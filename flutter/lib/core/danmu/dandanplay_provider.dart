// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient;
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../ohos_runtime.dart';
import '../series_scraper.dart';
import 'provider.dart';

class BoundDanmuEpisode {
  final String origin;
  final String rawEpisodeId;

  const BoundDanmuEpisode({
    required this.origin,
    required this.rawEpisodeId,
  });
}

/// Clean-room Dandanplay Open API v2 compatible segmented/full-episode [DanmuProvider].
///
/// Default server list is strictly empty (`""`). Network operations are automatically
/// disabled when [OhosRuntime.isOhos] is true.
class DandanplayProvider implements DanmuProvider {
  static const String defaultServerUrls = '';
  static const int maxServers = 8;
  static const int defaultMaxConcurrency = 4;
  static const Duration connectTimeout = Duration(milliseconds: 5000);
  static const Duration readTimeout = Duration(milliseconds: 8000);
  static const int defaultMinRequestIntervalMs = 200;
  static const int defaultRetryAfterMs = 2000;
  static const int windowDurationMs = 30000;
  static const int maxWindowItems = 1500;
  static const int maxFullEpisodeItems = 20000;
  static const int maxPayloadBytes = 8 * 1024 * 1024;
  static const int maxTextLength = 180;
  static const String boundUriPrefix = 'mmdanmu://v1?';

  /// Minimum candidate confidence required for automatic episode binding.
  /// Mismatched episodes (including neighbor episodes like E09/E11 for E10)
  /// and mismatched seasons (e.g. S01E10 for S02E10) are capped strictly below
  /// this threshold so they stay available for explicit user choice.
  static const double autoBindMinConfidence = 0.55;

  final List<String> configuredOrigins;
  final Set<String> _originWhitelist;
  final String appId;
  final String appSecret;
  final int maxConcurrency;
  final int minRequestIntervalMs;
  final http.Client _client;
  final HttpClient? _ownedIoHttpClient;
  final bool _ownsClient;
  final Map<String, int> _domainNextAllowedMs = <String, int>{};

  /// Origins restored from cloud sync that have NOT yet been explicitly
  /// authorized on this device to receive local `appId`/`appSecret`.
  /// Kept in sync by [DanmuPrefs] so even providers instantiated directly with
  /// saved global credentials never leak `X-AppId`/`X-Signature` to unapproved
  /// cloud-restored endpoints.
  static final Set<String> _locallyUnauthorizedCredentialOrigins = <String>{};

  static void setLocallyUnauthorizedCredentialOrigins(
    Iterable<String> origins,
  ) {
    _locallyUnauthorizedCredentialOrigins
      ..clear()
      ..addAll(origins.map(normalizeOriginOrNull).whereType<String>());
  }

  static void markOriginAuthorizedForLocalCredentials(String origin) {
    final norm = normalizeOriginOrNull(origin);
    if (norm != null) {
      _locallyUnauthorizedCredentialOrigins.remove(norm);
    }
  }

  static void markOriginUnauthorizedForLocalCredentials(String origin) {
    final norm = normalizeOriginOrNull(origin);
    if (norm != null) {
      _locallyUnauthorizedCredentialOrigins.add(norm);
    }
  }

  final Set<String>? authorizedCredentialOrigins;

  factory DandanplayProvider({
    String multilineServerUrls = defaultServerUrls,
    String appId = '',
    String appSecret = '',
    Set<String>? authorizedCredentialOrigins,
    int maxConcurrency = defaultMaxConcurrency,
    int minRequestIntervalMs = defaultMinRequestIntervalMs,
    http.Client? client,
  }) {
    HttpClient? ownedIoHttpClient;
    late final http.Client resolvedClient;
    if (client != null) {
      resolvedClient = client;
    } else {
      ownedIoHttpClient = HttpClient()..connectionTimeout = connectTimeout;
      resolvedClient = IOClient(ownedIoHttpClient);
    }
    return DandanplayProvider._(
      multilineServerUrls: multilineServerUrls,
      appId: appId,
      appSecret: appSecret,
      authorizedCredentialOrigins: authorizedCredentialOrigins == null
          ? null
          : Set<String>.unmodifiable(
              authorizedCredentialOrigins
                  .map(normalizeOriginOrNull)
                  .whereType<String>(),
            ),
      maxConcurrency: maxConcurrency,
      minRequestIntervalMs: minRequestIntervalMs,
      client: resolvedClient,
      ownedIoHttpClient: ownedIoHttpClient,
      ownsClient: client == null,
    );
  }

  DandanplayProvider._({
    required String multilineServerUrls,
    required String appId,
    required String appSecret,
    required this.authorizedCredentialOrigins,
    required int maxConcurrency,
    required int minRequestIntervalMs,
    required http.Client client,
    required HttpClient? ownedIoHttpClient,
    required bool ownsClient,
  })  : configuredOrigins = parseConfiguredOrigins(multilineServerUrls),
        _originWhitelist =
            Set<String>.unmodifiable(parseConfiguredOrigins(multilineServerUrls)),
        appId = appId.trim(),
        appSecret = appSecret.trim(),
        maxConcurrency = maxConcurrency.clamp(1, 5),
        minRequestIntervalMs = math.max(0, minRequestIntervalMs),
        _client = client,
        _ownedIoHttpClient = ownedIoHttpClient,
        _ownsClient = ownsClient;

  bool _shouldSignOrigin(String originKey) {
    if (appId.isEmpty || appSecret.isEmpty) return false;
    final explicit = authorizedCredentialOrigins;
    if (explicit != null) {
      return explicit.contains(originKey);
    }
    return !_locallyUnauthorizedCredentialOrigins.contains(originKey);
  }

  String? _resolveMatchingConfiguredOrigin(
    Uri targetUri,
    String fallbackOriginKey,
  ) {
    if (targetUri.host.isEmpty) return null;
    final scheme = targetUri.scheme.toLowerCase();
    final host = targetUri.host.toLowerCase();
    final port = _effectivePort(scheme, targetUri.hasPort ? targetUri.port : -1);
    final path = targetUri.path;
    final candidates = <String>{
      ..._originWhitelist,
      if (fallbackOriginKey.isNotEmpty) fallbackOriginKey,
    };
    String? bestMatch;
    int bestPathLen = -1;
    for (final origin in candidates) {
      if (!_matchesOrigin(origin, scheme, host, port)) continue;
      final oPath = Uri.parse(origin).path;
      final pathMatches = oPath.isEmpty ||
          path == oPath ||
          path.startsWith('$oPath/');
      if (!pathMatches) continue;
      if (oPath.length > bestPathLen) {
        bestPathLen = oPath.length;
        bestMatch = origin;
      }
    }
    return bestMatch;
  }

  bool _shouldSignRequestUri(Uri targetUri, String fallbackOriginKey) {
    if (appId.isEmpty || appSecret.isEmpty) return false;
    final effectiveOrigin =
        _resolveMatchingConfiguredOrigin(targetUri, fallbackOriginKey);
    if (effectiveOrigin == null) return false;
    return _shouldSignOrigin(effectiveOrigin);
  }

  static bool _hasConfirmedFullIdentity(
    DanmuCandidate candidate,
    DanmuMatchQuery query,
  ) {
    final normQ = SeriesScraper.normalizeWorkCoreTitle(query.title);
    final normA = SeriesScraper.normalizeWorkCoreTitle(candidate.animeTitle);
    if (normQ.isNotEmpty) {
      if (normA.isEmpty) return false;
      final titleMatches =
          normA == normQ || normA.contains(normQ) || normQ.contains(normA);
      if (!titleMatches) return false;
    }
    if (query.episodeIndex > 0) {
      final epText = candidate.episodeTitle.trim();
      if (epText.isEmpty) return false;
      final scraped = SeriesScraper.scrapeEpisodeName(
        epText,
        seriesTitle: candidate.animeTitle,
      );
      if (scraped.isSpecial ||
          scraped.resolvedEpisodeNumber != query.episodeIndex) {
        return false;
      }
    }
    final reqSeason = query.seasonNumber;
    if (reqSeason != null && reqSeason > 0) {
      final candSeason =
          _extractCandidateSeason(candidate.animeTitle, candidate.episodeTitle);
      if (candSeason == reqSeason) return true;
      if (candSeason == null && reqSeason > 1) {
        final normalizedAnime =
            SeriesScraper.normalizeSequelNumerals(candidate.animeTitle);
        if (RegExp('(?<=[\\u4e00-\\u9fff])$reqSeason\\b')
            .hasMatch(normalizedAnime)) {
          return true;
        }
      }
      return false;
    }
    return true;
  }

  /// Selects a unique, order-independent auto-bind candidate from [candidates].
  ///
  /// Returns `null` (leaving candidates in pending user selection) when:
  /// - No candidate meets [autoBindMinConfidence], OR
  /// - Multiple distinct candidates near the top score are ambiguous (e.g.
  ///   both `S01E10` and `S02E10` returned by an origin when season is unknown,
  ///   or conflicting seasons/works across top candidates).
  ///
  /// When [query] has a confirmed season and exactly one qualifying candidate
  /// positively confirms the full `(work, season, episode)` identity while
  /// another candidate omits season info (e.g. `S02E10` vs unseasoned `第10集`),
  /// the unique fully-confirmed candidate wins cleanly.
  static DanmuCandidate? selectUniqueAutoBindCandidate(
    List<DanmuCandidate> candidates, {
    required DanmuMatchQuery query,
    List<String> preferredOrigins = const <String>[],
  }) {
    final qualifying = candidates
        .where(
          (c) =>
              c.boundEpisodeId.trim().isNotEmpty &&
              c.confidence >= autoBindMinConfidence,
        )
        .toList();
    if (qualifying.isEmpty) return null;

    var pool = qualifying;
    if (query.seasonNumber != null && query.seasonNumber! > 0) {
      final fullyConfirmed = qualifying
          .where((c) => _hasConfirmedFullIdentity(c, query))
          .toList();
      if (fullyConfirmed.isNotEmpty) {
        pool = fullyConfirmed;
      }
    }

    int originRank(String origin) {
      final idx = preferredOrigins.indexOf(origin);
      return idx >= 0 ? idx : preferredOrigins.length + 1;
    }

    pool.sort((a, b) {
      final confDiff = b.confidence.compareTo(a.confidence);
      if (confDiff != 0 && (b.confidence - a.confidence).abs() >= 0.001) {
        return confDiff;
      }
      final oDiff = originRank(a.sourceOrigin).compareTo(originRank(b.sourceOrigin));
      if (oDiff != 0) return oDiff;
      return a.boundEpisodeId.compareTo(b.boundEpisodeId);
    });

    final best = pool.first;
    final bestSeason = _extractCandidateSeason(best.animeTitle, best.episodeTitle);
    final bestCoreTitle = SeriesScraper.normalizeWorkCoreTitle(best.animeTitle);

    const double ambiguityMargin = 0.08;
    for (final other in pool.skip(1)) {
      if ((best.confidence - other.confidence).abs() >= ambiguityMargin) {
        continue;
      }
      if (other.boundEpisodeId == best.boundEpisodeId) {
        continue;
      }
      // Multiple distinct episodes from the SAME origin tied near top score:
      // refuse to guess based on server response ordering.
      if (other.sourceOrigin == best.sourceOrigin) {
        return null;
      }
      // Conflicting explicit seasons across top candidates (e.g. S01 vs S02):
      final otherSeason =
          _extractCandidateSeason(other.animeTitle, other.episodeTitle);
      if (bestSeason != null &&
          otherSeason != null &&
          bestSeason != otherSeason) {
        return null;
      }
      // Conflicting work titles across top candidates:
      final otherCoreTitle = SeriesScraper.normalizeWorkCoreTitle(other.animeTitle);
      if (bestCoreTitle.isNotEmpty &&
          otherCoreTitle.isNotEmpty &&
          bestCoreTitle != otherCoreTitle) {
        return null;
      }
    }
    return best;
  }

  bool _closed = false;

  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) {
      _client.close();
      _ownedIoHttpClient?.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // RFC 4648 Base64url (no padding) & Open API v2 SHA-256 signature
  // ---------------------------------------------------------------------------

  static String base64UrlEncodeNoPad(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static List<int> base64UrlDecode(String encoded) {
    if (encoded.isEmpty) return <int>[];
    if (encoded.contains('=') || encoded.contains('+') || encoded.contains('/')) {
      throw const FormatException('Invalid unpadded base64url token');
    }
    final rem = encoded.length % 4;
    if (rem == 1) {
      throw const FormatException('Invalid base64url length');
    }
    final padded = rem == 0 ? encoded : encoded + ('=' * (4 - rem));
    return base64Url.decode(padded);
  }

  static String computeOpenApiSignature({
    required String appId,
    required int timestampSec,
    required String urlPath,
    required String appSecret,
  }) {
    final normalizedPath = urlPath.isEmpty ? '/' : urlPath;
    final digest = sha256.convert(
      utf8.encode('$appId$timestampSec$normalizedPath$appSecret'),
    );
    return base64.encode(digest.bytes);
  }

  // ---------------------------------------------------------------------------
  // Origin Normalization, Percent Encoding & SourceBoundEpisodeId (SSRF Guard)
  // ---------------------------------------------------------------------------

  static List<String> parseConfiguredOrigins(String multilineUrls) {
    if (multilineUrls.trim().isEmpty) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final line in multilineUrls.split(RegExp(r'\r?\n'))) {
      if (out.length >= maxServers) break;
      final normalized = normalizeOriginOrNull(line);
      if (normalized != null && seen.add(normalized)) {
        out.add(normalized);
      }
    }
    return List<String>.unmodifiable(out);
  }

  static String? normalizeOriginOrNull(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    for (var i = 0; i < trimmed.length; i++) {
      if (trimmed.codeUnitAt(i) <= 0x20) return null;
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (uri.hasQuery || uri.hasFragment) return null;
    if (uri.host.isEmpty || uri.host.contains('_')) return null;
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final host = uri.host.toLowerCase();
    final formattedHost =
        (host.contains(':') && !host.startsWith('[')) ? '[$host]' : host;
    final includePort = uri.hasPort &&
        !((scheme == 'http' && uri.port == 80) ||
            (scheme == 'https' && uri.port == 443));
    final portPart = includePort ? ':${uri.port}' : '';
    return '$scheme://$formattedHost$portPart$path';
  }

  static String percentEncode(String value) {
    if (value.isEmpty) return '';
    final bytes = utf8.encode(value);
    final sb = StringBuffer();
    for (final b in bytes) {
      if ((b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A) ||
          (b >= 0x30 && b <= 0x39) ||
          b == 0x2D ||
          b == 0x5F ||
          b == 0x2E ||
          b == 0x7E) {
        sb.writeCharCode(b);
      } else {
        sb.write('%');
        sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return sb.toString();
  }

  static String percentDecode(String encoded) {
    if (encoded.isEmpty) return '';
    final bytes = <int>[];
    for (var i = 0; i < encoded.length; i++) {
      final ch = encoded.codeUnitAt(i);
      if (ch == 0x25) {
        if (i + 2 >= encoded.length) {
          throw const FormatException('Truncated percent escape');
        }
        final hex = encoded.substring(i + 1, i + 3);
        final v = int.tryParse(hex, radix: 16);
        if (v == null) {
          throw const FormatException('Invalid percent escape');
        }
        bytes.add(v);
        i += 2;
      } else {
        bytes.addAll(utf8.encode(encoded[i]));
      }
    }
    return utf8.decode(bytes);
  }

  static String encodeBoundEpisodeId(String origin, String rawEpisodeId) {
    final norm = normalizeOriginOrNull(origin);
    if (norm == null) {
      throw FormatException('Invalid danmu origin: $origin');
    }
    final ep = rawEpisodeId.trim();
    if (ep.isEmpty) {
      throw const FormatException('Episode id cannot be empty');
    }
    final src = base64UrlEncodeNoPad(utf8.encode(norm));
    return '${boundUriPrefix}src=$src&ep=${percentEncode(ep)}';
  }

  static BoundDanmuEpisode decodeBoundEpisodeId(
    String boundEpisodeId,
    Iterable<String> allowedOrigins,
  ) {
    if (!boundEpisodeId.startsWith(boundUriPrefix)) {
      throw const FormatException('Invalid mmdanmu://v1 bound episode id');
    }
    final query = boundEpisodeId.substring(boundUriPrefix.length);
    String? srcParam;
    String? epParam;
    for (final pair in query.split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final k = pair.substring(0, eq);
      final v = pair.substring(eq + 1);
      if (k == 'src') srcParam = v;
      if (k == 'ep') epParam = v;
    }
    if (srcParam == null ||
        srcParam.isEmpty ||
        epParam == null ||
        epParam.isEmpty) {
      throw const FormatException('Missing src or ep in mmdanmu://v1 URI');
    }
    final decodedOrigin = utf8.decode(base64UrlDecode(srcParam));
    final normOrigin = normalizeOriginOrNull(decodedOrigin);
    if (normOrigin == null) {
      throw FormatException('Illegal danmu origin scheme: $decodedOrigin');
    }
    final allowed = allowedOrigins.toSet();
    if (!allowed.contains(normOrigin)) {
      throw FormatException('Danmu origin is not in user whitelist: $normOrigin');
    }
    final rawEp = percentDecode(epParam).trim();
    if (rawEp.isEmpty) {
      throw const FormatException('Decoded episode id is empty');
    }
    return BoundDanmuEpisode(origin: normOrigin, rawEpisodeId: rawEp);
  }

  Uri _validateSegmentUri(String rawUrl, String boundOrigin) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Empty danmu segment URL');
    }
    final base = Uri.parse('$boundOrigin/');
    final resolved = base.resolve(trimmed);
    final scheme = resolved.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw FormatException('Unsupported segment scheme: $scheme');
    }
    if (resolved.userInfo.isNotEmpty) {
      throw const FormatException('Segment URL must not contain credentials');
    }
    if (!_isUriOriginAllowed(resolved, boundOrigin)) {
      throw FormatException(
        'Segment URL host is not in user whitelist: ${resolved.host}',
      );
    }
    return resolved;
  }

  bool _isUriOriginAllowed(Uri uri, String boundOrigin) {
    if (uri.host.isEmpty) return false;
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final port = _effectivePort(scheme, uri.hasPort ? uri.port : -1);
    if (_matchesOrigin(boundOrigin, scheme, host, port)) return true;
    for (final allowed in _originWhitelist) {
      if (_matchesOrigin(allowed, scheme, host, port)) return true;
    }
    return false;
  }

  static bool _matchesOrigin(
    String normalizedOrigin,
    String scheme,
    String host,
    int port,
  ) {
    final o = Uri.parse(normalizedOrigin);
    final oScheme = o.scheme.toLowerCase();
    final oHost = o.host.toLowerCase();
    final oPort = _effectivePort(oScheme, o.hasPort ? o.port : -1);
    return oScheme == scheme && oHost == host && oPort == port;
  }

  static int _effectivePort(String scheme, int port) {
    if (port > 0) return port;
    return scheme == 'https' ? 443 : 80;
  }

  // ---------------------------------------------------------------------------
  // 3-Stage Protocol
  // ---------------------------------------------------------------------------

  @override
  Future<List<DanmuCandidate>> matchOrSearch(
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    if (OhosRuntime.isOhos || configuredOrigins.isEmpty) {
      return const <DanmuCandidate>[];
    }

    // 0. If the user explicitly bound a Dandanplay animeId + origin for this
    // series, resolve the exact episode from that bangumi first.
    final boundAnimeId = query.animeIdOverride.trim();
    final boundOrigin = normalizeOriginOrNull(query.originOverride);
    if (boundAnimeId.isNotEmpty &&
        boundOrigin != null &&
        _originWhitelist.contains(boundOrigin)) {
      try {
        final eps = await listEpisodes(
          boundOrigin,
          boundAnimeId,
          cancelToken: cancelToken,
        );
        if (eps.isNotEmpty) {
          final ranked = _rankBoundAnimeEpisodes(eps, query);
          if (ranked.isNotEmpty) return ranked;
        }
      } catch (_) {}
    }

    final merged = <DanmuCandidate>[];
    final seenBound = <String>{};

    // Bounded concurrency batches of size <= maxConcurrency (1..5, default 4)
    for (var start = 0;
        start < configuredOrigins.length;
        start += maxConcurrency) {
      cancelToken?.throwIfCancelled();
      final end = math.min(start + maxConcurrency, configuredOrigins.length);
      final batch = configuredOrigins.sublist(start, end);
      final results = await Future.wait<List<DanmuCandidate>>(
        batch.map(
          (origin) async {
            try {
              return await _matchOrSearchSingleOrigin(
                origin,
                query,
                cancelToken: cancelToken,
              );
            } catch (_) {
              return const <DanmuCandidate>[];
            }
          },
        ),
      );
      for (final list in results) {
        for (final c in list) {
          if (seenBound.add(c.boundEpisodeId)) {
            merged.add(c);
          }
        }
      }
    }

    cancelToken?.throwIfCancelled();
    merged.sort((a, b) => b.confidence.compareTo(a.confidence));
    return merged;
  }

  static int? _extractCandidateSeason(String animeTitle, String episodeTitle) {
    final epScraped = SeriesScraper.scrapeEpisodeName(
      episodeTitle,
      seriesTitle: animeTitle,
    );
    if (epScraped.seasonNumber != null && epScraped.seasonNumber! > 0) {
      return epScraped.seasonNumber;
    }
    final normalizedAnime = SeriesScraper.normalizeSequelNumerals(animeTitle);
    final cnMatch = RegExp(r'第\s*([0-9一二三四五六七八九十两]+)\s*[季部]')
        .firstMatch(normalizedAnime);
    if (cnMatch != null) {
      final token = cnMatch.group(1)!;
      final parsed = int.tryParse(token) ??
          const <String, int>{
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
            '十': 10,
          }[token];
      if (parsed != null && parsed > 0 && parsed <= 99) return parsed;
    }
    final enMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])(?:Season[\s._\-]*0*(\d{1,2})|[Ss]0*(\d{1,2}))(?![0-9A-Za-z])',
      caseSensitive: false,
    ).firstMatch(normalizedAnime);
    if (enMatch != null) {
      final parsed = int.tryParse(enMatch.group(1) ?? enMatch.group(2) ?? '');
      if (parsed != null && parsed > 0 && parsed <= 99) return parsed;
    }
    return null;
  }

  List<DanmuCandidate> _rankBoundAnimeEpisodes(
    List<DanmuCandidate> eps,
    DanmuMatchQuery query,
  ) {
    if (eps.isEmpty) return const <DanmuCandidate>[];
    final targetEp = query.episodeIndex;
    if (targetEp <= 0) return eps;
    final scored = <DanmuCandidate>[];
    for (int i = 0; i < eps.length; i++) {
      final c = eps[i];
      final scraped = SeriesScraper.scrapeEpisodeName(
        c.episodeTitle,
        seriesTitle: c.animeTitle,
      );
      final epNum = scraped.resolvedEpisodeNumber;
      final candSeason = _extractCandidateSeason(c.animeTitle, c.episodeTitle);
      final seasonMismatch = query.seasonNumber != null &&
          query.seasonNumber! > 0 &&
          candSeason != null &&
          candSeason != query.seasonNumber;
      double conf;
      if (seasonMismatch) {
        conf = 0.22;
      } else if (scraped.isSpecial) {
        // Trailers / previews / SP must never auto-bind for regular episodes.
        conf = 0.15;
      } else if (epNum != null) {
        // Neighbor episodes stay strictly below autoBindMinConfidence (0.55)
        // so the player leaves selection to the user instead of silently
        // loading the wrong episode's danmu.
        conf = epNum == targetEp
            ? 1.0
            : (epNum == targetEp - 1 || epNum == targetEp + 1 ? 0.34 : 0.20);
      } else {
        // Never auto-bind by list position when episode titles have no
        // parseable episode number; leave as a low-confidence candidate.
        conf = 0.20;
      }
      scored.add(
        DanmuCandidate(
          sourceOrigin: c.sourceOrigin,
          animeId: c.animeId,
          animeTitle: c.animeTitle,
          boundEpisodeId: c.boundEpisodeId,
          episodeTitle: c.episodeTitle,
          confidence: conf,
        ),
      );
    }
    scored.sort((a, b) => b.confidence.compareTo(a.confidence));
    return scored;
  }

  Future<List<DanmuCandidate>> _matchOrSearchSingleOrigin(
    String origin,
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async {
    List<DanmuCandidate> matched = const <DanmuCandidate>[];
    try {
      matched = await _tryMatchEndpoint(
        origin,
        query,
        cancelToken: cancelToken,
      );
    } on DanmuCancelledException {
      rethrow;
    } catch (_) {}
    final hasStrongMatch =
        matched.any((c) => c.confidence >= autoBindMinConfidence);
    if (hasStrongMatch) return matched;
    List<DanmuCandidate> searched = const <DanmuCandidate>[];
    try {
      searched = await _trySearchEpisodesEndpoint(
        origin,
        query,
        cancelToken: cancelToken,
      );
    } on DanmuCancelledException {
      rethrow;
    } catch (_) {}
    if (matched.isEmpty) return searched;
    if (searched.isEmpty) return matched;
    final seen = <String>{};
    final combined = <DanmuCandidate>[];
    for (final c in <DanmuCandidate>[...searched, ...matched]) {
      if (seen.add(c.boundEpisodeId)) {
        combined.add(c);
      }
    }
    combined.sort((a, b) => b.confidence.compareTo(a.confidence));
    return combined;
  }

  static Set<String> _titleOverlapTokens(String normalized) {
    final out = <String>{};
    if (normalized.isEmpty) return out;
    final cjk = normalized.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '');
    if (cjk.length >= 2) {
      for (int i = 0; i < cjk.length - 1; i++) {
        out.add(cjk.substring(i, i + 2));
      }
    } else if (cjk.length == 1) {
      out.add(cjk);
    }
    for (final m in RegExp(r'[a-z0-9]{2,}').allMatches(normalized)) {
      out.add(m.group(0)!);
    }
    return out;
  }

  static double _titleOverlapRatio(String normQ, String normA) {
    final qTokens = _titleOverlapTokens(normQ);
    final aTokens = _titleOverlapTokens(normA);
    if (qTokens.isEmpty || aTokens.isEmpty) return 0.0;
    int overlap = 0;
    for (final t in qTokens) {
      if (aTokens.contains(t)) overlap++;
    }
    final denom = math.min(qTokens.length, aTokens.length);
    return denom > 0 ? overlap / denom : 0.0;
  }

  static double _scoreCandidate(
    DanmuMatchQuery query, {
    required String animeTitle,
    required String episodeTitle,
    required double baseConfidence,
    bool isExactMatch = false,
  }) {
    var score = baseConfidence;
    final candIsMc = SeriesScraper.isMotionComicText(
      animeTitle,
      extraContext: episodeTitle,
    );
    if (query.isMotionComic && candIsMc) {
      score += 0.08;
    }

    bool titleUnrelated = false;
    bool missingIdentityEvidence = false;
    final normQ = SeriesScraper.normalizeWorkCoreTitle(query.title);
    final normA = SeriesScraper.normalizeWorkCoreTitle(animeTitle);
    if (normQ.isNotEmpty && normA.isEmpty) {
      if (!isExactMatch) {
        // Non-exact match supplied no work title (e.g. ID-only candidate):
        // must never auto-bind by backfilling query metadata.
        missingIdentityEvidence = true;
      }
    } else if (normQ.isNotEmpty && normA.isNotEmpty) {
      if (normA == normQ) {
        score += 0.14;
      } else if (normA.contains(normQ) || normQ.contains(normA)) {
        final bareRootHijack = normQ.length >= 6 &&
            normA.length <= 4 &&
            RegExp(r'\d').hasMatch(normQ) &&
            !RegExp(r'\d').hasMatch(normA);
        score += bareRootHijack ? -0.22 : 0.06;
      } else {
        final overlap = _titleOverlapRatio(normQ, normA);
        if (overlap >= 0.35) {
          score -= 0.10;
        } else {
          titleUnrelated = true;
          score -= 0.45;
        }
      }
    }

    bool episodeMismatched = false;
    bool seasonMismatched = false;

    final scrapedEp = episodeTitle.trim().isNotEmpty
        ? SeriesScraper.scrapeEpisodeName(
            episodeTitle,
            seriesTitle: animeTitle,
          )
        : null;
    if (query.episodeIndex > 0) {
      if (scrapedEp != null) {
        final epNum = scrapedEp.resolvedEpisodeNumber;
        if (epNum != null && !scrapedEp.isSpecial) {
          if (epNum == query.episodeIndex) {
            score += 0.18;
          } else {
            episodeMismatched = true;
            score -= 0.35;
          }
        } else if (scrapedEp.isSpecial) {
          episodeMismatched = true;
          score -= 0.40;
        } else if (!isExactMatch) {
          // Non-exact candidate supplied an episode title with no parseable
          // episode number (e.g. "重逢"): cannot prove episode identity.
          missingIdentityEvidence = true;
        }
      } else if (!isExactMatch) {
        // Non-exact candidate supplied no episodeTitle at all.
        missingIdentityEvidence = true;
      }
    }

    final year = query.year.trim();
    if (year.length == 4 && animeTitle.contains(year)) {
      score += 0.05;
    }
    if (query.seasonNumber != null && query.seasonNumber! > 0) {
      final s = query.seasonNumber!;
      final candSeason = _extractCandidateSeason(animeTitle, episodeTitle);
      if (candSeason != null) {
        if (candSeason == s) {
          score += 0.16;
        } else {
          seasonMismatched = true;
          score -= 0.45;
        }
      } else if (s > 1) {
        final normalizedAnime = SeriesScraper.normalizeSequelNumerals(animeTitle);
        if (RegExp('(?<=[\\u4e00-\\u9fff])$s\\b').hasMatch(normalizedAnime)) {
          score += 0.10;
        } else {
          // Candidate has no Season N marker when Season N > 1 was requested.
          score -= 0.14;
        }
      }
    }

    if (candIsMc != query.isMotionComic) {
      // Strictly separate 动态漫画 from standard 动漫/剧集 so wrong-medium danmu
      // never beats or auto-binds over the true work (even with exact title+ep).
      return math.min(score - 0.65, 0.24).clamp(0.05, 0.24);
    }
    if (seasonMismatched) {
      // Wrong-season candidates (e.g. S01E10 for S02E10) never auto-bind.
      return math.min(score, 0.30).clamp(0.05, 0.30);
    }
    if (episodeMismatched) {
      // Neighbor / wrong-episode candidates (e.g. E09/E11 for E10) never
      // auto-bind and are surfaced for explicit user choice.
      return math.min(score, 0.34).clamp(0.05, 0.34);
    }
    if (missingIdentityEvidence) {
      // Non-exact candidates missing positive work or episode-number identity
      // stay candidate-only (strictly below autoBindMinConfidence).
      return math.min(score, 0.36).clamp(0.05, 0.36);
    }
    if (titleUnrelated) {
      // Unrelated work returning the same season/episode must stay candidate-only
      // (strictly below autoBindMinConfidence) so the user decides explicitly.
      return math.min(score, 0.38).clamp(0.05, 0.38);
    }
    return score.clamp(0.05, 1.0);
  }

  Future<List<DanmuCandidate>> _tryMatchEndpoint(
    String origin,
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async {
    final fileName = _buildCleanFileName(query);
    if (fileName.isEmpty) return const <DanmuCandidate>[];
    final payload = jsonEncode(<String, dynamic>{
      'fileName': fileName,
      'fileHash': '',
      'fileSize': 0,
      'videoDuration': math.max(0, query.durationSec),
      'matchMode': 'fileNameOnly',
    });
    final body = await _executeHttp(
      originKey: origin,
      uri: Uri.parse('$origin/api/v2/match'),
      method: 'POST',
      jsonBody: payload,
      cancelToken: cancelToken,
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const <DanmuCandidate>[];
    final matches = decoded['matches'];
    if (matches is! List || matches.isEmpty) return const <DanmuCandidate>[];
    final exact = decoded['isMatched'] == true;
    final out = <DanmuCandidate>[];
    for (final raw in matches) {
      if (raw is! Map) continue;
      final epId = _stringifyId(raw['episodeId']);
      if (epId.isEmpty) continue;
      final animeId = _stringifyId(raw['animeId']);
      // NEVER backfill missing animeTitle / episodeTitle from the request query:
      // candidate identity must come strictly from the server response itself.
      final animeTitle = (raw['animeTitle']?.toString() ?? '').trim();
      final epTitle = (raw['episodeTitle']?.toString() ?? '').trim();
      final rawConf = raw['confidence'] is num
          ? (raw['confidence'] as num).toDouble()
          : (exact ? 0.90 : 0.78);
      final conf = _scoreCandidate(
        query,
        animeTitle: animeTitle,
        episodeTitle: epTitle,
        baseConfidence: rawConf,
        isExactMatch: exact,
      );
      out.add(
        DanmuCandidate(
          sourceOrigin: origin,
          animeId: animeId,
          animeTitle: animeTitle,
          boundEpisodeId: encodeBoundEpisodeId(origin, epId),
          episodeTitle: epTitle,
          confidence: conf,
        ),
      );
    }
    out.sort((a, b) => b.confidence.compareTo(a.confidence));
    return out;
  }

  Future<List<DanmuCandidate>> _trySearchEpisodesEndpoint(
    String origin,
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async {
    var cleanTitle = _cleanTitle(query.title);
    if (cleanTitle.isEmpty) return const <DanmuCandidate>[];
    if (query.isMotionComic &&
        !SeriesScraper.isMotionComicText(cleanTitle)) {
      cleanTitle = '$cleanTitle 动态漫画';
    }
    final sb = StringBuffer('$origin/api/v2/search/episodes?anime=')
      ..write(percentEncode(cleanTitle));
    if (query.episodeIndex > 0) {
      sb.write('&episode=${query.episodeIndex}');
    }
    final body = await _executeHttp(
      originKey: origin,
      uri: Uri.parse(sb.toString()),
      method: 'GET',
      cancelToken: cancelToken,
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const <DanmuCandidate>[];
    final animes = decoded['animes'];
    if (animes is! List) return const <DanmuCandidate>[];
    final out = <DanmuCandidate>[];
    for (final anime in animes) {
      if (anime is! Map) continue;
      final animeId = _stringifyId(anime['animeId']);
      final animeTitle = anime['animeTitle']?.toString() ?? '';
      final episodes = anime['episodes'];
      if (episodes is! List) continue;
      for (final ep in episodes) {
        if (ep is! Map) continue;
        final epId = _stringifyId(ep['episodeId']);
        if (epId.isEmpty) continue;
        final epTitle = ep['episodeTitle']?.toString() ?? '';
        final conf = _scoreCandidate(
          query,
          animeTitle: animeTitle,
          episodeTitle: epTitle,
          baseConfidence: 0.68,
        );
        out.add(
          DanmuCandidate(
            sourceOrigin: origin,
            animeId: animeId,
            animeTitle: animeTitle,
            boundEpisodeId: encodeBoundEpisodeId(origin, epId),
            episodeTitle: epTitle,
            confidence: conf,
          ),
        );
      }
    }
    out.sort((a, b) => b.confidence.compareTo(a.confidence));
    return out;
  }

  @override
  Future<List<DanmuCandidate>> listEpisodes(
    String sourceOrigin,
    String animeId, {
    DanmuCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    if (OhosRuntime.isOhos) return const <DanmuCandidate>[];
    final normOrigin = normalizeOriginOrNull(sourceOrigin);
    if (normOrigin == null || !_originWhitelist.contains(normOrigin)) {
      throw FormatException('Danmu origin is not in user whitelist: $sourceOrigin');
    }
    final id = animeId.trim();
    if (id.isEmpty) return const <DanmuCandidate>[];
    final body = await _executeHttp(
      originKey: normOrigin,
      uri: Uri.parse('$normOrigin/api/v2/bangumi/${percentEncode(id)}'),
      method: 'GET',
      cancelToken: cancelToken,
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const <DanmuCandidate>[];
    final bangumi = decoded['bangumi'] is Map ? decoded['bangumi'] as Map : null;
    final animeTitle =
        (bangumi?['animeTitle'] ?? decoded['animeTitle'] ?? '').toString();
    final episodes = bangumi?['episodes'] ?? decoded['episodes'];
    if (episodes is! List) return const <DanmuCandidate>[];
    final out = <DanmuCandidate>[];
    for (final ep in episodes) {
      if (ep is! Map) continue;
      final epId = _stringifyId(ep['episodeId']);
      if (epId.isEmpty) continue;
      out.add(
        DanmuCandidate(
          sourceOrigin: normOrigin,
          animeId: id,
          animeTitle: animeTitle,
          boundEpisodeId: encodeBoundEpisodeId(normOrigin, epId),
          episodeTitle: ep['episodeTitle']?.toString() ?? '',
          confidence: 1.0,
        ),
      );
    }
    return out;
  }

  @override
  Future<DanmuEpisodeSession> openSession(
    String boundEpisodeId, {
    DanmuCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    if (OhosRuntime.isOhos) {
      return DanmuEpisodeSession(
        boundEpisodeId: boundEpisodeId,
        segmented: false,
      );
    }
    final bound = decodeBoundEpisodeId(boundEpisodeId, _originWhitelist);
    final uri = Uri.parse(
      '${bound.origin}/api/v2/comment/${percentEncode(bound.rawEpisodeId)}'
      '?withRelated=true&chConvert=0',
    );
    final body = await _executeHttp(
      originKey: bound.origin,
      uri: uri,
      method: 'GET',
      cancelToken: cancelToken,
    );
    final trimmed = body.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic> && decoded['segments'] is List) {
          final rawSegs = decoded['segments'] as List;
          if (rawSegs.isNotEmpty) {
            final segments = <DanmuSegmentDescriptor>[];
            for (final raw in rawSegs) {
              if (raw is! Map) continue;
              final startMs = raw.containsKey('startMs')
                  ? (raw['startMs'] as num).toInt()
                  : ((raw['startSec'] as num?)?.toDouble() ?? 0.0) * 1000 ~/ 1;
              final endMs = raw.containsKey('endMs')
                  ? (raw['endMs'] as num).toInt()
                  : ((raw['endSec'] as num?)?.toDouble() ?? 0.0) * 1000 ~/ 1;
              final rawSegUrl =
                  (raw['segmentUrl'] ?? raw['url'] ?? '').toString().trim();
              if (endMs <= startMs || rawSegUrl.isEmpty) continue;
              final validated = _validateSegmentUri(rawSegUrl, bound.origin);
              segments.add(
                DanmuSegmentDescriptor(
                  startMs: startMs,
                  endMs: endMs,
                  segmentUrl: validated.toString(),
                ),
              );
            }
            if (segments.isNotEmpty) {
              return DanmuEpisodeSession(
                boundEpisodeId: boundEpisodeId,
                segmented: true,
                segments: List<DanmuSegmentDescriptor>.unmodifiable(segments),
              );
            }
          }
        }
      } on FormatException {
        rethrow;
      } catch (_) {}
    }

    final full = parseDanmuPayload(trimmed, maxItems: maxFullEpisodeItems);
    return DanmuEpisodeSession(
      boundEpisodeId: boundEpisodeId,
      segmented: false,
      preloadComments: List<DanmuItem>.unmodifiable(full),
    );
  }

  @override
  Future<List<DanmuItem>> fetchWindow(
    DanmuEpisodeSession session,
    int windowIndex, {
    DanmuCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    if (OhosRuntime.isOhos) return const <DanmuItem>[];
    if (windowIndex < 0) {
      throw RangeError.value(windowIndex, 'windowIndex', 'must be >= 0');
    }
    final windowStartMs = windowIndex * windowDurationMs;
    final windowEndMs = windowStartMs + windowDurationMs;

    if (!session.segmented) {
      return _sliceWindow(session.preloadComments, windowStartMs, windowEndMs);
    }

    final bound = decodeBoundEpisodeId(session.boundEpisodeId, _originWhitelist);
    final overlapping = <DanmuSegmentDescriptor>[];
    for (final seg in session.segments) {
      if (seg.startMs < windowEndMs && seg.endMs > windowStartMs) {
        overlapping.add(seg);
      }
    }
    if (overlapping.isEmpty) return const <DanmuItem>[];

    final collected = <DanmuItem>[];
    for (final seg in overlapping) {
      cancelToken?.throwIfCancelled();
      final validUri = _validateSegmentUri(seg.segmentUrl, bound.origin);
      final body = await _executeHttp(
        originKey: bound.origin,
        uri: validUri,
        method: 'GET',
        cancelToken: cancelToken,
      );
      final parsed = parseDanmuPayload(body, maxItems: maxFullEpisodeItems);
      for (final item in parsed) {
        if (item.timeMs >= windowStartMs && item.timeMs < windowEndMs) {
          collected.add(item);
        }
      }
    }
    return sortDedupAndCap(collected, maxWindowItems);
  }

  static List<DanmuItem> _sliceWindow(
    List<DanmuItem> sorted,
    int windowStartMs,
    int windowEndMs,
  ) {
    if (sorted.isEmpty) return const <DanmuItem>[];
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >>> 1;
      if (sorted[mid].timeMs < windowStartMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final out = <DanmuItem>[];
    for (var i = lo; i < sorted.length && out.length < maxWindowItems; i++) {
      final item = sorted[i];
      if (item.timeMs >= windowEndMs) break;
      if (item.timeMs >= windowStartMs) {
        out.add(item);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // HTTP Transport, Per-Domain Rate Limit, Optional Signature & Retry-After
  // ---------------------------------------------------------------------------

  Future<void> _awaitRateLimit(
    String originKey,
    DanmuCancelToken? cancelToken,
  ) async {
    if (minRequestIntervalMs <= 0 && !_domainNextAllowedMs.containsKey(originKey)) {
      return;
    }
    while (true) {
      cancelToken?.throwIfCancelled();
      final now = DateTime.now().millisecondsSinceEpoch;
      final allowed = _domainNextAllowedMs[originKey] ?? 0;
      if (now >= allowed) {
        _domainNextAllowedMs[originKey] = now + minRequestIntervalMs;
        return;
      }
      final waitMs = math.max(1, math.min(allowed - now, 50));
      if (cancelToken == null) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      } else {
        final waiter = Completer<void>();
        final timer = Timer(Duration(milliseconds: waitMs), () {
          if (!waiter.isCompleted) waiter.complete();
        });
        void onCancel() {
          if (!waiter.isCompleted) {
            waiter.completeError(const DanmuCancelledException());
          }
        }
        cancelToken.onCancel(onCancel);
        try {
          await waiter.future;
        } finally {
          timer.cancel();
          cancelToken.removeCancelHook(onCancel);
        }
      }
    }
  }

  void _recordBackoff(String originKey, int retryAfterMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final int deadline = now + math.max<int>(minRequestIntervalMs, retryAfterMs);
    final prev = _domainNextAllowedMs[originKey] ?? 0;
    if (deadline > prev) {
      _domainNextAllowedMs[originKey] = deadline;
    }
  }

  static int parseRetryAfterMs(String? header) {
    if (header == null || header.trim().isEmpty) return defaultRetryAfterMs;
    final sec = int.tryParse(header.trim());
    if (sec != null && sec > 0) {
      return math.min(60000, sec * 1000);
    }
    return defaultRetryAfterMs;
  }

  static void _discardStreamWithoutDrain(http.StreamedResponse response) {
    try {
      final sub = response.stream.listen(
        (_) {},
        onError: (_) {},
        cancelOnError: true,
      );
      unawaited(sub.cancel().catchError((_) {}));
    } catch (_) {}
  }

  Future<http.StreamedResponse> _sendAbortable(
    http.AbortableRequest req,
    Completer<void> abortCompleter,
    DanmuCancelToken? cancelToken,
  ) async {
    cancelToken?.throwIfCancelled();
    final responseCompleter = Completer<http.StreamedResponse>();

    void triggerAbort() {
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
    }

    final timer = Timer(readTimeout, () {
      triggerAbort();
      if (!responseCompleter.isCompleted) {
        responseCompleter.completeError(
          TimeoutException('Danmu HTTP request timed out', readTimeout),
        );
      }
    });

    void onCancel() {
      triggerAbort();
      if (!responseCompleter.isCompleted) {
        responseCompleter.completeError(const DanmuCancelledException());
      }
    }

    cancelToken?.onCancel(onCancel);

    unawaited(
      _client.send(req).then(
        (streamed) {
          if (!responseCompleter.isCompleted) {
            if (cancelToken != null && cancelToken.isCancelled) {
              triggerAbort();
              _discardStreamWithoutDrain(streamed);
              responseCompleter.completeError(const DanmuCancelledException());
            } else {
              responseCompleter.complete(streamed);
            }
          } else {
            // Cancelled or timed out while awaiting headers: NEVER drain the body.
            _discardStreamWithoutDrain(streamed);
          }
        },
        onError: (Object err, StackTrace st) {
          if (!responseCompleter.isCompleted) {
            if (cancelToken != null && cancelToken.isCancelled) {
              responseCompleter.completeError(const DanmuCancelledException());
            } else {
              responseCompleter.completeError(err, st);
            }
          }
        },
      ),
    );

    try {
      return await responseCompleter.future;
    } finally {
      timer.cancel();
      cancelToken?.removeCancelHook(onCancel);
    }
  }

  Future<List<int>> _readBodyBytesAbortable(
    http.StreamedResponse streamed,
    Completer<void> abortCompleter,
    DanmuCancelToken? cancelToken,
  ) async {
    if (cancelToken != null && cancelToken.isCancelled) {
      if (!abortCompleter.isCompleted) abortCompleter.complete();
      _discardStreamWithoutDrain(streamed);
      cancelToken.throwIfCancelled();
    }

    final completer = Completer<List<int>>();
    final bytes = <int>[];
    StreamSubscription<List<int>>? sub;

    void cancelSub() {
      final active = sub;
      if (active != null) {
        unawaited(active.cancel().catchError((_) {}));
      }
    }

    void triggerAbort() {
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
    }

    void finishError(Object error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }

    final timer = Timer(readTimeout, () {
      triggerAbort();
      cancelSub();
      finishError(TimeoutException('Danmu body read timed out', readTimeout));
    });

    void onCancel() {
      triggerAbort();
      cancelSub();
      finishError(const DanmuCancelledException());
    }

    sub = streamed.stream.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (cancelToken != null && cancelToken.isCancelled) {
          triggerAbort();
          cancelSub();
          finishError(const DanmuCancelledException());
          return;
        }
        if (bytes.length + chunk.length > maxPayloadBytes) {
          triggerAbort();
          cancelSub();
          finishError(
            const FormatException('Danmu payload exceeds 8 MB limit'),
          );
          return;
        }
        bytes.addAll(chunk);
      },
      onError: (Object err, StackTrace st) {
        if (!completer.isCompleted) {
          if (cancelToken != null && cancelToken.isCancelled) {
            completer.completeError(const DanmuCancelledException());
          } else {
            completer.completeError(err, st);
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          if (cancelToken != null && cancelToken.isCancelled) {
            completer.completeError(const DanmuCancelledException());
          } else {
            completer.complete(bytes);
          }
        }
      },
      cancelOnError: true,
    );

    if (completer.isCompleted) {
      cancelSub();
    }

    cancelToken?.onCancel(onCancel);
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      cancelToken?.removeCancelHook(onCancel);
    }
  }

  Future<String> _executeHttp({
    required String originKey,
    required Uri uri,
    required String method,
    String? jsonBody,
    DanmuCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    await _awaitRateLimit(originKey, cancelToken);

    var currentUri = uri;
    var currentMethod = method;
    var currentBody = jsonBody;

    for (var redirect = 0; redirect < 4; redirect++) {
      cancelToken?.throwIfCancelled();
      final abortCompleter = Completer<void>();
      final req = http.AbortableRequest(
        currentMethod,
        currentUri,
        abortTrigger: abortCompleter.future,
      )
        ..followRedirects = false
        ..headers['Accept'] = 'application/json, application/xml, text/xml, */*'
        ..headers['User-Agent'] = 'MarcoMovie-Danmu/1.0';

      if (_shouldSignRequestUri(currentUri, originKey)) {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        req.headers['X-AppId'] = appId;
        req.headers['X-Timestamp'] = ts.toString();
        req.headers['X-Signature'] = computeOpenApiSignature(
          appId: appId,
          timestampSec: ts,
          urlPath: currentUri.path,
          appSecret: appSecret,
        );
      }

      if (currentMethod == 'POST' && currentBody != null) {
        req.headers['Content-Type'] = 'application/json; charset=UTF-8';
        req.body = currentBody;
      }

      final streamed = await _sendAbortable(req, abortCompleter, cancelToken);
      if (cancelToken != null && cancelToken.isCancelled) {
        if (!abortCompleter.isCompleted) abortCompleter.complete();
        _discardStreamWithoutDrain(streamed);
        cancelToken.throwIfCancelled();
      }

      final status = streamed.statusCode;
      if (status == 301 ||
          status == 302 ||
          status == 303 ||
          status == 307 ||
          status == 308) {
        _discardStreamWithoutDrain(streamed);
        final loc = streamed.headers['location']?.trim() ?? '';
        if (loc.isEmpty) {
          throw const DanmuHttpException(302, 'Redirect missing Location header');
        }
        currentUri = _validateSegmentUri(loc, originKey);
        if (status == 303) {
          currentMethod = 'GET';
          currentBody = null;
        }
        continue;
      }

      if (status == 429) {
        _discardStreamWithoutDrain(streamed);
        final retryAfterMs = parseRetryAfterMs(streamed.headers['retry-after']);
        _recordBackoff(originKey, retryAfterMs);
        throw DanmuHttpException(
          429,
          'HTTP 429 Too Many Requests',
          retryAfterMs: retryAfterMs,
        );
      }
      if (status == 410) {
        _discardStreamWithoutDrain(streamed);
        throw const DanmuHttpException(410, 'HTTP 410 Segment Expired');
      }
      if (status < 200 || status >= 300) {
        _discardStreamWithoutDrain(streamed);
        throw DanmuHttpException(status, 'Danmu server returned HTTP $status');
      }

      final bytes = await _readBodyBytesAbortable(
        streamed,
        abortCompleter,
        cancelToken,
      );
      return utf8.decode(bytes, allowMalformed: true);
    }

    throw const FormatException('Too many danmu redirects');
  }

  // ---------------------------------------------------------------------------
  // Standard Danmu Payload Normalization (JSON / Simplified Array / XML)
  // ---------------------------------------------------------------------------

  static List<DanmuItem> parseDanmuPayload(
    String body, {
    int maxItems = maxFullEpisodeItems,
  }) {
    if (body.length > maxPayloadBytes) {
      throw const FormatException('Danmu payload exceeds 8 MB limit');
    }
    var content = body.trim();
    if (content.startsWith('\uFEFF')) {
      content = content.substring(1).trim();
    }
    if (content.isEmpty) return const <DanmuItem>[];

    final out = <DanmuItem>[];
    if (content.startsWith('<')) {
      _parseXmlPayload(content, out, maxItems);
    } else {
      _parseJsonPayload(content, out, maxItems);
    }
    return sortDedupAndCap(out, maxItems);
  }

  static void _parseXmlPayload(
    String content,
    List<DanmuItem> out,
    int maxItems,
  ) {
    final upper = content.toUpperCase();
    if (upper.contains('<!DOCTYPE') || upper.contains('<!ENTITY')) {
      throw const FormatException('XML danmu must not contain DOCTYPE or ENTITY');
    }
    final pattern = RegExp(
      r'''<d\b[^>]*\bp\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</d>''',
      caseSensitive: false,
    );
    var count = 0;
    for (final match in pattern.allMatches(content)) {
      if (count >= maxItems * 2) break;
      count++;
      final p = (match.group(1) ?? '').split(',');
      if (p.length < 4) continue;
      final timeSec = double.tryParse(p[0].trim());
      final modeRaw = int.tryParse(p[1].trim());
      final colorRaw = int.tryParse(p[3].trim());
      if (timeSec == null || modeRaw == null || colorRaw == null) continue;
      final id = p.length >= 8 ? p[7].trim() : '';
      final text = _unescapeXml(match.group(2) ?? '');
      _addNormalized(
        out,
        rawId: id,
        timeMs: (timeSec * 1000).round(),
        mode: normalizeMode(modeRaw),
        rgbColor: colorRaw & 0xFFFFFF,
        rawText: text,
      );
    }
  }

  static void _parseJsonPayload(
    String content,
    List<DanmuItem> out,
    int maxItems,
  ) {
    final root = jsonDecode(content);
    List<dynamic>? list;
    if (root is List) {
      list = root;
    } else if (root is Map) {
      for (final key in const [
        'comments',
        'danmuku',
        'danmaku',
        'danmu',
        'data',
        'list',
      ]) {
        if (root[key] is List) {
          list = root[key] as List;
          break;
        }
      }
      if (list == null && root['data'] is Map) {
        final inner = root['data'] as Map;
        for (final key in const [
          'comments',
          'danmuku',
          'danmaku',
          'danmu',
          'list',
        ]) {
          if (inner[key] is List) {
            list = inner[key] as List;
            break;
          }
        }
      }
    }
    if (list == null) return;
    final limit = math.min(maxItems * 2, list.length);
    for (var i = 0; i < limit; i++) {
      final entry = list[i];
      if (entry is List && entry.length >= 4) {
        final t = _toDouble(entry[0]);
        if (t == null) continue;
        final mode = normalizeMode(_toInt(entry[1]) ?? 1);
        final color = (_toInt(entry[2]) ?? 0xFFFFFF) & 0xFFFFFF;
        final text = entry[3]?.toString() ?? '';
        final id = entry.length > 4 ? _stringifyId(entry[4]) : '';
        _addNormalized(
          out,
          rawId: id,
          timeMs: (t * 1000).round(),
          mode: mode,
          rgbColor: color,
          rawText: text,
        );
      } else if (entry is Map) {
        final id = _stringifyId(entry.containsKey('cid') ? entry['cid'] : entry['id']);
        var timeMs = entry.containsKey('timeMs')
            ? (_toInt(entry['timeMs']) ?? -1)
            : ((_toDouble(entry['time'] ?? entry['t']) ?? 0.0) * 1000).round();
        var mode = normalizeMode(_toInt(entry['mode']) ?? 1);
        var color =
            (_toInt(entry['color'] ?? entry['rgbColor']) ?? 0xFFFFFF) & 0xFFFFFF;
        final text =
            (entry['m'] ?? entry['text'] ?? entry['content'] ?? '').toString();
        if (entry['p'] != null) {
          final p = entry['p'].toString().split(',');
          if (p.isNotEmpty) {
            final t = double.tryParse(p[0].trim());
            if (t != null) timeMs = (t * 1000).round();
          }
          if (p.length >= 2) {
            final m = int.tryParse(p[1].trim());
            if (m != null) mode = normalizeMode(m);
          }
          if (p.length >= 3) {
            final c = int.tryParse(p[2].trim());
            if (c != null) color = c & 0xFFFFFF;
          }
        }
        _addNormalized(
          out,
          rawId: id,
          timeMs: timeMs,
          mode: mode,
          rgbColor: color,
          rawText: text,
        );
      }
    }
  }

  static void _addNormalized(
    List<DanmuItem> out, {
    required String rawId,
    required int timeMs,
    required int mode,
    required int rgbColor,
    required String rawText,
  }) {
    if (timeMs < 0) return;
    final clean = _sanitizeText(rawText);
    if (clean.isEmpty) return;
    final id = rawId.trim().isNotEmpty
        ? rawId.trim()
        : 'h_${timeMs}_${mode}_${rgbColor & 0xFFFFFF}_${clean.hashCode.toUnsigned(32).toRadixString(16)}';
    out.add(
      DanmuItem(
        id: id,
        timeMs: timeMs,
        mode: mode,
        rgbColor: rgbColor & 0xFFFFFF,
        text: clean,
      ),
    );
  }

  static String _sanitizeText(String raw) {
    final sb = StringBuffer();
    for (var i = 0; i < raw.length && sb.length < maxTextLength; i++) {
      final code = raw.codeUnitAt(i);
      if (code < 0x20 || code == 0x7F) {
        sb.write(' ');
      } else {
        sb.writeCharCode(code);
      }
    }
    final trimmed = sb.toString().trim();
    return trimmed.length > maxTextLength
        ? trimmed.substring(0, maxTextLength)
        : trimmed;
  }

  static int normalizeMode(int mode) {
    if (mode == 4 || mode == 5) return mode;
    return 1;
  }

  static List<DanmuItem> sortDedupAndCap(List<DanmuItem> items, int maxItems) {
    if (items.isEmpty) return const <DanmuItem>[];
    final sorted = List<DanmuItem>.from(items)..sort(DanmuItem.compareOrder);
    final dedup = <String, DanmuItem>{};
    for (final item in sorted) {
      if (!dedup.containsKey(item.id)) {
        dedup[item.id] = item;
        if (dedup.length >= maxItems) break;
      }
    }
    return dedup.values.toList(growable: false);
  }

  static String _buildCleanFileName(DanmuMatchQuery query) {
    var t = _cleanTitle(query.title);
    if (t.isEmpty) return '';
    if (query.isMotionComic && !SeriesScraper.isMotionComicText(t)) {
      t = '$t 动态漫画';
    }
    if (query.episodeIndex > 0) {
      final padded = query.episodeIndex < 10
          ? '0${query.episodeIndex}'
          : '${query.episodeIndex}';
      if (query.seasonNumber != null && query.seasonNumber! > 0) {
        final sPad = query.seasonNumber! < 10
            ? '0${query.seasonNumber}'
            : '${query.seasonNumber}';
        return '$t S${sPad}E$padded';
      }
      return '$t E$padded';
    }
    final ep = _cleanTitle(query.episodeTitle);
    if (ep.isNotEmpty && ep.toLowerCase() != t.toLowerCase()) {
      return '$t $ep';
    }
    return t;
  }

  static String _cleanTitle(String raw) {
    final sanitized = raw
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (sanitized.isEmpty) return '';
    final cleaned = SeriesScraper.cleanSearchTitle(sanitized);
    return cleaned.isNotEmpty ? cleaned : sanitized;
  }

  static String _stringifyId(dynamic val) {
    if (val == null) return '';
    return val.toString().trim();
  }

  static double? _toDouble(dynamic val) {
    if (val is num) return val.toDouble();
    if (val is String) return double.tryParse(val.trim());
    return null;
  }

  static int? _toInt(dynamic val) {
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val.trim());
    return null;
  }

  static String _unescapeXml(String raw) {
    var s = raw.trim();
    if (s.startsWith('<![CDATA[') && s.endsWith(']]>')) {
      s = s.substring(9, s.length - 3);
    }
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'");
  }
}

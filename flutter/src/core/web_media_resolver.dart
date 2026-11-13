import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'cms_parser.dart';
import 'local_media_proxy.dart';
import 'models.dart';
import 'resilient_http_client.dart';
import 'source_playback.dart';

class WebSniffResult {
  final String url;
  final Map<String, String> headers;

  const WebSniffResult({
    required this.url,
    this.headers = const {},
  });
}

typedef WebSnifferInvoker = Future<WebSniffResult?> Function(
  String url,
  Map<String, String> headers,
  Duration timeout,
);

typedef ResolverTextFetcher = Future<ResolverHttpDocument> Function(
  String url, {
  Map<String, String> headers,
  Duration? timeout,
});

class ResolverHttpDocument {
  final Uri finalUri;
  final int statusCode;
  final Map<String, String> responseHeaders;
  final Map<String, String> effectiveRequestHeaders;
  final String body;
  final bool isDirectMediaResponse;

  const ResolverHttpDocument({
    required this.finalUri,
    required this.statusCode,
    required this.responseHeaders,
    required this.effectiveRequestHeaders,
    required this.body,
    this.isDirectMediaResponse = false,
  });
}

/// Multi-stage secondary playback resolver for cross-platform Flutter
/// (`Windows`, `macOS`, `iOS / iPadOS`):
///
/// 1. **Stage 1 (Parser Waterfall)**: Evaluates explicit `playUrl`, `site.playUrl`,
///    and `CmsConfig.parses` (`type` 1/2/3 JSON parsers + HTML wrapper parsers)
///    with strict credential-origin boundaries.
/// 2. **Stage 2 (Pure-Dart Webpage / MacCMS / Iframe Extractor)**: Unpacks
///    `player_aaaa` / `player_data` (`encrypt` 0/1/2), `<video>` / `<source>`,
///    JS player configs (`DPlayer`, `Artplayer`, `Aliplayer`, `Hls.js`),
///    `atob` / `decodeURIComponent` literals, and up to 2 hops of `<iframe>`
///    wrappers while preserving `Referer` and `Set-Cookie`.
/// 3. **Stage 3 (Native Ephemeral `WKWebView` Sniffer)**: Invokes
///    `marco_movie/web_sniffer` on iOS and macOS when dynamic JS execution is
///    required to materialize the stream URL.
class WebMediaResolver {
  static const MethodChannel _channel = MethodChannel('marco_movie/web_sniffer');

  static const String desktopBrowserUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.0 Safari/605.1.15';

  static WebSnifferInvoker? debugSnifferOverride;

  static final RegExp _directMediaExtPattern = RegExp(
    r'\.(?:m3u8?|mp4|flv|mkv|ts|webm|mpd|mov|m4v|avi)(?:$|[?#])',
    caseSensitive: false,
  );

  static final RegExp _directMediaHintPattern = RegExp(
    r'(?:\.(?:m3u8?|mp4|flv|mkv|webm|mpd|m4v)(?:$|[?#])|[?&](?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video))',
    caseSensitive: false,
  );

  static final RegExp _ignoredAssetExtPattern = RegExp(
    r'\.(?:js|mjs|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|eot|otf|json|xml|vtt|srt|ass|html?|php|asp|aspx|jsp)(?:$|[?#])',
    caseSensitive: false,
  );

  static final RegExp _webPageHintPattern = RegExp(
    r'(?:\.(?:s?html?|php|asp|aspx|jsp)(?:$|[?#])|/(?:vodplay|play|share|video|watch|v_show|x/cover|x/page|bangumi/play)(?:/|$|[?#]))',
    caseSensitive: false,
  );

  static bool isDirectStreamUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (const {'rtsp', 'rtmp', 'mms', 'udp', 'rtp'}.contains(scheme)) {
      return true;
    }
    if (scheme != 'http' && scheme != 'https') return false;
    return _directMediaExtPattern.hasMatch(uri.path);
  }

  static bool looksLikeWebPlayerPageUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    if (uri.host.isEmpty || isDirectStreamUrl(value)) return false;
    return _webPageHintPattern.hasMatch('${uri.path}?${uri.query}');
  }

  /// Returns `null` when [episode] can be played directly or resolved via
  /// source adapter, cloud-share resolver, parser waterfall (`site.playUrl` /
  /// [parses]), or `WebMediaResolver`; otherwise returns a user-facing Chinese
  /// diagnostic reason explaining why the episode is unavailable in the picker.
  static String? episodeUnavailableReason(
    CmsEpisode episode, {
    required CmsSite site,
    List<CmsParse> parses = const [],
  }) {
    final raw = episode.url.trim();
    if (raw.isEmpty) {
      return '当前剧集缺少有效播放地址';
    }
    if (episode.isDirectPlayable || episode.needsSourceResolution) {
      return null;
    }
    final lower = raw.toLowerCase();
    if (raw.startsWith('mmshare://') ||
        lower.startsWith('push://') ||
        ResilientHttpClient.cloudProviderForShare(raw) != null) {
      return null;
    }
    if (lower.startsWith('magnet:') ||
        lower.startsWith('ed2k://') ||
        lower.startsWith('thunder://')) {
      return '当前剧集为磁力 / P2P 链接，暂不支持直接播放';
    }
    final hasParser = site.playUrl.trim().isNotEmpty ||
        parses.any((p) => p.url.trim().isNotEmpty);
    if (hasParser || looksLikeWebPlayerPageUrl(raw)) {
      return null;
    }
    return '当前线路缺少可用解析配置（playUrl / parses），暂无法解析播放';
  }

  static bool canPlayOrResolveEpisode(
    CmsEpisode episode, {
    required CmsSite site,
    List<CmsParse> parses = const [],
  }) =>
      episodeUnavailableReason(episode, site: site, parses: parses) == null;

  static bool _isCandidateMediaUrl(
    String rawCandidate, {
    Uri? allowedOrigin,
    String? originalPageUrl,
  }) {
    final cleaned = rawCandidate.trim();
    if (cleaned.isEmpty ||
        cleaned.startsWith('blob:') ||
        cleaned.startsWith('data:') ||
        cleaned.startsWith('javascript:')) {
      return false;
    }
    if (originalPageUrl != null &&
        cleaned.toLowerCase() == originalPageUrl.trim().toLowerCase()) {
      return false;
    }
    final uri = Uri.tryParse(cleaned);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    if (!const {'http', 'https', 'rtsp', 'rtmp'}.contains(scheme)) {
      return false;
    }
    if ((scheme == 'http' || scheme == 'https') &&
        !_sameOrigin(uri, allowedOrigin) &&
        LocalMediaLease.isPrivateOrReservedTarget(uri)) {
      return false;
    }
    if (_ignoredAssetExtPattern.hasMatch(uri.path)) {
      return false;
    }
    return true;
  }

  static bool _looksStrongMediaUrl(
    String rawCandidate, {
    Uri? allowedOrigin,
    String? originalPageUrl,
  }) {
    if (!_isCandidateMediaUrl(
      rawCandidate,
      allowedOrigin: allowedOrigin,
      originalPageUrl: originalPageUrl,
    )) {
      return false;
    }
    final uri = Uri.parse(rawCandidate.trim());
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'rtsp' || scheme == 'rtmp') return true;
    return _directMediaHintPattern.hasMatch('${uri.path}?${uri.query}');
  }

  static bool _sameOrigin(Uri? a, Uri? b) {
    if (a == null || b == null) return false;
    final portA = a.hasPort ? a.port : (a.scheme.toLowerCase() == 'https' ? 443 : 80);
    final portB = b.hasPort ? b.port : (b.scheme.toLowerCase() == 'https' ? 443 : 80);
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        portA == portB;
  }

  static String _originString(Uri uri) {
    final defaultPort =
        (uri.scheme == 'https' && (!uri.hasPort || uri.port == 443)) ||
            (uri.scheme == 'http' && (!uri.hasPort || uri.port == 80));
    return '${uri.scheme}://${uri.host}${defaultPort ? '' : ':${uri.port}'}';
  }

  /// Resolves a secondary playback target into a `SourcePlayback.decode`-ready map
  /// (`{'url': ..., 'parse': 0, 'jx': 0, 'header': {...}}`), or returns `null`
  /// if no playable media stream could be extracted.
  static Future<Map<String, dynamic>?> resolve({
    required CmsSite site,
    required String targetUrl,
    String explicitPlayUrl = '',
    List<CmsParse> parses = const [],
    Map<String, String> extraHeaders = const {},
    Uri? sourceOrigin,
    required ResolverTextFetcher fetchDocument,
    bool Function()? isCancelled,
    WebSnifferInvoker? webSniffer,
  }) async {
    final trimmedTarget = targetUrl.trim();
    if (trimmedTarget.isEmpty) return null;

    bool cancelled() => isCancelled?.call() == true;

    final jsonParsers = <CmsParse>[];
    final webParsers = <CmsParse>[];
    final seenParserUrls = <String>{};

    void addParserCandidate(
      String rawPrefix, {
      int type = 1,
      Map<String, String> headers = const {},
      String name = '解析',
    }) {
      final prefix = rawPrefix.trim();
      if (!prefix.startsWith('http://') && !prefix.startsWith('https://')) {
        return;
      }
      if (!seenParserUrls.add(prefix)) return;
      final entry = CmsParse(
        name: name,
        url: prefix,
        type: type,
        headers: headers,
      );
      if (type == 0) {
        webParsers.add(entry);
      } else {
        jsonParsers.add(entry);
      }
    }

    if (explicitPlayUrl.trim().isNotEmpty) {
      addParserCandidate(explicitPlayUrl, type: 1, name: '线路解析');
    }
    if (site.playUrl.trim().isNotEmpty) {
      addParserCandidate(site.playUrl, type: 1, name: '站点解析');
    }
    for (final p in parses) {
      addParserCandidate(p.url, type: p.type, headers: p.headers, name: p.name);
    }

    // Stage 1: Try JSON / hybrid parsers (up to 6 candidates).
    final stage1 = await _tryParserList(
      parsers: jsonParsers.take(6),
      site: site,
      targetUrl: trimmedTarget,
      extraHeaders: extraHeaders,
      sourceOrigin: sourceOrigin,
      fetchDocument: fetchDocument,
      cancelled: cancelled,
    );
    if (stage1 != null) return stage1;
    if (cancelled()) return null;

    // Stage 2: If targetUrl is itself an HTTP(S) webpage, inspect it directly
    // (handles MacCMS player_aaaa, <video>, DPlayer/ArtPlayer, and <iframe>).
    final targetUri = Uri.tryParse(trimmedTarget);
    final isHttpTarget = targetUri != null &&
        (targetUri.scheme == 'http' || targetUri.scheme == 'https') &&
        targetUri.host.isNotEmpty;

    String? innerChainTarget;
    if (isHttpTarget) {
      final (extracted, nestedTarget) = await _extractFromWebPage(
        pageUrl: trimmedTarget,
        site: site,
        extraHeaders: extraHeaders,
        sourceOrigin: sourceOrigin,
        fetchDocument: fetchDocument,
        cancelled: cancelled,
        maxIframeDepth: 2,
      );
      if (extracted != null) return extracted;
      innerChainTarget = nestedTarget;
    }
    if (cancelled()) return null;

    // If MacCMS player_aaaa exposed an inner upstream URL/token (e.g. encrypt=2
    // wrapping an inner video URL), run Stage 1 parsers on that inner target!
    if (innerChainTarget != null &&
        innerChainTarget.isNotEmpty &&
        innerChainTarget != trimmedTarget) {
      final chainedJson = await _tryParserList(
        parsers: jsonParsers.take(6),
        site: site,
        targetUrl: innerChainTarget,
        extraHeaders: extraHeaders,
        sourceOrigin: sourceOrigin,
        fetchDocument: fetchDocument,
        cancelled: cancelled,
      );
      if (chainedJson != null) return chainedJson;

      final innerUri = Uri.tryParse(innerChainTarget);
      if (innerUri != null &&
          (innerUri.scheme == 'http' || innerUri.scheme == 'https') &&
          innerUri.host.isNotEmpty &&
          _isCandidateMediaUrl(innerChainTarget, allowedOrigin: targetUri)) {
        final (innerExtracted, _) = await _extractFromWebPage(
          pageUrl: innerChainTarget,
          site: site,
          extraHeaders: {
            ...extraHeaders,
            'Referer': trimmedTarget,
          },
          sourceOrigin: sourceOrigin,
          fetchDocument: fetchDocument,
          cancelled: cancelled,
          maxIframeDepth: 1,
        );
        if (innerExtracted != null) return innerExtracted;
      }
    }
    if (cancelled()) return null;

    // Stage 2B: Try configured type-0 web parsers via static HTML / iframe extraction.
    final effectiveTargetForWebParser =
        (innerChainTarget != null && innerChainTarget.isNotEmpty)
            ? innerChainTarget
            : trimmedTarget;
    for (final webParser in webParsers.take(3)) {
      if (cancelled()) return null;
      final wrappedUrl =
          '${webParser.url}${Uri.encodeComponent(effectiveTargetForWebParser)}';
      final (extracted, _) = await _extractFromWebPage(
        pageUrl: wrappedUrl,
        site: site,
        extraHeaders: {
          ...extraHeaders,
          ...webParser.headers,
        },
        sourceOrigin: sourceOrigin,
        fetchDocument: fetchDocument,
        cancelled: cancelled,
        maxIframeDepth: 1,
        originalTargetUrl: effectiveTargetForWebParser,
      );
      if (extracted != null) return extracted;
    }
    if (cancelled()) return null;

    // Stage 3: Native ephemeral WKWebView sniffer (iOS / macOS, or injected test double).
    final sniffer = webSniffer ?? debugSnifferOverride ?? _invokePlatformSniffer;
    final sniffCandidates = <String>[];
    if (webParsers.isNotEmpty) {
      sniffCandidates.add(
        '${webParsers.first.url}${Uri.encodeComponent(effectiveTargetForWebParser)}',
      );
    } else if (explicitPlayUrl.startsWith('http://') ||
        explicitPlayUrl.startsWith('https://')) {
      sniffCandidates.add(
        '${explicitPlayUrl.trim()}${Uri.encodeComponent(effectiveTargetForWebParser)}',
      );
    } else if (site.playUrl.startsWith('http://') ||
        site.playUrl.startsWith('https://')) {
      sniffCandidates.add(
        '${site.playUrl.trim()}${Uri.encodeComponent(effectiveTargetForWebParser)}',
      );
    }
    if (isHttpTarget && !sniffCandidates.contains(trimmedTarget)) {
      sniffCandidates.add(trimmedTarget);
    }

    for (final sniffUrl in sniffCandidates.take(2)) {
      if (cancelled()) return null;
      final sniffUri = Uri.tryParse(sniffUrl);
      if (sniffUri == null) continue;
      final sniffHeaders = _mergeHeaders([
        SourcePlayback.headersForOrigin(site.headers, sourceOrigin, sniffUri),
        SourcePlayback.headersForOrigin(extraHeaders, sourceOrigin, sniffUri),
      ]);
      final sniffed = await sniffer(
        sniffUrl,
        sniffHeaders,
        const Duration(seconds: 12),
      );
      if (sniffed != null &&
          _isCandidateMediaUrl(
            sniffed.url,
            allowedOrigin: sniffUri,
            originalPageUrl: sniffUrl,
          )) {
        final mediaHeaders = <String, String>{
          'Referer': sniffUrl,
          ...sniffed.headers,
        };
        return <String, dynamic>{
          'url': sniffed.url.trim(),
          'parse': 0,
          'jx': 0,
          'header': mediaHeaders,
        };
      }
    }

    return null;
  }

  static Future<Map<String, dynamic>?> _tryParserList({
    required Iterable<CmsParse> parsers,
    required CmsSite site,
    required String targetUrl,
    required Map<String, String> extraHeaders,
    required Uri? sourceOrigin,
    required ResolverTextFetcher fetchDocument,
    required bool Function() cancelled,
  }) async {
    for (final parser in parsers) {
      if (cancelled()) return null;
      final parserUrl = '${parser.url}${Uri.encodeComponent(targetUrl)}';
      final parserUri = Uri.tryParse(parserUrl);
      if (parserUri == null) continue;
      final reqHeaders = _mergeHeaders([
        SourcePlayback.headersForOrigin(site.headers, sourceOrigin, parserUri),
        SourcePlayback.headersForOrigin(extraHeaders, sourceOrigin, parserUri),
        parser.headers,
      ]);
      try {
        final doc = await fetchDocument(
          parserUrl,
          headers: reqHeaders,
          timeout: const Duration(seconds: 8),
        );
        if (doc.isDirectMediaResponse &&
            _isCandidateMediaUrl(
              doc.finalUri.toString(),
              allowedOrigin: parserUri,
              originalPageUrl: targetUrl,
            )) {
          return _buildResolvedMap(
            mediaUrl: doc.finalUri.toString(),
            pageUri: parserUri,
            effectiveRequestHeaders: doc.effectiveRequestHeaders,
          );
        }
        final fromJson = _tryDecodeParserJson(
          doc.body,
          allowedOrigin: doc.finalUri,
          originalTargetUrl: targetUrl,
        );
        if (fromJson != null) return fromJson;

        // Many CMS playUrl prefixes return an HTML player wrapper rather than JSON.
        final (fromHtml, _) = _extractFromHtmlText(
          html: doc.body,
          pageUri: doc.finalUri,
          effectiveRequestHeaders: doc.effectiveRequestHeaders,
          originalTargetUrl: targetUrl,
        );
        if (fromHtml != null) return fromHtml;
      } catch (_) {
        // Continue to next backup parser in waterfall.
      }
    }
    return null;
  }

  static Map<String, dynamic>? _tryDecodeParserJson(
    String rawBody, {
    required Uri allowedOrigin,
    required String originalTargetUrl,
  }) {
    final trimmed = rawBody.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(CmsParser.stripJsonComments(trimmed));
      if (decoded is! Map) return null;

      Map<String, dynamic>? candidateMap;
      String mediaUrl = (decoded['url'] ?? '').toString().trim();
      if (mediaUrl.isNotEmpty) {
        candidateMap = Map<String, dynamic>.from(decoded);
      } else if (decoded['data'] is Map) {
        final dataMap = Map<String, dynamic>.from(decoded['data'] as Map);
        mediaUrl = (dataMap['url'] ?? dataMap['playUrl'] ?? '').toString().trim();
        if (mediaUrl.isNotEmpty) {
          candidateMap = dataMap;
        }
      }
      if (candidateMap == null || mediaUrl.isEmpty) return null;
      if (mediaUrl.startsWith('//')) {
        mediaUrl = '${allowedOrigin.scheme}:$mediaUrl';
      }
      if (!_isCandidateMediaUrl(
        mediaUrl,
        allowedOrigin: allowedOrigin,
        originalPageUrl: originalTargetUrl,
      )) {
        return null;
      }
      // Do not accept another HTML page masquerading as a parsed stream URL.
      if (looksLikeWebPlayerPageUrl(mediaUrl) && !isDirectStreamUrl(mediaUrl)) {
        return null;
      }

      final explicitHeaders = <String, String>{};
      final rawHeader = candidateMap['header'] ?? candidateMap['headers'];
      if (rawHeader is Map) {
        rawHeader.forEach((k, v) {
          if (v != null && v.toString().trim().isNotEmpty) {
            explicitHeaders[k.toString()] = v.toString().trim();
          }
        });
      } else if (rawHeader is String && rawHeader.trim().startsWith('{')) {
        try {
          final parsedH = jsonDecode(rawHeader);
          if (parsedH is Map) {
            parsedH.forEach((k, v) {
              if (v != null && v.toString().trim().isNotEmpty) {
                explicitHeaders[k.toString()] = v.toString().trim();
              }
            });
          }
        } catch (_) {}
      }
      final ua = (candidateMap['ua'] ?? candidateMap['user-agent'] ?? '')
          .toString()
          .trim();
      final referer = (candidateMap['referer'] ?? '').toString().trim();
      if (ua.isNotEmpty &&
          !explicitHeaders.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        explicitHeaders['User-Agent'] = ua;
      }
      if (referer.isNotEmpty &&
          !explicitHeaders.keys.any((k) => k.toLowerCase() == 'referer')) {
        explicitHeaders['Referer'] = referer;
      }

      final out = Map<String, dynamic>.from(candidateMap)
        ..['url'] = mediaUrl
        ..['parse'] = 0
        ..['jx'] = 0;
      if (explicitHeaders.isNotEmpty) {
        out['header'] = explicitHeaders;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static Future<(Map<String, dynamic>?, String?)> _extractFromWebPage({
    required String pageUrl,
    required CmsSite site,
    required Map<String, String> extraHeaders,
    required Uri? sourceOrigin,
    required ResolverTextFetcher fetchDocument,
    required bool Function() cancelled,
    required int maxIframeDepth,
    String? originalTargetUrl,
  }) async {
    var currentUrl = pageUrl;
    var refererHeader = extraHeaders['Referer'] ?? extraHeaders['referer'];

    for (var depth = 0; depth <= maxIframeDepth; depth++) {
      if (cancelled()) return (null, null);
      final currentUri = Uri.tryParse(currentUrl);
      if (currentUri == null) return (null, null);

      final reqHeaders = _mergeHeaders([
        {'User-Agent': desktopBrowserUa},
        SourcePlayback.headersForOrigin(site.headers, sourceOrigin, currentUri),
        SourcePlayback.headersForOrigin(extraHeaders, sourceOrigin, currentUri),
        if (refererHeader != null && refererHeader.isNotEmpty)
          {'Referer': refererHeader},
      ]);

      ResolverHttpDocument doc;
      try {
        doc = await fetchDocument(
          currentUrl,
          headers: reqHeaders,
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {
        return (null, null);
      }

      if (doc.isDirectMediaResponse &&
          _isCandidateMediaUrl(
            doc.finalUri.toString(),
            allowedOrigin: currentUri,
            originalPageUrl: originalTargetUrl,
          )) {
        return (
          _buildResolvedMap(
            mediaUrl: doc.finalUri.toString(),
            pageUri: currentUri,
            effectiveRequestHeaders: doc.effectiveRequestHeaders,
          ),
          null,
        );
      }

      final fromJson = _tryDecodeParserJson(
        doc.body,
        allowedOrigin: doc.finalUri,
        originalTargetUrl: originalTargetUrl ?? pageUrl,
      );
      if (fromJson != null) return (fromJson, null);

      final (fromHtml, nestedTarget) = _extractFromHtmlText(
        html: doc.body,
        pageUri: doc.finalUri,
        effectiveRequestHeaders: doc.effectiveRequestHeaders,
        originalTargetUrl: originalTargetUrl ?? pageUrl,
      );
      if (fromHtml != null) return (fromHtml, null);
      if (nestedTarget != null && nestedTarget.isNotEmpty) {
        return (null, nestedTarget);
      }

      if (depth >= maxIframeDepth) break;
      final iframeUrl = _extractFirstPlayerIframe(doc.body, doc.finalUri);
      if (iframeUrl == null || iframeUrl == currentUrl) break;
      refererHeader = doc.finalUri.toString();
      currentUrl = iframeUrl;
    }

    return (null, null);
  }

  static (Map<String, dynamic>?, String?) _extractFromHtmlText({
    required String html,
    required Uri pageUri,
    required Map<String, String> effectiveRequestHeaders,
    String? originalTargetUrl,
  }) {
    if (html.trim().isEmpty) return (null, null);

    // 1. MacCMS v10 `player_aaaa` / `player_data` JSON object.
    String? nestedChainTarget;
    for (final marker in const ['player_aaaa', 'player_data']) {
      final objText = _extractAssignedJsonObject(html, marker);
      if (objText == null) continue;
      final parsedPlayer = _parseMacCmsPlayerObject(objText, pageUri);
      if (parsedPlayer != null) {
        final (candidateUrl, extraPlayerHeaders) = parsedPlayer;
        if (_looksStrongMediaUrl(
          candidateUrl,
          allowedOrigin: pageUri,
          originalPageUrl: originalTargetUrl,
        )) {
          return (
            _buildResolvedMap(
              mediaUrl: candidateUrl,
              pageUri: pageUri,
              effectiveRequestHeaders: effectiveRequestHeaders,
              extraHeaders: extraPlayerHeaders,
            ),
            null,
          );
        }
        if (candidateUrl.isNotEmpty &&
            candidateUrl != pageUri.toString() &&
            candidateUrl != originalTargetUrl) {
          nestedChainTarget ??= candidateUrl;
        }
      }
    }

    // 2. HTML <video src="..."> and <source src="..."> elements.
    for (final tagPattern in [
      RegExp(r'<video\b[^>]*?\bsrc\s*=\s*["\x27]([^"\x27]+)["\x27]',
          caseSensitive: false),
      RegExp(r'<source\b[^>]*?\bsrc\s*=\s*["\x27]([^"\x27]+)["\x27]',
          caseSensitive: false),
    ]) {
      for (final match in tagPattern.allMatches(html)) {
        final rawSrc = _unescapeJsUrl(match.group(1) ?? '');
        final resolved = _resolveRelativeCandidate(pageUri, rawSrc);
        if (resolved != null &&
            _isCandidateMediaUrl(
              resolved,
              allowedOrigin: pageUri,
              originalPageUrl: originalTargetUrl,
            ) &&
            !looksLikeWebPlayerPageUrl(resolved)) {
          return (
            _buildResolvedMap(
              mediaUrl: resolved,
              pageUri: pageUri,
              effectiveRequestHeaders: effectiveRequestHeaders,
            ),
            null,
          );
        }
      }
    }

    // 3. Base64 `atob("...")` and `decodeURIComponent("...")` obfuscated media URLs.
    for (final atobMatch in RegExp(
      r'atob\(\s*["\x27]([A-Za-z0-9+/=%]{16,})["\x27]\s*\)',
    ).allMatches(html)) {
      final decoded = _tryDecodeBase64String(atobMatch.group(1)!);
      if (decoded != null) {
        final candidate = _resolveRelativeCandidate(pageUri, _unescapeJsUrl(decoded));
        if (candidate != null &&
            _looksStrongMediaUrl(
              candidate,
              allowedOrigin: pageUri,
              originalPageUrl: originalTargetUrl,
            )) {
          return (
            _buildResolvedMap(
              mediaUrl: candidate,
              pageUri: pageUri,
              effectiveRequestHeaders: effectiveRequestHeaders,
            ),
            null,
          );
        }
      }
    }

    for (final uriCompMatch in RegExp(
      r'decodeURIComponent\(\s*["\x27]([^"\x27]{16,})["\x27]\s*\)',
    ).allMatches(html)) {
      try {
        final decoded = Uri.decodeComponent(uriCompMatch.group(1)!);
        final candidate = _resolveRelativeCandidate(pageUri, _unescapeJsUrl(decoded));
        if (candidate != null &&
            _looksStrongMediaUrl(
              candidate,
              allowedOrigin: pageUri,
              originalPageUrl: originalTargetUrl,
            )) {
          return (
            _buildResolvedMap(
              mediaUrl: candidate,
              pageUri: pageUri,
              effectiveRequestHeaders: effectiveRequestHeaders,
            ),
            null,
          );
        }
      } catch (_) {}
    }

    // 4. JS player configuration properties (`url`, `vurl`, `playurl`, `hlsUrl`, `file`).
    final normalizedHtml = _unescapeHexAndSlashes(html);
    final keyedMediaPattern = RegExp(
      r'(?:["\x27]?(?:url|vurl|playurl|playUrl|videoUrl|hlsUrl|file|main)["\x27]?)\s*[:=]\s*["\x27]((?:https?:)?//[^"\x27<>\\\s]+|/[^"\x27<>\\\s]+\.(?:m3u8|mp4|flv|mkv|mpd|webm)(?:\?[^"\x27<>\\\s]*)?)["\x27]',
      caseSensitive: false,
    );
    for (final match in keyedMediaPattern.allMatches(normalizedHtml)) {
      final resolved = _resolveRelativeCandidate(pageUri, match.group(1) ?? '');
      if (resolved != null &&
          _looksStrongMediaUrl(
            resolved,
            allowedOrigin: pageUri,
            originalPageUrl: originalTargetUrl,
          )) {
        return (
          _buildResolvedMap(
            mediaUrl: resolved,
            pageUri: pageUri,
            effectiveRequestHeaders: effectiveRequestHeaders,
          ),
          null,
        );
      }
    }

    // 5. Direct full HTTP(S) media literals embedded in script blocks.
    final rawMediaLiteralPattern = RegExp(
      r'https?://[^\s"\x27<>\\]+?\.(?:m3u8|mp4|flv|mkv|mpd|webm|m4v)(?:\?[^\s"\x27<>\\]*)?',
      caseSensitive: false,
    );
    for (final match in rawMediaLiteralPattern.allMatches(normalizedHtml)) {
      final candidate = _unescapeHtmlEntities(match.group(0)!);
      if (_looksStrongMediaUrl(
        candidate,
        allowedOrigin: pageUri,
        originalPageUrl: originalTargetUrl,
      )) {
        return (
          _buildResolvedMap(
            mediaUrl: candidate,
            pageUri: pageUri,
            effectiveRequestHeaders: effectiveRequestHeaders,
          ),
          null,
        );
      }
    }

    return (null, nestedChainTarget);
  }

  static Map<String, dynamic> _buildResolvedMap({
    required String mediaUrl,
    required Uri pageUri,
    required Map<String, String> effectiveRequestHeaders,
    Map<String, String> extraHeaders = const {},
  }) {
    final mediaUri = Uri.tryParse(mediaUrl);
    final headers = <String, String>{
      'Referer': pageUri.toString(),
      'Origin': _originString(pageUri),
    };
    for (final entry in effectiveRequestHeaders.entries) {
      final lower = entry.key.toLowerCase();
      if (lower == 'user-agent') {
        headers['User-Agent'] = entry.value;
      } else if (lower == 'cookie' && _sameOrigin(pageUri, mediaUri)) {
        headers['Cookie'] = entry.value;
      }
    }
    headers.putIfAbsent('User-Agent', () => desktopBrowserUa);
    headers.addAll(extraHeaders);
    return <String, dynamic>{
      'url': mediaUrl,
      'parse': 0,
      'jx': 0,
      'header': headers,
    };
  }

  static String? _extractAssignedJsonObject(String html, String variableName) {
    final assignMatch = RegExp(
      '\\b${RegExp.escape(variableName)}\\s*=\\s*\\{',
    ).firstMatch(html);
    if (assignMatch == null) return null;
    final startBrace = assignMatch.end - 1;
    var depth = 0;
    var inString = false;
    var quoteChar = 0;
    var escaped = false;
    final limit = (startBrace + 65536).clamp(0, html.length);
    for (var i = startBrace; i < limit; i++) {
      final ch = html.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == 0x5C /* \ */) {
          escaped = true;
        } else if (ch == quoteChar) {
          inString = false;
        }
        continue;
      }
      if (ch == 0x22 /* " */ || ch == 0x27 /* ' */) {
        inString = true;
        quoteChar = ch;
      } else if (ch == 0x7B /* { */) {
        depth++;
      } else if (ch == 0x7D /* } */) {
        depth--;
        if (depth == 0) {
          return html.substring(startBrace, i + 1);
        }
      }
    }
    return null;
  }

  static (String, Map<String, String>)? _parseMacCmsPlayerObject(
    String jsonText,
    Uri pageUri,
  ) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) return null;
      var rawUrl = (decoded['url'] ?? '').toString().trim();
      if (rawUrl.isEmpty) return null;
      final encrypt = int.tryParse('${decoded['encrypt'] ?? 0}') ?? 0;
      if (encrypt == 1) {
        try {
          rawUrl = Uri.decodeComponent(rawUrl);
        } catch (_) {}
      } else if (encrypt == 2) {
        final b64 = _tryDecodeBase64String(rawUrl);
        if (b64 != null) {
          try {
            rawUrl = Uri.decodeComponent(b64);
          } catch (_) {
            rawUrl = b64;
          }
        }
      }
      rawUrl = _unescapeJsUrl(rawUrl);
      final resolved = _resolveRelativeCandidate(pageUri, rawUrl) ?? rawUrl;
      final extraHeaders = <String, String>{};
      if (decoded['headers'] is Map) {
        (decoded['headers'] as Map).forEach((k, v) {
          if (v != null && v.toString().trim().isNotEmpty) {
            extraHeaders[k.toString()] = v.toString().trim();
          }
        });
      }
      return (resolved, extraHeaders);
    } catch (_) {
      return null;
    }
  }

  static String? _extractFirstPlayerIframe(String html, Uri pageUri) {
    final iframePattern = RegExp(
      r'<iframe\b[^>]*?\bsrc\s*=\s*["\x27]([^"\x27]+)["\x27]',
      caseSensitive: false,
    );
    for (final match in iframePattern.allMatches(html)) {
      final rawSrc = _unescapeHtmlEntities(_unescapeJsUrl(match.group(1) ?? ''));
      if (rawSrc.isEmpty ||
          rawSrc.startsWith('about:') ||
          rawSrc.startsWith('javascript:') ||
          rawSrc.startsWith('data:')) {
        continue;
      }
      final resolved = _resolveRelativeCandidate(pageUri, rawSrc);
      if (resolved == null) continue;
      final uri = Uri.tryParse(resolved);
      if (uri == null || uri.host.isEmpty) continue;
      final lower = resolved.toLowerCase();
      if (lower.contains('googletagmanager') ||
          lower.contains('google-analytics') ||
          lower.contains('hm.baidu.com') ||
          lower.contains('doubleclick.net') ||
          lower.contains('/ads/') ||
          lower.contains('adservice')) {
        continue;
      }
      if (!_sameOrigin(uri, pageUri) &&
          LocalMediaLease.isPrivateOrReservedTarget(uri)) {
        continue;
      }
      return resolved;
    }
    return null;
  }

  static String? _resolveRelativeCandidate(Uri baseUri, String rawCandidate) {
    final cleaned = _unescapeHtmlEntities(rawCandidate.trim());
    if (cleaned.isEmpty ||
        cleaned.startsWith('blob:') ||
        cleaned.startsWith('data:') ||
        cleaned.startsWith('javascript:')) {
      return null;
    }
    try {
      if (cleaned.startsWith('rtmp://') || cleaned.startsWith('rtsp://')) {
        return cleaned;
      }
      return baseUri.resolve(cleaned).toString();
    } catch (_) {
      return null;
    }
  }

  static String? _tryDecodeBase64String(String raw) {
    var cleaned = raw.trim();
    if (cleaned.contains('%')) {
      try {
        cleaned = Uri.decodeComponent(cleaned);
      } catch (_) {}
    }
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), '');
    if (cleaned.length < 8) return null;
    final mod = cleaned.length % 4;
    if (mod == 1) return null;
    if (mod > 0) {
      cleaned = cleaned.padRight(cleaned.length + (4 - mod), '=');
    }
    try {
      final bytes = base64Decode(cleaned);
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isEmpty || text.codeUnits.any((c) => c < 0x09)) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  static String _unescapeJsUrl(String input) => input
      .trim()
      .replaceAll(r'\/', '/')
      .replaceAllMapped(
        RegExp(r'\\x([0-9a-fA-F]{2})'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'\\u([0-9a-fA-F]{4})'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      );

  static String _unescapeHexAndSlashes(String input) => input
      .replaceAll(r'\/', '/')
      .replaceAllMapped(
        RegExp(r'\\x([0-9a-fA-F]{2})'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'\\u00([0-9a-fA-F]{2})'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      );

  static String _unescapeHtmlEntities(String input) => input
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&#x26;', '&');

  static Map<String, String> _mergeHeaders(Iterable<Map<String, String>> layers) {
    final merged = <String, String>{};
    for (final layer in layers) {
      for (final entry in layer.entries) {
        merged.removeWhere((k, _) => k.toLowerCase() == entry.key.toLowerCase());
        merged[entry.key] = entry.value;
      }
    }
    return merged;
  }

  static Future<WebSniffResult?> _invokePlatformSniffer(
    String url,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    if (!Platform.isIOS && !Platform.isMacOS) return null;
    try {
      final response = await _channel
          .invokeMapMethod<String, dynamic>('sniffMedia', <String, dynamic>{
        'url': url,
        'headers': headers,
        'timeoutMs': timeout.inMilliseconds,
      }).timeout(timeout + const Duration(seconds: 2), onTimeout: () => null);
      if (response == null) return null;
      final mediaUrl = (response['url'] ?? '').toString().trim();
      if (mediaUrl.isEmpty) return null;
      final outHeaders = <String, String>{};
      final rawHeaders = response['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((k, v) {
          if (v != null && v.toString().trim().isNotEmpty) {
            outHeaders[k.toString()] = v.toString().trim();
          }
        });
      }
      return WebSniffResult(url: mediaUrl, headers: outHeaders);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Helper used by `CmsClient` to probe a parser/webpage URL without downloading
  /// multi-megabyte video bodies if the URL already redirects/responds with media.
  static bool looksLikeBinaryMediaResponse(
    Map<String, String> responseHeaders,
    Uint8List prefix,
  ) {
    final ct = (responseHeaders['content-type'] ?? '').toLowerCase();
    if (ct.contains('video/') ||
        ct.contains('audio/') ||
        ct.contains('mpegurl') ||
        ct.contains('dash+xml')) {
      return true;
    }
    if (prefix.length >= 7) {
      var s = 0;
      if (prefix[0] == 0xEF && prefix[1] == 0xBB && prefix[2] == 0xBF) s = 3;
      while (s < prefix.length &&
          (prefix[s] == 0x20 ||
              prefix[s] == 0x09 ||
              prefix[s] == 0x0D ||
              prefix[s] == 0x0A)) {
        s++;
      }
      if (s + 7 <= prefix.length &&
          latin1.decode(prefix.sublist(s, s + 7), allowInvalid: true) ==
              '#EXTM3U') {
        return true;
      }
    }
    if (prefix.length >= 8) {
      final box = latin1.decode(prefix.sublist(4, 8), allowInvalid: true);
      if (const {'ftyp', 'styp', 'moof', 'moov', 'mdat'}.contains(box)) {
        return true;
      }
    }
    if (prefix.length >= 4 &&
        ((prefix[0] == 0x46 && prefix[1] == 0x4C && prefix[2] == 0x56) ||
            (prefix[0] == 0x1A &&
                prefix[1] == 0x45 &&
                prefix[2] == 0xDF &&
                prefix[3] == 0xA3))) {
      return true;
    }
    return false;
  }

  /// Extracts `name=value` cookie pairs from an HTTP `Set-Cookie` header that
  /// are valid for [requestUri], scoped safely for redirect hops.
  static List<({String name, String value, String domain, bool hostOnly, String path})>
      parseRedirectSetCookies(Map<String, String> responseHeaders, Uri requestUri) {
    String? rawSetCookie;
    for (final entry in responseHeaders.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        rawSetCookie = entry.value;
        break;
      }
    }
    if (rawSetCookie == null || rawSetCookie.trim().isEmpty) return const [];

    final pieces = <String>[];
    var start = 0;
    var inExpires = false;
    for (var i = 0; i < rawSetCookie.length; i++) {
      final ch = rawSetCookie.codeUnitAt(i);
      if (ch == 0x3B) {
        inExpires = false;
      } else if (!inExpires &&
          i + 8 <= rawSetCookie.length &&
          rawSetCookie.substring(i, i + 8).toLowerCase() == 'expires=') {
        inExpires = true;
      } else if (ch == 0x2C) {
        if (inExpires) {
          inExpires = false;
          continue;
        }
        final rest = rawSetCookie.substring(i + 1).trimLeft();
        final semi = rest.indexOf(';');
        final eq = rest.indexOf('=');
        if (eq > 0 && (semi < 0 || eq < semi)) {
          final part = rawSetCookie.substring(start, i).trim();
          if (part.isNotEmpty) pieces.add(part);
          start = i + 1;
        }
      }
    }
    final tail = rawSetCookie.substring(start).trim();
    if (tail.isNotEmpty) pieces.add(tail);

    final reqHost = requestUri.host.toLowerCase();
    final out =
        <({String name, String value, String domain, bool hostOnly, String path})>[];
    for (final piece in pieces) {
      final attrs = piece.split(';');
      if (attrs.isEmpty) continue;
      final nv = attrs.first.trim();
      final eq = nv.indexOf('=');
      if (eq <= 0) continue;
      final name = nv.substring(0, eq).trim();
      final value = nv.substring(eq + 1).trim();
      if (name.isEmpty) continue;

      var domain = reqHost;
      var hostOnly = true;
      var path = '/';
      var expired = value.isEmpty;

      for (final rawAttr in attrs.skip(1)) {
        final attr = rawAttr.trim();
        if (attr.isEmpty) continue;
        final aEq = attr.indexOf('=');
        final aKey =
            (aEq < 0 ? attr : attr.substring(0, aEq)).trim().toLowerCase();
        final aVal = aEq < 0 ? '' : attr.substring(aEq + 1).trim();
        if (aKey == 'domain' && aVal.isNotEmpty) {
          final clean = aVal.replaceFirst(RegExp(r'^\.+'), '').toLowerCase();
          if (clean.contains('.') &&
              InternetAddress.tryParse(clean) == null &&
              (reqHost == clean || reqHost.endsWith('.$clean'))) {
            domain = clean;
            hostOnly = false;
          }
        } else if (aKey == 'path' && aVal.startsWith('/')) {
          path = aVal;
        } else if (aKey == 'max-age') {
          final secs = int.tryParse(aVal);
          if (secs != null && secs <= 0) expired = true;
        }
      }

      if (!expired) {
        out.add((
          name: name,
          value: value,
          domain: domain,
          hostOnly: hostOnly,
          path: path,
        ));
      }
    }
    return out;
  }

  static bool redirectCookieMatches(
    ({String name, String value, String domain, bool hostOnly, String path}) cookie,
    Uri targetUri,
  ) {
    final host = targetUri.host.toLowerCase();
    if (cookie.hostOnly) {
      if (host != cookie.domain) return false;
    } else {
      if (host != cookie.domain && !host.endsWith('.${cookie.domain}')) {
        return false;
      }
    }
    final reqPath = targetUri.path.isEmpty ? '/' : targetUri.path;
    if (cookie.path == '/' || reqPath == cookie.path) return true;
    if (reqPath.startsWith(cookie.path)) {
      return cookie.path.endsWith('/') ||
          reqPath.codeUnitAt(cookie.path.length) == 0x2F;
    }
    return false;
  }
}

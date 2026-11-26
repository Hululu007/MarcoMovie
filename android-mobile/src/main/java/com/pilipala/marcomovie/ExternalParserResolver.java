package com.pilipala.marcomovie;

import java.net.URI;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import org.json.JSONObject;

/**
 * Pure-JVM external parser selection, JSON response validation, and URL assembly (Item 14: 原 14).
 *
 * <p>Fixes the external parser execution chain:
 *
 * <ul>
 *   <li>Flag-aware parser prioritization (matches {@code lineFlag} against {@code parse.flags}
 *       before falling back to generic parsers, instead of blindly truncating at index 4).
 *   <li>Strict JSON response validation (rejects HTTP/API error codes, non-media VIP web pages, and
 *       HTML error URLs; extracts nested {@code data.url}, normalizes {@code //cdn...}, handles
 *       nested {@code parse: 1} WebView handoff, and reads both {@code header} and {@code headers}).
 *   <li>Proper URL encoding when concatenating an episode URL onto a query-based parser prefix.
 * </ul>
 */
final class ExternalParserResolver {
    private static final String[] VIP_WEB_HOSTS = {
        "v.qq.com",
        "iqiyi.com",
        "youku.com",
        "mgtv.com",
        "le.com",
        "sohu.com",
        "pptv.com",
        "1905.com",
        "bilibili.com",
        "ixigua.com"
    };

    static final class ParsedResult {
        final boolean ok;
        final boolean needsWebSniff;
        final String url;
        final Map<String, String> headers;
        final JSONObject rawJson;
        final String rejectReason;

        ParsedResult(
                boolean ok,
                boolean needsWebSniff,
                String url,
                Map<String, String> headers,
                JSONObject rawJson,
                String rejectReason) {
            this.ok = ok;
            this.needsWebSniff = needsWebSniff;
            this.url = url == null ? "" : url;
            this.headers =
                    headers == null
                            ? Collections.<String, String>emptyMap()
                            : new LinkedHashMap<>(headers);
            this.rawJson = rawJson;
            this.rejectReason = rejectReason == null ? "" : rejectReason;
        }
    }

    interface HttpFetcher {
        String fetch(String url, Map<String, String> headers) throws Exception;
    }

    interface EmbeddedExtractor {
        String extract(String pageUrl, String html);
    }

    static final class ResolutionOutcome {
        static final String KIND_DIRECT_EMBEDDED = "direct_embedded";
        static final String KIND_JSON_PARSER = "json_parser";
        static final String KIND_WEB_SNIFF = "web_sniff";
        static final String KIND_WEB_PARSER = "web_parser";
        static final String KIND_DIRECT_URL = "direct_url";
        static final String KIND_FAILED = "failed";

        final String kind;
        final String url;
        final Map<String, String> headers;
        final JSONObject rawJson;
        final String matchedParserName;
        final String matchedParserUrl;
        final String webPrefix;
        final String error;

        ResolutionOutcome(
                String kind,
                String url,
                Map<String, String> headers,
                JSONObject rawJson,
                String matchedParserName,
                String matchedParserUrl,
                String webPrefix,
                String error) {
            this.kind = kind;
            this.url = url == null ? "" : url;
            this.headers =
                    headers == null
                            ? Collections.<String, String>emptyMap()
                            : new LinkedHashMap<>(headers);
            this.rawJson = rawJson;
            this.matchedParserName = matchedParserName == null ? "" : matchedParserName;
            this.matchedParserUrl = matchedParserUrl == null ? "" : matchedParserUrl;
            this.webPrefix = webPrefix == null ? "" : webPrefix;
            this.error = error == null ? "" : error;
        }
    }

    /**
     * Production routing gate deciding whether a spider/CMS playback result with {@code parse!=0 ||
     * jx!=0} should execute the external parser chain ({@link #executeParserChain}) rather than
     * jumping straight to raw WebView sniffing.
     *
     * <p>Covers {@code parse=1, jx=0} with no {@code playUrl} prefix for ALL of: VIP pages, opaque
     * non-HTTP episode IDs, AND ordinary web pages whenever parsers are configured.
     */
    static boolean shouldRouteThroughExternalParsers(
            int parseFlag,
            int jxFlag,
            String playPrefix,
            String episodeUrl,
            List<Cms.Parse> cfgParses) {
        if (parseFlag == 0 && jxFlag == 0) return false;
        if (jxFlag != 0) return true;
        String cleanPrefix = playPrefix == null ? "" : playPrefix.trim();
        if (isKnownJsonParserPrefix(cleanPrefix, cfgParses)) return true;
        if (cleanPrefix.isEmpty() && cfgParses != null && !cfgParses.isEmpty()) {
            return true;
        }
        return false;
    }

    /**
     * Executes the production external parser chain:
     *
     * <ol>
     *   <li>For non-VIP HTTP pages, tries extracting an embedded direct stream URL first.
     *   <li>Orders configured parsers by flag match, then runs JSON parsers (up to 8 candidates),
     *       including opaque episode IDs and normal web pages.
     *   <li>Falls back to a configured web parser ({@code type == 0}) or explicit non-JSON prefix,
     *       direct media URL, or raw WebView sniff.
     * </ol>
     */
    static ResolutionOutcome executeParserChain(
            String epUrl,
            String lineFlag,
            String preferredPrefix,
            List<Cms.Parse> allParses,
            Map<String, String> siteHeaders,
            String siteName,
            HttpFetcher fetcher,
            EmbeddedExtractor embeddedExtractor) {
        String cleanEpUrl = epUrl == null ? "" : epUrl.trim();
        if (cleanEpUrl.isEmpty()) {
            return new ResolutionOutcome(
                    ResolutionOutcome.KIND_FAILED, "", null, null, "", "", "", "剧集播放标识为空");
        }
        if (Cms.isHttp(cleanEpUrl)
                && !isKnownVipPageUrl(cleanEpUrl)
                && fetcher != null
                && embeddedExtractor != null) {
            try {
                String html = fetcher.fetch(cleanEpUrl, siteHeaders);
                String embedded = embeddedExtractor.extract(cleanEpUrl, html);
                if (Cms.isDirectStreamUrl(embedded)) {
                    return new ResolutionOutcome(
                            ResolutionOutcome.KIND_DIRECT_EMBEDDED,
                            embedded,
                            siteHeaders,
                            null,
                            "",
                            "",
                            "",
                            "");
                }
            } catch (Exception ignored) {
            }
        }

        List<Cms.Parse> candidates =
                orderParsersForFlag(allParses, lineFlag, preferredPrefix, siteHeaders, siteName);
        Cms.Parse webFallbackParser = null;
        int triedJson = 0;
        for (Cms.Parse p : candidates) {
            if (Thread.currentThread().isInterrupted()) {
                return new ResolutionOutcome(
                        ResolutionOutcome.KIND_FAILED, "", null, null, "", "", "", "已取消");
            }
            if (p.type == 0 && webFallbackParser == null) {
                webFallbackParser = p;
            }
            if ((p.type == 1 || p.type == 2 || p.type == 3) && triedJson < 8 && fetcher != null) {
                triedJson++;
                try {
                    String targetUrl = buildWebParserUrl(p.url, cleanEpUrl);
                    String resp = fetcher.fetch(targetUrl, p.headers);
                    ParsedResult pr = parseJsonParserResponse(resp, cleanEpUrl);
                    if (pr.ok && pr.needsWebSniff) {
                        Map<String, String> merged = new LinkedHashMap<>(p.headers);
                        Cms.mergeHeaders(merged, pr.headers);
                        return new ResolutionOutcome(
                                ResolutionOutcome.KIND_WEB_SNIFF,
                                pr.url,
                                merged,
                                pr.rawJson,
                                p.name,
                                p.url,
                                "",
                                "");
                    }
                    if (pr.ok && pr.rawJson != null) {
                        Map<String, String> merged = new LinkedHashMap<>(pr.headers);
                        if (merged.isEmpty() && !p.headers.isEmpty()) merged.putAll(p.headers);
                        return new ResolutionOutcome(
                                ResolutionOutcome.KIND_JSON_PARSER,
                                pr.url,
                                merged,
                                pr.rawJson,
                                p.name,
                                p.url,
                                "",
                                "");
                    }
                } catch (Exception ignored) {
                }
            }
        }

        String finalPrefix =
                webFallbackParser != null
                        ? webFallbackParser.url
                        : (preferredPrefix != null
                                        && !isKnownJsonParserPrefix(preferredPrefix, allParses)
                                ? preferredPrefix.trim()
                                : "");
        Map<String, String> fallbackHeaders =
                webFallbackParser != null
                        ? webFallbackParser.headers
                        : Collections.<String, String>emptyMap();
        String webTarget = buildWebParserUrl(finalPrefix, cleanEpUrl);
        if (!finalPrefix.isEmpty() && Cms.isHttp(webTarget)) {
            return new ResolutionOutcome(
                    ResolutionOutcome.KIND_WEB_PARSER,
                    cleanEpUrl,
                    fallbackHeaders,
                    null,
                    webFallbackParser != null ? webFallbackParser.name : "",
                    finalPrefix,
                    finalPrefix,
                    "");
        }
        if (Cms.isDirectStreamUrl(cleanEpUrl)) {
            return new ResolutionOutcome(
                    ResolutionOutcome.KIND_DIRECT_URL,
                    cleanEpUrl,
                    siteHeaders,
                    null,
                    "",
                    "",
                    "",
                    "");
        }
        if (Cms.isHttp(cleanEpUrl)) {
            return new ResolutionOutcome(
                    ResolutionOutcome.KIND_WEB_SNIFF,
                    cleanEpUrl,
                    siteHeaders,
                    null,
                    "",
                    "",
                    "",
                    "");
        }
        return new ResolutionOutcome(
                ResolutionOutcome.KIND_FAILED, "", null, null, "", "", "", "此剧集需要外部解析，未找到可用解析接口");
    }

    private ExternalParserResolver() {}

    static boolean isKnownVipPageUrl(String url) {
        if (url == null || !Cms.isHttp(url)) return false;
        try {
            String host = URI.create(url.trim()).getHost();
            if (host == null) return false;
            String lower = host.toLowerCase(Locale.ROOT);
            for (String vip : VIP_WEB_HOSTS) {
                if (lower.equals(vip) || lower.endsWith("." + vip)) return true;
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    static boolean matchesParserFlag(Cms.Parse parse, String lineFlag) {
        if (parse == null || parse.flags == null || parse.flags.isEmpty()) return false;
        if (lineFlag == null || lineFlag.trim().isEmpty()) return false;
        String cleanLine = lineFlag.trim().toLowerCase(Locale.ROOT);
        for (String f : parse.flags) {
            if (f == null || f.trim().isEmpty()) continue;
            String cf = f.trim().toLowerCase(Locale.ROOT);
            if (cleanLine.equals(cf) || cleanLine.contains(cf) || cf.contains(cleanLine)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Orders candidate external parsers by priority:
     *
     * <ol>
     *   <li>Explicit {@code preferredPrefix} (deduplicated against config.parses to retain its real
     *       {@code type} and {@code headers})
     *   <li>Parsers whose {@code flags} match {@code lineFlag}
     *   <li>Generic parsers with no restricted {@code flags}
     *   <li>Remaining parsers as last fallback
     * </ol>
     */
    static List<Cms.Parse> orderParsersForFlag(
            List<Cms.Parse> allParses,
            String lineFlag,
            String preferredPrefix,
            Map<String, String> siteHeaders,
            String siteName) {
        List<Cms.Parse> matched = new ArrayList<>();
        List<Cms.Parse> generic = new ArrayList<>();
        List<Cms.Parse> others = new ArrayList<>();
        Set<String> seenUrls = new LinkedHashSet<>();

        String cleanPrefix = preferredPrefix == null ? "" : preferredPrefix.trim();
        if (Cms.isHttp(cleanPrefix)) {
            Cms.Parse matchedCfg = null;
            if (allParses != null) {
                for (Cms.Parse p : allParses) {
                    if (p != null && cleanPrefix.equals(p.url)) {
                        matchedCfg = p;
                        break;
                    }
                }
            }
            if (matchedCfg != null) {
                matched.add(matchedCfg);
                seenUrls.add(matchedCfg.url);
            } else {
                Cms.Parse pref = new Cms.Parse();
                pref.name = siteName == null || siteName.isEmpty() ? "站点解析" : siteName;
                pref.url = cleanPrefix;
                pref.type = looksLikeJsonParsePrefix(cleanPrefix) ? 1 : 0;
                if (siteHeaders != null) pref.headers.putAll(siteHeaders);
                matched.add(pref);
                seenUrls.add(cleanPrefix);
            }
        }

        if (allParses != null) {
            for (Cms.Parse p : allParses) {
                if (p == null || !Cms.isHttp(p.url) || !seenUrls.add(p.url)) continue;
                if (matchesParserFlag(p, lineFlag)) {
                    matched.add(p);
                } else if (p.flags == null || p.flags.isEmpty()) {
                    generic.add(p);
                } else {
                    others.add(p);
                }
            }
        }

        List<Cms.Parse> ordered = new ArrayList<>(matched.size() + generic.size() + others.size());
        ordered.addAll(matched);
        ordered.addAll(generic);
        ordered.addAll(others);
        return ordered;
    }

    static boolean looksLikeJsonParsePrefix(String url) {
        if (url == null) return false;
        String lower = url.toLowerCase(Locale.ROOT);
        return lower.contains("json") || lower.contains("/api") || lower.contains("jx=");
    }

    static boolean isKnownJsonParserPrefix(String prefix, List<Cms.Parse> parses) {
        if (prefix == null || prefix.trim().isEmpty()) return false;
        String clean = prefix.trim();
        if (parses != null) {
            for (Cms.Parse p : parses) {
                if (p != null && clean.equals(p.url)) {
                    return p.type == 1 || p.type == 2 || p.type == 3;
                }
            }
        }
        return looksLikeJsonParsePrefix(clean);
    }

    /**
     * Validates a JSON external parser response and extracts playable media URL + merged headers,
     * rejecting HTML error pages, echoed VIP URLs, and API error codes.
     */
    static ParsedResult parseJsonParserResponse(String rawBody, String originalEpUrl) {
        if (rawBody == null || !rawBody.trim().startsWith("{")) {
            return new ParsedResult(false, false, "", null, null, "响应不是 JSON");
        }
        try {
            JSONObject root = new JSONObject(rawBody.trim());
            int code = root.optInt("code", 200);
            if (code >= 400 || (root.has("success") && !root.optBoolean("success", true))) {
                return new ParsedResult(false, false, "", null, root, "解析接口返回错误码 " + code);
            }
            JSONObject dataObj = root.optJSONObject("data");
            String mediaUrl = Cms.optSafeString(root, "url", "").trim();
            if (mediaUrl.isEmpty() && dataObj != null) {
                mediaUrl = Cms.optSafeString(dataObj, "url", "").trim();
            }
            if (mediaUrl.startsWith("//")) {
                mediaUrl = "https:" + mediaUrl;
            }
            if (mediaUrl.isEmpty()) {
                return new ParsedResult(false, false, "", null, root, "解析响应缺少 url");
            }

            Map<String, String> headers = new LinkedHashMap<>();
            extractHeaders(root, headers);
            if (dataObj != null) extractHeaders(dataObj, headers);

            boolean nestedParse =
                    root.optInt("parse", 0) == 1
                            || (dataObj != null && dataObj.optInt("parse", 0) == 1);
            if (nestedParse && Cms.isHttp(mediaUrl)) {
                return new ParsedResult(true, true, mediaUrl, headers, root, "");
            }

            // Reject echoed original VIP page URL or obvious HTML error pages!
            if (originalEpUrl != null
                    && !originalEpUrl.trim().isEmpty()
                    && mediaUrl.equalsIgnoreCase(originalEpUrl.trim())
                    && isKnownVipPageUrl(mediaUrl)) {
                return new ParsedResult(false, false, "", headers, root, "解析接口原样退回 VIP 网页地址");
            }
            if (looksLikeHtmlPageUrl(mediaUrl)) {
                return new ParsedResult(false, false, "", headers, root, "解析返回的是网页地址而非媒体流");
            }
            if (!Cms.isMedia(mediaUrl)) {
                return new ParsedResult(false, false, "", headers, root, "解析返回的协议不受支持");
            }

            // Build normalized JSON with top-level url & header so MediaOptions.episode handles it
            // cleanly
            JSONObject normalized = new JSONObject(root.toString());
            normalized.put("url", mediaUrl);
            if (!headers.isEmpty()) {
                normalized.put("header", new JSONObject(headers));
            }
            return new ParsedResult(true, false, mediaUrl, headers, normalized, "");
        } catch (Exception e) {
            return new ParsedResult(false, false, "", null, null, "JSON 解析异常：" + e.getMessage());
        }
    }

    static boolean looksLikeHtmlPageUrl(String url) {
        if (url == null || !Cms.isHttp(url)) return false;
        if (isKnownVipPageUrl(url)) return true;
        try {
            String path = URI.create(url.trim()).getPath();
            if (path == null) return false;
            String lower = path.toLowerCase(Locale.ROOT);
            return lower.endsWith(".html")
                    || lower.endsWith(".htm")
                    || lower.endsWith(".shtml")
                    || lower.endsWith(".php")
                    || lower.endsWith(".jsp")
                    || lower.endsWith(".asp");
        } catch (Exception ignored) {
            return false;
        }
    }

    /** Safely assembles a WebView / HTTP parser URL, encoding {@code epUrl} when needed. */
    static String buildWebParserUrl(String prefix, String epUrl) {
        String p = prefix == null ? "" : prefix.trim();
        String u = epUrl == null ? "" : epUrl.trim();
        if (p.isEmpty()) return u;
        if (u.isEmpty()) return p;
        // If prefix ends with query parameter (e.g. ?url= or &v=) and epUrl contains query/hash,
        // URL-encode epUrl so inner & / ? / # are not eaten by the outer parser query string!
        if (p.contains("?") && (u.contains("&") || u.contains("?") || u.contains("#"))) {
            try {
                return p + URLEncoder.encode(u, "UTF-8");
            } catch (Exception ignored) {
            }
        }
        return p + u;
    }

    private static void extractHeaders(JSONObject obj, Map<String, String> out) {
        if (obj == null) return;
        for (String key : new String[] {"header", "headers"}) {
            Object raw = obj.opt(key);
            if (raw instanceof String) {
                try {
                    raw = new JSONObject(((String) raw).trim());
                } catch (Exception ignored) {
                }
            }
            if (raw instanceof JSONObject) {
                JSONObject jo = (JSONObject) raw;
                Iterator<String> it = jo.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    String v = Cms.optSafeString(jo, k, "").trim();
                    if (k != null && !k.isEmpty() && !v.isEmpty()) {
                        out.put(k, v);
                    }
                }
            }
        }
    }
}

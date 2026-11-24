// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.util.Base64;
import android.util.Xml;
import com.pilipala.source.Json;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.zip.GZIPInputStream;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.*;
import org.xmlpull.v1.XmlPullParser;

/**
 * API 14-only, non-executing CMS & Live adapter.
 *
 * <p>Supports JSON CMS ({@code type=1}), MacCMS XML ({@code type=0}), Emby accounts, GZIP / Base64
 * / 2423 Hex-AES configurations, and M3U / TXT live channel lists. Unsupported plugins remain
 * visible and explicitly labeled.
 */
public final class LiteCatalog {
    public static final int MAX_BYTES = 2 * 1024 * 1024;
    public static final long REQUEST_BUDGET_NS = 18000000000L;
    public static final String USER_AGENT = "okhttp/3.15";
    public static final String SAFARI_USER_AGENT =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    private static final Set<HttpURLConnection> IN_FLIGHT =
            Collections.synchronizedSet(new HashSet<HttpURLConnection>());

    public static void cancelAll() {
        HttpURLConnection[] active;
        synchronized (IN_FLIGHT) {
            active = IN_FLIGHT.toArray(new HttpURLConnection[IN_FLIGHT.size()]);
            IN_FLIGHT.clear();
        }
        for (int i = 0; i < active.length; i++) {
            try {
                active[i].disconnect();
            } catch (Exception ignored) {
            }
        }
    }

    public static final class Site {
        public static final String STATUS_OK = "ok";
        public static final String STATUS_NEEDS_JAR = "needs-jar";
        public static final String STATUS_UNSUPPORTED_TYPE = "unsupported-type";
        public static final String STATUS_ADAPTER_MISSING = "adapter-missing";
        public static final String STATUS_EXT_TOO_LARGE = "ext-too-large";
        public static final String STATUS_CUSTOM_SITE_URL = "custom-site-url";
        public static final String STATUS_PARSER_REQUIRED = "parser-required";
        public static final int MAX_EXT_SIZE = 128 * 1024;

        public String key, name, api, playUrl = "";
        public String originalKey = "", originalApi = "", group = "默认分组";
        public int type;
        public boolean supported;
        public boolean searchable = true;
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
        public String jar = "";
        public Object ext;
        public boolean extTooLarge;
        public boolean requiresParser;
        public int playUrlParseType = -1;
        public final Map<String, String> playUrlHeaders = new LinkedHashMap<String, String>();
        public final List<Parse> jsonParses = new ArrayList<Parse>();
        public String unsupportedParseReason = "";

        public String siteId() {
            String k =
                    originalKey != null && originalKey.length() > 0
                            ? originalKey
                            : (key == null ? "" : key);
            String a =
                    originalApi != null && originalApi.length() > 0
                            ? originalApi
                            : (api == null ? "" : api);
            return k + "\n" + a;
        }

        public boolean isExtTooLarge() {
            if (extTooLarge) return true;
            if (ext instanceof String) {
                return ((String) ext).length() > MAX_EXT_SIZE;
            }
            if (ext instanceof JSONObject || ext instanceof JSONArray) {
                return ext.toString().length() > MAX_EXT_SIZE;
            }
            return false;
        }

        public boolean isNetdiskSite() {
            String lowerApi = api == null ? "" : api.toLowerCase(Locale.ROOT);
            String lowerName = name == null ? "" : name.toLowerCase(Locale.ROOT);
            String lowerKey = key == null ? "" : key.toLowerCase(Locale.ROOT);
            if (lowerName.contains("秒播")
                    || lowerApi.startsWith("csp_wex")
                    || lowerApi.contains("ikanbot")
                    || lowerApi.contains("yiys")) {
                return false;
            }
            return lowerApi.contains("wogg")
                    || lowerApi.contains("ainew")
                    || lowerApi.contains("qwmkv")
                    || lowerApi.contains("soai")
                    || lowerApi.contains("sokaka")
                    || lowerApi.contains("seedhub")
                    || lowerApi.contains("pansou")
                    || lowerApi.contains("s_zps")
                    || lowerApi.contains("ypanso")
                    || lowerApi.contains("bpanso")
                    || lowerApi.contains("yiso")
                    || lowerApi.contains("panta")
                    || lowerApi.contains("mypan")
                    || lowerKey.contains("mypan")
                    || lowerName.contains("我的云盘")
                    || lowerName.contains("我的网盘")
                    || lowerName.contains("我的┃网盘")
                    || lowerName.contains("网盘")
                    || lowerName.contains("云盘")
                    || lowerApi.contains("alipansou")
                    || lowerApi.contains("tudou");
        }

        public String capabilityStatus() {
            if (isExtTooLarge()) {
                return STATUS_EXT_TOO_LARGE;
            }
            if ("mydrive".equals(key)) {
                return STATUS_UNSUPPORTED_TYPE;
            }
            if (api != null && api.startsWith("emby://account/")) {
                return STATUS_OK;
            }
            if ((type == 3 || isScriptOrJarApi(api)) && isNetdiskSite()) {
                return STATUS_ADAPTER_MISSING;
            }
            if (type == 3
                    || isScriptOrJarApi(api)
                    || (type != 0 && type != 1 && jar != null && jar.length() > 0)) {
                return STATUS_NEEDS_JAR;
            }
            if (type != 0 && type != 1) {
                return STATUS_UNSUPPORTED_TYPE;
            }
            try {
                http(api);
            } catch (Exception invalid) {
                return STATUS_CUSTOM_SITE_URL;
            }
            return STATUS_OK;
        }

        public String playbackHint() {
            if (requiresParser && (playUrl == null || playUrl.trim().length() == 0)) {
                if (unsupportedParseReason != null && unsupportedParseReason.length() > 0) {
                    return unsupportedParseReason;
                }
                return capabilityReason(STATUS_PARSER_REQUIRED);
            }
            return "";
        }

        public static String capabilityReason(String status) {
            if (STATUS_OK.equals(status)) {
                return "正常可用";
            } else if (STATUS_NEEDS_JAR.equals(status)) {
                return "此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持";
            } else if (STATUS_UNSUPPORTED_TYPE.equals(status)) {
                return "暂不支持此类型来源，已保留在列表中";
            } else if (STATUS_ADAPTER_MISSING.equals(status)) {
                return "此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路";
            } else if (STATUS_EXT_TOO_LARGE.equals(status)) {
                return "扩展参数超过大小上限，无法加载";
            } else if (STATUS_CUSTOM_SITE_URL.equals(status)) {
                return "此来源不是可直接请求的 HTTP(S) CMS";
            } else if (STATUS_PARSER_REQUIRED.equals(status)) {
                return "需要解析器，当前环境缺少可用解析配置";
            }
            return "此来源暂不可用";
        }

        public String limitation() {
            return capabilityReason(capabilityStatus());
        }
    }

    public static Site resolveSelectedSite(
            List<Site> availableSites,
            Site previousSelected,
            String savedSelectedKey,
            String savedSelectedApi) {
        if (availableSites == null || availableSites.isEmpty()) return null;
        if (previousSelected != null) {
            String prevId = previousSelected.siteId();
            String prevKey = previousSelected.key == null ? "" : previousSelected.key;
            String prevApi = previousSelected.api == null ? "" : previousSelected.api;
            for (int i = 0; i < availableSites.size(); i++) {
                Site s = availableSites.get(i);
                if (s != null && s.supported && prevId.equals(s.siteId())) {
                    return s;
                }
            }
            if (prevKey.length() > 0 && prevApi.length() > 0) {
                for (int i = 0; i < availableSites.size(); i++) {
                    Site s = availableSites.get(i);
                    if (s != null
                            && s.supported
                            && prevKey.equals(s.key)
                            && prevApi.equals(s.api)) {
                        return s;
                    }
                }
            }
            if (prevKey.length() > 0) {
                for (int i = 0; i < availableSites.size(); i++) {
                    Site s = availableSites.get(i);
                    if (s != null && s.supported && prevKey.equals(s.key)) {
                        return s;
                    }
                }
            }
        }
        String sk = savedSelectedKey == null ? "" : savedSelectedKey.trim();
        String sa = savedSelectedApi == null ? "" : savedSelectedApi.trim();
        if (sk.length() > 0 && sa.length() > 0) {
            for (int i = 0; i < availableSites.size(); i++) {
                Site s = availableSites.get(i);
                if (s != null && s.supported && sk.equals(s.key) && sa.equals(s.api)) {
                    return s;
                }
            }
        }
        if (sk.length() > 0) {
            for (int i = 0; i < availableSites.size(); i++) {
                Site s = availableSites.get(i);
                if (s != null && s.supported && sk.equals(s.key)) {
                    return s;
                }
            }
        }
        for (int i = 0; i < availableSites.size(); i++) {
            Site s = availableSites.get(i);
            if (s != null && s.supported) {
                return s;
            }
        }
        return null;
    }

    public static boolean sameSiteBinding(Site a, Site b) {
        if (a == b) return true;
        if (a == null || b == null) return false;
        String ka = a.key == null ? "" : a.key;
        String kb = b.key == null ? "" : b.key;
        String aa = a.api == null ? "" : a.api;
        String ab = b.api == null ? "" : b.api;
        return ka.equals(kb) && aa.equals(ab) && a.type == b.type;
    }

    public static final class Parse {
        public String name = "";
        public String url = "";
        public int type;
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
        public final List<String> flags = new ArrayList<String>();
    }

    public static final class ResolvedPlay {
        public final String url;
        public final Map<String, String> headers;
        public final String mode;
        public final String parseName;

        public ResolvedPlay(String url, Map<String, String> headers, String mode, String parseName) {
            this.url = url == null ? "" : url;
            this.headers =
                    headers == null || headers.isEmpty()
                            ? Collections.<String, String>emptyMap()
                            : Collections.unmodifiableMap(
                                    new LinkedHashMap<String, String>(headers));
            this.mode = mode == null ? "direct" : mode;
            this.parseName = parseName == null ? "" : parseName;
        }
    }

    public static final class FetchResult {
        public final String body;
        public final String finalUrl;

        public FetchResult(String body, String finalUrl) {
            this.body = body == null ? "" : body;
            this.finalUrl = finalUrl == null ? "" : finalUrl;
        }
    }

    public static final class Category {
        public String id, name;
    }

    public static final class LiveSource {
        public String name = "";
        public String url = "";
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
        public final List<LiveGroup> inlineGroups = new ArrayList<LiveGroup>();
    }

    public static final class LiveChannel {
        public String name = "";
        public String group = "";
        public final List<String> urls = new ArrayList<String>();
        public final List<Map<String, String>> lineHeaders = new ArrayList<Map<String, String>>();
        public final Map<String, String> headers = new LinkedHashMap<String, String>();

        public Map<String, String> headersForLine(int index) {
            if (index >= 0 && index < lineHeaders.size()) {
                return lineHeaders.get(index);
            }
            return headers;
        }
    }

    public static final class LiveGroup {
        public String name = "";
        public final List<LiveChannel> channels = new ArrayList<LiveChannel>();
    }

    public static String cmsAction(Site site) {
        return site != null && site.type == 0 ? "videolist" : "detail";
    }

    public static String cmsCategoriesUrl(Site site) throws Exception {
        return query(site.api, "ac", "list");
    }

    public static String cmsListUrl(Site site, String categoryId, String keyword, int page)
            throws Exception {
        String ac = cmsAction(site);
        String pg = String.valueOf(Math.max(1, page));
        if (categoryId != null && categoryId.length() > 0) {
            return query(site.api, "ac", ac, "pg", pg, "t", categoryId);
        }
        if (keyword != null && keyword.length() > 0) {
            return query(site.api, "ac", ac, "pg", pg, "wd", keyword);
        }
        return query(site.api, "ac", ac, "pg", pg);
    }

    public static String cmsDetailUrl(Site site, String videoId) throws Exception {
        return query(site.api, "ac", cmsAction(site), "ids", videoId);
    }

    public static boolean isDirectStreamUrl(String value) {
        if (value == null) return false;
        String trimmed = value.trim();
        if (trimmed.length() == 0) return false;
        try {
            http(trimmed);
        } catch (Exception invalid) {
            return false;
        }
        String lower = trimmed.toLowerCase(Locale.ROOT);
        String path = lower.split("[?#]", 2)[0];
        return path.endsWith(".m3u8")
                || path.endsWith(".mp4")
                || path.endsWith(".flv")
                || path.endsWith(".mkv")
                || path.endsWith(".ts")
                || path.endsWith(".webm")
                || path.endsWith(".mpd")
                || path.endsWith(".mov")
                || path.endsWith(".avi")
                || path.endsWith(".3gp")
                || path.endsWith(".m4v")
                || lower.contains(".m3u8?")
                || lower.contains(".mp4?")
                || lower.contains(".flv?")
                || lower.contains(".ts?");
    }

    public static Map<String, String> safeSiteMediaHeaders(Site source, String targetUrl) {
        if (source == null || source.headers.isEmpty()) {
            return Collections.<String, String>emptyMap();
        }
        if (source.api != null
                && (source.api.startsWith("http://") || source.api.startsWith("https://"))) {
            return com.pilipala.source.MediaRequestHeaders.forTarget(
                    source.headers, source.api, targetUrl);
        }
        return com.pilipala.source.MediaRequestHeaders.forTarget(
                source.headers, "http://origin.invalid/", targetUrl);
    }

    public static String buildParseRequestUrl(String parseBaseUrl, String rawEpisodeUrl)
            throws Exception {
        if (parseBaseUrl == null || parseBaseUrl.trim().length() == 0) {
            throw new IOException("解析接口地址为空");
        }
        String base = parseBaseUrl.trim();
        if (base.regionMatches(true, 0, "json:", 0, 5)) {
            base = base.substring(5).trim();
        }
        base = http(base);
        String encoded =
                URLEncoder.encode(rawEpisodeUrl == null ? "" : rawEpisodeUrl, "UTF-8")
                        .replace("+", "%20");
        if (base.contains("{url}")) {
            return base.replace("{url}", encoded);
        }
        if (base.endsWith("=") || base.endsWith("?") || base.endsWith("&")) {
            return base + encoded;
        }
        return base + (base.indexOf('?') >= 0 ? "&url=" : "?url=") + encoded;
    }

    public static ResolvedPlay resolvePlayUrl(String rawEpisodeUrl, Site source, String lineName)
            throws Exception {
        if (rawEpisodeUrl == null || rawEpisodeUrl.trim().length() == 0) {
            throw new IOException("剧集播放地址为空");
        }
        String raw = rawEpisodeUrl.trim();
        if (isDirectStreamUrl(raw)) {
            String normalized = http(raw);
            return new ResolvedPlay(
                    normalized, safeSiteMediaHeaders(source, normalized), "direct", "");
        }
        String playUrl = source != null && source.playUrl != null ? source.playUrl.trim() : "";
        boolean explicitJsonPrefix = playUrl.regionMatches(true, 0, "json:", 0, 5);
        if (playUrl.length() > 0
                && !explicitJsonPrefix
                && !playUrl.startsWith("http://")
                && !playUrl.startsWith("https://")) {
            throw new IOException("此解析配置依赖脚本或外部运行环境，轻量版仅支持 HTTP(S) JSON 解析与可播直链");
        }
        if (source != null
                && (explicitJsonPrefix
                        || source.playUrlParseType == 1
                        || source.playUrlParseType == 2
                        || source.playUrlParseType == 3
                        || !source.jsonParses.isEmpty())) {
            List<Parse> candidates = orderedCandidateParses(source, lineName, explicitJsonPrefix);
            Exception lastError = null;
            for (int i = 0; i < candidates.size(); i++) {
                Parse p = candidates.get(i);
                try {
                    return resolveViaHttpEndpoint(p.url, raw, p.headers, source, true, p.name);
                } catch (Exception ex) {
                    lastError = ex;
                    if (Thread.currentThread().isInterrupted()) throw ex;
                }
            }
            if (lastError != null) throw lastError;
        }
        if (playUrl.startsWith("http://") || playUrl.startsWith("https://")) {
            return resolveViaHttpEndpoint(
                    playUrl,
                    raw,
                    source != null ? source.playUrlHeaders : null,
                    source,
                    false,
                    "播放前缀");
        }
        if (source != null && source.requiresParser) {
            String reason =
                    source.unsupportedParseReason != null
                                    && source.unsupportedParseReason.length() > 0
                            ? source.unsupportedParseReason
                            : "此线路需要播放解析接口，但当前订阅未提供可用的 HTTP(S) JSON 解析配置";
            throw new IOException(reason);
        }
        String normalized;
        try {
            normalized = http(raw);
        } catch (Exception invalid) {
            throw new IOException("此剧集地址不是可直接播放的 HTTP(S) 媒体地址");
        }
        return new ResolvedPlay(
                normalized, safeSiteMediaHeaders(source, normalized), "direct", "");
    }

    private static List<Parse> orderedCandidateParses(
            Site source, String lineName, boolean explicitJsonPrefix) {
        List<Parse> matching = new ArrayList<Parse>();
        List<Parse> others = new ArrayList<Parse>();
        String cleanLine = lineName == null ? "" : lineName.trim().toLowerCase(Locale.ROOT);
        if (explicitJsonPrefix && source.playUrl != null && source.playUrl.length() > 5) {
            Parse explicit = new Parse();
            explicit.name = "站点 JSON 解析";
            explicit.url = source.playUrl.substring(5).trim();
            explicit.type = 1;
            explicit.headers.putAll(source.playUrlHeaders);
            matching.add(explicit);
        }
        for (int i = 0; i < source.jsonParses.size(); i++) {
            Parse p = source.jsonParses.get(i);
            boolean flagHit = false;
            if (cleanLine.length() > 0 && !p.flags.isEmpty()) {
                for (int j = 0; j < p.flags.size(); j++) {
                    String fl = p.flags.get(j).toLowerCase(Locale.ROOT);
                    if (fl.length() > 0 && (cleanLine.equals(fl) || cleanLine.contains(fl))) {
                        flagHit = true;
                        break;
                    }
                }
            }
            if (flagHit) matching.add(p);
            else others.add(p);
        }
        if (matching.isEmpty()
                && others.isEmpty()
                && source.playUrl != null
                && (source.playUrl.startsWith("http://") || source.playUrl.startsWith("https://"))) {
            Parse fallback = new Parse();
            fallback.name = "JSON 解析";
            fallback.url = source.playUrl;
            fallback.type = source.playUrlParseType > 0 ? source.playUrlParseType : 1;
            fallback.headers.putAll(source.playUrlHeaders);
            matching.add(fallback);
        }
        matching.addAll(others);
        return matching;
    }

    private static boolean isMediaContentType(String contentType) {
        if (contentType == null) return false;
        String lower = contentType.toLowerCase(Locale.ROOT);
        return lower.startsWith("video/")
                || lower.startsWith("audio/")
                || lower.contains("mpegurl")
                || lower.contains("x-mpegurl")
                || lower.contains("dash+xml")
                || lower.contains("mp2t");
    }

    private static ResolvedPlay resolveViaHttpEndpoint(
            String parseBaseUrl,
            String rawEpisodeUrl,
            Map<String, String> parseRequestHeaders,
            Site source,
            boolean explicitJsonParse,
            String parseName)
            throws Exception {
        String current = buildParseRequestUrl(parseBaseUrl, rawEpisodeUrl);
        long deadlineNs = System.nanoTime() + 12000000000L;
        Map<String, String> reqHeaders = new LinkedHashMap<String, String>();
        if (parseRequestHeaders != null) reqHeaders.putAll(parseRequestHeaders);
        Map<String, RedirectCookie> redirectCookies = new LinkedHashMap<String, RedirectCookie>();
        boolean redirected = false;

        for (int hop = 0; hop < 6; hop++) {
            if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs) {
                throw new InterruptedIOException("解析接口请求超时");
            }
            HttpURLConnection c = (HttpURLConnection) new URL(current).openConnection();
            IN_FLIGHT.add(c);
            if (c instanceof javax.net.ssl.HttpsURLConnection) {
                NetworkTls.configure((javax.net.ssl.HttpsURLConnection) c);
            }
            int remainingMs = (int) Math.max(1000L, (deadlineNs - System.nanoTime()) / 1000000L);
            c.setConnectTimeout(Math.min(8000, remainingMs));
            c.setReadTimeout(Math.min(10000, remainingMs));
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", USER_AGENT);
            for (Map.Entry<String, String> h : reqHeaders.entrySet()) {
                c.setRequestProperty(h.getKey(), h.getValue());
            }
            try {
                int status = c.getResponseCode();
                List<String> setCookies = c.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry : c.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<RedirectCookie> newCookies = parseSetCookies(setCookies, new URL(current));
                for (int i = 0; i < newCookies.size(); i++) {
                    RedirectCookie cookie = newCookies.get(i);
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }
                if (status >= 300 && status < 400) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null) throw new IOException("解析接口重定向缺少地址");
                    String next = http(new URL(new URL(current), loc).toString());
                    URL before = new URL(current), after = new URL(next);
                    if ("https".equalsIgnoreCase(before.getProtocol())
                            && "http".equalsIgnoreCase(after.getProtocol())) {
                        throw new IOException("解析接口不允许降级重定向");
                    }
                    if (after.getUserInfo() != null) {
                        throw new IOException("解析接口重定向不能注入凭据");
                    }
                    reqHeaders = inheritedHeaders(before, after, reqHeaders);
                    mergeRedirectCookies(reqHeaders, redirectCookies.values(), after);
                    current = next;
                    redirected = true;
                    if (!explicitJsonParse && isDirectStreamUrl(next)) {
                        Map<String, String> mediaHeaders =
                                new LinkedHashMap<String, String>(
                                        safeSiteMediaHeaders(source, next));
                        return new ResolvedPlay(next, mediaHeaders, "prefix-redirect", parseName);
                    }
                    continue;
                }
                if (status < 200 || status >= 300) {
                    throw new IOException("解析接口返回 HTTP " + status);
                }
                String contentType = c.getContentType();
                if (isMediaContentType(contentType)) {
                    Map<String, String> mediaHeaders =
                            new LinkedHashMap<String, String>(
                                    safeSiteMediaHeaders(source, current));
                    return new ResolvedPlay(
                            current,
                            mediaHeaders,
                            redirected ? "prefix-redirect" : "prefix-media",
                            parseName);
                }
                InputStream in = c.getInputStream();
                if ("gzip".equalsIgnoreCase(c.getContentEncoding())) {
                    in = new GZIPInputStream(in);
                }
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[4096];
                int n;
                int limit = 256 * 1024;
                boolean truncatedAsBinary = false;
                while ((n = in.read(buf)) != -1) {
                    if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs) {
                        throw new InterruptedIOException("解析接口读取超时");
                    }
                    if (out.size() == 0 && n >= 8 && looksLikeBinaryMedia(buf, n)) {
                        truncatedAsBinary = true;
                        break;
                    }
                    if (out.size() + n > limit) {
                        if (!explicitJsonParse
                                && contentType != null
                                && contentType.toLowerCase(Locale.ROOT)
                                        .contains("octet-stream")) {
                            truncatedAsBinary = true;
                            break;
                        }
                        throw new IOException("解析接口返回内容过大");
                    }
                    out.write(buf, 0, n);
                }
                if (truncatedAsBinary) {
                    Map<String, String> mediaHeaders =
                            new LinkedHashMap<String, String>(
                                    safeSiteMediaHeaders(source, current));
                    return new ResolvedPlay(
                            current,
                            mediaHeaders,
                            redirected ? "prefix-redirect" : "prefix-media",
                            parseName);
                }
                String body = decodeText(out.toByteArray()).trim();
                if (body.startsWith("\ufeff")) body = body.substring(1).trim();
                if (body.startsWith("#EXTM3U")) {
                    Map<String, String> mediaHeaders =
                            new LinkedHashMap<String, String>(
                                    safeSiteMediaHeaders(source, current));
                    return new ResolvedPlay(
                            current,
                            mediaHeaders,
                            redirected ? "prefix-redirect" : "prefix-media",
                            parseName);
                }
                if (isHtml(body)) {
                    throw new IOException("解析接口返回网页内容，轻量版不支持网页嗅探解析");
                }
                if (body.startsWith("{")) {
                    return parseJsonPlayResponse(body, current, source, parseName);
                }
                throw new IOException("解析接口未返回可识别的 JSON 或媒体流");
            } finally {
                IN_FLIGHT.remove(c);
                c.disconnect();
            }
        }
        throw new IOException("解析接口重定向过多");
    }

    private static boolean looksLikeBinaryMedia(byte[] buf, int len) {
        if (len >= 8
                && buf[4] == 'f'
                && buf[5] == 't'
                && buf[6] == 'y'
                && buf[7] == 'p') {
            return true;
        }
        if (len >= 4
                && (buf[0] & 0xff) == 0x1a
                && (buf[1] & 0xff) == 0x45
                && (buf[2] & 0xff) == 0xdf
                && (buf[3] & 0xff) == 0xa3) {
            return true;
        }
        if (len >= 3 && buf[0] == 'F' && buf[1] == 'L' && buf[2] == 'V') {
            return true;
        }
        return len >= 1 && buf[0] == 0x47 && (len < 189 || buf[188] == 0x47);
    }

    public static ResolvedPlay parseJsonPlayResponse(
            String jsonBody, String parseEndpointUrl, Site source, String parseName)
            throws Exception {
        JSONObject obj = new JSONObject(withoutComments(jsonBody).trim());
        JSONObject dataObj = obj.optJSONObject("data");
        String mediaUrl = Json.str(obj, "url", "").trim();
        if (mediaUrl.length() == 0 && dataObj != null) {
            mediaUrl = Json.str(dataObj, "url", "").trim();
        }
        if (mediaUrl.length() == 0 && obj.opt("data") instanceof String) {
            String ds = Json.str(obj, "data", "").trim();
            if (ds.startsWith("http://") || ds.startsWith("https://")) {
                mediaUrl = ds;
            }
        }
        if (mediaUrl.length() == 0) {
            String msg = Json.str(obj, "msg", Json.str(obj, "message", "")).trim();
            throw new IOException(
                    msg.length() > 0 ? ("解析失败：" + msg) : "解析接口返回空播放地址");
        }
        if (!mediaUrl.startsWith("http://")
                && !mediaUrl.startsWith("https://")
                && parseEndpointUrl != null
                && parseEndpointUrl.length() > 0
                && (mediaUrl.startsWith("/") || mediaUrl.startsWith("./") || mediaUrl.startsWith("../"))) {
            mediaUrl = new URL(new URL(parseEndpointUrl), mediaUrl).toString();
        }
        String normalizedUrl;
        try {
            normalizedUrl = http(mediaUrl);
        } catch (Exception invalid) {
            throw new IOException("解析接口返回了不受支持的播放协议地址");
        }
        Map<String, String> mergedHeaders =
                new LinkedHashMap<String, String>(safeSiteMediaHeaders(source, normalizedUrl));
        extractParseResponseHeaders(mergedHeaders, obj);
        if (dataObj != null) {
            extractParseResponseHeaders(mergedHeaders, dataObj);
        }
        return new ResolvedPlay(normalizedUrl, mergedHeaders, "json-parse", parseName);
    }

    private static void extractParseResponseHeaders(Map<String, String> target, JSONObject obj) {
        if (obj == null) return;
        applyHeaderField(target, obj.opt("header"));
        applyHeaderField(target, obj.opt("headers"));
        String ua = Json.str(obj, "ua", Json.str(obj, "User-Agent", Json.str(obj, "user-agent", ""))).trim();
        if (ua.length() > 0) putSafeSingleHeader(target, "User-Agent", ua);
        String ref = Json.str(obj, "referer", Json.str(obj, "Referer", "")).trim();
        if (ref.length() > 0) putSafeSingleHeader(target, "Referer", ref);
        String origin = Json.str(obj, "origin", Json.str(obj, "Origin", "")).trim();
        if (origin.length() > 0) putSafeSingleHeader(target, "Origin", origin);
        String cookie = Json.str(obj, "cookie", Json.str(obj, "Cookie", "")).trim();
        if (cookie.length() > 0) putSafeSingleHeader(target, "Cookie", cookie);
    }

    private static void applyHeaderField(Map<String, String> target, Object field) {
        if (field == null || field == JSONObject.NULL) return;
        if (field instanceof JSONObject) {
            putSafeHeaders(target, (JSONObject) field);
        } else if (field instanceof String) {
            String raw = ((String) field).trim();
            if (raw.startsWith("{")) {
                try {
                    putSafeHeaders(target, new JSONObject(raw));
                } catch (Exception ignored) {
                }
            }
        }
    }

    static void putSafeSingleHeader(Map<String, String> target, String k, String v) {
        if (k == null || k.length() == 0 || v == null) return;
        if (k.indexOf('\r') >= 0
                || k.indexOf('\n') >= 0
                || v.indexOf('\r') >= 0
                || v.indexOf('\n') >= 0) {
            return;
        }
        for (Iterator<String> it = target.keySet().iterator(); it.hasNext(); ) {
            if (it.next().equalsIgnoreCase(k)) {
                it.remove();
            }
        }
        if ("user-agent".equalsIgnoreCase(k) || "ua".equalsIgnoreCase(k)) k = "User-Agent";
        else if ("referer".equalsIgnoreCase(k) || "referrer".equalsIgnoreCase(k)) k = "Referer";
        else if ("cookie".equalsIgnoreCase(k)) k = "Cookie";
        else if ("origin".equalsIgnoreCase(k)) k = "Origin";
        else if ("authorization".equalsIgnoreCase(k)) k = "Authorization";
        target.put(k, v);
    }

    public static String http(String value) throws Exception {
        URL u = new URL(value.trim());
        String scheme = u.getProtocol();
        if ((!"http".equals(scheme) && !"https".equals(scheme))
                || u.getHost().length() == 0
                || u.getUserInfo() != null) {
            throw new IOException("请输入有效的 HTTP(S) 配置地址");
        }
        return u.toExternalForm();
    }

    public static String withoutComments(String s) {
        if (s == null) return "";
        if (s.startsWith("\ufeff")) s = s.substring(1);
        StringBuilder out = new StringBuilder(s.length());
        boolean inStr = false, esc = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (inStr) {
                out.append(c);
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') inStr = false;
            } else {
                if (c == '"') {
                    inStr = true;
                    out.append(c);
                } else if (c == '/' && i + 1 < s.length() && s.charAt(i + 1) == '/') {
                    i += 2;
                    while (i < s.length() && s.charAt(i) != '\n') i++;
                    if (i < s.length()) out.append('\n');
                } else if (c == '/' && i + 1 < s.length() && s.charAt(i + 1) == '*') {
                    i += 2;
                    while (i + 1 < s.length() && !(s.charAt(i) == '*' && s.charAt(i + 1) == '/'))
                        i++;
                    i++;
                } else out.append(c);
            }
        }
        String clean = out.toString();
        StringBuilder noTrailing = new StringBuilder(clean.length());
        inStr = false;
        esc = false;
        for (int i = 0; i < clean.length(); i++) {
            char c = clean.charAt(i);
            if (inStr) {
                noTrailing.append(c);
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') inStr = false;
                continue;
            }
            if (c == '"') {
                inStr = true;
                noTrailing.append(c);
                continue;
            }
            if (c == ',') {
                int j = i + 1;
                while (j < clean.length() && Character.isWhitespace(clean.charAt(j))) j++;
                if (j < clean.length() && (clean.charAt(j) == '}' || clean.charAt(j) == ']')) {
                    continue;
                }
            }
            noTrailing.append(c);
        }
        return noTrailing.toString();
    }

    public static boolean isHtml(String s) {
        if (s == null) return false;
        String t = s.replaceFirst("^\\uFEFF", "").trim().toLowerCase(Locale.ROOT);
        return t.startsWith("<!doctype") || t.startsWith("<html");
    }

    static boolean isScriptOrJarApi(String api) {
        if (api == null) return false;
        String lower = api.trim().toLowerCase(Locale.ROOT).split("[?#]", 2)[0];
        return lower.startsWith("csp_")
                || lower.endsWith(".js")
                || lower.endsWith(".mjs")
                || lower.endsWith(".py")
                || lower.endsWith(".jar");
    }

    static boolean hasXmlInUrlPath(String httpUrl) {
        try {
            String urlPath = new URL(http(httpUrl)).getPath();
            if (urlPath == null) return false;
            String lowerPath = urlPath.toLowerCase(Locale.ROOT);
            return lowerPath.contains("xml") || lowerPath.endsWith(".xml");
        } catch (Exception e) {
            return false;
        }
    }

    static final class HttpStatusException extends IOException {
        final int status;

        HttpStatusException(int status) {
            super("服务器返回 HTTP " + status);
            this.status = status;
        }
    }

    static final class RedirectCookie {
        final String name;
        final String value;
        final String domain;
        final boolean hostOnly;
        final String path;

        RedirectCookie(String name, String value, String domain, boolean hostOnly, String path) {
            this.name = name;
            this.value = value;
            this.domain = domain;
            this.hostOnly = hostOnly;
            this.path = path;
        }

        boolean matches(URL target) {
            String targetHost = target.getHost().toLowerCase(Locale.ROOT);
            if (hostOnly) {
                if (!targetHost.equals(domain)) return false;
            } else {
                if (!targetHost.equals(domain) && !targetHost.endsWith("." + domain)) return false;
            }
            String targetPath = target.getPath();
            if (targetPath == null || targetPath.length() == 0) targetPath = "/";
            if ("/".equals(path) || targetPath.equals(path)) return true;
            if (targetPath.startsWith(path)) {
                return path.endsWith("/") || targetPath.charAt(path.length()) == '/';
            }
            return false;
        }
    }

    static List<RedirectCookie> parseSetCookies(List<String> headerValues, URL requestUrl) {
        List<RedirectCookie> result = new ArrayList<RedirectCookie>();
        if (headerValues == null || headerValues.isEmpty()) return result;
        String reqHost = requestUrl.getHost().toLowerCase(Locale.ROOT);
        for (int j = 0; j < headerValues.size(); j++) {
            String raw = headerValues.get(j);
            if (raw == null || raw.trim().length() == 0) continue;
            String[] parts = raw.split(";");
            if (parts.length == 0) continue;
            String first = parts[0].trim();
            int eq = first.indexOf('=');
            if (eq <= 0) continue;
            String name = first.substring(0, eq).trim();
            String value = first.substring(eq + 1).trim();
            if (name.length() == 0) continue;

            String domain = reqHost;
            boolean hostOnly = true;
            String path = "/";
            boolean expired = value.length() == 0;

            for (int i = 1; i < parts.length; i++) {
                String attr = parts[i].trim();
                if (attr.length() == 0) continue;
                int aEq = attr.indexOf('=');
                String aKey =
                        (aEq < 0 ? attr : attr.substring(0, aEq)).trim().toLowerCase(Locale.ROOT);
                String aVal = aEq < 0 ? "" : attr.substring(aEq + 1).trim();
                if ("domain".equals(aKey) && aVal.length() > 0) {
                    String clean = aVal.replaceAll("^\\.+", "").toLowerCase(Locale.ROOT);
                    if (clean.indexOf('.') >= 0
                            && (reqHost.equals(clean) || reqHost.endsWith("." + clean))) {
                        domain = clean;
                        hostOnly = false;
                    }
                } else if ("path".equals(aKey) && aVal.startsWith("/")) {
                    path = aVal;
                } else if ("max-age".equals(aKey)) {
                    try {
                        long secs = Long.parseLong(aVal);
                        if (secs <= 0) expired = true;
                    } catch (Exception ignored) {
                    }
                }
            }
            if (!expired) {
                result.add(new RedirectCookie(name, value, domain, hostOnly, path));
            }
        }
        return result;
    }

    static void mergeRedirectCookies(
            Map<String, String> headers, Collection<RedirectCookie> cookies, URL target) {
        Map<String, String> map = new LinkedHashMap<String, String>();
        String existing = null;
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if ("cookie".equalsIgnoreCase(entry.getKey())) {
                existing = entry.getValue();
                break;
            }
        }
        if (existing != null && existing.trim().length() > 0) {
            String[] pairs = existing.split(";");
            for (int i = 0; i < pairs.length; i++) {
                int eq = pairs[i].indexOf('=');
                if (eq > 0) {
                    map.put(pairs[i].substring(0, eq).trim(), pairs[i].substring(eq + 1).trim());
                }
            }
        }
        for (Iterator<RedirectCookie> it = cookies.iterator(); it.hasNext(); ) {
            RedirectCookie rc = it.next();
            if (rc.matches(target)) {
                map.put(rc.name, rc.value);
            }
        }
        if (!map.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            for (Map.Entry<String, String> e : map.entrySet()) {
                if (sb.length() > 0) sb.append("; ");
                sb.append(e.getKey()).append("=").append(e.getValue());
            }
            for (Iterator<String> it = headers.keySet().iterator(); it.hasNext(); ) {
                if ("cookie".equalsIgnoreCase(it.next())) it.remove();
            }
            headers.put("Cookie", sb.toString());
        }
    }

    static Map<String, String> inheritedHeaders(URL before, URL after, Map<String, String> input) {
        Map<String, String> out = new LinkedHashMap<String, String>();
        int bp = before.getPort() < 0 ? before.getDefaultPort() : before.getPort();
        int ap = after.getPort() < 0 ? after.getDefaultPort() : after.getPort();
        boolean sameOrigin =
                before.getProtocol().equalsIgnoreCase(after.getProtocol())
                        && before.getHost().equalsIgnoreCase(after.getHost())
                        && bp == ap;
        for (Map.Entry<String, String> entry : input.entrySet()) {
            String key = entry.getKey();
            if (sameOrigin
                    || !(key.equalsIgnoreCase("Authorization")
                            || key.equalsIgnoreCase("Proxy-Authorization")
                            || key.equalsIgnoreCase("Cookie")
                            || key.equalsIgnoreCase("Cookie2"))) {
                out.put(key, entry.getValue());
            }
        }
        return out;
    }

    private static FetchResult fetchOnceWithUrl(
            String address, Map<String, String> requestHeaders, String defaultUa)
            throws Exception {
        String current = http(address);
        long deadlineNs = System.nanoTime() + REQUEST_BUDGET_NS;
        Map<String, String> headers = new LinkedHashMap<String, String>();
        if (requestHeaders != null) headers.putAll(requestHeaders);
        Map<String, RedirectCookie> redirectCookies = new LinkedHashMap<String, RedirectCookie>();
        for (int redirects = 0; redirects < 6; redirects++) {
            if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs)
                throw new InterruptedIOException();
            HttpURLConnection c = (HttpURLConnection) new URL(current).openConnection();
            IN_FLIGHT.add(c);
            if (c instanceof javax.net.ssl.HttpsURLConnection)
                NetworkTls.configure((javax.net.ssl.HttpsURLConnection) c);
            int remainingMs = (int) Math.max(1000L, (deadlineNs - System.nanoTime()) / 1000000L);
            c.setConnectTimeout(Math.min(10000, remainingMs));
            c.setReadTimeout(Math.min(12000, remainingMs));
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", defaultUa != null ? defaultUa : USER_AGENT);
            if (headers != null)
                for (Map.Entry<String, String> h : headers.entrySet())
                    c.setRequestProperty(h.getKey(), h.getValue());
            try {
                int status = c.getResponseCode();
                List<String> setCookies = c.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry : c.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<RedirectCookie> newCookies = parseSetCookies(setCookies, new URL(current));
                for (int i = 0; i < newCookies.size(); i++) {
                    RedirectCookie cookie = newCookies.get(i);
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }
                if (status >= 300 && status < 400) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null) throw new IOException("重定向缺少地址");
                    String next = http(new URL(new URL(current), loc).toString());
                    URL before = new URL(current), after = new URL(next);
                    if ("https".equals(before.getProtocol()) && "http".equals(after.getProtocol()))
                        throw new IOException("不支持降级连接");
                    if (after.getUserInfo() != null) throw new IOException("来源重定向不能注入登录凭据");
                    if (headers != null) {
                        headers = inheritedHeaders(before, after, headers);
                    }
                    mergeRedirectCookies(headers, redirectCookies.values(), after);
                    current = next;
                    continue;
                }
                if (status < 200 || status >= 300) throw new HttpStatusException(status);
                InputStream in = c.getInputStream();
                if ("gzip".equalsIgnoreCase(c.getContentEncoding())) {
                    in = new java.util.zip.GZIPInputStream(in);
                }
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] b = new byte[8192];
                int n;
                while ((n = in.read(b)) != -1) {
                    if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs)
                        throw new InterruptedIOException();
                    if (out.size() + n > MAX_BYTES) throw new IOException("配置或列表超过大小限制");
                    out.write(b, 0, n);
                }
                return new FetchResult(decodeText(out.toByteArray()), current);
            } finally {
                IN_FLIGHT.remove(c);
                c.disconnect();
            }
        }
        throw new IOException("重定向过多");
    }

    private static String fetchOnce(
            String address, Map<String, String> requestHeaders, String defaultUa)
            throws Exception {
        return fetchOnceWithUrl(address, requestHeaders, defaultUa).body;
    }

    public static FetchResult fetchWithFinalUrl(String address, Map<String, String> headers)
            throws Exception {
        String customUa = null;
        if (headers != null) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                if ("user-agent".equalsIgnoreCase(entry.getKey())) {
                    customUa = entry.getValue();
                    break;
                }
            }
        }
        return fetchOnceWithUrl(address, headers, customUa != null ? customUa : USER_AGENT);
    }

    public static String fetch(String address, Map<String, String> headers) throws Exception {
        return fetchWithFinalUrl(address, headers).body;
    }

    public static String fetchConfig(String address) throws Exception {
        Map<String, String> headers = new LinkedHashMap<String, String>();
        headers.put("User-Agent", USER_AGENT);
        String result;
        try {
            result = fetchOnce(address, headers, USER_AGENT);
            if (!isHtml(result)) {
                return result;
            }
        } catch (HttpStatusException e) {
            if (e.status != 403) {
                throw e;
            }
        }
        Map<String, String> fallbackHeaders = new LinkedHashMap<String, String>();
        fallbackHeaders.put("User-Agent", SAFARI_USER_AGENT);
        result = fetchOnce(address, fallbackHeaders, SAFARI_USER_AGENT);
        if (isHtml(result)) {
            throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        return result;
    }

    public static String decodeText(byte[] bytes) throws IOException {
        if (bytes.length >= 2 && (bytes[0] & 255) == 0x1f && (bytes[1] & 255) == 0x8b) {
            GZIPInputStream gz = new GZIPInputStream(new ByteArrayInputStream(bytes));
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = gz.read(buf)) != -1) {
                    if (out.size() + n > MAX_BYTES) throw new IOException("解压后内容超过大小限制");
                    out.write(buf, 0, n);
                }
                bytes = out.toByteArray();
            } finally {
                gz.close();
            }
        }
        if (bytes.length >= 2 && (bytes[0] & 255) == 0xFF && (bytes[1] & 255) == 0xD8) {
            int marker = -1;
            for (int i = bytes.length - 2; i >= 2; i--) {
                if (bytes[i] == '*' && bytes[i + 1] == '*') {
                    marker = i + 2;
                    break;
                }
            }
            if (marker >= 0) {
                int len = bytes.length - marker;
                byte[] sub = new byte[len];
                System.arraycopy(bytes, marker, sub, 0, len);
                return new String(Base64.decode(sub, Base64.DEFAULT), "UTF-8");
            }
        }
        if (bytes.length >= 3
                && (bytes[0] & 255) == 0xEF
                && (bytes[1] & 255) == 0xBB
                && (bytes[2] & 255) == 0xBF)
            return new String(bytes, 3, bytes.length - 3, "UTF-8");
        if (bytes.length >= 2 && (bytes[0] & 255) == 255 && (bytes[1] & 255) == 254)
            return new String(bytes, 2, bytes.length - 2, "UTF-16LE");
        if (bytes.length >= 2 && (bytes[0] & 255) == 254 && (bytes[1] & 255) == 255)
            return new String(bytes, 2, bytes.length - 2, "UTF-16BE");
        return new String(bytes, "UTF-8");
    }

    public static String decrypt2423(String raw) {
        if (raw == null) return "";
        String s = raw.replaceAll("\\s+", "");
        if (!s.startsWith("2423")) return raw;
        try {
            int keyEnd = s.indexOf("2324");
            while (keyEnd >= 0 && (keyEnd % 2 != 0)) {
                keyEnd = s.indexOf("2324", keyEnd + 1);
            }
            if (keyEnd < 4) return raw;
            String keyHex = s.substring(4, keyEnd);
            String body = s.substring(keyEnd + 4);
            if (body.length() < 26) return raw;
            String ivHex = body.substring(body.length() - 26);
            String cipherHex = body.substring(0, body.length() - 26);
            String keyStr = new String(hexToBytes(keyHex), "UTF-8").trim();
            String ivStr = new String(hexToBytes(ivHex), "UTF-8").trim();
            byte[] keyBytes = padRight16(keyStr.getBytes("UTF-8"));
            byte[] ivBytes = padRight16(ivStr.getBytes("UTF-8"));
            Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            cipher.init(
                    Cipher.DECRYPT_MODE,
                    new SecretKeySpec(keyBytes, "AES"),
                    new IvParameterSpec(ivBytes));
            byte[] decrypted = cipher.doFinal(hexToBytes(cipherHex));
            return new String(decrypted, "UTF-8").trim();
        } catch (Exception ignored) {
            return raw;
        }
    }

    private static byte[] padRight16(byte[] src) {
        byte[] out = new byte[16];
        for (int i = 0; i < 16; i++) {
            out[i] = i < src.length ? src[i] : (byte) '0';
        }
        return out;
    }

    private static byte[] hexToBytes(String hex) {
        int len = hex.length() / 2;
        byte[] out = new byte[len];
        for (int i = 0; i < len; i++) {
            int hi = Character.digit(hex.charAt(i * 2), 16);
            int lo = Character.digit(hex.charAt(i * 2 + 1), 16);
            out[i] = (byte) ((Math.max(0, hi) << 4) | Math.max(0, lo));
        }
        return out;
    }

    public static JSONObject decodeConfig(String raw) throws Exception {
        if (isHtml(raw)) {
            throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        String cleaned = withoutComments(raw).trim();
        if (isHtml(cleaned)) {
            throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        if (cleaned.startsWith("\ufeff")) cleaned = cleaned.substring(1).trim();
        if (cleaned.startsWith("2423")) {
            cleaned = withoutComments(decrypt2423(cleaned)).trim();
        }
        int star = cleaned.indexOf("**");
        if (!cleaned.startsWith("{") && !cleaned.startsWith("[")) {
            if (star >= 0) {
                try {
                    String decoded =
                            new String(
                                    Base64.decode(
                                            cleaned.substring(star + 2).replaceAll("\\s+", ""),
                                            Base64.DEFAULT),
                                    "UTF-8");
                    if (decoded.trim().startsWith("{") || decoded.trim().startsWith("["))
                        cleaned = withoutComments(decoded).trim();
                } catch (Exception ignored) {
                }
            } else if (cleaned.length() >= 16 && !cleaned.contains(" ")) {
                try {
                    String decoded =
                            new String(
                                    Base64.decode(
                                            cleaned.replaceAll("\\s+", ""),
                                            Base64.DEFAULT),
                                    "UTF-8");
                    if (decoded.trim().startsWith("{") || decoded.trim().startsWith("["))
                        cleaned = withoutComments(decoded).trim();
                } catch (Exception ignored) {
                }
            }
        }
        if (cleaned.startsWith("<")) {
            String lowerXml = cleaned.toLowerCase(Locale.ROOT);
            if (lowerXml.contains("<rss") && lowerXml.contains("<list")) {
                return new JSONObject().put("_mm_direct_xml", true);
            }
        }
        if (cleaned.startsWith("[")) {
            JSONArray sites = new JSONArray(cleaned);
            if (sites.length() == 0) throw new IOException("配置数组需要包含带 api 的来源对象");
            for (int i = 0; i < sites.length(); i++) {
                JSONObject item = sites.optJSONObject(i);
                Object api = item == null ? null : item.opt("api");
                if (!(api instanceof String) || ((String) api).trim().length() == 0)
                    throw new IOException("配置数组需要包含带 api 的来源对象");
            }
            return new JSONObject().put("sites", sites);
        }
        return new JSONObject(cleaned);
    }

    private static boolean isDirectCmsResponse(JSONObject root) {
        if (root == null) return false;
        if (root.optBoolean("_mm_direct_xml", false)) return true;
        JSONArray videos = root.optJSONArray("list");
        JSONArray categories = root.optJSONArray("class");
        if (videos != null) {
            for (int i = 0; i < videos.length(); i++) {
                JSONObject v = videos.optJSONObject(i);
                if (v != null
                        && (Json.str(v, "vod_id", "").trim().length() > 0
                                || Json.str(v, "vod_name", "").trim().length() > 0)) {
                    return true;
                }
            }
        }
        if (categories != null) {
            for (int i = 0; i < categories.length(); i++) {
                JSONObject c = categories.optJSONObject(i);
                if (c != null
                        && Json.str(c, "type_id", "").trim().length() > 0
                        && Json.str(c, "type_name", "").trim().length() > 0) {
                    return true;
                }
            }
        }
        return videos != null
                && videos.length() == 0
                && Json.integer(root, "code", -1) == 1
                && Json.integer(root, "page", 0) > 0
                && Json.integer(root, "pagecount", -1) >= 0;
    }

    private static JSONObject directCmsConfig(JSONObject doc, String origin) throws Exception {
        String address = http(origin);
        URI uri = new URI(address);
        StringBuilder api = new StringBuilder(address.split("[?#]", 2)[0]);
        String query = uri.getRawQuery();
        if (query != null) {
            boolean first = true;
            String[] parts = query.split("&");
            for (int i = 0; i < parts.length; i++) {
                String part = parts[i];
                if (part.length() == 0) continue;
                String key = URLDecoder.decode(part.split("=", 2)[0], "UTF-8");
                if ("ac".equals(key)
                        || "t".equals(key)
                        || "pg".equals(key)
                        || "wd".equals(key)
                        || "ids".equals(key)
                        || "h".equals(key)) continue;
                api.append(first ? '?' : '&').append(part);
                first = false;
            }
        }
        String endpoint = api.toString();
        boolean isXml = doc.optBoolean("_mm_direct_xml", false) || hasXmlInUrlPath(endpoint);
        JSONObject site =
                new JSONObject()
                        .put("key", "cms_" + UUID.nameUUIDFromBytes(endpoint.getBytes("UTF-8")))
                        .put("name", "采集源 · " + new URL(endpoint).getHost())
                        .put("type", isXml ? 0 : 1)
                        .put("api", endpoint)
                        .put("searchable", 1);
        JSONObject out = new JSONObject().put("sites", new JSONArray().put(site));
        String tagged = Json.str(doc, com.pilipala.source.Warehouse.ORIGIN, "");
        if (tagged.length() > 0) out.put(com.pilipala.source.Warehouse.ORIGIN, tagged);
        return out;
    }

    public static String importConfig(String raw, String origin) throws Exception {
        JSONObject preview = decodeConfig(raw);
        if (isDirectCmsResponse(preview)) {
            return directCmsConfig(preview, origin).toString();
        }
        return com.pilipala.source.Warehouse.resolve(
                raw,
                origin,
                new com.pilipala.source.Warehouse.Reader() {
                    public String read(String url) throws Exception {
                        return fetchConfig(url);
                    }
                },
                new com.pilipala.source.Warehouse.Decoder() {
                    public JSONObject decode(String text) throws Exception {
                        return decodeConfig(text);
                    }
                },
                new com.pilipala.source.Warehouse.Validator() {
                    public void validate(String text, String base) throws Exception {
                        parse(text, base);
                    }
                });
    }

    public static List<Site> parse(String raw, String base) throws Exception {
        JSONObject document = decodeConfig(raw);
        base = Json.str(document, com.pilipala.source.Warehouse.ORIGIN, base);
        if (isDirectCmsResponse(document)) {
            document = directCmsConfig(document, base);
        }
        JSONArray rows = document.optJSONArray("sites");
        if ((rows == null || rows.length() == 0) && Json.str(document, "api", "").length() > 0)
            rows = new JSONArray().put(document);
        if (rows == null || rows.length() == 0) {
            if (!parseLivesFromDocument(document, base).isEmpty()) {
                return new ArrayList<Site>();
            }
            throw new IOException("配置没有 sites 列表");
        }
        List<Parse> supportedJsonParses = new ArrayList<Parse>();
        boolean hasWebSniffParse = false;
        boolean hasScriptParse = false;
        JSONArray parses = document.optJSONArray("parses");
        if (parses != null) {
            for (int i = 0; i < parses.length() && i < 100; i++) {
                JSONObject pj = parses.optJSONObject(i);
                if (pj == null) continue;
                int pType = Json.integer(pj, "type", 0);
                String pUrl = Json.str(pj, "url", "").trim();
                String pName = Json.str(pj, "name", "").trim();
                if (pUrl.length() > 0
                        && !pUrl.startsWith("http://")
                        && !pUrl.startsWith("https://")
                        && base != null
                        && base.length() > 0
                        && (pUrl.startsWith("./") || pUrl.startsWith("../") || pUrl.startsWith("/"))) {
                    try {
                        pUrl = new URL(new URL(base), pUrl).toString();
                    } catch (Exception ignored) {
                    }
                }
                boolean httpParse = pUrl.startsWith("http://") || pUrl.startsWith("https://");
                if (pType == 0) {
                    hasWebSniffParse = true;
                    continue;
                }
                if ((pType == 1 || pType == 2 || pType == 3)
                        && httpParse
                        && !isScriptOrJarApi(pUrl)) {
                    Parse parsedItem = new Parse();
                    parsedItem.name = pName.length() > 0 ? pName : ("JSON 解析 " + (supportedJsonParses.size() + 1));
                    parsedItem.url = pUrl;
                    parsedItem.type = pType;
                    putSafeHeaders(parsedItem.headers, pj.optJSONObject("header"));
                    putSafeHeaders(parsedItem.headers, pj.optJSONObject("headers"));
                    JSONObject pExt = pj.optJSONObject("ext");
                    if (pExt != null) {
                        putSafeHeaders(parsedItem.headers, pExt.optJSONObject("header"));
                        putSafeHeaders(parsedItem.headers, pExt.optJSONObject("headers"));
                        JSONArray flagArr = pExt.optJSONArray("flag");
                        if (flagArr != null) {
                            for (int f = 0; f < flagArr.length(); f++) {
                                String fl = flagArr.optString(f, "").trim();
                                if (fl.length() > 0) parsedItem.flags.add(fl);
                            }
                        }
                    }
                    supportedJsonParses.add(parsedItem);
                } else {
                    hasScriptParse = true;
                }
            }
        }
        Parse defaultJsonParse = supportedJsonParses.isEmpty() ? null : supportedJsonParses.get(0);
        String defaultUnsupportedParseReason =
                hasWebSniffParse
                        ? "配置中的解析接口仅包含网页嗅探解析 (type=0)，轻量版仅支持 HTTP(S) JSON 解析与可播直链"
                        : (hasScriptParse
                                ? "配置中的解析接口依赖外部脚本或插件，轻量版仅支持 HTTP(S) JSON 解析与可播直链"
                                : "");
        List<Site> sites = new ArrayList<Site>();
        for (int i = 0; i < rows.length() && i < 500; i++) {
            JSONObject row = rows.getJSONObject(i);
            Site s = new Site();
            s.name = Json.str(row, "name", "未命名");
            s.key = Json.str(row, "key", s.name + "_" + i);
            s.originalKey = s.key;
            String parsedGroup = Json.str(row, "group", "").trim();
            s.group = parsedGroup.length() > 0 ? parsedGroup : "默认分组";
            s.type = Json.integer(row, "type", -1);
            s.api = Json.str(row, "api", "");
            s.playUrl = Json.str(row, "playUrl", "").trim();
            boolean siteRequestsParse =
                    Json.integer(row, "parse", 0) == 1 || Json.integer(row, "jx", 0) == 1;
            if (s.playUrl.length() == 0 && siteRequestsParse) {
                if (defaultJsonParse != null) {
                    s.playUrl = defaultJsonParse.url;
                    s.playUrlParseType = defaultJsonParse.type;
                    s.playUrlHeaders.putAll(defaultJsonParse.headers);
                    s.jsonParses.addAll(supportedJsonParses);
                } else {
                    s.unsupportedParseReason = defaultUnsupportedParseReason;
                }
            } else if (s.playUrl.regionMatches(true, 0, "json:", 0, 5)) {
                s.playUrlParseType = 1;
                s.jsonParses.addAll(supportedJsonParses);
            } else if (siteRequestsParse && !supportedJsonParses.isEmpty()) {
                s.jsonParses.addAll(supportedJsonParses);
            }
            s.searchable = Json.integer(row, "searchable", 1) != 0;
            s.ext = row.opt("ext");
            s.requiresParser = s.playUrl.length() > 0 || siteRequestsParse;
            String rawJar = Json.str(row, "jar", "");
            if (rawJar.length() > 0) {
                if ((rawJar.startsWith("./") || rawJar.startsWith("../"))
                        && base != null
                        && base.length() > 0) {
                    try {
                        s.jar = new URL(new URL(base), rawJar).toString();
                    } catch (Exception ignored) {
                        s.jar = rawJar;
                    }
                } else {
                    s.jar = rawJar;
                }
            }
            if (base != null && base.length() > 0) {
                if (s.ext instanceof String) {
                    String extStr = (String) s.ext;
                    if (extStr.startsWith("./") || extStr.startsWith("../")) {
                        try {
                            s.ext = new URL(new URL(base), extStr).toString();
                        } catch (Exception ignored) {
                        }
                    }
                } else if (s.ext instanceof JSONObject) {
                    JSONObject extObj = (JSONObject) s.ext;
                    for (String field : new String[] {"json", "url", "rule"}) {
                        String val = Json.str(extObj, field, null);
                        if (val != null && (val.startsWith("./") || val.startsWith("../"))) {
                            try {
                                extObj.put(field, new URL(new URL(base), val).toString());
                            } catch (Exception ignored) {
                            }
                        }
                    }
                }
            }
            if (!s.api.startsWith("csp_")
                    && !s.api.startsWith("js_")
                    && base != null
                    && base.length() > 0) {
                try {
                    s.api = new URL(new URL(base), s.api).toString();
                } catch (Exception ignored) {
                }
            }
            s.originalApi = s.api;
            if (s.type == -1
                    && (s.api.startsWith("http://") || s.api.startsWith("https://"))
                    && (s.jar == null || s.jar.length() == 0)
                    && !isScriptOrJarApi(s.api)) {
                s.type = hasXmlInUrlPath(s.api) ? 0 : 1;
            }
            String checkPlayUrl =
                    s.playUrl.regionMatches(true, 0, "json:", 0, 5)
                            ? s.playUrl.substring(5).trim()
                            : s.playUrl;
            boolean directPlayUrl =
                    checkPlayUrl.length() == 0
                            || checkPlayUrl.startsWith("http://")
                            || checkPlayUrl.startsWith("https://");
            s.supported = Site.STATUS_OK.equals(s.capabilityStatus()) && directPlayUrl;
            String ua = Json.str(row, "ua", "");
            if (ua.length() > 0 && ua.indexOf('\r') < 0 && ua.indexOf('\n') < 0) {
                s.headers.put("User-Agent", ua);
            }
            putSafeHeaders(s.headers, row.optJSONObject("header"));
            putSafeHeaders(s.headers, row.optJSONObject("headers"));
            JSONObject extObj = row.optJSONObject("ext");
            if (extObj != null) {
                String extUa = Json.str(extObj, "ua", "");
                if (extUa.length() > 0 && extUa.indexOf('\r') < 0 && extUa.indexOf('\n') < 0) {
                    s.headers.put("User-Agent", extUa);
                }
                putSafeHeaders(s.headers, extObj.optJSONObject("header"));
                putSafeHeaders(s.headers, extObj.optJSONObject("headers"));
            }
            sites.add(s);
        }
        return sites;
    }

    public static void applySiteOverride(Site s, JSONObject ov) {
        if (s == null || ov == null) return;
        if (s.originalKey == null || s.originalKey.length() == 0) s.originalKey = s.key;
        if (s.originalApi == null || s.originalApi.length() == 0) s.originalApi = s.api;
        if (ov.has("name")) {
            String n = ov.optString("name", "").trim();
            if (n.length() > 0) s.name = n;
        }
        if (ov.has("group")) {
            String g = ov.optString("group", "").trim();
            s.group = g.length() > 0 ? g : "默认分组";
        }
        if (ov.has("api")) {
            String a = ov.optString("api", "").trim();
            if (a.length() > 0) {
                s.api = a;
                if ((a.startsWith("http://") || a.startsWith("https://"))
                        && !isScriptOrJarApi(a)) {
                    s.jar = "";
                    s.type = hasXmlInUrlPath(a) ? 0 : 1;
                }
            }
        }
        if (ov.has("playUrl")) {
            s.playUrl = ov.optString("playUrl", "").trim();
        }
        if (ov.has("ext")) {
            String e = ov.optString("ext", "").trim();
            if (e.length() == 0) {
                s.ext = null;
                s.extTooLarge = false;
            } else {
                s.ext = e;
                s.extTooLarge = e.length() > Site.MAX_EXT_SIZE;
            }
        }
        if (ov.has("searchable")) {
            s.searchable = ov.optBoolean("searchable", s.searchable);
        }
        String checkPlayUrl =
                s.playUrl == null
                        ? ""
                        : (s.playUrl.regionMatches(true, 0, "json:", 0, 5)
                                ? s.playUrl.substring(5).trim()
                                : s.playUrl);
        boolean directPlayUrl =
                checkPlayUrl.length() == 0
                        || checkPlayUrl.startsWith("http://")
                        || checkPlayUrl.startsWith("https://");
        s.supported = Site.STATUS_OK.equals(s.capabilityStatus()) && directPlayUrl;
    }

    public static List<Site> applySiteEditsToList(List<Site> rawSites, JSONObject saved) {
        if (rawSites == null) return new ArrayList<Site>();
        if (saved == null) return new ArrayList<Site>(rawSites);
        JSONObject overrides = saved.optJSONObject("overrides");
        Set<String> hiddenSet = new HashSet<String>();
        JSONArray hidden = saved.optJSONArray("hidden");
        if (hidden != null) {
            for (int i = 0; i < hidden.length(); i++) {
                String k = hidden.optString(i, "");
                if (k.length() > 0) hiddenSet.add(k);
            }
        }
        Map<String, Site> pending = new LinkedHashMap<String, Site>();
        Map<String, String> keyToId = new LinkedHashMap<String, String>();
        for (int i = 0; i < rawSites.size(); i++) {
            Site site = rawSites.get(i);
            String id = site.siteId();
            if (hiddenSet.contains(id) || hiddenSet.contains(site.key)) continue;
            if (overrides != null) {
                JSONObject ov = overrides.optJSONObject(id);
                if (ov == null) ov = overrides.optJSONObject(site.key);
                if (ov != null) applySiteOverride(site, ov);
            }
            if (site.group == null || site.group.trim().length() == 0) site.group = "默认分组";
            pending.put(id, site);
            if (!keyToId.containsKey(site.key)) keyToId.put(site.key, id);
        }
        List<Site> result = new ArrayList<Site>();
        JSONArray order = saved.optJSONArray("order");
        if (order != null) {
            for (int i = 0; i < order.length(); i++) {
                String tok = order.optString(i);
                Site site = pending.remove(tok);
                if (site == null) {
                    String mappedId = keyToId.get(tok);
                    if (mappedId != null) site = pending.remove(mappedId);
                }
                if (site != null) result.add(site);
            }
        }
        result.addAll(pending.values());
        return result;
    }

    private static void putSafeHeaders(Map<String, String> target, JSONObject hs) {
        if (hs == null) return;
        Iterator<String> keys = hs.keys();
        while (keys.hasNext()) {
            String k = keys.next();
            if (k == null || k.length() == 0 || hs.isNull(k)) continue;
            String v = Json.str(hs, k, "");
            if (k.indexOf('\r') < 0
                    && k.indexOf('\n') < 0
                    && v.indexOf('\r') < 0
                    && v.indexOf('\n') < 0) {
                for (Iterator<String> it = target.keySet().iterator(); it.hasNext(); ) {
                    if (it.next().equalsIgnoreCase(k)) {
                        it.remove();
                    }
                }
                if ("user-agent".equalsIgnoreCase(k)) k = "User-Agent";
                else if ("referer".equalsIgnoreCase(k)) k = "Referer";
                else if ("cookie".equalsIgnoreCase(k)) k = "Cookie";
                else if ("origin".equalsIgnoreCase(k)) k = "Origin";
                else if ("authorization".equalsIgnoreCase(k)) k = "Authorization";
                target.put(k, v);
            }
        }
    }

    public static List<Category> categories(String raw) {
        List<Category> out = new ArrayList<Category>();
        try {
            JSONObject obj = parseCmsResponse(raw);
            JSONArray arr = obj.optJSONArray("class");
            if (arr != null)
                for (int i = 0; i < Math.min(arr.length(), 30); i++) {
                    JSONObject c = arr.optJSONObject(i);
                    if (c == null) continue;
                    String id = c.optString("type_id").trim(),
                            name = c.optString("type_name").trim();
                    if (id.length() > 0 && name.length() > 0) {
                        Category cat = new Category();
                        cat.id = id;
                        cat.name = name;
                        out.add(cat);
                    }
                }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static JSONObject parseCmsResponse(String raw) throws Exception {
        if (raw == null) throw new IOException("空响应");
        String trimmed = raw.trim();
        if (trimmed.startsWith("\ufeff")) trimmed = trimmed.substring(1).trim();
        JSONObject root = trimmed.startsWith("<") ? parseXmlCms(trimmed) : new JSONObject(trimmed);
        if (!root.has("list") && root.has("data") && root.optJSONObject("data") != null) {
            JSONObject data = root.optJSONObject("data");
            if (data.has("list")) {
                root.put("list", data.get("list"));
            }
            if (!root.has("page") && data.has("page")) root.put("page", data.get("page"));
            if (!root.has("pagecount") && data.has("pagecount"))
                root.put("pagecount", data.get("pagecount"));
            if (!root.has("total") && data.has("total")) root.put("total", data.get("total"));
            if (!root.has("limit") && data.has("limit")) root.put("limit", data.get("limit"));
        }
        return root;
    }

    public static JSONObject parseXmlCms(String xml) throws Exception {
        XmlPullParser parser = Xml.newPullParser();
        parser.setInput(new StringReader(xml));
        JSONArray classes = new JSONArray();
        JSONArray list = new JSONArray();
        int page = 1, pagecount = 1;
        JSONObject currentVideo = null;
        List<String> froms = new ArrayList<String>();
        List<String> urls = new ArrayList<String>();
        String currentDdFlag = "";
        int event = parser.getEventType();
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG) {
                String tag = parser.getName();
                if ("list".equalsIgnoreCase(tag)) {
                    try {
                        String pg = parser.getAttributeValue(null, "page");
                        String pc = parser.getAttributeValue(null, "pagecount");
                        if (pg != null) page = Math.max(1, Integer.parseInt(pg.trim()));
                        if (pc != null) pagecount = Math.max(1, Integer.parseInt(pc.trim()));
                    } catch (Exception ignored) {
                    }
                } else if ("ty".equalsIgnoreCase(tag)) {
                    String id = parser.getAttributeValue(null, "id");
                    String name = safeNextText(parser).trim();
                    if (id != null && id.trim().length() > 0 && name.length() > 0) {
                        classes.put(
                                new JSONObject().put("type_id", id.trim()).put("type_name", name));
                    }
                } else if ("video".equalsIgnoreCase(tag)) {
                    currentVideo = new JSONObject();
                    froms.clear();
                    urls.clear();
                } else if (currentVideo != null) {
                    if ("id".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_id", safeNextText(parser).trim());
                    } else if ("name".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_name", safeNextText(parser).trim());
                    } else if ("pic".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_pic", safeNextText(parser).trim());
                    } else if ("type".equalsIgnoreCase(tag)) {
                        currentVideo.put("type_name", safeNextText(parser).trim());
                    } else if ("year".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_year", safeNextText(parser).trim());
                    } else if ("area".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_area", safeNextText(parser).trim());
                    } else if ("note".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_remarks", safeNextText(parser).trim());
                    } else if ("actor".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_actor", safeNextText(parser).trim());
                    } else if ("director".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_director", safeNextText(parser).trim());
                    } else if ("des".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_content", safeNextText(parser).trim());
                    } else if ("dd".equalsIgnoreCase(tag)) {
                        String flag = parser.getAttributeValue(null, "flag");
                        currentDdFlag =
                                flag != null && flag.trim().length() > 0
                                        ? flag.trim()
                                        : ("线路" + (froms.size() + 1));
                        String playData = safeNextText(parser).trim();
                        if (playData.length() > 0) {
                            froms.add(currentDdFlag);
                            urls.add(playData);
                        }
                    }
                }
            } else if (event == XmlPullParser.END_TAG) {
                String tag = parser.getName();
                if ("video".equalsIgnoreCase(tag) && currentVideo != null) {
                    if (currentVideo.optString("vod_id").length() > 0
                            && currentVideo.optString("vod_name").length() > 0) {
                        if (!froms.isEmpty()) {
                            currentVideo.put("vod_play_from", join(froms, "$$$"));
                            currentVideo.put("vod_play_url", join(urls, "$$$"));
                        }
                        list.put(currentVideo);
                    }
                    currentVideo = null;
                }
            }
            event = parser.next();
        }
        return new JSONObject()
                .put("page", page)
                .put("pagecount", pagecount)
                .put("class", classes)
                .put("list", list);
    }

    private static String safeNextText(XmlPullParser parser) {
        try {
            String t = parser.nextText();
            return t == null ? "" : t;
        } catch (Exception e) {
            return "";
        }
    }

    private static String join(List<String> items, String sep) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(sep);
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    public static String query(String api, String... pairs) throws Exception {
        StringBuilder b = new StringBuilder(api);
        for (int i = 0; i < pairs.length; i += 2)
            b.append(b.indexOf("?") < 0 ? '?' : '&')
                    .append(URLEncoder.encode(pairs[i], "UTF-8"))
                    .append('=')
                    .append(URLEncoder.encode(pairs[i + 1], "UTF-8"));
        return b.toString();
    }

    public static JSONArray list(String raw) throws Exception {
        JSONArray a = parseCmsResponse(raw).optJSONArray("list");
        if (a == null) throw new IOException("返回内容不是 CMS 列表");
        return a;
    }

    public static List<LiveSource> parseLives(String rawConfig, String base) {
        if (rawConfig == null || rawConfig.trim().length() == 0) {
            return new ArrayList<LiveSource>();
        }
        try {
            JSONObject doc = decodeConfig(rawConfig);
            return parseLivesFromDocument(doc, base);
        } catch (Exception ignored) {
            return new ArrayList<LiveSource>();
        }
    }

    private static List<LiveSource> parseLivesFromDocument(JSONObject doc, String base) {
        List<LiveSource> out = new ArrayList<LiveSource>();
        if (doc == null) return out;
        base = Json.str(doc, com.pilipala.source.Warehouse.ORIGIN, base);
        JSONArray lives = doc.optJSONArray("lives");
        if (lives == null) return out;

        Map<String, LiveGroup> inlineGroups = new LinkedHashMap<String, LiveGroup>();
        Map<String, LiveChannel> inlineChannelMap = new LinkedHashMap<String, LiveChannel>();
        String inlineSourceName = "";

        for (int i = 0; i < lives.length() && out.size() < 32; i++) {
            JSONObject item = lives.optJSONObject(i);
            if (item == null) continue;
            JSONArray channels = item.optJSONArray("channels");
            if (channels != null && channels.length() > 0) {
                String itemGroup =
                        Json.str(item, "group", Json.str(item, "name", "")).trim();
                Map<String, String> itemHeaders = extractLiveMetaHeaders(item);
                for (int j = 0; j < channels.length() && inlineChannelMap.size() < 800; j++) {
                    JSONObject ch = channels.optJSONObject(j);
                    if (ch == null) continue;
                    String chName = Json.str(ch, "name", "").trim();
                    String chGroup = Json.str(ch, "group", itemGroup).trim();
                    if (chGroup.length() == 0) chGroup = "直播频道";
                    Map<String, String> chHeaders = new LinkedHashMap<String, String>(itemHeaders);
                    mergeLiveMetaHeaders(chHeaders, ch);

                    List<String> rawUrls = new ArrayList<String>();
                    JSONArray urlsArr = ch.optJSONArray("urls");
                    if (urlsArr != null && urlsArr.length() > 0) {
                        for (int k = 0; k < urlsArr.length(); k++) {
                            String candidate = urlsArr.optString(k, "").trim();
                            if (candidate.length() > 0) rawUrls.add(candidate);
                        }
                    } else {
                        String single = Json.str(ch, "url", "").trim();
                        if (single.length() > 0) rawUrls.add(single);
                    }
                    if (rawUrls.isEmpty()) continue;

                    boolean allProxyEntries = true;
                    for (int k = 0; k < rawUrls.size(); k++) {
                        if (!rawUrls.get(k).startsWith("proxy://")) {
                            allProxyEntries = false;
                            break;
                        }
                    }
                    if (allProxyEntries) {
                        for (int k = 0; k < rawUrls.size() && out.size() < 32; k++) {
                            addLiveSourceItem(
                                    out,
                                    chName.length() > 0 ? chName : chGroup,
                                    rawUrls.get(k),
                                    item,
                                    base);
                        }
                        continue;
                    }

                    if (inlineSourceName.length() == 0) {
                        String n = Json.str(item, "name", "").trim();
                        inlineSourceName = n.length() > 0 ? n : (itemGroup.length() > 0 ? itemGroup : "内置直播");
                    }
                    String effectiveName =
                            chName.length() > 0
                                    ? chName
                                    : ("频道 " + (inlineChannelMap.size() + 1));
                    for (int k = 0; k < rawUrls.size(); k++) {
                        String entry = rawUrls.get(k);
                        if (entry.startsWith("proxy://")) {
                            addLiveSourceItem(out, effectiveName, entry, item, base);
                            continue;
                        }
                        for (String part : entry.split("#")) {
                            addChannelUrl(
                                    inlineGroups,
                                    inlineChannelMap,
                                    chGroup,
                                    effectiveName,
                                    part.trim(),
                                    chHeaders,
                                    base);
                        }
                    }
                }
            } else {
                addLiveSourceItem(
                        out,
                        Json.str(item, "name", "直播源 " + (out.size() + 1)),
                        Json.str(item, "url", ""),
                        item,
                        base);
            }
        }
        if (!inlineGroups.isEmpty()) {
            LiveSource inlineSrc = new LiveSource();
            inlineSrc.name = inlineSourceName.length() > 0 ? inlineSourceName : "内置直播";
            inlineSrc.url = "";
            inlineSrc.inlineGroups.addAll(inlineGroups.values());
            out.add(0, inlineSrc);
        }
        return out;
    }

    private static Map<String, String> extractLiveMetaHeaders(JSONObject meta) {
        Map<String, String> headers = new LinkedHashMap<String, String>();
        mergeLiveMetaHeaders(headers, meta);
        return headers;
    }

    private static void mergeLiveMetaHeaders(Map<String, String> target, JSONObject meta) {
        if (meta == null) return;
        String ua = Json.str(meta, "ua", "").trim();
        if (ua.length() > 0) putSafeSingleHeader(target, "User-Agent", ua);
        String ref = Json.str(meta, "referer", Json.str(meta, "Referer", "")).trim();
        if (ref.length() > 0) putSafeSingleHeader(target, "Referer", ref);
        putSafeHeaders(target, meta.optJSONObject("header"));
        putSafeHeaders(target, meta.optJSONObject("headers"));
    }

    private static void addLiveSourceItem(
            List<LiveSource> out, String name, String rawUrl, JSONObject meta, String base) {
        if (rawUrl == null) return;
        String u = rawUrl.trim();
        if (u.length() == 0) return;
        if (u.startsWith("proxy://")) {
            int extIdx = u.indexOf("ext=");
            if (extIdx > 0) {
                String ext = u.substring(extIdx + 4);
                int amp = ext.indexOf('&');
                if (amp > 0) ext = ext.substring(0, amp);
                try {
                    String decoded =
                            new String(
                                    Base64.decode(
                                            URLDecoder.decode(ext, "UTF-8"),
                                            Base64.DEFAULT | Base64.URL_SAFE),
                                    "UTF-8")
                                    .trim();
                    if (decoded.startsWith("http://") || decoded.startsWith("https://")) {
                        u = decoded;
                    }
                } catch (Exception ignored) {
                }
            }
        } else if (!u.startsWith("http://")
                && !u.startsWith("https://")
                && base != null
                && base.length() > 0) {
            try {
                u = new URL(new URL(base), u).toString();
            } catch (Exception ignored) {
            }
        }
        if (!(u.startsWith("http://") || u.startsWith("https://") || u.startsWith("proxy://"))) {
            return;
        }
        LiveSource src = new LiveSource();
        src.name = name == null || name.trim().length() == 0 ? "直播源" : name.trim();
        src.url = u;
        mergeLiveMetaHeaders(src.headers, meta);
        out.add(src);
    }

    public static List<LiveGroup> fetchLiveGroups(LiveSource src) throws Exception {
        if (src == null) return Collections.emptyList();
        if (!src.inlineGroups.isEmpty()) {
            return src.inlineGroups;
        }
        if (src.url == null || src.url.trim().length() == 0) return Collections.emptyList();
        String u = src.url.trim();
        String content;
        String baseUrl = null;
        if (u.startsWith("proxy://")) {
            int extIdx = u.indexOf("ext=");
            if (extIdx < 0) throw new IOException("不支持的代理直播地址");
            String ext = u.substring(extIdx + 4);
            int amp = ext.indexOf('&');
            if (amp > 0) ext = ext.substring(0, amp);
            String decoded =
                    new String(
                                    Base64.decode(
                                            URLDecoder.decode(ext, "UTF-8"),
                                            Base64.DEFAULT | Base64.URL_SAFE),
                                    "UTF-8")
                            .trim();
            if (decoded.startsWith("http://") || decoded.startsWith("https://")) {
                FetchResult res = fetchWithFinalUrl(decoded, src.headers);
                content = res.body;
                baseUrl = res.finalUrl;
            } else {
                content = decoded;
            }
        } else {
            FetchResult res = fetchWithFinalUrl(u, src.headers);
            content = res.body;
            baseUrl = res.finalUrl;
        }
        return parseLiveContent(content, baseUrl);
    }

    public static List<LiveGroup> parseLiveContent(String raw) {
        return parseLiveContent(raw, null);
    }

    public static List<LiveGroup> parseLiveContent(String raw, String baseUrl) {
        if (raw == null) return Collections.emptyList();
        String text = raw.trim();
        if (text.startsWith("\ufeff")) text = text.substring(1).trim();
        int star = text.indexOf("**");
        if (star >= 0 && !text.startsWith("#EXTM3U") && !text.contains(",#genre#")) {
            try {
                text =
                        new String(
                                        Base64.decode(
                                                text.substring(star + 2).replaceAll("\\s+", ""),
                                                Base64.DEFAULT),
                                        "UTF-8")
                                .trim();
            } catch (Exception ignored) {
            }
        } else if (!text.startsWith("#EXTM3U")
                && !text.contains(",#genre#")
                && !text.contains("http://")
                && !text.contains("https://")
                && !text.contains("#EXTINF:")) {
            try {
                String decoded =
                        new String(Base64.decode(text.replaceAll("\\s+", ""), Base64.DEFAULT), "UTF-8")
                                .trim();
                if (decoded.contains("http://")
                        || decoded.contains("https://")
                        || decoded.startsWith("#EXTM3U")
                        || decoded.contains(",#genre#")) text = decoded;
            } catch (Exception ignored) {
            }
        }
        Map<String, LiveGroup> groups = new LinkedHashMap<String, LiveGroup>();
        Map<String, LiveChannel> channelMap = new LinkedHashMap<String, LiveChannel>();
        String[] lines = text.split("\r?\n");
        boolean isM3u = text.startsWith("#EXTM3U") || text.contains("#EXTINF:");
        if (isM3u) {
            String currentGroup = "直播频道";
            String currentName = "";
            Map<String, String> pendingHeaders = new LinkedHashMap<String, String>();
            for (int i = 0; i < lines.length && channelMap.size() < 800; i++) {
                String line = lines[i].trim();
                if (line.length() == 0) continue;
                if (line.startsWith("#EXTINF:")) {
                    currentGroup = extractAttr(line, "group-title", "直播频道");
                    int comma = line.lastIndexOf(',');
                    currentName =
                            comma >= 0 && comma + 1 < line.length()
                                    ? line.substring(comma + 1).trim()
                                    : extractAttr(line, "tvg-name", "频道");
                    String extUa = extractAttr(line, "http-user-agent", "");
                    if (extUa.length() == 0) extUa = extractAttr(line, "user-agent", "");
                    if (extUa.length() > 0) putSafeSingleHeader(pendingHeaders, "User-Agent", extUa);
                    String extRef = extractAttr(line, "http-referrer", "");
                    if (extRef.length() == 0) extRef = extractAttr(line, "http-referer", "");
                    if (extRef.length() == 0) extRef = extractAttr(line, "referer", "");
                    if (extRef.length() > 0) putSafeSingleHeader(pendingHeaders, "Referer", extRef);
                } else if (line.startsWith("#EXTGRP:")) {
                    String g = line.substring(8).trim();
                    if (g.length() > 0) currentGroup = g;
                } else if (line.regionMatches(true, 0, "#EXTVLCOPT:http-user-agent=", 0, 27)) {
                    putSafeSingleHeader(pendingHeaders, "User-Agent", line.substring(27).trim());
                } else if (line.regionMatches(true, 0, "#EXTVLCOPT:http-referrer=", 0, 25)) {
                    putSafeSingleHeader(pendingHeaders, "Referer", line.substring(25).trim());
                } else if (line.regionMatches(true, 0, "#EXTVLCOPT:http-referer=", 0, 24)) {
                    putSafeSingleHeader(pendingHeaders, "Referer", line.substring(24).trim());
                } else if (line.regionMatches(true, 0, "#EXTVLCOPT:http-origin=", 0, 23)) {
                    putSafeSingleHeader(pendingHeaders, "Origin", line.substring(23).trim());
                } else if (!line.startsWith("#")) {
                    addChannelUrl(
                            groups,
                            channelMap,
                            currentGroup,
                            currentName.length() > 0 ? currentName : "频道 " + (channelMap.size() + 1),
                            line,
                            pendingHeaders,
                            baseUrl);
                    currentName = "";
                    pendingHeaders = new LinkedHashMap<String, String>();
                }
            }
        } else {
            String currentGroup = "默认分组";
            for (int i = 0; i < lines.length && channelMap.size() < 800; i++) {
                String line = lines[i].trim();
                if (line.length() == 0 || line.startsWith("#") || line.startsWith("//")) continue;
                int comma = line.indexOf(',');
                if (comma <= 0) continue;
                String left = line.substring(0, comma).trim();
                String right = line.substring(comma + 1).trim();
                if (right.startsWith("#genre#")) {
                    if (left.length() > 0) currentGroup = left;
                    continue;
                }
                for (String u : right.split("#")) {
                    addChannelUrl(
                            groups,
                            channelMap,
                            currentGroup,
                            left,
                            u.trim(),
                            Collections.<String, String>emptyMap(),
                            baseUrl);
                }
            }
        }
        return new ArrayList<LiveGroup>(groups.values());
    }

    private static void addChannelUrl(
            Map<String, LiveGroup> groups,
            Map<String, LiveChannel> channelMap,
            String groupName,
            String chName,
            String rawUrl,
            Map<String, String> extraHeaders,
            String baseUrl) {
        if (rawUrl == null || rawUrl.length() == 0) return;
        String urlPart = rawUrl.trim();
        Map<String, String> inlineHeaders = new LinkedHashMap<String, String>();
        if (extraHeaders != null) {
            for (Map.Entry<String, String> e : extraHeaders.entrySet()) {
                putSafeSingleHeader(inlineHeaders, e.getKey(), e.getValue());
            }
        }
        int pipe = urlPart.indexOf('|');
        if (pipe > 0) {
            String tail = urlPart.substring(pipe + 1);
            urlPart = urlPart.substring(0, pipe).trim();
            for (String kv : tail.split("&|\\|")) {
                int eq = kv.indexOf('=');
                if (eq > 0) {
                    String k = kv.substring(0, eq).trim();
                    String v = kv.substring(eq + 1).trim();
                    if ("referer".equalsIgnoreCase(k) || "referrer".equalsIgnoreCase(k)) {
                        putSafeSingleHeader(inlineHeaders, "Referer", v);
                    } else if ("user-agent".equalsIgnoreCase(k) || "ua".equalsIgnoreCase(k)) {
                        putSafeSingleHeader(inlineHeaders, "User-Agent", v);
                    } else if ("origin".equalsIgnoreCase(k)) {
                        putSafeSingleHeader(inlineHeaders, "Origin", v);
                    } else if ("cookie".equalsIgnoreCase(k)) {
                        putSafeSingleHeader(inlineHeaders, "Cookie", v);
                    }
                }
            }
        }
        int dollar = urlPart.indexOf('$');
        if (dollar >= 0) {
            String left = urlPart.substring(0, dollar).trim();
            String right = urlPart.substring(dollar + 1).trim();
            boolean leftIsHttp =
                    left.startsWith("http://") || left.startsWith("https://");
            boolean rightLooksLikeUrl =
                    right.startsWith("http://")
                            || right.startsWith("https://")
                            || right.startsWith("/")
                            || right.startsWith("./")
                            || right.startsWith("../")
                            || right.toLowerCase(Locale.ROOT).contains(".m3u8")
                            || right.toLowerCase(Locale.ROOT).contains(".mp4")
                            || right.toLowerCase(Locale.ROOT).contains(".flv")
                            || right.toLowerCase(Locale.ROOT).contains(".ts");
            if (!leftIsHttp && rightLooksLikeUrl) {
                urlPart = right;
            } else if (left.length() > 0) {
                urlPart = left;
            }
        }
        if (!urlPart.startsWith("http://")
                && !urlPart.startsWith("https://")
                && baseUrl != null
                && baseUrl.length() > 0) {
            try {
                urlPart = new URL(new URL(baseUrl), urlPart).toString();
            } catch (Exception ignored) {
            }
        }
        try {
            urlPart = http(urlPart);
        } catch (Exception invalid) {
            return;
        }
        String gKey = groupName == null || groupName.length() == 0 ? "直播频道" : groupName;
        LiveGroup grp = groups.get(gKey);
        if (grp == null) {
            grp = new LiveGroup();
            grp.name = gKey;
            groups.put(gKey, grp);
        }
        String chKey = gKey + "\n" + chName;
        LiveChannel ch = channelMap.get(chKey);
        if (ch == null) {
            ch = new LiveChannel();
            ch.name = chName;
            ch.group = gKey;
            ch.headers.putAll(inlineHeaders);
            channelMap.put(chKey, ch);
            grp.channels.add(ch);
        }
        boolean duplicate = false;
        for (int i = 0; i < ch.urls.size(); i++) {
            if (urlPart.equals(ch.urls.get(i)) && inlineHeaders.equals(ch.headersForLine(i))) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            ch.urls.add(urlPart);
            ch.lineHeaders.add(new LinkedHashMap<String, String>(inlineHeaders));
        }
    }

    private static String extractAttr(String line, String attr, String fallback) {
        int idx = line.indexOf(attr + "=\"");
        if (idx >= 0) {
            int start = idx + attr.length() + 2;
            int end = line.indexOf('"', start);
            if (end > start) {
                String v = line.substring(start, end).trim();
                if (v.length() > 0) return v;
            }
        }
        return fallback;
    }
}

// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import java.util.zip.Inflater;
import java.util.zip.InflaterInputStream;
import javax.xml.parsers.DocumentBuilderFactory;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/**
 * Clean-room Dandanplay Open API v2 compatible segmented/full-episode {@link DanmuProvider}.
 *
 * <p>Default server list is strictly empty (zero hardcoded third-party domains or API keys). Uses
 * built-in zero-dependency RFC 4648 Base64/Base64url and SHA-256 helpers for Android API 23 and
 * pure-JVM compatibility.
 */
public final class DandanplayProvider implements DanmuProvider {

    public static final String DEFAULT_SERVER_URLS = "";
    public static final int MAX_SERVERS = 8;
    public static final int DEFAULT_MAX_CONCURRENCY = 4;
    public static final int CONNECT_TIMEOUT_MS = 5000;
    public static final int READ_TIMEOUT_MS = 8000;
    public static final long DEFAULT_MIN_REQUEST_INTERVAL_MS = 200L;
    public static final long DEFAULT_RETRY_AFTER_MS = 2000L;
    public static final int WINDOW_DURATION_MS = 30000;
    public static final int MAX_WINDOW_ITEMS = 1500;
    public static final int MAX_FULL_EPISODE_ITEMS = 20000;
    public static final int MAX_PAYLOAD_BYTES = 8 * 1024 * 1024;
    public static final int MAX_TEXT_LENGTH = 180;
    public static final String BOUND_URI_PREFIX = "mmdanmu://v1?";

    private static final Charset UTF_8 = Charset.forName("UTF-8");
    private static final char[] B64_STD =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();
    private static final char[] B64_URL =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toCharArray();
    private static final int[] B64_URL_DEC = new int[128];

    static {
        for (int i = 0; i < B64_URL_DEC.length; i++) B64_URL_DEC[i] = -1;
        for (int i = 0; i < B64_URL.length; i++) B64_URL_DEC[B64_URL[i]] = i;
    }

    public static final class BoundEpisode {
        public final String origin;
        public final String rawEpisodeId;

        public BoundEpisode(String origin, String rawEpisodeId) {
            this.origin = origin;
            this.rawEpisodeId = rawEpisodeId;
        }
    }

    public static final Comparator<DanmuItem> ITEM_ORDER =
            new Comparator<DanmuItem>() {
                @Override
                public int compare(DanmuItem a, DanmuItem b) {
                    if (a.timeMs != b.timeMs) {
                        return a.timeMs < b.timeMs ? -1 : 1;
                    }
                    return a.id.compareTo(b.id);
                }
            };

    private final List<String> configuredOrigins;
    private final Set<String> originWhitelist;
    private final String appId;
    private final String appSecret;
    private final int maxConcurrency;
    private final long minRequestIntervalMs;
    private final ConcurrentHashMap<String, Long> domainNextAllowedMs = new ConcurrentHashMap<>();

    public DandanplayProvider() {
        this(DEFAULT_SERVER_URLS, "", "", DEFAULT_MAX_CONCURRENCY, DEFAULT_MIN_REQUEST_INTERVAL_MS);
    }

    public DandanplayProvider(String multilineServerUrls, String appId, String appSecret) {
        this(
                multilineServerUrls,
                appId,
                appSecret,
                DEFAULT_MAX_CONCURRENCY,
                DEFAULT_MIN_REQUEST_INTERVAL_MS);
    }

    public DandanplayProvider(
            String multilineServerUrls,
            String appId,
            String appSecret,
            int maxConcurrency,
            long minRequestIntervalMs) {
        this.configuredOrigins = parseConfiguredOrigins(multilineServerUrls);
        this.originWhitelist = Collections.unmodifiableSet(new LinkedHashSet<>(configuredOrigins));
        this.appId = appId == null ? "" : appId.trim();
        this.appSecret = appSecret == null ? "" : appSecret.trim();
        this.maxConcurrency = Math.max(1, Math.min(5, maxConcurrency));
        this.minRequestIntervalMs = Math.max(0L, minRequestIntervalMs);
    }

    public List<String> getConfiguredOrigins() {
        return configuredOrigins;
    }

    // -------------------------------------------------------------------------
    // Zero-dependency RFC 4648 Base64 / Base64url (no padding) & SHA-256
    // -------------------------------------------------------------------------

    public static String base64UrlEncodeNoPad(byte[] input) {
        return encodeBase64(input, B64_URL, false);
    }

    public static String base64Encode(byte[] input) {
        return encodeBase64(input, B64_STD, true);
    }

    private static String encodeBase64(byte[] input, char[] alphabet, boolean pad) {
        if (input == null || input.length == 0) return "";
        StringBuilder out = new StringBuilder(((input.length + 2) / 3) * 4);
        int i = 0;
        while (i < input.length) {
            int b0 = input[i++] & 0xFF;
            boolean hasB1 = i < input.length;
            int b1 = hasB1 ? (input[i++] & 0xFF) : 0;
            boolean hasB2 = i < input.length;
            int b2 = hasB2 ? (input[i++] & 0xFF) : 0;
            int triple = (b0 << 16) | (b1 << 8) | b2;
            out.append(alphabet[(triple >>> 18) & 0x3F]);
            out.append(alphabet[(triple >>> 12) & 0x3F]);
            if (hasB1) {
                out.append(alphabet[(triple >>> 6) & 0x3F]);
            } else if (pad) {
                out.append('=');
            }
            if (hasB2) {
                out.append(alphabet[triple & 0x3F]);
            } else if (pad) {
                out.append('=');
            }
        }
        return out.toString();
    }

    public static byte[] base64UrlDecode(String encoded) throws IOException {
        if (encoded == null || encoded.isEmpty()) return new byte[0];
        int len = encoded.length();
        int rem = len % 4;
        if (rem == 1) {
            throw new IOException("Invalid base64url length");
        }
        int outLen = (len / 4) * 3 + (rem == 2 ? 1 : (rem == 3 ? 2 : 0));
        byte[] out = new byte[outLen];
        int outPos = 0;
        int i = 0;
        while (i < len) {
            int c0 = decodeB64UrlChar(encoded.charAt(i++));
            int c1 = decodeB64UrlChar(encoded.charAt(i++));
            int c2 = (i < len) ? decodeB64UrlChar(encoded.charAt(i++)) : -1;
            int c3 = (i < len) ? decodeB64UrlChar(encoded.charAt(i++)) : -1;
            out[outPos++] = (byte) ((c0 << 2) | (c1 >>> 4));
            if (c2 >= 0 && outPos < outLen) {
                out[outPos++] = (byte) (((c1 & 0x0F) << 4) | (c2 >>> 2));
            }
            if (c3 >= 0 && outPos < outLen) {
                out[outPos++] = (byte) (((c2 & 0x03) << 6) | c3);
            }
        }
        return out;
    }

    private static int decodeB64UrlChar(char ch) throws IOException {
        if (ch >= 128 || B64_URL_DEC[ch] < 0) {
            throw new IOException("Invalid base64url character: " + ch);
        }
        return B64_URL_DEC[ch];
    }

    public static byte[] sha256(byte[] input) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return digest.digest(input == null ? new byte[0] : input);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    public static String computeOpenApiSignature(
            String appId, long timestampSec, String urlPath, String appSecret) {
        String path = (urlPath == null || urlPath.isEmpty()) ? "/" : urlPath;
        String payload = appId + timestampSec + path + appSecret;
        return base64Encode(sha256(payload.getBytes(UTF_8)));
    }

    // -------------------------------------------------------------------------
    // Origin Normalization, Percent Encoding & SourceBoundEpisodeId (SSRF Guard)
    // -------------------------------------------------------------------------

    public static List<String> parseConfiguredOrigins(String multilineUrls) {
        if (multilineUrls == null || multilineUrls.trim().isEmpty()) {
            return Collections.emptyList();
        }
        LinkedHashSet<String> set = new LinkedHashSet<>();
        String[] lines = multilineUrls.split("\\r?\\n");
        for (String line : lines) {
            if (set.size() >= MAX_SERVERS) break;
            String normalized = normalizeOriginOrNull(line);
            if (normalized != null) {
                set.add(normalized);
            }
        }
        return Collections.unmodifiableList(new ArrayList<>(set));
    }

    public static String normalizeOriginOrNull(String raw) {
        if (raw == null) return null;
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return null;
        while (trimmed.endsWith("/")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        try {
            URI uri = URI.create(trimmed);
            String scheme = uri.getScheme();
            if (scheme == null) return null;
            String lowerScheme = scheme.toLowerCase(Locale.ROOT);
            if (!"http".equals(lowerScheme) && !"https".equals(lowerScheme)) {
                return null;
            }
            if (uri.getRawUserInfo() != null) return null;
            if (uri.getRawQuery() != null || uri.getRawFragment() != null) return null;
            String host = uri.getHost();
            if (host == null || host.isEmpty()) return null;
            int port = uri.getPort();
            String path = uri.getRawPath();
            if (path == null) path = "";
            while (path.endsWith("/")) {
                path = path.substring(0, path.length() - 1);
            }
            StringBuilder sb = new StringBuilder();
            sb.append(lowerScheme).append("://").append(host.toLowerCase(Locale.ROOT));
            if (port != -1
                    && !(("http".equals(lowerScheme) && port == 80)
                            || ("https".equals(lowerScheme) && port == 443))) {
                sb.append(':').append(port);
            }
            sb.append(path);
            return sb.toString();
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    public static String percentEncode(String value) {
        if (value == null || value.isEmpty()) return "";
        byte[] bytes = value.getBytes(UTF_8);
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            int v = b & 0xFF;
            if ((v >= 'A' && v <= 'Z')
                    || (v >= 'a' && v <= 'z')
                    || (v >= '0' && v <= '9')
                    || v == '-'
                    || v == '_'
                    || v == '.'
                    || v == '~') {
                sb.append((char) v);
            } else {
                sb.append('%');
                sb.append(Character.toUpperCase(Character.forDigit((v >>> 4) & 0xF, 16)));
                sb.append(Character.toUpperCase(Character.forDigit(v & 0xF, 16)));
            }
        }
        return sb.toString();
    }

    public static String percentDecode(String encoded) throws IOException {
        if (encoded == null || encoded.isEmpty()) return "";
        ByteArrayOutputStream out = new ByteArrayOutputStream(encoded.length());
        int len = encoded.length();
        for (int i = 0; i < len; i++) {
            char ch = encoded.charAt(i);
            if (ch == '%') {
                if (i + 2 >= len) throw new IOException("Truncated percent escape");
                int hi = Character.digit(encoded.charAt(i + 1), 16);
                int lo = Character.digit(encoded.charAt(i + 2), 16);
                if (hi < 0 || lo < 0) throw new IOException("Invalid percent escape");
                out.write((hi << 4) | lo);
                i += 2;
            } else {
                byte[] utf8 = String.valueOf(ch).getBytes(UTF_8);
                out.write(utf8, 0, utf8.length);
            }
        }
        return new String(out.toByteArray(), UTF_8);
    }

    public static String encodeBoundEpisodeId(String origin, String rawEpisodeId)
            throws IOException {
        String normOrigin = normalizeOriginOrNull(origin);
        if (normOrigin == null) {
            throw new IOException("无效弹幕服务地址: " + origin);
        }
        if (rawEpisodeId == null || rawEpisodeId.trim().isEmpty()) {
            throw new IOException("剧集弹幕标识不能为空");
        }
        String src = base64UrlEncodeNoPad(normOrigin.getBytes(UTF_8));
        String ep = percentEncode(rawEpisodeId.trim());
        return BOUND_URI_PREFIX + "src=" + src + "&ep=" + ep;
    }

    public static BoundEpisode decodeBoundEpisodeId(
            String boundEpisodeId, Collection<String> allowedOrigins) throws IOException {
        if (boundEpisodeId == null || !boundEpisodeId.startsWith(BOUND_URI_PREFIX)) {
            throw new IOException("非法的来源绑定弹幕标识");
        }
        String query = boundEpisodeId.substring(BOUND_URI_PREFIX.length());
        String srcParam = null;
        String epParam = null;
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            if (eq <= 0) continue;
            String k = pair.substring(0, eq);
            String v = pair.substring(eq + 1);
            if ("src".equals(k)) srcParam = v;
            else if ("ep".equals(k)) epParam = v;
        }
        if (srcParam == null || srcParam.isEmpty() || epParam == null || epParam.isEmpty()) {
            throw new IOException("来源绑定弹幕标识缺少 src 或 ep 参数");
        }
        String decodedOrigin = new String(base64UrlDecode(srcParam), UTF_8);
        String normOrigin = normalizeOriginOrNull(decodedOrigin);
        if (normOrigin == null) {
            throw new IOException("弹幕来源地址协议非法: " + decodedOrigin);
        }
        if (allowedOrigins == null || !allowedOrigins.contains(normOrigin)) {
            throw new IOException("弹幕来源地址不在用户白名单内: " + normOrigin);
        }
        String rawEp = percentDecode(epParam);
        if (rawEp.trim().isEmpty()) {
            throw new IOException("弹幕剧集标识为空");
        }
        return new BoundEpisode(normOrigin, rawEp);
    }

    private String validateSegmentUrl(String rawUrl, String boundOrigin) throws IOException {
        if (rawUrl == null || rawUrl.trim().isEmpty()) {
            throw new IOException("分片弹幕地址为空");
        }
        String candidate = rawUrl.trim();
        URI resolved;
        try {
            URI base = URI.create(boundOrigin + "/");
            resolved = base.resolve(candidate);
        } catch (IllegalArgumentException e) {
            throw new IOException("无效分片地址: " + candidate, e);
        }
        String scheme = resolved.getScheme();
        if (scheme == null
                || (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme))) {
            throw new IOException("不支持的分片协议: " + scheme);
        }
        if (resolved.getRawUserInfo() != null) {
            throw new IOException("分片地址禁止携带登录凭据");
        }
        if (!isUrlOriginAllowed(resolved, boundOrigin)) {
            throw new IOException("分片地址不在已配置服务白名单内: " + resolved.getHost());
        }
        return resolved.toString();
    }

    private boolean isUrlOriginAllowed(URI uri, String boundOrigin) {
        String host = uri.getHost();
        if (host == null || host.isEmpty()) return false;
        String targetScheme = uri.getScheme().toLowerCase(Locale.ROOT);
        int targetPort = effectivePort(targetScheme, uri.getPort());
        String targetHost = host.toLowerCase(Locale.ROOT);
        if (matchesOriginHostPort(boundOrigin, targetScheme, targetHost, targetPort)) {
            return true;
        }
        for (String allowed : originWhitelist) {
            if (matchesOriginHostPort(allowed, targetScheme, targetHost, targetPort)) {
                return true;
            }
        }
        return false;
    }

    private static boolean matchesOriginHostPort(
            String normalizedOrigin, String scheme, String host, int port) {
        if (normalizedOrigin == null || normalizedOrigin.isEmpty()) return false;
        URI o = URI.create(normalizedOrigin);
        String oScheme = o.getScheme().toLowerCase(Locale.ROOT);
        String oHost = o.getHost().toLowerCase(Locale.ROOT);
        int oPort = effectivePort(oScheme, o.getPort());
        return oScheme.equals(scheme) && oHost.equals(host) && oPort == port;
    }

    private static int effectivePort(String scheme, int port) {
        if (port > 0) return port;
        return "https".equalsIgnoreCase(scheme) ? 443 : 80;
    }

    // -------------------------------------------------------------------------
    // DanmuProvider 3-Stage Protocol
    // -------------------------------------------------------------------------

    private static final class OriginMatchOutcome {
        final List<Candidate> candidates;
        final IOException error;
        final boolean succeeded;

        OriginMatchOutcome(List<Candidate> candidates, IOException error, boolean succeeded) {
            this.candidates = candidates == null ? Collections.<Candidate>emptyList() : candidates;
            this.error = error;
            this.succeeded = succeeded;
        }
    }

    private static int errorPriority(IOException e) {
        if (e == null) return 0;
        if (e instanceof HttpStatusException) {
            int code = ((HttpStatusException) e).statusCode;
            if (code == 401 || code == 403) return 4;
            if (code == 429) return 3;
            return 2;
        }
        return 1;
    }

    private static final ExecutorService MATCH_POOL = createMatchPool();

    private static ExecutorService createMatchPool() {
        java.util.concurrent.ThreadPoolExecutor pool =
                new java.util.concurrent.ThreadPoolExecutor(
                        4,
                        4,
                        20L,
                        java.util.concurrent.TimeUnit.SECONDS,
                        new java.util.concurrent.LinkedBlockingQueue<Runnable>(),
                        new java.util.concurrent.ThreadFactory() {
                            @Override
                            public Thread newThread(Runnable r) {
                                Thread t = new Thread(r, "dandan-match");
                                t.setDaemon(true);
                                return t;
                            }
                        });
        pool.allowCoreThreadTimeOut(true);
        return pool;
    }

    @Override
    public List<Candidate> matchOrSearch(final MatchQuery query, final CancellationToken token)
            throws IOException {
        if (token != null) token.throwIfCancelled();
        if (configuredOrigins.isEmpty() || query == null) {
            return Collections.emptyList();
        }
        final ExecutorService pool = MATCH_POOL;
        List<Future<OriginMatchOutcome>> futures = new ArrayList<>();
        try {
            for (final String origin : configuredOrigins) {
                futures.add(
                        pool.submit(
                                new Callable<OriginMatchOutcome>() {
                                    @Override
                                    public OriginMatchOutcome call() {
                                        try {
                                            return new OriginMatchOutcome(
                                                    matchOrSearchSingleOrigin(origin, query, token),
                                                    null,
                                                    true);
                                        } catch (CancelledException cancelled) {
                                            return new OriginMatchOutcome(null, cancelled, false);
                                        } catch (IOException ioErr) {
                                            return new OriginMatchOutcome(null, ioErr, false);
                                        } catch (Exception other) {
                                            return new OriginMatchOutcome(
                                                    null, new IOException("弹幕匹配异常", other), false);
                                        }
                                    }
                                }));
            }
            List<Candidate> merged = new ArrayList<>();
            Set<String> seenBoundIds = new LinkedHashSet<>();
            boolean anySucceeded = false;
            IOException prioritizedError = null;
            for (Future<OriginMatchOutcome> future : futures) {
                if (token != null && token.isCancelled()) {
                    future.cancel(true);
                    continue;
                }
                try {
                    OriginMatchOutcome outcome = future.get();
                    if (outcome == null) continue;
                    if (outcome.error instanceof CancelledException) {
                        throw (CancelledException) outcome.error;
                    }
                    if (outcome.succeeded) {
                        anySucceeded = true;
                        for (Candidate c : outcome.candidates) {
                            if (seenBoundIds.add(c.boundEpisodeId)) {
                                merged.add(c);
                            }
                        }
                    } else if (outcome.error != null) {
                        if (prioritizedError == null
                                || errorPriority(outcome.error) > errorPriority(prioritizedError)) {
                            prioritizedError = outcome.error;
                        }
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new CancelledException("matchOrSearch interrupted");
                } catch (ExecutionException e) {
                    if (prioritizedError == null) {
                        prioritizedError = new IOException("弹幕匹配执行失败", e.getCause());
                    }
                }
            }
            if (token != null) token.throwIfCancelled();
            if (!merged.isEmpty()) {
                Collections.sort(
                        merged,
                        new Comparator<Candidate>() {
                            @Override
                            public int compare(Candidate a, Candidate b) {
                                return Double.compare(b.confidence, a.confidence);
                            }
                        });
                return merged;
            }
            if (!anySucceeded && prioritizedError != null) {
                throw prioritizedError;
            }
            return Collections.emptyList();
        } finally {
            for (Future<OriginMatchOutcome> f : futures) {
                if (f != null && !f.isDone()) {
                    f.cancel(true);
                }
            }
        }
    }

    private List<Candidate> matchOrSearchSingleOrigin(
            String origin, MatchQuery query, CancellationToken token) throws IOException {
        if (token != null) token.throwIfCancelled();
        if (query != null
                && !query.boundAnimeId.isEmpty()
                && (query.boundOrigin.isEmpty()
                        || origin.equalsIgnoreCase(normalizeOriginOrNull(query.boundOrigin)))) {
            try {
                List<Candidate> direct = listEpisodes(origin, query.boundAnimeId, token);
                Candidate picked = pickBoundAnimeEpisode(direct, query);
                if (picked != null) {
                    return Collections.singletonList(picked);
                }
            } catch (CancelledException e) {
                throw e;
            } catch (HttpStatusException e) {
                if (e.statusCode != 404 && e.statusCode != 405) {
                    throw e;
                }
            } catch (IOException ignored) {
            }
        }
        List<Candidate> matched;
        try {
            matched = tryMatchEndpoint(origin, query, token);
        } catch (HttpStatusException e) {
            if (e.statusCode == 404 || e.statusCode == 405) {
                matched = Collections.emptyList();
            } else {
                throw e;
            }
        }
        if (!matched.isEmpty()) return matched;
        return trySearchEpisodesEndpoint(origin, query, token);
    }

    static Candidate pickBoundAnimeEpisode(List<Candidate> episodes, MatchQuery query) {
        if (episodes == null || episodes.isEmpty()) return null;
        if (query == null) return null;
        if (query.isMovie) {
            for (Candidate c : episodes) {
                if (c == null) continue;
                if (isSpecialEpisodeTitle(c.episodeTitle)) continue;
                int candEp = extractEpisodeNum(c.episodeTitle);
                if (candEp <= 1) {
                    return c;
                }
            }
            return null;
        }
        int reqEp = effectiveRequestedEpisode(query);
        boolean querySpecial = isSpecialEpisodeTitle(query.episodeTitle);
        if (reqEp > 0) {
            for (Candidate c : episodes) {
                if (c == null) continue;
                boolean candSpecial = isSpecialEpisodeTitle(c.episodeTitle);
                if (candSpecial && !querySpecial) continue;
                int candEp = extractEpisodeNum(c.episodeTitle);
                if (candEp == reqEp) {
                    return c;
                }
            }
            return null;
        }
        String reqTitleNorm = normalizeCompact(query.episodeTitle);
        if (!reqTitleNorm.isEmpty()) {
            for (Candidate c : episodes) {
                if (c == null) continue;
                if (reqTitleNorm.equals(normalizeCompact(c.episodeTitle))) {
                    return c;
                }
            }
        }
        return null;
    }

    private List<Candidate> tryMatchEndpoint(
            String origin, MatchQuery query, CancellationToken token) throws IOException {
        String fileName = buildCleanFileName(query);
        if (fileName.isEmpty()) return Collections.emptyList();
        JSONObject payload = new JSONObject();
        try {
            payload.put("fileName", fileName);
            payload.put("fileHash", "");
            payload.put("fileSize", 0);
            payload.put("videoDuration", query.durationSec);
            payload.put("matchMode", "fileNameOnly");
        } catch (JSONException e) {
            throw new IOException("Failed to build match payload", e);
        }
        String response =
                executeHttp(origin, origin + "/api/v2/match", "POST", payload.toString(), token);
        try {
            JSONObject root = new JSONObject(response);
            JSONArray matches = root.optJSONArray("matches");
            if (matches == null || matches.length() == 0) return Collections.emptyList();
            boolean exact = root.optBoolean("isMatched", false);
            List<Candidate> out = new ArrayList<>();
            for (int i = 0; i < matches.length(); i++) {
                JSONObject m = matches.optJSONObject(i);
                if (m == null) continue;
                String epId = stringifyId(m.opt("episodeId"));
                if (epId.isEmpty()) continue;
                String animeId = stringifyId(m.opt("animeId"));
                String animeTitle = m.optString("animeTitle", "");
                // Never substitute query.episodeTitle as server evidence when server omits it.
                String epTitle = m.optString("episodeTitle", "");
                String rawEpNum = stringifyId(m.opt("episodeNumber"));
                if (!isCandidateCompatible(query, animeId, animeTitle, epTitle, rawEpNum, exact)) {
                    continue;
                }
                double conf =
                        m.has("confidence")
                                ? m.optDouble("confidence", exact ? 1.0 : 0.85)
                                : (exact ? 1.0 : 0.85);
                out.add(
                        new Candidate(
                                origin,
                                animeId,
                                animeTitle.isEmpty() ? query.title : animeTitle,
                                encodeBoundEpisodeId(origin, epId),
                                epTitle,
                                conf));
            }
            return out;
        } catch (JSONException e) {
            return Collections.emptyList();
        }
    }

    private List<Candidate> trySearchEpisodesEndpoint(
            String origin, MatchQuery query, CancellationToken token) throws IOException {
        String cleanTitle = cleanTitle(query.title);
        if (cleanTitle.isEmpty()) return Collections.emptyList();
        StringBuilder url =
                new StringBuilder(origin)
                        .append("/api/v2/search/episodes?anime=")
                        .append(percentEncode(cleanTitle));
        int reqEp = effectiveRequestedEpisode(query);
        if (!query.isMovie && reqEp > 0) {
            url.append("&episode=").append(reqEp);
        }
        String response = executeHttp(origin, url.toString(), "GET", null, token);
        try {
            JSONObject root = new JSONObject(response);
            JSONArray animes = root.optJSONArray("animes");
            if (animes == null) return Collections.emptyList();
            List<Candidate> out = new ArrayList<>();
            for (int i = 0; i < animes.length(); i++) {
                JSONObject anime = animes.optJSONObject(i);
                if (anime == null) continue;
                String animeId = stringifyId(anime.opt("animeId"));
                String animeTitle = anime.optString("animeTitle", "");
                JSONArray episodes = anime.optJSONArray("episodes");
                if (episodes == null) continue;
                for (int j = 0; j < episodes.length(); j++) {
                    JSONObject ep = episodes.optJSONObject(j);
                    if (ep == null) continue;
                    String epId = stringifyId(ep.opt("episodeId"));
                    if (epId.isEmpty()) continue;
                    String epTitle = ep.optString("episodeTitle", "");
                    String rawEpNum = stringifyId(ep.opt("episodeNumber"));
                    if (!isCandidateCompatible(
                            query, animeId, animeTitle, epTitle, rawEpNum, false)) {
                        continue;
                    }
                    double scoredConf =
                            scoreSearchCandidate(
                                    cleanTitle,
                                    effectiveRequestedSeason(query),
                                    reqEp,
                                    animeTitle,
                                    epTitle);
                    out.add(
                            new Candidate(
                                    origin,
                                    animeId,
                                    animeTitle,
                                    encodeBoundEpisodeId(origin, epId),
                                    epTitle,
                                    scoredConf));
                }
            }
            return out;
        } catch (JSONException e) {
            return Collections.emptyList();
        }
    }

    @Override
    public List<AnimeHit> searchAnimes(String keyword, CancellationToken token) throws IOException {
        if (token != null) token.throwIfCancelled();
        String raw = keyword == null ? "" : keyword.trim();
        String cleaned = cleanTitle(raw);
        String q = !cleaned.isEmpty() ? cleaned : raw;
        if (q.isEmpty()) return Collections.emptyList();
        List<AnimeHit> hits = new ArrayList<>();
        Set<String> seen = new LinkedHashSet<>();
        IOException lastError = null;
        for (String origin : originWhitelist) {
            if (token != null) token.throwIfCancelled();
            try {
                boolean anyFromSearchAnime = false;
                try {
                    String animeUrl = origin + "/api/v2/search/anime?keyword=" + percentEncode(q);
                    String body = executeHttp(origin, animeUrl, "GET", null, token);
                    JSONObject root = new JSONObject(body);
                    JSONArray animes = root.optJSONArray("animes");
                    if (animes != null) {
                        for (int i = 0; i < animes.length(); i++) {
                            JSONObject a = animes.optJSONObject(i);
                            if (a == null) continue;
                            String aid = stringifyId(a.opt("animeId"));
                            String atitle = a.optString("animeTitle", "").trim();
                            if (aid.isEmpty() || atitle.isEmpty()) continue;
                            if (!seen.add(origin + "|" + aid)) continue;
                            String typeDesc = a.optString("typeDescription", "").trim();
                            int epCount = Math.max(0, a.optInt("episodeCount", 0));
                            hits.add(new AnimeHit(origin, aid, atitle, typeDesc, epCount));
                            anyFromSearchAnime = true;
                        }
                    }
                } catch (CancelledException ce) {
                    throw ce;
                } catch (Exception ignored) {
                }
                if (!anyFromSearchAnime) {
                    String epUrl = origin + "/api/v2/search/episodes?anime=" + percentEncode(q);
                    String body = executeHttp(origin, epUrl, "GET", null, token);
                    JSONObject root = new JSONObject(body);
                    JSONArray animes = root.optJSONArray("animes");
                    if (animes != null) {
                        for (int i = 0; i < animes.length(); i++) {
                            JSONObject a = animes.optJSONObject(i);
                            if (a == null) continue;
                            String aid = stringifyId(a.opt("animeId"));
                            String atitle = a.optString("animeTitle", "").trim();
                            if (aid.isEmpty() || atitle.isEmpty()) continue;
                            if (!seen.add(origin + "|" + aid)) continue;
                            JSONArray eps = a.optJSONArray("episodes");
                            int epCount = eps == null ? 0 : eps.length();
                            String typeDesc = a.optString("typeDescription", "").trim();
                            hits.add(new AnimeHit(origin, aid, atitle, typeDesc, epCount));
                        }
                    }
                }
            } catch (CancelledException ce) {
                throw ce;
            } catch (IOException io) {
                lastError = io;
            } catch (Exception e) {
                lastError = new IOException(e);
            }
        }
        if (hits.isEmpty() && lastError != null) {
            throw lastError;
        }
        return hits;
    }

    @Override
    public List<Candidate> listEpisodes(
            String sourceOrigin, String animeId, CancellationToken token) throws IOException {
        if (token != null) token.throwIfCancelled();
        String normOrigin = normalizeOriginOrNull(sourceOrigin);
        if (normOrigin == null || !originWhitelist.contains(normOrigin)) {
            throw new IOException("弹幕来源不在白名单内: " + sourceOrigin);
        }
        if (animeId == null || animeId.trim().isEmpty()) {
            return Collections.emptyList();
        }
        String url = normOrigin + "/api/v2/bangumi/" + percentEncode(animeId.trim());
        String response = executeHttp(normOrigin, url, "GET", null, token);
        try {
            JSONObject root = new JSONObject(response);
            JSONObject bangumi = root.optJSONObject("bangumi");
            String animeTitle =
                    bangumi != null
                            ? bangumi.optString("animeTitle", "")
                            : root.optString("animeTitle", "");
            JSONArray episodes =
                    bangumi != null
                            ? bangumi.optJSONArray("episodes")
                            : root.optJSONArray("episodes");
            if (episodes == null) return Collections.emptyList();
            List<Candidate> out = new ArrayList<>();
            for (int i = 0; i < episodes.length(); i++) {
                JSONObject ep = episodes.optJSONObject(i);
                if (ep == null) continue;
                String epId = stringifyId(ep.opt("episodeId"));
                if (epId.isEmpty()) continue;
                String epTitle = ep.optString("episodeTitle", "");
                String rawEpNum = stringifyId(ep.opt("episodeNumber"));
                String labeledTitle = enrichServerEpisodeTitle(epTitle, rawEpNum);
                out.add(
                        new Candidate(
                                normOrigin,
                                animeId.trim(),
                                animeTitle,
                                encodeBoundEpisodeId(normOrigin, epId),
                                labeledTitle,
                                1.0));
            }
            return out;
        } catch (JSONException e) {
            throw new IOException("解析剧集弹幕列表失败", e);
        }
    }

    @Override
    public EpisodeSession openSession(String boundEpisodeId, CancellationToken token)
            throws IOException {
        if (token != null) token.throwIfCancelled();
        BoundEpisode bound = decodeBoundEpisodeId(boundEpisodeId, originWhitelist);
        String url =
                bound.origin
                        + "/api/v2/comment/"
                        + percentEncode(bound.rawEpisodeId)
                        + "?withRelated=true&chConvert=0";
        String response = executeHttp(bound.origin, url, "GET", null, token);
        String trimmed = response == null ? "" : response.trim();
        if (trimmed.startsWith("{")) {
            try {
                JSONObject root = new JSONObject(trimmed);
                JSONArray segArray = root.optJSONArray("segments");
                if (segArray != null && segArray.length() > 0) {
                    List<SegmentDescriptor> segments = new ArrayList<>();
                    for (int i = 0; i < segArray.length(); i++) {
                        JSONObject s = segArray.optJSONObject(i);
                        if (s == null) continue;
                        long startMs =
                                s.has("startMs")
                                        ? s.optLong("startMs", 0L)
                                        : Math.round(s.optDouble("startSec", 0.0) * 1000.0);
                        long endMs =
                                s.has("endMs")
                                        ? s.optLong("endMs", startMs)
                                        : Math.round(s.optDouble("endSec", 0.0) * 1000.0);
                        String rawSegUrl = s.optString("segmentUrl", s.optString("url", ""));
                        if (endMs <= startMs || rawSegUrl.isEmpty()) continue;
                        String validatedUrl = validateSegmentUrl(rawSegUrl, bound.origin);
                        segments.add(new SegmentDescriptor(startMs, endMs, validatedUrl));
                    }
                    if (!segments.isEmpty()) {
                        return new EpisodeSession(
                                boundEpisodeId, true, segments, Collections.<DanmuItem>emptyList());
                    }
                }
            } catch (JSONException ignored) {
            }
        }
        List<DanmuItem> full = parseDanmuPayload(trimmed, MAX_FULL_EPISODE_ITEMS);
        return new EpisodeSession(
                boundEpisodeId, false, Collections.<SegmentDescriptor>emptyList(), full);
    }

    @Override
    public List<DanmuItem> fetchWindow(
            EpisodeSession session, int windowIndex, CancellationToken token) throws IOException {
        if (token != null) token.throwIfCancelled();
        if (session == null) return Collections.emptyList();
        if (windowIndex < 0) {
            throw new IllegalArgumentException("windowIndex must be >= 0");
        }
        long windowStartMs = (long) windowIndex * WINDOW_DURATION_MS;
        long windowEndMs = windowStartMs + WINDOW_DURATION_MS;

        if (!session.segmented) {
            return sliceWindow(session.preloadComments, windowStartMs, windowEndMs);
        }

        BoundEpisode bound = decodeBoundEpisodeId(session.boundEpisodeId, originWhitelist);
        List<SegmentDescriptor> overlapping = new ArrayList<>();
        for (SegmentDescriptor seg : session.segments) {
            // Strict half-open intersection: [seg.startMs, seg.endMs) ∩ [windowStartMs,
            // windowEndMs)
            if (seg.startMs < windowEndMs && seg.endMs > windowStartMs) {
                overlapping.add(seg);
            }
        }
        if (overlapping.isEmpty()) {
            return Collections.emptyList();
        }
        List<DanmuItem> collected = new ArrayList<>();
        for (SegmentDescriptor seg : overlapping) {
            if (token != null) token.throwIfCancelled();
            String validUrl = validateSegmentUrl(seg.segmentUrl, bound.origin);
            String body = executeHttp(bound.origin, validUrl, "GET", null, token);
            List<DanmuItem> parsed = parseDanmuPayload(body, MAX_FULL_EPISODE_ITEMS);
            for (DanmuItem item : parsed) {
                if (item.timeMs >= windowStartMs && item.timeMs < windowEndMs) {
                    collected.add(item);
                }
            }
        }
        return sortDedupAndCap(collected, MAX_WINDOW_ITEMS);
    }

    private static List<DanmuItem> sliceWindow(
            List<DanmuItem> sortedComments, long windowStartMs, long windowEndMs) {
        if (sortedComments == null || sortedComments.isEmpty()) return Collections.emptyList();
        int lo = 0;
        int hi = sortedComments.size();
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (sortedComments.get(mid).timeMs < windowStartMs) lo = mid + 1;
            else hi = mid;
        }
        List<DanmuItem> out = new ArrayList<>();
        for (int i = lo; i < sortedComments.size() && out.size() < MAX_WINDOW_ITEMS; i++) {
            DanmuItem item = sortedComments.get(i);
            if (item.timeMs >= windowEndMs) break;
            if (item.timeMs >= windowStartMs) {
                out.add(item);
            }
        }
        return out;
    }

    // -------------------------------------------------------------------------
    // HTTP Transport, Rate Limiting, Optional Signature & Cancellation
    // -------------------------------------------------------------------------

    private void awaitDomainRateLimit(String rateLimitKey, CancellationToken token)
            throws IOException {
        if (minRequestIntervalMs <= 0L && !domainNextAllowedMs.containsKey(rateLimitKey)) return;
        while (true) {
            if (token != null) token.throwIfCancelled();
            long now = System.currentTimeMillis();
            Long allowedAt = domainNextAllowedMs.get(rateLimitKey);
            long target = allowedAt == null ? 0L : allowedAt.longValue();
            if (now >= target) {
                long next = now + minRequestIntervalMs;
                if (allowedAt == null) {
                    if (domainNextAllowedMs.putIfAbsent(rateLimitKey, next) == null) {
                        return;
                    }
                } else if (domainNextAllowedMs.replace(rateLimitKey, allowedAt, next)) {
                    return;
                }
                continue;
            }
            long sleepMs = Math.min(target - now, 50L);
            try {
                Thread.sleep(Math.max(1L, sleepMs));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new CancelledException("Rate-limit wait interrupted");
            }
        }
    }

    private void recordBackoff(String rateLimitKey, long retryAfterMs) {
        long deadline = System.currentTimeMillis() + Math.max(minRequestIntervalMs, retryAfterMs);
        while (true) {
            Long prev = domainNextAllowedMs.get(rateLimitKey);
            if (prev == null) {
                if (domainNextAllowedMs.putIfAbsent(rateLimitKey, deadline) == null) return;
            } else if (prev.longValue() >= deadline) {
                return;
            } else if (domainNextAllowedMs.replace(rateLimitKey, prev, deadline)) {
                return;
            }
        }
    }

    private String executeHttp(
            String originKey,
            String urlString,
            String method,
            String jsonBody,
            CancellationToken token)
            throws IOException {
        if (token != null) token.throwIfCancelled();
        awaitDomainRateLimit(originKey, token);

        String currentUrlStr = urlString;
        for (int redirect = 0; redirect < 4; redirect++) {
            if (token != null) token.throwIfCancelled();
            URI uri;
            try {
                uri = URI.create(currentUrlStr);
            } catch (IllegalArgumentException e) {
                throw new IOException("非法请求地址: " + currentUrlStr, e);
            }
            final HttpURLConnection conn =
                    (HttpURLConnection) new URL(currentUrlStr).openConnection();
            Runnable cancelHook =
                    new Runnable() {
                        @Override
                        public void run() {
                            try {
                                conn.disconnect();
                            } catch (Throwable ignored) {
                            }
                        }
                    };
            if (token != null) token.onCancel(cancelHook);
            try {
                conn.setInstanceFollowRedirects(false);
                conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
                conn.setReadTimeout(READ_TIMEOUT_MS);
                conn.setRequestMethod(method);
                conn.setRequestProperty(
                        "Accept", "application/json, application/xml, text/xml, */*");
                conn.setRequestProperty("Accept-Encoding", "gzip, deflate");
                conn.setRequestProperty("User-Agent", "MarcoMovie-Danmu/1.0");
                if (!appId.isEmpty() && !appSecret.isEmpty()) {
                    long ts = System.currentTimeMillis() / 1000L;
                    String rawPath = uri.getRawPath();
                    String path = (rawPath == null || rawPath.isEmpty()) ? "/" : rawPath;
                    String sig = computeOpenApiSignature(appId, ts, path, appSecret);
                    conn.setRequestProperty("X-AppId", appId);
                    conn.setRequestProperty("X-Timestamp", String.valueOf(ts));
                    conn.setRequestProperty("X-Signature", sig);
                }
                if ("POST".equals(method) && jsonBody != null) {
                    byte[] payloadBytes = jsonBody.getBytes(UTF_8);
                    conn.setDoOutput(true);
                    conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8");
                    conn.setFixedLengthStreamingMode(payloadBytes.length);
                    try (OutputStream os = conn.getOutputStream()) {
                        os.write(payloadBytes);
                    }
                }
                int status = conn.getResponseCode();
                if (token != null) token.throwIfCancelled();

                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String location = conn.getHeaderField("Location");
                    if (location == null || location.trim().isEmpty()) {
                        throw new IOException("弹幕重定向缺少 Location");
                    }
                    currentUrlStr = validateSegmentUrl(location.trim(), originKey);
                    if (status == 303) {
                        method = "GET";
                        jsonBody = null;
                    }
                    continue;
                }
                if (status == 429) {
                    long retryAfterMs = parseRetryAfterMs(conn.getHeaderField("Retry-After"));
                    recordBackoff(originKey, retryAfterMs);
                    throw new HttpStatusException(429, "弹幕请求被限流 (HTTP 429)", retryAfterMs);
                }
                if (status == 410) {
                    throw new HttpStatusException(410, "弹幕分片已过期 (HTTP 410)");
                }
                if (status < 200 || status >= 300) {
                    throw new HttpStatusException(status, "弹幕服务返回 HTTP " + status);
                }
                try (InputStream in = conn.getInputStream()) {
                    return readDecodedBody(in, conn.getContentEncoding(), token);
                }
            } catch (IOException e) {
                if (token != null && token.isCancelled()) {
                    throw new CancelledException("Danmu HTTP request cancelled");
                }
                throw e;
            } finally {
                if (token != null) token.removeCancelHook(cancelHook);
                conn.disconnect();
            }
        }
        throw new IOException("弹幕重定向次数过多");
    }

    public static long parseRetryAfterMs(String headerValue) {
        if (headerValue == null || headerValue.trim().isEmpty()) {
            return DEFAULT_RETRY_AFTER_MS;
        }
        try {
            long sec = Long.parseLong(headerValue.trim());
            if (sec > 0) {
                return Math.min(60000L, sec * 1000L);
            }
        } catch (NumberFormatException ignored) {
        }
        return DEFAULT_RETRY_AFTER_MS;
    }

    private static String readDecodedBody(
            InputStream rawStream, String contentEncoding, CancellationToken token)
            throws IOException {
        byte[] raw = readBounded(rawStream, MAX_PAYLOAD_BYTES, token);
        if (raw.length == 0) return "";
        String enc = contentEncoding == null ? "" : contentEncoding.toLowerCase(Locale.ROOT);
        if (enc.contains("gzip")
                || (raw.length >= 2 && (raw[0] & 0xFF) == 0x1F && (raw[1] & 0xFF) == 0x8B)) {
            try (InputStream gz = new GZIPInputStream(new ByteArrayInputStream(raw))) {
                return new String(readBounded(gz, MAX_PAYLOAD_BYTES, token), UTF_8);
            } catch (IOException ignored) {
            }
        }
        if (enc.contains("deflate")) {
            for (boolean nowrap : new boolean[] {true, false}) {
                try (InputStream inf =
                        new InflaterInputStream(
                                new ByteArrayInputStream(raw), new Inflater(nowrap))) {
                    return new String(readBounded(inf, MAX_PAYLOAD_BYTES, token), UTF_8);
                } catch (IOException ignored) {
                }
            }
        }
        return new String(raw, UTF_8);
    }

    private static byte[] readBounded(InputStream in, int maxBytes, CancellationToken token)
            throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int total = 0;
        int n;
        while ((n = in.read(buf)) != -1) {
            if (token != null) token.throwIfCancelled();
            total += n;
            if (total > maxBytes) {
                throw new IOException("弹幕响应体积超过 8 MB 上限");
            }
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }

    // -------------------------------------------------------------------------
    // Standard Danmu Payload Normalization (JSON / Simplified Array / XML)
    // -------------------------------------------------------------------------

    public static List<DanmuItem> parseDanmuPayload(String body, int maxItems) throws IOException {
        if (body == null) return Collections.emptyList();
        if (body.length() > MAX_PAYLOAD_BYTES) {
            throw new IOException("弹幕内容超过 8 MB 上限");
        }
        String content = body.trim();
        if (content.startsWith("\uFEFF")) {
            content = content.substring(1).trim();
        }
        if (content.isEmpty()) return Collections.emptyList();

        List<DanmuItem> parsed = new ArrayList<>();
        if (content.startsWith("<")) {
            parseXmlPayload(content, parsed, maxItems);
        } else {
            parseJsonPayload(content, parsed, maxItems);
        }
        return sortDedupAndCap(parsed, maxItems);
    }

    private static void parseXmlPayload(String content, List<DanmuItem> out, int maxItems)
            throws IOException {
        String upper = content.toUpperCase(Locale.ROOT);
        if (upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY")) {
            throw new IOException("弹幕 XML 禁止包含外部实体 (DOCTYPE/ENTITY)");
        }
        String sanitized = stripIllegalXmlChars(content);
        try {
            DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
            factory.setExpandEntityReferences(false);
            Document doc =
                    factory.newDocumentBuilder()
                            .parse(new ByteArrayInputStream(sanitized.getBytes(UTF_8)));
            NodeList nodes = doc.getElementsByTagName("d");
            int limit = Math.min(maxItems * 2, nodes.getLength());
            for (int i = 0; i < limit; i++) {
                Element el = (Element) nodes.item(i);
                parseXmlElement(el.getAttribute("p"), el.getTextContent(), out);
            }
        } catch (Exception domErr) {
            Matcher m =
                    Pattern.compile(
                                    "<d\\b[^>]*\\bp\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</d>",
                                    Pattern.CASE_INSENSITIVE)
                            .matcher(sanitized);
            int count = 0;
            while (m.find() && count < maxItems * 2) {
                count++;
                parseXmlElement(m.group(1), unescapeXml(m.group(2)), out);
            }
            if (count == 0
                    && !sanitized.contains("<i")
                    && !sanitized.contains("<packet")
                    && !sanitized.contains("<danmaku")) {
                throw new IOException("无法解析 XML 弹幕内容", domErr);
            }
        }
    }

    private static void parseXmlElement(String pAttr, String rawText, List<DanmuItem> out) {
        if (pAttr == null) return;
        String[] p = pAttr.split(",");
        if (p.length < 4) return;
        try {
            long timeMs = Math.round(Double.parseDouble(p[0].trim()) * 1000.0);
            int mode = normalizeMode(Integer.parseInt(p[1].trim()));
            int color = Integer.parseInt(p[3].trim()) & 0xFFFFFF;
            String id = p.length >= 8 ? p[7].trim() : "";
            addNormalized(out, id, timeMs, mode, color, rawText);
        } catch (NumberFormatException ignored) {
        }
    }

    private static void parseJsonPayload(String content, List<DanmuItem> out, int maxItems)
            throws IOException {
        Object root;
        try {
            root = new JSONTokener(content).nextValue();
        } catch (JSONException e) {
            throw new IOException("无法解析 JSON 弹幕内容", e);
        }
        JSONArray list = null;
        if (root instanceof JSONArray) {
            list = (JSONArray) root;
        } else if (root instanceof JSONObject) {
            JSONObject obj = (JSONObject) root;
            for (String key :
                    new String[] {"comments", "danmuku", "danmaku", "danmu", "data", "list"}) {
                list = obj.optJSONArray(key);
                if (list != null) break;
            }
            if (list == null) {
                JSONObject inner = obj.optJSONObject("data");
                if (inner != null) {
                    for (String key :
                            new String[] {"comments", "danmuku", "danmaku", "danmu", "list"}) {
                        list = inner.optJSONArray(key);
                        if (list != null) break;
                    }
                }
            }
        }
        if (list == null) return;
        int limit = Math.min(maxItems * 2, list.length());
        for (int i = 0; i < limit; i++) {
            Object entry = list.opt(i);
            if (entry instanceof JSONArray) {
                JSONArray a = (JSONArray) entry;
                if (a.length() < 4) continue;
                try {
                    long timeMs = Math.round(a.getDouble(0) * 1000.0);
                    int mode = normalizeMode(a.optInt(1, 1));
                    int color = a.optInt(2, 0xFFFFFF) & 0xFFFFFF;
                    String text = a.optString(3, "");
                    String id = a.length() > 4 ? stringifyId(a.opt(4)) : "";
                    addNormalized(out, id, timeMs, mode, color, text);
                } catch (Exception ignored) {
                }
            } else if (entry instanceof JSONObject) {
                JSONObject o = (JSONObject) entry;
                try {
                    String id = stringifyId(o.has("cid") ? o.opt("cid") : o.opt("id"));
                    long timeMs;
                    if (o.has("timeMs") && !o.isNull("timeMs")) {
                        double msVal = o.optDouble("timeMs", Double.NaN);
                        timeMs = Double.isNaN(msVal) ? -1L : Math.round(msVal);
                    } else {
                        timeMs = Math.round(o.optDouble("time", o.optDouble("t", 0.0)) * 1000.0);
                    }
                    int mode = normalizeMode(o.optInt("mode", 1));
                    int color = o.optInt("color", o.optInt("rgbColor", 0xFFFFFF)) & 0xFFFFFF;
                    String text = o.optString("m", o.optString("text", o.optString("content", "")));
                    if (o.has("p")) {
                        String pStr = o.optString("p", "");
                        String[] p = pStr.split(",");
                        if (p.length >= 1 && !p[0].trim().isEmpty()) {
                            timeMs = Math.round(Double.parseDouble(p[0].trim()) * 1000.0);
                        }
                        if (p.length >= 3) {
                            mode = normalizeMode(Integer.parseInt(p[1].trim()));
                            color = Integer.parseInt(p[2].trim()) & 0xFFFFFF;
                        } else if (p.length == 2) {
                            mode = normalizeMode(Integer.parseInt(p[1].trim()));
                        }
                    }
                    addNormalized(out, id, timeMs, mode, color, text);
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static void addNormalized(
            List<DanmuItem> out,
            String rawId,
            long timeMs,
            int mode,
            int rgbColor,
            String rawText) {
        if (timeMs < 0 || rawText == null) return;
        String clean = sanitizeText(rawText);
        if (clean.isEmpty()) return;
        String id =
                (rawId == null || rawId.trim().isEmpty())
                        ? syntheticId(timeMs, mode, rgbColor, clean)
                        : rawId.trim();
        out.add(new DanmuItem(id, timeMs, mode, rgbColor & 0xFFFFFF, clean));
    }

    private static String sanitizeText(String raw) {
        StringBuilder sb = new StringBuilder(Math.min(raw.length(), MAX_TEXT_LENGTH));
        for (int i = 0; i < raw.length(); i++) {
            char ch = raw.charAt(i);
            if (ch < 0x20 || ch == 0x7F) {
                sb.append(' ');
            } else {
                sb.append(ch);
            }
            if (sb.length() >= MAX_TEXT_LENGTH) break;
        }
        String trimmed = sb.toString().trim();
        return trimmed.length() > MAX_TEXT_LENGTH ? trimmed.substring(0, MAX_TEXT_LENGTH) : trimmed;
    }

    private static String syntheticId(long timeMs, int mode, int color, String text) {
        return "h_"
                + timeMs
                + "_"
                + mode
                + "_"
                + (color & 0xFFFFFF)
                + "_"
                + Integer.toHexString(text.hashCode());
    }

    public static int normalizeMode(int mode) {
        if (mode == 4 || mode == 5) return mode;
        return 1;
    }

    public static List<DanmuItem> sortDedupAndCap(List<DanmuItem> items, int maxItems) {
        if (items == null || items.isEmpty()) return Collections.emptyList();
        List<DanmuItem> sorted = new ArrayList<>(items);
        Collections.sort(sorted, ITEM_ORDER);
        Map<String, DanmuItem> dedup = new LinkedHashMap<>();
        for (DanmuItem item : sorted) {
            if (!dedup.containsKey(item.id)) {
                dedup.put(item.id, item);
                if (dedup.size() >= maxItems) break;
            }
        }
        return new ArrayList<>(dedup.values());
    }

    static String buildCleanFileName(MatchQuery query) {
        if (query == null) return "";
        String t = cleanTitle(query.title);
        if (t.isEmpty()) return "";
        if (query.isMovie) {
            return t;
        }
        String seasonPrefix =
                query.seasonNumber > 1 && !containsSeasonTag(t)
                        ? (" S"
                                + (query.seasonNumber < 10
                                        ? "0" + query.seasonNumber
                                        : query.seasonNumber))
                        : "";
        if (query.episodeIndex > 0) {
            return t
                    + seasonPrefix
                    + " E"
                    + (query.episodeIndex < 10 ? "0" + query.episodeIndex : query.episodeIndex);
        }
        String ep = cleanTitle(query.episodeTitle);
        if (!ep.isEmpty() && !ep.equalsIgnoreCase(t)) {
            return t + seasonPrefix + " " + ep;
        }
        return t + seasonPrefix;
    }

    private static final Pattern SEASON_EP_PAT =
            Pattern.compile(
                    "(?i)(?:s|season\\s*)0*(\\d{1,2})\\s*[._\\-\\s]*e(?:p)?\\.?\\s*0*(\\d{1,4})(?:$|[^0-9])");
    private static final Pattern SEASON_TAG_PAT =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,2})\\s*季|第\\s*([一二三四五六七八九十两兩]{1,3})\\s*季|season\\s*0*(\\d{1,2})|(?:^|[^a-z0-9])s0*(\\d{1,2})(?:$|[^a-z0-9]))");
    private static final Pattern SPECIAL_PAT =
            Pattern.compile(
                    "(?i)(?:第\\s*0+\\s*[集话話回期]|(?:^|[^a-z0-9])ep?\\.?\\s*0+(?:$|[^0-9])|(?:^|[^a-z0-9])s00e?\\d*(?:$|[^a-z0-9])|(?:^|[^a-z0-9])(?:sp|ova|oad|pv|cm|op|ed|ncop|nced|extra|bonus|trailer|preview|making)(?:\\s*\\d{0,3})(?:$|[^a-z0-9])|预告|先导|花絮|番外|特别篇|特典|总集篇|总集|幕后|彩蛋|片花|小剧场|抢先看)");
    private static final Pattern CN_ARABIC_EP_PAT =
            Pattern.compile("第\\s*0*(\\d{1,4})\\s*[集话話回期篇章]");
    private static final Pattern CN_NUM_EP_PAT =
            Pattern.compile("第\\s*([一二三四五六七八九十百千零〇两兩]{1,6})\\s*[集话話回期篇章]");
    private static final Pattern EXPLICIT_EP_PAT =
            Pattern.compile(
                    "(?i)(?:^|[^a-z0-9])(?:episode|ep|e)\\.?\\s*0*(\\d{1,4})(?:$|[^a-z0-9])");
    private static final Pattern BRACKET_EP_PAT =
            Pattern.compile("[\\[【(（]\\s*(?:第)?0*(\\d{1,4})(?:\\s*[集话話])?\\s*[\\]】)）]");
    private static final Pattern LOOSE_EP_PAT = Pattern.compile("(?<![0-9])0*(\\d{1,4})(?![0-9])");
    private static final Pattern TECH_NOISE_PAT =
            Pattern.compile(
                    "(?i)(?:\\d{3,4}\\s*[xX×]\\s*\\d{3,4}|(?:2160|1440|1080|720|576|480|360)[pi]|(?:2k|4k|8k)|(?:8|10|12)\\s*bit|(?:24|25|30|48|50|60|120)\\s*(?:fps|帧|hz)|h\\.?265|h\\.?264|x\\.?265|x\\.?264|5\\.1|7\\.1|2\\.0|(?:19[4-9]\\d|20[0-3]\\d))");

    private static boolean containsSeasonTag(String title) {
        if (title == null) return false;
        return SEASON_TAG_PAT.matcher(title).find();
    }

    private static int parseChineseSmallNumber(String raw) {
        if (raw == null || raw.isEmpty()) return -1;
        String s = raw.trim();
        if ("两".equals(s) || "兩".equals(s)) return 2;
        int total = 0;
        int cur = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            int d = -1;
            switch (c) {
                case '零':
                case '〇':
                    d = 0;
                    break;
                case '一':
                    d = 1;
                    break;
                case '二':
                case '两':
                case '兩':
                    d = 2;
                    break;
                case '三':
                    d = 3;
                    break;
                case '四':
                    d = 4;
                    break;
                case '五':
                    d = 5;
                    break;
                case '六':
                    d = 6;
                    break;
                case '七':
                    d = 7;
                    break;
                case '八':
                    d = 8;
                    break;
                case '九':
                    d = 9;
                    break;
                case '十':
                    total += (cur == 0 ? 1 : cur) * 10;
                    cur = 0;
                    continue;
                case '百':
                    total += (cur == 0 ? 1 : cur) * 100;
                    cur = 0;
                    continue;
                case '千':
                    total += (cur == 0 ? 1 : cur) * 1000;
                    cur = 0;
                    continue;
                default:
                    return -1;
            }
            cur = d;
        }
        total += cur;
        return total > 0 ? total : -1;
    }

    static boolean isSpecialEpisodeTitle(String raw) {
        if (raw == null || raw.trim().isEmpty()) return false;
        return SPECIAL_PAT.matcher(raw.trim()).find();
    }

    static int extractSeasonNum(String raw) {
        if (raw == null || raw.trim().isEmpty()) return -1;
        Matcher se = SEASON_EP_PAT.matcher(raw);
        if (se.find()) {
            try {
                int v = Integer.parseInt(se.group(1));
                return v > 0 ? v : -1;
            } catch (NumberFormatException ignored) {
            }
        }
        Matcher m = SEASON_TAG_PAT.matcher(raw);
        if (m.find()) {
            if (m.group(2) != null) return parseChineseSmallNumber(m.group(2));
            String g =
                    m.group(1) != null
                            ? m.group(1)
                            : (m.group(3) != null ? m.group(3) : m.group(4));
            if (g != null) {
                try {
                    int v = Integer.parseInt(g);
                    return v > 0 ? v : -1;
                } catch (NumberFormatException ignored) {
                }
            }
        }
        return -1;
    }

    static int extractEpisodeNum(String raw) {
        if (raw == null || raw.trim().isEmpty()) return -1;
        String trimmed = raw.trim();
        if (isSpecialEpisodeTitle(trimmed)) return -1;
        Matcher se = SEASON_EP_PAT.matcher(trimmed);
        if (se.find()) {
            try {
                int v = Integer.parseInt(se.group(2));
                if (v > 0) return v;
            } catch (NumberFormatException ignored) {
            }
        }
        Matcher cnA = CN_ARABIC_EP_PAT.matcher(trimmed);
        if (cnA.find()) {
            try {
                int v = Integer.parseInt(cnA.group(1));
                if (v > 0) return v;
            } catch (NumberFormatException ignored) {
            }
        }
        Matcher cnN = CN_NUM_EP_PAT.matcher(trimmed);
        if (cnN.find()) {
            int v = parseChineseSmallNumber(cnN.group(1));
            if (v > 0) return v;
        }
        String cleaned =
                SEASON_TAG_PAT
                        .matcher(TECH_NOISE_PAT.matcher(trimmed).replaceAll(" "))
                        .replaceAll(" ");
        Matcher exp = EXPLICIT_EP_PAT.matcher(cleaned);
        if (exp.find()) {
            try {
                int v = Integer.parseInt(exp.group(1));
                if (v > 0) return v;
            } catch (NumberFormatException ignored) {
            }
        }
        Matcher br = BRACKET_EP_PAT.matcher(cleaned);
        if (br.find()) {
            try {
                int v = Integer.parseInt(br.group(1));
                if (v > 0 && v <= 2000) return v;
            } catch (NumberFormatException ignored) {
            }
        }
        Matcher loose = LOOSE_EP_PAT.matcher(cleaned);
        int found = -1;
        int count = 0;
        while (loose.find()) {
            try {
                int v = Integer.parseInt(loose.group(1));
                if (v > 0 && v <= 2000) {
                    found = v;
                    count++;
                }
            } catch (NumberFormatException ignored) {
            }
        }
        return count == 1 ? found : -1;
    }

    private static int extractServerEpisodeNum(String epTitle, String rawEpNum) {
        if (rawEpNum != null && !rawEpNum.isEmpty()) {
            if (isSpecialEpisodeTitle(rawEpNum)) return -1;
            try {
                int v = Integer.parseInt(rawEpNum);
                if (v > 0) return v;
            } catch (NumberFormatException ignored) {
                int parsed = extractEpisodeNum(rawEpNum);
                if (parsed > 0) return parsed;
            }
        }
        return extractEpisodeNum(epTitle);
    }

    private static String enrichServerEpisodeTitle(String epTitle, String rawEpNum) {
        String title = epTitle == null ? "" : epTitle.trim();
        if (rawEpNum == null || rawEpNum.trim().isEmpty()) return title;
        String num = rawEpNum.trim();
        if (extractEpisodeNum(title) > 0 || isSpecialEpisodeTitle(title)) {
            return title;
        }
        if (num.matches("\\d+")) {
            return title.isEmpty() ? ("第" + num + "集") : ("第" + num + "集 " + title);
        }
        return title.isEmpty() ? num : (num + " " + title);
    }

    private static int effectiveRequestedEpisode(MatchQuery query) {
        if (query == null || query.isMovie) return 0;
        if (query.episodeIndex > 0) return query.episodeIndex;
        return extractEpisodeNum(query.episodeTitle);
    }

    private static int effectiveRequestedSeason(MatchQuery query) {
        if (query == null || query.isMovie) return -1;
        if (query.seasonNumber > 0) return query.seasonNumber;
        int s = extractSeasonNum(query.episodeTitle);
        if (s > 0) return s;
        return extractSeasonNum(query.title);
    }

    private static String normalizeCompact(String raw) {
        if (raw == null) return "";
        return raw.toLowerCase(Locale.ROOT).replaceAll("[\\s\\p{Punct}·•—–：:，,。！？【】（）《》「」『』]+", "");
    }

    private static String stripSeasonCompact(String raw) {
        if (raw == null) return "";
        String stripped = SEASON_TAG_PAT.matcher(cleanTitle(raw)).replaceAll(" ");
        return normalizeCompact(stripped);
    }

    private static boolean isMotionComic(String title) {
        if (title == null) return false;
        String l = title.toLowerCase(Locale.ROOT);
        return l.contains("动态漫画") || l.contains("动态漫");
    }

    static boolean isCandidateCompatible(
            MatchQuery query,
            String candAnimeId,
            String candAnimeTitle,
            String candEpTitle,
            String rawEpNum,
            boolean exactMatchFlag) {
        if (query == null) return false;

        // 1. Respect bound anime ID if user/system bound a specific anime.
        boolean matchesBoundAnime = false;
        if (!query.boundAnimeId.isEmpty()) {
            if (candAnimeId != null && !candAnimeId.isEmpty()) {
                if (!query.boundAnimeId.equals(candAnimeId)) {
                    return false;
                }
                matchesBoundAnime = true;
            }
        }

        // 2. Reject explicit work-form mismatch (e.g. regular anime vs motion comic).
        if (!matchesBoundAnime
                && candAnimeTitle != null
                && !candAnimeTitle.isEmpty()
                && !query.title.isEmpty()
                && isMotionComic(query.title) != isMotionComic(candAnimeTitle)) {
            return false;
        }

        // 3. Validate season compatibility (e.g. S1 vs S2 both having E02).
        int reqSeason = effectiveRequestedSeason(query);
        if (!query.isMovie && reqSeason > 0) {
            int candSeason = extractSeasonNum(candEpTitle);
            if (candSeason <= 0) candSeason = extractSeasonNum(candAnimeTitle);
            if (candSeason > 0 && candSeason != reqSeason) {
                return false;
            }
            if (reqSeason >= 2 && candSeason <= 0 && !matchesBoundAnime) {
                String qBase = stripSeasonCompact(query.title);
                String cBase = stripSeasonCompact(candAnimeTitle);
                if (!qBase.isEmpty() && qBase.equals(cBase)) {
                    return false;
                }
            }
        }

        // 4. Validate episode / movie / special compatibility strictly from server evidence.
        boolean candSpecial =
                isSpecialEpisodeTitle(candEpTitle)
                        || (rawEpNum != null
                                && !rawEpNum.isEmpty()
                                && isSpecialEpisodeTitle(rawEpNum));
        int candEp = candSpecial ? -1 : extractServerEpisodeNum(candEpTitle, rawEpNum);

        if (query.isMovie) {
            if (candSpecial) return false;
            if (candEp > 1) return false;
            return true;
        }

        boolean querySpecial = isSpecialEpisodeTitle(query.episodeTitle);
        int reqEp = effectiveRequestedEpisode(query);
        if (reqEp > 0) {
            if (candSpecial && !querySpecial) return false;
            // Missing/unknown server episode number is NOT sufficient evidence for automatic match.
            if (candEp <= 0) return false;
            if (candEp != reqEp) return false;
            return true;
        }

        // Unnumbered / special episode query: require explicit title or special agreement.
        if (querySpecial) {
            if (!candSpecial) return false;
            String qNorm = normalizeCompact(query.episodeTitle);
            String cNorm = normalizeCompact(candEpTitle);
            return !qNorm.isEmpty()
                    && !cNorm.isEmpty()
                    && (cNorm.contains(qNorm) || qNorm.contains(cNorm));
        }
        String qNorm = normalizeCompact(query.episodeTitle);
        String cNorm = normalizeCompact(candEpTitle);
        if (!qNorm.isEmpty() && !cNorm.isEmpty()) {
            return cNorm.equals(qNorm);
        }
        return exactMatchFlag && !candSpecial;
    }

    static double scoreSearchCandidate(
            String cleanQueryTitle,
            int querySeason,
            int queryEp,
            String candAnimeTitle,
            String candEpTitle) {
        String qLower = cleanQueryTitle == null ? "" : cleanQueryTitle.toLowerCase(Locale.ROOT);
        String cLower = candAnimeTitle == null ? "" : candAnimeTitle.toLowerCase(Locale.ROOT);
        boolean qMotion = isMotionComic(qLower);
        boolean cMotion = isMotionComic(cLower);
        double score = 0.55;
        if (qMotion != cMotion) score -= 0.30;
        String qNorm = normalizeCompact(qLower);
        String cNorm = normalizeCompact(cLower);
        if (!qNorm.isEmpty() && !cNorm.isEmpty()) {
            if (qNorm.equals(cNorm)) score += 0.25;
            else if (cNorm.contains(qNorm) || qNorm.contains(cNorm)) {
                score += Math.max(0.06, 0.18 - Math.abs(cNorm.length() - qNorm.length()) * 0.015);
            } else {
                score -= 0.10;
            }
        }
        int candSeason = extractSeasonNum(candEpTitle);
        if (candSeason <= 0) candSeason = extractSeasonNum(candAnimeTitle);
        if (querySeason > 1 && candSeason == querySeason) {
            score += 0.12;
        } else if (querySeason == 1 && (candSeason == 1 || candSeason <= 0)) {
            score += 0.05;
        }
        if (queryEp > 0 && candEpTitle != null && !candEpTitle.trim().isEmpty()) {
            int candEp = extractEpisodeNum(candEpTitle);
            if (candEp == queryEp) score += 0.10;
            else if (candEp > 0) score -= 0.15;
        }
        return Math.max(0.05, Math.min(0.95, score));
    }

    private static String cleanTitle(String raw) {
        if (raw == null) return "";
        String cleaned =
                raw.replaceAll("[\\p{Cntrl}]+", " ")
                        .replaceAll(
                                "(?i)(?:[\\[【(（][^\\]】)）]*(?:4k|8k|2k|1080p|2160p|720p|hdr|杜比|蓝光|国语|粤语|中字|更新|全\\d+集|完结|连载|hd|bd)[^\\]】)）]*[\\]】)）]|更新至?\\s*\\d+\\s*[集话期]?|全\\s*\\d+\\s*[集话期])",
                                " ")
                        .replaceAll("\\s+", " ")
                        .trim();
        return cleaned.isEmpty()
                ? raw.replaceAll("[\\p{Cntrl}]+", " ").replaceAll("\\s+", " ").trim()
                : cleaned;
    }

    private static String stringifyId(Object val) {
        if (val == null || val == JSONObject.NULL) return "";
        return String.valueOf(val).trim();
    }

    private static String stripIllegalXmlChars(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch == 0x9
                    || ch == 0xA
                    || ch == 0xD
                    || (ch >= 0x20 && ch <= 0xD7FF)
                    || (ch >= 0xE000 && ch <= 0xFFFD)) {
                sb.append(ch);
            }
        }
        return sb.toString();
    }

    private static String unescapeXml(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String s = raw.trim();
        if (s.startsWith("<![CDATA[") && s.endsWith("]]>")) {
            s = s.substring(9, s.length() - 3);
        }
        return s.replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&apos;", "'")
                .replace("&#39;", "'");
    }
}

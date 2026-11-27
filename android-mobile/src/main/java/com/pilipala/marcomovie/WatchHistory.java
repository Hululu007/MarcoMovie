package com.pilipala.marcomovie;

import java.util.*;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.json.*;

/** Device-local bookmarks. Resolve fresh media URLs; never persist signed playback URLs. */
final class WatchHistory {
    static final int LIMIT = 60;
    static final String CORRUPTED_PREF = "watch_history_corrupted";
    static volatile boolean historyCorrupted = false;
    private static volatile Thread storageThread;
    static final ExecutorService STORAGE_EXECUTOR =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "playback-storage");
                        t.setDaemon(true);
                        storageThread = t;
                        return t;
                    });

    interface CorruptionRecorder {
        void recordCorruption(String key, String rawCorrupted);
    }

    interface Store {
        void writeHistoryState(String historyJson, boolean corrupted);
    }

    interface Persistence {
        String readRaw();

        boolean readCorruptedPref();

        void writeState(String historyJson, boolean corrupted);
    }

    interface RestoreCallback {
        void onResult(boolean restored);
    }

    static Entry cloneEntry(Entry src) {
        if (src == null) return null;
        Entry e = new Entry();
        e.site = src.site;
        e.id = src.id;
        e.title = src.title;
        e.poster = src.poster;
        e.line = src.line;
        e.lineId = src.lineId;
        e.driveKey = src.driveKey;
        e.episode = src.episode;
        e.episodeKey = src.episodeKey;
        e.episodeMediaId = src.episodeMediaId;
        e.episodeUrl = src.episodeUrl;
        e.index = src.index;
        e.position = src.position;
        e.duration = src.duration;
        e.updated = src.updated;
        return e;
    }

    static <T> T callOnStorageExecutor(final Callable<T> task) throws Exception {
        if (Thread.currentThread() == storageThread) {
            return task.call();
        }
        try {
            return STORAGE_EXECUTOR.submit(task).get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw e;
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new RuntimeException(cause);
        }
    }

    static Future<String> enqueueUpsert(final Persistence persistence, final Entry entry) {
        final Entry snapshot = cloneEntry(entry);
        return STORAGE_EXECUTOR.submit(
                new Callable<String>() {
                    @Override
                    public String call() {
                        if (persistence == null || snapshot == null) return null;
                        if (persistence.readCorruptedPref()) {
                            historyCorrupted = true;
                        }
                        String current = persistence.readRaw();
                        String updated = upsert(current, snapshot);
                        if (updated != null && !updated.equals(current)) {
                            persistence.writeState(updated, historyCorrupted);
                        }
                        return updated;
                    }
                });
    }

    static Future<String> enqueueRemove(
            final Persistence persistence, final String key, final Runnable onComplete) {
        return STORAGE_EXECUTOR.submit(
                new Callable<String>() {
                    @Override
                    public String call() {
                        try {
                            if (persistence == null || key == null || key.isEmpty()) return null;
                            if (persistence.readCorruptedPref()) {
                                historyCorrupted = true;
                            }
                            String current = persistence.readRaw();
                            String updated = remove(current, key);
                            if (updated != null && !updated.equals(current)) {
                                persistence.writeState(updated, historyCorrupted);
                            }
                            return updated;
                        } finally {
                            if (onComplete != null) onComplete.run();
                        }
                    }
                });
    }

    static Future<String> enqueueClear(final Persistence persistence, final Runnable onComplete) {
        return STORAGE_EXECUTOR.submit(
                new Callable<String>() {
                    @Override
                    public String call() {
                        try {
                            if (persistence == null) return clear(null);
                            return clear(
                                    new Store() {
                                        @Override
                                        public void writeHistoryState(
                                                String historyJson, boolean corrupted) {
                                            persistence.writeState(historyJson, corrupted);
                                        }
                                    });
                        } finally {
                            if (onComplete != null) onComplete.run();
                        }
                    }
                });
    }

    static String validateBackupJson(Object rawCandidate) {
        if (rawCandidate == null) return null;
        String text =
                rawCandidate instanceof String
                        ? ((String) rawCandidate).trim()
                        : String.valueOf(rawCandidate).trim();
        if ("null".equals(text)) return null;
        if (text.isEmpty()) return "[]";
        if (!text.startsWith("[") || !text.endsWith("]")) return null;
        return isMalformed(text) ? null : text;
    }

    static Future<Boolean> enqueueBackupRestore(
            final Persistence persistence,
            final Object rawCandidate,
            final RestoreCallback callback) {
        return STORAGE_EXECUTOR.submit(
                new Callable<Boolean>() {
                    @Override
                    public Boolean call() {
                        String validated = validateBackupJson(rawCandidate);
                        boolean ok = false;
                        if (validated != null) {
                            String written =
                                    overwrite(
                                            validated,
                                            persistence == null
                                                    ? null
                                                    : new Store() {
                                                        @Override
                                                        public void writeHistoryState(
                                                                String historyJson,
                                                                boolean corrupted) {
                                                            persistence.writeState(
                                                                    historyJson, corrupted);
                                                        }
                                                    });
                            ok = written != null;
                        } else {
                            AppLog.w(
                                    "WatchHistory",
                                    "Rejected malformed watch_history during backup restore",
                                    null);
                        }
                        if (callback != null) {
                            callback.onResult(ok);
                        }
                        return ok;
                    }
                });
    }

    static boolean isCorrupted() {
        return historyCorrupted;
    }

    static void setCorrupted(boolean corrupted) {
        historyCorrupted = corrupted;
    }

    static String clear() {
        return clear(null);
    }

    static String clear(Store store) {
        historyCorrupted = false;
        if (store != null) {
            store.writeHistoryState("[]", false);
        }
        return "[]";
    }

    static String overwrite(String validJson, Store store) {
        String normalized =
                validJson == null || validJson.trim().isEmpty() ? "[]" : validJson.trim();
        if (isMalformed(normalized)) {
            AppLog.w("WatchHistory", "Rejected malformed full history overwrite", null);
            return null;
        }
        historyCorrupted = false;
        if (store != null) {
            store.writeHistoryState(normalized, false);
        }
        return normalized;
    }

    static boolean isMalformed(String text) {
        if (text == null) return false;
        String t = text.trim();
        if (t.isEmpty() || "[]".equals(t)) return false;
        try {
            JSONArray arr = new JSONArray(t);
            for (int i = 0; i < arr.length(); i++) {
                if (!(arr.get(i) instanceof JSONObject)) {
                    return true;
                }
            }
            return false;
        } catch (Exception e) {
            return true;
        }
    }

    private static boolean isAsciiLetter(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    private static boolean containsAsciiWord(String lower, String word) {
        int wlen = word.length();
        int idx = lower.indexOf(word);
        while (idx >= 0) {
            boolean leftOk = idx == 0 || !isAsciiLetter(lower.charAt(idx - 1));
            int end = idx + wlen;
            boolean rightOk = end >= lower.length() || !isAsciiLetter(lower.charAt(end));
            if (leftOk && rightOk) return true;
            idx = lower.indexOf(word, idx + 1);
        }
        return false;
    }

    static String sha256Hex(String input) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] dig =
                    md.digest(
                            (input == null ? "" : input)
                                    .getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(dig.length * 2);
            for (byte b : dig) {
                sb.append(Character.forDigit((b >>> 4) & 0x0f, 16));
                sb.append(Character.forDigit(b & 0x0f, 16));
            }
            return sb.toString();
        } catch (Exception ignored) {
            return Integer.toHexString(input == null ? 0 : input.hashCode());
        }
    }

    /** Recognizes one of the 4 core netdisk keys from a line title (with ASCII boundary guards). */
    static String detectDriveKeyFromLineName(String raw) {
        if (raw == null || raw.trim().isEmpty()) return "";
        String lower = raw.trim().toLowerCase(Locale.ROOT);
        if (lower.contains("夸克")
                || lower.contains("夸父")
                || lower.contains("kuake")
                || lower.contains("quark")
                || lower.contains("pan.quark.cn")
                || lower.contains("qk原画")
                || lower.contains("qk4k")
                || lower.contains("qk智")) {
            return "quark";
        }
        if (lower.contains("优汐")
                || lower.contains("drive.uc.cn")
                || lower.contains("fast.uc.cn")
                || containsAsciiWord(lower, "uc")) {
            return "uc";
        }
        if (lower.contains("百度")
                || lower.contains("摆渡")
                || lower.contains("嘟嘟")
                || lower.contains("baidu")
                || lower.contains("baidupan")
                || lower.contains("pan.baidu.com")
                || lower.contains("yun.baidu.com")
                || lower.contains("bdwp")) {
            return "baidu";
        }
        if (lower.contains("阿里")
                || lower.contains("阿狸")
                || lower.contains("alipan")
                || lower.contains("aliyundrive")
                || lower.contains("aliyun")
                || containsAsciiWord(lower, "ali")) {
            return "ali";
        }
        return "";
    }

    static String extractLowerHost(String rawUrl) {
        if (rawUrl == null) return "";
        String trimmed = rawUrl.trim();
        if (trimmed.isEmpty()) return "";
        String lower = trimmed.toLowerCase(Locale.ROOT);
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return "";
        try {
            java.net.URL u = new java.net.URL(trimmed);
            String host = u.getHost();
            return host == null ? "" : host.trim().toLowerCase(Locale.ROOT);
        } catch (Exception ignored) {
            return "";
        }
    }

    static boolean hostEqualsOrSubdomain(String host, String domain) {
        if (host == null || host.isEmpty() || domain == null || domain.isEmpty()) return false;
        return host.equals(domain) || host.endsWith("." + domain);
    }

    static String detectDriveKeyFromUrl(String rawUrl) {
        String host = extractLowerHost(rawUrl);
        if (host.isEmpty()) return "";
        if (hostEqualsOrSubdomain(host, "pan.quark.cn")) return "quark";
        if (hostEqualsOrSubdomain(host, "drive.uc.cn")
                || hostEqualsOrSubdomain(host, "fast.uc.cn")) {
            return "uc";
        }
        if (hostEqualsOrSubdomain(host, "pan.baidu.com")
                || hostEqualsOrSubdomain(host, "yun.baidu.com")) {
            return "baidu";
        }
        if (hostEqualsOrSubdomain(host, "alipan.com")
                || hostEqualsOrSubdomain(host, "aliyundrive.com")) {
            return "ali";
        }
        return "";
    }

    private static final Set<String> VOLATILE_QUERY_KEYS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    "sign",
                                    "sig",
                                    "signature",
                                    "token",
                                    "tk",
                                    "auth",
                                    "auth_key",
                                    "authkey",
                                    "key",
                                    "api_key",
                                    "apikey",
                                    "access_token",
                                    "refresh_token",
                                    "id_token",
                                    "jwt",
                                    "ticket",
                                    "st",
                                    "exp",
                                    "expire",
                                    "expires",
                                    "expires_in",
                                    "ts",
                                    "time",
                                    "timestamp",
                                    "nonce",
                                    "rand",
                                    "random",
                                    "_",
                                    "_t",
                                    "cb",
                                    "cache",
                                    "cachebuster",
                                    "hash",
                                    "md5",
                                    "sha",
                                    "sha1",
                                    "sha256",
                                    "hmac",
                                    "policy",
                                    "session",
                                    "session_id",
                                    "sess",
                                    "cookie",
                                    "secret",
                                    "wssecret",
                                    "wstime",
                                    "txsecret",
                                    "txtime",
                                    "pwd",
                                    "password",
                                    "pass",
                                    "passcode",
                                    "code",
                                    "lease",
                                    "lease_id",
                                    "ip",
                                    "client_ip",
                                    "uid",
                                    "userid",
                                    "user_id",
                                    "did",
                                    "device_id",
                                    "uuid",
                                    "ossaccesskeyid",
                                    "googleaccessid",
                                    "awsaccesskeyid")));

    private static boolean looksLikeEpochOrHexTimestamp(String rawValue) {
        if (rawValue == null) return false;
        String v = rawValue.trim();
        int n = v.length();
        if (n >= 9 && n <= 13) {
            boolean allDigits = true;
            for (int i = 0; i < n; i++) {
                if (!Character.isDigit(v.charAt(i))) {
                    allDigits = false;
                    break;
                }
            }
            if (allDigits) return true;
        }
        if (n >= 8 && n <= 16) {
            boolean allHex = true;
            boolean hasAlphaHex = false;
            for (int i = 0; i < n; i++) {
                char ch = v.charAt(i);
                if ((ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')) {
                    hasAlphaHex = true;
                } else if (ch < '0' || ch > '9') {
                    allHex = false;
                    break;
                }
            }
            if (allHex && hasAlphaHex) return true;
        }
        return false;
    }

    private static boolean isVolatileOrSensitiveQueryParam(String rawKey, String rawValue) {
        if (rawKey == null || rawKey.isEmpty()) return true;
        String k = rawKey.trim().toLowerCase(Locale.ROOT);
        if (k.isEmpty()) return true;
        // Single-letter "e" / "t" can identify episodes (e=1, e=2) on CMS routes, while CDNs use
        // Unix epoch or hex timestamps (e=1799999999, t=65a0b1c2) for expiration.
        if ("e".equals(k) || "t".equals(k)) {
            return looksLikeEpochOrHexTimestamp(rawValue);
        }
        if (VOLATILE_QUERY_KEYS.contains(k)) return true;
        if (k.startsWith("x-amz-")
                || k.startsWith("x-oss-")
                || k.startsWith("x-cos-")
                || k.startsWith("x-qiniu-")
                || k.startsWith("q-sign")
                || k.startsWith("q-ak")
                || k.startsWith("q-key-time")
                || k.startsWith("q-header-list")
                || k.startsWith("q-url-param-list")
                || k.startsWith("utm_")) {
            return true;
        }
        return k.contains("sign")
                || k.contains("token")
                || k.contains("auth")
                || k.contains("secret")
                || k.contains("expire")
                || k.contains("passwd")
                || k.contains("password")
                || k.contains("cookie")
                || k.contains("session")
                || k.contains("ticket")
                || k.contains("nonce")
                || k.contains("hmac")
                || k.contains("lease")
                || k.contains("timestamp");
    }

    private static String canonicalizeNonSensitiveQuery(String rawQuery) {
        if (rawQuery == null || rawQuery.isEmpty()) return "";
        String[] parts = rawQuery.split("&");
        List<String> kept = new ArrayList<>();
        for (String part : parts) {
            if (part == null || part.isEmpty()) continue;
            int eq = part.indexOf('=');
            String k = (eq >= 0 ? part.substring(0, eq) : part).trim().toLowerCase(Locale.ROOT);
            String v = eq >= 0 ? part.substring(eq + 1).trim() : "";
            if (isVolatileOrSensitiveQueryParam(k, v)) continue;
            kept.add(k + "=" + v);
        }
        if (kept.isEmpty()) return "";
        Collections.sort(kept);
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < kept.size(); i++) {
            if (i > 0) sb.append('&');
            sb.append(kept.get(i));
        }
        return sb.toString();
    }

    /**
     * Returns {@code true} for local proxy leases or resolved temporary netdisk download URLs that
     * must NEVER be persisted or synced.
     */
    static boolean isSensitiveOrEphemeralUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return true;
        String trimmed = rawUrl.trim();
        String lower = trimmed.toLowerCase(Locale.ROOT);
        if (lower.startsWith("proxy://")
                || lower.startsWith("file://")
                || lower.startsWith("content://")) {
            return true;
        }
        if (lower.startsWith("http://") || lower.startsWith("https://")) {
            try {
                java.net.URL u = new java.net.URL(trimmed);
                String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
                String path = u.getPath() == null ? "" : u.getPath().toLowerCase(Locale.ROOT);
                if ("127.0.0.1".equals(host)
                        || "localhost".equals(host)
                        || "::1".equals(host)
                        || "[::1]".equals(host)
                        || host.startsWith("127.")
                        || path.contains("/proxy")
                        || path.contains("/lease/")) {
                    return true;
                }
                if (host.contains("baidupcs.com")
                        || host.contains("pcs.baidu.com")
                        || host.contains("aliyundrive.net")
                        || host.contains("alipan.net")
                        || host.contains("dl-pc")
                        || host.contains("pds-")
                        || host.contains("115cdn.com")
                        || (host.contains("quark.cn") && !host.equals("pan.quark.cn"))
                        || (host.contains("uc.cn")
                                && !host.equals("drive.uc.cn")
                                && !host.equals("fast.uc.cn"))) {
                    return true;
                }
            } catch (Exception ignored) {
                return true;
            }
        }
        return false;
    }

    /**
     * Computes a non-sensitive stable episode fingerprint from an upstream episode identifier/URL,
     * preserving episode-identifying query parameters (e.g. {@code id=11} vs {@code id=12}) while
     * stripping volatile signing, auth, token, expiration, and fragment components. Returns {@code
     * ""} for local proxy leases or temporary signed netdisk download URLs so sensitive/ephemeral
     * URLs never enter local bookmarks, backups, or CloudSync payloads.
     */
    static String stableEpisodeKey(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return "";
        if (isSensitiveOrEphemeralUrl(rawUrl)) return "";
        String trimmed = rawUrl.trim();
        int hIdx = trimmed.indexOf('#');
        String noFrag = hIdx >= 0 ? trimmed.substring(0, hIdx) : trimmed;
        int qIdx = noFrag.indexOf('?');
        String basePart = qIdx >= 0 ? noFrag.substring(0, qIdx) : noFrag;
        String rawQuery = qIdx >= 0 ? noFrag.substring(qIdx + 1) : "";
        String cleanQuery = canonicalizeNonSensitiveQuery(rawQuery);
        String canonical;
        if (basePart.toLowerCase(Locale.ROOT).startsWith("http://")
                || basePart.toLowerCase(Locale.ROOT).startsWith("https://")) {
            try {
                java.net.URL u = new java.net.URL(basePart);
                String proto = u.getProtocol().toLowerCase(Locale.ROOT);
                String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
                int port = u.getPort();
                String portPart =
                        (port > 0
                                        && !(("http".equals(proto) && port == 80)
                                                || ("https".equals(proto) && port == 443)))
                                ? (":" + port)
                                : "";
                String path = u.getPath() == null ? "" : u.getPath();
                canonical = proto + "://" + host + portPart + path;
            } catch (Exception ignored) {
                return "";
            }
        } else {
            canonical = basePart;
        }
        if (canonical.isEmpty()) return "";
        if (!cleanQuery.isEmpty()) {
            canonical = canonical + "?" + cleanQuery;
        }
        return "epk1:" + sha256Hex(canonical).substring(0, 24);
    }

    private static final java.util.regex.Pattern WINDOWS_CANONICAL_MEDIA_ID_PATTERN =
            java.util.regex.Pattern.compile("^mid:v1:[0-9a-f]{32}$");
    private static final java.util.regex.Pattern WINDOWS_NON_URI_SECRET_SEG_PATTERN =
            java.util.regex.Pattern.compile(
                    "(?i)([?&|;\\s])(token|sign|sig|signature|auth|auth_key|access_token|secret|pass|password|pwd|cookie|session|expires|expire|exp|key|api_key|apikey)=[^&|;\\s]*");
    private static final Set<String> WINDOWS_SAFE_IDENTITY_QUERY_KEYS =
            Collections.unmodifiableSet(
                    new HashSet<>(
                            Arrays.asList(
                                    "id",
                                    "fid",
                                    "file_id",
                                    "fileid",
                                    "vid",
                                    "item_id",
                                    "itemid",
                                    "share_id",
                                    "shareid",
                                    "fs_id",
                                    "fsid",
                                    "path",
                                    "name",
                                    "ep",
                                    "episode",
                                    "sid",
                                    "v",
                                    "p",
                                    "cid",
                                    "bvid",
                                    "aid",
                                    "playid",
                                    "media_id",
                                    "mediaid",
                                    "file",
                                    "dir",
                                    "folder",
                                    "drive_id",
                                    "driveid",
                                    "pan_id",
                                    "panid",
                                    "uk",
                                    "surl",
                                    "pwd_id",
                                    "vod_id",
                                    "nid",
                                    "part",
                                    "part_id",
                                    "partid",
                                    "ratingkey",
                                    "rating_key",
                                    "episode_id",
                                    "episodeid",
                                    "stream_id",
                                    "streamid",
                                    "asset_id",
                                    "assetid",
                                    "provider",
                                    "drive",
                                    "ref",
                                    "account",
                                    "fids",
                                    "channel_id",
                                    "channelid")));

    static boolean isCanonicalWindowsMediaId(String value) {
        return value != null && WINDOWS_CANONICAL_MEDIA_ID_PATTERN.matcher(value.trim()).matches();
    }

    private static String encodeUriQueryComponentUtf8(String value) {
        if (value == null || value.isEmpty()) return "";
        try {
            return java.net.URLEncoder.encode(value, "UTF-8")
                    .replace("+", "%20")
                    .replace("%21", "!")
                    .replace("%27", "'")
                    .replace("%28", "(")
                    .replace("%29", ")")
                    .replace("%7E", "~");
        } catch (Exception ignored) {
            return value;
        }
    }

    private static String decodeUriQueryComponentUtf8(String value) {
        if (value == null || value.isEmpty()) return "";
        try {
            return java.net.URLDecoder.decode(value, "UTF-8");
        } catch (Exception ignored) {
            return value;
        }
    }

    /**
     * Computes a Windows/Flutter 0.7.3-compatible {@code mid:v1:<32hex>} non-streamable media
     * identity from an upstream episode URL (matching {@code
     * WatchHistoryEntry.mediaIdentityForUrl}). Returns {@code ""} for empty URLs or ephemeral
     * loopback proxy leases.
     */
    static String windowsMediaIdentityForUrl(String rawUrl) {
        if (rawUrl == null) return "";
        String trimmed = rawUrl.trim();
        if (trimmed.isEmpty()) return "";
        if (isCanonicalWindowsMediaId(trimmed)) return trimmed;
        String lowerRaw = trimmed.toLowerCase(Locale.ROOT);
        if (lowerRaw.startsWith("proxy://")
                || lowerRaw.contains("127.0.0.1")
                || lowerRaw.contains("localhost")
                || lowerRaw.contains("[::1]")
                || lowerRaw.contains("/proxy/")
                || lowerRaw.contains("/lease/")) {
            return "";
        }
        String canonical = trimmed;
        try {
            java.net.URI uri = java.net.URI.create(trimmed);
            String scheme = uri.getScheme();
            if (scheme != null && !scheme.isEmpty()) {
                String lowerScheme = scheme.toLowerCase(Locale.ROOT);
                String rawAuth = uri.getRawAuthority();
                String host = uri.getHost();
                int port = uri.getPort();
                boolean hasExplicitPort =
                        port >= 0
                                && !(("http".equals(lowerScheme) && port == 80)
                                        || ("https".equals(lowerScheme) && port == 443));
                StringBuilder buf = new StringBuilder();
                buf.append(lowerScheme).append(':');
                if (rawAuth != null) {
                    buf.append("//");
                    if (host != null) {
                        buf.append(host.toLowerCase(Locale.ROOT));
                    }
                    if (hasExplicitPort) {
                        buf.append(':').append(port);
                    }
                }
                String path = uri.getRawPath();
                if (path != null) {
                    buf.append(path);
                } else if (uri.getRawSchemeSpecificPart() != null && rawAuth == null) {
                    String ssp = uri.getRawSchemeSpecificPart();
                    int qIdx = ssp.indexOf('?');
                    buf.append(qIdx >= 0 ? ssp.substring(0, qIdx) : ssp);
                }
                String rawQuery = uri.getRawQuery();
                if (rawQuery != null && !rawQuery.isEmpty()) {
                    TreeMap<String, List<String>> kept = new TreeMap<>();
                    for (String pair : rawQuery.split("&")) {
                        if (pair.isEmpty()) continue;
                        int eq = pair.indexOf('=');
                        String k =
                                decodeUriQueryComponentUtf8(eq >= 0 ? pair.substring(0, eq) : pair);
                        String v =
                                eq >= 0 ? decodeUriQueryComponentUtf8(pair.substring(eq + 1)) : "";
                        String lowerKey = k.toLowerCase(Locale.ROOT);
                        if (!WINDOWS_SAFE_IDENTITY_QUERY_KEYS.contains(lowerKey)) continue;
                        List<String> list = kept.get(lowerKey);
                        if (list == null) {
                            list = new ArrayList<>();
                            kept.put(lowerKey, list);
                        }
                        list.add(v);
                    }
                    if (!kept.isEmpty()) {
                        buf.append('?');
                        boolean first = true;
                        for (Map.Entry<String, List<String>> e : kept.entrySet()) {
                            for (String val : e.getValue()) {
                                if (!first) buf.append('&');
                                first = false;
                                buf.append(encodeUriQueryComponentUtf8(e.getKey()))
                                        .append('=')
                                        .append(encodeUriQueryComponentUtf8(val));
                            }
                        }
                    }
                }
                canonical = buf.toString();
            } else {
                canonical = WINDOWS_NON_URI_SECRET_SEG_PATTERN.matcher(trimmed).replaceAll("$1");
            }
        } catch (Exception ignored) {
            canonical = WINDOWS_NON_URI_SECRET_SEG_PATTERN.matcher(trimmed).replaceAll("$1");
        }
        String digest = sha256Hex(canonical);
        return digest.length() >= 32 ? ("mid:v1:" + digest.substring(0, 32)) : "";
    }

    /**
     * Resolves {@code episodeMediaId} when Android starts or saves playback for an episode.
     *
     * <p>When {@code savedMatchedBookmark} was ALREADY confirmed by {@link HistoryResumeMatcher} to
     * represent this exact episode/file and carries a non-sensitive Windows {@code episodeMediaId},
     * preserves it across continued playback unless {@code rawEpisodeUrl} maps to a strictly
     * different canonical Windows media ID AND {@code savedMatchedBookmark} already carried a
     * conflicting Android {@code episodeKey}. When switching to a different episode or conflicting
     * duplicate-named file ({@code savedMatchedBookmark == null}), never inherits an old identity
     * and derives only this episode's own identity.
     */
    static String resolveEpisodeMediaIdForPlayback(
            String rawEpisodeUrl, Entry savedMatchedBookmark) {
        String derived = windowsMediaIdentityForUrl(rawEpisodeUrl);
        if (savedMatchedBookmark != null) {
            String savedMid = sanitizeEpisodeMediaId(savedMatchedBookmark.episodeMediaId);
            if (!savedMid.isEmpty()) {
                if (derived.isEmpty() || savedMid.equals(derived)) {
                    return savedMid;
                }
                // If savedMatchedBookmark came from Windows (no Android episodeKey) and was
                // confirmed to match this unique episode even though Android's site plugin
                // represents the upstream URL differently, preserve Windows' episodeMediaId.
                String savedEpKey = bookmarkEpisodeKey(savedMatchedBookmark);
                String curEpKey = stableEpisodeKey(rawEpisodeUrl);
                if (savedEpKey.isEmpty() || (!curEpKey.isEmpty() && savedEpKey.equals(curEpKey))) {
                    return savedMid;
                }
            }
        }
        return derived;
    }

    /**
     * Pure-JVM playback bookmark builder shared by fullscreen ({@link PlaybackController}) and
     * inline ({@link MobileInlinePlayer}) players so Windows {@code episodeMediaId} is preserved
     * when continuing the confirmed same episode and never transferred onto a different episode or
     * conflicting duplicate-named file.
     */
    static Entry buildPlaybackEntry(
            String siteKey,
            String vodId,
            String title,
            String poster,
            String lineRawName,
            String lineId,
            String driveKey,
            String episodeName,
            String rawEpisodeUrl,
            int episodeIndex,
            int positionMs,
            int durationMs,
            long updatedMs,
            Entry savedMatchedBookmark) {
        Entry e = new Entry();
        e.site = siteKey == null ? "" : siteKey;
        e.id = vodId == null ? "" : vodId;
        e.title = title == null ? "" : title;
        e.poster = poster == null ? "" : poster;
        e.line = lineRawName == null ? "" : lineRawName;
        e.lineId = lineId == null ? "" : lineId;
        e.driveKey = driveKey == null ? "" : driveKey;
        e.episode = episodeName == null ? "" : episodeName;
        e.episodeKey = stableEpisodeKey(rawEpisodeUrl);
        e.episodeMediaId = resolveEpisodeMediaIdForPlayback(rawEpisodeUrl, savedMatchedBookmark);
        e.episodeUrl = "";
        e.index = Math.max(0, episodeIndex);
        e.position = Math.max(0, positionMs);
        e.duration = Math.max(0, durationMs);
        e.updated = updatedMs;
        return e;
    }

    private static boolean isSameConfirmedEpisodeForMediaIdCarry(Entry prev, Entry next) {
        if (prev == null || next == null) return false;
        String prevMid = sanitizeEpisodeMediaId(prev.episodeMediaId);
        if (prevMid.isEmpty()) return false;
        String prevEp = prev.episode == null ? "" : prev.episode.trim();
        String nextEp = next.episode == null ? "" : next.episode.trim();
        if (prevEp.isEmpty() || !prevEp.equalsIgnoreCase(nextEp)) return false;
        String prevLineId = prev.lineId == null ? "" : prev.lineId.trim();
        String nextLineId = next.lineId == null ? "" : next.lineId.trim();
        String prevLine = prev.line == null ? "" : prev.line.trim();
        String nextLine = next.line == null ? "" : next.line.trim();
        boolean sameLine =
                (!prevLineId.isEmpty() && !nextLineId.isEmpty())
                        ? prevLineId.equals(nextLineId)
                        : (!prevLine.isEmpty() && prevLine.equalsIgnoreCase(nextLine));
        if (!sameLine) return false;
        String prevDrive = bookmarkDriveKey(prev);
        String nextDrive = bookmarkDriveKey(next);
        if (!prevDrive.isEmpty() && !nextDrive.isEmpty() && !prevDrive.equals(nextDrive)) {
            return false;
        }
        // Require BOTH entries to share a confirmed non-empty episodeKey so duplicate-named files
        // without matching fingerprints NEVER inherit another file's episodeMediaId.
        String prevEpKey = bookmarkEpisodeKey(prev);
        String nextEpKey = bookmarkEpisodeKey(next);
        return !prevEpKey.isEmpty() && prevEpKey.equals(nextEpKey);
    }

    private static boolean isSensitiveHistoryUrlKey(String key) {
        return "episodeUrl".equals(key)
                || "episode_url".equals(key)
                || "playUrl".equals(key)
                || "play_url".equals(key)
                || "downloadUrl".equals(key)
                || "download_url".equals(key)
                || "proxyUrl".equals(key)
                || "proxy_url".equals(key);
    }

    /**
     * Validates a cross-platform stable non-streamable episode media ID (such as Windows/Flutter
     * 0.7.3's {@code mid:v1:<sha256>} {@code episodeMediaId}) while rejecting raw URLs, signed
     * query strings, or local proxy leases so credentials can never be smuggled through it.
     */
    static String sanitizeEpisodeMediaId(String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.isEmpty() || trimmed.length() > 160) return "";
        if (isSensitiveOrEphemeralUrl(trimmed)) return "";
        String lower = trimmed.toLowerCase(Locale.ROOT);
        if (lower.contains("://")
                || lower.indexOf('?') >= 0
                || lower.indexOf('&') >= 0
                || lower.indexOf('\n') >= 0
                || lower.indexOf('\r') >= 0
                || lower.contains("token=")
                || lower.contains("sign=")
                || lower.contains("auth_key=")
                || lower.contains("password=")
                || lower.contains("127.0.0.1")
                || lower.contains("localhost")) {
            return "";
        }
        return trimmed;
    }

    /**
     * Losslessly strips legacy sensitive playback URL fields from a raw history array without
     * truncating entries (e.g. > 60), dropping legacy {@code siteKey}/{@code vodId} schemas,
     * reordering entries, or removing cross-platform non-sensitive extension fields such as Windows
     * 0.7.3's {@code episodeMediaId}. Used when preserving remote history during subscribe-only
     * sync or sanitizing backups.
     */
    static JSONArray sanitizePreservingHistoryArray(JSONArray rawArr) {
        JSONArray clean = new JSONArray();
        if (rawArr == null) return clean;
        for (int i = 0; i < rawArr.length(); i++) {
            Object rawElem = rawArr.opt(i);
            if (!(rawElem instanceof JSONObject)) {
                if (rawElem != null) clean.put(rawElem);
                continue;
            }
            JSONObject src = (JSONObject) rawElem;
            JSONObject copy = new JSONObject();
            String legacyUrl = "";
            Iterator<String> it = src.keys();
            while (it.hasNext()) {
                String k = it.next();
                if (k == null) continue;
                if (isSensitiveHistoryUrlKey(k)) {
                    if (legacyUrl.isEmpty()) {
                        legacyUrl = Cms.optSafeString(src, k);
                    }
                    continue;
                }
                if ("episodeMediaId".equals(k)) {
                    String safeMediaId = sanitizeEpisodeMediaId(Cms.optSafeString(src, k));
                    if (!safeMediaId.isEmpty()) {
                        try {
                            copy.put(k, safeMediaId);
                        } catch (JSONException ignored) {
                        }
                    }
                    continue;
                }
                try {
                    copy.put(k, src.get(k));
                } catch (JSONException ignored) {
                }
            }
            if (!legacyUrl.isEmpty()) {
                try {
                    if (Cms.optSafeString(copy, "episodeKey").isEmpty()) {
                        String derivedEpKey = stableEpisodeKey(legacyUrl);
                        if (!derivedEpKey.isEmpty()) {
                            copy.put("episodeKey", derivedEpKey);
                        }
                    }
                    if (Cms.optSafeString(copy, "driveKey").isEmpty()) {
                        String derivedDrive = detectDriveKeyFromUrl(legacyUrl);
                        if (derivedDrive.isEmpty()) {
                            derivedDrive =
                                    detectDriveKeyFromLineName(Cms.optSafeString(copy, "line"));
                        }
                        if (!derivedDrive.isEmpty()) {
                            copy.put("driveKey", derivedDrive);
                        }
                    }
                } catch (JSONException ignored) {
                }
            } else if (Cms.optSafeString(copy, "driveKey").isEmpty()) {
                String derivedDrive = detectDriveKeyFromLineName(Cms.optSafeString(copy, "line"));
                if (!derivedDrive.isEmpty()) {
                    try {
                        copy.put("driveKey", derivedDrive);
                    } catch (JSONException ignored) {
                    }
                }
            }
            clean.put(copy);
        }
        return clean;
    }

    /**
     * Sanitizes a raw watch-history JSON array (e.g. from legacy backups or remote sync payloads),
     * migrating non-sensitive {@code episodeKey}/{@code driveKey} while stripping any legacy {@code
     * episodeUrl}, temporary download URLs, signed parameters, or local proxy leases.
     */
    static JSONArray sanitizeHistoryArray(JSONArray rawArr) {
        return sanitizePreservingHistoryArray(rawArr);
    }

    /**
     * Validates and sanitizes a serialized watch-history JSON array string for backup/restore.
     * Returns {@code null} if {@code rawJson} is not a valid JSON array.
     */
    static String sanitizeHistoryJson(String rawJson) {
        if (rawJson == null) return null;
        String trimmed = rawJson.trim();
        if (trimmed.isEmpty()) return "[]";
        if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return null;
        try {
            JSONArray rawArr = new JSONArray(trimmed);
            return sanitizePreservingHistoryArray(rawArr).toString();
        } catch (Exception ignored) {
            return null;
        }
    }

    static String bookmarkDriveKey(Entry bookmark) {
        if (bookmark == null) return "";
        if (bookmark.driveKey != null && !bookmark.driveKey.trim().isEmpty()) {
            return bookmark.driveKey.trim().toLowerCase(Locale.ROOT);
        }
        String byUrl = detectDriveKeyFromUrl(bookmark.episodeUrl);
        if (!byUrl.isEmpty()) return byUrl;
        return detectDriveKeyFromLineName(bookmark.line);
    }

    static String bookmarkEpisodeKey(Entry bookmark) {
        if (bookmark == null) return "";
        if (bookmark.episodeKey != null && !bookmark.episodeKey.trim().isEmpty()) {
            return bookmark.episodeKey.trim();
        }
        return stableEpisodeKey(bookmark.episodeUrl);
    }

    static final class Entry {
        String site,
                id,
                title,
                poster,
                line,
                lineId,
                driveKey,
                episode,
                episodeKey,
                episodeMediaId,
                episodeUrl;
        int index, position, duration;
        long updated;

        String key() {
            return site + "\n" + id;
        }

        boolean complete() {
            return duration > 0 && position >= duration - Math.min(5000, duration / 20);
        }

        int resume() {
            return complete() ? 0 : Math.max(0, position);
        }

        /**
         * Serializes non-sensitive stable resume identity. Never persists or exports temporary
         * download URLs, query parameters, signed tokens, or local proxy leases.
         */
        JSONObject json() throws JSONException {
            JSONObject obj =
                    new JSONObject()
                            .put("site", site)
                            .put("id", id)
                            .put("title", title)
                            .put("poster", poster)
                            .put("line", line)
                            .put("episode", episode)
                            .put("index", index)
                            .put("position", position)
                            .put("duration", duration)
                            .put("updated", updated);
            String effLineId = lineId != null ? lineId.trim() : "";
            if (!effLineId.isEmpty()) {
                obj.put("lineId", effLineId);
            }
            String effDrive = bookmarkDriveKey(this);
            if (!effDrive.isEmpty()) {
                obj.put("driveKey", effDrive);
            }
            String effEpKey = bookmarkEpisodeKey(this);
            if (!effEpKey.isEmpty()) {
                obj.put("episodeKey", effEpKey);
            }
            String effEpMediaId = sanitizeEpisodeMediaId(episodeMediaId);
            if (!effEpMediaId.isEmpty()) {
                obj.put("episodeMediaId", effEpMediaId);
            }
            return obj;
        }

        /** Explicit CloudSync serialization — strictly non-sensitive stable identity only. */
        JSONObject syncJson() throws JSONException {
            return json();
        }
    }

    static List<Entry> read(String text) {
        return read(text, null);
    }

    static List<Entry> read(String text, CorruptionRecorder recorder) {
        List<Entry> out = new ArrayList<>();
        Set<String> keys = new HashSet<>();
        if (text == null) return out;
        String trimmed = text.trim();
        if (trimmed.isEmpty() || "[]".equals(trimmed)) return out;
        try {
            JSONArray a = new JSONArray(trimmed);
            for (int i = 0; i < a.length() && out.size() < LIMIT; i++) {
                JSONObject o = a.optJSONObject(i);
                if (o == null) continue;
                Entry e = new Entry();
                e.site = Cms.optSafeString(o, "site");
                e.id = Cms.optSafeString(o, "id");
                e.title = Cms.optSafeString(o, "title");
                e.poster = Cms.optSafeString(o, "poster");
                e.line = Cms.optSafeString(o, "line");
                e.lineId = Cms.optSafeString(o, "lineId");
                e.driveKey = Cms.optSafeString(o, "driveKey");
                e.episode = Cms.optSafeString(o, "episode");
                e.episodeKey = Cms.optSafeString(o, "episodeKey");
                e.episodeMediaId = sanitizeEpisodeMediaId(Cms.optSafeString(o, "episodeMediaId"));
                String legacyUrl = Cms.optSafeString(o, "episodeUrl");
                if (e.episodeKey.isEmpty() && !legacyUrl.isEmpty()) {
                    e.episodeKey = stableEpisodeKey(legacyUrl);
                }
                if (e.driveKey.isEmpty() && !legacyUrl.isEmpty()) {
                    e.driveKey = detectDriveKeyFromUrl(legacyUrl);
                }
                e.episodeUrl = "";
                e.index = Math.max(0, o.optInt("index"));
                e.position = Math.max(0, o.optInt("position"));
                e.duration = Math.max(0, o.optInt("duration"));
                e.updated = o.optLong("updated");
                if (!e.site.isEmpty() && !e.id.isEmpty() && keys.add(e.key())) out.add(e);
            }
        } catch (Exception e) {
            boolean wasCorrupted = historyCorrupted;
            historyCorrupted = true;
            if (!wasCorrupted && recorder != null) {
                long ts = System.currentTimeMillis();
                recorder.recordCorruption("watch_history_corrupt_" + ts, text);
            }
            AppLog.w("WatchHistory", "History JSON corrupted, parse failed", e);
        }
        return out;
    }

    static String upsert(String text, Entry entry) {
        if (historyCorrupted || isMalformed(text)) {
            historyCorrupted = true;
            AppLog.w("WatchHistory", "Skipping upsert because watch history is corrupted", null);
            return text;
        }
        List<Entry> entries = read(text);
        Entry prev = null;
        for (Iterator<Entry> it = entries.iterator(); it.hasNext(); ) {
            Entry cur = it.next();
            if (cur.key().equals(entry.key())) {
                prev = cur;
                it.remove();
            }
        }
        Entry toStore = cloneEntry(entry);
        if (toStore != null) {
            String curMid = sanitizeEpisodeMediaId(toStore.episodeMediaId);
            if (curMid.isEmpty() && isSameConfirmedEpisodeForMediaIdCarry(prev, toStore)) {
                toStore.episodeMediaId = sanitizeEpisodeMediaId(prev.episodeMediaId);
            } else {
                toStore.episodeMediaId = curMid;
            }
            entries.add(0, toStore);
        }
        JSONArray a = new JSONArray();
        for (int i = 0; i < Math.min(LIMIT, entries.size()); i++)
            try {
                a.put(entries.get(i).json());
            } catch (Exception ignored) {
            }
        return a.toString();
    }

    static String remove(String text, String key) {
        if (historyCorrupted || isMalformed(text)) {
            historyCorrupted = true;
            return text;
        }
        JSONArray a = new JSONArray();
        for (Entry e : read(text))
            if (!e.key().equals(key))
                try {
                    a.put(e.json());
                } catch (Exception ignored) {
                }
        return a.toString();
    }
}

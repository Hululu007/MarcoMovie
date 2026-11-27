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

    static String detectDriveKeyFromUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return "";
        String lower = rawUrl.trim().toLowerCase(Locale.ROOT);
        if (lower.contains("pan.quark.cn")) return "quark";
        if (lower.contains("drive.uc.cn") || lower.contains("fast.uc.cn")) return "uc";
        if (lower.contains("pan.baidu.com") || lower.contains("yun.baidu.com")) return "baidu";
        if (lower.contains("alipan.com") || lower.contains("aliyundrive.com")) return "ali";
        return "";
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
     * Computes a non-sensitive stable episode fingerprint from an upstream episode identifier/URL
     * after stripping query parameters, fragments, and userinfo. Returns {@code ""} for local proxy
     * leases or temporary signed netdisk download URLs so sensitive/ephemeral URLs never enter
     * local bookmarks or CloudSync payloads.
     */
    static String stableEpisodeKey(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return "";
        if (isSensitiveOrEphemeralUrl(rawUrl)) return "";
        String trimmed = rawUrl.trim();
        String canonical;
        int qIdx = trimmed.indexOf('?');
        int hIdx = trimmed.indexOf('#');
        int cut = qIdx >= 0 && hIdx >= 0 ? Math.min(qIdx, hIdx) : (qIdx >= 0 ? qIdx : hIdx);
        String noQuery = cut >= 0 ? trimmed.substring(0, cut) : trimmed;
        if (noQuery.toLowerCase(Locale.ROOT).startsWith("http://")
                || noQuery.toLowerCase(Locale.ROOT).startsWith("https://")) {
            try {
                java.net.URL u = new java.net.URL(noQuery);
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
            canonical = noQuery;
        }
        if (canonical.isEmpty()) return "";
        return "epk1:" + sha256Hex(canonical).substring(0, 24);
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
        String site, id, title, poster, line, lineId, driveKey, episode, episodeKey, episodeUrl;
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
        for (Iterator<Entry> it = entries.iterator(); it.hasNext(); ) {
            if (it.next().key().equals(entry.key())) it.remove();
        }
        entries.add(0, entry);
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

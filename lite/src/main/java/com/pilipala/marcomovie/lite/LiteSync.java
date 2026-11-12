// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Android 4.0+ (API 14+) {@code marco-movie-sync} v2 engine for TV Lite.
 *
 * <p>Interoperates seamlessly with Android TV, Android Mobile/Tablet, iOS, iPadOS, macOS, and
 * Windows over both WebDAV and LAN peer-to-peer HTTP. Strictly API 14 compatible (no {@code
 * StandardCharsets}, {@code java.util.Base64}, or {@code Long.compare}), upgrades HTTPS via {@link
 * NetworkTls}, strips private sites/lives, and preserves secondary remote subscriptions so Lite
 * never drops multi-subscription entries created on other platforms.
 */
public final class LiteSync {
    public static final String SCHEMA = "marco-movie-sync";
    public static final int VERSION = 2;
    public static final String DEFAULT_FILE = "marco-movie-sync.json";
    public static final int MAX_TOMBSTONES = 300;
    public static final int MAX_SYNC_BYTES = 8 * 1024 * 1024;
    private static final char[] BASE64_ALPHABET =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    private LiteSync() {}

    public interface MergeCallback {
        MergeResult merge(String remotePayloadJson) throws Exception;
    }

    public interface LanPeerCallback {
        String exportLocalPayload() throws Exception;

        MergeResult applyMergedPayload(String remoteMergedPayloadJson) throws Exception;
    }

    public static final class LocalSubscription {
        public String key = "";
        public String name = "";
        public String url = "";
        public String rawContent = "";
        public String selectedSiteKey = "";
        public long updatedAt = 1L;

        public static LocalSubscription create(
                String name,
                String url,
                String rawContent,
                String selectedSiteKey,
                long updatedAt) {
            String cleanUrl = cleanHttpUrl(url);
            String cleanRaw = sanitizePublicRawConfig(rawContent);
            if (cleanUrl.length() == 0 && cleanRaw.length() == 0) return null;
            LocalSubscription s = new LocalSubscription();
            s.url = cleanUrl;
            s.rawContent = cleanRaw;
            s.key = subscriptionIdentity(cleanUrl, cleanRaw);
            String n = name == null ? "" : name.trim();
            s.name = n.length() == 0 ? "我的订阅" : n;
            s.selectedSiteKey = selectedSiteKey == null ? "" : selectedSiteKey.trim();
            s.updatedAt = updatedAt > 0L ? updatedAt : 1L;
            return s;
        }

        public JSONObject toJson() throws JSONException {
            return new JSONObject()
                    .put("id", key)
                    .put("syncKey", key)
                    .put("key", key)
                    .put("name", name.length() == 0 ? "我的订阅" : name)
                    .put("url", url)
                    .put("rawContent", rawContent)
                    .put("isPrivate", false)
                    .put("enabled", true)
                    .put("selectedSiteKey", selectedSiteKey)
                    .put("updatedAt", updatedAt > 0L ? updatedAt : 1L);
        }
    }

    public static final class MergeResult {
        public final String historyJson;
        public final String favoritesJson;
        public final String tombstonesJson;
        public final LocalSubscription activeSubscription;
        public final boolean clearLocalSubscription;
        public final String payloadJson;
        public final int historyCount;
        public final int favoriteCount;
        public final int subscriptionCount;
        public final boolean changed;

        MergeResult(
                String historyJson,
                String favoritesJson,
                String tombstonesJson,
                LocalSubscription activeSubscription,
                boolean clearLocalSubscription,
                String payloadJson,
                int historyCount,
                int favoriteCount,
                int subscriptionCount,
                boolean changed) {
            this.historyJson = historyJson;
            this.favoritesJson = favoritesJson;
            this.tombstonesJson = tombstonesJson;
            this.activeSubscription = activeSubscription;
            this.clearLocalSubscription = clearLocalSubscription;
            this.payloadJson = payloadJson;
            this.historyCount = historyCount;
            this.favoriteCount = favoriteCount;
            this.subscriptionCount = subscriptionCount;
            this.changed = changed;
        }
    }

    public static final class Tombstones {
        public final Map<String, Long> stamps = new LinkedHashMap<String, Long>();

        public static Tombstones read(String raw) {
            Tombstones t = new Tombstones();
            if (raw == null || raw.length() == 0) return t;
            try {
                final JSONObject obj = new JSONObject(raw);
                Iterator<String> keys = obj.keys();
                List<String> names = new ArrayList<String>();
                while (keys.hasNext()) names.add(keys.next());
                Collections.sort(
                        names,
                        new Comparator<String>() {
                            public int compare(String a, String b) {
                                long va = obj.optLong(a, 0L);
                                long vb = obj.optLong(b, 0L);
                                return vb < va ? -1 : (vb > va ? 1 : 0);
                            }
                        });
                for (int i = 0; i < Math.min(MAX_TOMBSTONES, names.size()); i++) {
                    String k = names.get(i);
                    long ts = obj.optLong(k, 0L);
                    if (k.length() > 0 && ts > 0L) t.stamps.put(k, Long.valueOf(ts));
                }
            } catch (Exception ignored) {
            }
            return t;
        }

        public long get(String key) {
            Long v = stamps.get(key);
            return v == null ? 0L : v.longValue();
        }

        public void putMax(String key, long ts) {
            if (key == null || key.length() == 0 || ts <= 0L) return;
            Long prev = stamps.get(key);
            if (prev == null || ts > prev.longValue()) {
                stamps.put(key, Long.valueOf(ts));
            }
        }

        public void merge(Tombstones other) {
            if (other == null) return;
            for (Map.Entry<String, Long> e : other.stamps.entrySet()) {
                if (e.getValue() != null) putMax(e.getKey(), e.getValue().longValue());
            }
        }

        public JSONObject toJsonObject() {
            List<Map.Entry<String, Long>> list =
                    new ArrayList<Map.Entry<String, Long>>(stamps.entrySet());
            Collections.sort(
                    list,
                    new Comparator<Map.Entry<String, Long>>() {
                        public int compare(Map.Entry<String, Long> a, Map.Entry<String, Long> b) {
                            long va = a.getValue() == null ? 0L : a.getValue().longValue();
                            long vb = b.getValue() == null ? 0L : b.getValue().longValue();
                            return vb < va ? -1 : (vb > va ? 1 : 0);
                        }
                    });
            JSONObject out = new JSONObject();
            for (int i = 0; i < Math.min(MAX_TOMBSTONES, list.size()); i++) {
                Map.Entry<String, Long> e = list.get(i);
                long v = e.getValue() == null ? 0L : e.getValue().longValue();
                if (v > 0L) {
                    try {
                        out.put(e.getKey(), v);
                    } catch (JSONException ignored) {
                    }
                }
            }
            return out;
        }

        public String json() {
            return toJsonObject().toString();
        }
    }

    public static String itemKey(String siteKey, String vodId) {
        return (siteKey == null ? "" : siteKey) + "\n" + (vodId == null ? "" : vodId);
    }

    public static String subscriptionIdentity(String origin, String raw) {
        String trimmedOrigin = origin == null ? "" : origin.trim();
        String basis = trimmedOrigin.length() > 0 ? trimmedOrigin : (raw == null ? "" : raw);
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(basis.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(digest.length * 2);
            for (int i = 0; i < digest.length; i++) {
                String h = Integer.toHexString(digest[i] & 0xff);
                if (h.length() == 1) sb.append('0');
                sb.append(h);
            }
            return sb.toString();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    static String cleanHttpUrl(String raw) {
        if (raw == null) return "";
        String t = raw.trim();
        String lower = t.toLowerCase(Locale.US);
        if (lower.startsWith("http://") || lower.startsWith("https://")) return t;
        return "";
    }

    static boolean isTruthyPrivateFlag(Object flag) {
        if (flag == null) return false;
        if (flag instanceof Boolean) return ((Boolean) flag).booleanValue();
        if (flag instanceof Number) return ((Number) flag).intValue() == 1;
        String s = String.valueOf(flag).trim().toLowerCase(Locale.US);
        return "true".equals(s) || "1".equals(s);
    }

    private static boolean isPrivateJsonEntry(Object entry) {
        if (!(entry instanceof JSONObject)) return false;
        JSONObject map = (JSONObject) entry;
        if (isTruthyPrivateFlag(map.opt("isPrivate"))
                || isTruthyPrivateFlag(map.opt("private"))
                || isTruthyPrivateFlag(map.opt("hidden"))
                || "private".equalsIgnoreCase(map.optString("space", "").trim())) {
            return true;
        }
        String grp = map.optString("group", "");
        return grp.indexOf("隐私") >= 0 || grp.indexOf("私密") >= 0;
    }

    public static String sanitizePublicRawConfig(String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.length() == 0) return "";
        try {
            JSONObject obj = LiteCatalog.decodeConfig(trimmed);
            if (obj.has("api") && isPrivateJsonEntry(obj)) return "";
            boolean modified = false;
            boolean hadFiltered = false;
            int publicCount = 0;
            String[] keys = {"sites", "lives"};
            for (int kIdx = 0; kIdx < keys.length; kIdx++) {
                String k = keys[kIdx];
                Object field = obj.opt(k);
                if (field instanceof JSONArray) {
                    hadFiltered = true;
                    JSONArray arr = (JSONArray) field;
                    JSONArray clean = new JSONArray();
                    for (int i = 0; i < arr.length(); i++) {
                        Object item = arr.opt(i);
                        if (isPrivateJsonEntry(item)) {
                            modified = true;
                        } else {
                            clean.put(item);
                            publicCount++;
                        }
                    }
                    if (modified) obj.put(k, clean);
                }
            }
            if (!modified) return raw;
            JSONArray depots = obj.optJSONArray("urls");
            if (depots == null) depots = obj.optJSONArray("depots");
            if (hadFiltered && publicCount == 0 && (depots == null || depots.length() == 0)) {
                return "";
            }
            return obj.toString();
        } catch (Exception ignored) {
            return raw;
        }
    }

    public static String exportPayload(
            String historyRaw,
            String favoritesRaw,
            String tombstonesRaw,
            LocalSubscription localSub,
            boolean syncSubs,
            long now) {
        JSONArray subsArr = null;
        if (syncSubs) {
            subsArr = new JSONArray();
            Tombstones tombs = Tombstones.read(tombstonesRaw);
            if (localSub != null
                    && localSub.key.length() > 0
                    && tombs.get("sub:" + localSub.key) < localSub.updatedAt) {
                try {
                    subsArr.put(localSub.toJson());
                } catch (JSONException ignored) {
                }
            }
        }
        return buildWirePayload(historyRaw, favoritesRaw, tombstonesRaw, subsArr, now);
    }

    private static String buildWirePayload(
            String historyRaw,
            String favoritesRaw,
            String tombstonesRaw,
            JSONArray subsArrayOrNull,
            long now) {
        List<LiteStore.HistoryEntry> hist = LiteStore.parseHistoryJson(historyRaw);
        List<LiteStore.FavoriteEntry> favs = LiteStore.parseFavoritesJson(favoritesRaw);
        Tombstones tombs = Tombstones.read(tombstonesRaw);

        JSONArray histArr = new JSONArray();
        for (int i = 0; i < hist.size(); i++) {
            LiteStore.HistoryEntry e = hist.get(i);
            try {
                histArr.put(
                        new JSONObject()
                                .put("site", e.siteKey)
                                .put("siteName", e.siteName)
                                .put("siteApi", e.siteApi)
                                .put("id", e.vodId)
                                .put("title", e.vodName)
                                .put("poster", e.vodPic)
                                .put("line", e.lineName)
                                .put("episode", e.epName)
                                .put("epUrl", e.epUrl)
                                .put("index", e.epIndex)
                                .put("position", Math.max(0, e.positionMs))
                                .put("duration", Math.max(0, e.durationMs))
                                .put("updated", e.updatedAt > 0L ? e.updatedAt : 1L));
            } catch (JSONException ignored) {
            }
        }

        JSONArray favArr = new JSONArray();
        for (int i = 0; i < favs.size(); i++) {
            LiteStore.FavoriteEntry f = favs.get(i);
            String k = itemKey(f.siteKey, f.vodId);
            long ts = Math.max(1L, Math.max(f.addedAt, tombs.get("add:" + k)));
            try {
                favArr.put(
                        new JSONObject()
                                .put("site", f.siteKey)
                                .put("siteName", f.siteName)
                                .put("siteApi", f.siteApi)
                                .put("id", f.vodId)
                                .put("title", f.vodName)
                                .put("poster", f.vodPic)
                                .put("remarks", f.vodRemarks)
                                .put("updated", ts)
                                .put("addedAt", ts));
            } catch (JSONException ignored) {
            }
        }

        try {
            JSONObject root =
                    new JSONObject()
                            .put("schema", SCHEMA)
                            .put("version", VERSION)
                            .put("updated", now)
                            .put("updatedAt", now)
                            .put("watch_history", histArr)
                            .put("favorites", favArr)
                            .put("tombstones", tombs.toJsonObject());
            if (subsArrayOrNull != null) {
                root.put("subscriptions", subsArrayOrNull);
            }
            return root.toString();
        } catch (JSONException e) {
            return "{}";
        }
    }

    public static MergeResult merge(
            String localHistoryRaw,
            String localFavoritesRaw,
            String localTombstonesRaw,
            LocalSubscription localSub,
            boolean syncSubs,
            String remotePayloadJson,
            long now) {
        List<LiteStore.HistoryEntry> localHist = LiteStore.parseHistoryJson(localHistoryRaw);
        List<LiteStore.FavoriteEntry> localFavs = LiteStore.parseFavoritesJson(localFavoritesRaw);
        Tombstones tombs = Tombstones.read(localTombstonesRaw);
        for (int i = 0; i < localFavs.size(); i++) {
            LiteStore.FavoriteEntry lf = localFavs.get(i);
            if (lf.addedAt > 0L) {
                tombs.putMax("add:" + itemKey(lf.siteKey, lf.vodId), lf.addedAt);
            }
        }

        List<LiteStore.HistoryEntry> remoteHist = new ArrayList<LiteStore.HistoryEntry>();
        List<LiteStore.FavoriteEntry> remoteFavs = new ArrayList<LiteStore.FavoriteEntry>();
        JSONArray rawRemoteSubs = null;

        if (remotePayloadJson != null && remotePayloadJson.trim().length() > 0) {
            try {
                JSONObject root = new JSONObject(remotePayloadJson);
                String schema = root.optString("schema", root.optString("format", ""));
                if (schema.length() > 0
                        && !SCHEMA.equals(schema)
                        && !"marco-movie-backup".equals(schema)
                        && !"MarcoMovie-1".equals(schema)) {
                    throw new IllegalArgumentException("不支持的同步数据格式: " + schema);
                }
                JSONObject rt = root.optJSONObject("tombstones");
                if (rt != null) tombs.merge(Tombstones.read(rt.toString()));

                JSONArray hArr = root.optJSONArray("watch_history");
                if (hArr == null) hArr = root.optJSONArray("history");
                if (hArr == null) hArr = root.optJSONArray("watchHistory");
                JSONObject prefsBag = root.optJSONObject("prefs");
                if (prefsBag == null) prefsBag = root.optJSONObject("settings");
                if (hArr == null && prefsBag != null) {
                    Object rh = prefsBag.opt("watch_history");
                    if (rh instanceof JSONArray) hArr = (JSONArray) rh;
                    else if (rh instanceof String && ((String) rh).length() > 0) {
                        hArr = new JSONArray((String) rh);
                    }
                }
                if (hArr != null) remoteHist = parseWireHistory(hArr);

                JSONArray fArr = root.optJSONArray("favorites");
                if (fArr == null && prefsBag != null) {
                    Object rf = prefsBag.opt("favorites");
                    if (rf instanceof JSONArray) fArr = (JSONArray) rf;
                    else if (rf instanceof String && ((String) rf).length() > 0) {
                        fArr = new JSONArray((String) rf);
                    }
                }
                if (fArr != null) remoteFavs = parseWireFavorites(fArr);

                if (root.has("subscriptions") && root.optJSONArray("subscriptions") != null) {
                    rawRemoteSubs = root.optJSONArray("subscriptions");
                } else if ("MarcoMovie-1".equals(schema) || "marco-movie-backup".equals(schema)) {
                    String orig = root.optString("origin", "").trim();
                    String cfg = root.optString("rawConfig", root.optString("config", ""));
                    LocalSubscription legacy =
                            LocalSubscription.create("备份订阅", orig, cfg, "", 1L);
                    if (legacy != null) {
                        rawRemoteSubs = new JSONArray().put(legacy.toJson());
                    }
                }
            } catch (IllegalArgumentException e) {
                throw e;
            } catch (Exception e) {
                throw new IllegalArgumentException("远端同步文件解析失败", e);
            }
        }

        // 1. Merge WatchHistory (LWW + hist: tombstones)
        Map<String, LiteStore.HistoryEntry> histMap =
                new LinkedHashMap<String, LiteStore.HistoryEntry>();
        for (int i = 0; i < localHist.size(); i++) {
            LiteStore.HistoryEntry e = localHist.get(i);
            String k = itemKey(e.siteKey, e.vodId);
            long delAt = tombs.get("hist:" + k);
            if (delAt > 0L && delAt >= e.updatedAt) continue;
            histMap.put(k, e);
        }
        for (int i = 0; i < remoteHist.size(); i++) {
            LiteStore.HistoryEntry r = remoteHist.get(i);
            String k = itemKey(r.siteKey, r.vodId);
            long delAt = tombs.get("hist:" + k);
            if (delAt > 0L && delAt >= r.updatedAt) continue;
            LiteStore.HistoryEntry cur = histMap.get(k);
            if (cur == null) {
                histMap.put(k, r);
            } else if (r.updatedAt > cur.updatedAt
                    || (r.updatedAt == cur.updatedAt && r.positionMs > cur.positionMs)) {
                if (r.siteApi.length() == 0 && cur.siteApi.length() > 0) r.siteApi = cur.siteApi;
                if (r.siteName.length() == 0 && cur.siteName.length() > 0) r.siteName = cur.siteName;
                if (r.epUrl.length() == 0 && cur.epUrl.length() > 0) r.epUrl = cur.epUrl;
                histMap.put(k, r);
            }
        }
        List<LiteStore.HistoryEntry> mergedHist =
                new ArrayList<LiteStore.HistoryEntry>(histMap.values());
        Collections.sort(
                mergedHist,
                new Comparator<LiteStore.HistoryEntry>() {
                    public int compare(LiteStore.HistoryEntry a, LiteStore.HistoryEntry b) {
                        return b.updatedAt < a.updatedAt ? -1 : (b.updatedAt > a.updatedAt ? 1 : 0);
                    }
                });
        JSONArray nextHistArr = new JSONArray();
        for (int i = 0; i < Math.min(LiteStore.MAX_HISTORY, mergedHist.size()); i++) {
            try {
                nextHistArr.put(mergedHist.get(i).toJson());
            } catch (Exception ignored) {
            }
        }

        // 2. Merge Favorites (fav: vs add: timestamps)
        Map<String, LiteStore.FavoriteEntry> favMap =
                new LinkedHashMap<String, LiteStore.FavoriteEntry>();
        for (int i = 0; i < localFavs.size(); i++) {
            LiteStore.FavoriteEntry f = localFavs.get(i);
            String k = itemKey(f.siteKey, f.vodId);
            long addTs = Math.max(1L, Math.max(f.addedAt, tombs.get("add:" + k)));
            long delTs = tombs.get("fav:" + k);
            if (delTs > addTs) continue;
            f.addedAt = addTs;
            tombs.putMax("add:" + k, addTs);
            favMap.put(k, f);
        }
        for (int i = 0; i < remoteFavs.size(); i++) {
            LiteStore.FavoriteEntry rf = remoteFavs.get(i);
            String k = itemKey(rf.siteKey, rf.vodId);
            long effAdd = Math.max(1L, Math.max(rf.addedAt, tombs.get("add:" + k)));
            long delTs = tombs.get("fav:" + k);
            if (delTs > effAdd) continue;
            rf.addedAt = effAdd;
            tombs.putMax("add:" + k, effAdd);
            LiteStore.FavoriteEntry existing = favMap.get(k);
            if (existing == null) {
                favMap.put(k, rf);
            } else {
                if (existing.vodPic.length() == 0 && rf.vodPic.length() > 0) {
                    existing.vodPic = rf.vodPic;
                }
                if (existing.siteApi.length() == 0 && rf.siteApi.length() > 0) {
                    existing.siteApi = rf.siteApi;
                }
            }
        }
        JSONArray nextFavArr = new JSONArray();
        int favIdx = 0;
        for (LiteStore.FavoriteEntry f : favMap.values()) {
            if (favIdx >= LiteStore.MAX_FAVORITES) break;
            try {
                nextFavArr.put(f.toJson());
                favIdx++;
            } catch (Exception ignored) {
            }
        }

        // 3. Merge Subscriptions (preserving all multi-subscription entries from TV/Mobile/Flutter)
        JSONArray outSubsArray = null;
        LocalSubscription chosenActive = null;
        boolean clearLocalSub = false;
        int subCount = 0;

        if (syncSubs) {
            Map<String, JSONObject> mergedSubObjects = new LinkedHashMap<String, JSONObject>();
            if (localSub != null && localSub.key.length() > 0) {
                if (tombs.get("sub:" + localSub.key) < localSub.updatedAt) {
                    try {
                        mergedSubObjects.put(localSub.key, localSub.toJson());
                        chosenActive = localSub;
                    } catch (JSONException ignored) {
                    }
                } else {
                    clearLocalSub = true;
                }
            }
            if (rawRemoteSubs != null) {
                for (int i = 0; i < rawRemoteSubs.length(); i++) {
                    JSONObject ro = rawRemoteSubs.optJSONObject(i);
                    LocalSubscription parsedRemote = parseRemoteSubscription(ro);
                    if (parsedRemote == null) continue;
                    if (tombs.get("sub:" + parsedRemote.key) >= parsedRemote.updatedAt) continue;
                    JSONObject existingObj = mergedSubObjects.get(parsedRemote.key);
                    if (existingObj == null) {
                        try {
                            JSONObject cleanCopy = new JSONObject(ro.toString());
                            cleanCopy.put("id", parsedRemote.key);
                            cleanCopy.put("syncKey", parsedRemote.key);
                            cleanCopy.put("key", parsedRemote.key);
                            cleanCopy.put("rawContent", parsedRemote.rawContent);
                            cleanCopy.put("isPrivate", false);
                            mergedSubObjects.put(parsedRemote.key, cleanCopy);
                        } catch (JSONException ignored) {
                        }
                        if (chosenActive == null && ro.optBoolean("enabled", true)) {
                            chosenActive = parsedRemote;
                            clearLocalSub = false;
                        }
                    } else if (parsedRemote.updatedAt > existingObj.optLong("updatedAt", 1L)) {
                        try {
                            JSONObject cleanCopy = new JSONObject(ro.toString());
                            cleanCopy.put("id", parsedRemote.key);
                            cleanCopy.put("syncKey", parsedRemote.key);
                            cleanCopy.put("key", parsedRemote.key);
                            cleanCopy.put("rawContent", parsedRemote.rawContent);
                            cleanCopy.put("isPrivate", false);
                            mergedSubObjects.put(parsedRemote.key, cleanCopy);
                        } catch (JSONException ignored) {
                        }
                        if (localSub != null && parsedRemote.key.equals(localSub.key)) {
                            chosenActive = parsedRemote;
                        }
                    }
                }
            }
            outSubsArray = new JSONArray();
            for (JSONObject o : mergedSubObjects.values()) {
                outSubsArray.put(o);
            }
            subCount = outSubsArray.length();
        } else if (rawRemoteSubs != null) {
            outSubsArray = rawRemoteSubs;
        }

        String nextHistJson = nextHistArr.toString();
        String nextFavJson = nextFavArr.toString();
        String nextTombJson = tombs.json();
        boolean changed =
                !nextHistJson.equals(localHistoryRaw == null ? "[]" : localHistoryRaw)
                        || !nextFavJson.equals(localFavoritesRaw == null ? "[]" : localFavoritesRaw)
                        || clearLocalSub
                        || (chosenActive != null
                                && (localSub == null
                                        || !chosenActive.key.equals(localSub.key)
                                        || !chosenActive.rawContent.equals(localSub.rawContent)));

        String payload =
                buildWirePayload(nextHistJson, nextFavJson, nextTombJson, outSubsArray, now);
        return new MergeResult(
                nextHistJson,
                nextFavJson,
                nextTombJson,
                chosenActive,
                clearLocalSub,
                payload,
                nextHistArr.length(),
                nextFavArr.length(),
                subCount,
                changed);
    }

    private static LocalSubscription parseRemoteSubscription(JSONObject o) {
        if (o == null) return null;
        String grp = o.optString("group", o.optString("groupTag", "")).trim();
        if (isTruthyPrivateFlag(o.opt("isPrivate"))
                || isTruthyPrivateFlag(o.opt("private"))
                || isTruthyPrivateFlag(o.opt("hidden"))
                || grp.indexOf("隐私") >= 0
                || grp.indexOf("私密") >= 0) {
            return null;
        }
        String rawUrl =
                o.optString("warehouseUrl", "").trim().length() > 0
                        ? o.optString("warehouseUrl", "").trim()
                        : o.optString("url", o.optString("origin", "")).trim();
        if (rawUrl.toLowerCase(Locale.US).startsWith("file:")) return null;
        String cleanUrl = cleanHttpUrl(rawUrl);
        String rawCfg =
                sanitizePublicRawConfig(o.optString("rawContent", o.optString("raw", "")));
        if (cleanUrl.length() == 0 && rawCfg.length() == 0) return null;
        LocalSubscription item = new LocalSubscription();
        item.url = cleanUrl;
        item.rawContent = rawCfg;
        item.key = subscriptionIdentity(cleanUrl, rawCfg);
        item.name = o.optString("name", "").trim();
        if (item.name.length() == 0) item.name = "我的订阅";
        item.selectedSiteKey = o.optString("selectedSiteKey", o.optString("selected", "")).trim();
        item.updatedAt = Math.max(1L, o.optLong("updatedAt", o.optLong("updated", 1L)));
        return item;
    }

    private static List<LiteStore.HistoryEntry> parseWireHistory(JSONArray arr) {
        List<LiteStore.HistoryEntry> out = new ArrayList<LiteStore.HistoryEntry>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            String site = o.optString("site", o.optString("siteKey", "")).trim();
            String id = o.optString("id", o.optString("vodId", "")).trim();
            String title = o.optString("title", o.optString("vodName", "")).trim();
            if (site.length() == 0 || id.length() == 0 || "live".equals(site)) continue;
            if (title.length() == 0) title = id;
            LiteStore.HistoryEntry e = new LiteStore.HistoryEntry();
            e.siteKey = site;
            e.siteName = o.optString("siteName", site);
            e.siteApi = o.optString("siteApi", "");
            e.vodId = id;
            e.vodName = title;
            e.vodPic = o.optString("poster", o.optString("vodPic", ""));
            e.lineName = o.optString("line", o.optString("lineName", ""));
            e.epName =
                    o.optString(
                            "episode",
                            o.optString("epName", o.optString("episodeName", "")));
            e.epUrl = o.optString("epUrl", "");
            e.epIndex = Math.max(0, o.optInt("index", o.optInt("epIndex", 0)));
            long pos = o.has("position") ? o.optLong("position", 0L) : o.optLong("positionMs", 0L);
            long dur = o.has("duration") ? o.optLong("duration", 0L) : o.optLong("durationMs", 0L);
            e.positionMs = (int) Math.max(0L, Math.min(Integer.MAX_VALUE, pos));
            e.durationMs = (int) Math.max(0L, Math.min(Integer.MAX_VALUE, dur));
            e.updatedAt = Math.max(1L, o.optLong("updated", o.optLong("updatedAt", 1L)));
            out.add(e);
        }
        return out;
    }

    private static List<LiteStore.FavoriteEntry> parseWireFavorites(JSONArray arr) {
        List<LiteStore.FavoriteEntry> out = new ArrayList<LiteStore.FavoriteEntry>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            String site = o.optString("site", o.optString("siteKey", "")).trim();
            String id = o.optString("id", o.optString("vodId", "")).trim();
            String title = o.optString("title", o.optString("vodName", "")).trim();
            if (site.length() == 0 || id.length() == 0) continue;
            if (title.length() == 0) title = id;
            LiteStore.FavoriteEntry f = new LiteStore.FavoriteEntry();
            f.siteKey = site;
            f.siteName = o.optString("siteName", site);
            f.siteApi = o.optString("siteApi", "");
            f.vodId = id;
            f.vodName = title;
            f.vodPic = o.optString("poster", o.optString("vodPic", ""));
            f.vodRemarks = o.optString("remarks", o.optString("vodRemarks", ""));
            f.addedAt = Math.max(1L, o.optLong("updated", o.optLong("addedAt", 1L)));
            out.add(f);
        }
        return out;
    }

    public static String resolveWebdavFileUrl(String rawUrl) throws IOException {
        if (rawUrl == null || rawUrl.trim().length() == 0) {
            throw new IOException("请填写 WebDAV 服务器地址");
        }
        String u = rawUrl.trim();
        String lower = u.toLowerCase(Locale.US);
        if (!lower.startsWith("https://") && !lower.startsWith("http://")) {
            throw new IOException("WebDAV 地址需以 https:// 或 http:// 开头");
        }
        String pathOnly = u;
        int q = pathOnly.indexOf('?');
        if (q >= 0) pathOnly = pathOnly.substring(0, q);
        if (pathOnly.toLowerCase(Locale.US).endsWith(".json")) {
            return u;
        }
        return u.endsWith("/") ? (u + DEFAULT_FILE) : (u + "/" + DEFAULT_FILE);
    }

    public static String resolveLanSyncEndpoint(String rawInput) throws IOException {
        if (rawInput == null || rawInput.trim().length() == 0) {
            throw new IOException("请输入对方设备的局域网同步地址");
        }
        String u = rawInput.trim();
        String lower = u.toLowerCase(Locale.US);
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            u = "http://" + u;
        }
        while (u.endsWith("/")) u = u.substring(0, u.length() - 1);
        return u.endsWith("/sync") ? u : (u + "/sync");
    }

    public static String basicAuthHeader(String user, String pass) {
        if ((user == null || user.length() == 0) && (pass == null || pass.length() == 0)) {
            return "";
        }
        String raw = (user == null ? "" : user) + ":" + (pass == null ? "" : pass);
        try {
            return "Basic " + encodeBase64(raw.getBytes("UTF-8"));
        } catch (Exception e) {
            return "";
        }
    }

    static String encodeBase64(byte[] data) {
        StringBuilder out = new StringBuilder(((data.length + 2) / 3) * 4);
        int i = 0;
        while (i < data.length) {
            int b0 = data[i++] & 0xff;
            int b1 = i < data.length ? (data[i++] & 0xff) : -1;
            int b2 = i < data.length ? (data[i++] & 0xff) : -1;
            out.append(BASE64_ALPHABET[b0 >>> 2]);
            if (b1 < 0) {
                out.append(BASE64_ALPHABET[(b0 & 0x03) << 4]);
                out.append("==");
            } else if (b2 < 0) {
                out.append(BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >>> 4)]);
                out.append(BASE64_ALPHABET[(b1 & 0x0f) << 2]);
                out.append('=');
            } else {
                out.append(BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >>> 4)]);
                out.append(BASE64_ALPHABET[((b1 & 0x0f) << 2) | (b2 >>> 6)]);
                out.append(BASE64_ALPHABET[b2 & 0x3f]);
            }
        }
        return out.toString();
    }

    public static MergeResult syncWebdav(
            String rawWebdavUrl, String username, String password, MergeCallback merger)
            throws Exception {
        String fileUrl = resolveWebdavFileUrl(rawWebdavUrl);
        String auth = basicAuthHeader(username, password);
        HttpURLConnection getConn = openConnection(fileUrl, "GET", auth, 12000);
        String remoteJson = null;
        try {
            int code = getConn.getResponseCode();
            if (code >= 200 && code < 300) {
                remoteJson = readBody(getConn.getInputStream(), MAX_SYNC_BYTES);
            } else if (code == 401 || code == 403) {
                throw new IOException("WebDAV 认证失败 (HTTP " + code + ")");
            } else if (code != 404) {
                throw new IOException("WebDAV 读取失败 (HTTP " + code + ")");
            }
        } finally {
            getConn.disconnect();
        }

        MergeResult merged = merger.merge(remoteJson);
        byte[] payloadBytes = merged.payloadJson.getBytes("UTF-8");
        if (payloadBytes.length > MAX_SYNC_BYTES) {
            throw new IOException("同步数据超出 8 MB 限制");
        }

        int putCode = putBytes(fileUrl, auth, payloadBytes);
        if (putCode == 404 || putCode == 409) {
            ensureParentCollections(fileUrl, auth);
            putCode = putBytes(fileUrl, auth, payloadBytes);
        }
        if (putCode == 401 || putCode == 403) {
            throw new IOException("WebDAV 写入被拒绝 (HTTP " + putCode + ")");
        }
        if (putCode < 200 || putCode >= 300) {
            throw new IOException("WebDAV 写入失败 (HTTP " + putCode + ")");
        }
        return merged;
    }

    public static MergeResult syncLanPeer(String peerUrl, LanPeerCallback callback)
            throws Exception {
        String endpoint = resolveLanSyncEndpoint(peerUrl);
        byte[] outBytes = callback.exportLocalPayload().getBytes("UTF-8");
        if (outBytes.length > MAX_SYNC_BYTES) {
            throw new IOException("本地同步数据超出 8 MB 限制");
        }
        HttpURLConnection conn = openConnection(endpoint, "POST", null, 12000);
        String respBody;
        try {
            conn.setDoOutput(true);
            conn.setFixedLengthStreamingMode(outBytes.length);
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            OutputStream os = conn.getOutputStream();
            try {
                os.write(outBytes);
            } finally {
                os.close();
            }
            int code = conn.getResponseCode();
            if (code == 410) {
                throw new IOException("对方局域网同步会话已过期，请重新打开二维码");
            }
            if (code < 200 || code >= 300) {
                throw new IOException("局域网同步失败 (HTTP " + code + ")");
            }
            respBody = readBody(conn.getInputStream(), MAX_SYNC_BYTES);
        } finally {
            conn.disconnect();
        }
        return callback.applyMergedPayload(respBody);
    }

    private static int putBytes(String fileUrl, String auth, byte[] body) throws IOException {
        HttpURLConnection conn = openConnection(fileUrl, "PUT", auth, 15000);
        try {
            conn.setDoOutput(true);
            conn.setFixedLengthStreamingMode(body.length);
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            OutputStream os = conn.getOutputStream();
            try {
                os.write(body);
            } finally {
                os.close();
            }
            return conn.getResponseCode();
        } finally {
            conn.disconnect();
        }
    }

    private static HttpURLConnection openConnection(
            String urlStr, String method, String auth, int timeoutMs) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        if (conn instanceof HttpsURLConnection) {
            NetworkTls.configure((HttpsURLConnection) conn);
        }
        conn.setInstanceFollowRedirects(false);
        conn.setConnectTimeout(timeoutMs);
        conn.setReadTimeout(timeoutMs);
        conn.setUseCaches(false);
        conn.setRequestMethod(method);
        conn.setRequestProperty("User-Agent", "MarcoMovie-LiteSync/2.0");
        conn.setRequestProperty("Accept", "application/json");
        if (auth != null && auth.length() > 0) {
            conn.setRequestProperty("Authorization", auth);
        }
        return conn;
    }

    private static void ensureParentCollections(String fileUrl, String auth) {
        try {
            URI uri = new URI(fileUrl);
            String rawPath = uri.getRawPath();
            if (rawPath == null || rawPath.length() == 0) return;
            int lastSlash = rawPath.lastIndexOf('/');
            if (lastSlash <= 0) return;
            String parentPath = rawPath.substring(0, lastSlash + 1);
            String[] parts = parentPath.split("/");
            StringBuilder current = new StringBuilder("/");
            for (int i = 0; i < parts.length; i++) {
                String p = parts[i];
                if (p == null || p.length() == 0) continue;
                current.append(p).append('/');
                sendRawMkcol(uri, current.toString(), auth);
            }
        } catch (Exception ignored) {
        }
    }

    private static void sendRawMkcol(URI baseUri, String rawCollectionPath, String auth) {
        String scheme =
                baseUri.getScheme() == null
                        ? "http"
                        : baseUri.getScheme().toLowerCase(Locale.US);
        boolean https = "https".equals(scheme);
        String host = baseUri.getHost();
        if (host == null || host.length() == 0) return;
        int port = baseUri.getPort();
        int connectPort = port > 0 ? port : (https ? 443 : 80);
        String hostHeader =
                (port > 0 && port != (https ? 443 : 80)) ? (host + ":" + port) : host;
        Socket sock = null;
        try {
            Socket tcp = new Socket();
            tcp.connect(new InetSocketAddress(host, connectPort), 8000);
            tcp.setSoTimeout(8000);
            if (https) {
                SSLSocketFactory sf =
                        new NetworkTls.ModernTlsFactory(NetworkTls.context(null).getSocketFactory());
                SSLSocket ssl = (SSLSocket) sf.createSocket(tcp, host, connectPort, true);
                ssl.startHandshake();
                if (!HttpsURLConnection.getDefaultHostnameVerifier()
                        .verify(host, ssl.getSession())) {
                    ssl.close();
                    return;
                }
                sock = ssl;
            } else {
                sock = tcp;
            }
            StringBuilder req = new StringBuilder();
            req.append("MKCOL ").append(rawCollectionPath).append(" HTTP/1.1\r\n");
            req.append("Host: ").append(hostHeader).append("\r\n");
            req.append("User-Agent: MarcoMovie-LiteSync/2.0\r\n");
            if (auth != null && auth.length() > 0) {
                req.append("Authorization: ").append(auth).append("\r\n");
            }
            req.append("Content-Length: 0\r\n");
            req.append("Connection: close\r\n\r\n");
            OutputStream os = sock.getOutputStream();
            os.write(req.toString().getBytes("UTF-8"));
            os.flush();
            InputStream is = sock.getInputStream();
            byte[] buf = new byte[256];
            is.read(buf);
        } catch (Exception ignored) {
        } finally {
            if (sock != null) {
                try {
                    sock.close();
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static String readBody(InputStream in, int maxBytes) throws IOException {
        if (in == null) return "";
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try {
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) {
                if (bos.size() + n > maxBytes) {
                    throw new IOException("远端同步文件超出大小限制");
                }
                bos.write(buf, 0, n);
            }
            return new String(bos.toByteArray(), "UTF-8");
        } finally {
            try {
                in.close();
            } catch (Exception ignored) {
            }
        }
    }
}

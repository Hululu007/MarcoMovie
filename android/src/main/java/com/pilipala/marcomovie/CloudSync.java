package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Cross-device cloud (WebDAV) and LAN peer-to-peer synchronization engine ({@code marco-movie-sync}
 * v2).
 *
 * <p>Syncs public watch-history bookmarks, favorites, deletion tombstones, and optionally user
 * public subscription configurations across Android TV, Android Mobile/Tablet, Android Lite, iOS,
 * iPadOS, macOS, and Windows. Never exports or mutates Private Space data, cloud drive tokens, or
 * Emby credentials.
 */
final class CloudSync {
    static final String SCHEMA = "marco-movie-sync";
    static final int VERSION = 2;
    static final String DEFAULT_FILE = "marco-movie-sync.json";
    static final int MAX_TOMBSTONES = 300;
    static final int MAX_SYNC_BYTES = 8 * 1024 * 1024;
    private static final char[] BASE64_ALPHABET =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    private CloudSync() {}

    interface MergeCallback {
        MergeResult merge(String remotePayloadJson) throws Exception;
    }

    interface LanPeerCallback {
        String exportLocalPayload() throws Exception;

        MergeResult applyMergedPayload(String remoteMergedPayloadJson) throws Exception;
    }

    /** Public subscription item synchronized across devices in {@code marco-movie-sync} v2. */
    static final class SubscriptionItem {
        String key = "";
        String name = "";
        String url = "";
        String rawContent = "";
        boolean enabled = true;
        String selectedSiteKey = "";
        String groupTag = "";
        long updatedAt = 1L;

        JSONObject toJson() throws JSONException {
            String safeKey = key == null ? "" : key;
            JSONObject o =
                    new JSONObject()
                            .put("id", safeKey)
                            .put("syncKey", safeKey)
                            .put("key", safeKey)
                            .put("name", name == null || name.isEmpty() ? "我的订阅" : name)
                            .put("url", url == null ? "" : url)
                            .put("rawContent", rawContent == null ? "" : rawContent)
                            .put("isPrivate", false)
                            .put("enabled", enabled)
                            .put("selectedSiteKey", selectedSiteKey == null ? "" : selectedSiteKey)
                            .put("updatedAt", Math.max(1L, updatedAt));
            if (groupTag != null && !groupTag.isEmpty()) {
                o.put("group", groupTag);
                o.put("groupTag", groupTag);
            }
            return o;
        }

        static SubscriptionItem create(
                String name,
                String originUrl,
                String rawConfig,
                boolean enabled,
                String selectedSiteKey,
                long updatedAt)
                throws Exception {
            String cleanUrl = originUrl == null ? "" : originUrl.trim();
            if (cleanUrl.toLowerCase(Locale.ROOT).startsWith("file:")) {
                cleanUrl = "";
            }
            if (!cleanUrl.isEmpty() && !Cms.isHttp(cleanUrl)) {
                cleanUrl = "";
            }
            String publicRaw = sanitizePublicRawConfig(rawConfig);
            if (cleanUrl.isEmpty() && publicRaw.isEmpty()) return null;
            SubscriptionItem item = new SubscriptionItem();
            item.url = cleanUrl;
            item.rawContent = publicRaw;
            item.key = ConfigLibrary.identity(cleanUrl, publicRaw);
            item.name = name == null || name.trim().isEmpty() ? "我的订阅" : name.trim();
            item.enabled = enabled;
            item.selectedSiteKey = selectedSiteKey == null ? "" : selectedSiteKey.trim();
            item.updatedAt = Math.max(1L, updatedAt);
            return item;
        }

        static SubscriptionItem fromRemoteJson(JSONObject o) {
            if (o == null) return null;
            String grp = o.optString("group", o.optString("groupTag", "")).trim();
            if (isTruthyPrivateFlag(o.opt("isPrivate"))
                    || isTruthyPrivateFlag(o.opt("hidden"))
                    || grp.contains("隐私")
                    || grp.contains("私密")) {
                return null;
            }
            String rawUrl =
                    o.optString("warehouseUrl", "").trim().isEmpty()
                            ? o.optString("url", o.optString("origin", "")).trim()
                            : o.optString("warehouseUrl", "").trim();
            if (rawUrl.toLowerCase(Locale.ROOT).startsWith("file:")) {
                return null;
            }
            String cleanUrl = Cms.isHttp(rawUrl) ? rawUrl : "";
            String rawCfg =
                    sanitizePublicRawConfig(o.optString("rawContent", o.optString("raw", "")));
            if (cleanUrl.isEmpty() && rawCfg.isEmpty()) {
                return null;
            }
            try {
                String canonicalKey;
                String providedKey =
                        o.optString("syncKey", o.optString("key", o.optString("id", "")))
                                .trim()
                                .toLowerCase(Locale.ROOT);
                if (!cleanUrl.isEmpty() || !rawCfg.isEmpty()) {
                    canonicalKey = ConfigLibrary.identity(cleanUrl, rawCfg);
                } else if (providedKey.matches("[0-9a-f]{64}")) {
                    canonicalKey = providedKey;
                } else {
                    return null;
                }
                SubscriptionItem item = new SubscriptionItem();
                item.key = canonicalKey;
                item.name = o.optString("name", "").trim();
                if (item.name.isEmpty()) item.name = "我的订阅";
                item.url = cleanUrl;
                item.rawContent = rawCfg;
                item.enabled = o.optBoolean("enabled", true);
                item.selectedSiteKey =
                        o.optString("selectedSiteKey", o.optString("selected", "")).trim();
                item.groupTag = grp;
                item.updatedAt = Math.max(1L, o.optLong("updatedAt", o.optLong("updated", 1L)));
                return item;
            } catch (Exception ignored) {
                return null;
            }
        }
    }

    static boolean isTruthyPrivateFlag(Object flag) {
        if (flag == null) return false;
        if (flag instanceof Boolean) return (Boolean) flag;
        if (flag instanceof Number) return ((Number) flag).intValue() == 1;
        String s = String.valueOf(flag).trim().toLowerCase(Locale.ROOT);
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
        String group = map.optString("group", "");
        return group.contains("隐私") || group.contains("私密");
    }

    /**
     * Strips any private site or live source from raw subscription JSON so Private Space entries
     * never leave the device.
     */
    static String sanitizePublicRawConfig(String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return "";
        try {
            String unpacked = Cms.withoutComments(trimmed);
            JSONObject obj = new JSONObject(unpacked);
            if (obj.has("api") && isPrivateJsonEntry(obj)) {
                return "";
            }
            boolean modified = false;
            boolean hadFilteredArray = false;
            int remainingPublicItems = 0;
            String[] keys = {"sites", "lives"};
            for (String k : keys) {
                Object field = obj.opt(k);
                if (field instanceof JSONArray) {
                    hadFilteredArray = true;
                    JSONArray arr = (JSONArray) field;
                    JSONArray clean = new JSONArray();
                    for (int i = 0; i < arr.length(); i++) {
                        Object item = arr.opt(i);
                        if (isPrivateJsonEntry(item)) {
                            modified = true;
                        } else {
                            clean.put(item);
                            remainingPublicItems++;
                        }
                    }
                    if (modified) obj.put(k, clean);
                } else if (field instanceof JSONObject && isPrivateJsonEntry(field)) {
                    hadFilteredArray = true;
                    modified = true;
                    obj.put(k, new JSONArray());
                }
            }
            if (!modified) return raw;
            JSONArray depots = obj.optJSONArray("urls");
            if (depots == null) depots = obj.optJSONArray("depots");
            if (hadFilteredArray
                    && remainingPublicItems == 0
                    && (depots == null || depots.length() == 0)) {
                return "";
            }
            return obj.toString();
        } catch (Exception ignored) {
            return raw;
        }
    }

    static final class MergeResult {
        final String historyJson;
        final String favoritesJson;
        final String tombstonesJson;
        final List<SubscriptionItem> subscriptions;
        final String payloadJson;
        final int historyCount;
        final int favoriteCount;
        final int subscriptionCount;
        final boolean changed;
        final boolean subscriptionsChanged;

        MergeResult(
                String historyJson,
                String favoritesJson,
                String tombstonesJson,
                List<SubscriptionItem> subscriptions,
                String payloadJson,
                int historyCount,
                int favoriteCount,
                int subscriptionCount,
                boolean changed,
                boolean subscriptionsChanged) {
            this.historyJson = historyJson;
            this.favoritesJson = favoritesJson;
            this.tombstonesJson = tombstonesJson;
            this.subscriptions = subscriptions;
            this.payloadJson = payloadJson;
            this.historyCount = historyCount;
            this.favoriteCount = favoriteCount;
            this.subscriptionCount = subscriptionCount;
            this.changed = changed;
            this.subscriptionsChanged = subscriptionsChanged;
        }
    }

    /**
     * Tracks deletion and favorite-addition timestamps so deleted items do not resurrect across
     * devices.
     *
     * <ul>
     *   <li>{@code hist:<site>\n<id>} -> epoch millis when watch-history bookmark was deleted
     *   <li>{@code fav:<site>\n<id>} -> epoch millis when favorite was removed
     *   <li>{@code add:<site>\n<id>} -> epoch millis when favorite was added locally
     *   <li>{@code sub:<sha256-hex>} -> epoch millis when subscription was deleted locally
     * </ul>
     */
    static final class Tombstones {
        final Map<String, Long> stamps = new LinkedHashMap<>();

        static Tombstones read(String raw) {
            Tombstones t = new Tombstones();
            if (raw == null || raw.isEmpty()) return t;
            try {
                JSONObject obj = new JSONObject(raw);
                Iterator<String> keys = obj.keys();
                List<String> names = new ArrayList<>();
                while (keys.hasNext()) names.add(keys.next());
                Collections.sort(names, (a, b) -> Long.compare(obj.optLong(b), obj.optLong(a)));
                for (int i = 0; i < Math.min(MAX_TOMBSTONES, names.size()); i++) {
                    String k = names.get(i);
                    long ts = obj.optLong(k, 0L);
                    if (!k.isEmpty() && ts > 0L) t.stamps.put(k, ts);
                }
            } catch (Exception ignored) {
            }
            return t;
        }

        String json() {
            return toJsonObject().toString();
        }

        JSONObject toJsonObject() {
            List<Map.Entry<String, Long>> list = new ArrayList<>(stamps.entrySet());
            Collections.sort(list, (a, b) -> Long.compare(b.getValue(), a.getValue()));
            JSONObject out = new JSONObject();
            for (int i = 0; i < Math.min(MAX_TOMBSTONES, list.size()); i++) {
                Map.Entry<String, Long> e = list.get(i);
                if (e.getValue() != null && e.getValue() > 0L) {
                    try {
                        out.put(e.getKey(), e.getValue().longValue());
                    } catch (JSONException ignored) {
                    }
                }
            }
            return out;
        }

        void putMax(String key, long ts) {
            if (key == null || key.isEmpty() || ts <= 0L) return;
            Long prev = stamps.get(key);
            if (prev == null || ts > prev) stamps.put(key, ts);
        }

        long get(String key) {
            Long v = stamps.get(key);
            return v == null ? 0L : v;
        }

        static String recordHistoryDelete(String raw, String itemKey, long now) {
            Tombstones t = read(raw);
            if (itemKey != null && !itemKey.isEmpty()) {
                t.putMax("hist:" + itemKey, now);
            }
            return t.json();
        }

        static String recordHistoryClear(
                String raw, List<WatchHistory.Entry> currentEntries, long now) {
            Tombstones t = read(raw);
            if (currentEntries != null) {
                for (WatchHistory.Entry e : currentEntries) {
                    if (e != null && e.site != null && e.id != null) {
                        t.putMax("hist:" + e.key(), now);
                    }
                }
            }
            return t.json();
        }

        static String recordFavoriteToggle(
                String raw, String itemKey, boolean nowFavorited, long now) {
            Tombstones t = read(raw);
            if (itemKey != null && !itemKey.isEmpty()) {
                if (nowFavorited) {
                    t.stamps.put("add:" + itemKey, now);
                    t.stamps.remove("fav:" + itemKey);
                } else {
                    t.stamps.put("fav:" + itemKey, now);
                    t.stamps.remove("add:" + itemKey);
                }
            }
            return t.json();
        }

        static String recordSubscriptionUpsert(String raw, String subKey) {
            Tombstones t = read(raw);
            if (subKey != null && !subKey.isEmpty()) {
                t.stamps.remove("sub:" + subKey);
            }
            return t.json();
        }

        static String recordSubscriptionDelete(String raw, String subKey, long now) {
            Tombstones t = read(raw);
            if (subKey != null && !subKey.isEmpty()) {
                t.putMax("sub:" + subKey, now);
            }
            return t.json();
        }

        void merge(Tombstones other) {
            if (other == null) return;
            for (Map.Entry<String, Long> e : other.stamps.entrySet()) {
                if (e.getValue() != null) putMax(e.getKey(), e.getValue());
            }
        }
    }

    static String exportPayload(
            String historyJson,
            String favoritesJson,
            String tombstonesJson,
            List<SubscriptionItem> localSubscriptions,
            boolean syncSubscriptions,
            long now) {
        return exportPayload(
                historyJson,
                favoritesJson,
                tombstonesJson,
                localSubscriptions,
                syncSubscriptions,
                null,
                now);
    }

    static String exportPayload(
            String historyJson,
            String favoritesJson,
            String tombstonesJson,
            List<SubscriptionItem> localSubscriptions,
            boolean syncSubscriptions,
            JSONArray preservedRemoteSubscriptions,
            long now) {
        List<WatchHistory.Entry> history = WatchHistory.read(historyJson);
        List<Favorites.Entry> favs = Favorites.read(favoritesJson);
        Tombstones tombs = Tombstones.read(tombstonesJson);
        JSONArray histArr = new JSONArray();
        for (WatchHistory.Entry e : history) {
            try {
                histArr.put(e.json());
            } catch (JSONException ignored) {
            }
        }
        JSONArray favArr = new JSONArray();
        for (Favorites.Entry f : favs) {
            try {
                long favTs = Math.max(1L, tombs.get("add:" + f.key()));
                favArr.put(f.json().put("updated", favTs).put("addedAt", favTs));
            } catch (JSONException ignored) {
            }
        }
        try {
            JSONObject out =
                    new JSONObject()
                            .put("schema", SCHEMA)
                            .put("version", VERSION)
                            .put("updated", now)
                            .put("updatedAt", now)
                            .put("watch_history", histArr)
                            .put("favorites", favArr)
                            .put("tombstones", tombs.toJsonObject());
            if (syncSubscriptions) {
                JSONArray subsArr = new JSONArray();
                if (localSubscriptions != null) {
                    for (SubscriptionItem sub : localSubscriptions) {
                        if (sub == null || sub.key == null || sub.key.isEmpty()) continue;
                        if (tombs.get("sub:" + sub.key) >= sub.updatedAt) continue;
                        subsArr.put(sub.toJson());
                    }
                }
                out.put("subscriptions", subsArr);
            } else if (preservedRemoteSubscriptions != null) {
                out.put("subscriptions", preservedRemoteSubscriptions);
            }
            return out.toString();
        } catch (JSONException e) {
            return "{}";
        }
    }

    static MergeResult merge(
            String localHistoryJson,
            String localFavoritesJson,
            String localTombstonesJson,
            String remotePayloadJson,
            long now) {
        return merge(
                localHistoryJson,
                localFavoritesJson,
                localTombstonesJson,
                null,
                false,
                remotePayloadJson,
                now);
    }

    static MergeResult merge(
            String localHistoryJson,
            String localFavoritesJson,
            String localTombstonesJson,
            List<SubscriptionItem> localSubscriptions,
            boolean syncSubscriptions,
            String remotePayloadJson,
            long now) {
        List<WatchHistory.Entry> localHist = WatchHistory.read(localHistoryJson);
        List<Favorites.Entry> localFavs = Favorites.read(localFavoritesJson);
        Tombstones tombs = Tombstones.read(localTombstonesJson);

        List<WatchHistory.Entry> remoteHist = new ArrayList<>();
        List<Favorites.Entry> remoteFavs = new ArrayList<>();
        Map<String, Long> remoteFavAdded = new LinkedHashMap<>();
        List<SubscriptionItem> remoteSubs = new ArrayList<>();
        JSONArray rawRemoteSubsArray = null;

        if (remotePayloadJson != null && !remotePayloadJson.trim().isEmpty()) {
            try {
                JSONObject root = new JSONObject(remotePayloadJson);
                String schema = root.optString("schema", root.optString("format", ""));
                if (!schema.isEmpty()
                        && !SCHEMA.equals(schema)
                        && !"marco-movie-backup".equals(schema)
                        && !"MarcoMovie-1".equals(schema)) {
                    throw new IllegalArgumentException("不支持的同步文件格式: " + schema);
                }
                JSONObject remoteTombObj = root.optJSONObject("tombstones");
                if (remoteTombObj != null) {
                    tombs.merge(Tombstones.read(remoteTombObj.toString()));
                }
                JSONArray hArr = root.optJSONArray("watch_history");
                if (hArr == null) hArr = root.optJSONArray("history");
                if (hArr == null) hArr = root.optJSONArray("watchHistory");
                JSONObject prefsBag = root.optJSONObject("prefs");
                if (prefsBag == null) prefsBag = root.optJSONObject("settings");
                if (hArr == null && prefsBag != null) {
                    Object rawH = prefsBag.opt("watch_history");
                    if (rawH instanceof JSONArray) hArr = (JSONArray) rawH;
                    else if (rawH instanceof String && !((String) rawH).isEmpty()) {
                        hArr = new JSONArray((String) rawH);
                    }
                }
                if (hArr != null) {
                    remoteHist = parseRemoteHistory(hArr);
                }
                JSONArray fArr = root.optJSONArray("favorites");
                if (fArr == null && prefsBag != null) {
                    Object rawF = prefsBag.opt("favorites");
                    if (rawF instanceof JSONArray) fArr = (JSONArray) rawF;
                    else if (rawF instanceof String && !((String) rawF).isEmpty()) {
                        fArr = new JSONArray((String) rawF);
                    }
                }
                if (fArr != null) {
                    parseRemoteFavorites(fArr, remoteFavs, remoteFavAdded);
                }
                if (root.has("subscriptions") && root.optJSONArray("subscriptions") != null) {
                    rawRemoteSubsArray = root.optJSONArray("subscriptions");
                    for (int i = 0; i < rawRemoteSubsArray.length(); i++) {
                        SubscriptionItem sub =
                                SubscriptionItem.fromRemoteJson(
                                        rawRemoteSubsArray.optJSONObject(i));
                        if (sub != null) remoteSubs.add(sub);
                    }
                } else if (prefsBag != null
                        && prefsBag.optJSONArray("saved_subscriptions") != null) {
                    JSONArray savedSubs = prefsBag.optJSONArray("saved_subscriptions");
                    for (int i = 0; i < savedSubs.length(); i++) {
                        SubscriptionItem sub =
                                SubscriptionItem.fromRemoteJson(savedSubs.optJSONObject(i));
                        if (sub != null) remoteSubs.add(sub);
                    }
                } else if ("MarcoMovie-1".equals(schema) || "marco-movie-backup".equals(schema)) {
                    String origin = root.optString("origin", "").trim();
                    String cfgRaw = root.optString("rawConfig", root.optString("config", ""));
                    SubscriptionItem legacy =
                            SubscriptionItem.create("备份订阅", origin, cfgRaw, true, "", 1L);
                    if (legacy != null) remoteSubs.add(legacy);
                }
            } catch (IllegalArgumentException e) {
                throw e;
            } catch (Exception e) {
                throw new IllegalArgumentException("远端同步数据解析失败", e);
            }
        }

        // 1. Merge WatchHistory (Last-Write-Wins on `updated`, respecting `hist:` tombstones)
        Map<String, WatchHistory.Entry> histMap = new LinkedHashMap<>();
        for (WatchHistory.Entry e : localHist) {
            long delAt = tombs.get("hist:" + e.key());
            if (delAt > 0L && delAt >= e.updated) continue;
            histMap.put(e.key(), e);
        }
        for (WatchHistory.Entry r : remoteHist) {
            String key = r.key();
            long delAt = tombs.get("hist:" + key);
            if (delAt > 0L && delAt >= r.updated) continue;
            WatchHistory.Entry cur = histMap.get(key);
            if (cur == null
                    || r.updated > cur.updated
                    || (r.updated == cur.updated && r.position > cur.position)) {
                histMap.put(key, r);
            }
        }
        List<WatchHistory.Entry> mergedHist = new ArrayList<>(histMap.values());
        Collections.sort(mergedHist, (a, b) -> Long.compare(b.updated, a.updated));
        if (mergedHist.size() > WatchHistory.LIMIT) {
            mergedHist = new ArrayList<>(mergedHist.subList(0, WatchHistory.LIMIT));
        }

        // 2. Merge Favorites (respecting `fav:` removal vs `add:` addition timestamps)
        Map<String, Favorites.Entry> favMap = new LinkedHashMap<>();
        for (Favorites.Entry f : localFavs) {
            String key = f.key();
            long addedAt = Math.max(1L, tombs.get("add:" + key));
            long delAt = tombs.get("fav:" + key);
            if (delAt > addedAt) continue;
            tombs.putMax("add:" + key, addedAt);
            favMap.put(key, f);
        }
        for (Favorites.Entry rf : remoteFavs) {
            String key = rf.key();
            Long remoteAddedObj = remoteFavAdded.get(key);
            long remoteAdded = Math.max(1L, remoteAddedObj == null ? 1L : remoteAddedObj);
            long localAdded = tombs.get("add:" + key);
            long effectiveAdded = Math.max(remoteAdded, localAdded);
            long delAt = tombs.get("fav:" + key);
            if (delAt > effectiveAdded) continue;
            tombs.putMax("add:" + key, effectiveAdded);
            if (!favMap.containsKey(key)) {
                favMap.put(key, rf);
            } else {
                Favorites.Entry existing = favMap.get(key);
                if ((existing.poster == null || existing.poster.isEmpty())
                        && rf.poster != null
                        && !rf.poster.isEmpty()) {
                    existing.poster = rf.poster;
                }
            }
        }
        List<Favorites.Entry> mergedFavs = new ArrayList<>(favMap.values());
        if (mergedFavs.size() > Favorites.LIMIT) {
            mergedFavs = new ArrayList<>(mergedFavs.subList(0, Favorites.LIMIT));
        }

        // 3. Merge Public Subscriptions (when opted in)
        List<SubscriptionItem> mergedSubs = null;
        boolean subsChanged = false;
        if (syncSubscriptions) {
            Map<String, SubscriptionItem> subMap = new LinkedHashMap<>();
            List<String> beforeDigest = new ArrayList<>();
            if (localSubscriptions != null) {
                for (SubscriptionItem s : localSubscriptions) {
                    if (s == null || s.key == null || s.key.isEmpty()) continue;
                    beforeDigest.add(subscriptionStateKey(s));
                    long delAt = tombs.get("sub:" + s.key);
                    if (delAt > 0L && delAt >= s.updatedAt) continue;
                    subMap.put(s.key, s);
                }
            }
            for (SubscriptionItem rs : remoteSubs) {
                if (rs == null || rs.key == null || rs.key.isEmpty()) continue;
                long delAt = tombs.get("sub:" + rs.key);
                if (delAt > 0L && delAt >= rs.updatedAt) continue;
                SubscriptionItem cur = subMap.get(rs.key);
                if (cur == null) {
                    subMap.put(rs.key, rs);
                } else {
                    boolean remoteNewer =
                            rs.updatedAt > cur.updatedAt
                                    || (rs.updatedAt == cur.updatedAt
                                            && cur.rawContent.isEmpty()
                                            && !rs.rawContent.isEmpty());
                    if (remoteNewer) {
                        if (rs.rawContent.isEmpty() && !cur.rawContent.isEmpty()) {
                            rs.rawContent = cur.rawContent;
                        }
                        if (rs.groupTag.isEmpty() && !cur.groupTag.isEmpty()) {
                            rs.groupTag = cur.groupTag;
                        }
                        subMap.put(rs.key, rs);
                    } else if (cur.rawContent.isEmpty() && !rs.rawContent.isEmpty()) {
                        cur.rawContent = rs.rawContent;
                    }
                }
            }
            mergedSubs = new ArrayList<>(subMap.values());
            List<String> afterDigest = new ArrayList<>();
            for (SubscriptionItem s : mergedSubs) {
                afterDigest.add(subscriptionStateKey(s));
            }
            subsChanged = !beforeDigest.equals(afterDigest);
        }

        JSONArray outHistArr = new JSONArray();
        for (WatchHistory.Entry e : mergedHist) {
            try {
                outHistArr.put(e.json());
            } catch (JSONException ignored) {
            }
        }
        JSONArray outFavArr = new JSONArray();
        for (Favorites.Entry f : mergedFavs) {
            try {
                outFavArr.put(f.json());
            } catch (JSONException ignored) {
            }
        }

        String nextHistJson = outHistArr.toString();
        String nextFavJson = outFavArr.toString();
        String nextTombJson = tombs.json();
        boolean changed =
                !sameHistory(localHist, mergedHist)
                        || !sameFavorites(localFavs, mergedFavs)
                        || subsChanged;
        String payload =
                exportPayload(
                        nextHistJson,
                        nextFavJson,
                        nextTombJson,
                        mergedSubs,
                        syncSubscriptions,
                        rawRemoteSubsArray,
                        now);
        int subCount =
                syncSubscriptions
                        ? (mergedSubs == null ? 0 : mergedSubs.size())
                        : (localSubscriptions == null ? 0 : localSubscriptions.size());
        return new MergeResult(
                nextHistJson,
                nextFavJson,
                nextTombJson,
                mergedSubs,
                payload,
                mergedHist.size(),
                mergedFavs.size(),
                subCount,
                changed,
                subsChanged);
    }

    private static String subscriptionStateKey(SubscriptionItem s) {
        return s.key
                + "|"
                + s.name
                + "|"
                + s.url
                + "|"
                + s.enabled
                + "|"
                + s.selectedSiteKey
                + "|"
                + (s.rawContent == null ? 0 : s.rawContent.hashCode());
    }

    private static List<WatchHistory.Entry> parseRemoteHistory(JSONArray arr) {
        List<WatchHistory.Entry> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            String site = o.optString("site", o.optString("siteKey", "")).trim();
            String id = o.optString("id", o.optString("vodId", "")).trim();
            if (site.isEmpty() || id.isEmpty() || "live".equals(site)) continue;
            WatchHistory.Entry e = new WatchHistory.Entry();
            e.site = site;
            e.id = id;
            e.title = o.optString("title", "").trim();
            e.poster = o.optString("poster", "");
            e.line = o.optString("line", o.optString("routeName", ""));
            e.episode =
                    o.optString(
                            "episode", o.optString("episodeName", o.optString("episodeTitle", "")));
            e.index = Math.max(0, o.optInt("index", o.optInt("episodeIndex", 0)));
            long pos = o.has("position") ? o.optLong("position", 0L) : o.optLong("positionMs", 0L);
            long dur = o.has("duration") ? o.optLong("duration", 0L) : o.optLong("durationMs", 0L);
            e.position = (int) Math.max(0L, Math.min(Integer.MAX_VALUE, pos));
            e.duration = (int) Math.max(0L, Math.min(Integer.MAX_VALUE, dur));
            e.updated = Math.max(1L, o.optLong("updated", o.optLong("updatedAt", 1L)));
            out.add(e);
        }
        return out;
    }

    private static void parseRemoteFavorites(
            JSONArray arr, List<Favorites.Entry> out, Map<String, Long> addedAtMap) {
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            String site = o.optString("site", o.optString("siteKey", "")).trim();
            String id = o.optString("id", o.optString("vodId", "")).trim();
            if (site.isEmpty() || id.isEmpty()) continue;
            Favorites.Entry f = new Favorites.Entry();
            f.site = site;
            f.id = id;
            f.title = o.optString("title", "").trim();
            f.poster = o.optString("poster", "");
            out.add(f);
            addedAtMap.put(f.key(), Math.max(1L, o.optLong("updated", o.optLong("addedAt", 1L))));
        }
    }

    private static boolean sameHistory(List<WatchHistory.Entry> a, List<WatchHistory.Entry> b) {
        if (a.size() != b.size()) return false;
        for (int i = 0; i < a.size(); i++) {
            WatchHistory.Entry x = a.get(i), y = b.get(i);
            if (!x.key().equals(y.key())
                    || x.position != y.position
                    || x.duration != y.duration
                    || x.updated != y.updated
                    || !String.valueOf(x.episode).equals(String.valueOf(y.episode))
                    || !String.valueOf(x.line).equals(String.valueOf(y.line))) {
                return false;
            }
        }
        return true;
    }

    private static boolean sameFavorites(List<Favorites.Entry> a, List<Favorites.Entry> b) {
        if (a.size() != b.size()) return false;
        for (int i = 0; i < a.size(); i++) {
            if (!a.get(i).key().equals(b.get(i).key())) return false;
        }
        return true;
    }

    /** Normalizes a WebDAV folder or file URL to the exact JSON sync file endpoint. */
    static String resolveWebdavFileUrl(String rawUrl) {
        if (rawUrl == null) throw new IllegalArgumentException("请填写 WebDAV 服务器地址");
        String trimmed = rawUrl.trim();
        if (trimmed.isEmpty()) throw new IllegalArgumentException("请填写 WebDAV 服务器地址");
        if (!trimmed.regionMatches(true, 0, "http://", 0, 7)
                && !trimmed.regionMatches(true, 0, "https://", 0, 8)) {
            trimmed = "https://" + trimmed;
        }
        URI uri = URI.create(trimmed);
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            throw new IllegalArgumentException("仅支持 HTTP 或 HTTPS WebDAV 地址");
        }
        String path = uri.getRawPath() == null ? "" : uri.getRawPath();
        if (path.endsWith(".json")) {
            return trimmed;
        }
        if (!trimmed.endsWith("/")) trimmed = trimmed + "/";
        return trimmed + DEFAULT_FILE;
    }

    /** Normalizes a LAN QR pairing URL or sync URL to the {@code /sync} JSON endpoint. */
    static String resolveLanSyncEndpoint(String rawInput) {
        if (rawInput == null) throw new IllegalArgumentException("请输入对方设备的局域网同步地址");
        String trimmed = rawInput.trim();
        if (trimmed.isEmpty()) throw new IllegalArgumentException("请输入对方设备的局域网同步地址");
        if (!trimmed.regionMatches(true, 0, "http://", 0, 7)
                && !trimmed.regionMatches(true, 0, "https://", 0, 8)) {
            trimmed = "http://" + trimmed;
        }
        while (trimmed.endsWith("/")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        URI uri = URI.create(trimmed);
        String host = uri.getHost();
        if (host == null || host.isEmpty()) {
            throw new IllegalArgumentException("局域网同步地址缺少主机 IP");
        }
        if (trimmed.endsWith("/sync")) return trimmed;
        return trimmed + "/sync";
    }

    static String base64EncodeUtf8(String value) {
        byte[] data = value.getBytes(StandardCharsets.UTF_8);
        StringBuilder sb = new StringBuilder(((data.length + 2) / 3) * 4);
        int i = 0;
        while (i < data.length) {
            int b0 = data[i++] & 0xff;
            int b1 = i < data.length ? data[i++] & 0xff : -1;
            int b2 = i < data.length ? data[i++] & 0xff : -1;
            sb.append(BASE64_ALPHABET[b0 >>> 2]);
            if (b1 < 0) {
                sb.append(BASE64_ALPHABET[(b0 & 0x03) << 4]);
                sb.append("==");
            } else if (b2 < 0) {
                sb.append(BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >>> 4)]);
                sb.append(BASE64_ALPHABET[(b1 & 0x0f) << 2]);
                sb.append('=');
            } else {
                sb.append(BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >>> 4)]);
                sb.append(BASE64_ALPHABET[((b1 & 0x0f) << 2) | (b2 >>> 6)]);
                sb.append(BASE64_ALPHABET[b2 & 0x3f]);
            }
        }
        return sb.toString();
    }

    private static String basicAuthHeader(String user, String pass) {
        String u = user == null ? "" : user;
        String p = pass == null ? "" : pass;
        if (u.isEmpty() && p.isEmpty()) return null;
        return "Basic " + base64EncodeUtf8(u + ":" + p);
    }

    /** Executes a bidirectional WebDAV GET -> merge -> PUT sync cycle. */
    static MergeResult syncWebdav(
            String rawUrl, String username, String password, MergeCallback merger)
            throws Exception {
        String fileUrl = resolveWebdavFileUrl(rawUrl);
        String auth = basicAuthHeader(username, password);

        String remoteJson = null;
        HttpURLConnection getConn = openConnection(fileUrl, "GET", auth, 12000);
        try {
            int code = getConn.getResponseCode();
            if (code >= 200 && code < 300) {
                remoteJson = readBody(getConn.getInputStream(), MAX_SYNC_BYTES);
            } else if (code == 401 || code == 403) {
                throw new IOException("WebDAV 认证失败 (HTTP " + code + ")，请检查账号或应用专用密码");
            } else if (code != 404) {
                throw new IOException("WebDAV 读取失败 (HTTP " + code + ")");
            }
        } finally {
            getConn.disconnect();
        }

        MergeResult merged = merger.merge(remoteJson);
        byte[] payloadBytes = merged.payloadJson.getBytes(StandardCharsets.UTF_8);
        if (payloadBytes.length > MAX_SYNC_BYTES) {
            throw new IOException("同步数据超出 8 MB 大小限制");
        }

        int putCode = putBytes(fileUrl, auth, payloadBytes);
        if (putCode == 404 || putCode == 409) {
            ensureParentCollections(fileUrl, auth);
            putCode = putBytes(fileUrl, auth, payloadBytes);
        }
        if (putCode == 401 || putCode == 403) {
            throw new IOException("WebDAV 写入被拒绝 (HTTP " + putCode + ")，请检查读写权限");
        }
        if (putCode < 200 || putCode >= 300) {
            throw new IOException("WebDAV 写入失败 (HTTP " + putCode + ")");
        }
        return merged;
    }

    /**
     * Executes a bidirectional sync against another Marco Movie device's LAN receiver ({@code POST
     * /configure/<token>/sync}).
     */
    static MergeResult syncLanPeer(String peerUrlOrHost, LanPeerCallback callback)
            throws Exception {
        String endpoint = resolveLanSyncEndpoint(peerUrlOrHost);
        String localJson = callback.exportLocalPayload();
        byte[] outBytes = localJson.getBytes(StandardCharsets.UTF_8);
        if (outBytes.length > MAX_SYNC_BYTES) {
            throw new IOException("本地同步数据超出 8 MB 大小限制");
        }

        HttpURLConnection postConn = openConnection(endpoint, "POST", null, 12000);
        String responseJson;
        try {
            postConn.setDoOutput(true);
            postConn.setFixedLengthStreamingMode(outBytes.length);
            postConn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            try (OutputStream out = postConn.getOutputStream()) {
                out.write(outBytes);
            }
            int code = postConn.getResponseCode();
            if (code == 410) {
                throw new IOException("对方设备的局域网同步会话已过期，请重新打开二维码");
            }
            if (code < 200 || code >= 300) {
                throw new IOException("局域网同步未成功 (HTTP " + code + ")");
            }
            responseJson = readBody(postConn.getInputStream(), MAX_SYNC_BYTES);
        } finally {
            postConn.disconnect();
        }
        return callback.applyMergedPayload(responseJson);
    }

    private static int putBytes(String fileUrl, String auth, byte[] payloadBytes)
            throws IOException {
        HttpURLConnection conn = openConnection(fileUrl, "PUT", auth, 15000);
        try {
            conn.setDoOutput(true);
            conn.setFixedLengthStreamingMode(payloadBytes.length);
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            try (OutputStream out = conn.getOutputStream()) {
                out.write(payloadBytes);
            }
            return conn.getResponseCode();
        } finally {
            conn.disconnect();
        }
    }

    /**
     * Creates missing ancestor WebDAV collections via raw HTTP/1.1 {@code MKCOL}, because standard
     * {@link HttpURLConnection#setRequestMethod(String)} rejects {@code MKCOL}.
     */
    private static void ensureParentCollections(String fileUrl, String auth) {
        try {
            URI uri = new URI(fileUrl);
            String rawPath = uri.getRawPath();
            if (rawPath == null || rawPath.isEmpty()) return;
            int lastSlash = rawPath.lastIndexOf('/');
            if (lastSlash <= 0) return;
            String parentPath = rawPath.substring(0, lastSlash + 1);
            String[] parts = parentPath.split("/");
            StringBuilder current = new StringBuilder("/");
            for (String part : parts) {
                if (part == null || part.isEmpty()) continue;
                current.append(part).append('/');
                sendRawMkcol(uri, current.toString(), auth);
            }
        } catch (Exception ignored) {
        }
    }

    private static void sendRawMkcol(URI baseUri, String rawCollectionPath, String auth) {
        String scheme =
                baseUri.getScheme() == null ? "http" : baseUri.getScheme().toLowerCase(Locale.ROOT);
        boolean https = "https".equals(scheme);
        String host = baseUri.getHost();
        if (host == null || host.isEmpty()) return;
        int port = baseUri.getPort();
        int connectPort = port > 0 ? port : (https ? 443 : 80);
        String hostHeader = (port > 0 && port != (https ? 443 : 80)) ? (host + ":" + port) : host;

        java.net.Socket sock = null;
        try {
            java.net.Socket tcp = new java.net.Socket();
            tcp.connect(new java.net.InetSocketAddress(host, connectPort), 8000);
            tcp.setSoTimeout(8000);
            if (https) {
                javax.net.ssl.SSLSocketFactory sf =
                        (javax.net.ssl.SSLSocketFactory)
                                javax.net.ssl.SSLSocketFactory.getDefault();
                javax.net.ssl.SSLSocket ssl =
                        (javax.net.ssl.SSLSocket) sf.createSocket(tcp, host, connectPort, true);
                ssl.startHandshake();
                if (!javax.net.ssl.HttpsURLConnection.getDefaultHostnameVerifier()
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
            req.append("User-Agent: MarcoMovie-Sync/2.0\r\n");
            if (auth != null && !auth.isEmpty()) {
                req.append("Authorization: ").append(auth).append("\r\n");
            }
            req.append("Content-Length: 0\r\n");
            req.append("Connection: close\r\n\r\n");
            OutputStream os = sock.getOutputStream();
            os.write(req.toString().getBytes(StandardCharsets.UTF_8));
            os.flush();
            InputStream is = sock.getInputStream();
            byte[] buf = new byte[256];
            // Read response status line to let server complete MKCOL cleanly
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

    private static HttpURLConnection openConnection(
            String targetUrl, String method, String auth, int timeoutMs) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(targetUrl).openConnection();
        conn.setInstanceFollowRedirects(false);
        conn.setConnectTimeout(timeoutMs);
        conn.setReadTimeout(timeoutMs);
        conn.setUseCaches(false);
        conn.setRequestMethod(method);
        conn.setRequestProperty("User-Agent", "MarcoMovie-Sync/2.0");
        conn.setRequestProperty("Accept", "application/json");
        if (auth != null && !auth.isEmpty()) {
            conn.setRequestProperty("Authorization", auth);
        }
        return conn;
    }

    private static String readBody(InputStream in, int maxBytes) throws IOException {
        if (in == null) return "";
        try (InputStream src = in;
                ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = src.read(buf)) != -1) {
                if (bos.size() + n > maxBytes) {
                    throw new IOException("远端同步文件超出大小限制");
                }
                bos.write(buf, 0, n);
            }
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}

package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.WeakHashMap;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * TV-owned persistent multi-subscription manager with deterministic, order-independent stable site
 * identities.
 *
 * <p>Solves cross-source site-key drift when multiple subscriptions contain colliding site keys or
 * names (e.g., two subscriptions both defining {@code key="same"}). Each subscription owns a
 * permanent {@code id}; every emitted site receives {@code rawKey + "::" + shortId(sub.id)}, so
 * enabling, disabling, reordering, restarting, or refreshing subscriptions never mutates another
 * subscription's site keys or corrupts WatchHistory / Favorites targets.
 */
final class TvMultiSourceStore {
    static final int SCHEMA_VERSION = 1;
    static final String STATE_FILENAME = "tv_multi_source_v1.json";
    static final String KEY_SEPARATOR = "::";
    static final String MULTI_TV_ORIGIN_PREFIX = "marco-tv-multi://";

    private static final Object LOCK = new Object();
    private static final Set<Cms.Config> EFFECTIVE_RUNTIME_CONFIGS =
            Collections.newSetFromMap(new WeakHashMap<Cms.Config, Boolean>());
    private static final WeakHashMap<Cms.Site, Set<String>> SITE_TRUSTED_ALIASES =
            new WeakHashMap<Cms.Site, Set<String>>();

    static void markEffectiveRuntimeConfig(Cms.Config cfg) {
        if (cfg == null) return;
        synchronized (EFFECTIVE_RUNTIME_CONFIGS) {
            EFFECTIVE_RUNTIME_CONFIGS.add(cfg);
        }
    }

    static boolean hasDerivedRuntimeSiteKeys(Cms.Config cfg) {
        if (cfg == null || cfg.sites == null) return false;
        for (Cms.Site s : cfg.sites) {
            if (s != null && isStableScopedKey(s.key)) return true;
        }
        return false;
    }

    static boolean rawJsonHasDerivedRuntimeSiteKeys(String raw) {
        return ConfigLibrary.rawJsonHasDerivedRuntimeSiteKeys(raw);
    }

    static boolean isEffectiveRuntimeConfig(Cms.Config cfg, String origin) {
        if (cfg != null) {
            synchronized (EFFECTIVE_RUNTIME_CONFIGS) {
                if (EFFECTIVE_RUNTIME_CONFIGS.contains(cfg)) return true;
            }
            if (hasDerivedRuntimeSiteKeys(cfg)) return true;
            if (cfg.raw != null && rawJsonHasDerivedRuntimeSiteKeys(cfg.raw)) return true;
        }
        return origin != null && origin.startsWith(MULTI_TV_ORIGIN_PREFIX);
    }

    static String stripOwnStableSuffix(String subscriptionId, String key) {
        String clean = key == null ? "" : key.trim();
        if (clean.isEmpty() || subscriptionId == null || subscriptionId.isEmpty()) return clean;
        String suffix = KEY_SEPARATOR + stableShortId(subscriptionId);
        while (clean.endsWith(suffix) && clean.length() > suffix.length()) {
            clean = clean.substring(0, clean.length() - suffix.length());
        }
        return clean;
    }

    static void attachTrustedSiteAliases(Cms.Site site, Set<String> aliases) {
        if (site == null || aliases == null || aliases.isEmpty()) return;
        synchronized (SITE_TRUSTED_ALIASES) {
            SITE_TRUSTED_ALIASES.put(
                    site, Collections.unmodifiableSet(new LinkedHashSet<>(aliases)));
        }
    }

    static boolean siteMatchesHistoryKey(Cms.Site activeSite, String storedSiteKey) {
        return siteMatchesHistoryKey(null, activeSite, storedSiteKey);
    }

    static boolean siteMatchesHistoryKey(
            MainActivity a, Cms.Site activeSite, String storedSiteKey) {
        if (activeSite == null || activeSite.key == null || activeSite.key.isEmpty()) return false;
        if (storedSiteKey == null || storedSiteKey.trim().isEmpty()) return false;
        String stored = storedSiteKey.trim();
        if (activeSite.key.equals(stored)) return true;
        synchronized (SITE_TRUSTED_ALIASES) {
            Set<String> aliases = SITE_TRUSTED_ALIASES.get(activeSite);
            if (aliases != null && aliases.contains(stored)) {
                return true;
            }
        }
        if (a != null && a.multiSourceStore != null && a.configStore != null && !a.privateMode) {
            try {
                TvMultiSourceStore.State msState = a.multiSourceStore.readState();
                if (msState.initialized) {
                    ConfigLibrary lib = new ConfigLibrary(a.configStore.directory);
                    SiteResolution res =
                            a.multiSourceStore.resolveStoredSiteKey(stored, a.config, lib);
                    if (res.status != SiteResolution.STATUS_AMBIGUOUS
                            && res.status != SiteResolution.STATUS_MISSING
                            && activeSite.key.equals(res.stableSiteKey)) {
                        return true;
                    }
                }
            } catch (Throwable ignored) {
            }
        }
        return false;
    }

    static final class SubscriptionRecord {
        String id = "";
        String libraryEntryId = "";
        String name = "";
        String origin = "";
        boolean enabled;
        final LinkedHashSet<String> disabledSiteKeys = new LinkedHashSet<>();
        String lastError = "";
        long lastUpdated = 1L;
        int totalSiteCount;
        int loadedSiteCount;

        SubscriptionRecord copy() {
            SubscriptionRecord c = new SubscriptionRecord();
            c.id = id;
            c.libraryEntryId = libraryEntryId;
            c.name = name;
            c.origin = origin;
            c.enabled = enabled;
            c.disabledSiteKeys.addAll(disabledSiteKeys);
            c.lastError = lastError;
            c.lastUpdated = lastUpdated;
            c.totalSiteCount = totalSiteCount;
            c.loadedSiteCount = loadedSiteCount;
            return c;
        }

        JSONObject toJson() throws Exception {
            JSONArray disabledArr = new JSONArray();
            for (String k : disabledSiteKeys) {
                if (k != null && !k.isEmpty()) disabledArr.put(k);
            }
            return new JSONObject()
                    .put("id", id)
                    .put("libraryEntryId", libraryEntryId)
                    .put("name", name)
                    .put("origin", origin)
                    .put("enabled", enabled)
                    .put("disabledSiteKeys", disabledArr)
                    .put("lastError", lastError == null ? "" : lastError)
                    .put("lastUpdated", Math.max(1L, lastUpdated))
                    .put("totalSiteCount", Math.max(0, totalSiteCount))
                    .put("loadedSiteCount", Math.max(0, loadedSiteCount));
        }

        static SubscriptionRecord fromJson(JSONObject obj) {
            SubscriptionRecord r = new SubscriptionRecord();
            r.id = obj.optString("id", "").trim();
            r.libraryEntryId = obj.optString("libraryEntryId", "").trim();
            r.name = obj.optString("name", "").trim();
            r.origin = obj.optString("origin", "").trim();
            r.enabled = obj.optBoolean("enabled", false);
            r.lastError = obj.optString("lastError", "").trim();
            r.lastUpdated = Math.max(1L, obj.optLong("lastUpdated", 1L));
            r.totalSiteCount = Math.max(0, obj.optInt("totalSiteCount", 0));
            r.loadedSiteCount = Math.max(0, obj.optInt("loadedSiteCount", 0));
            JSONArray arr = obj.optJSONArray("disabledSiteKeys");
            if (arr != null) {
                for (int i = 0; i < arr.length(); i++) {
                    String k = arr.optString(i, "").trim();
                    if (!k.isEmpty()) r.disabledSiteKeys.add(k);
                }
            }
            return r;
        }
    }

    static final class AliasTarget {
        final String subscriptionId;
        final String rawSiteKey;
        final String stableSiteKey;

        AliasTarget(String subscriptionId, String rawSiteKey, String stableSiteKey) {
            this.subscriptionId = subscriptionId == null ? "" : subscriptionId;
            this.rawSiteKey = rawSiteKey == null ? "" : rawSiteKey;
            this.stableSiteKey = stableSiteKey == null ? "" : stableSiteKey;
        }

        JSONObject toJson() throws Exception {
            return new JSONObject()
                    .put("subscriptionId", subscriptionId)
                    .put("rawSiteKey", rawSiteKey)
                    .put("stableSiteKey", stableSiteKey);
        }

        static AliasTarget fromJson(JSONObject o) {
            if (o == null) return null;
            String subId = o.optString("subscriptionId", "").trim();
            String raw = o.optString("rawSiteKey", "").trim();
            String stable = o.optString("stableSiteKey", "").trim();
            if (subId.isEmpty() || raw.isEmpty()) return null;
            if (stable.isEmpty()) stable = stableSiteKey(subId, raw);
            return new AliasTarget(subId, raw, stable);
        }
    }

    static final class State {
        int version = SCHEMA_VERSION;
        boolean initialized;
        long revision = 1L;
        String currentSubscriptionId = "";
        String currentRawSiteKey = "";
        String currentStableSiteKey = "";
        final List<SubscriptionRecord> subscriptions = new ArrayList<>();
        final LinkedHashMap<String, AliasTarget> legacyAliases = new LinkedHashMap<>();

        State copy() {
            State s = new State();
            s.version = version;
            s.initialized = initialized;
            s.revision = revision;
            s.currentSubscriptionId = currentSubscriptionId;
            s.currentRawSiteKey = currentRawSiteKey;
            s.currentStableSiteKey = currentStableSiteKey;
            for (SubscriptionRecord r : subscriptions) s.subscriptions.add(r.copy());
            s.legacyAliases.putAll(legacyAliases);
            return s;
        }

        int enabledCount() {
            int n = 0;
            for (SubscriptionRecord r : subscriptions) if (r.enabled) n++;
            return n;
        }

        SubscriptionRecord findById(String id) {
            if (id == null || id.isEmpty()) return null;
            for (SubscriptionRecord r : subscriptions) {
                if (id.equals(r.id)) return r;
            }
            return null;
        }

        SubscriptionRecord findByOrigin(String origin) {
            if (origin == null || origin.trim().isEmpty()) return null;
            String clean = origin.trim();
            for (SubscriptionRecord r : subscriptions) {
                if (clean.equals(r.origin)) return r;
            }
            return null;
        }

        SubscriptionRecord findByLibraryEntryId(String entryId) {
            if (entryId == null || entryId.isEmpty()) return null;
            for (SubscriptionRecord r : subscriptions) {
                if (entryId.equals(r.libraryEntryId)) return r;
            }
            return null;
        }

        JSONObject toJson() throws Exception {
            JSONArray subs = new JSONArray();
            for (SubscriptionRecord r : subscriptions) subs.put(r.toJson());
            JSONObject aliases = new JSONObject();
            for (Map.Entry<String, AliasTarget> e : legacyAliases.entrySet()) {
                if (e.getKey() != null && !e.getKey().isEmpty() && e.getValue() != null) {
                    aliases.put(e.getKey(), e.getValue().toJson());
                }
            }
            return new JSONObject()
                    .put("version", version)
                    .put("initialized", initialized)
                    .put("revision", revision)
                    .put(
                            "currentSubscriptionId",
                            currentSubscriptionId == null ? "" : currentSubscriptionId)
                    .put("currentRawSiteKey", currentRawSiteKey == null ? "" : currentRawSiteKey)
                    .put(
                            "currentStableSiteKey",
                            currentStableSiteKey == null ? "" : currentStableSiteKey)
                    .put("subscriptions", subs)
                    .put("legacyAliases", aliases);
        }

        static State fromJson(JSONObject obj) {
            State s = new State();
            if (obj == null) return s;
            s.version = obj.optInt("version", SCHEMA_VERSION);
            s.initialized = obj.optBoolean("initialized", false);
            s.revision = Math.max(1L, obj.optLong("revision", 1L));
            s.currentSubscriptionId = obj.optString("currentSubscriptionId", "").trim();
            s.currentRawSiteKey = obj.optString("currentRawSiteKey", "").trim();
            s.currentStableSiteKey = obj.optString("currentStableSiteKey", "").trim();
            JSONArray subs = obj.optJSONArray("subscriptions");
            if (subs != null) {
                for (int i = 0; i < subs.length(); i++) {
                    JSONObject item = subs.optJSONObject(i);
                    if (item == null) continue;
                    SubscriptionRecord r = SubscriptionRecord.fromJson(item);
                    if (!r.id.isEmpty()) s.subscriptions.add(r);
                }
            }
            JSONObject aliases = obj.optJSONObject("legacyAliases");
            if (aliases != null) {
                Iterator<String> it = aliases.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    AliasTarget t = AliasTarget.fromJson(aliases.optJSONObject(k));
                    if (k != null && !k.isEmpty() && t != null) {
                        s.legacyAliases.put(k, t);
                    }
                }
            }
            return s;
        }
    }

    static final class EffectiveBuild {
        final Cms.Config config;
        final String effectiveOrigin;
        final String resolvedCurrentSiteKey;
        final String resolvedCurrentSubscriptionId;
        final int enabledSubscriptionCount;
        final int totalSubscriptionCount;
        final long revision;
        final boolean stale;
        final Map<String, String> stableKeyToSubscriptionId;
        final Map<String, String> stableKeyToRawKey;

        EffectiveBuild(
                Cms.Config config,
                String effectiveOrigin,
                String resolvedCurrentSiteKey,
                String resolvedCurrentSubscriptionId,
                int enabledSubscriptionCount,
                int totalSubscriptionCount,
                long revision,
                Map<String, String> stableKeyToSubscriptionId,
                Map<String, String> stableKeyToRawKey) {
            this(
                    config,
                    effectiveOrigin,
                    resolvedCurrentSiteKey,
                    resolvedCurrentSubscriptionId,
                    enabledSubscriptionCount,
                    totalSubscriptionCount,
                    revision,
                    false,
                    stableKeyToSubscriptionId,
                    stableKeyToRawKey);
        }

        EffectiveBuild(
                Cms.Config config,
                String effectiveOrigin,
                String resolvedCurrentSiteKey,
                String resolvedCurrentSubscriptionId,
                int enabledSubscriptionCount,
                int totalSubscriptionCount,
                long revision,
                boolean stale,
                Map<String, String> stableKeyToSubscriptionId,
                Map<String, String> stableKeyToRawKey) {
            this.config = config;
            this.effectiveOrigin = effectiveOrigin == null ? "" : effectiveOrigin;
            this.resolvedCurrentSiteKey =
                    resolvedCurrentSiteKey == null ? "" : resolvedCurrentSiteKey;
            this.resolvedCurrentSubscriptionId =
                    resolvedCurrentSubscriptionId == null ? "" : resolvedCurrentSubscriptionId;
            this.enabledSubscriptionCount = enabledSubscriptionCount;
            this.totalSubscriptionCount = totalSubscriptionCount;
            this.revision = revision;
            this.stale = stale;
            this.stableKeyToSubscriptionId =
                    Collections.unmodifiableMap(new LinkedHashMap<>(stableKeyToSubscriptionId));
            this.stableKeyToRawKey =
                    Collections.unmodifiableMap(new LinkedHashMap<>(stableKeyToRawKey));
        }
    }

    static final class SiteResolution {
        static final int STATUS_ENABLED = 0;
        static final int STATUS_DISABLED_SUBSCRIPTION = 1;
        static final int STATUS_DISABLED_SITE = 2;
        static final int STATUS_AMBIGUOUS = 3;
        static final int STATUS_MISSING = 4;

        static final class Candidate {
            final SubscriptionRecord subscription;
            final String rawSiteKey;
            final String stableSiteKey;
            final String siteName;
            final boolean siteDisabled;

            Candidate(
                    SubscriptionRecord subscription,
                    String rawSiteKey,
                    String stableSiteKey,
                    String siteName,
                    boolean siteDisabled) {
                this.subscription = subscription;
                this.rawSiteKey = rawSiteKey;
                this.stableSiteKey = stableSiteKey;
                this.siteName = siteName;
                this.siteDisabled = siteDisabled;
            }
        }

        final int status;
        final Cms.Site activeSite;
        final SubscriptionRecord subscription;
        final String rawSiteKey;
        final String stableSiteKey;
        final String siteName;
        final List<Candidate> candidates;

        SiteResolution(
                int status,
                Cms.Site activeSite,
                SubscriptionRecord subscription,
                String rawSiteKey,
                String stableSiteKey,
                String siteName,
                List<Candidate> candidates) {
            this.status = status;
            this.activeSite = activeSite;
            this.subscription = subscription;
            this.rawSiteKey = rawSiteKey == null ? "" : rawSiteKey;
            this.stableSiteKey = stableSiteKey == null ? "" : stableSiteKey;
            this.siteName = siteName == null ? "" : siteName;
            this.candidates =
                    candidates == null
                            ? Collections.emptyList()
                            : Collections.unmodifiableList(new ArrayList<>(candidates));
        }
    }

    interface SiteAvailability {
        boolean isAvailable(Cms.Config config, Cms.Site site);
    }

    final File directory;
    final File stateFile;
    private State cachedState;

    TvMultiSourceStore(File configDirectory) {
        this.directory = new File(configDirectory, "subscriptions");
        this.stateFile = new File(directory, STATE_FILENAME);
    }

    /** Deterministic 8-hex-char subscription prefix derived ONLY from permanent subscription ID. */
    static String stableShortId(String subscriptionId) {
        String clean = subscriptionId == null ? "" : subscriptionId.trim().toLowerCase(Locale.ROOT);
        if (clean.length() >= 8 && clean.substring(0, 8).matches("[0-9a-f]{8}")) {
            return clean.substring(0, 8);
        }
        try {
            return ConfigLibrary.hash("sub:" + clean).substring(0, 8);
        } catch (Exception e) {
            return String.format(Locale.ROOT, "%08x", clean.hashCode());
        }
    }

    /**
     * Order-independent, sibling-independent deterministic site key.
     *
     * <p>Disabling A never changes B's key, and swapping [A, B] -> [B, A] never changes either key.
     */
    static String stableSiteKey(String subscriptionId, String rawSiteKey) {
        String raw = rawSiteKey == null ? "" : rawSiteKey.trim();
        if (raw.isEmpty()) raw = "site";
        String suffix = KEY_SEPARATOR + stableShortId(subscriptionId);
        if (raw.endsWith(suffix)) return raw;
        return raw + suffix;
    }

    static boolean isStableScopedKey(String key) {
        if (key == null) return false;
        int idx = key.lastIndexOf(KEY_SEPARATOR);
        if (idx <= 0 || idx + KEY_SEPARATOR.length() + 8 != key.length()) return false;
        String tail = key.substring(idx + KEY_SEPARATOR.length());
        return tail.matches("[0-9a-f]{8}");
    }

    static String extractRawKeyFromStable(String key) {
        if (!isStableScopedKey(key)) return key == null ? "" : key;
        return key.substring(0, key.lastIndexOf(KEY_SEPARATOR));
    }

    static String extractShortSubIdFromStable(String key) {
        if (!isStableScopedKey(key)) return "";
        return key.substring(key.lastIndexOf(KEY_SEPARATOR) + KEY_SEPARATOR.length());
    }

    static String newPermanentId(String origin, String raw) throws Exception {
        String cleanOrigin = origin == null ? "" : origin.trim();
        if (!cleanOrigin.isEmpty() && !SubscriptionManager.isMergedOrigin(cleanOrigin)) {
            return ConfigLibrary.hash("url:" + cleanOrigin);
        }
        // Local URL-less subscription receives a one-time permanent ID that never changes on edit.
        return ConfigLibrary.hash(
                "local-sub:"
                        + UUID.randomUUID().toString()
                        + ":"
                        + ConfigLibrary.hash(raw == null ? "" : raw));
    }

    private final Map<String, String> recoveryHints =
            new java.util.concurrent.ConcurrentHashMap<>();

    String recoveryHintFor(String subId) {
        if (subId == null || subId.isEmpty()) return "";
        String hint = recoveryHints.get(subId);
        return hint == null ? "" : hint;
    }

    void invalidateCache() {
        synchronized (LOCK) {
            cachedState = null;
        }
    }

    State readState() {
        File configDir = directory.getParentFile();
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(configDir);
        if (ConfigLibrary.isRestoreActiveInProcess(configDir)) {
            File f =
                    ConfigLibrary.resolveLiveOrOldSnapshotForRead(
                            configDir, stateFile, "old-state.json", true);
            if (f == null || !f.exists()) return new State();
            try {
                return State.fromJson(new JSONObject(readText(f, 2 * 1024 * 1024)));
            } catch (Throwable ignored) {
                return new State();
            }
        }
        synchronized (LOCK) {
            if (cachedState != null) return cachedState.copy();
            File f = stateFile;
            if (!f.exists() && new File(directory, STATE_FILENAME + ".bak").exists()) {
                f = new File(directory, STATE_FILENAME + ".bak");
            }
            if (!f.exists()) {
                cachedState = new State();
                return cachedState.copy();
            }
            try {
                String raw = readText(f, 2 * 1024 * 1024);
                cachedState = State.fromJson(new JSONObject(raw));
                return cachedState.copy();
            } catch (Throwable ignored) {
                cachedState = new State();
                return cachedState.copy();
            }
        }
    }

    long currentRevision() {
        return readState().revision;
    }

    void saveState(State next) throws IOException {
        synchronized (LOCK) {
            if (next == null) throw new IOException("多源状态为空");
            State copy = next.copy();
            if (cachedState != null && copy.revision < cachedState.revision) {
                // Monotonic revision invariant: never allow an older snapshot to regress disk
                // state.
                return;
            }
            copy.version = SCHEMA_VERSION;
            String encoded;
            try {
                encoded = copy.toJson().toString();
            } catch (Exception e) {
                throw new IOException("序列化多源状态失败: " + e.getMessage(), e);
            }
            writeAtomic(stateFile, encoded);
            cachedState = copy;
        }
    }

    /** Exports current multi-source state for backup archives (preserving enabled/disabled switches). */
    JSONObject exportStateJson() {
        try {
            return exportStateJsonStrict();
        } catch (Throwable ignored) {
            return null;
        }
    }

    /**
     * Strict export for backup creation: throws when the persisted state file is unreadable or
     * malformed rather than silently omitting multi-source state from a backup.
     */
    JSONObject exportStateJsonStrict() throws Exception {
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(directory.getParentFile());
        synchronized (LOCK) {
            File f = stateFile;
            if (!f.exists() && new File(directory, STATE_FILENAME + ".bak").exists()) {
                f = new File(directory, STATE_FILENAME + ".bak");
            }
            if (!f.exists()) {
                return (cachedState != null && cachedState.initialized)
                        ? cachedState.toJson()
                        : null;
            }
            String raw = readText(f, 2 * 1024 * 1024);
            JSONObject obj = new JSONObject(raw);
            State validated = validateBackupStateJson(obj);
            cachedState = validated;
            return validated.initialized ? validated.toJson() : null;
        }
    }

    /**
     * Strictly validates a serialized {@code tv_multi_source_state} object, rejecting missing or
     * duplicate subscription IDs and malformed entries instead of silently dropping records.
     */
    static State validateBackupStateJson(JSONObject stateJson) throws IOException {
        if (stateJson == null) throw new IOException("备份中的多源状态为空");
        boolean initialized = stateJson.optBoolean("initialized", false);
        State parsed = State.fromJson(stateJson);
        if (!initialized) return parsed;
        if (!stateJson.has("subscriptions") || stateJson.isNull("subscriptions")) {
            throw new IOException("备份中的多源订阅列表缺失");
        }
        Object rawSubsObj = stateJson.opt("subscriptions");
        if (!(rawSubsObj instanceof JSONArray)) {
            throw new IOException("备份中的多源订阅列表格式无效");
        }
        JSONArray rawSubs = (JSONArray) rawSubsObj;
        Set<String> seenIds = new HashSet<>();
        for (int i = 0; i < rawSubs.length(); i++) {
            JSONObject item = rawSubs.optJSONObject(i);
            if (item == null) {
                throw new IOException("备份中的第 " + (i + 1) + " 条订阅状态无效");
            }
            String id = item.optString("id", "").trim();
            if (id.isEmpty()) {
                throw new IOException("备份中的第 " + (i + 1) + " 条订阅状态缺少 ID");
            }
            if (!seenIds.add(id)) {
                throw new IOException("备份中的订阅状态存在重复 ID：" + id);
            }
            if (item.has("disabledSiteKeys") && !item.isNull("disabledSiteKeys")) {
                Object disabledObj = item.opt("disabledSiteKeys");
                if (!(disabledObj instanceof JSONArray)) {
                    throw new IOException("备份中的线路开关格式无效：" + id);
                }
                JSONArray disabledArr = (JSONArray) disabledObj;
                for (int j = 0; j < disabledArr.length(); j++) {
                    Object k = disabledArr.opt(j);
                    if (!(k instanceof String) || ((String) k).trim().isEmpty()) {
                        throw new IOException("备份中的线路开关包含无效项：" + id);
                    }
                }
            }
        }
        if (parsed.subscriptions.size() != rawSubs.length()) {
            throw new IOException("备份中的多源订阅记录不完整");
        }
        return parsed;
    }

    /** Prepares validated restored state against staged library entries WITHOUT mutating disk. */
    State prepareBackupRestore(List<ConfigLibrary.Entry> stagedEntries, JSONObject stateJson)
            throws Exception {
        synchronized (LOCK) {
            State restored = validateBackupStateJson(stateJson);
            if (!restored.initialized) return readState();
            State current = readState();
            List<ConfigLibrary.Entry> libEntries =
                    stagedEntries != null ? stagedEntries : Collections.emptyList();
            for (SubscriptionRecord r : restored.subscriptions) {
                ConfigLibrary.Entry entry = findLibraryEntry(libEntries, r);
                if (entry == null) {
                    throw new IOException("备份中的多源订阅缺少对应正文：" + (r.name.isEmpty() ? r.id : r.name));
                }
                r.libraryEntryId = entry.id;
            }
            restored.version = SCHEMA_VERSION;
            restored.revision = Math.max(restored.revision, current.revision + 1L);
            restored.initialized = true;
            return restored;
        }
    }

    /** Restores multi-source state from a backup archive after ConfigLibrary entries are restored. */
    State restoreFromBackup(ConfigLibrary library, JSONObject stateJson) throws Exception {
        synchronized (LOCK) {
            State restored = validateBackupStateJson(stateJson);
            if (!restored.initialized) return readState();
            State current = readState();
            List<ConfigLibrary.Entry> libEntries =
                    library != null ? library.entries() : Collections.emptyList();
            for (SubscriptionRecord r : restored.subscriptions) {
                ConfigLibrary.Entry entry = findLibraryEntry(libEntries, r);
                if (entry != null) {
                    r.libraryEntryId = entry.id;
                }
            }
            restored.revision = Math.max(restored.revision, current.revision + 1L);
            restored.initialized = true;
            saveState(restored);
            return restored.copy();
        }
    }

    private static String canonicalJsonValue(Object value) {
        if (value == null || value == JSONObject.NULL) return "null";
        if (value instanceof JSONObject) {
            JSONObject obj = (JSONObject) value;
            java.util.TreeSet<String> keys = new java.util.TreeSet<>();
            java.util.Iterator<String> it = obj.keys();
            while (it.hasNext()) keys.add(it.next());
            StringBuilder sb = new StringBuilder("{");
            boolean first = true;
            for (String k : keys) {
                if (!first) sb.append(',');
                first = false;
                sb.append(JSONObject.quote(k)).append(':').append(canonicalJsonValue(obj.opt(k)));
            }
            sb.append('}');
            return sb.toString();
        }
        if (value instanceof JSONArray) {
            JSONArray arr = (JSONArray) value;
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < arr.length(); i++) {
                if (i > 0) sb.append(',');
                sb.append(canonicalJsonValue(arr.opt(i)));
            }
            sb.append(']');
            return sb.toString();
        }
        if (value instanceof String) {
            return JSONObject.quote((String) value);
        }
        return String.valueOf(value);
    }

    private static Object resolveRelativeJsonExtFields(JSONObject obj, String origin) {
        if (origin == null || origin.trim().isEmpty()) return obj;
        try {
            JSONObject copy = new JSONObject(obj.toString());
            for (String field : new String[] {"json", "url", "rule"}) {
                String val = Cms.optSafeString(copy, field, null);
                if (val != null) val = val.trim();
                if (val != null && (val.startsWith("./") || val.startsWith("../"))) {
                    copy.put(field, Cms.resolve(origin, val));
                }
            }
            return copy;
        } catch (Throwable ignored) {
            return obj;
        }
    }

    /**
     * Produces an engine-accurate canonical signature for {@code site.ext}, strictly matching
     * {@link Cms#parseConfig} (resolving only untrimmed explicit {@code ./} and {@code ../}
     * relative paths against {@code origin}, never trimming before prefix checks) and {@link
     * HttpT4Engine} (fetching remote HTTP URLs vs. sending trimmed inline extensions via GET when
     * {@code length <= 1000} and POST when {@code length > 1000}).
     */
    private static String canonicalExtSignature(
            Object ext, String origin, int type, boolean alreadyParsedByCms) {
        if (ext == null || ext == JSONObject.NULL) {
            return "";
        }
        Object effectiveExt = ext;
        if (!alreadyParsedByCms) {
            if (ext instanceof String) {
                String rawStr = (String) ext;
                if ("null".equalsIgnoreCase(rawStr.trim())) {
                    return "";
                }
                if (origin != null
                        && !origin.isEmpty()
                        && (rawStr.startsWith("./") || rawStr.startsWith("../"))) {
                    try {
                        String resolved = Cms.resolve(origin, rawStr);
                        if (resolved != null && !resolved.isEmpty()) {
                            effectiveExt = resolved;
                        }
                    } catch (Throwable ignored) {
                    }
                }
            } else if (ext instanceof JSONObject) {
                effectiveExt = resolveRelativeJsonExtFields((JSONObject) ext, origin);
            }
        }
        String rawValue = effectiveExt.toString();
        if (Cms.isHttp(rawValue)) {
            return "remote:" + rawValue.trim();
        }
        String trimmed = rawValue.trim();
        if (trimmed.isEmpty() || "null".equalsIgnoreCase(trimmed)) {
            return "";
        }
        String transport = (type == 4) ? (trimmed.length() > 1000 ? "post:" : "get:") : "";
        if (effectiveExt instanceof JSONObject || effectiveExt instanceof JSONArray) {
            return transport + "json:" + canonicalJsonValue(effectiveExt);
        }
        if (trimmed.startsWith("{")) {
            try {
                return transport + "json:" + canonicalJsonValue(new JSONObject(trimmed));
            } catch (Throwable ignored) {
            }
        } else if (trimmed.startsWith("[")) {
            try {
                return transport + "json:" + canonicalJsonValue(new JSONArray(trimmed));
            } catch (Throwable ignored) {
            }
        }
        return transport + "literal:" + trimmed;
    }

    private static String canonicalHeadersSignature(Cms.Site parsed, JSONObject rawObj, int type) {
        java.util.TreeMap<String, String> normalized = new java.util.TreeMap<>();
        if (parsed != null && parsed.headers != null && !parsed.headers.isEmpty()) {
            for (Map.Entry<String, String> e : parsed.headers.entrySet()) {
                if (e.getKey() == null || e.getValue() == null) continue;
                String k = e.getKey().trim().toLowerCase(Locale.ROOT);
                String v = e.getValue().trim();
                if (!k.isEmpty() && !v.isEmpty()) {
                    normalized.put(k, v);
                }
            }
        } else {
            normalized.put("user-agent", Cms.USER_AGENT);
            if (rawObj != null) {
                for (String field : new String[] {"header", "headers"}) {
                    Object hObj = rawObj.isNull(field) ? null : rawObj.opt(field);
                    if (hObj instanceof JSONObject) {
                        JSONObject jo = (JSONObject) hObj;
                        Iterator<String> it = jo.keys();
                        while (it.hasNext()) {
                            String k = it.next();
                            String v = Cms.optSafeString(jo, k, "").trim();
                            if (v.isEmpty() || v.contains("\r") || v.contains("\n")) continue;
                            String lk = k.trim().toLowerCase(Locale.ROOT);
                            if (lk.equals("user-agent")
                                    || lk.equals("referer")
                                    || (type == 4
                                            && k.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+")
                                            && !lk.equals("content-length")
                                            && !lk.equals("transfer-encoding")
                                            && !lk.equals("connection"))) {
                                normalized.put(lk, v);
                            }
                        }
                    }
                }
                String ua = Cms.optSafeString(rawObj, "ua", "").trim();
                if (!ua.isEmpty() && !ua.contains("\r") && !ua.contains("\n")) {
                    normalized.put("user-agent", ua);
                }
            }
        }
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : normalized.entrySet()) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(e.getKey()).append('=').append(e.getValue());
        }
        return sb.toString();
    }

    private static final class SiteRouteSignature {
        final String rawKey;
        final int type;
        final String rawApi;
        final String resolvedApi;
        final String extSig;
        final String canonicalHeaders;
        final String effectiveJar;
        final boolean searchable;

        SiteRouteSignature(
                String rawKey,
                int type,
                String rawApi,
                String resolvedApi,
                String extSig,
                String canonicalHeaders,
                String effectiveJar,
                boolean searchable) {
            this.rawKey = rawKey == null ? "" : rawKey;
            this.type = type;
            this.rawApi = rawApi == null ? "" : rawApi;
            this.resolvedApi = resolvedApi == null ? "" : resolvedApi;
            this.extSig = extSig == null ? "" : extSig;
            this.canonicalHeaders = canonicalHeaders == null ? "" : canonicalHeaders;
            this.effectiveJar = effectiveJar == null ? "" : effectiveJar;
            this.searchable = searchable;
        }

        boolean matches(SiteRouteSignature cand) {
            if (cand == null) return false;
            if (!rawKey.equals(cand.rawKey)) return false;
            if (type != cand.type) return false;
            if (searchable != cand.searchable) return false;
            boolean hasExpectedApi = !rawApi.isEmpty() || !resolvedApi.isEmpty();
            if (hasExpectedApi) {
                boolean apiHit =
                        (!rawApi.isEmpty()
                                        && (rawApi.equals(cand.rawApi)
                                                || rawApi.equals(cand.resolvedApi)))
                                || (!resolvedApi.isEmpty()
                                        && (resolvedApi.equals(cand.rawApi)
                                                || resolvedApi.equals(cand.resolvedApi)));
                if (!apiHit) return false;
            }
            if (!extSig.equals(cand.extSig)) return false;
            if (!canonicalHeaders.equals(cand.canonicalHeaders)) return false;
            if (type == 3
                    && (!effectiveJar.isEmpty() || !cand.effectiveJar.isEmpty())
                    && !effectiveJar.equals(cand.effectiveJar)) {
                return false;
            }
            return true;
        }
    }

    private static List<SiteRouteSignature> extractSiteRoutes(
            String subId, String rawJson, String origin) {
        List<SiteRouteSignature> out = new ArrayList<>();
        Map<String, Cms.Site> parsedByKey = new LinkedHashMap<>();
        String configSpider = "";
        try {
            Cms.Config parsed = Cms.parseConfig(rawJson, origin);
            configSpider = parsed.spider == null ? "" : parsed.spider.trim();
            for (Cms.Site s : parsed.sites) {
                if (s == null || s.key == null || s.key.isEmpty()) continue;
                String rk = stripOwnStableSuffix(subId, s.key).trim();
                if (!rk.isEmpty()
                        && !"live-only-placeholder".equals(rk)
                        && !"csp_LivePlaceholder".equals(s.api)) {
                    parsedByKey.put(rk, s);
                }
            }
        } catch (Throwable ignored) {
        }
        Set<String> emittedKeys = new HashSet<>();
        try {
            JSONObject root = parseRootOrEmpty(rawJson);
            if (configSpider.isEmpty()) {
                configSpider = Cms.optSafeString(root, "spider", "").trim();
            }
            JSONArray sites = root.optJSONArray("sites");
            if (sites != null) {
                for (int i = 0; i < sites.length(); i++) {
                    JSONObject o = sites.optJSONObject(i);
                    if (o == null) continue;
                    String rk = stripOwnStableSuffix(subId, o.optString("key", "")).trim();
                    String rawApi = Cms.optSafeString(o, "api", "").trim();
                    if (rk.isEmpty()
                            || "live-only-placeholder".equals(rk)
                            || "csp_LivePlaceholder".equals(rawApi)) {
                        continue;
                    }
                    Cms.Site parsed = parsedByKey.get(rk);
                    int type = parsed != null ? parsed.type : o.optInt("type", 0);
                    String resolvedApi =
                            parsed != null && parsed.api != null && !parsed.api.trim().isEmpty()
                                    ? parsed.api.trim()
                                    : rawApi;
                    Object extObj = parsed != null ? parsed.ext : o.opt("ext");
                    String extSig = canonicalExtSignature(extObj, origin, type, parsed != null);
                    String headersSig = canonicalHeadersSignature(parsed, o, type);
                    String effJar = "";
                    if (type == 3) {
                        String siteJar =
                                parsed != null && parsed.jar != null
                                        ? parsed.jar.trim()
                                        : Cms.optSafeString(o, "jar", "").trim();
                        if (!siteJar.isEmpty()) {
                            effJar = siteJar;
                        } else if (parsed != null && CspEngine.eligible(parsed)) {
                            effJar = configSpider;
                        }
                    }
                    boolean searchable =
                            parsed != null
                                    ? parsed.searchable
                                    : (com.pilipala.source.Json.integer(o, "searchable", 1) != 0);
                    out.add(
                            new SiteRouteSignature(
                                    rk,
                                    type,
                                    rawApi,
                                    resolvedApi,
                                    extSig,
                                    headersSig,
                                    effJar,
                                    searchable));
                    emittedKeys.add(rk);
                }
            }
        } catch (Throwable ignored) {
        }
        for (Map.Entry<String, Cms.Site> e : parsedByKey.entrySet()) {
            String rk = e.getKey();
            if (emittedKeys.contains(rk)) continue;
            Cms.Site s = e.getValue();
            String api = s.api == null ? "" : s.api.trim();
            String extSig = canonicalExtSignature(s.ext, origin, s.type, true);
            String headersSig = canonicalHeadersSignature(s, null, s.type);
            String effJar = "";
            if (s.type == 3) {
                String siteJar = s.jar == null ? "" : s.jar.trim();
                effJar = !siteJar.isEmpty() ? siteJar : (CspEngine.eligible(s) ? configSpider : "");
            }
            out.add(
                    new SiteRouteSignature(
                            rk, s.type, api, api, extSig, headersSig, effJar, s.searchable));
        }
        return out;
    }

    /**
     * Attempts safe recovery for a subscription whose active ConfigLibrary snapshot was previously
     * overwritten by a filtered runtime config (containing derived {@code ::shortId} keys). Keeps
     * all user switches ({@code enabled}, {@code disabledSiteKeys}) intact and restores ONLY when a
     * verified clean generation matches surviving raw keys AND actual engine route identity ({@code
     * type}, {@code api}, canonical {@code ext}, and effective {@code jar} for CSP) — using trusted
     * {@code cleanHistory} first, then an unambiguous unique newest timestamp on legacy disks
     * (never breaking ties by site count and never overwriting surviving working routes when no
     * compatible backup exists).
     */
    boolean tryRecoverDamagedSubscriptionRaw(ConfigLibrary library, SubscriptionRecord rec) {
        if (library == null
                || rec == null
                || library.directory == null
                || !library.directory.isDirectory()) {
            return false;
        }
        try {
            final long startRev = readState().revision;
            ConfigLibrary.Entry entry = findLibraryEntry(library.entries(), rec);
            if (entry == null) return false;
            final String damagedDigest = entry.digest;
            String curRaw = library.raw(entry);
            if (!rawJsonHasDerivedRuntimeSiteKeys(curRaw)) {
                recoveryHints.remove(rec.id);
                return false;
            }

            // Extract surviving raw keys AND engine-effective route signatures (type, api,
            // canonical ext, effective jar) from the damaged runtime snapshot so recovery never
            // resurrects a withdrawn catalog/endpoint or overwrites a still-working line.
            List<SiteRouteSignature> damagedSurvivors =
                    extractSiteRoutes(rec.id, curRaw, rec.origin);

            final class CleanSnapshotCandidate {
                final String digest;
                final String raw;
                final int siteCount;
                final long lastModified;
                final boolean routesCompatible;

                CleanSnapshotCandidate(
                        String digest,
                        String raw,
                        int siteCount,
                        long lastModified,
                        boolean routesCompatible) {
                    this.digest = digest;
                    this.raw = raw;
                    this.siteCount = siteCount;
                    this.lastModified = lastModified;
                    this.routesCompatible = routesCompatible;
                }
            }

            String prefix = entry.id + "-";
            File[] files = library.directory.listFiles();
            if (files == null) return false;
            long damagedMtime = library.contentFile(entry).lastModified();
            Map<String, CleanSnapshotCandidate> byDigest = new LinkedHashMap<>();
            List<CleanSnapshotCandidate> allCandidates = new ArrayList<>();
            for (File f : files) {
                if (f == null || !f.isFile()) continue;
                String fn = f.getName();
                if (!fn.startsWith(prefix) || !fn.endsWith(".json")) continue;
                String expectedDigest = fn.substring(prefix.length(), fn.length() - 5);
                if (!expectedDigest.matches("[0-9a-f]{64}")
                        || expectedDigest.equals(damagedDigest)) {
                    continue;
                }
                try {
                    String candidate = readText(f, ConfigLibrary.MAX_SUBSCRIPTION_BYTES);
                    if (!ConfigLibrary.hash(candidate).equals(expectedDigest)) continue;
                    if (rawJsonHasDerivedRuntimeSiteKeys(candidate)) continue;
                    Cms.Config parsed = Cms.parseConfig(candidate, rec.origin);
                    List<SiteRouteSignature> candRoutes =
                            extractSiteRoutes(rec.id, candidate, rec.origin);
                    Map<String, List<SiteRouteSignature>> candByKey = new HashMap<>();
                    for (SiteRouteSignature sig : candRoutes) {
                        List<SiteRouteSignature> list = candByKey.get(sig.rawKey);
                        if (list == null) {
                            list = new ArrayList<>(2);
                            candByKey.put(sig.rawKey, list);
                        }
                        list.add(sig);
                    }
                    boolean routesMatch = true;
                    for (SiteRouteSignature surv : damagedSurvivors) {
                        List<SiteRouteSignature> matchedKey = candByKey.get(surv.rawKey);
                        if (matchedKey == null || matchedKey.isEmpty()) {
                            routesMatch = false;
                            break;
                        }
                        boolean routeHit = false;
                        for (SiteRouteSignature candSig : matchedKey) {
                            if (surv.matches(candSig)) {
                                routeHit = true;
                                break;
                            }
                        }
                        if (!routeHit) {
                            routesMatch = false;
                            break;
                        }
                    }
                    CleanSnapshotCandidate c =
                            new CleanSnapshotCandidate(
                                    expectedDigest,
                                    candidate,
                                    parsed.sites.size(),
                                    f.lastModified(),
                                    routesMatch);
                    byDigest.put(expectedDigest, c);
                    allCandidates.add(c);
                } catch (Throwable ignored) {
                }
            }
            if (allCandidates.isEmpty()) {
                recoveryHints.put(rec.id, "检测到旧版订阅快照，未找到可验证的历史副本，已保留当前可用线路，建议刷新订阅");
                return false;
            }

            // Priority 1: trusted clean digest chain recorded in ConfigLibrary index (newest
            // first). Still require route compatibility whenever surviving working lines exist so
            // an older snapshot can never clobber a newer surviving endpoint.
            CleanSnapshotCandidate chosen = null;
            for (String histDigest : entry.cleanHistory) {
                CleanSnapshotCandidate c = byDigest.get(histDigest);
                if (c != null && c.routesCompatible) {
                    chosen = c;
                    break;
                }
            }

            // Priority 2: legacy disk upgrade without cleanHistory — strictly require route
            // compatibility (both raw key AND endpoint API). Never fall back to incompatible
            // snapshots, and never break equal-mtime ties by site count.
            if (chosen == null && entry.cleanHistory.isEmpty()) {
                List<CleanSnapshotCandidate> pool = new ArrayList<>();
                for (CleanSnapshotCandidate c : allCandidates) {
                    if (c.routesCompatible) pool.add(c);
                }
                if (damagedMtime > 0L && !pool.isEmpty()) {
                    List<CleanSnapshotCandidate> priorToDamage = new ArrayList<>();
                    for (CleanSnapshotCandidate c : pool) {
                        if (c.lastModified <= damagedMtime) priorToDamage.add(c);
                    }
                    if (!priorToDamage.isEmpty()) pool = priorToDamage;
                }
                if (!pool.isEmpty()) {
                    long maxMtime = Long.MIN_VALUE;
                    for (CleanSnapshotCandidate c : pool) {
                        if (c.lastModified > maxMtime) maxMtime = c.lastModified;
                    }
                    List<CleanSnapshotCandidate> newestTied = new ArrayList<>();
                    for (CleanSnapshotCandidate c : pool) {
                        if (c.lastModified == maxMtime) newestTied.add(c);
                    }
                    if (newestTied.size() == 1) {
                        chosen = newestTied.get(0);
                    }
                }
            }

            if (chosen != null) {
                synchronized (LOCK) {
                    State st = readState();
                    if (st.revision != startRev) return false;
                    SubscriptionRecord cur = st.findById(rec.id);
                    if (cur == null) return false;
                    ConfigLibrary.Entry latestEntry = findLibraryEntry(library.entries(), cur);
                    if (latestEntry == null || !damagedDigest.equals(latestEntry.digest)) {
                        // A newer refresh already replaced the damaged snapshot; never overwrite
                        // it.
                        return false;
                    }
                    ConfigLibrary.Entry restored =
                            library.remember(
                                    chosen.raw,
                                    latestEntry.origin,
                                    cur.name.isEmpty() ? latestEntry.name : cur.name,
                                    latestEntry.selected,
                                    Math.max(latestEntry.updated, System.currentTimeMillis()));
                    cur.libraryEntryId = restored.id;
                    cur.totalSiteCount = Math.max(0, chosen.siteCount);
                    cur.lastError = "";
                    st.revision++;
                    saveState(st);
                }
                recoveryHints.remove(rec.id);
                return true;
            }
            // Could not uniquely identify a compatible historical generation: keep current
            // readable body and user switches intact, and surface a refresh hint instead of
            // risking resurrecting withdrawn lines or overwriting still-working endpoints.
            recoveryHints.put(rec.id, "无法自动确认旧版订阅的历史版本，已保留当前可用线路与开关，建议刷新订阅");
        } catch (Throwable ignored) {
        }
        return false;
    }

    /**
     * Scans all stored subscriptions and automatically restores any subscription whose active
     * ConfigLibrary index entry was polluted by a filtered runtime snapshot when a verified
     * undamaged copy of the same subscription still exists on disk. Preserves all user switches.
     */
    boolean recoverDamagedSubscriptionsIfAny(ConfigLibrary library) {
        if (library == null || library.directory == null || !library.directory.isDirectory()) {
            return false;
        }
        State snap = readState();
        if (snap.subscriptions.isEmpty()) return false;
        boolean recoveredAny = false;
        for (SubscriptionRecord rec : snap.subscriptions) {
            if (tryRecoverDamagedSubscriptionRaw(library, rec)) {
                recoveredAny = true;
            }
        }
        return recoveredAny;
    }

    /**
     * One-time safe upgrade migration from legacy single-source or merged-config installations.
     *
     * <p>Rules:
     * <ul>
     *   <li>Legacy single-source: enables ONLY the active source; saved-but-unused ConfigLibrary
     *       entries stay disabled.
     *   <li>Legacy merged config: recovers enabled members from {@code _marco_multi_sources} and
     *       records exact legacy alias mappings (including {@code key__6hex} disambiguated keys) so
     *       existing WatchHistory &amp; Favorites resolve without cross-source contamination.
     *   <li>Unidentifiable active snapshot: preserved as an enabled standalone card so upgrade never
     *       breaks working playback.
     *   <li>Already initialized state (including explicit 0 enabled): never auto-re-enables.
     * </ul>
     */
    State ensureMigrated(
            ConfigLibrary library, String activeRaw, String activeOrigin, String activeSelectedKey)
            throws Exception {
        synchronized (LOCK) {
            State st = readState();
            List<ConfigLibrary.Entry> libEntries =
                    library != null ? library.entries() : Collections.emptyList();
            if (st.initialized) {
                boolean changed = syncLibraryEntriesLocked(st, libEntries, false);
                if (changed) {
                    st.revision++;
                    saveState(st);
                }
                recoverDamagedSubscriptionsIfAny(library);
                return readState();
            }

            // First-time upgrade migration
            Map<String, ConfigLibrary.Entry> byOrigin = new LinkedHashMap<>();
            Map<String, ConfigLibrary.Entry> byId = new LinkedHashMap<>();
            Map<String, ConfigLibrary.Entry> byName = new LinkedHashMap<>();
            for (ConfigLibrary.Entry e : libEntries) {
                if (e == null) continue;
                // Skip old synthetic merged entries from becoming standalone cards unless needed
                if (SubscriptionManager.isMergedOrigin(e.origin)) continue;
                byId.put(e.id, e);
                if (e.origin != null && !e.origin.trim().isEmpty()) {
                    byOrigin.put(e.origin.trim(), e);
                }
                if (e.name != null
                        && !e.name.trim().isEmpty()
                        && !byName.containsKey(e.name.trim())) {
                    byName.put(e.name.trim(), e);
                }
                SubscriptionRecord rec = recordFromLibraryEntry(e, false);
                st.subscriptions.add(rec);
            }

            String cleanActiveRaw = activeRaw == null ? "" : activeRaw.trim();
            String cleanActiveOrigin = activeOrigin == null ? "" : activeOrigin.trim();
            String cleanSelected = activeSelectedKey == null ? "" : activeSelectedKey.trim();

            if (!cleanActiveRaw.isEmpty()) {
                List<SubscriptionManager.MultiSourceMeta> multiMeta =
                        SubscriptionManager.readMultiSourceMeta(cleanActiveRaw);
                if (SubscriptionManager.isMergedOrigin(cleanActiveOrigin)
                        || multiMeta.size() >= 2) {
                    migrateLegacyMergedLocked(
                            st,
                            library,
                            cleanActiveRaw,
                            cleanSelected,
                            multiMeta,
                            byOrigin,
                            byName);
                } else {
                    migrateLegacySingleLocked(
                            st,
                            library,
                            cleanActiveRaw,
                            cleanActiveOrigin,
                            cleanSelected,
                            byOrigin,
                            byId);
                }
            }

            st.initialized = true;
            st.revision = Math.max(1L, st.revision + 1L);
            saveState(st);
            recoverDamagedSubscriptionsIfAny(library);
            return readState();
        }
    }

    private void migrateLegacySingleLocked(
            State st,
            ConfigLibrary library,
            String activeRaw,
            String activeOrigin,
            String activeSelectedKey,
            Map<String, ConfigLibrary.Entry> byOrigin,
            Map<String, ConfigLibrary.Entry> byId)
            throws Exception {
        SubscriptionRecord matched = null;
        if (!activeOrigin.isEmpty()) {
            matched = st.findByOrigin(activeOrigin);
        }
        if (matched == null) {
            String activeLibId = ConfigLibrary.identity(activeOrigin, activeRaw);
            matched = st.findByLibraryEntryId(activeLibId);
        }
        if (matched == null && library != null) {
            Cms.Config parsed = Cms.parseConfig(activeRaw, activeOrigin);
            String name = deriveFriendlyName(activeOrigin, parsed, "当前本地配置");
            ConfigLibrary.Entry saved =
                    library.remember(activeRaw, activeOrigin, name, activeSelectedKey);
            matched = recordFromLibraryEntry(saved, true);
            st.subscriptions.add(0, matched);
        }
        if (matched != null) {
            matched.enabled = true;
            try {
                Cms.Config parsed = Cms.parseConfig(activeRaw, activeOrigin);
                matched.totalSiteCount = parsed.sites.size();
                matched.loadedSiteCount = parsed.sites.size();
                for (Cms.Site site : parsed.sites) {
                    if (site == null || site.key == null || site.key.isEmpty()) continue;
                    String stable = stableSiteKey(matched.id, site.key);
                    st.legacyAliases.put(site.key, new AliasTarget(matched.id, site.key, stable));
                }
                if (!activeSelectedKey.isEmpty()) {
                    AliasTarget at = st.legacyAliases.get(activeSelectedKey);
                    if (at != null) {
                        st.currentSubscriptionId = at.subscriptionId;
                        st.currentRawSiteKey = at.rawSiteKey;
                        st.currentStableSiteKey = at.stableSiteKey;
                    }
                }
            } catch (Throwable ignored) {
            }
        }
    }

    private void migrateLegacyMergedLocked(
            State st,
            ConfigLibrary library,
            String activeRaw,
            String activeSelectedKey,
            List<SubscriptionManager.MultiSourceMeta> multiMeta,
            Map<String, ConfigLibrary.Entry> byOrigin,
            Map<String, ConfigLibrary.Entry> byName)
            throws Exception {
        List<SubscriptionRecord> matchedMembers = new ArrayList<>();
        boolean allMatched = !multiMeta.isEmpty();
        Set<String> usedLegacyKeys = new HashSet<>();
        for (int i = 0; i < multiMeta.size(); i++) {
            SubscriptionManager.MultiSourceMeta m = multiMeta.get(i);
            SubscriptionRecord rec = null;
            if (!m.url.isEmpty()) {
                rec = st.findByOrigin(m.url);
            }
            if (rec == null && !m.name.isEmpty()) {
                // Only match by name if unique in subscriptions
                SubscriptionRecord byUniqueName = null;
                int hits = 0;
                for (SubscriptionRecord cand : st.subscriptions) {
                    if (m.name.equals(cand.name)) {
                        byUniqueName = cand;
                        hits++;
                    }
                }
                if (hits == 1) rec = byUniqueName;
            }
            if (rec == null) {
                allMatched = false;
                continue;
            }
            rec.enabled = true;
            matchedMembers.add(rec);

            // Reproduce exact legacy SubscriptionManager.mergeSources key assignment for aliases!
            if (library != null) {
                ConfigLibrary.Entry entry = findLibraryEntry(library.entries(), rec);
                if (entry != null) {
                    try {
                        String memberRaw = library.raw(entry);
                        Cms.Config memberCfg = Cms.parseConfig(memberRaw, rec.origin);
                        String originTag =
                                rec.origin.isEmpty() ? ("local:" + m.name + ":" + i) : rec.origin;
                        String oldShort6 = ConfigLibrary.hash(originTag).substring(0, 6);
                        rec.totalSiteCount = memberCfg.sites.size();
                        for (Cms.Site site : memberCfg.sites) {
                            if (site == null || site.key == null || site.key.isEmpty()) continue;
                            String legacyKey = site.key;
                            if (!usedLegacyKeys.add(legacyKey)) {
                                legacyKey = site.key + "__" + oldShort6;
                                int dup = 2;
                                while (!usedLegacyKeys.add(legacyKey)) {
                                    legacyKey = site.key + "__" + oldShort6 + "_" + dup++;
                                }
                            }
                            String stable = stableSiteKey(rec.id, site.key);
                            st.legacyAliases.put(
                                    legacyKey, new AliasTarget(rec.id, site.key, stable));
                        }
                    } catch (Throwable ignored) {
                        allMatched = false;
                    }
                } else {
                    allMatched = false;
                }
            }
        }

        // Preserve working snapshot when any legacy merged member was missing/unidentifiable!
        if (!allMatched && library != null) {
            for (SubscriptionRecord r : matchedMembers) r.enabled = false;
            Cms.Config snapCfg = Cms.parseConfig(activeRaw, "");
            String snapName = "已升级合并快照";
            ConfigLibrary.Entry saved =
                    library.remember(activeRaw, "", snapName, activeSelectedKey);
            SubscriptionRecord snapRec = recordFromLibraryEntry(saved, true);
            snapRec.totalSiteCount = snapCfg.sites.size();
            snapRec.loadedSiteCount = snapCfg.sites.size();
            st.subscriptions.add(0, snapRec);
            for (Cms.Site site : snapCfg.sites) {
                if (site == null || site.key == null || site.key.isEmpty()) continue;
                String stable = stableSiteKey(snapRec.id, site.key);
                st.legacyAliases.put(site.key, new AliasTarget(snapRec.id, site.key, stable));
            }
        }

        if (!activeSelectedKey.isEmpty()) {
            AliasTarget target = st.legacyAliases.get(activeSelectedKey);
            if (target != null) {
                st.currentSubscriptionId = target.subscriptionId;
                st.currentRawSiteKey = target.rawSiteKey;
                st.currentStableSiteKey = target.stableSiteKey;
            }
        }
    }

    private static boolean syncLibraryEntriesLocked(
            State st, List<ConfigLibrary.Entry> libEntries, boolean enableNew) throws Exception {
        boolean changed = false;
        for (ConfigLibrary.Entry e : libEntries) {
            if (e == null || SubscriptionManager.isMergedOrigin(e.origin)) continue;
            SubscriptionRecord existing = st.findByLibraryEntryId(e.id);
            if (existing == null && e.origin != null && !e.origin.trim().isEmpty()) {
                existing = st.findByOrigin(e.origin.trim());
            }
            if (existing != null) {
                if (!e.id.equals(existing.libraryEntryId)) {
                    existing.libraryEntryId = e.id;
                    changed = true;
                }
                if (e.updated > existing.lastUpdated) {
                    existing.lastUpdated = e.updated;
                    changed = true;
                }
                if (existing.name.isEmpty() && e.name != null && !e.name.trim().isEmpty()) {
                    existing.name = e.name.trim();
                    changed = true;
                }
            } else {
                SubscriptionRecord added = recordFromLibraryEntry(e, enableNew);
                st.subscriptions.add(added);
                changed = true;
            }
        }
        return changed;
    }

    private static SubscriptionRecord recordFromLibraryEntry(ConfigLibrary.Entry e, boolean enabled)
            throws Exception {
        SubscriptionRecord r = new SubscriptionRecord();
        r.id =
                (e.origin != null && !e.origin.trim().isEmpty())
                        ? ConfigLibrary.hash("url:" + e.origin.trim())
                        : e.id;
        r.libraryEntryId = e.id;
        r.name = (e.name == null || e.name.trim().isEmpty()) ? "未命名订阅" : e.name.trim();
        r.origin = e.origin == null ? "" : e.origin.trim();
        r.enabled = enabled;
        r.lastUpdated = Math.max(1L, e.updated);
        return r;
    }

    private static ConfigLibrary.Entry findLibraryEntry(
            List<ConfigLibrary.Entry> entries, SubscriptionRecord rec) {
        if (entries == null || rec == null) return null;
        for (ConfigLibrary.Entry e : entries) {
            if (e != null && rec.libraryEntryId.equals(e.id)) return e;
        }
        if (!rec.origin.isEmpty()) {
            for (ConfigLibrary.Entry e : entries) {
                if (e != null && rec.origin.equals(e.origin)) return e;
            }
        }
        return null;
    }

    /** Registers or updates a subscription in ConfigLibrary + TvMultiSourceStore atomically. */
    SubscriptionRecord registerSubscription(
            ConfigLibrary library,
            String raw,
            String origin,
            String name,
            boolean enableOnAdd,
            long updatedAt)
            throws Exception {
        return importSubscriptionInternal(
                library, raw, origin, name, enableOnAdd, true, false, updatedAt);
    }

    /**
     * Atomically validates UTF-8 size, parses, writes &amp; reads back candidate content from
     * {@link ConfigLibrary}, and only then commits index + enabled set + optional current site so
     * any failure leaves existing subscriptions and active catalog completely untouched.
     */
    SubscriptionRecord importSubscriptionAtomic(
            ConfigLibrary library,
            String raw,
            String origin,
            String name,
            boolean appendToExisting,
            boolean selectFirstSite,
            long updatedAt)
            throws Exception {
        return importSubscriptionInternal(
                library, raw, origin, name, true, appendToExisting, selectFirstSite, updatedAt);
    }

    private SubscriptionRecord importSubscriptionInternal(
            ConfigLibrary library,
            String raw,
            String origin,
            String name,
            boolean enableOnAdd,
            boolean appendToExisting,
            boolean selectFirstSite,
            long updatedAt)
            throws Exception {
        if (raw == null || Cms.utf8ByteLength(raw) > ConfigLibrary.MAX_SUBSCRIPTION_BYTES) {
            throw new IOException("订阅正文超过 16 MB 限制，原片库已保留");
        }
        String cleanOrigin = origin == null ? "" : origin.trim();
        Cms.Config parsed = Cms.parseConfig(raw, cleanOrigin);
        String label =
                (name != null && !name.trim().isEmpty())
                        ? name.trim()
                        : deriveFriendlyName(cleanOrigin, parsed, "订阅源");
        synchronized (LOCK) {
            // Stage candidate content, read back & verify SHA-256 + parseability BEFORE committing
            // any enabled-set or current-site mutations.
            ConfigLibrary.Entry saved =
                    library.remember(raw, cleanOrigin, label, "", Math.max(1L, updatedAt));
            String verifiedRaw = library.raw(saved);
            Cms.Config verifiedParsed =
                    verifiedRaw.equals(raw) ? parsed : Cms.parseConfig(verifiedRaw, cleanOrigin);

            State st = readState();
            SubscriptionRecord existing =
                    !cleanOrigin.isEmpty()
                            ? st.findByOrigin(cleanOrigin)
                            : st.findByLibraryEntryId(saved.id);
            if (existing != null) {
                existing.libraryEntryId = saved.id;
                if (name != null && !name.trim().isEmpty()) existing.name = name.trim();
                existing.lastUpdated = Math.max(1L, updatedAt);
                existing.lastError = "";
                existing.totalSiteCount = verifiedParsed.sites.size();
                if (enableOnAdd) existing.enabled = true;
            } else {
                existing = new SubscriptionRecord();
                existing.id = newPermanentId(cleanOrigin, verifiedRaw);
                existing.libraryEntryId = saved.id;
                existing.name = label;
                existing.origin = cleanOrigin;
                existing.enabled = enableOnAdd;
                existing.lastUpdated = Math.max(1L, updatedAt);
                existing.totalSiteCount = verifiedParsed.sites.size();
                st.subscriptions.add(existing);
            }
            if (!appendToExisting) {
                for (SubscriptionRecord r : st.subscriptions) {
                    r.enabled = existing.id.equals(r.id);
                }
            }
            if (selectFirstSite
                    && !verifiedParsed.sites.isEmpty()
                    && verifiedParsed.sites.get(0) != null
                    && !verifiedParsed.sites.get(0).key.isEmpty()) {
                String rawFirst =
                        stripOwnStableSuffix(existing.id, verifiedParsed.sites.get(0).key);
                String stableFirst = stableSiteKey(existing.id, rawFirst);
                st.currentStableSiteKey = stableFirst;
                st.currentSubscriptionId = existing.id;
                st.currentRawSiteKey = rawFirst;
            }
            st.initialized = true;
            st.revision++;
            saveState(st);
            return existing.copy();
        }
    }

    /**
     * Switches the active child warehouse inside an existing multi-warehouse subscription while
     * preserving all other enabled subscriptions and keeping {@code _marco_depots} intact.
     */
    SubscriptionRecord switchSubscriptionDepot(
            ConfigLibrary library,
            String subId,
            String warehouseRoot,
            Cms.Config selectedLeaf,
            long updatedAt)
            throws Exception {
        if (library == null || selectedLeaf == null || selectedLeaf.raw == null) {
            throw new IOException("子仓库数据无效");
        }
        synchronized (LOCK) {
            State st = readState();
            SubscriptionRecord target =
                    (subId != null && !subId.trim().isEmpty()) ? st.findById(subId.trim()) : null;
            if (target == null && warehouseRoot != null && !warehouseRoot.trim().isEmpty()) {
                target = st.findByOrigin(warehouseRoot.trim());
            }
            if (target == null) {
                target = st.findById(st.currentSubscriptionId);
            }
            if (target == null) {
                for (SubscriptionRecord r : st.subscriptions) {
                    if (r.enabled) {
                        target = r;
                        break;
                    }
                }
            }
            if (target == null) {
                throw new IOException("未找到可切换的多仓订阅");
            }
            List<ConfigLibrary.Entry> libEntries = library.entries();
            ConfigLibrary.Entry prevEntry = findLibraryEntry(libEntries, target);
            String prevRaw = prevEntry != null ? library.raw(prevEntry) : "{\"sites\":[]}";
            String combined =
                    com.pilipala.source.Warehouse.retainDirectory(
                            selectedLeaf.raw,
                            selectedLeaf.origin,
                            prevRaw,
                            raw -> new JSONObject(Cms.withoutComments(raw)));
            Cms.Config verifiedParsed = Cms.parseConfig(combined, selectedLeaf.origin);
            String rememberOrigin =
                    !target.origin.isEmpty()
                            ? target.origin
                            : (warehouseRoot != null && !warehouseRoot.isEmpty()
                                    ? warehouseRoot
                                    : selectedLeaf.origin);
            ConfigLibrary.Entry saved =
                    library.remember(
                            combined, rememberOrigin, target.name, "", Math.max(1L, updatedAt));
            String readBack = library.raw(saved);
            if (!readBack.equals(combined)) {
                verifiedParsed = Cms.parseConfig(readBack, selectedLeaf.origin);
            }
            target.libraryEntryId = saved.id;
            target.enabled = true;
            target.lastUpdated = Math.max(1L, updatedAt);
            target.lastError = "";
            target.totalSiteCount = verifiedParsed.sites.size();
            if (!verifiedParsed.sites.isEmpty()
                    && verifiedParsed.sites.get(0) != null
                    && !verifiedParsed.sites.get(0).key.isEmpty()) {
                String rawFirst = stripOwnStableSuffix(target.id, verifiedParsed.sites.get(0).key);
                st.currentSubscriptionId = target.id;
                st.currentRawSiteKey = rawFirst;
                st.currentStableSiteKey = stableSiteKey(target.id, rawFirst);
            }
            st.initialized = true;
            st.revision++;
            saveState(st);
            return target.copy();
        }
    }

    /** Atomically enables only the specified subscription IDs, keeping all others disabled for later re-enable. */
    State enableOnlySubscriptions(Set<String> keepEnabledIds) throws IOException {
        synchronized (LOCK) {
            State st = readState();
            boolean changed = false;
            for (SubscriptionRecord r : st.subscriptions) {
                boolean wantEnabled = keepEnabledIds != null && keepEnabledIds.contains(r.id);
                if (r.enabled != wantEnabled) {
                    r.enabled = wantEnabled;
                    changed = true;
                }
            }
            if (changed || !st.initialized) {
                st.initialized = true;
                st.revision++;
                saveState(st);
            }
            return st.copy();
        }
    }

    /** Toggles a subscription's enabled flag without altering other subscriptions' site keys. */
    State setSubscriptionEnabled(String subscriptionId, boolean enabled) throws IOException {
        synchronized (LOCK) {
            State st = readState();
            SubscriptionRecord target = st.findById(subscriptionId);
            if (target == null) return st;
            if (target.enabled == enabled && st.initialized) return st;
            target.enabled = enabled;
            st.initialized = true;
            st.revision++;
            saveState(st);
            return st.copy();
        }
    }

    /** Toggles an individual site inside a subscription (preserved across parent disable/enable). */
    State setSiteDisabled(String subscriptionId, String rawSiteKey, boolean disabled)
            throws IOException {
        synchronized (LOCK) {
            State st = readState();
            SubscriptionRecord target = st.findById(subscriptionId);
            if (target == null || rawSiteKey == null || rawSiteKey.trim().isEmpty()) return st;
            String raw = rawSiteKey.trim();
            boolean changed =
                    disabled
                            ? target.disabledSiteKeys.add(raw)
                            : target.disabledSiteKeys.remove(raw);
            if (!changed) return st;
            st.initialized = true;
            st.revision++;
            saveState(st);
            return st.copy();
        }
    }

    /** Moves a subscription up or down in priority order without changing any site's stable key. */
    State moveSubscription(String subscriptionId, int delta) throws IOException {
        synchronized (LOCK) {
            State st = readState();
            int idx = -1;
            for (int i = 0; i < st.subscriptions.size(); i++) {
                if (st.subscriptions.get(i).id.equals(subscriptionId)) {
                    idx = i;
                    break;
                }
            }
            if (idx < 0) return st;
            int nextIdx = idx + delta;
            if (nextIdx < 0 || nextIdx >= st.subscriptions.size()) return st;
            SubscriptionRecord item = st.subscriptions.remove(idx);
            st.subscriptions.add(nextIdx, item);
            st.revision++;
            saveState(st);
            return st.copy();
        }
    }

    State renameSubscription(ConfigLibrary library, String subscriptionId, String newName)
            throws Exception {
        synchronized (LOCK) {
            State st = readState();
            SubscriptionRecord target = st.findById(subscriptionId);
            if (target == null || newName == null || newName.trim().isEmpty()) return st;
            target.name = newName.trim();
            if (library != null) {
                ConfigLibrary.Entry entry = findLibraryEntry(library.entries(), target);
                if (entry != null) {
                    String raw = library.raw(entry);
                    ConfigLibrary.Entry updated =
                            library.remember(
                                    raw, entry.origin, target.name, entry.selected, entry.updated);
                    target.libraryEntryId = updated.id;
                }
            }
            st.revision++;
            saveState(st);
            return st.copy();
        }
    }

    State deleteSubscription(ConfigLibrary library, String subscriptionId) throws Exception {
        synchronized (LOCK) {
            State st = readState();
            SubscriptionRecord removed = null;
            Iterator<SubscriptionRecord> it = st.subscriptions.iterator();
            while (it.hasNext()) {
                SubscriptionRecord r = it.next();
                if (r.id.equals(subscriptionId)) {
                    removed = r;
                    it.remove();
                    break;
                }
            }
            if (removed == null) return st;
            if (library != null && !removed.libraryEntryId.isEmpty()) {
                try {
                    library.remove(removed.libraryEntryId);
                } catch (Exception ignored) {
                }
            }
            if (removed.id.equals(st.currentSubscriptionId)) {
                st.currentSubscriptionId = "";
                st.currentRawSiteKey = "";
                st.currentStableSiteKey = "";
            }
            st.initialized = true;
            st.revision++;
            saveState(st);
            return st.copy();
        }
    }

    State setCurrentSite(String stableSiteKey, String subscriptionId, String rawSiteKey)
            throws IOException {
        synchronized (LOCK) {
            State st = readState();
            String nextStable = stableSiteKey == null ? "" : stableSiteKey.trim();
            String nextSub = subscriptionId == null ? "" : subscriptionId.trim();
            String nextRaw = rawSiteKey == null ? "" : rawSiteKey.trim();
            boolean changed =
                    !nextStable.equals(st.currentStableSiteKey)
                            || !nextSub.equals(st.currentSubscriptionId)
                            || !nextRaw.equals(st.currentRawSiteKey);
            st.currentStableSiteKey = nextStable;
            st.currentSubscriptionId = nextSub;
            st.currentRawSiteKey = nextRaw;
            if (changed) {
                st.revision++;
            }
            saveState(st);
            return st.copy();
        }
    }

    /**
     * Refreshes one enabled subscription safely: preserves per-site disabled switches, keeps last
     * good snapshot on fetch/parse failure (recording {@code lastError} on the card), and aborts
     * commit if state revision changed while fetching.
     */
    boolean refreshSingleSubscription(
            ConfigLibrary library,
            String subscriptionId,
            SubscriptionManager.Fetcher fetcher,
            long nowMs)
            throws Exception {
        final State snap = readState();
        final long expectedRev = snap.revision;
        final SubscriptionRecord target = snap.findById(subscriptionId);
        if (target == null || target.origin.isEmpty() || !Cms.isHttp(target.origin)) {
            return false;
        }
        String fetchedRaw;
        Cms.Config parsed;
        try {
            fetchedRaw = fetcher.fetch(target.origin);
            if (fetchedRaw == null || fetchedRaw.trim().isEmpty()) {
                throw new IOException("订阅返回空内容");
            }
            if (Cms.utf8ByteLength(fetchedRaw) > ConfigLibrary.MAX_SUBSCRIPTION_BYTES) {
                throw new IOException("订阅正文超过 16 MB 限制，保留上次可用配置");
            }
            parsed = Cms.parseConfig(fetchedRaw, target.origin);
            boolean hasLiveBlock = fetchedRaw.contains("\"lives\"");
            if (parsed.sites.isEmpty() && !hasLiveBlock) {
                throw new IOException("订阅未包含有效片源");
            }
        } catch (Throwable err) {
            synchronized (LOCK) {
                State cur = readState();
                SubscriptionRecord curTarget = cur.findById(subscriptionId);
                if (curTarget != null) {
                    curTarget.lastError =
                            err.getMessage() == null || err.getMessage().trim().isEmpty()
                                    ? "刷新失败（保留上次可用配置）"
                                    : err.getMessage().trim();
                    saveState(cur);
                }
            }
            return false;
        }

        synchronized (LOCK) {
            State cur = readState();
            if (cur.revision != expectedRev) {
                // User mutated enabled set / order / metadata while refresh was in flight;
                // abort BEFORE touching ConfigLibrary so stale payload never overwrites disk.
                return false;
            }
            SubscriptionRecord curTarget = cur.findById(subscriptionId);
            if (curTarget == null) {
                return false;
            }
            try {
                ConfigLibrary.Entry saved =
                        library.remember(
                                fetchedRaw, target.origin, curTarget.name, "", Math.max(1L, nowMs));
                String verifiedRaw = library.raw(saved);
                Cms.Config verifiedParsed =
                        verifiedRaw.equals(fetchedRaw)
                                ? parsed
                                : Cms.parseConfig(verifiedRaw, target.origin);
                curTarget.libraryEntryId = saved.id;
                curTarget.lastUpdated = Math.max(1L, nowMs);
                curTarget.lastError = "";
                curTarget.totalSiteCount = verifiedParsed.sites.size();
                cur.revision++;
                saveState(cur);
                return true;
            } catch (Throwable storeErr) {
                curTarget.lastError =
                        storeErr.getMessage() == null || storeErr.getMessage().trim().isEmpty()
                                ? "刷新落盘校验失败（保留上次可用配置）"
                                : storeErr.getMessage().trim();
                saveState(cur);
                return false;
            }
        }
    }

    /**
     * Builds the active {@link Cms.Config} exclusively from currently enabled subscriptions minus
     * individually disabled sites, assigning deterministic subscription-scoped stable site keys.
     */
    EffectiveBuild buildEffectiveConfig(
            ConfigLibrary library, String preferredSiteKey, SiteAvailability availability)
            throws Exception {
        // When an in-process backup restore is active, concurrent readers MUST stay strictly
        // read-only on the consistent pre-restore/post-prefs snapshot and never mutate disk state.
        boolean restoreActive = ConfigLibrary.isRestoreActiveInProcess(directory.getParentFile());
        if (!restoreActive) {
            // Safely heal any subscription polluted by a legacy filtered snapshot BEFORE capturing
            // startRevision so normal boot never marks its own recovery build stale and preserves
            // all user enabled/disabled switches.
            recoverDamagedSubscriptionsIfAny(library);
        }
        final State st = readState();
        List<ConfigLibrary.Entry> libEntries =
                library != null ? library.entries() : Collections.emptyList();
        return buildEffectiveConfigInternal(
                library, st, libEntries, preferredSiteKey, availability, !restoreActive);
    }

    /**
     * Builds a candidate {@link EffectiveBuild} strictly in memory against staged entries and
     * staged {@link State} during atomic backup restore, updating derived counts/selection on
     * {@code stagedState} WITHOUT writing to disk.
     */
    EffectiveBuild buildEffectiveConfigFromSnapshot(
            ConfigLibrary library,
            List<ConfigLibrary.Entry> stagedEntries,
            State stagedState,
            String preferredSiteKey,
            SiteAvailability availability)
            throws Exception {
        return buildEffectiveConfigInternal(
                library,
                stagedState,
                stagedEntries == null ? Collections.emptyList() : stagedEntries,
                preferredSiteKey,
                availability,
                false);
    }

    private EffectiveBuild buildEffectiveConfigInternal(
            ConfigLibrary library,
            State st,
            List<ConfigLibrary.Entry> libEntries,
            String preferredSiteKey,
            SiteAvailability availability,
            boolean persistDerivedState)
            throws Exception {
        final long startRevision = st.revision;
        List<SubscriptionRecord> enabledSubs = new ArrayList<>();
        for (SubscriptionRecord r : st.subscriptions) {
            if (r.enabled) enabledSubs.add(r);
        }

        if (enabledSubs.isEmpty()) {
            Cms.Config emptyCfg = new Cms.Config();
            emptyCfg.raw = "{\"sites\":[]}";
            markEffectiveRuntimeConfig(emptyCfg);
            boolean staleBuild = false;
            if (persistDerivedState) {
                synchronized (LOCK) {
                    State latest = readState();
                    staleBuild = latest.revision != startRevision;
                }
            }
            return new EffectiveBuild(
                    emptyCfg,
                    "",
                    "",
                    "",
                    0,
                    st.subscriptions.size(),
                    startRevision,
                    staleBuild,
                    Collections.emptyMap(),
                    Collections.emptyMap());
        }

        // Parse each enabled subscription independently with its own base URL & spider context,
        // releasing full raw JSON & arbitrary large top-level fields (such as padding) immediately
        // after extracting sites & metadata so 6x9 MiB multi-source builds stay <25 MiB peak heap.
        final class LoadedSub {
            final SubscriptionRecord rec;
            final String spider;
            final String warehouse;
            final JSONArray depots;
            final JSONArray rawParses;
            final JSONArray rawRules;
            final JSONArray rawAds;
            final JSONArray rawLives;
            final List<Cms.Site> keptSites = new ArrayList<>();
            final List<String> keptRawKeys = new ArrayList<>();
            final List<JSONObject> keptRawSites = new ArrayList<>();
            final Set<String> allRawKeys = new HashSet<>();
            int realVodSiteCount;

            LoadedSub(SubscriptionRecord rec, Cms.Config parsed, JSONObject rawRoot) {
                this.rec = rec;
                this.spider = parsed.spider == null ? "" : parsed.spider;
                this.warehouse = parsed.warehouse == null ? "" : parsed.warehouse;
                this.depots = parsed.depots;
                this.rawParses = rawRoot.optJSONArray("parses");
                this.rawRules = rawRoot.optJSONArray("rules");
                this.rawAds = rawRoot.optJSONArray("ads");
                this.rawLives = rawRoot.optJSONArray("lives");
                List<JSONObject> rawSites = new ArrayList<>();
                JSONArray arr = rawRoot.optJSONArray("sites");
                if (arr != null) {
                    for (int i = 0; i < arr.length(); i++) {
                        JSONObject o = arr.optJSONObject(i);
                        if (o != null) rawSites.add(o);
                    }
                }
                for (int i = 0; i < parsed.sites.size(); i++) {
                    Cms.Site site = parsed.sites.get(i);
                    if (site == null || site.key == null || site.key.isEmpty()) continue;
                    if ("live-only-placeholder".equals(site.key)
                            || "csp_LivePlaceholder".equals(site.api)) {
                        continue;
                    }
                    realVodSiteCount++;
                    String normalizedRawKey = stripOwnStableSuffix(rec.id, site.key);
                    allRawKeys.add(normalizedRawKey);
                    if (rec.disabledSiteKeys.contains(normalizedRawKey)
                            || rec.disabledSiteKeys.contains(site.key)) {
                        continue;
                    }
                    keptSites.add(site);
                    keptRawKeys.add(normalizedRawKey);
                    keptRawSites.add(i < rawSites.size() ? rawSites.get(i) : null);
                }
            }
        }

        List<LoadedSub> loaded = new ArrayList<>();
        Map<String, Set<String>> loadedRawKeysBySubId = new HashMap<>();
        int totalKept = 0;
        for (SubscriptionRecord rec : enabledSubs) {
            ConfigLibrary.Entry entry = findLibraryEntry(libEntries, rec);
            if (entry == null) {
                rec.lastError = "未找到本地订阅正文";
                continue;
            }
            try {
                String raw = library.raw(entry);
                Cms.Config parsed = Cms.parseConfig(raw, rec.origin);
                JSONObject rawRoot = parseRootOrEmpty(parsed.raw);
                LoadedSub ls = new LoadedSub(rec, parsed, rawRoot);
                parsed.raw = null;
                rec.totalSiteCount = ls.realVodSiteCount;
                loaded.add(ls);
                loadedRawKeysBySubId.put(rec.id, ls.allRawKeys);
                totalKept += ls.keptSites.size();
            } catch (Throwable err) {
                rec.lastError = "解析失败：" + (err.getMessage() == null ? "格式无效" : err.getMessage());
            }
        }

        if (loaded.isEmpty()) {
            Cms.Config emptyCfg = new Cms.Config();
            emptyCfg.raw = "{\"sites\":[]}";
            markEffectiveRuntimeConfig(emptyCfg);
            boolean staleBuild = false;
            if (persistDerivedState) {
                synchronized (LOCK) {
                    State latest = readState();
                    staleBuild = latest.revision != startRevision;
                }
            }
            return new EffectiveBuild(
                    emptyCfg,
                    "",
                    "",
                    "",
                    enabledSubs.size(),
                    st.subscriptions.size(),
                    startRevision,
                    staleBuild,
                    Collections.emptyMap(),
                    Collections.emptyMap());
        }

        // Fair per-subscription cap when combined kept sites exceed 500
        int[] keptSizes = new int[loaded.size()];
        for (int i = 0; i < loaded.size(); i++) keptSizes[i] = loaded.get(i).keptSites.size();
        int[] limits =
                computeFairLimits(keptSizes, totalKept, SubscriptionManager.MAX_MERGED_SITES);

        JSONArray mergedSites = new JSONArray();
        JSONArray mergedParses = new JSONArray();
        JSONArray mergedRules = new JSONArray();
        JSONArray mergedAds = new JSONArray();
        JSONArray mergedLives = new JSONArray();
        JSONArray mergedDepots = new JSONArray();
        Set<String> usedStableKeys = new HashSet<>();
        Set<String> seenParses = new HashSet<>();
        Set<String> seenAds = new HashSet<>();
        Set<String> seenLives = new HashSet<>();
        Set<String> seenDepots = new HashSet<>();
        Map<String, String> keyToSub = new LinkedHashMap<>();
        Map<String, String> keyToRaw = new LinkedHashMap<>();
        String firstSpider = "";
        String firstWarehouse = "";
        StringBuilder originSig = new StringBuilder();
        boolean multiSub = loaded.size() > 1;

        for (int i = 0; i < loaded.size(); i++) {
            LoadedSub ls = loaded.get(i);
            SubscriptionRecord rec = ls.rec;
            originSig.append(rec.id).append('\n');
            if (firstSpider.isEmpty() && !ls.spider.isEmpty()) {
                firstSpider = ls.spider;
            }
            if (firstWarehouse.isEmpty() && !ls.warehouse.isEmpty()) {
                firstWarehouse = ls.warehouse;
            }
            int limit = limits[i];
            int added = 0;
            for (int sIdx = 0; sIdx < ls.keptSites.size() && added < limit; sIdx++) {
                Cms.Site site = ls.keptSites.get(sIdx);
                String rawKey = ls.keptRawKeys.get(sIdx);
                JSONObject rawSite = ls.keptRawSites.get(sIdx);
                JSONObject copy = copyJson(rawSite);
                String stableKey = stableSiteKey(rec.id, rawKey);
                if (!usedStableKeys.add(stableKey)) {
                    int dup = 2;
                    while (!usedStableKeys.add(stableKey + "_" + dup)) dup++;
                    stableKey = stableKey + "_" + dup;
                }
                String resolvedGroup =
                        multiSub
                                ? (rec.name.isEmpty() ? "默认分组" : rec.name)
                                : ((site.group != null && !site.group.trim().isEmpty())
                                        ? site.group.trim()
                                        : (rec.name.isEmpty() ? "默认分组" : rec.name));
                copy.put("key", stableKey);
                copy.put("name", site.name);
                copy.put("group", resolvedGroup);
                copy.put("type", site.type);
                copy.put("api", site.api);
                copy.put("searchable", site.searchable ? 1 : 0);
                String effJar = (site.jar != null && !site.jar.isEmpty()) ? site.jar : ls.spider;
                if (!effJar.isEmpty()) copy.put("jar", effJar);
                if (site.playUrl != null && !site.playUrl.isEmpty())
                    copy.put("playUrl", site.playUrl);
                if (site.ext != null) copy.put("ext", site.ext);
                mergedSites.put(copy);
                keyToSub.put(stableKey, rec.id);
                keyToRaw.put(stableKey, rawKey);
                added++;
            }
            rec.loadedSiteCount = added;

            if (ls.depots != null) {
                for (int d = 0; d < ls.depots.length(); d++) {
                    JSONObject dep = ls.depots.optJSONObject(d);
                    if (dep == null) continue;
                    String u = dep.optString("url", "").trim();
                    if (!u.isEmpty() && seenDepots.add(u)) {
                        JSONObject depCopy = copyJson(dep);
                        depCopy.put("_subId", rec.id);
                        if (!ls.warehouse.isEmpty()) depCopy.put("_warehouseRoot", ls.warehouse);
                        mergedDepots.put(depCopy);
                    }
                }
            }
            JSONArray rawParses = ls.rawParses;
            if (rawParses != null) {
                for (int p = 0; p < rawParses.length() && mergedParses.length() < 100; p++) {
                    JSONObject obj = rawParses.optJSONObject(p);
                    if (obj == null) continue;
                    String u = obj.optString("url", "").trim();
                    if (!u.isEmpty() && seenParses.add(u)) mergedParses.put(copyJson(obj));
                }
            }
            JSONArray rawRules = ls.rawRules;
            if (rawRules != null) {
                for (int r = 0; r < rawRules.length() && mergedRules.length() < 200; r++) {
                    JSONObject obj = rawRules.optJSONObject(r);
                    if (obj != null) mergedRules.put(copyJson(obj));
                }
            }
            JSONArray rawAds = ls.rawAds;
            if (rawAds != null) {
                for (int a = 0; a < rawAds.length(); a++) {
                    String ad = rawAds.optString(a, "").trim();
                    if (!ad.isEmpty() && seenAds.add(ad)) mergedAds.put(ad);
                }
            }
            JSONArray rawLives = ls.rawLives;
            if (rawLives != null) {
                for (int l = 0; l < rawLives.length(); l++) {
                    JSONObject lv = rawLives.optJSONObject(l);
                    if (lv == null) continue;
                    String lk = lv.optString("url", lv.optString("name", "")).trim();
                    if (lk.isEmpty() || seenLives.add(lk)) mergedLives.put(copyJson(lv));
                }
            }
        }

        JSONObject root = new JSONObject();
        if (!firstSpider.isEmpty()) root.put("spider", firstSpider);
        root.put("sites", mergedSites);
        if (mergedParses.length() > 0) root.put("parses", mergedParses);
        if (mergedRules.length() > 0) root.put("rules", mergedRules);
        if (mergedAds.length() > 0) root.put("ads", mergedAds);
        if (mergedLives.length() > 0) root.put("lives", mergedLives);
        if (mergedDepots.length() > 0) {
            root.put(com.pilipala.source.Warehouse.DEPOTS, mergedDepots);
        }
        if (!firstWarehouse.isEmpty()) {
            root.put(com.pilipala.source.Warehouse.ROOT, firstWarehouse);
        }

        String effectiveOrigin =
                loaded.size() == 1
                        ? loaded.get(0).rec.origin
                        : MULTI_TV_ORIGIN_PREFIX
                                + ConfigLibrary.hash(originSig.toString()).substring(0, 16);
        Cms.Config built;
        if (mergedSites.length() > 0) {
            built = Cms.parseConfig(root.toString(), effectiveOrigin);
        } else {
            // Enabled subscription(s) exist but zero VOD sites remain enabled (e.g. last site
            // disabled or pure-live subscription). Build a valid empty-VOD runtime config while
            // retaining valid lives/parses/rules/ads/depots instead of throwing IOException.
            built = new Cms.Config();
            built.raw = root.toString();
            built.origin = effectiveOrigin;
            built.spider = firstSpider;
            built.warehouse = firstWarehouse;
            if (mergedDepots.length() > 0) built.depots = mergedDepots;
        }
        markEffectiveRuntimeConfig(built);

        // Attach verified per-site legacy history aliases directly to each emitted Cms.Site so
        // detail bookmark lookup and fallback matching recognize migrated records without ever
        // guessing across colliding subscriptions.
        attachBuiltSiteAliases(
                st, library, libEntries, built, keyToSub, keyToRaw, loadedRawKeysBySubId);

        // Resolve current browsing site cleanly:
        // 1. Keep currentStableSiteKey if still present & available (enabling B does NOT jump away
        // from A!)
        // 2. Otherwise check preferredSiteKey (or its alias)
        // 3. Otherwise first available site in deterministic subscription order
        String chosenKey = "";
        String chosenSub = "";
        if (!st.currentStableSiteKey.isEmpty()
                && isPresentAndAvailable(built, st.currentStableSiteKey, availability)) {
            chosenKey = st.currentStableSiteKey;
            chosenSub = mapGet(keyToSub, chosenKey, st.currentSubscriptionId);
        }
        if (chosenKey.isEmpty() && preferredSiteKey != null && !preferredSiteKey.trim().isEmpty()) {
            String pref = preferredSiteKey.trim();
            int nl = pref.indexOf('\n');
            if (nl > 0) pref = pref.substring(0, nl).trim();
            String prefCandidate = pref;
            if (!isPresentAndAvailable(built, prefCandidate, availability)) {
                AliasTarget at = st.legacyAliases.get(pref);
                if (at != null && isPresentAndAvailable(built, at.stableSiteKey, availability)) {
                    prefCandidate = at.stableSiteKey;
                }
            }
            if (isPresentAndAvailable(built, prefCandidate, availability)) {
                chosenKey = prefCandidate;
                chosenSub = mapGet(keyToSub, chosenKey, "");
            }
        }
        if (chosenKey.isEmpty()) {
            for (Cms.Site s : built.sites) {
                if (s != null && (availability == null || availability.isAvailable(built, s))) {
                    chosenKey = s.key;
                    chosenSub = mapGet(keyToSub, chosenKey, "");
                    break;
                }
            }
        }

        // Atomic revision check & derived-field commit: if ANY newer mutation committed while
        // this build was running, NEVER write back stale state (which would revert toggles or
        // regress revision). Only update derived counts/selection when revision still matches.
        boolean staleBuild = false;
        if (persistDerivedState) {
            synchronized (LOCK) {
                State latest = readState();
                if (latest.revision != startRevision) {
                    staleBuild = true;
                } else {
                    boolean countsChanged = false;
                    for (LoadedSub ls : loaded) {
                        SubscriptionRecord cur = latest.findById(ls.rec.id);
                        if (cur != null) {
                            if (cur.totalSiteCount != ls.rec.totalSiteCount
                                    || cur.loadedSiteCount != ls.rec.loadedSiteCount) {
                                cur.totalSiteCount = ls.rec.totalSiteCount;
                                cur.loadedSiteCount = ls.rec.loadedSiteCount;
                                countsChanged = true;
                            }
                        }
                    }
                    boolean selectionChanged =
                            !chosenKey.equals(latest.currentStableSiteKey)
                                    || !chosenSub.equals(latest.currentSubscriptionId);
                    if (selectionChanged) {
                        latest.currentStableSiteKey = chosenKey;
                        latest.currentSubscriptionId = chosenSub;
                        latest.currentRawSiteKey = mapGet(keyToRaw, chosenKey, "");
                    }
                    if (selectionChanged || countsChanged) {
                        try {
                            saveState(latest);
                        } catch (IOException ignored) {
                        }
                    }
                }
            }
        } else {
            for (LoadedSub ls : loaded) {
                SubscriptionRecord cur = st.findById(ls.rec.id);
                if (cur != null) {
                    cur.totalSiteCount = ls.rec.totalSiteCount;
                    cur.loadedSiteCount = ls.rec.loadedSiteCount;
                }
            }
            st.currentStableSiteKey = chosenKey;
            st.currentSubscriptionId = chosenSub;
            st.currentRawSiteKey = mapGet(keyToRaw, chosenKey, "");
        }

        return new EffectiveBuild(
                built,
                effectiveOrigin,
                chosenKey,
                chosenSub,
                enabledSubs.size(),
                st.subscriptions.size(),
                startRevision,
                staleBuild,
                keyToSub,
                keyToRaw);
    }

    private static void attachBuiltSiteAliases(
            State st,
            ConfigLibrary library,
            List<ConfigLibrary.Entry> libEntries,
            Cms.Config built,
            Map<String, String> keyToSub,
            Map<String, String> keyToRaw,
            Map<String, Set<String>> loadedRawKeysBySubId) {
        if (built == null || built.sites == null || built.sites.isEmpty()) return;
        Map<String, Set<String>> subAliasByStableKey = new HashMap<>();
        for (Map.Entry<String, AliasTarget> entry : st.legacyAliases.entrySet()) {
            String legacyKey = entry.getKey();
            AliasTarget target = entry.getValue();
            if (legacyKey == null || legacyKey.isEmpty() || target == null) continue;
            String stable = target.stableSiteKey;
            if (stable == null || stable.isEmpty()) {
                stable = stableSiteKey(target.subscriptionId, target.rawSiteKey);
            }
            Set<String> set = subAliasByStableKey.get(stable);
            if (set == null) {
                set = new LinkedHashSet<>();
                subAliasByStableKey.put(stable, set);
            }
            set.add(legacyKey);
        }
        // Count raw key ownership across ALL subscriptions (enabled and disabled) so we only
        // grant an implicit raw-key alias when zero ambiguity exists across the whole store.
        Map<String, Integer> rawKeyOwners = new HashMap<>();
        if (library != null && libEntries != null) {
            for (SubscriptionRecord rec : st.subscriptions) {
                Set<String> preloaded =
                        loadedRawKeysBySubId != null ? loadedRawKeysBySubId.get(rec.id) : null;
                if (preloaded != null) {
                    for (String raw : preloaded) {
                        Integer prev = rawKeyOwners.get(raw);
                        rawKeyOwners.put(raw, prev == null ? 1 : prev + 1);
                    }
                    continue;
                }
                ConfigLibrary.Entry e = findLibraryEntry(libEntries, rec);
                if (e == null) continue;
                try {
                    Cms.Config parsed = Cms.parseConfig(library.raw(e), rec.origin);
                    Set<String> seenInSub = new HashSet<>();
                    for (Cms.Site s : parsed.sites) {
                        if (s == null || s.key == null || s.key.isEmpty()) continue;
                        if ("live-only-placeholder".equals(s.key)
                                || "csp_LivePlaceholder".equals(s.api)) {
                            continue;
                        }
                        String raw = stripOwnStableSuffix(rec.id, s.key);
                        if (seenInSub.add(raw)) {
                            Integer prev = rawKeyOwners.get(raw);
                            rawKeyOwners.put(raw, prev == null ? 1 : prev + 1);
                        }
                    }
                } catch (Throwable ignored) {
                }
            }
        }
        for (Cms.Site s : built.sites) {
            if (s == null || s.key == null || s.key.isEmpty()) continue;
            Set<String> aliases = new LinkedHashSet<>();
            aliases.add(s.key);
            Set<String> explicit = subAliasByStableKey.get(s.key);
            if (explicit != null) aliases.addAll(explicit);
            String rawKey = mapGet(keyToRaw, s.key, extractRawKeyFromStable(s.key));
            if (rawKey != null && !rawKey.isEmpty()) {
                AliasTarget mapped = st.legacyAliases.get(rawKey);
                if (mapped != null) {
                    if (s.key.equals(mapped.stableSiteKey)) {
                        aliases.add(rawKey);
                    }
                } else {
                    Integer owners = rawKeyOwners.get(rawKey);
                    if (owners != null && owners == 1) {
                        aliases.add(rawKey);
                    }
                }
            }
            attachTrustedSiteAliases(s, aliases);
        }
    }

    private static String mapGet(Map<String, String> map, String key, String fallback) {
        String v = map != null ? map.get(key) : null;
        return v != null ? v : fallback;
    }

    private static boolean isPresentAndAvailable(
            Cms.Config cfg, String key, SiteAvailability availability) {
        if (cfg == null || key == null || key.isEmpty()) return false;
        for (Cms.Site s : cfg.sites) {
            if (s != null && key.equals(s.key)) {
                return availability == null || availability.isAvailable(cfg, s);
            }
        }
        return false;
    }

    /**
     * Resolves a site key stored in WatchHistory or Favorites without ever cross-contaminating
     * colliding subscriptions or guessing on ambiguous legacy keys.
     */
    SiteResolution resolveStoredSiteKey(
            String storedSiteKey, Cms.Config activeConfig, ConfigLibrary library) {
        String key = storedSiteKey == null ? "" : storedSiteKey.trim();
        if (key.isEmpty()) {
            return new SiteResolution(SiteResolution.STATUS_MISSING, null, null, "", "", "", null);
        }
        State st = readState();

        // 1. Direct match in active enabled config
        if (activeConfig != null) {
            for (Cms.Site s : activeConfig.sites) {
                if (s != null && key.equals(s.key)) {
                    String subId = findSubIdForStableKey(st, key);
                    SubscriptionRecord rec = st.findById(subId);
                    return new SiteResolution(
                            SiteResolution.STATUS_ENABLED,
                            s,
                            rec,
                            extractRawKeyFromStable(key),
                            key,
                            s.name,
                            null);
                }
            }
        }

        // 2. If key is stable-scoped ("raw::shortId"), resolve directly to its owning subscription!
        if (isStableScopedKey(key)) {
            String rawKey = extractRawKeyFromStable(key);
            String shortId = extractShortSubIdFromStable(key);
            for (SubscriptionRecord rec : st.subscriptions) {
                if (stableShortId(rec.id).equals(shortId)) {
                    String siteName = lookupSiteNameInLibrary(library, rec, rawKey);
                    if (siteName == null) siteName = rawKey;
                    if (!rec.enabled) {
                        return new SiteResolution(
                                SiteResolution.STATUS_DISABLED_SUBSCRIPTION,
                                null,
                                rec.copy(),
                                rawKey,
                                key,
                                siteName,
                                null);
                    }
                    if (rec.disabledSiteKeys.contains(rawKey)) {
                        return new SiteResolution(
                                SiteResolution.STATUS_DISABLED_SITE,
                                null,
                                rec.copy(),
                                rawKey,
                                key,
                                siteName,
                                null);
                    }
                    return new SiteResolution(
                            SiteResolution.STATUS_MISSING,
                            null,
                            rec.copy(),
                            rawKey,
                            key,
                            siteName,
                            null);
                }
            }
            return new SiteResolution(
                    SiteResolution.STATUS_MISSING, null, null, rawKey, key, "", null);
        }

        // 3. Check persisted legacy alias table (from upgrade migration)
        AliasTarget alias = st.legacyAliases.get(key);
        if (alias != null) {
            return resolveStoredSiteKey(alias.stableSiteKey, activeConfig, library);
        }

        // 4. Unscoped legacy key not in alias table: scan all subscriptions; ONLY resolve if
        // unique!
        List<SiteResolution.Candidate> matches = new ArrayList<>();
        if (library != null) {
            try {
                List<ConfigLibrary.Entry> entries = library.entries();
                for (SubscriptionRecord rec : st.subscriptions) {
                    ConfigLibrary.Entry e = findLibraryEntry(entries, rec);
                    if (e == null) continue;
                    try {
                        Cms.Config parsed = Cms.parseConfig(library.raw(e), rec.origin);
                        for (Cms.Site s : parsed.sites) {
                            if (s == null || s.key == null || s.key.isEmpty()) continue;
                            if ("live-only-placeholder".equals(s.key)
                                    || "csp_LivePlaceholder".equals(s.api)) {
                                continue;
                            }
                            String normalizedRaw = stripOwnStableSuffix(rec.id, s.key);
                            if (key.equals(normalizedRaw) || key.equals(s.key)) {
                                matches.add(
                                        new SiteResolution.Candidate(
                                                rec.copy(),
                                                normalizedRaw,
                                                stableSiteKey(rec.id, normalizedRaw),
                                                s.name,
                                                rec.disabledSiteKeys.contains(normalizedRaw)));
                                break;
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                }
            } catch (Throwable ignored) {
            }
        }
        if (matches.size() == 1) {
            return resolveStoredSiteKey(matches.get(0).stableSiteKey, activeConfig, library);
        }
        if (matches.size() > 1) {
            return new SiteResolution(
                    SiteResolution.STATUS_AMBIGUOUS, null, null, key, "", "", matches);
        }
        return new SiteResolution(SiteResolution.STATUS_MISSING, null, null, key, "", "", null);
    }

    /** Returns true if the given stable site key belongs to a currently enabled subscription & site. */
    boolean isSiteCurrentlyEnabled(String stableKey) {
        if (stableKey == null || stableKey.trim().isEmpty()) return false;
        State st = readState();
        if (!st.initialized) return true;
        if (st.enabledCount() == 0) return false;
        if (isStableScopedKey(stableKey)) {
            String raw = extractRawKeyFromStable(stableKey);
            String shortId = extractShortSubIdFromStable(stableKey);
            for (SubscriptionRecord r : st.subscriptions) {
                if (stableShortId(r.id).equals(shortId)) {
                    return r.enabled && !r.disabledSiteKeys.contains(raw);
                }
            }
            return false;
        }
        return true;
    }

    /** Lists all sites inside one specific subscription (for "管理线路" independent site toggle). */
    List<Cms.Site> listSitesInSubscription(ConfigLibrary library, SubscriptionRecord rec) {
        if (library == null || rec == null) return Collections.emptyList();
        try {
            ConfigLibrary.Entry entry = findLibraryEntry(library.entries(), rec);
            if (entry == null) return Collections.emptyList();
            String raw = library.raw(entry);
            if (rawJsonHasDerivedRuntimeSiteKeys(raw)
                    && tryRecoverDamagedSubscriptionRaw(library, rec)) {
                entry = findLibraryEntry(library.entries(), rec);
                if (entry == null) return Collections.emptyList();
                raw = library.raw(entry);
            }
            Cms.Config parsed = Cms.parseConfig(raw, rec.origin);
            List<Cms.Site> out = new ArrayList<>();
            for (Cms.Site s : parsed.sites) {
                if (s == null || s.key == null || s.key.isEmpty()) continue;
                if ("live-only-placeholder".equals(s.key) || "csp_LivePlaceholder".equals(s.api)) {
                    continue;
                }
                s.key = stripOwnStableSuffix(rec.id, s.key);
                out.add(s);
            }
            return out;
        } catch (Throwable ignored) {
            return Collections.emptyList();
        }
    }

    private static String findSubIdForStableKey(State st, String stableKey) {
        if (!isStableScopedKey(stableKey)) return st.currentSubscriptionId;
        String shortId = extractShortSubIdFromStable(stableKey);
        for (SubscriptionRecord r : st.subscriptions) {
            if (stableShortId(r.id).equals(shortId)) return r.id;
        }
        return "";
    }

    private static String lookupSiteNameInLibrary(
            ConfigLibrary library, SubscriptionRecord rec, String rawKey) {
        if (library == null || rec == null || rawKey == null) return null;
        try {
            ConfigLibrary.Entry entry = findLibraryEntry(library.entries(), rec);
            if (entry == null) return null;
            Cms.Config parsed = Cms.parseConfig(library.raw(entry), rec.origin);
            for (Cms.Site s : parsed.sites) {
                if (s != null && rawKey.equals(stripOwnStableSuffix(rec.id, s.key))) return s.name;
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    private static int[] computeFairLimits(int[] sizes, int totalSites, int cap) {
        int count = sizes.length;
        if (totalSites <= cap) return sizes.clone();
        int[] limits = new int[count];
        int remaining = cap;
        boolean[] done = new boolean[count];
        int active = count;
        while (active > 0 && remaining > 0) {
            int share = Math.max(1, remaining / active);
            boolean progressed = false;
            for (int i = 0; i < count; i++) {
                if (done[i]) continue;
                int want = sizes[i] - limits[i];
                if (want <= share) {
                    limits[i] += want;
                    remaining -= want;
                    done[i] = true;
                    active--;
                    progressed = true;
                }
            }
            if (!progressed) {
                for (int i = 0; i < count && remaining > 0; i++) {
                    if (done[i]) continue;
                    int grant = Math.min(sizes[i] - limits[i], share);
                    limits[i] += grant;
                    remaining -= grant;
                }
                break;
            }
        }
        return limits;
    }

    private static String deriveFriendlyName(String origin, Cms.Config parsed, String fallback) {
        String derived = SubscriptionManager.deriveGroupName("", origin, parsed, 1, null);
        return (derived == null || derived.trim().isEmpty()) ? fallback : derived.trim();
    }

    private static JSONObject parseRootOrEmpty(String raw) {
        if (raw == null || raw.trim().isEmpty()) return new JSONObject();
        try {
            String clean = Cms.withoutComments(raw).trim();
            if (clean.startsWith("{")) return new JSONObject(clean);
        } catch (Throwable ignored) {
        }
        return new JSONObject();
    }

    private static JSONObject copyJson(JSONObject src) {
        if (src == null) return new JSONObject();
        try {
            return new JSONObject(src.toString());
        } catch (Exception e) {
            return new JSONObject();
        }
    }

    private static String readText(File file, int limit) throws IOException {
        if (file.length() > limit) throw new IOException("多源状态文件过大");
        try (FileInputStream in = new FileInputStream(file);
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (out.size() + n > limit) throw new IOException("多源状态文件过大");
                out.write(buf, 0, n);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private void writeAtomic(File target, String raw) throws IOException {
        if (!directory.exists() && !directory.mkdirs()) {
            throw new IOException("无法创建多源配置目录");
        }
        File pending = File.createTempFile("tv-multisource-", ".tmp", directory);
        try {
            try (FileOutputStream out = new FileOutputStream(pending)) {
                out.write(raw.getBytes(StandardCharsets.UTF_8));
                out.getFD().sync();
            }
            if (!pending.renameTo(target)) {
                File backup = new File(directory, target.getName() + ".bak");
                if (!target.isFile()
                        || (backup.exists() && !backup.delete())
                        || !target.renameTo(backup)) {
                    throw new IOException("无法保存多源配置，原文件已保留");
                }
                if (!pending.renameTo(target)) {
                    backup.renameTo(target);
                    throw new IOException("无法保存多源配置，原文件已保留");
                }
                backup.delete();
            }
        } finally {
            pending.delete();
        }
    }
}

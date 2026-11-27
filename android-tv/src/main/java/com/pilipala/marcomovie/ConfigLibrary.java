package com.pilipala.marcomovie;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import org.json.*;

/** Independent saved subscriptions; each retains its own base URL, spider and account settings. */
final class ConfigLibrary {
    /** Unified single-subscription UTF-8 byte cap shared by download, parse, storage & readback. */
    static final int MAX_SUBSCRIPTION_BYTES = 16 * 1024 * 1024;

    /** Unified WAL preferences/history replay byte cap matching SettingsScreen.MAX_BACKUP_BYTES. */
    static final int MAX_RESTORE_PREFS_BYTES = 64 * 1024 * 1024;

    /**
     * Preference key atomically persisted alongside restored settings/history to record the exact
     * restore transaction ID already committed to {@code SharedPreferences} (kept outside {@link
     * Prefs#KEYS} so backup schema counts stay invariant).
     */
    static final String RESTORE_TX_APPLIED_ID_PREF = "restore_tx_applied_id";

    /** Internal WAL-only metadata key embedded in {@code new-prefs.json} for startup replay. */
    static final String RESTORE_TX_META_KEY = "__marco_restore_tx_id";

    private static final String RUNTIME_SITE_KEY_SEPARATOR = "::";
    private static final int MAX_CLEAN_HISTORY = 8;
    private static final String RESTORE_TX_DIR = "restore-tx";
    private static final String RESTORE_TX_MANIFEST = "manifest.json";
    private static final String PHASE_PREPARED = "PREPARED";
    private static final String PHASE_COMMITTING_PREFS = "COMMITTING_PREFS";
    private static final String PHASE_PREFS_PERSISTED = "PREFS_PERSISTED";
    private static final Object LOCK = new Object();

    interface PrefsVisibilityProbe {
        boolean areNewPrefsVisible();
    }

    private static final class ActiveRestoreState {
        final String txId;
        final boolean oldIndexExisted;
        final boolean oldStateExisted;
        String phase;
        volatile PrefsVisibilityProbe prefsVisibilityProbe;
        volatile boolean prefsVisible;
        volatile boolean prefsPersisted;

        ActiveRestoreState(
                String txId, String phase, boolean oldIndexExisted, boolean oldStateExisted) {
            this.txId = txId;
            this.phase = phase;
            this.oldIndexExisted = oldIndexExisted;
            this.oldStateExisted = oldStateExisted;
        }
    }

    /**
     * Tracks restore transactions currently executing in this JVM process (keyed by canonical
     * config directory) so concurrent readers never mistake an active restore for a crashed prior
     * process and roll it back.
     */
    private static final Map<String, ActiveRestoreState> ACTIVE_IN_PROCESS_TX = new HashMap<>();

    static String canonicalDirKey(File configDir) {
        if (configDir == null) return "";
        try {
            return configDir.getCanonicalPath();
        } catch (IOException ignored) {
            return configDir.getAbsolutePath();
        }
    }

    static boolean isRestoreActiveInProcess(File configDir) {
        if (configDir == null) return false;
        synchronized (LOCK) {
            return ACTIVE_IN_PROCESS_TX.containsKey(canonicalDirKey(configDir));
        }
    }

    /**
     * Returns a consistent file for concurrent readers while an in-process restore transaction is
     * active: keeps readers on the pre-restore snapshot across both {@code PREPARED} and pre-commit
     * {@code COMMITTING_PREFS} until preferences &amp; watch history have actually been persisted
     * ({@link RestoreTransaction#markPrefsPersisted()}), then exposes the live target so concurrent
     * readers always observe one single generation across subscriptions, preferences, and history.
     */
    static File resolveLiveOrOldSnapshotForRead(
            File configDir, File liveFile, String oldTxFileName, boolean isStateFile) {
        if (configDir == null) return liveFile;
        synchronized (LOCK) {
            ActiveRestoreState active = ACTIVE_IN_PROCESS_TX.get(canonicalDirKey(configDir));
            if (active == null) return liveFile;
            boolean visible = active.prefsPersisted || active.prefsVisible;
            if (!visible) {
                PrefsVisibilityProbe probe = active.prefsVisibilityProbe;
                if (probe != null) {
                    try {
                        visible = probe.areNewPrefsVisible();
                    } catch (Throwable ignored) {
                        visible = false;
                    }
                }
            }
            if (!visible) {
                boolean existed = isStateFile ? active.oldStateExisted : active.oldIndexExisted;
                if (!existed) return null;
                return new File(new File(configDir, RESTORE_TX_DIR), oldTxFileName);
            }
            return liveFile;
        }
    }

    interface CommitFaultInjector {
        void afterStep(String step) throws Exception;
    }

    interface PrefsReplayCallback {
        void replayPrefs(JSONObject newPrefs) throws Exception;
    }

    interface PrefsAppliedCheck {
        boolean isTxApplied(String txId);
    }

    /** Test-only hook to simulate mid-commit write failures or interrupted commits. */
    static volatile CommitFaultInjector restoreCommitFaultInjector;

    /**
     * Test-only marker error that bypasses in-process rollback to simulate abrupt process death
     * mid-commit so cold-start recovery can be verified end-to-end.
     */
    static final class SimulatedProcessKill extends Error {
        SimulatedProcessKill(String message) {
            super(message);
        }
    }

    static final class StagedSubInput {
        final String raw;
        final File rawFile;
        final String precomputedId;
        final String precomputedDigest;
        final boolean precomputedDerivedKeys;
        final String origin;
        final String name;
        final String selected;
        final long updatedAt;

        StagedSubInput(String raw, String origin, String name, String selected, long updatedAt) {
            this.raw = raw;
            this.rawFile = null;
            this.precomputedId = null;
            this.precomputedDigest = null;
            this.precomputedDerivedKeys = false;
            this.origin = origin == null ? "" : origin.trim();
            this.name = name == null ? "" : name;
            this.selected = selected == null ? "" : selected;
            this.updatedAt = Math.max(1L, updatedAt);
        }

        StagedSubInput(
                File rawFile,
                String precomputedId,
                String precomputedDigest,
                boolean precomputedDerivedKeys,
                String origin,
                String name,
                String selected,
                long updatedAt) {
            this.raw = null;
            this.rawFile = rawFile;
            this.precomputedId = precomputedId;
            this.precomputedDigest = precomputedDigest;
            this.precomputedDerivedKeys = precomputedDerivedKeys;
            this.origin = origin == null ? "" : origin.trim();
            this.name = name == null ? "" : name;
            this.selected = selected == null ? "" : selected;
            this.updatedAt = Math.max(1L, updatedAt);
        }
    }

    static final class StagedRestoreBatch {
        final File directory;
        final List<Entry> entries;
        final String newIndexJson;
        final List<File> createdFiles;

        StagedRestoreBatch(
                File directory, List<Entry> entries, String newIndexJson, List<File> createdFiles) {
            this.directory = directory;
            this.entries = Collections.unmodifiableList(entries);
            this.newIndexJson = newIndexJson;
            this.createdFiles = createdFiles;
        }

        /**
         * Deletes only newly created content files that are NOT referenced by the currently active
         * {@code subscriptions/index.json} on disk. Never deletes any content file referenced by
         * the live index.
         */
        void cleanupCreatedFiles() {
            synchronized (LOCK) {
                Set<String> activeReferenced = readActiveIndexedContentNames(directory);
                for (File f : createdFiles) {
                    if (f != null && f.isFile() && !activeReferenced.contains(f.getName())) {
                        f.delete();
                    }
                }
            }
        }
    }

    static Set<String> readActiveIndexedContentNames(File subsDir) {
        Set<String> referenced = new HashSet<>();
        if (subsDir == null) return referenced;
        File indexTarget = new File(subsDir, "index.json");
        if (!indexTarget.isFile()) return referenced;
        try {
            JSONArray idx = new JSONArray(read(indexTarget, 1024 * 1024));
            for (int i = 0; i < idx.length(); i++) {
                Entry e = new Entry(idx.getJSONObject(i));
                referenced.add(e.id + "-" + e.digest + ".json");
            }
        } catch (Throwable ignored) {
        }
        return referenced;
    }

    /**
     * Handle for a durable two-phase WAL restore transaction covering {@code
     * subscriptions/index.json}, {@code subscriptions/tv_multi_source_v1.json}, {@code
     * config.json}, and preferences/watch-history replay.
     *
     * <p>Phase 1 ({@code PREPARED}) writes file targets; a crash before preferences start rolls
     * back to the pre-restore snapshot. Phase 2 ({@code COMMITTING_PREFS}) records the new
     * preferences snapshot in the WAL; an explicit in-process error calls {@link #rollback()},
     * while an abrupt process kill during/after preference writes rolls forward cleanly on cold
     * start so files, preferences, and watch history always converge to one consistent generation.
     */
    static final class RestoreTransaction {
        final File configDir;
        final String txId;
        private final ActiveRestoreState stateRef;
        private boolean finalized;
        private boolean rolledBack;

        RestoreTransaction(File configDir, String txId, ActiveRestoreState stateRef) {
            this.configDir = configDir;
            this.txId = txId;
            this.stateRef = stateRef;
        }

        boolean isFinalized() {
            return finalized;
        }

        /**
         * Updates the in-process concurrent-read visibility boundary immediately before/on failure
         * of {@code SharedPreferences.Editor.commit()/apply()} without acquiring {@link #LOCK} (so
         * lock ordering with {@link WatchHistory#PERSISTENCE_LOCK} is never inverted).
         */
        void setPrefsVisible(boolean visible) {
            if (stateRef != null) {
                stateRef.prefsVisible = visible;
            }
        }

        /**
         * Installs or clears a lock-free live visibility probe checked by concurrent readers during
         * {@code SharedPreferences.Editor.commit()/apply()} so readers observe the pre-restore
         * snapshot before {@code SharedPreferences} flips in memory and switch immediately to the
         * live new snapshot the moment new preferences become visible.
         */
        void setPrefsVisibilityProbe(PrefsVisibilityProbe probe) {
            if (stateRef != null) {
                stateRef.prefsVisibilityProbe = probe;
            }
        }

        void markCommittingPrefs(String newPrefsJson) throws Exception {
            synchronized (LOCK) {
                if (finalized || rolledBack) {
                    throw new IOException("还原事务状态无效，无法进入偏好写入阶段");
                }
                String dirKey = canonicalDirKey(configDir);
                ActiveRestoreState active = ACTIVE_IN_PROCESS_TX.get(dirKey);
                if (active == null || !txId.equals(active.txId)) {
                    throw new IOException("还原事务所有权已失效，无法进入偏好写入阶段");
                }
                File txDir = new File(configDir, RESTORE_TX_DIR);
                File manifestFile = new File(txDir, RESTORE_TX_MANIFEST);
                if (!manifestFile.isFile()) {
                    throw new IOException("还原事务清单丢失，无法进入偏好写入阶段");
                }
                JSONObject manifest = new JSONObject(read(manifestFile, 1024 * 1024));
                if (!txId.equals(manifest.optString("txId", ""))) {
                    throw new IOException("还原事务编号不匹配，无法进入偏好写入阶段");
                }
                boolean hasPrefs = newPrefsJson != null && !newPrefsJson.isEmpty();
                if (hasPrefs) {
                    String persistedPrefsJson = newPrefsJson;
                    try {
                        JSONObject snapObj = new JSONObject(newPrefsJson);
                        snapObj.put(RESTORE_TX_META_KEY, txId);
                        persistedPrefsJson = snapObj.toString();
                    } catch (Throwable ignored) {
                    }
                    writeBytesInDir(
                            txDir,
                            new File(txDir, "new-prefs.json"),
                            persistedPrefsJson.getBytes(StandardCharsets.UTF_8));
                }
                manifest.put("phase", PHASE_COMMITTING_PREFS);
                manifest.put("hasNewPrefs", hasPrefs);
                manifest.put("prefsPersisted", false);
                writeBytesInDir(
                        txDir, manifestFile, manifest.toString().getBytes(StandardCharsets.UTF_8));
                active.phase = PHASE_COMMITTING_PREFS;
            }
            CommitFaultInjector hook = restoreCommitFaultInjector;
            if (hook != null) {
                try {
                    hook.afterStep("committing_prefs");
                } catch (SimulatedProcessKill kill) {
                    synchronized (LOCK) {
                        clearActiveRestoreIfOwnedLocked(configDir, txId);
                    }
                    throw kill;
                }
            }
        }

        void markPrefsPersisted() throws Exception {
            synchronized (LOCK) {
                if (finalized || rolledBack) {
                    throw new IOException("还原事务状态无效，无法确认偏好落盘");
                }
                String dirKey = canonicalDirKey(configDir);
                ActiveRestoreState active = ACTIVE_IN_PROCESS_TX.get(dirKey);
                if (active == null || !txId.equals(active.txId)) {
                    throw new IOException("还原事务所有权已失效，无法确认偏好落盘");
                }
                File txDir = new File(configDir, RESTORE_TX_DIR);
                File manifestFile = new File(txDir, RESTORE_TX_MANIFEST);
                if (manifestFile.isFile()) {
                    try {
                        JSONObject manifest = new JSONObject(read(manifestFile, 1024 * 1024));
                        if (txId.equals(manifest.optString("txId", ""))) {
                            manifest.put("phase", PHASE_PREFS_PERSISTED);
                            manifest.put("prefsPersisted", true);
                            writeBytesInDir(
                                    txDir,
                                    manifestFile,
                                    manifest.toString().getBytes(StandardCharsets.UTF_8));
                        }
                    } catch (Throwable ignored) {
                        // Even if disk manifest update fails here, SharedPreferences already
                        // atomically persisted RESTORE_TX_APPLIED_ID_PREF = txId.
                    }
                }
                active.phase = PHASE_PREFS_PERSISTED;
                active.prefsVisibilityProbe = null;
                active.prefsVisible = true;
                active.prefsPersisted = true;
            }
            CommitFaultInjector hook = restoreCommitFaultInjector;
            if (hook != null) {
                try {
                    hook.afterStep("prefs_persisted");
                } catch (SimulatedProcessKill kill) {
                    synchronized (LOCK) {
                        clearActiveRestoreIfOwnedLocked(configDir, txId);
                    }
                    throw kill;
                }
            }
        }

        /**
         * Releases in-process transaction ownership after preferences &amp; watch history have
         * ALREADY been durably persisted when final WAL cleanup fails: marks the WAL as {@code
         * PREFS_PERSISTED} (never rolling back files and never allowing next startup to replay
         * stale preferences over subsequent user progress or subscription updates).
         */
        void abandonFinalizeKeepForwardWal() {
            synchronized (LOCK) {
                if (finalized || rolledBack) return;
                File txDir = new File(configDir, RESTORE_TX_DIR);
                File manifestFile = new File(txDir, RESTORE_TX_MANIFEST);
                if (manifestFile.isFile()) {
                    try {
                        JSONObject manifest = new JSONObject(read(manifestFile, 1024 * 1024));
                        if (txId.equals(manifest.optString("txId", ""))
                                && !PHASE_PREFS_PERSISTED.equals(manifest.optString("phase", ""))) {
                            manifest.put("phase", PHASE_PREFS_PERSISTED);
                            manifest.put("prefsPersisted", true);
                            writeBytesInDir(
                                    txDir,
                                    manifestFile,
                                    manifest.toString().getBytes(StandardCharsets.UTF_8));
                        }
                    } catch (Throwable ignored) {
                    }
                }
                if (stateRef != null) {
                    stateRef.phase = PHASE_PREFS_PERSISTED;
                    stateRef.prefsVisibilityProbe = null;
                    stateRef.prefsVisible = true;
                    stateRef.prefsPersisted = true;
                }
                clearActiveRestoreIfOwnedLocked(configDir, txId);
            }
        }

        void finalizeCommit() throws IOException {
            synchronized (LOCK) {
                if (finalized) return;
                if (rolledBack) throw new IOException("还原事务已回滚，无法提交");
                String dirKey = canonicalDirKey(configDir);
                ActiveRestoreState active = ACTIVE_IN_PROCESS_TX.get(dirKey);
                if (active == null || !txId.equals(active.txId)) {
                    throw new IOException("还原事务所有权已丢失，无法确认提交");
                }
                File txDir = new File(configDir, RESTORE_TX_DIR);
                File manifestFile = new File(txDir, RESTORE_TX_MANIFEST);
                if (!manifestFile.isFile()) {
                    throw new IOException("还原事务清单已被移除，无法确认提交");
                }
                try {
                    JSONObject manifest = new JSONObject(read(manifestFile, 1024 * 1024));
                    if (!txId.equals(manifest.optString("txId", ""))) {
                        throw new IOException("还原事务编号不匹配，无法确认提交");
                    }
                } catch (IOException ioe) {
                    throw ioe;
                } catch (Exception parseErr) {
                    throw new IOException("还原事务清单损坏，无法确认提交", parseErr);
                }
                if (!manifestFile.delete()) {
                    throw new IOException("无法清理还原事务标记");
                }
                deleteDirectoryRecursive(txDir);
                clearActiveRestoreIfOwnedLocked(configDir, txId);
                finalized = true;
            }
        }

        void rollback() {
            synchronized (LOCK) {
                if (finalized || rolledBack) return;
                if (stateRef != null) {
                    stateRef.prefsVisibilityProbe = null;
                    stateRef.prefsVisible = false;
                }
                rollbackRestoreTransactionLocked(configDir, txId);
                clearActiveRestoreIfOwnedLocked(configDir, txId);
                rolledBack = true;
            }
        }
    }

    private static void clearActiveRestoreIfOwnedLocked(File configDir, String txId) {
        String dirKey = canonicalDirKey(configDir);
        ActiveRestoreState active = ACTIVE_IN_PROCESS_TX.get(dirKey);
        if (active != null && (txId == null || txId.equals(active.txId))) {
            ACTIVE_IN_PROCESS_TX.remove(dirKey);
        }
    }

    static boolean isDerivedRuntimeSiteKey(String key) {
        if (key == null) return false;
        int idx = key.lastIndexOf(RUNTIME_SITE_KEY_SEPARATOR);
        if (idx <= 0 || idx + RUNTIME_SITE_KEY_SEPARATOR.length() + 8 != key.length()) {
            return false;
        }
        String tail = key.substring(idx + RUNTIME_SITE_KEY_SEPARATOR.length());
        for (int i = 0; i < tail.length(); i++) {
            char c = tail.charAt(i);
            boolean hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            if (!hex) return false;
        }
        return true;
    }

    static boolean rawJsonHasDerivedRuntimeSiteKeys(String raw) {
        if (raw == null || !raw.contains(RUNTIME_SITE_KEY_SEPARATOR)) return false;
        try {
            String trimmed = stripJsonComments(raw).trim();
            if (!trimmed.startsWith("{")) return false;
            JSONObject root = new JSONObject(trimmed);
            JSONArray sites = root.optJSONArray("sites");
            if (sites == null) return false;
            for (int i = 0; i < sites.length(); i++) {
                JSONObject o = sites.optJSONObject(i);
                if (o != null && isDerivedRuntimeSiteKey(o.optString("key", ""))) {
                    return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static String stripJsonComments(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        if (raw.indexOf("//") < 0 && raw.indexOf("/*") < 0) return raw;
        StringBuilder out = new StringBuilder(raw.length());
        boolean inString = false;
        boolean escaped = false;
        int len = raw.length();
        for (int i = 0; i < len; i++) {
            char c = raw.charAt(i);
            if (inString) {
                out.append(c);
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    inString = false;
                }
                continue;
            }
            if (c == '"') {
                inString = true;
                out.append(c);
                continue;
            }
            if (c == '/' && i + 1 < len) {
                char next = raw.charAt(i + 1);
                if (next == '/') {
                    i += 2;
                    while (i < len && raw.charAt(i) != '\n' && raw.charAt(i) != '\r') i++;
                    if (i < len) out.append(raw.charAt(i));
                    continue;
                }
                if (next == '*') {
                    i += 2;
                    while (i + 1 < len && !(raw.charAt(i) == '*' && raw.charAt(i + 1) == '/')) i++;
                    i++;
                    continue;
                }
            }
            out.append(c);
        }
        return out.toString();
    }

    static final class Entry {
        final String id, origin, name, selected, digest;
        final long updated;
        final List<String> cleanHistory;

        Entry(JSONObject value) throws Exception {
            id = value.getString("id");
            origin = value.getString("origin");
            name = value.getString("name");
            selected = value.optString("selected");
            digest = value.getString("digest");
            updated = Math.max(1L, value.optLong("updated", 1L));
            if (!id.matches("[0-9a-f]{64}") || !digest.matches("[0-9a-f]{64}"))
                throw new IOException("保存的订阅索引损坏，原文件已保留");
            List<String> hist = new ArrayList<>();
            JSONArray histArr = value.optJSONArray("cleanHistory");
            if (histArr != null) {
                for (int i = 0; i < histArr.length(); i++) {
                    String d = histArr.optString(i, "").trim();
                    if (d.matches("[0-9a-f]{64}") && !hist.contains(d)) {
                        hist.add(d);
                    }
                }
            }
            cleanHistory = Collections.unmodifiableList(hist);
        }
    }

    final File directory;

    ConfigLibrary(File configDirectory) {
        directory = new File(configDirectory, "subscriptions");
    }

    static String hash(String value) throws Exception {
        return hashBytes(value.getBytes(StandardCharsets.UTF_8));
    }

    static String hashBytes(byte[] rawBytes) throws Exception {
        byte[] bytes = MessageDigest.getInstance("SHA-256").digest(rawBytes);
        StringBuilder out = new StringBuilder(64);
        for (byte b : bytes) out.append(String.format(Locale.ROOT, "%02x", b & 255));
        return out.toString();
    }

    static boolean isLocalFileOrigin(String origin) {
        return origin != null && origin.trim().toLowerCase(Locale.ROOT).startsWith("file:");
    }

    static String identity(String origin, String raw) throws Exception {
        return hash(
                origin == null || origin.trim().isEmpty()
                        ? "local:" + raw
                        : "url:" + origin.trim());
    }

    private JSONArray index() throws Exception {
        File configDir = directory.getParentFile();
        recoverInterruptedRestoreIfNeeded(configDir);
        File target = new File(directory, "index.json");
        File file = resolveLiveOrOldSnapshotForRead(configDir, target, "old-index.json", false);
        if (file == null) return new JSONArray();
        if (file == target && !file.exists() && new File(directory, "index.json.bak").exists()) {
            file = new File(directory, "index.json.bak");
        }
        if (!file.exists()) return new JSONArray();
        return new JSONArray(read(file, 1024 * 1024));
    }

    List<Entry> entries() throws Exception {
        synchronized (LOCK) {
            JSONArray items = index();
            List<Entry> out = new ArrayList<>();
            for (int i = 0; i < items.length(); i++) out.add(new Entry(items.getJSONObject(i)));
            return out;
        }
    }

    Entry remember(String raw, String origin, String name, String selected) throws Exception {
        return remember(raw, origin, name, selected, System.currentTimeMillis());
    }

    Entry remember(String raw, String origin, String name, String selected, long updatedAt)
            throws Exception {
        if (raw == null) throw new IOException("订阅正文为空");
        byte[] rawBytes = raw.getBytes(StandardCharsets.UTF_8);
        if (rawBytes.length > MAX_SUBSCRIPTION_BYTES) {
            throw new IOException("保存的订阅文件过大（超过 16 MB 限制），原订阅已保留");
        }
        synchronized (LOCK) {
            String source = origin == null ? "" : origin.trim();
            String id = identity(source, raw), digest = hashBytes(rawBytes);
            long stamp = Math.max(1L, updatedAt);
            JSONArray items = index();
            int position = items.length();
            Entry previousEntry = null;
            for (int i = 0; i < items.length(); i++) {
                Entry existing = new Entry(items.getJSONObject(i));
                if (id.equals(existing.id)) {
                    position = i;
                    previousEntry = existing;
                    break;
                }
            }
            JSONArray cleanHistory = new JSONArray();
            List<String> seenHistory = new ArrayList<>();
            boolean incomingClean = !rawJsonHasDerivedRuntimeSiteKeys(raw);
            if (incomingClean) {
                seenHistory.add(digest);
            }
            if (previousEntry != null) {
                for (String d : previousEntry.cleanHistory) {
                    if (seenHistory.size() >= MAX_CLEAN_HISTORY) break;
                    if (!seenHistory.contains(d)) seenHistory.add(d);
                }
                if (previousEntry.cleanHistory.isEmpty()
                        && !seenHistory.contains(previousEntry.digest)
                        && seenHistory.size() < MAX_CLEAN_HISTORY) {
                    // Legacy pre-cleanHistory entry: verify before recording its digest in chain.
                    try {
                        String prevRaw = raw(previousEntry);
                        if (!rawJsonHasDerivedRuntimeSiteKeys(prevRaw)) {
                            seenHistory.add(previousEntry.digest);
                        }
                    } catch (Throwable ignored) {
                    }
                }
            }
            for (String d : seenHistory) cleanHistory.put(d);
            JSONObject value =
                    new JSONObject()
                            .put("id", id)
                            .put("origin", source)
                            .put("name", name)
                            .put("selected", selected == null ? "" : selected)
                            .put("digest", digest)
                            .put("updated", stamp)
                            .put("cleanHistory", cleanHistory);
            Entry saved = new Entry(value);
            // Content files are immutable: stage candidate content, read back & verify digest
            // within MAX_SUBSCRIPTION_BYTES BEFORE committing index.json so a failed or oversized
            // write can never corrupt or empty an existing subscription.
            File content = content(saved);
            boolean createdContent = false;
            if (!content.exists()) {
                writeBytes(content, rawBytes);
                createdContent = true;
            } else if (!content.isFile()) {
                throw new IOException("无法写入订阅正文（目标不是文件）：" + content.getName());
            }
            try {
                verifyContentFile(content, digest, MAX_SUBSCRIPTION_BYTES);
            } catch (Exception verifyError) {
                if (createdContent) content.delete();
                throw verifyError;
            }
            items.put(position, value);
            write(new File(directory, "index.json"), items.toString());
            return saved;
        }
    }

    /**
     * Stages all immutable subscription content files for a backup restore, verifying every file on
     * disk BEFORE touching {@code index.json}, {@code tv_multi_source.json}, or {@code config.json}.
     * On any write or verification error, removes every content file created during this batch and
     * leaves the existing library completely untouched.
     */
    StagedRestoreBatch stageRestoreBatch(List<StagedSubInput> inputs, boolean replaceAllEntries)
            throws Exception {
        if (inputs == null) {
            throw new IOException("待还原订阅列表为空");
        }
        synchronized (LOCK) {
            recoverInterruptedRestoreIfNeeded(directory.getParentFile());
            if (!directory.exists() && !directory.mkdirs()) {
                throw new IOException("无法创建订阅目录");
            }
            JSONArray baseItems = replaceAllEntries ? new JSONArray() : index();
            List<JSONObject> mergedJson = new ArrayList<>();
            Map<String, Integer> posById = new HashMap<>();
            Map<String, Entry> prevById = new HashMap<>();
            for (int i = 0; i < baseItems.length(); i++) {
                JSONObject obj = baseItems.getJSONObject(i);
                Entry existing = new Entry(obj);
                posById.put(existing.id, mergedJson.size());
                prevById.put(existing.id, existing);
                mergedJson.add(obj);
            }

            List<File> createdFiles = new ArrayList<>();
            Set<String> batchSeenIds = new HashSet<>();
            try {
                for (StagedSubInput input : inputs) {
                    if (input == null || (input.raw == null && input.rawFile == null)) {
                        throw new IOException("备份订阅正文为空");
                    }
                    String source = input.origin;
                    byte[] rawBytes = null;
                    String id;
                    String digest;
                    boolean hasDerived;
                    if (input.rawFile != null) {
                        if (!input.rawFile.isFile() || input.rawFile.length() <= 0L) {
                            throw new IOException("暂存的备份订阅文件不可读");
                        }
                        if (input.rawFile.length() > MAX_SUBSCRIPTION_BYTES) {
                            throw new IOException("保存的订阅文件过大（超过 16 MB 限制），原订阅已保留");
                        }
                        id = input.precomputedId;
                        digest = input.precomputedDigest;
                        hasDerived = input.precomputedDerivedKeys;
                        if (id == null || id.isEmpty() || digest == null || digest.isEmpty()) {
                            rawBytes = readRawBytes(input.rawFile, MAX_SUBSCRIPTION_BYTES);
                            String loaded = new String(rawBytes, StandardCharsets.UTF_8);
                            id = identity(source, loaded);
                            digest = hashBytes(rawBytes);
                            hasDerived = rawJsonHasDerivedRuntimeSiteKeys(loaded);
                        }
                    } else {
                        rawBytes = input.raw.getBytes(StandardCharsets.UTF_8);
                        if (rawBytes.length > MAX_SUBSCRIPTION_BYTES) {
                            throw new IOException("保存的订阅文件过大（超过 16 MB 限制），原订阅已保留");
                        }
                        id = identity(source, input.raw);
                        digest = hashBytes(rawBytes);
                        hasDerived = rawJsonHasDerivedRuntimeSiteKeys(input.raw);
                    }
                    if (!batchSeenIds.add(id)) {
                        throw new IOException("备份中存在重复来源或冲突订阅 ID：" + id);
                    }
                    Entry previousEntry = prevById.get(id);
                    JSONArray cleanHistory = new JSONArray();
                    List<String> seenHistory = new ArrayList<>();
                    if (!hasDerived) {
                        seenHistory.add(digest);
                    }
                    if (!replaceAllEntries && previousEntry != null) {
                        for (String d : previousEntry.cleanHistory) {
                            if (seenHistory.size() >= MAX_CLEAN_HISTORY) break;
                            if (!seenHistory.contains(d)) seenHistory.add(d);
                        }
                    }
                    for (String d : seenHistory) cleanHistory.put(d);
                    JSONObject value =
                            new JSONObject()
                                    .put("id", id)
                                    .put("origin", source)
                                    .put("name", input.name)
                                    .put("selected", input.selected)
                                    .put("digest", digest)
                                    .put("updated", input.updatedAt)
                                    .put("cleanHistory", cleanHistory);
                    Entry saved = new Entry(value);
                    File contentFile = content(saved);
                    if (contentFile.exists()) {
                        if (!contentFile.isFile()) {
                            throw new IOException(
                                    "无法写入订阅正文（目标不可写）：" + contentFile.getAbsolutePath());
                        }
                        try {
                            verifyContentFile(contentFile, digest, MAX_SUBSCRIPTION_BYTES);
                        } catch (Exception corruptExisting) {
                            if (input.rawFile != null) {
                                copyFileAtomicInDir(directory, input.rawFile, contentFile);
                            } else {
                                writeBytes(contentFile, rawBytes);
                            }
                            verifyContentFile(contentFile, digest, MAX_SUBSCRIPTION_BYTES);
                        }
                    } else {
                        if (input.rawFile != null) {
                            copyFileAtomicInDir(directory, input.rawFile, contentFile);
                        } else {
                            writeBytes(contentFile, rawBytes);
                        }
                        createdFiles.add(contentFile);
                        verifyContentFile(contentFile, digest, MAX_SUBSCRIPTION_BYTES);
                    }
                    Integer existingPos = posById.get(id);
                    if (existingPos != null) {
                        mergedJson.set(existingPos, value);
                    } else {
                        posById.put(id, mergedJson.size());
                        mergedJson.add(value);
                    }
                    prevById.put(id, saved);
                }
                JSONArray finalArr = new JSONArray();
                List<Entry> finalEntries = new ArrayList<>(mergedJson.size());
                for (JSONObject o : mergedJson) {
                    finalArr.put(o);
                    finalEntries.add(new Entry(o));
                }
                return new StagedRestoreBatch(
                        directory, finalEntries, finalArr.toString(), createdFiles);
            } catch (Throwable err) {
                Set<String> activeReferenced = readActiveIndexedContentNames(directory);
                for (File f : createdFiles) {
                    if (f != null && f.isFile() && !activeReferenced.contains(f.getName())) {
                        f.delete();
                    }
                }
                if (err instanceof Exception) throw (Exception) err;
                throw new IOException("备份订阅暂存失败：" + err.getMessage(), err);
            }
        }
    }

    /**
     * Begins a durable WAL restore transaction, writes {@code subscriptions/index.json}, {@code
     * subscriptions/tv_multi_source_v1.json}, and {@code config.json}, and leaves the WAL manifest
     * armed until the caller invokes {@link RestoreTransaction#finalizeCommit()} (after preferences
     * are written) or {@link RestoreTransaction#rollback()} on error.
     */
    static RestoreTransaction beginAndWriteRestoreTransaction(
            File configDir,
            String newIndexJson,
            String newMultiStateJson,
            String newConfigRaw,
            List<File> createdContentFiles)
            throws Exception {
        if (configDir == null) throw new IOException("配置目录不可用");
        synchronized (LOCK) {
            recoverInterruptedRestoreIfNeeded(configDir);
            String dirKey = canonicalDirKey(configDir);
            if (ACTIVE_IN_PROCESS_TX.containsKey(dirKey)) {
                throw new IOException("已有备份还原正在进行，请稍候重试");
            }
            File subsDir = new File(configDir, "subscriptions");
            if (!subsDir.exists() && !subsDir.mkdirs()) {
                throw new IOException("无法创建订阅目录");
            }
            File indexTarget = new File(subsDir, "index.json");
            File stateTarget = new File(subsDir, "tv_multi_source_v1.json");
            File configTarget = new File(configDir, "config.json");

            File txDir = new File(configDir, RESTORE_TX_DIR);
            deleteDirectoryRecursive(txDir);
            if (!txDir.mkdirs()) {
                throw new IOException("无法创建备份还原事务目录");
            }

            boolean oldIndexExisted = indexTarget.isFile();
            boolean oldStateExisted = stateTarget.isFile();
            boolean oldConfigExisted = configTarget.isFile();
            if (oldIndexExisted) {
                copyFileWithSync(indexTarget, new File(txDir, "old-index.json"));
            }
            if (oldStateExisted) {
                copyFileWithSync(stateTarget, new File(txDir, "old-state.json"));
            }
            if (oldConfigExisted) {
                copyFileWithSync(configTarget, new File(txDir, "old-config.json"));
            }
            if (newIndexJson != null) {
                writeBytesInDir(
                        txDir,
                        new File(txDir, "new-index.json"),
                        newIndexJson.getBytes(StandardCharsets.UTF_8));
            }
            if (newMultiStateJson != null) {
                writeBytesInDir(
                        txDir,
                        new File(txDir, "new-state.json"),
                        newMultiStateJson.getBytes(StandardCharsets.UTF_8));
            }
            if (newConfigRaw != null) {
                writeBytesInDir(
                        txDir,
                        new File(txDir, "new-config.json"),
                        newConfigRaw.getBytes(StandardCharsets.UTF_8));
            }

            JSONArray createdNames = new JSONArray();
            if (createdContentFiles != null) {
                for (File f : createdContentFiles) {
                    if (f != null) createdNames.put(f.getName());
                }
            }
            String txId = UUID.randomUUID().toString();
            JSONObject manifest =
                    new JSONObject()
                            .put("txId", txId)
                            .put("phase", PHASE_PREPARED)
                            .put("oldIndexExisted", oldIndexExisted)
                            .put("oldStateExisted", oldStateExisted)
                            .put("oldConfigExisted", oldConfigExisted)
                            .put("updateIndex", newIndexJson != null)
                            .put("updateState", newMultiStateJson != null)
                            .put("updateConfig", newConfigRaw != null)
                            .put("hasNewPrefs", false)
                            .put("createdFiles", createdNames);
            writeBytesInDir(
                    txDir,
                    new File(txDir, RESTORE_TX_MANIFEST),
                    manifest.toString().getBytes(StandardCharsets.UTF_8));
            ActiveRestoreState activeState =
                    new ActiveRestoreState(txId, PHASE_PREPARED, oldIndexExisted, oldStateExisted);
            ACTIVE_IN_PROCESS_TX.put(dirKey, activeState);

            CommitFaultInjector hook = restoreCommitFaultInjector;
            try {
                if (newIndexJson != null) {
                    writeBytesInDir(
                            subsDir, indexTarget, newIndexJson.getBytes(StandardCharsets.UTF_8));
                    if (hook != null) hook.afterStep("index");
                }
                if (newMultiStateJson != null) {
                    writeBytesInDir(
                            subsDir,
                            stateTarget,
                            newMultiStateJson.getBytes(StandardCharsets.UTF_8));
                    if (hook != null) hook.afterStep("state");
                }
                if (newConfigRaw != null) {
                    writeBytesInDir(
                            configDir, configTarget, newConfigRaw.getBytes(StandardCharsets.UTF_8));
                    if (hook != null) hook.afterStep("config");
                }
                return new RestoreTransaction(configDir, txId, activeState);
            } catch (SimulatedProcessKill kill) {
                // Deliberately bypass in-process rollback to test cold-start crash recovery;
                // clear in-process ownership so the next cold open in this JVM recovers it.
                clearActiveRestoreIfOwnedLocked(configDir, txId);
                throw kill;
            } catch (Throwable commitErr) {
                rollbackRestoreTransactionLocked(configDir, txId);
                clearActiveRestoreIfOwnedLocked(configDir, txId);
                if (commitErr instanceof Exception) throw (Exception) commitErr;
                throw new IOException("备份还原提交失败，已回滚原数据：" + commitErr.getMessage(), commitErr);
            }
        }
    }

    /**
     * Atomically commits {@code subscriptions/index.json}, {@code tv_multi_source_v1.json}, and
     * {@code config.json} under a durable WAL manifest in {@code <configDir>/restore-tx/}. Any
     * write failure rolls back all three targets immediately; an abrupt process kill mid-commit is
     * rolled back automatically on the next cold read via {@link
     * #recoverInterruptedRestoreIfNeeded(File)}.
     */
    static void commitRestoreTransaction(
            File configDir,
            String newIndexJson,
            String newMultiStateJson,
            String newConfigRaw,
            List<File> createdContentFiles)
            throws Exception {
        RestoreTransaction tx =
                beginAndWriteRestoreTransaction(
                        configDir,
                        newIndexJson,
                        newMultiStateJson,
                        newConfigRaw,
                        createdContentFiles);
        try {
            tx.finalizeCommit();
        } catch (Throwable err) {
            tx.rollback();
            if (err instanceof Exception) throw (Exception) err;
            throw new IOException("备份还原提交失败，已回滚原数据：" + err.getMessage(), err);
        }
    }

    /**
     * Checks for an incomplete restore transaction left behind by a crashed/killed prior process
     * and converges all targets to one consistent generation:
     * <ul>
     *   <li>If an in-process restore owns {@code configDir}, returns immediately without touching
     *       the WAL so concurrent readers never roll back a live commit.
     *   <li>If the prior process crashed in {@code PREPARED} (before preference writes began),
     *       rolls back files to the exact pre-restore snapshot.
     *   <li>If the prior process crashed in {@code COMMITTING_PREFS} (while/after writing
     *       preferences), rolls forward all new file targets and replays persisted preferences
     *       (when {@code prefs} is provided) so files, preferences, and watch history converge to
     *       the complete new generation.
     * </ul>
     */
    static void recoverInterruptedRestoreIfNeeded(File configDir) {
        recoverInterruptedRestoreIfNeeded(configDir, null, null);
    }

    static void recoverInterruptedRestoreIfNeeded(File configDir, PrefsReplayCallback prefsReplay) {
        recoverInterruptedRestoreIfNeeded(configDir, prefsReplay, null);
    }

    static void recoverInterruptedRestoreIfNeeded(
            File configDir, PrefsReplayCallback prefsReplay, PrefsAppliedCheck prefsAppliedCheck) {
        if (configDir == null || !configDir.isDirectory()) return;
        File txDir = new File(configDir, RESTORE_TX_DIR);
        if (!txDir.exists()) return;
        synchronized (LOCK) {
            if (ACTIVE_IN_PROCESS_TX.containsKey(canonicalDirKey(configDir))) {
                return;
            }
            if (!txDir.exists()) return;
            File manifestFile = new File(txDir, RESTORE_TX_MANIFEST);
            if (!manifestFile.isFile()) {
                // Crashed before PREPARED manifest existed: no live targets were modified yet.
                deleteDirectoryRecursive(txDir);
                return;
            }
            try {
                JSONObject manifest = new JSONObject(read(manifestFile, 1024 * 1024));
                String phase = manifest.optString("phase", "");
                String txId = manifest.optString("txId", "");
                boolean prefsAlreadyPersisted =
                        PHASE_PREFS_PERSISTED.equals(phase)
                                || manifest.optBoolean("prefsPersisted", false);
                if (!prefsAlreadyPersisted
                        && PHASE_COMMITTING_PREFS.equals(phase)
                        && prefsAppliedCheck != null
                        && !txId.isEmpty()) {
                    try {
                        if (prefsAppliedCheck.isTxApplied(txId)) {
                            prefsAlreadyPersisted = true;
                        }
                    } catch (Throwable ignored) {
                    }
                }
                if (prefsAlreadyPersisted) {
                    // Both file targets and preferences were already durably persisted before
                    // finalization failed. Never overwrite live subscription files or replay stale
                    // preferences over subsequent user progress/settings; clean up WAL on startup
                    // recovery.
                    if (prefsReplay != null || prefsAppliedCheck != null) {
                        manifestFile.delete();
                        deleteDirectoryRecursive(txDir);
                    }
                    return;
                }
                if (PHASE_COMMITTING_PREFS.equals(phase)) {
                    rollForwardRestoreTransactionLocked(configDir, manifest, prefsReplay);
                    return;
                }
            } catch (Throwable ignored) {
            }
            rollbackRestoreTransactionLocked(configDir, null);
        }
    }

    private static void rollForwardRestoreTransactionLocked(
            File configDir, JSONObject manifest, PrefsReplayCallback prefsReplay) {
        File txDir = new File(configDir, RESTORE_TX_DIR);
        File manifestFile = new File(txDir, RESTORE_TX_MANIFEST);
        try {
            boolean needsPrefsReplay = manifest.optBoolean("hasNewPrefs", false);
            if (needsPrefsReplay && prefsReplay == null) {
                // An ordinary read (e.g., ConfigLibrary.entries() or
                // TvMultiSourceStore.readState()) has no SharedPreferences/txId context: it can
                // neither verify restore_tx_applied_id nor replay new-prefs.json. Never overwrite
                // live subscription/state/config files during an ordinary read; keep the WAL
                // intact so startup recovery with full preference context converges cleanly.
                return;
            }
            File subsDir = new File(configDir, "subscriptions");
            File indexTarget = new File(subsDir, "index.json");
            File stateTarget = new File(subsDir, "tv_multi_source_v1.json");
            File configTarget = new File(configDir, "config.json");

            if (manifest.optBoolean("updateIndex", false)) {
                File newIdx = new File(txDir, "new-index.json");
                if (newIdx.isFile()) {
                    restoreOrDeleteTarget(subsDir, indexTarget, newIdx, true);
                }
            }
            if (manifest.optBoolean("updateState", false)) {
                File newSt = new File(txDir, "new-state.json");
                if (newSt.isFile()) {
                    restoreOrDeleteTarget(subsDir, stateTarget, newSt, true);
                }
            }
            if (manifest.optBoolean("updateConfig", false)) {
                File newCfg = new File(txDir, "new-config.json");
                if (newCfg.isFile()) {
                    restoreOrDeleteTarget(configDir, configTarget, newCfg, true);
                }
            }
            if (needsPrefsReplay) {
                File newPrefsFile = new File(txDir, "new-prefs.json");
                if (!newPrefsFile.isFile()) {
                    throw new IOException("缺少待重放的偏好快照文件");
                }
                JSONObject newPrefs = new JSONObject(read(newPrefsFile, MAX_RESTORE_PREFS_BYTES));
                prefsReplay.replayPrefs(newPrefs);
            }
            manifestFile.delete();
            deleteDirectoryRecursive(txDir);
        } catch (Throwable ignored) {
        }
    }

    private static void rollbackRestoreTransactionLocked(File configDir, String expectedTxId) {
        File txDir = new File(configDir, RESTORE_TX_DIR);
        File manifestFile = new File(txDir, RESTORE_TX_MANIFEST);
        if (!manifestFile.isFile()) {
            deleteDirectoryRecursive(txDir);
            return;
        }
        try {
            JSONObject manifest = new JSONObject(read(manifestFile, 1024 * 1024));
            if (expectedTxId != null
                    && !expectedTxId.isEmpty()
                    && !expectedTxId.equals(manifest.optString("txId", ""))) {
                return;
            }
            File subsDir = new File(configDir, "subscriptions");
            File indexTarget = new File(subsDir, "index.json");
            File stateTarget = new File(subsDir, "tv_multi_source_v1.json");
            File configTarget = new File(configDir, "config.json");

            if (manifest.optBoolean("updateIndex", true)) {
                restoreOrDeleteTarget(
                        subsDir,
                        indexTarget,
                        new File(txDir, "old-index.json"),
                        manifest.optBoolean("oldIndexExisted", false));
            }
            if (manifest.optBoolean("updateState", true)) {
                restoreOrDeleteTarget(
                        subsDir,
                        stateTarget,
                        new File(txDir, "old-state.json"),
                        manifest.optBoolean("oldStateExisted", false));
            }
            if (manifest.optBoolean("updateConfig", true)) {
                restoreOrDeleteTarget(
                        configDir,
                        configTarget,
                        new File(txDir, "old-config.json"),
                        manifest.optBoolean("oldConfigExisted", false));
            }

            Set<String> referenced = new HashSet<>();
            if (indexTarget.isFile()) {
                try {
                    JSONArray restoredIdx = new JSONArray(read(indexTarget, 1024 * 1024));
                    for (int i = 0; i < restoredIdx.length(); i++) {
                        Entry e = new Entry(restoredIdx.getJSONObject(i));
                        referenced.add(e.id + "-" + e.digest + ".json");
                    }
                } catch (Throwable ignored) {
                }
            }
            JSONArray created = manifest.optJSONArray("createdFiles");
            if (created != null) {
                for (int i = 0; i < created.length(); i++) {
                    String fn = created.optString(i, "").trim();
                    if (!fn.isEmpty() && !referenced.contains(fn)) {
                        File f = new File(subsDir, fn);
                        if (f.isFile()) f.delete();
                    }
                }
            }
            manifestFile.delete();
            deleteDirectoryRecursive(txDir);
        } catch (Throwable ignored) {
        }
    }

    private static void restoreOrDeleteTarget(
            File parentDir, File target, File backupCopy, boolean existedBefore) throws Exception {
        if (existedBefore && backupCopy.isFile()) {
            copyFileAtomicInDir(parentDir, backupCopy, target);
        } else if (!existedBefore) {
            if (target.isFile()) target.delete();
        }
    }

    private static void copyFileAtomicInDir(File parentDir, File src, File target)
            throws IOException {
        if (!parentDir.exists() && !parentDir.mkdirs()) {
            throw new IOException("无法创建保存订阅的目录");
        }
        File pending = File.createTempFile("config-lib-", ".tmp", parentDir);
        try {
            copyFileWithSync(src, pending);
            if (!pending.renameTo(target)) {
                File backup = new File(parentDir, target.getName() + ".bak");
                if (!target.isFile()
                        || (backup.exists() && !backup.delete())
                        || !target.renameTo(backup)) {
                    throw new IOException("无法保存订阅，原记录已保留");
                }
                if (!pending.renameTo(target)) {
                    backup.renameTo(target);
                    throw new IOException("无法保存订阅，原记录已保留");
                }
                backup.delete();
            }
        } finally {
            pending.delete();
        }
    }

    private static void copyFileWithSync(File src, File dst) throws IOException {
        try (FileInputStream in = new FileInputStream(src);
                FileOutputStream out = new FileOutputStream(dst)) {
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n > 0) out.write(buf, 0, n);
            }
            out.getFD().sync();
        }
    }

    private static byte[] readRawBytes(File file, int limit) throws IOException {
        long len = file.length();
        if (len > limit) throw new IOException("文件超过大小限制");
        int cap = (int) Math.max(256L, Math.min(limit, len > 0 ? len : 4096L));
        try (FileInputStream in = new FileInputStream(file);
                ByteArrayOutputStream out = new ByteArrayOutputStream(cap)) {
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (out.size() + n > limit) throw new IOException("文件超过大小限制");
                if (n > 0) out.write(buf, 0, n);
            }
            return out.toByteArray();
        }
    }

    private static void deleteDirectoryRecursive(File dir) {
        if (dir == null || !dir.exists()) return;
        if (dir.isDirectory()) {
            File[] children = dir.listFiles();
            if (children != null) {
                for (File c : children) deleteDirectoryRecursive(c);
            }
        }
        dir.delete();
    }

    private static void writeBytesInDir(File dir, File target, byte[] data) throws Exception {
        if (!dir.exists() && !dir.mkdirs()) throw new IOException("无法创建目录");
        File pending = File.createTempFile("tx-", ".tmp", dir);
        try {
            try (FileOutputStream out = new FileOutputStream(pending)) {
                out.write(data);
                out.getFD().sync();
            }
            if (!pending.renameTo(target)) {
                File backup = new File(dir, target.getName() + ".bak");
                if (!target.isFile()
                        || (backup.exists() && !backup.delete())
                        || !target.renameTo(backup)) {
                    throw new IOException("无法原子替换目标文件：" + target.getName());
                }
                if (!pending.renameTo(target)) {
                    backup.renameTo(target);
                    throw new IOException("无法原子替换目标文件：" + target.getName());
                }
                backup.delete();
            }
        } finally {
            pending.delete();
        }
    }

    boolean remove(String id) throws Exception {
        if (id == null || id.isEmpty()) return false;
        synchronized (LOCK) {
            JSONArray items = index();
            JSONArray kept = new JSONArray();
            List<Entry> removed = new ArrayList<>();
            Set<String> activeFiles = new HashSet<>();
            for (int i = 0; i < items.length(); i++) {
                Entry entry = new Entry(items.getJSONObject(i));
                if (id.equals(entry.id)) {
                    removed.add(entry);
                } else {
                    kept.put(items.getJSONObject(i));
                    activeFiles.add(content(entry).getName());
                }
            }
            if (removed.isEmpty()) return false;
            write(new File(directory, "index.json"), kept.toString());
            for (Entry r : removed) {
                File f = content(r);
                if (!activeFiles.contains(f.getName())) f.delete();
            }
            return true;
        }
    }

    void rememberIfAbsent(String raw, String origin, String name, String selected)
            throws Exception {
        synchronized (LOCK) {
            String id = identity(origin, raw);
            for (Entry entry : entries()) if (entry.id.equals(id)) return;
            remember(raw, origin, name, selected);
        }
    }

    String raw(Entry entry) throws Exception {
        String value = read(content(entry), MAX_SUBSCRIPTION_BYTES);
        if (!hash(value).equals(entry.digest)) throw new IOException("保存的订阅内容损坏，原文件已保留");
        return value;
    }

    File contentFile(Entry entry) {
        return content(entry);
    }

    private File content(Entry entry) {
        return new File(directory, entry.id + "-" + entry.digest + ".json");
    }

    private static void verifyContentFile(File file, String expectedDigest, int limit)
            throws Exception {
        long fileLen = file.length();
        if (fileLen > limit) throw new IOException("保存的订阅文件过大");
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        long total = 0;
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[16384];
            int n;
            while ((n = in.read(buffer)) >= 0) {
                total += n;
                if (total > limit) throw new IOException("保存的订阅文件过大");
                if (n > 0) md.update(buffer, 0, n);
            }
        }
        StringBuilder out = new StringBuilder(64);
        for (byte b : md.digest()) out.append(String.format(Locale.ROOT, "%02x", b & 255));
        if (!out.toString().equals(expectedDigest)) {
            throw new IOException("保存的订阅内容回读校验失败，原文件已保留");
        }
    }

    private static String read(File file, int limit) throws Exception {
        long fileLen = file.length();
        if (fileLen > limit) throw new IOException("保存的订阅文件过大");
        int initialCap = (int) Math.max(256L, Math.min(limit, fileLen > 0 ? fileLen : 4096L));
        try (FileInputStream in = new FileInputStream(file);
                ByteArrayOutputStream out = new ByteArrayOutputStream(initialCap)) {
            byte[] buffer = new byte[16384];
            int n;
            while ((n = in.read(buffer)) >= 0) {
                if (out.size() + n > limit) throw new IOException("保存的订阅文件过大");
                out.write(buffer, 0, n);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private void write(File target, String raw) throws Exception {
        writeBytes(target, raw.getBytes(StandardCharsets.UTF_8));
    }

    private void writeBytes(File target, byte[] data) throws Exception {
        if (!directory.exists() && !directory.mkdirs()) throw new IOException("无法创建订阅目录");
        File pending = File.createTempFile("subscription-", ".tmp", directory);
        try {
            try (FileOutputStream out = new FileOutputStream(pending)) {
                out.write(data);
                out.getFD().sync();
            }
            if (!pending.renameTo(target)) {
                // Windows cannot rename over an existing file. Android uses the atomic path above.
                File backup = new File(directory, target.getName() + ".bak");
                if (!target.isFile()
                        || (backup.exists() && !backup.delete())
                        || !target.renameTo(backup)) throw new IOException("无法保存订阅，原文件已保留");
                if (!pending.renameTo(target)) {
                    backup.renameTo(target);
                    throw new IOException("无法保存订阅，原文件已保留");
                }
                backup.delete();
            }
        } finally {
            pending.delete();
        }
    }
}

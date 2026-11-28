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
    static final Object PERSISTENCE_LOCK = new Object();
    private static final java.util.concurrent.atomic.AtomicLong RESTORE_EPOCH =
            new java.util.concurrent.atomic.AtomicLong(0L);
    private static volatile Thread storageThread;

    static long restoreEpoch() {
        return RESTORE_EPOCH.get();
    }

    static long bumpRestoreEpoch() {
        return RESTORE_EPOCH.incrementAndGet();
    }

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

    /**
     * Scoped cross-source history migration ticket: binds an old bookmark key strictly to the
     * target {@code (siteKey, videoId)} so old history can ONLY be removed after that exact target
     * starts playing and persists its new progress.
     */
    static final class PendingMigration {
        static final int MIN_PROGRESS_ADVANCE_MS = 250;
        static final int SEEK_LANDING_TOLERANCE_MS = 2000;
        static final int POST_SEEK_CONSECUTIVE_ADVANCES_REQUIRED = 2;
        static final int CLOCK_JITTER_ALLOWANCE_MS = 250;
        static final int STALE_PRE_SEEK_WINDOW_MS = 400;
        final String oldKey;
        final String targetSiteKey;
        final String targetVideoId;
        private boolean playbackObserved;
        private int initialObservedPosMs = -1;
        private long initialObservedAtMs = -1L;
        private int lastValidPosMs = -1;
        private long lastValidAtMs = -1L;
        private int lastObservedPosMs = -1;
        private int pendingSeekTargetMs = -1;
        private int preSeekPosMs = -1;
        private int settledSeekTargetMs = -1;
        private int settledPreSeekPosMs = -1;
        private long observedPlayerSeekGen;
        private boolean seekSettled;
        private boolean baselineCameFromSeek;
        private boolean pausedSinceLastSample;
        private int consecutiveValidAdvances;
        private boolean progressConfirmed;

        PendingMigration(String oldKey, String targetSiteKey, String targetVideoId) {
            this.oldKey = oldKey == null ? "" : oldKey;
            this.targetSiteKey = targetSiteKey == null ? "" : targetSiteKey;
            this.targetVideoId = targetVideoId == null ? "" : targetVideoId;
        }

        boolean valid() {
            return !oldKey.isEmpty() && !targetSiteKey.isEmpty() && !targetVideoId.isEmpty();
        }

        String targetKey() {
            return targetSiteKey + "\n" + targetVideoId;
        }

        boolean matchesTarget(String siteKey, String videoId) {
            return valid()
                    && targetSiteKey.equals(siteKey)
                    && targetVideoId.equals(videoId)
                    && !oldKey.equals(targetKey());
        }

        boolean matchesSavedBookmark(Entry savedBookmark) {
            return savedBookmark != null && matchesTarget(savedBookmark.site, savedBookmark.id);
        }

        boolean isProgressConfirmed() {
            return progressConfirmed;
        }

        void resetProgressBaselineForSeek(int targetPosMs) {
            resetProgressBaselineForSeek(targetPosMs, -1);
        }

        void resetProgressBaselineForSeek(int targetPosMs, int currentPosMs) {
            if (progressConfirmed) return;
            int effectivePreSeek = currentPosMs >= 0 ? currentPosMs : lastObservedPosMs;
            playbackObserved = false;
            initialObservedPosMs = -1;
            initialObservedAtMs = -1L;
            lastValidPosMs = -1;
            lastValidAtMs = -1L;
            pendingSeekTargetMs = Math.max(0, targetPosMs);
            preSeekPosMs = effectivePreSeek;
            settledSeekTargetMs = -1;
            settledPreSeekPosMs = -1;
            seekSettled = false;
            baselineCameFromSeek = false;
            pausedSinceLastSample = false;
            consecutiveValidAdvances = 0;
        }

        void syncPlayerSeekGeneration(long playerSeekGen, int targetPosMs, int prePosMs) {
            if (progressConfirmed || playerSeekGen <= observedPlayerSeekGen) return;
            observedPlayerSeekGen = playerSeekGen;
            int clampedTarget = Math.max(0, targetPosMs);
            if (playbackObserved
                    || pendingSeekTargetMs < 0
                    || pendingSeekTargetMs != clampedTarget) {
                resetProgressBaselineForSeek(clampedTarget, prePosMs);
            }
        }

        boolean observePlaybackProgress(
                boolean foreground,
                boolean playIntended,
                boolean playerIsPlaying,
                int rawPosMs,
                int seekTargetMs) {
            return observePlaybackProgress(
                    foreground,
                    playIntended,
                    playerIsPlaying,
                    rawPosMs,
                    seekTargetMs,
                    false,
                    false,
                    1.0f,
                    -1L);
        }

        boolean observePlaybackProgress(
                boolean foreground,
                boolean playIntended,
                boolean playerIsPlaying,
                int rawPosMs,
                int seekTargetMs,
                boolean seekConfirmationAvailable,
                boolean seekInFlight,
                long nowMs) {
            return observePlaybackProgress(
                    foreground,
                    playIntended,
                    playerIsPlaying,
                    rawPosMs,
                    seekTargetMs,
                    seekConfirmationAvailable,
                    seekInFlight,
                    1.0f,
                    nowMs);
        }

        boolean observePlaybackProgress(
                boolean foreground,
                boolean playIntended,
                boolean playerIsPlaying,
                int rawPosMs,
                int seekTargetMs,
                boolean seekConfirmationAvailable,
                boolean seekInFlight,
                float playbackRate,
                long nowMs) {
            if (progressConfirmed) return true;
            if (!foreground || !playIntended || !playerIsPlaying || rawPosMs < 0) {
                consecutiveValidAdvances = 0;
                pausedSinceLastSample = true;
                return false;
            }
            float effectiveRate =
                    (Float.isNaN(playbackRate) || Float.isInfinite(playbackRate))
                            ? 1.0f
                            : Math.max(0.25f, Math.min(4.0f, playbackRate));

            // Prefer confirmable kernel seek-completion signals: while a seek is still in flight,
            // never accept optimistic target writes or delayed pre-seek positions as landed.
            if (seekConfirmationAvailable && seekInFlight) {
                return false;
            }

            int activeSeekTarget =
                    pendingSeekTargetMs >= 0
                            ? pendingSeekTargetMs
                            : (!seekSettled && !playbackObserved && seekTargetMs > 0
                                    ? seekTargetMs
                                    : -1);
            if (activeSeekTarget >= 0) {
                if (preSeekPosMs >= 0 && activeSeekTarget > preSeekPosMs) {
                    int jump = activeSeekTarget - preSeekPosMs;
                    int tol = Math.min(SEEK_LANDING_TOLERANCE_MS, jump / 3);
                    int landingFloor = Math.max(preSeekPosMs + 1, activeSeekTarget - tol);
                    if (rawPosMs < landingFloor) {
                        return false;
                    }
                } else if (preSeekPosMs >= 0 && activeSeekTarget < preSeekPosMs) {
                    int jump = preSeekPosMs - activeSeekTarget;
                    int tol = Math.min(SEEK_LANDING_TOLERANCE_MS, jump / 3);
                    int landingCeiling = Math.min(preSeekPosMs - 1, activeSeekTarget + tol);
                    if (rawPosMs > landingCeiling) {
                        return false;
                    }
                } else if (activeSeekTarget > 0) {
                    int landingFloor = Math.max(1, activeSeekTarget - SEEK_LANDING_TOLERANCE_MS);
                    if (rawPosMs < landingFloor) {
                        return false;
                    }
                }
                settledSeekTargetMs = activeSeekTarget;
                settledPreSeekPosMs = preSeekPosMs;
                pendingSeekTargetMs = -1;
                preSeekPosMs = -1;
                seekSettled = true;
                baselineCameFromSeek = true;
                playbackObserved = true;
                pausedSinceLastSample = false;
                initialObservedPosMs = rawPosMs;
                initialObservedAtMs = nowMs;
                lastValidPosMs = rawPosMs;
                lastValidAtMs = nowMs;
                lastObservedPosMs = rawPosMs;
                consecutiveValidAdvances = 0;
                return false;
            }

            if (!playbackObserved) {
                playbackObserved = true;
                baselineCameFromSeek = false;
                pausedSinceLastSample = false;
                initialObservedPosMs = rawPosMs;
                initialObservedAtMs = nowMs;
                lastValidPosMs = rawPosMs;
                lastValidAtMs = nowMs;
                lastObservedPosMs = rawPosMs;
                consecutiveValidAdvances = 0;
                return false;
            }

            // Late / regressive readings MUST NOT pull the sampling baseline back to an older
            // pre-seek position (blocks 12s -> 13.5s receiving 13.5s, late 12s, then 13.5s).
            if (rawPosMs < lastValidPosMs) {
                consecutiveValidAdvances = 0;
                return false;
            }

            if (rawPosMs == lastValidPosMs) {
                if (nowMs >= 0L && lastValidAtMs >= 0L) {
                    if (pausedSinceLastSample || nowMs - lastValidAtMs >= 500L) {
                        lastValidAtMs = nowMs;
                        if (lastValidPosMs == initialObservedPosMs) {
                            initialObservedAtMs = nowMs;
                        }
                    }
                }
                pausedSinceLastSample = false;
                return false;
            }

            // Separate seek completion from first credible playback advance: after ANY backward
            // seek (even with kernel seek confirmation), a single reading jumping back into the
            // pre-seek zone before any credible post-landing advance MUST NOT confirm migration.
            if (baselineCameFromSeek
                    && settledPreSeekPosMs >= 0
                    && settledSeekTargetMs >= 0
                    && settledPreSeekPosMs > settledSeekTargetMs
                    && consecutiveValidAdvances == 0) {
                int jump = settledPreSeekPosMs - settledSeekTargetMs;
                int staleMargin = Math.min(STALE_PRE_SEEK_WINDOW_MS, Math.max(150, jump / 3));
                if (rawPosMs >= settledPreSeekPosMs - staleMargin
                        && rawPosMs <= settledPreSeekPosMs + staleMargin) {
                    return false;
                }
            }

            int stepDeltaMs = rawPosMs - lastValidPosMs;
            int totalDeltaMs = rawPosMs - initialObservedPosMs;
            boolean wallClockAllowsConfirm = true;
            if (nowMs >= 0L && lastValidAtMs >= 0L && initialObservedAtMs >= 0L) {
                long stepWallMs = Math.max(0L, nowMs - lastValidAtMs);
                long totalWallMs = Math.max(0L, nowMs - initialObservedAtMs);
                long maxStepMediaMs =
                        Math.round(stepWallMs * (double) effectiveRate * 1.2)
                                + CLOCK_JITTER_ALLOWANCE_MS;
                long maxTotalMediaMs =
                        Math.round(totalWallMs * (double) effectiveRate * 1.2)
                                + CLOCK_JITTER_ALLOWANCE_MS;
                if (stepDeltaMs > maxStepMediaMs || totalDeltaMs > maxTotalMediaMs) {
                    consecutiveValidAdvances = 0;
                    return false;
                }
                long minWallForProgressMs =
                        Math.max(
                                100L,
                                Math.round(
                                        (MIN_PROGRESS_ADVANCE_MS / (double) effectiveRate) * 0.6));
                if (totalWallMs < minWallForProgressMs) {
                    wallClockAllowsConfirm = false;
                }
            }

            pausedSinceLastSample = false;
            lastValidPosMs = rawPosMs;
            lastValidAtMs = nowMs;
            lastObservedPosMs = rawPosMs;
            consecutiveValidAdvances++;

            // Any seek separates landing from credible continuous playback: require consecutive
            // valid forward-advancing samples matching elapsed wall-clock time before confirming.
            int requiredAdvances =
                    baselineCameFromSeek ? POST_SEEK_CONSECUTIVE_ADVANCES_REQUIRED : 1;
            if (rawPosMs > 0
                    && totalDeltaMs >= MIN_PROGRESS_ADVANCE_MS
                    && consecutiveValidAdvances >= requiredAdvances
                    && wallClockAllowsConfirm) {
                progressConfirmed = true;
            }
            return progressConfirmed;
        }

        void markCompletedInForeground(boolean foreground, boolean playIntended) {
            if (foreground && playIntended) {
                progressConfirmed = true;
            }
        }
    }

    static boolean isValidEntry(Entry entry) {
        return entry != null
                && entry.site != null
                && !entry.site.trim().isEmpty()
                && entry.id != null
                && !entry.id.trim().isEmpty();
    }

    static Entry cloneEntry(Entry src) {
        if (src == null) return null;
        Entry e = new Entry();
        e.site = src.site;
        e.id = src.id;
        e.title = src.title;
        e.poster = src.poster;
        e.line = src.line;
        e.episode = src.episode;
        e.shareUrl = src.shareUrl;
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
        final long submittedEpoch = RESTORE_EPOCH.get();
        return STORAGE_EXECUTOR.submit(
                new Callable<String>() {
                    @Override
                    public String call() {
                        if (persistence == null || snapshot == null) return null;
                        if (submittedEpoch != RESTORE_EPOCH.get()) {
                            return null;
                        }
                        boolean corruptedPref = persistence.readCorruptedPref();
                        String current = persistence.readRaw();
                        if (submittedEpoch != RESTORE_EPOCH.get()) {
                            return null;
                        }
                        if (corruptedPref || historyCorrupted || isMalformed(current)) {
                            synchronized (PERSISTENCE_LOCK) {
                                if (submittedEpoch != RESTORE_EPOCH.get()) {
                                    return null;
                                }
                                historyCorrupted = true;
                            }
                            return current;
                        }
                        String updated = upsert(current, snapshot);
                        synchronized (PERSISTENCE_LOCK) {
                            if (submittedEpoch != RESTORE_EPOCH.get()) {
                                return null;
                            }
                            if (updated != null && !updated.equals(current)) {
                                persistence.writeState(updated, historyCorrupted);
                            }
                            return updated;
                        }
                    }
                });
    }

    /**
     * Atomically upserts {@code entry} and removes {@code oldKey} on the single storage executor
     * ONLY IF the new entry was saved cleanly and is distinct from {@code oldKey}.
     */
    static Future<String> enqueueUpsertAndMigrate(
            final Persistence persistence, final Entry entry, final String oldKey) {
        final Entry snapshot = cloneEntry(entry);
        final long submittedEpoch = RESTORE_EPOCH.get();
        return STORAGE_EXECUTOR.submit(
                new Callable<String>() {
                    @Override
                    public String call() {
                        if (persistence == null || snapshot == null) return null;
                        if (submittedEpoch != RESTORE_EPOCH.get()) {
                            return null;
                        }
                        boolean corruptedPref = persistence.readCorruptedPref();
                        String current = persistence.readRaw();
                        if (submittedEpoch != RESTORE_EPOCH.get()) {
                            return null;
                        }
                        if (corruptedPref || historyCorrupted || isMalformed(current)) {
                            synchronized (PERSISTENCE_LOCK) {
                                if (submittedEpoch != RESTORE_EPOCH.get()) {
                                    return null;
                                }
                                historyCorrupted = true;
                            }
                            return current;
                        }
                        String updated = upsertAndMigrate(current, snapshot, oldKey);
                        synchronized (PERSISTENCE_LOCK) {
                            if (submittedEpoch != RESTORE_EPOCH.get()) {
                                return null;
                            }
                            if (updated != null && !updated.equals(current)) {
                                persistence.writeState(updated, historyCorrupted);
                            }
                            return updated;
                        }
                    }
                });
    }

    static Future<String> enqueueRemove(
            final Persistence persistence, final String key, final Runnable onComplete) {
        final long submittedEpoch = RESTORE_EPOCH.get();
        return STORAGE_EXECUTOR.submit(
                new Callable<String>() {
                    @Override
                    public String call() {
                        try {
                            if (persistence == null || key == null || key.isEmpty()) return null;
                            if (submittedEpoch != RESTORE_EPOCH.get()) {
                                return null;
                            }
                            boolean corruptedPref = persistence.readCorruptedPref();
                            String current = persistence.readRaw();
                            if (submittedEpoch != RESTORE_EPOCH.get()) {
                                return null;
                            }
                            if (corruptedPref || historyCorrupted || isMalformed(current)) {
                                synchronized (PERSISTENCE_LOCK) {
                                    if (submittedEpoch != RESTORE_EPOCH.get()) {
                                        return null;
                                    }
                                    historyCorrupted = true;
                                }
                                return current;
                            }
                            String updated = remove(current, key);
                            synchronized (PERSISTENCE_LOCK) {
                                if (submittedEpoch != RESTORE_EPOCH.get()) {
                                    return null;
                                }
                                if (updated != null && !updated.equals(current)) {
                                    persistence.writeState(updated, historyCorrupted);
                                }
                                return updated;
                            }
                        } finally {
                            if (onComplete != null) onComplete.run();
                        }
                    }
                });
    }

    static Future<String> enqueueClear(final Persistence persistence, final Runnable onComplete) {
        final long submittedEpoch = RESTORE_EPOCH.get();
        return STORAGE_EXECUTOR.submit(
                new Callable<String>() {
                    @Override
                    public String call() {
                        try {
                            if (persistence == null) return clear(null);
                            synchronized (PERSISTENCE_LOCK) {
                                if (submittedEpoch != RESTORE_EPOCH.get()) {
                                    return null;
                                }
                                return clear(
                                        new Store() {
                                            @Override
                                            public void writeHistoryState(
                                                    String historyJson, boolean corrupted) {
                                                persistence.writeState(historyJson, corrupted);
                                            }
                                        });
                            }
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
                            synchronized (PERSISTENCE_LOCK) {
                                bumpRestoreEpoch();
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
                            }
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

    static final class Entry {
        String site, id, title, poster, line, episode;
        String shareUrl = "";
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
            if (shareUrl != null && !shareUrl.isEmpty()) {
                obj.put("shareUrl", shareUrl);
            }
            return obj;
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
                e.episode = Cms.optSafeString(o, "episode");
                e.shareUrl = Cms.optSafeString(o, "shareUrl");
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

    static String upsertAndMigrate(String text, Entry newEntry, String oldKey) {
        if (historyCorrupted || isMalformed(text)) {
            historyCorrupted = true;
            AppLog.w(
                    "WatchHistory",
                    "Skipping upsertAndMigrate because watch history is corrupted",
                    null);
            return text;
        }
        if (!isValidEntry(newEntry)) {
            return text;
        }
        JSONObject newJson;
        try {
            newJson = newEntry.json();
        } catch (Exception e) {
            return text;
        }
        String newKey = newEntry.key();
        String removeKey = oldKey == null ? "" : oldKey;
        List<Entry> entries = read(text);
        for (Iterator<Entry> it = entries.iterator(); it.hasNext(); ) {
            Entry existing = it.next();
            String existingKey = existing.key();
            if (newKey.equals(existingKey)
                    || (!removeKey.isEmpty() && removeKey.equals(existingKey))) {
                it.remove();
            }
        }
        entries.add(0, newEntry);
        JSONArray a = new JSONArray();
        a.put(newJson);
        for (int i = 1; i < Math.min(LIMIT, entries.size()); i++) {
            try {
                a.put(entries.get(i).json());
            } catch (Exception ignored) {
            }
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

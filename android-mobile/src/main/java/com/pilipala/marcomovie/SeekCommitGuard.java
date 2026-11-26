package com.pilipala.marcomovie;

/**
 * Pure-JVM seek confirmation guard preventing failed or stalled seeks from polluting {@link
 * WatchHistory}.
 *
 * <p>When a user seeks to a target position, {@link #beginSeek(int)} records the target as pending
 * WITHOUT mutating {@link #historyPositionMs()}. Only once the player exits buffering and delivers
 * genuine playback clock progress at the target position is the new position committed for history
 * persistence. If the seek stalls, errors, or is abandoned on exit, history retains the last
 * confirmed reached position.
 */
final class SeekCommitGuard {
    private static final int TARGET_TOLERANCE_MS = 15_000;
    private static final java.util.Map<Object, SeekCommitGuard> INSTANCES =
            new java.util.WeakHashMap<>();

    static SeekCommitGuard forHost(Object host) {
        if (host == null) return new SeekCommitGuard();
        synchronized (INSTANCES) {
            SeekCommitGuard existing = INSTANCES.get(host);
            if (existing == null) {
                existing = new SeekCommitGuard();
                INSTANCES.put(host, existing);
            }
            return existing;
        }
    }

    private int confirmedPositionMs = 0;
    private int pendingSeekTargetMs = -1;
    private boolean pendingSeekActive = false;
    private int firstLandedTickMs = -1;
    volatile boolean buffering = false;
    volatile boolean pendingStartPaused = false;

    synchronized void reset(int initialPositionMs) {
        confirmedPositionMs = Math.max(0, initialPositionMs);
        pendingSeekTargetMs = -1;
        pendingSeekActive = false;
        firstLandedTickMs = -1;
    }

    synchronized void beginSeek(int targetMs) {
        pendingSeekTargetMs = Math.max(0, targetMs);
        pendingSeekActive = true;
        firstLandedTickMs = -1;
    }

    synchronized void onSeekFailedOrCancelled() {
        pendingSeekTargetMs = -1;
        pendingSeekActive = false;
        firstLandedTickMs = -1;
    }

    /**
     * Feeds a live player clock sample.
     *
     * @param rawPositionMs player-reported position in ms
     * @param isPlaying whether playback is actively advancing (not paused)
     * @param isBuffering whether the player is currently buffering / seeking
     * @return {@code true} if this tick just confirmed a pending seek
     */
    synchronized boolean onPlaybackTick(int rawPositionMs, boolean isPlaying, boolean isBuffering) {
        if (rawPositionMs < 0) return false;
        if (!pendingSeekActive) {
            if (!isBuffering && isPlaying) {
                confirmedPositionMs = rawPositionMs;
            } else if (!isBuffering && confirmedPositionMs == 0 && rawPositionMs > 0) {
                confirmedPositionMs = rawPositionMs;
            }
            return false;
        }
        // Pending seek active: NEVER confirm while buffering or before position lands near target.
        if (isBuffering) {
            firstLandedTickMs = -1;
            return false;
        }
        int diff = Math.abs(rawPositionMs - pendingSeekTargetMs);
        if (diff > TARGET_TOLERANCE_MS) {
            return false;
        }
        if (isPlaying) {
            // Require genuine clock advance past the initial landed sample (at least 200ms)
            // so a frozen frame reporting the optimistic seek target is never misclassified as
            // reached.
            if (firstLandedTickMs < 0) {
                firstLandedTickMs = rawPositionMs;
                return false;
            }
            if (rawPositionMs > firstLandedTickMs + 200) {
                confirmedPositionMs = rawPositionMs;
                pendingSeekActive = false;
                pendingSeekTargetMs = -1;
                firstLandedTickMs = -1;
                return true;
            }
            return false;
        }
        // Paused seek that cleanly finished buffering and landed at target: confirm once stable
        // on two consecutive non-buffering samples.
        if (firstLandedTickMs < 0) {
            firstLandedTickMs = rawPositionMs;
            return false;
        }
        confirmedPositionMs = rawPositionMs;
        pendingSeekActive = false;
        pendingSeekTargetMs = -1;
        firstLandedTickMs = -1;
        return true;
    }

    synchronized int historyPositionMs() {
        return confirmedPositionMs;
    }

    synchronized boolean isPendingSeek() {
        return pendingSeekActive;
    }

    synchronized int pendingTargetMs() {
        return pendingSeekTargetMs;
    }
}

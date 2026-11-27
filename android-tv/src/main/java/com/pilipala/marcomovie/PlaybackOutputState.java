package com.pilipala.marcomovie;

/**
 * Pure-JVM playback output & black-screen watchdog state machine.
 *
 * <p>Strictly separates file-opened, decoder-prepared, valid-surface, video-track presence, and
 * first-frame-rendered signals so UI loading dismissal, live stream quality scoring, and bounded
 * black-screen recovery never conflate audio-only playback, paused state, black-screen intros, or
 * MPV's unconfirmed {@code FILE_LOADED} event with a genuine "prepared but no picture" fault.
 */
final class PlaybackOutputState {
    enum VideoFrameState {
        NONE,
        FIRST_FRAME_RENDERED,
        OUTPUT_UNCONFIRMED,
        RECONFIRM_REQUIRED
    }

    enum VideoTrackPresence {
        UNKNOWN,
        PRESENT,
        ABSENT
    }

    enum FaultCategory {
        NONE,
        NETWORK_UNREACHABLE,
        TLS_HANDSHAKE_OR_CERT,
        PARSE_FAILED,
        NO_VIDEO_TRACK,
        DECODE_FAILED,
        VIDEO_TRACK_NO_FIRST_FRAME,
        SURFACE_LOST_PICTURE
    }

    enum WatchdogAction {
        NONE,
        REBIND_SURFACE,
        FALLBACK_ONCE,
        REPORT_STALLED
    }

    enum UiOverlayMode {
        INITIAL_LOADING,
        WAITING_FIRST_FRAME,
        PLAYBACK_BUFFERING,
        READY_CLEAN,
        RECOVERY_STALLED_ERROR
    }

    static final long INITIAL_FIRST_FRAME_GRACE_MS = 4000L;
    static final long REBIND_RECONFIRM_GRACE_MS = 3000L;
    static final int MAX_RECOVERY_ATTEMPTS = 2;

    final int sessionId;
    final boolean mpvEngine;

    boolean fileOpened;
    boolean decoderPrepared;
    boolean surfaceValid;
    int surfaceIdentity;
    int lastAttachedSurfaceId;
    int voConfiguredSurfaceId;
    VideoTrackPresence videoTrack = VideoTrackPresence.UNKNOWN;
    VideoFrameState frameState = VideoFrameState.NONE;
    FaultCategory fault = FaultCategory.NONE;

    boolean foreground;
    boolean userWantsPlay;
    boolean playing;
    boolean buffering;
    boolean completed;

    long preparedAtMs;
    long waitingSinceMs;
    long firstFrameMs = -1L;
    int recoveryAttempts;
    boolean rebindRequested;
    boolean fallbackRequested;
    boolean reportedStalled;

    PlaybackOutputState(int sessionId, boolean mpvEngine, boolean foreground) {
        this.sessionId = sessionId;
        this.mpvEngine = mpvEngine;
        this.foreground = foreground;
    }

    private boolean isActivelyWaitingForFrame() {
        return decoderPrepared
                && foreground
                && playing
                && userWantsPlay
                && !buffering
                && !completed
                && !reportedStalled
                && surfaceValid
                && videoTrack == VideoTrackPresence.PRESENT
                && (frameState == VideoFrameState.NONE
                        || frameState == VideoFrameState.RECONFIRM_REQUIRED);
    }

    void onSurfaceAttached(int surfaceId, boolean valid, long nowMs) {
        boolean usable = valid && surfaceId != 0;
        boolean changed =
                usable && lastAttachedSurfaceId != 0 && lastAttachedSurfaceId != surfaceId;
        surfaceIdentity = usable ? surfaceId : 0;
        surfaceValid = usable;
        if (!usable) {
            voConfiguredSurfaceId = 0;
            waitingSinceMs = 0L;
            return;
        }
        lastAttachedSurfaceId = surfaceId;
        if (changed) {
            voConfiguredSurfaceId = 0;
            if (decoderPrepared && videoTrack == VideoTrackPresence.PRESENT && !reportedStalled) {
                if (frameState == VideoFrameState.FIRST_FRAME_RENDERED
                        || frameState == VideoFrameState.OUTPUT_UNCONFIRMED
                        || frameState == VideoFrameState.RECONFIRM_REQUIRED) {
                    frameState = VideoFrameState.RECONFIRM_REQUIRED;
                }
            }
        }
        if (isActivelyWaitingForFrame()) {
            waitingSinceMs = nowMs;
        } else if (!foreground || !playing || !userWantsPlay || buffering || completed) {
            waitingSinceMs = 0L;
        }
    }

    void onSurfaceDestroyed(long nowMs) {
        surfaceValid = false;
        surfaceIdentity = 0;
        voConfiguredSurfaceId = 0;
        // Background / detached-Surface duration must NEVER accrue toward watchdog grace.
        waitingSinceMs = 0L;
        if (decoderPrepared && videoTrack == VideoTrackPresence.PRESENT && !reportedStalled) {
            if (frameState == VideoFrameState.FIRST_FRAME_RENDERED
                    || frameState == VideoFrameState.OUTPUT_UNCONFIRMED) {
                frameState = VideoFrameState.RECONFIRM_REQUIRED;
            }
        }
    }

    void onFileOpened() {
        fileOpened = true;
    }

    void onVideoTrackPresence(boolean hasVideo, long nowMs) {
        videoTrack = hasVideo ? VideoTrackPresence.PRESENT : VideoTrackPresence.ABSENT;
        if (!hasVideo) {
            waitingSinceMs = 0L;
            if (fault == FaultCategory.VIDEO_TRACK_NO_FIRST_FRAME
                    || fault == FaultCategory.SURFACE_LOST_PICTURE) {
                fault = FaultCategory.NONE;
            }
        } else if (waitingSinceMs == 0L && isActivelyWaitingForFrame()) {
            waitingSinceMs = nowMs;
        }
    }

    void onDecoderPrepared(long nowMs, boolean willPlayInForeground) {
        fileOpened = true;
        decoderPrepared = true;
        preparedAtMs = nowMs;
        completed = false;
        userWantsPlay = willPlayInForeground;
        playing = willPlayInForeground;
        if (willPlayInForeground && foreground && surfaceValid && !buffering && !reportedStalled) {
            if (frameState == VideoFrameState.NONE && waitingSinceMs == 0L) {
                waitingSinceMs = nowMs;
            }
        } else {
            waitingSinceMs = 0L;
        }
    }

    void onFirstFrameRendered(int surfaceId, long elapsedMs) {
        if (!surfaceValid
                || (surfaceIdentity != 0 && surfaceId != 0 && surfaceId != surfaceIdentity)) {
            return;
        }
        frameState = VideoFrameState.FIRST_FRAME_RENDERED;
        if (firstFrameMs < 0L && elapsedMs >= 0L) {
            firstFrameMs = elapsedMs;
        }
        fault = FaultCategory.NONE;
        waitingSinceMs = 0L;
    }

    void onVideoOutputUnconfirmed() {
        if (frameState == VideoFrameState.NONE
                || frameState == VideoFrameState.RECONFIRM_REQUIRED) {
            frameState = VideoFrameState.OUTPUT_UNCONFIRMED;
        }
    }

    /**
     * Records a libmpv {@code vo-configured} state bound to a specific Surface identity. Stale
     * callbacks belonging to a destroyed or replaced Surface are ignored.
     */
    void onMpvVoConfigured(int surfaceId, boolean configured, long nowMs) {
        if (!mpvEngine
                || !surfaceValid
                || surfaceIdentity == 0
                || surfaceId == 0
                || surfaceId != surfaceIdentity) {
            return;
        }
        if (configured) {
            voConfiguredSurfaceId = surfaceId;
            if (decoderPrepared) {
                if (frameState == VideoFrameState.NONE
                        || frameState == VideoFrameState.RECONFIRM_REQUIRED) {
                    frameState = VideoFrameState.OUTPUT_UNCONFIRMED;
                }
                if (!reportedStalled) {
                    fault = FaultCategory.NONE;
                }
                waitingSinceMs = 0L;
            }
        } else {
            if (voConfiguredSurfaceId == surfaceId) {
                voConfiguredSurfaceId = 0;
            }
            if (decoderPrepared
                    && videoTrack == VideoTrackPresence.PRESENT
                    && !reportedStalled
                    && frameState == VideoFrameState.OUTPUT_UNCONFIRMED) {
                frameState = VideoFrameState.RECONFIRM_REQUIRED;
                waitingSinceMs = isActivelyWaitingForFrame() ? nowMs : 0L;
            }
        }
    }

    boolean isVoConfiguredForCurrentSurface(boolean mpvVoConfiguredForCurrentSurface) {
        if (!mpvEngine || !surfaceValid || surfaceIdentity == 0) return false;
        if (voConfiguredSurfaceId != 0) {
            return voConfiguredSurfaceId == surfaceIdentity;
        }
        return mpvVoConfiguredForCurrentSurface && frameState == VideoFrameState.OUTPUT_UNCONFIRMED;
    }

    void onForegroundChanged(boolean isForeground, long nowMs) {
        boolean wasForeground = foreground;
        foreground = isForeground;
        if (!isForeground) {
            waitingSinceMs = 0L;
            return;
        }
        if (!wasForeground) {
            // Fresh return to foreground: restart active wait timer from now (never count bg time).
            waitingSinceMs = isActivelyWaitingForFrame() ? nowMs : 0L;
        } else if (waitingSinceMs == 0L && isActivelyWaitingForFrame()) {
            waitingSinceMs = nowMs;
        }
    }

    void onPlayStateChanged(boolean isPlaying, boolean wantsPlay, long nowMs) {
        boolean wasActive = playing && userWantsPlay;
        playing = isPlaying;
        userWantsPlay = wantsPlay;
        if (!isPlaying || !wantsPlay) {
            waitingSinceMs = 0L;
            return;
        }
        if (!wasActive) {
            // Fresh resume from pause/background: restart active wait timer from now.
            waitingSinceMs = isActivelyWaitingForFrame() ? nowMs : 0L;
        } else if (waitingSinceMs == 0L && isActivelyWaitingForFrame()) {
            waitingSinceMs = nowMs;
        }
    }

    void onBufferingChanged(boolean isBuffering, long nowMs) {
        buffering = isBuffering;
        if (isBuffering) {
            waitingSinceMs = 0L;
        } else if (isActivelyWaitingForFrame()) {
            waitingSinceMs = nowMs;
        }
    }

    void onCompleted() {
        completed = true;
        playing = false;
        waitingSinceMs = 0L;
    }

    void markReportedStalled() {
        reportedStalled = true;
        waitingSinceMs = 0L;
    }

    /**
     * Dismiss loading overlay once playback has confirmed video output (or when no video frame is
     * expected: audio-only, paused/background, terminal stalled error, or MPV with VO already
     * configured for the current Surface).
     */
    boolean shouldDismissLoading(boolean mpvVoConfigured) {
        if (reportedStalled) return true;
        if (!decoderPrepared) return false;
        if (!foreground || !playing || !userWantsPlay || completed) return true;
        if (videoTrack == VideoTrackPresence.ABSENT) return true;
        if (frameState == VideoFrameState.FIRST_FRAME_RENDERED) return true;
        if (mpvEngine) {
            return frameState == VideoFrameState.OUTPUT_UNCONFIRMED
                    && isVoConfiguredForCurrentSurface(mpvVoConfigured);
        }
        // Keep loading indicator up while Media3/SystemPlayer is still waiting for its first frame
        // on a stream with a confirmed video track (bounded by watchdog).
        return videoTrack == VideoTrackPresence.UNKNOWN && !surfaceValid;
    }

    /**
     * Resolves the distinct UI overlay state so initial first-frame wait, mid-playback buffering,
     * and terminal stalled recovery failure never overwrite each other on 1Hz UI clock ticks.
     */
    UiOverlayMode resolveOverlayMode(boolean mpvVoConfigured) {
        if (reportedStalled) return UiOverlayMode.RECOVERY_STALLED_ERROR;
        if (!decoderPrepared) return UiOverlayMode.INITIAL_LOADING;
        if (buffering) return UiOverlayMode.PLAYBACK_BUFFERING;
        if (shouldDismissLoading(mpvVoConfigured)) return UiOverlayMode.READY_CLEAN;
        return UiOverlayMode.WAITING_FIRST_FRAME;
    }

    /**
     * Live stream quality scoring must NEVER mark a stream healthy solely on SPS video-size
     * metadata when zero frames rendered. Allow only confirmed first frame, or audio-only live
     * radio.
     */
    boolean shouldRecordLiveSuccess() {
        if (!decoderPrepared) return false;
        if (videoTrack == VideoTrackPresence.ABSENT) return true;
        return frameState == VideoFrameState.FIRST_FRAME_RENDERED;
    }

    /**
     * Evaluates whether a genuine "prepared with video track but no rendered frame" fault requires
     * bounded recovery. Strictly gated on foreground + user playing + valid surface + confirmed
     * video track + non-buffering + non-completed + grace period elapsed.
     */
    WatchdogAction evaluateWatchdog(long nowMs, boolean mpvVoConfigured) {
        if (reportedStalled) return WatchdogAction.NONE;
        if (!decoderPrepared
                || !foreground
                || !playing
                || !userWantsPlay
                || buffering
                || completed) {
            return WatchdogAction.NONE;
        }
        if (videoTrack != VideoTrackPresence.PRESENT) return WatchdogAction.NONE;
        if (!surfaceValid) return WatchdogAction.NONE;
        if (frameState == VideoFrameState.FIRST_FRAME_RENDERED) return WatchdogAction.NONE;
        // MPV lacks a strict Surface presentation callback; when vo-configured is confirmed for the
        // CURRENT Surface it stays "OUTPUT_UNCONFIRMED" rather than triggering a false fallback.
        if (mpvEngine
                && frameState == VideoFrameState.OUTPUT_UNCONFIRMED
                && isVoConfiguredForCurrentSurface(mpvVoConfigured)) {
            return WatchdogAction.NONE;
        }
        if (waitingSinceMs <= 0L) {
            waitingSinceMs = nowMs;
            return WatchdogAction.NONE;
        }
        long grace =
                frameState == VideoFrameState.RECONFIRM_REQUIRED || recoveryAttempts > 0
                        ? REBIND_RECONFIRM_GRACE_MS
                        : INITIAL_FIRST_FRAME_GRACE_MS;
        if (nowMs - waitingSinceMs < grace) return WatchdogAction.NONE;

        fault =
                frameState == VideoFrameState.RECONFIRM_REQUIRED
                        ? FaultCategory.SURFACE_LOST_PICTURE
                        : FaultCategory.VIDEO_TRACK_NO_FIRST_FRAME;

        if (!rebindRequested && recoveryAttempts < MAX_RECOVERY_ATTEMPTS) {
            rebindRequested = true;
            recoveryAttempts++;
            waitingSinceMs = nowMs;
            return WatchdogAction.REBIND_SURFACE;
        }
        if (!fallbackRequested && recoveryAttempts < MAX_RECOVERY_ATTEMPTS) {
            fallbackRequested = true;
            recoveryAttempts++;
            waitingSinceMs = nowMs;
            return WatchdogAction.FALLBACK_ONCE;
        }
        reportedStalled = true;
        waitingSinceMs = 0L;
        return WatchdogAction.REPORT_STALLED;
    }

    String diagnosticStateName() {
        if (videoTrack == VideoTrackPresence.ABSENT && decoderPrepared) return "AUDIO_ONLY";
        if (frameState == VideoFrameState.FIRST_FRAME_RENDERED) return "FIRST_FRAME_RENDERED";
        if (frameState == VideoFrameState.OUTPUT_UNCONFIRMED) return "OUTPUT_UNCONFIRMED";
        if (frameState == VideoFrameState.RECONFIRM_REQUIRED) return "RECONFIRM_REQUIRED";
        if (decoderPrepared) return "DECODER_PREPARED";
        if (fileOpened) return "FILE_OPENED";
        return "NONE";
    }
}

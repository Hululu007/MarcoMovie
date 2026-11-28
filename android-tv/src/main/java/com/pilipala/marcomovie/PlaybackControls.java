package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.drawable.ClipDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.LayerDrawable;
import android.text.TextUtils;
import android.view.*;
import android.widget.*;
import com.pilipala.marcomovie.hud.PlaybackStateProbe;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import com.pilipala.marcomovie.hud.SkipCountdownPill;
import com.pilipala.marcomovie.hud.SleepTimerSheet;

import java.util.*;

/** Independent TV playback controls. Every visible action is wired to playback state. */
final class PlaybackControls {
    static final int ICON_PLAY_PAUSE = 0;
    static final int ICON_NEXT = 1;
    static final int ICON_EPISODES = 2;
    static final int ICON_SUBTITLES = 3;
    static final int ICON_AUDIO = 4;
    static final int ICON_LINES = 5;
    static final int ICON_SPEED = 6;
    static final int ICON_MORE = 7;
    static final int ICON_SKIP_INTRO = 8;
    static final int ICON_SKIP_OUTRO = 9;
    static final int ICON_CAST = 10;
    static final int ICON_DECODER = 11;
    static final int ICON_DANMAKU = 12;
    static final int ICON_TRACKS = 13;
    static final int ICON_EPG = 14;
    static final int ICON_SLEEP_TIMER = 15;

    final MainActivity a;
    final boolean modernTv;
    final Cms.Site site;
    final Cms.Video video;
    final Cms.Episode resolved;
    final LinearLayout dockOverlay;
    final SeekBar timeline;
    final SubtitleOverlayView subtitle;
    final VideoOutput surface;
    final PlaybackEffects effects = new PlaybackEffects();
    final DanmakuView danmaku;
    final DanmuOwnership.RequestContext danmuOwner;
    final DanmuOwnership.EpisodeStatus danmuStatus = new DanmuOwnership.EpisodeStatus();
    boolean danmakuLoaded;
    private DanmuSegmentCache danmuSegmentCache;
    private DanmuProvider.CancellationToken danmuMatchToken;
    private DanmuProvider.Candidate activeDanmuCandidate;
    private int danmuSessionSerial;
    private int danmuLoadSerial;
    private String activeDanmuServerSignature = "";
    private String lastObservedDanmuServerSignature = "";
    private boolean lastDanmuTvSeeking;
    private boolean lastDanmuPlaying;
    private float lastDanmuSpeed = 1f;
    private FirstPlayGestureHint firstPlayGestureHint;
    boolean currentMobileLandscape;
    final Map<String, Button> buttons = new LinkedHashMap<>();
    Button lastFocusedModernButton;
    String lastFocusedActionKey = "";
    private HorizontalScrollView classicDockScroller;
    private final List<View> classicGroupDividers = new ArrayList<>();
    private final List<String> classicDividerBeforeKey = new ArrayList<>();
    private final List<String> classicDividerAfterKey = new ArrayList<>();
    TextView buttonTooltip;
    private TooltipBubbleDrawable buttonTooltipBg;
    private Button activeTooltipButton;
    private String activeTooltipKey;
    private Runnable pendingTooltipHide;
    Dialog activeDialog;
    View menuAnchor;
    String lastSubtitle = "";
    boolean dialogOpen, transitioning;
    private TvMarkerHost markerState;
    private final TvMarkerTailGate markerTail = new TvMarkerTailGate();
    private MoviePlayer markerObservedPlayer;
    static final long SKIP_DOUBLE_CLICK_MS = 420L;
    static final int SKIP_TAP_SCHEDULE_SINGLE = 1;
    static final int SKIP_TAP_TRIGGER_DOUBLE = 2;
    static final int SKIP_TAP_FLUSH_OTHER_AND_SCHEDULE = 3;
    private boolean pendingSkipTapActive;
    private boolean pendingSkipTapIntro;
    private long pendingSkipTapAtMs;
    private Runnable pendingSkipTapRunnable;

    // Session-scoped sleep timer (cold-start default OFF; persists across in-place episode
    // transitions within the same playback session, cleared on exit/destroy/new playback session).
    static final SleepTimerSheet.Controller SESSION_SLEEP_TIMER = new SleepTimerSheet.Controller();
    private static boolean preserveSleepTimerForInPlaceSwitch;
    final SkipCountdownPill skipCountdownPill;
    final SleepTimerSheet.WarningPill sleepWarningPill;
    boolean outroSkipCancelledForEpisode;
    private int pendingIntroSkipMs;
    private boolean lastControlsVisibleForSkip;

    static void markSleepTimerInPlaceSwitch() {
        preserveSleepTimerForInPlaceSwitch = true;
    }

    static void clearSleepTimerOnLeave() {
        preserveSleepTimerForInPlaceSwitch = false;
        SESSION_SLEEP_TIMER.cancel();
    }

    /** Reserved Wave 2 danmu mount hook (null in Wave 1; preserves existing DanmakuView). */
    Runnable danmuMountHook;

    FrameLayout firstPlayGestureHintSlot() {
        return a.playerChrome != null ? a.playerChrome.firstPlayGestureHintSlot : null;
    }

    void setDanmuMountHook(Runnable hook) {
        danmuMountHook = hook;
    }

    void updateSafeTop(int safeTopPx) {
        if (sleepWarningPill != null) {
            sleepWarningPill.updateSafeTop(safeTopPx);
        }
    }

    private void hideSleepWarning() {
        if (sleepWarningPill == null) return;
        boolean hadFocus = sleepWarningPill.hasFocus();
        sleepWarningPill.hide();
        syncSleepWarningTvFocusLinks(false);
        if (hadFocus && a.isTvDevice()) {
            if (a.controlsVisible) {
                restoreToolbarFocusAfterSubmenu();
            } else if (a.root != null) {
                a.root.requestFocus();
            }
        }
    }

    private void syncSleepWarningTvFocusLinks(boolean warningVisible) {
        if (!a.isTvDevice() || sleepWarningPill == null) return;
        int warningExtendId = sleepWarningPill.getExtendButtonId();
        if (modernTv) {
            for (Button b : buttons.values()) {
                if (b instanceof ModernIconButton && b.getVisibility() == View.VISIBLE) {
                    b.setNextFocusUpId(
                            SleepTimerSheet.resolveActionUpFocusId(
                                    warningVisible, warningExtendId, b.getId()));
                }
            }
            if (warningVisible) {
                int downId =
                        lastFocusedModernButton != null
                                        && lastFocusedModernButton.getVisibility() == View.VISIBLE
                                ? lastFocusedModernButton.getId()
                                : (timeline != null ? timeline.getId() : View.NO_ID);
                sleepWarningPill.setDownFocusTargetId(downId);
            }
        } else if (timeline != null) {
            timeline.setNextFocusUpId(
                    SleepTimerSheet.resolveActionUpFocusId(
                            warningVisible, warningExtendId, View.NO_ID));
            if (warningVisible) {
                sleepWarningPill.setDownFocusTargetId(timeline.getId());
            }
        }
    }

    boolean canRunSkipCountdown() {
        boolean inPip = android.os.Build.VERSION.SDK_INT >= 24 && a.isInPictureInPictureMode();
        PlaybackStateProbe.Snapshot snap =
                a.player != null && a.prepared ? PlaybackStateProbe.inspect(a.player) : null;
        boolean playbackIntended = PlaybackStateProbe.isPlaybackIntended(a.playing, snap);
        boolean activeDialogShowing = activeDialog != null && activeDialog.isShowing();
        return PlaybackStateProbe.canRunSkipCountdown(
                a.foreground,
                a.miniMode,
                inPip,
                a.playerLocked,
                a.prepared,
                playbackIntended,
                transitioning,
                activeDialogShowing);
    }

    void syncSkipCountdownLifecycle() {
        if (skipCountdownPill != null) {
            skipCountdownPill.syncPlaybackGuard();
        }
    }

    private static int findDanmakuOverlayIndex(ViewGroup playbackLayer) {
        if (playbackLayer == null) return -1;
        int found = -1;
        for (int i = 0; i < playbackLayer.getChildCount(); i++) {
            View child = playbackLayer.getChildAt(i);
            if (child instanceof DanmakuView || "danmaku-view".equals(child.getTag())) {
                found = i;
            }
        }
        return found;
    }

    /**
     * Enforces strict playback layer Z-order: Video surface (0) -> DanmakuView (1) ->
     * SubtitleOverlayView (2) -> HUD overlays (3+), ensuring subtitles always render above danmaku.
     */
    static void mountMediaOverlaysInZOrder(
            ViewGroup playbackLayer,
            View danmakuView,
            ViewGroup.LayoutParams danmakuLp,
            View subtitleView,
            ViewGroup.LayoutParams subtitleLp) {
        if (playbackLayer == null) return;
        if (danmakuView != null) {
            if (danmakuView.getParent() instanceof ViewGroup) {
                ((ViewGroup) danmakuView.getParent()).removeView(danmakuView);
            }
            int danmakuIndex = Math.min(1, playbackLayer.getChildCount());
            if (danmakuLp != null) {
                playbackLayer.addView(danmakuView, danmakuIndex, danmakuLp);
            } else {
                playbackLayer.addView(danmakuView, danmakuIndex);
            }
        }
        if (subtitleView != null) {
            if (subtitleView.getParent() instanceof ViewGroup) {
                ((ViewGroup) subtitleView.getParent()).removeView(subtitleView);
            }
            int subtitleIndex;
            if (danmakuView != null) {
                int dmIdx = playbackLayer.indexOfChild(danmakuView);
                subtitleIndex = dmIdx >= 0 ? dmIdx + 1 : Math.min(2, playbackLayer.getChildCount());
            } else {
                int existingDmIdx = findDanmakuOverlayIndex(playbackLayer);
                subtitleIndex =
                        existingDmIdx >= 0
                                ? existingDmIdx + 1
                                : Math.min(1, playbackLayer.getChildCount());
            }
            if (subtitleLp != null) {
                playbackLayer.addView(subtitleView, subtitleIndex, subtitleLp);
            } else {
                playbackLayer.addView(subtitleView, subtitleIndex);
            }
        }
    }

    void onScreenLockRequested() {
        if (skipCountdownPill != null) {
            skipCountdownPill.dismissSilently();
        }
        hideFirstPlayGestureHint();
    }

    private boolean subtitlePrefAppliedForEpisode = false;
    private boolean audioPrefAppliedForEpisode = false;
    private boolean tvMuteHintShownForEpisode = false;

    void onSwitchingAway() {
        danmuLoadSerial++;
        closeSegmentedDanmuSession();
        if (danmaku != null) {
            danmaku.clearAll();
        }
        danmakuLoaded = false;
        danmuStatus.reset(currentEpisodeDisplayLabel());
    }

    String currentEpisodeDisplayLabel() {
        Cms.Episode ep = a != null && a.activeEpisode != null ? a.activeEpisode : resolved;
        if (ep != null && ep.name != null && !ep.name.trim().isEmpty()) {
            return ep.name.trim();
        }
        int idx = episodeIndex();
        return idx >= 0 ? ("第 " + (idx + 1) + " 集") : "当前剧集";
    }

    private boolean isDanmuOwnerStillActive(DanmuOwnership.RequestContext ownerSnap) {
        return ownerSnap != null
                && DanmuOwnership.GLOBAL.isCurrentOwner(ownerSnap)
                && a.playbackControls == this
                && danmaku != null
                && !danmaku.closed;
    }

    void resetEpisodeTransientState() {
        cancelPendingSkipTap();
        resetMarkers();
        outroSkipCancelledForEpisode = false;
        subtitlePrefAppliedForEpisode = false;
        audioPrefAppliedForEpisode = false;
        tvMuteHintShownForEpisode = false;
        pendingIntroSkipMs = 0;
        pendingResumeMs = 0;
        pendingResumeIsIntro = false;
        if (skipCountdownPill != null) skipCountdownPill.dismissSilently();
        danmuLoadSerial++;
        closeSegmentedDanmuSession();
        if (danmaku != null) {
            danmaku.clearAll();
        }
        danmakuLoaded = false;
        danmuStatus.reset(currentEpisodeDisplayLabel());
        hideFirstPlayGestureHint();
    }

    private void cancelPendingSkipTap() {
        if (pendingSkipTapRunnable != null && a != null && a.ui != null) {
            a.ui.removeCallbacks(pendingSkipTapRunnable);
        }
        pendingSkipTapRunnable = null;
        pendingSkipTapActive = false;
    }

    static int decideSkipTap(
            boolean pendingActive,
            boolean pendingIntro,
            long pendingAtMs,
            boolean tappedIntro,
            long nowMs) {
        if (pendingActive && pendingIntro == tappedIntro) {
            long delta = nowMs - pendingAtMs;
            if (delta >= 0L && delta <= SKIP_DOUBLE_CLICK_MS) {
                return SKIP_TAP_TRIGGER_DOUBLE;
            }
        }
        if (pendingActive && pendingIntro != tappedIntro) {
            return SKIP_TAP_FLUSH_OTHER_AND_SCHEDULE;
        }
        return SKIP_TAP_SCHEDULE_SINGLE;
    }

    static int captureSkipSecondsFromPlayback(
            boolean intro, int currentPlayerPosMs, int currentPlayerDurMs) {
        if (currentPlayerPosMs <= 0) return 0;
        if (intro) {
            return VideoSkipStore.clampSkipSeconds(Math.max(1, currentPlayerPosMs / 1000));
        }
        if (currentPlayerDurMs > currentPlayerPosMs) {
            int remain = (currentPlayerDurMs - currentPlayerPosMs) / 1000;
            if (remain <= 0) return 1;
            if (remain > VideoSkipStore.MAX_SKIP_SECONDS) return -1;
            return VideoSkipStore.clampSkipSeconds(remain);
        }
        return VideoSkipStore.clampSkipSeconds(Math.max(1, currentPlayerPosMs / 1000));
    }

    static int resolveSkipDialogWidthPx(int windowWidthPx, int maxWidthPx, int horizontalMarginPx) {
        int safeWin = Math.max(240, windowWidthPx);
        int bounded = safeWin - Math.max(0, horizontalMarginPx);
        return Math.max(240, Math.min(bounded, maxWidthPx));
    }

    static boolean shouldRecreateMarkerHost(
            boolean hasExisting, boolean sameEpisode, boolean sameLine, boolean valid) {
        return !hasExisting || !sameEpisode || !sameLine || !valid;
    }

    TvMarkerHost markers() {
        if (shouldRecreateMarkerHost(
                markerState != null,
                markerState != null && markerState.episode == a.activeEpisode,
                markerState != null && markerState.line == a.activeLine,
                markerState != null && markerState.valid())) {
            if (markerState != null) markerState.abort();
            markerState = new TvMarkerHost(a, this);
            markerTail.reset();
        }
        return markerState;
    }

    void resetMarkers() {
        if (markerState != null) markerState.abort();
        markerState = null;
        markerTail.reset();
    }

    void refreshMarkerPlaybackMode() {
        if (a.isTvDevice() && a.player != null && a.prepared && !a.isLive() && !a.isCast())
            a.player.setRepeatOne(
                    shouldEnableNativeRepeatOne(
                            a.prefs.getInt(Prefs.REPEAT_MODE, 0),
                            outroPosition(a.player.getDuration()) == 0));
    }

    private static boolean shouldEnableNativeRepeatOne(int repeatMode, boolean noOutroSkip) {
        return repeatMode == 1 && noOutroSkip && !SESSION_SLEEP_TIMER.isEndOfEpisodeMode();
    }

    private int introPosition(int duration) {
        int legacy = getVideoIntro(a, site, video) * 1000;
        return a.isTvDevice() && !a.isLive() && !a.isCast()
                ? (int) Math.min(Integer.MAX_VALUE, markers().effective(true, duration, legacy))
                : legacy;
    }

    private long outroPosition(int duration) {
        long effectiveDur =
                duration > 0 ? duration : (a.player == null ? 0 : a.player.getDuration());
        int tail = getVideoOutro(a, site, video) * 1000;
        long legacy = tail > 0 && tail < effectiveDur ? effectiveDur - tail : 0;
        return a.isTvDevice() && !a.isLive() && !a.isCast()
                ? markers().effective(false, effectiveDur, legacy)
                : legacy;
    }

    boolean touchSeeking, sliderSeeking;
    long lastSeekTimeMs;
    int lastSeekTargetMs = -1;
    int pendingResumeMs;
    boolean pendingResumeIsIntro;
    int videoWidth, videoHeight;

    boolean isUserSeeking() {
        return touchSeeking || sliderSeeking;
    }

    void recordUserSeek(int targetMs) {
        lastSeekTimeMs = android.os.SystemClock.uptimeMillis();
        lastSeekTargetMs = Math.max(0, targetMs);
        PlaybackController.notifyPendingHistoryMigrationSeek(a, lastSeekTargetMs);
        timeline.setProgress(lastSeekTargetMs);
        onDanmuSeekSettled(lastSeekTargetMs);
    }

    void onDanmuSeekInitiated() {
        if (danmaku != null) {
            danmaku.onSeekInitiated();
        }
    }

    void onDanmuSeekSettled(long targetRawPositionMs) {
        if (danmaku != null) {
            danmaku.onSeekSettled(Math.max(0L, targetRawPositionMs));
        }
    }

    void onDanmuPlaySpeedChanged(float speed) {
        if (speed <= 0f) return;
        lastDanmuSpeed = speed;
        if (danmaku != null) {
            danmaku.setPlaySpeed(speed);
        }
    }

    void syncDanmuPlaybackState() {
        if (danmaku == null || danmaku.closed) return;
        reconcileDetachedSegmentedDanmuSession();
        boolean tvSeeking = a.isTvDevice() && a.seekGesture.active;
        if (tvSeeking && !lastDanmuTvSeeking) {
            onDanmuSeekInitiated();
        } else if (!tvSeeking && lastDanmuTvSeeking) {
            long pos = a.player != null && a.prepared ? a.player.getCurrentPosition() : 0L;
            onDanmuSeekSettled(pos);
        }
        lastDanmuTvSeeking = tvSeeking;

        if (a.player != null && a.prepared) {
            float speed = a.player.getSpeed();
            if (speed > 0f && Math.abs(speed - lastDanmuSpeed) > 0.01f) {
                onDanmuPlaySpeedChanged(speed);
            }
        }

        boolean nowPlaying = a.playing && a.player != null && a.prepared;
        if (nowPlaying != lastDanmuPlaying) {
            lastDanmuPlaying = nowPlaying;
            if (danmaku.enabled) {
                if (danmuSegmentCache != null
                        && danmaku.hasSegmentCache()
                        && a.player != null
                        && a.prepared) {
                    danmuSegmentCache.onPlaybackTick(a.player.getCurrentPosition(), nowPlaying);
                }
                danmaku.invalidate();
            }
        }
    }

    static boolean shouldCloseDetachedSegmentCache(
            boolean hasTrackedCache, boolean viewHasSegmentCache) {
        return hasTrackedCache && !viewHasSegmentCache;
    }

    private void reconcileDetachedSegmentedDanmuSession() {
        if (shouldCloseDetachedSegmentCache(
                danmuSegmentCache != null, danmaku != null && danmaku.hasSegmentCache())) {
            closeSegmentedDanmuSession();
        }
    }

    void closeSegmentedDanmuSession() {
        danmuSessionSerial++;
        if (danmuMatchToken != null) {
            danmuMatchToken.cancel();
            danmuMatchToken = null;
        }
        activeDanmuCandidate = null;
        activeDanmuServerSignature = "";
        DanmuSegmentCache cache = danmuSegmentCache;
        danmuSegmentCache = null;
        if (danmaku != null) {
            danmaku.detachSegmentCache();
        }
        if (cache != null) {
            cache.close();
        }
    }

    void loadLocalDanmakuText(String text) {
        final int loadSer = ++danmuLoadSerial;
        final DanmuOwnership.RequestContext ownerSnap = danmuOwner;
        closeSegmentedDanmuSession();
        danmuStatus.markLoading(DanmuOwnership.SourceKind.LOCAL_FILE);
        danmaku.enabled(true);
        danmaku.loadText(
                text,
                new DanmakuView.Listener() {
                    public void loaded(int count) {
                        if (loadSer != danmuLoadSerial || !isDanmuOwnerStillActive(ownerSnap)) {
                            return;
                        }
                        danmakuLoaded = count > 0;
                        if (count > 0) {
                            DanmuOwnership.GLOBAL.markConfirmedDanmuMounted(ownerSnap);
                            danmuStatus.markLoaded(
                                    DanmuOwnership.SourceKind.LOCAL_FILE, count, "", "");
                        } else {
                            danmuStatus.markNoComments(
                                    DanmuOwnership.SourceKind.LOCAL_FILE, "", "");
                        }
                        a.toast("已加载 " + count + " 条弹幕");
                    }

                    public void error(String message) {
                        if (loadSer != danmuLoadSerial || !isDanmuOwnerStillActive(ownerSnap)) {
                            return;
                        }
                        danmakuLoaded = false;
                        danmuStatus.markParseError(DanmuOwnership.SourceKind.LOCAL_FILE, message);
                        a.notice(message);
                    }
                });
    }

    private void maybeShowFirstPlayGestureHint() {
        if (a.isLive() || a.isCast() || a.miniMode || a.playerLocked || transitioning) return;
        FrameLayout slot = firstPlayGestureHintSlot();
        if (slot == null) return;
        if (firstPlayGestureHint == null) {
            firstPlayGestureHint = new FirstPlayGestureHint(a);
            firstPlayGestureHint.setTag("first-play-gesture-hint");
            FrameLayout.LayoutParams lp =
                    new FrameLayout.LayoutParams(
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            lp.leftMargin = a.dp(16);
            lp.rightMargin = a.dp(16);
            lp.bottomMargin = a.dp(a.isTvDevice() ? 132 : 96);
            slot.addView(firstPlayGestureHint, lp);
        }
        boolean reducedTransparency =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        boolean shown =
                firstPlayGestureHint.showIfEligible(
                        a.isTvDevice(),
                        a.reduced,
                        reducedTransparency,
                        () -> {
                            FrameLayout s = firstPlayGestureHintSlot();
                            if (s != null) s.setVisibility(View.GONE);
                        });
        slot.setVisibility(shown ? View.VISIBLE : View.GONE);
    }

    private void hideFirstPlayGestureHint() {
        if (firstPlayGestureHint != null) {
            firstPlayGestureHint.hideImmediate();
        }
        FrameLayout slot = firstPlayGestureHintSlot();
        if (slot != null) {
            slot.setVisibility(View.GONE);
        }
    }

    static boolean shouldHoldSeekTargetPosition(
            int actualPositionMs, int seekTargetMs, long elapsedSinceSeekMs, boolean seekInFlight) {
        if (seekTargetMs < 0 || elapsedSinceSeekMs >= 3500L) return false;
        if (Math.abs(actualPositionMs - seekTargetMs) <= 2500) return false;
        if (!seekInFlight
                && actualPositionMs > seekTargetMs
                && elapsedSinceSeekMs > 0L
                && (long) (actualPositionMs - seekTargetMs)
                        <= Math.max(2500L, elapsedSinceSeekMs * 2L + 500L)) {
            return false;
        }
        return true;
    }

    int displayPosition(int actualPositionMs) {
        if (lastSeekTargetMs >= 0) {
            long elapsed = android.os.SystemClock.uptimeMillis() - lastSeekTimeMs;
            boolean seekInFlight = a != null && a.player != null && a.player.isSeekInFlight();
            if (shouldHoldSeekTargetPosition(
                    actualPositionMs, lastSeekTargetMs, elapsed, seekInFlight)) {
                return lastSeekTargetMs;
            }
            if (!seekInFlight) {
                lastSeekTargetMs = -1;
            }
        }
        return actualPositionMs;
    }

    PlaybackControls(
            MainActivity host,
            LinearLayout overlay,
            LinearLayout progress,
            VideoOutput texture,
            Cms.Site s,
            Cms.Video v,
            Cms.Episode ep) {
        a = host;
        boolean preservedSleep = preserveSleepTimerForInPlaceSwitch;
        preserveSleepTimerForInPlaceSwitch = false;
        SESSION_SLEEP_TIMER.onNewPlaybackSession(
                preservedSleep, android.os.SystemClock.elapsedRealtime());
        lastControlsVisibleForSkip = a.controlsVisible;
        modernTv = a.isTvDevice() && a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
        site = s;
        video = v;
        resolved = ep;
        danmuOwner =
                a.activeDanmuContext != null
                        ? a.activeDanmuContext
                        : PlaybackController.ensureDanmuContext(
                                a,
                                s,
                                v,
                                a.activeLine,
                                a.activeEpisode != null ? a.activeEpisode : ep);
        danmuStatus.reset(currentEpisodeDisplayLabel());
        dockOverlay =
                (modernTv && host.playerChrome != null && host.playerChrome.actionHost != null)
                        ? host.playerChrome.actionHost
                        : overlay;
        if (dockOverlay != null) {
            dockOverlay.setMotionEventSplittingEnabled(false);
        }
        surface = texture;
        danmaku =
                new DanmakuView(
                        a,
                        new DanmakuView.Clock() {
                            public int position() {
                                return a.player == null ? 0 : a.player.getCurrentPosition();
                            }

                            public boolean playing() {
                                return a.player != null && a.player.isPlaying();
                            }
                        });
        danmaku.setTag("danmaku-view");
        subtitle = new SubtitleOverlayView(a);
        subtitle.setUserDefaultStyle();
        subtitle.setPadding(a.dp(40), 0, a.dp(40), a.dp(12));
        FrameLayout.LayoutParams caption = new FrameLayout.LayoutParams(-1, -1, Gravity.BOTTOM);
        caption.bottomMargin = a.dp(168);
        mountMediaOverlaysInZOrder(
                a.playbackLayer, danmaku, new FrameLayout.LayoutParams(-1, -1), subtitle, caption);
        DanmuSettingsPanel.DanmuConfig initialDanmuCfg =
                DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        lastObservedDanmuServerSignature = danmuServerSignature(initialDanmuCfg);
        danmaku.applyConfig(initialDanmuCfg);
        applySubtitleStyle();
        boolean reducedTransparency =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        skipCountdownPill = new SkipCountdownPill(a, a.isTvDevice());
        skipCountdownPill.setReducedTransparency(reducedTransparency);
        skipCountdownPill.setPlaybackGuard(this::canRunSkipCountdown);
        skipCountdownPill.setTouchInteractionHook(
                () -> {
                    if (a.touchPlayerGesture != null) a.touchPlayerGesture.cancelActiveGesture();
                });
        skipCountdownPill.setSilentDismissListener(
                wasIntro -> {
                    if (!wasIntro && !outroSkipCancelledForEpisode) {
                        // Allow TV outro skip to cleanly re-evaluate when foreground playback
                        // resumes after pause/call/background without marking user-cancelled.
                        markerTail.reset();
                    }
                });
        skipCountdownPill.setCallbacks(
                new SkipCountdownPill.Callbacks() {
                    @Override
                    public void onSkipExecute(boolean intro, int targetPositionMs) {
                        if (intro) pendingIntroSkipMs = 0;
                        executeSkipAction(intro, targetPositionMs);
                    }

                    @Override
                    public void onCancelled(boolean intro) {
                        if (intro) {
                            pendingIntroSkipMs = 0;
                        } else {
                            outroSkipCancelledForEpisode = true;
                        }
                    }

                    @Override
                    public void onTvDialogStateChanged(boolean open) {
                        if (open) {
                            dialogOpen = true;
                            hideButtonTooltip(true);
                        } else if (activeDialog == null || !activeDialog.isShowing()) {
                            dialogOpen = false;
                            if (a.isTvDevice()) {
                                View curFocus = a.getCurrentFocus();
                                boolean focusStillOnSkip =
                                        curFocus == null
                                                || curFocus == skipCountdownPill
                                                || (curFocus.getParent() != null
                                                        && curFocus.getParent().getParent()
                                                                == skipCountdownPill);
                                if (focusStillOnSkip) {
                                    if (a.controlsVisible) {
                                        if (timeline != null) timeline.requestFocus();
                                    } else if (a.root != null) {
                                        a.root.requestFocus();
                                    }
                                }
                                if (a.controlsVisible && a.playing) {
                                    a.scheduleHide();
                                }
                            }
                        }
                    }

                    @Override
                    public void onTvMediaKey(int keyCode) {
                        if (keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                                || (keyCode == KeyEvent.KEYCODE_MEDIA_PLAY && !a.playing)
                                || (keyCode == KeyEvent.KEYCODE_MEDIA_PAUSE && a.playing)) {
                            a.togglePlayback();
                        }
                        a.showControls(true);
                    }

                    @Override
                    public void onTvMenuKey() {
                        a.showControls(true);
                        focusPrimaryAction();
                    }
                });
        FrameLayout.LayoutParams skipLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.RIGHT);
        skipLp.rightMargin = a.dp(a.isTvDevice() ? 36 : 20);
        skipLp.bottomMargin = a.dp(a.isTvDevice() ? 96 : 84);
        a.playbackLayer.addView(skipCountdownPill, skipLp);

        sleepWarningPill =
                new SleepTimerSheet.WarningPill(
                        a,
                        a.isTvDevice(),
                        () -> {
                            SESSION_SLEEP_TIMER.extend15Minutes(
                                    android.os.SystemClock.elapsedRealtime());
                            hideSleepWarning();
                            if (a.playerChrome != null) {
                                a.playerChrome.syncSleepHudPill(
                                        android.os.SystemClock.elapsedRealtime());
                            }
                            a.toast("定时关闭已延长 15 分钟");
                        },
                        () -> {
                            SESSION_SLEEP_TIMER.cancel();
                            hideSleepWarning();
                            if (a.playerChrome != null) a.playerChrome.syncSleepHudPill(0L);
                            a.toast("已取消定时关闭");
                        });
        sleepWarningPill.setReducedTransparency(reducedTransparency);
        sleepWarningPill.setTouchInteractionHook(
                () -> {
                    if (a.touchPlayerGesture != null) a.touchPlayerGesture.cancelActiveGesture();
                });
        FrameLayout.LayoutParams sleepLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        int initialSafeTop = a.playerChrome != null ? a.playerChrome.windowInsets.top : 0;
        sleepLp.topMargin =
                SleepTimerSheet.computeWarningTopMarginPx(
                        a.isTvDevice(),
                        initialSafeTop,
                        a.getResources().getDisplayMetrics().density);
        a.playbackLayer.addView(sleepWarningPill, sleepLp);

        timeline = new SeekBar(a);
        timeline.setTag("timeline");
        timeline.setBackgroundColor(Color.TRANSPARENT);
        UiCompat.setDefaultFocusHighlightEnabled(timeline, false);
        timeline.setFocusable(true);
        if (a.isTvDevice()) {
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                timeline.setMinHeight(0);
            }
            timeline.setMinimumHeight(0);
            styleModernTimeline(false);
            timeline.setOnFocusChangeListener((focusedView, f) -> styleModernTimeline(f));
            timeline.setKeyProgressIncrement(15000);
            progress.addView(
                    timeline,
                    new LinearLayout.LayoutParams(-1, PlayerChrome.vp(a, modernTv ? 15 : 18)));
        } else {
            timeline.setOnFocusChangeListener(
                    (focusedView, f) ->
                            FocusMotion.style(
                                    a,
                                    timeline,
                                    f,
                                    0,
                                    0x16ffffff,
                                    16,
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    false,
                                    1));
            UiCompat.tintSeekBar(timeline, 0xfff5f5f7, Color.WHITE);
            if (!a.isTvDevice()) {
                timeline.setPadding(a.dp(8), 0, a.dp(8), 0);
            }
            timeline.setKeyProgressIncrement(15000);
            progress.addView(timeline, new LinearLayout.LayoutParams(-1, a.dp(32)));
        }
        timeline.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    public void onStartTrackingTouch(SeekBar b) {
                        if (a.touchPlayerGesture != null) {
                            a.touchPlayerGesture.cancelActiveGesture();
                        }
                        sliderSeeking = true;
                        onDanmuSeekInitiated();
                        a.finishSeek(false);
                        a.scheduleHide();
                    }

                    public void onStopTrackingTouch(SeekBar b) {
                        boolean wasDragging = sliderSeeking;
                        sliderSeeking = false;
                        if (wasDragging && a.prepared && a.player != null) {
                            int target = b.getProgress();
                            recordUserSeek(target);
                            a.player.seekTo(target);
                            if (a.playClock != null && a.player.getDuration() > 0) {
                                a.playClock.setText(
                                        PlaybackController.formatTime(target)
                                                + " / "
                                                + PlaybackController.formatTime(
                                                        a.player.getDuration()));
                            }
                        } else if (wasDragging) {
                            onDanmuSeekSettled(
                                    a.player != null && a.prepared
                                            ? a.player.getCurrentPosition()
                                            : 0L);
                        }
                        a.scheduleHide();
                    }

                    public void onProgressChanged(SeekBar b, int position, boolean user) {
                        if (user && a.prepared && a.player != null) {
                            if (sliderSeeking) {
                                if (a.playClock != null && a.player.getDuration() > 0) {
                                    a.playClock.setText(
                                            PlaybackController.formatTime(position)
                                                    + " / "
                                                    + PlaybackController.formatTime(
                                                            a.player.getDuration()));
                                }
                            } else {
                                recordUserSeek(position);
                                a.player.seekTo(position);
                            }
                            a.scheduleHide();
                        }
                    }
                });
        boolean mobileLandscape = !a.isTvDevice() && !a.isPortrait();
        currentMobileLandscape = mobileLandscape;
        LinearLayout row = a.row();
        boolean live = "live".equals(site.key);
        String savedToolbarOrder =
                a.prefs != null ? a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, "") : "";
        if (a.isTvDevice()) {
            populateTvToolbarButtons(row, savedToolbarOrder, live);
        } else {
            add(
                    row,
                    "锁定",
                    "lock-tool",
                    () -> {
                        if (a.touchPlayerGesture != null) {
                            a.touchPlayerGesture.onScreenLockRequested();
                        }
                        onScreenLockRequested();
                        PlaybackController.setPlayerLocked(a, true);
                    });
            add(
                    row,
                    live ? "上台" : "上集",
                    "prev-episode",
                    () -> {
                        if (live) a.liveStep(-1);
                        else if (!step(-1))
                            showBubble("已是第一集", new String[] {"知道了"}, -1, i -> {}, "");
                    });
            add(
                    row,
                    live ? "下台" : "下集",
                    "next-episode",
                    () -> {
                        if (live) a.liveStep(1);
                        else if (!step(1)) showBubble("无下集", new String[] {"知道了"}, -1, i -> {}, "");
                    });
            add(
                    row,
                    live ? "频道" : "选集",
                    "episodes",
                    () -> {
                        if (live) a.chooseLiveChannel();
                        else chooseEpisodes();
                    });
            add(
                    row,
                    "换源",
                    "lines",
                    () -> {
                        if (live) a.chooseLiveStream();
                        else chooseLine();
                    });
            add(row, "1.0×", "speed", this::speed);
            add(row, "画面", "aspect", this::aspect);
            add(row, "字幕", "subtitles", () -> tracks(3));
            add(row, "全屏", "fullscreen-tool", a::togglePlayerOrientation);
            add(row, "音轨", "audio-tracks", () -> tracks(1));
            add(row, "解码", "decoder", this::decoderMenu);
            add(row, "弹幕", "danmaku-tool", this::danmaku);
            add(row, "片头", "skip-intro-tool", () -> skip(true));
            add(row, "片尾", "skip-outro-tool", () -> skip(false));
            add(row, "循环", "repeat-tool", this::repeat);
            if (live) {
                for (String vodKey :
                        new String[] {
                            "speed", "skip-intro-tool", "skip-outro-tool", "repeat-tool"
                        }) {
                    Button vodBtn = buttons.get(vodKey);
                    if (vodBtn != null) vodBtn.setVisibility(View.GONE);
                }
            }
            add(
                    row,
                    "重播",
                    "restart-tool",
                    () -> {
                        if (a.player != null && a.prepared) {
                            recordUserSeek(0);
                            a.player.seekTo(0);
                            a.player.start();
                            a.playing = true;
                        } else reload(false);
                    });
            add(row, "更多", "more", this::more);
        }
        timeline.setId(UiCompat.generateViewId());
        List<Button> all = new ArrayList<>();
        for (int i = 0; i < row.getChildCount(); i++) {
            View child = row.getChildAt(i);
            if (child instanceof Button) all.add((Button) child);
        }
        for (Button b : all) b.setId(UiCompat.generateViewId());
        if (!a.isTvDevice()) {
            for (Button b : all) b.setNextFocusUpId(timeline.getId());
            if (!all.isEmpty()) {
                timeline.setNextFocusDownId(all.get(0).getId());
                all.get(0).setNextFocusLeftId(all.get(all.size() - 1).getId());
                all.get(all.size() - 1).setNextFocusRightId(all.get(0).getId());
                all.get(0)
                        .setOnKeyListener(
                                (view, key, event) -> {
                                    if (key != KeyEvent.KEYCODE_DPAD_LEFT) return false;
                                    if (event.getAction() == KeyEvent.ACTION_DOWN)
                                        all.get(all.size() - 1).requestFocus();
                                    return true;
                                });
                all.get(all.size() - 1)
                        .setOnKeyListener(
                                (view, key, event) -> {
                                    if (key != KeyEvent.KEYCODE_DPAD_RIGHT) return false;
                                    if (event.getAction() == KeyEvent.ACTION_DOWN)
                                        all.get(0).requestFocus();
                                    return true;
                                });
            }
        }
        rebuildToolDock(mobileLandscape);
        initButtonTooltip();
        updateLabels();
    }

    private void populateTvToolbarButtons(
            LinearLayout row, String savedToolbarOrder, boolean live) {
        List<String> keys = TvPlayerToolbarOrder.resolveOrder(savedToolbarOrder, modernTv, live);
        for (String actionKey : keys) {
            addTvToolbarAction(row, actionKey, live);
        }
        if (!buttons.containsKey(TvPlayerToolbarOrder.KEY_DECODER)) {
            registerHiddenAction(TvPlayerToolbarOrder.KEY_DECODER, this::decoderMenu);
        }
        if (!buttons.containsKey("aspect")) {
            registerHiddenAction("aspect", this::aspect);
        }
        if (!buttons.containsKey(TvPlayerToolbarOrder.KEY_SUBTITLES)) {
            registerHiddenAction(TvPlayerToolbarOrder.KEY_SUBTITLES, this::subtitleQuickMenu);
        }
        if (!buttons.containsKey(TvPlayerToolbarOrder.KEY_DANMAKU)) {
            registerHiddenAction(TvPlayerToolbarOrder.KEY_DANMAKU, this::danmaku);
        }
    }

    /** Rebuilds the TV toolbar buttons in-place after custom order changes without interrupting playback. */
    void rebuildTvToolbarFromPrefs() {
        if (!a.isTvDevice() || dockOverlay == null) return;
        boolean live = "live".equals(site.key);
        String savedToolbarOrder =
                a.prefs != null ? a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, "") : "";
        hideButtonTooltip(true);
        buttons.clear();
        lastFocusedModernButton = null;
        LinearLayout stagingRow = a.row();
        populateTvToolbarButtons(stagingRow, savedToolbarOrder, live);
        for (Button b : buttons.values()) {
            b.setId(UiCompat.generateViewId());
        }
        rebuildToolDock(currentMobileLandscape);
        updateLabels();
        Button moreBtn = buttons.get(TvPlayerToolbarOrder.KEY_MORE);
        if (moreBtn != null && moreBtn.getVisibility() == View.VISIBLE) {
            moreBtn.requestFocus();
        } else {
            focusPrimaryAction();
        }
    }

    private void addTvToolbarAction(LinearLayout row, String key, boolean live) {
        switch (key) {
            case TvPlayerToolbarOrder.KEY_PLAY_PAUSE:
                addModernIcon(
                        row,
                        "播放 / 暂停",
                        TvPlayerToolbarOrder.KEY_PLAY_PAUSE,
                        ICON_PLAY_PAUSE,
                        () -> {
                            if (!a.prepared
                                    && a.playerChrome != null
                                    && a.playerChrome.terminalError) {
                                reload(false);
                                return;
                            }
                            boolean wasVisible = a.controlsVisible;
                            a.togglePlayback();
                            if (PlaybackController.shouldShowHudOnPauseToggle(
                                    a.isTvDevice(), wasVisible, a.playing)) {
                                a.showControls(true);
                            } else if (wasVisible && !a.playing) {
                                a.showControls(false);
                            } else if (a.playerChrome != null) {
                                a.playerChrome.update();
                            }
                        });
                break;
            case TvPlayerToolbarOrder.KEY_NEXT_EPISODE:
                addModernIcon(
                        row,
                        live ? "下台" : "下一集",
                        TvPlayerToolbarOrder.KEY_NEXT_EPISODE,
                        ICON_NEXT,
                        () -> {
                            if (live) a.liveStep(1);
                            else if (!step(1))
                                showBubble("无下集", new String[] {"知道了"}, -1, i -> {}, "");
                        });
                break;
            case TvPlayerToolbarOrder.KEY_EPISODES:
                addModernIcon(
                        row,
                        live ? "频道" : "选集",
                        TvPlayerToolbarOrder.KEY_EPISODES,
                        ICON_EPISODES,
                        () -> {
                            if (live) a.chooseLiveChannel();
                            else chooseEpisodes();
                        });
                break;
            case TvPlayerToolbarOrder.KEY_LINES:
                addModernIcon(
                        row,
                        live ? "线路" : "线路 / 画质",
                        TvPlayerToolbarOrder.KEY_LINES,
                        ICON_LINES,
                        () -> {
                            if (live) a.chooseLiveStream();
                            else chooseLine();
                        });
                break;
            case TvPlayerToolbarOrder.KEY_DANMAKU:
                addModernIcon(
                        row, "弹幕", TvPlayerToolbarOrder.KEY_DANMAKU, ICON_DANMAKU, this::danmaku);
                break;
            case TvPlayerToolbarOrder.KEY_SPEED:
                addModernIcon(row, "倍速", TvPlayerToolbarOrder.KEY_SPEED, ICON_SPEED, this::speed);
                break;
            case TvPlayerToolbarOrder.KEY_TRACKS:
                addModernIcon(
                        row,
                        "字幕 / 音轨",
                        TvPlayerToolbarOrder.KEY_TRACKS,
                        ICON_TRACKS,
                        this::tracksCombinedMenu);
                break;
            case TvPlayerToolbarOrder.KEY_EPG:
                addModernIcon(
                        row,
                        "节目单",
                        TvPlayerToolbarOrder.KEY_EPG,
                        ICON_EPG,
                        () -> LiveController.showEpgAndCatchupDialog(a));
                break;
            case TvPlayerToolbarOrder.KEY_SUBTITLES:
                addModernIcon(
                        row,
                        "字幕",
                        TvPlayerToolbarOrder.KEY_SUBTITLES,
                        ICON_SUBTITLES,
                        this::subtitleQuickMenu);
                break;
            case TvPlayerToolbarOrder.KEY_AUDIO_TRACKS:
                addModernIcon(
                        row,
                        "音轨",
                        TvPlayerToolbarOrder.KEY_AUDIO_TRACKS,
                        ICON_AUDIO,
                        () -> tracks(1));
                break;
            case TvPlayerToolbarOrder.KEY_DECODER:
                addModernIcon(
                        row,
                        "解码",
                        TvPlayerToolbarOrder.KEY_DECODER,
                        ICON_DECODER,
                        this::decoderMenu);
                break;
            case TvPlayerToolbarOrder.KEY_SLEEP_TIMER:
                addModernIcon(
                        row,
                        "定时关闭",
                        TvPlayerToolbarOrder.KEY_SLEEP_TIMER,
                        ICON_SLEEP_TIMER,
                        this::sleepTimerMenu);
                break;
            case TvPlayerToolbarOrder.KEY_SKIP_INTRO:
                addModernIcon(
                        row,
                        "片头",
                        TvPlayerToolbarOrder.KEY_SKIP_INTRO,
                        ICON_SKIP_INTRO,
                        () -> skip(true));
                break;
            case TvPlayerToolbarOrder.KEY_SKIP_OUTRO:
                addModernIcon(
                        row,
                        "片尾",
                        TvPlayerToolbarOrder.KEY_SKIP_OUTRO,
                        ICON_SKIP_OUTRO,
                        () -> skip(false));
                break;
            case TvPlayerToolbarOrder.KEY_MORE:
                addModernIcon(row, "更多", TvPlayerToolbarOrder.KEY_MORE, ICON_MORE, this::more);
                break;
        }
    }

    private void initButtonTooltip() {
        if (!a.isTvDevice() || a.playerChrome == null || a.playerChrome.overlay == null) return;
        float u = PlayerChrome.modernUnit(a);
        boolean reducedTrans =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        int arrowH = modernTv ? PlayerChrome.vp(a, 5f) : a.dp(5f);
        float arrowHalfW = modernTv ? u * 5f : a.dp(5f);
        float cornerRadius = modernTv ? u * 8.5f : a.dp(8.5f);
        float strokeW = Math.max(1f, modernTv ? u * 0.75f : a.dp(0.8f));
        int fillColor = reducedTrans ? 0xf61d212a : 0xec1b1f29;
        buttonTooltipBg =
                new TooltipBubbleDrawable(
                        fillColor, 0x3dffffff, strokeW, cornerRadius, arrowH, arrowHalfW);
        TextView tip = a.text("", 12f, 0xfff5f7fb);
        tip.setTag("player-button-tooltip");
        tip.setFocusable(false);
        tip.setClickable(false);
        tip.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        tip.setSingleLine(true);
        tip.setIncludeFontPadding(false);
        tip.setGravity(Gravity.CENTER);
        if (modernTv) {
            tip.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.2f);
            tip.setTypeface(
                    android.graphics.Typeface.create(
                            "sans-serif-medium", android.graphics.Typeface.NORMAL));
            int padH = PlayerChrome.vp(a, 10.5f);
            int padTop = PlayerChrome.vp(a, 4.5f);
            tip.setPadding(padH, padTop, padH, padTop + arrowH);
        } else {
            tip.setTextSize(12f);
            tip.setTypeface(
                    android.graphics.Typeface.create(
                            "sans-serif-medium", android.graphics.Typeface.BOLD));
            int padH = a.dp(11);
            int padTop = a.dp(5);
            tip.setPadding(padH, padTop, padH, padTop + arrowH);
        }
        tip.setBackground(buttonTooltipBg);
        UiCompat.setElevation(tip, modernTv ? PlayerChrome.vp(a, 14) : a.dp(14));
        tip.setVisibility(View.GONE);
        tip.setAlpha(0f);
        a.playerChrome.overlay.addView(
                tip, new FrameLayout.LayoutParams(-2, -2, Gravity.LEFT | Gravity.TOP));
        buttonTooltip = tip;
    }

    private String tooltipLabelFor(String key) {
        boolean live = "live".equals(site.key);
        float rate = a.prefs != null ? a.prefs.getFloat(Prefs.PLAY_SPEED, 1f) : 1f;
        int introSec = live ? 0 : getVideoIntro(a, site, video);
        int outroSec = live ? 0 : getVideoOutro(a, site, video);
        int engineMode = a.prefs != null ? a.prefs.getInt(Prefs.PLAYER_ENGINE, 0) : 0;
        return TvPlayerToolbarOrder.tooltipLabel(
                key, live, a.playing, rate, introSec, outroSec, engineMode);
    }

    void showButtonTooltip(final Button anchor, final String key) {
        if (!a.isTvDevice()
                || buttonTooltip == null
                || a.playerChrome == null
                || a.playerChrome.overlay == null
                || anchor == null
                || key == null) {
            return;
        }
        if (pendingTooltipHide != null && a.ui != null) {
            a.ui.removeCallbacks(pendingTooltipHide);
            pendingTooltipHide = null;
        }
        if (!a.controlsVisible
                || dialogOpen
                || a.miniMode
                || a.playerChrome.progressOnlyMode
                || anchor.getVisibility() != View.VISIBLE) {
            hideButtonTooltip(true);
            return;
        }
        String label = tooltipLabelFor(key);
        if (label.isEmpty()) {
            hideButtonTooltip(true);
            return;
        }
        activeTooltipButton = anchor;
        activeTooltipKey = key;
        if (!label.contentEquals(buttonTooltip.getText())) {
            buttonTooltip.setText(label);
        }
        final FrameLayout overlay = a.playerChrome.overlay;
        if (overlay.getWidth() > 0 && anchor.getWidth() > 0 && anchor.isAttachedToWindow()) {
            positionButtonTooltip(anchor, true);
        }
        anchor.post(
                () -> {
                    if (a.isFinishing()
                            || a.playbackControls != this
                            || activeTooltipButton != anchor
                            || !anchor.hasFocus()
                            || !a.controlsVisible
                            || dialogOpen
                            || a.miniMode
                            || (a.playerChrome != null && a.playerChrome.progressOnlyMode)) {
                        return;
                    }
                    positionButtonTooltip(anchor, buttonTooltip.getVisibility() != View.VISIBLE);
                });
    }

    private void positionButtonTooltip(Button anchor, boolean animateIfNewlyShown) {
        if (buttonTooltip == null
                || buttonTooltipBg == null
                || a.playerChrome == null
                || a.playerChrome.overlay == null
                || anchor == null
                || !anchor.isAttachedToWindow()) {
            return;
        }
        FrameLayout overlay = a.playerChrome.overlay;
        int contentW = overlay.getWidth() - overlay.getPaddingLeft() - overlay.getPaddingRight();
        int contentH = overlay.getHeight() - overlay.getPaddingTop() - overlay.getPaddingBottom();
        if (contentW <= 0 || contentH <= 0 || anchor.getWidth() <= 0) return;

        int edgeMargin = modernTv ? PlayerChrome.vp(a, 12) : a.dp(12);
        int maxTipW = Math.max(1, contentW - edgeMargin * 2);
        buttonTooltip.measure(
                View.MeasureSpec.makeMeasureSpec(maxTipW, View.MeasureSpec.AT_MOST),
                View.MeasureSpec.makeMeasureSpec(contentH, View.MeasureSpec.AT_MOST));
        int tipW = buttonTooltip.getMeasuredWidth();
        int tipH = buttonTooltip.getMeasuredHeight();
        if (tipW <= 0 || tipH <= 0) return;

        int[] overlayLoc = new int[2];
        int[] anchorLoc = new int[2];
        overlay.getLocationInWindow(overlayLoc);
        anchor.getLocationInWindow(anchorLoc);
        int anchorTopWindowY = anchorLoc[1];
        if (a.playerChrome.dock != null
                && a.playerChrome.dock.getVisibility() == View.VISIBLE
                && a.playerChrome.dock.getHeight() > 0) {
            int[] dockLoc = new int[2];
            a.playerChrome.dock.getLocationInWindow(dockLoc);
            if (dockLoc[1] > 0) {
                anchorTopWindowY = Math.min(anchorLoc[1], dockLoc[1]);
            }
        }
        int anchorCenterX =
                (anchorLoc[0] + anchor.getWidth() / 2) - overlayLoc[0] - overlay.getPaddingLeft();
        int anchorTopY = anchorTopWindowY - overlayLoc[1] - overlay.getPaddingTop();
        int gapPx = modernTv ? PlayerChrome.vp(a, 4.5f) : a.dp(4);
        float minArrowInset = buttonTooltipBg.cornerRadius + buttonTooltipBg.arrowHalfWidth;
        TvPlayerToolbarOrder.TooltipPlacement place =
                TvPlayerToolbarOrder.computeTooltipPlacement(
                        contentW,
                        contentH,
                        anchorCenterX,
                        anchorTopY,
                        tipW,
                        tipH,
                        edgeMargin,
                        gapPx,
                        minArrowInset);

        buttonTooltipBg.setArrowCenterX(place.arrowCenterX);
        buttonTooltip.invalidate();
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) buttonTooltip.getLayoutParams();
        if (lp.leftMargin != place.left || lp.topMargin != place.top) {
            lp.leftMargin = place.left;
            lp.topMargin = place.top;
            buttonTooltip.setLayoutParams(lp);
        }

        boolean wasVisible = buttonTooltip.getVisibility() == View.VISIBLE;
        buttonTooltip.animate().cancel();
        if (!wasVisible) {
            buttonTooltip.setVisibility(View.VISIBLE);
            if (animateIfNewlyShown && !a.reduced) {
                buttonTooltip.setAlpha(0f);
                buttonTooltip.setTranslationY(modernTv ? PlayerChrome.vp(a, 4) : a.dp(4));
                buttonTooltip
                        .animate()
                        .alpha(1f)
                        .translationY(0f)
                        .setDuration(110)
                        .setInterpolator(new android.view.animation.DecelerateInterpolator())
                        .start();
            } else {
                buttonTooltip.setAlpha(1f);
                buttonTooltip.setTranslationY(0f);
            }
        } else {
            buttonTooltip.setAlpha(1f);
            buttonTooltip.setTranslationY(0f);
        }
    }

    private void repositionActiveTooltipIfVisible() {
        if (buttonTooltip == null
                || buttonTooltip.getVisibility() != View.VISIBLE
                || activeTooltipButton == null
                || !activeTooltipButton.hasFocus()) {
            return;
        }
        positionButtonTooltip(activeTooltipButton, false);
    }

    private void scheduleHideButtonTooltip() {
        if (!a.isTvDevice() || buttonTooltip == null) return;
        if (pendingTooltipHide != null && a.ui != null) {
            a.ui.removeCallbacks(pendingTooltipHide);
        }
        pendingTooltipHide =
                () -> {
                    pendingTooltipHide = null;
                    if (a.isFinishing() || a.playbackControls != this) return;
                    if (activeTooltipButton != null
                            && activeTooltipButton.hasFocus()
                            && activeTooltipButton.getVisibility() == View.VISIBLE
                            && a.controlsVisible
                            && !dialogOpen
                            && !a.miniMode
                            && (a.playerChrome == null || !a.playerChrome.progressOnlyMode)) {
                        return;
                    }
                    hideButtonTooltip(false);
                };
        if (a.ui != null) {
            a.ui.post(pendingTooltipHide);
        } else {
            pendingTooltipHide.run();
        }
    }

    void hideButtonTooltip(boolean immediate) {
        if (pendingTooltipHide != null && a.ui != null) {
            a.ui.removeCallbacks(pendingTooltipHide);
            pendingTooltipHide = null;
        }
        activeTooltipButton = null;
        activeTooltipKey = null;
        if (buttonTooltip == null) return;
        buttonTooltip.animate().cancel();
        if (immediate || a.reduced || buttonTooltip.getVisibility() != View.VISIBLE) {
            buttonTooltip.setAlpha(0f);
            buttonTooltip.setTranslationY(0f);
            buttonTooltip.setVisibility(View.GONE);
            return;
        }
        long dur = 90L;
        UiCompat.startWithEndAction(
                buttonTooltip.animate().alpha(0f).setDuration(dur),
                buttonTooltip,
                dur,
                () -> {
                    if (buttonTooltip != null && activeTooltipButton == null) {
                        buttonTooltip.setVisibility(View.GONE);
                        buttonTooltip.setTranslationY(0f);
                    }
                });
    }

    void refreshTooltipForCurrentFocus() {
        if (!a.isTvDevice() || buttonTooltip == null) return;
        if (!a.controlsVisible
                || dialogOpen
                || a.miniMode
                || (a.playerChrome != null && a.playerChrome.progressOnlyMode)) {
            hideButtonTooltip(true);
            return;
        }
        for (Map.Entry<String, Button> entry : buttons.entrySet()) {
            Button btn = entry.getValue();
            if (btn != null && btn.getVisibility() == View.VISIBLE && btn.hasFocus()) {
                showButtonTooltip(btn, entry.getKey());
                return;
            }
        }
        hideButtonTooltip(true);
    }

    static final class TooltipBubbleDrawable extends Drawable {
        final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path path = new Path();
        final RectF arcBox = new RectF();
        final float cornerRadius;
        final float arrowHeight;
        final float arrowHalfWidth;
        final float strokeWidth;
        float arrowCenterX = -1f;

        TooltipBubbleDrawable(
                int fillColor,
                int strokeColor,
                float strokeWidth,
                float cornerRadius,
                float arrowHeight,
                float arrowHalfWidth) {
            this.strokeWidth = strokeWidth;
            this.cornerRadius = cornerRadius;
            this.arrowHeight = arrowHeight;
            this.arrowHalfWidth = arrowHalfWidth;
            fillPaint.setStyle(Paint.Style.FILL);
            fillPaint.setColor(fillColor);
            strokePaint.setStyle(Paint.Style.STROKE);
            strokePaint.setColor(strokeColor);
            strokePaint.setStrokeWidth(strokeWidth);
            strokePaint.setStrokeJoin(Paint.Join.ROUND);
        }

        void setArrowCenterX(float x) {
            if (Math.abs(arrowCenterX - x) > 0.25f) {
                arrowCenterX = x;
                invalidateSelf();
            }
        }

        @Override
        public void draw(Canvas c) {
            Rect b = getBounds();
            if (b.width() <= 0 || b.height() <= 0) return;
            float halfStroke = strokeWidth * 0.5f;
            float l = b.left + halfStroke;
            float t = b.top + halfStroke;
            float r = b.right - halfStroke;
            float pb = b.bottom - arrowHeight - halfStroke;
            float tipY = b.bottom - halfStroke;
            if (r <= l || pb <= t) return;
            float rad = Math.min(cornerRadius, Math.min((r - l) * 0.5f, (pb - t) * 0.5f));
            float minArrowX = l + rad + arrowHalfWidth;
            float maxArrowX = r - rad - arrowHalfWidth;
            float cx = arrowCenterX >= 0f ? arrowCenterX : (l + r) * 0.5f;

            path.reset();
            path.moveTo(l + rad, t);
            path.lineTo(r - rad, t);
            arcBox.set(r - 2f * rad, t, r, t + 2f * rad);
            path.arcTo(arcBox, -90f, 90f, false);
            path.lineTo(r, pb - rad);
            arcBox.set(r - 2f * rad, pb - 2f * rad, r, pb);
            path.arcTo(arcBox, 0f, 90f, false);
            if (minArrowX <= maxArrowX && arrowHeight > 0f) {
                float ax = Math.max(minArrowX, Math.min(maxArrowX, cx));
                path.lineTo(ax + arrowHalfWidth, pb);
                path.lineTo(ax, tipY);
                path.lineTo(ax - arrowHalfWidth, pb);
            }
            path.lineTo(l + rad, pb);
            arcBox.set(l, pb - 2f * rad, l + 2f * rad, pb);
            path.arcTo(arcBox, 90f, 90f, false);
            path.lineTo(l, t + rad);
            arcBox.set(l, t, l + 2f * rad, t + 2f * rad);
            path.arcTo(arcBox, 180f, 90f, false);
            path.close();

            c.drawPath(path, fillPaint);
            if (strokeWidth > 0f) {
                c.drawPath(path, strokePaint);
            }
        }

        @Override
        public void setAlpha(int alpha) {
            fillPaint.setAlpha(alpha);
            strokePaint.setAlpha(alpha);
        }

        @Override
        public void setColorFilter(android.graphics.ColorFilter colorFilter) {
            fillPaint.setColorFilter(colorFilter);
            strokePaint.setColorFilter(colorFilter);
        }

        @Override
        public int getOpacity() {
            return android.graphics.PixelFormat.TRANSLUCENT;
        }
    }

    private void styleModernTimeline(boolean focused) {
        float u = PlayerChrome.modernUnit(a);
        final int barH = Math.max(2, Math.round(u * (focused ? 3.6f : 2.3f)));
        GradientDrawable trackBg = new GradientDrawable();
        trackBg.setColor(focused ? 0x4affffff : 0x32ffffff);
        trackBg.setCornerRadius(barH * .5f);
        GradientDrawable secBg = new GradientDrawable();
        secBg.setColor(0x56ffffff);
        secBg.setCornerRadius(barH * .5f);
        GradientDrawable progBg = new GradientDrawable();
        progBg.setColor(0xfff5f7fb);
        progBg.setCornerRadius(barH * .5f);
        Drawable[] layers =
                new Drawable[] {
                    trackBg,
                    new ClipDrawable(secBg, Gravity.LEFT, ClipDrawable.HORIZONTAL),
                    new ClipDrawable(progBg, Gravity.LEFT, ClipDrawable.HORIZONTAL)
                };
        LayerDrawable ld =
                new LayerDrawable(layers) {
                    @Override
                    protected void onBoundsChange(Rect bounds) {
                        int cy = bounds.centerY();
                        int top = cy - barH / 2;
                        int bottom = top + barH;
                        for (int i = 0; i < getNumberOfLayers(); i++) {
                            getDrawable(i).setBounds(bounds.left, top, bounds.right, bottom);
                        }
                    }
                };
        ld.setId(0, android.R.id.background);
        ld.setId(1, android.R.id.secondaryProgress);
        ld.setId(2, android.R.id.progress);
        int curProg = timeline.getProgress();
        int curMax = timeline.getMax();
        timeline.setProgressDrawable(ld);
        if (curMax > 0) timeline.setMax(curMax);
        timeline.setProgress(curProg);

        int thumbSize = Math.max(6, Math.round(u * (focused ? 10.5f : 7.2f)));
        GradientDrawable thumb = new GradientDrawable();
        thumb.setShape(GradientDrawable.OVAL);
        thumb.setSize(thumbSize, thumbSize);
        thumb.setColor(Color.WHITE);
        if (focused) {
            thumb.setStroke(Math.max(1, Math.round(u * 1.6f)), 0x55ffffff);
        }
        timeline.setThumb(thumb);
        timeline.setThumbOffset(0);
        if (android.os.Build.VERSION.SDK_INT >= 21) {
            timeline.setSplitTrack(false);
        }
        int padH = Math.max(4, Math.round(u * 5.5f));
        timeline.setPadding(padH, 0, padH, 0);
    }

    void refreshPlayPauseGlyph() {
        Button pp = buttons.get("play-pause");
        if (pp != null) {
            pp.setContentDescription(a.playing ? "暂停" : "播放");
            pp.invalidate();
            if (activeTooltipButton == pp && pp.hasFocus()) {
                showButtonTooltip(pp, TvPlayerToolbarOrder.KEY_PLAY_PAUSE);
            }
        }
    }

    void focusPrimaryAction() {
        if (a.isTvDevice()) {
            if (lastFocusedModernButton != null
                    && lastFocusedModernButton.getVisibility() == View.VISIBLE) {
                lastFocusedModernButton.requestFocus();
                return;
            }
            for (Button b : buttons.values()) {
                if (b instanceof ModernIconButton && b.getVisibility() == View.VISIBLE) {
                    b.requestFocus();
                    return;
                }
            }
        }
        for (Button b : buttons.values()) {
            if (b.getVisibility() == View.VISIBLE) {
                b.requestFocus();
                return;
            }
        }
    }

    private boolean hasLinesCapability(boolean live) {
        if (live) return true;
        int lineCount = video != null && video.lines != null ? video.lines.size() : 0;
        int qCount = 0;
        if (a.activeEpisode != null && a.activeEpisode.media != null) {
            org.json.JSONArray qs = a.activeEpisode.media.optJSONArray("qualities");
            if (qs != null) qCount = qs.length();
        }
        boolean localFile =
                "local".equals(site != null ? site.key : "")
                        || (a.activeEpisode != null
                                && NetworkSpeedMonitor.isLocalMediaUrl(a.activeEpisode.url));
        boolean hasCrossSource =
                a.config != null && a.config.sites != null && !a.config.sites.isEmpty();
        return TvPlayerToolbarOrder.shouldShowLinesAction(
                live, lineCount, qCount, localFile, hasCrossSource);
    }

    private boolean hasLiveEpgCapability(boolean live) {
        if (!live || a.liveSession == null || a.liveSession.index < 0) return false;
        if (a.liveSession.epgGuide != null) return true;
        if (a.prefs != null && !a.prefs.getString(Prefs.LIVE_EPG_URL, "").trim().isEmpty()) {
            return true;
        }
        if (a.liveSession.catalog != null && a.liveSession.catalog.options != null) {
            String catEpg = a.liveSession.catalog.options.get("epg");
            String catTvg = a.liveSession.catalog.options.get("url-tvg");
            String catXTvg = a.liveSession.catalog.options.get("x-tvg-url");
            if ((catEpg != null && !catEpg.trim().isEmpty())
                    || (catTvg != null && !catTvg.trim().isEmpty())
                    || (catXTvg != null && !catXTvg.trim().isEmpty())) {
                return true;
            }
        }
        if (a.liveSession.source != null && a.liveSession.source.options != null) {
            String srcEpg = a.liveSession.source.options.get("epg");
            if (srcEpg != null && !srcEpg.trim().isEmpty()) return true;
        }
        LiveCatalog.Channel ch =
                a.liveSession.index >= 0 && a.liveSession.index < a.liveSession.channels.size()
                        ? a.liveSession.channels.get(a.liveSession.index)
                        : null;
        if (ch != null && ch.options != null) {
            String epg = ch.options.get("epg");
            String catchup = ch.options.get("catchup");
            String catchupSrc = ch.options.get("catchup-source");
            if ((epg != null && !epg.trim().isEmpty())
                    || (catchup != null && !catchup.trim().isEmpty())
                    || (catchupSrc != null && !catchupSrc.trim().isEmpty())) {
                return true;
            }
        }
        return false;
    }

    void restoreToolbarFocusAfterSubmenu() {
        if (!a.isTvDevice() || !a.controlsVisible) return;
        if (menuAnchor instanceof Button
                && menuAnchor.isAttachedToWindow()
                && menuAnchor.getVisibility() == View.VISIBLE
                && menuAnchor.isFocusable()) {
            menuAnchor.requestFocus();
            return;
        }
        if (lastFocusedModernButton != null
                && lastFocusedModernButton.isAttachedToWindow()
                && lastFocusedModernButton.getVisibility() == View.VISIBLE) {
            lastFocusedModernButton.requestFocus();
            return;
        }
        if (lastFocusedActionKey != null && !lastFocusedActionKey.isEmpty()) {
            Button byKey = buttons.get(lastFocusedActionKey);
            if (byKey != null
                    && byKey.isAttachedToWindow()
                    && byKey.getVisibility() == View.VISIBLE) {
                byKey.requestFocus();
                return;
            }
        }
        // Fallback: pick nearest surviving visible action button (handles capability
        // disappearance).
        List<Button> allIconBtns = new ArrayList<>();
        int prevIdx = -1;
        int idx = 0;
        for (Map.Entry<String, Button> entry : buttons.entrySet()) {
            Button b = entry.getValue();
            if (!(b instanceof ModernIconButton)) continue;
            if (b == lastFocusedModernButton || entry.getKey().equals(lastFocusedActionKey)) {
                prevIdx = idx;
            }
            allIconBtns.add(b);
            idx++;
        }
        if (prevIdx >= 0) {
            for (int delta = 1; delta < allIconBtns.size(); delta++) {
                int right = prevIdx + delta;
                if (right < allIconBtns.size()
                        && allIconBtns.get(right).getVisibility() == View.VISIBLE) {
                    allIconBtns.get(right).requestFocus();
                    return;
                }
                int left = prevIdx - delta;
                if (left >= 0 && allIconBtns.get(left).getVisibility() == View.VISIBLE) {
                    allIconBtns.get(left).requestFocus();
                    return;
                }
            }
        }
        for (Button b : allIconBtns) {
            if (b.getVisibility() == View.VISIBLE) {
                b.requestFocus();
                return;
            }
        }
        if (timeline != null && timeline.getVisibility() == View.VISIBLE) {
            timeline.requestFocus();
        }
    }

    void syncModernActionVisibility() {
        if (!a.isTvDevice()) return;
        boolean live = "live".equals(site.key);
        boolean multiOrLive =
                live
                        || (a.activeLine != null
                                && a.activeLine.episodes != null
                                && a.activeLine.episodes.size() > 1);
        View prevFocused = a.getCurrentFocus();
        Button nextBtn = buttons.get(TvPlayerToolbarOrder.KEY_NEXT_EPISODE);
        Button epBtn = buttons.get(TvPlayerToolbarOrder.KEY_EPISODES);
        Button linesBtn = buttons.get(TvPlayerToolbarOrder.KEY_LINES);
        Button introBtn = buttons.get(TvPlayerToolbarOrder.KEY_SKIP_INTRO);
        Button outroBtn = buttons.get(TvPlayerToolbarOrder.KEY_SKIP_OUTRO);
        Button speedBtn = buttons.get(TvPlayerToolbarOrder.KEY_SPEED);
        Button danmuBtn = buttons.get(TvPlayerToolbarOrder.KEY_DANMAKU);
        Button tracksBtn = buttons.get(TvPlayerToolbarOrder.KEY_TRACKS);
        Button subBtn = buttons.get(TvPlayerToolbarOrder.KEY_SUBTITLES);
        Button audioBtn = buttons.get(TvPlayerToolbarOrder.KEY_AUDIO_TRACKS);
        Button epgBtn = buttons.get(TvPlayerToolbarOrder.KEY_EPG);
        if (nextBtn instanceof ModernIconButton)
            nextBtn.setVisibility(multiOrLive ? View.VISIBLE : View.GONE);
        if (epBtn instanceof ModernIconButton)
            epBtn.setVisibility(multiOrLive ? View.VISIBLE : View.GONE);
        if (linesBtn instanceof ModernIconButton)
            linesBtn.setVisibility(hasLinesCapability(live) ? View.VISIBLE : View.GONE);
        if (introBtn instanceof ModernIconButton)
            introBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        if (outroBtn instanceof ModernIconButton)
            outroBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        if (speedBtn instanceof ModernIconButton)
            speedBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        if (danmuBtn instanceof ModernIconButton)
            danmuBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        if (tracksBtn instanceof ModernIconButton)
            tracksBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        if (subBtn instanceof ModernIconButton)
            subBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        if (audioBtn instanceof ModernIconButton)
            audioBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        if (epgBtn instanceof ModernIconButton) {
            epgBtn.setVisibility(hasLiveEpgCapability(live) ? View.VISIBLE : View.GONE);
        }

        // Sync non-focusable classic visual group dividers so hidden groups never leave dangling
        // or doubled separators.
        if (!modernTv && !classicGroupDividers.isEmpty()) {
            List<String> visKeys = new ArrayList<>();
            for (Map.Entry<String, Button> entry : buttons.entrySet()) {
                Button b = entry.getValue();
                if (b instanceof ModernIconButton && b.getVisibility() == View.VISIBLE) {
                    visKeys.add(entry.getKey());
                }
            }
            for (int dIdx = 0; dIdx < classicGroupDividers.size(); dIdx++) {
                View div = classicGroupDividers.get(dIdx);
                String beforeK = classicDividerBeforeKey.get(dIdx);
                String afterK = classicDividerAfterKey.get(dIdx);
                int idxBefore = visKeys.indexOf(beforeK);
                int idxAfter = visKeys.indexOf(afterK);
                boolean showDiv = false;
                if (idxBefore >= 0 && idxBefore + 1 < visKeys.size()) {
                    String nextVisKey = visKeys.get(idxBefore + 1);
                    if (nextVisKey.equals(afterK)
                            || (idxAfter < 0
                                    && TvPlayerToolbarOrder.groupBucket(beforeK, live)
                                            != TvPlayerToolbarOrder.groupBucket(
                                                    nextVisKey, live))) {
                        // Show divider only once between two adjacent visible buttons of different
                        // buckets.
                        boolean earlierDividerAlreadyShown = false;
                        for (int prev = 0; prev < dIdx; prev++) {
                            if (classicGroupDividers.get(prev).getVisibility() == View.VISIBLE
                                    && visKeys.indexOf(classicDividerBeforeKey.get(prev))
                                            == idxBefore) {
                                earlierDividerAlreadyShown = true;
                                break;
                            }
                        }
                        showDiv =
                                !earlierDividerAlreadyShown
                                        && TvPlayerToolbarOrder.groupBucket(beforeK, live)
                                                != TvPlayerToolbarOrder.groupBucket(
                                                        nextVisKey, live);
                    }
                }
                div.setVisibility(showDiv ? View.VISIBLE : View.GONE);
            }
        }

        final List<Button> vis = new ArrayList<>();
        for (Button b : buttons.values()) {
            if (b instanceof ModernIconButton && b.getVisibility() == View.VISIBLE) {
                vis.add(b);
            }
        }
        if (vis.isEmpty()) return;
        boolean sleepVisible = sleepWarningPill != null && sleepWarningPill.isShowing();
        int sleepExtendId =
                sleepWarningPill != null ? sleepWarningPill.getExtendButtonId() : View.NO_ID;
        for (int i = 0; i < vis.size(); i++) {
            final Button cur = vis.get(i);
            final Button prev = vis.get((i - 1 + vis.size()) % vis.size());
            final Button nxt = vis.get((i + 1) % vis.size());
            cur.setNextFocusLeftId(prev.getId());
            cur.setNextFocusRightId(nxt.getId());
            if (modernTv) {
                cur.setNextFocusUpId(
                        SleepTimerSheet.resolveActionUpFocusId(
                                sleepVisible, sleepExtendId, cur.getId()));
                cur.setNextFocusDownId(live ? cur.getId() : timeline.getId());
            } else {
                // Double-Layer TV: floating timeline sits directly ABOVE the icon dock
                boolean hasSeekbar =
                        !live && timeline != null && timeline.getVisibility() == View.VISIBLE;
                cur.setNextFocusUpId(
                        hasSeekbar
                                ? timeline.getId()
                                : SleepTimerSheet.resolveActionUpFocusId(
                                        sleepVisible, sleepExtendId, cur.getId()));
                cur.setNextFocusDownId(cur.getId());
            }
            final boolean isFirst = i == 0;
            final boolean isLast = i == vis.size() - 1;
            cur.setOnKeyListener(
                    (view, key, event) -> {
                        if (isFirst && key == KeyEvent.KEYCODE_DPAD_LEFT) {
                            if (event.getAction() == KeyEvent.ACTION_DOWN) prev.requestFocus();
                            return true;
                        }
                        if (isLast && key == KeyEvent.KEYCODE_DPAD_RIGHT) {
                            if (event.getAction() == KeyEvent.ACTION_DOWN) nxt.requestFocus();
                            return true;
                        }
                        return false;
                    });
        }
        if (lastFocusedModernButton == null
                || lastFocusedModernButton.getVisibility() != View.VISIBLE) {
            lastFocusedModernButton = vis.get(0);
        }
        if (prevFocused instanceof ModernIconButton
                && prevFocused.getVisibility() != View.VISIBLE) {
            restoreToolbarFocusAfterSubmenu();
        }
        if (modernTv) {
            timeline.setNextFocusUpId(lastFocusedModernButton.getId());
            timeline.setNextFocusDownId(lastFocusedModernButton.getId());
        } else {
            timeline.setNextFocusUpId(
                    SleepTimerSheet.resolveActionUpFocusId(
                            sleepVisible, sleepExtendId, timeline.getId()));
            timeline.setNextFocusDownId(lastFocusedModernButton.getId());
        }
        refreshTooltipForCurrentFocus();
    }

    void relayout(boolean mobileLandscape) {
        if (mobileLandscape != currentMobileLandscape || dockOverlay.getChildCount() == 0) {
            currentMobileLandscape = mobileLandscape;
            rebuildToolDock(mobileLandscape);
        }
        Button fsTool = buttons.get("fullscreen-tool");
        if (fsTool != null) {
            fsTool.setText(mobileLandscape ? "竖屏" : "全屏");
        }
        if (a.isTvDevice()) {
            repositionActiveTooltipIfVisible();
        }
    }

    private void rebuildToolDock(boolean mobileLandscape) {
        dockOverlay.removeAllViews();
        boolean tv = a.isTvDevice();
        Button fsTool = buttons.get("fullscreen-tool");
        if (fsTool != null) {
            fsTool.setText(mobileLandscape ? "竖屏" : "全屏");
        }
        if (!tv) {
            LinearLayout col = a.vertical();
            col.setMotionEventSplittingEnabled(false);
            col.setGravity(Gravity.CENTER_HORIZONTAL);
            col.setClipChildren(false);
            col.setClipToPadding(false);
            col.setPadding(a.dp(1), a.dp(2), a.dp(1), a.dp(2));
            for (Button b : buttons.values()) {
                if (b.getVisibility() == View.GONE) continue;
                if (b.getParent() instanceof ViewGroup) {
                    ((ViewGroup) b.getParent()).removeView(b);
                }
                b.setSingleLine(true);
                b.setTextSize(11f);
                b.setMinHeight(0);
                b.setMinimumHeight(0);
                int padH = a.dp(2);
                b.setPadding(padH, 0, padH, 0);
                int w = a.dp(mobileLandscape ? 40 : 44);
                int h = a.dp(mobileLandscape ? 30 : 33);
                LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(w, h);
                size.setMargins(a.dp(1), a.dp(2), a.dp(1), a.dp(2));
                col.addView(b, size);
            }
            ScrollView vScroller =
                    new ScrollView(a) {
                        @Override
                        public boolean onInterceptTouchEvent(MotionEvent ev) {
                            if (getParent() != null) {
                                getParent().requestDisallowInterceptTouchEvent(true);
                            }
                            return super.onInterceptTouchEvent(ev);
                        }

                        @Override
                        public boolean onTouchEvent(MotionEvent ev) {
                            if (getParent() != null) {
                                getParent().requestDisallowInterceptTouchEvent(true);
                            }
                            return super.onTouchEvent(ev);
                        }
                    };
            vScroller.setVerticalScrollBarEnabled(false);
            vScroller.setFillViewport(true);
            vScroller.setClipChildren(true);
            vScroller.setClipToPadding(true);
            vScroller.addView(col, new ScrollView.LayoutParams(-1, -2));
            dockOverlay.addView(vScroller, new LinearLayout.LayoutParams(-1, -1));
            return;
        }
        if (tv) {
            classicGroupDividers.clear();
            classicDividerBeforeKey.clear();
            classicDividerAfterKey.clear();
            classicDockScroller = null;
            boolean live = "live".equals(site.key);
            LinearLayout row = a.row();
            row.setGravity(modernTv ? (Gravity.CENTER_VERTICAL | Gravity.RIGHT) : Gravity.CENTER);
            row.setClipChildren(false);
            row.setClipToPadding(false);
            int d = PlayerChrome.vp(a, modernTv ? 31 : 34);
            int mH = PlayerChrome.vp(a, modernTv ? 3.2f : 5.0f);
            int mV = PlayerChrome.vp(a, modernTv ? 1.5f : 2.0f);
            String prevKey = null;
            for (Map.Entry<String, Button> entry : buttons.entrySet()) {
                String k = entry.getKey();
                Button b = entry.getValue();
                if (!(b instanceof ModernIconButton)) continue;
                if (b.getParent() instanceof ViewGroup) {
                    ((ViewGroup) b.getParent()).removeView(b);
                }
                if (!modernTv
                        && prevKey != null
                        && TvPlayerToolbarOrder.groupBucket(prevKey, live)
                                != TvPlayerToolbarOrder.groupBucket(k, live)) {
                    View divider = new View(a);
                    divider.setTag("toolbar-group-gap");
                    divider.setFocusable(false);
                    divider.setClickable(false);
                    divider.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
                    divider.setBackgroundColor(0x2effffff);
                    LinearLayout.LayoutParams divLp =
                            new LinearLayout.LayoutParams(
                                    Math.max(1, a.dp(1)), PlayerChrome.vp(a, 18));
                    divLp.gravity = Gravity.CENTER_VERTICAL;
                    divLp.setMargins(PlayerChrome.vp(a, 7), 0, PlayerChrome.vp(a, 7), 0);
                    row.addView(divider, divLp);
                    classicGroupDividers.add(divider);
                    classicDividerBeforeKey.add(prevKey);
                    classicDividerAfterKey.add(k);
                }
                LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(d, d);
                size.setMargins(mH, mV, mH, mV);
                row.addView(b, size);
                prevKey = k;
            }
            if (!modernTv) {
                HorizontalScrollView hsv = new HorizontalScrollView(a);
                hsv.setTag("classic-dock-scroller");
                hsv.setHorizontalScrollBarEnabled(false);
                hsv.setSmoothScrollingEnabled(true);
                hsv.setOverScrollMode(View.OVER_SCROLL_NEVER);
                hsv.setClipChildren(false);
                hsv.setClipToPadding(false);
                hsv.setFocusable(false);
                row.setPadding(
                        PlayerChrome.vp(a, 4),
                        PlayerChrome.vp(a, 2),
                        PlayerChrome.vp(a, 4),
                        PlayerChrome.vp(a, 2));
                hsv.addView(row, new HorizontalScrollView.LayoutParams(-2, -2));
                classicDockScroller = hsv;
                dockOverlay.addView(hsv, new LinearLayout.LayoutParams(-2, -2));
            } else {
                dockOverlay.addView(row, new LinearLayout.LayoutParams(-2, -2));
            }
            syncModernActionVisibility();
            return;
        }
    }

    void registerHiddenAction(String key, Runnable action) {
        Button b =
                a.button(
                        key,
                        key,
                        () -> {
                            menuAnchor = buttons.get("more");
                            action.run();
                        });
        b.setVisibility(View.GONE);
        buttons.put(key, b);
    }

    Button addModernIcon(
            LinearLayout row, String label, String key, int iconKind, Runnable action) {
        ModernIconButton b = new ModernIconButton(iconKind);
        b.setTag(key);
        b.setContentDescription(label);
        b.setText(label);
        b.setHorizontallyScrolling(false);
        b.setGravity(Gravity.LEFT | Gravity.TOP);
        b.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, 0f);
        b.setTextColor(Color.TRANSPARENT);
        UiCompat.setDefaultFocusHighlightEnabled(b, false);
        b.setFocusable(true);
        b.setFocusableInTouchMode(true);
        b.setClickable(true);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setPadding(0, 0, 0, 0);
        int d = PlayerChrome.vp(a, modernTv ? 31 : 34);
        final int radiusDp =
                Math.max(12, Math.round((d * .5f) / a.getResources().getDisplayMetrics().density));
        GradientDrawable idleCircle = new GradientDrawable();
        idleCircle.setColor(0x20ffffff);
        idleCircle.setCornerRadius(d * .5f);
        b.setBackground(idleCircle);
        a.pressFeedback(b);
        b.setOnClickListener(
                v -> {
                    if (a.touchPlayerGesture != null) {
                        a.touchPlayerGesture.cancelActiveGesture();
                    }
                    menuAnchor = buttons.get(key);
                    action.run();
                });
        b.setOnFocusChangeListener(
                (view, focused) -> {
                    if (focused) {
                        lastFocusedModernButton = b;
                        lastFocusedActionKey = key;
                        if (modernTv) {
                            timeline.setNextFocusUpId(b.getId());
                            timeline.setNextFocusDownId(b.getId());
                        } else {
                            timeline.setNextFocusDownId(b.getId());
                            if (classicDockScroller != null) {
                                int pad = PlayerChrome.vp(a, 16);
                                int targetX =
                                        Math.max(
                                                0,
                                                b.getLeft()
                                                        - (classicDockScroller.getWidth()
                                                                        - b.getWidth())
                                                                / 2);
                                if (a.reduced) {
                                    classicDockScroller.scrollTo(targetX, 0);
                                } else {
                                    classicDockScroller.smoothScrollTo(targetX, 0);
                                }
                                classicDockScroller.post(
                                        () -> {
                                            if (b.hasFocus()) showButtonTooltip(b, key);
                                        });
                            }
                        }
                        showButtonTooltip(b, key);
                    } else {
                        scheduleHideButtonTooltip();
                    }
                    FocusMotion.style(
                            a,
                            b,
                            focused,
                            0x20ffffff,
                            MainActivity.WHITE,
                            radiusDp,
                            Color.TRANSPARENT,
                            Color.TRANSPARENT,
                            false,
                            1.06f);
                    b.setPadding(0, 0, 0, 0);
                    b.invalidate();
                });
        int mH = PlayerChrome.vp(a, 3.2f);
        int mV = PlayerChrome.vp(a, 1.5f);
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(d, d);
        size.setMargins(mH, mV, mH, mV);
        row.addView(b, size);
        buttons.put(key, b);
        return b;
    }

    final class ModernIconButton extends Button {
        final int kind;
        final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path path = new Path();
        final RectF box = new RectF();

        ModernIconButton(int kind) {
            super(a);
            this.kind = kind;
            setIncludeFontPadding(false);
            setAllCaps(false);
            UiCompat.setDefaultFocusHighlightEnabled(this, false);
        }

        @Override
        protected void onDraw(Canvas c) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float cx = getScrollX() + w * .5f, cy = getScrollY() + h * .5f;
            float r = Math.min(w, h) * .5f;
            boolean focused = hasFocus();
            int fg = focused ? 0xff14161b : 0xfff3f6fb;
            int cut = focused ? MainActivity.WHITE : 0xff282b34;
            p.reset();
            p.setAntiAlias(true);
            p.setColor(fg);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeJoin(Paint.Join.ROUND);

            switch (kind) {
                case ICON_PLAY_PAUSE:
                    p.setStyle(Paint.Style.FILL);
                    if (a.playing) {
                        float bw = r * .14f, bh = r * .29f, gap = r * .105f, cr = r * .065f;
                        box.set(cx - gap - bw, cy - bh, cx - gap, cy + bh);
                        c.drawRoundRect(box, cr, cr, p);
                        box.set(cx + gap, cy - bh, cx + gap + bw, cy + bh);
                        c.drawRoundRect(box, cr, cr, p);
                    } else {
                        path.reset();
                        path.moveTo(cx - r * .17f, cy - r * .29f);
                        path.lineTo(cx + r * .29f, cy);
                        path.lineTo(cx - r * .17f, cy + r * .29f);
                        path.close();
                        p.setStrokeWidth(Math.max(1.5f, r * .075f));
                        p.setStyle(Paint.Style.FILL_AND_STROKE);
                        c.drawPath(path, p);
                    }
                    break;
                case ICON_NEXT:
                    p.setStyle(Paint.Style.FILL_AND_STROKE);
                    p.setStrokeWidth(Math.max(1.4f, r * .065f));
                    path.reset();
                    path.moveTo(cx - r * .27f, cy - r * .25f);
                    path.lineTo(cx + r * .09f, cy);
                    path.lineTo(cx - r * .27f, cy + r * .25f);
                    path.close();
                    c.drawPath(path, p);
                    p.setStyle(Paint.Style.FILL);
                    box.set(cx + r * .17f, cy - r * .27f, cx + r * .28f, cy + r * .27f);
                    c.drawRoundRect(box, r * .055f, r * .055f, p);
                    break;
                case ICON_EPISODES:
                    {
                        float sw = Math.max(1.8f, r * .095f);
                        p.setStrokeWidth(sw);
                        float[] ys = {cy - r * .23f, cy, cy + r * .23f};
                        for (float y : ys) {
                            p.setStyle(Paint.Style.FILL);
                            c.drawCircle(cx - r * .29f, y, r * .068f, p);
                            p.setStyle(Paint.Style.STROKE);
                            c.drawLine(cx - r * .13f, y, cx + r * .31f, y, p);
                        }
                        break;
                    }
                case ICON_SUBTITLES:
                    {
                        p.setStyle(Paint.Style.FILL);
                        box.set(cx - r * .37f, cy - r * .275f, cx + r * .37f, cy + r * .275f);
                        c.drawRoundRect(box, r * .11f, r * .11f, p);
                        p.setColor(cut);
                        float cr = r * .04f;
                        box.set(cx - r * .26f, cy + r * .005f, cx + r * .09f, cy + r * .085f);
                        c.drawRoundRect(box, cr, cr, p);
                        box.set(cx + r * .15f, cy + r * .005f, cx + r * .26f, cy + r * .085f);
                        c.drawRoundRect(box, cr, cr, p);
                        box.set(cx - r * .26f, cy + r * .13f, cx - r * .01f, cy + r * .21f);
                        c.drawRoundRect(box, cr, cr, p);
                        box.set(cx + r * .05f, cy + r * .13f, cx + r * .26f, cy + r * .21f);
                        c.drawRoundRect(box, cr, cr, p);
                        break;
                    }
                case ICON_AUDIO:
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(Math.max(1.8f, r * .095f));
                        float[] xs = {
                            cx - r * .29f, cx - r * .145f, cx, cx + r * .145f, cx + r * .29f
                        };
                        float[] hs = {r * .11f, r * .22f, r * .33f, r * .20f, r * .11f};
                        for (int i = 0; i < xs.length; i++) {
                            c.drawLine(xs[i], cy - hs[i], xs[i], cy + hs[i], p);
                        }
                        break;
                    }
                case ICON_LINES:
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(Math.max(1.7f, r * .088f));
                        float xl = cx - r * .34f, xr = cx + r * .34f;
                        float[] ys = {cy - r * .23f, cy, cy + r * .23f};
                        float[] ks = {cx - r * .11f, cx + r * .13f, cx - r * .06f};
                        for (int i = 0; i < 3; i++) {
                            c.drawLine(xl, ys[i], xr, ys[i], p);
                            c.drawLine(ks[i], ys[i] - r * .095f, ks[i], ys[i] + r * .095f, p);
                        }
                        break;
                    }
                case ICON_SPEED:
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(Math.max(1.8f, r * .095f));
                        box.set(cx - r * .35f, cy - r * .31f, cx + r * .35f, cy + r * .39f);
                        c.drawArc(box, 155f, 230f, false, p);
                        c.drawLine(cx, cy + r * .06f, cx + r * .20f, cy - r * .15f, p);
                        p.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx, cy + r * .06f, r * .08f, p);
                        break;
                    }
                case ICON_SKIP_INTRO:
                    {
                        boolean active = getVideoIntro(a, site, video) > 0;
                        float sw = Math.max(1.75f, r * .092f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        // Left opening timeline bracket '['
                        p.setColor(active ? (focused ? 0xff059669 : 0xff34d399) : fg);
                        path.reset();
                        path.moveTo(cx - r * .13f, cy - r * .28f);
                        path.lineTo(cx - r * .33f, cy - r * .28f);
                        path.lineTo(cx - r * .33f, cy + r * .28f);
                        path.lineTo(cx - r * .13f, cy + r * .28f);
                        c.drawPath(path, p);
                        // Forward jump arrow '→' emerging from the opening boundary
                        p.setColor(active && !focused ? 0xff6ee7b7 : fg);
                        c.drawLine(cx - r * .11f, cy, cx + r * .33f, cy, p);
                        path.reset();
                        path.moveTo(cx + r * .14f, cy - r * .18f);
                        path.lineTo(cx + r * .33f, cy);
                        path.lineTo(cx + r * .14f, cy + r * .18f);
                        c.drawPath(path, p);
                        break;
                    }
                case ICON_SKIP_OUTRO:
                    {
                        boolean active = getVideoOutro(a, site, video) > 0;
                        float sw = Math.max(1.75f, r * .092f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        // Right closing timeline bracket ']'
                        p.setColor(active ? (focused ? 0xff059669 : 0xff34d399) : fg);
                        path.reset();
                        path.moveTo(cx + r * .13f, cy - r * .28f);
                        path.lineTo(cx + r * .33f, cy - r * .28f);
                        path.lineTo(cx + r * .33f, cy + r * .28f);
                        path.lineTo(cx + r * .13f, cy + r * .28f);
                        c.drawPath(path, p);
                        // Tail offset arrow '←' measured inward from the ending boundary
                        p.setColor(active && !focused ? 0xff6ee7b7 : fg);
                        c.drawLine(cx + r * .11f, cy, cx - r * .33f, cy, p);
                        path.reset();
                        path.moveTo(cx - r * .14f, cy - r * .18f);
                        path.lineTo(cx - r * .33f, cy);
                        path.lineTo(cx - r * .14f, cy + r * .18f);
                        c.drawPath(path, p);
                        break;
                    }
                case ICON_CAST:
                    {
                        float sw = Math.max(1.75f, r * .09f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        p.setStrokeCap(Paint.Cap.ROUND);
                        p.setStrokeJoin(Paint.Join.ROUND);
                        float left = cx - r * .38f;
                        float right = cx + r * .38f;
                        float top = cy - r * .28f;
                        float bottom = cy + r * .28f;
                        // Screen frame leaving lower-left corner open for cast waves
                        path.reset();
                        path.moveTo(left, cy - r * .08f);
                        path.lineTo(left, top);
                        path.lineTo(right, top);
                        path.lineTo(right, bottom);
                        path.lineTo(cx + r * .06f, bottom);
                        c.drawPath(path, p);
                        // Two cast arcs + origin dot in lower-left corner
                        box.set(
                                left - r * .24f,
                                bottom - r * .24f,
                                left + r * .24f,
                                bottom + r * .24f);
                        c.drawArc(box, -90f, 90f, false, p);
                        box.set(
                                left - r * .40f,
                                bottom - r * .40f,
                                left + r * .40f,
                                bottom + r * .40f);
                        c.drawArc(box, -90f, 90f, false, p);
                        p.setStyle(Paint.Style.FILL);
                        c.drawCircle(
                                left + r * .04f, bottom - r * .04f, Math.max(1.4f, r * .065f), p);
                        break;
                    }
                case ICON_DECODER:
                    {
                        // Hardware decoder chip icon: rounded core + 4-side pins
                        float sw = Math.max(1.65f, r * .085f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        float core = r * .24f;
                        box.set(cx - core, cy - core, cx + core, cy + core);
                        c.drawRoundRect(box, r * .08f, r * .08f, p);
                        float pinOut = r * .39f;
                        float pinOff = r * .11f;
                        for (float off : new float[] {-pinOff, pinOff}) {
                            c.drawLine(cx + off, cy - core, cx + off, cy - pinOut, p);
                            c.drawLine(cx + off, cy + core, cx + off, cy + pinOut, p);
                            c.drawLine(cx - core, cy + off, cx - pinOut, cy + off, p);
                            c.drawLine(cx + core, cy + off, cx + pinOut, cy + off, p);
                        }
                        p.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx, cy, r * .065f, p);
                        break;
                    }
                case ICON_DANMAKU:
                    {
                        float sw = Math.max(1.7f, r * .088f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        box.set(cx - r * .38f, cy - r * .28f, cx + r * .38f, cy + r * .22f);
                        c.drawRoundRect(box, r * .13f, r * .13f, p);
                        // Tail pointer
                        path.reset();
                        path.moveTo(cx - r * .12f, cy + r * .22f);
                        path.lineTo(cx - r * .22f, cy + r * .35f);
                        path.lineTo(cx + r * .04f, cy + r * .22f);
                        c.drawPath(path, p);
                        // Two horizontal scrolling danmu lines
                        c.drawLine(cx - r * .22f, cy - r * .09f, cx + r * .22f, cy - r * .09f, p);
                        c.drawLine(cx - r * .22f, cy + r * .06f, cx + r * .08f, cy + r * .06f, p);
                        if (danmuStatus.isFailure()) {
                            p.setStyle(Paint.Style.FILL);
                            p.setColor(focused ? 0xffdc2626 : 0xfff87171);
                            c.drawCircle(cx + r * .31f, cy - r * .27f, r * .115f, p);
                        } else if (danmaku != null && danmaku.enabled && danmakuLoaded) {
                            p.setStyle(Paint.Style.FILL);
                            p.setColor(focused ? 0xff059669 : 0xff34d399);
                            c.drawCircle(cx + r * .31f, cy - r * .27f, r * .10f, p);
                        }
                        break;
                    }
                case ICON_TRACKS:
                    {
                        // Combined Subtitle box (left) + Audio bars (right)
                        float sw = Math.max(1.65f, r * .085f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        box.set(cx - r * .40f, cy - r * .26f, cx + r * .06f, cy + r * .26f);
                        c.drawRoundRect(box, r * .10f, r * .10f, p);
                        c.drawLine(cx - r * .28f, cy + r * .02f, cx - r * .06f, cy + r * .02f, p);
                        c.drawLine(cx - r * .28f, cy + r * .14f, cx - r * .13f, cy + r * .14f, p);
                        c.drawLine(cx + r * .22f, cy - r * .22f, cx + r * .22f, cy + r * .22f, p);
                        c.drawLine(cx + r * .36f, cy - r * .13f, cx + r * .36f, cy + r * .13f, p);
                        break;
                    }
                case ICON_EPG:
                    {
                        float sw = Math.max(1.65f, r * .085f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        box.set(cx - r * .36f, cy - r * .30f, cx + r * .36f, cy + r * .30f);
                        c.drawRoundRect(box, r * .11f, r * .11f, p);
                        c.drawLine(cx - r * .36f, cy - r * .11f, cx + r * .36f, cy - r * .11f, p);
                        c.drawLine(cx - r * .20f, cy + r * .05f, cx + r * .20f, cy + r * .05f, p);
                        c.drawLine(cx - r * .20f, cy + r * .18f, cx + r * .06f, cy + r * .18f, p);
                        break;
                    }
                case ICON_SLEEP_TIMER:
                    {
                        float sw = Math.max(1.65f, r * .085f);
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        box.set(cx - r * .33f, cy - r * .33f, cx + r * .33f, cy + r * .33f);
                        c.drawArc(box, -60f, 290f, false, p);
                        c.drawLine(cx, cy, cx, cy - r * .19f, p);
                        c.drawLine(cx, cy, cx + r * .15f, cy + r * .07f, p);
                        if (SESSION_SLEEP_TIMER.isActive()) {
                            p.setStyle(Paint.Style.FILL);
                            p.setColor(focused ? 0xffd97706 : 0xfffbbf24);
                            c.drawCircle(cx + r * .30f, cy - r * .28f, r * .10f, p);
                        }
                        break;
                    }
                case ICON_MORE:
                default:
                    {
                        p.setStyle(Paint.Style.FILL);
                        float dr = Math.max(1.5f, r * .08f);
                        c.drawCircle(cx - r * .24f, cy, dr, p);
                        c.drawCircle(cx, cy, dr, p);
                        c.drawCircle(cx + r * .24f, cy, dr, p);
                        break;
                    }
            }
        }
    }

    Button add(LinearLayout row, String title, String key, Runnable action) {
        Button b =
                a.button(
                        title,
                        key,
                        () -> {
                            if (a.touchPlayerGesture != null) {
                                a.touchPlayerGesture.cancelActiveGesture();
                            }
                            menuAnchor = buttons.get(key);
                            action.run();
                        });
        b.setSingleLine(true);
        b.setEllipsize(android.text.TextUtils.TruncateAt.END);
        b.setTextSize(a.isTvDevice() ? 12.5f : 13f);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(a.dp(42));
        b.setMinimumHeight(a.dp(42));
        b.setBackground(a.bg(0x16ffffff, 19));
        int padH = a.dp(a.isTvDevice() ? 4 : 6);
        b.setPadding(padH, 0, padH, 0);
        b.setOnFocusChangeListener(
                (view, focused) -> {
                    if (a.isTvDevice()) {
                        if (focused) showButtonTooltip(b, key);
                        else scheduleHideButtonTooltip();
                    }
                    FocusMotion.style(
                            a,
                            b,
                            focused,
                            0x16ffffff,
                            MainActivity.WHITE,
                            19,
                            MainActivity.WHITE,
                            MainActivity.DARK,
                            false,
                            1.025f);
                    b.setPadding(padH, 0, padH, 0);
                });
        int btnWidth = a.dp(a.isTvDevice() ? 58 : 68);
        int marginH = a.dp(a.isTvDevice() ? 3 : 4);
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(btnWidth, a.dp(42));
        size.setMargins(marginH, a.dp(4), marginH, a.dp(4));
        row.addView(b, size);
        buttons.put(key, b);
        return b;
    }

    int lineIndex() {
        return a.activeLine == null ? -1 : video.lines.indexOf(a.activeLine);
    }

    int episodeIndex() {
        if (a.activeLine == null || a.activeLine.episodes == null || a.activeEpisode == null) {
            return -1;
        }
        int exact = a.activeLine.episodes.indexOf(a.activeEpisode);
        if (exact >= 0) return exact;
        String activeUrl = a.activeEpisode.url == null ? "" : a.activeEpisode.url.trim();
        String activeName = a.activeEpisode.name == null ? "" : a.activeEpisode.name.trim();
        for (int i = 0; i < a.activeLine.episodes.size(); i++) {
            Cms.Episode cand = a.activeLine.episodes.get(i);
            if (cand == null) continue;
            String cUrl = cand.url == null ? "" : cand.url.trim();
            String cName = cand.name == null ? "" : cand.name.trim();
            if (!activeUrl.isEmpty()
                    && activeUrl.equals(cUrl)
                    && (activeName.isEmpty() || activeName.equals(cName))) {
                return i;
            }
        }
        if (!activeName.isEmpty()) {
            for (int i = 0; i < a.activeLine.episodes.size(); i++) {
                Cms.Episode cand = a.activeLine.episodes.get(i);
                if (cand == null) continue;
                String cName = cand.name == null ? "" : cand.name.trim();
                if (activeName.equals(cName)) {
                    return i;
                }
            }
        }
        return -1;
    }

    boolean hasAlternativeLines() {
        if ("live".equals(site.key)) {
            if (a.liveSession != null
                    && a.liveSession.index >= 0
                    && a.liveSession.index < a.liveSession.channels.size()) {
                LiveCatalog.Channel ch = a.liveSession.channels.get(a.liveSession.index);
                if (ch != null && ch.streams != null && ch.streams.size() > 1) return true;
            }
        }
        if (video != null && video.lines != null && video.lines.size() > 1) return true;
        org.json.JSONArray qualities =
                resolved != null && resolved.media != null
                        ? resolved.media.optJSONArray("qualities")
                        : null;
        return qualities != null && qualities.length() > 1;
    }

    void openLinePickerFromError(View anchorView) {
        if (anchorView != null) {
            menuAnchor = anchorView;
        }
        if ("live".equals(site.key)) {
            a.chooseLiveStream();
        } else {
            chooseLine();
        }
    }

    void choose(String title, String[] labels, int selected, PlayerBubble.IntAction action) {
        showBubble(title, labels, selected, action, "", null);
    }

    void choose(
            String title,
            String[] labels,
            int selected,
            PlayerBubble.IntAction action,
            Runnable onCancelBack) {
        showBubble(title, labels, selected, action, "", onCancelBack);
    }

    void message(String text) {
        showBubble("播放提示", new String[] {"完成"}, -1, i -> {}, text, null);
    }

    void message(String text, Runnable onCancelBack) {
        showBubble("播放提示", new String[] {"完成"}, -1, i -> {}, text, onCancelBack);
    }

    void showBubble(
            String title,
            String[] labels,
            int selected,
            PlayerBubble.IntAction action,
            String message) {
        showBubble(title, labels, selected, action, message, null);
    }

    void showBubble(
            String title,
            String[] labels,
            int selected,
            PlayerBubble.IntAction action,
            String message,
            Runnable onCancelBack) {
        List<PlayerBubble.Row> rows = new ArrayList<>(labels.length);
        for (int i = 0; i < labels.length; i++) {
            String raw = labels[i] == null ? "" : labels[i];
            boolean checked = (i == selected) || raw.startsWith("✓");
            rows.add(PlayerBubble.Row.item(i, raw, checked));
        }
        showStructuredBubble(title, "", rows, selected, action, message, false, onCancelBack);
    }

    void showStructuredBubble(
            String title,
            String statusBanner,
            List<PlayerBubble.Row> rows,
            int initialFocusActionIndex,
            PlayerBubble.IntAction action,
            String message,
            boolean forceShowHeading,
            Runnable onCancelBack) {
        if (activeDialog != null) {
            activeDialog.dismiss();
            activeDialog = null;
        }
        if (skipCountdownPill != null) {
            skipCountdownPill.dismissSilently();
        }
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.onDialogOpened();
        }
        if (menuAnchor == null || !UiCompat.isAttached(menuAnchor))
            menuAnchor = buttons.get("more");
        dialogOpen = true;
        hideButtonTooltip(true);
        if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
        final Dialog[] holder = new Dialog[1];
        holder[0] =
                PlayerBubble.showStructured(
                        a,
                        menuAnchor,
                        title,
                        statusBanner,
                        rows,
                        initialFocusActionIndex,
                        action,
                        () -> {
                            if (activeDialog == holder[0]) {
                                activeDialog = null;
                                dialogOpen = false;
                                a.scheduleHide();
                                if (a.ui != null) {
                                    a.ui.post(
                                            () -> {
                                                if (a.playbackControls == this && !dialogOpen) {
                                                    restoreToolbarFocusAfterSubmenu();
                                                    refreshTooltipForCurrentFocus();
                                                }
                                            });
                                }
                            }
                        },
                        message,
                        forceShowHeading,
                        onCancelBack);
        activeDialog = holder[0];
    }

    static final int EPISODE_GROUP_SIZE = 50;

    void chooseEpisodes() {
        int l = lineIndex();
        if (l < 0) {
            message("此内容没有可切换的剧集。");
            return;
        }
        Cms.Line line = video.lines.get(l);
        int total = line.episodes.size();
        int current = episodeIndex();
        if (total <= EPISODE_GROUP_SIZE) {
            String[] labels = new String[total];
            for (int i = 0; i < total; i++) labels[i] = line.episodes.get(i).name;
            choose(
                    line.name + " · 选集",
                    labels,
                    current,
                    i -> {
                        markSleepTimerInPlaceSwitch();
                        a.changeEpisode(site, video, line, line.episodes.get(i), 0);
                    });
            return;
        }
        int page = EpisodeSelection.pageFor(Math.max(0, current), total, false);
        chooseEpisodePage(line, page);
    }

    void chooseEpisodePage(Cms.Line line, int page) {
        int total = line.episodes.size();
        int groups = Math.max(1, (total + EPISODE_GROUP_SIZE - 1) / EPISODE_GROUP_SIZE);
        int safePage = Math.max(0, Math.min(page, groups - 1));
        int start = safePage * EPISODE_GROUP_SIZE;
        int end = Math.min(total, start + EPISODE_GROUP_SIZE);
        int count = end - start;
        String[] labels = new String[count + 1];
        labels[0] = "切换选集分组（当前 " + (start + 1) + "-" + end + " / 共 " + total + " 集）";
        int current = episodeIndex();
        int selected = 0;
        for (int i = 0; i < count; i++) {
            int epIndex = start + i;
            labels[i + 1] = line.episodes.get(epIndex).name;
            if (epIndex == current) selected = i + 1;
        }
        choose(
                line.name + " · 选集 (" + (start + 1) + "-" + end + ")",
                labels,
                selected,
                i -> {
                    if (i == 0) {
                        chooseEpisodeGroupList(line, safePage);
                    } else {
                        int target = start + (i - 1);
                        if (target >= 0 && target < total) {
                            markSleepTimerInPlaceSwitch();
                            a.changeEpisode(site, video, line, line.episodes.get(target), 0);
                        }
                    }
                });
    }

    void chooseEpisodeGroupList(Cms.Line line, int currentGroup) {
        int total = line.episodes.size();
        int groups = Math.max(1, (total + EPISODE_GROUP_SIZE - 1) / EPISODE_GROUP_SIZE);
        String[] groupLabels = new String[groups];
        for (int g = 0; g < groups; g++) {
            int gStart = g * EPISODE_GROUP_SIZE + 1;
            int gEnd = Math.min(total, (g + 1) * EPISODE_GROUP_SIZE);
            groupLabels[g] = "第 " + gStart + " - " + gEnd + " 集";
        }
        choose(line.name + " · 选择分组", groupLabels, currentGroup, g -> chooseEpisodePage(line, g));
    }

    void chooseLine() {
        chooseLine(null);
    }

    void chooseLine(Runnable onCancelBack) {
        org.json.JSONArray qualities =
                resolved != null && resolved.media != null
                        ? resolved.media.optJSONArray("qualities")
                        : null;
        int qCount = qualities != null && qualities.length() > 1 ? qualities.length() : 0;
        List<String> videoTracks =
                (a.player != null && a.prepared)
                        ? a.player.trackLabels(2)
                        : Collections.emptyList();
        int vTrackMenuCount = videoTracks.size() > 1 ? videoTracks.size() + 1 : 0;
        boolean isLiveMode = "live".equals(site.key);
        boolean canCrossSearch =
                video != null
                        && video.title != null
                        && !video.title.trim().isEmpty()
                        && !isLiveMode;
        boolean canEpg = isLiveMode && a.liveSession != null && a.liveSession.index >= 0;
        int lineCount = video != null && video.lines != null ? video.lines.size() : 0;
        if (lineCount == 0 && qCount == 0 && vTrackMenuCount == 0 && !canCrossSearch && !canEpg) {
            message("此内容只有当前地址。", onCancelBack);
            return;
        }
        int groupCount =
                (lineCount > 0 ? 1 : 0)
                        + ((qCount > 0 || vTrackMenuCount > 0) ? 1 : 0)
                        + (canEpg ? 1 : 0)
                        + (canCrossSearch ? 1 : 0);
        boolean useHeaders = groupCount > 1;
        List<PlayerBubble.Row> rows = new ArrayList<>();
        int nextActionIdx = 0;

        // 1. 本片可选线路 first (active line marked and focused on open)
        final int curLineIdx = lineIndex();
        final int lineStart = nextActionIdx;
        if (lineCount > 0) {
            if (useHeaders) rows.add(PlayerBubble.Row.header("本片线路"));
            for (int i = 0; i < lineCount; i++) {
                boolean active = (i == curLineIdx);
                String name = video.lines.get(i).name;
                rows.add(
                        PlayerBubble.Row.item(
                                nextActionIdx++, active ? (name + "（当前）") : name, active));
            }
        }

        // 2. 清晰度与视频轨 second
        final int qStart = nextActionIdx;
        int currentQualityIdx =
                resolved != null && resolved.media != null
                        ? resolved.media.optInt("_qualityIdx", 0)
                        : 0;
        if (qCount > 0 || vTrackMenuCount > 0) {
            if (useHeaders) rows.add(PlayerBubble.Row.header("清晰度 / 视频轨"));
        }
        String qPrefix = isLiveMode ? "直播源 · " : "画质 · ";
        for (int q = 0; q < qCount; q++) {
            org.json.JSONObject qObj = qualities.optJSONObject(q);
            String qName = qObj != null ? qObj.optString("name", "线路 " + (q + 1)) : "线路 " + (q + 1);
            boolean activeQ = (q == currentQualityIdx);
            rows.add(
                    PlayerBubble.Row.item(
                            nextActionIdx++, qPrefix + qName + (activeQ ? "（当前）" : ""), activeQ));
        }
        final int vTrackStart = nextActionIdx;
        if (vTrackMenuCount > 0) {
            boolean anyChecked = false;
            for (String vt : videoTracks) {
                if (vt != null && vt.startsWith("✓")) {
                    anyChecked = true;
                    break;
                }
            }
            rows.add(PlayerBubble.Row.item(nextActionIdx++, "视频轨 · 自动优选画质", !anyChecked));
            for (String vt : videoTracks) {
                boolean checked = vt != null && vt.startsWith("✓");
                String clean = vt == null ? "" : vt.replaceFirst("^✓\\s*", "");
                rows.add(PlayerBubble.Row.item(nextActionIdx++, "视频轨 · " + clean, checked));
            }
        }

        final int epgIndex = canEpg ? nextActionIdx : -1;
        if (canEpg) {
            if (useHeaders) rows.add(PlayerBubble.Row.header("直播节目单"));
            rows.add(PlayerBubble.Row.item(nextActionIdx++, "节目单与回看 (EPG)", false));
        }

        // 3. 搜索同名其他片源 at bottom
        final int crossSearchIndex = canCrossSearch ? nextActionIdx : -1;
        if (canCrossSearch) {
            if (useHeaders) rows.add(PlayerBubble.Row.header("其他片源"));
            rows.add(PlayerBubble.Row.item(nextActionIdx++, "搜索同名其他片源 · " + video.title, false));
        }

        int initialFocus;
        if (lineCount > 0) {
            initialFocus = lineStart + Math.max(0, Math.min(lineCount - 1, curLineIdx));
        } else if (qCount > 0) {
            initialFocus = qStart + Math.max(0, Math.min(qCount - 1, currentQualityIdx));
        } else if (vTrackMenuCount > 0) {
            initialFocus = vTrackStart;
        } else {
            initialFocus = 0;
        }

        final int finalVTrackMenuCount = vTrackMenuCount;
        final int finalQCount = qCount;
        final org.json.JSONArray finalQualities = qualities;
        String panelTitle =
                (lineCount > 0 && (qCount > 0 || vTrackMenuCount > 0))
                        ? "线路 / 画质"
                        : (lineCount > 0
                                ? "线路"
                                : (qCount > 0 || vTrackMenuCount > 0 ? "清晰度 / 画质" : "片源"));
        showStructuredBubble(
                panelTitle,
                "",
                rows,
                initialFocus,
                i -> {
                    if (epgIndex >= 0 && i == epgIndex) {
                        LiveController.showEpgAndCatchupDialog(a);
                        return;
                    }
                    if (crossSearchIndex >= 0 && i == crossSearchIndex) {
                        clearSleepTimerOnLeave();
                        a.leavePlayback();
                        a.crossSearch(Cms.searchTitle(video));
                        return;
                    }
                    if (finalVTrackMenuCount > 0
                            && i >= vTrackStart
                            && i < vTrackStart + finalVTrackMenuCount) {
                        int vtChoice = i - vTrackStart;
                        if (a.player != null && a.prepared) {
                            a.player.selectTrack(2, vtChoice == 0 ? -1 : vtChoice - 1);
                            a.toast(vtChoice == 0 ? "已切换为自动优选画质" : "已锁定所选视频画质轨道");
                        }
                        return;
                    }
                    int qChoice = i - qStart;
                    if (qChoice >= 0 && qChoice < finalQCount && finalQualities != null) {
                        org.json.JSONObject qObj = finalQualities.optJSONObject(qChoice);
                        if (qObj != null) {
                            String nextUrl = qObj.optString("url", "");
                            if (!nextUrl.isEmpty()) {
                                try {
                                    resolved.media.put("_qualityIdx", qChoice);
                                } catch (Exception ignored) {
                                }
                                PlaybackController.applyCandidateHeaders(site, resolved, qObj);
                                a.resumeAt =
                                        !isLiveMode && a.prepared && a.player != null
                                                ? a.player.getCurrentPosition()
                                                : 0;
                                markSleepTimerInPlaceSwitch();
                                if (LiveQualityPolicy.isEmbyLiveUrl(nextUrl)) {
                                    LiveController.playEmbyLiveAsync(
                                            a, site, video, resolved, nextUrl);
                                } else {
                                    resolved.url = LocalProxy.rewrite(nextUrl);
                                    a.playerPage(site, video, resolved);
                                }
                            }
                        }
                        return;
                    }
                    int lineIdx = i - lineStart;
                    if (lineIdx >= 0 && lineIdx < lineCount) {
                        Cms.Line line = video.lines.get(lineIdx);
                        if (!line.episodes.isEmpty()) {
                            Cms.Episode prevEp =
                                    a.activeEpisode != null ? a.activeEpisode : resolved;
                            SeriesScrapeStore.OverrideRecord ov =
                                    SeriesScrapeStore.load(
                                            a, site != null ? site.key : "", video.id, video.title);
                            Cms.Episode matched =
                                    TvSeriesScraper.findMatchingEpisodeAcrossLines(
                                            video.title, line, a.activeLine, prevEp, ov);
                            if (matched == null) {
                                int n =
                                        Math.min(
                                                Math.max(0, episodeIndex()),
                                                line.episodes.size() - 1);
                                matched = line.episodes.get(n);
                            }
                            String prevName =
                                    prevEp != null && prevEp.name != null ? prevEp.name.trim() : "";
                            String nextName =
                                    matched != null && matched.name != null
                                            ? matched.name.trim()
                                            : "";
                            if (!nextName.isEmpty() && !nextName.equalsIgnoreCase(prevName)) {
                                a.toast("已切至 " + line.name + " · " + nextName);
                            }
                            int resumePos =
                                    !isLiveMode && a.prepared && a.player != null
                                            ? a.player.getCurrentPosition()
                                            : 0;
                            markSleepTimerInPlaceSwitch();
                            a.changeEpisode(site, video, line, matched, resumePos);
                        }
                    }
                },
                "",
                true,
                onCancelBack);
    }

    boolean hasAdjacentEpisode(int direction) {
        return peekAdjacentEpisode(direction) != null;
    }

    String peekAdjacentEpisodeName(int direction) {
        Cms.Episode next = peekAdjacentEpisode(direction);
        return next != null && next.name != null ? next.name.trim() : "";
    }

    private Cms.Episode peekAdjacentEpisode(int direction) {
        int i = episodeIndex(), l = lineIndex();
        if (l < 0 || i < 0 || video == null || video.lines == null || l >= video.lines.size()) {
            return null;
        }
        Cms.Line line = video.lines.get(l);
        if (line == null || line.episodes == null || line.episodes.isEmpty()) return null;
        int next = i + direction;
        if (a.prefs != null && a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 2) {
            next = (next + line.episodes.size()) % line.episodes.size();
        }
        if (next < 0 || next >= line.episodes.size()) return null;
        return line.episodes.get(next);
    }

    boolean isSkipCountdownActive() {
        return skipCountdownPill != null && skipCountdownPill.isActive();
    }

    boolean step(int direction) {
        int i = episodeIndex(), l = lineIndex();
        if (l < 0 || i < 0) return false;
        Cms.Line line = video.lines.get(l);
        int next = i + direction;
        if (a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 2)
            next = (next + line.episodes.size()) % line.episodes.size();
        if (next < 0 || next >= line.episodes.size()) return false;
        transitioning = true;
        resetEpisodeTransientState();
        markSleepTimerInPlaceSwitch();
        if (a.touchPlayerGesture != null) a.touchPlayerGesture.onEpisodeSwitch();
        a.changeEpisode(site, video, line, line.episodes.get(next), 0);
        return true;
    }

    void reload(boolean preserve) {
        int position =
                preserve && a.prepared && a.player != null ? a.player.getCurrentPosition() : 0;
        markSleepTimerInPlaceSwitch();
        if (a.activeLine != null && a.activeEpisode != null)
            a.changeEpisode(site, video, a.activeLine, a.activeEpisode, position);
        else {
            a.resumeAt = position;
            a.playerPage(site, video, resolved);
        }
    }

    void speed() {
        if (a.player == null) return;
        float[] speeds = {.5f, .75f, 1f, 1.25f, 1.5f, 1.75f, 2f};
        String[] labels = {"0.5×", "0.75×", "1.0×", "1.25×", "1.5×", "1.75×", "2.0×"};
        int current = 2;
        for (int i = 0; i < speeds.length; i++) if (speeds[i] == a.player.getSpeed()) current = i;
        choose(
                "播放倍速（以后播放沿用）",
                labels,
                current,
                i -> {
                    if (a.player != null) a.player.setSpeed(speeds[i]);
                    onDanmuPlaySpeedChanged(speeds[i]);
                    a.prefs.edit().putFloat(Prefs.PLAY_SPEED, speeds[i]).apply();
                    if (a.touchPlayerGesture != null) {
                        a.touchPlayerGesture.onManualSpeedChanged();
                    }
                    updateLabels();
                });
    }

    void aspect() {
        aspect(null);
    }

    void aspect(Runnable onCancelBack) {
        String[] labels = {"适应画面", "铺满屏幕", "16:9", "4:3", "裁切填充"};
        choose(
                "画面比例（以后播放沿用）",
                labels,
                a.prefs.getInt(Prefs.ASPECT, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.ASPECT, i).apply();
                    resize(videoWidth, videoHeight);
                    updateLabels();
                },
                onCancelBack);
    }

    void engine() {
        engine(null);
    }

    void engine(Runnable onCancelBack) {
        int cur = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
        final int[] vals = {0, 3, 2, 1};
        int selected = cur == 3 ? 1 : (cur == 2 ? 2 : (cur == 1 ? 3 : 0));
        choose(
                "播放器内核（以后播放沿用）",
                new String[] {
                    "Exo 播放器 (Media3 · 默认)",
                    "MPV 高画质内核 (libmpv · HDR / Anime4K / ASS)",
                    "IJK 兼容模式 (Media3 + FFmpeg)",
                    "系统播放器 (Android Native)"
                },
                selected,
                i -> {
                    if (i >= 0 && i < vals.length) {
                        a.prefs.edit().putInt(Prefs.PLAYER_ENGINE, vals[i]).apply();
                        updateLabels();
                        reload(true);
                    }
                },
                onCancelBack);
    }

    void output() {
        output(null);
    }

    void output(Runnable onCancelBack) {
        choose(
                "画面输出（以后播放沿用）",
                new String[] {"保真输出 · HDR 与流畅度优先", "兼容输出 · 支持应用内调色"},
                a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.VIDEO_OUTPUT, i).apply();
                    reload(true);
                },
                onCancelBack);
    }

    void decoder() {
        decoder(null);
    }

    void decoder(Runnable onCancelBack) {
        choose(
                "解码方式（以后播放沿用）",
                new String[] {"自动选择（默认）", "设备硬件解码", "软件解码优先（高分辨率可能较慢）"},
                a.prefs.getInt(Prefs.DECODER_MODE, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.DECODER_MODE, i).apply();
                    updateLabels();
                    reload(true);
                },
                onCancelBack);
    }

    void decoderMenu() {
        decoderMenu(null);
    }

    void decoderMenu(Runnable onCancelBack) {
        int decMode = a.prefs.getInt(Prefs.DECODER_MODE, 0);
        int engMode = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
        int outMode = a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0);
        boolean anime4k = a.prefs.getBoolean(Prefs.ANIME4K_ENABLED, false);
        String engLabel =
                engMode == 3 ? "MPV" : (engMode == 2 ? "IJK" : (engMode == 1 ? "系统" : "Exo"));
        String[] items = {
            (engMode == 0 ? "✓ " : "") + "播放器内核 · Exo (Media3)",
            (engMode == 3 ? "✓ " : "") + "播放器内核 · MPV 高画质 (HDR / Anime4K / ASS)",
            (engMode == 2 ? "✓ " : "") + "播放器内核 · IJK 兼容模式 (Media3 + FFmpeg)",
            (engMode == 1 ? "✓ " : "") + "播放器内核 · 系统播放器",
            (decMode == 0 ? "✓ " : "") + "解码方式 · 自动解码（默认）",
            (decMode == 1 ? "✓ " : "") + "解码方式 · 设备硬件解码 (HW)",
            (decMode == 2 ? "✓ " : "") + "解码方式 · 软件解码优先 (SW)",
            "画面输出 · " + (outMode == 0 ? "保真输出 (HDR)" : "兼容输出 (调色)"),
            "Anime4K 实时超分 (MPV) · " + (anime4k ? "已开启" : "已关闭")
        };
        int curIdx = engMode == 3 ? 1 : (engMode == 2 ? 2 : (engMode == 1 ? 3 : 0));
        choose(
                "播放器与解码 (" + engLabel + " · 以后播放沿用)",
                items,
                curIdx,
                i -> {
                    if (i >= 0 && i <= 3) {
                        int nextEng = i == 1 ? 3 : (i == 2 ? 2 : (i == 3 ? 1 : 0));
                        a.prefs.edit().putInt(Prefs.PLAYER_ENGINE, nextEng).apply();
                        updateLabels();
                        reload(true);
                    } else if (i >= 4 && i <= 6) {
                        a.prefs.edit().putInt(Prefs.DECODER_MODE, i - 4).apply();
                        updateLabels();
                        reload(true);
                    } else if (i == 7) {
                        output(() -> decoderMenu(onCancelBack));
                    } else if (i == 8) {
                        a.prefs.edit().putBoolean(Prefs.ANIME4K_ENABLED, !anime4k).apply();
                        message(!anime4k ? "已开启 Anime4K 实时超分（MPV 内核生效）" : "已关闭 Anime4K 实时超分");
                        if (engMode == 3) reload(true);
                    }
                },
                onCancelBack);
    }

    private DanmuProvider.MatchQuery buildDanmuMatchQuery() {
        String rawTitle = video != null && video.title != null ? video.title.trim() : "";
        String siteKey = site != null && site.key != null ? site.key : "";
        String videoId = video != null && video.id != null ? video.id : "";
        SeriesScrapeStore.OverrideRecord ov = SeriesScrapeStore.load(a, siteKey, videoId, rawTitle);

        String effectiveTitle =
                ov != null && !ov.danmuTitleOverride.isEmpty()
                        ? ov.danmuTitleOverride
                        : (ov != null && !ov.matchedTitle.isEmpty()
                                ? ov.matchedTitle
                                : TvSeriesScraper.cleanWorkTitle(rawTitle));
        Cms.Episode ep = a.activeEpisode != null ? a.activeEpisode : resolved;
        String epTitle = ep != null && ep.name != null ? ep.name.trim() : "";
        List<Cms.Episode> eps =
                a.activeLine != null && a.activeLine.episodes != null
                        ? a.activeLine.episodes
                        : Collections.<Cms.Episode>emptyList();
        int rawIdx = episodeIndex();
        boolean movie =
                eps.size() <= 1
                        && (rawIdx >= 0
                                ? TvSeriesScraper.isSingleMovieLine(effectiveTitle, eps, rawIdx)
                                : (HistoryResumeMatcher.looksLikeMovieEpisode(epTitle)
                                        && TvSeriesScraper.extractEpisodeNumber(epTitle) <= 0))
                        && (ov == null
                                || (ov.episodeOffset == 0 && ov.episodeNumberOverrides.isEmpty()));
        int epNum;
        if (movie) {
            epNum = 0;
        } else if (rawIdx >= 0 && rawIdx < eps.size()) {
            epNum = TvSeriesScraper.resolveDanmuEpisodeNumber(effectiveTitle, eps, rawIdx, ov);
        } else {
            int parsedEp = DandanplayProvider.extractEpisodeNum(epTitle);
            if (parsedEp <= 0) parsedEp = TvSeriesScraper.extractEpisodeNumber(epTitle);
            int offset = ov != null ? ov.episodeOffset : 0;
            epNum = parsedEp > 0 ? Math.max(1, parsedEp + offset) : 0;
        }
        int seasonNum;
        if (movie) {
            seasonNum = -1;
        } else if (rawIdx >= 0 && rawIdx < eps.size()) {
            seasonNum = TvSeriesScraper.resolveDanmuSeasonNumber(effectiveTitle, eps, rawIdx, ov);
        } else {
            int parsedSeason = DandanplayProvider.extractSeasonNum(epTitle);
            if (parsedSeason <= 0)
                parsedSeason = DandanplayProvider.extractSeasonNum(effectiveTitle);
            seasonNum = parsedSeason;
        }
        String boundAnimeId = ov != null ? ov.danmuAnimeId : "";
        String boundOrigin = ov != null ? ov.danmuOrigin : "";
        long durSec =
                (a.player != null && a.prepared && a.player.getDuration() > 0)
                        ? (a.player.getDuration() / 1000L)
                        : 0L;
        return new DanmuProvider.MatchQuery(
                effectiveTitle,
                epTitle,
                epNum,
                durSec,
                seasonNum,
                movie,
                boundAnimeId,
                boundOrigin);
    }

    static String danmuServerSignature(DanmuSettingsPanel.DanmuConfig cfg) {
        if (cfg == null) return "";
        return cfg.serverUrls + "|" + cfg.appId + "|" + cfg.appSecret;
    }

    static boolean shouldApplyAsyncMatchResult(
            DanmuSettingsPanel.DanmuConfig requestCfg, DanmuSettingsPanel.DanmuConfig latestCfg) {
        if (requestCfg == null || latestCfg == null || !latestCfg.enabled) {
            return false;
        }
        return danmuServerSignature(requestCfg).equals(danmuServerSignature(latestCfg));
    }

    static boolean shouldStartSegmentedSessionOnConfigUpdate(
            boolean enabled,
            String serverUrls,
            boolean hasActiveSegmentedSession,
            boolean hasLegacyLoadedDanmaku,
            String previousServerSignature,
            String nextServerSignature) {
        if (!enabled || serverUrls == null || serverUrls.trim().isEmpty()) {
            return false;
        }
        String prev = previousServerSignature == null ? "" : previousServerSignature;
        String next = nextServerSignature == null ? "" : nextServerSignature;
        boolean serverChanged = !prev.equals(next);
        if (hasLegacyLoadedDanmaku) {
            return serverChanged;
        }
        return !hasActiveSegmentedSession || serverChanged;
    }

    private void startSegmentedDanmuSession(
            final DanmuSettingsPanel.DanmuConfig cfg, final boolean showFeedback) {
        closeSegmentedDanmuSession();
        if (cfg == null || !cfg.enabled) {
            danmaku.enabled(false);
            danmuStatus.markDisabled();
            return;
        }
        danmaku.applyConfig(cfg);
        final DandanplayProvider provider = cfg.createProvider();
        if (provider.getConfiguredOrigins().isEmpty()) {
            if (showFeedback) {
                a.toast("未配置自定义弹幕服务源，请在弹幕设置中填写服务地址或导入本地文件");
            }
            return;
        }
        final int serial = ++danmuSessionSerial;
        final int loadSer = ++danmuLoadSerial;
        final DanmuOwnership.RequestContext ownerSnap = danmuOwner;
        final DanmuProvider.CancellationToken token = new DanmuProvider.CancellationToken();
        danmuMatchToken = token;
        String sig = danmuServerSignature(cfg);
        activeDanmuServerSignature = sig;
        lastObservedDanmuServerSignature = sig;
        danmuStatus.markLoading(DanmuOwnership.SourceKind.CUSTOM_SERVICE);
        final DanmuProvider.MatchQuery query = buildDanmuMatchQuery();
        final String siteKeySnap = site != null && site.key != null ? site.key : "";
        final String videoIdSnap = video != null && video.id != null ? video.id : "";
        final String rawTitleSnap = video != null && video.title != null ? video.title : "";
        final int rawEpIdxSnap = episodeIndex();
        final String epDisplaySnap = currentEpisodeDisplayLabel();
        a.worker.execute(
                () -> {
                    try {
                        DanmuProvider.Candidate manualHit = null;
                        SeriesScrapeStore.OverrideRecord ov =
                                SeriesScrapeStore.load(a, siteKeySnap, videoIdSnap, rawTitleSnap);
                        String manualBoundId =
                                (ov != null && rawEpIdxSnap >= 0)
                                        ? ov.danmuEpisodeIdOverrides.get(rawEpIdxSnap)
                                        : null;
                        if (manualBoundId != null && !manualBoundId.trim().isEmpty()) {
                            try {
                                DandanplayProvider.BoundEpisode decoded =
                                        DandanplayProvider.decodeBoundEpisodeId(
                                                manualBoundId, provider.getConfiguredOrigins());
                                manualHit =
                                        new DanmuProvider.Candidate(
                                                decoded.origin,
                                                ov.danmuAnimeId,
                                                ov.danmuTitleOverride.isEmpty()
                                                        ? query.title
                                                        : ov.danmuTitleOverride,
                                                manualBoundId,
                                                epDisplaySnap,
                                                1.0);
                            } catch (Exception ignored) {
                            }
                        }
                        List<DanmuProvider.Candidate> candidates =
                                manualHit != null
                                        ? Collections.singletonList(manualHit)
                                        : provider.matchOrSearch(query, token);
                        final DanmuProvider.Candidate best =
                                (candidates != null && !candidates.isEmpty())
                                        ? candidates.get(0)
                                        : null;
                        String rawCid = "";
                        if (best != null
                                && best.boundEpisodeId != null
                                && !best.boundEpisodeId.isEmpty()) {
                            try {
                                rawCid =
                                        DandanplayProvider.decodeBoundEpisodeId(
                                                        best.boundEpisodeId,
                                                        provider.getConfiguredOrigins())
                                                .rawEpisodeId;
                            } catch (Exception ignored) {
                            }
                        }
                        final String resolvedCommentId = rawCid;
                        AppLog.i(
                                "PlaybackControls",
                                DanmuProvider.FailureInfo.sanitizedDiagnostic(
                                        "match",
                                        200,
                                        ownerSnap != null ? ownerSnap.anonId() : "-",
                                        candidates == null ? 0 : candidates.size()));
                        a.ui.post(
                                () -> {
                                    if (token.isCancelled()
                                            || serial != danmuSessionSerial
                                            || loadSer != danmuLoadSerial
                                            || !isDanmuOwnerStillActive(ownerSnap)) {
                                        return;
                                    }
                                    danmuMatchToken = null;
                                    DanmuSettingsPanel.DanmuConfig latestCfg =
                                            DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
                                    if (!shouldApplyAsyncMatchResult(cfg, latestCfg)) {
                                        return;
                                    }
                                    if (best == null
                                            || best.boundEpisodeId == null
                                            || best.boundEpisodeId.isEmpty()) {
                                        danmuStatus.markNoMatch();
                                        if (showFeedback) {
                                            a.toast("未匹配到本集弹幕，可在弹幕菜单「手动搜索弹幕」");
                                        }
                                        return;
                                    }
                                    final String matchLabel =
                                            best.animeTitle
                                                    + (best.episodeTitle.isEmpty()
                                                            ? ""
                                                            : " · " + best.episodeTitle);
                                    DanmuSegmentCache cache = new DanmuSegmentCache(provider);
                                    danmuSegmentCache = cache;
                                    danmakuLoaded = false;
                                    activeDanmuCandidate = best;
                                    danmaku.applyConfig(latestCfg);
                                    danmaku.attachSegmentCache(
                                            cache,
                                            new DanmakuView.SegmentEventListener() {
                                                @Override
                                                public void onSessionReady(
                                                        final boolean segmented,
                                                        final int knownTotalCount) {
                                                    a.ui.post(
                                                            () -> {
                                                                if (serial != danmuSessionSerial
                                                                        || !isDanmuOwnerStillActive(
                                                                                ownerSnap)) {
                                                                    return;
                                                                }
                                                                DanmuOwnership.GLOBAL
                                                                        .markConfirmedDanmuMounted(
                                                                                ownerSnap);
                                                                if (!segmented
                                                                        && knownTotalCount == 0) {
                                                                    danmuStatus.markNoComments(
                                                                            DanmuOwnership
                                                                                    .SourceKind
                                                                                    .CUSTOM_SERVICE,
                                                                            matchLabel,
                                                                            resolvedCommentId);
                                                                } else {
                                                                    danmuStatus.markLoaded(
                                                                            DanmuOwnership
                                                                                    .SourceKind
                                                                                    .CUSTOM_SERVICE,
                                                                            segmented
                                                                                    ? -1
                                                                                    : knownTotalCount,
                                                                            matchLabel,
                                                                            resolvedCommentId);
                                                                }
                                                                AppLog.i(
                                                                        "PlaybackControls",
                                                                        DanmuProvider.FailureInfo
                                                                                .sanitizedDiagnostic(
                                                                                        "open_session",
                                                                                        200,
                                                                                        ownerSnap
                                                                                                .anonId(),
                                                                                        knownTotalCount));
                                                            });
                                                }

                                                @Override
                                                public void onWindowReady(
                                                        int windowIndex, int count) {
                                                    a.ui.post(
                                                            () -> {
                                                                if (serial != danmuSessionSerial
                                                                        || !isDanmuOwnerStillActive(
                                                                                ownerSnap)) {
                                                                    return;
                                                                }
                                                                if (danmuStatus.state
                                                                        == DanmuOwnership.State
                                                                                .LOADING) {
                                                                    DanmuOwnership.GLOBAL
                                                                            .markConfirmedDanmuMounted(
                                                                                    ownerSnap);
                                                                    danmuStatus.markLoaded(
                                                                            DanmuOwnership
                                                                                    .SourceKind
                                                                                    .CUSTOM_SERVICE,
                                                                            -1,
                                                                            matchLabel,
                                                                            resolvedCommentId);
                                                                }
                                                            });
                                                }

                                                @Override
                                                public void onError(
                                                        final String stage,
                                                        final Throwable error,
                                                        final String fallbackMessage) {
                                                    final DanmuProvider.FailureInfo fi =
                                                            DanmuProvider.FailureInfo.classify(
                                                                    error);
                                                    AppLog.w(
                                                            "PlaybackControls",
                                                            DanmuProvider.FailureInfo
                                                                    .sanitizedDiagnostic(
                                                                            stage,
                                                                            fi.httpStatus,
                                                                            ownerSnap.anonId(),
                                                                            0),
                                                            null);
                                                    a.ui.post(
                                                            () -> {
                                                                if (serial != danmuSessionSerial
                                                                        || !isDanmuOwnerStillActive(
                                                                                ownerSnap)) {
                                                                    return;
                                                                }
                                                                danmuStatus.markFailure(
                                                                        DanmuOwnership.SourceKind
                                                                                .CUSTOM_SERVICE,
                                                                        fi);
                                                                refreshDanmuBadgeIcon();
                                                                String toastKey =
                                                                        stage
                                                                                + ":"
                                                                                + fi.kind
                                                                                + ":"
                                                                                + fi.httpStatus;
                                                                if (showFeedback
                                                                        || danmuStatus
                                                                                .shouldEmitAutoToast(
                                                                                        toastKey)) {
                                                                    a.toast(
                                                                            "本集弹幕加载失败："
                                                                                    + fi.shortReason);
                                                                }
                                                            });
                                                }
                                            });
                                    danmaku.enabled(true);
                                    cache.bindSession(best.boundEpisodeId);
                                    if (a.player != null && a.prepared) {
                                        danmaku.setPlaySpeed(a.player.getSpeed());
                                        cache.onPlaybackTick(
                                                a.player.getCurrentPosition(),
                                                a.player.isPlaying());
                                    }
                                    if (showFeedback) {
                                        a.toast("已匹配本集弹幕：" + matchLabel);
                                    }
                                });
                    } catch (DanmuProvider.CancelledException ignored) {
                    } catch (Exception error) {
                        final DanmuProvider.FailureInfo fi =
                                DanmuProvider.FailureInfo.classify(error);
                        AppLog.w(
                                "PlaybackControls",
                                DanmuProvider.FailureInfo.sanitizedDiagnostic(
                                        "match",
                                        fi.httpStatus,
                                        ownerSnap != null ? ownerSnap.anonId() : "-",
                                        0),
                                null);
                        a.ui.post(
                                () -> {
                                    if (token.isCancelled()
                                            || serial != danmuSessionSerial
                                            || loadSer != danmuLoadSerial
                                            || !isDanmuOwnerStillActive(ownerSnap)) {
                                        return;
                                    }
                                    danmuMatchToken = null;
                                    danmuStatus.markFailure(
                                            DanmuOwnership.SourceKind.CUSTOM_SERVICE, fi);
                                    refreshDanmuBadgeIcon();
                                    String toastKey = "match:" + fi.kind + ":" + fi.httpStatus;
                                    if (showFeedback || danmuStatus.shouldEmitAutoToast(toastKey)) {
                                        a.toast("本集弹幕加载失败：" + fi.shortReason);
                                    }
                                });
                    }
                });
    }

    private void onDanmuConfigUpdated(DanmuSettingsPanel.DanmuConfig config) {
        if (config == null || danmaku.closed) return;
        danmaku.applyConfig(config);
        String prevSig = lastObservedDanmuServerSignature;
        String nextSig = danmuServerSignature(config);
        lastObservedDanmuServerSignature = nextSig;
        if (!config.enabled) {
            closeSegmentedDanmuSession();
            return;
        }
        if (a.isLive() || a.isCast()) return;
        if (config.serverUrls.isEmpty()) {
            if (danmuSegmentCache != null) {
                closeSegmentedDanmuSession();
            }
            return;
        }
        if (shouldStartSegmentedSessionOnConfigUpdate(
                config.enabled,
                config.serverUrls,
                danmuSegmentCache != null || danmuMatchToken != null,
                danmakuLoaded,
                prevSig,
                nextSig)) {
            startSegmentedDanmuSession(config, false);
        }
    }

    void openDanmuSettingsPanel() {
        if (activeDialog != null) {
            activeDialog.dismiss();
            activeDialog = null;
        }
        if (skipCountdownPill != null) {
            skipCountdownPill.dismissSilently();
        }
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.onDialogOpened();
        }
        lastObservedDanmuServerSignature =
                danmuServerSignature(DanmuSettingsPanel.loadConfig(a, a.isTvDevice()));
        dialogOpen = true;
        hideButtonTooltip(true);
        if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
        final Dialog[] holder = new Dialog[1];
        android.app.AlertDialog dlg =
                DanmuSettingsPanel.showDialog(a, a.isTvDevice(), this::onDanmuConfigUpdated);
        holder[0] = dlg;
        dlg.setOnDismissListener(
                d -> {
                    if (activeDialog == holder[0]) {
                        activeDialog = null;
                        dialogOpen = false;
                        if (!a.isFinishing()
                                && (android.os.Build.VERSION.SDK_INT < 17 || !a.isDestroyed())) {
                            a.scheduleHide();
                            if (a.isTvDevice() && a.controlsVisible) {
                                restoreToolbarFocusAfterSubmenu();
                            }
                            if (a.ui != null) {
                                a.ui.post(
                                        () -> {
                                            if (a.playbackControls == this && !dialogOpen) {
                                                refreshTooltipForCurrentFocus();
                                            }
                                        });
                            }
                        }
                    }
                });
        activeDialog = dlg;
    }

    private void refreshDanmuBadgeIcon() {
        Button dmBtn = buttons.get(TvPlayerToolbarOrder.KEY_DANMAKU);
        if (dmBtn != null) dmBtn.invalidate();
    }

    void openManualDanmuSearchDialog(final Runnable onCancelBack) {
        DanmuSettingsPanel.DanmuConfig cfg = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        DandanplayProvider provider = cfg.createProvider();
        String rawTitle = video != null && video.title != null ? video.title.trim() : "";
        Cms.Episode ep = a.activeEpisode != null ? a.activeEpisode : resolved;
        String epName = ep != null && ep.name != null ? ep.name.trim() : "";
        List<Cms.Episode> eps =
                a.activeLine != null && a.activeLine.episodes != null
                        ? a.activeLine.episodes
                        : Collections.<Cms.Episode>emptyList();
        int rawIdx = episodeIndex();
        int epNum =
                (rawIdx >= 0 && rawIdx < eps.size())
                        ? TvSeriesScraper.resolveDanmuEpisodeNumber(
                                rawTitle, eps, rawIdx, null)
                        : DandanplayProvider.extractEpisodeNum(epName);
        if (activeDialog != null && activeDialog.isShowing()) {
            try {
                activeDialog.dismiss();
            } catch (Exception ignored) {
            }
        }
        final boolean[] selectedRef = {false};
        Dialog dlg =
                TvDanmuSearchDialog.show(
                        a,
                        provider,
                        rawTitle,
                        epName,
                        epNum,
                        cand -> {
                            selectedRef[0] = true;
                            dialogOpen = false;
                            activeDialog = null;
                            bindManualDanmuCandidate(cand);
                        });
        if (dlg == null) return;
        activeDialog = dlg;
        dialogOpen = true;
        dlg.setOnDismissListener(
                d -> {
                    if (activeDialog == dlg) {
                        activeDialog = null;
                        dialogOpen = false;
                        TvQrInputHelper.dismissActive();
                        if (!a.isFinishing()
                                && (android.os.Build.VERSION.SDK_INT < 17 || !a.isDestroyed())) {
                            a.scheduleHide();
                            if (a.isTvDevice() && a.controlsVisible) {
                                restoreToolbarFocusAfterSubmenu();
                            }
                            if (!selectedRef[0] && onCancelBack != null) {
                                onCancelBack.run();
                            }
                        }
                    }
                });
    }

    void bindManualDanmuCandidate(DanmuProvider.Candidate cand) {
        if (cand == null || cand.boundEpisodeId == null || cand.boundEpisodeId.isEmpty()) return;
        String siteKey = site != null && site.key != null ? site.key : "";
        String videoId = video != null && video.id != null ? video.id : "";
        String rawTitle = video != null && video.title != null ? video.title.trim() : "";
        SeriesScrapeStore.OverrideRecord existing =
                SeriesScrapeStore.load(a, siteKey, videoId, rawTitle);
        SeriesScrapeStore.OverrideRecord rec =
                existing != null ? existing : new SeriesScrapeStore.OverrideRecord();
        if (!cand.animeId.isEmpty()) rec.danmuAnimeId = cand.animeId;
        if (!cand.sourceOrigin.isEmpty()) rec.danmuOrigin = cand.sourceOrigin;
        if (!cand.animeTitle.isEmpty()) rec.danmuTitleOverride = cand.animeTitle;
        int rawIdx = episodeIndex();
        if (rawIdx >= 0) {
            rec.danmuEpisodeIdOverrides.put(rawIdx, cand.boundEpisodeId);
        }
        SeriesScrapeStore.save(a, siteKey, videoId, rawTitle, rec);

        DanmuSettingsPanel.DanmuConfig refreshed =
                DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        if (!refreshed.enabled) {
            a.prefs.edit().putBoolean(Prefs.DANMAKU_DEFAULT, true).apply();
            refreshed = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        }
        if (danmaku != null) danmaku.enabled(true);
        startSegmentedDanmuSession(refreshed, true);
        updateLabels();
        a.toast(
                "已绑定弹幕："
                        + (cand.animeTitle.isEmpty() ? "所选剧目" : cand.animeTitle)
                        + (cand.episodeTitle.isEmpty() ? "" : " · " + cand.episodeTitle));
    }

    void danmaku() {
        danmaku(null);
    }

    void danmaku(Runnable onCancelBack) {
        danmuStatus.episodeLabel = currentEpisodeDisplayLabel();
        String statusHeadline = danmuStatus.statusHeadline();
        DanmuSettingsPanel.DanmuConfig dmCur = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        boolean autoLoad = a.prefs.getBoolean(Prefs.DANMAKU_DEFAULT, true);
        boolean currentlyShown = danmaku != null && danmaku.enabled;

        List<PlayerBubble.Row> rows = new ArrayList<>();
        rows.add(
                PlayerBubble.Row.item(0, currentlyShown ? "隐藏弹幕（本集）" : "显示弹幕（本集）", currentlyShown));
        rows.add(PlayerBubble.Row.item(1, "重试本集（本集）", false));
        rows.add(PlayerBubble.Row.item(2, "🔍 手动搜索弹幕（适合网盘加长文件名）", false));
        rows.add(PlayerBubble.Row.item(3, "校正集数 / 更换匹配（本剧）", false));
        rows.add(PlayerBubble.Row.item(4, "导入本地弹幕文件（本集）", false));
        rows.add(
                PlayerBubble.Row.item(
                        5, "自动加载片源弹幕：" + (autoLoad ? "开启" : "关闭") + "（以后播放沿用）", autoLoad));
        rows.add(
                PlayerBubble.Row.item(
                        6,
                        "弹幕偏好（" + DanmuSettingsPanel.formatCompactStatus(dmCur) + " · 以后播放沿用）",
                        false));

        String rec = danmuStatus.recommendedInitialFocusAction();
        int initialFocus = "retry".equals(rec) ? 1 : ("correct".equals(rec) ? 2 : 0);

        showStructuredBubble(
                "弹幕",
                statusHeadline,
                rows,
                initialFocus,
                i -> {
                    if (i == 0) {
                        if (currentlyShown) {
                            if (danmaku != null) danmaku.enabled(false);
                            danmuStatus.markDisabled();
                            refreshDanmuBadgeIcon();
                        } else {
                            if (danmaku != null) danmaku.enabled(true);
                            if (danmakuLoaded || danmuSegmentCache != null) {
                                danmuStatus.state = DanmuOwnership.State.LOADED;
                                refreshDanmuBadgeIcon();
                            } else {
                                retryCurrentEpisodeDanmu(true);
                            }
                        }
                        return;
                    }
                    if (i == 1) {
                        retryCurrentEpisodeDanmu(true);
                        return;
                    }
                    if (i == 2) {
                        openManualDanmuSearchDialog(() -> danmaku(onCancelBack));
                        return;
                    }
                    if (i == 3) {
                        TvSeriesScrapeDialog.show(
                                a,
                                site,
                                video,
                                a.activeLine,
                                () -> {
                                    DanmuSettingsPanel.DanmuConfig refreshed =
                                            DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
                                    if (refreshed.enabled && !refreshed.serverUrls.isEmpty()) {
                                        startSegmentedDanmuSession(refreshed, true);
                                    }
                                    updateLabels();
                                });
                        return;
                    }
                    if (i == 4) {
                        a.pickDanmaku();
                        return;
                    }
                    if (i == 5) {
                        boolean nextAuto = !autoLoad;
                        a.prefs.edit().putBoolean(Prefs.DANMAKU_DEFAULT, nextAuto).apply();
                        a.toast(nextAuto ? "以后播放将自动加载片源弹幕" : "已关闭以后播放自动加载片源弹幕");
                        return;
                    }
                    if (i == 6) {
                        openDanmuSettingsPanel();
                    }
                },
                "",
                true,
                onCancelBack);
    }

    void soundEffect() {
        soundEffect(null);
    }

    private void applyPlayerAudioEffects(int preset, int boostDb) throws Exception {
        if (a.player == null) throw new IllegalStateException();
        boolean isMpv = a.player instanceof MpvPlayer;
        if (a.player.supportsInAppAudioEffects()) {
            effects.close();
            a.player.applyInAppAudioEffect(preset);
            a.player.applyInAppLoudnessBoost(boostDb);
            return;
        }
        if (isMpv) {
            effects.close();
            ((MpvPlayer) a.player).applyLoudnessBoost(boostDb);
            if (preset != 0) throw new IllegalStateException("MPV 引擎暂不使用系统音效接口");
            return;
        }
        if (PlaybackEffects.shouldUsePlatformAudioFx(false, false)) {
            effects.audio(a.player.getAudioSessionId(), preset);
            effects.applyLoudness(a.player.getAudioSessionId(), boostDb);
        }
    }

    private void warnIfTvSystemAudioMuted() {
        if (!a.isTvDevice() || a.isCast() || tvMuteHintShownForEpisode) return;
        try {
            android.media.AudioManager am =
                    (android.media.AudioManager)
                            a.getSystemService(android.content.Context.AUDIO_SERVICE);
            if (am == null) return;
            int vol = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC);
            boolean muted =
                    android.os.Build.VERSION.SDK_INT >= 23
                            && am.isStreamMute(android.media.AudioManager.STREAM_MUSIC);
            if (muted || vol <= 0) {
                tvMuteHintShownForEpisode = true;
                a.toast("电视当前处于静音或音量为 0，请按遥控器音量+恢复声音");
            }
        } catch (Throwable ignored) {
        }
    }

    void soundEffect(Runnable onCancelBack) {
        choose(
                "音效（以后播放沿用）",
                new String[] {"原声", "影院", "人声清晰", "柔和低音"},
                a.prefs.getInt(Prefs.AUDIO_EFFECT, 0),
                i -> {
                    try {
                        int boost = a.prefs.getInt(Prefs.LOUDNESS_BOOST, 0);
                        applyPlayerAudioEffects(i, boost);
                        a.prefs.edit().putInt(Prefs.AUDIO_EFFECT, i).apply();
                    } catch (Exception error) {
                        message("这台设备当前音轨未提供可用音效接口。", onCancelBack);
                    }
                },
                onCancelBack);
    }

    void pictureEffect() {
        pictureEffect(null);
    }

    void pictureEffect(Runnable onCancelBack) {
        choose(
                "画面色彩（以后播放沿用）",
                new String[] {"原始画面", "明亮", "影院", "柔和"},
                a.prefs.getInt(Prefs.PICTURE_EFFECT, 0),
                i -> {
                    if (i > 0 && !surface.supportsPicture()) {
                        message(
                                "当前使用保真输出，保留原始色彩。需要应用内调色时，可在“播放器与解码”选择兼容输出；HDR 内容建议保持保真输出。",
                                onCancelBack);
                        return;
                    }
                    PlaybackEffects.picture(surface, i);
                    a.prefs.edit().putInt(Prefs.PICTURE_EFFECT, i).apply();
                },
                onCancelBack);
    }

    void close() {
        cancelPendingSkipTap();
        hideButtonTooltip(true);
        if (buttonTooltip != null && buttonTooltip.getParent() instanceof ViewGroup) {
            ((ViewGroup) buttonTooltip.getParent()).removeView(buttonTooltip);
        }
        buttonTooltip = null;
        buttonTooltipBg = null;
        if (markerObservedPlayer != null) markerObservedPlayer.setOnSeekPositionListener(null);
        markerObservedPlayer = null;
        resetMarkers(); // Drop unidentified-media session markers with their owning player
        // controls.
        surface.setFrameAdvancing(false);
        if (activeDialog != null) {
            activeDialog.dismiss();
            activeDialog = null;
        }
        if (skipCountdownPill != null) skipCountdownPill.dismissSilently();
        hideSleepWarning();
        boolean preserveSleep =
                preserveSleepTimerForInPlaceSwitch
                        && !a.isFinishing()
                        && (android.os.Build.VERSION.SDK_INT < 17 || !a.isDestroyed());
        SESSION_SLEEP_TIMER.onPlayerSessionClosed(preserveSleep);
        if (preserveSleep && a.ui != null) {
            // If an in-place switch was aborted or left playback before constructing a replacement
            // PlaybackControls, clear the sleep timer on the very next UI frame.
            a.ui.post(
                    () -> {
                        if (a.playbackControls == null || a.current == null || !a.current.player) {
                            clearSleepTimerOnLeave();
                        }
                    });
        } else {
            preserveSleepTimerForInPlaceSwitch = false;
        }
        effects.close();
        danmuLoadSerial++;
        closeSegmentedDanmuSession();
        hideFirstPlayGestureHint();
        danmaku.close();
    }

    static final int[] SUBTITLE_SIZES = {28, 35, 45, 55, 65};
    static final String[] SUBTITLE_SIZE_LABELS = {"极小", "小", "标准", "大", "超大"};
    static final int[] SUBTITLE_BOTTOMS = {8, 24, 48, 76, 110, 148};
    static final String[] SUBTITLE_BOTTOM_LABELS = {"贴底", "标准", "略高", "中下", "偏高", "较高"};

    void applySubtitleStyle() {
        int size = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        int bottomDp = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        int stylePreset = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
        int weight = Prefs.clampSubtitleWeight(a.prefs.getInt(Prefs.SUBTITLE_WEIGHT, 50));
        int offsetX = Prefs.clampSubtitleOffsetX(a.prefs.getInt(Prefs.SUBTITLE_OFFSET_X, 0));
        subtitle.applyStylePreset(stylePreset, weight);
        subtitle.setSubtitleSizeValue(size);
        subtitle.setSubtitleBottomDp(bottomDp);
        subtitle.setHorizontalOffsetPercent(offsetX);
        if (danmaku != null) {
            danmaku.setSubtitleBottomClearanceDp(bottomDp + 28f);
        }
        visible(a.controlsVisible);
    }

    String subtitleSizeLabel() {
        int size = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        for (int i = 0; i < SUBTITLE_SIZES.length; i++) {
            if (SUBTITLE_SIZES[i] == size) return SUBTITLE_SIZE_LABELS[i];
        }
        return size + "";
    }

    String subtitleBottomLabel() {
        int bottomDp = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        for (int i = 0; i < SUBTITLE_BOTTOMS.length; i++) {
            if (SUBTITLE_BOTTOMS[i] == bottomDp) return SUBTITLE_BOTTOM_LABELS[i];
        }
        return bottomDp + "dp";
    }

    String subtitleStyleLabel() {
        int style = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
        return SubtitleOverlayView.STYLE_LABELS[style];
    }

    void subtitleSizeDialog() {
        showSubtitleAdjuster(a, subtitle, this::applySubtitleStyle);
    }

    void subtitleBottomDialog() {
        showSubtitleAdjuster(a, subtitle, this::applySubtitleStyle);
    }

    static void showSubtitleStyleDrawer(
            MainActivity a, int selectedIndex, PlayerBubble.IntAction onSelect) {
        if (!a.isTvDevice()) {
            MobileShell.showDrawerPicker(
                    a,
                    "选择字幕颜色与样式",
                    "选择后实时套用至全屏字幕预览与后续播放",
                    SubtitleOverlayView.STYLE_LABELS,
                    selectedIndex,
                    onSelect);
            return;
        }
        final Dialog drawer = new Dialog(a);
        drawer.requestWindowFeature(Window.FEATURE_NO_TITLE);
        if (drawer.getWindow() != null) {
            drawer.getWindow().getDecorView().setTag("app-dialog");
            drawer.getWindow()
                    .setBackgroundDrawable(
                            new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
            drawer.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            drawer.getWindow()
                    .setLayout(
                            WindowManager.LayoutParams.MATCH_PARENT,
                            WindowManager.LayoutParams.MATCH_PARENT);
        }
        FrameLayout root = new FrameLayout(a);
        root.setBackgroundColor(0x55000000);
        root.setOnClickListener(v -> drawer.dismiss());

        LinearLayout sheet = a.vertical();
        sheet.setPadding(a.dp(22), a.dp(24), a.dp(22), a.dp(24));
        android.graphics.drawable.GradientDrawable bg = a.bg(0xf2151d1a, 24);
        bg.setStroke(a.dp(1), 0x38ffffff);
        sheet.setBackground(bg);
        sheet.setClickable(true);

        TextView head = a.text("字幕颜色与样式（抽屉菜单）", 18, MainActivity.WHITE);
        head.setTypeface(null, android.graphics.Typeface.BOLD);
        sheet.addView(head);
        a.gap(sheet, 4);
        sheet.addView(a.text("上下移动实时预览，按确认键完成选择", 12, MainActivity.MUTED));
        a.gap(sheet, 14);

        ScrollView scroll = new ScrollView(a);
        scroll.setVerticalScrollBarEnabled(false);
        LinearLayout list = a.vertical();
        Button initialFocus = null;
        for (int i = 0; i < SubtitleOverlayView.STYLE_LABELS.length; i++) {
            final int idx = i;
            String label =
                    (i == selectedIndex ? "✓  " : "    ") + SubtitleOverlayView.STYLE_LABELS[i];
            Button item =
                    a.button(
                            label,
                            "sub-style-" + i,
                            () -> {
                                onSelect.accept(idx);
                                drawer.dismiss();
                            });
            item.setGravity(Gravity.LEFT | Gravity.CENTER_VERTICAL);
            item.setTextSize(14);
            item.setMinHeight(a.dp(44));
            item.setMinimumHeight(a.dp(44));
            item.setTextColor(SubtitleOverlayView.STYLE_COLORS[i]);
            item.setOnFocusChangeListener(
                    (v, focused) -> {
                        FocusMotion.style(
                                a,
                                item,
                                focused,
                                0xff202a26,
                                MainActivity.WHITE,
                                14,
                                SubtitleOverlayView.STYLE_COLORS[idx],
                                MainActivity.DARK,
                                false,
                                1.02f);
                        if (focused) {
                            onSelect.accept(idx);
                        }
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, a.dp(44));
            lp.bottomMargin = a.dp(8);
            list.addView(item, lp);
            if (i == selectedIndex) initialFocus = item;
        }
        scroll.addView(list, new ScrollView.LayoutParams(-1, -2));
        sheet.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1f));

        FrameLayout.LayoutParams sheetLp =
                new FrameLayout.LayoutParams(
                        a.dp(360),
                        WindowManager.LayoutParams.MATCH_PARENT,
                        Gravity.RIGHT | Gravity.CENTER_VERTICAL);
        sheetLp.setMargins(0, a.dp(20), a.dp(20), a.dp(20));
        root.addView(sheet, sheetLp);
        drawer.setContentView(root, new ViewGroup.LayoutParams(a.windowWidth(), a.windowHeight()));
        drawer.show();
        if (drawer.getWindow() != null) {
            drawer.getWindow()
                    .setLayout(
                            WindowManager.LayoutParams.MATCH_PARENT,
                            WindowManager.LayoutParams.MATCH_PARENT);
        }
        if (initialFocus != null) initialFocus.requestFocus();
    }

    static void showSubtitleAdjuster(
            MainActivity a, SubtitleOverlayView liveSub, Runnable onChanged) {
        final Dialog dlg = new Dialog(a);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        if (dlg.getWindow() != null) {
            dlg.getWindow().getDecorView().setTag("app-dialog");
            dlg.getWindow()
                    .setBackgroundDrawable(
                            new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
            dlg.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            dlg.getWindow()
                    .setLayout(
                            WindowManager.LayoutParams.MATCH_PARENT,
                            WindowManager.LayoutParams.MATCH_PARENT);
        }
        if (liveSub != null) {
            liveSub.setVisibility(View.INVISIBLE);
            if (a.controlsVisible) a.showControls(false);
        }

        FrameLayout fullRoot = new FrameLayout(a);
        if (liveSub == null) {
            fullRoot.setBackgroundColor(0xee080e0c);
        } else {
            fullRoot.setBackgroundColor(0x28000000);
        }

        final SubtitleOverlayView previewCanvas = new SubtitleOverlayView(a);
        previewCanvas.setPreviewActive(true);
        previewCanvas.setShowAxisGuides(true);
        fullRoot.addView(previewCanvas, new FrameLayout.LayoutParams(-1, -1));

        final SeekBar[] sizeBarRef = new SeekBar[1];
        final SeekBar[] weightBarRef = new SeekBar[1];
        final TextView[] sizeValRef = new TextView[1];
        final TextView[] weightValRef = new TextView[1];
        final TextView[] posValRef = new TextView[1];
        final TextView[] styleBtnTextRef = new TextView[1];
        final View[] initialTvFocusRef = new View[1];
        final boolean[] internalSync = {false};
        final int savedScrollY = a.scroll != null ? a.scroll.getScrollY() : 0;
        final String savedFocusTag =
                a.getCurrentFocus() != null && a.getCurrentFocus().getTag() instanceof String
                        ? (String) a.getCurrentFocus().getTag()
                        : (a.current != null ? a.current.focus : null);
        final int savedDescendantFocus =
                a.scroll != null
                        ? a.scroll.getDescendantFocusability()
                        : ViewGroup.FOCUS_AFTER_DESCENDANTS;
        if (a.scroll != null && liveSub == null) {
            a.scroll.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        }

        final Runnable syncState =
                () -> {
                    int sz = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
                    int bt = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
                    int st = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                    int wt = Prefs.clampSubtitleWeight(a.prefs.getInt(Prefs.SUBTITLE_WEIGHT, 50));
                    int ox = Prefs.clampSubtitleOffsetX(a.prefs.getInt(Prefs.SUBTITLE_OFFSET_X, 0));

                    previewCanvas.applyStylePreset(st, wt);
                    previewCanvas.setSubtitleSizeValue(sz);
                    previewCanvas.setSubtitleBottomDp(bt);
                    previewCanvas.setHorizontalOffsetPercent(ox);

                    internalSync[0] = true;
                    if (sizeBarRef[0] != null) sizeBarRef[0].setProgress(sz - 25);
                    if (weightBarRef[0] != null) weightBarRef[0].setProgress(wt);
                    internalSync[0] = false;

                    if (sizeValRef[0] != null) sizeValRef[0].setText(sz + "");
                    if (weightValRef[0] != null) weightValRef[0].setText(wt + "");
                    if (posValRef[0] != null) {
                        posValRef[0].setText(
                                "高度 "
                                        + bt
                                        + "dp · "
                                        + (Math.abs(ox) <= 2
                                                ? "中轴线居中 ✓"
                                                : ("水平 " + (ox > 0 ? "+" : "") + ox)));
                    }
                    if (styleBtnTextRef[0] != null) {
                        styleBtnTextRef[0].setText(
                                "字幕颜色与样式  ·  " + SubtitleOverlayView.STYLE_LABELS[st] + "  ▸");
                        styleBtnTextRef[0].setTextColor(SubtitleOverlayView.STYLE_COLORS[st]);
                    }
                    if (liveSub != null && onChanged != null) onChanged.run();
                };

        final Runnable resetDefaults =
                () -> {
                    a.prefs
                            .edit()
                            .putInt(Prefs.SUBTITLE_SIZE, 45)
                            .putInt(Prefs.SUBTITLE_BOTTOM, 24)
                            .putInt(Prefs.SUBTITLE_WEIGHT, 50)
                            .putInt(Prefs.SUBTITLE_OFFSET_X, 0)
                            .putInt(Prefs.SUBTITLE_STYLE, 0)
                            .apply();
                    syncState.run();
                };

        if (!a.isTvDevice()) {
            // =================================================================
            // MOBILE FULL-SCREEN INTERACTIVE SUBTITLE DEBUGGER
            // - Two-finger pinch-to-zoom for font size (25..65)
            // - One-finger press & drag for 2D position with center-axis snap
            // - Center-axis guide lines (中轴线指引)
            // - Dedicated sliders & drawer picker for color/style
            // =================================================================
            final float[] pinchSize = {
                Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45))
            };
            final boolean[] isScaling = {false};
            final float[] downXY = new float[2];
            final int[] startPos = new int[2];

            final ScaleGestureDetector scaleDetector =
                    new ScaleGestureDetector(
                            a,
                            new ScaleGestureDetector.SimpleOnScaleGestureListener() {
                                @Override
                                public boolean onScaleBegin(ScaleGestureDetector detector) {
                                    isScaling[0] = true;
                                    pinchSize[0] =
                                            Prefs.clampSubtitleSize(
                                                    a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
                                    return true;
                                }

                                @Override
                                public boolean onScale(ScaleGestureDetector detector) {
                                    pinchSize[0] =
                                            Math.max(
                                                    25f,
                                                    Math.min(
                                                            65f,
                                                            pinchSize[0]
                                                                    * detector.getScaleFactor()));
                                    int nextSz = Prefs.clampSubtitleSize(Math.round(pinchSize[0]));
                                    a.prefs.edit().putInt(Prefs.SUBTITLE_SIZE, nextSz).apply();
                                    syncState.run();
                                    return true;
                                }

                                @Override
                                public void onScaleEnd(ScaleGestureDetector detector) {
                                    isScaling[0] = false;
                                }
                            });

            previewCanvas.setOnTouchListener(
                    (v, event) -> {
                        scaleDetector.onTouchEvent(event);
                        int action = event.getActionMasked();
                        if (action == MotionEvent.ACTION_DOWN) {
                            downXY[0] = event.getRawX();
                            downXY[1] = event.getRawY();
                            startPos[0] =
                                    Prefs.clampSubtitleOffsetX(
                                            a.prefs.getInt(Prefs.SUBTITLE_OFFSET_X, 0));
                            startPos[1] =
                                    Prefs.clampSubtitleBottom(
                                            a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
                            previewCanvas.setShowAxisGuides(true);
                            return true;
                        }
                        if (action == MotionEvent.ACTION_POINTER_DOWN) {
                            isScaling[0] = true;
                            return true;
                        }
                        if (action == MotionEvent.ACTION_MOVE) {
                            if (isScaling[0] || event.getPointerCount() > 1) return true;
                            float dx = event.getRawX() - downXY[0];
                            float dy = event.getRawY() - downXY[1];
                            float maxShiftX = Math.max(a.dp(80), previewCanvas.getWidth() * 0.30f);
                            int nextOx =
                                    Prefs.clampSubtitleOffsetX(
                                            startPos[0] + Math.round((dx / maxShiftX) * 100f));
                            if (Math.abs(nextOx) <= 4) {
                                nextOx = 0; // Magnetic snap to vertical center axis (中轴线吸附)
                            }
                            int nextBt =
                                    Prefs.clampSubtitleBottom(
                                            startPos[1]
                                                    - Math.round(dy / Math.max(1f, a.dp(2.2f))));
                            if (Math.abs(nextBt - 24) <= 2) {
                                nextBt = 24;
                            }
                            a.prefs
                                    .edit()
                                    .putInt(Prefs.SUBTITLE_OFFSET_X, nextOx)
                                    .putInt(Prefs.SUBTITLE_BOTTOM, nextBt)
                                    .apply();
                            syncState.run();
                            return true;
                        }
                        return true;
                    });

            // Top floating HUD bar
            LinearLayout topBar = a.row();
            topBar.setGravity(Gravity.CENTER_VERTICAL);
            topBar.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
            android.graphics.drawable.GradientDrawable topBg = a.bg(0xdd141c19, 20);
            topBg.setStroke(a.dp(1), 0x33ffffff);
            topBar.setBackground(topBg);

            LinearLayout titleCol = a.vertical();
            TextView t1 = a.text("全屏字幕触控调试", 14.5f, MainActivity.WHITE);
            t1.setTypeface(null, android.graphics.Typeface.BOLD);
            titleCol.addView(t1);
            TextView t2 = a.text("单指按住拖拽位置（中轴线自动吸附） · 双指捏合缩放字号", 11.5f, 0xff9ca3af);
            titleCol.addView(t2);
            topBar.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));

            TextView resetBtn = a.text("重置居中", 12, 0xffe5e7eb);
            resetBtn.setGravity(Gravity.CENTER);
            resetBtn.setPadding(a.dp(12), a.dp(7), a.dp(12), a.dp(7));
            resetBtn.setBackground(a.bg(0x28ffffff, 999));
            MobileDetailScreen.bindTouchFeedback(resetBtn);
            resetBtn.setOnClickListener(v -> resetDefaults.run());
            LinearLayout.LayoutParams resetLp = new LinearLayout.LayoutParams(-2, -2);
            resetLp.rightMargin = a.dp(8);
            topBar.addView(resetBtn, resetLp);

            TextView doneBtn = a.text("完成", 12.5f, Color.WHITE);
            doneBtn.setTypeface(null, android.graphics.Typeface.BOLD);
            doneBtn.setGravity(Gravity.CENTER);
            doneBtn.setPadding(a.dp(15), a.dp(7), a.dp(15), a.dp(7));
            doneBtn.setBackground(a.bg(0xff1f7a54, 999));
            MobileDetailScreen.bindTouchFeedback(doneBtn);
            doneBtn.setOnClickListener(v -> dlg.dismiss());
            topBar.addView(doneBtn, new LinearLayout.LayoutParams(-2, -2));

            FrameLayout.LayoutParams topLp =
                    new FrameLayout.LayoutParams(-1, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
            int topInset = a.statusBarHeight() + a.dp(8);
            topLp.setMargins(a.dp(14), topInset, a.dp(14), 0);
            fullRoot.addView(topBar, topLp);

            // Compact floating control card at top-below-HUD (so bottom subtitle area stays clear)
            LinearLayout ctrlCard = a.vertical();
            ctrlCard.setPadding(a.dp(16), a.dp(12), a.dp(16), a.dp(12));
            android.graphics.drawable.GradientDrawable ctrlBg = a.bg(0xdc141c19, 20);
            ctrlBg.setStroke(a.dp(1), 0x2effffff);
            ctrlCard.setBackground(ctrlBg);

            // Size slider row
            LinearLayout szRow = a.row();
            szRow.setGravity(Gravity.CENTER_VERTICAL);
            szRow.addView(a.text("字幕大小", 12.5f, MainActivity.WHITE));
            SeekBar szBar = new SeekBar(a);
            szBar.setMax(40);
            UiCompat.tintSeekBar(szBar, 0xff34d399, Color.WHITE);
            sizeBarRef[0] = szBar;
            szRow.addView(szBar, new LinearLayout.LayoutParams(0, -2, 1f));
            TextView szVal = a.text("45", 12.5f, 0xff34d399);
            szVal.setGravity(Gravity.RIGHT);
            sizeValRef[0] = szVal;
            szRow.addView(szVal, new LinearLayout.LayoutParams(a.dp(32), -2));
            ctrlCard.addView(szRow, new LinearLayout.LayoutParams(-1, -2));

            a.gap(ctrlCard, 6);

            // Weight slider row
            LinearLayout wtRow = a.row();
            wtRow.setGravity(Gravity.CENTER_VERTICAL);
            wtRow.addView(a.text("字体粗细", 12.5f, MainActivity.WHITE));
            SeekBar wtBar = new SeekBar(a);
            wtBar.setMax(100);
            UiCompat.tintSeekBar(wtBar, 0xff5ac8fa, Color.WHITE);
            weightBarRef[0] = wtBar;
            wtRow.addView(wtBar, new LinearLayout.LayoutParams(0, -2, 1f));
            TextView wtVal = a.text("50", 12.5f, 0xff5ac8fa);
            wtVal.setGravity(Gravity.RIGHT);
            weightValRef[0] = wtVal;
            wtRow.addView(wtVal, new LinearLayout.LayoutParams(a.dp(32), -2));
            ctrlCard.addView(wtRow, new LinearLayout.LayoutParams(-1, -2));

            a.gap(ctrlCard, 8);

            // Drawer button for Subtitle Color & Style
            TextView styleDrawerBtn = a.text("", 13, Color.WHITE);
            styleDrawerBtn.setTypeface(null, android.graphics.Typeface.BOLD);
            styleDrawerBtn.setGravity(Gravity.CENTER);
            styleDrawerBtn.setPadding(a.dp(14), a.dp(9), a.dp(14), a.dp(9));
            styleDrawerBtn.setBackground(a.bg(0x24ffffff, 14));
            MobileDetailScreen.bindTouchFeedback(styleDrawerBtn);
            styleBtnTextRef[0] = styleDrawerBtn;
            styleDrawerBtn.setOnClickListener(
                    v -> {
                        int curSt =
                                Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                        showSubtitleStyleDrawer(
                                a,
                                curSt,
                                idx -> {
                                    a.prefs.edit().putInt(Prefs.SUBTITLE_STYLE, idx).apply();
                                    syncState.run();
                                });
                    });
            ctrlCard.addView(styleDrawerBtn, new LinearLayout.LayoutParams(-1, -2));

            szBar.setOnSeekBarChangeListener(
                    new SeekBar.OnSeekBarChangeListener() {
                        @Override
                        public void onProgressChanged(SeekBar b, int p, boolean fromUser) {
                            if (!fromUser || internalSync[0]) return;
                            a.prefs.edit().putInt(Prefs.SUBTITLE_SIZE, 25 + p).apply();
                            syncState.run();
                        }

                        @Override
                        public void onStartTrackingTouch(SeekBar b) {}

                        @Override
                        public void onStopTrackingTouch(SeekBar b) {}
                    });
            wtBar.setOnSeekBarChangeListener(
                    new SeekBar.OnSeekBarChangeListener() {
                        @Override
                        public void onProgressChanged(SeekBar b, int p, boolean fromUser) {
                            if (!fromUser || internalSync[0]) return;
                            a.prefs.edit().putInt(Prefs.SUBTITLE_WEIGHT, p).apply();
                            syncState.run();
                        }

                        @Override
                        public void onStartTrackingTouch(SeekBar b) {}

                        @Override
                        public void onStopTrackingTouch(SeekBar b) {}
                    });

            FrameLayout.LayoutParams ctrlLp =
                    new FrameLayout.LayoutParams(-1, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
            ctrlLp.setMargins(a.dp(14), topInset + a.dp(62), a.dp(14), 0);
            fullRoot.addView(ctrlCard, ctrlLp);
        } else {
            // =================================================================
            // TV FULL-SCREEN SUBTITLE PREVIEW & ADJUSTER
            // - D-Pad 2D position adjustment with center-axis guide lines
            // - Dedicated SeekBar slider for Subtitle Size (字幕大小)
            // - Dedicated SeekBar slider for Subtitle Weight (字体粗细)
            // - Slide-in Drawer Menu for Subtitle Color & Style (字幕颜色与样式)
            // =================================================================
            LinearLayout tvPanel = a.vertical();
            tvPanel.setPadding(a.dp(22), a.dp(16), a.dp(22), a.dp(16));
            android.graphics.drawable.GradientDrawable bg = a.bg(0xe4141c19, 22);
            bg.setStroke(a.dp(1), 0x40ffffff);
            tvPanel.setBackground(bg);

            LinearLayout headerRow = a.row();
            headerRow.setGravity(Gravity.CENTER_VERTICAL);
            TextView title = a.text("全屏字幕实时预览与调节", 17, MainActivity.WHITE);
            title.setTypeface(null, android.graphics.Typeface.BOLD);
            headerRow.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));
            TextView posStatus = a.text("", 12.5f, 0xff34d399);
            posValRef[0] = posStatus;
            headerRow.addView(posStatus);
            tvPanel.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));
            a.gap(tvPanel, 10);

            // 1. D-Pad Position Control Row (Interactive 2D D-Pad Mode + Quick Step Buttons)
            final boolean[] posDpadActive = {false};
            LinearLayout posRow = a.row();
            posRow.setGravity(Gravity.CENTER_VERTICAL);
            final Button posDpadBtn = a.button("十字方向键调位置（点击进入全向微调）", "tv-sub-pos-mode", () -> {});
            posDpadBtn.setId(View.generateViewId());
            posDpadBtn.setNextFocusUpId(posDpadBtn.getId());
            posDpadBtn.setNextFocusLeftId(posDpadBtn.getId());
            posDpadBtn.setTextSize(13f);
            posDpadBtn.setMinHeight(a.dp(40));
            posDpadBtn.setMinimumHeight(a.dp(40));
            initialTvFocusRef[0] = posDpadBtn;

            final Runnable updatePosModeUi =
                    () -> {
                        boolean active = posDpadActive[0];
                        posDpadBtn.setText(
                                active ? "● 正在用 ▲▼◀▶ 调节位置（按确认键或返回键退出位置模式）" : "十字方向键调位置（点击进入全向微调）");
                        int selfId = posDpadBtn.getId();
                        posDpadBtn.setNextFocusUpId(selfId);
                        posDpadBtn.setNextFocusLeftId(selfId);
                        posDpadBtn.setNextFocusDownId(active ? selfId : View.NO_ID);
                        posDpadBtn.setNextFocusRightId(active ? selfId : View.NO_ID);
                    };

            posDpadBtn.setOnClickListener(
                    v -> {
                        posDpadActive[0] = !posDpadActive[0];
                        updatePosModeUi.run();
                        posDpadBtn.requestFocus();
                    });

            final View.OnKeyListener posModeKeyHandler =
                    (v, keyCode, event) -> {
                        if (!posDpadActive[0]) {
                            return false;
                        }
                        int action = event.getAction();
                        if (keyCode == KeyEvent.KEYCODE_DPAD_UP) {
                            if (action == KeyEvent.ACTION_DOWN) {
                                int bt =
                                        Prefs.clampSubtitleBottom(
                                                a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24) + 4);
                                a.prefs.edit().putInt(Prefs.SUBTITLE_BOTTOM, bt).apply();
                                syncState.run();
                            }
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
                            if (action == KeyEvent.ACTION_DOWN) {
                                int bt =
                                        Prefs.clampSubtitleBottom(
                                                a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24) - 4);
                                a.prefs.edit().putInt(Prefs.SUBTITLE_BOTTOM, bt).apply();
                                syncState.run();
                            }
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) {
                            if (action == KeyEvent.ACTION_DOWN) {
                                int ox =
                                        Prefs.clampSubtitleOffsetX(
                                                a.prefs.getInt(Prefs.SUBTITLE_OFFSET_X, 0) - 4);
                                if (Math.abs(ox) <= 2) ox = 0;
                                a.prefs.edit().putInt(Prefs.SUBTITLE_OFFSET_X, ox).apply();
                                syncState.run();
                            }
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) {
                            if (action == KeyEvent.ACTION_DOWN) {
                                int ox =
                                        Prefs.clampSubtitleOffsetX(
                                                a.prefs.getInt(Prefs.SUBTITLE_OFFSET_X, 0) + 4);
                                if (Math.abs(ox) <= 2) ox = 0;
                                a.prefs.edit().putInt(Prefs.SUBTITLE_OFFSET_X, ox).apply();
                                syncState.run();
                            }
                            return true;
                        }
                        if (keyCode == KeyEvent.KEYCODE_BACK
                                || keyCode == KeyEvent.KEYCODE_ESCAPE
                                || keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                                || keyCode == KeyEvent.KEYCODE_ENTER
                                || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                            if (action == KeyEvent.ACTION_UP) {
                                posDpadActive[0] = false;
                                updatePosModeUi.run();
                                posDpadBtn.requestFocus();
                            }
                            return true;
                        }
                        return true;
                    };

            posDpadBtn.setOnKeyListener(posModeKeyHandler);
            dlg.setOnKeyListener(
                    (d, keyCode, event) -> posModeKeyHandler.onKey(posDpadBtn, keyCode, event));
            LinearLayout.LayoutParams posBtnLp = new LinearLayout.LayoutParams(0, a.dp(40), 1f);
            posBtnLp.rightMargin = a.dp(8);
            posRow.addView(posDpadBtn, posBtnLp);

            Button upBtn =
                    a.button(
                            "▲ 上移",
                            "tv-sub-up",
                            () -> {
                                int bt =
                                        Prefs.clampSubtitleBottom(
                                                a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24) + 6);
                                a.prefs.edit().putInt(Prefs.SUBTITLE_BOTTOM, bt).apply();
                                syncState.run();
                            });
            upBtn.setId(View.generateViewId());
            upBtn.setNextFocusUpId(upBtn.getId());
            upBtn.setTextSize(12.5f);
            upBtn.setMinHeight(a.dp(40));
            upBtn.setMinimumHeight(a.dp(40));
            LinearLayout.LayoutParams upLp = new LinearLayout.LayoutParams(-2, a.dp(40));
            upLp.rightMargin = a.dp(6);
            posRow.addView(upBtn, upLp);

            Button downBtn =
                    a.button(
                            "▼ 下移",
                            "tv-sub-down",
                            () -> {
                                int bt =
                                        Prefs.clampSubtitleBottom(
                                                a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24) - 6);
                                a.prefs.edit().putInt(Prefs.SUBTITLE_BOTTOM, bt).apply();
                                syncState.run();
                            });
            downBtn.setId(View.generateViewId());
            downBtn.setNextFocusUpId(downBtn.getId());
            downBtn.setNextFocusRightId(downBtn.getId());
            downBtn.setTextSize(12.5f);
            downBtn.setMinHeight(a.dp(40));
            downBtn.setMinimumHeight(a.dp(40));
            posRow.addView(downBtn, new LinearLayout.LayoutParams(-2, a.dp(40)));
            tvPanel.addView(posRow, new LinearLayout.LayoutParams(-1, -2));

            a.gap(tvPanel, 8);

            // 2. Dedicated SeekBar Slider for Subtitle Size (字幕大小)
            LinearLayout sizeRow = a.row();
            sizeRow.setGravity(Gravity.CENTER_VERTICAL);
            sizeRow.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
            sizeRow.setBackground(a.bg(0x1fffffff, 12));
            TextView sizeLbl = a.text("字幕大小（◀ ▶ 滑动）", 13.5f, MainActivity.WHITE);
            sizeRow.addView(sizeLbl, new LinearLayout.LayoutParams(a.dp(150), -2));
            final SeekBar tvSizeBar = new SeekBar(a);
            tvSizeBar.setMax(40);
            tvSizeBar.setKeyProgressIncrement(2);
            UiCompat.setDefaultFocusHighlightEnabled(tvSizeBar, false);
            tvSizeBar.setFocusable(true);
            UiCompat.tintSeekBar(tvSizeBar, 0xff34d399, Color.WHITE);
            tvSizeBar.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    sizeRow,
                                    f,
                                    0x1fffffff,
                                    0x3834d399,
                                    12,
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    false,
                                    1.01f));
            sizeBarRef[0] = tvSizeBar;
            sizeRow.addView(tvSizeBar, new LinearLayout.LayoutParams(0, -2, 1f));
            TextView tvSizeVal = a.text("45", 13.5f, 0xff34d399);
            tvSizeVal.setGravity(Gravity.RIGHT);
            sizeValRef[0] = tvSizeVal;
            sizeRow.addView(tvSizeVal, new LinearLayout.LayoutParams(a.dp(40), -2));
            tvPanel.addView(sizeRow, new LinearLayout.LayoutParams(-1, -2));

            a.gap(tvPanel, 8);

            // 3. Dedicated SeekBar Slider for Subtitle Weight / Thickness (字体粗细)
            LinearLayout weightRow = a.row();
            weightRow.setGravity(Gravity.CENTER_VERTICAL);
            weightRow.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
            weightRow.setBackground(a.bg(0x1fffffff, 12));
            TextView weightLbl = a.text("字体粗细（◀ ▶ 滑动）", 13.5f, MainActivity.WHITE);
            weightRow.addView(weightLbl, new LinearLayout.LayoutParams(a.dp(150), -2));
            final SeekBar tvWeightBar = new SeekBar(a);
            tvWeightBar.setMax(100);
            tvWeightBar.setKeyProgressIncrement(5);
            UiCompat.setDefaultFocusHighlightEnabled(tvWeightBar, false);
            tvWeightBar.setFocusable(true);
            UiCompat.tintSeekBar(tvWeightBar, 0xff5ac8fa, Color.WHITE);
            tvWeightBar.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    weightRow,
                                    f,
                                    0x1fffffff,
                                    0x385ac8fa,
                                    12,
                                    MainActivity.WHITE,
                                    MainActivity.WHITE,
                                    false,
                                    1.01f));
            weightBarRef[0] = tvWeightBar;
            weightRow.addView(tvWeightBar, new LinearLayout.LayoutParams(0, -2, 1f));
            TextView tvWeightVal = a.text("50", 13.5f, 0xff5ac8fa);
            tvWeightVal.setGravity(Gravity.RIGHT);
            weightValRef[0] = tvWeightVal;
            weightRow.addView(tvWeightVal, new LinearLayout.LayoutParams(a.dp(40), -2));
            tvPanel.addView(weightRow, new LinearLayout.LayoutParams(-1, -2));

            tvSizeBar.setOnSeekBarChangeListener(
                    new SeekBar.OnSeekBarChangeListener() {
                        @Override
                        public void onProgressChanged(SeekBar b, int p, boolean fromUser) {
                            if (internalSync[0]) return;
                            a.prefs.edit().putInt(Prefs.SUBTITLE_SIZE, 25 + p).apply();
                            syncState.run();
                        }

                        @Override
                        public void onStartTrackingTouch(SeekBar b) {}

                        @Override
                        public void onStopTrackingTouch(SeekBar b) {}
                    });
            tvWeightBar.setOnSeekBarChangeListener(
                    new SeekBar.OnSeekBarChangeListener() {
                        @Override
                        public void onProgressChanged(SeekBar b, int p, boolean fromUser) {
                            if (internalSync[0]) return;
                            a.prefs.edit().putInt(Prefs.SUBTITLE_WEIGHT, p).apply();
                            syncState.run();
                        }

                        @Override
                        public void onStartTrackingTouch(SeekBar b) {}

                        @Override
                        public void onStopTrackingTouch(SeekBar b) {}
                    });

            a.gap(tvPanel, 8);

            // 4. Drawer Menu Button for Subtitle Color & Style + Reset & Done Buttons
            LinearLayout bottomRow = a.row();
            bottomRow.setGravity(Gravity.CENTER_VERTICAL);
            Button styleDrawerBtn =
                    a.button(
                            "字幕颜色与样式",
                            "tv-sub-style-drawer",
                            () -> {
                                int curSt =
                                        Prefs.clampSubtitleStyle(
                                                a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                                showSubtitleStyleDrawer(
                                        a,
                                        curSt,
                                        idx -> {
                                            a.prefs
                                                    .edit()
                                                    .putInt(Prefs.SUBTITLE_STYLE, idx)
                                                    .apply();
                                            syncState.run();
                                        });
                            });
            styleDrawerBtn.setId(View.generateViewId());
            styleDrawerBtn.setNextFocusDownId(styleDrawerBtn.getId());
            styleDrawerBtn.setNextFocusLeftId(styleDrawerBtn.getId());
            styleDrawerBtn.setTextSize(13f);
            styleDrawerBtn.setMinHeight(a.dp(42));
            styleDrawerBtn.setMinimumHeight(a.dp(42));
            styleBtnTextRef[0] = styleDrawerBtn;
            LinearLayout.LayoutParams styleLp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
            styleLp.rightMargin = a.dp(8);
            bottomRow.addView(styleDrawerBtn, styleLp);

            Button resetBtn = a.button("恢复默认", "tv-sub-reset", resetDefaults);
            resetBtn.setId(View.generateViewId());
            resetBtn.setNextFocusDownId(resetBtn.getId());
            resetBtn.setTextSize(13f);
            resetBtn.setMinHeight(a.dp(42));
            resetBtn.setMinimumHeight(a.dp(42));
            LinearLayout.LayoutParams resetLp = new LinearLayout.LayoutParams(-2, a.dp(42));
            resetLp.rightMargin = a.dp(8);
            bottomRow.addView(resetBtn, resetLp);

            Button doneBtn = a.button("完成", "tv-sub-done", dlg::dismiss);
            doneBtn.setId(View.generateViewId());
            doneBtn.setNextFocusDownId(doneBtn.getId());
            doneBtn.setNextFocusRightId(doneBtn.getId());
            doneBtn.setTextSize(13f);
            doneBtn.setMinHeight(a.dp(42));
            doneBtn.setMinimumHeight(a.dp(42));
            bottomRow.addView(doneBtn, new LinearLayout.LayoutParams(-2, a.dp(42)));
            tvPanel.addView(bottomRow, new LinearLayout.LayoutParams(-1, -2));

            FrameLayout.LayoutParams panelLp =
                    new FrameLayout.LayoutParams(
                            Math.min(a.windowWidth() - a.dp(48), a.dp(660)),
                            -2,
                            Gravity.TOP | Gravity.CENTER_HORIZONTAL);
            panelLp.topMargin = a.dp(24);
            fullRoot.addView(tvPanel, panelLp);
        }

        syncState.run();

        dlg.setOnDismissListener(
                d -> {
                    if (a.scroll != null && liveSub == null) {
                        a.scroll.setDescendantFocusability(savedDescendantFocus);
                        a.scroll.scrollTo(0, savedScrollY);
                    }
                    if (a.current != null && liveSub == null) {
                        if (savedFocusTag != null) a.current.focus = savedFocusTag;
                        a.current.scroll = savedScrollY;
                    }
                    if (liveSub != null) {
                        liveSub.setPreviewActive(false);
                        liveSub.setVisibility(View.VISIBLE);
                    }
                    if (onChanged != null) onChanged.run();
                });
        dlg.setContentView(fullRoot, new ViewGroup.LayoutParams(a.windowWidth(), a.windowHeight()));
        dlg.show();
        if (dlg.getWindow() != null) {
            dlg.getWindow()
                    .setLayout(
                            WindowManager.LayoutParams.MATCH_PARENT,
                            WindowManager.LayoutParams.MATCH_PARENT);
        }
        if (initialTvFocusRef[0] != null) {
            initialTvFocusRef[0].requestFocus();
            initialTvFocusRef[0].post(initialTvFocusRef[0]::requestFocus);
        }
    }

    void tracksCombinedMenu() {
        tracksCombinedMenu(0, null);
    }

    void tracksCombinedMenu(int initialFocusIndex, Runnable onCancelBack) {
        List<String> rawSubs =
                (a.player != null && a.prepared)
                        ? a.player.trackLabels(3)
                        : Collections.emptyList();
        List<String> rawAudios =
                (a.player != null && a.prepared)
                        ? a.player.trackLabels(1)
                        : Collections.emptyList();

        List<PlayerBubble.Row> rows = new ArrayList<>();
        final List<String> subCleanLabels = new ArrayList<>();
        int nextIdx = 0;

        // Section 1: Subtitles
        rows.add(PlayerBubble.Row.header("字幕（本剧记忆）"));
        boolean anySubChecked = false;
        for (String raw : rawSubs) {
            if (raw != null && raw.startsWith("✓")) {
                anySubChecked = true;
                break;
            }
        }
        final int subOffIdx = nextIdx++;
        rows.add(PlayerBubble.Row.item(subOffIdx, "关闭字幕", !anySubChecked));
        final int subTrackStart = nextIdx;
        int activeSubIdx = subOffIdx;
        for (int k = 0; k < rawSubs.size(); k++) {
            String raw = rawSubs.get(k);
            boolean checked = raw != null && raw.startsWith("✓");
            String clean = raw == null ? "" : raw.replaceFirst("^✓\\s*", "");
            subCleanLabels.add(clean);
            if (checked) activeSubIdx = nextIdx;
            rows.add(PlayerBubble.Row.item(nextIdx++, clean, checked));
        }
        final int subTrackEnd = nextIdx;
        final int subAdjustIdx = nextIdx++;
        rows.add(PlayerBubble.Row.item(subAdjustIdx, "字幕大小与位置（播放中预览 · 以后播放沿用）", false));
        final int subStyleIdx = nextIdx++;
        rows.add(
                PlayerBubble.Row.item(
                        subStyleIdx, "字幕样式 · " + subtitleStyleLabel() + "（以后播放沿用）", false));
        final int subImportIdx = nextIdx++;
        rows.add(PlayerBubble.Row.item(subImportIdx, "导入字幕文件…（本集）", false));

        // Section 2: Audio tracks
        rows.add(PlayerBubble.Row.header("音轨（本剧记忆）"));
        final List<String> audioCleanLabels = new ArrayList<>();
        final int audioAutoIdx;
        final int audioTrackStart;
        final int audioTrackEnd;
        final boolean singleAudioOnly = rawAudios.size() == 1;
        if (rawAudios.isEmpty()) {
            audioAutoIdx = -1;
            audioTrackStart = nextIdx;
            audioTrackEnd = nextIdx;
            rows.add(
                    PlayerBubble.Row.item(
                            nextIdx++,
                            (a.player != null && a.prepared) ? "当前音轨 · 默认音轨" : "等待视频就绪后读取音轨",
                            true));
        } else if (singleAudioOnly) {
            audioAutoIdx = -1;
            String clean =
                    rawAudios.get(0) == null ? "默认音轨" : rawAudios.get(0).replaceFirst("^✓\\s*", "");
            audioCleanLabels.add(clean);
            audioTrackStart = nextIdx;
            rows.add(PlayerBubble.Row.item(nextIdx++, "当前音轨 · " + clean, true));
            audioTrackEnd = nextIdx;
        } else {
            boolean anyAudioChecked = false;
            for (String raw : rawAudios) {
                if (raw != null && raw.startsWith("✓")) {
                    anyAudioChecked = true;
                    break;
                }
            }
            audioAutoIdx = nextIdx++;
            rows.add(PlayerBubble.Row.item(audioAutoIdx, "自动选择默认音轨", !anyAudioChecked));
            audioTrackStart = nextIdx;
            for (int k = 0; k < rawAudios.size(); k++) {
                String raw = rawAudios.get(k);
                boolean checked = raw != null && raw.startsWith("✓");
                String clean = raw == null ? "" : raw.replaceFirst("^✓\\s*", "");
                audioCleanLabels.add(clean);
                rows.add(PlayerBubble.Row.item(nextIdx++, clean, checked));
            }
            audioTrackEnd = nextIdx;
        }
        int audioPref = a.prefs.getInt(Prefs.AUDIO_TRACK_PREFERENCE, 0);
        String audioPrefText =
                audioPref == SubtitlePreferenceStore.AUDIO_PREF_CHINESE
                        ? "优先中文 / 国语"
                        : audioPref == SubtitlePreferenceStore.AUDIO_PREF_ORIGINAL
                                ? "优先原声 / 默认"
                                : "智能默认";
        final int audioPrefIdx = nextIdx++;
        rows.add(
                PlayerBubble.Row.item(
                        audioPrefIdx, "自动选轨策略 · " + audioPrefText + "（以后播放沿用）", false));

        int focusTarget = initialFocusIndex > 0 ? initialFocusIndex : activeSubIdx;
        showStructuredBubble(
                "字幕 / 音轨",
                "",
                rows,
                focusTarget,
                i -> {
                    if (i == subOffIdx) {
                        selectAndRememberSubtitle(-2, null);
                    } else if (i >= subTrackStart && i < subTrackEnd) {
                        int k = i - subTrackStart;
                        selectAndRememberSubtitle(k, subCleanLabels.get(k));
                    } else if (i == subAdjustIdx) {
                        showSubtitleAdjuster(a, subtitle, this::applySubtitleStyle);
                    } else if (i == subStyleIdx) {
                        int cur = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                        choose(
                                "字幕样式（以后播放沿用）",
                                SubtitleOverlayView.STYLE_LABELS,
                                cur,
                                sIdx -> {
                                    a.prefs.edit().putInt(Prefs.SUBTITLE_STYLE, sIdx).apply();
                                    applySubtitleStyle();
                                },
                                () -> tracksCombinedMenu(subStyleIdx, onCancelBack));
                    } else if (i == subImportIdx) {
                        a.pickSubtitle();
                    } else if (audioAutoIdx >= 0 && i == audioAutoIdx) {
                        selectAndRememberAudio(-1, null);
                    } else if (i >= audioTrackStart && i < audioTrackEnd) {
                        if (!singleAudioOnly) {
                            int k = i - audioTrackStart;
                            selectAndRememberAudio(k, audioCleanLabels.get(k));
                        }
                    } else if (i == audioPrefIdx) {
                        int nextPref = (audioPref + 1) % 3;
                        a.prefs.edit().putInt(Prefs.AUDIO_TRACK_PREFERENCE, nextPref).apply();
                        String nextName =
                                nextPref == SubtitlePreferenceStore.AUDIO_PREF_CHINESE
                                        ? "优先中文 / 国语"
                                        : nextPref == SubtitlePreferenceStore.AUDIO_PREF_ORIGINAL
                                                ? "优先原声 / 默认"
                                                : "智能默认";
                        a.toast("自动选轨策略已切换为：" + nextName + "（以后播放沿用）");
                        audioPrefAppliedForEpisode = false;
                        applyPreferredAudioIfNeeded();
                    }
                },
                "",
                true,
                onCancelBack);
    }

    void subtitleQuickMenu() {
        List<String> rawTracks =
                (a.player != null && a.prepared)
                        ? a.player.trackLabels(3)
                        : Collections.emptyList();
        List<String> labels = new ArrayList<>();
        labels.add("关闭字幕");
        int selectedIdx = 0;
        for (int k = 0; k < rawTracks.size(); k++) {
            String raw = rawTracks.get(k);
            if (raw != null && raw.startsWith("✓")) {
                selectedIdx = 1 + k;
                raw = raw.replaceFirst("^✓\\s*", "");
            }
            labels.add(raw);
        }
        final int trackEnd = labels.size();
        labels.add("字幕大小与位置（播放中预览 · 以后播放沿用）");
        labels.add("字幕颜色与样式 · " + subtitleStyleLabel() + "（以后播放沿用）");
        labels.add("导入字幕文件…（本集）");
        choose(
                "字幕（本剧记忆）",
                labels.toArray(new String[0]),
                selectedIdx,
                i -> {
                    if (i == 0) {
                        selectAndRememberSubtitle(-2, null);
                    } else if (i < trackEnd) {
                        selectAndRememberSubtitle(i - 1, labels.get(i));
                    } else if (i == trackEnd) {
                        showSubtitleAdjuster(a, subtitle, this::applySubtitleStyle);
                    } else if (i == trackEnd + 1) {
                        int cur = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                        choose(
                                "字幕颜色与样式（以后播放沿用）",
                                SubtitleOverlayView.STYLE_LABELS,
                                cur,
                                sIdx -> {
                                    a.prefs.edit().putInt(Prefs.SUBTITLE_STYLE, sIdx).apply();
                                    applySubtitleStyle();
                                },
                                this::subtitleQuickMenu);
                    } else {
                        a.pickSubtitle();
                    }
                });
    }

    void tracks(int type) {
        if (type == 3) {
            subtitleQuickMenu();
            return;
        }
        if (a.player == null || !a.prepared) {
            message("请等待视频开始播放。");
            return;
        }
        List<String> tracks = a.player.trackLabels(type);
        List<String> labels = new ArrayList<>();
        int selectedIdx = 0;
        final boolean singleAudioOnly = type == 1 && tracks.size() == 1;
        if (singleAudioOnly) {
            String clean =
                    tracks.get(0) == null ? "默认音轨" : tracks.get(0).replaceFirst("^✓\\s*", "");
            labels.add("当前音轨 · " + clean);
            selectedIdx = 0;
        } else {
            labels.add("自动选择默认音轨");
            for (int k = 0; k < tracks.size(); k++) {
                String raw = tracks.get(k);
                if (raw != null && raw.startsWith("✓")) {
                    selectedIdx = 1 + k;
                    raw = raw.replaceFirst("^✓\\s*", "");
                }
                labels.add(raw);
            }
        }
        final int trackOptionCount = labels.size();
        int audioPref = a.prefs.getInt(Prefs.AUDIO_TRACK_PREFERENCE, 0);
        String audioPrefText =
                audioPref == SubtitlePreferenceStore.AUDIO_PREF_CHINESE
                        ? "优先中文 / 国语"
                        : audioPref == SubtitlePreferenceStore.AUDIO_PREF_ORIGINAL
                                ? "优先原声 / 默认"
                                : "智能默认";
        labels.add("自动选轨策略：" + audioPrefText + "（以后播放沿用）");
        boolean swAudio = a.prefs.getBoolean(Prefs.SOFTWARE_AUDIO, false);
        labels.add("兼容音频解码：" + (swAudio ? "已开启" : "关闭") + "（以后播放沿用）");
        labels.add("音效模式 · 设置（以后播放沿用）");
        choose(
                "音轨（本剧记忆）",
                labels.toArray(new String[0]),
                selectedIdx,
                i -> {
                    if (i < trackOptionCount) {
                        if (singleAudioOnly) return;
                        if (type == 1) {
                            if (i == 0) {
                                selectAndRememberAudio(-1, null);
                            } else {
                                selectAndRememberAudio(i - 1, labels.get(i));
                            }
                        } else if (a.player != null) {
                            a.player.selectTrack(type, i == 0 ? -1 : i - 1);
                        }
                    } else if (i == trackOptionCount) {
                        int nextPref = (audioPref + 1) % 3;
                        a.prefs.edit().putInt(Prefs.AUDIO_TRACK_PREFERENCE, nextPref).apply();
                        String nextName =
                                nextPref == SubtitlePreferenceStore.AUDIO_PREF_CHINESE
                                        ? "优先中文 / 国语"
                                        : nextPref == SubtitlePreferenceStore.AUDIO_PREF_ORIGINAL
                                                ? "优先原声 / 默认"
                                                : "智能默认";
                        a.toast("自动选轨策略已切换为：" + nextName);
                        audioPrefAppliedForEpisode = false;
                        applyPreferredAudioIfNeeded();
                    } else if (i == trackOptionCount + 1) {
                        a.prefs.edit().putBoolean(Prefs.SOFTWARE_AUDIO, !swAudio).apply();
                        reload(true);
                    } else {
                        soundEffect(() -> tracks(type));
                    }
                });
    }

    static int getVideoIntro(MainActivity a, Cms.Site site, Cms.Video video) {
        if (a == null) return 0;
        String siteKey = site == null ? "" : site.key;
        String videoId = VideoSkipStore.videoKeyFrom(video, a.activeEpisode);
        if (a.privateMode) {
            return VideoSkipStore.getPrivateSkip(siteKey, videoId, true);
        }
        if (a.prefs == null) return 0;
        return VideoSkipStore.readIntro(
                a.prefs.getString(Prefs.VIDEO_SKIP_RECORDS, "[]"), siteKey, videoId);
    }

    static int getVideoOutro(MainActivity a, Cms.Site site, Cms.Video video) {
        if (a == null) return 0;
        String siteKey = site == null ? "" : site.key;
        String videoId = VideoSkipStore.videoKeyFrom(video, a.activeEpisode);
        if (a.privateMode) {
            return VideoSkipStore.getPrivateSkip(siteKey, videoId, false);
        }
        if (a.prefs == null) return 0;
        return VideoSkipStore.readOutro(
                a.prefs.getString(Prefs.VIDEO_SKIP_RECORDS, "[]"), siteKey, videoId);
    }

    static void setVideoSkip(
            MainActivity a, Cms.Site site, Cms.Video video, boolean intro, int seconds) {
        if (a == null) return;
        if (a.isTvDevice() && !a.privateMode && VideoMarkerRepository.clearing()) {
            a.toast("正在保存清除结果，请稍候");
            return;
        }
        String siteKey = site == null ? "" : site.key;
        String videoId = VideoSkipStore.videoKeyFrom(video, a.activeEpisode);
        if (a.privateMode) {
            VideoSkipStore.setPrivateSkip(siteKey, videoId, intro, seconds);
            return;
        }
        if (a.prefs == null) return;
        String updated =
                VideoSkipStore.writeSkip(
                        a.prefs.getString(Prefs.VIDEO_SKIP_RECORDS, "[]"),
                        siteKey,
                        videoId,
                        intro,
                        seconds,
                        System.currentTimeMillis());
        a.prefs.edit().putString(Prefs.VIDEO_SKIP_RECORDS, updated).apply();
    }

    static int countVideoSkipRecords(MainActivity a) {
        if (a == null) return 0;
        if (a.privateMode) return VideoSkipStore.countPrivateRecords();
        if (a.prefs == null) return 0;
        return VideoSkipStore.countRecords(a.prefs.getString(Prefs.VIDEO_SKIP_RECORDS, "[]"));
    }

    static void clearVideoSkipRecords(MainActivity a, Runnable onChanged) {
        if (a == null || a.switchingPrivacy || a.isDestroyed()) return;
        if (!a.isTvDevice()) {
            if (a.privateMode) VideoSkipStore.clearPrivateRecords();
            else if (a.prefs != null) a.prefs.edit().remove(Prefs.VIDEO_SKIP_RECORDS).apply();
            else return;
            a.toast("已清除全部影片的片头片尾记录");
            if (onChanged != null) onChanged.run();
            return;
        }
        if (VideoMarkerRepository.clearing()) {
            a.toast("正在保存清除结果，请稍候");
            return;
        }
        if (a.markerHost != null) a.markerHost.abort();
        if (a.playbackControls != null) a.playbackControls.resetMarkers();
        if (a.privateMode) {
            VideoMarkerRepository.clearPrivate();
            VideoSkipStore.clearPrivateRecords();
            a.toast("已清除当前空间的片头片尾记录");
            if (onChanged != null) onChanged.run();
            return;
        }
        final android.content.SharedPreferences capturedPrefs = a.prefs;
        if (capturedPrefs == null) return;
        final int generation = a.generation;
        final TvSearchContext context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final MarkerClearTask.Write clear =
                VideoMarkerRepository.preparePublicClear(a.getFilesDir());
        if (clear == null) return;
        a.toast("正在清除当前空间的记录");
        try {
            MarkerClearTask.submit(
                    clear,
                    () -> MarkerLegacyCommit.clear(capturedPrefs),
                    (newer, failure) -> {
                        // Release even if the old Activity is destroyed and its UI queue is
                        // discarded.
                        VideoMarkerRepository.finishClear();
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()
                                            || a.isDestroyed()
                                            || a.switchingPrivacy
                                            || a.generation != generation
                                            || a.prefs != capturedPrefs
                                            || !context.matches(
                                                    a.config, a.privateMode, a.engineEpoch)) return;
                                    if (a.playbackControls != null)
                                        a.playbackControls.resetMarkers();
                                    if (failure != null) {
                                        a.notice(
                                                newer
                                                        ? "新标记已清空，旧记录写盘未确认，请重新检查"
                                                        : "新标记清除未确认，旧记录保留：" + failure.getMessage());
                                        return;
                                    }
                                    a.toast("已清除当前空间的片头片尾记录");
                                    if (onChanged != null) onChanged.run();
                                });
                    });
        } catch (RuntimeException rejected) {
            VideoMarkerRepository.finishClear();
            a.notice("清除任务未启动，原记录保留");
        }
    }

    void skip(boolean intro) {
        if (a.isTvDevice() && !a.isLive() && !a.isCast()) {
            long now = android.os.SystemClock.uptimeMillis();
            int decision =
                    decideSkipTap(
                            pendingSkipTapActive,
                            pendingSkipTapIntro,
                            pendingSkipTapAtMs,
                            intro,
                            now);
            if (decision == SKIP_TAP_TRIGGER_DOUBLE) {
                cancelPendingSkipTap();
                openSkipEditDialog(intro);
                return;
            }
            if (decision == SKIP_TAP_FLUSH_OTHER_AND_SCHEDULE) {
                boolean prevIntro = pendingSkipTapIntro;
                cancelPendingSkipTap();
                applyDirectSkipCurrentTime(prevIntro);
            }
            pendingSkipTapActive = true;
            pendingSkipTapIntro = intro;
            pendingSkipTapAtMs = now;
            final boolean targetIntro = intro;
            pendingSkipTapRunnable =
                    () -> {
                        pendingSkipTapRunnable = null;
                        pendingSkipTapActive = false;
                        if (a.isFinishing() || a.playbackControls != this) return;
                        applyDirectSkipCurrentTime(targetIntro);
                    };
            a.ui.postDelayed(pendingSkipTapRunnable, SKIP_DOUBLE_CLICK_MS);
            return;
        }
        openSkipEditDialog(intro);
    }

    private void applyDirectSkipCurrentTime(boolean intro) {
        if (site == null || video == null || a.player == null || !a.prepared) {
            a.toast("播放尚未就绪，双击" + (intro ? "片头" : "片尾") + "可手动编辑");
            return;
        }
        int curPos = a.player.getCurrentPosition();
        int curDur = a.player.getDuration();
        if (curPos <= 0) {
            a.toast("当前播放时间无效，双击" + (intro ? "片头" : "片尾") + "可手动编辑");
            return;
        }
        int sec = captureSkipSecondsFromPlayback(intro, curPos, curDur);
        if (sec < 0) {
            a.toast("当前距片尾超过 20 分钟，请临近片尾再单击，或双击手动编辑");
            return;
        }
        setVideoSkip(a, site, video, intro, sec);
        if (a.isTvDevice() && !a.isLive() && !a.isCast()) {
            markers().inheritLegacy(intro);
        }
        refreshMarkerPlaybackMode();
        updateLabels();
        if (intro) {
            a.toast("已设本剧片头为 " + PlaybackController.formatTime(sec * 1000) + "（后续剧集自动延续，双击可编辑）");
        } else {
            a.toast("已设本剧片尾为结束前 " + PlaybackController.formatTime(sec * 1000) + "（后续剧集自动延续，双击可编辑）");
        }
    }

    private void openSkipEditDialog(boolean intro) {
        int curPos = a.player != null && a.prepared ? a.player.getCurrentPosition() : 0;
        int curDur = a.player != null && a.prepared ? a.player.getDuration() : 0;
        showSkipAdjuster(
                a,
                site,
                video,
                intro,
                curPos,
                curDur,
                () -> {
                    if (a.isTvDevice() && !a.isLive() && !a.isCast()) {
                        markers().inheritLegacy(intro);
                    }
                    refreshMarkerPlaybackMode();
                    updateLabels();
                });
    }

    static void showSkipAdjuster(
            MainActivity a,
            boolean intro,
            int currentPlayerPosMs,
            int currentPlayerDurMs,
            Runnable onChanged) {
        showVideoSkipRecordsDialog(a, onChanged);
    }

    static void showVideoSkipRecordsDialog(MainActivity a, Runnable onChanged) {
        if (a == null) return;
        int count = countVideoSkipRecords(a);
        int v2Count = a.isTvDevice() ? VideoMarkerRepository.count(a) : 0;
        AppDialog.Builder b =
                new AppDialog.Builder(a)
                        .setTitle("片头片尾独立记录")
                        .setMessage(
                                a.isTvDevice()
                                        ? "旧记录为片头持续秒数/片尾剩余秒数；新标记为本集本线路绝对毫秒节点，互不改写。\n旧记录："
                                                + count
                                                + "，新标记："
                                                + (v2Count < 0 ? "读取失败，原文件保留" : v2Count)
                                                + "。\n清空将删除本空间两代记录及当前会话标记；不影响另一空间或远端。"
                                        : "每部影片在播放页面点击「片头」或「片尾」按钮时，会优先默认记录当前播放时间，并支持按秒微调。\n\n"
                                                + "记录仅对当前影片独立生效，不会全局同步影响其他影视。\n"
                                                + "当前本机已保存："
                                                + count
                                                + " 部影片记录。")
                        .setNegativeButton("关闭", null);
        if (count > 0 || a.isTvDevice()) {
            b.setPositiveButton(
                    "清空全部记录",
                    (d, w) -> {
                        clearVideoSkipRecords(a, onChanged);
                    });
        }
        b.show();
    }

    static void showSkipAdjuster(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            boolean intro,
            int currentPlayerPosMs,
            int currentPlayerDurMs,
            Runnable onChanged) {
        if (site == null || video == null) {
            showVideoSkipRecordsDialog(a, onChanged);
            return;
        }
        final int savedSec = intro ? getVideoIntro(a, site, video) : getVideoOutro(a, site, video);
        final int captureSec =
                captureSkipSecondsFromPlayback(intro, currentPlayerPosMs, currentPlayerDurMs);
        final boolean hasCapture = captureSec > 0;
        final boolean tv = a.isTvDevice();
        final int cardWidth =
                resolveSkipDialogWidthPx(a.windowWidth(), a.dp(tv ? 452 : 368), a.dp(tv ? 96 : 36));

        final Dialog dlg = new Dialog(a);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        final PlaybackControls owner = a.playbackControls;
        if (owner != null) {
            if (owner.activeDialog != null) owner.activeDialog.dismiss();
            owner.activeDialog = dlg;
            owner.dialogOpen = true;
            owner.hideButtonTooltip(true);
            if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
        }

        LinearLayout card = a.vertical();
        card.setTag("skip-adjuster-card");
        card.setClipChildren(true);
        card.setClipToPadding(true);
        card.setPadding(a.dp(20), a.dp(16), a.dp(20), a.dp(16));
        android.graphics.drawable.GradientDrawable bg =
                new android.graphics.drawable.GradientDrawable(
                        android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xf723252d, 0xfa15161c});
        bg.setCornerRadius(a.dp(20));
        bg.setStroke(Math.max(1, a.dp(0.9f)), 0x36ffffff);
        card.setBackground(bg);

        // Header row: compact title + live time readout
        LinearLayout headRow = a.row();
        headRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text(intro ? "片头时间编辑" : "片尾时间编辑", 16f, MainActivity.WHITE);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        title.setSingleLine(true);
        headRow.addView(title);
        TextView scope = a.text("  · 本剧通用", 11.5f, MainActivity.MUTED);
        scope.setSingleLine(true);
        headRow.addView(scope, new LinearLayout.LayoutParams(0, -2, 1f));

        final TextView valueLabel = a.text("", 15.5f, 0xff34d399);
        valueLabel.setTypeface(null, android.graphics.Typeface.BOLD);
        valueLabel.setSingleLine(true);
        valueLabel.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        headRow.addView(valueLabel, new LinearLayout.LayoutParams(-2, -2));
        card.addView(headRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(card, 4);

        TextView sub =
                a.text(
                        tv
                                ? (intro
                                        ? "本剧各集自动延续 · 单击片头键设为当前时间，双击打开此面板微调"
                                        : "本剧各集自动延续 · 单击片尾键设为当前位置，双击打开此面板微调")
                                : "本剧各集自动延续，不全局影响其他影视",
                        11.5f,
                        0xa8ebebf5);
        sub.setSingleLine(true);
        sub.setEllipsize(TextUtils.TruncateAt.END);
        card.addView(sub, new LinearLayout.LayoutParams(-1, -2));
        a.gap(card, 12);

        // Compact SeekBar row with min/max labels
        LinearLayout barRow = a.row();
        barRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView minTv = a.text("00:00", 11f, MainActivity.MUTED);
        minTv.setSingleLine(true);
        barRow.addView(minTv, new LinearLayout.LayoutParams(-2, -2));

        final SeekBar bar = new SeekBar(a);
        bar.setId(View.generateViewId());
        bar.setMax(VideoSkipStore.MAX_SKIP_SECONDS);
        bar.setKeyProgressIncrement(5);
        UiCompat.tintSeekBar(bar, 0xff34d399, Color.WHITE);
        UiCompat.setDefaultFocusHighlightEnabled(bar, false);
        bar.setProgress(savedSec);
        LinearLayout.LayoutParams barLp = new LinearLayout.LayoutParams(0, a.dp(30), 1f);
        barLp.leftMargin = a.dp(8);
        barLp.rightMargin = a.dp(8);
        barRow.addView(bar, barLp);

        TextView maxTv =
                a.text(
                        PlaybackController.formatTime(VideoSkipStore.MAX_SKIP_SECONDS * 1000),
                        11f,
                        MainActivity.MUTED);
        maxTv.setSingleLine(true);
        barRow.addView(maxTv, new LinearLayout.LayoutParams(-2, -2));
        card.addView(barRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(card, 12);

        final int[] currentSecRef = {savedSec};
        final boolean[] mutatedRef = {false};
        final PlayerBubble.IntAction renderSec =
                sec -> {
                    int clamped = VideoSkipStore.clampSkipSeconds(sec);
                    currentSecRef[0] = clamped;
                    if (bar.getProgress() != clamped) bar.setProgress(clamped);
                    if (clamped <= 0) {
                        valueLabel.setText("未设置");
                        valueLabel.setTextColor(MainActivity.MUTED);
                    } else {
                        String fmt = PlaybackController.formatTime(clamped * 1000);
                        valueLabel.setText(intro ? fmt : "结束前 " + fmt);
                        valueLabel.setTextColor(0xff34d399);
                    }
                };
        final PlayerBubble.IntAction commitSec =
                sec -> {
                    int clamped = VideoSkipStore.clampSkipSeconds(sec);
                    mutatedRef[0] = true;
                    setVideoSkip(a, site, video, intro, clamped);
                    if (a.isTvDevice() && owner != null && !a.isLive() && !a.isCast()) {
                        owner.markers().inheritLegacy(intro);
                    }
                    if (!intro && a.player != null && !"live".equals(site.key)) {
                        if (a.isTvDevice() && owner != null) owner.refreshMarkerPlaybackMode();
                        else
                            a.player.setRepeatOne(
                                    shouldEnableNativeRepeatOne(
                                            a.prefs.getInt(Prefs.REPEAT_MODE, 0),
                                            clamped == 0));
                    }
                    renderSec.accept(clamped);
                };
        renderSec.accept(savedSec);

        // Row 1: 6 equal-weight step buttons (mathematically guaranteed zero overflow)
        final int[] deltas = {-15, -5, -1, 1, 5, 15};
        final String[] stepLabels = {"-15s", "-5s", "-1s", "+1s", "+5s", "+15s"};
        LinearLayout stepRow = a.row();
        stepRow.setTag("skip-step-row");
        stepRow.setWeightSum(deltas.length);
        stepRow.setGravity(Gravity.CENTER_VERTICAL);
        final TextView[] stepBtns = new TextView[deltas.length];
        for (int i = 0; i < deltas.length; i++) {
            final int delta = deltas[i];
            final TextView b = a.text(stepLabels[i], 12.5f, MainActivity.WHITE);
            b.setId(View.generateViewId());
            b.setTag("skip-step:" + delta);
            b.setTypeface(null, android.graphics.Typeface.BOLD);
            b.setGravity(Gravity.CENTER);
            b.setSingleLine(true);
            b.setEllipsize(TextUtils.TruncateAt.END);
            b.setMinWidth(0);
            b.setMinimumWidth(0);
            b.setPadding(0, 0, 0, 0);
            b.setFocusable(true);
            b.setClickable(true);
            UiCompat.setDefaultFocusHighlightEnabled(b, false);
            styleSkipDialogPill(a, b, false, 0x22ffffff, MainActivity.WHITE);
            b.setOnFocusChangeListener(
                    (v, f) -> styleSkipDialogPill(a, b, f, 0x22ffffff, MainActivity.WHITE));
            b.setOnClickListener(v -> commitSec.accept(currentSecRef[0] + delta));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, a.dp(36), 1f);
            if (i + 1 < deltas.length) lp.rightMargin = a.dp(5);
            stepRow.addView(b, lp);
            stepBtns[i] = b;
        }
        card.addView(stepRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(card, 10);

        // Row 2: 3 equal-weight action buttons (设为当前 / 清除 / 完成) — zero overflow
        LinearLayout actionRow = a.row();
        actionRow.setTag("skip-action-row");
        actionRow.setWeightSum(3f);
        actionRow.setGravity(Gravity.CENTER_VERTICAL);

        String captureLabel =
                hasCapture
                        ? ("设为当前 " + PlaybackController.formatTime(captureSec * 1000))
                        : "设为当前时间";
        final TextView captureBtn =
                makeSkipDialogAction(
                        a,
                        captureLabel,
                        "skip-confirm-current",
                        0x2a34d399,
                        0xff6ee7b7,
                        () -> {
                            if (captureSec > 0) {
                                commitSec.accept(captureSec);
                            } else if (captureSec < 0) {
                                a.toast("当前距片尾超过 20 分钟，请使用上方按键微调");
                            } else {
                                a.toast("播放尚未就绪，请先播放后再记录当前时间");
                            }
                        });
        LinearLayout.LayoutParams capLp = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
        capLp.rightMargin = a.dp(8);
        actionRow.addView(captureBtn, capLp);

        final TextView clearBtn =
                makeSkipDialogAction(
                        a, "清除本片", "skip-clear", 0x24ffffff, 0xe6f5f5f7, () -> commitSec.accept(0));
        LinearLayout.LayoutParams clrLp = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
        clrLp.rightMargin = a.dp(8);
        actionRow.addView(clearBtn, clrLp);

        final TextView doneBtn =
                makeSkipDialogAction(
                        a, "完成", "skip-done", 0xff1e7b52, MainActivity.WHITE, dlg::dismiss);
        actionRow.addView(doneBtn, new LinearLayout.LayoutParams(0, a.dp(38), 1f));
        card.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));

        // Explicit D-pad navigation across SeekBar <-> Step Row <-> Action Row
        TextView[] actionBtns = {captureBtn, clearBtn, doneBtn};
        bar.setNextFocusDownId(stepBtns[3].getId());
        bar.setNextFocusUpId(bar.getId());
        for (int i = 0; i < stepBtns.length; i++) {
            stepBtns[i].setNextFocusLeftId(stepBtns[Math.max(0, i - 1)].getId());
            stepBtns[i].setNextFocusRightId(stepBtns[Math.min(stepBtns.length - 1, i + 1)].getId());
            stepBtns[i].setNextFocusUpId(bar.getId());
            stepBtns[i].setNextFocusDownId(actionBtns[Math.min(2, i / 2)].getId());
        }
        for (int i = 0; i < actionBtns.length; i++) {
            actionBtns[i].setNextFocusLeftId(actionBtns[Math.max(0, i - 1)].getId());
            actionBtns[i].setNextFocusRightId(
                    actionBtns[Math.min(actionBtns.length - 1, i + 1)].getId());
            actionBtns[i].setNextFocusUpId(
                    stepBtns[Math.min(stepBtns.length - 1, i * 2 + 1)].getId());
            actionBtns[i].setNextFocusDownId(actionBtns[i].getId());
        }

        bar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    public void onStartTrackingTouch(SeekBar s) {}

                    public void onStopTrackingTouch(SeekBar s) {}

                    public void onProgressChanged(SeekBar s, int progress, boolean fromUser) {
                        if (fromUser) commitSec.accept(progress);
                    }
                });

        dlg.setOnDismissListener(
                d -> {
                    if (owner != null) {
                        if (owner.activeDialog == dlg) {
                            owner.activeDialog = null;
                            owner.dialogOpen = false;
                            a.scheduleHide();
                            if (a.ui != null) {
                                a.ui.post(
                                        () -> {
                                            if (a.playbackControls == owner && !owner.dialogOpen) {
                                                owner.restoreToolbarFocusAfterSubmenu();
                                                owner.refreshTooltipForCurrentFocus();
                                            }
                                        });
                            }
                        }
                    }
                    if (mutatedRef[0] && onChanged != null) {
                        onChanged.run();
                    }
                });

        dlg.setContentView(
                card,
                new android.view.ViewGroup.LayoutParams(
                        cardWidth, android.view.ViewGroup.LayoutParams.WRAP_CONTENT));
        dlg.show();
        final Window window = dlg.getWindow();
        if (window != null) {
            window.getDecorView().setTag("app-dialog");
            window.getDecorView().setPadding(0, 0, 0, 0);
            window.getDecorView().setMinimumWidth(0);
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.setLayout(cardWidth, android.view.WindowManager.LayoutParams.WRAP_CONTENT);
            window.setGravity(Gravity.CENTER);
            android.view.WindowManager.LayoutParams lp = window.getAttributes();
            lp.dimAmount = 0.60f;
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            window.setAttributes(lp);
        }
        card.post(
                () -> {
                    if (savedSec == 0 && hasCapture) {
                        captureBtn.requestFocus();
                    } else {
                        stepBtns[3].requestFocus();
                    }
                });
    }

    private static TextView makeSkipDialogAction(
            MainActivity a, String label, String tag, int idleBg, int idleFg, Runnable onClick) {
        final TextView b = a.text(label, 12.5f, idleFg);
        b.setId(View.generateViewId());
        b.setTag(tag);
        b.setTypeface(null, android.graphics.Typeface.BOLD);
        b.setGravity(Gravity.CENTER);
        b.setSingleLine(true);
        b.setEllipsize(TextUtils.TruncateAt.END);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setPadding(a.dp(6), 0, a.dp(6), 0);
        b.setFocusable(true);
        b.setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(b, false);
        styleSkipDialogPill(a, b, false, idleBg, idleFg);
        b.setOnFocusChangeListener((v, f) -> styleSkipDialogPill(a, b, f, idleBg, idleFg));
        b.setOnClickListener(v -> onClick.run());
        return b;
    }

    private static void styleSkipDialogPill(
            MainActivity a, TextView b, boolean focused, int idleBg, int idleFg) {
        android.graphics.drawable.GradientDrawable gd =
                a.bg(focused ? MainActivity.WHITE : idleBg, 11);
        gd.setStroke(Math.max(1, a.dp(focused ? 1.5f : 0.7f)), focused ? 0xff34d399 : 0x24ffffff);
        b.setBackground(gd);
        b.setTextColor(focused ? 0xff101614 : idleFg);
    }

    void openMergedSkipPanel() {
        openMergedSkipPanel(null);
    }

    void openMergedSkipPanel(Runnable onCancelBack) {
        List<PlayerBubble.Row> rows = new ArrayList<>();
        int idx = 0;
        rows.add(PlayerBubble.Row.header("本剧跳过规则（按剧记忆，各集自动延续）"));
        final int introIdx = idx++;
        rows.add(
                PlayerBubble.Row.item(
                        introIdx,
                        "本剧片头 · " + skipLabel(getVideoIntro(a, site, video)),
                        getVideoIntro(a, site, video) > 0));
        final int outroIdx = idx++;
        rows.add(
                PlayerBubble.Row.item(
                        outroIdx,
                        "本剧片尾 · " + skipLabel(getVideoOutro(a, site, video)),
                        getVideoOutro(a, site, video) > 0));
        final int markerIdx;
        if (a.isTvDevice() && !a.isLive() && !a.isCast()) {
            rows.add(PlayerBubble.Row.header("本集本线路打点（绝对毫秒节点，独立保存）"));
            markerIdx = idx++;
            rows.add(PlayerBubble.Row.item(markerIdx, "打开本集精准片头 / 片尾打点", false));
        } else {
            markerIdx = -1;
        }
        showStructuredBubble(
                "片头片尾",
                "",
                rows,
                0,
                i -> {
                    if (i == introIdx) {
                        openSkipEditDialog(true);
                    } else if (i == outroIdx) {
                        openSkipEditDialog(false);
                    } else if (markerIdx >= 0 && i == markerIdx) {
                        if (!a.prepared || a.player == null) {
                            a.toast("请等待视频开始播放后再打点");
                            return;
                        }
                        a.showControls(false);
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || a.playbackControls != this) return;
                                    long now = android.os.SystemClock.uptimeMillis();
                                    KeyEvent syntheticDown =
                                            new KeyEvent(
                                                    now,
                                                    now,
                                                    KeyEvent.ACTION_DOWN,
                                                    KeyEvent.KEYCODE_DPAD_UP,
                                                    0);
                                    if (!markers().open(syntheticDown)) {
                                        a.toast("当前暂无法打开精准打点");
                                    }
                                });
                    }
                },
                "",
                true,
                onCancelBack);
    }

    void repeat() {
        repeat(null);
    }

    void repeat(Runnable onCancelBack) {
        choose(
                "循环播放（以后播放沿用）",
                new String[] {"关闭", "单集循环", "列表循环"},
                a.prefs.getInt(Prefs.REPEAT_MODE, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.REPEAT_MODE, i).apply();
                    if (a.player != null)
                        a.player.setRepeatOne(
                                shouldEnableNativeRepeatOne(
                                        i,
                                        a.isTvDevice()
                                                ? outroPosition(a.player.getDuration()) == 0
                                                : getVideoOutro(a, site, video) == 0));
                    updateLabels();
                },
                onCancelBack);
    }

    void sleepTimerMenu() {
        sleepTimerMenu(null);
    }

    void sleepTimerMenu(Runnable onCancelBack) {
        long now = android.os.SystemClock.elapsedRealtime();
        choose(
                "定时关闭（" + SESSION_SLEEP_TIMER.summaryLabel(now) + "）",
                SleepTimerSheet.PRESET_LABELS,
                SESSION_SLEEP_TIMER.getMode(),
                idx -> {
                    long t = android.os.SystemClock.elapsedRealtime();
                    SESSION_SLEEP_TIMER.selectPreset(idx, t);
                    if (sleepWarningPill != null) sleepWarningPill.hide();
                    if (a.playerChrome != null) a.playerChrome.syncSleepHudPill(t);
                    refreshMarkerPlaybackMode();
                    Button sleepBtn = buttons.get(TvPlayerToolbarOrder.KEY_SLEEP_TIMER);
                    if (sleepBtn != null) sleepBtn.invalidate();
                    a.toast(
                            idx == SleepTimerSheet.MODE_OFF
                                    ? "已关闭定时停止"
                                    : "已开启定时关闭：" + SleepTimerSheet.PRESET_LABELS[idx]);
                },
                onCancelBack);
    }

    private void triggerSleepExpiry() {
        if (sleepWarningPill != null) sleepWarningPill.hide();
        if (skipCountdownPill != null) skipCountdownPill.dismissSilently();
        if (a.player != null && a.prepared) {
            try {
                a.player.pause();
            } catch (Exception ignored) {
            }
        }
        a.playing = false;
        if (a.getWindow() != null) {
            a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
        if (a.playerChrome != null) a.playerChrome.syncSleepHudPill(0L);
        if (a.playStatus != null) {
            a.playStatus.setText("定时关闭已触发 · 已停止播放");
        }
        a.toast("定时关闭已到点，已停止播放");
        if (!a.isFinishing() && !a.isDestroyed()) {
            a.leavePlayback();
        }
    }

    private void executeSkipAction(boolean intro, int targetPositionMs) {
        if (a.player == null || !a.prepared || transitioning || !canRunSkipCountdown()) return;
        if (intro) {
            int duration = a.player.getDuration();
            if (duration > 0 && targetPositionMs > 0 && targetPositionMs < duration - 1000) {
                recordUserSeek(targetPositionMs);
                a.player.seekTo(targetPositionMs);
                a.toast("已跳过片头");
            }
            return;
        }
        if (SESSION_SLEEP_TIMER.onEpisodeCompleted()) {
            triggerSleepExpiry();
            return;
        }
        int duration = a.player.getDuration();
        long tailNode = outroPosition(duration);
        if (a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 1) {
            int target = introPosition(duration);
            if (a.isTvDevice() && tailNode > 0 && target >= tailNode) {
                target = 0;
            }
            recordUserSeek(target);
            a.player.seekTo(target);
        } else if (!step(1)) {
            transitioning = true;
            a.player.pause();
            a.playing = false;
            a.playStatus.setText("已跳过片尾");
            a.showControls(true);
        }
    }

    void chooseCastDevice() {
        if (a.privateMode) {
            a.toast("隐私空间已隔离局域网投屏");
            return;
        }
        String castUrl = resolved == null || resolved.url == null ? "" : resolved.url.trim();
        String valid = CastService.validateCastMediaUrl(castUrl);
        if (valid.isEmpty()) {
            a.toast("当前播放流为本地代理或非 HTTP 直链，暂不支持直接推送给外部投屏设备");
            return;
        }
        String displayTitle =
                video != null && video.title != null && !video.title.trim().isEmpty()
                        ? video.title.trim()
                        : (resolved != null && resolved.name != null
                                ? resolved.name.trim()
                                : "Marco Movie");
        if (a.activeEpisode != null
                && a.activeEpisode.name != null
                && !a.activeEpisode.name.trim().isEmpty()
                && !displayTitle.contains(a.activeEpisode.name.trim())) {
            displayTitle = displayTitle + " · " + a.activeEpisode.name.trim();
        }
        DlnaCastClient.showCastDevicePicker(
                a,
                valid,
                displayTitle,
                () -> {
                    if (a.player != null && a.prepared && a.playing) {
                        try {
                            a.player.pause();
                            a.playing = false;
                            if (a.playerChrome != null) a.playerChrome.update();
                        } catch (Throwable ignored) {
                        }
                    }
                });
    }

    void more() {
        more(0);
    }

    void more(int initialFocusActionIndex) {
        if ("live".equals(site.key)) {
            final String clockKey =
                    a.isTvDevice() ? Prefs.TV_PLAYER_TOP_RIGHT_HUD : Prefs.PLAYER_ALWAYS_SHOW_CLOCK;
            boolean alwaysClock = a.prefs.getBoolean(clockKey, a.isTvDevice());
            String sleepSummary =
                    SESSION_SLEEP_TIMER.summaryLabel(android.os.SystemClock.elapsedRealtime());
            boolean offerCast = !a.isTvDevice() && !a.privateMode && !a.isCast();
            List<String> liveList = new ArrayList<>();
            if (offerCast) liveList.add("投屏 · 选择设备");
            liveList.add("上一频道");
            liveList.add("选择频道");
            liveList.add("播放线路");
            liveList.add("节目单与回看 (EPG)");
            liveList.add("播放器与解码（以后播放沿用）");
            liveList.add("画面色彩（以后播放沿用）");
            liveList.add("定时关闭：" + sleepSummary);
            liveList.add(
                    (a.isTvDevice() ? "右上角进度与时间：" : "播放页常显时间：")
                            + (alwaysClock ? "开启" : "关闭")
                            + "（以后播放沿用）");
            liveList.add("播放信息");
            liveList.add("返回频道列表");
            final int liveOffset = offerCast ? 1 : 0;
            choose(
                    "直播更多",
                    liveList.toArray(new String[0]),
                    initialFocusActionIndex,
                    i -> {
                        if (offerCast && i == 0) {
                            chooseCastDevice();
                            return;
                        }
                        switch (i - liveOffset) {
                            case 0:
                                a.liveStep(-1);
                                break;
                            case 1:
                                a.chooseLiveChannel();
                                break;
                            case 2:
                                a.chooseLiveStream();
                                break;
                            case 3:
                                LiveController.showEpgAndCatchupDialog(a);
                                break;
                            case 4:
                                decoderMenu(() -> more(i));
                                break;
                            case 5:
                                pictureEffect(() -> more(i));
                                break;
                            case 6:
                                sleepTimerMenu(() -> more(i));
                                break;
                            case 7:
                                a.prefs.edit().putBoolean(clockKey, !alwaysClock).apply();
                                if (a.playerChrome != null) a.playerChrome.syncClockViews();
                                break;
                            case 8:
                                message(
                                        a.player == null
                                                ? "播放器尚未准备好。"
                                                : a.player.playbackInfo()
                                                        + "\n"
                                                        + surface.outputName(),
                                        () -> more(i));
                                break;
                            case 9:
                                clearSleepTimerOnLeave();
                                a.leavePlayback();
                                break;
                        }
                    });
            return;
        }
        final String clockKey =
                a.isTvDevice() ? Prefs.TV_PLAYER_TOP_RIGHT_HUD : Prefs.PLAYER_ALWAYS_SHOW_CLOCK;
        boolean alwaysClock = a.prefs.getBoolean(clockKey, a.isTvDevice());
        boolean slimProgress = PlayerHudPrefs.isSlimProgressEnabled(a);
        boolean autoNext = a.prefs.getBoolean(Prefs.AUTO_NEXT, true);
        String sleepSummary =
                SESSION_SLEEP_TIMER.summaryLabel(android.os.SystemClock.elapsedRealtime());
        boolean offerCast = !a.isTvDevice() && !a.privateMode && !a.isCast();
        boolean danmuOnMainBar =
                buttons.get(TvPlayerToolbarOrder.KEY_DANMAKU) instanceof ModernIconButton
                        && buttons.get(TvPlayerToolbarOrder.KEY_DANMAKU).getVisibility()
                                == View.VISIBLE;

        final String[] aspectLabels = {"适应画面", "铺满屏幕", "16:9", "4:3", "裁切填充"};
        int aspectIdx =
                Math.max(0, Math.min(aspectLabels.length - 1, a.prefs.getInt(Prefs.ASPECT, 0)));
        final String[] repeatLabels = {"关闭", "单集循环", "列表循环"};
        int repIdx =
                Math.max(
                        0, Math.min(repeatLabels.length - 1, a.prefs.getInt(Prefs.REPEAT_MODE, 0)));
        int engMode = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
        String engLabel =
                engMode == 3 ? "MPV" : (engMode == 2 ? "IJK" : (engMode == 1 ? "系统" : "Exo"));
        int decMode = a.prefs.getInt(Prefs.DECODER_MODE, 0);
        String decLabel = decMode == 1 ? "硬件解码" : (decMode == 2 ? "软件优先" : "自动");
        int outMode = a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0);
        String outLabel = outMode == 0 ? "保真输出" : "兼容输出";

        List<PlayerBubble.Row> rows = new ArrayList<>();
        final List<Runnable> actions = new ArrayList<>();
        int idx = 0;

        if (offerCast) {
            rows.add(PlayerBubble.Row.item(idx++, "投屏 · 选择设备", false));
            actions.add(this::chooseCastDevice);
        }

        // 1. 剧集与时间
        rows.add(PlayerBubble.Row.header("剧集与时间"));
        final int prevEpIdx = idx++;
        rows.add(PlayerBubble.Row.item(prevEpIdx, "上一集（本集）", false));
        actions.add(
                () -> {
                    if (!step(-1)) message("已经是第一集。", () -> more(prevEpIdx));
                });

        final int restartIdx = idx++;
        rows.add(PlayerBubble.Row.item(restartIdx, "从头重播（本集）", false));
        actions.add(
                () -> {
                    pendingResumeMs = 0;
                    if (a.playingBookmark != null) a.playingBookmark.position = 0;
                    if (a.player != null && a.prepared) {
                        recordUserSeek(0);
                        a.player.seekTo(0);
                        a.player.start();
                        a.playing = true;
                    } else {
                        a.resumeAt = -1;
                        reload(false);
                    }
                });

        final int skipIdx = idx++;
        rows.add(PlayerBubble.Row.item(skipIdx, "片头片尾（本剧规则 / 本集打点）", false));
        actions.add(() -> openMergedSkipPanel(() -> more(skipIdx)));

        final int repeatIdx = idx++;
        rows.add(
                PlayerBubble.Row.item(
                        repeatIdx, "循环播放 · " + repeatLabels[repIdx] + "（以后播放沿用）", false));
        actions.add(() -> repeat(() -> more(repeatIdx)));

        final int autoNextIdx = idx++;
        rows.add(
                PlayerBubble.Row.item(
                        autoNextIdx, "自动下一集：" + (autoNext ? "开启" : "关闭") + "（以后播放沿用）", autoNext));
        actions.add(
                () -> {
                    boolean nextVal = !autoNext;
                    a.prefs.edit().putBoolean(Prefs.AUTO_NEXT, nextVal).apply();
                    a.toast(nextVal ? "已开启自动播放下一集（以后播放沿用）" : "已关闭自动播放下一集（以后播放沿用）");
                });

        final int sleepIdx = idx++;
        rows.add(PlayerBubble.Row.item(sleepIdx, "定时关闭 · " + sleepSummary, false));
        actions.add(() -> sleepTimerMenu(() -> more(sleepIdx)));

        // 2. 画面与声音
        rows.add(PlayerBubble.Row.header("画面与声音"));
        final int aspectRowIdx = idx++;
        rows.add(
                PlayerBubble.Row.item(
                        aspectRowIdx, "画面比例 · " + aspectLabels[aspectIdx] + "（以后播放沿用）", false));
        actions.add(() -> aspect(() -> more(aspectRowIdx)));

        final int picIdx = idx++;
        rows.add(PlayerBubble.Row.item(picIdx, "画面色彩（以后播放沿用）", false));
        actions.add(() -> pictureEffect(() -> more(picIdx)));

        final int soundIdx = idx++;
        rows.add(PlayerBubble.Row.item(soundIdx, "音效（以后播放沿用）", false));
        actions.add(() -> soundEffect(() -> more(soundIdx)));

        // 3. 播放故障
        rows.add(PlayerBubble.Row.header("播放故障"));
        final int retryIdx = idx++;
        rows.add(PlayerBubble.Row.item(retryIdx, "重试播放（本集）", false));
        actions.add(() -> reload(true));

        final int lineIdx = idx++;
        rows.add(PlayerBubble.Row.item(lineIdx, "切换线路 / 画质", false));
        actions.add(() -> chooseLine(() -> more(lineIdx)));

        final int engIdx = idx++;
        rows.add(PlayerBubble.Row.item(engIdx, "播放器内核 · " + engLabel + "（以后播放沿用）", false));
        actions.add(() -> engine(() -> more(engIdx)));

        final int decIdx = idx++;
        rows.add(PlayerBubble.Row.item(decIdx, "解码方式 · " + decLabel + "（以后播放沿用）", false));
        actions.add(() -> decoder(() -> more(decIdx)));

        final int outIdx = idx++;
        rows.add(PlayerBubble.Row.item(outIdx, "画面输出 · " + outLabel + "（以后播放沿用）", false));
        actions.add(() -> output(() -> more(outIdx)));

        final int infoIdx = idx++;
        rows.add(PlayerBubble.Row.item(infoIdx, "播放信息", false));
        actions.add(
                () ->
                        message(
                                a.player == null
                                        ? "播放器尚未准备好。"
                                        : a.player.playbackInfo() + "\n" + surface.outputName(),
                                () -> more(infoIdx)));

        // 4. 界面显示
        rows.add(PlayerBubble.Row.header("界面显示"));
        if (!danmuOnMainBar) {
            final int danmuFallbackIdx = idx++;
            rows.add(PlayerBubble.Row.item(danmuFallbackIdx, "弹幕（状态 / 重试 / 偏好）", false));
            actions.add(() -> danmaku(() -> more(danmuFallbackIdx)));
        }
        final int clockIdx = idx++;
        rows.add(
                PlayerBubble.Row.item(
                        clockIdx,
                        (a.isTvDevice() ? "右上角进度与时间：" : "播放页常显时间：")
                                + (alwaysClock ? "开启" : "关闭")
                                + "（以后播放沿用）",
                        alwaysClock));
        actions.add(
                () -> {
                    a.prefs.edit().putBoolean(clockKey, !alwaysClock).apply();
                    if (a.playerChrome != null) a.playerChrome.syncClockViews();
                });

        final int slimIdx = idx++;
        rows.add(
                PlayerBubble.Row.item(
                        slimIdx,
                        "底部细进度条：" + (slimProgress ? "开启" : "关闭") + "（以后播放沿用）",
                        slimProgress));
        actions.add(
                () -> {
                    boolean nextSlim = !slimProgress;
                    PlayerHudPrefs.setSlimProgressEnabled(a, nextSlim);
                    if (a.playerChrome != null) a.playerChrome.update();
                    a.toast(nextSlim ? "已开启播放中底部细进度条" : "已关闭播放中底部细进度条");
                });

        if (a.isTvDevice()) {
            final int toolbarOrderIdx = idx++;
            rows.add(PlayerBubble.Row.item(toolbarOrderIdx, "播放工具栏排列", false));
            actions.add(
                    () ->
                            new SettingsScreen(a)
                                    .showTvToolbarOrderDialogForPlayer(
                                            this::rebuildTvToolbarFromPrefs,
                                            () -> more(toolbarOrderIdx)));
        }

        final int backDetailIdx = idx++;
        rows.add(PlayerBubble.Row.item(backDetailIdx, "返回详情", false));
        actions.add(
                () -> {
                    clearSleepTimerOnLeave();
                    a.leavePlayback();
                });

        int safeFocus =
                initialFocusActionIndex >= 0 && initialFocusActionIndex < actions.size()
                        ? initialFocusActionIndex
                        : 0;
        showStructuredBubble(
                "更多",
                "",
                rows,
                safeFocus,
                i -> {
                    if (i >= 0 && i < actions.size()) {
                        actions.get(i).run();
                    }
                },
                "",
                true,
                null);
    }

    void updateLabels() {
        float rate = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
        Button speedBtn = buttons.get("speed");
        if (speedBtn != null) {
            if (speedBtn instanceof ModernIconButton) {
                speedBtn.setContentDescription(
                        Math.abs(rate - 1f) < 0.01f ? "倍速" : "倍速 " + rate + "×");
            } else if (a.isTvDevice()) {
                speedBtn.setText(Math.abs(rate - 1f) < 0.01f ? "倍速" : rate + "×");
            } else {
                speedBtn.setText(rate + "×");
            }
        }
        Button introBtn = buttons.get("skip-intro-tool");
        if (introBtn != null) {
            int s = getVideoIntro(a, site, video);
            if (a.isTvDevice()) {
                String fmt = s > 0 ? PlaybackController.formatTime(s * 1000) : "";
                introBtn.setContentDescription(
                        s > 0 ? ("片头 " + fmt + " · 单击设当前 / 双击编辑") : "片头 · 单击设当前 / 双击编辑");
                if (!(introBtn instanceof ModernIconButton)) {
                    introBtn.setText(s > 0 ? "片头 " + fmt : "片头");
                }
                introBtn.invalidate();
            } else if (introBtn instanceof ModernIconButton) {
                introBtn.setContentDescription(s > 0 ? "片头 " + s + "s" : "片头");
                introBtn.invalidate();
            } else {
                introBtn.setText(s > 0 ? s + "s" : "片头");
            }
        }
        Button outroBtn = buttons.get("skip-outro-tool");
        if (outroBtn != null) {
            int s = getVideoOutro(a, site, video);
            if (a.isTvDevice()) {
                String fmt = s > 0 ? PlaybackController.formatTime(s * 1000) : "";
                outroBtn.setContentDescription(
                        s > 0 ? ("片尾 结束前 " + fmt + " · 单击设当前 / 双击编辑") : "片尾 · 单击设当前 / 双击编辑");
                if (!(outroBtn instanceof ModernIconButton)) {
                    outroBtn.setText(s > 0 ? "片尾 " + fmt : "片尾");
                }
                outroBtn.invalidate();
            } else if (outroBtn instanceof ModernIconButton) {
                outroBtn.setContentDescription(s > 0 ? "片尾 " + s + "s" : "片尾");
                outroBtn.invalidate();
            } else {
                outroBtn.setText(s > 0 ? s + "s" : "片尾");
            }
        }
        Button decBtn = buttons.get("decoder");
        if (decBtn != null) {
            int eng = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
            String engLabel = eng == 3 ? "MPV" : (eng == 2 ? "IJK" : (eng == 1 ? "系统" : "Exo"));
            if (decBtn instanceof ModernIconButton) {
                decBtn.setContentDescription("解码 · " + engLabel);
                decBtn.invalidate();
            } else {
                decBtn.setText(engLabel);
            }
        }
        if (a.isTvDevice() && activeTooltipButton != null && activeTooltipButton.hasFocus()) {
            refreshTooltipForCurrentFocus();
        }
        refreshDanmuBadgeIcon();
    }

    String skipLabel(int seconds) {
        return seconds == 0 ? "关闭" : a.time(seconds * 1000);
    }

    void applyExternalDanmaku(String rawUrl) {
        applyExternalDanmaku(rawUrl, danmuOwner);
    }

    void applyExternalDanmaku(String rawUrl, DanmuOwnership.RequestContext pushOwner) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return;
        if (pushOwner == null
                || !pushOwner.matches(danmuOwner)
                || !isDanmuOwnerStillActive(danmuOwner)) {
            return;
        }
        String candidate = rawUrl.trim();
        if (candidate.startsWith("[") || candidate.startsWith("{")) {
            try {
                org.json.JSONObject wrapper = new org.json.JSONObject().put("danmaku", candidate);
                String extracted = MediaOptions.extractDanmakuUrl(wrapper);
                if (!extracted.isEmpty()) candidate = extracted;
            } catch (Exception ignored) {
            }
        }
        String rewritten = LocalProxy.rewrite(candidate);
        if (rewritten == null || rewritten.isEmpty()) return;
        String previous = resolved.media.optString("danmaku");
        try {
            resolved.media.put("danmaku", rewritten);
            resolved.media.put("_danmakuSource", "plugin");
        } catch (Exception ignored) {
        }
        if (a.prefs.getBoolean(Prefs.DANMAKU_DEFAULT, true)
                && (!danmakuLoaded || !rewritten.equals(previous))) {
            final int loadSer = ++danmuLoadSerial;
            final DanmuOwnership.RequestContext ownerSnap = danmuOwner;
            closeSegmentedDanmuSession();
            danmuStatus.markLoading(DanmuOwnership.SourceKind.PLUGIN_PUSH);
            danmaku.enabled(true);
            danmaku.load(
                    rewritten,
                    DanmakuView.sanitizeDanmakuHeaders(rewritten, resolved.url, resolved.headers),
                    new DanmakuView.Listener() {
                        public void loaded(int count) {
                            if (loadSer != danmuLoadSerial || !isDanmuOwnerStillActive(ownerSnap)) {
                                return;
                            }
                            danmakuLoaded = count > 0;
                            if (count > 0) {
                                DanmuOwnership.GLOBAL.markConfirmedDanmuMounted(ownerSnap);
                                danmuStatus.markLoaded(
                                        DanmuOwnership.SourceKind.PLUGIN_PUSH, count, "", "");
                                a.toast("已加载 " + count + " 条弹幕");
                            } else {
                                danmuStatus.markNoComments(
                                        DanmuOwnership.SourceKind.PLUGIN_PUSH, "", "");
                            }
                        }

                        public void error(String message) {
                            if (loadSer != danmuLoadSerial || !isDanmuOwnerStillActive(ownerSnap)) {
                                return;
                            }
                            danmakuLoaded = false;
                            danmuStatus.markFailure(
                                    DanmuOwnership.SourceKind.PLUGIN_PUSH,
                                    new DanmuProvider.FailureInfo(
                                            DanmuProvider.FailureKind.NETWORK_ERROR,
                                            0,
                                            0L,
                                            message));
                            if (!a.isLive() && !a.isCast()) {
                                DanmuSettingsPanel.DanmuConfig dmCfg =
                                        DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
                                if (dmCfg.enabled && !dmCfg.serverUrls.isEmpty()) {
                                    startSegmentedDanmuSession(dmCfg, false);
                                }
                            }
                        }
                    });
        }
    }

    private List<String> collectResolvedDanmakuUrls() {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        if (resolved != null && resolved.media != null) {
            org.json.JSONArray list = resolved.media.optJSONArray("danmakuList");
            if (list != null) {
                for (int i = 0; i < list.length(); i++) {
                    String u = list.optString(i, "").trim();
                    if (!u.isEmpty()) out.add(u);
                }
            }
            String primary = resolved.media.optString("danmaku", "").trim();
            if (!primary.isEmpty()) out.add(primary);
        }
        return new ArrayList<>(out);
    }

    private DanmuOwnership.SourceKind resolvedDanmakuSourceKind() {
        if (resolved != null
                && resolved.media != null
                && "plugin".equals(resolved.media.optString("_danmakuSource", ""))) {
            return DanmuOwnership.SourceKind.PLUGIN_PUSH;
        }
        return DanmuOwnership.SourceKind.SOURCE_BUNDLED;
    }

    private void loadDanmakuCandidateChain(
            final List<String> candidates, final int index, final boolean showUserError) {
        final int loadSer = ++danmuLoadSerial;
        loadDanmakuCandidateChain(
                candidates,
                index,
                showUserError,
                resolvedDanmakuSourceKind(),
                loadSer,
                danmuOwner,
                null);
    }

    private void loadDanmakuCandidateChain(
            final List<String> candidates,
            final int index,
            final boolean showUserError,
            final DanmuOwnership.SourceKind sourceKind,
            final int loadSer,
            final DanmuOwnership.RequestContext ownerSnap,
            final String lastErrorMsg) {
        if (loadSer != danmuLoadSerial || !isDanmuOwnerStillActive(ownerSnap)) {
            return;
        }
        if (candidates == null || index >= candidates.size()) {
            danmakuLoaded = false;
            if (!a.isLive() && !a.isCast()) {
                DanmuSettingsPanel.DanmuConfig dmCfg =
                        DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
                danmaku.applyConfig(dmCfg);
                if (dmCfg.enabled && !dmCfg.serverUrls.isEmpty()) {
                    startSegmentedDanmuSession(dmCfg, showUserError);
                    return;
                }
            }
            if (lastErrorMsg != null && !lastErrorMsg.isEmpty()) {
                danmuStatus.markFailure(
                        sourceKind,
                        new DanmuProvider.FailureInfo(
                                DanmuProvider.FailureKind.NETWORK_ERROR, 0, 0L, lastErrorMsg));
            } else {
                danmuStatus.markNoMatch();
            }
            if (showUserError) {
                message("当前片源暂未返回可用弹幕，可在「弹幕偏好」配置自定义弹幕服务或导入本地 XML / JSON 文件。");
            }
            return;
        }
        if (index == 0) {
            danmuStatus.markLoading(sourceKind);
        }
        String dmUrl = candidates.get(index);
        danmaku.enabled(true);
        danmaku.load(
                dmUrl,
                DanmakuView.sanitizeDanmakuHeaders(dmUrl, resolved.url, resolved.headers),
                new DanmakuView.Listener() {
                    public void loaded(int count) {
                        if (loadSer != danmuLoadSerial || !isDanmuOwnerStillActive(ownerSnap)) {
                            return;
                        }
                        if (count > 0) {
                            danmakuLoaded = true;
                            DanmuOwnership.GLOBAL.markConfirmedDanmuMounted(ownerSnap);
                            danmuStatus.markLoaded(sourceKind, count, "", "");
                            refreshDanmuBadgeIcon();
                            AppLog.i(
                                    "PlaybackControls",
                                    DanmuProvider.FailureInfo.sanitizedDiagnostic(
                                            "direct_load", 200, ownerSnap.anonId(), count));
                            a.toast("已加载 " + count + " 条弹幕");
                        } else {
                            loadDanmakuCandidateChain(
                                    candidates,
                                    index + 1,
                                    showUserError,
                                    sourceKind,
                                    loadSer,
                                    ownerSnap,
                                    lastErrorMsg);
                        }
                    }

                    public void error(String message) {
                        if (loadSer != danmuLoadSerial || !isDanmuOwnerStillActive(ownerSnap)) {
                            return;
                        }
                        loadDanmakuCandidateChain(
                                candidates,
                                index + 1,
                                showUserError,
                                sourceKind,
                                loadSer,
                                ownerSnap,
                                message);
                    }
                });
    }

    void retryCurrentEpisodeDanmu(boolean showFeedback) {
        danmuStatus.reset(currentEpisodeDisplayLabel());
        List<String> dmCandidates = collectResolvedDanmakuUrls();
        if (dmCandidates.isEmpty()) {
            String recentDm = CspEngine.consumeRecentPluginDanmaku(danmuOwner, 120000L);
            if (!recentDm.isEmpty()) {
                String rewritten = LocalProxy.rewrite(recentDm);
                try {
                    resolved.media.put("danmaku", rewritten);
                    resolved.media.put("_danmakuSource", "plugin");
                } catch (Exception ignored) {
                }
                if (rewritten != null && !rewritten.isEmpty()) {
                    dmCandidates = Collections.singletonList(rewritten);
                }
            }
        }
        if (!dmCandidates.isEmpty()) {
            closeSegmentedDanmuSession();
            loadDanmakuCandidateChain(dmCandidates, 0, showFeedback);
            return;
        }
        DanmuSettingsPanel.DanmuConfig cur = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        DanmuSettingsPanel.DanmuConfig.Builder b = cur.toBuilder();
        b.enabled = true;
        DanmuSettingsPanel.DanmuConfig enabledCfg = b.build();
        DanmuSettingsPanel.saveConfig(a, enabledCfg);
        if (!enabledCfg.serverUrls.isEmpty()) {
            startSegmentedDanmuSession(enabledCfg, showFeedback);
        } else {
            danmuStatus.markNoMatch();
            if (showFeedback) {
                openDanmuSettingsPanel();
                a.toast("请先填写自定义弹幕服务地址，或导入本地 XML / JSON");
            }
        }
    }

    private SubtitlePreferenceStore.Selection readSeriesSubtitlePreference() {
        if (site == null || "live".equals(site.key)) return null;
        String videoKey = VideoSkipStore.videoKeyFrom(video, a.activeEpisode);
        if (videoKey.isEmpty()) return null;
        if (a.privateMode) {
            return SubtitlePreferenceStore.getPrivate(site.key, videoKey);
        }
        if (a.prefs == null) return null;
        return SubtitlePreferenceStore.read(
                a.prefs.getString(Prefs.VIDEO_SUBTITLE_RECORDS, "[]"), site.key, videoKey);
    }

    private void saveSeriesSubtitlePreference(int trackIndex, String rawLabel) {
        if (site == null || "live".equals(site.key)) return;
        String videoKey = VideoSkipStore.videoKeyFrom(video, a.activeEpisode);
        if (videoKey.isEmpty()) return;
        SubtitlePreferenceStore.Selection sel =
                trackIndex == -2
                        ? new SubtitlePreferenceStore.Selection(true, -2, "")
                        : new SubtitlePreferenceStore.Selection(false, trackIndex, rawLabel);
        if (a.privateMode) {
            SubtitlePreferenceStore.setPrivate(site.key, videoKey, sel);
            return;
        }
        if (a.prefs == null) return;
        String updated =
                SubtitlePreferenceStore.write(
                        a.prefs.getString(Prefs.VIDEO_SUBTITLE_RECORDS, "[]"),
                        site.key,
                        videoKey,
                        sel);
        a.prefs.edit().putString(Prefs.VIDEO_SUBTITLE_RECORDS, updated).apply();
    }

    void selectAndRememberSubtitle(int trackIndex, String rawLabel) {
        subtitlePrefAppliedForEpisode = true;
        if (a.player != null && a.prepared) {
            a.player.selectTrack(3, trackIndex);
        }
        saveSeriesSubtitlePreference(trackIndex, rawLabel);
    }

    private SubtitlePreferenceStore.Selection readSeriesAudioPreference() {
        if (site == null || "live".equals(site.key)) return null;
        String videoKey = VideoSkipStore.videoKeyFrom(video, a.activeEpisode);
        if (videoKey.isEmpty()) return null;
        if (a.privateMode) {
            return SubtitlePreferenceStore.getPrivateAudio(site.key, videoKey);
        }
        if (a.prefs == null) return null;
        return SubtitlePreferenceStore.read(
                a.prefs.getString(Prefs.VIDEO_AUDIO_RECORDS, "[]"), site.key, videoKey);
    }

    private void saveSeriesAudioPreference(int trackIndex, String rawLabel) {
        if (site == null || "live".equals(site.key)) return;
        String videoKey = VideoSkipStore.videoKeyFrom(video, a.activeEpisode);
        if (videoKey.isEmpty()) return;
        if (trackIndex < 0) {
            if (a.privateMode) {
                SubtitlePreferenceStore.removePrivateAudio(site.key, videoKey);
            } else if (a.prefs != null) {
                String updated =
                        SubtitlePreferenceStore.remove(
                                a.prefs.getString(Prefs.VIDEO_AUDIO_RECORDS, "[]"),
                                site.key,
                                videoKey);
                a.prefs.edit().putString(Prefs.VIDEO_AUDIO_RECORDS, updated).apply();
            }
            return;
        }
        SubtitlePreferenceStore.Selection sel =
                new SubtitlePreferenceStore.Selection(false, trackIndex, rawLabel);
        if (a.privateMode) {
            SubtitlePreferenceStore.setPrivateAudio(site.key, videoKey, sel);
            return;
        }
        if (a.prefs == null) return;
        String updated =
                SubtitlePreferenceStore.write(
                        a.prefs.getString(Prefs.VIDEO_AUDIO_RECORDS, "[]"),
                        site.key,
                        videoKey,
                        sel);
        a.prefs.edit().putString(Prefs.VIDEO_AUDIO_RECORDS, updated).apply();
    }

    void selectAndRememberAudio(int trackIndex, String rawLabel) {
        audioPrefAppliedForEpisode = true;
        saveSeriesAudioPreference(trackIndex, rawLabel);
        if (a.player != null && a.prepared) {
            a.player.selectTrack(1, trackIndex);
            if (trackIndex < 0) {
                audioPrefAppliedForEpisode = false;
                applyPreferredAudioIfNeeded();
            }
        }
    }

    void onPlayerTextTracksChanged() {
        applyRememberedSubtitleIfNeeded();
    }

    void onPlayerAudioTracksChanged() {
        applyPreferredAudioIfNeeded();
    }

    private void applyRememberedSubtitleIfNeeded() {
        if (subtitlePrefAppliedForEpisode
                || a.player == null
                || !a.prepared
                || site == null
                || "live".equals(site.key)) return;
        SubtitlePreferenceStore.Selection saved = readSeriesSubtitlePreference();
        if (saved != null && saved.disabled) {
            subtitlePrefAppliedForEpisode = true;
            a.player.selectTrack(3, -2);
            return;
        }
        List<String> labels = a.player.trackLabels(3);
        if (labels == null || labels.isEmpty()) {
            // Tracks may arrive asynchronously after onPrepared (e.g. MKV parse / external SRT).
            return;
        }
        if (saved != null) {
            int matched = SubtitlePreferenceStore.matchTrackIndex(saved, labels);
            if (matched >= 0) {
                subtitlePrefAppliedForEpisode = true;
                String current = labels.get(matched);
                if (current == null || !current.trim().startsWith("✓")) {
                    a.player.selectTrack(3, matched);
                }
            }
            return;
        }
        // First open of a series without saved preference: automatically pick the best Chinese
        // subtitle so multi-language MKV / Web-DL releases do not require manual switching.
        subtitlePrefAppliedForEpisode = true;
        int autoSub = SubtitlePreferenceStore.pickBestSubtitleTrack(labels);
        if (autoSub >= 0) {
            a.player.selectTrack(3, autoSub);
        }
    }

    private void applyPreferredAudioIfNeeded() {
        if (audioPrefAppliedForEpisode
                || a.player == null
                || !a.prepared
                || site == null
                || "live".equals(site.key)) return;
        List<String> labels = a.player.trackLabels(1);
        if (labels == null || labels.isEmpty()) {
            return;
        }
        SubtitlePreferenceStore.Selection saved = readSeriesAudioPreference();
        if (saved != null && !saved.disabled) {
            int matched = SubtitlePreferenceStore.matchTrackIndex(saved, labels);
            if (matched >= 0) {
                audioPrefAppliedForEpisode = true;
                String current = labels.get(matched);
                if (current == null || !current.trim().startsWith("✓")) {
                    a.player.selectTrack(1, matched);
                }
                return;
            }
        }
        audioPrefAppliedForEpisode = true;
        int prefMode =
                a.prefs != null
                        ? a.prefs.getInt(
                                Prefs.AUDIO_TRACK_PREFERENCE,
                                SubtitlePreferenceStore.AUDIO_PREF_SMART)
                        : SubtitlePreferenceStore.AUDIO_PREF_SMART;
        int autoAudio = SubtitlePreferenceStore.pickBestAudioTrack(labels, prefMode);
        if (autoAudio >= 0) {
            a.player.selectTrack(1, autoAudio);
        }
    }

    void prepared() {
        resetEpisodeTransientState();
        if (a.isTvDevice() && !a.isLive() && !a.isCast()) {
            markerObservedPlayer = a.player;
            final MoviePlayer owner = markerObservedPlayer;
            owner.setOnSeekPositionListener(
                    (player, actualPosition) -> {
                        if (a.playbackControls == this
                                && a.player == owner
                                && player == owner
                                && markerObservedPlayer == owner)
                            markerTail.observe(actualPosition);
                    });
        }
        if (a.player == null) return;
        if (resolved.media.optString("danmaku").isEmpty()) {
            String recentDm = CspEngine.consumeRecentPluginDanmaku(danmuOwner, 25000L);
            if (!recentDm.isEmpty()) {
                applyExternalDanmaku(recentDm, danmuOwner);
            }
        }
        List<String> dmCandidates = collectResolvedDanmakuUrls();
        if (a.prefs.getBoolean(Prefs.DANMAKU_DEFAULT, true)
                && !danmakuLoaded
                && !dmCandidates.isEmpty()) {
            loadDanmakuCandidateChain(dmCandidates, 0, false);
        } else if (!danmakuLoaded && !a.isLive() && !a.isCast()) {
            DanmuSettingsPanel.DanmuConfig dmCfg = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
            danmaku.applyConfig(dmCfg);
            if (dmCfg.enabled && !dmCfg.serverUrls.isEmpty()) {
                startSegmentedDanmuSession(dmCfg, false);
            }
        }
        if (danmuMountHook != null) {
            danmuMountHook.run();
        }
        PlaybackEffects.picture(surface, a.prefs.getInt(Prefs.PICTURE_EFFECT, 0));
        try {
            applyPlayerAudioEffects(
                    a.prefs.getInt(Prefs.AUDIO_EFFECT, 0), a.prefs.getInt(Prefs.LOUDNESS_BOOST, 0));
        } catch (Throwable ignored) {
        }
        warnIfTvSystemAudioMuted();
        int duration = a.player.getDuration();
        if (duration <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
            duration = a.playingBookmark.duration;
        }
        timeline.setEnabled(duration > 0);
        timeline.setMax(duration > 0 ? duration : 100);
        if (duration <= 0) timeline.setProgress(0);
        timeline.setKeyProgressIncrement(15000);
        boolean explicitRestart = a.resumeAt < 0;
        boolean historyResume = a.resumeAt > 0;
        int seek =
                ("live".equals(site.key) || explicitRestart)
                        ? 0
                        : historyResume ? a.resumeAt : introPosition(duration);
        a.resumeAt = 0;
        if (seek > 0) {
            if (duration > 0) {
                if (seek < duration - 1000) {
                    pendingResumeMs = 0;
                    pendingResumeIsIntro = false;
                    if (!historyResume
                            && !a.miniMode
                            && skipCountdownPill != null
                            && PlayerHudPrefs.isSkipCountdownEnabled(a)) {
                        pendingIntroSkipMs = seek;
                        boolean hasModalDialog = activeDialog != null && activeDialog.isShowing();
                        if (canRunSkipCountdown()) {
                            skipCountdownPill.start(true, seek, !a.controlsVisible, hasModalDialog);
                        }
                    } else {
                        recordUserSeek(seek);
                        a.player.seekTo(seek);
                        if (historyResume) {
                            a.toast("已为您续播至 " + PlaybackController.formatTime(seek));
                        }
                    }
                }
            } else {
                pendingResumeMs = seek;
                pendingResumeIsIntro = !historyResume;
                if (historyResume) {
                    a.toast("已为您续播至 " + PlaybackController.formatTime(seek));
                }
            }
        }
        if ("live".equals(site.key)) {
            a.player.setSpeed(1.0f);
        } else {
            float speed = a.prefs.getFloat(Prefs.PLAY_SPEED, 1);
            a.player.setSpeed(speed);
            onDanmuPlaySpeedChanged(speed);
            a.player.setRepeatOne(
                    shouldEnableNativeRepeatOne(
                            a.prefs.getInt(Prefs.REPEAT_MODE, 0),
                            a.isTvDevice()
                                    ? outroPosition(duration) == 0
                                    : getVideoOutro(a, site, video) == 0));
        }
        updateLabels();
        syncModernActionVisibility();
        refreshPlayPauseGlyph();
        applyRememberedSubtitleIfNeeded();
        applyPreferredAudioIfNeeded();
        if ((!subtitlePrefAppliedForEpisode || !audioPrefAppliedForEpisode) && a.ui != null) {
            final MoviePlayer owner = a.player;
            a.ui.postDelayed(
                    () -> {
                        if (a.playbackControls == this && a.player == owner && a.prepared) {
                            applyRememberedSubtitleIfNeeded();
                            applyPreferredAudioIfNeeded();
                        }
                    },
                    750L);
        }
        maybeShowFirstPlayGestureHint();
    }

    private void tickSleepTimer() {
        if (!SESSION_SLEEP_TIMER.isActive()) {
            hideSleepWarning();
            if (a.playerChrome != null) a.playerChrome.syncSleepHudPill(0L);
            return;
        }
        long now = android.os.SystemClock.elapsedRealtime();
        if (SESSION_SLEEP_TIMER.tick(now)) {
            triggerSleepExpiry();
            return;
        }
        if (a.playerChrome != null
                && !PlayerChrome.shouldSuppressLiveHudRedraws(
                        a.isTvDevice(), a.playerChrome.hdrSurfaceActive, a.controlsVisible)) {
            a.playerChrome.syncSleepHudPill(now);
        }
        if (sleepWarningPill != null) {
            if (SESSION_SLEEP_TIMER.shouldShowPreExpiryWarning(now)) {
                boolean wasShowing = sleepWarningPill.isShowing();
                long secLeft = (SESSION_SLEEP_TIMER.remainingMs(now) + 999L) / 1000L;
                sleepWarningPill.showCountdownSeconds(secLeft);
                if (!wasShowing) {
                    syncSleepWarningTvFocusLinks(true);
                    if (a.isTvDevice()
                            && !dialogOpen
                            && (activeDialog == null || !activeDialog.isShowing())
                            && a.markerHost == null
                            && !a.seekGesture.active
                            && (skipCountdownPill == null || !skipCountdownPill.isActive())) {
                        if (!a.controlsVisible) {
                            a.showControls(true);
                        }
                        sleepWarningPill.requestInitialTvFocus();
                    }
                }
            } else {
                hideSleepWarning();
            }
        }
    }

    void tick() {
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.syncRuntimeState();
        }
        syncDanmuPlaybackState();
        syncSkipCountdownLifecycle();
        tickSleepTimer();
        if (a.isTvDevice() && (a.markerHost != null || a.seekGesture.active)) return;
        if ("live".equals(site.key)) return;
        if (a.player == null || !a.prepared || isUserSeeking()) return;
        int duration = a.player.getDuration();
        if (duration <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
            duration = a.playingBookmark.duration;
        }
        if (pendingResumeMs > 0 && duration > 0) {
            int target = pendingResumeMs;
            boolean isIntroPending = pendingResumeIsIntro;
            pendingResumeMs = 0;
            pendingResumeIsIntro = false;
            int curPosNow = a.player.getCurrentPosition();
            if (target < duration - 1000) {
                if (isIntroPending) {
                    if (curPosNow < target - 1000) {
                        if (!a.miniMode
                                && skipCountdownPill != null
                                && PlayerHudPrefs.isSkipCountdownEnabled(a)) {
                            pendingIntroSkipMs = target;
                        } else {
                            recordUserSeek(target);
                            a.player.seekTo(target);
                        }
                    }
                } else if (curPosNow < Math.min(target - 2000, 5000)) {
                    recordUserSeek(target);
                    a.player.seekTo(target);
                }
            }
        }
        int actualPosition = a.player.getCurrentPosition();
        reconcileDetachedSegmentedDanmuSession();
        if (danmuSegmentCache != null && danmaku.enabled && danmaku.hasSegmentCache()) {
            danmuSegmentCache.onPlaybackTick(actualPosition, a.player.isPlaying());
        }
        int position = displayPosition(actualPosition);
        if (a.controlsVisible) {
            syncTimelineView(position, duration);
        }
        if (pendingIntroSkipMs > 0 && duration > 0) {
            if (actualPosition >= pendingIntroSkipMs - 1000
                    || pendingIntroSkipMs >= duration - 1000) {
                pendingIntroSkipMs = 0;
            } else if (skipCountdownPill != null
                    && !skipCountdownPill.isActive()
                    && PlayerHudPrefs.isSkipCountdownEnabled(a)
                    && canRunSkipCountdown()) {
                boolean hasModalDialog = activeDialog != null && activeDialog.isShowing();
                skipCountdownPill.start(
                        true, pendingIntroSkipMs, !a.controlsVisible, hasModalDialog);
            }
        }
        long tailNode = outroPosition(duration);
        markerTail.node(tailNode);
        markerTail.observe(actualPosition);
        if (!transitioning
                && !outroSkipCancelledForEpisode
                && canRunSkipCountdown()
                && duration > 0
                && tailNode > 0
                && tailNode < duration
                && (a.isTvDevice() ? markerTail.take(actualPosition) : position >= tailNode)) {
            if (!a.miniMode
                    && skipCountdownPill != null
                    && PlayerHudPrefs.isSkipCountdownEnabled(a)) {
                if (!skipCountdownPill.isActive()) {
                    boolean hasModalDialog = activeDialog != null && activeDialog.isShowing();
                    skipCountdownPill.start(
                            false, (int) tailNode, !a.controlsVisible, hasModalDialog);
                }
            } else {
                executeSkipAction(false, (int) tailNode);
            }
        }
    }

    void completed() {
        if (SESSION_SLEEP_TIMER.onEpisodeCompleted()) {
            triggerSleepExpiry();
            return;
        }
        if (!transitioning
                && (a.prefs.getBoolean(Prefs.AUTO_NEXT, true)
                        || a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 2)
                && step(1)) return;
        a.showControls(true);
        a.playStatus.setText("播放结束 · 按确认重播");
    }

    void resize(int width, int height) {
        videoWidth = width;
        videoHeight = height;
        if (a.playerChrome != null) a.playerChrome.resolution(width, height);
        if (width <= 0 || height <= 0 || a.playbackLayer.getWidth() == 0) return;
        int w = a.playbackLayer.getWidth(),
                h = a.playbackLayer.getHeight(),
                mode = a.prefs.getInt(Prefs.ASPECT, 0);
        float ratio = mode == 2 ? 16f / 9 : mode == 3 ? 4f / 3 : (float) width / height;
        if (mode != 1) {
            if (mode == 4) {
                if ((float) w / h > ratio) h = Math.round(w / ratio);
                else w = Math.round(h * ratio);
            } else if ((float) w / h > ratio) w = Math.round(h * ratio);
            else h = Math.round(w / ratio);
        }
        surface.setLayoutParams(new FrameLayout.LayoutParams(w, h, Gravity.CENTER));
    }

    private void syncTimelineView(int position, int duration) {
        if (duration > 0) {
            if (!timeline.isEnabled()) timeline.setEnabled(true);
            int max = Math.max(duration, position);
            if (timeline.getMax() != max) timeline.setMax(max);
            int clamped = Math.max(0, Math.min(position, max));
            if (timeline.getProgress() != clamped) timeline.setProgress(clamped);
        } else {
            if (timeline.isEnabled()) timeline.setEnabled(false);
            if (timeline.getMax() != 100) timeline.setMax(100);
            if (timeline.getProgress() != 0) timeline.setProgress(0);
        }
    }

    void visible(boolean visible) {
        if (visible
                && a.player != null
                && a.prepared
                && !isUserSeeking()
                && !"live".equals(site.key)) {
            int dur = a.player.getDuration();
            if (dur <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
                dur = a.playingBookmark.duration;
            }
            int pos = displayPosition(a.player.getCurrentPosition());
            syncTimelineView(pos, dur);
        }
        if (a.isTvDevice()
                && visible
                && !lastControlsVisibleForSkip
                && skipCountdownPill != null
                && skipCountdownPill.isActive()) {
            skipCountdownPill.onExternalControlsShown();
        }
        lastControlsVisibleForSkip = visible;
        int bottomDp = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        int basePx = a.dp(bottomDp);
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) subtitle.getLayoutParams();
        if (lp.bottomMargin != basePx) {
            lp.bottomMargin = basePx;
            subtitle.setLayoutParams(lp);
        }
        boolean progressOnly = a.playerChrome != null && a.playerChrome.progressOnlyMode;
        if (a.isTvDevice()) {
            if (!visible || progressOnly || dialogOpen || a.miniMode) {
                hideButtonTooltip(true);
            } else {
                refreshTooltipForCurrentFocus();
            }
        }
        if (subtitle.isPreviewActive()) {
            subtitle.setTranslationY(0f);
            return;
        }
        int targetPx =
                visible
                        ? a.dp(
                                progressOnly
                                        ? Math.max(modernTv ? 104 : 82, bottomDp + 16)
                                        : Math.max(modernTv ? 176 : 168, bottomDp + 24))
                        : basePx;
        subtitle.setTranslationY(-(targetPx - basePx));
    }
}

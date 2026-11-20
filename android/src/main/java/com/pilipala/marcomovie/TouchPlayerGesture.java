package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.media.AudioManager;
import android.os.Build;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewTreeObserver;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import com.pilipala.marcomovie.hud.SpeedLockCapsule;
import java.util.Locale;

/**
 * Touch gesture controller for phone and tablet playback backed by {@link
 * PlayerGestureStateMachine}: single-tap controls toggle, toggleable release-validated double-tap
 * (center play/pause or fullscreen; left/right 28% seek with 650ms multi-tap combo), mutual-
 * exclusion horizontal seek / brightness / volume drags, and upgraded long-press (>= 350ms) speed
 * boost with horizontal detent stepping (1.25x / 1.5x / 2.0x / 3.0x) and swipe-up speed lock.
 */
final class TouchPlayerGesture implements View.OnTouchListener {
    private final MainActivity a;
    private final LinearLayout hudCard;
    private final TextView hud;
    private final SeekProgressBarView hudProgress;
    private final SpeedLockCapsule speedLockCapsule;
    final PlayerGestureStateMachine fsm;

    private final Rect hitRect = new Rect();
    private VelocityTracker velocityTracker;
    private long lastMoveTimeMs;
    private int startPositionMs, durationMs, targetSeekMs;
    private float startBrightness = 0.5f;
    private float startVolume = 0.5f;
    private float miniDownX, miniDownY;
    private boolean miniTapCandidate;

    private final Runnable fsmTickRunnable = this::handleFsmTick;
    private final Runnable hideNoticeRunnable = this::handleHideNotice;

    private void handleFsmTick() {
        fsm.onTick(SystemClock.uptimeMillis());
        scheduleNextFsmTick();
    }

    private void handleHideNotice() {
        PlayerGestureStateMachine.State st = fsm.getState();
        if (st == PlayerGestureStateMachine.State.IDLE
                || st == PlayerGestureStateMachine.State.LOCKED_IDLE
                || st == PlayerGestureStateMachine.State.SPEED_LOCKED) {
            hideHud();
        }
    }

    static final class SeekProgressBarView extends View {
        private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF rect = new RectF();
        private float progressFraction = 0f;

        SeekProgressBarView(MainActivity activity) {
            super(activity);
            trackPaint.setColor(0x38ffffff);
            fillPaint.setColor(0xff34d399);
        }

        void setProgressFraction(float fraction) {
            float clamped = Math.max(0f, Math.min(1f, fraction));
            if (Math.abs(clamped - progressFraction) > 0.002f) {
                progressFraction = clamped;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) return;
            float r = h / 2f;
            rect.set(0, 0, w, h);
            canvas.drawRoundRect(rect, r, r, trackPaint);
            float fillW = Math.max(h, w * progressFraction);
            rect.set(0, 0, Math.min(w, fillW), h);
            canvas.drawRoundRect(rect, r, r, fillPaint);
        }
    }

    private TouchPlayerGesture(MainActivity activity) {
        this.a = activity;
        this.hudCard = activity.vertical();
        this.hudCard.setGravity(Gravity.CENTER_HORIZONTAL);
        this.hudCard.setPadding(activity.dp(18), activity.dp(10), activity.dp(18), activity.dp(10));
        UiCompat.setBackground(this.hudCard, activity.bg(0xdc181d1b, 20));
        this.hudCard.setVisibility(View.GONE);

        this.hud = activity.text("", 13.5f, MainActivity.WHITE);
        this.hud.setTag("player-touch-hud");
        this.hud.setGravity(Gravity.CENTER);
        this.hudCard.addView(this.hud, new LinearLayout.LayoutParams(-2, -2));

        this.hudProgress = new SeekProgressBarView(activity);
        this.hudProgress.setVisibility(View.GONE);
        LinearLayout.LayoutParams barLp =
                new LinearLayout.LayoutParams(activity.dp(190), activity.dp(5));
        barLp.topMargin = activity.dp(7);
        this.hudCard.addView(this.hudProgress, barLp);

        FrameLayout.LayoutParams lp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        lp.topMargin = activity.dp(36);
        activity.playbackLayer.addView(this.hudCard, lp);

        this.speedLockCapsule = new SpeedLockCapsule(activity);
        boolean reducedTransparency =
                activity.prefs != null
                        && activity.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        this.speedLockCapsule.setAccessibilityFlags(activity.reduced, reducedTransparency);
        FrameLayout.LayoutParams speedLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        speedLp.topMargin = activity.dp(16);
        activity.playbackLayer.addView(this.speedLockCapsule, speedLp);

        this.fsm = new PlayerGestureStateMachine(createListener());
        refreshConfigFromPrefs();
        attachLifecycleGuards(activity.root);
    }

    private void attachLifecycleGuards(View hostRoot) {
        if (hostRoot == null) return;
        final ViewTreeObserver.OnWindowFocusChangeListener focusListener =
                hasFocus -> {
                    if (!hasFocus) {
                        cancelWithReason(
                                a.foreground
                                        ? PlayerGestureStateMachine.InterruptReason
                                                .WINDOW_FOCUS_LOST
                                        : PlayerGestureStateMachine.InterruptReason.BACKGROUND);
                    }
                };
        hostRoot.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {
                        if (Build.VERSION.SDK_INT >= 18) {
                            ViewTreeObserver vto = v.getViewTreeObserver();
                            if (vto != null && vto.isAlive()) {
                                vto.addOnWindowFocusChangeListener(focusListener);
                            }
                        }
                    }

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        if (Build.VERSION.SDK_INT >= 18) {
                            ViewTreeObserver vto = v.getViewTreeObserver();
                            if (vto != null && vto.isAlive()) {
                                vto.removeOnWindowFocusChangeListener(focusListener);
                            }
                        }
                        cancelWithReason(PlayerGestureStateMachine.InterruptReason.EXIT_PLAYER);
                    }
                });
    }

    private PlayerGestureStateMachine.Listener createListener() {
        return new PlayerGestureStateMachine.ListenerAdapter() {
            @Override
            public void onSingleTap() {
                if (a.miniMode) {
                    a.expandPlayback();
                    return;
                }
                if (a.playerLocked) return;
                a.showControls(!a.controlsVisible);
            }

            @Override
            public void onLockedSingleTap() {
                if (!a.miniMode && a.playerLocked) {
                    PlaybackController.toggleUnlockButton(a);
                }
            }

            @Override
            public void onDoubleTapPlayPause() {
                if (a.miniMode || a.playerLocked) return;
                a.togglePlayback();
                a.showControls(true);
            }

            @Override
            public void onDoubleTapFullscreen() {
                if (a.miniMode || a.playerLocked) return;
                a.togglePlayerOrientation();
            }

            @Override
            public void onDoubleTapSeek(int stepMs, int accumulatedMs) {
                if (a.miniMode || a.playerLocked || a.player == null || !a.prepared) return;
                int dur = a.player.getDuration();
                if (dur <= 0) return;
                int cur =
                        a.playbackControls != null
                                ? a.playbackControls.displayPosition(a.player.getCurrentPosition())
                                : a.player.getCurrentPosition();
                int next = Math.max(0, Math.min(dur, cur + stepMs));
                if (a.playbackControls != null) {
                    a.playbackControls.recordUserSeek(next);
                }
                a.player.seekTo(next);
                if (a.playClock != null) {
                    a.playClock.setText(
                            PlaybackController.formatTime(next)
                                    + " / "
                                    + PlaybackController.formatTime(dur));
                }
                int absSec = Math.abs(accumulatedMs) / 1000;
                String dirText = accumulatedMs >= 0 ? "快进 +" : "快退 -";
                showBriefNotice(dirText + absSec + " 秒");
            }

            @Override
            public void onSeekBegin(float downX, float downY) {
                if (a.root != null && a.root.getParent() != null) {
                    a.root.getParent().requestDisallowInterceptTouchEvent(true);
                }
                if (a.player != null && a.prepared) {
                    startPositionMs = a.player.getCurrentPosition();
                    durationMs = a.player.getDuration();
                    targetSeekMs = startPositionMs;
                }
            }

            @Override
            public void onSeekMove(float dx, float stepDx, float rawX, long nowMs) {
                if (a.player == null || !a.prepared || durationMs <= 0) return;
                int width = Math.max(1, a.windowWidth());
                long dtMs = Math.max(1L, nowMs - lastMoveTimeMs);
                lastMoveTimeMs = nowMs;
                float vx = (stepDx * 1000f) / dtMs;
                if (velocityTracker != null) {
                    velocityTracker.computeCurrentVelocity(1000);
                    float trackedVx = velocityTracker.getXVelocity();
                    if (Math.abs(trackedVx) > 10f) vx = trackedVx;
                }
                float speedMul = SeekGesture.linearSeekSpeedMultiplier(vx, width);
                targetSeekMs =
                        SeekGesture.stepLinearSeekTarget(
                                targetSeekMs, durationMs, stepDx, vx, width);
                if (a.playbackControls != null) {
                    a.playbackControls.touchSeeking = true;
                    a.playbackControls.timeline.setProgress(targetSeekMs);
                }
                if (!a.controlsVisible) {
                    PlaybackController.showControls(a, true, true);
                }
                String speedText = String.format(Locale.US, "%.1f×", speedMul);
                if (a.playClock != null) {
                    a.playClock.setText(
                            PlaybackController.formatTime(targetSeekMs)
                                    + " / "
                                    + PlaybackController.formatTime(durationMs));
                }
                if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                    a.playerChrome.seekHint.setText(
                            (dx >= 0 ? "快进 " : "快退 ") + speedText + " · 松手跳转");
                    a.playerChrome.seekHint.setVisibility(View.VISIBLE);
                }
                float frac = durationMs > 0 ? (targetSeekMs / (float) durationMs) : 0f;
                showHud(
                        (dx >= 0 ? "快进至 " : "快退至 ")
                                + PlaybackController.formatTime(targetSeekMs)
                                + " / "
                                + PlaybackController.formatTime(durationMs)
                                + "  ·  "
                                + speedText,
                        frac);
            }

            @Override
            public void onSeekCommit() {
                if (a.playbackControls != null) {
                    a.playbackControls.touchSeeking = false;
                }
                if (a.player != null && a.prepared && durationMs > 0) {
                    if (a.playbackControls != null) {
                        a.playbackControls.recordUserSeek(targetSeekMs);
                    }
                    a.player.seekTo(targetSeekMs);
                    if (a.playClock != null) {
                        a.playClock.setText(
                                PlaybackController.formatTime(targetSeekMs)
                                        + " / "
                                        + PlaybackController.formatTime(durationMs));
                    }
                    if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                        a.playerChrome.seekHint.setText("");
                        a.playerChrome.seekHint.setVisibility(View.GONE);
                    }
                    if (a.playerChrome != null && a.playerChrome.progressOnlyMode) {
                        a.showControls(false);
                    } else {
                        a.scheduleHide();
                    }
                }
                hideHud();
            }

            @Override
            public void onSeekCancel() {
                if (a.playbackControls != null) {
                    a.playbackControls.touchSeeking = false;
                }
                if (a.playerChrome != null && a.playerChrome.seekHint != null) {
                    a.playerChrome.seekHint.setText("");
                    a.playerChrome.seekHint.setVisibility(View.GONE);
                }
                if (a.playerChrome != null && a.playerChrome.progressOnlyMode) {
                    a.showControls(false);
                }
                hideHud();
            }

            @Override
            public void onBrightnessBegin() {
                if (a.root != null && a.root.getParent() != null) {
                    a.root.getParent().requestDisallowInterceptTouchEvent(true);
                }
            }

            @Override
            public void onBrightnessMove(float dy) {
                int height = Math.max(1, a.windowHeight());
                float level = SeekGesture.dragVerticalLevel(startBrightness, dy, height);
                WindowManager.LayoutParams attrs = a.getWindow().getAttributes();
                attrs.screenBrightness = Math.max(0.02f, level);
                a.getWindow().setAttributes(attrs);
                showHud("屏幕亮度 " + Math.round(level * 100) + "%", level);
            }

            @Override
            public void onVolumeBegin() {
                if (a.root != null && a.root.getParent() != null) {
                    a.root.getParent().requestDisallowInterceptTouchEvent(true);
                }
            }

            @Override
            public void onVolumeMove(float dy) {
                int height = Math.max(1, a.windowHeight());
                float level = SeekGesture.dragVerticalLevel(startVolume, dy, height);
                AudioManager audio = (AudioManager) a.getSystemService(Context.AUDIO_SERVICE);
                if (audio != null) {
                    int max = Math.max(1, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
                    int vol = Math.round(level * max);
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0);
                }
                showHud("媒体音量 " + Math.round(level * 100) + "%", level);
            }

            @Override
            public void onVerticalDragEnd() {
                hideHud();
            }

            @Override
            public void onSpeedBoostStart(float speed, int detentIndex) {
                applyPlayerSpeedSafely(speed);
                performTickHaptic();
                hideHud();
                speedLockCapsule.showBoosting(speed, detentIndex, false);
            }

            @Override
            public void onSpeedBoostChanged(float speed, int detentIndex) {
                applyPlayerSpeedSafely(speed);
                performTickHaptic();
                boolean lockReady =
                        fsm.getState() == PlayerGestureStateMachine.State.SPEED_LOCK_READY;
                speedLockCapsule.showBoosting(speed, detentIndex, lockReady);
            }

            @Override
            public void onSpeedLockReadyChanged(boolean lockReady, float speed) {
                performTickHaptic();
                speedLockCapsule.showBoosting(speed, fsm.getCurrentDetentIndex(), lockReady);
            }

            @Override
            public void onSpeedLocked(float lockedSpeed) {
                performTickHaptic();
                speedLockCapsule.showLocked(lockedSpeed, TouchPlayerGesture.this::unlockSpeedLock);
            }

            @Override
            public void onSpeedBoostEnd(float restoredSpeed, boolean cancelled) {
                applyPlayerSpeedSafely(restoredSpeed);
                speedLockCapsule.hide();
            }

            @Override
            public void onSpeedUnlocked(float restoredSpeed) {
                speedLockCapsule.hide();
                if (restoredSpeed > 0f) {
                    applyPlayerSpeedSafely(restoredSpeed);
                    showBriefNotice("已恢复 " + SpeedLockCapsule.formatSpeed(restoredSpeed) + " 播放");
                }
            }
        };
    }

    static void attach(MainActivity activity, View surfaceView) {
        TouchPlayerGesture listener = new TouchPlayerGesture(activity);
        activity.touchPlayerGesture = listener;
        activity.root.setOnTouchListener(listener);
    }

    void updateSafeTop(int safeTopPx) {
        if (speedLockCapsule != null) {
            speedLockCapsule.updateSafeTop(safeTopPx);
        }
    }

    void unlockSpeedLock() {
        fsm.unlockLockedSpeed(SystemClock.uptimeMillis());
        scheduleNextFsmTick();
    }

    void onEpisodeSwitch() {
        cancelWithReason(PlayerGestureStateMachine.InterruptReason.EPISODE_SWITCH);
    }

    void onManualSpeedChanged() {
        cancelWithReason(PlayerGestureStateMachine.InterruptReason.MANUAL_SPEED_CHANGE);
    }

    void onDialogOpened() {
        cancelWithReason(PlayerGestureStateMachine.InterruptReason.DIALOG_OPEN);
    }

    void cancelActiveGesture() {
        cancelWithReason(
                a.playerLocked
                        ? PlayerGestureStateMachine.InterruptReason.SCREEN_LOCKED
                        : PlayerGestureStateMachine.InterruptReason.ACTION_CANCEL);
    }

    private void cancelWithReason(PlayerGestureStateMachine.InterruptReason reason) {
        a.ui.removeCallbacks(fsmTickRunnable);
        a.ui.removeCallbacks(hideNoticeRunnable);
        recycleVelocityTracker();
        fsm.cancel(reason, SystemClock.uptimeMillis());
    }

    private void refreshConfigFromPrefs() {
        PlayerGestureStateMachine.Config cfg = fsm.config();
        cfg.doubleTapCenter = PlayerHudPrefs.getDoubleTapCenter(a);
        cfg.doubleTapSides = PlayerHudPrefs.getDoubleTapSides(a);
        cfg.longPressRestoreMode = PlayerHudPrefs.getLongPressRestoreMode(a);
        boolean reducedTransparency =
                a.prefs != null && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        speedLockCapsule.setAccessibilityFlags(a.reduced, reducedTransparency);
    }

    private void applyPlayerSpeedSafely(float speed) {
        if (a.player != null && a.prepared && speed > 0f) {
            try {
                a.player.setSpeed(speed);
            } catch (Exception ignored) {
            }
        }
    }

    private void performTickHaptic() {
        if (a.root != null) {
            try {
                a.root.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);
            } catch (Exception ignored) {
            }
        }
    }

    private void scheduleNextFsmTick() {
        a.ui.removeCallbacks(fsmTickRunnable);
        long deadline = fsm.nextDeadlineMs();
        if (deadline >= 0L) {
            long delay = Math.max(0L, deadline - SystemClock.uptimeMillis());
            a.ui.postDelayed(fsmTickRunnable, delay);
        }
    }

    private void recycleVelocityTracker() {
        if (velocityTracker != null) {
            velocityTracker.recycle();
            velocityTracker = null;
        }
    }

    void showBriefNotice(String text) {
        a.ui.removeCallbacks(hideNoticeRunnable);
        showHud(text, -1f);
        a.ui.postDelayed(hideNoticeRunnable, 1300L);
    }

    private void showHud(String text, float progressFraction) {
        hud.setText(text);
        if (progressFraction >= 0f) {
            hudProgress.setProgressFraction(progressFraction);
            hudProgress.setVisibility(View.VISIBLE);
        } else {
            hudProgress.setVisibility(View.GONE);
        }
        hudCard.setVisibility(View.VISIBLE);
    }

    private void hideHud() {
        hudCard.setVisibility(View.GONE);
        hudProgress.setVisibility(View.GONE);
    }

    private boolean isTouchInsideView(View view, float rawX, float rawY) {
        if (view == null || !view.isShown()) return false;
        if (!view.getGlobalVisibleRect(hitRect)) return false;
        return hitRect.contains(Math.round(rawX), Math.round(rawY));
    }

    private boolean isTouchInsideControls(float rawX, float rawY) {
        if (speedLockCapsule != null
                && speedLockCapsule.getVisibility() == View.VISIBLE
                && isTouchInsideView(speedLockCapsule, rawX, rawY)) {
            return true;
        }
        if (!a.controlsVisible || a.playerChrome == null) return false;
        return isTouchInsideView(a.playerChrome.dock, rawX, rawY)
                || isTouchInsideView(a.playerChrome.heading, rawX, rawY)
                || isTouchInsideView(a.playerChrome.progress, rawX, rawY)
                || isTouchInsideView(a.playerChrome.lockBtn, rawX, rawY);
    }

    private PlayerGestureStateMachine.Env buildEnv(float rawX, float rawY, boolean downEvent) {
        PlayerGestureStateMachine.Env env = new PlayerGestureStateMachine.Env();
        env.density = a.getResources().getDisplayMetrics().density;
        env.screenWidthPx = Math.max(1, a.windowWidth());
        env.screenHeightPx = Math.max(1, a.windowHeight());
        if (a.playerChrome != null) {
            env.systemGestureInsetLeftPx = a.playerChrome.windowInsets.left;
            env.systemGestureInsetRightPx = a.playerChrome.windowInsets.right;
            env.systemInsetTopPx = a.playerChrome.windowInsets.top;
            env.systemInsetBottomPx = a.playerChrome.windowInsets.bottom;
        }
        env.screenLocked = a.playerLocked;
        boolean inPip = Build.VERSION.SDK_INT >= 24 && a.isInPictureInPictureMode();
        env.miniOrPip = a.miniMode || inPip;
        env.liveStream = a.isLive();
        env.prepared = a.prepared;
        env.playing = a.playing;
        env.durationMs =
                a.player != null && a.prepared ? Math.max(0, a.player.getDuration()) : durationMs;
        env.controlsVisible = a.controlsVisible;
        env.startedInsideControls = downEvent && isTouchInsideControls(rawX, rawY);
        env.userNormalSpeed = a.prefs != null ? a.prefs.getFloat(Prefs.PLAY_SPEED, 1.0f) : 1.0f;
        return env;
    }

    @Override
    public boolean onTouch(View v, MotionEvent event) {
        if (a.miniMode) {
            return handleMiniModeTouch(event);
        }
        long nowMs = SystemClock.uptimeMillis();
        int action = event.getActionMasked();
        int pointerCount = event.getPointerCount();
        int pointerId = event.getPointerId(0);
        float rawX = event.getRawX();
        float rawY = event.getRawY();

        if (action == MotionEvent.ACTION_POINTER_DOWN) {
            cancelWithReason(PlayerGestureStateMachine.InterruptReason.MULTI_TOUCH);
            return true;
        }

        if (action == MotionEvent.ACTION_DOWN) {
            refreshConfigFromPrefs();
            fsm.setScreenLocked(a.playerLocked, nowMs);
            lastMoveTimeMs = nowMs;
            if (velocityTracker == null) {
                velocityTracker = VelocityTracker.obtain();
            } else {
                velocityTracker.clear();
            }
            velocityTracker.addMovement(event);
            if (a.playbackControls != null) {
                a.playbackControls.touchSeeking = false;
            }
            if (a.player != null && a.prepared) {
                startPositionMs = a.player.getCurrentPosition();
                durationMs = a.player.getDuration();
                targetSeekMs = startPositionMs;
            }
            WindowManager.LayoutParams attrs = a.getWindow().getAttributes();
            startBrightness =
                    attrs.screenBrightness >= 0f && attrs.screenBrightness <= 1f
                            ? attrs.screenBrightness
                            : 0.5f;
            AudioManager audio = (AudioManager) a.getSystemService(Context.AUDIO_SERVICE);
            if (audio != null) {
                int max = Math.max(1, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
                int cur = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
                startVolume = cur / (float) max;
            }
            PlayerGestureStateMachine.Env env = buildEnv(rawX, rawY, true);
            boolean accepted = fsm.onPointerDown(pointerId, pointerCount, rawX, rawY, nowMs, env);
            scheduleNextFsmTick();
            // Return false if ignored by edge guard so system back swipe works cleanly.
            return accepted || a.playerLocked;
        }

        if (action == MotionEvent.ACTION_MOVE) {
            if (velocityTracker != null) velocityTracker.addMovement(event);
            PlayerGestureStateMachine.Env env = buildEnv(rawX, rawY, false);
            fsm.onPointerMove(pointerId, pointerCount, rawX, rawY, nowMs, env);
            scheduleNextFsmTick();
            return true;
        }

        if (action == MotionEvent.ACTION_UP) {
            PlayerGestureStateMachine.Env env = buildEnv(rawX, rawY, false);
            fsm.onPointerUp(pointerId, rawX, rawY, nowMs, env);
            recycleVelocityTracker();
            scheduleNextFsmTick();
            return true;
        }

        if (action == MotionEvent.ACTION_CANCEL) {
            cancelWithReason(PlayerGestureStateMachine.InterruptReason.ACTION_CANCEL);
            return true;
        }

        return true;
    }

    private boolean handleMiniModeTouch(MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            miniDownX = event.getRawX();
            miniDownY = event.getRawY();
            miniTapCandidate = true;
            return true;
        }
        if (action == MotionEvent.ACTION_MOVE && miniTapCandidate) {
            float slop = a.dp(PlayerGestureStateMachine.TOUCH_SLOP_DP);
            if (Math.abs(event.getRawX() - miniDownX) > slop
                    || Math.abs(event.getRawY() - miniDownY) > slop) {
                miniTapCandidate = false;
            }
            return true;
        }
        if (action == MotionEvent.ACTION_UP && miniTapCandidate) {
            miniTapCandidate = false;
            a.expandPlayback();
            return true;
        }
        miniTapCandidate = false;
        return true;
    }
}

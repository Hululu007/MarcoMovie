package com.pilipala.marcomovie;

import android.view.KeyEvent;
import com.pilipala.marcomovie.PlayerGestureStateMachine.Env;
import com.pilipala.marcomovie.PlayerGestureStateMachine.InterruptReason;
import com.pilipala.marcomovie.PlayerGestureStateMachine.State;
import com.pilipala.marcomovie.hud.FastForwardScrubCapsule;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import com.pilipala.marcomovie.hud.SkipCountdownPill;
import com.pilipala.marcomovie.hud.SleepTimerSheet;
import com.pilipala.marcomovie.hud.StartSpecBanner;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Pure-JVM deterministic verification suite for M2 Android Player HUD & Touch Gesture State
 * Machine.
 */
public final class PlayerGestureChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) {
            throw new AssertionError("FAILED: " + label);
        }
        checks++;
        System.out.println("PASS " + label);
    }

    private static Env defaultEnv() {
        Env env = new Env();
        env.density = 1.0f; // 1px == 1dp for clean deterministic math
        env.screenWidthPx = 1000f;
        env.screenHeightPx = 500f;
        env.prepared = true;
        env.playing = true;
        env.durationMs = 3_600_000;
        env.userNormalSpeed = 1.25f;
        return env;
    }

    private static final class Spy extends PlayerGestureStateMachine.ListenerAdapter {
        final List<State> states = new ArrayList<>();
        int singleTaps;
        int lockedSingleTaps;
        int doubleTapPlayPauses;
        int doubleTapFullscreens;
        int doubleTapSeekCalls;
        int lastSeekStepMs;
        int lastSeekAccumulatedMs;
        int multiTapEnds;
        int seekBegins;
        int seekMoves;
        int seekCommits;
        int seekCancels;
        int brightnessBegins;
        int brightnessMoves;
        int volumeBegins;
        int volumeMoves;
        int verticalEnds;
        int boostStarts;
        int boostChanges;
        float lastBoostSpeed;
        int lastDetentIndex = -1;
        boolean lastLockReady;
        int lockReadyChanges;
        int speedLocks;
        float lastLockedSpeed;
        int boostEnds;
        float lastRestoredSpeed;
        boolean lastBoostEndCancelled;
        int speedUnlocks;
        float lastUnlockedSpeed;

        @Override
        public void onStateChanged(State from, State to) {
            states.add(to);
        }

        @Override
        public void onSingleTap() {
            singleTaps++;
        }

        @Override
        public void onLockedSingleTap() {
            lockedSingleTaps++;
        }

        @Override
        public void onDoubleTapPlayPause() {
            doubleTapPlayPauses++;
        }

        @Override
        public void onDoubleTapFullscreen() {
            doubleTapFullscreens++;
        }

        @Override
        public void onDoubleTapSeek(int stepMs, int accumulatedMs) {
            doubleTapSeekCalls++;
            lastSeekStepMs = stepMs;
            lastSeekAccumulatedMs = accumulatedMs;
        }

        @Override
        public void onMultiTapSeekEnd() {
            multiTapEnds++;
        }

        @Override
        public void onSeekBegin(float downX, float downY) {
            seekBegins++;
        }

        @Override
        public void onSeekMove(float dx, float stepDx, float rawX, long nowMs) {
            seekMoves++;
        }

        @Override
        public void onSeekCommit() {
            seekCommits++;
        }

        @Override
        public void onSeekCancel() {
            seekCancels++;
        }

        @Override
        public void onBrightnessBegin() {
            brightnessBegins++;
        }

        @Override
        public void onBrightnessMove(float dy) {
            brightnessMoves++;
        }

        @Override
        public void onVolumeBegin() {
            volumeBegins++;
        }

        @Override
        public void onVolumeMove(float dy) {
            volumeMoves++;
        }

        @Override
        public void onVerticalDragEnd() {
            verticalEnds++;
        }

        @Override
        public void onSpeedBoostStart(float speed, int detentIndex) {
            boostStarts++;
            lastBoostSpeed = speed;
            lastDetentIndex = detentIndex;
        }

        @Override
        public void onSpeedBoostChanged(float speed, int detentIndex) {
            boostChanges++;
            lastBoostSpeed = speed;
            lastDetentIndex = detentIndex;
        }

        @Override
        public void onSpeedLockReadyChanged(boolean lockReady, float speed) {
            lockReadyChanges++;
            lastLockReady = lockReady;
            lastBoostSpeed = speed;
        }

        @Override
        public void onSpeedLocked(float lockedSpeed) {
            speedLocks++;
            lastLockedSpeed = lockedSpeed;
        }

        @Override
        public void onSpeedBoostEnd(float restoredSpeed, boolean cancelled) {
            boostEnds++;
            lastRestoredSpeed = restoredSpeed;
            lastBoostEndCancelled = cancelled;
        }

        @Override
        public void onSpeedUnlocked(float restoredSpeed) {
            speedUnlocks++;
            lastUnlockedSpeed = restoredSpeed;
        }
    }

    public static void main(String[] args) {
        testSingleTapAndDoubleTapCenterModes();
        testSecondTapDragDoesNotTriggerDoubleTap();
        testMultiTapSideSeekComboNeverTogglesControls();
        testEdgeAndSystemVerticalGuards();
        testMutualExclusionDragsCancelLongPress();
        testLongPressSpeedDetentsAndReleaseRestore();
        testLongPressAlreadyAt2xStartsAt3x();
        testSwipeUpLockHysteresisAndUnlockMatrix();
        testAllInterruptionSafetyResets();
        testLockedIdleAndLiveStreamGuards();
        testStartSpecDualChannelFusionAndAntiOverlap();
        testSkipCountdownControllerAndTvKeyRouting();
        testSleepTimerControllerPresetsWarningExtendAndExpiry();
        testPrefsNormalizersAndScrubFormatting();
        System.out.println("ALL PASS (" + checks + " Android M2 HUD & gesture checks)");
    }

    private static void testSingleTapAndDoubleTapCenterModes() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        check(fsm.onPointerDown(0, 1, 500, 250, 1000, env), "Center pointer down accepted");
        check(fsm.getState() == State.DOWN_PENDING, "Enters DOWN_PENDING on pointer down");
        fsm.onPointerUp(0, 504, 252, 1080, env);
        check(fsm.getState() == State.WAIT_DOUBLE_TAP, "Short release enters WAIT_DOUBLE_TAP");
        fsm.onTick(1339);
        check(spy.singleTaps == 0, "Single tap waits full 260ms window");
        fsm.onTick(1340);
        check(spy.singleTaps == 1 && fsm.getState() == State.IDLE, "Single tap fires at 260ms");

        // Double-tap center -> play/pause (must trigger on UP, not DOWN)
        fsm.onPointerDown(0, 1, 500, 250, 2000, env);
        fsm.onPointerUp(0, 500, 250, 2050, env);
        fsm.onPointerDown(0, 1, 510, 255, 2150, env);
        check(
                fsm.getState() == State.SECOND_TAP_DOWN && spy.doubleTapPlayPauses == 0,
                "Second tap down enters SECOND_TAP_DOWN without firing before UP");
        fsm.onPointerUp(0, 512, 255, 2210, env);
        check(
                spy.doubleTapPlayPauses == 1 && fsm.getState() == State.IDLE,
                "Center double-tap fires play/pause on second UP");

        // Toggle center mode to fullscreen
        fsm.config().doubleTapCenter = PlayerHudPrefs.CENTER_FULLSCREEN;
        fsm.onPointerDown(0, 1, 500, 250, 3000, env);
        fsm.onPointerUp(0, 500, 250, 3040, env);
        fsm.onPointerDown(0, 1, 500, 250, 3120, env);
        fsm.onPointerUp(0, 500, 250, 3160, env);
        check(spy.doubleTapFullscreens == 1, "Center double-tap supports fullscreen toggle");

        // Far-apart second tap (> 42dp) settles first single tap then starts fresh press
        fsm.config().doubleTapCenter = PlayerHudPrefs.CENTER_PLAY_PAUSE;
        int prevSingle = spy.singleTaps;
        fsm.onPointerDown(0, 1, 450, 250, 4000, env);
        fsm.onPointerUp(0, 450, 250, 4040, env);
        fsm.onPointerDown(0, 1, 550, 250, 4120, env);
        check(
                spy.singleTaps == prevSingle + 1 && fsm.getState() == State.DOWN_PENDING,
                "Far-apart second tap settles first single tap and begins fresh DOWN_PENDING");
        fsm.cancel(InterruptReason.ACTION_CANCEL, 4130);
    }

    private static void testSecondTapDragDoesNotTriggerDoubleTap() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        fsm.onPointerDown(0, 1, 500, 250, 1000, env);
        fsm.onPointerUp(0, 500, 250, 1050, env);
        fsm.onPointerDown(0, 1, 500, 250, 1150, env);
        check(fsm.getState() == State.SECOND_TAP_DOWN, "Entered SECOND_TAP_DOWN");
        fsm.onPointerMove(0, 1, 530, 252, 1180, env);
        check(
                fsm.getState() == State.HORIZONTAL_SEEK && spy.seekBegins == 1,
                "Horizontal drag from SECOND_TAP_DOWN transitions to HORIZONTAL_SEEK");
        fsm.onPointerUp(0, 560, 252, 1220, env);
        check(
                spy.seekCommits == 1 && spy.doubleTapPlayPauses == 0 && spy.doubleTapSeekCalls == 0,
                "Drag from second tap commits seek and never falsely fires double-tap");
    }

    private static void testMultiTapSideSeekComboNeverTogglesControls() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        // Double tap on left 28% (x = 150 / 1000) -> -10s
        fsm.onPointerDown(0, 1, 150, 250, 1000, env);
        fsm.onPointerUp(0, 150, 250, 1040, env);
        fsm.onPointerDown(0, 1, 152, 250, 1140, env);
        fsm.onPointerUp(0, 152, 250, 1180, env);
        check(
                fsm.getState() == State.MULTI_TAP_SEEK_WINDOW
                        && spy.doubleTapSeekCalls == 1
                        && spy.lastSeekStepMs == -10000
                        && spy.lastSeekAccumulatedMs == -10000,
                "Left-28% double-tap triggers -10s and enters MULTI_TAP_SEEK_WINDOW");

        // 3rd tap (odd!) within 650ms accumulates -20s without toggling controls
        fsm.onPointerDown(0, 1, 160, 250, 1500, env);
        fsm.onPointerUp(0, 160, 250, 1540, env);
        check(
                fsm.getState() == State.MULTI_TAP_SEEK_WINDOW
                        && spy.doubleTapSeekCalls == 2
                        && spy.lastSeekAccumulatedMs == -20000
                        && spy.singleTaps == 0,
                "3rd tap inside 650ms accumulates -20s without toggling controls");

        // Timeout after 650ms ends window cleanly without toggling controls
        fsm.onTick(1540 + 650);
        check(
                fsm.getState() == State.IDLE && spy.multiTapEnds == 1 && spy.singleTaps == 0,
                "Multi-tap seek window expires cleanly to IDLE with zero false single-taps");

        // Right-28% with 15s step, then tapping opposite side ends combo cleanly
        fsm.config().doubleTapSides = PlayerHudPrefs.SIDES_SEEK_15S;
        fsm.onPointerDown(0, 1, 850, 250, 3000, env);
        fsm.onPointerUp(0, 850, 250, 3040, env);
        fsm.onPointerDown(0, 1, 855, 250, 3120, env);
        fsm.onPointerUp(0, 855, 250, 3160, env);
        check(spy.lastSeekAccumulatedMs == 15000, "Right-28% double-tap respects seek_15s config");
        fsm.onPointerDown(0, 1, 150, 250, 3300, env);
        check(
                fsm.getState() == State.IDLE && spy.singleTaps == 0,
                "Tapping opposite side ends multi-tap combo without toggling controls");

        // Side mode toggled to full-screen play/pause
        fsm.config().doubleTapSides = PlayerHudPrefs.SIDES_PLAY_PAUSE;
        fsm.onPointerDown(0, 1, 150, 250, 5000, env);
        fsm.onPointerUp(0, 150, 250, 5040, env);
        fsm.onPointerDown(0, 1, 150, 250, 5120, env);
        fsm.onPointerUp(0, 150, 250, 5160, env);
        check(
                spy.doubleTapPlayPauses == 1,
                "Side double-tap can be toggled back to full-screen play/pause");
    }

    private static void testEdgeAndSystemVerticalGuards() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.systemGestureInsetLeftPx = 32f;
        env.systemGestureInsetRightPx = 30f;

        check(!fsm.onPointerDown(0, 1, 20, 250, 1000, env), "Left edge back guard rejects touch");
        check(
                !fsm.onPointerDown(0, 1, 31, 250, 1010, env),
                "System gesture left inset (>24dp) rejects touch");
        check(!fsm.onPointerDown(0, 1, 980, 250, 1020, env), "Right edge back guard rejects touch");
        check(!fsm.onPointerDown(0, 1, 500, 20, 1030, env), "Top vertical guard (<28dp) rejects");
        check(
                !fsm.onPointerDown(0, 1, 500, 480, 1040, env),
                "Bottom vertical guard (>h-28dp) rejects");

        env.startedInsideControls = true;
        check(
                !fsm.onPointerDown(0, 1, 500, 250, 1050, env),
                "Touch starting inside visible controls/dock is ignored");
        check(fsm.getState() == State.IDLE, "Ignored guards leave FSM in IDLE");
    }

    private static void testMutualExclusionDragsCancelLongPress() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();

        // Left half vertical drag -> brightness, cancels long-press
        fsm.onPointerDown(0, 1, 250, 250, 1000, env);
        fsm.onPointerMove(0, 1, 252, 225, 1100, env);
        check(
                fsm.getState() == State.VERTICAL_BRIGHTNESS
                        && !fsm.isLongPressArmed()
                        && spy.brightnessBegins == 1,
                "Left vertical drag enters VERTICAL_BRIGHTNESS and disarms long-press");
        fsm.onTick(1600);
        check(spy.boostStarts == 0, "Long-press never fires during brightness drag");
        fsm.onPointerUp(0, 252, 180, 1650, env);
        check(
                fsm.getState() == State.IDLE && spy.verticalEnds == 1,
                "Brightness drag ends cleanly");

        // Right half vertical drag -> volume
        fsm.onPointerDown(0, 1, 750, 250, 2000, env);
        fsm.onPointerMove(0, 1, 752, 220, 2080, env);
        check(
                fsm.getState() == State.VERTICAL_VOLUME && spy.volumeBegins == 1,
                "Right vertical drag enters VERTICAL_VOLUME");
        fsm.onPointerUp(0, 752, 190, 2200, env);

        // Horizontal seek before 350ms -> seek, cancels long-press, commits single seek on UP
        fsm.onPointerDown(0, 1, 500, 250, 3000, env);
        fsm.onPointerMove(0, 1, 530, 252, 3100, env);
        check(fsm.getState() == State.HORIZONTAL_SEEK, "Horizontal drag enters HORIZONTAL_SEEK");
        fsm.onTick(3600);
        check(spy.boostStarts == 0, "Long-press never fires during horizontal seek");
        fsm.onPointerUp(0, 620, 252, 3650, env);
        check(spy.seekCommits == 1, "Horizontal seek commits single seekTo on UP");
    }

    private static void testLongPressSpeedDetentsAndReleaseRestore() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 1.25f;

        fsm.onPointerDown(0, 1, 500, 250, 1000, env);
        fsm.onTick(1349);
        check(
                fsm.getState() == State.DOWN_PENDING && spy.boostStarts == 0,
                "Stationary hold < 350ms does not activate speed boost");
        fsm.onTick(1350);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED
                        && spy.boostStarts == 1
                        && Math.abs(spy.lastBoostSpeed - 2.0f) < 0.001f
                        && spy.lastDetentIndex == 2,
                "Stationary hold >= 350ms activates LONG_PRESS_SPEED at 2.0x");

        // Slide right +36dp -> 3.0x
        fsm.onPointerMove(0, 1, 536, 250, 1400, env);
        check(
                Math.abs(spy.lastBoostSpeed - 3.0f) < 0.001f && spy.lastDetentIndex == 3,
                "Horizontal slide +36dp steps up to 3.0x");

        // Slide left -36dp from anchor -> 1.5x
        fsm.onPointerMove(0, 1, 464, 250, 1450, env);
        check(
                Math.abs(spy.lastBoostSpeed - 1.5f) < 0.001f && spy.lastDetentIndex == 1,
                "Horizontal slide -36dp from anchor steps down to 1.5x");

        // Slide left -72dp from anchor -> 1.25x (clamped)
        fsm.onPointerMove(0, 1, 400, 250, 1500, env);
        check(
                Math.abs(spy.lastBoostSpeed - 1.25f) < 0.001f && spy.lastDetentIndex == 0,
                "Horizontal slide <= -72dp clamps to 1.25x");

        // Release without swipe-up restores userNormalSpeed (1.25x)
        fsm.onPointerUp(0, 400, 250, 1550, env);
        check(
                fsm.getState() == State.IDLE
                        && !fsm.isSpeedLocked()
                        && spy.boostEnds == 1
                        && !spy.lastBoostEndCancelled
                        && Math.abs(spy.lastRestoredSpeed - 1.25f) < 0.001f,
                "Release without lock restores userNormalSpeed (1.25x)");

        // Restore mode = "1.0x"
        fsm.config().longPressRestoreMode = PlayerHudPrefs.RESTORE_ONE_X;
        fsm.onPointerDown(0, 1, 500, 250, 2000, env);
        fsm.onTick(2350);
        fsm.onPointerUp(0, 500, 250, 2400, env);
        check(
                Math.abs(spy.lastRestoredSpeed - 1.0f) < 0.001f,
                "Restore mode 1.0x forces 1.0x on release");
    }

    private static void testLongPressAlreadyAt2xStartsAt3x() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 2.0f;

        fsm.onPointerDown(0, 1, 500, 250, 1000, env);
        fsm.onTick(1350);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED
                        && Math.abs(spy.lastBoostSpeed - 3.0f) < 0.001f
                        && spy.lastDetentIndex == 3,
                "Long-press when userNormalSpeed == 2.0x auto-elevates initial boost to 3.0x");
        fsm.onPointerUp(0, 500, 250, 1400, env);
        check(
                Math.abs(spy.lastRestoredSpeed - 2.0f) < 0.001f,
                "Releasing 3.0x boost restores userNormalSpeed 2.0x");
    }

    private static void testSwipeUpLockHysteresisAndUnlockMatrix() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.userNormalSpeed = 1.5f;

        fsm.onPointerDown(0, 1, 500, 300, 1000, env);
        fsm.onTick(1350);
        // Move right to 3.0x, then swipe up -47dp (not yet locked)
        fsm.onPointerMove(0, 1, 540, 253, 1400, env);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED,
                "Swipe up -47dp does not yet trigger SPEED_LOCK_READY");

        // Swipe up -48dp -> SPEED_LOCK_READY
        fsm.onPointerMove(0, 1, 540, 252, 1420, env);
        check(
                fsm.getState() == State.SPEED_LOCK_READY && spy.lastLockReady,
                "Swipe up dy <= -48dp enters SPEED_LOCK_READY");

        // Pull back to -40dp -> hysteresis keeps SPEED_LOCK_READY
        fsm.onPointerMove(0, 1, 540, 260, 1440, env);
        check(
                fsm.getState() == State.SPEED_LOCK_READY,
                "Hysteresis retains SPEED_LOCK_READY at dy = -40dp");

        // Pull back to -35dp -> exits back to LONG_PRESS_SPEED
        fsm.onPointerMove(0, 1, 540, 265, 1460, env);
        check(
                fsm.getState() == State.LONG_PRESS_SPEED && !spy.lastLockReady,
                "Pulling below -36dp cancels SPEED_LOCK_READY back to LONG_PRESS_SPEED");

        // Swipe up again to -54dp and release -> SPEED_LOCKED at 3.0x
        fsm.onPointerMove(0, 1, 540, 246, 1480, env);
        fsm.onPointerUp(0, 540, 246, 1500, env);
        check(
                fsm.getState() == State.SPEED_LOCKED
                        && fsm.isSpeedLocked()
                        && spy.speedLocks == 1
                        && Math.abs(spy.lastLockedSpeed - 3.0f) < 0.001f,
                "Releasing inside lock zone enters SPEED_LOCKED at 3.0x");

        // Tap unlock capsule -> restores 1.5x and returns IDLE
        fsm.unlockLockedSpeed(2000);
        check(
                fsm.getState() == State.IDLE
                        && !fsm.isSpeedLocked()
                        && spy.speedUnlocks == 1
                        && Math.abs(spy.lastUnlockedSpeed - 1.5f) < 0.001f,
                "Clicking unlock capsule restores userNormalSpeed (1.5x) and exits SPEED_LOCKED");

        // Auto-unlock matrix: episode switch, exit, background, lock, multi-touch, PiP, manual
        InterruptReason[] autoUnlockReasons = {
            InterruptReason.EPISODE_SWITCH,
            InterruptReason.EXIT_PLAYER,
            InterruptReason.BACKGROUND,
            InterruptReason.SCREEN_LOCKED,
            InterruptReason.MULTI_TOUCH,
            InterruptReason.PIP_OR_MINI,
            InterruptReason.MANUAL_SPEED_CHANGE
        };
        long t = 3000;
        for (InterruptReason reason : autoUnlockReasons) {
            fsm.setScreenLocked(false, t);
            fsm.onPointerDown(0, 1, 500, 300, t, env);
            fsm.onTick(t + 350);
            fsm.onPointerMove(0, 1, 500, 245, t + 400, env);
            fsm.onPointerUp(0, 500, 245, t + 420, env);
            check(fsm.isSpeedLocked(), "Precondition locked before " + reason);
            int prevUnlocks = spy.speedUnlocks;
            fsm.cancel(reason, t + 500);
            boolean expectedUnlock = spy.speedUnlocks == prevUnlocks + 1;
            boolean expectedSpeed =
                    reason == InterruptReason.MANUAL_SPEED_CHANGE
                            ? spy.lastUnlockedSpeed < 0f
                            : Math.abs(spy.lastUnlockedSpeed - 1.5f) < 0.001f;
            check(
                    !fsm.isSpeedLocked() && expectedUnlock && expectedSpeed,
                    "SPEED_LOCKED auto-unlocks cleanly on " + reason);
            t += 1000;
        }
    }

    private static void testAllInterruptionSafetyResets() {
        InterruptReason[] reasons = {
            InterruptReason.ACTION_CANCEL,
            InterruptReason.MULTI_TOUCH,
            InterruptReason.WINDOW_FOCUS_LOST,
            InterruptReason.BACKGROUND,
            InterruptReason.AUDIO_FOCUS_LOST,
            InterruptReason.PIP_OR_MINI,
            InterruptReason.DIALOG_OPEN,
            InterruptReason.EPISODE_SWITCH,
            InterruptReason.SCREEN_LOCKED
        };
        for (InterruptReason reason : reasons) {
            Spy spy = new Spy();
            PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
            Env env = defaultEnv();
            env.userNormalSpeed = 1.25f;

            // Interrupt during SPEED_LOCK_READY: must NOT lock, MUST restore 1.25x
            fsm.onPointerDown(0, 1, 500, 300, 1000, env);
            fsm.onTick(1350);
            fsm.onPointerMove(0, 1, 500, 240, 1400, env);
            check(fsm.getState() == State.SPEED_LOCK_READY, "In SPEED_LOCK_READY before " + reason);
            fsm.cancel(reason, 1450);
            State expectedEnd =
                    reason == InterruptReason.SCREEN_LOCKED ? State.LOCKED_IDLE : State.IDLE;
            check(
                    fsm.getState() == expectedEnd
                            && !fsm.isSpeedLocked()
                            && spy.boostEnds == 1
                            && spy.lastBoostEndCancelled
                            && Math.abs(spy.lastRestoredSpeed - 1.25f) < 0.001f
                            && spy.states.contains(State.CANCELLED),
                    "Interrupt " + reason + " during SPEED_LOCK_READY cancels & restores 1.25x");
        }

        // Interrupt during HORIZONTAL_SEEK discards preview without committing seek
        Spy seekSpy = new Spy();
        PlayerGestureStateMachine seekFsm = new PlayerGestureStateMachine(seekSpy);
        Env env = defaultEnv();
        seekFsm.onPointerDown(0, 1, 500, 250, 1000, env);
        seekFsm.onPointerMove(0, 1, 560, 250, 1050, env);
        seekFsm.onPointerDown(1, 2, 600, 250, 1080, env); // 2nd finger multi-touch interrupt
        check(
                seekFsm.getState() == State.IDLE
                        && seekSpy.seekCancels == 1
                        && seekSpy.seekCommits == 0,
                "Multi-touch during HORIZONTAL_SEEK cancels preview without committing seekTo");
    }

    private static void testLockedIdleAndLiveStreamGuards() {
        Spy spy = new Spy();
        PlayerGestureStateMachine fsm = new PlayerGestureStateMachine(spy);
        Env env = defaultEnv();
        env.screenLocked = true;
        fsm.setScreenLocked(true, 1000);
        check(fsm.getState() == State.LOCKED_IDLE, "setScreenLocked(true) enters LOCKED_IDLE");

        fsm.onPointerDown(0, 1, 500, 250, 1100, env);
        fsm.onPointerUp(0, 502, 251, 1160, env);
        check(
                spy.lockedSingleTaps == 1 && spy.singleTaps == 0,
                "Single tap in LOCKED_IDLE toggles unlock capsule only");

        fsm.onPointerDown(0, 1, 500, 250, 1500, env);
        fsm.onTick(2000);
        fsm.onPointerMove(0, 1, 700, 250, 2050, env);
        fsm.onPointerUp(0, 700, 250, 2100, env);
        check(
                spy.boostStarts == 0 && spy.seekBegins == 0,
                "LOCKED_IDLE blocks long-press speed boost and horizontal seek");

        // Live stream: blocks horizontal seek & long-press speed boost
        fsm.setScreenLocked(false, 3000);
        env.screenLocked = false;
        env.liveStream = true;
        env.durationMs = 0;
        fsm.onPointerDown(0, 1, 500, 250, 3100, env);
        fsm.onTick(3600);
        check(spy.boostStarts == 0, "Live stream blocks long-press speed boost");
        fsm.onPointerMove(0, 1, 600, 250, 3650, env);
        check(
                fsm.getState() != State.HORIZONTAL_SEEK && spy.seekBegins == 0,
                "Live stream blocks horizontal seek");
    }

    private static void testStartSpecDualChannelFusionAndAntiOverlap() {
        // 960x540 video on "4K专线" line MUST NOT mislabel 4K!
        List<StartSpecBanner.Badge> lowRes =
                StartSpecBanner.fuseSpecBadges(
                        Arrays.asList("H.264", "AAC"), 960, 540, "4K专线 · 超清", "第01集 4K");
        boolean has4k = false;
        boolean hasSd = false;
        for (StartSpecBanner.Badge b : lowRes) {
            if ("4K".equals(b.label)) has4k = true;
            if ("SD".equals(b.label)) hasSd = true;
        }
        check(
                !has4k && hasSd,
                "Dual-channel fusion prevents 960x540 stream on '4K专线' from mislabeling 4K");

        // 3840x2160 stream with DV + Atmos + REMUX metadata -> 4K, DV · ATMOS, REMUX, HEVC (<= 5)
        List<StartSpecBanner.Badge> uhd =
                StartSpecBanner.fuseSpecBadges(
                        Arrays.asList("Dolby Vision", "Dolby Atmos", "HEVC"),
                        3840,
                        2160,
                        "原盘 REMUX 专线",
                        "S01E01");
        List<String> labels = new ArrayList<>();
        for (StartSpecBanner.Badge b : uhd) labels.add(b.label);
        check(
                labels.contains("4K")
                        && labels.contains("DV · ATMOS")
                        && labels.contains("REMUX")
                        && labels.contains("HEVC")
                        && labels.size() <= StartSpecBanner.MAX_BADGES,
                "Dual-channel fusion combines DV + Atmos into DV · ATMOS and preserves 4K/REMUX");

        // Anti-overlap safe margins
        int[] hiddenMargins = StartSpecBanner.computeSafeMargins(40, 24, 120, false, 1.0f);
        check(
                hiddenMargins[0] == 52 && hiddenMargins[1] == 36,
                "StartSpecBanner hidden-controls margins respect safeLeft+12dp and safeTop+12dp");
        int[] visibleMargins = StartSpecBanner.computeSafeMargins(40, 24, 120, true, 1.0f);
        check(
                visibleMargins[1] == 130,
                "StartSpecBanner visible-controls margin shifts below topHeaderBottom+10dp");
    }

    private static void testSkipCountdownControllerAndTvKeyRouting() {
        SkipCountdownPill.Controller ctl = new SkipCountdownPill.Controller();
        ctl.start(true, 95_000, 1000L, true);
        check(
                ctl.isActive()
                        && ctl.isIntro()
                        && ctl.ownsTvFocus()
                        && ctl.getRemainingSecondsCeil() == 3,
                "SkipCountdown starts 3s active countdown owning TV focus");
        check(!ctl.tick(2500L) && ctl.getRemainingSecondsCeil() == 2, "Countdown at 1.5s shows 2s");
        check(
                ctl.tick(4000L)
                        && !ctl.isActive()
                        && !ctl.ownsTvFocus()
                        && ctl.getState() == SkipCountdownPill.Controller.STATE_SKIPPED,
                "Countdown expires at 3000ms and releases TV focus");

        // Cancel via TV directional/back keys
        ctl.start(false, 2_500_000, 5000L, true);
        check(
                SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_DPAD_CENTER) == 1
                        && SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_ENTER) == 1,
                "TV confirm keys map to immediate skip");
        check(
                SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_BACK) == -1
                        && SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_DPAD_LEFT)
                                == -1
                        && SkipCountdownPill.Controller.classifyTvKey(KeyEvent.KEYCODE_DPAD_UP)
                                == -1,
                "TV directional and Back keys map to immediate cancel");
        check(
                ctl.cancel()
                        && !ctl.isActive()
                        && !ctl.ownsTvFocus()
                        && ctl.getState() == SkipCountdownPill.Controller.STATE_CANCELLED,
                "Canceling countdown clears active state and releases TV focus");
    }

    private static void testSleepTimerControllerPresetsWarningExtendAndExpiry() {
        SleepTimerSheet.Controller sleep = new SleepTimerSheet.Controller();
        check(!sleep.isActive() && sleep.getMode() == SleepTimerSheet.MODE_OFF, "Cold-start OFF");

        sleep.selectPreset(SleepTimerSheet.MODE_15M, 10_000L);
        check(
                sleep.isActive() && sleep.remainingMs(10_000L) == 900_000L,
                "15m preset schedules 900,000ms countdown");
        check(
                !sleep.shouldShowPreExpiryWarning(10_000L + 869_000L),
                "No pre-expiry warning at 31s remaining");
        check(
                sleep.shouldShowPreExpiryWarning(10_000L + 870_000L),
                "Pre-expiry warning triggers at <= 30s remaining");

        // Extend 15 minutes
        sleep.extend15Minutes(10_000L + 875_000L);
        check(
                !sleep.shouldShowPreExpiryWarning(10_000L + 875_000L)
                        && sleep.remainingMs(10_000L + 875_000L) == 925_000L,
                "Extending sleep timer adds 15 minutes and dismisses warning");

        // Expiry
        check(
                sleep.tick(10_000L + 1_800_000L) && !sleep.isActive() && sleep.isExpired(),
                "Sleep timer expires at deadline and turns off");

        // End of episode mode
        sleep.selectPreset(SleepTimerSheet.MODE_END_OF_EPISODE, 5_000_000L);
        check(
                sleep.isEndOfEpisodeMode() && !sleep.tick(9_000_000L),
                "End-of-episode mode does not expire on wall clock");
        check(
                sleep.onEpisodeCompleted() && !sleep.isActive(),
                "End-of-episode mode triggers cleanly on episode completion");
    }

    private static void testPrefsNormalizersAndScrubFormatting() {
        check(
                PlayerHudPrefs.CENTER_PLAY_PAUSE.equals(
                        PlayerHudPrefs.normalizeDoubleTapCenter("invalid")),
                "Unknown doubleTapCenter falls back to play_pause");
        check(
                PlayerHudPrefs.SIDES_SEEK_10S.equals(
                        PlayerHudPrefs.normalizeDoubleTapSides("invalid")),
                "Unknown doubleTapSides falls back to seek_10s");
        check(
                PlayerHudPrefs.RESTORE_PREVIOUS.equals(
                        PlayerHudPrefs.normalizeLongPressRestoreMode("invalid")),
                "Unknown longPressRestoreMode falls back to previous");
        check(
                "1:05:09".equals(FastForwardScrubCapsule.formatClock(3_909_000))
                        && "+00:45".equals(FastForwardScrubCapsule.formatSignedOffset(45_000))
                        && "-01:30".equals(FastForwardScrubCapsule.formatSignedOffset(-90_000)),
                "TV scrub capsule formats hours, minutes, and signed offsets accurately");
        // Verify null-safe fallback for empty track badges
        check(
                StartSpecBanner.fuseSpecBadges(Collections.emptyList(), 0, 0, "", "").isEmpty(),
                "Empty track & metadata fusion returns empty list safely");
    }
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Locale;

/**
 * Lightweight first-play gesture hint capsule mounted above the player bottom control bar.
 *
 * <p>Displays at most {@link Policy#MAX_SHOW_COUNT} (3) times across playback sessions and offers a
 * one-tap "不再提示 / Don't show again" button. Backed by {@link OnboardingScreen#PREFS_FILE} so
 * {@code Prefs.java} remains untouched.
 */
public final class FirstPlayGestureHint extends LinearLayout {

    public static final int MAX_SHOW_COUNT = 3;
    public static final long MIN_DWELL_MS = 2000L;
    public static final long AUTO_DISMISS_MS = 4500L;

    /** Pure-Java frequency cap and copy policy shared by Android runtime and JVM checks. */
    public static final class Policy {
        private Policy() {}

        public static boolean shouldShow(OnboardingScreen.Store store) {
            if (store == null) {
                return false;
            }
            if (store.getBoolean(OnboardingScreen.KEY_PLAY_HINT_DISMISSED, false)) {
                return false;
            }
            return store.getInt(OnboardingScreen.KEY_PLAY_HINT_SHOWN_COUNT, 0) < MAX_SHOW_COUNT;
        }

        public static int getShownCount(OnboardingScreen.Store store) {
            return store == null
                    ? 0
                    : Math.max(0, store.getInt(OnboardingScreen.KEY_PLAY_HINT_SHOWN_COUNT, 0));
        }

        public static boolean isDismissed(OnboardingScreen.Store store) {
            return store != null
                    && store.getBoolean(OnboardingScreen.KEY_PLAY_HINT_DISMISSED, false);
        }

        /** Records a completed display (after 2s dwell) up to {@link #MAX_SHOW_COUNT}. */
        public static int recordShown(OnboardingScreen.Store store) {
            if (store == null) {
                return 0;
            }
            int next = Math.min(MAX_SHOW_COUNT, getShownCount(store) + 1);
            store.putInt(OnboardingScreen.KEY_PLAY_HINT_SHOWN_COUNT, next);
            return next;
        }

        /** Permanently suppresses automatic display until user replays onboarding from Settings. */
        public static void dismissForever(OnboardingScreen.Store store) {
            if (store != null) {
                store.putBoolean(OnboardingScreen.KEY_PLAY_HINT_DISMISSED, true);
            }
        }

        public static String hintCopy(boolean tvMode, boolean chinese) {
            if (tvMode) {
                return chinese
                        ? "长按左右键加速快进/快退 · 松手即播 · 返回键取消"
                        : "Hold Left/Right to scrub · Release to play · Back to cancel";
            }
            return chinese
                    ? "长按 2.0× 倍速 · 左右滑调速 · 上滑锁定 · 两侧双击快进快退"
                    : "Hold 2.0× speed · Slide to adjust · Swipe up to lock · Double-tap sides to seek";
        }

        public static String dismissLabel(boolean chinese) {
            return chinese ? "知道了 / 不再提示" : "Got it / Don't show again";
        }
    }

    private final OnboardingScreen.Store store;
    private final boolean zh;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final TextView messageView;
    private final TextView dismissButton;
    private Runnable dwellTask;
    private Runnable autoHideTask;
    private boolean countedThisSession;

    public FirstPlayGestureHint(Context context) {
        this(context, new OnboardingScreen.SharedPrefsStore(context), isChineseLocale());
    }

    public FirstPlayGestureHint(Context context, OnboardingScreen.Store store, boolean chinese) {
        super(context);
        this.store = store;
        this.zh = chinese;

        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        setVisibility(GONE);
        setPadding(dp(14), dp(8), dp(10), dp(8));

        this.messageView = new TextView(context);
        messageView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f);
        messageView.setTextColor(0xFFF5F5F7);
        LinearLayout.LayoutParams msgLp =
                new LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
        msgLp.rightMargin = dp(10);
        addView(messageView, msgLp);

        this.dismissButton = new TextView(context);
        dismissButton.setText(Policy.dismissLabel(zh));
        dismissButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f);
        dismissButton.setTypeface(Typeface.DEFAULT_BOLD);
        dismissButton.setTextColor(0xFF64D2FF);
        dismissButton.setFocusable(true);
        dismissButton.setClickable(true);
        dismissButton.setPadding(dp(10), dp(5), dp(10), dp(5));
        GradientDrawable btnBg = new GradientDrawable();
        btnBg.setColor(0x2E0A84FF);
        btnBg.setCornerRadius(dp(14));
        btnBg.setStroke(dp(1), 0x665AC8FA);
        UiCompat.setBackground(dismissButton, btnBg);
        addView(dismissButton);
    }

    /**
     * Shows the gesture hint capsule if frequency cap allows.
     *
     * @return {@code true} if the hint became visible; {@code false} if suppressed by policy.
     */
    public boolean showIfEligible(
            boolean tvMode,
            final boolean reduceMotion,
            boolean reduceTransparency,
            final Runnable onDismissed) {
        cancelTimers();
        if (!Policy.shouldShow(store)) {
            setVisibility(GONE);
            return false;
        }
        countedThisSession = false;
        applySurface(reduceTransparency);
        messageView.setText(Policy.hintCopy(tvMode, zh));

        dismissButton.setOnClickListener(
                new OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        Policy.dismissForever(store);
                        hideInternal(reduceMotion, onDismissed);
                    }
                });

        setVisibility(VISIBLE);
        setAlpha(0f);
        animate().cancel();
        animate().alpha(1f).setDuration(reduceMotion ? 120L : 180L).start();

        dwellTask =
                new Runnable() {
                    @Override
                    public void run() {
                        if (!countedThisSession && getVisibility() == VISIBLE) {
                            countedThisSession = true;
                            Policy.recordShown(store);
                        }
                    }
                };
        handler.postDelayed(dwellTask, MIN_DWELL_MS);

        autoHideTask =
                new Runnable() {
                    @Override
                    public void run() {
                        hideInternal(reduceMotion, onDismissed);
                    }
                };
        handler.postDelayed(autoHideTask, AUTO_DISMISS_MS);
        return true;
    }

    public void hideImmediate() {
        cancelTimers();
        animate().cancel();
        setVisibility(GONE);
    }

    private void hideInternal(boolean reduceMotion, final Runnable onDismissed) {
        cancelTimers();
        animate().cancel();
        animate()
                .alpha(0f)
                .setDuration(reduceMotion ? 120L : 180L)
                .withEndAction(
                        new Runnable() {
                            @Override
                            public void run() {
                                setVisibility(GONE);
                                if (onDismissed != null) {
                                    onDismissed.run();
                                }
                            }
                        })
                .start();
    }

    private void applySurface(boolean reduceTransparency) {
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(reduceTransparency ? 0xEB16161A : 0xCC12141C);
        bg.setCornerRadius(dp(20));
        bg.setStroke(dp(1), reduceTransparency ? 0x73FFFFFF : 0x38FFFFFF);
        UiCompat.setBackground(this, bg);
    }

    private void cancelTimers() {
        if (dwellTask != null) {
            handler.removeCallbacks(dwellTask);
            dwellTask = null;
        }
        if (autoHideTask != null) {
            handler.removeCallbacks(autoHideTask);
            autoHideTask = null;
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        cancelTimers();
        animate().cancel();
        super.onDetachedFromWindow();
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private static boolean isChineseLocale() {
        String lang = Locale.getDefault().getLanguage();
        return lang != null && lang.toLowerCase(Locale.US).startsWith("zh");
    }
}

package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 3-second cancelable intro/outro skip countdown overlay (player-hud-spec.md §4.4).
 *
 * <p>On Android TV when main controls are hidden, requests focus on the primary skip button, sets
 * {@code dialogOpen = true} via callback, skips on Confirm/Enter, cancels immediately on any
 * directional key or Back, and restores focus cleanly on dismissal. Zero blur, zero shaders, and
 * zero per-frame draw allocations for ARM32 >= 50fps safety.
 */
public final class SkipCountdownPill extends LinearLayout {
    public static final long TOTAL_MS = 3000L;
    public static final long TICK_MS = 100L;

    /** Pure-Java countdown state controller for deterministic JVM testing. */
    public static final class Controller {
        public static final int STATE_IDLE = 0;
        public static final int STATE_ACTIVE = 1;
        public static final int STATE_SKIPPED = 2;
        public static final int STATE_CANCELLED = 3;

        private int state = STATE_IDLE;
        private boolean intro;
        private int targetPositionMs;
        private long startTimeMs;
        private long remainingMs;
        private boolean ownsTvFocus;

        public int getState() {
            return state;
        }

        public boolean isActive() {
            return state == STATE_ACTIVE;
        }

        public boolean isIntro() {
            return intro;
        }

        public int getTargetPositionMs() {
            return targetPositionMs;
        }

        public long getRemainingMs() {
            return remainingMs;
        }

        public int getRemainingSecondsCeil() {
            if (remainingMs <= 0L) return 0;
            return (int) ((remainingMs + 999L) / 1000L);
        }

        public float getProgressFraction() {
            if (TOTAL_MS <= 0L) return 0f;
            float frac = 1f - (remainingMs / (float) TOTAL_MS);
            return Math.max(0f, Math.min(1f, frac));
        }

        public boolean ownsTvFocus() {
            return ownsTvFocus;
        }

        public void start(boolean intro, int targetPositionMs, long nowMs, boolean takeTvFocus) {
            this.intro = intro;
            this.targetPositionMs = Math.max(0, targetPositionMs);
            this.startTimeMs = nowMs;
            this.remainingMs = TOTAL_MS;
            this.ownsTvFocus = takeTvFocus;
            this.state = STATE_ACTIVE;
        }

        /** @return {@code true} when countdown expires and skip should execute now. */
        public boolean tick(long nowMs) {
            if (state != STATE_ACTIVE) return false;
            long elapsed = Math.max(0L, nowMs - startTimeMs);
            remainingMs = Math.max(0L, TOTAL_MS - elapsed);
            if (remainingMs <= 0L) {
                state = STATE_SKIPPED;
                ownsTvFocus = false;
                return true;
            }
            return false;
        }

        public boolean skipNow() {
            if (state != STATE_ACTIVE) return false;
            remainingMs = 0L;
            state = STATE_SKIPPED;
            ownsTvFocus = false;
            return true;
        }

        public boolean cancel() {
            if (state != STATE_ACTIVE) return false;
            remainingMs = 0L;
            state = STATE_CANCELLED;
            ownsTvFocus = false;
            return true;
        }

        public void reset() {
            state = STATE_IDLE;
            remainingMs = 0L;
            ownsTvFocus = false;
        }

        /**
         * Classifies a TV remote key during active countdown.
         *
         * @return {@code 1} = confirm skip, {@code -1} = cancel countdown, {@code 0} = ignore
         */
        public static int classifyTvKey(int keyCode) {
            if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                    || keyCode == KeyEvent.KEYCODE_ENTER
                    || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                return 1;
            }
            if (keyCode == KeyEvent.KEYCODE_BACK
                    || keyCode == KeyEvent.KEYCODE_ESCAPE
                    || keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                    || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                    || keyCode == KeyEvent.KEYCODE_DPAD_UP
                    || keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
                return -1;
            }
            return 0;
        }
    }

    public interface Callbacks {
        void onSkipExecute(boolean intro, int targetPositionMs);

        void onCancelled(boolean intro);

        void onTvDialogStateChanged(boolean open);
    }

    private static final class CountdownBar extends View {
        private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF rect = new RectF();
        private float fraction = 0f;

        CountdownBar(Context context) {
            super(context);
            trackPaint.setColor(0x33ffffff);
            fillPaint.setColor(0xff34d399);
        }

        void setFraction(float f) {
            float clamped = Math.max(0f, Math.min(1f, f));
            if (Math.abs(clamped - fraction) > 0.005f) {
                fraction = clamped;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0f || h <= 0f) return;
            float r = h * 0.5f;
            rect.set(0f, 0f, w, h);
            canvas.drawRoundRect(rect, r, r, trackPaint);
            float fillW = w * fraction;
            if (fillW > 0f) {
                rect.set(0f, 0f, Math.min(w, Math.max(h, fillW)), h);
                canvas.drawRoundRect(rect, r, r, fillPaint);
            }
        }
    }

    private final boolean isTv;
    private final Controller controller = new Controller();
    private final TextView titleView;
    private final Button skipBtn;
    private final Button cancelBtn;
    private final CountdownBar progressBar;
    private Callbacks callbacks;
    private boolean reducedTransparency;
    private boolean notifiedDialogOpen;

    private final Runnable tickRunnable =
            new Runnable() {
                @Override
                public void run() {
                    if (!controller.isActive()) return;
                    boolean expired = controller.tick(android.os.SystemClock.uptimeMillis());
                    updateCountdownUi();
                    if (expired) {
                        finishWithSkip();
                    } else {
                        postDelayed(this, TICK_MS);
                    }
                }
            };

    public SkipCountdownPill(Context context, boolean tv) {
        super(context);
        this.isTv = tv;
        setTag("player-skip-countdown-pill");
        setOrientation(VERTICAL);
        setPadding(dp(tv ? 18 : 14), dp(tv ? 12 : 10), dp(tv ? 18 : 14), dp(tv ? 10 : 8));
        applySurface();

        LinearLayout row = new LinearLayout(context);
        row.setOrientation(HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);

        titleView = new TextView(context);
        titleView.setTag("player-skip-countdown-title");
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, tv ? 15f : 13.5f);
        titleView.setTextColor(0xfff5f5f7);
        titleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        titleView.setSingleLine(true);
        titleView.setIncludeFontPadding(false);
        LayoutParams titleLp = new LayoutParams(-2, -2);
        titleLp.rightMargin = dp(12);
        row.addView(titleView, titleLp);

        skipBtn = buildActionButton(context, "立即跳过", true);
        skipBtn.setTag("player-skip-now");
        skipBtn.setOnClickListener(v -> finishWithSkip());
        LayoutParams skipLp = new LayoutParams(-2, dp(tv ? 36 : 32));
        skipLp.rightMargin = dp(8);
        row.addView(skipBtn, skipLp);

        cancelBtn = buildActionButton(context, tv ? "方向键/返回取消" : "取消", false);
        cancelBtn.setTag("player-skip-cancel");
        cancelBtn.setFocusable(!tv);
        cancelBtn.setOnClickListener(v -> finishWithCancel());
        row.addView(cancelBtn, new LayoutParams(-2, dp(tv ? 36 : 32)));

        if (tv) {
            skipBtn.setFocusable(true);
            skipBtn.setFocusableInTouchMode(true);
            skipBtn.setOnKeyListener(
                    (v, keyCode, event) -> {
                        if (!controller.isActive()) return false;
                        int action = Controller.classifyTvKey(keyCode);
                        if (action == 1) {
                            if (event.getAction() == KeyEvent.ACTION_UP) {
                                finishWithSkip();
                            }
                            return true;
                        }
                        if (action == -1) {
                            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                                finishWithCancel();
                            }
                            return true;
                        }
                        return false;
                    });
        }

        addView(row, new LayoutParams(-2, -2));

        progressBar = new CountdownBar(context);
        LayoutParams barLp = new LayoutParams(LayoutParams.MATCH_PARENT, dp(3));
        barLp.topMargin = dp(8);
        addView(progressBar, barLp);

        if (Build.VERSION.SDK_INT >= 21) {
            setElevation(dp(12));
        }
        setVisibility(View.GONE);
    }

    private int dp(float v) {
        float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
        return Math.max(1, Math.round(v * d));
    }

    private Button buildActionButton(Context context, String text, boolean primary) {
        Button b = new Button(context);
        b.setText(text);
        b.setAllCaps(false);
        b.setIncludeFontPadding(false);
        b.setSingleLine(true);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setGravity(Gravity.CENTER);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, isTv ? 13.5f : 12.5f);
        b.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        b.setPadding(dp(12), 0, dp(12), 0);
        styleButton(b, primary, false);
        if (isTv && primary) {
            b.setOnFocusChangeListener((v, focused) -> styleButton(b, true, focused));
        }
        return b;
    }

    private void styleButton(Button b, boolean primary, boolean focused) {
        GradientDrawable gd = new GradientDrawable();
        gd.setCornerRadius(dp(999));
        if (focused) {
            gd.setColor(0xfff5f5f7);
            gd.setStroke(dp(2), 0xffffffff);
            b.setTextColor(0xff101013);
        } else if (primary) {
            gd.setColor(0xff1f6f4a);
            gd.setStroke(dp(1), 0x6634d399);
            b.setTextColor(0xffffffff);
        } else {
            gd.setColor(0x28ffffff);
            gd.setStroke(dp(1), 0x33ffffff);
            b.setTextColor(0xffe5e7eb);
        }
        b.setBackground(gd);
    }

    private void applySurface() {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(isTv ? 16 : 14));
        bg.setColor(reducedTransparency ? 0xf516161a : 0xd916161a);
        bg.setStroke(Math.max(1, dp(1)), reducedTransparency ? 0x73ffffff : 0x33ffffff);
        setBackground(bg);
    }

    public void setReducedTransparency(boolean reducedTransparency) {
        if (this.reducedTransparency != reducedTransparency) {
            this.reducedTransparency = reducedTransparency;
            applySurface();
        }
    }

    public void setCallbacks(Callbacks callbacks) {
        this.callbacks = callbacks;
    }

    public boolean isActive() {
        return controller.isActive();
    }

    public void start(boolean intro, int targetPositionMs, boolean controlsHidden) {
        if (controller.isActive()) return;
        boolean takeTvFocus = isTv && controlsHidden;
        controller.start(
                intro, targetPositionMs, android.os.SystemClock.uptimeMillis(), takeTvFocus);
        updateCountdownUi();
        setVisibility(View.VISIBLE);
        if (takeTvFocus) {
            notifiedDialogOpen = true;
            if (callbacks != null) callbacks.onTvDialogStateChanged(true);
            skipBtn.requestFocus();
            skipBtn.post(skipBtn::requestFocus);
        }
        removeCallbacks(tickRunnable);
        postDelayed(tickRunnable, TICK_MS);
    }

    public void dismissSilently() {
        removeCallbacks(tickRunnable);
        controller.reset();
        setVisibility(View.GONE);
        releaseTvDialogState();
    }

    @Override
    protected void onDetachedFromWindow() {
        removeCallbacks(tickRunnable);
        controller.reset();
        releaseTvDialogState();
        super.onDetachedFromWindow();
    }

    private void finishWithSkip() {
        removeCallbacks(tickRunnable);
        boolean wasIntro = controller.isIntro();
        int target = controller.getTargetPositionMs();
        if (!controller.skipNow() && controller.getState() != Controller.STATE_SKIPPED) return;
        controller.reset();
        setVisibility(View.GONE);
        releaseTvDialogState();
        if (callbacks != null) callbacks.onSkipExecute(wasIntro, target);
    }

    private void finishWithCancel() {
        removeCallbacks(tickRunnable);
        boolean wasIntro = controller.isIntro();
        if (!controller.cancel()) return;
        controller.reset();
        setVisibility(View.GONE);
        releaseTvDialogState();
        if (callbacks != null) callbacks.onCancelled(wasIntro);
    }

    private void releaseTvDialogState() {
        if (notifiedDialogOpen) {
            notifiedDialogOpen = false;
            if (callbacks != null) callbacks.onTvDialogStateChanged(false);
        }
    }

    private void updateCountdownUi() {
        int sec = Math.max(1, controller.getRemainingSecondsCeil());
        titleView.setText((controller.isIntro() ? "即将跳过片头" : "即将跳过片尾") + " · " + sec + "s");
        progressBar.setFraction(controller.getProgressFraction());
    }
}

package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.provider.Settings;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.widget.TextView;
import java.util.WeakHashMap;

/**
 * Unified, interruptible motion & haptic foundation for Android Mobile / Tablet built strictly on
 * {@link MotionTokens}, {@link MotionSpring}, and {@link MotionLoop}.
 *
 * <p>Core policy helpers ({@link #shouldReduceMotion(boolean, float)}, {@link #rubberBand(float,
 * float)}, {@link #shouldDismissSheetOnRelease(float, float, float, float, float)}, and {@link
 * #measureSpringSettleSteps(MotionTokens.SpringPreset, float, float)}) are pure Java with zero
 * Android runtime dependencies so JVM tests can verify every curve and threshold directly.
 */
final class MobileMotion {
    private static final WeakHashMap<View, PressController> PRESS_CONTROLLERS = new WeakHashMap<>();
    private static final WeakHashMap<View, MotionLoop.Step> POP_STEPS = new WeakHashMap<>();
    private static final WeakHashMap<View, MotionLoop.Step> SHAKE_STEPS = new WeakHashMap<>();
    private static final WeakHashMap<TextView, String> PENDING_TEXT = new WeakHashMap<>();

    private MobileMotion() {}

    /** Pure-JVM reduced-motion policy combining app toggle and system animator duration scale. */
    static boolean shouldReduceMotion(boolean appReduced, float sysAnimatorScale) {
        if (appReduced) return true;
        return !Float.isNaN(sysAnimatorScale) && sysAnimatorScale <= 0f;
    }

    /** Runtime reduced-motion check honoring both {@code Prefs.REDUCED} and system settings. */
    static boolean isReduced(Context ctx) {
        boolean appReduced = (ctx instanceof MainActivity) && ((MainActivity) ctx).reduced;
        if (appReduced) return true;
        if (ctx == null) return false;
        float scale = 1f;
        try {
            if (ctx.getContentResolver() != null) {
                scale =
                        Settings.Global.getFloat(
                                ctx.getContentResolver(),
                                Settings.Global.ANIMATOR_DURATION_SCALE,
                                1f);
            }
        } catch (Throwable ignored) {
        }
        return shouldReduceMotion(false, scale);
    }

    /**
     * iOS-style asymptotic rubber-band resistance curve ({@code (1 - 1 / (x * 0.55 / d + 1)) * d}).
     * Monotonic in {@code offsetPx}, mirrors symmetrically for negative offsets, and strictly
     * bounded below {@code maxExtentPx}.
     */
    static float rubberBand(float offsetPx, float maxExtentPx) {
        if (maxExtentPx <= 0f
                || offsetPx == 0f
                || Float.isNaN(offsetPx)
                || Float.isNaN(maxExtentPx)
                || Float.isInfinite(maxExtentPx)) {
            return 0f;
        }
        float sign = offsetPx < 0f ? -1f : 1f;
        double x = Math.abs((double) offsetPx);
        double d = maxExtentPx;
        double damped = (1.0 - 1.0 / (x * 0.55 / d + 1.0)) * d;
        float res = (float) damped;
        if (res >= maxExtentPx) {
            res = Math.nextDown(maxExtentPx);
        }
        return sign * res;
    }

    /**
     * Pure-JVM release decision for finger-tracking bottom sheets and side drawers. Returns {@code
     * true} when drag distance exceeds {@code sizePx * fracThreshold} or positive fling velocity
     * exceeds {@code flingThreshold}.
     */
    static boolean shouldDismissSheetOnRelease(
            float dragPx,
            float velPxPerSec,
            float sizePx,
            float fracThreshold,
            float flingThreshold) {
        if (Float.isNaN(dragPx) || dragPx <= 0f) return false;
        if (sizePx > 0f && fracThreshold > 0f && dragPx + 1e-3f >= sizePx * fracThreshold) {
            return true;
        }
        return flingThreshold > 0f && !Float.isNaN(velPxPerSec) && velPxPerSec >= flingThreshold;
    }

    /**
     * Pure-JVM spring settle step counter using {@link MotionTokens#stepUnderdampedSpring} for
     * deterministic settle benchmarks.
     */
    static int measureSpringSettleSteps(
            MotionTokens.SpringPreset preset, float dtSeconds, float tolerance) {
        if (preset == null || dtSeconds <= 0f || Float.isNaN(dtSeconds)) return 0;
        MotionTokens.SpringState state = new MotionTokens.SpringState(0f, 0f);
        int steps = 0;
        while (steps < 600) {
            steps++;
            if (!MotionTokens.stepUnderdampedSpring(state, 1f, preset, dtSeconds, tolerance)) {
                break;
            }
        }
        return steps;
    }

    static void bindPress(View v, float pressedScale) {
        bindPressInternal(v, pressedScale, false, 0, 0, null, null);
    }

    static void bindPress(View v, float pressedScale, int normalBg, int pressedBg) {
        bindPressInternal(v, pressedScale, true, normalBg, pressedBg, null, null);
    }

    static void bindPress(View v, float pressedScale, Drawable normalBg, Drawable pressedBg) {
        bindPressInternal(v, pressedScale, false, 0, 0, normalBg, pressedBg);
    }

    private static void bindPressInternal(
            View v,
            float pressedScale,
            boolean useColorBg,
            int normalBgColor,
            int pressedBgColor,
            Drawable normalBgDrawable,
            Drawable pressedBgDrawable) {
        if (v == null) return;
        PressController prev = PRESS_CONTROLLERS.remove(v);
        if (prev != null) {
            prev.detach();
        }
        v.setFocusable(false);
        v.setFocusableInTouchMode(false);
        PressController controller =
                new PressController(
                        v,
                        pressedScale,
                        useColorBg,
                        normalBgColor,
                        pressedBgColor,
                        normalBgDrawable,
                        pressedBgDrawable);
        PRESS_CONTROLLERS.put(v, controller);
        controller.attach();
    }

    static void crossfadeVisibility(View v, boolean show, float slideYDp, float scaleFrom) {
        int durationMs = show ? MotionTokens.DURATION_STANDARD_MS : MotionTokens.DURATION_FAST_MS;
        crossfadeVisibility(v, show, slideYDp, scaleFrom, durationMs, false);
    }

    static void crossfadeVisibility(
            View v,
            boolean show,
            float slideYDp,
            float scaleFrom,
            int durationMs,
            boolean hudMode) {
        if (v == null) return;
        v.animate().cancel();
        if (!UiCompat.isAttached(v)) {
            v.setVisibility(show ? View.VISIBLE : View.GONE);
            v.setAlpha(show ? 1f : 0f);
            v.setTranslationY(0f);
            v.setScaleX(1f);
            v.setScaleY(1f);
            return;
        }
        boolean reduced = isReduced(v.getContext());
        int dur =
                reduced
                        ? (hudMode
                                ? MotionTokens.DURATION_REDUCED_HUD_FADE_MS
                                : MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                        : Math.max(0, durationMs);
        float slidePx = reduced ? 0f : dpPx(v, slideYDp);
        float sc = (reduced || scaleFrom <= 0f) ? 1f : scaleFrom;

        if (show) {
            if (v.getVisibility() == View.VISIBLE
                    && v.getAlpha() >= 0.99f
                    && Math.abs(v.getTranslationY()) < 0.5f
                    && Math.abs(v.getScaleX() - 1f) < 0.005f) {
                return;
            }
            if (v.getVisibility() != View.VISIBLE) {
                v.setAlpha(0f);
                v.setTranslationY(slidePx);
                v.setScaleX(sc);
                v.setScaleY(sc);
                v.setVisibility(View.VISIBLE);
            } else if (reduced) {
                v.setTranslationY(0f);
                v.setScaleX(1f);
                v.setScaleY(1f);
            }
            v.animate()
                    .alpha(1f)
                    .translationY(0f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .setDuration(dur)
                    .setInterpolator(
                            reduced
                                    ? MotionTokens.createLinearInterpolator()
                                    : MotionTokens.createDecelerateInterpolator())
                    .withEndAction(null)
                    .start();
        } else {
            if (v.getVisibility() == View.GONE) {
                v.setAlpha(1f);
                v.setTranslationY(0f);
                v.setScaleX(1f);
                v.setScaleY(1f);
                return;
            }
            v.animate()
                    .alpha(0f)
                    .translationY(slidePx)
                    .scaleX(sc)
                    .scaleY(sc)
                    .setDuration(dur)
                    .setInterpolator(
                            reduced
                                    ? MotionTokens.createLinearInterpolator()
                                    : MotionTokens.createAccelerateInterpolator())
                    .withEndAction(
                            () -> {
                                v.setVisibility(View.GONE);
                                v.setTranslationY(0f);
                                v.setScaleX(1f);
                                v.setScaleY(1f);
                            })
                    .start();
        }
    }

    private static void cancelPopBounce(View v) {
        if (v == null) return;
        MotionLoop.Step prev = POP_STEPS.remove(v);
        if (prev != null) {
            MotionLoop.remove(prev);
        }
    }

    /** Interruptible {@code SPRING_HUD_POPUP} scale pop ({@code 1f -> ~1.18f -> 1f}); no-op in reduced mode. */
    static void popBounce(final View v) {
        if (v == null || isReduced(v.getContext())) return;
        PressController press = PRESS_CONTROLLERS.get(v);
        if (press != null) {
            press.cancelForExternalScale();
        }
        cancelPopBounce(v);
        v.animate().cancel();
        final MotionTokens.SpringState state = new MotionTokens.SpringState(1f, 9.8f);
        final MotionLoop.Step[] ref = new MotionLoop.Step[1];
        ref[0] =
                dt -> {
                    if (!UiCompat.isAttached(v)) {
                        v.setScaleX(1f);
                        v.setScaleY(1f);
                        POP_STEPS.remove(v);
                        return false;
                    }
                    boolean moving =
                            MotionTokens.stepUnderdampedSpring(
                                    state, 1f, MotionTokens.SPRING_HUD_POPUP, dt, 0.002f);
                    float s = Math.max(0.85f, Math.min(1.24f, state.value));
                    v.setScaleX(s);
                    v.setScaleY(s);
                    if (!moving) {
                        v.setScaleX(1f);
                        v.setScaleY(1f);
                        POP_STEPS.remove(v);
                    }
                    return moving;
                };
        POP_STEPS.put(v, ref[0]);
        MotionLoop.add(ref[0]);
    }

    /** Damped horizontal {@code ±6dp} spring shake + reject haptic; subtle alpha pulse when reduced. */
    static void shakeInvalid(final View v) {
        if (v == null) return;
        try {
            int feedback =
                    Build.VERSION.SDK_INT >= 30
                            ? HapticFeedbackConstants.REJECT
                            : HapticFeedbackConstants.LONG_PRESS;
            v.performHapticFeedback(feedback);
        } catch (Throwable ignored) {
        }
        MotionLoop.Step prev = SHAKE_STEPS.remove(v);
        if (prev != null) {
            MotionLoop.remove(prev);
        }
        v.animate().cancel();
        if (isReduced(v.getContext())) {
            v.setTranslationX(0f);
            v.setAlpha(0.55f);
            v.animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .start();
            return;
        }
        final float maxAmp = dpPx(v, 6f);
        final float[] elapsed = {0f};
        final MotionLoop.Step[] ref = new MotionLoop.Step[1];
        ref[0] =
                dt -> {
                    if (!UiCompat.isAttached(v)) {
                        v.setTranslationX(0f);
                        SHAKE_STEPS.remove(v);
                        return false;
                    }
                    elapsed[0] += dt;
                    float t = elapsed[0];
                    if (t >= 0.34f) {
                        v.setTranslationX(0f);
                        SHAKE_STEPS.remove(v);
                        return false;
                    }
                    float decay = (float) Math.exp(-9.5 * t);
                    float offset = (float) (maxAmp * decay * Math.sin(44.0 * t));
                    v.setTranslationX(offset);
                    return true;
                };
        SHAKE_STEPS.put(v, ref[0]);
        MotionLoop.add(ref[0]);
    }

    /**
     * Directional page/tab transition ({@code ±14dp} for {@code |direction| == 1}, {@code ±28dp}
     * for {@code |direction| >= 2}, {@code 0} for fade-only). Uses {@code 150ms} opacity-only when
     * reduced.
     */
    static void animatePageSwap(View view, int direction) {
        float slideDp = Math.abs(direction) >= 2 ? 28f : 14f;
        animatePageSwap(view, direction, slideDp);
    }

    static void animatePageSwap(View view, int direction, float slideDp) {
        if (view == null) return;
        view.animate().cancel();
        boolean reduced = isReduced(view.getContext());
        if (reduced) {
            view.setTranslationX(0f);
            view.setAlpha(0f);
            view.animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .start();
            return;
        }
        float slidePx =
                direction == 0 ? 0f : (direction > 0 ? dpPx(view, slideDp) : -dpPx(view, slideDp));
        int dur =
                Math.abs(direction) >= 2
                        ? MotionTokens.DURATION_MOBILE_SHARED_BOUNDS_MS
                        : MotionTokens.DURATION_STANDARD_MS;
        view.setAlpha(0f);
        view.setTranslationX(slidePx);
        view.animate()
                .alpha(1f)
                .translationX(0f)
                .setDuration(dur)
                .setInterpolator(MotionTokens.createStandardInterpolator())
                .start();
    }

    /** Smooth 100ms crossfade text update when content actually changes (instant if unchanged or reduced). */
    static void crossfadeText(final TextView tv, CharSequence nextText) {
        if (tv == null) return;
        final String target = nextText == null ? "" : nextText.toString();
        String pending = PENDING_TEXT.get(tv);
        CharSequence current = tv.getText();
        boolean hasPending = pending != null;
        if (!hasPending && current != null && current.toString().equals(target)) {
            return;
        }
        tv.animate().cancel();
        if (hasPending && pending.equals(target)) {
            PENDING_TEXT.remove(tv);
            tv.setText(target);
            if (isReduced(tv.getContext()) || !UiCompat.isAttached(tv)) {
                tv.setAlpha(1f);
            } else {
                tv.animate()
                        .alpha(1f)
                        .setDuration(55)
                        .setInterpolator(MotionTokens.createDecelerateInterpolator())
                        .withEndAction(null)
                        .start();
            }
            return;
        }
        if (current != null && current.toString().equals(target)) {
            PENDING_TEXT.remove(tv);
            if (tv.getAlpha() < 0.99f && UiCompat.isAttached(tv) && !isReduced(tv.getContext())) {
                tv.animate()
                        .alpha(1f)
                        .setDuration(55)
                        .setInterpolator(MotionTokens.createDecelerateInterpolator())
                        .withEndAction(null)
                        .start();
            } else {
                tv.setAlpha(1f);
            }
            return;
        }
        if (isReduced(tv.getContext()) || !UiCompat.isAttached(tv)) {
            PENDING_TEXT.remove(tv);
            tv.setAlpha(1f);
            tv.setText(target);
            return;
        }
        PENDING_TEXT.put(tv, target);
        tv.animate()
                .alpha(0f)
                .setDuration(50)
                .setInterpolator(MotionTokens.createAccelerateInterpolator())
                .withEndAction(
                        () -> {
                            if (!target.equals(PENDING_TEXT.get(tv))) return;
                            PENDING_TEXT.remove(tv);
                            tv.setText(target);
                            tv.animate()
                                    .alpha(1f)
                                    .setDuration(55)
                                    .setInterpolator(MotionTokens.createDecelerateInterpolator())
                                    .withEndAction(null)
                                    .start();
                        })
                .start();
    }

    static void animateExpandCollapse(View v, boolean expand) {
        crossfadeVisibility(v, expand, -4f, 1f, MotionTokens.DURATION_FAST_MS, false);
    }

    static float dpPx(View v, float dp) {
        float density =
                v != null && v.getResources() != null
                        ? v.getResources().getDisplayMetrics().density
                        : 2f;
        return dp * density;
    }

    static int blendArgb(int c1, int c2, float ratio) {
        float r = Math.max(0f, Math.min(1f, ratio));
        int a1 = (c1 >>> 24) & 0xFF;
        int r1 = (c1 >> 16) & 0xFF;
        int g1 = (c1 >> 8) & 0xFF;
        int b1 = c1 & 0xFF;
        int a2 = (c2 >>> 24) & 0xFF;
        int r2 = (c2 >> 16) & 0xFF;
        int g2 = (c2 >> 8) & 0xFF;
        int b2 = c2 & 0xFF;
        int oa = Math.round(a1 + (a2 - a1) * r);
        int or = Math.round(r1 + (r2 - r1) * r);
        int og = Math.round(g1 + (g2 - g1) * r);
        int ob = Math.round(b1 + (b2 - b1) * r);
        return (oa << 24) | (or << 16) | (og << 8) | ob;
    }

    private static final class PressController
            implements View.OnTouchListener, View.OnAttachStateChangeListener {
        private final View view;
        private final float pressedScale;
        private final boolean useColorBg;
        private final int normalBgColor;
        private final int pressedBgColor;
        private final Drawable normalBgDrawable;
        private final Drawable pressedBgDrawable;
        private final MotionSpring spring =
                new MotionSpring(
                        1f, MotionTokens.SPRING_PRESS_FEEDBACK.motionSpringFrequency, 0.002f);
        private final MotionLoop.Step step;
        private boolean pressed;

        PressController(
                View view,
                float pressedScale,
                boolean useColorBg,
                int normalBgColor,
                int pressedBgColor,
                Drawable normalBgDrawable,
                Drawable pressedBgDrawable) {
            this.view = view;
            this.pressedScale = Math.max(0.80f, Math.min(1.0f, pressedScale));
            this.useColorBg = useColorBg;
            this.normalBgColor = normalBgColor;
            this.pressedBgColor = pressedBgColor;
            this.normalBgDrawable = normalBgDrawable;
            this.pressedBgDrawable = pressedBgDrawable;
            this.step =
                    dt -> {
                        if (!UiCompat.isAttached(view)) {
                            resetVisualsImmediate();
                            return false;
                        }
                        boolean moving = spring.step(dt);
                        applySpringVisuals(spring.value);
                        return moving;
                    };
        }

        void attach() {
            view.setOnTouchListener(this);
            view.addOnAttachStateChangeListener(this);
        }

        void detach() {
            MotionLoop.remove(step);
            view.removeOnAttachStateChangeListener(this);
            resetVisualsImmediate();
        }

        void cancelForExternalScale() {
            MotionLoop.remove(step);
            resetVisualsImmediate();
        }

        @Override
        public boolean onTouch(View v, MotionEvent event) {
            int action = event.getActionMasked();
            if (action == MotionEvent.ACTION_DOWN) {
                setPressedState(true);
            } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                setPressedState(false);
            }
            return false;
        }

        private void setPressedState(boolean down) {
            if (down) {
                cancelPopBounce(view);
            }
            if (pressed == down) return;
            pressed = down;
            boolean reduced = isReduced(view.getContext());
            if (reduced) {
                MotionLoop.remove(step);
                spring.snap(1f);
                view.setScaleX(1f);
                view.setScaleY(1f);
                if (useColorBg) {
                    view.setBackgroundColor(down ? pressedBgColor : normalBgColor);
                } else if (normalBgDrawable != null || pressedBgDrawable != null) {
                    Drawable target = down ? pressedBgDrawable : normalBgDrawable;
                    if (target != null) view.setBackground(target);
                } else {
                    view.setAlpha(down ? 0.82f : 1f);
                }
                return;
            }
            if (normalBgDrawable != null || pressedBgDrawable != null) {
                Drawable target = down ? pressedBgDrawable : normalBgDrawable;
                if (target != null) view.setBackground(target);
            }
            spring.target(down ? pressedScale : 1f);
            MotionLoop.add(step);
        }

        private void applySpringVisuals(float scale) {
            view.setScaleX(scale);
            view.setScaleY(scale);
            float denom = Math.max(0.001f, 1f - pressedScale);
            float t = Math.max(0f, Math.min(1f, (1f - scale) / denom));
            if (useColorBg) {
                view.setBackgroundColor(
                        t <= 0.001f ? normalBgColor : blendArgb(normalBgColor, pressedBgColor, t));
            } else if (normalBgDrawable == null && pressedBgDrawable == null) {
                view.setAlpha(1f - 0.14f * t);
            }
        }

        private void resetVisualsImmediate() {
            pressed = false;
            spring.snap(1f);
            view.setScaleX(1f);
            view.setScaleY(1f);
            if (useColorBg) {
                view.setBackgroundColor(normalBgColor);
            } else if (normalBgDrawable != null) {
                view.setBackground(normalBgDrawable);
            } else {
                view.setAlpha(1f);
            }
        }

        @Override
        public void onViewAttachedToWindow(View v) {}

        @Override
        public void onViewDetachedFromWindow(View v) {
            MotionLoop.remove(step);
            resetVisualsImmediate();
        }
    }
}

package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.View;
import com.pilipala.marcomovie.MotionTokens;

/**
 * Persistent bottom slim progress indicator shown when main playback controls are hidden
 * (player-hud-spec.md §4.2: 2.5dp mobile/tablet, 3.0dp TV, zero per-frame allocations).
 */
public final class SlimProgressBar extends View {
    public static final long FADE_OUT_MS = MotionTokens.DURATION_FAST_MS;
    public static final long REDUCED_FADE_MS = MotionTokens.DURATION_REDUCED_HUD_FADE_MS;
    private static final int DEFAULT_MOBILE_ACCENT_ARGB = 0xE6007AFF;

    private final boolean tv;
    private final Paint trackPaint = new Paint();
    private final Paint progressPaint = new Paint();
    private float fraction = 0f;
    private boolean reducedMotion;
    private boolean shouldShow;

    public SlimProgressBar(Context context, boolean tv) {
        super(context);
        this.tv = tv;
        setTag("player-slim-progress");
        setFocusable(false);
        setClickable(false);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        trackPaint.setColor(0x38ffffff);
        trackPaint.setStyle(Paint.Style.FILL);
        progressPaint.setColor(tv ? 0xddf5f7fb : DEFAULT_MOBILE_ACCENT_ARGB);
        progressPaint.setStyle(Paint.Style.FILL);
        setVisibility(View.GONE);
        setAlpha(0f);
    }

    public static int preferredHeightPx(Context context, boolean tv) {
        float d =
                context != null && context.getResources() != null
                        ? context.getResources().getDisplayMetrics().density
                        : 1f;
        return Math.max(2, Math.round((tv ? 3.0f : 2.5f) * d));
    }

    public void setAccentColor(int accentArgb) {
        if (tv) return;
        int next =
                accentArgb == 0
                        ? DEFAULT_MOBILE_ACCENT_ARGB
                        : ((accentArgb & 0x00FFFFFF) | 0xE6000000);
        if (progressPaint.getColor() != next) {
            progressPaint.setColor(next);
            invalidate();
        }
    }

    public void setReducedMotion(boolean reducedMotion) {
        this.reducedMotion = reducedMotion;
    }

    public void setProgress(int positionMs, int durationMs) {
        if (durationMs <= 0) return;
        float next = Math.max(0f, Math.min(1f, positionMs / (float) durationMs));
        if (Math.abs(next - fraction) >= 0.0015f) {
            fraction = next;
            invalidate();
        }
    }

    public void setActiveVisible(boolean visible) {
        if (shouldShow == visible) return;
        shouldShow = visible;
        animate().cancel();
        long dur = reducedMotion ? REDUCED_FADE_MS : FADE_OUT_MS;
        if (visible) {
            setVisibility(View.VISIBLE);
            animate()
                    .alpha(1f)
                    .setDuration(dur)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .withEndAction(null)
                    .start();
        } else {
            animate()
                    .alpha(0f)
                    .setDuration(dur)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .withEndAction(
                            () -> {
                                if (!shouldShow) setVisibility(View.GONE);
                            })
                    .start();
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        animate().withEndAction(null).cancel();
        super.onDetachedFromWindow();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth();
        int h = getHeight();
        if (w <= 0 || h <= 0) return;
        canvas.drawRect(0f, 0f, w, h, trackPaint);
        float fillW = w * fraction;
        if (fillW > 0f) {
            canvas.drawRect(0f, 0f, fillW, h, progressPaint);
        }
    }
}

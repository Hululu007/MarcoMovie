package com.pilipala.marcomovie.hud;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.pilipala.marcomovie.MotionTokens;
import com.pilipala.marcomovie.PlayerGestureStateMachine;
import java.util.Locale;

/**
 * Top-center speed boost & swipe-up speed lock capsule for touch playback (player-hud-spec.md
 * §4.3).
 *
 * <p>Uses Cinema Obsidian surfaces, dynamic theme accent, pure vector status glyphs (zero emojis),
 * and interruptible {@link MotionTokens} transitions with zero blur and zero shaders.
 */
public final class SpeedLockCapsule extends LinearLayout {
    public static final long LOCKED_DIM_DELAY_MS = 3000L;
    public static final float LOCKED_DIM_ALPHA = 0.72f;
    private static final int DEFAULT_ACCENT_ARGB = 0xFF007AFF;
    private static final int LOCKED_AMBER_ARGB = 0xFFFFB340;

    private final ImageView primaryIcon;
    private final TextView primaryText;
    private final LinearLayout detentRow;
    private final TextView[] detentViews;
    private final TextView secondaryText;
    private final Runnable dimRunnable = this::applyDimmedAlpha;

    private Drawable customLockDrawable;
    private Drawable customBoostDrawable;
    private final FallbackGlyphDrawable fallbackLockDrawable;
    private final FallbackGlyphDrawable fallbackBoostDrawable;

    private int accentColor = DEFAULT_ACCENT_ARGB;
    private boolean reducedMotion;
    private boolean reducedTransparency;
    private boolean lockedMode;
    private boolean showing;
    private int lastActiveDetent = -1;
    private int safeTopPx;

    public SpeedLockCapsule(Context context) {
        super(context);
        setTag("player-speed-lock-capsule");
        setOrientation(VERTICAL);
        setGravity(Gravity.CENTER_HORIZONTAL);
        setFocusable(false);
        setClickable(false);
        setPadding(dp(16), dp(9), dp(16), dp(9));
        applySurface(false, false);

        int glyphPx = dp(15);
        fallbackLockDrawable = new FallbackGlyphDrawable(true, glyphPx);
        fallbackBoostDrawable = new FallbackGlyphDrawable(false, glyphPx);

        LinearLayout primaryRow = new LinearLayout(context);
        primaryRow.setOrientation(HORIZONTAL);
        primaryRow.setGravity(Gravity.CENTER_VERTICAL);

        primaryIcon = new ImageView(context);
        primaryIcon.setTag("player-speed-icon");
        primaryIcon.setScaleType(ImageView.ScaleType.FIT_CENTER);
        primaryIcon.setImageDrawable(fallbackBoostDrawable);
        LayoutParams iconLp = new LayoutParams(glyphPx, glyphPx);
        iconLp.rightMargin = dp(6);
        primaryRow.addView(primaryIcon, iconLp);

        primaryText = new TextView(context);
        primaryText.setTag("player-speed-primary");
        primaryText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        primaryText.setTextColor(0xfff5f5f7);
        primaryText.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        primaryText.setSingleLine(true);
        primaryText.setIncludeFontPadding(false);
        primaryText.setGravity(Gravity.CENTER);
        primaryRow.addView(primaryText, new LayoutParams(-2, -2));
        addView(primaryRow, new LayoutParams(-2, -2));

        detentRow = new LinearLayout(context);
        detentRow.setOrientation(HORIZONTAL);
        detentRow.setGravity(Gravity.CENTER);
        LayoutParams detentRowLp = new LayoutParams(-2, -2);
        detentRowLp.topMargin = dp(6);
        float[] detents = PlayerGestureStateMachine.SPEED_DETENTS;
        detentViews = new TextView[detents.length];
        for (int i = 0; i < detents.length; i++) {
            TextView tv = new TextView(context);
            tv.setText(formatSpeed(detents[i]));
            tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f);
            tv.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            tv.setIncludeFontPadding(false);
            tv.setSingleLine(true);
            tv.setGravity(Gravity.CENTER);
            tv.setPadding(dp(6), dp(2), dp(6), dp(2));
            LayoutParams lp = new LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = dp(5);
            detentRow.addView(tv, lp);
            detentViews[i] = tv;
        }
        addView(detentRow, detentRowLp);

        secondaryText = new TextView(context);
        secondaryText.setTag("player-speed-secondary");
        secondaryText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f);
        secondaryText.setTextColor(0xc8ebebf5);
        secondaryText.setSingleLine(true);
        secondaryText.setIncludeFontPadding(false);
        secondaryText.setGravity(Gravity.CENTER);
        LayoutParams secLp = new LayoutParams(-2, -2);
        secLp.topMargin = dp(5);
        addView(secondaryText, secLp);

        if (Build.VERSION.SDK_INT >= 21) {
            setElevation(dp(12));
        }
        setVisibility(View.GONE);
    }

    private int dp(float v) {
        float d = getResources() != null ? getResources().getDisplayMetrics().density : 1f;
        return Math.max(1, Math.round(v * d));
    }

    public static String formatSpeed(float speed) {
        if (Math.abs(speed - Math.round(speed)) < 0.01f) {
            return String.format(Locale.US, "%.1f×", speed);
        }
        if (Math.abs(speed * 10f - Math.round(speed * 10f)) < 0.01f) {
            return String.format(Locale.US, "%.1f×", speed);
        }
        return String.format(Locale.US, "%.2f×", speed);
    }

    public void setAccentColor(int accentArgb) {
        int next = accentArgb == 0 ? DEFAULT_ACCENT_ARGB : accentArgb;
        if (this.accentColor != next) {
            this.accentColor = next;
            if (lastActiveDetent >= 0) {
                updateDetentHighlight(lastActiveDetent);
            }
        }
    }

    public void setStatusIcons(Drawable lockDrawable, Drawable boostDrawable) {
        this.customLockDrawable = lockDrawable;
        this.customBoostDrawable = boostDrawable;
    }

    public void setAccessibilityFlags(boolean reducedMotion, boolean reducedTransparency) {
        this.reducedMotion = reducedMotion;
        this.reducedTransparency = reducedTransparency;
    }

    public void updateSafeTop(int safeTopPx) {
        this.safeTopPx = Math.max(0, safeTopPx);
        if (getLayoutParams() instanceof FrameLayout.LayoutParams) {
            FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) getLayoutParams();
            int nextTop = Math.max(dp(16), this.safeTopPx + dp(16));
            if (lp.topMargin != nextTop) {
                lp.topMargin = nextTop;
                setLayoutParams(lp);
            }
        }
    }

    /**
     * Lifts darker accent presets (such as Graphite Slate {@code #64748B}) toward white on the dark
     * {@code 0xE0141720} cinema capsule surface so lock-ready glyphs, copy, and stroke maintain
     * crisp high contrast.
     */
    public static int ensureDarkSurfaceContrast(int argb) {
        int a = (argb >>> 24) & 0xFF;
        if (a == 0) a = 0xFF;
        int r = (argb >> 16) & 0xFF;
        int g = (argb >> 8) & 0xFF;
        int b = argb & 0xFF;
        double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        if (luma >= 165.0) {
            return (a << 24) | (r << 16) | (g << 8) | b;
        }
        float mix = luma < 125.0 ? 0.42f : 0.35f;
        int nr = Math.min(255, Math.round(r + (255 - r) * mix));
        int ng = Math.min(255, Math.round(g + (255 - g) * mix));
        int nb = Math.min(255, Math.round(b + (255 - b) * mix));
        return (a << 24) | (nr << 16) | (ng << 8) | nb;
    }

    private static int accentOnFillColor(int argb) {
        int r = (argb >> 16) & 0xFF;
        int g = (argb >> 8) & 0xFF;
        int b = argb & 0xFF;
        double luma = 0.299 * r + 0.587 * g + 0.114 * b;
        return luma > 168.0 ? 0xFF11141A : 0xFFFFFFFF;
    }

    private void applySurface(boolean lockReady, boolean locked) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(locked ? 999 : 18));
        int fill = reducedTransparency ? 0xF5141720 : 0xE0141720;
        int stroke;
        if (lockReady) {
            stroke = ensureDarkSurfaceContrast(accentColor);
        } else if (locked) {
            stroke = 0x99FF9F0A;
        } else {
            stroke = 0x33FFFFFF;
        }
        bg.setColor(fill);
        bg.setStroke(Math.max(1, dp(lockReady ? 1.5f : 1f)), stroke);
        setBackground(bg);
    }

    private void applyPrimaryGlyph(boolean useLock, int tintArgb) {
        Drawable d =
                useLock
                        ? (customLockDrawable != null ? customLockDrawable : fallbackLockDrawable)
                        : (customBoostDrawable != null
                                ? customBoostDrawable
                                : fallbackBoostDrawable);
        if (Build.VERSION.SDK_INT >= 21) {
            d.setTint(tintArgb);
        } else if (d instanceof FallbackGlyphDrawable) {
            ((FallbackGlyphDrawable) d).setGlyphColor(tintArgb);
        }
        primaryIcon.setImageDrawable(d);
    }

    private void updateDetentHighlight(int activeIndex) {
        lastActiveDetent = activeIndex;
        int activeText = accentOnFillColor(accentColor);
        for (int i = 0; i < detentViews.length; i++) {
            TextView tv = detentViews[i];
            boolean active = i == activeIndex;
            tv.setTextColor(active ? activeText : 0xB8D1D1DA);
            GradientDrawable pill = new GradientDrawable();
            pill.setCornerRadius(dp(999));
            pill.setColor(active ? accentColor : 0x1EFFFFFF);
            tv.setBackground(pill);
        }
    }

    private void revealAnimatedIfNeeded() {
        animate().cancel();
        boolean newlyShown = !showing || getVisibility() != View.VISIBLE;
        showing = true;
        if (!newlyShown || !isAttachedToWindow()) {
            setVisibility(View.VISIBLE);
            setAlpha(1f);
            setTranslationY(0f);
            setScaleX(1f);
            setScaleY(1f);
            return;
        }
        setVisibility(View.VISIBLE);
        setAlpha(0f);
        if (reducedMotion) {
            setTranslationY(0f);
            setScaleX(1f);
            setScaleY(1f);
            animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.DURATION_REDUCED_HUD_FADE_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .withEndAction(null)
                    .start();
        } else {
            setTranslationY(-dp(4));
            setScaleX(0.96f);
            setScaleY(0.96f);
            animate()
                    .alpha(1f)
                    .translationY(0f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .setDuration(MotionTokens.DURATION_FAST_MS)
                    .setInterpolator(MotionTokens.createDecelerateInterpolator())
                    .withEndAction(null)
                    .start();
        }
    }

    public void showBoosting(float speed, int detentIndex, boolean lockReady) {
        removeCallbacks(dimRunnable);
        lockedMode = false;
        setClickable(false);
        setOnClickListener(null);
        setPadding(dp(16), dp(9), dp(16), dp(9));
        applySurface(lockReady, false);

        String speedStr = formatSpeed(speed);
        int lockAccent = ensureDarkSurfaceContrast(accentColor);
        applyPrimaryGlyph(lockReady, lockReady ? lockAccent : 0xFFF5F5F7);
        primaryText.setText(speedStr + " 倍速播放中");
        detentRow.setVisibility(View.VISIBLE);
        updateDetentHighlight(detentIndex);
        secondaryText.setVisibility(View.VISIBLE);
        secondaryText.setTextColor(lockReady ? lockAccent : 0xC8EBEBF5);
        secondaryText.setText(lockReady ? ("松手即可锁定 " + speedStr) : "左右滑动调速 · 上滑锁定");

        revealAnimatedIfNeeded();
    }

    public void showLocked(float speed, Runnable onUnlockClick) {
        removeCallbacks(dimRunnable);
        lockedMode = true;
        setPadding(dp(14), dp(7), dp(14), dp(7));
        applySurface(false, true);

        String speedStr = formatSpeed(speed);
        applyPrimaryGlyph(true, LOCKED_AMBER_ARGB);
        primaryText.setText(speedStr + " 锁定中 · 点击恢复");
        detentRow.setVisibility(View.GONE);
        secondaryText.setVisibility(View.GONE);

        setClickable(true);
        setOnClickListener(
                v -> {
                    if (onUnlockClick != null) onUnlockClick.run();
                });
        revealAnimatedIfNeeded();
        postDelayed(dimRunnable, LOCKED_DIM_DELAY_MS);
    }

    public void hide() {
        removeCallbacks(dimRunnable);
        lockedMode = false;
        setClickable(false);
        setOnClickListener(null);
        if (!showing && getVisibility() != View.VISIBLE) {
            animate().cancel();
            setAlpha(1f);
            setTranslationY(0f);
            setScaleX(1f);
            setScaleY(1f);
            return;
        }
        showing = false;
        animate().cancel();
        if (!isAttachedToWindow()) {
            setAlpha(1f);
            setTranslationY(0f);
            setScaleX(1f);
            setScaleY(1f);
            setVisibility(View.GONE);
            return;
        }
        if (reducedMotion) {
            animate()
                    .alpha(0f)
                    .setDuration(MotionTokens.DURATION_REDUCED_HUD_FADE_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .withEndAction(
                            () -> {
                                if (!showing) {
                                    setVisibility(View.GONE);
                                    setAlpha(1f);
                                    setTranslationY(0f);
                                    setScaleX(1f);
                                    setScaleY(1f);
                                }
                            })
                    .start();
        } else {
            animate()
                    .alpha(0f)
                    .translationY(-dp(4))
                    .scaleX(0.96f)
                    .scaleY(0.96f)
                    .setDuration(MotionTokens.DURATION_FAST_MS)
                    .setInterpolator(MotionTokens.createAccelerateInterpolator())
                    .withEndAction(
                            () -> {
                                if (!showing) {
                                    setVisibility(View.GONE);
                                    setAlpha(1f);
                                    setTranslationY(0f);
                                    setScaleX(1f);
                                    setScaleY(1f);
                                }
                            })
                    .start();
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        removeCallbacks(dimRunnable);
        animate().withEndAction(null).cancel();
        super.onDetachedFromWindow();
    }

    private void applyDimmedAlpha() {
        if (!lockedMode || !showing || getVisibility() != View.VISIBLE) return;
        if (reducedMotion) {
            setAlpha(LOCKED_DIM_ALPHA);
        } else {
            animate()
                    .alpha(LOCKED_DIM_ALPHA)
                    .setDuration(MotionTokens.DURATION_STANDARD_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .start();
        }
    }

    private static final class FallbackGlyphDrawable extends Drawable {
        private final boolean lock;
        private final int sizePx;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF box = new RectF();
        private final Path path = new Path();
        private int color = 0xFFF5F5F7;

        FallbackGlyphDrawable(boolean lock, int sizePx) {
            this.lock = lock;
            this.sizePx = Math.max(1, sizePx);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
        }

        void setGlyphColor(int color) {
            if (this.color != color) {
                this.color = color;
                invalidateSelf();
            }
        }

        @Override
        public void setTint(int tintColor) {
            setGlyphColor(tintColor);
        }

        @Override
        public int getIntrinsicWidth() {
            return sizePx;
        }

        @Override
        public int getIntrinsicHeight() {
            return sizePx;
        }

        @Override
        public void draw(Canvas canvas) {
            Rect b = getBounds();
            float s =
                    Math.min(
                            b.width() > 0 ? b.width() : sizePx,
                            b.height() > 0 ? b.height() : sizePx);
            if (s <= 0f) return;
            float ox = b.left + ((b.width() > 0 ? b.width() : sizePx) - s) * 0.5f;
            float oy = b.top + ((b.height() > 0 ? b.height() : sizePx) - s) * 0.5f;
            float u = s / 24f;
            paint.setColor(color);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1.5f, 2.0f * u));
            if (lock) {
                box.set(ox + 5f * u, oy + 11f * u, ox + 19f * u, oy + 20f * u);
                canvas.drawRoundRect(box, 2.5f * u, 2.5f * u, paint);
                box.set(ox + 8f * u, oy + 4f * u, ox + 16f * u, oy + 12f * u);
                canvas.drawArc(box, 180f, 180f, false, paint);
                canvas.drawLine(ox + 8f * u, oy + 8f * u, ox + 8f * u, oy + 11f * u, paint);
                canvas.drawLine(ox + 16f * u, oy + 8f * u, ox + 16f * u, oy + 11f * u, paint);
            } else {
                path.reset();
                path.moveTo(ox + 4f * u, oy + 6.5f * u);
                path.lineTo(ox + 11.5f * u, oy + 12f * u);
                path.lineTo(ox + 4f * u, oy + 17.5f * u);
                path.moveTo(ox + 12.5f * u, oy + 6.5f * u);
                path.lineTo(ox + 20f * u, oy + 12f * u);
                path.lineTo(ox + 12.5f * u, oy + 17.5f * u);
                canvas.drawPath(path, paint);
            }
        }

        @Override
        public void setAlpha(int alpha) {
            paint.setAlpha(alpha);
            invalidateSelf();
        }

        @Override
        public void setColorFilter(ColorFilter colorFilter) {
            paint.setColorFilter(colorFilter);
            invalidateSelf();
        }

        @Override
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }
}

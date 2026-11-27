package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Current-page playback feedback; never creates a navigation destination. */
final class PlaybackLoading extends FrameLayout {
    private final BrandLogoLoaderView loader;
    private final TextView speedView;
    private final NetworkSpeedMonitor speedMonitor;

    PlaybackLoading(MainActivity a) {
        super(a);
        setTag("playback-loading");
        setContentDescription("正在加载播放");
        UiCompat.setBackground(this, UiCompat.createFocusSafeColorBackground(0x66000000));
        UiCompat.setDefaultFocusHighlightEnabled(this, false);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setClickable(true);

        LinearLayout pill = new LinearLayout(a);
        pill.setOrientation(LinearLayout.VERTICAL);
        pill.setGravity(Gravity.CENTER_HORIZONTAL);
        pill.setPadding(a.dp(24), a.dp(18), a.dp(24), a.dp(16));
        android.graphics.drawable.GradientDrawable bg = a.bg(0xdc141822, 18);
        bg.setStroke(Math.max(1, a.dp(1)), 0x30ffffff);
        pill.setBackground(bg);
        UiCompat.setElevation(pill, a.dp(12));

        int logoSize = a.dp(a.isTvDevice() ? 42 : 34);
        loader = new BrandLogoLoaderView(a);
        loader.setTag("playback-loading-logo");
        loader.setReducedMotion(a.reduced);
        loader.setActive(true);
        pill.addView(loader, new LinearLayout.LayoutParams(logoSize, logoSize));

        speedView =
                a.text(
                        NetworkSpeedMonitor.formatSpeedLabel(0L),
                        a.isTvDevice() ? 13f : 12f,
                        0xffd7e5f5);
        speedView.setTag("playback-loading-speed");
        speedView.setFontFeatureSettings("tnum");
        speedView.setIncludeFontPadding(false);
        speedView.setSingleLine(true);
        speedView.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        if (android.os.Build.VERSION.SDK_INT >= 19) {
            speedView.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_NONE);
        }
        LinearLayout.LayoutParams spdLp = new LinearLayout.LayoutParams(-2, -2);
        spdLp.topMargin = a.dp(10);
        pill.addView(speedView, spdLp);

        speedMonitor =
                new NetworkSpeedMonitor(
                        () -> {
                            if (a.activeEpisode != null
                                    && NetworkSpeedMonitor.isLocalMediaUrl(a.activeEpisode.url)) {
                                return 0L;
                            }
                            return a.player != null ? a.player.networkSpeedBytesPerSec() : -1L;
                        },
                        (bps, formatted) -> speedView.setText(formatted));

        addView(pill, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (loader != null) loader.setActive(getVisibility() == View.VISIBLE);
        if (speedMonitor != null && getVisibility() == View.VISIBLE) speedMonitor.start();
    }

    @Override
    protected void onVisibilityChanged(View changedView, int visibility) {
        super.onVisibilityChanged(changedView, visibility);
        boolean vis = visibility == View.VISIBLE && isAttachedToWindow();
        if (loader != null) loader.setActive(vis);
        if (speedMonitor != null) {
            if (vis) speedMonitor.start();
            else speedMonitor.stop();
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        if (loader != null) loader.setActive(false);
        if (speedMonitor != null) speedMonitor.stop();
        super.onDetachedFromWindow();
    }

    static final class Ring extends View {
        final Paint paint = new Paint(3);
        ValueAnimator animation;
        float angle;

        Ring(MainActivity a) {
            super(a);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(a.dp(2));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setColor(MainActivity.WHITE);
        }

        protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            animation = ValueAnimator.ofFloat(0, 360);
            animation.setDuration(900);
            animation.setRepeatCount(-1);
            animation.setInterpolator(new android.view.animation.LinearInterpolator());
            animation.addUpdateListener(
                    v -> {
                        angle = (float) v.getAnimatedValue();
                        invalidate();
                    });
            animation.start();
        }

        protected void onDetachedFromWindow() {
            if (animation != null) {
                animation.removeAllUpdateListeners();
                animation.cancel();
                animation = null;
            }
            super.onDetachedFromWindow();
        }

        protected void onDraw(Canvas c) {
            super.onDraw(c);
            float inset = paint.getStrokeWidth();
            c.drawArc(
                    new RectF(inset, inset, getWidth() - inset, getHeight() - inset),
                    angle,
                    260,
                    false,
                    paint);
        }
    }
}

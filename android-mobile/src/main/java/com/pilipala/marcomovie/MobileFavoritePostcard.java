package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RadialGradient;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.text.TextPaint;
import android.text.TextUtils;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import java.util.Calendar;
import java.util.Locale;
import java.util.Random;

/**
 * Native Android 120fps port of the iOS Marco Movie Favorite signature animation ({@code
 * FavoritePostcardFlightOverlay}):
 *
 * <ol>
 *   <li>Vintage camera shutter flash + viewfinder brackets + tactile impact ({@code t ∈ [0.00,
 *       0.12]}).
 *   <li>Collectible Marco Movie designer postcard (4 randomly cycled non-repeating variants:
 *       <b>Wavy Postage Stamp</b>, <b>Cinema Ticket Stub</b>, <b>Vintage Air Mail</b>, and <b>35mm
 *       Film Frame</b>) developing out of warm exposure wash ({@code t ∈ [0.04, 0.30]}).
 *   <li>3D perspective quadratic-Bézier parabolic flight straight into the top punch-hole / Dynamic
 *       Island cutout with arrival haptic ({@code t ∈ [0.30, 0.48]}).
 *   <li>Top elastic capsule expansion ({@code Marco Movie · 已收藏 <剧名>}) with mini framed poster
 *       thumbnail & crimson heart badge ({@code t ∈ [0.44, 0.98]}).
 * </ol>
 *
 * <p>Honors {@link MobileMotion#isReduced(android.content.Context)} by skipping flash and 3D flight
 * and showing only the calm top confirmation capsule.
 */
final class MobileFavoritePostcard {
    static final int STYLE_WAVY_POSTAGE_STAMP = 0;
    static final int STYLE_CINEMA_TICKET_STUB = 1;
    static final int STYLE_VINTAGE_AIR_MAIL = 2;
    static final int STYLE_FILM_FRAME_CARD = 3;
    static final int STYLE_COUNT = 4;

    private static final float DURATION_SECONDS = 2.4f;
    private static final Random RNG = new Random();
    private static int lastStyleIdx = -1;
    private static OverlayHost activeOverlay;

    private MobileFavoritePostcard() {}

    /** Pure-JVM timeline snapshot computed deterministically from normalized progress {@code t}. */
    static final class TimelineState {
        final float flashOpacity;
        final boolean showPostcard;
        final float cardOpacity;
        final float cardScale;
        final float cardRotateDeg;
        final float cardTiltXDeg;
        final float developWash;
        final float flightProgress;
        final boolean showIsland;
        final float islandExpand;
        final boolean arrivalTriggered;

        TimelineState(
                float flashOpacity,
                boolean showPostcard,
                float cardOpacity,
                float cardScale,
                float cardRotateDeg,
                float cardTiltXDeg,
                float developWash,
                float flightProgress,
                boolean showIsland,
                float islandExpand,
                boolean arrivalTriggered) {
            this.flashOpacity = flashOpacity;
            this.showPostcard = showPostcard;
            this.cardOpacity = cardOpacity;
            this.cardScale = cardScale;
            this.cardRotateDeg = cardRotateDeg;
            this.cardTiltXDeg = cardTiltXDeg;
            this.developWash = developWash;
            this.flightProgress = flightProgress;
            this.showIsland = showIsland;
            this.islandExpand = islandExpand;
            this.arrivalTriggered = arrivalTriggered;
        }
    }

    /** Pure-JVM non-repeating style picker across all 4 collectible postcard variants. */
    static int pickNextStyle(int prevStyle, int randRaw) {
        int next = Math.floorMod(randRaw, STYLE_COUNT);
        if (next == prevStyle && STYLE_COUNT > 1) {
            next = (next + 1) % STYLE_COUNT;
        }
        return next;
    }

    private static float clamp01(float v) {
        return Math.max(0f, Math.min(1f, Float.isNaN(v) ? 0f : v));
    }

    private static float easeOutCubic(float t) {
        float x = 1f - clamp01(t);
        return 1f - x * x * x;
    }

    private static float easeInCubic(float t) {
        float x = clamp01(t);
        return x * x * x;
    }

    private static float easeInOutCubic(float t) {
        float x = clamp01(t);
        return x < 0.5f ? 4f * x * x * x : 1f - (float) Math.pow(-2f * x + 2f, 3) * 0.5f;
    }

    private static float easeOutBack(float t) {
        float x = clamp01(t);
        float c1 = 1.70158f;
        float c3 = c1 + 1f;
        float xm = x - 1f;
        return 1f + c3 * xm * xm * xm + c1 * xm * xm;
    }

    /** Pure-JVM timeline evaluator matching iOS {@code _FavoritePostcardAnimationWidgetState}. */
    static TimelineState computeTimelineState(float rawT, boolean reducedMotion) {
        float t = clamp01(rawT);
        float flashOpacity = 0f;
        if (!reducedMotion) {
            if (t < 0.035f) {
                flashOpacity = easeOutCubic(t / 0.035f) * 0.86f;
            } else if (t < 0.12f) {
                flashOpacity = (1f - easeInCubic((t - 0.035f) / 0.085f)) * 0.86f;
            }
        }

        boolean showPostcard = !reducedMotion && t >= 0.04f && t <= 0.48f;
        float cardOpacity = 0f;
        float cardScale = 1f;
        float cardRotateDeg = 0f;
        float cardTiltXDeg = 0f;
        float developWash = 0f;
        float flightProgress = 0f;
        if (showPostcard) {
            if (t < 0.14f) {
                float p = easeOutBack((t - 0.04f) / 0.10f);
                cardOpacity = clamp01((t - 0.04f) / 0.06f);
                cardScale = 0.78f + 0.24f * p;
                cardRotateDeg = (float) Math.toDegrees(-0.055f * (1f - p) - 0.02f);
                developWash = clamp01(1f - p) * 0.62f;
            } else if (t < 0.30f) {
                float p = (t - 0.14f) / 0.16f;
                cardOpacity = 1f;
                cardScale = 1.02f - 0.02f * (float) Math.sin(p * Math.PI);
                cardRotateDeg = (float) Math.toDegrees(-0.02f + 0.038f * p);
            } else {
                flightProgress = easeInOutCubic((t - 0.30f) / 0.18f);
                cardScale = 1.0f * (1f - flightProgress) + 0.16f * flightProgress;
                cardRotateDeg =
                        (float)
                                Math.toDegrees(
                                        0.018f * (1f - flightProgress) + 0.22f * flightProgress);
                cardTiltXDeg = (float) Math.toDegrees(0.45f * Math.sin(flightProgress * Math.PI));
                cardOpacity =
                        flightProgress > 0.82f
                                ? clamp01(1f - (flightProgress - 0.82f) / 0.18f)
                                : 1f;
            }
        }

        boolean showIsland =
                reducedMotion ? (t >= 0.05f && t <= 0.92f) : (t >= 0.44f && t <= 0.98f);
        float islandExpand = 0f;
        if (showIsland) {
            if (reducedMotion) {
                islandExpand = 1f;
            } else if (t < 0.56f) {
                islandExpand = easeOutBack((t - 0.44f) / 0.12f);
            } else if (t < 0.84f) {
                islandExpand = 1f;
            } else {
                islandExpand = 1f - easeInCubic((t - 0.84f) / 0.14f);
            }
        }

        return new TimelineState(
                flashOpacity,
                showPostcard,
                cardOpacity,
                cardScale,
                cardRotateDeg,
                cardTiltXDeg,
                developWash,
                flightProgress,
                showIsland,
                islandExpand,
                t >= 0.45f);
    }

    /** Extracts an already-loaded {@link Bitmap} from a poster {@link ImageView} if present. */
    static Bitmap peekBitmapFromView(ImageView iv) {
        if (iv == null) return null;
        Drawable d = iv.getDrawable();
        if (d instanceof BitmapDrawable) {
            Bitmap b = ((BitmapDrawable) d).getBitmap();
            if (b != null && !b.isRecycled()) return b;
        }
        return null;
    }

    /** Launches the collectible postcard flight & top island capsule animation on the DecorView. */
    static void show(MainActivity a, String title, String posterUrl, Bitmap initialPoster) {
        if (a == null || a.isFinishing() || a.isDestroyed() || a.getWindow() == null) return;
        View decor = a.getWindow().getDecorView();
        if (!(decor instanceof ViewGroup)) return;
        ViewGroup hostParent = (ViewGroup) decor;

        dismissActive();

        int style = pickNextStyle(lastStyleIdx, RNG.nextInt(STYLE_COUNT));
        lastStyleIdx = style;

        Calendar cal = Calendar.getInstance();
        String dateStamp =
                String.format(
                        Locale.US,
                        "%04d.%02d.%02d",
                        cal.get(Calendar.YEAR),
                        cal.get(Calendar.MONTH) + 1,
                        cal.get(Calendar.DAY_OF_MONTH));

        Bitmap logoMark = null;
        try {
            logoMark = BitmapFactory.decodeResource(a.getResources(), R.drawable.logo_mark);
        } catch (Throwable ignored) {
        }

        OverlayHost overlay =
                new OverlayHost(
                        a,
                        title == null ? "" : title.trim(),
                        dateStamp,
                        initialPoster,
                        logoMark,
                        style,
                        () -> {
                            if (activeOverlay != null
                                    && activeOverlay.getParent() instanceof ViewGroup) {
                                ((ViewGroup) activeOverlay.getParent()).removeView(activeOverlay);
                            }
                            activeOverlay = null;
                        });
        activeOverlay = overlay;
        hostParent.addView(
                overlay,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // If poster bitmap wasn't already cached on the ImageView, resolve it asynchronously
        if (initialPoster == null && posterUrl != null && !posterUrl.trim().isEmpty()) {
            Cms.Video dummy = new Cms.Video();
            dummy.title = title == null ? "" : title;
            dummy.poster = posterUrl;
            ImageView hiddenFetcher = new ImageView(a);
            ImageLoader.loadHeroHdPoster(
                    a, dummy, hiddenFetcher, a.privateMode, overlay::setPosterBitmap);
        }

        overlay.start();
    }

    static void dismissActive() {
        if (activeOverlay != null) {
            activeOverlay.stop();
            if (activeOverlay.getParent() instanceof ViewGroup) {
                ((ViewGroup) activeOverlay.getParent()).removeView(activeOverlay);
            }
            activeOverlay = null;
        }
    }

    private static final class OverlayHost extends FrameLayout {
        private final MainActivity a;
        private final String title;
        private final String dateStamp;
        private final int style;
        private final boolean reducedMotion;
        private final Runnable onDone;
        private final Bitmap logoMark;
        private Bitmap posterBitmap;

        private final View scrimLayer;
        private final FlashView flashView;
        private final PostcardCanvasView postcardView;
        private final IslandPillView islandView;

        private float elapsedSeconds = 0f;
        private boolean arrivalHapticFired = false;
        private MotionLoop.Step loopStep;
        private int cardW;
        private int cardH;
        private int cardShadowPad;
        private float islandW;
        private float islandH;
        private float islandTop;

        OverlayHost(
                MainActivity a,
                String title,
                String dateStamp,
                Bitmap initialPoster,
                Bitmap logoMark,
                int style,
                Runnable onDone) {
            super(a);
            this.a = a;
            this.title = title;
            this.dateStamp = dateStamp;
            this.posterBitmap = initialPoster;
            this.logoMark = logoMark;
            this.style = style;
            this.reducedMotion = MobileMotion.isReduced(a);
            this.onDone = onDone;

            setClickable(false);
            setFocusable(false);
            setClipChildren(false);
            setClipToPadding(false);

            int screenW = Math.max(a.dp(320), a.windowWidth());
            this.cardW = Math.min(a.dp(314), Math.round(screenW * 0.84f));
            this.cardH = Math.round(cardW / 1.52f);
            this.cardShadowPad = a.dp(18);
            this.islandW = a.dp(124);
            int sbH = a.statusBarHeight();
            boolean hasTopCutout = sbH > a.dp(28);
            this.islandTop = hasTopCutout ? a.dp(10) : (sbH + a.dp(8));
            this.islandH = hasTopCutout ? Math.max(a.dp(34), sbH - this.islandTop) : 0f;

            scrimLayer = new View(a);
            scrimLayer.setBackgroundColor(Color.BLACK);
            scrimLayer.setAlpha(0f);
            addView(scrimLayer, new FrameLayout.LayoutParams(-1, -1));

            flashView = new FlashView(a);
            flashView.setAlpha(0f);
            addView(flashView, new FrameLayout.LayoutParams(-1, -1));

            postcardView =
                    new PostcardCanvasView(
                            a, style, title, dateStamp, initialPoster, logoMark, cardShadowPad);
            postcardView.setVisibility(View.INVISIBLE);
            postcardView.setCameraDistance(a.getResources().getDisplayMetrics().density * 7200f);
            addView(
                    postcardView,
                    new FrameLayout.LayoutParams(
                            cardW + cardShadowPad * 2, cardH + cardShadowPad * 2));

            islandView = new IslandPillView(a, title, initialPoster, islandW, islandH, islandTop);
            islandView.setVisibility(View.INVISIBLE);
            addView(islandView, new FrameLayout.LayoutParams(-1, -1));
        }

        void setPosterBitmap(Bitmap bmp) {
            if (bmp == null || bmp.isRecycled()) return;
            this.posterBitmap = bmp;
            postcardView.setPosterBitmap(bmp);
            islandView.setPosterBitmap(bmp);
        }

        private void fireHaptic(boolean heavy) {
            try {
                int code;
                if (Build.VERSION.SDK_INT >= 30) {
                    code =
                            heavy
                                    ? HapticFeedbackConstants.CONFIRM
                                    : HapticFeedbackConstants.CLOCK_TICK;
                } else {
                    code =
                            heavy
                                    ? HapticFeedbackConstants.LONG_PRESS
                                    : HapticFeedbackConstants.VIRTUAL_KEY;
                }
                performHapticFeedback(code);
            } catch (Throwable ignored) {
            }
        }

        void start() {
            elapsedSeconds = 0f;
            arrivalHapticFired = false;
            fireHaptic(false);
            applyFrame(0f);
            loopStep =
                    dt -> {
                        if (!UiCompat.isAttached(this) || a.isFinishing()) {
                            loopStep = null;
                            return false;
                        }
                        elapsedSeconds += dt;
                        float t = elapsedSeconds / DURATION_SECONDS;
                        if (t >= 1f) {
                            loopStep = null;
                            if (onDone != null) onDone.run();
                            return false;
                        }
                        applyFrame(t);
                        return true;
                    };
            MotionLoop.add(loopStep);
        }

        void stop() {
            if (loopStep != null) {
                MotionLoop.remove(loopStep);
                loopStep = null;
            }
        }

        private void applyFrame(float t) {
            TimelineState st = computeTimelineState(t, reducedMotion);
            if (!arrivalHapticFired && st.arrivalTriggered) {
                arrivalHapticFired = true;
                fireHaptic(true);
            }

            // 1. Subtle backdrop dim strictly during postcard focus
            if (st.showPostcard) {
                float dimFactor = t < 0.34f ? 1f : 0.35f;
                scrimLayer.setAlpha(0.30f * st.cardOpacity * dimFactor);
                scrimLayer.setVisibility(View.VISIBLE);
            } else {
                scrimLayer.setAlpha(0f);
                scrimLayer.setVisibility(View.INVISIBLE);
            }

            // 2. Retro shutter flash + viewfinder brackets
            if (st.flashOpacity > 0.005f) {
                flashView.setAlpha(st.flashOpacity);
                flashView.setVisibility(View.VISIBLE);
            } else {
                flashView.setAlpha(0f);
                flashView.setVisibility(View.INVISIBLE);
            }

            // 3. Collectible postcard with 3D parabolic flight into top cutout
            int w = getWidth() > 0 ? getWidth() : a.windowWidth();
            int h = getHeight() > 0 ? getHeight() : a.windowHeight();
            if (st.showPostcard) {
                float p0x = w * 0.5f;
                float p0y = h * 0.46f;
                float cx = p0x;
                float cy = p0y;
                if (st.flightProgress > 0f) {
                    float p = st.flightProgress;
                    float inv = 1f - p;
                    float p2x = w * 0.5f;
                    float p2y = islandTop + (islandH > 0f ? islandH : a.dp(28)) + a.dp(6);
                    float p1x = w * 0.68f;
                    float p1y = Math.min(p0y, p2y) + (p0y - p2y) * 0.28f;
                    cx = inv * inv * p0x + 2f * inv * p * p1x + p * p * p2x;
                    cy = inv * inv * p0y + 2f * inv * p * p1y + p * p * p2y;
                }
                postcardView.setVisibility(View.VISIBLE);
                postcardView.setAlpha(st.cardOpacity);
                postcardView.setTranslationX(cx - cardW * 0.5f - cardShadowPad);
                postcardView.setTranslationY(cy - cardH * 0.5f - cardShadowPad);
                postcardView.setScaleX(st.cardScale);
                postcardView.setScaleY(st.cardScale);
                postcardView.setRotation(st.cardRotateDeg);
                postcardView.setRotationX(st.cardTiltXDeg);
                postcardView.setDevelopWash(st.developWash);
            } else {
                postcardView.setVisibility(View.INVISIBLE);
            }

            // 4. Top Dynamic-Island / Punch-Hole elastic feedback capsule
            if (st.showIsland) {
                islandView.setVisibility(View.VISIBLE);
                islandView.setExpandProgress(st.islandExpand);
            } else {
                islandView.setVisibility(View.INVISIBLE);
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            stop();
            super.onDetachedFromWindow();
        }
    }

    /** Warm radial vintage camera flash + dark viewfinder corner brackets. */
    private static final class FlashView extends View {
        private final MainActivity a;
        private final Paint flashPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint cornerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int lastW = -1;
        private int lastH = -1;

        FlashView(MainActivity a) {
            super(a);
            this.a = a;
            cornerPaint.setColor(0xCC1C1C1E);
            cornerPaint.setStyle(Paint.Style.STROKE);
            cornerPaint.setStrokeWidth(a.dp(2f));
            cornerPaint.setStrokeCap(Paint.Cap.ROUND);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            if (w != lastW || h != lastH) {
                lastW = w;
                lastH = h;
                flashPaint.setShader(
                        new RadialGradient(
                                w * 0.5f,
                                h * 0.46f,
                                Math.max(w, h) * 0.72f,
                                new int[] {0xFFFFFDF4, 0xEBFFF4D6, 0x85FFD89B},
                                new float[] {0f, 0.55f, 1f},
                                Shader.TileMode.CLAMP));
            }
            canvas.drawRect(0f, 0f, w, h, flashPaint);

            float boxW = a.dp(268);
            float boxH = a.dp(176);
            float l = (w - boxW) * 0.5f;
            float t = h * 0.46f - boxH * 0.5f;
            float r = l + boxW;
            float b = t + boxH;
            float len = a.dp(18);
            canvas.drawLine(l, t, l + len, t, cornerPaint);
            canvas.drawLine(l, t, l, t + len, cornerPaint);
            canvas.drawLine(r, t, r - len, t, cornerPaint);
            canvas.drawLine(r, t, r, t + len, cornerPaint);
            canvas.drawLine(l, b, l + len, b, cornerPaint);
            canvas.drawLine(l, b, l, b - len, cornerPaint);
            canvas.drawLine(r, b, r - len, b, cornerPaint);
            canvas.drawLine(r, b, r, b - len, cornerPaint);
        }
    }

    /** Custom-drawn collectible Marco Movie postcard supporting all 4 iOS designer styles. */
    private static final class PostcardCanvasView extends View {
        private final MainActivity a;
        private final int style;
        private final String title;
        private final String dateStamp;
        private final Bitmap logoMark;
        private final int shadowPad;
        private Bitmap posterBitmap;
        private float developWash = 0f;

        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        private final Paint shadowPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final TextPaint textPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        private final Path clipPath = new Path();
        private final Rect srcRect = new Rect();
        private final RectF dstRect = new RectF();
        private int lastW = -1, lastH = -1;

        PostcardCanvasView(
                MainActivity a,
                int style,
                String title,
                String dateStamp,
                Bitmap posterBitmap,
                Bitmap logoMark,
                int shadowPad) {
            super(a);
            this.a = a;
            this.style = style;
            this.title = title.isEmpty() ? "我的收藏" : title;
            this.dateStamp = dateStamp;
            this.posterBitmap = posterBitmap;
            this.logoMark = logoMark;
            this.shadowPad = shadowPad;
            shadowPaint.setColor(0xFF141418);
            shadowPaint.setShadowLayer(a.dp(15f), 0f, a.dp(9f), 0x8C000000);
        }

        void setPosterBitmap(Bitmap bmp) {
            this.posterBitmap = bmp;
            invalidate();
        }

        void setDevelopWash(float wash) {
            if (Math.abs(this.developWash - wash) > 0.005f) {
                this.developWash = wash;
                invalidate();
            }
        }

        private void rebuildPerimeterClip(int w, int h) {
            clipPath.reset();
            if (style == STYLE_WAVY_POSTAGE_STAMP) {
                Path outer = new Path();
                outer.addRoundRect(0f, 0f, w, h, a.dp(6), a.dp(6), Path.Direction.CW);
                Path holes = new Path();
                float r = a.dp(6.2f);
                float step = r * 2.55f;
                for (float x = step * 0.7f; x < w - step * 0.5f; x += step) {
                    holes.addCircle(x, 0f, r, Path.Direction.CW);
                    holes.addCircle(x, h, r, Path.Direction.CW);
                }
                for (float y = step * 0.7f; y < h - step * 0.5f; y += step) {
                    holes.addCircle(0f, y, r, Path.Direction.CW);
                    holes.addCircle(w, y, r, Path.Direction.CW);
                }
                clipPath.op(outer, holes, Path.Op.DIFFERENCE);
            } else if (style == STYLE_CINEMA_TICKET_STUB) {
                Path outer = new Path();
                outer.addRoundRect(0f, 0f, w, h, a.dp(14), a.dp(14), Path.Direction.CW);
                Path notches = new Path();
                float nr = a.dp(10.5f);
                float tearX = w * 0.68f;
                notches.addCircle(0f, h * 0.5f, nr, Path.Direction.CW);
                notches.addCircle(w, h * 0.5f, nr, Path.Direction.CW);
                notches.addCircle(tearX, 0f, a.dp(7f), Path.Direction.CW);
                notches.addCircle(tearX, h, a.dp(7f), Path.Direction.CW);
                clipPath.op(outer, notches, Path.Op.DIFFERENCE);
            } else if (style == STYLE_VINTAGE_AIR_MAIL) {
                clipPath.addRoundRect(0f, 0f, w, h, a.dp(13), a.dp(13), Path.Direction.CW);
            } else {
                clipPath.addRoundRect(0f, 0f, w, h, a.dp(11), a.dp(11), Path.Direction.CW);
            }
        }

        private void drawCenterCropPhoto(Canvas canvas, RectF box, float radiusPx) {
            int save = canvas.save();
            Path p = new Path();
            p.addRoundRect(box, radiusPx, radiusPx, Path.Direction.CW);
            canvas.clipPath(p);
            if (posterBitmap != null && !posterBitmap.isRecycled()) {
                int bw = posterBitmap.getWidth();
                int bh = posterBitmap.getHeight();
                float scale = Math.max(box.width() / bw, box.height() / bh);
                float cropW = box.width() / scale;
                float cropH = box.height() / scale;
                int left = Math.max(0, Math.round((bw - cropW) * 0.5f));
                int top = Math.max(0, Math.round((bh - cropH) * 0.25f));
                srcRect.set(
                        left,
                        top,
                        Math.min(bw, left + Math.round(cropW)),
                        Math.min(bh, top + Math.round(cropH)));
                paint.reset();
                paint.setAntiAlias(true);
                paint.setFilterBitmap(true);
                canvas.drawBitmap(posterBitmap, srcRect, box, paint);
            } else {
                paint.reset();
                paint.setAntiAlias(true);
                paint.setShader(
                        new LinearGradient(
                                box.left,
                                box.top,
                                box.right,
                                box.bottom,
                                0xFF2B3242,
                                0xFF151822,
                                Shader.TileMode.CLAMP));
                canvas.drawRect(box, paint);
                paint.setShader(null);
            }
            if (developWash > 0.01f) {
                paint.reset();
                paint.setColor(
                        MobileTheme.withAlpha(0xFFFFF8E8, Math.round(255f * clamp01(developWash))));
                canvas.drawRect(box, paint);
            }
            canvas.restoreToCount(save);
        }

        private void drawBrandStamp(
                Canvas canvas,
                float rightX,
                float topY,
                int bgCol,
                int borderCol,
                int textCol,
                String label,
                float rotateDeg) {
            textPaint.reset();
            textPaint.setAntiAlias(true);
            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(8.5f));
            textPaint.setColor(textCol);
            float tw = textPaint.measureText(label);
            float iconSize = a.dp(12);
            float padH = a.dp(6.5f);
            float boxW = padH * 2 + iconSize + a.dp(4) + tw;
            float boxH = a.dp(20);
            float leftX = rightX - boxW;
            int save = canvas.save();
            canvas.rotate(rotateDeg, leftX + boxW * 0.5f, topY + boxH * 0.5f);
            dstRect.set(leftX, topY, rightX, topY + boxH);
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(bgCol);
            canvas.drawRoundRect(dstRect, a.dp(5.5f), a.dp(5.5f), paint);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1f, a.dp(0.85f)));
            paint.setColor(borderCol);
            canvas.drawRoundRect(dstRect, a.dp(5.5f), a.dp(5.5f), paint);
            if (logoMark != null && !logoMark.isRecycled()) {
                RectF icRect =
                        new RectF(
                                leftX + padH,
                                topY + (boxH - iconSize) * 0.5f,
                                leftX + padH + iconSize,
                                topY + (boxH + iconSize) * 0.5f);
                paint.reset();
                paint.setAntiAlias(true);
                paint.setFilterBitmap(true);
                canvas.drawBitmap(logoMark, null, icRect, paint);
            }
            Paint.FontMetrics fm = textPaint.getFontMetrics();
            float ty = topY + boxH * 0.5f - (fm.ascent + fm.descent) * 0.5f;
            canvas.drawText(label, leftX + padH + iconSize + a.dp(4), ty, textPaint);
            canvas.restoreToCount(save);
        }

        private void drawTinyHeart(Canvas canvas, float cx, float cy, float sizePx, int color) {
            Path hp = new Path();
            float s = sizePx * 0.5f;
            hp.moveTo(cx, cy + s * 0.85f);
            hp.cubicTo(
                    cx - s * 1.2f,
                    cy + s * 0.1f,
                    cx - s * 1.15f,
                    cy - s * 0.9f,
                    cx,
                    cy - s * 0.25f);
            hp.cubicTo(
                    cx + s * 1.15f,
                    cy - s * 0.9f,
                    cx + s * 1.2f,
                    cy + s * 0.1f,
                    cx,
                    cy + s * 0.85f);
            hp.close();
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(color);
            canvas.drawPath(hp, paint);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth() - shadowPad * 2;
            int h = getHeight() - shadowPad * 2;
            if (w <= 0 || h <= 0) return;
            if (w != lastW || h != lastH) {
                lastW = w;
                lastH = h;
                rebuildPerimeterClip(w, h);
            }

            int saveOuter = canvas.save();
            canvas.translate(shadowPad, shadowPad);
            // Silhouette-accurate drop shadow matching stamp perforations & ticket notches
            canvas.drawPath(clipPath, shadowPaint);
            int save = canvas.save();
            canvas.clipPath(clipPath);
            if (style == STYLE_WAVY_POSTAGE_STAMP) {
                drawWavyPostageStamp(canvas, w, h);
            } else if (style == STYLE_CINEMA_TICKET_STUB) {
                drawCinemaTicketStub(canvas, w, h);
            } else if (style == STYLE_VINTAGE_AIR_MAIL) {
                drawVintageAirMail(canvas, w, h);
            } else {
                drawFilmFrameCard(canvas, w, h);
            }
            canvas.restoreToCount(save);
            canvas.restoreToCount(saveOuter);
        }

        private void drawWavyPostageStamp(Canvas canvas, int w, int h) {
            canvas.drawColor(0xFFFAF5E8);
            float pad = a.dp(14);
            float photoW = (w - pad * 2 - a.dp(10)) * 0.62f;
            RectF photoBox = new RectF(pad, pad, pad + photoW, h - pad);
            drawCenterCropPhoto(canvas, photoBox, a.dp(7));

            float colL = photoBox.right + a.dp(10);
            float colR = w - pad;
            drawBrandStamp(canvas, colR, pad, 0xFF1A191E, 0xFFD9B468, 0xFFFFEAB8, "MARCO", 3.5f);

            // Circular ink postmark + wavy cancellation lines
            paint.reset();
            paint.setAntiAlias(true);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1f, a.dp(1f)));
            paint.setColor(0x558B7355);
            float pmCx = colL + (colR - colL) * 0.30f;
            float pmCy = pad + a.dp(42);
            canvas.drawCircle(pmCx, pmCy, a.dp(13), paint);
            canvas.drawCircle(pmCx, pmCy, a.dp(9.5f), paint);
            for (int i = -1; i <= 1; i++) {
                float wy = pmCy + i * a.dp(4.8f);
                Path wave = new Path();
                wave.moveTo(pmCx + a.dp(14), wy);
                wave.quadTo(pmCx + a.dp(24), wy - a.dp(3), pmCx + a.dp(34), wy);
                wave.quadTo(pmCx + a.dp(44), wy + a.dp(3), colR - a.dp(2), wy);
                canvas.drawPath(wave, paint);
            }

            // Bottom title, hairline divider, heart + date
            float colW = Math.max(10f, colR - colL);
            textPaint.reset();
            textPaint.setAntiAlias(true);
            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(12f));
            textPaint.setColor(0xFF1F1C18);
            CharSequence elTitle =
                    TextUtils.ellipsize(title, textPaint, colW, TextUtils.TruncateAt.END);
            canvas.drawText(elTitle, 0, elTitle.length(), colL, h - pad - a.dp(24), textPaint);

            paint.reset();
            paint.setColor(0xFFD5C9B2);
            canvas.drawRect(colL, h - pad - a.dp(18), colR, h - pad - a.dp(17), paint);

            drawTinyHeart(canvas, colL + a.dp(5), h - pad - a.dp(7), a.dp(9.5f), 0xFFD94A5A);
            textPaint.setTypeface(Typeface.DEFAULT);
            textPaint.setTextSize(a.dp(9f));
            textPaint.setColor(0xFF837868);
            canvas.drawText(dateStamp, colL + a.dp(13), h - pad - a.dp(3.5f), textPaint);
        }

        private void drawCinemaTicketStub(Canvas canvas, int w, int h) {
            paint.reset();
            paint.setShader(
                    new LinearGradient(
                            0f, 0f, w, h, 0xFF1C1E26, 0xFF101218, Shader.TileMode.CLAMP));
            canvas.drawRect(0f, 0f, w, h, paint);
            paint.setShader(null);

            float tearX = w * 0.68f;
            RectF photoBox = new RectF(0f, 0f, tearX - a.dp(1), h);
            drawCenterCropPhoto(canvas, photoBox, 0f);

            paint.reset();
            paint.setShader(
                    new LinearGradient(
                            0f,
                            0f,
                            0f,
                            h,
                            new int[] {0x2E000000, Color.TRANSPARENT, 0xD4000000},
                            new float[] {0f, 0.45f, 1f},
                            Shader.TileMode.CLAMP));
            canvas.drawRect(photoBox, paint);
            paint.setShader(null);

            float leftPad = a.dp(14);
            textPaint.reset();
            textPaint.setAntiAlias(true);
            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(13f));
            textPaint.setColor(Color.WHITE);
            CharSequence elTitle =
                    TextUtils.ellipsize(
                            title, textPaint, tearX - leftPad - a.dp(10), TextUtils.TruncateAt.END);
            canvas.drawText(elTitle, 0, elTitle.length(), leftPad, h - a.dp(25), textPaint);

            textPaint.setTextSize(a.dp(8.8f));
            textPaint.setColor(0xFFD8B872);
            canvas.drawText("SCREEN 01 · " + dateStamp, leftPad, h - a.dp(11), textPaint);

            // Perforated gold dash tear line
            paint.reset();
            paint.setColor(0x66D8B872);
            paint.setStrokeWidth(Math.max(1f, a.dp(1.2f)));
            paint.setStrokeCap(Paint.Cap.ROUND);
            for (float y = a.dp(12); y < h - a.dp(12); y += a.dp(9)) {
                canvas.drawLine(tearX, y, tearX, y + a.dp(4.5f), paint);
            }

            // Right stub: MARCO gold badge, ADMIT ONE, mini barcode, pink heart
            float stubL = tearX + a.dp(7);
            float stubR = w - a.dp(11);
            float stubCx = (stubL + stubR) * 0.5f;
            drawBrandStamp(
                    canvas, stubR, a.dp(12), 0x28D8B872, 0xAAD8B872, 0xFFFFE5A8, "MARCO", 0f);

            textPaint.reset();
            textPaint.setAntiAlias(true);
            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(7.8f));
            textPaint.setColor(0x8CFFFFFF);
            textPaint.setTextAlign(Paint.Align.CENTER);
            canvas.drawText("ADMIT ONE", stubCx, a.dp(46), textPaint);
            textPaint.setTextAlign(Paint.Align.LEFT);

            float[] bars = {1.8f, 1.0f, 2.6f, 1.2f, 1.0f, 2.8f, 1.4f, 1.0f, 2.2f, 1.2f, 2.5f};
            paint.reset();
            paint.setColor(0x88FFE5A8);
            float bx = stubL + a.dp(4);
            float barTop = h - a.dp(70);
            float barBot = h - a.dp(32);
            for (int i = 0; i < bars.length && bx < stubR - a.dp(4); i++) {
                float bw = a.dp(bars[i]);
                canvas.drawRoundRect(bx, barTop, bx + bw, barBot, a.dp(0.8f), a.dp(0.8f), paint);
                bx += bw + a.dp(i % 2 == 0 ? 2.4f : 1.8f);
            }
            drawTinyHeart(canvas, stubCx, h - a.dp(16), a.dp(11.5f), 0xFFFF2D55);
        }

        private void drawVintageAirMail(Canvas canvas, int w, int h) {
            canvas.drawColor(0xFFFAF6EC);
            // Crimson & navy diagonal airmail stripes
            float stripeW = a.dp(11);
            float gap = a.dp(7);
            int idx = 0;
            for (float start = -h; start < w + h; start += stripeW + gap) {
                Path sp = new Path();
                sp.moveTo(start, 0f);
                sp.lineTo(start + stripeW, 0f);
                sp.lineTo(start + stripeW - h, h);
                sp.lineTo(start - h, h);
                sp.close();
                paint.reset();
                paint.setAntiAlias(true);
                paint.setColor(idx % 2 == 0 ? 0xFFD63B48 : 0xFF22468A);
                canvas.drawPath(sp, paint);
                idx++;
            }

            float m = a.dp(5.5f);
            dstRect.set(m, m, w - m, h - m);
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(0xFFFCF8F0);
            canvas.drawRoundRect(dstRect, a.dp(8.5f), a.dp(8.5f), paint);

            float pPad = m + a.dp(8.5f);
            RectF photoBox = new RectF(pPad, pPad, w - pPad, h - m - a.dp(30));
            drawCenterCropPhoto(canvas, photoBox, a.dp(7));

            // PAR AVION blue badge top-left
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(0xD61F3E7A);
            canvas.drawRoundRect(
                    photoBox.left + a.dp(7),
                    photoBox.top + a.dp(7),
                    photoBox.left + a.dp(66),
                    photoBox.top + a.dp(23),
                    a.dp(4),
                    a.dp(4),
                    paint);
            textPaint.reset();
            textPaint.setAntiAlias(true);
            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(7.8f));
            textPaint.setColor(Color.WHITE);
            canvas.drawText(
                    "PAR AVION", photoBox.left + a.dp(12), photoBox.top + a.dp(18), textPaint);

            drawBrandStamp(
                    canvas,
                    photoBox.right - a.dp(7),
                    photoBox.top + a.dp(6),
                    0xE8B92B38,
                    0xFFFFD8B0,
                    Color.WHITE,
                    "MARCO",
                    -3.5f);

            float rowY = h - m - a.dp(12);
            drawTinyHeart(canvas, pPad + a.dp(6), rowY - a.dp(3.5f), a.dp(10.5f), 0xFFC93342);
            textPaint.setTextSize(a.dp(9.2f));
            textPaint.setColor(0xFF6B7386);
            float dateW = textPaint.measureText(dateStamp);
            canvas.drawText(dateStamp, w - pPad - dateW, rowY, textPaint);

            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(11.8f));
            textPaint.setColor(0xFF1D2230);
            float maxTw = Math.max(20f, (w - pPad - dateW - a.dp(8)) - (pPad + a.dp(16)));
            CharSequence elTitle =
                    TextUtils.ellipsize(title, textPaint, maxTw, TextUtils.TruncateAt.END);
            canvas.drawText(elTitle, 0, elTitle.length(), pPad + a.dp(16), rowY, textPaint);
        }

        private void drawFilmFrameCard(Canvas canvas, int w, int h) {
            canvas.drawColor(0xFF141418);
            // Gold rim border
            paint.reset();
            paint.setAntiAlias(true);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1f, a.dp(1f)));
            paint.setColor(0x44F6C26B);
            canvas.drawRoundRect(
                    a.dp(0.5f),
                    a.dp(0.5f),
                    w - a.dp(0.5f),
                    h - a.dp(0.5f),
                    a.dp(11),
                    a.dp(11),
                    paint);

            // Top & bottom 35mm film sprocket holes
            float holeW = a.dp(11);
            float holeH = a.dp(8);
            float step = a.dp(22);
            for (float x = a.dp(14); x < w - a.dp(14); x += step) {
                paint.reset();
                paint.setAntiAlias(true);
                paint.setColor(0xFF2B2D36);
                canvas.drawRoundRect(
                        x, a.dp(7), x + holeW, a.dp(7) + holeH, a.dp(2), a.dp(2), paint);
                canvas.drawRoundRect(
                        x, h - a.dp(15), x + holeW, h - a.dp(15) + holeH, a.dp(2), a.dp(2), paint);
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f, a.dp(0.6f)));
                paint.setColor(0x33F6C26B);
                canvas.drawRoundRect(
                        x, a.dp(7), x + holeW, a.dp(7) + holeH, a.dp(2), a.dp(2), paint);
                canvas.drawRoundRect(
                        x, h - a.dp(15), x + holeW, h - a.dp(15) + holeH, a.dp(2), a.dp(2), paint);
            }

            RectF photoBox = new RectF(a.dp(12), a.dp(22), w - a.dp(12), h - a.dp(22));
            drawCenterCropPhoto(canvas, photoBox, a.dp(6));

            paint.reset();
            paint.setShader(
                    new LinearGradient(
                            0f,
                            photoBox.top,
                            0f,
                            photoBox.bottom,
                            new int[] {0x24000000, Color.TRANSPARENT, 0xCC000000},
                            new float[] {0f, 0.50f, 1f},
                            Shader.TileMode.CLAMP));
            canvas.drawRoundRect(photoBox, a.dp(6), a.dp(6), paint);
            paint.setShader(null);

            drawBrandStamp(
                    canvas,
                    photoBox.right - a.dp(7),
                    photoBox.top + a.dp(7),
                    0xD8111116,
                    0xBBF6C26B,
                    0xFFF6C26B,
                    "35MM · MARCO",
                    0f);

            textPaint.reset();
            textPaint.setAntiAlias(true);
            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(9.2f));
            textPaint.setColor(0xFFF6C26B);
            float dateW = textPaint.measureText(dateStamp);
            float baseY = photoBox.bottom - a.dp(9);
            canvas.drawText(dateStamp, photoBox.right - a.dp(10) - dateW, baseY, textPaint);

            textPaint.setTextSize(a.dp(12f));
            textPaint.setColor(Color.WHITE);
            float maxTw = Math.max(20f, photoBox.width() - a.dp(26) - dateW);
            CharSequence elTitle =
                    TextUtils.ellipsize(title, textPaint, maxTw, TextUtils.TruncateAt.END);
            canvas.drawText(
                    elTitle, 0, elTitle.length(), photoBox.left + a.dp(10), baseY, textPaint);
        }
    }

    /** Top elastic Dynamic-Island / Punch-Hole confirmation capsule ({@code Marco Movie · 已收藏}). */
    private static final class IslandPillView extends View {
        private final MainActivity a;
        private final String feedbackLine;
        private final float islandW;
        private final float islandH;
        private final float islandTop;
        private Bitmap posterBitmap;
        private float expandProgress = 0f;

        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        private final TextPaint textPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        private final Rect srcRect = new Rect();
        private final RectF pillRect = new RectF();

        IslandPillView(
                MainActivity a,
                String title,
                Bitmap posterBitmap,
                float islandW,
                float islandH,
                float islandTop) {
            super(a);
            this.a = a;
            this.feedbackLine = title.isEmpty() ? "已收藏影片" : ("已收藏 " + title);
            this.posterBitmap = posterBitmap;
            this.islandW = islandW;
            this.islandH = islandH;
            this.islandTop = islandTop;
        }

        void setPosterBitmap(Bitmap bmp) {
            this.posterBitmap = bmp;
            invalidate();
        }

        void setExpandProgress(float progress) {
            this.expandProgress = progress;
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            if (w <= 0) return;
            float p = Math.max(0f, Math.min(1.15f, expandProgress));
            float clamped = clamp01(expandProgress);
            if (clamped <= 0.01f) return;

            float minH = islandH > 0f ? islandH : a.dp(34);
            float targetW = Math.min(a.dp(312), w - a.dp(24));
            float targetH = islandH > 0f ? (islandH + a.dp(56)) : a.dp(58);
            float curW =
                    Math.max(islandW, Math.min(w - a.dp(20), islandW + (targetW - islandW) * p));
            float curH = Math.max(minH, Math.min(targetH + a.dp(16), minH + (targetH - minH) * p));
            float left = Math.max(a.dp(12), Math.min(w - curW - a.dp(12), (w - curW) * 0.5f));
            float radius = (minH * 0.5f) + (a.dp(28) - minH * 0.5f) * clamped;

            pillRect.set(left, islandTop, left + curW, islandTop + curH);
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(0xFF000000);
            paint.setShadowLayer(
                    a.dp(14),
                    0f,
                    a.dp(6),
                    MobileTheme.withAlpha(0xFF000000, Math.round(120 * clamped)));
            canvas.drawRoundRect(pillRect, radius, radius, paint);
            paint.clearShadowLayer();

            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1f, a.dp(0.75f)));
            paint.setColor(MobileTheme.withAlpha(Color.WHITE, Math.round(38 * clamped)));
            canvas.drawRoundRect(pillRect, radius, radius, paint);

            float contentAlpha = clamp01((clamped - 0.15f) / 0.85f);
            if (contentAlpha <= 0.02f) return;
            int a255 = Math.round(255 * contentAlpha);

            float contentTop =
                    islandH > 0f ? (islandTop + islandH + a.dp(4)) : (islandTop + a.dp(6));
            float contentCenterY = (contentTop + pillRect.bottom - a.dp(6)) * 0.5f;

            // Mini cream-framed postcard thumbnail (40x28dp)
            float thumbW = a.dp(40);
            float thumbH = a.dp(28);
            float thumbL = left + a.dp(14);
            float thumbT = contentCenterY - thumbH * 0.5f;
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(MobileTheme.withAlpha(0xFFFAF6EE, a255));
            canvas.drawRoundRect(
                    thumbL, thumbT, thumbL + thumbW, thumbT + thumbH, a.dp(6), a.dp(6), paint);

            float pad = a.dp(1.5f);
            RectF innerThumb =
                    new RectF(
                            thumbL + pad,
                            thumbT + pad,
                            thumbL + thumbW - pad,
                            thumbT + thumbH - pad);
            int save = canvas.save();
            Path tp = new Path();
            tp.addRoundRect(innerThumb, a.dp(4), a.dp(4), Path.Direction.CW);
            canvas.clipPath(tp);
            if (posterBitmap != null && !posterBitmap.isRecycled()) {
                int bw = posterBitmap.getWidth(), bh = posterBitmap.getHeight();
                float sc = Math.max(innerThumb.width() / bw, innerThumb.height() / bh);
                float cw = innerThumb.width() / sc, ch = innerThumb.height() / sc;
                int sl = Math.max(0, Math.round((bw - cw) * 0.5f));
                int st = Math.max(0, Math.round((bh - ch) * 0.25f));
                srcRect.set(
                        sl,
                        st,
                        Math.min(bw, sl + Math.round(cw)),
                        Math.min(bh, st + Math.round(ch)));
                paint.reset();
                paint.setAntiAlias(true);
                paint.setFilterBitmap(true);
                paint.setAlpha(a255);
                canvas.drawBitmap(posterBitmap, srcRect, innerThumb, paint);
            } else {
                paint.reset();
                paint.setColor(MobileTheme.withAlpha(0xFF23252C, a255));
                canvas.drawRect(innerThumb, paint);
            }
            canvas.restoreToCount(save);

            // Right pink heart circle (28dp)
            float badgeR = a.dp(14);
            float badgeCx = pillRect.right - a.dp(14) - badgeR;
            paint.reset();
            paint.setAntiAlias(true);
            paint.setColor(MobileTheme.withAlpha(0xFFFF2D55, Math.round(58 * contentAlpha)));
            canvas.drawCircle(badgeCx, contentCenterY, badgeR, paint);

            Path hp = new Path();
            float hs = a.dp(6.5f);
            hp.moveTo(badgeCx, contentCenterY + hs * 0.85f);
            hp.cubicTo(
                    badgeCx - hs * 1.2f,
                    contentCenterY + hs * 0.1f,
                    badgeCx - hs * 1.15f,
                    contentCenterY - hs * 0.9f,
                    badgeCx,
                    contentCenterY - hs * 0.25f);
            hp.cubicTo(
                    badgeCx + hs * 1.15f,
                    contentCenterY - hs * 0.9f,
                    badgeCx + hs * 1.2f,
                    contentCenterY + hs * 0.1f,
                    badgeCx,
                    contentCenterY + hs * 0.85f);
            hp.close();
            paint.setColor(MobileTheme.withAlpha(0xFFFF2D55, a255));
            canvas.drawPath(hp, paint);

            // Center text: Marco Movie + 已收藏 <title>
            float textL = thumbL + thumbW + a.dp(10);
            float textMaxW = Math.max(20f, badgeCx - badgeR - a.dp(10) - textL);

            textPaint.reset();
            textPaint.setAntiAlias(true);
            textPaint.setTypeface(Typeface.DEFAULT_BOLD);
            textPaint.setTextSize(a.dp(10f));
            textPaint.setColor(MobileTheme.withAlpha(Color.WHITE, Math.round(140 * contentAlpha)));
            canvas.drawText("Marco Movie", textL, contentCenterY - a.dp(3), textPaint);

            textPaint.setTextSize(a.dp(13f));
            textPaint.setColor(MobileTheme.withAlpha(Color.WHITE, a255));
            CharSequence elLine =
                    TextUtils.ellipsize(
                            feedbackLine, textPaint, textMaxW, TextUtils.TruncateAt.END);
            canvas.drawText(
                    elLine, 0, elLine.length(), textL, contentCenterY + a.dp(13), textPaint);
        }
    }
}

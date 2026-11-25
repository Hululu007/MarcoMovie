package com.pilipala.marcomovie;

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
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;

/**
 * Pure 24x24dp rounded-stroke vector icon library for Android Mobile / Tablet.
 *
 * <p>Replaces all UI Chrome emoji and rough legacy shapes with crisp, anti-aliased vector drawings
 * that scale cleanly to any size as either a {@link View} ({@link IconView}) or {@link Drawable}
 * ({@link IconDrawable}).
 */
final class MobileIcons {
    // Nav bar
    static final int IC_DISCOVER = 1;
    static final int IC_LIVE = 2;
    static final int IC_LIBRARY = 3;
    static final int IC_SETTINGS = 4;
    static final int IC_SEARCH = 5;

    // Navigation & Actions
    static final int IC_BACK = 10;
    static final int IC_CLOSE = 11;
    static final int IC_CHEVRON_RIGHT = 12;
    static final int IC_CHEVRON_DOWN = 13;
    static final int IC_CHECK = 14;
    static final int IC_FILTER = 15;
    static final int IC_REFRESH = 16;
    static final int IC_MORE = 17;
    static final int IC_PLUS = 18;
    static final int IC_TRASH = 19;
    static final int IC_SORT = 20;
    static final int IC_EDIT = 21;
    static final int IC_MENU = 22;
    static final int IC_WARNING = 23;

    // Media & Player HUD
    static final int IC_PLAY = 30;
    static final int IC_PAUSE = 31;
    static final int IC_REWIND_15 = 32;
    static final int IC_FORWARD_15 = 33;
    static final int IC_PREV_EP = 34;
    static final int IC_NEXT_EP = 35;
    static final int IC_PIP = 36;
    static final int IC_CAST = 37;
    static final int IC_FULLSCREEN = 38;
    static final int IC_EXIT_FULLSCREEN = 39;
    static final int IC_ROTATE = 40;
    static final int IC_LOCK = 41;
    static final int IC_UNLOCK = 42;
    static final int IC_SUBTITLE = 43;
    static final int IC_DANMAKU = 44;
    static final int IC_SPEED = 45;
    static final int IC_VOLUME = 46;
    static final int IC_BRIGHTNESS = 47;
    static final int IC_BATTERY = 48;
    static final int IC_ENGINE = 49;
    static final int IC_ASPECT = 50;
    static final int IC_AUDIO_TRACK = 51;
    static final int IC_TIMER = 52;
    static final int IC_REPEAT = 53;
    static final int IC_EXTERNAL = 54;
    static final int IC_REPLAY = 55;
    static final int IC_SKIP = 56;

    // Library & Settings categories
    static final int IC_CLOUD_SYNC = 70;
    static final int IC_HEART = 71;
    static final int IC_HEART_FILLED = 72;
    static final int IC_HISTORY = 73;
    static final int IC_DOWNLOAD = 74;
    static final int IC_FOLDER = 75;
    static final int IC_CLIPBOARD = 76;
    static final int IC_LINK = 77;
    static final int IC_PALETTE = 78;
    static final int IC_SUN = 79;
    static final int IC_MOON = 80;
    static final int IC_THEME_AUTO = 81;
    static final int IC_SPARKLE = 82;
    static final int IC_STAR = 83;
    static final int IC_GESTURE = 84;
    static final int IC_PRIVACY = 85;
    static final int IC_STORAGE = 86;
    static final int IC_INFO = 87;
    static final int IC_TV_LINK = 88;
    static final int IC_NETDISK = 89;
    static final int IC_SLIDERS = 90;
    static final int IC_SWITCH_SOURCE = 91;
    static final int IC_BELL = 92;

    private MobileIcons() {}

    static IconView create(Context ctx, int icon, float sizeDp, int color) {
        return new IconView(ctx, icon, sizeDp, color);
    }

    static View view(MainActivity a, int icon, int sizeDp, int color) {
        return create(a, icon, sizeDp, color);
    }

    static IconDrawable drawable(Context ctx, int icon, float sizeDp, int color) {
        float density =
                ctx != null && ctx.getResources() != null
                        ? ctx.getResources().getDisplayMetrics().density
                        : 2f;
        int px = Math.max(1, Math.round(sizeDp * density));
        IconDrawable d = new IconDrawable(icon, px, color);
        d.setBounds(0, 0, px, px);
        return d;
    }

    /** Softly tinted rounded-square icon badge (zero stroke). */
    static FrameLayout badge(
            MainActivity a, int icon, int badgeTintColor, int boxSizeDp, int iconSizeDp) {
        MobileTheme.Palette p = MobileTheme.of(a);
        int tint = badgeTintColor != 0 ? badgeTintColor : p.accent;
        FrameLayout box = new FrameLayout(a);
        box.setBackground(a.bg(MobileTheme.withAlpha(tint, p.isDark ? 0x2E : 0x1E), 8));
        IconView iv = create(a, icon, iconSizeDp, tint);
        int iconPx = a.dp(iconSizeDp);
        box.addView(iv, new FrameLayout.LayoutParams(iconPx, iconPx, Gravity.CENTER));
        box.setMinimumWidth(a.dp(boxSizeDp));
        box.setMinimumHeight(a.dp(boxSizeDp));
        return box;
    }

    /** Standalone vector icon {@link View} with live tint, filled-state, and battery-level APIs. */
    static final class IconView extends View {
        private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int sizePx;
        private int icon;
        private int tint;
        private boolean filled;
        private int levelPercent = -1;
        private boolean charging;
        private float strokeWidthUnits = 1.9f;

        IconView(Context ctx, int icon, float sizeDp, int color) {
            super(ctx);
            float density =
                    ctx != null && ctx.getResources() != null
                            ? ctx.getResources().getDisplayMetrics().density
                            : 2f;
            this.sizePx = Math.max(1, Math.round(sizeDp * density));
            this.icon = icon;
            this.tint = color;
            initPaints(strokePaint, fillPaint);
            setClickable(false);
            setFocusable(false);
        }

        void setIcon(int nextIcon) {
            if (this.icon != nextIcon) {
                this.icon = nextIcon;
                invalidate();
            }
        }

        void setTint(int color) {
            if (this.tint != color) {
                this.tint = color;
                invalidate();
            }
        }

        void setFilled(boolean filled) {
            if (this.filled != filled) {
                this.filled = filled;
                invalidate();
            }
        }

        void setStrokeWidthUnits(float units) {
            if (units > 0f && this.strokeWidthUnits != units) {
                this.strokeWidthUnits = units;
                invalidate();
            }
        }

        void setLevel(int percent, boolean charging) {
            int clamped = Math.max(0, Math.min(100, percent));
            if (this.levelPercent != clamped || this.charging != charging) {
                this.levelPercent = clamped;
                this.charging = charging;
                invalidate();
            }
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            int w = resolveSize(sizePx + getPaddingLeft() + getPaddingRight(), widthMeasureSpec);
            int h = resolveSize(sizePx + getPaddingTop() + getPaddingBottom(), heightMeasureSpec);
            setMeasuredDimension(w, h);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float availW = getWidth() - getPaddingLeft() - getPaddingRight();
            float availH = getHeight() - getPaddingTop() - getPaddingBottom();
            float size = Math.min(availW, availH);
            if (size <= 0f) return;
            float ox = getPaddingLeft() + (availW - size) * 0.5f;
            float oy = getPaddingTop() + (availH - size) * 0.5f;
            drawIcon(
                    canvas,
                    ox,
                    oy,
                    size,
                    icon,
                    tint,
                    filled,
                    levelPercent,
                    charging,
                    strokeWidthUnits,
                    strokePaint,
                    fillPaint);
        }
    }

    /** Standalone vector icon {@link Drawable} for compound drawables and custom chrome. */
    static final class IconDrawable extends Drawable {
        private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int sizePx;
        private int icon;
        private int tint;
        private boolean filled;
        private int levelPercent = -1;
        private boolean charging;
        private int alpha = 255;

        IconDrawable(int icon, int sizePx, int color) {
            this.icon = icon;
            this.sizePx = sizePx;
            this.tint = color;
            initPaints(strokePaint, fillPaint);
        }

        void setIcon(int nextIcon) {
            if (this.icon != nextIcon) {
                this.icon = nextIcon;
                invalidateSelf();
            }
        }

        @Override
        public void setTint(int color) {
            if (this.tint != color) {
                this.tint = color;
                invalidateSelf();
            }
        }

        void setFilled(boolean filled) {
            if (this.filled != filled) {
                this.filled = filled;
                invalidateSelf();
            }
        }

        void setLevel(int percent, boolean charging) {
            int clamped = Math.max(0, Math.min(100, percent));
            if (this.levelPercent != clamped || this.charging != charging) {
                this.levelPercent = clamped;
                this.charging = charging;
                invalidateSelf();
            }
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
            float w = b.width() > 0 ? b.width() : sizePx;
            float h = b.height() > 0 ? b.height() : sizePx;
            float size = Math.min(w, h);
            if (size <= 0f) return;
            float ox = b.left + (w - size) * 0.5f;
            float oy = b.top + (h - size) * 0.5f;
            int effectiveColor = applyDrawableAlpha(tint, alpha);
            drawIcon(
                    canvas,
                    ox,
                    oy,
                    size,
                    icon,
                    effectiveColor,
                    filled,
                    levelPercent,
                    charging,
                    1.9f,
                    strokePaint,
                    fillPaint);
        }

        @Override
        public void setAlpha(int alpha) {
            this.alpha = Math.max(0, Math.min(255, alpha));
            invalidateSelf();
        }

        @Override
        public void setColorFilter(ColorFilter colorFilter) {
            strokePaint.setColorFilter(colorFilter);
            fillPaint.setColorFilter(colorFilter);
            invalidateSelf();
        }

        @Override
        @SuppressWarnings("deprecation")
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }

    private static int applyDrawableAlpha(int color, int alpha) {
        if (alpha >= 255) return color;
        int origA = (color >>> 24) & 0xFF;
        int combined = (origA * alpha) / 255;
        return (color & 0x00FFFFFF) | (combined << 24);
    }

    private static void initPaints(Paint stroke, Paint fill) {
        stroke.setStyle(Paint.Style.STROKE);
        stroke.setStrokeCap(Paint.Cap.ROUND);
        stroke.setStrokeJoin(Paint.Join.ROUND);
        fill.setStyle(Paint.Style.FILL);
        fill.setStrokeCap(Paint.Cap.ROUND);
        fill.setStrokeJoin(Paint.Join.ROUND);
    }

    static void drawIcon(
            Canvas c,
            float x,
            float y,
            float size,
            int icon,
            int color,
            boolean filled,
            int levelPercent,
            boolean charging,
            float strokeWidthUnits,
            Paint sp,
            Paint fp) {
        sp.setColor(color);
        sp.setStrokeWidth(strokeWidthUnits);
        fp.setColor(color);

        int save = c.save();
        c.translate(x, y);
        float scale = size / 24f;
        c.scale(scale, scale);

        switch (icon) {
            case IC_DISCOVER:
                drawDiscover(c, sp, fp, filled);
                break;
            case IC_LIVE:
                drawLive(c, sp, fp, filled);
                break;
            case IC_LIBRARY:
                drawLibrary(c, sp, fp, filled);
                break;
            case IC_SETTINGS:
                drawSettingsGear(c, sp, fp, filled);
                break;
            case IC_SEARCH:
                c.drawCircle(10.6f, 10.6f, 6.6f, sp);
                c.drawLine(15.5f, 15.5f, 20.4f, 20.4f, sp);
                break;
            case IC_BACK:
                drawPolyline(c, sp, 15f, 5.2f, 8.2f, 12f, 15f, 18.8f);
                break;
            case IC_CLOSE:
                c.drawLine(6.2f, 6.2f, 17.8f, 17.8f, sp);
                c.drawLine(17.8f, 6.2f, 6.2f, 17.8f, sp);
                break;
            case IC_CHEVRON_RIGHT:
                drawPolyline(c, sp, 9.2f, 5.8f, 15.4f, 12f, 9.2f, 18.2f);
                break;
            case IC_CHEVRON_DOWN:
                drawPolyline(c, sp, 5.8f, 9.2f, 12f, 15.4f, 18.2f, 9.2f);
                break;
            case IC_CHECK:
                drawPolyline(c, sp, 4.8f, 12.6f, 9.6f, 17.4f, 19.2f, 7.2f);
                break;
            case IC_FILTER:
                drawFilter(c, sp, fp, filled);
                break;
            case IC_REFRESH:
                drawRefresh(c, sp);
                break;
            case IC_MORE:
                c.drawCircle(5.5f, 12f, 1.65f, fp);
                c.drawCircle(12f, 12f, 1.65f, fp);
                c.drawCircle(18.5f, 12f, 1.65f, fp);
                break;
            case IC_PLUS:
                c.drawLine(12f, 5f, 12f, 19f, sp);
                c.drawLine(5f, 12f, 19f, 12f, sp);
                break;
            case IC_TRASH:
                drawTrash(c, sp);
                break;
            case IC_SORT:
                c.drawLine(7.6f, 18.5f, 7.6f, 5.5f, sp);
                drawPolyline(c, sp, 4.8f, 8.3f, 7.6f, 5.5f, 10.4f, 8.3f);
                c.drawLine(16.4f, 5.5f, 16.4f, 18.5f, sp);
                drawPolyline(c, sp, 13.6f, 15.7f, 16.4f, 18.5f, 19.2f, 15.7f);
                break;
            case IC_EDIT:
                drawEdit(c, sp);
                break;
            case IC_MENU:
                c.drawLine(4.2f, 6.8f, 19.8f, 6.8f, sp);
                c.drawLine(4.2f, 12f, 19.8f, 12f, sp);
                c.drawLine(4.2f, 17.2f, 19.8f, 17.2f, sp);
                break;
            case IC_WARNING:
                drawWarning(c, sp, fp);
                break;
            case IC_PLAY:
                drawPlay(c, sp, fp);
                break;
            case IC_PAUSE:
                c.drawRoundRect(new RectF(6.2f, 4.8f, 10.1f, 19.2f), 1.4f, 1.4f, fp);
                c.drawRoundRect(new RectF(13.9f, 4.8f, 17.8f, 19.2f), 1.4f, 1.4f, fp);
                break;
            case IC_REWIND_15:
                drawSkip15(c, sp, fp, false);
                break;
            case IC_FORWARD_15:
                drawSkip15(c, sp, fp, true);
                break;
            case IC_PREV_EP:
                drawPrevNext(c, sp, fp, false);
                break;
            case IC_NEXT_EP:
                drawPrevNext(c, sp, fp, true);
                break;
            case IC_PIP:
                c.drawRoundRect(new RectF(2.8f, 4.6f, 21.2f, 19.4f), 2.3f, 2.3f, sp);
                c.drawRoundRect(new RectF(12.2f, 11.4f, 18.8f, 16.8f), 1.2f, 1.2f, fp);
                break;
            case IC_CAST:
                drawCast(c, sp, fp);
                break;
            case IC_FULLSCREEN:
                drawFullscreen(c, sp, false);
                break;
            case IC_EXIT_FULLSCREEN:
                drawFullscreen(c, sp, true);
                break;
            case IC_ROTATE:
                drawRotate(c, sp);
                break;
            case IC_LOCK:
                drawLock(c, sp, fp, true);
                break;
            case IC_UNLOCK:
                drawLock(c, sp, fp, false);
                break;
            case IC_SUBTITLE:
                c.drawRoundRect(new RectF(3f, 5.4f, 21f, 18.6f), 2.4f, 2.4f, sp);
                c.drawLine(6.4f, 12.2f, 12.2f, 12.2f, sp);
                c.drawLine(14.8f, 12.2f, 17.6f, 12.2f, sp);
                c.drawLine(6.4f, 15.2f, 9.6f, 15.2f, sp);
                c.drawLine(12.2f, 15.2f, 17.6f, 15.2f, sp);
                break;
            case IC_DANMAKU:
                c.drawRoundRect(new RectF(3f, 5f, 21f, 19f), 2.6f, 2.6f, sp);
                c.drawLine(6f, 9.2f, 13.2f, 9.2f, sp);
                c.drawLine(10.8f, 12.2f, 18f, 12.2f, sp);
                c.drawLine(6.4f, 15.2f, 14.4f, 15.2f, sp);
                break;
            case IC_SPEED:
                drawSpeed(c, sp, fp);
                break;
            case IC_VOLUME:
                drawVolume(c, sp);
                break;
            case IC_BRIGHTNESS:
            case IC_SUN:
                drawSun(c, sp);
                break;
            case IC_BATTERY:
                drawBattery(c, sp, fp, color, levelPercent, charging);
                break;
            case IC_ENGINE:
                drawEngine(c, sp);
                break;
            case IC_ASPECT:
                drawAspect(c, sp);
                break;
            case IC_AUDIO_TRACK:
                c.drawLine(4.8f, 10.2f, 4.8f, 13.8f, sp);
                c.drawLine(8.4f, 7.2f, 8.4f, 16.8f, sp);
                c.drawLine(12f, 4.6f, 12f, 19.4f, sp);
                c.drawLine(15.6f, 7.8f, 15.6f, 16.2f, sp);
                c.drawLine(19.2f, 10.4f, 19.2f, 13.6f, sp);
                break;
            case IC_TIMER:
                c.drawLine(9.5f, 3f, 14.5f, 3f, sp);
                c.drawLine(12f, 3f, 12f, 5.4f, sp);
                c.drawCircle(12f, 13.3f, 7.6f, sp);
                c.drawLine(12f, 13.3f, 12f, 9.2f, sp);
                c.drawLine(12f, 13.3f, 15.2f, 13.3f, sp);
                break;
            case IC_REPEAT:
                drawRepeat(c, sp);
                break;
            case IC_EXTERNAL:
                drawExternal(c, sp);
                break;
            case IC_REPLAY:
                drawReplay(c, sp);
                break;
            case IC_SKIP:
                drawPolyline(c, sp, 4.6f, 7.2f, 10.2f, 12f, 4.6f, 16.8f);
                drawPolyline(c, sp, 11.2f, 7.2f, 16.8f, 12f, 11.2f, 16.8f);
                c.drawLine(19.6f, 6.8f, 19.6f, 17.2f, sp);
                break;
            case IC_CLOUD_SYNC:
                drawCloudSync(c, sp);
                break;
            case IC_HEART:
                drawHeart(c, sp, fp, filled);
                break;
            case IC_HEART_FILLED:
                drawHeart(c, sp, fp, true);
                break;
            case IC_HISTORY:
                drawHistory(c, sp);
                break;
            case IC_DOWNLOAD:
                c.drawLine(12f, 4.4f, 12f, 15f, sp);
                drawPolyline(c, sp, 8f, 11.2f, 12f, 15.2f, 16f, 11.2f);
                drawPolyline(c, sp, 4.5f, 15.6f, 4.5f, 19.2f, 19.5f, 19.2f, 19.5f, 15.6f);
                break;
            case IC_FOLDER:
                drawFolder(c, sp);
                break;
            case IC_CLIPBOARD:
                drawClipboard(c, sp);
                break;
            case IC_LINK:
                drawLink(c, sp);
                break;
            case IC_PALETTE:
                drawPalette(c, sp, fp);
                break;
            case IC_MOON:
                drawMoon(c, sp, fp, filled);
                break;
            case IC_THEME_AUTO:
                drawThemeAuto(c, sp, fp);
                break;
            case IC_SPARKLE:
                drawSparkle(c, sp, fp, filled);
                break;
            case IC_STAR:
                drawStar(c, sp, fp, filled);
                break;
            case IC_GESTURE:
                drawGesture(c, sp, fp);
                break;
            case IC_PRIVACY:
                drawPrivacy(c, sp);
                break;
            case IC_STORAGE:
                drawStorage(c, sp);
                break;
            case IC_INFO:
                c.drawCircle(12f, 12f, 8.6f, sp);
                c.drawCircle(12f, 8.2f, 1.15f, fp);
                c.drawLine(12f, 11.2f, 12f, 16.4f, sp);
                break;
            case IC_TV_LINK:
                drawTvLink(c, sp, fp);
                break;
            case IC_NETDISK:
                drawNetdisk(c, sp, fp);
                break;
            case IC_SLIDERS:
                drawSliders(c, sp, fp);
                break;
            case IC_SWITCH_SOURCE:
                c.drawLine(4.5f, 8.4f, 19.5f, 8.4f, sp);
                drawPolyline(c, sp, 16.1f, 5.2f, 19.5f, 8.4f, 16.1f, 11.6f);
                c.drawLine(19.5f, 15.6f, 4.5f, 15.6f, sp);
                drawPolyline(c, sp, 7.9f, 12.4f, 4.5f, 15.6f, 7.9f, 18.8f);
                break;
            case IC_BELL:
                drawBell(c, sp);
                break;
            default:
                c.drawCircle(12f, 12f, 7.5f, sp);
                break;
        }

        c.restoreToCount(save);
    }

    private static void drawPolyline(Canvas c, Paint p, float... pts) {
        if (pts.length < 4) return;
        Path path = new Path();
        path.moveTo(pts[0], pts[1]);
        for (int i = 2; i + 1 < pts.length; i += 2) {
            path.lineTo(pts[i], pts[i + 1]);
        }
        c.drawPath(path, p);
    }

    private static void drawDiscover(Canvas c, Paint sp, Paint fp, boolean filled) {
        Path star = new Path();
        star.moveTo(12f, 2.6f);
        star.quadTo(12.6f, 11.4f, 21.4f, 12f);
        star.quadTo(12.6f, 12.6f, 12f, 21.4f);
        star.quadTo(11.4f, 12.6f, 2.6f, 12f);
        star.quadTo(11.4f, 11.4f, 12f, 2.6f);
        star.close();
        if (filled) {
            c.drawPath(star, fp);
        }
        c.drawPath(star, sp);
    }

    private static void drawLive(Canvas c, Paint sp, Paint fp, boolean filled) {
        RectF screen = new RectF(3f, 7.8f, 21f, 18.6f);
        if (filled) {
            c.drawRoundRect(screen, 2.6f, 2.6f, sp);
            Path play = new Path();
            play.moveTo(10.4f, 10.7f);
            play.lineTo(15.0f, 13.2f);
            play.lineTo(10.4f, 15.7f);
            play.close();
            c.drawPath(play, fp);
        } else {
            c.drawRoundRect(screen, 2.6f, 2.6f, sp);
        }
        c.drawLine(8.6f, 21f, 15.4f, 21f, sp);
        // Broadcast signal arcs above screen
        c.drawArc(new RectF(9.2f, 4.4f, 14.8f, 10f), -135f, 90f, false, sp);
        c.drawArc(new RectF(6.8f, 2f, 17.2f, 12.4f), -135f, 90f, false, sp);
    }

    private static void drawLibrary(Canvas c, Paint sp, Paint fp, boolean filled) {
        c.drawLine(8.2f, 3.6f, 15.8f, 3.6f, sp);
        c.drawLine(5.8f, 6.2f, 18.2f, 6.2f, sp);
        RectF card = new RectF(3.5f, 8.8f, 20.5f, 20.2f);
        c.drawRoundRect(card, 2.5f, 2.5f, sp);
        Path play = new Path();
        play.moveTo(10.3f, 11.9f);
        play.lineTo(15.1f, 14.5f);
        play.lineTo(10.3f, 17.1f);
        play.close();
        if (filled) {
            c.drawPath(play, fp);
        } else {
            c.drawPath(play, sp);
        }
    }

    /** Precision 6-tooth mechanical gear (never concentric target circles). */
    private static void drawSettingsGear(Canvas c, Paint sp, Paint fp, boolean filled) {
        Path gear = new Path();
        final float cx = 12f;
        final float cy = 12f;
        final float rInner = 6.7f;
        final float rOuter = 9.5f;
        for (int i = 0; i < 6; i++) {
            double baseDeg = -90.0 + i * 60.0;
            double[] degs = {
                baseDeg - 26.0, baseDeg - 15.0, baseDeg - 10.5, baseDeg + 10.5, baseDeg + 15.0
            };
            float[] radii = {rInner, rInner, rOuter, rOuter, rInner};
            for (int j = 0; j < degs.length; j++) {
                double rad = Math.toRadians(degs[j]);
                float px = cx + (float) (Math.cos(rad) * radii[j]);
                float py = cy + (float) (Math.sin(rad) * radii[j]);
                if (i == 0 && j == 0) gear.moveTo(px, py);
                else gear.lineTo(px, py);
            }
        }
        gear.close();
        if (filled) {
            Path donut = new Path();
            donut.addPath(gear);
            donut.addCircle(cx, cy, 3.3f, Path.Direction.CCW);
            donut.setFillType(Path.FillType.EVEN_ODD);
            c.drawPath(donut, fp);
        } else {
            c.drawPath(gear, sp);
            c.drawCircle(cx, cy, 3.1f, sp);
        }
    }

    private static void drawFilter(Canvas c, Paint sp, Paint fp, boolean filled) {
        Path funnel = new Path();
        funnel.moveTo(3.6f, 5.2f);
        funnel.lineTo(20.4f, 5.2f);
        funnel.lineTo(14.2f, 12.2f);
        funnel.lineTo(14.2f, 18.6f);
        funnel.lineTo(9.8f, 20.5f);
        funnel.lineTo(9.8f, 12.2f);
        funnel.close();
        if (filled) {
            c.drawPath(funnel, fp);
        }
        c.drawPath(funnel, sp);
    }

    private static void drawRefresh(Canvas c, Paint sp) {
        c.drawArc(new RectF(4.4f, 4.4f, 19.6f, 19.6f), -48f, 295f, false, sp);
        drawPolyline(c, sp, 19.4f, 4.5f, 19.4f, 9.2f, 14.8f, 9.2f);
    }

    private static void drawTrash(Canvas c, Paint sp) {
        c.drawLine(4.2f, 6.6f, 19.8f, 6.6f, sp);
        drawPolyline(c, sp, 9.2f, 6.6f, 9.2f, 4.2f, 14.8f, 4.2f, 14.8f, 6.6f);
        drawPolyline(c, sp, 6.2f, 6.6f, 7.1f, 19.8f, 16.9f, 19.8f, 17.8f, 6.6f);
        c.drawLine(10.1f, 10.4f, 10.4f, 16.4f, sp);
        c.drawLine(13.9f, 10.4f, 13.6f, 16.4f, sp);
    }

    private static void drawEdit(Canvas c, Paint sp) {
        Path body = new Path();
        body.moveTo(16.4f, 3.8f);
        body.lineTo(20.2f, 7.6f);
        body.lineTo(8.3f, 19.5f);
        body.lineTo(4.1f, 20.1f);
        body.lineTo(4.7f, 15.9f);
        body.close();
        c.drawPath(body, sp);
        c.drawLine(14.1f, 6.1f, 17.9f, 9.9f, sp);
    }

    private static void drawPlay(Canvas c, Paint sp, Paint fp) {
        Path tri = new Path();
        tri.moveTo(7.3f, 4.8f);
        tri.lineTo(19.2f, 12f);
        tri.lineTo(7.3f, 19.2f);
        tri.close();
        c.drawPath(tri, fp);
        c.drawPath(tri, sp);
    }

    private static void drawSkip15(Canvas c, Paint sp, Paint fp, boolean forward) {
        RectF oval = new RectF(4.2f, 4.8f, 19.8f, 20.4f);
        if (forward) {
            c.drawArc(oval, -100f, -295f, false, sp);
            drawPolyline(c, sp, 13.4f, 2.8f, 15.8f, 5.2f, 12.8f, 7.5f);
        } else {
            c.drawArc(oval, -80f, 295f, false, sp);
            drawPolyline(c, sp, 10.6f, 2.8f, 8.2f, 5.2f, 11.2f, 7.5f);
        }
        Paint textPaint = new Paint(fp);
        textPaint.setTextAlign(Paint.Align.CENTER);
        textPaint.setTextSize(7.1f);
        textPaint.setTypeface(Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD));
        c.drawText("15", 12f, 15.4f, textPaint);
    }

    private static void drawPrevNext(Canvas c, Paint sp, Paint fp, boolean next) {
        Path tri = new Path();
        if (next) {
            tri.moveTo(5.5f, 6.4f);
            tri.lineTo(14.5f, 12f);
            tri.lineTo(5.5f, 17.6f);
            tri.close();
            c.drawPath(tri, fp);
            c.drawPath(tri, sp);
            c.drawLine(18.5f, 6f, 18.5f, 18f, sp);
        } else {
            c.drawLine(5.5f, 6f, 5.5f, 18f, sp);
            tri.moveTo(18.5f, 6.4f);
            tri.lineTo(9.5f, 12f);
            tri.lineTo(18.5f, 17.6f);
            tri.close();
            c.drawPath(tri, fp);
            c.drawPath(tri, sp);
        }
    }

    private static void drawCast(Canvas c, Paint sp, Paint fp) {
        drawPolyline(c, sp, 3f, 8.6f, 3f, 5.4f, 21f, 5.4f, 21f, 18.6f, 14.2f, 18.6f);
        c.drawCircle(3.6f, 18.2f, 1.15f, fp);
        c.drawArc(new RectF(-0.8f, 13.8f, 8f, 22.6f), -90f, 90f, false, sp);
        c.drawArc(new RectF(-4.4f, 10.2f, 11.6f, 26.2f), -90f, 90f, false, sp);
    }

    private static void drawFullscreen(Canvas c, Paint sp, boolean exit) {
        if (!exit) {
            drawPolyline(c, sp, 4.2f, 9f, 4.2f, 4.2f, 9f, 4.2f);
            drawPolyline(c, sp, 15f, 4.2f, 19.8f, 4.2f, 19.8f, 9f);
            drawPolyline(c, sp, 19.8f, 15f, 19.8f, 19.8f, 15f, 19.8f);
            drawPolyline(c, sp, 9f, 19.8f, 4.2f, 19.8f, 4.2f, 15f);
        } else {
            drawPolyline(c, sp, 9f, 4.2f, 9f, 9f, 4.2f, 9f);
            drawPolyline(c, sp, 19.8f, 9f, 15f, 9f, 15f, 4.2f);
            drawPolyline(c, sp, 15f, 19.8f, 15f, 15f, 19.8f, 15f);
            drawPolyline(c, sp, 4.2f, 15f, 9f, 15f, 9f, 19.8f);
        }
    }

    private static void drawRotate(Canvas c, Paint sp) {
        c.drawRoundRect(new RectF(5.2f, 7.6f, 15.6f, 19.4f), 2f, 2f, sp);
        c.drawArc(new RectF(7.4f, 3.6f, 20.6f, 16.8f), -85f, 95f, false, sp);
        drawPolyline(c, sp, 17.8f, 8.6f, 20.5f, 11.4f, 22f, 8.2f);
    }

    private static void drawLock(Canvas c, Paint sp, Paint fp, boolean locked) {
        c.drawRoundRect(new RectF(5.4f, 10.8f, 18.6f, 20.2f), 2.3f, 2.3f, sp);
        c.drawCircle(12f, 15.4f, 1.35f, fp);
        if (locked) {
            Path shackle = new Path();
            shackle.moveTo(8.3f, 10.8f);
            shackle.lineTo(8.3f, 7.8f);
            shackle.arcTo(new RectF(8.3f, 4.1f, 15.7f, 11.5f), 180f, 180f, false);
            shackle.lineTo(15.7f, 10.8f);
            c.drawPath(shackle, sp);
        } else {
            Path shackle = new Path();
            shackle.moveTo(8.3f, 10.8f);
            shackle.lineTo(8.3f, 7.6f);
            shackle.arcTo(new RectF(8.3f, 3.9f, 15.7f, 11.3f), 180f, 145f, false);
            c.drawPath(shackle, sp);
        }
    }

    private static void drawSpeed(Canvas c, Paint sp, Paint fp) {
        c.drawArc(new RectF(3.5f, 4.8f, 20.5f, 21.8f), 150f, 240f, false, sp);
        c.drawLine(12f, 13.8f, 16.6f, 9.2f, sp);
        c.drawCircle(12f, 13.8f, 1.6f, fp);
    }

    private static void drawVolume(Canvas c, Paint sp) {
        Path cone = new Path();
        cone.moveTo(3.6f, 9.6f);
        cone.lineTo(7.4f, 9.6f);
        cone.lineTo(12.2f, 5.8f);
        cone.lineTo(12.2f, 18.2f);
        cone.lineTo(7.4f, 14.4f);
        cone.lineTo(3.6f, 14.4f);
        cone.close();
        c.drawPath(cone, sp);
        c.drawArc(new RectF(12.4f, 8.6f, 16.6f, 15.4f), -50f, 100f, false, sp);
        c.drawArc(new RectF(13.2f, 5.8f, 20.4f, 18.2f), -50f, 100f, false, sp);
    }

    private static void drawSun(Canvas c, Paint sp) {
        c.drawCircle(12f, 12f, 4.1f, sp);
        for (int i = 0; i < 8; i++) {
            double rad = Math.toRadians(i * 45.0);
            float cos = (float) Math.cos(rad);
            float sin = (float) Math.sin(rad);
            c.drawLine(12f + cos * 7.1f, 12f + sin * 7.1f, 12f + cos * 9.5f, 12f + sin * 9.5f, sp);
        }
    }

    private static void drawBattery(
            Canvas c, Paint sp, Paint fp, int baseColor, int levelPercent, boolean charging) {
        c.drawRoundRect(new RectF(2.4f, 6.8f, 19.2f, 17.2f), 2.2f, 2.2f, sp);
        c.drawLine(21.1f, 10.1f, 21.1f, 13.9f, sp);
        int pct = levelPercent < 0 ? 75 : Math.max(0, Math.min(100, levelPercent));
        int fillColor = baseColor;
        if (charging) {
            fillColor = 0xFF10B981;
        } else if (pct <= 20) {
            fillColor = 0xFFFF3B30;
        }
        float innerLeft = 4.6f;
        float innerMaxW = 12.4f;
        float fillW = innerMaxW * (pct / 100f);
        if (fillW > 0.6f) {
            Paint bar = new Paint(fp);
            bar.setColor(fillColor);
            c.drawRoundRect(new RectF(innerLeft, 9.0f, innerLeft + fillW, 15.0f), 1.0f, 1.0f, bar);
        }
        if (charging) {
            Paint bolt = new Paint(sp);
            bolt.setColor(0xFFFFFFFF);
            bolt.setStrokeWidth(1.4f);
            drawPolyline(c, bolt, 11.8f, 8.6f, 9.8f, 12.1f, 12.2f, 12.1f, 10.4f, 15.4f);
        }
    }

    private static void drawEngine(Canvas c, Paint sp) {
        c.drawRoundRect(new RectF(6.5f, 6.5f, 17.5f, 17.5f), 2f, 2f, sp);
        c.drawRoundRect(new RectF(9.9f, 9.9f, 14.1f, 14.1f), 0.7f, 0.7f, sp);
        c.drawLine(9.5f, 3.6f, 9.5f, 6.2f, sp);
        c.drawLine(14.5f, 3.6f, 14.5f, 6.2f, sp);
        c.drawLine(9.5f, 17.8f, 9.5f, 20.4f, sp);
        c.drawLine(14.5f, 17.8f, 14.5f, 20.4f, sp);
        c.drawLine(3.6f, 9.5f, 6.2f, 9.5f, sp);
        c.drawLine(3.6f, 14.5f, 6.2f, 14.5f, sp);
        c.drawLine(17.8f, 9.5f, 20.4f, 9.5f, sp);
        c.drawLine(17.8f, 14.5f, 20.4f, 14.5f, sp);
    }

    private static void drawAspect(Canvas c, Paint sp) {
        c.drawRoundRect(new RectF(3f, 5.4f, 21f, 18.6f), 2.3f, 2.3f, sp);
        drawPolyline(c, sp, 6.5f, 11.2f, 6.5f, 8.6f, 9.2f, 8.6f);
        drawPolyline(c, sp, 17.5f, 12.8f, 17.5f, 15.4f, 14.8f, 15.4f);
    }

    private static void drawRepeat(Canvas c, Paint sp) {
        drawPolyline(c, sp, 5f, 10.6f, 5f, 7.6f, 19f, 7.6f);
        drawPolyline(c, sp, 16.2f, 4.8f, 19f, 7.6f, 16.2f, 10.4f);
        drawPolyline(c, sp, 19f, 13.4f, 19f, 16.4f, 5f, 16.4f);
        drawPolyline(c, sp, 7.8f, 13.6f, 5f, 16.4f, 7.8f, 19.2f);
    }

    private static void drawExternal(Canvas c, Paint sp) {
        drawPolyline(c, sp, 11.4f, 5.4f, 5.2f, 5.4f, 5.2f, 18.8f, 18.6f, 18.8f, 18.6f, 12.6f);
        c.drawLine(11.4f, 12.6f, 19f, 5f, sp);
        drawPolyline(c, sp, 14.2f, 5f, 19f, 5f, 19f, 9.8f);
    }

    private static void drawReplay(Canvas c, Paint sp) {
        c.drawArc(new RectF(4.4f, 4.4f, 19.6f, 19.6f), -135f, 295f, false, sp);
        drawPolyline(c, sp, 4.6f, 4.5f, 4.6f, 9.2f, 9.2f, 9.2f);
    }

    private static void drawCloudSync(Canvas c, Paint sp) {
        Path cloud = new Path();
        cloud.moveTo(7.4f, 16.6f);
        cloud.lineTo(17.2f, 16.6f);
        cloud.arcTo(new RectF(14.4f, 10.2f, 20.8f, 16.6f), 90f, -180f, false);
        cloud.arcTo(new RectF(7.6f, 5.4f, 16.6f, 14.4f), -15f, -165f, false);
        cloud.arcTo(new RectF(3.4f, 9.6f, 10.4f, 16.6f), -100f, -170f, false);
        cloud.close();
        c.drawPath(cloud, sp);
        c.drawLine(12f, 19.8f, 12f, 12.4f, sp);
        drawPolyline(c, sp, 9.6f, 14.6f, 12f, 12.2f, 14.4f, 14.6f);
    }

    private static void drawHeart(Canvas c, Paint sp, Paint fp, boolean filled) {
        Path heart = new Path();
        heart.moveTo(12f, 19.6f);
        heart.cubicTo(4.8f, 14.8f, 3.2f, 10.6f, 4.2f, 7.6f);
        heart.cubicTo(5.1f, 4.9f, 8.7f, 4.4f, 11.1f, 6.7f);
        heart.lineTo(12f, 7.6f);
        heart.lineTo(12.9f, 6.7f);
        heart.cubicTo(15.3f, 4.4f, 18.9f, 4.9f, 19.8f, 7.6f);
        heart.cubicTo(20.8f, 10.6f, 19.2f, 14.8f, 12f, 19.6f);
        heart.close();
        if (filled) {
            c.drawPath(heart, fp);
        }
        c.drawPath(heart, sp);
    }

    private static void drawHistory(Canvas c, Paint sp) {
        c.drawArc(new RectF(4.2f, 4.2f, 19.8f, 19.8f), -145f, 305f, false, sp);
        drawPolyline(c, sp, 4.3f, 5.5f, 4.3f, 9.8f, 8.6f, 9.8f);
        c.drawLine(12f, 8.2f, 12f, 12.5f, sp);
        c.drawLine(12f, 12.5f, 15.2f, 14.2f, sp);
    }

    private static void drawFolder(Canvas c, Paint sp) {
        Path f = new Path();
        f.moveTo(3.4f, 7.2f);
        f.quadTo(3.4f, 5.6f, 5f, 5.6f);
        f.lineTo(9.4f, 5.6f);
        f.lineTo(11.4f, 8.2f);
        f.lineTo(19f, 8.2f);
        f.quadTo(20.6f, 8.2f, 20.6f, 9.8f);
        f.lineTo(20.6f, 17.4f);
        f.quadTo(20.6f, 19f, 19f, 19f);
        f.lineTo(5f, 19f);
        f.quadTo(3.4f, 19f, 3.4f, 17.4f);
        f.close();
        c.drawPath(f, sp);
    }

    private static void drawClipboard(Canvas c, Paint sp) {
        c.drawRoundRect(new RectF(8.8f, 3.4f, 15.2f, 6.8f), 1.3f, 1.3f, sp);
        Path board = new Path();
        board.moveTo(8.8f, 5.2f);
        board.lineTo(6.6f, 5.2f);
        board.quadTo(5f, 5.2f, 5f, 6.8f);
        board.lineTo(5f, 18.8f);
        board.quadTo(5f, 20.4f, 6.6f, 20.4f);
        board.lineTo(17.4f, 20.4f);
        board.quadTo(19f, 20.4f, 19f, 18.8f);
        board.lineTo(19f, 6.8f);
        board.quadTo(19f, 5.2f, 17.4f, 5.2f);
        board.lineTo(15.2f, 5.2f);
        c.drawPath(board, sp);
        c.drawLine(8.6f, 11.8f, 15.4f, 11.8f, sp);
        c.drawLine(8.6f, 15.4f, 13.6f, 15.4f, sp);
    }

    private static void drawLink(Canvas c, Paint sp) {
        int s = c.save();
        c.rotate(-45f, 12f, 12f);
        c.drawRoundRect(new RectF(3.6f, 9.2f, 11.6f, 14.8f), 2.8f, 2.8f, sp);
        c.drawRoundRect(new RectF(12.4f, 9.2f, 20.4f, 14.8f), 2.8f, 2.8f, sp);
        c.drawLine(9.5f, 12f, 14.5f, 12f, sp);
        c.restoreToCount(s);
    }

    private static void drawPalette(Canvas c, Paint sp, Paint fp) {
        c.drawArc(new RectF(3.4f, 3.4f, 20.6f, 20.6f), 55f, 285f, false, sp);
        Path notch = new Path();
        notch.moveTo(16.9f, 19f);
        notch.quadTo(13.8f, 17.8f, 15f, 15.2f);
        notch.quadTo(16.2f, 13.4f, 19.6f, 14.2f);
        c.drawPath(notch, sp);
        c.drawCircle(8.4f, 9.6f, 1.25f, fp);
        c.drawCircle(12.4f, 7.6f, 1.25f, fp);
        c.drawCircle(16.1f, 9.8f, 1.25f, fp);
        c.drawCircle(8.2f, 14.1f, 1.25f, fp);
    }

    private static void drawMoon(Canvas c, Paint sp, Paint fp, boolean filled) {
        Path moon = new Path();
        moon.moveTo(18.8f, 14.6f);
        moon.arcTo(new RectF(4.4f, 4.4f, 19.6f, 19.6f), 22f, 255f, false);
        moon.arcTo(new RectF(9.2f, 3.4f, 21.8f, 16f), 192f, -112f, false);
        moon.close();
        if (filled) {
            c.drawPath(moon, fp);
        }
        c.drawPath(moon, sp);
    }

    private static void drawThemeAuto(Canvas c, Paint sp, Paint fp) {
        c.drawCircle(12f, 12f, 8.2f, sp);
        Path half = new Path();
        half.arcTo(new RectF(3.8f, 3.8f, 20.2f, 20.2f), -90f, 180f, true);
        half.close();
        c.drawPath(half, fp);
    }

    private static void drawSparkle(Canvas c, Paint sp, Paint fp, boolean filled) {
        Path big = new Path();
        big.moveTo(10.2f, 4.2f);
        big.quadTo(10.8f, 12.2f, 18.2f, 13f);
        big.quadTo(10.8f, 13.8f, 10.2f, 20.8f);
        big.quadTo(9.6f, 13.8f, 2.8f, 13f);
        big.quadTo(9.6f, 12.2f, 10.2f, 4.2f);
        big.close();
        if (filled) c.drawPath(big, fp);
        c.drawPath(big, sp);

        Path small = new Path();
        small.moveTo(18.2f, 3.4f);
        small.quadTo(18.5f, 6.2f, 21.2f, 6.6f);
        small.quadTo(18.5f, 7f, 18.2f, 9.8f);
        small.quadTo(17.9f, 7f, 15.2f, 6.6f);
        small.quadTo(17.9f, 6.2f, 18.2f, 3.4f);
        small.close();
        c.drawPath(small, fp);
    }

    private static void drawStar(Canvas c, Paint sp, Paint fp, boolean filled) {
        Path star = new Path();
        for (int i = 0; i < 10; i++) {
            double rad = Math.toRadians(-90.0 + i * 36.0);
            float r = (i % 2 == 0) ? 8.8f : 3.9f;
            float px = 12f + (float) (Math.cos(rad) * r);
            float py = 12.4f + (float) (Math.sin(rad) * r);
            if (i == 0) star.moveTo(px, py);
            else star.lineTo(px, py);
        }
        star.close();
        if (filled) c.drawPath(star, fp);
        c.drawPath(star, sp);
    }

    private static void drawGesture(Canvas c, Paint sp, Paint fp) {
        c.drawCircle(12f, 12f, 2.2f, fp);
        c.drawCircle(12f, 12f, 5.4f, sp);
        drawPolyline(c, sp, 5.6f, 9.2f, 3f, 12f, 5.6f, 14.8f);
        drawPolyline(c, sp, 18.4f, 9.2f, 21f, 12f, 18.4f, 14.8f);
    }

    private static void drawPrivacy(Canvas c, Paint sp) {
        Path shield = new Path();
        shield.moveTo(12f, 3.4f);
        shield.lineTo(19.2f, 6.4f);
        shield.lineTo(19.2f, 11.8f);
        shield.quadTo(19.2f, 17.4f, 12f, 20.6f);
        shield.quadTo(4.8f, 17.4f, 4.8f, 11.8f);
        shield.lineTo(4.8f, 6.4f);
        shield.close();
        c.drawPath(shield, sp);
        drawPolyline(c, sp, 9.2f, 12.2f, 11.2f, 14.2f, 15f, 10.2f);
    }

    private static void drawStorage(Canvas c, Paint sp) {
        c.drawOval(new RectF(4.8f, 4.2f, 19.2f, 8.6f), sp);
        c.drawLine(4.8f, 6.4f, 4.8f, 17.6f, sp);
        c.drawLine(19.2f, 6.4f, 19.2f, 17.6f, sp);
        c.drawArc(new RectF(4.8f, 9.8f, 19.2f, 14.2f), 0f, 180f, false, sp);
        c.drawArc(new RectF(4.8f, 15.4f, 19.2f, 19.8f), 0f, 180f, false, sp);
    }

    private static void drawTvLink(Canvas c, Paint sp, Paint fp) {
        c.drawRoundRect(new RectF(3.2f, 5.4f, 20.8f, 16.4f), 2.2f, 2.2f, sp);
        c.drawLine(8.6f, 19.4f, 15.4f, 19.4f, sp);
        c.drawCircle(12f, 13.4f, 1.1f, fp);
        c.drawArc(new RectF(8.6f, 8.8f, 15.4f, 15.6f), -135f, 90f, false, sp);
    }

    private static void drawNetdisk(Canvas c, Paint sp, Paint fp) {
        Path cloud = new Path();
        cloud.moveTo(6.8f, 13.8f);
        cloud.arcTo(new RectF(3.8f, 8.6f, 9.6f, 14.4f), 110f, 165f, false);
        cloud.arcTo(new RectF(7.6f, 4.4f, 16.4f, 13.2f), 195f, 165f, false);
        cloud.arcTo(new RectF(14.8f, 8.8f, 20.2f, 14.2f), -90f, 160f, false);
        c.drawPath(cloud, sp);
        c.drawRoundRect(new RectF(4.2f, 14.6f, 19.8f, 19.6f), 2f, 2f, sp);
        c.drawCircle(16.6f, 17.1f, 1.05f, fp);
    }

    private static void drawSliders(Canvas c, Paint sp, Paint fp) {
        c.drawLine(4.2f, 6.6f, 19.8f, 6.6f, sp);
        c.drawLine(4.2f, 12f, 19.8f, 12f, sp);
        c.drawLine(4.2f, 17.4f, 19.8f, 17.4f, sp);
        c.drawCircle(8.6f, 6.6f, 2.1f, fp);
        c.drawCircle(15.4f, 12f, 2.1f, fp);
        c.drawCircle(10.2f, 17.4f, 2.1f, fp);
    }

    private static void drawBell(Canvas c, Paint sp) {
        Path bell = new Path();
        bell.moveTo(5.6f, 16.6f);
        bell.lineTo(18.4f, 16.6f);
        bell.quadTo(17.4f, 15f, 17.4f, 10.6f);
        bell.arcTo(new RectF(6.6f, 4.8f, 17.4f, 15.6f), 0f, -180f, false);
        bell.quadTo(6.6f, 15f, 5.6f, 16.6f);
        c.drawPath(bell, sp);
        c.drawArc(new RectF(9.8f, 17.2f, 14.2f, 20.4f), 15f, 150f, false, sp);
    }

    private static void drawWarning(Canvas c, Paint sp, Paint fp) {
        Path tri = new Path();
        tri.moveTo(12f, 3.8f);
        tri.lineTo(20.6f, 19.2f);
        tri.lineTo(3.4f, 19.2f);
        tri.close();
        c.drawPath(tri, sp);
        c.drawLine(12f, 9.4f, 12f, 13.6f, sp);
        c.drawCircle(12f, 16.4f, 1.1f, fp);
    }
}

package com.pilipala.marcomovie;

import android.content.Context;
import android.content.res.Configuration;
import android.graphics.RenderEffect;
import android.graphics.Shader;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;

/**
 * Day/Night semantic design-token engine and API-graded frost helpers for Android Mobile / Tablet.
 *
 * <p>Core state resolution ({@link #isDarkForConfig(int, int)}, {@link #forState(boolean, int)},
 * {@link #withAlpha(int, int)}, {@link #themeModeLabel(int)}) is pure Java with zero Android
 * runtime calls so JVM unit tests can verify all theme modes and accent presets directly.
 */
final class MobileTheme {
    static final int MODE_SYSTEM = 0;
    static final int MODE_LIGHT = 1;
    static final int MODE_DARK = 2;

    static final int ACCENT_COUNT = 6;

    static final String[] ACCENT_NAMES = {
        "经典蔚蓝", "绯红玫粉", "翡翠青绿", "鸢尾霓紫", "琥珀流金", "石墨雅灰", "珊瑚暖橙", "碧水青黛"
    };

    static final int[] ACCENT_COLORS = {
        0xFF007AFF,
        0xFFFF2D55,
        0xFF10B981,
        0xFF8B5CF6,
        0xFFF59E0B,
        0xFF64748B,
        0xFFF97316,
        0xFF14B8A6
    };

    private static final int UI_MODE_NIGHT_MASK_CONST = 0x30;
    private static final int UI_MODE_NIGHT_YES_CONST = 0x20;

    private MobileTheme() {}

    /** Semantic Day (Daylight Alabaster) & Night (Cinema Obsidian) token palette. */
    static final class Palette {
        final boolean isDark;
        final int bgCanvas;
        final int bgCard;
        final int bgSheet;
        final int bgSubtle;
        final int bgPressed;
        final int textPrimary;
        final int textSecondary;
        final int textTertiary;
        final int hairline;
        final int dockSurface;
        final int dockSurfaceOpaque;
        final int dockStroke;
        final int pillSelectedFill;
        final int pillUnselectedFill;
        final int scrimBackdrop;
        final int handleColor;
        final int accent;
        final int accentSoft;
        final int accentOnFill;
        final int danger;
        final int success;
        final int warning;

        Palette(boolean dark, int accentColor) {
            this.isDark = dark;
            this.accent = accentColor;
            this.accentOnFill = computeAccentOnFill(accentColor);
            this.danger = 0xFFFF3B30;
            this.success = 0xFF10B981;
            this.warning = 0xFFF59E0B;
            if (dark) {
                this.bgCanvas = 0xFF0A0B0E;
                this.bgCard = 0xFF15171E;
                this.bgSheet = 0xFF161922;
                this.bgSubtle = 0xFF20232D;
                this.bgPressed = 0xFF282C38;
                this.textPrimary = 0xFFF3F5F9;
                this.textSecondary = 0xFF949BA8;
                this.textTertiary = 0xFF606775;
                this.hairline = 0x14FFFFFF;
                this.dockSurface = 0xF0151822;
                this.dockSurfaceOpaque = 0xFA151821;
                this.dockStroke = 0x29FFFFFF;
                this.pillSelectedFill = withAlpha(accentColor, 0x33);
                this.pillUnselectedFill = 0xFF20232D;
                this.scrimBackdrop = 0x8A000000;
                this.handleColor = 0x3DFFFFFF;
                this.accentSoft = withAlpha(accentColor, 0x2E);
            } else {
                this.bgCanvas = 0xFFF3F5F9;
                this.bgCard = 0xFFFFFFFF;
                this.bgSheet = 0xFFFFFFFF;
                this.bgSubtle = 0xFFE7EBF2;
                this.bgPressed = 0xFFDFE5EE;
                this.textPrimary = 0xFF11141A;
                this.textSecondary = 0xFF5C6472;
                this.textTertiary = 0xFF8E96A5;
                this.hairline = 0x12000000;
                this.dockSurface = 0xF5FFFFFF;
                this.dockSurfaceOpaque = 0xFCFFFFFF;
                this.dockStroke = 0x1A000000;
                this.pillSelectedFill = withAlpha(accentColor, 0x1F);
                this.pillUnselectedFill = 0xFFE7EBF2;
                this.scrimBackdrop = 0x66000000;
                this.handleColor = 0x2E11141A;
                this.accentSoft = withAlpha(accentColor, 0x1E);
            }
        }
    }

    /** Pure-JVM theme polarity resolver for {@link Configuration#uiMode} and {@link Prefs#THEME_MODE}. */
    static boolean isDarkForConfig(int uiMode, int mode) {
        if (mode == MODE_LIGHT) return false;
        if (mode == MODE_DARK) return true;
        return (uiMode & UI_MODE_NIGHT_MASK_CONST) == UI_MODE_NIGHT_YES_CONST;
    }

    static boolean isDark(Context ctx, int mode) {
        if (mode == MODE_LIGHT) return false;
        if (mode == MODE_DARK) return true;
        if (ctx == null || ctx.getResources() == null) return true;
        Configuration cfg = ctx.getResources().getConfiguration();
        if (cfg == null) return true;
        return isDarkForConfig(cfg.uiMode, mode);
    }

    static boolean isDark(MainActivity a) {
        if (a == null) return true;
        int mode = themeMode(a);
        return isDark(a, mode);
    }

    static int themeMode(MainActivity a) {
        if (a == null) return MODE_SYSTEM;
        int raw = a.mobilePrefs().getInt(Prefs.THEME_MODE, MODE_SYSTEM);
        return raw >= MODE_SYSTEM && raw <= MODE_DARK ? raw : MODE_SYSTEM;
    }

    /** Pure-JVM palette factory for unit tests and runtime lookups. */
    static Palette forState(boolean dark, int accentPreset) {
        return new Palette(dark, Prefs.accentColorForPreset(accentPreset));
    }

    static Palette of(MainActivity a) {
        if (a == null) return forState(true, 0);
        int preset = a.mobilePrefs().getInt(Prefs.ACCENT_PRESET, 0);
        return forState(isDark(a), preset);
    }

    static int withAlpha(int color, int alpha) {
        int clamped = Math.max(0, Math.min(255, alpha));
        return (color & 0x00FFFFFF) | (clamped << 24);
    }

    /**
     * Pure-JVM RGB tonal surface mixer for Android 16 Material 3 Expressive containers: blends
     * {@code tint} into {@code base} by {@code ratio ∈ [0, 1]} while preserving {@code base}'s
     * alpha channel.
     */
    static int blend(int base, int tint, float ratio) {
        float t = Math.max(0f, Math.min(1f, ratio));
        int a = (base >>> 24) & 0xFF;
        int br = (base >> 16) & 0xFF;
        int bg = (base >> 8) & 0xFF;
        int bb = base & 0xFF;
        int tr = (tint >> 16) & 0xFF;
        int tg = (tint >> 8) & 0xFF;
        int tb = tint & 0xFF;
        int r = Math.round(br + (tr - br) * t);
        int g = Math.round(bg + (tg - bg) * t);
        int b = Math.round(bb + (tb - bb) * t);
        return (a << 24) | (r << 16) | (g << 8) | b;
    }

    static int computeAccentOnFill(int accentColor) {
        int r = (accentColor >> 16) & 0xFF;
        int g = (accentColor >> 8) & 0xFF;
        int b = accentColor & 0xFF;
        float luma = 0.299f * r + 0.587f * g + 0.114f * b;
        return luma >= 165f ? 0xFF11141A : 0xFFFFFFFF;
    }

    static String themeModeLabel(int mode) {
        switch (mode) {
            case MODE_LIGHT:
                return "浅色日间";
            case MODE_DARK:
                return "深色夜间";
            case MODE_SYSTEM:
            default:
                return "跟随系统";
        }
    }

    static String accentName(int preset) {
        if (preset >= 0 && preset < ACCENT_NAMES.length) {
            return ACCENT_NAMES[preset];
        }
        return ACCENT_NAMES[0];
    }

    /** Borderless card surface using semantic {@code bgCard} (zero stroke). */
    static GradientDrawable cardBg(MainActivity a, float radiusDp) {
        Palette p = of(a);
        GradientDrawable d = new GradientDrawable();
        d.setColor(p.bgCard);
        d.setCornerRadius(a.dp(radiusDp));
        return d;
    }

    /** Borderless subtle surface using semantic {@code bgSubtle} (zero stroke). */
    static GradientDrawable subtleBg(MainActivity a, float radiusDp) {
        Palette p = of(a);
        GradientDrawable d = new GradientDrawable();
        d.setColor(p.bgSubtle);
        d.setCornerRadius(a.dp(radiusDp));
        return d;
    }

    /** Rounded surface with explicit fill and hairline stroke color. */
    static GradientDrawable outlinedBg(
            MainActivity a, int fillColor, int strokeColor, float radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fillColor);
        d.setCornerRadius(a.dp(radiusDp));
        if (strokeColor != 0) {
            d.setStroke(hairlinePx(a), strokeColor);
        }
        return d;
    }

    /** Borderless pressed-state fill using semantic {@code bgPressed}. */
    static GradientDrawable pressedBg(MainActivity a, float radiusDp) {
        Palette p = of(a);
        GradientDrawable d = new GradientDrawable();
        d.setColor(p.bgPressed);
        d.setCornerRadius(a.dp(radiusDp));
        return d;
    }

    /** Borderless filter/tab pill surface (soft accent tint when selected, {@code bgSubtle} otherwise). */
    static GradientDrawable pillBg(MainActivity a, boolean selected, float radiusDp) {
        Palette p = of(a);
        GradientDrawable d = new GradientDrawable();
        d.setColor(selected ? p.pillSelectedFill : p.pillUnselectedFill);
        d.setCornerRadius(a.dp(radiusDp));
        return d;
    }

    /** Solid accent pill/button surface (zero stroke). */
    static GradientDrawable accentPillBg(MainActivity a, float radiusDp) {
        Palette p = of(a);
        GradientDrawable d = new GradientDrawable();
        d.setColor(p.accent);
        d.setCornerRadius(a.dp(radiusDp));
        return d;
    }

    /**
     * Floating navigation dock Material 3 Expressive tonal surface. Subtly infuses the active
     * accent hue into the high-opacity container (falling back to {@code dockSurfaceOpaque} when
     * reduced transparency is enabled) paired with an ultra-fine {@code 0.5dp} specular rim.
     */
    static GradientDrawable dockFrostBg(MainActivity a, float radiusDp) {
        Palette p = of(a);
        GradientDrawable d = new GradientDrawable();
        int baseFill = a.isReducedTransparency() ? p.dockSurfaceOpaque : p.dockSurface;
        int tonalFill = blend(baseFill, p.accent, p.isDark ? 0.06f : 0.03f);
        d.setColor(tonalFill);
        d.setCornerRadius(a.dp(radiusDp));
        int strokePx = hairlinePx(a);
        d.setStroke(strokePx, p.dockStroke);
        return d;
    }

    /** Ultra-fine {@code 0.5dp} pixel width (at least {@code 1px}). */
    static int hairlinePx(MainActivity a) {
        float density =
                a != null && a.getResources() != null
                        ? a.getResources().getDisplayMetrics().density
                        : 2f;
        return Math.max(1, Math.round(density * 0.5f));
    }

    /** Enables API 31+ hardware window background/behind blur safely; no-op on API 23-30. */
    static void applyWindowBlurIfSupported(
            Window window, boolean reducedTransparency, int radiusPx) {
        if (window == null || Build.VERSION.SDK_INT < 31) return;
        try {
            WindowManager.LayoutParams attrs = window.getAttributes();
            if (reducedTransparency || radiusPx <= 0) {
                window.clearFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND);
                window.setBackgroundBlurRadius(0);
                if (attrs != null) {
                    attrs.setBlurBehindRadius(0);
                    window.setAttributes(attrs);
                }
            } else {
                window.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND);
                window.setBackgroundBlurRadius(radiusPx);
                if (attrs != null) {
                    attrs.setBlurBehindRadius(radiusPx);
                    window.setAttributes(attrs);
                }
            }
        } catch (Throwable ignored) {
        }
    }

    /** Applies or clears API 31+ GPU {@link RenderEffect} blur on a target view safely. */
    static void applyViewBlurIfSupported(View target, boolean reducedTransparency, float radiusPx) {
        if (target == null || Build.VERSION.SDK_INT < 31) return;
        try {
            if (reducedTransparency || radiusPx <= 0f) {
                target.setRenderEffect(null);
            } else {
                target.setRenderEffect(
                        RenderEffect.createBlurEffect(radiusPx, radiusPx, Shader.TileMode.CLAMP));
            }
        } catch (Throwable ignored) {
        }
    }
}

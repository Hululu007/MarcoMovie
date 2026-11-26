// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.AssetManager;
import android.content.res.Configuration;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import android.view.Choreographer;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.Window;
import android.view.WindowInsetsController;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Redesigned minimalist, linear-animated interactive 5-act onboarding for Android Mobile / Tablet:
 *
 * <ol>
 *   <li><b>01 · YOUR SOURCES</b>: Interactive linear link pulse snapping your own subscription into
 *       a clean cinema library (zero built-in streams).
 *   <li><b>02 · FLUID MOTION</b>: Tap miniature poster cards to experience the live dual poster +
 *       Dock-to-sheet expand &amp; return choreography.
 *   <li><b>03 · DOCK SHORTCUTS</b>: Hold or drag across the miniature floating Dock to reveal &amp;
 *       slide-select deep quick actions.
 *   <li><b>04 · GESTURE PLAYER</b>: Drag left/right edges for linear brightness/volume arcs or hold
 *       center for 2.0× speed boost.
 *   <li><b>05 · PERSONALIZE</b>: Live Day/Night appearance &amp; accent color switching right on
 *       the onboarding canvas with celestial sun/moon line morphing.
 * </ol>
 *
 * <p>Preserves every {@link Controller}, {@link Store}, {@link DemoItem}, and {@link Callbacks}
 * state-machine contract verified by {@code OnboardingStateChecks} &amp; {@code
 * Wave2AndroidWireChecks}.
 */
public final class OnboardingScreen extends FrameLayout {

    public static final String PREFS_FILE = "marco_onboarding_local";
    public static final String KEY_ONBOARDING_DONE_VERSION = "onboarding_done_version";
    public static final String KEY_PLAY_HINT_SHOWN_COUNT = "play_hint_shown_count";
    public static final String KEY_PLAY_HINT_DISMISSED = "play_hint_dismissed";
    public static final int CURRENT_VERSION = 1;
    public static final int ACT_COUNT = 5;
    public static final int[] SUPPORTED_UI_SCALES = {100, 110, 120};

    private static final int COLOR_ACCENT_FALLBACK = 0xFF007AFF;

    /** Device-local key-value abstraction so state logic is unit-testable on the JVM. */
    public interface Store {
        int getInt(String key, int defaultValue);

        void putInt(String key, int value);

        boolean getBoolean(String key, boolean defaultValue);

        void putBoolean(String key, boolean value);
    }

    /** Android {@link SharedPreferences} adapter backed by {@link #PREFS_FILE}. */
    public static final class SharedPrefsStore implements Store {
        private final SharedPreferences prefs;

        public SharedPrefsStore(Context context) {
            this.prefs = context.getApplicationContext().getSharedPreferences(PREFS_FILE, 0);
        }

        @Override
        public int getInt(String key, int defaultValue) {
            return prefs.getInt(key, defaultValue);
        }

        @Override
        public void putInt(String key, int value) {
            prefs.edit().putInt(key, value).apply();
        }

        @Override
        public boolean getBoolean(String key, boolean defaultValue) {
            return prefs.getBoolean(key, defaultValue);
        }

        @Override
        public void putBoolean(String key, boolean value) {
            prefs.edit().putBoolean(key, value).apply();
        }
    }

    /** In-memory {@link Store} for deterministic offline JVM verification. */
    public static final class MemoryStore implements Store {
        private final Map<String, Integer> ints = new HashMap<String, Integer>();
        private final Map<String, Boolean> bools = new HashMap<String, Boolean>();

        @Override
        public int getInt(String key, int defaultValue) {
            Integer v = ints.get(key);
            return v != null ? v.intValue() : defaultValue;
        }

        @Override
        public void putInt(String key, int value) {
            ints.put(key, Integer.valueOf(value));
        }

        @Override
        public boolean getBoolean(String key, boolean defaultValue) {
            Boolean v = bools.get(key);
            return v != null ? v.booleanValue() : defaultValue;
        }

        @Override
        public void putBoolean(String key, boolean value) {
            bools.put(key, Boolean.valueOf(value));
        }
    }

    /** Fictional demo poster metadata parsed from {@code assets/demo/manifest.json}. */
    public static final class DemoItem {
        public final String id;
        public final String file;
        public final String titleZh;
        public final String titleEn;
        public final String badgeZh;
        public final String badgeEn;
        public final List<String> specs;
        public final float progress;
        public final int accentColor;

        public DemoItem(
                String id,
                String file,
                String titleZh,
                String titleEn,
                String badgeZh,
                String badgeEn,
                List<String> specs,
                float progress,
                int accentColor) {
            this.id = id;
            this.file = file;
            this.titleZh = titleZh;
            this.titleEn = titleEn;
            this.badgeZh = badgeZh;
            this.badgeEn = badgeEn;
            this.specs = Collections.unmodifiableList(new ArrayList<String>(specs));
            this.progress = Math.max(0f, Math.min(1f, progress));
            this.accentColor = accentColor;
        }

        public String title(boolean zh) {
            return zh ? titleZh : titleEn;
        }

        public String badgeLabel(boolean zh) {
            return zh ? badgeZh : badgeEn;
        }
    }

    /** Pure-Java 5-act navigation, personalization, and persistence state machine. */
    public static final class Controller {
        private final Store store;
        private int currentAct;
        private int hudDemoStep;
        private boolean reduceMotion;
        private boolean reduceTransparency;
        private int uiScalePercent = 100;
        private boolean finished;
        private boolean skipped;

        public Controller(Store store) {
            this.store = store;
        }

        public static boolean shouldShowOnLaunch(Store store) {
            return store != null && store.getInt(KEY_ONBOARDING_DONE_VERSION, 0) < CURRENT_VERSION;
        }

        public static void markCompleted(Store store) {
            if (store != null) {
                store.putInt(KEY_ONBOARDING_DONE_VERSION, CURRENT_VERSION);
            }
        }

        public static void resetForReplay(Store store) {
            if (store != null) {
                store.putInt(KEY_ONBOARDING_DONE_VERSION, 0);
                store.putInt(KEY_PLAY_HINT_SHOWN_COUNT, 0);
                store.putBoolean(KEY_PLAY_HINT_DISMISSED, false);
            }
        }

        public int getCurrentAct() {
            return currentAct;
        }

        public boolean isFirstAct() {
            return currentAct == 0;
        }

        public boolean isLastAct() {
            return currentAct == ACT_COUNT - 1;
        }

        public boolean nextAct() {
            if (currentAct < ACT_COUNT - 1) {
                currentAct++;
                return true;
            }
            return false;
        }

        public boolean previousAct() {
            if (currentAct > 0) {
                currentAct--;
                return true;
            }
            return false;
        }

        public void goToAct(int index) {
            if (index < 0) {
                currentAct = 0;
            } else if (index >= ACT_COUNT) {
                currentAct = ACT_COUNT - 1;
            } else {
                currentAct = index;
            }
        }

        public int getHudDemoStep() {
            return hudDemoStep;
        }

        public int cycleHudDemoStep() {
            hudDemoStep = (hudDemoStep + 1) % 3;
            return hudDemoStep;
        }

        public void complete(boolean wasSkipped) {
            finished = true;
            skipped = wasSkipped;
            markCompleted(store);
        }

        public boolean handleBack() {
            if (currentAct > 0) {
                currentAct--;
                return false;
            }
            complete(true);
            return true;
        }

        public boolean isFinished() {
            return finished;
        }

        public boolean isSkipped() {
            return skipped;
        }

        public boolean isReduceMotion() {
            return reduceMotion;
        }

        public void setReduceMotion(boolean value) {
            this.reduceMotion = value;
        }

        public boolean isReduceTransparency() {
            return reduceTransparency;
        }

        public void setReduceTransparency(boolean value) {
            this.reduceTransparency = value;
        }

        public int getUiScalePercent() {
            return uiScalePercent;
        }

        public void setUiScalePercent(int percent) {
            if (percent == 100 || percent == 110 || percent == 120) {
                this.uiScalePercent = percent;
            }
        }
    }

    /** Host integration callbacks. */
    public interface Callbacks {
        void onImportConfig(String initialEmptyUrl);

        void onOpenSync();

        void onPersonalizationChanged(
                boolean reduceMotion, boolean reduceTransparency, int uiScalePercent);

        void onFinished(boolean skipped);
    }

    /** Pure-JVM act eyebrow metadata for verification & UI rendering. */
    static String[] actEyebrows() {
        return new String[] {
            "01 · YOUR SOURCES",
            "02 · FLUID MOTION",
            "03 · DOCK SHORTCUTS",
            "04 · GESTURE PLAYER",
            "05 · PERSONALIZE"
        };
    }

    /** Pure-JVM concise editorial act headlines. */
    static String[] actTitles(boolean zh) {
        if (zh) {
            return new String[] {
                "纯净私享，自带片源", "海报铺开，选集自然升起", "底栏长按，高频功能直达", "沉浸手势，倍速随心掌控", "昼夜随心，即刻启程"
            };
        }
        return new String[] {
            "Your Own Sources, Purely",
            "Fluid Poster & Sheet Motion",
            "Long-Press Dock Shortcuts",
            "Effortless Gesture Playback",
            "Tailored Day & Night"
        };
    }

    static String[] actSubtitles(boolean zh) {
        if (zh) {
            return new String[] {
                "不内置任何资源。导入您的合法订阅链接或本地包，即可拥有纯净无干扰的私人影院。",
                "轻点任意海报卡片，封面与底栏将同步过渡至详情页；按返回即优雅缩回原位。",
                "长按或按住上滑底栏任意按钮，滑动松手即可一键切换片源、切日夜模式或直达下载。",
                "左滑调亮度、右滑调音量、长按屏幕 2.0× 倍速播放，单手即可轻松操控。",
                "支持跟随系统、浅色日间与深色夜间，随时可在设置中自由调整。"
            };
        }
        return new String[] {
            "Zero bundled media. Import your own subscription URL or local config for a private cinema.",
            "Tap any poster card below to preview the synchronized hero & dock-to-sheet transition.",
            "Hold or slide up on any dock tab to preview instant deep-feature quick actions.",
            "Swipe left for brightness, right for volume, or hold center for 2.0x boost.",
            "Pick your preferred Day/Night theme and accent color right here."
        };
    }

    private final Controller controller;
    private final boolean tvMode;
    private final boolean zh;
    private final Callbacks callbacks;
    private final FrameLayout backgroundSlot;
    private final LinearLayout rootCol;
    private final LinearLayout progressBarRow;
    private final TextView skipBtn;
    private final FrameLayout stageHost;
    private final LinearLayout copyCol;
    private final TextView eyebrowTv;
    private final TextView headlineTv;
    private final TextView subtitleTv;
    private final LinearLayout controlsSlot;
    private final TextView prevBtn;
    private final TextView nextBtn;
    private LinearPlaygroundView activeCanvas;
    private boolean backDownTracked;
    private float swipeDownX;
    private float swipeDownY;
    private int lastActIndex = -1;

    public OnboardingScreen(
            Context context,
            boolean tvMode,
            boolean reduceMotion,
            boolean reduceTransparency,
            int initialUiScalePercent,
            Callbacks callbacks) {
        this(
                context,
                new SharedPrefsStore(context),
                tvMode,
                isChineseLocale(),
                reduceMotion,
                reduceTransparency,
                initialUiScalePercent,
                callbacks);
    }

    public OnboardingScreen(
            Context context,
            Store store,
            boolean tvMode,
            boolean chinese,
            boolean reduceMotion,
            boolean reduceTransparency,
            int initialUiScalePercent,
            Callbacks callbacks) {
        super(context);
        this.controller = new Controller(store);
        this.controller.setReduceMotion(reduceMotion);
        this.controller.setReduceTransparency(reduceTransparency);
        this.controller.setUiScalePercent(initialUiScalePercent);
        this.tvMode = tvMode;
        this.zh = chinese;
        this.callbacks = callbacks;

        setClickable(true);
        UiCompat.setDefaultFocusHighlightEnabled(this, false);
        setFocusable(true);
        setFocusableInTouchMode(true);

        this.backgroundSlot = new FrameLayout(context);
        addView(backgroundSlot, new LayoutParams(-1, -1));

        int topInset = resolveSystemBarInset(context, "status_bar_height", dp(28));
        int bottomInset = resolveSystemBarInset(context, "navigation_bar_height", dp(16));

        this.rootCol = new LinearLayout(context);
        rootCol.setOrientation(LinearLayout.VERTICAL);
        rootCol.setPadding(dp(22), topInset + dp(14), dp(22), bottomInset + dp(20));
        addView(rootCol, new LayoutParams(-1, -1));

        // 1. Minimalist Top Linear Progress Segments + Subtle Skip
        LinearLayout topBar = new LinearLayout(context);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);

        this.progressBarRow = new LinearLayout(context);
        progressBarRow.setOrientation(LinearLayout.HORIZONTAL);
        progressBarRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams pbLp = new LinearLayout.LayoutParams(0, dp(24), 1f);
        pbLp.rightMargin = dp(16);
        topBar.addView(progressBarRow, pbLp);

        this.skipBtn = new TextView(context);
        skipBtn.setText(zh ? "跳过" : "Skip");
        skipBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        skipBtn.setTypeface(null, Typeface.BOLD);
        skipBtn.setPadding(dp(12), dp(6), dp(4), dp(6));
        bindPressScale(skipBtn, 0.92f);
        skipBtn.setOnClickListener(v -> finishOnboarding(true));
        topBar.addView(skipBtn, new LinearLayout.LayoutParams(-2, -2));
        rootCol.addView(topBar, new LinearLayout.LayoutParams(-1, -2));

        // 2. Interactive Linear-Vector Showcase Canvas (generous airy hero centerpiece)
        this.stageHost = new FrameLayout(context);
        LinearLayout.LayoutParams stageLp = new LinearLayout.LayoutParams(-1, 0, 1f);
        stageLp.topMargin = dp(16);
        stageLp.bottomMargin = dp(16);
        rootCol.addView(stageHost, stageLp);

        // 3. Minimalist Editorial Typography Block
        this.copyCol = new LinearLayout(context);
        copyCol.setOrientation(LinearLayout.VERTICAL);

        this.eyebrowTv = new TextView(context);
        eyebrowTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f);
        eyebrowTv.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        eyebrowTv.setLetterSpacing(0.14f);
        copyCol.addView(eyebrowTv, new LinearLayout.LayoutParams(-1, -2));

        this.headlineTv = new TextView(context);
        headlineTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 25f);
        headlineTv.setTypeface(null, Typeface.BOLD);
        headlineTv.setLineSpacing(dp(2f), 1f);
        LinearLayout.LayoutParams hLp = new LinearLayout.LayoutParams(-1, -2);
        hLp.topMargin = dp(6);
        copyCol.addView(headlineTv, hLp);

        this.subtitleTv = new TextView(context);
        subtitleTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
        subtitleTv.setLineSpacing(dp(4f), 1f);
        LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(-1, -2);
        sLp.topMargin = dp(8);
        copyCol.addView(subtitleTv, sLp);

        // Optional contextual inline controls (e.g., Act 1 Import Pill, Act 5 Theme & Accent)
        this.controlsSlot = new LinearLayout(context);
        controlsSlot.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams ctrlLp = new LinearLayout.LayoutParams(-1, -2);
        ctrlLp.topMargin = dp(14);
        copyCol.addView(controlsSlot, ctrlLp);

        rootCol.addView(copyCol, new LinearLayout.LayoutParams(-1, -2));

        // 4. Clean Bottom Navigation Controls (Back + Stadium Primary CTA)
        LinearLayout bottomRow = new LinearLayout(context);
        bottomRow.setOrientation(LinearLayout.HORIZONTAL);
        bottomRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams botLp = new LinearLayout.LayoutParams(-1, -2);
        botLp.topMargin = dp(20);

        this.prevBtn = new TextView(context);
        prevBtn.setText(zh ? "上一步" : "Back");
        prevBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f);
        prevBtn.setTypeface(null, Typeface.BOLD);
        prevBtn.setGravity(Gravity.CENTER);
        prevBtn.setPadding(dp(18), 0, dp(18), 0);
        bindPressScale(prevBtn, 0.94f);
        prevBtn.setOnClickListener(
                v -> {
                    if (controller.previousAct()) {
                        renderCurrentAct(-1);
                    }
                });
        LinearLayout.LayoutParams prevLp = new LinearLayout.LayoutParams(-2, dp(48));
        prevLp.rightMargin = dp(10);
        bottomRow.addView(prevBtn, prevLp);

        this.nextBtn = new TextView(context);
        nextBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f);
        nextBtn.setTypeface(null, Typeface.BOLD);
        nextBtn.setGravity(Gravity.CENTER);
        bindPressScale(nextBtn, 0.96f);
        nextBtn.setOnClickListener(
                v -> {
                    if (controller.nextAct()) {
                        renderCurrentAct(1);
                    } else {
                        finishOnboarding(false);
                    }
                });
        bottomRow.addView(nextBtn, new LinearLayout.LayoutParams(0, dp(48), 1f));
        rootCol.addView(bottomRow, botLp);

        // Subtle horizontal swipe gesture on text/header area to step between acts
        final int slop = ViewConfiguration.get(context).getScaledTouchSlop();
        copyCol.setOnTouchListener(
                (v, ev) -> {
                    int a = ev.getActionMasked();
                    if (a == MotionEvent.ACTION_DOWN) {
                        swipeDownX = ev.getRawX();
                        swipeDownY = ev.getRawY();
                        return true;
                    } else if (a == MotionEvent.ACTION_UP) {
                        float dx = ev.getRawX() - swipeDownX;
                        float dy = ev.getRawY() - swipeDownY;
                        if (Math.abs(dx) > Math.max(slop * 2, dp(44))
                                && Math.abs(dx) > Math.abs(dy) * 1.4f) {
                            if (dx < 0 && controller.nextAct()) {
                                renderCurrentAct(1);
                                return true;
                            } else if (dx > 0 && controller.previousAct()) {
                                renderCurrentAct(-1);
                                return true;
                            }
                        }
                    }
                    return false;
                });

        renderCurrentAct(0);
    }

    /** Preserved hook: mobile onboarding keeps its clean Day/Night editorial canvas. */
    public void setBackgroundLayer(View layer) {
        // Deliberately keep crisp MobileTheme Alabaster/Obsidian canvas on mobile so linear
        // animations maintain ultra-clean contrast in both Light and Dark modes.
        applyThemeChrome();
    }

    public Controller getController() {
        return controller;
    }

    public static boolean shouldShow(Context context) {
        return Controller.shouldShowOnLaunch(new SharedPrefsStore(context));
    }

    public static void resetForReplay(Context context) {
        Controller.resetForReplay(new SharedPrefsStore(context));
    }

    public boolean handleBackPressed() {
        boolean exited = controller.handleBack();
        if (exited) {
            notifyFinished(true);
        } else {
            renderCurrentAct(-1);
        }
        return true;
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event != null && event.getKeyCode() == KeyEvent.KEYCODE_BACK) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                if (event.getRepeatCount() == 0) {
                    event.startTracking();
                    backDownTracked = true;
                }
                return true;
            }
            if (event.getAction() == KeyEvent.ACTION_UP) {
                boolean wasTracked = backDownTracked;
                backDownTracked = false;
                if (wasTracked && !event.isCanceled()) {
                    return handleBackPressed();
                }
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    protected void onDetachedFromWindow() {
        if (activeCanvas != null) {
            activeCanvas.stop();
            activeCanvas = null;
        }
        super.onDetachedFromWindow();
    }

    private static final String MOBILE_PREFS_FILE = "movie_mobile";
    private static final String PREF_THEME_MODE = "theme_mode";
    private static final String PREF_ACCENT_PRESET = "accent_preset";
    private static final int[] ACCENT_PRESETS = {
        0xFF007AFF,
        0xFFFF2D55,
        0xFF10B981,
        0xFF8B5CF6,
        0xFFF59E0B,
        0xFF64748B,
        0xFFF97316,
        0xFF14B8A6
    };

    /** Self-contained Daylight Alabaster / Cinema Obsidian palette matching MobileTheme tokens. */
    private static final class Palette {
        final boolean isDark;
        final int bgCanvas;
        final int bgCard;
        final int bgSubtle;
        final int textPrimary;
        final int textSecondary;
        final int textTertiary;
        final int accent;
        final int accentOnFill;
        final int pillSelectedFill;

        Palette(boolean dark, int accentColor) {
            this.isDark = dark;
            this.bgCanvas = dark ? 0xFF0A0B0E : 0xFFF3F5F9;
            this.bgCard = dark ? 0xFF15171E : 0xFFFFFFFF;
            this.bgSubtle = dark ? 0xFF20232D : 0xFFE7EBF2;
            this.textPrimary = dark ? 0xFFF3F5F9 : 0xFF11141A;
            this.textSecondary = dark ? 0xFF949BA8 : 0xFF5C6472;
            this.textTertiary = dark ? 0xFF606775 : 0xFF8E96A5;
            this.accent = accentColor;
            this.accentOnFill = computeOnFill(accentColor);
            this.pillSelectedFill = withAlpha(accentColor, dark ? 0x30 : 0x1E);
        }
    }

    private static int withAlpha(int color, int alpha) {
        int clamped = Math.max(0, Math.min(255, alpha));
        return (color & 0x00FFFFFF) | (clamped << 24);
    }

    private static int blendColors(int base, int tint, float ratio) {
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

    private static int computeOnFill(int accentColor) {
        int r = (accentColor >> 16) & 0xFF;
        int g = (accentColor >> 8) & 0xFF;
        int b = accentColor & 0xFF;
        float luma = 0.299f * r + 0.587f * g + 0.114f * b;
        return luma >= 165f ? 0xFF11141A : 0xFFFFFFFF;
    }

    private static int resolveSystemBarInset(Context context, String dimenName, int fallbackPx) {
        if (context == null || context.getResources() == null) return fallbackPx;
        int id = context.getResources().getIdentifier(dimenName, "dimen", "android");
        if (id > 0) {
            int val = context.getResources().getDimensionPixelSize(id);
            if (val > 0) return val;
        }
        return fallbackPx;
    }

    private static boolean isSystemReducedMotion(Context ctx) {
        if (ctx == null) return false;
        try {
            if (Build.VERSION.SDK_INT >= 17) {
                float scale =
                        Settings.Global.getFloat(
                                ctx.getContentResolver(),
                                Settings.Global.ANIMATOR_DURATION_SCALE,
                                1f);
                return scale <= 0.01f;
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static void bindPressScale(final View view, final float scale) {
        view.setOnTouchListener(
                (v, ev) -> {
                    int act = ev.getActionMasked();
                    if (act == MotionEvent.ACTION_DOWN) {
                        v.animate().scaleX(scale).scaleY(scale).setDuration(90).start();
                    } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(140).start();
                    }
                    return false;
                });
    }

    private SharedPreferences mobileThemePrefs() {
        return getContext().getSharedPreferences(MOBILE_PREFS_FILE, Context.MODE_PRIVATE);
    }

    private Palette resolvePalette() {
        Context ctx = getContext();
        SharedPreferences mp = mobileThemePrefs();
        int mode = mp.getInt(PREF_THEME_MODE, 0);
        boolean dark;
        if (mode == 1) {
            dark = false;
        } else if (mode == 2) {
            dark = true;
        } else {
            int uiMode =
                    ctx != null && ctx.getResources() != null
                            ? (ctx.getResources().getConfiguration().uiMode
                                    & Configuration.UI_MODE_NIGHT_MASK)
                            : 0;
            dark = uiMode == Configuration.UI_MODE_NIGHT_YES;
        }
        int preset = mp.getInt(PREF_ACCENT_PRESET, 0);
        int accent =
                (preset >= 0 && preset < ACCENT_PRESETS.length)
                        ? ACCENT_PRESETS[preset]
                        : COLOR_ACCENT_FALLBACK;
        return new Palette(dark, accent);
    }

    private void syncSystemBarIcons(boolean darkCanvas) {
        Context ctx = getContext();
        if (!(ctx instanceof Activity)) return;
        try {
            Window w = ((Activity) ctx).getWindow();
            if (w == null) return;
            if (Build.VERSION.SDK_INT >= 30) {
                WindowInsetsController ic = w.getInsetsController();
                if (ic != null) {
                    int mask =
                            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                                    | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                    ic.setSystemBarsAppearance(darkCanvas ? 0 : mask, mask);
                }
            } else if (Build.VERSION.SDK_INT >= 23) {
                View decor = w.getDecorView();
                int flags = decor.getSystemUiVisibility();
                if (darkCanvas) {
                    flags &= ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
                } else {
                    flags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
                }
                decor.setSystemUiVisibility(flags);
            }
        } catch (Throwable ignored) {
        }
    }

    private void applyThemeChrome() {
        Palette p = resolvePalette();
        backgroundSlot.removeAllViews();
        backgroundSlot.setBackgroundColor(p.bgCanvas);
        syncSystemBarIcons(p.isDark);
        skipBtn.setTextColor(p.textSecondary);
        eyebrowTv.setTextColor(p.accent);
        headlineTv.setTextColor(p.textPrimary);
        subtitleTv.setTextColor(p.textSecondary);

        prevBtn.setTextColor(p.textPrimary);
        GradientDrawable prevBg = new GradientDrawable();
        prevBg.setColor(p.bgSubtle);
        prevBg.setCornerRadius(dp(999));
        prevBtn.setBackground(prevBg);

        nextBtn.setTextColor(p.accentOnFill);
        GradientDrawable nextBg = new GradientDrawable();
        nextBg.setColor(p.accent);
        nextBg.setCornerRadius(dp(999));
        nextBtn.setBackground(nextBg);
        renderProgressSegments(controller.getCurrentAct(), p);
    }

    private void renderProgressSegments(int activeAct, Palette p) {
        progressBarRow.removeAllViews();
        for (int i = 0; i < ACT_COUNT; i++) {
            final int target = i;
            View bar = new View(getContext());
            GradientDrawable gd = new GradientDrawable();
            gd.setCornerRadius(dp(999));
            gd.setColor(
                    i <= activeAct ? p.accent : withAlpha(p.textTertiary, p.isDark ? 0x45 : 0x35));
            bar.setBackground(gd);
            bar.setOnClickListener(
                    v -> {
                        if (target != controller.getCurrentAct()) {
                            int dir = target > controller.getCurrentAct() ? 1 : -1;
                            controller.goToAct(target);
                            renderCurrentAct(dir);
                        }
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(3f), 1f);
            if (i < ACT_COUNT - 1) lp.rightMargin = dp(6);
            progressBarRow.addView(bar, lp);
        }
    }

    private void renderCurrentAct(int direction) {
        int act = controller.getCurrentAct();
        boolean changed = lastActIndex != act;
        lastActIndex = act;

        Palette p = resolvePalette();
        applyThemeChrome();

        eyebrowTv.setText(actEyebrows()[act]);
        headlineTv.setText(actTitles(zh)[act]);
        subtitleTv.setText(actSubtitles(zh)[act]);

        prevBtn.setVisibility(controller.isFirstAct() ? View.GONE : View.VISIBLE);
        nextBtn.setText(
                controller.isLastAct()
                        ? (zh ? "开启 Marco Movie" : "Get Started")
                        : (zh ? "继续" : "Continue"));

        // Mount interactive 120fps linear vector showcase for this act
        if (activeCanvas != null) {
            activeCanvas.stop();
        }
        stageHost.removeAllViews();
        LinearPlaygroundView canvas =
                new LinearPlaygroundView(
                        getContext(),
                        act,
                        p,
                        zh,
                        controller.isReduceMotion() || isSystemReducedMotion(getContext()),
                        () -> {
                            if (act == 3) {
                                controller.cycleHudDemoStep();
                            }
                        });
        activeCanvas = canvas;
        stageHost.addView(canvas, new LayoutParams(-1, -1));
        canvas.start();

        // Populate minimal contextual controls for Act 1 & Act 5
        controlsSlot.removeAllViews();
        if (act == 0) {
            TextView importGhost = new TextView(getContext());
            importGhost.setText(zh ? "已有片源？立即导入配置 →" : "Have a source? Import now →");
            importGhost.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f);
            importGhost.setTypeface(null, Typeface.BOLD);
            importGhost.setTextColor(p.accent);
            importGhost.setGravity(Gravity.CENTER_VERTICAL);
            importGhost.setPadding(dp(14), dp(9), dp(14), dp(9));
            GradientDrawable gBg = new GradientDrawable();
            gBg.setColor(p.pillSelectedFill);
            gBg.setCornerRadius(dp(999));
            importGhost.setBackground(gBg);
            bindPressScale(importGhost, 0.95f);
            importGhost.setOnClickListener(
                    v -> {
                        if (callbacks != null) callbacks.onImportConfig("");
                    });
            controlsSlot.addView(importGhost, new LinearLayout.LayoutParams(-2, -2));
        } else if (act == ACT_COUNT - 1) {
            buildPersonalizeControls(p);
        }

        if (changed && direction != 0 && !controller.isReduceMotion()) {
            animateSwap(copyCol, direction, dp(16));
            animateSwap(stageHost, direction, dp(12));
        }
    }

    private static void animateSwap(View v, int direction, int shiftPx) {
        v.animate().cancel();
        v.setAlpha(0f);
        v.setTranslationX(direction > 0 ? shiftPx : -shiftPx);
        v.animate()
                .alpha(1f)
                .translationX(0f)
                .setDuration(220)
                .setInterpolator(
                        t -> {
                            float inv = 1f - t;
                            return 1f - inv * inv * inv;
                        })
                .start();
    }

    private void buildPersonalizeControls(Palette p) {
        Context ctx = getContext();
        SharedPreferences mp = mobileThemePrefs();
        int curMode = mp.getInt(PREF_THEME_MODE, 0);

        // Minimalist 3-way segmented control: Follow System | Light | Dark
        LinearLayout seg = new LinearLayout(ctx);
        seg.setOrientation(LinearLayout.HORIZONTAL);
        seg.setPadding(dp(3), dp(3), dp(3), dp(3));
        GradientDrawable trackBg = new GradientDrawable();
        trackBg.setColor(p.bgSubtle);
        trackBg.setCornerRadius(dp(12));
        seg.setBackground(trackBg);

        String[] modeLabels = {zh ? "跟随系统" : "System", zh ? "浅色日间" : "Light", zh ? "深色夜间" : "Dark"};
        for (int i = 0; i < modeLabels.length; i++) {
            final int idx = i;
            boolean sel = idx == curMode;
            TextView pill = new TextView(ctx);
            pill.setText(modeLabels[i]);
            pill.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f);
            pill.setTypeface(null, sel ? Typeface.BOLD : Typeface.NORMAL);
            pill.setTextColor(sel ? p.textPrimary : p.textSecondary);
            pill.setGravity(Gravity.CENTER);
            pill.setPadding(dp(8), dp(8), dp(8), dp(8));
            if (sel) {
                GradientDrawable selBg = new GradientDrawable();
                selBg.setColor(p.bgCard);
                selBg.setCornerRadius(dp(9));
                pill.setBackground(selBg);
            }
            bindPressScale(pill, 0.96f);
            pill.setOnClickListener(
                    v -> {
                        mp.edit().putInt(PREF_THEME_MODE, idx).apply();
                        renderCurrentAct(0);
                    });
            seg.addView(pill, new LinearLayout.LayoutParams(0, -2, 1f));
        }
        controlsSlot.addView(seg, new LinearLayout.LayoutParams(-1, -2));

        // Compact minimalist 8-accent swatch row
        int curAccent = mp.getInt(PREF_ACCENT_PRESET, 0);
        LinearLayout swatchRow = new LinearLayout(ctx);
        swatchRow.setOrientation(LinearLayout.HORIZONTAL);
        swatchRow.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < ACCENT_PRESETS.length; i++) {
            final int idx = i;
            boolean sel = idx == curAccent;
            FrameLayout cell = new FrameLayout(ctx);
            View dot = new View(ctx);
            GradientDrawable dotBg = new GradientDrawable();
            dotBg.setShape(GradientDrawable.OVAL);
            dotBg.setColor(ACCENT_PRESETS[i]);
            if (sel) {
                dotBg.setStroke(dp(2.5f), p.textPrimary);
            }
            dot.setBackground(dotBg);
            int size = dp(sel ? 26 : 22);
            cell.addView(dot, new FrameLayout.LayoutParams(size, size, Gravity.CENTER));
            bindPressScale(cell, 0.90f);
            cell.setOnClickListener(
                    v -> {
                        mp.edit().putInt(PREF_ACCENT_PRESET, idx).apply();
                        renderCurrentAct(0);
                    });
            swatchRow.addView(cell, new LinearLayout.LayoutParams(0, dp(34), 1f));
        }
        LinearLayout.LayoutParams swLp = new LinearLayout.LayoutParams(-1, -2);
        swLp.topMargin = dp(8);
        controlsSlot.addView(swatchRow, swLp);

        // Quick secondary action row: Import source | Reduced motion chip
        LinearLayout utilRow = new LinearLayout(ctx);
        utilRow.setOrientation(LinearLayout.HORIZONTAL);
        utilRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams uLp = new LinearLayout.LayoutParams(-1, -2);
        uLp.topMargin = dp(6);

        TextView impChip = new TextView(ctx);
        impChip.setText(zh ? "导入片源配置" : "Import Source");
        impChip.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f);
        impChip.setTypeface(null, Typeface.BOLD);
        impChip.setTextColor(p.accent);
        impChip.setPadding(dp(12), dp(7), dp(12), dp(7));
        GradientDrawable ib = new GradientDrawable();
        ib.setColor(p.pillSelectedFill);
        ib.setCornerRadius(dp(999));
        impChip.setBackground(ib);
        bindPressScale(impChip, 0.94f);
        impChip.setOnClickListener(
                v -> {
                    if (callbacks != null) callbacks.onImportConfig("");
                });
        LinearLayout.LayoutParams icLp = new LinearLayout.LayoutParams(-2, -2);
        icLp.rightMargin = dp(8);
        utilRow.addView(impChip, icLp);

        boolean rm = controller.isReduceMotion();
        TextView rmChip = new TextView(ctx);
        rmChip.setText(
                rm
                        ? (zh ? "减弱动效：已开" : "Reduced Motion: On")
                        : (zh ? "减弱动效：关闭" : "Reduced Motion: Off"));
        rmChip.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f);
        rmChip.setTextColor(rm ? p.accent : p.textSecondary);
        rmChip.setPadding(dp(12), dp(7), dp(12), dp(7));
        GradientDrawable rb = new GradientDrawable();
        rb.setColor(rm ? p.pillSelectedFill : p.bgSubtle);
        rb.setCornerRadius(dp(999));
        rmChip.setBackground(rb);
        bindPressScale(rmChip, 0.94f);
        rmChip.setOnClickListener(
                v -> {
                    controller.setReduceMotion(!controller.isReduceMotion());
                    if (callbacks != null) {
                        callbacks.onPersonalizationChanged(
                                controller.isReduceMotion(),
                                controller.isReduceTransparency(),
                                controller.getUiScalePercent());
                    }
                    renderCurrentAct(0);
                });
        utilRow.addView(rmChip, new LinearLayout.LayoutParams(-2, -2));
        controlsSlot.addView(utilRow, uLp);
    }

    private void finishOnboarding(boolean skipped) {
        controller.complete(skipped);
        notifyFinished(skipped);
    }

    private void notifyFinished(boolean skipped) {
        if (callbacks != null) {
            callbacks.onFinished(skipped);
        }
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private static boolean isChineseLocale() {
        String lang = Locale.getDefault().getLanguage();
        return lang != null && lang.toLowerCase(Locale.US).startsWith("zh");
    }

    /**
     * Interactive 120fps Linear-Vector Showcase Canvas rendered cleanly via geometric strokes,
     * animated dashed guides, and real spring physics — giving every act a tactile Apple-grade
     * live playground without heavy bitmaps or clutter.
     */
    private static final class LinearPlaygroundView extends View {
        private final int act;
        private final Palette p;
        private final boolean zh;
        private final boolean reduced;
        private final Runnable onStepPulse;
        private final float d;

        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF r1 = new RectF();
        private final RectF r2 = new RectF();
        private final Path path = new Path();

        private Choreographer.FrameCallback frameCb;
        private long lastFrameNs = 0L;
        private boolean running = false;
        private float time = 0f;

        // Act 1 interactive state: tap to connect source pulse
        private boolean sourceConnected = false;
        private float sourceAnim = 0f;

        // Act 2 interactive state: tap any mini poster card to morph hero + rising dock sheet
        private int selectedCard = 1;
        private boolean cardExpanded = false;
        private float morphAnim = 0f;

        // Act 3 interactive state: touch/slide mini dock quick menu
        private int activeDockTab = 0;
        private boolean dockMenuOpen = true;
        private float dockMenuAnim = 0f;
        private int hoveredQuickIdx = 0;

        // Act 4 interactive state: drag brightness/volume or hold 2.0x boost
        private float brightnessVal = 0.68f;
        private float volumeVal = 0.62f;
        private boolean boostHolding = false;
        private float boostAnim = 0f;
        private int activeGestureSide = 0; // -1 left, +1 right, 0 none
        private float lastTouchY = 0f;

        // Act 5 interactive state: celestial sun <-> moon linear morph
        private float moonAnim;

        LinearPlaygroundView(
                Context ctx,
                int act,
                Palette p,
                boolean zh,
                boolean reduced,
                Runnable onStepPulse) {
            super(ctx);
            this.act = act;
            this.p = p;
            this.zh = zh;
            this.reduced = reduced;
            this.onStepPulse = onStepPulse;
            this.d = ctx.getResources().getDisplayMetrics().density;
            this.moonAnim = p.isDark ? 1f : 0f;
            stroke.setStyle(Paint.Style.STROKE);
            stroke.setStrokeCap(Paint.Cap.ROUND);
            stroke.setStrokeJoin(Paint.Join.ROUND);
            fill.setStyle(Paint.Style.FILL);
            text.setTextAlign(Paint.Align.CENTER);
            text.setTypeface(Typeface.DEFAULT_BOLD);
        }

        void start() {
            stop();
            if (reduced) {
                sourceAnim = sourceConnected ? 1f : 0f;
                morphAnim = cardExpanded ? 1f : 0f;
                dockMenuAnim = dockMenuOpen ? 1f : 0f;
                boostAnim = boostHolding ? 1f : 0f;
                moonAnim = p.isDark ? 1f : 0f;
                invalidate();
                return;
            }
            running = true;
            lastFrameNs = 0L;
            if (Build.VERSION.SDK_INT >= 16) {
                frameCb =
                        frameTimeNanos -> {
                            if (!running || !UiCompat.isAttached(this)) {
                                running = false;
                                return;
                            }
                            float dt =
                                    lastFrameNs == 0L
                                            ? 0.016f
                                            : Math.min(
                                                    0.05f,
                                                    Math.max(
                                                            0.001f,
                                                            (frameTimeNanos - lastFrameNs)
                                                                    * 1e-9f));
                            lastFrameNs = frameTimeNanos;
                            advanceFrame(dt);
                            Choreographer.getInstance().postFrameCallback(frameCb);
                        };
                Choreographer.getInstance().postFrameCallback(frameCb);
            }
        }

        private void advanceFrame(float step) {
            time += step;
            sourceAnim = approach(sourceAnim, sourceConnected ? 1f : 0f, step * 5.2f);
            morphAnim = approach(morphAnim, cardExpanded ? 1f : 0f, step * 5.8f);
            dockMenuAnim = approach(dockMenuAnim, dockMenuOpen ? 1f : 0f, step * 6.5f);
            boostAnim = approach(boostAnim, boostHolding ? 1f : 0f, step * 7.5f);
            moonAnim = approach(moonAnim, p.isDark ? 1f : 0f, step * 5.0f);
            invalidate();
        }

        void stop() {
            running = false;
            if (Build.VERSION.SDK_INT >= 16 && frameCb != null) {
                try {
                    Choreographer.getInstance().removeFrameCallback(frameCb);
                } catch (Throwable ignored) {
                }
                frameCb = null;
            }
        }

        private static float approach(float cur, float tgt, float rate) {
            float diff = tgt - cur;
            if (Math.abs(diff) < 0.002f) return tgt;
            return cur + diff * Math.min(1f, rate);
        }

        private float dp(float v) {
            return v * d;
        }

        private void haptic(int code) {
            try {
                performHapticFeedback(code);
            } catch (Throwable ignored) {
            }
        }

        @Override
        public boolean onTouchEvent(MotionEvent ev) {
            int action = ev.getActionMasked();
            float x = ev.getX();
            float y = ev.getY();
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return false;

            if (act == 0) {
                if (action == MotionEvent.ACTION_UP) {
                    sourceConnected = !sourceConnected;
                    if (reduced) sourceAnim = sourceConnected ? 1f : 0f;
                    haptic(HapticFeedbackConstants.KEYBOARD_TAP);
                    invalidate();
                }
                return true;
            }
            if (act == 1) {
                if (action == MotionEvent.ACTION_UP) {
                    if (!cardExpanded) {
                        int col = x < w * 0.36f ? 0 : (x > w * 0.64f ? 2 : 1);
                        selectedCard = col;
                        cardExpanded = true;
                    } else {
                        cardExpanded = false;
                    }
                    if (reduced) morphAnim = cardExpanded ? 1f : 0f;
                    haptic(HapticFeedbackConstants.KEYBOARD_TAP);
                    invalidate();
                }
                return true;
            }
            if (act == 2) {
                if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_MOVE) {
                    float dockY = h * 0.78f;
                    if (y >= dockY - dp(24)) {
                        int nextTab =
                                Math.max(0, Math.min(3, (int) ((x - w * 0.14f) / (w * 0.18f))));
                        if (nextTab != activeDockTab) {
                            activeDockTab = nextTab;
                            hoveredQuickIdx = 0;
                            haptic(HapticFeedbackConstants.CLOCK_TICK);
                        }
                        dockMenuOpen = true;
                    } else if (dockMenuOpen) {
                        float menuTop = h * 0.24f;
                        float menuBot = h * 0.62f;
                        if (y >= menuTop && y <= menuBot) {
                            int idx =
                                    Math.max(
                                            0,
                                            Math.min(
                                                    2,
                                                    (int)
                                                            (((y - menuTop) / (menuBot - menuTop))
                                                                    * 3f)));
                            if (idx != hoveredQuickIdx) {
                                hoveredQuickIdx = idx;
                                haptic(HapticFeedbackConstants.CLOCK_TICK);
                            }
                        }
                    }
                    if (reduced) dockMenuAnim = dockMenuOpen ? 1f : 0f;
                    invalidate();
                }
                return true;
            }
            if (act == 3) {
                if (action == MotionEvent.ACTION_DOWN) {
                    lastTouchY = y;
                    if (x < w * 0.32f) {
                        activeGestureSide = -1;
                    } else if (x > w * 0.68f) {
                        activeGestureSide = 1;
                    } else {
                        activeGestureSide = 0;
                        boostHolding = true;
                        haptic(HapticFeedbackConstants.LONG_PRESS);
                        if (onStepPulse != null) onStepPulse.run();
                    }
                    if (reduced) boostAnim = boostHolding ? 1f : 0f;
                    invalidate();
                } else if (action == MotionEvent.ACTION_MOVE) {
                    float dy = (lastTouchY - y) / Math.max(1f, h * 0.45f);
                    lastTouchY = y;
                    if (activeGestureSide == -1) {
                        brightnessVal = Math.max(0.10f, Math.min(1f, brightnessVal + dy));
                        invalidate();
                    } else if (activeGestureSide == 1) {
                        volumeVal = Math.max(0.10f, Math.min(1f, volumeVal + dy));
                        invalidate();
                    }
                } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                    boostHolding = false;
                    activeGestureSide = 0;
                    if (reduced) boostAnim = 0f;
                    invalidate();
                }
                return true;
            }
            return false;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;

            // Subtle architectural canvas frame with hairline border
            r1.set(0f, 0f, w, h);
            fill.setColor(p.bgCard);
            canvas.drawRoundRect(r1, dp(24), dp(24), fill);
            stroke.setPathEffect(null);
            stroke.setStrokeWidth(dp(0.8f));
            stroke.setColor(p.isDark ? 0x1EFFFFFF : 0x14000000);
            canvas.drawRoundRect(r1, dp(24), dp(24), stroke);

            // Subtle geometric dot grid backdrop for Linear-app luxury depth
            fill.setColor(withAlpha(p.textTertiary, p.isDark ? 0x26 : 0x20));
            float gridStep = dp(24);
            for (float gx = gridStep; gx < w - dp(12); gx += gridStep) {
                for (float gy = gridStep; gy < h - dp(12); gy += gridStep) {
                    canvas.drawCircle(gx, gy, dp(1f), fill);
                }
            }

            switch (act) {
                case 0:
                    drawAct1Sources(canvas, w, h);
                    break;
                case 1:
                    drawAct2DualMotion(canvas, w, h);
                    break;
                case 2:
                    drawAct3DockShortcuts(canvas, w, h);
                    break;
                case 3:
                    drawAct4GesturePlayer(canvas, w, h);
                    break;
                default:
                    drawAct5CelestialTheme(canvas, w, h);
                    break;
            }
        }

        private void drawInteractiveHintChip(Canvas canvas, float w, float h, String label) {
            text.setTextSize(dp(11.5f));
            float tw = text.measureText(label);
            float pw = tw + dp(24);
            float ph = dp(26);
            float l = (w - pw) * 0.5f;
            float t = h - ph - dp(14);
            r2.set(l, t, l + pw, t + ph);
            fill.setColor(withAlpha(p.accent, p.isDark ? 0x2A : 0x18));
            canvas.drawRoundRect(r2, ph * 0.5f, ph * 0.5f, fill);
            text.setColor(p.accent);
            canvas.drawText(label, w * 0.5f, t + ph * 0.66f, text);
        }

        private void drawAct1Sources(Canvas canvas, int w, int h) {
            float cx = w * 0.5f;
            float pillY = h * 0.22f;
            float frameTop = h * 0.44f;
            float frameH = h * 0.36f;
            float frameW = Math.min(w * 0.74f, dp(248));
            float frameL = cx - frameW * 0.5f;

            // Top minimalist URL capsule
            float pillW = Math.min(w * 0.66f, dp(216));
            float pillH = dp(36);
            r2.set(
                    cx - pillW * 0.5f,
                    pillY - pillH * 0.5f,
                    cx + pillW * 0.5f,
                    pillY + pillH * 0.5f);
            int pillLitFill = blendColors(p.bgCard, p.accent, p.isDark ? 0.26f : 0.14f);
            fill.setColor(blendColors(p.bgSubtle, pillLitFill, sourceAnim));
            canvas.drawRoundRect(r2, pillH * 0.5f, pillH * 0.5f, fill);
            stroke.setStrokeWidth(dp(1.4f));
            stroke.setColor(blendColors(p.textTertiary, p.accent, sourceAnim));
            canvas.drawRoundRect(r2, pillH * 0.5f, pillH * 0.5f, stroke);

            text.setTextSize(dp(11.5f));
            text.setColor(blendColors(p.textSecondary, p.accent, sourceAnim));
            canvas.drawText(
                    sourceConnected
                            ? (zh ? "✓  自有片源已接入" : "✓  Source Connected")
                            : "https://source.example/config.json",
                    cx,
                    pillY + dp(4),
                    text);

            // Vertical animated linear beam connecting URL capsule -> Library Frame
            float lineTop = pillY + pillH * 0.5f + dp(6);
            float lineBot = frameTop - dp(6);
            stroke.setStrokeWidth(dp(1.4f));
            stroke.setPathEffect(new DashPathEffect(new float[] {dp(4), dp(4)}, -(time * dp(24))));
            stroke.setColor(withAlpha(p.accent, sourceConnected ? 0xD0 : 0x55));
            canvas.drawLine(cx, lineTop, cx, lineBot, stroke);
            stroke.setPathEffect(null);

            float pulseY = lineTop + (lineBot - lineTop) * ((time * 0.9f) % 1f);
            fill.setColor(p.accent);
            canvas.drawCircle(cx, pulseY, dp(sourceConnected ? 3.5f : 2.5f), fill);

            // Minimalist 3-card library wireframe morphing into illuminated cinema cards
            r2.set(frameL, frameTop, frameL + frameW, frameTop + frameH);
            stroke.setStrokeWidth(dp(1.2f));
            stroke.setColor(withAlpha(p.textTertiary, 0x55));
            canvas.drawRoundRect(r2, dp(16), dp(16), stroke);

            float pad = dp(12);
            float gap = dp(9);
            float cardW = (frameW - pad * 2 - gap * 2) / 3f;
            float cardH = frameH - pad * 2;
            int[] cardTints = {p.accent, 0xFF8B5CF6, 0xFF10B981};
            for (int i = 0; i < 3; i++) {
                float cl = frameL + pad + i * (cardW + gap);
                float ct = frameTop + pad;
                float lit = Math.max(0f, Math.min(1f, sourceAnim * 1.4f - i * 0.18f));
                r2.set(cl, ct, cl + cardW, ct + cardH);
                int cardLitFill = blendColors(p.bgCard, cardTints[i], p.isDark ? 0.28f : 0.15f);
                fill.setColor(blendColors(p.bgSubtle, cardLitFill, lit));
                canvas.drawRoundRect(r2, dp(10), dp(10), fill);
                stroke.setStrokeWidth(dp(1.2f));
                stroke.setColor(
                        blendColors(
                                withAlpha(p.textTertiary, 0x45),
                                withAlpha(cardTints[i], 0xD0),
                                lit));
                canvas.drawRoundRect(r2, dp(10), dp(10), stroke);

                if (lit > 0.25f) {
                    stroke.setStrokeWidth(dp(1.4f));
                    stroke.setColor(withAlpha(cardTints[i], Math.round(180 * lit)));
                    canvas.drawCircle(cl + cardW * 0.5f, ct + cardH * 0.42f, dp(8.5f), stroke);
                }

                // Minimalist linear title line inside each poster card
                float lineY = ct + cardH - dp(12);
                stroke.setStrokeWidth(dp(2f));
                stroke.setColor(
                        withAlpha(
                                lit > 0.5f ? cardTints[i] : p.textTertiary,
                                lit > 0.5f ? 0xD0 : 0x50));
                canvas.drawLine(cl + dp(8), lineY, cl + cardW - dp(12), lineY, stroke);
            }

            drawInteractiveHintChip(
                    canvas,
                    w,
                    h,
                    sourceConnected
                            ? (zh ? "再次轻点重置演示" : "Tap again to reset")
                            : (zh ? "轻点画布 · 体验接入片源" : "Tap canvas to simulate import"));
        }

        private void drawAct2DualMotion(Canvas canvas, int w, int h) {
            // Miniature sleek phone frame inside the stage
            float phoneH = h * 0.76f;
            float phoneW = Math.min(w * 0.62f, phoneH * 0.54f);
            float pL = (w - phoneW) * 0.5f;
            float pT = (h - phoneH) * 0.42f;
            float pR = pL + phoneW;
            float pB = pT + phoneH;

            r1.set(pL, pT, pR, pB);
            fill.setColor(p.bgCanvas);
            canvas.drawRoundRect(r1, dp(22), dp(22), fill);
            stroke.setStrokeWidth(dp(1.4f));
            stroke.setColor(withAlpha(p.textTertiary, 0x65));
            canvas.drawRoundRect(r1, dp(22), dp(22), stroke);

            int save = canvas.save();
            path.reset();
            path.addRoundRect(r1, dp(22), dp(22), Path.Direction.CW);
            canvas.clipPath(path);

            float pad = dp(10);
            float gap = dp(6);
            float cardW = (phoneW - pad * 2 - gap * 2) / 3f;
            float cardH = cardW * 1.45f;
            float gridTop = pT + dp(26);
            int[] tints = {0xFF5AC8FA, p.accent, 0xFFFF9F0A};

            // Static background 3-card row (fades smoothly while selected card expands)
            float bgCardVis = Math.max(0f, 1f - morphAnim * 1.35f);
            if (bgCardVis > 0.01f) {
                for (int i = 0; i < 3; i++) {
                    if (i == selectedCard && morphAnim > 0.04f) continue;
                    float cl = pL + pad + i * (cardW + gap);
                    r2.set(cl, gridTop, cl + cardW, gridTop + cardH);
                    fill.setColor(
                            withAlpha(tints[i], Math.round((p.isDark ? 0x35 : 0x26) * bgCardVis)));
                    canvas.drawRoundRect(r2, dp(7), dp(7), fill);
                    stroke.setStrokeWidth(dp(1f));
                    stroke.setColor(withAlpha(tints[i], Math.round(0x85 * bgCardVis)));
                    canvas.drawRoundRect(r2, dp(7), dp(7), stroke);
                }
            }

            // 1. Expanding Selected Poster Card -> Upper Hero (opaque tinted surface, zero bleed)
            float srcL = pL + pad + selectedCard * (cardW + gap);
            float srcT = gridTop;
            float heroBot = pT + phoneH * 0.56f;
            float curL = srcL + (pL - srcL) * morphAnim;
            float curT = srcT + (pT - srcT) * morphAnim;
            float curR = (srcL + cardW) + (pR - (srcL + cardW)) * morphAnim;
            float curB = (srcT + cardH) + (heroBot - (srcT + cardH)) * morphAnim;
            float curRad = dp(7) * (1f - morphAnim);
            r2.set(curL, curT, curR, curB);
            fill.setColor(blendColors(p.bgCanvas, tints[selectedCard], p.isDark ? 0.36f : 0.22f));
            canvas.drawRoundRect(r2, curRad, curRad, fill);
            stroke.setStrokeWidth(dp(1.3f));
            stroke.setColor(tints[selectedCard]);
            canvas.drawRoundRect(r2, curRad, curRad, stroke);

            // Subtle linear play icon emerging in hero
            if (morphAnim > 0.25f) {
                float a = Math.min(1f, (morphAnim - 0.25f) / 0.5f);
                stroke.setStrokeWidth(dp(1.6f));
                stroke.setColor(withAlpha(Color.WHITE, Math.round(230 * a)));
                float hCx = (curL + curR) * 0.5f;
                float hCy = (curT + curB) * 0.5f;
                canvas.drawCircle(hCx, hCy, dp(12), stroke);
            }

            // 2. Synchronized Dock Pill <-> Rising Lower Episode Sheet!
            float dockW = phoneW * 0.68f;
            float dockH = dp(18);
            float dL = pL + (phoneW - dockW) * 0.5f;
            float dT = pB - dockH - dp(10);
            float dR = dL + dockW;
            float dB = dT + dockH;

            float sL = dL + (pL - dL) * morphAnim;
            float sT = dT + ((heroBot - dp(10)) - dT) * morphAnim;
            float sR = dR + (pR - dR) * morphAnim;
            float sB = dB + (pB - dB) * morphAnim;
            float sTopR = dp(9) + (dp(14) - dp(9)) * morphAnim;
            float sBotR = dp(9) * (1f - morphAnim);

            r2.set(sL, sT, sR, sB);
            path.reset();
            path.addRoundRect(
                    r2,
                    new float[] {sTopR, sTopR, sTopR, sTopR, sBotR, sBotR, sBotR, sBotR},
                    Path.Direction.CW);
            fill.setColor(p.bgCard);
            canvas.drawPath(path, fill);
            stroke.setStrokeWidth(dp(1.2f));
            stroke.setColor(withAlpha(p.accent, Math.round(180 * (1f - morphAnim * 0.4f))));
            canvas.drawPath(path, stroke);

            // Miniature episode skeleton lines materializing inside rising sheet
            if (morphAnim > 0.35f) {
                float la = Math.min(1f, (morphAnim - 0.35f) / 0.45f);
                fill.setColor(withAlpha(p.accent, Math.round(220 * la)));
                r2.set(sL + dp(12), sT + dp(12), sR - dp(12), sT + dp(24));
                canvas.drawRoundRect(r2, dp(6), dp(6), fill);

                fill.setColor(withAlpha(p.textTertiary, Math.round(90 * la)));
                for (int e = 0; e < 4; e++) {
                    float ex = sL + dp(12) + e * dp(24);
                    r2.set(ex, sT + dp(32), ex + dp(18), sT + dp(46));
                    canvas.drawRoundRect(r2, dp(4), dp(4), fill);
                }
            }
            canvas.restoreToCount(save);

            drawInteractiveHintChip(
                    canvas,
                    w,
                    h,
                    cardExpanded
                            ? (zh ? "再点一次 · 看海报与底栏优雅回位" : "Tap again to shrink back")
                            : (zh ? "点击任意海报卡片 · 预览双动效" : "Tap a card to preview morph"));
        }

        private void drawAct3DockShortcuts(Canvas canvas, int w, int h) {
            float dockW = Math.min(w * 0.78f, dp(248));
            float dockH = dp(44);
            float dockL = (w - dockW) * 0.5f;
            float dockT = h * 0.68f;

            // Floating Dock pill
            r2.set(dockL, dockT, dockL + dockW, dockT + dockH);
            fill.setColor(p.bgCanvas);
            canvas.drawRoundRect(r2, dockH * 0.5f, dockH * 0.5f, fill);
            stroke.setStrokeWidth(dp(1.2f));
            stroke.setColor(withAlpha(p.textTertiary, 0x55));
            canvas.drawRoundRect(r2, dockH * 0.5f, dockH * 0.5f, stroke);

            String[] tabs =
                    zh
                            ? new String[] {"发现", "直播", "片库", "设置"}
                            : new String[] {"Home", "Live", "Lib", "Set"};
            float cellW = dockW / 4f;
            float activeCx = dockL + (activeDockTab + 0.5f) * cellW;
            for (int i = 0; i < 4; i++) {
                float cx = dockL + (i + 0.5f) * cellW;
                boolean sel = i == activeDockTab;
                if (sel) {
                    r2.set(cx - dp(22), dockT + dp(6), cx + dp(22), dockT + dockH - dp(6));
                    fill.setColor(p.pillSelectedFill);
                    canvas.drawRoundRect(r2, dp(16), dp(16), fill);
                }
                text.setTextSize(dp(11f));
                text.setColor(sel ? p.accent : p.textSecondary);
                canvas.drawText(tabs[i], cx, dockT + dockH * 0.62f, text);
            }

            // Floating Quick-Action Popover unfolding right above the active tab
            if (dockMenuAnim > 0.02f) {
                String[][] menuItems =
                        zh
                                ? new String[][] {
                                    {"切换片源", "导入片源", "回到顶部"},
                                    {"导入直播源", "节目单设置", "刷新频道"},
                                    {"观看历史", "我的收藏", "离线下载"},
                                    {"切换日夜模式", "播放与画质", "隐私空间"}
                                }
                                : new String[][] {
                                    {"Switch Source", "Import", "Top"},
                                    {"Import Live", "EPG", "Refresh"},
                                    {"History", "Favorites", "Downloads"},
                                    {"Day / Night", "Playback", "Privacy"}
                                };
                String[] rows = menuItems[activeDockTab % menuItems.length];
                float menuW = dp(148);
                float menuH = dp(112);
                float mL = Math.max(dp(16), Math.min(w - menuW - dp(16), activeCx - menuW * 0.5f));
                float mB = dockT - dp(14) + dp(12) * (1f - dockMenuAnim);
                float mT = mB - menuH;

                r2.set(mL, mT, mL + menuW, mB);
                fill.setColor(p.bgCanvas);
                canvas.drawRoundRect(r2, dp(16), dp(16), fill);
                stroke.setStrokeWidth(dp(1.2f));
                stroke.setColor(withAlpha(p.accent, 0x80));
                canvas.drawRoundRect(r2, dp(16), dp(16), stroke);

                float rowH = (menuH - dp(12)) / 3f;
                for (int r = 0; r < 3; r++) {
                    float rt = mT + dp(6) + r * rowH;
                    boolean hov = r == hoveredQuickIdx;
                    if (hov) {
                        r2.set(mL + dp(6), rt, mL + menuW - dp(6), rt + rowH);
                        fill.setColor(p.pillSelectedFill);
                        canvas.drawRoundRect(r2, dp(10), dp(10), fill);
                    }
                    text.setTextSize(dp(12f));
                    text.setColor(hov ? p.accent : p.textPrimary);
                    canvas.drawText(rows[r], mL + menuW * 0.5f, rt + rowH * 0.64f, text);
                }
            }

            drawInteractiveHintChip(
                    canvas, w, h, zh ? "按住底部图标并上下滑动体验" : "Touch & slide dock tabs above");
        }

        private void drawAct4GesturePlayer(Canvas canvas, int w, int h) {
            float vpW = Math.min(w * 0.84f, dp(280));
            float vpH = vpW * 0.56f;
            float vpL = (w - vpW) * 0.5f;
            float vpT = (h - vpH) * 0.42f;
            float vpR = vpL + vpW;
            float vpB = vpT + vpH;

            r2.set(vpL, vpT, vpR, vpB);
            fill.setColor(p.isDark ? 0xFF0E1118 : 0xFF151923);
            canvas.drawRoundRect(r2, dp(16), dp(16), fill);
            stroke.setStrokeWidth(dp(1.2f));
            stroke.setColor(withAlpha(p.accent, boostHolding ? 0xDD : 0x55));
            canvas.drawRoundRect(r2, dp(16), dp(16), stroke);

            // Animated minimalist cinema waveform / timeline inside viewport
            float playY = vpB - dp(18);
            stroke.setStrokeWidth(dp(2f));
            stroke.setColor(0x38FFFFFF);
            canvas.drawLine(vpL + dp(16), playY, vpR - dp(16), playY, stroke);
            float speedMul = 1f + boostAnim * 2.2f;
            float prog = ((time * 0.16f * speedMul) % 1f);
            float headX = vpL + dp(16) + (vpW - dp(32)) * prog;
            stroke.setColor(p.accent);
            canvas.drawLine(vpL + dp(16), playY, headX, playY, stroke);
            fill.setColor(Color.WHITE);
            canvas.drawCircle(headX, playY, dp(3.5f), fill);

            // Left linear brightness meter
            drawSideMeter(
                    canvas,
                    vpL + dp(20),
                    vpT + dp(22),
                    vpB - dp(34),
                    brightnessVal,
                    activeGestureSide == -1 ? p.accent : 0xBBFFFFFF,
                    zh ? "亮度" : "BRI");
            // Right linear volume meter
            drawSideMeter(
                    canvas,
                    vpR - dp(20),
                    vpT + dp(22),
                    vpB - dp(34),
                    volumeVal,
                    activeGestureSide == 1 ? p.accent : 0xBBFFFFFF,
                    zh ? "音量" : "VOL");

            // Center 2.0x boost capsule
            float cX = (vpL + vpR) * 0.5f;
            float cY = (vpT + vpB) * 0.44f;
            String speedStr = boostHolding ? "2.0×  ▸▸" : "1.0×";
            float capW = dp(boostHolding ? 86 : 64);
            float capH = dp(28);
            r2.set(cX - capW * 0.5f, cY - capH * 0.5f, cX + capW * 0.5f, cY + capH * 0.5f);
            fill.setColor(boostHolding ? p.accent : 0x26FFFFFF);
            canvas.drawRoundRect(r2, capH * 0.5f, capH * 0.5f, fill);
            text.setTextSize(dp(12f));
            text.setColor(Color.WHITE);
            canvas.drawText(speedStr, cX, cY + dp(4.5f), text);

            drawInteractiveHintChip(
                    canvas,
                    w,
                    h,
                    zh ? "滑左右调亮度音量 · 按住中间 2.0× 加速" : "Drag sides or hold center for 2.0x");
        }

        private void drawSideMeter(
                Canvas canvas,
                float x,
                float top,
                float bottom,
                float value,
                int color,
                String label) {
            stroke.setStrokeWidth(dp(3f));
            stroke.setColor(0x30FFFFFF);
            canvas.drawLine(x, top, x, bottom, stroke);
            float fillTop = bottom - (bottom - top) * value;
            stroke.setColor(color);
            canvas.drawLine(x, bottom, x, fillTop, stroke);
            text.setTextSize(dp(9.5f));
            text.setColor(color);
            canvas.drawText(label, x, top - dp(6), text);
        }

        private void drawAct5CelestialTheme(Canvas canvas, int w, int h) {
            float cx = w * 0.5f;
            float cy = h * 0.47f;
            float radius = Math.min(w, h) * 0.20f;

            // Rotating minimalist concentric orbital rings
            stroke.setStrokeWidth(dp(1f));
            stroke.setPathEffect(new DashPathEffect(new float[] {dp(5), dp(6)}, time * dp(12)));
            stroke.setColor(withAlpha(p.accent, 0x55));
            canvas.drawCircle(cx, cy, radius * 1.65f, stroke);
            stroke.setPathEffect(null);

            stroke.setColor(withAlpha(p.accent, 0x28));
            canvas.drawCircle(cx, cy, radius * 2.15f, stroke);

            // Sun rays smoothly retracting as moonAnim approaches 1
            float rayVis = 1f - moonAnim;
            if (rayVis > 0.02f) {
                stroke.setStrokeWidth(dp(2f));
                stroke.setColor(withAlpha(p.accent, Math.round(230 * rayVis)));
                for (int i = 0; i < 8; i++) {
                    double ang = i * (Math.PI / 4.0) + time * 0.35;
                    float rIn = radius * 1.24f;
                    float rOut = radius * (1.24f + 0.34f * rayVis);
                    canvas.drawLine(
                            cx + (float) Math.cos(ang) * rIn,
                            cy + (float) Math.sin(ang) * rIn,
                            cx + (float) Math.cos(ang) * rOut,
                            cy + (float) Math.sin(ang) * rOut,
                            stroke);
                }
            }

            // Core geometric orb + crescent cutout overlay
            fill.setColor(withAlpha(p.accent, p.isDark ? 0x35 : 0x22));
            canvas.drawCircle(cx, cy, radius, fill);
            stroke.setStrokeWidth(dp(2.2f));
            stroke.setColor(p.accent);
            canvas.drawCircle(cx, cy, radius, stroke);

            if (moonAnim > 0.05f) {
                float cutOff = radius * (1.25f - 0.65f * moonAnim);
                fill.setColor(p.bgCard);
                canvas.drawCircle(cx + cutOff, cy - cutOff * 0.45f, radius * 0.85f, fill);
            }

            drawInteractiveHintChip(
                    canvas,
                    w,
                    h,
                    p.isDark
                            ? (zh ? "深色夜间 · 影院低眩光画布" : "Dark Obsidian · Cinema Canvas")
                            : (zh ? "浅色日间 · 柔和雪花石膏画布" : "Light Alabaster · Crisp Daylight"));
        }
    }

    /** Loads demo poster entries from {@code assets/demo/manifest.json} with safe empty fallback. */
    public static List<DemoItem> loadDemoItems(Context context) {
        if (context == null) {
            return Collections.emptyList();
        }
        AssetManager assets = context.getAssets();
        if (assets == null) {
            return Collections.emptyList();
        }
        try {
            InputStream in = assets.open("demo/manifest.json");
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                }
                String raw = new String(out.toByteArray(), Charset.forName("UTF-8"));
                return parseManifest(raw);
            } finally {
                in.close();
            }
        } catch (IOException ignored) {
            return Collections.emptyList();
        }
    }

    /** Pure-Java manifest parser shared by runtime and JVM checks. */
    public static List<DemoItem> parseManifest(String rawJson) {
        if (rawJson == null || rawJson.trim().isEmpty()) {
            return Collections.emptyList();
        }
        try {
            JSONObject root = new JSONObject(rawJson);
            JSONArray arr = root.optJSONArray("items");
            if (arr == null) {
                return Collections.emptyList();
            }
            List<DemoItem> out = new ArrayList<DemoItem>(arr.length());
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) {
                    continue;
                }
                List<String> specs = new ArrayList<String>();
                JSONArray specArr = o.optJSONArray("specs");
                if (specArr != null) {
                    for (int s = 0; s < specArr.length(); s++) {
                        String tag = specArr.optString(s, "").trim();
                        if (!tag.isEmpty()) {
                            specs.add(tag);
                        }
                    }
                }
                int accent =
                        parseHexColor(o.optString("accentHex", "#007AFF"), COLOR_ACCENT_FALLBACK);
                out.add(
                        new DemoItem(
                                o.optString("id", "demo_" + (i + 1)),
                                o.optString("file", ""),
                                o.optString("titleZh", "示例"),
                                o.optString("titleEn", "Sample"),
                                o.optString("badgeZh", "示例"),
                                o.optString("badgeEn", "DEMO"),
                                specs,
                                (float) o.optDouble("progress", 0.0),
                                accent));
            }
            return out;
        } catch (JSONException ignored) {
            return Collections.emptyList();
        }
    }

    private static int parseHexColor(String hex, int fallback) {
        if (hex == null) {
            return fallback;
        }
        String s = hex.trim();
        if (s.startsWith("#")) {
            s = s.substring(1);
        }
        if (s.length() == 6) {
            try {
                return 0xFF000000 | Integer.parseInt(s, 16);
            } catch (NumberFormatException ignored) {
                return fallback;
            }
        }
        return fallback;
    }
}

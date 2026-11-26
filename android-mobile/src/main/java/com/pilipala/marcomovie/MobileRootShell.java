package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/**
 * Modular Android Mobile & Tablet root shell using Android 16 / Material 3 Expressive floating
 * navigation bar + Apple-grade interruptible {@link MotionSpring} physics:
 *
 * <ul>
 *   <li>{@code 4 + 1} Material 3 Expressive floating stadium bar ({@code 发现 · 直播 · 片库 · 设置})
 *       with icon-hugging elastic spring pill indicator + detached circular Search FAB that morphs
 *       into a rounded squircle when active; unified full-width 5-tab bar in style 1; vertical
 *       tonal side rail on landscape tablets.
 *   <li>Fixed-bounds {@link FrameLayout} dock stage with single-spring strictly non-overlapping
 *       two-phase cross-morph ({@link #computeDockMorphAlphas(float)}) and hysteresis scroll
 *       tracker ({@link DockScrollTracker}) — mathematically guaranteeing zero layout jitter and
 *       zero ghost icons while scrolling.
 *   <li>Top immersive status-bar fade veil + live {@link WindowInsets} syncing for true Android
 *       15/16 Edge-to-Edge across all 5 tabs.
 * </ul>
 */
final class MobileRootShell {
    static final int TAB_HOME = 0;
    static final int TAB_LIVE = 1;
    static final int TAB_LIBRARY = 2;
    static final int TAB_SETTINGS = 3;
    static final int TAB_SEARCH = 4;

    private static final String[] TAB_NAMES = {"发现", "直播", "片库", "设置", "搜索"};
    private static final int[] TAB_ICON_IDS = {
        MobileIcons.IC_DISCOVER,
        MobileIcons.IC_LIVE,
        MobileIcons.IC_LIBRARY,
        MobileIcons.IC_SETTINGS,
        MobileIcons.IC_SEARCH
    };

    static int activeTab = TAB_HOME;
    static int librarySubTab = 0;
    static int settingsSubPage = 0;
    static String settingsHighlightKey = "";
    static String pendingSearchKeyword = "";

    final MainActivity a;
    FrameLayout shellRoot;
    FrameLayout contentContainer;
    AmbientCanvasView ambientCanvas;
    View statusBarVeil;
    FrameLayout floatingDockWrap;
    LinearLayout expandedDockLayer;
    LinearLayout collapsedDockLayer;
    LinearLayout mainCapsule;
    View collapsedPill;
    View searchBubble;
    View collapsedSearchBubble;
    boolean dockCollapsed;
    boolean renderedPortrait;
    private boolean renderedDark;
    private int renderedAccent;
    boolean isSideRailLayout;
    private int lastRenderedTab = -1;

    private boolean dockCollapseFullHide;
    private MotionSpring dockCollapseSpring;
    private MotionLoop.Step dockCollapseStep;
    private FrameLayout activeQuickMenuOverlay;

    /** Pure-JVM descriptor of a floating quick action surfaced on Dock long-press / slide. */
    static final class DockQuickAction {
        final String id;
        final String label;
        final int iconId;

        DockQuickAction(String id, String label, int iconId) {
            this.id = id;
            this.label = label;
            this.iconId = iconId;
        }
    }

    /** Pure-JVM quick-action menu catalog per bottom Dock tab. */
    static List<DockQuickAction> quickActionsForTab(int tabIndex) {
        List<DockQuickAction> out = new ArrayList<>();
        switch (tabIndex) {
            case TAB_LIVE:
                out.add(new DockQuickAction("import_live", "导入直播源", MobileIcons.IC_PLUS));
                out.add(new DockQuickAction("live_epg", "节目单设置", MobileIcons.IC_BELL));
                out.add(new DockQuickAction("refresh_live", "刷新频道", MobileIcons.IC_REFRESH));
                break;
            case TAB_LIBRARY:
                out.add(new DockQuickAction("lib_history", "观看历史", MobileIcons.IC_HISTORY));
                out.add(new DockQuickAction("lib_favorites", "我的收藏", MobileIcons.IC_HEART_FILLED));
                out.add(new DockQuickAction("lib_downloads", "离线下载", MobileIcons.IC_DOWNLOAD));
                out.add(new DockQuickAction("lib_sync", "云同步", MobileIcons.IC_CLOUD_SYNC));
                break;
            case TAB_SETTINGS:
                out.add(new DockQuickAction("toggle_theme", "切换日夜模式", MobileIcons.IC_MOON));
                out.add(new DockQuickAction("settings_playback", "播放与画质", MobileIcons.IC_PLAY));
                out.add(new DockQuickAction("privacy_space", "隐私空间", MobileIcons.IC_PRIVACY));
                out.add(new DockQuickAction("replay_onboarding", "新手引导", MobileIcons.IC_SPARKLE));
                break;
            case TAB_SEARCH:
                out.add(new DockQuickAction("clipboard_search", "剪贴板搜索", MobileIcons.IC_CLIPBOARD));
                out.add(new DockQuickAction("clipboard_import", "剪贴板导入源", MobileIcons.IC_LINK));
                out.add(new DockQuickAction("fresh_search", "全站搜索", MobileIcons.IC_SEARCH));
                break;
            case TAB_HOME:
            default:
                out.add(new DockQuickAction("switch_source", "切换片源", MobileIcons.IC_SWITCH_SOURCE));
                out.add(new DockQuickAction("import_source", "导入片源", MobileIcons.IC_PLUS));
                out.add(new DockQuickAction("manage_sources", "片源管理", MobileIcons.IC_FOLDER));
                out.add(new DockQuickAction("scroll_top", "回到顶部", MobileIcons.IC_DISCOVER));
                break;
        }
        return out;
    }

    /**
     * Pure-JVM slide-to-select hit-tester mapping a live finger coordinate onto the floating Dock
     * quick-action menu rows (returns {@code -1} when outside horizontal/vertical menu bounds).
     */
    static int hitTestQuickAction(
            float fingerX,
            float fingerY,
            float menuLeft,
            float menuRight,
            float[] itemTops,
            float[] itemBottoms,
            float slopPx) {
        if (itemTops == null || itemBottoms == null || itemTops.length == 0) return -1;
        float pad = Math.max(0f, slopPx);
        if (fingerX < menuLeft - pad || fingerX > menuRight + pad) return -1;
        int n = Math.min(itemTops.length, itemBottoms.length);
        for (int i = 0; i < n; i++) {
            if (fingerY >= itemTops[i] - 2f && fingerY <= itemBottoms[i] + 2f) {
                return i;
            }
        }
        return -1;
    }

    interface TextAction {
        void run(String text);
    }

    Cms.Site activeSite;
    Runnable reloadCategory;
    TextAction onSourceRejected;

    private final View[] tabItemViews = new View[5];
    private final MobileIcons.IconView[] tabIconViews = new MobileIcons.IconView[5];
    private final TextView[] tabLabelViews = new TextView[5];
    private SpringNavTrackView activeNavTrack;
    private MobileIcons.IconView collapsedPillIcon;
    private TextView collapsedPillLabel;
    private MobileIcons.IconView searchBubbleIcon;
    private MobileIcons.IconView collapsedSearchIcon;

    MobileRootShell(MainActivity activity) {
        this.a = activity;
    }

    static void resetStaticState() {
        activeTab = TAB_HOME;
        librarySubTab = 0;
        settingsSubPage = 0;
        settingsHighlightKey = "";
        pendingSearchKeyword = "";
        MobileSearchPage.invalidateSession();
        MobilePosterTransition.clearSavedState(null);
    }

    /**
     * Pure-JVM strictly non-overlapping two-phase cross-morph alpha schedule for collapsed dock
     * transitions.
     *
     * <p>Returns {@code [expandedAlpha, collapsedAlpha]} with a clean dead-band on {@code [0.42,
     * 0.48]} so the expanded dock and collapsed pill are NEVER visible in the same frame —
     * mathematically eliminating ghosting ("虚影").
     */
    static float[] computeDockMorphAlphas(float progress) {
        float p = Math.max(0f, Math.min(1f, Float.isNaN(progress) ? 0f : progress));
        float expanded = p < 0.42f ? (1f - p / 0.42f) : 0f;
        float collapsed = p > 0.48f ? ((p - 0.48f) / 0.52f) : 0f;
        return new float[] {expanded, collapsed};
    }

    /**
     * Pure-JVM directional scroll accumulator with hysteresis, bottom-overscroll protection, and
     * cooldown to prevent 120Hz micro-delta dock jitter in both collapse and auto-hide modes.
     */
    static final class DockScrollTracker {
        static final int ACTION_NONE = 0;
        static final int ACTION_COLLAPSE = 1;
        static final int ACTION_EXPAND = -1;
        static final long COOLDOWN_MS = 120L;

        private int lastY = -1;
        private int accumDy = 0;
        private boolean collapsed = false;
        private long lastToggleMs = -10_000L;

        void reset(boolean isCollapsed) {
            this.lastY = -1;
            this.accumDy = 0;
            this.collapsed = isCollapsed;
        }

        void syncCollapsed(boolean isCollapsed, long nowMs) {
            if (this.collapsed != isCollapsed) {
                this.collapsed = isCollapsed;
                this.accumDy = 0;
            }
        }

        int onScroll(
                int scrollY,
                boolean canScrollDown,
                long nowMs,
                int collapseDistPx,
                int expandDistPx,
                int topAutoExpandPx,
                int minCollapseYPx) {
            int y = Math.max(0, scrollY);
            if (lastY < 0) {
                lastY = y;
                return ACTION_NONE;
            }
            int dy = y - lastY;
            lastY = y;

            if (collapsed && y <= topAutoExpandPx) {
                collapsed = false;
                accumDy = 0;
                lastToggleMs = nowMs;
                return ACTION_EXPAND;
            }
            if (dy == 0) return ACTION_NONE;

            if ((dy > 0 && accumDy < 0) || (dy < 0 && accumDy > 0)) {
                accumDy = 0;
            }
            accumDy += dy;

            if (!collapsed) {
                if (y >= minCollapseYPx
                        && accumDy >= collapseDistPx
                        && (nowMs - lastToggleMs >= COOLDOWN_MS)) {
                    collapsed = true;
                    accumDy = 0;
                    lastToggleMs = nowMs;
                    return ACTION_COLLAPSE;
                }
            } else {
                if (accumDy <= -expandDistPx && (nowMs - lastToggleMs >= COOLDOWN_MS)) {
                    collapsed = false;
                    accumDy = 0;
                    lastToggleMs = nowMs;
                    return ACTION_EXPAND;
                }
            }
            return ACTION_NONE;
        }
    }

    static void show(MainActivity a) {
        MobileRootShell shell = new MobileRootShell(a);
        a.mobileShell = shell;
        shell.render();
    }

    static void openTab(MainActivity a, int tab) {
        activeTab = tab;
        if (tab == TAB_SETTINGS) settingsSubPage = 0;
        if (a.current != null && a.current.home && a.mobileShell != null) {
            a.mobileShell.switchTab(tab);
        } else {
            a.open(new MainActivity.Screen(() -> show(a)), false);
        }
    }

    static void openSearch(MainActivity a, String initialKeyword) {
        if (initialKeyword != null && !initialKeyword.trim().isEmpty()) {
            pendingSearchKeyword = initialKeyword.trim();
        }
        openTab(a, TAB_SEARCH);
    }

    boolean resume() {
        if (shellRoot == null
                || contentContainer == null
                || a.isPortrait() != renderedPortrait
                || MobileTheme.isDark(a) != renderedDark
                || a.mobileAccentColor() != renderedAccent
                || a.isFinishing()) {
            return false;
        }
        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }
        a.applyMobileSystemBars(false);
        a.root = shellRoot;
        a.setContentView(shellRoot);
        a.watchRootLayout(shellRoot);
        expandDock();
        ImageLoader.resumeMissingPosters(a, shellRoot);
        return true;
    }

    void showSourceRejectedRecovery(String reason) {
        if (onSourceRejected != null) {
            onSourceRejected.run(reason);
        }
    }

    boolean handleBack() {
        if (dismissQuickMenu(true)) {
            return true;
        }
        if (activeTab == TAB_SETTINGS && settingsSubPage != 0) {
            settingsSubPage = 0;
            settingsHighlightKey = "";
            switchTab(TAB_SETTINGS);
            return true;
        }
        if (activeTab != TAB_HOME) {
            switchTab(TAB_HOME);
            return true;
        }
        return false;
    }

    void resolveActiveSite() {
        activeSite = null;
        if (a.config == null || a.config.sites.isEmpty()) return;
        String saved = a.prefs.getString(Prefs.SELECTED_SITE, "");
        String rawSkip = a.prefs.getString(Prefs.RECOVERED_SKIP_SITE, "");
        String skipSite = rawSkip == null ? "" : rawSkip.trim();
        for (Cms.Site s : a.config.sites) {
            if (s.key.equals(saved) && a.available(s)) {
                activeSite = s;
                if (!skipSite.isEmpty()) {
                    a.prefs.edit().putString(Prefs.RECOVERED_SKIP_SITE, "").apply();
                }
                return;
            }
        }
        // After startup crash recovery clears a faulty site, skip that site on fallback selection
        // even when it is the first entry in config.sites so Home opens the next healthy site.
        // If no alternative site exists, leave activeSite null so MobileHomePage offers manual
        // switch-source and manual retry controls instead of looping back into the crashed site.
        for (Cms.Site s : a.config.sites) {
            if (a.available(s) && (skipSite.isEmpty() || !s.key.equals(skipSite))) {
                activeSite = s;
                android.content.SharedPreferences.Editor ed =
                        a.prefs.edit().putString(Prefs.SELECTED_SITE, s.key);
                if (!skipSite.isEmpty()) {
                    ed.putString(Prefs.RECOVERED_SKIP_SITE, "");
                }
                ed.apply();
                return;
            }
        }
    }

    void setAmbientColor(int color) {
        if (ambientCanvas != null && a.mobilePrefs().getBoolean(Prefs.COVER_AMBIENT, true)) {
            ambientCanvas.setDynamicTint(color);
        }
    }

    void setStatusBarVeilAlpha(float alpha) {
        if (statusBarVeil != null) {
            float clamped = Math.max(0f, Math.min(1f, alpha));
            statusBarVeil.setAlpha(clamped);
            statusBarVeil.setVisibility(clamped > 0.01f ? View.VISIBLE : View.INVISIBLE);
        }
    }

    void bindScrollBehavior(final ScrollView sv) {
        bindScrollBehavior(sv, null);
    }

    void bindScrollBehavior(final ScrollView sv, final Runnable onScrollExtra) {
        if (sv == null) return;
        final DockScrollTracker tracker = new DockScrollTracker();
        final int collapseDistPx = a.dp(24);
        final int expandDistPx = a.dp(24);
        final int topAutoExpandPx = a.dp(20);
        final int minCollapseYPx = a.dp(56);
        final Runnable handleScroll =
                () -> {
                    if (onScrollExtra != null) onScrollExtra.run();
                    int behavior = a.mobilePrefs().getInt(Prefs.NAV_SCROLL_BEHAVIOR, 1);
                    if (behavior == 0 || floatingDockWrap == null) return;
                    long nowMs = SystemClock.uptimeMillis();
                    tracker.syncCollapsed(dockCollapsed, nowMs);
                    int action =
                            tracker.onScroll(
                                    sv.getScrollY(),
                                    sv.canScrollVertically(1),
                                    nowMs,
                                    collapseDistPx,
                                    expandDistPx,
                                    topAutoExpandPx,
                                    minCollapseYPx);
                    if (action == DockScrollTracker.ACTION_COLLAPSE) {
                        collapseDock(behavior == 2);
                    } else if (action == DockScrollTracker.ACTION_EXPAND) {
                        expandDock();
                    }
                };
        if (Build.VERSION.SDK_INT >= 23) {
            sv.setOnScrollChangeListener(
                    (v, scrollX, scrollY, oldScrollX, oldScrollY) -> handleScroll.run());
        } else {
            sv.getViewTreeObserver().addOnScrollChangedListener(handleScroll::run);
        }
    }

    private void ensureDockSpring() {
        if (dockCollapseSpring == null) {
            dockCollapseSpring =
                    new MotionSpring(
                            0f,
                            MotionTokens.SPRING_PLAYER_TRANSITION.motionSpringFrequency,
                            0.002f);
        }
    }

    private void stopDockSpring() {
        if (dockCollapseStep != null) {
            MotionLoop.remove(dockCollapseStep);
            dockCollapseStep = null;
        }
    }

    private void applyDockProgress(float rawProgress) {
        if (floatingDockWrap == null || expandedDockLayer == null) return;
        float p = Math.max(0f, Math.min(1f, rawProgress));
        boolean reduced = MobileMotion.isReduced(a);
        if (dockCollapseFullHide) {
            if (collapsedDockLayer != null) {
                collapsedDockLayer.setAlpha(0f);
                collapsedDockLayer.setVisibility(View.INVISIBLE);
            }
            float alpha = 1f - p;
            expandedDockLayer.setAlpha(alpha);
            expandedDockLayer.setTranslationY(reduced ? 0f : p * a.dp(96));
            expandedDockLayer.setScaleX(reduced ? 1f : (1f - 0.04f * p));
            expandedDockLayer.setScaleY(reduced ? 1f : (1f - 0.04f * p));
            expandedDockLayer.setVisibility(alpha > 0.01f ? View.VISIBLE : View.INVISIBLE);
            return;
        }
        float[] alphas = computeDockMorphAlphas(p);
        float expA = alphas[0];
        float colA = alphas[1];

        expandedDockLayer.setAlpha(expA);
        if (reduced) {
            expandedDockLayer.setTranslationY(0f);
            expandedDockLayer.setScaleX(1f);
            expandedDockLayer.setScaleY(1f);
        } else {
            float expT = 1f - expA;
            expandedDockLayer.setTranslationY(expT * a.dp(6));
            float expS = 1f - 0.05f * expT;
            expandedDockLayer.setScaleX(expS);
            expandedDockLayer.setScaleY(expS);
        }
        expandedDockLayer.setVisibility(expA > 0.01f ? View.VISIBLE : View.INVISIBLE);

        if (collapsedDockLayer != null) {
            collapsedDockLayer.setAlpha(colA);
            if (reduced) {
                collapsedDockLayer.setTranslationY(0f);
                collapsedDockLayer.setScaleX(1f);
                collapsedDockLayer.setScaleY(1f);
            } else {
                float colT = 1f - colA;
                collapsedDockLayer.setTranslationY(colT * a.dp(6));
                float colS = 1f - 0.05f * colT;
                collapsedDockLayer.setScaleX(colS);
                collapsedDockLayer.setScaleY(colS);
            }
            collapsedDockLayer.setVisibility(colA > 0.01f ? View.VISIBLE : View.INVISIBLE);
        }
    }

    private void driveDockSpringTo(float target) {
        if (floatingDockWrap == null) return;
        ensureDockSpring();
        if (MobileMotion.isReduced(a) || !UiCompat.isAttached(floatingDockWrap)) {
            stopDockSpring();
            dockCollapseSpring.snap(target);
            applyDockProgress(target);
            return;
        }
        dockCollapseSpring.target(target);
        if (dockCollapseStep == null) {
            dockCollapseStep =
                    dt -> {
                        if (floatingDockWrap == null || !UiCompat.isAttached(floatingDockWrap)) {
                            dockCollapseStep = null;
                            return false;
                        }
                        boolean moving = dockCollapseSpring.step(dt);
                        applyDockProgress(dockCollapseSpring.value);
                        if (!moving) {
                            dockCollapseStep = null;
                        }
                        return moving;
                    };
        }
        MotionLoop.add(dockCollapseStep);
    }

    private void collapseDock(boolean fullHide) {
        if (floatingDockWrap == null) return;
        if (dockCollapsed && dockCollapseFullHide == fullHide) return;
        dockCollapsed = true;
        dockCollapseFullHide = fullHide;
        driveDockSpringTo(1f);
    }

    void expandDock() {
        if (floatingDockWrap == null) return;
        if (!dockCollapsed && (dockCollapseSpring == null || dockCollapseSpring.value <= 0.005f)) {
            return;
        }
        dockCollapsed = false;
        driveDockSpringTo(0f);
    }

    private static int findFirstScrollY(View root) {
        if (root instanceof ScrollView) {
            return root.getScrollY();
        }
        if (root instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) root;
            for (int i = 0; i < vg.getChildCount(); i++) {
                int y = findFirstScrollY(vg.getChildAt(i));
                if (y > 0) return y;
            }
        }
        return 0;
    }

    void render() {
        if (activeTab == TAB_SETTINGS && a.pendingSettingsScrollY < 0 && contentContainer != null) {
            int curScroll = findFirstScrollY(contentContainer);
            if (curScroll > 0) {
                a.pendingSettingsScrollY = curScroll;
            }
        }

        stopDockSpring();
        dismissQuickMenu(false);
        if (a.back.isEmpty()) {
            MobilePosterTransition.clearSavedState(a);
        }
        a.clearPlaybackLoading();
        a.cancelArtwork();
        a.cancelPageRequests();
        if (a.current != null) {
            a.current.home = true;
            a.current.mobileHome = this;
        }
        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }
        a.stopWeb();
        a.stopMagnet();
        a.releasePlayer();
        a.generation++;

        a.applyMobileSystemBars(false);
        resolveActiveSite();

        MobileTheme.Palette p = MobileTheme.of(a);
        renderedDark = p.isDark;
        renderedAccent = p.accent;
        dockCollapsed = false;
        dockCollapseFullHide = false;
        dockCollapseSpring = null;
        lastRenderedTab = -1;
        statusBarVeil = null;
        floatingDockWrap = null;
        expandedDockLayer = null;
        collapsedDockLayer = null;
        mainCapsule = null;
        activeNavTrack = null;
        collapsedPill = null;
        searchBubble = null;
        collapsedSearchBubble = null;
        collapsedPillIcon = null;
        collapsedPillLabel = null;
        searchBubbleIcon = null;
        collapsedSearchIcon = null;
        for (int i = 0; i < 5; i++) {
            tabItemViews[i] = null;
            tabIconViews[i] = null;
            tabLabelViews[i] = null;
        }

        shellRoot = new FrameLayout(a);
        shellRoot.setBackgroundColor(p.bgCanvas);
        shellRoot.setClipChildren(false);
        shellRoot.setClipToPadding(false);
        a.root = shellRoot;
        a.setContentView(shellRoot);
        a.watchRootLayout(shellRoot);
        renderedPortrait = a.isPortrait();
        final boolean builtPortrait = renderedPortrait;
        shellRoot.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    int w = r - l, h = b - t;
                    if (w <= 0 || h <= 0 || a.root != shellRoot) return;
                    a.usableWidth = w;
                    a.usableHeight = h;
                    if ((w < h) != builtPortrait) {
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing()
                                            && !a.isDestroyed()
                                            && a.root == shellRoot
                                            && a.current != null
                                            && a.current.home) {
                                        show(a);
                                    }
                                });
                    }
                });

        ambientCanvas = new AmbientCanvasView(a);
        shellRoot.addView(ambientCanvas, new FrameLayout.LayoutParams(-1, -1));

        float widthDp = a.windowWidth() / a.getResources().getDisplayMetrics().density;
        isSideRailLayout = widthDp >= 640 && !a.isPortrait();

        if (isSideRailLayout) {
            LinearLayout mainRow = a.row();
            mainRow.setGravity(Gravity.TOP);
            shellRoot.addView(mainRow, new FrameLayout.LayoutParams(-1, -1));

            FrameLayout railWrap = new FrameLayout(a);
            railWrap.setPadding(
                    a.dp(12),
                    a.statusBarHeight() + a.dp(12),
                    a.dp(6),
                    a.navigationBarHeight() + a.dp(12));
            LinearLayout rail = buildVerticalSideRail(p);
            railWrap.addView(
                    rail, new FrameLayout.LayoutParams(a.dp(76), -2, Gravity.CENTER_VERTICAL));
            mainRow.addView(railWrap, new LinearLayout.LayoutParams(-2, -1));

            contentContainer = new FrameLayout(a);
            mainRow.addView(contentContainer, new LinearLayout.LayoutParams(0, -1, 1f));
        } else {
            contentContainer = new FrameLayout(a);
            shellRoot.addView(contentContainer, new FrameLayout.LayoutParams(-1, -1));

            // Immersive status-bar fade veil so scrolled content glides smoothly beneath system
            // icons without harsh visual collisions on Android 15/16 Edge-to-Edge screens.
            statusBarVeil = new View(a);
            statusBarVeil.setClickable(false);
            statusBarVeil.setFocusable(false);
            statusBarVeil.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {
                                MobileTheme.withAlpha(p.bgCanvas, 0xEB),
                                MobileTheme.withAlpha(p.bgCanvas, 0x85),
                                Color.TRANSPARENT
                            }));
            shellRoot.addView(
                    statusBarVeil,
                    new FrameLayout.LayoutParams(-1, a.statusBarHeight() + a.dp(14), Gravity.TOP));

            floatingDockWrap = buildFloatingBottomDock(p);
            FrameLayout.LayoutParams dockLp =
                    new FrameLayout.LayoutParams(-1, a.dp(64), Gravity.BOTTOM);
            dockLp.bottomMargin = a.navigationBarHeight() + a.dp(10);
            shellRoot.addView(floatingDockWrap, dockLp);
        }

        // Live Android 15/16 WindowInsets listener keeps status-bar veil & floating dock margin
        // pixel-locked to the real system gesture bar / punch-hole cutout after first attach.
        if (Build.VERSION.SDK_INT >= 23) {
            shellRoot.setOnApplyWindowInsetsListener(
                    (v, insets) -> {
                        if (insets != null) {
                            int topInset;
                            int bottomInset;
                            if (Build.VERSION.SDK_INT >= 30) {
                                topInset =
                                        insets.getInsets(
                                                        WindowInsets.Type.statusBars()
                                                                | WindowInsets.Type.displayCutout())
                                                .top;
                                bottomInset =
                                        insets.getInsets(WindowInsets.Type.navigationBars()).bottom;
                            } else {
                                topInset = insets.getSystemWindowInsetTop();
                                bottomInset = insets.getSystemWindowInsetBottom();
                            }
                            if (statusBarVeil != null && topInset > 0) {
                                ViewGroup.LayoutParams slp = statusBarVeil.getLayoutParams();
                                int targetH = topInset + a.dp(14);
                                if (slp != null && slp.height != targetH) {
                                    slp.height = targetH;
                                    statusBarVeil.setLayoutParams(slp);
                                }
                            }
                            if (floatingDockWrap != null) {
                                FrameLayout.LayoutParams dlp =
                                        (FrameLayout.LayoutParams)
                                                floatingDockWrap.getLayoutParams();
                                int clampedBottom = Math.max(0, Math.min(a.dp(56), bottomInset));
                                int targetMargin = clampedBottom + a.dp(10);
                                if (dlp != null && dlp.bottomMargin != targetMargin) {
                                    dlp.bottomMargin = targetMargin;
                                    floatingDockWrap.setLayoutParams(dlp);
                                }
                            }
                        }
                        return insets;
                    });
        }

        switchTab(activeTab);
    }

    private FrameLayout buildFloatingBottomDock(MobileTheme.Palette p) {
        boolean unifiedFiveBar = a.mobilePrefs().getInt(Prefs.NAV_STYLE, 0) == 1;
        float dockElev = a.dp(p.isDark ? 10f : 6f);
        int availW = a.windowWidth();

        // Fixed-bounds stage (MATCH_PARENT x 64dp) ensures zero requestLayout() jitter while
        // scrolling in both collapsed and auto-hide dock modes.
        FrameLayout stage = new FrameLayout(a);
        stage.setClipChildren(false);
        stage.setClipToPadding(false);
        stage.setTag("mobile-bottom-dock");

        // Layer A: Expanded Android 16 / Material 3 Expressive Floating Navigation Bar
        expandedDockLayer = a.row();
        expandedDockLayer.setGravity(Gravity.CENTER);
        expandedDockLayer.setClipChildren(false);
        expandedDockLayer.setClipToPadding(false);

        SpringNavTrackView navTrack = new SpringNavTrackView(a, false, p.pillSelectedFill);
        navTrack.setGravity(Gravity.CENTER_VERTICAL);
        navTrack.setPadding(a.dp(7), a.dp(6), a.dp(7), a.dp(6));
        navTrack.setBackground(MobileTheme.dockFrostBg(a, 32f));
        UiCompat.setElevation(navTrack, dockElev);
        mainCapsule = navTrack;
        activeNavTrack = navTrack;

        int tabCount = unifiedFiveBar ? 5 : 4;
        int fourCellW =
                Math.max(
                        a.dp(54),
                        Math.min(
                                a.dp(66),
                                (availW - a.dp(32) - a.dp(10) - a.dp(56) - a.dp(14)) / 4));
        for (int i = 0; i < tabCount; i++) {
            final int idx = i;
            LinearLayout cell = a.vertical();
            cell.setGravity(Gravity.CENTER);
            cell.setTag(idx == TAB_SEARCH ? "mobile-nav-search" : ("mobile-nav:" + idx));

            // M3 Expressive 30dp icon slot aligned with the sliding 52dp x 30dp pill indicator
            FrameLayout iconSlot = new FrameLayout(a);
            MobileIcons.IconView icon =
                    MobileIcons.create(a, TAB_ICON_IDS[i], 20f, p.textSecondary);
            tabIconViews[i] = icon;
            iconSlot.addView(
                    icon, new FrameLayout.LayoutParams(a.dp(20), a.dp(20), Gravity.CENTER));
            cell.addView(iconSlot, new LinearLayout.LayoutParams(-1, a.dp(30)));

            TextView lbl = a.text(TAB_NAMES[i], 10.5f, p.textSecondary);
            lbl.setIncludeFontPadding(false);
            lbl.setGravity(Gravity.CENTER);
            lbl.setPadding(0, a.dp(2.5f), 0, 0);
            tabLabelViews[i] = lbl;
            cell.addView(lbl, new LinearLayout.LayoutParams(-1, -2));
            tabItemViews[i] = cell;

            bindDockTabQuickGestures(cell, idx);
            LinearLayout.LayoutParams cellLp =
                    unifiedFiveBar
                            ? new LinearLayout.LayoutParams(0, a.dp(52), 1f)
                            : new LinearLayout.LayoutParams(fourCellW, a.dp(52));
            mainCapsule.addView(cell, cellLp);
        }

        if (unifiedFiveBar) {
            int barW = Math.min(Math.max(a.dp(280), availW - a.dp(32)), a.dp(384));
            expandedDockLayer.addView(mainCapsule, new LinearLayout.LayoutParams(barW, a.dp(64)));
        } else {
            expandedDockLayer.addView(mainCapsule, new LinearLayout.LayoutParams(-2, a.dp(64)));

            // Detached "+1" Material 3 Expressive Morphing Search FAB (56dp circle -> squircle)
            FrameLayout sWrap = new FrameLayout(a);
            sWrap.setTag("mobile-nav-search");
            sWrap.setBackground(MobileTheme.dockFrostBg(a, 28f));
            UiCompat.setElevation(sWrap, dockElev);

            searchBubbleIcon = MobileIcons.create(a, MobileIcons.IC_SEARCH, 21f, p.textPrimary);
            sWrap.addView(
                    searchBubbleIcon,
                    new FrameLayout.LayoutParams(a.dp(21), a.dp(21), Gravity.CENTER));
            bindDockTabQuickGestures(sWrap, TAB_SEARCH);

            LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(a.dp(56), a.dp(56));
            sLp.leftMargin = a.dp(10);
            expandedDockLayer.addView(sWrap, sLp);
            searchBubble = sWrap;
        }
        stage.addView(
                expandedDockLayer, new FrameLayout.LayoutParams(-1, a.dp(64), Gravity.CENTER));

        // Layer B: Collapsed Compact Pill (stacked inside FrameLayout, strictly non-overlapping!)
        collapsedDockLayer = a.row();
        collapsedDockLayer.setGravity(Gravity.CENTER);
        collapsedDockLayer.setClipChildren(false);
        collapsedDockLayer.setClipToPadding(false);
        collapsedDockLayer.setAlpha(0f);
        collapsedDockLayer.setVisibility(View.INVISIBLE);

        LinearLayout miniExpand = a.row();
        miniExpand.setGravity(Gravity.CENTER_VERTICAL);
        miniExpand.setPadding(a.dp(16), 0, a.dp(14), 0);
        miniExpand.setBackground(MobileTheme.dockFrostBg(a, 24f));
        UiCompat.setElevation(miniExpand, dockElev);

        collapsedPillIcon = MobileIcons.create(a, TAB_ICON_IDS[TAB_HOME], 18f, p.accent);
        collapsedPillIcon.setFilled(true);
        LinearLayout.LayoutParams miniIconLp = new LinearLayout.LayoutParams(a.dp(18), a.dp(18));
        miniIconLp.rightMargin = a.dp(7);
        miniExpand.addView(collapsedPillIcon, miniIconLp);

        collapsedPillLabel = a.text(TAB_NAMES[TAB_HOME], 13f, p.textPrimary);
        collapsedPillLabel.setTypeface(null, Typeface.BOLD);
        miniExpand.addView(collapsedPillLabel);

        MobileIcons.IconView expandChevron =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_DOWN, 12.5f, p.textTertiary);
        expandChevron.setRotation(180f);
        LinearLayout.LayoutParams miniChevLp =
                new LinearLayout.LayoutParams(a.dp(12.5f), a.dp(12.5f));
        miniChevLp.leftMargin = a.dp(6);
        miniExpand.addView(expandChevron, miniChevLp);

        MobileMotion.bindPress(miniExpand, 0.94f);
        miniExpand.setOnClickListener(v -> expandDock());
        collapsedPill = miniExpand;
        collapsedDockLayer.addView(miniExpand, new LinearLayout.LayoutParams(-2, a.dp(46)));

        if (!unifiedFiveBar) {
            FrameLayout miniSearch = new FrameLayout(a);
            miniSearch.setBackground(MobileTheme.dockFrostBg(a, 23f));
            UiCompat.setElevation(miniSearch, dockElev);
            collapsedSearchIcon = MobileIcons.create(a, MobileIcons.IC_SEARCH, 19f, p.textPrimary);
            miniSearch.addView(
                    collapsedSearchIcon,
                    new FrameLayout.LayoutParams(a.dp(19), a.dp(19), Gravity.CENTER));
            MobileMotion.bindPress(miniSearch, 0.92f);
            miniSearch.setOnClickListener(v -> switchTab(TAB_SEARCH));
            LinearLayout.LayoutParams msLp = new LinearLayout.LayoutParams(a.dp(46), a.dp(46));
            msLp.leftMargin = a.dp(10);
            collapsedDockLayer.addView(miniSearch, msLp);
            collapsedSearchBubble = miniSearch;
        }
        stage.addView(
                collapsedDockLayer, new FrameLayout.LayoutParams(-1, a.dp(64), Gravity.CENTER));
        return stage;
    }

    private LinearLayout buildVerticalSideRail(MobileTheme.Palette p) {
        SpringNavTrackView rail = new SpringNavTrackView(a, true, p.pillSelectedFill);
        rail.setGravity(Gravity.CENTER_HORIZONTAL);
        rail.setPadding(a.dp(6), a.dp(10), a.dp(6), a.dp(10));
        rail.setBackground(MobileTheme.dockFrostBg(a, 28f));
        UiCompat.setElevation(rail, a.dp(p.isDark ? 10f : 6f));
        activeNavTrack = rail;

        for (int i = 0; i < 5; i++) {
            final int tabIdx = i;
            LinearLayout cell = a.vertical();
            cell.setGravity(Gravity.CENTER);
            cell.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(6));
            cell.setTag(i == TAB_SEARCH ? "mobile-nav-search" : ("mobile-nav:" + i));

            FrameLayout iconSlot = new FrameLayout(a);
            MobileIcons.IconView icon =
                    MobileIcons.create(a, TAB_ICON_IDS[i], 20f, p.textSecondary);
            tabIconViews[i] = icon;
            iconSlot.addView(
                    icon, new FrameLayout.LayoutParams(a.dp(20), a.dp(20), Gravity.CENTER));
            cell.addView(iconSlot, new LinearLayout.LayoutParams(-1, a.dp(30)));

            TextView lbl = a.text(TAB_NAMES[i], 10.5f, p.textSecondary);
            lbl.setIncludeFontPadding(false);
            lbl.setGravity(Gravity.CENTER);
            lbl.setPadding(0, a.dp(2.5f), 0, 0);
            tabLabelViews[i] = lbl;
            cell.addView(lbl, new LinearLayout.LayoutParams(-1, -2));
            tabItemViews[i] = cell;

            bindDockTabQuickGestures(cell, tabIdx);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            if (i < 4) lp.bottomMargin = a.dp(6);
            rail.addView(cell, lp);
        }
        return rail;
    }

    /**
     * Unified tactile Dock gesture controller bound to EVERY Dock tab &amp; Search FAB:
     * <ul>
     *   <li><b>Tap</b>: switches immediately to {@code tabIdx}.
     *   <li><b>Long-press (~260ms) or upward pull (&gt;= 28dp)</b>: blooms a sleek frosted
     *       quick-action menu directly above the button.
     *   <li><b>Long-press + slide &amp; release</b>: tracks finger 1:1 across quick actions with
     *       live accent pill highlight &amp; micro-tick haptics, executing on release!
     *   <li><b>Long-press + lift in place</b>: pins the floating menu open for comfortable tap.
     * </ul>
     */
    private void bindDockTabQuickGestures(final View view, final int tabIdx) {
        final float[] downX = {0f};
        final float[] downY = {0f};
        final boolean[] menuActive = {false};
        final boolean[] draggedDuringMenu = {false};
        final float maxPullPx = a.dp(18);
        final float pullTriggerPx = a.dp(28);
        final float touchSlop = ViewConfiguration.get(a).getScaledTouchSlop();
        final QuickMenuSession[] sessionRef = {null};
        final Runnable[] holdTimerRef = {null};

        view.setFocusable(false);
        view.setFocusableInTouchMode(false);
        view.setClickable(true);

        final Runnable cancelHold =
                () -> {
                    if (holdTimerRef[0] != null) {
                        view.removeCallbacks(holdTimerRef[0]);
                        holdTimerRef[0] = null;
                    }
                };

        final Runnable openMenuNow =
                () -> {
                    if (menuActive[0] || !UiCompat.isAttached(view)) return;
                    menuActive[0] = true;
                    draggedDuringMenu[0] = false;
                    cancelHold.run();
                    view.animate().cancel();
                    view.setTranslationY(0f);
                    view.setScaleX(1f);
                    view.setScaleY(1f);
                    try {
                        view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
                    } catch (Throwable ignored) {
                    }
                    MobileMotion.popBounce(view);
                    sessionRef[0] = showDockQuickMenu(view, tabIdx);
                };

        view.setOnTouchListener(
                (v, ev) -> {
                    int act = ev.getActionMasked();
                    boolean reduced = MobileMotion.isReduced(a);
                    if (act == MotionEvent.ACTION_DOWN) {
                        downX[0] = ev.getRawX();
                        downY[0] = ev.getRawY();
                        menuActive[0] = false;
                        draggedDuringMenu[0] = false;
                        sessionRef[0] = null;
                        cancelHold.run();
                        v.animate().cancel();
                        if (!reduced) {
                            v.animate()
                                    .scaleX(0.93f)
                                    .scaleY(0.93f)
                                    .setDuration(MotionTokens.DURATION_MICRO_MS)
                                    .setInterpolator(MotionTokens.createDecelerateInterpolator())
                                    .start();
                        }
                        holdTimerRef[0] = openMenuNow;
                        v.postDelayed(openMenuNow, 260L);
                        return true;
                    } else if (act == MotionEvent.ACTION_MOVE) {
                        float dx = ev.getRawX() - downX[0];
                        float dy = downY[0] - ev.getRawY();
                        if (!menuActive[0]) {
                            if (Math.abs(dx) > touchSlop * 1.4f && dy < touchSlop) {
                                cancelHold.run();
                            }
                            if (dy > 0f && !reduced) {
                                v.setTranslationY(-MobileMotion.rubberBand(dy, maxPullPx));
                            }
                            if (dy >= pullTriggerPx) {
                                openMenuNow.run();
                                if (sessionRef[0] != null) {
                                    draggedDuringMenu[0] = true;
                                    sessionRef[0].updateHover(ev.getRawX(), ev.getRawY());
                                }
                            }
                        } else if (sessionRef[0] != null) {
                            if (Math.hypot(dx, dy) > touchSlop) {
                                draggedDuringMenu[0] = true;
                            }
                            sessionRef[0].updateHover(ev.getRawX(), ev.getRawY());
                        }
                        return true;
                    } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                        cancelHold.run();
                        v.animate().cancel();
                        if (reduced) {
                            v.setTranslationY(0f);
                            v.setScaleX(1f);
                            v.setScaleY(1f);
                        } else {
                            v.animate()
                                    .translationY(0f)
                                    .scaleX(1f)
                                    .scaleY(1f)
                                    .setDuration(MotionTokens.DURATION_FAST_MS)
                                    .setInterpolator(MotionTokens.createDecelerateInterpolator())
                                    .start();
                        }
                        if (menuActive[0]) {
                            QuickMenuSession s = sessionRef[0];
                            menuActive[0] = false;
                            sessionRef[0] = null;
                            if (act == MotionEvent.ACTION_UP && s != null) {
                                if (s.hoveredIndex >= 0) {
                                    s.commitHovered();
                                } else if (draggedDuringMenu[0]) {
                                    dismissQuickMenu(true);
                                }
                                // If lifted in place without dragging, keep popover open for tap!
                            } else {
                                dismissQuickMenu(true);
                            }
                            return true;
                        }
                        if (act == MotionEvent.ACTION_UP) {
                            float dist =
                                    (float)
                                            Math.hypot(
                                                    ev.getRawX() - downX[0],
                                                    ev.getRawY() - downY[0]);
                            if (dist <= touchSlop * 2.2f) {
                                switchTab(tabIdx);
                            }
                        }
                        return true;
                    }
                    return false;
                });
    }

    private final class QuickMenuSession {
        final FrameLayout overlay;
        final LinearLayout card;
        final List<DockQuickAction> actions;
        final List<LinearLayout> rowViews;
        final List<MobileIcons.IconView> rowIcons;
        final List<TextView> rowLabels;
        final int[] cardLoc = new int[2];
        final int[] rowLoc = new int[2];
        final float[] itemTops;
        final float[] itemBottoms;
        int hoveredIndex = -1;

        QuickMenuSession(
                FrameLayout overlay,
                LinearLayout card,
                List<DockQuickAction> actions,
                List<LinearLayout> rowViews,
                List<MobileIcons.IconView> rowIcons,
                List<TextView> rowLabels) {
            this.overlay = overlay;
            this.card = card;
            this.actions = actions;
            this.rowViews = rowViews;
            this.rowIcons = rowIcons;
            this.rowLabels = rowLabels;
            this.itemTops = new float[actions.size()];
            this.itemBottoms = new float[actions.size()];
        }

        void updateHover(float rawX, float rawY) {
            if (!UiCompat.isAttached(card) || card.getWidth() <= 0) return;
            card.getLocationOnScreen(cardLoc);
            float menuLeft = cardLoc[0];
            float menuRight = cardLoc[0] + card.getWidth();
            for (int i = 0; i < rowViews.size(); i++) {
                LinearLayout rv = rowViews.get(i);
                rv.getLocationOnScreen(rowLoc);
                itemTops[i] = rowLoc[1];
                itemBottoms[i] = rowLoc[1] + rv.getHeight();
            }
            int next =
                    hitTestQuickAction(
                            rawX, rawY, menuLeft, menuRight, itemTops, itemBottoms, a.dp(24));
            if (next != hoveredIndex) {
                hoveredIndex = next;
                applyHighlight(next);
                if (next >= 0) {
                    performTabHaptic(card);
                }
            }
        }

        void applyHighlight(int activeIdx) {
            MobileTheme.Palette p = MobileTheme.of(a);
            for (int i = 0; i < rowViews.size(); i++) {
                boolean sel = i == activeIdx;
                rowViews.get(i).setBackground(sel ? a.bg(p.pillSelectedFill, 12) : null);
                rowIcons.get(i).setTint(sel ? p.accent : p.textSecondary);
                rowLabels.get(i).setTextColor(sel ? p.accent : p.textPrimary);
                rowLabels.get(i).setTypeface(null, sel ? Typeface.BOLD : Typeface.NORMAL);
            }
        }

        void commitHovered() {
            if (hoveredIndex >= 0 && hoveredIndex < actions.size()) {
                DockQuickAction picked = actions.get(hoveredIndex);
                dismissQuickMenu(false);
                executeDockQuickAction(picked.id);
            } else {
                dismissQuickMenu(true);
            }
        }
    }

    private QuickMenuSession showDockQuickMenu(View anchor, int tabIdx) {
        dismissQuickMenu(false);
        if (shellRoot == null) return null;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final List<DockQuickAction> actions = quickActionsForTab(tabIdx);
        if (actions.isEmpty()) return null;

        final FrameLayout overlay = new FrameLayout(a);
        overlay.setTag("dock-quick-menu");
        overlay.setBackgroundColor(p.isDark ? 0x4A000000 : 0x26000000);
        overlay.setClickable(true);
        overlay.setOnClickListener(v -> dismissQuickMenu(true));

        final LinearLayout card = a.vertical();
        card.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
        card.setBackground(MobileTheme.dockFrostBg(a, 18f));
        UiCompat.setElevation(card, a.dp(14f));
        card.setClickable(true);

        final List<LinearLayout> rowViews = new ArrayList<>();
        final List<MobileIcons.IconView> rowIcons = new ArrayList<>();
        final List<TextView> rowLabels = new ArrayList<>();
        int menuW = a.dp(178);

        for (int i = 0; i < actions.size(); i++) {
            final DockQuickAction act = actions.get(i);
            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(12), a.dp(11), a.dp(14), a.dp(11));

            int iconId = act.iconId;
            String label = act.label;
            if ("toggle_theme".equals(act.id)) {
                iconId = p.isDark ? MobileIcons.IC_SUN : MobileIcons.IC_MOON;
                label = p.isDark ? "切换浅色日间" : "切换深色夜间";
            } else if ("privacy_space".equals(act.id) && a.privateMode) {
                label = "退出隐私空间";
            }
            MobileIcons.IconView ic = MobileIcons.create(a, iconId, 16.5f, p.textSecondary);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(a.dp(16.5f), a.dp(16.5f));
            ilp.rightMargin = a.dp(10);
            row.addView(ic, ilp);

            TextView tv = a.text(label, 14f, p.textPrimary);
            tv.setSingleLine(true);
            row.addView(tv, new LinearLayout.LayoutParams(0, -2, 1f));

            MobileMotion.bindPress(row, 0.96f);
            row.setOnClickListener(
                    v -> {
                        dismissQuickMenu(false);
                        executeDockQuickAction(act.id);
                    });
            card.addView(row, new LinearLayout.LayoutParams(menuW, -2));
            rowViews.add(row);
            rowIcons.add(ic);
            rowLabels.add(tv);
        }

        // Compute anchored position right above (or beside, on side rail) the pressed Dock button
        int[] rootLoc = new int[2];
        int[] ancLoc = new int[2];
        shellRoot.getLocationOnScreen(rootLoc);
        anchor.getLocationOnScreen(ancLoc);
        int rootW = Math.max(a.dp(300), shellRoot.getWidth());
        int rootH = Math.max(a.dp(480), shellRoot.getHeight());
        int ancCenterX = ancLoc[0] - rootLoc[0] + anchor.getWidth() / 2;
        int ancTopY = ancLoc[1] - rootLoc[1];

        FrameLayout.LayoutParams clp;
        if (isSideRailLayout) {
            clp = new FrameLayout.LayoutParams(-2, -2, Gravity.LEFT | Gravity.TOP);
            clp.leftMargin =
                    Math.min(
                            rootW - menuW - a.dp(16),
                            ancLoc[0] - rootLoc[0] + anchor.getWidth() + a.dp(12));
            clp.topMargin =
                    Math.max(a.statusBarHeight() + a.dp(16), Math.min(rootH - a.dp(240), ancTopY));
        } else {
            clp = new FrameLayout.LayoutParams(-2, -2, Gravity.LEFT | Gravity.BOTTOM);
            int left = ancCenterX - (menuW + a.dp(12)) / 2;
            left = Math.max(a.dp(14), Math.min(rootW - menuW - a.dp(26), left));
            clp.leftMargin = left;
            clp.bottomMargin =
                    Math.max(a.navigationBarHeight() + a.dp(82), rootH - ancTopY + a.dp(12));
        }
        overlay.addView(card, clp);
        shellRoot.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
        activeQuickMenuOverlay = overlay;

        if (!MobileMotion.isReduced(a)) {
            overlay.setAlpha(0f);
            overlay.animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.DURATION_MICRO_MS)
                    .setInterpolator(MotionTokens.createDecelerateInterpolator())
                    .start();
            card.setAlpha(0f);
            card.setScaleX(0.86f);
            card.setScaleY(0.86f);
            card.setTranslationY(a.dp(14));
            card.animate()
                    .alpha(1f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .translationY(0f)
                    .setDuration(MotionTokens.DURATION_FAST_MS)
                    .setInterpolator(MotionTokens.createStandardInterpolator())
                    .start();
        }
        return new QuickMenuSession(overlay, card, actions, rowViews, rowIcons, rowLabels);
    }

    private boolean dismissQuickMenu(boolean animate) {
        final FrameLayout overlay = activeQuickMenuOverlay;
        if (overlay == null) return false;
        activeQuickMenuOverlay = null;
        if (!animate || MobileMotion.isReduced(a) || !UiCompat.isAttached(overlay)) {
            if (overlay.getParent() instanceof ViewGroup) {
                ((ViewGroup) overlay.getParent()).removeView(overlay);
            }
            return true;
        }
        overlay.setClickable(false);
        overlay.animate()
                .alpha(0f)
                .setDuration(110)
                .setInterpolator(MotionTokens.createAccelerateInterpolator())
                .withEndAction(
                        () -> {
                            if (overlay.getParent() instanceof ViewGroup) {
                                ((ViewGroup) overlay.getParent()).removeView(overlay);
                            }
                        })
                .start();
        return true;
    }

    private void executeDockQuickAction(String actionId) {
        if (actionId == null) return;
        switch (actionId) {
            case "switch_source":
                showQuickSourceAndModeSheet();
                break;
            case "import_source":
                UiWidgets.showMobileImportDialog(a);
                break;
            case "manage_sources":
                settingsSubPage = MobileSettingsIndex.SUB_SOURCES;
                switchTab(TAB_SETTINGS);
                break;
            case "scroll_top":
                if (activeTab != TAB_HOME) {
                    switchTab(TAB_HOME);
                } else {
                    ScrollView sv = findFirstScrollView(contentContainer);
                    if (sv != null && sv.getScrollY() > a.dp(12)) {
                        sv.smoothScrollTo(0, 0);
                    } else {
                        switchTab(TAB_HOME);
                    }
                }
                break;
            case "import_live":
                SourceController.showLiveImportDialog(a);
                break;
            case "live_epg":
                SourceController.showEpgDialog(a);
                break;
            case "refresh_live":
                switchTab(TAB_LIVE);
                break;
            case "lib_history":
                librarySubTab = 0;
                switchTab(TAB_LIBRARY);
                break;
            case "lib_favorites":
                librarySubTab = 1;
                switchTab(TAB_LIBRARY);
                break;
            case "lib_downloads":
                librarySubTab = 3;
                switchTab(TAB_LIBRARY);
                break;
            case "lib_sync":
                CloudSyncDialog.show(a, () -> switchTab(activeTab));
                break;
            case "toggle_theme":
                boolean currentlyDark = MobileTheme.isDark(a);
                int nextMode = currentlyDark ? MobileTheme.MODE_LIGHT : MobileTheme.MODE_DARK;
                a.mobilePrefs().edit().putInt(Prefs.THEME_MODE, nextMode).apply();
                a.applyMobileThemeNow();
                break;
            case "settings_playback":
                settingsSubPage = MobileSettingsIndex.SUB_PLAYBACK;
                switchTab(TAB_SETTINGS);
                break;
            case "privacy_space":
                PrivacySpace.openOrExit(a);
                break;
            case "replay_onboarding":
                OnboardingScreen.resetForReplay(a);
                a.showOnboarding(true);
                break;
            case "clipboard_search":
                try {
                    android.content.ClipboardManager cm =
                            (android.content.ClipboardManager)
                                    a.getSystemService(android.content.Context.CLIPBOARD_SERVICE);
                    if (cm != null
                            && cm.hasPrimaryClip()
                            && cm.getPrimaryClip() != null
                            && cm.getPrimaryClip().getItemCount() > 0
                            && cm.getPrimaryClip().getItemAt(0).getText() != null) {
                        String q = cm.getPrimaryClip().getItemAt(0).getText().toString().trim();
                        if (!q.isEmpty()) {
                            openSearch(a, q);
                            break;
                        }
                    }
                } catch (Throwable ignored) {
                }
                a.toast("剪贴板为空");
                break;
            case "clipboard_import":
                UiWidgets.pasteConfigFromClipboard(a);
                break;
            case "fresh_search":
                pendingSearchKeyword = "";
                switchTab(TAB_SEARCH);
                break;
            default:
                break;
        }
    }

    private static ScrollView findFirstScrollView(View root) {
        if (root instanceof ScrollView) return (ScrollView) root;
        if (root instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) root;
            for (int i = 0; i < vg.getChildCount(); i++) {
                ScrollView hit = findFirstScrollView(vg.getChildAt(i));
                if (hit != null) return hit;
            }
        }
        return null;
    }

    void showQuickSourceAndModeSheet() {
        final List<String> labels = new ArrayList<>();
        final List<Runnable> actions = new ArrayList<>();
        int selectedIdx = 0;

        if (a.config != null && !a.config.sites.isEmpty()) {
            for (final Cms.Site s : a.config.sites) {
                if (!a.available(s)) continue;
                boolean isCur = activeSite != null && s.key.equals(activeSite.key);
                if (isCur) selectedIdx = labels.size();
                labels.add("片源 · " + s.name);
                actions.add(
                        () -> {
                            a.prefs
                                    .edit()
                                    .putString(Prefs.SELECTED_SITE, s.key)
                                    .putString(Prefs.RECOVERED_SKIP_SITE, "")
                                    .apply();
                            activeSite = s;
                            switchTab(TAB_HOME);
                        });
            }
            if (a.config.depots != null && a.config.depots.length() > 1) {
                labels.add("切换多仓仓库 (" + a.config.depots.length() + " 个子仓)");
                actions.add(() -> SourcePicker.showWarehouses(a));
            }
        }
        labels.add("导入或更新配置源");
        actions.add(() -> UiWidgets.showMobileImportDialog(a));

        UiWidgets.showDrawerPicker(
                a,
                "快速切换首页与片源",
                "按住底栏「发现」图标上滑可随时呼出此面板",
                labels.toArray(new String[0]),
                selectedIdx,
                idx -> {
                    if (idx >= 0 && idx < actions.size()) actions.get(idx).run();
                });
    }

    private void performTabHaptic(View v) {
        if (v == null) return;
        try {
            // 26 == HapticFeedbackConstants.SEGMENT_TICK on Android 14+ (API 34+)
            int code = Build.VERSION.SDK_INT >= 34 ? 26 : HapticFeedbackConstants.CLOCK_TICK;
            v.performHapticFeedback(code);
        } catch (Throwable ignored) {
        }
    }

    void switchTab(int index) {
        dismissQuickMenu(false);
        if (activeTab == TAB_SEARCH && index != TAB_SEARCH) {
            MobileSearchPage.onPageExit();
        }
        if (activeTab == TAB_SETTINGS && index != TAB_SETTINGS) {
            a.pendingSettingsScrollY = -1;
        }
        int prevTab = lastRenderedTab;
        activeTab = index;
        lastRenderedTab = index;
        MobileShell.syncFromRootTab(index);
        expandDock();
        a.cancelPageRequests();

        MobileTheme.Palette p = MobileTheme.of(a);
        boolean switched = prevTab >= 0 && prevTab != index;

        if (activeNavTrack != null) {
            activeNavTrack.setActiveIndex(index, switched);
        }
        if (switched) {
            performTabHaptic(activeNavTrack != null ? activeNavTrack : shellRoot);
        }

        for (int i = 0; i < 5; i++) {
            boolean sel = (i == index);
            if (tabIconViews[i] != null) {
                tabIconViews[i].setTint(sel ? p.accent : p.textSecondary);
                tabIconViews[i].setFilled(sel);
                if (sel && switched) {
                    MobileMotion.popBounce(tabIconViews[i]);
                }
            }
            if (tabLabelViews[i] != null) {
                tabLabelViews[i].setTextColor(sel ? p.accent : p.textSecondary);
                tabLabelViews[i].setTypeface(null, sel ? Typeface.BOLD : Typeface.NORMAL);
            }
        }

        if (collapsedPillIcon != null && collapsedPillLabel != null) {
            int safeIdx = index >= 0 && index < TAB_ICON_IDS.length ? index : TAB_HOME;
            collapsedPillIcon.setIcon(TAB_ICON_IDS[safeIdx]);
            collapsedPillIcon.setTint(p.accent);
            collapsedPillIcon.setFilled(true);
            collapsedPillLabel.setText(TAB_NAMES[safeIdx]);
        }

        // Material 3 Expressive detached Search FAB shape morph: 28dp circle -> 18dp rounded
        // squircle when active
        if (searchBubble instanceof FrameLayout) {
            FrameLayout sb = (FrameLayout) searchBubble;
            boolean sSel = (index == TAB_SEARCH);
            sb.setBackground(
                    sSel ? MobileTheme.accentPillBg(a, 18f) : MobileTheme.dockFrostBg(a, 28f));
            if (searchBubbleIcon != null) {
                searchBubbleIcon.setTint(sSel ? p.accentOnFill : p.textPrimary);
            }
            if (sSel && switched) {
                MobileMotion.popBounce(sb);
            }
        }
        if (collapsedSearchBubble instanceof FrameLayout) {
            FrameLayout csb = (FrameLayout) collapsedSearchBubble;
            boolean sSel = (index == TAB_SEARCH);
            csb.setBackground(
                    sSel ? MobileTheme.accentPillBg(a, 15f) : MobileTheme.dockFrostBg(a, 23f));
            if (collapsedSearchIcon != null) {
                collapsedSearchIcon.setTint(sSel ? p.accentOnFill : p.textPrimary);
            }
        }

        if (contentContainer == null) return;
        setStatusBarVeilAlpha(1f);
        a.applyMobileSystemBars(false, false);
        contentContainer.removeAllViews();
        resolveActiveSite();

        switch (index) {
            case TAB_LIVE:
                MobileLivePage.render(this, contentContainer);
                break;
            case TAB_LIBRARY:
                MobileLibraryPage.render(this, contentContainer);
                break;
            case TAB_SETTINGS:
                MobileSettingsScreen.render(this, contentContainer);
                break;
            case TAB_SEARCH:
                MobileSearchPage.render(this, contentContainer);
                break;
            case TAB_HOME:
            default:
                MobileHomePage.render(this, contentContainer);
                break;
        }

        if (switched && contentContainer.getChildCount() > 0) {
            View nextPage = contentContainer.getChildAt(contentContainer.getChildCount() - 1);
            int dir = index > prevTab ? 1 : -1;
            MobileMotion.animatePageSwap(nextPage, dir, 10f);
        }
    }

    /**
     * Android 16 / Material 3 Expressive icon-hugging active-tab indicator track driven by
     * asymmetric leading/trailing {@link MotionSpring} physics for silky elastic liquid travel
     * between tabs without oversized beach-ball circles.
     */
    static final class SpringNavTrackView extends LinearLayout {
        private static final float LEAD_SPRING_FREQ = 25.5f;
        private static final float TRAIL_SPRING_FREQ = 17.5f;

        private final MainActivity a;
        private final boolean vertical;
        private final Paint pillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF pillRect = new RectF();
        private final int baseFillColor;
        private MotionSpring startSpring;
        private MotionSpring endSpring;
        private final MotionSpring alphaSpring;
        private MotionLoop.Step springStep;
        private int activeIndex = -1;
        private boolean laidOut;

        SpringNavTrackView(MainActivity activity, boolean vertical, int fillColor) {
            super(activity);
            this.a = activity;
            this.vertical = vertical;
            this.baseFillColor = fillColor;
            setOrientation(vertical ? VERTICAL : HORIZONTAL);
            setWillNotDraw(false);
            pillPaint.setStyle(Paint.Style.FILL);
            pillPaint.setColor(fillColor);
            float baseFreq = MotionTokens.SPRING_HUD_POPUP.motionSpringFrequency;
            this.startSpring = new MotionSpring(0f, baseFreq, 0.4f);
            this.endSpring = new MotionSpring(0f, baseFreq, 0.4f);
            this.alphaSpring = new MotionSpring(0f, baseFreq, 0.01f);
        }

        void setActiveIndex(int index, boolean animate) {
            this.activeIndex = index;
            if (!laidOut) {
                invalidate();
                return;
            }
            updateTargets(animate && !MobileMotion.isReduced(a));
        }

        private float[] computeIndicatorSpan(View child) {
            if (vertical) {
                float top = child.getTop() + child.getPaddingTop();
                float h = a.dp(30);
                return new float[] {top, top + h};
            }
            float centerX = (child.getLeft() + child.getRight()) * 0.5f;
            float maxW = Math.max(a.dp(36), child.getWidth() - a.dp(10));
            float pillW = Math.min(a.dp(52), maxW);
            return new float[] {centerX - pillW * 0.5f, centerX + pillW * 0.5f};
        }

        private void updateTargets(boolean animate) {
            boolean inBounds = activeIndex >= 0 && activeIndex < getChildCount();
            if (!inBounds) {
                if (animate) {
                    alphaSpring.target(0f);
                    startSpringLoop();
                } else {
                    stopSpringLoop();
                    alphaSpring.snap(0f);
                    invalidate();
                }
                return;
            }
            View child = getChildAt(activeIndex);
            float[] span = computeIndicatorSpan(child);
            float targetStart = span[0];
            float targetEnd = span[1];
            boolean wasHidden = alphaSpring.value <= 0.05f;
            if (!animate || wasHidden) {
                startSpring.snap(targetStart);
                endSpring.snap(targetEnd);
                if (animate) {
                    alphaSpring.target(1f);
                    startSpringLoop();
                } else {
                    stopSpringLoop();
                    alphaSpring.snap(1f);
                    invalidate();
                }
                return;
            }
            // Asymmetric lead/trail spring frequencies create a subtle M3 Expressive elastic
            // stretch in the direction of motion while keeping zero positional discontinuity.
            boolean movingForward = targetStart >= startSpring.value;
            float startFreq = movingForward ? TRAIL_SPRING_FREQ : LEAD_SPRING_FREQ;
            float endFreq = movingForward ? LEAD_SPRING_FREQ : TRAIL_SPRING_FREQ;
            float curStart = startSpring.value;
            float curStartVel = startSpring.velocity;
            float curEnd = endSpring.value;
            float curEndVel = endSpring.velocity;
            startSpring = new MotionSpring(curStart, startFreq, 0.4f);
            startSpring.velocity = curStartVel;
            startSpring.target(targetStart);
            endSpring = new MotionSpring(curEnd, endFreq, 0.4f);
            endSpring.velocity = curEndVel;
            endSpring.target(targetEnd);
            alphaSpring.target(1f);
            startSpringLoop();
        }

        private void startSpringLoop() {
            if (springStep == null) {
                springStep =
                        dt -> {
                            if (!UiCompat.isAttached(this)) {
                                springStep = null;
                                return false;
                            }
                            boolean m1 = startSpring.step(dt);
                            boolean m2 = endSpring.step(dt);
                            boolean m3 = alphaSpring.step(dt);
                            invalidate();
                            boolean moving = m1 || m2 || m3;
                            if (!moving) springStep = null;
                            return moving;
                        };
            }
            MotionLoop.add(springStep);
        }

        private void stopSpringLoop() {
            if (springStep != null) {
                MotionLoop.remove(springStep);
                springStep = null;
            }
        }

        @Override
        protected void onLayout(boolean changed, int l, int t, int r, int b) {
            super.onLayout(changed, l, t, r, b);
            boolean first = !laidOut;
            laidOut = true;
            if (first || changed) {
                updateTargets(false);
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float aFrac = Math.max(0f, Math.min(1f, alphaSpring.value));
            if (aFrac <= 0.01f || endSpring.value <= startSpring.value) return;
            int origAlpha = (baseFillColor >>> 24) & 0xFF;
            pillPaint.setColor(MobileTheme.withAlpha(baseFillColor, Math.round(origAlpha * aFrac)));
            if (vertical) {
                float cx = getWidth() * 0.5f;
                float halfW =
                        Math.min(
                                a.dp(24),
                                (getWidth() - getPaddingLeft() - getPaddingRight()) * 0.5f);
                pillRect.set(cx - halfW, startSpring.value, cx + halfW, endSpring.value);
            } else {
                float iconTop = getPaddingTop() + a.dp(3.5f);
                float iconBottom = iconTop + a.dp(30);
                if (getChildCount() > 0 && getChildAt(0) instanceof ViewGroup) {
                    ViewGroup firstCell = (ViewGroup) getChildAt(0);
                    if (firstCell.getChildCount() > 0) {
                        View iconSlot = firstCell.getChildAt(0);
                        if (iconSlot.getHeight() > 0) {
                            iconTop = firstCell.getTop() + iconSlot.getTop();
                            iconBottom = firstCell.getTop() + iconSlot.getBottom();
                        }
                    }
                }
                pillRect.set(startSpring.value, iconTop, endSpring.value, iconBottom);
            }
            float r = Math.min(pillRect.width(), pillRect.height()) * 0.5f;
            canvas.drawRoundRect(pillRect, r, r, pillPaint);
        }

        @Override
        protected void onDetachedFromWindow() {
            stopSpringLoop();
            super.onDetachedFromWindow();
        }
    }

    /**
     * Day/Night ambient background canvas supporting custom wallpaper + dim veil or soft dynamic
     * cover tint glow (delicate pastel morning mist in Daylight Alabaster, deep ambient glow in
     * Cinema Obsidian).
     */
    static final class AmbientCanvasView extends View {
        private final MainActivity a;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int dynamicTint;
        private Bitmap wallpaper;
        private boolean wallpaperChecked;

        AmbientCanvasView(MainActivity activity) {
            super(activity);
            this.a = activity;
            this.dynamicTint = MobileTheme.of(activity).accent;
        }

        void setDynamicTint(int color) {
            if (this.dynamicTint != color) {
                this.dynamicTint = color;
                invalidate();
            }
        }

        private void ensureWallpaper() {
            if (wallpaperChecked) return;
            wallpaperChecked = true;
            if (!a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false)) return;
            File f = new File(a.getFilesDir(), "wallpaper.jpg");
            if (f.exists()) {
                try {
                    wallpaper = BitmapFactory.decodeFile(f.getAbsolutePath());
                } catch (Throwable ignored) {
                }
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            MobileTheme.Palette p = MobileTheme.of(a);
            ensureWallpaper();
            if (wallpaper != null && !wallpaper.isRecycled()) {
                RectF dst = new RectF(0, 0, w, h);
                canvas.drawBitmap(wallpaper, null, dst, paint);
                int dim = Prefs.clampWallpaperDim(a.prefs.getInt(Prefs.WALLPAPER_DIM, 65));
                int alpha = Math.round(255 * (dim / 100f));
                int veilBase = p.isDark ? 0x0A0B0E : 0xF3F5F9;
                canvas.drawColor(MobileTheme.withAlpha(veilBase, alpha));
                return;
            }

            canvas.drawColor(p.bgCanvas);

            if (a.mobilePrefs().getBoolean(Prefs.COVER_AMBIENT, true)) {
                int glowAlpha = p.isDark ? 0x34 : 0x1A;
                int glow = MobileTheme.withAlpha(dynamicTint, glowAlpha);
                paint.setShader(
                        new RadialGradient(
                                w * 0.5f,
                                h * 0.08f,
                                Math.max(w, h) * 0.65f,
                                new int[] {glow, Color.TRANSPARENT},
                                null,
                                Shader.TileMode.CLAMP));
                canvas.drawRect(0, 0, w, h, paint);
                paint.setShader(null);
            }
        }
    }
}

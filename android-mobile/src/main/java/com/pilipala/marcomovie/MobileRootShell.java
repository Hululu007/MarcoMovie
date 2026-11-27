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

    static final int DOCK_POS_AUTO = 0;
    static final int DOCK_POS_BOTTOM = 1;
    static final int DOCK_POS_TOP = 2;
    static final int DOCK_POS_LEFT = 3;
    static final int DOCK_POS_RIGHT = 4;

    private static final String FEATURE_HINGE_ANGLE = "android.hardware.sensor.hinge_angle";

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
    private static int pendingRelayoutTab = -1;
    private static int pendingRelayoutScrollY = -1;

    static void recordRelayoutScrollState(int tab, int scrollY) {
        pendingRelayoutTab = tab;
        pendingRelayoutScrollY = Math.max(0, scrollY);
    }

    static int peekPendingRelayoutTab() {
        return pendingRelayoutTab;
    }

    static int consumeRelayoutScrollForTab(int tab) {
        if (pendingRelayoutTab != tab) return -1;
        int y = pendingRelayoutScrollY;
        pendingRelayoutTab = -1;
        pendingRelayoutScrollY = -1;
        return y;
    }

    static void clearPendingRelayoutScrollState() {
        pendingRelayoutTab = -1;
        pendingRelayoutScrollY = -1;
    }

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
    int activeDockPosition = DOCK_POS_BOTTOM;
    private int renderedDockPref = DOCK_POS_AUTO;
    private FrameLayout sideRailWrap;
    private int lastRenderedTab = -1;
    private int lastInsetTop;
    private int lastInsetBottom;
    private int lastInsetLeft;
    private int lastInsetRight;

    /**
     * Pure-JVM check determining whether a layout change requires rebuilding the shell and Hero
     * carousel (handles orientation switches, Dock-edge changes, AND same-orientation foldable
     * fold/unfold or split-screen width changes).
     */
    static boolean shouldRelayoutForResize(
            boolean prevPortrait,
            int prevWidthPx,
            int prevDockPos,
            int nextW,
            int nextH,
            int nextDockPos,
            int widthThresholdPx) {
        if (nextW <= 0 || nextH <= 0) return false;
        boolean orientChanged = (nextW < nextH) != prevPortrait;
        boolean dockChanged = nextDockPos != prevDockPos;
        boolean widthChanged =
                prevWidthPx > 0 && Math.abs(nextW - prevWidthPx) >= Math.max(1, widthThresholdPx);
        return orientChanged || dockChanged || widthChanged;
    }

    /** Pure-JVM viewport-clamped box &amp; scrollability plan for the Dock quick-action menu. */
    static final class QuickMenuLayout {
        final int left;
        final int top;
        final int width;
        final int height;
        final boolean scrollable;

        QuickMenuLayout(int left, int top, int width, int height, boolean scrollable) {
            this.left = left;
            this.top = top;
            this.width = width;
            this.height = height;
            this.scrollable = scrollable;
        }
    }

    static QuickMenuLayout computeQuickMenuLayout(
            int dockPos,
            int rootW,
            int rootH,
            int insetL,
            int insetT,
            int insetR,
            int insetB,
            int ancLeft,
            int ancTop,
            int ancW,
            int ancH,
            int contentW,
            int contentH,
            int padPx,
            int gapPx) {
        int safePad = Math.max(0, padPx);
        int maxW = Math.max(1, rootW - Math.max(0, insetL) - Math.max(0, insetR) - safePad * 2);
        int maxH = Math.max(1, rootH - Math.max(0, insetT) - Math.max(0, insetB) - safePad * 2);
        int menuW = Math.min(maxW, Math.max(1, contentW));
        boolean scrollable = contentH > maxH;
        int menuH = scrollable ? maxH : Math.max(1, contentH);
        int[] origin =
                computeQuickMenuOrigin(
                        dockPos, rootW, rootH, insetL, insetT, insetR, insetB, ancLeft, ancTop,
                        ancW, ancH, menuW, menuH, safePad, gapPx);
        return new QuickMenuLayout(origin[0], origin[1], menuW, menuH, scrollable);
    }

    /**
     * Pure-JVM viewport-clamped anchor math for the Dock quick-action menu across all four Dock
     * edges (Top / Bottom / Left / Right), guaranteed to stay strictly within real viewport bounds
     * and system insets regardless of menu height or split-screen compactness.
     */
    static int[] computeQuickMenuOrigin(
            int dockPos,
            int rootW,
            int rootH,
            int insetL,
            int insetT,
            int insetR,
            int insetB,
            int ancLeft,
            int ancTop,
            int ancW,
            int ancH,
            int menuW,
            int menuH,
            int padPx,
            int gapPx) {
        int minLeft = Math.max(0, insetL) + Math.max(0, padPx);
        int maxLeft = Math.max(minLeft, rootW - Math.max(0, insetR) - menuW - Math.max(0, padPx));
        int minTop = Math.max(0, insetT) + Math.max(0, padPx);
        int maxTop = Math.max(minTop, rootH - Math.max(0, insetB) - menuH - Math.max(0, padPx));

        int rawLeft;
        int rawTop;
        if (dockPos == DOCK_POS_LEFT) {
            rawLeft = ancLeft + ancW + gapPx;
            rawTop = ancTop;
        } else if (dockPos == DOCK_POS_RIGHT) {
            rawLeft = ancLeft - menuW - gapPx;
            rawTop = ancTop;
        } else if (dockPos == DOCK_POS_TOP) {
            rawLeft = (ancLeft + ancW / 2) - menuW / 2;
            rawTop = ancTop + ancH + gapPx;
        } else {
            rawLeft = (ancLeft + ancW / 2) - menuW / 2;
            rawTop = ancTop - menuH - gapPx;
        }
        int clampedLeft = Math.max(minLeft, Math.min(maxLeft, rawLeft));
        int clampedTop = Math.max(minTop, Math.min(maxTop, rawTop));
        return new int[] {clampedLeft, clampedTop};
    }

    /**
     * Pure-JVM large-screen tablet &amp; foldable detector.
     *
     * <p>Returns {@code true} for Android tablets, unfolded book-style foldables, and devices
     * advertising {@code android.hardware.sensor.hinge_angle} (even while folded on the outer
     * cover screen), while staying {@code false} for ordinary bar phones in both portrait and
     * landscape orientations.
     */
    static boolean isTabletOrFoldableDevice(
            int smallestScreenWidthDp,
            int screenLayoutSize,
            float windowWidthDp,
            float windowHeightDp,
            boolean hasHingeAngleFeature) {
        if (hasHingeAngleFeature) return true;
        if (smallestScreenWidthDp >= 580) return true;
        if (screenLayoutSize >= android.content.res.Configuration.SCREENLAYOUT_SIZE_LARGE) {
            return true;
        }
        return Math.min(windowWidthDp, windowHeightDp) >= 540f;
    }

    static boolean isTabletOrFoldable(MainActivity a) {
        if (a == null || a.isTvDevice()) return false;
        int swDp = 0;
        int layoutSize = 0;
        float density = 1f;
        try {
            android.content.res.Resources res = a.getResources();
            if (res != null) {
                if (res.getDisplayMetrics() != null && res.getDisplayMetrics().density > 0f) {
                    density = res.getDisplayMetrics().density;
                }
                android.content.res.Configuration cfg = res.getConfiguration();
                if (cfg != null) {
                    swDp = cfg.smallestScreenWidthDp;
                    layoutSize =
                            cfg.screenLayout
                                    & android.content.res.Configuration.SCREENLAYOUT_SIZE_MASK;
                }
            }
            android.content.res.Configuration sysCfg =
                    android.content.res.Resources.getSystem().getConfiguration();
            if (sysCfg != null) {
                swDp = Math.max(swDp, sysCfg.smallestScreenWidthDp);
                int sysSize =
                        sysCfg.screenLayout
                                & android.content.res.Configuration.SCREENLAYOUT_SIZE_MASK;
                layoutSize = Math.max(layoutSize, sysSize);
            }
        } catch (Throwable ignored) {
        }
        boolean hasHinge = false;
        try {
            if (a.getPackageManager() != null) {
                hasHinge = a.getPackageManager().hasSystemFeature(FEATURE_HINGE_ANGLE);
            }
        } catch (Throwable ignored) {
        }
        float winWDp = a.windowWidth() / density;
        float winHDp = a.windowHeight() / density;
        return isTabletOrFoldableDevice(swDp, layoutSize, winWDp, winHDp, hasHinge);
    }

    /**
     * Pure-JVM resolver turning the saved {@link Prefs#TABLET_DOCK_POSITION} preference into one of
     * the four concrete edges ({@link #DOCK_POS_TOP}, {@link #DOCK_POS_BOTTOM}, {@link
     * #DOCK_POS_LEFT}, {@link #DOCK_POS_RIGHT}).
     */
    static int resolveDockPosition(
            int savedPref, boolean isTabletOrFoldable, float windowWidthDp, boolean portrait) {
        if (isTabletOrFoldable) {
            if (savedPref == DOCK_POS_BOTTOM
                    || savedPref == DOCK_POS_TOP
                    || savedPref == DOCK_POS_LEFT
                    || savedPref == DOCK_POS_RIGHT) {
                return savedPref;
            }
        }
        return (windowWidthDp >= 640f && !portrait) ? DOCK_POS_LEFT : DOCK_POS_BOTTOM;
    }

    static String dockPositionLabel(int pref) {
        switch (pref) {
            case DOCK_POS_BOTTOM:
                return "底部";
            case DOCK_POS_TOP:
                return "顶部";
            case DOCK_POS_LEFT:
                return "左侧";
            case DOCK_POS_RIGHT:
                return "右侧";
            case DOCK_POS_AUTO:
            default:
                return "自动适配";
        }
    }

    private static int currentEffectiveDockPosition(MainActivity a) {
        float density =
                a.getResources() != null && a.getResources().getDisplayMetrics() != null
                        ? Math.max(1f, a.getResources().getDisplayMetrics().density)
                        : 1f;
        float widthDp = a.windowWidth() / density;
        int pref = a.mobilePrefs().getInt(Prefs.TABLET_DOCK_POSITION, DOCK_POS_AUTO);
        return resolveDockPosition(pref, isTabletOrFoldable(a), widthDp, a.isPortrait());
    }

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
    private int renderedHomeSectionsRev = -1;

    MobileRootShell(MainActivity activity) {
        this.a = activity;
    }

    static void resetStaticState() {
        activeTab = TAB_HOME;
        librarySubTab = 0;
        settingsSubPage = 0;
        settingsHighlightKey = "";
        pendingSearchKeyword = "";
        clearPendingRelayoutScrollState();
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
        if (a != null && a.mobileShell != null && a.mobileShell.contentContainer != null) {
            int curScroll = findFirstScrollY(a.mobileShell.contentContainer);
            if (curScroll > 0) {
                recordRelayoutScrollState(activeTab, curScroll);
                if (activeTab == TAB_SETTINGS && a.pendingSettingsScrollY < 0) {
                    a.pendingSettingsScrollY = curScroll;
                }
            }
        }
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
                || a.mobilePrefs().getInt(Prefs.TABLET_DOCK_POSITION, DOCK_POS_AUTO)
                        != renderedDockPref
                || currentEffectiveDockPosition(a) != activeDockPosition
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
        if (activeTab == TAB_HOME && renderedHomeSectionsRev != MobileHomeSections.revision()) {
            renderedHomeSectionsRev = MobileHomeSections.revision();
            switchTab(TAB_HOME);
            return true;
        }
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
        final int restoreY = consumeRelayoutScrollForTab(activeTab);
        if (restoreY > 0) {
            sv.post(
                    () -> {
                        if (UiCompat.isAttached(sv)) {
                            sv.scrollTo(0, restoreY);
                            handleScroll.run();
                        }
                    });
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
        boolean isTop = activeDockPosition == DOCK_POS_TOP;
        float sign = isTop ? -1f : 1f;
        if (dockCollapseFullHide) {
            if (collapsedDockLayer != null) {
                collapsedDockLayer.setAlpha(0f);
                collapsedDockLayer.setVisibility(View.INVISIBLE);
            }
            float alpha = 1f - p;
            expandedDockLayer.setAlpha(alpha);
            expandedDockLayer.setTranslationY(reduced ? 0f : sign * p * a.dp(96));
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
            expandedDockLayer.setTranslationY(sign * expT * a.dp(6));
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
                collapsedDockLayer.setTranslationY(sign * colT * a.dp(6));
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
        sideRailWrap = null;
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
        renderedDockPref = a.mobilePrefs().getInt(Prefs.TABLET_DOCK_POSITION, DOCK_POS_AUTO);
        activeDockPosition = currentEffectiveDockPosition(a);
        isSideRailLayout =
                activeDockPosition == DOCK_POS_LEFT || activeDockPosition == DOCK_POS_RIGHT;
        final boolean builtPortrait = renderedPortrait;
        final int builtDockPosition = activeDockPosition;
        final int[] builtWidthRef = {Math.max(0, a.windowWidth())};
        final int widthRelayoutThreshold = a.dp(48);
        shellRoot.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    int w = r - l, h = b - t;
                    if (w <= 0 || h <= 0 || a.root != shellRoot) return;
                    a.usableWidth = w;
                    a.usableHeight = h;
                    if (builtWidthRef[0] <= 0) {
                        builtWidthRef[0] = w;
                    }
                    int nextDockPos = currentEffectiveDockPosition(a);
                    if (shouldRelayoutForResize(
                            builtPortrait,
                            builtWidthRef[0],
                            builtDockPosition,
                            w,
                            h,
                            nextDockPos,
                            widthRelayoutThreshold)) {
                        builtWidthRef[0] = w;
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

        if (isSideRailLayout) {
            boolean rightRail = activeDockPosition == DOCK_POS_RIGHT;
            LinearLayout mainRow = a.row();
            mainRow.setGravity(Gravity.TOP);
            shellRoot.addView(mainRow, new FrameLayout.LayoutParams(-1, -1));

            FrameLayout railWrap = new FrameLayout(a);
            railWrap.setTag(rightRail ? "mobile-right-rail" : "mobile-left-rail");
            railWrap.setPadding(
                    a.dp(rightRail ? 6 : 12),
                    a.statusBarHeight() + a.dp(12),
                    a.dp(rightRail ? 12 : 6),
                    a.navigationBarHeight() + a.dp(12));

            // Wrap vertical side rail in a fill-viewport ScrollView so compact split-screen or
            // short landscape heights remain smoothly scrollable with zero clipped items.
            android.widget.ScrollView railScroll = new android.widget.ScrollView(a);
            railScroll.setTag("mobile-side-rail-scroll");
            railScroll.setFillViewport(true);
            railScroll.setVerticalScrollBarEnabled(false);
            railScroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
            FrameLayout railCenterHost = new FrameLayout(a);
            LinearLayout rail = buildVerticalSideRail(p);
            railCenterHost.addView(
                    rail, new FrameLayout.LayoutParams(a.dp(76), -2, Gravity.CENTER_VERTICAL));
            railScroll.addView(railCenterHost, new FrameLayout.LayoutParams(-2, -2));
            railWrap.addView(railScroll, new FrameLayout.LayoutParams(-2, -1));
            sideRailWrap = railWrap;

            contentContainer = new FrameLayout(a);
            if (rightRail) {
                mainRow.addView(contentContainer, new LinearLayout.LayoutParams(0, -1, 1f));
                mainRow.addView(railWrap, new LinearLayout.LayoutParams(-2, -1));
            } else {
                mainRow.addView(railWrap, new LinearLayout.LayoutParams(-2, -1));
                mainRow.addView(contentContainer, new LinearLayout.LayoutParams(0, -1, 1f));
            }
        } else {
            boolean topDock = activeDockPosition == DOCK_POS_TOP;
            contentContainer = new FrameLayout(a);
            FrameLayout.LayoutParams contentLp = new FrameLayout.LayoutParams(-1, -1);
            if (topDock) {
                // Reserve clean vertical headroom for the 64dp floating top Dock so every tab's
                // header starts neatly below the top capsule with zero overlap.
                contentLp.topMargin = a.dp(74);
            }
            shellRoot.addView(contentContainer, contentLp);

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

            floatingDockWrap = buildFloatingHorizontalDock(p, topDock);
            FrameLayout.LayoutParams dockLp =
                    new FrameLayout.LayoutParams(
                            -1, a.dp(64), topDock ? Gravity.TOP : Gravity.BOTTOM);
            if (topDock) {
                dockLp.topMargin = a.statusBarHeight() + a.dp(8);
            } else {
                dockLp.bottomMargin = a.navigationBarHeight() + a.dp(10);
            }
            shellRoot.addView(floatingDockWrap, dockLp);
        }

        // Live Android 15/16 WindowInsets listener keeps status-bar veil, horizontal dock
        // left/right cutouts, and side-rail opposite-edge content padding pixel-locked on all 4
        // edges.
        if (Build.VERSION.SDK_INT >= 23) {
            shellRoot.setOnApplyWindowInsetsListener(
                    (v, insets) -> {
                        if (insets != null) {
                            int topInset;
                            int bottomInset;
                            int leftInset;
                            int rightInset;
                            if (Build.VERSION.SDK_INT >= 30) {
                                android.graphics.Insets topBars =
                                        insets.getInsets(
                                                WindowInsets.Type.statusBars()
                                                        | WindowInsets.Type.displayCutout());
                                android.graphics.Insets navBars =
                                        insets.getInsets(WindowInsets.Type.navigationBars());
                                topInset = topBars.top;
                                bottomInset = navBars.bottom;
                                leftInset = Math.max(topBars.left, navBars.left);
                                rightInset = Math.max(topBars.right, navBars.right);
                            } else {
                                topInset = insets.getSystemWindowInsetTop();
                                bottomInset = insets.getSystemWindowInsetBottom();
                                leftInset = insets.getSystemWindowInsetLeft();
                                rightInset = insets.getSystemWindowInsetRight();
                            }
                            lastInsetTop = Math.max(0, topInset);
                            lastInsetBottom = Math.max(0, bottomInset);
                            lastInsetLeft = Math.max(0, leftInset);
                            lastInsetRight = Math.max(0, rightInset);
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
                                if (dlp != null) {
                                    boolean changed = false;
                                    if (activeDockPosition == DOCK_POS_TOP) {
                                        int clampedTop = Math.max(0, Math.min(a.dp(64), topInset));
                                        int targetTop = clampedTop + a.dp(8);
                                        if (dlp.topMargin != targetTop) {
                                            dlp.topMargin = targetTop;
                                            changed = true;
                                        }
                                    } else {
                                        int clampedBottom =
                                                Math.max(0, Math.min(a.dp(56), bottomInset));
                                        int targetBottom = clampedBottom + a.dp(10);
                                        if (dlp.bottomMargin != targetBottom) {
                                            dlp.bottomMargin = targetBottom;
                                            changed = true;
                                        }
                                    }
                                    if (dlp.leftMargin != lastInsetLeft
                                            || dlp.rightMargin != lastInsetRight) {
                                        dlp.leftMargin = lastInsetLeft;
                                        dlp.rightMargin = lastInsetRight;
                                        changed = true;
                                    }
                                    if (changed) {
                                        floatingDockWrap.setLayoutParams(dlp);
                                    }
                                }
                                if (contentContainer != null
                                        && (contentContainer.getPaddingLeft() != lastInsetLeft
                                                || contentContainer.getPaddingRight()
                                                        != lastInsetRight)) {
                                    contentContainer.setPadding(
                                            lastInsetLeft, 0, lastInsetRight, 0);
                                }
                            }
                            if (sideRailWrap != null) {
                                boolean rightRail = activeDockPosition == DOCK_POS_RIGHT;
                                int padL = rightRail ? a.dp(6) : (lastInsetLeft + a.dp(12));
                                int padR = rightRail ? (lastInsetRight + a.dp(12)) : a.dp(6);
                                int padT = Math.max(a.statusBarHeight(), lastInsetTop) + a.dp(12);
                                int padB =
                                        Math.max(a.navigationBarHeight(), lastInsetBottom)
                                                + a.dp(12);
                                if (sideRailWrap.getPaddingLeft() != padL
                                        || sideRailWrap.getPaddingRight() != padR
                                        || sideRailWrap.getPaddingTop() != padT
                                        || sideRailWrap.getPaddingBottom() != padB) {
                                    sideRailWrap.setPadding(padL, padT, padR, padB);
                                }
                                // Apply opposite-side inset to contentContainer so right cutout/nav
                                // bar is respected with Left rail and left cutout/nav bar with
                                // Right rail.
                                if (contentContainer != null) {
                                    int cPadL = rightRail ? lastInsetLeft : 0;
                                    int cPadR = rightRail ? 0 : lastInsetRight;
                                    if (contentContainer.getPaddingLeft() != cPadL
                                            || contentContainer.getPaddingRight() != cPadR) {
                                        contentContainer.setPadding(cPadL, 0, cPadR, 0);
                                    }
                                }
                            }
                        }
                        return insets;
                    });
        }

        switchTab(activeTab);
    }

    private FrameLayout buildFloatingHorizontalDock(MobileTheme.Palette p, boolean isTopDock) {
        boolean unifiedFiveBar = a.mobilePrefs().getInt(Prefs.NAV_STYLE, 0) == 1;
        float dockElev = a.dp(p.isDark ? 10f : 6f);
        int availW = a.windowWidth();

        // Fixed-bounds stage (MATCH_PARENT x 64dp) ensures zero requestLayout() jitter while
        // scrolling in both collapsed and auto-hide dock modes.
        FrameLayout stage = new FrameLayout(a);
        stage.setClipChildren(false);
        stage.setClipToPadding(false);
        stage.setTag(isTopDock ? "mobile-top-dock" : "mobile-bottom-dock");

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
        expandChevron.setRotation(isTopDock ? 0f : 180f);
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
                    view.setTranslationX(0f);
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
                        // Compute inward pull away from whichever screen edge hosts the Dock
                        float inwardPull;
                        float crossAxis;
                        if (activeDockPosition == DOCK_POS_TOP) {
                            inwardPull = ev.getRawY() - downY[0];
                            crossAxis = Math.abs(dx);
                        } else if (activeDockPosition == DOCK_POS_LEFT) {
                            inwardPull = dx;
                            crossAxis = Math.abs(dy);
                        } else if (activeDockPosition == DOCK_POS_RIGHT) {
                            inwardPull = -dx;
                            crossAxis = Math.abs(dy);
                        } else {
                            inwardPull = dy;
                            crossAxis = Math.abs(dx);
                        }
                        if (!menuActive[0]) {
                            if (crossAxis > touchSlop * 1.4f && inwardPull < touchSlop) {
                                cancelHold.run();
                            }
                            if (inwardPull > 0f && !reduced) {
                                float rb = MobileMotion.rubberBand(inwardPull, maxPullPx);
                                if (activeDockPosition == DOCK_POS_TOP) {
                                    v.setTranslationY(rb);
                                } else if (activeDockPosition == DOCK_POS_LEFT) {
                                    v.setTranslationX(rb);
                                } else if (activeDockPosition == DOCK_POS_RIGHT) {
                                    v.setTranslationX(-rb);
                                } else {
                                    v.setTranslationY(-rb);
                                }
                            }
                            if (inwardPull >= pullTriggerPx) {
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
                            v.setTranslationX(0f);
                            v.setTranslationY(0f);
                            v.setScaleX(1f);
                            v.setScaleY(1f);
                        } else {
                            v.animate()
                                    .translationX(0f)
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

        final ScrollView menuScroll = new ScrollView(a);
        menuScroll.setTag("dock-quick-menu-scroll");
        menuScroll.setVerticalScrollBarEnabled(true);
        menuScroll.setOverScrollMode(View.OVER_SCROLL_IF_CONTENT_SCROLLS);
        final LinearLayout itemsBox = a.vertical();
        menuScroll.addView(itemsBox, new ScrollView.LayoutParams(-1, -2));
        card.addView(menuScroll, new LinearLayout.LayoutParams(-1, -2));

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
            itemsBox.addView(row, new LinearLayout.LayoutParams(menuW, -2));
            rowViews.add(row);
            rowIcons.add(ic);
            rowLabels.add(tv);
        }

        // Measure unconstrained natural item height so low-height split-screen clamps the outer
        // card height cleanly while menuScroll scrolls smoothly to the very last action row.
        int[] rootLoc = new int[2];
        int[] ancLoc = new int[2];
        shellRoot.getLocationOnScreen(rootLoc);
        anchor.getLocationOnScreen(ancLoc);
        int rootW = Math.max(1, shellRoot.getWidth());
        int rootH = Math.max(1, shellRoot.getHeight());
        int insetL = Math.max(0, lastInsetLeft);
        int insetR = Math.max(0, lastInsetRight);
        int insetT = Math.max(a.statusBarHeight(), lastInsetTop);
        int insetB = Math.max(a.navigationBarHeight(), lastInsetBottom);
        int pad = a.dp(12);
        int maxMenuW = Math.max(a.dp(120), rootW - insetL - insetR - pad * 2);
        itemsBox.measure(
                View.MeasureSpec.makeMeasureSpec(maxMenuW, View.MeasureSpec.AT_MOST),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int naturalContentW = Math.max(menuW, itemsBox.getMeasuredWidth()) + a.dp(12);
        int naturalContentH = Math.max(a.dp(48), itemsBox.getMeasuredHeight()) + a.dp(12);

        int ancLeftX = ancLoc[0] - rootLoc[0];
        int ancTopY = ancLoc[1] - rootLoc[1];
        QuickMenuLayout layout =
                computeQuickMenuLayout(
                        activeDockPosition,
                        rootW,
                        rootH,
                        insetL,
                        insetT,
                        insetR,
                        insetB,
                        ancLeftX,
                        ancTopY,
                        anchor.getWidth(),
                        anchor.getHeight(),
                        naturalContentW,
                        naturalContentH,
                        pad,
                        a.dp(12));

        FrameLayout.LayoutParams clp =
                new FrameLayout.LayoutParams(
                        layout.width,
                        layout.scrollable ? layout.height : -2,
                        Gravity.LEFT | Gravity.TOP);
        clp.leftMargin = layout.left;
        clp.topMargin = layout.top;
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
        final MobileTheme.Palette p = MobileTheme.of(a);
        final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];
        LinearLayout content = a.vertical();
        content.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(8));

        if (a.config != null && !a.config.sites.isEmpty()) {
            float density = Math.max(1f, a.getResources().getDisplayMetrics().density);
            float fontScale = a.getResources().getConfiguration().fontScale;
            float windowWidthDp = a.windowWidth() / density;
            float availWidthDp =
                    SourcePickerLayout.computeQuickSwitchContentWidthDp(
                            windowWidthDp, a.isPortrait());
            int cols = SourcePickerLayout.resolveQuickSwitchColumns(availWidthDp, fontScale);
            int gapPx = a.dp(8);

            LinearLayout grid = a.vertical();
            LinearLayout row = null;
            int colIdx = 0;
            for (final Cms.Site s : a.config.sites) {
                if (s == null) continue;
                final boolean avail = a.available(s);
                if (!avail) continue;
                if (row == null || colIdx == cols) {
                    row = a.row();
                    row.setBaselineAligned(false);
                    LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                    rlp.bottomMargin = gapPx;
                    grid.addView(row, rlp);
                    colIdx = 0;
                }
                final boolean isCur = activeSite != null && s.key.equals(activeSite.key);
                final boolean isPref = SourcePreferences.isPreferred(a, s);
                LinearLayout card =
                        SourcePickerLayout.buildMobileSourceCard(
                                a,
                                s,
                                isCur,
                                isPref,
                                true,
                                () -> {
                                    if (handleRef[0] != null) handleRef[0].dismiss();
                                    SourcePicker.commitSelectedSiteForCrashGuard(a, s.key);
                                    activeSite = s;
                                    switchTab(TAB_HOME);
                                },
                                () -> {
                                    a.prefs
                                            .edit()
                                            .putString(
                                                    Prefs.PREFERRED_SITE,
                                                    isPref ? "" : SourcePreferences.identity(s))
                                            .apply();
                                    a.toast(isPref ? "已取消常用片源" : "已设为常用片源");
                                    if (handleRef[0] != null) handleRef[0].dismiss();
                                    showQuickSourceAndModeSheet();
                                },
                                () -> {
                                    if (handleRef[0] != null) handleRef[0].dismiss();
                                    SourcePicker.showSiteActionMenu(a, a.config, s, null);
                                });
                LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0, -2, 1f);
                if (colIdx + 1 < cols) clp.rightMargin = gapPx;
                row.addView(card, clp);
                colIdx++;
            }
            if (row != null && colIdx > 0 && colIdx < cols) {
                for (int pad = colIdx; pad < cols; pad++) {
                    LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(0, 1, 1f);
                    if (pad + 1 < cols) plp.rightMargin = gapPx;
                    row.addView(new View(a), plp);
                }
            }
            content.addView(grid, new LinearLayout.LayoutParams(-1, -2));
        } else {
            TextView empty = a.text("尚未导入片源配置，可先导入订阅源或查看推荐榜单。", 13f, p.textSecondary);
            empty.setPadding(a.dp(4), a.dp(8), a.dp(4), a.dp(12));
            content.addView(empty);
        }

        LinearLayout footerRow = a.row();
        footerRow.setPadding(0, a.dp(6), 0, 0);
        if (a.config != null && !a.config.sites.isEmpty()) {
            TextView fullPickerBtn = a.text("完整片源管理", 12.5f, p.textPrimary);
            fullPickerBtn.setTypeface(null, Typeface.BOLD);
            fullPickerBtn.setGravity(Gravity.CENTER);
            fullPickerBtn.setBackground(MobileTheme.subtleBg(a, 999));
            MobileMotion.bindPress(fullPickerBtn, 0.95f);
            fullPickerBtn.setOnClickListener(
                    v -> {
                        if (handleRef[0] != null) handleRef[0].dismiss();
                        SourcePicker.show(a);
                    });
            LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
            flp.rightMargin = a.dp(8);
            footerRow.addView(fullPickerBtn, flp);
        }
        if (a.config != null && a.config.depots != null && a.config.depots.length() > 1) {
            TextView depotBtn =
                    a.text("切换多仓 (" + a.config.depots.length() + ")", 12.5f, p.textPrimary);
            depotBtn.setTypeface(null, Typeface.BOLD);
            depotBtn.setGravity(Gravity.CENTER);
            depotBtn.setBackground(MobileTheme.subtleBg(a, 999));
            MobileMotion.bindPress(depotBtn, 0.95f);
            depotBtn.setOnClickListener(
                    v -> {
                        if (handleRef[0] != null) handleRef[0].dismiss();
                        SourcePicker.showWarehouses(a);
                    });
            LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
            dlp.rightMargin = a.dp(8);
            footerRow.addView(depotBtn, dlp);
        }
        TextView importBtn = a.text("导入/更新配置", 12.5f, p.accentOnFill);
        importBtn.setTypeface(null, Typeface.BOLD);
        importBtn.setGravity(Gravity.CENTER);
        importBtn.setBackground(MobileTheme.accentPillBg(a, 999));
        MobileMotion.bindPress(importBtn, 0.95f);
        importBtn.setOnClickListener(
                v -> {
                    if (handleRef[0] != null) handleRef[0].dismiss();
                    UiWidgets.showMobileImportDialog(a);
                });
        footerRow.addView(importBtn, new LinearLayout.LayoutParams(0, a.dp(38), 1f));
        content.addView(footerRow, new LinearLayout.LayoutParams(-1, -2));

        handleRef[0] =
                MobileBottomSheet.showHandle(
                        a, "快速切换首页与片源", "点选切换 · 长按或点击右侧按钮可收藏/编辑/排序/删除", null, null, content, true);
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
        if (prevTab >= 0 && prevTab != index) {
            clearPendingRelayoutScrollState();
        }
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
                renderedHomeSectionsRev = MobileHomeSections.revision();
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

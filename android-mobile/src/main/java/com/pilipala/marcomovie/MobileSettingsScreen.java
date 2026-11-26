package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.app.Dialog;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Build;
import android.text.Editable;
import android.text.InputType;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.ViewParent;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Pure Android Mobile & Tablet Settings Center ({@code MobileSettingsScreen}):
 *
 * <ul>
 *   <li>Clean iOS / BieCuiLe Inset Grouped Section architecture via {@link MobileSectionGroup}
 *       with full Day/Night {@link MobileTheme} tokens and pure {@link MobileIcons} vectors.
 *   <li>Non-disruptive live theme/accent switching preserving exact scroll position via {@link
 *       MainActivity#pendingSettingsScrollY}.
 *   <li>Progressive disclosure folding advanced/debug options into collapsible {@code 高级与调试选项}
 *       groups (auto-expanded when non-default or targeted via {@link MobileSettingsIndex} search).
 *   <li>Destructive action safety via {@link MobileBottomSheet#showConfirm} and fluid push/pop
 *       sub-page motion via {@link MobileMotion} &amp; {@link MotionTokens}.
 * </ul>
 */
final class MobileSettingsScreen {
    private static final int TINT_BLUE = 0xFF007AFF;
    private static final int TINT_GREEN = 0xFF10B981;
    private static final int TINT_VIOLET = 0xFF8B5CF6;
    private static final int TINT_AMBER = 0xFFF59E0B;
    private static final int TINT_ROSE = 0xFFFF2D55;
    private static final int TINT_TEAL = 0xFF14B8A6;
    private static final int TINT_SLATE = 0xFF64748B;
    private static final int TINT_CORAL = 0xFFF97316;

    private static int lastRenderedSubPage = 0;
    private static final Set<Integer> EXPANDED_ADVANCED = new HashSet<>();

    private MobileSettingsScreen() {}

    /** Pure-JVM directional push/pop resolver for settings root <-> sub-page navigation. */
    static int computeTransitionDirection(int prevSubPage, int nextSubPage) {
        if (prevSubPage == nextSubPage) return 0;
        if (prevSubPage == 0) return 2;
        if (nextSubPage == 0) return -2;
        return nextSubPage > prevSubPage ? 2 : -2;
    }

    /** Pure-JVM progressive-disclosure helper for collapsible advanced/debug groups. */
    static boolean shouldAutoExpandAdvanced(
            boolean userExpanded, boolean hasNonDefault, String highlightKey, String... keys) {
        if (userExpanded || hasNonDefault) return true;
        if (highlightKey != null && !highlightKey.isEmpty() && keys != null) {
            for (String k : keys) {
                if (highlightKey.equals(k)) return true;
            }
        }
        return false;
    }

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setFillViewport(true);
        sv.setBackgroundColor(p.bgCanvas);
        shell.bindScrollBehavior(sv);

        final LinearLayout body = a.vertical();
        body.setPadding(
                a.dp(16),
                a.statusBarHeight() + a.dp(12),
                a.dp(16),
                a.navigationBarHeight() + a.dp(112));
        sv.addView(body, new ScrollView.LayoutParams(-1, -2));
        container.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        int curSub = MobileRootShell.settingsSubPage;
        int transitionDir = computeTransitionDirection(lastRenderedSubPage, curSub);
        lastRenderedSubPage = curSub;

        populate(shell, body, sv);

        if (transitionDir != 0) {
            MobileMotion.animatePageSwap(sv, transitionDir, 28f);
        }
    }

    private static void reloadPreservingScroll(MobileRootShell shell, ScrollView sv) {
        if (sv != null) {
            shell.a.pendingSettingsScrollY = sv.getScrollY();
        }
        shell.switchTab(MobileRootShell.TAB_SETTINGS);
    }

    private static void applyThemePreservingScroll(MainActivity a, ScrollView sv) {
        if (sv != null) {
            a.pendingSettingsScrollY = sv.getScrollY();
        }
        a.applyMobileThemeNow();
    }

    private static void openSubPage(MobileRootShell shell, int subPage, String highlightKey) {
        shell.a.pendingSettingsScrollY = -1;
        MobileRootShell.settingsSubPage = subPage;
        MobileRootShell.settingsHighlightKey = highlightKey == null ? "" : highlightKey;
        shell.switchTab(MobileRootShell.TAB_SETTINGS);
    }

    private static void populate(
            final MobileRootShell shell, final LinearLayout body, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        body.removeAllViews();
        int sub = MobileRootShell.settingsSubPage;

        if (sub == 0) {
            renderRootOverview(shell, body);
            restorePendingScrollIfNeeded(a, body, sv);
            return;
        }

        final String activeHighlightKey =
                MobileRootShell.settingsHighlightKey == null
                        ? ""
                        : MobileRootShell.settingsHighlightKey;

        // Sub-page top bar with vector back button & spring press feedback
        String[] subTitles = {
            "", "片源与直播", "外观与导航", "播放与触控手势", "字幕与弹幕", "网盘、追剧与 AI 助手", "云同步与隐私互联", "存储、备份与关于"
        };
        LinearLayout navRow = a.row();
        navRow.setGravity(Gravity.CENTER_VERTICAL);
        navRow.setPadding(0, 0, 0, a.dp(16));

        FrameLayout backBtn = new FrameLayout(a);
        backBtn.setBackground(MobileTheme.subtleBg(a, 999));
        MobileIcons.IconView backIcon =
                MobileIcons.create(a, MobileIcons.IC_BACK, 18f, p.textPrimary);
        backIcon.setStrokeWidthUnits(2.2f);
        backBtn.addView(backIcon, new FrameLayout.LayoutParams(a.dp(18), a.dp(18), Gravity.CENTER));
        MobileMotion.bindPress(backBtn, 0.90f);
        backBtn.setOnClickListener(v -> openSubPage(shell, 0, ""));
        LinearLayout.LayoutParams bLp = new LinearLayout.LayoutParams(a.dp(36), a.dp(36));
        bLp.rightMargin = a.dp(12);
        navRow.addView(backBtn, bLp);

        String subTitle =
                sub >= 0 && sub < subTitles.length
                        ? subTitles[sub]
                        : subTitles[subTitles.length - 1];
        TextView title = a.text(subTitle, 22f, p.textPrimary);
        title.setTypeface(null, Typeface.BOLD);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        navRow.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));
        body.addView(navRow, new LinearLayout.LayoutParams(-1, -2));

        switch (sub) {
            case MobileSettingsIndex.SUB_SOURCES:
                renderSubSourcesAndLive(shell, body, sv, activeHighlightKey);
                break;
            case MobileSettingsIndex.SUB_APPEARANCE:
                renderSubAppearanceAndNav(shell, body, sv);
                break;
            case MobileSettingsIndex.SUB_PLAYBACK:
                renderSubPlaybackAndGesture(shell, body, sv, activeHighlightKey);
                break;
            case MobileSettingsIndex.SUB_SUBTITLE:
                renderSubSubtitleAndDanmaku(shell, body, sv);
                break;
            case MobileSettingsIndex.SUB_SERVICES:
                renderSubScrapingAccountsAndAi(shell, body, sv);
                break;
            case MobileSettingsIndex.SUB_SYNC:
                renderSubSyncAndTvConnect(shell, body, sv, activeHighlightKey);
                break;
            case MobileSettingsIndex.SUB_STORAGE:
            default:
                renderSubStorageUpdateAndAbout(shell, body, sv);
                break;
        }

        // Scroll to & flash target setting row when navigated from Instant Settings Search
        if (!activeHighlightKey.isEmpty()) {
            MobileRootShell.settingsHighlightKey = "";
            a.pendingSettingsScrollY = -1;
            body.post(
                    () -> {
                        View target = body.findViewWithTag(activeHighlightKey);
                        if (target != null) {
                            int y = computeOffsetInAncestor(target, body);
                            sv.smoothScrollTo(0, Math.max(0, y - a.dp(72)));
                            flashSettingRow(a, target);
                        }
                    });
        } else {
            restorePendingScrollIfNeeded(a, body, sv);
        }
    }

    private static void restorePendingScrollIfNeeded(
            MainActivity a, LinearLayout body, final ScrollView sv) {
        if (a.pendingSettingsScrollY < 0) return;
        final int targetY = a.pendingSettingsScrollY;
        a.pendingSettingsScrollY = -1;
        body.post(() -> sv.scrollTo(0, targetY));
    }

    // =========================================================================
    // ROOT OVERVIEW: 3 CLUSTERS · 7 ENTRIES + INSTANT GROUPED SEARCH
    // =========================================================================
    private static void renderRootOverview(final MobileRootShell shell, final LinearLayout body) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);

        TextView heading = a.text("设置", 26f, p.textPrimary);
        heading.setTypeface(null, Typeface.BOLD);
        heading.setPadding(a.dp(4), 0, a.dp(4), 0);
        body.addView(heading, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 12);

        final EditText searchInput = new EditText(a);
        final LinearLayout searchHitsBox = a.vertical();
        searchHitsBox.setVisibility(View.GONE);
        final LinearLayout groupsBox = a.vertical();
        final boolean[] inSearchMode = {false};

        LinearLayout searchBar =
                MobileSectionGroup.searchBar(
                        a,
                        searchInput,
                        "搜索设置项",
                        () -> {
                            inSearchMode[0] = false;
                            MobileMotion.crossfadeVisibility(searchHitsBox, false, -4f, 1f);
                            MobileMotion.crossfadeVisibility(groupsBox, true, 0f, 1f);
                        });
        body.addView(searchBar, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 18);

        body.addView(searchHitsBox, new LinearLayout.LayoutParams(-1, -2));
        body.addView(groupsBox, new LinearLayout.LayoutParams(-1, -2));

        searchInput.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(Editable s) {
                        String q = s == null ? "" : s.toString().trim();
                        if (q.isEmpty()) {
                            if (inSearchMode[0]) {
                                inSearchMode[0] = false;
                                MobileMotion.crossfadeVisibility(searchHitsBox, false, -4f, 1f);
                                MobileMotion.crossfadeVisibility(groupsBox, true, 0f, 1f);
                            } else {
                                searchHitsBox.setVisibility(View.GONE);
                                groupsBox.setVisibility(View.VISIBLE);
                            }
                            return;
                        }
                        List<MobileSettingsIndex.Entry> hits = MobileSettingsIndex.search(q);
                        if (!inSearchMode[0]) {
                            inSearchMode[0] = true;
                            groupsBox.setVisibility(View.GONE);
                            MobileMotion.crossfadeVisibility(searchHitsBox, true, 4f, 1f);
                        } else {
                            groupsBox.setVisibility(View.GONE);
                            searchHitsBox.setVisibility(View.VISIBLE);
                        }
                        searchHitsBox.removeAllViews();
                        if (hits.isEmpty()) {
                            LinearLayout emptyCard = a.vertical();
                            emptyCard.setGravity(Gravity.CENTER);
                            emptyCard.setPadding(a.dp(16), a.dp(28), a.dp(16), a.dp(28));
                            emptyCard.setBackground(MobileTheme.cardBg(a, 16));
                            TextView emptyTv = a.text("未找到包含“" + q + "”的设置项", 14f, p.textSecondary);
                            emptyTv.setGravity(Gravity.CENTER);
                            emptyCard.addView(emptyTv);
                            searchHitsBox.addView(emptyCard, new LinearLayout.LayoutParams(-1, -2));
                            return;
                        }
                        Map<String, List<MobileSettingsIndex.Entry>> grouped =
                                new LinkedHashMap<>();
                        for (MobileSettingsIndex.Entry hit : hits) {
                            List<MobileSettingsIndex.Entry> bucket = grouped.get(hit.groupName);
                            if (bucket == null) {
                                bucket = new ArrayList<>();
                                grouped.put(hit.groupName, bucket);
                            }
                            bucket.add(hit);
                        }
                        for (Map.Entry<String, List<MobileSettingsIndex.Entry>> entry :
                                grouped.entrySet()) {
                            List<View> rows = new ArrayList<>();
                            for (final MobileSettingsIndex.Entry hit : entry.getValue()) {
                                rows.add(
                                        MobileSectionGroup.navRow(
                                                a,
                                                iconForSubPage(hit.subPage),
                                                tintForSubPage(hit.subPage, p),
                                                hit.title,
                                                null,
                                                () -> openSubPage(shell, hit.subPage, hit.key)));
                            }
                            addSection(a, searchHitsBox, entry.getKey(), null, rows);
                        }
                    }
                });

        // Cluster 1 — 个性化
        String themeLabel = MobileTheme.themeModeLabel(MobileTheme.themeMode(a));
        addSection(
                a,
                groupsBox,
                "个性化",
                null,
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_PALETTE,
                                        p.accent,
                                        "外观与导航",
                                        themeLabel,
                                        () ->
                                                openSubPage(
                                                        shell,
                                                        MobileSettingsIndex.SUB_APPEARANCE,
                                                        "")),
                                "ms-grp-2")));

        // Cluster 2 — 内容与观影
        String siteVal = a.config == null ? "未导入" : (a.config.sites.size() + " 个片源");
        String engineVal = shortEngineName(a.prefs.getInt(Prefs.PLAYER_ENGINE, 0));
        boolean bilingualOn = a.mobilePrefs().getBoolean(Prefs.SUBTITLE_BILINGUAL, true);
        boolean danmuOn = a.prefs.getBoolean(Prefs.DANMAKU_DEFAULT, true);
        String subDanmuVal = (bilingualOn ? "双语" : "单语") + " / " + (danmuOn ? "弹幕" : "关弹幕");
        String serviceVal = buildServiceSummary(a);
        addSection(
                a,
                groupsBox,
                "内容与观影",
                null,
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SWITCH_SOURCE,
                                        TINT_GREEN,
                                        "片源与直播",
                                        siteVal,
                                        () ->
                                                openSubPage(
                                                        shell,
                                                        MobileSettingsIndex.SUB_SOURCES,
                                                        "")),
                                "ms-grp-1"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_PLAY,
                                        TINT_BLUE,
                                        "播放与触控手势",
                                        engineVal,
                                        () ->
                                                openSubPage(
                                                        shell,
                                                        MobileSettingsIndex.SUB_PLAYBACK,
                                                        "")),
                                "ms-grp-3"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SUBTITLE,
                                        TINT_VIOLET,
                                        "字幕与弹幕",
                                        subDanmuVal,
                                        () ->
                                                openSubPage(
                                                        shell,
                                                        MobileSettingsIndex.SUB_SUBTITLE,
                                                        "")),
                                "ms-grp-4"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SPARKLE,
                                        TINT_AMBER,
                                        "网盘、追剧与 AI 助手",
                                        serviceVal,
                                        () ->
                                                openSubPage(
                                                        shell,
                                                        MobileSettingsIndex.SUB_SERVICES,
                                                        "")),
                                "ms-grp-5")));

        // Cluster 3 — 互联与系统
        String syncVal = a.privateMode ? "隐私空间" : "WebDAV / 局域网";
        String verVal = "v" + UpdateManager.installedVersion(a);
        addSection(
                a,
                groupsBox,
                "互联与系统",
                null,
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_CLOUD_SYNC,
                                        TINT_TEAL,
                                        "云同步与隐私互联",
                                        syncVal,
                                        () -> openSubPage(shell, MobileSettingsIndex.SUB_SYNC, "")),
                                "ms-grp-6"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_STORAGE,
                                        TINT_SLATE,
                                        "存储、备份与关于",
                                        verVal,
                                        () ->
                                                openSubPage(
                                                        shell,
                                                        MobileSettingsIndex.SUB_STORAGE,
                                                        "")),
                                "ms-grp-7"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SPARKLE,
                                        TINT_BLUE,
                                        "联系与反馈作者",
                                        MobileAuthorNotice.AUTHOR_SOCIAL_NAME,
                                        () -> MobileAuthorNotice.showContactSheet(a)),
                                "ms-grp-contact")));
    }

    // =========================================================================
    // SUB 2: 外观与导航 (Cluster 1 — 个性化)
    // =========================================================================
    private static void renderSubAppearanceAndNav(
            MobileRootShell shell, LinearLayout body, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);

        // Section ①: 主题与色彩 (non-disruptive live theme/accent switching preserving scrollY)
        int curMode = MobileTheme.themeMode(a);
        LinearLayout themeRow = a.vertical();
        themeRow.setTag("ms-theme-mode");
        themeRow.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        themeRow.addView(
                buildInlineControlHeader(
                        a,
                        p,
                        curMode == MobileTheme.MODE_LIGHT
                                ? MobileIcons.IC_SUN
                                : (curMode == MobileTheme.MODE_DARK
                                        ? MobileIcons.IC_MOON
                                        : MobileIcons.IC_THEME_AUTO),
                        p.accent,
                        "外观模式",
                        MobileTheme.themeModeLabel(curMode)),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(themeRow, 10);
        LinearLayout modeSeg =
                MobileSectionGroup.segmentedControl(
                        a,
                        new String[] {"跟随系统", "浅色日间", "深色夜间"},
                        curMode,
                        idx -> {
                            a.mobilePrefs().edit().putInt(Prefs.THEME_MODE, idx).apply();
                            applyThemePreservingScroll(a, sv);
                        });
        themeRow.addView(modeSeg, new LinearLayout.LayoutParams(-1, -2));

        int curAccent = a.mobilePrefs().getInt(Prefs.ACCENT_PRESET, 0);
        LinearLayout accentRow = a.vertical();
        accentRow.setTag("ms-accent");
        accentRow.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(4));
        accentRow.addView(
                buildInlineControlHeader(
                        a,
                        p,
                        MobileIcons.IC_PALETTE,
                        p.accent,
                        "主题强调色",
                        MobileTheme.accentName(curAccent)),
                new LinearLayout.LayoutParams(-1, -2));
        LinearLayout swatches =
                MobileSectionGroup.accentSwatchRow(
                        a,
                        curAccent,
                        idx -> {
                            a.mobilePrefs().edit().putInt(Prefs.ACCENT_PRESET, idx).apply();
                            applyThemePreservingScroll(a, sv);
                        });
        accentRow.addView(swatches, new LinearLayout.LayoutParams(-1, -2));

        int curScale =
                Prefs.clampMobileUiScale(
                        a.mobilePrefs().getInt(Prefs.MOBILE_UI_SCALE_PERCENT, 100));
        View scaleRow =
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_SLIDERS,
                                TINT_BLUE,
                                "界面整体缩放",
                                curScale + "%",
                                () -> {
                                    String[] labels = {
                                        "紧凑 · 90%", "标准 · 100%", "舒展 · 110%", "大字 · 120%"
                                    };
                                    int[] vals = {90, 100, 110, 120};
                                    int sel = 1;
                                    for (int i = 0; i < vals.length; i++) {
                                        if (vals[i] == curScale) sel = i;
                                    }
                                    MobileBottomSheet.showPicker(
                                            a,
                                            "界面整体缩放",
                                            "调整手机与平板全局文字与控件大小，选择后立即生效",
                                            labels,
                                            sel,
                                            idx -> {
                                                a.mobilePrefs()
                                                        .edit()
                                                        .putInt(
                                                                Prefs.MOBILE_UI_SCALE_PERCENT,
                                                                vals[idx])
                                                        .apply();
                                                a.recreate();
                                            });
                                }),
                        "ms-ui-scale");

        addSection(
                a,
                body,
                "主题与色彩",
                "切换日夜外观或强调色会原地即时生效，不会中断浏览位置；开启「跟随系统」可随系统自动切换。",
                Arrays.<View>asList(themeRow, accentRow, scaleRow));

        // Section ②: 导航与首页
        boolean isLargeOrFoldable = MobileRootShell.isTabletOrFoldable(a);
        List<View> navRows = new ArrayList<>();
        if (isLargeOrFoldable) {
            navRows.add(
                    mobileIntRow(
                            shell,
                            sv,
                            "ms-tablet-dock-pos",
                            MobileIcons.IC_SWITCH_SOURCE,
                            TINT_VIOLET,
                            "导航栏位置 (Dock)",
                            Prefs.TABLET_DOCK_POSITION,
                            new String[] {
                                "自动适配（横屏左侧 · 竖屏底部）",
                                "顶部悬浮栏（上）",
                                "底部悬浮栏（下）",
                                "左侧竖向边栏（左）",
                                "右侧竖向边栏（右）"
                            },
                            new String[] {"自动适配", "顶部", "底部", "左侧", "右侧"},
                            new int[] {
                                MobileRootShell.DOCK_POS_AUTO,
                                MobileRootShell.DOCK_POS_TOP,
                                MobileRootShell.DOCK_POS_BOTTOM,
                                MobileRootShell.DOCK_POS_LEFT,
                                MobileRootShell.DOCK_POS_RIGHT
                            },
                            MobileRootShell.DOCK_POS_AUTO,
                            true));
        }
        navRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-nav-style",
                        MobileIcons.IC_MENU,
                        TINT_BLUE,
                        isLargeOrFoldable ? "横向导航栏形态（上/下位置）" : "底部导航栏形态",
                        Prefs.NAV_STYLE,
                        new String[] {"4+1 分离搜索（右侧独立搜索圆钮）", "五栏一体胶囊"},
                        new String[] {"4+1 分离搜索", "五栏一体"},
                        new int[] {0, 1},
                        0,
                        true));
        navRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-nav-scroll",
                        MobileIcons.IC_SORT,
                        TINT_TEAL,
                        "滑动页面时底栏自动收起",
                        Prefs.NAV_SCROLL_BEHAVIOR,
                        new String[] {"始终常驻显示", "上滑折叠为小胶囊（保留搜索钮）", "上滑完全自动隐藏"},
                        new String[] {"始终常驻", "上滑折叠", "自动隐藏"},
                        new int[] {0, 1, 2},
                        1,
                        false));
        navRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_LIBRARY,
                                TINT_VIOLET,
                                "首页专题显示与排序",
                                "已开启 "
                                        + MobileHomeSections.visibleCount(a)
                                        + " / "
                                        + MobileHomeSections.DEFAULT_ORDER.size()
                                        + " 个",
                                () ->
                                        MobileHomeSections.showSettingsSheet(
                                                a, () -> reloadPreservingScroll(shell, sv))),
                        "ms-home-sections"));
        navRows.add(
                mobileToggleRow(
                        a,
                        "ms-home-banner",
                        MobileIcons.IC_STAR,
                        TINT_AMBER,
                        "首页精选大图横幅",
                        Prefs.HOME_CAROUSEL,
                        true,
                        () ->
                                MobileHomeSections.setVisible(
                                        a,
                                        MobileHomeSections.ID_HERO_BILLBOARD,
                                        a.mobilePrefs().getBoolean(Prefs.HOME_CAROUSEL, true))));
        navRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-poster-density",
                        MobileIcons.IC_LIBRARY,
                        TINT_GREEN,
                        "海报墙排布密度",
                        Prefs.MOBILE_POSTER_DENSITY,
                        new String[] {"紧凑（同屏更多影片）", "标准（均衡推荐）", "宽敞（更大海报封面）"},
                        new String[] {"紧凑", "标准", "宽敞"},
                        new int[] {0, 1, 2},
                        1,
                        false));
        navRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-card-subtitle",
                        MobileIcons.IC_SUBTITLE,
                        TINT_SLATE,
                        "海报下方信息显示",
                        Prefs.MOBILE_CARD_SUBTITLE,
                        new String[] {"显示片名与更新角标", "仅显示更新角标", "极简纯片名"},
                        new String[] {"全部显示", "仅角标", "纯片名"},
                        new int[] {0, 1, 2},
                        0,
                        false));
        navRows.add(
                coreToggleRow(
                        a,
                        "ms-show-history",
                        MobileIcons.IC_HISTORY,
                        TINT_CORAL,
                        "首页显示继续观看",
                        Prefs.MOBILE_SHOW_HISTORY,
                        true,
                        () ->
                                MobileHomeSections.setVisible(
                                        a,
                                        MobileHomeSections.ID_WATCH_HISTORY,
                                        a.prefs.getBoolean(Prefs.MOBILE_SHOW_HISTORY, true))));
        addSection(
                a,
                body,
                "导航与首页",
                isLargeOrFoldable
                        ? "已识别为平板 / 折叠屏设备，可将 Dock 导航栏自由固定在屏幕上下左右任意一侧；长按或向内轻滑导航图标可呼出高频快捷菜单。"
                        : "长按或按住上滑底栏任意图标，均可呼出高频快捷菜单。",
                navRows);

        // Section ③: 背景与动效
        boolean wpOn = a.prefs.getBoolean(Prefs.WALLPAPER_ENABLED, false);
        int wpDim = Prefs.clampWallpaperDim(a.prefs.getInt(Prefs.WALLPAPER_DIM, 65));
        List<View> bgRows = new ArrayList<>();
        bgRows.add(
                mobileToggleRow(
                        a,
                        "ms-cover-ambient",
                        MobileIcons.IC_SPARKLE,
                        TINT_VIOLET,
                        "封面氛围柔光背景",
                        Prefs.COVER_AMBIENT,
                        true,
                        null));
        bgRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_FOLDER,
                                TINT_AMBER,
                                "自定义背景壁纸与暗度",
                                wpOn ? ("暗度 " + wpDim + "%") : "默认画布",
                                () -> {
                                    String[] opts = {
                                        "从手机相册选择背景图",
                                        "压暗程度 · 45%（更通透）",
                                        "压暗程度 · 65%（推荐）",
                                        "压暗程度 · 82%（更护眼）",
                                        "恢复默认纯净画布"
                                    };
                                    int sel = !wpOn ? 4 : (wpDim <= 52 ? 1 : (wpDim <= 74 ? 2 : 3));
                                    MobileBottomSheet.showPicker(
                                            a,
                                            "自定义背景壁纸",
                                            "适当的压暗遮罩可让海报与文字在任意壁纸上清晰易读",
                                            opts,
                                            sel,
                                            idx -> {
                                                if (idx == 0) {
                                                    BackupManager.pickDocument(
                                                            a, 44, "image/*", false);
                                                } else if (idx >= 1 && idx <= 3) {
                                                    int dim = idx == 1 ? 45 : (idx == 2 ? 65 : 82);
                                                    a.prefs
                                                            .edit()
                                                            .putInt(Prefs.WALLPAPER_DIM, dim)
                                                            .putBoolean(
                                                                    Prefs.WALLPAPER_ENABLED, true)
                                                            .apply();
                                                    applyThemePreservingScroll(a, sv);
                                                } else {
                                                    a.prefs
                                                            .edit()
                                                            .putBoolean(
                                                                    Prefs.WALLPAPER_ENABLED, false)
                                                            .apply();
                                                    applyThemePreservingScroll(a, sv);
                                                }
                                            });
                                }),
                        "ms-wallpaper"));
        bgRows.add(
                coreToggleRow(
                        a,
                        "ms-glass-toggle",
                        MobileIcons.IC_BRIGHTNESS,
                        TINT_TEAL,
                        "关闭半透明毛玻璃（更省电）",
                        Prefs.REDUCED_TRANSPARENCY,
                        false,
                        () -> applyThemePreservingScroll(a, sv)));
        bgRows.add(
                coreToggleRow(
                        a,
                        "ms-reduced-motion",
                        MobileIcons.IC_SPEED,
                        TINT_SLATE,
                        "减弱界面动态效果",
                        Prefs.REDUCED,
                        false,
                        () -> a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false)));
        addSection(a, body, "背景与动效", "关闭半透明模糊与减弱动效可降低老旧机型功耗，也会自动尊重系统无障碍动画设置。", bgRows);
    }

    // =========================================================================
    // SUB 1: 片源与直播 (Cluster 2 — 内容与观影)
    // =========================================================================
    private static void renderSubSourcesAndLive(
            MobileRootShell shell,
            LinearLayout body,
            final ScrollView sv,
            String activeHighlightKey) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);

        // Section ①: 配置导入与默认站
        boolean hasMultiDepots =
                a.config != null && a.config.depots != null && a.config.depots.length() > 1;
        String lastAuto = a.prefs.getString(Prefs.SUBSCRIPTION_LAST_AUTO_STATUS, "").trim();
        List<View> cfgRows = new ArrayList<>();
        cfgRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_CLIPBOARD,
                                TINT_GREEN,
                                "剪贴板一键识别导入",
                                "自动识别",
                                () -> UiWidgets.pasteConfigFromClipboard(a)),
                        "ms-clip-import"));
        cfgRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_LINK,
                                TINT_BLUE,
                                "通过网址或本地包导入片源",
                                a.configOrigin.isEmpty() ? "未导入" : "已导入",
                                () -> UiWidgets.showMobileImportDialog(a)),
                        "ms-url-import"));
        cfgRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_SWITCH_SOURCE,
                                TINT_TEAL,
                                "切换默认首页片源",
                                shell.activeSite == null ? "未选择" : shell.activeSite.name,
                                shell::showQuickSourceAndModeSheet),
                        "ms-switch-site"));
        cfgRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_FOLDER,
                                TINT_AMBER,
                                "订阅源与多仓管理",
                                hasMultiDepots ? (a.config.depots.length() + " 个子仓") : "历史订阅",
                                () -> {
                                    if (hasMultiDepots) {
                                        MobileBottomSheet.showPicker(
                                                a,
                                                "订阅源与多仓管理",
                                                "切换当前影视仓子仓库或管理已保存的历史订阅",
                                                new String[] {
                                                    "切换当前影视仓子仓库 (" + a.config.depots.length() + ")",
                                                    "管理已保存的历史订阅配置"
                                                },
                                                0,
                                                idx -> {
                                                    if (idx == 0) SourcePicker.showWarehouses(a);
                                                    else SourcePicker.showSavedConfigs(a);
                                                });
                                    } else {
                                        SourcePicker.showSavedConfigs(a);
                                    }
                                }),
                        "ms-saved-configs"));
        cfgRows.add(
                coreToggleRow(
                        a,
                        "ms-sub-auto",
                        MobileIcons.IC_TIMER,
                        TINT_VIOLET,
                        "每日后台自动更新订阅源",
                        Prefs.SUBSCRIPTION_AUTO_UPDATE,
                        true,
                        null));
        cfgRows.add(
                tagged(
                        MobileSectionGroup.actionRow(
                                a,
                                MobileIcons.IC_REFRESH,
                                TINT_BLUE,
                                "立即刷新当前订阅源",
                                lastAuto.isEmpty() ? "立即拉取" : trimCompact(lastAuto, 12),
                                p.accent,
                                () -> {
                                    a.toast("正在后台刷新订阅源…");
                                    SourceController.runDailyAutoUpdateIfNeeded(a, true);
                                }),
                        "ms-sub-refresh-now"));
        addSection(a, body, "配置导入与默认站", "复制影视源网址或配置文本后点「剪贴板一键识别」，系统会自动判断单仓、多仓或离线压缩包。", cfgRows);

        // Section ②: 电视直播
        String epg = a.prefs.getString(Prefs.LIVE_EPG_URL, "").trim();
        List<View> liveRows = new ArrayList<>();
        liveRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_LIVE,
                                TINT_CORAL,
                                "电视直播源管理",
                                "M3U / TXT",
                                () -> SourceController.showLiveImportDialog(a)),
                        "ms-live-import"));
        liveRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_BELL,
                                TINT_BLUE,
                                "直播节目预告单 (EPG)",
                                epg.isEmpty() ? "跟随列表" : "已配置",
                                () -> SourceController.showEpgDialog(a)),
                        "ms-live-epg"));
        liveRows.add(
                coreToggleRow(
                        a,
                        "ms-live-hq",
                        MobileIcons.IC_SPARKLE,
                        TINT_GREEN,
                        "直播优先高画质与 IPv6",
                        Prefs.LIVE_HIGH_QUALITY,
                        true,
                        null));
        liveRows.add(
                coreToggleRow(
                        a,
                        "ms-live-merge",
                        MobileIcons.IC_SWITCH_SOURCE,
                        TINT_VIOLET,
                        "同名频道合并多线路切换",
                        Prefs.LIVE_MERGE_SOURCES,
                        true,
                        null));
        addSection(a, body, "电视直播", "开启同名合并后，多个直播订阅中的同一频道会自动整合，播放时可一键切线路。", liveRows);

        // Section ③: 聚合搜索
        List<View> searchRows = new ArrayList<>();
        searchRows.add(
                mobileToggleRow(
                        a,
                        "ms-search-sidebar",
                        MobileIcons.IC_SEARCH,
                        TINT_TEAL,
                        "搜索页左侧显示片源筛选栏",
                        Prefs.SEARCH_PLATFORM_SIDEBAR,
                        false,
                        null));
        searchRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-search-threads",
                        MobileIcons.IC_SPEED,
                        TINT_CORAL,
                        "聚合搜索同时查询片源数",
                        Prefs.SEARCH_THREADS,
                        new String[] {"2 个片源 · 更省电", "4 个片源 · 均衡", "6 个片源 · 更快捷"},
                        new String[] {"2 个", "4 个", "6 个"},
                        new int[] {2, 4, 6},
                        6,
                        false));
        addSection(a, body, "聚合搜索", "片源较多时建议开启左侧筛选栏，单手拇指即可快速切换不同片源的搜索结果。", searchRows);

        // Collapsible Section ④: 高级与调试选项 (progressive disclosure)
        String udpxy = a.prefs.getString(Prefs.LIVE_UDPXY_URL, "").trim();
        boolean cspOn = a.prefs.getBoolean(Prefs.EXPERIMENTAL_CSP, true);
        boolean jsOn = a.prefs.getBoolean(Prefs.WEBVIEW_JS_FALLBACK, true);
        boolean pyOn = a.prefs.getBoolean(Prefs.NATIVE_PYTHON_ENABLED, true);
        boolean httpsOnly = a.prefs.getBoolean(Prefs.ONLY_ALLOW_HTTPS_PLUGINS, false);
        boolean nonDefault = !udpxy.isEmpty() || !cspOn || !jsOn || !pyOn || httpsOnly;
        boolean expandAdv =
                shouldAutoExpandAdvanced(
                        EXPANDED_ADVANCED.contains(MobileSettingsIndex.SUB_SOURCES),
                        nonDefault,
                        activeHighlightKey,
                        "ms-live-udpxy",
                        "ms-ext-csp",
                        "ms-ext-js",
                        "ms-ext-py",
                        "ms-https-only");

        List<View> advRows = new ArrayList<>();
        advRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_TV_LINK,
                                TINT_TEAL,
                                "路由器组播转单播 (udpxy)",
                                udpxy.isEmpty() ? "未配置" : "已配置",
                                () -> SourceController.showUdpxyDialog(a)),
                        "ms-live-udpxy"));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-ext-csp",
                        MobileIcons.IC_ENGINE,
                        TINT_AMBER,
                        "支持第三方 JAR 扩展源",
                        Prefs.EXPERIMENTAL_CSP,
                        true,
                        a::closeEngines));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-ext-js",
                        MobileIcons.IC_LINK,
                        TINT_BLUE,
                        "网页脚本源兼容兜底 (WebView JS)",
                        Prefs.WEBVIEW_JS_FALLBACK,
                        true,
                        a::closeEngines));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-ext-py",
                        MobileIcons.IC_SLIDERS,
                        TINT_GREEN,
                        "内置 Python 扩展运行引擎",
                        Prefs.NATIVE_PYTHON_ENABLED,
                        true,
                        a::closeEngines));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-https-only",
                        MobileIcons.IC_PRIVACY,
                        TINT_ROSE,
                        "仅允许 HTTPS 安全插件",
                        Prefs.ONLY_ALLOW_HTTPS_PLUGINS,
                        false,
                        a::closeEngines));
        addCollapsibleAdvancedSection(
                a,
                body,
                MobileSettingsIndex.SUB_SOURCES,
                expandAdv,
                nonDefault,
                "普通观影保持默认即可；使用路由器 IPTV 组播或排查 JAR / JS / Python 扩展插件时再按需调整。",
                advRows);
    }

    // =========================================================================
    // SUB 3: 播放与触控手势 (Cluster 2 — 内容与观影)
    // =========================================================================
    private static void renderSubPlaybackAndGesture(
            MobileRootShell shell,
            LinearLayout body,
            final ScrollView sv,
            String activeHighlightKey) {
        final MainActivity a = shell.a;

        // Section ①: 起播与选集
        List<View> startRows = new ArrayList<>();
        startRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-detail-tap",
                        MobileIcons.IC_PLAY,
                        TINT_BLUE,
                        "点选剧集时的起播方式",
                        Prefs.DETAIL_TAP_MODE,
                        new String[] {"顶部内嵌小窗直接播放（推荐）", "直接进入横屏全屏播放", "仅选中剧集，点击播放键再起播"},
                        new String[] {"内嵌小窗", "直接全屏", "仅选中"},
                        new int[] {0, 1, 2},
                        0,
                        false));
        startRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-ep-clean",
                        MobileIcons.IC_SPARKLE,
                        TINT_VIOLET,
                        "自动整理清晰集名",
                        Prefs.EPISODE_CLEAN_MODE,
                        new String[] {"本地智能净化（毫秒级零流量）", "关闭（显示片源原始集名）", "AI 深度净化（需配置 AI 助手）"},
                        new String[] {"本地净化", "关闭", "AI 净化"},
                        new int[] {0, 1, 2},
                        0,
                        false));
        startRows.add(
                coreToggleRow(
                        a,
                        "ms-auto-next",
                        MobileIcons.IC_NEXT_EP,
                        TINT_GREEN,
                        "播完自动连播下一集",
                        Prefs.AUTO_NEXT,
                        true,
                        null));
        startRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-repeat-mode",
                        MobileIcons.IC_REPEAT,
                        TINT_AMBER,
                        "循环播放模式",
                        Prefs.REPEAT_MODE,
                        new String[] {"关闭循环", "单集循环", "列表循环"},
                        new String[] {"关闭", "单集循环", "列表循环"},
                        new int[] {0, 1, 2},
                        0,
                        false));
        addSection(
                a,
                body,
                "起播与选集",
                "每部剧集打开时默认正序并自动定位到上次观看集数，切换倒序仅对当前剧集生效；小窗起播让你边看简介挑线路边播。",
                startRows);

        // Section ②: 内核与音画增强
        // NOTE: Engine mapping MUST preserve exact `new int[] {0, 1, 2, 3}` (Media3=0, System=1,
        // IJK=2, MPV=3).
        List<View> coreRows = new ArrayList<>();
        coreRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-player-engine",
                        MobileIcons.IC_ENGINE,
                        TINT_BLUE,
                        "默认播放内核",
                        Prefs.PLAYER_ENGINE,
                        new String[] {
                            "智能推荐 (Media3 · 省电稳定)",
                            "系统原生播放器",
                            "兼容内核 (IJK · 适合直播与旧格式)",
                            "高画质影院 (MPV · 支持 HDR 与超分)"
                        },
                        new String[] {"智能推荐 (Media3)", "系统原生", "兼容内核 (IJK)", "高画质影院 (MPV)"},
                        new int[] {0, 1, 2, 3},
                        0,
                        false));
        coreRows.add(
                mobileToggleRow(
                        a,
                        "ms-auto-switch-kernel",
                        MobileIcons.IC_REFRESH,
                        TINT_GREEN,
                        "起播失败自动切换备用内核",
                        Prefs.AUTO_SWITCH_KERNEL,
                        true,
                        null));
        coreRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-decoder-mode",
                        MobileIcons.IC_SLIDERS,
                        TINT_TEAL,
                        "视频解码方式",
                        Prefs.DECODER_MODE,
                        new String[] {"自动选择（推荐）", "硬件解码优先 · 更省电", "软件解码优先 · 兼容性强"},
                        new String[] {"自动", "硬解优先", "软解优先"},
                        new int[] {0, 1, 2},
                        0,
                        false));
        coreRows.add(
                coreToggleRow(
                        a,
                        "ms-hdr-tone",
                        MobileIcons.IC_SUN,
                        TINT_AMBER,
                        "HDR 画面亮暗自适应优化 (MPV)",
                        Prefs.HDR_TONE_MAPPING,
                        true,
                        null));
        coreRows.add(
                coreToggleRow(
                        a,
                        "ms-anime4k",
                        MobileIcons.IC_SPARKLE,
                        TINT_VIOLET,
                        "动漫画面实时超分增强 (Anime4K)",
                        Prefs.ANIME4K_ENABLED,
                        false,
                        null));
        coreRows.add(
                mobileToggleRow(
                        a,
                        "ms-letterbox",
                        MobileIcons.IC_PALETTE,
                        TINT_CORAL,
                        "宽银幕上下黑边柔光填充",
                        Prefs.LETTERBOX_BLUR,
                        false,
                        null));
        coreRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-loudness",
                        MobileIcons.IC_VOLUME,
                        TINT_ROSE,
                        "音量响度增益",
                        Prefs.LOUDNESS_BOOST,
                        new String[] {"关闭增益", "+3 dB", "+6 dB", "+10 dB", "+15 dB"},
                        new String[] {"关闭", "+3 dB", "+6 dB", "+10 dB", "+15 dB"},
                        new int[] {0, 3, 6, 10, 15},
                        0,
                        false));
        coreRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-picture-effect",
                        MobileIcons.IC_BRIGHTNESS,
                        TINT_AMBER,
                        "画面色彩风格",
                        Prefs.PICTURE_EFFECT,
                        new String[] {"原始色彩", "明亮鲜活", "影院质感", "柔和护眼"},
                        new String[] {"原始", "明亮", "影院", "柔和"},
                        new int[] {0, 1, 2, 3},
                        0,
                        false));
        coreRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-audio-effect",
                        MobileIcons.IC_AUDIO_TRACK,
                        TINT_GREEN,
                        "音频均衡音效",
                        Prefs.AUDIO_EFFECT,
                        new String[] {"原声输出", "影院环绕", "人声清晰", "柔和低音"},
                        new String[] {"原声", "影院", "人声清晰", "柔和低音"},
                        new int[] {0, 1, 2, 3},
                        0,
                        false));
        coreRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-aspect",
                        MobileIcons.IC_ASPECT,
                        TINT_BLUE,
                        "默认画面比例",
                        Prefs.ASPECT,
                        new String[] {"自适应", "拉伸铺满", "16:9 宽屏", "4:3 经典", "裁切填充"},
                        new String[] {"自适应", "铺满", "16:9", "4:3", "裁切"},
                        new int[] {0, 1, 2, 3, 4},
                        0,
                        false));

        float curSpeed = a.prefs.getFloat(Prefs.PLAY_SPEED, 1.0f);
        coreRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_SPEED,
                                TINT_TEAL,
                                "默认播放倍速",
                                formatSpeed(curSpeed),
                                () -> {
                                    String[] labels = {
                                        "0.5×", "0.75×", "1.0×（标准）", "1.25×", "1.5×", "2.0×"
                                    };
                                    float[] vals = {0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f};
                                    int sel = 2;
                                    for (int i = 0; i < vals.length; i++) {
                                        if (Math.abs(vals[i] - curSpeed) < 0.05f) sel = i;
                                    }
                                    MobileBottomSheet.showPicker(
                                            a,
                                            "默认播放倍速",
                                            "新起播影片默认使用该播放速度",
                                            labels,
                                            sel,
                                            idx -> {
                                                a.prefs
                                                        .edit()
                                                        .putFloat(Prefs.PLAY_SPEED, vals[idx])
                                                        .apply();
                                                reloadPreservingScroll(shell, sv);
                                            });
                                }),
                        "ms-play-speed"));
        coreRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-buffer-sec",
                        MobileIcons.IC_TIMER,
                        TINT_SLATE,
                        "网络预加载缓冲时长",
                        Prefs.BUFFER_SECONDS,
                        new String[] {"15 秒 · 节省内存", "30 秒 · 均衡推荐", "50 秒 · 弱网防卡顿"},
                        new String[] {"15 秒", "30 秒", "50 秒"},
                        new int[] {15, 30, 50},
                        30,
                        false));
        addSection(
                a, body, "内核与音画增强", "日常追剧推荐默认的智能内核（Media3）；观看高码率 HDR 或特效字幕动漫时可切换 MPV。", coreRows);

        // Section ③: 触屏手势防误触
        List<View> gestureRows = new ArrayList<>();
        gestureRows.add(
                mobileToggleRow(
                        a,
                        "ms-swipe-swap",
                        MobileIcons.IC_GESTURE,
                        TINT_CORAL,
                        "互换左右半屏亮度与音量手势",
                        Prefs.SWIPE_SWAP_LR,
                        false,
                        null));
        gestureRows.add(
                mobileToggleRow(
                        a,
                        "ms-src-bright",
                        MobileIcons.IC_BRIGHTNESS,
                        TINT_AMBER,
                        "按片源记住各自播放亮度",
                        Prefs.REMEMBER_SOURCE_BRIGHTNESS,
                        true,
                        null));
        float curBoost = a.mobilePrefs().getFloat(Prefs.LONG_PRESS_SPEED, 2.0f);
        gestureRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_SPEED,
                                TINT_BLUE,
                                "长按画面临时加速倍速",
                                String.format(Locale.US, "%.1f×", curBoost),
                                () -> {
                                    String[] labels = {
                                        "1.5× 轻快倍速",
                                        "2.0× 标准二倍速（推荐）",
                                        "2.5× 进阶倍速",
                                        "3.0× 三倍速刷剧",
                                        "4.0× 极速浏览"
                                    };
                                    float[] vals = {1.5f, 2.0f, 2.5f, 3.0f, 4.0f};
                                    int sel = 1;
                                    for (int i = 0; i < vals.length; i++) {
                                        if (Math.abs(vals[i] - curBoost) < 0.1f) sel = i;
                                    }
                                    MobileBottomSheet.showPicker(
                                            a,
                                            "长按画面临时加速倍速",
                                            "长按屏幕时向右微滑可平滑提速，松手即刻恢复原速",
                                            labels,
                                            sel,
                                            idx -> {
                                                a.mobilePrefs()
                                                        .edit()
                                                        .putFloat(Prefs.LONG_PRESS_SPEED, vals[idx])
                                                        .apply();
                                                reloadPreservingScroll(shell, sv);
                                            });
                                }),
                        "ms-long-speed"));
        gestureRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-vert-ep",
                        MobileIcons.IC_GESTURE,
                        TINT_VIOLET,
                        "上下滑动切换上下集",
                        Prefs.VERTICAL_SWIPE_EPISODE,
                        new String[] {"关闭上下滑换集", "双指上下滑换集（防误触 · 推荐）", "画面中区单指上下滑换集"},
                        new String[] {"关闭", "双指防误触", "单指中区"},
                        new int[] {0, 1, 2},
                        1,
                        false));
        int hudMask = a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD, 7);
        gestureRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_BATTERY,
                                TINT_GREEN,
                                "播放页右上角状态信息",
                                describeHudMaskCompact(hudMask),
                                () -> showCornerHudConfigSheet(shell, sv)),
                        "ms-corner-hud"));
        boolean reconciledSlimOn =
                com.pilipala.marcomovie.hud.PlayerHudPrefs.isUnifiedSlimProgressEnabled(
                        a, a.mobilePrefs());
        gestureRows.add(
                mobileToggleRow(
                        a,
                        "ms-mini-bar",
                        MobileIcons.IC_SLIDERS,
                        TINT_TEAL,
                        "隐藏按钮后保留底部进度细线",
                        Prefs.MINI_PROGRESS_BAR,
                        reconciledSlimOn,
                        () -> {
                            boolean on = a.mobilePrefs().getBoolean(Prefs.MINI_PROGRESS_BAR, true);
                            com.pilipala.marcomovie.hud.PlayerHudPrefs
                                    .setUnifiedSlimProgressEnabled(a, a.mobilePrefs(), on);
                            if (a.mobilePlayerOverlay != null) {
                                a.mobilePlayerOverlay.syncControlsVisibility();
                            }
                            if (a.playerChrome != null) {
                                a.playerChrome.update();
                            }
                        }));
        gestureRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_SORT,
                                TINT_SLATE,
                                "自定义播放器按钮顺序",
                                "排序",
                                () -> showPlayerButtonOrderDialog(shell)),
                        "ms-btn-order"));
        addSection(a, body, "触屏手势防误触", "默认左半屏滑调亮度、右半屏滑调音量；右上角状态信息仅在隐藏播放按钮时静默显示。", gestureRows);

        // Section ④: 片头片尾与后台
        int sIntro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_INTRO, 0));
        int sOutro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_OUTRO, 0));
        String skipVal = (sIntro == 0 && sOutro == 0) ? "未设置" : (sIntro + "s / " + sOutro + "s");
        List<View> tailRows = new ArrayList<>();
        tailRows.add(
                mobileToggleRow(
                        a,
                        "ms-skip-intro",
                        MobileIcons.IC_SKIP,
                        TINT_BLUE,
                        "自动识别并跳过剧集片头",
                        Prefs.THEINTRODB_AUTO_SKIP,
                        true,
                        null));
        tailRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_TIMER,
                                TINT_AMBER,
                                "手动设置跳过片头 / 片尾秒数",
                                skipVal,
                                () ->
                                        MobileBottomSheet.showPicker(
                                                a,
                                                "片头 / 片尾跳过设置",
                                                "当前全局片头 " + sIntro + " 秒 · 片尾 " + sOutro + " 秒",
                                                new String[] {
                                                    "调节全局跳过片头秒数",
                                                    "调节全局跳过片尾秒数",
                                                    "查看单部影片独立记录 ("
                                                            + PlaybackControls
                                                                    .countVideoSkipRecords(a)
                                                            + ")",
                                                    "清零全局片头片尾"
                                                },
                                                0,
                                                idx -> {
                                                    if (idx == 0) {
                                                        PlaybackControls.showSkipAdjuster(
                                                                a,
                                                                true,
                                                                0,
                                                                0,
                                                                () ->
                                                                        reloadPreservingScroll(
                                                                                shell, sv));
                                                    } else if (idx == 1) {
                                                        PlaybackControls.showSkipAdjuster(
                                                                a,
                                                                false,
                                                                0,
                                                                0,
                                                                () ->
                                                                        reloadPreservingScroll(
                                                                                shell, sv));
                                                    } else if (idx == 2) {
                                                        PlaybackControls.showVideoSkipRecordsDialog(
                                                                a,
                                                                () ->
                                                                        reloadPreservingScroll(
                                                                                shell, sv));
                                                    } else {
                                                        a.prefs
                                                                .edit()
                                                                .putInt(Prefs.SKIP_INTRO, 0)
                                                                .putInt(Prefs.SKIP_OUTRO, 0)
                                                                .apply();
                                                        reloadPreservingScroll(shell, sv);
                                                    }
                                                })),
                        "ms-manual-skip"));
        tailRows.add(
                mobileToggleRow(
                        a,
                        "ms-pip-bg",
                        MobileIcons.IC_PIP,
                        TINT_GREEN,
                        "返回桌面自动悬浮小窗播放",
                        Prefs.AUTO_PIP,
                        true,
                        null));
        tailRows.add(
                mobileToggleRow(
                        a,
                        "ms-bg-audio",
                        MobileIcons.IC_AUDIO_TRACK,
                        TINT_VIOLET,
                        "锁屏或切后台继续听剧",
                        Prefs.BACKGROUND_PLAY,
                        false,
                        null));
        addSection(a, body, "片头片尾与后台", "自动跳片头基于 TheIntroDB 社区时间点（搭配 TMDB 效果更佳）。", tailRows);

        // Collapsible Section ⑤: 高级与调试选项 (progressive disclosure)
        boolean tunneled = a.prefs.getBoolean(Prefs.TUNNELED_PLAYBACK, false);
        boolean swAudio = a.prefs.getBoolean(Prefs.SOFTWARE_AUDIO, false);
        boolean preferAac = a.prefs.getBoolean(Prefs.PREFER_AAC, false);
        int videoOut = a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0);
        boolean hlsProxy = a.prefs.getBoolean(Prefs.HLS_PROXY_ENABLED, true);
        boolean hlsAd = a.prefs.getBoolean(Prefs.HLS_AD_STRIP, false);
        boolean nonDefault =
                tunneled || swAudio || preferAac || videoOut != 0 || !hlsProxy || hlsAd;
        boolean expandAdv =
                shouldAutoExpandAdvanced(
                        EXPANDED_ADVANCED.contains(MobileSettingsIndex.SUB_PLAYBACK),
                        nonDefault,
                        activeHighlightKey,
                        "ms-tunneled",
                        "ms-sw-audio",
                        "ms-prefer-aac",
                        "ms-video-output",
                        "ms-hls-proxy",
                        "ms-hls-ad");

        List<View> advRows = new ArrayList<>();
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-tunneled",
                        MobileIcons.IC_LIVE,
                        TINT_VIOLET,
                        "4K HDR 低功耗硬件直通",
                        Prefs.TUNNELED_PLAYBACK,
                        false,
                        null));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-sw-audio",
                        MobileIcons.IC_AUDIO_TRACK,
                        TINT_SLATE,
                        "兼容音频软解码",
                        Prefs.SOFTWARE_AUDIO,
                        false,
                        null));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-prefer-aac",
                        MobileIcons.IC_VOLUME,
                        TINT_SLATE,
                        "优先选择 AAC 兼容音轨",
                        Prefs.PREFER_AAC,
                        false,
                        null));
        advRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-video-output",
                        MobileIcons.IC_FULLSCREEN,
                        TINT_BLUE,
                        "画面渲染输出模式",
                        Prefs.VIDEO_OUTPUT,
                        new String[] {"画质保真优先 · HDR 与高帧率", "兼容调色模式 · 支持应用内调色"},
                        new String[] {"画质保真", "兼容调色"},
                        new int[] {0, 1},
                        0,
                        false));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-hls-proxy",
                        MobileIcons.IC_LINK,
                        TINT_TEAL,
                        "自动修复防盗链视频流",
                        Prefs.HLS_PROXY_ENABLED,
                        true,
                        null));
        advRows.add(
                coreToggleRow(
                        a,
                        "ms-hls-ad",
                        MobileIcons.IC_FILTER,
                        TINT_CORAL,
                        "自动过滤切片插播广告 (HLS)",
                        Prefs.HLS_AD_STRIP,
                        false,
                        null));
        addCollapsibleAdvancedSection(
                a,
                body,
                MobileSettingsIndex.SUB_PLAYBACK,
                expandAdv,
                nonDefault,
                "自动修复防盗链视频流（HLS 本地代理）可修正伪装图床分片；仅在遇到无声、花屏或 4K HDR 兼容问题时再调整解码与直通选项。",
                advRows);
    }

    // =========================================================================
    // SUB 4: 字幕与弹幕 (Cluster 2 — 内容与观影)
    // =========================================================================
    private static void renderSubSubtitleAndDanmaku(
            MobileRootShell shell, LinearLayout body, final ScrollView sv) {
        final MainActivity a = shell.a;

        // Section ①: 字幕显示与调校
        int subSize = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        int subBot = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        List<View> subRows = new ArrayList<>();
        subRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_SUBTITLE,
                                TINT_VIOLET,
                                "全屏手势预览调校字幕",
                                subSize + " / " + subBot + "dp",
                                () ->
                                        PlaybackControls.showSubtitleAdjuster(
                                                a, null, () -> reloadPreservingScroll(shell, sv))),
                        "ms-sub-adjust"));
        subRows.add(
                mobileToggleRow(
                        a,
                        "ms-sub-bilingual",
                        MobileIcons.IC_SPARKLE,
                        TINT_BLUE,
                        "AI 双语对照同屏字幕",
                        Prefs.SUBTITLE_BILINGUAL,
                        true,
                        null));
        subRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-sub-style",
                        MobileIcons.IC_PALETTE,
                        TINT_AMBER,
                        "字幕配色与底衬样式",
                        Prefs.SUBTITLE_STYLE,
                        SubtitleOverlayView.STYLE_LABELS,
                        SubtitleOverlayView.STYLE_LABELS,
                        new int[] {0, 1, 2, 3, 4, 5, 6, 7},
                        0,
                        false));
        subRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-sub-weight",
                        MobileIcons.IC_EDIT,
                        TINT_TEAL,
                        "字幕字体粗细",
                        Prefs.SUBTITLE_WEIGHT,
                        new String[] {"纤细 (20)", "标准 (50 · 推荐)", "加粗 (75)", "特粗 (100)"},
                        new String[] {"纤细", "标准", "加粗", "特粗"},
                        new int[] {20, 50, 75, 100},
                        50,
                        false));
        subRows.add(
                coreIntRow(
                        shell,
                        sv,
                        "ms-sub-offset",
                        MobileIcons.IC_SLIDERS,
                        TINT_SLATE,
                        "字幕水平位置微调",
                        Prefs.SUBTITLE_OFFSET_X,
                        new String[] {"偏左 (-40)", "微左 (-20)", "居中 (0)", "微右 (+20)", "偏右 (+40)"},
                        new String[] {"-40", "-20", "居中", "+20", "+40"},
                        new int[] {-40, -20, 0, 20, 40},
                        0,
                        false));
        addSection(a, body, "字幕显示与调校", "点开全屏手势调校即可双指缩放字号、拖拽底距，边看效果边调整。", subRows);

        // Section ②: 在线字幕源
        boolean hasSubKeys =
                !a.secretsPrefs().getString(Prefs.SECRET_ASSRT_TOKEN, "").trim().isEmpty()
                        || !a.secretsPrefs()
                                .getString(Prefs.SECRET_OPENSUBTITLES_KEY, "")
                                .trim()
                                .isEmpty();
        addSection(
                a,
                body,
                "在线字幕源",
                "SubHD 无需配置即可使用；填入个人免费 Token 可解锁射手网与 OpenSubtitles 在线搜字幕。",
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_LINK,
                                        TINT_BLUE,
                                        "在线字幕搜刮凭据",
                                        hasSubKeys ? "已配置" : "未配置",
                                        () -> showOnlineSubtitleCredentialDialog(shell, sv)),
                                "ms-online-sub")));

        // Section ③: 弹幕样式与源管理
        List<View> dmRows = new ArrayList<>();
        dmRows.add(
                coreToggleRow(
                        a,
                        "ms-danmaku-def",
                        MobileIcons.IC_DANMAKU,
                        TINT_GREEN,
                        "播放时默认开启弹幕",
                        Prefs.DANMAKU_DEFAULT,
                        true,
                        () -> {
                            boolean on = a.prefs.getBoolean(Prefs.DANMAKU_DEFAULT, true);
                            DanmuSettingsPanel.DanmuConfig cur =
                                    DanmuSettingsPanel.loadConfig(a, false);
                            DanmuSettingsPanel.DanmuConfig.Builder b = cur.toBuilder();
                            b.enabled = on;
                            DanmuSettingsPanel.saveConfig(a, b.build());
                        }));
        dmRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_SLIDERS,
                                TINT_VIOLET,
                                "弹幕样式与关键词屏蔽",
                                DanmuSettingsPanel.formatCompactStatus(
                                        DanmuSettingsPanel.loadConfig(a, false)),
                                () -> {
                                    Dialog dlg = DanmuSettingsPanel.showDialog(a, false, null);
                                    dlg.setOnDismissListener(
                                            d -> {
                                                if (!a.isFinishing()
                                                        && (Build.VERSION.SDK_INT < 17
                                                                || !a.isDestroyed())) {
                                                    reloadPreservingScroll(shell, sv);
                                                }
                                            });
                                }),
                        "ms-danmu-panel"));
        dmRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-danmaku-style",
                        MobileIcons.IC_ASPECT,
                        TINT_BLUE,
                        "弹幕显示画面区域",
                        Prefs.DANMAKU_AREA,
                        new String[] {"顶部 1/4 屏 · 清爽", "半屏显示 · 推荐", "3/4 屏", "全屏铺满"},
                        new String[] {"1/4 屏", "半屏", "3/4 屏", "全屏"},
                        new int[] {0, 1, 2, 3},
                        1,
                        false));
        dmRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-danmaku-opacity",
                        MobileIcons.IC_BRIGHTNESS,
                        TINT_TEAL,
                        "弹幕文字透明度",
                        Prefs.DANMAKU_OPACITY,
                        new String[] {"40% · 轻柔半透", "65% · 适中", "85% · 清晰推荐", "100% · 完全不透明"},
                        new String[] {"40%", "65%", "85%", "100%"},
                        new int[] {40, 65, 85, 100},
                        85,
                        false));
        dmRows.add(
                mobileIntRow(
                        shell,
                        sv,
                        "ms-danmaku-speed",
                        MobileIcons.IC_SPEED,
                        TINT_AMBER,
                        "弹幕飘屏速度",
                        Prefs.DANMAKU_SPEED,
                        new String[] {"慢速舒缓", "标准速度", "快速略过"},
                        new String[] {"慢速", "标准", "快速"},
                        new int[] {0, 1, 2},
                        1,
                        false));
        List<OnlineSubtitleDanmakuService.DanmakuSource> dmList =
                OnlineSubtitleDanmakuService.loadDanmakuSources(a);
        dmRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_REFRESH,
                                TINT_CORAL,
                                "弹幕源管理与一键测速",
                                dmList.size() + " 个自建源",
                                () -> showDanmakuSourcesDialog(shell, sv)),
                        "ms-danmaku-src"));
        addSection(a, body, "弹幕样式与源管理", "内置支持弹弹Play 接口与自定义弹幕源，可一键测速自动把最快的源排在前面。", dmRows);
    }

    // =========================================================================
    // SUB 5: 刮削、网盘与 AI 助手 (Cluster 2 — 内容与观影)
    // =========================================================================
    private static void renderSubScrapingAccountsAndAi(
            MobileRootShell shell, LinearLayout body, final ScrollView sv) {
        final MainActivity a = shell.a;

        // Section ①: 网盘扫码授权
        int loggedDrives = AccountPanel.loggedDriveCount(a);
        int alistCount = AlistAccounts.list(a).size();
        List<View> driveRows = new ArrayList<>();
        driveRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_NETDISK,
                                TINT_BLUE,
                                "网盘扫码授权中心",
                                loggedDrives > 0 ? ("已登 " + loggedDrives + " 项") : "扫码授权",
                                () -> AccountPanel.show(a, null)),
                        "ms-netdisk"));
        driveRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_FOLDER,
                                TINT_GREEN,
                                "挂载个人 AList 网盘目录",
                                alistCount > 0 ? (alistCount + " 个挂载") : "未挂载",
                                () ->
                                        AlistAccounts.openManager(
                                                a, () -> reloadPreservingScroll(shell, sv))),
                        "ms-alist"));
        driveRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_LIVE,
                                TINT_VIOLET,
                                "连接 Emby 私有媒体库",
                                "直连挂载",
                                () -> EmbyEngine.connect(a)),
                        "ms-emby"));
        addSection(a, body, "网盘扫码授权", "登录夸克、UC、阿里、百度、115 等网盘账号后，即可直接播放网盘 4K 原画资源。", driveRows);

        // Section ②: 追剧日历账号
        String bgmUser = a.secretsPrefs().getString(Prefs.SECRET_BANGUMI_USERNAME, "").trim();
        String doubanCk = a.secretsPrefs().getString(Prefs.SECRET_DOUBAN_COOKIE, "").trim();
        int boundTrackers = (bgmUser.isEmpty() ? 0 : 1) + (doubanCk.isEmpty() ? 0 : 1);

        List<View> trackerRows = new ArrayList<>();
        trackerRows.add(
                tagged(
                        MobileSectionGroup.navRow(
                                a,
                                MobileIcons.IC_REPEAT,
                                TINT_GREEN,
                                "绑定 Bangumi / 豆瓣追剧账号",
                                boundTrackers > 0 ? ("已绑定 " + boundTrackers + " 项") : "未绑定",
                                () -> showTrackingAccountsDialog(shell, sv)),
                        "ms-bgm-trakt"));
        addSection(a, body, "追剧日历账号", "首页最近热门榜单开箱即用无需配置密钥；绑定 Bangumi 或豆瓣账号可同步个人追剧日历。", trackerRows);

        // Section ③: AI 观影实验室（内测口令开关）
        final AiBetaGate.VerifyResult aiBetaStatus = AiBetaGate.currentStatus(a);
        List<View> aiRows = new ArrayList<>();
        if (!aiBetaStatus.coreAiEnabled()) {
            aiRows.add(
                    tagged(
                            MobileSectionGroup.navRow(
                                    a,
                                    MobileIcons.IC_SPARKLE,
                                    TINT_VIOLET,
                                    "AI 观影实验室",
                                    "内测中 · 输入口令开启",
                                    () ->
                                            AiBetaGate.showUnlockSheet(
                                                    a, () -> reloadPreservingScroll(shell, sv))),
                            "ms-ai-lab-gate"));
            addSection(
                    a,
                    body,
                    "AI 观影实验室 (内测)",
                    "新一代 AI 观影实验室（双模式认证、全片双语字幕、防剧透剧情问答、AI 找片）处于限量测试阶段，未解锁前保持隐藏，凭作者签发口令离线开启。",
                    aiRows);
        } else {
            aiRows.add(
                    tagged(
                            MobileSectionGroup.navRow(
                                    a,
                                    MobileIcons.IC_SPARKLE,
                                    TINT_VIOLET,
                                    "内测通行状态",
                                    trimCompact(aiBetaStatus.summaryBadge(), 18),
                                    () -> showAiBetaStatusDialog(shell, sv, aiBetaStatus)),
                            "ms-ai-lab-gate"));
            aiRows.add(
                    mobileToggleRow(
                            a,
                            "ms-ai-enable",
                            MobileIcons.IC_SPARKLE,
                            TINT_VIOLET,
                            "启用 AI 观影助手",
                            Prefs.AI_ENABLED,
                            false,
                            null));
            aiRows.add(
                    tagged(
                            MobileSectionGroup.navRow(
                                    a,
                                    MobileIcons.IC_SLIDERS,
                                    TINT_BLUE,
                                    "AI 认证中心（API Key / 订阅账号）",
                                    trimCompact(AiAuthManager.activeSummaryLabel(a), 14),
                                    () -> showAiConfigDialog(shell, sv)),
                            "ms-ai-cfg"));
            aiRows.add(
                    tagged(
                            MobileSectionGroup.navRow(
                                    a,
                                    MobileIcons.IC_SEARCH,
                                    TINT_CORAL,
                                    "今晚看什么 · AI 找片",
                                    "自然语言选片",
                                    () ->
                                            AiCinemaCopilot.showDiscoverySheet(
                                                    a,
                                                    title -> {
                                                        if (title != null
                                                                && !title.trim().isEmpty()) {
                                                            MobileRootShell.openSearch(
                                                                    a, title.trim());
                                                        }
                                                    })),
                            "ms-ai-discovery"));
            aiRows.add(
                    mobileToggleRow(
                            a,
                            "ms-ai-translate-sub",
                            MobileIcons.IC_SUBTITLE,
                            TINT_AMBER,
                            "全片 AI 滑动窗口双语字幕",
                            Prefs.AI_TRANSLATE_SUB,
                            false,
                            null));
            aiRows.add(
                    mobileToggleRow(
                            a,
                            "ms-ai-clean-search",
                            MobileIcons.IC_SEARCH,
                            TINT_TEAL,
                            "AI 净化搜索结果片名",
                            Prefs.AI_CLEAN_SEARCH,
                            false,
                            null));
            aiRows.add(
                    mobileToggleRow(
                            a,
                            "ms-ai-py-audit",
                            MobileIcons.IC_PRIVACY,
                            TINT_ROSE,
                            "导入 Python 脚本时进行安全扫描",
                            Prefs.AI_PY_SECURITY_CHECK,
                            true,
                            null));
            addSection(
                    a,
                    body,
                    "AI 观影实验室 (内测已开启)",
                    "支持 API Key（DeepSeek / 通义 / 硅基流动 / Kimi / GLM / OpenAI / Claude / Gemini / OpenRouter / Ollama）及订阅账号 OAuth 登录；播放页「更多工具」可使用防剧透剧情与台词问答。",
                    aiRows);
        }
    }

    // =========================================================================
    // SUB 6: 云同步与隐私互联 (Cluster 3 — 互联与系统)
    // =========================================================================
    private static void renderSubSyncAndTvConnect(
            MobileRootShell shell,
            LinearLayout body,
            final ScrollView sv,
            String activeHighlightKey) {
        final MainActivity a = shell.a;

        // Section ①: 多端同步
        String webdavUrl = a.prefs.getString(Prefs.WEBDAV_URL, "").trim();
        boolean webdavAuto = a.prefs.getBoolean(Prefs.WEBDAV_AUTO, false);
        String syncStatus = webdavUrl.isEmpty() ? "未配置" : (webdavAuto ? "自动同步中" : "手动同步");
        addSection(
                a,
                body,
                "多端同步",
                "自动在手机、平板与电视之间同步观看进度与收藏夹，删除记录也会安全同步。",
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_CLOUD_SYNC,
                                        TINT_TEAL,
                                        "云盘多端自动同步 (WebDAV)",
                                        syncStatus,
                                        () ->
                                                CloudSyncDialog.show(
                                                        a,
                                                        () -> reloadPreservingScroll(shell, sv))),
                                "ms-cloud-sync"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SWITCH_SOURCE,
                                        TINT_BLUE,
                                        "同 Wi-Fi 设备局域网互传同步",
                                        "免云盘直传",
                                        () ->
                                                CloudSyncDialog.showLanConnectDialog(
                                                        a,
                                                        () -> reloadPreservingScroll(shell, sv))),
                                "ms-lan-sync")));

        // Section ②: 电视端互联
        addSection(
                a,
                body,
                "电视端互联",
                "同一 Wi-Fi 下可将手机片源一键推送给电视，或开启无线投屏发现客厅大屏设备。",
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_TV_LINK,
                                        TINT_BLUE,
                                        "扫码推送片源 / 辅助输入至电视",
                                        "推源 / 同步码",
                                        () -> EditionImpl.showMobileLanTransferSheet(a)),
                                "ms-push-tv"),
                        coreToggleRow(
                                a,
                                "ms-cast-enable",
                                MobileIcons.IC_CAST,
                                TINT_GREEN,
                                "局域网 DLNA 无线投屏",
                                Prefs.CAST_ENABLED,
                                true,
                                a::syncCastService)));

        // Section ③: 隐私保护
        addSection(
                a,
                body,
                "隐私保护",
                "使用 4 位数字口令开启独立隔离空间，私密片源、观看历史与收藏不会进入公开备份或云同步。",
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_PRIVACY,
                                        TINT_ROSE,
                                        a.privateMode ? "退出隐私空间（返回公开环境）" : "隐私空间与 4 位数字口令",
                                        a.privateMode ? "已开启" : "未进入",
                                        () -> PrivacySpace.openOrExit(a)),
                                "ms-privacy")));

        // Collapsible Section ④: 高级与调试选项 (progressive disclosure)
        boolean gwOn = a.prefs.getBoolean(Prefs.SPIDER_GATEWAY_ENABLED, false);
        boolean expandAdv =
                shouldAutoExpandAdvanced(
                        EXPANDED_ADVANCED.contains(MobileSettingsIndex.SUB_SYNC),
                        gwOn,
                        activeHighlightKey,
                        "ms-spider-gw");
        addCollapsibleAdvancedSection(
                a,
                body,
                MobileSettingsIndex.SUB_SYNC,
                expandAdv,
                gwOn,
                "仅当需要将本机已加载的爬虫扩展共享给同局域网内其他设备调用时才需开启 Spider 网关。",
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_LINK,
                                        TINT_VIOLET,
                                        "局域网远程爬虫网关 (Spider)",
                                        gwOn ? "运行中" : "已关闭",
                                        () ->
                                                SpiderGatewayDialog.show(
                                                        a,
                                                        () -> reloadPreservingScroll(shell, sv))),
                                "ms-spider-gw")));
    }

    // =========================================================================
    // SUB 7: 存储、备份与关于 (Cluster 3 — 互联与系统)
    // =========================================================================
    private static void renderSubStorageUpdateAndAbout(
            MobileRootShell shell, LinearLayout body, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);

        // Top Brand Aurora Header Card
        body.addView(buildAuroraBrandCard(a), sectionLayoutParams(a));

        // Section ①: 备份与恢复
        addSection(
                a,
                body,
                "备份与恢复",
                "备份文件包含片源、直播、收藏与外观偏好，不包含任何本机私密 API 密钥。",
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_DOWNLOAD,
                                        TINT_BLUE,
                                        "导出手机端配置备份",
                                        "JSON",
                                        () ->
                                                BackupManager.pickDocument(
                                                        a, 45, "application/json", true)),
                                "ms-backup-export"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_REFRESH,
                                        TINT_GREEN,
                                        "从备份文件恢复配置",
                                        "导入还原",
                                        () ->
                                                BackupManager.pickDocument(
                                                        a, 46, "application/json", false)),
                                "ms-backup-restore"),
                        tagged(
                                MobileSectionGroup.actionRow(
                                        a,
                                        MobileIcons.IC_REPEAT,
                                        TINT_ROSE,
                                        "恢复外观与播放默认设置",
                                        null,
                                        p.danger,
                                        () ->
                                                MobileBottomSheet.showConfirm(
                                                        a,
                                                        "恢复手机默认设置？",
                                                        "将恢复手机端外观与播放偏好为默认，不会删除收藏、历史与片源",
                                                        "恢复默认",
                                                        true,
                                                        () -> {
                                                            a.mobilePrefs().edit().clear().apply();
                                                            a.recreate();
                                                        })),
                                "ms-reset-mobile")));

        // Section ②: 缓存与空间管理
        long tmdbKb = TmdbService.cacheBytes(a) / 1024L;
        long aiKb = AiAssistantService.cacheBytes(a) / 1024L;
        long mediaBytes = estimateMediaCacheBytes(a);
        long mediaMb = mediaBytes / (1024L * 1024L);
        String cacheBadge =
                mediaMb > 0
                        ? (mediaMb + " MB")
                        : ((tmdbKb + aiKb) > 0 ? ((tmdbKb + aiKb) + " KB") : "轻盈");
        addSection(
                a,
                body,
                "缓存与空间管理",
                "临时缓存可随时安全释放；清空搜索或观看历史等个人记录前会弹出二次确认，避免误删。",
                Arrays.<View>asList(
                        coreIntRow(
                                shell,
                                sv,
                                "ms-disk-cache",
                                MobileIcons.IC_STORAGE,
                                TINT_AMBER,
                                "边播边存视频缓存上限",
                                Prefs.MEDIA_CACHE_MB,
                                new String[] {
                                    "关闭磁盘视频缓存", "128 MB", "256 MB · 推荐", "512 MB", "1024 MB"
                                },
                                new String[] {"关闭", "128 MB", "256 MB", "512 MB", "1024 MB"},
                                new int[] {0, 128, 256, 512, 1024},
                                256,
                                false),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_TRASH,
                                        TINT_ROSE,
                                        "清理缓存与个人观看记录",
                                        cacheBadge,
                                        () ->
                                                showCacheCleanupSheet(
                                                        shell, sv, tmdbKb, aiKb, mediaMb)),
                                "ms-clear-caches")));

        // Section ③: 联系与反馈作者
        addSection(
                a,
                body,
                "联系与反馈作者",
                "各平台统一账号名："
                        + MobileAuthorNotice.AUTHOR_SOCIAL_FULL
                        + "。"
                        + MobileAuthorNotice.OFFICIAL_DOWNLOAD_WARNING,
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SPARKLE,
                                        TINT_BLUE,
                                        "各社媒账号名",
                                        MobileAuthorNotice.AUTHOR_SOCIAL_NAME,
                                        () -> MobileAuthorNotice.showContactSheet(a)),
                                "ms-author-social"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_LINK,
                                        TINT_TEAL,
                                        "官网交流频道",
                                        MobileAuthorNotice.OFFICIAL_CHANNEL_NAME,
                                        () ->
                                                MobileAuthorNotice.openOfficialUrl(
                                                        a,
                                                        MobileAuthorNotice.OFFICIAL_CHANNEL_URL,
                                                        "官网交流频道")),
                                "ms-official-channel"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_EXTERNAL,
                                        TINT_GREEN,
                                        "Marco 官网",
                                        MobileAuthorNotice.OFFICIAL_SITE_DISPLAY,
                                        () ->
                                                MobileAuthorNotice.openOfficialUrl(
                                                        a,
                                                        MobileAuthorNotice.OFFICIAL_SITE_URL,
                                                        "Marco 官网")),
                                "ms-official-site"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_HEART_FILLED,
                                        TINT_ROSE,
                                        "捐赠支持",
                                        "请作者喝杯咖啡",
                                        () ->
                                                MobileAuthorNotice.openOfficialUrl(
                                                        a,
                                                        MobileAuthorNotice.OFFICIAL_DONATE_URL,
                                                        "官网捐赠区")),
                                "ms-official-donate")));

        // Section ④: 诊断与关于
        int crashCount = CrashReportStore.loadReports(a.getFilesDir()).size();
        addSection(
                a,
                body,
                "诊断与关于",
                "手机端采用独立 android-mobile 更新通道，与电视端版本互不干扰。",
                Arrays.<View>asList(
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_CLOUD_SYNC,
                                        TINT_BLUE,
                                        "检查软件更新（手机端通道）",
                                        "v" + UpdateManager.installedVersion(a),
                                        () ->
                                                a.open(
                                                        new MainActivity.Screen(
                                                                () -> new UpdateScreen(a).show()),
                                                        true)),
                                "ms-updates"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_INFO,
                                        TINT_CORAL,
                                        "查看历史异常退出报告",
                                        crashCount > 0 ? (crashCount + " 条") : "无异常",
                                        () -> CrashReportDialog.show(a, true)),
                                "ms-crash-reports"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SLIDERS,
                                        TINT_SLATE,
                                        "查看运行诊断日志",
                                        "诊断",
                                        () -> showDiagnosticLogsDialog(a)),
                                "ms-logs"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_SPARKLE,
                                        TINT_VIOLET,
                                        "重新查看新手引导",
                                        "交互导览",
                                        () -> {
                                            OnboardingScreen.resetForReplay(a);
                                            a.showOnboarding(true);
                                        }),
                                "ms-replay-onboarding"),
                        tagged(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_INFO,
                                        TINT_TEAL,
                                        "开源许可与版本信息",
                                        "GPL-3.0",
                                        () -> showOpenSourceDialog(a)),
                                "ms-licenses")));
    }

    private static FrameLayout buildAuroraBrandCard(MainActivity a) {
        FrameLayout card = new FrameLayout(a);
        card.setBackground(a.bg(0xFF0C101B, 18));
        card.setMinimumHeight(a.dp(118));
        if (Build.VERSION.SDK_INT >= 21) {
            card.setOutlineProvider(ViewOutlineProvider.BACKGROUND);
            UiCompat.setClipToOutline(card, true);
        }

        AuroraSurfaceView aurora = new AuroraSurfaceView(a);
        aurora.setReducedMotion(MobileMotion.isReduced(a));
        card.addView(aurora, new FrameLayout.LayoutParams(-1, -1));

        View scrim = new View(a);
        scrim.setBackgroundColor(0x42000000);
        card.addView(scrim, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout content = a.vertical();
        content.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));

        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView name = a.text("Marco Movie", 19f, Color.WHITE);
        name.setTypeface(null, Typeface.BOLD);
        titleRow.addView(name, new LinearLayout.LayoutParams(-2, -2));

        TextView badge = a.text("MOBILE · v" + UpdateManager.installedVersion(a), 11f, Color.WHITE);
        badge.setTypeface(null, Typeface.BOLD);
        badge.setPadding(a.dp(9), a.dp(3), a.dp(9), a.dp(3));
        badge.setBackground(a.bg(0x30FFFFFF, 999));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(-2, -2);
        badgeLp.leftMargin = a.dp(10);
        titleRow.addView(badge, badgeLp);
        content.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));

        a.gap(content, 6);
        TextView tagline = a.text("纯净原生移动端影音播放器 · GPL-3.0", 12.5f, 0xE2E8F0FF);
        content.addView(tagline, new LinearLayout.LayoutParams(-1, -2));

        a.gap(content, 8);
        TextView decl = a.text(MainActivity.TOOL_DECLARATION, 11.5f, 0xBDD6DFEE);
        decl.setLineSpacing(a.dp(2.5f), 1f);
        content.addView(decl, new LinearLayout.LayoutParams(-1, -2));

        card.addView(content, new FrameLayout.LayoutParams(-1, -2));
        return card;
    }

    /**
     * Two-tier cache & personal-data cleanup sheet: safe temporary caches execute cleanly in 1 tap,
     * while every destructive personal-data clear is visually separated in danger red and guarded
     * behind {@link MobileBottomSheet#showConfirm}.
     */
    private static void showCacheCleanupSheet(
            final MobileRootShell shell,
            final ScrollView sv,
            long tmdbKb,
            long aiKb,
            long mediaMb) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];

        LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(4), 0, a.dp(4));

        // Safe temporary caches (zero personal data impact)
        List<View> safeRows = new ArrayList<>();
        safeRows.add(
                MobileSectionGroup.actionRow(
                        a,
                        MobileIcons.IC_PALETTE,
                        TINT_BLUE,
                        "清理图片与首页快照缓存",
                        "安全",
                        p.textPrimary,
                        () -> {
                            a.images.evictAll();
                            a.homeData.clear();
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            a.toast("已清理图片与首页快照缓存");
                            reloadPreservingScroll(shell, sv);
                        }));
        safeRows.add(
                MobileSectionGroup.actionRow(
                        a,
                        MobileIcons.IC_STORAGE,
                        TINT_AMBER,
                        "清理边播边存视频缓存",
                        mediaMb + " MB",
                        p.textPrimary,
                        () -> {
                            a.worker.execute(() -> clearMediaDiskCache(a));
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            a.toast("已清理边播边存视频缓存");
                            reloadPreservingScroll(shell, sv);
                        }));
        safeRows.add(
                MobileSectionGroup.actionRow(
                        a,
                        MobileIcons.IC_SPARKLE,
                        TINT_VIOLET,
                        "清理推荐榜单与 AI 临时缓存",
                        (tmdbKb + aiKb) + " KB",
                        p.textPrimary,
                        () -> {
                            MobileCuratedDiscovery.clearCache();
                            TmdbService.clearCache(a);
                            AiAssistantService.clearCache(a);
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            a.toast("已清理推荐榜单与 AI 临时缓存");
                            reloadPreservingScroll(shell, sv);
                        }));
        safeRows.add(
                MobileSectionGroup.actionRow(
                        a,
                        MobileIcons.IC_REFRESH,
                        TINT_GREEN,
                        "一键清理全部临时缓存",
                        null,
                        p.accent,
                        () -> {
                            a.images.evictAll();
                            a.homeData.clear();
                            MobileCuratedDiscovery.clearCache();
                            a.worker.execute(() -> clearMediaDiskCache(a));
                            TmdbService.clearCache(a);
                            AiAssistantService.clearCache(a);
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            a.toast("已清理全部临时缓存");
                            reloadPreservingScroll(shell, sv);
                        }));
        addSection(a, content, "临时缓存（可安全清理）", "仅释放自动生成的图片与分块缓存，不会删除收藏夹、观看进度或离线下载影片。", safeRows);

        // Destructive personal data & diagnostics (spatially separated + guarded by showConfirm)
        List<View> dangerRows = new ArrayList<>();
        dangerRows.add(
                MobileSectionGroup.actionRow(
                        a,
                        MobileIcons.IC_SEARCH,
                        TINT_ROSE,
                        "清空搜索历史",
                        null,
                        p.danger,
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            MobileBottomSheet.showConfirm(
                                    a,
                                    "清空全部搜索历史？",
                                    "将永久清除本机保存的所有搜索关键词记录，此操作无法撤销。",
                                    "清空搜索历史",
                                    true,
                                    () -> {
                                        a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                        a.toast("已清空搜索历史");
                                        reloadPreservingScroll(shell, sv);
                                    });
                        }));
        dangerRows.add(
                MobileSectionGroup.actionRow(
                        a,
                        MobileIcons.IC_HISTORY,
                        TINT_ROSE,
                        "清空观看历史",
                        null,
                        p.danger,
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            MobileBottomSheet.showConfirm(
                                    a,
                                    "清空全部观看历史？",
                                    "将清空全部观看进度并同步记录云端删除标记，不会影响你的收藏夹与片源。",
                                    "清空观看历史",
                                    true,
                                    () ->
                                            CloudSyncDialog.clearHistoryWithTombstone(
                                                    a,
                                                    () -> {
                                                        a.toast("已清空观看历史记录");
                                                        reloadPreservingScroll(shell, sv);
                                                    }));
                        }));
        dangerRows.add(
                MobileSectionGroup.actionRow(
                        a,
                        MobileIcons.IC_TRASH,
                        TINT_ROSE,
                        "清空诊断日志与崩溃报告",
                        null,
                        p.danger,
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            MobileBottomSheet.showConfirm(
                                    a,
                                    "清空诊断日志与崩溃报告？",
                                    "将删除所有已记录的运行日志与异常退出堆栈，此操作无法撤销。",
                                    "确认清空",
                                    true,
                                    () -> {
                                        AppLog.clear();
                                        CrashReportStore.clearAll(a.getFilesDir());
                                        a.toast("已清空诊断日志与崩溃报告");
                                        reloadPreservingScroll(shell, sv);
                                    });
                        }));
        addSection(a, content, "个人记录与诊断数据", "以下操作会清除历史或日志记录，点击后将再次确认，防止误碰丢失。", dangerRows);

        handleRef[0] =
                MobileBottomSheet.showHandle(
                        a, "清理缓存与记录", "临时缓存可放心一键清理，个人记录需二次确认", null, null, content, true);
    }

    private static void showDiagnosticLogsDialog(MainActivity a) {
        MobileTheme.Palette p = MobileTheme.of(a);
        String dump = AppLog.dump();
        LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(4), 0, a.dp(4));

        TextView logBox = a.text(dump.isEmpty() ? "当前运行正常，暂无异常日志。" : dump, 12f, p.textSecondary);
        logBox.setTypeface(Typeface.MONOSPACE);
        logBox.setLineSpacing(a.dp(3), 1f);
        logBox.setTextIsSelectable(true);
        logBox.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(12));
        logBox.setBackground(MobileTheme.subtleBg(a, 14));
        content.addView(logBox, new LinearLayout.LayoutParams(-1, -2));

        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];
        hRef[0] =
                MobileBottomSheet.showHandle(
                        a,
                        "运行诊断日志",
                        dump.isEmpty() ? "运行状态健康" : "长按文本可复制排查信息",
                        dump.isEmpty() ? null : "清空日志",
                        dump.isEmpty()
                                ? null
                                : () -> {
                                    if (hRef[0] != null) hRef[0].dismiss();
                                    MobileBottomSheet.showConfirm(
                                            a,
                                            "清空运行诊断日志？",
                                            "清空后将无法查看本次会话之前记录的诊断信息。",
                                            "清空日志",
                                            true,
                                            () -> {
                                                AppLog.clear();
                                                a.toast("已清空诊断日志");
                                            });
                                },
                        content,
                        true);
    }

    private static void showOpenSourceDialog(MainActivity a) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(4), 0, a.dp(4));

        LinearLayout infoCard = a.vertical();
        infoCard.setPadding(a.dp(14), a.dp(14), a.dp(14), a.dp(14));
        infoCard.setBackground(MobileTheme.subtleBg(a, 16));

        TextView ver =
                a.text(
                        "Marco Movie Mobile v" + UpdateManager.installedVersion(a),
                        15f,
                        p.textPrimary);
        ver.setTypeface(null, Typeface.BOLD);
        infoCard.addView(ver);
        a.gap(infoCard, 6);

        TextView meta =
                a.text(
                        "通道标识：android-mobile（与电视端独立演进）\n"
                                + "开源协议：GNU General Public License v3.0 (GPL-3.0)\n"
                                + "核心组件：AndroidX Media3、libmpv、QuickJS、CPython 3.11、ZXing",
                        12.5f,
                        p.textSecondary);
        meta.setLineSpacing(a.dp(3.5f), 1f);
        infoCard.addView(meta);
        content.addView(infoCard, new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        TextView decl = a.text(MainActivity.TOOL_DECLARATION, 12f, p.textSecondary);
        decl.setLineSpacing(a.dp(3f), 1f);
        decl.setPadding(a.dp(4), 0, a.dp(4), a.dp(4));
        content.addView(decl, new LinearLayout.LayoutParams(-1, -2));

        MobileBottomSheet.showHandle(a, "开源许可与版本信息", "纯净原生移动端影音播放器", null, null, content, true);
    }

    // =========================================================================
    // CONFIGURATION DIALOGS & SHEETS (FULL DAY / NIGHT MOBILETHEME)
    // =========================================================================
    private static void showAiBetaStatusDialog(
            final MobileRootShell shell, final ScrollView sv, AiBetaGate.VerifyResult status) {
        final MainActivity a = shell.a;
        String[] options = {"更换新内测口令", "退出 AI 观影实验室测试（重新锁定）"};
        MobileBottomSheet.showPicker(
                a,
                "AI 观影实验室通行证",
                status.summaryBadge(),
                options,
                -1,
                sel -> {
                    if (sel == 0) {
                        AiBetaGate.showUnlockSheet(a, () -> reloadPreservingScroll(shell, sv));
                    } else if (sel == 1) {
                        MobileBottomSheet.showConfirm(
                                a,
                                "退出 AI 观影实验室？",
                                "将清除当前内测口令并隐藏搜索页与播放页的 AI 测试入口（你已保存的 API Key 与账号配置可随时重新解锁后恢复）。",
                                "退出内测",
                                true,
                                () -> {
                                    AiBetaGate.deactivate(a);
                                    a.toast("已退出 AI 观影实验室测试");
                                    reloadPreservingScroll(shell, sv);
                                });
                    }
                });
    }

    private static void showAiConfigDialog(final MobileRootShell shell, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final SharedPreferences mp = a.mobilePrefs();
        final SharedPreferences sec = a.secretsPrefs();

        LinearLayout form = a.vertical();
        form.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        // Dual-mode segmented switch: API Key (BYOK) vs Subscription / OAuth Sign-In
        final String[] curMode = {AiAuthManager.authMode(a)};
        LinearLayout segRow = a.row();
        segRow.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
        segRow.setBackground(a.bg(p.bgSubtle, 14));
        final TextView apiTabBtn = a.text("API 密钥 (BYOK)", 13f, p.textPrimary);
        apiTabBtn.setTypeface(null, Typeface.BOLD);
        apiTabBtn.setGravity(Gravity.CENTER);
        apiTabBtn.setPadding(a.dp(8), a.dp(9), a.dp(8), a.dp(9));
        final TextView oauthTabBtn = a.text("订阅账号登录 (OAuth)", 13f, p.textPrimary);
        oauthTabBtn.setTypeface(null, Typeface.BOLD);
        oauthTabBtn.setGravity(Gravity.CENTER);
        oauthTabBtn.setPadding(a.dp(8), a.dp(9), a.dp(8), a.dp(9));
        segRow.addView(apiTabBtn, new LinearLayout.LayoutParams(0, -2, 1f));
        segRow.addView(oauthTabBtn, new LinearLayout.LayoutParams(0, -2, 1f));
        form.addView(segRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(form, 12);

        // --- Pane A: API Key Mode ---
        final LinearLayout apiPane = a.vertical();
        final String[] curProv = {mp.getString(Prefs.AI_PROVIDER, "deepseek")};
        final TextView[] provTextHolder = new TextView[1];
        final EditText[] baseHolder = new EditText[1];
        final EditText[] modelHolder = new EditText[1];

        LinearLayout provBtn =
                buildDropdownButton(
                        a,
                        "服务商：" + AiAssistantService.providerLabel(curProv[0]),
                        provTextHolder,
                        () -> {
                            int idx =
                                    Arrays.asList(AiAssistantService.PROVIDER_IDS)
                                            .indexOf(curProv[0]);
                            MobileBottomSheet.showPicker(
                                    a,
                                    "选择 AI 大模型服务商",
                                    "原生支持 OpenAI 兼容、Anthropic Claude 与 Google Gemini 协议",
                                    AiAssistantService.PROVIDER_LABELS,
                                    Math.max(0, idx),
                                    sel -> {
                                        curProv[0] = AiAssistantService.PROVIDER_IDS[sel];
                                        provTextHolder[0].setText(
                                                "服务商："
                                                        + AiAssistantService.providerLabel(
                                                                curProv[0]));
                                        if (baseHolder[0] != null) {
                                            baseHolder[0].setHint(
                                                    AiAssistantService.defaultBaseUrl(curProv[0]));
                                        }
                                        if (modelHolder[0] != null) {
                                            modelHolder[0].setHint(
                                                    AiAssistantService.defaultModel(curProv[0]));
                                        }
                                    });
                        });
        apiPane.addView(provBtn, new LinearLayout.LayoutParams(-1, -2));
        a.gap(apiPane, 12);

        final EditText keyInput =
                formField(
                        a,
                        apiPane,
                        "API Key（本地 Ollama 可留空；仅存本机私有偏好，不随备份或云同步上传）",
                        "sk-…",
                        sec.getString(Prefs.SECRET_AI_API_KEY, ""),
                        true);
        final EditText baseInput =
                formField(
                        a,
                        apiPane,
                        "接口地址 Base URL（留空使用官方默认端点，也可填个人中转网关）",
                        AiAssistantService.defaultBaseUrl(curProv[0]),
                        mp.getString(Prefs.AI_BASE_URL, ""),
                        false);
        final EditText modelInput =
                formField(
                        a,
                        apiPane,
                        "模型名称 Model（留空使用推荐默认模型）",
                        AiAssistantService.defaultModel(curProv[0]),
                        mp.getString(Prefs.AI_MODEL, ""),
                        false);
        baseHolder[0] = baseInput;
        modelHolder[0] = modelInput;
        form.addView(apiPane, new LinearLayout.LayoutParams(-1, -2));

        // --- Pane B: OAuth / Subscription Sign-In Mode ---
        final LinearLayout oauthPane = a.vertical();
        final String[] curOAuthProv = {AiAuthManager.activeOAuthProvider(a)};
        final EditText[] oauthModelHolder = new EditText[1];
        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];

        final Runnable[] rebuildOAuthCards = new Runnable[1];
        final LinearLayout oauthCardsBox = a.vertical();
        oauthPane.addView(oauthCardsBox, new LinearLayout.LayoutParams(-1, -2));
        a.gap(oauthPane, 10);

        final EditText oauthModelInput =
                formField(
                        a,
                        oauthPane,
                        "当前订阅账号使用的模型名（留空使用推荐默认模型）",
                        AiAuthManager.defaultOAuthModel(curOAuthProv[0]),
                        AiAuthManager.resolveOAuthModel(a, curOAuthProv[0]),
                        false);
        oauthModelHolder[0] = oauthModelInput;

        rebuildOAuthCards[0] =
                () -> {
                    oauthCardsBox.removeAllViews();
                    boolean allowExp = AiBetaGate.isExperimentalOAuthAllowed(a);
                    for (int i = 0; i < AiAuthManager.OAUTH_PROVIDER_IDS.length; i++) {
                        final String provId = AiAuthManager.OAUTH_PROVIDER_IDS[i];
                        final String label = AiAuthManager.OAUTH_PROVIDER_LABELS[i];
                        final boolean isExp =
                                AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL.equals(provId);
                        final boolean selected = provId.equals(curOAuthProv[0]);
                        final AiAuthManager.OAuthBundle bundle =
                                AiAuthManager.loadBundle(a, provId);

                        LinearLayout card = a.vertical();
                        card.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
                        card.setBackground(
                                a.bg(
                                        selected
                                                ? MobileTheme.withAlpha(
                                                        p.accent, p.isDark ? 0x28 : 0x16)
                                                : p.bgSubtle,
                                        14));
                        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-1, -2);
                        if (i > 0) clp.topMargin = a.dp(8);

                        LinearLayout top = a.row();
                        top.setGravity(Gravity.CENTER_VERTICAL);
                        TextView titleTv = a.text(label, 13.5f, p.textPrimary);
                        titleTv.setTypeface(null, Typeface.BOLD);
                        top.addView(titleTv, new LinearLayout.LayoutParams(0, -2, 1f));
                        if (selected) {
                            TextView selTag = a.text("当前选用", 11f, p.accent);
                            selTag.setTypeface(null, Typeface.BOLD);
                            top.addView(selTag);
                        }
                        card.addView(top, new LinearLayout.LayoutParams(-1, -2));
                        a.gap(card, 4);

                        String subStr;
                        int subColor = p.textSecondary;
                        if (isExp && !allowExp) {
                            subStr = "当前内测口令未包含实验性 OAuth 权限";
                        } else if (bundle != null && bundle.hasCredential()) {
                            subStr = bundle.statusSummary();
                            if (bundle.needsReauth) subColor = p.danger;
                        } else if (AiAuthManager.OAUTH_OPENROUTER.equals(provId)) {
                            subStr = "未登录 · 官方 PKCE 浏览器一键授权，无需手动复制 Key";
                        } else if (AiAuthManager.OAUTH_KIMI_CODE.equals(provId)) {
                            subStr = "未登录 · 标准 RFC 8628 设备码登录，自动刷新令牌";
                        } else {
                            subStr = "未登录 · 官方 OAuth PKCE（需同意实验性风险提示）";
                        }
                        TextView stTv = a.text(subStr, 12f, subColor);
                        stTv.setLineSpacing(a.dp(2f), 1f);
                        card.addView(stTv);

                        if (!isExp || allowExp) {
                            a.gap(card, 8);
                            LinearLayout btnRow = a.row();
                            TextView loginBtn =
                                    a.text(
                                            bundle != null && bundle.hasCredential()
                                                    ? (bundle.needsReauth ? "重新登录" : "切换为当前")
                                                    : "立即登录",
                                            12f,
                                            p.accentOnFill);
                            loginBtn.setTypeface(null, Typeface.BOLD);
                            loginBtn.setGravity(Gravity.CENTER);
                            loginBtn.setPadding(a.dp(12), a.dp(7), a.dp(12), a.dp(7));
                            loginBtn.setBackground(MobileTheme.accentPillBg(a, 10));
                            MobileMotion.bindPress(loginBtn, 0.94f);
                            loginBtn.setOnClickListener(
                                    v -> {
                                        curOAuthProv[0] = provId;
                                        AiAuthManager.setActiveOAuthProvider(a, provId);
                                        if (oauthModelHolder[0] != null) {
                                            oauthModelHolder[0].setHint(
                                                    AiAuthManager.defaultOAuthModel(provId));
                                            oauthModelHolder[0].setText(
                                                    AiAuthManager.resolveOAuthModel(a, provId));
                                        }
                                        if (bundle != null
                                                && bundle.hasCredential()
                                                && !bundle.needsReauth) {
                                            rebuildOAuthCards[0].run();
                                            a.toast("已切换为：" + label);
                                            return;
                                        }
                                        AiAssistantService.ResultCallback<AiAuthManager.OAuthBundle>
                                                doneCb =
                                                        b -> {
                                                            curOAuthProv[0] = provId;
                                                            curMode[0] =
                                                                    AiAuthManager.AUTH_MODE_OAUTH;
                                                            rebuildOAuthCards[0].run();
                                                            reloadPreservingScroll(shell, sv);
                                                        };
                                        if (AiAuthManager.OAUTH_OPENROUTER.equals(provId)) {
                                            AiAuthManager.startOpenRouterSignIn(a, doneCb);
                                        } else if (AiAuthManager.OAUTH_KIMI_CODE.equals(provId)) {
                                            AiAuthManager.startKimiCodeDeviceSignIn(a, doneCb);
                                        } else {
                                            AiAuthManager.startOpenAiExperimentalSignIn(a, doneCb);
                                        }
                                    });
                            btnRow.addView(loginBtn, new LinearLayout.LayoutParams(-2, -2));

                            if (bundle != null && bundle.hasCredential()) {
                                TextView signOutBtn = a.text("退出登录", 12f, p.danger);
                                signOutBtn.setTypeface(null, Typeface.BOLD);
                                signOutBtn.setPadding(a.dp(12), a.dp(7), a.dp(12), a.dp(7));
                                MobileMotion.bindPress(signOutBtn, 0.94f);
                                signOutBtn.setOnClickListener(
                                        v -> {
                                            AiAuthManager.signOutOAuth(a, provId);
                                            a.toast("已退出 " + label);
                                            rebuildOAuthCards[0].run();
                                            reloadPreservingScroll(shell, sv);
                                        });
                                LinearLayout.LayoutParams soLp =
                                        new LinearLayout.LayoutParams(-2, -2);
                                soLp.leftMargin = a.dp(8);
                                btnRow.addView(signOutBtn, soLp);
                            }
                            card.addView(btnRow);
                        }

                        oauthCardsBox.addView(card, clp);
                    }
                };
        rebuildOAuthCards[0].run();
        form.addView(oauthPane, new LinearLayout.LayoutParams(-1, -2));

        final Runnable syncModeUi =
                () -> {
                    boolean isOAuth = AiAuthManager.AUTH_MODE_OAUTH.equals(curMode[0]);
                    apiTabBtn.setBackground(!isOAuth ? MobileTheme.accentPillBg(a, 10) : null);
                    apiTabBtn.setTextColor(!isOAuth ? p.accentOnFill : p.textSecondary);
                    oauthTabBtn.setBackground(isOAuth ? MobileTheme.accentPillBg(a, 10) : null);
                    oauthTabBtn.setTextColor(isOAuth ? p.accentOnFill : p.textSecondary);
                    apiPane.setVisibility(isOAuth ? View.GONE : View.VISIBLE);
                    oauthPane.setVisibility(isOAuth ? View.VISIBLE : View.GONE);
                };
        apiTabBtn.setOnClickListener(
                v -> {
                    curMode[0] = AiAuthManager.AUTH_MODE_API_KEY;
                    syncModeUi.run();
                });
        oauthTabBtn.setOnClickListener(
                v -> {
                    curMode[0] = AiAuthManager.AUTH_MODE_OAUTH;
                    rebuildOAuthCards[0].run();
                    syncModeUi.run();
                });
        syncModeUi.run();

        final Runnable persist =
                () -> {
                    AiAuthManager.setAuthMode(a, curMode[0]);
                    if (AiAuthManager.AUTH_MODE_OAUTH.equals(curMode[0])) {
                        AiAuthManager.setActiveOAuthProvider(a, curOAuthProv[0]);
                        AiAuthManager.saveOAuthModel(
                                a, curOAuthProv[0], oauthModelInput.getText().toString().trim());
                        AiAuthManager.OAuthBundle b = AiAuthManager.loadBundle(a, curOAuthProv[0]);
                        mp.edit()
                                .putBoolean(
                                        Prefs.AI_ENABLED,
                                        b != null && b.hasCredential() && !b.needsReauth)
                                .apply();
                    } else {
                        String keyVal = keyInput.getText().toString().trim();
                        String baseVal = baseInput.getText().toString().trim();
                        sec.edit().putString(Prefs.SECRET_AI_API_KEY, keyVal).apply();
                        mp.edit()
                                .putBoolean(
                                        Prefs.AI_ENABLED,
                                        !keyVal.isEmpty() || "ollama".equals(curProv[0]))
                                .putString(Prefs.AI_PROVIDER, curProv[0])
                                .putString(
                                        Prefs.AI_BASE_URL,
                                        baseVal.isEmpty() || Prefs.sanitizeHttpUrl(baseVal) == null
                                                ? ""
                                                : baseVal)
                                .putString(Prefs.AI_MODEL, modelInput.getText().toString().trim())
                                .apply();
                    }
                };

        LinearLayout footerRow = a.row();
        footerRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView testBtn =
                buildSheetActionPill(
                        a,
                        p,
                        "测试连接",
                        false,
                        () -> {
                            persist.run();
                            a.toast("正在测试 AI 模型连通性…");
                            AiAssistantService.testConnectionAsync(a, a::toast);
                        });
        TextView saveBtn =
                buildSheetActionPill(
                        a,
                        p,
                        "保存启用",
                        true,
                        () -> {
                            persist.run();
                            if (hRef[0] != null) hRef[0].dismiss();
                            a.toast("AI 认证中心配置已保存");
                            reloadPreservingScroll(shell, sv);
                        });
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0, a.dp(44), 1f);
        tlp.rightMargin = a.dp(8);
        footerRow.addView(testBtn, tlp);
        footerRow.addView(saveBtn, new LinearLayout.LayoutParams(0, a.dp(44), 1.3f));
        a.gap(form, 12);
        form.addView(footerRow, new LinearLayout.LayoutParams(-1, -2));

        hRef[0] =
                MobileBottomSheet.showHandle(
                        a,
                        "AI 认证中心",
                        "支持 BYOK API Key 与 OpenRouter / Kimi Code 订阅账号登录",
                        null,
                        null,
                        form,
                        true);
    }

    private static void showTrackingAccountsDialog(
            final MobileRootShell shell, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final SharedPreferences sec = a.secretsPrefs();
        LinearLayout form = a.vertical();
        form.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        final EditText bgmUser =
                formField(
                        a,
                        form,
                        "Bangumi 用户名 / UID（同步「在看」番剧列表）",
                        "例如：sai",
                        sec.getString(Prefs.SECRET_BANGUMI_USERNAME, ""),
                        false);
        final EditText bgmToken =
                formField(
                        a,
                        form,
                        "Bangumi Access Token（可选，读取私有收藏需要）",
                        "Bearer Token",
                        sec.getString(Prefs.SECRET_BANGUMI_TOKEN, ""),
                        true);
        final EditText doubanCookie =
                formField(
                        a,
                        form,
                        "豆瓣 Cookie（可选，用于同步豆瓣个人在看与想看）",
                        "dbcl2=…",
                        sec.getString(Prefs.SECRET_DOUBAN_COOKIE, ""),
                        true);

        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];
        Runnable onSave =
                () -> {
                    sec.edit()
                            .putString(
                                    Prefs.SECRET_BANGUMI_USERNAME,
                                    bgmUser.getText().toString().trim())
                            .putString(
                                    Prefs.SECRET_BANGUMI_TOKEN,
                                    bgmToken.getText().toString().trim())
                            .putString(
                                    Prefs.SECRET_DOUBAN_COOKIE,
                                    doubanCookie.getText().toString().trim())
                            .apply();
                    if (hRef[0] != null) hRef[0].dismiss();
                    a.toast("追剧账号已保存");
                    reloadPreservingScroll(shell, sv);
                };
        a.gap(form, 4);
        form.addView(
                buildSheetActionPill(a, p, "保存追剧账号", true, onSave),
                new LinearLayout.LayoutParams(-1, a.dp(44)));

        hRef[0] =
                MobileBottomSheet.showHandle(
                        a, "追剧账号配置", "仅保存在本机，用于同步个人在看追剧日历", "保存", onSave, form, true);
    }

    private static void showOnlineSubtitleCredentialDialog(
            final MobileRootShell shell, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final SharedPreferences sec = a.secretsPrefs();
        LinearLayout form = a.vertical();
        form.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        TextView note =
                a.text(
                        "SubHD 免密钥可用；下方填写个人免费 Token 可启用射手网与 OpenSubtitles 在线检索。",
                        12f,
                        p.textSecondary);
        note.setLineSpacing(a.dp(2f), 1f);
        form.addView(note);
        a.gap(form, 10);

        final EditText assrt =
                formField(
                        a,
                        form,
                        "射手网(伪) Assrt API Token (assrt.net 个人中心获取)",
                        "32位 Token",
                        sec.getString(Prefs.SECRET_ASSRT_TOKEN, ""),
                        true);
        final EditText osKey =
                formField(
                        a,
                        form,
                        "OpenSubtitles REST v1 API Key (opensubtitles.com)",
                        "API Key",
                        sec.getString(Prefs.SECRET_OPENSUBTITLES_KEY, ""),
                        true);

        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];
        Runnable onSave =
                () -> {
                    sec.edit()
                            .putString(Prefs.SECRET_ASSRT_TOKEN, assrt.getText().toString().trim())
                            .putString(
                                    Prefs.SECRET_OPENSUBTITLES_KEY,
                                    osKey.getText().toString().trim())
                            .apply();
                    if (hRef[0] != null) hRef[0].dismiss();
                    a.toast("在线字幕凭据已保存在本机");
                    reloadPreservingScroll(shell, sv);
                };
        a.gap(form, 4);
        form.addView(
                buildSheetActionPill(a, p, "保存凭据", true, onSave),
                new LinearLayout.LayoutParams(-1, a.dp(44)));

        hRef[0] =
                MobileBottomSheet.showHandle(
                        a, "在线字幕站凭据", "仅保存在本机，用于解锁射手网与 OpenSubtitles", "保存", onSave, form, true);
    }

    private static void showDanmakuSourcesDialog(final MobileRootShell shell, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final List<OnlineSubtitleDanmakuService.DanmakuSource> list =
                OnlineSubtitleDanmakuService.loadDanmakuSources(a);
        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        if (list.isEmpty()) {
            box.addView(a.text("尚未添加自定义 LogVar 兼容弹幕源（默认使用弹弹Play 搜索接口）。", 12.5f, p.textSecondary));
        } else {
            for (int i = 0; i < list.size(); i++) {
                final int idx = i;
                final OnlineSubtitleDanmakuService.DanmakuSource s = list.get(i);
                LinearLayout r = a.row();
                r.setGravity(Gravity.CENTER_VERTICAL);
                r.setPadding(a.dp(12), a.dp(9), a.dp(10), a.dp(9));
                r.setBackground(MobileTheme.subtleBg(a, 12));
                String lat =
                        s.latencyMs > 0
                                ? (s.latencyMs >= 9999 ? "超时" : (s.latencyMs + "ms"))
                                : "未测速";
                LinearLayout col = a.vertical();
                TextView nameTv = a.text((i + 1) + ". " + s.name + " · " + lat, 13f, p.textPrimary);
                nameTv.setTypeface(null, Typeface.BOLD);
                col.addView(nameTv);
                TextView urlTv = a.text(s.baseUrl, 11.5f, p.textSecondary);
                urlTv.setSingleLine(true);
                urlTv.setEllipsize(TextUtils.TruncateAt.MIDDLE);
                col.addView(urlTv);
                r.addView(col, new LinearLayout.LayoutParams(0, -2, 1f));

                TextView del = a.text("删除", 12.5f, p.danger);
                del.setTypeface(null, Typeface.BOLD);
                del.setPadding(a.dp(10), a.dp(6), a.dp(6), a.dp(6));
                MobileMotion.bindPress(del, 0.92f);
                del.setOnClickListener(
                        v ->
                                MobileBottomSheet.showConfirm(
                                        a,
                                        "删除该弹幕源？",
                                        "将移除自定义弹幕源“" + s.name + "”，不影响内置弹弹Play 接口。",
                                        "删除弹幕源",
                                        true,
                                        () -> {
                                            if (idx >= 0 && idx < list.size()) {
                                                list.remove(idx);
                                                OnlineSubtitleDanmakuService.saveDanmakuSources(
                                                        a, list);
                                            }
                                            if (hRef[0] != null) {
                                                hRef[0].dismiss();
                                            }
                                            a.toast("已删除弹幕源");
                                            reloadPreservingScroll(shell, sv);
                                        }));
                r.addView(del);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
                lp.bottomMargin = a.dp(6);
                box.addView(r, lp);
            }
        }
        a.gap(box, 10);
        final EditText nameIn = formField(a, box, "新增弹幕源名称", "例如：自建弹幕库", "", false);
        final EditText urlIn =
                formField(
                        a, box, "弹幕 API 根地址 (兼容 /api/v2/search/episodes)", "https://…", "", false);

        Runnable onBenchmark =
                () -> {
                    a.toast("正在并发测速全部弹幕源…");
                    OnlineSubtitleDanmakuService.benchmarkDanmakuSourcesAsync(
                            a,
                            sorted -> {
                                if (hRef[0] != null) hRef[0].dismiss();
                                a.toast("已按响应延迟从快到慢完成自动排序");
                                reloadPreservingScroll(shell, sv);
                            });
                };
        Runnable onAdd =
                () -> {
                    String u =
                            DanmuSourceManager.normalizeServiceOrigin(
                                    urlIn.getText().toString().trim());
                    if (u == null || u.isEmpty()) {
                        a.toast("请输入有效的 HTTP / HTTPS 弹幕源地址（保留端口与 /dm 等子路径）");
                        return;
                    }
                    String n = nameIn.getText().toString().trim();
                    DanmuSourceManager.addOrUpdateSource(
                            a, n.isEmpty() ? DanmuSourceManager.defaultSourceName(u) : n, u, -1L);
                    if (hRef[0] != null) hRef[0].dismiss();
                    a.toast("已添加弹幕源（设置与自动播放已同步）");
                    reloadPreservingScroll(shell, sv);
                };
        Runnable onDiscover =
                () -> {
                    if (hRef[0] != null) hRef[0].dismiss();
                    DanmuSourceManager.showDiscoverAndAddServiceSheet(
                            a, () -> reloadPreservingScroll(shell, sv));
                };

        box.addView(
                buildSheetActionPill(a, p, "搜索并添加新弹幕源（探测端口与子路径）", false, onDiscover),
                new LinearLayout.LayoutParams(-1, a.dp(42)));
        a.gap(box, 8);
        LinearLayout footerRow = a.row();
        footerRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, a.dp(44), 1f);
        blp.rightMargin = a.dp(8);
        footerRow.addView(buildSheetActionPill(a, p, "一键测速排序", false, onBenchmark), blp);
        footerRow.addView(
                buildSheetActionPill(a, p, "添加弹幕源", true, onAdd),
                new LinearLayout.LayoutParams(0, a.dp(44), 1.2f));
        a.gap(box, 4);
        box.addView(footerRow, new LinearLayout.LayoutParams(-1, -2));

        hRef[0] =
                MobileBottomSheet.showHandle(
                        a, "弹幕源管理与测速", "支持自定义 LogVar 兼容弹幕源并自动择优排序", null, null, box, true);
    }

    private static void showCornerHudConfigSheet(final MobileRootShell shell, final ScrollView sv) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final int[] mask = {a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD, 7)};
        final int[] flags = {
            Prefs.HUD_CLOCK, Prefs.HUD_BATTERY, Prefs.HUD_NET_SPEED, Prefs.HUD_RESOLUTION
        };
        final int[] icons = {
            MobileIcons.IC_TIMER,
            MobileIcons.IC_BATTERY,
            MobileIcons.IC_SPEED,
            MobileIcons.IC_ASPECT
        };
        final int[] tints = {TINT_BLUE, TINT_GREEN, TINT_TEAL, TINT_VIOLET};
        final String[] names = {"系统时间 (HH:mm)", "实时电池电量 (%)", "实时网速 (KB/s · MB/s)", "视频分辨率"};

        List<View> rows = new ArrayList<>();
        for (int i = 0; i < flags.length; i++) {
            final int bit = flags[i];
            boolean on = (mask[0] & bit) != 0;
            rows.add(
                    MobileSectionGroup.toggleRow(
                            a,
                            icons[i],
                            tints[i],
                            names[i],
                            on,
                            checked -> {
                                if (checked) mask[0] |= bit;
                                else mask[0] &= ~bit;
                                a.mobilePrefs()
                                        .edit()
                                        .putInt(Prefs.PLAYER_CORNER_HUD, mask[0])
                                        .apply();
                                boolean clockOn = (mask[0] & Prefs.HUD_CLOCK) != 0;
                                a.prefs
                                        .edit()
                                        .putBoolean(Prefs.PLAYER_ALWAYS_SHOW_CLOCK, clockOn)
                                        .apply();
                                if (a.mobilePlayerOverlay != null) {
                                    a.mobilePlayerOverlay.syncControlsVisibility();
                                }
                                if (a.playerChrome != null) {
                                    a.playerChrome.syncClockViews();
                                }
                            }));
        }

        final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];
        LinearLayout content = a.vertical();
        TextView desc = a.text("点击开关即刻生效并自动保存，返回后无需再次确认。", 12.5f, p.textSecondary);
        desc.setPadding(a.dp(4), 0, a.dp(4), a.dp(10));
        content.addView(desc);
        content.addView(MobileSectionGroup.create(a, null, null, rows));
        a.gap(content, 12);

        TextView doneBtn = a.text("完成", 14f, p.accentOnFill);
        doneBtn.setTypeface(null, Typeface.BOLD);
        doneBtn.setGravity(Gravity.CENTER);
        doneBtn.setPadding(0, a.dp(12), 0, a.dp(12));
        doneBtn.setBackground(MobileTheme.accentPillBg(a, 14));
        MobileMotion.bindPress(doneBtn, 0.96f);
        doneBtn.setOnClickListener(
                v -> {
                    if (handleRef[0] != null) handleRef[0].dismiss();
                });
        content.addView(doneBtn, new LinearLayout.LayoutParams(-1, -2));

        handleRef[0] =
                MobileBottomSheet.showCustom(
                        a, "播放页右上角状态信息", content, () -> reloadPreservingScroll(shell, sv));
    }

    private static void showPlayerButtonOrderDialog(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        String raw =
                Prefs.sanitizeButtonOrder(
                        a.mobilePrefs()
                                .getString(
                                        Prefs.PLAYER_BUTTON_ORDER,
                                        Prefs.DEFAULT_PLAYER_BUTTON_ORDER));
        final List<String> tokens = new ArrayList<>(Arrays.asList(raw.split(",")));

        LinearLayout rootBox = a.vertical();
        rootBox.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        final LinearLayout list = a.vertical();
        rootBox.addView(list, new LinearLayout.LayoutParams(-1, -2));

        final Runnable[] rebuild = new Runnable[1];
        rebuild[0] =
                () -> {
                    list.removeAllViews();
                    for (int i = 0; i < tokens.size(); i++) {
                        final int idx = i;
                        String tk = tokens.get(i);
                        LinearLayout r = a.row();
                        r.setGravity(Gravity.CENTER_VERTICAL);
                        r.setPadding(a.dp(12), a.dp(9), a.dp(8), a.dp(9));
                        r.setBackground(MobileTheme.subtleBg(a, 12));
                        r.addView(
                                a.text((i + 1) + ". " + buttonDisplayName(tk), 14f, p.textPrimary),
                                new LinearLayout.LayoutParams(0, -2, 1f));
                        if (i > 0) {
                            TextView up = a.text("上移", 12.5f, p.accent);
                            up.setTypeface(null, Typeface.BOLD);
                            up.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
                            up.setBackground(MobileTheme.pillBg(a, true, 999));
                            MobileMotion.bindPress(up, 0.92f);
                            up.setOnClickListener(
                                    v -> {
                                        String tmp = tokens.set(idx - 1, tokens.get(idx));
                                        tokens.set(idx, tmp);
                                        rebuild[0].run();
                                    });
                            LinearLayout.LayoutParams ulp = new LinearLayout.LayoutParams(-2, -2);
                            ulp.rightMargin = a.dp(6);
                            r.addView(up, ulp);
                        }
                        if (i < tokens.size() - 1) {
                            TextView dn = a.text("下移", 12.5f, p.textSecondary);
                            dn.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
                            dn.setBackground(MobileTheme.cardBg(a, 999));
                            MobileMotion.bindPress(dn, 0.92f);
                            dn.setOnClickListener(
                                    v -> {
                                        String tmp = tokens.set(idx + 1, tokens.get(idx));
                                        tokens.set(idx, tmp);
                                        rebuild[0].run();
                                    });
                            r.addView(dn);
                        }
                        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
                        lp.bottomMargin = a.dp(6);
                        list.addView(r, lp);
                    }
                };
        rebuild[0].run();

        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];
        Runnable onReset =
                () -> {
                    a.mobilePrefs()
                            .edit()
                            .putString(Prefs.PLAYER_BUTTON_ORDER, Prefs.DEFAULT_PLAYER_BUTTON_ORDER)
                            .apply();
                    if (hRef[0] != null) hRef[0].dismiss();
                    a.toast("已恢复默认按钮顺序");
                };
        Runnable onSave =
                () -> {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < tokens.size(); i++) {
                        if (i > 0) sb.append(',');
                        sb.append(tokens.get(i));
                    }
                    a.mobilePrefs()
                            .edit()
                            .putString(
                                    Prefs.PLAYER_BUTTON_ORDER,
                                    Prefs.sanitizeButtonOrder(sb.toString()))
                            .apply();
                    if (hRef[0] != null) hRef[0].dismiss();
                    a.toast("已更新播放器按钮顺序");
                };

        LinearLayout footerRow = a.row();
        footerRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(0, a.dp(44), 1f);
        rlp.rightMargin = a.dp(8);
        footerRow.addView(buildSheetActionPill(a, p, "恢复默认", false, onReset), rlp);
        footerRow.addView(
                buildSheetActionPill(a, p, "保存顺序", true, onSave),
                new LinearLayout.LayoutParams(0, a.dp(44), 1.3f));
        a.gap(rootBox, 6);
        rootBox.addView(footerRow, new LinearLayout.LayoutParams(-1, -2));

        hRef[0] =
                MobileBottomSheet.showHandle(
                        a, "自定义播放器按钮顺序", "按使用习惯调整全屏工具栏按钮顺序", "保存", onSave, rootBox, true);
    }

    private static TextView buildSheetActionPill(
            MainActivity a,
            MobileTheme.Palette p,
            String label,
            boolean primary,
            Runnable onClick) {
        TextView btn = a.text(label, 14f, primary ? p.accentOnFill : p.textPrimary);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setGravity(Gravity.CENTER);
        btn.setBackground(primary ? a.bg(p.accent, 14) : MobileTheme.subtleBg(a, 14));
        MobileMotion.bindPress(btn, 0.96f);
        btn.setOnClickListener(
                v -> {
                    if (onClick != null) onClick.run();
                });
        return btn;
    }

    private static void promptSingleSecret(
            final MobileRootShell shell,
            final ScrollView sv,
            String title,
            String tip,
            final String secretKey) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));
        final EditText input =
                formField(a, box, tip, "API Key", a.secretsPrefs().getString(secretKey, ""), true);
        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];
        Runnable onSave =
                () -> {
                    a.secretsPrefs()
                            .edit()
                            .putString(secretKey, input.getText().toString().trim())
                            .apply();
                    if (hRef[0] != null) hRef[0].dismiss();
                    a.toast("密钥已保存");
                    reloadPreservingScroll(shell, sv);
                };
        box.addView(
                buildSheetActionPill(a, p, "保存密钥", true, onSave),
                new LinearLayout.LayoutParams(-1, a.dp(44)));
        hRef[0] = MobileBottomSheet.showHandle(a, title, "仅保存在本机应用私有偏好中", "保存", onSave, box, false);
    }

    // =========================================================================
    // PROGRESSIVE DISCLOSURE COLLAPSIBLE GROUP & INSET GROUPED ROW BUILDERS
    // =========================================================================
    private static void addCollapsibleAdvancedSection(
            final MainActivity a,
            LinearLayout parent,
            final int subPageId,
            boolean initialExpanded,
            final boolean hasNonDefault,
            String footerText,
            List<View> rows) {
        if (rows == null || rows.isEmpty()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final boolean[] expanded = {initialExpanded};
        if (initialExpanded) {
            EXPANDED_ADVANCED.add(subPageId);
        }

        LinearLayout outer = a.vertical();
        LinearLayout card = a.vertical();
        card.setBackground(MobileTheme.cardBg(a, 16));
        if (Build.VERSION.SDK_INT >= 21) {
            card.setOutlineProvider(ViewOutlineProvider.BACKGROUND);
            UiCompat.setClipToOutline(card, true);
        }

        // Collapsible header row with rotating chevron (0° <-> 180°)
        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        headerRow.setMinimumHeight(a.dp(52));
        headerRow.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));

        FrameLayout badge = MobileIcons.badge(a, MobileIcons.IC_SLIDERS, TINT_SLATE, 28, 16);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(a.dp(28), a.dp(28));
        blp.rightMargin = a.dp(10);
        headerRow.addView(badge, blp);

        TextView titleView = a.text("高级与调试选项", 15f, p.textPrimary);
        titleView.setSingleLine(true);
        titleView.setEllipsize(TextUtils.TruncateAt.END);
        headerRow.addView(titleView, new LinearLayout.LayoutParams(0, -2, 1f));

        final String collapsedStatus =
                hasNonDefault ? ("已自定义 · " + rows.size() + " 项") : (rows.size() + " 项");
        final TextView statusView =
                a.text(initialExpanded ? "收起" : collapsedStatus, 13f, p.textSecondary);
        statusView.setSingleLine(true);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-2, -2);
        slp.leftMargin = a.dp(8);
        slp.rightMargin = a.dp(6);
        headerRow.addView(statusView, slp);

        final MobileIcons.IconView chevron =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_DOWN, 14f, p.textTertiary);
        chevron.setRotation(initialExpanded ? 180f : 0f);
        headerRow.addView(chevron, new LinearLayout.LayoutParams(a.dp(14), a.dp(14)));

        MobileSectionGroup.bindPressHighlight(headerRow, p.bgPressed);
        card.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        // Collapsible rows body
        final LinearLayout contentWrap = a.vertical();
        contentWrap.setVisibility(initialExpanded ? View.VISIBLE : View.GONE);
        int hairlinePx = MobileTheme.hairlinePx(a);
        int insetPx = a.dp(52);
        for (View row : rows) {
            if (row == null) continue;
            View divider = new View(a);
            divider.setBackgroundColor(p.hairline);
            LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(-1, hairlinePx);
            dlp.leftMargin = insetPx;
            contentWrap.addView(divider, dlp);
            if (row.getParent() instanceof ViewGroup) {
                ((ViewGroup) row.getParent()).removeView(row);
            }
            contentWrap.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }
        card.addView(contentWrap, new LinearLayout.LayoutParams(-1, -2));
        outer.addView(card, new LinearLayout.LayoutParams(-1, -2));

        final TextView footerView;
        if (footerText != null && !footerText.trim().isEmpty()) {
            footerView = a.text(footerText.trim(), 12f, p.textSecondary);
            footerView.setLineSpacing(a.dp(2.5f), 1f);
            footerView.setPadding(a.dp(16), a.dp(8), a.dp(16), 0);
            footerView.setVisibility(initialExpanded ? View.VISIBLE : View.GONE);
            outer.addView(footerView, new LinearLayout.LayoutParams(-1, -2));
        } else {
            footerView = null;
        }

        headerRow.setOnClickListener(
                v -> {
                    boolean next = !expanded[0];
                    expanded[0] = next;
                    if (next) EXPANDED_ADVANCED.add(subPageId);
                    else EXPANDED_ADVANCED.remove(subPageId);

                    chevron.animate().cancel();
                    if (MobileMotion.isReduced(a)) {
                        chevron.setRotation(next ? 180f : 0f);
                    } else {
                        chevron.animate()
                                .rotation(next ? 180f : 0f)
                                .setDuration(MotionTokens.DURATION_FAST_MS)
                                .setInterpolator(MotionTokens.createStandardInterpolator())
                                .start();
                    }
                    MobileMotion.crossfadeText(statusView, next ? "收起" : collapsedStatus);
                    MobileMotion.animateExpandCollapse(contentWrap, next);
                    if (footerView != null) {
                        MobileMotion.animateExpandCollapse(footerView, next);
                    }
                });

        parent.addView(outer, sectionLayoutParams(a));
    }

    private static void addSection(
            MainActivity a,
            LinearLayout parent,
            String headerTitle,
            String footerText,
            List<View> rows) {
        LinearLayout section = MobileSectionGroup.create(a, headerTitle, footerText, rows);
        parent.addView(section, sectionLayoutParams(a));
    }

    private static LinearLayout.LayoutParams sectionLayoutParams(MainActivity a) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = a.dp(18);
        return lp;
    }

    private static View tagged(View v, String key) {
        if (v != null && key != null) {
            v.setTag(key);
        }
        return v;
    }

    private static View mobileToggleRow(
            MainActivity a,
            String tagKey,
            int icon,
            int tint,
            String title,
            String prefKey,
            boolean defVal,
            Runnable after) {
        return toggleRowInternal(
                a, a.mobilePrefs(), tagKey, icon, tint, title, prefKey, defVal, after);
    }

    private static View coreToggleRow(
            MainActivity a,
            String tagKey,
            int icon,
            int tint,
            String title,
            String prefKey,
            boolean defVal,
            Runnable after) {
        return toggleRowInternal(a, a.prefs, tagKey, icon, tint, title, prefKey, defVal, after);
    }

    private static View toggleRowInternal(
            MainActivity a,
            final SharedPreferences sp,
            String tagKey,
            int icon,
            int tint,
            String title,
            final String prefKey,
            boolean defVal,
            final Runnable after) {
        boolean init = sp.getBoolean(prefKey, defVal);
        View row =
                MobileSectionGroup.toggleRow(
                        a,
                        icon,
                        tint,
                        title,
                        init,
                        checked -> {
                            sp.edit().putBoolean(prefKey, checked).apply();
                            if (after != null) after.run();
                        });
        row.setTag(tagKey);
        return row;
    }

    private static View mobileIntRow(
            MobileRootShell shell,
            ScrollView sv,
            String tagKey,
            int icon,
            int tint,
            String title,
            String prefKey,
            String[] fullLabels,
            String[] shortLabels,
            int[] values,
            int fallback,
            boolean reRenderShell) {
        return intRowInternal(
                shell,
                sv,
                shell.a.mobilePrefs(),
                tagKey,
                icon,
                tint,
                title,
                prefKey,
                fullLabels,
                shortLabels,
                values,
                fallback,
                reRenderShell);
    }

    private static View coreIntRow(
            MobileRootShell shell,
            ScrollView sv,
            String tagKey,
            int icon,
            int tint,
            String title,
            String prefKey,
            String[] fullLabels,
            String[] shortLabels,
            int[] values,
            int fallback,
            boolean reRenderShell) {
        return intRowInternal(
                shell,
                sv,
                shell.a.prefs,
                tagKey,
                icon,
                tint,
                title,
                prefKey,
                fullLabels,
                shortLabels,
                values,
                fallback,
                reRenderShell);
    }

    private static View intRowInternal(
            final MobileRootShell shell,
            final ScrollView sv,
            final SharedPreferences sp,
            String tagKey,
            int icon,
            int tint,
            final String title,
            final String prefKey,
            final String[] fullLabels,
            final String[] shortLabels,
            final int[] values,
            int fallback,
            final boolean reRenderShell) {
        final MainActivity a = shell.a;
        int cur = sp.getInt(prefKey, fallback);
        int sel = 0;
        for (int i = 0; i < values.length; i++) {
            if (values[i] == cur) sel = i;
        }
        final int selectedIdx = sel;
        String displayVal =
                shortLabels != null && selectedIdx < shortLabels.length
                        ? shortLabels[selectedIdx]
                        : fullLabels[selectedIdx];
        View row =
                MobileSectionGroup.navRow(
                        a,
                        icon,
                        tint,
                        title,
                        displayVal,
                        () ->
                                MobileBottomSheet.showPicker(
                                        a,
                                        title,
                                        "选择后立即生效",
                                        fullLabels,
                                        selectedIdx,
                                        idx -> {
                                            sp.edit().putInt(prefKey, values[idx]).apply();
                                            if (reRenderShell) {
                                                applyThemePreservingScroll(a, sv);
                                            } else {
                                                reloadPreservingScroll(shell, sv);
                                            }
                                        }));
        row.setTag(tagKey);
        return row;
    }

    private static LinearLayout buildInlineControlHeader(
            MainActivity a,
            MobileTheme.Palette p,
            int icon,
            int tint,
            String title,
            String valueText) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout badge = MobileIcons.badge(a, icon, tint, 28, 16);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(a.dp(28), a.dp(28));
        blp.rightMargin = a.dp(10);
        row.addView(badge, blp);

        TextView label = a.text(title, 15f, p.textPrimary);
        label.setSingleLine(true);
        label.setEllipsize(TextUtils.TruncateAt.END);
        row.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

        if (valueText != null && !valueText.isEmpty()) {
            TextView val = a.text(valueText, 13.5f, p.textSecondary);
            val.setSingleLine(true);
            row.addView(val, new LinearLayout.LayoutParams(-2, -2));
        }
        return row;
    }

    private static LinearLayout buildDropdownButton(
            MainActivity a, String labelText, TextView[] outLabel, Runnable onClick) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout btn = a.row();
        btn.setGravity(Gravity.CENTER_VERTICAL);
        btn.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        btn.setBackground(MobileTheme.subtleBg(a, 12));

        TextView tv = a.text(labelText, 13.5f, p.textPrimary);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setSingleLine(true);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        if (outLabel != null && outLabel.length > 0) {
            outLabel[0] = tv;
        }
        btn.addView(tv, new LinearLayout.LayoutParams(0, -2, 1f));

        MobileIcons.IconView down =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_DOWN, 14f, p.textSecondary);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
        dlp.leftMargin = a.dp(8);
        btn.addView(down, dlp);

        MobileMotion.bindPress(btn, 0.97f);
        btn.setOnClickListener(
                v -> {
                    if (onClick != null) onClick.run();
                });
        return btn;
    }

    private static EditText formField(
            MainActivity a,
            LinearLayout parent,
            String label,
            String hint,
            String initial,
            boolean password) {
        MobileTheme.Palette p = MobileTheme.of(a);
        TextView lbl = a.text(label, 12f, p.textSecondary);
        lbl.setLineSpacing(a.dp(2f), 1f);
        parent.addView(lbl);
        a.gap(parent, 5);
        EditText et = new EditText(a);
        et.setHint(hint);
        et.setHintTextColor(p.textTertiary);
        et.setTextColor(p.textPrimary);
        et.setTextSize(13.5f);
        et.setSingleLine(true);
        if (password) {
            et.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        }
        et.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
        et.setBackground(MobileTheme.subtleBg(a, 12));
        if (initial != null && !initial.isEmpty()) {
            et.setText(initial);
            et.setSelection(initial.length());
        }
        parent.addView(et, new LinearLayout.LayoutParams(-1, -2));
        a.gap(parent, 10);
        return et;
    }

    private static ScrollView wrapScroll(MainActivity a, View child) {
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.addView(child, new ScrollView.LayoutParams(-1, -2));
        return sv;
    }

    private static int computeOffsetInAncestor(View target, View ancestor) {
        int y = 0;
        View cur = target;
        while (cur != null && cur != ancestor) {
            y += cur.getTop();
            ViewParent parent = cur.getParent();
            cur = parent instanceof View ? (View) parent : null;
        }
        return y;
    }

    /** Pulses a soft theme-aware accent tint on the target row when jumped from Settings Search. */
    private static void flashSettingRow(final MainActivity a, final View row) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        if (MobileMotion.isReduced(a)) {
            row.setBackgroundColor(MobileTheme.withAlpha(p.accent, p.isDark ? 0x38 : 0x26));
            row.postDelayed(() -> row.setBackgroundColor(Color.TRANSPARENT), 900);
            return;
        }
        ValueAnimator anim = ValueAnimator.ofFloat(1f, 0.2f, 1f, 0f);
        anim.setDuration(1300);
        anim.setInterpolator(MotionTokens.createStandardInterpolator());
        anim.addUpdateListener(
                va -> {
                    float f = (Float) va.getAnimatedValue();
                    int maxAlpha = p.isDark ? 0x48 : 0x30;
                    int alpha = Math.round(maxAlpha * f);
                    row.setBackgroundColor(
                            alpha <= 0
                                    ? Color.TRANSPARENT
                                    : MobileTheme.withAlpha(p.accent, alpha));
                });
        anim.start();
    }

    private static int iconForSubPage(int subPage) {
        switch (subPage) {
            case MobileSettingsIndex.SUB_SOURCES:
                return MobileIcons.IC_SWITCH_SOURCE;
            case MobileSettingsIndex.SUB_APPEARANCE:
                return MobileIcons.IC_PALETTE;
            case MobileSettingsIndex.SUB_PLAYBACK:
                return MobileIcons.IC_PLAY;
            case MobileSettingsIndex.SUB_SUBTITLE:
                return MobileIcons.IC_SUBTITLE;
            case MobileSettingsIndex.SUB_SERVICES:
                return MobileIcons.IC_SPARKLE;
            case MobileSettingsIndex.SUB_SYNC:
                return MobileIcons.IC_CLOUD_SYNC;
            case MobileSettingsIndex.SUB_STORAGE:
            default:
                return MobileIcons.IC_STORAGE;
        }
    }

    private static int tintForSubPage(int subPage, MobileTheme.Palette p) {
        switch (subPage) {
            case MobileSettingsIndex.SUB_SOURCES:
                return TINT_GREEN;
            case MobileSettingsIndex.SUB_APPEARANCE:
                return p.accent;
            case MobileSettingsIndex.SUB_PLAYBACK:
                return TINT_BLUE;
            case MobileSettingsIndex.SUB_SUBTITLE:
                return TINT_VIOLET;
            case MobileSettingsIndex.SUB_SERVICES:
                return TINT_AMBER;
            case MobileSettingsIndex.SUB_SYNC:
                return TINT_TEAL;
            case MobileSettingsIndex.SUB_STORAGE:
            default:
                return TINT_SLATE;
        }
    }

    private static String shortEngineName(int engine) {
        switch (engine) {
            case 1:
                return "系统原生";
            case 2:
                return "IJK";
            case 3:
                return "MPV";
            case 0:
            default:
                return "Media3";
        }
    }

    private static String buildServiceSummary(MainActivity a) {
        boolean unlocked = AiBetaGate.isUnlocked(a);
        boolean hasAi = AiAssistantService.isConfigured(a);
        int drives = AccountPanel.loggedDriveCount(a);
        if (hasAi && drives > 0) return "AI / " + drives + " 网盘";
        if (hasAi) return "AI / 网盘";
        if (drives > 0) return "已登 " + drives + " 网盘";
        return unlocked ? "网盘 / AI" : "网盘 / 追剧";
    }

    private static String describeHudMaskCompact(int mask) {
        int visible =
                mask
                        & (Prefs.HUD_CLOCK
                                | Prefs.HUD_BATTERY
                                | Prefs.HUD_NET_SPEED
                                | Prefs.HUD_RESOLUTION);
        if (visible <= 0) return "已关闭";
        List<String> on = new ArrayList<>();
        if ((visible & Prefs.HUD_CLOCK) != 0) on.add("时间");
        if ((visible & Prefs.HUD_BATTERY) != 0) on.add("电量");
        if ((visible & Prefs.HUD_NET_SPEED) != 0) on.add("网速");
        if ((visible & Prefs.HUD_RESOLUTION) != 0) on.add("分辨率");
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < on.size(); i++) {
            if (i > 0) sb.append(" · ");
            sb.append(on.get(i));
        }
        return sb.toString();
    }

    private static String formatSpeed(float speed) {
        if (Math.abs(speed - Math.round(speed)) < 0.01f) {
            return String.format(Locale.US, "%.1f×", speed);
        }
        if (Math.abs(speed * 4f - Math.round(speed * 4f)) < 0.01f
                && Math.abs(speed * 2f - Math.round(speed * 2f)) > 0.01f) {
            return String.format(Locale.US, "%.2f×", speed);
        }
        return String.format(Locale.US, "%.1f×", speed);
    }

    private static String trimCompact(String text, int maxLen) {
        if (text == null) return "";
        String s = text.trim();
        return s.length() <= maxLen ? s : (s.substring(0, maxLen) + "…");
    }

    private static long estimateMediaCacheBytes(MainActivity a) {
        MediaDiskCache cur = MediaDiskCache.currentInstance();
        if (cur != null) return cur.totalCachedBytes();
        return dirSizeBytes(new File(a.getCacheDir(), "media-cache"));
    }

    private static void clearMediaDiskCache(MainActivity a) {
        MediaDiskCache cur = MediaDiskCache.currentInstance();
        if (cur != null) {
            cur.clear();
            return;
        }
        deleteChildren(new File(a.getCacheDir(), "media-cache"));
    }

    private static long dirSizeBytes(File file) {
        if (file == null || !file.exists()) return 0L;
        if (file.isFile()) return file.length();
        long sum = 0L;
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                sum += dirSizeBytes(child);
            }
        }
        return sum;
    }

    private static void deleteChildren(File dir) {
        if (dir == null || !dir.isDirectory()) return;
        File[] children = dir.listFiles();
        if (children == null) return;
        for (File child : children) {
            if (child.isDirectory()) {
                deleteChildren(child);
            }
            child.delete();
        }
    }

    private static String buttonDisplayName(String token) {
        if ("episodes".equals(token)) return "选集";
        if ("lines".equals(token)) return "换源 / 线路";
        if ("speed".equals(token)) return "播放倍速";
        if ("subtitles".equals(token)) return "内嵌与本地字幕";
        if ("online-sub".equals(token)) return "在线字幕搜索";
        if ("ai-sub".equals(token)) return "AI 双语字幕翻译";
        if ("danmaku-tool".equals(token)) return "弹幕开关与匹配";
        if ("aspect".equals(token)) return "画面比例";
        if ("decoder".equals(token)) return "内核与解码方式";
        if ("pip-tool".equals(token)) return "画中画小窗 (PiP)";
        if ("external-player".equals(token)) return "外部播放器打开";
        if ("more".equals(token)) return "更多工具";
        return token;
    }
}

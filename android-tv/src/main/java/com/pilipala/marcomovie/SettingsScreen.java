package com.pilipala.marcomovie;

import android.content.Intent;
import android.database.Cursor;
import android.graphics.*;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.view.Gravity;
import android.view.View;
import android.widget.*;
import com.pilipala.marcomovie.hud.PlayerHudPrefs;
import java.io.*;

/** Remote-friendly settings. Each row changes a setting consumed by the app. */
final class SettingsScreen {
    final MainActivity a;

    SettingsScreen(MainActivity activity) {
        a = activity;
    }

    void page(String title, String note) {
        if (a.isTvDevice()) {
            // Fast TV split-pane host: avoids creating & immediately discarding an outer
            // TvScrollView and skips full-screen HomeAmbient shader overdraw on Settings.
            a.renderDirectTvPage();
            if (HomeAmbient.effectiveBgMode(a) == Prefs.BG_MODE_WALLPAPER && a.root != null) {
                a.root.addView(
                        ImageLoader.createAtmosphere(a), 0, new FrameLayout.LayoutParams(-1, -1));
            }
            tvPage(title, note);
            return;
        }
        a.renderPage("", "");
        if (!a.isTvDevice()) {
            LinearLayout topNav = a.row();
            topNav.setGravity(Gravity.CENTER_VERTICAL);
            topNav.setPadding(0, 0, 0, a.dp(14));
            TextView backBtn = a.text("‹", 22, MainActivity.WHITE);
            backBtn.setGravity(Gravity.CENTER);
            backBtn.setBackground(
                    MobileShell.glassBg(0xb034343a, 0xc01e1e22, a.dp(999), a.dp(0.8f), 0x38ffffff));
            MobileDetailScreen.bindTouchFeedback(backBtn);
            backBtn.setOnClickListener(v -> a.onBackPressed());
            LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
            backLp.rightMargin = a.dp(10);
            topNav.addView(backBtn, backLp);
            TextView heading = a.text(title, 22, MainActivity.WHITE);
            heading.setTypeface(null, Typeface.BOLD);
            topNav.addView(heading, new LinearLayout.LayoutParams(0, -2, 1));
            a.body.addView(topNav, new LinearLayout.LayoutParams(-1, -2));
        } else {
            a.body.addView(a.text(title, 28, MainActivity.WHITE));
            a.gap(a.body, 10);
        }
        if (!note.isEmpty()) {
            a.paragraph(note);
            a.gap(a.body, 6);
        }
    }

    /** Apple tvOS-style 6-category split-view settings shell backed by stable IDs in {@link TvSettingsRegistry}. */
    static final int TV_CAT_SOURCES = TvSettingsRegistry.IDX_SOURCES;

    static final int TV_CAT_PLAYBACK = TvSettingsRegistry.IDX_PLAYBACK;
    static final int TV_CAT_SUBTITLE_DANMU = TvSettingsRegistry.IDX_SUBTITLE_DANMU;
    static final int TV_CAT_APPEARANCE = TvSettingsRegistry.IDX_APPEARANCE_REMOTE;
    static final int TV_CAT_DATA_SYNC = TvSettingsRegistry.IDX_DATA_SYNC;
    static final int TV_CAT_UPDATES = TvSettingsRegistry.IDX_UPDATES_DIAG;
    static final int TV_CAT_COUNT = TvSettingsRegistry.CATEGORY_COUNT;
    // Legacy aliases preserved for internal clarity
    static final int TV_CAT_CONTENT = TV_CAT_SOURCES;
    static final int TV_CAT_BACKUP = TV_CAT_DATA_SYNC;

    private static final java.util.Map<String, String> TV_LAST_ROW_TAG_BY_CAT =
            new java.util.HashMap<>();
    private static final java.util.Map<String, Integer> TV_LAST_ROW_IDX_BY_CAT =
            new java.util.HashMap<>();
    private static android.view.animation.DecelerateInterpolator tvDecelCache;

    static void resetTvNavigationMemory() {
        TV_LAST_ROW_TAG_BY_CAT.clear();
        TV_LAST_ROW_IDX_BY_CAT.clear();
    }

    private static android.view.animation.DecelerateInterpolator tvDecel() {
        if (tvDecelCache == null) {
            tvDecelCache = new android.view.animation.DecelerateInterpolator();
        }
        return tvDecelCache;
    }

    static String resolveTvCategoryId(String idOrLegacyTitle) {
        return TvSettingsRegistry.resolveCategoryId(idOrLegacyTitle);
    }

    static int resolveTvCategoryIndex(String idOrLegacyTitle) {
        return TvSettingsRegistry.resolveCategoryIndex(idOrLegacyTitle);
    }

    private View tvActiveCategoryButton;
    private View tvFirstRightControl;
    private FrameLayout tvRightHost;
    private TvScrollView tvActiveScroll;
    private int tvSelectedCategory = TV_CAT_SOURCES;
    private int tvBuildingCategory = -1;
    private boolean tvDirectEntryMode = false;
    private final TvScrollView[] tvCategoryScrolls = new TvScrollView[TV_CAT_COUNT];
    private final LinearLayout[] tvCategoryPanes = new LinearLayout[TV_CAT_COUNT];
    private final View[] tvCategoryFirstControls = new View[TV_CAT_COUNT];

    @SuppressWarnings("unchecked")
    private final java.util.List<View>[] tvCategoryControls = new java.util.List[TV_CAT_COUNT];

    @SuppressWarnings("unchecked")
    private final java.util.List<String>[] tvCategoryControlTags = new java.util.List[TV_CAT_COUNT];

    private final java.util.List<Runnable> tvCategoryRefreshers = new java.util.ArrayList<>();
    private final android.util.SparseArray<View> tvCategoryViews = new android.util.SparseArray<>();

    void tvPage(String title, String note) {
        tvActiveCategoryButton = null;
        tvFirstRightControl = null;
        tvActiveScroll = null;
        tvBuildingCategory = -1;
        java.util.Arrays.fill(tvCategoryScrolls, null);
        java.util.Arrays.fill(tvCategoryPanes, null);
        java.util.Arrays.fill(tvCategoryFirstControls, null);
        for (int i = 0; i < TV_CAT_COUNT; i++) {
            tvCategoryControls[i] = new java.util.ArrayList<>();
            tvCategoryControlTags[i] = new java.util.ArrayList<>();
        }
        tvCategoryRefreshers.clear();
        tvCategoryViews.clear();
        tvSelectedCategory = resolveTvCategoryIndex(title);
        boolean isSubpage = "解码组件".equals(title) || "首页壁纸".equals(title);
        if (!isSubpage && !tvDirectEntryMode && a.prefs != null) {
            a.prefs
                    .edit()
                    .putString(
                            Prefs.TV_SETTINGS_LAST_CATEGORY,
                            TvSettingsRegistry.specAt(tvSelectedCategory).id)
                    .apply();
        }

        // Replace outer page body with a fixed full-screen Apple tvOS split container using exact
        // precomputed pixel bounds (zero nested LinearLayout weight=1 double-measure passes).
        if (a.scroll != null) a.root.removeView(a.scroll);
        if (a.body != null && a.body.getParent() == a.root) a.root.removeView(a.body);

        int padH = a.dp(52);
        int padTop = a.dp(28);
        int padBottom = a.dp(20);
        int winW = Math.max(a.dp(640), a.windowWidth());
        int winH = Math.max(a.dp(360), a.windowHeight());
        int innerW = Math.max(a.dp(500), winW - padH * 2);
        int headerH = a.dp(42);
        int headerGap = a.dp(20);
        int columnsH = Math.max(a.dp(240), winH - padTop - padBottom - headerH - headerGap);
        int navW = a.dp(256);
        int navGap = a.dp(44);
        int rightW = Math.max(a.dp(240), innerW - navW - navGap);

        LinearLayout shell = a.vertical();
        shell.setClipChildren(false);
        shell.setClipToPadding(false);
        shell.setPadding(padH, padTop, padH, padBottom);
        a.root.addView(shell, new FrameLayout.LayoutParams(-1, -1));

        // Fixed Top Apple tvOS Header Row (Title + Live Clock)
        FrameLayout headerBar = new FrameLayout(a);
        TextView heading = a.text("设置", 30, TvV17Theme.TEXT);
        heading.setTypeface(null, Typeface.BOLD);
        headerBar.addView(
                heading,
                new FrameLayout.LayoutParams(-2, -2, Gravity.START | Gravity.CENTER_VERTICAL));
        String clockText =
                new java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
                        .format(new java.util.Date());
        TextView clock = a.text(clockText, 16, 0xb8ebebf5);
        clock.setTypeface(null, Typeface.BOLD);
        headerBar.addView(
                clock, new FrameLayout.LayoutParams(-2, -2, Gravity.END | Gravity.CENTER_VERTICAL));
        shell.addView(headerBar, new LinearLayout.LayoutParams(innerW, headerH));
        a.gap(shell, 20);

        LinearLayout columns = a.row();
        columns.setGravity(Gravity.TOP);
        columns.setClipChildren(false);
        columns.setClipToPadding(false);
        shell.addView(columns, new LinearLayout.LayoutParams(innerW, columnsH));

        // Left Fixed Primary Sidebar: 6 stable-ID categories with instant focus handoff.
        LinearLayout navigation = a.vertical();
        navigation.setTag("tv-settings-left-rail");
        navigation.setClipChildren(false);
        navigation.setClipToPadding(false);
        navigation.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(10));
        LinearLayout.LayoutParams navSize = new LinearLayout.LayoutParams(navW, columnsH);
        navSize.rightMargin = navGap;
        columns.addView(navigation, navSize);

        tvRightHost = new FrameLayout(a);
        tvRightHost.setTag("tv-settings-right-pane");
        tvRightHost.setClipChildren(false);
        tvRightHost.setClipToPadding(false);
        columns.addView(tvRightHost, new LinearLayout.LayoutParams(rightW, columnsH));

        for (TvSettingsRegistry.CategorySpec spec : TvSettingsRegistry.CATEGORIES) {
            tvCategory(navigation, spec.index, spec.title, spec.navTag);
        }
        // Keep vertical navigation strictly inside the left rail (never leaks into right pane)
        for (int i = 0; i < TV_CAT_COUNT; i++) {
            View cur = tvCategoryViews.get(i);
            View up = tvCategoryViews.get(Math.max(0, i - 1));
            View down = tvCategoryViews.get(Math.min(TV_CAT_COUNT - 1, i + 1));
            if (cur != null) {
                cur.setNextFocusLeftId(cur.getId());
                if (up != null) cur.setNextFocusUpId(up.getId());
                if (down != null) cur.setNextFocusDownId(down.getId());
            }
        }

        View navSpacer = new View(a);
        navigation.addView(navSpacer, new LinearLayout.LayoutParams(1, 0, 1f));

        LinearLayout brandFoot = a.vertical();
        brandFoot.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        brandFoot.setBackground(TvV17Surface.rounded(0x4d141822, a.dp(16), 0x1cffffff, a.dp(1)));
        TextView brandTitle =
                a.text("Marco Movie  " + UpdateManager.installedVersion(a), 12.5f, 0xd8f5f5f7);
        brandTitle.setTypeface(null, Typeface.BOLD);
        brandFoot.addView(brandTitle);
        TextView hint = a.text("↑↓ 切换分类 · → 进入内容 · 返回退出", 11f, 0x99ebebf5);
        hint.setPadding(0, a.dp(4), 0, 0);
        brandFoot.addView(hint);
        navigation.addView(brandFoot, new LinearLayout.LayoutParams(-1, -2));

        TvScrollView initialScroll = createTvRightScroll();
        LinearLayout initialPane = createTvCategoryPane();
        initialScroll.addView(initialPane, new ScrollView.LayoutParams(-1, -2));
        tvRightHost.addView(initialScroll, new FrameLayout.LayoutParams(-1, -1));
        tvActiveScroll = initialScroll;
        a.scroll = initialScroll;
        a.body = initialPane;
        if (!isSubpage && tvSelectedCategory >= 0 && tvSelectedCategory < TV_CAT_COUNT) {
            tvCategoryScrolls[tvSelectedCategory] = initialScroll;
            tvCategoryPanes[tvSelectedCategory] = initialPane;
        }
        renderTvRightHeader(initialPane, title, note);
        if (!isSubpage) {
            scheduleTvCategoryPrewarm();
        }
        if (tvActiveCategoryButton != null) {
            a.tvInitialFocus = tvActiveCategoryButton;
        }
        if (tvActiveCategoryButton != null
                && (a.current == null || a.current.focus == null || a.current.focus.isEmpty())) {
            final View initialCat = tvActiveCategoryButton;
            a.ui.post(
                    () -> {
                        if (initialCat.isAttachedToWindow()
                                && (a.current == null
                                        || a.current.focus == null
                                        || a.current.focus.isEmpty())) {
                            initialCat.requestFocus();
                        }
                    });
        }
    }

    private TvScrollView createTvRightScroll() {
        TvScrollView scroller = new TvScrollView(a);
        scroller.readingMode = true;
        scroller.setFocusFrameEnabled(false);
        scroller.setFillViewport(true);
        scroller.setVerticalScrollBarEnabled(false);
        scroller.setClipChildren(false);
        scroller.setClipToPadding(false);
        return scroller;
    }

    private LinearLayout createTvCategoryPane() {
        LinearLayout pane = a.vertical();
        pane.setClipChildren(false);
        pane.setClipToPadding(false);
        pane.setPadding(a.dp(8), a.dp(4), a.dp(16), a.dp(56));
        return pane;
    }

    private void scheduleTvCategoryPrewarm() {
        if (tvRightHost == null || a.isFinishing()) return;
        final int ticket = a.generation;
        final FrameLayout host = tvRightHost;
        host.post(
                () -> {
                    if (a.isFinishing() || a.generation != ticket || !host.isAttachedToWindow()) {
                        return;
                    }
                    syncTvCategoryRightFocusLink(tvSelectedCategory);
                    reconcileMissingRestoredRowFocus();
                });
    }

    private void reconcileMissingRestoredRowFocus() {
        if (a.current == null || a.current.focus == null || a.current.focus.isEmpty()) return;
        String wanted = a.current.focus;
        View exact = MainActivity.findVisibleFocusableByTag(a.root, wanted);
        if (exact != null) return;
        // Requested right-pane row disappeared (e.g. conditional item hidden): land on nearest
        // visible row in the active category instead of stranding focus.
        String wantedCatId = TvSettingsRegistry.categoryIdForRowTag(wanted);
        if (wantedCatId != null
                && wantedCatId.equals(TvSettingsRegistry.specAt(tvSelectedCategory).id)) {
            View fallback = resolveTargetRightControl(tvSelectedCategory);
            if (fallback != null && fallback.getTag() instanceof String) {
                a.current.focus = (String) fallback.getTag();
                fallback.requestFocus();
            }
        }
    }

    private TvScrollView ensureTvCategoryScroll(final int catIndex, boolean active) {
        TvScrollView existing = tvCategoryScrolls[catIndex];
        if (existing != null) return existing;
        LinearLayout prevBody = a.body;
        int prevBuilding = tvBuildingCategory;
        tvBuildingCategory = catIndex;
        TvScrollView scroller = createTvRightScroll();
        LinearLayout pane = createTvCategoryPane();
        scroller.addView(pane, new ScrollView.LayoutParams(-1, -2));
        tvCategoryScrolls[catIndex] = scroller;
        tvCategoryPanes[catIndex] = pane;
        tvCategoryFirstControls[catIndex] = null;
        tvCategoryControls[catIndex].clear();
        tvCategoryControlTags[catIndex].clear();
        a.body = pane;
        TvSettingsRegistry.CategorySpec spec = TvSettingsRegistry.specAt(catIndex);
        try {
            renderTvRightHeader(pane, spec.title, spec.subtitle);
            renderTvCategoryRows(catIndex);
        } finally {
            tvBuildingCategory = prevBuilding;
            a.body = active ? pane : prevBody;
        }
        syncTvCategoryRightFocusLink(catIndex);
        if (active) {
            scroller.setVisibility(View.VISIBLE);
            scroller.setFocusable(true);
            scroller.setAlpha(1f);
            scroller.setDescendantFocusability(android.view.ViewGroup.FOCUS_AFTER_DESCENDANTS);
            tvRightHost.addView(scroller, new FrameLayout.LayoutParams(-1, -1));
        } else {
            scroller.setFocusable(false);
            scroller.setDescendantFocusability(android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS);
            scroller.setAlpha(0.002f);
            tvRightHost.addView(scroller, 0, new FrameLayout.LayoutParams(-1, -1));
            scroller.postOnAnimation(
                    () -> {
                        if (scroller.isAttachedToWindow() && tvSelectedCategory != catIndex) {
                            scroller.setAlpha(0f);
                            scroller.setVisibility(View.INVISIBLE);
                        }
                    });
        }
        return scroller;
    }

    private void renderTvCategoryRows(int catIndex) {
        switch (catIndex) {
            case TV_CAT_SOURCES:
                tvSourcesRows();
                break;
            case TV_CAT_PLAYBACK:
                tvPlaybackRows();
                break;
            case TV_CAT_SUBTITLE_DANMU:
                tvSubtitleDanmuRows();
                break;
            case TV_CAT_APPEARANCE:
                tvAppearanceRemoteRows();
                break;
            case TV_CAT_DATA_SYNC:
                tvDataSyncRows();
                break;
            case TV_CAT_UPDATES:
                tvUpdatesDiagRows();
                break;
            default:
                tvSourcesRows();
                break;
        }
    }

    private void renderTvRightHeader(LinearLayout content, String title, String note) {
        TextView section = a.text(title, 25, TvV17Theme.TEXT);
        section.setTypeface(null, Typeface.BOLD);
        content.addView(section);
        if (note != null && !note.isEmpty()) {
            TextView noteView = a.text(note, 13f, 0xa8ebebf5);
            noteView.setLineSpacing(a.dp(2), 1.12f);
            noteView.setPadding(0, a.dp(6), 0, a.dp(18));
            content.addView(noteView);
        } else {
            a.gap(content, 16);
        }
    }

    private void tvSectionHeader(String title) {
        TextView head = a.text(title, 13f, 0x99d6dff0);
        head.setTag("settings-section:" + title);
        head.setTypeface(null, Typeface.BOLD);
        head.setFocusable(false);
        head.setClickable(false);
        head.setPadding(a.dp(6), a.dp(10), a.dp(6), a.dp(8));
        a.body.addView(head, new LinearLayout.LayoutParams(-1, -2));
    }

    private void updateTvCategoryRenderBinding(int catIndex) {
        if (a.current == null) return;
        final String catId = TvSettingsRegistry.specAt(catIndex).id;
        a.current.render = () -> new SettingsScreen(a).openTvCategoryById(catId, null, false);
    }

    private View resolveTargetRightControl(int catIndex) {
        if (catIndex < 0 || catIndex >= TV_CAT_COUNT) return tvFirstRightControl;
        java.util.List<View> controls = tvCategoryControls[catIndex];
        java.util.List<View> visibleControls = new java.util.ArrayList<>();
        java.util.List<String> visibleTags = new java.util.ArrayList<>();
        for (int i = 0; i < controls.size(); i++) {
            View v = controls.get(i);
            if (v != null
                    && v.getVisibility() == View.VISIBLE
                    && v.isFocusable()
                    && v.isEnabled()) {
                visibleControls.add(v);
                visibleTags.add(v.getTag() instanceof String ? (String) v.getTag() : "");
            }
        }
        if (visibleControls.isEmpty()) return tvCategoryFirstControls[catIndex];
        String catId = TvSettingsRegistry.specAt(catIndex).id;
        String savedTag = TV_LAST_ROW_TAG_BY_CAT.get(catId);
        Integer savedIdxObj = TV_LAST_ROW_IDX_BY_CAT.get(catId);
        int savedIdx = savedIdxObj != null ? savedIdxObj : -1;
        int idx = TvSettingsRegistry.resolveNearestVisibleRowIndex(visibleTags, savedTag, savedIdx);
        return idx >= 0 && idx < visibleControls.size()
                ? visibleControls.get(idx)
                : visibleControls.get(0);
    }

    private void syncTvCategoryRightFocusLink(int catIndex) {
        if (catIndex < 0 || catIndex >= TV_CAT_COUNT) return;
        View catBtn = tvCategoryViews.get(catIndex);
        View target = resolveTargetRightControl(catIndex);
        if (catBtn != null && target != null) {
            catBtn.setNextFocusRightId(target.getId());
        }
        if (catIndex == tvSelectedCategory) {
            tvFirstRightControl = target;
        }
    }

    private void recordTvRightRowFocus(int catIndex, View control) {
        if (catIndex < 0 || catIndex >= TV_CAT_COUNT || control == null) return;
        String catId = TvSettingsRegistry.specAt(catIndex).id;
        String tag = control.getTag() instanceof String ? (String) control.getTag() : "";
        int idx = tvCategoryControls[catIndex].indexOf(control);
        if (!tag.isEmpty()) {
            TV_LAST_ROW_TAG_BY_CAT.put(catId, tag);
        }
        if (idx >= 0) {
            TV_LAST_ROW_IDX_BY_CAT.put(catId, idx);
        }
        View catBtn = tvCategoryViews.get(catIndex);
        if (catBtn != null) {
            catBtn.setNextFocusRightId(control.getId());
        }
        if (catIndex == tvSelectedCategory) {
            tvFirstRightControl = control;
        }
    }

    private void switchTvCategoryInPlace(int catIndex, boolean moveFocusToRight) {
        if (tvRightHost == null || a.isFinishing()) return;
        if (catIndex < 0 || catIndex >= TV_CAT_COUNT) catIndex = TV_CAT_SOURCES;
        TvScrollView targetScroll = ensureTvCategoryScroll(catIndex, true);
        boolean changed = (catIndex != tvSelectedCategory) || tvActiveScroll != targetScroll;
        if (changed) {
            if (tvActiveScroll != null && tvActiveScroll != targetScroll) {
                tvActiveScroll.cancelMotion();
                tvActiveScroll.setAlpha(0f);
                tvActiveScroll.setVisibility(View.INVISIBLE);
                tvActiveScroll.setFocusable(false);
                tvActiveScroll.setDescendantFocusability(
                        android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS);
            }
            tvSelectedCategory = catIndex;
            tvActiveCategoryButton = tvCategoryViews.get(catIndex);
            tvActiveScroll = targetScroll;
            a.scroll = targetScroll;
            a.body = tvCategoryPanes[catIndex];
            if (targetScroll.getScrollY() != 0) targetScroll.scrollTo(0, 0);
            targetScroll.setVisibility(View.VISIBLE);
            targetScroll.setFocusable(true);
            targetScroll.setDescendantFocusability(android.view.ViewGroup.FOCUS_AFTER_DESCENDANTS);
            targetScroll.setAlpha(1f);

            if (!tvDirectEntryMode && a.prefs != null) {
                a.prefs
                        .edit()
                        .putString(
                                Prefs.TV_SETTINGS_LAST_CATEGORY,
                                TvSettingsRegistry.specAt(catIndex).id)
                        .apply();
            }
            syncTvCategoryRightFocusLink(catIndex);
            for (Runnable r : tvCategoryRefreshers) r.run();
            updateTvCategoryRenderBinding(catIndex);
        }
        View targetControl = resolveTargetRightControl(catIndex);
        if (moveFocusToRight && targetControl != null) {
            targetControl.requestFocus();
        }
    }

    private void registerTvRightControl(final View control) {
        if (!a.isTvDevice() || control == null) return;
        if (control.getId() == View.NO_ID) control.setId(View.generateViewId());
        final int targetCat = tvBuildingCategory >= 0 ? tvBuildingCategory : tvSelectedCategory;
        View catBtn =
                (targetCat >= 0 && targetCat < TV_CAT_COUNT)
                        ? tvCategoryViews.get(targetCat)
                        : tvActiveCategoryButton;
        if (catBtn != null) {
            control.setNextFocusLeftId(catBtn.getId());
        }
        if (targetCat >= 0 && targetCat < TV_CAT_COUNT) {
            tvCategoryControls[targetCat].add(control);
            tvCategoryControlTags[targetCat].add(
                    control.getTag() instanceof String ? (String) control.getTag() : "");
            if (tvCategoryFirstControls[targetCat] == null) {
                tvCategoryFirstControls[targetCat] = control;
                if (catBtn != null) catBtn.setNextFocusRightId(control.getId());
                if (targetCat == tvSelectedCategory) {
                    tvFirstRightControl = control;
                }
            }
            final View.OnFocusChangeListener existing = control.getOnFocusChangeListener();
            control.setOnFocusChangeListener(
                    (v, focused) -> {
                        if (existing != null) existing.onFocusChange(v, focused);
                        if (focused) {
                            recordTvRightRowFocus(targetCat, control);
                        }
                    });
        } else if (tvFirstRightControl == null) {
            tvFirstRightControl = control;
            if (catBtn != null) catBtn.setNextFocusRightId(control.getId());
        }
    }

    void tvCategory(LinearLayout parent, final int catIndex, String title, String tag) {
        final LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(14), a.dp(11), a.dp(16), a.dp(11));
        row.setTag(tag);
        row.setId(View.generateViewId());
        row.setFocusable(true);
        row.setFocusableInTouchMode(true);
        row.setClickable(true);
        a.pressFeedback(row);

        MobileShell.SettingIconView icon =
                new MobileShell.SettingIconView(
                        a, MobileShell.SettingIconView.kindForSetting(tag, title));
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(a.dp(30), a.dp(30));
        iconLp.rightMargin = a.dp(12);
        row.addView(icon, iconLp);

        final TextView label = a.text(title, 15.5f, MainActivity.WHITE);
        label.setTypeface(null, Typeface.BOLD);
        label.setSingleLine(true);
        row.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

        final boolean reducedTrans = a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        final android.graphics.drawable.Drawable focusedBg =
                TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(1));
        final android.graphics.drawable.Drawable activeBg =
                TvV17Surface.rounded(0x36ffffff, a.dp(14), 0x55ffffff, a.dp(1));
        final android.graphics.drawable.Drawable idleBg =
                TvV17Surface.rounded(
                        reducedTrans ? 0xee1c212b : 0x661a1f29, a.dp(14), 0x1affffff, a.dp(1));
        final Runnable applyVisual =
                () -> {
                    boolean active = (catIndex == tvSelectedCategory);
                    boolean focused = row.hasFocus();
                    if (focused) {
                        if (row.getBackground() != focusedBg) row.setBackground(focusedBg);
                        if (label.getCurrentTextColor() != 0xff101013) {
                            label.setTextColor(0xff101013);
                        }
                    } else {
                        android.graphics.drawable.Drawable targetBg = active ? activeBg : idleBg;
                        if (row.getBackground() != targetBg) row.setBackground(targetBg);
                        int textColor = active ? MainActivity.WHITE : 0xc8e4ebf5;
                        if (label.getCurrentTextColor() != textColor) {
                            label.setTextColor(textColor);
                        }
                    }
                };
        tvCategoryRefreshers.add(applyVisual);
        tvCategoryViews.put(catIndex, row);
        applyVisual.run();
        row.setOnFocusChangeListener(
                (v, focused) -> {
                    row.animate().cancel();
                    if (focused) {
                        if (catIndex != tvSelectedCategory) {
                            switchTvCategoryInPlace(catIndex, false);
                        }
                        applyVisual.run();
                        float scale = a.reduced ? 1f : 1.028f;
                        if (a.reduced) {
                            row.setScaleX(1f);
                            row.setScaleY(1f);
                        } else {
                            row.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        // Snap scale immediately on blur so the previous row never lingers halfway
                        // down while the newly focused row is already bright white.
                        row.setScaleX(1f);
                        row.setScaleY(1f);
                        applyVisual.run();
                    }
                });
        row.setOnClickListener(v -> switchTvCategoryInPlace(catIndex, true));
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, a.dp(50));
        size.bottomMargin = a.dp(8);
        parent.addView(row, size);
        if (catIndex == tvSelectedCategory) tvActiveCategoryButton = row;
    }

    void updatesCategory() {
        openTvCategoryById(TvSettingsRegistry.CAT_UPDATES_DIAG, null, false);
    }

    private void tvUpdatesDiagRows() {
        final UpdateManager updates = UpdateManager.get(a);
        String installed = UpdateManager.installedVersion(a);
        UpdateManager.Release rel = updates.available;
        String statusDetail =
                updates.busy
                        ? (updates.message
                                + (updates.percent >= 0 ? " · " + updates.percent + "%" : ""))
                        : (rel != null
                                ? ("发现应用新版 " + rel.version + " · " + updates.message)
                                : ("当前应用版本 "
                                        + installed
                                        + " · "
                                        + updates.message
                                        + "（刷新片源请去「片源与直播」）"));
        link(
                rel != null
                        ? (updates.ready() ? "立即安装新版 " + rel.version : "下载并更新至 " + rel.version)
                        : "检查软件更新",
                statusDetail,
                "settings-update-action",
                () -> {
                    if (updates.busy) {
                        updates.cancel();
                        a.refresh();
                    } else if (updates.ready() || rel != null) {
                        open(() -> new UpdateScreen(a).show());
                    } else {
                        updates.check(true);
                        a.toast("正在检查软件新版…");
                        open(() -> new UpdateScreen(a).show());
                    }
                });
        link(
                "自动更新策略",
                UpdateScreen.modeName(updates.mode()),
                "settings-update-mode",
                () -> {
                    String[] modes = {"notify", "download", "off"};
                    new AppDialog.Builder(a)
                            .setTitle("软件更新方式")
                            .setMessage("自动检查至少间隔六小时，仅在应用首页运行时发起。播放过程中不弹出更新窗口；安装始终由你确认。")
                            .setSingleChoiceItems(
                                    new String[] {"自动检查并提醒", "自动下载后提醒", "仅手动检查"},
                                    java.util.Arrays.asList(modes).indexOf(updates.mode()),
                                    (d, n) -> {
                                        updates.setMode(modes[n]);
                                        a.refresh();
                                    })
                            .setNegativeButton("返回", null)
                            .show();
                });
        link("运行日志", "查看本机最近异常与诊断记录", "settings-logs", this::diagnostics);
        if (!a.privateMode) {
            int pendingCrashes = CrashReportStore.loadUnsubmittedReports(a.getFilesDir()).size();
            String crashSub =
                    pendingCrashes > 0
                            ? ("待提交 " + pendingCrashes + " 条崩溃日志 · 自动提交 GitHub Issue / 扫码导出")
                            : "闪退自动留痕，支持一键提交 GitHub Issue 或扫码导出脱敏日志";
            link(
                    "崩溃日志与问题反馈",
                    crashSub,
                    "settings-crash-feedback",
                    () -> CrashReportDialog.show(a, true));
        }
        link(
                TvOfficialNotice.SETTINGS_ROW_TITLE,
                TvOfficialNotice.SETTINGS_ROW_DETAIL,
                TvOfficialNotice.SETTINGS_ROW_TAG,
                () -> TvOfficialNotice.showContactAndGroupDialog(a));
        LinearLayout donateBanner =
                TvOfficialNotice.buildInlineDonateCard(
                        a, TvOfficialNotice.DONATE_ROW_TAG, "settings-donate-qr");
        registerTvRightControl(donateBanner);
        LinearLayout.LayoutParams donateLp = new LinearLayout.LayoutParams(-1, -2);
        donateLp.bottomMargin = a.dp(14);
        a.body.addView(donateBanner, donateLp);
        link(
                "打开完整软件更新中心",
                "查看更新通道、版本信息、下载进度与安装包校验",
                "settings-update-full",
                () -> open(() -> new UpdateScreen(a).show()));
        link(
                "重新查看新手引导",
                "重温功能导览并重新启用首播手势提示",
                "settings-replay-onboarding",
                () -> {
                    OnboardingScreen.resetForReplay(a);
                    a.showOnboarding(true);
                });
        a.paragraph(
                "Marco Movie "
                        + installed
                        + " · 作者 Pilipala · 各社媒同名「"
                        + TvOfficialNotice.AUTHOR_SOCIAL_NAME
                        + "」（小红书/B站/抖音/公众号/视频号）· 唯一官网 "
                        + TvOfficialNotice.OFFICIAL_SITE_DISPLAY
                        + " · 交流群 "
                        + TvOfficialNotice.OFFICIAL_GROUP_URL
                        + " · 捐赠支持 "
                        + TvOfficialNotice.OFFICIAL_DONATE_URL
                        + " · github.com/Pilipala9919/MarcoMovie。本产品仅为工具，不含任何影视资源；内容与配置请自行合法获取。播放能力取决于服务授权和设备支持。");
    }

    private void tvUpdateInlineRows() {
        tvUpdatesDiagRows();
    }

    void link(String title, String detail, String key, Runnable action) {
        boolean tv = a.isTvDevice();
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(
                a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14), a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14));
        MobileShell.SettingIconView icon =
                new MobileShell.SettingIconView(
                        a, MobileShell.SettingIconView.kindForSetting(key, title));
        LinearLayout.LayoutParams iconLp =
                new LinearLayout.LayoutParams(a.dp(tv ? 36 : 38), a.dp(tv ? 36 : 38));
        iconLp.rightMargin = a.dp(tv ? 16 : 14);
        row.addView(icon, iconLp);

        boolean inlineValue = tv && detail != null && !detail.isEmpty() && detail.length() <= 20;
        LinearLayout copy = a.vertical();
        final TextView titleView = a.text(title, tv ? 16 : 17, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        copy.addView(titleView);
        final TextView caption;
        if (!inlineValue && detail != null && !detail.isEmpty()) {
            caption = a.text(detail, 12.5f, 0xa8ebebf5);
            caption.setPadding(0, a.dp(3), 0, 0);
            copy.addView(caption);
        } else {
            caption = null;
        }
        row.addView(copy, new LinearLayout.LayoutParams(0, -2, 1));

        final TextView rightValue;
        if (inlineValue) {
            rightValue = a.text(detail, 14, 0xb8ebebf5);
            rightValue.setSingleLine(true);
            rightValue.setPadding(a.dp(10), 0, a.dp(8), 0);
            row.addView(rightValue);
        } else {
            rightValue = null;
        }
        final TextView chevron = a.text("›", 22, 0x88ebebf5);
        row.addView(chevron);
        row.setTag(key);
        row.setId(View.generateViewId());
        row.setFocusable(tv);
        row.setFocusableInTouchMode(tv);
        row.setClickable(true);
        final int surface =
                tv && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)
                        ? 0xee1c212b
                        : 0xbf1a1f29;
        final android.graphics.drawable.Drawable restingBg =
                tv
                        ? TvV17Surface.rounded(surface, a.dp(14), 0x22ffffff, a.dp(1))
                        : a.bg(0xff222226, 14);
        final android.graphics.drawable.Drawable focusedBg =
                tv ? TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(1)) : null;
        row.setBackground(restingBg);
        row.setOnFocusChangeListener(
                (v, f) -> {
                    if (!tv) {
                        FocusMotion.style(
                                a,
                                row,
                                f,
                                0xff222226,
                                0xff37373e,
                                14,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.008f);
                        return;
                    }
                    row.animate().cancel();
                    if (f) {
                        if (row.getBackground() != focusedBg) row.setBackground(focusedBg);
                        titleView.setTextColor(0xff101013);
                        if (caption != null) caption.setTextColor(0xff48484a);
                        if (rightValue != null) rightValue.setTextColor(0xff3a3a3c);
                        chevron.setTextColor(0xff636366);
                        float scale = a.reduced ? 1f : 1.014f;
                        if (a.reduced) {
                            row.setScaleX(1f);
                            row.setScaleY(1f);
                        } else {
                            row.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        if (row.getBackground() != restingBg) row.setBackground(restingBg);
                        titleView.setTextColor(MainActivity.WHITE);
                        if (caption != null) caption.setTextColor(0xa8ebebf5);
                        if (rightValue != null) rightValue.setTextColor(0xb8ebebf5);
                        chevron.setTextColor(0x88ebebf5);
                        row.setScaleX(1f);
                        row.setScaleY(1f);
                    }
                });
        if (tv) {
            a.pressFeedback(row);
            registerTvRightControl(row);
        } else {
            MobileShell.bindCardTouchFeedback(a, row, a.bg(0xff222226, 14), a.bg(0xff303038, 14));
        }
        row.setOnClickListener(v -> action.run());
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, -2);
        size.bottomMargin = a.dp(14);
        a.body.addView(row, size);
    }

    void open(Runnable page) {
        a.open(new MainActivity.Screen(page), true);
    }

    void show() {
        if (a.isTvDevice()) {
            String savedCat =
                    a.prefs != null ? a.prefs.getString(Prefs.TV_SETTINGS_LAST_CATEGORY, "") : "";
            String initialCatId = TvSettingsRegistry.resolveInitialHomeEntryCategory(savedCat);
            openTvCategoryById(initialCatId, null, false);
            return;
        }
        page("设置", "");
        link("首页与壁纸", "", "settings-appearance", () -> open(this::appearance));
        link("播放与字幕", "", "settings-playback", () -> open(this::playback));
        link("搜索与数据", "", "settings-data", () -> open(this::data));
        link("软件更新", "", "settings-updates", () -> open(() -> new UpdateScreen(a).show()));
    }

    /** Direct entry to a TV settings category/row (Back returns to actual caller). */
    void showCategory(String categoryIdOrLegacy, String targetRowTag) {
        if (!a.isTvDevice()) {
            show();
            return;
        }
        openTvCategoryById(categoryIdOrLegacy, targetRowTag, true);
    }

    void openTvCategoryById(String categoryIdOrLegacy, String targetRowTag, boolean directEntry) {
        tvDirectEntryMode = directEntry;
        int idx = TvSettingsRegistry.resolveCategoryIndex(categoryIdOrLegacy);
        TvSettingsRegistry.CategorySpec spec = TvSettingsRegistry.specAt(idx);
        page(spec.title, spec.subtitle);
        renderTvCategoryRows(idx);
        syncTvCategoryRightFocusLink(idx);
        updateTvCategoryRenderBinding(idx);
        if (targetRowTag != null && !targetRowTag.trim().isEmpty()) {
            final String wanted = targetRowTag.trim();
            if (a.current != null) a.current.focus = wanted;
            a.ui.post(
                    () -> {
                        View target = MainActivity.findVisibleFocusableByTag(a.root, wanted);
                        if (target != null) {
                            target.requestFocus();
                        } else {
                            View fallback = resolveTargetRightControl(idx);
                            if (fallback != null) fallback.requestFocus();
                        }
                    });
        }
    }

    private boolean hasConfiguredSites() {
        return a.config != null && a.config.sites != null && !a.config.sites.isEmpty();
    }

    private void tvSourcesRows() {
        boolean configured = hasConfiguredSites();
        if (configured) {
            link("管理订阅", "切换订阅、多源合并自动分组或管理线路", "settings-source-manager", a::chooseOrImport);
            link("导入订阅", "手机扫码、遥控输入或本地包（支持多行地址自动分组）", "settings-import", a::importDialog);
        } else {
            link("导入订阅", "手机扫码、遥控输入或本地包（首次使用请先导入配置源）", "settings-import", a::importDialog);
            link("管理订阅", "切换订阅、多源合并自动分组或管理线路", "settings-source-manager", a::chooseOrImport);
        }
        link(
                "立即刷新全部订阅源",
                SourceController.subscriptionAutoUpdateSummary(a) + "（刷新片源列表，非软件升级）",
                "settings-refresh-subs",
                () -> SourceController.runDailyAutoUpdateIfNeeded(a, true));
        link(
                "电视直播源",
                "导入或管理多份 M3U / TXT / JSON 直播源",
                "settings-live-import",
                () -> SourceController.showLiveImportDialog(a));
        String epgAddr = a.prefs.getString(Prefs.LIVE_EPG_URL, "");
        link(
                "节目单 (EPG)",
                epgAddr.isEmpty()
                        ? "支持 .xml / .xml.gz 节目单与回看时移（默认读取列表 x-tvg-url）"
                        : "当前：" + epgAddr,
                "settings-live-epg",
                () -> SourceController.showEpgDialog(a));
        toggle("导入的订阅源每天自动更新", Prefs.SUBSCRIPTION_AUTO_UPDATE, true, null);
        if (a.config != null && a.config.depots.length() > 1) {
            link(
                    "切换影视仓线路",
                    "当前订阅包含 " + a.config.depots.length() + " 个子仓库，点击切换",
                    "settings-depots",
                    () -> SourcePicker.showWarehouses(a));
        }
        link(
                "网盘与账号",
                "网盘扫码登录、凭据与网盘顺序（由配置提供）",
                "settings-accounts",
                () -> AccountPanel.show(a, null));
        link(
                "挂载 AList 网盘 / 媒体库",
                AlistAccounts.statusSummary(a),
                "settings-alist-mount",
                () -> AlistAccounts.openManager(a, a::refresh));
        link(
                "存储权限（网盘扫码 Cookie 保存）",
                a.storagePermissionStatusText(),
                "settings-storage-permission",
                () -> {
                    if (android.os.Build.VERSION.SDK_INT >= 30) {
                        a.openTvStoragePermissionSettings();
                    } else {
                        a.requestRuntimeStoragePermission(a::refresh);
                    }
                });

        Runnable buildAdvancedRows =
                () -> {
                    tvSectionHeader("高级");
                    ints(
                            "同时搜索的来源数",
                            Prefs.SEARCH_THREADS,
                            new String[] {"2 个 · 轻量", "4 个 · 均衡", "6 个 · 快速"},
                            new int[] {2, 4, 6},
                            6);
                    ints(
                            "单个来源等待时间",
                            Prefs.SEARCH_TIMEOUT,
                            new String[] {"10 秒", "20 秒", "30 秒"},
                            new int[] {10, 20, 30},
                            20);
                    toggle(
                            "内置 CPython 3.11 爬虫引擎",
                            Prefs.NATIVE_PYTHON_ENABLED,
                            true,
                            a::closeEngines);
                    toggle(
                            "异步 JS 源 WebView 兜底引擎",
                            Prefs.WEBVIEW_JS_FALLBACK,
                            true,
                            a::closeEngines);
                    toggle("启用来源扩展", Prefs.EXPERIMENTAL_CSP, true, a::closeEngines);
                    toggle("仅允许 HTTPS 插件", Prefs.ONLY_ALLOW_HTTPS_PLUGINS, false, a::closeEngines);
                    if (!a.privateMode) {
                        link(
                                "局域网蜘蛛网关",
                                SpiderGatewayDialog.statusSummary(a),
                                "settings-spider-gateway",
                                () -> SpiderGatewayDialog.show(a));
                    }
                    String udpxyAddr = a.prefs.getString(Prefs.LIVE_UDPXY_URL, "");
                    link(
                            "组播转单播网关 (udpxy)",
                            udpxyAddr.isEmpty()
                                    ? "配置路由器 udpxy / rtp2httpd 地址播放原画 1080i50 / 4K 组播源"
                                    : "当前：" + udpxyAddr,
                            "settings-live-udpxy",
                            () -> SourceController.showUdpxyDialog(a));
                    toggle("直播优先最高画质与 IPv6", Prefs.LIVE_HIGH_QUALITY, true, null);
                    toggle("跨源同名频道智能聚合", Prefs.LIVE_MERGE_SOURCES, true, null);
                };
        boolean deferOffscreen =
                a.isTvDevice()
                        && a.ui != null
                        && !tvDirectEntryMode
                        && (a.current == null
                                || a.current.focus == null
                                || a.current.focus.isEmpty())
                        && tvCategoryPanes[TV_CAT_SOURCES] != null
                        && a.body == tvCategoryPanes[TV_CAT_SOURCES];
        if (deferOffscreen) {
            final LinearLayout targetPane = tvCategoryPanes[TV_CAT_SOURCES];
            final int ticket = a.generation;
            targetPane.postOnAnimation(
                    () -> {
                        if (a.isFinishing()
                                || a.generation != ticket
                                || tvCategoryPanes[TV_CAT_SOURCES] != targetPane) {
                            return;
                        }
                        LinearLayout prevBody = a.body;
                        int prevBuilding = tvBuildingCategory;
                        tvBuildingCategory = TV_CAT_SOURCES;
                        a.body = targetPane;
                        try {
                            buildAdvancedRows.run();
                        } finally {
                            tvBuildingCategory = prevBuilding;
                            a.body = prevBody;
                        }
                        syncTvCategoryRightFocusLink(TV_CAT_SOURCES);
                    });
        } else {
            buildAdvancedRows.run();
        }
    }

    private void tvPlaybackRows() {
        // Row 1: 默认倍速（电视端按剧集连播会话保持，返回主页或切换其他剧集自动重置 1.0×）
        if (a.prefs != null && Math.abs(a.prefs.getFloat(Prefs.PLAY_SPEED, 1f) - 1f) > 0.001f) {
            a.prefs.edit().putFloat(Prefs.PLAY_SPEED, 1f).apply();
        }
        link(
                "默认倍速",
                "1.0× · 同剧连播保持，返回主页自动重置",
                "setting-play_speed",
                () -> {
                    if (a.prefs != null
                            && Math.abs(a.prefs.getFloat(Prefs.PLAY_SPEED, 1f) - 1f) > 0.001f) {
                        a.prefs.edit().putFloat(Prefs.PLAY_SPEED, 1f).apply();
                    }
                    new AppDialog.Builder(a)
                            .setTitle("默认倍速说明")
                            .setMessage(
                                    "电视端每次从主页或新剧集进入均默认 1.0× 原速播放；播放中调节的倍速仅在同一部剧连续选集播放时保持，返回主页或切换其他剧集后自动重置为 1.0×。")
                            .setPositiveButton("知道了", null)
                            .show();
                });
        toggle("自动播放下一集", Prefs.AUTO_NEXT, true, null);
        ints(
                "画面比例",
                Prefs.ASPECT,
                new String[] {"适应", "铺满", "16:9", "4:3", "裁切填充"},
                new int[] {0, 1, 2, 3, 4},
                0);
        int skipRecordCount = PlaybackControls.countVideoSkipRecords(a);
        int v2MarkerCount = VideoMarkerRepository.count(a);
        String skipSummary =
                (skipRecordCount <= 0 && v2MarkerCount <= 0)
                        ? "管理按剧跳过规则与按集打点记录"
                        : ("本剧规则 "
                                + skipRecordCount
                                + " 条 · 本集打点 "
                                + (v2MarkerCount < 0 ? "读取异常" : v2MarkerCount + " 条")
                                + " · 点击查看或清空");
        link(
                "片头片尾管理",
                skipSummary,
                "setting-" + Prefs.VIDEO_SKIP_RECORDS,
                () -> PlaybackControls.showVideoSkipRecordsDialog(a, a::refresh));
        link(
                "跳过片头片尾 3 秒可取消倒计时",
                PlayerHudPrefs.isSkipCountdownEnabled(a) ? "开启（3 秒倒计时）" : "关闭（立即跳过）",
                "setting-" + PlayerHudPrefs.KEY_SKIP_COUNTDOWN,
                () -> {
                    PlayerHudPrefs.setSkipCountdownEnabled(
                            a, !PlayerHudPrefs.isSkipCountdownEnabled(a));
                    a.refresh();
                });
        ints(
                "循环播放",
                Prefs.REPEAT_MODE,
                new String[] {"关闭", "单集循环", "列表循环"},
                new int[] {0, 1, 2},
                0);
        ints(
                "音效",
                Prefs.AUDIO_EFFECT,
                new String[] {"原声", "影院", "人声清晰", "柔和低音"},
                new int[] {0, 1, 2, 3},
                0);
        ints(
                "人声与响度增益",
                Prefs.LOUDNESS_BOOST,
                new String[] {"关闭", "+4 dB", "+8 dB", "+12 dB"},
                new int[] {0, 4, 8, 12},
                0);
        ints(
                "画面色彩",
                Prefs.PICTURE_EFFECT,
                new String[] {"原始", "明亮", "影院", "柔和"},
                new int[] {0, 1, 2, 3},
                0);

        tvSectionHeader("兼容与缓冲");
        ints(
                "播放器内核",
                Prefs.PLAYER_ENGINE,
                new String[] {
                    "Exo (Media3 · 默认)",
                    "MPV 高画质 (libmpv · HDR / Anime4K / ASS)",
                    "IJK 兼容模式 (Media3 + FFmpeg)",
                    "系统播放器"
                },
                new int[] {0, 3, 2, 1},
                0);
        ints(
                "解码方式",
                Prefs.DECODER_MODE,
                new String[] {"自动", "硬件解码", "软件解码优先"},
                new int[] {0, 1, 2},
                0);
        ints(
                "画面输出",
                Prefs.VIDEO_OUTPUT,
                new String[] {"保真输出 · HDR 与流畅度优先", "兼容输出 · 支持应用内调色"},
                new int[] {0, 1},
                0);
        toggle("4K HDR 隧道模式", Prefs.TUNNELED_PLAYBACK, false, null);
        toggle("MPV HDR 自动峰值色调映射 (libplacebo)", Prefs.HDR_TONE_MAPPING, true, null);
        toggle("MPV Anime4K 实时超分滤镜", Prefs.ANIME4K_ENABLED, false, null);
        toggle("HLS 伪装分片实时修正代理", Prefs.HLS_PROXY_ENABLED, true, null);
        toggle("HLS 点播广告分段启发式过滤", Prefs.HLS_AD_STRIP, false, null);
        ints(
                "直链本地分块缓存",
                Prefs.MEDIA_CACHE_MB,
                new String[] {"关闭", "128 MB", "256 MB（默认）", "512 MB", "1024 MB"},
                new int[] {0, 128, 256, 512, 1024},
                256);
        ints(
                "网络缓冲",
                Prefs.BUFFER_SECONDS,
                new String[] {"15 秒 · 节省内存", "30 秒 · 均衡", "50 秒 · 网络波动"},
                new int[] {15, 30, 50},
                30);
        toggle("优先使用兼容音频解码", Prefs.SOFTWARE_AUDIO, false, null);
        toggle("优先选择 AAC 音轨", Prefs.PREFER_AAC, false, null);
        link("解码组件", "查看本机已加载的音频与视频扩展", "settings-decoders", () -> open(this::decoders));
        a.paragraph(
                "兼容音频解码仅切换音频，不强制视频软解码；AAC 优先仅在媒体包含可用 AAC 音轨时生效。以上两项用于 Media3。系统播放器支持的字幕与网络格式少于 Media3。");
    }

    private void openDanmuPanelFromSettings() {
        android.app.AlertDialog dlg = DanmuSettingsPanel.showDialog(a, a.isTvDevice(), null);
        dlg.setOnDismissListener(
                d -> {
                    if (!a.isFinishing()
                            && (android.os.Build.VERSION.SDK_INT < 17 || !a.isDestroyed())) {
                        a.refresh();
                    }
                });
    }

    private void tvSubtitleDanmuRows() {
        // Row 1: 自动加载片源弹幕
        toggle("自动加载片源弹幕", "片源自带弹幕可独立使用，无需配置自定义服务（以后播放沿用）", Prefs.DANMAKU_DEFAULT, true, null);
        DanmuSettingsPanel.DanmuConfig dmCfg = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        String dmSummary = DanmuSettingsPanel.formatConfigSummary(dmCfg);
        link("弹幕服务与偏好", dmSummary, "setting-danmu-panel", this::openDanmuPanelFromSettings);
        int subSize = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        int subBottom = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        int subStyle = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
        link(
                "字幕大小与位置（全屏预览调校）",
                "字号 "
                        + subSize
                        + " · 底部高度 "
                        + subBottom
                        + "dp · "
                        + SubtitleOverlayView.STYLE_LABELS[subStyle],
                "setting-" + Prefs.SUBTITLE_SIZE,
                () -> PlaybackControls.showSubtitleAdjuster(a, null, a::refresh));
        ints(
                "字幕样式",
                Prefs.SUBTITLE_STYLE,
                SubtitleOverlayView.STYLE_LABELS,
                new int[] {0, 1, 2, 3, 4, 5, 6, 7},
                0);
        ints(
                "默认音轨偏好",
                Prefs.AUDIO_TRACK_PREFERENCE,
                new String[] {"智能默认（自动避开解说音轨）", "优先中文 / 国语", "优先原声 / 片源默认"},
                new int[] {0, 1, 2},
                0);

        tvSectionHeader("弹幕外观与过滤");
        link(
                "弹幕显示区域与密度",
                "区域 "
                        + Math.round(dmCfg.displayArea * 100f)
                        + "% · 同屏上限 "
                        + dmCfg.maxRows
                        + " 行（进入弹幕面板调节）",
                "setting-danmu-display",
                this::openDanmuPanelFromSettings);
        link(
                "弹幕字号、透明度与时间偏移",
                "字号 "
                        + Math.round(dmCfg.fontSizeSp)
                        + " · 透明度 "
                        + Math.round(dmCfg.opacity * 100f)
                        + "% · 偏移 "
                        + String.format(
                                java.util.Locale.ROOT, "%+.1fs", dmCfg.timeOffsetMs / 1000f),
                "setting-danmu-style",
                this::openDanmuPanelFromSettings);
        int ruleCount = dmCfg.blockRules != null ? dmCfg.blockRules.size() : 0;
        link(
                "弹幕屏蔽词与过滤规则",
                (ruleCount == 0 ? "未设屏蔽规则" : ("已设 " + ruleCount + " 条屏蔽规则")) + " · 滚动/顶部/底部弹幕开关",
                "setting-danmu-filter",
                this::openDanmuPanelFromSettings);
        a.paragraph("片源自带弹幕、插件推送弹幕与本地弹幕文件均可独立使用，无需配置自定义服务地址；填写自定义服务后仅在片源未提供弹幕时参与匹配。");
    }

    private void tvAppearanceRemoteRows() {
        int currentDockStyle = a.useLeftDock() ? 1 : 0;
        String[] dockLabels = new String[] {"顶部沉浸式导航栏（推荐）", "左侧简洁导航栏"};
        link(
                "首页导航栏位置",
                dockLabels[currentDockStyle],
                "setting-" + Prefs.TV_DOCK_POSITION,
                () ->
                        new AppDialog.Builder(a)
                                .setTitle("首页导航栏位置")
                                .setMessage("顶部导航栏常显左上角品牌标识，向下滚动时自动缩小为渐变沉浸样式；也可切换为左侧可展开导航栏。")
                                .setSingleChoiceItems(
                                        dockLabels,
                                        currentDockStyle,
                                        (d, which) -> {
                                            android.content.SharedPreferences.Editor ed =
                                                    a.prefs.edit();
                                            if (which == 0) {
                                                ed.putInt(Prefs.TV_NAVIGATION_MODE, 0)
                                                        .putInt(Prefs.TV_DOCK_POSITION, 1);
                                            } else {
                                                ed.putInt(Prefs.TV_NAVIGATION_MODE, 1);
                                            }
                                            ed.apply();
                                            a.refresh();
                                        })
                                .setNegativeButton("返回", null)
                                .show());
        link(
                "自定义导航栏顺序与名称",
                TvNavConfig.summaryLabel(a),
                "setting-tv-nav-custom",
                () -> TvNavCustomizeDialog.show(a, a::refresh));
        link(
                "首页壁纸与柔光主题",
                HomeAmbient.activeBackgroundSummary(a),
                "settings-wallpaper",
                () -> open(this::wallpaper));
        addTvBackgroundStudioInline(true);
        ints(
                "播放界面样式",
                Prefs.TV_PLAYER_STYLE,
                new String[] {"现代悬浮卡片（默认）", "经典双层工具栏"},
                new int[] {0, 1},
                0);
        boolean modernPlayerStyle = a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
        link(
                "播放工具条按钮顺序",
                TvPlayerToolbarOrder.settingsSummary(
                        a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, ""), modernPlayerStyle),
                "setting-" + Prefs.TV_PLAYER_TOOLBAR_ORDER,
                this::showTvToolbarOrderDialog);
        link(
                "界面大小",
                TvLayoutPolicy.percent(a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100))
                        + "% · 按钮、文字与图标一起调整",
                "setting-ui_scale_percent",
                () -> {
                    String[] scaleLabels = new String[] {"标准 · 自动适配", "放大 · 110%", "更大 · 120%"};
                    int[] scaleValues = new int[] {100, 110, 120};
                    int curScale =
                            a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100) == 120
                                    ? 2
                                    : a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100) == 110 ? 1 : 0;
                    new AppDialog.Builder(a)
                            .setTitle("界面大小")
                            .setMessage("标准会自动适配屏幕分辨率。观看距离较远时可放大；选择后界面重新载入。")
                            .setSingleChoiceItems(
                                    scaleLabels,
                                    curScale,
                                    (d, n) -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.UI_SCALE_PERCENT, scaleValues[n])
                                                .apply();
                                        a.recreate();
                                    })
                            .setNegativeButton("返回", null)
                            .show();
                });
        ints(
                "导航栏字体与按钮大小",
                Prefs.NAV_SCALE_PERCENT,
                new String[] {"紧凑 · 85%", "标准 · 100%", "偏大 · 115%", "大号 · 130%", "特大 · 140%"},
                new int[] {85, 100, 115, 130, 140},
                100);
        ints(
                "每行海报",
                Prefs.HOME_COLUMNS,
                new String[] {"最多 5 张 · 舒展", "最多 6 张", "最多 7 张", "最多 8 张"},
                new int[] {5, 6, 7, 8},
                5);
        toggle(
                "减少透明效果",
                Prefs.REDUCED_TRANSPARENCY,
                false,
                () -> com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root));
        toggle("开屏动画", Prefs.STARTUP_ANIMATION, true, null);
        toggle(
                "减少动态效果",
                Prefs.REDUCED,
                false,
                () -> a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false));

        tvSectionHeader("播放页界面与提示");
        toggle("播放中右上角显示进度与时间", Prefs.TV_PLAYER_TOP_RIGHT_HUD, true, null);
        link(
                "播放中底部细进度条",
                PlayerHudPrefs.isSlimProgressEnabled(a) ? "开启" : "关闭",
                "setting-" + PlayerHudPrefs.KEY_SLIM_PROGRESS,
                () -> {
                    PlayerHudPrefs.setSlimProgressEnabled(
                            a, !PlayerHudPrefs.isSlimProgressEnabled(a));
                    a.refresh();
                });
        link(
                "起播画质规格提示",
                PlayerHudPrefs.isStartSpecHudEnabled(a) ? "开启" : "关闭",
                "setting-" + PlayerHudPrefs.KEY_START_SPEC_HUD,
                () -> {
                    PlayerHudPrefs.setStartSpecHudEnabled(
                            a, !PlayerHudPrefs.isStartSpecHudEnabled(a));
                    a.refresh();
                });
    }

    private void tvDataSyncRows() {
        link("观看历史", "查看、继续播放或删除本机观看记录", "settings-history", () -> open(a::historyPage));
        if (!a.privateMode) {
            link(
                    "多端网络同步",
                    CloudSyncDialog.statusSummary(a),
                    "settings-cloud-sync",
                    () -> CloudSyncDialog.show(a, a::refresh));
        }
        link(
                "备份配置与偏好",
                "导出配置与偏好，请妥善保管；不含插件单独保存的登录状态",
                "settings-backup",
                () -> pick(45, "application/json", true));
        link(
                "还原配置与偏好",
                "从 Marco Movie 备份文件还原",
                "settings-restore",
                () -> pick(46, "application/json", false));
        File localSafe = lastSafeBackupFile(a);
        if (!a.privateMode && localSafe != null && localSafe.isFile() && localSafe.length() > 0) {
            link(
                    "从本机安全备份副本还原",
                    "读取上次有效导出的保护副本（" + formatBackupSize(localSafe.length()) + "），防止覆盖写坏后丢数据",
                    "settings-restore-safe-copy",
                    () -> restoreFromLocalSafeCopy(a));
        }

        tvSectionHeader("缓存与重置");
        link(
                "重新加载首页图片与片单",
                "清除内存与磁盘中的首页缓存",
                "settings-clear-images",
                () -> {
                    a.images.evictAll();
                    a.homeData.clear();
                    try {
                        File snapDir = new File(a.getCacheDir(), "home_snap_v1");
                        File[] files = snapDir.listFiles();
                        if (files != null) for (File f : files) f.delete();
                    } catch (Throwable ignored) {
                    }
                    a.toast("已清除首页缓存");
                });
        link(
                "清除搜索记录",
                "清除最近搜索，保留网盘登录",
                "settings-clear-history",
                () ->
                        confirm(
                                "清除搜索记录？",
                                () -> {
                                    a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                    a.refresh();
                                }));
        link(
                "重置观看历史（保留损坏备份）",
                "清空本机观看记录并解除损坏锁定，已生成的本地备份继续保留",
                "settings-reset-history",
                () ->
                        confirm(
                                "重置观看历史（保留损坏备份）？",
                                () -> {
                                    final boolean wasCorrupted =
                                            WatchHistory.isCorrupted()
                                                    || a.prefs.getBoolean(
                                                            WatchHistory.CORRUPTED_PREF, false);
                                    final java.util.List<WatchHistory.Entry> prev =
                                            wasCorrupted
                                                    ? java.util.Collections.emptyList()
                                                    : a.watchHistory();
                                    a.clearWatchHistory(
                                            () -> {
                                                if (!wasCorrupted) {
                                                    CloudSyncDialog.onHistoryCleared(a, prev);
                                                }
                                                a.toast("已重置观看历史");
                                                a.refresh();
                                            });
                                }));
        link(
                "恢复播放与外观默认设置",
                "保留来源配置和网盘登录",
                "settings-reset",
                () ->
                        confirm(
                                "恢复默认设置？",
                                () -> {
                                    android.content.SharedPreferences.Editor edit = a.prefs.edit();
                                    for (String key : KEYS) edit.remove(key);
                                    edit.remove(Prefs.TV_PLAYER_TOOLBAR_ORDER);
                                    edit.remove(Prefs.TV_SETTINGS_LAST_CATEGORY);
                                    edit.apply();
                                    resetTvNavigationMemory();
                                    TvNavConfig.reset(a);
                                    a.reduced = false;
                                    a.recreate();
                                }));
    }

    void decoders() {
        page("解码组件", "组件随应用安装，无需另外下载解码包。");
        a.paragraph(DecoderSupport.description());
    }

    void openConfigSiteHome(Cms.Site targetSite) {
        a.prefs.edit().putString(Prefs.SELECTED_SITE, targetSite.key).apply();
        MobileShell.activeTab = 0;
        a.back.clear();
        a.open(new MainActivity.Screen(a::home), false);
    }

    interface AccountChoice {
        void accept(int index);
    }

    void showAccountActionPicker(
            String title, String subtitle, String[] labels, AccountChoice handleChoice) {
        if (!a.isTvDevice()) {
            MobileShell.showDrawerPicker(a, title, subtitle, labels, -1, handleChoice::accept);
        } else {
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setItems(labels, (d, which) -> handleChoice.accept(which))
                    .setNegativeButton("关闭", null)
                    .show();
        }
    }

    static Cms.Video findSortCard(java.util.List<Cms.Video> videos) {
        if (videos == null) return null;
        for (Cms.Video v : videos) {
            if (v == null) continue;
            String id = v.id == null ? "" : v.id.toLowerCase(java.util.Locale.ROOT);
            String act = v.action == null ? "" : v.action.toLowerCase(java.util.Locale.ROOT);
            String title = v.title == null ? "" : v.title;
            if (id.contains("pan_order")
                    || id.contains("panorder")
                    || id.contains("panpaixu")
                    || act.contains("pan_order")
                    || act.contains("panorder")
                    || act.contains("panpaixu")
                    || title.contains("优先顺序")
                    || title.contains("搜索顺序")
                    || title.contains("网盘排序")
                    || title.contains("网盘顺序")
                    || title.contains("盘序")) {
                return v;
            }
        }
        return null;
    }

    static Cms.Video findDirectDriveCard(java.util.List<Cms.Video> videos, String driveKey) {
        if (videos == null || driveKey == null || driveKey.trim().isEmpty()) return null;
        String target = driveKey.trim().toLowerCase(java.util.Locale.ROOT);
        Cms.Video fallback = null;
        for (Cms.Video v : videos) {
            if (v == null) continue;
            String title = v.title == null ? "" : v.title.trim();
            String id = v.id == null ? "" : v.id.toLowerCase(java.util.Locale.ROOT);
            String act = v.action == null ? "" : v.action.toLowerCase(java.util.Locale.ROOT);
            if (title.contains("清除") || title.contains("重置") || id.contains("clear")) {
                continue;
            }
            String detected = PluginDialogStyler.detectDriveKeyFromLabel(title);
            if (detected == null) detected = PluginDialogStyler.detectDriveKeyFromLabel(id);
            if (detected == null) detected = PluginDialogStyler.detectDriveKeyFromLabel(act);
            if (!target.equals(detected)) continue;
            if (title.contains("扫码")
                    || title.contains("二维码")
                    || title.contains("登录")
                    || title.contains("登入")
                    || id.contains("qr")
                    || id.contains("scan")
                    || id.contains("login")) {
                return v;
            }
            if (fallback == null) fallback = v;
        }
        return fallback;
    }

    void openDirectDriveConfigAction(
            Cms.Site targetSite, String driveKey, boolean toggleEnableOnly) {
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(targetSite);
                        String homeRaw = eng.home();
                        java.util.List<Cms.Category> cats = Cms.categories(homeRaw);
                        Cms.Listing homeList = null;
                        try {
                            homeList = Cms.listing(homeRaw);
                        } catch (Throwable ignored) {
                        }
                        Cms.Video matched =
                                findDirectDriveCard(
                                        homeList != null ? homeList.videos : null, driveKey);
                        if (matched == null && cats != null) {
                            for (Cms.Category c : cats) {
                                String cname = c.name == null ? "" : c.name;
                                String cid =
                                        c.id == null ? "" : c.id.toLowerCase(java.util.Locale.ROOT);
                                if (driveKey.equals(
                                                PluginDialogStyler.detectDriveKeyFromLabel(cname))
                                        || cname.contains("网盘")
                                        || cname.contains("云盘")
                                        || cname.contains("扫码")
                                        || cname.contains("登录")
                                        || cid.contains("pan")
                                        || cid.contains("config")) {
                                    try {
                                        Cms.Listing cl = Cms.listing(eng.category(c.id, 1));
                                        matched = findDirectDriveCard(cl.videos, driveKey);
                                        if (matched != null) break;
                                    } catch (Throwable ignored) {
                                    }
                                }
                            }
                        }
                        if (matched != null) {
                            final Cms.Video card = matched;
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || ticket != a.generation) return;
                                        PluginDialogStyler.watch(a);
                                        a.openListing(targetSite, card);
                                    });
                            return;
                        }
                        String targetApi =
                                targetSite.api == null
                                        ? ""
                                        : targetSite.api.toLowerCase(java.util.Locale.ROOT);
                        String targetKey =
                                targetSite.key == null
                                        ? ""
                                        : targetSite.key.toLowerCase(java.util.Locale.ROOT);
                        final boolean isMyDriveSpider =
                                targetApi.contains("mydrive") || targetKey.contains("mydrive");
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    if (isMyDriveSpider) {
                                        PluginDialogStyler.armDirectDriveForward(
                                                a, driveKey, toggleEnableOnly);
                                        a.sourceAction(targetSite, "LoginShow");
                                    } else {
                                        PluginDialogStyler.clearDirectDriveForward();
                                        openDynamicConfigSiteAction(targetSite, "LoginShow");
                                    }
                                });
                    } catch (Throwable error) {
                        String targetApi =
                                targetSite.api == null
                                        ? ""
                                        : targetSite.api.toLowerCase(java.util.Locale.ROOT);
                        String targetKey =
                                targetSite.key == null
                                        ? ""
                                        : targetSite.key.toLowerCase(java.util.Locale.ROOT);
                        final boolean isMyDriveSpider =
                                targetApi.contains("mydrive") || targetKey.contains("mydrive");
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    if (isMyDriveSpider) {
                                        PluginDialogStyler.armDirectDriveForward(
                                                a, driveKey, toggleEnableOnly);
                                        a.sourceAction(targetSite, "LoginShow");
                                    } else {
                                        PluginDialogStyler.clearDirectDriveForward();
                                        openConfigSiteHome(targetSite);
                                    }
                                });
                    }
                });
    }

    void showDynamicVideoPicker(
            Cms.Site targetSite, String title, java.util.List<Cms.Video> videos) {
        if (videos == null || videos.isEmpty()) {
            openConfigSiteHome(targetSite);
            return;
        }
        String[] labels = new String[videos.size() + 1];
        for (int i = 0; i < videos.size(); i++) {
            Cms.Video v = videos.get(i);
            String name = v.title == null ? "" : v.title.trim();
            String rem = v.remarks == null ? "" : v.remarks.trim();
            if (!rem.isEmpty() && !rem.equals(name)) {
                labels[i] = name + " · " + rem;
            } else {
                labels[i] = name;
            }
        }
        labels[videos.size()] = "打开完整配置中心";
        showAccountActionPicker(
                title,
                "选择需要执行的网盘配置操作",
                labels,
                idx -> {
                    if (idx < 0 || idx > videos.size()) return;
                    if (idx == videos.size()) {
                        openConfigSiteHome(targetSite);
                    } else {
                        a.openListing(targetSite, videos.get(idx));
                    }
                });
    }

    void openDynamicConfigCategory(Cms.Site targetSite, Cms.Category cat) {
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(targetSite);
                        Cms.Listing list = Cms.listing(eng.category(cat.id, 1));
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    showDynamicVideoPicker(targetSite, cat.name, list.videos);
                                });
                    } catch (Throwable error) {
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    openConfigSiteHome(targetSite);
                                });
                    }
                });
    }

    void openDynamicConfigSiteAction(Cms.Site targetSite, String action) {
        final int ticket = a.generation;
        final boolean wantSort = "panSortShow".equals(action) || "panSourceSortShow".equals(action);
        a.worker.execute(
                () -> {
                    try {
                        CspEngine.syncAllPluginActivities(a);
                        SourceEngine eng = a.engine(targetSite);
                        String homeRaw = eng.home();
                        java.util.List<Cms.Category> cats = Cms.categories(homeRaw);
                        Cms.Listing homeList = null;
                        try {
                            homeList = Cms.listing(homeRaw);
                        } catch (Throwable ignored) {
                        }
                        if (wantSort) {
                            Cms.Video sortCard =
                                    findSortCard(homeList != null ? homeList.videos : null);
                            if (sortCard == null && cats != null) {
                                for (Cms.Category c : cats) {
                                    String cid =
                                            c.id == null
                                                    ? ""
                                                    : c.id.toLowerCase(java.util.Locale.ROOT);
                                    String cname = c.name == null ? "" : c.name;
                                    if (cid.contains("pan")
                                            || cid.contains("config")
                                            || cname.contains("网盘")
                                            || cname.contains("配置")) {
                                        try {
                                            Cms.Listing cl = Cms.listing(eng.category(c.id, 1));
                                            sortCard = findSortCard(cl.videos);
                                            if (sortCard != null) break;
                                        } catch (Throwable ignored) {
                                        }
                                    }
                                }
                            }
                            if (sortCard != null) {
                                final Cms.Video found = sortCard;
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing() || ticket != a.generation) return;
                                            a.openListing(targetSite, found);
                                        });
                                return;
                            }
                        }
                        if (cats != null && !cats.isEmpty()) {
                            final java.util.List<Cms.Category> categoryList = cats;
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || ticket != a.generation) return;
                                        String[] labels = new String[categoryList.size() + 1];
                                        for (int i = 0; i < categoryList.size(); i++) {
                                            labels[i] = categoryList.get(i).name;
                                        }
                                        labels[categoryList.size()] = "打开完整配置中心";
                                        showAccountActionPicker(
                                                targetSite.name,
                                                "选择需要配置的网盘或功能分类",
                                                labels,
                                                idx -> {
                                                    if (idx < 0 || idx > categoryList.size())
                                                        return;
                                                    if (idx == categoryList.size()) {
                                                        openConfigSiteHome(targetSite);
                                                    } else {
                                                        openDynamicConfigCategory(
                                                                targetSite, categoryList.get(idx));
                                                    }
                                                });
                                    });
                            return;
                        }
                        if (homeList != null && !homeList.videos.isEmpty()) {
                            final java.util.List<Cms.Video> videos = homeList.videos;
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || ticket != a.generation) return;
                                        showDynamicVideoPicker(targetSite, targetSite.name, videos);
                                    });
                            return;
                        }
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    openConfigSiteHome(targetSite);
                                });
                    } catch (Throwable error) {
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || ticket != a.generation) return;
                                    openConfigSiteHome(targetSite);
                                });
                    }
                });
    }

    void accountAction(String action) {
        accountAction(action, null);
    }

    void accountAction(String action, Cms.Site explicitConfigSite) {
        if (a.config != null) {
            Cms.Site fallback = explicitConfigSite;
            if (fallback == null) {
                fallback = AccountPanel.findConfigCenterSite(a);
            }
            if (fallback == null) {
                String currentKey = a.prefs.getString(Prefs.SELECTED_SITE, "");
                if (currentKey != null && !currentKey.isEmpty()) {
                    for (Cms.Site site : a.config.sites) {
                        if (currentKey.equals(site.key)
                                && SourceController.isDedicatedConfigSite(site)) {
                            fallback = site;
                            break;
                        }
                    }
                }
            }
            if (fallback == null) {
                for (Cms.Site site : a.config.sites) {
                    if (site.api != null
                            && site.api.toLowerCase(java.util.Locale.ROOT).contains("mydrive")) {
                        fallback = site;
                        break;
                    }
                    if (fallback == null && SourceController.isDedicatedConfigSite(site)) {
                        fallback = site;
                    }
                }
            }
            if (fallback == null) {
                for (Cms.Site site : a.config.sites) {
                    if (SourceController.isConfigOrNetdiskSite(site)) {
                        fallback = site;
                        break;
                    }
                }
            }
            if (fallback != null) {
                if (!a.available(fallback)) {
                    a.notice("请先在“搜索与数据”中启用来源扩展。");
                    return;
                }
                final Cms.Site targetSite = fallback;
                String api =
                        targetSite.api == null
                                ? ""
                                : targetSite.api.toLowerCase(java.util.Locale.ROOT);
                String key =
                        targetSite.key == null
                                ? ""
                                : targetSite.key.toLowerCase(java.util.Locale.ROOT);
                boolean isMyDrive = api.contains("mydrive") || key.contains("mydrive");
                if (isMyDrive) {
                    a.ensureStoragePermissionForNetdisk(() -> a.sourceAction(targetSite, action));
                    return;
                }
                boolean isPanConfig = api.contains("panconfig") || key.contains("panconfig");
                if (isPanConfig) {
                    if ("LoginShow".equals(action)) {
                        final String[] labels =
                                new String[] {
                                    "夸克网盘扫码登录",
                                    "UC网盘 Cookie 扫码登录",
                                    "UC网盘 TV Token 扫码登录",
                                    "百度网盘扫码登录",
                                    "115网盘扫码登录",
                                    "天翼网盘扫码登录",
                                    "天翼网盘账号密码登录",
                                    "移动云盘扫码登录",
                                    "光鸭网盘扫码登录",
                                    "迅雷云盘扫码登录",
                                    "哔哩哔哩扫码登录",
                                    "123网盘账号密码设置",
                                    "打开完整配置中心"
                                };
                        final String[] codes =
                                new String[] {
                                    "quark",
                                    "uccookie",
                                    "uctoken",
                                    "baidu",
                                    "pan115",
                                    "pan189",
                                    "pan189account",
                                    "pan139",
                                    "guangya",
                                    "thunder",
                                    "bili",
                                    "pan123manual",
                                    "__open_config__"
                                };
                        showAccountActionPicker(
                                "网盘扫码与账号登录",
                                "选择需要扫码或配置凭据的网盘服务",
                                labels,
                                idx -> {
                                    if (idx < 0 || idx >= codes.length) return;
                                    String code = codes[idx];
                                    if ("__open_config__".equals(code)) {
                                        openConfigSiteHome(targetSite);
                                    } else {
                                        a.sourceAction(targetSite, code);
                                    }
                                });
                        return;
                    }
                    if ("pushCkShow".equals(action)) {
                        a.sourceAction(targetSite, "web");
                        return;
                    }
                    if ("panSortShow".equals(action) || "panSourceSortShow".equals(action)) {
                        a.sourceAction(targetSite, "panorder");
                        return;
                    }
                }
                boolean isWexConfig =
                        api.contains("wexconfig")
                                || api.contains("wexokconfig")
                                || key.contains("wexconfig")
                                || key.contains("wexokconfig");
                if (isWexConfig) {
                    if ("panSortShow".equals(action) || "panSourceSortShow".equals(action)) {
                        a.sourceAction(targetSite, "panpaixu");
                        return;
                    }
                    final String[] labels =
                            new String[] {
                                "夸克网盘扫码 / Cookie 设置",
                                "UC网盘扫码 / Cookie 设置①",
                                "UC网盘 TV 扫码设置②",
                                "阿里云盘扫码 / Token 设置",
                                "百度网盘扫码登录",
                                "115网盘扫码 / Cookie 设置",
                                "天翼云盘账号登录",
                                "移动云盘 Cookie 设置",
                                "123云盘账号登录",
                                "迅雷云盘账号登录",
                                "哔哩哔哩扫码 / Cookie 设置",
                                "网盘启用开关设置",
                                "打开完整配置中心"
                            };
                    final String[] codes =
                            new String[] {
                                "quarkcookie",
                                "ucpancookie",
                                "uctvpancookie",
                                "aliyuntoken",
                                "baidupanlogin",
                                "115pancookie",
                                "tianyilogin",
                                "ydyuncookie",
                                "pan123login",
                                "panxunleiuser",
                                "bilicookie",
                                "pankaiguan",
                                "__open_config__"
                            };
                    showAccountActionPicker(
                            "网盘扫码与账号登录",
                            "选择需要扫码或配置凭据的网盘服务",
                            labels,
                            idx -> {
                                if (idx < 0 || idx >= codes.length) return;
                                String code = codes[idx];
                                if ("__open_config__".equals(code)) {
                                    openConfigSiteHome(targetSite);
                                } else {
                                    a.sourceAction(targetSite, code);
                                }
                            });
                    return;
                }
                openDynamicConfigSiteAction(targetSite, action);
                return;
            }
        }
        a.notice("当前配置没有提供网盘账号入口，请先导入支持网盘的配置源。");
    }

    void appearance() {
        if (a.isTvDevice()) {
            openTvCategoryById(TvSettingsRegistry.CAT_APPEARANCE_REMOTE, null, false);
            return;
        }
        page("外观与壁纸", "界面按屏幕分辨率自动适配，支持首页封面自适应柔光、自定义柔光渐变与扫码上传壁纸。");
        appearanceRows();
    }

    void appearanceRows() {
        link(
                "首页壁纸与柔光主题",
                HomeAmbient.activeBackgroundSummary(a),
                "settings-wallpaper",
                () -> open(this::wallpaper));
        if (a.isTvDevice()) {
            addTvBackgroundStudioInline(true);
        }
        link(
                "界面大小",
                TvLayoutPolicy.percent(a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100))
                        + "% · 按钮、文字与图标一起调整",
                "setting-ui_scale_percent",
                () -> {
                    String[] scaleLabels = new String[] {"标准 · 自动适配", "放大 · 110%", "更大 · 120%"};
                    int[] scaleValues = new int[] {100, 110, 120};
                    int curScale =
                            a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100) == 120
                                    ? 2
                                    : a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100) == 110 ? 1 : 0;
                    if (!a.isTvDevice()) {
                        MobileShell.showDrawerPicker(
                                a,
                                "界面大小",
                                "标准会自动适配屏幕分辨率；选择后界面重新载入",
                                scaleLabels,
                                curScale,
                                n -> {
                                    a.prefs
                                            .edit()
                                            .putInt(Prefs.UI_SCALE_PERCENT, scaleValues[n])
                                            .apply();
                                    a.recreate();
                                });
                        return;
                    }
                    new AppDialog.Builder(a)
                            .setTitle("界面大小")
                            .setMessage("标准会自动适配屏幕分辨率。观看距离较远时可放大；选择后界面重新载入。")
                            .setSingleChoiceItems(
                                    scaleLabels,
                                    curScale,
                                    (d, n) -> {
                                        a.prefs
                                                .edit()
                                                .putInt(Prefs.UI_SCALE_PERCENT, scaleValues[n])
                                                .apply();
                                        a.recreate();
                                    })
                            .setNegativeButton("返回", null)
                            .show();
                });
        if (a.isTvDevice()) {
            int currentDockStyle = a.useLeftDock() ? 1 : 0;
            String[] dockLabels = new String[] {"顶部沉浸式导航栏（推荐）", "左侧简洁导航栏"};
            link(
                    "首页导航栏位置",
                    dockLabels[currentDockStyle],
                    "setting-" + Prefs.TV_DOCK_POSITION,
                    () ->
                            new AppDialog.Builder(a)
                                    .setTitle("首页导航栏位置")
                                    .setMessage("顶部导航栏常显左上角品牌标识，向下滚动时自动缩小为渐变沉浸样式；也可切换为左侧可展开导航栏。")
                                    .setSingleChoiceItems(
                                            dockLabels,
                                            currentDockStyle,
                                            (d, which) -> {
                                                android.content.SharedPreferences.Editor ed =
                                                        a.prefs.edit();
                                                if (which == 0) {
                                                    ed.putInt(Prefs.TV_NAVIGATION_MODE, 0)
                                                            .putInt(Prefs.TV_DOCK_POSITION, 1);
                                                } else {
                                                    ed.putInt(Prefs.TV_NAVIGATION_MODE, 1);
                                                }
                                                ed.apply();
                                                a.refresh();
                                            })
                                    .setNegativeButton("返回", null)
                                    .show());
            link(
                    "自定义导航栏顺序与名称",
                    TvNavConfig.summaryLabel(a),
                    "setting-tv-nav-custom",
                    () -> TvNavCustomizeDialog.show(a, a::refresh));
        }
        ints(
                "导航栏字体与按钮大小",
                Prefs.NAV_SCALE_PERCENT,
                new String[] {"紧凑 · 85%", "标准 · 100%", "偏大 · 115%", "大号 · 130%", "特大 · 140%"},
                new int[] {85, 100, 115, 130, 140},
                100);
        ints(
                "每行海报",
                Prefs.HOME_COLUMNS,
                new String[] {"最多 5 张 · 舒展", "最多 6 张", "最多 7 张", "最多 8 张"},
                new int[] {5, 6, 7, 8},
                5);
        if (!a.isTvDevice()) {
            toggle("首页推荐卡片", Prefs.SHOW_HERO_BANNER, true, null);
            toggle("海报配色柔光", Prefs.HOME_AMBIENT, true, null);
        }
        toggle(
                "减少透明效果",
                Prefs.REDUCED_TRANSPARENCY,
                false,
                () -> com.pilipala.glass.GlassworkSurface.invalidateBackdrop(a.root));
        toggle("开屏动画", Prefs.STARTUP_ANIMATION, true, null);
        toggle(
                "减少动态效果",
                Prefs.REDUCED,
                false,
                () -> a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false));
    }

    private void applyTvBackgroundMode(int mode) {
        int clamped = Prefs.clampBgMode(mode);
        android.content.SharedPreferences.Editor edit =
                a.prefs
                        .edit()
                        .putInt(Prefs.TV_BG_MODE, clamped)
                        .putBoolean(Prefs.WALLPAPER_ENABLED, clamped == Prefs.BG_MODE_WALLPAPER)
                        .putBoolean(
                                Prefs.HOME_AMBIENT,
                                clamped == Prefs.BG_MODE_ADAPTIVE
                                        || clamped == Prefs.BG_MODE_GRADIENT);
        edit.apply();
        a.refresh();
    }

    private Button makeStudioPill(String label, String tag, boolean active, Runnable onClick) {
        final Button b = a.button(label, tag, onClick);
        b.setSingleLine(true);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setTextSize(13.5f);
        b.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
        b.setMinHeight(a.dp(40));
        b.setMinimumHeight(a.dp(40));
        b.setPadding(a.dp(16), a.dp(8), a.dp(16), a.dp(8));
        final int restBg = active ? 0xff0a84ff : 0x70262c38;
        final int restStroke = active ? 0x9980c2ff : 0x26ffffff;
        final android.graphics.drawable.Drawable restingBg =
                TvV17Surface.rounded(restBg, a.dp(20), restStroke, a.dp(1));
        final android.graphics.drawable.Drawable focusedBg =
                TvV17Surface.rounded(0xfff5f5f7, a.dp(20), 0xffffffff, a.dp(1));
        b.setBackground(restingBg);
        b.setTextColor(MainActivity.WHITE);
        b.setOnFocusChangeListener(
                (v, focused) -> {
                    b.animate().cancel();
                    if (focused) {
                        if (b.getBackground() != focusedBg) b.setBackground(focusedBg);
                        b.setTextColor(0xff101013);
                        float scale = a.reduced ? 1f : 1.035f;
                        if (a.reduced) {
                            b.setScaleX(1f);
                            b.setScaleY(1f);
                        } else {
                            b.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        if (b.getBackground() != restingBg) b.setBackground(restingBg);
                        b.setTextColor(MainActivity.WHITE);
                        b.setScaleX(1f);
                        b.setScaleY(1f);
                    }
                });
        return b;
    }

    private void addTvBackgroundStudioInline(boolean compact) {
        final int mode = HomeAmbient.effectiveBgMode(a);
        final int currentPreset = Prefs.clampGlowPreset(a.prefs.getInt(Prefs.TV_GLOW_PRESET, 0));
        final int currentStrength = a.prefs.getInt(Prefs.TV_AMBIENT_PERCENT, 75);

        // Card 1: Background Mode Selector + Strength Controls
        LinearLayout studioCard = a.vertical();
        studioCard.setClipChildren(false);
        studioCard.setClipToPadding(false);
        studioCard.setPadding(a.dp(18), a.dp(16), a.dp(18), a.dp(16));
        studioCard.setBackground(TvV17Surface.rounded(0x991a1f29, a.dp(18), 0x24ffffff, a.dp(1)));

        TextView modeHeader = a.text("背景渲染模式", 15, MainActivity.WHITE);
        modeHeader.setTypeface(null, Typeface.BOLD);
        studioCard.addView(modeHeader);
        TextView modeSub = a.text("选择封面自适应柔光、自定义柔光渐变或手机扫码上传壁纸，切换即时生效", 12, 0xa6ebebf5);
        modeSub.setPadding(0, a.dp(4), 0, a.dp(12));
        studioCard.addView(modeSub);

        LinearLayout modeRow = a.row();
        modeRow.setClipChildren(false);
        modeRow.setClipToPadding(false);
        String[] modeLabels = {"封面自适应柔光", "自定义柔光渐变", "图片壁纸", "纯深色"};
        int[] modeValues = {
            Prefs.BG_MODE_ADAPTIVE,
            Prefs.BG_MODE_GRADIENT,
            Prefs.BG_MODE_WALLPAPER,
            Prefs.BG_MODE_DARK
        };
        for (int i = 0; i < modeLabels.length; i++) {
            final int targetMode = modeValues[i];
            Button pill =
                    makeStudioPill(
                            modeLabels[i],
                            "tv-bg-mode:" + targetMode,
                            mode == targetMode,
                            () -> {
                                if (targetMode == Prefs.BG_MODE_WALLPAPER
                                        && !new File(a.getFilesDir(), "wallpaper.jpg").exists()) {
                                    new WallpaperUploadDialog(a, a::refresh).show();
                                    return;
                                }
                                applyTvBackgroundMode(targetMode);
                            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(40));
            if (i > 0) lp.leftMargin = a.dp(10);
            modeRow.addView(pill, lp);
            if (i == 0) registerTvRightControl(pill);
        }
        studioCard.addView(modeRow, new LinearLayout.LayoutParams(-1, -2));

        // Strength pills when glow is active
        if (mode == Prefs.BG_MODE_ADAPTIVE || mode == Prefs.BG_MODE_GRADIENT) {
            a.gap(studioCard, 14);
            LinearLayout strengthRow = a.row();
            strengthRow.setClipChildren(false);
            strengthRow.setClipToPadding(false);
            TextView sLabel = a.text("柔光浓度", 13.5f, 0xc8ebebf5);
            LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-2, -2);
            slp.rightMargin = a.dp(14);
            strengthRow.addView(sLabel, slp);
            String[] sLabels = {"柔和微光", "标准柔光", "浓郁流光"};
            int[] sVals = {35, 75, 100};
            int activeIdx = currentStrength <= 50 ? 0 : (currentStrength <= 85 ? 1 : 2);
            for (int i = 0; i < sLabels.length; i++) {
                final int val = sVals[i];
                Button sb =
                        makeStudioPill(
                                sLabels[i],
                                "tv-glow-strength:" + val,
                                activeIdx == i,
                                () -> {
                                    a.prefs.edit().putInt(Prefs.TV_AMBIENT_PERCENT, val).apply();
                                    if (a.homeAmbient != null) {
                                        a.homeAmbient.setStrength(Prefs.tvAmbientStrength(val));
                                    }
                                    a.refresh();
                                });
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(36));
                if (i > 0) lp.leftMargin = a.dp(8);
                strengthRow.addView(sb, lp);
                if (i == 0) registerTvRightControl(sb);
            }
            studioCard.addView(strengthRow, new LinearLayout.LayoutParams(-1, -2));
        }

        LinearLayout.LayoutParams studioLp = new LinearLayout.LayoutParams(-1, -2);
        studioLp.bottomMargin = a.dp(20);
        a.body.addView(studioCard, studioLp);

        // Card 2: Apple TV Soft Glow Preset Grid (2x3) + Custom Color Tuner
        if (!compact || mode == Prefs.BG_MODE_GRADIENT) {
            LinearLayout themeCard = a.vertical();
            themeCard.setClipChildren(false);
            themeCard.setClipToPadding(false);
            themeCard.setPadding(a.dp(22), a.dp(20), a.dp(22), a.dp(20));
            themeCard.setBackground(
                    TvV17Surface.rounded(0x991a1f29, a.dp(18), 0x24ffffff, a.dp(1)));

            LinearLayout themeHead = a.row();
            themeHead.setGravity(Gravity.CENTER_VERTICAL);
            TextView themeTitle = a.text("客厅全局渐变柔光主题", 15.5f, MainActivity.WHITE);
            themeTitle.setTypeface(null, Typeface.BOLD);
            themeHead.addView(themeTitle, new LinearLayout.LayoutParams(0, -2, 1f));
            Button customBtn =
                    makeStudioPill(
                            "自定义颜色调节",
                            "tv-glow-custom-tuner",
                            mode == Prefs.BG_MODE_GRADIENT
                                    && currentPreset == HomeAmbient.PRESET_CUSTOM,
                            this::showCustomGlowTunerDialog);
            themeHead.addView(customBtn, new LinearLayout.LayoutParams(-2, a.dp(38)));
            themeCard.addView(themeHead, new LinearLayout.LayoutParams(-1, -2));
            a.gap(themeCard, 16);

            for (int r = 0; r < 2; r++) {
                LinearLayout gridRow = a.row();
                gridRow.setClipChildren(false);
                gridRow.setClipToPadding(false);
                for (int c = 0; c < 3; c++) {
                    final int idx = r * 3 + c;
                    final boolean isSelected =
                            mode == Prefs.BG_MODE_GRADIENT && currentPreset == idx;
                    LinearLayout swatch =
                            buildGlowPresetCard(
                                    idx,
                                    HomeAmbient.PRESET_NAMES[idx],
                                    HomeAmbient.PRESET_SUBTITLES[idx],
                                    HomeAmbient.PRESET_LEFT[idx],
                                    HomeAmbient.PRESET_RIGHT[idx],
                                    isSelected);
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, -2, 1f);
                    if (c < 2) lp.rightMargin = a.dp(14);
                    gridRow.addView(swatch, lp);
                    if (c == 0) registerTvRightControl(swatch);
                }
                LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-1, -2);
                if (r == 0) rowLp.bottomMargin = a.dp(14);
                themeCard.addView(gridRow, rowLp);
            }

            LinearLayout.LayoutParams themeLp = new LinearLayout.LayoutParams(-1, -2);
            themeLp.bottomMargin = a.dp(20);
            a.body.addView(themeCard, themeLp);
        }
    }

    private LinearLayout buildGlowPresetCard(
            final int index,
            String name,
            String subtitle,
            final int leftColor,
            final int rightColor,
            final boolean selected) {
        final LinearLayout card = a.vertical();
        card.setClipChildren(false);
        card.setClipToPadding(false);
        card.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(12));
        card.setTag("tv-glow-preset:" + index);
        card.setId(View.generateViewId());
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        card.setClickable(true);
        a.pressFeedback(card);

        // Two-tone gradient preview bar
        FrameLayout previewBox = new FrameLayout(a);
        android.graphics.drawable.GradientDrawable grad =
                new android.graphics.drawable.GradientDrawable(
                        android.graphics.drawable.GradientDrawable.Orientation.LEFT_RIGHT,
                        new int[] {leftColor, rightColor});
        grad.setCornerRadius(a.dp(10));
        previewBox.setBackground(grad);
        if (selected) {
            TextView badge = a.text("✓ 当前", 10.5f, MainActivity.WHITE);
            badge.setTypeface(null, Typeface.BOLD);
            badge.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
            badge.setBackground(a.bg(0xbb101318, 10));
            FrameLayout.LayoutParams blp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
            blp.topMargin = a.dp(6);
            blp.rightMargin = a.dp(6);
            previewBox.addView(badge, blp);
        }
        card.addView(previewBox, new LinearLayout.LayoutParams(-1, a.dp(50)));
        a.gap(card, 9);

        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        View dot1 = new View(a);
        dot1.setBackground(a.bg(leftColor, 6));
        LinearLayout.LayoutParams d1 = new LinearLayout.LayoutParams(a.dp(9), a.dp(9));
        d1.rightMargin = a.dp(5);
        titleRow.addView(dot1, d1);
        View dot2 = new View(a);
        dot2.setBackground(a.bg(rightColor, 6));
        LinearLayout.LayoutParams d2 = new LinearLayout.LayoutParams(a.dp(9), a.dp(9));
        d2.rightMargin = a.dp(8);
        titleRow.addView(dot2, d2);
        final TextView titleView = a.text(name, 14, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        titleView.setSingleLine(true);
        titleRow.addView(titleView);
        card.addView(titleRow);

        final TextView subView = a.text(subtitle, 11, 0xa8ebebf5);
        subView.setSingleLine(true);
        subView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        subView.setPadding(0, a.dp(3), 0, 0);
        card.addView(subView);

        final int restBg = selected ? 0x36ffffff : 0x5512161f;
        final int restStroke = selected ? 0x9980c2ff : 0x22ffffff;
        final android.graphics.drawable.Drawable restingBg =
                TvV17Surface.rounded(restBg, a.dp(14), restStroke, a.dp(1));
        final android.graphics.drawable.Drawable focusedBg =
                TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(2));
        card.setBackground(restingBg);
        card.setOnFocusChangeListener(
                (v, focused) -> {
                    card.animate().cancel();
                    if (focused) {
                        if (card.getBackground() != focusedBg) card.setBackground(focusedBg);
                        titleView.setTextColor(0xff101013);
                        subView.setTextColor(0xff48484a);
                        float scale = a.reduced ? 1f : 1.03f;
                        if (a.reduced) {
                            card.setScaleX(1f);
                            card.setScaleY(1f);
                        } else {
                            card.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                        if (a.homeAmbient != null) {
                            a.homeAmbient.previewCustomColors(leftColor, rightColor);
                        }
                    } else {
                        if (card.getBackground() != restingBg) card.setBackground(restingBg);
                        titleView.setTextColor(MainActivity.WHITE);
                        subView.setTextColor(0xa8ebebf5);
                        card.setScaleX(1f);
                        card.setScaleY(1f);
                    }
                });
        card.setOnClickListener(
                v -> {
                    a.prefs
                            .edit()
                            .putInt(Prefs.TV_BG_MODE, Prefs.BG_MODE_GRADIENT)
                            .putInt(Prefs.TV_GLOW_PRESET, index)
                            .putBoolean(Prefs.WALLPAPER_ENABLED, false)
                            .putBoolean(Prefs.HOME_AMBIENT, true)
                            .apply();
                    a.refresh();
                });
        return card;
    }

    private void showCustomGlowTunerDialog() {
        int[] active = HomeAmbient.activeGradientColors(a);
        final float[] leftHsv = new float[3];
        final float[] rightHsv = new float[3];
        Color.colorToHSV(active[0], leftHsv);
        Color.colorToHSV(active[1], rightHsv);
        if (leftHsv[1] < 0.15f) leftHsv[1] = 0.55f;
        if (leftHsv[2] < 0.25f) leftHsv[2] = 0.48f;
        if (rightHsv[1] < 0.15f) rightHsv[1] = 0.55f;
        if (rightHsv[2] < 0.25f) rightHsv[2] = 0.48f;

        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(6), a.dp(4), a.dp(6), a.dp(4));

        final View previewBar = new View(a);
        LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(-1, a.dp(64));
        pLp.bottomMargin = a.dp(14);
        panel.addView(previewBar, pLp);

        final TextView leftHueVal = a.text("", 13, 0xd8ebebf5);
        final TextView leftSatVal = a.text("", 13, 0xd8ebebf5);
        final TextView rightHueVal = a.text("", 13, 0xd8ebebf5);
        final TextView rightSatVal = a.text("", 13, 0xd8ebebf5);

        Runnable syncPreview =
                () -> {
                    int lc = Color.HSVToColor(leftHsv);
                    int rc = Color.HSVToColor(rightHsv);
                    android.graphics.drawable.GradientDrawable gd =
                            new android.graphics.drawable.GradientDrawable(
                                    android.graphics.drawable.GradientDrawable.Orientation
                                            .LEFT_RIGHT,
                                    new int[] {lc, rc});
                    gd.setCornerRadius(a.dp(14));
                    gd.setStroke(a.dp(1), 0x44ffffff);
                    previewBar.setBackground(gd);
                    leftHueVal.setText(Math.round(leftHsv[0]) + "°");
                    leftSatVal.setText(Math.round(leftHsv[1] * 100) + "%");
                    rightHueVal.setText(Math.round(rightHsv[0]) + "°");
                    rightSatVal.setText(Math.round(rightHsv[1] * 100) + "%");
                    if (a.homeAmbient != null) {
                        a.homeAmbient.previewCustomColors(lc, rc);
                    }
                };

        addColorAdjustRow(
                panel,
                "左上主光 · 色相",
                leftHueVal,
                () -> {
                    leftHsv[0] = (leftHsv[0] + 345f) % 360f;
                    syncPreview.run();
                },
                () -> {
                    leftHsv[0] = (leftHsv[0] + 15f) % 360f;
                    syncPreview.run();
                });
        addColorAdjustRow(
                panel,
                "左上主光 · 饱和度",
                leftSatVal,
                () -> {
                    leftHsv[1] = Math.max(0.15f, leftHsv[1] - 0.1f);
                    syncPreview.run();
                },
                () -> {
                    leftHsv[1] = Math.min(0.85f, leftHsv[1] + 0.1f);
                    syncPreview.run();
                });
        addColorAdjustRow(
                panel,
                "右下辅光 · 色相",
                rightHueVal,
                () -> {
                    rightHsv[0] = (rightHsv[0] + 345f) % 360f;
                    syncPreview.run();
                },
                () -> {
                    rightHsv[0] = (rightHsv[0] + 15f) % 360f;
                    syncPreview.run();
                });
        addColorAdjustRow(
                panel,
                "右下辅光 · 饱和度",
                rightSatVal,
                () -> {
                    rightHsv[1] = Math.max(0.15f, rightHsv[1] - 0.1f);
                    syncPreview.run();
                },
                () -> {
                    rightHsv[1] = Math.min(0.85f, rightHsv[1] + 0.1f);
                    syncPreview.run();
                });

        syncPreview.run();

        new AppDialog.Builder(a)
                .setTitle("自定义柔光双色")
                .setView(panel)
                .setNegativeButton(
                        "取消",
                        (d, w) -> {
                            if (a.homeAmbient != null) a.homeAmbient.applyFromPrefs(true);
                        })
                .setPositiveButton(
                        "应用此柔光配色",
                        (d, w) -> {
                            int lc = Color.HSVToColor(leftHsv) & 0xFFFFFF;
                            int rc = Color.HSVToColor(rightHsv) & 0xFFFFFF;
                            a.prefs
                                    .edit()
                                    .putInt(Prefs.TV_BG_MODE, Prefs.BG_MODE_GRADIENT)
                                    .putInt(Prefs.TV_GLOW_PRESET, HomeAmbient.PRESET_CUSTOM)
                                    .putInt(Prefs.TV_GLOW_COLOR_LEFT, lc)
                                    .putInt(Prefs.TV_GLOW_COLOR_RIGHT, rc)
                                    .putBoolean(Prefs.WALLPAPER_ENABLED, false)
                                    .putBoolean(Prefs.HOME_AMBIENT, true)
                                    .apply();
                            a.refresh();
                            a.toast("自定义柔光配色已保存");
                        })
                .show();
    }

    private void addColorAdjustRow(
            LinearLayout parent,
            String label,
            TextView valueText,
            Runnable onMinus,
            Runnable onPlus) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, a.dp(4), 0, a.dp(4));
        TextView lbl = a.text(label, 14, MainActivity.WHITE);
        row.addView(lbl, new LinearLayout.LayoutParams(0, -2, 1f));
        Button minus = a.navButton("－", "tuner-minus-" + label, onMinus);
        LinearLayout.LayoutParams ml = new LinearLayout.LayoutParams(a.dp(46), a.dp(36));
        row.addView(minus, ml);
        valueText.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams vl = new LinearLayout.LayoutParams(a.dp(62), -2);
        row.addView(valueText, vl);
        Button plus = a.navButton("＋", "tuner-plus-" + label, onPlus);
        LinearLayout.LayoutParams pl = new LinearLayout.LayoutParams(a.dp(46), a.dp(36));
        row.addView(plus, pl);
        parent.addView(row, new LinearLayout.LayoutParams(-1, -2));
    }

    void wallpaper() {
        page("首页壁纸", "支持手机扫码上传本地高清图片、Apple TV 柔光渐变主题、自定义双色调节与剧集封面色调自适应。");
        if (a.isTvDevice()) {
            addTvBackgroundStudioInline(false);
            link(
                    "手机扫码上传替换壁纸",
                    "同一 Wi-Fi 下手机扫码，直接从相册选图传到电视",
                    "wallpaper-qr-upload",
                    () -> new WallpaperUploadDialog(a, a::refresh).show());
        }
        link("选择本地图片", "JPG、PNG、WebP", "wallpaper-file", () -> pick(44, "image/*", false));
        link("从图片地址导入", "输入你自己的 HTTP / HTTPS 图片地址", "wallpaper-url", this::wallpaperUrl);
        ints(
                "壁纸压暗",
                Prefs.WALLPAPER_DIM,
                new String[] {"轻 · 40%", "适中 · 60%", "深 · 80%"},
                new int[] {40, 60, 80},
                60);
        link(
                "切换为封面自适应柔光",
                "跟随首页选中的剧集封面主色调自动渲染柔光背景",
                "wallpaper-reset",
                () -> applyTvBackgroundMode(Prefs.BG_MODE_ADAPTIVE));
        if (new File(a.getFilesDir(), "wallpaper.jpg").exists())
            link(
                    "启用已保存的图片壁纸",
                    "使用上次上传或导入的图片",
                    "wallpaper-enable",
                    () -> applyTvBackgroundMode(Prefs.BG_MODE_WALLPAPER));
    }

    void playback() {
        if (a.isTvDevice()) {
            openTvCategoryById(TvSettingsRegistry.CAT_PLAYBACK, null, false);
            return;
        }
        page("播放与字幕", "作为之后播放的默认设置；播放界面中仍可随时调整。");
        playbackRows();
    }

    void playbackRows() {
        if (a.isTvDevice()) {
            ints(
                    "播放界面样式",
                    Prefs.TV_PLAYER_STYLE,
                    new String[] {"现代悬浮卡片（默认）", "经典双层工具栏"},
                    new int[] {0, 1},
                    0);
            boolean modernPlayerStyle = a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
            link(
                    "播放工具条按钮顺序",
                    TvPlayerToolbarOrder.settingsSummary(
                            a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, ""),
                            modernPlayerStyle),
                    "setting-" + Prefs.TV_PLAYER_TOOLBAR_ORDER,
                    this::showTvToolbarOrderDialog);
        }
        ints(
                "画面输出",
                Prefs.VIDEO_OUTPUT,
                new String[] {"保真输出 · HDR 与流畅度优先", "兼容输出 · 支持应用内调色"},
                new int[] {0, 1},
                0);
        ints(
                "播放器",
                Prefs.PLAYER_ENGINE,
                new String[] {
                    "Exo (Media3 · 默认)",
                    "MPV 高画质 (libmpv · HDR / Anime4K / ASS)",
                    "IJK 兼容模式 (Media3 + FFmpeg)",
                    "系统播放器"
                },
                new int[] {0, 3, 2, 1},
                0);
        ints(
                "解码方式",
                Prefs.DECODER_MODE,
                new String[] {"自动", "硬件解码", "软件解码优先"},
                new int[] {0, 1, 2},
                0);
        toggle("4K HDR 隧道模式", Prefs.TUNNELED_PLAYBACK, false, null);
        toggle("MPV HDR 自动峰值色调映射 (libplacebo)", Prefs.HDR_TONE_MAPPING, true, null);
        toggle("MPV Anime4K 实时超分滤镜", Prefs.ANIME4K_ENABLED, false, null);
        toggle("HLS 伪装分片实时修正代理", Prefs.HLS_PROXY_ENABLED, true, null);
        toggle("HLS 点播广告分段启发式过滤", Prefs.HLS_AD_STRIP, false, null);
        ints(
                "直链本地分块缓存",
                Prefs.MEDIA_CACHE_MB,
                new String[] {"关闭", "128 MB", "256 MB（默认）", "512 MB", "1024 MB"},
                new int[] {0, 128, 256, 512, 1024},
                256);
        ints(
                "人声与响度增益",
                Prefs.LOUDNESS_BOOST,
                new String[] {"关闭", "+4 dB", "+8 dB", "+12 dB"},
                new int[] {0, 4, 8, 12},
                0);
        toggle("内置 CPython 3.11 爬虫引擎", Prefs.NATIVE_PYTHON_ENABLED, true, a::closeEngines);
        toggle("异步 JS 源 WebView 兜底引擎", Prefs.WEBVIEW_JS_FALLBACK, true, a::closeEngines);
        toggle("优先使用兼容音频解码", Prefs.SOFTWARE_AUDIO, false, null);
        toggle("优先选择 AAC 音轨", Prefs.PREFER_AAC, false, null);
        link("解码组件", "查看本机已加载的音频与视频扩展", "settings-decoders", () -> open(this::decoders));
        ints(
                "画面比例",
                Prefs.ASPECT,
                new String[] {"适应", "铺满", "16:9", "4:3", "裁切填充"},
                new int[] {0, 1, 2, 3, 4},
                0);
        ints(
                "网络缓冲",
                Prefs.BUFFER_SECONDS,
                new String[] {"15 秒 · 节省内存", "30 秒 · 均衡", "50 秒 · 网络波动"},
                new int[] {15, 30, 50},
                30);
        link(
                "默认速度",
                a.prefs.getFloat(Prefs.PLAY_SPEED, 1) + "×",
                "setting-play_speed",
                () -> {
                    String[] speedLabels =
                            new String[] {"0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"};
                    float[] speedVals = new float[] {.5f, .75f, 1f, 1.25f, 1.5f, 2f};
                    float curSpeed = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
                    int curIdx = 2;
                    for (int i = 0; i < speedVals.length; i++) {
                        if (Math.abs(curSpeed - speedVals[i]) < 0.05f) {
                            curIdx = i;
                            break;
                        }
                    }
                    if (!a.isTvDevice()) {
                        MobileShell.showDrawerPicker(
                                a,
                                "默认播放速度",
                                "作为之后进入播放时的初始倍速",
                                speedLabels,
                                curIdx,
                                i -> {
                                    a.prefs.edit().putFloat(Prefs.PLAY_SPEED, speedVals[i]).apply();
                                    a.refresh();
                                });
                        return;
                    }
                    if (a.prefs != null
                            && Math.abs(a.prefs.getFloat(Prefs.PLAY_SPEED, 1f) - 1f) > 0.001f) {
                        a.prefs.edit().putFloat(Prefs.PLAY_SPEED, 1f).apply();
                    }
                    new AppDialog.Builder(a)
                            .setTitle("默认倍速说明")
                            .setMessage(
                                    "电视端每次从主页或新剧集进入均默认 1.0× 原速播放；播放中调节的倍速仅在同一部剧连续选集播放时保持，返回主页或切换其他剧集后自动重置为 1.0×。")
                            .setPositiveButton("知道了", null)
                            .show();
                });
        toggle("自动播放下一集", Prefs.AUTO_NEXT, true, null);
        if (a.isTvDevice()) {
            toggle("播放中右上角显示进度与时间", Prefs.TV_PLAYER_TOP_RIGHT_HUD, true, null);
        } else {
            toggle("播放页常显时间", Prefs.PLAYER_ALWAYS_SHOW_CLOCK, false, null);
        }
        link(
                "起播画质规格提示",
                PlayerHudPrefs.isStartSpecHudEnabled(a) ? "开启" : "关闭",
                "setting-" + PlayerHudPrefs.KEY_START_SPEC_HUD,
                () -> {
                    PlayerHudPrefs.setStartSpecHudEnabled(
                            a, !PlayerHudPrefs.isStartSpecHudEnabled(a));
                    a.refresh();
                });
        link(
                "播放中底部细进度条",
                PlayerHudPrefs.isSlimProgressEnabled(a) ? "开启" : "关闭",
                "setting-" + PlayerHudPrefs.KEY_SLIM_PROGRESS,
                () -> {
                    PlayerHudPrefs.setSlimProgressEnabled(
                            a, !PlayerHudPrefs.isSlimProgressEnabled(a));
                    a.refresh();
                });
        link(
                "跳过片头片尾 3 秒可取消倒计时",
                PlayerHudPrefs.isSkipCountdownEnabled(a) ? "开启（3 秒倒计时）" : "关闭（立即跳过）",
                "setting-" + PlayerHudPrefs.KEY_SKIP_COUNTDOWN,
                () -> {
                    PlayerHudPrefs.setSkipCountdownEnabled(
                            a, !PlayerHudPrefs.isSkipCountdownEnabled(a));
                    a.refresh();
                });
        if (!a.isTvDevice()) {
            link(
                    "双击屏幕左右两侧",
                    PlayerHudPrefs.doubleTapSidesLabel(PlayerHudPrefs.getDoubleTapSides(a)),
                    "setting-" + PlayerHudPrefs.KEY_DOUBLE_TAP_SIDES,
                    () -> {
                        final String[] labels = {
                            "左右快退/快进 5 秒", "左右快退/快进 10 秒", "左右快退/快进 15 秒", "全屏双击播放 / 暂停"
                        };
                        final String[] vals = {
                            PlayerHudPrefs.SIDES_SEEK_5S,
                            PlayerHudPrefs.SIDES_SEEK_10S,
                            PlayerHudPrefs.SIDES_SEEK_15S,
                            PlayerHudPrefs.SIDES_PLAY_PAUSE
                        };
                        String cur = PlayerHudPrefs.getDoubleTapSides(a);
                        int sel = 1;
                        for (int i = 0; i < vals.length; i++) {
                            if (vals[i].equals(cur)) sel = i;
                        }
                        MobileShell.showDrawerPicker(
                                a,
                                "双击屏幕左右两侧",
                                "支持连击累加快进快退，或切换回全屏双击播/暂",
                                labels,
                                sel,
                                idx -> {
                                    PlayerHudPrefs.setDoubleTapSides(a, vals[idx]);
                                    a.refresh();
                                });
                    });
            link(
                    "双击屏幕中央",
                    PlayerHudPrefs.doubleTapCenterLabel(PlayerHudPrefs.getDoubleTapCenter(a)),
                    "setting-" + PlayerHudPrefs.KEY_DOUBLE_TAP_CENTER,
                    () -> {
                        final String[] labels = {"播放 / 暂停", "切换横竖屏全屏", "关闭双击"};
                        final String[] vals = {
                            PlayerHudPrefs.CENTER_PLAY_PAUSE,
                            PlayerHudPrefs.CENTER_FULLSCREEN,
                            PlayerHudPrefs.CENTER_NONE
                        };
                        String cur = PlayerHudPrefs.getDoubleTapCenter(a);
                        int sel = 0;
                        for (int i = 0; i < vals.length; i++) {
                            if (vals[i].equals(cur)) sel = i;
                        }
                        MobileShell.showDrawerPicker(
                                a,
                                "双击屏幕中央",
                                "自定义播放画面中区双击响应",
                                labels,
                                sel,
                                idx -> {
                                    PlayerHudPrefs.setDoubleTapCenter(a, vals[idx]);
                                    a.refresh();
                                });
                    });
            link(
                    "长按倍速松手恢复",
                    PlayerHudPrefs.longPressRestoreLabel(PlayerHudPrefs.getLongPressRestoreMode(a)),
                    "setting-" + PlayerHudPrefs.KEY_LONG_PRESS_RESTORE_MODE,
                    () -> {
                        boolean isOneX =
                                PlayerHudPrefs.RESTORE_ONE_X.equals(
                                        PlayerHudPrefs.getLongPressRestoreMode(a));
                        PlayerHudPrefs.setLongPressRestoreMode(
                                a,
                                isOneX
                                        ? PlayerHudPrefs.RESTORE_PREVIOUS
                                        : PlayerHudPrefs.RESTORE_ONE_X);
                        a.refresh();
                    });
        }
        ints("循环", Prefs.REPEAT_MODE, new String[] {"关闭", "单集循环", "列表循环"}, new int[] {0, 1, 2}, 0);
        int skipRecordCount = PlaybackControls.countVideoSkipRecords(a);
        link(
                "片头片尾独立记录",
                skipRecordCount <= 0
                        ? "每部影片在播放页独立保存片头片尾，不全局同步"
                        : "已独立记录 " + skipRecordCount + " 部影片 · 点击查看或清空",
                "setting-" + Prefs.VIDEO_SKIP_RECORDS,
                () -> PlaybackControls.showVideoSkipRecordsDialog(a, a::refresh));
        int subSize = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        int subBottom = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        int subStyle = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
        link(
                a.isTvDevice() ? "字幕大小与位置（全屏预览调校）" : "字幕全屏调试（双指缩放 · 按住拖拽）",
                "字号 "
                        + subSize
                        + " · 底部高度 "
                        + subBottom
                        + "dp · "
                        + SubtitleOverlayView.STYLE_LABELS[subStyle],
                "setting-" + Prefs.SUBTITLE_SIZE,
                () -> PlaybackControls.showSubtitleAdjuster(a, null, a::refresh));
        ints(
                "字幕样式",
                Prefs.SUBTITLE_STYLE,
                SubtitleOverlayView.STYLE_LABELS,
                new int[] {0, 1, 2, 3, 4, 5, 6, 7},
                0);
        ints(
                "自动音轨偏好",
                Prefs.AUDIO_TRACK_PREFERENCE,
                new String[] {"智能默认（自动避开解说音轨）", "优先中文 / 国语", "优先原声 / 片源默认"},
                new int[] {0, 1, 2},
                0);
        toggle("自动加载来源弹幕", Prefs.DANMAKU_DEFAULT, true, null);
        DanmuSettingsPanel.DanmuConfig dmCfg = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        String dmSummary = DanmuSettingsPanel.formatConfigSummary(dmCfg);
        link(
                "弹幕设置",
                dmSummary,
                "setting-danmu-panel",
                () -> {
                    android.app.AlertDialog dlg =
                            DanmuSettingsPanel.showDialog(a, a.isTvDevice(), null);
                    dlg.setOnDismissListener(
                            d -> {
                                if (!a.isFinishing()
                                        && (android.os.Build.VERSION.SDK_INT < 17
                                                || !a.isDestroyed())) {
                                    a.refresh();
                                }
                            });
                });
        ints(
                "画面色彩",
                Prefs.PICTURE_EFFECT,
                new String[] {"原始", "明亮", "影院", "柔和"},
                new int[] {0, 1, 2, 3},
                0);
        ints(
                "音效",
                Prefs.AUDIO_EFFECT,
                new String[] {"原声", "影院", "人声清晰", "柔和低音"},
                new int[] {0, 1, 2, 3},
                0);
        a.paragraph(
                "兼容音频解码仅切换音频，不强制视频软解码；AAC 优先仅在媒体包含可用 AAC 音轨时生效，不会转换文件。以上两项用于 Media3。音效取决于电视提供的音频接口。系统播放器支持的字幕和网络格式少于 Media3；播放器中的字幕按钮可导入外部字幕。");
    }

    void showTvToolbarOrderDialog() {
        showTvToolbarOrderDialogInternal(false, null, null);
    }

    void showTvToolbarOrderDialogForPlayer(Runnable onApplied, Runnable onBackToMore) {
        showTvToolbarOrderDialogInternal(true, onApplied, onBackToMore);
    }

    private void showTvToolbarOrderDialogInternal(
            final boolean fromPlayer, final Runnable onApplied, final Runnable onBackToMore) {
        final boolean modernStyle = a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
        final boolean reducedTrans = a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        final String initialSaved = a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, "");
        final java.util.List<String> order =
                TvPlayerToolbarOrder.resolveOrder(initialSaved, modernStyle);
        if (order.isEmpty()) return;

        final View returnFocus = a.getCurrentFocus();
        final String[] grabbedKey = {null};
        final int[] focusedSlot = {0};
        final boolean[] changed = {false};

        final android.app.Dialog dialog = new android.app.Dialog(a);
        dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);

        LinearLayout panel = a.vertical();
        panel.setTag("tv-toolbar-order-dialog");
        panel.setClipChildren(false);
        panel.setClipToPadding(false);
        panel.setPadding(a.dp(24), a.dp(20), a.dp(24), a.dp(18));
        panel.setBackground(
                TvV17Surface.rounded(
                        reducedTrans ? 0xf6191c23 : 0xee161b25, a.dp(24), 0x30ffffff, a.dp(1)));

        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView titleView = a.text("播放工具条按钮排列", 20, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        titleRow.addView(titleView, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView stylePill = a.text(modernStyle ? "现代悬浮卡片" : "经典双层工具栏", 11.5f, 0xd8d8e6ff);
        stylePill.setTypeface(null, Typeface.BOLD);
        stylePill.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
        stylePill.setBackground(TvV17Surface.rounded(0x28ffffff, a.dp(999), 0x38ffffff, a.dp(1)));
        titleRow.addView(stylePill, new LinearLayout.LayoutParams(-2, -2));
        panel.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));

        TextView subtitle = a.text("◀ ▶ 直接左移/右移 · 确认键抓起调序 · 下方可增减按钮或恢复默认", 12.5f, 0xb2ebebf5);
        subtitle.setPadding(0, a.dp(5), 0, a.dp(12));
        panel.addView(subtitle, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout previewBox = a.vertical();
        previewBox.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(10));
        previewBox.setBackground(TvV17Surface.rounded(0x7a0d1118, a.dp(14), 0x22ffffff, a.dp(1)));
        TextView previewHeading = a.text("实时预览（从左到右）", 11f, 0x99ebebf5);
        previewHeading.setPadding(a.dp(2), 0, 0, a.dp(7));
        previewBox.addView(previewHeading);

        final HorizontalScrollView previewScroller = new HorizontalScrollView(a);
        previewScroller.setHorizontalScrollBarEnabled(false);
        previewScroller.setFocusable(false);
        previewScroller.setFillViewport(true);
        final LinearLayout previewStrip = a.row();
        previewStrip.setTag("tv-toolbar-order-preview");
        previewStrip.setGravity(Gravity.CENTER_VERTICAL);
        previewScroller.addView(previewStrip, new FrameLayout.LayoutParams(-2, -2));
        previewBox.addView(previewScroller, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout.LayoutParams prevBoxLp = new LinearLayout.LayoutParams(-1, -2);
        prevBoxLp.bottomMargin = a.dp(12);
        panel.addView(previewBox, prevBoxLp);

        final LinearLayout listContainer = a.vertical();
        listContainer.setClipChildren(false);
        listContainer.setClipToPadding(false);
        listContainer.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));

        final java.util.List<LinearLayout> rowViews = new java.util.ArrayList<>();
        final java.util.List<TextView> indexBadges = new java.util.ArrayList<>();
        final java.util.List<TextView> nameViews = new java.util.ArrayList<>();
        final java.util.List<TextView> hintViews = new java.util.ArrayList<>();
        final java.util.List<TextView> previewChips = new java.util.ArrayList<>();

        final Runnable persistOrder =
                () -> {
                    String existing = a.prefs.getString(Prefs.TV_PLAYER_TOOLBAR_ORDER, "");
                    String merged =
                            TvPlayerToolbarOrder.mergeEditedOrder(existing, order, modernStyle);
                    a.prefs.edit().putString(Prefs.TV_PLAYER_TOOLBAR_ORDER, merged).apply();
                    changed[0] = true;
                };

        final Button[] footerBtnRefs = new Button[3];

        final Runnable syncAll =
                () -> {
                    int n = order.size();
                    int focusedRowIdx = -1;
                    for (int i = 0; i < n && i < rowViews.size(); i++) {
                        String key = order.get(i);
                        boolean grabbed = key.equals(grabbedKey[0]);
                        LinearLayout rowView = rowViews.get(i);
                        TextView badgeView = indexBadges.get(i);
                        TextView nameView = nameViews.get(i);
                        TextView hintView = hintViews.get(i);
                        TextView chipView = previewChips.get(i);
                        boolean focused = rowView.hasFocus();
                        if (focused) focusedRowIdx = i;

                        rowView.setTag("toolbar-order-row:" + key);
                        badgeView.setText(String.valueOf(i + 1));
                        nameView.setText(TvPlayerToolbarOrder.settingsLabel(key));

                        String hintText;
                        if (grabbed) {
                            hintText = "● 移动中 · ▲▼◀▶ 调序 · 确认放下";
                        } else if (focused) {
                            if (i == 0) {
                                hintText = "确认抓起 · 右移 ▶";
                            } else if (i == n - 1) {
                                hintText = "◀ 左移 · 确认抓起";
                            } else {
                                hintText = "◀ 左移 · 确认抓起 · 右移 ▶";
                            }
                        } else {
                            hintText =
                                    (i > 0 ? "◀ " : "   ")
                                            + "第 "
                                            + (i + 1)
                                            + " 位"
                                            + (i < n - 1 ? " ▶" : "   ");
                        }
                        hintView.setText(hintText);

                        int nextRowState = grabbed ? 2 : (focused ? 1 : 0);
                        if (nextRowState == 2) {
                            rowView.setBackground(
                                    TvV17Surface.rounded(
                                            0xff0a84ff, a.dp(13), 0x9980c2ff, a.dp(1)));
                            badgeView.setBackground(
                                    TvV17Surface.rounded(0x38ffffff, a.dp(999), 0, 0));
                            badgeView.setTextColor(MainActivity.WHITE);
                            nameView.setTextColor(MainActivity.WHITE);
                            hintView.setTextColor(0xeef5f7fb);
                        } else if (nextRowState == 1) {
                            rowView.setBackground(
                                    TvV17Surface.rounded(
                                            0xfff5f5f7, a.dp(13), 0xffffffff, a.dp(1)));
                            badgeView.setBackground(
                                    TvV17Surface.rounded(0x1f101013, a.dp(999), 0, 0));
                            badgeView.setTextColor(0xff101013);
                            nameView.setTextColor(0xff101013);
                            hintView.setTextColor(0xff48484a);
                        } else {
                            rowView.setBackground(
                                    TvV17Surface.rounded(
                                            reducedTrans ? 0xee202632 : 0x8a202632,
                                            a.dp(13),
                                            0x20ffffff,
                                            a.dp(1)));
                            badgeView.setBackground(
                                    TvV17Surface.rounded(0x24ffffff, a.dp(999), 0, 0));
                            badgeView.setTextColor(0xdcebebf5);
                            nameView.setTextColor(MainActivity.WHITE);
                            hintView.setTextColor(0x99ebebf5);
                        }

                        chipView.setText((i + 1) + " " + TvPlayerToolbarOrder.shortChipLabel(key));
                        if (nextRowState == 2) {
                            chipView.setBackground(
                                    TvV17Surface.rounded(
                                            0xff0a84ff, a.dp(999), 0x9980c2ff, a.dp(1)));
                            chipView.setTextColor(MainActivity.WHITE);
                            chipView.setTypeface(null, Typeface.BOLD);
                        } else if (nextRowState == 1) {
                            chipView.setBackground(
                                    TvV17Surface.rounded(
                                            0xfff5f5f7, a.dp(999), 0xffffffff, a.dp(1)));
                            chipView.setTextColor(0xff101013);
                            chipView.setTypeface(null, Typeface.BOLD);
                        } else {
                            chipView.setBackground(
                                    TvV17Surface.rounded(
                                            0x26ffffff, a.dp(999), 0x1effffff, a.dp(1)));
                            chipView.setTextColor(0xdcebebf5);
                            chipView.setTypeface(null, Typeface.NORMAL);
                        }
                    }
                    if (!previewChips.isEmpty()) {
                        int activeIdx =
                                focusedRowIdx >= 0
                                        ? focusedRowIdx
                                        : Math.max(
                                                0,
                                                Math.min(previewChips.size() - 1, focusedSlot[0]));
                        final TextView activeChip = previewChips.get(activeIdx);
                        previewScroller.post(
                                () -> {
                                    int chipCenter =
                                            activeChip.getLeft() + activeChip.getWidth() / 2;
                                    int targetScroll =
                                            Math.max(
                                                    0, chipCenter - previewScroller.getWidth() / 2);
                                    previewScroller.smoothScrollTo(targetScroll, 0);
                                });
                    }
                };

        final Runnable rebuildSlots =
                () -> {
                    previewStrip.removeAllViews();
                    listContainer.removeAllViews();
                    rowViews.clear();
                    indexBadges.clear();
                    nameViews.clear();
                    hintViews.clear();
                    previewChips.clear();
                    int n = order.size();
                    for (int i = 0; i < n; i++) {
                        TextView chip = a.text("", 11.5f, 0xdcebebf5);
                        chip.setSingleLine(true);
                        chip.setIncludeFontPadding(false);
                        chip.setGravity(Gravity.CENTER);
                        chip.setPadding(a.dp(9), a.dp(5), a.dp(9), a.dp(5));
                        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, -2);
                        if (i > 0) clp.leftMargin = a.dp(6);
                        previewStrip.addView(chip, clp);
                        previewChips.add(chip);
                    }
                    for (int i = 0; i < n; i++) {
                        final int slot = i;
                        LinearLayout row = a.row();
                        row.setGravity(Gravity.CENTER_VERTICAL);
                        row.setPadding(a.dp(14), a.dp(9), a.dp(14), a.dp(9));
                        row.setId(UiCompat.generateViewId());
                        row.setFocusable(true);
                        row.setFocusableInTouchMode(true);
                        row.setClickable(true);
                        UiCompat.setDefaultFocusHighlightEnabled(row, false);

                        TextView badge = a.text(String.valueOf(i + 1), 12.5f, 0xdcebebf5);
                        badge.setTypeface(null, Typeface.BOLD);
                        badge.setGravity(Gravity.CENTER);
                        badge.setIncludeFontPadding(false);
                        LinearLayout.LayoutParams bLp =
                                new LinearLayout.LayoutParams(a.dp(26), a.dp(26));
                        bLp.rightMargin = a.dp(12);
                        row.addView(badge, bLp);

                        TextView name = a.text("", 15f, MainActivity.WHITE);
                        name.setTypeface(null, Typeface.BOLD);
                        name.setSingleLine(true);
                        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
                        row.addView(name, new LinearLayout.LayoutParams(0, -2, 1f));

                        TextView hint = a.text("", 12f, 0x99ebebf5);
                        hint.setSingleLine(true);
                        hint.setPadding(a.dp(10), 0, 0, 0);
                        row.addView(hint, new LinearLayout.LayoutParams(-2, -2));

                        rowViews.add(row);
                        indexBadges.add(badge);
                        nameViews.add(name);
                        hintViews.add(hint);

                        row.setOnFocusChangeListener(
                                (v, focused) -> {
                                    if (focused) focusedSlot[0] = slot;
                                    syncAll.run();
                                });
                        row.setOnClickListener(
                                v -> {
                                    if (slot >= order.size()) return;
                                    String key = order.get(slot);
                                    grabbedKey[0] = key.equals(grabbedKey[0]) ? null : key;
                                    syncAll.run();
                                });
                        row.setOnKeyListener(
                                (v, keyCode, event) -> {
                                    if (slot >= order.size()) return false;
                                    boolean down =
                                            event.getAction() == android.view.KeyEvent.ACTION_DOWN;
                                    boolean isGrabbed = order.get(slot).equals(grabbedKey[0]);
                                    if (keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT
                                            || (isGrabbed
                                                    && keyCode
                                                            == android.view.KeyEvent
                                                                    .KEYCODE_DPAD_UP)) {
                                        if (down
                                                && TvPlayerToolbarOrder.moveItem(order, slot, -1)) {
                                            persistOrder.run();
                                            focusedSlot[0] = slot - 1;
                                            rowViews.get(slot - 1).requestFocus();
                                            syncAll.run();
                                        }
                                        return true;
                                    }
                                    if (keyCode == android.view.KeyEvent.KEYCODE_DPAD_RIGHT
                                            || (isGrabbed
                                                    && keyCode
                                                            == android.view.KeyEvent
                                                                    .KEYCODE_DPAD_DOWN)) {
                                        if (down && TvPlayerToolbarOrder.moveItem(order, slot, 1)) {
                                            persistOrder.run();
                                            focusedSlot[0] = slot + 1;
                                            rowViews.get(slot + 1).requestFocus();
                                            syncAll.run();
                                        }
                                        return true;
                                    }
                                    return false;
                                });

                        LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(-1, a.dp(46));
                        rLp.bottomMargin = a.dp(6);
                        listContainer.addView(row, rLp);
                    }
                    Button doneRef = footerBtnRefs[2];
                    for (int i = 0; i < rowViews.size(); i++) {
                        rowViews.get(i)
                                .setNextFocusUpId(
                                        i == 0
                                                ? rowViews.get(0).getId()
                                                : rowViews.get(i - 1).getId());
                        rowViews.get(i)
                                .setNextFocusDownId(
                                        i == rowViews.size() - 1
                                                ? (doneRef != null
                                                        ? doneRef.getId()
                                                        : rowViews.get(i).getId())
                                                : rowViews.get(i + 1).getId());
                    }
                    if (!rowViews.isEmpty()) {
                        int lastId = rowViews.get(rowViews.size() - 1).getId();
                        for (Button fb : footerBtnRefs) {
                            if (fb != null) fb.setNextFocusUpId(lastId);
                        }
                    }
                    syncAll.run();
                };

        LinearLayout footer = a.row();
        footer.setGravity(Gravity.CENTER_VERTICAL);
        footer.setClipChildren(false);
        footer.setClipToPadding(false);

        final Button toggleActionsBtn =
                a.navButton(
                        "增减按钮",
                        "toolbar-order-toggle-actions",
                        () -> {
                            grabbedKey[0] = null;
                            final java.util.List<String> pool = new java.util.ArrayList<>();
                            for (String k : TvPlayerToolbarOrder.availableKeys(modernStyle)) {
                                if (!TvPlayerToolbarOrder.isPinnedKey(k)) pool.add(k);
                            }
                            String[] labels = new String[pool.size()];
                            for (int i = 0; i < pool.size(); i++) {
                                String k = pool.get(i);
                                boolean on = order.contains(k);
                                labels[i] =
                                        (on ? "✓ 已显示 · " : "＋ 添加 · ")
                                                + TvPlayerToolbarOrder.settingsLabel(k);
                            }
                            new AppDialog.Builder(a)
                                    .setTitle("添加或移除主栏按钮")
                                    .setItems(
                                            labels,
                                            (d, which) -> {
                                                if (which < 0 || which >= pool.size()) return;
                                                String chosen = pool.get(which);
                                                if (order.contains(chosen)) {
                                                    if (order.size() <= 2) {
                                                        a.toast("主栏至少需保留 2 个按钮");
                                                        return;
                                                    }
                                                    order.remove(chosen);
                                                } else {
                                                    if (order.size()
                                                            >= TvPlayerToolbarOrder
                                                                    .MAX_CUSTOM_TOOLBAR_ITEMS) {
                                                        a.toast("主栏最多显示 12 个按钮，请先移除不常用项");
                                                        return;
                                                    }
                                                    int moreIdx =
                                                            order.indexOf(
                                                                    TvPlayerToolbarOrder.KEY_MORE);
                                                    if (moreIdx >= 0) order.add(moreIdx, chosen);
                                                    else order.add(chosen);
                                                }
                                                persistOrder.run();
                                                focusedSlot[0] =
                                                        Math.min(
                                                                focusedSlot[0],
                                                                Math.max(0, order.size() - 1));
                                                rebuildSlots.run();
                                                if (!rowViews.isEmpty()) {
                                                    rowViews.get(focusedSlot[0]).requestFocus();
                                                }
                                            })
                                    .setNegativeButton("返回", null)
                                    .show();
                        });
        final Button resetBtn =
                a.navButton(
                        "恢复默认顺序",
                        "toolbar-order-reset",
                        () -> {
                            grabbedKey[0] = null;
                            order.clear();
                            order.addAll(TvPlayerToolbarOrder.defaultOrder(modernStyle));
                            a.prefs.edit().remove(Prefs.TV_PLAYER_TOOLBAR_ORDER).apply();
                            changed[0] = true;
                            focusedSlot[0] = 0;
                            rebuildSlots.run();
                            if (!rowViews.isEmpty()) rowViews.get(0).requestFocus();
                            a.toast("已恢复新版默认按钮顺序");
                        });
        final Button doneBtn = a.navButton("完成", "toolbar-order-done", dialog::dismiss);

        footerBtnRefs[0] = toggleActionsBtn;
        footerBtnRefs[1] = resetBtn;
        footerBtnRefs[2] = doneBtn;

        for (final Button fb : footerBtnRefs) {
            fb.setId(UiCompat.generateViewId());
            UiCompat.setDefaultFocusHighlightEnabled(fb, false);
            fb.setOnFocusChangeListener(
                    (v, f) -> {
                        if (f && grabbedKey[0] != null) {
                            grabbedKey[0] = null;
                            syncAll.run();
                        }
                        FocusMotion.style(
                                a,
                                fb,
                                f,
                                0xff282832,
                                MainActivity.WHITE,
                                19,
                                0xffe6e6ee,
                                MainActivity.DARK,
                                false,
                                1.02f);
                    });
        }
        toggleActionsBtn.setNextFocusDownId(toggleActionsBtn.getId());
        toggleActionsBtn.setNextFocusLeftId(doneBtn.getId());
        toggleActionsBtn.setNextFocusRightId(resetBtn.getId());
        resetBtn.setNextFocusDownId(resetBtn.getId());
        resetBtn.setNextFocusLeftId(toggleActionsBtn.getId());
        resetBtn.setNextFocusRightId(doneBtn.getId());
        doneBtn.setNextFocusDownId(doneBtn.getId());
        doneBtn.setNextFocusLeftId(resetBtn.getId());
        doneBtn.setNextFocusRightId(toggleActionsBtn.getId());

        LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
        tLp.rightMargin = a.dp(8);
        footer.addView(toggleActionsBtn, tLp);
        LinearLayout.LayoutParams resetLp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
        resetLp.rightMargin = a.dp(8);
        footer.addView(resetBtn, resetLp);
        footer.addView(doneBtn, new LinearLayout.LayoutParams(0, a.dp(42), 1f));

        TvScrollView scroller = new TvScrollView(a);
        scroller.setFocusFrameEnabled(false);
        scroller.setVerticalScrollBarEnabled(false);
        scroller.addView(listContainer, new ScrollView.LayoutParams(-1, -2));

        FrameLayout viewport =
                new FrameLayout(a) {
                    @Override
                    protected void dispatchDraw(Canvas c) {
                        int save = c.save();
                        c.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(c);
                        c.restoreToCount(save);
                    }
                };
        viewport.setTag("scroll-viewport-clip");
        viewport.setClipChildren(true);
        viewport.setClipToPadding(true);
        viewport.addView(scroller, new FrameLayout.LayoutParams(-1, -1));

        int screenW = a.root != null && a.root.getWidth() > 0 ? a.root.getWidth() : a.windowWidth();
        int screenH =
                a.root != null && a.root.getHeight() > 0 ? a.root.getHeight() : a.windowHeight();
        int width = Math.min(a.dp(720), Math.max(a.dp(240), screenW - a.dp(48)));
        int naturalListH = Math.max(order.size(), 6) * a.dp(52) + a.dp(8);
        int defaultViewportH = a.dp(260);
        panel.addView(viewport, new LinearLayout.LayoutParams(-1, defaultViewportH));
        a.gap(panel, 12);
        panel.addView(footer, new LinearLayout.LayoutParams(-1, -2));

        rebuildSlots.run();
        panel.measure(
                View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int chromeH = Math.max(0, panel.getMeasuredHeight() - defaultViewportH);
        int outerMarginY = a.dp(44);
        int maxDialogH = Math.max(a.dp(160), screenH - outerMarginY);
        int maxListH = AppDialog.computeMaxContentHeight(screenH, chromeH, outerMarginY, a.dp(110));
        boolean needOuterScroll = maxListH < a.dp(96);
        int resolvedListH =
                needOuterScroll
                        ? Math.min(naturalListH, a.dp(200))
                        : Math.max(a.dp(72), Math.min(naturalListH, maxListH));
        viewport.setLayoutParams(new LinearLayout.LayoutParams(-1, resolvedListH));

        dialog.setOnKeyListener(
                (d, keyCode, event) -> {
                    if (grabbedKey[0] != null
                            && (keyCode == android.view.KeyEvent.KEYCODE_BACK
                                    || keyCode == android.view.KeyEvent.KEYCODE_ESCAPE)) {
                        if (event.getAction() == android.view.KeyEvent.ACTION_UP) {
                            grabbedKey[0] = null;
                            syncAll.run();
                        }
                        return true;
                    }
                    return false;
                });

        dialog.setOnDismissListener(
                d -> {
                    if (fromPlayer) {
                        if (changed[0] && onApplied != null) {
                            onApplied.run();
                        } else if (onBackToMore != null) {
                            onBackToMore.run();
                        }
                        return;
                    }
                    if (changed[0]) {
                        if (a.current != null) {
                            a.current.focus = "setting-" + Prefs.TV_PLAYER_TOOLBAR_ORDER;
                        }
                        a.refresh();
                    } else if (returnFocus != null && UiCompat.isAttached(returnFocus)) {
                        returnFocus.requestFocus();
                    }
                });

        if (needOuterScroll) {
            TvScrollView outer = new TvScrollView(a);
            outer.setVerticalScrollBarEnabled(false);
            outer.addView(panel, new android.widget.ScrollView.LayoutParams(width, -2));
            dialog.setContentView(
                    outer, new android.view.ViewGroup.LayoutParams(width, maxDialogH));
        } else {
            dialog.setContentView(panel);
        }
        dialog.show();
        android.view.Window w = dialog.getWindow();
        if (w != null) {
            w.setBackgroundDrawableResource(android.R.color.transparent);
            w.setLayout(width, needOuterScroll ? maxDialogH : -2);
            w.setGravity(Gravity.CENTER);
            w.addFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            android.view.WindowManager.LayoutParams attrs = w.getAttributes();
            attrs.dimAmount = 0.56f;
            w.setAttributes(attrs);
            w.getDecorView().setSystemUiVisibility(5894);
        }
        if (!rowViews.isEmpty()) {
            rowViews.get(0).requestFocus();
            rowViews.get(0)
                    .post(
                            () -> {
                                if (!rowViews.isEmpty()) rowViews.get(0).requestFocus();
                            });
        }
    }

    void data() {
        page("搜索与数据", "搜索默认识别首拼和全拼，并检索配置中全部可搜索来源。");
        contentRows();
        backupRows();
    }

    void content() {
        if (a.isTvDevice()) {
            openTvCategoryById(TvSettingsRegistry.CAT_SOURCES, null, false);
            return;
        }
        page("内容与连接", "搜索默认识别首拼和全拼，并检索配置中全部可搜索来源。");
        contentRows();
    }

    void backup() {
        if (a.isTvDevice()) {
            openTvCategoryById(TvSettingsRegistry.CAT_DATA_SYNC, null, false);
            return;
        }
        page("数据与备份", "管理同步、备份和本机记录。");
        backupRows();
    }

    void contentRows() {
        ints(
                "同时搜索的来源数",
                Prefs.SEARCH_THREADS,
                new String[] {"2 个 · 轻量", "4 个 · 均衡", "6 个 · 快速"},
                new int[] {2, 4, 6},
                6);
        ints(
                "单个来源等待时间",
                Prefs.SEARCH_TIMEOUT,
                new String[] {"10 秒", "20 秒", "30 秒"},
                new int[] {10, 20, 30},
                20);
        link(
                "导入或更新配置源",
                a.isTvDevice()
                        ? "手机扫码、遥控输入或本地包（支持多行地址自动分组）"
                        : "剪贴板粘贴、网址输入或本地包 (.json/.js/.py/.zip)",
                "settings-import",
                a::importDialog);
        if (a.isTvDevice()) {
            link("已添加源与线路管理", "切换订阅、多源合并自动分组或管理线路", "settings-source-manager", a::chooseOrImport);
        }
        toggle("导入的订阅源每天自动更新", Prefs.SUBSCRIPTION_AUTO_UPDATE, true, null);
        link(
                "立即刷新全部订阅源",
                SourceController.subscriptionAutoUpdateSummary(a),
                "settings-refresh-subs",
                () -> SourceController.runDailyAutoUpdateIfNeeded(a, true));
        link(
                "导入或管理电视直播源",
                "支持叠加多份 M3U / TXT / JSON 源与组播单播配置",
                "settings-live-import",
                () -> SourceController.showLiveImportDialog(a));
        String udpxyAddr = a.prefs.getString(Prefs.LIVE_UDPXY_URL, "");
        link(
                "组播转单播网关 (udpxy)",
                udpxyAddr.isEmpty()
                        ? "配置路由器 udpxy / rtp2httpd 地址播放原画 1080i50 / 4K 组播源"
                        : "当前：" + udpxyAddr,
                "settings-live-udpxy",
                () -> SourceController.showUdpxyDialog(a));
        String epgAddr = a.prefs.getString(Prefs.LIVE_EPG_URL, "");
        link(
                "自定义 XMLTV 节目单 (EPG)",
                epgAddr.isEmpty()
                        ? "支持 .xml / .xml.gz 节目单与回看时移（默认读取列表 x-tvg-url）"
                        : "当前：" + epgAddr,
                "settings-live-epg",
                () -> SourceController.showEpgDialog(a));
        toggle("直播优先最高画质与 IPv6", Prefs.LIVE_HIGH_QUALITY, true, null);
        toggle("跨源同名频道智能聚合", Prefs.LIVE_MERGE_SOURCES, true, null);
        if (a.config != null && a.config.depots.length() > 1) {
            link(
                    "切换影视仓线路",
                    "当前订阅包含 " + a.config.depots.length() + " 个子仓库，点击切换",
                    "settings-depots",
                    () -> SourcePicker.showWarehouses(a));
        }
        toggle("启用来源扩展", Prefs.EXPERIMENTAL_CSP, true, a::closeEngines);
        toggle("仅允许 HTTPS 插件", Prefs.ONLY_ALLOW_HTTPS_PLUGINS, false, a::closeEngines);
        link(
                "网盘与账号",
                "网盘扫码登录、凭据与网盘顺序（由配置提供）",
                "settings-accounts",
                () -> AccountPanel.show(a, null));
        link(
                "挂载 AList 网盘 / 媒体库",
                AlistAccounts.statusSummary(a),
                "settings-alist-mount",
                () -> AlistAccounts.openManager(a, a::refresh));
        if (!a.privateMode) {
            link(
                    "局域网蜘蛛网关",
                    SpiderGatewayDialog.statusSummary(a),
                    "settings-spider-gateway",
                    () -> SpiderGatewayDialog.show(a));
        }
        link(
                "存储权限（网盘扫码 Cookie 保存）",
                a.storagePermissionStatusText(),
                "settings-storage-permission",
                () -> {
                    if (android.os.Build.VERSION.SDK_INT >= 30) {
                        a.openTvStoragePermissionSettings();
                    } else {
                        a.requestRuntimeStoragePermission(a::refresh);
                    }
                });
    }

    void backupRows() {
        if (!a.privateMode) {
            link(
                    "多端网络同步",
                    CloudSyncDialog.statusSummary(a),
                    "settings-cloud-sync",
                    () -> CloudSyncDialog.show(a, a::refresh));
        }
        link(
                "备份配置与偏好",
                "导出配置与偏好，请妥善保管；不含插件单独保存的登录状态",
                "settings-backup",
                () -> pick(45, "application/json", true));
        link(
                "还原配置与偏好",
                "从 Marco Movie 备份文件还原",
                "settings-restore",
                () -> pick(46, "application/json", false));
        File localSafe = lastSafeBackupFile(a);
        if (!a.privateMode && localSafe != null && localSafe.isFile() && localSafe.length() > 0) {
            link(
                    "从本机安全备份副本还原",
                    "读取上次有效导出的保护副本（" + formatBackupSize(localSafe.length()) + "），防止覆盖写坏后丢数据",
                    "settings-restore-safe-copy",
                    () -> restoreFromLocalSafeCopy(a));
        }
        link("观看历史", "查看、继续播放或删除本机观看记录", "settings-history", () -> open(a::historyPage));
        link(
                "重置观看历史（保留损坏备份）",
                "清空本机观看记录并解除损坏锁定，已生成的本地备份继续保留",
                "settings-reset-history",
                () ->
                        confirm(
                                "重置观看历史（保留损坏备份）？",
                                () -> {
                                    final boolean wasCorrupted =
                                            WatchHistory.isCorrupted()
                                                    || a.prefs.getBoolean(
                                                            WatchHistory.CORRUPTED_PREF, false);
                                    final java.util.List<WatchHistory.Entry> prev =
                                            wasCorrupted
                                                    ? java.util.Collections.emptyList()
                                                    : a.watchHistory();
                                    a.clearWatchHistory(
                                            () -> {
                                                if (!wasCorrupted) {
                                                    CloudSyncDialog.onHistoryCleared(a, prev);
                                                }
                                                a.toast("已重置观看历史");
                                                a.refresh();
                                            });
                                }));
        link(
                "清除搜索记录",
                "清除最近搜索，保留网盘登录",
                "settings-clear-history",
                () ->
                        confirm(
                                "清除搜索记录？",
                                () -> {
                                    a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                    a.refresh();
                                }));
        link(
                "重新加载首页图片与片单",
                "清除内存与磁盘中的首页缓存",
                "settings-clear-images",
                () -> {
                    a.images.evictAll();
                    a.homeData.clear();
                    try {
                        File snapDir = new File(a.getCacheDir(), "home_snap_v1");
                        File[] files = snapDir.listFiles();
                        if (files != null) for (File f : files) f.delete();
                    } catch (Throwable ignored) {
                    }
                    a.toast("已清除首页缓存");
                });
        link("运行日志", "查看本机最近异常与诊断记录", "settings-logs", this::diagnostics);
        if (!a.privateMode) {
            int pendingCrashes = CrashReportStore.loadUnsubmittedReports(a.getFilesDir()).size();
            String crashSub =
                    pendingCrashes > 0
                            ? ("待提交 " + pendingCrashes + " 条崩溃日志 · 自动提交 GitHub Issue / 扫码导出")
                            : "闪退自动留痕，支持一键提交 GitHub Issue 或扫码导出脱敏日志";
            link(
                    "崩溃日志与问题反馈",
                    crashSub,
                    "settings-crash-feedback",
                    () -> CrashReportDialog.show(a, true));
        }
        link(
                TvOfficialNotice.SETTINGS_ROW_TITLE,
                TvOfficialNotice.SETTINGS_ROW_DETAIL,
                TvOfficialNotice.SETTINGS_ROW_TAG,
                () -> TvOfficialNotice.showContactAndGroupDialog(a));
        link(
                "重新查看新手引导",
                "重温功能导览并重新启用首播手势提示",
                "settings-replay-onboarding",
                () -> {
                    OnboardingScreen.resetForReplay(a);
                    a.showOnboarding(true);
                });
        link(
                "恢复播放与外观默认设置",
                "保留来源配置和网盘登录",
                "settings-reset",
                () ->
                        confirm(
                                "恢复默认设置？",
                                () -> {
                                    android.content.SharedPreferences.Editor edit = a.prefs.edit();
                                    for (String key : KEYS) edit.remove(key);
                                    edit.remove(Prefs.TV_PLAYER_TOOLBAR_ORDER);
                                    edit.apply();
                                    TvNavConfig.reset(a);
                                    a.reduced = false;
                                    a.recreate();
                                }));
        a.paragraph(
                "Marco Movie "
                        + UpdateManager.installedVersion(a)
                        + " · 作者 Pilipala · 各社媒同名「"
                        + TvOfficialNotice.AUTHOR_SOCIAL_NAME
                        + "」（小红书/B站/抖音/公众号/视频号）· 官网 "
                        + TvOfficialNotice.OFFICIAL_SITE_DISPLAY
                        + " · 交流群 "
                        + TvOfficialNotice.OFFICIAL_GROUP_URL
                        + " · github.com/Pilipala9919/MarcoMovie。本产品仅为工具，不含任何影视资源；内容与配置请自行合法获取。播放能力取决于服务授权和设备支持。");
    }

    void confirm(String title, Runnable action) {
        new AppDialog.Builder(a)
                .setTitle(title)
                .setNegativeButton("取消", null)
                .setPositiveButton("确定", (d, i) -> action.run())
                .show();
    }

    void diagnostics() {
        String text = AppLog.dump();
        new AppDialog.Builder(a)
                .setTitle("运行日志")
                .setMessage(text.isEmpty() ? "当前运行正常，暂无异常或告警记录。" : text)
                .setNeutralButton(
                        "清空记录",
                        (d, i) -> {
                            AppLog.clear();
                            a.toast("已清空运行日志");
                        })
                .setPositiveButton("关闭", null)
                .show();
    }

    void toggle(String title, String key, boolean defaultValue, Runnable after) {
        toggle(title, "", key, defaultValue, after);
    }

    void toggle(
            String title, String subtitleNote, String key, boolean defaultValue, Runnable after) {
        boolean tv = a.isTvDevice();
        boolean initial = a.prefs.getBoolean(key, defaultValue);
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(
                a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14), a.dp(tv ? 22 : 18), a.dp(tv ? 18 : 14));
        MobileShell.SettingIconView icon =
                new MobileShell.SettingIconView(
                        a, MobileShell.SettingIconView.kindForSetting(key, title));
        LinearLayout.LayoutParams iconLp =
                new LinearLayout.LayoutParams(a.dp(tv ? 36 : 38), a.dp(tv ? 36 : 38));
        iconLp.rightMargin = a.dp(tv ? 16 : 14);
        row.addView(icon, iconLp);
        LinearLayout copy = a.vertical();
        final TextView titleView = a.text(title, tv ? 16 : 17, MainActivity.WHITE);
        titleView.setTypeface(null, Typeface.BOLD);
        copy.addView(titleView);
        final TextView noteView;
        if (subtitleNote != null && !subtitleNote.trim().isEmpty()) {
            noteView = a.text(subtitleNote.trim(), 12f, 0xa8ebebf5);
            noteView.setPadding(0, a.dp(3), 0, 0);
            copy.addView(noteView);
        } else {
            noteView = null;
        }
        final TextView caption = a.text(initial ? "开启" : "关闭", 12.5f, 0xa8ebebf5);
        caption.setPadding(0, a.dp(3), 0, 0);
        if (!tv) copy.addView(caption);
        row.addView(copy, new LinearLayout.LayoutParams(0, -2, 1));

        if (tv) {
            caption.setPadding(a.dp(10), 0, a.dp(8), 0);
            row.addView(caption);
        }

        final MobileShell.IosSwitchView toggleSwitch = new MobileShell.IosSwitchView(a, initial);
        LinearLayout.LayoutParams switchLp = new LinearLayout.LayoutParams(a.dp(50), a.dp(30));
        switchLp.leftMargin = a.dp(8);
        row.addView(toggleSwitch, switchLp);

        row.setTag("setting-" + key);
        row.setId(View.generateViewId());
        row.setFocusable(tv);
        row.setFocusableInTouchMode(tv);
        row.setClickable(true);
        final int surface =
                tv && a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)
                        ? 0xee1c212b
                        : 0xbf1a1f29;
        final android.graphics.drawable.Drawable restingBg =
                tv
                        ? TvV17Surface.rounded(surface, a.dp(14), 0x22ffffff, a.dp(1))
                        : a.bg(0xff222226, 14);
        final android.graphics.drawable.Drawable focusedBg =
                tv ? TvV17Surface.rounded(0xfff5f5f7, a.dp(14), 0xffffffff, a.dp(1)) : null;
        row.setBackground(restingBg);
        row.setOnFocusChangeListener(
                (v, f) -> {
                    if (!tv) {
                        FocusMotion.style(
                                a,
                                row,
                                f,
                                0xff222226,
                                0xff37373e,
                                14,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.008f);
                        return;
                    }
                    row.animate().cancel();
                    if (f) {
                        if (row.getBackground() != focusedBg) row.setBackground(focusedBg);
                        titleView.setTextColor(0xff101013);
                        if (noteView != null) noteView.setTextColor(0xff48484a);
                        caption.setTextColor(0xff48484a);
                        float scale = a.reduced ? 1f : 1.014f;
                        if (a.reduced) {
                            row.setScaleX(1f);
                            row.setScaleY(1f);
                        } else {
                            row.animate()
                                    .scaleX(scale)
                                    .scaleY(scale)
                                    .setDuration(70)
                                    .setInterpolator(tvDecel())
                                    .start();
                        }
                    } else {
                        if (row.getBackground() != restingBg) row.setBackground(restingBg);
                        titleView.setTextColor(MainActivity.WHITE);
                        if (noteView != null) noteView.setTextColor(0xa8ebebf5);
                        caption.setTextColor(0xa8ebebf5);
                        row.setScaleX(1f);
                        row.setScaleY(1f);
                    }
                });
        if (tv) {
            a.pressFeedback(row);
            registerTvRightControl(row);
        } else {
            MobileShell.bindCardTouchFeedback(a, row, a.bg(0xff222226, 14), a.bg(0xff303038, 14));
        }
        row.setOnClickListener(
                v -> {
                    final boolean current = a.prefs.getBoolean(key, defaultValue);
                    final boolean nextVal = !current;
                    Runnable applyChange =
                            () -> {
                                a.prefs.edit().putBoolean(key, nextVal).apply();
                                toggleSwitch.setChecked(nextVal, !a.reduced);
                                caption.setText(nextVal ? "开启" : "关闭");
                                if (after != null) after.run();
                                if (key.equals(Prefs.WALLPAPER_ENABLED)) {
                                    a.refresh();
                                }
                            };
                    if (key.equals(Prefs.EXPERIMENTAL_CSP) && nextVal && !current) {
                        confirm("运行配置源提供的扩展？请仅使用你信任的配置。", applyChange);
                    } else {
                        applyChange.run();
                    }
                });
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, -2);
        size.bottomMargin = a.dp(14);
        a.body.addView(row, size);
    }

    void ints(String title, String key, String[] labels, int[] values, int fallback) {
        int current = a.prefs.getInt(key, fallback), selected = 0;
        for (int i = 0; i < values.length; i++) if (current == values[i]) selected = i;
        final int choice = selected;
        link(
                title,
                labels[selected],
                "setting-" + key,
                () -> {
                    if (!a.isTvDevice()) {
                        MobileShell.showDrawerPicker(
                                a,
                                title,
                                "在下方抽屉中选择预设选项",
                                labels,
                                choice,
                                index -> {
                                    a.prefs.edit().putInt(key, values[index]).apply();
                                    a.refresh();
                                });
                        return;
                    }
                    new AppDialog.Builder(a)
                            .setTitle(title)
                            .setSingleChoiceItems(
                                    labels,
                                    choice,
                                    (dialog, index) -> {
                                        a.prefs.edit().putInt(key, values[index]).apply();
                                        dialog.dismiss();
                                        a.refresh();
                                    })
                            .setNegativeButton("取消", null)
                            .show();
                });
    }

    void pick(int request, String mime, boolean create) {
        if (a.privateMode && (request == 45 || request == 46)) {
            a.toast("请先退出隐私空间，再导出或恢复公开备份");
            return;
        }
        if ((request == 45 || request == 46) && isBackupRestoreInFlight()) {
            a.toast("正在后台还原备份，请稍候…");
            return;
        }
        try {
            Intent intent =
                    new Intent(
                            create ? Intent.ACTION_CREATE_DOCUMENT : Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType(mime);
            if (create) intent.putExtra(Intent.EXTRA_TITLE, defaultBackupFileName());
            a.startActivityForResult(intent, request);
        } catch (Exception error) {
            a.notice("电视没有文件选择器。壁纸也可以通过图片地址导入；文件导入导出需要安装文件管理器。");
        }
    }

    void wallpaperUrl() {
        AddressInput input = new AddressInput(a, "https://…/wallpaper.jpg", "");
        new AppDialog.Builder(a)
                .setTitle("壁纸图片地址")
                .setView(input)
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "导入",
                        (d, i) -> {
                            String address = input.value();
                            if (!Cms.isHttp(address)) {
                                a.notice("请输入 HTTP 或 HTTPS 图片地址。");
                                return;
                            }
                            a.worker.execute(
                                    () -> {
                                        try {
                                            java.net.HttpURLConnection connection =
                                                    (java.net.HttpURLConnection)
                                                            new java.net.URL(
                                                                            Cms.normalizeHttp(
                                                                                    address))
                                                                    .openConnection();
                                            connection.setConnectTimeout(15000);
                                            connection.setReadTimeout(15000);
                                            try (InputStream stream = connection.getInputStream()) {
                                                saveWallpaper(a, stream);
                                            } finally {
                                                connection.disconnect();
                                            }
                                            a.ui.post(
                                                    () -> {
                                                        a.refresh();
                                                        a.toast("壁纸已更新");
                                                    });
                                        } catch (Exception error) {
                                            a.ui.post(() -> a.notice("图片无法读取，请检查图片地址和格式。"));
                                        }
                                    });
                        })
                .show();
    }

    static void saveWallpaper(MainActivity a, InputStream stream) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int length;
        while ((length = stream.read(chunk)) != -1) {
            if (bytes.size() + length > 16 * 1024 * 1024) throw new IOException("Image too large");
            bytes.write(chunk, 0, length);
        }
        byte[] data = bytes.toByteArray();
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (options.outWidth <= 0 || options.outHeight <= 0) throw new IOException("Invalid image");
        options.inSampleSize = 1;
        while (options.outWidth / options.inSampleSize > 1920
                || options.outHeight / options.inSampleSize > 1080) options.inSampleSize *= 2;
        options.inJustDecodeBounds = false;
        Bitmap image = BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (image == null) throw new IOException("Invalid image");
        File temporary = new File(a.getFilesDir(), "wallpaper.tmp");
        try {
            try (OutputStream output = new FileOutputStream(temporary)) {
                if (!image.compress(Bitmap.CompressFormat.JPEG, 90, output))
                    throw new IOException("Encoding failed");
            }
            if (!temporary.renameTo(new File(a.getFilesDir(), "wallpaper.jpg")))
                throw new IOException("Unable to save wallpaper");
        } finally {
            image.recycle();
            temporary.delete();
        }
        a.prefs
                .edit()
                .putInt(Prefs.TV_BG_MODE, Prefs.BG_MODE_WALLPAPER)
                .putBoolean(Prefs.WALLPAPER_ENABLED, true)
                .apply();
    }

    static final String[] KEYS = Prefs.KEYS;

    /**
     * Unified archive capacity limit shared by backup export and backup restore so any valid
     * multi-subscription backup that exports cleanly is guaranteed readable on restore.
     */
    static final int MAX_BACKUP_BYTES = 64 * 1024 * 1024;

    private static final String BACKUP_RECOVERY_DIR = "backup-recovery";
    private static final String LAST_SAFE_BACKUP_NAME = "last-safe-backup.json";

    static String defaultBackupFileName() {
        String stamp =
                new java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.ROOT)
                        .format(new java.util.Date());
        return "MarcoMovie-backup-" + stamp + ".json";
    }

    private static String formatBackupSize(long bytes) {
        if (bytes >= 1024L * 1024L) {
            return String.format(java.util.Locale.ROOT, "%.1f MB", bytes / (1024.0 * 1024.0));
        }
        if (bytes >= 1024L) {
            return String.format(java.util.Locale.ROOT, "%.1f KB", bytes / 1024.0);
        }
        return bytes + " B";
    }

    static File lastSafeBackupFile(MainActivity a) {
        if (a == null || a.configStore == null || a.configStore.directory == null) return null;
        return new File(
                new File(a.configStore.directory, BACKUP_RECOVERY_DIR), LAST_SAFE_BACKUP_NAME);
    }

    /**
     * Streaming RFC-8259 UTF-8 JSON writer that enforces {@link #MAX_BACKUP_BYTES} continuously
     * while emitting chunks directly to disk, keeping peak heap bounded on 192 MiB TV devices even
     * when exporting 56–64 MiB multi-subscription archives.
     */
    private static final class BoundedJsonStreamWriter implements Closeable {
        private final OutputStream rawOut;
        private final byte[] buf = new byte[65536];
        private int pos = 0;
        private long totalBytes = 0L;
        private final int maxBytes;

        BoundedJsonStreamWriter(OutputStream out, int maxBytes) {
            this.rawOut = out;
            this.maxBytes = maxBytes;
        }

        long bytesWritten() {
            return totalBytes;
        }

        private void flushBuffer() throws IOException {
            if (pos > 0) {
                rawOut.write(buf, 0, pos);
                pos = 0;
            }
        }

        private void writeByte(int b) throws IOException {
            if (totalBytes + 1L > maxBytes) {
                throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
            }
            if (pos >= buf.length) flushBuffer();
            buf[pos++] = (byte) b;
            totalBytes++;
        }

        void writeAscii(String ascii) throws IOException {
            int len = ascii.length();
            if (totalBytes + len > maxBytes) {
                throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
            }
            for (int i = 0; i < len; i++) {
                if (pos >= buf.length) flushBuffer();
                buf[pos++] = (byte) ascii.charAt(i);
            }
            totalBytes += len;
        }

        void writeUtf8Raw(String text) throws IOException {
            if (text == null || text.isEmpty()) return;
            final int len = text.length();
            final byte[] localBuf = this.buf;
            final int cap = localBuf.length;
            int i = 0;
            while (i < len) {
                char c = text.charAt(i);
                if (c < 0x80) {
                    int start = i;
                    while (i < len && text.charAt(i) < 0x80) i++;
                    int run = i - start;
                    if (totalBytes + run > maxBytes) {
                        throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
                    }
                    int p = this.pos;
                    int cur = start;
                    while (cur < i) {
                        int avail = cap - p;
                        if (avail == 0) {
                            this.pos = p;
                            flushBuffer();
                            p = 0;
                            avail = cap;
                        }
                        int take = Math.min(avail, i - cur);
                        int end = cur + take;
                        while (cur < end) {
                            localBuf[p++] = (byte) text.charAt(cur++);
                        }
                    }
                    this.pos = p;
                    totalBytes += run;
                } else if (c < 0x800) {
                    writeByte(0xC0 | (c >> 6));
                    writeByte(0x80 | (c & 0x3F));
                    i++;
                } else if (Character.isHighSurrogate(c)
                        && i + 1 < len
                        && Character.isLowSurrogate(text.charAt(i + 1))) {
                    int cp = Character.toCodePoint(c, text.charAt(i + 1));
                    writeByte(0xF0 | (cp >> 18));
                    writeByte(0x80 | ((cp >> 12) & 0x3F));
                    writeByte(0x80 | ((cp >> 6) & 0x3F));
                    writeByte(0x80 | (cp & 0x3F));
                    i += 2;
                } else {
                    writeByte(0xE0 | (c >> 12));
                    writeByte(0x80 | ((c >> 6) & 0x3F));
                    writeByte(0x80 | (c & 0x3F));
                    i++;
                }
            }
        }

        void writeJsonString(String value) throws IOException {
            if (value == null) {
                writeAscii("null");
                return;
            }
            writeByte('"');
            final int len = value.length();
            final byte[] localBuf = this.buf;
            final int cap = localBuf.length;
            int i = 0;
            while (i < len) {
                char c = value.charAt(i);
                if (c >= 0x20 && c < 0x80 && c != '"' && c != '\\') {
                    int start = i;
                    i++;
                    while (i < len) {
                        char nc = value.charAt(i);
                        if (nc < 0x20 || nc >= 0x80 || nc == '"' || nc == '\\') break;
                        i++;
                    }
                    int run = i - start;
                    if (totalBytes + run > maxBytes) {
                        throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
                    }
                    int p = this.pos;
                    int cur = start;
                    while (cur < i) {
                        int avail = cap - p;
                        if (avail == 0) {
                            this.pos = p;
                            flushBuffer();
                            p = 0;
                            avail = cap;
                        }
                        int take = Math.min(avail, i - cur);
                        int end = cur + take;
                        while (cur < end) {
                            localBuf[p++] = (byte) value.charAt(cur++);
                        }
                    }
                    this.pos = p;
                    totalBytes += run;
                    continue;
                }
                i++;
                switch (c) {
                    case '"':
                        writeAscii("\\\"");
                        break;
                    case '\\':
                        writeAscii("\\\\");
                        break;
                    case '\b':
                        writeAscii("\\b");
                        break;
                    case '\f':
                        writeAscii("\\f");
                        break;
                    case '\n':
                        writeAscii("\\n");
                        break;
                    case '\r':
                        writeAscii("\\r");
                        break;
                    case '\t':
                        writeAscii("\\t");
                        break;
                    default:
                        if (c < 0x20) {
                            writeAscii(String.format(java.util.Locale.ROOT, "\\u%04x", (int) c));
                        } else if (c < 0x800) {
                            writeByte(0xC0 | (c >> 6));
                            writeByte(0x80 | (c & 0x3F));
                        } else if (Character.isHighSurrogate(c)
                                && i < len
                                && Character.isLowSurrogate(value.charAt(i))) {
                            int cp = Character.toCodePoint(c, value.charAt(i++));
                            writeByte(0xF0 | (cp >> 18));
                            writeByte(0x80 | ((cp >> 12) & 0x3F));
                            writeByte(0x80 | ((cp >> 6) & 0x3F));
                            writeByte(0x80 | (cp & 0x3F));
                        } else {
                            writeByte(0xE0 | (c >> 12));
                            writeByte(0x80 | ((c >> 6) & 0x3F));
                            writeByte(0x80 | (c & 0x3F));
                        }
                        break;
                }
            }
            writeByte('"');
        }

        void writeJsonValue(Object value) throws IOException {
            if (value == null || value == org.json.JSONObject.NULL) {
                writeAscii("null");
            } else if (value instanceof Boolean) {
                writeAscii(((Boolean) value) ? "true" : "false");
            } else if (value instanceof Number) {
                String num = String.valueOf(value);
                if ("NaN".equals(num) || "Infinity".equals(num) || "-Infinity".equals(num)) {
                    writeAscii("null");
                } else {
                    writeAscii(num);
                }
            } else if (value instanceof String) {
                writeJsonString((String) value);
            } else if (value instanceof org.json.JSONObject
                    || value instanceof org.json.JSONArray) {
                writeUtf8Raw(value.toString());
            } else {
                writeJsonString(String.valueOf(value));
            }
        }

        void flush() throws IOException {
            flushBuffer();
            rawOut.flush();
        }

        @Override
        public void close() throws IOException {
            flush();
            rawOut.close();
        }
    }

    private static File resolveBackupTempDir(MainActivity a, File requested) throws IOException {
        File dir = requested;
        if (dir == null && a != null && a.configStore != null && a.configStore.directory != null) {
            dir = new File(a.configStore.directory, "backup-tmp");
        }
        if (dir == null) {
            dir = new File(System.getProperty("java.io.tmpdir", "."));
        }
        if (!dir.exists() && !dir.mkdirs()) {
            throw new IOException("无法创建备份临时目录");
        }
        return dir;
    }

    /**
     * Streams a complete validated backup archive directly into a temporary file on disk,
     * serializing one subscription at a time and enforcing {@link #MAX_BACKUP_BYTES} on exact UTF-8
     * bytes. Verifies the staged file structurally via streaming readback before returning so low-
     * memory TVs (192 MiB heap) can export up to 64 MiB archives safely.
     */
    static File exportBackupToTempFile(MainActivity a, File tempDir) throws Exception {
        File dir = resolveBackupTempDir(a, tempDir);
        File staged = File.createTempFile("marco-backup-", ".tmp", dir);
        try {
            try (FileOutputStream fos = new FileOutputStream(staged);
                    BoundedJsonStreamWriter w =
                            new BoundedJsonStreamWriter(fos, MAX_BACKUP_BYTES)) {
                w.writeAscii(
                        "{\"format\":\"MarcoMovie-1\",\"schema\":\"marco-movie-backup\",\"version\":1");
                w.writeAscii(",\"origin\":");
                w.writeJsonString(a.configOrigin == null ? "" : a.configOrigin);
                w.writeAscii(",\"configOrigin\":");
                w.writeJsonString(a.configOrigin == null ? "" : a.configOrigin);
                w.writeAscii(",\"config\":");
                if (a.config != null && a.config.raw != null) {
                    String cleanRaw = Cms.withoutComments(a.config.raw).trim();
                    boolean wroteObj = false;
                    if (cleanRaw.startsWith("{") && cleanRaw.endsWith("}")) {
                        if (cleanRaw.length() <= 2 * 1024 * 1024) {
                            try {
                                org.json.JSONObject cfgObj = new org.json.JSONObject(cleanRaw);
                                w.writeUtf8Raw(cfgObj.toString());
                                wroteObj = true;
                            } catch (Exception ignored) {
                            }
                        } else if (isStructurallyValidJsonObjectString(cleanRaw)) {
                            w.writeUtf8Raw(cleanRaw);
                            wroteObj = true;
                        }
                    }
                    if (!wroteObj) {
                        w.writeJsonString(a.config.raw);
                    }
                } else {
                    w.writeAscii("null");
                }

                w.writeAscii(",\"settings\":{");
                boolean firstSetting = true;
                java.util.Map<String, ?> allPrefs = null;
                if (a.prefs != null) {
                    for (String key : KEYS) {
                        if (a.prefs.contains(key)) {
                            if (allPrefs == null) allPrefs = a.prefs.getAll();
                            Object val = allPrefs == null ? null : allPrefs.get(key);
                            if (val != null) {
                                if (!firstSetting) w.writeByte(',');
                                firstSetting = false;
                                w.writeJsonString(key);
                                w.writeByte(':');
                                w.writeJsonValue(val);
                            }
                        }
                    }
                    for (String dataKey :
                            new String[] {
                                Prefs.SELECTED_SITE,
                                Prefs.TV_PLAYER_TOOLBAR_ORDER,
                                Prefs.LIVE_UDPXY_URL,
                                Prefs.LIVE_EPG_URL,
                                Prefs.LIVE_SOURCES_JSON,
                                Prefs.WATCH_HISTORY,
                                Prefs.FAVORITES,
                                Prefs.GLOBAL_SEARCH_HISTORY
                            }) {
                        if (a.prefs.contains(dataKey)) {
                            String clean =
                                    Prefs.sanitizeUserData(dataKey, a.prefs.getString(dataKey, ""));
                            if (clean != null) {
                                if (!firstSetting) w.writeByte(',');
                                firstSetting = false;
                                w.writeJsonString(dataKey);
                                w.writeByte(':');
                                w.writeJsonString(clean);
                            }
                        }
                    }
                    String savedLiveUrl = a.prefs.getString(Prefs.LIVE_URL, "");
                    if (Cms.isHttp(savedLiveUrl)) {
                        if (!firstSetting) w.writeByte(',');
                        firstSetting = false;
                        w.writeJsonString(Prefs.LIVE_URL);
                        w.writeByte(':');
                        w.writeJsonString(Cms.normalizeHttp(savedLiveUrl));
                        w.writeByte(',');
                        w.writeJsonString(Prefs.LIVE_NAME);
                        w.writeByte(':');
                        w.writeJsonString(a.prefs.getString(Prefs.LIVE_NAME, "自定义直播源"));
                    }
                }

                if (a.configStore != null) {
                    ConfigLibrary lib = new ConfigLibrary(a.configStore.directory);
                    java.util.List<ConfigLibrary.Entry> entries = lib.entries();
                    java.util.Set<String> exportedIds = new java.util.HashSet<>();
                    java.util.Set<String> exportedOrigins = new java.util.HashSet<>();
                    if (!entries.isEmpty()) {
                        if (!firstSetting) w.writeByte(',');
                        firstSetting = false;
                        w.writeAscii("\"saved_subscriptions\":[");
                        for (int i = 0; i < entries.size(); i++) {
                            ConfigLibrary.Entry entry = entries.get(i);
                            String label =
                                    (entry.name == null || entry.name.trim().isEmpty())
                                            ? entry.id
                                            : entry.name.trim();
                            String rawSub;
                            try {
                                rawSub = lib.raw(entry);
                                validateSavedSubscriptionPayload(rawSub, entry.origin, label);
                            } catch (Exception memberErr) {
                                throw new IOException(
                                        "无法导出备份：订阅「" + label + "」正文损坏或不可读，原备份文件已保留", memberErr);
                            }
                            if (i > 0) w.writeByte(',');
                            w.writeAscii("{\"id\":");
                            w.writeJsonString(entry.id);
                            w.writeAscii(",\"name\":");
                            w.writeJsonString(entry.name);
                            w.writeAscii(",\"url\":");
                            w.writeJsonString(entry.origin);
                            w.writeAscii(",\"rawContent\":");
                            w.writeJsonString(rawSub);
                            w.writeAscii(",\"enabled\":true,\"isPrivate\":false}");
                            exportedIds.add(entry.id);
                            if (entry.origin != null && !entry.origin.trim().isEmpty()) {
                                exportedOrigins.add(entry.origin.trim());
                            }
                            exportedIds.add(ConfigLibrary.identity(entry.origin, rawSub));
                            // Release each raw subscription immediately before reading the next.
                            rawSub = null;
                        }
                        w.writeByte(']');
                    }
                    if (a.isTvDevice() && a.multiSourceStore != null) {
                        org.json.JSONObject msJson = a.multiSourceStore.exportStateJsonStrict();
                        if (msJson != null) {
                            TvMultiSourceStore.State validated =
                                    TvMultiSourceStore.validateBackupStateJson(msJson);
                            if (validated.initialized) {
                                for (TvMultiSourceStore.SubscriptionRecord rec :
                                        validated.subscriptions) {
                                    boolean matched =
                                            (!rec.libraryEntryId.isEmpty()
                                                            && exportedIds.contains(
                                                                    rec.libraryEntryId))
                                                    || (!rec.origin.isEmpty()
                                                            && exportedOrigins.contains(
                                                                    rec.origin));
                                    if (!matched) {
                                        throw new IOException(
                                                "无法导出备份：多源订阅「"
                                                        + (rec.name.isEmpty() ? rec.id : rec.name)
                                                        + "」缺少对应原文，原备份文件已保留");
                                    }
                                }
                            }
                            if (!firstSetting) w.writeByte(',');
                            firstSetting = false;
                            w.writeAscii("\"tv_multi_source_state\":");
                            w.writeUtf8Raw(msJson.toString());
                        }
                    }
                }
                w.writeAscii("}}");
                w.flush();
                fos.getFD().sync();
            }
            verifyStagedBackupFile(staged, MAX_BACKUP_BYTES);
            return staged;
        } catch (Throwable err) {
            staged.delete();
            if (err instanceof Exception) throw (Exception) err;
            throw new IOException("导出备份失败：" + err.getMessage(), err);
        }
    }

    private static boolean isStructurallyValidJsonObjectString(String text) {
        if (text == null || text.length() < 2) return false;
        int depth = 0;
        boolean inStr = false;
        boolean esc = false;
        int len = text.length();
        for (int i = 0; i < len; i++) {
            char c = text.charAt(i);
            if (inStr) {
                if (esc) {
                    esc = false;
                } else if (c == '\\') {
                    esc = true;
                } else if (c == '"') {
                    inStr = false;
                }
                continue;
            }
            if (c == '"') {
                inStr = true;
            } else if (c == '{' || c == '[') {
                depth++;
            } else if (c == '}' || c == ']') {
                depth--;
                if (depth < 0) return false;
                if (depth == 0 && i < len - 1) {
                    for (int j = i + 1; j < len; j++) {
                        if (!Character.isWhitespace(text.charAt(j))) return false;
                    }
                    return true;
                }
            }
        }
        return !inStr && depth == 0;
    }

    /** Streaming structural & size readback check for a staged backup temp file (zero DOM heap). */
    static long verifyStagedBackupFile(File file, int maxBytes) throws IOException {
        if (file == null || !file.isFile()) throw new IOException("暂存备份文件不存在");
        long len = file.length();
        if (len <= 2L) throw new IOException("暂存备份文件为空");
        if (len > maxBytes) {
            throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
        }
        long total = 0L;
        int depth = 0;
        boolean inStr = false;
        boolean esc = false;
        boolean sawStart = false;
        boolean finishedRoot = false;
        byte[] buf = new byte[65536];
        try (FileInputStream in = new FileInputStream(file)) {
            int n;
            while ((n = in.read(buf)) >= 0) {
                total += n;
                if (total > maxBytes) {
                    throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
                }
                for (int i = 0; i < n; i++) {
                    int b = buf[i] & 0xFF;
                    if (inStr) {
                        if (esc) {
                            esc = false;
                        } else if (b == '\\') {
                            esc = true;
                        } else if (b == '"') {
                            inStr = false;
                        }
                        continue;
                    }
                    if (finishedRoot) {
                        if (b != ' ' && b != '\t' && b != '\r' && b != '\n') {
                            throw new IOException("暂存备份 JSON 尾部存在异常数据");
                        }
                        continue;
                    }
                    if (!sawStart) {
                        if (b == ' ' || b == '\t' || b == '\r' || b == '\n') continue;
                        if (b != '{') throw new IOException("暂存备份格式无效");
                        sawStart = true;
                        depth = 1;
                        continue;
                    }
                    if (b == '"') {
                        inStr = true;
                    } else if (b == '{' || b == '[') {
                        depth++;
                    } else if (b == '}' || b == ']') {
                        depth--;
                        if (depth < 0) throw new IOException("暂存备份 JSON 结构损坏");
                        if (depth == 0) finishedRoot = true;
                    }
                }
            }
        }
        if (!sawStart || !finishedRoot || inStr || depth != 0) {
            throw new IOException("暂存备份校验未通过，原备份文件已保留");
        }
        return total;
    }

    static byte[] encodeBackupBytes(org.json.JSONObject backup) throws IOException {
        if (backup == null) throw new IOException("备份内容为空");
        byte[] data = backup.toString().getBytes("UTF-8");
        if (data.length > MAX_BACKUP_BYTES) {
            throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
        }
        return data;
    }

    static byte[] exportBackupBytes(MainActivity a) throws Exception {
        File staged = exportBackupToTempFile(a, null);
        try {
            long len = staged.length();
            if (len > MAX_BACKUP_BYTES) {
                throw new IOException("备份文件超过 64 MB 上限，无法导出，原备份文件已保留");
            }
            // Allocate ONE exact-sized byte[] after streaming temp file releases all member buffers
            // so even 56+ MiB exports stay cleanly within a 192 MiB heap.
            byte[] data = new byte[(int) len];
            int offset = 0;
            try (FileInputStream in = new FileInputStream(staged)) {
                while (offset < data.length) {
                    int n = in.read(data, offset, Math.min(65536, data.length - offset));
                    if (n < 0) break;
                    offset += n;
                }
            }
            if (offset != data.length) {
                throw new IOException("读取暂存备份文件不完整");
            }
            return data;
        } finally {
            staged.delete();
        }
    }

    interface BackupExportDestination {
        InputStream openExistingForRead() throws IOException;

        OutputStream openForWrite() throws IOException;

        File directLocalFileOrNull();

        boolean supportsSiblingNewDocument();

        OutputStream openSiblingNewDocumentForWrite(String suggestedName) throws IOException;
    }

    static final class BackupExportOutcome {
        final long exportedBytes;
        final boolean wroteSiblingDocument;
        final boolean preservedExistingBeforeWrite;
        final File localSafeCopy;

        BackupExportOutcome(
                long exportedBytes,
                boolean wroteSiblingDocument,
                boolean preservedExistingBeforeWrite,
                File localSafeCopy) {
            this.exportedBytes = exportedBytes;
            this.wroteSiblingDocument = wroteSiblingDocument;
            this.preservedExistingBeforeWrite = preservedExistingBeforeWrite;
            this.localSafeCopy = localSafeCopy;
        }
    }

    private static void streamFileToOutput(File src, OutputStream out) throws IOException {
        byte[] buf = new byte[65536];
        try (FileInputStream in = new FileInputStream(src)) {
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n > 0) out.write(buf, 0, n);
            }
        }
    }

    private static void atomicMoveOrCopyToFile(File src, File target) throws IOException {
        File parent = target.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("无法创建目标目录");
        }
        if (src.renameTo(target)) {
            return;
        }
        atomicCopyToFile(src, target);
    }

    private static void atomicCopyToFile(File src, File target) throws IOException {
        File parent = target.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("无法创建目标目录");
        }
        File tmp = File.createTempFile("backup-safe-", ".tmp", parent);
        try {
            try (FileInputStream in = new FileInputStream(src);
                    FileOutputStream out = new FileOutputStream(tmp)) {
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) >= 0) {
                    if (n > 0) out.write(buf, 0, n);
                }
                out.getFD().sync();
            }
            if (!tmp.renameTo(target)) {
                File bak = new File(parent, target.getName() + ".bak");
                if (target.isFile()) {
                    if (bak.exists()) bak.delete();
                    if (!target.renameTo(bak)) {
                        throw new IOException("无法安全替换目标备份文件，原文件已保留");
                    }
                    if (!tmp.renameTo(target)) {
                        bak.renameTo(target);
                        throw new IOException("无法安全替换目标备份文件，原文件已保留");
                    }
                    bak.delete();
                } else {
                    throw new IOException("无法写入目标备份文件");
                }
            }
        } finally {
            tmp.delete();
        }
    }

    private enum ExistingDestStatus {
        CONFIRMED_EMPTY,
        CAPTURED_EXISTING,
        UNREADABLE_OR_UNKNOWN
    }

    private static final class ExistingDestProbe {
        final ExistingDestStatus status;
        final File tempRollbackMirror;
        final long byteCount;

        ExistingDestProbe(ExistingDestStatus status, File tempRollbackMirror, long byteCount) {
            this.status = status;
            this.tempRollbackMirror = tempRollbackMirror;
            this.byteCount = byteCount;
        }

        void cleanupMirror() {
            if (tempRollbackMirror != null && tempRollbackMirror.isFile()) {
                tempRollbackMirror.delete();
            }
        }
    }

    /**
     * Checks whether {@code file} passes the exact same formal streaming restore preflight used by
     * real restore. Guarantees that {@code last-safe-backup.json} can NEVER be overwritten by an
     * unrelated or malformed JSON file.
     */
    static boolean isRestorableBackupFile(MainActivity a, File file) {
        if (file == null || !file.isFile()) return false;
        long len = file.length();
        if (len <= 2L || len > MAX_BACKUP_BYTES) return false;
        boolean tvMulti =
                a == null
                        || (a.isTvDevice() && a.multiSourceStore != null && a.configStore != null);
        try (InputStream in = new FileInputStream(file)) {
            BackupRestorePlan plan = readAndValidateBackupStream(in, tvMulti);
            plan.cleanupTempFiles();
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Probes an existing export destination before any truncating write. Strictly distinguishes:
     * <ul>
     *   <li>{@link ExistingDestStatus#CONFIRMED_EMPTY}: opened cleanly and read 0 bytes.
     *   <li>{@link ExistingDestStatus#CAPTURED_EXISTING}: read {@code >0} bytes into a temporary
     *       rollback mirror file (completely separate from {@code last-safe-backup.json}).
     *   <li>{@link ExistingDestStatus#UNREADABLE_OR_UNKNOWN}: provider refused read, returned null,
     *       errored mid-read, or exceeded {@link #MAX_BACKUP_BYTES}. Caller MUST NOT truncate.
     * </ul>
     */
    private static ExistingDestProbe probeExistingDestination(
            BackupExportDestination dest, File recoveryDir) {
        if (dest == null) {
            return new ExistingDestProbe(ExistingDestStatus.UNREADABLE_OR_UNKNOWN, null, 0L);
        }
        File tmpDir = recoveryDir;
        if (tmpDir == null) {
            tmpDir = new File(System.getProperty("java.io.tmpdir", "."));
        }
        if (!tmpDir.exists()) tmpDir.mkdirs();
        File mirror = null;
        try (InputStream existing = dest.openExistingForRead()) {
            if (existing == null) {
                return new ExistingDestProbe(ExistingDestStatus.UNREADABLE_OR_UNKNOWN, null, 0L);
            }
            mirror = File.createTempFile("rollback-mirror-", ".tmp", tmpDir);
            long total = 0L;
            byte[] buf = new byte[65536];
            try (FileOutputStream out = new FileOutputStream(mirror)) {
                int n;
                while ((n = existing.read(buf)) >= 0) {
                    if (n > 0) {
                        total += n;
                        if (total > MAX_BACKUP_BYTES) {
                            mirror.delete();
                            return new ExistingDestProbe(
                                    ExistingDestStatus.UNREADABLE_OR_UNKNOWN, null, 0L);
                        }
                        out.write(buf, 0, n);
                    }
                }
                out.getFD().sync();
            }
            if (total == 0L) {
                mirror.delete();
                return new ExistingDestProbe(ExistingDestStatus.CONFIRMED_EMPTY, null, 0L);
            }
            return new ExistingDestProbe(ExistingDestStatus.CAPTURED_EXISTING, mirror, total);
        } catch (Throwable readErr) {
            if (mirror != null) mirror.delete();
            return new ExistingDestProbe(ExistingDestStatus.UNREADABLE_OR_UNKNOWN, null, 0L);
        }
    }

    /**
     * Formal production export flow:
     * 1. Streams & validates the complete new backup into a local temp file BEFORE opening target.
     * 2. For direct local files, uses atomic temp+fsync+rename (never truncates existing file) and
     *    updates {@link #lastSafeBackupFile(MainActivity)} only with verified restorable archives.
     * 3. For SAF / document providers:
     *    - Strictly distinguishes confirmed-empty new documents from unreadable/unknown existing
     *      documents. When an existing document cannot be read to confirm safety, writes a sibling
     *      new document if supported or ABORTS before calling {@code openForWrite()}.
     *    - Keeps the per-export temporary destination rollback mirror completely separate from
     *      {@code last-safe-backup.json}. Only files that pass formal restore preflight ({@link
     *      #isRestorableBackupFile}) may ever replace {@code last-safe-backup.json}.
     *    - On any write/flush/close failure, attempts to roll back the destination from its own
     *      temporary rollback mirror and reports honestly whether a verified local safe copy
     *      exists.
     */
    static BackupExportOutcome exportBackupToDestination(
            MainActivity a, BackupExportDestination dest) throws Exception {
        if (dest == null) throw new IOException("目标备份位置不可用");
        File staged = exportBackupToTempFile(a, null);
        File safeCopy = lastSafeBackupFile(a);
        File recoveryDir = safeCopy != null ? safeCopy.getParentFile() : null;
        ExistingDestProbe probe = null;
        try {
            long exportedBytes = staged.length();
            File directFile = dest.directLocalFileOrNull();
            if (directFile != null) {
                atomicCopyToFile(staged, directFile);
                if (safeCopy != null) {
                    try {
                        atomicMoveOrCopyToFile(staged, safeCopy);
                    } catch (Throwable ignored) {
                    }
                }
                return new BackupExportOutcome(exportedBytes, false, false, safeCopy);
            }

            probe = probeExistingDestination(dest, recoveryDir);

            // Never truncate an existing document when the provider refused/failed reading it so
            // we cannot confirm it is empty or preserve a rollback mirror.
            if (probe.status == ExistingDestStatus.UNREADABLE_OR_UNKNOWN) {
                if (dest.supportsSiblingNewDocument()) {
                    OutputStream sibOut = null;
                    try {
                        sibOut = dest.openSiblingNewDocumentForWrite(defaultBackupFileName());
                        if (sibOut == null) throw new IOException("无法创建新备份文档");
                        streamFileToOutput(staged, sibOut);
                        sibOut.flush();
                        sibOut.close();
                        sibOut = null;
                    } catch (Throwable err) {
                        if (sibOut != null) {
                            try {
                                sibOut.close();
                            } catch (Throwable ignored) {
                            }
                        }
                        if (err instanceof IOException) throw (IOException) err;
                        throw new IOException("写入新备份文档失败，原备份文件未改动：" + err.getMessage(), err);
                    }
                    if (safeCopy != null && isRestorableBackupFile(a, staged)) {
                        try {
                            atomicMoveOrCopyToFile(staged, safeCopy);
                        } catch (Throwable ignored) {
                        }
                    }
                    return new BackupExportOutcome(exportedBytes, true, false, safeCopy);
                }
                throw new IOException("无法读取目标备份文件以确认是否安全覆盖，已中止写入以保护原文件；请另存为新文件或更换文件管理器");
            }

            boolean capturedExisting =
                    probe.status == ExistingDestStatus.CAPTURED_EXISTING
                            && probe.tempRollbackMirror != null
                            && probe.tempRollbackMirror.isFile();
            boolean capturedExistingRestorable =
                    capturedExisting && isRestorableBackupFile(a, probe.tempRollbackMirror);

            // ONLY replace last-safe-backup.json when the captured target itself passes formal
            // restore preflight; unrelated or malformed JSON must NEVER clobber a known-good copy.
            if (capturedExistingRestorable && safeCopy != null) {
                try {
                    atomicCopyToFile(probe.tempRollbackMirror, safeCopy);
                } catch (Throwable ignored) {
                }
            }

            if (capturedExisting && dest.supportsSiblingNewDocument()) {
                OutputStream sibOut = null;
                try {
                    sibOut = dest.openSiblingNewDocumentForWrite(defaultBackupFileName());
                    if (sibOut == null) throw new IOException("无法创建新备份文档");
                    streamFileToOutput(staged, sibOut);
                    sibOut.flush();
                    sibOut.close();
                    sibOut = null;
                } catch (Throwable err) {
                    if (sibOut != null) {
                        try {
                            sibOut.close();
                        } catch (Throwable ignored) {
                        }
                    }
                    if (err instanceof IOException) throw (IOException) err;
                    throw new IOException("写入新备份文档失败，原备份文件未改动：" + err.getMessage(), err);
                }
                if (safeCopy != null) {
                    try {
                        atomicMoveOrCopyToFile(staged, safeCopy);
                    } catch (Throwable ignored) {
                    }
                }
                return new BackupExportOutcome(
                        exportedBytes, true, capturedExistingRestorable, safeCopy);
            }

            OutputStream out = null;
            try {
                out = dest.openForWrite();
                if (out == null) throw new IOException("无法写入目标备份文件");
                streamFileToOutput(staged, out);
                out.flush();
                out.close();
                out = null;
            } catch (Throwable writeOrCloseErr) {
                if (out != null) {
                    try {
                        out.close();
                    } catch (Throwable ignored) {
                    }
                }
                boolean restoredTarget = false;
                if (capturedExisting
                        && probe.tempRollbackMirror != null
                        && probe.tempRollbackMirror.isFile()) {
                    OutputStream rb = null;
                    try {
                        rb = dest.openForWrite();
                        if (rb != null) {
                            streamFileToOutput(probe.tempRollbackMirror, rb);
                            rb.flush();
                            rb.close();
                            rb = null;
                            restoredTarget = true;
                        }
                    } catch (Throwable ignored) {
                        if (rb != null) {
                            try {
                                rb.close();
                            } catch (Throwable ignored2) {
                            }
                        }
                    }
                }
                boolean hasValidSafeCopy = isRestorableBackupFile(a, safeCopy);
                String detail =
                        writeOrCloseErr.getMessage() == null
                                ? ""
                                : ("：" + writeOrCloseErr.getMessage());
                if (restoredTarget && hasValidSafeCopy) {
                    throw new IOException(
                            capturedExistingRestorable
                                    ? ("备份写入失败" + detail + "；已自动恢复原备份文件，且本机保留安全副本")
                                    : ("备份写入失败" + detail + "；已自动恢复目标文件，本机上次有效备份副本未受影响，可在设置页直接还原"),
                            writeOrCloseErr);
                }
                if (restoredTarget) {
                    throw new IOException("备份写入失败" + detail + "；已自动恢复目标原文件", writeOrCloseErr);
                }
                if (hasValidSafeCopy) {
                    throw new IOException(
                            "备份写入失败" + detail + "；目标文件可能不完整，本机已保留上次有效备份副本，可在设置页直接还原",
                            writeOrCloseErr);
                }
                if (writeOrCloseErr instanceof IOException) throw (IOException) writeOrCloseErr;
                throw new IOException("备份写入失败" + detail, writeOrCloseErr);
            }

            if (safeCopy != null) {
                try {
                    atomicMoveOrCopyToFile(staged, safeCopy);
                } catch (Throwable ignored) {
                }
            }
            return new BackupExportOutcome(
                    exportedBytes, false, capturedExistingRestorable, safeCopy);
        } finally {
            if (probe != null) probe.cleanupMirror();
            staged.delete();
        }
    }

    private static boolean isConfirmedEmptyContentUri(MainActivity a, Uri uri) {
        if (a == null || uri == null) return false;
        Cursor cursor = null;
        try {
            cursor =
                    a.getContentResolver()
                            .query(uri, new String[] {OpenableColumns.SIZE}, null, null, null);
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) {
                return cursor.getLong(0) == 0L;
            }
        } catch (Throwable ignored) {
        } finally {
            if (cursor != null) {
                try {
                    cursor.close();
                } catch (Throwable ignored) {
                }
            }
        }
        return false;
    }

    static BackupExportOutcome exportBackupToUri(final MainActivity a, final Uri uri)
            throws Exception {
        if (uri == null) throw new IOException("未选择备份保存位置");
        final File localFile =
                "file".equalsIgnoreCase(uri.getScheme()) && uri.getPath() != null
                        ? new File(uri.getPath())
                        : null;
        return exportBackupToDestination(
                a,
                new BackupExportDestination() {
                    @Override
                    public InputStream openExistingForRead() throws IOException {
                        try {
                            InputStream in = a.getContentResolver().openInputStream(uri);
                            if (in == null) {
                                if (isConfirmedEmptyContentUri(a, uri)) {
                                    return new ByteArrayInputStream(new byte[0]);
                                }
                                throw new IOException("无法读取目标文档以确认内容");
                            }
                            return in;
                        } catch (FileNotFoundException e) {
                            if (isConfirmedEmptyContentUri(a, uri)) {
                                return new ByteArrayInputStream(new byte[0]);
                            }
                            throw new IOException("目标文档暂不可读，已中止覆盖", e);
                        } catch (SecurityException e) {
                            throw new IOException("无权读取目标文档以确认是否为空", e);
                        }
                    }

                    @Override
                    public OutputStream openForWrite() throws IOException {
                        return a.getContentResolver().openOutputStream(uri, "wt");
                    }

                    @Override
                    public File directLocalFileOrNull() {
                        return localFile;
                    }

                    @Override
                    public boolean supportsSiblingNewDocument() {
                        return false;
                    }

                    @Override
                    public OutputStream openSiblingNewDocumentForWrite(String suggestedName)
                            throws IOException {
                        throw new IOException("不支持同目录新建文档");
                    }
                });
    }

    private static final java.util.concurrent.ExecutorService BACKUP_RESTORE_EXECUTOR =
            java.util.concurrent.Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "marco-backup-restore");
                        t.setDaemon(true);
                        return t;
                    });
    private static final java.util.concurrent.atomic.AtomicBoolean BACKUP_RESTORE_IN_FLIGHT =
            new java.util.concurrent.atomic.AtomicBoolean(false);

    /** Package-private test hook invoked strictly during Stage 3 (post-commit UI refresh). */
    static volatile Runnable restoreUiRefreshHookForTest;

    static boolean isBackupRestoreInFlight() {
        return BACKUP_RESTORE_IN_FLIGHT.get();
    }

    static final class BackupRestoreMetrics {
        final String entrySource;
        final long preflightMs;
        final long commitMs;
        final String commitThread;
        final long uiPublishMs;
        final String uiThread;
        final boolean committed;
        final String error;
        final String uiRefreshError;

        BackupRestoreMetrics(
                String entrySource,
                long preflightMs,
                long commitMs,
                String commitThread,
                long uiPublishMs,
                String uiThread,
                boolean committed,
                String error,
                String uiRefreshError) {
            this.entrySource = entrySource;
            this.preflightMs = preflightMs;
            this.commitMs = commitMs;
            this.commitThread = commitThread;
            this.uiPublishMs = uiPublishMs;
            this.uiThread = uiThread;
            this.committed = committed;
            this.error = error;
            this.uiRefreshError = uiRefreshError;
        }
    }

    interface BackupRestoreObserver {
        void onComplete(BackupRestoreMetrics metrics);
    }

    static volatile BackupRestoreObserver lastRestoreObserverForTest;

    static final class BackupRestoreCommitResult {
        final boolean committed;
        final boolean useMulti;
        final TvMultiSourceStore.EffectiveBuild built;
        final Cms.Config legacyConfig;
        final String origin;
        final org.json.JSONObject settings;
        final long commitMs;
        final String workerThread;
        Throwable uiRefreshError;

        BackupRestoreCommitResult(
                boolean committed,
                boolean useMulti,
                TvMultiSourceStore.EffectiveBuild built,
                Cms.Config legacyConfig,
                String origin,
                org.json.JSONObject settings,
                long commitMs,
                String workerThread) {
            this.committed = committed;
            this.useMulti = useMulti;
            this.built = built;
            this.legacyConfig = legacyConfig;
            this.origin = origin;
            this.settings = settings;
            this.commitMs = commitMs;
            this.workerThread = workerThread;
        }
    }

    /**
     * Runs backup restore commit asynchronously on the dedicated serial {@code
     * marco-backup-restore} worker thread, guarding against repeated/concurrent confirmation taps
     * while keeping the TV main thread responsive for remote input during staging, hashing, WAL
     * commit, and effective-config rebuild.
     */
    static boolean startAsyncBackupRestore(
            final MainActivity a,
            final BackupRestorePlan plan,
            final long preflightMs,
            final String entrySource,
            final String failureNotice,
            final BackupRestoreObserver observer) {
        if (a == null || plan == null) return false;
        if (!BACKUP_RESTORE_IN_FLIGHT.compareAndSet(false, true)) {
            plan.cleanupTempFiles();
            if (a.ui != null) {
                a.ui.post(() -> a.toast("正在后台还原备份，请稍候…"));
            }
            return false;
        }
        final int oldScale = a.prefs != null ? a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100) : 100;
        if (a.ui != null) {
            a.toast("正在后台还原备份，请稍候…");
        }
        BACKUP_RESTORE_EXECUTOR.execute(
                () -> {
                    final String commitThread = Thread.currentThread().getName();
                    final long commitStartNs = System.nanoTime();
                    BackupRestoreCommitResult commitRes = null;
                    Throwable commitErr = null;
                    try {
                        commitRes = commitBackupRestoreOnWorker(a, plan);
                    } catch (Throwable err) {
                        commitErr = err;
                        AppLog.w(
                                "Settings",
                                "async backup restore (" + entrySource + ") failed",
                                err);
                    } finally {
                        plan.cleanupTempFiles();
                    }
                    final long commitMs =
                            Math.max(0L, (System.nanoTime() - commitStartNs) / 1_000_000L);
                    final BackupRestoreCommitResult finalRes = commitRes;
                    final Throwable finalErr = commitErr;
                    Runnable publishOnUi =
                            () -> {
                                final String uiThread = Thread.currentThread().getName();
                                final long uiStartNs = System.nanoTime();
                                Throwable uiErr = null;
                                try {
                                    if (finalErr != null) {
                                        if (a.ui != null && !a.isFinishing() && !a.isDestroyed()) {
                                            a.notice(failureNotice);
                                        }
                                    } else if (finalRes != null) {
                                        uiErr = publishBackupRestoreUi(a, finalRes, oldScale);
                                    }
                                } finally {
                                    BACKUP_RESTORE_IN_FLIGHT.set(false);
                                }
                                final long uiMs =
                                        Math.max(0L, (System.nanoTime() - uiStartNs) / 1_000_000L);
                                BackupRestoreMetrics metrics =
                                        new BackupRestoreMetrics(
                                                entrySource,
                                                preflightMs,
                                                commitMs,
                                                commitThread,
                                                uiMs,
                                                uiThread,
                                                finalRes != null && finalRes.committed,
                                                finalErr == null ? "" : finalErr.toString(),
                                                uiErr == null ? "" : uiErr.toString());
                                if (observer != null) observer.onComplete(metrics);
                                BackupRestoreObserver hook = lastRestoreObserverForTest;
                                if (hook != null) hook.onComplete(metrics);
                            };
                    if (a.ui != null) {
                        a.ui.post(publishOnUi);
                    } else {
                        publishOnUi.run();
                    }
                });
        return true;
    }

    static void restoreFromLocalSafeCopy(final MainActivity a) {
        restoreFromLocalSafeCopy(a, null);
    }

    static void restoreFromLocalSafeCopy(
            final MainActivity a, final BackupRestoreObserver observer) {
        if (isBackupRestoreInFlight()) {
            a.toast("正在后台还原备份，请稍候…");
            return;
        }
        final File safeCopy = lastSafeBackupFile(a);
        if (safeCopy == null || !safeCopy.isFile() || safeCopy.length() <= 0) {
            a.notice("未找到可恢复的本机安全备份副本。");
            return;
        }
        BACKUP_RESTORE_EXECUTOR.execute(
                () -> {
                    final long preflightStartNs = System.nanoTime();
                    try {
                        final BackupRestorePlan plan;
                        try (InputStream input = new FileInputStream(safeCopy)) {
                            plan =
                                    readAndValidateBackupStream(
                                            input,
                                            a.isTvDevice()
                                                    && a.multiSourceStore != null
                                                    && a.configStore != null);
                        }
                        final long preflightMs =
                                Math.max(0L, (System.nanoTime() - preflightStartNs) / 1_000_000L);
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || a.isDestroyed()) {
                                        plan.cleanupTempFiles();
                                        return;
                                    }
                                    final java.util.concurrent.atomic.AtomicBoolean confirmed =
                                            new java.util.concurrent.atomic.AtomicBoolean(false);
                                    AppDialog dlg =
                                            new AppDialog.Builder(a)
                                                    .setTitle("从本机安全副本还原？")
                                                    .setMessage("将恢复上次有效导出时保存的完整配置、订阅与偏好。网盘账号保持不变。")
                                                    .setNegativeButton(
                                                            "取消",
                                                            (d, i) -> {
                                                                if (confirmed.compareAndSet(
                                                                        false, true)) {
                                                                    plan.cleanupTempFiles();
                                                                }
                                                            })
                                                    .setPositiveButton(
                                                            "立即还原",
                                                            (d, i) -> {
                                                                if (!confirmed.compareAndSet(
                                                                        false, true)) {
                                                                    return;
                                                                }
                                                                startAsyncBackupRestore(
                                                                        a,
                                                                        plan,
                                                                        preflightMs,
                                                                        "local-safe-copy",
                                                                        "安全副本无法还原，当前数据未改动。",
                                                                        observer);
                                                            })
                                                    .show();
                                    dlg.setOnDismissListener(
                                            d -> {
                                                if (a.ui != null) {
                                                    a.ui.post(
                                                            () -> {
                                                                if (confirmed.compareAndSet(
                                                                        false, true)) {
                                                                    plan.cleanupTempFiles();
                                                                }
                                                            });
                                                } else if (confirmed.compareAndSet(false, true)) {
                                                    plan.cleanupTempFiles();
                                                }
                                            });
                                });
                    } catch (Exception error) {
                        AppLog.w("Settings", "read local safe backup failed", error);
                        String detail = error.getMessage();
                        a.ui.post(
                                () ->
                                        a.notice(
                                                detail != null && !detail.trim().isEmpty()
                                                        ? detail.trim()
                                                        : "本机安全副本读取失败。"));
                    }
                });
    }

    static org.json.JSONObject readBackupJson(InputStream input) throws Exception {
        if (input == null) throw new IOException("无法打开备份文件");
        // Spool to a temp file first so reading large 37–64 MiB archives avoids
        // ByteArrayOutputStream 2x doubling inside 192 MiB TV heaps.
        File tmpDir = new File(System.getProperty("java.io.tmpdir", "."));
        if (!tmpDir.exists()) tmpDir.mkdirs();
        File spooled = File.createTempFile("marco-backup-in-", ".tmp", tmpDir);
        try {
            long total = 0L;
            byte[] buf = new byte[65536];
            try (FileOutputStream out = new FileOutputStream(spooled)) {
                int n;
                while ((n = input.read(buf)) >= 0) {
                    if (n > 0) {
                        total += n;
                        if (total > MAX_BACKUP_BYTES) {
                            throw new IOException("响应超过大小限制");
                        }
                        out.write(buf, 0, n);
                    }
                }
            }
            if (total <= 0L) throw new IOException("备份文件为空");
            byte[] exact = new byte[(int) total];
            int offset = 0;
            try (FileInputStream in = new FileInputStream(spooled)) {
                while (offset < exact.length) {
                    int n = in.read(exact, offset, Math.min(65536, exact.length - offset));
                    if (n < 0) break;
                    offset += n;
                }
            }
            String text = new String(exact, 0, offset, java.nio.charset.StandardCharsets.UTF_8);
            exact = null;
            String clean = Cms.withoutComments(text).trim();
            text = null;
            if (!clean.startsWith("{")) throw new IOException("备份文件格式无效");
            return new org.json.JSONObject(clean);
        } finally {
            spooled.delete();
        }
    }

    private static void validateSavedSubscriptionPayload(String rawSub, String origin, String label)
            throws Exception {
        String trimmed = rawSub == null ? "" : rawSub.trim();
        if (trimmed.isEmpty()) {
            throw new IOException("订阅正文为空：" + label);
        }
        if (Cms.utf8ByteLength(rawSub) > ConfigLibrary.MAX_SUBSCRIPTION_BYTES) {
            throw new IOException("订阅正文超过 16 MB 限制：" + label);
        }
        try {
            Cms.parseConfig(rawSub, origin);
        } catch (IOException parseErr) {
            // Allow legitimate pure-live raw subscription JSON that has a valid non-empty lives
            // array.
            org.json.JSONObject subRoot = new org.json.JSONObject(Cms.withoutComments(trimmed));
            org.json.JSONArray lvs = subRoot.optJSONArray("lives");
            if (lvs == null || lvs.length() == 0) {
                throw parseErr;
            }
        }
    }

    static final class SpooledSubscription {
        final String declaredId;
        final String canonicalId;
        final String digest;
        final String name;
        final String url;
        final File rawFile;
        final boolean hasDerivedKeys;

        SpooledSubscription(
                String declaredId,
                String canonicalId,
                String digest,
                String name,
                String url,
                File rawFile,
                boolean hasDerivedKeys) {
            this.declaredId = declaredId == null ? "" : declaredId;
            this.canonicalId = canonicalId;
            this.digest = digest;
            this.name = name == null ? "" : name;
            this.url = url == null ? "" : url;
            this.rawFile = rawFile;
            this.hasDerivedKeys = hasDerivedKeys;
        }
    }

    static final class BackupRestorePlan {
        final String origin;
        final String configJson;
        final Cms.Config legacyConfig;
        final org.json.JSONObject settings;
        final org.json.JSONArray savedSubscriptions;
        final java.util.List<SpooledSubscription> spooledSubscriptions;
        final File spoolTempDir;
        final org.json.JSONObject multiSourceState;

        BackupRestorePlan(
                String origin,
                String configJson,
                Cms.Config legacyConfig,
                org.json.JSONObject settings,
                org.json.JSONArray savedSubscriptions,
                org.json.JSONObject multiSourceState) {
            this(
                    origin,
                    configJson,
                    legacyConfig,
                    settings,
                    savedSubscriptions,
                    null,
                    null,
                    multiSourceState);
        }

        BackupRestorePlan(
                String origin,
                String configJson,
                Cms.Config legacyConfig,
                org.json.JSONObject settings,
                org.json.JSONArray savedSubscriptions,
                java.util.List<SpooledSubscription> spooledSubscriptions,
                File spoolTempDir,
                org.json.JSONObject multiSourceState) {
            this.origin = origin;
            this.configJson = configJson;
            this.legacyConfig = legacyConfig;
            this.settings = settings;
            this.savedSubscriptions = savedSubscriptions;
            this.spooledSubscriptions = spooledSubscriptions;
            this.spoolTempDir = spoolTempDir;
            this.multiSourceState = multiSourceState;
        }

        boolean usesMultiSourceRestore() {
            return multiSourceState != null;
        }

        int savedSubscriptionCount() {
            if (spooledSubscriptions != null) return spooledSubscriptions.size();
            return savedSubscriptions != null ? savedSubscriptions.length() : 0;
        }

        void cleanupTempFiles() {
            if (spooledSubscriptions != null) {
                for (SpooledSubscription s : spooledSubscriptions) {
                    if (s != null && s.rawFile != null && s.rawFile.isFile()) {
                        s.rawFile.delete();
                    }
                }
            }
            if (spoolTempDir != null && spoolTempDir.exists()) {
                File[] children = spoolTempDir.listFiles();
                if (children != null) {
                    for (File c : children) c.delete();
                }
                spoolTempDir.delete();
            }
        }
    }

    /**
     * Pure-JVM streaming JSON reader used by {@link #readAndValidateBackupStream} so 37–64 MiB
     * backups with multi-subscription payloads restore cleanly inside 192 MiB TV heaps (including
     * UTF-16 CJK preferences on Android 9 ART) by streaming one {@code rawContent} to disk at a
     * time instead of materializing all raw subscriptions simultaneously.
     */
    private static final class BackupStreamReader {
        private final java.io.Reader in;
        private final char[] rbuf = new char[32768];
        private int rpos = 0;
        private int rlen = 0;

        BackupStreamReader(java.io.Reader in) {
            this.in = in;
        }

        private boolean refill() throws IOException {
            if (rpos < rlen) return true;
            rpos = 0;
            rlen = in.read(rbuf, 0, rbuf.length);
            if (rlen < 0) {
                rlen = 0;
                return false;
            }
            return rlen > 0;
        }

        private int readRawChar() throws IOException {
            if (rpos >= rlen && !refill()) return -1;
            return rbuf[rpos++];
        }

        private int peekRawChar() throws IOException {
            if (rpos >= rlen && !refill()) return -1;
            return rbuf[rpos];
        }

        int peekTokenChar() throws IOException {
            while (true) {
                int c = peekRawChar();
                if (c < 0) return -1;
                if (c <= ' ' || c == '\uFEFF') {
                    readRawChar();
                    continue;
                }
                if (c == '/') {
                    readRawChar();
                    int n = peekRawChar();
                    if (n == '/') {
                        readRawChar();
                        while (true) {
                            int ch = readRawChar();
                            if (ch < 0 || ch == '\n' || ch == '\r') break;
                        }
                        continue;
                    }
                    if (n == '*') {
                        readRawChar();
                        int prev = -1;
                        while (true) {
                            int ch = readRawChar();
                            if (ch < 0) throw new IOException("备份文件注释未闭合");
                            if (prev == '*' && ch == '/') break;
                            prev = ch;
                        }
                        continue;
                    }
                    throw new IOException("备份文件 JSON 格式无效");
                }
                return c;
            }
        }

        void expect(char expected) throws IOException {
            int c = peekTokenChar();
            if (c != expected) {
                throw new IOException("备份文件 JSON 格式无效");
            }
            readRawChar();
        }

        String readString() throws IOException {
            expect('"');
            StringBuilder sb = new StringBuilder(64);
            while (true) {
                int c = readRawChar();
                if (c < 0) throw new IOException("备份文件字符串未闭合");
                if (c == '"') return sb.toString();
                if (c == '\\') {
                    sb.append(readEscapeChar());
                } else {
                    sb.append((char) c);
                }
            }
        }

        long streamStringToFile(File dst, long maxBytes) throws IOException {
            expect('"');
            long byteCount = 0L;
            final byte[] outBuf = new byte[32768];
            int outPos = 0;
            try (FileOutputStream fos = new FileOutputStream(dst)) {
                while (true) {
                    if (rpos >= rlen && !refill()) {
                        throw new IOException("备份文件字符串未闭合");
                    }
                    // Fast inner loop over buffered ASCII characters (zero locks, zero per-char
                    // OutputStreamWriter calls — 15-20x faster on ARMv7 TV CPUs).
                    final char[] local = this.rbuf;
                    int p = this.rpos;
                    final int lim = this.rlen;
                    while (p < lim) {
                        char c = local[p];
                        if (c == '"' || c == '\\' || c >= 0x80) break;
                        if (outPos >= outBuf.length) {
                            byteCount += outPos;
                            if (byteCount > maxBytes) throw new IOException("订阅正文超过 16 MB 限制");
                            fos.write(outBuf, 0, outPos);
                            outPos = 0;
                        }
                        outBuf[outPos++] = (byte) c;
                        p++;
                    }
                    this.rpos = p;
                    if (p >= lim) continue;

                    char c = local[this.rpos++];
                    if (c == '"') break;
                    char ch = (c == '\\') ? readEscapeChar() : c;
                    if (outPos + 4 > outBuf.length) {
                        byteCount += outPos;
                        if (byteCount > maxBytes) throw new IOException("订阅正文超过 16 MB 限制");
                        fos.write(outBuf, 0, outPos);
                        outPos = 0;
                    }
                    if (ch < 0x80) {
                        outBuf[outPos++] = (byte) ch;
                    } else if (ch < 0x800) {
                        outBuf[outPos++] = (byte) (0xC0 | (ch >> 6));
                        outBuf[outPos++] = (byte) (0x80 | (ch & 0x3F));
                    } else if (Character.isHighSurrogate(ch)) {
                        int next = peekRawChar();
                        char low = 0;
                        boolean haveLow = false;
                        if (next == '\\') {
                            readRawChar();
                            char esc = readEscapeChar();
                            if (Character.isLowSurrogate(esc)) {
                                low = esc;
                                haveLow = true;
                            } else {
                                // Emit replacement for unpaired high surrogate + esc
                                outBuf[outPos++] = (byte) 0xEF;
                                outBuf[outPos++] = (byte) 0xBF;
                                outBuf[outPos++] = (byte) 0xBD;
                                if (outPos + 4 > outBuf.length) {
                                    byteCount += outPos;
                                    if (byteCount > maxBytes)
                                        throw new IOException("订阅正文超过 16 MB 限制");
                                    fos.write(outBuf, 0, outPos);
                                    outPos = 0;
                                }
                                if (esc < 0x80) {
                                    outBuf[outPos++] = (byte) esc;
                                } else if (esc < 0x800) {
                                    outBuf[outPos++] = (byte) (0xC0 | (esc >> 6));
                                    outBuf[outPos++] = (byte) (0x80 | (esc & 0x3F));
                                } else {
                                    outBuf[outPos++] = (byte) (0xE0 | (esc >> 12));
                                    outBuf[outPos++] = (byte) (0x80 | ((esc >> 6) & 0x3F));
                                    outBuf[outPos++] = (byte) (0x80 | (esc & 0x3F));
                                }
                                continue;
                            }
                        } else if (next >= 0 && Character.isLowSurrogate((char) next)) {
                            low = (char) readRawChar();
                            haveLow = true;
                        }
                        if (haveLow) {
                            int cp = Character.toCodePoint(ch, low);
                            outBuf[outPos++] = (byte) (0xF0 | (cp >> 18));
                            outBuf[outPos++] = (byte) (0x80 | ((cp >> 12) & 0x3F));
                            outBuf[outPos++] = (byte) (0x80 | ((cp >> 6) & 0x3F));
                            outBuf[outPos++] = (byte) (0x80 | (cp & 0x3F));
                        } else {
                            outBuf[outPos++] = (byte) 0xEF;
                            outBuf[outPos++] = (byte) 0xBF;
                            outBuf[outPos++] = (byte) 0xBD;
                        }
                    } else {
                        outBuf[outPos++] = (byte) (0xE0 | (ch >> 12));
                        outBuf[outPos++] = (byte) (0x80 | ((ch >> 6) & 0x3F));
                        outBuf[outPos++] = (byte) (0x80 | (ch & 0x3F));
                    }
                }
                if (outPos > 0) {
                    byteCount += outPos;
                    if (byteCount > maxBytes) throw new IOException("订阅正文超过 16 MB 限制");
                    fos.write(outBuf, 0, outPos);
                }
            }
            return byteCount;
        }

        private char readEscapeChar() throws IOException {
            int esc = readRawChar();
            if (esc < 0) throw new IOException("备份文件转义序列不完整");
            switch (esc) {
                case '"':
                    return '"';
                case '\\':
                    return '\\';
                case '/':
                    return '/';
                case 'b':
                    return '\b';
                case 'f':
                    return '\f';
                case 'n':
                    return '\n';
                case 'r':
                    return '\r';
                case 't':
                    return '\t';
                case 'u':
                    int code = 0;
                    for (int i = 0; i < 4; i++) {
                        int h = readRawChar();
                        int digit = Character.digit(h, 16);
                        if (digit < 0) throw new IOException("备份文件 Unicode 转义无效");
                        code = (code << 4) | digit;
                    }
                    return (char) code;
                default:
                    throw new IOException("备份文件存在非法转义字符");
            }
        }

        Object readValue() throws Exception {
            int c = peekTokenChar();
            if (c < 0) throw new IOException("备份文件意外结束");
            if (c == '{') return readObject();
            if (c == '[') return readArray();
            if (c == '"') return readString();
            if (c == 't') {
                expectLiteral("true");
                return Boolean.TRUE;
            }
            if (c == 'f') {
                expectLiteral("false");
                return Boolean.FALSE;
            }
            if (c == 'n') {
                expectLiteral("null");
                return org.json.JSONObject.NULL;
            }
            return readNumber();
        }

        org.json.JSONObject readObject() throws Exception {
            expect('{');
            org.json.JSONObject obj = new org.json.JSONObject();
            int c = peekTokenChar();
            if (c == '}') {
                readRawChar();
                return obj;
            }
            while (true) {
                String k = readString();
                expect(':');
                obj.put(k, readValue());
                int next = peekTokenChar();
                if (next == ',') {
                    readRawChar();
                } else if (next == '}') {
                    readRawChar();
                    return obj;
                } else {
                    throw new IOException("备份文件 JSON 对象缺少分隔符");
                }
            }
        }

        org.json.JSONArray readArray() throws Exception {
            expect('[');
            org.json.JSONArray arr = new org.json.JSONArray();
            int c = peekTokenChar();
            if (c == ']') {
                readRawChar();
                return arr;
            }
            while (true) {
                arr.put(readValue());
                int next = peekTokenChar();
                if (next == ',') {
                    readRawChar();
                } else if (next == ']') {
                    readRawChar();
                    return arr;
                } else {
                    throw new IOException("备份文件 JSON 数组缺少分隔符");
                }
            }
        }

        private void expectLiteral(String lit) throws IOException {
            for (int i = 0; i < lit.length(); i++) {
                int c = readRawChar();
                if (c != lit.charAt(i)) throw new IOException("备份文件 JSON 字面量无效");
            }
        }

        private Number readNumber() throws IOException {
            StringBuilder sb = new StringBuilder(24);
            boolean isFloat = false;
            while (true) {
                int c = peekRawChar();
                if ((c >= '0' && c <= '9')
                        || c == '-'
                        || c == '+'
                        || c == '.'
                        || c == 'e'
                        || c == 'E') {
                    if (c == '.' || c == 'e' || c == 'E') isFloat = true;
                    sb.append((char) readRawChar());
                } else {
                    break;
                }
            }
            if (sb.length() == 0) throw new IOException("备份文件数字无效");
            String num = sb.toString();
            try {
                if (isFloat) return Double.valueOf(num);
                long v = Long.parseLong(num);
                if (v >= Integer.MIN_VALUE && v <= Integer.MAX_VALUE) {
                    return Integer.valueOf((int) v);
                }
                return Long.valueOf(v);
            } catch (NumberFormatException e) {
                throw new IOException("备份文件数字格式无效：" + num, e);
            }
        }
    }

    /**
     * Streaming, low-memory equivalent of {@code validateBackupForRestore(readBackupJson(in),
     * tvMultiSourceCapable)} for 192 MiB TVs. Spools each {@code saved_subscriptions[i].rawContent}
     * to a private temp file and validates subscriptions one at a time so peak heap stays under
     * ~25 MiB even for 64 MiB archives containing CJK preferences.
     */
    static BackupRestorePlan readAndValidateBackupStream(
            InputStream input, boolean tvMultiSourceCapable) throws Exception {
        if (input == null) throw new IOException("无法打开备份文件");
        File tmpBase = new File(System.getProperty("java.io.tmpdir", "."));
        if (!tmpBase.exists()) tmpBase.mkdirs();
        File spooledArchive = File.createTempFile("marco-backup-stream-", ".tmp", tmpBase);
        File stageDir =
                new File(
                        tmpBase,
                        "marco-backup-plan-"
                                + System.nanoTime()
                                + "-"
                                + java.util.UUID.randomUUID().toString().substring(0, 8));
        if (!stageDir.mkdirs()) {
            spooledArchive.delete();
            throw new IOException("无法创建备份还原暂存目录");
        }
        java.util.List<SpooledSubscription> spooledSubs = null;
        boolean succeeded = false;
        try {
            long total = 0L;
            byte[] buf = new byte[65536];
            try (FileOutputStream out = new FileOutputStream(spooledArchive)) {
                int n;
                while ((n = input.read(buf)) >= 0) {
                    if (n > 0) {
                        total += n;
                        if (total > MAX_BACKUP_BYTES) {
                            throw new IOException("响应超过大小限制");
                        }
                        out.write(buf, 0, n);
                    }
                }
            }
            if (total <= 0L) throw new IOException("备份文件为空");

            org.json.JSONObject rootMeta = new org.json.JSONObject();
            org.json.JSONObject settings = null;
            java.util.Map<String, SpooledSubscription> savedByCanonicalId =
                    new java.util.LinkedHashMap<>();
            java.util.Map<String, String> canonicalIdByOrigin = new java.util.HashMap<>();
            java.util.Set<String> seenDeclaredIds = new java.util.HashSet<>();
            java.util.Set<String> seenOrigins = new java.util.HashSet<>();

            try (java.io.BufferedReader br =
                    new java.io.BufferedReader(
                            new java.io.InputStreamReader(
                                    new FileInputStream(spooledArchive),
                                    java.nio.charset.StandardCharsets.UTF_8),
                            65536)) {
                BackupStreamReader jr = new BackupStreamReader(br);
                if (jr.peekTokenChar() != '{') throw new IOException("备份文件格式无效");
                jr.expect('{');
                if (jr.peekTokenChar() != '}') {
                    while (true) {
                        String key = jr.readString();
                        jr.expect(':');
                        if ("settings".equals(key)) {
                            int sc = jr.peekTokenChar();
                            if (sc == 'n') {
                                jr.readValue();
                                settings = null;
                            } else if (sc == '{') {
                                jr.expect('{');
                                settings = new org.json.JSONObject();
                                if (jr.peekTokenChar() != '}') {
                                    while (true) {
                                        String sk = jr.readString();
                                        jr.expect(':');
                                        if ("saved_subscriptions".equals(sk)) {
                                            int arrChar = jr.peekTokenChar();
                                            if (arrChar == 'n') {
                                                jr.readValue();
                                                spooledSubs = null;
                                            } else if (arrChar == '[') {
                                                jr.expect('[');
                                                spooledSubs = new java.util.ArrayList<>();
                                                if (jr.peekTokenChar() != ']') {
                                                    int idx = 0;
                                                    while (true) {
                                                        if (jr.peekTokenChar() != '{') {
                                                            throw new IOException(
                                                                    "备份中的第 " + (idx + 1)
                                                                            + " 条订阅项无效");
                                                        }
                                                        jr.expect('{');
                                                        String subId = "";
                                                        String subOrigin = "";
                                                        String subName = "";
                                                        File rawFile = null;
                                                        if (jr.peekTokenChar() != '}') {
                                                            while (true) {
                                                                String fk = jr.readString();
                                                                jr.expect(':');
                                                                if ("rawContent".equals(fk)) {
                                                                    if (jr.peekTokenChar() == '"') {
                                                                        rawFile =
                                                                                new File(
                                                                                        stageDir,
                                                                                        "sub-" + idx
                                                                                                + ".json");
                                                                        jr.streamStringToFile(
                                                                                rawFile,
                                                                                ConfigLibrary
                                                                                        .MAX_SUBSCRIPTION_BYTES);
                                                                    } else {
                                                                        Object rv = jr.readValue();
                                                                        if (rv != null
                                                                                && rv
                                                                                        != org.json
                                                                                                .JSONObject
                                                                                                .NULL) {
                                                                            rawFile =
                                                                                    new File(
                                                                                            stageDir,
                                                                                            "sub-"
                                                                                                    + idx
                                                                                                    + ".json");
                                                                            byte[] b =
                                                                                    String.valueOf(
                                                                                                    rv)
                                                                                            .getBytes(
                                                                                                    java
                                                                                                            .nio
                                                                                                            .charset
                                                                                                            .StandardCharsets
                                                                                                            .UTF_8);
                                                                            if (b.length
                                                                                    > ConfigLibrary
                                                                                            .MAX_SUBSCRIPTION_BYTES) {
                                                                                throw new IOException(
                                                                                        "订阅正文超过 16 MB 限制");
                                                                            }
                                                                            try (FileOutputStream
                                                                                    fos =
                                                                                            new FileOutputStream(
                                                                                                    rawFile)) {
                                                                                fos.write(b);
                                                                            }
                                                                        }
                                                                    }
                                                                } else {
                                                                    Object fv = jr.readValue();
                                                                    String sv =
                                                                            (fv == null
                                                                                            || fv
                                                                                                    == org
                                                                                                            .json
                                                                                                            .JSONObject
                                                                                                            .NULL)
                                                                                    ? ""
                                                                                    : String
                                                                                            .valueOf(
                                                                                                    fv);
                                                                    if ("id".equals(fk)) {
                                                                        subId = sv.trim();
                                                                    } else if ("url".equals(fk)) {
                                                                        subOrigin = sv.trim();
                                                                    } else if ("name".equals(fk)) {
                                                                        subName = sv.trim();
                                                                    }
                                                                }
                                                                int fn = jr.peekTokenChar();
                                                                if (fn == ',') {
                                                                    jr.readRawChar();
                                                                } else if (fn == '}') {
                                                                    jr.readRawChar();
                                                                    break;
                                                                } else {
                                                                    throw new IOException(
                                                                            "备份订阅对象格式无效");
                                                                }
                                                            }
                                                        } else {
                                                            jr.readRawChar();
                                                        }
                                                        String label =
                                                                subName.isEmpty()
                                                                        ? ("#" + (idx + 1))
                                                                        : subName;
                                                        if (rawFile == null
                                                                || !rawFile.isFile()
                                                                || rawFile.length() <= 0L) {
                                                            throw new IOException(
                                                                    "订阅正文为空：" + label);
                                                        }
                                                        // Validate ONE subscription at a time and
                                                        // release its String immediately!
                                                        byte[] subBytes =
                                                                readFileBytesBounded(
                                                                        rawFile,
                                                                        ConfigLibrary
                                                                                .MAX_SUBSCRIPTION_BYTES);
                                                        String subRaw =
                                                                new String(
                                                                        subBytes,
                                                                        java.nio.charset
                                                                                .StandardCharsets
                                                                                .UTF_8);
                                                        String digest =
                                                                ConfigLibrary.hashBytes(subBytes);
                                                        subBytes = null;
                                                        validateSavedSubscriptionPayload(
                                                                subRaw, subOrigin, label);
                                                        String canonicalId =
                                                                ConfigLibrary.identity(
                                                                        subOrigin, subRaw);
                                                        boolean hasDerived =
                                                                ConfigLibrary
                                                                        .rawJsonHasDerivedRuntimeSiteKeys(
                                                                                subRaw);
                                                        subRaw = null;
                                                        if (!subId.isEmpty()
                                                                && !subId.equals(canonicalId)) {
                                                            throw new IOException(
                                                                    "备份中的第 "
                                                                            + (idx + 1)
                                                                            + " 条订阅声明 ID 与来源地址冲突："
                                                                            + label);
                                                        }
                                                        if (!subId.isEmpty()
                                                                && !seenDeclaredIds.add(subId)) {
                                                            throw new IOException(
                                                                    "备份中的订阅正文存在重复 ID：" + subId);
                                                        }
                                                        if (!subOrigin.isEmpty()
                                                                && !seenOrigins.add(subOrigin)) {
                                                            throw new IOException(
                                                                    "备份中的订阅正文存在重复来源地址："
                                                                            + subOrigin);
                                                        }
                                                        SpooledSubscription entry =
                                                                new SpooledSubscription(
                                                                        subId,
                                                                        canonicalId,
                                                                        digest,
                                                                        subName,
                                                                        subOrigin,
                                                                        rawFile,
                                                                        hasDerived);
                                                        if (savedByCanonicalId.put(
                                                                        canonicalId, entry)
                                                                != null) {
                                                            throw new IOException(
                                                                    "备份中的订阅正文存在身份冲突：" + label);
                                                        }
                                                        if (!subOrigin.isEmpty()) {
                                                            canonicalIdByOrigin.put(
                                                                    subOrigin, canonicalId);
                                                        }
                                                        spooledSubs.add(entry);
                                                        idx++;
                                                        int an = jr.peekTokenChar();
                                                        if (an == ',') {
                                                            jr.readRawChar();
                                                        } else if (an == ']') {
                                                            jr.readRawChar();
                                                            break;
                                                        } else {
                                                            throw new IOException("备份订阅列表格式无效");
                                                        }
                                                    }
                                                } else {
                                                    jr.readRawChar();
                                                }
                                            } else {
                                                throw new IOException(
                                                        "备份中的 saved_subscriptions 格式无效");
                                            }
                                        } else {
                                            settings.put(sk, jr.readValue());
                                        }
                                        int sn = jr.peekTokenChar();
                                        if (sn == ',') {
                                            jr.readRawChar();
                                        } else if (sn == '}') {
                                            jr.readRawChar();
                                            break;
                                        } else {
                                            throw new IOException("备份设置对象格式无效");
                                        }
                                    }
                                } else {
                                    jr.readRawChar();
                                }
                            } else {
                                jr.readValue();
                            }
                        } else {
                            rootMeta.put(key, jr.readValue());
                        }
                        int rn = jr.peekTokenChar();
                        if (rn == ',') {
                            jr.readRawChar();
                        } else if (rn == '}') {
                            jr.readRawChar();
                            break;
                        } else {
                            throw new IOException("备份根对象格式无效");
                        }
                    }
                } else {
                    jr.readRawChar();
                }
            }

            if (!Prefs.isBackupObject(
                    rootMeta.optString("format", null),
                    rootMeta.optString("schema", null),
                    rootMeta.optInt("version", 0))) {
                throw new IOException("Invalid backup");
            }
            final String origin =
                    rootMeta.has("origin") && !rootMeta.optString("origin").isEmpty()
                            ? rootMeta.optString("origin", "")
                            : rootMeta.optString("configOrigin", "");
            final String configJson;
            if (!rootMeta.has("config") || rootMeta.isNull("config")) {
                configJson = null;
            } else {
                configJson = Prefs.extractBackupConfigJson(rootMeta.opt("config"));
                if (configJson == null) throw new IOException("Invalid backup config");
            }
            if (settings != null) {
                for (String key :
                        new String[] {
                            Prefs.WATCH_HISTORY, Prefs.FAVORITES, Prefs.GLOBAL_SEARCH_HISTORY
                        }) {
                    if (!settings.has(key)) continue;
                    org.json.JSONArray rows =
                            new org.json.JSONArray(String.valueOf(settings.get(key)));
                    for (int i = 0; i < rows.length(); i++) {
                        if (Prefs.GLOBAL_SEARCH_HISTORY.equals(key)) {
                            if (!(rows.get(i) instanceof String))
                                throw new IOException("Invalid search history");
                        } else {
                            org.json.JSONObject item = rows.getJSONObject(i);
                            if (item.optString("id").isEmpty() || item.optString("site").isEmpty())
                                throw new IOException("Invalid bookmark");
                        }
                    }
                }
            }
            org.json.JSONObject rawMsState = null;
            if (tvMultiSourceCapable
                    && settings != null
                    && settings.has("tv_multi_source_state")
                    && !settings.isNull("tv_multi_source_state")) {
                Object msObj = settings.opt("tv_multi_source_state");
                if (!(msObj instanceof org.json.JSONObject)) {
                    throw new IOException("备份中的 tv_multi_source_state 格式无效");
                }
                rawMsState = (org.json.JSONObject) msObj;
            }
            org.json.JSONObject validatedMsState = null;
            if (rawMsState != null) {
                TvMultiSourceStore.State parsedState =
                        TvMultiSourceStore.validateBackupStateJson(rawMsState);
                if (parsedState.initialized) {
                    if (configJson != null) {
                        String trimmedCfg = Cms.withoutComments(configJson).trim();
                        if (!trimmedCfg.startsWith("{"))
                            throw new IOException("Invalid backup config");
                        new org.json.JSONObject(trimmedCfg);
                    }
                    java.util.Set<String> claimedCanonicalIds = new java.util.HashSet<>();
                    java.util.Set<String> seenStateOrigins = new java.util.HashSet<>();
                    for (TvMultiSourceStore.SubscriptionRecord rec : parsedState.subscriptions) {
                        String recLabel = rec.name.isEmpty() ? rec.id : rec.name;
                        if (!rec.origin.isEmpty() && !seenStateOrigins.add(rec.origin)) {
                            throw new IOException("备份中的多源状态存在重复来源地址：" + rec.origin);
                        }
                        String matchedCanonicalId = null;
                        if (!rec.libraryEntryId.isEmpty()
                                && savedByCanonicalId.containsKey(rec.libraryEntryId)) {
                            matchedCanonicalId = rec.libraryEntryId;
                        } else if (!rec.origin.isEmpty()
                                && canonicalIdByOrigin.containsKey(rec.origin)) {
                            matchedCanonicalId = canonicalIdByOrigin.get(rec.origin);
                        }
                        if (matchedCanonicalId == null) {
                            throw new IOException("备份中的多源订阅缺少对应原文：" + recLabel);
                        }
                        if (!rec.libraryEntryId.isEmpty()
                                && !rec.libraryEntryId.equals(matchedCanonicalId)) {
                            throw new IOException("备份中的多源状态 ID 与订阅正文身份冲突：" + recLabel);
                        }
                        SpooledSubscription matchedSub = savedByCanonicalId.get(matchedCanonicalId);
                        String matchedOrigin = matchedSub == null ? "" : matchedSub.url;
                        if (!rec.origin.isEmpty()
                                && !matchedOrigin.isEmpty()
                                && !rec.origin.equals(matchedOrigin)) {
                            throw new IOException("备份中的多源状态来源地址与正文不一致：" + recLabel);
                        }
                        if (!claimedCanonicalIds.add(matchedCanonicalId)) {
                            throw new IOException("备份中的多源状态与订阅正文存在一对多冲突：" + recLabel);
                        }
                    }
                    validatedMsState = rawMsState;
                }
            }
            Cms.Config legacyConfig = null;
            if (validatedMsState == null) {
                legacyConfig = configJson == null ? null : Cms.parseConfig(configJson, origin);
            } else if (configJson != null) {
                try {
                    legacyConfig = Cms.parseConfig(configJson, origin);
                } catch (IOException ignored) {
                }
            }
            BackupRestorePlan plan =
                    new BackupRestorePlan(
                            origin,
                            configJson,
                            legacyConfig,
                            settings,
                            null,
                            spooledSubs,
                            stageDir,
                            validatedMsState);
            succeeded = true;
            return plan;
        } finally {
            spooledArchive.delete();
            if (!succeeded) {
                if (spooledSubs != null) {
                    for (SpooledSubscription s : spooledSubs) {
                        if (s != null && s.rawFile != null && s.rawFile.isFile()) {
                            s.rawFile.delete();
                        }
                    }
                }
                if (stageDir.exists()) {
                    File[] children = stageDir.listFiles();
                    if (children != null) {
                        for (File c : children) c.delete();
                    }
                    stageDir.delete();
                }
            }
        }
    }

    private static byte[] readFileBytesBounded(File file, int maxBytes) throws IOException {
        long len = file.length();
        if (len > maxBytes) throw new IOException("订阅正文超过 16 MB 限制");
        byte[] exact = new byte[(int) len];
        int off = 0;
        try (FileInputStream in = new FileInputStream(file)) {
            while (off < exact.length) {
                int n = in.read(exact, off, Math.min(65536, exact.length - off));
                if (n < 0) break;
                off += n;
            }
        }
        return exact;
    }

    static org.json.JSONObject buildBackupJson(MainActivity a) throws Exception {
        Object exportedConfig = org.json.JSONObject.NULL;
        if (a.config != null && a.config.raw != null) {
            try {
                String cleanRaw = Cms.withoutComments(a.config.raw).trim();
                exportedConfig =
                        cleanRaw.startsWith("{") ? new org.json.JSONObject(cleanRaw) : a.config.raw;
            } catch (Exception ignored) {
                exportedConfig = a.config.raw;
            }
        }
        org.json.JSONObject backup =
                new org.json.JSONObject()
                        .put("format", "MarcoMovie-1")
                        .put("schema", "marco-movie-backup")
                        .put("version", 1)
                        .put("origin", a.configOrigin)
                        .put("configOrigin", a.configOrigin)
                        .put("config", exportedConfig);
        org.json.JSONObject settings = new org.json.JSONObject();
        for (String key : KEYS)
            if (a.prefs.contains(key)) settings.put(key, a.prefs.getAll().get(key));
        for (String dataKey :
                new String[] {
                    Prefs.SELECTED_SITE,
                    Prefs.TV_PLAYER_TOOLBAR_ORDER,
                    Prefs.LIVE_UDPXY_URL,
                    Prefs.LIVE_EPG_URL,
                    Prefs.LIVE_SOURCES_JSON,
                    Prefs.WATCH_HISTORY,
                    Prefs.FAVORITES,
                    Prefs.GLOBAL_SEARCH_HISTORY
                }) {
            if (a.prefs.contains(dataKey)) {
                String clean = Prefs.sanitizeUserData(dataKey, a.prefs.getString(dataKey, ""));
                if (clean != null) settings.put(dataKey, clean);
            }
        }
        String savedLiveUrl = a.prefs.getString(Prefs.LIVE_URL, "");
        if (Cms.isHttp(savedLiveUrl)) {
            settings.put(Prefs.LIVE_URL, Cms.normalizeHttp(savedLiveUrl));
            settings.put(Prefs.LIVE_NAME, a.prefs.getString(Prefs.LIVE_NAME, "自定义直播源"));
        }
        if (a.configStore != null) {
            ConfigLibrary lib = new ConfigLibrary(a.configStore.directory);
            java.util.List<ConfigLibrary.Entry> entries = lib.entries();
            org.json.JSONArray subs = new org.json.JSONArray();
            java.util.Set<String> exportedIds = new java.util.HashSet<>();
            java.util.Set<String> exportedOrigins = new java.util.HashSet<>();
            for (ConfigLibrary.Entry entry : entries) {
                String label =
                        (entry.name == null || entry.name.trim().isEmpty())
                                ? entry.id
                                : entry.name.trim();
                String rawSub;
                try {
                    rawSub = lib.raw(entry);
                    validateSavedSubscriptionPayload(rawSub, entry.origin, label);
                } catch (Exception memberErr) {
                    throw new IOException("无法导出备份：订阅「" + label + "」正文损坏或不可读，原备份文件已保留", memberErr);
                }
                subs.put(
                        new org.json.JSONObject()
                                .put("id", entry.id)
                                .put("name", entry.name)
                                .put("url", entry.origin)
                                .put("rawContent", rawSub)
                                .put("enabled", true)
                                .put("isPrivate", false));
                exportedIds.add(entry.id);
                if (entry.origin != null && !entry.origin.trim().isEmpty()) {
                    exportedOrigins.add(entry.origin.trim());
                }
                exportedIds.add(ConfigLibrary.identity(entry.origin, rawSub));
            }
            if (subs.length() > 0) {
                settings.put("saved_subscriptions", subs);
            }
            if (a.isTvDevice() && a.multiSourceStore != null) {
                org.json.JSONObject msJson = a.multiSourceStore.exportStateJsonStrict();
                if (msJson != null) {
                    TvMultiSourceStore.State validated =
                            TvMultiSourceStore.validateBackupStateJson(msJson);
                    if (validated.initialized) {
                        for (TvMultiSourceStore.SubscriptionRecord rec : validated.subscriptions) {
                            boolean matched =
                                    (!rec.libraryEntryId.isEmpty()
                                                    && exportedIds.contains(rec.libraryEntryId))
                                            || (!rec.origin.isEmpty()
                                                    && exportedOrigins.contains(rec.origin));
                            if (!matched) {
                                throw new IOException(
                                        "无法导出备份：多源订阅「"
                                                + (rec.name.isEmpty() ? rec.id : rec.name)
                                                + "」缺少对应原文，原备份文件已保留");
                            }
                        }
                    }
                    settings.put("tv_multi_source_state", msJson);
                }
            }
        }
        backup.put("settings", settings);
        return backup;
    }

    /**
     * Strictly validates a backup payload BEFORE touching any existing user configuration or prefs.
     * Supports legitimate TV multi-source empty-VOD backups (all subscriptions disabled, or enabled
     * parent with zero enabled VOD lines) by validating every raw saved subscription and every
     * multi-source state record (including non-empty unique IDs), while preserving strict non-empty
     * sites validation for ordinary single-source backups.
     */
    static BackupRestorePlan validateBackupForRestore(
            org.json.JSONObject backup, boolean tvMultiSourceCapable) throws Exception {
        if (backup == null
                || !Prefs.isBackupObject(
                        backup.optString("format", null),
                        backup.optString("schema", null),
                        backup.optInt("version", 0))) {
            throw new IOException("Invalid backup");
        }
        final String origin =
                backup.has("origin") && !backup.optString("origin").isEmpty()
                        ? backup.optString("origin", "")
                        : backup.optString("configOrigin", "");
        final String configJson;
        if (!backup.has("config") || backup.isNull("config")) {
            configJson = null;
        } else {
            configJson = Prefs.extractBackupConfigJson(backup.opt("config"));
            if (configJson == null) throw new IOException("Invalid backup config");
        }
        final org.json.JSONObject settings = backup.optJSONObject("settings");
        final org.json.JSONArray savedSubscriptions;
        if (settings != null
                && settings.has("saved_subscriptions")
                && !settings.isNull("saved_subscriptions")) {
            Object rawSavedObj = settings.opt("saved_subscriptions");
            if (!(rawSavedObj instanceof org.json.JSONArray)) {
                throw new IOException("备份中的 saved_subscriptions 格式无效");
            }
            savedSubscriptions = (org.json.JSONArray) rawSavedObj;
        } else {
            savedSubscriptions = null;
        }
        java.util.Map<String, org.json.JSONObject> savedByCanonicalId =
                new java.util.LinkedHashMap<>();
        java.util.Map<String, String> canonicalIdByOrigin = new java.util.HashMap<>();
        java.util.Set<String> seenDeclaredIds = new java.util.HashSet<>();
        java.util.Set<String> seenOrigins = new java.util.HashSet<>();
        if (savedSubscriptions != null) {
            for (int i = 0; i < savedSubscriptions.length(); i++) {
                org.json.JSONObject sub = savedSubscriptions.optJSONObject(i);
                if (sub == null) {
                    throw new IOException("备份中的第 " + (i + 1) + " 条订阅项无效");
                }
                String subRaw = sub.optString("rawContent", "");
                String subOrigin = sub.optString("url", "").trim();
                String subName = sub.optString("name", "").trim();
                String label = subName.isEmpty() ? ("#" + (i + 1)) : subName;
                validateSavedSubscriptionPayload(subRaw, subOrigin, label);
                String canonicalId = ConfigLibrary.identity(subOrigin, subRaw);
                String subId = sub.optString("id", "").trim();
                if (!subId.isEmpty() && !subId.equals(canonicalId)) {
                    throw new IOException("备份中的第 " + (i + 1) + " 条订阅声明 ID 与来源地址冲突：" + label);
                }
                if (!subId.isEmpty() && !seenDeclaredIds.add(subId)) {
                    throw new IOException("备份中的订阅正文存在重复 ID：" + subId);
                }
                if (!subOrigin.isEmpty() && !seenOrigins.add(subOrigin)) {
                    throw new IOException("备份中的订阅正文存在重复来源地址：" + subOrigin);
                }
                if (savedByCanonicalId.put(canonicalId, sub) != null) {
                    throw new IOException("备份中的订阅正文存在身份冲突：" + label);
                }
                if (!subOrigin.isEmpty()) {
                    canonicalIdByOrigin.put(subOrigin, canonicalId);
                }
            }
        }
        if (settings != null) {
            for (String key :
                    new String[] {
                        Prefs.WATCH_HISTORY, Prefs.FAVORITES, Prefs.GLOBAL_SEARCH_HISTORY
                    }) {
                if (!settings.has(key)) continue;
                org.json.JSONArray rows = new org.json.JSONArray(String.valueOf(settings.get(key)));
                for (int i = 0; i < rows.length(); i++) {
                    if (Prefs.GLOBAL_SEARCH_HISTORY.equals(key)) {
                        if (!(rows.get(i) instanceof String))
                            throw new IOException("Invalid search history");
                    } else {
                        org.json.JSONObject item = rows.getJSONObject(i);
                        if (item.optString("id").isEmpty() || item.optString("site").isEmpty())
                            throw new IOException("Invalid bookmark");
                    }
                }
            }
        }

        org.json.JSONObject rawMsState = null;
        if (tvMultiSourceCapable
                && settings != null
                && settings.has("tv_multi_source_state")
                && !settings.isNull("tv_multi_source_state")) {
            Object msObj = settings.opt("tv_multi_source_state");
            if (!(msObj instanceof org.json.JSONObject)) {
                throw new IOException("备份中的 tv_multi_source_state 格式无效");
            }
            rawMsState = (org.json.JSONObject) msObj;
        }
        org.json.JSONObject validatedMsState = null;
        if (rawMsState != null) {
            TvMultiSourceStore.State parsedState =
                    TvMultiSourceStore.validateBackupStateJson(rawMsState);
            if (parsedState.initialized) {
                if (configJson != null) {
                    // Ensure exported config snapshot is structurally valid JSON (empty sites is
                    // valid).
                    String trimmedCfg = Cms.withoutComments(configJson).trim();
                    if (!trimmedCfg.startsWith("{")) throw new IOException("Invalid backup config");
                    new org.json.JSONObject(trimmedCfg);
                }
                java.util.Set<String> claimedCanonicalIds = new java.util.HashSet<>();
                java.util.Set<String> seenStateOrigins = new java.util.HashSet<>();
                for (TvMultiSourceStore.SubscriptionRecord rec : parsedState.subscriptions) {
                    String recLabel = rec.name.isEmpty() ? rec.id : rec.name;
                    if (!rec.origin.isEmpty() && !seenStateOrigins.add(rec.origin)) {
                        throw new IOException("备份中的多源状态存在重复来源地址：" + rec.origin);
                    }
                    String matchedCanonicalId = null;
                    if (!rec.libraryEntryId.isEmpty()
                            && savedByCanonicalId.containsKey(rec.libraryEntryId)) {
                        matchedCanonicalId = rec.libraryEntryId;
                    } else if (!rec.origin.isEmpty()
                            && canonicalIdByOrigin.containsKey(rec.origin)) {
                        matchedCanonicalId = canonicalIdByOrigin.get(rec.origin);
                    }
                    if (matchedCanonicalId == null) {
                        throw new IOException("备份中的多源订阅缺少对应原文：" + recLabel);
                    }
                    if (!rec.libraryEntryId.isEmpty()
                            && !rec.libraryEntryId.equals(matchedCanonicalId)) {
                        throw new IOException("备份中的多源状态 ID 与订阅正文身份冲突：" + recLabel);
                    }
                    org.json.JSONObject matchedSub = savedByCanonicalId.get(matchedCanonicalId);
                    String matchedOrigin =
                            matchedSub == null ? "" : matchedSub.optString("url", "").trim();
                    if (!rec.origin.isEmpty()
                            && !matchedOrigin.isEmpty()
                            && !rec.origin.equals(matchedOrigin)) {
                        throw new IOException("备份中的多源状态来源地址与正文不一致：" + recLabel);
                    }
                    if (!claimedCanonicalIds.add(matchedCanonicalId)) {
                        throw new IOException("备份中的多源状态与订阅正文存在一对多冲突：" + recLabel);
                    }
                }
                validatedMsState = rawMsState;
            }
        }

        Cms.Config legacyConfig = null;
        if (validatedMsState == null) {
            legacyConfig = configJson == null ? null : Cms.parseConfig(configJson, origin);
        } else if (configJson != null) {
            try {
                legacyConfig = Cms.parseConfig(configJson, origin);
            } catch (IOException ignored) {
                // Zero-VOD multi-source state is valid; runtime config will be rebuilt from raw
                // subs.
            }
        }
        return new BackupRestorePlan(
                origin, configJson, legacyConfig, settings, savedSubscriptions, validatedMsState);
    }

    /**
     * Stages subscription files (Phase 1) and atomically commits files + preferences inside a
     * durable WAL transaction (Phase 2). Safe to run entirely on a background worker thread (no
     * View/UI calls).
     *
     * <p>Guarantees:
     * <ul>
     *   <li>Any failure in Phase 1 or Phase 2 (including preference {@code apply()} failure) rolls
     *       back the WAL transaction cleanly and removes ONLY unreferenced newly created files —
     *       never deleting any content file referenced by the active {@code index.json}.
     *   <li>Once {@link ConfigLibrary.RestoreTransaction#finalizeCommit()} succeeds, {@code
     *       committed} is permanently {@code true} and committed files are never cleaned up.
     * </ul>
     */
    static BackupRestoreCommitResult commitBackupRestoreOnWorker(
            MainActivity a, BackupRestorePlan plan) throws Exception {
        if (plan == null) throw new IOException("还原计划为空");
        final long startNs = System.nanoTime();
        final String workerName = Thread.currentThread().getName();
        ConfigLibrary lib =
                a.configStore != null ? new ConfigLibrary(a.configStore.directory) : null;
        ConfigLibrary.StagedRestoreBatch stagedBatch = null;
        boolean useMulti =
                plan.usesMultiSourceRestore()
                        && a.isTvDevice()
                        && a.multiSourceStore != null
                        && a.configStore != null;

        // Stage 1: pre-commit staging of immutable subscription content files.
        if (plan.spooledSubscriptions != null && lib != null) {
            java.util.List<ConfigLibrary.StagedSubInput> inputs =
                    new java.util.ArrayList<>(plan.spooledSubscriptions.size());
            long now = System.currentTimeMillis();
            for (int idx = 0; idx < plan.spooledSubscriptions.size(); idx++) {
                SpooledSubscription sub = plan.spooledSubscriptions.get(idx);
                if (sub == null || sub.rawFile == null || !sub.rawFile.isFile()) {
                    throw new IOException("备份订阅暂存文件缺失");
                }
                inputs.add(
                        new ConfigLibrary.StagedSubInput(
                                sub.rawFile,
                                sub.canonicalId,
                                sub.digest,
                                sub.hasDerivedKeys,
                                sub.url,
                                sub.name.isEmpty() ? "已恢复的订阅" : sub.name,
                                "",
                                now + idx));
            }
            stagedBatch = lib.stageRestoreBatch(inputs, useMulti);
        } else if (plan.savedSubscriptions != null && lib != null) {
            java.util.List<ConfigLibrary.StagedSubInput> inputs =
                    new java.util.ArrayList<>(plan.savedSubscriptions.length());
            long now = System.currentTimeMillis();
            for (int idx = 0; idx < plan.savedSubscriptions.length(); idx++) {
                org.json.JSONObject sub = plan.savedSubscriptions.optJSONObject(idx);
                if (sub == null) throw new IOException("备份订阅项无效");
                String subRaw = sub.optString("rawContent", "");
                if (subRaw.trim().isEmpty()) throw new IOException("备份订阅正文为空");
                inputs.add(
                        new ConfigLibrary.StagedSubInput(
                                subRaw,
                                sub.optString("url", ""),
                                sub.optString("name", "已恢复的订阅"),
                                "",
                                now + idx));
            }
            stagedBatch = lib.stageRestoreBatch(inputs, useMulti);
        }

        // Stage 2: WAL-guarded file + preference commit. Before preferences are persisted, any
        // failure rolls back the WAL completely to the pre-restore state. Once preferences & watch
        // history have been durably persisted, the commit direction is forward: any subsequent
        // finalization I/O error keeps live new files and the COMMITTING_PREFS WAL intact so reads
        // and next startup converge cleanly to the complete new generation (never split-brain).
        ConfigLibrary.RestoreTransaction tx = null;
        boolean prefsPersisted = false;
        boolean committed = false;
        try {
            if (useMulti) {
                java.util.List<ConfigLibrary.Entry> stagedEntries =
                        stagedBatch != null ? stagedBatch.entries : lib.entries();
                TvMultiSourceStore.State stagedState =
                        a.multiSourceStore.prepareBackupRestore(
                                stagedEntries, plan.multiSourceState);
                String preferred =
                        a.prefs != null ? a.prefs.getString(Prefs.PREFERRED_SITE, "") : "";
                TvMultiSourceStore.SiteAvailability avail =
                        a.ui != null ? (cfg, st) -> SourceController.available(a, cfg, st) : null;
                TvMultiSourceStore.EffectiveBuild built =
                        a.multiSourceStore.buildEffectiveConfigFromSnapshot(
                                lib, stagedEntries, stagedState, preferred, avail);
                String newStateJson = stagedState.toJson().toString();
                String newConfigRaw =
                        (built != null && built.config != null) ? built.config.raw : null;

                tx =
                        ConfigLibrary.beginAndWriteRestoreTransaction(
                                a.configStore.directory,
                                stagedBatch != null ? stagedBatch.newIndexJson : null,
                                newStateJson,
                                newConfigRaw,
                                stagedBatch != null ? stagedBatch.createdFiles : null);
                org.json.JSONObject prefsSnap = buildRestorablePrefsJson(plan.settings);
                tx.markCommittingPrefs(prefsSnap != null ? prefsSnap.toString() : null);
                restoreSettingsPreferencesOnly(a, plan.settings, tx);
                prefsPersisted = true;
                tx.markPrefsPersisted();
                tx.finalizeCommit();
                committed = true;
                a.multiSourceStore.invalidateCache();
                long commitMs = Math.max(0L, (System.nanoTime() - startNs) / 1_000_000L);
                return new BackupRestoreCommitResult(
                        true,
                        true,
                        built,
                        null,
                        built != null ? built.effectiveOrigin : plan.origin,
                        plan.settings,
                        commitMs,
                        workerName);
            }

            if (a.configStore != null
                    && (stagedBatch != null
                            || (plan.legacyConfig != null && plan.legacyConfig.raw != null))) {
                tx =
                        ConfigLibrary.beginAndWriteRestoreTransaction(
                                a.configStore.directory,
                                stagedBatch != null ? stagedBatch.newIndexJson : null,
                                null,
                                plan.legacyConfig != null ? plan.legacyConfig.raw : null,
                                stagedBatch != null ? stagedBatch.createdFiles : null);
                org.json.JSONObject prefsSnap = buildRestorablePrefsJson(plan.settings);
                tx.markCommittingPrefs(prefsSnap != null ? prefsSnap.toString() : null);
            }
            restoreSettingsPreferencesOnly(a, plan.settings, tx);
            prefsPersisted = true;
            if (tx != null) {
                tx.markPrefsPersisted();
                tx.finalizeCommit();
            }
            committed = true;
            if (a.multiSourceStore != null) a.multiSourceStore.invalidateCache();
            long commitMs = Math.max(0L, (System.nanoTime() - startNs) / 1_000_000L);
            return new BackupRestoreCommitResult(
                    true,
                    false,
                    null,
                    plan.legacyConfig,
                    plan.origin,
                    plan.settings,
                    commitMs,
                    workerName);
        } catch (ConfigLibrary.SimulatedProcessKill kill) {
            // Deliberately keep WAL on disk to exercise cold-start crash recovery.
            throw kill;
        } catch (Throwable err) {
            if (!committed) {
                if (prefsPersisted) {
                    if (tx != null) {
                        tx.abandonFinalizeKeepForwardWal();
                    }
                } else if (tx != null) {
                    tx.rollback();
                } else if (stagedBatch != null) {
                    stagedBatch.cleanupCreatedFiles();
                }
                if (a.multiSourceStore != null) a.multiSourceStore.invalidateCache();
            }
            if (err instanceof Exception) throw (Exception) err;
            throw new IOException("备份还原失败，已保留原数据：" + err.getMessage(), err);
        }
    }

    /**
     * Stage 3: post-commit runtime & UI publication. Committed disk state is NEVER rolled back or
     * cleaned up if UI refresh fails; any refresh error is caught, logged, and returned so callers
     * can report it cleanly while preserving the newly committed data.
     */
    static Throwable publishBackupRestoreUi(
            MainActivity a, BackupRestoreCommitResult result, int oldScale) {
        if (a == null || result == null || !result.committed) return null;
        try {
            if (result.useMulti) {
                if (result.built != null) {
                    a.config = result.built.config;
                    a.configOrigin = result.built.effectiveOrigin;
                }
            } else if (result.legacyConfig != null) {
                a.config = result.legacyConfig;
                a.configOrigin = result.origin;
            }
            a.invalidateWatchHistoryCache();
            CatalogScreen.invalidateTvHistoryHost(a);
            if (a.prefs != null) {
                try {
                    a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false);
                } catch (Throwable ignored) {
                }
            }

            Runnable testHook = restoreUiRefreshHookForTest;
            if (testHook != null) {
                testHook.run();
            }

            if (result.settings != null
                    && result.settings.has(Prefs.WATCH_HISTORY)
                    && !result.settings.isNull(Prefs.WATCH_HISTORY)
                    && WatchHistory.validateBackupJson(result.settings.opt(Prefs.WATCH_HISTORY))
                            == null
                    && a.ui != null
                    && !a.isFinishing()
                    && !a.isDestroyed()) {
                a.notice("备份中的观看历史格式错误，未能恢复观看历史。");
            }

            if (a.ui != null && !a.isFinishing() && !a.isDestroyed()) {
                if (result.useMulti) {
                    a.applyMultiSourceEffectiveBuild(result.built, false, 0, 0, "备份已还原");
                } else {
                    a.closeEngines();
                    a.refresh();
                    a.toast("备份已还原");
                }
                if (oldScale >= 0
                        && a.prefs != null
                        && oldScale != a.prefs.getInt(Prefs.UI_SCALE_PERCENT, 100)) {
                    a.recreate();
                }
            }
            return null;
        } catch (Throwable uiErr) {
            result.uiRefreshError = uiErr;
            AppLog.w("Settings", "post-commit backup UI refresh failed", uiErr);
            if (a.ui != null && !a.isFinishing() && !a.isDestroyed()) {
                try {
                    a.notice("备份数据已成功还原，但界面刷新遇到异常，重新进入或重启后即可生效。");
                } catch (Throwable ignored) {
                }
            }
            return uiErr;
        }
    }

    /**
     * Synchronous facade used by tests and direct callers: executes Stage 1 + Stage 2 atomically,
     * then executes Stage 3 UI publication in a separate try/catch so a post-commit UI refresh
     * error can never roll back or delete committed subscription files.
     */
    static TvMultiSourceStore.EffectiveBuild applyBackupRestore(
            MainActivity a, BackupRestorePlan plan) throws Exception {
        BackupRestoreCommitResult res = commitBackupRestoreOnWorker(a, plan);
        publishBackupRestoreUi(a, res, -1);
        return res.built;
    }

    static void result(MainActivity a, int request, Uri uri) {
        result(a, request, uri, null);
    }

    static void result(
            final MainActivity a,
            final int request,
            final Uri uri,
            final BackupRestoreObserver observer) {
        if (a.privateMode && (request == 45 || request == 46)) return;
        if ((request == 45 || request == 46) && isBackupRestoreInFlight()) {
            a.toast("正在后台还原备份，请稍候…");
            return;
        }
        java.util.concurrent.Executor executor = request == 46 ? BACKUP_RESTORE_EXECUTOR : a.worker;
        executor.execute(
                () -> {
                    try {
                        if (request == 44) {
                            try (InputStream input = a.getContentResolver().openInputStream(uri)) {
                                saveWallpaper(a, input);
                            }
                        } else if (request == 45) {
                            // Stream, validate every subscription & state, enforce MAX_BACKUP_BYTES
                            // in a temp file, probe existing destination before write, and safely
                            // abort/rollback on unreadable or write/close failures.
                            exportBackupToUri(a, uri);
                        } else if (request == 46) {
                            final long preflightStartNs = System.nanoTime();
                            final BackupRestorePlan plan;
                            try (InputStream input = a.getContentResolver().openInputStream(uri)) {
                                plan =
                                        readAndValidateBackupStream(
                                                input,
                                                a.isTvDevice()
                                                        && a.multiSourceStore != null
                                                        && a.configStore != null);
                            }
                            final long preflightMs =
                                    Math.max(
                                            0L,
                                            (System.nanoTime() - preflightStartNs) / 1_000_000L);
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing() || a.isDestroyed()) {
                                            plan.cleanupTempFiles();
                                            return;
                                        }
                                        final java.util.concurrent.atomic.AtomicBoolean confirmed =
                                                new java.util.concurrent.atomic.AtomicBoolean(
                                                        false);
                                        AppDialog dlg =
                                                new AppDialog.Builder(a)
                                                        .setTitle("还原备份？")
                                                        .setMessage("将替换本机来源配置与外观、播放偏好。网盘账号保持不变。")
                                                        .setNegativeButton(
                                                                "取消",
                                                                (d, i) -> {
                                                                    if (confirmed.compareAndSet(
                                                                            false, true)) {
                                                                        plan.cleanupTempFiles();
                                                                    }
                                                                })
                                                        .setPositiveButton(
                                                                "还原",
                                                                (d, i) -> {
                                                                    if (!confirmed.compareAndSet(
                                                                            false, true)) {
                                                                        return;
                                                                    }
                                                                    startAsyncBackupRestore(
                                                                            a,
                                                                            plan,
                                                                            preflightMs,
                                                                            "external-file",
                                                                            "备份无法还原，当前数据未改动。",
                                                                            observer);
                                                                })
                                                        .show();
                                        dlg.setOnDismissListener(
                                                d -> {
                                                    if (a.ui != null) {
                                                        a.ui.post(
                                                                () -> {
                                                                    if (confirmed.compareAndSet(
                                                                            false, true)) {
                                                                        plan.cleanupTempFiles();
                                                                    }
                                                                });
                                                    } else if (confirmed.compareAndSet(
                                                            false, true)) {
                                                        plan.cleanupTempFiles();
                                                    }
                                                });
                                    });
                            return;
                        }
                        a.ui.post(
                                () -> {
                                    a.refresh();
                                    a.toast(request == 45 ? "备份已保存" : "壁纸已更新");
                                });
                    } catch (Exception error) {
                        AppLog.w("Settings", "file result " + request + " failed", error);
                        String detail = error.getMessage();
                        String msg =
                                (detail != null && !detail.trim().isEmpty())
                                        ? detail.trim()
                                        : "文件无法处理。请检查文件格式与可用存储空间。";
                        a.ui.post(() -> a.notice(msg));
                    }
                });
    }

    private static final String[] RESTORE_DATA_KEYS = {
        Prefs.SELECTED_SITE,
        Prefs.TV_PLAYER_TOOLBAR_ORDER,
        Prefs.LIVE_UDPXY_URL,
        Prefs.LIVE_EPG_URL,
        Prefs.LIVE_SOURCES_JSON,
        Prefs.LIVE_URL,
        Prefs.LIVE_NAME,
        Prefs.FAVORITES,
        Prefs.GLOBAL_SEARCH_HISTORY
    };

    private static boolean hasAnyRestorablePrefKey(org.json.JSONObject settings) {
        if (settings == null) return false;
        for (String key : KEYS) {
            if (settings.has(key) && !settings.isNull(key)) return true;
        }
        for (String dataKey : RESTORE_DATA_KEYS) {
            if (settings.has(dataKey) && !settings.isNull(dataKey)) return true;
        }
        return settings.has(Prefs.WATCH_HISTORY) && !settings.isNull(Prefs.WATCH_HISTORY);
    }

    /**
     * Extracts ONLY the compact restorable preferences (including validated {@code WATCH_HISTORY})
     * for durable WAL replay without copying multi-megabyte {@code saved_subscriptions}.
     */
    static org.json.JSONObject buildRestorablePrefsJson(org.json.JSONObject settings) {
        if (settings == null || !hasAnyRestorablePrefKey(settings)) return null;
        org.json.JSONObject out = new org.json.JSONObject();
        try {
            for (String key : KEYS) {
                if (settings.has(key) && !settings.isNull(key)) {
                    Object clean = Prefs.sanitizeSetting(key, settings.opt(key));
                    if (clean != null) out.put(key, clean);
                }
            }
            for (String dataKey : RESTORE_DATA_KEYS) {
                if (settings.has(dataKey) && !settings.isNull(dataKey)) {
                    String cleanData = Prefs.sanitizeUserData(dataKey, settings.opt(dataKey));
                    if (cleanData != null) out.put(dataKey, cleanData);
                }
            }
            if (settings.has(Prefs.WATCH_HISTORY) && !settings.isNull(Prefs.WATCH_HISTORY)) {
                String validatedHistory =
                        WatchHistory.validateBackupJson(settings.opt(Prefs.WATCH_HISTORY));
                if (validatedHistory != null) {
                    out.put(Prefs.WATCH_HISTORY, validatedHistory);
                }
            }
        } catch (Throwable ignored) {
        }
        return out.length() > 0 ? out : null;
    }

    /**
     * Atomically applies all restorable settings, user data keys, and validated watch history into
     * a single {@link android.content.SharedPreferences.Editor} batch. Uses synchronous {@code
     * commit()} on real Android worker threads so disk persistence completes before WAL
     * finalization, and bumps {@link WatchHistory#bumpRestoreEpoch()} so any stale pre-restore
     * playback writes queued behind a busy storage executor cannot overwrite the restored history.
     */
    private static final class PrefChangeExpectation {
        final String key;
        final Object expectedValue;

        PrefChangeExpectation(String key, Object expectedValue) {
            this.key = key;
            this.expectedValue = expectedValue;
        }
    }

    private static boolean prefCurrentlyMatches(
            android.content.SharedPreferences prefs, String key, Object expectedValue) {
        try {
            if (expectedValue instanceof Boolean) {
                boolean nv = (Boolean) expectedValue;
                return prefs.getBoolean(key, !nv) == nv;
            }
            if (expectedValue instanceof Integer) {
                int nv = (Integer) expectedValue;
                int sentinel = nv == Integer.MIN_VALUE ? 0 : Integer.MIN_VALUE;
                return prefs.getInt(key, sentinel) == nv;
            }
            if (expectedValue instanceof Float) {
                float nv = (Float) expectedValue;
                float sentinel = nv == -999999f ? -888888f : -999999f;
                return Float.compare(prefs.getFloat(key, sentinel), nv) == 0;
            }
            if (expectedValue instanceof String) {
                String nv = (String) expectedValue;
                String sentinel = nv.isEmpty() ? "\u0000__marco_absent__" : "";
                return nv.equals(prefs.getString(key, sentinel));
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static void recordPrefChangeIfDifferent(
            java.util.List<PrefChangeExpectation> changed,
            android.content.SharedPreferences prefs,
            String key,
            Object newValue) {
        if (changed == null || prefs == null || key == null || newValue == null) return;
        if (!prefCurrentlyMatches(prefs, key, newValue)) {
            changed.add(new PrefChangeExpectation(key, newValue));
        }
    }

    private static boolean anyPrefChangeVisible(
            android.content.SharedPreferences prefs,
            java.util.List<PrefChangeExpectation> changed) {
        if (prefs == null || changed == null || changed.isEmpty()) return false;
        for (int i = 0; i < changed.size(); i++) {
            PrefChangeExpectation item = changed.get(i);
            if (prefCurrentlyMatches(prefs, item.key, item.expectedValue)) {
                return true;
            }
        }
        return false;
    }

    static void applyRestorablePrefsSnapshot(
            android.content.SharedPreferences prefs,
            org.json.JSONObject settings,
            boolean syncCommit)
            throws IOException {
        applyRestorablePrefsSnapshot(prefs, settings, syncCommit, null);
    }

    static void applyRestorablePrefsSnapshot(
            android.content.SharedPreferences prefs,
            org.json.JSONObject settings,
            boolean syncCommit,
            ConfigLibrary.RestoreTransaction tx)
            throws IOException {
        if (settings == null || prefs == null) return;
        android.content.SharedPreferences.Editor edit;
        try {
            edit = prefs.edit();
        } catch (NullPointerException npe) {
            if (!hasAnyRestorablePrefKey(settings)) return;
            throw npe;
        }
        if (edit == null) return;
        java.util.List<PrefChangeExpectation> changed =
                tx != null ? new java.util.ArrayList<PrefChangeExpectation>() : null;
        for (String key : KEYS) {
            Object clean = Prefs.sanitizeSetting(key, settings.opt(key));
            if (clean instanceof Boolean) {
                edit.putBoolean(key, (Boolean) clean);
                recordPrefChangeIfDifferent(changed, prefs, key, clean);
            } else if (clean instanceof Float) {
                edit.putFloat(key, (Float) clean);
                recordPrefChangeIfDifferent(changed, prefs, key, clean);
            } else if (clean instanceof Integer) {
                edit.putInt(key, (Integer) clean);
                recordPrefChangeIfDifferent(changed, prefs, key, clean);
            }
        }
        for (String dataKey : RESTORE_DATA_KEYS) {
            if (settings.has(dataKey)) {
                String cleanData = Prefs.sanitizeUserData(dataKey, settings.opt(dataKey));
                if (cleanData != null) {
                    edit.putString(dataKey, cleanData);
                    recordPrefChangeIfDifferent(changed, prefs, dataKey, cleanData);
                }
            }
        }
        String validatedHistory = null;
        if (settings.has(Prefs.WATCH_HISTORY) && !settings.isNull(Prefs.WATCH_HISTORY)) {
            validatedHistory = WatchHistory.validateBackupJson(settings.opt(Prefs.WATCH_HISTORY));
            if (validatedHistory == null) {
                AppLog.w(
                        "WatchHistory",
                        "Rejected malformed watch_history during backup restore",
                        null);
            }
        }
        synchronized (WatchHistory.PERSISTENCE_LOCK) {
            if (validatedHistory != null || settings.has(Prefs.FAVORITES)) {
                WatchHistory.bumpRestoreEpoch();
            }
            if (validatedHistory != null) {
                WatchHistory.setCorrupted(false);
                edit.putString(Prefs.WATCH_HISTORY, validatedHistory);
                edit.putBoolean(WatchHistory.CORRUPTED_PREF, false);
                recordPrefChangeIfDifferent(changed, prefs, Prefs.WATCH_HISTORY, validatedHistory);
            }
            String commitTxId =
                    (tx != null && tx.txId != null && !tx.txId.isEmpty())
                            ? tx.txId
                            : settings.optString(ConfigLibrary.RESTORE_TX_META_KEY, "");
            if (commitTxId != null && !commitTxId.isEmpty()) {
                edit.putString(ConfigLibrary.RESTORE_TX_APPLIED_ID_PREF, commitTxId);
            }
            if (tx != null && changed != null && !changed.isEmpty()) {
                final java.util.List<PrefChangeExpectation> snapshot =
                        new java.util.ArrayList<>(changed);
                tx.setPrefsVisibilityProbe(() -> anyPrefChangeVisible(prefs, snapshot));
            }
            boolean persisted = false;
            try {
                if (syncCommit) {
                    if (!edit.commit()) {
                        throw new IOException("写入偏好与观看历史失败，已回滚原数据");
                    }
                } else {
                    edit.apply();
                }
                persisted = true;
            } finally {
                if (!persisted && tx != null) {
                    tx.setPrefsVisibilityProbe(null);
                    tx.setPrefsVisible(false);
                }
            }
        }
    }

    /**
     * Thread-safe preference + watch-history persistence invoked inside Stage 2 while the file WAL
     * is still armed. Any exception thrown by {@code SharedPreferences.Editor} propagates to
     * trigger full WAL rollback so file targets and preferences never diverge.
     */
    static void restoreSettingsPreferencesOnly(MainActivity a, org.json.JSONObject settings)
            throws IOException {
        restoreSettingsPreferencesOnly(a, settings, null);
    }

    static void restoreSettingsPreferencesOnly(
            MainActivity a, org.json.JSONObject settings, ConfigLibrary.RestoreTransaction tx)
            throws IOException {
        if (settings == null || a == null || a.prefs == null) return;
        applyRestorablePrefsSnapshot(a.prefs, settings, a.ui != null, tx);
    }

    static void restoreSettings(MainActivity a, org.json.JSONObject settings) {
        try {
            restoreSettingsPreferencesOnly(a, settings);
        } catch (IOException e) {
            AppLog.w("Settings", "restoreSettings failed", e);
        }
        if (a != null) {
            a.invalidateWatchHistoryCache();
            CatalogScreen.invalidateTvHistoryHost(a);
            if (settings != null
                    && settings.has(Prefs.WATCH_HISTORY)
                    && !settings.isNull(Prefs.WATCH_HISTORY)
                    && WatchHistory.validateBackupJson(settings.opt(Prefs.WATCH_HISTORY)) == null
                    && a.ui != null) {
                a.notice("备份中的观看历史格式错误，未能恢复观看历史。");
            }
            if (a.prefs != null) {
                a.reduced = a.prefs.getBoolean(Prefs.REDUCED, false);
            }
        }
    }
}

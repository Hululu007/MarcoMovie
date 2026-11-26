package com.pilipala.marcomovie;

import android.graphics.Typeface;
import android.os.Build;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;
import java.util.Locale;

/**
 * Redesigned Mobile Library Page ({@code 片库}, Day/Night {@link MobileTheme} + {@link MobileIcons}
 * + {@link MobileMotion}):
 * - Spring-sliding 4-way {@link MobileSectionGroup#segmentedControl}: {@code 历史 · 收藏 · 追剧 · 离线}
 * - Top-right 1-tap vector Cloud Sync status capsule (WebDAV & LAN sync)
 * - Clean borderless Inset Grouped {@code bgCard} lists with {@code 0.5dp} inset hairline dividers,
 *   {@link MobileBottomSheet#showConfirm} destructive guards, and 1-tap empty-state CTAs.
 */
final class MobileLibraryPage {
    private static int selectedWeekday = 0;

    private MobileLibraryPage() {}

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        if (selectedWeekday <= 0) selectedWeekday = TrackingRatingService.todayWeekday();

        LinearLayout page = a.vertical();
        page.setPadding(a.dp(16), a.statusBarHeight() + a.dp(10), a.dp(16), 0);
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        // 1. Header Row: Title + Vector Cloud Sync Pill
        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text("我的片库", 22, p.textPrimary);
        title.setTypeface(null, Typeface.BOLD);
        topRow.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        LinearLayout syncPill = a.row();
        syncPill.setGravity(Gravity.CENTER_VERTICAL);
        syncPill.setPadding(a.dp(12), a.dp(7), a.dp(13), a.dp(7));
        syncPill.setBackground(MobileTheme.cardBg(a, 999));
        if (!p.isDark) UiCompat.setElevation(syncPill, a.dp(2f));

        MobileIcons.IconView cloudIcon =
                MobileIcons.create(a, MobileIcons.IC_CLOUD_SYNC, 15f, p.accent);
        LinearLayout.LayoutParams ciLp = new LinearLayout.LayoutParams(a.dp(15), a.dp(15));
        ciLp.rightMargin = a.dp(6);
        syncPill.addView(cloudIcon, ciLp);

        TextView syncLbl = a.text("云同步", 12.5f, p.accent);
        syncLbl.setTypeface(null, Typeface.BOLD);
        syncPill.addView(syncLbl);

        MobileMotion.bindPress(syncPill, 0.94f);
        topRow.addView(syncPill);
        page.addView(topRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(page, 12);

        // 2. Spring-Sliding 4-Way Segmented Sub-Tab Bar (preserves "my-downloads" tag on tab 3)
        final String[] subNames = {"历史", "收藏", "追剧", "离线"};
        final String[] subTags = {null, null, null, "my-downloads"};
        final ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setFillViewport(true);
        shell.bindScrollBehavior(sv);
        final LinearLayout listBody = a.vertical();
        listBody.setPadding(0, a.dp(2), 0, a.navigationBarHeight() + a.dp(106));
        sv.addView(listBody, new ScrollView.LayoutParams(-1, -2));

        final int[] lastRenderedSub = {-1};
        final Runnable refreshSubTab =
                new Runnable() {
                    @Override
                    public void run() {
                        int cur = MobileRootShell.librarySubTab;
                        int prev = lastRenderedSub[0];
                        lastRenderedSub[0] = cur;
                        listBody.removeAllViews();
                        if (cur == 0) {
                            renderHistoryList(a, listBody, this);
                        } else if (cur == 1) {
                            renderFavoritesList(a, listBody, this);
                        } else if (cur == 2) {
                            renderFollowCalendar(a, listBody);
                        } else {
                            MobileDownloads.render(a, listBody);
                        }
                        if (prev >= 0 && prev != cur) {
                            sv.scrollTo(0, 0);
                            MobileMotion.animatePageSwap(listBody, cur > prev ? 1 : -1, 10f);
                        }
                    }
                };

        LinearLayout segBar =
                MobileSectionGroup.segmentedControl(
                        a,
                        subNames,
                        subTags,
                        MobileRootShell.librarySubTab,
                        idx -> {
                            MobileRootShell.librarySubTab = idx;
                            refreshSubTab.run();
                        });
        page.addView(segBar, new LinearLayout.LayoutParams(-1, -2));
        a.gap(page, 12);
        page.addView(sv, new LinearLayout.LayoutParams(-1, 0, 1f));

        syncPill.setOnClickListener(v -> CloudSyncDialog.show(a, refreshSubTab));

        refreshSubTab.run();
    }

    private static LinearLayout createGroupedListCard(MainActivity a, MobileTheme.Palette p) {
        LinearLayout card = a.vertical();
        card.setBackground(MobileTheme.cardBg(a, 16));
        if (Build.VERSION.SDK_INT >= 21) {
            card.setOutlineProvider(ViewOutlineProvider.BACKGROUND);
            UiCompat.setClipToOutline(card, true);
        }
        if (!p.isDark) UiCompat.setElevation(card, a.dp(1.5f));
        return card;
    }

    private static void addInsetDivider(
            MainActivity a, LinearLayout card, MobileTheme.Palette p, int leftInsetDp) {
        View divider = new View(a);
        divider.setBackgroundColor(p.hairline);
        LinearLayout.LayoutParams dlp =
                new LinearLayout.LayoutParams(-1, MobileTheme.hairlinePx(a));
        dlp.leftMargin = a.dp(leftInsetDp);
        card.addView(divider, dlp);
    }

    private static void renderEmptyState(
            MainActivity a,
            LinearLayout parent,
            int iconId,
            int badgeTint,
            String headline,
            String subtitle,
            String ctaLabel,
            Runnable onCta) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout box = a.vertical();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(a.dp(24), a.dp(52), a.dp(24), a.dp(48));

        FrameLayout badge = MobileIcons.badge(a, iconId, badgeTint, 50, 24);
        box.addView(badge, new LinearLayout.LayoutParams(a.dp(50), a.dp(50)));
        a.gap(box, 14);

        TextView head = a.text(headline, 15.5f, p.textPrimary);
        head.setTypeface(null, Typeface.BOLD);
        head.setGravity(Gravity.CENTER);
        box.addView(head);

        if (subtitle != null && !subtitle.isEmpty()) {
            a.gap(box, 6);
            TextView sub = a.text(subtitle, 13f, p.textSecondary);
            sub.setGravity(Gravity.CENTER);
            sub.setLineSpacing(0, 1.35f);
            box.addView(sub);
        }
        if (ctaLabel != null && !ctaLabel.isEmpty() && onCta != null) {
            a.gap(box, 18);
            TextView cta = a.text(ctaLabel, 13.5f, p.accentOnFill);
            cta.setTypeface(null, Typeface.BOLD);
            cta.setGravity(Gravity.CENTER);
            cta.setPadding(a.dp(22), a.dp(10), a.dp(22), a.dp(10));
            cta.setBackground(MobileTheme.accentPillBg(a, 999));
            MobileMotion.bindPress(cta, 0.94f);
            cta.setOnClickListener(v -> onCta.run());
            box.addView(cta, new LinearLayout.LayoutParams(-2, -2));
        }
        parent.addView(box, new LinearLayout.LayoutParams(-1, -2));
    }

    private static void renderHistoryList(
            final MainActivity a, LinearLayout parent, final Runnable reload) {
        MobileTheme.Palette p = MobileTheme.of(a);
        List<WatchHistory.Entry> items = a.watchHistory();
        if (items.isEmpty()) {
            renderEmptyState(
                    a,
                    parent,
                    MobileIcons.IC_HISTORY,
                    p.accent,
                    "暂无观看历史",
                    "播放影片后将自动记录进度，随时接着看",
                    "去发现影片",
                    () -> MobileRootShell.openTab(a, MobileRootShell.TAB_HOME));
            return;
        }
        LinearLayout bar = a.row();
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(a.dp(4), 0, a.dp(4), a.dp(10));
        bar.addView(
                a.text("共 " + items.size() + " 条记录 · 点击续播", 12.5f, p.textSecondary),
                new LinearLayout.LayoutParams(0, -2, 1f));

        LinearLayout clearAll = a.row();
        clearAll.setGravity(Gravity.CENTER_VERTICAL);
        clearAll.setPadding(a.dp(8), a.dp(4), a.dp(4), a.dp(4));
        MobileIcons.IconView trashIc = MobileIcons.create(a, MobileIcons.IC_TRASH, 13f, p.danger);
        LinearLayout.LayoutParams tiLp = new LinearLayout.LayoutParams(a.dp(13), a.dp(13));
        tiLp.rightMargin = a.dp(4);
        clearAll.addView(trashIc, tiLp);
        TextView clearLbl = a.text("清空全部", 12.5f, p.danger);
        clearLbl.setTypeface(null, Typeface.BOLD);
        clearAll.addView(clearLbl);
        MobileMotion.bindPress(clearAll, 0.94f);
        clearAll.setOnClickListener(
                v ->
                        MobileBottomSheet.showConfirm(
                                a,
                                "清空观看历史？",
                                "此操作将移除本机全部观看进度记录（不会影响已收藏影片）。",
                                "清空全部",
                                true,
                                () -> CloudSyncDialog.clearHistoryWithTombstone(a, reload)));
        bar.addView(clearAll);
        parent.addView(bar);

        LinearLayout groupCard = createGroupedListCard(a, p);
        for (int i = 0; i < items.size(); i++) {
            final WatchHistory.Entry e = items.get(i);
            if (i > 0) addInsetDivider(a, groupCard, p, 76);

            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(12), a.dp(11), a.dp(12), a.dp(11));
            MobileSectionGroup.bindPressHighlight(row, p.bgPressed);
            Runnable confirmRemoveHistory =
                    () ->
                            MobileBottomSheet.showConfirm(
                                    a,
                                    "移除观看记录？",
                                    "将从观看历史中移除《" + e.title + "》的播放进度。",
                                    "确认移除",
                                    true,
                                    () ->
                                            CloudSyncDialog.removeHistoryWithTombstone(
                                                    a, e.key(), reload));
            row.setOnClickListener(v -> a.resumeHistory(e));
            row.setOnLongClickListener(
                    v -> {
                        confirmRemoveHistory.run();
                        return true;
                    });

            ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(MobileTheme.subtleBg(a, 10));
            pic.setClipToOutline(true);
            if (e.poster != null && !e.poster.isEmpty()) a.poster(e.poster, pic);
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(52), a.dp(74));
            pLp.rightMargin = a.dp(12);
            row.addView(pic, pLp);

            LinearLayout info = a.vertical();
            TextView t = a.text(e.title, 14.5f, p.textPrimary);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(t);

            TextView sub =
                    a.text(MobileHomePage.formatCleanHistorySubtitle(a, e), 12f, p.textSecondary);
            sub.setSingleLine(true);
            sub.setEllipsize(TextUtils.TruncateAt.END);
            sub.setPadding(0, a.dp(4), 0, 0);
            info.addView(sub);
            row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

            FrameLayout delBtn = new FrameLayout(a);
            delBtn.setBackground(MobileTheme.subtleBg(a, 999));
            MobileIcons.IconView delIcon =
                    MobileIcons.create(a, MobileIcons.IC_TRASH, 15f, p.danger);
            delBtn.addView(
                    delIcon, new FrameLayout.LayoutParams(a.dp(15), a.dp(15), Gravity.CENTER));
            MobileMotion.bindPress(delBtn, 0.90f);
            delBtn.setOnClickListener(v -> confirmRemoveHistory.run());
            LinearLayout.LayoutParams dLp = new LinearLayout.LayoutParams(a.dp(32), a.dp(32));
            dLp.leftMargin = a.dp(10);
            row.addView(delBtn, dLp);

            groupCard.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }
        parent.addView(groupCard, new LinearLayout.LayoutParams(-1, -2));
    }

    private static void renderFavoritesList(
            final MainActivity a, LinearLayout parent, final Runnable reload) {
        MobileTheme.Palette p = MobileTheme.of(a);
        List<Favorites.Entry> favs = Favorites.read(a.prefs.getString(Prefs.FAVORITES, "[]"));
        if (favs.isEmpty()) {
            renderEmptyState(
                    a,
                    parent,
                    MobileIcons.IC_HEART,
                    p.danger,
                    "暂无收藏影片",
                    "看到喜欢的影视作品，点一下详情页右上角爱心即可收藏",
                    "去发现影片",
                    () -> MobileRootShell.openTab(a, MobileRootShell.TAB_HOME));
            return;
        }

        LinearLayout groupCard = createGroupedListCard(a, p);
        for (int i = 0; i < favs.size(); i++) {
            final Favorites.Entry f = favs.get(i);
            if (i > 0) addInsetDivider(a, groupCard, p, 76);

            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(12), a.dp(11), a.dp(12), a.dp(11));
            MobileSectionGroup.bindPressHighlight(row, p.bgPressed);
            Runnable confirmRemoveFavorite =
                    () ->
                            MobileBottomSheet.showConfirm(
                                    a,
                                    "取消收藏影片？",
                                    "将把《" + f.title + "》移出收藏列表。",
                                    "取消收藏",
                                    true,
                                    () ->
                                            CloudSyncDialog.removeFavoriteWithTombstone(
                                                    a, f.site, f.id, reload));
            final ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(MobileTheme.subtleBg(a, 10));
            pic.setClipToOutline(true);
            if (f.poster != null && !f.poster.isEmpty()) a.poster(f.poster, pic);

            row.setOnClickListener(
                    v -> {
                        Cms.Site targetSite = null;
                        if (a.config != null) {
                            for (Cms.Site s : a.config.sites) {
                                if (s.key.equals(f.site)) {
                                    targetSite = s;
                                    break;
                                }
                            }
                        }
                        if (targetSite == null) {
                            MobileRootShell.openSearch(a, f.title);
                            return;
                        }
                        final Cms.Site resolvedSite = targetSite;
                        final Cms.Video vid = f.video();
                        MobilePosterTransition.openDetailFromCard(
                                a, resolvedSite, vid, pic, 10f, false);
                    });
            row.setOnLongClickListener(
                    v -> {
                        confirmRemoveFavorite.run();
                        return true;
                    });

            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(52), a.dp(74));
            pLp.rightMargin = a.dp(12);
            row.addView(pic, pLp);

            LinearLayout info = a.vertical();
            TextView t = a.text(f.title, 14.5f, p.textPrimary);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(t);

            String siteDisplay = f.site;
            if (a.config != null) {
                for (Cms.Site s : a.config.sites) {
                    if (s.key.equals(f.site)) {
                        siteDisplay = s.name;
                        break;
                    }
                }
            }
            TextView sub = a.text("来源：" + siteDisplay, 12f, p.textSecondary);
            sub.setSingleLine(true);
            sub.setEllipsize(TextUtils.TruncateAt.END);
            sub.setPadding(0, a.dp(4), 0, 0);
            info.addView(sub);
            row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

            FrameLayout removeBtn = new FrameLayout(a);
            removeBtn.setBackground(MobileTheme.subtleBg(a, 999));
            MobileIcons.IconView heartIcon =
                    MobileIcons.create(a, MobileIcons.IC_HEART_FILLED, 15f, p.danger);
            removeBtn.addView(
                    heartIcon, new FrameLayout.LayoutParams(a.dp(15), a.dp(15), Gravity.CENTER));
            MobileMotion.bindPress(removeBtn, 0.90f);
            removeBtn.setOnClickListener(v -> confirmRemoveFavorite.run());
            LinearLayout.LayoutParams dLp = new LinearLayout.LayoutParams(a.dp(32), a.dp(32));
            dLp.leftMargin = a.dp(10);
            row.addView(removeBtn, dLp);

            groupCard.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }
        parent.addView(groupCard, new LinearLayout.LayoutParams(-1, -2));
    }

    private static void renderFollowCalendar(final MainActivity a, final LinearLayout parent) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        final String[] dayLabels = {"周一", "周二", "周三", "周四", "周五", "周六", "周日"};
        HorizontalScrollView dayHsv = new HorizontalScrollView(a);
        dayHsv.setHorizontalScrollBarEnabled(false);
        final LinearLayout dayRow = a.row();
        dayHsv.addView(dayRow);
        parent.addView(dayHsv, new LinearLayout.LayoutParams(-1, -2));
        a.gap(parent, 12);

        final LinearLayout itemsBox = a.vertical();
        parent.addView(itemsBox, new LinearLayout.LayoutParams(-1, -2));
        itemsBox.addView(a.text("正在加载追剧日历…", 13f, p.textSecondary));

        TrackingRatingService.fetchFollowCalendarAsync(
                a,
                entries -> {
                    final Runnable renderDay =
                            new Runnable() {
                                @Override
                                public void run() {
                                    dayRow.removeAllViews();
                                    for (int d = 1; d <= 7; d++) {
                                        final int dayNum = d;
                                        boolean sel = (d == selectedWeekday);
                                        TextView pill =
                                                a.text(
                                                        dayLabels[d - 1],
                                                        12.5f,
                                                        sel ? p.accent : p.textSecondary);
                                        pill.setTypeface(
                                                null, sel ? Typeface.BOLD : Typeface.NORMAL);
                                        pill.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
                                        pill.setBackground(MobileTheme.pillBg(a, sel, 999));
                                        MobileMotion.bindPress(pill, 0.94f);
                                        pill.setOnClickListener(
                                                v -> {
                                                    selectedWeekday = dayNum;
                                                    run();
                                                });
                                        LinearLayout.LayoutParams lp =
                                                new LinearLayout.LayoutParams(-2, -2);
                                        lp.rightMargin = a.dp(7);
                                        dayRow.addView(pill, lp);
                                    }

                                    itemsBox.removeAllViews();
                                    if (entries == null || entries.isEmpty()) {
                                        renderEmptyState(
                                                a,
                                                itemsBox,
                                                MobileIcons.IC_STAR,
                                                p.warning,
                                                "未能加载追剧日历",
                                                "请检查网络连接，或绑定追剧账号同步个人在看列表",
                                                "同步追剧进度",
                                                () -> {
                                                    MobileRootShell.settingsSubPage = 5;
                                                    MobileRootShell.openTab(
                                                            a, MobileRootShell.TAB_SETTINGS);
                                                });
                                        return;
                                    }
                                    LinearLayout groupCard = createGroupedListCard(a, p);
                                    int shown = 0;
                                    for (final TrackingRatingService.CalendarEntry ce : entries) {
                                        if (ce.weekday != selectedWeekday) continue;
                                        if (shown > 0) addInsetDivider(a, groupCard, p, 74);
                                        shown++;

                                        LinearLayout row = a.row();
                                        row.setGravity(Gravity.CENTER_VERTICAL);
                                        row.setPadding(a.dp(12), a.dp(11), a.dp(12), a.dp(11));
                                        MobileSectionGroup.bindPressHighlight(row, p.bgPressed);
                                        row.setOnClickListener(
                                                v -> MobileRootShell.openSearch(a, ce.title));

                                        ImageView pic = new ImageView(a);
                                        pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
                                        pic.setBackground(MobileTheme.subtleBg(a, 10));
                                        pic.setClipToOutline(true);
                                        if (ce.posterUrl != null && !ce.posterUrl.isEmpty()) {
                                            a.poster(ce.posterUrl, pic);
                                        }
                                        LinearLayout.LayoutParams pLp =
                                                new LinearLayout.LayoutParams(a.dp(50), a.dp(70));
                                        pLp.rightMargin = a.dp(12);
                                        row.addView(pic, pLp);

                                        LinearLayout info = a.vertical();
                                        TextView t = a.text(ce.title, 14.5f, p.textPrimary);
                                        t.setTypeface(null, Typeface.BOLD);
                                        t.setSingleLine(true);
                                        t.setEllipsize(TextUtils.TruncateAt.END);
                                        info.addView(t);

                                        String meta =
                                                ce.sourceBadge
                                                        + (ce.subtitle.isEmpty()
                                                                ? ""
                                                                : (" · " + ce.subtitle))
                                                        + (ce.rating > 0
                                                                ? String.format(
                                                                        Locale.US,
                                                                        " · %.1f 分",
                                                                        ce.rating)
                                                                : "");
                                        TextView sub = a.text(meta, 12f, p.accent);
                                        sub.setSingleLine(true);
                                        sub.setEllipsize(TextUtils.TruncateAt.END);
                                        sub.setPadding(0, a.dp(4), 0, 0);
                                        info.addView(sub);
                                        row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

                                        TextView searchTag = a.text("搜源", 12f, p.textSecondary);
                                        LinearLayout.LayoutParams stLp =
                                                new LinearLayout.LayoutParams(-2, -2);
                                        stLp.leftMargin = a.dp(8);
                                        stLp.rightMargin = a.dp(4);
                                        row.addView(searchTag, stLp);

                                        MobileIcons.IconView chev =
                                                MobileIcons.create(
                                                        a,
                                                        MobileIcons.IC_CHEVRON_RIGHT,
                                                        13f,
                                                        p.textTertiary);
                                        row.addView(
                                                chev,
                                                new LinearLayout.LayoutParams(a.dp(13), a.dp(13)));

                                        groupCard.addView(
                                                row, new LinearLayout.LayoutParams(-1, -2));
                                    }
                                    if (shown == 0) {
                                        renderEmptyState(
                                                a,
                                                itemsBox,
                                                MobileIcons.IC_STAR,
                                                p.accent,
                                                "当日暂无更新番剧记录",
                                                "可切换其他星期查看排期",
                                                null,
                                                null);
                                    } else {
                                        itemsBox.addView(
                                                groupCard, new LinearLayout.LayoutParams(-1, -2));
                                    }
                                }
                            };
                    renderDay.run();
                });
    }
}

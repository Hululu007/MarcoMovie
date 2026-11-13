package com.pilipala.marcomovie;

import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.List;

/**
 * Category listing, paginated video grid browsing, and watch history management extracted from
 * {@link MainActivity}.
 */
final class CatalogScreen {
    private CatalogScreen() {}

    /** Visible back entry so remote and touch users can always leave a library page. */
    static void addBack(MainActivity a, String tag) {
        a.body.addView(
                a.navButton("‹ 返回", tag, a::onBackPressed),
                new LinearLayout.LayoutParams(a.dp(82), a.dp(32)));
        a.gap(a.body, 8);
    }

    static void categories(MainActivity a, Cms.Site s) {
        a.prefs.edit().putString(Prefs.SELECTED_SITE, s.key).apply();
        a.renderPage(s.name, "CHOOSE A CATEGORY");
        addBack(a, "catalog-back");
        LinearLayout actions = a.row();
        a.addButton(actions, a.button("全局搜索", "search", a::globalSearchDialog));
        a.addButton(
                actions,
                a.button(
                        "最新内容",
                        "latest",
                        () ->
                                a.open(
                                        new MainActivity.Screen(
                                                () -> videos(a, s, "", "最新内容", 1, null)),
                                        true)));
        a.body.addView(actions);
        a.load(
                "正在读取分类…",
                () -> Cms.categories(a.engine(s).home()),
                cats -> {
                    if (cats.isEmpty()) {
                        a.paragraph("来源没有返回分类，可尝试“最新内容”或搜索。");
                        return;
                    }
                    for (Cms.Category c : cats)
                        a.addButton(
                                a.body,
                                a.button(
                                        c.name,
                                        "category:" + c.id,
                                        () ->
                                                a.open(
                                                        new MainActivity.Screen(
                                                                () ->
                                                                        videos(
                                                                                a, s, c.id, c.name,
                                                                                1, null)),
                                                        true)));
                });
    }

    static void videos(
            MainActivity a, Cms.Site s, String cat, String title, int page, String search) {
        a.renderPage(title, "EXPLORE THE LIBRARY");
        addBack(a, "catalog-back");
        a.paragraph(s.name + " · 第 " + page + " 页");
        a.load(
                "正在读取影片…",
                () -> {
                    SourceEngine selected = a.engine(s);
                    return Cms.listing(
                            search != null
                                    ? selected.search(search, page)
                                    : selected.category(cat, page));
                },
                list -> {
                    if (list.videos.isEmpty()) a.paragraph("这一页没有影片。");
                    int cols =
                            TvLayoutPolicy.catalogColumns(
                                    a.windowWidth() / a.getResources().getDisplayMetrics().density,
                                    a.formFactor,
                                    a.isPortrait());
                    LinearLayout cards = null;
                    for (int i = 0; i < list.videos.size(); i++) {
                        if (i % cols == 0) {
                            cards = a.row();
                            cards.setGravity(Gravity.TOP);
                            cards.setClipChildren(false);
                            cards.setClipToPadding(false);
                            a.body.addView(cards);
                        }
                        Cms.Video v = list.videos.get(i);
                        LinearLayout card = a.vertical();
                        card.setPadding(a.dp(5), a.dp(5), a.dp(5), a.dp(10));
                        card.setClipChildren(false);
                        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, -2, 1);
                        lp.setMargins(a.dp(5), a.dp(5), a.dp(14), a.dp(19));
                        cards.addView(card, lp);
                        FrameLayout art = new FrameLayout(a);
                        art.setBackground(
                                new GradientDrawable(
                                        GradientDrawable.Orientation.TL_BR,
                                        new int[] {0xff304c70, 0xff141c2c}));
                        ImageView img = new ImageView(a);
                        img.setScaleType(ImageView.ScaleType.CENTER_CROP);
                        art.addView(img, new FrameLayout.LayoutParams(-1, -1));
                        card.addView(art, new LinearLayout.LayoutParams(-1, a.dp(185)));
                        a.poster(v.poster, img);
                        TextView label = a.text(v.title, 16, MainActivity.WHITE);
                        label.setPadding(a.dp(5), a.dp(10), a.dp(5), 0);
                        label.setLines(2);
                        label.setEllipsize(TextUtils.TruncateAt.END);
                        card.addView(label);
                        TextView remark = a.text(v.remarks, 12, MainActivity.MUTED);
                        remark.setMaxLines(1);
                        remark.setEllipsize(TextUtils.TruncateAt.END);
                        card.addView(remark);
                        card.setFocusable(a.isTvDevice());
                        card.setFocusableInTouchMode(a.isTvDevice());
                        card.setClickable(true);
                        card.setTag(i == 0 ? "primary" : "video:" + v.id);
                        card.setOnClickListener(view -> a.openListing(s, v));
                        card.setOnFocusChangeListener(
                                (view, focus) ->
                                        FocusMotion.style(
                                                a,
                                                card,
                                                focus,
                                                0x00101c30,
                                                0xff435c7c,
                                                10,
                                                MainActivity.WHITE,
                                                MainActivity.WHITE,
                                                true,
                                                1.035f));
                    }
                    if (cards != null) {
                        int remainder = list.videos.size() % cols;
                        if (remainder > 0)
                            for (int i = remainder; i < cols; i++) {
                                LinearLayout.LayoutParams blank =
                                        new LinearLayout.LayoutParams(0, 1, 1);
                                blank.setMargins(a.dp(5), a.dp(5), a.dp(14), a.dp(19));
                                cards.addView(new View(a), blank);
                            }
                    }
                    LinearLayout paging = a.row();
                    if (page > 1)
                        a.addButton(
                                paging,
                                a.button(
                                        "上一页",
                                        "previous",
                                        () ->
                                                a.open(
                                                        new MainActivity.Screen(
                                                                () ->
                                                                        videos(
                                                                                a, s, cat, title,
                                                                                page - 1, search)),
                                                        false)));
                    if (page < list.pageCount)
                        a.addButton(
                                paging,
                                a.button(
                                        "下一页",
                                        "next",
                                        () ->
                                                a.open(
                                                        new MainActivity.Screen(
                                                                () ->
                                                                        videos(
                                                                                a, s, cat, title,
                                                                                page + 1, search)),
                                                        false)));
                    a.body.addView(paging);
                    a.restore(a.current);
                });
    }

    static String historyLabel(WatchHistory.Entry e) {
        return e.episode
                + " · "
                + (e.complete()
                        ? "已看完"
                        : PlaybackController.formatTime(e.position)
                                + (e.duration > 0
                                        ? " / " + PlaybackController.formatTime(e.duration)
                                        : ""));
    }

    static void resumeHistory(MainActivity a, WatchHistory.Entry e) {
        Cms.Site site = null;
        if (a.config != null) for (Cms.Site s : a.config.sites) if (s.key.equals(e.site)) site = s;
        if (site == null || !a.available(site)) {
            if (a.config != null && e.title != null && !e.title.trim().isEmpty()) {
                if (!a.isTvDevice()) {
                    a.toast("原片源不在当前订阅中，已自动全网搜索该影片");
                    a.openSearch(e.title);
                } else {
                    new AppDialog.Builder(a)
                            .setTitle("原片源不在当前订阅中")
                            .setMessage("这条观看记录来自其他设备或旧订阅源，是否在当前片库中全网搜索「" + e.title + "」？")
                            .setPositiveButton("全网搜索", (d, w) -> a.openSearch(e.title))
                            .setNegativeButton("保留记录", null)
                            .show();
                }
                return;
            }
            a.notice("这条记录的来源已不可用，记录仍保留在本机。");
            return;
        }
        final Cms.Site selected = site;
        Cms.Video listing = new Cms.Video();
        listing.id = e.id;
        listing.title = e.title;
        listing.poster = e.poster;
        a.open(new MainActivity.Screen(() -> a.detail(selected, listing)), true);
    }

    static void playBookmark(
            MainActivity a, Cms.Site site, Cms.Video video, WatchHistory.Entry bookmark) {
        Cms.Line line = null;
        for (Cms.Line candidate : video.lines)
            if (candidate.name.equals(bookmark.line)) {
                line = candidate;
                break;
            }
        if (line == null && !video.lines.isEmpty()) {
            line = video.lines.get(0);
        }
        Cms.Episode episode = null;
        if (line != null) {
            for (Cms.Episode candidate : line.episodes)
                if (candidate.name.equals(bookmark.episode)) {
                    episode = candidate;
                    break;
                }
            if (episode == null && bookmark.index >= 0 && bookmark.index < line.episodes.size()) {
                episode = line.episodes.get(bookmark.index);
            }
        }
        if (episode == null) {
            a.notice("上次的线路或集数已变更，请在下方重新选集。");
            return;
        }
        a.resumeAt = bookmark.resume();
        a.resolvePlayer(site, video, line, episode);
    }

    private static String historyProgressBadge(WatchHistory.Entry e) {
        if (e.complete()) return "已看完";
        if (e.duration > 0) {
            int pct = Math.max(1, Math.min(99, Math.round(e.position * 100f / e.duration)));
            return "已看 " + pct + "%";
        }
        if (e.position > 0) return "已看 " + PlaybackController.formatTime(e.position);
        return "刚刚观看";
    }

    private static String historyTimeSummary(WatchHistory.Entry e) {
        String ep = e.episode == null ? "" : e.episode.trim();
        if (e.complete()) return ep.isEmpty() ? "已看完" : ep + " · 已看完";
        if (e.duration > 0)
            return PlaybackController.formatTime(e.position)
                    + " / "
                    + PlaybackController.formatTime(e.duration);
        if (e.position > 0) return "观看至 " + PlaybackController.formatTime(e.position);
        return ep.isEmpty() ? "继续观看" : ep;
    }

    private static void confirmClearHistory(MainActivity a) {
        new AppDialog.Builder(a)
                .setTitle("清空观看历史？")
                .setMessage("只清除本机观看记录，保留配置和账号。")
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "清空",
                        (d, n) -> {
                            List<WatchHistory.Entry> prev = a.watchHistory();
                            a.clearWatchHistory();
                            CloudSyncDialog.onHistoryCleared(a, prev);
                            a.refresh();
                        })
                .show();
    }

    private static void manageHistoryEntry(MainActivity a, WatchHistory.Entry e) {
        new AppDialog.Builder(a)
                .setTitle(e.title == null || e.title.isEmpty() ? "观看记录" : e.title)
                .setItems(
                        new String[] {"继续观看", "移除此记录"},
                        (d, n) -> {
                            if (n == 0) resumeHistory(a, e);
                            else {
                                a.prefs
                                        .edit()
                                        .putString(
                                                Prefs.WATCH_HISTORY,
                                                WatchHistory.remove(
                                                        a.prefs.getString(
                                                                Prefs.WATCH_HISTORY, "[]"),
                                                        e.key()))
                                        .apply();
                                CloudSyncDialog.onHistoryDeleted(a, e.key());
                                a.refresh();
                            }
                        })
                .setNegativeButton("返回", null)
                .show();
    }

    static void historyPage(MainActivity a) {
        a.renderPage("观看历史", "CONTINUE WATCHING");
        List<WatchHistory.Entry> entries = a.watchHistory();
        if (entries.isEmpty()) {
            boolean corrupted =
                    WatchHistory.isCorrupted()
                            || a.prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false);
            a.paragraph(corrupted ? "观看历史数据异常，已暂停更新并保留本地损坏备份。可重置历史后恢复记录。" : "播放后会在这里记录集数和进度。");
            if (corrupted) {
                a.addButton(
                        a.body,
                        a.navButton(
                                "重置观看历史（保留损坏备份）",
                                "history-reset-corrupted",
                                () -> confirmClearHistory(a)));
            }
            if (!a.privateMode) {
                a.addButton(
                        a.body,
                        a.navButton(
                                "多端云同步",
                                "history-cloud-sync",
                                () -> CloudSyncDialog.show(a, a::refresh)));
            }
            return;
        }
        if (a.isTvDevice()) {
            LinearLayout topBar = a.row();
            topBar.setClipChildren(false);
            topBar.setClipToPadding(false);
            topBar.setGravity(Gravity.CENTER_VERTICAL);
            TextView summary =
                    a.text(entries.size() + " 部观看记录 · 确认继续观看，长按确认或按菜单键管理", 13, MainActivity.MUTED);
            topBar.addView(summary, new LinearLayout.LayoutParams(0, -2, 1));
            if (!a.privateMode) {
                Button syncBtn =
                        a.navButton(
                                "多端云同步",
                                "history-cloud-sync",
                                () -> CloudSyncDialog.show(a, a::refresh));
                LinearLayout.LayoutParams syncLp = new LinearLayout.LayoutParams(-2, a.dp(36));
                syncLp.rightMargin = a.dp(8);
                topBar.addView(syncBtn, syncLp);
            }
            Button clearBtn = a.navButton("清空观看历史", "history-clear", () -> confirmClearHistory(a));
            topBar.addView(clearBtn, new LinearLayout.LayoutParams(-2, a.dp(36)));
            a.body.addView(topBar, new LinearLayout.LayoutParams(-1, -2));
            a.gap(a.body, 10);

            float screen = a.windowWidth() / a.getResources().getDisplayMetrics().density;
            int columns = Math.max(4, Math.min(6, a.prefs.getInt(Prefs.HOME_COLUMNS, 6)));
            int width = Math.max(108, (int) ((screen - 92) / columns) - 20);
            int height = Math.round(width * 1.5f);
            LinearLayout row = null;
            for (int i = 0; i < entries.size(); i++) {
                final WatchHistory.Entry e = entries.get(i);
                if (i % columns == 0) {
                    row = a.row();
                    row.setGravity(Gravity.TOP);
                    row.setClipChildren(false);
                    row.setClipToPadding(false);
                    a.body.addView(row);
                }
                LinearLayout card = a.vertical();
                card.setPadding(a.dp(5), a.dp(5), a.dp(5), a.dp(8));
                card.setGravity(Gravity.CENTER_HORIZONTAL);
                card.setClipChildren(false);
                card.setClipToPadding(false);
                card.setId(View.generateViewId());
                card.setTag("history:" + e.key());
                card.setFocusable(true);
                card.setFocusableInTouchMode(true);
                card.setClickable(true);

                FrameLayout art = new FrameLayout(a);
                GradientDrawable artBg =
                        new GradientDrawable(
                                GradientDrawable.Orientation.TL_BR,
                                new int[] {0xff282d38, 0xff171a22});
                artBg.setCornerRadius(a.dp(10));
                art.setBackground(artBg);
                art.setClipToOutline(true);

                TextView fallback =
                        a.text(
                                e.title == null || e.title.isEmpty() ? "影片" : e.title,
                                13,
                                0x55ffffff);
                fallback.setGravity(Gravity.CENTER);
                fallback.setMaxLines(2);
                fallback.setEllipsize(TextUtils.TruncateAt.END);
                fallback.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(28));
                art.addView(fallback, new FrameLayout.LayoutParams(-1, -1));

                ImageView poster = new ImageView(a);
                poster.setScaleType(ImageView.ScaleType.CENTER_CROP);
                art.addView(poster, new FrameLayout.LayoutParams(-1, -1));
                a.poster(e.poster, poster);

                String ep = e.episode == null ? "" : e.episode.trim();
                if (!ep.isEmpty()) {
                    TextView epBadge = a.text(ep, 10.5f, 0xffedf1f7);
                    epBadge.setSingleLine(true);
                    epBadge.setEllipsize(TextUtils.TruncateAt.END);
                    epBadge.setMaxWidth(a.dp(Math.max(48, width - 16)));
                    epBadge.setPadding(a.dp(7), a.dp(2.5f), a.dp(7), a.dp(2.5f));
                    GradientDrawable badgeBg = new GradientDrawable();
                    badgeBg.setColor(0xd214171f);
                    badgeBg.setCornerRadius(a.dp(6));
                    badgeBg.setStroke(Math.max(1, a.dp(.8f)), 0x24ffffff);
                    epBadge.setBackground(badgeBg);
                    FrameLayout.LayoutParams bp =
                            new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
                    bp.setMargins(a.dp(6), a.dp(6), a.dp(6), 0);
                    art.addView(epBadge, bp);
                }

                LinearLayout overlay = a.vertical();
                overlay.setGravity(Gravity.BOTTOM);
                overlay.setPadding(a.dp(8), a.dp(14), a.dp(8), a.dp(7));
                GradientDrawable scrim =
                        new GradientDrawable(
                                GradientDrawable.Orientation.TOP_BOTTOM,
                                new int[] {0x00000000, 0xaa0e1016, 0xeb0b0d12});
                overlay.setBackground(scrim);

                TextView progLabel = a.text(historyProgressBadge(e), 10.5f, 0xfff3f5f9);
                progLabel.setTypeface(null, Typeface.BOLD);
                progLabel.setSingleLine(true);
                progLabel.setEllipsize(TextUtils.TruncateAt.END);
                overlay.addView(progLabel, new LinearLayout.LayoutParams(-1, -2));

                FrameLayout track = new FrameLayout(a);
                track.setBackground(a.bg(0x3affffff, 2));
                LinearLayout.LayoutParams tp = new LinearLayout.LayoutParams(-1, a.dp(3.5f));
                tp.topMargin = a.dp(4);
                float ratio =
                        e.complete()
                                ? 1f
                                : e.duration > 0
                                        ? Math.max(
                                                .04f, Math.min(1f, (float) e.position / e.duration))
                                        : (e.position > 0 ? .18f : 0f);
                if (ratio > 0f) {
                    View fill = new View(a);
                    fill.setBackground(a.bg(0xfff5f7fb, 2));
                    int barInnerPx = Math.max(a.dp(6), a.dp(width - 16));
                    int fillPx = Math.max(a.dp(4), Math.round(barInnerPx * ratio));
                    track.addView(fill, new FrameLayout.LayoutParams(fillPx, -1, Gravity.LEFT));
                }
                overlay.addView(track, tp);
                art.addView(overlay, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

                card.addView(art, new LinearLayout.LayoutParams(a.dp(width), a.dp(height)));

                TextView title =
                        a.text(
                                e.title == null || e.title.isEmpty() ? "未命名影片" : e.title,
                                13,
                                MainActivity.WHITE);
                title.setSingleLine(true);
                title.setEllipsize(TextUtils.TruncateAt.END);
                title.setPadding(a.dp(2), a.dp(8), a.dp(2), 0);
                card.addView(title, new LinearLayout.LayoutParams(-1, -2));

                TextView sub = a.text(historyTimeSummary(e), 11, MainActivity.MUTED);
                sub.setSingleLine(true);
                sub.setEllipsize(TextUtils.TruncateAt.END);
                sub.setPadding(a.dp(2), a.dp(2), a.dp(2), 0);
                card.addView(sub, new LinearLayout.LayoutParams(-1, -2));

                card.setOnClickListener(v -> resumeHistory(a, e));
                card.setOnLongClickListener(
                        v -> {
                            manageHistoryEntry(a, e);
                            return true;
                        });
                a.pressFeedback(card);
                card.setOnKeyListener(
                        (v, key, event) -> {
                            if (key == KeyEvent.KEYCODE_MENU) {
                                if (event.getAction() == KeyEvent.ACTION_UP)
                                    manageHistoryEntry(a, e);
                                return true;
                            }
                            return false;
                        });
                card.setOnFocusChangeListener(
                        (v, f) ->
                                FocusMotion.style(
                                        a,
                                        card,
                                        f,
                                        0,
                                        0xff29292f,
                                        14,
                                        MainActivity.WHITE,
                                        MainActivity.WHITE,
                                        true,
                                        1.035f));
                LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(0, -2, 1);
                size.setMargins(a.dp(4), a.dp(5), a.dp(4), a.dp(16));
                row.addView(card, size);
                if (i == 0 && a.current != null && a.current.focus == null)
                    a.ui.post(card::requestFocus);
            }
            if (row != null)
                for (int i = entries.size() % columns; i > 0 && i < columns; i++) {
                    LinearLayout.LayoutParams blank = new LinearLayout.LayoutParams(0, 1, 1);
                    blank.setMargins(a.dp(4), a.dp(5), a.dp(4), a.dp(16));
                    row.addView(new View(a), blank);
                }
            return;
        }
        LinearLayout topActions = a.row();
        if (!a.privateMode) {
            a.addButton(
                    topActions,
                    a.navButton(
                            "多端云同步",
                            "history-cloud-sync",
                            () -> CloudSyncDialog.show(a, a::refresh)));
        }
        a.addButton(
                topActions, a.navButton("清空观看历史", "history-clear", () -> confirmClearHistory(a)));
        a.body.addView(topActions);
        for (WatchHistory.Entry e : entries) {
            LinearLayout line = a.row();
            line.setClipChildren(false);
            line.setClipToPadding(false);
            line.setPadding(0, a.dp(6), 0, a.dp(6));
            Button item =
                    a.button(
                            e.title + " · " + historyLabel(e),
                            "history:" + e.key(),
                            () -> resumeHistory(a, e));
            item.setSingleLine(true);
            item.setEllipsize(TextUtils.TruncateAt.END);
            line.addView(item, new LinearLayout.LayoutParams(0, a.dp(52), 1));
            a.addButton(
                    line,
                    a.navButton(
                            "移除",
                            "history-remove:" + e.key(),
                            () -> {
                                a.prefs
                                        .edit()
                                        .putString(
                                                Prefs.WATCH_HISTORY,
                                                WatchHistory.remove(
                                                        a.prefs.getString(
                                                                Prefs.WATCH_HISTORY, "[]"),
                                                        e.key()))
                                        .apply();
                                CloudSyncDialog.onHistoryDeleted(a, e.key());
                                a.refresh();
                            }));
            a.body.addView(line);
            a.gap(a.body, 8);
        }
    }
}

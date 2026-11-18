package com.pilipala.marcomovie;

import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.graphics.Rect;
import android.widget.Button;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.List;

/** TV presentation. The host owns navigation and existing history/favorite storage. */
final class TvV17MineScreen {
    private final MainActivity a;

    TvV17MineScreen(MainActivity activity) { a = activity; }

    void show() {
        a.renderPage("我的", "");
        showActions();
        a.gap(a.body, 18);

        LinearLayout sections = a.row();
        sections.setGravity(Gravity.TOP);
        sections.setClipChildren(false);
        LinearLayout historySection = a.vertical();
        LinearLayout favoritesSection = a.vertical();
        LinearLayout.LayoutParams historySize = new LinearLayout.LayoutParams(0, -2, 1f);
        historySize.rightMargin = a.dp(28);
        sections.addView(historySection, historySize);
        sections.addView(favoritesSection, new LinearLayout.LayoutParams(0, -2, 1.1f));
        a.body.addView(sections);
        List<WatchHistory.Entry> history = a.watchHistory();
        boolean historyCorrupted = WatchHistory.isCorrupted()
                || a.prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false);
        historySection.addView(a.text("继续观看", 22, TvV17Theme.TEXT));
        a.gap(historySection, 8);
        if (historyCorrupted) {
            historySection.addView(a.text("观看记录数据损坏，已保留本地备份并暂停更新。请打开全部历史查看恢复选项。", 16, TvV17Theme.MUTED));
        } else if (history.isEmpty()) {
            historySection.addView(a.text("暂无观看记录", 16, TvV17Theme.MUTED));
        } else {
            WatchHistory.Entry entry = history.get(0);
            LinearLayout row = card(entry.poster, entry.title, CatalogScreen.historyLabel(entry),
                    "mine-history:" + entry.key(), 240);
            row.setOnClickListener(v -> a.resumeHistory(entry));
            // Existing history page owns deletion, sync notification and missing-source recovery.
            row.setOnLongClickListener(v -> { openHistory(); return true; });
            TvMenuAction.bind(row, this::openHistory);
            historySection.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }

        List<Favorites.Entry> favorites = Favorites.read(a.prefs.getString(Prefs.FAVORITES, "[]"));
        favoritesSection.addView(a.text("收藏 · " + favorites.size() + " 部", 22, TvV17Theme.TEXT));
        a.gap(favoritesSection, 8);
        if (favorites.isEmpty()) {
            favoritesSection.addView(a.text("暂无收藏", 16, TvV17Theme.MUTED));
            return;
        }
        LinearLayout cards = a.row();
        cards.setGravity(Gravity.TOP);
        FavoritesScreen handler = new FavoritesScreen(a);
        int count = Math.min(3, favorites.size());
        for (int i = 0; i < count; i++) {
            Favorites.Entry entry = favorites.get(i);
            LinearLayout item = card(entry.poster, entry.title, "", "mine-favorite:" + entry.key(), 180);
            item.setOnClickListener(v -> handler.open(entry));
            item.setOnLongClickListener(v -> { handler.manage(entry); return true; });
            TvMenuAction.bind(item, () -> handler.manage(entry));
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(0, -2, 1f);
            size.rightMargin = a.dp(16);
            cards.addView(item, size);
        }
        for (int i = count; i < 3; i++) {
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(0, 1, 1f);
            size.rightMargin = a.dp(16);
            cards.addView(new View(a), size);
        }
        favoritesSection.addView(cards);
    }

    private void openHistory() {
        a.open(new MainActivity.Screen(a::historyPage), true);
    }

    private void showActions() {
        HorizontalScrollView viewport = new HorizontalScrollView(a);
        viewport.setTag("mine-actions-viewport");
        viewport.setFocusable(false);
        viewport.setFillViewport(true);
        viewport.setHorizontalScrollBarEnabled(false);
        viewport.setClipToPadding(false);
        viewport.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(8));
        LinearLayout row = a.row();
        row.setTag("mine-actions");
        row.setClipChildren(false);
        Button[] buttons = {
            a.navButton("全部历史", "mine-history", this::openHistory),
            a.navButton("全部收藏", "mine-favorites",
                    () -> a.open(new MainActivity.Screen(() -> new FavoritesScreen(a).show()), true)),
            a.navButton("网盘与账号", "mine-accounts", () -> AccountPanel.show(a, null)),
            a.navButton("投屏", "mine-cast", () -> a.open(new MainActivity.Screen(a::castScreen), true)),
            a.navButton(a.privateMode ? "退出隐私空间" : "隐私空间", "mine-private", () -> PrivacySpace.openTv(a)),
            a.navButton("同步", "mine-sync", () -> CloudSyncDialog.show(a, null)),
            a.navButton("配置与设置", "mine-settings", () -> a.open(new MainActivity.Screen(a::settings), true))
        };
        int widest = a.dp(100);
        int height = a.dp(46);
        for (Button button : buttons) {
            button.setId(View.generateViewId());
            widest = Math.max(widest, (int) Math.ceil(button.getPaint().measureText(button.getText().toString()))
                    + button.getPaddingLeft() + button.getPaddingRight() + a.dp(4));
            height = Math.max(height, button.getLineHeight() + button.getPaddingTop() + button.getPaddingBottom() + a.dp(4));
        }
        final int minimum = widest, gap = a.dp(10);
        for (int i = 0; i < buttons.length; i++) {
            Button button = buttons[i];
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(minimum, height);
            if (i + 1 < buttons.length) size.rightMargin = gap;
            row.addView(button, size);
            if (i > 0) button.setNextFocusLeftId(buttons[i - 1].getId());
            if (i + 1 < buttons.length) button.setNextFocusRightId(buttons[i + 1].getId());
            View.OnFocusChangeListener styling = button.getOnFocusChangeListener();
            button.setOnFocusChangeListener((v, focused) -> {
                if (styling != null) styling.onFocusChange(v, focused);
                if (focused) viewport.post(() -> {
                    if (!button.hasFocus() || !viewport.isAttachedToWindow()) return;
                    Rect rect = new Rect(button.getLeft() - a.dp(3), 0,
                            button.getRight() + a.dp(3), row.getHeight());
                    viewport.requestChildRectangleOnScreen(row, rect, true);
                });
            });
        }
        viewport.addView(row, new HorizontalScrollView.LayoutParams(-2, -2));
        viewport.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
            int available = r - l - viewport.getPaddingLeft() - viewport.getPaddingRight();
            int width = TvMineActionMetrics.width(available, minimum, gap, buttons.length);
            for (Button button : buttons) {
                LinearLayout.LayoutParams size = (LinearLayout.LayoutParams) button.getLayoutParams();
                if (size.width != width) { size.width = width; button.setLayoutParams(size); }
            }
        });
        a.body.addView(viewport, new LinearLayout.LayoutParams(-1, -2));
    }

    private LinearLayout card(String poster, String title, String detail, String tag, int heightDp) {
        LinearLayout card = a.vertical();
        card.setTag(tag);
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);
        card.setClickable(true);
        card.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(8));
        ImageView art = new ImageView(a);
        TvV17PosterCard.artwork(a, art);
        card.addView(art, new LinearLayout.LayoutParams(-1, a.dp(heightDp)));
        a.poster(poster, art);
        TextView name = a.text(title == null ? "" : title, 16, TvV17Theme.TEXT);
        name.setSingleLine(true);
        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        card.addView(name);
        if (detail != null && !detail.isEmpty()) card.addView(a.text(detail, 12, TvV17Theme.MUTED));
        a.pressFeedback(card);
        card.setOnFocusChangeListener((v, focused) -> TvV17PosterCard.focus(a, card, name, focused));
        return card;
    }
}

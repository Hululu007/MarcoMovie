package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;

/** A home preview of the current real source. HomeScreen owns all source and paging state. */
final class TvV17LibraryScreen {
    /** No borrowed backdrop: the latest real history entry supplies title and resume action. */
    static View hero(MainActivity a, LinearLayout host, WatchHistory.Entry entry) {
        host.removeAllViews();
        if (entry == null) return null;
        LinearLayout hero = a.vertical();
        hero.setTag("home-continue");
        hero.setId(View.generateViewId());
        hero.setGravity(Gravity.CENTER_VERTICAL);
        hero.setPadding(a.dp(24), a.dp(18), a.dp(24), a.dp(18));
        GradientDrawable background =
                new GradientDrawable(
                        GradientDrawable.Orientation.LEFT_RIGHT,
                        new int[] {0xff273b43, 0xff242c39, 0xff171c25});
        background.setCornerRadius(a.dp(18));
        hero.setBackground(background);
        hero.setFocusable(true);
        hero.setFocusableInTouchMode(true);
        hero.setClickable(true);
        hero.setContentDescription("继续观看 " + entry.title + " " + a.historyLabel(entry));
        a.pressFeedback(hero);
        TextView title = a.text(entry.title, 24, TvV17Theme.TEXT);
        title.setTypeface(null, Typeface.BOLD);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        hero.addView(title);
        TextView detail = a.text(a.historyLabel(entry), 14, TvV17Theme.MUTED);
        detail.setSingleLine(true);
        detail.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams detailSize = new LinearLayout.LayoutParams(-1, -2);
        detailSize.topMargin = a.dp(8);
        hero.addView(detail, detailSize);
        TextView action = a.text("▶  继续观看", 15, TvV17Theme.TEXT);
        action.setTypeface(null, Typeface.BOLD);
        LinearLayout.LayoutParams actionSize = new LinearLayout.LayoutParams(-1, -2);
        actionSize.topMargin = a.dp(12);
        hero.addView(action, actionSize);
        hero.setOnClickListener(v -> a.resumeHistory(entry));
        hero.setOnFocusChangeListener(
                (v, focused) -> {
                    hero.setAlpha(focused ? 1f : .90f);
                    hero.setElevation(focused ? a.dp(5) : 0);
                    hero.setBackground(
                            TvV17Surface.rounded(
                                    focused ? 0xff304750 : 0xff26353f,
                                    a.dp(18),
                                    focused ? TvV17Theme.FOCUS : Color.TRANSPARENT,
                                    focused ? a.dp(2) : 0));
                });
        host.addView(hero, new LinearLayout.LayoutParams(-1, a.dp(164)));
        return hero;
    }

    static List<View> preview(
            MainActivity a,
            LinearLayout host,
            Cms.Site site,
            List<Cms.Video> videos,
            int columns,
            int widthDp) {
        host.removeAllViews();
        List<View> cards = new ArrayList<>();
        if (videos == null || videos.isEmpty()) {
            TextView empty = a.text("暂无影片，请打开片库切换分类或重试。", 14, MainActivity.MUTED);
            host.addView(empty);
            return cards;
        }
        LinearLayout row = a.row();
        row.setGravity(Gravity.TOP);
        row.setClipChildren(false);
        row.setClipToPadding(false);
        host.addView(row);
        int count = Math.min(columns, videos.size());
        for (int i = 0; i < count; i++) {
            Cms.Video video = videos.get(i);
            LinearLayout card = a.vertical();
            card.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
            card.setGravity(Gravity.CENTER_HORIZONTAL);
            card.setClipChildren(false);
            card.setTag("home-preview:" + i);
            card.setId(View.generateViewId());
            card.setFocusable(true);
            card.setFocusableInTouchMode(true);
            card.setClickable(true);
            card.setContentDescription(video.title);
            a.pressFeedback(card);
            ImageView image =
                    new ImageView(a) {
                        @Override
                        public void setImageBitmap(android.graphics.Bitmap bm) {
                            super.setImageBitmap(bm);
                            if (a.homeAmbient != null) a.homeAmbient.posterReady(this);
                        }
                    };
            TvV17PosterCard.artwork(a, image);
            card.addView(image, new LinearLayout.LayoutParams(a.dp(widthDp), a.dp(widthDp * 1.5f)));
            if (video.poster != null && !video.poster.isEmpty()) a.poster(video.poster, image);
            TextView title = a.text(video.title, 13, TvV17Theme.MUTED);
            title.setSingleLine(true);
            title.setEllipsize(TextUtils.TruncateAt.END);
            title.setPadding(a.dp(2), a.dp(7), a.dp(2), 0);
            card.addView(title, new LinearLayout.LayoutParams(-1, a.dp(27)));
            TvV17PosterCard.focus(a, card, title, false);
            card.setOnFocusChangeListener(
                    (v, focused) -> {
                        TvV17PosterCard.focus(a, card, title, focused);
                        if (focused && a.homeAmbient != null) a.homeAmbient.follow(image);
                    });
            if (i == 0
                    && a.homeAmbient != null
                    && (a.homeAmbient.wanted == null
                            || !a.homeAmbient.wanted.isAttachedToWindow())) {
                a.homeAmbient.follow(image);
            }
            card.setOnClickListener(v -> a.openListing(site, video));
            LinearLayout.LayoutParams cell = new LinearLayout.LayoutParams(0, -2, 1);
            cell.rightMargin = a.dp(i == columns - 1 ? 0 : 14);
            row.addView(card, cell);
            cards.add(card);
        }
        // Preserve card width when the source returns fewer items than the configured density.
        for (int i = count; i < columns; i++) {
            LinearLayout.LayoutParams cell = new LinearLayout.LayoutParams(0, 1, 1);
            cell.rightMargin = a.dp(i == columns - 1 ? 0 : 14);
            row.addView(new View(a), cell);
        }
        return cards;
    }
}

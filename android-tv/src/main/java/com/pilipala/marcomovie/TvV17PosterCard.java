package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.TextView;

/** Presentation only: callers own image loading, identity, actions and focus restoration. */
final class TvV17PosterCard {
    private static final int TAG_POSTER_VIEW = 0x5f505354; // "PST"
    private static final int TAG_DOUBAN_BADGE = 0x5f444242; // "DBB"

    static void artwork(MainActivity a, ImageView art) {
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        art.setBackground(TvV17Surface.rounded(0xff252c35, a.dp(10), Color.TRANSPARENT, 0));
        art.setClipToOutline(true);
    }

    /** Creates a consistent, sleek top-right Douban rating badge pill over poster artwork. */
    static TextView createDoubanBadge(MainActivity a) {
        TextView badge = a.text("", 10.5f, 0xfffbbf24);
        badge.setTag("card-douban-score");
        badge.setTypeface(null, Typeface.BOLD);
        badge.setSingleLine(true);
        badge.setIncludeFontPadding(false);
        badge.setPadding(a.dp(6), a.dp(2.5f), a.dp(6), a.dp(2.5f));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xd010141c);
        bg.setCornerRadius(a.dp(6));
        bg.setStroke(Math.max(1, a.dp(0.8f)), 0x44fbbf24);
        badge.setBackground(bg);
        badge.setVisibility(View.GONE);
        return badge;
    }

    static void attachDoubanBadge(MainActivity a, FrameLayout container, Cms.Video video) {
        attachDoubanBadge(a, container, video, 0);
    }

    static void attachDoubanBadge(
            MainActivity a, FrameLayout container, Cms.Video video, int scopeToken) {
        if (a == null || container == null || video == null) return;
        TextView badge = createDoubanBadge(a);
        FrameLayout.LayoutParams lp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
        lp.topMargin = a.dp(6);
        lp.rightMargin = a.dp(6);
        container.addView(badge, lp);
        container.setTag(TAG_DOUBAN_BADGE, badge);
        DoubanScoreRepository.bindBadge(a, badge, video, scopeToken);
    }

    static FrameLayout wrapArtworkWithDoubanBadge(
            MainActivity a, ImageView art, Cms.Video video, boolean showBadge) {
        return wrapArtworkWithDoubanBadge(a, art, video, showBadge, 0);
    }

    static FrameLayout wrapArtworkWithDoubanBadge(
            MainActivity a, ImageView art, Cms.Video video, boolean showBadge, int scopeToken) {
        FrameLayout wrap = new FrameLayout(a);
        wrap.setClipChildren(true);
        wrap.addView(art, new FrameLayout.LayoutParams(-1, -1));
        wrap.setTag(TAG_POSTER_VIEW, art);
        if (showBadge && video != null) {
            attachDoubanBadge(a, wrap, video, scopeToken);
        }
        return wrap;
    }

    /** Finds the underlying poster ImageView even when wrapped inside a badge FrameLayout. */
    static ImageView findPosterView(View root) {
        if (root == null) return null;
        if (root instanceof ImageView) return (ImageView) root;
        Object tagged = root.getTag(TAG_POSTER_VIEW);
        if (tagged instanceof ImageView) return (ImageView) tagged;
        if (root instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) root;
            for (int i = 0; i < group.getChildCount(); i++) {
                ImageView found = findPosterView(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    /** Finds the Douban rating badge TextView attached to a poster card, if present. */
    static TextView findDoubanBadge(View root) {
        if (root == null) return null;
        if (root instanceof TextView && "card-douban-score".equals(root.getTag())) {
            return (TextView) root;
        }
        Object tagged = root.getTag(TAG_DOUBAN_BADGE);
        if (tagged instanceof TextView) return (TextView) tagged;
        if (root instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) root;
            for (int i = 0; i < group.getChildCount(); i++) {
                TextView found = findDoubanBadge(group.getChildAt(i));
                if (found != null) return found;
            }
        }
        return null;
    }

    /**
     * Unbinds both the nested poster {@link ImageView} and any Douban rating badge inside a card so
     * late image or rating callbacks cannot backfill offscreen cards or leak views. Preserves
     * {@code card.getTag()} focus identity and the badge's {@code "card-douban-score"} tag.
     */
    static void unbindCard(View card) {
        if (card == null) return;
        ImageView poster = findPosterView(card);
        if (poster != null) {
            ImageLoader.unbind(poster);
        }
        TextView badge = findDoubanBadge(card);
        if (badge != null) {
            DoubanScoreRepository.unbindBadge(badge);
        }
    }

    static void focus(MainActivity a, View card, TextView title, boolean focused) {
        FocusMotion.style(
                a,
                card,
                focused,
                Color.TRANSPARENT,
                Color.TRANSPARENT,
                12,
                TvV17Theme.FOCUS,
                TvV17Theme.FOCUS,
                true,
                1.035f);
        title.setTextColor(focused ? TvV17Theme.TEXT : TvV17Theme.MUTED);
    }
}

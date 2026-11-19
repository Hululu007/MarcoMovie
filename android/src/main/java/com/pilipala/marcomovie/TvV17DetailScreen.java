package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** TV detail presentation. The host owns loading, identity, actions and the page stack. */
final class TvV17DetailScreen {
    interface Actions {
        void back();

        void play();

        void favorite();

        void synopsis();
    }

    final FrameLayout view;
    final LinearLayout seasonHost;
    final LinearLayout episodeHost;
    final Button play;
    final Button favorite;
    final TvScrollView scroll;
    final LinearLayout content;
    private final MainActivity host;

    /**
     * verifiedBackdrop must belong to this exact video, or be null. In its absence the original
     * poster is fitted without cropping; neither this component nor its image loader searches for
     * a substitute. The host supplies the existing bookmark/default-line play action.
     */
    TvV17DetailScreen(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            String verifiedBackdrop,
            boolean isFavorite,
            boolean playEnabled,
            String playLabel,
            Actions actions) {
        if (a == null || site == null || video == null || actions == null)
            throw new IllegalArgumentException();
        host = a;
        view = new FrameLayout(a);
        view.setTag("tv-v17-detail");
        view.setBackgroundColor(0xff10181e);

        boolean horizontal = verifiedBackdrop != null && !verifiedBackdrop.trim().isEmpty();
        String artwork = horizontal ? verifiedBackdrop : video.poster;
        if (artwork != null && !artwork.trim().isEmpty()) {
            ImageView image = new ImageView(a);
            image.setTag("tv-v17-detail-artwork");
            image.setScaleType(
                    horizontal ? ImageView.ScaleType.CENTER_CROP : ImageView.ScaleType.FIT_CENTER);
            FrameLayout.LayoutParams art =
                    new FrameLayout.LayoutParams(
                            horizontal ? -1 : a.dp(360), a.dp(440), Gravity.TOP | Gravity.RIGHT);
            view.addView(image, art);
            a.poster(artwork, image, true);
        }
        View shade = new View(a);
        shade.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.LEFT_RIGHT,
                        new int[] {0xf710181e, 0xc510181e, 0x5010181e}));
        view.addView(shade, new FrameLayout.LayoutParams(-1, a.dp(440)));

        scroll = new TvScrollView(a);
        scroll.setFillViewport(true);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        view.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        content = a.vertical();
        content.setPadding(a.dp(38), a.dp(24), a.dp(38), a.dp(36));
        content.setClipChildren(false);
        content.setClipToPadding(false);
        scroll.addView(content, new ScrollView.LayoutParams(-1, -2));

        Button back = DetailScreen.glassNavButton(a, "‹ 返回", "detail-back", false, actions::back);
        content.addView(back, new LinearLayout.LayoutParams(-2, a.dp(38)));
        View breathingRoom = new View(a);
        content.addView(breathingRoom, new LinearLayout.LayoutParams(1, a.dp(100)));

        TextView metadata =
                a.text(
                        TextUtils.join("  ·  ", DetailScreen.collectMetaPills(video)),
                        14,
                        TvV17Theme.MUTED);
        content.addView(metadata, new LinearLayout.LayoutParams(-1, -2));
        TextView title = a.text(video.title == null ? "" : video.title, 32, TvV17Theme.TEXT);
        title.setTag("detail-title");
        title.setTypeface(null, Typeface.BOLD);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(-1, -2);
        titleLp.topMargin = a.dp(8);
        content.addView(title, titleLp);
        LinearLayout rating = DetailScreen.buildRatingAndCastRow(a, site, video);
        LinearLayout.LayoutParams ratingLp = new LinearLayout.LayoutParams(-2, -2);
        ratingLp.topMargin = a.dp(6);
        content.addView(rating, ratingLp);
        if (video.description != null && !video.description.trim().isEmpty()) {
            TextView synopsis = a.text(video.description, 14, TvV17Theme.TEXT);
            synopsis.setMaxLines(2);
            synopsis.setEllipsize(TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams synopsisLp = new LinearLayout.LayoutParams(-1, -2);
            synopsisLp.topMargin = a.dp(10);
            content.addView(synopsis, synopsisLp);
        }
        LinearLayout buttons = a.row();
        buttons.setClipChildren(false);
        buttons.setClipToPadding(false);
        LinearLayout.LayoutParams buttonsLp = new LinearLayout.LayoutParams(-1, -2);
        buttonsLp.topMargin = a.dp(14);
        content.addView(buttons, buttonsLp);
        play = DetailScreen.heroPlayButton(a, playLabel, "detail-play", actions::play);
        play.setEnabled(playEnabled);
        buttons.addView(play, new LinearLayout.LayoutParams(-2, a.dp(46)));
        favorite =
                DetailScreen.glassNavButton(
                        a, "", "detail-favorite", isFavorite, actions::favorite);
        favorite.setOnFocusChangeListener(
                (v, focused) ->
                        DetailScreen.styleGlassButton(a, favorite, focused, favorite.isSelected()));
        setFavorite(isFavorite);
        LinearLayout.LayoutParams favoriteLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        favoriteLp.leftMargin = a.dp(8);
        buttons.addView(favorite, favoriteLp);
        Button more = DetailScreen.glassNavButton(a, "⋯ 更多", "synopsis", false, actions::synopsis);
        LinearLayout.LayoutParams moreLp = new LinearLayout.LayoutParams(-2, a.dp(46));
        moreLp.leftMargin = a.dp(8);
        buttons.addView(more, moreLp);

        seasonHost = a.vertical();
        seasonHost.setTag("detail-seasons");
        LinearLayout.LayoutParams seasonLp = new LinearLayout.LayoutParams(-1, -2);
        seasonLp.topMargin = a.dp(24);
        content.addView(seasonHost, seasonLp);
        episodeHost = a.vertical();
        episodeHost.setTag("detail-episodes");
        LinearLayout.LayoutParams panelLp = new LinearLayout.LayoutParams(-1, -2);
        panelLp.topMargin = a.dp(12);
        content.addView(TvV17EpisodePanel.wrap(a, episodeHost), panelLp);
    }

    void setFavorite(boolean selected) {
        favorite.setText(selected ? "♥ 已收藏" : "♡ 收藏");
        favorite.setSelected(selected);
        favorite.setContentDescription(selected ? "已收藏，点击取消收藏" : "收藏");
        DetailScreen.styleGlassButton(host, favorite, favorite.hasFocus(), selected);
    }
}

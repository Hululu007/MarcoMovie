package com.pilipala.marcomovie;

import android.widget.FrameLayout;
import android.widget.LinearLayout;

/** TV-only bridge to existing detail loading, favorites, line/episode popup and bookmark playback. */
final class TvDetailHost {
    interface Valid {
        boolean get();
    }

    static int[] initialSelection(
            Cms.Video video,
            WatchHistory.Entry bookmark,
            String preferred,
            EpisodeSelection saved,
            boolean descending) {
        int line = 0, page = 0;
        for (int i = 0; i < video.lines.size(); i++)
            if (video.lines.get(i).name.equals(preferred)) {
                line = i;
                break;
            }
        if (bookmark != null) {
            for (int i = 0; i < video.lines.size(); i++) {
                Cms.Line candidate = video.lines.get(i);
                if (!candidate.name.equals(bookmark.line)) continue;
                line = i;
                for (int n = 0; n < candidate.episodes.size(); n++)
                    if (candidate.episodes.get(n).name.equals(bookmark.episode)) {
                        page = (descending ? candidate.episodes.size() - 1 - n : n) / 50;
                        break;
                    }
                break;
            }
        }
        if (saved != null && saved.selected)
            for (int i = 0; i < video.lines.size(); i++)
                if (video.lines.get(i).name.equals(saved.line)) {
                    line = i;
                    page =
                            EpisodeSelection.boundPage(
                                    saved.page, video.lines.get(i).episodes.size());
                    break;
                }
        return new int[] {line, page};
    }

    static String formatHistoryCaption(
            MainActivity a, WatchHistory.Entry bookmark, String episodeFileCaption) {
        if (bookmark == null) return "";
        String progress =
                bookmark.complete()
                        ? "已看完"
                        : PlaybackController.formatTime(bookmark.position)
                                + (bookmark.duration > 0
                                        ? " / " + PlaybackController.formatTime(bookmark.duration)
                                        : "");
        String ep = bookmark.episode == null ? "" : bookmark.episode.trim();
        if (!ep.isEmpty() && episodeFileCaption != null && episodeFileCaption.contains(ep)) {
            return "上次观看进度 · " + progress;
        }
        return "上次观看 · " + a.historyLabel(bookmark);
    }

    private static Cms.Episode resolveActiveEpisode(Cms.Line line, WatchHistory.Entry bookmark) {
        if (line == null || line.episodes == null || line.episodes.isEmpty()) return null;
        if (bookmark != null && line.name.equals(bookmark.line) && bookmark.episode != null) {
            for (Cms.Episode ep : line.episodes) {
                if (bookmark.episode.equals(ep.name)) return ep;
            }
        }
        return line.episodes.get(0);
    }

    private static String buildEpisodesButtonLabel(Cms.Video video, int lineIdx) {
        if (video == null || video.lines.isEmpty()) return "☰ 选集";
        Cms.Line line = video.lines.get(Math.max(0, Math.min(lineIdx, video.lines.size() - 1)));
        int epCount = line.episodes.size();
        int lineCount = video.lines.size();
        if (epCount <= 1 && lineCount > 1) return "☰ 选线路 (" + lineCount + ")";
        if (epCount > 1 && lineCount > 1) return "☰ 选集与线路 · " + epCount + " 集";
        if (epCount > 1) return "☰ 选集 · " + epCount + " 集";
        return "☰ 线路与片源";
    }

    private static void showEpisodesPopup(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            WatchHistory.Entry bookmark,
            MainActivity.Screen screen,
            TvV17DetailScreen ui) {
        if (video == null || video.lines.isEmpty()) {
            a.toast("该来源没有可播放线路");
            return;
        }
        int[] selection =
                initialSelection(
                        video,
                        bookmark,
                        a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                        screen.selection,
                        a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));

        LinearLayout host = a.vertical();
        host.setTag("detail-episodes");
        host.setClipChildren(false);
        host.setClipToPadding(false);
        host.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(10));
        if (video.lines.get(selection[0]).episodes.size() > 16) {
            host.setMinimumHeight(Math.max(a.dp(280), a.windowHeight() - a.dp(220)));
        }

        DetailScreen.renderEpisodes(a, site, video, selection[0], selection[1], host, null);

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle("选线路与选集")
                        .setWide(true)
                        .setView(host)
                        .setNegativeButton("关闭", null)
                        .create();
        dialog.setOnDismissListener(
                d -> {
                    int[] updated =
                            initialSelection(
                                    video,
                                    bookmark,
                                    a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                    screen.selection,
                                    a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
                    Cms.Line activeLine = video.lines.get(updated[0]);
                    Cms.Episode activeEp = resolveActiveEpisode(activeLine, bookmark);
                    ui.updateEpisodeCaption(
                            TvV17DetailScreen.formatEpisodeFileCaption(activeLine, activeEp),
                            buildEpisodesButtonLabel(video, updated[0]));
                });
        dialog.show();
        android.view.View firstEp = host.findViewWithTag("detail-line:" + selection[0]);
        if (firstEp != null) firstEp.requestFocus();
    }

    static void show(MainActivity a, Cms.Site site, Cms.Video listing, Cms.Video ready) {
        a.renderPage(listing.title == null ? "详情" : listing.title, "");
        a.addButton(a.body, a.navButton("‹ 返回", "detail-back", a::onBackPressed));
        final MainActivity.Screen screen = a.current;
        final int ticket = a.generation;
        final TvSearchContext context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final TvV17DetailScreen[] displayed = new TvV17DetailScreen[1];
        Valid valid =
                () ->
                        a.current == screen
                                && ticket == a.generation
                                && !a.isFinishing()
                                && context.matches(a.config, a.privateMode, a.engineEpoch);
        android.widget.Button pendingFavorite =
                DetailScreen.glassNavButton(a, "", "detail-favorite", false, () -> {});
        DetailScreen.bindFavoriteAction(a, site, listing, pendingFavorite);
        pendingFavorite.setOnClickListener(
                v -> {
                    if (!valid.get()) return;
                    boolean selected = DetailScreen.toggleFavorite(a, site, listing);
                    pendingFavorite.setText(selected ? "♥ 已收藏" : "♡ 加入收藏");
                    DetailScreen.styleGlassButton(
                            a, pendingFavorite, pendingFavorite.hasFocus(), selected);
                });
        a.addButton(a.body, pendingFavorite);
        android.widget.TextView pending = a.text("正在加载影片详情…", 16, MainActivity.MUTED);
        pending.setTag("detail-loading");
        a.body.addView(pending);
        MainActivity.Done<Cms.Video> present =
                video -> {
                    if (!valid.get()) return;
                    if (video.id == null || video.id.trim().isEmpty()) video.id = listing.id;
                    if (video.title == null || video.title.isEmpty()) video.title = listing.title;
                    if (video.poster == null || video.poster.isEmpty())
                        video.poster = listing.poster;
                    if (video.year == null || video.year.isEmpty()) video.year = listing.year;
                    if (video.remarks == null || video.remarks.isEmpty())
                        video.remarks = listing.remarks;
                    if (video.doubanScore == null || video.doubanScore.isEmpty())
                        video.doubanScore = listing.doubanScore;
                    for (java.util.Iterator<Cms.Line> it = video.lines.iterator(); it.hasNext(); )
                        if (it.next().episodes.isEmpty()) it.remove();
                    WatchHistory.Entry found = null;
                    for (WatchHistory.Entry entry : a.watchHistory())
                        if (entry.site.equals(site.key) && entry.id.equals(video.id)) {
                            found = entry;
                            break;
                        }
                    final WatchHistory.Entry bookmark = found;
                    int[] initialSel =
                            video.lines.isEmpty()
                                    ? new int[] {0, 0}
                                    : initialSelection(
                                            video,
                                            bookmark,
                                            a.prefs.getString(Prefs.PREFERRED_LINE, ""),
                                            screen.selection,
                                            a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
                    Cms.Line activeLine =
                            video.lines.isEmpty() ? null : video.lines.get(initialSel[0]);
                    Cms.Episode activeEpisode = resolveActiveEpisode(activeLine, bookmark);
                    String episodeFileCaption =
                            TvV17DetailScreen.formatEpisodeFileCaption(activeLine, activeEpisode);
                    String historyCaption = formatHistoryCaption(a, bookmark, episodeFileCaption);
                    String episodesBtnLabel = buildEpisodesButtonLabel(video, initialSel[0]);

                    if (displayed[0] != null) a.capture();
                    final TvV17DetailScreen[] current = new TvV17DetailScreen[1];
                    TvV17DetailScreen ui =
                            new TvV17DetailScreen(
                                    a,
                                    site,
                                    video,
                                    null,
                                    Favorites.contains(
                                            a.prefs.getString(Prefs.FAVORITES, "[]"),
                                            site.key,
                                            video.id),
                                    !video.lines.isEmpty(),
                                    bookmark == null ? "► 开始播放" : "► 继续播放",
                                    episodesBtnLabel,
                                    episodeFileCaption,
                                    historyCaption,
                                    new TvV17DetailScreen.Actions() {
                                        public void back() {
                                            if (valid.get()) a.onBackPressed();
                                        }

                                        public void play() {
                                            if (!valid.get() || video.lines.isEmpty()) return;
                                            int[] sel =
                                                    initialSelection(
                                                            video,
                                                            bookmark,
                                                            a.prefs.getString(
                                                                    Prefs.PREFERRED_LINE, ""),
                                                            screen.selection,
                                                            a.prefs.getBoolean(
                                                                    Prefs.EPISODES_DESCENDING,
                                                                    false));
                                            if (bookmark != null
                                                    && (!screen.selection.selected
                                                            || video.lines
                                                                    .get(sel[0])
                                                                    .name
                                                                    .equals(bookmark.line))) {
                                                a.playBookmark(site, video, bookmark);
                                            } else {
                                                Cms.Line line = video.lines.get(sel[0]);
                                                a.resolvePlayer(
                                                        site, video, line, line.episodes.get(0));
                                            }
                                        }

                                        public void episodes() {
                                            if (!valid.get()) return;
                                            showEpisodesPopup(
                                                    a, site, video, bookmark, screen, current[0]);
                                        }

                                        public void favorite() {
                                            if (!valid.get()) return;
                                            current[0].setFavorite(
                                                    DetailScreen.toggleFavorite(a, site, video));
                                        }

                                        public void synopsis() {
                                            if (valid.get())
                                                new AppDialog.Builder(a)
                                                        .setTitle(video.title)
                                                        .setMessage(
                                                                DetailScreen
                                                                        .buildFullSynopsisMessage(
                                                                                video))
                                                        .setPositiveButton("关闭", null)
                                                        .show();
                                        }
                                    });
                    current[0] = ui;
                    if (displayed[0] == null) a.root.removeView(a.scroll);
                    else a.root.removeView(displayed[0].view);
                    displayed[0] = ui;
                    a.root.addView(ui.view, new FrameLayout.LayoutParams(-1, -1));
                    a.scroll = ui.scroll;
                    a.body = ui.content;
                    if (video.lines.isEmpty()) {
                        ui.statusView.setText("该来源没有返回可播放线路");
                        ui.statusView.setVisibility(android.view.View.VISIBLE);
                        screen.focus = "detail-favorite";
                    } else {
                        DetailScreen.populateTvRelatedSeasons(a, site, video, ui.seasonHost);
                        if (screen.focus == null || "detail-back".equals(screen.focus))
                            screen.focus = "detail-play";
                    }
                    a.restore(screen);
                };
        if (ready != null) {
            try {
                present.accept(ready);
            } catch (Exception e) {
                a.notice("详情数据无法显示，请返回后重试。");
            }
        } else {
            boolean playable = false;
            for (Cms.Line line : listing.lines)
                if (!line.episodes.isEmpty()) {
                    playable = true;
                    break;
                }
            if (playable) {
                try {
                    present.accept(listing);
                } catch (Exception e) {
                    a.notice("详情数据无法显示，请返回后重试。");
                }
                if (!a.reduced
                        && (listing.description == null || listing.description.trim().isEmpty())) {
                    android.view.View state = a.root.findViewWithTag("detail-loading");
                    if (state instanceof android.widget.TextView) {
                        state.setVisibility(android.view.View.VISIBLE);
                        ((android.widget.TextView) state).setText("正在补全详情…");
                    }
                    a.loadDetail(site, listing.id, present);
                }
            } else a.loadDetail(site, listing.id, present);
        }
    }
}

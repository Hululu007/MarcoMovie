package com.pilipala.marcomovie;

import android.widget.FrameLayout;

/** TV-only bridge to existing detail loading, favorites, line selection and bookmark playback. */
final class TvDetailHost {
    interface Valid { boolean get(); }
    static int[] initialSelection(Cms.Video video, WatchHistory.Entry bookmark,
            String preferred, EpisodeSelection saved, boolean descending) {
        int line = 0, page = 0;
        for (int i = 0; i < video.lines.size(); i++)
            if (video.lines.get(i).name.equals(preferred)) { line = i; break; }
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
                    page = EpisodeSelection.boundPage(saved.page, video.lines.get(i).episodes.size());
                    break;
                }
        return new int[] {line, page};
    }

    static void show(MainActivity a, Cms.Site site, Cms.Video listing, Cms.Video ready) {
        a.renderPage(listing.title == null ? "详情" : listing.title, "");
        a.addButton(a.body, a.navButton("‹ 返回", "detail-back", a::onBackPressed));
        final MainActivity.Screen screen = a.current;
        final int ticket = a.generation;
        final TvSearchContext context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final TvV17DetailScreen[] displayed = new TvV17DetailScreen[1];
        Valid valid = () -> a.current == screen && ticket == a.generation
                && !a.isFinishing() && context.matches(a.config, a.privateMode, a.engineEpoch);
        android.widget.Button pendingFavorite = DetailScreen.glassNavButton(a, "", "detail-favorite", false, () -> {});
        DetailScreen.bindFavoriteAction(a, site, listing, pendingFavorite);
        pendingFavorite.setOnClickListener(v -> {
            if (!valid.get()) return;
            boolean selected = DetailScreen.toggleFavorite(a, site, listing);
            pendingFavorite.setText(selected ? "♥ 已收藏" : "♡ 加入收藏");
            DetailScreen.styleGlassButton(a, pendingFavorite, pendingFavorite.hasFocus(), selected);
        });
        a.addButton(a.body, pendingFavorite);
        android.widget.TextView pending = a.text("正在加载影片详情…", 16, MainActivity.MUTED);
        pending.setTag("detail-loading");
        a.body.addView(pending);
        MainActivity.Done<Cms.Video> present = video -> {
            if (!valid.get()) return;
            if (video.id == null || video.id.trim().isEmpty()) video.id = listing.id;
            if (video.title == null || video.title.isEmpty()) video.title = listing.title;
            if (video.poster == null || video.poster.isEmpty()) video.poster = listing.poster;
            if (video.year == null || video.year.isEmpty()) video.year = listing.year;
            if (video.remarks == null || video.remarks.isEmpty()) video.remarks = listing.remarks;
            if (video.doubanScore == null || video.doubanScore.isEmpty()) video.doubanScore = listing.doubanScore;
            // Same empty-line exclusion as the existing detail route; keep original line objects.
            for (java.util.Iterator<Cms.Line> it = video.lines.iterator(); it.hasNext(); )
                if (it.next().episodes.isEmpty()) it.remove();
            WatchHistory.Entry found = null;
            for (WatchHistory.Entry entry : a.watchHistory())
                if (entry.site.equals(site.key) && entry.id.equals(video.id)) { found = entry; break; }
            final WatchHistory.Entry bookmark = found;
            if (displayed[0] != null) a.capture();
            final TvV17DetailScreen[] current = new TvV17DetailScreen[1];
            TvV17DetailScreen ui = new TvV17DetailScreen(a, site, video, null,
                    Favorites.contains(a.prefs.getString(Prefs.FAVORITES, "[]"), site.key, video.id),
                    !video.lines.isEmpty(), bookmark == null ? "► 开始播放" : "► 继续播放 · " + bookmark.episode,
                    new TvV17DetailScreen.Actions() {
                        public void back() { if (valid.get()) a.onBackPressed(); }
                        public void play() {
                            if (!valid.get() || video.lines.isEmpty()) return;
                            if (bookmark != null) a.playBookmark(site, video, bookmark);
                            else {
                                Cms.Line line = video.lines.get(SourcePreferences.lineIndex(a, video));
                                a.resolvePlayer(site, video, line, line.episodes.get(0));
                            }
                        }
                        public void favorite() {
                            if (!valid.get()) return;
                            current[0].setFavorite(DetailScreen.toggleFavorite(a, site, video));
                        }
                        public void synopsis() {
                            if (valid.get()) new AppDialog.Builder(a).setTitle(video.title)
                                    .setMessage(DetailScreen.buildFullSynopsisMessage(video))
                                    .setPositiveButton("关闭", null).show();
                        }
                    });
            if (bookmark != null) {
                android.widget.TextView history = a.text("上次观看 · " + a.historyLabel(bookmark), 13, MainActivity.MUTED);
                history.setTag("detail-history");
                ui.content.addView(history, ui.content.indexOfChild(ui.seasonHost));
            }
            android.widget.TextView status = a.text("", 14, MainActivity.MUTED);
            status.setTag("detail-loading");
            ui.content.addView(status, ui.content.indexOfChild(ui.seasonHost));
            current[0] = ui;
            if (displayed[0] == null) a.root.removeView(a.scroll);
            else a.root.removeView(displayed[0].view);
            displayed[0] = ui;
            a.root.addView(ui.view, new FrameLayout.LayoutParams(-1, -1));
            a.scroll = ui.scroll; a.body = ui.content;
            if (video.lines.isEmpty()) {
                ui.episodeHost.addView(a.text("该来源没有返回可播放线路", 16, MainActivity.MUTED));
                screen.focus = "detail-favorite";
            } else {
                int[] selection = initialSelection(video, bookmark,
                        a.prefs.getString(Prefs.PREFERRED_LINE, ""), screen.selection,
                        a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
                DetailScreen.populateTvRelatedSeasons(a, site, video, ui.seasonHost);
                DetailScreen.renderEpisodes(a, site, video, selection[0], selection[1], ui.episodeHost, null);
                if (screen.focus == null || "detail-back".equals(screen.focus)) screen.focus = "detail-play";
            }
            a.restore(screen);
        };
        if (ready != null) {
            try { present.accept(ready); }
            catch (Exception e) { a.notice("详情数据无法显示，请返回后重试。"); }
        } else {
            boolean playable = false;
            for (Cms.Line line : listing.lines) if (!line.episodes.isEmpty()) { playable = true; break; }
            if (playable) {
                try { present.accept(listing); }
                catch (Exception e) { a.notice("详情数据无法显示，请返回后重试。"); }
                if (!a.reduced && (listing.description == null || listing.description.trim().isEmpty())) {
                    android.view.View state = a.root.findViewWithTag("detail-loading");
                    if (state instanceof android.widget.TextView) ((android.widget.TextView) state).setText("正在补全详情…");
                    a.loadDetail(site, listing.id, present);
                }
            } else a.loadDetail(site, listing.id, present);
        }
    }
}

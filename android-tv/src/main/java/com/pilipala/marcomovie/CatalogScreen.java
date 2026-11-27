package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.SystemClock;
import android.text.TextPaint;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
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
                        if (!SourceController.isConfigOrNetdiskActionCard(s, v)) {
                            TvV17PosterCard.attachDoubanBadge(a, art, v);
                        }
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
        if (e == null) return "";
        String ep = e.episode == null ? "" : e.episode.trim();
        String prog =
                e.complete()
                        ? "已看完"
                        : PlaybackController.formatTime(e.position)
                                + (e.duration > 0
                                        ? " / " + PlaybackController.formatTime(e.duration)
                                        : "");
        return ep.isEmpty() ? prog : ep + " · " + prog;
    }

    static List<Cms.Site> collectAlternativeHistorySites(MainActivity a, String failedSiteKey) {
        if (a == null || a.config == null || a.config.sites == null) {
            return java.util.Collections.emptyList();
        }
        List<Cms.Site> pool = new ArrayList<>();
        for (Cms.Site s : SourcePreferences.prioritized(a, a.config.sites)) {
            if (s == null || !s.searchable || !a.available(s)) continue;
            if (SourceController.isConfigOrNetdiskSite(s)) continue;
            pool.add(s);
        }
        String selectedKey = a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
        return HistoryResumeMatcher.rankAlternativeSites(
                pool, failedSiteKey, selectedKey, a.isTvDevice() ? 8 : 12);
    }

    static boolean hasAlternativeHistorySources(MainActivity a, String failedSiteKey) {
        return !collectAlternativeHistorySites(a, failedSiteKey).isEmpty();
    }

    static void resumeHistory(MainActivity a, WatchHistory.Entry e) {
        if (a == null || e == null) return;
        if (a.isTvDevice()
                && a.multiSourceStore != null
                && a.configStore != null
                && !a.privateMode) {
            TvMultiSourceStore.State msState = a.multiSourceStore.readState();
            if (msState.initialized) {
                ConfigLibrary lib = new ConfigLibrary(a.configStore.directory);
                TvMultiSourceStore.SiteResolution res =
                        a.multiSourceStore.resolveStoredSiteKey(e.site, a.config, lib);
                if (res.status == TvMultiSourceStore.SiteResolution.STATUS_ENABLED
                        && res.activeSite != null
                        && a.available(res.activeSite)) {
                    openHistoryOnSite(a, e, res.activeSite);
                    return;
                }
                if (res.status == TvMultiSourceStore.SiteResolution.STATUS_DISABLED_SUBSCRIPTION
                        && res.subscription != null) {
                    final TvMultiSourceStore.SubscriptionRecord sub = res.subscription;
                    final String targetStableKey = res.stableSiteKey;
                    new AppDialog.Builder(a)
                            .setTitle("「" + sub.name + "」当前已停用")
                            .setMessage(
                                    "这条观看历史来自已停用的订阅源「" + sub.name + "」。可直接重新启用来源并继续播放，或从其他已启用片源查找。")
                            .setPositiveButton(
                                    "启用来源",
                                    (d, w) -> {
                                        try {
                                            a.multiSourceStore.setSubscriptionEnabled(sub.id, true);
                                            TvMultiSourceStore.EffectiveBuild built =
                                                    a.multiSourceStore.buildEffectiveConfig(
                                                            lib,
                                                            a.prefs.getString(
                                                                    Prefs.PREFERRED_SITE, ""),
                                                            (cfg, st) ->
                                                                    SourceController.available(
                                                                            a, cfg, st));
                                            a.applyMultiSourceEffectiveBuild(
                                                    built, false, 0, 0, "已重新启用「" + sub.name + "」");
                                            Cms.Site target =
                                                    findSiteByKey(a.config, targetStableKey);
                                            if (target != null && a.available(target)) {
                                                openHistoryOnSite(a, e, target);
                                            }
                                        } catch (Exception err) {
                                            a.notice("启用来源失败：" + a.message(err));
                                        }
                                    })
                            .setNeutralButton(
                                    "选择其他来源",
                                    (d, w) -> {
                                        if (e.title != null && !e.title.trim().isEmpty()) {
                                            a.openSearch(e.title);
                                        }
                                    })
                            .setNegativeButton("保留记录", null)
                            .show();
                    return;
                }
                if (res.status == TvMultiSourceStore.SiteResolution.STATUS_DISABLED_SITE
                        && res.subscription != null) {
                    final TvMultiSourceStore.SubscriptionRecord sub = res.subscription;
                    final String rawKey = res.rawSiteKey;
                    final String targetStableKey = res.stableSiteKey;
                    new AppDialog.Builder(a)
                            .setTitle("线路「" + res.siteName + "」已停用")
                            .setMessage("该历史记录对应的线路已单独停用。可重新启用该线路并继续观看，或从其他来源搜索。")
                            .setPositiveButton(
                                    "启用线路",
                                    (d, w) -> {
                                        try {
                                            a.multiSourceStore.setSiteDisabled(
                                                    sub.id, rawKey, false);
                                            TvMultiSourceStore.EffectiveBuild built =
                                                    a.multiSourceStore.buildEffectiveConfig(
                                                            lib,
                                                            a.prefs.getString(
                                                                    Prefs.PREFERRED_SITE, ""),
                                                            (cfg, st) ->
                                                                    SourceController.available(
                                                                            a, cfg, st));
                                            a.applyMultiSourceEffectiveBuild(
                                                    built,
                                                    false,
                                                    0,
                                                    0,
                                                    "已重新启用线路「" + res.siteName + "」");
                                            Cms.Site target =
                                                    findSiteByKey(a.config, targetStableKey);
                                            if (target != null && a.available(target)) {
                                                openHistoryOnSite(a, e, target);
                                            }
                                        } catch (Exception err) {
                                            a.notice("启用线路失败：" + a.message(err));
                                        }
                                    })
                            .setNeutralButton(
                                    "选择其他来源",
                                    (d, w) -> {
                                        if (e.title != null && !e.title.trim().isEmpty()) {
                                            a.openSearch(e.title);
                                        }
                                    })
                            .setNegativeButton("保留记录", null)
                            .show();
                    return;
                }
                if (res.status == TvMultiSourceStore.SiteResolution.STATUS_AMBIGUOUS
                        && !res.candidates.isEmpty()) {
                    String[] labels = new String[res.candidates.size()];
                    for (int i = 0; i < res.candidates.size(); i++) {
                        TvMultiSourceStore.SiteResolution.Candidate c = res.candidates.get(i);
                        labels[i] =
                                c.subscription.name
                                        + " · "
                                        + c.siteName
                                        + (c.subscription.enabled ? "" : "（已停用）");
                    }
                    new AppDialog.Builder(a)
                            .setTitle("选择该历史记录的来源")
                            .setMessage("多个订阅存在同名片源，为避免串源，请选择具体来源打开：")
                            .setItems(
                                    labels,
                                    (d, idx) -> {
                                        TvMultiSourceStore.SiteResolution.Candidate pick =
                                                res.candidates.get(idx);
                                        try {
                                            if (!pick.subscription.enabled) {
                                                a.multiSourceStore.setSubscriptionEnabled(
                                                        pick.subscription.id, true);
                                            }
                                            if (pick.siteDisabled) {
                                                a.multiSourceStore.setSiteDisabled(
                                                        pick.subscription.id,
                                                        pick.rawSiteKey,
                                                        false);
                                            }
                                            TvMultiSourceStore.EffectiveBuild built =
                                                    a.multiSourceStore.buildEffectiveConfig(
                                                            lib,
                                                            a.prefs.getString(
                                                                    Prefs.PREFERRED_SITE, ""),
                                                            (cfg, st) ->
                                                                    SourceController.available(
                                                                            a, cfg, st));
                                            a.applyMultiSourceEffectiveBuild(
                                                    built, false, 0, 0, "");
                                            Cms.Site target =
                                                    findSiteByKey(a.config, pick.stableSiteKey);
                                            if (target != null && a.available(target)) {
                                                openHistoryOnSite(a, e, target);
                                            }
                                        } catch (Exception err) {
                                            a.notice("打开来源失败：" + a.message(err));
                                        }
                                    })
                            .setNegativeButton("保留记录", null)
                            .show();
                    return;
                }
            }
        }
        if (a.config == null) {
            String origin = a.prefs != null ? a.prefs.getString(Prefs.ORIGIN, "") : "";
            if (origin != null && !origin.trim().isEmpty()) {
                a.toast("正在加载片源配置，请稍后再点击继续观看");
            } else {
                a.notice("当前尚未导入片源配置，导入片源后即可继续观看该历史记录。");
            }
            return;
        }
        Cms.Site site = findSiteByKey(a.config, e.site);
        if (site == null || !a.available(site)) {
            if (e.title != null
                    && !e.title.trim().isEmpty()
                    && hasAlternativeHistorySources(a, e.site)) {
                resumeHistoryFromAlternativeSources(a, e, e.site, "原片源不在当前订阅中", false);
                return;
            }
            if (e.title != null && !e.title.trim().isEmpty()) {
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
        openHistoryOnSite(a, e, site);
    }

    private static Cms.Site findSiteByKey(Cms.Config cfg, String key) {
        if (cfg == null || key == null) return null;
        for (Cms.Site s : cfg.sites) {
            if (s != null && key.equals(s.key)) return s;
        }
        return null;
    }

    private static void openHistoryOnSite(MainActivity a, WatchHistory.Entry e, Cms.Site selected) {
        WatchHistory.Entry forwarded = WatchHistory.cloneEntry(e);
        if (forwarded != null
                && selected != null
                && selected.key != null
                && !selected.key.isEmpty()) {
            if (!selected.key.equals(e.site) && e.id != null && !e.id.isEmpty()) {
                a.pendingHistoryMigration =
                        new WatchHistory.PendingMigration(e.key(), selected.key, e.id);
            }
            forwarded.site = selected.key;
        }
        a.historyFallbackBookmark = forwarded;
        a.historyFallbackInFlight = false;
        Cms.Video listing = new Cms.Video();
        listing.id = e.id;
        listing.title = e.title;
        listing.poster = e.poster;
        a.open(new MainActivity.Screen(() -> a.detail(selected, listing)), true);
    }

    private static final class AltHistoryHit {
        final Cms.Site site;
        final Cms.Video video;
        final int score;

        AltHistoryHit(Cms.Site site, Cms.Video video, int score) {
            this.site = site;
            this.video = video;
            this.score = score;
        }
    }

    static void resumeHistoryFromAlternativeSources(
            final MainActivity a,
            final WatchHistory.Entry rawBookmark,
            final String failedSiteKey,
            final String reason,
            final boolean replaceCurrentScreen) {
        if (a == null || rawBookmark == null || a.isFinishing()) return;
        final WatchHistory.Entry bookmark = WatchHistory.cloneEntry(rawBookmark);
        final String title = bookmark.title == null ? "" : bookmark.title.trim();
        if (title.isEmpty()) {
            a.historyFallbackInFlight = false;
            a.notice("该观看记录缺少片名，无法自动匹配其他片源。");
            return;
        }
        final List<Cms.Site> candidates = collectAlternativeHistorySites(a, failedSiteKey);
        if (candidates.isEmpty()) {
            a.historyFallbackInFlight = false;
            new AppDialog.Builder(a)
                    .setTitle("原片源暂不可用")
                    .setMessage(reason + "，当前没有其他可用片源可自动切换，是否前往全网搜索「" + title + "」？")
                    .setPositiveButton("全网搜索", (d, w) -> a.openSearch(title))
                    .setNegativeButton("保留记录", null)
                    .show();
            return;
        }

        a.historyFallbackInFlight = true;
        final TvSearchContext ctx = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final java.util.concurrent.atomic.AtomicBoolean cancelled =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        final java.util.concurrent.atomic.AtomicBoolean resolvedOk =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        final SearchCoordinator[] coordRef = new SearchCoordinator[1];

        final TextView statusText =
                a.text(
                        reason + "，正在从其他 " + candidates.size() + " 个片源自动匹配《" + title + "》…",
                        14.5f,
                        MainActivity.WHITE);
        statusText.setLineSpacing(a.dp(4), 1f);
        final AppDialog progressDialog =
                new AppDialog.Builder(a)
                        .setTitle("自动切换可用片源")
                        .setView(statusText)
                        .setNegativeButton(
                                "取消",
                                (d, w) -> {
                                    cancelled.set(true);
                                    a.historyFallbackInFlight = false;
                                    if (coordRef[0] != null) coordRef[0].close();
                                })
                        .create();
        progressDialog.setOnCancelListener(
                d -> {
                    cancelled.set(true);
                    a.historyFallbackInFlight = false;
                    if (coordRef[0] != null) coordRef[0].close();
                });
        progressDialog.show();

        final List<AltHistoryHit> hits = new ArrayList<>();
        final int[] finishedCount = {0};
        final boolean[] detailChecking = {false};
        final boolean[] allDone = {false};
        final Runnable[] tryNextHitRef = new Runnable[1];

        final Runnable handleAllExhausted =
                () -> {
                    if (cancelled.get() || resolvedOk.get() || a.isFinishing()) return;
                    a.historyFallbackInFlight = false;
                    if (coordRef[0] != null) coordRef[0].close();
                    if (progressDialog.isShowing()) progressDialog.dismiss();
                    new AppDialog.Builder(a)
                            .setTitle("未找到可直接续播的备用源")
                            .setMessage("已尝试当前订阅中的其他片源，暂未匹配到《" + title + "》的可播剧集。是否打开全网搜索手动挑选？")
                            .setPositiveButton("全网搜索", (d, w) -> a.openSearch(title))
                            .setNegativeButton("保留记录", null)
                            .show();
                };

        tryNextHitRef[0] =
                () -> {
                    if (cancelled.get()
                            || resolvedOk.get()
                            || detailChecking[0]
                            || a.isFinishing()
                            || !ctx.matches(a.config, a.privateMode, a.engineEpoch)) {
                        return;
                    }
                    if (hits.isEmpty()) {
                        if (allDone[0]) handleAllExhausted.run();
                        return;
                    }
                    detailChecking[0] = true;
                    final AltHistoryHit hit = hits.remove(0);
                    statusText.setText("已匹配到「" + hit.site.name + "」，正在拉取剧集并恢复上次进度…");
                    a.details.execute(
                            () -> {
                                Cms.Video detailVideo = null;
                                try {
                                    boolean hasLines =
                                            hit.video.lines != null && !hit.video.lines.isEmpty();
                                    if (hasLines) {
                                        detailVideo = hit.video;
                                    } else {
                                        SourceEngine eng =
                                                SourceController.engine(a, hit.site, ctx);
                                        Cms.Listing list = Cms.listing(eng.detail(hit.video.id));
                                        if (!list.videos.isEmpty()) {
                                            detailVideo = list.videos.get(0);
                                        }
                                    }
                                    if (detailVideo != null) {
                                        if (detailVideo.id == null
                                                || detailVideo.id.trim().isEmpty()) {
                                            detailVideo.id = hit.video.id;
                                        }
                                        if (detailVideo.title == null
                                                || detailVideo.title.isEmpty()) {
                                            detailVideo.title =
                                                    hit.video.title != null
                                                                    && !hit.video.title.isEmpty()
                                                            ? hit.video.title
                                                            : title;
                                        }
                                        if (detailVideo.poster == null
                                                || detailVideo.poster.isEmpty()) {
                                            detailVideo.poster =
                                                    hit.video.poster != null
                                                                    && !hit.video.poster.isEmpty()
                                                            ? hit.video.poster
                                                            : bookmark.poster;
                                        }
                                    }
                                } catch (Throwable ignored) {
                                    detailVideo = null;
                                }
                                final Cms.Video readyVideo = detailVideo;
                                final HistoryResumeMatcher.EpisodeMatch matched =
                                        readyVideo != null
                                                ? HistoryResumeMatcher.matchEpisode(
                                                        readyVideo, bookmark)
                                                : null;
                                a.ui.post(
                                        () -> {
                                            detailChecking[0] = false;
                                            if (cancelled.get()
                                                    || resolvedOk.get()
                                                    || a.isFinishing()
                                                    || !ctx.matches(
                                                            a.config, a.privateMode, a.engineEpoch))
                                                return;
                                            if (readyVideo != null && matched != null) {
                                                resolvedOk.set(true);
                                                if (coordRef[0] != null) coordRef[0].close();
                                                if (progressDialog.isShowing()) {
                                                    progressDialog.dismiss();
                                                }
                                                int resumePos = bookmark.resume();
                                                String oldKey = bookmark.key();
                                                WatchHistory.PendingMigration migration =
                                                        new WatchHistory.PendingMigration(
                                                                oldKey,
                                                                hit.site.key,
                                                                readyVideo.id);
                                                a.pendingHistoryMigration =
                                                        migration.matchesTarget(
                                                                        hit.site.key, readyVideo.id)
                                                                ? migration
                                                                : null;
                                                a.historyFallbackBookmark = null;
                                                a.resumeAt = resumePos;
                                                if (replaceCurrentScreen
                                                        && a.current != null
                                                        && !a.current.player) {
                                                    a.open(
                                                            new MainActivity.Screen(
                                                                    () ->
                                                                            a.detail(
                                                                                    hit.site,
                                                                                    readyVideo,
                                                                                    readyVideo)),
                                                            false);
                                                } else if (a.current == null || !a.current.player) {
                                                    a.open(
                                                            new MainActivity.Screen(
                                                                    () ->
                                                                            a.detail(
                                                                                    hit.site,
                                                                                    readyVideo,
                                                                                    readyVideo)),
                                                            true);
                                                }
                                                String epHint =
                                                        matched.episode.name != null
                                                                        && !matched.episode
                                                                                .name
                                                                                .trim()
                                                                                .isEmpty()
                                                                ? " · "
                                                                        + matched.episode.name
                                                                                .trim()
                                                                : "";
                                                String posHint =
                                                        resumePos > 0
                                                                ? "（续播 "
                                                                        + PlaybackController
                                                                                .formatTime(
                                                                                        resumePos)
                                                                        + "）"
                                                                : "";
                                                a.toast(
                                                        "原源已失效，已自动切换至「"
                                                                + hit.site.name
                                                                + "」"
                                                                + epHint
                                                                + posHint);
                                                a.resolvePlayer(
                                                        hit.site,
                                                        readyVideo,
                                                        matched.line,
                                                        matched.episode);
                                            } else {
                                                tryNextHitRef[0].run();
                                            }
                                        });
                            });
                };

        int maxConc = a.isTvDevice() ? 1 : 2;
        SearchCoordinator.configureThreads(a.prefs.getInt(Prefs.SEARCH_THREADS, 6));
        SearchCoordinator coordinator =
                new SearchCoordinator(
                        (site, q) -> {
                            SourceEngine eng = SourceController.engine(a, site, ctx);
                            return Cms.listing(eng.search(q, 1)).videos;
                        },
                        (site, videos, outcome) ->
                                a.ui.post(
                                        () -> {
                                            if (cancelled.get()
                                                    || resolvedOk.get()
                                                    || a.isFinishing()) return;
                                            finishedCount[0]++;
                                            if (videos != null && !videos.isEmpty()) {
                                                Cms.Video bestCand = null;
                                                int bestScore = 54;
                                                for (Cms.Video cand : videos) {
                                                    int sc =
                                                            HistoryResumeMatcher.scoreTitleMatch(
                                                                    bookmark, cand);
                                                    if (sc > bestScore) {
                                                        bestScore = sc;
                                                        bestCand = cand;
                                                    }
                                                }
                                                if (bestCand != null) {
                                                    hits.add(
                                                            new AltHistoryHit(
                                                                    site, bestCand, bestScore));
                                                    java.util.Collections.sort(
                                                            hits,
                                                            (x, y) ->
                                                                    Integer.compare(
                                                                            y.score, x.score));
                                                    if (!detailChecking[0]) {
                                                        tryNextHitRef[0].run();
                                                        return;
                                                    }
                                                }
                                            }
                                            if (!detailChecking[0]) {
                                                statusText.setText(
                                                        reason
                                                                + "，正在匹配《"
                                                                + title
                                                                + "》其他片源（"
                                                                + finishedCount[0]
                                                                + "/"
                                                                + candidates.size()
                                                                + "）…");
                                            }
                                            if (finishedCount[0] >= candidates.size()) {
                                                allDone[0] = true;
                                                if (!detailChecking[0]) {
                                                    tryNextHitRef[0].run();
                                                }
                                            }
                                        }),
                        6000,
                        15000,
                        8,
                        maxConc);
        coordRef[0] = coordinator;
        coordinator.start(candidates, title);
    }

    static void playBookmark(
            MainActivity a, Cms.Site site, Cms.Video video, WatchHistory.Entry bookmark) {
        HistoryResumeMatcher.EpisodeMatch matched =
                HistoryResumeMatcher.matchEpisode(video, bookmark);
        if (matched == null) {
            a.notice("上次的线路或集数已变更，请在下方重新选集。");
            return;
        }
        WatchHistory.Entry forwarded = WatchHistory.cloneEntry(bookmark);
        if (forwarded != null && site != null && site.key != null && !site.key.isEmpty()) {
            if (bookmark.site != null
                    && !site.key.equals(bookmark.site)
                    && bookmark.id != null
                    && !bookmark.id.isEmpty()
                    && a.pendingHistoryMigration == null) {
                a.pendingHistoryMigration =
                        new WatchHistory.PendingMigration(bookmark.key(), site.key, bookmark.id);
            }
            forwarded.site = site.key;
        }
        a.historyFallbackBookmark = forwarded;
        a.historyFallbackInFlight = false;
        a.resumeAt = bookmark.resume();
        a.resolvePlayer(site, video, matched.line, matched.episode);
    }

    private static String formatHistoryDuration(int ms) {
        int sec = Math.max(0, ms / 1000);
        int h = sec / 3600;
        int m = (sec / 60) % 60;
        int s = sec % 60;
        StringBuilder sb = new StringBuilder(8);
        if (h > 0) {
            sb.append(h).append(':');
        }
        if (m < 10) sb.append('0');
        sb.append(m).append(':');
        if (s < 10) sb.append('0');
        sb.append(s);
        return sb.toString();
    }

    private static String historyProgressBadge(WatchHistory.Entry e) {
        if (e.complete()) return "已看完";
        if (e.duration > 0) {
            int pct = Math.max(1, Math.min(99, Math.round(e.position * 100f / e.duration)));
            return "已看 " + pct + "%";
        }
        if (e.position > 0) return "已看 " + formatHistoryDuration(e.position);
        return "刚刚观看";
    }

    private static String historyTimeSummary(WatchHistory.Entry e) {
        String ep = e.episode == null ? "" : e.episode.trim();
        if (e.complete()) return ep.isEmpty() ? "已看完" : ep + " · 已看完";
        if (e.duration > 0)
            return formatHistoryDuration(e.position) + " / " + formatHistoryDuration(e.duration);
        if (e.position > 0) return "观看至 " + formatHistoryDuration(e.position);
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
                            final boolean wasCorrupted =
                                    WatchHistory.isCorrupted()
                                            || a.prefs.getBoolean(
                                                    WatchHistory.CORRUPTED_PREF, false);
                            final List<WatchHistory.Entry> prev =
                                    wasCorrupted
                                            ? java.util.Collections.emptyList()
                                            : a.watchHistory();
                            a.clearWatchHistory(
                                    () -> {
                                        if (!wasCorrupted) {
                                            CloudSyncDialog.onHistoryCleared(a, prev);
                                        }
                                        a.refresh();
                                    });
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
                                final String entryKey = e.key();
                                a.removeWatchHistory(
                                        entryKey,
                                        () -> {
                                            CloudSyncDialog.onHistoryDeleted(a, entryKey);
                                            a.refresh();
                                        });
                            }
                        })
                .setNegativeButton("返回", null)
                .show();
    }

    /**
     * Per-open timing breakdown captured on {@link #historyPage(MainActivity)} using monotonic
     * device time ({@link SystemClock#elapsedRealtimeNanos()}) so probes can separate card
     * creation, layout, poster binding, first frame draw, and first-card focusable readiness.
     */
    static final class HistoryOpenProfile {
        final long enterNs;
        long entriesReadNs;
        long headerDoneNs;
        long gridAttachNs;
        long firstPreDrawNs;
        long firstFramePostedNs;
        long firstCardFocusedNs;
        long firstCardFocusedMonoNs;
        String firstCardWindowIdentity = "";
        long createHoldersTotalNs;
        long bindHoldersTotalNs;
        long textMeasureTotalNs;
        long shaderApplyTotalNs;
        long posterCacheHitTotalNs;
        int entryCount;
        int holdersCreated;
        int holdersBound;
        int posterCacheHits;
        int posterDeferredCount;
        boolean reusedPool;
        boolean reusedHost;
        String firstCardTag = "";

        HistoryOpenProfile(long enterNs) {
            this.enterNs = enterNs;
        }
    }

    static volatile HistoryOpenProfile lastHistoryOpenProfile;

    private static final class PreparedHistoryText {
        final String titleText;
        final String subText;
        final String epText;
        final float badgeTextW;
        final String progText;
        final String contentDesc;

        PreparedHistoryText(
                String titleText,
                String subText,
                String epText,
                float badgeTextW,
                String progText,
                String contentDesc) {
            this.titleText = titleText;
            this.subText = subText;
            this.epText = epText;
            this.badgeTextW = badgeTextW;
            this.progText = progText;
            this.contentDesc = contentDesc;
        }
    }

    private static final java.util.concurrent.ConcurrentHashMap<String, PreparedHistoryText>
            PREPARED_TEXT_CACHE = new java.util.concurrent.ConcurrentHashMap<>();

    private static final Object THEME_LOCK = new Object();

    /** Single lightweight leaf view for TV History header (replaces 3 TextViews + 2-pass LinearLayout). */
    private static final class TvHistoryHeaderView extends View {
        private final TvHistoryCardTheme t;
        private String summaryText = "";

        TvHistoryHeaderView(MainActivity a, TvHistoryCardTheme theme) {
            super(a);
            this.t = theme;
        }

        void setSummaryText(String text) {
            String next = text == null ? "" : text;
            if (!next.equals(summaryText)) {
                summaryText = next;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            canvas.drawText("CONTINUE WATCHING", 0f, t.headerEyeBaseline, t.headerEyePaint);
            canvas.drawText("观看历史", 0f, t.headerTitleBaseline, t.headerTitlePaint);
            if (!summaryText.isEmpty()) {
                canvas.drawText(
                        summaryText,
                        t.headerSummaryLeft,
                        t.headerSummaryBaseline,
                        t.headerSummaryPaint);
            }
        }
    }

    private static final class TvHistoryPageHost {
        final FrameLayout root;
        final LinearLayout body;
        final TvHistoryHeaderView headerView;
        final RecyclerView grid;
        final GridLayoutManager lm;
        final TvHistoryGridAdapter adapter;
        final RecyclerView.RecycledViewPool pool;
        final TvHistoryCardTheme theme;
        final int columns;
        final Runnable attachHeaderActions;
        boolean headerActionsAttached;
        boolean layoutWatcherAttached;
        String lastFingerprint = "";

        TvHistoryPageHost(
                FrameLayout root,
                LinearLayout body,
                TvHistoryHeaderView headerView,
                Runnable attachHeaderActions,
                RecyclerView grid,
                GridLayoutManager lm,
                TvHistoryGridAdapter adapter,
                RecyclerView.RecycledViewPool pool,
                TvHistoryCardTheme theme,
                int columns) {
            this.root = root;
            this.body = body;
            this.headerView = headerView;
            this.attachHeaderActions = attachHeaderActions;
            this.grid = grid;
            this.lm = lm;
            this.adapter = adapter;
            this.pool = pool;
            this.theme = theme;
            this.columns = columns;
        }

        void ensureHeaderActionsDeferred(MainActivity a) {
            if (headerActionsAttached || attachHeaderActions == null || root == null) return;
            headerActionsAttached = true;
            root.postDelayed(
                    () -> {
                        if (!a.isFinishing()
                                && !(android.os.Build.VERSION.SDK_INT >= 17 && a.isDestroyed())) {
                            attachHeaderActions.run();
                        }
                    },
                    240L);
        }

        void setSummaryText(String text) {
            if (headerView != null) {
                headerView.setSummaryText(text);
            }
        }

        TvHistoryCardView firstVisibleCard() {
            View child = lm.findViewByPosition(0);
            if (child instanceof TvHistoryCardView && grid.getChildAdapterPosition(child) == 0) {
                return (TvHistoryCardView) child;
            }
            if (grid.getChildCount() > 0 && grid.getChildAt(0) instanceof TvHistoryCardView) {
                return (TvHistoryCardView) grid.getChildAt(0);
            }
            return null;
        }

        TvHistoryCardView findExactCardAtPosition(int targetPosition, String expectedTag) {
            View child = lm.findViewByPosition(targetPosition);
            if (!(child instanceof TvHistoryCardView)) return null;
            if (grid.getChildAdapterPosition(child) != targetPosition) return null;
            if (expectedTag != null && !expectedTag.equals(child.getTag())) return null;
            return (TvHistoryCardView) child;
        }
    }

    static void invalidateTvHistoryHost(MainActivity a) {
        if (a != null && a.tvHistoryHostCache instanceof TvHistoryPageHost) {
            ((TvHistoryPageHost) a.tvHistoryHostCache).lastFingerprint = "";
        }
        TvHistoryPageHost existing = tvHistoryHostRef == null ? null : tvHistoryHostRef.get();
        if (existing != null) {
            existing.lastFingerprint = "";
        }
        PREPARED_TEXT_CACHE.clear();
    }

    private static WeakReference<RecyclerView.RecycledViewPool> tvHistoryPoolRef;
    private static int tvHistoryPoolActivityId;
    private static int tvHistoryPoolKey;
    private static volatile WeakReference<TvHistoryCardTheme> tvHistoryThemeRef;
    private static volatile int tvHistoryThemeActivityId;
    private static volatile int tvHistoryThemeKey;
    private static WeakReference<TvHistoryPageHost> tvHistoryHostRef;
    private static int tvHistoryHostActivityId;
    private static int tvHistoryHostKey;

    private static TvHistoryCardTheme obtainTvHistoryTheme(
            MainActivity a, int cardW, int artW, int artH) {
        int actId = System.identityHashCode(a);
        int sdBits = Float.floatToIntBits(a.getResources().getDisplayMetrics().scaledDensity);
        int key = (((cardW * 31 + artW) * 31 + artH) * 31) + sdBits;
        // Lock-free fast read so the UI thread NEVER stalls behind background prewarm!
        TvHistoryCardTheme existing = tvHistoryThemeRef == null ? null : tvHistoryThemeRef.get();
        if (existing != null && tvHistoryThemeActivityId == actId && tvHistoryThemeKey == key) {
            return existing;
        }
        TvHistoryCardTheme created = new TvHistoryCardTheme(a, cardW, artW, artH);
        synchronized (THEME_LOCK) {
            TvHistoryCardTheme raced = tvHistoryThemeRef == null ? null : tvHistoryThemeRef.get();
            if (raced != null && tvHistoryThemeActivityId == actId && tvHistoryThemeKey == key) {
                return raced;
            }
            tvHistoryThemeRef = new WeakReference<>(created);
            tvHistoryThemeActivityId = actId;
            tvHistoryThemeKey = key;
            PREPARED_TEXT_CACHE.clear();
            return created;
        }
    }

    /**
     * Pre-computes {@link TvHistoryCardTheme} paints/atlases, top-12 card text measurements, and
     * RecyclerView ART class verification on a dedicated daemon thread (never queued behind
     * startup config/Home I/O on {@code a.worker}), then warms ONLY an empty zero-child
     * {@link TvHistoryPageHost} shell after Home's first frame while {@code startupIntro} is on
     * screen so immediate cold entry into Watch History stays well below 50 ms on all frames with
     * {@code grid_children == 0} and zero Home startup delay.
     */
    static void prewarmTvHistoryThemeAsync(final MainActivity a) {
        if (a == null || !a.isTvDevice() || a.privateMode) return;
        try {
            Thread t =
                    new Thread(
                            () -> {
                                try {
                                    Class.forName(RecyclerView.class.getName());
                                    Class.forName(GridLayoutManager.class.getName());
                                    Class.forName(TvHistoryPageHost.class.getName());
                                    Class.forName(TvHistoryHeaderView.class.getName());
                                    Class.forName(TvHistoryCardTheme.class.getName());
                                    Class.forName(TvHistoryCardView.class.getName());
                                    Class.forName(TvHistoryCardHolder.class.getName());
                                    Class.forName(TvHistoryGridAdapter.class.getName());
                                    Class.forName(TvFocusFrame.class.getName());
                                    final int columns =
                                            Math.max(
                                                    4,
                                                    Math.min(
                                                            6,
                                                            a.prefs.getInt(Prefs.HOME_COLUMNS, 6)));
                                    final int availPx =
                                            Math.max(a.dp(720), a.windowWidth() - a.dp(92));
                                    final int cellPx = Math.max(a.dp(116), availPx / columns);
                                    final int sideMargin = a.dp(4);
                                    final int padH = a.dp(5);
                                    final int cardW = Math.max(a.dp(108), cellPx - sideMargin * 2);
                                    final int artWPx = Math.max(a.dp(100), cardW - padH * 2);
                                    final int artHPx = Math.round(artWPx * 1.5f);
                                    final int gridH =
                                            Math.max(
                                                    a.dp(360),
                                                    a.getResources()
                                                                    .getDisplayMetrics()
                                                                    .heightPixels
                                                            - a.dp(112));
                                    final TvHistoryCardTheme theme =
                                            obtainTvHistoryTheme(a, cardW, artWPx, artHPx);
                                    theme.ensureFocusCardCornerAtlas();
                                    theme.ensureScrimBitmap();
                                    theme.ensureCornerAtlas(false);
                                    theme.ensureCornerAtlas(true);
                                    theme.progTextPaint.measureText("已看 99% 已看完 刚刚观看");
                                    theme.headerEyePaint.measureText("CONTINUE WATCHING");
                                    theme.headerTitlePaint.measureText("观看历史");
                                    theme.headerSummaryPaint.measureText(
                                            "31 部观看记录 · 确认继续观看，长按确认或按菜单键管理");
                                    theme.subTextWarmup();
                                    List<WatchHistory.Entry> entries = a.watchHistory();
                                    int cap = Math.min(entries.size(), columns * 2);
                                    for (int i = 0; i < cap; i++) {
                                        prewarmPreparedText(theme, entries.get(i));
                                    }
                                    // Once theme & ART classes are verified off-thread, attach &
                                    // pre-layout ONLY the empty RecyclerView host shell (0 entries,
                                    // 0 grid children) and pre-populate 6 properly-typed
                                    // (viewType=0) recycled empty card holders in tiny idle slices
                                    // right after Home's initial frame so fast cold DPAD_CENTER
                                    // never pays RecyclerView/Button/ViewHolder construction inside
                                    // deliverInputEvent or Frame 1 layout while keeping
                                    // grid_children == 0.
                                    if (a.ui != null) {
                                        final int[] tries = {0};
                                        final Runnable warmShell =
                                                new Runnable() {
                                                    @Override
                                                    public void run() {
                                                        if (a.isFinishing()
                                                                || (android.os.Build.VERSION.SDK_INT
                                                                                >= 17
                                                                        && a.isDestroyed())
                                                                || a.privateMode
                                                                || a.tvHistoryHostCache != null) {
                                                            return;
                                                        }
                                                        if (a.tvStage == null
                                                                || a.tvStage.getWidth() <= 0) {
                                                            if (tries[0]++ < 6) {
                                                                a.ui.postDelayed(this, 50L);
                                                            }
                                                            return;
                                                        }
                                                        try {
                                                            final TvHistoryPageHost shell =
                                                                    obtainOrCreateTvHistoryHost(
                                                                            a, columns, theme,
                                                                            gridH, null);
                                                            a.attachPrewarmedHistoryRoot(
                                                                    shell.root);
                                                            a.layoutPrewarmedHistoryRoot(
                                                                    shell.root);
                                                            final int poolTarget =
                                                                    Math.min(6, columns);
                                                            final Runnable fillPool =
                                                                    new Runnable() {
                                                                        @Override
                                                                        public void run() {
                                                                            if (a.isFinishing()
                                                                                    || (android.os
                                                                                                            .Build
                                                                                                            .VERSION
                                                                                                            .SDK_INT
                                                                                                    >= 17
                                                                                            && a
                                                                                                    .isDestroyed())
                                                                                    || a.privateMode) {
                                                                                return;
                                                                            }
                                                                            if (shell.grid
                                                                                            .getChildCount()
                                                                                    > 0) {
                                                                                return;
                                                                            }
                                                                            int cur =
                                                                                    shell.pool
                                                                                            .getRecycledViewCount(
                                                                                                    0);
                                                                            int add =
                                                                                    Math.min(
                                                                                            3,
                                                                                            Math
                                                                                                    .max(
                                                                                                            0,
                                                                                                            poolTarget
                                                                                                                    - cur));
                                                                            for (int k = 0;
                                                                                    k < add;
                                                                                    k++) {
                                                                                shell.pool
                                                                                        .putRecycledView(
                                                                                                shell
                                                                                                        .adapter
                                                                                                        .createViewHolder(
                                                                                                                shell.grid,
                                                                                                                0));
                                                                            }
                                                                            if (shell.pool
                                                                                            .getRecycledViewCount(
                                                                                                    0)
                                                                                    < poolTarget) {
                                                                                a.ui.postDelayed(
                                                                                        this, 24L);
                                                                            }
                                                                        }
                                                                    };
                                                            a.ui.postDelayed(fillPool, 20L);
                                                        } catch (Throwable ignored) {
                                                        }
                                                    }
                                                };
                                        a.ui.postDelayed(warmShell, 50L);
                                    }
                                } catch (Throwable ignored) {
                                }
                            },
                            "tv-history-prewarm");
            t.setDaemon(true);
            t.setPriority(Thread.NORM_PRIORITY - 1);
            t.start();
        } catch (Throwable ignored) {
        }
    }

    private static RecyclerView.RecycledViewPool obtainTvHistoryPool(
            MainActivity a, int columns, int cardW, int cardH, HistoryOpenProfile profile) {
        int actId = System.identityHashCode(a);
        int key = (columns * 31 + cardW) * 31 + cardH;
        RecyclerView.RecycledViewPool existing =
                tvHistoryPoolRef == null ? null : tvHistoryPoolRef.get();
        if (existing != null && tvHistoryPoolActivityId == actId && tvHistoryPoolKey == key) {
            if (profile != null) profile.reusedPool = true;
            return existing;
        }
        RecyclerView.RecycledViewPool pool = new RecyclerView.RecycledViewPool();
        pool.setMaxRecycledViews(0, Math.max(18, columns * 3));
        tvHistoryPoolRef = new WeakReference<>(pool);
        tvHistoryPoolActivityId = actId;
        tvHistoryPoolKey = key;
        return pool;
    }

    private static TvHistoryPageHost obtainOrCreateTvHistoryHost(
            final MainActivity a,
            final int columns,
            final TvHistoryCardTheme theme,
            final int gridH,
            final HistoryOpenProfile profile) {
        int actId = System.identityHashCode(a);
        int sdBits = Float.floatToIntBits(a.getResources().getDisplayMetrics().scaledDensity);
        int key =
                ((((((columns * 31 + theme.cardW) * 31 + theme.cardH) * 31 + gridH) * 31
                                        + (a.privateMode ? 1 : 0))
                                * 31)
                        + sdBits);
        TvHistoryPageHost existing =
                a.tvHistoryHostCache instanceof TvHistoryPageHost
                        ? (TvHistoryPageHost) a.tvHistoryHostCache
                        : (tvHistoryHostRef == null ? null : tvHistoryHostRef.get());
        if (existing != null && tvHistoryHostActivityId == actId && tvHistoryHostKey == key) {
            if (profile != null) {
                profile.reusedHost = true;
                profile.reusedPool = true;
            }
            return existing;
        }
        if (existing != null
                && existing.root != null
                && existing.root.getParent() instanceof ViewGroup) {
            if (existing.root != a.root) {
                ((ViewGroup) existing.root.getParent()).removeView(existing.root);
            }
        }

        FrameLayout hostRoot = new FrameLayout(a);
        hostRoot.setClipChildren(false);
        hostRoot.setClipToPadding(false);
        hostRoot.setBackgroundColor(0xff0d0f14);

        LinearLayout hostBody = a.vertical();
        hostBody.setClipChildren(false);
        hostBody.setClipToPadding(false);
        hostBody.setPadding(a.dp(46), a.dp(24), a.dp(46), a.dp(18));
        hostRoot.addView(hostBody, new FrameLayout.LayoutParams(-1, -1));

        FrameLayout headerBox = new FrameLayout(a);
        headerBox.setClipChildren(false);
        headerBox.setClipToPadding(false);
        TvHistoryHeaderView headerView = new TvHistoryHeaderView(a, theme);
        headerBox.addView(headerView, new FrameLayout.LayoutParams(-1, -1));

        final LinearLayout actionsRow = a.row();
        actionsRow.setClipChildren(false);
        actionsRow.setClipToPadding(false);
        actionsRow.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout.LayoutParams actLp =
                new FrameLayout.LayoutParams(-2, a.dp(40), Gravity.END | Gravity.BOTTOM);
        actLp.bottomMargin = a.dp(6);
        headerBox.addView(actionsRow, actLp);

        final Runnable attachHeaderActions =
                () -> {
                    if (actionsRow.getChildCount() > 0) return;
                    if (!a.privateMode) {
                        Button syncBtn =
                                a.navButton(
                                        "多端云同步",
                                        "history-cloud-sync",
                                        () -> CloudSyncDialog.show(a, a::refresh));
                        LinearLayout.LayoutParams syncLp =
                                new LinearLayout.LayoutParams(-2, a.dp(36));
                        syncLp.rightMargin = a.dp(8);
                        actionsRow.addView(syncBtn, syncLp);
                    }
                    Button clearBtn =
                            a.navButton("清空观看历史", "history-clear", () -> confirmClearHistory(a));
                    actionsRow.addView(clearBtn, new LinearLayout.LayoutParams(-2, a.dp(36)));
                };
        // Defer the two secondary top-right header pill buttons past Frame 1 on first display so
        // Frame 1 draws ONLY TvHistoryHeaderView + card_01 with minimal DisplayList & GPU work.
        LinearLayout.LayoutParams hbLp = new LinearLayout.LayoutParams(-1, theme.headerTotalH);
        hbLp.bottomMargin = a.dp(8);
        hostBody.addView(headerBox, hbLp);

        RecyclerView grid = new RecyclerView(a);
        grid.setTag("history-tv-grid");
        grid.setClipChildren(false);
        grid.setClipToPadding(false);
        grid.setPadding(0, a.dp(4), 0, a.dp(24));
        grid.setHasFixedSize(true);
        grid.setItemAnimator(null);
        grid.setFocusable(true);
        grid.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
        final TvHistoryGridAdapter adapter =
                new TvHistoryGridAdapter(
                        a,
                        java.util.Collections.emptyList(),
                        theme,
                        columns,
                        a.generation,
                        profile);
        GridLayoutManager lm =
                new GridLayoutManager(a, columns) {
                    @Override
                    public void onLayoutCompleted(RecyclerView.State state) {
                        super.onLayoutCompleted(state);
                        adapter.onGridLayoutCompleted(this);
                    }
                };
        lm.setItemPrefetchEnabled(false);
        lm.setInitialPrefetchItemCount(0);
        lm.setRecycleChildrenOnDetach(false);
        grid.setLayoutManager(lm);
        RecyclerView.RecycledViewPool pool =
                obtainTvHistoryPool(a, columns, theme.cardW, theme.cardH, profile);
        grid.setRecycledViewPool(pool);
        grid.setAdapter(adapter);
        hostBody.addView(grid, new LinearLayout.LayoutParams(-1, gridH));

        TvHistoryPageHost host =
                new TvHistoryPageHost(
                        hostRoot,
                        hostBody,
                        headerView,
                        attachHeaderActions,
                        grid,
                        lm,
                        adapter,
                        pool,
                        theme,
                        columns);
        a.tvHistoryHostCache = host;
        if (!a.privateMode) {
            a.retainedHistoryRoot = hostRoot;
        }
        tvHistoryHostRef = new WeakReference<>(host);
        tvHistoryHostActivityId = actId;
        tvHistoryHostKey = key;
        return host;
    }

    private static TvHistoryCardHolder createTvHistoryCardHolder(
            final MainActivity a, final TvHistoryCardTheme theme) {
        final TvHistoryCardView card = new TvHistoryCardView(a, theme);
        final TvHistoryCardHolder holder = new TvHistoryCardHolder(card);
        card.setOnClickListener(
                v -> {
                    if (holder.bound != null) resumeHistory(a, holder.bound);
                });
        card.setOnLongClickListener(
                v -> {
                    if (holder.bound != null) manageHistoryEntry(a, holder.bound);
                    return true;
                });
        card.setOnKeyListener(
                (v, key, event) -> {
                    if (key == KeyEvent.KEYCODE_DPAD_DOWN
                            && event.getAction() == KeyEvent.ACTION_DOWN
                            && v.getParent() instanceof RecyclerView) {
                        RecyclerView.Adapter<?> ad = ((RecyclerView) v.getParent()).getAdapter();
                        if (ad instanceof TvHistoryGridAdapter) {
                            ((TvHistoryGridAdapter) ad).finishStagingImmediately();
                        }
                    }
                    if (key == KeyEvent.KEYCODE_MENU) {
                        if (event.getAction() == KeyEvent.ACTION_UP && holder.bound != null) {
                            manageHistoryEntry(a, holder.bound);
                        }
                        return true;
                    }
                    return false;
                });
        RecyclerView.LayoutParams lp = new RecyclerView.LayoutParams(theme.cardW, theme.cardH);
        lp.setMargins(theme.marginH, theme.marginTop, theme.marginH, theme.marginBottom);
        card.setLayoutParams(lp);
        return holder;
    }

    private static void appendLengthPrefixed(StringBuilder sb, String value) {
        if (value == null) {
            sb.append("0:");
            return;
        }
        sb.append(value.length()).append(':').append(value).append('\0');
    }

    private static String historyEntriesFingerprint(List<WatchHistory.Entry> entries) {
        if (entries == null || entries.isEmpty()) return "";
        StringBuilder sb = new StringBuilder(entries.size() * 128);
        sb.append(entries.size()).append('\0');
        for (int i = 0; i < entries.size(); i++) {
            WatchHistory.Entry e = entries.get(i);
            if (e == null) {
                sb.append("null\0");
                continue;
            }
            appendLengthPrefixed(sb, e.site);
            appendLengthPrefixed(sb, e.id);
            appendLengthPrefixed(sb, e.title);
            appendLengthPrefixed(sb, e.poster);
            appendLengthPrefixed(sb, e.line);
            appendLengthPrefixed(sb, e.episode);
            sb.append(e.index)
                    .append('\0')
                    .append(e.position)
                    .append('\0')
                    .append(e.duration)
                    .append('\0')
                    .append(e.updated)
                    .append('\n');
        }
        return sb.toString();
    }

    /**
     * Pre-warms {@link TvHistoryCardTheme}, the reusable {@link TvHistoryPageHost}, pooled {@link
     * TvHistoryCardHolder} views, disk-cached poster bitmaps into RAM, and an offscreen pre-laid
     * initial grid snapshot in tiny non-blocking idle slices during Home idle so the very first
     * "历史" open hits the warm retained-host swap path with zero cold layout stall.
     */
    static void prewarmTvHistoryOnIdle(final MainActivity a) {
        if (a == null || !a.isTvDevice() || a.privateMode || a.ui == null) return;
        // Verify RecyclerView + History card classes on a background thread during startup so
        // fast cold entry into Watch History never pays 30-40 ms of ART class verification on UI.
        try {
            a.worker.execute(
                    () -> {
                        try {
                            Class.forName(RecyclerView.class.getName());
                            Class.forName(GridLayoutManager.class.getName());
                            Class.forName(TvHistoryCardTheme.class.getName());
                            Class.forName(TvHistoryCardView.class.getName());
                            Class.forName(TvHistoryGridAdapter.class.getName());
                        } catch (Throwable ignored) {
                        }
                    });
        } catch (Throwable ignored) {
        }
        final int homeGen = a.generation;
        final boolean[] readyAfterSplash = {false};
        final Runnable kickoff =
                new Runnable() {
                    @Override
                    public void run() {
                        if (a.isFinishing()
                                || (android.os.Build.VERSION.SDK_INT >= 17 && a.isDestroyed())
                                || a.generation != homeGen
                                || a.player != null
                                || a.sourceDialog != null
                                || a.current == null
                                || !a.current.home) {
                            return;
                        }
                        if (a.startupIntro != null) {
                            a.ui.postDelayed(this, 100L);
                            return;
                        }
                        if (!readyAfterSplash[0]) {
                            readyAfterSplash[0] = true;
                            a.ui.postDelayed(this, 700L);
                            return;
                        }
                        try {
                            final int columns =
                                    Math.max(4, Math.min(6, a.prefs.getInt(Prefs.HOME_COLUMNS, 6)));
                            final int availPx = Math.max(a.dp(720), a.windowWidth() - a.dp(92));
                            final int cellPx = Math.max(a.dp(116), availPx / columns);
                            final int sideMargin = a.dp(4);
                            final int padH = a.dp(5);
                            final int cardW = Math.max(a.dp(108), cellPx - sideMargin * 2);
                            final int artWPx = Math.max(a.dp(100), cardW - padH * 2);
                            final int artHPx = Math.round(artWPx * 1.5f);
                            final int gridH =
                                    Math.max(
                                            a.dp(360),
                                            a.getResources().getDisplayMetrics().heightPixels
                                                    - a.dp(112));
                            final TvHistoryCardTheme theme =
                                    obtainTvHistoryTheme(a, cardW, artWPx, artHPx);
                            theme.prepareBitmapsAsync(a);
                            final TvHistoryPageHost host =
                                    obtainOrCreateTvHistoryHost(a, columns, theme, gridH, null);
                            a.attachPrewarmedHistoryRoot(host.root);
                            final RecyclerView.RecycledViewPool pool = host.pool;
                            final List<WatchHistory.Entry> entries = a.watchHistory();
                            final int visibleCap = Math.min(entries.size(), columns * 2);
                            // Prime Minikin glyph caches for common history badge/time characters.
                            theme.progTextPaint.measureText("已看 99% 已看完 刚刚观看");
                            theme.subTextWarmup();
                            final int target = Math.min(12, Math.max(columns, visibleCap));
                            final int[] slice = {0};
                            final int[] textCursor = {0};
                            Runnable step =
                                    new Runnable() {
                                        @Override
                                        public void run() {
                                            if (a.isFinishing()
                                                    || (android.os.Build.VERSION.SDK_INT >= 17
                                                            && a.isDestroyed())
                                                    || a.player != null
                                                    || a.sourceDialog != null
                                                    || a.current == null
                                                    || !a.current.home) {
                                                return;
                                            }
                                            int now = pool.getRecycledViewCount(0);
                                            int add = Math.min(3, Math.max(0, target - now));
                                            for (int k = 0; k < add; k++) {
                                                pool.putRecycledView(
                                                        host.adapter.createViewHolder(
                                                                host.grid, 0));
                                            }
                                            int textEnd = Math.min(visibleCap, textCursor[0] + 3);
                                            for (int idx = textCursor[0]; idx < textEnd; idx++) {
                                                prewarmPreparedText(theme, entries.get(idx));
                                            }
                                            textCursor[0] = textEnd;
                                            slice[0]++;
                                            if ((pool.getRecycledViewCount(0) < target
                                                            || textCursor[0] < visibleCap)
                                                    && slice[0] < 6) {
                                                a.ui.postDelayed(this, 24L);
                                                return;
                                            }
                                            a.ui.postDelayed(
                                                    () -> {
                                                        if (a.isFinishing()
                                                                || (android.os.Build.VERSION.SDK_INT
                                                                                >= 17
                                                                        && a.isDestroyed())
                                                                || a.player != null
                                                                || a.sourceDialog != null
                                                                || a.current == null
                                                                || !a.current.home) {
                                                            return;
                                                        }
                                                        try {
                                                            List<WatchHistory.Entry> curEntries =
                                                                    a.watchHistory();
                                                            if (curEntries.isEmpty()) return;
                                                            String fp =
                                                                    historyEntriesFingerprint(
                                                                            curEntries);
                                                            if (!fp.equals(host.lastFingerprint)
                                                                    || host.grid.getChildCount()
                                                                            == 0) {
                                                                String summaryText =
                                                                        curEntries.size()
                                                                                + " 部观看记录 · 确认继续观看，长按确认或按菜单键管理";
                                                                host.setSummaryText(summaryText);
                                                                host.lastFingerprint = fp;
                                                                host.adapter
                                                                        .replaceEntriesForPrewarm(
                                                                                curEntries,
                                                                                a.generation);
                                                                host.grid.stopScroll();
                                                                host.lm.scrollToPositionWithOffset(
                                                                        0, 0);
                                                                a.layoutPrewarmedHistoryRoot(
                                                                        host.root);
                                                            }
                                                            int preloadCap =
                                                                    Math.min(curEntries.size(), 3);
                                                            for (int i = 0; i < preloadCap; i++) {
                                                                final WatchHistory.Entry e =
                                                                        curEntries.get(i);
                                                                if (e != null
                                                                        && e.poster != null
                                                                        && !e.poster.isEmpty()) {
                                                                    a.ui.postDelayed(
                                                                            () -> {
                                                                                if (!a.isFinishing()
                                                                                        && a.generation
                                                                                                == homeGen
                                                                                        && a.current
                                                                                                != null
                                                                                        && a.current
                                                                                                .home) {
                                                                                    ImageLoader
                                                                                            .preloadDiskCachedPoster(
                                                                                                    a,
                                                                                                    e.poster,
                                                                                                    artWPx,
                                                                                                    artHPx);
                                                                                }
                                                                            },
                                                                            i * 45L);
                                                                }
                                                            }
                                                        } catch (Throwable ignored) {
                                                        }
                                                    },
                                                    32L);
                                        }
                                    };
                            step.run();
                        } catch (Throwable ignored) {
                        }
                    }
                };
        a.ui.postDelayed(kickoff, 100L);
    }

    static void historyPage(MainActivity a) {
        final long enterNs = SystemClock.elapsedRealtimeNanos();
        final HistoryOpenProfile profile = new HistoryOpenProfile(enterNs);
        lastHistoryOpenProfile = profile;
        a.pendingHistoryMigration = null;
        final List<WatchHistory.Entry> entries = a.watchHistory();
        profile.entriesReadNs = SystemClock.elapsedRealtimeNanos();
        profile.entryCount = entries.size();
        if (entries.isEmpty()) {
            TvHistoryPageHost oldHost = tvHistoryHostRef == null ? null : tvHistoryHostRef.get();
            if (oldHost != null) oldHost.lastFingerprint = "";
            a.renderPage("观看历史", "CONTINUE WATCHING");
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
            final int columns = Math.max(4, Math.min(6, a.prefs.getInt(Prefs.HOME_COLUMNS, 6)));
            final int availPx = Math.max(a.dp(720), a.windowWidth() - a.dp(92));
            final int cellPx = Math.max(a.dp(116), availPx / columns);
            final int sideMargin = a.dp(4);
            final int padH = a.dp(5);
            final int cardW = Math.max(a.dp(108), cellPx - sideMargin * 2);
            final int artWPx = Math.max(a.dp(100), cardW - padH * 2);
            final int artHPx = Math.round(artWPx * 1.5f);
            final TvHistoryCardTheme theme = obtainTvHistoryTheme(a, cardW, artWPx, artHPx);
            theme.prepareBitmapsAsync(a);
            final int gridH =
                    Math.max(
                            a.dp(360),
                            a.getResources().getDisplayMetrics().heightPixels - a.dp(112));
            final TvHistoryPageHost host =
                    obtainOrCreateTvHistoryHost(a, columns, theme, gridH, profile);
            final boolean attachWatcher = !host.layoutWatcherAttached;
            host.layoutWatcherAttached = true;
            a.presentDirectTvRoot(host.root, host.body, attachWatcher);
            host.ensureHeaderActionsDeferred(a);
            String summaryText = entries.size() + " 部观看记录 · 确认继续观看，长按确认或按菜单键管理";
            host.setSummaryText(summaryText);
            profile.headerDoneNs = SystemClock.elapsedRealtimeNanos();

            final boolean hasExistingChildren = host.grid.getChildCount() > 0;
            final String fingerprint =
                    hasExistingChildren ? historyEntriesFingerprint(entries) : "";
            final boolean freshOpen = a.current == null || a.current.focus == null;
            final String expectedFirstTag = "history:" + entries.get(0).key();
            final String savedFocusTag = (!freshOpen && a.current != null) ? a.current.focus : null;
            final int savedFocusPos;
            if (savedFocusTag != null && savedFocusTag.startsWith("history:")) {
                int foundPos = -1;
                for (int idx = 0; idx < entries.size(); idx++) {
                    if (savedFocusTag.equals("history:" + entries.get(idx).key())) {
                        foundPos = idx;
                        break;
                    }
                }
                savedFocusPos = foundPos;
            } else {
                savedFocusPos = -1;
            }
            final boolean unchanged =
                    hasExistingChildren
                            && fingerprint.equals(host.lastFingerprint)
                            && host.adapter.getItemCount() == entries.size();
            final RecyclerView grid = host.grid;
            final TvHistoryGridAdapter adapter = host.adapter;
            final int expectedGen = a.generation;
            if (unchanged) {
                adapter.rebindSession(entries, expectedGen, profile, grid);
                final boolean needsScrollToTop =
                        freshOpen && host.lm.findFirstCompletelyVisibleItemPosition() != 0;
                if (needsScrollToTop) {
                    grid.stopScroll();
                    host.lm.scrollToPositionWithOffset(0, 0);
                }
                // On first cold display after natural Home prewarm, defer cold poster GPU uploads
                // to Frame 2's 2-card postOnAnimation micro-waves so Mali-450 SyncStart/SwapBuffers
                // stays well under 50 ms even at worst-case vsync input phase. On same-process warm
                // re-open, posters are already resident on cv.posterBitmap and draw immediately in
                // one single frame.
                for (int c = 0, cnt = grid.getChildCount(); c < cnt; c++) {
                    View child = grid.getChildAt(c);
                    if (!(child instanceof TvHistoryCardView)) continue;
                    TvHistoryCardView cv = (TvHistoryCardView) child;
                    cv.openProfile = profile;
                    if (cv.posterBitmap != null && !cv.posterBitmap.isRecycled()) {
                        profile.posterCacheHits++;
                    } else {
                        int pos = grid.getChildAdapterPosition(cv);
                        if (pos >= 0 && pos < entries.size()) {
                            WatchHistory.Entry entry = entries.get(pos);
                            final long p0 = SystemClock.elapsedRealtimeNanos();
                            Bitmap bmp =
                                    ImageLoader.cachedPosterBitmap(
                                            a, entry.poster, theme.artW, theme.artH);
                            profile.posterCacheHitTotalNs +=
                                    (SystemClock.elapsedRealtimeNanos() - p0);
                            if (bmp != null || (entry.poster != null && !entry.poster.isEmpty())) {
                                RecyclerView.ViewHolder vh = grid.getChildViewHolder(cv);
                                if (vh instanceof TvHistoryCardHolder) {
                                    TvHistoryCardHolder th = (TvHistoryCardHolder) vh;
                                    profile.posterDeferredCount++;
                                    adapter.queueDeferredPoster(th, th.bindSeq, entry.poster, bmp);
                                }
                            }
                        }
                    }
                }
                TvHistoryCardView verifiedFirst =
                        (!needsScrollToTop)
                                ? host.findExactCardAtPosition(0, expectedFirstTag)
                                : null;
                a.tvInitialFocus = verifiedFirst != null ? verifiedFirst : grid;
                if (freshOpen
                        && verifiedFirst != null
                        && verifiedFirst.isAttachedToWindow()
                        && !verifiedFirst.hasFocus()) {
                    verifiedFirst.requestFocus();
                } else if (!freshOpen && savedFocusPos >= 0) {
                    TvHistoryCardView savedCard =
                            host.findExactCardAtPosition(savedFocusPos, savedFocusTag);
                    if (savedCard != null
                            && savedCard.isAttachedToWindow()
                            && !savedCard.hasFocus()) {
                        savedCard.requestFocus();
                    }
                }
            } else {
                host.lastFingerprint = fingerprint;
                adapter.pendingFreshFocusTag = freshOpen ? expectedFirstTag : null;
                adapter.replaceEntries(entries, expectedGen, profile, freshOpen);
                grid.stopScroll();
                if (!freshOpen && savedFocusPos > 0) {
                    host.lm.scrollToPosition(savedFocusPos);
                } else {
                    host.lm.scrollToPositionWithOffset(0, 0);
                }
                a.tvInitialFocus = grid;
            }
            profile.gridAttachNs = SystemClock.elapsedRealtimeNanos();

            grid.getViewTreeObserver()
                    .addOnPreDrawListener(
                            new ViewTreeObserver.OnPreDrawListener() {
                                @Override
                                public boolean onPreDraw() {
                                    if (grid.getViewTreeObserver().isAlive()) {
                                        grid.getViewTreeObserver().removeOnPreDrawListener(this);
                                    }
                                    if (a.generation == expectedGen) {
                                        if (freshOpen) {
                                            TvHistoryCardView c0 =
                                                    host.findExactCardAtPosition(
                                                            0, expectedFirstTag);
                                            if (c0 != null) {
                                                a.tvInitialFocus = c0;
                                                a.autoFocus = c0;
                                                if (c0.isAttachedToWindow() && !c0.hasFocus()) {
                                                    c0.requestFocus();
                                                }
                                            } else {
                                                grid.post(
                                                        () -> {
                                                            if (a.generation != expectedGen) return;
                                                            TvHistoryCardView late0 =
                                                                    host.findExactCardAtPosition(
                                                                            0, expectedFirstTag);
                                                            if (late0 != null
                                                                    && late0.isAttachedToWindow()) {
                                                                a.tvInitialFocus = late0;
                                                                a.autoFocus = late0;
                                                                if (!late0.hasFocus()) {
                                                                    late0.requestFocus();
                                                                }
                                                            }
                                                        });
                                            }
                                        } else if (savedFocusPos >= 0) {
                                            TvHistoryCardView savedCard =
                                                    host.findExactCardAtPosition(
                                                            savedFocusPos, savedFocusTag);
                                            if (savedCard != null
                                                    && savedCard.isAttachedToWindow()
                                                    && !savedCard.hasFocus()) {
                                                savedCard.requestFocus();
                                                a.autoFocus = savedCard;
                                            }
                                        }
                                    }
                                    if (profile.firstPreDrawNs == 0L) {
                                        profile.firstPreDrawNs = SystemClock.elapsedRealtimeNanos();
                                    }
                                    grid.post(
                                            () -> {
                                                if (profile.firstFramePostedNs == 0L) {
                                                    profile.firstFramePostedNs =
                                                            SystemClock.elapsedRealtimeNanos();
                                                }
                                                if (host.lastFingerprint == null
                                                        || host.lastFingerprint.isEmpty()) {
                                                    host.lastFingerprint =
                                                            historyEntriesFingerprint(entries);
                                                }
                                                adapter.flushDeferredPosters(grid);
                                            });
                                    return true;
                                }
                            });
            return;
        }
        a.renderPage("观看历史", "CONTINUE WATCHING");
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
                                final String entryKey = e.key();
                                a.removeWatchHistory(
                                        entryKey,
                                        () -> {
                                            CloudSyncDialog.onHistoryDeleted(a, entryKey);
                                            a.refresh();
                                        });
                            }));
            a.body.addView(line);
            a.gap(a.body, 8);
        }
    }

    /** Shared immutable paints and exact pixel geometry for single-view TV history cards. */
    private static final class TvHistoryCardTheme {
        final int cardW;
        final int cardH;
        final int padH;
        final int padTop;
        final int padBottom;
        final int artW;
        final int artH;
        final int marginH;
        final int marginTop;
        final int marginBottom;
        final float cardRadius;
        final float artRadius;
        final float badgeRadius;
        final float trackRadius;
        final int badgePadH;
        final int badgePadV;
        final int badgeMargin;
        final int overlayPadH;
        final int overlayPadBottom;
        final int trackH;
        final int trackTopGap;
        final int barInnerW;
        final int titleTopGap;
        final int subTopGap;
        final float titleBaselineOffset;
        final float titleLineH;
        final float subBaselineOffset;
        final float badgeBaselineOffset;
        final float badgeBoxH;
        final float progBaselineOffset;
        final float ellipsisTitleW;
        final float ellipsisSubW;
        final float ellipsisBadgeW;
        final float ellipsisProgW;
        final float ellipsisFallbackW;
        final float safeUpperTitleCharW;
        final float safeUpperSubCharW;
        final float safeUpperProgCharW;
        final float safeUpperBadgeCharW;
        final int scrimH;

        final Paint focusBgPaint = new Paint();
        final Paint focusRingFillPaint = new Paint();
        final Paint focusRingPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint placeholderBgPaint = new Paint();
        private volatile Bitmap scrimBitmap;
        final int cornerSizePx;
        final int cardCornerSizePx;
        final float focusStrokePx;
        private volatile Bitmap normalCornerAtlas;
        private volatile Bitmap focusedCornerAtlas;
        private volatile Bitmap focusCardCornerAtlas;
        private final java.util.concurrent.atomic.AtomicBoolean bitmapsPreparing =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        final Rect cornerSrcTl = new Rect();
        final Rect cornerSrcTr = new Rect();
        final Rect cornerSrcBl = new Rect();
        final Rect cornerSrcBr = new Rect();
        final Rect cardCornerSrcTl = new Rect();
        final Rect cardCornerSrcTr = new Rect();
        final Rect cardCornerSrcBl = new Rect();
        final Rect cardCornerSrcBr = new Rect();
        final TextPaint headerEyePaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final TextPaint headerTitlePaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final TextPaint headerSummaryPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final int headerTotalH;
        final float headerEyeBaseline;
        final float headerTitleBaseline;
        final float headerSummaryBaseline;
        final float headerSummaryLeft;
        final Paint badgeBgPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint trackPaint = new Paint();
        final Paint fillPaint = new Paint();
        final TextPaint fallbackPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final TextPaint badgeTextPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final TextPaint progTextPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final TextPaint titlePaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final TextPaint subPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        final float titleTextSize;
        final float subTextSize;
        final float progTextSize;
        final float badgeTextSize;

        TvHistoryCardTheme(MainActivity a, int cardW, int artW, int artH) {
            this.cardW = cardW;
            this.artW = artW;
            this.artH = artH;
            this.padH = a.dp(5);
            this.padTop = a.dp(5);
            this.padBottom = a.dp(8);
            this.marginH = a.dp(4);
            this.marginTop = a.dp(5);
            this.marginBottom = a.dp(14);
            this.cardRadius = a.dp(14);
            this.artRadius = a.dp(10);
            this.badgeRadius = a.dp(6);
            this.trackRadius = a.dp(2);
            this.badgePadH = a.dp(7);
            this.badgePadV = a.dp(3);
            this.badgeMargin = a.dp(6);
            this.overlayPadH = a.dp(8);
            this.overlayPadBottom = a.dp(7);
            this.trackH = Math.max(2, a.dp(3.5f));
            this.trackTopGap = a.dp(4);
            this.barInnerW = Math.max(a.dp(6), artW - overlayPadH * 2);
            this.titleTopGap = a.dp(8);
            this.subTopGap = a.dp(2);
            this.scrimH = Math.min(artH, a.dp(56));

            float scaledDensity = a.getResources().getDisplayMetrics().scaledDensity;
            this.badgeTextSize = 10.5f * scaledDensity;
            this.progTextSize = 10.5f * scaledDensity;
            this.titleTextSize = 13f * scaledDensity;
            this.subTextSize = 11f * scaledDensity;
            fallbackPaint.setColor(0x55ffffff);
            fallbackPaint.setTextSize(13f * scaledDensity);
            fallbackPaint.setTextAlign(Paint.Align.CENTER);

            badgeTextPaint.setColor(0xffedf1f7);
            badgeTextPaint.setTextSize(this.badgeTextSize);

            progTextPaint.setColor(0xfff3f5f9);
            progTextPaint.setTypeface(Typeface.DEFAULT_BOLD);
            progTextPaint.setTextSize(this.progTextSize);

            titlePaint.setColor(MainActivity.WHITE);
            titlePaint.setTextSize(this.titleTextSize);

            subPaint.setColor(MainActivity.MUTED);
            subPaint.setTextSize(this.subTextSize);

            Paint.FontMetrics fmTitle = titlePaint.getFontMetrics();
            Paint.FontMetrics fmSub = subPaint.getFontMetrics();
            Paint.FontMetrics fmBadge = badgeTextPaint.getFontMetrics();
            Paint.FontMetrics fmProg = progTextPaint.getFontMetrics();
            this.titleLineH = fmTitle.descent - fmTitle.ascent;
            int titleH = (int) Math.ceil(this.titleLineH);
            int subH = (int) Math.ceil(fmSub.descent - fmSub.ascent);
            this.titleBaselineOffset = -fmTitle.ascent;
            this.subBaselineOffset = -fmSub.ascent;
            this.badgeBaselineOffset = -fmBadge.ascent;
            this.badgeBoxH = (fmBadge.descent - fmBadge.ascent) + badgePadV * 2;
            this.progBaselineOffset = -fmProg.descent;
            float ellipsisRatio = titlePaint.measureText("…") / Math.max(1f, this.titleTextSize);
            this.ellipsisTitleW = ellipsisRatio * this.titleTextSize;
            this.ellipsisSubW = ellipsisRatio * this.subTextSize;
            this.ellipsisBadgeW = ellipsisRatio * this.badgeTextSize;
            this.ellipsisProgW = ellipsisRatio * this.progTextSize * 1.08f;
            this.ellipsisFallbackW = this.ellipsisTitleW;
            float wideRatio =
                    Math.max(titlePaint.measureText("W"), titlePaint.measureText("宽"))
                            / Math.max(1f, this.titleTextSize);
            this.safeUpperTitleCharW = wideRatio * this.titleTextSize * 1.08f;
            this.safeUpperSubCharW = wideRatio * this.subTextSize * 1.08f;
            this.safeUpperProgCharW = wideRatio * this.progTextSize * 1.14f;
            this.safeUpperBadgeCharW = wideRatio * this.badgeTextSize * 1.08f;
            this.cardH = padTop + artH + titleTopGap + titleH + subTopGap + subH + padBottom;

            focusBgPaint.setStyle(Paint.Style.FILL);
            focusBgPaint.setColor(0xff29292f);

            this.focusStrokePx = Math.max(2f, a.dp(2));
            focusRingFillPaint.setStyle(Paint.Style.FILL);
            focusRingFillPaint.setColor(0xf4ffffff);

            focusRingPaint.setStyle(Paint.Style.STROKE);
            focusRingPaint.setColor(0xf4ffffff);
            focusRingPaint.setStrokeWidth(this.focusStrokePx);

            placeholderBgPaint.setStyle(Paint.Style.FILL);
            placeholderBgPaint.setColor(0xff202530);

            headerEyePaint.setColor(0x998aa0c0);
            headerEyePaint.setTextSize(11f * scaledDensity);
            headerTitlePaint.setColor(MainActivity.WHITE);
            headerTitlePaint.setTypeface(Typeface.DEFAULT_BOLD);
            headerTitlePaint.setTextSize(26f * scaledDensity);
            headerSummaryPaint.setColor(MainActivity.MUTED);
            headerSummaryPaint.setTextSize(13f * scaledDensity);
            Paint.FontMetrics fmEye = headerEyePaint.getFontMetrics();
            Paint.FontMetrics fmHead = headerTitlePaint.getFontMetrics();
            Paint.FontMetrics fmSum = headerSummaryPaint.getFontMetrics();
            float eyeH = fmEye.descent - fmEye.ascent;
            float headH = fmHead.descent - fmHead.ascent;
            this.headerEyeBaseline = -fmEye.ascent;
            float headTop = eyeH + a.dp(2);
            this.headerTitleBaseline = headTop - fmHead.ascent;
            this.headerSummaryBaseline =
                    headTop + (headH - (fmSum.descent - fmSum.ascent)) * 0.55f - fmSum.ascent;
            this.headerSummaryLeft = headerTitlePaint.measureText("观看历史") + a.dp(18);
            this.headerTotalH = Math.max(a.dp(60), (int) Math.ceil(headTop + headH + a.dp(4)));

            this.cornerSizePx = Math.max(2, (int) Math.ceil(artRadius));
            cornerSrcTl.set(0, 0, cornerSizePx, cornerSizePx);
            cornerSrcTr.set(cornerSizePx, 0, cornerSizePx * 2, cornerSizePx);
            cornerSrcBl.set(0, cornerSizePx, cornerSizePx, cornerSizePx * 2);
            cornerSrcBr.set(cornerSizePx, cornerSizePx, cornerSizePx * 2, cornerSizePx * 2);
            this.cardCornerSizePx = Math.max(4, (int) Math.ceil(cardRadius));
            cardCornerSrcTl.set(0, 0, cardCornerSizePx, cardCornerSizePx);
            cardCornerSrcTr.set(cardCornerSizePx, 0, cardCornerSizePx * 2, cardCornerSizePx);
            cardCornerSrcBl.set(0, cardCornerSizePx, cardCornerSizePx, cardCornerSizePx * 2);
            cardCornerSrcBr.set(
                    cardCornerSizePx, cardCornerSizePx, cardCornerSizePx * 2, cardCornerSizePx * 2);
            // Scrim & corner atlas are built lazily when the first poster arrives (or during idle
            // prewarm) so completely cold Frame 1 does zero offscreen Bitmap software rendering.

            badgeBgPaint.setStyle(Paint.Style.FILL);
            badgeBgPaint.setColor(0xd814171f);

            trackPaint.setStyle(Paint.Style.FILL);
            trackPaint.setColor(0x3affffff);

            fillPaint.setStyle(Paint.Style.FILL);
            fillPaint.setColor(0xfff5f7fb);
        }

        Bitmap peekScrimBitmap() {
            Bitmap b = scrimBitmap;
            return (b != null && !b.isRecycled()) ? b : null;
        }

        Bitmap peekCornerAtlas(boolean focused) {
            Bitmap b = focused ? focusedCornerAtlas : normalCornerAtlas;
            return (b != null && !b.isRecycled()) ? b : null;
        }

        Bitmap peekFocusCardCornerAtlas() {
            Bitmap b = focusCardCornerAtlas;
            return (b != null && !b.isRecycled()) ? b : null;
        }

        Bitmap ensureFocusCardCornerAtlas() {
            Bitmap existing = focusCardCornerAtlas;
            if (existing != null && !existing.isRecycled()) return existing;
            try {
                int full = cardCornerSizePx * 2;
                Bitmap sheet = Bitmap.createBitmap(full, full, Bitmap.Config.ARGB_8888);
                Canvas c = new Canvas(sheet);
                float hs = focusStrokePx * 0.5f;
                Paint bgP = new Paint(Paint.ANTI_ALIAS_FLAG);
                bgP.setStyle(Paint.Style.FILL);
                bgP.setColor(0xff29292f);
                c.drawRoundRect(new RectF(0f, 0f, full, full), cardRadius, cardRadius, bgP);
                Paint stP = new Paint(Paint.ANTI_ALIAS_FLAG);
                stP.setStyle(Paint.Style.STROKE);
                stP.setStrokeWidth(focusStrokePx);
                stP.setColor(0xf4ffffff);
                c.drawRoundRect(
                        new RectF(hs, hs, full - hs, full - hs), cardRadius, cardRadius, stP);
                focusCardCornerAtlas = sheet;
                return sheet;
            } catch (Throwable ignored) {
                return null;
            }
        }

        void prepareBitmapsAsync(final MainActivity a) {
            if (peekScrimBitmap() != null
                    && peekCornerAtlas(false) != null
                    && peekCornerAtlas(true) != null
                    && peekFocusCardCornerAtlas() != null) {
                return;
            }
            if (a == null || !bitmapsPreparing.compareAndSet(false, true)) return;
            try {
                a.artwork.execute(
                        () -> {
                            try {
                                ensureFocusCardCornerAtlas();
                                ensureScrimBitmap();
                                ensureCornerAtlas(false);
                                ensureCornerAtlas(true);
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || (android.os.Build.VERSION.SDK_INT >= 17
                                                            && a.isDestroyed())) {
                                                return;
                                            }
                                            TvHistoryPageHost host =
                                                    a.tvHistoryHostCache
                                                                    instanceof TvHistoryPageHost
                                                            ? (TvHistoryPageHost)
                                                                    a.tvHistoryHostCache
                                                            : (tvHistoryHostRef == null
                                                                    ? null
                                                                    : tvHistoryHostRef.get());
                                            if (host != null
                                                    && host.root != null
                                                    && host.root.getVisibility() == View.VISIBLE
                                                    && host.grid != null) {
                                                // Only invalidate visible cards that already drew
                                                // a poster, staggered 1 per frame so we never
                                                // cause a 12-card Record View#draw burst.
                                                final int[] idx = {0};
                                                final Runnable tick =
                                                        new Runnable() {
                                                            @Override
                                                            public void run() {
                                                                if (a.isFinishing()
                                                                        || host.grid == null) {
                                                                    return;
                                                                }
                                                                while (idx[0]
                                                                        < host.grid
                                                                                .getChildCount()) {
                                                                    View ch =
                                                                            host.grid.getChildAt(
                                                                                    idx[0]++);
                                                                    if (ch
                                                                                    instanceof
                                                                                    TvHistoryCardView
                                                                            && ((TvHistoryCardView)
                                                                                                    ch)
                                                                                            .posterBitmap
                                                                                    != null) {
                                                                        ch.invalidate();
                                                                        host.grid.postDelayed(
                                                                                this, 48L);
                                                                        return;
                                                                    }
                                                                }
                                                            }
                                                        };
                                                host.grid.postDelayed(tick, 48L);
                                            }
                                        });
                            } catch (Throwable ignored) {
                            } finally {
                                bitmapsPreparing.set(false);
                            }
                        });
            } catch (Throwable ignored) {
                bitmapsPreparing.set(false);
            }
        }

        Bitmap ensureScrimBitmap() {
            Bitmap existing = scrimBitmap;
            if (existing != null && !existing.isRecycled()) return existing;
            try {
                if (scrimH > 0) {
                    Bitmap b = Bitmap.createBitmap(4, scrimH, Bitmap.Config.ARGB_8888);
                    Canvas sc = new Canvas(b);
                    Paint sp = new Paint();
                    sp.setStyle(Paint.Style.FILL);
                    sp.setShader(
                            new LinearGradient(
                                    0f,
                                    0f,
                                    0f,
                                    scrimH,
                                    new int[] {0x00000000, 0xaa0e1016, 0xeb0b0d12},
                                    new float[] {0f, 0.55f, 1f},
                                    Shader.TileMode.CLAMP));
                    sc.drawRect(0f, 0f, 4f, scrimH, sp);
                    scrimBitmap = b;
                }
            } catch (Throwable ignored) {
                scrimBitmap = null;
            }
            return scrimBitmap;
        }

        Bitmap ensureCornerAtlas(boolean focused) {
            if (focused) {
                Bitmap existing = focusedCornerAtlas;
                if (existing == null || existing.isRecycled()) {
                    existing = buildCornerAtlas(cornerSizePx, artRadius, 0xff29292f);
                    focusedCornerAtlas = existing;
                }
                return existing;
            }
            Bitmap existing = normalCornerAtlas;
            if (existing == null || existing.isRecycled()) {
                existing = buildCornerAtlas(cornerSizePx, artRadius, 0xff0d0f14);
                normalCornerAtlas = existing;
            }
            return existing;
        }

        void subTextWarmup() {
            subPaint.measureText("00:00 / 01:23:45 第1集 观看至");
            badgeTextPaint.measureText("第01集 正片 全");
            titlePaint.measureText("影片");
        }

        private static Bitmap buildCornerAtlas(int size, float radius, int bgColor) {
            if (size <= 0 || radius <= 0.5f) return null;
            try {
                // Single 2*size x 2*size atlas holds all 4 antialiased corner cutouts (TL/TR/BL/BR)
                // so Mali-450 uploads 1 tiny texture instead of 4 separate 20x20 textures.
                int full = size * 2;
                Bitmap sheet = Bitmap.createBitmap(full, full, Bitmap.Config.ARGB_8888);
                Canvas c = new Canvas(sheet);
                c.drawColor(bgColor);
                Paint clear = new Paint(Paint.ANTI_ALIAS_FLAG);
                clear.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.CLEAR));
                c.drawRoundRect(new RectF(0f, 0f, full, full), radius, radius, clear);
                return sheet;
            } catch (Throwable ignored) {
                return null;
            }
        }
    }

    private static String fastEllipsize(
            String text,
            TextPaint paint,
            float textSizePx,
            float maxWidthPx,
            float ellipsisWidthPx) {
        if (text == null || text.isEmpty() || maxWidthPx <= 0f) return "";
        int len = text.length();
        // Always measure actual glyph advances via Paint.breakText (never assume an average ASCII
        // width factor that underestimates wide glyphs like 'W'/'M' or enlarged font scales);
        // callers reuse results through PREPARED_TEXT_CACHE.
        int fit = paint.breakText(text, 0, len, true, maxWidthPx, null);
        if (fit >= len) return text;
        if (fit <= 1) return "…";
        float avail = maxWidthPx - ellipsisWidthPx;
        if (avail <= 1f) return "…";
        int trim = paint.breakText(text, 0, fit, true, avail, null);
        if (trim <= 0) return "…";
        return text.substring(0, trim) + "…";
    }

    private static String historyCardTextCacheKey(
            WatchHistory.Entry e,
            TvHistoryCardTheme t,
            String titleText,
            String ep,
            String subSummary,
            String progBadge) {
        return e.key()
                + "\0"
                + e.updated
                + "\0"
                + (e.line == null ? "" : e.line)
                + "\0"
                + e.index
                + "\0"
                + t.artW
                + "\0"
                + Float.floatToIntBits(t.titleTextSize)
                + "\0"
                + titleText
                + "\0"
                + ep
                + "\0"
                + subSummary
                + "\0"
                + progBadge;
    }

    private static boolean isStandardBmpString(String text) {
        for (int i = 0, n = text.length(); i < n; i++) {
            char c = text.charAt(i);
            if (c < 0x20 || c > 0x9FFF) return false;
        }
        return true;
    }

    private static String fastEllipsizeBounded(
            String text,
            TextPaint paint,
            float textSizePx,
            float maxWidthPx,
            float ellipsisWidthPx,
            float safeUpperCharW) {
        if (text == null || text.isEmpty() || maxWidthPx <= 0f) return "";
        if (safeUpperCharW > 0f
                && text.length() * safeUpperCharW <= maxWidthPx
                && isStandardBmpString(text)) {
            return text;
        }
        return fastEllipsize(text, paint, textSizePx, maxWidthPx, ellipsisWidthPx);
    }

    private static PreparedHistoryText obtainPreparedText(
            TvHistoryCardTheme t,
            String cacheKey,
            String title,
            String sub,
            String ep,
            String prog) {
        PreparedHistoryText prep = cacheKey != null ? PREPARED_TEXT_CACHE.get(cacheKey) : null;
        if (prep != null) return prep;
        String tText =
                fastEllipsizeBounded(
                        title,
                        t.titlePaint,
                        t.titleTextSize,
                        t.artW - 4,
                        t.ellipsisTitleW,
                        t.safeUpperTitleCharW);
        String sText =
                fastEllipsizeBounded(
                        sub,
                        t.subPaint,
                        t.subTextSize,
                        t.artW - 4,
                        t.ellipsisSubW,
                        t.safeUpperSubCharW);
        String pText =
                fastEllipsizeBounded(
                        prog,
                        t.progTextPaint,
                        t.progTextSize,
                        t.barInnerW,
                        t.ellipsisProgW,
                        t.safeUpperProgCharW);
        String eText = "";
        float bW = 0f;
        if (ep != null && !ep.isEmpty()) {
            float maxBadgeTextW =
                    Math.max(t.barInnerW * 0.4f, t.artW - t.badgeMargin * 2 - t.badgePadH * 2);
            float[] measured = new float[1];
            eText =
                    fastEllipsizeWithWidth(
                            ep, t.badgeTextPaint, maxBadgeTextW, t.ellipsisBadgeW, measured);
            bW = measured[0];
        }
        String cd =
                ep != null && !ep.isEmpty()
                        ? (title + " · " + ep + " · " + sub)
                        : (title + " · " + sub);
        prep = new PreparedHistoryText(tText, sText, eText, bW, pText, cd);
        if (cacheKey != null) {
            if (PREPARED_TEXT_CACHE.size() > 160) PREPARED_TEXT_CACHE.clear();
            PREPARED_TEXT_CACHE.put(cacheKey, prep);
        }
        return prep;
    }

    private static void prewarmPreparedText(TvHistoryCardTheme t, WatchHistory.Entry e) {
        if (t == null || e == null) return;
        String titleText = (e.title == null || e.title.isEmpty()) ? "未命名影片" : e.title;
        String ep = e.episode == null ? "" : e.episode.trim();
        String subSummary = historyTimeSummary(e);
        String progBadge = historyProgressBadge(e);
        String cacheKey = historyCardTextCacheKey(e, t, titleText, ep, subSummary, progBadge);
        obtainPreparedText(t, cacheKey, titleText, subSummary, ep, progBadge);
    }

    private static String fastEllipsizeWithWidth(
            String text,
            TextPaint paint,
            float maxWidthPx,
            float ellipsisWidthPx,
            float[] outWidth) {
        if (text == null || text.isEmpty() || maxWidthPx <= 0f) {
            outWidth[0] = 0f;
            return "";
        }
        int len = text.length();
        int fit = paint.breakText(text, 0, len, true, maxWidthPx, outWidth);
        if (fit >= len) return text;
        if (fit <= 1) {
            outWidth[0] = ellipsisWidthPx;
            return "…";
        }
        float avail = maxWidthPx - ellipsisWidthPx;
        if (avail <= 1f) {
            outWidth[0] = ellipsisWidthPx;
            return "…";
        }
        int trim = paint.breakText(text, 0, fit, true, avail, outWidth);
        if (trim <= 0) {
            outWidth[0] = ellipsisWidthPx;
            return "…";
        }
        outWidth[0] += ellipsisWidthPx;
        return text.substring(0, trim) + "…";
    }

    /**
     * Single-view custom leaf card for TV watch history: replaces a 10-view nested hierarchy,
     * removes per-card {@code setClipToOutline(true)} GPU clip masks and 8-frame focus spring
     * storms, and renders posters via opaque center-cropped {@code drawBitmap} plus 4 tiny
     * pre-baked corner masks so Mali-450 avoids full-card {@code BitmapShader} + rounded-rect SDF
     * fragment shaders and cold GLSL compilation stalls.
     */
    private static final class TvHistoryCardView extends View {
        final TvHistoryCardTheme t;
        final Paint posterPaint = new Paint(Paint.FILTER_BITMAP_FLAG);
        final Rect posterSrcRect = new Rect();
        final RectF cardRect = new RectF();
        final RectF ringRect = new RectF();
        final RectF artRect = new RectF();
        final RectF scrimRect = new RectF();
        final RectF badgeRect = new RectF();
        final RectF trackRect = new RectF();
        final RectF fillRect = new RectF();
        final RectF cornerDstTl = new RectF();
        final RectF cornerDstTr = new RectF();
        final RectF cornerDstBl = new RectF();
        final RectF cornerDstBr = new RectF();
        final RectF cardCornerDstTl = new RectF();
        final RectF cardCornerDstTr = new RectF();
        final RectF cardCornerDstBl = new RectF();
        final RectF cardCornerDstBr = new RectF();

        Bitmap posterBitmap;
        boolean hasPosterSrcRect;
        boolean hasPosterUrl;
        String fallbackRaw = "影片";
        String fallbackText = "影片";
        boolean fallbackMeasured;
        String titleText = "";
        String subText = "";
        String epText = "";
        String progText = "";
        float badgeTextW;
        int fillWidthPx;
        boolean cardFocused;
        boolean hasDrawnOnce;
        int adapterPosition = -1;
        HistoryOpenProfile openProfile;

        TvHistoryCardView(MainActivity a, TvHistoryCardTheme theme) {
            super(a);
            this.t = theme;
            setId(View.generateViewId());
            setFocusable(true);
            setFocusableInTouchMode(true);
            setClickable(true);
            UiCompat.setDefaultFocusHighlightEnabled(this, false);
            TvFocusFrame.attachCard(this, "history-grid");

            float halfStroke = t.focusRingPaint.getStrokeWidth() * 0.5f;
            cardRect.set(0f, 0f, t.cardW, t.cardH);
            ringRect.set(halfStroke, halfStroke, t.cardW - halfStroke, t.cardH - halfStroke);
            artRect.set(t.padH, t.padTop, t.padH + t.artW, t.padTop + t.artH);
            float cs = t.cornerSizePx;
            cornerDstTl.set(artRect.left, artRect.top, artRect.left + cs, artRect.top + cs);
            cornerDstTr.set(artRect.right - cs, artRect.top, artRect.right, artRect.top + cs);
            cornerDstBl.set(artRect.left, artRect.bottom - cs, artRect.left + cs, artRect.bottom);
            cornerDstBr.set(artRect.right - cs, artRect.bottom - cs, artRect.right, artRect.bottom);
            float ccs = t.cardCornerSizePx;
            cardCornerDstTl.set(0f, 0f, ccs, ccs);
            cardCornerDstTr.set(t.cardW - ccs, 0f, t.cardW, ccs);
            cardCornerDstBl.set(0f, t.cardH - ccs, ccs, t.cardH);
            cardCornerDstBr.set(t.cardW - ccs, t.cardH - ccs, t.cardW, t.cardH);
            scrimRect.set(artRect.left, artRect.bottom - t.scrimH, artRect.right, artRect.bottom);
            float trackTop = artRect.bottom - t.overlayPadBottom - t.trackH;
            trackRect.set(
                    artRect.left + t.overlayPadH,
                    trackTop,
                    artRect.left + t.overlayPadH + t.barInnerW,
                    trackTop + t.trackH);
        }

        void bindData(
                int pos,
                HistoryOpenProfile profile,
                String cacheKey,
                String fallback,
                String title,
                String sub,
                String ep,
                String prog,
                int fillPx,
                Bitmap cachedPoster,
                boolean hasPosterUrl) {
            this.adapterPosition = pos;
            this.openProfile = profile;
            this.hasPosterUrl = hasPosterUrl;
            this.fallbackRaw = fallback == null ? "影片" : fallback;
            this.fallbackMeasured = false;
            final long tm0 = profile != null ? SystemClock.elapsedRealtimeNanos() : 0L;
            PreparedHistoryText prep = obtainPreparedText(t, cacheKey, title, sub, ep, prog);
            if (profile != null) {
                profile.textMeasureTotalNs += (SystemClock.elapsedRealtimeNanos() - tm0);
            }
            this.titleText = prep.titleText;
            this.subText = prep.subText;
            this.progText = prep.progText;
            this.epText = prep.epText;
            this.badgeTextW = prep.badgeTextW;
            if (!this.epText.isEmpty()) {
                float boxW = badgeTextW + t.badgePadH * 2;
                badgeRect.set(
                        artRect.right - t.badgeMargin - boxW,
                        artRect.top + t.badgeMargin,
                        artRect.right - t.badgeMargin,
                        artRect.top + t.badgeMargin + t.badgeBoxH);
            }
            this.fillWidthPx = Math.max(0, Math.min(t.barInnerW, fillPx));
            if (this.fillWidthPx > 0) {
                fillRect.set(
                        trackRect.left,
                        trackRect.top,
                        trackRect.left + this.fillWidthPx,
                        trackRect.bottom);
            }
            setContentDescription(prep.contentDesc);
            final long sh0 = profile != null ? SystemClock.elapsedRealtimeNanos() : 0L;
            applyPosterBitmapInternal(cachedPoster);
            if (profile != null) {
                profile.shaderApplyTotalNs += (SystemClock.elapsedRealtimeNanos() - sh0);
            }
            invalidate();
        }

        void setPosterBitmap(Bitmap bmp) {
            if (this.posterBitmap == bmp) return;
            applyPosterBitmapInternal(bmp);
            invalidate();
        }

        private void applyPosterBitmapInternal(Bitmap bmp) {
            if (bmp == null || bmp.isRecycled()) {
                this.posterBitmap = null;
                this.hasPosterSrcRect = false;
                return;
            }
            int bw = bmp.getWidth();
            int bh = bmp.getHeight();
            if (bw <= 0 || bh <= 0) {
                this.posterBitmap = null;
                this.hasPosterSrcRect = false;
                return;
            }
            this.posterBitmap = bmp;
            float targetRatio = artRect.width() / Math.max(1f, artRect.height());
            float bmpRatio = (float) bw / (float) bh;
            if (bmpRatio > targetRatio) {
                int cropW = Math.max(1, Math.min(bw, Math.round(bh * targetRatio)));
                int left = (bw - cropW) / 2;
                posterSrcRect.set(left, 0, left + cropW, bh);
            } else {
                int cropH =
                        Math.max(1, Math.min(bh, Math.round(bw / Math.max(0.01f, targetRatio))));
                int top = (bh - cropH) / 2;
                posterSrcRect.set(0, top, bw, top + cropH);
            }
            this.hasPosterSrcRect = true;
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            setMeasuredDimension(t.cardW, t.cardH);
        }

        @Override
        protected void onFocusChanged(
                boolean gainFocus, int direction, android.graphics.Rect previouslyFocusedRect) {
            super.onFocusChanged(gainFocus, direction, previouslyFocusedRect);
            cardFocused = gainFocus;
            setScaleX(gainFocus ? 1.025f : 1f);
            setScaleY(gainFocus ? 1.025f : 1f);
            if (gainFocus
                    && adapterPosition == 0
                    && openProfile != null
                    && openProfile.firstCardFocusedMonoNs == 0L) {
                openProfile.firstCardFocusedNs = SystemClock.elapsedRealtimeNanos();
                openProfile.firstCardFocusedMonoNs = System.nanoTime();
                Object tg = getTag();
                if (tg instanceof String) openProfile.firstCardTag = (String) tg;
                try {
                    View rv = getRootView();
                    android.view.ViewParent vp = rv != null ? rv.getParent() : null;
                    if (vp != null) {
                        openProfile.firstCardWindowIdentity =
                                "ViewRootImpl@" + Integer.toHexString(System.identityHashCode(vp));
                    }
                } catch (Throwable ignored) {
                }
            }
            if (hasDrawnOnce) {
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (cardFocused) {
                float ccs = t.cardCornerSizePx;
                float sw = t.focusStrokePx;
                // On the very first cold switch frame (!hasDrawnOnce), draw pure solid GPU quads
                // with ZERO bitmap texture upload so Mali-450 SwapBuffers stays well under 50 ms;
                // rounded focus corner atlas renders on subsequent frames once settled.
                Bitmap focusCorners = hasDrawnOnce ? t.peekFocusCardCornerAtlas() : null;
                if (focusCorners != null) {
                    // 9-slice solid quads + 4 pre-baked rounded-ring corner blits eliminate cold
                    // Mali-450 GLSL drawRoundRect SDF shader compilation on Frame 1!
                    canvas.drawRect(ccs, 0f, t.cardW - ccs, t.cardH, t.focusBgPaint);
                    canvas.drawRect(0f, ccs, ccs, t.cardH - ccs, t.focusBgPaint);
                    canvas.drawRect(t.cardW - ccs, ccs, t.cardW, t.cardH - ccs, t.focusBgPaint);
                    canvas.drawBitmap(focusCorners, t.cardCornerSrcTl, cardCornerDstTl, null);
                    canvas.drawBitmap(focusCorners, t.cardCornerSrcTr, cardCornerDstTr, null);
                    canvas.drawBitmap(focusCorners, t.cardCornerSrcBl, cardCornerDstBl, null);
                    canvas.drawBitmap(focusCorners, t.cardCornerSrcBr, cardCornerDstBr, null);
                    canvas.drawRect(ccs, 0f, t.cardW - ccs, sw, t.focusRingFillPaint);
                    canvas.drawRect(
                            ccs, t.cardH - sw, t.cardW - ccs, t.cardH, t.focusRingFillPaint);
                    canvas.drawRect(0f, ccs, sw, t.cardH - ccs, t.focusRingFillPaint);
                    canvas.drawRect(
                            t.cardW - sw, ccs, t.cardW, t.cardH - ccs, t.focusRingFillPaint);
                } else {
                    canvas.drawRect(cardRect, t.focusBgPaint);
                    canvas.drawRect(0f, 0f, t.cardW, sw, t.focusRingFillPaint);
                    canvas.drawRect(0f, t.cardH - sw, t.cardW, t.cardH, t.focusRingFillPaint);
                    canvas.drawRect(0f, 0f, sw, t.cardH, t.focusRingFillPaint);
                    canvas.drawRect(t.cardW - sw, 0f, t.cardW, t.cardH, t.focusRingFillPaint);
                }
            }
            boolean drewPoster = false;
            if (posterBitmap != null && !posterBitmap.isRecycled() && hasPosterSrcRect) {
                canvas.drawBitmap(posterBitmap, posterSrcRect, artRect, posterPaint);
                drewPoster = true;
            } else {
                // Pure solid GPU quad on Frame 1 avoids per-card rounded-rect path tessellation.
                canvas.drawRect(artRect, t.placeholderBgPaint);
                if (!hasPosterUrl) {
                    if (!fallbackMeasured) {
                        fallbackMeasured = true;
                        fallbackText =
                                fastEllipsize(
                                        fallbackRaw,
                                        t.fallbackPaint,
                                        t.titleTextSize,
                                        t.artW - t.overlayPadH * 2,
                                        t.ellipsisFallbackW);
                    }
                    canvas.drawText(
                            fallbackText, artRect.centerX(), artRect.centerY(), t.fallbackPaint);
                }
            }
            if (drewPoster) {
                Bitmap scrim = t.peekScrimBitmap();
                if (scrim != null) {
                    canvas.drawBitmap(scrim, null, scrimRect, null);
                }
                Bitmap cornerAtlas = t.peekCornerAtlas(cardFocused);
                if (cornerAtlas != null) {
                    canvas.drawBitmap(cornerAtlas, t.cornerSrcTl, cornerDstTl, null);
                    canvas.drawBitmap(cornerAtlas, t.cornerSrcTr, cornerDstTr, null);
                    canvas.drawBitmap(cornerAtlas, t.cornerSrcBl, cornerDstBl, null);
                    canvas.drawBitmap(cornerAtlas, t.cornerSrcBr, cornerDstBr, null);
                }
            }
            if (!epText.isEmpty()) {
                canvas.drawRect(badgeRect, t.badgeBgPaint);
                canvas.drawText(
                        epText,
                        badgeRect.left + t.badgePadH,
                        badgeRect.top + t.badgePadV + t.badgeBaselineOffset,
                        t.badgeTextPaint);
            }
            float progBaseline = trackRect.top - t.trackTopGap + t.progBaselineOffset;
            canvas.drawText(progText, trackRect.left, progBaseline, t.progTextPaint);
            canvas.drawRect(trackRect, t.trackPaint);
            if (fillWidthPx > 0) {
                canvas.drawRect(fillRect, t.fillPaint);
            }
            float titleTop = artRect.bottom + t.titleTopGap;
            canvas.drawText(
                    titleText, artRect.left + 2f, titleTop + t.titleBaselineOffset, t.titlePaint);
            float subTop = titleTop + t.titleLineH + t.subTopGap;
            canvas.drawText(subText, artRect.left + 2f, subTop + t.subBaselineOffset, t.subPaint);
            hasDrawnOnce = true;
        }
    }

    private static final class TvHistoryCardHolder extends RecyclerView.ViewHolder {
        final TvHistoryCardView card;
        WatchHistory.Entry bound;
        int bindSeq;

        TvHistoryCardHolder(TvHistoryCardView card) {
            super(card);
            this.card = card;
        }
    }

    private static final class PendingPosterLoad {
        final TvHistoryCardHolder holder;
        final int bindSeq;
        final String url;
        final Bitmap readyBitmap;

        PendingPosterLoad(TvHistoryCardHolder holder, int bindSeq, String url, Bitmap readyBitmap) {
            this.holder = holder;
            this.bindSeq = bindSeq;
            this.url = url;
            this.readyBitmap = readyBitmap;
        }
    }

    private static final class TvHistoryGridAdapter
            extends RecyclerView.Adapter<TvHistoryCardHolder> {
        private final MainActivity a;
        private List<WatchHistory.Entry> entries;
        private final TvHistoryCardTheme theme;
        private final int columns;
        private int pageTicket;
        private HistoryOpenProfile profile;
        private final List<PendingPosterLoad> deferredPosters = new ArrayList<>();
        private final List<PendingPosterLoad> readyPosterApplyQueue = new ArrayList<>();
        private boolean readyPosterDrainScheduled;
        private WeakReference<RecyclerView> activeGridRef;
        private boolean firstFrameRendered;
        private boolean prewarmMode;
        private int visibleLimit = Integer.MAX_VALUE;
        private boolean stagingRows;
        String pendingFreshFocusTag;

        void onGridLayoutCompleted(GridLayoutManager lm) {
            String tag = pendingFreshFocusTag;
            if (tag == null || a.generation != pageTicket || lm == null) return;
            View c0 = lm.findViewByPosition(0);
            if (c0 instanceof TvHistoryCardView
                    && tag.equals(c0.getTag())
                    && c0.isAttachedToWindow()) {
                pendingFreshFocusTag = null;
                a.tvInitialFocus = c0;
                a.autoFocus = c0;
                if (!c0.hasFocus()) {
                    c0.requestFocus();
                }
            }
        }

        TvHistoryGridAdapter(
                MainActivity a,
                List<WatchHistory.Entry> entries,
                TvHistoryCardTheme theme,
                int columns,
                int pageTicket,
                HistoryOpenProfile profile) {
            this.a = a;
            this.entries = entries;
            this.theme = theme;
            this.columns = Math.max(1, columns);
            this.pageTicket = pageTicket;
            this.profile = profile;
        }

        void rebindSession(int nextTicket, HistoryOpenProfile nextProfile) {
            this.pageTicket = nextTicket;
            this.profile = nextProfile;
            this.deferredPosters.clear();
            this.readyPosterApplyQueue.clear();
            this.readyPosterDrainScheduled = false;
            this.firstFrameRendered = false;
            this.prewarmMode = false;
            this.visibleLimit = Integer.MAX_VALUE;
            this.stagingRows = false;
        }

        void rebindSession(
                List<WatchHistory.Entry> nextEntries,
                int nextTicket,
                HistoryOpenProfile nextProfile,
                RecyclerView grid) {
            this.entries = nextEntries;
            this.activeGridRef = grid != null ? new WeakReference<>(grid) : null;
            rebindSession(nextTicket, nextProfile);
            if (grid != null && nextEntries != null) {
                for (int c = 0, cnt = grid.getChildCount(); c < cnt; c++) {
                    View child = grid.getChildAt(c);
                    RecyclerView.ViewHolder vh = grid.getChildViewHolder(child);
                    if (vh instanceof TvHistoryCardHolder) {
                        int pos = grid.getChildAdapterPosition(child);
                        if (pos >= 0 && pos < nextEntries.size()) {
                            ((TvHistoryCardHolder) vh).bound = nextEntries.get(pos);
                        }
                    }
                }
            }
        }

        void replaceEntries(
                List<WatchHistory.Entry> nextEntries,
                int nextTicket,
                HistoryOpenProfile nextProfile) {
            replaceEntries(nextEntries, nextTicket, nextProfile, false);
        }

        void replaceEntries(
                List<WatchHistory.Entry> nextEntries,
                int nextTicket,
                HistoryOpenProfile nextProfile,
                boolean stageRowOne) {
            this.entries = nextEntries;
            this.pageTicket = nextTicket;
            this.profile = nextProfile;
            this.deferredPosters.clear();
            this.readyPosterApplyQueue.clear();
            this.readyPosterDrainScheduled = false;
            this.firstFrameRendered = false;
            this.prewarmMode = false;
            int initialColdBatch = 1;
            if (stageRowOne && nextEntries != null && nextEntries.size() > initialColdBatch) {
                // On cold unprewarmed first open, lay out card_01 immediately on Frame 1 so
                // focus lands instantly and the switch frame stays well under 50 ms even before
                // JIT warms up, then hydrate the remaining visible cards 1 per frame.
                this.visibleLimit = initialColdBatch;
                this.stagingRows = true;
            } else {
                this.visibleLimit = Integer.MAX_VALUE;
                this.stagingRows = false;
            }
            notifyDataSetChanged();
        }

        void finishStagingImmediately() {
            if (!stagingRows) return;
            int total = entries == null ? 0 : entries.size();
            int prev = Math.min(total, visibleLimit);
            stagingRows = false;
            visibleLimit = Integer.MAX_VALUE;
            if (total > prev) {
                notifyItemRangeInserted(prev, total - prev);
            }
        }

        void replaceEntriesForPrewarm(List<WatchHistory.Entry> nextEntries, int nextTicket) {
            this.entries = nextEntries;
            this.pageTicket = nextTicket;
            this.profile = null;
            this.deferredPosters.clear();
            this.readyPosterApplyQueue.clear();
            this.readyPosterDrainScheduled = false;
            this.firstFrameRendered = false;
            this.prewarmMode = true;
            this.visibleLimit = Integer.MAX_VALUE;
            this.stagingRows = false;
            notifyDataSetChanged();
        }

        void queueDeferredPoster(TvHistoryCardHolder h, int seq, String url) {
            queueDeferredPoster(h, seq, url, null);
        }

        void queueDeferredPoster(TvHistoryCardHolder h, int seq, String url, Bitmap readyBitmap) {
            if ((url == null || url.isEmpty()) && readyBitmap == null) return;
            if (firstFrameRendered) {
                applyOrDispatchPoster(h, seq, url, readyBitmap);
            } else {
                deferredPosters.add(new PendingPosterLoad(h, seq, url, readyBitmap));
            }
        }

        void flushDeferredPosters(final RecyclerView grid) {
            this.activeGridRef = grid != null ? new WeakReference<>(grid) : null;
            firstFrameRendered = true;
            if (stagingRows && grid != null) {
                // Serialize Row-2 hydration FIRST; drain deferred poster textures AFTER Row 2
                // finishes so holder creation and Mali-450 texture upload never collide in one
                // frame.
                scheduleRowHydrationStep(grid, pageTicket);
                return;
            } else if (stagingRows) {
                finishStagingImmediately();
            }
            drainDeferredPostersNow(grid);
        }

        private void drainDeferredPostersNow(final RecyclerView grid) {
            if (deferredPosters.isEmpty()) return;
            final List<PendingPosterLoad> batch = new ArrayList<>(deferredPosters);
            deferredPosters.clear();
            // Upload deferred posters 1 card/frame on postOnAnimation so Mali-450 never spikes
            // >=50 ms on Frame 2..13 when posters arrive.
            final int waveSize = 1;
            if (grid != null) {
                scheduleDeferredWave(grid, batch, 0, waveSize);
            } else {
                for (int i = 0; i < batch.size(); i++) {
                    PendingPosterLoad item = batch.get(i);
                    applyOrDispatchPoster(item.holder, item.bindSeq, item.url, item.readyBitmap);
                }
            }
        }

        private void scheduleRowHydrationStep(final RecyclerView grid, final int expectedTicket) {
            grid.postDelayed(
                    () -> {
                        if (!stagingRows || a.isFinishing() || a.generation != expectedTicket) {
                            return;
                        }
                        int total = entries == null ? 0 : entries.size();
                        int prev = Math.min(total, visibleLimit);
                        if (prev >= total) {
                            stagingRows = false;
                            visibleLimit = Integer.MAX_VALUE;
                            drainDeferredPostersNow(grid);
                            return;
                        }
                        int targetRowOne = Math.min(total, columns);
                        int targetRowTwo = Math.min(total, columns * 2);
                        int next;
                        if (prev < targetRowOne) {
                            next = Math.min(targetRowOne, prev + 1);
                            visibleLimit = next;
                            notifyItemRangeInserted(prev, next - prev);
                            scheduleRowHydrationStep(grid, expectedTicket);
                        } else if (prev < targetRowTwo) {
                            // Hydrate Row 2 spaced across >=2 VSyncs so Mali-450 SwapChain never
                            // queues.
                            next = Math.min(targetRowTwo, prev + 1);
                            visibleLimit = next;
                            notifyItemRangeInserted(prev, next - prev);
                            scheduleRowHydrationStep(grid, expectedTicket);
                        } else {
                            // Row 1 & Row 2 are now visible; expose all remaining offscreen items
                            // at once (RecyclerView will not create offscreen holders), then begin
                            // spaced poster uploads.
                            stagingRows = false;
                            visibleLimit = Integer.MAX_VALUE;
                            notifyItemRangeInserted(prev, total - prev);
                            grid.postDelayed(
                                    () -> {
                                        if (!a.isFinishing() && a.generation == expectedTicket) {
                                            drainDeferredPostersNow(grid);
                                        }
                                    },
                                    56L);
                        }
                    },
                    42L);
        }

        private void scheduleDeferredWave(
                final RecyclerView grid,
                final List<PendingPosterLoad> batch,
                final int start,
                final int waveSize) {
            grid.postDelayed(
                    () -> {
                        if (a.isFinishing() || a.generation != pageTicket) return;
                        int end = Math.min(batch.size(), start + waveSize);
                        for (int i = start; i < end; i++) {
                            PendingPosterLoad item = batch.get(i);
                            applyOrDispatchPoster(
                                    item.holder, item.bindSeq, item.url, item.readyBitmap);
                        }
                        if (end < batch.size()) {
                            scheduleDeferredWave(grid, batch, end, waveSize);
                        }
                    },
                    52L);
        }

        private void enqueueReadyPosterApply(
                final TvHistoryCardHolder h, final int seq, final Bitmap bmp) {
            if (h.bindSeq != seq || bmp == null || bmp.isRecycled()) return;
            readyPosterApplyQueue.add(new PendingPosterLoad(h, seq, "", bmp));
            if (readyPosterDrainScheduled) return;
            readyPosterDrainScheduled = true;
            RecyclerView grid = activeGridRef == null ? null : activeGridRef.get();
            Runnable drain =
                    new Runnable() {
                        @Override
                        public void run() {
                            readyPosterDrainScheduled = false;
                            if (a.isFinishing() || a.generation != pageTicket) {
                                readyPosterApplyQueue.clear();
                                return;
                            }
                            int applied = 0;
                            while (!readyPosterApplyQueue.isEmpty() && applied < 1) {
                                PendingPosterLoad next = readyPosterApplyQueue.remove(0);
                                if (next.holder.bindSeq == next.bindSeq
                                        && next.readyBitmap != null
                                        && !next.readyBitmap.isRecycled()) {
                                    next.holder.card.setPosterBitmap(next.readyBitmap);
                                    applied++;
                                }
                            }
                            if (!readyPosterApplyQueue.isEmpty()) {
                                readyPosterDrainScheduled = true;
                                RecyclerView g = activeGridRef == null ? null : activeGridRef.get();
                                if (g != null && g.isAttachedToWindow()) {
                                    g.postDelayed(this, 52L);
                                } else {
                                    a.ui.postDelayed(this, 52L);
                                }
                            }
                        }
                    };
            if (grid != null && grid.isAttachedToWindow()) {
                grid.postDelayed(drain, 52L);
            } else {
                a.ui.postDelayed(drain, 52L);
            }
        }

        private void applyOrDispatchPoster(
                final TvHistoryCardHolder h,
                final int seq,
                final String url,
                final Bitmap readyBitmap) {
            if (h.bindSeq != seq) return;
            if (readyBitmap != null && !readyBitmap.isRecycled()) {
                h.card.setPosterBitmap(readyBitmap);
                return;
            }
            dispatchPosterLoad(h, seq, url);
        }

        private void dispatchPosterLoad(
                final TvHistoryCardHolder h, final int seq, final String url) {
            if (url == null || url.isEmpty() || h.bindSeq != seq) return;
            ImageLoader.loadPosterBitmap(
                    a,
                    url,
                    theme.artW,
                    theme.artH,
                    pageTicket,
                    bmp -> {
                        if (h.bindSeq == seq && bmp != null && !bmp.isRecycled()) {
                            enqueueReadyPosterApply(h, seq, bmp);
                        }
                    });
        }

        @Override
        public int getItemCount() {
            int n = entries == null ? 0 : entries.size();
            return Math.min(n, visibleLimit);
        }

        @Override
        public TvHistoryCardHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            final long t0 = SystemClock.elapsedRealtimeNanos();
            final TvHistoryCardHolder holder = createTvHistoryCardHolder(a, theme);
            if (profile != null) {
                profile.holdersCreated++;
                profile.createHoldersTotalNs += (SystemClock.elapsedRealtimeNanos() - t0);
            }
            return holder;
        }

        @Override
        public void onBindViewHolder(TvHistoryCardHolder h, int i) {
            final long t0 = SystemClock.elapsedRealtimeNanos();
            final WatchHistory.Entry e = entries.get(i);
            final TvHistoryCardView card = h.card;
            h.bound = e;
            final int seq = ++h.bindSeq;
            card.setTag("history:" + e.key());
            String titleText = (e.title == null || e.title.isEmpty()) ? "未命名影片" : e.title;
            String fallbackText = (e.title == null || e.title.isEmpty()) ? "影片" : e.title;
            String ep = e.episode == null ? "" : e.episode.trim();
            float ratio =
                    e.complete()
                            ? 1f
                            : e.duration > 0
                                    ? Math.max(.04f, Math.min(1f, (float) e.position / e.duration))
                                    : (e.position > 0 ? .18f : 0f);
            int fillPx = ratio > 0f ? Math.max(a.dp(4), Math.round(theme.barInnerW * ratio)) : 0;

            final long p0 = SystemClock.elapsedRealtimeNanos();
            Bitmap cached = ImageLoader.cachedPosterBitmap(a, e.poster, theme.artW, theme.artH);
            if (profile != null) {
                profile.posterCacheHitTotalNs += (SystemClock.elapsedRealtimeNanos() - p0);
            }
            String subSummary = historyTimeSummary(e);
            String progBadge = historyProgressBadge(e);
            String cacheKey =
                    historyCardTextCacheKey(e, theme, titleText, ep, subSummary, progBadge);
            // During occluded Home prewarm or unprewarmed cold Frame 1, defer poster texture
            // uploads out of Frame 1 (prewarm leaves posterBitmap null so Frame-1 swap uploads at
            // most 1 texture, and staged cold open defers all Frame-1 posters to Frame 2's
            // 2-card micro-waves) to eliminate Mali-450 SyncStart/SwapBuffers >=50 ms spikes.
            boolean hasPosterUrl = e.poster != null && !e.poster.isEmpty();
            boolean deferColdBitmap = prewarmMode || (!firstFrameRendered && cached != null);
            card.bindData(
                    i,
                    profile,
                    cacheKey,
                    fallbackText,
                    titleText,
                    subSummary,
                    ep,
                    progBadge,
                    fillPx,
                    deferColdBitmap ? null : cached,
                    hasPosterUrl);
            if (!prewarmMode) {
                if (deferColdBitmap) {
                    if (profile != null) profile.posterDeferredCount++;
                    queueDeferredPoster(h, seq, e.poster, cached);
                } else if (cached != null) {
                    if (profile != null) profile.posterCacheHits++;
                } else if (e.poster != null && !e.poster.isEmpty()) {
                    if (profile != null) profile.posterDeferredCount++;
                    queueDeferredPoster(h, seq, e.poster, null);
                }
                if (i == 0) a.tvInitialFocus = card;
            }
            if (profile != null) {
                profile.holdersBound++;
                profile.bindHoldersTotalNs += (SystemClock.elapsedRealtimeNanos() - t0);
            }
        }

        @Override
        public void onViewRecycled(TvHistoryCardHolder h) {
            h.bindSeq++;
            h.bound = null;
            h.card.setPosterBitmap(null);
            h.card.openProfile = null;
            h.card.hasDrawnOnce = false;
        }
    }
}

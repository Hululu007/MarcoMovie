package com.pilipala.marcomovie;

import android.view.*;
import android.widget.*;
import java.util.*;

final class FavoritesScreen {
    final MainActivity a;

    FavoritesScreen(MainActivity a) {
        this.a = a;
    }

    void show() {
        a.renderPage("我的收藏", "YOUR COLLECTION");
        List<Favorites.Entry> entries = Favorites.read(a.prefs.getString(Prefs.FAVORITES, "[]"));
        if (entries.isEmpty()) {
            a.paragraph("把喜欢的内容留在这里。打开影片详情，选择“加入收藏”。");
            if (!a.privateMode) {
                a.addButton(
                        a.body,
                        a.navButton(
                                "多端云同步",
                                "favorites-cloud-sync",
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
                    a.text(entries.size() + " 部收藏 · 确认打开详情，长按确认或按菜单键管理", 13, MainActivity.MUTED);
            topBar.addView(summary, new LinearLayout.LayoutParams(0, -2, 1));
            if (!a.privateMode) {
                Button syncBtn =
                        a.navButton(
                                "多端云同步",
                                "favorites-cloud-sync",
                                () -> CloudSyncDialog.show(a, a::refresh));
                topBar.addView(syncBtn, new LinearLayout.LayoutParams(-2, a.dp(36)));
            }
            a.body.addView(topBar, new LinearLayout.LayoutParams(-1, -2));
            a.gap(a.body, 10);
        } else {
            a.paragraph(entries.size() + " 部收藏 · 确认打开详情，长按确认或按菜单键管理");
            if (!a.privateMode) {
                a.addButton(
                        a.body,
                        a.navButton(
                                "多端云同步",
                                "favorites-cloud-sync",
                                () -> CloudSyncDialog.show(a, a::refresh)));
            }
        }
        float screen = a.windowWidth() / a.getResources().getDisplayMetrics().density;
        int columns = Math.max(4, Math.min(6, a.prefs.getInt(Prefs.HOME_COLUMNS, 6)));
        int width = (int) ((screen - 92) / columns) - 20;
        LinearLayout row = null;
        for (int i = 0; i < entries.size(); i++) {
            Favorites.Entry e = entries.get(i);
            if (i % columns == 0) {
                row = a.row();
                row.setGravity(Gravity.TOP);
                row.setClipChildren(false);
                a.body.addView(row);
            }
            LinearLayout card = a.vertical();
            card.setPadding(a.dp(5), a.dp(5), a.dp(5), a.dp(8));
            card.setGravity(Gravity.CENTER_HORIZONTAL);
            card.setId(View.generateViewId());
            card.setTag("favorite:" + e.key());
            card.setFocusable(a.isTvDevice());
            card.setFocusableInTouchMode(a.isTvDevice());
            card.setClickable(true);
            if (a.isTvDevice()) TvFocusFrame.attachCard(card, "favorites-grid");
            ImageView poster = new ImageView(a);
            poster.setScaleType(ImageView.ScaleType.CENTER_CROP);
            poster.setBackground(a.bg(0xff29292e, 10));
            poster.setClipToOutline(true);
            card.addView(poster, new LinearLayout.LayoutParams(a.dp(width), a.dp(width * 1.5f)));
            a.poster(e.poster, poster);
            TextView title = a.text(e.title, 13, MainActivity.WHITE);
            title.setSingleLine(true);
            title.setEllipsize(android.text.TextUtils.TruncateAt.END);
            title.setPadding(0, a.dp(9), 0, 0);
            card.addView(title, new LinearLayout.LayoutParams(-1, a.dp(30)));
            card.setOnClickListener(v -> open(e));
            card.setOnLongClickListener(
                    v -> {
                        manage(e);
                        return true;
                    });
            a.pressFeedback(card);
            card.setOnKeyListener(
                    (v, key, event) -> {
                        if (key == KeyEvent.KEYCODE_MENU) {
                            if (event.getAction() == KeyEvent.ACTION_UP) manage(e);
                            return true;
                        }
                        return false;
                    });
            card.setOnFocusChangeListener(
                    (v, f) -> {
                        FocusMotion.style(
                                a,
                                card,
                                f,
                                0,
                                0xff29292f,
                                16,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                true,
                                1.035f);
                    });
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(0, -2, 1);
            size.setMargins(a.dp(4), a.dp(5), a.dp(4), a.dp(16));
            row.addView(card, size);
            if (i == 0 && a.current != null && a.current.focus == null)
                a.ui.post(card::requestFocus);
        }
        if (row != null)
            for (int i = entries.size() % columns; i > 0 && i < columns; i++)
                row.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1));
    }

    void open(Favorites.Entry e) {
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
                    a.openListing(res.activeSite, e.video());
                    return;
                }
                if (res.status == TvMultiSourceStore.SiteResolution.STATUS_DISABLED_SUBSCRIPTION
                        && res.subscription != null) {
                    final TvMultiSourceStore.SubscriptionRecord sub = res.subscription;
                    final String targetStableKey = res.stableSiteKey;
                    new AppDialog.Builder(a)
                            .setTitle("「" + sub.name + "」当前已停用")
                            .setMessage("这条收藏来自已停用的订阅源「" + sub.name + "」。可重新启用来源并打开，或选择其他来源搜索。")
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
                                            if (a.config != null) {
                                                for (Cms.Site s : a.config.sites) {
                                                    if (s != null
                                                            && targetStableKey.equals(s.key)
                                                            && a.available(s)) {
                                                        a.openListing(s, e.video());
                                                        return;
                                                    }
                                                }
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
                            .setNegativeButton("保留收藏", null)
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
                            .setMessage("该收藏对应的线路已单独停用。可重新启用并打开，或从其他来源搜索。")
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
                                                    built, false, 0, 0, "");
                                            if (a.config != null) {
                                                for (Cms.Site s : a.config.sites) {
                                                    if (s != null
                                                            && targetStableKey.equals(s.key)
                                                            && a.available(s)) {
                                                        a.openListing(s, e.video());
                                                        return;
                                                    }
                                                }
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
                            .setNegativeButton("保留收藏", null)
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
                            .setTitle("选择该收藏的来源")
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
                                            if (a.config != null) {
                                                for (Cms.Site s : a.config.sites) {
                                                    if (s != null
                                                            && pick.stableSiteKey.equals(s.key)
                                                            && a.available(s)) {
                                                        a.openListing(s, e.video());
                                                        return;
                                                    }
                                                }
                                            }
                                        } catch (Exception err) {
                                            a.notice("打开来源失败：" + a.message(err));
                                        }
                                    })
                            .setNegativeButton("保留收藏", null)
                            .show();
                    return;
                }
            }
        }
        Cms.Site found = null;
        if (a.config != null) for (Cms.Site s : a.config.sites) if (s.key.equals(e.site)) found = s;
        if (found == null || !a.available(found)) {
            if (a.config != null && e.title != null && !e.title.trim().isEmpty()) {
                if (!a.isTvDevice()) {
                    a.toast("原片源不在当前订阅中，已自动全网搜索该影片");
                    a.openSearch(e.title);
                } else {
                    new AppDialog.Builder(a)
                            .setTitle("原片源不在当前订阅中")
                            .setMessage("这条收藏来自其他设备或旧订阅源，是否在当前片库中全网搜索「" + e.title + "」？")
                            .setPositiveButton("全网搜索", (d, w) -> a.openSearch(e.title))
                            .setNegativeButton("保留收藏", null)
                            .show();
                }
                return;
            }
            a.notice("这个收藏的来源暂不可用，收藏仍保留。请检查配置。");
            return;
        }
        Cms.Site selected = found;
        a.openListing(selected, e.video());
    }

    void manage(Favorites.Entry e) {
        new AppDialog.Builder(a)
                .setTitle(e.title)
                .setItems(
                        new String[] {"打开详情", "取消收藏"},
                        (d, n) -> {
                            if (n == 0) open(e);
                            else {
                                a.prefs
                                        .edit()
                                        .putString(
                                                Prefs.FAVORITES,
                                                Favorites.toggle(
                                                        a.prefs.getString(Prefs.FAVORITES, "[]"),
                                                        e.site,
                                                        e.video()))
                                        .apply();
                                CloudSyncDialog.onFavoriteToggled(a, e.site, e.id, false);
                                a.refresh();
                            }
                        })
                .setNegativeButton("返回", null)
                .show();
    }
}

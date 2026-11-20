package com.pilipala.marcomovie;

import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.Button;
import android.widget.TextView;
import java.util.List;

/** Live list presentation; loading, parsing, session and playback remain in LiveController. */
final class TvV17LiveScreen {
    private static final int PAGE_SIZE = 40;
    private final MainActivity a;

    TvV17LiveScreen(MainActivity activity) {
        a = activity;
    }

    void show() {
        a.renderPage("电视直播", "");
        a.addButton(
                a.body,
                a.navButton(
                        "导入直播源",
                        "v17-live-import",
                        () -> SourceController.showLiveImportDialog(a)));
        List<LiveCatalog.Source> sources = LiveController.sourcesFor(a);
        if (sources.isEmpty()) {
            a.paragraph("暂无直播源。导入 M3U、TXT 或 JSON 后即可浏览频道。");
            return;
        }
        a.gap(a.body, 12);
        for (int i = 0; i < sources.size(); i++) {
            LiveCatalog.Source source = sources.get(i);
            final int index = i;
            a.addButton(
                    a.body,
                    a.navButton(
                            source.name,
                            "v17-live-source:" + index,
                            () -> {
                                SourcePage page = new SourcePage(source);
                                a.open(new MainActivity.Screen(page::show), true);
                            }));
        }
    }

    private final class SourcePage {
        final LiveCatalog.Source source;
        final TvSearchContext context = new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        LiveCatalog.Catalog catalog;

        SourcePage(LiveCatalog.Source source) {
            this.source = source;
        }

        void show() {
            if (!context.matches(a.config, a.privateMode, a.engineEpoch)) {
                a.renderPage(source.name, "电视直播");
                a.paragraph("来源已更改，请返回重新打开直播。");
                return;
            }
            if (catalog != null) {
                showCatalog(source, catalog, context, 0, 0);
                return;
            }
            a.renderPage(source.name, "电视直播");
            MainActivity.Screen screen = a.current;
            a.load(
                    "正在读取频道…",
                    () -> LiveController.loadCatalog(a, source),
                    result -> {
                        if (!context.matches(a.config, a.privateMode, a.engineEpoch)) return;
                        catalog = result;
                        showCatalog(source, catalog, context, 0, 0);
                        if (a.current == screen) a.restore(screen);
                    });
        }
    }

    private void showCatalog(
            LiveCatalog.Source source,
            LiveCatalog.Catalog catalog,
            TvSearchContext context,
            int selectedGroup,
            int page) {
        a.renderPage(source.name, "电视直播");
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)) {
            a.paragraph("来源已更改，请返回重新打开直播。");
            return;
        }
        if (catalog.groups.isEmpty()) {
            a.paragraph("这个直播源没有频道分组。");
            return;
        }
        int groupIndex = Math.max(0, Math.min(selectedGroup, catalog.groups.size() - 1));
        LinearLayout groups = a.row();
        groups.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < catalog.groups.size(); i++) {
            final int index = i;
            LiveCatalog.Group group = catalog.groups.get(i);
            a.addButton(
                    groups,
                    a.navButton(
                            group.name + " · " + group.channels.size(),
                            "v17-live-group:" + i,
                            () ->
                                    openList(
                                            () -> showCatalog(source, catalog, context, index, 0),
                                            "v17-live-group:" + index)));
        }
        android.widget.HorizontalScrollView groupScroll =
                new android.widget.HorizontalScrollView(a);
        groupScroll.setHorizontalScrollBarEnabled(false);
        groupScroll.addView(groups);
        a.body.addView(groupScroll);
        a.gap(a.body, 12);
        LiveCatalog.Group group = catalog.groups.get(groupIndex);
        if (group.channels.isEmpty()) {
            a.paragraph("此分组暂无频道。");
            return;
        }
        int maxPage = (group.channels.size() - 1) / PAGE_SIZE;
        int currentPage = Math.max(0, Math.min(page, maxPage));
        int start = currentPage * PAGE_SIZE;
        int end = Math.min(group.channels.size(), start + PAGE_SIZE);
        LinearLayout columns = a.row();
        columns.setGravity(Gravity.TOP);
        columns.setClipChildren(false);
        LinearLayout channels = a.vertical();
        LinearLayout.LayoutParams channelSize = new LinearLayout.LayoutParams(0, -2, 1f);
        channelSize.rightMargin = a.dp(30);
        columns.addView(channels, channelSize);
        LinearLayout details = a.vertical();
        details.setPadding(a.dp(22), a.dp(20), a.dp(22), a.dp(20));
        details.setBackground(
                TvV17Surface.rounded(
                        a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false)
                                ? TvV17Theme.OPAQUE_SURFACE
                                : TvV17Theme.SURFACE,
                        a.dp(18),
                        0x2affffff,
                        a.dp(1)));
        TextView detailTitle = a.text(group.channels.get(start).name, 24, TvV17Theme.TEXT);
        details.addView(detailTitle);
        a.gap(details, 10);
        TextView detailInfo =
                a.text(channelSummary(group.channels.get(start)), 15, TvV17Theme.MUTED);
        details.addView(detailInfo);
        columns.addView(details, new LinearLayout.LayoutParams(0, -2, 1f));
        a.body.addView(columns);
        for (int i = start; i < end; i++) {
            LiveCatalog.Channel channel = group.channels.get(i);
            String suffix =
                    channel.streams.size() > 1 ? " · " + channel.streams.size() + " 条线路" : "";
            Button button =
                    a.navButton(
                            channel.name + suffix,
                            "v17-live-channel:" + i,
                            () -> play(source, catalog, channel, context));
            button.setGravity(Gravity.CENTER_VERTICAL | Gravity.LEFT);
            button.setOnFocusChangeListener(
                    (view, focused) -> {
                        FocusMotion.style(
                                a,
                                button,
                                focused,
                                0xff222a34,
                                TvV17Theme.FOCUS,
                                12,
                                TvV17Theme.TEXT,
                                MainActivity.DARK,
                                false,
                                1.01f);
                        if (focused) {
                            detailTitle.setText(channel.name);
                            detailInfo.setText(channelSummary(channel));
                        }
                    });
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, a.dp(52));
            size.bottomMargin = a.dp(8);
            channels.addView(button, size);
        }
        LinearLayout pages = a.row();
        if (currentPage > 0)
            a.addButton(
                    pages,
                    a.navButton(
                            "上一页",
                            "v17-live-prev",
                            () ->
                                    openList(
                                            () ->
                                                    showCatalog(
                                                            source,
                                                            catalog,
                                                            context,
                                                            groupIndex,
                                                            currentPage - 1),
                                            "v17-live-channel:"
                                                    + ((currentPage - 1) * PAGE_SIZE))));
        if (currentPage < maxPage)
            a.addButton(
                    pages,
                    a.navButton(
                            "下一页",
                            "v17-live-next",
                            () ->
                                    openList(
                                            () ->
                                                    showCatalog(
                                                            source,
                                                            catalog,
                                                            context,
                                                            groupIndex,
                                                            currentPage + 1),
                                            "v17-live-channel:"
                                                    + ((currentPage + 1) * PAGE_SIZE))));
        channels.addView(pages);
    }

    private void openList(Runnable render, String focus) {
        MainActivity.Screen screen = new MainActivity.Screen(render);
        screen.focus = focus;
        a.open(screen, false);
    }

    private String channelSummary(LiveCatalog.Channel channel) {
        if (channel == null || channel.streams.isEmpty()) return "此频道暂无可播放的线路";
        StringBuilder sb = new StringBuilder();
        String epg = channel.options.get("epg");
        if (epg != null && !epg.trim().isEmpty()) {
            sb.append("正在播出：").append(epg.trim()).append("\n");
        } else {
            sb.append("暂无实时节目单（可在设置中配置 XMLTV EPG）\n");
        }
        String nextEpg = channel.options.get("epg-next");
        if (nextEpg != null && !nextEpg.trim().isEmpty()) {
            sb.append("即将播出：").append(nextEpg.trim()).append("\n");
        }
        if (LiveEpgService.supportsCatchup(channel)) {
            sb.append("支持回看时移（播放中按菜单可打开节目单回看）\n");
        }
        String[] labels = LiveController.streamLabelsFor(a, channel);
        if (labels.length > 0) {
            sb.append("\n优选线路：").append(labels[0]);
            if (labels.length > 1) {
                sb.append("  （共 ").append(labels.length).append(" 条可用线路）");
            }
        }
        return sb.toString().trim();
    }

    private void play(
            LiveCatalog.Source source,
            LiveCatalog.Catalog catalog,
            LiveCatalog.Channel channel,
            TvSearchContext context) {
        if (!context.matches(a.config, a.privateMode, a.engineEpoch)) {
            a.notice("来源已更改，请重新打开直播。");
            return;
        }
        if (channel.streams.isEmpty()) {
            a.notice("此频道没有可播放的线路。");
        } else if (channel.streams.size() == 1) {
            LiveController.playFromCatalog(
                    a, source, catalog, channel, channel.streams.get(0), context);
        } else {
            String[] labels = LiveController.streamLabelsFor(a, channel);
            new AppDialog.Builder(a)
                    .setTitle(channel.name)
                    .setItems(
                            labels,
                            (dialog, index) ->
                                    LiveController.playFromCatalog(
                                            a,
                                            source,
                                            catalog,
                                            channel,
                                            channel.streams.get(index),
                                            context))
                    .setNegativeButton("取消", null)
                    .show();
        }
    }
}

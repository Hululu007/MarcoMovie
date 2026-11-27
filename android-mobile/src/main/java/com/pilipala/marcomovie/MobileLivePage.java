package com.pilipala.marcomovie;

import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.text.Editable;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.Surface;
import android.view.View;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * Redesigned Mobile Live TV Page (Day/Night {@link MobileTheme} + {@link MobileIcons} +
 * {@link MobileMotion}):
 * - Portrait top {@code 16:9} inline live preview window with subtle buffering indicator, EPG info,
 *   stream line switcher, and vector fullscreen button into landscape live player
 * - {@link MobileSectionGroup#searchBar} with animated clear button + 0-match recovery CTA
 * - Bottom dual-column Group sidebar (left) + in-place highlighted Channel & EPG cards (right,
 *   preserving scroll position on channel selection).
 */
final class MobileLivePage {
    /**
     * Pure-JVM snapshot preserving Live TV source, group, search filter, and left/right scroll
     * offsets across same-direction foldable/split-screen relayouts.
     */
    static final class LiveRelayoutState {
        final String sourceUrl;
        final int sourceIndex;
        final int groupIndex;
        final String filterQuery;
        final int groupScrollY;
        final int channelScrollY;

        LiveRelayoutState(
                String sourceUrl,
                int sourceIndex,
                int groupIndex,
                String filterQuery,
                int groupScrollY,
                int channelScrollY) {
            this.sourceUrl = sourceUrl == null ? "" : sourceUrl;
            this.sourceIndex = Math.max(0, sourceIndex);
            this.groupIndex = Math.max(0, groupIndex);
            this.filterQuery = filterQuery == null ? "" : filterQuery;
            this.groupScrollY = Math.max(0, groupScrollY);
            this.channelScrollY = Math.max(0, channelScrollY);
        }
    }

    private static LiveRelayoutState pendingRelayoutState;
    private static Runnable activeCaptureHook;

    static void recordRelayoutState(LiveRelayoutState state) {
        pendingRelayoutState = state;
    }

    static void captureForRelayout() {
        Runnable hook = activeCaptureHook;
        if (hook != null) {
            try {
                hook.run();
            } catch (Throwable ignored) {
            }
        }
    }

    static LiveRelayoutState consumeRelayoutState() {
        LiveRelayoutState s = pendingRelayoutState;
        pendingRelayoutState = null;
        return s;
    }

    static void clearRelayoutState() {
        pendingRelayoutState = null;
        activeCaptureHook = null;
    }

    static int resolveRestoredSourceIndex(LiveRelayoutState saved, List<String> sourceUrls) {
        if (saved == null || sourceUrls == null || sourceUrls.isEmpty()) return 0;
        if (!saved.sourceUrl.isEmpty()) {
            for (int i = 0; i < sourceUrls.size(); i++) {
                if (saved.sourceUrl.equals(sourceUrls.get(i))) return i;
            }
        }
        return Math.min(saved.sourceIndex, sourceUrls.size() - 1);
    }

    static int resolveRestoredGroupIndex(LiveRelayoutState saved, int groupCount) {
        if (saved == null || groupCount <= 0) return 0;
        return Math.min(saved.groupIndex, groupCount - 1);
    }

    private MobileLivePage() {}

    private static final class ChannelRowHolder {
        final LiveCatalog.Channel channel;
        final LinearLayout row;
        final TextView nameView;
        final FrameLayout trailingSlot;

        ChannelRowHolder(
                LiveCatalog.Channel channel,
                LinearLayout row,
                TextView nameView,
                FrameLayout trailingSlot) {
            this.channel = channel;
            this.row = row;
            this.nameView = nameView;
            this.trailingSlot = trailingSlot;
        }
    }

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout page = a.vertical();
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        final List<LiveCatalog.Source> sources = LiveController.sourcesFor(a);
        if (sources.isEmpty()) {
            page.setGravity(Gravity.CENTER_HORIZONTAL);
            page.setPadding(
                    a.dp(24),
                    a.statusBarHeight() + a.dp(72),
                    a.dp(24),
                    a.navigationBarHeight() + a.dp(106));

            FrameLayout badge = MobileIcons.badge(a, MobileIcons.IC_LIVE, p.accent, 54, 28);
            page.addView(badge, new LinearLayout.LayoutParams(a.dp(54), a.dp(54)));
            a.gap(page, 16);

            TextView titleEmpty = a.text("尚未导入电视直播源", 18, p.textPrimary);
            titleEmpty.setTypeface(null, Typeface.BOLD);
            titleEmpty.setGravity(Gravity.CENTER);
            page.addView(titleEmpty);
            a.gap(page, 8);

            TextView hint = a.text("支持常见电视直播频道列表与网络直播流", 13.5f, p.textSecondary);
            hint.setGravity(Gravity.CENTER);
            page.addView(hint);
            a.gap(page, 22);

            LinearLayout importBtn = a.row();
            importBtn.setGravity(Gravity.CENTER);
            importBtn.setPadding(a.dp(20), a.dp(13), a.dp(20), a.dp(13));
            importBtn.setBackground(MobileTheme.accentPillBg(a, 999));

            MobileIcons.IconView plusIcon =
                    MobileIcons.create(a, MobileIcons.IC_PLUS, 16f, p.accentOnFill);
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(16), a.dp(16));
            pLp.rightMargin = a.dp(7);
            importBtn.addView(plusIcon, pLp);

            TextView btnLbl = a.text("导入电视直播源", 14, p.accentOnFill);
            btnLbl.setTypeface(null, Typeface.BOLD);
            importBtn.addView(btnLbl);

            MobileMotion.bindPress(importBtn, 0.96f);
            importBtn.setOnClickListener(v -> SourceController.showLiveImportDialog(a));
            page.addView(importBtn, new LinearLayout.LayoutParams(-1, -2));
            return;
        }

        // 1. Top Header: Title + Refresh + Borderless Search Bar (with animated clear)
        LinearLayout header = a.vertical();
        header.setPadding(a.dp(16), a.statusBarHeight() + a.dp(8), a.dp(16), a.dp(6));
        page.addView(header, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = a.text("电视直播", 20, p.textPrimary);
        title.setTypeface(null, Typeface.BOLD);
        topRow.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        LinearLayout importTopBtn = a.row();
        importTopBtn.setTag("live-import-btn");
        importTopBtn.setGravity(Gravity.CENTER_VERTICAL);
        importTopBtn.setPadding(a.dp(11), a.dp(7), a.dp(12), a.dp(7));
        importTopBtn.setBackground(MobileTheme.pillBg(a, true, 999));
        MobileIcons.IconView importTopIc =
                MobileIcons.create(a, MobileIcons.IC_PLUS, 13.5f, p.accent);
        LinearLayout.LayoutParams aiLp = new LinearLayout.LayoutParams(a.dp(13.5f), a.dp(13.5f));
        aiLp.rightMargin = a.dp(4);
        importTopBtn.addView(importTopIc, aiLp);
        TextView importTopLbl = a.text("导入直播源", 12.5f, p.accent);
        importTopLbl.setTypeface(null, Typeface.BOLD);
        importTopBtn.addView(importTopLbl);
        MobileMotion.bindPress(importTopBtn, 0.94f);
        importTopBtn.setOnClickListener(v -> SourceController.showLiveImportDialog(a));
        LinearLayout.LayoutParams impLp = new LinearLayout.LayoutParams(-2, a.dp(34));
        impLp.rightMargin = a.dp(8);
        topRow.addView(importTopBtn, impLp);

        FrameLayout refreshBtn = new FrameLayout(a);
        refreshBtn.setBackground(MobileTheme.subtleBg(a, 999));
        refreshBtn.setContentDescription("刷新频道列表");
        MobileIcons.IconView refIcon =
                MobileIcons.create(a, MobileIcons.IC_REFRESH, 16f, p.textSecondary);
        refreshBtn.addView(
                refIcon, new FrameLayout.LayoutParams(a.dp(16), a.dp(16), Gravity.CENTER));
        MobileMotion.bindPress(refreshBtn, 0.92f);
        topRow.addView(refreshBtn, new LinearLayout.LayoutParams(a.dp(34), a.dp(34)));

        header.addView(topRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(header, 8);

        final EditText filterInput = new EditText(a);
        final Runnable[] rebuildColumnsRef = new Runnable[1];
        LinearLayout searchBar =
                MobileSectionGroup.searchBar(
                        a,
                        filterInput,
                        "搜索频道名称…",
                        () -> {
                            if (rebuildColumnsRef[0] != null) rebuildColumnsRef[0].run();
                        });
        header.addView(searchBar, new LinearLayout.LayoutParams(-1, a.dp(40)));

        HorizontalScrollView srcHsv = new HorizontalScrollView(a);
        srcHsv.setHorizontalScrollBarEnabled(false);
        srcHsv.setPadding(0, a.dp(8), 0, a.dp(2));
        final LinearLayout srcRow = a.row();
        srcHsv.addView(srcRow);
        header.addView(srcHsv, new LinearLayout.LayoutParams(-1, -2));

        // 2. Portrait 16:9 Inline Live Stage (cinema dark video box in both Day & Night)
        int stageH =
                a.isPortrait() ? Math.round((a.windowWidth() - a.dp(32)) * 9f / 16f) : a.dp(168);
        final FrameLayout liveStage = new FrameLayout(a);
        liveStage.setClipToOutline(true);
        liveStage.setBackground(a.bg(0xFF0A0B0E, 16));
        if (!p.isDark) UiCompat.setElevation(liveStage, a.dp(3f));
        LinearLayout.LayoutParams stageLp = new LinearLayout.LayoutParams(-1, stageH);
        stageLp.setMargins(a.dp(16), a.dp(4), a.dp(16), a.dp(10));
        page.addView(liveStage, stageLp);

        final VideoOutput previewSurface = new VideoOutput(a, true);
        liveStage.addView(previewSurface, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        // Subtle centered preview buffering pill (shown while switching / connecting)
        final LinearLayout bufferingPill = a.row();
        bufferingPill.setGravity(Gravity.CENTER_VERTICAL);
        bufferingPill.setPadding(a.dp(14), a.dp(8), a.dp(16), a.dp(8));
        bufferingPill.setBackground(a.bg(0xCC141720, 999));
        ProgressBar spinner = new ProgressBar(a, null, android.R.attr.progressBarStyleSmall);
        if (Build.VERSION.SDK_INT >= 21) {
            spinner.setIndeterminateTintList(ColorStateList.valueOf(p.accent));
        }
        LinearLayout.LayoutParams spLp = new LinearLayout.LayoutParams(a.dp(16), a.dp(16));
        spLp.rightMargin = a.dp(8);
        bufferingPill.addView(spinner, spLp);
        TextView bufLabel = a.text("正在连接直播流…", 12.5f, Color.WHITE);
        bufLabel.setTypeface(null, Typeface.BOLD);
        bufferingPill.addView(bufLabel);
        bufferingPill.setVisibility(View.GONE);
        liveStage.addView(bufferingPill, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        LinearLayout stageHud = a.row();
        stageHud.setGravity(Gravity.CENTER_VERTICAL);
        stageHud.setPadding(a.dp(12), a.dp(12), a.dp(10), a.dp(10));
        stageHud.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0x00000000, 0xCC0A0B0E}));

        final View liveDot = new View(a);
        liveDot.setBackground(a.bg(0x88FFFFFF, 999));
        LinearLayout.LayoutParams ldLp = new LinearLayout.LayoutParams(a.dp(7), a.dp(7));
        ldLp.rightMargin = a.dp(7);
        stageHud.addView(liveDot, ldLp);

        final TextView liveNowLabel = a.text("点选下方频道开始预览", 12.5f, Color.WHITE);
        liveNowLabel.setTypeface(null, Typeface.BOLD);
        liveNowLabel.setSingleLine(true);
        liveNowLabel.setEllipsize(TextUtils.TruncateAt.END);
        stageHud.addView(liveNowLabel, new LinearLayout.LayoutParams(0, -2, 1f));

        final TextView lineBtn = a.text("换线", 11.5f, Color.WHITE);
        lineBtn.setTypeface(null, Typeface.BOLD);
        lineBtn.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
        lineBtn.setBackground(a.bg(0x38FFFFFF, 999));
        lineBtn.setVisibility(View.GONE);
        MobileMotion.bindPress(lineBtn, 0.93f);
        LinearLayout.LayoutParams lbLp = new LinearLayout.LayoutParams(-2, -2);
        lbLp.rightMargin = a.dp(6);
        stageHud.addView(lineBtn, lbLp);

        final LinearLayout fsBtn = a.row();
        fsBtn.setGravity(Gravity.CENTER_VERTICAL);
        fsBtn.setPadding(a.dp(10), a.dp(5), a.dp(11), a.dp(5));
        fsBtn.setBackground(MobileTheme.accentPillBg(a, 999));
        MobileIcons.IconView fsIcon =
                MobileIcons.create(a, MobileIcons.IC_FULLSCREEN, 12.5f, p.accentOnFill);
        LinearLayout.LayoutParams fsiLp = new LinearLayout.LayoutParams(a.dp(12.5f), a.dp(12.5f));
        fsiLp.rightMargin = a.dp(4);
        fsBtn.addView(fsIcon, fsiLp);
        TextView fsLabel = a.text("全屏", 11.5f, p.accentOnFill);
        fsLabel.setTypeface(null, Typeface.BOLD);
        fsBtn.addView(fsLabel);
        fsBtn.setVisibility(View.GONE);
        MobileMotion.bindPress(fsBtn, 0.93f);
        stageHud.addView(fsBtn, new LinearLayout.LayoutParams(-2, -2));

        liveStage.addView(stageHud, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

        final MoviePlayer[] inlineLivePlayer = {null};
        final Surface[] readySurface = {null};
        final LiveCatalog.Source[] curSource = {null};
        final LiveCatalog.Channel[] curChannel = {null};
        final LiveCatalog.Stream[] curStream = {null};
        final List<ChannelRowHolder> renderedRows = new ArrayList<>();

        final Runnable stopPreview =
                () -> {
                    if (inlineLivePlayer[0] != null) {
                        try {
                            inlineLivePlayer[0].release();
                        } catch (Exception ignored) {
                        }
                        inlineLivePlayer[0] = null;
                    }
                };
        liveStage.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {}

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        stopPreview.run();
                    }
                });

        final Runnable startPreview =
                () -> {
                    stopPreview.run();
                    final LiveCatalog.Channel ch = curChannel[0];
                    final LiveCatalog.Stream st = curStream[0];
                    if (ch == null || st == null || readySurface[0] == null) return;
                    liveDot.setBackground(a.bg(p.warning, 999));
                    liveNowLabel.setText("正在连接：" + ch.name + " …");
                    MobileMotion.crossfadeVisibility(
                            bufferingPill, true, 0f, 0.94f, MotionTokens.DURATION_FAST_MS, true);
                    fsBtn.setVisibility(View.VISIBLE);
                    lineBtn.setVisibility(ch.streams.size() > 1 ? View.VISIBLE : View.GONE);
                    final int ticket = a.generation;
                    a.worker.execute(
                            () -> {
                                try {
                                    MoviePlayer mp = new MoviePlayer(a);
                                    mp.configureDefaultAudio();
                                    mp.setDataSource(
                                            a,
                                            Uri.parse(LocalProxy.rewrite(st.url)),
                                            Collections.emptyMap());
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || !liveStage.isAttachedToWindow()
                                                        || readySurface[0] == null) {
                                                    mp.release();
                                                    return;
                                                }
                                                inlineLivePlayer[0] = mp;
                                                mp.setSurface(readySurface[0]);
                                                mp.setOnPreparedListener(
                                                        player -> {
                                                            liveDot.setBackground(
                                                                    a.bg(p.success, 999));
                                                            liveNowLabel.setText(
                                                                    "直播中 · " + ch.name);
                                                            MobileMotion.crossfadeVisibility(
                                                                    bufferingPill,
                                                                    false,
                                                                    0f,
                                                                    0.94f,
                                                                    MotionTokens.DURATION_FAST_MS,
                                                                    true);
                                                            player.start();
                                                        });
                                                mp.prepareAsync();
                                            });
                                } catch (Exception e) {
                                    a.ui.post(
                                            () -> {
                                                liveDot.setBackground(a.bg(p.danger, 999));
                                                MobileMotion.crossfadeVisibility(
                                                        bufferingPill,
                                                        false,
                                                        0f,
                                                        0.94f,
                                                        MotionTokens.DURATION_FAST_MS,
                                                        true);
                                                liveNowLabel.setText(ch.name + " 预览失败，可点全屏切换内核");
                                            });
                                }
                            });
                };

        previewSurface.listen(
                new VideoOutput.Listener() {
                    @Override
                    public void available(Surface value) {
                        readySurface[0] = value;
                        if (curChannel[0] != null && inlineLivePlayer[0] == null) {
                            startPreview.run();
                        } else if (inlineLivePlayer[0] != null) {
                            inlineLivePlayer[0].setSurface(value);
                        }
                    }

                    @Override
                    public void resized(int width, int height) {
                        if (inlineLivePlayer[0] != null) {
                            inlineLivePlayer[0].setSurfaceSize(width, height);
                        }
                    }

                    @Override
                    public void destroyed() {
                        readySurface[0] = null;
                        if (inlineLivePlayer[0] != null) {
                            inlineLivePlayer[0].setSurface(null);
                        }
                    }
                });

        fsBtn.setOnClickListener(
                v -> {
                    if (curSource[0] != null && curChannel[0] != null && curStream[0] != null) {
                        stopPreview.run();
                        a.playLive(curSource[0], curChannel[0], curStream[0]);
                    }
                });
        lineBtn.setOnClickListener(
                v -> {
                    final LiveCatalog.Channel ch = curChannel[0];
                    if (ch == null || ch.streams.size() <= 1) return;
                    String[] labels = LiveController.streamLabelsFor(a, ch);
                    int curIdx = Math.max(0, ch.streams.indexOf(curStream[0]));
                    UiWidgets.showDrawerPicker(
                            a,
                            ch.name + " · 切换直播源线路",
                            "",
                            labels,
                            curIdx,
                            idx -> {
                                curStream[0] = ch.streams.get(idx);
                                startPreview.run();
                            });
                });

        // 3. Bottom Dual-Column Group Sidebar + Channel List
        LinearLayout dualPane = a.row();
        page.addView(dualPane, new LinearLayout.LayoutParams(-1, 0, 1f));

        int bottomPad = a.navigationBarHeight() + a.dp(104);
        ScrollView groupSv = new ScrollView(a);
        groupSv.setVerticalScrollBarEnabled(false);
        final LinearLayout groupCol = a.vertical();
        groupCol.setPadding(a.dp(16), a.dp(2), a.dp(6), bottomPad);
        groupSv.addView(groupCol);
        dualPane.addView(groupSv, new LinearLayout.LayoutParams(a.dp(108), -1));

        ScrollView chanSv = new ScrollView(a);
        chanSv.setVerticalScrollBarEnabled(false);
        shell.bindScrollBehavior(chanSv);
        final LinearLayout chanCol = a.vertical();
        chanCol.setPadding(a.dp(4), a.dp(2), a.dp(16), bottomPad);
        chanSv.addView(chanCol);
        dualPane.addView(chanSv, new LinearLayout.LayoutParams(0, -1, 1f));

        final LiveRelayoutState restoredState = consumeRelayoutState();
        List<String> sourceUrls = new ArrayList<>(sources.size());
        for (LiveCatalog.Source s : sources) {
            sourceUrls.add(s != null && s.url != null ? s.url : "");
        }
        final int[] srcIdx = {resolveRestoredSourceIndex(restoredState, sourceUrls)};
        final int[] grpIdx = {restoredState != null ? restoredState.groupIndex : 0};
        final int[] pendingScrollRestore =
                restoredState != null
                        ? new int[] {restoredState.groupScrollY, restoredState.channelScrollY, 1}
                        : new int[] {0, 0, 0};
        final LiveCatalog.Catalog[] catHolder = {null};
        final int[] reqSeq = {0};
        final Runnable[] loadCatalog = new Runnable[1];
        if (restoredState != null && !restoredState.filterQuery.isEmpty()) {
            filterInput.setText(restoredState.filterQuery);
            filterInput.setSelection(restoredState.filterQuery.length());
        }
        activeCaptureHook =
                () -> {
                    String sUrl =
                            srcIdx[0] >= 0 && srcIdx[0] < sources.size()
                                    ? sources.get(srcIdx[0]).url
                                    : "";
                    recordRelayoutState(
                            new LiveRelayoutState(
                                    sUrl,
                                    srcIdx[0],
                                    grpIdx[0],
                                    filterInput.getText().toString(),
                                    groupSv.getScrollY(),
                                    chanSv.getScrollY()));
                };

        final Runnable syncActiveChannelInPlace =
                () -> {
                    for (ChannelRowHolder holder : renderedRows) {
                        boolean playingThis = (curChannel[0] == holder.channel);
                        applyChannelRowHighlight(a, p, holder, playingThis);
                    }
                };

        final Runnable rebuildColumns =
                new Runnable() {
                    @Override
                    public void run() {
                        groupCol.removeAllViews();
                        chanCol.removeAllViews();
                        renderedRows.clear();
                        LiveCatalog.Catalog cat = catHolder[0];
                        if (cat == null || cat.groups.isEmpty()) return;

                        String rawQ = filterInput.getText().toString().trim();
                        String q = rawQ.toLowerCase(Locale.ROOT);

                        for (int i = 0; i < cat.groups.size(); i++) {
                            final int gIndex = i;
                            LiveCatalog.Group g = cat.groups.get(i);
                            boolean sel = q.isEmpty() && gIndex == grpIdx[0];
                            TextView gItem =
                                    a.text(
                                            g.name + " (" + g.channels.size() + ")",
                                            12f,
                                            sel ? p.accent : p.textSecondary);
                            gItem.setTypeface(null, sel ? Typeface.BOLD : Typeface.NORMAL);
                            gItem.setMaxLines(2);
                            gItem.setEllipsize(TextUtils.TruncateAt.END);
                            gItem.setPadding(a.dp(10), a.dp(9), a.dp(10), a.dp(9));
                            gItem.setBackground(MobileTheme.pillBg(a, sel, 12));
                            MobileMotion.bindPress(gItem, 0.94f);
                            gItem.setOnClickListener(
                                    v -> {
                                        grpIdx[0] = gIndex;
                                        if (!filterInput.getText().toString().isEmpty()) {
                                            filterInput.setText("");
                                        } else {
                                            run();
                                        }
                                    });
                            LinearLayout.LayoutParams gLp = new LinearLayout.LayoutParams(-1, -2);
                            gLp.bottomMargin = a.dp(6);
                            groupCol.addView(gItem, gLp);
                        }

                        int startG =
                                q.isEmpty()
                                        ? Math.max(0, Math.min(cat.groups.size() - 1, grpIdx[0]))
                                        : 0;
                        int endG = q.isEmpty() ? (startG + 1) : cat.groups.size();
                        int matchedCount = 0;
                        for (int g = startG; g < endG; g++) {
                            LiveCatalog.Group grp = cat.groups.get(g);
                            for (final LiveCatalog.Channel ch : grp.channels) {
                                if (!q.isEmpty() && !ch.name.toLowerCase(Locale.ROOT).contains(q)) {
                                    continue;
                                }
                                matchedCount++;
                                boolean playingThis = (curChannel[0] == ch);
                                LinearLayout row = a.row();
                                row.setGravity(Gravity.CENTER_VERTICAL);
                                row.setPadding(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
                                MobileMotion.bindPress(row, 0.97f);

                                TextView badge = buildCallsignBadge(a, ch.name);
                                LinearLayout.LayoutParams bLp =
                                        new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
                                bLp.rightMargin = a.dp(10);
                                row.addView(badge, bLp);

                                LinearLayout info = a.vertical();
                                TextView cName = a.text(ch.name, 13.5f, p.textPrimary);
                                cName.setTypeface(null, Typeface.BOLD);
                                cName.setSingleLine(true);
                                cName.setEllipsize(TextUtils.TruncateAt.END);
                                info.addView(cName);

                                String epg = ch.options.get("epg");
                                String meta =
                                        (epg != null && !epg.trim().isEmpty())
                                                ? ("正在播：" + epg.trim())
                                                : (grp.name
                                                        + " · "
                                                        + (ch.streams.size() > 1
                                                                ? ch.streams.size() + " 条线路"
                                                                : "直连"));
                                TextView sub = a.text(meta, 11.5f, p.textSecondary);
                                sub.setSingleLine(true);
                                sub.setEllipsize(TextUtils.TruncateAt.END);
                                sub.setPadding(0, a.dp(2), 0, 0);
                                info.addView(sub);
                                row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

                                FrameLayout trailingSlot = new FrameLayout(a);
                                LinearLayout.LayoutParams trLp =
                                        new LinearLayout.LayoutParams(a.dp(18), a.dp(18));
                                trLp.leftMargin = a.dp(6);
                                row.addView(trailingSlot, trLp);

                                final ChannelRowHolder holder =
                                        new ChannelRowHolder(ch, row, cName, trailingSlot);
                                applyChannelRowHighlight(a, p, holder, playingThis);
                                renderedRows.add(holder);

                                row.setOnClickListener(
                                        v -> {
                                            if (ch.streams.isEmpty()) return;
                                            curSource[0] = sources.get(srcIdx[0]);
                                            curChannel[0] = ch;
                                            curStream[0] = ch.streams.get(0);
                                            startPreview.run();
                                            // Update highlight in place to preserve scroll
                                            // position!
                                            syncActiveChannelInPlace.run();
                                            MobileMotion.popBounce(holder.trailingSlot);
                                        });
                                row.setOnLongClickListener(
                                        v -> {
                                            if (ch.streams.isEmpty()) return true;
                                            stopPreview.run();
                                            a.playLive(
                                                    sources.get(srcIdx[0]), ch, ch.streams.get(0));
                                            return true;
                                        });

                                LinearLayout.LayoutParams rLp =
                                        new LinearLayout.LayoutParams(-1, -2);
                                rLp.bottomMargin = a.dp(8);
                                chanCol.addView(row, rLp);
                            }
                        }

                        if (matchedCount == 0 && !q.isEmpty()) {
                            LinearLayout emptyBox = a.vertical();
                            emptyBox.setGravity(Gravity.CENTER_HORIZONTAL);
                            emptyBox.setPadding(a.dp(12), a.dp(36), a.dp(12), a.dp(24));
                            TextView msg = a.text("未找到包含「" + rawQ + "」的频道", 13.5f, p.textSecondary);
                            msg.setGravity(Gravity.CENTER);
                            emptyBox.addView(msg);
                            a.gap(emptyBox, 12);
                            TextView clearBtn = a.text("清空搜索", 13f, p.accent);
                            clearBtn.setTypeface(null, Typeface.BOLD);
                            clearBtn.setPadding(a.dp(16), a.dp(8), a.dp(16), a.dp(8));
                            clearBtn.setBackground(MobileTheme.pillBg(a, true, 999));
                            MobileMotion.bindPress(clearBtn, 0.94f);
                            clearBtn.setOnClickListener(v -> filterInput.setText(""));
                            emptyBox.addView(clearBtn);
                            chanCol.addView(emptyBox, new LinearLayout.LayoutParams(-1, -2));
                        }
                    }
                };
        rebuildColumnsRef[0] = rebuildColumns;

        filterInput.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(Editable s) {
                        rebuildColumns.run();
                    }
                });

        loadCatalog[0] =
                () -> {
                    final int myReq = ++reqSeq[0];
                    srcRow.removeAllViews();
                    for (int i = 0; i < sources.size(); i++) {
                        final int idx = i;
                        boolean active = (i == srcIdx[0]);
                        String rawName = sources.get(i).name == null ? "" : sources.get(i).name;
                        boolean hasSparkle =
                                LiveQualityPolicy.MERGED_SOURCE_URL.equals(sources.get(i).url)
                                        || rawName.startsWith("✨");
                        String cleanName =
                                rawName.startsWith("✨")
                                        ? rawName.replaceFirst("^✨\\s*", "").trim()
                                        : rawName;
                        View chipView;
                        if (hasSparkle) {
                            LinearLayout chipRow = a.row();
                            chipRow.setGravity(Gravity.CENTER_VERTICAL);
                            chipRow.setPadding(a.dp(12), a.dp(6), a.dp(13), a.dp(6));
                            chipRow.setBackground(MobileTheme.pillBg(a, active, 999));
                            MobileIcons.IconView spIc =
                                    MobileIcons.create(
                                            a,
                                            MobileIcons.IC_SPARKLE,
                                            13f,
                                            active ? p.accent : p.textSecondary);
                            LinearLayout.LayoutParams sparkleLp =
                                    new LinearLayout.LayoutParams(a.dp(13), a.dp(13));
                            sparkleLp.rightMargin = a.dp(5);
                            chipRow.addView(spIc, sparkleLp);
                            TextView lbl =
                                    a.text(cleanName, 12.5f, active ? p.accent : p.textSecondary);
                            lbl.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
                            chipRow.addView(lbl);
                            chipView = chipRow;
                        } else {
                            TextView chip =
                                    a.text(cleanName, 12.5f, active ? p.accent : p.textSecondary);
                            chip.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
                            chip.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
                            chip.setBackground(MobileTheme.pillBg(a, active, 999));
                            chipView = chip;
                        }
                        MobileMotion.bindPress(chipView, 0.94f);
                        chipView.setOnClickListener(
                                v -> {
                                    srcIdx[0] = idx;
                                    grpIdx[0] = 0;
                                    loadCatalog[0].run();
                                });
                        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                        lp.rightMargin = a.dp(8);
                        srcRow.addView(chipView, lp);
                    }

                    LinearLayout addLive = a.row();
                    addLive.setGravity(Gravity.CENTER_VERTICAL);
                    addLive.setPadding(a.dp(11), a.dp(6), a.dp(12), a.dp(6));
                    addLive.setBackground(MobileTheme.subtleBg(a, 999));
                    MobileIcons.IconView plus =
                            MobileIcons.create(a, MobileIcons.IC_PLUS, 12.5f, p.accent);
                    LinearLayout.LayoutParams plp =
                            new LinearLayout.LayoutParams(a.dp(12.5f), a.dp(12.5f));
                    plp.rightMargin = a.dp(4);
                    addLive.addView(plus, plp);
                    TextView addLbl = a.text("管理源", 12.5f, p.accent);
                    addLbl.setTypeface(null, Typeface.BOLD);
                    addLive.addView(addLbl);
                    MobileMotion.bindPress(addLive, 0.94f);
                    addLive.setOnClickListener(v -> SourceController.showLiveImportDialog(a));
                    srcRow.addView(addLive);

                    groupCol.removeAllViews();
                    chanCol.removeAllViews();
                    renderedRows.clear();
                    chanCol.addView(a.text("正在加载频道与节目单…", 12.5f, p.textSecondary));
                    final LiveCatalog.Source selSrc = sources.get(srcIdx[0]);
                    final int ticket = a.generation;
                    a.submitPage(
                            () -> {
                                try {
                                    final LiveCatalog.Catalog catalog =
                                            LiveController.loadCatalog(a, selSrc);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqSeq[0]) return;
                                                catHolder[0] = catalog;
                                                grpIdx[0] =
                                                        resolveRestoredGroupIndex(
                                                                new LiveRelayoutState(
                                                                        "", 0, grpIdx[0], "", 0, 0),
                                                                catalog.groups.size());
                                                a.liveSession = new LiveSession(selSrc, catalog);
                                                if (curChannel[0] == null
                                                        && !catalog.groups.isEmpty()
                                                        && !catalog.groups
                                                                .get(grpIdx[0])
                                                                .channels
                                                                .isEmpty()) {
                                                    LiveCatalog.Channel first =
                                                            catalog.groups
                                                                    .get(grpIdx[0])
                                                                    .channels
                                                                    .get(0);
                                                    if (!first.streams.isEmpty()) {
                                                        curSource[0] = selSrc;
                                                        curChannel[0] = first;
                                                        curStream[0] = first.streams.get(0);
                                                        startPreview.run();
                                                    }
                                                }
                                                rebuildColumns.run();
                                                if (pendingScrollRestore[2] == 1) {
                                                    pendingScrollRestore[2] = 0;
                                                    final int gY = pendingScrollRestore[0];
                                                    final int cY = pendingScrollRestore[1];
                                                    groupSv.post(() -> groupSv.scrollTo(0, gY));
                                                    chanSv.post(() -> chanSv.scrollTo(0, cY));
                                                }
                                            });
                                } catch (Exception e) {
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqSeq[0]) return;
                                                chanCol.removeAllViews();
                                                chanCol.addView(
                                                        a.text(
                                                                "读取直播源失败：" + a.message(e),
                                                                12.5f,
                                                                p.textSecondary));
                                            });
                                }
                            });
                };

        refreshBtn.setOnClickListener(v -> loadCatalog[0].run());
        loadCatalog[0].run();
    }

    private static void applyChannelRowHighlight(
            MainActivity a, MobileTheme.Palette p, ChannelRowHolder holder, boolean playingThis) {
        if (playingThis) {
            holder.row.setBackground(a.bg(p.pillSelectedFill, 14));
            UiCompat.setElevation(holder.row, 0f);
        } else {
            holder.row.setBackground(MobileTheme.cardBg(a, 14));
            UiCompat.setElevation(holder.row, p.isDark ? 0f : a.dp(1.5f));
        }
        holder.nameView.setTextColor(playingThis ? p.accent : p.textPrimary);
        holder.trailingSlot.removeAllViews();
        if (playingThis) {
            MobileIcons.IconView liveInd =
                    MobileIcons.create(a, MobileIcons.IC_LIVE, 16f, p.accent);
            liveInd.setFilled(true);
            holder.trailingSlot.addView(
                    liveInd, new FrameLayout.LayoutParams(a.dp(16), a.dp(16), Gravity.CENTER));
        } else {
            MobileIcons.IconView chev =
                    MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 13f, p.textTertiary);
            holder.trailingSlot.addView(
                    chev, new FrameLayout.LayoutParams(a.dp(13), a.dp(13), Gravity.CENTER));
        }
    }

    private static TextView buildCallsignBadge(MainActivity a, String rawName) {
        String name = rawName == null ? "TV" : rawName.trim();
        String upper = name.toUpperCase(Locale.ROOT);
        int bgColor = 0xFF2563EB;
        String label;
        if (upper.startsWith("CCTV")) {
            bgColor = 0xFFE11D48;
            String num = upper.replaceFirst("^CCTV[-\\s]*", "").replaceAll("[^0-9A-Z+]", "");
            if (num.length() > 3) num = num.substring(0, 3);
            label = num.isEmpty() ? "CCTV" : ("CC\n" + num);
        } else if (name.contains("卫视")) {
            bgColor = 0xFFD97706;
            String p = name.replaceAll("卫视.*$", "").trim();
            label = p.length() >= 2 ? p.substring(0, 2) : "卫视";
        } else if (upper.contains("4K") || upper.contains("8K")) {
            bgColor = 0xFF7C3AED;
            label = upper.contains("8K") ? "8K" : "4K";
        } else {
            String clean = name.replaceAll("[\\[\\(（【].*?[\\]\\)）】]", "").trim();
            label = clean.length() >= 2 ? clean.substring(0, 2) : (clean.isEmpty() ? "TV" : clean);
        }
        TextView tv = a.text(label, 10.5f, Color.WHITE);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setGravity(Gravity.CENTER);
        tv.setBackground(a.bg(bgColor, 10));
        return tv;
    }
}

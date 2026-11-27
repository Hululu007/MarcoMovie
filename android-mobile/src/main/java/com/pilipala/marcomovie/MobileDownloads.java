package com.pilipala.marcomovie;

import android.graphics.Typeface;
import android.net.Uri;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Phone and tablet offline download UI (Day/Night {@link MobileTheme} + {@link MobileIcons} +
 * {@link MobileBottomSheet} + {@link MobileMotion}):
 * - Live offline download list under {@code 片库 → 离线}
 * - Batch episode download sheet opened from {@link MobileDetailScreen} with dynamic header reset
 *   (hidden when 0 episodes selected) and destructive deletion confirmation.
 */
final class MobileDownloads {
    private final MainActivity a;
    private final DownloadManager manager;
    private final LinearLayout holder;
    private final Map<String, Row> rows = new HashMap<>();
    private final int ticket;
    private String signature = "";

    private static final class Row {
        TextView status;
        View fill;
        View rest;
    }

    private MobileDownloads(MainActivity activity, LinearLayout parent) {
        a = activity;
        manager = DownloadManager.get(activity);
        holder = activity.vertical();
        ticket = activity.generation;
        parent.addView(holder, new LinearLayout.LayoutParams(-1, -2));
    }

    /** Renders the download list into the Library tab and keeps it refreshed while visible. */
    static void render(MainActivity a, LinearLayout parent) {
        MobileTheme.Palette p = MobileTheme.of(a);
        if (a.privateMode) {
            LinearLayout box = a.vertical();
            box.setGravity(Gravity.CENTER_HORIZONTAL);
            box.setPadding(a.dp(24), a.dp(52), a.dp(24), a.dp(48));
            FrameLayout badge =
                    MobileIcons.badge(a, MobileIcons.IC_PRIVACY, p.textSecondary, 50, 24);
            box.addView(badge, new LinearLayout.LayoutParams(a.dp(50), a.dp(50)));
            a.gap(box, 14);
            TextView head = a.text("隐私空间不保存离线缓存", 15.5f, p.textPrimary);
            head.setTypeface(null, Typeface.BOLD);
            head.setGravity(Gravity.CENTER);
            box.addView(head);
            a.gap(box, 6);
            TextView hint = a.text("切换回公开空间后即可查看或管理离线影片", 13f, p.textSecondary);
            hint.setGravity(Gravity.CENTER);
            box.addView(hint);
            parent.addView(box, new LinearLayout.LayoutParams(-1, -2));
            return;
        }
        MobileDownloads view = new MobileDownloads(a, parent);
        view.rebuild();
        a.ui.postDelayed(view::tick, 1000);
    }

    private void tick() {
        if (ticket != a.generation || !holder.isAttachedToWindow() || a.isFinishing()) return;
        if (a.foreground) update();
        a.ui.postDelayed(this::tick, 1000);
    }

    private void update() {
        List<DownloadManager.Task> tasks = manager.snapshot();
        if (!signature(tasks).equals(signature)) {
            rebuild();
            return;
        }
        for (DownloadManager.Task t : tasks) {
            Row row = rows.get(t.id);
            if (row != null) bind(row, t);
        }
    }

    private static String signature(List<DownloadManager.Task> tasks) {
        StringBuilder out = new StringBuilder();
        for (DownloadManager.Task t : tasks) {
            out.append(t.id).append(':').append(t.state).append(';');
        }
        return out.toString();
    }

    private void rebuild() {
        MobileTheme.Palette p = MobileTheme.of(a);
        holder.removeAllViews();
        rows.clear();
        List<DownloadManager.Task> tasks = manager.snapshot();
        signature = signature(tasks);
        if (tasks.isEmpty()) {
            LinearLayout box = a.vertical();
            box.setGravity(Gravity.CENTER_HORIZONTAL);
            box.setPadding(a.dp(24), a.dp(52), a.dp(24), a.dp(36));

            FrameLayout badge = MobileIcons.badge(a, MobileIcons.IC_DOWNLOAD, p.accent, 50, 24);
            box.addView(badge, new LinearLayout.LayoutParams(a.dp(50), a.dp(50)));
            a.gap(box, 14);

            TextView head = a.text("暂无离线缓存影片", 15.5f, p.textPrimary);
            head.setTypeface(null, Typeface.BOLD);
            head.setGravity(Gravity.CENTER);
            box.addView(head);
            a.gap(box, 6);

            TextView hint = a.text("在影片详情页点击右上角下载按钮即可离线保存", 13f, p.textSecondary);
            hint.setGravity(Gravity.CENTER);
            box.addView(hint);
            a.gap(box, 18);

            TextView cta = a.text("去挑部影片离线缓存", 13.5f, p.accentOnFill);
            cta.setTypeface(null, Typeface.BOLD);
            cta.setGravity(Gravity.CENTER);
            cta.setPadding(a.dp(22), a.dp(10), a.dp(22), a.dp(10));
            cta.setBackground(MobileTheme.accentPillBg(a, 999));
            MobileMotion.bindPress(cta, 0.94f);
            cta.setOnClickListener(v -> MobileRootShell.openTab(a, MobileRootShell.TAB_HOME));
            box.addView(cta, new LinearLayout.LayoutParams(-2, -2));

            holder.addView(box, new LinearLayout.LayoutParams(-1, -2));
        } else {
            holder.addView(toolbar(tasks, p), new LinearLayout.LayoutParams(-1, -2));
            a.gap(holder, 10);
            for (int i = tasks.size() - 1; i >= 0; i--) {
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
                lp.bottomMargin = a.dp(9);
                holder.addView(item(tasks.get(i), p), lp);
            }
            TextView where = a.text("保存位置：" + manager.folderPath(), 11.5f, p.textTertiary);
            where.setPadding(a.dp(4), a.dp(8), a.dp(4), a.dp(12));
            holder.addView(where, new LinearLayout.LayoutParams(-1, -2));
        }
    }

    private View toolbar(List<DownloadManager.Task> tasks, MobileTheme.Palette p) {
        int active = 0;
        int done = 0;
        int resumable = 0;
        for (DownloadManager.Task t : tasks) {
            if (t.state == DownloadManager.RUNNING || t.state == DownloadManager.WAITING) active++;
            if (t.state == DownloadManager.DONE) done++;
            if (t.state == DownloadManager.PAUSED || t.state == DownloadManager.FAILED) resumable++;
        }
        LinearLayout bar = a.row();
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(a.dp(4), 0, a.dp(4), 0);

        String label = "共 " + tasks.size() + " 项 · 进行中 " + active + " · 已完成 " + done;
        TextView summary = a.text(label, 12.5f, p.textSecondary);
        summary.setSingleLine(true);
        summary.setEllipsize(TextUtils.TruncateAt.END);
        bar.addView(summary, new LinearLayout.LayoutParams(0, -2, 1));

        if (resumable > 0) {
            LinearLayout startAll =
                    pillButton(
                            MobileIcons.IC_PLAY,
                            "全部开始",
                            p.accent,
                            MobileTheme.pillBg(a, true, 999));
            startAll.setTag("downloads-start-all");
            startAll.setOnClickListener(
                    v -> {
                        manager.resumeAll();
                        update();
                    });
            bar.addView(startAll);
        }
        if (active > 0) {
            LinearLayout pauseAll =
                    pillButton(
                            MobileIcons.IC_PAUSE,
                            "全部暂停",
                            p.textPrimary,
                            MobileTheme.subtleBg(a, 999));
            pauseAll.setTag("downloads-pause-all");
            pauseAll.setOnClickListener(
                    v -> {
                        manager.pauseAll();
                        update();
                    });
            LinearLayout.LayoutParams pauseLp = new LinearLayout.LayoutParams(-2, -2);
            pauseLp.leftMargin = a.dp(8);
            bar.addView(pauseAll, pauseLp);
        }
        return bar;
    }

    private LinearLayout pillButton(
            int iconId, String label, int textColor, android.graphics.drawable.Drawable bg) {
        LinearLayout chip = a.row();
        chip.setGravity(Gravity.CENTER);
        chip.setPadding(a.dp(11), a.dp(6), a.dp(12), a.dp(6));
        chip.setBackground(bg);
        if (iconId != 0) {
            MobileIcons.IconView iv = MobileIcons.create(a, iconId, 12f, textColor);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(a.dp(12), a.dp(12));
            ilp.rightMargin = a.dp(4);
            chip.addView(iv, ilp);
        }
        TextView tv = a.text(label, 12f, textColor);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setSingleLine(true);
        chip.addView(tv);
        MobileMotion.bindPress(chip, 0.94f);
        return chip;
    }

    private View item(DownloadManager.Task t, MobileTheme.Palette p) {
        LinearLayout row = a.row();
        row.setTag("download:" + t.id);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(11), a.dp(11), a.dp(12), a.dp(11));
        row.setBackground(MobileTheme.cardBg(a, 16));
        if (!p.isDark) UiCompat.setElevation(row, a.dp(1.5f));
        MobileMotion.bindPress(row, 0.98f);
        row.setOnClickListener(v -> primary(t));

        ImageView thumb = new ImageView(a);
        thumb.setScaleType(ImageView.ScaleType.CENTER_CROP);
        thumb.setBackground(MobileTheme.subtleBg(a, 10));
        thumb.setClipToOutline(true);
        LinearLayout.LayoutParams thumbLp = new LinearLayout.LayoutParams(a.dp(52), a.dp(74));
        thumbLp.rightMargin = a.dp(12);
        row.addView(thumb, thumbLp);
        if (!t.poster.isEmpty()) a.poster(t.poster, thumb);

        LinearLayout info = a.vertical();
        TextView title = a.text(t.title, 14.5f, p.textPrimary);
        title.setTypeface(null, Typeface.BOLD);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        info.addView(title);

        String detail = t.line.isEmpty() ? t.episode : t.episode + " · " + t.line;
        TextView sub = a.text(detail, 12f, p.textSecondary);
        sub.setSingleLine(true);
        sub.setEllipsize(TextUtils.TruncateAt.END);
        sub.setPadding(0, a.dp(3), 0, 0);
        info.addView(sub);

        Row holderRow = new Row();
        LinearLayout track = a.row();
        track.setBackground(MobileTheme.subtleBg(a, 999));
        LinearLayout.LayoutParams trackLp = new LinearLayout.LayoutParams(-1, a.dp(4));
        trackLp.topMargin = a.dp(8);
        info.addView(track, trackLp);
        holderRow.fill = new View(a);
        holderRow.rest = new View(a);
        track.addView(holderRow.fill, new LinearLayout.LayoutParams(0, -1, 0f));
        track.addView(holderRow.rest, new LinearLayout.LayoutParams(0, -1, 100f));

        holderRow.status = a.text("", 11.5f, p.textSecondary);
        holderRow.status.setMaxLines(2);
        holderRow.status.setEllipsize(TextUtils.TruncateAt.END);
        holderRow.status.setPadding(0, a.dp(6), 0, 0);
        info.addView(holderRow.status);
        row.addView(info, new LinearLayout.LayoutParams(0, -2, 1));

        LinearLayout actions = a.vertical();
        actions.setGravity(Gravity.END);

        LinearLayout main = buildPrimaryActionButton(t.state, p);
        main.setTag("download-action:" + t.id);
        main.setOnClickListener(v -> primary(t));
        actions.addView(main, new LinearLayout.LayoutParams(-2, -2));

        FrameLayout removeBtn = new FrameLayout(a);
        removeBtn.setTag("download-delete:" + t.id);
        removeBtn.setBackground(MobileTheme.subtleBg(a, 999));
        MobileIcons.IconView trashIc = MobileIcons.create(a, MobileIcons.IC_TRASH, 14f, p.danger);
        removeBtn.addView(
                trashIc, new FrameLayout.LayoutParams(a.dp(14), a.dp(14), Gravity.CENTER));
        MobileMotion.bindPress(removeBtn, 0.90f);
        removeBtn.setOnClickListener(v -> confirmDelete(t));
        LinearLayout.LayoutParams removeLp = new LinearLayout.LayoutParams(a.dp(32), a.dp(32));
        removeLp.topMargin = a.dp(7);
        actions.addView(removeBtn, removeLp);

        LinearLayout.LayoutParams actionsLp = new LinearLayout.LayoutParams(-2, -2);
        actionsLp.leftMargin = a.dp(10);
        row.addView(actions, actionsLp);

        rows.put(t.id, holderRow);
        bind(holderRow, t);
        return row;
    }

    private LinearLayout buildPrimaryActionButton(int state, MobileTheme.Palette p) {
        if (state == DownloadManager.DONE) {
            return pillButton(
                    MobileIcons.IC_PLAY, "播放", p.accentOnFill, MobileTheme.accentPillBg(a, 999));
        }
        if (state == DownloadManager.FAILED) {
            return pillButton(
                    MobileIcons.IC_REFRESH, "重试", p.accent, MobileTheme.pillBg(a, true, 999));
        }
        if (state == DownloadManager.PAUSED) {
            return pillButton(
                    MobileIcons.IC_PLAY, "继续", p.accent, MobileTheme.pillBg(a, true, 999));
        }
        return pillButton(MobileIcons.IC_PAUSE, "暂停", p.textPrimary, MobileTheme.subtleBg(a, 999));
    }

    private void bind(Row row, DownloadManager.Task t) {
        MobileTheme.Palette p = MobileTheme.of(a);
        int state = t.state;
        row.status.setText(t.status());
        row.status.setTextColor(statusColor(state, p));
        float done = Math.max(0, t.percent());
        weight(row.fill, done);
        weight(row.rest, 100f - done);
        row.fill.setBackground(a.bg(barColor(state, p), 999));
    }

    private static int statusColor(int state, MobileTheme.Palette p) {
        if (state == DownloadManager.FAILED) return p.danger;
        if (state == DownloadManager.DONE) return p.success;
        if (state == DownloadManager.RUNNING) return p.accent;
        return p.textSecondary;
    }

    private static int barColor(int state, MobileTheme.Palette p) {
        if (state == DownloadManager.FAILED) return p.danger;
        if (state == DownloadManager.DONE) return p.success;
        if (state == DownloadManager.PAUSED) return p.textTertiary;
        return p.accent;
    }

    private static void weight(View view, float value) {
        LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) view.getLayoutParams();
        if (lp.weight == value) return;
        lp.weight = value;
        view.setLayoutParams(lp);
    }

    private void primary(DownloadManager.Task t) {
        int state = t.state;
        if (state == DownloadManager.DONE) {
            play(a, t);
            return;
        }
        if (state == DownloadManager.RUNNING || state == DownloadManager.WAITING) {
            manager.pause(t.id);
        } else {
            manager.resume(t.id);
        }
        update();
    }

    private void confirmDelete(DownloadManager.Task t) {
        String name = t.title + " " + t.episode;
        MobileBottomSheet.showConfirm(
                a,
                "删除离线缓存？",
                "将删除「" + name + "」以及本地已下载文件，删除后需要重新缓存。",
                "删除",
                true,
                () -> {
                    manager.delete(t.id);
                    update();
                });
    }

    /** Plays a finished download offline through the regular player page. */
    static void play(MainActivity a, DownloadManager.Task t) {
        File file = t.path.isEmpty() ? null : new File(t.path);
        if (file == null || !file.isFile()) {
            a.toast("下载文件不存在，可能已被删除");
            return;
        }
        a.activeLine = null;
        a.activeEpisode = null;
        a.resumeAt = 0;
        Cms.Site site = new Cms.Site();
        site.key = "download";
        site.name = "本地下载";
        site.api = "";
        site.playUrl = "";
        Cms.Video video = new Cms.Video();
        video.id = "";
        video.title = t.episode.isEmpty() ? t.title : t.title + " · " + t.episode;
        video.poster = t.poster;
        Cms.Episode episode = new Cms.Episode();
        episode.name = t.episode;
        episode.url = Uri.fromFile(file).toString();
        if (file.getName().toLowerCase(Locale.ROOT).endsWith(".m3u8")) {
            try {
                episode.media.put("mimeType", DownloadManager.HLS_MIME);
            } catch (Exception ignored) {
            }
        }
        Runnable render = () -> a.playerPage(site, video, episode);
        MainActivity.Screen screen = new MainActivity.Screen(render);
        screen.player = true;
        a.open(screen, true);
    }

    // =========================================================================
    // Episode picker (mobile detail page — rendered inside MobileBottomSheet)
    // =========================================================================

    /**
     * Pure-JVM initial-selection index policy for {@link #pick}: returns {@code -1} (0 episodes
     * selected) when {@code preselectDefault} is {@code false}; otherwise matches {@code current}
     * by episode name or falls back to index {@code 0}.
     */
    static int resolveInitialPickIndex(
            List<Cms.Episode> episodes, String current, boolean preselectDefault) {
        if (episodes == null || episodes.isEmpty() || !preselectDefault) return -1;
        int initial = 0;
        if (current != null && !current.isEmpty()) {
            for (int i = 0; i < episodes.size(); i++) {
                Cms.Episode ep = episodes.get(i);
                if (ep != null && current.equals(ep.name)) {
                    initial = i;
                }
            }
        }
        return initial;
    }

    /** Lets the user pick episodes of one line; {@code current} (or episode 0) is preselected. */
    static void pick(MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, String current) {
        pick(a, s, v, line, current, true);
    }

    /**
     * Lets the user pick episodes of one line. When {@code preselectDefault} is {@code false}
     * (e.g. detail screen is awaiting explicit re-selection), starts with 0 episodes selected.
     */
    static void pick(
            MainActivity a,
            Cms.Site s,
            Cms.Video v,
            Cms.Line line,
            String current,
            boolean preselectDefault) {
        final int total = line.episodes.size();
        if (total == 0) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final boolean[] chosen = new boolean[total];
        int initial = resolveInitialPickIndex(line.episodes, current, preselectDefault);
        if (initial >= 0 && initial < total) {
            chosen[initial] = true;
        }
        final TextView[] cells = new TextView[total];
        final MobileBottomSheet.SheetHandle[] handleRef = {null};

        LinearLayout panel = a.vertical();
        panel.setPadding(0, a.dp(2), 0, a.dp(6));

        // Quick select-all chip row (only shown for multi-episode titles)
        final TextView selectAllChip = a.text("全选全部剧集", 12.5f, p.accent);
        if (total > 1) {
            LinearLayout tools = a.row();
            tools.setGravity(Gravity.CENTER_VERTICAL);
            TextView tip = a.text("点选需要离线缓存的剧集", 12.5f, p.textSecondary);
            tools.addView(tip, new LinearLayout.LayoutParams(0, -2, 1f));

            selectAllChip.setTypeface(null, Typeface.BOLD);
            selectAllChip.setPadding(a.dp(12), a.dp(5.5f), a.dp(12), a.dp(5.5f));
            selectAllChip.setBackground(MobileTheme.pillBg(a, true, 999));
            MobileMotion.bindPress(selectAllChip, 0.94f);
            tools.addView(selectAllChip);
            panel.addView(tools, new LinearLayout.LayoutParams(-1, -2));
            a.gap(panel, 10);
        }

        float widthDp = a.windowWidth() / a.getResources().getDisplayMetrics().density;
        int cols = widthDp >= 640 ? 6 : widthDp >= 480 ? 4 : 3;
        LinearLayout grid = a.vertical();
        panel.addView(grid, new LinearLayout.LayoutParams(-1, -2));

        // Primary confirm CTA at sheet bottom
        final LinearLayout startBtn = a.row();
        startBtn.setTag("download-pick-confirm");
        startBtn.setGravity(Gravity.CENTER);
        startBtn.setPadding(a.dp(18), a.dp(13), a.dp(18), a.dp(13));
        startBtn.setBackground(MobileTheme.accentPillBg(a, 999));
        final MobileIcons.IconView dlIcon =
                MobileIcons.create(a, MobileIcons.IC_DOWNLOAD, 16f, p.accentOnFill);
        LinearLayout.LayoutParams dliLp = new LinearLayout.LayoutParams(a.dp(16), a.dp(16));
        dliLp.rightMargin = a.dp(7);
        startBtn.addView(dlIcon, dliLp);
        final TextView startLbl = a.text("开始缓存 (1 集)", 14.5f, p.accentOnFill);
        startLbl.setTypeface(null, Typeface.BOLD);
        startBtn.addView(startLbl);
        MobileMotion.bindPress(startBtn, 0.96f);

        final Runnable syncSelectionUi =
                () -> {
                    int count = countChosen(chosen);
                    if (handleRef[0] != null) {
                        handleRef[0].setSubtitle(summaryText(chosen));
                        // Hide "清空" header action whenever 0 episodes are selected
                        handleRef[0].setAction("清空", count > 0);
                    }
                    if (total > 1) {
                        selectAllChip.setVisibility(count < total ? View.VISIBLE : View.GONE);
                    }
                    if (count > 0) {
                        startBtn.setBackground(MobileTheme.accentPillBg(a, 999));
                        dlIcon.setTint(p.accentOnFill);
                        startLbl.setTextColor(p.accentOnFill);
                        startLbl.setText("开始缓存 (" + count + " 集)");
                    } else {
                        startBtn.setBackground(MobileTheme.subtleBg(a, 999));
                        dlIcon.setTint(p.textTertiary);
                        startLbl.setTextColor(p.textTertiary);
                        startLbl.setText("请选择要缓存的剧集");
                    }
                };

        LinearLayout rowView = null;
        for (int i = 0; i < total; i++) {
            if (i % cols == 0) {
                rowView = a.row();
                grid.addView(rowView, new LinearLayout.LayoutParams(-1, -2));
            }
            final int index = i;
            final TextView cell = a.text(line.episodes.get(i).name, 13, p.textPrimary);
            cell.setTag("download-pick:" + i);
            cell.setGravity(Gravity.CENTER);
            cell.setSingleLine(true);
            cell.setEllipsize(TextUtils.TruncateAt.END);
            cell.setPadding(a.dp(8), a.dp(10), a.dp(8), a.dp(10));
            MobileMotion.bindPress(cell, 0.94f);
            cell.setOnClickListener(
                    view -> {
                        chosen[index] = !chosen[index];
                        styleCell(a, p, cells[index], chosen[index]);
                        if (chosen[index]) {
                            MobileMotion.popBounce(cells[index]);
                        }
                        syncSelectionUi.run();
                    });
            styleCell(a, p, cell, chosen[i]);
            cells[i] = cell;
            LinearLayout.LayoutParams cellLp = new LinearLayout.LayoutParams(0, -2, 1);
            cellLp.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
            rowView.addView(cell, cellLp);
        }
        int rem = total % cols;
        if (rem > 0 && rowView != null) {
            for (int i = rem; i < cols; i++) {
                LinearLayout.LayoutParams blankLp = new LinearLayout.LayoutParams(0, 1, 1);
                blankLp.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
                rowView.addView(new View(a), blankLp);
            }
        }

        LinearLayout.LayoutParams btnLp = new LinearLayout.LayoutParams(-1, -2);
        btnLp.topMargin = a.dp(14);
        panel.addView(startBtn, btnLp);

        selectAllChip.setOnClickListener(
                view -> {
                    for (int i = 0; i < total; i++) {
                        chosen[i] = true;
                        styleCell(a, p, cells[i], true);
                    }
                    syncSelectionUi.run();
                });

        startBtn.setOnClickListener(
                view -> {
                    List<Cms.Episode> picked = new ArrayList<>();
                    for (int i = 0; i < total; i++) {
                        if (chosen[i]) picked.add(line.episodes.get(i));
                    }
                    if (picked.isEmpty()) {
                        MobileMotion.shakeInvalid(startBtn);
                        a.toast("请至少选择一集");
                        return;
                    }
                    if (handleRef[0] != null) handleRef[0].dismiss();
                    enqueue(a, s, v, line, picked);
                });

        Runnable onClear =
                () -> {
                    for (int i = 0; i < total; i++) {
                        chosen[i] = false;
                        styleCell(a, p, cells[i], false);
                    }
                    syncSelectionUi.run();
                };

        handleRef[0] =
                MobileBottomSheet.showHandle(
                        a,
                        "离线缓存 · " + line.name,
                        summaryText(chosen),
                        countChosen(chosen) > 0 ? "清空" : "",
                        onClear,
                        panel,
                        true);
        syncSelectionUi.run();
    }

    private static void styleCell(
            MainActivity a, MobileTheme.Palette p, TextView cell, boolean selected) {
        if (selected) {
            cell.setTextColor(p.accentOnFill);
            cell.setTypeface(null, Typeface.BOLD);
            cell.setBackground(MobileTheme.accentPillBg(a, 10));
        } else {
            cell.setTextColor(p.textPrimary);
            cell.setTypeface(null, Typeface.NORMAL);
            cell.setBackground(MobileTheme.subtleBg(a, 10));
        }
    }

    private static int countChosen(boolean[] chosen) {
        int count = 0;
        for (boolean value : chosen) {
            if (value) count++;
        }
        return count;
    }

    private static String summaryText(boolean[] chosen) {
        return "已选 " + countChosen(chosen) + " / " + chosen.length + " 集";
    }

    /** Queues episodes for download and reports the result with a toast. */
    static void enqueue(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, List<Cms.Episode> picked) {
        if (picked.isEmpty()) {
            a.toast("请至少选择一集");
            return;
        }
        if (a.privateMode) {
            a.toast("隐私空间不加入公共下载列表");
            return;
        }
        int added = DownloadManager.get(a).enqueue(s, v, line, picked);
        int skipped = picked.size() - added;
        if (added == 0) {
            a.toast("所选剧集已在离线缓存列表中");
            return;
        }
        String extra = skipped > 0 ? "（" + skipped + " 集已存在）" : "";
        a.toast("已加入离线缓存 " + added + " 集" + extra + "，可在「片库 → 离线」查看");
    }
}

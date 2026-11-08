package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Color;
import android.view.*;
import android.widget.*;
import java.util.*;

/** Independent TV playback controls. Every visible action is wired to playback state. */
final class PlaybackControls {
    final MainActivity a;
    final Cms.Site site;
    final Cms.Video video;
    final Cms.Episode resolved;
    final LinearLayout dockOverlay;
    final SeekBar timeline;
    final SubtitleOverlayView subtitle;
    final VideoOutput surface;
    final PlaybackEffects effects = new PlaybackEffects();
    final DanmakuView danmaku;
    boolean danmakuLoaded;
    boolean currentMobileLandscape;
    final Map<String, Button> buttons = new LinkedHashMap<>();
    Dialog activeDialog;
    View menuAnchor;
    String lastSubtitle = "";
    boolean dialogOpen, transitioning;
    boolean touchSeeking, sliderSeeking;
    long lastSeekTimeMs;
    int lastSeekTargetMs = -1;
    int pendingResumeMs;
    int videoWidth, videoHeight;

    boolean isUserSeeking() {
        return touchSeeking || sliderSeeking;
    }

    void recordUserSeek(int targetMs) {
        lastSeekTimeMs = android.os.SystemClock.uptimeMillis();
        lastSeekTargetMs = Math.max(0, targetMs);
        timeline.setProgress(lastSeekTargetMs);
    }

    int displayPosition(int actualPositionMs) {
        if (lastSeekTargetMs >= 0
                && android.os.SystemClock.uptimeMillis() - lastSeekTimeMs < 3500
                && Math.abs(actualPositionMs - lastSeekTargetMs) > 2500) {
            return lastSeekTargetMs;
        }
        return actualPositionMs;
    }

    PlaybackControls(
            MainActivity host,
            LinearLayout overlay,
            LinearLayout progress,
            VideoOutput texture,
            Cms.Site s,
            Cms.Video v,
            Cms.Episode ep) {
        a = host;
        site = s;
        video = v;
        resolved = ep;
        dockOverlay = overlay;
        surface = texture;
        danmaku =
                new DanmakuView(
                        a,
                        new DanmakuView.Clock() {
                            public int position() {
                                return a.player == null ? 0 : a.player.getCurrentPosition();
                            }

                            public boolean playing() {
                                return a.player != null && a.player.isPlaying();
                            }
                        });
        a.playbackLayer.addView(danmaku, 1, new FrameLayout.LayoutParams(-1, -1));
        danmaku.enabled(false);
        subtitle = new SubtitleOverlayView(a);
        subtitle.setUserDefaultStyle();
        subtitle.setPadding(a.dp(40), 0, a.dp(40), a.dp(12));
        FrameLayout.LayoutParams caption = new FrameLayout.LayoutParams(-1, -1, Gravity.BOTTOM);
        caption.bottomMargin = a.dp(168);
        a.playbackLayer.addView(subtitle, 1, caption);
        applySubtitleStyle();
        timeline = new SeekBar(a);
        timeline.setTag("timeline");
        timeline.setBackgroundColor(Color.TRANSPARENT);
        timeline.setFocusable(true);
        timeline.setOnFocusChangeListener(
                (focusedView, f) ->
                        FocusMotion.style(
                                a,
                                timeline,
                                f,
                                0,
                                0x16ffffff,
                                16,
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                false,
                                1));
        UiCompat.tintSeekBar(timeline, 0xfff5f5f7, Color.WHITE);
        timeline.setKeyProgressIncrement(15000);
        progress.addView(timeline, new LinearLayout.LayoutParams(-1, a.dp(32)));
        timeline.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    public void onStartTrackingTouch(SeekBar b) {
                        sliderSeeking = true;
                        a.finishSeek(false);
                        a.scheduleHide();
                    }

                    public void onStopTrackingTouch(SeekBar b) {
                        boolean wasDragging = sliderSeeking;
                        sliderSeeking = false;
                        if (wasDragging && a.prepared && a.player != null) {
                            int target = b.getProgress();
                            recordUserSeek(target);
                            a.player.seekTo(target);
                            if (a.playClock != null && a.player.getDuration() > 0) {
                                a.playClock.setText(
                                        PlaybackController.formatTime(target)
                                                + " / "
                                                + PlaybackController.formatTime(
                                                        a.player.getDuration()));
                            }
                        }
                        a.scheduleHide();
                    }

                    public void onProgressChanged(SeekBar b, int position, boolean user) {
                        if (user && a.prepared && a.player != null) {
                            if (sliderSeeking) {
                                if (a.playClock != null && a.player.getDuration() > 0) {
                                    a.playClock.setText(
                                            PlaybackController.formatTime(position)
                                                    + " / "
                                                    + PlaybackController.formatTime(
                                                            a.player.getDuration()));
                                }
                            } else {
                                recordUserSeek(position);
                                a.player.seekTo(position);
                            }
                            a.scheduleHide();
                        }
                    }
                });
        boolean mobileLandscape = !a.isTvDevice() && !a.isPortrait();
        currentMobileLandscape = mobileLandscape;
        LinearLayout row = a.row();
        boolean live = "live".equals(site.key);
        if (a.isTvDevice()) {
            add(
                    row,
                    live ? "下台" : "下一集",
                    "next-episode",
                    () -> {
                        if (live) a.liveStep(1);
                        else if (!step(1)) showBubble("无下集", new String[] {"知道了"}, -1, i -> {}, "");
                    });
            add(
                    row,
                    live ? "频道" : "选集",
                    "episodes",
                    () -> {
                        if (live) a.chooseLiveChannel();
                        else chooseEpisodes();
                    });
            add(
                    row,
                    live ? "线路" : "换源",
                    "lines",
                    () -> {
                        if (live) a.chooseLiveStream();
                        else chooseLine();
                    });
            add(row, "倍速", "speed", this::speed);
            add(row, "音轨", "audio-tracks", () -> tracks(1));
            add(row, "解码", "decoder", this::decoderMenu);
            add(row, "片头", "skip-intro-tool", () -> skip(true));
            add(row, "片尾", "skip-outro-tool", () -> skip(false));
            add(row, "更多", "more", this::more);
            // Keep aspect/subtitles action references in map for programmatic callers
            registerHiddenAction("aspect", this::aspect);
            registerHiddenAction("subtitles", () -> tracks(3));
        } else {
            if (!live) {
                add(
                        row,
                        "上集",
                        "prev-episode",
                        () -> {
                            if (!step(-1))
                                showBubble("已是第一集", new String[] {"知道了"}, -1, i -> {}, "");
                        });
            }
            add(
                    row,
                    live ? "下台" : "下集",
                    "next-episode",
                    () -> {
                        if (live) a.liveStep(1);
                        else if (!step(1)) showBubble("无下集", new String[] {"知道了"}, -1, i -> {}, "");
                    });
            add(
                    row,
                    live ? "频道" : "选集",
                    "episodes",
                    () -> {
                        if (live) a.chooseLiveChannel();
                        else chooseEpisodes();
                    });
            add(
                    row,
                    "换源",
                    "lines",
                    () -> {
                        if (live) a.chooseLiveStream();
                        else chooseLine();
                    });
            add(row, "1.0×", "speed", this::speed);
            add(row, "画面", "aspect", this::aspect);
            add(row, "字幕", "subtitles", () -> tracks(3));
            add(row, "全屏", "fullscreen-tool", a::togglePlayerOrientation);
            add(row, "音轨", "audio-tracks", () -> tracks(1));
            add(row, "解码", "decoder", this::decoderMenu);
            add(row, "弹幕", "danmaku-tool", this::danmaku);
            add(row, "跳片头", "skip-intro-tool", () -> skip(true));
            add(row, "跳片尾", "skip-outro-tool", () -> skip(false));
            add(row, "循环", "repeat-tool", this::repeat);
            add(
                    row,
                    "重播",
                    "restart-tool",
                    () -> {
                        if (a.player != null && a.prepared) {
                            a.player.seekTo(0);
                            a.player.start();
                            a.playing = true;
                        } else reload(false);
                    });
            add(row, "更多", "more", this::more);
        }
        timeline.setId(UiCompat.generateViewId());
        List<Button> all = new ArrayList<>();
        for (int i = 0; i < row.getChildCount(); i++) {
            View child = row.getChildAt(i);
            if (child instanceof Button) all.add((Button) child);
        }
        for (Button b : all) b.setId(UiCompat.generateViewId());
        for (Button b : all) b.setNextFocusUpId(timeline.getId());
        timeline.setNextFocusDownId(all.get(0).getId());
        all.get(0).setNextFocusLeftId(all.get(all.size() - 1).getId());
        all.get(all.size() - 1).setNextFocusRightId(all.get(0).getId());
        all.get(0)
                .setOnKeyListener(
                        (view, key, event) -> {
                            if (key != KeyEvent.KEYCODE_DPAD_LEFT) return false;
                            if (event.getAction() == KeyEvent.ACTION_DOWN)
                                all.get(all.size() - 1).requestFocus();
                            return true;
                        });
        all.get(all.size() - 1)
                .setOnKeyListener(
                        (view, key, event) -> {
                            if (key != KeyEvent.KEYCODE_DPAD_RIGHT) return false;
                            if (event.getAction() == KeyEvent.ACTION_DOWN)
                                all.get(0).requestFocus();
                            return true;
                        });
        rebuildToolDock(mobileLandscape);
        updateLabels();
    }

    void relayout(boolean mobileLandscape) {
        if (mobileLandscape != currentMobileLandscape || dockOverlay.getChildCount() == 0) {
            currentMobileLandscape = mobileLandscape;
            rebuildToolDock(mobileLandscape);
        }
        Button fsTool = buttons.get("fullscreen-tool");
        if (fsTool != null) {
            fsTool.setText(mobileLandscape ? "竖屏" : "全屏");
        }
    }

    private void rebuildToolDock(boolean mobileLandscape) {
        dockOverlay.removeAllViews();
        boolean tv = a.isTvDevice();
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER);
        row.setClipChildren(false);
        row.setClipToPadding(false);
        row.setPadding(a.dp(1), a.dp(1), a.dp(1), a.dp(1));
        for (Button b : buttons.values()) {
            if (b.getVisibility() == View.GONE) continue;
            if (b.getParent() instanceof ViewGroup) {
                ((ViewGroup) b.getParent()).removeView(b);
            }
            b.setSingleLine(true);
            int padH = a.dp(mobileLandscape || tv ? 4 : 6);
            b.setPadding(padH, 0, padH, 0);
            int w = a.dp(mobileLandscape ? 64 : (tv ? 58 : 68));
            int h = a.dp(mobileLandscape ? 34 : 42);
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(w, h);
            int mh = a.dp(mobileLandscape ? 3 : (tv ? 3 : 4));
            int mv = a.dp(mobileLandscape ? 2 : 4);
            size.setMargins(mh, mv, mh, mv);
            row.addView(b, size);
        }
        Button fsTool = buttons.get("fullscreen-tool");
        if (fsTool != null) {
            fsTool.setText(mobileLandscape ? "竖屏" : "全屏");
        }
        if (false) {
        } else {
            HorizontalScrollView scroller =
                    new HorizontalScrollView(a) {
                        @Override
                        protected void dispatchDraw(Canvas canvas) {
                            int save = canvas.save();
                            canvas.clipRect(
                                    getScrollX(), 0, getScrollX() + getWidth(), getHeight());
                            super.dispatchDraw(canvas);
                            canvas.restoreToCount(save);
                        }
                    };
            scroller.setHorizontalScrollBarEnabled(false);
            scroller.setFillViewport(true);
            scroller.setClipChildren(true);
            scroller.setClipToPadding(true);
            scroller.addView(row);
            dockOverlay.addView(scroller, new LinearLayout.LayoutParams(-1, -2));
        }
    }

    void registerHiddenAction(String key, Runnable action) {
        Button b =
                a.button(
                        key,
                        key,
                        () -> {
                            menuAnchor = buttons.get("more");
                            action.run();
                        });
        b.setVisibility(View.GONE);
        buttons.put(key, b);
    }

    Button add(LinearLayout row, String title, String key, Runnable action) {
        Button b =
                a.button(
                        title,
                        key,
                        () -> {
                            menuAnchor = buttons.get(key);
                            action.run();
                        });
        b.setSingleLine(true);
        b.setEllipsize(android.text.TextUtils.TruncateAt.END);
        b.setTextSize(a.isTvDevice() ? 12.5f : 13f);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(a.dp(42));
        b.setMinimumHeight(a.dp(42));
        b.setBackground(a.bg(0x16ffffff, 19));
        int padH = a.dp(a.isTvDevice() ? 4 : 6);
        b.setPadding(padH, 0, padH, 0);
        b.setOnFocusChangeListener(
                (view, focused) -> {
                    FocusMotion.style(
                            a,
                            b,
                            focused,
                            0x16ffffff,
                            MainActivity.WHITE,
                            19,
                            MainActivity.WHITE,
                            MainActivity.DARK,
                            false,
                            1.025f);
                    b.setPadding(padH, 0, padH, 0);
                });
        int btnWidth = a.dp(a.isTvDevice() ? 58 : 68);
        int marginH = a.dp(a.isTvDevice() ? 3 : 4);
        LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(btnWidth, a.dp(42));
        size.setMargins(marginH, a.dp(4), marginH, a.dp(4));
        row.addView(b, size);
        buttons.put(key, b);
        return b;
    }

    int lineIndex() {
        return a.activeLine == null ? -1 : video.lines.indexOf(a.activeLine);
    }

    int episodeIndex() {
        return a.activeLine == null ? -1 : a.activeLine.episodes.indexOf(a.activeEpisode);
    }

    void choose(String title, String[] labels, int selected, PlayerBubble.IntAction action) {
        showBubble(title, labels, selected, action, "");
    }

    void message(String text) {
        showBubble("播放提示", new String[] {"完成"}, -1, i -> {}, text);
    }

    void showBubble(
            String title,
            String[] labels,
            int selected,
            PlayerBubble.IntAction action,
            String message) {
        if (activeDialog != null) {
            activeDialog.dismiss();
            activeDialog = null;
        }
        if (menuAnchor == null || !UiCompat.isAttached(menuAnchor))
            menuAnchor = buttons.get("more");
        dialogOpen = true;
        if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
        final Dialog[] holder = new Dialog[1];
        holder[0] =
                PlayerBubble.show(
                        a,
                        menuAnchor,
                        title,
                        labels,
                        selected,
                        action,
                        () -> {
                            if (activeDialog == holder[0]) {
                                activeDialog = null;
                                dialogOpen = false;
                                a.scheduleHide();
                            }
                        },
                        message);
        activeDialog = holder[0];
    }

    static final int EPISODE_GROUP_SIZE = 50;

    void chooseEpisodes() {
        int l = lineIndex();
        if (l < 0) {
            message("此内容没有可切换的剧集。");
            return;
        }
        Cms.Line line = video.lines.get(l);
        int total = line.episodes.size();
        int current = episodeIndex();
        if (total <= EPISODE_GROUP_SIZE) {
            String[] labels = new String[total];
            for (int i = 0; i < total; i++) labels[i] = line.episodes.get(i).name;
            choose(
                    line.name + " · 选集",
                    labels,
                    current,
                    i -> a.changeEpisode(site, video, line, line.episodes.get(i), 0));
            return;
        }
        int page = EpisodeSelection.pageFor(Math.max(0, current), total, false);
        chooseEpisodePage(line, page);
    }

    void chooseEpisodePage(Cms.Line line, int page) {
        int total = line.episodes.size();
        int groups = Math.max(1, (total + EPISODE_GROUP_SIZE - 1) / EPISODE_GROUP_SIZE);
        int safePage = Math.max(0, Math.min(page, groups - 1));
        int start = safePage * EPISODE_GROUP_SIZE;
        int end = Math.min(total, start + EPISODE_GROUP_SIZE);
        int count = end - start;
        String[] labels = new String[count + 1];
        labels[0] = "切换选集分组（当前 " + (start + 1) + "-" + end + " / 共 " + total + " 集）";
        int current = episodeIndex();
        int selected = 0;
        for (int i = 0; i < count; i++) {
            int epIndex = start + i;
            labels[i + 1] = line.episodes.get(epIndex).name;
            if (epIndex == current) selected = i + 1;
        }
        choose(
                line.name + " · 选集 (" + (start + 1) + "-" + end + ")",
                labels,
                selected,
                i -> {
                    if (i == 0) {
                        chooseEpisodeGroupList(line, safePage);
                    } else {
                        int target = start + (i - 1);
                        if (target >= 0 && target < total) {
                            a.changeEpisode(site, video, line, line.episodes.get(target), 0);
                        }
                    }
                });
    }

    void chooseEpisodeGroupList(Cms.Line line, int currentGroup) {
        int total = line.episodes.size();
        int groups = Math.max(1, (total + EPISODE_GROUP_SIZE - 1) / EPISODE_GROUP_SIZE);
        String[] groupLabels = new String[groups];
        for (int g = 0; g < groups; g++) {
            int gStart = g * EPISODE_GROUP_SIZE + 1;
            int gEnd = Math.min(total, (g + 1) * EPISODE_GROUP_SIZE);
            groupLabels[g] = "第 " + gStart + " - " + gEnd + " 集";
        }
        choose(line.name + " · 选择分组", groupLabels, currentGroup, g -> chooseEpisodePage(line, g));
    }

    void chooseLine() {
        org.json.JSONArray qualities =
                resolved != null && resolved.media != null
                        ? resolved.media.optJSONArray("qualities")
                        : null;
        int qCount = qualities != null && qualities.length() > 1 ? qualities.length() : 0;
        boolean canCrossSearch =
                video != null
                        && video.title != null
                        && !video.title.trim().isEmpty()
                        && !"live".equals(site.key);
        if (video.lines.isEmpty() && qCount == 0 && !canCrossSearch) {
            message("此内容只有当前地址。");
            return;
        }
        List<String> items = new ArrayList<>();
        int currentQualityIdx =
                resolved != null && resolved.media != null
                        ? resolved.media.optInt("_qualityIdx", 0)
                        : 0;
        for (int q = 0; q < qCount; q++) {
            org.json.JSONObject qObj = qualities.optJSONObject(q);
            String qName = qObj != null ? qObj.optString("name", "画质 " + (q + 1)) : "画质 " + (q + 1);
            items.add("画质 · " + qName + (q == currentQualityIdx ? "（当前）" : ""));
        }
        for (int i = 0; i < video.lines.size(); i++) {
            items.add((qCount > 0 ? "线路 · " : "") + video.lines.get(i).name);
        }
        final int crossSearchIndex = canCrossSearch ? items.size() : -1;
        if (canCrossSearch) {
            items.add("搜索同名其他片源 · " + video.title);
        }
        int selected = qCount > 0 ? currentQualityIdx : lineIndex();
        final int finalQCount = qCount;
        final org.json.JSONArray finalQualities = qualities;
        choose(
                qCount > 0 ? "选择画质或播放线路" : "换源 · 选择线路或片源",
                items.toArray(new String[0]),
                selected,
                i -> {
                    if (crossSearchIndex >= 0 && i == crossSearchIndex) {
                        a.leavePlayback();
                        a.crossSearch(Cms.searchTitle(video));
                        return;
                    }
                    if (i < finalQCount && finalQualities != null) {
                        org.json.JSONObject qObj = finalQualities.optJSONObject(i);
                        if (qObj != null) {
                            String nextUrl = qObj.optString("url", "");
                            if (!nextUrl.isEmpty()) {
                                try {
                                    resolved.media.put("_qualityIdx", i);
                                } catch (Exception ignored) {
                                }
                                resolved.url = LocalProxy.rewrite(nextUrl);
                                a.resumeAt =
                                        a.prepared && a.player != null
                                                ? a.player.getCurrentPosition()
                                                : 0;
                                a.playerPage(site, video, resolved);
                            }
                        }
                        return;
                    }
                    int lineIdx = i - finalQCount;
                    if (lineIdx >= 0 && lineIdx < video.lines.size()) {
                        Cms.Line line = video.lines.get(lineIdx);
                        if (!line.episodes.isEmpty()) {
                            int n = Math.min(Math.max(0, episodeIndex()), line.episodes.size() - 1);
                            a.changeEpisode(site, video, line, line.episodes.get(n), 0);
                        }
                    }
                });
    }

    boolean step(int direction) {
        int i = episodeIndex(), l = lineIndex();
        if (l < 0 || i < 0) return false;
        Cms.Line line = video.lines.get(l);
        int next = i + direction;
        if (a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 2)
            next = (next + line.episodes.size()) % line.episodes.size();
        if (next < 0 || next >= line.episodes.size()) return false;
        transitioning = true;
        a.changeEpisode(site, video, line, line.episodes.get(next), 0);
        return true;
    }

    void reload(boolean preserve) {
        int position =
                preserve && a.prepared && a.player != null ? a.player.getCurrentPosition() : 0;
        if (a.activeLine != null && a.activeEpisode != null)
            a.changeEpisode(site, video, a.activeLine, a.activeEpisode, position);
        else {
            a.resumeAt = position;
            a.playerPage(site, video, resolved);
        }
    }

    void speed() {
        if (a.player == null) return;
        float[] speeds = {.5f, .75f, 1f, 1.25f, 1.5f, 1.75f, 2f};
        String[] labels = {"0.5×", "0.75×", "1.0×", "1.25×", "1.5×", "1.75×", "2.0×"};
        int current = 2;
        for (int i = 0; i < speeds.length; i++) if (speeds[i] == a.player.getSpeed()) current = i;
        choose(
                "播放速度",
                labels,
                current,
                i -> {
                    if (a.player != null) a.player.setSpeed(speeds[i]);
                    a.prefs.edit().putFloat(Prefs.PLAY_SPEED, speeds[i]).apply();
                    updateLabels();
                });
    }

    void aspect() {
        String[] labels = {"适应画面", "铺满屏幕", "16:9", "4:3", "裁切填充"};
        choose(
                "画面比例",
                labels,
                a.prefs.getInt(Prefs.ASPECT, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.ASPECT, i).apply();
                    resize(videoWidth, videoHeight);
                    updateLabels();
                });
    }

    void engine() {
        choose(
                "选择播放器",
                new String[] {"Media3 · 网络与字幕优先", "系统播放器"},
                a.prefs.getInt(Prefs.PLAYER_ENGINE, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.PLAYER_ENGINE, i).apply();
                    reload(true);
                });
    }

    void output() {
        choose(
                "画面输出",
                new String[] {"保真输出 · HDR 与流畅度优先", "兼容输出 · 支持应用内调色"},
                a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.VIDEO_OUTPUT, i).apply();
                    reload(true);
                });
    }

    void decoder() {
        choose(
                "选择解码方式",
                new String[] {"自动选择（默认）", "设备硬件解码", "软件解码优先（高分辨率可能较慢）"},
                a.prefs.getInt(Prefs.DECODER_MODE, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.DECODER_MODE, i).apply();
                    updateLabels();
                    reload(true);
                });
    }

    void decoderMenu() {
        int decMode = a.prefs.getInt(Prefs.DECODER_MODE, 0);
        int engMode = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
        int outMode = a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0);
        String[] items = {
            (decMode == 0 ? "✓ " : "") + "自动解码（默认）",
            (decMode == 1 ? "✓ " : "") + "设备硬件解码 (HW)",
            (decMode == 2 ? "✓ " : "") + "软件解码优先 (SW)",
            "播放器内核 · " + (engMode == 0 ? "Media3" : "系统播放器"),
            "画面输出 · " + (outMode == 0 ? "保真输出 (HDR)" : "兼容输出 (调色)")
        };
        choose(
                "解码与播放器",
                items,
                decMode >= 0 && decMode <= 2 ? decMode : 0,
                i -> {
                    if (i >= 0 && i <= 2) {
                        a.prefs.edit().putInt(Prefs.DECODER_MODE, i).apply();
                        updateLabels();
                        reload(true);
                    } else if (i == 3) {
                        engine();
                    } else if (i == 4) {
                        output();
                    }
                });
    }

    void danmaku() {
        choose(
                "弹幕",
                new String[] {"开启 / 重新加载来源弹幕", "关闭弹幕", "导入本地弹幕 XML / JSON"},
                -1,
                i -> {
                    if (i == 1) {
                        danmaku.enabled(false);
                        return;
                    }
                    if (i == 2) {
                        a.pickDanmaku();
                        return;
                    }
                    String address = resolved.media.optString("danmaku");
                    if (address.isEmpty()) {
                        message("当前来源没有提供弹幕，可导入本地 XML / JSON。");
                        return;
                    }
                    danmaku.enabled(true);
                    danmaku.load(
                            address,
                            resolved.headers,
                            new DanmakuView.Listener() {
                                public void loaded(int count) {
                                    a.toast("已加载 " + count + " 条弹幕");
                                }

                                public void error(String message) {
                                    message(message);
                                }
                            });
                });
    }

    void soundEffect() {
        choose(
                "音效",
                new String[] {"原声", "影院", "人声清晰", "柔和低音"},
                a.prefs.getInt(Prefs.AUDIO_EFFECT, 0),
                i -> {
                    try {
                        if (a.player == null) throw new IllegalStateException();
                        effects.audio(a.player.getAudioSessionId(), i);
                        a.prefs.edit().putInt(Prefs.AUDIO_EFFECT, i).apply();
                    } catch (Exception error) {
                        message("这台设备当前音轨未提供可用音效接口。");
                    }
                });
    }

    void pictureEffect() {
        choose(
                "画面色彩",
                new String[] {"原始画面", "明亮", "影院", "柔和"},
                a.prefs.getInt(Prefs.PICTURE_EFFECT, 0),
                i -> {
                    if (i > 0 && !surface.supportsPicture()) {
                        message("当前使用保真输出，保留原始色彩。需要应用内调色时，可在“播放器与解码”选择兼容输出；HDR 内容建议保持保真输出。");
                        return;
                    }
                    PlaybackEffects.picture(surface, i);
                    a.prefs.edit().putInt(Prefs.PICTURE_EFFECT, i).apply();
                });
    }

    void close() {
        surface.setFrameAdvancing(false);
        if (activeDialog != null) {
            activeDialog.dismiss();
            activeDialog = null;
        }
        effects.close();
        danmaku.close();
    }

    static final int[] SUBTITLE_SIZES = {28, 35, 45, 55, 65};
    static final String[] SUBTITLE_SIZE_LABELS = {"极小", "小", "标准", "大", "超大"};
    static final int[] SUBTITLE_BOTTOMS = {8, 24, 48, 76, 110, 148};
    static final String[] SUBTITLE_BOTTOM_LABELS = {"贴底", "标准", "略高", "中下", "偏高", "较高"};

    void applySubtitleStyle() {
        int size = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        int bottomDp = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        int stylePreset = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
        subtitle.applyStylePreset(stylePreset);
        subtitle.setFractionalTextSize(size / 1000f);
        subtitle.setBottomPaddingFraction(0.02f + (bottomDp / 650f));
        visible(a.controlsVisible);
    }

    String subtitleSizeLabel() {
        int size = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
        for (int i = 0; i < SUBTITLE_SIZES.length; i++) {
            if (SUBTITLE_SIZES[i] == size) return SUBTITLE_SIZE_LABELS[i];
        }
        return size + "";
    }

    String subtitleBottomLabel() {
        int bottomDp = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        for (int i = 0; i < SUBTITLE_BOTTOMS.length; i++) {
            if (SUBTITLE_BOTTOMS[i] == bottomDp) return SUBTITLE_BOTTOM_LABELS[i];
        }
        return bottomDp + "dp";
    }

    String subtitleStyleLabel() {
        int style = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
        return SubtitleOverlayView.STYLE_LABELS[style];
    }

    void subtitleSizeDialog() {
        showSubtitleAdjuster(a, subtitle, this::applySubtitleStyle);
    }

    void subtitleBottomDialog() {
        showSubtitleAdjuster(a, subtitle, this::applySubtitleStyle);
    }

    static void showSubtitleAdjuster(
            MainActivity a, SubtitleOverlayView liveSub, Runnable onChanged) {
        final Dialog dlg = new Dialog(a);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        if (dlg.getWindow() != null) {
            dlg.getWindow()
                    .setBackgroundDrawable(
                            new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
            dlg.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        }
        if (liveSub != null) {
            liveSub.setPreviewActive(true);
            if (a.controlsVisible) a.showControls(false);
        }

        LinearLayout card = a.vertical();
        card.setPadding(a.dp(22), a.dp(18), a.dp(22), a.dp(18));
        android.graphics.drawable.GradientDrawable bg = a.bg(0xe8141c19, 22);
        bg.setStroke(a.dp(1), 0x40ffffff);
        card.setBackground(bg);
        card.setFocusable(true);
        card.setFocusableInTouchMode(true);

        TextView title = a.text("字幕方向键直调（实时生效）", 17, MainActivity.WHITE);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        card.addView(title);
        a.gap(card, 6);

        TextView guide =
                a.text(
                        a.isTvDevice()
                                ? "▲ ▼ 调整高度位置  ·  ◀ ▶ 调整字体大小  ·  确认键 切换字体颜色"
                                : "可使用方向键或下方按钮实时调节高度位置、字体大小与字体颜色",
                        12,
                        MainActivity.MUTED);
        card.addView(guide);
        a.gap(card, 10);

        final TextView statusView = a.text("", 14, 0xff2ad47a);
        statusView.setTypeface(null, android.graphics.Typeface.BOLD);
        card.addView(statusView);
        a.gap(card, 12);

        final SubtitleOverlayView previewBox;
        if (liveSub == null) {
            previewBox = new SubtitleOverlayView(a);
            previewBox.setBackground(a.bg(0xff0b110f, 14));
            previewBox.setPreviewActive(true);
            card.addView(previewBox, new LinearLayout.LayoutParams(-1, a.dp(92)));
            a.gap(card, 12);
        } else {
            previewBox = null;
        }

        final Runnable syncState =
                () -> {
                    int sz = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
                    int bt = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
                    int st = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                    statusView.setText(
                            "底部高度："
                                    + bt
                                    + "dp   ·   字体大小："
                                    + sz
                                    + "   ·   颜色样式："
                                    + SubtitleOverlayView.STYLE_LABELS[st]);
                    statusView.setTextColor(SubtitleOverlayView.STYLE_COLORS[st]);
                    if (previewBox != null) {
                        previewBox.applyStylePreset(st);
                        previewBox.setFractionalTextSize(sz / 1000f);
                        previewBox.setBottomPaddingFraction(0.02f + (bt / 650f));
                    }
                    if (onChanged != null) onChanged.run();
                };
        syncState.run();

        // java.util.function.IntConsumer is unavailable on Android 6 (API 23).
        final PlayerBubble.IntAction stepSize =
                delta -> {
                    int cur = Prefs.clampSubtitleSize(a.prefs.getInt(Prefs.SUBTITLE_SIZE, 45));
                    int next = Prefs.clampSubtitleSize(cur + delta);
                    a.prefs.edit().putInt(Prefs.SUBTITLE_SIZE, next).apply();
                    syncState.run();
                };
        final PlayerBubble.IntAction stepBottom =
                delta -> {
                    int cur = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
                    int next = Prefs.clampSubtitleBottom(cur + delta);
                    a.prefs.edit().putInt(Prefs.SUBTITLE_BOTTOM, next).apply();
                    syncState.run();
                };
        final Runnable cycleStyle =
                () -> {
                    int cur = Prefs.clampSubtitleStyle(a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                    int next = (cur + 1) % SubtitleOverlayView.STYLE_LABELS.length;
                    a.prefs.edit().putInt(Prefs.SUBTITLE_STYLE, next).apply();
                    syncState.run();
                };

        if (a.isTvDevice()) {
            TextView tvExitHint = a.text("✓ 每次调节均已实时保存  ·  按【返回键】或长按【确认键】完成退出", 12.5f, 0xffe5e7eb);
            tvExitHint.setGravity(Gravity.CENTER);
            tvExitHint.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
            tvExitHint.setBackground(a.bg(0x28ffffff, 12));
            card.addView(tvExitHint, new LinearLayout.LayoutParams(-1, -2));
        } else {
            LinearLayout controlsRow = a.row();
            controlsRow.setGravity(Gravity.CENTER);
            String[] btnLabels = {"字号 -", "字号 +", "▼ 下移", "▲ 上移", "切换颜色", "完成"};
            Runnable[] btnActions = {
                () -> stepSize.accept(-2),
                () -> stepSize.accept(2),
                () -> stepBottom.accept(-6),
                () -> stepBottom.accept(6),
                cycleStyle,
                dlg::dismiss
            };
            for (int i = 0; i < btnLabels.length; i++) {
                final Runnable act = btnActions[i];
                TextView b = a.text(btnLabels[i], 12, MainActivity.WHITE);
                b.setGravity(Gravity.CENTER);
                b.setPadding(a.dp(10), a.dp(8), a.dp(10), a.dp(8));
                b.setBackground(a.bg(i == btnLabels.length - 1 ? 0xff1f6f4a : 0x26ffffff, 12));
                b.setOnClickListener(v -> act.run());
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                lp.rightMargin = a.dp(6);
                controlsRow.addView(b, lp);
            }
            HorizontalScrollView hScroll = new HorizontalScrollView(a);
            hScroll.setHorizontalScrollBarEnabled(false);
            hScroll.addView(controlsRow);
            card.addView(hScroll, new LinearLayout.LayoutParams(-1, -2));
        }

        dlg.setOnKeyListener(
                (dialog, keyCode, event) -> {
                    if (event.getAction() != KeyEvent.ACTION_DOWN) return false;
                    if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) {
                        stepSize.accept(-2);
                        return true;
                    }
                    if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) {
                        stepSize.accept(2);
                        return true;
                    }
                    if (keyCode == KeyEvent.KEYCODE_DPAD_UP) {
                        stepBottom.accept(6);
                        return true;
                    }
                    if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
                        stepBottom.accept(-6);
                        return true;
                    }
                    if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                            || keyCode == KeyEvent.KEYCODE_ENTER) {
                        if (event.getRepeatCount() > 0) {
                            dlg.dismiss();
                            return true;
                        }
                        cycleStyle.run();
                        return true;
                    }
                    if (keyCode == KeyEvent.KEYCODE_BACK
                            || keyCode == KeyEvent.KEYCODE_ESCAPE
                            || keyCode == KeyEvent.KEYCODE_MENU) {
                        dlg.dismiss();
                        return true;
                    }
                    return false;
                });
        dlg.setOnDismissListener(
                d -> {
                    if (liveSub != null) {
                        liveSub.setPreviewActive(false);
                        if (onChanged != null) onChanged.run();
                    }
                });
        FrameLayout wrapper = new FrameLayout(a);
        FrameLayout.LayoutParams wlp =
                new FrameLayout.LayoutParams(
                        Math.min(a.windowWidth() - a.dp(32), a.dp(560)),
                        -2,
                        Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        wlp.topMargin = a.dp(32);
        wrapper.addView(card, wlp);
        dlg.setContentView(wrapper);
        dlg.show();
        card.requestFocus();
    }

    void tracks(int type) {
        if (type == 3) {
            List<String> tracks =
                    (a.player != null && a.prepared)
                            ? a.player.trackLabels(3)
                            : Collections.emptyList();
            List<String> labels = new ArrayList<>();
            labels.add(
                    "方向键直调字幕（大小 "
                            + subtitleSizeLabel()
                            + " · 位置 "
                            + subtitleBottomLabel()
                            + " · "
                            + subtitleStyleLabel()
                            + "）");
            labels.add("字幕样式 · " + subtitleStyleLabel());
            labels.add("关闭字幕");
            labels.addAll(tracks);
            labels.add("导入字幕文件…");
            choose(
                    "字幕与显示设置",
                    labels.toArray(new String[0]),
                    -1,
                    i -> {
                        if (i == 0) {
                            showSubtitleAdjuster(a, subtitle, this::applySubtitleStyle);
                        } else if (i == 1) {
                            int cur =
                                    Prefs.clampSubtitleStyle(
                                            a.prefs.getInt(Prefs.SUBTITLE_STYLE, 0));
                            choose(
                                    "字幕样式（默认透明底描边）",
                                    SubtitleOverlayView.STYLE_LABELS,
                                    cur,
                                    sIdx -> {
                                        a.prefs.edit().putInt(Prefs.SUBTITLE_STYLE, sIdx).apply();
                                        applySubtitleStyle();
                                    });
                        } else if (i == labels.size() - 1) {
                            a.pickSubtitle();
                        } else if (a.player != null && a.prepared) {
                            a.player.selectTrack(3, i == 2 ? -2 : i - 3);
                        }
                    });
            return;
        }
        if (a.player == null || !a.prepared) {
            message("请等待视频开始播放。");
            return;
        }
        List<String> tracks = a.player.trackLabels(type);
        List<String> labels = new ArrayList<>();
        labels.add("自动选择默认音轨");
        labels.addAll(tracks);
        final int trackOptionCount = labels.size();
        boolean swAudio = a.prefs.getBoolean(Prefs.SOFTWARE_AUDIO, false);
        labels.add("兼容音频解码：" + (swAudio ? "已开启" : "关闭"));
        labels.add("音效模式 · 设置");
        choose(
                "音轨与音频",
                labels.toArray(new String[0]),
                0,
                i -> {
                    if (i < trackOptionCount) {
                        if (a.player != null) a.player.selectTrack(type, i == 0 ? -1 : i - 1);
                    } else if (i == trackOptionCount) {
                        a.prefs.edit().putBoolean(Prefs.SOFTWARE_AUDIO, !swAudio).apply();
                        reload(true);
                    } else {
                        soundEffect();
                    }
                });
    }

    void skip(boolean intro) {
        int curPos = a.player != null && a.prepared ? a.player.getCurrentPosition() : 0;
        int curDur = a.player != null && a.prepared ? a.player.getDuration() : 0;
        showSkipAdjuster(a, intro, curPos, curDur, this::updateLabels);
    }

    static void showSkipAdjuster(
            MainActivity a,
            boolean intro,
            int currentPlayerPosMs,
            int currentPlayerDurMs,
            Runnable onChanged) {
        final String key = intro ? Prefs.SKIP_INTRO : Prefs.SKIP_OUTRO;
        final Dialog dlg = new Dialog(a);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        if (dlg.getWindow() != null) {
            dlg.getWindow()
                    .setBackgroundDrawable(
                            new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        }
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(22), a.dp(18), a.dp(22), a.dp(18));
        android.graphics.drawable.GradientDrawable bg = a.bg(0xf2161e1b, 22);
        bg.setStroke(a.dp(1), 0x38ffffff);
        card.setBackground(bg);

        TextView title = a.text(intro ? "手动精准设置跳过片头" : "手动精准设置跳过片尾", 17, MainActivity.WHITE);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        card.addView(title);
        a.gap(card, 6);

        TextView sub =
                a.text("拖动滑块或使用左右方向键精准定位到秒（00:00 - 03:00），也可一键抓取当前播放进度", 12, MainActivity.MUTED);
        card.addView(sub);
        a.gap(card, 14);

        final TextView valueLabel = a.text("", 18, 0xff2ad47a);
        valueLabel.setTypeface(null, android.graphics.Typeface.BOLD);
        card.addView(valueLabel);
        a.gap(card, 10);

        final SeekBar bar = new SeekBar(a);
        bar.setMax(180);
        bar.setKeyProgressIncrement(1);
        UiCompat.tintSeekBar(bar, 0xff2ad47a, Color.WHITE);
        int initialSec = Prefs.clampSkipSeconds(a.prefs.getInt(key, 0));
        bar.setProgress(initialSec);
        card.addView(bar, new LinearLayout.LayoutParams(-1, a.dp(36)));
        a.gap(card, 12);

        final PlayerBubble.IntAction applySec =
                sec -> {
                    int clamped = Prefs.clampSkipSeconds(sec);
                    a.prefs.edit().putInt(key, clamped).apply();
                    if (bar.getProgress() != clamped) bar.setProgress(clamped);
                    valueLabel.setText(
                            clamped <= 0
                                    ? "当前：已关闭（00:00）"
                                    : "当前："
                                            + PlaybackController.formatTime(clamped * 1000)
                                            + "（"
                                            + clamped
                                            + " 秒）");
                    if (onChanged != null) onChanged.run();
                };
        applySec.accept(initialSec);

        bar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    public void onStartTrackingTouch(SeekBar s) {}

                    public void onStopTrackingTouch(SeekBar s) {}

                    public void onProgressChanged(SeekBar s, int progress, boolean fromUser) {
                        if (fromUser) applySec.accept(progress);
                    }
                });

        if (currentPlayerPosMs > 0) {
            int candidateSec =
                    intro
                            ? (currentPlayerPosMs / 1000)
                            : (currentPlayerDurMs > currentPlayerPosMs
                                    ? (currentPlayerDurMs - currentPlayerPosMs) / 1000
                                    : (currentPlayerPosMs / 1000));
            final int captureSec = Prefs.clampSkipSeconds(Math.max(1, candidateSec));
            String captureText =
                    (intro ? "设为当前播放进度 · " : "设为当前剩余时长 · ")
                            + PlaybackController.formatTime(captureSec * 1000)
                            + " ("
                            + captureSec
                            + "秒)";
            TextView captureBtn = a.text(captureText, 13, MainActivity.WHITE);
            captureBtn.setGravity(Gravity.CENTER);
            captureBtn.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
            captureBtn.setBackground(a.bg(0xff1e5d41, 14));
            captureBtn.setFocusable(true);
            captureBtn.setOnClickListener(v -> applySec.accept(captureSec));
            card.addView(captureBtn, new LinearLayout.LayoutParams(-1, -2));
            a.gap(card, 10);
        }

        LinearLayout stepRow = a.row();
        stepRow.setGravity(Gravity.CENTER);
        String[] stepTitles = {"关闭", "-10秒", "-5秒", "-1秒", "+1秒", "+5秒", "+10秒", "完成"};
        int[] deltas = {0, -10, -5, -1, 1, 5, 10, 999};
        for (int i = 0; i < stepTitles.length; i++) {
            final int d = deltas[i];
            TextView b = a.text(stepTitles[i], 12, MainActivity.WHITE);
            b.setGravity(Gravity.CENTER);
            b.setPadding(a.dp(10), a.dp(8), a.dp(10), a.dp(8));
            b.setFocusable(true);
            b.setBackground(a.bg(d == 999 ? 0xff1f6f4a : 0x24ffffff, 12));
            b.setOnClickListener(
                    v -> {
                        if (d == 999) {
                            dlg.dismiss();
                        } else if (d == 0) {
                            applySec.accept(0);
                        } else {
                            applySec.accept(a.prefs.getInt(key, 0) + d);
                        }
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            lp.rightMargin = a.dp(6);
            stepRow.addView(b, lp);
        }
        HorizontalScrollView scroll = new HorizontalScrollView(a);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.addView(stepRow);
        card.addView(scroll, new LinearLayout.LayoutParams(-1, -2));

        FrameLayout wrapper = new FrameLayout(a);
        FrameLayout.LayoutParams wlp =
                new FrameLayout.LayoutParams(
                        Math.min(a.windowWidth() - a.dp(32), a.dp(540)), -2, Gravity.CENTER);
        wrapper.addView(card, wlp);
        dlg.setContentView(wrapper);
        dlg.show();
        bar.requestFocus();
    }

    void repeat() {
        choose(
                "循环播放",
                new String[] {"关闭", "单集循环", "列表循环"},
                a.prefs.getInt(Prefs.REPEAT_MODE, 0),
                i -> {
                    a.prefs.edit().putInt(Prefs.REPEAT_MODE, i).apply();
                    if (a.player != null)
                        a.player.setRepeatOne(i == 1 && a.prefs.getInt(Prefs.SKIP_OUTRO, 0) == 0);
                    updateLabels();
                });
    }

    void more() {
        if ("live".equals(site.key)) {
            String[] live = {"上一频道", "选择频道", "播放线路", "播放器与解码", "画面色彩", "播放信息", "返回频道列表"};
            choose(
                    "直播设置",
                    live,
                    -1,
                    i -> {
                        switch (i) {
                            case 0:
                                a.liveStep(-1);
                                break;
                            case 1:
                                a.chooseLiveChannel();
                                break;
                            case 2:
                                a.chooseLiveStream();
                                break;
                            case 3:
                                choose(
                                        "播放器与解码",
                                        new String[] {"切换播放器", "切换解码方式", "画面输出"},
                                        -1,
                                        n -> {
                                            if (n == 0) engine();
                                            else if (n == 1) decoder();
                                            else output();
                                        });
                                break;
                            case 4:
                                pictureEffect();
                                break;
                            case 5:
                                message(
                                        a.player == null
                                                ? "播放器尚未准备好。"
                                                : a.player.playbackInfo()
                                                        + "\n"
                                                        + surface.outputName());
                                break;
                            case 6:
                                a.leavePlayback();
                                break;
                        }
                    });
            return;
        }
        String[] labels = {
            "画面比例",
            "字幕与显示",
            "刷新播放",
            "从头重播",
            "上一集",
            "跳过片头 / 片尾",
            "弹幕",
            "音效",
            "画面色彩",
            "循环播放",
            "自动播放下集：" + (a.prefs.getBoolean(Prefs.AUTO_NEXT, true) ? "开启" : "关闭"),
            "播放信息",
            "返回详情"
        };
        choose(
                "更多",
                labels,
                -1,
                i -> {
                    switch (i) {
                        case 0:
                            aspect();
                            break;
                        case 1:
                            tracks(3);
                            break;
                        case 2:
                            reload(true);
                            break;
                        case 3:
                            pendingResumeMs = 0;
                            if (a.playingBookmark != null) a.playingBookmark.position = 0;
                            if (a.player != null && a.prepared) {
                                recordUserSeek(0);
                                a.player.seekTo(0);
                                a.player.start();
                                a.playing = true;
                            } else {
                                a.resumeAt = -1;
                                reload(false);
                            }
                            break;
                        case 4:
                            if (!step(-1)) message("已经是第一集。");
                            break;
                        case 5:
                            choose(
                                    "自动跳过",
                                    new String[] {
                                        "片头 · " + skipLabel(a.prefs.getInt(Prefs.SKIP_INTRO, 0)),
                                        "片尾 · " + skipLabel(a.prefs.getInt(Prefs.SKIP_OUTRO, 0))
                                    },
                                    -1,
                                    n -> skip(n == 0));
                            break;
                        case 6:
                            danmaku();
                            break;
                        case 7:
                            soundEffect();
                            break;
                        case 8:
                            pictureEffect();
                            break;
                        case 9:
                            repeat();
                            break;
                        case 10:
                            a.prefs
                                    .edit()
                                    .putBoolean(
                                            Prefs.AUTO_NEXT,
                                            !a.prefs.getBoolean(Prefs.AUTO_NEXT, true))
                                    .apply();
                            break;
                        case 11:
                            message(
                                    a.player == null
                                            ? "播放器尚未准备好。"
                                            : a.player.playbackInfo()
                                                    + "\n"
                                                    + surface.outputName());
                            break;
                        case 12:
                            a.leavePlayback();
                            break;
                    }
                });
    }

    void updateLabels() {
        float rate = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
        Button speedBtn = buttons.get("speed");
        if (speedBtn != null) {
            if (a.isTvDevice()) {
                speedBtn.setText(Math.abs(rate - 1f) < 0.01f ? "倍速" : rate + "×");
            } else {
                speedBtn.setText(rate + "×");
            }
        }
        Button introBtn = buttons.get("skip-intro-tool");
        if (introBtn != null) {
            int s = a.prefs.getInt(Prefs.SKIP_INTRO, 0);
            introBtn.setText(s > 0 ? "片头" + s + "s" : (a.isTvDevice() ? "片头" : "跳片头"));
        }
        Button outroBtn = buttons.get("skip-outro-tool");
        if (outroBtn != null) {
            int s = a.prefs.getInt(Prefs.SKIP_OUTRO, 0);
            outroBtn.setText(s > 0 ? "片尾" + s + "s" : (a.isTvDevice() ? "片尾" : "跳片尾"));
        }
    }

    String skipLabel(int seconds) {
        return seconds == 0 ? "关闭" : a.time(seconds * 1000);
    }

    void prepared() {
        if (a.player == null) return;
        if (a.prefs.getBoolean(Prefs.DANMAKU_DEFAULT, true)
                && !danmakuLoaded
                && !resolved.media.optString("danmaku").isEmpty()) {
            danmakuLoaded = true;
            danmaku.enabled(true);
            danmaku.load(
                    resolved.media.optString("danmaku"),
                    resolved.headers,
                    new DanmakuView.Listener() {
                        public void loaded(int count) {}

                        public void error(String message) {}
                    });
        }
        PlaybackEffects.picture(surface, a.prefs.getInt(Prefs.PICTURE_EFFECT, 0));
        try {
            effects.audio(a.player.getAudioSessionId(), a.prefs.getInt(Prefs.AUDIO_EFFECT, 0));
        } catch (Exception ignored) {
        }
        int duration = a.player.getDuration();
        if (duration <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
            duration = a.playingBookmark.duration;
        }
        timeline.setEnabled(duration > 0);
        timeline.setMax(duration > 0 ? duration : 100);
        if (duration <= 0) timeline.setProgress(0);
        timeline.setKeyProgressIncrement(15000);
        boolean explicitRestart = a.resumeAt < 0;
        boolean historyResume = a.resumeAt > 0;
        int seek =
                ("live".equals(site.key) || explicitRestart)
                        ? 0
                        : historyResume ? a.resumeAt : a.prefs.getInt(Prefs.SKIP_INTRO, 0) * 1000;
        a.resumeAt = 0;
        if (seek > 0) {
            if (duration > 0) {
                if (seek < duration - 1000) {
                    pendingResumeMs = 0;
                    recordUserSeek(seek);
                    a.player.seekTo(seek);
                    if (historyResume) {
                        a.toast("已为您续播至 " + PlaybackController.formatTime(seek));
                    }
                }
            } else {
                pendingResumeMs = seek;
                if (historyResume) {
                    a.toast("已为您续播至 " + PlaybackController.formatTime(seek));
                }
            }
        }
        a.player.setSpeed(a.prefs.getFloat(Prefs.PLAY_SPEED, 1));
        a.player.setRepeatOne(
                a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 1
                        && a.prefs.getInt(Prefs.SKIP_OUTRO, 0) == 0);
    }

    void tick() {
        if ("live".equals(site.key)) return;
        if (a.player == null || !a.prepared || isUserSeeking()) return;
        int duration = a.player.getDuration();
        if (duration <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
            duration = a.playingBookmark.duration;
        }
        if (pendingResumeMs > 0 && duration > 0) {
            int target = pendingResumeMs;
            pendingResumeMs = 0;
            if (target < duration - 1000
                    && a.player.getCurrentPosition() < Math.min(target - 2000, 5000)) {
                recordUserSeek(target);
                a.player.seekTo(target);
            }
        }
        int position = displayPosition(a.player.getCurrentPosition());
        if (duration > 0) {
            timeline.setEnabled(true);
            timeline.setMax(Math.max(duration, position));
            timeline.setProgress(Math.max(0, Math.min(position, timeline.getMax())));
        } else {
            timeline.setEnabled(false);
            timeline.setMax(100);
            timeline.setProgress(0);
        }
        int tail = a.prefs.getInt(Prefs.SKIP_OUTRO, 0) * 1000;
        if (!transitioning
                && a.playing
                && duration > 0
                && tail > 0
                && tail < duration
                && position >= duration - tail) {
            if (a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 1)
                a.player.seekTo(a.prefs.getInt(Prefs.SKIP_INTRO, 0) * 1000);
            else if (!step(1)) {
                transitioning = true;
                a.player.pause();
                a.playing = false;
                a.playStatus.setText("已跳过片尾");
                a.showControls(true);
            }
        }
    }

    void completed() {
        if (!transitioning
                && (a.prefs.getBoolean(Prefs.AUTO_NEXT, true)
                        || a.prefs.getInt(Prefs.REPEAT_MODE, 0) == 2)
                && step(1)) return;
        a.showControls(true);
        a.playStatus.setText("播放结束 · 按确认重播");
    }

    void resize(int width, int height) {
        videoWidth = width;
        videoHeight = height;
        if (a.playerChrome != null) a.playerChrome.resolution(width, height);
        if (width <= 0 || height <= 0 || a.playbackLayer.getWidth() == 0) return;
        int w = a.playbackLayer.getWidth(),
                h = a.playbackLayer.getHeight(),
                mode = a.prefs.getInt(Prefs.ASPECT, 0);
        float ratio = mode == 2 ? 16f / 9 : mode == 3 ? 4f / 3 : (float) width / height;
        if (mode != 1) {
            if (mode == 4) {
                if ((float) w / h > ratio) h = Math.round(w / ratio);
                else w = Math.round(h * ratio);
            } else if ((float) w / h > ratio) w = Math.round(h * ratio);
            else h = Math.round(w / ratio);
        }
        surface.setLayoutParams(new FrameLayout.LayoutParams(w, h, Gravity.CENTER));
    }

    void visible(boolean visible) {
        int bottomDp = Prefs.clampSubtitleBottom(a.prefs.getInt(Prefs.SUBTITLE_BOTTOM, 24));
        int basePx = a.dp(bottomDp);
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) subtitle.getLayoutParams();
        if (lp.bottomMargin != basePx) {
            lp.bottomMargin = basePx;
            subtitle.setLayoutParams(lp);
        }
        if (subtitle.isPreviewActive()) {
            subtitle.setTranslationY(0f);
            return;
        }
        boolean progressOnly = a.playerChrome != null && a.playerChrome.progressOnlyMode;
        int targetPx =
                visible
                        ? a.dp(
                                progressOnly
                                        ? Math.max(82, bottomDp + 16)
                                        : Math.max(168, bottomDp + 24))
                        : basePx;
        subtitle.setTranslationY(-(targetPx - basePx));
    }
}

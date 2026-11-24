package com.pilipala.marcomovie;

import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import java.util.Map;
import java.util.Objects;
import org.json.JSONObject;

/**
 * Portrait inline {@code 16:9} mini-player mounted at the top of {@link MobileDetailScreen} when
 * {@link Prefs#DETAIL_TAP_MODE} is {@code 0} ("详情页内嵌小窗起播"). Shares the unified engine
 * selection, fallback ladder, proxy/cache, IntroDB v4 skip evaluator, and 15s history checkpointing
 * with {@link PlaybackController}, enforces single active playback lifecycle across backgrounding /
 * lock-screen / Home return, and seamlessly hands off to landscape fullscreen.
 */
final class MobileInlinePlayer {
    static final long CHECKPOINT_INTERVAL_MS = 15_000L;

    static final class ProgressCheckpointPolicy {
        private long lastWriteAtMs;
        private int lastSavedPosMs = -1;
        private String lastEpisodeKey = "";

        boolean shouldWrite(long nowMs, int posMs, int durMs, String episodeKey, boolean force) {
            if (durMs <= 0) return false;
            String ep = episodeKey == null ? "" : episodeKey;
            boolean episodeChanged = !ep.equals(lastEpisodeKey);
            if (force) {
                if (!episodeChanged
                        && lastSavedPosMs >= 0
                        && Math.abs(posMs - lastSavedPosMs) < 500) {
                    return false;
                }
                lastWriteAtMs = nowMs;
                lastSavedPosMs = posMs;
                lastEpisodeKey = ep;
                return true;
            }
            if (posMs < 1000 && lastSavedPosMs < 0) return false;
            if (episodeChanged
                    || lastWriteAtMs == 0L
                    || nowMs - lastWriteAtMs >= CHECKPOINT_INTERVAL_MS) {
                lastWriteAtMs = nowMs;
                lastSavedPosMs = posMs;
                lastEpisodeKey = ep;
                return true;
            }
            return false;
        }

        void reset() {
            lastWriteAtMs = 0L;
            lastSavedPosMs = -1;
            lastEpisodeKey = "";
        }
    }

    private final MainActivity a;
    private final FrameLayout hostSlot;
    private final Runnable onClosed;
    private final FrameLayout container;
    private final VideoOutput surfaceView;
    private final TextView titleLabel;
    private final TextView statusLabel;
    private final TextView playPauseBtn;
    private final TextView clockLabel;
    private final SeekBar seekBar;

    private Cms.Site site;
    private Cms.Video video;
    private Cms.Line activeLine;
    private Cms.Episode rawEpisode;
    private Cms.Episode resolvedEpisode;
    private int tmdbId;
    private boolean isTv = true;
    private int seasonNum = 1;
    private int epNum = 1;
    private MoviePlayer player;
    private PlaybackController.EnginePlan activeEnginePlan;
    private Surface renderSurface;
    private boolean prepared;
    private boolean userSeeking;
    private boolean closed;
    private boolean pausedForBackground;
    private int lastKnownPosMs;
    private int lastKnownDurMs;
    private int loadSerial;
    private long episodeToken;
    private final IntroSkipEvaluator skipEvaluator = new IntroSkipEvaluator();
    private final ProgressCheckpointPolicy checkpointPolicy = new ProgressCheckpointPolicy();

    private final Runnable ticker =
            new Runnable() {
                @Override
                public void run() {
                    if (closed || player == null || !prepared) return;
                    try {
                        int pos = player.getCurrentPosition();
                        int dur = player.getDuration();
                        if (pos > 0) lastKnownPosMs = pos;
                        if (dur > 0) lastKnownDurMs = dur;
                        if (!userSeeking && dur > 0) {
                            seekBar.setMax(dur);
                            seekBar.setProgress(pos);
                            clockLabel.setText(
                                    PlaybackController.formatTime(pos)
                                            + " / "
                                            + PlaybackController.formatTime(dur));
                        }
                        boolean autoNext = a.prefs.getBoolean(Prefs.AUTO_NEXT, true);
                        IntroSkipEvaluator.Decision decision =
                                skipEvaluator.evaluate(pos, dur, hasNextEpisode(), autoNext);
                        if (decision.action == IntroSkipEvaluator.ACTION_SEEK
                                && decision.targetMs >= 0L) {
                            player.seekTo((int) decision.targetMs);
                            if (!decision.toastMessage.isEmpty()) {
                                a.toast(decision.toastMessage);
                            }
                        } else if (decision.action == IntroSkipEvaluator.ACTION_NEXT_EPISODE) {
                            if (!decision.toastMessage.isEmpty()) {
                                a.toast(decision.toastMessage);
                            }
                            if (stepNextEpisode()) {
                                return;
                            }
                        }
                        saveHistoryProgress(pos, dur, false);
                    } catch (Exception ignored) {
                    }
                    a.ui.postDelayed(this, 1000);
                }
            };

    MobileInlinePlayer(MainActivity activity, FrameLayout hostSlot, Runnable onClosed) {
        this.a = activity;
        this.hostSlot = hostSlot;
        this.onClosed = onClosed;

        int stageH = Math.round(activity.windowWidth() * 9f / 16f);
        int topInset = activity.statusBarHeight();
        container = new FrameLayout(activity);
        container.setBackgroundColor(Color.BLACK);
        FrameLayout.LayoutParams slotLp = new FrameLayout.LayoutParams(-1, stageH + topInset);
        hostSlot.removeAllViews();
        hostSlot.addView(container, slotLp);
        hostSlot.setVisibility(View.VISIBLE);

        FrameLayout videoArea = new FrameLayout(activity);
        FrameLayout.LayoutParams vLp = new FrameLayout.LayoutParams(-1, stageH, Gravity.BOTTOM);
        container.addView(videoArea, vLp);

        surfaceView = new VideoOutput(activity, activity.prefs.getInt(Prefs.VIDEO_OUTPUT, 0) == 1);
        videoArea.addView(surfaceView, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        // Top bar inside inline window: Collapse '×', Title, Expand Fullscreen '⛶'
        LinearLayout topBar = activity.row();
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(activity.dp(10), activity.dp(6), activity.dp(10), activity.dp(6));
        topBar.setBackgroundColor(0x88000000);

        TextView closeBtn = activity.text("✕ 收起", 11.5f, Color.WHITE);
        closeBtn.setPadding(activity.dp(10), activity.dp(4), activity.dp(10), activity.dp(4));
        closeBtn.setBackground(activity.bg(0x40ffffff, 999));
        UiWidgets.bindTouchFeedback(closeBtn);
        closeBtn.setOnClickListener(
                v -> {
                    detach();
                    if (this.onClosed != null) this.onClosed.run();
                });
        topBar.addView(closeBtn);

        titleLabel = activity.text("", 12.5f, Color.WHITE);
        titleLabel.setTypeface(null, Typeface.BOLD);
        titleLabel.setSingleLine(true);
        titleLabel.setEllipsize(TextUtils.TruncateAt.END);
        titleLabel.setPadding(activity.dp(8), 0, activity.dp(8), 0);
        topBar.addView(titleLabel, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView expandBtn = activity.text("⛶ 横屏全屏", 11.5f, 0xff08120e);
        expandBtn.setTypeface(null, Typeface.BOLD);
        expandBtn.setPadding(activity.dp(11), activity.dp(4), activity.dp(11), activity.dp(4));
        expandBtn.setBackground(activity.bg(activity.mobileAccentColor(), 999));
        UiWidgets.bindTouchFeedback(expandBtn);
        expandBtn.setOnClickListener(v -> expandToFullscreen());
        topBar.addView(expandBtn);

        videoArea.addView(topBar, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        statusLabel = activity.text("正在解析播放地址…", 12.5f, 0xffe5e7eb);
        statusLabel.setPadding(activity.dp(14), activity.dp(7), activity.dp(14), activity.dp(7));
        statusLabel.setBackground(activity.bg(0xb8141a18, 999));
        videoArea.addView(statusLabel, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        // Bottom mini transport bar
        LinearLayout bottomBar = activity.row();
        bottomBar.setGravity(Gravity.CENTER_VERTICAL);
        bottomBar.setPadding(activity.dp(10), activity.dp(4), activity.dp(10), activity.dp(4));
        bottomBar.setBackgroundColor(0x99000000);

        playPauseBtn = activity.text("❚❚", 13f, Color.WHITE);
        playPauseBtn.setTypeface(null, Typeface.BOLD);
        playPauseBtn.setPadding(activity.dp(8), activity.dp(4), activity.dp(8), activity.dp(4));
        UiWidgets.bindTouchFeedback(playPauseBtn);
        playPauseBtn.setOnClickListener(v -> togglePlayPause());
        bottomBar.addView(playPauseBtn);

        seekBar = new SeekBar(activity);
        UiCompat.tintSeekBar(seekBar, activity.mobileAccentColor(), Color.WHITE);
        seekBar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    @Override
                    public void onProgressChanged(SeekBar b, int progress, boolean fromUser) {
                        if (fromUser && player != null && prepared) {
                            clockLabel.setText(
                                    PlaybackController.formatTime(progress)
                                            + " / "
                                            + PlaybackController.formatTime(player.getDuration()));
                        }
                    }

                    @Override
                    public void onStartTrackingTouch(SeekBar b) {
                        userSeeking = true;
                    }

                    @Override
                    public void onStopTrackingTouch(SeekBar b) {
                        userSeeking = false;
                        if (player != null && prepared) {
                            player.seekTo(b.getProgress());
                        }
                    }
                });
        bottomBar.addView(seekBar, new LinearLayout.LayoutParams(0, activity.dp(26), 1f));

        clockLabel = activity.text("--:-- / --:--", 10.5f, 0xffe5e7eb);
        clockLabel.setPadding(activity.dp(4), 0, 0, 0);
        bottomBar.addView(clockLabel);

        videoArea.addView(bottomBar, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));

        // Tap video center to toggle play/pause
        videoArea.setOnClickListener(v -> togglePlayPause());

        surfaceView.listen(
                new VideoOutput.Listener() {
                    @Override
                    public void available(Surface value) {
                        renderSurface = value;
                        if (player != null) {
                            player.setSurface(value);
                        } else if (resolvedEpisode != null) {
                            startResolvedStream();
                        }
                    }

                    @Override
                    public void resized(int width, int height) {
                        if (player != null) player.setSurfaceSize(width, height);
                    }

                    @Override
                    public void destroyed() {
                        renderSurface = null;
                        if (player != null) {
                            player.setSurface(null);
                            if (!allowBackgroundAudio()) {
                                pausedForBackground = true;
                                pause();
                            }
                        }
                    }
                });
    }

    /** Pure policy check used across background/lock-screen/surface-destroy transitions. */
    static boolean shouldContinuePlaybackInBackground(
            boolean foreground, boolean inPip, boolean backgroundPlayPref) {
        return foreground || inPip || backgroundPlayPref;
    }

    private boolean allowBackgroundAudio() {
        boolean inPip = android.os.Build.VERSION.SDK_INT >= 24 && a.isInPictureInPictureMode();
        boolean bgPref = a.mobilePrefs().getBoolean(Prefs.BACKGROUND_PLAY, false);
        return shouldContinuePlaybackInBackground(a.foreground, inPip, bgPref);
    }

    private boolean hasNextEpisode() {
        if (activeLine == null || rawEpisode == null || activeLine.episodes == null) return false;
        int idx = activeLine.episodes.indexOf(rawEpisode);
        return idx >= 0 && idx + 1 < activeLine.episodes.size();
    }

    void onActivityStop(boolean keepBgPlay) {
        flushHistoryProgress();
        if (!keepBgPlay) {
            pausedForBackground = true;
            if (player != null) {
                // Always revoke playback intent even while buffering (when isPlaying() is false)
                // so completing the buffer in the background can never start audio output.
                try {
                    player.pause();
                } catch (Exception ignored) {
                }
                if (playPauseBtn != null) {
                    playPauseBtn.setText("▶");
                }
            }
            if (a != null && a.ui != null) {
                a.ui.removeCallbacks(ticker);
            }
        }
    }

    void onActivityStart() {
        pausedForBackground = false;
        if (!closed && player != null && prepared && player.isPlaying()) {
            a.ui.removeCallbacks(ticker);
            a.ui.post(ticker);
        }
    }

    void startEpisode(
            Cms.Site s,
            Cms.Video v,
            Cms.Line line,
            Cms.Episode ep,
            int tmdbId,
            boolean isTv,
            int seasonNum,
            int epNum) {
        // Persist the outgoing episode's latest position before tearing down its player.
        flushHistoryProgress();
        // Ensure strict single active playback session before mounting inline player.
        if (a.player != null) {
            a.inlinePlayer = null;
            a.releasePlayer();
        }
        releaseInternalPlayer();
        this.lastKnownPosMs = 0;
        this.lastKnownDurMs = 0;
        this.site = s;
        this.video = v;
        this.activeLine = line;
        this.rawEpisode = ep;
        this.resolvedEpisode = null;
        this.tmdbId = tmdbId;
        this.isTv = isTv;
        this.seasonNum = Math.max(1, seasonNum);
        this.epNum = Math.max(1, epNum);
        this.pausedForBackground = false;
        final long epTok = ++episodeToken;
        int manualIntro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_INTRO, 0));
        int manualOutro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_OUTRO, 0));
        skipEvaluator.resetForEpisode(epTok, manualIntro, manualOutro);

        a.activeLine = line;
        a.activeEpisode = ep;
        a.inlinePlayer = this;
        a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        EpisodeNameCleaner.CleanedEpisode cleaned =
                EpisodeNameCleaner.clean(ep.name, v.title, this.epNum);
        titleLabel.setText(v.title + " · " + cleaned.shortLabel);
        statusLabel.setText("正在解析 " + cleaned.shortLabel + " …");
        statusLabel.setVisibility(View.VISIBLE);

        boolean offlineOrLive = s == null || "live".equals(s.key) || "download".equals(s.key);
        if (!offlineOrLive
                && tmdbId > 0
                && (manualIntro <= 0 || manualOutro <= 0)
                && a.mobilePrefs().getBoolean(Prefs.THEINTRODB_AUTO_SKIP, true)) {
            TmdbService.lookupIntroDbAsync(
                    a,
                    tmdbId,
                    isTv,
                    this.seasonNum,
                    this.epNum,
                    ts -> {
                        if (!closed && ts != null) {
                            skipEvaluator.applyCommunityTimestamps(epTok, ts);
                        }
                    });
        }

        a.resolvePlayer(s, v, line, ep);
    }

    boolean acceptsResolved(Cms.Site s, Cms.Video v) {
        return !closed
                && hostSlot.isAttachedToWindow()
                && site != null
                && video != null
                && Objects.equals(site.key, s.key)
                && Objects.equals(video.id, v.id);
    }

    void playResolved(Cms.Site s, Cms.Video v, Cms.Episode resolved) {
        this.resolvedEpisode = resolved;
        if (renderSurface != null && renderSurface.isValid()) {
            startResolvedStream();
        }
    }

    void showResolveFailure(String message) {
        if (closed || statusLabel == null) return;
        String text = message == null || message.trim().isEmpty() ? "解析失败，请切换线路或片源" : message;
        if (!text.startsWith("解析失败")) text = "解析失败：" + text;
        statusLabel.setVisibility(View.VISIBLE);
        statusLabel.setText(text);
    }

    private void startResolvedStream() {
        releaseInternalPlayer();
        final Cms.Episode ep = resolvedEpisode;
        if (ep == null || closed) return;
        if (ep.media == null) {
            ep.media = new JSONObject();
        }
        final int serial = ++loadSerial;
        final int ticket = a.generation;
        final int engPref = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
        final PlaybackController.EnginePlan planned =
                PlaybackController.planEngine(engPref, ep.media, MpvPlayer.isAvailable());
        statusLabel.setText("正在缓冲画面（" + planned.engineLabel + "）…");
        statusLabel.setVisibility(View.VISIBLE);

        a.worker.execute(
                () -> {
                    try {
                        final Map<String, String> headers =
                                Cms.inheritedHeaders(site.api, ep.url, site.headers);
                        Cms.mergeHeaders(headers, ep.headers);
                        final String effective =
                                PlaybackController.preparePlayUrl(a, site, ep, headers);
                        PlaybackController.annotateLocalHlsMpvCompatibility(effective, ep.media);
                        final PlaybackController.EnginePlan effectivePlan =
                                PlaybackController.planEngine(
                                        engPref, ep.media, MpvPlayer.isAvailable());
                        PlaybackController.commitPreparedLaunchOnMain(
                                a.ui::post,
                                () ->
                                        !closed
                                                && !a.isFinishing()
                                                && !a.isDestroyed()
                                                && a.inlinePlayer == MobileInlinePlayer.this
                                                && a.player == null
                                                && ticket == a.generation
                                                && serial == loadSerial
                                                && renderSurface != null
                                                && renderSurface.isValid(),
                                () -> {
                                    MoviePlayer[] out = new MoviePlayer[1];
                                    final PlaybackController.EnginePlan actualPlan =
                                            PlaybackController.createPlayerWithPlan(
                                                    a, ep, effectivePlan, out);
                                    final MoviePlayer mp = out[0];
                                    try {
                                        if (engPref == PlaybackController.ENGINE_MPV
                                                && actualPlan.engine
                                                        == PlaybackController.ENGINE_MEDIA3) {
                                            ep.media.put(
                                                    PlaybackController
                                                            .MEDIA_KEY_SINGLE_PLAY_FALLBACK_FROM_MPV,
                                                    true);
                                        } else {
                                            ep.media.remove(
                                                    PlaybackController
                                                            .MEDIA_KEY_SINGLE_PLAY_FALLBACK_FROM_MPV);
                                        }
                                    } catch (Exception ignored) {
                                    }
                                    try {
                                        mp.configureDefaultAudio();
                                        mp.setDataSource(a, Uri.parse(effective), headers);
                                        mp.setOptions(ep.media);
                                    } catch (Throwable setupErr) {
                                        try {
                                            mp.release();
                                        } catch (Exception ignored) {
                                        }
                                        throw setupErr;
                                    }
                                    player = mp;
                                    activeEnginePlan = actualPlan;
                                    if (!actualPlan.fallbackReason.isEmpty()) {
                                        AppLog.i(
                                                "MobileInlinePlayer",
                                                "Engine fallback ("
                                                        + actualPlan.engineLabel
                                                        + "): "
                                                        + actualPlan.fallbackReason);
                                        a.toast(actualPlan.fallbackReason);
                                        statusLabel.setVisibility(View.VISIBLE);
                                        statusLabel.setText(
                                                "已切换至 " + actualPlan.engineLabel + " 内核，正在加载…");
                                    }
                                    mp.setSurface(renderSurface);
                                    mp.setOnPreparedListener(
                                            p -> {
                                                if (closed
                                                        || a.isFinishing()
                                                        || serial != loadSerial
                                                        || player != mp) {
                                                    return;
                                                }
                                                prepared = true;
                                                statusLabel.setVisibility(View.GONE);
                                                float spd = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
                                                if (Math.abs(spd - 1f) > 0.02f) p.setSpeed(spd);
                                                if (a.resumeAt > 0) {
                                                    p.seekTo(a.resumeAt);
                                                    a.resumeAt = 0;
                                                }
                                                if (allowBackgroundAudio()
                                                        && !pausedForBackground) {
                                                    p.start();
                                                    playPauseBtn.setText("❚❚");
                                                    a.ui.removeCallbacks(ticker);
                                                    a.ui.post(ticker);
                                                } else {
                                                    p.pause();
                                                    playPauseBtn.setText("▶");
                                                }
                                            });
                                    mp.setOnCompletionListener(
                                            p -> {
                                                if (closed
                                                        || serial != loadSerial
                                                        || player != mp) {
                                                    return;
                                                }
                                                stepNextEpisode();
                                            });
                                    mp.setOnErrorListener(
                                            (p, what, extra) -> {
                                                if (closed
                                                        || serial != loadSerial
                                                        || player != mp) {
                                                    return true;
                                                }
                                                boolean autoSwitch =
                                                        a.mobilePrefs()
                                                                .getBoolean(
                                                                        Prefs.AUTO_SWITCH_KERNEL,
                                                                        true);
                                                String reason =
                                                        PlaybackController.advanceFallbackPlan(
                                                                ep.media,
                                                                actualPlan.engine,
                                                                actualPlan.softwareFallback,
                                                                autoSwitch);
                                                if (reason != null) {
                                                    int resumePos = captureResumePosition();
                                                    if (resumePos > 0) {
                                                        a.resumeAt = resumePos;
                                                    }
                                                    a.toast(reason);
                                                    startResolvedStream();
                                                    return true;
                                                }
                                                flushHistoryProgress();
                                                statusLabel.setVisibility(View.VISIBLE);
                                                statusLabel.setText(
                                                        autoSwitch
                                                                ? ("播放失败（"
                                                                        + actualPlan.engineLabel
                                                                        + "），点击右上角「横屏全屏」切核重试")
                                                                : ("播放失败（"
                                                                        + actualPlan.engineLabel
                                                                        + "，已关闭自动切核），请手动切换内核或线路"));
                                                return true;
                                            });
                                    mp.prepareAsync();
                                    return mp;
                                },
                                e -> {
                                    statusLabel.setVisibility(View.VISIBLE);
                                    statusLabel.setText("播放失败：" + a.message(e));
                                });
                    } catch (Throwable e) {
                        a.ui.post(
                                () -> {
                                    if (closed || serial != loadSerial) return;
                                    statusLabel.setVisibility(View.VISIBLE);
                                    statusLabel.setText("播放失败：" + a.message(e));
                                });
                    }
                });
    }

    private boolean stepNextEpisode() {
        if (!a.prefs.getBoolean(Prefs.AUTO_NEXT, true)
                || activeLine == null
                || rawEpisode == null) {
            return false;
        }
        int idx = activeLine.episodes.indexOf(rawEpisode);
        if (idx >= 0 && idx + 1 < activeLine.episodes.size()) {
            flushHistoryProgress();
            Cms.Episode next = activeLine.episodes.get(idx + 1);
            a.resumeAt = 0;
            startEpisode(site, video, activeLine, next, tmdbId, isTv, seasonNum, epNum + 1);
            return true;
        }
        return false;
    }

    private void togglePlayPause() {
        if (player == null || !prepared) return;
        if (player.isPlaying()) {
            player.pause();
            playPauseBtn.setText("▶");
            flushHistoryProgress();
        } else {
            pausedForBackground = false;
            player.start();
            playPauseBtn.setText("❚❚");
            a.ui.removeCallbacks(ticker);
            a.ui.post(ticker);
        }
    }

    void pause() {
        if (player != null) {
            try {
                player.pause();
            } catch (Exception ignored) {
            }
            if (playPauseBtn != null) {
                playPauseBtn.setText("▶");
            }
            flushHistoryProgress();
        }
    }

    int captureResumePosition() {
        int pos = 0;
        if (player != null && prepared) {
            try {
                pos = Math.max(0, player.getCurrentPosition());
            } catch (Exception ignored) {
            }
        }
        return PlaybackController.resolveFallbackResumePosition(
                pos, lastKnownPosMs, a != null ? a.resumeAt : 0);
    }

    void flushHistoryProgress() {
        if (player == null && lastKnownPosMs <= 0) return;
        try {
            int pos = 0;
            int dur = 0;
            if (player != null && prepared) {
                pos = Math.max(0, player.getCurrentPosition());
                dur = Math.max(0, player.getDuration());
            }
            if (pos <= 0) pos = lastKnownPosMs;
            if (dur <= 0) dur = lastKnownDurMs;
            if (dur > 0) {
                saveHistoryProgress(pos, dur, true);
            }
        } catch (Exception ignored) {
        }
    }

    private void expandToFullscreen() {
        Cms.Site s = site;
        Cms.Video v = video;
        Cms.Line l = activeLine;
        Cms.Episode raw = rawEpisode;
        Cms.Episode res = resolvedEpisode;
        int pos = (player != null && prepared) ? Math.max(0, player.getCurrentPosition()) : 0;
        if (res != null) {
            if (res.media == null) res.media = new JSONObject();
            try {
                if (tmdbId > 0) {
                    res.media.put("_tmdbId", tmdbId);
                    res.media.put("_isTv", isTv);
                    res.media.put("_seasonNum", seasonNum);
                    res.media.put("_epNum", epNum);
                }
            } catch (Exception ignored) {
            }
        }
        flushHistoryProgress();
        detach();
        if (onClosed != null) onClosed.run();
        a.activeLine = l;
        a.activeEpisode = raw;
        a.resumeAt = pos;
        if (res != null) {
            PlaybackController.openPlayer(a, s, v, res);
        } else if (s != null && v != null && l != null && raw != null) {
            a.resolvePlayer(s, v, l, raw);
        }
    }

    private void saveHistoryProgress(int pos, int dur, boolean force) {
        if (a.privateMode || a.switchingPrivacy) {
            return;
        }
        if (site == null
                || "live".equals(site.key)
                || "download".equals(site.key)
                || video == null
                || activeLine == null
                || rawEpisode == null
                || dur <= 0) {
            return;
        }
        long now = System.currentTimeMillis();
        String epKey = site.key + "\n" + video.id + "\n" + activeLine.name + "\n" + rawEpisode.name;
        if (!checkpointPolicy.shouldWrite(now, pos, dur, epKey, force)) {
            return;
        }
        WatchHistory.Entry entry = new WatchHistory.Entry();
        entry.site = site.key;
        entry.id = video.id;
        entry.title = video.title;
        entry.poster = video.poster;
        entry.line = activeLine.name;
        entry.episode = rawEpisode.name;
        entry.index = activeLine.episodes.indexOf(rawEpisode);
        entry.position = pos;
        entry.duration = dur;
        entry.updated = now;
        WatchHistory.enqueueUpsert(a.historyPersistence(), entry);
        CloudSyncDialog.scheduleAutoPush(a, force);
    }

    private void releaseInternalPlayer() {
        loadSerial++;
        a.ui.removeCallbacks(ticker);
        prepared = false;
        activeEnginePlan = null;
        checkpointPolicy.reset();
        if (player != null) {
            try {
                player.release();
            } catch (Exception ignored) {
            }
            player = null;
        }
    }

    void detach() {
        flushHistoryProgress();
        closed = true;
        episodeToken++;
        releaseInternalPlayer();
        if (a.inlinePlayer == this) {
            a.inlinePlayer = null;
        }
        if (a.player == null) {
            a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
        if (container.getParent() instanceof ViewGroup) {
            ((ViewGroup) container.getParent()).removeView(container);
        }
        hostSlot.setVisibility(View.GONE);
    }
}

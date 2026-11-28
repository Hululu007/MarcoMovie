package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.ClipDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.LayerDrawable;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
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
 * lock-screen / Home return, and seamlessly hands off to landscape fullscreen with matching vector
 * cinema chrome.
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
    private final LinearLayout loadingCard;
    private final BrandLogoLoaderView loadingSpinner;
    private final TextView statusLabel;
    private final LinearLayout retryBtn;
    private final FrameLayout centerPlayBtn;
    private final FrameLayout playPauseBtn;
    private final MobileIcons.IconView playPauseIcon;
    private final FrameLayout nextEpBtn;
    private final MobileIcons.IconView volumeIcon;
    private final TextView elapsedLabel;
    private final TextView totalLabel;
    private final SeekBar seekBar;

    private boolean centerPlayShown;
    private boolean loadingCardShown = true;
    private boolean nextEpShown;

    private Cms.Site site;
    private Cms.Video video;
    private Cms.Line activeLine;
    private Cms.Episode rawEpisode;
    private Cms.Episode resolvedEpisode;
    private WatchHistory.Entry matchedSavedBookmark;
    private int tmdbId;
    private boolean isTv = true;
    private int seasonNum = 1;
    private int epNum = 1;
    private MoviePlayer player;
    private PlaybackController.EnginePlan activeEnginePlan;
    private Surface renderSurface;
    private int surfaceWidth;
    private int surfaceHeight;
    private boolean prepared;
    private boolean userSeeking;
    private boolean closed;
    private boolean pausedForBackground;
    private boolean inlineMuted;
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
                            updateInlineTimeLabels(pos, dur);
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

        final MobileTheme.Palette palette = MobileTheme.of(activity);
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

        // Soft top & bottom gradient scrims aligned with fullscreen PlayerChrome
        View topScrim = new View(activity);
        topScrim.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xB8000000, 0x3C000000, 0x00000000}));
        videoArea.addView(topScrim, new FrameLayout.LayoutParams(-1, activity.dp(64), Gravity.TOP));

        View bottomScrim = new View(activity);
        bottomScrim.setBackground(
                new GradientDrawable(
                        GradientDrawable.Orientation.BOTTOM_TOP,
                        new int[] {0xCC000000, 0x4A000000, 0x00000000}));
        videoArea.addView(
                bottomScrim, new FrameLayout.LayoutParams(-1, activity.dp(68), Gravity.BOTTOM));

        // Top bar: [IC_CHEVRON_DOWN] Title [IC_CAST] [IC_VOLUME] [IC_CLOSE]
        LinearLayout topBar = activity.row();
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(activity.dp(10), activity.dp(8), activity.dp(10), activity.dp(6));

        FrameLayout collapseBtn =
                buildInlineIconButton(
                        activity,
                        MobileIcons.IC_CHEVRON_DOWN,
                        17f,
                        "收起小窗",
                        0x33000000,
                        () -> {
                            detach();
                            if (this.onClosed != null) this.onClosed.run();
                        });
        topBar.addView(
                collapseBtn, new LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)));

        titleLabel = activity.text("", 13f, Color.WHITE);
        titleLabel.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        titleLabel.setSingleLine(true);
        titleLabel.setEllipsize(TextUtils.TruncateAt.END);
        titleLabel.setShadowLayer(activity.dp(3), 0, activity.dp(1), 0xAA000000);
        titleLabel.setPadding(activity.dp(8), 0, activity.dp(8), 0);
        topBar.addView(titleLabel, new LinearLayout.LayoutParams(0, -2, 1f));

        FrameLayout extBtn =
                buildInlineIconButton(
                        activity,
                        MobileIcons.IC_EXTERNAL,
                        15f,
                        "外部播放",
                        0x33000000,
                        () -> {
                            Cms.Episode target =
                                    resolvedEpisode != null ? resolvedEpisode : rawEpisode;
                            PlaybackController.launchExternalPlayer(a, video, target);
                        });
        LinearLayout.LayoutParams extLp =
                new LinearLayout.LayoutParams(activity.dp(32), activity.dp(32));
        extLp.rightMargin = activity.dp(6);
        topBar.addView(extBtn, extLp);

        FrameLayout castBtn =
                buildInlineIconButton(
                        activity,
                        MobileIcons.IC_CAST,
                        16f,
                        "投屏",
                        0x33000000,
                        this::castActiveEpisode);
        castBtn.setTag("inline-cast");
        LinearLayout.LayoutParams castLp =
                new LinearLayout.LayoutParams(activity.dp(32), activity.dp(32));
        castLp.rightMargin = activity.dp(6);
        if (activity.privateMode || activity.isCast()) {
            castBtn.setVisibility(View.GONE);
        }
        topBar.addView(castBtn, castLp);

        FrameLayout volBtn = new FrameLayout(activity);
        volBtn.setContentDescription("切换静音");
        volBtn.setBackground(activity.bg(0x33000000, 999));
        volumeIcon = MobileIcons.create(activity, MobileIcons.IC_VOLUME, 16f, Color.WHITE);
        volumeIcon.setStrokeWidthUnits(2.0f);
        volBtn.addView(
                volumeIcon,
                new FrameLayout.LayoutParams(activity.dp(16), activity.dp(16), Gravity.CENTER));
        MobileMotion.bindPress(volBtn, 0.92f);
        volBtn.setOnClickListener(v -> toggleInlineMute());
        LinearLayout.LayoutParams volLp =
                new LinearLayout.LayoutParams(activity.dp(32), activity.dp(32));
        volLp.rightMargin = activity.dp(6);
        topBar.addView(volBtn, volLp);

        FrameLayout closeBtn =
                buildInlineIconButton(
                        activity,
                        MobileIcons.IC_CLOSE,
                        15f,
                        "关闭小窗",
                        0x33000000,
                        () -> {
                            detach();
                            if (this.onClosed != null) this.onClosed.run();
                        });
        topBar.addView(closeBtn, new LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)));

        videoArea.addView(topBar, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        // Center frosted loading/retry card with vector BrandLogoLoaderView
        loadingCard = activity.vertical();
        loadingCard.setGravity(Gravity.CENTER_HORIZONTAL);
        loadingCard.setPadding(activity.dp(14), activity.dp(9), activity.dp(16), activity.dp(9));
        GradientDrawable loadBg =
                activity.bg(activity.isReducedTransparency() ? 0xEE141720 : 0xCC141720, 18);
        loadBg.setStroke(MobileTheme.hairlinePx(activity), 0x2EFFFFFF);
        loadingCard.setBackground(loadBg);

        LinearLayout statusRow = activity.row();
        statusRow.setGravity(Gravity.CENTER_VERTICAL);
        loadingSpinner = new BrandLogoLoaderView(activity);
        loadingSpinner.setReducedMotion(MobileMotion.isReduced(activity));
        loadingSpinner.setActive(true);
        LinearLayout.LayoutParams spinLp =
                new LinearLayout.LayoutParams(activity.dp(20), activity.dp(20));
        spinLp.rightMargin = activity.dp(8);
        statusRow.addView(loadingSpinner, spinLp);

        statusLabel = activity.text("正在解析播放地址…", 12f, 0xFFF3F5F9);
        statusLabel.setSingleLine(false);
        statusLabel.setMaxLines(2);
        statusLabel.setEllipsize(TextUtils.TruncateAt.END);
        statusLabel.setMaxWidth(activity.dp(240));
        statusRow.addView(statusLabel, new LinearLayout.LayoutParams(-2, -2));
        loadingCard.addView(statusRow, new LinearLayout.LayoutParams(-2, -2));

        retryBtn = activity.row();
        retryBtn.setTag("inline-retry-pill");
        retryBtn.setGravity(Gravity.CENTER_VERTICAL);
        retryBtn.setPadding(activity.dp(12), activity.dp(5), activity.dp(12), activity.dp(5));
        retryBtn.setBackground(activity.bg(palette.accent, 999));
        MobileIcons.IconView retryIc =
                MobileIcons.create(activity, MobileIcons.IC_REFRESH, 13f, palette.accentOnFill);
        retryIc.setStrokeWidthUnits(2.1f);
        LinearLayout.LayoutParams ricLp =
                new LinearLayout.LayoutParams(activity.dp(13), activity.dp(13));
        ricLp.rightMargin = activity.dp(5);
        retryBtn.addView(retryIc, ricLp);
        TextView retryLbl = activity.text("点击重试", 11.5f, palette.accentOnFill);
        retryLbl.setTypeface(null, Typeface.BOLD);
        retryLbl.setIncludeFontPadding(false);
        retryBtn.addView(retryLbl, new LinearLayout.LayoutParams(-2, -2));
        MobileMotion.bindPress(retryBtn, 0.92f);
        retryBtn.setOnClickListener(v -> retryInlineLoad());
        retryBtn.setVisibility(View.GONE);
        LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(-2, -2);
        rLp.topMargin = activity.dp(8);
        loadingCard.addView(retryBtn, rLp);

        videoArea.addView(loadingCard, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        // Center frosted Play button (shown when prepared & paused)
        centerPlayBtn = new FrameLayout(activity);
        centerPlayBtn.setContentDescription("继续播放");
        GradientDrawable cpBg =
                activity.bg(activity.isReducedTransparency() ? 0xDC141720 : 0x94141720, 999);
        cpBg.setStroke(MobileTheme.hairlinePx(activity), 0x36FFFFFF);
        centerPlayBtn.setBackground(cpBg);
        MobileIcons.IconView centerPlayIcon =
                MobileIcons.create(activity, MobileIcons.IC_PLAY, 22f, Color.WHITE);
        centerPlayIcon.setStrokeWidthUnits(2.1f);
        FrameLayout.LayoutParams cpiLp =
                new FrameLayout.LayoutParams(activity.dp(22), activity.dp(22), Gravity.CENTER);
        cpiLp.leftMargin = activity.dp(1.5f);
        centerPlayBtn.addView(centerPlayIcon, cpiLp);
        MobileMotion.bindPress(centerPlayBtn, 0.92f);
        centerPlayBtn.setOnClickListener(v -> togglePlayPause());
        centerPlayBtn.setVisibility(View.GONE);
        videoArea.addView(
                centerPlayBtn,
                new FrameLayout.LayoutParams(activity.dp(48), activity.dp(48), Gravity.CENTER));

        // Bottom unified vector transport bar: [Play/Pause] [NextEp] [elapsed] [SeekBar] [total]
        // [Fullscreen]
        LinearLayout bottomBar = activity.row();
        bottomBar.setGravity(Gravity.CENTER_VERTICAL);
        bottomBar.setPadding(activity.dp(8), activity.dp(4), activity.dp(8), activity.dp(6));

        playPauseBtn = new FrameLayout(activity);
        playPauseBtn.setContentDescription("播放或暂停");
        playPauseIcon = MobileIcons.create(activity, MobileIcons.IC_PAUSE, 17f, Color.WHITE);
        playPauseIcon.setStrokeWidthUnits(2.1f);
        playPauseBtn.addView(
                playPauseIcon,
                new FrameLayout.LayoutParams(activity.dp(17), activity.dp(17), Gravity.CENTER));
        MobileMotion.bindPress(playPauseBtn, 0.92f);
        playPauseBtn.setOnClickListener(v -> togglePlayPause());
        bottomBar.addView(
                playPauseBtn, new LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)));

        nextEpBtn =
                buildInlineIconButton(
                        activity,
                        MobileIcons.IC_NEXT_EP,
                        16f,
                        "下一集",
                        0x00000000,
                        this::stepNextEpisode);
        nextEpBtn.setVisibility(View.GONE);
        bottomBar.addView(
                nextEpBtn, new LinearLayout.LayoutParams(activity.dp(30), activity.dp(30)));

        elapsedLabel = activity.text("00:00", 10.5f, 0xFFF3F5F9);
        elapsedLabel.setFontFeatureSettings("tnum");
        elapsedLabel.setIncludeFontPadding(false);
        elapsedLabel.setSingleLine(true);
        elapsedLabel.setPadding(activity.dp(4), 0, activity.dp(6), 0);
        bottomBar.addView(elapsedLabel, new LinearLayout.LayoutParams(-2, -2));

        seekBar = new SeekBar(activity);
        if (Build.VERSION.SDK_INT >= 29) {
            seekBar.setMinHeight(0);
        }
        seekBar.setMinimumHeight(0);
        styleInlineSeekBar(activity, seekBar, palette.accent);
        seekBar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    @Override
                    public void onProgressChanged(SeekBar b, int progress, boolean fromUser) {
                        if (fromUser && player != null && prepared) {
                            updateInlineTimeLabels(progress, player.getDuration());
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

        totalLabel = activity.text("--:--", 10.5f, 0xB8F3F5F9);
        totalLabel.setFontFeatureSettings("tnum");
        totalLabel.setIncludeFontPadding(false);
        totalLabel.setSingleLine(true);
        totalLabel.setPadding(activity.dp(6), 0, activity.dp(4), 0);
        bottomBar.addView(totalLabel, new LinearLayout.LayoutParams(-2, -2));

        FrameLayout expandBtn =
                buildInlineIconButton(
                        activity,
                        MobileIcons.IC_FULLSCREEN,
                        17f,
                        "横屏全屏",
                        0x00000000,
                        this::expandToFullscreen);
        bottomBar.addView(
                expandBtn, new LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)));

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
                        surfaceWidth = width;
                        surfaceHeight = height;
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

    private static FrameLayout buildInlineIconButton(
            MainActivity activity,
            int icon,
            float sizeDp,
            String desc,
            int circleBg,
            Runnable onClick) {
        FrameLayout btn = new FrameLayout(activity);
        btn.setContentDescription(desc);
        if (circleBg != 0) {
            btn.setBackground(activity.bg(circleBg, 999));
        }
        MobileIcons.IconView iv = MobileIcons.create(activity, icon, sizeDp, Color.WHITE);
        iv.setStrokeWidthUnits(2.0f);
        int px = activity.dp(sizeDp);
        btn.addView(iv, new FrameLayout.LayoutParams(px, px, Gravity.CENTER));
        MobileMotion.bindPress(btn, 0.92f);
        btn.setOnClickListener(
                v -> {
                    if (onClick != null) onClick.run();
                });
        return btn;
    }

    private static void styleInlineSeekBar(MainActivity activity, SeekBar bar, int accent) {
        final int barH = Math.max(2, activity.dp(2.6f));
        GradientDrawable trackBg = new GradientDrawable();
        trackBg.setColor(0x3DFFFFFF);
        trackBg.setCornerRadius(barH * 0.5f);
        GradientDrawable secBg = new GradientDrawable();
        secBg.setColor(0x64FFFFFF);
        secBg.setCornerRadius(barH * 0.5f);
        GradientDrawable progBg = new GradientDrawable();
        progBg.setColor(accent);
        progBg.setCornerRadius(barH * 0.5f);
        Drawable[] layers =
                new Drawable[] {
                    trackBg,
                    new ClipDrawable(secBg, Gravity.LEFT, ClipDrawable.HORIZONTAL),
                    new ClipDrawable(progBg, Gravity.LEFT, ClipDrawable.HORIZONTAL)
                };
        LayerDrawable ld =
                new LayerDrawable(layers) {
                    @Override
                    protected void onBoundsChange(Rect bounds) {
                        int cy = bounds.centerY();
                        int top = cy - barH / 2;
                        int bottom = top + barH;
                        for (int i = 0; i < getNumberOfLayers(); i++) {
                            getDrawable(i).setBounds(bounds.left, top, bounds.right, bottom);
                        }
                    }
                };
        ld.setId(0, android.R.id.background);
        ld.setId(1, android.R.id.secondaryProgress);
        ld.setId(2, android.R.id.progress);
        bar.setProgressDrawable(ld);

        int thumbSize = activity.dp(11);
        GradientDrawable thumb = new GradientDrawable();
        thumb.setShape(GradientDrawable.OVAL);
        thumb.setSize(thumbSize, thumbSize);
        thumb.setColor(Color.WHITE);
        thumb.setStroke(activity.dp(1.5f), MobileTheme.withAlpha(accent, 0x66));
        bar.setThumb(thumb);
        bar.setThumbOffset(0);
        if (Build.VERSION.SDK_INT >= 21) {
            bar.setSplitTrack(false);
        }
        int padH = activity.dp(5);
        bar.setPadding(padH, 0, padH, 0);
    }

    private void updateInlineTimeLabels(int posMs, int durMs) {
        if (elapsedLabel != null) {
            elapsedLabel.setText(PlaybackController.formatTime(Math.max(0, posMs)));
        }
        if (totalLabel != null) {
            totalLabel.setText(durMs > 0 ? PlaybackController.formatTime(durMs) : "--:--");
        }
    }

    private static void snapInlineVisibility(View view, boolean show) {
        view.animate().withEndAction(null).cancel();
        view.setAlpha(1f);
        view.setTranslationY(0f);
        view.setScaleX(1f);
        view.setScaleY(1f);
        view.setVisibility(show ? View.VISIBLE : View.GONE);
    }

    private void setCenterPlayVisible(boolean show) {
        if (centerPlayBtn == null) return;
        if (centerPlayShown == show
                && centerPlayBtn.getVisibility() == (show ? View.VISIBLE : View.GONE)) {
            return;
        }
        centerPlayShown = show;
        if (UiCompat.isAttached(centerPlayBtn)) {
            MobileMotion.crossfadeVisibility(
                    centerPlayBtn, show, 0f, 0.92f, MotionTokens.DURATION_FAST_MS, true);
        } else {
            snapInlineVisibility(centerPlayBtn, show);
        }
    }

    private void setLoadingCardVisible(boolean show) {
        if (loadingCard == null) return;
        if (loadingCardShown == show
                && loadingCard.getVisibility() == (show ? View.VISIBLE : View.GONE)) {
            return;
        }
        loadingCardShown = show;
        if (UiCompat.isAttached(loadingCard)) {
            MobileMotion.crossfadeVisibility(
                    loadingCard, show, 0f, 0.96f, MotionTokens.DURATION_FAST_MS, true);
        } else {
            snapInlineVisibility(loadingCard, show);
        }
    }

    private void setNextEpVisible(boolean show) {
        if (nextEpBtn == null) return;
        if (nextEpShown == show && nextEpBtn.getVisibility() == (show ? View.VISIBLE : View.GONE)) {
            return;
        }
        nextEpShown = show;
        if (UiCompat.isAttached(nextEpBtn)) {
            MobileMotion.crossfadeVisibility(
                    nextEpBtn, show, 0f, 0.92f, MotionTokens.DURATION_FAST_MS, true);
        } else {
            snapInlineVisibility(nextEpBtn, show);
        }
    }

    private void retryInlineLoad() {
        if (closed) return;
        if (resolvedEpisode != null) {
            startResolvedStream();
        } else if (site != null && video != null && activeLine != null && rawEpisode != null) {
            showInlineStatus("正在重新解析播放地址…", true);
            a.resolvePlayer(site, video, activeLine, rawEpisode);
        }
    }

    private void syncPlayPauseVisual(boolean playing) {
        if (playPauseIcon != null) {
            playPauseIcon.setIcon(playing ? MobileIcons.IC_PAUSE : MobileIcons.IC_PLAY);
        }
        boolean showCenter = prepared && !playing && !loadingCardShown;
        setCenterPlayVisible(showCenter);
    }

    private void showInlineStatus(String message, boolean spinning) {
        if (statusLabel != null) {
            statusLabel.setText(message);
        }
        if (loadingSpinner != null) {
            loadingSpinner.setReducedMotion(MobileMotion.isReduced(a));
            loadingSpinner.setVisibility(spinning ? View.VISIBLE : View.GONE);
            loadingSpinner.setActive(spinning);
        }
        if (retryBtn != null) {
            retryBtn.setVisibility(spinning ? View.GONE : View.VISIBLE);
        }
        if (loadingCard != null) {
            loadingCard.setClickable(!spinning);
        }
        setLoadingCardVisible(true);
        setCenterPlayVisible(false);
    }

    private void hideInlineStatus() {
        if (loadingSpinner != null) {
            loadingSpinner.setActive(false);
        }
        if (retryBtn != null) {
            retryBtn.setVisibility(View.GONE);
        }
        if (loadingCard != null) {
            loadingCard.setClickable(false);
        }
        setLoadingCardVisible(false);
    }

    private void toggleInlineMute() {
        try {
            AudioManager am = (AudioManager) a.getSystemService(Context.AUDIO_SERVICE);
            if (am != null) {
                am.adjustStreamVolume(
                        AudioManager.STREAM_MUSIC, AudioManager.ADJUST_TOGGLE_MUTE, 0);
                inlineMuted = am.isStreamMute(AudioManager.STREAM_MUSIC);
                if (volumeIcon != null) {
                    volumeIcon.setTint(inlineMuted ? 0x70FFFFFF : Color.WHITE);
                }
                a.toast(inlineMuted ? "已静音" : "已恢复声音");
            }
        } catch (Throwable ignored) {
        }
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
                syncPlayPauseVisual(false);
            }
            if (a != null && a.ui != null) {
                a.ui.removeCallbacks(ticker);
            }
        }
    }

    void onActivityStart() {
        pausedForBackground = false;
        if (!closed && player != null && prepared && player.isPlaying()) {
            syncPlayPauseVisual(true);
            a.ui.removeCallbacks(ticker);
            a.ui.post(ticker);
        }
    }

    boolean isClosed() {
        return closed;
    }

    private void castActiveEpisode() {
        if (closed) return;
        if (a.privateMode) {
            a.toast("隐私空间已隔离局域网投屏");
            return;
        }
        String resUrl =
                resolvedEpisode != null && resolvedEpisode.url != null
                        ? resolvedEpisode.url.trim()
                        : "";
        String rawUrl = rawEpisode != null && rawEpisode.url != null ? rawEpisode.url.trim() : "";
        if (resUrl.isEmpty() && !Cms.isHttp(rawUrl) && !LanCastMediaRelay.isLocalFileUrl(rawUrl)) {
            a.toast("正在解析播放地址，请稍候再投屏");
            return;
        }
        Map<String, String> mediaHeaders =
                Cms.inheritedHeaders(
                        site != null ? site.api : "",
                        resUrl.isEmpty() ? rawUrl : resUrl,
                        site != null ? site.headers : null);
        if (resolvedEpisode != null) {
            Cms.mergeHeaders(mediaHeaders, resolvedEpisode.headers);
        }
        String declaredMime =
                resolvedEpisode != null && resolvedEpisode.media != null
                        ? MediaOptions.mime(resolvedEpisode.media)
                        : "";
        DlnaCastClient.CastTarget target =
                DlnaCastClient.prepareCastTarget(
                        resUrl,
                        rawUrl,
                        mediaHeaders,
                        declaredMime,
                        DlnaCastClient.findLocalLanIpv4(),
                        null);
        if (target.url.isEmpty()) {
            a.toast(target.errorMessage);
            return;
        }
        String displayTitle =
                video != null && video.title != null && !video.title.trim().isEmpty()
                        ? video.title.trim()
                        : "Marco Movie";
        if (rawEpisode != null && rawEpisode.name != null && !rawEpisode.name.trim().isEmpty()) {
            EpisodeNameCleaner.CleanedEpisode cleaned =
                    EpisodeNameCleaner.clean(rawEpisode.name, displayTitle, epNum);
            if (!displayTitle.contains(cleaned.shortLabel)) {
                displayTitle = displayTitle + " · " + cleaned.shortLabel;
            }
        }
        DlnaCastClient.showCastDevicePicker(a, target.url, displayTitle, this::pause);
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
        // Cancel any in-flight parse from a previously tapped episode so switches feel instant.
        a.clearPlaybackLoading();
        a.stopWeb();
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
        WatchHistory.Entry saved = PlaybackController.lookupSavedBookmark(a, s, v, line, ep);
        this.matchedSavedBookmark = saved != null ? WatchHistory.cloneEntry(saved) : null;
        if (a.resumeAt == 0 && saved != null) {
            a.resumeAt = saved.resume();
        }
        a.inlinePlayer = this;
        a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        EpisodeNameCleaner.CleanedEpisode cleaned =
                EpisodeNameCleaner.clean(ep.name, v.title, this.epNum);
        titleLabel.setText(v.title + " · " + cleaned.shortLabel);
        setNextEpVisible(hasNextEpisode());
        updateInlineTimeLabels(0, 0);
        showInlineStatus("正在解析 " + cleaned.shortLabel + " …", true);

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
        showInlineStatus(text, false);
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
        showInlineStatus("正在缓冲画面（" + planned.engineLabel + "）…", true);

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
                                        showInlineStatus(
                                                "已切换至 " + actualPlan.engineLabel + " 内核，正在加载…",
                                                true);
                                    }
                                    mp.setSurface(renderSurface);
                                    if (surfaceWidth > 0 && surfaceHeight > 0) {
                                        mp.setSurfaceSize(surfaceWidth, surfaceHeight);
                                    }
                                    mp.setOnPreparedListener(
                                            p -> {
                                                if (closed
                                                        || a.isFinishing()
                                                        || serial != loadSerial
                                                        || player != mp) {
                                                    return;
                                                }
                                                prepared = true;
                                                hideInlineStatus();
                                                float spd = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
                                                if (Math.abs(spd - 1f) > 0.02f) p.setSpeed(spd);
                                                if (a.resumeAt > 0) {
                                                    p.seekTo(a.resumeAt);
                                                    a.resumeAt = 0;
                                                }
                                                if (allowBackgroundAudio()
                                                        && !pausedForBackground) {
                                                    p.start();
                                                    syncPlayPauseVisual(true);
                                                    a.ui.removeCallbacks(ticker);
                                                    a.ui.post(ticker);
                                                } else {
                                                    p.pause();
                                                    syncPlayPauseVisual(false);
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
                                                AppLog.w(
                                                        "MobileInlinePlayer",
                                                        "Inline error what="
                                                                + what
                                                                + " extra="
                                                                + extra
                                                                + " engine="
                                                                + actualPlan.engineLabel
                                                                + " url="
                                                                + effective,
                                                        null);
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
                                                                autoSwitch,
                                                                MpvPlayer.isAvailable(),
                                                                PlaybackController
                                                                        .wasLoopbackCacheOrHlsUrl(
                                                                                effective));
                                                if (reason != null) {
                                                    int resumePos = captureResumePosition();
                                                    if (resumePos > 0) {
                                                        a.resumeAt = resumePos;
                                                    }
                                                    a.toast(reason);
                                                    startResolvedStream();
                                                    return true;
                                                }
                                                if (autoSwitch
                                                        && video != null
                                                        && video.lines != null
                                                        && video.lines.size() > 1
                                                        && activeLine != null
                                                        && rawEpisode != null) {
                                                    int curLineIdx =
                                                            video.lines.indexOf(activeLine);
                                                    int hopCount =
                                                            rawEpisode.media != null
                                                                    ? rawEpisode.media.optInt(
                                                                            "_lineHopCount", 0)
                                                                    : 0;
                                                    if (curLineIdx >= 0
                                                            && hopCount
                                                                    < Math.min(
                                                                            3,
                                                                            video.lines.size()
                                                                                    - 1)) {
                                                        Cms.Line nextLine =
                                                                video.lines.get(
                                                                        (curLineIdx + 1)
                                                                                % video.lines
                                                                                        .size());
                                                        Cms.Episode nextEp =
                                                                PlaybackController
                                                                        .findMatchingEpisode(
                                                                                nextLine,
                                                                                activeLine,
                                                                                rawEpisode);
                                                        if (nextEp != null
                                                                && nextLine != activeLine) {
                                                            if (nextEp.media == null) {
                                                                nextEp.media = new JSONObject();
                                                            }
                                                            try {
                                                                nextEp.media.put(
                                                                        "_lineHopCount",
                                                                        hopCount + 1);
                                                            } catch (Exception ignored) {
                                                            }
                                                            int resumePos = captureResumePosition();
                                                            if (resumePos > 0) {
                                                                a.resumeAt = resumePos;
                                                            }
                                                            a.toast(
                                                                    "当前线路异常，已自动切换至 "
                                                                            + nextLine.name);
                                                            startEpisode(
                                                                    site, video, nextLine, nextEp,
                                                                    tmdbId, isTv, seasonNum, epNum);
                                                            return true;
                                                        }
                                                    }
                                                }
                                                flushHistoryProgress();
                                                showInlineStatus(
                                                        autoSwitch
                                                                ? ("播放失败（"
                                                                        + actualPlan.engineLabel
                                                                        + "），可点右上角外部播放或右下角全屏重试")
                                                                : ("播放失败（"
                                                                        + actualPlan.engineLabel
                                                                        + "，已关闭自动切核），请手动切换内核或线路"),
                                                        false);
                                                return true;
                                            });
                                    mp.prepareAsync();
                                    return mp;
                                },
                                e -> showInlineStatus("播放失败：" + a.message(e), false));
                    } catch (Throwable e) {
                        a.ui.post(
                                () -> {
                                    if (closed || serial != loadSerial) return;
                                    showInlineStatus("播放失败：" + a.message(e), false);
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
            syncPlayPauseVisual(false);
            flushHistoryProgress();
        } else {
            pausedForBackground = false;
            player.start();
            syncPlayPauseVisual(true);
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
            syncPlayPauseVisual(false);
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
        String lineKey = activeLine.rawName();
        String lineId = activeLine.lineId();
        String epUrl = rawEpisode.url != null ? rawEpisode.url : "";
        String epKey =
                site.key
                        + "\n"
                        + video.id
                        + "\n"
                        + (lineId.isEmpty() ? lineKey : lineId)
                        + "\n"
                        + rawEpisode.name
                        + "\n"
                        + epUrl;
        if (!checkpointPolicy.shouldWrite(now, pos, dur, epKey, force)) {
            return;
        }
        WatchHistory.Entry entry =
                WatchHistory.buildPlaybackEntry(
                        site.key,
                        video.id,
                        video.title,
                        video.poster,
                        lineKey,
                        lineId,
                        NetdiskStore.detectLineDriveKey(activeLine),
                        rawEpisode.name,
                        epUrl,
                        activeLine.episodes.indexOf(rawEpisode),
                        pos,
                        dur,
                        now,
                        matchedSavedBookmark);
        WatchHistory.enqueueUpsert(a.historyPersistence(), entry);
        CloudSyncDialog.scheduleAutoPush(a, force);
    }

    private void releaseInternalPlayer() {
        loadSerial++;
        a.ui.removeCallbacks(ticker);
        prepared = false;
        activeEnginePlan = null;
        checkpointPolicy.reset();
        if (loadingSpinner != null) {
            loadingSpinner.setActive(false);
        }
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
        if (container != null && container.getParent() instanceof ViewGroup) {
            ((ViewGroup) container.getParent()).removeView(container);
        }
        if (hostSlot != null) {
            hostSlot.setVisibility(View.GONE);
        }
    }
}

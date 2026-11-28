package com.pilipala.marcomovie;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ActivityInfo;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.SystemClock;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * Automatic half-folded tabletop split HUD & video stage controller for foldable Android phones.
 *
 * <p>Detects half-folded posture via a 3-tier fallback chain (AndroidX WindowExtensions {@code
 * WindowLayoutComponent}, legacy {@code SidecarInterface}, and {@code Sensor.TYPE_HINGE_ANGLE}),
 * aligns screen orientation so the hinge runs horizontally when needed, confines video/subtitles/
 * danmaku to the upper display half with a tap-to-peek header, and renders a dark matte tabletop
 * control deck in the lower half.
 */
final class FoldableTabletopController {
    static final float HINGE_ENTER_MIN_DEG = 68f;
    static final float HINGE_ENTER_MAX_DEG = 142f;
    static final float HINGE_EXIT_LOW_DEG = 55f;
    static final float HINGE_EXIT_HIGH_DEG = 155f;
    static final long POSTURE_DEBOUNCE_MS = 180L;
    private static final int TYPE_HINGE_ANGLE_SENSOR = 36;
    private static final int WINDOW_STATE_HALF_OPENED = 2;

    static final class SplitBounds {
        final boolean active;
        final boolean needsOrientationFlipForHorizontalHinge;
        final int upperBottomPx;
        final int lowerTopPx;

        SplitBounds(
                boolean active,
                boolean needsOrientationFlipForHorizontalHinge,
                int upperBottomPx,
                int lowerTopPx) {
            this.active = active;
            this.needsOrientationFlipForHorizontalHinge = needsOrientationFlipForHorizontalHinge;
            this.upperBottomPx = upperBottomPx;
            this.lowerTopPx = lowerTopPx;
        }
    }

    static boolean shouldEnterByHingeAngle(boolean currentlyHalfFolded, float angleDeg) {
        if (Float.isNaN(angleDeg) || angleDeg < 0f || angleDeg > 180f) {
            return currentlyHalfFolded;
        }
        if (currentlyHalfFolded) {
            return angleDeg >= HINGE_EXIT_LOW_DEG && angleDeg <= HINGE_EXIT_HIGH_DEG;
        }
        return angleDeg >= HINGE_ENTER_MIN_DEG && angleDeg <= HINGE_ENTER_MAX_DEG;
    }

    static SplitBounds computeSplitBounds(
            int containerW,
            int containerH,
            Rect foldBoundsInWindow,
            boolean sensorHalfFolded,
            int fallbackCreaseHalfGapPx) {
        if (foldBoundsInWindow == null) {
            return computeSplitBounds(
                    containerW,
                    containerH,
                    false,
                    0,
                    0,
                    0,
                    0,
                    sensorHalfFolded,
                    fallbackCreaseHalfGapPx);
        }
        return computeSplitBounds(
                containerW,
                containerH,
                true,
                foldBoundsInWindow.left,
                foldBoundsInWindow.top,
                foldBoundsInWindow.right,
                foldBoundsInWindow.bottom,
                sensorHalfFolded,
                fallbackCreaseHalfGapPx);
    }

    static SplitBounds computeSplitBounds(
            int containerW,
            int containerH,
            boolean hasFoldFeature,
            int foldLeft,
            int foldTop,
            int foldRight,
            int foldBottom,
            boolean sensorHalfFolded,
            int fallbackCreaseHalfGapPx) {
        if (containerW <= 0 || containerH <= 0) {
            return new SplitBounds(false, false, Math.max(1, containerH), containerH);
        }
        if (hasFoldFeature) {
            int bw = Math.max(0, foldRight - foldLeft);
            int bh = Math.max(0, foldBottom - foldTop);
            if (bh > bw && foldLeft >= containerW * 0.25f && foldRight <= containerW * 0.75f) {
                return new SplitBounds(false, true, containerH, containerH);
            }
            if (bw >= bh
                    && bw >= containerW * 0.5f
                    && bh <= containerH * 0.18f
                    && foldTop >= containerH * 0.28f
                    && foldBottom <= containerH * 0.72f) {
                int upBot = Math.max(1, Math.min(containerH - 2, foldTop));
                int lowTop = Math.max(upBot, Math.min(containerH - 1, foldBottom));
                return new SplitBounds(true, false, upBot, lowTop);
            }
            return new SplitBounds(false, false, containerH, containerH);
        }
        if (sensorHalfFolded && containerH >= 360) {
            int gap = Math.max(0, fallbackCreaseHalfGapPx);
            int half = containerH / 2;
            int upBot = Math.max(1, half - gap);
            int lowTop = Math.min(containerH - 1, Math.max(upBot, half + gap));
            return new SplitBounds(true, false, upBot, lowTop);
        }
        return new SplitBounds(false, false, containerH, containerH);
    }

    private final MainActivity a;
    private final Cms.Site site;
    private final Cms.Video video;
    private final Cms.Episode episode;
    private final PlaybackControls controls;
    private final SimpleDateFormat clockFmt = new SimpleDateFormat("HH:mm", Locale.US);

    private FrameLayout upperPeekHeader;
    private TextView peekTitleView;
    private TextView peekMetaPill;
    private TextView peekClockView;
    private TextView peekBatteryView;
    private MobileIcons.IconView peekBatteryIcon;
    private boolean peekVisible = true;

    private LinearLayout tabletopDeck;
    private FrameLayout deckBackBtn;
    private FrameLayout deckLockBtn;
    private View danmuDot;
    private TextView deckDanmuLabel;
    private TextView deckSpeedLabel;
    private TextView deckLineLabel;
    private TextView deckQualityResLabel;
    private TextView deckElapsedView;
    private TextView deckTotalView;
    private SeekBar deckSeekBar;
    private MobileIcons.IconView deckPlayIcon;
    private FrameLayout deckPlayBtn;
    private FrameLayout deckNextBtn;
    private TextView deckHintBanner;

    private boolean destroyed;
    private boolean active;
    private boolean deckSeeking;
    private int upperBottomPx;
    private int lowerTopPx;
    private boolean windowHalfOpened;
    private Rect windowFoldBounds;
    private boolean sensorHalfFolded;
    private boolean orientationFlippedForHinge;
    private long lastPostureChangeUptime;
    private boolean posturePendingApply;

    private Object windowLayoutComponent;
    private Object windowLayoutConsumerProxy;
    private Object sidecarImpl;
    private Object sidecarCallbackProxy;
    private SensorManager sensorManager;
    private Sensor hingeSensor;
    private SensorEventListener hingeSensorListener;

    private final Runnable hidePeekRunnable =
            () -> {
                peekVisible = false;
                syncPeekVisibility(true);
            };

    private final Runnable debouncedEvaluateRunnable =
            () -> {
                posturePendingApply = false;
                evaluateNow();
            };

    private final View.OnLayoutChangeListener rootLayoutListener =
            (v, l, t, r, b, ol, ot, or, ob) -> {
                if (!destroyed && (r - l != or - ol || b - t != ob - ot)) {
                    evaluateNow();
                }
            };

    FoldableTabletopController(
            MainActivity activity,
            Cms.Site site,
            Cms.Video video,
            Cms.Episode episode,
            PlaybackControls controls) {
        this.a = activity;
        this.site = site;
        this.video = video;
        this.episode = episode;
        this.controls = controls;
        buildViews();
        mountViews();
        registerFoldObservers();
        evaluateNow();
    }

    private void buildViews() {
        final int radiusDeckBtn = 12;
        final boolean live = site != null && "live".equals(site.key);

        // 1. Upper-half tap-to-peek header
        upperPeekHeader = new FrameLayout(a);
        upperPeekHeader.setTag("foldable-peek-header");
        GradientDrawable peekShade =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xB8000000, 0x33000000, 0x00000000});
        upperPeekHeader.setBackground(peekShade);
        upperPeekHeader.setPadding(a.dp(18), a.dp(12), a.dp(18), a.dp(16));
        upperPeekHeader.setVisibility(View.GONE);

        LinearLayout peekRow = a.row();
        peekRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout leftCol = a.vertical();
        String titleStr = video != null && video.title != null ? video.title.trim() : "";
        peekTitleView = a.text(titleStr.isEmpty() ? "正在播放" : titleStr, 15f, MainActivity.WHITE);
        peekTitleView.setTypeface(null, Typeface.BOLD);
        peekTitleView.setSingleLine(true);
        peekTitleView.setEllipsize(TextUtils.TruncateAt.END);
        leftCol.addView(peekTitleView, new LinearLayout.LayoutParams(-1, -2));

        peekMetaPill = a.text("", 11f, 0xFFD9E1EE);
        peekMetaPill.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
        peekMetaPill.setBackground(a.bg(0x38000000, 999));
        peekMetaPill.setVisibility(View.GONE);
        LinearLayout.LayoutParams mpLp = new LinearLayout.LayoutParams(-2, -2);
        mpLp.topMargin = a.dp(4);
        leftCol.addView(peekMetaPill, mpLp);
        peekRow.addView(leftCol, new LinearLayout.LayoutParams(0, -2, 1f));

        LinearLayout rightTelemetry = a.row();
        rightTelemetry.setGravity(Gravity.CENTER_VERTICAL);
        peekClockView = a.text("", 12f, 0xFFF3F5F9);
        peekClockView.setTypeface(null, Typeface.BOLD);
        rightTelemetry.addView(peekClockView, new LinearLayout.LayoutParams(-2, -2));

        peekBatteryIcon = MobileIcons.create(a, MobileIcons.IC_BATTERY, 14f, 0xE6FFFFFF);
        peekBatteryIcon.setStrokeWidthUnits(1.7f);
        LinearLayout.LayoutParams biLp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
        biLp.leftMargin = a.dp(8);
        biLp.rightMargin = a.dp(3);
        rightTelemetry.addView(peekBatteryIcon, biLp);

        peekBatteryView = a.text("", 11.5f, 0xEBF3F5F9);
        rightTelemetry.addView(peekBatteryView, new LinearLayout.LayoutParams(-2, -2));
        peekRow.addView(rightTelemetry, new LinearLayout.LayoutParams(-2, -2));
        upperPeekHeader.addView(peekRow, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        // 2. Lower-half persistent dark matte tabletop control deck
        tabletopDeck = a.vertical();
        tabletopDeck.setTag("foldable-tabletop-deck");
        tabletopDeck.setBackgroundColor(0xFF0A0C10);
        tabletopDeck.setClickable(true);
        tabletopDeck.setFocusable(false);
        tabletopDeck.setPadding(a.dp(20), a.dp(14), a.dp(20), a.dp(16));
        tabletopDeck.setVisibility(View.GONE);

        // 2a. Top row: Back (<) + optional Lock pill
        LinearLayout topDeckRow = a.row();
        topDeckRow.setGravity(Gravity.CENTER_VERTICAL);
        deckBackBtn =
                makeDeckIconPill(
                        MobileIcons.IC_BACK,
                        18f,
                        46,
                        32,
                        "返回",
                        () -> {
                            PlaybackControls.clearSleepTimerOnLeave();
                            a.leavePlayback();
                        });
        topDeckRow.addView(deckBackBtn, new LinearLayout.LayoutParams(a.dp(46), a.dp(32)));

        View topSpacer = new View(a);
        topDeckRow.addView(topSpacer, new LinearLayout.LayoutParams(0, 1, 1f));

        deckHintBanner = a.text("", 11.5f, 0xCCBFD0E6);
        deckHintBanner.setSingleLine(true);
        deckHintBanner.setEllipsize(TextUtils.TruncateAt.END);
        topDeckRow.addView(deckHintBanner, new LinearLayout.LayoutParams(-2, -2));

        deckLockBtn =
                makeDeckIconPill(
                        MobileIcons.IC_LOCK,
                        15f,
                        34,
                        32,
                        "锁定屏幕",
                        () -> PlaybackController.setPlayerLocked(a, !a.playerLocked));
        LinearLayout.LayoutParams lkLp = new LinearLayout.LayoutParams(a.dp(34), a.dp(32));
        lkLp.leftMargin = a.dp(10);
        topDeckRow.addView(deckLockBtn, lkLp);
        tabletopDeck.addView(topDeckRow, new LinearLayout.LayoutParams(-1, -2));

        // Flexible vertical spacer above center tool strip
        View midTopSpacer = new View(a);
        tabletopDeck.addView(midTopSpacer, new LinearLayout.LayoutParams(-1, 0, 1f));

        // 2b. Center horizontally centered action strip: 弹 / 倍速 / 音效 / 智能+分辨率 / 选集 / 字幕 / 更多
        HorizontalScrollView toolScroll = new HorizontalScrollView(a);
        toolScroll.setHorizontalScrollBarEnabled(false);
        toolScroll.setFillViewport(true);
        toolScroll.setOverScrollMode(View.OVER_SCROLL_NEVER);

        LinearLayout toolStrip = a.row();
        toolStrip.setGravity(Gravity.CENTER);
        toolStrip.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(6));

        if (!live) {
            LinearLayout danmuAction = a.row();
            danmuAction.setTag("foldable-deck-danmu");
            danmuAction.setGravity(Gravity.CENTER);
            danmuAction.setPadding(a.dp(14), a.dp(8), a.dp(14), a.dp(8));
            deckDanmuLabel = a.text("弹", 14.5f, 0xFFF3F5F9);
            deckDanmuLabel.setTypeface(null, Typeface.BOLD);
            danmuAction.addView(deckDanmuLabel);
            danmuDot = new View(a);
            GradientDrawable dotBg = new GradientDrawable();
            dotBg.setShape(GradientDrawable.OVAL);
            dotBg.setColor(0xFF4ADE80);
            danmuDot.setBackground(dotBg);
            LinearLayout.LayoutParams dLp = new LinearLayout.LayoutParams(a.dp(6), a.dp(6));
            dLp.leftMargin = a.dp(3);
            dLp.gravity = Gravity.BOTTOM;
            dLp.bottomMargin = a.dp(2);
            danmuAction.addView(danmuDot, dLp);
            MobileMotion.bindPress(danmuAction, 0.92f);
            danmuAction.setOnClickListener(
                    v -> {
                        if (controls != null) {
                            controls.toggleMobileDanmakuFromDeck();
                            syncDynamicStates();
                        }
                    });
            toolStrip.addView(danmuAction, new LinearLayout.LayoutParams(-2, -2));
        }

        deckSpeedLabel =
                addDeckTextAction(
                        toolStrip,
                        "foldable-deck-speed",
                        "倍速",
                        () -> {
                            if (controls != null) controls.speed();
                        });

        addDeckTextAction(
                toolStrip,
                "foldable-deck-sound",
                "音效",
                () -> {
                    if (controls != null) controls.soundEffect();
                });

        // Two-line Quality/Route + Resolution pill
        LinearLayout qualBox = a.vertical();
        qualBox.setTag("foldable-deck-quality");
        qualBox.setGravity(Gravity.CENTER);
        qualBox.setPadding(a.dp(14), a.dp(4), a.dp(14), a.dp(4));
        deckLineLabel = a.text("智能", 13.5f, 0xFFF3F5F9);
        deckLineLabel.setTypeface(null, Typeface.BOLD);
        deckLineLabel.setSingleLine(true);
        qualBox.addView(deckLineLabel, new LinearLayout.LayoutParams(-2, -2));

        deckQualityResLabel = a.text("自动", 9.5f, 0xFF0B0E14);
        deckQualityResLabel.setTypeface(null, Typeface.BOLD);
        deckQualityResLabel.setPadding(a.dp(5), a.dp(1), a.dp(5), a.dp(1));
        deckQualityResLabel.setBackground(a.bg(0xFFE5E7EB, 4));
        LinearLayout.LayoutParams qrLp = new LinearLayout.LayoutParams(-2, -2);
        qrLp.topMargin = a.dp(2);
        qualBox.addView(deckQualityResLabel, qrLp);
        MobileMotion.bindPress(qualBox, 0.92f);
        qualBox.setOnClickListener(
                v -> {
                    if (controls != null) {
                        controls.showQualityAndVideoTrackSheet();
                    }
                });
        toolStrip.addView(qualBox, new LinearLayout.LayoutParams(-2, -2));

        boolean hasMultiEp =
                !live
                        && a.activeLine != null
                        && a.activeLine.episodes != null
                        && a.activeLine.episodes.size() > 1;
        if (live || hasMultiEp) {
            addDeckTextAction(
                    toolStrip,
                    "foldable-deck-episodes",
                    live ? "频道" : "选集",
                    () -> {
                        if (live) a.chooseLiveChannel();
                        else if (controls != null) controls.chooseEpisodes();
                    });
        }
        if (!live) {
            addDeckTextAction(
                    toolStrip,
                    "foldable-deck-subtitle",
                    "字幕",
                    () -> {
                        if (controls != null) controls.showMobileSubtitleSheet();
                    });
        }
        addDeckTextAction(
                toolStrip,
                "foldable-deck-more",
                "更多",
                () -> {
                    if (controls != null) controls.showMobileMoreSheet();
                });

        toolScroll.addView(toolStrip, new FrameLayout.LayoutParams(-1, -2));
        tabletopDeck.addView(toolScroll, new LinearLayout.LayoutParams(-1, -2));

        // 2c. Full-width seekbar + timestamps row
        LinearLayout seekRow = a.row();
        seekRow.setGravity(Gravity.CENTER_VERTICAL);
        seekRow.setPadding(0, a.dp(12), 0, a.dp(12));

        deckElapsedView = a.text("00:00", 12f, 0xFFE5E7EB);
        deckElapsedView.setTypeface(Typeface.MONOSPACE);
        seekRow.addView(deckElapsedView, new LinearLayout.LayoutParams(-2, -2));

        deckSeekBar = new SeekBar(a);
        deckSeekBar.setTag("foldable-deck-seekbar");
        deckSeekBar.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
        GradientDrawable thumb = new GradientDrawable();
        thumb.setShape(GradientDrawable.OVAL);
        thumb.setSize(a.dp(13), a.dp(13));
        thumb.setColor(0xFFFFFFFF);
        deckSeekBar.setThumb(thumb);
        deckSeekBar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    @Override
                    public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                        if (fromUser && deckElapsedView != null) {
                            deckElapsedView.setText(PlaybackController.formatTime(progress));
                        }
                    }

                    @Override
                    public void onStartTrackingTouch(SeekBar bar) {
                        deckSeeking = true;
                        if (controls != null) controls.touchSeeking = true;
                    }

                    @Override
                    public void onStopTrackingTouch(SeekBar bar) {
                        deckSeeking = false;
                        int target = bar.getProgress();
                        if (controls != null) {
                            controls.touchSeeking = false;
                            if (a.player != null && a.prepared) {
                                controls.recordUserSeek(target);
                                a.player.seekTo(target);
                            }
                        }
                    }
                });
        LinearLayout.LayoutParams sbLp = new LinearLayout.LayoutParams(0, -2, 1f);
        sbLp.leftMargin = a.dp(6);
        sbLp.rightMargin = a.dp(6);
        seekRow.addView(deckSeekBar, sbLp);

        deckTotalView = a.text("00:00", 12f, 0xFFA1AAB8);
        deckTotalView.setTypeface(Typeface.MONOSPACE);
        seekRow.addView(deckTotalView, new LinearLayout.LayoutParams(-2, -2));
        tabletopDeck.addView(seekRow, new LinearLayout.LayoutParams(-1, -2));

        View midBotSpacer = new View(a);
        tabletopDeck.addView(midBotSpacer, new LinearLayout.LayoutParams(-1, 0, 1f));

        // 2d. Bottom transport row: bottom-left Pause/Play + bottom-right Next Episode
        LinearLayout bottomRow = a.row();
        bottomRow.setGravity(Gravity.CENTER_VERTICAL);
        deckPlayBtn = new FrameLayout(a);
        deckPlayBtn.setTag("foldable-deck-play");
        deckPlayBtn.setContentDescription("播放/暂停");
        GradientDrawable playBg = a.bg(0xFF1C2029, radiusDeckBtn);
        playBg.setStroke(MobileTheme.hairlinePx(a), 0x22FFFFFF);
        deckPlayBtn.setBackground(playBg);
        deckPlayIcon = MobileIcons.create(a, MobileIcons.IC_PAUSE, 19f, MainActivity.WHITE);
        deckPlayIcon.setStrokeWidthUnits(2.1f);
        deckPlayBtn.addView(
                deckPlayIcon, new FrameLayout.LayoutParams(a.dp(19), a.dp(19), Gravity.CENTER));
        MobileMotion.bindPress(deckPlayBtn, 0.92f);
        deckPlayBtn.setOnClickListener(
                v -> {
                    a.togglePlayback();
                    syncDynamicStates();
                });
        bottomRow.addView(deckPlayBtn, new LinearLayout.LayoutParams(a.dp(54), a.dp(38)));

        View botSpacer = new View(a);
        bottomRow.addView(botSpacer, new LinearLayout.LayoutParams(0, 1, 1f));

        deckNextBtn =
                makeDeckIconPill(
                        MobileIcons.IC_NEXT_EP,
                        19f,
                        54,
                        38,
                        live ? "下一频道" : "下一集",
                        () -> {
                            if (live) {
                                a.liveStep(1);
                            } else if (controls != null && !controls.step(1)) {
                                a.toast("已是最后一集");
                            }
                        });
        deckNextBtn.setVisibility(live || hasMultiEp ? View.VISIBLE : View.INVISIBLE);
        bottomRow.addView(deckNextBtn, new LinearLayout.LayoutParams(a.dp(54), a.dp(38)));
        tabletopDeck.addView(bottomRow, new LinearLayout.LayoutParams(-1, -2));
    }

    private FrameLayout makeDeckIconPill(
            int iconId, float iconDp, int wDp, int hDp, String desc, Runnable action) {
        FrameLayout btn = new FrameLayout(a);
        btn.setContentDescription(desc);
        GradientDrawable pillBg = a.bg(0xFF1C2029, 12);
        pillBg.setStroke(MobileTheme.hairlinePx(a), 0x22FFFFFF);
        btn.setBackground(pillBg);
        MobileIcons.IconView iv = MobileIcons.create(a, iconId, iconDp, MainActivity.WHITE);
        iv.setStrokeWidthUnits(2.0f);
        btn.addView(iv, new FrameLayout.LayoutParams(a.dp(iconDp), a.dp(iconDp), Gravity.CENTER));
        MobileMotion.bindPress(btn, 0.92f);
        btn.setOnClickListener(
                v -> {
                    if (action != null) action.run();
                });
        return btn;
    }

    private TextView addDeckTextAction(
            LinearLayout parent, String tag, String text, Runnable action) {
        TextView tv = a.text(text, 14f, 0xFFE5E7EB);
        tv.setTag(tag);
        tv.setSingleLine(true);
        tv.setGravity(Gravity.CENTER);
        tv.setPadding(a.dp(14), a.dp(8), a.dp(14), a.dp(8));
        MobileMotion.bindPress(tv, 0.92f);
        tv.setOnClickListener(
                v -> {
                    if (action != null) action.run();
                });
        parent.addView(tv, new LinearLayout.LayoutParams(-2, -2));
        return tv;
    }

    private void mountViews() {
        if (a.root == null) return;
        a.root.addView(upperPeekHeader, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));
        a.root.addView(tabletopDeck, new FrameLayout.LayoutParams(-1, 0, Gravity.BOTTOM));
        a.root.addOnLayoutChangeListener(rootLayoutListener);
    }

    private void registerFoldObservers() {
        registerWindowExtensions();
        if (windowLayoutComponent == null) {
            registerSidecar();
        }
        registerHingeSensor();
    }

    @SuppressWarnings("unchecked")
    private void registerWindowExtensions() {
        try {
            Class<?> providerCls =
                    Class.forName("androidx.window.extensions.WindowExtensionsProvider");
            Method getExt = providerCls.getMethod("getWindowExtensions");
            Object ext = getExt.invoke(null);
            if (ext == null) return;
            Method getComp = ext.getClass().getMethod("getWindowLayoutComponent");
            Object comp = getComp.invoke(ext);
            if (comp == null) return;

            Method addMethod = null;
            Class<?> consumerInterface = null;
            for (Method m : comp.getClass().getMethods()) {
                if (!"addWindowLayoutInfoListener".equals(m.getName())) continue;
                Class<?>[] pts = m.getParameterTypes();
                if (pts.length == 2 && Activity.class.isAssignableFrom(pts[0])) {
                    addMethod = m;
                    consumerInterface = pts[1];
                    break;
                }
            }
            if (addMethod == null || consumerInterface == null) return;

            Object proxy =
                    Proxy.newProxyInstance(
                            consumerInterface.getClassLoader(),
                            new Class<?>[] {consumerInterface},
                            new InvocationHandler() {
                                @Override
                                public Object invoke(Object p, Method m, Object[] args) {
                                    if ("accept".equals(m.getName())
                                            && args != null
                                            && args.length == 1
                                            && args[0] != null) {
                                        onWindowLayoutInfoReflective(args[0]);
                                    }
                                    return null;
                                }
                            });
            addMethod.invoke(comp, a, proxy);
            windowLayoutComponent = comp;
            windowLayoutConsumerProxy = proxy;
        } catch (Throwable ignored) {
        }
    }

    private void registerSidecar() {
        try {
            Class<?> providerCls = Class.forName("androidx.window.sidecar.SidecarProvider");
            Method getImpl = providerCls.getMethod("getSidecarImpl", Context.class);
            Object impl = getImpl.invoke(null, a);
            if (impl == null) return;
            Class<?> cbInterface =
                    Class.forName("androidx.window.sidecar.SidecarInterface$SidecarCallback");
            Object cbProxy =
                    Proxy.newProxyInstance(
                            cbInterface.getClassLoader(),
                            new Class<?>[] {cbInterface},
                            new InvocationHandler() {
                                @Override
                                public Object invoke(Object p, Method m, Object[] args) {
                                    if (args != null && args.length >= 1) {
                                        onSidecarCallbackReflective(m.getName(), args);
                                    }
                                    return null;
                                }
                            });
            Method setCb = impl.getClass().getMethod("setSidecarCallback", cbInterface);
            setCb.invoke(impl, cbProxy);
            Method onLayoutChanged =
                    impl.getClass()
                            .getMethod(
                                    "onWindowLayoutChangeListenerAdded", android.os.IBinder.class);
            View decor = a.getWindow() != null ? a.getWindow().getDecorView() : null;
            android.os.IBinder token = decor != null ? decor.getWindowToken() : null;
            if (token != null) {
                onLayoutChanged.invoke(impl, token);
            }
            sidecarImpl = impl;
            sidecarCallbackProxy = cbProxy;
        } catch (Throwable ignored) {
        }
    }

    private void registerHingeSensor() {
        try {
            sensorManager = (SensorManager) a.getSystemService(Context.SENSOR_SERVICE);
            if (sensorManager == null) return;
            Sensor found = sensorManager.getDefaultSensor(TYPE_HINGE_ANGLE_SENSOR);
            if (found == null) {
                List<Sensor> all = sensorManager.getSensorList(Sensor.TYPE_ALL);
                if (all != null) {
                    for (Sensor s : all) {
                        if (s == null) continue;
                        String st = s.getStringType();
                        if (st != null && st.toLowerCase(Locale.ROOT).contains("hinge_angle")) {
                            found = s;
                            break;
                        }
                    }
                }
            }
            if (found == null) return;
            hingeSensor = found;
            hingeSensorListener =
                    new SensorEventListener() {
                        @Override
                        public void onSensorChanged(SensorEvent event) {
                            if (destroyed
                                    || event == null
                                    || event.values == null
                                    || event.values.length == 0) {
                                return;
                            }
                            float deg = event.values[0];
                            boolean nextSensor = shouldEnterByHingeAngle(sensorHalfFolded, deg);
                            if (nextSensor != sensorHalfFolded) {
                                sensorHalfFolded = nextSensor;
                                schedulePostureEvaluation();
                            }
                        }

                        @Override
                        public void onAccuracyChanged(Sensor sensor, int accuracy) {}
                    };
            sensorManager.registerListener(
                    hingeSensorListener, hingeSensor, SensorManager.SENSOR_DELAY_NORMAL);
        } catch (Throwable ignored) {
        }
    }

    private void onWindowLayoutInfoReflective(Object layoutInfo) {
        if (destroyed || layoutInfo == null) return;
        try {
            Method getFeatures = layoutInfo.getClass().getMethod("getDisplayFeatures");
            Object rawList = getFeatures.invoke(layoutInfo);
            boolean halfFound = false;
            Rect foldRect = null;
            if (rawList instanceof List<?>) {
                for (Object item : (List<?>) rawList) {
                    if (item == null) continue;
                    try {
                        Method getState = item.getClass().getMethod("getState");
                        Object st = getState.invoke(item);
                        if (st instanceof Integer && ((Integer) st) == WINDOW_STATE_HALF_OPENED) {
                            halfFound = true;
                            Method getBounds = item.getClass().getMethod("getBounds");
                            Object b = getBounds.invoke(item);
                            if (b instanceof Rect) {
                                foldRect = new Rect((Rect) b);
                            }
                            break;
                        }
                    } catch (NoSuchMethodException ignored) {
                    }
                }
            }
            final boolean fHalf = halfFound;
            final Rect fRect = foldRect;
            a.ui.post(
                    () -> {
                        if (destroyed) return;
                        windowHalfOpened = fHalf;
                        windowFoldBounds = fRect;
                        schedulePostureEvaluation();
                    });
        } catch (Throwable ignored) {
        }
    }

    private void onSidecarCallbackReflective(String methodName, Object[] args) {
        if (destroyed) return;
        try {
            boolean half = windowHalfOpened;
            Rect rect = windowFoldBounds;
            if ("onDeviceStateChanged".equals(methodName) && args[0] != null) {
                Object posture = args[0].getClass().getField("posture").get(args[0]);
                if (posture instanceof Integer) {
                    half = ((Integer) posture) == WINDOW_STATE_HALF_OPENED;
                }
            } else if ("onWindowLayoutChanged".equals(methodName)
                    && args.length >= 2
                    && args[1] != null) {
                Object features = args[1].getClass().getField("displayFeatures").get(args[1]);
                if (features instanceof List<?>) {
                    rect = null;
                    for (Object f : (List<?>) features) {
                        if (f == null) continue;
                        Method getRect = f.getClass().getMethod("getRect");
                        Object r = getRect.invoke(f);
                        if (r instanceof Rect) {
                            rect = new Rect((Rect) r);
                            break;
                        }
                    }
                }
            }
            final boolean fHalf = half;
            final Rect fRect = rect;
            a.ui.post(
                    () -> {
                        if (destroyed) return;
                        windowHalfOpened = fHalf;
                        windowFoldBounds = fRect;
                        schedulePostureEvaluation();
                    });
        } catch (Throwable ignored) {
        }
    }

    private void schedulePostureEvaluation() {
        lastPostureChangeUptime = SystemClock.uptimeMillis();
        if (!posturePendingApply) {
            posturePendingApply = true;
            a.ui.postDelayed(debouncedEvaluateRunnable, POSTURE_DEBOUNCE_MS);
        }
    }

    boolean isEnabledInPrefs() {
        return a != null
                && a.mobilePrefs() != null
                && a.mobilePrefs().getBoolean(Prefs.FOLDABLE_TABLETOP_SPLIT_HUD, true);
    }

    boolean isTabletopActive() {
        return !destroyed && active;
    }

    int effectiveVideoStageHeight(int fallbackContainerHeight) {
        if (isTabletopActive() && upperBottomPx > 0) {
            return upperBottomPx;
        }
        return fallbackContainerHeight;
    }

    void onPreferenceChanged() {
        if (destroyed) return;
        evaluateNow();
    }

    void onResume() {
        if (destroyed) return;
        registerHingeSensor();
        evaluateNow();
    }

    void onPause() {
        if (sensorManager != null && hingeSensorListener != null) {
            try {
                sensorManager.unregisterListener(hingeSensorListener);
            } catch (Throwable ignored) {
            }
        }
    }

    void onUpperStageSingleTap() {
        if (!isTabletopActive()) return;
        peekVisible = !peekVisible;
        syncPeekVisibility(true);
    }

    private void syncPeekVisibility(boolean resetTimer) {
        if (upperPeekHeader == null) return;
        a.ui.removeCallbacks(hidePeekRunnable);
        boolean show = isTabletopActive() && peekVisible && !a.miniMode;
        upperPeekHeader.setVisibility(show ? View.VISIBLE : View.GONE);
        if (show && resetTimer) {
            a.ui.postDelayed(hidePeekRunnable, 3500L);
        }
    }

    private void evaluateNow() {
        if (destroyed || a.root == null) return;
        if (!isEnabledInPrefs()
                || a.miniMode
                || (Build.VERSION.SDK_INT >= 24 && a.isInPictureInPictureMode())) {
            setTabletopActive(false, 0, 0);
            return;
        }
        int w = a.root.getWidth() > 0 ? a.root.getWidth() : a.windowWidth();
        int h = a.root.getHeight() > 0 ? a.root.getHeight() : a.windowHeight();
        SplitBounds split =
                computeSplitBounds(
                        w,
                        h,
                        windowHalfOpened && windowFoldBounds != null,
                        windowFoldBounds != null ? windowFoldBounds.left : 0,
                        windowFoldBounds != null ? windowFoldBounds.top : 0,
                        windowFoldBounds != null ? windowFoldBounds.right : 0,
                        windowFoldBounds != null ? windowFoldBounds.bottom : 0,
                        sensorHalfFolded && (windowFoldBounds == null),
                        a.dp(10));
        if (split.needsOrientationFlipForHorizontalHinge
                && !a.playerLocked
                && !orientationFlippedForHinge) {
            orientationFlippedForHinge = true;
            a.setRequestedOrientation(
                    w >= h
                            ? ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            : ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
            return;
        }
        if (!split.active && orientationFlippedForHinge && !windowHalfOpened && !sensorHalfFolded) {
            orientationFlippedForHinge = false;
            if (!a.playerLocked) {
                a.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
            }
        }
        setTabletopActive(split.active, split.upperBottomPx, split.lowerTopPx);
    }

    private void setTabletopActive(boolean nextActive, int nextUpperBottom, int nextLowerTop) {
        int totalH =
                a.root != null && a.root.getHeight() > 0 ? a.root.getHeight() : a.windowHeight();
        boolean changed =
                active != nextActive
                        || (nextActive
                                && (upperBottomPx != nextUpperBottom
                                        || lowerTopPx != nextLowerTop));
        active = nextActive;
        upperBottomPx = nextActive ? nextUpperBottom : totalH;
        lowerTopPx = nextActive ? nextLowerTop : totalH;

        if (!changed) return;

        if (active) {
            peekVisible = true;
            a.applyMobileSystemBars(true);
            layoutSplitContainers(totalH);
            tabletopDeck.setVisibility(View.VISIBLE);
            tabletopDeck.bringToFront();
            if (a.playerOverlay != null) {
                a.playerOverlay.setVisibility(View.GONE);
            }
            if (a.mobilePlayerOverlay != null) {
                a.mobilePlayerOverlay.syncControlsVisibility();
            }
            syncPeekVisibility(true);
            syncDynamicStates();
        } else {
            layoutFullContainers();
            tabletopDeck.setVisibility(View.GONE);
            upperPeekHeader.setVisibility(View.GONE);
            if (a.playerOverlay != null) {
                a.playerOverlay.setVisibility(a.controlsVisible ? View.VISIBLE : View.GONE);
            }
            if (a.mobilePlayerOverlay != null) {
                a.mobilePlayerOverlay.syncControlsVisibility();
            }
        }
        if (controls != null) {
            controls.resize(controls.videoWidth, controls.videoHeight);
        }
    }

    private void layoutSplitContainers(int totalH) {
        if (a.playbackLayer != null) {
            FrameLayout.LayoutParams plp =
                    new FrameLayout.LayoutParams(-1, Math.max(1, upperBottomPx), Gravity.TOP);
            a.playbackLayer.setLayoutParams(plp);
        }
        if (upperPeekHeader != null) {
            FrameLayout.LayoutParams hlp = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
            int topInset = a.playerChrome != null ? a.playerChrome.windowInsets.top : 0;
            upperPeekHeader.setPadding(
                    a.dp(18), Math.max(a.dp(12), topInset + a.dp(4)), a.dp(18), a.dp(14));
            upperPeekHeader.setLayoutParams(hlp);
        }
        if (tabletopDeck != null) {
            int deckH = Math.max(a.dp(140), totalH - lowerTopPx);
            FrameLayout.LayoutParams dlp = new FrameLayout.LayoutParams(-1, deckH, Gravity.BOTTOM);
            int navBot = a.navigationBarHeight();
            tabletopDeck.setPadding(
                    a.dp(20), a.dp(14), a.dp(20), Math.max(a.dp(16), navBot + a.dp(8)));
            tabletopDeck.setLayoutParams(dlp);
        }
    }

    private void layoutFullContainers() {
        if (a.playbackLayer != null) {
            a.playbackLayer.setLayoutParams(new FrameLayout.LayoutParams(-1, -1));
        }
    }

    void onPlaybackTick() {
        if (!isTabletopActive()) return;
        syncDynamicStates();
    }

    void syncDynamicStates() {
        if (!isTabletopActive()) return;
        if (peekClockView != null) {
            peekClockView.setText(clockFmt.format(new Date()));
        }
        if (peekBatteryView != null && peekBatteryIcon != null) {
            int bat = queryBatteryPercent();
            boolean chg = isBatteryCharging();
            if (bat >= 0) {
                peekBatteryIcon.setLevel(Math.min(100, bat), chg);
                peekBatteryIcon.setVisibility(View.VISIBLE);
                peekBatteryView.setVisibility(View.VISIBLE);
                peekBatteryView.setText(Math.min(100, bat) + "%");
            } else {
                peekBatteryIcon.setVisibility(View.GONE);
                peekBatteryView.setVisibility(View.GONE);
            }
        }
        if (controls != null && deckPlayIcon != null) {
            int icon = a.playing ? MobileIcons.IC_PAUSE : MobileIcons.IC_PLAY;
            deckPlayIcon.setIcon(icon);
        }
        if (danmuDot != null && controls != null) {
            danmuDot.setVisibility(controls.isDanmakuEnabled() ? View.VISIBLE : View.INVISIBLE);
        }
        if (deckSpeedLabel != null && a.prefs != null) {
            float spd = a.prefs.getFloat(Prefs.PLAY_SPEED, 1f);
            deckSpeedLabel.setText(Math.abs(spd - 1f) < 0.01f ? "倍速" : spd + "×");
        }
        if (deckQualityResLabel != null) {
            String res = a.player != null && a.prepared ? a.player.activeDecodedResolution() : "自动";
            if (res == null || res.trim().isEmpty()) res = "自动";
            deckQualityResLabel.setText(res);
        }
        if (deckLineLabel != null && a.activeLine != null && a.activeLine.name != null) {
            String ln = a.activeLine.name.trim();
            deckLineLabel.setText(ln.length() > 6 ? "智能" : (ln.isEmpty() ? "智能" : ln));
        }
        if (deckHintBanner != null && a.activeEpisode != null && a.activeEpisode.name != null) {
            deckHintBanner.setText(a.activeEpisode.name.trim());
        }
        if (!deckSeeking && a.player != null && a.prepared && deckSeekBar != null) {
            int pos =
                    controls != null
                            ? controls.displayPosition(a.player.getCurrentPosition())
                            : a.player.getCurrentPosition();
            int dur = a.player.getDuration();
            if (dur <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
                dur = a.playingBookmark.duration;
            }
            if (peekMetaPill != null && dur > 0) {
                int mins = Math.max(1, dur / 60000);
                peekMetaPill.setText(mins + "分钟");
                peekMetaPill.setVisibility(View.VISIBLE);
            }
            if (dur > 0) {
                deckSeekBar.setEnabled(true);
                int max = Math.max(dur, pos);
                if (deckSeekBar.getMax() != max) deckSeekBar.setMax(max);
                deckSeekBar.setProgress(Math.max(0, Math.min(pos, max)));
            } else {
                deckSeekBar.setEnabled(false);
                deckSeekBar.setProgress(0);
            }
            if (deckElapsedView != null) {
                deckElapsedView.setText(PlaybackController.formatTime(Math.max(0, pos)));
            }
            if (deckTotalView != null) {
                deckTotalView.setText(
                        dur > 0
                                ? PlaybackController.formatTime(dur)
                                : (a.isLive() ? "直播" : "--:--"));
            }
        }
    }

    private int queryBatteryPercent() {
        try {
            BatteryManager bm = (BatteryManager) a.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                int cap = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
                if (cap >= 0 && cap <= 100) return cap;
            }
        } catch (Throwable ignored) {
        }
        return -1;
    }

    private boolean isBatteryCharging() {
        try {
            Intent intent =
                    a.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (intent != null) {
                int status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
                return status == BatteryManager.BATTERY_STATUS_CHARGING
                        || status == BatteryManager.BATTERY_STATUS_FULL;
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    void detach() {
        if (destroyed) return;
        destroyed = true;
        a.ui.removeCallbacks(hidePeekRunnable);
        a.ui.removeCallbacks(debouncedEvaluateRunnable);
        if (a.root != null) {
            a.root.removeOnLayoutChangeListener(rootLayoutListener);
            a.root.removeView(upperPeekHeader);
            a.root.removeView(tabletopDeck);
        }
        layoutFullContainers();
        if (windowLayoutComponent != null && windowLayoutConsumerProxy != null) {
            try {
                for (Method m : windowLayoutComponent.getClass().getMethods()) {
                    if ("removeWindowLayoutInfoListener".equals(m.getName())
                            && m.getParameterTypes().length == 1) {
                        m.invoke(windowLayoutComponent, windowLayoutConsumerProxy);
                        break;
                    }
                }
            } catch (Throwable ignored) {
            }
        }
        if (sidecarImpl != null) {
            try {
                View decor = a.getWindow() != null ? a.getWindow().getDecorView() : null;
                android.os.IBinder token = decor != null ? decor.getWindowToken() : null;
                if (token != null) {
                    sidecarImpl
                            .getClass()
                            .getMethod(
                                    "onWindowLayoutChangeListenerRemoved", android.os.IBinder.class)
                            .invoke(sidecarImpl, token);
                }
            } catch (Throwable ignored) {
            }
        }
        if (sensorManager != null && hingeSensorListener != null) {
            try {
                sensorManager.unregisterListener(hingeSensorListener);
            } catch (Throwable ignored) {
            }
        }
    }
}

package com.pilipala.marcomovie;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.TrafficStats;
import android.os.BatteryManager;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * Mobile fullscreen player companion overlay:
 * - Idle-only top-right status micro-capsule ({@link Prefs#PLAYER_CORNER_HUD}: real Clock, vector
 *   Battery, real TrafficStats Net Speed, real Resolution — hidden whenever main HUD controls are
 *   expanded to prevent overlap)
 * - 2dp bottom accent {@code MiniProgressBar} shown whenever full controls hide ({@link
 *   Prefs#MINI_PROGRESS_BAR})
 * - Optional {@link Prefs#LETTERBOX_BLUR} cinema ambient glow behind {@link VideoOutput}
 * - Automatic {@link TmdbService#lookupIntroDbAsync} community intro/credits skip in fullscreen.
 */
final class MobilePlayerOverlay {
    static final int REAL_CORNER_HUD_MASK =
            Prefs.HUD_CLOCK | Prefs.HUD_BATTERY | Prefs.HUD_NET_SPEED | Prefs.HUD_RESOLUTION;

    static final int ANCHOR_TOP_RIGHT = 0;
    static final int ANCHOR_TOP_LEFT = 1;
    static final int ANCHOR_TOP_CENTER = 2;
    static final int ANCHOR_BOTTOM_RIGHT = 3;
    static final int ANCHOR_BOTTOM_LEFT = 4;

    static final int MIN_OFFSET_X_DP = -400;
    static final int MAX_OFFSET_X_DP = 400;
    static final int MIN_OFFSET_Y_DP = -300;
    static final int MAX_OFFSET_Y_DP = 300;

    static final class CornerPlacement {
        final int leftPx;
        final int topPx;

        CornerPlacement(int leftPx, int topPx) {
            this.leftPx = leftPx;
            this.topPx = topPx;
        }
    }

    private final MainActivity a;
    private final LinearLayout hudCapsule;
    private final TextView hudPrefixText;
    private final TextView hudBatterySep;
    private final MobileIcons.IconView hudBatteryIcon;
    private final TextView hudBatteryText;
    private final TextView hudClockSep;
    private final TextView hudClockText;
    private final MiniProgressView miniBar;
    private View letterboxGlow;
    private FrameLayout dragOverlayLayer;
    private LinearLayout dragBanner;
    private TextView dragCoordHint;
    private boolean closed;
    private boolean hudCapsuleShown;
    private boolean miniBarShown;
    private boolean adjustingPosition;
    private long lastRxBytes = -1;
    private long lastRxTimeMs = 0;
    private String lastSampledNetSpeed = "";
    private long episodeToken = 1L;
    private final IntroSkipEvaluator skipEvaluator = new IntroSkipEvaluator();
    private final SimpleDateFormat clockFmt = new SimpleDateFormat("HH:mm", Locale.US);
    private final View.OnLayoutChangeListener containerLayoutListener =
            (v, l, t, r, b, ol, ot, or, ob) -> {
                if (!closed) updateCapsuleSafeMargins();
            };
    private final View.OnLayoutChangeListener capsuleLayoutListener =
            (v, l, t, r, b, ol, ot, or, ob) -> {
                if (!closed && (r - l != or - ol || b - t != ob - ot)) {
                    updateCapsuleSafeMargins();
                }
            };

    private final Runnable pulse =
            new Runnable() {
                @Override
                public void run() {
                    if (closed || a.isFinishing() || a.playbackLayer == null) return;
                    updateHudAndMiniBar();
                    a.ui.postDelayed(this, 1000);
                }
            };

    /**
     * Pure-JVM visibility rule for the idle top-right micro-capsule: strictly hidden when main
     * controls are visible or the screen is locked, and only shown when at least one real telemetry
     * flag is enabled.
     */
    static boolean shouldShowIdleCornerHud(
            boolean controlsVisible, int cornerMask, boolean locked) {
        if (controlsVisible || locked) return false;
        return (cornerMask & REAL_CORNER_HUD_MASK) != 0;
    }

    static int clampAnchor(int raw) {
        return Math.max(ANCHOR_TOP_RIGHT, Math.min(ANCHOR_BOTTOM_LEFT, raw));
    }

    static int clampOffsetXDp(int raw) {
        return Math.max(MIN_OFFSET_X_DP, Math.min(MAX_OFFSET_X_DP, raw));
    }

    static int clampOffsetYDp(int raw) {
        return Math.max(MIN_OFFSET_Y_DP, Math.min(MAX_OFFSET_Y_DP, raw));
    }

    static boolean hasCustomCornerHudPosition(int anchor, int offsetXDp, int offsetYDp) {
        return clampAnchor(anchor) != ANCHOR_TOP_RIGHT
                || clampOffsetXDp(offsetXDp) != 0
                || clampOffsetYDp(offsetYDp) != 0;
    }

    static boolean shouldShowCornerHud(
            boolean controlsVisible,
            int cornerMask,
            boolean locked,
            boolean customPosition,
            boolean adjustingPosition) {
        if (adjustingPosition) return true;
        if (locked || (cornerMask & REAL_CORNER_HUD_MASK) == 0) return false;
        if (customPosition) return true;
        return !controlsVisible;
    }

    static String anchorLabel(int anchor) {
        switch (clampAnchor(anchor)) {
            case ANCHOR_TOP_LEFT:
                return "左上角";
            case ANCHOR_TOP_CENTER:
                return "顶部居中";
            case ANCHOR_BOTTOM_RIGHT:
                return "右下角";
            case ANCHOR_BOTTOM_LEFT:
                return "左下角";
            case ANCHOR_TOP_RIGHT:
            default:
                return "右上角";
        }
    }

    static String describeCornerPosition(int anchor, int offsetXDp, int offsetYDp) {
        int aClamped = clampAnchor(anchor);
        int xClamped = clampOffsetXDp(offsetXDp);
        int yClamped = clampOffsetYDp(offsetYDp);
        if (!hasCustomCornerHudPosition(aClamped, xClamped, yClamped)) {
            return "右上角（默认）";
        }
        StringBuilder sb = new StringBuilder(anchorLabel(aClamped));
        if (xClamped != 0 || yClamped != 0) {
            sb.append(" · X")
                    .append(xClamped >= 0 ? "+" : "")
                    .append(xClamped)
                    .append(" Y")
                    .append(yClamped >= 0 ? "+" : "")
                    .append(yClamped);
        }
        return sb.toString();
    }

    static CornerPlacement computeCornerPlacement(
            int containerW,
            int containerH,
            int capsuleW,
            int capsuleH,
            int safeLeft,
            int safeTop,
            int safeRight,
            int safeBottom,
            int anchor,
            int offsetXPx,
            int offsetYPx,
            int basePadHPx,
            int basePadVPx) {
        int cW = Math.max(1, containerW);
        int cH = Math.max(1, containerH);
        int capW = Math.max(0, Math.min(cW, capsuleW));
        int capH = Math.max(0, Math.min(cH, capsuleH));
        int sLeft = Math.max(0, safeLeft);
        int sTop = Math.max(0, safeTop);
        int sRight = Math.max(0, safeRight);
        int sBottom = Math.max(0, safeBottom);

        int minLeft = Math.min(Math.max(4, sLeft + basePadHPx / 2), Math.max(4, cW - capW - 4));
        int maxLeft = Math.max(minLeft, cW - Math.max(4, sRight + basePadHPx / 2) - capW);
        int minTop = Math.min(Math.max(4, sTop + basePadVPx / 2), Math.max(4, cH - capH - 4));
        int maxTop = Math.max(minTop, cH - Math.max(4, sBottom + basePadVPx / 2) - capH);

        int baseLeft;
        int baseTop;
        int aClamped = clampAnchor(anchor);
        switch (aClamped) {
            case ANCHOR_TOP_LEFT:
                baseLeft = sLeft + basePadHPx;
                baseTop = sTop + basePadVPx;
                break;
            case ANCHOR_TOP_CENTER:
                baseLeft = (cW - capW) / 2;
                baseTop = sTop + basePadVPx;
                break;
            case ANCHOR_BOTTOM_RIGHT:
                baseLeft = cW - sRight - basePadHPx - capW;
                baseTop = cH - sBottom - basePadVPx - capH;
                break;
            case ANCHOR_BOTTOM_LEFT:
                baseLeft = sLeft + basePadHPx;
                baseTop = cH - sBottom - basePadVPx - capH;
                break;
            case ANCHOR_TOP_RIGHT:
            default:
                baseLeft = cW - sRight - basePadHPx - capW;
                baseTop = sTop + basePadVPx;
                break;
        }

        int finalLeft = Math.max(minLeft, Math.min(maxLeft, baseLeft + offsetXPx));
        int finalTop = Math.max(minTop, Math.min(maxTop, baseTop + offsetYPx));
        return new CornerPlacement(finalLeft, finalTop);
    }

    static int[] resolveDraggedAnchorAndOffsets(
            int containerW,
            int containerH,
            int capsuleW,
            int capsuleH,
            int safeLeft,
            int safeTop,
            int safeRight,
            int safeBottom,
            int desiredLeftPx,
            int desiredTopPx,
            int basePadHPx,
            int basePadVPx,
            float density) {
        float d = density > 0f ? density : 1f;
        int cW = Math.max(1, containerW);
        int cH = Math.max(1, containerH);
        int capW = Math.max(0, Math.min(cW, capsuleW));
        int capH = Math.max(0, Math.min(cH, capsuleH));
        int sLeft = Math.max(0, safeLeft);
        int sTop = Math.max(0, safeTop);
        int sRight = Math.max(0, safeRight);
        int sBottom = Math.max(0, safeBottom);
        int minLeft = Math.min(Math.max(4, sLeft + basePadHPx / 2), Math.max(4, cW - capW - 4));
        int maxLeft = Math.max(minLeft, cW - Math.max(4, sRight + basePadHPx / 2) - capW);
        int minTop = Math.min(Math.max(4, sTop + basePadVPx / 2), Math.max(4, cH - capH - 4));
        int maxTop = Math.max(minTop, cH - Math.max(4, sBottom + basePadVPx / 2) - capH);
        int clampedLeft = Math.max(minLeft, Math.min(maxLeft, desiredLeftPx));
        int clampedTop = Math.max(minTop, Math.min(maxTop, desiredTopPx));

        int[] candidates = {
            ANCHOR_TOP_RIGHT,
            ANCHOR_TOP_LEFT,
            ANCHOR_TOP_CENTER,
            ANCHOR_BOTTOM_RIGHT,
            ANCHOR_BOTTOM_LEFT
        };
        int bestAnchor = ANCHOR_TOP_RIGHT;
        long bestDistSq = Long.MAX_VALUE;
        int bestBaseLeft = 0;
        int bestBaseTop = 0;
        for (int cand : candidates) {
            CornerPlacement base =
                    computeCornerPlacement(
                            cW,
                            cH,
                            capW,
                            capH,
                            sLeft,
                            sTop,
                            sRight,
                            sBottom,
                            cand,
                            0,
                            0,
                            basePadHPx,
                            basePadVPx);
            long dx = (long) clampedLeft - base.leftPx;
            long dy = (long) clampedTop - base.topPx;
            long distSq = dx * dx + dy * dy;
            if (distSq < bestDistSq) {
                bestDistSq = distSq;
                bestAnchor = cand;
                bestBaseLeft = base.leftPx;
                bestBaseTop = base.topPx;
            }
        }
        int offXDp = clampOffsetXDp(Math.round((clampedLeft - bestBaseLeft) / d));
        int offYDp = clampOffsetYDp(Math.round((clampedTop - bestBaseTop) / d));
        return new int[] {bestAnchor, offXDp, offYDp};
    }

    /**
     * Pure-JVM formatter for real corner status telemetry (real net speed, real resolution, real
     * battery percentage, real clock). Never emits synthetic frame-rate labels or emoji icons.
     */
    static String formatCornerStatusLine(
            int cornerMask,
            String netSpeed,
            String resolution,
            int batteryPercent,
            String clockText) {
        StringBuilder sb = new StringBuilder();
        if ((cornerMask & Prefs.HUD_NET_SPEED) != 0
                && netSpeed != null
                && !netSpeed.trim().isEmpty()) {
            appendPart(sb, netSpeed.trim());
        }
        if ((cornerMask & Prefs.HUD_RESOLUTION) != 0
                && resolution != null
                && !resolution.trim().isEmpty()
                && !resolution.contains("未知")) {
            appendPart(sb, resolution.trim());
        }
        if ((cornerMask & Prefs.HUD_BATTERY) != 0 && batteryPercent >= 0) {
            appendPart(sb, Math.min(100, batteryPercent) + "%");
        }
        if ((cornerMask & Prefs.HUD_CLOCK) != 0
                && clockText != null
                && !clockText.trim().isEmpty()) {
            appendPart(sb, clockText.trim());
        }
        return sb.toString();
    }

    static String formatNetSpeed(long bytesPerSec) {
        long safe = Math.max(0L, bytesPerSec);
        if (safe >= 1024L * 1024L) {
            return String.format(Locale.US, "%.1f MB/s", safe / (1024f * 1024f));
        }
        return (safe / 1024L) + " KB/s";
    }

    MobilePlayerOverlay(MainActivity activity, Cms.Site site, Cms.Video video, Cms.Episode ep) {
        this.a = activity;

        // 1. Optional letterbox ambient glow behind VideoOutput
        if (a.mobilePrefs().getBoolean(Prefs.LETTERBOX_BLUR, false) && a.playbackLayer != null) {
            final int tint = SeasonParser.defaultAmbientForTitle(video == null ? "" : video.title);
            letterboxGlow =
                    new View(a) {
                        private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);

                        @Override
                        protected void onDraw(Canvas c) {
                            int w = getWidth(), h = getHeight();
                            if (w <= 0 || h <= 0) return;
                            int glow = (tint & 0x00ffffff) | 0x66000000;
                            p.setShader(
                                    new RadialGradient(
                                            w * 0.5f,
                                            h * 0.5f,
                                            Math.max(w, h) * 0.65f,
                                            new int[] {glow, 0xff050608},
                                            null,
                                            Shader.TileMode.CLAMP));
                            c.drawRect(0, 0, w, h, p);
                        }
                    };
            a.playbackLayer.addView(letterboxGlow, 0, new FrameLayout.LayoutParams(-1, -1));
        }

        // 2. Idle Top-Right Status Micro-Capsule (zero overlap with expanded Top Bar)
        hudCapsule = a.row();
        hudCapsule.setTag("mobile-corner-hud");
        hudCapsule.setGravity(Gravity.CENTER_VERTICAL);
        hudCapsule.setClickable(false);
        hudCapsule.setFocusable(false);
        hudCapsule.setPadding(a.dp(9), a.dp(3.5f), a.dp(9), a.dp(3.5f));
        GradientDrawable capsuleBg = a.bg(a.isReducedTransparency() ? 0xE6141720 : 0x8F10131A, 999);
        capsuleBg.setStroke(MobileTheme.hairlinePx(a), 0x24FFFFFF);
        hudCapsule.setBackground(capsuleBg);

        hudPrefixText = makeTelemetryText(10.5f, 0xD8F3F5F9, false);
        hudCapsule.addView(hudPrefixText, new LinearLayout.LayoutParams(-2, -2));

        hudBatterySep = makeSeparatorDot();
        hudCapsule.addView(hudBatterySep, new LinearLayout.LayoutParams(-2, -2));

        hudBatteryIcon = MobileIcons.create(a, MobileIcons.IC_BATTERY, 14f, 0xE6FFFFFF);
        hudBatteryIcon.setStrokeWidthUnits(1.7f);
        LinearLayout.LayoutParams batIconLp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
        batIconLp.rightMargin = a.dp(3);
        hudCapsule.addView(hudBatteryIcon, batIconLp);

        hudBatteryText = makeTelemetryText(10.5f, 0xEBF3F5F9, false);
        hudCapsule.addView(hudBatteryText, new LinearLayout.LayoutParams(-2, -2));

        hudClockSep = makeSeparatorDot();
        hudCapsule.addView(hudClockSep, new LinearLayout.LayoutParams(-2, -2));

        hudClockText = makeTelemetryText(10.5f, 0xFFF3F5F9, true);
        hudCapsule.addView(hudClockText, new LinearLayout.LayoutParams(-2, -2));

        hudCapsule.setVisibility(View.GONE);
        FrameLayout.LayoutParams hudLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.LEFT);
        hudLp.setMargins(0, a.dp(10), 0, 0);
        if (a.playbackLayer != null) {
            a.playbackLayer.addView(hudCapsule, hudLp);
            a.playbackLayer.addOnLayoutChangeListener(containerLayoutListener);
        }
        hudCapsule.addOnLayoutChangeListener(capsuleLayoutListener);

        // 3. Bottom 2dp Accent Mini Progress Bar (visible when controls hide)
        miniBar = new MiniProgressView(a);
        miniBar.setTag("mobile-mini-progress");
        miniBar.setVisibility(View.GONE);
        FrameLayout.LayoutParams miniLp =
                new FrameLayout.LayoutParams(-1, a.dp(2f), Gravity.BOTTOM);
        if (a.playbackLayer != null) {
            a.playbackLayer.addView(miniBar, miniLp);
        }

        // 4. Community Intro / Credits Skip via TMDB + TheIntroDB v4 (independent of mini-bar)
        int manualIntro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_INTRO, 0));
        int manualOutro = Prefs.clampSkipSeconds(a.prefs.getInt(Prefs.SKIP_OUTRO, 0));
        final long epTok = ++episodeToken;
        // Fullscreen PlaybackControls already handles manual SKIP_INTRO / SKIP_OUTRO; pass
        // positive sentinel values only when manual skip is configured so community intro/credits
        // never override manual settings, while applying community segments when manual is 0.
        skipEvaluator.resetForEpisode(
                epTok,
                manualIntro > 0 ? Integer.MAX_VALUE / 2000 : 0,
                manualOutro > 0 ? Integer.MAX_VALUE / 2000 : 0);

        String siteKey = site == null || site.key == null ? "" : site.key;
        boolean offlineOrLive = "live".equals(siteKey) || "download".equals(siteKey);
        if (!offlineOrLive
                && video != null
                && ep != null
                && (manualIntro <= 0 || manualOutro <= 0)
                && a.mobilePrefs().getBoolean(Prefs.THEINTRODB_AUTO_SKIP, true)) {
            int handedTmdbId = ep.media != null ? ep.media.optInt("_tmdbId", 0) : 0;
            if (handedTmdbId > 0) {
                boolean handedIsTv = ep.media.optBoolean("_isTv", true);
                int handedSeason = Math.max(1, ep.media.optInt("_seasonNum", 1));
                int handedEp = Math.max(1, ep.media.optInt("_epNum", 1));
                TmdbService.lookupIntroDbAsync(
                        a,
                        handedTmdbId,
                        handedIsTv,
                        handedSeason,
                        handedEp,
                        ts -> {
                            if (ts != null && !closed) {
                                skipEvaluator.applyCommunityTimestamps(epTok, ts);
                            }
                        });
            } else if (TmdbService.isConfigured(a)) {
                final SeasonParser.SeasonMeta sm = SeasonParser.parseSeasonMeta(video.title);
                final EpisodeNameCleaner.CleanedEpisode ce =
                        EpisodeNameCleaner.clean(ep.name, video.title, 1);
                TmdbService.enrichDetailAsync(
                        a,
                        video.title,
                        sm.seasonNumber,
                        meta -> {
                            if (meta == null || closed) return;
                            TmdbService.lookupIntroDbAsync(
                                    a,
                                    meta.tmdbId,
                                    meta.isTv,
                                    sm.seasonNumber,
                                    ce.episodeNumber,
                                    ts -> {
                                        if (ts != null && !closed) {
                                            skipEvaluator.applyCommunityTimestamps(epTok, ts);
                                        }
                                    });
                        });
            }
        }

        a.ui.post(pulse);
    }

    private TextView makeTelemetryText(float sizeSp, int color, boolean medium) {
        TextView tv = a.text("", sizeSp, color);
        tv.setSingleLine(true);
        tv.setIncludeFontPadding(false);
        tv.setFontFeatureSettings("tnum");
        if (medium) {
            tv.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        }
        return tv;
    }

    private TextView makeSeparatorDot() {
        TextView dot = a.text("·", 10.5f, 0x66FFFFFF);
        dot.setSingleLine(true);
        dot.setIncludeFontPadding(false);
        dot.setPadding(a.dp(4), 0, a.dp(4), 0);
        return dot;
    }

    private void setIdleCapsuleVisible(boolean show) {
        if (hudCapsuleShown == show
                && hudCapsule.getVisibility() == (show ? View.VISIBLE : View.GONE)) {
            return;
        }
        hudCapsuleShown = show;
        if (UiCompat.isAttached(hudCapsule)) {
            MobileMotion.crossfadeVisibility(
                    hudCapsule, show, -4f, 0.96f, MotionTokens.DURATION_FAST_MS, true);
        } else {
            hudCapsule.animate().cancel();
            hudCapsule.setAlpha(1f);
            hudCapsule.setTranslationY(0f);
            hudCapsule.setScaleX(1f);
            hudCapsule.setScaleY(1f);
            hudCapsule.setVisibility(show ? View.VISIBLE : View.GONE);
        }
    }

    private void setMiniBarVisible(boolean show) {
        if (miniBarShown == show && miniBar.getVisibility() == (show ? View.VISIBLE : View.GONE)) {
            return;
        }
        miniBarShown = show;
        if (UiCompat.isAttached(miniBar)) {
            MobileMotion.crossfadeVisibility(
                    miniBar, show, 0f, 1f, MotionTokens.DURATION_FAST_MS, true);
        } else {
            miniBar.animate().cancel();
            miniBar.setAlpha(1f);
            miniBar.setVisibility(show ? View.VISIBLE : View.GONE);
        }
    }

    private boolean isSlimBarEnabled() {
        return com.pilipala.marcomovie.hud.PlayerHudPrefs.isUnifiedSlimProgressEnabled(
                a, a.mobilePrefs());
    }

    /** Immediately synchronizes idle capsule and mini progress bar when HUD visibility toggles. */
    void syncControlsVisibility() {
        if (closed || a.isFinishing()) return;
        int mask = a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD, 7);
        int bat = queryBatteryPercent();
        boolean charging = isBatteryCharging();
        String nowClock = clockFmt.format(new Date());
        if (a.playerChrome != null) {
            a.playerChrome.updateMobileTopStatus(nowClock, bat, charging, lastSampledNetSpeed);
        }
        renderIdleCornerCapsule(mask, lastSampledNetSpeed, bat, charging, nowClock);
        if (a.controlsVisible || a.miniMode) {
            setMiniBarVisible(false);
        } else if (!a.isLive() && a.prepared && a.player != null && isSlimBarEnabled()) {
            int dur = a.player.getDuration();
            if (dur > 0) {
                miniBar.setAccentColor(MobileTheme.of(a).accent);
                miniBar.setFraction(a.player.getCurrentPosition() / (float) dur);
                setMiniBarVisible(true);
            } else {
                setMiniBarVisible(false);
            }
        } else {
            setMiniBarVisible(false);
        }
    }

    void applyPositionPrefsNow() {
        if (closed || a.isFinishing()) return;
        updateCapsuleSafeMargins();
        syncControlsVisibility();
        if (a.playerChrome != null) {
            a.playerChrome.updateMobileTopStatus(
                    clockFmt.format(new Date()),
                    queryBatteryPercent(),
                    isBatteryCharging(),
                    lastSampledNetSpeed);
        }
    }

    void startPositionDragMode() {
        if (closed || a.isFinishing() || a.playbackLayer == null) return;
        stopPositionDragMode(false);
        adjustingPosition = true;
        if (a.controlsVisible) {
            a.showControls(false);
        }

        final float density = Math.max(1f, a.getResources().getDisplayMetrics().density);
        final int accent = MobileTheme.of(a).accent;

        // Highlight capsule while dragging
        GradientDrawable dragBg = a.bg(0xE0141822, 999);
        dragBg.setStroke(Math.max(2, a.dp(1.5f)), accent);
        hudCapsule.setBackground(dragBg);
        UiCompat.setElevation(hudCapsule, a.dp(12));

        dragOverlayLayer = new FrameLayout(a);
        dragOverlayLayer.setTag("mobile-corner-hud-drag-layer");
        dragOverlayLayer.setBackgroundColor(0x33000000);
        dragOverlayLayer.setClickable(true);
        dragOverlayLayer.setFocusable(false);

        dragBanner = a.row();
        dragBanner.setGravity(Gravity.CENTER_VERTICAL);
        dragBanner.setPadding(a.dp(14), a.dp(10), a.dp(10), a.dp(10));
        GradientDrawable bannerBg = a.bg(0xEB151821, 999);
        bannerBg.setStroke(MobileTheme.hairlinePx(a), 0x38FFFFFF);
        dragBanner.setBackground(bannerBg);
        UiCompat.setElevation(dragBanner, a.dp(10));

        dragCoordHint = a.text("拖动上方状态胶囊调整位置", 12.5f, 0xFFF3F5F9);
        dragCoordHint.setSingleLine(true);
        dragBanner.addView(dragCoordHint, new LinearLayout.LayoutParams(-2, -2));

        TextView resetBtn = a.text("恢复默认", 12f, 0xFFD1D5DB);
        resetBtn.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
        resetBtn.setBackground(a.bg(0x24FFFFFF, 999));
        MobileMotion.bindPress(resetBtn, 0.94f);
        resetBtn.setOnClickListener(
                v -> {
                    a.mobilePrefs()
                            .edit()
                            .putInt(Prefs.PLAYER_CORNER_HUD_ANCHOR, ANCHOR_TOP_RIGHT)
                            .putInt(Prefs.PLAYER_CORNER_HUD_OFFSET_X, 0)
                            .putInt(Prefs.PLAYER_CORNER_HUD_OFFSET_Y, 0)
                            .apply();
                    applyPositionPrefsNow();
                    updateDragBannerHint();
                });
        LinearLayout.LayoutParams rstLp = new LinearLayout.LayoutParams(-2, -2);
        rstLp.leftMargin = a.dp(10);
        dragBanner.addView(resetBtn, rstLp);

        TextView doneBtn = a.text("完成", 12.5f, MobileTheme.of(a).accentOnFill);
        doneBtn.setTypeface(null, Typeface.BOLD);
        doneBtn.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
        doneBtn.setBackground(a.bg(accent, 999));
        MobileMotion.bindPress(doneBtn, 0.94f);
        doneBtn.setOnClickListener(v -> stopPositionDragMode(true));
        LinearLayout.LayoutParams doneLp = new LinearLayout.LayoutParams(-2, -2);
        doneLp.leftMargin = a.dp(8);
        dragBanner.addView(doneBtn, doneLp);

        FrameLayout.LayoutParams bannerLp =
                new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        bannerLp.bottomMargin = a.dp(24);
        dragOverlayLayer.addView(dragBanner, bannerLp);

        dragOverlayLayer.setOnClickListener(v -> stopPositionDragMode(true));

        final float[] touchStart = new float[2];
        final int[] startCapsulePos = new int[2];
        hudCapsule.setClickable(true);
        hudCapsule.setOnTouchListener(
                (v, ev) -> {
                    if (!adjustingPosition) return false;
                    int action = ev.getActionMasked();
                    if (action == MotionEvent.ACTION_DOWN) {
                        touchStart[0] = ev.getRawX();
                        touchStart[1] = ev.getRawY();
                        startCapsulePos[0] = hudCapsule.getLeft();
                        startCapsulePos[1] = hudCapsule.getTop();
                        return true;
                    } else if (action == MotionEvent.ACTION_MOVE
                            || action == MotionEvent.ACTION_UP
                            || action == MotionEvent.ACTION_CANCEL) {
                        int desiredLeft =
                                startCapsulePos[0] + Math.round(ev.getRawX() - touchStart[0]);
                        int desiredTop =
                                startCapsulePos[1] + Math.round(ev.getRawY() - touchStart[1]);
                        int safeLeft = 0;
                        int safeTop = 0;
                        int safeRight = 0;
                        int safeBottom = 0;
                        if (a.playerChrome != null && a.playerChrome.overlay != null) {
                            safeLeft =
                                    Math.max(
                                            a.playerChrome.overlay.getPaddingLeft(),
                                            a.isPortrait()
                                                    ? a.playerChrome.windowInsets.left
                                                    : Math.min(
                                                            a.dp(24),
                                                            a.playerChrome.windowInsets.left));
                            safeTop =
                                    Math.max(
                                            a.playerChrome.overlay.getPaddingTop(),
                                            a.playerChrome.windowInsets.top);
                            safeRight =
                                    Math.max(
                                            a.playerChrome.overlay.getPaddingRight(),
                                            a.isPortrait()
                                                    ? a.playerChrome.windowInsets.right
                                                    : Math.min(
                                                            a.dp(24),
                                                            a.playerChrome.windowInsets.right));
                            safeBottom =
                                    Math.max(
                                            a.playerChrome.overlay.getPaddingBottom(),
                                            a.playerChrome.windowInsets.bottom);
                        }
                        int containerW = a.playbackLayer != null ? a.playbackLayer.getWidth() : 0;
                        int containerH = a.playbackLayer != null ? a.playbackLayer.getHeight() : 0;
                        int capW = Math.max(a.dp(48), hudCapsule.getWidth());
                        int capH = Math.max(a.dp(20), hudCapsule.getHeight());
                        int[] snapped =
                                resolveDraggedAnchorAndOffsets(
                                        containerW,
                                        containerH,
                                        capW,
                                        capH,
                                        safeLeft,
                                        safeTop,
                                        safeRight,
                                        safeBottom,
                                        desiredLeft,
                                        desiredTop,
                                        a.dp(12),
                                        a.dp(10),
                                        density);
                        a.mobilePrefs()
                                .edit()
                                .putInt(Prefs.PLAYER_CORNER_HUD_ANCHOR, snapped[0])
                                .putInt(Prefs.PLAYER_CORNER_HUD_OFFSET_X, snapped[1])
                                .putInt(Prefs.PLAYER_CORNER_HUD_OFFSET_Y, snapped[2])
                                .apply();
                        applyPositionPrefsNow();
                        updateDragBannerHint();
                        return true;
                    }
                    return false;
                });

        int capsuleIdx = a.playbackLayer.indexOfChild(hudCapsule);
        if (capsuleIdx >= 0) {
            a.playbackLayer.addView(
                    dragOverlayLayer, capsuleIdx, new FrameLayout.LayoutParams(-1, -1));
        } else {
            a.playbackLayer.addView(dragOverlayLayer, new FrameLayout.LayoutParams(-1, -1));
        }
        hudCapsule.bringToFront();
        syncControlsVisibility();
        updateCapsuleSafeMargins();
        updateDragBannerHint();
    }

    private void updateDragBannerHint() {
        if (dragCoordHint == null) return;
        int anchor = clampAnchor(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_ANCHOR, 0));
        int offX = clampOffsetXDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_X, 0));
        int offY = clampOffsetYDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_Y, 0));
        dragCoordHint.setText(describeCornerPosition(anchor, offX, offY));
    }

    private void stopPositionDragMode(boolean showToast) {
        if (!adjustingPosition && dragOverlayLayer == null) return;
        adjustingPosition = false;
        hudCapsule.setOnTouchListener(null);
        hudCapsule.setClickable(false);
        GradientDrawable capsuleBg = a.bg(a.isReducedTransparency() ? 0xE6141720 : 0x8F10131A, 999);
        capsuleBg.setStroke(MobileTheme.hairlinePx(a), 0x24FFFFFF);
        hudCapsule.setBackground(capsuleBg);
        UiCompat.setElevation(hudCapsule, 0f);
        removeParent(dragOverlayLayer);
        dragOverlayLayer = null;
        dragBanner = null;
        dragCoordHint = null;
        syncControlsVisibility();
        if (showToast) {
            int anchor = clampAnchor(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_ANCHOR, 0));
            int offX = clampOffsetXDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_X, 0));
            int offY = clampOffsetYDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_Y, 0));
            a.toast("状态栏位置已保存：" + describeCornerPosition(anchor, offX, offY));
        }
    }

    private void renderIdleCornerCapsule(
            int mask, String netSpeed, int bat, boolean charging, String nowClock) {
        int anchor = clampAnchor(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_ANCHOR, 0));
        int offX = clampOffsetXDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_X, 0));
        int offY = clampOffsetYDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_Y, 0));
        boolean customPos = hasCustomCornerHudPosition(anchor, offX, offY);
        if (a.miniMode
                || !shouldShowCornerHud(
                        a.controlsVisible, mask, a.playerLocked, customPos, adjustingPosition)) {
            setIdleCapsuleVisible(false);
            return;
        }
        updateCapsuleSafeMargins();

        String res =
                (mask & Prefs.HUD_RESOLUTION) != 0 && a.player != null && a.prepared
                        ? a.player.videoResolution()
                        : "";
        String prefixLine =
                formatCornerStatusLine(
                        mask & (Prefs.HUD_NET_SPEED | Prefs.HUD_RESOLUTION), netSpeed, res, -1, "");
        boolean showPrefix = !prefixLine.isEmpty();
        boolean showBattery = (mask & Prefs.HUD_BATTERY) != 0 && bat >= 0;
        boolean showClock = (mask & Prefs.HUD_CLOCK) != 0 && !nowClock.isEmpty();

        if (!showPrefix && !showBattery && !showClock) {
            if (!adjustingPosition) {
                setIdleCapsuleVisible(false);
                return;
            }
            showClock = true;
            nowClock = clockFmt.format(new Date());
        }

        hudPrefixText.setVisibility(showPrefix ? View.VISIBLE : View.GONE);
        if (showPrefix) hudPrefixText.setText(prefixLine);

        hudBatterySep.setVisibility(showPrefix && showBattery ? View.VISIBLE : View.GONE);
        hudBatteryIcon.setVisibility(showBattery ? View.VISIBLE : View.GONE);
        hudBatteryText.setVisibility(showBattery ? View.VISIBLE : View.GONE);
        if (showBattery) {
            int clampedBat = Math.min(100, bat);
            hudBatteryIcon.setLevel(clampedBat, charging);
            hudBatteryText.setText(clampedBat + "%");
        }

        hudClockSep.setVisibility(
                (showPrefix || showBattery) && showClock ? View.VISIBLE : View.GONE);
        hudClockText.setVisibility(showClock ? View.VISIBLE : View.GONE);
        if (showClock) hudClockText.setText(nowClock);

        setIdleCapsuleVisible(true);
    }

    private void updateCapsuleSafeMargins() {
        if (!(hudCapsule.getLayoutParams() instanceof FrameLayout.LayoutParams)) return;
        int safeLeft = 0;
        int safeTop = 0;
        int safeRight = 0;
        int safeBottom = 0;
        if (a.playerChrome != null && a.playerChrome.overlay != null) {
            safeLeft =
                    Math.max(
                            a.playerChrome.overlay.getPaddingLeft(),
                            a.isPortrait()
                                    ? a.playerChrome.windowInsets.left
                                    : Math.min(a.dp(24), a.playerChrome.windowInsets.left));
            safeTop =
                    Math.max(
                            a.playerChrome.overlay.getPaddingTop(),
                            a.playerChrome.windowInsets.top);
            safeRight =
                    Math.max(
                            a.playerChrome.overlay.getPaddingRight(),
                            a.isPortrait()
                                    ? a.playerChrome.windowInsets.right
                                    : Math.min(a.dp(24), a.playerChrome.windowInsets.right));
            safeBottom =
                    Math.max(
                            a.playerChrome.overlay.getPaddingBottom(),
                            a.playerChrome.windowInsets.bottom);
        }

        int anchor = clampAnchor(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_ANCHOR, 0));
        int offXDp = clampOffsetXDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_X, 0));
        int offYDp = clampOffsetYDp(a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD_OFFSET_Y, 0));
        int offXPx = a.dp(offXDp);
        int offYPx = a.dp(offYDp);
        int basePadHPx = a.dp(12);
        int basePadVPx = a.dp(10);

        int containerW = a.playbackLayer != null ? a.playbackLayer.getWidth() : 0;
        int containerH = a.playbackLayer != null ? a.playbackLayer.getHeight() : 0;
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) hudCapsule.getLayoutParams();
        if (containerW <= 0 || containerH <= 0) {
            int fallbackGravity = Gravity.TOP | Gravity.RIGHT;
            if (anchor == ANCHOR_TOP_LEFT) fallbackGravity = Gravity.TOP | Gravity.LEFT;
            else if (anchor == ANCHOR_TOP_CENTER)
                fallbackGravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
            else if (anchor == ANCHOR_BOTTOM_RIGHT)
                fallbackGravity = Gravity.BOTTOM | Gravity.RIGHT;
            else if (anchor == ANCHOR_BOTTOM_LEFT) fallbackGravity = Gravity.BOTTOM | Gravity.LEFT;
            lp.gravity = fallbackGravity;
            lp.setMargins(
                    Math.max(0, safeLeft + basePadHPx),
                    Math.max(a.dp(10), safeTop + basePadVPx),
                    Math.max(a.dp(14), safeRight + basePadHPx),
                    Math.max(a.dp(10), safeBottom + basePadVPx));
            hudCapsule.setLayoutParams(lp);
            return;
        }

        int capW = hudCapsule.getWidth();
        int capH = hudCapsule.getHeight();
        if (capW <= 0 || capH <= 0) {
            hudCapsule.measure(
                    View.MeasureSpec.makeMeasureSpec(containerW, View.MeasureSpec.AT_MOST),
                    View.MeasureSpec.makeMeasureSpec(containerH, View.MeasureSpec.AT_MOST));
            capW = Math.max(a.dp(48), hudCapsule.getMeasuredWidth());
            capH = Math.max(a.dp(20), hudCapsule.getMeasuredHeight());
        }

        CornerPlacement p =
                computeCornerPlacement(
                        containerW,
                        containerH,
                        capW,
                        capH,
                        safeLeft,
                        safeTop,
                        safeRight,
                        safeBottom,
                        anchor,
                        offXPx,
                        offYPx,
                        basePadHPx,
                        basePadVPx);
        if (lp.gravity != (Gravity.TOP | Gravity.LEFT)
                || lp.leftMargin != p.leftPx
                || lp.topMargin != p.topPx
                || lp.rightMargin != 0
                || lp.bottomMargin != 0) {
            lp.gravity = Gravity.TOP | Gravity.LEFT;
            lp.setMargins(p.leftPx, p.topPx, 0, 0);
            hudCapsule.setLayoutParams(lp);
        }
    }

    private void updateHudAndMiniBar() {
        int mask = a.mobilePrefs().getInt(Prefs.PLAYER_CORNER_HUD, 7);
        String sampledSpeed = sampleNetSpeed();
        if (!sampledSpeed.isEmpty()) {
            lastSampledNetSpeed = sampledSpeed;
        }
        int bat = queryBatteryPercent();
        boolean charging = isBatteryCharging();
        String nowClock = clockFmt.format(new Date());

        if (a.playerChrome != null) {
            a.playerChrome.updateMobileTopStatus(nowClock, bat, charging, sampledSpeed);
        }
        renderIdleCornerCapsule(mask, sampledSpeed, bat, charging, nowClock);

        int dur = 0;
        int pos = 0;
        if (!a.isLive() && a.prepared && a.player != null) {
            dur = a.player.getDuration();
            pos = a.player.getCurrentPosition();
            // Community intro/credits skip runs regardless of MINI_PROGRESS_BAR visibility.
            boolean hasNext =
                    a.activeLine != null
                            && a.activeEpisode != null
                            && a.activeLine.episodes != null
                            && a.activeLine.episodes.indexOf(a.activeEpisode) >= 0
                            && a.activeLine.episodes.indexOf(a.activeEpisode) + 1
                                    < a.activeLine.episodes.size();
            boolean autoNext = a.prefs.getBoolean(Prefs.AUTO_NEXT, true);
            IntroSkipEvaluator.Decision decision =
                    skipEvaluator.evaluate(pos, dur, hasNext, autoNext);
            if (decision.action == IntroSkipEvaluator.ACTION_SEEK && decision.targetMs >= 0L) {
                a.player.seekTo((int) decision.targetMs);
                if (!decision.toastMessage.isEmpty()) a.toast(decision.toastMessage);
            } else if (decision.action == IntroSkipEvaluator.ACTION_NEXT_EPISODE
                    && a.playbackControls != null) {
                if (!decision.toastMessage.isEmpty()) a.toast(decision.toastMessage);
                a.playbackControls.step(1);
                return;
            }
        }

        boolean showMini =
                !a.controlsVisible
                        && !a.miniMode
                        && !a.isLive()
                        && a.prepared
                        && a.player != null
                        && isSlimBarEnabled();
        if (showMini && dur > 0) {
            miniBar.setAccentColor(MobileTheme.of(a).accent);
            miniBar.setFraction(pos / (float) dur);
            setMiniBarVisible(true);
        } else {
            setMiniBarVisible(false);
        }
    }

    private static void appendPart(StringBuilder sb, String item) {
        if (sb.length() > 0) sb.append(" · ");
        sb.append(item);
    }

    private String sampleNetSpeed() {
        long now = SystemClock.elapsedRealtime();
        long rx = TrafficStats.getUidRxBytes(android.os.Process.myUid());
        if (rx == TrafficStats.UNSUPPORTED) rx = TrafficStats.getTotalRxBytes();
        if (rx <= 0) return "";
        String out = "";
        if (lastRxBytes > 0 && now > lastRxTimeMs) {
            long bytesPerSec = ((rx - lastRxBytes) * 1000L) / Math.max(1L, now - lastRxTimeMs);
            out = formatNetSpeed(bytesPerSec);
        }
        lastRxBytes = rx;
        lastRxTimeMs = now;
        return out;
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
        closed = true;
        stopPositionDragMode(false);
        a.ui.removeCallbacks(pulse);
        if (a.playbackLayer != null) {
            a.playbackLayer.removeOnLayoutChangeListener(containerLayoutListener);
        }
        hudCapsule.removeOnLayoutChangeListener(capsuleLayoutListener);
        removeParent(hudCapsule);
        removeParent(miniBar);
        removeParent(letterboxGlow);
    }

    private static void removeParent(View v) {
        if (v != null && v.getParent() instanceof ViewGroup) {
            ((ViewGroup) v.getParent()).removeView(v);
        }
    }

    private static final class MiniProgressView extends View {
        private final Paint bgPaint = new Paint();
        private final Paint fgPaint = new Paint();
        private float fraction = 0f;

        MiniProgressView(MainActivity a) {
            super(a);
            bgPaint.setColor(0x30ffffff);
            fgPaint.setColor(MobileTheme.of(a).accent);
        }

        void setAccentColor(int color) {
            if (fgPaint.getColor() != color) {
                fgPaint.setColor(color);
                invalidate();
            }
        }

        void setFraction(float f) {
            float c = Math.max(0f, Math.min(1f, f));
            if (Math.abs(c - fraction) > 0.002f) {
                fraction = c;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            canvas.drawRect(0, 0, w, h, bgPaint);
            canvas.drawRect(0, 0, w * fraction, h, fgPaint);
        }
    }
}

package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.widget.FrameLayout;
import android.widget.ImageView;
import java.lang.ref.WeakReference;
import java.util.ArrayDeque;

/**
 * Native Android 120fps dual-choreographed shared-element transition porting iOS {@code
 * PosterExpandRoute} and adding synchronized floating-Dock <-> Detail-lower-sheet morphing:
 *
 * <ul>
 *   <li><b>Enter</b>: Smooth critically-damped spring ({@link #ENTER_DURATION_SEC}s, zero
 *       overshoot) simultaneously expands the tapped poster card from its exact screen {@link
 *       RectF} into the full-bleed Detail Hero while morphing the bottom floating Dock upward into
 *       the rounded Detail episode/info sheet ({@code detail-lower-sheet}), hiding both source
 *       elements past {@code p > 0.035f} for zero duplicate ghosting.
 *   <li><b>Return (Back)</b>: Pressing Back from {@link MobileDetailScreen} simultaneously shrinks
 *       the Hero poster back into the originating poster card's live {@link RectF} AND collapses
 *       the Detail episode sheet downward back into the floating bottom Dock on the preserved
 *       previous screen (zero reload, exact scroll position preserved).
 *   <li><b>Reduced Motion</b>: Honors {@link MobileMotion#isReduced(android.content.Context)} with
 *       a calm {@code 150ms} opacity-only cross-fade.
 * </ul>
 */
final class MobilePosterTransition {
    static final float ENTER_DURATION_SEC = 0.40f;
    static final float EXIT_DURATION_SEC = 0.36f;
    static final float SOURCE_HIDE_THRESHOLD = 0.035f;

    private static final float ENTER_OMEGA = 8.4f;
    private static final float EXIT_OMEGA = 9.0f;
    private static final float ENTER_NORM =
            1f - (1f + ENTER_OMEGA) * (float) Math.exp(-ENTER_OMEGA);
    private static final float EXIT_NORM = 1f - (1f + EXIT_OMEGA) * (float) Math.exp(-EXIT_OMEGA);
    private static final int MAX_SAVED_DEPTH = 3;

    private static final ArrayDeque<SavedReturnEntry> RETURN_STACK = new ArrayDeque<>();
    private static ActiveRun activeRun;

    private MobilePosterTransition() {}

    /** Pure-JVM per-frame single-card morph geometry, opacity, and zero-ghosting state. */
    static final class MorphFrame {
        final float left;
        final float top;
        final float right;
        final float bottom;
        final float radiusPx;
        final float backdropDim;
        final float detailOpacity;
        final float edgeOpacity;
        final boolean hideSourceCard;

        MorphFrame(
                float left,
                float top,
                float right,
                float bottom,
                float radiusPx,
                float backdropDim,
                float detailOpacity,
                float edgeOpacity,
                boolean hideSourceCard) {
            this.left = left;
            this.top = top;
            this.right = right;
            this.bottom = bottom;
            this.radiusPx = radiusPx;
            this.backdropDim = backdropDim;
            this.detailOpacity = detailOpacity;
            this.edgeOpacity = edgeOpacity;
            this.hideSourceCard = hideSourceCard;
        }
    }

    /**
     * Pure-JVM per-frame dual-element choreography state:
     * <ul>
     *   <li>Upper poster card expanding/shrinking between source card and Detail Hero
     *   <li>Lower episode sheet morphing smoothly between floating bottom Dock and Detail sheet
     * </ul>
     */
    static final class DualMorphFrame {
        final float posterLeft;
        final float posterTop;
        final float posterRight;
        final float posterBottom;
        final float posterRadiusPx;
        final float heroChromeAlpha;

        final boolean hasSheetMorph;
        final float sheetLeft;
        final float sheetTop;
        final float sheetRight;
        final float sheetBottom;
        final float sheetTopRadiusPx;
        final float sheetBottomRadiusPx;
        final float sheetSurfaceBlend;
        final float sheetContentAlpha;
        final float dockHintAlpha;

        final float backdropDim;
        final float edgeOpacity;
        final boolean hideSourceCard;
        final boolean hideDock;
        final float progress;

        DualMorphFrame(
                float posterLeft,
                float posterTop,
                float posterRight,
                float posterBottom,
                float posterRadiusPx,
                float heroChromeAlpha,
                boolean hasSheetMorph,
                float sheetLeft,
                float sheetTop,
                float sheetRight,
                float sheetBottom,
                float sheetTopRadiusPx,
                float sheetBottomRadiusPx,
                float sheetSurfaceBlend,
                float sheetContentAlpha,
                float dockHintAlpha,
                float backdropDim,
                float edgeOpacity,
                boolean hideSourceCard,
                boolean hideDock,
                float progress) {
            this.posterLeft = posterLeft;
            this.posterTop = posterTop;
            this.posterRight = posterRight;
            this.posterBottom = posterBottom;
            this.posterRadiusPx = posterRadiusPx;
            this.heroChromeAlpha = heroChromeAlpha;
            this.hasSheetMorph = hasSheetMorph;
            this.sheetLeft = sheetLeft;
            this.sheetTop = sheetTop;
            this.sheetRight = sheetRight;
            this.sheetBottom = sheetBottom;
            this.sheetTopRadiusPx = sheetTopRadiusPx;
            this.sheetBottomRadiusPx = sheetBottomRadiusPx;
            this.sheetSurfaceBlend = sheetSurfaceBlend;
            this.sheetContentAlpha = sheetContentAlpha;
            this.dockHintAlpha = dockHintAlpha;
            this.backdropDim = backdropDim;
            this.edgeOpacity = edgeOpacity;
            this.hideSourceCard = hideSourceCard;
            this.hideDock = hideDock;
            this.progress = progress;
        }
    }

    private static float clamp01(float v) {
        if (Float.isNaN(v)) return 0f;
        return Math.max(0f, Math.min(1f, v));
    }

    private static float lerp(float a, float b, float t) {
        return a + (b - a) * t;
    }

    /**
     * Pure-JVM analytical critically-damped unit spring matching Apple {@code Spring.smooth}:
     * instant responsive launch, velvety deceleration, strictly monotonic, zero overshoot.
     */
    static float evaluateSpringProgress(float rawT, boolean reversing) {
        float t = clamp01(rawT);
        if (t <= 0f) return 0f;
        if (t >= 1f) return 1f;
        float omega = reversing ? EXIT_OMEGA : ENTER_OMEGA;
        float norm = reversing ? EXIT_NORM : ENTER_NORM;
        float val = 1f - (1f + omega * t) * (float) Math.exp(-omega * t);
        return clamp01(val / norm);
    }

    /**
     * Pure-JVM single-card morph frame evaluator (backward-compatible with unit tests and used as
     * fallback when no split sheet exists).
     */
    static MorphFrame computeMorphFrame(
            float srcL,
            float srcT,
            float srcR,
            float srcB,
            float fullW,
            float fullH,
            float srcRadiusPx,
            float springProgress,
            boolean isFullBleedHero,
            boolean hasPoster,
            boolean reversing) {
        float p = clamp01(springProgress);
        float l = lerp(srcL, 0f, p);
        float t = lerp(srcT, 0f, p);
        float r = lerp(srcR, fullW, p);
        float b = lerp(srcB, fullH, p);
        float rad = Math.max(0f, srcRadiusPx * (1f - p));
        float dim = 0.36f * p;
        float detailOp;
        if (!hasPoster) {
            detailOp = 1f;
        } else if (isFullBleedHero) {
            detailOp = clamp01((p - 0.12f) / 0.44f);
        } else {
            detailOp = clamp01((p - 0.06f) / 0.42f);
        }
        float edgeOp = (reversing && p < 0.04f) ? clamp01(p / 0.04f) : 1f;
        boolean hideSource = p > SOURCE_HIDE_THRESHOLD;
        return new MorphFrame(l, t, r, b, rad, dim, detailOp, edgeOp, hideSource);
    }

    /**
     * Pure-JVM dual-element choreographer computing both the expanding/shrinking Poster Hero AND
     * the synchronized floating-Dock <-> Detail-episode-sheet morph.
     */
    static DualMorphFrame computeDualMorphFrame(
            float srcL,
            float srcT,
            float srcR,
            float srcB,
            float srcRadiusPx,
            boolean hasDock,
            float dockL,
            float dockT,
            float dockR,
            float dockB,
            float dockRadiusPx,
            float fullW,
            float fullH,
            float sheetTargetTopY,
            float sheetTargetTopRadiusPx,
            float heroSheetOverlapPx,
            float springProgress,
            boolean isFullBleedHero,
            boolean hasPoster,
            boolean reversing) {
        float p = clamp01(springProgress);
        float targetHeroBottom =
                Math.min(fullH, Math.max(sheetTargetTopY + heroSheetOverlapPx, fullH * 0.50f));

        float pL = lerp(srcL, 0f, p);
        float pT = lerp(srcT, 0f, p);
        float pR = lerp(srcR, fullW, p);
        float pB = lerp(srcB, targetHeroBottom, p);
        float pRad = Math.max(0f, srcRadiusPx * (1f - p));
        float heroChrome =
                !hasPoster
                        ? 1f
                        : (isFullBleedHero
                                ? clamp01((p - 0.14f) / 0.44f)
                                : clamp01((p - 0.16f) / 0.46f));

        // Synchronized lower episode sheet: starts from floating Dock bounds (or bottom edge when
        // opening from a dockless screen like Curated Collection Wall) and expands upward cleanly.
        float sStartL = hasDock ? dockL : fullW * 0.06f;
        float sStartT = hasDock ? dockT : fullH;
        float sStartR = hasDock ? dockR : fullW * 0.94f;
        float sStartB = hasDock ? dockB : fullH + Math.max(48f, dockRadiusPx * 2f);
        float sStartTopR = hasDock ? dockRadiusPx : sheetTargetTopRadiusPx;
        float sStartBotR = hasDock ? dockRadiusPx : 0f;

        float sL = lerp(sStartL, 0f, p);
        float sT = lerp(sStartT, sheetTargetTopY, p);
        float sR = lerp(sStartR, fullW, p);
        float sB = lerp(sStartB, fullH, p);
        float sTopR = lerp(sStartTopR, sheetTargetTopRadiusPx, p);
        float sBotR = Math.max(0f, lerp(sStartBotR, 0f, p));
        float surfaceBlend = hasDock ? clamp01(p / 0.48f) : 1f;
        float contentAlpha = clamp01((p - 0.24f) / 0.46f);
        float dockHint = hasDock ? clamp01(1f - p / 0.28f) : 0f;

        float dim = 0.34f * p;
        float edgeOp = (reversing && p < 0.04f) ? clamp01(p / 0.04f) : 1f;
        boolean hideSrc = p > SOURCE_HIDE_THRESHOLD;
        boolean hideDock = hasDock && p > SOURCE_HIDE_THRESHOLD;

        return new DualMorphFrame(
                pL,
                pT,
                pR,
                pB,
                pRad,
                heroChrome,
                true,
                sL,
                sT,
                sR,
                sB,
                sTopR,
                sBotR,
                surfaceBlend,
                contentAlpha,
                dockHint,
                dim,
                edgeOp,
                hideSrc,
                hideDock,
                p);
    }

    /**
     * Pure-JVM smooth vertical crop anchor interpolation matching Home {@code CENTER_CROP} ({@code
     * 0.50f}) at {@code p = 0} and {@link MobileDetailScreen.PortraitBackdropView} ({@code 0.24f})
     * at {@code p = 1} so cover posters never jump vertically on click or return.
     */
    static float interpolatePosterCropAnchorY(float progress) {
        return lerp(0.50f, 0.24f, clamp01(progress));
    }

    private static final class SavedReturnEntry {
        final MainActivity.Screen prevScreen;
        final FrameLayout prevRoot;
        final MainActivity.Screen detailScreen;
        final WeakReference<View> sourceViewRef;
        final RectF initialRect;
        final float sourceRadiusPx;
        final WeakReference<View> dockViewRef;
        final RectF initialDockRect;
        final float dockRadiusPx;
        final boolean hasDock;
        final Bitmap posterBitmap;
        final boolean isFullBleedHero;
        final int ambientColor;
        final boolean portrait;
        final boolean dark;
        final int accent;
        final boolean prevForceLightStatusIcons;
        final String favSnapshotBefore;
        final int historyCountBefore;

        SavedReturnEntry(
                MainActivity.Screen prevScreen,
                FrameLayout prevRoot,
                MainActivity.Screen detailScreen,
                View sourceView,
                RectF initialRect,
                float sourceRadiusPx,
                View dockView,
                RectF initialDockRect,
                float dockRadiusPx,
                boolean hasDock,
                Bitmap posterBitmap,
                boolean isFullBleedHero,
                int ambientColor,
                boolean portrait,
                boolean dark,
                int accent,
                boolean prevForceLightStatusIcons,
                String favSnapshotBefore,
                int historyCountBefore) {
            this.prevScreen = prevScreen;
            this.prevRoot = prevRoot;
            this.detailScreen = detailScreen;
            this.sourceViewRef = new WeakReference<>(sourceView);
            this.initialRect = new RectF(initialRect);
            this.sourceRadiusPx = sourceRadiusPx;
            this.dockViewRef = new WeakReference<>(dockView);
            this.initialDockRect =
                    initialDockRect != null ? new RectF(initialDockRect) : new RectF();
            this.dockRadiusPx = dockRadiusPx;
            this.hasDock = hasDock;
            this.posterBitmap = posterBitmap;
            this.isFullBleedHero = isFullBleedHero;
            this.ambientColor = ambientColor;
            this.portrait = portrait;
            this.dark = dark;
            this.accent = accent;
            this.prevForceLightStatusIcons = prevForceLightStatusIcons;
            this.favSnapshotBefore = favSnapshotBefore == null ? "" : favSnapshotBefore;
            this.historyCountBefore = historyCountBefore;
        }

        boolean matchesContext(MainActivity a) {
            return a != null
                    && !a.isFinishing()
                    && a.isPortrait() == portrait
                    && MobileTheme.isDark(a) == dark
                    && a.mobileAccentColor() == accent;
        }
    }

    private static final class ActiveRun {
        final boolean reversing;
        MotionLoop.Step step;
        Runnable finishNow;

        ActiveRun(boolean reversing) {
            this.reversing = reversing;
        }
    }

    static boolean isRunning() {
        return activeRun != null;
    }

    static void cancelActive(MainActivity a) {
        ActiveRun run = activeRun;
        activeRun = null;
        if (run != null) {
            if (run.step != null) {
                MotionLoop.remove(run.step);
                run.step = null;
            }
            if (run.finishNow != null) {
                Runnable fn = run.finishNow;
                run.finishNow = null;
                fn.run();
            }
        }
    }

    static void clearSavedState(MainActivity a) {
        cancelActive(a);
        for (SavedReturnEntry e : RETURN_STACK) {
            restoreAlpha(e.sourceViewRef.get());
            restoreAlpha(e.dockViewRef.get());
        }
        RETURN_STACK.clear();
    }

    /**
     * Opens {@link MobileDetailScreen} with dual-element choreography: the tapped poster card
     * expands smoothly into the full-bleed Hero while the floating bottom Dock rises and unfolds
     * upward into the Detail episode sheet.
     */
    static void openDetailFromCard(
            final MainActivity a,
            final Cms.Site site,
            final Cms.Video video,
            final View sourcePosterView,
            final float sourceRadiusDp,
            final boolean isFullBleedHero) {
        if (a == null || video == null) return;
        if (a.redirectListing(site, video)) return;
        if (a.isTvDevice()) {
            a.open(new MainActivity.Screen(() -> a.detail(site, video)), true);
            return;
        }
        cancelActive(a);

        final MainActivity.Screen detailScreen =
                new MainActivity.Screen(() -> a.detail(site, video));

        final FrameLayout prevRoot = a.root;
        final MainActivity.Screen prevScreen = a.current;
        if (prevRoot == null
                || prevScreen == null
                || sourcePosterView == null
                || !UiCompat.isAttached(sourcePosterView)
                || sourcePosterView.getWidth() < 8
                || sourcePosterView.getHeight() < 8
                || prevRoot.getWidth() < 16
                || prevRoot.getHeight() < 16) {
            a.open(detailScreen, true);
            return;
        }

        final int fullW = prevRoot.getWidth();
        final int fullH = prevRoot.getHeight();
        resetPressScale(sourcePosterView);
        final RectF sourceRect = measureRelativeRect(prevRoot, sourcePosterView);
        if (sourceRect == null
                || sourceRect.width() < 8f
                || sourceRect.height() < 8f
                || sourceRect.right <= 0f
                || sourceRect.left >= fullW
                || sourceRect.bottom <= 0f
                || sourceRect.top >= fullH) {
            a.open(detailScreen, true);
            return;
        }

        if (MobileMotion.isReduced(a)) {
            a.open(detailScreen, true);
            if (a.root != null) {
                a.root.setAlpha(0f);
                a.root.animate()
                        .alpha(1f)
                        .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                        .setInterpolator(MotionTokens.createLinearInterpolator())
                        .start();
            }
            return;
        }

        // Capture live floating bottom Dock bounds (if present & visible on prevRoot)
        final View dockHost = prevRoot.findViewWithTag("mobile-bottom-dock");
        final RectF dockRect = measureVisibleDockBounds(prevRoot, dockHost);
        final boolean hasDock =
                dockRect != null && dockRect.width() > a.dp(60) && dockRect.height() > a.dp(24);
        final float dockRadiusPx =
                hasDock ? Math.min(a.dp(32), dockRect.height() * 0.5f) : a.dp(24);

        final Bitmap posterBitmap = extractPosterBitmap(a, sourcePosterView, video);
        final float sourceRadiusPx = Math.max(0f, a.dp(sourceRadiusDp));
        final int ambientColor = MobileDetailScreen.defaultAmbientForTitle(video.title);
        final boolean prevPortrait = a.isPortrait();
        final boolean prevDark = MobileTheme.isDark(a);
        final int prevAccent = a.mobileAccentColor();
        final boolean prevForceLight = a.lastMobileForceLightStatusIcons;
        final String favSnapshot = a.prefs != null ? a.prefs.getString(Prefs.FAVORITES, "[]") : "";
        final int histCount = a.watchHistory().size();

        // Standard MainActivity navigation bookkeeping + build real MobileDetailScreen into a.root
        // without flashing an extra intermediate setContentView pass.
        a.dismissOnboarding();
        a.cancelActiveTransition();
        a.capture();
        a.back.push(prevScreen);
        a.current = detailScreen;
        a.suppressTransitionContentView = true;
        try {
            a.detail(site, video);
        } finally {
            a.suppressTransitionContentView = false;
        }
        final FrameLayout detailRoot = a.root;
        if (detailRoot == null || detailRoot == prevRoot) {
            a.restore(detailScreen);
            return;
        }

        SavedReturnEntry entry =
                new SavedReturnEntry(
                        prevScreen,
                        prevRoot,
                        detailScreen,
                        sourcePosterView,
                        sourceRect,
                        sourceRadiusPx,
                        hasDock ? dockHost : null,
                        dockRect,
                        dockRadiusPx,
                        hasDock,
                        posterBitmap,
                        isFullBleedHero,
                        ambientColor,
                        prevPortrait,
                        prevDark,
                        prevAccent,
                        prevForceLight,
                        favSnapshot,
                        histCount);
        RETURN_STACK.push(entry);
        while (RETURN_STACK.size() > MAX_SAVED_DEPTH) {
            SavedReturnEntry evicted = RETURN_STACK.removeLast();
            restoreAlpha(evicted.sourceViewRef.get());
            restoreAlpha(evicted.dockViewRef.get());
        }

        final View lowerSheet = detailRoot.findViewWithTag("detail-lower-sheet");
        final float targetSheetTopY = computeDefaultDetailSheetTopY(a, fullH);
        final float sheetTopRadiusPx = a.dp(24);
        // Matches PortraitBackdropView.posterWindowH = foregroundHeroH + 44dp = (targetSheetTopY +
        // 16dp) + 44dp
        final float heroOverlapPx = a.dp(60);
        final MobileTheme.Palette palette = MobileTheme.of(a);

        // Assemble single-pass 120fps transition host: [prevRoot, DualMorphStageView(detailRoot)]
        detachFromParent(prevRoot);
        detachFromParent(detailRoot);
        if (lowerSheet != null) {
            lowerSheet.setAlpha(0f);
        }

        final FrameLayout transitionHost = new FrameLayout(a);
        transitionHost.setBackgroundColor(palette.bgCanvas);
        transitionHost.setClickable(true);
        transitionHost.setOnTouchListener((v, ev) -> true);
        transitionHost.addView(prevRoot, new FrameLayout.LayoutParams(-1, -1));

        final DualMorphStageView stage =
                new DualMorphStageView(
                        a,
                        detailRoot,
                        lowerSheet,
                        posterBitmap,
                        ambientColor,
                        palette.bgCanvas,
                        palette.isDark ? 0xEB181B24 : 0xF5FFFFFF,
                        palette.isDark ? 0x2EFFFFFF : 0x1A000000,
                        palette.accent,
                        isFullBleedHero);
        stage.update(
                computeDualMorphFrame(
                        sourceRect.left,
                        sourceRect.top,
                        sourceRect.right,
                        sourceRect.bottom,
                        sourceRadiusPx,
                        hasDock,
                        hasDock ? dockRect.left : 0f,
                        hasDock ? dockRect.top : fullH,
                        hasDock ? dockRect.right : fullW,
                        hasDock ? dockRect.bottom : fullH,
                        dockRadiusPx,
                        fullW,
                        fullH,
                        targetSheetTopY,
                        sheetTopRadiusPx,
                        heroOverlapPx,
                        0f,
                        isFullBleedHero,
                        posterBitmap != null,
                        false));
        transitionHost.addView(stage, new FrameLayout.LayoutParams(-1, -1));

        detailRoot.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        a.glassFreezeController.setGlassFrozen(true);
        a.setContentView(transitionHost);

        final ActiveRun run = new ActiveRun(false);
        final float[] elapsed = {0f};
        final boolean[] firstTick = {true};
        final boolean[] finished = {false};

        run.finishNow =
                () -> {
                    if (finished[0]) return;
                    finished[0] = true;
                    if (activeRun == run) activeRun = null;
                    if (run.step != null) {
                        MotionLoop.remove(run.step);
                        run.step = null;
                    }
                    restoreAlpha(sourcePosterView);
                    if (hasDock) restoreAlpha(dockHost);
                    if (lowerSheet != null) {
                        lowerSheet.setAlpha(1f);
                        lowerSheet.setVisibility(View.VISIBLE);
                    }
                    detailRoot.setAlpha(1f);
                    detailRoot.setLayerType(View.LAYER_TYPE_NONE, null);
                    a.glassFreezeController.setGlassFrozen(false);
                    detachFromParent(prevRoot);
                    detachFromParent(detailRoot);
                    if (a.current == detailScreen && !a.isFinishing()) {
                        a.root = detailRoot;
                        a.setContentView(detailRoot);
                        a.watchRootLayout(detailRoot);
                        a.restore(detailScreen);
                    }
                };

        run.step =
                dt -> {
                    if (finished[0] || !UiCompat.isAttached(transitionHost) || a.isFinishing()) {
                        run.finishNow.run();
                        return false;
                    }
                    if (firstTick[0]) {
                        firstTick[0] = false;
                    } else {
                        elapsed[0] += Math.min(0.032f, dt);
                    }
                    float rawT = clamp01(elapsed[0] / ENTER_DURATION_SEC);
                    float p = evaluateSpringProgress(rawT, false);
                    float curW = transitionHost.getWidth() > 0 ? transitionHost.getWidth() : fullW;
                    float curH =
                            transitionHost.getHeight() > 0 ? transitionHost.getHeight() : fullH;
                    DualMorphFrame frame =
                            computeDualMorphFrame(
                                    sourceRect.left,
                                    sourceRect.top,
                                    sourceRect.right,
                                    sourceRect.bottom,
                                    sourceRadiusPx,
                                    hasDock,
                                    hasDock ? dockRect.left : 0f,
                                    hasDock ? dockRect.top : curH,
                                    hasDock ? dockRect.right : curW,
                                    hasDock ? dockRect.bottom : curH,
                                    dockRadiusPx,
                                    curW,
                                    curH,
                                    targetSheetTopY,
                                    sheetTopRadiusPx,
                                    heroOverlapPx,
                                    p,
                                    isFullBleedHero,
                                    posterBitmap != null,
                                    false);
                    if (isFullBleedHero) {
                        sourcePosterView.setAlpha(1f - clamp01(p / 0.14f));
                    } else {
                        sourcePosterView.setAlpha(frame.hideSourceCard ? 0f : 1f);
                    }
                    if (hasDock && dockHost != null) {
                        dockHost.setAlpha(1f - clamp01(p / 0.14f));
                    }
                    stage.update(frame);
                    if (rawT >= 1f) {
                        run.finishNow.run();
                        return false;
                    }
                    return true;
                };

        activeRun = run;
        // Start MotionLoop strictly AFTER the first measure/layout pass of detailRoot so frame 0
        // never skips ahead or stair-steps while the view tree inflates.
        transitionHost
                .getViewTreeObserver()
                .addOnPreDrawListener(
                        new ViewTreeObserver.OnPreDrawListener() {
                            @Override
                            public boolean onPreDraw() {
                                transitionHost.getViewTreeObserver().removeOnPreDrawListener(this);
                                if (!finished[0] && activeRun == run && run.step != null) {
                                    MotionLoop.add(run.step);
                                }
                                return true;
                            }
                        });
    }

    /**
     * Animates Back from {@link MobileDetailScreen}: shrinks the Hero poster smoothly back into the
     * originating poster card while collapsing the Detail episode sheet downward back into the
     * floating bottom Dock.
     */
    static boolean tryAnimatedBack(final MainActivity a) {
        if (a == null || a.isTvDevice() || a.current == null || a.back.isEmpty()) return false;

        if (activeRun != null && activeRun.reversing) {
            cancelActive(a);
            return true;
        }
        if (activeRun != null) {
            cancelActive(a);
        }

        SavedReturnEntry matched = null;
        while (!RETURN_STACK.isEmpty()) {
            SavedReturnEntry peek = RETURN_STACK.peek();
            if (peek.detailScreen == a.current && a.back.peek() == peek.prevScreen) {
                matched = RETURN_STACK.pop();
                break;
            }
            if (peek.detailScreen != a.current && !a.back.contains(peek.detailScreen)) {
                SavedReturnEntry dropped = RETURN_STACK.pop();
                restoreAlpha(dropped.sourceViewRef.get());
                restoreAlpha(dropped.dockViewRef.get());
                continue;
            }
            break;
        }
        if (matched == null) return false;

        final SavedReturnEntry entry = matched;
        final FrameLayout detailRoot = a.root;
        final FrameLayout prevRoot = entry.prevRoot;
        if (detailRoot == null
                || prevRoot == null
                || !entry.matchesContext(a)
                || detailRoot.getWidth() < 16
                || detailRoot.getHeight() < 16) {
            restoreAlpha(entry.sourceViewRef.get());
            restoreAlpha(entry.dockViewRef.get());
            return false;
        }

        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }
        MobileFavoritePostcard.dismissActive();

        final int fullW = detailRoot.getWidth();
        final int fullH = detailRoot.getHeight();
        final View lowerSheet = detailRoot.findViewWithTag("detail-lower-sheet");
        float startSheetTopY = computeDefaultDetailSheetTopY(a, fullH);
        if (lowerSheet != null) {
            RectF liveSheetRect = measureRelativeRect(detailRoot, lowerSheet);
            if (liveSheetRect != null && liveSheetRect.height() > a.dp(60)) {
                startSheetTopY =
                        Math.max(
                                a.statusBarHeight() + a.dp(52),
                                Math.min(startSheetTopY, liveSheetRect.top));
            }
        }
        final float effectiveSheetTopY = startSheetTopY;

        a.capture();
        a.cancelPageRequests();
        a.stopWeb();
        a.stopMagnet();
        a.generation++;
        a.current = a.back.pop();
        a.applyMobileSystemBars(false, entry.prevForceLightStatusIcons);

        final View sourceView = entry.sourceViewRef.get();
        final View dockView = entry.dockViewRef.get();
        if (MobileMotion.isReduced(a)) {
            restoreAlpha(sourceView);
            restoreAlpha(dockView);
            finishRestorePreviousScreen(a, entry);
            prevRoot.setAlpha(0f);
            prevRoot.animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .start();
            return true;
        }

        final Bitmap returnPoster = resolveReturnBitmap(detailRoot, entry);
        final RectF liveTargetRect = new RectF(entry.initialRect);
        final RectF liveDockRect = new RectF(entry.initialDockRect);
        final boolean hasDock = entry.hasDock && dockView != null;
        final float sheetTopRadiusPx = a.dp(24);
        final float heroOverlapPx = a.dp(60);
        final MobileTheme.Palette palette = MobileTheme.of(a);

        detachFromParent(prevRoot);
        detachFromParent(detailRoot);
        if (lowerSheet != null) {
            lowerSheet.setAlpha(0f);
        }

        final FrameLayout transitionHost = new FrameLayout(a);
        transitionHost.setBackgroundColor(palette.bgCanvas);
        transitionHost.setClickable(true);
        transitionHost.setOnTouchListener((v, ev) -> true);
        transitionHost.addView(prevRoot, new FrameLayout.LayoutParams(-1, -1));

        final DualMorphStageView stage =
                new DualMorphStageView(
                        a,
                        detailRoot,
                        lowerSheet,
                        returnPoster,
                        entry.ambientColor,
                        palette.bgCanvas,
                        palette.isDark ? 0xEB181B24 : 0xF5FFFFFF,
                        palette.isDark ? 0x2EFFFFFF : 0x1A000000,
                        palette.accent,
                        entry.isFullBleedHero);
        stage.update(
                computeDualMorphFrame(
                        liveTargetRect.left,
                        liveTargetRect.top,
                        liveTargetRect.right,
                        liveTargetRect.bottom,
                        entry.sourceRadiusPx,
                        hasDock,
                        liveDockRect.left,
                        liveDockRect.top,
                        liveDockRect.right,
                        liveDockRect.bottom,
                        entry.dockRadiusPx,
                        fullW,
                        fullH,
                        effectiveSheetTopY,
                        sheetTopRadiusPx,
                        heroOverlapPx,
                        1f,
                        entry.isFullBleedHero,
                        returnPoster != null,
                        true));
        transitionHost.addView(stage, new FrameLayout.LayoutParams(-1, -1));

        if (sourceView != null) {
            resetPressScale(sourceView);
            sourceView.setAlpha(0f);
        }
        if (hasDock) dockView.setAlpha(0f);

        detailRoot.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        a.glassFreezeController.setGlassFrozen(true);
        a.setContentView(transitionHost);

        final ActiveRun run = new ActiveRun(true);
        final float[] elapsed = {0f};
        final boolean[] firstTick = {true};
        final boolean[] finished = {false};

        run.finishNow =
                () -> {
                    if (finished[0]) return;
                    finished[0] = true;
                    if (activeRun == run) activeRun = null;
                    if (run.step != null) {
                        MotionLoop.remove(run.step);
                        run.step = null;
                    }
                    restoreAlpha(sourceView);
                    restoreAlpha(dockView);
                    if (lowerSheet != null) {
                        lowerSheet.setAlpha(1f);
                        lowerSheet.setVisibility(View.VISIBLE);
                    }
                    detailRoot.setAlpha(1f);
                    detailRoot.setLayerType(View.LAYER_TYPE_NONE, null);
                    a.glassFreezeController.setGlassFrozen(false);
                    detachFromParent(prevRoot);
                    detachFromParent(detailRoot);
                    if (a.current == entry.prevScreen && !a.isFinishing()) {
                        finishRestorePreviousScreen(a, entry);
                    }
                };

        run.step =
                dt -> {
                    if (finished[0] || !UiCompat.isAttached(transitionHost) || a.isFinishing()) {
                        run.finishNow.run();
                        return false;
                    }
                    if (firstTick[0]) {
                        firstTick[0] = false;
                    } else {
                        elapsed[0] += Math.min(0.032f, dt);
                    }
                    float rawT = clamp01(elapsed[0] / EXIT_DURATION_SEC);
                    float p = 1f - evaluateSpringProgress(rawT, true);
                    float curW = transitionHost.getWidth() > 0 ? transitionHost.getWidth() : fullW;
                    float curH =
                            transitionHost.getHeight() > 0 ? transitionHost.getHeight() : fullH;
                    DualMorphFrame frame =
                            computeDualMorphFrame(
                                    liveTargetRect.left,
                                    liveTargetRect.top,
                                    liveTargetRect.right,
                                    liveTargetRect.bottom,
                                    entry.sourceRadiusPx,
                                    hasDock,
                                    liveDockRect.left,
                                    liveDockRect.top,
                                    liveDockRect.right,
                                    liveDockRect.bottom,
                                    entry.dockRadiusPx,
                                    curW,
                                    curH,
                                    effectiveSheetTopY,
                                    sheetTopRadiusPx,
                                    heroOverlapPx,
                                    p,
                                    entry.isFullBleedHero,
                                    returnPoster != null,
                                    true);
                    if (sourceView != null) {
                        if (entry.isFullBleedHero) {
                            sourceView.setAlpha(1f - clamp01(p / 0.16f));
                        } else {
                            sourceView.setAlpha(frame.hideSourceCard ? 0f : 1f);
                        }
                    }
                    if (hasDock) {
                        dockView.setAlpha(1f - clamp01(p / 0.16f));
                    }
                    stage.update(frame);
                    if (rawT >= 1f) {
                        run.finishNow.run();
                        return false;
                    }
                    return true;
                };

        activeRun = run;
        // Measure exact post-layout destination rects on prevRoot ONCE before launching MotionLoop
        // so the return flight never jumps mid-animation.
        transitionHost
                .getViewTreeObserver()
                .addOnPreDrawListener(
                        new ViewTreeObserver.OnPreDrawListener() {
                            @Override
                            public boolean onPreDraw() {
                                transitionHost.getViewTreeObserver().removeOnPreDrawListener(this);
                                if (sourceView != null) {
                                    resetPressScale(sourceView);
                                    RectF measured = measureRelativeRect(prevRoot, sourceView);
                                    if (measured != null
                                            && measured.width() >= 8f
                                            && measured.height() >= 8f) {
                                        liveTargetRect.set(measured);
                                    }
                                }
                                if (hasDock) {
                                    RectF measuredDock =
                                            measureVisibleDockBounds(prevRoot, dockView);
                                    if (measuredDock != null
                                            && measuredDock.width() > a.dp(60)
                                            && measuredDock.height() > a.dp(24)) {
                                        liveDockRect.set(measuredDock);
                                    }
                                }
                                if (!finished[0] && activeRun == run && run.step != null) {
                                    MotionLoop.add(run.step);
                                }
                                return true;
                            }
                        });
        return true;
    }

    private static float computeDefaultDetailSheetTopY(MainActivity a, int screenH) {
        int foregroundHeroH = Math.max(a.dp(360), Math.min(a.dp(500), Math.round(screenH * 0.56f)));
        return Math.max(a.dp(240), foregroundHeroH - a.dp(16));
    }

    /**
     * Measures the tight visual pill union of the currently visible bottom Dock layer (expanded
     * 4+1 capsules or collapsed compact capsule) relative to {@code prevRoot}.
     */
    private static RectF measureVisibleDockBounds(View prevRoot, View dockHost) {
        if (prevRoot == null || dockHost == null || dockHost.getVisibility() != View.VISIBLE) {
            return null;
        }
        if (dockHost.getAlpha() < 0.15f) return null;
        if (!(dockHost instanceof ViewGroup)) {
            return measureRelativeRect(prevRoot, dockHost);
        }
        ViewGroup vg = (ViewGroup) dockHost;
        // Find the visible layer (expandedDockLayer or collapsedDockLayer) with highest alpha
        View bestLayer = null;
        float bestAlpha = 0.15f;
        for (int i = 0; i < vg.getChildCount(); i++) {
            View child = vg.getChildAt(i);
            if (child != null
                    && child.getVisibility() == View.VISIBLE
                    && child.getAlpha() > bestAlpha) {
                bestAlpha = child.getAlpha();
                bestLayer = child;
            }
        }
        if (!(bestLayer instanceof ViewGroup)) {
            return measureRelativeRect(prevRoot, dockHost);
        }
        ViewGroup layer = (ViewGroup) bestLayer;
        RectF union = null;
        for (int i = 0; i < layer.getChildCount(); i++) {
            View pill = layer.getChildAt(i);
            if (pill == null || pill.getVisibility() != View.VISIBLE || pill.getWidth() <= 0) {
                continue;
            }
            RectF r = measureRelativeRect(prevRoot, pill);
            if (r == null) continue;
            if (union == null) {
                union = new RectF(r);
            } else {
                union.union(r);
            }
        }
        return union != null ? union : measureRelativeRect(prevRoot, dockHost);
    }

    private static void finishRestorePreviousScreen(MainActivity a, SavedReturnEntry entry) {
        FrameLayout prevRoot = entry.prevRoot;
        a.applyMobileSystemBars(false, entry.prevForceLightStatusIcons);
        a.root = prevRoot;
        a.setContentView(prevRoot);
        a.watchRootLayout(prevRoot);
        ImageLoader.resumeMissingPosters(a, prevRoot);
        if (entry.prevScreen.mobileHome != null) {
            if (MobileRootShell.activeTab == MobileRootShell.TAB_LIBRARY) {
                String favNow = a.prefs != null ? a.prefs.getString(Prefs.FAVORITES, "[]") : "";
                int histNow = a.watchHistory().size();
                if (!favNow.equals(entry.favSnapshotBefore)
                        || histNow != entry.historyCountBefore) {
                    entry.prevScreen.mobileHome.switchTab(MobileRootShell.TAB_LIBRARY);
                }
            }
        }
        a.restore(entry.prevScreen);
    }

    private static void restoreAlpha(View v) {
        if (v != null) {
            v.setAlpha(1f);
        }
    }

    private static void detachFromParent(View v) {
        if (v != null && v.getParent() instanceof ViewGroup) {
            ((ViewGroup) v.getParent()).removeView(v);
        }
    }

    private static void resetPressScale(View view) {
        View cur = view;
        for (int depth = 0; cur != null && depth < 3; depth++) {
            if (Math.abs(cur.getScaleX() - 1f) > 0.001f
                    || Math.abs(cur.getScaleY() - 1f) > 0.001f) {
                cur.animate().cancel();
                cur.setScaleX(1f);
                cur.setScaleY(1f);
            }
            if (!(cur.getParent() instanceof View)) break;
            cur = (View) cur.getParent();
        }
    }

    private static RectF measureRelativeRect(View root, View target) {
        if (root == null || target == null || target.getWidth() <= 0 || target.getHeight() <= 0) {
            return null;
        }
        // Walk unscaled layout coordinates up to root so transient press scale never skews rects.
        float l = 0f;
        float t = 0f;
        View cur = target;
        boolean reachedRoot = false;
        while (cur != null) {
            if (cur == root) {
                reachedRoot = true;
                break;
            }
            l += cur.getLeft() + cur.getTranslationX();
            t += cur.getTop() + cur.getTranslationY();
            if (!(cur.getParent() instanceof View)) break;
            View parent = (View) cur.getParent();
            l -= parent.getScrollX();
            t -= parent.getScrollY();
            cur = parent;
        }
        if (reachedRoot) {
            return new RectF(l, t, l + target.getWidth(), t + target.getHeight());
        }
        int[] rootLoc = new int[2];
        int[] targetLoc = new int[2];
        root.getLocationInWindow(rootLoc);
        target.getLocationInWindow(targetLoc);
        float wl = targetLoc[0] - rootLoc[0];
        float wt = targetLoc[1] - rootLoc[1];
        return new RectF(wl, wt, wl + target.getWidth(), wt + target.getHeight());
    }

    private static Bitmap extractPosterBitmap(MainActivity a, View sourceView, Cms.Video video) {
        Bitmap found = findLargestImageBitmap(sourceView);
        if (found != null && !found.isRecycled()) return found;
        if (a != null && video != null && video.poster != null && !video.poster.isEmpty()) {
            Bitmap cached = a.images.get(video.poster);
            if (cached != null && !cached.isRecycled()) return cached;
        }
        return null;
    }

    private static Bitmap resolveReturnBitmap(FrameLayout detailRoot, SavedReturnEntry entry) {
        Bitmap detailBmp = null;
        if (detailRoot != null) {
            detailBmp =
                    MainActivity.extractDetailPosterBitmap(
                            detailRoot.findViewWithTag("detail-backdrop"));
            if (detailBmp == null) {
                detailBmp =
                        MainActivity.extractDetailPosterBitmap(
                                detailRoot.findViewWithTag("detail-cover"));
            }
        }
        Bitmap orig = entry.posterBitmap;
        if (orig != null && !orig.isRecycled()) {
            if (detailBmp == null || detailBmp.isRecycled()) return orig;
            float srcAspect =
                    entry.initialRect.height() > 1f
                            ? (entry.initialRect.width() / entry.initialRect.height())
                            : 0.67f;
            float detailAspect =
                    detailBmp.getHeight() > 0
                            ? (detailBmp.getWidth() / (float) detailBmp.getHeight())
                            : 0.67f;
            if (Math.abs(srcAspect - detailAspect) > 0.35f) {
                return orig;
            }
            return detailBmp;
        }
        return (detailBmp != null && !detailBmp.isRecycled()) ? detailBmp : null;
    }

    private static Bitmap findLargestImageBitmap(View view) {
        if (view == null || view.getVisibility() != View.VISIBLE) return null;
        Bitmap best = null;
        long bestArea = -1L;
        if (view instanceof ImageView) {
            Bitmap bmp = extractImageBitmap((ImageView) view);
            if (bmp != null) {
                best = bmp;
                bestArea = (long) Math.max(1, view.getWidth()) * Math.max(1, view.getHeight());
            }
        }
        if (view instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) view;
            for (int i = 0; i < vg.getChildCount(); i++) {
                View child = vg.getChildAt(i);
                if (child == null || child.getVisibility() != View.VISIBLE) continue;
                Bitmap cand = findLargestImageBitmap(child);
                if (cand != null) {
                    long area =
                            (long) Math.max(1, child.getWidth()) * Math.max(1, child.getHeight());
                    if (area >= bestArea) {
                        bestArea = area;
                        best = cand;
                    }
                }
            }
        }
        return best;
    }

    private static Bitmap extractImageBitmap(ImageView iv) {
        if (iv == null) return null;
        Drawable d = iv.getDrawable();
        if (d instanceof BitmapDrawable) {
            Bitmap b = ((BitmapDrawable) d).getBitmap();
            if (b != null && !b.isRecycled()) return b;
        }
        return null;
    }

    /**
     * Zero-relayout single-pass dual-element compositor:
     * <ol>
     *   <li>Upper expanding/shrinking Poster Card -> Detail Hero
     *   <li>Lower floating Dock pill <-> Detail rounded episode sheet ({@code detail-lower-sheet})
     * </ol>
     */
    private static final class DualMorphStageView extends FrameLayout {
        private final MainActivity a;
        private final View detailRoot;
        private final View lowerSheet;
        private final Bitmap posterBitmap;
        private final int ambientColor;
        private final int bgCanvasColor;
        private final int dockSurfaceColor;
        private final int dockStrokeColor;
        private final int accentColor;
        private final boolean isFullBleedHero;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint heroFadePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path clipPath = new Path();
        private final RectF posterRect = new RectF();
        private final RectF sheetRect = new RectF();
        private final RectF shadowRect = new RectF();
        private final Rect srcRect = new Rect();
        private final float[] sheetRadii = new float[8];
        private DualMorphFrame frame;
        private float lastHeroFadeH = -1f;

        DualMorphStageView(
                MainActivity a,
                View detailRoot,
                View lowerSheet,
                Bitmap posterBitmap,
                int ambientColor,
                int bgCanvasColor,
                int dockSurfaceColor,
                int dockStrokeColor,
                int accentColor,
                boolean isFullBleedHero) {
            super(a);
            this.a = a;
            this.detailRoot = detailRoot;
            this.lowerSheet = lowerSheet;
            this.posterBitmap = posterBitmap;
            this.ambientColor = ambientColor;
            this.bgCanvasColor = bgCanvasColor;
            this.dockSurfaceColor = dockSurfaceColor;
            this.dockStrokeColor = dockStrokeColor;
            this.accentColor = accentColor;
            this.isFullBleedHero = isFullBleedHero;
            strokePaint.setStyle(Paint.Style.STROKE);
            strokePaint.setStrokeWidth(MobileTheme.hairlinePx(a));
            setClipChildren(false);
            addView(detailRoot, new FrameLayout.LayoutParams(-1, -1));
        }

        void update(DualMorphFrame next) {
            this.frame = next;
            if (detailRoot != null && next != null) {
                detailRoot.setAlpha(next.heroChromeAlpha * next.edgeOpacity);
            }
            invalidate();
        }

        @Override
        protected void dispatchDraw(Canvas canvas) {
            DualMorphFrame f = this.frame;
            if (f == null) {
                super.dispatchDraw(canvas);
                return;
            }
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;

            // 1. Subtle backdrop dim over the preserved previous screen
            if (f.backdropDim > 0.005f) {
                paint.reset();
                paint.setColor(Color.argb(Math.round(f.backdropDim * 255f), 0, 0, 0));
                canvas.drawRect(0f, 0f, w, h, paint);
            }

            if (f.edgeOpacity <= 0.005f) return;
            int edgeAlpha = Math.round(255f * f.edgeOpacity);

            // =====================================================================
            // PASS 1: Upper Poster Card <-> Full-Bleed Detail Hero
            // =====================================================================
            posterRect.set(f.posterLeft, f.posterTop, f.posterRight, f.posterBottom);
            if (posterRect.width() > 1f && posterRect.height() > 1f) {
                if (f.posterRadiusPx > 0.5f) {
                    float sf = clamp01(1f - f.backdropDim / 0.34f);
                    if (sf > 0.02f) {
                        float sp = a.dp(6f) * sf;
                        float dy = a.dp(5f) * sf;
                        shadowRect.set(
                                posterRect.left - sp * 0.4f,
                                posterRect.top + dy * 0.5f,
                                posterRect.right + sp * 0.4f,
                                posterRect.bottom + dy + sp * 0.6f);
                        paint.reset();
                        paint.setAntiAlias(true);
                        paint.setColor(Color.argb(Math.round(54f * sf * f.edgeOpacity), 0, 0, 0));
                        canvas.drawRoundRect(
                                shadowRect,
                                f.posterRadiusPx + sp * 0.3f,
                                f.posterRadiusPx + sp * 0.3f,
                                paint);
                    }
                }

                int pSave = canvas.save();
                if (f.posterRadiusPx > 0.5f) {
                    clipPath.reset();
                    clipPath.addRoundRect(
                            posterRect, f.posterRadiusPx, f.posterRadiusPx, Path.Direction.CW);
                    canvas.clipPath(clipPath);
                } else {
                    canvas.clipRect(posterRect);
                }

                paint.reset();
                paint.setAntiAlias(true);
                paint.setColor(MobileTheme.withAlpha(ambientColor, edgeAlpha));
                canvas.drawRect(posterRect, paint);

                if (posterBitmap != null && !posterBitmap.isRecycled()) {
                    int bw = posterBitmap.getWidth();
                    int bh = posterBitmap.getHeight();
                    if (bw > 0 && bh > 0) {
                        float sc = Math.max(posterRect.width() / bw, posterRect.height() / bh);
                        float cropW = posterRect.width() / sc;
                        float cropH = posterRect.height() / sc;
                        float yAnchor = interpolatePosterCropAnchorY(f.progress);
                        int sl = Math.max(0, Math.round((bw - cropW) * 0.5f));
                        int st = Math.max(0, Math.round((bh - cropH) * yAnchor));
                        srcRect.set(
                                sl,
                                st,
                                Math.min(bw, sl + Math.round(cropW)),
                                Math.min(bh, st + Math.round(cropH)));
                        paint.reset();
                        paint.setAntiAlias(true);
                        paint.setFilterBitmap(true);
                        paint.setAlpha(edgeAlpha);
                        canvas.drawBitmap(posterBitmap, srcRect, posterRect, paint);
                    }
                }

                if (isFullBleedHero && f.heroChromeAlpha < 0.99f) {
                    float fadeH = posterRect.height() * 0.42f;
                    float fadeTop = posterRect.bottom - fadeH;
                    if (Math.abs(fadeH - lastHeroFadeH) > 2f) {
                        lastHeroFadeH = fadeH;
                        heroFadePaint.setShader(
                                new LinearGradient(
                                        0f,
                                        fadeTop,
                                        0f,
                                        posterRect.bottom,
                                        new int[] {
                                            Color.TRANSPARENT,
                                            MobileTheme.withAlpha(ambientColor, 0xA8),
                                            ambientColor
                                        },
                                        new float[] {0f, 0.55f, 1f},
                                        Shader.TileMode.CLAMP));
                    }
                    heroFadePaint.setAlpha(
                            Math.round((1f - f.heroChromeAlpha) * f.edgeOpacity * 255f));
                    canvas.drawRect(
                            posterRect.left,
                            fadeTop,
                            posterRect.right,
                            posterRect.bottom,
                            heroFadePaint);
                }

                // Draw upper Detail Hero (title, pills, floating back/source/fav bar). lowerSheet
                // stays alpha=0 for the entire animation so Pass 1 never mutates view visibility
                // inside dispatchDraw (zero HWUI re-upload / stair-step jank).
                if (detailRoot != null && f.heroChromeAlpha * f.edgeOpacity > 0.005f) {
                    int dSave = canvas.save();
                    if (isFullBleedHero) {
                        float tx = posterRect.left + (posterRect.width() - w) * 0.5f;
                        canvas.translate(tx, posterRect.top);
                    } else {
                        float sc = Math.max(posterRect.width() / w, posterRect.height() / h);
                        float tx = posterRect.left + (posterRect.width() - w * sc) * 0.5f;
                        canvas.translate(tx, posterRect.top);
                        canvas.scale(sc, sc);
                    }
                    super.dispatchDraw(canvas);
                    canvas.restoreToCount(dSave);
                }
                canvas.restoreToCount(pSave);
            }

            // =====================================================================
            // PASS 2: Floating Bottom Dock <-> Rounded Detail Lower Episode Sheet
            // =====================================================================
            if (f.hasSheetMorph) {
                sheetRect.set(f.sheetLeft, f.sheetTop, f.sheetRight, f.sheetBottom);
                if (sheetRect.width() > 2f && sheetRect.height() > 2f) {
                    sheetRadii[0] = f.sheetTopRadiusPx;
                    sheetRadii[1] = f.sheetTopRadiusPx;
                    sheetRadii[2] = f.sheetTopRadiusPx;
                    sheetRadii[3] = f.sheetTopRadiusPx;
                    sheetRadii[4] = f.sheetBottomRadiusPx;
                    sheetRadii[5] = f.sheetBottomRadiusPx;
                    sheetRadii[6] = f.sheetBottomRadiusPx;
                    sheetRadii[7] = f.sheetBottomRadiusPx;

                    // Floating elevation shadow during Dock-pill <-> Sheet morph
                    float sheetShadowFrac = clamp01(1f - f.sheetSurfaceBlend * 0.7f);
                    if (sheetShadowFrac > 0.04f) {
                        float sp = a.dp(7f) * sheetShadowFrac;
                        shadowRect.set(
                                sheetRect.left - sp * 0.25f,
                                sheetRect.top - sp * 0.35f,
                                sheetRect.right + sp * 0.25f,
                                sheetRect.bottom + sp * 0.45f);
                        paint.reset();
                        paint.setAntiAlias(true);
                        paint.setColor(
                                Color.argb(
                                        Math.round(48f * sheetShadowFrac * f.edgeOpacity),
                                        0,
                                        0,
                                        0));
                        canvas.drawRoundRect(
                                shadowRect, f.sheetTopRadiusPx, f.sheetTopRadiusPx, paint);
                    }

                    int sSave = canvas.save();
                    clipPath.reset();
                    clipPath.addRoundRect(sheetRect, sheetRadii, Path.Direction.CW);
                    canvas.clipPath(clipPath);

                    int surfaceCol =
                            MobileTheme.blend(dockSurfaceColor, bgCanvasColor, f.sheetSurfaceBlend);
                    paint.reset();
                    paint.setAntiAlias(true);
                    paint.setColor(
                            MobileTheme.withAlpha(
                                    surfaceCol,
                                    Math.round(Color.alpha(surfaceCol) * f.edgeOpacity)));
                    canvas.drawRect(sheetRect, paint);

                    // Composite the real Detail lower sheet centered cleanly without horizontal
                    // text squishing so typography glides smoothly into its final layout.
                    float contentAlpha = f.sheetContentAlpha * f.edgeOpacity;
                    if (lowerSheet != null && contentAlpha > 0.01f && lowerSheet.getWidth() > 0) {
                        int cSave = canvas.save();
                        float offsetX = (sheetRect.width() - lowerSheet.getWidth()) * 0.5f;
                        canvas.translate(sheetRect.left + offsetX, sheetRect.top);
                        if (contentAlpha < 0.99f) {
                            canvas.saveLayerAlpha(
                                    0f,
                                    0f,
                                    lowerSheet.getWidth(),
                                    Math.max(sheetRect.height(), lowerSheet.getHeight()),
                                    Math.round(255f * contentAlpha));
                        }
                        lowerSheet.draw(canvas);
                        canvas.restoreToCount(cSave);
                    }

                    canvas.restoreToCount(sSave);

                    // Delicate Dock rim hairline fading away as the capsule merges edge-to-edge
                    float rimAlpha = (1f - f.sheetSurfaceBlend) * f.edgeOpacity;
                    if (rimAlpha > 0.02f) {
                        strokePaint.setColor(
                                MobileTheme.withAlpha(
                                        dockStrokeColor,
                                        Math.round(Color.alpha(dockStrokeColor) * rimAlpha)));
                        clipPath.reset();
                        clipPath.addRoundRect(sheetRect, sheetRadii, Path.Direction.CW);
                        canvas.drawPath(clipPath, strokePaint);
                    }
                }
            }
        }
    }
}

package com.pilipala.marcomovie;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.ViewTreeObserver;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;

/**
 * Full-screen native Android port of iOS {@code _CuratedGravityWallPage} ({@code
 * flutter/lib/ui/curated_discovery_section.dart}) featuring:
 *
 * <ul>
 *   <li>Edge-to-edge ambient accent aura behind the transparent status bar
 *   <li>Floating borderless header with scroll-reactive feathered veil, circular frosted back
 *       button, and optically centered title &amp; subtitle
 *   <li>Responsive 3-column (4-column on {@code >= 620dp} tablets) interactive Poster Wall whose
 *       cards open {@link MobileDetailScreen} via {@link MobilePosterTransition}
 *   <li>All 3 signature 120fps physics entrance choreographies driven by {@link MotionLoop}:
 *       <ol>
 *         <li>{@link #STYLE_GRAVITY_STACK}: Free-fall bounce into fanned center stack -> spring
 *             spread outward into grid
 *         <li>{@link #STYLE_BLACK_HOLE_VORTEX}: Orbit &amp; spiral inward into glowing swirling
 *             singularity + accretion arcs -> supernova shockwave burst outward into grid
 *         <li>{@link #STYLE_TETRIS_TUMBLE}: Mixed horizontal/vertical blocks fall &amp; stack
 *             crookedly -> energetic arc scatter morphing cleanly into grid
 *       </ol>
 * </ul>
 */
final class MobileCuratedWallScreen {
    static final int STYLE_GRAVITY_STACK = 0;
    static final int STYLE_BLACK_HOLE_VORTEX = 1;
    static final int STYLE_TETRIS_TUMBLE = 2;

    static final float ENTRANCE_DURATION_SEC = 1.32f;
    static final int MAX_ANIMATED_CARDS = 12;

    private static final float[] STACK_ANGLES = {
        -0.14f, 0.11f, -0.07f, 0.16f, -0.10f, 0.08f, -0.15f, 0.12f, -0.05f, 0.09f, -0.12f, 0.06f
    };
    private static final float[][] STACK_JITTERS = {
        {-10f, 8f},
        {9f, 5f},
        {-5f, 3f},
        {12f, 0f},
        {-8f, -3f},
        {6f, -5f},
        {-11f, -7f},
        {8f, -9f},
        {-4f, -11f},
        {10f, -13f},
        {-7f, -15f},
        {4f, -17f}
    };
    // (dxUnits, dyUnits, angleRad, isLandscape: 1f=landscape, 0f=portrait)
    private static final float[][] TETRIS_SLOTS = {
        {-0.88f, 0.0f, -0.06f, 1f},
        {0.58f, 0.0f, 0.05f, 0f},
        {-0.18f, 0.72f, 0.04f, 1f},
        {1.05f, 0.85f, -0.08f, 0f},
        {-1.08f, 0.96f, 0.07f, 0f},
        {0.26f, 1.56f, -0.05f, 1f},
        {-0.76f, 1.88f, 0.09f, 1f},
        {0.82f, 2.22f, -0.07f, 0f},
        {-0.16f, 2.52f, 0.05f, 0f},
        {-1.02f, 2.74f, -0.09f, 1f},
        {0.48f, 3.04f, 0.08f, 1f},
        {-0.32f, 3.40f, -0.04f, 0f}
    };

    private MobileCuratedWallScreen() {}

    /** Pure-JVM snapshot of a single animated physics card's geometry &amp; opacity. */
    static final class PhysicsCardState {
        final float centerX;
        final float centerY;
        final float width;
        final float height;
        final float angleRad;
        final float opacity;

        PhysicsCardState(
                float centerX,
                float centerY,
                float width,
                float height,
                float angleRad,
                float opacity) {
            this.centerX = centerX;
            this.centerY = centerY;
            this.width = width;
            this.height = height;
            this.angleRad = angleRad;
            this.opacity = opacity;
        }
    }

    private static float clamp01(float v) {
        if (Float.isNaN(v)) return 0f;
        return Math.max(0f, Math.min(1f, v));
    }

    private static float clamp(float v, float lo, float hi) {
        if (Float.isNaN(v)) return lo;
        return Math.max(lo, Math.min(hi, v));
    }

    private static float lerp(float a, float b, float t) {
        return a + (b - a) * t;
    }

    static float easeOutCubic(float t) {
        float x = 1f - clamp01(t);
        return 1f - x * x * x;
    }

    static float easeInCubic(float t) {
        float x = clamp01(t);
        return x * x * x;
    }

    static float easeOutBack(float t) {
        float x = clamp01(t) - 1f;
        float c1 = 1.70158f;
        float c3 = c1 + 1f;
        return 1f + c3 * x * x * x + c1 * x * x;
    }

    /**
     * Exact pure-JVM port of iOS {@code _gravityFallWithBounce}: free-fall acceleration with two
     * damped physical floor impacts settling at {@code 1.0}.
     */
    static float gravityFallWithBounce(float t) {
        float x = clamp01(t);
        if (x < 0.68f) {
            float u = x / 0.68f;
            return u * u;
        } else if (x < 0.86f) {
            float u = (x - 0.68f) / 0.18f;
            return 1f - 0.10f * (float) Math.sin(u * Math.PI);
        } else {
            float u = (x - 0.86f) / 0.14f;
            return 1f - 0.032f * (float) Math.sin(u * Math.PI);
        }
    }

    /**
     * Pure-JVM deterministic evaluator computing a card's live center, dimensions, rotation, and
     * opacity across all 3 iOS physics entrance styles ({@link #STYLE_GRAVITY_STACK}, {@link
     * #STYLE_BLACK_HOLE_VORTEX}, {@link #STYLE_TETRIS_TUMBLE}). At {@code progress >= 0.999f},
     * every style converges pixel-exactly onto {@code (targetLeft + targetW/2, targetTop +
     * targetH/2, targetW, targetH, angle=0)}.
     */
    static PhysicsCardState computePhysicsCardState(
            int style,
            int index,
            int count,
            float progress,
            float screenW,
            float screenH,
            float density,
            float targetLeft,
            float targetTop,
            float targetW,
            float targetH) {
        float v = clamp01(progress);
        float d = Math.max(1f, density);
        int n = Math.max(1, count);
        int idx = Math.max(0, Math.min(n - 1, index));
        float targetCx = targetLeft + targetW * 0.5f;
        float targetCy = targetTop + targetH * 0.5f;

        if (style == STYLE_BLACK_HOLE_VORTEX) {
            float cx = screenW * 0.50f;
            float cy = screenH * 0.44f;
            float startAngle =
                    (idx / (float) n) * (float) (Math.PI * 2.0) + ((idx % 2 == 0) ? 0.2f : -0.3f);
            float maxOrbitR = Math.max(screenW, screenH) * 0.56f;
            float minOrbitR = 6f * d;

            if (v < 0.48f) {
                float inU = clamp01((v - (idx / (float) n) * 0.08f) / 0.40f);
                float spiral = easeInCubic(inU);
                float r = lerp(maxOrbitR, minOrbitR, spiral);
                float angle = startAngle + spiral * 4.2f;
                float scale = lerp(0.86f, 0.18f, spiral);
                float curCx = cx + (float) Math.cos(angle) * r;
                float curCy = cy + (float) Math.sin(angle) * r;
                float rot = (angle + (float) (Math.PI * 0.5)) * (1f - spiral * 0.4f);
                float op = clamp01(inU * 3.5f) * lerp(1f, 0.22f, spiral);
                return new PhysicsCardState(
                        curCx, curCy, targetW * scale, targetH * scale, rot, op);
            } else if (v < 0.54f) {
                return new PhysicsCardState(
                        cx, cy, targetW * 0.16f, targetH * 0.16f, startAngle + 4.2f, 0.18f);
            } else {
                float bStart = 0.54f + (idx / (float) n) * 0.07f;
                float bEnd = clamp(bStart + 0.34f, 0.78f, 0.95f);
                float raw = clamp01((v - bStart) / Math.max(0.01f, bEnd - bStart));
                float burstU = easeOutBack(raw);
                float curCx = lerp(cx, targetCx, burstU);
                float curCy = lerp(cy, targetCy, burstU);
                float scale = lerp(0.24f, 1.0f, burstU);
                float rot = lerp((idx - n * 0.5f) * 0.22f, 0f, burstU);
                float op = clamp01(burstU * 2.8f);
                return new PhysicsCardState(
                        curCx, curCy, targetW * scale, targetH * scale, rot, op);
            }
        }

        if (style == STYLE_TETRIS_TUMBLE) {
            float[] slot = TETRIS_SLOTS[idx % TETRIS_SLOTS.length];
            float dxUnits = slot[0];
            float dyUnits = slot[1];
            float slotAngle = slot[2];
            boolean landscape = slot[3] > 0.5f;

            float pileUnit = clamp(screenW * 0.22f, 72f * d, 96f * d);
            float bw = landscape ? pileUnit * 1.28f : pileUnit * 0.80f;
            float bh = landscape ? pileUnit * 0.80f : pileUnit * 1.16f;
            float pileBaseX = screenW * 0.50f;
            float pileBaseY = screenH * 0.64f;
            float piledCx = pileBaseX + dxUnits * pileUnit;
            float piledCy = pileBaseY - dyUnits * pileUnit;

            if (v < 0.54f) {
                float startT = (idx / (float) n) * 0.28f;
                float endT = clamp(startT + 0.24f, 0.24f, 0.54f);
                float u = clamp01((v - startT) / Math.max(0.01f, endT - startT));
                float fall = gravityFallWithBounce(u);
                float startCy = -bh * 0.5f - 24f * d - (idx % 3) * 32f * d;
                float curCy = lerp(startCy, piledCy, fall);
                float rot = lerp(slotAngle * 2.4f + (idx % 2 == 0 ? 0.35f : -0.35f), slotAngle, u);
                float op = clamp01(u * 5.0f);
                return new PhysicsCardState(piledCx, curCy, bw, bh, rot, op);
            } else {
                float sStart = 0.54f + (idx / (float) n) * 0.08f;
                float sEnd = clamp(sStart + 0.34f, 0.76f, 0.96f);
                float raw = clamp01((v - sStart) / Math.max(0.01f, sEnd - sStart));
                float t = easeOutBack(raw);
                float arc = (float) Math.sin(raw * Math.PI) * 26f * d * ((idx % 2 == 0) ? -1f : 1f);
                float curCx = lerp(piledCx, targetCx, t) + arc;
                float curCy = lerp(piledCy, targetCy, t);
                float curW = lerp(bw, targetW, t);
                float curH = lerp(bh, targetH, t);
                float rot = lerp(slotAngle, 0f, t);
                return new PhysicsCardState(curCx, curCy, curW, curH, rot, 1f);
            }
        }

        // Default: STYLE_GRAVITY_STACK
        float stackW = clamp(targetW * 1.12f, 98f * d, 132f * d);
        float stackH = stackW * 1.48f;
        float stackCx = screenW * 0.50f;
        float stackCy = screenH * 0.50f;
        float targetAngle = STACK_ANGLES[idx % STACK_ANGLES.length];
        float[] jitter = STACK_JITTERS[idx % STACK_JITTERS.length];
        float stackedCx = stackCx + jitter[0] * d;
        float stackedCy = stackCy + jitter[1] * d;

        if (v < 0.46f) {
            float startT = (idx / (float) n) * 0.20f;
            float endT = clamp(startT + 0.24f, 0.24f, 0.46f);
            float u = clamp01((v - startT) / Math.max(0.01f, endT - startT));
            float fall = gravityFallWithBounce(u);
            float startCy = -stackH * 0.5f - 28f * d - (idx % 4) * 26f * d;
            float curCy = lerp(startCy, stackedCy, fall);
            float rot = targetAngle * (0.4f + 0.6f * u);
            float op = clamp01(u * 4.5f);
            return new PhysicsCardState(stackedCx, curCy, stackW, stackH, rot, op);
        } else {
            float spreadStart = 0.46f + (idx / (float) n) * 0.09f;
            float spreadEnd = clamp(spreadStart + 0.36f, 0.70f, 0.94f);
            float raw = clamp01((v - spreadStart) / Math.max(0.01f, spreadEnd - spreadStart));
            float t = easeOutBack(raw);
            float curCx = lerp(stackedCx, targetCx, t);
            float curCy = lerp(stackedCy, targetCy, t);
            float curW = lerp(stackW, targetW, t);
            float curH = lerp(stackH, targetH, t);
            float rot = lerp(targetAngle, 0f, t);
            return new PhysicsCardState(curCx, curCy, curW, curH, rot, 1f);
        }
    }

    /** Opens the full-screen iOS-parity Curated Collection Wall on the activity screen stack. */
    static void open(
            final MainActivity a,
            final Cms.Site curatedSite,
            final String title,
            final String subtitle,
            final int accentColor,
            final List<Cms.Video> items,
            final boolean hasUserSources,
            final int entranceStyle) {
        if (a == null || items == null || items.isEmpty()) return;
        final List<Cms.Video> snapshot = new ArrayList<>(items);
        final boolean[] playedOnce = {false};
        a.open(
                new MainActivity.Screen(
                        () -> {
                            boolean runPhysics = !playedOnce[0] && !MobileMotion.isReduced(a);
                            playedOnce[0] = true;
                            show(
                                    a,
                                    curatedSite,
                                    title,
                                    subtitle,
                                    accentColor,
                                    snapshot,
                                    hasUserSources,
                                    entranceStyle,
                                    runPhysics);
                        }),
                true);
    }

    private static void show(
            final MainActivity a,
            final Cms.Site curatedSite,
            final String title,
            final String subtitle,
            final int accentColor,
            final List<Cms.Video> items,
            final boolean hasUserSources,
            final int entranceStyle,
            final boolean playPhysicsEntrance) {
        a.clearPlaybackLoading();
        a.cancelArtwork();
        a.cancelPageRequests();
        if (a.current != null) a.current.home = false;
        a.stopWeb();
        a.stopMagnet();
        a.releasePlayer();
        a.generation++;

        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }

        a.applyMobileSystemBars(false, false);

        final MobileTheme.Palette p = MobileTheme.of(a);
        final int topPad = a.statusBarHeight();
        final int bottomPad = a.navigationBarHeight() + a.dp(36);
        final int screenW = Math.max(a.dp(320), a.windowWidth());
        final int screenH = Math.max(a.dp(480), a.windowHeight());
        final float density = a.getResources().getDisplayMetrics().density;
        final float widthDp = screenW / Math.max(1f, density);
        final int cols = widthDp >= 620f ? 4 : 3;
        final int horizPad = a.dp(16);
        final int gapPx = a.dp(11);
        final int gridTopPad = topPad + a.dp(72);
        final int availW = Math.max(a.dp(220), screenW - horizPad * 2 - gapPx * (cols - 1));
        final int cellW = availW / cols;
        final int posterH = Math.round(cellW * 1.48f);

        final FrameLayout wallRoot = new FrameLayout(a);
        wallRoot.setTag("curated-wall-root");
        wallRoot.setBackgroundColor(p.bgCanvas);
        a.root = wallRoot;
        a.setContentView(wallRoot);
        a.watchRootLayout(wallRoot);

        // Layer 0: Subtle edge-to-edge top ambient accent aura behind status bar & header
        AmbientAuraView aura = new AmbientAuraView(a, accentColor, p.isDark);
        wallRoot.addView(aura, new FrameLayout.LayoutParams(-1, topPad + a.dp(184), Gravity.TOP));

        // Layer 1: Scrollable 3/4-column interactive Poster Wall
        final ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);

        LinearLayout gridBody = a.vertical();
        gridBody.setPadding(horizPad, gridTopPad, horizPad, bottomPad);

        final List<FrameLayout> gridPosterBoxes = new ArrayList<>();
        LinearLayout gridRow = null;
        int colIdx = 0;
        for (int i = 0; i < items.size(); i++) {
            final Cms.Video v = items.get(i);
            if (gridRow == null || colIdx == cols) {
                gridRow = a.row();
                gridRow.setGravity(Gravity.TOP);
                gridRow.setBaselineAligned(false);
                LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(-1, -2);
                rLp.bottomMargin = a.dp(14);
                gridBody.addView(gridRow, rLp);
                colIdx = 0;
            }
            LinearLayout card = a.vertical();
            final FrameLayout box = new FrameLayout(a);
            box.setClipToOutline(true);
            GradientDrawable boxBg = a.bg(p.bgSubtle, 13);
            boxBg.setStroke(MobileTheme.hairlinePx(a), p.isDark ? 0x1AFFFFFF : 0x10000000);
            box.setBackground(boxBg);
            if (!p.isDark) UiCompat.setElevation(box, a.dp(2f));

            ImageView img = new ImageView(a);
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            if (v.poster != null && !v.poster.isEmpty()) a.poster(v.poster, img);
            box.addView(img, new FrameLayout.LayoutParams(-1, posterH));

            String scoreTag = shortScoreTag(v);
            if (!scoreTag.isEmpty()) {
                TextView sc = a.text(scoreTag, 9.5f, 0xFFFFD86B);
                sc.setTypeface(null, Typeface.BOLD);
                sc.setPadding(a.dp(5.5f), a.dp(2), a.dp(5.5f), a.dp(2));
                sc.setBackground(a.bg(0xB80A0B0E, 6));
                FrameLayout.LayoutParams sLp =
                        new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
                sLp.setMargins(a.dp(5), a.dp(5), a.dp(5), a.dp(5));
                box.addView(sc, sLp);
            }
            card.addView(box, new LinearLayout.LayoutParams(-1, posterH));
            if (gridPosterBoxes.size() < MAX_ANIMATED_CARDS) {
                gridPosterBoxes.add(box);
            }

            TextView t = a.text(v.title == null ? "" : v.title, 12.5f, p.textPrimary);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setMaxLines(1);
            t.setEllipsize(TextUtils.TruncateAt.END);
            t.setPadding(a.dp(2), a.dp(6), a.dp(2), 0);
            card.addView(t, new LinearLayout.LayoutParams(-1, -2));

            String meta = buildCardSubtitle(v);
            if (!meta.isEmpty()) {
                TextView sub = a.text(meta, 10.5f, p.textTertiary);
                sub.setSingleLine(true);
                sub.setMaxLines(1);
                sub.setEllipsize(TextUtils.TruncateAt.END);
                sub.setPadding(a.dp(2), a.dp(1.5f), a.dp(2), 0);
                card.addView(sub, new LinearLayout.LayoutParams(-1, -2));
            }

            MobileMotion.bindPress(card, 0.96f);
            card.setOnClickListener(
                    view ->
                            MobilePosterTransition.openDetailFromCard(
                                    a, curatedSite, v, box, 13f, false));

            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (colIdx < cols - 1) cLp.rightMargin = gapPx;
            gridRow.addView(card, cLp);
            colIdx++;
        }
        if (gridRow != null && colIdx > 0 && colIdx < cols) {
            for (int pad = colIdx; pad < cols; pad++) {
                LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(0, 1, 1f);
                if (pad < cols - 1) pLp.rightMargin = gapPx;
                gridRow.addView(new View(a), pLp);
            }
        }

        sv.addView(gridBody, new ScrollView.LayoutParams(-1, -2));
        wallRoot.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        // Layer 2: Physics choreography overlay (Black Hole / Tetris / Gravity Stack)
        if (playPhysicsEntrance) {
            sv.setAlpha(0f);
            launchPhysicsChoreography(
                    a,
                    wallRoot,
                    sv,
                    gridPosterBoxes,
                    items,
                    entranceStyle,
                    accentColor,
                    p,
                    screenW,
                    screenH,
                    density,
                    cols,
                    horizPad,
                    gapPx,
                    gridTopPad,
                    cellW,
                    posterH);
        } else {
            sv.setAlpha(0f);
            sv.animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                    .setInterpolator(MotionTokens.createDecelerateInterpolator())
                    .start();
        }

        // Layer 3: Floating Borderless Header with Scroll-Reactive Feathered Veil
        final int headerH = topPad + a.dp(58);
        final HeaderVeilView headerVeil = new HeaderVeilView(a, p.bgCanvas);
        wallRoot.addView(
                headerVeil, new FrameLayout.LayoutParams(-1, headerH + a.dp(12), Gravity.TOP));

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        headerRow.setPadding(a.dp(14), topPad + a.dp(8), a.dp(14), a.dp(8));

        FrameLayout backBtn = new FrameLayout(a);
        backBtn.setTag("curated-wall-back");
        GradientDrawable backBg = a.bg(p.isDark ? 0x661C1F28 : 0xD9FFFFFF, 999);
        backBg.setStroke(MobileTheme.hairlinePx(a), p.isDark ? 0x26FFFFFF : 0x16000000);
        backBtn.setBackground(backBg);
        if (!p.isDark) UiCompat.setElevation(backBtn, a.dp(2f));
        MobileIcons.IconView backIc =
                MobileIcons.create(a, MobileIcons.IC_BACK, 19f, p.textPrimary);
        backIc.setStrokeWidthUnits(2.2f);
        backBtn.addView(backIc, new FrameLayout.LayoutParams(a.dp(19), a.dp(19), Gravity.CENTER));
        MobileMotion.bindPress(backBtn, 0.90f);
        backBtn.setOnClickListener(v -> a.onBackPressed());
        headerRow.addView(backBtn, new LinearLayout.LayoutParams(a.dp(38), a.dp(38)));

        LinearLayout titleCol = a.vertical();
        titleCol.setGravity(Gravity.CENTER_HORIZONTAL);
        titleCol.setPadding(a.dp(8), 0, a.dp(8), 0);

        TextView titleTv = a.text(title == null ? "精选专题" : title, 17f, p.textPrimary);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        titleCol.addView(titleTv);

        String subLine =
                (subtitle != null && !subtitle.trim().isEmpty())
                        ? subtitle.trim()
                        : (hasUserSources ? "点击海报自动匹配片源播放" : "暂未添加订阅源 · 播放时提示导入");
        TextView subTv = a.text(subLine, 11f, p.textSecondary);
        subTv.setSingleLine(true);
        subTv.setEllipsize(TextUtils.TruncateAt.END);
        subTv.setPadding(0, a.dp(1.5f), 0, 0);
        titleCol.addView(subTv);

        headerRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));
        headerRow.addView(new View(a), new LinearLayout.LayoutParams(a.dp(38), a.dp(38)));
        wallRoot.addView(headerRow, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        final float veilRampPx = Math.max(1f, a.dp(52));
        if (Build.VERSION.SDK_INT >= 23) {
            sv.setOnScrollChangeListener(
                    (v, sx, sy, osx, osy) -> headerVeil.setDepth(clamp01(sy / veilRampPx)));
        } else {
            sv.getViewTreeObserver()
                    .addOnScrollChangedListener(
                            () -> headerVeil.setDepth(clamp01(sv.getScrollY() / veilRampPx)));
        }
    }

    private static void launchPhysicsChoreography(
            final MainActivity a,
            final FrameLayout wallRoot,
            final ScrollView sv,
            final List<FrameLayout> gridPosterBoxes,
            final List<Cms.Video> items,
            final int style,
            final int accentColor,
            final MobileTheme.Palette p,
            final int screenW,
            final int screenH,
            final float density,
            final int cols,
            final int horizPad,
            final int gapPx,
            final int gridTopPad,
            final int cellW,
            final int posterH) {
        final int animCount = Math.min(MAX_ANIMATED_CARDS, items.size());
        if (animCount <= 0) {
            sv.setAlpha(1f);
            return;
        }

        final FrameLayout overlay = new FrameLayout(a);
        overlay.setTag("curated-physics-overlay");
        overlay.setClipChildren(false);
        overlay.setClickable(false);
        overlay.setFocusable(false);

        final BlackHoleVortexView vortexView =
                style == STYLE_BLACK_HOLE_VORTEX
                        ? new BlackHoleVortexView(a, accentColor, p.isDark)
                        : null;
        if (vortexView != null) {
            overlay.addView(vortexView, new FrameLayout.LayoutParams(-1, -1));
        }

        final float[] targetLefts = new float[animCount];
        final float[] targetTops = new float[animCount];
        final float[] targetWs = new float[animCount];
        final float[] targetHs = new float[animCount];
        final int estimatedRowH = posterH + a.dp(46);
        for (int i = 0; i < animCount; i++) {
            int col = i % cols;
            int row = i / cols;
            targetLefts[i] = horizPad + col * (cellW + gapPx);
            targetTops[i] = gridTopPad + row * estimatedRowH;
            targetWs[i] = cellW;
            targetHs[i] = posterH;
        }

        // Once the real 3-column grid lays out on frame 1, snap target slots to exact pixel bounds
        wallRoot.getViewTreeObserver()
                .addOnPreDrawListener(
                        new ViewTreeObserver.OnPreDrawListener() {
                            @Override
                            public boolean onPreDraw() {
                                wallRoot.getViewTreeObserver().removeOnPreDrawListener(this);
                                int[] rootLoc = new int[2];
                                wallRoot.getLocationInWindow(rootLoc);
                                int[] boxLoc = new int[2];
                                for (int i = 0; i < animCount && i < gridPosterBoxes.size(); i++) {
                                    FrameLayout box = gridPosterBoxes.get(i);
                                    if (box != null && box.getWidth() > 0 && box.getHeight() > 0) {
                                        box.getLocationInWindow(boxLoc);
                                        targetLefts[i] = boxLoc[0] - rootLoc[0];
                                        targetTops[i] = boxLoc[1] - rootLoc[1];
                                        targetWs[i] = box.getWidth();
                                        targetHs[i] = box.getHeight();
                                    }
                                }
                                return true;
                            }
                        });

        final FrameLayout[] cards = new FrameLayout[animCount];
        for (int i = 0; i < animCount; i++) {
            Cms.Video v = items.get(i);
            FrameLayout card = new FrameLayout(a);
            card.setClipToOutline(true);
            GradientDrawable bg = a.bg(p.bgSubtle, 13);
            bg.setStroke(MobileTheme.hairlinePx(a), 0x2EFFFFFF);
            card.setBackground(bg);
            UiCompat.setElevation(card, a.dp(5f));
            ImageView iv = new ImageView(a);
            iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
            if (v.poster != null && !v.poster.isEmpty()) a.poster(v.poster, iv);
            card.addView(iv, new FrameLayout.LayoutParams(-1, -1));
            card.setPivotX(cellW * 0.5f);
            card.setPivotY(posterH * 0.5f);
            card.setAlpha(0f);
            card.setLayerType(View.LAYER_TYPE_HARDWARE, null);
            overlay.addView(card, new FrameLayout.LayoutParams(cellW, posterH));
            cards[i] = card;
        }
        wallRoot.addView(overlay, new FrameLayout.LayoutParams(-1, -1));

        final float[] elapsed = {0f};
        final int[] hapticStage = {0};
        final MotionLoop.Step[] stepRef = {null};
        final Runnable cleanup =
                () -> {
                    if (stepRef[0] != null) {
                        MotionLoop.remove(stepRef[0]);
                        stepRef[0] = null;
                    }
                    sv.setAlpha(1f);
                    for (FrameLayout c : cards) {
                        if (c != null) c.setLayerType(View.LAYER_TYPE_NONE, null);
                    }
                    if (overlay.getParent() == wallRoot) {
                        wallRoot.removeView(overlay);
                    }
                };

        overlay.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {}

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        if (stepRef[0] != null) {
                            MotionLoop.remove(stepRef[0]);
                            stepRef[0] = null;
                        }
                        sv.setAlpha(1f);
                    }
                });

        stepRef[0] =
                dt -> {
                    if (!UiCompat.isAttached(overlay) || a.isFinishing()) {
                        cleanup.run();
                        return false;
                    }
                    elapsed[0] += Math.min(0.05f, dt);
                    float v = clamp01(elapsed[0] / ENTRANCE_DURATION_SEC);

                    // Subtle tactile beats matching iOS _CuratedGravityWallPage
                    if (hapticStage[0] == 0 && v >= 0.24f) {
                        hapticStage[0] = 1;
                        fireHaptic(wallRoot, HapticFeedbackConstants.CLOCK_TICK);
                    } else if (hapticStage[0] == 1 && v >= 0.44f) {
                        hapticStage[0] = 2;
                        fireHaptic(wallRoot, HapticFeedbackConstants.VIRTUAL_KEY);
                    } else if (hapticStage[0] == 2 && v >= 0.56f) {
                        hapticStage[0] = 3;
                        fireHaptic(wallRoot, HapticFeedbackConstants.KEYBOARD_TAP);
                    }

                    if (vortexView != null) {
                        vortexView.setProgress(v);
                    }

                    float gridAlpha = v < 0.86f ? 0f : clamp01((v - 0.86f) / 0.14f);
                    sv.setAlpha(gridAlpha);

                    float overlayFade = v < 0.90f ? 1f : clamp01(1f - (v - 0.90f) / 0.10f);
                    float liveW = wallRoot.getWidth() > 0 ? wallRoot.getWidth() : screenW;
                    float liveH = wallRoot.getHeight() > 0 ? wallRoot.getHeight() : screenH;

                    for (int i = 0; i < animCount; i++) {
                        PhysicsCardState st =
                                computePhysicsCardState(
                                        style,
                                        i,
                                        animCount,
                                        v,
                                        liveW,
                                        liveH,
                                        density,
                                        targetLefts[i],
                                        targetTops[i],
                                        targetWs[i],
                                        targetHs[i]);
                        FrameLayout card = cards[i];
                        card.setTranslationX(st.centerX - cellW * 0.5f);
                        card.setTranslationY(st.centerY - posterH * 0.5f);
                        card.setScaleX(Math.max(0.05f, st.width / Math.max(1f, cellW)));
                        card.setScaleY(Math.max(0.05f, st.height / Math.max(1f, posterH)));
                        card.setRotation((float) Math.toDegrees(st.angleRad));
                        card.setAlpha(st.opacity * overlayFade);
                    }

                    if (v >= 0.995f) {
                        cleanup.run();
                        return false;
                    }
                    return true;
                };
        MotionLoop.add(stepRef[0]);
    }

    private static void fireHaptic(View v, int constant) {
        if (v == null) return;
        try {
            v.performHapticFeedback(constant);
        } catch (Throwable ignored) {
        }
    }

    private static String shortScoreTag(Cms.Video v) {
        if (v == null || v.remarks == null) return "";
        String r = v.remarks.trim();
        if (r.startsWith("豆瓣 ")) return "豆 " + r.substring(3).trim();
        return r;
    }

    private static String buildCardSubtitle(Cms.Video v) {
        if (v == null) return "";
        String genre = MobileCuratedDiscovery.genreFor(v);
        StringBuilder sb = new StringBuilder();
        if (v.year != null && !v.year.trim().isEmpty()) sb.append(v.year.trim());
        if (!genre.isEmpty()) {
            if (sb.length() > 0) sb.append(" · ");
            sb.append(genre);
        }
        return sb.toString();
    }

    /** Edge-to-edge top ambient accent glow behind status bar &amp; collection header. */
    private static final class AmbientAuraView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int accentColor;
        private final boolean isDark;
        private int lastH = -1;

        AmbientAuraView(MainActivity a, int accentColor, boolean isDark) {
            super(a);
            this.accentColor = accentColor;
            this.isDark = isDark;
            setClickable(false);
            setFocusable(false);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            if (h != lastH) {
                lastH = h;
                paint.setShader(
                        new LinearGradient(
                                0f,
                                0f,
                                0f,
                                h,
                                new int[] {
                                    MobileTheme.withAlpha(accentColor, isDark ? 0x4D : 0x33),
                                    MobileTheme.withAlpha(accentColor, isDark ? 0x1A : 0x0F),
                                    Color.TRANSPARENT
                                },
                                new float[] {0f, 0.56f, 1f},
                                Shader.TileMode.CLAMP));
            }
            canvas.drawRect(0f, 0f, w, h, paint);
        }
    }

    /** Scroll-reactive feathered backdrop behind the floating collection header. */
    private static final class HeaderVeilView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int bgCanvas;
        private float depth = 0f;
        private int lastH = -1;

        HeaderVeilView(MainActivity a, int bgCanvas) {
            super(a);
            this.bgCanvas = bgCanvas;
            setClickable(false);
            setFocusable(false);
        }

        void setDepth(float nextDepth) {
            float clamped = clamp01(nextDepth);
            if (Math.abs(clamped - depth) > 0.01f) {
                depth = clamped;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (depth <= 0.01f) return;
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            if (h != lastH) {
                lastH = h;
                paint.setShader(
                        new LinearGradient(
                                0f,
                                0f,
                                0f,
                                h,
                                new int[] {
                                    MobileTheme.withAlpha(bgCanvas, 0xF0),
                                    MobileTheme.withAlpha(bgCanvas, 0xCC),
                                    Color.TRANSPARENT
                                },
                                new float[] {0f, 0.72f, 1f},
                                Shader.TileMode.CLAMP));
            }
            paint.setAlpha(Math.round(depth * 255f));
            canvas.drawRect(0f, 0f, w, h, paint);
        }
    }

    /**
     * Native Canvas port of iOS {@code _BlackHoleVortexPainter}: renders the gravitational lensing
     * radial glow, 3 counter-rotating glowing accretion arcs, dark singularity core, and supernova
     * expanding shockwave ring.
     */
    private static final class BlackHoleVortexView extends View {
        private final MainActivity a;
        private final int accentColor;
        private final boolean isDark;
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF arcRect = new RectF();
        private float progress = 0f;

        BlackHoleVortexView(MainActivity a, int accentColor, boolean isDark) {
            super(a);
            this.a = a;
            this.accentColor = accentColor;
            this.isDark = isDark;
            strokePaint.setStyle(Paint.Style.STROKE);
            strokePaint.setStrokeCap(Paint.Cap.ROUND);
            setClickable(false);
            setFocusable(false);
        }

        void setProgress(float p) {
            this.progress = clamp01(p);
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (progress <= 0f || progress >= 0.80f) return;
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;

            float cx = w * 0.50f;
            float cy = h * 0.44f;

            float corePulse;
            if (progress < 0.42f) {
                corePulse = easeOutCubic(progress / 0.42f);
            } else if (progress < 0.52f) {
                corePulse = 1f;
            } else if (progress < 0.62f) {
                corePulse = 1f - easeInCubic((progress - 0.52f) / 0.10f);
            } else {
                corePulse = 0f;
            }

            if (corePulse > 0.01f) {
                float coreR = lerp(a.dp(8), a.dp(46), corePulse);
                float glowR = coreR * 2.8f;

                fillPaint.setShader(
                        new RadialGradient(
                                cx,
                                cy,
                                Math.max(1f, glowR),
                                new int[] {
                                    MobileTheme.withAlpha(
                                            accentColor,
                                            Math.round((isDark ? 0.55f : 0.38f) * corePulse * 255)),
                                    MobileTheme.withAlpha(
                                            accentColor, Math.round(0.18f * corePulse * 255)),
                                    Color.TRANSPARENT
                                },
                                new float[] {0f, 0.50f, 1f},
                                Shader.TileMode.CLAMP));
                canvas.drawCircle(cx, cy, glowR, fillPaint);
                fillPaint.setShader(null);

                // 3 rotating glowing accretion arcs
                for (int r = 0; r < 3; r++) {
                    float ringR = coreR * (1.15f + r * 0.48f);
                    float startDeg =
                            (float)
                                    Math.toDegrees(
                                            progress * 12.0f * (r % 2 == 0 ? 1f : -1f) + r * 2.1f);
                    float sweepDeg = (float) Math.toDegrees(1.9f + r * 0.5f);
                    strokePaint.setColor(
                            MobileTheme.withAlpha(
                                    r == 0 ? Color.WHITE : accentColor,
                                    Math.round((0.55f - r * 0.14f) * corePulse * 255)));
                    strokePaint.setStrokeWidth(a.dp(2.6f - r * 0.5f));
                    arcRect.set(cx - ringR, cy - ringR, cx + ringR, cy + ringR);
                    canvas.drawArc(arcRect, startDeg, sweepDeg, false, strokePaint);
                }

                // Event horizon black singularity core + luminous rim
                fillPaint.setColor(
                        MobileTheme.withAlpha(0xFF06070A, Math.round(0.92f * corePulse * 255)));
                canvas.drawCircle(cx, cy, coreR * 0.72f, fillPaint);

                strokePaint.setColor(
                        MobileTheme.withAlpha(accentColor, Math.round(0.85f * corePulse * 255)));
                strokePaint.setStrokeWidth(a.dp(2.2f));
                canvas.drawCircle(cx, cy, coreR * 0.74f, strokePaint);
            }

            // Supernova shockwave ring expanding outward at v in [0.50, 0.78]
            if (progress >= 0.50f && progress <= 0.78f) {
                float shockT = (progress - 0.50f) / 0.28f;
                float shockR = lerp(a.dp(16), Math.max(w, h) * 0.65f, easeOutCubic(shockT));
                float shockAlpha = (1f - shockT) * (1f - shockT);
                strokePaint.setColor(
                        MobileTheme.withAlpha(accentColor, Math.round(0.75f * shockAlpha * 255)));
                strokePaint.setStrokeWidth(lerp(a.dp(5f), a.dp(1f), shockT));
                canvas.drawCircle(cx, cy, shockR, strokePaint);
            }
        }
    }
}

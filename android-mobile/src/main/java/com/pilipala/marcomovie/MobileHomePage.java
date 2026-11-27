package com.pilipala.marcomovie;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.TextUtils;
import android.text.style.ForegroundColorSpan;
import android.text.style.StyleSpan;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Redesigned Mobile Discovery Home (Day/Night {@link MobileTheme} + {@link MobileIcons} +
 * {@link MobileMotion}):
 * - Mode 0 ({@code 片源界面}): Top borderless source/depot capsules + vector funnel filter button
 *   (opening {@link MobileFilterSheet}), sticky borderless category pills, optional hero banner,
 *   Continue Watching strip, 0-hit filter recovery CTA, and 3/5-column {@code 2:3} poster wall.
 * - Mode 1 ({@code 全球热门趋势}): Trending / Popular TV / Popular Movies / Top Rated shelves with
 *   pure vector shelf badges; tapping any title immediately cross-searches active CMS sources.
 */
final class MobileHomePage {
    private static String selectedCategoryId = "";
    private static String lastSiteKey = "";
    private static final Map<String, String> selectedFilters = new LinkedHashMap<>();
    private static String dismissedClipboardText = "";

    interface LoadingMarkerStore {
        void writeMarker(String siteKey);
    }

    /**
     * Request-owned loading-site crash guard: ensures an older slow request finishing after a newer
     * request started can never clear the newer request's marker, and normal backgrounding clears
     * the marker cleanly so OS process reclaim is never misclassified as a crash.
     */
    static final class LoadingSiteGuard {
        private final AtomicLong seq = new AtomicLong(0L);
        private final Object lock = new Object();
        private long activeToken = 0L;
        private String activeSite = "";
        private Thread activeThread = null;

        long acquire(LoadingMarkerStore store, String siteKey) {
            String clean = siteKey == null ? "" : siteKey;
            synchronized (lock) {
                long token = seq.incrementAndGet();
                activeToken = token;
                activeSite = clean;
                activeThread = Thread.currentThread();
                MainActivity.registerActiveSourceLoadThread(activeThread, token, clean);
                if (store != null) {
                    store.writeMarker(clean);
                }
                return token;
            }
        }

        boolean releaseIfOwner(LoadingMarkerStore store, long token) {
            MainActivity.unregisterActiveSourceLoadThread(Thread.currentThread(), token);
            synchronized (lock) {
                if (token <= 0L || activeToken != token) {
                    return false;
                }
                MainActivity.unregisterActiveSourceLoadThread(activeThread, token);
                activeToken = 0L;
                activeSite = "";
                activeThread = null;
                if (store != null) {
                    store.writeMarker("");
                }
                return true;
            }
        }

        void clearOnNormalStop(LoadingMarkerStore store) {
            synchronized (lock) {
                MainActivity.unregisterActiveSourceLoadThread(activeThread, activeToken);
                activeToken = 0L;
                activeSite = "";
                activeThread = null;
                if (store != null) {
                    store.writeMarker("");
                }
            }
        }

        String activeSiteForTest() {
            synchronized (lock) {
                return activeSite;
            }
        }
    }

    private static final LoadingSiteGuard LOADING_GUARD = new LoadingSiteGuard();

    private MobileHomePage() {}

    private static void commitLoadingSite(MainActivity a, String siteKey) {
        if (a == null || a.prefs == null) return;
        a.prefs.edit().putString(Prefs.LOADING_SITE, siteKey == null ? "" : siteKey).commit();
    }

    private static void applyClearLoadingSite(MainActivity a) {
        if (a == null || a.prefs == null) return;
        a.prefs.edit().putString(Prefs.LOADING_SITE, "").apply();
    }

    static void clearLoadingSiteOnNormalStop(MainActivity a) {
        LOADING_GUARD.clearOnNormalStop(key -> applyClearLoadingSite(a));
    }

    static boolean hasAnyPoster(List<Cms.Video> videos) {
        if (videos == null || videos.isEmpty()) return false;
        for (Cms.Video v : videos) {
            if (v != null && v.poster != null && !v.poster.trim().isEmpty()) {
                return true;
            }
        }
        return false;
    }

    /**
     * Resolves initial home listings for both XML/JSON CMS and script sources. Standard Apple CMS
     * v10 {@code ?ac=list} omits {@code vod_pic}; when the home response contains videos without
     * any poster URL, enriches via {@link SourceEngine#homeVideos()} ({@code ?ac=detail&pg=1}) or
     * the first category before falling back to the posterless list.
     */
    static Cms.Listing resolveHomeListing(
            SourceEngine eng, String homeRaw, List<Cms.Category> parsedCats) throws Exception {
        Cms.Listing cand = HomeScreen.parseHomeListing(homeRaw);
        boolean hasPosters = hasAnyPoster(cand.videos);
        Throwable homeVideosError = null;
        boolean categoryAttempted = false;
        boolean categorySucceeded = false;
        Throwable categoryError = null;
        if (cand.videos.isEmpty() || !hasPosters) {
            try {
                Cms.Listing enriched = Cms.listing(eng.homeVideos());
                if (!enriched.videos.isEmpty()
                        && (cand.videos.isEmpty() || hasAnyPoster(enriched.videos))) {
                    cand = enriched;
                    hasPosters = hasAnyPoster(cand.videos);
                }
            } catch (Throwable err) {
                homeVideosError = err;
            }
        }
        if ((cand.videos.isEmpty() || !hasPosters) && parsedCats != null && !parsedCats.isEmpty()) {
            categoryAttempted = true;
            try {
                Cms.Listing byCat = Cms.listing(eng.category(parsedCats.get(0).id, 1));
                categorySucceeded = true;
                if (!byCat.videos.isEmpty()
                        && (cand.videos.isEmpty() || hasAnyPoster(byCat.videos))) {
                    cand = byCat;
                }
            } catch (Throwable err) {
                categoryError = err;
            }
        }
        if (cand.videos.isEmpty()) {
            Throwable primaryError =
                    categoryAttempted
                            ? (!categorySucceeded ? categoryError : null)
                            : homeVideosError;
            if (primaryError != null) {
                if (primaryError instanceof Exception) {
                    throw (Exception) primaryError;
                }
                throw new IOException(
                        primaryError.getMessage() != null ? primaryError.getMessage() : "列表读取失败",
                        primaryError);
            }
        }
        return cand;
    }

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        if (a.config == null || shell.activeSite == null) {
            String skipped =
                    a.prefs != null ? a.prefs.getString(Prefs.RECOVERED_SKIP_SITE, "") : "";
            if (a.config != null && skipped != null && !skipped.trim().isEmpty()) {
                renderCrashRecoveryEmpty(shell, container, skipped.trim());
                return;
            }
            renderCuratedDiscoveryHome(shell, container);
            return;
        }
        renderSourceHome(shell, container, shell.activeSite);
    }

    private static String detectClipboardCandidate(MainActivity a) {
        try {
            ClipboardManager cm = (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm == null || !cm.hasPrimaryClip()) return null;
            ClipData clip = cm.getPrimaryClip();
            if (clip == null || clip.getItemCount() <= 0 || clip.getItemAt(0).getText() == null) {
                return null;
            }
            String text = clip.getItemAt(0).getText().toString().trim();
            if (text.isEmpty() || text.equals(dismissedClipboardText)) return null;
            return UiWidgets.classifyImportCandidate(text) != null ? text : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static void renderCrashRecoveryEmpty(
            final MobileRootShell shell, final FrameLayout container, final String skippedSiteKey) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setFillViewport(true);
        LinearLayout box = a.vertical();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(
                a.dp(24),
                a.statusBarHeight() + a.dp(48),
                a.dp(24),
                a.navigationBarHeight() + a.dp(110));

        FrameLayout iconBadge =
                MobileIcons.badge(a, MobileIcons.IC_SWITCH_SOURCE, p.warning, 52, 26);
        box.addView(iconBadge, new LinearLayout.LayoutParams(a.dp(52), a.dp(52)));
        a.gap(box, 14);

        TextView badge = a.text("崩溃保护已生效", 12, p.warning);
        badge.setTypeface(null, Typeface.BOLD);
        box.addView(badge);
        a.gap(box, 8);

        String skippedName = skippedSiteKey;
        if (a.config != null) {
            for (Cms.Site s : a.config.sites) {
                if (s != null
                        && skippedSiteKey.equals(s.key)
                        && s.name != null
                        && !s.name.isEmpty()) {
                    skippedName = s.name;
                    break;
                }
            }
        }
        TextView headline = a.text("已暂停自动加载异常片源", 21, p.textPrimary);
        headline.setTypeface(null, Typeface.BOLD);
        headline.setGravity(Gravity.CENTER);
        box.addView(headline);
        a.gap(box, 10);

        TextView desc =
                a.text(
                        "上次加载「" + skippedName + "」时发生异常退出，当前配置内暂无其他可用站。请切换或导入其他片源，也可手动重试。",
                        13.5f,
                        p.textSecondary);
        desc.setGravity(Gravity.CENTER);
        desc.setLineSpacing(0, 1.38f);
        box.addView(desc);
        a.gap(box, 24);

        addPillAction(
                a,
                box,
                MobileIcons.IC_SWITCH_SOURCE,
                "切换片源 / 管理线路",
                p.accent,
                p.accentOnFill,
                () -> shell.showQuickSourceAndModeSheet());
        a.gap(box, 10);
        addPillAction(
                a,
                box,
                MobileIcons.IC_REFRESH,
                "手动重试该片源",
                p.bgCard,
                p.textPrimary,
                () -> {
                    a.prefs
                            .edit()
                            .putString(Prefs.RECOVERED_SKIP_SITE, "")
                            .putString(Prefs.SELECTED_SITE, skippedSiteKey)
                            .apply();
                    shell.switchTab(MobileRootShell.TAB_HOME);
                });
        a.gap(box, 10);
        addPillAction(
                a,
                box,
                MobileIcons.IC_FOLDER,
                "导入其他配置网址 / 本地包",
                p.bgSubtle,
                p.accent,
                () -> UiWidgets.showMobileImportDialog(a));

        sv.addView(box, new ScrollView.LayoutParams(-1, -2));
        container.addView(sv, new FrameLayout.LayoutParams(-1, -1));
    }

    private static void renderEmptyWelcome(MobileRootShell shell, FrameLayout container) {
        MainActivity a = shell.a;
        MobileTheme.Palette p = MobileTheme.of(a);
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setFillViewport(true);
        LinearLayout box = a.vertical();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(
                a.dp(24),
                a.statusBarHeight() + a.dp(44),
                a.dp(24),
                a.navigationBarHeight() + a.dp(110));

        // Smart 1-tap clipboard source detection banner (non-blocking, dismissible)
        final String detectedClip = detectClipboardCandidate(a);
        if (detectedClip != null) {
            String kind = UiWidgets.classifyImportCandidate(detectedClip);
            String preview = detectedClip.replace('\n', ' ').replace('\r', ' ').trim();
            if (preview.length() > 54) preview = preview.substring(0, 54) + "…";

            final LinearLayout banner = a.vertical();
            banner.setBackground(MobileTheme.cardBg(a, 18));
            if (!p.isDark) UiCompat.setElevation(banner, a.dp(3f));
            banner.setPadding(a.dp(14), a.dp(13), a.dp(14), a.dp(13));

            LinearLayout top = a.row();
            top.setGravity(Gravity.CENTER_VERTICAL);
            FrameLayout bIcon = MobileIcons.badge(a, MobileIcons.IC_CLIPBOARD, p.accent, 34, 17);
            LinearLayout.LayoutParams biLp = new LinearLayout.LayoutParams(a.dp(34), a.dp(34));
            biLp.rightMargin = a.dp(10);
            top.addView(bIcon, biLp);

            LinearLayout copyCol = a.vertical();
            TextView bTitle = a.text("发现剪贴板中的" + kind, 14f, p.textPrimary);
            bTitle.setTypeface(null, Typeface.BOLD);
            copyCol.addView(bTitle);
            TextView bSub = a.text(preview, 12f, p.textSecondary);
            bSub.setSingleLine(true);
            bSub.setEllipsize(TextUtils.TruncateAt.MIDDLE);
            bSub.setPadding(0, a.dp(2), 0, 0);
            copyCol.addView(bSub);
            top.addView(copyCol, new LinearLayout.LayoutParams(0, -2, 1f));
            banner.addView(top, new LinearLayout.LayoutParams(-1, -2));

            LinearLayout btnRow = a.row();
            btnRow.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            btnRow.setPadding(0, a.dp(11), 0, 0);

            TextView ignoreBtn = a.text("忽略", 13f, p.textSecondary);
            ignoreBtn.setTypeface(null, Typeface.BOLD);
            ignoreBtn.setPadding(a.dp(14), a.dp(7), a.dp(14), a.dp(7));
            ignoreBtn.setBackground(MobileTheme.subtleBg(a, 999));
            MobileMotion.bindPress(ignoreBtn, 0.94f);
            ignoreBtn.setOnClickListener(
                    v -> {
                        dismissedClipboardText = detectedClip;
                        MobileMotion.crossfadeVisibility(
                                banner, false, -6f, 0.96f, MotionTokens.DURATION_FAST_MS, false);
                    });
            LinearLayout.LayoutParams igLp = new LinearLayout.LayoutParams(-2, -2);
            igLp.rightMargin = a.dp(8);
            btnRow.addView(ignoreBtn, igLp);

            TextView importNow = a.text("立即导入", 13f, p.accentOnFill);
            importNow.setTypeface(null, Typeface.BOLD);
            importNow.setPadding(a.dp(16), a.dp(7), a.dp(16), a.dp(7));
            importNow.setBackground(MobileTheme.accentPillBg(a, 999));
            MobileMotion.bindPress(importNow, 0.94f);
            importNow.setOnClickListener(v -> UiWidgets.pasteConfigFromClipboard(a));
            btnRow.addView(importNow);

            banner.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));
            LinearLayout.LayoutParams banLp = new LinearLayout.LayoutParams(-1, -2);
            banLp.bottomMargin = a.dp(24);
            box.addView(banner, banLp);
        }

        ImageView emblem = new ImageView(a);
        emblem.setTag("home-brand");
        emblem.setImageResource(R.drawable.logo_mark);
        emblem.setScaleType(ImageView.ScaleType.FIT_CENTER);
        box.addView(emblem, new LinearLayout.LayoutParams(a.dp(60), a.dp(60)));
        a.gap(box, 10);

        TextView welcomeWordmark = buildWordmarkTextView(a, 20f, p.isDark, false);
        welcomeWordmark.setGravity(Gravity.CENTER);
        box.addView(welcomeWordmark);
        a.gap(box, 14);

        TextView badge = a.text("纯净私享影院 · 随时开播", 12f, p.accent);
        badge.setTypeface(null, Typeface.BOLD);
        box.addView(badge);
        a.gap(box, 8);

        TextView headline = a.text("把今晚，留给好故事。", 26, p.textPrimary);
        headline.setTypeface(null, Typeface.BOLD);
        headline.setGravity(Gravity.CENTER);
        box.addView(headline);
        a.gap(box, 10);

        TextView desc = a.text(MainActivity.TOOL_DECLARATION, 13, p.textSecondary);
        desc.setGravity(Gravity.CENTER);
        desc.setLineSpacing(0, 1.4f);
        box.addView(desc);
        a.gap(box, 26);

        if (detectedClip == null) {
            addPillAction(
                    a,
                    box,
                    MobileIcons.IC_CLIPBOARD,
                    "从剪贴板一键导入片源",
                    p.accent,
                    p.accentOnFill,
                    () -> UiWidgets.pasteConfigFromClipboard(a));
            a.gap(box, 10);
        }
        addPillAction(
                a,
                box,
                MobileIcons.IC_FOLDER,
                "添加网址或本地片源包",
                detectedClip != null ? p.accent : p.bgCard,
                detectedClip != null ? p.accentOnFill : p.textPrimary,
                () -> UiWidgets.showMobileImportDialog(a));
        a.gap(box, 10);
        addPillAction(
                a,
                box,
                MobileIcons.IC_SPARKLE,
                "先逛逛最近热门片单",
                p.bgSubtle,
                p.accent,
                () -> {
                    a.mobilePrefs().edit().putInt(Prefs.HOME_MODE, 1).apply();
                    shell.switchTab(MobileRootShell.TAB_HOME);
                });

        sv.addView(box, new ScrollView.LayoutParams(-1, -2));
        container.addView(sv, new FrameLayout.LayoutParams(-1, -1));
    }

    private static void addPillAction(
            MainActivity a,
            LinearLayout parent,
            int iconId,
            String text,
            int bgColor,
            int textColor,
            Runnable action) {
        LinearLayout btn = a.row();
        btn.setGravity(Gravity.CENTER);
        btn.setPadding(a.dp(18), a.dp(13), a.dp(18), a.dp(13));
        btn.setBackground(a.bg(bgColor, 999));

        if (iconId != 0) {
            MobileIcons.IconView iv = MobileIcons.create(a, iconId, 16f, textColor);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(a.dp(16), a.dp(16));
            ilp.rightMargin = a.dp(8);
            btn.addView(iv, ilp);
        }

        TextView lbl = a.text(text, 14, textColor);
        lbl.setTypeface(null, Typeface.BOLD);
        lbl.setSingleLine(true);
        lbl.setEllipsize(TextUtils.TruncateAt.END);
        btn.addView(lbl);

        MobileMotion.bindPress(btn, 0.96f);
        btn.setOnClickListener(v -> action.run());
        parent.addView(btn, new LinearLayout.LayoutParams(-1, -2));
    }

    /**
     * Pure-JVM height formula for the full-bleed iOS-style immersive Home cinema Hero billboard
     * (~56% of viewport height, clamped between {@code minPx} and {@code maxPx}).
     */
    static int computeImmersiveHeroHeightPx(int screenHeightPx, int minPx, int maxPx) {
        if (screenHeightPx <= 0) return minPx;
        int raw = Math.round(screenHeightPx * 0.56f);
        return Math.max(minPx, Math.min(maxPx, raw));
    }

    /**
     * Pure-JVM Rex-style poster atmospheric harmonizer matching iOS {@code
     * _resolveRexHeroAtmosphere}:
     *
     * <ul>
     *   <li>Dark Mode: deep cinema tone ({@code L ∈ [0.11, 0.20]}) dissolving effortlessly into
     *       Obsidian.
     *   <li>Light Mode: preserves natural poster warmth/richness ({@code L ∈ [0.24, 0.62]}) so the
     *       Hero flows continuously behind the first shelf into Alabaster with zero black-to-white
     *       cliff.
     * </ul>
     */
    static int resolveRexHeroAtmosphere(int seedColor, boolean isDark) {
        float r = ((seedColor >> 16) & 0xFF) / 255f;
        float g = ((seedColor >> 8) & 0xFF) / 255f;
        float b = (seedColor & 0xFF) / 255f;
        float max = Math.max(r, Math.max(g, b));
        float min = Math.min(r, Math.min(g, b));
        float l = (max + min) * 0.5f;
        float s;
        float h;
        float d = max - min;
        if (d < 1e-5f) {
            h = 0f;
            s = 0f;
        } else {
            s = l > 0.5f ? d / (2f - max - min) : d / (max + min);
            if (max == r) {
                h = ((g - b) / d) + (g < b ? 6f : 0f);
            } else if (max == g) {
                h = ((b - r) / d) + 2f;
            } else {
                h = ((r - g) / d) + 4f;
            }
            h /= 6f;
        }
        boolean hasChroma = s >= 0.06f;
        float targetS;
        float targetL;
        if (isDark) {
            targetS = hasChroma ? Math.max(0.16f, Math.min(0.50f, s * 1.12f)) : 0.06f;
            targetL = Math.max(0.11f, Math.min(0.20f, l * 0.62f));
        } else {
            targetS = hasChroma ? Math.max(0.12f, Math.min(0.46f, s * 1.02f)) : 0.06f;
            targetL = Math.max(0.24f, Math.min(0.62f, l));
        }
        return hslToOpaqueArgb(h, targetS, targetL);
    }

    private static int hslToOpaqueArgb(float h, float s, float l) {
        float c = (1f - Math.abs(2f * l - 1f)) * s;
        float x = c * (1f - Math.abs((h * 6f) % 2f - 1f));
        float m = l - c * 0.5f;
        float rf, gf, bf;
        float h6 = h * 6f;
        if (h6 < 1f) {
            rf = c;
            gf = x;
            bf = 0f;
        } else if (h6 < 2f) {
            rf = x;
            gf = c;
            bf = 0f;
        } else if (h6 < 3f) {
            rf = 0f;
            gf = c;
            bf = x;
        } else if (h6 < 4f) {
            rf = 0f;
            gf = x;
            bf = c;
        } else if (h6 < 5f) {
            rf = x;
            gf = 0f;
            bf = c;
        } else {
            rf = c;
            gf = 0f;
            bf = x;
        }
        int ri = Math.max(0, Math.min(255, Math.round((rf + m) * 255f)));
        int gi = Math.max(0, Math.min(255, Math.round((gf + m) * 255f)));
        int bi = Math.max(0, Math.min(255, Math.round((bf + m) * 255f)));
        return 0xFF000000 | (ri << 16) | (gi << 8) | bi;
    }

    /** Pure-JVM adaptive ink decision matching iOS {@code _useLightInkForHeroAtmo}. */
    static boolean useLightInkForHeroAtmo(int atmoColor, boolean isDark) {
        if (isDark) return true;
        double r = linearizeChannel(((atmoColor >> 16) & 0xFF) / 255.0);
        double g = linearizeChannel(((atmoColor >> 8) & 0xFF) / 255.0);
        double b = linearizeChannel((atmoColor & 0xFF) / 255.0);
        double lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        return lum < 0.27;
    }

    private static double linearizeChannel(double c) {
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }

    /**
     * Pure-JVM swipe release target page decision for {@link HeroPagerView}: commits adjacent slide
     * on crisp fling ({@code |velocityX| >= 480 px/s}) or drag distance ({@code >= 22%} page width).
     */
    static int resolveHeroSwipeTargetPage(
            int currentIdx, int pageCount, float dragDeltaX, float velocityX, int pageWidthPx) {
        if (pageCount <= 1) return 0;
        int cur = Math.max(0, Math.min(pageCount - 1, currentIdx));
        float distThresh = Math.max(1f, pageWidthPx * 0.22f);
        int target = cur;
        if (velocityX <= -480f || dragDeltaX <= -distThresh) {
            target = cur + 1;
        } else if (velocityX >= 480f || dragDeltaX >= distThresh) {
            target = cur - 1;
        }
        return Math.max(0, Math.min(pageCount - 1, target));
    }

    /** Builds the iOS-style two-tone {@code Marco Movie} wordmark {@link TextView}. */
    private static TextView buildWordmarkTextView(
            MainActivity a, float sizeSp, boolean useLightInk, boolean withShadow) {
        TextView tv = new TextView(a);
        tv.setTextSize(sizeSp);
        tv.setIncludeFontPadding(false);
        tv.setSingleLine(true);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        applyWordmarkInk(a, tv, useLightInk, withShadow);
        return tv;
    }

    private static void applyWordmarkInk(
            MainActivity a, TextView tv, boolean useLightInk, boolean withShadow) {
        if (tv == null) return;
        SpannableStringBuilder ssb = new SpannableStringBuilder("Marco Movie");
        int primary = useLightInk ? 0xFFF8FAFC : 0xFF111114;
        int secondary = useLightInk ? 0xFFD8E0EE : 0xFF63636C;
        ssb.setSpan(new StyleSpan(Typeface.BOLD), 0, 5, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        ssb.setSpan(new ForegroundColorSpan(primary), 0, 5, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        ssb.setSpan(new ForegroundColorSpan(secondary), 5, 11, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        tv.setText(ssb);
        if (withShadow) {
            tv.setShadowLayer(a.dp(4.5f), 0f, a.dp(1.2f), 0x8C000000);
        } else {
            tv.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT);
        }
    }

    /**
     * Builds the authentic iOS-style {@code Marco Movie} brand lockup: direct metallic film-ribbon
     * {@code R.drawable.logo_mark} + signature two-tone {@code Marco Movie} wordmark (zero square
     * box wrapper).
     */
    private static LinearLayout buildBrandWordmark(
            MainActivity a,
            boolean useLightInk,
            boolean withShadow,
            TextView[] wordmarkOut,
            Runnable onTap) {
        LinearLayout row = a.row();
        row.setTag("home-brand");
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(a.dp(36));

        ImageView mark = new ImageView(a);
        mark.setImageResource(R.drawable.logo_mark);
        mark.setScaleType(ImageView.ScaleType.FIT_CENTER);
        LinearLayout.LayoutParams ml = new LinearLayout.LayoutParams(a.dp(30), a.dp(30));
        ml.rightMargin = a.dp(6);
        row.addView(mark, ml);

        TextView wordmark = buildWordmarkTextView(a, 17f, useLightInk, withShadow);
        if (wordmarkOut != null && wordmarkOut.length > 0) {
            wordmarkOut[0] = wordmark;
        }
        row.addView(wordmark, new LinearLayout.LayoutParams(-2, -2));

        if (onTap != null) {
            MobileMotion.bindPress(row, 0.94f);
            row.setOnClickListener(
                    v -> {
                        MobileMotion.popBounce(row);
                        onTap.run();
                    });
        }
        return row;
    }

    private static void renderSourceHome(
            final MobileRootShell shell, final FrameLayout container, final Cms.Site site) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        if (!site.key.equals(lastSiteKey)) {
            lastSiteKey = site.key;
            selectedCategoryId = "";
            selectedFilters.clear();
        }
        shell.setAmbientColor(SeasonParser.defaultAmbientForTitle(site.name));

        final int heroHeightPx =
                computeImmersiveHeroHeightPx(a.windowHeight(), a.dp(420), a.dp(540));

        // Full-bleed edge-to-edge stage: Hero billboard starts at physical screen y = 0 right
        // underneath the transparent status bar & floating iOS-style brand header.
        FrameLayout page = new FrameLayout(a);
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        // 1. Scrollable full-bleed content area (bottom layer)
        // Wrap HeroAtmosphereView BEHIND body inside scrollContentHost so the continuous Rex aura
        // flows behind the Hero and first shelf without EVER stretching gaps between body children
        // (fixing extra blank space below category/filter bar when Continue Watching is hidden!).
        final ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);
        FrameLayout scrollContentHost = new FrameLayout(a);
        final HeroAtmosphereView heroAtmosphereView =
                new HeroAtmosphereView(a, heroHeightPx, a.dp(24), a.dp(168));
        heroAtmosphereView.setVisibility(View.GONE);
        scrollContentHost.addView(
                heroAtmosphereView,
                new FrameLayout.LayoutParams(-1, heroHeightPx + a.dp(192), Gravity.TOP));

        final LinearLayout body = a.vertical();
        final int standardTopPad = a.statusBarHeight() + a.dp(56);
        final int bottomPad = a.navigationBarHeight() + a.dp(108);
        body.setPadding(0, standardTopPad, 0, bottomPad);
        scrollContentHost.addView(body, new FrameLayout.LayoutParams(-1, -2));
        sv.addView(scrollContentHost, new ScrollView.LayoutParams(-1, -2));
        page.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        // Full-bleed Immersive Cinema Hero slot (placed first at y = 0 when on "推荐")
        final FrameLayout heroHolder = new FrameLayout(a);
        heroHolder.setVisibility(View.GONE);
        body.addView(heroHolder, new LinearLayout.LayoutParams(-1, -2));

        // Continue watching horizontal strip (shown on "推荐" tab when history exists)
        final LinearLayout historyWrap = a.vertical();
        body.addView(historyWrap, new LinearLayout.LayoutParams(-1, -2));
        renderContinueWatchingStrip(a, historyWrap);

        // Fixed iOS-style 6-module Curated Editorial Discovery (光影风向标 / 月度策划 / 热播剧影榜 /
        // 灵感片单 / 影业档案室 / 口碑典藏馆) — always displayed on Home regardless of source switcher
        final LinearLayout curatedWrap = a.vertical();
        curatedWrap.setPadding(0, a.dp(8), 0, a.dp(6));
        body.addView(curatedWrap, new LinearLayout.LayoutParams(-1, -2));

        // Source Catalog section header (shown above category bar on "推荐" tab)
        final LinearLayout sourceCatalogHeader = a.row();
        sourceCatalogHeader.setGravity(Gravity.CENTER_VERTICAL);
        sourceCatalogHeader.setPadding(a.dp(16), a.dp(18), a.dp(16), a.dp(6));
        TextView scTitle = a.text("片源片单", 18f, p.textPrimary);
        scTitle.setTypeface(null, Typeface.BOLD);
        sourceCatalogHeader.addView(scTitle);
        TextView scSiteBadge = a.text(site.name, 11f, p.textSecondary);
        scSiteBadge.setSingleLine(true);
        scSiteBadge.setEllipsize(TextUtils.TruncateAt.END);
        scSiteBadge.setPadding(a.dp(8), a.dp(2.5f), a.dp(8), a.dp(2.5f));
        scSiteBadge.setBackground(MobileTheme.subtleBg(a, 999));
        LinearLayout.LayoutParams scbLp = new LinearLayout.LayoutParams(-2, -2);
        scbLp.leftMargin = a.dp(8);
        sourceCatalogHeader.addView(scSiteBadge, scbLp);
        body.addView(sourceCatalogHeader, new LinearLayout.LayoutParams(-1, -2));

        // Inline Category Chips + Vector Filter Button (tight spacing above poster grid)
        LinearLayout categoryBarWrap = a.row();
        categoryBarWrap.setGravity(Gravity.CENTER_VERTICAL);
        categoryBarWrap.setPadding(a.dp(16), a.dp(4), a.dp(16), a.dp(8));

        HorizontalScrollView catScroll = new HorizontalScrollView(a);
        catScroll.setHorizontalScrollBarEnabled(false);
        catScroll.setClipToPadding(false);
        final LinearLayout catRow = a.row();
        catScroll.addView(catRow);
        LinearLayout.LayoutParams csLp = new LinearLayout.LayoutParams(0, -2, 1f);
        csLp.rightMargin = a.dp(8);
        categoryBarWrap.addView(catScroll, csLp);

        // Right vector funnel filter button (shows animated accent count badge when active)
        final LinearLayout filterBtn = a.row();
        filterBtn.setGravity(Gravity.CENTER_VERTICAL);
        filterBtn.setPadding(a.dp(11), a.dp(7), a.dp(11), a.dp(7));
        filterBtn.setBackground(MobileTheme.cardBg(a, 999));
        if (!p.isDark) UiCompat.setElevation(filterBtn, a.dp(2f));
        filterBtn.setVisibility(View.GONE);

        final MobileIcons.IconView filterIcon =
                MobileIcons.create(a, MobileIcons.IC_FILTER, 14.5f, p.textPrimary);
        LinearLayout.LayoutParams fiLp = new LinearLayout.LayoutParams(a.dp(14.5f), a.dp(14.5f));
        fiLp.rightMargin = a.dp(5);
        filterBtn.addView(filterIcon, fiLp);

        final TextView filterText = a.text("筛选", 12.5f, p.textPrimary);
        filterText.setTypeface(null, Typeface.BOLD);
        filterBtn.addView(filterText);

        final TextView filterCountBadge = a.text("", 10.5f, p.accentOnFill);
        filterCountBadge.setTypeface(null, Typeface.BOLD);
        filterCountBadge.setGravity(Gravity.CENTER);
        filterCountBadge.setMinWidth(a.dp(17));
        filterCountBadge.setPadding(a.dp(5), a.dp(1), a.dp(5), a.dp(1));
        filterCountBadge.setVisibility(View.GONE);
        LinearLayout.LayoutParams fcLp = new LinearLayout.LayoutParams(-2, a.dp(17));
        fcLp.leftMargin = a.dp(5);
        filterBtn.addView(filterCountBadge, fcLp);

        MobileMotion.bindPress(filterBtn, 0.93f);
        categoryBarWrap.addView(filterBtn, new LinearLayout.LayoutParams(-2, -2));
        body.addView(categoryBarWrap, new LinearLayout.LayoutParams(-1, -2));

        // 2. Floating iOS-style Top Brand Header (Marco Movie wordmark + Source switcher)
        final LinearLayout floatingTopBar = a.vertical();
        floatingTopBar.setPadding(a.dp(16), a.statusBarHeight() + a.dp(6), a.dp(16), a.dp(10));
        page.addView(floatingTopBar, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        final TextView[] brandWordmarkRef = {null};
        LinearLayout brandLockup =
                buildBrandWordmark(
                        a,
                        p.isDark,
                        false,
                        brandWordmarkRef,
                        () -> {
                            if (sv.getScrollY() > a.dp(16)) {
                                sv.smoothScrollTo(0, 0);
                            } else {
                                shell.showQuickSourceAndModeSheet();
                            }
                        });
        LinearLayout.LayoutParams brandLp = new LinearLayout.LayoutParams(-2, -2);
        brandLp.rightMargin = a.dp(8);
        topRow.addView(brandLockup, brandLp);

        topRow.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        // Multi-depot switcher pill (only surfaced when > 1 warehouse exists)
        final LinearLayout depotPill;
        final MobileIcons.IconView depotIcon;
        final TextView depotLbl;
        if (a.config != null && a.config.depots != null && a.config.depots.length() > 1) {
            depotPill = a.row();
            depotPill.setGravity(Gravity.CENTER_VERTICAL);
            depotPill.setPadding(a.dp(10), 0, a.dp(10), 0);
            depotPill.setBackground(MobileTheme.subtleBg(a, 999));

            depotIcon = MobileIcons.create(a, MobileIcons.IC_FOLDER, 12.5f, p.accent);
            LinearLayout.LayoutParams diLp =
                    new LinearLayout.LayoutParams(a.dp(12.5f), a.dp(12.5f));
            diLp.rightMargin = a.dp(4);
            depotPill.addView(depotIcon, diLp);

            depotLbl = a.text("多仓", 12f, p.accent);
            depotLbl.setTypeface(null, Typeface.BOLD);
            depotPill.addView(depotLbl);

            MobileMotion.bindPress(depotPill, 0.94f);
            depotPill.setOnClickListener(v -> SourcePicker.showWarehouses(a));
            LinearLayout.LayoutParams dLp = new LinearLayout.LayoutParams(-2, a.dp(34));
            dLp.rightMargin = a.dp(6);
            topRow.addView(depotPill, dLp);
        } else {
            depotPill = null;
            depotIcon = null;
            depotLbl = null;
        }

        // Current source switcher pill — sleek airy iOS frosted capsule (zero jarring neon dot)
        final LinearLayout srcPill = a.row();
        srcPill.setGravity(Gravity.CENTER_VERTICAL);
        srcPill.setPadding(a.dp(11), 0, a.dp(9), 0);
        GradientDrawable canvasSrcBg = a.bg(p.bgSubtle, 999);
        canvasSrcBg.setStroke(MobileTheme.hairlinePx(a), p.isDark ? 0x1EFFFFFF : 0x12000000);
        srcPill.setBackground(canvasSrcBg);

        final MobileIcons.IconView srcIcon =
                MobileIcons.create(a, MobileIcons.IC_SWITCH_SOURCE, 13f, p.accent);
        LinearLayout.LayoutParams siLp = new LinearLayout.LayoutParams(a.dp(13), a.dp(13));
        siLp.rightMargin = a.dp(5);
        srcPill.addView(srcIcon, siLp);

        final TextView srcLabel = a.text(site.name, 12.5f, p.textPrimary);
        srcLabel.setTag("source-switcher");
        srcLabel.setTypeface(null, Typeface.BOLD);
        srcLabel.setSingleLine(true);
        srcLabel.setEllipsize(TextUtils.TruncateAt.END);
        int maxSrcPx = Math.max(a.dp(88), Math.min(a.dp(144), a.windowWidth() - a.dp(224)));
        srcLabel.setMaxWidth(maxSrcPx);
        srcPill.addView(srcLabel);

        final MobileIcons.IconView srcChevron =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_DOWN, 11.5f, p.textTertiary);
        LinearLayout.LayoutParams chLp = new LinearLayout.LayoutParams(a.dp(11.5f), a.dp(11.5f));
        chLp.leftMargin = a.dp(4);
        srcPill.addView(srcChevron, chLp);

        MobileMotion.bindPress(srcPill, 0.94f);
        srcPill.setOnClickListener(v -> shell.showQuickSourceAndModeSheet());
        topRow.addView(srcPill, new LinearLayout.LayoutParams(-2, a.dp(34)));
        floatingTopBar.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        // Scroll-reactive iOS header & status bar polarity state machine:
        // When the full-bleed Hero is active, floatingTopBar rides upward smoothly with the Hero
        // (matching iOS adaptive_shell) so Marco Movie & source pill never collide with the Hero
        // title or scrolled poster rows; statusBarVeil fades in cleanly as Hero leaves viewport.
        final boolean[] heroVisibleFlag = {false};
        final Boolean[] lastOverHeroState = {null};
        final Runnable syncHeroHeaderPolarity =
                () -> {
                    int scrollY = sv.getScrollY();
                    boolean hasHero = heroVisibleFlag[0];
                    if (hasHero) {
                        floatingTopBar.setTranslationY(-Math.min(scrollY, heroHeightPx));
                        float veilAlpha =
                                Math.max(
                                        0f,
                                        Math.min(
                                                1f,
                                                (scrollY - heroHeightPx * 0.25f)
                                                        / Math.max(1f, heroHeightPx * 0.24f)));
                        shell.setStatusBarVeilAlpha(veilAlpha);
                    } else {
                        floatingTopBar.setTranslationY(0f);
                        shell.setStatusBarVeilAlpha(1f);
                    }
                    boolean overHero = hasHero && scrollY < Math.round(heroHeightPx * 0.44f);
                    if (lastOverHeroState[0] != null && lastOverHeroState[0] == overHero) {
                        return;
                    }
                    lastOverHeroState[0] = overHero;
                    if (overHero) {
                        a.applyMobileSystemBars(false, true);
                        floatingTopBar.setBackground(null);
                        applyWordmarkInk(a, brandWordmarkRef[0], true, true);
                        GradientDrawable glassPill = a.bg(0x450E121C, 999);
                        glassPill.setStroke(MobileTheme.hairlinePx(a), 0x33FFFFFF);
                        srcPill.setBackground(glassPill);
                        UiCompat.setElevation(srcPill, 0f);
                        srcIcon.setTint(0xEBFFFFFF);
                        srcLabel.setTextColor(0xF5FFFFFF);
                        srcChevron.setTint(0xBAFFFFFF);
                        if (depotPill != null) {
                            GradientDrawable dGlass = a.bg(0x450E121C, 999);
                            dGlass.setStroke(MobileTheme.hairlinePx(a), 0x33FFFFFF);
                            depotPill.setBackground(dGlass);
                            depotIcon.setTint(0xEBFFFFFF);
                            depotLbl.setTextColor(0xF5FFFFFF);
                        }
                    } else {
                        a.applyMobileSystemBars(false, false);
                        if (!hasHero) {
                            floatingTopBar.setBackground(
                                    new GradientDrawable(
                                            GradientDrawable.Orientation.TOP_BOTTOM,
                                            new int[] {
                                                MobileTheme.withAlpha(p.bgCanvas, 0xF5),
                                                MobileTheme.withAlpha(p.bgCanvas, 0xCC),
                                                Color.TRANSPARENT
                                            }));
                            applyWordmarkInk(a, brandWordmarkRef[0], p.isDark, false);
                            GradientDrawable subBg = a.bg(p.bgSubtle, 999);
                            subBg.setStroke(
                                    MobileTheme.hairlinePx(a), p.isDark ? 0x1EFFFFFF : 0x12000000);
                            srcPill.setBackground(subBg);
                            UiCompat.setElevation(srcPill, 0f);
                            srcIcon.setTint(p.accent);
                            srcLabel.setTextColor(p.textPrimary);
                            srcChevron.setTint(p.textTertiary);
                            if (depotPill != null) {
                                depotPill.setBackground(MobileTheme.pillBg(a, true, 999));
                                depotIcon.setTint(p.accent);
                                depotLbl.setTextColor(p.accent);
                            }
                        }
                    }
                };
        syncHeroHeaderPolarity.run();
        shell.bindScrollBehavior(sv, syncHeroHeaderPolarity);

        final Runnable[] applyHeroLayoutMode = {
            () -> {
                boolean hasHero = heroHolder.getChildCount() > 0;
                heroVisibleFlag[0] = hasHero;
                heroHolder.setVisibility(hasHero ? View.VISIBLE : View.GONE);
                heroAtmosphereView.setVisibility(hasHero ? View.VISIBLE : View.GONE);
                boolean hasShelfBelowHero =
                        historyWrap.getVisibility() == View.VISIBLE
                                || curatedWrap.getVisibility() == View.VISIBLE;
                int solidPast = hasShelfBelowHero ? a.dp(26) : a.dp(8);
                int dissolveLen = hasShelfBelowHero ? a.dp(148) : a.dp(116);
                heroAtmosphereView.setDissolveRange(heroHeightPx + solidPast, dissolveLen);
                ViewGroup.LayoutParams atmoLp = heroAtmosphereView.getLayoutParams();
                int desiredAtmoH = heroHeightPx + solidPast + dissolveLen;
                if (atmoLp != null && atmoLp.height != desiredAtmoH) {
                    atmoLp.height = desiredAtmoH;
                    heroAtmosphereView.setLayoutParams(atmoLp);
                }
                if (!hasHero) {
                    applyFirstShelfInk(historyWrap, p, false, false);
                    MobileCuratedSection.applyFirstHeaderInk(curatedWrap, p, false, false);
                }
                int topPad = hasHero ? 0 : standardTopPad;
                if (body.getPaddingTop() != topPad) {
                    body.setPadding(0, topPad, 0, bottomPad);
                }
                lastOverHeroState[0] = null;
                syncHeroHeaderPolarity.run();
            }
        };

        final TextView statusView = a.text("正在连接片源…", 13, p.textSecondary);
        statusView.setGravity(Gravity.CENTER);
        statusView.setPadding(a.dp(16), a.dp(28), a.dp(16), a.dp(12));
        body.addView(statusView, new LinearLayout.LayoutParams(-1, -2));

        // 1-tap Clear Filters CTA (only shown when active filters yield 0 matches)
        final TextView clearFilterBtn = a.text("清空筛选", 13, p.accentOnFill);
        clearFilterBtn.setTypeface(null, Typeface.BOLD);
        clearFilterBtn.setGravity(Gravity.CENTER);
        clearFilterBtn.setPadding(a.dp(20), a.dp(9), a.dp(20), a.dp(9));
        clearFilterBtn.setBackground(MobileTheme.accentPillBg(a, 999));
        clearFilterBtn.setVisibility(View.GONE);
        MobileMotion.bindPress(clearFilterBtn, 0.94f);
        LinearLayout.LayoutParams cfLp = new LinearLayout.LayoutParams(-2, -2);
        cfLp.gravity = Gravity.CENTER_HORIZONTAL;
        cfLp.bottomMargin = a.dp(14);
        body.addView(clearFilterBtn, cfLp);

        final TextView recoverSwitchBtn = a.text("切换其他片源", 13, p.textPrimary);
        recoverSwitchBtn.setTypeface(null, Typeface.BOLD);
        recoverSwitchBtn.setGravity(Gravity.CENTER);
        recoverSwitchBtn.setPadding(a.dp(18), a.dp(9), a.dp(18), a.dp(9));
        recoverSwitchBtn.setBackground(MobileTheme.cardBg(a, 999));
        if (!p.isDark) UiCompat.setElevation(recoverSwitchBtn, a.dp(2f));
        recoverSwitchBtn.setVisibility(View.GONE);
        MobileMotion.bindPress(recoverSwitchBtn, 0.94f);
        recoverSwitchBtn.setOnClickListener(v -> shell.showQuickSourceAndModeSheet());
        LinearLayout.LayoutParams recLp = new LinearLayout.LayoutParams(-2, -2);
        recLp.gravity = Gravity.CENTER_HORIZONTAL;
        recLp.bottomMargin = a.dp(14);
        body.addView(recoverSwitchBtn, recLp);

        shell.onSourceRejected =
                reason -> {
                    statusView.setVisibility(View.VISIBLE);
                    statusView.setText(reason);
                    clearFilterBtn.setVisibility(View.GONE);
                    recoverSwitchBtn.setVisibility(View.VISIBLE);
                };

        final LinearLayout gridWrap = a.vertical();
        gridWrap.setPadding(a.dp(16), a.dp(2), a.dp(16), 0);
        body.addView(gridWrap, new LinearLayout.LayoutParams(-1, -2));

        final TextView moreBtn = a.text("加载更多影片", 13.5f, p.textPrimary);
        moreBtn.setTypeface(null, Typeface.BOLD);
        moreBtn.setGravity(Gravity.CENTER);
        moreBtn.setPadding(a.dp(18), a.dp(12), a.dp(18), a.dp(12));
        moreBtn.setBackground(MobileTheme.cardBg(a, 999));
        if (!p.isDark) UiCompat.setElevation(moreBtn, a.dp(2f));
        moreBtn.setVisibility(View.GONE);
        MobileMotion.bindPress(moreBtn, 0.96f);
        LinearLayout.LayoutParams moreLp = new LinearLayout.LayoutParams(-1, -2);
        moreLp.setMargins(a.dp(16), a.dp(14), a.dp(16), a.dp(8));
        body.addView(moreBtn, moreLp);

        final List<Cms.Category> categories = new ArrayList<>();
        final List<Cms.Video> currentVideos = new ArrayList<>();
        final String[] filterSchemaHolder = {"{}"};
        final int[] curPage = {1};
        final int[] totalPages = {1};
        final int[] reqId = {0};
        final int[] lastFilterBadgeCount = {0};
        final Runnable[] fetchListing = new Runnable[1];

        final Runnable rebuildChips =
                new Runnable() {
                    @Override
                    public void run() {
                        catRow.removeAllViews();
                        addCatChip(
                                a,
                                catRow,
                                "推荐",
                                "",
                                selectedCategoryId.isEmpty(),
                                () -> {
                                    selectedCategoryId = "";
                                    curPage[0] = 1;
                                    run();
                                    fetchListing[0].run();
                                });
                        for (final Cms.Category c : categories) {
                            addCatChip(
                                    a,
                                    catRow,
                                    c.name,
                                    c.id,
                                    c.id.equals(selectedCategoryId),
                                    () -> {
                                        selectedCategoryId = c.id;
                                        curPage[0] = 1;
                                        run();
                                        fetchListing[0].run();
                                    });
                        }
                        String targetCat =
                                selectedCategoryId.isEmpty() && !categories.isEmpty()
                                        ? categories.get(0).id
                                        : selectedCategoryId;
                        final List<VideoFilters.Definition> activeDefs =
                                VideoFilters.definitions(
                                        filterSchemaHolder[0], targetCat, currentVideos);
                        filterBtn.setVisibility(
                                activeDefs != null && !activeDefs.isEmpty()
                                        ? View.VISIBLE
                                        : View.GONE);
                        int activeFilterCount =
                                MobileFilterSheet.countActiveSelections(
                                        activeDefs, selectedFilters);
                        if (activeFilterCount > 0) {
                            filterBtn.setBackground(MobileTheme.pillBg(a, true, 999));
                            filterIcon.setTint(p.accent);
                            filterIcon.setFilled(true);
                            filterText.setTextColor(p.accent);
                            filterCountBadge.setText(String.valueOf(activeFilterCount));
                            filterCountBadge.setTextColor(p.accentOnFill);
                            filterCountBadge.setBackground(MobileTheme.accentPillBg(a, 999));
                            filterCountBadge.setVisibility(View.VISIBLE);
                            if (activeFilterCount != lastFilterBadgeCount[0]) {
                                MobileMotion.popBounce(filterCountBadge);
                            }
                        } else {
                            filterBtn.setBackground(MobileTheme.cardBg(a, 999));
                            filterIcon.setTint(p.textPrimary);
                            filterIcon.setFilled(false);
                            filterText.setTextColor(p.textPrimary);
                            filterCountBadge.setVisibility(View.GONE);
                        }
                        lastFilterBadgeCount[0] = activeFilterCount;
                        filterBtn.setOnClickListener(
                                v -> {
                                    if (activeDefs == null || activeDefs.isEmpty()) return;
                                    VideoFilterDialog.show(
                                            a,
                                            activeDefs,
                                            selectedFilters,
                                            () -> {
                                                if (selectedCategoryId.isEmpty()
                                                        && !categories.isEmpty()) {
                                                    selectedCategoryId = categories.get(0).id;
                                                }
                                                curPage[0] = 1;
                                                run();
                                                fetchListing[0].run();
                                            });
                                });
                    }
                };

        clearFilterBtn.setOnClickListener(
                v -> {
                    MobileFilterSheet.resetSelections(selectedFilters);
                    curPage[0] = 1;
                    rebuildChips.run();
                    fetchListing[0].run();
                });

        final Runnable[] refreshCuratedRef = {null};
        final Runnable debouncedCuratedRefresh =
                () -> {
                    if (curatedWrap.getVisibility() == View.VISIBLE) {
                        boolean curatedIsFirst = historyWrap.getVisibility() != View.VISIBLE;
                        MobileCuratedSection.renderInto(
                                a,
                                curatedWrap,
                                true,
                                curatedIsFirst,
                                MobileHomeSections.visibleCuratedIds(a));
                        if (heroHolder.getChildCount() > 0 && curatedIsFirst) {
                            Object liveAtmoObj = heroHolder.getTag();
                            if (liveAtmoObj instanceof Integer) {
                                boolean lightInk =
                                        useLightInkForHeroAtmo((Integer) liveAtmoObj, p.isDark);
                                MobileCuratedSection.applyFirstHeaderInk(
                                        curatedWrap, p, true, lightInk);
                            }
                        }
                    }
                };
        refreshCuratedRef[0] =
                () -> {
                    a.ui.removeCallbacks(debouncedCuratedRefresh);
                    a.ui.postDelayed(debouncedCuratedRefresh, 160L);
                };

        // Recovery card when the user turns off every single Home section
        final LinearLayout allHiddenRecovery = buildAllSectionsHiddenCard(shell);
        allHiddenRecovery.setVisibility(View.GONE);
        body.addView(allHiddenRecovery, new LinearLayout.LayoutParams(-1, -2));

        final HomeScreen.Snapshot[] coldDiskHolder = {null};
        fetchListing[0] =
                () -> {
                    final int myReq = ++reqId[0];
                    final int pageToLoad = curPage[0];
                    final String catId = selectedCategoryId;
                    boolean heroAllowed =
                            MobileHomeSections.isVisible(a, MobileHomeSections.ID_HERO_BILLBOARD);
                    boolean showHistory =
                            catId.isEmpty()
                                    && MobileHomeSections.isVisible(
                                            a, MobileHomeSections.ID_WATCH_HISTORY)
                                    && !a.watchHistory().isEmpty();
                    historyWrap.setVisibility(showHistory ? View.VISIBLE : View.GONE);
                    List<String> enabledCurated = MobileHomeSections.visibleCuratedIds(a);
                    boolean showCurated =
                            catId.isEmpty() && !a.privateMode && !enabledCurated.isEmpty();
                    curatedWrap.setVisibility(showCurated ? View.VISIBLE : View.GONE);
                    boolean showSourceCatalog =
                            !catId.isEmpty()
                                    || MobileHomeSections.isVisible(
                                            a, MobileHomeSections.ID_SOURCE_UPDATES);
                    sourceCatalogHeader.setVisibility(
                            showSourceCatalog && catId.isEmpty() ? View.VISIBLE : View.GONE);
                    categoryBarWrap.setVisibility(showSourceCatalog ? View.VISIBLE : View.GONE);
                    gridWrap.setVisibility(showSourceCatalog ? View.VISIBLE : View.GONE);
                    boolean allOff = catId.isEmpty() && MobileHomeSections.areAllHidden(a, true);
                    allHiddenRecovery.setVisibility(allOff ? View.VISIBLE : View.GONE);
                    if (showCurated) {
                        MobileCuratedDiscovery.hydrateFromDiskIfNeeded(a);
                        MobileCuratedSection.renderInto(
                                a, curatedWrap, true, !showHistory, enabledCurated);
                        MobileCuratedDiscovery.fetchAllAsync(a, a.generation, refreshCuratedRef[0]);
                    } else {
                        ImageLoader.detachImageViews(curatedWrap);
                        curatedWrap.removeAllViews();
                    }
                    if (!showSourceCatalog) {
                        statusView.setVisibility(View.GONE);
                        moreBtn.setVisibility(View.GONE);
                        clearFilterBtn.setVisibility(View.GONE);
                        recoverSwitchBtn.setVisibility(View.GONE);
                        if (!heroAllowed) {
                            ImageLoader.detachImageViews(heroHolder);
                            heroHolder.removeAllViews();
                            applyHeroLayoutMode[0].run();
                            return;
                        }
                    }

                    // Instant in-memory snapshot hit for page 1 home (already fetched this session)
                    if (catId.isEmpty() && pageToLoad == 1) {
                        HomeScreen.Snapshot cached = a.homeData.get(site.key);
                        if (cached != null
                                && !cached.videos.isEmpty()
                                && hasAnyPoster(cached.videos)) {
                            ImageLoader.detachImageViews(gridWrap);
                            gridWrap.removeAllViews();
                            ImageLoader.detachImageViews(heroHolder);
                            heroHolder.removeAllViews();
                            moreBtn.setVisibility(View.GONE);
                            clearFilterBtn.setVisibility(View.GONE);
                            recoverSwitchBtn.setVisibility(View.GONE);
                            statusView.setOnClickListener(null);
                            statusView.setVisibility(View.GONE);
                            categories.clear();
                            categories.addAll(cached.categories);
                            currentVideos.clear();
                            currentVideos.addAll(cached.videos);
                            filterSchemaHolder[0] = cached.filterSchema;
                            totalPages[0] = Math.max(1, cached.pages);
                            rebuildChips.run();
                            presentVideos(
                                    shell,
                                    site,
                                    cached.videos,
                                    heroHolder,
                                    heroAtmosphereView,
                                    historyWrap,
                                    curatedWrap,
                                    gridWrap,
                                    true,
                                    heroHeightPx);
                            applyHeroLayoutMode[0].run();
                            return;
                        }
                    }

                    // Cold-start disk snapshot: render cached Immersive Hero + catalog IMMEDIATELY
                    // on frame 1, then silently refresh from network in the background.
                    final HomeScreen.Snapshot coldDisk =
                            (catId.isEmpty() && pageToLoad == 1) ? coldDiskHolder[0] : null;
                    coldDiskHolder[0] = null;
                    final boolean displayedColdCache =
                            coldDisk != null
                                    && !coldDisk.videos.isEmpty()
                                    && hasAnyPoster(coldDisk.videos);
                    final List<Cms.Video> coldSnapshotVideos =
                            displayedColdCache
                                    ? new ArrayList<>(coldDisk.videos)
                                    : java.util.Collections.emptyList();

                    if (displayedColdCache) {
                        ImageLoader.detachImageViews(gridWrap);
                        gridWrap.removeAllViews();
                        ImageLoader.detachImageViews(heroHolder);
                        heroHolder.removeAllViews();
                        moreBtn.setVisibility(View.GONE);
                        clearFilterBtn.setVisibility(View.GONE);
                        recoverSwitchBtn.setVisibility(View.GONE);
                        statusView.setOnClickListener(null);
                        statusView.setVisibility(View.GONE);
                        categories.clear();
                        categories.addAll(coldDisk.categories);
                        currentVideos.clear();
                        currentVideos.addAll(coldDisk.videos);
                        filterSchemaHolder[0] = coldDisk.filterSchema;
                        totalPages[0] = Math.max(1, coldDisk.pages);
                        rebuildChips.run();
                        presentVideos(
                                shell,
                                site,
                                coldDisk.videos,
                                heroHolder,
                                heroAtmosphereView,
                                historyWrap,
                                curatedWrap,
                                gridWrap,
                                true,
                                heroHeightPx);
                        applyHeroLayoutMode[0].run();
                    } else if (pageToLoad == 1) {
                        ImageLoader.detachImageViews(gridWrap);
                        gridWrap.removeAllViews();
                        ImageLoader.detachImageViews(heroHolder);
                        heroHolder.removeAllViews();
                        applyHeroLayoutMode[0].run();
                        moreBtn.setVisibility(View.GONE);
                        clearFilterBtn.setVisibility(View.GONE);
                        recoverSwitchBtn.setVisibility(View.GONE);
                        statusView.setOnClickListener(null);
                        statusView.setVisibility(View.VISIBLE);
                        statusView.setText("正在加载片单…");
                    } else {
                        moreBtn.setText("正在加载第 " + pageToLoad + " 页…");
                    }

                    final int ticket = a.generation;
                    final String targetCatForDefs =
                            catId.isEmpty() && !categories.isEmpty() ? categories.get(0).id : catId;
                    final List<VideoFilters.Definition> defsSnapshot =
                            VideoFilters.definitions(
                                    filterSchemaHolder[0], targetCatForDefs, currentVideos);
                    a.submitPage(
                            () -> {
                                final long loadingGuardToken =
                                        LOADING_GUARD.acquire(
                                                key -> commitLoadingSite(a, key), site.key);
                                try {
                                    SourceEngine eng = a.engine(site);
                                    final List<Cms.Category> parsedCats;
                                    final Cms.Listing listing;
                                    final String homeRaw;
                                    if (catId.isEmpty() && pageToLoad == 1) {
                                        homeRaw = eng.home();
                                        parsedCats = Cms.categories(homeRaw);
                                        listing = resolveHomeListing(eng, homeRaw, parsedCats);
                                    } else {
                                        homeRaw = null;
                                        parsedCats = null;
                                        listing =
                                                Cms.listing(
                                                        eng.category(
                                                                catId,
                                                                pageToLoad,
                                                                VideoFilters.remoteValues(
                                                                        defsSnapshot,
                                                                        selectedFilters)));
                                    }
                                    final List<Cms.Video> displayList =
                                            VideoFilters.apply(
                                                    listing.videos, defsSnapshot, selectedFilters);
                                    a.learnTitles(listing.videos);
                                    HomeScreen.Snapshot preparedSnap = null;
                                    if (catId.isEmpty() && pageToLoad == 1) {
                                        List<Cms.Category> snapCats =
                                                parsedCats != null
                                                        ? new ArrayList<>(parsedCats)
                                                        : new ArrayList<>();
                                        preparedSnap =
                                                new HomeScreen.Snapshot(
                                                        displayList,
                                                        snapCats,
                                                        "",
                                                        listing.pageCount);
                                        preparedSnap.filterSchema =
                                                homeRaw != null ? homeRaw : filterSchemaHolder[0];
                                        if (!a.privateMode
                                                && !displayList.isEmpty()
                                                && (site.api == null
                                                        || !site.api.contains("fixture.test"))) {
                                            HomeScreen.writeDiskSnapshot(a, site.key, preparedSnap);
                                        }
                                    }
                                    final HomeScreen.Snapshot freshSnap = preparedSnap;
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqId[0]) return;
                                                if (catId.isEmpty()
                                                        && pageToLoad == 1
                                                        && freshSnap != null) {
                                                    a.homeData.put(site.key, freshSnap);
                                                }
                                                if (displayedColdCache
                                                        && freshSnap != null
                                                        && HomeScreen.sameSnapshotContent(
                                                                coldDisk, freshSnap)) {
                                                    if (homeRaw != null) {
                                                        filterSchemaHolder[0] = homeRaw;
                                                    }
                                                    totalPages[0] = Math.max(1, listing.pageCount);
                                                    boolean hasMore = pageToLoad < totalPages[0];
                                                    moreBtn.setVisibility(
                                                            hasMore ? View.VISIBLE : View.GONE);
                                                    if (hasMore) {
                                                        moreBtn.setText(
                                                                "加载更多 ("
                                                                        + pageToLoad
                                                                        + " / "
                                                                        + totalPages[0]
                                                                        + ")");
                                                    }
                                                    return;
                                                }
                                                if (pageToLoad == 1) {
                                                    currentVideos.clear();
                                                    if (displayedColdCache) {
                                                        ImageLoader.detachImageViews(gridWrap);
                                                        gridWrap.removeAllViews();
                                                        if (!hasSameHeroLead(
                                                                coldSnapshotVideos, displayList)) {
                                                            ImageLoader.detachImageViews(
                                                                    heroHolder);
                                                            heroHolder.removeAllViews();
                                                        }
                                                    }
                                                }
                                                currentVideos.addAll(displayList);
                                                if (catId.isEmpty() && pageToLoad == 1) {
                                                    categories.clear();
                                                    if (parsedCats != null)
                                                        categories.addAll(parsedCats);
                                                    if (homeRaw != null)
                                                        filterSchemaHolder[0] = homeRaw;
                                                    if (freshSnap == null) {
                                                        HomeScreen.Snapshot snap =
                                                                new HomeScreen.Snapshot(
                                                                        displayList,
                                                                        new ArrayList<>(categories),
                                                                        "",
                                                                        listing.pageCount);
                                                        snap.filterSchema = filterSchemaHolder[0];
                                                        a.homeData.put(site.key, snap);
                                                    }
                                                    rebuildChips.run();
                                                }
                                                totalPages[0] = Math.max(1, listing.pageCount);
                                                boolean emptyFirst =
                                                        displayList.isEmpty() && pageToLoad == 1;
                                                statusView.setVisibility(
                                                        emptyFirst ? View.VISIBLE : View.GONE);
                                                recoverSwitchBtn.setVisibility(View.GONE);
                                                boolean hasActiveFilters =
                                                        !selectedFilters.isEmpty();
                                                if (emptyFirst) {
                                                    statusView.setText(
                                                            hasActiveFilters
                                                                    ? "当前筛选条件下暂无匹配影片"
                                                                    : "当前分类暂无内容");
                                                }
                                                clearFilterBtn.setVisibility(
                                                        emptyFirst && hasActiveFilters
                                                                ? View.VISIBLE
                                                                : View.GONE);
                                                presentVideos(
                                                        shell,
                                                        site,
                                                        displayList,
                                                        heroHolder,
                                                        heroAtmosphereView,
                                                        historyWrap,
                                                        curatedWrap,
                                                        gridWrap,
                                                        catId.isEmpty() && pageToLoad == 1,
                                                        heroHeightPx);
                                                applyHeroLayoutMode[0].run();
                                                boolean hasMore = pageToLoad < totalPages[0];
                                                moreBtn.setVisibility(
                                                        hasMore ? View.VISIBLE : View.GONE);
                                                if (hasMore) {
                                                    moreBtn.setText(
                                                            "加载更多 ("
                                                                    + pageToLoad
                                                                    + " / "
                                                                    + totalPages[0]
                                                                    + ")");
                                                }
                                            });
                                } catch (Throwable e) {
                                    AppLog.w("MobileHomePage", "home/category load failed", e);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()
                                                        || ticket != a.generation
                                                        || myReq != reqId[0]) return;
                                                if (displayedColdCache) {
                                                    a.toast("已展示上次缓存片单，后台刷新失败");
                                                    return;
                                                }
                                                clearFilterBtn.setVisibility(View.GONE);
                                                statusView.setVisibility(View.VISIBLE);
                                                statusView.setText(
                                                        SourceController.stageMessage("列表读取失败", e)
                                                                + "（点击重试）");
                                                statusView.setOnClickListener(
                                                        v -> fetchListing[0].run());
                                                recoverSwitchBtn.setVisibility(View.VISIBLE);
                                            });
                                } finally {
                                    LOADING_GUARD.releaseIfOwner(
                                            key -> applyClearLoadingSite(a), loadingGuardToken);
                                }
                            });
                };

        moreBtn.setOnClickListener(
                v -> {
                    curPage[0]++;
                    fetchListing[0].run();
                });

        HomeScreen.Snapshot initialSnap = a.homeData.get(site.key);
        if (initialSnap == null
                && !a.privateMode
                && (site.api == null || !site.api.contains("fixture.test"))) {
            HomeScreen.Snapshot diskSnap = HomeScreen.readDiskSnapshot(a, site.key);
            if (diskSnap != null && !diskSnap.videos.isEmpty()) {
                coldDiskHolder[0] = diskSnap;
                initialSnap = diskSnap;
            }
        }
        if (initialSnap != null) {
            if (initialSnap.categories != null && !initialSnap.categories.isEmpty()) {
                categories.clear();
                categories.addAll(initialSnap.categories);
            }
            if (initialSnap.filterSchema != null && !initialSnap.filterSchema.isEmpty()) {
                filterSchemaHolder[0] = initialSnap.filterSchema;
            }
        }

        rebuildChips.run();
        fetchListing[0].run();
    }

    private static void addCatChip(
            MainActivity a,
            LinearLayout row,
            String label,
            String id,
            boolean active,
            Runnable onTap) {
        MobileTheme.Palette p = MobileTheme.of(a);
        TextView chip = a.text(label, 13f, active ? p.accent : p.textSecondary);
        chip.setTag("home-tab:" + (id.isEmpty() ? "0" : id));
        chip.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
        chip.setPadding(a.dp(14), a.dp(6.5f), a.dp(14), a.dp(6.5f));
        // Opaque Material 3 tonal fill prevents poster bleed-through on active chips
        int chipFill =
                active
                        ? MobileTheme.blend(p.bgCard, p.accent, p.isDark ? 0.24f : 0.14f)
                        : p.pillUnselectedFill;
        chip.setBackground(a.bg(chipFill, 999));
        MobileMotion.bindPress(chip, 0.94f);
        chip.setOnClickListener(v -> onTap.run());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.rightMargin = a.dp(8);
        row.addView(chip, lp);
    }

    private static void renderContinueWatchingStrip(MainActivity a, LinearLayout parent) {
        parent.removeAllViews();
        if (!a.prefs.getBoolean(Prefs.MOBILE_SHOW_HISTORY, true)) {
            parent.setVisibility(View.GONE);
            return;
        }
        List<WatchHistory.Entry> items = a.watchHistory();
        if (items.isEmpty()) {
            parent.setVisibility(View.GONE);
            return;
        }
        parent.setVisibility(View.VISIBLE);

        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout header = a.row();
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(a.dp(16), a.dp(4), a.dp(16), a.dp(8));
        TextView title = a.text("继续观看", 15.5f, p.textPrimary);
        title.setTag("continue-watching-title");
        title.setTypeface(null, Typeface.BOLD);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        LinearLayout allBtn = a.row();
        allBtn.setGravity(Gravity.CENTER_VERTICAL);
        TextView allText = a.text("全部", 12.5f, p.textSecondary);
        allText.setTag("continue-watching-all");
        allBtn.addView(allText);
        MobileIcons.IconView allChev =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 13f, p.textTertiary);
        allChev.setTag("continue-watching-chev");
        LinearLayout.LayoutParams acLp = new LinearLayout.LayoutParams(a.dp(13), a.dp(13));
        acLp.leftMargin = a.dp(2);
        allBtn.addView(allChev, acLp);
        MobileMotion.bindPress(allBtn, 0.94f);
        allBtn.setOnClickListener(v -> MobileRootShell.openTab(a, MobileRootShell.TAB_LIBRARY));
        header.addView(allBtn);
        parent.addView(header);

        HorizontalScrollView hsv = new HorizontalScrollView(a);
        hsv.setHorizontalScrollBarEnabled(false);
        hsv.setPadding(a.dp(16), 0, a.dp(16), a.dp(6));
        hsv.setClipToPadding(false);
        LinearLayout row = a.row();
        hsv.addView(row);

        int limit = Math.min(10, items.size());
        for (int i = 0; i < limit; i++) {
            final WatchHistory.Entry e = items.get(i);
            LinearLayout card = a.row();
            card.setGravity(Gravity.CENTER_VERTICAL);
            card.setPadding(a.dp(9), a.dp(9), a.dp(12), a.dp(9));
            card.setBackground(MobileTheme.cardBg(a, 16));
            if (!p.isDark) UiCompat.setElevation(card, a.dp(2f));
            MobileMotion.bindPress(card, 0.97f);
            card.setOnClickListener(v -> a.resumeHistory(e));
            card.setOnLongClickListener(
                    v -> {
                        MobileBottomSheet.showConfirm(
                                a,
                                "移除续播记录？",
                                "将从继续观看列表中移除「" + e.title + "」，不会影响已收藏影片。",
                                "移除",
                                true,
                                () ->
                                        CloudSyncDialog.removeHistoryWithTombstone(
                                                a,
                                                e.key(),
                                                () -> renderContinueWatchingStrip(a, parent)));
                        return true;
                    });

            ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(MobileTheme.subtleBg(a, 10));
            pic.setClipToOutline(true);
            if (e.poster != null && !e.poster.isEmpty()) a.poster(e.poster, pic);
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(44), a.dp(60));
            pLp.rightMargin = a.dp(10);
            card.addView(pic, pLp);

            LinearLayout col = a.vertical();
            TextView t = a.text(e.title, 13.5f, p.textPrimary);
            t.setTypeface(null, Typeface.BOLD);
            t.setSingleLine(true);
            t.setEllipsize(TextUtils.TruncateAt.END);
            col.addView(t);

            TextView sub = a.text(formatCleanHistorySubtitle(a, e), 11.5f, p.textSecondary);
            sub.setSingleLine(true);
            sub.setEllipsize(TextUtils.TruncateAt.END);
            sub.setPadding(0, a.dp(3), 0, a.dp(6));
            col.addView(sub);

            float frac =
                    e.duration > 0
                            ? Math.max(0.05f, Math.min(1f, e.position / (float) e.duration))
                            : 0.2f;
            FrameLayout barTrack = new FrameLayout(a);
            barTrack.setBackground(MobileTheme.subtleBg(a, 999));
            View barFill = new View(a);
            barFill.setBackground(MobileTheme.accentPillBg(a, 999));
            barTrack.addView(
                    barFill, new FrameLayout.LayoutParams(Math.round(a.dp(136) * frac), -1));
            col.addView(barTrack, new LinearLayout.LayoutParams(a.dp(136), a.dp(3.5f)));

            card.addView(col, new LinearLayout.LayoutParams(a.dp(144), -2));
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(-2, -2);
            cLp.rightMargin = a.dp(10);
            row.addView(card, cLp);
        }
        parent.addView(hsv, new LinearLayout.LayoutParams(-1, -2));
    }

    /** Cleans raw netdisk/CMS filenames in watch-history subtitles while keeping time progress. */
    static String formatCleanHistorySubtitle(MainActivity a, WatchHistory.Entry e) {
        if (e == null) return "";
        String raw = a != null ? a.historyLabel(e) : "";
        int storedCleanMode = a != null ? a.mobilePrefs().getInt(Prefs.EPISODE_CLEAN_MODE, 1) : 1;
        int cleanMode =
                MobileDetailScreen.effectiveEpisodeCleanMode(
                        storedCleanMode, a != null && AiBetaGate.isUnlocked(a));
        return formatCleanHistoryLabel(raw, e.episode, e.title, e.index, cleanMode);
    }

    /**
     * Pure-JVM helper cleaning raw netdisk/CMS filenames (e.g. {@code [3.63GB] M- 4K.mkv}) inside
     * watch-history subtitles while preserving playback progress ({@code 00:42 / 1:30:48}).
     */
    static String formatCleanHistoryLabel(
            String rawLabel, String episode, String title, int index, int cleanMode) {
        String raw = rawLabel == null ? "" : rawLabel;
        if (cleanMode == 0 || episode == null || episode.trim().isEmpty()) {
            return raw;
        }
        String epTrim = episode.trim();
        EpisodeNameCleaner.CleanedEpisode cleaned =
                EpisodeNameCleaner.clean(epTrim, title, index + 1);
        String epLabel =
                cleaned != null && cleaned.shortLabel != null && !cleaned.shortLabel.isEmpty()
                        ? cleaned.shortLabel.trim()
                        : epTrim;
        boolean lookedLikeFile =
                epTrim.startsWith("[")
                        || epTrim.matches(
                                "(?i).*\\.(?:mkv|mp4|ts|flv|avi|mov|m3u8|webm|iso|rmvb)$");
        if (lookedLikeFile
                && !epLabel.startsWith("第 ")
                && !epLabel.matches("(?i)^S\\d{2}E\\d{2}.*")) {
            if (epLabel.length() <= 2 || epLabel.matches("^[A-Za-z0-9._\\-\\s]+$")) {
                epLabel = index <= 0 ? "正片" : ("第 " + (index + 1) + " 集");
            }
        }
        if (epLabel.equals(epTrim)) {
            return raw;
        }
        String timePart = "";
        int sep = raw.lastIndexOf(" · ");
        if (sep >= 0) {
            timePart = raw.substring(sep);
        }
        return epLabel + timePart;
    }

    /**
     * Pure-JVM helper computing Home poster-wall column count from {@link
     * Prefs#MOBILE_POSTER_DENSITY} ({@code 0 = 紧凑}, {@code 1 = 标准}, {@code 2 = 宽敞}) and the
     * effective content width in dp (after subtracting any tablet landscape side rail).
     */
    static int resolvePosterColumns(float contentWidthDp, boolean portrait, int densityPref) {
        boolean wide = contentWidthDp >= 560f || !portrait;
        int target;
        if (densityPref == 0) {
            target = wide ? 6 : 4;
        } else if (densityPref == 2) {
            target = wide ? 4 : 2;
        } else {
            target = wide ? 5 : 3;
        }
        int maxCols = Math.max(2, (int) ((Math.max(240f, contentWidthDp) - 32f) / 76f));
        return Math.max(2, Math.min(target, maxCols));
    }

    private static void applyFirstShelfInk(
            View historyWrap, MobileTheme.Palette p, boolean overAtmo, boolean useLightInk) {
        if (historyWrap == null) return;
        View tView = historyWrap.findViewWithTag("continue-watching-title");
        View aView = historyWrap.findViewWithTag("continue-watching-all");
        View cView = historyWrap.findViewWithTag("continue-watching-chev");
        int titleCol = overAtmo ? (useLightInk ? Color.WHITE : 0xFF141821) : p.textPrimary;
        int allCol = overAtmo ? (useLightInk ? 0xD9FFFFFF : 0xCC141821) : p.textSecondary;
        int chevCol = overAtmo ? (useLightInk ? 0xB8FFFFFF : 0x99141821) : p.textTertiary;
        if (tView instanceof TextView) ((TextView) tView).setTextColor(titleCol);
        if (aView instanceof TextView) ((TextView) aView).setTextColor(allCol);
        if (cView instanceof MobileIcons.IconView) ((MobileIcons.IconView) cView).setTint(chevCol);
    }

    /**
     * Continuous Rex atmospheric backdrop rendered behind BOTH the Hero billboard and the first
     * shelf below it so the Hero poster's extracted lower-band tone flows seamlessly behind
     * Continue Watching cards and dissolves smoothly into the Light/Dark page canvas with zero
     * black-to-white cliff.
     */
    static final class HeroAtmosphereView extends View {
        private int solidBottomPx;
        private int dissolvePx;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int atmoColor = 0xFF1C2331;
        private int shaderHeight = -1;
        private int shaderColor = 0;

        HeroAtmosphereView(MainActivity a, int heroHeightPx, int solidPastHeroPx, int dissolvePx) {
            super(a);
            this.solidBottomPx = Math.max(1, heroHeightPx + solidPastHeroPx);
            this.dissolvePx = Math.max(1, dissolvePx);
            setClickable(false);
            setFocusable(false);
        }

        void setDissolveRange(int solidBottomPx, int dissolvePx) {
            int nextSolid = Math.max(1, solidBottomPx);
            int nextDissolve = Math.max(1, dissolvePx);
            if (this.solidBottomPx != nextSolid || this.dissolvePx != nextDissolve) {
                this.solidBottomPx = nextSolid;
                this.dissolvePx = nextDissolve;
                this.shaderHeight = -1;
                invalidate();
            }
        }

        void setAtmosphereColor(int color) {
            if (this.atmoColor != color) {
                this.atmoColor = color;
                this.shaderColor = 0;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            if (shaderHeight != h || shaderColor != atmoColor) {
                shaderHeight = h;
                shaderColor = atmoColor;
                float total = Math.max(1f, solidBottomPx + dissolvePx);
                float solidStop = Math.max(0.45f, Math.min(0.88f, solidBottomPx / total));
                float tail = 1f - solidStop;
                int[] colors = {
                    atmoColor,
                    atmoColor,
                    MobileTheme.withAlpha(atmoColor, 0xCC),
                    MobileTheme.withAlpha(atmoColor, 0x80),
                    MobileTheme.withAlpha(atmoColor, 0x38),
                    MobileTheme.withAlpha(atmoColor, 0x0F),
                    Color.TRANSPARENT
                };
                float[] stops = {
                    0f,
                    solidStop,
                    solidStop + tail * 0.18f,
                    solidStop + tail * 0.40f,
                    solidStop + tail * 0.64f,
                    solidStop + tail * 0.84f,
                    1f
                };
                paint.setShader(
                        new LinearGradient(
                                0f, 0f, 0f, total, colors, stops, Shader.TileMode.CLAMP));
            }
            canvas.drawRect(0f, 0f, w, h, paint);
        }
    }

    /**
     * Native 1:1 finger-tracking horizontal carousel for the Hero billboard with {@link
     * VelocityTracker} fling physics, {@link MobileMotion#rubberBand} edge resistance, and
     * interruptible {@link MotionSpring} settle — never fights child clicks or vertical scrolling.
     */
    static final class HeroPagerView extends FrameLayout {
        interface PageListener {
            void onFractionalPage(float page);

            void onPageSettled(int index);
        }

        private final MainActivity a;
        private int pageWidthPx;
        private final int touchSlop;
        private final List<View> slides = new ArrayList<>();
        private final PageListener listener;
        private int currentIndex = 0;
        private float scrollOffsetPx = 0f;
        private float downX = 0f;
        private float downY = 0f;
        private float dragStartOffset = 0f;
        private boolean dragging = false;
        private VelocityTracker velocityTracker;
        private MotionSpring snapSpring;
        private MotionLoop.Step snapStep;

        HeroPagerView(MainActivity a, int pageWidthPx, PageListener listener) {
            super(a);
            this.a = a;
            this.pageWidthPx = Math.max(1, pageWidthPx);
            this.touchSlop = ViewConfiguration.get(a).getScaledTouchSlop();
            this.listener = listener;
            setClipChildren(true);
            setClipToPadding(true);
        }

        void addSlide(View slide, int heightPx) {
            int idx = slides.size();
            slides.add(slide);
            slide.setTranslationX(idx * pageWidthPx - scrollOffsetPx);
            addView(slide, new FrameLayout.LayoutParams(pageWidthPx, heightPx));
        }

        @Override
        protected void onSizeChanged(int w, int h, int oldw, int oldh) {
            super.onSizeChanged(w, h, oldw, oldh);
            updatePageWidth(w);
        }

        /** Updates carousel width cleanly when a foldable folds/unfolds in the same orientation. */
        void updatePageWidth(int newWidthPx) {
            int nextW = Math.max(1, newWidthPx);
            if (nextW == pageWidthPx) return;
            pageWidthPx = nextW;
            stopSnapSpring();
            for (int i = 0; i < slides.size(); i++) {
                View slide = slides.get(i);
                ViewGroup.LayoutParams lp = slide.getLayoutParams();
                if (lp != null && lp.width != nextW) {
                    lp.width = nextW;
                    slide.setLayoutParams(lp);
                }
            }
            applyOffset(currentIndex * (float) pageWidthPx);
        }

        int currentPage() {
            return currentIndex;
        }

        void animateToPage(int targetIdx) {
            if (slides.isEmpty()) return;
            int clamped = Math.max(0, Math.min(slides.size() - 1, targetIdx));
            currentIndex = clamped;
            launchSnapSpring(clamped * (float) pageWidthPx, 0f);
            if (listener != null) listener.onPageSettled(clamped);
        }

        private void applyOffset(float offset) {
            scrollOffsetPx = offset;
            for (int i = 0; i < slides.size(); i++) {
                slides.get(i).setTranslationX(i * pageWidthPx - scrollOffsetPx);
            }
            if (listener != null && pageWidthPx > 0) {
                float frac =
                        Math.max(
                                0f,
                                Math.min(
                                        Math.max(0, slides.size() - 1),
                                        scrollOffsetPx / (float) pageWidthPx));
                listener.onFractionalPage(frac);
            }
        }

        private void stopSnapSpring() {
            if (snapStep != null) {
                MotionLoop.remove(snapStep);
                snapStep = null;
            }
        }

        private void launchSnapSpring(float targetOffset, float initialVelocityPxPerSec) {
            stopSnapSpring();
            if (MobileMotion.isReduced(a) || !UiCompat.isAttached(this)) {
                applyOffset(targetOffset);
                return;
            }
            snapSpring =
                    new MotionSpring(
                            scrollOffsetPx,
                            MotionTokens.SPRING_PLAYER_TRANSITION.motionSpringFrequency,
                            0.5f);
            snapSpring.velocity = Math.max(-5500f, Math.min(5500f, initialVelocityPxPerSec));
            snapSpring.target(targetOffset);
            snapStep =
                    dt -> {
                        if (!UiCompat.isAttached(this)) {
                            snapStep = null;
                            return false;
                        }
                        boolean moving = snapSpring.step(dt);
                        applyOffset(snapSpring.value);
                        if (!moving) {
                            applyOffset(targetOffset);
                            snapStep = null;
                        }
                        return moving;
                    };
            MotionLoop.add(snapStep);
        }

        private void recycleTracker() {
            if (velocityTracker != null) {
                velocityTracker.recycle();
                velocityTracker = null;
            }
        }

        @Override
        public boolean onInterceptTouchEvent(MotionEvent ev) {
            if (slides.size() <= 1) return false;
            int act = ev.getActionMasked();
            if (act == MotionEvent.ACTION_DOWN) {
                stopSnapSpring();
                downX = ev.getRawX();
                downY = ev.getRawY();
                dragStartOffset = scrollOffsetPx;
                dragging = false;
                recycleTracker();
                velocityTracker = VelocityTracker.obtain();
                velocityTracker.addMovement(ev);
                return false;
            }
            if (act == MotionEvent.ACTION_MOVE) {
                if (velocityTracker != null) velocityTracker.addMovement(ev);
                float dx = ev.getRawX() - downX;
                float dy = ev.getRawY() - downY;
                if (Math.abs(dx) > touchSlop && Math.abs(dx) > Math.abs(dy) * 1.15f) {
                    dragging = true;
                    downX = ev.getRawX();
                    dragStartOffset = scrollOffsetPx;
                    if (getParent() != null) {
                        getParent().requestDisallowInterceptTouchEvent(true);
                    }
                    return true;
                }
            } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                dragging = false;
                recycleTracker();
            }
            return false;
        }

        @Override
        public boolean onTouchEvent(MotionEvent ev) {
            if (slides.size() <= 1) return super.onTouchEvent(ev);
            int act = ev.getActionMasked();
            if (velocityTracker == null) {
                velocityTracker = VelocityTracker.obtain();
            }
            velocityTracker.addMovement(ev);
            if (act == MotionEvent.ACTION_DOWN) {
                stopSnapSpring();
                downX = ev.getRawX();
                downY = ev.getRawY();
                dragStartOffset = scrollOffsetPx;
                return true;
            } else if (act == MotionEvent.ACTION_MOVE) {
                float dx = ev.getRawX() - downX;
                if (!dragging && Math.abs(dx) > touchSlop) {
                    dragging = true;
                    if (getParent() != null) {
                        getParent().requestDisallowInterceptTouchEvent(true);
                    }
                }
                float rawOffset = dragStartOffset - dx;
                float maxOffset = (slides.size() - 1) * (float) pageWidthPx;
                float damped;
                if (rawOffset < 0f) {
                    damped = MobileMotion.rubberBand(rawOffset, pageWidthPx * 0.28f);
                } else if (rawOffset > maxOffset) {
                    damped =
                            maxOffset
                                    + MobileMotion.rubberBand(
                                            rawOffset - maxOffset, pageWidthPx * 0.28f);
                } else {
                    damped = rawOffset;
                }
                applyOffset(damped);
                return true;
            } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                if (getParent() != null) {
                    getParent().requestDisallowInterceptTouchEvent(false);
                }
                float dragDeltaX = ev.getRawX() - downX;
                velocityTracker.computeCurrentVelocity(1000, 7000f);
                float vx = velocityTracker.getXVelocity();
                recycleTracker();
                int target =
                        resolveHeroSwipeTargetPage(
                                currentIndex, slides.size(), dragDeltaX, vx, pageWidthPx);
                currentIndex = target;
                dragging = false;
                launchSnapSpring(target * (float) pageWidthPx, -vx);
                if (listener != null) listener.onPageSettled(target);
                return true;
            }
            return true;
        }

        @Override
        protected void onDetachedFromWindow() {
            stopSnapSpring();
            recycleTracker();
            super.onDetachedFromWindow();
        }
    }

    /**
     * Exact iOS 8-stop non-linear atmospheric dissolve shader painted across the bottom 56% of each
     * Hero slide. Because every slide's dissolve is updated LIVE to {@code liveAtmo} in lockstep
     * with {@link HeroAtmosphereView}, the bottom pixel row of the Hero ({@code y = heroHeightPx -
     * 1}) and the top of the continuous backdrop ({@code y = heroHeightPx}) stay bit-for-bit
     * identical even mid-swipe — zero horizontal seam line and zero Mach banding.
     */
    static final class HeroBottomDissolveView extends View {
        private static final float[] STOPS = {
            0.00f, 0.14f, 0.30f, 0.48f, 0.66f, 0.82f, 0.93f, 1.00f
        };
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int atmoColor = 0xFF1C2331;
        private int shaderColor = 0;
        private int shaderHeight = -1;

        HeroBottomDissolveView(MainActivity a) {
            super(a);
            setClickable(false);
            setFocusable(false);
        }

        void setAtmosphereColor(int color) {
            if (this.atmoColor != color) {
                this.atmoColor = color;
                this.shaderColor = 0;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            if (shaderHeight != h || shaderColor != atmoColor) {
                shaderHeight = h;
                shaderColor = atmoColor;
                int[] colors = {
                    MobileTheme.withAlpha(atmoColor, 0x00),
                    MobileTheme.withAlpha(atmoColor, 0x0F),
                    MobileTheme.withAlpha(atmoColor, 0x33),
                    MobileTheme.withAlpha(atmoColor, 0x75),
                    MobileTheme.withAlpha(atmoColor, 0xB8),
                    MobileTheme.withAlpha(atmoColor, 0xE6),
                    MobileTheme.withAlpha(atmoColor, 0xFA),
                    atmoColor
                };
                paint.setShader(
                        new LinearGradient(0f, 0f, 0f, h, colors, STOPS, Shader.TileMode.CLAMP));
            }
            canvas.drawRect(0f, 0f, w, h, paint);
        }
    }

    /** Extracts the natural lower-band tone (y in [60%, 94%]) matching iOS Rex Hero sampling. */
    static int extractHeroLowerBandColor(android.graphics.Bitmap bmp, int fallback) {
        if (bmp == null || bmp.isRecycled() || bmp.getWidth() < 4 || bmp.getHeight() < 4) {
            return fallback;
        }
        int w = bmp.getWidth();
        int h = bmp.getHeight();
        int yStart = Math.round(h * 0.60f);
        int yEnd = Math.min(h, Math.round(h * 0.94f));
        int stepX = Math.max(1, w / 24);
        int stepY = Math.max(1, (yEnd - yStart) / 14);
        long rSum = 0, gSum = 0, bSum = 0, wSum = 0;
        float[] hsv = new float[3];
        for (int y = yStart; y < yEnd; y += stepY) {
            for (int x = 0; x < w; x += stepX) {
                int c = bmp.getPixel(x, y);
                if (Color.alpha(c) < 128) continue;
                Color.colorToHSV(c, hsv);
                long weight = 1 + (long) (hsv[1] * 6f);
                if (hsv[2] > 0.10f && hsv[2] < 0.92f) weight += 2;
                rSum += Color.red(c) * weight;
                gSum += Color.green(c) * weight;
                bSum += Color.blue(c) * weight;
                wSum += weight;
            }
        }
        if (wSum <= 0) return fallback;
        return Color.rgb((int) (rSum / wSum), (int) (gSum / wSum), (int) (bSum / wSum));
    }

    /**
     * Full-bleed iOS-style swipeable cinema Hero Billboard anchored to physical screen {@code y =
     * 0}: loads true 1080p/2K HD posters via {@link ImageLoader#loadHeroHdPoster}, extracts real
     * lower-band Rex atmospheric colors, and dissolves with ZERO seam even mid-swipe.
     */
    private static void buildImmersiveHeroBillboard(
            final MobileRootShell shell,
            final Cms.Site site,
            final List<Cms.Video> featuredList,
            final FrameLayout heroHolder,
            final HeroAtmosphereView heroAtmosphereView,
            final View historyWrap,
            final View curatedWrap,
            final int heroWidthPx,
            final int heroHeightPx) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final int count = featuredList.size();
        final int[] slideAtmos = new int[count];
        final HeroBottomDissolveView[] slideDissolves = new HeroBottomDissolveView[count];
        final Runnable[] slideInkUpdaters = new Runnable[count];
        for (int i = 0; i < count; i++) {
            int seed = SeasonParser.defaultAmbientForTitle(featuredList.get(i).title);
            slideAtmos[i] = resolveRexHeroAtmosphere(seed, p.isDark);
        }
        final float[] lastFracPage = {0f};
        final View[] dots = count > 1 ? new View[count] : null;
        final int[] activeSlide = {0};
        final int[] liveAtmoRef = {slideAtmos[0]};

        final Runnable applyLiveAtmo =
                () -> {
                    float page = Math.max(0f, Math.min(count - 1, lastFracPage[0]));
                    int left = (int) Math.floor(page);
                    int right = Math.min(count - 1, (int) Math.ceil(page));
                    float frac = page - left;
                    int liveAtmo =
                            left == right
                                    ? slideAtmos[left]
                                    : MobileTheme.blend(slideAtmos[left], slideAtmos[right], frac);
                    liveAtmoRef[0] = liveAtmo;
                    heroHolder.setTag(liveAtmo);
                    boolean lightInk = useLightInkForHeroAtmo(liveAtmo, p.isDark);
                    if (heroAtmosphereView != null) {
                        heroAtmosphereView.setAtmosphereColor(liveAtmo);
                    }
                    // Update EVERY slide's bottom dissolve to identical liveAtmo -> zero seam
                    // mid-swipe!
                    for (int i = 0; i < count; i++) {
                        if (slideDissolves[i] != null) {
                            slideDissolves[i].setAtmosphereColor(liveAtmo);
                        }
                        if (slideInkUpdaters[i] != null) {
                            slideInkUpdaters[i].run();
                        }
                    }
                    shell.setAmbientColor(liveAtmo);
                    boolean historyShown =
                            historyWrap != null && historyWrap.getVisibility() == View.VISIBLE;
                    applyFirstShelfInk(historyWrap, p, historyShown, lightInk);
                    MobileCuratedSection.applyFirstHeaderInk(
                            curatedWrap, p, !historyShown, lightInk);
                    if (dots != null) {
                        int activeColor = lightInk ? Color.WHITE : 0xFF141821;
                        int inactiveColor = lightInk ? 0x73FFFFFF : 0x4D141821;
                        for (int i = 0; i < dots.length; i++) {
                            if (dots[i] == null) continue;
                            boolean sel = i == activeSlide[0];
                            dots[i].setBackground(a.bg(sel ? activeColor : inactiveColor, 999));
                        }
                    }
                };

        FrameLayout billboard = new FrameLayout(a);
        billboard.setTag("home-immersive-hero");

        final HeroPagerView pager =
                new HeroPagerView(
                        a,
                        heroWidthPx,
                        new HeroPagerView.PageListener() {
                            @Override
                            public void onFractionalPage(float page) {
                                lastFracPage[0] = page;
                                applyLiveAtmo.run();
                            }

                            @Override
                            public void onPageSettled(int index) {
                                activeSlide[0] = index;
                                lastFracPage[0] = index;
                                if (dots != null) {
                                    for (int i = 0; i < dots.length; i++) {
                                        View d = dots[i];
                                        if (d == null) continue;
                                        ViewGroup.LayoutParams dlp = d.getLayoutParams();
                                        int targetW = a.dp(i == index ? 18 : 5.5f);
                                        if (dlp != null && dlp.width != targetW) {
                                            dlp.width = targetW;
                                            d.setLayoutParams(dlp);
                                        }
                                    }
                                }
                                applyLiveAtmo.run();
                            }
                        });

        final int topVignetteH = a.statusBarHeight() + a.dp(74);
        final int bottomDissolveH = Math.round(heroHeightPx * 0.56f);
        final boolean isPrivateSite = a.privateMode;

        for (int idx = 0; idx < count; idx++) {
            final int slideIdx = idx;
            final Cms.Video featured = featuredList.get(idx);
            final FrameLayout slide = new FrameLayout(a);
            slide.setBackgroundColor(Color.TRANSPARENT);

            final ImageView poster = new ImageView(a);
            poster.setScaleType(ImageView.ScaleType.CENTER_CROP);
            slide.addView(poster, new FrameLayout.LayoutParams(-1, -1));

            // Subtle top cinema vignette strictly behind status bar & floating Marco Movie header
            View topScrim = new View(a);
            topScrim.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {0x75000000, 0x29000000, Color.TRANSPARENT}));
            slide.addView(topScrim, new FrameLayout.LayoutParams(-1, topVignetteH, Gravity.TOP));

            // Seamless iOS 8-stop non-linear atmospheric dissolve synchronized live with Layer 0
            final HeroBottomDissolveView bottomScrim = new HeroBottomDissolveView(a);
            slideDissolves[idx] = bottomScrim;
            slide.addView(
                    bottomScrim, new FrameLayout.LayoutParams(-1, bottomDissolveH, Gravity.BOTTOM));

            // Centered iOS Hero copy stack: eyebrow badge, bold title, meta, vibrant Watch CTA
            LinearLayout copy = a.vertical();
            copy.setGravity(Gravity.CENTER_HORIZONTAL);
            copy.setPadding(a.dp(24), 0, a.dp(24), 0);

            final LinearLayout eyebrow = a.row();
            eyebrow.setGravity(Gravity.CENTER_VERTICAL);
            eyebrow.setPadding(a.dp(10), a.dp(4), a.dp(11), a.dp(4));

            final MobileIcons.IconView sp =
                    MobileIcons.create(a, MobileIcons.IC_SPARKLE, 12f, 0xFF5AC8FA);
            sp.setFilled(true);
            LinearLayout.LayoutParams spLp = new LinearLayout.LayoutParams(a.dp(12), a.dp(12));
            spLp.rightMargin = a.dp(4);
            eyebrow.addView(sp, spLp);

            final TextView eyeText = a.text("今日首推 · " + site.name, 11f, Color.WHITE);
            eyeText.setTypeface(null, Typeface.BOLD);
            eyeText.setSingleLine(true);
            eyeText.setEllipsize(TextUtils.TruncateAt.END);
            eyebrow.addView(eyeText);
            LinearLayout.LayoutParams eyeLp = new LinearLayout.LayoutParams(-2, -2);
            eyeLp.bottomMargin = a.dp(8);
            copy.addView(eyebrow, eyeLp);

            final TextView titleTv =
                    a.text(featured.title == null ? "" : featured.title, 24f, Color.WHITE);
            titleTv.setTypeface(null, Typeface.BOLD);
            titleTv.setGravity(Gravity.CENTER);
            titleTv.setMaxLines(2);
            titleTv.setEllipsize(TextUtils.TruncateAt.END);
            titleTv.setLineSpacing(0f, 1.12f);
            copy.addView(titleTv, new LinearLayout.LayoutParams(-1, -2));

            StringBuilder meta = new StringBuilder();
            if (featured.year != null && !featured.year.trim().isEmpty()) {
                meta.append(featured.year.trim());
            }
            if (featured.area != null && !featured.area.trim().isEmpty()) {
                if (meta.length() > 0) meta.append(" · ");
                meta.append(featured.area.trim());
            }
            if (featured.remarks != null && !featured.remarks.trim().isEmpty()) {
                if (meta.length() > 0) meta.append(" · ");
                meta.append(featured.remarks.trim());
            }
            final TextView metaTv;
            if (meta.length() > 0) {
                metaTv = a.text(meta.toString(), 12.5f, 0xE6FFFFFF);
                metaTv.setGravity(Gravity.CENTER);
                metaTv.setSingleLine(true);
                metaTv.setEllipsize(TextUtils.TruncateAt.END);
                metaTv.setPadding(0, a.dp(5), 0, 0);
                copy.addView(metaTv, new LinearLayout.LayoutParams(-1, -2));
            } else {
                metaTv = null;
            }

            LinearLayout watchCta = a.row();
            watchCta.setGravity(Gravity.CENTER);
            watchCta.setPadding(a.dp(22), a.dp(9), a.dp(24), a.dp(9));
            watchCta.setBackground(MobileTheme.accentPillBg(a, 999));
            UiCompat.setElevation(watchCta, a.dp(4f));

            MobileIcons.IconView playIc =
                    MobileIcons.create(a, MobileIcons.IC_PLAY, 13.5f, p.accentOnFill);
            playIc.setFilled(true);
            LinearLayout.LayoutParams plLp =
                    new LinearLayout.LayoutParams(a.dp(13.5f), a.dp(13.5f));
            plLp.rightMargin = a.dp(6);
            watchCta.addView(playIc, plLp);

            TextView ctaLbl = a.text("立即观看", 13.5f, p.accentOnFill);
            ctaLbl.setTypeface(null, Typeface.BOLD);
            watchCta.addView(ctaLbl);

            MobileMotion.bindPress(watchCta, 0.94f);
            watchCta.setOnClickListener(
                    v ->
                            MobilePosterTransition.openDetailFromCard(
                                    a, site, featured, slide, 0f, true));
            LinearLayout.LayoutParams ctaLp = new LinearLayout.LayoutParams(-2, -2);
            ctaLp.topMargin = a.dp(11);
            copy.addView(watchCta, ctaLp);

            FrameLayout.LayoutParams copyLp =
                    new FrameLayout.LayoutParams(
                            -1, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            copyLp.bottomMargin = a.dp(count > 1 ? 30 : 16);
            slide.addView(copy, copyLp);

            final Boolean[] lastSlideLight = {null};
            slideInkUpdaters[idx] =
                    () -> {
                        boolean useLight = useLightInkForHeroAtmo(liveAtmoRef[0], p.isDark);
                        if (lastSlideLight[0] != null && lastSlideLight[0] == useLight) return;
                        lastSlideLight[0] = useLight;
                        int primaryInk = useLight ? Color.WHITE : 0xFF141821;
                        int secondaryInk = useLight ? 0xE6FFFFFF : 0xCC141821;
                        GradientDrawable eyeBg = a.bg(useLight ? 0x2BFFFFFF : 0x18000000, 999);
                        eyeBg.setStroke(
                                MobileTheme.hairlinePx(a), useLight ? 0x42FFFFFF : 0x26000000);
                        eyebrow.setBackground(eyeBg);
                        sp.setTint(useLight ? 0xFF5AC8FA : p.accent);
                        eyeText.setTextColor(primaryInk);
                        titleTv.setTextColor(primaryInk);
                        titleTv.setShadowLayer(
                                a.dp(useLight ? 6f : 3f),
                                0f,
                                a.dp(useLight ? 2f : 0f),
                                useLight ? 0x99000000 : 0x45FFFFFF);
                        if (metaTv != null) {
                            metaTv.setTextColor(secondaryInk);
                            metaTv.setShadowLayer(
                                    a.dp(useLight ? 4f : 2f),
                                    0f,
                                    a.dp(useLight ? 1f : 0f),
                                    useLight ? 0x80000000 : 0x38FFFFFF);
                        }
                    };
            slideInkUpdaters[idx].run();

            ImageLoader.loadHeroHdPoster(
                    a,
                    featured,
                    poster,
                    isPrivateSite,
                    slideIdx == 0,
                    bmp -> {
                        int extracted = extractHeroLowerBandColor(bmp, slideAtmos[slideIdx]);
                        slideAtmos[slideIdx] = resolveRexHeroAtmosphere(extracted, p.isDark);
                        applyLiveAtmo.run();
                    });

            slide.setOnClickListener(
                    v ->
                            MobilePosterTransition.openDetailFromCard(
                                    a, site, featured, slide, 0f, true));
            pager.addSlide(slide, heroHeightPx);
        }

        billboard.addView(pager, new FrameLayout.LayoutParams(-1, heroHeightPx));

        // Animated capsule page indicator dots
        if (count > 1 && dots != null) {
            LinearLayout dotRow = a.row();
            dotRow.setGravity(Gravity.CENTER);
            for (int i = 0; i < count; i++) {
                final int targetIdx = i;
                View dot = new View(a);
                dots[i] = dot;
                LinearLayout.LayoutParams dlp =
                        new LinearLayout.LayoutParams(a.dp(i == 0 ? 18 : 5.5f), a.dp(5.5f));
                dlp.leftMargin = a.dp(3);
                dlp.rightMargin = a.dp(3);
                dot.setOnClickListener(v -> pager.animateToPage(targetIdx));
                dotRow.addView(dot, dlp);
            }
            FrameLayout.LayoutParams drLp =
                    new FrameLayout.LayoutParams(
                            -2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            drLp.bottomMargin = a.dp(10);
            billboard.addView(dotRow, drLp);
        }

        applyLiveAtmo.run();
        heroHolder.addView(billboard, new FrameLayout.LayoutParams(-1, heroHeightPx));
    }

    /**
     * Pure-JVM helper comparing the top-5 poster-bearing Hero slides between a cold-start disk
     * snapshot and a fresh background refresh so unchanged Hero billboards stay untouched without
     * flicker or scroll jumps.
     */
    static boolean hasSameHeroLead(List<Cms.Video> prev, List<Cms.Video> next) {
        List<Cms.Video> prevHero = collectHeroCandidates(prev);
        List<Cms.Video> nextHero = collectHeroCandidates(next);
        if (prevHero.size() != nextHero.size() || prevHero.isEmpty()) return false;
        for (int i = 0; i < prevHero.size(); i++) {
            Cms.Video a = prevHero.get(i);
            Cms.Video b = nextHero.get(i);
            if (!java.util.Objects.equals(a.id, b.id)
                    || !java.util.Objects.equals(a.title, b.title)
                    || !java.util.Objects.equals(a.poster, b.poster)) {
                return false;
            }
        }
        return true;
    }

    private static List<Cms.Video> collectHeroCandidates(List<Cms.Video> videos) {
        List<Cms.Video> out = new ArrayList<>();
        if (videos == null) return out;
        for (Cms.Video cand : videos) {
            if (cand == null) continue;
            if (cand.id != null && cand.id.startsWith("netdisk_qr:")) continue;
            if (cand.poster == null || cand.poster.trim().isEmpty()) continue;
            out.add(cand);
            if (out.size() >= 5) break;
        }
        return out;
    }

    private static void presentVideos(
            MobileRootShell shell,
            final Cms.Site site,
            List<Cms.Video> videos,
            FrameLayout heroHolder,
            HeroAtmosphereView heroAtmosphereView,
            View historyWrap,
            View curatedWrap,
            LinearLayout gridWrap,
            boolean allowHero,
            int heroHeightPx) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        if (videos == null || videos.isEmpty()) return;

        int sideRailPx = shell.isSideRailLayout ? a.dp(90) : 0;
        int contentPx = Math.max(a.dp(240), a.windowWidth() - sideRailPx);

        if (allowHero
                && MobileHomeSections.isVisible(a, MobileHomeSections.ID_HERO_BILLBOARD)
                && heroHolder.getChildCount() == 0) {
            final List<Cms.Video> featuredList = new ArrayList<>();
            for (Cms.Video cand : videos) {
                if (cand == null) continue;
                if (cand.id != null && cand.id.startsWith("netdisk_qr:")) continue;
                if (cand.poster == null || cand.poster.trim().isEmpty()) continue;
                featuredList.add(cand);
                if (featuredList.size() >= 5) break;
            }
            if (!featuredList.isEmpty()) {
                buildImmersiveHeroBillboard(
                        shell,
                        site,
                        featuredList,
                        heroHolder,
                        heroAtmosphereView,
                        historyWrap,
                        curatedWrap,
                        contentPx,
                        heroHeightPx);
            }
        }

        float contentWidthDp = contentPx / a.getResources().getDisplayMetrics().density;
        int densityPref = a.prefs.getInt(Prefs.MOBILE_POSTER_DENSITY, 1);
        int cols = resolvePosterColumns(contentWidthDp, a.isPortrait(), densityPref);
        int gapPx = a.dp(10);
        int availW = Math.max(a.dp(220), contentPx - a.dp(32) - gapPx * (cols - 1));
        int cardW = availW / cols;
        int posterH = Math.round(cardW * 1.5f);

        LinearLayout row = null;
        int countInRow = 0;
        for (int i = 0; i < videos.size(); i++) {
            final Cms.Video v = videos.get(i);
            if (row == null || countInRow == cols) {
                row = a.row();
                row.setGravity(Gravity.TOP);
                row.setBaselineAligned(false);
                LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(-1, -2);
                rLp.bottomMargin = a.dp(14);
                gridWrap.addView(row, rLp);
                countInRow = 0;
            }
            LinearLayout card = buildPosterCard(a, cardW, posterH, v.title, v.remarks, v.poster);
            final View posterAnchor = card.findViewWithTag("poster-card-box");
            card.setOnClickListener(
                    view ->
                            MobilePosterTransition.openDetailFromCard(
                                    a,
                                    site,
                                    v,
                                    posterAnchor != null ? posterAnchor : card,
                                    12f,
                                    false));
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (countInRow < cols - 1) cLp.rightMargin = gapPx;
            row.addView(card, cLp);
            countInRow++;
        }
        if (row != null && countInRow > 0 && countInRow < cols) {
            for (int pad = countInRow; pad < cols; pad++) {
                LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(0, 1, 1f);
                if (pad < cols - 1) pLp.rightMargin = gapPx;
                row.addView(new View(a), pLp);
            }
        }
    }

    static LinearLayout buildPosterCard(
            MainActivity a,
            int cardW,
            int posterH,
            String title,
            String badgeText,
            String posterUrl) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout card = a.vertical();
        FrameLayout box = new FrameLayout(a);
        box.setTag("poster-card-box");
        box.setClipToOutline(true);
        box.setBackground(MobileTheme.subtleBg(a, 12));

        ImageView img = new ImageView(a);
        img.setScaleType(ImageView.ScaleType.CENTER_CROP);
        if (posterUrl != null && !posterUrl.isEmpty()) a.poster(posterUrl, img);
        box.addView(img, new FrameLayout.LayoutParams(-1, posterH));

        int subtitleMode = a.prefs.getInt(Prefs.MOBILE_CARD_SUBTITLE, 0);
        boolean showBadge = subtitleMode != 2;
        boolean showTitle = subtitleMode != 1;

        if (showBadge && badgeText != null && !badgeText.trim().isEmpty()) {
            TextView rem = a.text(badgeText.trim(), 10f, Color.WHITE);
            rem.setSingleLine(true);
            rem.setEllipsize(TextUtils.TruncateAt.END);
            rem.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(2));
            rem.setBackground(a.bg(0xBF0A0B0E, 6));
            FrameLayout.LayoutParams bLp =
                    new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.RIGHT);
            bLp.setMargins(a.dp(5), 0, a.dp(5), a.dp(5));
            box.addView(rem, bLp);
        }
        card.addView(box, new LinearLayout.LayoutParams(-1, posterH));

        if (showTitle) {
            TextView t = a.text(title == null ? "" : title, 12.5f, p.textPrimary);
            t.setSingleLine(true);
            t.setMaxLines(1);
            t.setEllipsize(TextUtils.TruncateAt.END);
            t.setPadding(a.dp(2), a.dp(6), a.dp(2), 0);
            card.addView(t, new LinearLayout.LayoutParams(-1, -2));
        }
        MobileMotion.bindPress(card, 0.97f);
        return card;
    }

    static void openVideoOrFolder(MainActivity a, Cms.Site site, Cms.Video v) {
        if (v == null) return;
        if (a.redirectListing(site, v)) return;
        a.open(new MainActivity.Screen(() -> a.detail(site, v)), true);
    }

    /**
     * Unified iOS-style Curated Discovery Home rendered even BEFORE the user adds any subscription
     * source: displays the full-bleed zero-seam HD Hero + all 6 editorial modules ({@link
     * MobileCuratedSection}) + smart clipboard import prompt & top-right {@code + 导入片源} CTA.
     * Tapping any item opens {@link MobileDetailScreen}, which clearly prompts to add resources.
     */
    private static void renderCuratedDiscoveryHome(
            final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final Cms.Site curatedSite = MobileCuratedDiscovery.curatedSiteSentinel();

        FrameLayout page = new FrameLayout(a);
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        final int heroHeightPx =
                computeImmersiveHeroHeightPx(a.windowHeight(), a.dp(376), a.dp(508));

        final ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);

        FrameLayout scrollContentHost = new FrameLayout(a);
        final HeroAtmosphereView heroAtmosphereView =
                new HeroAtmosphereView(a, heroHeightPx, a.dp(26), a.dp(148));
        scrollContentHost.addView(
                heroAtmosphereView,
                new FrameLayout.LayoutParams(-1, heroHeightPx + a.dp(174), Gravity.TOP));

        final boolean showHero =
                MobileHomeSections.isVisible(a, MobileHomeSections.ID_HERO_BILLBOARD);
        final boolean showHistorySection =
                MobileHomeSections.isVisible(a, MobileHomeSections.ID_WATCH_HISTORY)
                        && !a.watchHistory().isEmpty();
        final List<String> enabledCurated = MobileHomeSections.visibleCuratedIds(a);
        final boolean allHidden = MobileHomeSections.areAllHidden(a, false);

        final int standardTopPad = a.statusBarHeight() + a.dp(56);
        final LinearLayout body = a.vertical();
        final int bottomPad = a.navigationBarHeight() + a.dp(108);
        body.setPadding(0, showHero ? 0 : standardTopPad, 0, bottomPad);
        scrollContentHost.addView(body, new FrameLayout.LayoutParams(-1, -2));
        sv.addView(scrollContentHost, new ScrollView.LayoutParams(-1, -2));
        page.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        final FrameLayout heroHolder = new FrameLayout(a);
        heroHolder.setVisibility(showHero ? View.VISIBLE : View.GONE);
        heroAtmosphereView.setVisibility(showHero ? View.VISIBLE : View.GONE);
        body.addView(heroHolder, new LinearLayout.LayoutParams(-1, -2));

        // Optional 1-tap clipboard import banner when user copied a source URL
        final String detectedClip = detectClipboardCandidate(a);
        if (detectedClip != null) {
            String kind = UiWidgets.classifyImportCandidate(detectedClip);
            final LinearLayout clipBanner = a.row();
            clipBanner.setGravity(Gravity.CENTER_VERTICAL);
            clipBanner.setBackground(MobileTheme.cardBg(a, 16));
            clipBanner.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
            TextView cTxt = a.text("检测到剪贴板中的" + kind, 13f, p.textPrimary);
            cTxt.setTypeface(null, Typeface.BOLD);
            clipBanner.addView(cTxt, new LinearLayout.LayoutParams(0, -2, 1f));
            TextView cBtn = a.text("立即导入", 12.5f, p.accentOnFill);
            cBtn.setTypeface(null, Typeface.BOLD);
            cBtn.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
            cBtn.setBackground(MobileTheme.accentPillBg(a, 999));
            MobileMotion.bindPress(cBtn, 0.94f);
            cBtn.setOnClickListener(v -> UiWidgets.pasteConfigFromClipboard(a));
            clipBanner.addView(cBtn);
            LinearLayout.LayoutParams cbLp = new LinearLayout.LayoutParams(-1, -2);
            cbLp.setMargins(a.dp(16), a.dp(10), a.dp(16), a.dp(4));
            body.addView(clipBanner, cbLp);
        }

        final LinearLayout historyWrap = a.vertical();
        body.addView(historyWrap, new LinearLayout.LayoutParams(-1, -2));
        if (showHistorySection) {
            renderContinueWatchingStrip(a, historyWrap);
        } else {
            historyWrap.setVisibility(View.GONE);
        }

        final LinearLayout curatedWrap = a.vertical();
        curatedWrap.setPadding(0, a.dp(8), 0, a.dp(12));
        curatedWrap.setVisibility(enabledCurated.isEmpty() ? View.GONE : View.VISIBLE);
        body.addView(curatedWrap, new LinearLayout.LayoutParams(-1, -2));

        if (allHidden) {
            body.addView(buildAllSectionsHiddenCard(shell), new LinearLayout.LayoutParams(-1, -2));
        }

        // Floating iOS-style Top Brand Header + "+ 导入片源" pill
        final LinearLayout floatingTopBar = a.vertical();
        floatingTopBar.setPadding(a.dp(16), a.statusBarHeight() + a.dp(6), a.dp(16), a.dp(10));
        page.addView(floatingTopBar, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        final TextView[] brandWordmarkRef = {null};
        LinearLayout brandLockup =
                buildBrandWordmark(
                        a,
                        showHero || p.isDark,
                        showHero,
                        brandWordmarkRef,
                        () -> {
                            if (sv.getScrollY() > a.dp(16)) {
                                sv.smoothScrollTo(0, 0);
                            } else {
                                UiWidgets.showMobileImportDialog(a);
                            }
                        });
        LinearLayout.LayoutParams tbLp = new LinearLayout.LayoutParams(-2, -2);
        tbLp.rightMargin = a.dp(8);
        topRow.addView(brandLockup, tbLp);
        topRow.addView(new View(a), new LinearLayout.LayoutParams(0, 1, 1f));

        final LinearLayout importPill = a.row();
        importPill.setGravity(Gravity.CENTER_VERTICAL);
        importPill.setPadding(a.dp(11), 0, a.dp(11), 0);
        GradientDrawable glassPill = a.bg(showHero ? 0x450E121C : p.bgSubtle, 999);
        glassPill.setStroke(
                MobileTheme.hairlinePx(a),
                showHero ? 0x33FFFFFF : (p.isDark ? 0x1EFFFFFF : 0x12000000));
        importPill.setBackground(glassPill);

        MobileIcons.IconView plusIcon =
                MobileIcons.create(a, MobileIcons.IC_PLUS, 13f, showHero ? 0xEBFFFFFF : p.accent);
        LinearLayout.LayoutParams spLp = new LinearLayout.LayoutParams(a.dp(13), a.dp(13));
        spLp.rightMargin = a.dp(5);
        importPill.addView(plusIcon, spLp);

        TextView modeLbl = a.text("导入片源", 12.5f, showHero ? 0xF5FFFFFF : p.textPrimary);
        modeLbl.setTag("source-switcher");
        modeLbl.setTypeface(null, Typeface.BOLD);
        importPill.addView(modeLbl);

        MobileMotion.bindPress(importPill, 0.94f);
        importPill.setOnClickListener(v -> UiWidgets.showMobileImportDialog(a));
        topRow.addView(importPill, new LinearLayout.LayoutParams(-2, a.dp(34)));
        floatingTopBar.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        final Boolean[] lastOverHeroState = {null};
        final Runnable syncPolarity =
                () -> {
                    if (!showHero) {
                        floatingTopBar.setTranslationY(0f);
                        shell.setStatusBarVeilAlpha(1f);
                        a.applyMobileSystemBars(false, false);
                        return;
                    }
                    int scrollY = sv.getScrollY();
                    floatingTopBar.setTranslationY(-Math.min(scrollY, heroHeightPx));
                    float veilAlpha =
                            Math.max(
                                    0f,
                                    Math.min(
                                            1f,
                                            (scrollY - heroHeightPx * 0.25f)
                                                    / Math.max(1f, heroHeightPx * 0.24f)));
                    shell.setStatusBarVeilAlpha(veilAlpha);
                    boolean overHero = scrollY < Math.round(heroHeightPx * 0.44f);
                    if (lastOverHeroState[0] != null && lastOverHeroState[0] == overHero) return;
                    lastOverHeroState[0] = overHero;
                    a.applyMobileSystemBars(false, overHero);
                };
        syncPolarity.run();
        shell.bindScrollBehavior(sv, syncPolarity);

        final int sideRailPx = shell.isSideRailLayout ? a.dp(90) : 0;
        final int contentPx = Math.max(a.dp(240), a.windowWidth() - sideRailPx);
        final boolean[] heroBuiltWithLivePosters = {false};

        final Runnable renderAll =
                () -> {
                    boolean curatedIsFirst = historyWrap.getVisibility() != View.VISIBLE;
                    if (!enabledCurated.isEmpty()) {
                        MobileCuratedSection.renderInto(
                                a, curatedWrap, false, showHero && curatedIsFirst, enabledCurated);
                    }
                    if (!showHero) {
                        MobileCuratedSection.applyFirstHeaderInk(curatedWrap, p, false, false);
                        return;
                    }
                    List<Cms.Video> heroPool = new ArrayList<>();
                    List<Cms.Video> trend =
                            MobileCuratedDiscovery.peekById(
                                    MobileCuratedDiscovery.ID_WEEKLY_TRENDING);
                    List<Cms.Video> cnHot =
                            MobileCuratedDiscovery.peekById(MobileCuratedDiscovery.ID_CN_HOT);
                    for (Cms.Video v : trend) {
                        if (v != null && v.poster != null && !v.poster.trim().isEmpty()) {
                            heroPool.add(v);
                            if (heroPool.size() >= 3) break;
                        }
                    }
                    for (Cms.Video v : cnHot) {
                        if (v != null && v.poster != null && !v.poster.trim().isEmpty()) {
                            heroPool.add(v);
                            if (heroPool.size() >= 5) break;
                        }
                    }
                    boolean hasLiveHero = !heroPool.isEmpty();
                    if (!hasLiveHero) {
                        for (int i = 0; i < Math.min(5, trend.size()); i++) {
                            heroPool.add(trend.get(i));
                        }
                    }

                    if (!heroPool.isEmpty()
                            && (heroHolder.getChildCount() == 0
                                    || (hasLiveHero && !heroBuiltWithLivePosters[0]))) {
                        heroHolder.removeAllViews();
                        buildImmersiveHeroBillboard(
                                shell,
                                curatedSite,
                                heroPool,
                                heroHolder,
                                heroAtmosphereView,
                                historyWrap,
                                curatedWrap,
                                contentPx,
                                heroHeightPx);
                        if (hasLiveHero) heroBuiltWithLivePosters[0] = true;
                    } else if (curatedIsFirst && heroHolder.getTag() instanceof Integer) {
                        boolean lightInk =
                                useLightInkForHeroAtmo((Integer) heroHolder.getTag(), p.isDark);
                        MobileCuratedSection.applyFirstHeaderInk(curatedWrap, p, true, lightInk);
                    }
                };

        final Runnable debouncedRender =
                () -> {
                    a.ui.removeCallbacks(renderAll);
                    a.ui.postDelayed(renderAll, 160L);
                };
        MobileCuratedDiscovery.hydrateFromDiskIfNeeded(a);
        renderAll.run();
        if (showHero || !enabledCurated.isEmpty()) {
            MobileCuratedDiscovery.fetchAllAsync(a, a.generation, debouncedRender);
        }
    }

    private static LinearLayout buildAllSectionsHiddenCard(final MobileRootShell shell) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout card = a.vertical();
        card.setTag("home-all-sections-hidden");
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setBackground(MobileTheme.cardBg(a, 18));
        card.setPadding(a.dp(20), a.dp(26), a.dp(20), a.dp(24));
        LinearLayout.LayoutParams outerLp = new LinearLayout.LayoutParams(-1, -2);
        outerLp.setMargins(a.dp(16), a.dp(24), a.dp(16), a.dp(16));
        card.setLayoutParams(outerLp);

        TextView title = a.text("所有首页专题均已隐藏", 16.5f, p.textPrimary);
        title.setTypeface(null, Typeface.BOLD);
        card.addView(title);
        a.gap(card, 8);

        TextView desc = a.text("你可以随时在此重新开启首页专题，或前往底部「设置 → 外观与导航」恢复默认显示。", 12.5f, p.textSecondary);
        desc.setGravity(Gravity.CENTER);
        desc.setLineSpacing(a.dp(2), 1f);
        card.addView(desc);
        a.gap(card, 16);

        LinearLayout btnRow = a.row();
        TextView manageBtn = a.text("管理首页专题", 13f, p.accentOnFill);
        manageBtn.setTypeface(null, Typeface.BOLD);
        manageBtn.setGravity(Gravity.CENTER);
        manageBtn.setPadding(a.dp(16), a.dp(10), a.dp(16), a.dp(10));
        manageBtn.setBackground(MobileTheme.accentPillBg(a, 999));
        MobileMotion.bindPress(manageBtn, 0.95f);
        manageBtn.setOnClickListener(
                v ->
                        MobileHomeSections.showSettingsSheet(
                                a, () -> shell.switchTab(MobileRootShell.TAB_HOME)));
        LinearLayout.LayoutParams b1 = new LinearLayout.LayoutParams(0, -2, 1f);
        b1.rightMargin = a.dp(8);
        btnRow.addView(manageBtn, b1);

        TextView settingsBtn = a.text("前往设置", 13f, p.textPrimary);
        settingsBtn.setTypeface(null, Typeface.BOLD);
        settingsBtn.setGravity(Gravity.CENTER);
        settingsBtn.setPadding(a.dp(16), a.dp(10), a.dp(16), a.dp(10));
        settingsBtn.setBackground(MobileTheme.subtleBg(a, 999));
        MobileMotion.bindPress(settingsBtn, 0.95f);
        settingsBtn.setOnClickListener(v -> shell.switchTab(MobileRootShell.TAB_SETTINGS));
        btnRow.addView(settingsBtn, new LinearLayout.LayoutParams(0, -2, 1f));
        card.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));
        return card;
    }
}

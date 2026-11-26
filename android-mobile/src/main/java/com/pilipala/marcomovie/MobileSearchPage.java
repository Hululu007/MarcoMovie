package com.pilipala.marcomovie;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import org.json.JSONArray;

/**
 * Mobile multi-source concurrent Search Page (Day/Night {@link MobileTheme} + {@link MobileIcons} +
 * {@link MobileMotion}):
 * - Native soft-keyboard borderless search bar ({@link MobileSectionGroup#searchBar}) with
 *   auto-focus on fresh empty entry, {@link MobileMotion#shakeInvalid} on empty submit, 1-tap
 *   clipboard paste, and {@link MobileBottomSheet#showConfirm}-guarded search history
 * - Reversible site filter pills (tapping the active site filter toggles back to {@code 全部}) and
 *   helpful 0-hit recovery CTA
 * - Isolates every query inside a dedicated {@link SearchSession} verified against space, config,
 *   engine epoch, generation, and page validity before updating results or cache.
 * - Optional title purification ({@link EpisodeNameCleaner#cleanSearchTitle}).
 */
final class MobileSearchPage {
    static final class Hit {
        final Cms.Site site;
        final Cms.Video video;

        Hit(Cms.Site site, Cms.Video video) {
            this.site = site;
            this.video = video;
        }
    }

    /** Per-query isolated state preventing late callbacks from mixing into newer queries. */
    static final class SearchSession {
        final long querySeq;
        final long pageToken;
        final String keyword;
        final boolean privateMode;
        final Object config;
        final int engineEpoch;
        final int generation;
        final int totalSites;
        final boolean exactMode;
        private final List<Hit> hits = new ArrayList<>();
        private int doneCount;
        private String status = "";
        private String selectedSiteFilter = "";
        volatile boolean cancelled;
        volatile ExecutorService pool;

        SearchSession(
                long querySeq,
                long pageToken,
                String keyword,
                boolean privateMode,
                Object config,
                int engineEpoch,
                int generation,
                int totalSites) {
            this(
                    querySeq,
                    pageToken,
                    keyword,
                    privateMode,
                    config,
                    engineEpoch,
                    generation,
                    totalSites,
                    false);
        }

        SearchSession(
                long querySeq,
                long pageToken,
                String keyword,
                boolean privateMode,
                Object config,
                int engineEpoch,
                int generation,
                int totalSites,
                boolean exactMode) {
            this.querySeq = querySeq;
            this.pageToken = pageToken;
            this.keyword = keyword == null ? "" : keyword;
            this.privateMode = privateMode;
            this.config = config;
            this.engineEpoch = engineEpoch;
            this.generation = generation;
            this.totalSites = Math.max(0, totalSites);
            this.exactMode = exactMode;
            this.status = (exactMode ? "精准匹配：正在并发检索 " : "正在并发检索 ") + this.totalSites + " 个片源…";
        }

        synchronized boolean isComplete() {
            return doneCount >= totalSites;
        }

        synchronized boolean matchesContext(boolean curPrivate, Object curConfig, int curEpoch) {
            return privateMode == curPrivate && config == curConfig && engineEpoch == curEpoch;
        }

        synchronized boolean acceptSiteBatch(
                long activeSeq,
                long activePageToken,
                boolean curPrivate,
                Object curConfig,
                int curEpoch,
                int curGeneration,
                List<Hit> batch) {
            if (cancelled
                    || querySeq != activeSeq
                    || pageToken != activePageToken
                    || privateMode != curPrivate
                    || config != curConfig
                    || engineEpoch != curEpoch
                    || generation != curGeneration) {
                return false;
            }
            if (batch != null && !batch.isEmpty()) {
                if (exactMode) {
                    for (int i = 0; i < batch.size(); i++) {
                        Hit h = batch.get(i);
                        if (h != null
                                && h.video != null
                                && SearchRanking.isExactTitleMatch(h.video.title, keyword)) {
                            hits.add(h);
                        }
                    }
                } else {
                    hits.addAll(batch);
                }
            }
            doneCount = Math.min(totalSites, doneCount + 1);
            status =
                    (exactMode ? "精准匹配 · " : "")
                            + "已检索 "
                            + doneCount
                            + "/"
                            + totalSites
                            + " 个片源 · 命中 "
                            + hits.size()
                            + " 条结果";
            return true;
        }

        synchronized List<Hit> snapshotHits() {
            return new ArrayList<>(hits);
        }

        synchronized List<Hit> filteredHits() {
            if (selectedSiteFilter.isEmpty()) {
                return new ArrayList<>(hits);
            }
            List<Hit> out = new ArrayList<>();
            for (Hit h : hits) {
                if (selectedSiteFilter.equals(h.site.key)) {
                    out.add(h);
                }
            }
            return out;
        }

        synchronized Map<String, Integer> siteCounts() {
            Map<String, Integer> counts = new LinkedHashMap<>();
            for (Hit h : hits) {
                Integer prev = counts.get(h.site.key);
                counts.put(h.site.key, (prev == null ? 0 : prev) + 1);
            }
            return counts;
        }

        synchronized String status() {
            return status;
        }

        synchronized String selectedSiteFilter() {
            return selectedSiteFilter;
        }

        synchronized void setSelectedSiteFilter(String siteKey) {
            this.selectedSiteFilter = siteKey == null ? "" : siteKey;
        }

        void cancelPool() {
            cancelled = true;
            ExecutorService p = pool;
            pool = null;
            if (p != null) {
                p.shutdownNow();
            }
        }
    }

    /**
     * Pure incremental-append planner used by {@link #render} to avoid tearing down the
     * {@link ScrollView} and rebuilding already-visible result cards when additional concurrent
     * sources arrive (#45). Preserves scroll position and click-target view identity across batches.
     */
    static final class IncrementalResultPlan {
        static final class Diff {
            final boolean fullRebuild;
            final int appendFromIndex;

            Diff(boolean fullRebuild, int appendFromIndex) {
                this.fullRebuild = fullRebuild;
                this.appendFromIndex = appendFromIndex;
            }
        }

        private long boundQuerySeq = -1L;
        private String boundFilter = "";
        private boolean boundSidebar;
        private boolean boundExactMode;
        private int processedHitCount;
        int fullRebuildCount;
        int incrementalUpdateCount;

        void reset() {
            boundQuerySeq = -1L;
            boundFilter = "";
            boundExactMode = false;
            processedHitCount = 0;
        }

        Diff planUpdate(long querySeq, String filter, boolean useSidebar, int totalHits) {
            return planUpdate(querySeq, filter, useSidebar, boundExactMode, totalHits);
        }

        Diff planUpdate(
                long querySeq,
                String filter,
                boolean useSidebar,
                boolean exactMode,
                int totalHits) {
            String f = filter == null ? "" : filter;
            boolean needFull =
                    boundQuerySeq != querySeq
                            || !boundFilter.equals(f)
                            || boundSidebar != useSidebar
                            || boundExactMode != exactMode
                            || totalHits < processedHitCount;
            if (needFull) {
                boundQuerySeq = querySeq;
                boundFilter = f;
                boundSidebar = useSidebar;
                boundExactMode = exactMode;
                processedHitCount = totalHits;
                fullRebuildCount++;
                return new Diff(true, 0);
            }
            int from = processedHitCount;
            processedHitCount = totalHits;
            incrementalUpdateCount++;
            return new Diff(false, from);
        }
    }

    private static final Object SESSION_LOCK = new Object();
    private static final AtomicLong QUERY_SEQ = new AtomicLong(0L);
    private static final AtomicLong PAGE_TOKEN = new AtomicLong(0L);
    private static SearchSession activeSession;

    private MobileSearchPage() {}

    /** Pure-JVM reversible site filter toggle: tapping the active site returns {@code ""} (全部). */
    static String toggleSiteFilter(String currentFilter, String tappedSiteKey) {
        String cur = currentFilter == null ? "" : currentFilter;
        String tapped = tappedSiteKey == null ? "" : tappedSiteKey;
        if (tapped.isEmpty() || tapped.equals(cur)) {
            return "";
        }
        return tapped;
    }

    static long beginPage() {
        return PAGE_TOKEN.incrementAndGet();
    }

    static void onPageExit() {
        PAGE_TOKEN.incrementAndGet();
        synchronized (SESSION_LOCK) {
            if (activeSession != null && !activeSession.isComplete()) {
                activeSession.cancelPool();
                activeSession = null;
            }
        }
    }

    static void invalidateSession() {
        PAGE_TOKEN.incrementAndGet();
        QUERY_SEQ.incrementAndGet();
        synchronized (SESSION_LOCK) {
            if (activeSession != null) {
                activeSession.cancelPool();
                activeSession = null;
            }
        }
    }

    static void clearCachedResults() {
        invalidateSession();
    }

    static SearchSession startSession(
            long pageToken,
            String keyword,
            boolean privateMode,
            Object config,
            int engineEpoch,
            int generation,
            int totalSites) {
        return startSession(
                pageToken,
                keyword,
                privateMode,
                config,
                engineEpoch,
                generation,
                totalSites,
                false);
    }

    static SearchSession startSession(
            long pageToken,
            String keyword,
            boolean privateMode,
            Object config,
            int engineEpoch,
            int generation,
            int totalSites,
            boolean exactMode) {
        synchronized (SESSION_LOCK) {
            if (activeSession != null) {
                activeSession.cancelPool();
            }
            long currentToken = PAGE_TOKEN.get();
            long effectivePageToken =
                    pageToken == currentToken ? pageToken : PAGE_TOKEN.incrementAndGet();
            long seq = QUERY_SEQ.incrementAndGet();
            activeSession =
                    new SearchSession(
                            seq,
                            effectivePageToken,
                            keyword,
                            privateMode,
                            config,
                            engineEpoch,
                            generation,
                            totalSites,
                            exactMode);
            return activeSession;
        }
    }

    static boolean acceptBatchIfCurrent(
            SearchSession session,
            boolean curPrivate,
            Object curConfig,
            int curEpoch,
            int curGeneration,
            List<Hit> batch) {
        synchronized (SESSION_LOCK) {
            if (session == null || session != activeSession) {
                return false;
            }
            return session.acceptSiteBatch(
                    QUERY_SEQ.get(),
                    PAGE_TOKEN.get(),
                    curPrivate,
                    curConfig,
                    curEpoch,
                    curGeneration,
                    batch);
        }
    }

    static SearchSession cachedSessionFor(boolean curPrivate, Object curConfig, int curEpoch) {
        synchronized (SESSION_LOCK) {
            if (activeSession != null
                    && !activeSession.cancelled
                    && activeSession.matchesContext(curPrivate, curConfig, curEpoch)) {
                return activeSession;
            }
            return null;
        }
    }

    static void render(final MobileRootShell shell, final FrameLayout container) {
        final MainActivity a = shell.a;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final long[] pageTokenHolder = {beginPage()};

        LinearLayout page = a.vertical();
        page.setPadding(a.dp(16), a.statusBarHeight() + a.dp(10), a.dp(16), 0);
        page.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    @Override
                    public void onViewAttachedToWindow(View v) {
                        if (PAGE_TOKEN.get() != pageTokenHolder[0]) {
                            pageTokenHolder[0] = beginPage();
                        }
                    }

                    @Override
                    public void onViewDetachedFromWindow(View v) {
                        if (PAGE_TOKEN.get() == pageTokenHolder[0]) {
                            onPageExit();
                        }
                    }
                });
        container.addView(page, new FrameLayout.LayoutParams(-1, -1));

        // 1. Borderless Search Input Row (MobileSectionGroup.searchBar + Paste + Search CTA)
        LinearLayout searchRow = a.row();
        searchRow.setGravity(Gravity.CENTER_VERTICAL);

        final EditText input = new EditText(a);
        LinearLayout searchBar = MobileSectionGroup.searchBar(a, input, "搜索电影、剧集、动漫、演员…", null);
        searchRow.addView(searchBar, new LinearLayout.LayoutParams(0, a.dp(42), 1f));

        FrameLayout pasteChip = new FrameLayout(a);
        pasteChip.setBackground(MobileTheme.subtleBg(a, 14));
        pasteChip.setContentDescription("粘贴剪贴板");
        MobileIcons.IconView pasteIcon =
                MobileIcons.create(a, MobileIcons.IC_CLIPBOARD, 17f, p.textSecondary);
        pasteChip.addView(
                pasteIcon, new FrameLayout.LayoutParams(a.dp(17), a.dp(17), Gravity.CENTER));
        MobileMotion.bindPress(pasteChip, 0.92f);
        LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(40), a.dp(42));
        pLp.leftMargin = a.dp(8);
        searchRow.addView(pasteChip, pLp);

        TextView goBtn = a.text("搜索", 13.5f, p.accentOnFill);
        goBtn.setTypeface(null, Typeface.BOLD);
        goBtn.setGravity(Gravity.CENTER);
        goBtn.setPadding(a.dp(16), 0, a.dp(16), 0);
        goBtn.setBackground(MobileTheme.accentPillBg(a, 14));
        MobileMotion.bindPress(goBtn, 0.94f);
        LinearLayout.LayoutParams goLp = new LinearLayout.LayoutParams(-2, a.dp(42));
        goLp.leftMargin = a.dp(8);
        searchRow.addView(goBtn, goLp);

        page.addView(searchRow, new LinearLayout.LayoutParams(-1, -2));

        // 1b. Fuzzy vs Exact Match mode toggle row (原 7: 精准搜索模式)
        final boolean[] exactMode = {
            a.mobilePrefs().getBoolean(Prefs.MOBILE_SEARCH_EXACT_MODE, false)
        };
        LinearLayout modeRow = a.row();
        modeRow.setGravity(Gravity.CENTER_VERTICAL);
        modeRow.setPadding(0, a.dp(10), 0, a.dp(2));

        final TextView fuzzyPill = a.text("模糊聚合", 12.5f, p.textPrimary);
        fuzzyPill.setSingleLine(true);
        fuzzyPill.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
        MobileMotion.bindPress(fuzzyPill, 0.94f);
        LinearLayout.LayoutParams fLp = new LinearLayout.LayoutParams(-2, -2);
        fLp.rightMargin = a.dp(8);
        modeRow.addView(fuzzyPill, fLp);

        final TextView exactPill = a.text("精准匹配", 12.5f, p.textPrimary);
        exactPill.setSingleLine(true);
        exactPill.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
        MobileMotion.bindPress(exactPill, 0.94f);
        LinearLayout.LayoutParams eLp = new LinearLayout.LayoutParams(-2, -2);
        eLp.rightMargin = a.dp(8);
        modeRow.addView(exactPill, eLp);

        final TextView modeHint = a.text("", 11.5f, p.textTertiary);
        modeHint.setSingleLine(true);
        modeHint.setEllipsize(TextUtils.TruncateAt.END);
        modeRow.addView(modeHint, new LinearLayout.LayoutParams(0, -2, 1f));
        page.addView(modeRow, new LinearLayout.LayoutParams(-1, -2));

        final Runnable updateModePills =
                () -> {
                    boolean exact = exactMode[0];
                    fuzzyPill.setTextColor(!exact ? p.accent : p.textSecondary);
                    fuzzyPill.setTypeface(null, !exact ? Typeface.BOLD : Typeface.NORMAL);
                    fuzzyPill.setBackground(MobileTheme.pillBg(a, !exact, 999));
                    exactPill.setTextColor(exact ? p.accent : p.textSecondary);
                    exactPill.setTypeface(null, exact ? Typeface.BOLD : Typeface.NORMAL);
                    exactPill.setBackground(MobileTheme.pillBg(a, exact, 999));
                    modeHint.setText(exact ? "仅保留原始完整片名完全一致的结果" : "精确命中优先 · 跨源聚合");
                };
        updateModePills.run();

        // 2. History chips + status row
        final LinearLayout historySection = a.vertical();
        historySection.setPadding(0, a.dp(10), 0, a.dp(4));
        page.addView(historySection, new LinearLayout.LayoutParams(-1, -2));

        final TextView statusText = a.text("", 12.5f, p.textSecondary);
        statusText.setPadding(a.dp(2), a.dp(6), a.dp(2), a.dp(6));
        page.addView(statusText, new LinearLayout.LayoutParams(-1, -2));

        // 3. Results area (either Top Filter Pills + Vertical Scroll, or Left Sidebar + Right List)
        final FrameLayout resultsStage = new FrameLayout(a);
        page.addView(resultsStage, new LinearLayout.LayoutParams(-1, 0, 1f));

        final SearchSession[] displayedSession = {null};
        final IncrementalResultPlan renderPlan = new IncrementalResultPlan();
        final LinearLayout[] filterContainerRef = {null};
        final LinearLayout[] listContainerRef = {null};
        final TextView[] allFilterChipRef = {null};
        final Map<String, TextView> siteFilterChips = new LinkedHashMap<>();
        final Runnable[] runSearch = new Runnable[1];
        final int bottomPad = a.navigationBarHeight() + a.dp(106);

        final Runnable rebuildResults =
                new Runnable() {
                    @Override
                    public void run() {
                        final SearchSession session = displayedSession[0];
                        if (session == null
                                || session.cancelled
                                || !session.matchesContext(
                                        a.privateMode, a.config, a.engineEpoch)) {
                            renderPlan.reset();
                            filterContainerRef[0] = null;
                            listContainerRef[0] = null;
                            allFilterChipRef[0] = null;
                            siteFilterChips.clear();
                            resultsStage.removeAllViews();
                            return;
                        }
                        List<Hit> snapshot =
                                SearchRanking.rankAndFilter(
                                        session.snapshotHits(), session.keyword, session.exactMode);
                        if (snapshot.isEmpty()) {
                            renderPlan.reset();
                            filterContainerRef[0] = null;
                            listContainerRef[0] = null;
                            allFilterChipRef[0] = null;
                            siteFilterChips.clear();
                            resultsStage.removeAllViews();
                            if (session.isComplete()) {
                                renderZeroHitsEmpty(shell, resultsStage, session.keyword);
                            }
                            return;
                        }

                        Map<String, Integer> siteCounts = new LinkedHashMap<>();
                        Map<String, String> siteNames = new LinkedHashMap<>();
                        for (Hit h : snapshot) {
                            Integer prev = siteCounts.get(h.site.key);
                            siteCounts.put(h.site.key, (prev == null ? 0 : prev) + 1);
                            siteNames.put(h.site.key, h.site.name);
                        }
                        String curFilter = session.selectedSiteFilter();
                        if (!curFilter.isEmpty() && !siteCounts.containsKey(curFilter)) {
                            session.setSelectedSiteFilter("");
                            curFilter = "";
                        }

                        boolean useSidebar =
                                a.mobilePrefs().getBoolean(Prefs.SEARCH_PLATFORM_SIDEBAR, false);
                        IncrementalResultPlan.Diff diff =
                                renderPlan.planUpdate(
                                        session.querySeq,
                                        curFilter,
                                        useSidebar,
                                        session.exactMode,
                                        snapshot.size());
                        // In fuzzy mode, exact/cross-source consensus hits can promote above older
                        // rows when later batches arrive; rebuild in that case so ranking stays
                        // strictly exact-first. In exact mode every hit is exact, so incremental
                        // append preserves scroll position without jitter.
                        boolean allowIncremental = !diff.fullRebuild && session.exactMode;

                        if (allowIncremental && listContainerRef[0] != null) {
                            // Incremental path (#45): preserve ScrollView, scrollY, and existing
                            // cards; update filter counts in-place and append only newly arrived
                            // matching hits!
                            if (allFilterChipRef[0] != null) {
                                allFilterChipRef[0].setText("全部 (" + snapshot.size() + ")");
                            }
                            if (filterContainerRef[0] != null) {
                                for (Map.Entry<String, Integer> e : siteCounts.entrySet()) {
                                    final String sKey = e.getKey();
                                    String label =
                                            useSidebar
                                                    ? (siteNames.get(sKey)
                                                            + " ("
                                                            + e.getValue()
                                                            + ")")
                                                    : (siteNames.get(sKey) + " · " + e.getValue());
                                    TextView existingChip = siteFilterChips.get(sKey);
                                    if (existingChip != null) {
                                        existingChip.setText(label);
                                    } else {
                                        TextView added =
                                                addPlatformFilterItem(
                                                        a,
                                                        filterContainerRef[0],
                                                        label,
                                                        sKey.equals(curFilter),
                                                        useSidebar,
                                                        () -> {
                                                            session.setSelectedSiteFilter(
                                                                    toggleSiteFilter(
                                                                            session
                                                                                    .selectedSiteFilter(),
                                                                            sKey));
                                                            run();
                                                        });
                                        siteFilterChips.put(sKey, added);
                                    }
                                }
                            }
                            populateHitRowsRange(
                                    a,
                                    listContainerRef[0],
                                    snapshot,
                                    diff.appendFromIndex,
                                    curFilter);
                            return;
                        }

                        resultsStage.removeAllViews();
                        siteFilterChips.clear();
                        if (useSidebar) {
                            LinearLayout split = a.row();
                            resultsStage.addView(split, new FrameLayout.LayoutParams(-1, -1));

                            ScrollView leftSv = new ScrollView(a);
                            leftSv.setVerticalScrollBarEnabled(false);
                            LinearLayout leftCol = a.vertical();
                            leftCol.setPadding(0, a.dp(4), a.dp(8), bottomPad);
                            allFilterChipRef[0] =
                                    addPlatformFilterItem(
                                            a,
                                            leftCol,
                                            "全部 (" + snapshot.size() + ")",
                                            curFilter.isEmpty(),
                                            true,
                                            () -> {
                                                session.setSelectedSiteFilter("");
                                                run();
                                            });
                            for (Map.Entry<String, Integer> e : siteCounts.entrySet()) {
                                final String sKey = e.getKey();
                                TextView chip =
                                        addPlatformFilterItem(
                                                a,
                                                leftCol,
                                                siteNames.get(sKey) + " (" + e.getValue() + ")",
                                                sKey.equals(curFilter),
                                                true,
                                                () -> {
                                                    session.setSelectedSiteFilter(
                                                            toggleSiteFilter(
                                                                    session.selectedSiteFilter(),
                                                                    sKey));
                                                    run();
                                                });
                                siteFilterChips.put(sKey, chip);
                            }
                            leftSv.addView(leftCol);
                            split.addView(leftSv, new LinearLayout.LayoutParams(a.dp(106), -1));

                            ScrollView rightSv = new ScrollView(a);
                            rightSv.setVerticalScrollBarEnabled(false);
                            shell.bindScrollBehavior(rightSv);
                            LinearLayout rightCol = a.vertical();
                            rightCol.setPadding(a.dp(4), a.dp(4), 0, bottomPad);
                            populateHitRowsRange(a, rightCol, snapshot, 0, curFilter);
                            rightSv.addView(rightCol);
                            split.addView(rightSv, new LinearLayout.LayoutParams(0, -1, 1f));
                            filterContainerRef[0] = leftCol;
                            listContainerRef[0] = rightCol;
                        } else {
                            LinearLayout vBox = a.vertical();
                            resultsStage.addView(vBox, new FrameLayout.LayoutParams(-1, -1));

                            HorizontalScrollView topHsv = new HorizontalScrollView(a);
                            topHsv.setHorizontalScrollBarEnabled(false);
                            topHsv.setPadding(0, a.dp(2), 0, a.dp(8));
                            LinearLayout chipRow = a.row();
                            allFilterChipRef[0] =
                                    addPlatformFilterItem(
                                            a,
                                            chipRow,
                                            "全部 (" + snapshot.size() + ")",
                                            curFilter.isEmpty(),
                                            false,
                                            () -> {
                                                session.setSelectedSiteFilter("");
                                                run();
                                            });
                            for (Map.Entry<String, Integer> e : siteCounts.entrySet()) {
                                final String sKey = e.getKey();
                                TextView chip =
                                        addPlatformFilterItem(
                                                a,
                                                chipRow,
                                                siteNames.get(sKey) + " · " + e.getValue(),
                                                sKey.equals(curFilter),
                                                false,
                                                () -> {
                                                    session.setSelectedSiteFilter(
                                                            toggleSiteFilter(
                                                                    session.selectedSiteFilter(),
                                                                    sKey));
                                                    run();
                                                });
                                siteFilterChips.put(sKey, chip);
                            }
                            topHsv.addView(chipRow);
                            vBox.addView(topHsv, new LinearLayout.LayoutParams(-1, -2));

                            ScrollView listSv = new ScrollView(a);
                            listSv.setVerticalScrollBarEnabled(false);
                            shell.bindScrollBehavior(listSv);
                            LinearLayout listCol = a.vertical();
                            listCol.setPadding(0, a.dp(2), 0, bottomPad);
                            populateHitRowsRange(a, listCol, snapshot, 0, curFilter);
                            listSv.addView(listCol);
                            vBox.addView(listSv, new LinearLayout.LayoutParams(-1, 0, 1f));
                            filterContainerRef[0] = chipRow;
                            listContainerRef[0] = listCol;
                        }
                    }
                };

        final Runnable renderHistory =
                new Runnable() {
                    @Override
                    public void run() {
                        historySection.removeAllViews();
                        if (a.privateMode) return;
                        List<String> hist = readSearchHistory(a);
                        if (hist.isEmpty()) return;
                        LinearLayout hRow = a.row();
                        hRow.setGravity(Gravity.CENTER_VERTICAL);
                        TextView hTitle = a.text("最近搜索", 12.5f, p.textSecondary);
                        hTitle.setTypeface(null, Typeface.BOLD);
                        hRow.addView(hTitle, new LinearLayout.LayoutParams(0, -2, 1f));

                        TextView clear = a.text("清空", 12.5f, p.danger);
                        clear.setTypeface(null, Typeface.BOLD);
                        MobileMotion.bindPress(clear, 0.94f);
                        clear.setOnClickListener(
                                v ->
                                        MobileBottomSheet.showConfirm(
                                                a,
                                                "清空搜索历史？",
                                                "将移除全部 " + hist.size() + " 条最近搜索记录。",
                                                "清空历史",
                                                true,
                                                () -> {
                                                    if (!a.privateMode && a.prefs != null) {
                                                        a.prefs
                                                                .edit()
                                                                .remove(Prefs.GLOBAL_SEARCH_HISTORY)
                                                                .apply();
                                                    }
                                                    run();
                                                }));
                        hRow.addView(clear);
                        historySection.addView(hRow);

                        HorizontalScrollView hsv = new HorizontalScrollView(a);
                        hsv.setHorizontalScrollBarEnabled(false);
                        hsv.setPadding(0, a.dp(8), 0, 0);
                        LinearLayout pills = a.row();
                        for (final String kw : hist) {
                            TextView chip = a.text(kw, 12.5f, p.textPrimary);
                            chip.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
                            chip.setBackground(MobileTheme.subtleBg(a, 999));
                            MobileMotion.bindPress(chip, 0.94f);
                            chip.setOnClickListener(
                                    v -> {
                                        input.setText(kw);
                                        input.setSelection(kw.length());
                                        runSearch[0].run();
                                    });
                            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                            lp.rightMargin = a.dp(8);
                            pills.addView(chip, lp);
                        }
                        hsv.addView(pills);
                        historySection.addView(hsv);
                    }
                };

        runSearch[0] =
                () -> {
                    final String q = input.getText().toString().trim();
                    if (q.isEmpty()) {
                        MobileMotion.shakeInvalid(input);
                        a.toast("请输入搜索关键词");
                        return;
                    }
                    if (a.config == null || a.config.sites.isEmpty()) {
                        UiWidgets.showMobileImportDialog(a);
                        return;
                    }
                    hideSoftKeyboard(a, input);
                    saveSearchHistory(a, q);
                    renderHistory.run();

                    renderPlan.reset();
                    filterContainerRef[0] = null;
                    listContainerRef[0] = null;
                    allFilterChipRef[0] = null;
                    siteFilterChips.clear();
                    resultsStage.removeAllViews();

                    final List<Cms.Site> searchable = new ArrayList<>();
                    for (Cms.Site s : a.config.sites) {
                        if (a.available(s) && s.searchable) searchable.add(s);
                    }
                    if (searchable.isEmpty()) {
                        invalidateSession();
                        displayedSession[0] = null;
                        statusText.setText("当前配置中没有可搜索的片源");
                        renderZeroHitsEmpty(shell, resultsStage, q);
                        return;
                    }

                    final SearchSession session =
                            startSession(
                                    pageTokenHolder[0],
                                    q,
                                    a.privateMode,
                                    a.config,
                                    a.engineEpoch,
                                    a.generation,
                                    searchable.size(),
                                    exactMode[0]);
                    pageTokenHolder[0] = session.pageToken;
                    displayedSession[0] = session;
                    statusText.setText(session.status());

                    int threads = Math.max(2, Math.min(6, a.prefs.getInt(Prefs.SEARCH_THREADS, 6)));
                    final int timeoutSec =
                            Prefs.clampSearchTimeoutSeconds(
                                    a.prefs.getInt(Prefs.SEARCH_TIMEOUT, 20));
                    a.submitPage(
                            () -> {
                                if (session.cancelled) return;
                                ExecutorService pool = Executors.newFixedThreadPool(threads);
                                session.pool = pool;
                                if (session.cancelled) {
                                    pool.shutdownNow();
                                    return;
                                }
                                try {
                                    List<Future<?>> futures = new ArrayList<>();
                                    for (final Cms.Site site : searchable) {
                                        if (session.cancelled) break;
                                        futures.add(
                                                pool.submit(
                                                        () -> {
                                                            if (session.cancelled
                                                                    || Thread.currentThread()
                                                                            .isInterrupted()) {
                                                                return;
                                                            }
                                                            final List<Hit> localHits =
                                                                    new ArrayList<>();
                                                            try {
                                                                Cms.Listing res =
                                                                        Cms.listing(
                                                                                a.engine(site)
                                                                                        .search(
                                                                                                q,
                                                                                                1));
                                                                if (!session.cancelled
                                                                        && res.videos != null
                                                                        && !res.videos.isEmpty()) {
                                                                    for (Cms.Video v : res.videos) {
                                                                        localHits.add(
                                                                                new Hit(site, v));
                                                                    }
                                                                }
                                                            } catch (Throwable ignored) {
                                                            } finally {
                                                                if (!session.cancelled) {
                                                                    a.ui.post(
                                                                            () -> {
                                                                                if (a.isFinishing()
                                                                                        || a
                                                                                                .isDestroyed()
                                                                                        || a.switchingPrivacy) {
                                                                                    return;
                                                                                }
                                                                                if (!acceptBatchIfCurrent(
                                                                                        session,
                                                                                        a.privateMode,
                                                                                        a.config,
                                                                                        a.engineEpoch,
                                                                                        a.generation,
                                                                                        localHits)) {
                                                                                    return;
                                                                                }
                                                                                displayedSession[
                                                                                                0] =
                                                                                        session;
                                                                                statusText.setText(
                                                                                        session
                                                                                                .status());
                                                                                rebuildResults
                                                                                        .run();
                                                                            });
                                                                }
                                                            }
                                                        }));
                                    }
                                    for (Future<?> f : futures) {
                                        if (session.cancelled
                                                || Thread.currentThread().isInterrupted()) {
                                            break;
                                        }
                                        try {
                                            f.get(timeoutSec, TimeUnit.SECONDS);
                                        } catch (InterruptedException ie) {
                                            Thread.currentThread().interrupt();
                                            break;
                                        } catch (Exception ignored) {
                                        }
                                    }
                                } finally {
                                    pool.shutdownNow();
                                    if (session.pool == pool) {
                                        session.pool = null;
                                    }
                                }
                            });
                };

        View.OnClickListener switchMode =
                v -> {
                    boolean nextExact = v == exactPill;
                    if (exactMode[0] == nextExact) return;
                    exactMode[0] = nextExact;
                    a.mobilePrefs()
                            .edit()
                            .putBoolean(Prefs.MOBILE_SEARCH_EXACT_MODE, nextExact)
                            .apply();
                    updateModePills.run();
                    String curKeyword = input.getText().toString().trim();
                    if (!curKeyword.isEmpty()) {
                        // Cancel any in-flight query from the previous mode immediately so stale
                        // batches can never mix into the newly selected mode.
                        runSearch[0].run();
                    } else {
                        invalidateSession();
                        displayedSession[0] = null;
                        statusText.setText("");
                        rebuildResults.run();
                    }
                };
        fuzzyPill.setOnClickListener(switchMode);
        exactPill.setOnClickListener(switchMode);

        goBtn.setOnClickListener(v -> runSearch[0].run());
        input.setOnEditorActionListener(
                (v, actionId, event) -> {
                    if (actionId == EditorInfo.IME_ACTION_SEARCH
                            || (event != null
                                    && event.getKeyCode() == KeyEvent.KEYCODE_ENTER
                                    && event.getAction() == KeyEvent.ACTION_DOWN)) {
                        runSearch[0].run();
                        return true;
                    }
                    return false;
                });
        pasteChip.setOnClickListener(
                v -> {
                    ClipboardManager cm =
                            (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
                    if (cm != null && cm.hasPrimaryClip()) {
                        ClipData clip = cm.getPrimaryClip();
                        if (clip != null
                                && clip.getItemCount() > 0
                                && clip.getItemAt(0).getText() != null) {
                            String txt = clip.getItemAt(0).getText().toString().trim();
                            if (!txt.isEmpty()) {
                                input.setText(txt);
                                input.setSelection(txt.length());
                                runSearch[0].run();
                                return;
                            }
                        }
                    }
                    MobileMotion.shakeInvalid(pasteChip);
                    a.toast("剪贴板为空");
                });

        renderHistory.run();

        if (!MobileRootShell.pendingSearchKeyword.isEmpty()) {
            String kw = MobileRootShell.pendingSearchKeyword;
            MobileRootShell.pendingSearchKeyword = "";
            input.setText(kw);
            input.setSelection(kw.length());
            runSearch[0].run();
        } else {
            SearchSession cached = cachedSessionFor(a.privateMode, a.config, a.engineEpoch);
            if (cached != null && !cached.keyword.isEmpty() && cached.exactMode == exactMode[0]) {
                displayedSession[0] = cached;
                input.setText(cached.keyword);
                statusText.setText(cached.status());
                rebuildResults.run();
            } else {
                // Fresh empty Search tab: auto-focus input so user can start typing immediately
                input.post(
                        () -> {
                            if (!a.isFinishing() && UiCompat.isAttached(input)) {
                                input.requestFocus();
                                showSoftKeyboard(a, input);
                            }
                        });
            }
        }
    }

    private static void renderZeroHitsEmpty(
            MobileRootShell shell, FrameLayout stage, String keyword) {
        MainActivity a = shell.a;
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout box = a.vertical();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(a.dp(24), a.dp(48), a.dp(24), a.dp(48));

        FrameLayout badge = MobileIcons.badge(a, MobileIcons.IC_SEARCH, p.textSecondary, 50, 24);
        box.addView(badge, new LinearLayout.LayoutParams(a.dp(50), a.dp(50)));
        a.gap(box, 14);

        String titleStr =
                (keyword == null || keyword.isEmpty())
                        ? "暂未找到匹配影片"
                        : ("未找到与「" + keyword + "」相关的影片");
        TextView head = a.text(titleStr, 15.5f, p.textPrimary);
        head.setTypeface(null, Typeface.BOLD);
        head.setGravity(Gravity.CENTER);
        box.addView(head);
        a.gap(box, 6);

        TextView hint = a.text("可尝试缩短关键词，或切换其他片源后再试", 13f, p.textSecondary);
        hint.setGravity(Gravity.CENTER);
        box.addView(hint);
        a.gap(box, 18);

        TextView switchBtn = a.text("切换片源", 13.5f, p.accentOnFill);
        switchBtn.setTypeface(null, Typeface.BOLD);
        switchBtn.setGravity(Gravity.CENTER);
        switchBtn.setPadding(a.dp(22), a.dp(10), a.dp(22), a.dp(10));
        switchBtn.setBackground(MobileTheme.accentPillBg(a, 999));
        MobileMotion.bindPress(switchBtn, 0.94f);
        switchBtn.setOnClickListener(v -> shell.showQuickSourceAndModeSheet());
        box.addView(switchBtn, new LinearLayout.LayoutParams(-2, -2));

        stage.addView(box, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));
    }

    private static TextView addPlatformFilterItem(
            MainActivity a,
            LinearLayout parent,
            String text,
            boolean active,
            boolean verticalSidebar,
            Runnable onTap) {
        MobileTheme.Palette p = MobileTheme.of(a);
        TextView tv = a.text(text, 12.5f, active ? p.accent : p.textSecondary);
        tv.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
        tv.setSingleLine(!verticalSidebar);
        if (verticalSidebar) tv.setMaxLines(2);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        tv.setPadding(
                a.dp(12), a.dp(verticalSidebar ? 9 : 6), a.dp(12), a.dp(verticalSidebar ? 9 : 6));
        tv.setBackground(MobileTheme.pillBg(a, active, verticalSidebar ? 12 : 999));
        MobileMotion.bindPress(tv, 0.94f);
        tv.setOnClickListener(v -> onTap.run());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(verticalSidebar ? -1 : -2, -2);
        if (verticalSidebar) lp.bottomMargin = a.dp(7);
        else lp.rightMargin = a.dp(8);
        parent.addView(tv, lp);
        return tv;
    }

    private static void populateHitRowsRange(
            MainActivity a,
            LinearLayout parent,
            List<Hit> hits,
            int fromIndex,
            String selectedSiteFilter) {
        MobileTheme.Palette p = MobileTheme.of(a);
        boolean cleanTitle = a.mobilePrefs().getBoolean(Prefs.AI_CLEAN_SEARCH, false);
        boolean animateBatch = fromIndex > 0 && !MobileMotion.isReduced(a);
        int start = Math.max(0, fromIndex);
        for (int i = start; i < hits.size(); i++) {
            final Hit h = hits.get(i);
            if (selectedSiteFilter != null
                    && !selectedSiteFilter.isEmpty()
                    && !selectedSiteFilter.equals(h.site.key)) {
                continue;
            }
            LinearLayout card = a.row();
            card.setGravity(Gravity.CENTER_VERTICAL);
            card.setPadding(a.dp(11), a.dp(11), a.dp(12), a.dp(11));
            card.setBackground(MobileTheme.cardBg(a, 16));
            if (!p.isDark) UiCompat.setElevation(card, a.dp(1.5f));
            MobileMotion.bindPress(card, 0.97f);
            final ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(MobileTheme.subtleBg(a, 10));
            pic.setClipToOutline(true);
            if (h.video.poster != null && !h.video.poster.isEmpty()) {
                a.poster(h.video.poster, pic);
            }
            card.setOnClickListener(
                    v ->
                            MobilePosterTransition.openDetailFromCard(
                                    a, h.site, h.video, pic, 10f, false));
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(56), a.dp(78));
            pLp.rightMargin = a.dp(12);
            card.addView(pic, pLp);

            LinearLayout info = a.vertical();
            String displayTitle =
                    cleanTitle ? EpisodeNameCleaner.cleanSearchTitle(h.video.title) : h.video.title;
            TextView t = a.text(displayTitle, 14.5f, p.textPrimary);
            t.setTypeface(null, Typeface.BOLD);
            t.setMaxLines(2);
            t.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(t);

            LinearLayout metaRow = a.row();
            metaRow.setGravity(Gravity.CENTER_VERTICAL);
            metaRow.setPadding(0, a.dp(6), 0, 0);

            TextView siteTag = a.text(h.site.name, 11.5f, p.accent);
            siteTag.setTypeface(null, Typeface.BOLD);
            siteTag.setSingleLine(true);
            siteTag.setPadding(a.dp(7), a.dp(2), a.dp(7), a.dp(2));
            siteTag.setBackground(MobileTheme.pillBg(a, true, 6));
            metaRow.addView(siteTag);

            if (h.video.remarks != null && !h.video.remarks.trim().isEmpty()) {
                TextView rem = a.text(h.video.remarks.trim(), 12f, p.textSecondary);
                rem.setSingleLine(true);
                rem.setEllipsize(TextUtils.TruncateAt.END);
                LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(0, -2, 1f);
                rLp.leftMargin = a.dp(8);
                metaRow.addView(rem, rLp);
            }
            info.addView(metaRow, new LinearLayout.LayoutParams(-1, -2));

            card.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

            MobileIcons.IconView chev =
                    MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 14f, p.textTertiary);
            LinearLayout.LayoutParams chLp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
            chLp.leftMargin = a.dp(8);
            card.addView(chev, chLp);

            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(-1, -2);
            cLp.bottomMargin = a.dp(9);
            parent.addView(card, cLp);

            if (animateBatch) {
                card.setAlpha(0f);
                card.animate()
                        .alpha(1f)
                        .setDuration(MotionTokens.DURATION_FAST_MS)
                        .setInterpolator(MotionTokens.createDecelerateInterpolator())
                        .start();
            }
        }
    }

    static List<String> readSearchHistory(SharedPreferences prefs, boolean privateMode) {
        if (privateMode || prefs == null) {
            return Collections.emptyList();
        }
        List<String> list = new ArrayList<>();
        try {
            JSONArray arr = new JSONArray(prefs.getString(Prefs.GLOBAL_SEARCH_HISTORY, "[]"));
            for (int i = 0; i < Math.min(12, arr.length()); i++) {
                String s = arr.optString(i, "").trim();
                if (!s.isEmpty()) list.add(s);
            }
        } catch (Exception ignored) {
        }
        return list;
    }

    static void saveSearchHistory(SharedPreferences prefs, boolean privateMode, String kw) {
        if (privateMode || prefs == null || kw == null) {
            return;
        }
        String trimmed = kw.trim();
        if (trimmed.isEmpty()) return;
        try {
            List<String> cur = new ArrayList<>(readSearchHistory(prefs, false));
            cur.remove(trimmed);
            cur.add(0, trimmed);
            JSONArray arr = new JSONArray();
            for (int i = 0; i < Math.min(15, cur.size()); i++) arr.put(cur.get(i));
            prefs.edit().putString(Prefs.GLOBAL_SEARCH_HISTORY, arr.toString()).apply();
        } catch (Exception ignored) {
        }
    }

    private static List<String> readSearchHistory(MainActivity a) {
        if (a == null) return Collections.emptyList();
        return readSearchHistory(a.prefs, a.privateMode);
    }

    private static void saveSearchHistory(MainActivity a, String kw) {
        if (a == null) return;
        saveSearchHistory(a.prefs, a.privateMode, kw);
    }

    private static void showSoftKeyboard(MainActivity a, View v) {
        try {
            InputMethodManager imm =
                    (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.showSoftInput(v, InputMethodManager.SHOW_IMPLICIT);
        } catch (Exception ignored) {
        }
    }

    private static void hideSoftKeyboard(MainActivity a, View v) {
        try {
            InputMethodManager imm =
                    (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(v.getWindowToken(), 0);
        } catch (Exception ignored) {
        }
    }
}

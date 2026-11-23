package com.pilipala.marcomovie;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
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
 * Mobile multi-source concurrent Search Page:
 * - Native soft-keyboard search input + 1-tap clipboard paste + public-only search history chips
 * - Supports both horizontal top site filter bar and BieCuiLe-style left vertical platform sidebar
 *   ({@link Prefs#SEARCH_PLATFORM_SIDEBAR})
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
            this.querySeq = querySeq;
            this.pageToken = pageToken;
            this.keyword = keyword == null ? "" : keyword;
            this.privateMode = privateMode;
            this.config = config;
            this.engineEpoch = engineEpoch;
            this.generation = generation;
            this.totalSites = Math.max(0, totalSites);
            this.status = "正在并发检索 " + this.totalSites + " 个片源…";
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
                hits.addAll(batch);
            }
            doneCount = Math.min(totalSites, doneCount + 1);
            status = "已检索 " + doneCount + "/" + totalSites + " 个片源 · 命中 " + hits.size() + " 条结果";
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
        private int processedHitCount;
        int fullRebuildCount;
        int incrementalUpdateCount;

        void reset() {
            boundQuerySeq = -1L;
            boundFilter = "";
            processedHitCount = 0;
        }

        Diff planUpdate(long querySeq, String filter, boolean useSidebar, int totalHits) {
            String f = filter == null ? "" : filter;
            boolean needFull =
                    boundQuerySeq != querySeq
                            || !boundFilter.equals(f)
                            || boundSidebar != useSidebar
                            || totalHits < processedHitCount;
            if (needFull) {
                boundQuerySeq = querySeq;
                boundFilter = f;
                boundSidebar = useSidebar;
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
                            totalSites);
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

        // 1. Search Input Bar
        LinearLayout searchBar = a.row();
        searchBar.setGravity(Gravity.CENTER_VERTICAL);
        searchBar.setPadding(a.dp(14), a.dp(6), a.dp(8), a.dp(6));
        searchBar.setBackground(
                UiWidgets.glassBg(0xd81d2623, 0xd8131917, a.dp(999), a.dp(0.9f), 0x38ffffff));

        final EditText input = new EditText(a);
        input.setHint("搜索电影、剧集、动漫、演员…");
        input.setHintTextColor(0xff7c858e);
        input.setTextColor(Color.WHITE);
        input.setTextSize(14.5f);
        input.setSingleLine(true);
        input.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        input.setBackgroundColor(Color.TRANSPARENT);
        input.setPadding(a.dp(4), a.dp(6), a.dp(8), a.dp(6));
        searchBar.addView(input, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView pasteChip = a.text("粘贴", 12f, 0xffd1d5db);
        pasteChip.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
        pasteChip.setBackground(a.bg(0x22ffffff, 999));
        UiWidgets.bindTouchFeedback(pasteChip);
        LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(-2, -2);
        pLp.rightMargin = a.dp(6);
        searchBar.addView(pasteChip, pLp);

        int accent = a.mobileAccentColor();
        TextView goBtn = a.text("搜索", 13f, 0xff08120e);
        goBtn.setTypeface(null, Typeface.BOLD);
        goBtn.setPadding(a.dp(15), a.dp(7), a.dp(15), a.dp(7));
        goBtn.setBackground(a.bg(accent, 999));
        UiWidgets.bindTouchFeedback(goBtn);
        searchBar.addView(goBtn, new LinearLayout.LayoutParams(-2, -2));

        page.addView(searchBar, new LinearLayout.LayoutParams(-1, -2));

        // 2. History chips + status row
        final LinearLayout historySection = a.vertical();
        historySection.setPadding(0, a.dp(10), 0, a.dp(4));
        page.addView(historySection, new LinearLayout.LayoutParams(-1, -2));

        final TextView statusText = a.text("", 12.5f, MainActivity.MUTED);
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
                        List<Hit> snapshot = session.snapshotHits();
                        if (snapshot.isEmpty()) {
                            renderPlan.reset();
                            filterContainerRef[0] = null;
                            listContainerRef[0] = null;
                            allFilterChipRef[0] = null;
                            siteFilterChips.clear();
                            resultsStage.removeAllViews();
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
                                        session.querySeq, curFilter, useSidebar, snapshot.size());

                        if (!diff.fullRebuild && listContainerRef[0] != null) {
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
                                                            session.setSelectedSiteFilter(sKey);
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
                            leftCol.setPadding(0, a.dp(4), a.dp(8), a.dp(104));
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
                                                    session.setSelectedSiteFilter(sKey);
                                                    run();
                                                });
                                siteFilterChips.put(sKey, chip);
                            }
                            leftSv.addView(leftCol);
                            split.addView(leftSv, new LinearLayout.LayoutParams(a.dp(104), -1));

                            ScrollView rightSv = new ScrollView(a);
                            rightSv.setVerticalScrollBarEnabled(false);
                            shell.bindScrollBehavior(rightSv);
                            LinearLayout rightCol = a.vertical();
                            rightCol.setPadding(a.dp(4), a.dp(4), 0, a.dp(106));
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
                                                    session.setSelectedSiteFilter(sKey);
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
                            listCol.setPadding(0, a.dp(2), 0, a.dp(106));
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
                        hRow.addView(
                                a.text("最近搜索", 12f, MainActivity.MUTED),
                                new LinearLayout.LayoutParams(0, -2, 1f));
                        TextView clear = a.text("清空", 12f, 0xffef4444);
                        UiWidgets.bindTouchFeedback(clear);
                        clear.setOnClickListener(
                                v -> {
                                    if (!a.privateMode && a.prefs != null) {
                                        a.prefs.edit().remove(Prefs.GLOBAL_SEARCH_HISTORY).apply();
                                    }
                                    run();
                                });
                        hRow.addView(clear);
                        historySection.addView(hRow);

                        HorizontalScrollView hsv = new HorizontalScrollView(a);
                        hsv.setHorizontalScrollBarEnabled(false);
                        hsv.setPadding(0, a.dp(6), 0, 0);
                        LinearLayout pills = a.row();
                        for (final String kw : hist) {
                            TextView p = a.text(kw, 12f, 0xffe5e7eb);
                            p.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
                            p.setBackground(a.bg(0xff1c2421, 999));
                            UiWidgets.bindTouchFeedback(p);
                            p.setOnClickListener(
                                    v -> {
                                        input.setText(kw);
                                        input.setSelection(kw.length());
                                        runSearch[0].run();
                                    });
                            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                            lp.rightMargin = a.dp(8);
                            pills.addView(p, lp);
                        }
                        hsv.addView(pills);
                        historySection.addView(hsv);
                    }
                };

        runSearch[0] =
                () -> {
                    final String q = input.getText().toString().trim();
                    if (q.isEmpty()) {
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
                                    searchable.size());
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
            if (cached != null && !cached.keyword.isEmpty()) {
                displayedSession[0] = cached;
                input.setText(cached.keyword);
                statusText.setText(cached.status());
                rebuildResults.run();
            }
        }
    }

    private static TextView addPlatformFilterItem(
            MainActivity a,
            LinearLayout parent,
            String text,
            boolean active,
            boolean verticalSidebar,
            Runnable onTap) {
        int accent = a.mobileAccentColor();
        TextView tv = a.text(text, 12f, active ? 0xff08120e : 0xffe5e7eb);
        tv.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
        tv.setSingleLine(!verticalSidebar);
        if (verticalSidebar) tv.setMaxLines(2);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        tv.setPadding(
                a.dp(11), a.dp(verticalSidebar ? 9 : 6), a.dp(11), a.dp(verticalSidebar ? 9 : 6));
        tv.setBackground(
                active
                        ? a.bg(accent, verticalSidebar ? 12 : 999)
                        : UiWidgets.glassBg(
                                0xb81c2421,
                                0xb8141a18,
                                a.dp(verticalSidebar ? 12 : 999),
                                a.dp(0.7f),
                                0x24ffffff));
        UiWidgets.bindTouchFeedback(tv);
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
        boolean cleanTitle = a.mobilePrefs().getBoolean(Prefs.AI_CLEAN_SEARCH, false);
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
            card.setPadding(a.dp(10), a.dp(10), a.dp(12), a.dp(10));
            card.setBackground(
                    UiWidgets.glassBg(0xc01b2320, 0xc0131917, a.dp(16), a.dp(0.7f), 0x26ffffff));
            UiWidgets.bindTouchFeedback(card);
            card.setOnClickListener(v -> MobileHomePage.openVideoOrFolder(a, h.site, h.video));

            ImageView pic = new ImageView(a);
            pic.setScaleType(ImageView.ScaleType.CENTER_CROP);
            pic.setBackground(a.bg(0xff232b28, 10));
            pic.setClipToOutline(true);
            if (h.video.poster != null && !h.video.poster.isEmpty()) {
                a.poster(h.video.poster, pic);
            }
            LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(a.dp(56), a.dp(78));
            pLp.rightMargin = a.dp(12);
            card.addView(pic, pLp);

            LinearLayout info = a.vertical();
            String displayTitle =
                    cleanTitle ? EpisodeNameCleaner.cleanSearchTitle(h.video.title) : h.video.title;
            TextView t = a.text(displayTitle, 14.5f, Color.WHITE);
            t.setTypeface(null, Typeface.BOLD);
            t.setMaxLines(2);
            t.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(t);

            String meta =
                    h.site.name
                            + (h.video.remarks != null && !h.video.remarks.isEmpty()
                                    ? ("  ·  " + h.video.remarks)
                                    : "");
            TextView sub = a.text(meta, 12f, a.mobileAccentColor());
            sub.setPadding(0, a.dp(5), 0, 0);
            info.addView(sub);

            card.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));
            LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(-1, -2);
            cLp.bottomMargin = a.dp(9);
            parent.addView(card, cLp);
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

    private static void hideSoftKeyboard(MainActivity a, View v) {
        try {
            InputMethodManager imm =
                    (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(v.getWindowToken(), 0);
        } catch (Exception ignored) {
        }
    }
}

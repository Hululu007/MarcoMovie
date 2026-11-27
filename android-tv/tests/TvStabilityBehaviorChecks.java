package com.pilipala.marcomovie;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.cert.CertPathValidatorException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.Deque;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import javax.net.ssl.SSLHandshakeException;

/**
 * Pure-JVM behavioral verification suite for Android TV search stability (#75/#74), playback crash
 * & MPV async teardown safety, and video first-frame / black-screen recovery.
 */
public final class TvStabilityBehaviorChecks {
    private static int passed = 0;
    private static int failed = 0;

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("PASS: " + name);
        } else {
            failed++;
            System.out.println("FAIL: " + name);
        }
    }

    private static String readSrc(String relPath) throws Exception {
        return new String(Files.readAllBytes(Paths.get(relPath)), StandardCharsets.UTF_8);
    }

    private static Cms.Site site(String key, int type) {
        Cms.Site s = new Cms.Site();
        s.key = key;
        s.name = "Source " + key;
        s.type = type;
        s.api = type == 1 ? "https://fixture.example/" + key : "csp_" + key;
        s.searchable = true;
        return s;
    }

    private static List<Cms.Video> videos(String prefix, int count) {
        List<Cms.Video> out = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            Cms.Video v = new Cms.Video();
            v.id = prefix + "_" + i;
            v.title = "Item " + prefix + " " + i;
            out.add(v);
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        testSearchOutOfOrderLateResponseRejected();
        testSearchFirstFailThenSecondSearchAndBudget();
        testUnifiedSearchBudgetAndObjectGraph();
        testSearchBatchHandoffAndCardClosureReachability();
        testSearchPaginationTrimRewindAndPinyinScanCursor();
        testWatchHistoryDefaultFocusAfterGenericRestore();
        testHttp404TerminalErrorOverlayAndRemoteActions();
        testTvDetailHostHistoryFallbackBookmarkOwnership();
        testWatchHistoryScopedMigrationSafety();
        testWatchHistoryFullCapacityMigration60Entries();
        testWatchHistoryMigrationTimingBackgroundHomeAndProgressGate();
        testWatchHistoryMigrationSeekResetProgressGate();
        testPosterUnbindAndPrivateDoubanGuards();
        testDoubanCrossPageWaiterValidation();
        testMpvBlockedDestroyNoMainThreadBlockAndNoZombie();
        testVideoOutputStateMachineAndBoundedRecovery();
        testMpvBackgroundSurfaceRecreationAndWatchdog();
        testOverlayBufferingAndTerminalStalledClockBridge();
        testTlsClassificationAndDiagnostics();
        testSourceWiringContracts();

        System.out.println(
                "TvStabilityBehaviorChecks summary: " + passed + " passed, " + failed + " failed");
        if (failed > 0) {
            System.exit(1);
        }
    }

    /**
     * Proves with deterministic CountDownLatch ordering: old search request starts first, blocks
     * until new search finishes, and arrives LAST — new search results stay 100% clean.
     */
    private static void testSearchOutOfOrderLateResponseRejected() throws Exception {
        final CountDownLatch oldEntered = new CountDownLatch(1);
        final CountDownLatch releaseOld = new CountDownLatch(1);
        final CountDownLatch newDone = new CountDownLatch(1);
        final AtomicInteger activeSerial = new AtomicInteger(1);
        final Map<String, List<Cms.Video>> screenResults = new ConcurrentHashMap<>();
        final AtomicInteger staleDrops = new AtomicInteger(0);

        Cms.Site s = site("ooo_http", 1);
        final int serial1 = activeSerial.get();
        SearchCoordinator oldSearch =
                new SearchCoordinator(
                        (st, q) -> {
                            oldEntered.countDown();
                            // Ignore interruption so the old request is guaranteed to finish LAST.
                            while (releaseOld.getCount() > 0) {
                                try {
                                    releaseOld.await(20, TimeUnit.MILLISECONDS);
                                } catch (InterruptedException ignored) {
                                }
                            }
                            return videos("old_stale", 5);
                        },
                        (st, vids, out) -> {
                            if (serial1 != activeSerial.get()) {
                                staleDrops.incrementAndGet();
                                return;
                            }
                            screenResults.put(st.key, vids);
                        },
                        3000,
                        5000);
        oldSearch.start(Collections.singletonList(s), "old-query");
        check("old search entered worker", oldEntered.await(2, TimeUnit.SECONDS));

        // User submits a second search on the same page before the first returns
        final int serial2 = activeSerial.incrementAndGet();
        oldSearch.close();
        screenResults.clear();

        SearchCoordinator newSearch =
                new SearchCoordinator(
                        (st, q) -> videos("new_fresh", 4),
                        (st, vids, out) -> {
                            if (serial2 == activeSerial.get()) {
                                screenResults.put(st.key, vids);
                            }
                            newDone.countDown();
                        },
                        3000,
                        5000);
        newSearch.start(Collections.singletonList(s), "new-query");
        check("new search finished first", newDone.await(2, TimeUnit.SECONDS));

        // Now force the old request to complete AFTER the new search already populated results
        releaseOld.countDown();
        Thread.sleep(150);
        newSearch.close();

        List<Cms.Video> finalItems = screenResults.get(s.key);
        boolean allFresh = finalItems != null && finalItems.size() == 4;
        if (allFresh) {
            for (Cms.Video v : finalItems) {
                if (!v.id.startsWith("new_fresh")) {
                    allFresh = false;
                    break;
                }
            }
        }
        check(
                "old request arriving last never overwrites newer search results",
                allFresh && staleDrops.get() == 0);
    }

    /**
     * Reproduces #75 primary flow: first search fails/times out on recoverable source, second
     * search on the same page succeeds cleanly; also validates TvSearchBudget fair floor & caps.
     */
    private static void testSearchFirstFailThenSecondSearchAndBudget() throws Exception {
        final AtomicBoolean firstRoundFail = new AtomicBoolean(true);
        final CountDownLatch round1Done = new CountDownLatch(3);
        final Map<String, SearchCoordinator.Outcome> r1Outcomes = new ConcurrentHashMap<>();

        Cms.Site normal = site("r_norm", 1);
        Cms.Site recover = site("r_recover", 1);
        Cms.Site slowFail = site("r_slow", 1);
        List<Cms.Site> sources = Arrays.asList(normal, recover, slowFail);

        SearchCoordinator.Runner runner =
                (s, q) -> {
                    if ("r_slow".equals(s.key)) {
                        Thread.sleep(600);
                        return videos("slow", 2);
                    }
                    if ("r_recover".equals(s.key) && firstRoundFail.get()) {
                        throw new IOException("simulated first search failure");
                    }
                    return videos(s.key + "_" + q, 10);
                };

        try (SearchCoordinator c1 =
                new SearchCoordinator(
                        runner,
                        (s, v, o) -> {
                            r1Outcomes.put(s.key, o);
                            round1Done.countDown();
                        },
                        120,
                        2000)) {
            c1.start(sources, "first");
            check(
                    "round 1 completes with mixed RESULT/FAILED/TIMEOUT",
                    round1Done.await(2, TimeUnit.SECONDS)
                            && r1Outcomes.get("r_norm") == SearchCoordinator.Outcome.RESULT
                            && r1Outcomes.get("r_recover") == SearchCoordinator.Outcome.FAILED
                            && r1Outcomes.get("r_slow") == SearchCoordinator.Outcome.TIMEOUT);
        }

        // Round 2 on same page after first search failure/timeout: recoverable source now returns!
        firstRoundFail.set(false);
        final CountDownLatch round2Done = new CountDownLatch(3);
        final Map<String, SearchCoordinator.Outcome> r2Outcomes = new ConcurrentHashMap<>();
        try (SearchCoordinator c2 =
                new SearchCoordinator(
                        runner,
                        (s, v, o) -> {
                            r2Outcomes.put(s.key, o);
                            round2Done.countDown();
                        },
                        120,
                        2000)) {
            c2.start(sources, "second");
            check(
                    "round 2 recovers cleanly on same page without starvation",
                    round2Done.await(2, TimeUnit.SECONDS)
                            && r2Outcomes.get("r_norm") == SearchCoordinator.Outcome.RESULT
                            && r2Outcomes.get("r_recover") == SearchCoordinator.Outcome.RESULT);
        }

        check(
                "TvSearchPages.MAX_RESULTS remains 5000 for single-source pagination",
                TvSearchPages.MAX_RESULTS == 5000);
    }

    /** Counts distinct Cms.Video instances strongly reachable from SourceResult + TvSearchPages. */
    private static int countDistinctReachableVideos(
            Map<String, GlobalSearchScreen.SourceResult> results) {
        IdentityHashMap<Cms.Video, Boolean> reachable = new IdentityHashMap<>();
        for (GlobalSearchScreen.SourceResult sr : results.values()) {
            if (sr == null) continue;
            if (sr.videos != null) {
                for (Cms.Video v : sr.videos) {
                    if (v != null) reachable.put(v, Boolean.TRUE);
                }
            }
            if (sr.pages != null && sr.pages.videos != null) {
                for (Cms.Video v : sr.pages.videos) {
                    if (v != null) reachable.put(v, Boolean.TRUE);
                }
            }
        }
        return reachable.size();
    }

    private static Cms.Listing listing(
            int page, int pageCount, String prefix, int count, int startOffset) {
        Cms.Listing l = new Cms.Listing();
        l.page = page;
        l.pageCount = pageCount;
        for (int i = 0; i < count; i++) {
            Cms.Video v = new Cms.Video();
            v.id = prefix + "_" + (startOffset + i);
            v.title = "Title " + prefix + " " + (startOffset + i);
            l.videos.add(v);
        }
        return l;
    }

    /**
     * Walks the Java object graph by object identity (Maps, Collections, Arrays, and declared
     * fields of app classes + lambda closures) to count every distinct strongly-reachable {@link
     * Cms.Video} instance.
     */
    private static int countReachableCmsVideos(Object root) {
        IdentityHashMap<Object, Boolean> visited = new IdentityHashMap<>();
        IdentityHashMap<Cms.Video, Boolean> videosFound = new IdentityHashMap<>();
        ArrayDeque<Object> stack = new ArrayDeque<>();
        if (root != null) stack.push(root);
        while (!stack.isEmpty()) {
            Object cur = stack.pop();
            if (cur == null || visited.put(cur, Boolean.TRUE) != null) continue;
            if (cur instanceof Cms.Video) {
                videosFound.put((Cms.Video) cur, Boolean.TRUE);
                continue;
            }
            if (cur instanceof String
                    || cur instanceof Number
                    || cur instanceof Boolean
                    || cur instanceof Character
                    || cur instanceof Enum<?>
                    || cur instanceof Class<?>) {
                continue;
            }
            if (cur instanceof Map<?, ?>) {
                for (Map.Entry<?, ?> entry : ((Map<?, ?>) cur).entrySet()) {
                    if (entry.getKey() != null) stack.push(entry.getKey());
                    if (entry.getValue() != null) stack.push(entry.getValue());
                }
                continue;
            }
            if (cur instanceof Collection<?>) {
                for (Object item : (Collection<?>) cur) {
                    if (item != null) stack.push(item);
                }
                continue;
            }
            Class<?> cls = cur.getClass();
            if (cls.isArray()) {
                if (!cls.getComponentType().isPrimitive()) {
                    Object[] arr = (Object[]) cur;
                    for (Object item : arr) {
                        if (item != null) stack.push(item);
                    }
                }
                continue;
            }
            String name = cls.getName();
            if (!name.startsWith("com.pilipala.marcomovie.")) continue;
            for (Class<?> c = cls; c != null && c != Object.class; c = c.getSuperclass()) {
                for (java.lang.reflect.Field f : c.getDeclaredFields()) {
                    if (java.lang.reflect.Modifier.isStatic(f.getModifiers())) continue;
                    if (f.getType().isPrimitive()) continue;
                    try {
                        f.setAccessible(true);
                        Object val = f.get(cur);
                        if (val != null) stack.push(val);
                    } catch (Throwable ignored) {
                    }
                }
            }
        }
        return videosFound.size();
    }

    private static Cms.Listing listingPage(String prefix, int page, int pageCount, int count) {
        Cms.Listing l = new Cms.Listing();
        l.page = page;
        l.pageCount = pageCount;
        int base = (page - 1) * count;
        for (int i = 0; i < count; i++) {
            Cms.Video v = new Cms.Video();
            v.id = prefix + "_" + (base + i);
            v.title = "Title " + prefix + " " + (base + i);
            l.videos.add(v);
        }
        return l;
    }

    /**
     * Round-2 P1 verification: exact 3-case matrix under low-RAM TV budget (globalCap=900,
     * stepCap=60), verifying BOTH screen-accessible results AND strongly-referenced Cms.Video
     * object count across initial search, single-source retry, and pagination.
     */
    private static void testUnifiedSearchBudgetAndObjectGraph() throws Exception {
        final int globalCap = TvSearchBudget.globalCap(true, true);
        final int stepCap = TvSearchBudget.pageStepCap(true, true);
        check(
                "Low-RAM TV budget constants are 900 global / 60 step",
                globalCap == 900 && stepCap == 60);

        // Case 1: 1 source, 1 page, 80 videos
        Cms.Site single1 = site("case1", 1);
        TvSearchPages.Fetch fetch1 = (term, p) -> listingPage("c1", p, 1, 80);
        int initCap1 = TvSearchBudget.initialPerSourceCap(1, true, true);
        TvSearchPages p1 =
                TvSearchPages.first(
                        "q", Collections.singletonList("q"), t -> true, fetch1, initCap1);
        Map<String, GlobalSearchScreen.SourceResult> map1 = new LinkedHashMap<>();
        map1.put(
                single1.key,
                new GlobalSearchScreen.SourceResult(
                        single1, p1.videos, SearchCoordinator.Outcome.RESULT, p1));
        check(
                "Case 1 initial: 1 source x 1 page x 80 retains 60 on screen & 60 in object graph"
                        + " with hasMore=true",
                p1.videos.size() == 60
                        && countDistinctReachableVideos(map1) == 60
                        && p1.hasMore()
                        && !p1.limited);
        TvSearchPages p1Next = p1.next(t -> true, fetch1, stepCap, globalCap);
        map1.put(
                single1.key,
                new GlobalSearchScreen.SourceResult(
                        single1, p1Next.videos, SearchCoordinator.Outcome.RESULT, p1Next));
        Set<String> ids1 = new HashSet<>();
        for (Cms.Video v : p1Next.videos) ids1.add(v.id);
        check(
                "Case 1 remainder page: reaches all 80 unique items, object graph holds 80,"
                        + " hasMore=false",
                p1Next.videos.size() == 80
                        && ids1.size() == 80
                        && countDistinctReachableVideos(map1) == 80
                        && !p1Next.hasMore());

        // Case 2: 1 source, 2 pages, 80 videos per page (160 total)
        Cms.Site single2 = site("case2", 1);
        TvSearchPages.Fetch fetch2 = (term, p) -> listingPage("c2", p, 2, 80);
        TvSearchPages p2 =
                TvSearchPages.first(
                        "q", Collections.singletonList("q"), t -> true, fetch2, initCap1);
        Map<String, GlobalSearchScreen.SourceResult> map2 = new LinkedHashMap<>();
        map2.put(
                single2.key,
                new GlobalSearchScreen.SourceResult(
                        single2, p2.videos, SearchCoordinator.Outcome.RESULT, p2));
        check(
                "Case 2 initial: 1 source x 2 pages x 80 retains 60 & 60 strong refs",
                p2.videos.size() == 60 && countDistinctReachableVideos(map2) == 60 && p2.hasMore());
        TvSearchPages p2s1 = p2.next(t -> true, fetch2, stepCap, globalCap);
        TvSearchPages p2s2 = p2s1.next(t -> true, fetch2, stepCap, globalCap);
        TvSearchPages p2s3 = p2s2.next(t -> true, fetch2, stepCap, globalCap);
        map2.put(
                single2.key,
                new GlobalSearchScreen.SourceResult(
                        single2, p2s3.videos, SearchCoordinator.Outcome.RESULT, p2s3));
        Set<String> ids2 = new HashSet<>();
        for (Cms.Video v : p2s3.videos) ids2.add(v.id);
        check(
                "Case 2 bounded pagination: 60 -> 80 -> 140 -> 160 (every step <= 60, all 160"
                        + " reachable)",
                p2s1.videos.size() == 80
                        && p2s1.hasMore()
                        && p2s2.videos.size() == 140
                        && p2s2.hasMore()
                        && p2s3.videos.size() == 160
                        && ids2.size() == 160
                        && !p2s3.hasMore()
                        && countDistinctReachableVideos(map2) == 160);

        // Case 3: 100 sources x 80 videos/source (8,000 raw items)
        int initCap100 = TvSearchBudget.initialPerSourceCap(100, true, true);
        Map<String, GlobalSearchScreen.SourceResult> map100 = new LinkedHashMap<>();
        int emptyInitialSources = 0;
        int totalVisible100 = 0;
        for (int i = 0; i < 100; i++) {
            final int idx = i;
            Cms.Site s = site("src_" + idx, 1);
            TvSearchPages.Fetch fetchI = (term, p) -> listingPage("s" + idx, p, 1, 80);
            TvSearchPages pagesI =
                    TvSearchPages.first(
                            "q", Collections.singletonList("q"), t -> true, fetchI, initCap100);
            map100.put(
                    s.key,
                    new GlobalSearchScreen.SourceResult(
                            s, pagesI.videos, SearchCoordinator.Outcome.RESULT, pagesI));
            TvSearchBudget.enforceGlobalResultsCap(map100, "", globalCap);
        }
        for (GlobalSearchScreen.SourceResult sr : map100.values()) {
            totalVisible100 += sr.videos.size();
            if (sr.videos.isEmpty()) emptyInitialSources++;
        }
        check(
                "Case 3 initial: 100 sources x 80 shows 900 total, 0 empty sources, and holds"
                        + " exactly 900 Cms.Video refs (not 8,000)",
                initCap100 == 9
                        && totalVisible100 == 900
                        && emptyInitialSources == 0
                        && countDistinctReachableVideos(map100) == 900);

        // Drill into source #73 and page through all 80 hits while obeying globalCap <= 900
        String targetKey = "src_73";
        TvSearchPages.Fetch fetch73 = (term, p) -> listingPage("s73", p, 1, 80);
        GlobalSearchScreen.SourceResult sr73 = map100.get(targetKey);
        TvSearchPages next73a = sr73.pages.next(t -> true, fetch73, stepCap, globalCap);
        map100.put(
                targetKey,
                new GlobalSearchScreen.SourceResult(
                        sr73.site, next73a.videos, SearchCoordinator.Outcome.RESULT, next73a));
        TvSearchBudget.enforceGlobalResultsCap(map100, targetKey, globalCap);
        int refsAfter73a = countDistinctReachableVideos(map100);

        TvSearchPages next73b = next73a.next(t -> true, fetch73, stepCap, globalCap);
        map100.put(
                targetKey,
                new GlobalSearchScreen.SourceResult(
                        sr73.site, next73b.videos, SearchCoordinator.Outcome.RESULT, next73b));
        TvSearchBudget.enforceGlobalResultsCap(map100, targetKey, globalCap);
        int refsAfter73b = countDistinctReachableVideos(map100);
        check(
                "Case 3 drill-down src_73 reaches all 80 hits while global strong refs stay <= 900",
                next73a.videos.size() == 69
                        && refsAfter73a <= globalCap
                        && next73b.videos.size() == 80
                        && !next73b.hasMore()
                        && refsAfter73b <= globalCap);

        // Tail source src_99 was evicted to 0 videos yet keeps cursor -> reload all 80 on demand
        GlobalSearchScreen.SourceResult evicted99 = map100.get("src_99");
        check(
                "Case 3 inactive source src_99 evicted to 0 videos with reloadable cursor",
                evicted99 != null
                        && evicted99.videos.isEmpty()
                        && evicted99.pages != null
                        && evicted99.pages.evicted
                        && evicted99.pages.hasMore());
        TvSearchPages.Fetch fetch99 = (term, p) -> listingPage("s99", p, 1, 80);
        TvSearchPages rec99a = evicted99.pages.next(t -> true, fetch99, stepCap, globalCap);
        map100.put(
                "src_99",
                new GlobalSearchScreen.SourceResult(
                        evicted99.site, rec99a.videos, SearchCoordinator.Outcome.RESULT, rec99a));
        TvSearchBudget.enforceGlobalResultsCap(map100, "src_99", globalCap);
        TvSearchPages rec99b = rec99a.next(t -> true, fetch99, stepCap, globalCap);
        map100.put(
                "src_99",
                new GlobalSearchScreen.SourceResult(
                        evicted99.site, rec99b.videos, SearchCoordinator.Outcome.RESULT, rec99b));
        TvSearchBudget.enforceGlobalResultsCap(map100, "src_99", globalCap);
        check(
                "Case 3 previously evicted src_99 reloads all 80 hits on demand while global refs"
                        + " stay <= 900",
                rec99a.videos.size() == 60
                        && rec99b.videos.size() == 80
                        && !rec99b.hasMore()
                        && countDistinctReachableVideos(map100) <= globalCap);

        // Single-source retry obeys the exact same stepCap & globalCap
        TvSearchPages.Fetch fetchRetry = (term, p) -> listingPage("s50_retry", p, 1, 80);
        TvSearchPages retry50 =
                TvSearchPages.first(
                        "q", Collections.singletonList("q"), t -> true, fetchRetry, stepCap);
        map100.put(
                "src_50",
                new GlobalSearchScreen.SourceResult(
                        map100.get("src_50").site,
                        retry50.videos,
                        SearchCoordinator.Outcome.RESULT,
                        retry50));
        TvSearchBudget.enforceGlobalResultsCap(map100, "src_50", globalCap);
        check(
                "Single-source retry obeys stepCap=60 and globalCap=900 with hasMore=true",
                retry50.videos.size() == 60
                        && retry50.hasMore()
                        && countDistinctReachableVideos(map100) <= globalCap);
    }

    private static void testDoubanCrossPageWaiterValidation() {
        int scopePageA = ImageLoader.newScope();
        int scopePageB = ImageLoader.newScope();
        String key = "santi#2023";

        // Page A (gen=1) started lookup, then user navigated to Page B (gen=2) showing same title
        ImageLoader.cancelScope(null, scopePageA);
        int currentGen = 2;

        boolean deliverPageA =
                DoubanScoreRepository.shouldDeliverToWaiter(
                        false,
                        false,
                        currentGen,
                        1,
                        101,
                        scopePageA,
                        ImageLoader.isScopeCancelled(scopePageA),
                        false,
                        key,
                        key,
                        Integer.valueOf(101));
        boolean deliverPageB =
                DoubanScoreRepository.shouldDeliverToWaiter(
                        false,
                        false,
                        currentGen,
                        2,
                        202,
                        scopePageB,
                        ImageLoader.isScopeCancelled(scopePageB),
                        true,
                        key,
                        key,
                        Integer.valueOf(202));
        boolean deliverRecycledBind =
                DoubanScoreRepository.shouldDeliverToWaiter(
                        false,
                        false,
                        currentGen,
                        2,
                        202,
                        scopePageB,
                        ImageLoader.isScopeCancelled(scopePageB),
                        true,
                        key,
                        key,
                        Integer.valueOf(203));
        boolean deliverPrivate =
                DoubanScoreRepository.shouldDeliverToWaiter(
                        false,
                        true,
                        currentGen,
                        2,
                        202,
                        scopePageB,
                        false,
                        true,
                        key,
                        key,
                        Integer.valueOf(202));
        check(
                "Douban single-flight drops departed Page A waiter while delivering to valid Page B"
                        + " same-title card",
                !deliverPageA && deliverPageB && !deliverRecycledBind && !deliverPrivate);
    }

    private static void testPosterUnbindAndPrivateDoubanGuards() throws Exception {
        int s1 = ImageLoader.newScope();
        int s2 = ImageLoader.newScope();
        check(
                "ImageLoader scopes are distinct and active initially",
                s1 != s2 && !ImageLoader.isScopeCancelled(s1));
        ImageLoader.cancelScope(null, s1);
        check(
                "ImageLoader.cancelScope marks only cancelled scope without affecting next scope",
                ImageLoader.isScopeCancelled(s1) && !ImageLoader.isScopeCancelled(s2));

        check(
                "DoubanScoreRepository blocks remote lookup in private mode and allows normal mode",
                !DoubanScoreRepository.shouldAllowRemoteLookup(true)
                        && DoubanScoreRepository.shouldAllowRemoteLookup(false));
    }

    /**
     * Artificially blocks old MPV native destroy behind a CountDownLatch and verifies: (1)
     * Main-thread immediate check fails fast (never blocks Back button), (2) Background wait
     * respects wait budget and throws MpvBusyTimeoutException for single fallback, (3) Cancelled
     * wait exits promptly when Back is pressed, (4) Releasing the old destroy later does NOT
     * resurrect any zombie MPV instance.
     */
    private static void testMpvBlockedDestroyNoMainThreadBlockAndNoZombie() throws Exception {
        final Object nativeLock = new Object();
        final MpvPlayer.NativeLifecycleCoordinator coord =
                new MpvPlayer.NativeLifecycleCoordinator(nativeLock);
        final ExecutorService destroyPool = Executors.newSingleThreadExecutor();
        final ExecutorService bgPool = Executors.newCachedThreadPool();
        final CountDownLatch destroyEntered = new CountDownLatch(1);
        final CountDownLatch releaseDestroy = new CountDownLatch(1);
        final AtomicInteger createCount = new AtomicInteger(0);
        try {
            long gen1 = coord.acquireCreateLease(500L, () -> false);
            createCount.incrementAndGet();
            check("initial MPV lease acquired cleanly", gen1 == 1L && coord.isActive());

            // Schedule blocked destroy on background pool (returns immediately!)
            long t0 = System.nanoTime();
            Future<?> destroyFuture =
                    coord.scheduleDestroy(
                            gen1,
                            destroyPool,
                            () -> {
                                destroyEntered.countDown();
                                try {
                                    releaseDestroy.await(5, TimeUnit.SECONDS);
                                } catch (InterruptedException ignored) {
                                }
                            });
            long scheduleMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
            check(
                    "scheduleDestroy returns immediately off main thread and enters destroy worker",
                    destroyFuture != null
                            && scheduleMs < 100L
                            && destroyEntered.await(1, TimeUnit.SECONDS)
                            && coord.isDestroying()
                            && !coord.isActive());

            // Main-thread non-blocking guard MUST throw MpvBusyTimeoutException immediately
            long mainStart = System.nanoTime();
            boolean mainThrewBusy = false;
            try {
                coord.tryAcquireCreateLeaseImmediate();
            } catch (MpvPlayer.MpvBusyTimeoutException expected) {
                mainThrewBusy = true;
            }
            long mainElapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - mainStart);
            check(
                    "main thread never blocks on hung MPV destroy (Back stays responsive)",
                    mainThrewBusy && mainElapsedMs < 50L);

            // Background wait respects waitBudgetMs (150ms) and triggers single Media3 fallback
            final AtomicReference<Throwable> bgError = new AtomicReference<>();
            final AtomicInteger fallbackCount = new AtomicInteger(0);
            long bgStart = System.nanoTime();
            Future<?> bgWait =
                    bgPool.submit(
                            () -> {
                                try {
                                    coord.acquireCreateLease(150L, () -> false);
                                    createCount.incrementAndGet();
                                } catch (MpvPlayer.MpvBusyTimeoutException timeout) {
                                    fallbackCount.incrementAndGet();
                                    bgError.set(timeout);
                                } catch (Throwable other) {
                                    bgError.set(other);
                                }
                            });
            bgWait.get(2, TimeUnit.SECONDS);
            long bgElapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - bgStart);
            check(
                    "background wait times out within budget and triggers exactly one fallback",
                    bgError.get() instanceof MpvPlayer.MpvBusyTimeoutException
                            && fallbackCount.get() == 1
                            && bgElapsedMs >= 120L
                            && bgElapsedMs < 1000L);

            // Back key pressed during background wait aborts immediately with InterruptedException
            final AtomicBoolean userBackedOut = new AtomicBoolean(false);
            final AtomicReference<Throwable> cancelErr = new AtomicReference<>();
            Future<?> cancelWait =
                    bgPool.submit(
                            () -> {
                                try {
                                    coord.acquireCreateLease(5000L, userBackedOut::get);
                                    createCount.incrementAndGet();
                                } catch (Throwable t) {
                                    cancelErr.set(t);
                                }
                            });
            Thread.sleep(60);
            long backStart = System.nanoTime();
            userBackedOut.set(true);
            cancelWait.get(1, TimeUnit.SECONDS);
            long backElapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - backStart);
            check(
                    "Back key during MPV wait cancels cleanly without creating zombie instance",
                    cancelErr.get() instanceof InterruptedException && backElapsedMs < 300L);

            // Now release the blocked old destroy — no zombie MPV may resurrect!
            releaseDestroy.countDown();
            destroyFuture.get(2, TimeUnit.SECONDS);
            Thread.sleep(100);
            check(
                    "releasing blocked old destroy leaves coordinator idle with zero zombie"
                            + " resurrection",
                    !coord.isDestroying() && !coord.isActive() && createCount.get() == 1);

            // Subsequent fresh playback request can acquire a clean new lease
            long gen2 = coord.acquireCreateLease(500L, () -> false);
            coord.abortCreateLease(gen2);
            check(
                    "fresh MPV playback succeeds after old destroy finishes",
                    gen2 == 2L && !coord.isBusy());
        } finally {
            releaseDestroy.countDown();
            destroyPool.shutdownNow();
            bgPool.shutdownNow();
        }
    }

    private static void testVideoOutputStateMachineAndBoundedRecovery() {
        // 1. Output-target identity matching for Media3 onRenderedFirstFrame
        Object surf1 = new Object();
        Object surf2 = new Object();
        check(
                "Media3 output matching accepts current Surface and rejects stale/null Surface",
                MoviePlayer.matchesRenderedOutput(surf1, surf1)
                        && !MoviePlayer.matchesRenderedOutput(surf2, surf1)
                        && !MoviePlayer.matchesRenderedOutput(surf1, null));

        // 2. Normal video playback: loading dismisses & live success records ONLY on first frame
        PlaybackOutputState media3 = new PlaybackOutputState(1, false, true);
        media3.onSurfaceAttached(101, true, 100L);
        media3.onFileOpened();
        media3.onVideoTrackPresence(true, 150L);
        media3.onDecoderPrepared(200L, true);
        check(
                "Media3 prepared without first frame keeps loading & blocks premature live success",
                !media3.shouldDismissLoading(false)
                        && !media3.shouldRecordLiveSuccess()
                        && "DECODER_PREPARED".equals(media3.diagnosticStateName()));

        // Stale surface first-frame ignored
        media3.onFirstFrameRendered(999, 250L);
        check(
                "Stale surface first-frame callback is ignored",
                media3.frameState == PlaybackOutputState.VideoFrameState.NONE
                        && !media3.shouldDismissLoading(false));

        // Real surface first-frame confirms output
        media3.onFirstFrameRendered(101, 320L);
        check(
                "Current surface first-frame dismisses loading, allows live success, disables"
                        + " watchdog",
                media3.frameState == PlaybackOutputState.VideoFrameState.FIRST_FRAME_RENDERED
                        && media3.firstFrameMs == 320L
                        && media3.shouldDismissLoading(false)
                        && media3.shouldRecordLiveSuccess()
                        && media3.evaluateWatchdog(60_000L, false)
                                == PlaybackOutputState.WatchdogAction.NONE);

        // Black-screen intro (first frame already rendered at 320ms, dark pixels for 5+ seconds)
        check(
                "Black-screen intro never triggers false recovery once first frame rendered",
                media3.evaluateWatchdog(10_000L, false) == PlaybackOutputState.WatchdogAction.NONE);

        // 3. Genuine "prepared with video track, valid surface, zero first frame" -> bounded cap
        PlaybackOutputState black = new PlaybackOutputState(2, false, true);
        black.onSurfaceAttached(202, true, 1000L);
        black.onVideoTrackPresence(true, 1000L);
        black.onDecoderPrepared(1000L, true);
        check(
                "Black-screen watchdog waits for grace window before acting",
                black.evaluateWatchdog(4500L, false) == PlaybackOutputState.WatchdogAction.NONE);
        check(
                "Watchdog step 1 requests in-place Surface rebind after grace",
                black.evaluateWatchdog(5100L, false)
                                == PlaybackOutputState.WatchdogAction.REBIND_SURFACE
                        && black.recoveryAttempts == 1
                        && black.fault
                                == PlaybackOutputState.FaultCategory.VIDEO_TRACK_NO_FIRST_FRAME);
        check(
                "Watchdog step 2 requests single controlled fallback after rebind grace",
                black.evaluateWatchdog(8200L, false)
                                == PlaybackOutputState.WatchdogAction.FALLBACK_ONCE
                        && black.recoveryAttempts == 2);
        check(
                "Watchdog step 3 stops recovery and reports stalled (never infinite loop)",
                black.evaluateWatchdog(11_300L, false)
                                == PlaybackOutputState.WatchdogAction.REPORT_STALLED
                        && black.evaluateWatchdog(30_000L, false)
                                == PlaybackOutputState.WatchdogAction.NONE);

        // 4. Surface recreation marks RECONFIRM_REQUIRED and detects SURFACE_LOST_PICTURE
        PlaybackOutputState bgReturn = new PlaybackOutputState(3, false, true);
        bgReturn.onSurfaceAttached(301, true, 100L);
        bgReturn.onVideoTrackPresence(true, 100L);
        bgReturn.onDecoderPrepared(150L, true);
        bgReturn.onFirstFrameRendered(301, 200L);
        bgReturn.onSurfaceDestroyed(2000L);
        bgReturn.onSurfaceAttached(302, true, 2500L);
        check(
                "Surface recreation requires first-frame reconfirmation",
                bgReturn.frameState == PlaybackOutputState.VideoFrameState.RECONFIRM_REQUIRED);
        check(
                "Lost picture after Surface recreation triggers SURFACE_LOST_PICTURE recovery",
                bgReturn.evaluateWatchdog(5600L, false)
                                == PlaybackOutputState.WatchdogAction.REBIND_SURFACE
                        && bgReturn.fault
                                == PlaybackOutputState.FaultCategory.SURFACE_LOST_PICTURE);

        // 5. MPV FILE_LOADED marks OUTPUT_UNCONFIRMED (never fake FIRST_FRAME_RENDERED)
        PlaybackOutputState mpv = new PlaybackOutputState(4, true, true);
        mpv.onSurfaceAttached(401, true, 100L);
        mpv.onVideoTrackPresence(true, 150L);
        mpv.onDecoderPrepared(200L, true);
        mpv.onVideoOutputUnconfirmed();
        check(
                "MPV FILE_LOADED stays OUTPUT_UNCONFIRMED, dismisses loading when VO configured,"
                        + " never loops",
                "OUTPUT_UNCONFIRMED".equals(mpv.diagnosticStateName())
                        && !mpv.shouldRecordLiveSuccess()
                        && mpv.shouldDismissLoading(true)
                        && mpv.evaluateWatchdog(20_000L, true)
                                == PlaybackOutputState.WatchdogAction.NONE);
        check(
                "MPV with VO unconfigured after grace triggers bounded recovery",
                mpv.evaluateWatchdog(5000L, false)
                        == PlaybackOutputState.WatchdogAction.REBIND_SURFACE);

        // 6. Negative false-positive guards: pure audio, paused, background, buffering, completed
        PlaybackOutputState audioOnly = new PlaybackOutputState(5, false, true);
        audioOnly.onSurfaceAttached(501, true, 100L);
        audioOnly.onVideoTrackPresence(false, 150L);
        audioOnly.onDecoderPrepared(200L, true);
        check(
                "Pure audio stream dismisses loading, allows live radio success, never triggers"
                        + " recovery",
                audioOnly.shouldDismissLoading(false)
                        && audioOnly.shouldRecordLiveSuccess()
                        && "AUDIO_ONLY".equals(audioOnly.diagnosticStateName())
                        && audioOnly.evaluateWatchdog(60_000L, false)
                                == PlaybackOutputState.WatchdogAction.NONE);

        PlaybackOutputState paused = new PlaybackOutputState(6, false, true);
        paused.onSurfaceAttached(601, true, 100L);
        paused.onVideoTrackPresence(true, 150L);
        paused.onDecoderPrepared(200L, true);
        paused.onPlayStateChanged(false, false, 300L);
        check(
                "Paused playback never triggers black-screen recovery",
                paused.shouldDismissLoading(false)
                        && paused.evaluateWatchdog(60_000L, false)
                                == PlaybackOutputState.WatchdogAction.NONE);

        PlaybackOutputState backgrounded = new PlaybackOutputState(7, false, false);
        backgrounded.onSurfaceAttached(701, true, 100L);
        backgrounded.onVideoTrackPresence(true, 150L);
        backgrounded.onDecoderPrepared(200L, false);
        check(
                "Background playback never triggers black-screen recovery",
                backgrounded.evaluateWatchdog(60_000L, false)
                        == PlaybackOutputState.WatchdogAction.NONE);

        PlaybackOutputState buffering = new PlaybackOutputState(8, false, true);
        buffering.onSurfaceAttached(801, true, 100L);
        buffering.onVideoTrackPresence(true, 150L);
        buffering.onDecoderPrepared(200L, true);
        buffering.onBufferingChanged(true, 500L);
        check(
                "Active network buffering never triggers black-screen recovery",
                buffering.evaluateWatchdog(60_000L, false)
                        == PlaybackOutputState.WatchdogAction.NONE);

        PlaybackOutputState completed = new PlaybackOutputState(9, false, true);
        completed.onSurfaceAttached(901, true, 100L);
        completed.onVideoTrackPresence(true, 150L);
        completed.onDecoderPrepared(200L, true);
        completed.onCompleted();
        check(
                "Normal completion never triggers black-screen recovery",
                completed.evaluateWatchdog(60_000L, false)
                        == PlaybackOutputState.WatchdogAction.NONE);
    }

    /**
     * Round-2 P1 verification: MPV 7-second background -> foreground return with recreated Surface.
     * Proves background time never counts toward timeout, stale old-Surface VO events are ignored,
     * healthy re-configured Surface #2 stays on MPV (OUTPUT_UNCONFIRMED, 0 recoveries), and a
     * genuinely broken Surface #2 VO still runs bounded recovery after a fresh grace window.
     */
    private static void testMpvBackgroundSurfaceRecreationAndWatchdog() {
        // 1. Healthy MPV after 7s background return
        PlaybackOutputState healthy = new PlaybackOutputState(10, true, true);
        healthy.onSurfaceAttached(1001, true, 100L);
        healthy.onVideoTrackPresence(true, 150L);
        healthy.onDecoderPrepared(200L, true);
        healthy.onVideoOutputUnconfirmed();
        healthy.onMpvVoConfigured(1001, true, 220L);
        check(
                "MPV initial Surface #1 VO configured keeps OUTPUT_UNCONFIRMED with NONE watchdog",
                healthy.frameState == PlaybackOutputState.VideoFrameState.OUTPUT_UNCONFIRMED
                        && healthy.shouldDismissLoading(true)
                        && healthy.evaluateWatchdog(2000L, true)
                                == PlaybackOutputState.WatchdogAction.NONE);

        // Background at t=2000 for 7,000 ms (Surface #1 destroyed)
        healthy.onForegroundChanged(false, 2000L);
        healthy.onPlayStateChanged(false, false, 2000L);
        healthy.onSurfaceDestroyed(2000L);
        check(
                "Backgrounding MPV clears waiting timer and requires reconfirm on next Surface",
                healthy.frameState == PlaybackOutputState.VideoFrameState.RECONFIRM_REQUIRED
                        && healthy.waitingSinceMs == 0L
                        && healthy.voConfiguredSurfaceId == 0);

        // Foreground return at t=9000 with Surface #2
        healthy.onForegroundChanged(true, 9000L);
        healthy.onSurfaceAttached(1002, true, 9000L);
        // Stale Surface #1 late VO event must be ignored
        healthy.onMpvVoConfigured(1001, true, 9005L);
        check(
                "Stale Surface #1 VO event after return is ignored for Surface #2",
                healthy.frameState == PlaybackOutputState.VideoFrameState.RECONFIRM_REQUIRED
                        && healthy.voConfiguredSurfaceId == 0
                        && !healthy.isVoConfiguredForCurrentSurface(true));

        // User resumes playback at t=9010 -> +10ms MUST NOT trigger immediate REBIND_SURFACE
        healthy.onPlayStateChanged(true, true, 9010L);
        check(
                "MPV 10ms after resuming from 7s background gets fresh grace window (NONE, no"
                        + " rebind)",
                healthy.waitingSinceMs == 9010L
                        && healthy.evaluateWatchdog(9020L, false)
                                == PlaybackOutputState.WatchdogAction.NONE);

        // Surface #2 reports vo-configured=true at t=9150 (no second FILE_LOADED!)
        healthy.onMpvVoConfigured(1002, true, 9150L);
        check(
                "MPV Surface #2 vo-configured restores OUTPUT_UNCONFIRMED without second"
                        + " FILE_LOADED and zero false fallback",
                healthy.frameState == PlaybackOutputState.VideoFrameState.OUTPUT_UNCONFIRMED
                        && healthy.voConfiguredSurfaceId == 1002
                        && healthy.shouldDismissLoading(true)
                        && healthy.evaluateWatchdog(12_500L, true)
                                == PlaybackOutputState.WatchdogAction.NONE
                        && healthy.evaluateWatchdog(69_000L, true)
                                == PlaybackOutputState.WatchdogAction.NONE
                        && healthy.recoveryAttempts == 0
                        && !healthy.rebindRequested
                        && !healthy.fallbackRequested);

        // 2. Broken MPV control: Surface #2 never configures VO after 7s background -> bounded
        // recovery
        PlaybackOutputState broken = new PlaybackOutputState(11, true, true);
        broken.onSurfaceAttached(2001, true, 100L);
        broken.onVideoTrackPresence(true, 150L);
        broken.onDecoderPrepared(200L, true);
        broken.onVideoOutputUnconfirmed();
        broken.onMpvVoConfigured(2001, true, 220L);
        broken.onForegroundChanged(false, 2000L);
        broken.onPlayStateChanged(false, false, 2000L);
        broken.onSurfaceDestroyed(2000L);
        broken.onForegroundChanged(true, 9000L);
        broken.onSurfaceAttached(2002, true, 9000L);
        broken.onPlayStateChanged(true, true, 9010L);
        check(
                "Broken MPV Surface #2 waits full 3s grace before REBIND_SURFACE -> FALLBACK_ONCE"
                        + " -> REPORT_STALLED",
                broken.evaluateWatchdog(9020L, false) == PlaybackOutputState.WatchdogAction.NONE
                        && broken.evaluateWatchdog(11_900L, false)
                                == PlaybackOutputState.WatchdogAction.NONE
                        && broken.evaluateWatchdog(12_050L, false)
                                == PlaybackOutputState.WatchdogAction.REBIND_SURFACE
                        && broken.fault == PlaybackOutputState.FaultCategory.SURFACE_LOST_PICTURE
                        && broken.evaluateWatchdog(15_100L, false)
                                == PlaybackOutputState.WatchdogAction.FALLBACK_ONCE
                        && broken.evaluateWatchdog(18_200L, false)
                                == PlaybackOutputState.WatchdogAction.REPORT_STALLED
                        && broken.evaluateWatchdog(30_000L, false)
                                == PlaybackOutputState.WatchdogAction.NONE);
    }

    /**
     * Round-2 P2 verification using the production clock-to-overlay bridge: (1) 6 seconds of
     * continuous mid-playback buffering after first frame keeps spinner & percent, (2) Terminal
     * stalled error after recovery exhaustion survives >= 2 subsequent 1Hz clock ticks with error
     * message and retry/back controls pinned visible.
     */
    private static void testOverlayBufferingAndTerminalStalledClockBridge() {
        // 1. First-frame wait -> ready -> 6s continuous mid-playback buffering
        PlaybackOutputState state = new PlaybackOutputState(20, false, true);
        PlayerChrome.OverlayState overlay = new PlayerChrome.OverlayState();
        state.onSurfaceAttached(3001, true, 100L);
        state.onVideoTrackPresence(true, 120L);
        state.onDecoderPrepared(200L, true);
        PlaybackController.stepClockOutputOverlay(state, overlay, 500L, true, false, true);
        check(
                "Initial first-frame wait shows waitingForFirstFrame overlay before frame arrives",
                overlay.waitingForFirstFrame
                        && overlay.loading
                        && overlay.shouldShowSpinner(true, false, false));

        state.onFirstFrameRendered(3001, 320L);
        PlaybackController.stepClockOutputOverlay(state, overlay, 1000L, true, false, true);
        check(
                "First frame transitions overlay cleanly to READY_CLEAN",
                !overlay.waitingForFirstFrame
                        && !overlay.loading
                        && !overlay.shouldShowSpinner(true, false, false));

        // Enter mid-playback buffering and run 6 consecutive 1Hz clock ticks (6 seconds)
        state.onBufferingChanged(true, 2000L);
        int[] percents = new int[] {12, 28, 44, 61, 79, 93};
        boolean bufferingHeldAll6s = true;
        for (int i = 0; i < percents.length; i++) {
            int pct = percents[i];
            long tickMs = 3000L + i * 1000L;
            overlay.setBuffering(true, pct, true);
            PlaybackOutputState.WatchdogAction act =
                    PlaybackController.stepClockOutputOverlay(
                            state, overlay, tickMs, true, false, true);
            if (act != PlaybackOutputState.WatchdogAction.NONE
                    || !overlay.buffering
                    || overlay.bufferingPercent != pct
                    || !overlay.loadingHeadline.contains(pct + "%")
                    || !overlay.shouldShowSpinner(true, false, false)
                    || overlay.waitingForFirstFrame) {
                bufferingHeldAll6s = false;
                break;
            }
        }
        check(
                "6 consecutive 1Hz clock ticks during mid-playback buffering preserve spinner and"
                        + " percentage",
                bufferingHeldAll6s);

        state.onBufferingChanged(false, 8500L);
        overlay.setBuffering(false, 100, true);
        PlaybackController.stepClockOutputOverlay(state, overlay, 9000L, true, false, true);
        check(
                "Ending mid-playback buffering clears spinner cleanly",
                !overlay.buffering
                        && overlay.bufferingPercent == -1
                        && !overlay.shouldShowSpinner(true, false, false));

        // 2. Exhausted black-screen recovery -> REPORT_STALLED -> 3 subsequent 1Hz clock ticks
        PlaybackOutputState stalled = new PlaybackOutputState(21, false, true);
        PlayerChrome.OverlayState stalledOverlay = new PlayerChrome.OverlayState();
        stalled.onSurfaceAttached(4001, true, 1000L);
        stalled.onVideoTrackPresence(true, 1000L);
        stalled.onDecoderPrepared(1000L, true);
        PlaybackOutputState.WatchdogAction a1 =
                PlaybackController.stepClockOutputOverlay(
                        stalled, stalledOverlay, 5100L, true, false, true);
        PlaybackOutputState.WatchdogAction a2 =
                PlaybackController.stepClockOutputOverlay(
                        stalled, stalledOverlay, 8200L, true, false, true);
        PlaybackOutputState.WatchdogAction a3 =
                PlaybackController.stepClockOutputOverlay(
                        stalled, stalledOverlay, 11_300L, true, false, true);
        check(
                "Exhausted recovery transitions through REBIND -> FALLBACK -> REPORT_STALLED into"
                        + " terminal error overlay",
                a1 == PlaybackOutputState.WatchdogAction.REBIND_SURFACE
                        && a2 == PlaybackOutputState.WatchdogAction.FALLBACK_ONCE
                        && a3 == PlaybackOutputState.WatchdogAction.REPORT_STALLED
                        && stalled.reportedStalled
                        && stalledOverlay.terminalError
                        && !stalledOverlay.waitingForFirstFrame
                        && !stalledOverlay.shouldShowSpinner(true, false, false)
                        && PlaybackController.STALLED_NO_PICTURE_MESSAGE.equals(
                                stalledOverlay.statusText)
                        && stalledOverlay.controlsMustStayVisible
                        && stalledOverlay.shouldShowTvStatus(true, true));

        // Run 3 more full 1Hz clock ticks after REPORT_STALLED
        boolean terminalPersisted = true;
        for (int tick = 1; tick <= 3; tick++) {
            PlaybackOutputState.WatchdogAction nextAct =
                    PlaybackController.stepClockOutputOverlay(
                            stalled, stalledOverlay, 11_300L + tick * 1000L, true, false, true);
            if (nextAct != PlaybackOutputState.WatchdogAction.NONE
                    || !stalled.shouldDismissLoading(false)
                    || stalled.resolveOverlayMode(false)
                            != PlaybackOutputState.UiOverlayMode.RECOVERY_STALLED_ERROR
                    || !stalledOverlay.terminalError
                    || stalledOverlay.waitingForFirstFrame
                    || stalledOverlay.loading
                    || stalledOverlay.shouldShowSpinner(true, false, false)
                    || !PlaybackController.STALLED_NO_PICTURE_MESSAGE.equals(
                            stalledOverlay.statusText)
                    || !stalledOverlay.controlsMustStayVisible
                    || !stalledOverlay.shouldShowTvStatus(true, true)) {
                terminalPersisted = false;
                break;
            }
        }
        check(
                "Terminal stalled error & controls stay visible across 3 subsequent 1Hz clock ticks"
                        + " (never reverts to waitingForFirstFrame)",
                terminalPersisted);
    }

    private static void testTlsClassificationAndDiagnostics() {
        Throwable wrappedHandshake =
                new RuntimeException(new SSLHandshakeException("Handshake failed"));
        Throwable wrappedCert =
                new RuntimeException(new CertPathValidatorException("Trust anchor not found"));
        Throwable plainIo = new IOException("Connection reset");
        check(
                "PlaybackFailure classifies SSLHandshakeException & CertPathValidatorException as"
                        + " TLS errors",
                PlaybackFailure.isTlsError(wrappedHandshake)
                        && PlaybackFailure.isTlsError(wrappedCert)
                        && !PlaybackFailure.isTlsError(plainIo));
        String tlsMsg = PlaybackFailure.message(2001, 0, true);
        check(
                "PlaybackFailure TLS message is distinct without relaxing TLS verification",
                tlsMsg.contains("TLS") && tlsMsg.contains("证书"));
    }

    private static void testSourceWiringContracts() throws Exception {
        String searchSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/GlobalSearchScreen.java");
        String cardSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/TvV17PosterCard.java");
        String mpvSrc = readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MpvPlayer.java");
        String sysSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SystemPlayer.java");
        String ctrlSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackController.java");
        String chromeSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlayerChrome.java");
        String mainSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MainActivity.java");

        check(
                "GlobalSearchScreen unbinds real nested ImageView & badge via"
                        + " TvV17PosterCard.unbindCard",
                searchSrc.contains("TvV17PosterCard.unbindCard(card)")
                        && searchSrc.contains("ImageLoader.cancelScope(a, searchArtworkScope)")
                        && cardSrc.contains("ImageLoader.unbind(poster)")
                        && cardSrc.contains("DoubanScoreRepository.unbindBadge(badge)"));
        check(
                "GlobalSearchScreen caches filter text/state to stop 16ms UI"
                        + " relayout/transient-state storm",
                searchSrc.contains("renderedFilterLabels")
                        && searchSrc.contains("renderedFilterStates")
                        && searchSrc.contains("maybeCacheResults(")
                        && mainSrc.contains("GlobalSearchScreen.trimMemory("));
        check(
                "SystemPlayer hooks MEDIA_INFO_VIDEO_RENDERING_START",
                sysSrc.contains("MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START")
                        && sysSrc.contains("notifyFirstFrameRendered("));
        check(
                "MpvPlayer observes vo-configured and never fakes firstFrameMs on FILE_LOADED",
                mpvSrc.contains("observeProperty(\"vo-configured\"")
                        && mpvSrc.contains("notifyVideoOutputUnconfirmed(")
                        && mpvSrc.contains("createWithBudget(")
                        && !mpvSrc.contains("firstFrameMs = SystemClock.elapsedRealtime()"));
        check(
                "PlaybackController guards UI-thread attach/Surface boundaries with Exception (not"
                        + " Throwable)",
                ctrlSrc.contains("handleRecoverablePlaybackException(")
                        && ctrlSrc.contains("sessionId != a.playbackSessionId")
                        && ctrlSrc.contains("MpvPlayer.createWithBudget(")
                        && ctrlSrc.contains("maybeRecordLiveSuccess("));
        check(
                "PlayerChrome separates waitingForFirstFrame from prepared before hiding spinner",
                chromeSrc.contains("waitingForFirstFrame")
                        && chromeSrc.contains("setWaitingForFirstFrame("));
        check("Prefs.KEYS remains strictly 46 keys", Prefs.KEYS.length == 46);
        String doubanSrc =
                readSrc(
                        "android-tv/src/main/java/com/pilipala/marcomovie/DoubanScoreRepository.java");
        String ciYml = readSrc(".github/workflows/build-multiplatform.yml");

        check(
                "GlobalSearchScreen enforces unified TvSearchBudget on initial, pagination, and"
                        + " retry with evicted card pruning",
                searchSrc.contains("TvSearchBudget.initialPerSourceCap(")
                        && searchSrc.contains("TvSearchBudget.enforceGlobalResultsCap(")
                        && searchSrc.contains("pruneEvictedCards()"));
        check(
                "DoubanScoreRepository validates per-waiter activityGeneration without global"
                        + " first-requester ticket abort",
                doubanSrc.contains("class BadgeWaiter")
                        && doubanSrc.contains("shouldDeliverToWaiter(")
                        && !doubanSrc.contains("ticket != a.generation"));
        check(
                "MpvPlayer binds vo-configured to attachedSurfaceId and notifies"
                        + " onVideoOutputConfigured",
                mpvSrc.contains("voConfiguredSurfaceId")
                        && mpvSrc.contains("isVoConfiguredForSurface(")
                        && mpvSrc.contains("notifyVideoOutputConfigured("));
        check(
                "PlayerChrome separates OverlayState and PlaybackController pins controls on"
                        + " reportedStalled",
                chromeSrc.contains("static final class OverlayState")
                        && chromeSrc.contains("applyOutputOverlayMode(")
                        && ctrlSrc.contains("stepClockOutputOverlay(")
                        && ctrlSrc.contains("!a.playbackOutputState.reportedStalled"));
        check(
                "TV CI workflow invokes run_tv_stability_checks.py",
                ciYml.contains("python android-tv/tests/run_tv_stability_checks.py"));

        String catalogSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/CatalogScreen.java");
        String controlsSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackControls.java");
        int histStart = catalogSrc.indexOf("static void historyPage(MainActivity a)");
        String histBody = histStart >= 0 ? catalogSrc.substring(histStart) : "";
        check(
                "CatalogScreen.historyPage registers first card as tvInitialFocus unconditionally"
                        + " and removes queued card::requestFocus",
                histBody.contains("if (i == 0) a.tvInitialFocus = card;")
                        && !histBody.contains("a.ui.post(card::requestFocus)"));
        check(
                "MainActivity preparePage clears tvInitialFocus and restore prioritizes s.focus"
                        + " then tvInitialFocus before body fallback",
                mainSrc.contains("tvInitialFocus = null;")
                        && mainSrc.contains(
                                "View target = s.focus == null ? null : root.findViewWithTag(s.focus);")
                        && mainSrc.contains("View first = tvInitialFocus;")
                        && mainSrc.indexOf("View first = tvInitialFocus;")
                                < mainSrc.indexOf("body.addFocusables(available"));
        check(
                "GlobalSearchScreen uses BatchHandoff take() without batches.get() and makeCard"
                        + " never captures SourceResult",
                searchSrc.contains("TvSearchBudget.BatchHandoff")
                        && searchSrc.contains("batches.take(site.key, accept)")
                        && !searchSrc.contains("batches.get(")
                        && searchSrc.contains(
                                "LinearLayout makeCard(final Cms.Site site, final Cms.Video video)")
                        && searchSrc.contains("card.setOnClickListener(null)"));
        check(
                "PlaybackController/PlayerChrome/MainActivity wire 404 terminalError with confirm"
                        + " retry and single-Back exit",
                chromeSrc.contains("void setTerminalError(String message)")
                        && ctrlSrc.contains("a.playerChrome.setTerminalError(")
                        && ctrlSrc.contains("a.playbackControls.reload(false)")
                        && controlsSrc.contains("a.playerChrome.terminalError")
                        && mainSrc.contains(
                                "if (!prepared && playerChrome != null && playerChrome.terminalError)"));
    }

    /**
     * Regression for R2 review finding #1: 100 sources x 80 items (lowRamTv globalCap=900, 9 each)
     * plus 1 source loading +60 items must NOT leave 60 evicted Cms.Video instances reachable via
     * staging batches or surviving card click callbacks. Counts distinct Cms.Video object
     * identities across active results + pending BatchHandoff + bound card click callbacks.
     */
    private static void testSearchBatchHandoffAndCardClosureReachability() throws Exception {
        final int globalCap = TvSearchBudget.globalCap(true, true);
        final int stepCap = TvSearchBudget.pageStepCap(true, true);
        final int initialPerSource = TvSearchBudget.initialPerSourceCap(100, true, true);
        final TvSearchBudget.BatchHandoff handoff = new TvSearchBudget.BatchHandoff();
        final Map<String, TvSearchPages> activePages = new LinkedHashMap<>();
        final Map<String, Runnable> boundCardCallbacks = new LinkedHashMap<>();

        // Simulate 100 sources x 80 items delivered through BatchHandoff -> activePages -> card
        // callbacks capturing ONLY (Cms.Site, Cms.Video) as in GlobalSearchScreen.makeCard().
        final Map<String, Cms.Site> sites = new LinkedHashMap<>();
        for (int s = 0; s < 100; s++) {
            final String key = "s" + s;
            final Cms.Site st = site(key, 1);
            sites.put(key, st);
            TvSearchPages first =
                    TvSearchPages.first(
                            "q",
                            Collections.singletonList("q"),
                            t -> true,
                            (term, p) -> listing(1, 1, key, 80, 0),
                            initialPerSource);
            handoff.put(key, first);
            TvSearchPages delivered = handoff.take(key, true);
            activePages.put(key, delivered);
            for (final Cms.Video v : delivered.videos) {
                boundCardCallbacks.put(
                        key + ":" + v.id,
                        () -> {
                            // Mirrors GlobalSearchScreen.makeCard(Cms.Site, Cms.Video): captures
                            // only site & single video, NEVER SourceResult or TvSearchPages.
                            if (st.key == null || v.id == null) throw new AssertionError();
                        });
            }
        }
        check(
                "BatchHandoff is empty after all 100 sources hand off to UI",
                handoff.pendingCount() == 0);

        // Timed-out source: UI settles as TIMEOUT before late worker finishes firstPage().
        handoff.take("late_timeout", false);
        TvSearchPages latePages =
                TvSearchPages.first(
                        "q",
                        Collections.singletonList("q"),
                        t -> true,
                        (term, p) -> listing(1, 1, "late_timeout", 80, 0),
                        initialPerSource);
        boolean acceptedLate = handoff.put("late_timeout", latePages);
        check(
                "BatchHandoff drops late worker batch after source timed out",
                !acceptedLate && handoff.pendingCount() == 0);

        // Now paginate one source by +60 items and enforce globalCap=900 + prune evicted cards.
        TvSearchPages expanded =
                activePages
                        .get("s0")
                        .next(
                                t -> true,
                                (term, p) -> listing(1, 1, "s0", 80, 0),
                                stepCap,
                                globalCap);
        activePages.put("s0", expanded);
        for (final Cms.Video v : expanded.videos) {
            final Cms.Site st = sites.get("s0");
            boundCardCallbacks.put(
                    "s0:" + v.id,
                    () -> {
                        if (st.key == null || v.id == null) throw new AssertionError();
                    });
        }
        TvSearchBudget.enforceGlobalPagesCap(activePages, "s0", globalCap);
        // Prune evicted cards exactly like GlobalSearchScreen.pruneEvictedCards().
        Set<String> liveCardKeys = new HashSet<>();
        for (Map.Entry<String, TvSearchPages> e : activePages.entrySet()) {
            for (Cms.Video v : e.getValue().videos) {
                liveCardKeys.add(e.getKey() + ":" + v.id);
            }
        }
        boundCardCallbacks.keySet().retainAll(liveCardKeys);

        // Count DISTINCT Cms.Video object identities reachable across ALL THREE roots:
        // (1) activePages, (2) handoff pending staging, (3) surviving boundCardCallbacks closures.
        List<Object> roots = new ArrayList<>();
        roots.add(activePages);
        roots.add(handoff.pendingValuesSnapshot());
        roots.add(boundCardCallbacks);
        int reachableDistinct = countReachableCmsVideos(roots);
        check(
                "100x80 + one-source +60 pagination keeps active+batches+cardCallbacks distinct"
                        + " Cms.Video objects <= 900 (not 960; actual="
                        + reachableDistinct
                        + ")",
                reachableDistinct == 900 && handoff.pendingCount() == 0);

        // Negative self-check: prove object-graph counter WOULD catch a leaky closure capturing
        // an evicted batch (simulating the old batches.get() / SourceResult capture bug).
        List<Object> leakyRoots = new ArrayList<>(roots);
        leakyRoots.add(
                (Runnable)
                        () -> {
                            if (latePages.videos.isEmpty()) throw new AssertionError();
                        });
        int leakyReachable = countReachableCmsVideos(leakyRoots);
        check(
                "Object-graph counter detects leaky closure references ("
                        + leakyReachable
                        + " > 900)",
                leakyReachable == 900 + initialPerSource);

        // Cancelled session: close() clears any unconsumed staging and rejects subsequent puts.
        TvSearchBudget.BatchHandoff cancelled = new TvSearchBudget.BatchHandoff();
        cancelled.put("s_pending", latePages);
        cancelled.close();
        boolean putAfterClose = cancelled.put("s_after_close", latePages);
        check(
                "BatchHandoff.close() clears pending batches and blocks post-cancel puts",
                !putAfterClose && cancelled.pendingCount() == 0);
    }

    /**
     * Regression for R2 review finding #2: two TvSearchPages.trimTo()/next() counterexamples.
     * (1) 3 pages x 2 items -> load all 6 -> trimTo(5) -> next() must reach page 3 and recover 6th.
     * (2) Pinyin non-direct query matching page 1 and page 10 (pages 2..9 unmatched): hitting the
     * 8-page scan cap must persist the advanced cursor (page=9) so the next click requests ONLY
     * page 10 without re-fetching pages 2..9, while still blocking duplicate-page server loops.
     */
    private static void testSearchPaginationTrimRewindAndPinyinScanCursor() throws Exception {
        // Counterexample 1: 3 pages x 2 items, load 6 -> trimTo(5) -> next() recovers 6th item.
        TvSearchPages.Fetch threePagesOfTwo = (term, p) -> listing(p, 3, "p3x2", 2, (p - 1) * 2);
        TvSearchPages tp =
                TvSearchPages.first(
                        "q", Collections.singletonList("q"), t -> true, threePagesOfTwo, 60);
        tp = tp.next(t -> true, threePagesOfTwo, 60, 900);
        tp = tp.next(t -> true, threePagesOfTwo, 60, 900);
        check(
                "3x2 baseline loads all 6 items across 3 pages",
                tp.videos.size() == 6 && !tp.hasMore());

        TvSearchPages trimmed5 = tp.trimTo(5);
        check(
                "trimTo(5) retains 5 items and marks hasMore=true",
                trimmed5.videos.size() == 5 && trimmed5.hasMore());

        TvSearchPages recovered = trimmed5.next(t -> true, threePagesOfTwo, 60, 900);
        Set<String> recoveredIds = new HashSet<>();
        for (Cms.Video v : recovered.videos) recoveredIds.add(v.id);
        check(
                "next() after trimTo(5) scans past page 1 & page 2 and recovers 6th item on page 3",
                recovered.videos.size() == 6
                        && recoveredIds.size() == 6
                        && recoveredIds.contains("p3x2_5")
                        && !recovered.hasMore());

        // Broken server repeating identical page 1 content on page 2 during rewind still
        // terminates.
        TvSearchPages.Fetch brokenRewindLoop = (term, p) -> listing(p, 10, "p3x2", 2, 0);
        TvSearchPages rewindStopped = trimmed5.next(t -> true, brokenRewindLoop, 60, 900);
        check(
                "Broken server repeating identical page during rewind still terminates pagination",
                !rewindStopped.hasMore());

        // Counterexample 2: pinyin non-direct term matches page 1 and page 10; pages 2..9 have
        // distinct non-matching items.
        final List<Integer> requestedPages = new ArrayList<>();
        TvSearchPages.Fetch pinyinTenPages =
                (term, p) -> {
                    requestedPages.add(p);
                    Cms.Listing out = new Cms.Listing();
                    out.page = p;
                    out.pageCount = 10;
                    Cms.Video v = new Cms.Video();
                    v.id = "py_" + p;
                    v.title = (p == 1 || p == 10) ? ("MATCH_TITLE_" + p) : ("OTHER_" + p);
                    out.videos.add(v);
                    return out;
                };
        SearchVariants.Match pinyinMatch = title -> title != null && title.startsWith("MATCH_");
        TvSearchPages py1 =
                TvSearchPages.first(
                        "ldh", Collections.singletonList("liu"), pinyinMatch, pinyinTenPages, 60);
        check(
                "Pinyin first() matches page 1 and reports hasMore=true",
                py1.videos.size() == 1
                        && "py_1".equals(py1.videos.get(0).id)
                        && py1.hasMore()
                        && requestedPages.equals(Collections.singletonList(1)));

        requestedPages.clear();
        TvSearchPages py2 = py1.next(pinyinMatch, pinyinTenPages, 60, 900);
        check(
                "Pinyin click #1 scans pages 2..9 (cap 8) and persists cursor at page 9",
                requestedPages.equals(Arrays.asList(2, 3, 4, 5, 6, 7, 8, 9))
                        && py2.videos.size() == 1
                        && py2.hasMore()
                        && py2.cursors.get(0).page == 9);

        requestedPages.clear();
        TvSearchPages py3 = py2.next(pinyinMatch, pinyinTenPages, 60, 900);
        check(
                "Pinyin click #2 requests ONLY page 10 (no 2..9 repeat) and retrieves page 10 hit",
                requestedPages.equals(Collections.singletonList(10))
                        && py3.videos.size() == 2
                        && "py_10".equals(py3.videos.get(1).id)
                        && !py3.hasMore());

        // Broken server repeating identical unmatched page 1 on page 2 still stops (no endless
        // loop).
        TvSearchPages.Fetch duplicatePinyinLoop =
                (term, p) -> {
                    Cms.Listing out = new Cms.Listing();
                    out.page = p;
                    out.pageCount = 50;
                    Cms.Video v = new Cms.Video();
                    v.id = "py_1";
                    v.title = "MATCH_TITLE_1";
                    out.videos.add(v);
                    return out;
                };
        TvSearchPages dupStop = py1.next(pinyinMatch, duplicatePinyinLoop, 60, 900);
        check(
                "Normal pagination duplicate-page protection remains intact for non-direct terms",
                !dupStop.hasMore());
    }

    /**
     * Regression for TV watch-history default focus: models the exact MainActivity.openScreenNow()
     * + CatalogScreen.historyPage() + MainActivity.restore() UI queue order so a regression that
     * only calls ui.post(card::requestFocus) without registering tvInitialFocus fails after the
     * queue finishes draining.
     */
    private static void testWatchHistoryDefaultFocusAfterGenericRestore() {
        final class FakeHistoryHost {
            String currentFocusTag;
            String savedScreenFocus;
            String tvInitialFocusTag;
            final List<String> bodyFocusables = new ArrayList<>();
            final Deque<Runnable> uiQueue = new ArrayDeque<>();

            void preparePage() {
                tvInitialFocusTag = null;
                bodyFocusables.clear();
            }

            void renderHistory(
                    List<String> historyKeys, boolean legacyBugMode, boolean privateMode) {
                preparePage();
                if (historyKeys.isEmpty()) {
                    if (!privateMode) bodyFocusables.add("history-cloud-sync");
                    return;
                }
                if (!privateMode) bodyFocusables.add("history-cloud-sync");
                bodyFocusables.add("history-clear");
                for (int i = 0; i < historyKeys.size(); i++) {
                    final String tag = "history:" + historyKeys.get(i);
                    bodyFocusables.add(tag);
                    if (legacyBugMode) {
                        if (i == 0 && savedScreenFocus == null) {
                            uiQueue.addLast(() -> currentFocusTag = tag);
                        }
                    } else {
                        if (i == 0) {
                            tvInitialFocusTag = tag;
                        }
                    }
                }
            }

            void enqueueRestore() {
                uiQueue.addLast(
                        () -> {
                            String target =
                                    savedScreenFocus != null
                                                    && bodyFocusables.contains(savedScreenFocus)
                                            ? savedScreenFocus
                                            : null;
                            if (target != null) {
                                currentFocusTag = target;
                                return;
                            }
                            String first =
                                    tvInitialFocusTag != null
                                                    && bodyFocusables.contains(tvInitialFocusTag)
                                            ? tvInitialFocusTag
                                            : null;
                            if (first == null && !bodyFocusables.isEmpty()) {
                                first = bodyFocusables.get(0);
                            }
                            if (first != null) currentFocusTag = first;
                        });
            }

            void drainUi() {
                while (!uiQueue.isEmpty()) {
                    uiQueue.removeFirst().run();
                }
            }
        }

        // First prove the old bug IS caught when draining render -> restore:
        FakeHistoryHost legacy = new FakeHistoryHost();
        legacy.renderHistory(Arrays.asList("s1:vidA", "s1:vidB"), true, false);
        legacy.enqueueRestore();
        legacy.drainUi();
        check(
                "Regression harness catches old bug (restore steals focus to topBar after queued"
                        + " card::requestFocus)",
                "history-cloud-sync".equals(legacy.currentFocusTag));

        // 1. Fresh entry with records (normal & private mode): final focus lands on first card.
        FakeHistoryHost fixed = new FakeHistoryHost();
        fixed.renderHistory(Arrays.asList("s1:vidA", "s1:vidB"), false, false);
        fixed.enqueueRestore();
        fixed.drainUi();
        check(
                "Fresh history entry lands final focus on recent first card after generic restore",
                "history:s1:vidA".equals(fixed.currentFocusTag));

        FakeHistoryHost priv = new FakeHistoryHost();
        priv.renderHistory(Arrays.asList("s1:vidA", "s1:vidB"), false, true);
        priv.enqueueRestore();
        priv.drainUi();
        check(
                "Private mode fresh history entry lands final focus on recent first card",
                "history:s1:vidA".equals(priv.currentFocusTag));

        // 2. Return from second card (vidB) even when ordering shifts: saved tag wins over card 0.
        fixed.savedScreenFocus = "history:s1:vidB";
        fixed.renderHistory(Arrays.asList("s1:vidC", "s1:vidA", "s1:vidB"), false, false);
        fixed.enqueueRestore();
        fixed.drainUi();
        check(
                "Returning from vidB restores vidB by stable tag even after order shifts",
                "history:s1:vidB".equals(fixed.currentFocusTag));

        // 3. Focused card deleted -> re-render + restore falls back to remaining first card.
        fixed.savedScreenFocus = "history:s1:vidB";
        fixed.renderHistory(Arrays.asList("s1:vidC", "s1:vidA"), false, false);
        fixed.enqueueRestore();
        fixed.drainUi();
        check(
                "Deleting focused history card falls back to remaining first card (not topBar)",
                "history:s1:vidC".equals(fixed.currentFocusTag));

        // 4. Single record -> unique card; empty history -> tvInitialFocus stays null.
        FakeHistoryHost single = new FakeHistoryHost();
        single.renderHistory(Collections.singletonList("s1:only"), false, false);
        single.enqueueRestore();
        single.drainUi();
        check(
                "Single history record focuses the unique card",
                "history:s1:only".equals(single.currentFocusTag));

        FakeHistoryHost empty = new FakeHistoryHost();
        empty.renderHistory(Collections.emptyList(), false, true);
        empty.enqueueRestore();
        empty.drainUi();
        check(
                "Empty history leaves tvInitialFocus null without fabricating placeholder focus",
                empty.tvInitialFocusTag == null && empty.currentFocusTag == null);
    }

    /**
     * Regression for R2 review finding #3: HTTP 404 playback failure produces user-facing 404 error
     * text (never stale "正在播放"), hides loading spinner, keeps TV status & controls pinned.
     */
    private static void testHttp404TerminalErrorOverlayAndRemoteActions() {
        String msg404 = PlaybackFailure.message(2004, 404, false) + "（2004）";
        check(
                "HTTP 404 maps to explicit expired/missing link message with code 2004",
                msg404.contains("播放链接已失效或内容不存在")
                        && msg404.contains("2004")
                        && !msg404.contains("正在播放"));

        PlayerChrome.OverlayState overlay = new PlayerChrome.OverlayState();
        overlay.setBuffering(true, 45, true);
        overlay.setTerminalError(msg404);
        check(
                "setTerminalError clears loading/buffering, pins controls, and exposes 404 status",
                overlay.terminalError
                        && overlay.controlsMustStayVisible
                        && !overlay.loading
                        && !overlay.waitingForFirstFrame
                        && !overlay.buffering
                        && overlay.bufferingPercent == -1
                        && !overlay.shouldShowSpinner(false, false, false)
                        && overlay.shouldShowTvStatus(false, false)
                        && msg404.equals(overlay.statusText));

        // Stale historyFallbackBookmark from an earlier watch-history browse must NOT hijack
        // HTTP 404 error handling of a different movie/site.
        WatchHistory.Entry prevHist = new WatchHistory.Entry();
        prevHist.site = "hist_site";
        prevHist.id = "vid_yi";
        prevHist.title = "测试剧乙";
        Cms.Site otherSite = site("err_404_site", 1);
        Cms.Video otherVideo = new Cms.Video();
        otherVideo.id = "err_404";
        otherVideo.title = "404测试";
        Cms.Site sameSite = site("hist_site", 1);
        Cms.Video sameVideo = new Cms.Video();
        sameVideo.id = "vid_yi";
        sameVideo.title = "测试剧乙";
        check(
                "Stale historyFallbackBookmark does not match a different site/video on 404",
                !PlaybackController.matchesHistoryFallbackBookmark(prevHist, otherSite, otherVideo)
                        && PlaybackController.matchesHistoryFallbackBookmark(
                                prevHist, sameSite, sameVideo));
    }

    /**
     * Regression for R4 TV Detail history-bookmark cross-contamination fix: verifies both the
     * "!playable" (empty lines) and "onDetailError" (detail 404/failure) branches of TvDetailHost
     * validate historyFallbackBookmark ownership by (site.key, video.id), never hijack an unrelated
     * title 《乙》 to search/resume 《甲》, and still preserve cross-source resume for 《甲》 itself.
     */
    private static void testTvDetailHostHistoryFallbackBookmarkOwnership() throws Exception {
        Cms.Site site1 = site("src_primary", 1);
        Cms.Site site2 = site("src_backup", 1);

        WatchHistory.Entry bmJia = new WatchHistory.Entry();
        bmJia.site = site1.key;
        bmJia.id = "vid_jia";
        bmJia.title = "测试剧甲";
        bmJia.episode = "第8集";
        bmJia.index = 7;
        bmJia.position = 720000;

        Cms.Video videoJia = new Cms.Video();
        videoJia.id = "vid_jia";
        videoJia.title = "测试剧甲";

        Cms.Video videoYiSameSite = new Cms.Video();
        videoYiSameSite.id = "vid_yi";
        videoYiSameSite.title = "测试剧乙";

        Cms.Video videoYiSameIdOtherSite = new Cms.Video();
        videoYiSameIdOtherSite.id = "vid_jia";
        videoYiSameIdOtherSite.title = "测试剧乙";

        Cms.Video videoMissingId = new Cms.Video();
        videoMissingId.id = "";
        videoMissingId.title = "无ID影片";

        // 1. Stale bookmark for 《甲》 on site1 must NEVER match never-watched 《乙》 (same site diff
        // id, diff site same id, or blank id) in either empty-lines or detail-error branch.
        check(
                "TvDetailHost rejects stale 《甲》 bookmark when 《乙》 (same site, diff id) fails or"
                        + " has empty lines",
                TvDetailHost.resolveHistoryFallbackBookmark(null, bmJia, site1, videoYiSameSite)
                        == null);
        check(
                "TvDetailHost rejects stale 《甲》 bookmark when 《乙》 (diff site, same id) fails or"
                        + " has empty lines",
                TvDetailHost.resolveHistoryFallbackBookmark(
                                null, bmJia, site2, videoYiSameIdOtherSite)
                        == null);
        check(
                "Strict matchesHistoryFallbackBookmark rejects blank video.id or null site",
                !PlaybackController.matchesHistoryFallbackBookmark(bmJia, site1, videoMissingId)
                        && !PlaybackController.matchesHistoryFallbackBookmark(bmJia, null, videoJia)
                        && !PlaybackController.matchesHistoryFallbackBookmark(bmJia, site1, null));

        // 2. When 《甲》 itself fails (detail 404 or empty lines) from its own history entry,
        // ownership matches and preserves episode + position for cross-source resume.
        WatchHistory.Entry matchedPendingOnly =
                TvDetailHost.resolveHistoryFallbackBookmark(null, bmJia, site1, videoJia);
        WatchHistory.Entry matchedActiveBm =
                TvDetailHost.resolveHistoryFallbackBookmark(bmJia, null, site1, videoJia);
        check(
                "TvDetailHost preserves 《甲》 cross-source fallback (Ep 8, 720000ms) when site.key"
                        + " and video.id match",
                matchedPendingOnly == bmJia
                        && matchedActiveBm == bmJia
                        && "第8集".equals(matchedPendingOnly.episode)
                        && matchedPendingOnly.position == 720000);

        // 3. Production source wiring verification for BOTH TvDetailHost branches.
        String detailHostSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/TvDetailHost.java");
        int noPlayableIdx = detailHostSrc.indexOf("if (!playable)");
        int onErrorIdx = detailHostSrc.indexOf("MainActivity.Done<Throwable> onDetailError");
        String noPlayableSection =
                noPlayableIdx >= 0 && onErrorIdx > noPlayableIdx
                        ? detailHostSrc.substring(noPlayableIdx, onErrorIdx)
                        : "";
        String onErrorSection =
                onErrorIdx >= 0
                        ? detailHostSrc.substring(
                                onErrorIdx, Math.min(detailHostSrc.length(), onErrorIdx + 1800))
                        : "";
        check(
                "TvDetailHost !playable branch validates ownership via"
                        + " matchesHistoryFallbackBookmark and searches only resolved.title",
                noPlayableSection.contains("PlaybackController.matchesHistoryFallbackBookmark(")
                        && noPlayableSection.contains("resolveHistoryFallbackBookmark(bm,")
                        && noPlayableSection.contains("a.historyFallbackBookmark = null;")
                        && noPlayableSection.contains("a.openSearch(resolved.title.trim())"));
        check(
                "TvDetailHost onDetailError branch validates ownership via"
                        + " matchesHistoryFallbackBookmark and searches only initialVideo.title",
                onErrorSection.contains("PlaybackController.matchesHistoryFallbackBookmark(")
                        && onErrorSection.contains("resolveHistoryFallbackBookmark(")
                        && onErrorSection.contains("a.historyFallbackBookmark = null;")
                        && onErrorSection.contains("a.openSearch(fallbackTitle)"));
    }

    /**
     * Regression for R5 cross-source history migration data-safety fix: verifies PendingMigration
     * binds oldKey to (targetSiteKey, targetVideoId), never deletes old 《甲》 when backup fails or
     * playback switches to 《乙》, and atomically removes old 《甲》 ONLY after target 《甲》 saves.
     */
    private static void testWatchHistoryScopedMigrationSafety() throws Exception {
        WatchHistory.setCorrupted(false);

        WatchHistory.Entry oldJia = new WatchHistory.Entry();
        oldJia.site = "src_primary";
        oldJia.id = "vid_jia";
        oldJia.title = "测试剧甲";
        oldJia.episode = "第8集";
        oldJia.index = 7;
        oldJia.position = 12000;
        oldJia.duration = 45000;
        oldJia.updated = 1000L;

        WatchHistory.Entry otherBing = new WatchHistory.Entry();
        otherBing.site = "src_primary";
        otherBing.id = "vid_bing";
        otherBing.title = "测试剧丙";
        otherBing.episode = "第2集";
        otherBing.index = 1;
        otherBing.position = 5000;
        otherBing.duration = 45000;
        otherBing.updated = 500L;

        WatchHistory.Entry backupJia = new WatchHistory.Entry();
        backupJia.site = "src_backup";
        backupJia.id = "vid_jia_backup";
        backupJia.title = "测试剧甲";
        backupJia.episode = "第8集";
        backupJia.index = 7;
        backupJia.position = 12000;
        backupJia.duration = 45000;
        backupJia.updated = 2000L;

        WatchHistory.Entry videoYi = new WatchHistory.Entry();
        videoYi.site = "src_backup";
        videoYi.id = "vid_yi";
        videoYi.title = "测试剧乙";
        videoYi.episode = "第1集";
        videoYi.index = 0;
        videoYi.position = 3000;
        videoYi.duration = 45000;
        videoYi.updated = 3000L;

        WatchHistory.PendingMigration migration =
                new WatchHistory.PendingMigration(oldJia.key(), backupJia.site, backupJia.id);
        WatchHistory.PendingMigration selfMigration =
                new WatchHistory.PendingMigration(oldJia.key(), oldJia.site, oldJia.id);

        check(
                "PendingMigration matches ONLY exact target (site, id) and rejects 《乙》 or self",
                migration.matchesTarget(backupJia.site, backupJia.id)
                        && migration.matchesSavedBookmark(backupJia)
                        && !migration.matchesTarget(videoYi.site, videoYi.id)
                        && !migration.matchesSavedBookmark(videoYi)
                        && !migration.matchesSavedBookmark(null)
                        && !selfMigration.matchesTarget(oldJia.site, oldJia.id));

        // Path 1: Backup fails / early back -> user plays 《乙》 -> 《甲》 original record stays intact.
        String hist = WatchHistory.upsert(WatchHistory.upsert("[]", otherBing), oldJia);
        String afterYi =
                migration.matchesSavedBookmark(videoYi)
                        ? WatchHistory.upsertAndMigrate(hist, videoYi, migration.oldKey)
                        : WatchHistory.upsert(hist, videoYi);
        List<WatchHistory.Entry> entriesAfterYi = WatchHistory.read(afterYi);
        WatchHistory.Entry foundOldJia = null;
        WatchHistory.Entry foundYi = null;
        WatchHistory.Entry foundBackupJia = null;
        for (WatchHistory.Entry e : entriesAfterYi) {
            if (oldJia.key().equals(e.key())) foundOldJia = e;
            if (videoYi.key().equals(e.key())) foundYi = e;
            if (backupJia.key().equals(e.key())) foundBackupJia = e;
        }
        check(
                "Path 1: Playing 《乙》 after failed/cancelled migration keeps 《甲》 Ep 8 @ 12000ms"
                        + " intact with no stray backup entry",
                foundOldJia != null
                        && "第8集".equals(foundOldJia.episode)
                        && foundOldJia.position == 12000
                        && foundYi != null
                        && foundBackupJia == null);

        // Path 2: 《甲》 succeeds on backup source -> atomic upsertAndMigrate saves new record &
        // removes old.
        String afterMigrate = WatchHistory.upsertAndMigrate(hist, backupJia, migration.oldKey);
        List<WatchHistory.Entry> entriesAfterMigrate = WatchHistory.read(afterMigrate);
        WatchHistory.Entry oldAfter = null;
        WatchHistory.Entry newAfter = null;
        WatchHistory.Entry bingAfter = null;
        for (WatchHistory.Entry e : entriesAfterMigrate) {
            if (oldJia.key().equals(e.key())) oldAfter = e;
            if (backupJia.key().equals(e.key())) newAfter = e;
            if (otherBing.key().equals(e.key())) bingAfter = e;
        }
        check(
                "Path 2: Successful migration persists backup 《甲》 Ep 8 @ 12000ms, removes old"
                        + " 《甲》, and preserves unrelated entries",
                oldAfter == null
                        && newAfter != null
                        && "第8集".equals(newAfter.episode)
                        && newAfter.position == 12000
                        && newAfter.duration == 45000
                        && bingAfter != null);

        // Production source wiring checks across MainActivity, CatalogScreen, TvDetailHost,
        // PlaybackController
        String mainSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MainActivity.java");
        String catSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/CatalogScreen.java");
        String detailSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/TvDetailHost.java");
        String ctrlSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackController.java");
        check(
                "Production code replaces bare migratingHistoryOldKey with scoped"
                        + " PendingMigration and commits atomically via"
                        + " tryCommitPendingHistoryMigration",
                mainSrc.contains("WatchHistory.PendingMigration pendingHistoryMigration;")
                        && mainSrc.contains("boolean deferPlayingBookmarkUntilMigrationCommit;")
                        && !mainSrc.contains("migratingHistoryOldKey")
                        && catSrc.contains("new WatchHistory.PendingMigration(")
                        && detailSrc.contains("clearMismatchedHistoryMigration(")
                        && ctrlSrc.contains("WatchHistory.enqueueUpsertAndMigrate(")
                        && ctrlSrc.contains("tryCommitPendingHistoryMigration(")
                        && ctrlSrc.contains("deferForMigration")
                        && !ctrlSrc.contains("migratingHistoryOldKey"));
    }

    /**
     * Regression for R6 item 1: full 60-entry WatchHistory with original 《甲》 in the middle and
     * backup 《甲》 under a brand-new key must remove oldKey and duplicate targetKey BEFORE adding
     * the new entry at index 0 and trimming to 60 ONCE in a single write — preserving all 59 other
     * entries' keys, positions, and relative order.
     */
    private static void testWatchHistoryFullCapacityMigration60Entries() throws Exception {
        WatchHistory.setCorrupted(false);

        final int total = WatchHistory.LIMIT; // 60
        final int jiaIndex = 29; // right in the middle
        List<WatchHistory.Entry> expectedOthers = new ArrayList<>();
        String histJson = "[]";
        WatchHistory.Entry oldJia = null;

        // Build exact order [0 .. 59] by inserting from oldest (59) down to newest (0).
        for (int rank = total - 1; rank >= 0; rank--) {
            WatchHistory.Entry e = new WatchHistory.Entry();
            if (rank == jiaIndex) {
                e.site = "src_primary_full";
                e.id = "vid_jia_mid";
                e.title = "测试剧甲";
                e.episode = "第8集";
                e.index = 7;
                e.position = 12000;
                e.duration = 45000;
                oldJia = e;
            } else {
                e.site = "site_" + rank;
                e.id = "vid_" + rank;
                e.title = "其他剧_" + rank;
                e.episode = "第" + ((rank % 12) + 1) + "集";
                e.index = rank % 12;
                e.position = 1000 + rank * 370;
                e.duration = 90000;
            }
            e.poster = "https://example.invalid/p" + rank + ".jpg";
            e.line = "主线";
            e.updated = 100000L - rank * 100L;
            histJson = WatchHistory.upsert(histJson, e);
        }

        List<WatchHistory.Entry> before = WatchHistory.read(histJson);
        check(
                "Full-capacity setup has exact 60 entries with original 《甲》 at middle index 29",
                before.size() == 60
                        && oldJia != null
                        && oldJia.key().equals(before.get(jiaIndex).key()));
        for (int i = 0; i < before.size(); i++) {
            if (i != jiaIndex) expectedOthers.add(before.get(i));
        }

        WatchHistory.Entry backupJia = new WatchHistory.Entry();
        backupJia.site = "src_backup_new";
        backupJia.id = "vid_jia_backup_new";
        backupJia.title = "测试剧甲";
        backupJia.poster = "https://example.invalid/p_backup.jpg";
        backupJia.line = "备用线";
        backupJia.episode = "第8集";
        backupJia.index = 7;
        backupJia.position = 13250;
        backupJia.duration = 45000;
        backupJia.updated = 200000L;

        final AtomicReference<String> storedRaw = new AtomicReference<>(histJson);
        final AtomicInteger writeCount = new AtomicInteger(0);
        WatchHistory.Persistence mockPersistence =
                new WatchHistory.Persistence() {
                    @Override
                    public String readRaw() {
                        return storedRaw.get();
                    }

                    @Override
                    public boolean readCorruptedPref() {
                        return false;
                    }

                    @Override
                    public void writeState(String historyJson, boolean corrupted) {
                        storedRaw.set(historyJson);
                        writeCount.incrementAndGet();
                    }
                };

        String afterJson =
                WatchHistory.enqueueUpsertAndMigrate(mockPersistence, backupJia, oldJia.key())
                        .get(5, TimeUnit.SECONDS);
        List<WatchHistory.Entry> after = WatchHistory.read(afterJson);

        boolean all59Preserved = after.size() == 60 && expectedOthers.size() == 59;
        if (all59Preserved) {
            for (int i = 0; i < 59; i++) {
                WatchHistory.Entry exp = expectedOthers.get(i);
                WatchHistory.Entry got = after.get(i + 1);
                if (!exp.key().equals(got.key())
                        || exp.position != got.position
                        || exp.duration != got.duration
                        || !exp.episode.equals(got.episode)) {
                    all59Preserved = false;
                    break;
                }
            }
        }
        boolean oldRemoved = true;
        for (WatchHistory.Entry e : after) {
            if (oldJia.key().equals(e.key())) oldRemoved = false;
        }
        check(
                "60-entry migration writes once, retains 60 items, puts backup 《甲》 first, removes"
                        + " old 《甲》, and keeps all 59 others' keys/positions/order intact",
                writeCount.get() == 1
                        && after.size() == 60
                        && backupJia.key().equals(after.get(0).key())
                        && "第8集".equals(after.get(0).episode)
                        && after.get(0).position == 13250
                        && oldRemoved
                        && all59Preserved
                        && "site_59\nvid_59".equals(after.get(59).key()));

        // Invalid newEntry must NOT delete oldKey or mutate storage
        WatchHistory.Entry invalidEntry = new WatchHistory.Entry();
        invalidEntry.site = "src_backup_new";
        invalidEntry.id = "";
        int writesBeforeInvalid = writeCount.get();
        String unchanged =
                WatchHistory.enqueueUpsertAndMigrate(mockPersistence, invalidEntry, backupJia.key())
                        .get(5, TimeUnit.SECONDS);
        check(
                "Invalid newEntry during upsertAndMigrate performs zero writes and preserves"
                        + " existing history",
                writeCount.get() == writesBeforeInvalid && afterJson.equals(unchanged));

        // Duplicate target key already in the 60-entry list alongside oldKey must dedupe cleanly
        WatchHistory.Entry dupTarget = WatchHistory.cloneEntry(after.get(40));
        dupTarget.position = 77777;
        String afterDupMigrate =
                WatchHistory.upsertAndMigrate(afterJson, dupTarget, after.get(15).key());
        List<WatchHistory.Entry> dupList = WatchHistory.read(afterDupMigrate);
        check(
                "Migrating when both oldKey and targetKey exist removes both before prepending"
                        + " once",
                dupList.size() == 59
                        && dupTarget.key().equals(dupList.get(0).key())
                        && dupList.get(0).position == 77777);

        String whSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/WatchHistory.java");
        int migIdx = whSrc.indexOf("static String upsertAndMigrate(");
        String migBody =
                migIdx >= 0 ? whSrc.substring(migIdx, whSrc.indexOf("static String remove(")) : "";
        check(
                "WatchHistory.upsertAndMigrate removes old/target keys before prepending and trims"
                        + " to LIMIT once (no two-step upsert+remove)",
                !migBody.contains("upsert(text,")
                        && !migBody.contains("remove(updated,")
                        && migBody.contains("entries.add(0, newEntry)")
                        && migBody.contains("Math.min(LIMIT, entries.size())"));
    }

    /**
     * Regression for R6 item 2: verifies PendingMigration stays armed while backup prepares paused
     * in background (after system Home), refuses to commit until active foreground playback
     * advances real progress, and blocks unplayed deferred bookmark persistence on background exit.
     */
    private static void testWatchHistoryMigrationTimingBackgroundHomeAndProgressGate()
            throws Exception {
        WatchHistory.PendingMigration pm =
                new WatchHistory.PendingMigration(
                        "src_primary\nvid_jia", "src_backup", "vid_jia_backup");

        // 1. Background prepare completes while paused after Home -> must NOT confirm
        boolean bgOnPrepared = pm.observePlaybackProgress(false, false, false, 12000, 12000);
        boolean bgClockTick = pm.observePlaybackProgress(false, false, false, 12000, 12000);
        // 2. Return to foreground while still paused -> still must NOT confirm
        boolean fgStillPaused = pm.observePlaybackProgress(true, false, false, 12000, 12000);
        check(
                "Background prepared & paused (and foreground before resume) never confirm"
                        + " migration",
                !bgOnPrepared && !bgClockTick && !fgStillPaused && !pm.isProgressConfirmed());

        // 3. User resumes in foreground -> first playing tick captures baseline (still false),
        //    tiny <250ms jitter stays false, real progress >=250ms confirms!
        boolean resumeTick0 = pm.observePlaybackProgress(true, true, true, 12000, 12000);
        boolean jitterTick = pm.observePlaybackProgress(true, true, true, 12120, 12000);
        boolean realProgress = pm.observePlaybackProgress(true, true, true, 12450, 12000);
        check(
                "Foreground resume confirms migration ONLY after actual playback advances >="
                        + " 250ms",
                !resumeTick0 && !jitterTick && realProgress && pm.isProgressConfirmed());

        // 4. Seek jump from 0 -> 12000 must NOT falsely confirm until playback actually advances
        WatchHistory.PendingMigration pmSeek =
                new WatchHistory.PendingMigration(
                        "src_primary\nvid_jia2", "src_backup", "vid_jia2_backup");
        boolean preSeekZero =
                pmSeek.observePlaybackProgress(true, true, true, 0, 12000, false, false, 1000L);
        boolean seekLanded =
                pmSeek.observePlaybackProgress(true, true, true, 12000, 12000, false, false, 1200L);
        boolean afterStep1 =
                pmSeek.observePlaybackProgress(true, true, true, 12150, 12000, false, false, 1350L);
        boolean afterAdvance =
                pmSeek.observePlaybackProgress(true, true, true, 12300, 12000, false, false, 1500L);
        check(
                "Initial 0->12000 seek jump does not prematurely confirm migration before"
                        + " consecutive real playback progress",
                !preSeekZero
                        && !seekLanded
                        && !afterStep1
                        && afterAdvance
                        && pmSeek.isProgressConfirmed());

        // 5. Start-from-0 playback advances cleanly once pos >= 250ms
        WatchHistory.PendingMigration pmZero =
                new WatchHistory.PendingMigration(
                        "src_primary\nvid_jia3", "src_backup", "vid_jia3_backup");
        boolean z0 = pmZero.observePlaybackProgress(true, true, true, 0, 0);
        boolean z1 = pmZero.observePlaybackProgress(true, true, true, 300, 0);
        check(
                "Start-from-0 backup playback confirms once real position advances >= 250ms",
                !z0 && z1 && pmZero.isProgressConfirmed());

        // 6. Production wiring: releasePlayer runs before clearing pendingHistoryMigration and
        //    deferPlayingBookmarkUntilMigrationCommit blocks unplayed bookmark writes.
        String ctrlSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackController.java");
        String mainSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MainActivity.java");
        int leaveIdx = ctrlSrc.indexOf("static void leavePlayback(");
        String leaveBody =
                leaveIdx >= 0
                        ? ctrlSrc.substring(
                                leaveIdx, ctrlSrc.indexOf("static void minimizePlayback("))
                        : "";
        int prepIdx = mainSrc.indexOf("void preparePage(boolean navigation)");
        String prepBody = prepIdx >= 0 ? mainSrc.substring(prepIdx, prepIdx + 800) : "";
        check(
                "Production leavePlayback/preparePage release player before clearing pending"
                        + " migration and guard unplayed deferred bookmarks",
                leaveBody.indexOf("releasePlayer(a);") >= 0
                        && leaveBody.indexOf("clearPendingHistoryMigration(a);")
                                > leaveBody.indexOf("releasePlayer(a);")
                        && prepBody.indexOf("releasePlayer();") >= 0
                        && prepBody.indexOf("if (navigation) pendingHistoryMigration = null;")
                                > prepBody.indexOf("releasePlayer();")
                        && ctrlSrc.contains(
                                "if (a.deferPlayingBookmarkUntilMigrationCommit) return;")
                        && ctrlSrc.contains("observePendingHistoryMigration(a);"));
    }

    /**
     * Regression for R7 seek-reset boundary: auto-resume seek (35ms -> 12000ms) and manual remote
     * fast-forward (12000ms -> 27000ms) must reset migration progress sampling to the post-seek
     * landing position and wait for natural playback >= 250ms before migrating; stalling, exiting,
     * or switching movies right after the seek must preserve the original bookmark untouched.
     */
    private static void testWatchHistoryMigrationSeekResetProgressGate() throws Exception {
        WatchHistory.setCorrupted(false);

        WatchHistory.Entry oldJia = new WatchHistory.Entry();
        oldJia.site = "src_primary";
        oldJia.id = "vid_jia";
        oldJia.title = "测试剧甲";
        oldJia.episode = "第8集";
        oldJia.index = 7;
        oldJia.position = 12000;
        oldJia.duration = 45000;
        oldJia.updated = 1000L;
        String baseHist = WatchHistory.upsert("[]", oldJia);

        // Case 1A: Auto-resume seek 35ms -> 12000ms (with seek target already armed) -> 12300ms
        WatchHistory.PendingMigration pmAutoA =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        boolean aAt35 = pmAutoA.observePlaybackProgress(true, true, true, 35, 12000);
        boolean aAt12000 = pmAutoA.observePlaybackProgress(true, true, true, 12000, 12000);
        boolean aAt12200 = pmAutoA.observePlaybackProgress(true, true, true, 12200, 12000);
        boolean aAt12300 = pmAutoA.observePlaybackProgress(true, true, true, 12300, 12000);
        check(
                "Case 1A: Auto-resume 35ms -> 12000ms keeps old bookmark until natural playback"
                        + " reaches 12300ms",
                !aAt35 && !aAt12000 && !aAt12200 && aAt12300 && pmAutoA.isProgressConfirmed());

        // Case 1B: Player already sampled 35ms before delayed pendingResumeMs triggers seek(12000)
        WatchHistory.PendingMigration pmAutoB =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        boolean bPreSeek35 = pmAutoB.observePlaybackProgress(true, true, true, 35, 0);
        pmAutoB.resetProgressBaselineForSeek(12000, 35);
        boolean bStale35 = pmAutoB.observePlaybackProgress(true, true, true, 35, 12000);
        boolean bLanded12000 = pmAutoB.observePlaybackProgress(true, true, true, 12000, 12000);
        boolean bPlay12200 = pmAutoB.observePlaybackProgress(true, true, true, 12200, 12000);
        boolean bPlay12300 = pmAutoB.observePlaybackProgress(true, true, true, 12300, 12000);
        WatchHistory.Entry migrated12300 = WatchHistory.cloneEntry(oldJia);
        migrated12300.site = "src_backup";
        migrated12300.id = "vid_jia_backup";
        migrated12300.position = 12300;
        String afterCase1 = WatchHistory.upsertAndMigrate(baseHist, migrated12300, pmAutoB.oldKey);
        List<WatchHistory.Entry> case1List = WatchHistory.read(afterCase1);
        check(
                "Case 1B: Delayed auto-resume reset from 35ms -> 12000ms keeps old bookmark until"
                        + " 12300ms then migrates cleanly",
                !bPreSeek35
                        && !bStale35
                        && !bLanded12000
                        && !bPlay12200
                        && bPlay12300
                        && case1List.size() == 1
                        && "src_backup\nvid_jia_backup".equals(case1List.get(0).key())
                        && case1List.get(0).position == 12300);

        // Case 2: Manual remote fast-forward 12000ms -> 27000ms -> natural play to 27300ms
        WatchHistory.PendingMigration pmManual =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        boolean mLanded12000 = pmManual.observePlaybackProgress(true, true, true, 12000, 12000);
        // User fast-forwards +15s before natural playback reaches 12250ms
        pmManual.resetProgressBaselineForSeek(27000, 12000);
        boolean mStale12050 = pmManual.observePlaybackProgress(true, true, true, 12050, 27000);
        boolean mLanded27000 = pmManual.observePlaybackProgress(true, true, true, 27000, 27000);
        boolean mPlay27200 = pmManual.observePlaybackProgress(true, true, true, 27200, 27000);
        boolean mPlay27300 = pmManual.observePlaybackProgress(true, true, true, 27300, 27000);
        WatchHistory.Entry migrated27300 = WatchHistory.cloneEntry(migrated12300);
        migrated27300.position = 27300;
        String afterCase2 = WatchHistory.upsertAndMigrate(baseHist, migrated27300, pmManual.oldKey);
        List<WatchHistory.Entry> case2List = WatchHistory.read(afterCase2);
        check(
                "Case 2: Manual fast-forward 12000ms -> 27000ms resets baseline and migrates only"
                        + " after natural playback reaches 27300ms",
                !mLanded12000
                        && !mStale12050
                        && !mLanded27000
                        && !mPlay27200
                        && mPlay27300
                        && case2List.size() == 1
                        && "src_backup\nvid_jia_backup".equals(case2List.get(0).key())
                        && case2List.get(0).position == 27300);

        // Backward rewind 12000ms -> 3000ms -> 3150ms -> 3300ms also resets cleanly without
        // stale-position lockup
        WatchHistory.PendingMigration pmRewind =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmRewind.observePlaybackProgress(true, true, true, 12000, 12000, false, false, 1000L);
        pmRewind.resetProgressBaselineForSeek(3000, 12000);
        boolean rStale12050 =
                pmRewind.observePlaybackProgress(
                        true, true, true, 12050, 3000, false, false, 1100L);
        boolean rLanded3000 =
                pmRewind.observePlaybackProgress(true, true, true, 3000, 3000, false, false, 1200L);
        boolean rPlay3150 =
                pmRewind.observePlaybackProgress(true, true, true, 3150, 3000, false, false, 1350L);
        boolean rPlay3300 =
                pmRewind.observePlaybackProgress(true, true, true, 3300, 3000, false, false, 1500L);
        check(
                "Backward rewind 12000ms -> 3000ms ignores pre-seek 12050ms and confirms after"
                        + " consecutive natural play to 3300ms",
                !rStale12050
                        && !rLanded3000
                        && !rPlay3150
                        && rPlay3300
                        && pmRewind.isProgressConfirmed());

        // Short-distance forward seek (12000ms -> 13500ms, jump < 2000ms): late pre-seek 12000ms
        // must NOT be mistaken for seek landing; landing at 13500ms keeps old bookmark; natural
        // play to 13750ms (+250ms) commits migration cleanly. Also test 1-arg reset overload!
        WatchHistory.PendingMigration pmShortFwd =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        boolean sfBefore = pmShortFwd.observePlaybackProgress(true, true, true, 12000, 12000);
        pmShortFwd.resetProgressBaselineForSeek(13500, 12000);
        boolean sfLate12000 = pmShortFwd.observePlaybackProgress(true, true, true, 12000, 13500);
        boolean sfLanded13500 = pmShortFwd.observePlaybackProgress(true, true, true, 13500, 13500);
        boolean sfPlay13749 = pmShortFwd.observePlaybackProgress(true, true, true, 13749, 13500);
        boolean sfPlay13750 = pmShortFwd.observePlaybackProgress(true, true, true, 13750, 13500);
        WatchHistory.Entry migrated13750 = WatchHistory.cloneEntry(migrated12300);
        migrated13750.position = 13750;
        String afterShortFwd =
                WatchHistory.upsertAndMigrate(baseHist, migrated13750, pmShortFwd.oldKey);
        List<WatchHistory.Entry> shortFwdList = WatchHistory.read(afterShortFwd);
        check(
                "Short forward seek 12000ms -> 13500ms rejects late 12000ms, keeps old bookmark at"
                        + " 13500ms, and migrates only at >= 13750ms",
                !sfBefore
                        && !sfLate12000
                        && !sfLanded13500
                        && !sfPlay13749
                        && sfPlay13750
                        && pmShortFwd.isProgressConfirmed()
                        && shortFwdList.size() == 1
                        && "src_backup\nvid_jia_backup".equals(shortFwdList.get(0).key())
                        && shortFwdList.get(0).position == 13750);

        // Short forward seek via 1-arg resetProgressBaselineForSeek(13500) + stall/exit/switch Yi
        WatchHistory.PendingMigration pmShortStall =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmShortStall.observePlaybackProgress(true, true, true, 12000, 12000);
        pmShortStall.resetProgressBaselineForSeek(13500);
        boolean ssLate12000 = pmShortStall.observePlaybackProgress(true, true, true, 12000, 13500);
        boolean ssLanded13500 =
                pmShortStall.observePlaybackProgress(true, true, true, 13500, 13500);
        boolean ssFrozen13500 =
                pmShortStall.observePlaybackProgress(true, true, true, 13500, 13500);
        boolean ssBuffering13500 =
                pmShortStall.observePlaybackProgress(true, true, false, 13500, 13500);
        WatchHistory.Entry shortYi = new WatchHistory.Entry();
        shortYi.site = "src_backup";
        shortYi.id = "vid_yi_short";
        shortYi.title = "测试剧乙";
        shortYi.episode = "第1集";
        shortYi.position = 1500;
        shortYi.duration = 45000;
        shortYi.updated = 6000L;
        List<WatchHistory.Entry> afterShortStallYi =
                WatchHistory.read(WatchHistory.upsert(baseHist, shortYi));
        WatchHistory.Entry shortPreservedJia = null;
        WatchHistory.Entry shortSavedYi = null;
        WatchHistory.Entry shortStrayBackup = null;
        for (WatchHistory.Entry e : afterShortStallYi) {
            if (oldJia.key().equals(e.key())) shortPreservedJia = e;
            if (shortYi.key().equals(e.key())) shortSavedYi = e;
            if ("src_backup\nvid_jia_backup".equals(e.key())) shortStrayBackup = e;
        }
        check(
                "Short forward seek 12000ms -> 13500ms stalling/exiting/switching to 《乙》"
                        + " preserves original 《甲》 Ep 8 @ 12000ms",
                !ssLate12000
                        && !ssLanded13500
                        && !ssFrozen13500
                        && !ssBuffering13500
                        && !pmShortStall.isProgressConfirmed()
                        && shortPreservedJia != null
                        && "第8集".equals(shortPreservedJia.episode)
                        && shortPreservedJia.position == 12000
                        && shortSavedYi != null
                        && shortStrayBackup == null);

        // Short backward seek (13500ms -> 12000ms, jump < 2000ms): rejects late 13500ms, settles at
        // 12000ms, confirms after consecutive natural play to 12250ms
        WatchHistory.PendingMigration pmShortBack =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmShortBack.observePlaybackProgress(true, true, true, 13500, 13500, false, false, 1000L);
        pmShortBack.resetProgressBaselineForSeek(12000, 13500);
        boolean sbLate13500 =
                pmShortBack.observePlaybackProgress(
                        true, true, true, 13500, 12000, false, false, 1100L);
        boolean sbLanded12000 =
                pmShortBack.observePlaybackProgress(
                        true, true, true, 12000, 12000, false, false, 1200L);
        boolean sbPlay12120 =
                pmShortBack.observePlaybackProgress(
                        true, true, true, 12120, 12000, false, false, 1320L);
        boolean sbPlay12250 =
                pmShortBack.observePlaybackProgress(
                        true, true, true, 12250, 12000, false, false, 1450L);
        check(
                "Short backward seek 13500ms -> 12000ms rejects late 13500ms and confirms after"
                        + " consecutive natural play to 12250ms",
                !sbLate13500
                        && !sbLanded12000
                        && !sbPlay12120
                        && sbPlay12250
                        && pmShortBack.isProgressConfirmed());

        // RC Counterexample 1 (out-of-order backward seek, no kernel seek-complete signal):
        // 13500ms -> 12000ms where target 12000ms arrives FIRST (e.g. MPV optimistic positionSec),
        // then late pre-seek 13500ms arrives (both fast +100ms AND slow +1500ms) -> MUST NOT
        // confirm migration without real post-landing natural playback!
        WatchHistory.PendingMigration pmOutOfOrderBackFast =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmOutOfOrderBackFast.observePlaybackProgress(
                true, true, true, 13500, 13500, false, false, 1000L);
        pmOutOfOrderBackFast.resetProgressBaselineForSeek(12000, 13500);
        boolean oobTarget12000 =
                pmOutOfOrderBackFast.observePlaybackProgress(
                        true, true, true, 12000, 12000, false, false, 1050L);
        boolean oobLate13500Fast =
                pmOutOfOrderBackFast.observePlaybackProgress(
                        true, true, true, 13500, 12000, false, false, 1150L);
        boolean oobLate13500Slow =
                pmOutOfOrderBackFast.observePlaybackProgress(
                        true, true, true, 13500, 12000, false, false, 2600L);
        // Legacy 5-arg overload must also reject the exact same out-of-order backward sequence
        WatchHistory.PendingMigration pmOutOfOrderBackLegacy =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmOutOfOrderBackLegacy.observePlaybackProgress(true, true, true, 13500, 13500);
        pmOutOfOrderBackLegacy.resetProgressBaselineForSeek(12000, 13500);
        boolean oobLegTarget =
                pmOutOfOrderBackLegacy.observePlaybackProgress(true, true, true, 12000, 12000);
        boolean oobLegLate =
                pmOutOfOrderBackLegacy.observePlaybackProgress(true, true, true, 13500, 12000);
        // Only genuine consecutive post-landing natural playback confirms migration
        boolean oobNatural1 =
                pmOutOfOrderBackFast.observePlaybackProgress(
                        true, true, true, 12150, 12000, false, false, 2750L);
        boolean oobNatural2 =
                pmOutOfOrderBackFast.observePlaybackProgress(
                        true, true, true, 12300, 12000, false, false, 2900L);
        check(
                "Out-of-order backward seek 13500->12000 (target 12000 first, then late 13500)"
                        + " never confirms without real consecutive post-landing playback",
                !oobTarget12000
                        && !oobLate13500Fast
                        && !oobLate13500Slow
                        && !oobLegTarget
                        && !oobLegLate
                        && !pmOutOfOrderBackLegacy.isProgressConfirmed()
                        && !oobNatural1
                        && oobNatural2
                        && pmOutOfOrderBackFast.isProgressConfirmed());

        // RC Counterexample 2 (out-of-order forward seek, no kernel seek-complete signal):
        // 12000ms -> 13500ms where target 13500ms arrives FIRST, then stale pre-seek 12000ms
        // arrives, then the same target 13500ms arrives again -> stale 12000ms MUST NOT pull
        // the baseline backward and the repeated 13500ms MUST NOT confirm migration!
        WatchHistory.PendingMigration pmOutOfOrderFwd =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmOutOfOrderFwd.observePlaybackProgress(
                true, true, true, 12000, 12000, false, false, 1000L);
        pmOutOfOrderFwd.resetProgressBaselineForSeek(13500, 12000);
        boolean oofTargetFirst =
                pmOutOfOrderFwd.observePlaybackProgress(
                        true, true, true, 13500, 13500, false, false, 1050L);
        boolean oofStale12000 =
                pmOutOfOrderFwd.observePlaybackProgress(
                        true, true, true, 12000, 13500, false, false, 1150L);
        boolean oofTargetAgain =
                pmOutOfOrderFwd.observePlaybackProgress(
                        true, true, true, 13500, 13500, false, false, 1400L);
        // Legacy 5-arg overload must also reject the exact same out-of-order forward sequence
        WatchHistory.PendingMigration pmOutOfOrderFwdLegacy =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmOutOfOrderFwdLegacy.observePlaybackProgress(true, true, true, 12000, 12000);
        pmOutOfOrderFwdLegacy.resetProgressBaselineForSeek(13500, 12000);
        boolean oofLeg1 =
                pmOutOfOrderFwdLegacy.observePlaybackProgress(true, true, true, 13500, 13500);
        boolean oofLeg2 =
                pmOutOfOrderFwdLegacy.observePlaybackProgress(true, true, true, 12000, 13500);
        boolean oofLeg3 =
                pmOutOfOrderFwdLegacy.observePlaybackProgress(true, true, true, 13500, 13500);
        // Only genuine consecutive post-landing natural playback confirms migration
        boolean oofNatural1 =
                pmOutOfOrderFwd.observePlaybackProgress(
                        true, true, true, 13650, 13500, false, false, 1550L);
        boolean oofNatural2 =
                pmOutOfOrderFwd.observePlaybackProgress(
                        true, true, true, 13800, 13500, false, false, 1700L);
        check(
                "Out-of-order forward seek 12000->13500 (target 13500, stale 12000, target 13500)"
                        + " never pulls baseline back or confirms without real natural playback",
                !oofTargetFirst
                        && !oofStale12000
                        && !oofTargetAgain
                        && !oofLeg1
                        && !oofLeg2
                        && !oofLeg3
                        && !pmOutOfOrderFwdLegacy.isProgressConfirmed()
                        && !oofNatural1
                        && oofNatural2
                        && pmOutOfOrderFwd.isProgressConfirmed());

        // Kernel-confirmed seek signal path (Media3 / SystemPlayer / MPV):
        // While seekInFlight==true, optimistic target & stale pre-seek values are ignored;
        // once seekInFlight==false (seek confirmed), landing is separated from credible advance
        // so consecutive paced post-landing samples >= 250ms confirm migration cleanly.
        WatchHistory.PendingMigration pmConfirmed =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmConfirmed.observePlaybackProgress(true, true, true, 13500, 13500, true, false, 1000L);
        pmConfirmed.syncPlayerSeekGeneration(1L, 12000, 13500);
        boolean cfInFlightTarget =
                pmConfirmed.observePlaybackProgress(
                        true, true, true, 12000, 12000, true, true, 1050L);
        boolean cfInFlightLate =
                pmConfirmed.observePlaybackProgress(
                        true, true, true, 13500, 12000, true, true, 1100L);
        boolean cfConfirmedLanding =
                pmConfirmed.observePlaybackProgress(
                        true, true, true, 12000, 12000, true, false, 1200L);
        // Impossible 10ms jump after confirmed landing still rejected by wall-clock & pre-seek
        // guard
        boolean cfImpossibleSpike =
                pmConfirmed.observePlaybackProgress(
                        true, true, true, 13500, 12000, true, false, 1210L);
        // Real consecutive playback (150ms + 150ms = 300ms in 300ms wall time) confirms cleanly
        boolean cfRealPlay1 =
                pmConfirmed.observePlaybackProgress(
                        true, true, true, 12150, 12000, true, false, 1350L);
        boolean cfRealPlay2 =
                pmConfirmed.observePlaybackProgress(
                        true, true, true, 12300, 12000, true, false, 1500L);
        check(
                "Kernel seek-completion signal blocks in-flight optimistic/late readings and"
                        + " separates landing from consecutive real playback",
                !cfInFlightTarget
                        && !cfInFlightLate
                        && !cfConfirmedLanding
                        && !cfImpossibleSpike
                        && !cfRealPlay1
                        && cfRealPlay2
                        && pmConfirmed.isProgressConfirmed());

        // Section 4.1 regression: 1.0x backward seek 13500ms -> 12000ms with kernel confirmation.
        // After landing at 12000ms (t=1000ms), sending ONLY ONE stale pre-seek reading 13500ms at
        // +799ms (1799ms), +800ms (1800ms), or +1000ms (2000ms) MUST NOT confirm migration, and
        // persisted WatchHistory must keep original 《甲》 untouched; genuine continuous playback
        // after landing (both 500ms and 1000ms callback cadence, or after a rejected stale reading)
        // must still confirm and migrate cleanly.
        final int[] staleDelaysMs = new int[] {799, 800, 1000};
        boolean allStaleSingleReadingsBlocked = true;
        boolean allPersistedOriginalsIntact = true;
        for (int delayMs : staleDelaysMs) {
            final String[] persistedJson = new String[] {baseHist};
            WatchHistory.Persistence diskStore =
                    new WatchHistory.Persistence() {
                        public String readRaw() {
                            return persistedJson[0];
                        }

                        public boolean readCorruptedPref() {
                            return false;
                        }

                        public void writeState(String historyJson, boolean corrupted) {
                            persistedJson[0] = historyJson;
                        }
                    };
            WatchHistory.PendingMigration pmLateConfirmed =
                    new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
            pmLateConfirmed.observePlaybackProgress(
                    true, true, true, 13500, 13500, true, false, 1.0f, 500L);
            pmLateConfirmed.syncPlayerSeekGeneration(1L, 12000, 13500);
            boolean landed12000 =
                    pmLateConfirmed.observePlaybackProgress(
                            true, true, true, 12000, 12000, true, false, 1.0f, 1000L);
            boolean singleStale13500 =
                    pmLateConfirmed.observePlaybackProgress(
                            true, true, true, 13500, 12000, true, false, 1.0f, 1000L + delayMs);
            if (pmLateConfirmed.isProgressConfirmed()) {
                WatchHistory.Entry badMigrated = WatchHistory.cloneEntry(oldJia);
                badMigrated.site = "src_backup";
                badMigrated.id = "vid_jia_backup";
                badMigrated.position = 13500;
                WatchHistory.enqueueUpsertAndMigrate(diskStore, badMigrated, pmLateConfirmed.oldKey)
                        .get();
            }
            List<WatchHistory.Entry> afterStale = WatchHistory.read(diskStore.readRaw());
            boolean originalStillPresent =
                    afterStale.size() == 1
                            && oldJia.key().equals(afterStale.get(0).key())
                            && "第8集".equals(afterStale.get(0).episode)
                            && afterStale.get(0).position == 12000;
            if (landed12000 || singleStale13500 || pmLateConfirmed.isProgressConfirmed()) {
                allStaleSingleReadingsBlocked = false;
            }
            if (!originalStillPresent) {
                allPersistedOriginalsIntact = false;
            }
        }
        // Positive continuous-playback verification after confirmed 13500 -> 12000 backward seek:
        // (a) 500ms cadence after a rejected +800ms stale 13500 reading
        final String[] persistedPosA = new String[] {baseHist};
        WatchHistory.Persistence diskPosA =
                new WatchHistory.Persistence() {
                    public String readRaw() {
                        return persistedPosA[0];
                    }

                    public boolean readCorruptedPref() {
                        return false;
                    }

                    public void writeState(String historyJson, boolean corrupted) {
                        persistedPosA[0] = historyJson;
                    }
                };
        WatchHistory.PendingMigration pmRecoverAfterStale =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmRecoverAfterStale.observePlaybackProgress(
                true, true, true, 13500, 13500, true, false, 1.0f, 500L);
        pmRecoverAfterStale.syncPlayerSeekGeneration(1L, 12000, 13500);
        boolean recLanded =
                pmRecoverAfterStale.observePlaybackProgress(
                        true, true, true, 12000, 12000, true, false, 1.0f, 1000L);
        boolean recStale800 =
                pmRecoverAfterStale.observePlaybackProgress(
                        true, true, true, 13500, 12000, true, false, 1.0f, 1800L);
        boolean recStep1 =
                pmRecoverAfterStale.observePlaybackProgress(
                        true, true, true, 12500, 12000, true, false, 1.0f, 2000L);
        boolean recStep2 =
                pmRecoverAfterStale.observePlaybackProgress(
                        true, true, true, 13000, 12000, true, false, 1.0f, 2500L);
        if (pmRecoverAfterStale.isProgressConfirmed()) {
            WatchHistory.Entry migratedOk = WatchHistory.cloneEntry(oldJia);
            migratedOk.site = "src_backup";
            migratedOk.id = "vid_jia_backup";
            migratedOk.position = 13000;
            WatchHistory.enqueueUpsertAndMigrate(diskPosA, migratedOk, pmRecoverAfterStale.oldKey)
                    .get();
        }
        List<WatchHistory.Entry> migratedListA = WatchHistory.read(diskPosA.readRaw());
        // (b) 1Hz production callback cadence: 12000@1000 -> 13000@2000 -> 14000@3000
        WatchHistory.PendingMigration pmOneHz =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmOneHz.observePlaybackProgress(true, true, true, 13500, 13500, true, false, 1.0f, 500L);
        pmOneHz.syncPlayerSeekGeneration(1L, 12000, 13500);
        boolean oneHzLand =
                pmOneHz.observePlaybackProgress(
                        true, true, true, 12000, 12000, true, false, 1.0f, 1000L);
        boolean oneHzStep1 =
                pmOneHz.observePlaybackProgress(
                        true, true, true, 13000, 12000, true, false, 1.0f, 2000L);
        boolean oneHzStep2 =
                pmOneHz.observePlaybackProgress(
                        true, true, true, 14000, 12000, true, false, 1.0f, 3000L);
        check(
                "Confirmed backward seek 13500->12000 rejects single stale 13500 at +799/+800/+1000ms"
                        + " preserving persisted original 《甲》, while continuous post-landing"
                        + " playback still migrates",
                allStaleSingleReadingsBlocked
                        && allPersistedOriginalsIntact
                        && !recLanded
                        && !recStale800
                        && !recStep1
                        && recStep2
                        && pmRecoverAfterStale.isProgressConfirmed()
                        && migratedListA.size() == 1
                        && "src_backup\nvid_jia_backup".equals(migratedListA.get(0).key())
                        && migratedListA.get(0).position == 13000
                        && !oneHzLand
                        && !oneHzStep1
                        && oneHzStep2
                        && pmOneHz.isProgressConfirmed());

        // Playback rate consistency (2.0x speed advances +250ms per 125ms wall time -> valid!)
        WatchHistory.PendingMigration pmFastRate =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmFastRate.observePlaybackProgress(
                true, true, true, 12000, 12000, true, false, 2.0f, 1000L);
        boolean frStep1 =
                pmFastRate.observePlaybackProgress(
                        true, true, true, 12250, 12000, true, false, 2.0f, 1125L);
        boolean frStep2 =
                pmFastRate.observePlaybackProgress(
                        true, true, true, 12500, 12000, true, false, 2.0f, 1250L);
        check("2.0x playback speed satisfies wall-clock consistency", !frStep1 && frStep2);

        // Case 3: Immediately stall, exit, or switch to 《乙》 after seek -> old 《甲》 preserved!
        WatchHistory.PendingMigration pmStall =
                new WatchHistory.PendingMigration(oldJia.key(), "src_backup", "vid_jia_backup");
        pmStall.observePlaybackProgress(true, true, true, 12000, 12000);
        pmStall.resetProgressBaselineForSeek(27000, 12000);
        boolean sLanded27000 = pmStall.observePlaybackProgress(true, true, true, 27000, 27000);
        boolean sStalledFrozen = pmStall.observePlaybackProgress(true, true, true, 27000, 27000);
        boolean sBuffering = pmStall.observePlaybackProgress(true, true, false, 27000, 27000);
        WatchHistory.Entry videoYi = new WatchHistory.Entry();
        videoYi.site = "src_backup";
        videoYi.id = "vid_yi";
        videoYi.title = "测试剧乙";
        videoYi.episode = "第1集";
        videoYi.position = 1500;
        videoYi.duration = 45000;
        videoYi.updated = 5000L;
        String afterStallSwitch = WatchHistory.upsert(baseHist, videoYi);
        List<WatchHistory.Entry> case3List = WatchHistory.read(afterStallSwitch);
        WatchHistory.Entry preservedJia = null;
        WatchHistory.Entry savedYi = null;
        WatchHistory.Entry strayBackup = null;
        for (WatchHistory.Entry e : case3List) {
            if (oldJia.key().equals(e.key())) preservedJia = e;
            if (videoYi.key().equals(e.key())) savedYi = e;
            if ("src_backup\nvid_jia_backup".equals(e.key())) strayBackup = e;
        }
        check(
                "Case 3: Stalling, exiting, or switching to 《乙》 immediately after seek preserves"
                        + " original 《甲》 Ep 8 @ 12000ms with no stray backup entry",
                !sLanded27000
                        && !sStalledFrozen
                        && !sBuffering
                        && !pmStall.isProgressConfirmed()
                        && preservedJia != null
                        && "第8集".equals(preservedJia.episode)
                        && preservedJia.position == 12000
                        && savedYi != null
                        && strayBackup == null);

        // Production seek-reset and kernel seek-completion wiring checks
        String ctrlSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackController.java");
        String controlsSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/PlaybackControls.java");
        String movieSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MoviePlayer.java");
        String sysSrc =
                readSrc("android-tv/src/main/java/com/pilipala/marcomovie/SystemPlayer.java");
        String mpvSrc = readSrc("android-tv/src/main/java/com/pilipala/marcomovie/MpvPlayer.java");
        int finishIdx = ctrlSrc.indexOf("static void finishSeek(");
        String finishBody = finishIdx >= 0 ? ctrlSrc.substring(finishIdx, finishIdx + 700) : "";
        int recIdx = controlsSrc.indexOf("void recordUserSeek(");
        String recBody = recIdx >= 0 ? controlsSrc.substring(recIdx, recIdx + 300) : "";
        check(
                "Production finishSeek syncs recordUserSeek (preventing stale displayPosition"
                        + " override) and resets PendingMigration before player.seekTo",
                finishBody.indexOf("a.playbackControls.recordUserSeek(target);") >= 0
                        && finishBody.indexOf("notifyPendingHistoryMigrationSeek(a, target);") >= 0
                        && finishBody.indexOf("a.player.seekTo(target);")
                                > finishBody.indexOf("a.playbackControls.recordUserSeek(target);")
                        && recBody.contains(
                                "PlaybackController.notifyPendingHistoryMigrationSeek("));
        check(
                "displayPosition holds stale pre-seek values but never snaps natural post-seek"
                        + " playback (+2527ms in 2527ms) backwards to seek target",
                PlaybackControls.shouldHoldSeekTargetPosition(35, 12000, 100L, true)
                        && PlaybackControls.shouldHoldSeekTargetPosition(27000, 12000, 100L, false)
                        && !PlaybackControls.shouldHoldSeekTargetPosition(
                                14527, 12000, 2527L, false)
                        && !PlaybackControls.shouldHoldSeekTargetPosition(
                                12500, 12000, 500L, false));
        check(
                "Production player kernels wire seek-completion signals and monotonic clock into"
                        + " PendingMigration",
                movieSrc.contains("confirmSeekCompleted(exoPendingSeekGen)")
                        && movieSrc.contains("boolean isSeekInFlight()")
                        && sysSrc.contains("confirmSeekCompleted(systemPendingSeekGen)")
                        && mpvSrc.contains("MPVLib.MPV_EVENT_SEEK")
                        && mpvSrc.contains("MPVLib.MPV_EVENT_PLAYBACK_RESTART")
                        && mpvSrc.contains("MPVLib.observeProperty(\"seeking\"")
                        && mpvSrc.contains("confirmSeekCompleted(pendingGen)")
                        && ctrlSrc.contains("a.pendingHistoryMigration.syncPlayerSeekGeneration(")
                        && ctrlSrc.contains("a.player.isSeekInFlight()")
                        && ctrlSrc.contains("SystemClock.elapsedRealtime()"));
    }
}

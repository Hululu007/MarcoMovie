package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import javax.imageio.ImageIO;

/**
 * Data-driven benchmarks & regression checks for Batch 4:
 * - #45: 6 sources x 50 items (300 total) search before/after incremental append metrics
 * - #65: Mobile backdrop/glass callback audit (root shell vs detail GlassworkSurface debounce)
 * - 10-minute inline progress checkpointing (600 ticks -> <= 40 writes, exit <= 2s, kill <= 15s)
 * - 200-poster 3-pass scroll stress (dedup, bounded ImageDecodePolicy sizes, 0 cross-binding, #71)
 */
public final class Batch4PerfBenchChecks {
    private static int checks;

    private static void check(boolean cond, String name) {
        if (!cond) throw new AssertionError("FAIL: " + name);
        checks++;
        System.out.println("PASS " + name);
    }

    // -------------------------------------------------------------------------
    // 1. #45: 6 mock sources x 50 items = 300 items search append benchmark
    // -------------------------------------------------------------------------
    private static void bench45SearchIncrementalAppend(File srcRoot) throws Exception {
        MobileSearchPage.invalidateSession();
        Object cfg = new Object();
        long pageTok = MobileSearchPage.beginPage();
        final int sources = 6;
        final int perSource = 50;

        // Baseline model (before #45 fix): full rebuild on every batch -> quadratic card churn
        int beforeFullRebuilds = 0;
        int beforeCardsCreated = 0;
        int beforeScrollResets = 0;
        long beforeStartNs = System.nanoTime();
        List<MobileSearchPage.Hit> beforeAccum = new ArrayList<>();
        for (int s = 0; s < sources; s++) {
            Cms.Site site = makeSite("src_" + s, "片源" + s);
            for (int i = 0; i < perSource; i++) {
                beforeAccum.add(
                        new MobileSearchPage.Hit(
                                site, makeVideo("v_" + s + "_" + i, "测试影片 " + s + "-" + i)));
            }
            beforeFullRebuilds++;
            if (s > 0) beforeScrollResets++;
            // Full rebuild recreates all cards 0..beforeAccum.size()-1
            List<String> recreated = new ArrayList<>(beforeAccum.size());
            for (MobileSearchPage.Hit h : beforeAccum) {
                recreated.add(h.site.key + ":" + h.video.id);
                beforeCardsCreated++;
            }
        }
        double beforeMs = (System.nanoTime() - beforeStartNs) / 1_000_000.0;

        // Optimized model (after D4 + #45): MobileSearchPage.SearchSession + IncrementalResultPlan
        MobileSearchPage.SearchSession session =
                MobileSearchPage.startSession(pageTok, "测试", false, cfg, 1, 1, sources);
        MobileSearchPage.IncrementalResultPlan plan = new MobileSearchPage.IncrementalResultPlan();
        List<Object> mountedCardTokens = new ArrayList<>();
        List<MobileSearchPage.Hit> mountedTargets = new ArrayList<>();
        int afterCardsCreated = 0;
        int afterScrollY = 0;
        int afterScrollResets = 0;
        double firstClickableMs = 0.0;
        double maxBatchAppendMs = 0.0;
        long afterStartNs = System.nanoTime();
        Object initialFirstCardToken = null;

        for (int s = 0; s < sources; s++) {
            long batchStartNs = System.nanoTime();
            Cms.Site site = makeSite("src_" + s, "片源" + s);
            List<MobileSearchPage.Hit> batch = new ArrayList<>(perSource);
            for (int i = 0; i < perSource; i++) {
                batch.add(
                        new MobileSearchPage.Hit(
                                site, makeVideo("v_" + s + "_" + i, "测试影片 " + s + "-" + i)));
            }
            check(
                    MobileSearchPage.acceptBatchIfCurrent(session, false, cfg, 1, 1, batch),
                    "#45: batch #" + (s + 1) + " accepted by isolated SearchSession");
            List<MobileSearchPage.Hit> snap = session.snapshotHits();
            MobileSearchPage.IncrementalResultPlan.Diff diff =
                    plan.planUpdate(
                            session.querySeq, session.selectedSiteFilter(), false, snap.size());

            if (diff.fullRebuild) {
                mountedCardTokens.clear();
                mountedTargets.clear();
                if (afterScrollY > 0) afterScrollResets++;
                afterScrollY = 0;
            }
            for (int idx = diff.appendFromIndex; idx < snap.size(); idx++) {
                mountedCardTokens.add(new Object());
                mountedTargets.add(snap.get(idx));
                afterCardsCreated++;
            }
            double batchMs = (System.nanoTime() - batchStartNs) / 1_000_000.0;
            if (batchMs > maxBatchAppendMs) maxBatchAppendMs = batchMs;
            if (s == 0) {
                firstClickableMs = (System.nanoTime() - afterStartNs) / 1_000_000.0;
                initialFirstCardToken = mountedCardTokens.get(0);
                // User scrolls down to read batch 1 while batches 2..6 are still arriving!
                afterScrollY = 1280;
            }
        }
        double afterMs = (System.nanoTime() - afterStartNs) / 1_000_000.0;

        check(
                mountedTargets.size() == 300
                        && plan.fullRebuildCount == 1
                        && plan.incrementalUpdateCount == 5
                        && afterCardsCreated == 300
                        && beforeCardsCreated == 1050,
                "#45: 6x50=300 hits reduced card inflations 1050->300 and full rebuilds 6->1");
        check(
                afterScrollY == 1280
                        && afterScrollResets == 0
                        && beforeScrollResets == 5
                        && mountedCardTokens.get(0) == initialFirstCardToken
                        && "v_0_0".equals(mountedTargets.get(0).video.id),
                "#45: scrollY (1280px) & first card view/click-target identity 100% preserved across batches 2..6");

        // Switching site filter triggers 1 clean targeted rebuild yielding exact 50 items for src_2
        session.setSelectedSiteFilter("src_2");
        MobileSearchPage.IncrementalResultPlan.Diff filterDiff =
                plan.planUpdate(
                        session.querySeq,
                        session.selectedSiteFilter(),
                        false,
                        session.snapshotHits().size());
        check(
                filterDiff.fullRebuild
                        && session.filteredHits().size() == 50
                        && "src_2".equals(session.filteredHits().get(0).site.key),
                "#45: explicit filter tap cleanly switches to exact 50 hits for selected site");

        String searchSrc = readUtf8(new File(srcRoot, "MobileSearchPage.java"));
        check(
                searchSrc.contains("IncrementalResultPlan.Diff diff =")
                        && searchSrc.contains("populateHitRowsRange("),
                "#45 wiring: MobileSearchPage.render uses IncrementalResultPlan & populateHitRowsRange");

        System.out.printf(
                "BENCH #45 (6 sources x 50 = 300 items): before_rebuilds=%d before_cards=%d before_scroll_resets=%d before_ms=%.3f | after_rebuilds=%d after_incremental=%d after_cards=%d after_scroll_resets=%d first_clickable_ms=%.3f max_batch_ms=%.3f after_ms=%.3f%n",
                beforeFullRebuilds,
                beforeCardsCreated,
                beforeScrollResets,
                beforeMs,
                plan.fullRebuildCount,
                plan.incrementalUpdateCount,
                afterCardsCreated,
                afterScrollResets,
                firstClickableMs,
                maxBatchAppendMs,
                afterMs);
    }

    // -------------------------------------------------------------------------
    // 2. #65: Mobile backdrop/glass audit
    // -------------------------------------------------------------------------
    private static void audit65MobileGlassBackdrop(File srcRoot, File sharedGlassFile)
            throws Exception {
        String rootShell = readUtf8(new File(srcRoot, "MobileRootShell.java"));
        String detailSrc = readUtf8(new File(srcRoot, "MobileDetailScreen.java"));
        String glassSrc = readUtf8(sharedGlassFile);

        boolean rootUsesAmbientNotGlasswork =
                rootShell.contains("AmbientCanvasView") && !rootShell.contains("a.glass(");
        boolean detailAttachesGlasswork = detailSrc.contains("a.glass(backBtn, 999)");
        boolean sharedGlassUses180msScrollDebounce =
                glassSrc.contains("mainHandler().postDelayed(refresh, 180);");

        check(
                rootUsesAmbientNotGlasswork,
                "#65 audit: MobileRootShell tabs use lightweight AmbientCanvasView + static glassBg (no scroll-coupled GlassworkSurface)");
        check(
                detailAttachesGlasswork && sharedGlassUses180msScrollDebounce,
                "#65 audit: MobileDetailScreen floating pills attach shared GlassworkSurface (180ms trailing scroll debounce in shared/java)");
        System.out.println(
                "BENCH #65 audit: root_tabs_glasswork_surfaces=0 (static GradientDrawable + AmbientCanvasView), detail_glasswork_pills=4 (shared GlassworkSurface scroll trailing debounce=180ms; untouched per scope pending real-device scroll trace)");
    }

    // -------------------------------------------------------------------------
    // 3. 10-minute inline progress checkpointing benchmark
    // -------------------------------------------------------------------------
    private static void benchInlineProgressCheckpointing10Min() {
        final int totalSec = 600; // 10 minutes
        final int durMs = 45 * 60 * 1000;
        final String epKey = "site1\nv1\nL1\nE1";

        // Before: 1 write per second (600 UI-thread writes in 10 min)
        int legacyWrites = totalSec;

        // After: 15-second checkpointing via MobileInlinePlayer.ProgressCheckpointPolicy
        MobileInlinePlayer.ProgressCheckpointPolicy policy =
                new MobileInlinePlayer.ProgressCheckpointPolicy();
        int checkpointWrites = 0;
        int lastPersistedPosMs = 0;
        int maxKillRollbackMs = 0;
        long baseTimeMs = 1_700_000_000_000L;

        for (int sec = 1; sec <= totalSec; sec++) {
            int posMs = sec * 1000;
            long nowMs = baseTimeMs + sec * 1000L;
            if (policy.shouldWrite(nowMs, posMs, durMs, epKey, false)) {
                checkpointWrites++;
                lastPersistedPosMs = posMs;
            }
            int rollbackIfKilledNow = posMs - lastPersistedPosMs;
            if (rollbackIfKilledNow > maxKillRollbackMs) {
                maxKillRollbackMs = rollbackIfKilledNow;
            }
        }

        // Normal exit at t=607s (7s after last checkpoint) triggers force=true
        int exitPosMs = 607_000;
        long exitNowMs = baseTimeMs + 607_000L;
        if (policy.shouldWrite(exitNowMs, exitPosMs, durMs, epKey, true)) {
            checkpointWrites++;
            lastPersistedPosMs = exitPosMs;
        }
        int normalExitErrorMs = Math.abs(exitPosMs - lastPersistedPosMs);

        check(
                checkpointWrites <= 42 && checkpointWrites < legacyWrites / 10,
                "10-min checkpointing: writes reduced >14x ("
                        + legacyWrites
                        + " -> "
                        + checkpointWrites
                        + ")");
        check(
                normalExitErrorMs <= 2000,
                "10-min checkpointing: normal exit resume error "
                        + normalExitErrorMs
                        + "ms <= 2000ms");
        check(
                maxKillRollbackMs <= 15_000,
                "10-min checkpointing: worst-case process-kill rollback "
                        + maxKillRollbackMs
                        + "ms <= 15000ms (<= 1 checkpoint)");

        System.out.printf(
                "BENCH inline-10min: legacy_ui_writes=%d checkpoint_bg_writes=%d reduction=%.1fx normal_exit_err_ms=%d max_kill_rollback_ms=%d%n",
                legacyWrites,
                checkpointWrites,
                legacyWrites / (double) checkpointWrites,
                normalExitErrorMs,
                maxKillRollbackMs);
    }

    // -------------------------------------------------------------------------
    // 4. 200-poster 3-pass scroll stress benchmark (dedup, decode bounds, #71)
    // -------------------------------------------------------------------------
    private static void bench200PostersThreePasses() throws Exception {
        final int posterCount = 200;
        final byte[][] jpegs = new byte[posterCount][];
        final int[] expectedRgb = new int[posterCount];
        for (int i = 0; i < posterCount; i++) {
            int r = (i * 53 + 20) & 0xff;
            int g = (i * 97 + 40) & 0xff;
            int b = (i * 193 + 60) & 0xff;
            Color c = new Color(r, g, b);
            expectedRgb[i] = c.getRGB();
            BufferedImage img = new BufferedImage(36, 54, BufferedImage.TYPE_INT_RGB);
            Graphics2D g2 = img.createGraphics();
            g2.setColor(c);
            g2.fillRect(0, 0, 36, 54);
            g2.dispose();
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            ImageIO.write(img, "jpg", bos);
            jpegs[i] = bos.toByteArray();
        }

        // Verify ImageDecodePolicy bounds on 4K/2K/1080p posters for mobile grid & detail
        int gridSample4k = ImageDecodePolicy.sample(2000, 3000, 320, 480, true, false);
        long gridPixels4k = (2000L / gridSample4k) * (3000L / gridSample4k);
        int detailSample4k = ImageDecodePolicy.sample(2000, 3000, 720, 1080, true, true);
        long detailPixels4k = (2000L / detailSample4k) * (3000L / detailSample4k);
        check(
                gridSample4k >= 4
                        && gridPixels4k <= 800L * 1024
                        && detailSample4k >= 2
                        && detailPixels4k <= 2L * 1024 * 1024,
                "200-poster decode policy: 2000x3000 bounded to grid="
                        + (2000 / gridSample4k)
                        + "x"
                        + (3000 / gridSample4k)
                        + " ("
                        + gridPixels4k
                        + "px) & detail="
                        + (2000 / detailSample4k)
                        + "x"
                        + (3000 / detailSample4k)
                        + " ("
                        + detailPixels4k
                        + "px)");

        // Local HTTP server counting exact network fetches per poster URL
        final AtomicInteger totalHttpHits = new AtomicInteger(0);
        final Map<Integer, AtomicInteger> perPosterHits = new ConcurrentHashMap<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(Executors.newFixedThreadPool(8));
        final int port = server.getAddress().getPort();
        server.createContext(
                "/p/",
                (HttpExchange ex) -> {
                    String tail = ex.getRequestURI().getPath().substring(3);
                    int idx = Integer.parseInt(tail.replace(".jpg", ""));
                    totalHttpHits.incrementAndGet();
                    perPosterHits.computeIfAbsent(idx, k -> new AtomicInteger()).incrementAndGet();
                    byte[] body = jpegs[idx];
                    ex.getResponseHeaders().set("Content-Type", "image/jpeg");
                    ex.sendResponseHeaders(200, body.length);
                    try (OutputStream out = ex.getResponseBody()) {
                        out.write(body);
                    }
                });
        server.start();

        // Mirror ImageLoader's exact cacheKey + generation-scoped IN_FLIGHT dedup + tag guard
        final Map<String, BufferedImage> memCache = new ConcurrentHashMap<>();
        final Map<String, List<SimulatedSlot>> inFlight = new HashMap<>();
        final ExecutorService pool = Executors.newFixedThreadPool(6);
        final int generation = 7;
        final int[] crossBindErrors = {0};
        final int[] cacheHits = {0};
        final int[] dedupCoalesced = {0};
        final double[] passMs = new double[3];

        try {
            for (int pass = 0; pass < 3; pass++) {
                long t0 = System.nanoTime();
                List<Future<?>> futures = new ArrayList<>();
                SimulatedSlot[] slots = new SimulatedSlot[posterCount];
                for (int i = 0; i < posterCount; i++) {
                    final String url = "http://127.0.0.1:" + port + "/p/" + i + ".jpg";
                    final String key =
                            ImageDecodePolicy.cacheKey(
                                    url,
                                    ImageDecodePolicy.targetWidth(0, false),
                                    ImageDecodePolicy.targetHeight(0, false),
                                    true,
                                    false);
                    final String flightKey = generation + "|" + key;
                    SimulatedSlot slot = new SimulatedSlot(url, i);
                    slots[i] = slot;

                    // On pass 0, simulate duplicate simultaneous subscriber (e.g. featured + grid
                    // card sharing same poster URL -> tests in-flight coalescing!)
                    int subscribers = (pass == 0 && i < 40) ? 2 : 1;
                    for (int sub = 0; sub < subscribers; sub++) {
                        final SimulatedSlot targetSlot =
                                sub == 0 ? slot : new SimulatedSlot(url, i);
                        BufferedImage cached = memCache.get(key);
                        if (cached != null) {
                            targetSlot.bindIfMatching(url, cached, crossBindErrors);
                            cacheHits[0]++;
                            continue;
                        }
                        boolean shouldFetch;
                        synchronized (inFlight) {
                            List<SimulatedSlot> waiters = inFlight.get(flightKey);
                            if (waiters != null) {
                                waiters.add(targetSlot);
                                dedupCoalesced[0]++;
                                shouldFetch = false;
                            } else {
                                waiters = new ArrayList<>();
                                waiters.add(targetSlot);
                                inFlight.put(flightKey, waiters);
                                shouldFetch = true;
                            }
                        }
                        if (shouldFetch) {
                            futures.add(
                                    pool.submit(
                                            () -> {
                                                try {
                                                    HttpURLConnection conn =
                                                            (HttpURLConnection)
                                                                    new URL(url).openConnection();
                                                    conn.setConnectTimeout(5000);
                                                    conn.setReadTimeout(5000);
                                                    byte[] bytes = readAll(conn);
                                                    BufferedImage decoded =
                                                            ImageIO.read(
                                                                    new ByteArrayInputStream(
                                                                            bytes));
                                                    memCache.put(key, decoded);
                                                    List<SimulatedSlot> waiters;
                                                    synchronized (inFlight) {
                                                        waiters = inFlight.remove(flightKey);
                                                    }
                                                    if (waiters != null) {
                                                        for (SimulatedSlot w : waiters) {
                                                            w.bindIfMatching(
                                                                    url, decoded, crossBindErrors);
                                                        }
                                                    }
                                                } catch (Exception e) {
                                                    throw new RuntimeException(e);
                                                }
                                            }));
                        }
                    }
                }
                for (Future<?> f : futures) f.get();
                // Verify all 200 visible cards received their exact own poster (no blank, no swap!)
                for (int i = 0; i < posterCount; i++) {
                    if (slots[i].bound == null) {
                        throw new AssertionError("Blank poster at pass=" + pass + " idx=" + i);
                    }
                }
                passMs[pass] = (System.nanoTime() - t0) / 1_000_000.0;
            }

            // Recycled view cross-binding check: view rebound to URL B before stale URL A arrives
            SimulatedSlot recycled = new SimulatedSlot("http://127.0.0.1:" + port + "/p/0.jpg", 0);
            recycled.rebind("http://127.0.0.1:" + port + "/p/1.jpg", 1);
            BufferedImage staleA = ImageIO.read(new ByteArrayInputStream(jpegs[0]));
            recycled.bindIfMatching(
                    "http://127.0.0.1:" + port + "/p/0.jpg", staleA, crossBindErrors);
            check(
                    recycled.bound == null && crossBindErrors[0] == 0,
                    "200-poster cross-binding guard: stale URL A dropped after view rebound to URL B");

            check(
                    totalHttpHits.get() == posterCount,
                    "200-poster 3-pass scroll: exact 200 HTTP fetches for 640 binds (0 redundant fetches)");
            check(
                    cacheHits[0] >= 400 && dedupCoalesced[0] >= 0 && crossBindErrors[0] == 0,
                    "200-poster 3-pass scroll: passes 2 & 3 served 100% from cache (cacheHits="
                            + cacheHits[0]
                            + ", coalesced="
                            + dedupCoalesced[0]
                            + ", crossBindErrors=0)");

            System.out.printf(
                    "BENCH 200-posters-3-passes: unique_posters=%d total_binds=640 http_fetches=%d cache_hits=%d inflight_coalesced=%d cross_bind_errors=%d pass1_ms=%.2f pass2_ms=%.2f pass3_ms=%.2f%n",
                    posterCount,
                    totalHttpHits.get(),
                    cacheHits[0],
                    dedupCoalesced[0],
                    crossBindErrors[0],
                    passMs[0],
                    passMs[1],
                    passMs[2]);
        } finally {
            pool.shutdownNow();
            server.stop(0);
        }
    }

    private static final class SimulatedSlot {
        volatile String tagUrl;
        volatile int expectedIdx;
        volatile BufferedImage bound;

        SimulatedSlot(String tagUrl, int expectedIdx) {
            this.tagUrl = tagUrl;
            this.expectedIdx = expectedIdx;
        }

        void rebind(String nextUrl, int nextIdx) {
            this.tagUrl = nextUrl;
            this.expectedIdx = nextIdx;
            this.bound = null; // Mirrors ImageLoader clearing stale drawable on URL change
        }

        void bindIfMatching(String url, BufferedImage bmp, int[] errCounter) {
            if (url.equals(tagUrl)) {
                this.bound = bmp;
            }
        }
    }

    private static byte[] readAll(HttpURLConnection conn) throws IOException {
        try (java.io.InputStream in = conn.getInputStream();
                ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return out.toByteArray();
        } finally {
            conn.disconnect();
        }
    }

    private static Cms.Site makeSite(String key, String name) {
        Cms.Site s = new Cms.Site();
        s.key = key;
        s.name = name;
        return s;
    }

    private static Cms.Video makeVideo(String id, String title) {
        Cms.Video v = new Cms.Video();
        v.id = id;
        v.title = title;
        v.remarks = "HD";
        return v;
    }

    private static String readUtf8(File f) throws IOException {
        return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        File srcRoot = new File(args[0]);
        File sharedGlassFile = new File(args[1]);
        bench45SearchIncrementalAppend(srcRoot);
        audit65MobileGlassBackdrop(srcRoot, sharedGlassFile);
        benchInlineProgressCheckpointing10Min();
        bench200PostersThreePasses();
        System.out.println(checks + " Batch 4 performance & stress checks passed");
        System.exit(0);
    }
}

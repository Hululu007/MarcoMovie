package com.pilipala.marcomovie;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Automated regression suite for Codex Rework Priority Blockers R1-R5:
 *
 * <ul>
 *   <li>R1: Search page return from Detail re-activates page token while still rejecting late
 *       callbacks from earlier searches or exited pages.
 *   <li>R2: ConfigStore crash durability (real child JVM halt + cold restart, atomic config-state
 *       recovery, and failed disk write retry healing).
 *   <li>R3: Inline player background stop revokes playback intent even while buffering (tested both
 *       directly and in dedicated buffering double harness run by run_rework_r1_r5_checks.py).
 *   <li>R4: Latch-controlled slow player prepare task A cannot construct MPV or release active B
 *       when ownership moved to B (both rapid line switch and inline-to-fullscreen handoff).
 *   <li>R5: Finite mid-episode IntroDB credits window never triggers ACTION_NEXT_EPISODE regardless
 *       of entry offset, while true end-of-episode credits still advance to next episode.
 * </ul>
 */
public final class ReworkR1ToR5Checks {
    private static int checks;

    private static void check(boolean cond, String label) {
        if (!cond) {
            throw new AssertionError("FAIL: " + label);
        }
        checks++;
        System.out.println("PASS " + label);
    }

    private static String readUtf8(Path path) {
        try {
            return new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "";
        }
    }

    // -------------------------------------------------------------------------
    // Child JVM entry points for R2 crash durability (real Runtime.halt(0))
    // -------------------------------------------------------------------------

    private static void runR2HaltChild(Path dir) throws Exception {
        Path pointersFile = dir.resolve("simulated-prefs");
        Path activeFile = dir.resolve("config.json");
        String oldBody = "{\"sites\":[{\"key\":\"site_a\",\"type\":1,\"api\":\"./a\"}]}";
        String freshBody = "{\"sites\":[{\"key\":\"site_b\",\"type\":1,\"api\":\"./b\"}]}";
        ConfigStore cs = new ConfigStore(dir.toFile());
        ConfigStore.PointerStore ps =
                new ConfigStore.PointerStore() {
                    @Override
                    public ConfigStore.PointerSnapshot readCurrentPointers() {
                        String txt = readUtf8(pointersFile);
                        if (txt.isEmpty()) return new ConfigStore.PointerSnapshot(null, null);
                        String[] parts = txt.split(" / ");
                        return new ConfigStore.PointerSnapshot(
                                parts[0], parts.length > 1 ? parts[1] : null);
                    }

                    @Override
                    public void applyPointers(ConfigStore.PointerSnapshot p) {
                        try {
                            Files.write(
                                    pointersFile,
                                    (p.origin + " / " + p.selectedSite)
                                            .getBytes(StandardCharsets.UTF_8));
                        } catch (Exception e) {
                            throw new RuntimeException(e);
                        }
                    }
                };
        Boolean initOk =
                cs.saveAsync(oldBody, new ConfigStore.PointerSnapshot("A", "site_a"), ps, null)
                        .get(5, TimeUnit.SECONDS);
        if (!Boolean.TRUE.equals(initOk)) {
            throw new AssertionError("R2 child initial save failed");
        }
        CountDownLatch blocked = new CountDownLatch(1);
        CountDownLatch holdForever = new CountDownLatch(1);
        ConfigStore.WRITE_EXECUTOR.submit(
                () -> {
                    blocked.countDown();
                    try {
                        holdForever.await();
                    } catch (InterruptedException ignored) {
                    }
                });
        if (!blocked.await(5, TimeUnit.SECONDS)) {
            throw new AssertionError("R2 child writer did not block");
        }
        ConfigStore.CommitResult commit =
                cs.saveIfExpectedSeq(
                        cs.latestWriteSeq(),
                        freshBody,
                        new ConfigStore.PointerSnapshot("B", "site_b"),
                        ps,
                        null);
        String pNow = readUtf8(pointersFile);
        String bNow = readUtf8(activeFile);
        System.out.println(
                "queued=" + commit.accepted + "; persisted pointers=" + pNow + "; body=" + bNow);
        System.out.flush();
        if (!commit.accepted || !"A / site_a".equals(pNow) || !oldBody.equals(bNow)) {
            System.err.println("R2 split-brain detected before halt!");
            System.err.flush();
            Runtime.getRuntime().halt(2);
        }
        Runtime.getRuntime().halt(0);
    }

    private static void runR2ColdChild(Path dir) throws Exception {
        Path pointersFile = dir.resolve("simulated-prefs");
        Path activeFile = dir.resolve("config.json");
        String oldBody = "{\"sites\":[{\"key\":\"site_a\",\"type\":1,\"api\":\"./a\"}]}";
        String persistedPointers = readUtf8(pointersFile);
        String persistedBody = readUtf8(activeFile);
        ConfigStore cs = new ConfigStore(dir.toFile());
        ConfigStore.RecoveredState recovered = cs.loadRecoveredState("A", "site_a");
        check(
                "A / site_a".equals(persistedPointers) && oldBody.equals(persistedBody),
                "R2 cold restart: pointers and config.json remain consistently on A/site_a after halt");
        check(
                recovered != null
                        && recovered.fromAtomicBundle
                        && "A".equals(recovered.origin)
                        && "site_a".equals(recovered.selectedSite)
                        && oldBody.equals(recovered.raw),
                "R2 cold restart: ConfigStore.loadRecoveredState returns atomic A/site_a version");
    }

    // -------------------------------------------------------------------------
    // R1: Search Page Return from Detail
    // -------------------------------------------------------------------------

    private static void testR1SearchPageReturn(File srcRoot) throws Exception {
        MobileSearchPage.invalidateSession();
        Object cfg = new Object();
        Cms.Site siteA = new Cms.Site();
        siteA.key = "site_a";
        siteA.name = "甲源";
        Cms.Site siteB = new Cms.Site();
        siteB.key = "site_b";
        siteB.name = "乙源";
        Cms.Video vA = new Cms.Video();
        vA.id = "va1";
        vA.title = "甲片";
        Cms.Video vB = new Cms.Video();
        vB.id = "vb1";
        vB.title = "乙片";

        long retainedToken = MobileSearchPage.beginPage();
        MobileSearchPage.SearchSession a =
                MobileSearchPage.startSession(retainedToken, "a", false, cfg, 0, 1, 2);
        check(
                MobileSearchPage.acceptBatchIfCurrent(
                        a,
                        false,
                        cfg,
                        0,
                        1,
                        Collections.singletonList(new MobileSearchPage.Hit(siteA, vA))),
                "R1: initial search A before entering detail accepted");

        // User opens detail -> onViewDetachedFromWindow calls onPageExit()
        MobileSearchPage.onPageExit();
        check(a.cancelled, "R1: leaving detail while search A is still incomplete cancels A");
        check(
                !MobileSearchPage.acceptBatchIfCurrent(
                        a,
                        false,
                        cfg,
                        0,
                        1,
                        Collections.singletonList(new MobileSearchPage.Hit(siteA, vA))),
                "R1: late callback from A rejected after page exit");

        // Case 1: User presses Back onto retained view (even if caller still passes retainedToken)
        MobileSearchPage.SearchSession b =
                MobileSearchPage.startSession(retainedToken, "b", false, cfg, 0, 2, 1);
        check(
                MobileSearchPage.acceptBatchIfCurrent(
                        b,
                        false,
                        cfg,
                        0,
                        2,
                        Collections.singletonList(new MobileSearchPage.Hit(siteB, vB))),
                "R1: searching B after returning to retained search view succeeds");
        check(
                b.snapshotHits().size() == 1
                        && "vb1".equals(b.snapshotHits().get(0).video.id)
                        && b.status().contains("1/1"),
                "R1: search B delivers result and updates completion status");
        check(
                !MobileSearchPage.acceptBatchIfCurrent(
                        a,
                        false,
                        cfg,
                        0,
                        2,
                        Collections.singletonList(new MobileSearchPage.Hit(siteA, vA))),
                "R1: late callback from earlier search A still rejected after B started");

        // Case 2: Re-attached view calling beginPage() on attach also works, and exiting cancels C
        long reattachedToken = MobileSearchPage.beginPage();
        MobileSearchPage.SearchSession c =
                MobileSearchPage.startSession(reattachedToken, "c", false, cfg, 0, 3, 2);
        MobileSearchPage.onPageExit();
        check(
                c.cancelled
                        && !MobileSearchPage.acceptBatchIfCurrent(
                                c,
                                false,
                                cfg,
                                0,
                                3,
                                Collections.singletonList(new MobileSearchPage.Hit(siteB, vB))),
                "R1: leaving page again after re-attach still cancels in-flight search C");

        // Static wiring check: MobileSearchPage.render refreshes token on re-attach
        String searchSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileSearchPage.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                searchSrc.contains("pageTokenHolder[0] = beginPage();")
                        && searchSrc.contains(
                                "startSession(\n                                    pageTokenHolder[0]"),
                "R1 wiring: MobileSearchPage.render refreshes pageTokenHolder on attach and uses mutable token");
    }

    // -------------------------------------------------------------------------
    // R2: Subscription Config Durability, Atomic Recovery & Failed Write Retry
    // -------------------------------------------------------------------------

    private static void testR2DurabilityAndFailedWriteRetry(File workDir, File srcRoot)
            throws Exception {
        // 1. Normal A -> B transition + atomic recovery when Prefs lagged behind config-state.json
        File normalDir = new File(workDir, "r2-normal");
        ConfigStore store = new ConfigStore(normalDir);
        final AtomicReference<String> originPref = new AtomicReference<>(null);
        final AtomicReference<String> sitePref = new AtomicReference<>(null);
        ConfigStore.PointerStore ps =
                new ConfigStore.PointerStore() {
                    @Override
                    public ConfigStore.PointerSnapshot readCurrentPointers() {
                        return new ConfigStore.PointerSnapshot(originPref.get(), sitePref.get());
                    }

                    @Override
                    public void applyPointers(ConfigStore.PointerSnapshot s) {
                        originPref.set(s.origin);
                        sitePref.set(s.selectedSite);
                    }
                };
        String bodyA = "{\"sites\":[{\"key\":\"site_a\",\"type\":1,\"api\":\"./a\"}]}";
        String bodyB = "{\"sites\":[{\"key\":\"site_b\",\"type\":1,\"api\":\"./b\"}]}";
        AtomicInteger successCount = new AtomicInteger();
        ConfigStore.CommitResult commitA =
                store.saveAsync(
                        bodyA,
                        new ConfigStore.PointerSnapshot("https://a.example/cfg.json", "site_a"),
                        ps,
                        (seq, committed) -> successCount.incrementAndGet(),
                        null);
        check(
                commitA.accepted
                        && Boolean.TRUE.equals(commitA.future.get(5, TimeUnit.SECONDS))
                        && successCount.get() == 1
                        && "https://a.example/cfg.json".equals(originPref.get())
                        && "site_a".equals(sitePref.get()),
                "R2: normal initial save A persists config, state bundle, pointers and fires onSuccess");

        ConfigStore.CommitResult commitB =
                store.saveIfExpectedSeq(
                        store.latestWriteSeq(),
                        bodyB,
                        new ConfigStore.PointerSnapshot("https://b.example/cfg.json", "site_b"),
                        ps,
                        (seq, committed) -> successCount.incrementAndGet(),
                        null);
        check(
                commitB.accepted
                        && Boolean.TRUE.equals(commitB.future.get(5, TimeUnit.SECONDS))
                        && successCount.get() == 2
                        && "https://b.example/cfg.json".equals(originPref.get())
                        && "site_b".equals(sitePref.get()),
                "R2: normal A -> B transition persists B body + pointers atomically");

        // Simulate crash window where config-state.json committed B but SharedPreferences still had
        // stale A pointers: cold recovery must recover consistent B + originB (never A origin + B
        // body).
        ConfigStore.RecoveredState recoveredB =
                store.loadRecoveredState("https://a.example/cfg.json", "site_a");
        check(
                recoveredB != null
                        && recoveredB.fromAtomicBundle
                        && "https://b.example/cfg.json".equals(recoveredB.origin)
                        && "site_b".equals(recoveredB.selectedSite)
                        && bodyB.equals(recoveredB.raw),
                "R2: atomic config-state bundle heals stale prefs pointers on cold start");

        // 2. Failed write must NOT invoke onSuccess, must preserve old pointers, and subsequent
        // retry (both force=true and force=false) with unchanged server & old active config MUST
        // request active repair until persisted!
        String subUrl = "https://sub.example/sub.json";
        String oldSub =
                "{\"sites\":[{\"key\":\"a\",\"name\":\"A\",\"type\":1,\"api\":\"https://sub.example/a\"}]}";
        String freshSub = oldSub.replace("sub.example/a", "sub.example/b");
        File libDir = new File(workDir, "r2-lib");
        ConfigLibrary library = new ConfigLibrary(libDir);
        library.remember(oldSub, subUrl, "A", "a", 1L);

        SubscriptionManager.RefreshSummary first =
                SubscriptionManager.refreshDueSubscriptions(
                        library, subUrl, oldSub, 10_000L, true, u -> freshSub);
        check(
                first.activeChanged
                        && first.updatedCount == 1
                        && freshSub.equals(first.updatedActiveRaw),
                "R2: initial refresh detects remote update and requests active config write");

        // Force disk write failure by pointing ConfigStore at a regular file instead of directory.
        File notDir = new File(workDir, "not-a-dir");
        Files.write(notDir.toPath(), new byte[] {1});
        ConfigStore brokenStore = new ConfigStore(notDir);
        AtomicInteger badSuccess = new AtomicInteger();
        AtomicInteger badFailure = new AtomicInteger();
        final AtomicReference<String> badOrigin = new AtomicReference<>(subUrl);
        final AtomicReference<String> badSite = new AtomicReference<>("old_site");
        ConfigStore.PointerStore badPs =
                new ConfigStore.PointerStore() {
                    @Override
                    public ConfigStore.PointerSnapshot readCurrentPointers() {
                        return new ConfigStore.PointerSnapshot(badOrigin.get(), badSite.get());
                    }

                    @Override
                    public void applyPointers(ConfigStore.PointerSnapshot s) {
                        badOrigin.set(s.origin);
                        badSite.set(s.selectedSite);
                    }
                };
        ConfigStore.CommitResult failedCommit =
                brokenStore.saveIfExpectedSeq(
                        0L,
                        first.updatedActiveRaw,
                        new ConfigStore.PointerSnapshot(subUrl, "new_site"),
                        badPs,
                        (seq, c) -> badSuccess.incrementAndGet(),
                        (seq, err, rb) -> badFailure.incrementAndGet());
        Boolean writeOk = failedCommit.future.get(5, TimeUnit.SECONDS);
        check(
                failedCommit.accepted
                        && Boolean.FALSE.equals(writeOk)
                        && badSuccess.get() == 0
                        && badFailure.get() == 1
                        && "old_site".equals(badSite.get()),
                "R2: failed active write returns false, skips onSuccess, fires onFailure, preserves old pointers");

        // Retry #1 (force=true) with unchanged server & OLD active config must repair active config
        SubscriptionManager.RefreshSummary retryForce =
                SubscriptionManager.refreshDueSubscriptions(
                        library, subUrl, oldSub, 20_000L, true, u -> freshSub);
        check(
                retryForce.activeChanged
                        && retryForce.updatedCount == 1
                        && freshSub.equals(retryForce.updatedActiveRaw),
                "R2: forced retry with unchanged server & stale active config requests active repair");

        // Retry #2 (force=false, within 24h window!) must STILL repair out-of-sync active config
        SubscriptionManager.RefreshSummary retryAuto =
                SubscriptionManager.refreshDueSubscriptions(
                        library, subUrl, oldSub, 25_000L, false, u -> freshSub);
        check(
                retryAuto.activeChanged
                        && retryAuto.updatedCount == 1
                        && freshSub.equals(retryAuto.updatedActiveRaw),
                "R2: automatic non-force retry still repairs out-of-sync active config");

        // Once active write succeeds and active config becomes freshSub, retry reports up-to-date.
        File healedDir = new File(workDir, "r2-healed");
        ConfigStore healthyStore = new ConfigStore(healedDir);
        AtomicInteger healedSuccess = new AtomicInteger();
        Boolean healOk =
                healthyStore
                        .saveIfExpectedSeq(
                                0L,
                                retryForce.updatedActiveRaw,
                                new ConfigStore.PointerSnapshot(subUrl, "a"),
                                badPs,
                                (seq, c) -> healedSuccess.incrementAndGet(),
                                null)
                        .future
                        .get(5, TimeUnit.SECONDS);
        check(
                Boolean.TRUE.equals(healOk) && healedSuccess.get() == 1,
                "R2: retry write to healthy store succeeds");
        SubscriptionManager.RefreshSummary afterHeal =
                SubscriptionManager.refreshDueSubscriptions(
                        library, subUrl, freshSub, 30_000L, true, u -> freshSub);
        check(
                !afterHeal.activeChanged && afterHeal.updatedCount == 0,
                "R2: after active config is repaired, subsequent refresh reports 0 updates");

        // Static wiring check: SourceController updates SUBSCRIPTION_LAST_AUTO_UPDATE and toasts
        // only inside ConfigStore success callback.
        String scSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "SourceController.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                scSrc.contains("保存失败，原配置已保留") && scSrc.contains("(seq, committed) ->"),
                "R2 wiring: SourceController commits UI/status updates only on disk write success callback");
    }

    // -------------------------------------------------------------------------
    // R4: Latch-Controlled Slow Task A Cannot Release Active MPV B
    // -------------------------------------------------------------------------

    private static final class FakeSingletonMpv {
        static FakeSingletonMpv active;
        static final AtomicInteger liveCount = new AtomicInteger();

        final String name;
        final AtomicInteger releaseCalls = new AtomicInteger();
        boolean released;

        FakeSingletonMpv(String name) {
            // Mirrors MpvPlayer.java:380 — creating a new MPV instance immediately releases the
            // process-wide activeInstance!
            if (active != null && active != this) {
                active.release();
            }
            this.name = name;
            active = this;
            liveCount.incrementAndGet();
        }

        void release() {
            releaseCalls.incrementAndGet();
            if (!released) {
                released = true;
                liveCount.decrementAndGet();
                if (active == this) {
                    active = null;
                }
            }
        }
    }

    private static void testR4StaleTaskCannotReleaseActiveMpv(File srcRoot) throws Exception {
        ExecutorService mainLooper =
                Executors.newSingleThreadExecutor(r -> new Thread(r, "r4-fake-main"));
        ExecutorService workers = Executors.newFixedThreadPool(2);
        try {
            PlaybackController.MainThreadDispatcher main = mainLooper::execute;

            // Scenario 1: Slow line A vs Fast line B on shared singleton MPV
            FakeSingletonMpv.active = null;
            FakeSingletonMpv.liveCount.set(0);
            final AtomicInteger activeSerial = new AtomicInteger(1);
            final CountDownLatch aPreparing = new CountDownLatch(1);
            final CountDownLatch releaseA = new CountDownLatch(1);
            final CountDownLatch bReady = new CountDownLatch(1);
            final CountDownLatch aDone = new CountDownLatch(1);
            final AtomicReference<FakeSingletonMpv> mpvBRef = new AtomicReference<>();
            final AtomicInteger aConstructAttempts = new AtomicInteger();

            // Launch slow task A (serial = 1)
            workers.execute(
                    () -> {
                        aPreparing.countDown();
                        try {
                            releaseA.await(5, TimeUnit.SECONDS);
                        } catch (InterruptedException ignored) {
                        }
                        PlaybackController.commitPreparedLaunchOnMain(
                                main,
                                () -> activeSerial.get() == 1,
                                () -> {
                                    aConstructAttempts.incrementAndGet();
                                    return new FakeSingletonMpv("A");
                                },
                                null);
                        main.post(aDone::countDown);
                    });

            check(
                    aPreparing.await(5, TimeUnit.SECONDS),
                    "R4: slow line A entered background prepare");

            // User rapidly switches to fast line B (serial = 2)
            activeSerial.set(2);
            workers.execute(
                    () ->
                            PlaybackController.commitPreparedLaunchOnMain(
                                    main,
                                    () -> activeSerial.get() == 2,
                                    () -> {
                                        FakeSingletonMpv b = new FakeSingletonMpv("B");
                                        mpvBRef.set(b);
                                        bReady.countDown();
                                        return b;
                                    },
                                    null));

            check(bReady.await(5, TimeUnit.SECONDS), "R4: fast line B acquired singleton MPV");
            FakeSingletonMpv mpvB = mpvBRef.get();
            check(
                    mpvB != null
                            && FakeSingletonMpv.active == mpvB
                            && FakeSingletonMpv.liveCount.get() == 1,
                    "R4: B is sole active MPV before stale A returns");

            // Now let slow task A finish URL prep and post to main thread
            releaseA.countDown();
            check(
                    aDone.await(5, TimeUnit.SECONDS),
                    "R4: stale task A completed main-thread handoff");
            check(
                    aConstructAttempts.get() == 0
                            && mpvB.releaseCalls.get() == 0
                            && !mpvB.released
                            && FakeSingletonMpv.active == mpvB
                            && FakeSingletonMpv.liveCount.get() == 1,
                    "R4: stale line A never constructed MPV and never released active B");

            // Scenario 2: Inline slow task A vs expand-to-fullscreen B
            final AtomicBoolean inlineClosed = new AtomicBoolean(false);
            final AtomicInteger generation = new AtomicInteger(10);
            final CountDownLatch inlinePrep = new CountDownLatch(1);
            final CountDownLatch releaseInline = new CountDownLatch(1);
            final CountDownLatch fsReady = new CountDownLatch(1);
            final CountDownLatch inlineDone = new CountDownLatch(1);
            final AtomicReference<FakeSingletonMpv> fsMpvRef = new AtomicReference<>();
            final AtomicInteger inlineConstructAttempts = new AtomicInteger();

            workers.execute(
                    () -> {
                        inlinePrep.countDown();
                        try {
                            releaseInline.await(5, TimeUnit.SECONDS);
                        } catch (InterruptedException ignored) {
                        }
                        PlaybackController.commitPreparedLaunchOnMain(
                                main,
                                () -> !inlineClosed.get() && generation.get() == 10,
                                () -> {
                                    inlineConstructAttempts.incrementAndGet();
                                    return new FakeSingletonMpv("inline-stale");
                                },
                                null);
                        main.post(inlineDone::countDown);
                    });
            check(
                    inlinePrep.await(5, TimeUnit.SECONDS),
                    "R4: inline player task entered background prepare");

            // Expand to fullscreen detaches inline and increments generation to 11
            inlineClosed.set(true);
            generation.set(11);
            workers.execute(
                    () ->
                            PlaybackController.commitPreparedLaunchOnMain(
                                    main,
                                    () -> generation.get() == 11,
                                    () -> {
                                        FakeSingletonMpv fs = new FakeSingletonMpv("fullscreen");
                                        fsMpvRef.set(fs);
                                        fsReady.countDown();
                                        return fs;
                                    },
                                    null));
            check(
                    fsReady.await(5, TimeUnit.SECONDS),
                    "R4: fullscreen player acquired singleton MPV");
            FakeSingletonMpv fsMpv = fsMpvRef.get();

            releaseInline.countDown();
            check(
                    inlineDone.await(5, TimeUnit.SECONDS),
                    "R4: stale inline task finished main-thread check");
            check(
                    inlineConstructAttempts.get() == 0
                            && fsMpv.releaseCalls.get() == 0
                            && !fsMpv.released
                            && FakeSingletonMpv.active == fsMpv
                            && FakeSingletonMpv.liveCount.get() == 1,
                    "R4: stale inline task never clobbered active fullscreen MPV (single active playback preserved)");
        } finally {
            workers.shutdownNow();
            mainLooper.shutdownNow();
        }

        // Static wiring check: player creation in both MobileInlinePlayer and PlaybackController
        // occurs strictly inside commitPreparedLaunchOnMain (never before main-thread ownership).
        String inlineSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileInlinePlayer.java").toPath()),
                        StandardCharsets.UTF_8);
        String pcSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "PlaybackController.java").toPath()),
                        StandardCharsets.UTF_8);
        int inlineCommitIdx = inlineSrc.indexOf("PlaybackController.commitPreparedLaunchOnMain(");
        int inlineCreateIdx = inlineSrc.indexOf("PlaybackController.createPlayerWithPlan(");
        check(
                inlineCommitIdx > 0 && inlineCreateIdx > inlineCommitIdx,
                "R4 wiring: MobileInlinePlayer creates player strictly inside commitPreparedLaunchOnMain");

        int pcCommitIdx = pcSrc.indexOf("commitPreparedLaunchOnMain(");
        int pcCreateIdx = pcSrc.indexOf("createPlayerWithPlan(a, ep, plan, created)");
        check(
                pcCommitIdx > 0 && pcCreateIdx > pcCommitIdx,
                "R4 wiring: PlaybackController.playerPage creates player strictly inside commitPreparedLaunchOnMain");
    }

    // -------------------------------------------------------------------------
    // R5: Finite Mid-Episode Credits Window Must Never Skip Episode
    // -------------------------------------------------------------------------

    private static void testR5FiniteMidEpisodeCredits() {
        long dur45Min = 2_700_000L;
        // Mid-episode credits [25:00, 25:10] with 20 minutes remaining and auto-next enabled
        TmdbService.TimeRange midCredits = new TmdbService.TimeRange(1_500_000L, 1_510_000L);

        // At 25:00: seek to 25:10
        IntroSkipEvaluator eStart = new IntroSkipEvaluator();
        eStart.resetForEpisode(1L, 0, 0);
        eStart.applyCommunityTimestamps(
                1L,
                new TmdbService.IntroTimestamps(
                        Collections.<TmdbService.TimeRange>emptyList(),
                        Collections.singletonList(midCredits)));
        IntroSkipEvaluator.Decision dStart = eStart.evaluate(1_500_000L, dur45Min, true, true);
        check(
                dStart.action == IntroSkipEvaluator.ACTION_SEEK && dStart.targetMs == 1_510_000L,
                "R5: finite mid-episode credits at 25:00 seeks to 25:10");

        // At 25:09.250, 25:09.750, 25:09.999 (<1s remaining in finite mid-episode range):
        // MUST return ACTION_NONE, NEVER ACTION_NEXT_EPISODE!
        for (long pos : new long[] {1_509_000L, 1_509_250L, 1_509_750L, 1_509_999L}) {
            IntroSkipEvaluator eTail = new IntroSkipEvaluator();
            eTail.resetForEpisode(2L, 0, 0);
            eTail.applyCommunityTimestamps(
                    2L,
                    new TmdbService.IntroTimestamps(
                            Collections.<TmdbService.TimeRange>emptyList(),
                            Collections.singletonList(midCredits)));
            IntroSkipEvaluator.Decision dTail = eTail.evaluate(pos, dur45Min, true, true);
            check(
                    dTail.action == IntroSkipEvaluator.ACTION_NONE,
                    "R5: finite mid-episode credits at pos="
                            + pos
                            + " continues episode (ACTION_NONE, never ACTION_NEXT_EPISODE)");
        }

        // True end-of-episode open credits [43:00, -1] MUST still trigger ACTION_NEXT_EPISODE
        IntroSkipEvaluator eOpenEnd = new IntroSkipEvaluator();
        eOpenEnd.resetForEpisode(3L, 0, 0);
        eOpenEnd.applyCommunityTimestamps(
                3L,
                new TmdbService.IntroTimestamps(
                        Collections.<TmdbService.TimeRange>emptyList(),
                        Collections.singletonList(new TmdbService.TimeRange(2_580_000L, -1L))));
        IntroSkipEvaluator.Decision dOpenEnd = eOpenEnd.evaluate(2_585_000L, dur45Min, true, true);
        check(
                dOpenEnd.action == IntroSkipEvaluator.ACTION_NEXT_EPISODE,
                "R5: open-ended end credits [43:00, EOF] triggers ACTION_NEXT_EPISODE when auto-next enabled");

        // Finite credits reaching EOF [43:00, 45:00] MUST trigger ACTION_NEXT_EPISODE
        IntroSkipEvaluator eFiniteEnd = new IntroSkipEvaluator();
        eFiniteEnd.resetForEpisode(4L, 0, 0);
        eFiniteEnd.applyCommunityTimestamps(
                4L,
                new TmdbService.IntroTimestamps(
                        Collections.<TmdbService.TimeRange>emptyList(),
                        Collections.singletonList(
                                new TmdbService.TimeRange(2_580_000L, dur45Min))));
        IntroSkipEvaluator.Decision dFiniteEnd =
                eFiniteEnd.evaluate(2_585_000L, dur45Min, true, true);
        check(
                dFiniteEnd.action == IntroSkipEvaluator.ACTION_NEXT_EPISODE,
                "R5: finite end credits reaching EOF [43:00, 45:00] triggers ACTION_NEXT_EPISODE");

        // Both a finite mid-episode credits window AND true end credits in the same episode:
        // mid-episode continues playback; true end credits later triggers next episode!
        IntroSkipEvaluator eDual = new IntroSkipEvaluator();
        eDual.resetForEpisode(5L, 0, 0);
        eDual.applyCommunityTimestamps(
                5L,
                new TmdbService.IntroTimestamps(
                        Collections.<TmdbService.TimeRange>emptyList(),
                        Arrays.asList(midCredits, new TmdbService.TimeRange(2_580_000L, -1L))));
        IntroSkipEvaluator.Decision dMid = eDual.evaluate(1_509_500L, dur45Min, true, true);
        IntroSkipEvaluator.Decision dEnd = eDual.evaluate(2_580_000L, dur45Min, true, true);
        check(
                dMid.action == IntroSkipEvaluator.ACTION_NONE
                        && dEnd.action == IntroSkipEvaluator.ACTION_NEXT_EPISODE,
                "R5: dual credits skips nothing at mid-episode tail and advances only at true EOF credits");

        // Respects autoNextEnabled=false and hasNextEpisode=false
        IntroSkipEvaluator eNoNext = new IntroSkipEvaluator();
        eNoNext.resetForEpisode(6L, 0, 0);
        eNoNext.applyCommunityTimestamps(
                6L,
                new TmdbService.IntroTimestamps(
                        Collections.<TmdbService.TimeRange>emptyList(),
                        Collections.singletonList(new TmdbService.TimeRange(2_580_000L, -1L))));
        check(
                eNoNext.evaluate(2_580_000L, dur45Min, false, true).action
                        == IntroSkipEvaluator.ACTION_NONE,
                "R5: open-ended credits does not advance when hasNextEpisode=false");
    }

    public static void main(String[] args) throws Exception {
        if (args.length >= 2 && "--r2-halt".equals(args[0])) {
            runR2HaltChild(Paths.get(args[1]));
            return;
        }
        if (args.length >= 2 && "--r2-cold".equals(args[0])) {
            runR2ColdChild(Paths.get(args[1]));
            return;
        }
        File workDir = new File(args[0]);
        File srcRoot = new File(args[1]);
        testR1SearchPageReturn(srcRoot);
        testR2DurabilityAndFailedWriteRetry(workDir, srcRoot);
        testR4StaleTaskCannotReleaseActiveMpv(srcRoot);
        testR5FiniteMidEpisodeCredits();
        System.out.println(checks + " R1/R2/R4/R5 checks passed");
        System.exit(0);
    }
}

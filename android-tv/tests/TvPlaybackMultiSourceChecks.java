package com.pilipala.marcomovie;

import com.pilipala.marcomovie.hud.FastForwardScrubCapsule;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Pure JVM regression checks for:
 * 1) R7 post-review rework (LoadingGuardTracker, AppDialog visible bounds, HomeDock reversal guard)
 * 2) Modern light seek capsule (format + gating)
 * 3) Minimalist logo + single-line live speed loader (0 KB/s fallback, resetSession, local URL)
 * 4) Classic two-tier player toolbar (grouped VOD/Single/Local/Live + legacy custom preservation)
 * 5) Multi-source subscription cards & order-independent stable site identity (conflict, toggle,
 *    reorder, zero-enabled cold restart, per-site disable, legacy single/merged upgrade, refresh
 *    failure preservation, stale revision guard, fair 500-site cap)
 */
public final class TvPlaybackMultiSourceChecks {
    private static int passed = 0;

    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAILED: " + label);
        passed++;
    }

    private static String makeSubJson(String... siteSpecs) {
        StringBuilder sb = new StringBuilder("{\"sites\":[");
        for (int i = 0; i < siteSpecs.length; i++) {
            if (i > 0) sb.append(',');
            String[] parts = siteSpecs[i].split("\\|", -1);
            String key = parts[0];
            String name = parts[1];
            String api = parts[2];
            sb.append("{\"key\":\"")
                    .append(key)
                    .append("\",\"name\":\"")
                    .append(name)
                    .append("\",\"type\":1,\"api\":\"")
                    .append(api)
                    .append("\",\"searchable\":1}");
        }
        sb.append("]}");
        return sb.toString();
    }

    private static String makeLargeSubJson(String prefix, int count) {
        StringBuilder sb = new StringBuilder("{\"sites\":[");
        for (int i = 0; i < count; i++) {
            if (i > 0) sb.append(',');
            sb.append("{\"key\":\"")
                    .append(prefix)
                    .append('_')
                    .append(i)
                    .append("\",\"name\":\"")
                    .append(prefix)
                    .append("线路")
                    .append(i)
                    .append("\",\"type\":1,\"api\":\"http://")
                    .append(prefix)
                    .append(".test/api/")
                    .append(i)
                    .append("\",\"searchable\":1}");
        }
        sb.append("]}");
        return sb.toString();
    }

    private static void testR7ReworkContracts() throws Exception {
        // 1. LoadingGuardTracker prevents stale B callback from clearing C's guard
        HomeSourceSwitchAnchor.LoadingGuardTracker tracker =
                new HomeSourceSwitchAnchor.LoadingGuardTracker();
        tracker.claim("site_b", 10, 100L);
        check(
                tracker.isOwner("site_b", 10, 100L)
                        && "site_b".equals(tracker.activeOwnerSiteKey()),
                "LoadingGuardTracker claims site B ownership");
        tracker.claim("site_c", 10, 101L);
        check(
                !tracker.isOwner("site_b", 10, 100L) && tracker.isOwner("site_c", 10, 101L),
                "Claiming site C invalidates site B token immediately");
        check(
                !tracker.releaseIfOwner("site_b", 10, 100L),
                "Stale site B completion cannot release site C guard");
        check(
                "site_c".equals(tracker.activeOwnerSiteKey()),
                "Site C guard stays active after stale B callback");
        check(
                !tracker.releaseIfSiteMatches("site_b", 10),
                "Site-key mismatch does not clear site C guard");
        check(
                tracker.releaseIfOwner("site_c", 10, 101L)
                        && tracker.activeOwnerSiteKey().isEmpty(),
                "Owner C releases guard cleanly");
        tracker.claim("site_d", 11, 102L);
        check(
                tracker.releaseIfSiteMatches("site_d", 11) && !tracker.isOwner("site_d", 11, 102L),
                "Matching site key releases guard cleanly on fallback path");

        // 2. AppDialog visible window bounds strictly cap inside 320x200 small window (density=2.0)
        AppDialog.DialogWindowBounds tiny =
                AppDialog.computeDialogWindowBounds(320, 200, 1040, 64, 64, 48);
        check(
                tiny.width <= 320
                        && tiny.maxHeight <= 200
                        && tiny.width > 0
                        && tiny.maxHeight > 0
                        && tiny.innerWidth > 0,
                "AppDialog bounds never exceed 320x200 visible window (got "
                        + tiny.width
                        + "x"
                        + tiny.maxHeight
                        + ")");

        AppDialog.DialogWindowBounds hd720 =
                AppDialog.computeDialogWindowBounds(1280, 720, 840, 60, 48, 36);
        check(
                hd720.width > 0
                        && hd720.width <= 1280
                        && hd720.maxHeight > 0
                        && hd720.maxHeight <= 720,
                "AppDialog bounds respect 1280x720 visible margins");

        // 3. HomeSourceSwitchAnchor scroll anchor alignment & selection routing
        check(
                HomeSourceSwitchAnchor.decideSiteSelectionAction("a", "a", true, true)
                        == HomeSourceSwitchAnchor.ACTION_DISMISS_ONLY,
                "Re-selecting same site dismisses picker without reloading");
        check(
                HomeSourceSwitchAnchor.decideSiteSelectionAction("a", "b", true, true)
                        == HomeSourceSwitchAnchor.ACTION_IN_PLACE_HOME_SWITCH,
                "Retained home switch executes in-place switch");
        check(
                HomeSourceSwitchAnchor.decideSiteSelectionAction("a", "b", false, false)
                        == HomeSourceSwitchAnchor.ACTION_SETTINGS_COMMIT_STAY,
                "Settings-page source selection commits without switching page");
        check(
                HomeSourceSwitchAnchor.computeAlignedScrollY(500, 120, 2000, 1080) == 380,
                "Anchor aligns source row to original relative viewport Y");
        check(
                HomeSourceSwitchAnchor.computeAlignedScrollY(500, 120, 1200, 1080) == 120,
                "Short-list scroll clamps safely to maxScroll");
    }

    private static void testLightSeekCapsuleContracts() {
        check(
                "快进 12:40".equals(FastForwardScrubCapsule.formatLightSeekCue(+1, 760_000)),
                "Light seek capsule formats forward mm:ss cue as '快进 12:40'");
        check(
                "快退 05:09".equals(FastForwardScrubCapsule.formatLightSeekCue(-1, 309_000)),
                "Light seek capsule formats rewind mm:ss cue as '快退 05:09'");
        check(
                "快进 1:01:01".equals(FastForwardScrubCapsule.formatLightSeekCue(+1, 3_661_000)),
                "Light seek capsule formats hh:mm:ss cue over 1 hour");
        check(
                "快退 00:00".equals(FastForwardScrubCapsule.formatLightSeekCue(-1, -5_000)),
                "Light seek capsule clamps negative target to 00:00");

        check(
                PlaybackController.shouldUseLightSeekCapsule(true, true, false, false),
                "Modern TV hidden controls uses light seek capsule");
        check(
                PlaybackController.shouldUseLightSeekCapsule(true, true, true, true),
                "Modern TV progress-only mode uses light seek capsule");
        check(
                !PlaybackController.shouldUseLightSeekCapsule(true, true, true, false),
                "Modern TV with controls explicitly open keeps timeline scrub active");
        check(
                !PlaybackController.shouldUseLightSeekCapsule(true, false, false, false),
                "Classic TV style keeps classic seek behavior");
        check(
                !PlaybackController.shouldUseLightSeekCapsule(false, true, false, false),
                "Non-TV device does not enter TV light seek capsule");
    }

    private static void testMinimalistSpeedMonitorContracts() {
        check(
                "0 KB/s".equals(NetworkSpeedMonitor.formatSpeed(0L)),
                "formatSpeed(0) renders '0 KB/s'");
        check(
                "0 KB/s".equals(NetworkSpeedMonitor.formatSpeed(-1L)),
                "formatSpeed(-1) renders '0 KB/s' and never '测速中…'");
        check(
                "2 KB/s".equals(NetworkSpeedMonitor.formatSpeed(2048L)),
                "formatSpeed(2048) renders '2 KB/s'");
        check(
                "1.0 MB/s".equals(NetworkSpeedMonitor.formatSpeed(1024L * 1024L)),
                "formatSpeed(1 MiB/s) renders '1.0 MB/s'");
        check(
                "实时网速 0 KB/s".equals(NetworkSpeedMonitor.formatSpeedLabel(-1L)),
                "formatSpeedLabel(-1) renders '实时网速 0 KB/s'");

        check(
                NetworkSpeedMonitor.isLocalMediaUrl("file:///sdcard/movie.mp4"),
                "file:// recognized as local media URL");
        check(
                NetworkSpeedMonitor.isLocalMediaUrl("/storage/emulated/0/movie.mp4"),
                "Absolute filesystem path recognized as local media URL");
        check(
                NetworkSpeedMonitor.isLocalMediaUrl("content://media/external/video/1"),
                "content:// recognized as local media URL");
        check(
                !NetworkSpeedMonitor.isLocalMediaUrl("https://cdn.example.com/a.m3u8"),
                "https:// is remote media URL");
        check(
                !NetworkSpeedMonitor.isLocalMediaUrl("http://127.0.0.1:9978/proxy"),
                "http:// local proxy URL is not treated as offline local file");

        // Verify exact transition sequence: initial unknown -> 2048 B/s -> both unavailable ->
        // resetSession
        AtomicLong fakeEngineRate = new AtomicLong(-1L);
        List<String> observed = new ArrayList<>();
        NetworkSpeedMonitor monitor =
                new NetworkSpeedMonitor(
                        fakeEngineRate::get, (bps, formatted) -> observed.add(formatted));
        monitor.start();
        check(
                observed.size() == 1 && "实时网速 0 KB/s".equals(observed.get(0)),
                "start() immediately emits '实时网速 0 KB/s' without '测速中…'");
        fakeEngineRate.set(2048L);
        monitor.sampleAndDispatch();
        check(
                "实时网速 2 KB/s".equals(observed.get(observed.size() - 1)),
                "Engine throughput 2048 B/s transitions to '实时网速 2 KB/s'");
        fakeEngineRate.set(-1L);
        monitor.sampleAndDispatch();
        check(
                "实时网速 0 KB/s".equals(observed.get(observed.size() - 1)),
                "Simultaneous engine + UID unavailability drops immediately to '实时网速 0 KB/s'");
        fakeEngineRate.set(512_000L);
        monitor.sampleAndDispatch();
        check(
                observed.get(observed.size() - 1).contains("500 KB/s"),
                "Non-zero throughput updates speed normally");
        monitor.resetSession();
        check(
                "实时网速 0 KB/s".equals(observed.get(observed.size() - 1)),
                "resetSession() immediately resets to '实时网速 0 KB/s' on session switch");
        monitor.stop();
        check(!monitor.isRunning(), "stop() halts monitor cleanly");
    }

    private static void testClassicTwoTierToolbarContracts() {
        List<String> vodMulti = TvPlayerToolbarOrder.visibleOrderForSession("", false, false, true);
        check(
                vodMulti.equals(
                        Arrays.asList(
                                TvPlayerToolbarOrder.KEY_EPISODES,
                                TvPlayerToolbarOrder.KEY_NEXT_EPISODE,
                                TvPlayerToolbarOrder.KEY_LINES,
                                TvPlayerToolbarOrder.KEY_DANMAKU,
                                TvPlayerToolbarOrder.KEY_TRACKS,
                                TvPlayerToolbarOrder.KEY_SPEED,
                                TvPlayerToolbarOrder.KEY_MORE)),
                "Classic VOD multi-episode default order matches grouped specification");

        check(
                TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_EPISODES, false) == 0
                        && TvPlayerToolbarOrder.groupBucket(
                                        TvPlayerToolbarOrder.KEY_NEXT_EPISODE, false)
                                == 0
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_LINES, false)
                                == 1
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_DANMAKU, false)
                                == 2
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_TRACKS, false)
                                == 2
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_SPEED, false)
                                == 2
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_MORE, false)
                                == 3,
                "Classic VOD visual grouping puts 选集/下一集 | 线路 | 弹幕/字幕音轨/倍速 | 更多 into 4 distinct buckets");

        List<String> vodSingle =
                TvPlayerToolbarOrder.visibleOrderForSession("", false, false, false);
        check(
                !vodSingle.contains(TvPlayerToolbarOrder.KEY_EPISODES)
                        && !vodSingle.contains(TvPlayerToolbarOrder.KEY_NEXT_EPISODE),
                "Classic single-episode VOD hides episodes and next-episode");

        check(
                !TvPlayerToolbarOrder.shouldShowLinesAction(false, 1, 0, true, false),
                "Local single-file playback hides unused lines button");
        check(
                TvPlayerToolbarOrder.shouldShowLinesAction(false, 2, 0, true, false),
                "Multiple lines keep lines button visible");
        check(
                TvPlayerToolbarOrder.shouldShowLinesAction(false, 1, 2, true, false),
                "Multiple qualities keep lines/quality button visible");
        check(
                TvPlayerToolbarOrder.shouldShowLinesAction(false, 1, 0, false, true),
                "Remote VOD with cross-source capability keeps lines button visible");

        List<String> liveClassic =
                TvPlayerToolbarOrder.visibleOrderForSession("", false, true, true);
        check(
                liveClassic.equals(
                        Arrays.asList(
                                TvPlayerToolbarOrder.KEY_EPISODES,
                                TvPlayerToolbarOrder.KEY_NEXT_EPISODE,
                                TvPlayerToolbarOrder.KEY_LINES,
                                TvPlayerToolbarOrder.KEY_EPG,
                                TvPlayerToolbarOrder.KEY_MORE)),
                "Classic Live default order is 频道、下一台 | 线路、节目单 | 更多");
        check(
                TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_EPISODES, true) == 0
                        && TvPlayerToolbarOrder.groupBucket(
                                        TvPlayerToolbarOrder.KEY_NEXT_EPISODE, true)
                                == 0
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_LINES, true)
                                == 1
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_EPG, true) == 1
                        && TvPlayerToolbarOrder.groupBucket(TvPlayerToolbarOrder.KEY_MORE, true)
                                == 2,
                "Classic Live visual grouping separates 频道/下一台 | 线路/节目单 | 更多");

        // Legacy custom order preservation across style switches
        String custom = "episodes,lines,danmaku,audio-tracks,skip-intro-tool,decoder,speed,more";
        List<String> classicCustom = TvPlayerToolbarOrder.resolveOrder(custom, false, false);
        List<String> modernCustom = TvPlayerToolbarOrder.resolveOrder(custom, true, false);
        check(
                classicCustom.equals(
                                Arrays.asList(
                                        "episodes",
                                        "lines",
                                        "danmaku",
                                        "audio-tracks",
                                        "skip-intro-tool",
                                        "decoder",
                                        "speed",
                                        "more"))
                        && modernCustom.equals(classicCustom),
                "Legacy custom toolbar order is strictly preserved across Classic and Modern styles");
    }

    private static void testMultiSourceStoreContracts(File rootDir) throws Exception {
        // ---- Scenario 1: Two subscriptions A & B with IDENTICAL site key="same" and name="同名影视"
        // ----
        File s1Dir = new File(rootDir, "scenario1_conflict");
        ConfigLibrary lib1 = new ConfigLibrary(s1Dir);
        TvMultiSourceStore store1 = new TvMultiSourceStore(s1Dir);

        String rawA =
                makeSubJson(
                        "same|同名影视|http://sub-a.test/same",
                        "extra_a|A独有线路|http://sub-a.test/extra");
        String rawB =
                makeSubJson(
                        "same|同名影视|http://sub-b.test/same",
                        "extra_b|B独有线路|http://sub-b.test/extra");

        TvMultiSourceStore.SubscriptionRecord recA =
                store1.registerSubscription(
                        lib1, rawA, "http://sub-a.test/config.json", "订阅A", true, 1000L);
        TvMultiSourceStore.SubscriptionRecord recB =
                store1.registerSubscription(
                        lib1, rawB, "http://sub-b.test/config.json", "订阅B", true, 2000L);

        TvMultiSourceStore.EffectiveBuild buildAB =
                store1.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        check(
                buildAB.enabledSubscriptionCount == 2 && buildAB.config.sites.size() == 4,
                "A+B enabled builds 4 distinct sites across 2 subscriptions");

        Cms.Site siteASame = null;
        Cms.Site siteAExtra = null;
        Cms.Site siteBSame = null;
        for (Cms.Site s : buildAB.config.sites) {
            if ("http://sub-a.test/same".equals(s.api)) siteASame = s;
            if ("http://sub-a.test/extra".equals(s.api)) siteAExtra = s;
            if ("http://sub-b.test/same".equals(s.api)) siteBSame = s;
        }
        check(
                siteASame != null && siteBSame != null && siteAExtra != null,
                "Both colliding sites and extras are present");
        check(
                !siteASame.key.equals(siteBSame.key),
                "Colliding 'same' sites receive distinct stable keys: "
                        + siteASame.key
                        + " vs "
                        + siteBSame.key);
        final String stableKeyA = siteASame.key;
        final String stableKeyAExtra = siteAExtra.key;
        final String stableKeyB = siteBSame.key;

        // Reorder B before A: BOTH stable keys MUST remain 100% invariant!
        store1.moveSubscription(recB.id, -1);
        TvMultiSourceStore.EffectiveBuild buildBA =
                store1.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        String keyAAfterReorder = "";
        String keyBAfterReorder = "";
        for (Cms.Site s : buildBA.config.sites) {
            if ("http://sub-a.test/same".equals(s.api)) keyAAfterReorder = s.key;
            if ("http://sub-b.test/same".equals(s.api)) keyBAfterReorder = s.key;
        }
        check(
                stableKeyA.equals(keyAAfterReorder) && stableKeyB.equals(keyBAfterReorder),
                "Reordering B before A keeps both stable keys 100% unchanged");
        check(
                "http://sub-b.test/same".equals(buildBA.config.sites.get(0).api),
                "Reordering B before A changes display order so B appears first");

        // Disable A -> B continues working with IDENTICAL key; A history resolves
        // DISABLED_SUBSCRIPTION (NOT B!)
        store1.setSubscriptionEnabled(recA.id, false);
        TvMultiSourceStore.EffectiveBuild buildOnlyB =
                store1.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        check(
                buildOnlyB.enabledSubscriptionCount == 1 && buildOnlyB.config.sites.size() == 2,
                "Disabling A leaves only B's 2 sites active");
        check(
                stableKeyB.equals(buildOnlyB.config.sites.get(0).key),
                "Disabling A NEVER mutates B's stable site key");
        check(
                !store1.isSiteCurrentlyEnabled(stableKeyA)
                        && store1.isSiteCurrentlyEnabled(stableKeyB),
                "isSiteCurrentlyEnabled accurately reflects A off / B on");

        TvMultiSourceStore.SiteResolution resB =
                store1.resolveStoredSiteKey(stableKeyB, buildOnlyB.config, lib1);
        check(
                resB.status == TvMultiSourceStore.SiteResolution.STATUS_ENABLED
                        && resB.activeSite != null
                        && "http://sub-b.test/same".equals(resB.activeSite.api),
                "B watch history / favorite resolves to B while A is disabled");

        TvMultiSourceStore.SiteResolution resAWhileOff =
                store1.resolveStoredSiteKey(stableKeyA, buildOnlyB.config, lib1);
        check(
                resAWhileOff.status
                                == TvMultiSourceStore.SiteResolution.STATUS_DISABLED_SUBSCRIPTION
                        && resAWhileOff.subscription != null
                        && recA.id.equals(resAWhileOff.subscription.id),
                "A watch history / favorite resolves STATUS_DISABLED_SUBSCRIPTION for A (NEVER opens B!)");

        // Per-site disable inside A + disable & cold-restart & re-enable A preserves per-site
        // disable!
        store1.setSubscriptionEnabled(recA.id, true);
        store1.setSiteDisabled(recA.id, "extra_a", true);
        TvMultiSourceStore.EffectiveBuild buildAExtraOff =
                store1.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        check(
                buildAExtraOff.config.sites.size() == 3,
                "Disabling extra_a inside A hides only extra_a while keeping A's same and B");
        TvMultiSourceStore.SiteResolution resExtraOff =
                store1.resolveStoredSiteKey(stableKeyAExtra, buildAExtraOff.config, lib1);
        check(
                resExtraOff.status == TvMultiSourceStore.SiteResolution.STATUS_DISABLED_SITE
                        && resExtraOff.subscription != null
                        && recA.id.equals(resExtraOff.subscription.id)
                        && "extra_a".equals(resExtraOff.rawSiteKey),
                "Per-site disabled key resolves STATUS_DISABLED_SITE");

        // Disable BOTH A and B (zero-enabled) -> cold restart MUST stay zero-enabled!
        store1.setSubscriptionEnabled(recA.id, false);
        store1.setSubscriptionEnabled(recB.id, false);
        TvMultiSourceStore.EffectiveBuild buildZero =
                store1.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        check(
                buildZero.enabledSubscriptionCount == 0 && buildZero.totalSubscriptionCount == 2,
                "Disabling all subscriptions yields zero-enabled state while retaining both cards");

        // Simulate cold restart with brand new TvMultiSourceStore instance reading same disk dir
        TvMultiSourceStore store1Cold = new TvMultiSourceStore(s1Dir);
        TvMultiSourceStore.State coldState = store1Cold.readState();
        check(
                coldState.initialized
                        && coldState.subscriptions.size() == 2
                        && coldState.enabledCount() == 0,
                "Cold restart preserves explicit zero-enabled state without auto-re-enabling");

        // Re-enable A after cold restart -> stableKeyA still matches AND extra_a is STILL disabled!
        store1Cold.setSubscriptionEnabled(recA.id, true);
        TvMultiSourceStore.EffectiveBuild buildReA =
                store1Cold.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        check(
                buildReA.config.sites.size() == 1
                        && stableKeyA.equals(buildReA.config.sites.get(0).key),
                "Re-enabling A restores stableKeyA identically and preserves extra_a per-site disable");
        store1Cold.setSiteDisabled(recA.id, "extra_a", false);
        TvMultiSourceStore.EffectiveBuild buildReAFull =
                store1Cold.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        check(buildReAFull.config.sites.size() == 2, "Re-enabling extra_a restores it cleanly");

        // ---- Scenario 2: Legacy Single-Source Upgrade Migration ----
        File s2Dir = new File(rootDir, "scenario2_legacy_single");
        ConfigLibrary lib2 = new ConfigLibrary(s2Dir);
        lib2.remember(rawA, "http://sub-a.test/config.json", "旧单源A", "same", 1000L);
        lib2.remember(rawB, "http://sub-b.test/config.json", "旧未用源B", "", 2000L);
        Cms.Config legacyActiveA = Cms.parseConfig(rawA, "http://sub-a.test/config.json");
        TvMultiSourceStore store2 = new TvMultiSourceStore(s2Dir);
        TvMultiSourceStore.State mig2 =
                store2.ensureMigrated(
                        lib2, legacyActiveA.raw, "http://sub-a.test/config.json", "same");
        check(
                mig2.initialized && mig2.subscriptions.size() == 2 && mig2.enabledCount() == 1,
                "Legacy single-source migration enables ONLY active A and keeps inactive B disabled");
        // Now enable B too: legacy watch history with unscoped key "same" MUST still open A!
        String subAId2 = "";
        String subBId2 = "";
        for (TvMultiSourceStore.SubscriptionRecord r : mig2.subscriptions) {
            if (r.origin.contains("sub-a.test")) subAId2 = r.id;
            if (r.origin.contains("sub-b.test")) subBId2 = r.id;
        }
        store2.setSubscriptionEnabled(subBId2, true);
        TvMultiSourceStore.EffectiveBuild build2AB =
                store2.buildEffectiveConfig(lib2, "", (cfg, s) -> true);
        TvMultiSourceStore.SiteResolution resLegacySame =
                store2.resolveStoredSiteKey("same", build2AB.config, lib2);
        check(
                resLegacySame.status == TvMultiSourceStore.SiteResolution.STATUS_ENABLED
                        && resLegacySame.activeSite != null
                        && "http://sub-a.test/same".equals(resLegacySame.activeSite.api),
                "Legacy unscoped 'same' history resolves via alias to A even after B is enabled");
        store2.setSubscriptionEnabled(subAId2, false);
        TvMultiSourceStore.EffectiveBuild build2OnlyB =
                store2.buildEffectiveConfig(lib2, "", (cfg, s) -> true);
        TvMultiSourceStore.SiteResolution resLegacySameOff =
                store2.resolveStoredSiteKey("same", build2OnlyB.config, lib2);
        check(
                resLegacySameOff.status
                                == TvMultiSourceStore.SiteResolution.STATUS_DISABLED_SUBSCRIPTION
                        && resLegacySameOff.subscription != null
                        && subAId2.equals(resLegacySameOff.subscription.id),
                "Disabling legacy A makes legacy 'same' prompt for A rather than opening B");

        // ---- Scenario 3: Legacy Merged (SubscriptionManager.mergeSources) Upgrade Migration ----
        File s3Dir = new File(rootDir, "scenario3_legacy_merged");
        ConfigLibrary lib3 = new ConfigLibrary(s3Dir);
        lib3.remember(rawA, "http://sub-a.test/config.json", "合并源A", "", 1000L);
        lib3.remember(rawB, "http://sub-b.test/config.json", "合并源B", "", 2000L);
        List<SubscriptionManager.SourceBundle> bundles = new ArrayList<>();
        bundles.add(
                new SubscriptionManager.SourceBundle(
                        "合并源A", "http://sub-a.test/config.json", rawA, 1000L));
        bundles.add(
                new SubscriptionManager.SourceBundle(
                        "合并源B", "http://sub-b.test/config.json", rawB, 2000L));
        SubscriptionManager.MergedResult mergedLegacy = SubscriptionManager.mergeSources(bundles);
        String legacyKeyA = "";
        String legacyKeyB = "";
        for (Cms.Site s : mergedLegacy.config.sites) {
            if ("http://sub-a.test/same".equals(s.api)) legacyKeyA = s.key;
            if ("http://sub-b.test/same".equals(s.api)) legacyKeyB = s.key;
        }
        check(
                "same".equals(legacyKeyA) && legacyKeyB.startsWith("same__"),
                "Precondition: legacy merger gave A='same' and B='same__<hash>' ("
                        + legacyKeyB
                        + ")");

        TvMultiSourceStore store3 = new TvMultiSourceStore(s3Dir);
        TvMultiSourceStore.State mig3 =
                store3.ensureMigrated(
                        lib3, mergedLegacy.config.raw, mergedLegacy.origin, legacyKeyB);
        check(
                mig3.initialized && mig3.subscriptions.size() == 2 && mig3.enabledCount() == 2,
                "Legacy merged migration restores both A and B as separate enabled cards");
        // Disable A and check BOTH legacy keys resolve to their true owners!
        String subAId3 = mig3.subscriptions.get(0).id;
        store3.setSubscriptionEnabled(subAId3, false);
        TvMultiSourceStore.EffectiveBuild build3OnlyB =
                store3.buildEffectiveConfig(lib3, "", (cfg, s) -> true);
        TvMultiSourceStore.SiteResolution r3B =
                store3.resolveStoredSiteKey(legacyKeyB, build3OnlyB.config, lib3);
        TvMultiSourceStore.SiteResolution r3A =
                store3.resolveStoredSiteKey(legacyKeyA, build3OnlyB.config, lib3);
        check(
                r3B.status == TvMultiSourceStore.SiteResolution.STATUS_ENABLED
                        && r3B.activeSite != null
                        && "http://sub-b.test/same".equals(r3B.activeSite.api),
                "Legacy merged B key ('same__<hash>') still opens B after disabling A");
        check(
                r3A.status == TvMultiSourceStore.SiteResolution.STATUS_DISABLED_SUBSCRIPTION
                        && r3A.subscription != null
                        && subAId3.equals(r3A.subscription.id),
                "Legacy merged A key ('same') points to disabled A (never cross-contaminates B)");

        // ---- Scenario 4: Unidentifiable Legacy Snapshot & Ambiguous Unaliased Key ----
        File s4Dir = new File(rootDir, "scenario4_snapshot");
        ConfigLibrary lib4 = new ConfigLibrary(s4Dir);
        Cms.Config orphanCfg = Cms.parseConfig(rawA, "");
        TvMultiSourceStore store4 = new TvMultiSourceStore(s4Dir);
        TvMultiSourceStore.State mig4 = store4.ensureMigrated(lib4, orphanCfg.raw, "", "same");
        check(
                mig4.initialized && mig4.subscriptions.size() == 1 && mig4.enabledCount() == 1,
                "Unidentifiable active snapshot is preserved as an enabled standalone card");

        // Ambiguous raw key without alias in store1 (where both A & B have 'same', no alias)
        store1Cold.setSubscriptionEnabled(recB.id, true);
        TvMultiSourceStore.EffectiveBuild build1Both =
                store1Cold.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        TvMultiSourceStore.SiteResolution ambig =
                store1Cold.resolveStoredSiteKey("same", build1Both.config, lib1);
        check(
                ambig.status == TvMultiSourceStore.SiteResolution.STATUS_AMBIGUOUS
                        && ambig.candidates.size() == 2,
                "Unaliased ambiguous key returns STATUS_AMBIGUOUS with 2 candidates instead of guessing");

        // ---- Scenario 5: Refresh Failure Preservation & Stale Revision Guard ----
        boolean failOk =
                store1Cold.refreshSingleSubscription(
                        lib1,
                        recA.id,
                        url -> {
                            throw new java.io.IOException("simulated 503");
                        },
                        5000L);
        check(!failOk, "Failed refresh returns false");
        TvMultiSourceStore.SubscriptionRecord recAAfterFail =
                store1Cold.readState().findById(recA.id);
        check(
                recAAfterFail != null
                        && recAAfterFail.lastError.contains("simulated 503")
                        && store1Cold
                                        .buildEffectiveConfig(lib1, "", (cfg, s) -> true)
                                        .config
                                        .sites
                                        .size()
                                == 4,
                "Failed refresh preserves last good snapshot and records lastError");

        // Stale revision guard: mutate state while refresh fetcher is in flight!
        boolean staleOk =
                store1Cold.refreshSingleSubscription(
                        lib1,
                        recA.id,
                        url -> {
                            store1Cold.renameSubscription(lib1, recA.id, "订阅A新名");
                            return makeSubJson("changed|不应写入|http://stale.test/api");
                        },
                        6000L);
        check(!staleOk, "Refresh interrupted by concurrent state mutation is aborted cleanly");
        TvMultiSourceStore.EffectiveBuild afterStale =
                store1Cold.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        boolean foundStale = false;
        for (Cms.Site s : afterStale.config.sites) {
            if ("http://stale.test/api".equals(s.api)) foundStale = true;
        }
        check(!foundStale, "Stale refresh payload was never committed over newer state");

        // ---- Scenario 6: Fair 500-Site Cap Across Subscriptions ----
        File s6Dir = new File(rootDir, "scenario6_cap");
        ConfigLibrary lib6 = new ConfigLibrary(s6Dir);
        TvMultiSourceStore store6 = new TvMultiSourceStore(s6Dir);
        store6.registerSubscription(
                lib6, makeLargeSubJson("bigA", 300), "http://biga.test/c.json", "大源A", true, 1L);
        store6.registerSubscription(
                lib6, makeLargeSubJson("bigB", 300), "http://bigb.test/c.json", "大源B", true, 2L);
        TvMultiSourceStore.EffectiveBuild capped =
                store6.buildEffectiveConfig(lib6, "", (cfg, s) -> true);
        int countA = 0;
        int countB = 0;
        for (Cms.Site s : capped.config.sites) {
            if (s.api.contains("bigA.test")) countA++;
            if (s.api.contains("bigB.test")) countB++;
        }
        check(
                capped.config.sites.size() == 500 && countA == 250 && countB == 250,
                "500-site cap fairly balances 300+300 as 250+250 (got "
                        + countA
                        + "+"
                        + countB
                        + ")");
    }

    private static void testPostReviewReworkCounterexamples(File rootDir) throws Exception {
        // ---- Rework 1: Raw subscription body never overwritten by runtime effective config ----
        File rw1Dir = new File(rootDir, "rework1_raw_snapshot");
        ConfigLibrary lib1 = new ConfigLibrary(rw1Dir);
        TvMultiSourceStore store1 = new TvMultiSourceStore(rw1Dir);
        String rawA = makeSubJson("keep|主线A|http://a.test/keep", "hidden|备线A|http://a.test/hidden");
        String rawB = makeSubJson("same|主线B|http://b.test/same");
        TvMultiSourceStore.SubscriptionRecord recA =
                store1.registerSubscription(
                        lib1, rawA, "https://sub-a.invalid/c.json", "订阅A", true, 100L);
        store1.setSiteDisabled(recA.id, "hidden", true);
        TvMultiSourceStore.EffectiveBuild eff1 =
                store1.buildEffectiveConfig(lib1, "", (cfg, s) -> true);
        check(
                TvMultiSourceStore.isEffectiveRuntimeConfig(eff1.config, eff1.effectiveOrigin),
                "Effective runtime config is tagged and recognized before rememberConfig");
        // Simulate SourceController.rememberConfig right before adding subscription B
        Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
        java.lang.reflect.Field fUnsafe = unsafeClass.getDeclaredField("theUnsafe");
        fUnsafe.setAccessible(true);
        Object unsafe = fUnsafe.get(null);
        MainActivity fakeAct =
                (MainActivity)
                        unsafeClass
                                .getMethod("allocateInstance", Class.class)
                                .invoke(unsafe, MainActivity.class);
        fakeAct.config = eff1.config;
        fakeAct.configOrigin = eff1.effectiveOrigin;
        SourceController.rememberConfig(fakeAct, lib1);
        store1.registerSubscription(lib1, rawB, "https://sub-b.invalid/c.json", "订阅B", true, 200L);
        List<Cms.Site> rawSitesA = store1.listSitesInSubscription(lib1, recA);
        check(rawSitesA.size() == 2, "Raw subscription A keeps both sites after append B");
        check(
                "keep".equals(rawSitesA.get(0).key) && "hidden".equals(rawSitesA.get(1).key),
                "Raw subscription A keys remain untouched without runtime ::shortId suffix");
        // Export + restore backup roundtrip preserves disabled toggle and both raw sites
        org.json.JSONObject backupMs = store1.exportStateJson();
        File rw1RestoreDir = new File(rootDir, "rework1_backup_restore");
        ConfigLibrary lib1R = new ConfigLibrary(rw1RestoreDir);
        for (ConfigLibrary.Entry e : lib1.entries()) {
            lib1R.remember(lib1.raw(e), e.origin, e.name, e.selected, e.updated);
        }
        TvMultiSourceStore store1R = new TvMultiSourceStore(rw1RestoreDir);
        store1R.restoreFromBackup(lib1R, backupMs);
        store1R.setSiteDisabled(recA.id, "hidden", false);
        TvMultiSourceStore.EffectiveBuild afterRestore =
                store1R.buildEffectiveConfig(lib1R, "", (cfg, s) -> true);
        check(
                afterRestore.config.sites.size() == 3,
                "Backup restore + re-enable hidden restores all 2 sites in A plus 1 in B");
        // Recovery test for an already-damaged legacy subscription whose ConfigLibrary index
        // points to a derived-key snapshot while an older undamaged immutable file still exists
        File rw1DmgDir = new File(rootDir, "rework1_damaged_recovery");
        ConfigLibrary libDmg = new ConfigLibrary(rw1DmgDir);
        TvMultiSourceStore storeDmg = new TvMultiSourceStore(rw1DmgDir);
        TvMultiSourceStore.SubscriptionRecord recDmg =
                storeDmg.registerSubscription(
                        libDmg, rawA, "https://dmg-a.invalid/c.json", "受损A", true, 100L);
        storeDmg.setSiteDisabled(recDmg.id, "hidden", true);
        String polluted =
                makeSubJson(
                        TvMultiSourceStore.stableSiteKey(recDmg.id, "keep")
                                + "|主线A|http://a.test/keep");
        libDmg.remember(polluted, "https://dmg-a.invalid/c.json", "受损A", "", 150L);
        boolean recovered = storeDmg.tryRecoverDamagedSubscriptionRaw(libDmg, recDmg);
        check(recovered, "Damaged subscription recovers from older immutable raw file on disk");
        check(
                storeDmg.readState().findById(recDmg.id).disabledSiteKeys.contains("hidden"),
                "Recovery preserves user disabledSiteKeys toggle");
        check(
                storeDmg.listSitesInSubscription(libDmg, recDmg).size() == 2,
                "Recovered subscription restores both original raw sites");

        // ---- Rework 2: Legacy history (single-source + merged) resumes EP02 @ 12:00 without dup
        // ----
        File rw2Dir = new File(rootDir, "rework2_history_resume");
        ConfigLibrary lib2 = new ConfigLibrary(rw2Dir);
        TvMultiSourceStore store2 = new TvMultiSourceStore(rw2Dir);
        String subASame = makeSubJson("same|同名主站|http://same-a.invalid/api");
        String subBSame = makeSubJson("same|同名主站|http://same-b.invalid/api");
        lib2.remember(subASame, "https://hist-a.invalid/c.json", "A", "");
        store2.ensureMigrated(lib2, subASame, "https://hist-a.invalid/c.json", "same");
        TvMultiSourceStore.SubscriptionRecord rec2B =
                store2.registerSubscription(
                        lib2, subBSame, "https://hist-b.invalid/c.json", "B", true, 200L);
        TvMultiSourceStore.EffectiveBuild built2 =
                store2.buildEffectiveConfig(lib2, "", (cfg, s) -> true);
        Cms.Site siteA2 = null;
        Cms.Site siteB2 = null;
        for (Cms.Site s : built2.config.sites) {
            if ("http://same-a.invalid/api".equals(s.api)) siteA2 = s;
            if ("http://same-b.invalid/api".equals(s.api)) siteB2 = s;
        }
        check(
                siteA2 != null && siteB2 != null,
                "Both colliding A and B sites built with unique keys");
        check(
                TvMultiSourceStore.siteMatchesHistoryKey(siteA2, "same"),
                "Migrated A site carries trusted legacy alias 'same'");
        check(
                !TvMultiSourceStore.siteMatchesHistoryKey(siteB2, "same"),
                "Sibling B site with colliding raw key 'same' NEVER steals A's legacy bookmark");
        WatchHistory.Entry legacyBm = new WatchHistory.Entry();
        legacyBm.site = "same";
        legacyBm.id = "vod-7";
        legacyBm.title = "同ID影片";
        legacyBm.line = "主线路";
        legacyBm.episode = "EP02";
        legacyBm.index = 1;
        legacyBm.position = 720000;
        legacyBm.duration = 3600000;
        Cms.Video vid2 = new Cms.Video();
        vid2.id = "vod-7";
        vid2.title = "同ID影片";
        check(
                PlaybackController.matchesHistoryFallbackBookmark(legacyBm, siteA2, vid2),
                "PlaybackController.matchesHistoryFallbackBookmark matches migrated A site");
        check(
                !PlaybackController.matchesHistoryFallbackBookmark(legacyBm, siteB2, vid2),
                "PlaybackController.matchesHistoryFallbackBookmark rejects sibling B site");
        WatchHistory.Entry resolvedBm =
                TvDetailHost.resolveHistoryFallbackBookmark(
                        null, WatchHistory.cloneEntry(legacyBm), siteA2, vid2);
        check(
                resolvedBm != null
                        && "EP02".equals(resolvedBm.episode)
                        && resolvedBm.resume() == 720000,
                "Detail fallback bookmark preserves EP02 @ 720000ms for migrated legacy history");
        // Progress write-back migration leaves 1 canonical entry (zero duplicates!)
        String initialHistJson = new org.json.JSONArray().put(legacyBm.json()).toString();
        WatchHistory.Entry updatedBm = WatchHistory.cloneEntry(legacyBm);
        updatedBm.site = siteA2.key;
        updatedBm.position = 725000;
        String afterWriteback =
                WatchHistory.upsertAndMigrate(initialHistJson, updatedBm, legacyBm.key());
        List<WatchHistory.Entry> histAfter = WatchHistory.read(afterWriteback);
        check(
                histAfter.size() == 1
                        && siteA2.key.equals(histAfter.get(0).site)
                        && histAfter.get(0).position == 725000,
                "Writing back progress migrates legacy key cleanly with zero duplicate entries");

        // ---- Rework 3: Disabling last VOD line + pure-live preservation + deleting last sub ----
        File rw3Dir = new File(rootDir, "rework3_last_line");
        ConfigLibrary lib3 = new ConfigLibrary(rw3Dir);
        TvMultiSourceStore store3 = new TvMultiSourceStore(rw3Dir);
        String subWithLive =
                "{\"sites\":[{\"key\":\"only\",\"name\":\"唯一线路\",\"type\":1,\"api\":\"http://only.test/api\"}],"
                        + "\"lives\":[{\"name\":\"测试直播\",\"url\":\"http://live.test/m3u\"}]}";
        TvMultiSourceStore.SubscriptionRecord rec3 =
                store3.registerSubscription(
                        lib3, subWithLive, "https://last-line.invalid/c.json", "单线含直播", true, 10L);
        store3.setSiteDisabled(rec3.id, "only", true);
        TvMultiSourceStore.EffectiveBuild warmEmpty =
                store3.buildEffectiveConfig(lib3, "", (cfg, s) -> true);
        TvMultiSourceStore store3Cold = new TvMultiSourceStore(rw3Dir);
        TvMultiSourceStore.EffectiveBuild coldEmpty =
                store3Cold.buildEffectiveConfig(lib3, "", (cfg, s) -> true);
        check(
                warmEmpty.config.sites.isEmpty()
                        && coldEmpty.config.sites.isEmpty()
                        && coldEmpty.enabledSubscriptionCount == 1
                        && coldEmpty.config.raw.contains("http://live.test/m3u"),
                "Disabling last VOD line throws zero IOException, keeps parent enabled, and preserves valid lives");
        store3Cold.setSiteDisabled(rec3.id, "only", false);
        check(
                store3Cold.buildEffectiveConfig(lib3, "", (cfg, s) -> true).config.sites.size()
                        == 1,
                "Re-enabling last VOD line restores the site cleanly");
        store3Cold.deleteSubscription(lib3, rec3.id);
        TvMultiSourceStore.EffectiveBuild afterDeleteLast =
                store3Cold.buildEffectiveConfig(lib3, "", (cfg, s) -> true);
        check(
                afterDeleteLast.totalSubscriptionCount == 0
                        && afterDeleteLast.config.sites.isEmpty(),
                "Deleting last subscription produces empty config without error");

        // ---- Rework 4: Stale build concurrency + rapid A->B->A never regresses revision ----
        File rw4Dir = new File(rootDir, "rework4_stale_build");
        ConfigLibrary lib4 = new ConfigLibrary(rw4Dir);
        TvMultiSourceStore store4 = new TvMultiSourceStore(rw4Dir);
        TvMultiSourceStore.SubscriptionRecord r4A =
                store4.registerSubscription(
                        lib4, subASame, "https://r4a.invalid/c.json", "A", true, 1L);
        TvMultiSourceStore.SubscriptionRecord r4B =
                store4.registerSubscription(
                        lib4, subBSame, "https://r4b.invalid/c.json", "B", true, 2L);
        java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch proceed = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.FutureTask<TvMultiSourceStore.EffectiveBuild> staleTask =
                new java.util.concurrent.FutureTask<>(
                        () ->
                                store4.buildEffectiveConfig(
                                        lib4,
                                        "",
                                        (cfg, s) -> {
                                            entered.countDown();
                                            try {
                                                proceed.await(
                                                        10, java.util.concurrent.TimeUnit.SECONDS);
                                            } catch (InterruptedException ignored) {
                                            }
                                            return true;
                                        }));
        Thread tStale = new Thread(staleTask);
        tStale.start();
        check(
                entered.await(10, java.util.concurrent.TimeUnit.SECONDS),
                "Concurrent stale build entered availability selection");
        // Rapid A->B->A mutations while old build is paused
        store4.setSubscriptionEnabled(r4A.id, false);
        store4.setSubscriptionEnabled(r4B.id, false);
        store4.setSubscriptionEnabled(r4A.id, true);
        long revAfterRapid = store4.currentRevision();
        proceed.countDown();
        TvMultiSourceStore.EffectiveBuild staleResult =
                staleTask.get(10, java.util.concurrent.TimeUnit.SECONDS);
        TvMultiSourceStore cold4 = new TvMultiSourceStore(rw4Dir);
        check(
                staleResult.stale,
                "Outdated build flags stale=true when revision advanced mid-flight");
        check(
                cold4.currentRevision() == revAfterRapid
                        && cold4.readState().findById(r4A.id).enabled
                        && !cold4.readState().findById(r4B.id).enabled,
                "Cold disk revision never regresses and rapid A->B->A final state persists cleanly");
    }

    private static void testSourceCodeStructuralGuards() throws Exception {
        Path tvSrc = Paths.get("android-tv/src/main/java/com/pilipala/marcomovie");
        String loadingSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("PlaybackLoading.java")),
                        StandardCharsets.UTF_8);
        String chromeSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("PlayerChrome.java")),
                        StandardCharsets.UTF_8);
        String pickerSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("SourcePicker.java")),
                        StandardCharsets.UTF_8);
        String dockSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("HomeDock.java")), StandardCharsets.UTF_8);
        String focusFrameSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("TvFocusFrame.java")),
                        StandardCharsets.UTF_8);
        String speedSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("NetworkSpeedMonitor.java")),
                        StandardCharsets.UTF_8);

        check(
                !loadingSrc.contains("测速中")
                        && !chromeSrc.contains("测速中")
                        && !speedSrc.contains("测速中"),
                "Neither PlaybackLoading, PlayerChrome, nor NetworkSpeedMonitor contains '测速中'");
        check(
                pickerSrc.contains("RecyclerView") && pickerSrc.contains("GridLayoutManager"),
                "SourcePicker uses RecyclerView + GridLayoutManager for visible-window recycling");
        check(
                pickerSrc.contains("sitesRv.setClipChildren(true)")
                        && pickerSrc.contains("sitesRv.setClipToPadding(true)")
                        && pickerSrc.contains("subsRv.setClipChildren(true)")
                        && pickerSrc.contains("subsRv.setClipToPadding(true)")
                        && pickerSrc.contains("grpScroll.setClipChildren(true)"),
                "SourcePicker clips RecyclerView & group pill scroll view so scrolled items never bleed over pills or footer");
        check(
                pickerSrc.contains("选线路") && pickerSrc.contains("管理订阅源"),
                "SourcePicker exposes both '选线路' and '管理订阅源' tabs");
        int cancelStart = dockSrc.indexOf("private void cancelTopTransition()");
        int nullIdx = dockSrc.indexOf("topTransitionAnimator = null;", cancelStart);
        int oldCancelIdx = dockSrc.indexOf("old.cancel();", cancelStart);
        check(
                cancelStart > 0 && nullIdx > cancelStart && oldCancelIdx > nullIdx,
                "HomeDock clears topTransitionAnimator before calling old.cancel() for mid-flight reversal continuity");
        check(
                focusFrameSrc.contains("hasVisibleOrActiveRing()"),
                "TvFocusFrame guards scroller.invalidate() via hasVisibleOrActiveRing()");
        String phoneCfgSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("PhoneConfigDialog.java")),
                        StandardCharsets.UTF_8);
        check(
                phoneCfgSrc.contains("FLAG_KEEP_SCREEN_ON")
                        && phoneCfgSrc.contains("acquireKeepScreenOn()")
                        && phoneCfgSrc.contains("releaseKeepScreenOn()"),
                "PhoneConfigDialog holds FLAG_KEEP_SCREEN_ON during 5-min QR pairing so TV screensaver never aborts in-flight phone push");
        String systemPlayerSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("SystemPlayer.java")),
                        StandardCharsets.UTF_8);
        String moviePlayerSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("MoviePlayer.java")),
                        StandardCharsets.UTF_8);
        String playbackCtrlSrc =
                new String(
                        Files.readAllBytes(tvSrc.resolve("PlaybackController.java")),
                        StandardCharsets.UTF_8);
        check(
                systemPlayerSrc.contains("public long networkSpeedBytesPerSec()")
                        && systemPlayerSrc.contains("return -1L;"),
                "SystemPlayer overrides networkSpeedBytesPerSec() to return -1L (unsupported counter -> UID fallback)");
        check(
                moviePlayerSrc.contains("transferCounterInstalled")
                        && moviePlayerSrc.contains("if (!transferCounterInstalled)"),
                "MoviePlayer distinguishes uninstalled transfer counter (-1L) from real measured 0 B/s");
        check(
                playbackCtrlSrc.contains("if (event.getRepeatCount() > 0)")
                        && playbackCtrlSrc.contains("a.suppressBackUpAfterSeekCancel = true"),
                "PlaybackController consumes held BACK repeat DOWN events through matching UP without leaking");
        check(
                pickerSrc.contains("class UniformSpanSizeLookup")
                        && pickerSrc.contains("class PickerShell")
                        && pickerSrc.contains("clearCachedShell"),
                "SourcePicker reuses warm PickerShell, O(1) UniformSpanSizeLookup, and clears shell on Activity destroy");
    }

    private static void testSecondRecheckReworkContracts(File rootDir) throws Exception {
        // 1. Atomic single-URL replace vs append via TvMultiSourceStore.enableOnlySubscriptions
        File r1Dir = new File(rootDir, "recheck2_replace");
        ConfigLibrary lib1 = new ConfigLibrary(r1Dir);
        TvMultiSourceStore store1 = new TvMultiSourceStore(r1Dir);
        String rawA = makeSubJson("a1|订阅A主线|http://a.invalid/1");
        String rawB = makeSubJson("b1|订阅B主线|http://b.invalid/1");
        TvMultiSourceStore.SubscriptionRecord recA =
                store1.registerSubscription(
                        lib1, rawA, "https://sub-a.invalid/a.json", "订阅A", true, 100L);
        TvMultiSourceStore.SubscriptionRecord recB =
                store1.registerSubscription(
                        lib1, rawB, "https://sub-b.invalid/b.json", "订阅B", true, 200L);
        long revBeforeReplace = store1.currentRevision();
        store1.enableOnlySubscriptions(java.util.Collections.singleton(recB.id));
        check(
                store1.currentRevision() > revBeforeReplace,
                "enableOnlySubscriptions bumps revision atomically");
        TvMultiSourceStore cold1 = new TvMultiSourceStore(r1Dir);
        TvMultiSourceStore.State st1 = cold1.readState();
        check(
                st1.enabledCount() == 1
                        && !st1.findById(recA.id).enabled
                        && st1.findById(recB.id).enabled
                        && st1.subscriptions.size() == 2,
                "Single-URL replace disables A while retaining A in library and enabling only B");

        // 2. Local JS extension persistence + deterministic deduplication on re-import
        File r2Dir = new File(rootDir, "recheck2_local_ext");
        ConfigLibrary lib2 = new ConfigLibrary(r2Dir);
        TvMultiSourceStore store2 = new TvMultiSourceStore(r2Dir);
        store2.registerSubscription(lib2, rawA, "https://sub-a.invalid/a.json", "订阅A", true, 100L);
        String jsOrigin = "file:///tmp/local_spiders/demo_ext.js";
        String jsRaw =
                "{\"sites\":[{\"key\":\"local_demo_ext\",\"name\":\"本地扩展 demo\",\"type\":3,\"api\":\"csp_Demo\",\"ext\":\""
                        + jsOrigin
                        + "\"}]}";
        TvMultiSourceStore.SubscriptionRecord jsRec1 =
                store2.registerSubscription(lib2, jsRaw, jsOrigin, "本地扩展 demo", true, 200L);
        TvMultiSourceStore.SubscriptionRecord jsRec2 =
                store2.registerSubscription(lib2, jsRaw, jsOrigin, "本地扩展 demo", true, 300L);
        check(
                jsRec1.id.equals(jsRec2.id) && store2.readState().subscriptions.size() == 2,
                "Re-importing same local JS extension updates in place without duplicate cards");
        TvMultiSourceStore cold2 = new TvMultiSourceStore(r2Dir);
        TvMultiSourceStore.EffectiveBuild built2 =
                cold2.buildEffectiveConfig(lib2, "", (cfg, s) -> true);
        check(
                built2.config.sites.size() == 2,
                "Cold restart preserves both original subscription A and local JS extension");

        // 3. Automatic recovery of damaged subscription on normal boot + race guard
        File r3Dir = new File(rootDir, "recheck2_damaged_boot");
        ConfigLibrary lib3 = new ConfigLibrary(r3Dir);
        TvMultiSourceStore store3 = new TvMultiSourceStore(r3Dir);
        String rawTwo =
                makeSubJson(
                        "keep|主线|http://dmg.invalid/keep", "hidden|隐藏|http://dmg.invalid/hidden");
        TvMultiSourceStore.SubscriptionRecord rec3 =
                store3.registerSubscription(
                        lib3, rawTwo, "https://dmg-boot.invalid/c.json", "受损源", true, 100L);
        store3.setSiteDisabled(rec3.id, "hidden", true);
        String polluted =
                makeSubJson(
                        TvMultiSourceStore.stableSiteKey(rec3.id, "keep")
                                + "|主线|http://dmg.invalid/keep");
        lib3.remember(polluted, "https://dmg-boot.invalid/c.json", "受损源", "", 150L);
        // Normal cold boot through ensureMigrated + buildEffectiveConfig (NOT direct helper call!)
        TvMultiSourceStore cold3 = new TvMultiSourceStore(r3Dir);
        cold3.ensureMigrated(lib3, polluted, "https://dmg-boot.invalid/c.json", "");
        TvMultiSourceStore.EffectiveBuild boot3 =
                cold3.buildEffectiveConfig(lib3, "", (cfg, s) -> true);
        check(
                boot3.config.sites.size() == 1
                        && cold3.readState().findById(rec3.id).disabledSiteKeys.contains("hidden")
                        && cold3.listSitesInSubscription(lib3, cold3.readState().findById(rec3.id))
                                        .size()
                                == 2,
                "Normal cold boot auto-recovers damaged subscription raw while preserving hidden toggle");
        cold3.setSiteDisabled(rec3.id, "hidden", false);
        check(
                cold3.buildEffectiveConfig(lib3, "", (cfg, s) -> true).config.sites.size() == 2,
                "Re-enabling hidden line after normal-boot auto-recovery restores both lines");

        // 4. SettingsScreen backup restore preflight (zero-enabled, enabled-zero-VOD+lives, 1-site,
        // corrupt)
        org.json.JSONArray savedSubsArr = new org.json.JSONArray();
        String liveSubRaw =
                "{\"sites\":[{\"key\":\"only\",\"name\":\"唯一线路\",\"type\":1,\"api\":\"http://only.invalid/api\"}],"
                        + "\"lives\":[{\"name\":\"测试直播\",\"url\":\"http://live.invalid/m3u\"}]}";
        File r4Dir = new File(rootDir, "recheck2_backup");
        ConfigLibrary lib4 = new ConfigLibrary(r4Dir);
        TvMultiSourceStore store4 = new TvMultiSourceStore(r4Dir);
        TvMultiSourceStore.SubscriptionRecord rec4 =
                store4.registerSubscription(
                        lib4, liveSubRaw, "https://bkp.invalid/c.json", "单线含直播", true, 100L);
        for (ConfigLibrary.Entry e : lib4.entries()) {
            org.json.JSONObject item = new org.json.JSONObject();
            item.put("id", e.id);
            item.put("url", e.origin);
            item.put("name", e.name);
            item.put("rawContent", lib4.raw(e));
            item.put("enabled", true);
            item.put("isPrivate", false);
            savedSubsArr.put(item);
        }
        // Case 4a: All subscriptions disabled -> 0 sites in config
        store4.setSubscriptionEnabled(rec4.id, false);
        TvMultiSourceStore.EffectiveBuild b4Zero =
                store4.buildEffectiveConfig(lib4, "", (cfg, s) -> true);
        org.json.JSONObject backupZeroEnabled =
                new org.json.JSONObject()
                        .put("format", "MarcoMovie-1")
                        .put("schema", "marco-movie-backup")
                        .put("version", 1)
                        .put("config", b4Zero.config.raw);
        org.json.JSONObject s4a = new org.json.JSONObject();
        s4a.put("saved_subscriptions", savedSubsArr);
        s4a.put("tv_multi_source_state", store4.exportStateJson());
        backupZeroEnabled.put("settings", s4a);
        SettingsScreen.BackupRestorePlan planZeroEnabled =
                SettingsScreen.validateBackupForRestore(backupZeroEnabled, true);
        check(
                planZeroEnabled.usesMultiSourceRestore()
                        && planZeroEnabled.savedSubscriptions.length() == 1
                        && planZeroEnabled.multiSourceState != null,
                "SettingsScreen backup preflight accepts valid multi-source backup with all subs disabled");

        // Case 4b: Parent enabled, only VOD line disabled, lives preserved -> 0 VOD sites in config
        store4.setSubscriptionEnabled(rec4.id, true);
        store4.setSiteDisabled(rec4.id, "only", true);
        TvMultiSourceStore.EffectiveBuild b4ParentZero =
                store4.buildEffectiveConfig(lib4, "", (cfg, s) -> true);
        org.json.JSONObject backupParentZero =
                new org.json.JSONObject()
                        .put("format", "MarcoMovie-1")
                        .put("schema", "marco-movie-backup")
                        .put("version", 1)
                        .put("config", b4ParentZero.config.raw);
        org.json.JSONObject s4b = new org.json.JSONObject();
        s4b.put("saved_subscriptions", savedSubsArr);
        s4b.put("tv_multi_source_state", store4.exportStateJson());
        backupParentZero.put("settings", s4b);
        SettingsScreen.BackupRestorePlan planParentZero =
                SettingsScreen.validateBackupForRestore(backupParentZero, true);
        check(
                planParentZero.usesMultiSourceRestore()
                        && planParentZero.configJson.contains("http://live.invalid/m3u"),
                "SettingsScreen backup preflight accepts enabled-parent zero-VOD backup preserving lives");

        // Case 4c: 1 active site control
        store4.setSiteDisabled(rec4.id, "only", false);
        TvMultiSourceStore.EffectiveBuild b4One =
                store4.buildEffectiveConfig(lib4, "", (cfg, s) -> true);
        org.json.JSONObject backupOne =
                new org.json.JSONObject()
                        .put("format", "MarcoMovie-1")
                        .put("schema", "marco-movie-backup")
                        .put("version", 1)
                        .put("config", b4One.config.raw);
        org.json.JSONObject s4c = new org.json.JSONObject();
        s4c.put("saved_subscriptions", savedSubsArr);
        s4c.put("tv_multi_source_state", store4.exportStateJson());
        backupOne.put("settings", s4c);
        SettingsScreen.BackupRestorePlan planOne =
                SettingsScreen.validateBackupForRestore(backupOne, true);
        check(
                planOne.usesMultiSourceRestore() && planOne.savedSubscriptions.length() == 1,
                "SettingsScreen backup preflight accepts 1-active-site control backup");

        // Case 4d: Corrupted backups must fail preflight before mutating anything
        boolean rejectedEmptySingle = false;
        try {
            org.json.JSONObject badSingle =
                    new org.json.JSONObject()
                            .put("format", "MarcoMovie-1")
                            .put("schema", "marco-movie-backup")
                            .put("version", 1)
                            .put("config", "{\"sites\":[]}");
            SettingsScreen.validateBackupForRestore(badSingle, true);
        } catch (Exception expected) {
            rejectedEmptySingle = true;
        }
        check(
                rejectedEmptySingle,
                "Ordinary single-source backup with empty sites is still rejected cleanly");
        boolean rejectedMissingSaved = false;
        try {
            org.json.JSONObject sBadMs = new org.json.JSONObject();
            sBadMs.put("saved_subscriptions", new org.json.JSONArray());
            sBadMs.put("tv_multi_source_state", store4.exportStateJson());
            org.json.JSONObject badMs =
                    new org.json.JSONObject()
                            .put("format", "MarcoMovie-1")
                            .put("schema", "marco-movie-backup")
                            .put("version", 1)
                            .put("config", b4Zero.config.raw)
                            .put("settings", sBadMs);
            SettingsScreen.validateBackupForRestore(badMs, true);
        } catch (Exception expected) {
            rejectedMissingSaved = true;
        }
        check(
                rejectedMissingSaved,
                "Multi-source backup missing referenced saved_subscriptions raw is rejected before mutation");

        // 5. setCurrentSite concurrency revision guard against stale background build
        File r5Dir = new File(rootDir, "recheck2_selection_race");
        ConfigLibrary lib5 = new ConfigLibrary(r5Dir);
        TvMultiSourceStore store5 = new TvMultiSourceStore(r5Dir);
        TvMultiSourceStore.SubscriptionRecord s5A =
                store5.registerSubscription(
                        lib5, rawA, "https://race-a.invalid/c.json", "A", true, 1L);
        TvMultiSourceStore.SubscriptionRecord s5B =
                store5.registerSubscription(
                        lib5, rawB, "https://race-b.invalid/c.json", "B", true, 2L);
        store5.setCurrentSite(TvMultiSourceStore.stableSiteKey(s5A.id, "a1"), s5A.id, "a1");
        final java.util.concurrent.CountDownLatch raceIn =
                new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch raceGo =
                new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.FutureTask<TvMultiSourceStore.EffectiveBuild> oldBuildTask =
                new java.util.concurrent.FutureTask<>(
                        () ->
                                store5.buildEffectiveConfig(
                                        lib5,
                                        "",
                                        (cfg, s) -> {
                                            raceIn.countDown();
                                            try {
                                                raceGo.await(
                                                        10, java.util.concurrent.TimeUnit.SECONDS);
                                            } catch (InterruptedException ignored) {
                                            }
                                            return true;
                                        }));
        new Thread(oldBuildTask).start();
        check(raceIn.await(10, java.util.concurrent.TimeUnit.SECONDS), "Stale build entered latch");
        long revBeforeSelect = store5.currentRevision();
        store5.setCurrentSite(TvMultiSourceStore.stableSiteKey(s5B.id, "b1"), s5B.id, "b1");
        check(
                store5.currentRevision() > revBeforeSelect,
                "setCurrentSite bumps revision so concurrent builds detect user selection");
        raceGo.countDown();
        TvMultiSourceStore.EffectiveBuild raceRes =
                oldBuildTask.get(10, java.util.concurrent.TimeUnit.SECONDS);
        TvMultiSourceStore cold5 = new TvMultiSourceStore(r5Dir);
        TvMultiSourceStore.State cold5St = cold5.readState();
        check(
                raceRes.stale
                        && s5B.id.equals(cold5St.currentSubscriptionId)
                        && "b1".equals(cold5St.currentRawSiteKey)
                        && cold5St.findById(s5A.id).enabled
                        && cold5St.findById(s5B.id).enabled,
                "Stale background build is marked stale=true, disk keeps B, and A/B enabled flags stay intact");

        // 6. ProxyAddress.isInProcessMediaProxy strict host/port/path matching
        check(
                !ProxyAddress.isInProcessMediaProxy("https://cdn.example.com/live/video.mp4", 9978)
                        && !ProxyAddress.isInProcessMediaProxy(
                                "https://cdn.example.com/hls?sid=abc123", 9978)
                        && !ProxyAddress.isInProcessMediaProxy(
                                "http://cdn.example.com/kcache/item1", 9978)
                        && !ProxyAddress.isInProcessMediaProxy(
                                "https://cdn.example.com/play.mp4?ref=/kcache/item1&x=/hls?sid=1",
                                9978)
                        && !ProxyAddress.isInProcessMediaProxy(
                                "http://127.0.0.1:8888/kcache/item1", 9978)
                        && !ProxyAddress.isInProcessMediaProxy("file:///sdcard/movie.mp4", 9978)
                        && ProxyAddress.isInProcessMediaProxy(
                                "http://127.0.0.1:9978/kcache/item1", 9978)
                        && ProxyAddress.isInProcessMediaProxy(
                                "http://127.0.0.1:9978/hls?sid=abc123", 9978)
                        && ProxyAddress.isInProcessMediaProxy(
                                "http://localhost:19978/hls?foo=1&sid=xyz", 19978),
                "ProxyAddress.isInProcessMediaProxy matches only actual bound loopback host+port+path");

        // 7. PinyinKeyboardModel cached shared dictionary reuse
        String miniTsv = "# header\nni\t你尼\nhao\t好号\n";
        PinyinKeyboardModel.warmSharedDictionary(
                new java.io.ByteArrayInputStream(miniTsv.getBytes(StandardCharsets.UTF_8)));
        PinyinKeyboardModel km1 = PinyinKeyboardModel.fromWarmSharedDictionary();
        PinyinKeyboardModel km2 = PinyinKeyboardModel.fromWarmSharedDictionary();
        km1.input("ni");
        check(
                !km1.candidates().isEmpty()
                        && km2.composition().isEmpty()
                        && km1.dictionary == km2.dictionary,
                "PinyinKeyboardModel shares cached immutable dictionary across instances with isolated input state");
    }

    private static String padJsonToExactUtf8Bytes(String baseJson, int targetBytes) {
        int baseLen = Cms.utf8ByteLength(baseJson);
        if (targetBytes < baseLen) {
            throw new IllegalArgumentException("targetBytes < baseLen");
        }
        int pad = targetBytes - baseLen;
        char[] spaces = new char[pad];
        java.util.Arrays.fill(spaces, ' ');
        return "{" + new String(spaces) + baseJson.substring(1);
    }

    private static void testThirdRecheckReworkContracts(File rootDir) throws Exception {
        // 1. Unified 16 MiB UTF-8 byte boundary + write/readback verification before index/state
        // commit
        File b1Dir = new File(rootDir, "recheck3_size_boundaries");
        ConfigLibrary lib1 = new ConfigLibrary(b1Dir);
        TvMultiSourceStore store1 = new TvMultiSourceStore(b1Dir);
        String baseOld =
                "{\"sites\":[{\"key\":\"old1\",\"name\":\"旧源线路\",\"type\":1,\"api\":\"https://old.invalid/api\"}]}";
        String baseNew =
                "{\"sites\":[{\"key\":\"new1\",\"name\":\"新源线路\",\"type\":1,\"api\":\"https://new.invalid/api\"}]}";
        TvMultiSourceStore.SubscriptionRecord oldRec =
                store1.registerSubscription(
                        lib1, baseOld, "https://old-bound.invalid/c.json", "旧源", true, 1L);

        // 1a: Below 4 MiB, exact 4 MiB (4,194,304 B), just over 4 MiB (4,194,399 B), exact 16 MiB
        int[] validSizes = {4 * 1024 * 1024 - 1, 4 * 1024 * 1024, 4194399, Cms.MAX_JSON};
        for (int idx = 0; idx < validSizes.length; idx++) {
            int sz = validSizes[idx];
            String url = "https://valid-" + idx + ".invalid/c.json";
            String payload = padJsonToExactUtf8Bytes(baseNew, sz);
            check(
                    payload.getBytes(StandardCharsets.UTF_8).length == sz,
                    "Constructed exact UTF-8 byte payload (" + sz + " B)");
            TvMultiSourceStore.SubscriptionRecord repRec =
                    store1.importSubscriptionAtomic(
                            lib1, payload, url, "有效大源" + idx, false, true, 10L + idx);
            TvMultiSourceStore cold = new TvMultiSourceStore(b1Dir);
            TvMultiSourceStore.EffectiveBuild eb = cold.buildEffectiveConfig(lib1, "", null);
            check(
                    cold.readState().enabledCount() == 1
                            && cold.readState().findById(repRec.id).enabled
                            && !cold.readState().findById(oldRec.id).enabled
                            && eb.config.sites.size() == 1
                            && "new1"
                                    .equals(
                                            TvMultiSourceStore.extractRawKeyFromStable(
                                                    eb.config.sites.get(0).key)),
                    "Replace succeeds & survives cold read at " + sz + " B");
            boolean refOk =
                    cold.refreshSingleSubscription(lib1, repRec.id, ignored -> payload, 50L + idx);
            TvMultiSourceStore coldRef = new TvMultiSourceStore(b1Dir);
            TvMultiSourceStore.EffectiveBuild ebRef = coldRef.buildEffectiveConfig(lib1, "", null);
            check(
                    refOk && ebRef.config.sites.size() == 1,
                    "Refresh succeeds & survives cold read at " + sz + " B");
        }

        // 1b: Over 16 MiB (16 MiB + 1 B ASCII, AND multibyte UTF-8 where char.length < 16 MiB but
        // UTF-8 bytes > 16 MiB) must fail BEFORE modifying index or disabling existing source!
        store1.enableOnlySubscriptions(java.util.Collections.singleton(oldRec.id));
        String overAscii = padJsonToExactUtf8Bytes(baseNew, Cms.MAX_JSON + 1);
        boolean replaceAsciiRejected = false;
        try {
            store1.importSubscriptionAtomic(
                    lib1,
                    overAscii,
                    "https://over-ascii.invalid/c.json",
                    "超限ASCII",
                    false,
                    true,
                    99L);
        } catch (java.io.IOException expected) {
            replaceAsciiRejected = true;
        }
        check(
                replaceAsciiRejected
                        && store1.readState().findById(oldRec.id).enabled
                        && new TvMultiSourceStore(b1Dir)
                                        .buildEffectiveConfig(lib1, "", null)
                                        .config
                                        .sites
                                        .size()
                                == 1,
                "Replace >16 MiB ASCII fails cleanly while preserving enabled old catalog");

        // Multibyte UTF-8: 6,000,000 CJK chars => 6,000,000 chars < 16M, but 18,000,000 UTF-8 bytes
        // > 16 MiB
        char[] cjkPad = new char[5_600_000];
        java.util.Arrays.fill(cjkPad, '中');
        String overUtf8 =
                "{\"note\":\""
                        + new String(cjkPad)
                        + "\",\"sites\":[{\"key\":\"u1\",\"name\":\"U1\",\"type\":1,\"api\":\"https://u.invalid/api\"}]}";
        check(
                overUtf8.length() < Cms.MAX_JSON && Cms.utf8ByteLength(overUtf8) > Cms.MAX_JSON,
                "Multibyte UTF-8 payload has char length < 16 MiB but UTF-8 bytes > 16 MiB");
        boolean parseUtf8Rejected = false;
        try {
            Cms.parseConfig(overUtf8, "https://over-utf8.invalid/c.json");
        } catch (java.io.IOException expected) {
            parseUtf8Rejected = true;
        }
        boolean refreshOverRejected =
                !store1.refreshSingleSubscription(lib1, oldRec.id, ignored -> overAscii, 100L);
        boolean refreshUtf8Rejected =
                !store1.refreshSingleSubscription(lib1, oldRec.id, ignored -> overUtf8, 101L);
        TvMultiSourceStore coldAfterOversize = new TvMultiSourceStore(b1Dir);
        check(
                parseUtf8Rejected
                        && refreshOverRejected
                        && refreshUtf8Rejected
                        && coldAfterOversize.readState().findById(oldRec.id).enabled
                        && coldAfterOversize
                                        .buildEffectiveConfig(lib1, "", null)
                                        .config
                                        .sites
                                        .size()
                                == 1,
                "Multibyte >16 MiB & oversized refresh both rejected while old catalog stays working");

        // 2. Damaged subscription recovery chooses latest clean generation (both with cleanHistory
        // AND on legacy index without cleanHistory), never resurrecting withdrawn lines!
        for (int pass = 0; pass < 2; pass++) {
            boolean stripCleanHistory = (pass == 1);
            File b2Dir = new File(rootDir, "recheck3_recovery_gen_" + pass);
            ConfigLibrary lib2 = new ConfigLibrary(b2Dir);
            TvMultiSourceStore store2 = new TvMultiSourceStore(b2Dir);
            String v1Raw =
                    "{\"sites\":["
                            + "{\"key\":\"keep\",\"name\":\"KeepV1\",\"type\":1,\"api\":\"https://v1.invalid/keep\"},"
                            + "{\"key\":\"withdrawn1\",\"name\":\"撤回1\",\"type\":1,\"api\":\"https://v1.invalid/w1\"},"
                            + "{\"key\":\"withdrawn2\",\"name\":\"撤回2\",\"type\":1,\"api\":\"https://v1.invalid/w2\"}"
                            + "]}";
            String v2Raw =
                    "{\"sites\":["
                            + "{\"key\":\"keep\",\"name\":\"KeepV2\",\"type\":1,\"api\":\"https://v2.invalid/keep\"},"
                            + "{\"key\":\"newLine\",\"name\":\"新增线路\",\"type\":1,\"api\":\"https://v2.invalid/new\"}"
                            + "]}";
            TvMultiSourceStore.SubscriptionRecord rec2 =
                    store2.registerSubscription(
                            lib2, v1Raw, "https://gen-test.invalid/c.json", "版本源", true, 1L);
            ConfigLibrary.Entry eV1 = lib2.entries().get(0);
            ConfigLibrary.Entry eV2 = lib2.remember(v2Raw, rec2.origin, rec2.name, "", 2L);
            store2.setSiteDisabled(rec2.id, "newLine", true);
            TvMultiSourceStore.EffectiveBuild filtered =
                    store2.buildEffectiveConfig(lib2, "", null);
            ConfigLibrary.Entry eDmg =
                    lib2.remember(filtered.config.raw, rec2.origin, rec2.name, "", 3L);
            // Set explicit chronological mtimes: v1 < v2 < damaged
            lib2.contentFile(eV1).setLastModified(1700000000000L);
            lib2.contentFile(eV2).setLastModified(1700000010000L);
            lib2.contentFile(eDmg).setLastModified(1700000020000L);
            if (stripCleanHistory) {
                File idxFile = new File(lib2.directory, "index.json");
                org.json.JSONArray arr =
                        new org.json.JSONArray(
                                new String(
                                        Files.readAllBytes(idxFile.toPath()),
                                        StandardCharsets.UTF_8));
                arr.getJSONObject(0).remove("cleanHistory");
                Files.write(idxFile.toPath(), arr.toString().getBytes(StandardCharsets.UTF_8));
            }
            TvMultiSourceStore cold2 = new TvMultiSourceStore(b2Dir);
            TvMultiSourceStore.EffectiveBuild boot2 = cold2.buildEffectiveConfig(lib2, "", null);
            java.util.List<Cms.Site> mgrSites = cold2.listSitesInSubscription(lib2, rec2);
            java.util.List<String> mgrKeys = new java.util.ArrayList<>();
            String keepApi = "";
            for (Cms.Site s : mgrSites) {
                mgrKeys.add(s.key);
                if ("keep".equals(s.key)) keepApi = s.api;
            }
            cold2.setSiteDisabled(rec2.id, "newLine", false);
            TvMultiSourceStore.EffectiveBuild unhidden2 =
                    cold2.buildEffectiveConfig(lib2, "", null);
            boolean hasNewLine = false;
            boolean hasWithdrawn = false;
            for (Cms.Site s : unhidden2.config.sites) {
                String rk = TvMultiSourceStore.extractRawKeyFromStable(s.key);
                if ("newLine".equals(rk)) hasNewLine = true;
                if (rk.startsWith("withdrawn")) hasWithdrawn = true;
            }
            check(
                    boot2.config.sites.size() == 1
                            && mgrKeys.equals(java.util.Arrays.asList("keep", "newLine"))
                            && "https://v2.invalid/keep".equals(keepApi)
                            && hasNewLine
                            && !hasWithdrawn
                            && lib2.entries().get(0).digest.equals(eV2.digest),
                    "Damaged recovery picks v2 (keep+newLine, updated API, no withdrawn) "
                            + (stripCleanHistory ? "[legacy mtime path]" : "[cleanHistory chain]"));
        }

        // 3. Settings backup round-trip: unified 64 MiB capacity, corrupt member rejection, missing
        // ID rejection
        File b3Dir = new File(rootDir, "recheck3_backup_contracts");
        ConfigLibrary lib3 = new ConfigLibrary(b3Dir);
        TvMultiSourceStore store3 = new TvMultiSourceStore(b3Dir);
        StringBuilder pad3m = new StringBuilder(3 * 1024 * 1024);
        for (int i = 0; i < 3 * 1024 * 1024; i++) pad3m.append('a');
        String note3m = pad3m.toString();
        for (int i = 0; i < 6; i++) {
            org.json.JSONObject siteObj =
                    new org.json.JSONObject()
                            .put("key", "big_" + i)
                            .put("name", "大订阅" + i)
                            .put("type", 1)
                            .put("api", "https://big-" + i + ".invalid/api");
            String subRaw =
                    new org.json.JSONObject()
                            .put("note", note3m)
                            .put("sites", new org.json.JSONArray().put(siteObj))
                            .toString();
            TvMultiSourceStore.SubscriptionRecord r =
                    store3.registerSubscription(
                            lib3,
                            subRaw,
                            "https://big-" + i + ".invalid/c.json",
                            "大源" + i,
                            true,
                            1L + i);
            if (i == 5) store3.setSubscriptionEnabled(r.id, false);
        }
        // Build archive using real production structure & encode/read helpers
        org.json.JSONArray saved6 = new org.json.JSONArray();
        for (ConfigLibrary.Entry e : lib3.entries()) {
            saved6.put(
                    new org.json.JSONObject()
                            .put("id", e.id)
                            .put("name", e.name)
                            .put("url", e.origin)
                            .put("rawContent", lib3.raw(e))
                            .put("enabled", true)
                            .put("isPrivate", false));
        }
        org.json.JSONObject ms6 = store3.exportStateJsonStrict();
        org.json.JSONObject backup6 =
                new org.json.JSONObject()
                        .put("format", "MarcoMovie-1")
                        .put("schema", "marco-movie-backup")
                        .put("version", 1)
                        .put("config", store3.buildEffectiveConfig(lib3, "", null).config.raw)
                        .put(
                                "settings",
                                new org.json.JSONObject()
                                        .put("saved_subscriptions", saved6)
                                        .put("tv_multi_source_state", ms6));
        byte[] encoded6 = SettingsScreen.encodeBackupBytes(backup6);
        check(
                encoded6.length > Cms.MAX_JSON
                        && encoded6.length <= SettingsScreen.MAX_BACKUP_BYTES,
                "6x3MiB backup ("
                        + encoded6.length
                        + " B) exceeds 16 MiB yet fits unified 64 MiB limit");
        org.json.JSONObject decoded6 =
                SettingsScreen.readBackupJson(new java.io.ByteArrayInputStream(encoded6));
        SettingsScreen.BackupRestorePlan plan6 =
                SettingsScreen.validateBackupForRestore(decoded6, true);
        File b3RestoreDir = new File(rootDir, "recheck3_backup_restore_target");
        ConfigLibrary lib3R = new ConfigLibrary(b3RestoreDir);
        TvMultiSourceStore store3R = new TvMultiSourceStore(b3RestoreDir);
        for (int i = 0; i < plan6.savedSubscriptions.length(); i++) {
            org.json.JSONObject sub = plan6.savedSubscriptions.getJSONObject(i);
            lib3R.remember(
                    sub.getString("rawContent"), sub.getString("url"), sub.getString("name"), "");
        }
        store3R.restoreFromBackup(lib3R, plan6.multiSourceState);
        TvMultiSourceStore cold3R = new TvMultiSourceStore(b3RestoreDir);
        TvMultiSourceStore.State st3R = cold3R.readState();
        TvMultiSourceStore.EffectiveBuild eb3R = cold3R.buildEffectiveConfig(lib3R, "", null);
        check(
                st3R.subscriptions.size() == 6
                        && st3R.enabledCount() == 5
                        && eb3R.config.sites.size() == 5,
                "6x3MiB backup round-trips cleanly through readBackupJson + validate + cold restore");

        // 3b: Missing ID in tv_multi_source_state must be rejected BEFORE mutating local data
        org.json.JSONObject badIdBackup = new org.json.JSONObject(decoded6.toString());
        badIdBackup
                .getJSONObject("settings")
                .getJSONObject("tv_multi_source_state")
                .getJSONArray("subscriptions")
                .getJSONObject(1)
                .remove("id");
        boolean missingIdRejected = false;
        try {
            SettingsScreen.validateBackupForRestore(badIdBackup, true);
        } catch (Exception expected) {
            missingIdRejected = true;
        }
        boolean restoreMissingIdRejected = false;
        try {
            store3R.restoreFromBackup(
                    lib3R,
                    badIdBackup.getJSONObject("settings").getJSONObject("tv_multi_source_state"));
        } catch (Exception expected) {
            restoreMissingIdRejected = true;
        }
        check(
                missingIdRejected
                        && restoreMissingIdRejected
                        && new TvMultiSourceStore(b3RestoreDir).readState().subscriptions.size()
                                == 6,
                "Backup state record missing ID is rejected by both preflight and restoreFromBackup without data loss");

        // 3c: Duplicate ID rejected
        org.json.JSONObject dupIdBackup = new org.json.JSONObject(decoded6.toString());
        org.json.JSONArray dupSubs =
                dupIdBackup
                        .getJSONObject("settings")
                        .getJSONObject("tv_multi_source_state")
                        .getJSONArray("subscriptions");
        dupSubs.getJSONObject(1).put("id", dupSubs.getJSONObject(0).getString("id"));
        boolean dupIdRejected = false;
        try {
            SettingsScreen.validateBackupForRestore(dupIdBackup, true);
        } catch (Exception expected) {
            dupIdRejected = true;
        }
        check(dupIdRejected, "Backup state with duplicate subscription ID is rejected cleanly");

        // 3d: Over MAX_BACKUP_BYTES rejected on readBackupJson
        boolean overBackupReadRejected = false;
        try {
            java.io.InputStream fakeHuge =
                    new java.io.InputStream() {
                        long remaining = SettingsScreen.MAX_BACKUP_BYTES + 1024L;

                        @Override
                        public int read() {
                            if (remaining <= 0) return -1;
                            remaining--;
                            return ' ';
                        }

                        @Override
                        public int read(byte[] b, int off, int len) {
                            if (remaining <= 0) return -1;
                            int n = (int) Math.min(len, remaining);
                            java.util.Arrays.fill(b, off, off + n, (byte) ' ');
                            remaining -= n;
                            return n;
                        }
                    };
            SettingsScreen.readBackupJson(fakeHuge);
        } catch (java.io.IOException expected) {
            overBackupReadRejected = true;
        }
        check(
                overBackupReadRejected,
                "Backup stream exceeding 64 MiB MAX_BACKUP_BYTES is rejected");
    }

    private static MainActivity makeMockActivity(File root) throws Exception {
        Class<?> u = Class.forName("sun.misc.Unsafe");
        java.lang.reflect.Field f = u.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        MainActivity act =
                (MainActivity)
                        u.getMethod("allocateInstance", Class.class)
                                .invoke(f.get(null), MainActivity.class);
        act.formFactor = TvLayoutPolicy.FORM_TV;
        act.prefs =
                (android.content.SharedPreferences)
                        java.lang.reflect.Proxy.newProxyInstance(
                                TvPlaybackMultiSourceChecks.class.getClassLoader(),
                                new Class<?>[] {android.content.SharedPreferences.class},
                                (proxy, m, args) -> {
                                    if ("contains".equals(m.getName())) return false;
                                    if ("edit".equals(m.getName())) return null;
                                    if ("getAll".equals(m.getName())) {
                                        return java.util.Collections.emptyMap();
                                    }
                                    return (args != null && args.length > 1) ? args[1] : null;
                                });
        act.configStore = new ConfigStore(root);
        act.multiSourceStore = new TvMultiSourceStore(root);
        return act;
    }

    private static void testFourthRecheckReworkContracts(File tmpRoot) throws Exception {
        // 1. Atomic backup restore rollback on 2nd subscription write failure + commit interruption
        //    + same-URL different-ID identity conflict + normal overwrite + all-disabled restore
        File r4Dir = new File(tmpRoot, "r4_rework");
        r4Dir.mkdirs();

        // 1a. Export A_new + B_new from source library
        File srcDir = new File(r4Dir, "src_ab");
        srcDir.mkdirs();
        MainActivity srcAct = makeMockActivity(srcDir);
        ConfigLibrary srcLib = new ConfigLibrary(srcDir);
        String newARaw =
                "{\"sites\":[{\"key\":\"newA\",\"name\":\"新线路A\",\"type\":1,\"api\":\"https://new.invalid/a\"}]}";
        String newBRaw =
                "{\"sites\":[{\"key\":\"newB\",\"name\":\"新线路B\",\"type\":1,\"api\":\"https://new.invalid/b\"}]}";
        srcAct.multiSourceStore.registerSubscription(
                srcLib, newARaw, "https://r4.invalid/A", "订阅A新", true, 100L);
        srcAct.multiSourceStore.registerSubscription(
                srcLib, newBRaw, "https://r4.invalid/B", "订阅B新", true, 101L);
        TvMultiSourceStore.EffectiveBuild srcBuilt =
                srcAct.multiSourceStore.buildEffectiveConfig(srcLib, "", null);
        srcAct.config = srcBuilt.config;
        srcAct.configOrigin = srcBuilt.effectiveOrigin;
        byte[] newBackupBytes = SettingsScreen.exportBackupBytes(srcAct);
        SettingsScreen.BackupRestorePlan newPlan =
                SettingsScreen.validateBackupForRestore(
                        SettingsScreen.readBackupJson(new ByteArrayInputStream(newBackupBytes)),
                        true);

        // 1b. Seed target with A_old + B_old (B_old disabled), inject directory obstacle on B_new
        File dstPartial = new File(r4Dir, "dst_partial");
        dstPartial.mkdirs();
        MainActivity dstAct = makeMockActivity(dstPartial);
        ConfigLibrary dstLib = new ConfigLibrary(dstPartial);
        String oldARaw =
                "{\"sites\":[{\"key\":\"oldA\",\"name\":\"旧线路A\",\"type\":1,\"api\":\"https://old.invalid/a\"}]}";
        String oldBRaw =
                "{\"sites\":[{\"key\":\"oldB\",\"name\":\"旧线路B\",\"type\":1,\"api\":\"https://old.invalid/b\"}]}";
        TvMultiSourceStore.SubscriptionRecord recOldA =
                dstAct.multiSourceStore.registerSubscription(
                        dstLib, oldARaw, "https://r4.invalid/A", "订阅A旧", true, 10L);
        TvMultiSourceStore.SubscriptionRecord recOldB =
                dstAct.multiSourceStore.registerSubscription(
                        dstLib, oldBRaw, "https://r4.invalid/B", "订阅B旧", false, 11L);
        String oldADigest = ConfigLibrary.hash(oldARaw);
        String oldBDigest = ConfigLibrary.hash(oldBRaw);
        File bObstacle =
                new File(
                        dstLib.directory,
                        ConfigLibrary.identity("https://r4.invalid/B", newBRaw)
                                + "-"
                                + ConfigLibrary.hash(newBRaw)
                                + ".json");
        bObstacle.mkdirs();
        Files.write(new File(bObstacle, "lock").toPath(), new byte[] {1});

        boolean partialThrew = false;
        try {
            SettingsScreen.applyBackupRestore(dstAct, newPlan);
        } catch (Exception expected) {
            partialThrew = true;
        }
        check(
                partialThrew,
                "R4.1: Restore fails explicitly when 2nd subscription cannot be written");
        TvMultiSourceStore coldPartial = new TvMultiSourceStore(dstPartial);
        ConfigLibrary coldPartialLib = new ConfigLibrary(dstPartial);
        TvMultiSourceStore.State stPartial = coldPartial.readState();
        TvMultiSourceStore.EffectiveBuild bPartial =
                coldPartial.buildEffectiveConfig(coldPartialLib, "", null);
        check(
                stPartial.findById(recOldA.id).enabled && !stPartial.findById(recOldB.id).enabled,
                "R4.1: Failed 2nd-member restore preserves exact original enabled/disabled switches");
        check(
                oldADigest.equals(coldPartialLib.entries().get(0).digest)
                        && oldBDigest.equals(coldPartialLib.entries().get(1).digest),
                "R4.1: Failed 2nd-member restore preserves exact original raw digests for A and B");
        check(
                bPartial.config.sites.size() == 1
                        && "https://old.invalid/a".equals(bPartial.config.sites.get(0).api),
                "R4.1: Cold boot after failed 2nd-member restore serves oldA API (never partial newA)");

        // 1c. Commit interruption (simulated abrupt process death after writing index.json)
        File dstInterrupt = new File(r4Dir, "dst_interrupt");
        dstInterrupt.mkdirs();
        MainActivity intAct = makeMockActivity(dstInterrupt);
        ConfigLibrary intLib = new ConfigLibrary(dstInterrupt);
        TvMultiSourceStore.SubscriptionRecord intOldA =
                intAct.multiSourceStore.registerSubscription(
                        intLib, oldARaw, "https://r4.invalid/A", "订阅A旧", true, 20L);
        TvMultiSourceStore.SubscriptionRecord intOldB =
                intAct.multiSourceStore.registerSubscription(
                        intLib, oldBRaw, "https://r4.invalid/B", "订阅B旧", true, 21L);
        intAct.multiSourceStore.setSiteDisabled(intOldB.id, "oldB", true);
        intAct.multiSourceStore.buildEffectiveConfig(intLib, "", null);
        boolean killThrown = false;
        try {
            ConfigLibrary.restoreCommitFaultInjector =
                    step -> {
                        if ("state".equals(step)) {
                            throw new ConfigLibrary.SimulatedProcessKill("simulated power loss");
                        }
                    };
            SettingsScreen.applyBackupRestore(intAct, newPlan);
        } catch (ConfigLibrary.SimulatedProcessKill expected) {
            killThrown = true;
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
        }
        check(killThrown, "R4.1: Simulated mid-commit process kill interrupted after index write");
        TvMultiSourceStore coldInt = new TvMultiSourceStore(dstInterrupt);
        ConfigLibrary coldIntLib = new ConfigLibrary(dstInterrupt);
        TvMultiSourceStore.State stInt = coldInt.readState();
        TvMultiSourceStore.EffectiveBuild bInt = coldInt.buildEffectiveConfig(coldIntLib, "", null);
        check(
                oldADigest.equals(coldIntLib.entries().get(0).digest)
                        && oldBDigest.equals(coldIntLib.entries().get(1).digest)
                        && stInt.findById(intOldB.id).disabledSiteKeys.contains("oldB")
                        && bInt.config.sites.size() == 1
                        && "https://old.invalid/a".equals(bInt.config.sites.get(0).api),
                "R4.1: Cold boot after mid-commit kill automatically rolls back index, state, switches & routes");

        // 1d. Normal overwrite succeeds after clean apply
        SettingsScreen.applyBackupRestore(intAct, newPlan);
        TvMultiSourceStore coldOk = new TvMultiSourceStore(dstInterrupt);
        TvMultiSourceStore.EffectiveBuild bOk =
                coldOk.buildEffectiveConfig(new ConfigLibrary(dstInterrupt), "", null);
        check(
                bOk.config.sites.size() == 2
                        && "https://new.invalid/a".equals(bOk.config.sites.get(0).api)
                        && "https://new.invalid/b".equals(bOk.config.sites.get(1).api),
                "R4.1: Normal backup overwrite commits newA and newB atomically");

        // 1e. Same-URL different-declared-ID identity conflict rejected in preflight
        org.json.JSONObject conflictJson =
                SettingsScreen.readBackupJson(new ByteArrayInputStream(newBackupBytes));
        org.json.JSONArray cRows =
                conflictJson.getJSONObject("settings").getJSONArray("saved_subscriptions");
        cRows.getJSONObject(1).put("url", cRows.getJSONObject(0).getString("url"));
        boolean conflictRejected = false;
        try {
            SettingsScreen.validateBackupForRestore(conflictJson, true);
        } catch (Exception expected) {
            conflictRejected = true;
        }
        check(
                conflictRejected,
                "R4.1: Preflight rejects conflicting same-URL / distinct-declared-ID subscriptions");

        // 2. Streaming export + pre-overwrite SAF write/close failure protection
        File safDir = new File(r4Dir, "saf_protect");
        safDir.mkdirs();
        File existingDest = new File(safDir, "existing-backup.json");
        Files.write(existingDest.toPath(), newBackupBytes);
        // Mutate srcAct to add a 3rd sub, then inject write failure at byte 96 and close failure
        String extraRaw =
                "{\"sites\":[{\"key\":\"extraC\",\"name\":\"额外C\",\"type\":1,\"api\":\"https://new.invalid/c\"}]}";
        srcAct.multiSourceStore.registerSubscription(
                srcLib, extraRaw, "https://r4.invalid/C", "订阅C", true, 102L);
        final int[] writeCalls = {0};
        boolean writeFailCaught = false;
        try {
            SettingsScreen.exportBackupToDestination(
                    srcAct,
                    new SettingsScreen.BackupExportDestination() {
                        @Override
                        public java.io.InputStream openExistingForRead() throws IOException {
                            return new java.io.FileInputStream(existingDest);
                        }

                        @Override
                        public java.io.OutputStream openForWrite() throws IOException {
                            writeCalls[0]++;
                            java.io.FileOutputStream fos =
                                    new java.io.FileOutputStream(existingDest, false);
                            if (writeCalls[0] == 1) {
                                return new java.io.FilterOutputStream(fos) {
                                    @Override
                                    public void write(byte[] b, int off, int len)
                                            throws IOException {
                                        out.write(b, off, Math.min(96, len));
                                        throw new IOException("provider write failed at 96B");
                                    }
                                };
                            }
                            return fos;
                        }

                        @Override
                        public File directLocalFileOrNull() {
                            return null;
                        }

                        @Override
                        public boolean supportsSiblingNewDocument() {
                            return false;
                        }

                        @Override
                        public java.io.OutputStream openSiblingNewDocumentForWrite(String name)
                                throws IOException {
                            throw new IOException("unsupported");
                        }
                    });
        } catch (IOException expected) {
            writeFailCaught = true;
        }
        check(writeFailCaught, "R4.2: SAF write failure at byte 96 surfaces explicit error");
        byte[] afterWriteFail = Files.readAllBytes(existingDest.toPath());
        File safeCopyFile = SettingsScreen.lastSafeBackupFile(srcAct);
        check(
                java.util.Arrays.equals(newBackupBytes, afterWriteFail)
                        && safeCopyFile != null
                        && safeCopyFile.isFile()
                        && java.util.Arrays.equals(
                                newBackupBytes, Files.readAllBytes(safeCopyFile.toPath())),
                "R4.2: Automatic rollback restores target AND local safe copy retains exact prior backup");

        // 2b. Persistent provider close() failure still keeps local safe copy readable
        boolean closeFailCaught = false;
        try {
            SettingsScreen.exportBackupToDestination(
                    srcAct,
                    new SettingsScreen.BackupExportDestination() {
                        @Override
                        public java.io.InputStream openExistingForRead() throws IOException {
                            return new java.io.FileInputStream(existingDest);
                        }

                        @Override
                        public java.io.OutputStream openForWrite() throws IOException {
                            java.io.FileOutputStream fos =
                                    new java.io.FileOutputStream(existingDest, false);
                            return new java.io.FilterOutputStream(fos) {
                                @Override
                                public void close() throws IOException {
                                    super.close();
                                    throw new IOException("provider close failed");
                                }
                            };
                        }

                        @Override
                        public File directLocalFileOrNull() {
                            return null;
                        }

                        @Override
                        public boolean supportsSiblingNewDocument() {
                            return false;
                        }

                        @Override
                        public java.io.OutputStream openSiblingNewDocumentForWrite(String name)
                                throws IOException {
                            throw new IOException("unsupported");
                        }
                    });
        } catch (IOException expected) {
            closeFailCaught = true;
        }
        check(closeFailCaught, "R4.2: Provider close() failure surfaces explicit error");
        org.json.JSONObject recoveredFromSafe;
        try (java.io.InputStream in = new java.io.FileInputStream(safeCopyFile)) {
            recoveredFromSafe = SettingsScreen.readBackupJson(in);
        }
        SettingsScreen.BackupRestorePlan safePlan =
                SettingsScreen.validateBackupForRestore(recoveredFromSafe, true);
        check(
                safePlan.savedSubscriptions.length() == 2,
                "R4.2: Last valid backup remains readable & restorable from local safe copy after close() failure");

        // 3. Legacy disk recovery (no cleanHistory): equal-mtime different-API & no-compatible
        // stillWorking
        File legDir = new File(r4Dir, "legacy_tie_api");
        legDir.mkdirs();
        ConfigLibrary legLib = new ConfigLibrary(legDir);
        TvMultiSourceStore legStore = new TvMultiSourceStore(legDir);
        String legOrigin = "https://legacy.invalid/sub.json";
        String legOldRaw =
                "{\"sites\":["
                        + "{\"key\":\"keep\",\"name\":\"Keep\",\"type\":1,\"api\":\"https://withdrawn.invalid/keep\"},"
                        + "{\"key\":\"w1\",\"name\":\"W1\",\"type\":1,\"api\":\"https://withdrawn.invalid/w1\"},"
                        + "{\"key\":\"w2\",\"name\":\"W2\",\"type\":1,\"api\":\"https://withdrawn.invalid/w2\"}]}";
        String legNewRaw =
                "{\"sites\":["
                        + "{\"key\":\"keep\",\"name\":\"Keep\",\"type\":1,\"api\":\"https://latest.invalid/keep\"},"
                        + "{\"key\":\"newLine\",\"name\":\"New\",\"type\":1,\"api\":\"https://latest.invalid/new\"}]}";
        TvMultiSourceStore.SubscriptionRecord legRec =
                legStore.registerSubscription(legLib, legOldRaw, legOrigin, "LegacySub", true, 1L);
        ConfigLibrary.Entry eOld = legLib.entries().get(0);
        ConfigLibrary.Entry eNew = legLib.remember(legNewRaw, legOrigin, "LegacySub", "", 2L);
        legStore.setSiteDisabled(legRec.id, "newLine", true);
        String filteredDmg = legStore.buildEffectiveConfig(legLib, "", null).config.raw;
        ConfigLibrary.Entry eDmg = legLib.remember(filteredDmg, legOrigin, "LegacySub", "", 3L);
        // Strip cleanHistory from index.json and set identical mtime on eOld and eNew
        File idxFile = new File(legLib.directory, "index.json");
        org.json.JSONArray idxArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(idxFile.toPath()), StandardCharsets.UTF_8));
        idxArr.getJSONObject(0).remove("cleanHistory");
        Files.write(idxFile.toPath(), idxArr.toString().getBytes(StandardCharsets.UTF_8));
        long tBase = 1700000000000L;
        legLib.contentFile(eOld).setLastModified(tBase);
        legLib.contentFile(eNew).setLastModified(tBase);
        legLib.contentFile(eDmg).setLastModified(tBase + 20000L);
        TvMultiSourceStore coldLeg = new TvMultiSourceStore(legDir);
        TvMultiSourceStore.EffectiveBuild legBuilt = coldLeg.buildEffectiveConfig(legLib, "", null);
        check(
                legBuilt.config.sites.size() == 1
                        && "https://latest.invalid/keep".equals(legBuilt.config.sites.get(0).api)
                        && eNew.digest.equals(legLib.entries().get(0).digest),
                "R4.3: Legacy equal-mtime recovery matches surviving API endpoint and never resurrects withdrawn lines");

        // 3b. No-compatible-backup preserves stillWorking and records refresh hint
        File keepDir = new File(r4Dir, "legacy_still_working");
        keepDir.mkdirs();
        ConfigLibrary keepLib = new ConfigLibrary(keepDir);
        TvMultiSourceStore keepStore = new TvMultiSourceStore(keepDir);
        TvMultiSourceStore.SubscriptionRecord keepRec =
                keepStore.registerSubscription(keepLib, legOldRaw, legOrigin, "KeepSub", true, 1L);
        ConfigLibrary.Entry kOld = keepLib.entries().get(0);
        ConfigLibrary.Entry kNew = keepLib.remember(legNewRaw, legOrigin, "KeepSub", "", 2L);
        String stillWorkingDmg =
                "{\"sites\":[{\"key\":\""
                        + TvMultiSourceStore.stableSiteKey(keepRec.id, "stillWorking")
                        + "\",\"name\":\"Still\",\"type\":1,\"api\":\"https://retained.invalid/still\"}]}";
        ConfigLibrary.Entry kDmg = keepLib.remember(stillWorkingDmg, legOrigin, "KeepSub", "", 3L);
        File kIdxFile = new File(keepLib.directory, "index.json");
        org.json.JSONArray kIdxArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(kIdxFile.toPath()), StandardCharsets.UTF_8));
        kIdxArr.getJSONObject(0).remove("cleanHistory");
        Files.write(kIdxFile.toPath(), kIdxArr.toString().getBytes(StandardCharsets.UTF_8));
        keepLib.contentFile(kOld).setLastModified(tBase);
        keepLib.contentFile(kNew).setLastModified(tBase + 10000L);
        keepLib.contentFile(kDmg).setLastModified(tBase + 20000L);
        TvMultiSourceStore coldKeep = new TvMultiSourceStore(keepDir);
        TvMultiSourceStore.EffectiveBuild keepBuilt =
                coldKeep.buildEffectiveConfig(keepLib, "", null);
        check(
                kDmg.digest.equals(keepLib.entries().get(0).digest)
                        && keepBuilt.config.sites.size() == 1
                        && "https://retained.invalid/still"
                                .equals(keepBuilt.config.sites.get(0).api)
                        && !coldKeep.recoveryHintFor(keepRec.id).isEmpty(),
                "R4.3: No-compatible legacy recovery preserves stillWorking endpoint, digest & emits refresh hint");
    }

    private static MainActivity newHeadlessActivity(File root) throws Exception {
        Class<?> u = Class.forName("sun.misc.Unsafe");
        java.lang.reflect.Field f = u.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        MainActivity act =
                (MainActivity)
                        u.getMethod("allocateInstance", Class.class)
                                .invoke(f.get(null), MainActivity.class);
        act.formFactor = TvLayoutPolicy.FORM_TV;
        final java.util.Map<String, Object> store = new java.util.LinkedHashMap<>();
        final ClassLoader cl = TvPlaybackMultiSourceChecks.class.getClassLoader();
        act.prefs =
                (android.content.SharedPreferences)
                        java.lang.reflect.Proxy.newProxyInstance(
                                cl,
                                new Class<?>[] {android.content.SharedPreferences.class},
                                (proxy, m, args) -> {
                                    String name = m.getName();
                                    if ("contains".equals(name)) {
                                        return store.containsKey(String.valueOf(args[0]));
                                    }
                                    if ("getAll".equals(name)) {
                                        return new java.util.LinkedHashMap<>(store);
                                    }
                                    if ("edit".equals(name)) {
                                        final java.util.Map<String, Object> pending =
                                                new java.util.LinkedHashMap<>();
                                        final java.util.Set<String> removals =
                                                new java.util.HashSet<>();
                                        final boolean[] clearAll = {false};
                                        return java.lang.reflect.Proxy.newProxyInstance(
                                                cl,
                                                new Class<?>[] {
                                                    android.content.SharedPreferences.Editor.class
                                                },
                                                (ep, em, eargs) -> {
                                                    String en = em.getName();
                                                    if (en.startsWith("put")
                                                            && eargs != null
                                                            && eargs.length >= 2) {
                                                        String k = String.valueOf(eargs[0]);
                                                        pending.put(k, eargs[1]);
                                                        removals.remove(k);
                                                        return ep;
                                                    }
                                                    if ("remove".equals(en)
                                                            && eargs != null
                                                            && eargs.length >= 1) {
                                                        String k = String.valueOf(eargs[0]);
                                                        removals.add(k);
                                                        pending.remove(k);
                                                        return ep;
                                                    }
                                                    if ("clear".equals(en)) {
                                                        clearAll[0] = true;
                                                        pending.clear();
                                                        removals.clear();
                                                        return ep;
                                                    }
                                                    if ("apply".equals(en) || "commit".equals(en)) {
                                                        if (clearAll[0]) store.clear();
                                                        for (String rk : removals) store.remove(rk);
                                                        store.putAll(pending);
                                                        return "commit".equals(en)
                                                                ? Boolean.TRUE
                                                                : null;
                                                    }
                                                    return ep;
                                                });
                                    }
                                    if (args != null && args.length >= 2) {
                                        Object v = store.get(String.valueOf(args[0]));
                                        return v != null ? v : args[1];
                                    }
                                    return null;
                                });
        act.configStore = new ConfigStore(root);
        act.multiSourceStore = new TvMultiSourceStore(root);
        return act;
    }

    private static void testFifthRecheckReworkContracts(File tmpRoot) throws Exception {
        File r5Dir = new File(tmpRoot, "r5_recheck");
        r5Dir.mkdirs();

        // 1. P1: Three-stage restore — post-file prefs failure rolls back to complete OLD state
        // without deleting active-indexed files, AND post-commit UI refresh failure preserves
        // complete NEW committed state!
        File srcDir = new File(r5Dir, "t1_src");
        srcDir.mkdirs();
        MainActivity srcAct = newHeadlessActivity(srcDir);
        ConfigLibrary srcLib = new ConfigLibrary(srcDir);
        String urlA = "https://r5.invalid/a.json";
        String urlB = "https://r5.invalid/b.json";
        String rawOldA =
                "{\"sites\":[{\"key\":\"oldA\",\"name\":\"OldA\",\"type\":1,\"api\":\"https://old.invalid/a\"}]}";
        String rawOldB =
                "{\"sites\":[{\"key\":\"oldB\",\"name\":\"OldB\",\"type\":1,\"api\":\"https://old.invalid/b\"}]}";
        String rawNewA =
                "{\"sites\":[{\"key\":\"newA\",\"name\":\"NewA\",\"type\":1,\"api\":\"https://new.invalid/a\"}]}";
        String rawNewB =
                "{\"sites\":[{\"key\":\"newB\",\"name\":\"NewB\",\"type\":1,\"api\":\"https://new.invalid/b\"}]}";
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewA, urlA, "A", true, 10L);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewB, urlB, "B", true, 20L);
        srcAct.config = srcAct.multiSourceStore.buildEffectiveConfig(srcLib, "", null).config;
        srcAct.prefs.edit().putInt(Prefs.HOME_COLUMNS, 5).apply();
        byte[] newArchive = SettingsScreen.exportBackupBytes(srcAct);

        // 1a. Post-file preference apply() throws -> WAL rolls back cleanly to OLD A & OLD B
        File prefFailDir = new File(r5Dir, "t1_pref_fail");
        prefFailDir.mkdirs();
        MainActivity prefAct = newHeadlessActivity(prefFailDir);
        ConfigLibrary prefLib = new ConfigLibrary(prefFailDir);
        prefAct.multiSourceStore.registerSubscription(prefLib, rawOldA, urlA, "A", true, 1L);
        prefAct.multiSourceStore.registerSubscription(prefLib, rawOldB, urlB, "B", true, 2L);
        prefAct.config = prefAct.multiSourceStore.buildEffectiveConfig(prefLib, "", null).config;
        String oldADigest = prefLib.entries().get(0).digest;
        String oldBDigest = prefLib.entries().get(1).digest;
        final android.content.SharedPreferences realPrefs = prefAct.prefs;
        ClassLoader cl = TvPlaybackMultiSourceChecks.class.getClassLoader();
        android.content.SharedPreferences.Editor failingEd =
                (android.content.SharedPreferences.Editor)
                        java.lang.reflect.Proxy.newProxyInstance(
                                cl,
                                new Class<?>[] {android.content.SharedPreferences.Editor.class},
                                (p, m, a) -> {
                                    if ("apply".equals(m.getName())
                                            || "commit".equals(m.getName())) {
                                        throw new IllegalStateException(
                                                "injected prefs apply fail");
                                    }
                                    return p;
                                });
        prefAct.prefs =
                (android.content.SharedPreferences)
                        java.lang.reflect.Proxy.newProxyInstance(
                                cl,
                                new Class<?>[] {android.content.SharedPreferences.class},
                                (p, m, a) -> {
                                    if ("edit".equals(m.getName())) return failingEd;
                                    return m.invoke(realPrefs, a);
                                });
        SettingsScreen.BackupRestorePlan prefPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(newArchive), true);
        boolean prefErrCaught = false;
        try {
            SettingsScreen.applyBackupRestore(prefAct, prefPlan);
        } catch (IllegalStateException expected) {
            prefErrCaught = expected.getMessage().contains("injected prefs apply fail");
        } finally {
            prefPlan.cleanupTempFiles();
        }
        ConfigLibrary coldPrefLib = new ConfigLibrary(prefFailDir);
        TvMultiSourceStore coldPrefStore = new TvMultiSourceStore(prefFailDir);
        TvMultiSourceStore.EffectiveBuild coldPrefBuilt =
                coldPrefStore.buildEffectiveConfig(coldPrefLib, "", null);
        boolean allOldReadable =
                coldPrefLib.entries().size() == 2
                        && oldADigest.equals(coldPrefLib.entries().get(0).digest)
                        && oldBDigest.equals(coldPrefLib.entries().get(1).digest)
                        && coldPrefLib.raw(coldPrefLib.entries().get(0)).contains("oldA")
                        && coldPrefLib.raw(coldPrefLib.entries().get(1)).contains("oldB");
        check(
                prefErrCaught
                        && allOldReadable
                        && coldPrefBuilt.config.sites.size() == 2
                        && "https://old.invalid/a".equals(coldPrefBuilt.config.sites.get(0).api)
                        && "https://old.invalid/b".equals(coldPrefBuilt.config.sites.get(1).api),
                "R5.1: Preference apply() failure rolls back WAL cleanly to complete OLD state with 2/2 readable live lines");

        // 1b. Post-commit UI refresh failure -> committed NEW data survives 100% intact
        File uiFailDir = new File(r5Dir, "t1_ui_fail");
        uiFailDir.mkdirs();
        MainActivity uiAct = newHeadlessActivity(uiFailDir);
        ConfigLibrary uiLib = new ConfigLibrary(uiFailDir);
        uiAct.multiSourceStore.registerSubscription(uiLib, rawOldA, urlA, "A", true, 1L);
        uiAct.multiSourceStore.registerSubscription(uiLib, rawOldB, urlB, "B", true, 2L);
        uiAct.config = uiAct.multiSourceStore.buildEffectiveConfig(uiLib, "", null).config;
        SettingsScreen.BackupRestorePlan uiPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(newArchive), true);
        final java.util.concurrent.atomic.AtomicBoolean hookFired =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        SettingsScreen.restoreUiRefreshHookForTest =
                () -> {
                    hookFired.set(true);
                    throw new RuntimeException("injected post-commit ui refresh crash");
                };
        try {
            SettingsScreen.applyBackupRestore(uiAct, uiPlan);
        } finally {
            SettingsScreen.restoreUiRefreshHookForTest = null;
            uiPlan.cleanupTempFiles();
        }
        ConfigLibrary coldUiLib = new ConfigLibrary(uiFailDir);
        TvMultiSourceStore coldUiStore = new TvMultiSourceStore(uiFailDir);
        TvMultiSourceStore.EffectiveBuild coldUiBuilt =
                coldUiStore.buildEffectiveConfig(coldUiLib, "", null);
        check(
                hookFired.get()
                        && coldUiLib.entries().size() == 2
                        && coldUiBuilt.config.sites.size() == 2
                        && "https://new.invalid/a".equals(coldUiBuilt.config.sites.get(0).api)
                        && "https://new.invalid/b".equals(coldUiBuilt.config.sites.get(1).api)
                        && uiAct.prefs.getInt(Prefs.HOME_COLUMNS, 6) == 5,
                "R5.1: Post-commit UI refresh failure never deletes committed files; cold start reads complete NEW state & prefs");

        // 2. P1: Protect existing backup on unreadable provider & protect last-safe-backup from
        // unrelated JSON
        File t2Dir = new File(r5Dir, "t2_safe");
        t2Dir.mkdirs();
        MainActivity t2Act = newHeadlessActivity(t2Dir);
        ConfigLibrary t2Lib = new ConfigLibrary(t2Dir);
        t2Act.multiSourceStore.registerSubscription(t2Lib, rawOldA, urlA, "A", true, 1L);
        t2Act.config = t2Act.multiSourceStore.buildEffectiveConfig(t2Lib, "", null).config;
        final File targetDoc = new File(t2Dir, "doc.json");
        byte[] oldGoodBytes = SettingsScreen.exportBackupBytes(t2Act);
        Files.write(targetDoc.toPath(), oldGoodBytes);
        // 2a. Unreadable existing document -> MUST abort BEFORE openForWrite() (0 writes)
        final int[] writeAttempts = {0};
        boolean unreadRejected = false;
        try {
            SettingsScreen.exportBackupToDestination(
                    t2Act,
                    new SettingsScreen.BackupExportDestination() {
                        @Override
                        public java.io.InputStream openExistingForRead() throws IOException {
                            throw new IOException("provider denied read");
                        }

                        @Override
                        public java.io.OutputStream openForWrite() throws IOException {
                            writeAttempts[0]++;
                            return new java.io.FileOutputStream(targetDoc, false);
                        }

                        @Override
                        public File directLocalFileOrNull() {
                            return null;
                        }

                        @Override
                        public boolean supportsSiblingNewDocument() {
                            return false;
                        }

                        @Override
                        public java.io.OutputStream openSiblingNewDocumentForWrite(String name)
                                throws IOException {
                            throw new IOException("unsupported");
                        }
                    });
        } catch (IOException expected) {
            unreadRejected = true;
        }
        check(
                unreadRejected
                        && writeAttempts[0] == 0
                        && targetDoc.length() == oldGoodBytes.length
                        && SettingsScreen.isRestorableBackupFile(t2Act, targetDoc),
                "R5.2A: Unreadable destination aborts before openForWrite() and preserves existing valid backup");

        // 2b. Prior good local safe copy must NOT be replaced by 18-byte unrelated JSON target
        SettingsScreen.exportBackupToDestination(
                t2Act,
                new SettingsScreen.BackupExportDestination() {
                    @Override
                    public java.io.InputStream openExistingForRead() throws IOException {
                        return new java.io.FileInputStream(targetDoc);
                    }

                    @Override
                    public java.io.OutputStream openForWrite() throws IOException {
                        return new java.io.FileOutputStream(targetDoc, false);
                    }

                    @Override
                    public File directLocalFileOrNull() {
                        return targetDoc;
                    }

                    @Override
                    public boolean supportsSiblingNewDocument() {
                        return false;
                    }

                    @Override
                    public java.io.OutputStream openSiblingNewDocumentForWrite(String name)
                            throws IOException {
                        throw new IOException("unsupported");
                    }
                });
        File safeCopy = SettingsScreen.lastSafeBackupFile(t2Act);
        long safeGoodLen = safeCopy.length();
        Files.write(targetDoc.toPath(), "{\"unrelated\":true}".getBytes(StandardCharsets.UTF_8));
        boolean failOnUnrelated = false;
        try {
            SettingsScreen.exportBackupToDestination(
                    t2Act,
                    new SettingsScreen.BackupExportDestination() {
                        @Override
                        public java.io.InputStream openExistingForRead() throws IOException {
                            return new java.io.FileInputStream(targetDoc);
                        }

                        @Override
                        public java.io.OutputStream openForWrite() throws IOException {
                            return new java.io.FilterOutputStream(
                                    new java.io.FileOutputStream(targetDoc, false)) {
                                @Override
                                public void write(byte[] b, int off, int len) throws IOException {
                                    out.write(b, off, Math.min(10, len));
                                    throw new IOException("write fail");
                                }
                            };
                        }

                        @Override
                        public File directLocalFileOrNull() {
                            return null;
                        }

                        @Override
                        public boolean supportsSiblingNewDocument() {
                            return false;
                        }

                        @Override
                        public java.io.OutputStream openSiblingNewDocumentForWrite(String name)
                                throws IOException {
                            throw new IOException("unsupported");
                        }
                    });
        } catch (IOException expected) {
            failOnUnrelated = true;
        }
        check(
                failOnUnrelated
                        && safeCopy.isFile()
                        && safeCopy.length() == safeGoodLen
                        && SettingsScreen.isRestorableBackupFile(t2Act, safeCopy),
                "R5.2B: Unrelated 18-byte JSON target never overwrites verified last-safe-backup.json");

        // 3. P1: Legacy T4 recovery verifies ext route identity (no switch to withdrawn-catalog)
        File t3Dir = new File(r5Dir, "t3_t4_ext");
        t3Dir.mkdirs();
        ConfigLibrary t3Lib = new ConfigLibrary(t3Dir);
        TvMultiSourceStore t3Store = new TvMultiSourceStore(t3Dir);
        String t4Origin = "https://t4.invalid/sub.json";
        String t4Api = "http://127.0.0.1:9999/t4";
        String t4Old =
                "{\"sites\":[{\"key\":\"keep\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"withdrawn-catalog\"}]}";
        TvMultiSourceStore.SubscriptionRecord t4Rec =
                t3Store.registerSubscription(t3Lib, t4Old, t4Origin, "T4Sub", true, 1L);
        String t4Survivor =
                "{\"sites\":[{\"key\":\""
                        + TvMultiSourceStore.stableSiteKey(t4Rec.id, "keep")
                        + "\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"current-catalog\"}]}";
        ConfigLibrary.Entry t4Dmg = t3Lib.remember(t4Survivor, t4Origin, "T4Sub", "", 2L);
        File t3Idx = new File(t3Lib.directory, "index.json");
        org.json.JSONArray t3Arr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(t3Idx.toPath()), StandardCharsets.UTF_8));
        t3Arr.getJSONObject(0).remove("cleanHistory");
        Files.write(t3Idx.toPath(), t3Arr.toString().getBytes(StandardCharsets.UTF_8));
        TvMultiSourceStore t3Cold = new TvMultiSourceStore(t3Dir);
        TvMultiSourceStore.EffectiveBuild t3Built = t3Cold.buildEffectiveConfig(t3Lib, "", null);
        check(
                t4Dmg.digest.equals(t3Lib.entries().get(0).digest)
                        && t3Built.config.sites.size() == 1
                        && "current-catalog".equals(String.valueOf(t3Built.config.sites.get(0).ext))
                        && !t3Cold.recoveryHintFor(t4Rec.id).isEmpty(),
                "R5.3A: Legacy T4 recovery rejects withdrawn-catalog ext, keeps current-catalog & emits hint");

        // 3b. Positive control: matching T4 ext (including canonical JSON key-order) recovers
        // cleanly
        File t3PosDir = new File(r5Dir, "t3_t4_pos");
        t3PosDir.mkdirs();
        ConfigLibrary t3PosLib = new ConfigLibrary(t3PosDir);
        TvMultiSourceStore t3PosStore = new TvMultiSourceStore(t3PosDir);
        String t4GoodClean =
                "{\"sites\":["
                        + "{\"key\":\"keep\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":{\"b\":2,\"a\":\"current\"}},"
                        + "{\"key\":\"newLine\",\"name\":\"NewT4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"extra\"}"
                        + "]}";
        TvMultiSourceStore.SubscriptionRecord t4PosRec =
                t3PosStore.registerSubscription(t3PosLib, t4GoodClean, t4Origin, "T4Pos", true, 1L);
        ConfigLibrary.Entry t4PosClean = t3PosLib.entries().get(0);
        t3PosStore.setSiteDisabled(t4PosRec.id, "newLine", true);
        String t4PosSurvivor =
                "{\"sites\":[{\"key\":\""
                        + TvMultiSourceStore.stableSiteKey(t4PosRec.id, "keep")
                        + "\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":{\"a\":\"current\",\"b\":2}}]}";
        t3PosLib.remember(t4PosSurvivor, t4Origin, "T4Pos", "", 2L);
        File t3PosIdx = new File(t3PosLib.directory, "index.json");
        org.json.JSONArray t3PosArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(t3PosIdx.toPath()), StandardCharsets.UTF_8));
        t3PosArr.getJSONObject(0).remove("cleanHistory");
        Files.write(t3PosIdx.toPath(), t3PosArr.toString().getBytes(StandardCharsets.UTF_8));
        TvMultiSourceStore t3PosCold = new TvMultiSourceStore(t3PosDir);
        t3PosCold.buildEffectiveConfig(t3PosLib, "", null);
        check(
                t4PosClean.digest.equals(t3PosLib.entries().get(0).digest)
                        && t3PosCold.recoveryHintFor(t4PosRec.id).isEmpty(),
                "R5.3B: Legacy T4 recovery accepts canonical-equivalent structured ext and restores full clean copy");

        // 4. P2: Async serial worker thread execution & duplicate-confirm guard
        File t4Dir = new File(r5Dir, "t4_async");
        t4Dir.mkdirs();
        MainActivity t4Act = newHeadlessActivity(t4Dir);
        ConfigLibrary t4Lib = new ConfigLibrary(t4Dir);
        t4Act.multiSourceStore.registerSubscription(t4Lib, rawOldA, urlA, "A", true, 1L);
        t4Act.config = t4Act.multiSourceStore.buildEffectiveConfig(t4Lib, "", null).config;
        SettingsScreen.BackupRestorePlan asyncPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(newArchive), true);
        final java.util.concurrent.CountDownLatch latch =
                new java.util.concurrent.CountDownLatch(1);
        final SettingsScreen.BackupRestoreMetrics[] metricsRef =
                new SettingsScreen.BackupRestoreMetrics[1];
        boolean started =
                SettingsScreen.startAsyncBackupRestore(
                        t4Act,
                        asyncPlan,
                        5L,
                        "unit-test-async",
                        "fail",
                        m -> {
                            metricsRef[0] = m;
                            latch.countDown();
                        });
        check(
                started
                        && latch.await(15, java.util.concurrent.TimeUnit.SECONDS)
                        && metricsRef[0] != null
                        && metricsRef[0].committed
                        && "marco-backup-restore".equals(metricsRef[0].commitThread),
                "R5.4: startAsyncBackupRestore executes commit on dedicated serial worker thread marco-backup-restore");
    }

    private static android.content.SharedPreferences makeFileBackedPrefs(
            final File backingJsonFile, final Runnable afterDurableWrite) {
        final Object prefLock = new Object();
        return (android.content.SharedPreferences)
                java.lang.reflect.Proxy.newProxyInstance(
                        TvPlaybackMultiSourceChecks.class.getClassLoader(),
                        new Class<?>[] {android.content.SharedPreferences.class},
                        (proxy, method, args) -> {
                            String name = method.getName();
                            if ("edit".equals(name)) {
                                final java.util.Map<String, Object> staged =
                                        new java.util.HashMap<>();
                                return java.lang.reflect.Proxy.newProxyInstance(
                                        TvPlaybackMultiSourceChecks.class.getClassLoader(),
                                        new Class<?>[] {
                                            android.content.SharedPreferences.Editor.class
                                        },
                                        (ed, m, p) -> {
                                            String op = m.getName();
                                            if (op.startsWith("put")) {
                                                staged.put((String) p[0], p[1]);
                                                return ed;
                                            }
                                            if ("remove".equals(op)) {
                                                staged.put((String) p[0], org.json.JSONObject.NULL);
                                                return ed;
                                            }
                                            if ("apply".equals(op) || "commit".equals(op)) {
                                                synchronized (prefLock) {
                                                    org.json.JSONObject cur =
                                                            backingJsonFile.isFile()
                                                                    ? new org.json.JSONObject(
                                                                            new String(
                                                                                    Files
                                                                                            .readAllBytes(
                                                                                                    backingJsonFile
                                                                                                            .toPath()),
                                                                                    StandardCharsets
                                                                                            .UTF_8))
                                                                    : new org.json.JSONObject();
                                                    for (java.util.Map.Entry<String, Object> e :
                                                            staged.entrySet()) {
                                                        if (e.getValue()
                                                                == org.json.JSONObject.NULL) {
                                                            cur.remove(e.getKey());
                                                        } else {
                                                            cur.put(e.getKey(), e.getValue());
                                                        }
                                                    }
                                                    Files.write(
                                                            backingJsonFile.toPath(),
                                                            cur.toString()
                                                                    .getBytes(
                                                                            StandardCharsets
                                                                                    .UTF_8));
                                                }
                                                if (afterDurableWrite != null) {
                                                    afterDurableWrite.run();
                                                }
                                                return "commit".equals(op) ? Boolean.TRUE : null;
                                            }
                                            return ed;
                                        });
                            }
                            synchronized (prefLock) {
                                org.json.JSONObject cur =
                                        backingJsonFile.isFile()
                                                ? new org.json.JSONObject(
                                                        new String(
                                                                Files.readAllBytes(
                                                                        backingJsonFile.toPath()),
                                                                StandardCharsets.UTF_8))
                                                : new org.json.JSONObject();
                                if ("contains".equals(name)) {
                                    return cur.has((String) args[0]);
                                }
                                if ("getAll".equals(name)) {
                                    java.util.Map<String, Object> all = new java.util.HashMap<>();
                                    java.util.Iterator<String> it = cur.keys();
                                    while (it.hasNext()) {
                                        String k = it.next();
                                        all.put(k, cur.opt(k));
                                    }
                                    return all;
                                }
                                if (args != null && args.length >= 2) {
                                    String k = (String) args[0];
                                    if (!cur.has(k)) return args[1];
                                    if ("getInt".equals(name))
                                        return cur.optInt(k, (Integer) args[1]);
                                    if ("getBoolean".equals(name))
                                        return cur.optBoolean(k, (Boolean) args[1]);
                                    if ("getString".equals(name))
                                        return cur.optString(k, (String) args[1]);
                                    return cur.opt(k);
                                }
                            }
                            return null;
                        });
    }

    private static void testSixthRecheckReworkContracts(File tmpRoot) throws Exception {
        File r6Dir = new File(tmpRoot, "r6_rework");
        r6Dir.mkdirs();

        String urlA = "https://r6.invalid/subA.json";
        String urlB = "https://r6.invalid/subB.json";
        String rawOldA =
                "{\"sites\":[{\"key\":\"oldA\",\"name\":\"旧A\",\"type\":1,\"api\":\"https://old.invalid/a\"}]}";
        String rawOldB =
                "{\"sites\":[{\"key\":\"oldB\",\"name\":\"旧B\",\"type\":1,\"api\":\"https://old.invalid/b\"}]}";
        String rawNewA =
                "{\"sites\":[{\"key\":\"newA\",\"name\":\"新A\",\"type\":1,\"api\":\"https://new.invalid/a\"}]}";
        String rawNewB =
                "{\"sites\":[{\"key\":\"newB\",\"name\":\"新B\",\"type\":1,\"api\":\"https://new.invalid/b\"}]}";
        String oldHist =
                new org.json.JSONArray()
                        .put(
                                new org.json.JSONObject()
                                        .put("site", "oldSite")
                                        .put("id", "oldEp")
                                        .put("title", "oldEp")
                                        .put("episode", "EP01")
                                        .put("position", 60000)
                                        .put("duration", 1800000))
                        .toString();
        String newHist =
                new org.json.JSONArray()
                        .put(
                                new org.json.JSONObject()
                                        .put("site", "backupSite")
                                        .put("id", "backupEp")
                                        .put("title", "backupEp")
                                        .put("episode", "EP02")
                                        .put("position", 720000)
                                        .put("duration", 1800000))
                        .toString();

        // Build clean backup archive containing newA/newB, HOME_COLUMNS=5, EP02@12:00
        File srcDir = new File(r6Dir, "src");
        srcDir.mkdirs();
        MainActivity srcAct = newHeadlessActivity(srcDir);
        ConfigLibrary srcLib = new ConfigLibrary(srcDir);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewA, urlA, "A新", true, 10L);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewB, urlB, "B新", true, 11L);
        srcAct.config = srcAct.multiSourceStore.buildEffectiveConfig(srcLib, "", null).config;
        org.json.JSONObject archiveObj = SettingsScreen.buildBackupJson(srcAct);
        archiveObj.getJSONObject("settings").put(Prefs.HOME_COLUMNS, 5);
        archiveObj.getJSONObject("settings").put(Prefs.WATCH_HISTORY, newHist);
        byte[] archiveBytes = archiveObj.toString().getBytes(StandardCharsets.UTF_8);

        // 1A. Concurrent ConfigLibrary.entries() & TvMultiSourceStore.readState() during active WAL
        File concDir = new File(r6Dir, "concurrent_read");
        concDir.mkdirs();
        File concPrefsFile = new File(concDir, "prefs.json");
        Files.write(
                concPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity concAct = newHeadlessActivity(concDir);
        ConfigLibrary concLib = new ConfigLibrary(concDir);
        concAct.multiSourceStore.registerSubscription(concLib, rawOldA, urlA, "A旧", true, 1L);
        concAct.multiSourceStore.registerSubscription(concLib, rawOldB, urlB, "B旧", true, 2L);
        concAct.config = concAct.multiSourceStore.buildEffectiveConfig(concLib, "", null).config;

        final java.util.concurrent.CountDownLatch inPrefs =
                new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch readerDone =
                new java.util.concurrent.CountDownLatch(1);
        final boolean[] readerOk = {false};
        final int[] readerCount = {0};
        Thread reader =
                new Thread(
                        () -> {
                            try {
                                if (inPrefs.await(5, java.util.concurrent.TimeUnit.SECONDS)) {
                                    java.util.List<ConfigLibrary.Entry> ents =
                                            new ConfigLibrary(concDir).entries();
                                    TvMultiSourceStore.State st =
                                            new TvMultiSourceStore(concDir).readState();
                                    readerCount[0] = ents.size();
                                    readerOk[0] = ents.size() == 2 && st.subscriptions.size() == 2;
                                }
                            } catch (Throwable ignored) {
                            } finally {
                                readerDone.countDown();
                            }
                        },
                        "r6-concurrent-reader");
        reader.setDaemon(true);
        reader.start();
        concAct.prefs =
                makeFileBackedPrefs(
                        concPrefsFile,
                        () -> {
                            inPrefs.countDown();
                            try {
                                readerDone.await(3, java.util.concurrent.TimeUnit.SECONDS);
                            } catch (InterruptedException ignored) {
                            }
                        });
        SettingsScreen.BackupRestorePlan concPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(archiveBytes), true);
        SettingsScreen.BackupRestoreCommitResult concRes =
                SettingsScreen.commitBackupRestoreOnWorker(concAct, concPlan);
        concPlan.cleanupTempFiles();
        TvMultiSourceStore.EffectiveBuild coldConc =
                new TvMultiSourceStore(concDir)
                        .buildEffectiveConfig(new ConfigLibrary(concDir), "", null);
        org.json.JSONObject coldConcPrefs =
                new org.json.JSONObject(
                        new String(
                                Files.readAllBytes(concPrefsFile.toPath()),
                                StandardCharsets.UTF_8));
        check(
                concRes.committed
                        && readerOk[0]
                        && readerCount[0] == 2
                        && !new File(concDir, "restore-tx/manifest.json").exists()
                        && coldConc.config.sites.size() == 2
                        && "https://new.invalid/a".equals(coldConc.config.sites.get(0).api)
                        && coldConcPrefs.getInt(Prefs.HOME_COLUMNS) == 5
                        && new org.json.JSONArray(coldConcPrefs.getString(Prefs.WATCH_HISTORY))
                                .getJSONObject(0)
                                .getString("episode")
                                .equals("EP02"),
                "R6.1A: Concurrent reader during COMMITTING_PREFS never rolls back live WAL; cold read is consistent newA/newB + 5 cols + EP02");

        // 1B. Crash BEFORE markCommittingPrefs (PREPARED) rolls back to OLD; crash AFTER
        // markCommittingPrefs before prefs commit rolls forward BOTH files AND prefs on cold start!
        File prePrefsCrashDir = new File(r6Dir, "crash_pre_prefs");
        prePrefsCrashDir.mkdirs();
        File preCrashPrefsFile = new File(prePrefsCrashDir, "prefs.json");
        Files.write(
                preCrashPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity preCrashAct = newHeadlessActivity(prePrefsCrashDir);
        ConfigLibrary preCrashLib = new ConfigLibrary(prePrefsCrashDir);
        preCrashAct.multiSourceStore.registerSubscription(
                preCrashLib, rawOldA, urlA, "A旧", true, 1L);
        preCrashAct.multiSourceStore.registerSubscription(
                preCrashLib, rawOldB, urlB, "B旧", true, 2L);
        preCrashAct.prefs = makeFileBackedPrefs(preCrashPrefsFile, null);
        SettingsScreen.BackupRestorePlan prePlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(archiveBytes), true);
        boolean preKilled = false;
        try {
            ConfigLibrary.restoreCommitFaultInjector =
                    step -> {
                        if ("config".equals(step)) {
                            throw new ConfigLibrary.SimulatedProcessKill("pre-prefs kill");
                        }
                    };
            SettingsScreen.commitBackupRestoreOnWorker(preCrashAct, prePlan);
        } catch (ConfigLibrary.SimulatedProcessKill expected) {
            preKilled = true;
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
            prePlan.cleanupTempFiles();
        }
        android.content.SharedPreferences preColdReplayPrefs =
                makeFileBackedPrefs(preCrashPrefsFile, null);
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(
                prePrefsCrashDir,
                newPrefs ->
                        SettingsScreen.applyRestorablePrefsSnapshot(
                                preColdReplayPrefs, newPrefs, false));
        TvMultiSourceStore.EffectiveBuild preCold =
                new TvMultiSourceStore(prePrefsCrashDir)
                        .buildEffectiveConfig(new ConfigLibrary(prePrefsCrashDir), "", null);
        org.json.JSONObject preColdPrefs =
                new org.json.JSONObject(
                        new String(
                                Files.readAllBytes(preCrashPrefsFile.toPath()),
                                StandardCharsets.UTF_8));
        check(
                preKilled
                        && preCold.config.sites.size() == 2
                        && "https://old.invalid/a".equals(preCold.config.sites.get(0).api)
                        && preColdPrefs.getInt(Prefs.HOME_COLUMNS) == 6
                        && new org.json.JSONArray(preColdPrefs.getString(Prefs.WATCH_HISTORY))
                                .getJSONObject(0)
                                .getString("episode")
                                .equals("EP01"),
                "R6.1B: Crash in PREPARED (before prefs) rolls back cleanly to oldA/oldB + 6 cols + EP01");

        File postMarkCrashDir = new File(r6Dir, "crash_post_mark_before_prefs");
        postMarkCrashDir.mkdirs();
        File postMarkPrefsFile = new File(postMarkCrashDir, "prefs.json");
        Files.write(
                postMarkPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity postMarkAct = newHeadlessActivity(postMarkCrashDir);
        ConfigLibrary postMarkLib = new ConfigLibrary(postMarkCrashDir);
        postMarkAct.multiSourceStore.registerSubscription(
                postMarkLib, rawOldA, urlA, "A旧", true, 1L);
        postMarkAct.multiSourceStore.registerSubscription(
                postMarkLib, rawOldB, urlB, "B旧", true, 2L);
        postMarkAct.prefs = makeFileBackedPrefs(postMarkPrefsFile, null);
        SettingsScreen.BackupRestorePlan postPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(archiveBytes), true);
        boolean postMarkKilled = false;
        try {
            ConfigLibrary.restoreCommitFaultInjector =
                    step -> {
                        if ("committing_prefs".equals(step)) {
                            throw new ConfigLibrary.SimulatedProcessKill("post-mark kill");
                        }
                    };
            SettingsScreen.commitBackupRestoreOnWorker(postMarkAct, postPlan);
        } catch (ConfigLibrary.SimulatedProcessKill expected) {
            postMarkKilled = true;
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
            postPlan.cleanupTempFiles();
        }
        // Cold boot with SharedPreferences replays new-prefs.json AND rolls forward files
        android.content.SharedPreferences postColdReplayPrefs =
                makeFileBackedPrefs(postMarkPrefsFile, null);
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(
                postMarkCrashDir,
                newPrefs ->
                        SettingsScreen.applyRestorablePrefsSnapshot(
                                postColdReplayPrefs, newPrefs, false));
        TvMultiSourceStore.EffectiveBuild postCold =
                new TvMultiSourceStore(postMarkCrashDir)
                        .buildEffectiveConfig(new ConfigLibrary(postMarkCrashDir), "", null);
        org.json.JSONObject postColdPrefs =
                new org.json.JSONObject(
                        new String(
                                Files.readAllBytes(postMarkPrefsFile.toPath()),
                                StandardCharsets.UTF_8));
        check(
                postMarkKilled
                        && !new File(postMarkCrashDir, "restore-tx/manifest.json").exists()
                        && postCold.config.sites.size() == 2
                        && "https://new.invalid/a".equals(postCold.config.sites.get(0).api)
                        && postColdPrefs.getInt(Prefs.HOME_COLUMNS) == 5
                        && new org.json.JSONArray(postColdPrefs.getString(Prefs.WATCH_HISTORY))
                                .getJSONObject(0)
                                .getString("episode")
                                .equals("EP02"),
                "R6.1C: Crash in COMMITTING_PREFS before prefs write rolls forward files AND replays prefs+history cleanly on cold boot");

        // 2. Watch history survives blocked STORAGE_EXECUTOR AND blocks stale pre-restore upsert!
        File busyHistDir = new File(r6Dir, "busy_hist");
        busyHistDir.mkdirs();
        File busyPrefsFile = new File(busyHistDir, "prefs.json");
        Files.write(
                busyPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity busyAct = newHeadlessActivity(busyHistDir);
        ConfigLibrary busyLib = new ConfigLibrary(busyHistDir);
        busyAct.multiSourceStore.registerSubscription(busyLib, rawOldA, urlA, "A旧", true, 1L);
        busyAct.prefs = makeFileBackedPrefs(busyPrefsFile, null);
        final java.util.concurrent.CountDownLatch blockStarted =
                new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch releaseBlock =
                new java.util.concurrent.CountDownLatch(1);
        WatchHistory.STORAGE_EXECUTOR.execute(
                () -> {
                    blockStarted.countDown();
                    try {
                        releaseBlock.await(10, java.util.concurrent.TimeUnit.SECONDS);
                    } catch (InterruptedException ignored) {
                        Thread.currentThread().interrupt();
                    }
                });
        check(
                blockStarted.await(5, java.util.concurrent.TimeUnit.SECONDS),
                "R6.2: STORAGE_EXECUTOR blocker started");
        // Queue a stale playback save BEFORE backup restore commits
        WatchHistory.Entry staleEntry = new WatchHistory.Entry();
        staleEntry.site = "oldSite";
        staleEntry.id = "stalePreRestore";
        staleEntry.title = "stalePreRestore";
        staleEntry.episode = "EP01";
        staleEntry.position = 11111;
        staleEntry.duration = 1800000;
        java.util.concurrent.Future<String> staleFuture =
                WatchHistory.enqueueUpsert(busyAct.historyPersistence(), staleEntry);
        SettingsScreen.BackupRestorePlan busyPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(archiveBytes), true);
        try {
            SettingsScreen.restoreUiRefreshHookForTest =
                    () -> {
                        throw new IllegalStateException("R6 UI failure");
                    };
            SettingsScreen.BackupRestoreCommitResult busyRes =
                    SettingsScreen.commitBackupRestoreOnWorker(busyAct, busyPlan);
            Throwable uiErr = SettingsScreen.publishBackupRestoreUi(busyAct, busyRes, -1);
            // Verify IMMEDIATELY while STORAGE_EXECUTOR is STILL blocked!
            org.json.JSONObject immediatePrefs =
                    new org.json.JSONObject(
                            new String(
                                    Files.readAllBytes(busyPrefsFile.toPath()),
                                    StandardCharsets.UTF_8));
            org.json.JSONObject hist0 =
                    new org.json.JSONArray(immediatePrefs.getString(Prefs.WATCH_HISTORY))
                            .getJSONObject(0);
            check(
                    busyRes.committed
                            && uiErr != null
                            && "backupEp".equals(hist0.getString("id"))
                            && "EP02".equals(hist0.getString("episode"))
                            && hist0.getInt("position") == 720000,
                    "R6.2A: Watch history EP02@12:00 is durably committed BEFORE UI publish & without blocking on busy STORAGE_EXECUTOR");
        } finally {
            SettingsScreen.restoreUiRefreshHookForTest = null;
            busyPlan.cleanupTempFiles();
            releaseBlock.countDown();
        }
        staleFuture.get(5, java.util.concurrent.TimeUnit.SECONDS);
        org.json.JSONArray afterDrain =
                new org.json.JSONArray(
                        new org.json.JSONObject(
                                        new String(
                                                Files.readAllBytes(busyPrefsFile.toPath()),
                                                StandardCharsets.UTF_8))
                                .getString(Prefs.WATCH_HISTORY));
        check(
                afterDrain.length() == 1
                        && "backupEp".equals(afterDrain.getJSONObject(0).getString("id")),
                "R6.2B: Stale pre-restore WatchHistory upsert queued behind blocker cannot overwrite restored EP02@12:00");

        // 3. Legacy T4 snapshot recovery: opaque literal ext vs relative ./doc AND Referer header
        //    routing + positive controls (relative vs absolute remote doc & case-insensitive
        // header)
        String t4Origin = "http://127.0.0.1:18080/sub.json";
        String t4Api = "http://127.0.0.1:18080/t4";

        // 3A: opaque "catalog" vs relative "./catalog"
        File t4LitDir = new File(r6Dir, "t4_opaque_vs_doc");
        t4LitDir.mkdirs();
        ConfigLibrary t4LitLib = new ConfigLibrary(t4LitDir);
        TvMultiSourceStore t4LitStore = new TvMultiSourceStore(t4LitDir);
        String oldDocRaw =
                "{\"sites\":[{\"key\":\"keep\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"./catalog\",\"headers\":{\"Referer\":\"https://fixture.invalid/same\"}}]}";
        TvMultiSourceStore.SubscriptionRecord litRec =
                t4LitStore.registerSubscription(t4LitLib, oldDocRaw, t4Origin, "T4Lit", true, 1L);
        String curLitRaw =
                "{\"sites\":[{\"key\":\""
                        + TvMultiSourceStore.stableSiteKey(litRec.id, "keep")
                        + "\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"catalog\",\"headers\":{\"Referer\":\"https://fixture.invalid/same\"}}]}";
        ConfigLibrary.Entry litDmg = t4LitLib.remember(curLitRaw, t4Origin, "T4Lit", "", 2L);
        File litIdx = new File(t4LitLib.directory, "index.json");
        org.json.JSONArray litArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(litIdx.toPath()), StandardCharsets.UTF_8));
        litArr.getJSONObject(0).remove("cleanHistory");
        Files.write(litIdx.toPath(), litArr.toString().getBytes(StandardCharsets.UTF_8));
        TvMultiSourceStore litCold = new TvMultiSourceStore(t4LitDir);
        TvMultiSourceStore.EffectiveBuild litBuilt =
                litCold.buildEffectiveConfig(t4LitLib, "", null);
        check(
                litDmg.digest.equals(t4LitLib.entries().get(0).digest)
                        && "catalog".equals(String.valueOf(litBuilt.config.sites.get(0).ext)),
                "R6.3A: T4 opaque literal ext='catalog' does NOT match old relative document ext='./catalog'");

        // 3B: different Referer header on same T4 key/api/ext
        File t4HdrDir = new File(r6Dir, "t4_header_route");
        t4HdrDir.mkdirs();
        ConfigLibrary t4HdrLib = new ConfigLibrary(t4HdrDir);
        TvMultiSourceStore t4HdrStore = new TvMultiSourceStore(t4HdrDir);
        String oldHdrRaw =
                "{\"sites\":[{\"key\":\"keep\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"catalog\",\"headers\":{\"Referer\":\"https://fixture.invalid/withdrawn\"}}]}";
        TvMultiSourceStore.SubscriptionRecord hdrRec =
                t4HdrStore.registerSubscription(t4HdrLib, oldHdrRaw, t4Origin, "T4Hdr", true, 1L);
        String curHdrRaw =
                "{\"sites\":[{\"key\":\""
                        + TvMultiSourceStore.stableSiteKey(hdrRec.id, "keep")
                        + "\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"catalog\",\"headers\":{\"Referer\":\"https://fixture.invalid/current\"}}]}";
        ConfigLibrary.Entry hdrDmg = t4HdrLib.remember(curHdrRaw, t4Origin, "T4Hdr", "", 2L);
        File hdrIdx = new File(t4HdrLib.directory, "index.json");
        org.json.JSONArray hdrArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(hdrIdx.toPath()), StandardCharsets.UTF_8));
        hdrArr.getJSONObject(0).remove("cleanHistory");
        Files.write(hdrIdx.toPath(), hdrArr.toString().getBytes(StandardCharsets.UTF_8));
        TvMultiSourceStore hdrCold = new TvMultiSourceStore(t4HdrDir);
        TvMultiSourceStore.EffectiveBuild hdrBuilt =
                hdrCold.buildEffectiveConfig(t4HdrLib, "", null);
        check(
                hdrDmg.digest.equals(t4HdrLib.entries().get(0).digest)
                        && "https://fixture.invalid/current"
                                .equals(hdrBuilt.config.sites.get(0).headers.get("Referer")),
                "R6.3B: T4 recovery rejects old snapshot whose Referer header differs from current route");

        // 3C: Positive control — relative "./catalog" matches absolute
        // "http://127.0.0.1:18080/catalog"
        //     with case-insensitive Referer header
        File t4PosDir = new File(r6Dir, "t4_rel_abs_positive");
        t4PosDir.mkdirs();
        ConfigLibrary t4PosLib = new ConfigLibrary(t4PosDir);
        TvMultiSourceStore t4PosStore = new TvMultiSourceStore(t4PosDir);
        String cleanRelRaw =
                "{\"sites\":["
                        + "{\"key\":\"keep\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"./catalog\",\"headers\":{\"referer\":\"https://fixture.invalid/same\"}},"
                        + "{\"key\":\"extra\",\"name\":\"Extra\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"extra\"}"
                        + "]}";
        TvMultiSourceStore.SubscriptionRecord posRec =
                t4PosStore.registerSubscription(t4PosLib, cleanRelRaw, t4Origin, "T4Pos", true, 1L);
        ConfigLibrary.Entry posClean = t4PosLib.entries().get(0);
        t4PosStore.setSiteDisabled(posRec.id, "extra", true);
        String survAbsRaw =
                "{\"sites\":[{\"key\":\""
                        + TvMultiSourceStore.stableSiteKey(posRec.id, "keep")
                        + "\",\"name\":\"T4\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"http://127.0.0.1:18080/catalog\",\"headers\":{\"Referer\":\"https://fixture.invalid/same\"}}]}";
        t4PosLib.remember(survAbsRaw, t4Origin, "T4Pos", "", 2L);
        File posIdx = new File(t4PosLib.directory, "index.json");
        org.json.JSONArray posArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(posIdx.toPath()), StandardCharsets.UTF_8));
        posArr.getJSONObject(0).remove("cleanHistory");
        Files.write(posIdx.toPath(), posArr.toString().getBytes(StandardCharsets.UTF_8));
        TvMultiSourceStore posCold = new TvMultiSourceStore(t4PosDir);
        posCold.buildEffectiveConfig(t4PosLib, "", null);
        check(
                posClean.digest.equals(t4PosLib.entries().get(0).digest)
                        && posCold.recoveryHintFor(posRec.id).isEmpty(),
                "R6.3C: Positive control — relative ./catalog matches absolute http://.../catalog with same headers");
    }

    private static void testSeventhRecheckReworkContracts(File rootDir) throws Exception {
        File r7Dir = new File(rootDir, "recheck7_contracts");
        r7Dir.mkdirs();

        final String urlA = "https://r7-a.invalid/c.json";
        final String urlB = "https://r7-b.invalid/c.json";
        final String rawOldA =
                "{\"sites\":[{\"key\":\"oldA\",\"name\":\"旧A\",\"type\":1,\"api\":\"https://old.invalid/a\"}]}";
        final String rawOldB =
                "{\"sites\":[{\"key\":\"oldB\",\"name\":\"旧B\",\"type\":1,\"api\":\"https://old.invalid/b\"}]}";
        final String rawNewA =
                "{\"sites\":[{\"key\":\"newA\",\"name\":\"新A\",\"type\":1,\"api\":\"https://new.invalid/a\"}]}";
        final String rawNewB =
                "{\"sites\":[{\"key\":\"newB\",\"name\":\"新B\",\"type\":1,\"api\":\"https://new.invalid/b\"}]}";
        final String oldHist =
                "[{\"site\":\"oldSite\",\"id\":\"oldEp\",\"title\":\"oldEp\",\"episode\":\"EP01\",\"position\":60000,\"duration\":1800000}]";
        final String newHist =
                "[{\"site\":\"backupSite\",\"id\":\"backupEp\",\"title\":\"backupEp\",\"episode\":\"EP02\",\"position\":720000,\"duration\":1800000}]";

        // Build base archive + large >2 MiB prefs archive (60 watch history rows with 36 KB
        // posters)
        File srcDir = new File(r7Dir, "src");
        srcDir.mkdirs();
        MainActivity srcAct = newHeadlessActivity(srcDir);
        ConfigLibrary srcLib = new ConfigLibrary(srcDir);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewA, urlA, "A新", true, 1L);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewB, urlB, "B新", true, 2L);
        srcAct.config = srcAct.multiSourceStore.buildEffectiveConfig(srcLib, "", null).config;
        org.json.JSONObject smallArchive = SettingsScreen.buildBackupJson(srcAct);
        smallArchive
                .getJSONObject("settings")
                .put(Prefs.HOME_COLUMNS, 5)
                .put(Prefs.WATCH_HISTORY, newHist);
        byte[] smallArchiveBytes = smallArchive.toString().getBytes(StandardCharsets.UTF_8);

        org.json.JSONArray largeHistRows = new org.json.JSONArray();
        StringBuilder pad36k = new StringBuilder(36 * 1024);
        for (int p = 0; p < 36 * 1024; p++) pad36k.append('A');
        String poster36k = "data:image/png;base64," + pad36k.toString();
        for (int i = 0; i < WatchHistory.LIMIT; i++) {
            largeHistRows.put(
                    new org.json.JSONObject()
                            .put("site", "backupSite")
                            .put("id", i == 0 ? "backupEp" : "row-" + i)
                            .put("title", i == 0 ? "backupEp" : "row-" + i)
                            .put("episode", "EP02")
                            .put("position", 720000)
                            .put("duration", 1800000)
                            .put("poster", poster36k));
        }
        org.json.JSONObject largeArchive = new org.json.JSONObject(smallArchive.toString());
        largeArchive.getJSONObject("settings").put(Prefs.WATCH_HISTORY, largeHistRows.toString());
        byte[] largeArchiveBytes = largeArchive.toString().getBytes(StandardCharsets.UTF_8);
        check(
                largeArchiveBytes.length > 2 * 1024 * 1024,
                "R7.1: Large valid archive (" + largeArchiveBytes.length + " B) exceeds 2 MiB");

        // 1A. Crash in COMMITTING_PREFS on >2 MiB prefs snapshot -> cold replay succeeds cleanly!
        File bigDir = new File(r7Dir, "wal_large_crash");
        bigDir.mkdirs();
        File bigPrefsFile = new File(bigDir, "prefs.json");
        Files.write(
                bigPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity bigAct = newHeadlessActivity(bigDir);
        ConfigLibrary bigLib = new ConfigLibrary(bigDir);
        bigAct.multiSourceStore.registerSubscription(bigLib, rawOldA, urlA, "A旧", true, 1L);
        bigAct.multiSourceStore.registerSubscription(bigLib, rawOldB, urlB, "B旧", true, 2L);
        bigAct.prefs = makeFileBackedPrefs(bigPrefsFile, null);
        SettingsScreen.BackupRestorePlan bigPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(largeArchiveBytes), true);
        boolean bigKilled = false;
        try {
            ConfigLibrary.restoreCommitFaultInjector =
                    step -> {
                        if ("committing_prefs".equals(step)) {
                            throw new ConfigLibrary.SimulatedProcessKill("kill large pre-prefs");
                        }
                    };
            SettingsScreen.commitBackupRestoreOnWorker(bigAct, bigPlan);
        } catch (ConfigLibrary.SimulatedProcessKill expected) {
            bigKilled = true;
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
            bigPlan.cleanupTempFiles();
        }
        // Ordinary reads BEFORE replay must preserve the WAL!
        new TvMultiSourceStore(bigDir).readState();
        new ConfigLibrary(bigDir).entries();
        boolean walKeptAfterOrdinaryReads = new File(bigDir, "restore-tx/manifest.json").isFile();
        android.content.SharedPreferences bigColdPrefs = makeFileBackedPrefs(bigPrefsFile, null);
        int[] bigCalls = {0};
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(
                bigDir,
                snap -> {
                    bigCalls[0]++;
                    SettingsScreen.applyRestorablePrefsSnapshot(bigColdPrefs, snap, true);
                });
        org.json.JSONObject bigPrefsAfter =
                new org.json.JSONObject(
                        new String(
                                Files.readAllBytes(bigPrefsFile.toPath()), StandardCharsets.UTF_8));
        check(
                bigKilled
                        && walKeptAfterOrdinaryReads
                        && bigCalls[0] == 1
                        && !new File(bigDir, "restore-tx/manifest.json").exists()
                        && bigPrefsAfter.getInt(Prefs.HOME_COLUMNS) == 5
                        && "backupEp"
                                .equals(
                                        new org.json.JSONArray(
                                                        bigPrefsAfter.getString(
                                                                Prefs.WATCH_HISTORY))
                                                .getJSONObject(0)
                                                .getString("id")),
                "R7.1A: >2 MiB COMMITTING_PREFS snapshot survives ordinary reads and replays cleanly on cold boot");

        // 1B. Transient replay error + ordinary read preserves WAL -> retry succeeds -> later
        // updates survive cold restart
        File transDir = new File(r7Dir, "wal_transient");
        transDir.mkdirs();
        File transPrefsFile = new File(transDir, "prefs.json");
        Files.write(
                transPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity transAct = newHeadlessActivity(transDir);
        ConfigLibrary transLib = new ConfigLibrary(transDir);
        transAct.multiSourceStore.registerSubscription(transLib, rawOldA, urlA, "A旧", true, 1L);
        transAct.multiSourceStore.registerSubscription(transLib, rawOldB, urlB, "B旧", true, 2L);
        transAct.prefs = makeFileBackedPrefs(transPrefsFile, null);
        SettingsScreen.BackupRestorePlan transPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(smallArchiveBytes), true);
        try {
            ConfigLibrary.restoreCommitFaultInjector =
                    step -> {
                        if ("committing_prefs".equals(step)) {
                            throw new ConfigLibrary.SimulatedProcessKill("kill small pre-prefs");
                        }
                    };
            SettingsScreen.commitBackupRestoreOnWorker(transAct, transPlan);
        } catch (ConfigLibrary.SimulatedProcessKill ignored) {
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
            transPlan.cleanupTempFiles();
        }
        android.content.SharedPreferences transReplayPrefs =
                makeFileBackedPrefs(transPrefsFile, null);
        int[] transCalls = {0};
        ConfigLibrary.PrefsReplayCallback flakyCb =
                snap -> {
                    transCalls[0]++;
                    if (transCalls[0] == 1) throw new IOException("transient failure");
                    SettingsScreen.applyRestorablePrefsSnapshot(transReplayPrefs, snap, true);
                };
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(transDir, flakyCb);
        boolean walAfterFlaky = new File(transDir, "restore-tx/manifest.json").isFile();
        new ConfigLibrary(transDir).entries();
        boolean walAfterOrdinaryEntries = new File(transDir, "restore-tx/manifest.json").isFile();
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(transDir, flakyCb);
        boolean walClearedOnRetry = !new File(transDir, "restore-tx/manifest.json").exists();
        // Subsequent user edits (laterC, 7 columns, later-watch) must persist across next cold boot
        TvMultiSourceStore postStore = new TvMultiSourceStore(transDir);
        postStore.registerSubscription(
                new ConfigLibrary(transDir),
                "{\"sites\":[{\"key\":\"laterC\",\"name\":\"C\",\"type\":1,\"api\":\"https://later.invalid/c\"}]}",
                "https://r7-c.invalid/c.json",
                "C",
                true,
                3L);
        transReplayPrefs
                .edit()
                .putInt(Prefs.HOME_COLUMNS, 7)
                .putString(
                        Prefs.WATCH_HISTORY,
                        "[{\"site\":\"later\",\"id\":\"laterWatch\",\"title\":\"later\",\"episode\":\"EP03\",\"position\":30000,\"duration\":1800000}]")
                .commit();
        TvMultiSourceStore.EffectiveBuild afterLater =
                new TvMultiSourceStore(transDir)
                        .buildEffectiveConfig(new ConfigLibrary(transDir), "", null);
        check(
                walAfterFlaky
                        && walAfterOrdinaryEntries
                        && walClearedOnRetry
                        && transCalls[0] == 2
                        && afterLater.config.sites.size() == 3
                        && transReplayPrefs.getInt(Prefs.HOME_COLUMNS, 0) == 7
                        && transReplayPrefs
                                .getString(Prefs.WATCH_HISTORY, "")
                                .contains("laterWatch"),
                "R7.1B: Transient replay error keeps WAL across ordinary reads, succeeds on retry, and preserves later updates");

        // 1C. Single-generation concurrent reads at 3 pause points: before prefs.edit (OLD gen),
        //     after prefs_persisted before finalize (NEW gen), after return (NEW gen)
        File concDir = new File(r7Dir, "wal_single_gen");
        concDir.mkdirs();
        File concPrefsFile = new File(concDir, "prefs.json");
        Files.write(
                concPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity concAct = newHeadlessActivity(concDir);
        ConfigLibrary concLib = new ConfigLibrary(concDir);
        concAct.multiSourceStore.registerSubscription(concLib, rawOldA, urlA, "A旧", true, 1L);
        concAct.multiSourceStore.registerSubscription(concLib, rawOldB, urlB, "B旧", true, 2L);
        final android.content.SharedPreferences realConcPrefs =
                makeFileBackedPrefs(concPrefsFile, null);
        final String[] genBeforePrefs = {""};
        final int[] colsBeforePrefs = {-1};
        final String[] genAfterPrefs = {""};
        final int[] colsAfterPrefs = {-1};
        java.util.concurrent.ExecutorService concReader =
                java.util.concurrent.Executors.newSingleThreadExecutor();
        concAct.prefs =
                (android.content.SharedPreferences)
                        java.lang.reflect.Proxy.newProxyInstance(
                                TvPlaybackMultiSourceChecks.class.getClassLoader(),
                                new Class<?>[] {android.content.SharedPreferences.class},
                                (proxy, method, args) -> {
                                    if ("edit".equals(method.getName())
                                            && new File(concDir, "restore-tx/manifest.json")
                                                    .isFile()) {
                                        concReader
                                                .submit(
                                                        () -> {
                                                            TvMultiSourceStore.EffectiveBuild eb =
                                                                    new TvMultiSourceStore(concDir)
                                                                            .buildEffectiveConfig(
                                                                                    new ConfigLibrary(
                                                                                            concDir),
                                                                                    "",
                                                                                    null);
                                                            genBeforePrefs[0] =
                                                                    eb.config.sites.get(0).api;
                                                            colsBeforePrefs[0] =
                                                                    realConcPrefs.getInt(
                                                                            Prefs.HOME_COLUMNS, 0);
                                                            return null;
                                                        })
                                                .get(5, java.util.concurrent.TimeUnit.SECONDS);
                                    }
                                    return method.invoke(realConcPrefs, args);
                                });
        SettingsScreen.BackupRestorePlan concPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(smallArchiveBytes), true);
        try {
            ConfigLibrary.restoreCommitFaultInjector =
                    step -> {
                        if ("prefs_persisted".equals(step)) {
                            concReader
                                    .submit(
                                            () -> {
                                                TvMultiSourceStore.EffectiveBuild eb =
                                                        new TvMultiSourceStore(concDir)
                                                                .buildEffectiveConfig(
                                                                        new ConfigLibrary(concDir),
                                                                        "",
                                                                        null);
                                                genAfterPrefs[0] = eb.config.sites.get(0).api;
                                                colsAfterPrefs[0] =
                                                        realConcPrefs.getInt(Prefs.HOME_COLUMNS, 0);
                                                return null;
                                            })
                                    .get(5, java.util.concurrent.TimeUnit.SECONDS);
                        }
                    };
            SettingsScreen.commitBackupRestoreOnWorker(concAct, concPlan);
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
            concPlan.cleanupTempFiles();
            concReader.shutdownNow();
        }
        TvMultiSourceStore.EffectiveBuild afterConc =
                new TvMultiSourceStore(concDir)
                        .buildEffectiveConfig(new ConfigLibrary(concDir), "", null);
        check(
                "https://old.invalid/a".equals(genBeforePrefs[0])
                        && colsBeforePrefs[0] == 6
                        && "https://new.invalid/a".equals(genAfterPrefs[0])
                        && colsAfterPrefs[0] == 5
                        && "https://new.invalid/a".equals(afterConc.config.sites.get(0).api)
                        && realConcPrefs.getInt(Prefs.HOME_COLUMNS, 0) == 5,
                "R7.1C: Concurrent reads see single consistent generation before prefs.edit (old+6), after prefs_persisted (new+5), and after return (new+5)");

        // 2. In-flight WatchHistory upsert/migrate/remove/clear paused after reading old snapshot
        //    cannot clobber restored history, while post-restore user progress IS preserved!
        File ovDir = new File(r7Dir, "history_overlap");
        ovDir.mkdirs();
        File ovPrefsFile = new File(ovDir, "prefs.json");
        Files.write(
                ovPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity ovAct = newHeadlessActivity(ovDir);
        ConfigLibrary ovLib = new ConfigLibrary(ovDir);
        ovAct.multiSourceStore.registerSubscription(ovLib, rawOldA, urlA, "A旧", true, 1L);
        ovAct.prefs = makeFileBackedPrefs(ovPrefsFile, null);
        WatchHistory.Persistence realOv = ovAct.historyPersistence();
        final java.util.concurrent.CountDownLatch readOldDone =
                new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch releaseOld =
                new java.util.concurrent.CountDownLatch(1);
        WatchHistory.Persistence pausedOv =
                new WatchHistory.Persistence() {
                    @Override
                    public String readRaw() {
                        String snap = realOv.readRaw();
                        readOldDone.countDown();
                        try {
                            releaseOld.await(10, java.util.concurrent.TimeUnit.SECONDS);
                        } catch (InterruptedException ignored) {
                            Thread.currentThread().interrupt();
                        }
                        return snap;
                    }

                    @Override
                    public boolean readCorruptedPref() {
                        return realOv.readCorruptedPref();
                    }

                    @Override
                    public void writeState(String historyJson, boolean corrupted) {
                        realOv.writeState(historyJson, corrupted);
                    }
                };
        WatchHistory.Entry staleProgress = new WatchHistory.Entry();
        staleProgress.site = "oldSite";
        staleProgress.id = "oldEp";
        staleProgress.title = "Old";
        staleProgress.episode = "EP01";
        staleProgress.position = 90000;
        staleProgress.duration = 1800000;
        java.util.concurrent.Future<String> overlapFut =
                WatchHistory.enqueueUpsert(pausedOv, staleProgress);
        check(
                readOldDone.await(5, java.util.concurrent.TimeUnit.SECONDS),
                "R7.2: Paused in-flight WatchHistory writer read old snapshot");
        SettingsScreen.BackupRestorePlan ovPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(smallArchiveBytes), true);
        try {
            SettingsScreen.commitBackupRestoreOnWorker(ovAct, ovPlan);
        } finally {
            ovPlan.cleanupTempFiles();
            releaseOld.countDown();
        }
        overlapFut.get(5, java.util.concurrent.TimeUnit.SECONDS);
        org.json.JSONArray afterOverlap = new org.json.JSONArray(realOv.readRaw());
        // Now submit a brand-new post-restore user progress entry and verify it persists!
        WatchHistory.Entry postRestoreUser = new WatchHistory.Entry();
        postRestoreUser.site = "backupSite";
        postRestoreUser.id = "userNewEp";
        postRestoreUser.title = "UserNew";
        postRestoreUser.episode = "EP05";
        postRestoreUser.position = 240000;
        postRestoreUser.duration = 1800000;
        WatchHistory.enqueueUpsert(realOv, postRestoreUser)
                .get(5, java.util.concurrent.TimeUnit.SECONDS);
        org.json.JSONArray afterUserWrite = new org.json.JSONArray(realOv.readRaw());
        check(
                afterOverlap.length() == 1
                        && "backupEp".equals(afterOverlap.getJSONObject(0).getString("id"))
                        && afterOverlap.getJSONObject(0).getInt("position") == 720000
                        && afterUserWrite.length() == 2
                        && "userNewEp".equals(afterUserWrite.getJSONObject(0).getString("id"))
                        && afterUserWrite.getJSONObject(0).getInt("position") == 240000
                        && "backupEp".equals(afterUserWrite.getJSONObject(1).getString("id")),
                "R7.2: In-flight pre-restore WatchHistory write cannot clobber backup EP02@720000, while post-restore user progress persists");

        // 3. T4 transport threshold (GET <= 1000 vs POST > 1000) & leading-space " ./catalog" vs
        //    "./catalog" + 3 positive controls
        String t4Origin = "http://127.0.0.1:18081/sub.json";
        String t4Api = "http://127.0.0.1:18081/t4";

        // 3A: compact JSON (877 -> GET) vs pretty JSON (1256 -> POST)
        org.json.JSONObject fields = new org.json.JSONObject();
        for (int i = 0; i < 64; i++) fields.put("key" + i, "v" + i);
        String compactJson = fields.toString();
        String prettyJson = compactJson.replace(",", ",\n    ").replace(":", ": ");
        File trDir = new File(r7Dir, "t4_transport_threshold");
        trDir.mkdirs();
        ConfigLibrary trLib = new ConfigLibrary(trDir);
        TvMultiSourceStore trStore = new TvMultiSourceStore(trDir);
        String histPostRaw =
                new org.json.JSONObject()
                        .put(
                                "sites",
                                new org.json.JSONArray()
                                        .put(
                                                new org.json.JSONObject()
                                                        .put("key", "keep")
                                                        .put("name", "Keep")
                                                        .put("type", 4)
                                                        .put("api", t4Api)
                                                        .put("ext", prettyJson))
                                        .put(
                                                new org.json.JSONObject()
                                                        .put("key", "other")
                                                        .put("name", "Other")
                                                        .put("type", 4)
                                                        .put("api", t4Api)))
                        .toString();
        TvMultiSourceStore.SubscriptionRecord trRec =
                trStore.registerSubscription(trLib, histPostRaw, t4Origin, "T4Tr", true, 1L);
        String curGetRaw =
                new org.json.JSONObject()
                        .put(
                                "sites",
                                new org.json.JSONArray()
                                        .put(
                                                new org.json.JSONObject()
                                                        .put(
                                                                "key",
                                                                TvMultiSourceStore.stableSiteKey(
                                                                        trRec.id, "keep"))
                                                        .put("name", "Keep")
                                                        .put("type", 4)
                                                        .put("api", t4Api)
                                                        .put("ext", compactJson)))
                        .toString();
        ConfigLibrary.Entry trDmg = trLib.remember(curGetRaw, t4Origin, "T4Tr", "", 2L);
        File trIdx = new File(trLib.directory, "index.json");
        org.json.JSONArray trArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(trIdx.toPath()), StandardCharsets.UTF_8));
        trArr.getJSONObject(0).remove("cleanHistory");
        Files.write(trIdx.toPath(), trArr.toString().getBytes(StandardCharsets.UTF_8));
        TvMultiSourceStore trCold = new TvMultiSourceStore(trDir);
        TvMultiSourceStore.EffectiveBuild trBuilt = trCold.buildEffectiveConfig(trLib, "", null);
        check(
                trDmg.digest.equals(trLib.entries().get(0).digest)
                        && trBuilt.config.sites.get(0).ext.toString().trim().length() <= 1000,
                "R7.3A: T4 GET-sized compact JSON does NOT recover POST-sized (>1000) historical pretty JSON");

        // 3B: leading-space " ./catalog" (literal) vs "./catalog" (remote doc)
        File padDir = new File(r7Dir, "t4_padded_literal");
        padDir.mkdirs();
        ConfigLibrary padLib = new ConfigLibrary(padDir);
        TvMultiSourceStore padStore = new TvMultiSourceStore(padDir);
        String histDocRaw =
                "{\"sites\":[{\"key\":\"keep\",\"name\":\"Keep\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\"./catalog\"},{\"key\":\"other\",\"name\":\"Other\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\"}]}";
        TvMultiSourceStore.SubscriptionRecord padRec =
                padStore.registerSubscription(padLib, histDocRaw, t4Origin, "T4Pad", true, 1L);
        String curPaddedRaw =
                "{\"sites\":[{\"key\":\""
                        + TvMultiSourceStore.stableSiteKey(padRec.id, "keep")
                        + "\",\"name\":\"Keep\",\"type\":4,\"api\":\""
                        + t4Api
                        + "\",\"ext\":\" ./catalog\"}]}";
        ConfigLibrary.Entry padDmg = padLib.remember(curPaddedRaw, t4Origin, "T4Pad", "", 2L);
        File padIdx = new File(padLib.directory, "index.json");
        org.json.JSONArray padArr =
                new org.json.JSONArray(
                        new String(Files.readAllBytes(padIdx.toPath()), StandardCharsets.UTF_8));
        padArr.getJSONObject(0).remove("cleanHistory");
        Files.write(padIdx.toPath(), padArr.toString().getBytes(StandardCharsets.UTF_8));
        TvMultiSourceStore padCold = new TvMultiSourceStore(padDir);
        TvMultiSourceStore.EffectiveBuild padBuilt = padCold.buildEffectiveConfig(padLib, "", null);
        check(
                padDmg.digest.equals(padLib.entries().get(0).digest)
                        && " ./catalog".equals(String.valueOf(padBuilt.config.sites.get(0).ext)),
                "R7.3B: T4 leading-space literal ' ./catalog' does NOT recover remote doc './catalog'");
    }

    private static void testEighthRecheckReworkContracts(File tmpRoot) throws Exception {
        File r8Dir = new File(tmpRoot, "r8_rework");
        r8Dir.mkdirs();

        String urlA = "https://r8-a.invalid/c.json";
        String urlB = "https://r8-b.invalid/c.json";
        String rawOldA =
                "{\"sites\":[{\"key\":\"oldA\",\"name\":\"旧A\",\"type\":1,\"api\":\"https://old.invalid/a\"}]}";
        String rawOldB =
                "{\"sites\":[{\"key\":\"oldB\",\"name\":\"旧B\",\"type\":1,\"api\":\"https://old.invalid/b\"}]}";
        String rawNewA =
                "{\"sites\":[{\"key\":\"newA\",\"name\":\"新A\",\"type\":1,\"api\":\"https://new.invalid/a\"}]}";
        String rawNewB =
                "{\"sites\":[{\"key\":\"newB\",\"name\":\"新B\",\"type\":1,\"api\":\"https://new.invalid/b\"}]}";
        String oldHist =
                "[{\"site\":\"oldSite\",\"id\":\"oldEp\",\"title\":\"Old\",\"episode\":\"EP01\",\"position\":60000,\"duration\":1800000,\"updated\":1000}]";
        String newHist =
                "[{\"site\":\"backupSite\",\"id\":\"backupEp\",\"title\":\"Backup\",\"episode\":\"EP02\",\"position\":720000,\"duration\":1800000,\"updated\":2000}]";

        File srcDir = new File(r8Dir, "src");
        srcDir.mkdirs();
        MainActivity srcAct = newHeadlessActivity(srcDir);
        ConfigLibrary srcLib = new ConfigLibrary(srcDir);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewA, urlA, "A新", true, 10L);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewB, urlB, "B新", true, 11L);
        TvMultiSourceStore.EffectiveBuild srcBuilt =
                srcAct.multiSourceStore.buildEffectiveConfig(srcLib, "", null);
        srcAct.config = srcBuilt.config;
        srcAct.configOrigin = srcBuilt.effectiveOrigin;
        org.json.JSONObject backup = SettingsScreen.buildBackupJson(srcAct);
        backup.getJSONObject("settings")
                .put(Prefs.HOME_COLUMNS, 5)
                .put(Prefs.WATCH_HISTORY, newHist);
        byte[] archiveBytes = backup.toString().getBytes(StandardCharsets.UTF_8);

        // R8.1A: Finalization I/O failure AFTER prefs persisted must NOT roll back files to OLD!
        File finDir = new File(r8Dir, "finalize_fail");
        finDir.mkdirs();
        File finPrefsFile = new File(finDir, "prefs.json");
        Files.write(
                finPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity finAct = newHeadlessActivity(finDir);
        ConfigLibrary finLib = new ConfigLibrary(finDir);
        finAct.multiSourceStore.registerSubscription(finLib, rawOldA, urlA, "A旧", true, 1L);
        finAct.multiSourceStore.registerSubscription(finLib, rawOldB, urlB, "B旧", true, 2L);
        finAct.prefs = makeFileBackedPrefs(finPrefsFile, null);
        SettingsScreen.BackupRestorePlan finPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(archiveBytes), true);
        boolean finThrew = false;
        try {
            ConfigLibrary.restoreCommitFaultInjector =
                    step -> {
                        if ("prefs_persisted".equals(step)) {
                            throw new IOException("injected finalize I/O error");
                        }
                    };
            SettingsScreen.commitBackupRestoreOnWorker(finAct, finPlan);
        } catch (IOException expected) {
            finThrew = true;
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
            finPlan.cleanupTempFiles();
        }
        TvMultiSourceStore.EffectiveBuild afterFinFail =
                new TvMultiSourceStore(finDir)
                        .buildEffectiveConfig(new ConfigLibrary(finDir), "", null);
        boolean walPreservedAfterFinFail = new File(finDir, "restore-tx/manifest.json").isFile();
        android.content.SharedPreferences finColdPrefs = makeFileBackedPrefs(finPrefsFile, null);
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(
                finDir,
                snap -> SettingsScreen.applyRestorablePrefsSnapshot(finColdPrefs, snap, true));
        boolean walClearedOnBoot = !new File(finDir, "restore-tx/manifest.json").exists();
        org.json.JSONObject finPrefsAfter =
                new org.json.JSONObject(
                        new String(
                                Files.readAllBytes(finPrefsFile.toPath()), StandardCharsets.UTF_8));
        check(
                finThrew
                        && walPreservedAfterFinFail
                        && walClearedOnBoot
                        && afterFinFail.config.sites.size() == 2
                        && "https://new.invalid/a".equals(afterFinFail.config.sites.get(0).api)
                        && "https://new.invalid/b".equals(afterFinFail.config.sites.get(1).api)
                        && finPrefsAfter.getInt(Prefs.HOME_COLUMNS) == 5
                        && finPrefsAfter.getString(Prefs.WATCH_HISTORY).contains("backupEp"),
                "R8.1A: Finalize failure after prefs commit keeps consistent NEW files + prefs + forward WAL and clears cleanly on next startup");

        // R8.1B: Concurrent read right when preferences become visible sees consistent NEW gen
        File visDir = new File(r8Dir, "visible_read");
        visDir.mkdirs();
        File visPrefsFile = new File(visDir, "prefs.json");
        Files.write(
                visPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity visAct = newHeadlessActivity(visDir);
        ConfigLibrary visLib = new ConfigLibrary(visDir);
        visAct.multiSourceStore.registerSubscription(visLib, rawOldA, urlA, "A旧", true, 1L);
        visAct.multiSourceStore.registerSubscription(visLib, rawOldB, urlB, "B旧", true, 2L);
        final String[] visObservedApi = {""};
        final int[] visObservedCols = {-1};
        java.util.concurrent.ExecutorService visReader =
                java.util.concurrent.Executors.newSingleThreadExecutor();
        visAct.prefs =
                makeFileBackedPrefs(
                        visPrefsFile,
                        () -> {
                            try {
                                visReader
                                        .submit(
                                                () -> {
                                                    TvMultiSourceStore.EffectiveBuild eb =
                                                            new TvMultiSourceStore(visDir)
                                                                    .buildEffectiveConfig(
                                                                            new ConfigLibrary(
                                                                                    visDir),
                                                                            "",
                                                                            null);
                                                    visObservedApi[0] = eb.config.sites.get(0).api;
                                                    org.json.JSONObject p =
                                                            new org.json.JSONObject(
                                                                    new String(
                                                                            Files.readAllBytes(
                                                                                    visPrefsFile
                                                                                            .toPath()),
                                                                            StandardCharsets
                                                                                    .UTF_8));
                                                    visObservedCols[0] =
                                                            p.getInt(Prefs.HOME_COLUMNS);
                                                    return null;
                                                })
                                        .get(3, java.util.concurrent.TimeUnit.SECONDS);
                            } catch (Exception e) {
                                throw new RuntimeException(e);
                            }
                        });
        SettingsScreen.BackupRestorePlan visPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(archiveBytes), true);
        try {
            SettingsScreen.commitBackupRestoreOnWorker(visAct, visPlan);
        } finally {
            visPlan.cleanupTempFiles();
            visReader.shutdownNow();
        }
        check(
                "https://new.invalid/a".equals(visObservedApi[0]) && visObservedCols[0] == 5,
                "R8.1B: Concurrent reader during visible preference write sees consistent NEW generation (newA + 5 cols)");

        // R8.1C: Concurrent read paused inside Editor.commit() BEFORE preferences become visible
        // must STILL observe consistent OLD generation (oldA + 6 cols + oldEp)
        File preComDir = new File(r8Dir, "before_commit_read");
        preComDir.mkdirs();
        File preComPrefsFile = new File(preComDir, "prefs.json");
        Files.write(
                preComPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity preComAct = newHeadlessActivity(preComDir);
        ConfigLibrary preComLib = new ConfigLibrary(preComDir);
        preComAct.multiSourceStore.registerSubscription(preComLib, rawOldA, urlA, "A旧", true, 1L);
        preComAct.multiSourceStore.registerSubscription(preComLib, rawOldB, urlB, "B旧", true, 2L);
        android.content.SharedPreferences realPreCom = makeFileBackedPrefs(preComPrefsFile, null);
        final String[] preComApi = {""};
        final int[] preComCols = {-1};
        java.util.concurrent.ExecutorService preComReader =
                java.util.concurrent.Executors.newSingleThreadExecutor();
        preComAct.prefs =
                (android.content.SharedPreferences)
                        java.lang.reflect.Proxy.newProxyInstance(
                                android.content.SharedPreferences.class.getClassLoader(),
                                new Class<?>[] {android.content.SharedPreferences.class},
                                (p, m, aArgs) -> {
                                    if ("edit".equals(m.getName())) {
                                        android.content.SharedPreferences.Editor realEd =
                                                realPreCom.edit();
                                        return java.lang.reflect.Proxy.newProxyInstance(
                                                android.content.SharedPreferences.Editor.class
                                                        .getClassLoader(),
                                                new Class<?>[] {
                                                    android.content.SharedPreferences.Editor.class
                                                },
                                                (ed, em, ea) -> {
                                                    String op = em.getName();
                                                    if ("commit".equals(op) || "apply".equals(op)) {
                                                        preComReader
                                                                .submit(
                                                                        () -> {
                                                                            TvMultiSourceStore
                                                                                            .EffectiveBuild
                                                                                    eb =
                                                                                            new TvMultiSourceStore(
                                                                                                            preComDir)
                                                                                                    .buildEffectiveConfig(
                                                                                                            new ConfigLibrary(
                                                                                                                    preComDir),
                                                                                                            "",
                                                                                                            null);
                                                                            preComApi[0] =
                                                                                    eb.config.sites
                                                                                            .get(0)
                                                                                            .api;
                                                                            preComCols[0] =
                                                                                    realPreCom
                                                                                            .getInt(
                                                                                                    Prefs
                                                                                                            .HOME_COLUMNS,
                                                                                                    -1);
                                                                            return null;
                                                                        })
                                                                .get(
                                                                        3,
                                                                        java.util.concurrent
                                                                                .TimeUnit.SECONDS);
                                                    }
                                                    Object ret = em.invoke(realEd, ea);
                                                    return ret == realEd ? ed : ret;
                                                });
                                    }
                                    return m.invoke(realPreCom, aArgs);
                                });
        SettingsScreen.BackupRestorePlan preComPlan =
                SettingsScreen.readAndValidateBackupStream(
                        new java.io.ByteArrayInputStream(archiveBytes), true);
        try {
            SettingsScreen.commitBackupRestoreOnWorker(preComAct, preComPlan);
        } finally {
            preComPlan.cleanupTempFiles();
            preComReader.shutdownNow();
        }
        check(
                "https://old.invalid/a".equals(preComApi[0]) && preComCols[0] == 6,
                "R8.1C: Concurrent reader inside Editor.commit() BEFORE prefs flip still sees consistent OLD generation (oldA + 6 cols)");

        // R8.2: CloudSync.mergeSerial paused after reading old history cannot overwrite restored
        // history AND returns refreshed post-restore payload!
        File cloudDir = new File(r8Dir, "cloud_overlap");
        cloudDir.mkdirs();
        File cloudPrefsFile = new File(cloudDir, "prefs.json");
        Files.write(
                cloudPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity cloudAct = newHeadlessActivity(cloudDir);
        ConfigLibrary cloudLib = new ConfigLibrary(cloudDir);
        cloudAct.multiSourceStore.registerSubscription(cloudLib, rawOldA, urlA, "A旧", true, 1L);
        android.content.SharedPreferences realCloudPrefs =
                makeFileBackedPrefs(cloudPrefsFile, null);
        cloudAct.prefs = realCloudPrefs;
        java.util.concurrent.CountDownLatch cloudReadOld =
                new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch cloudRelease =
                new java.util.concurrent.CountDownLatch(1);
        CloudSync.LocalStore pausedStore =
                new CloudSync.LocalStore() {
                    @Override
                    public String readHistoryJson() {
                        String raw = realCloudPrefs.getString(Prefs.WATCH_HISTORY, "[]");
                        cloudReadOld.countDown();
                        try {
                            cloudRelease.await(10, java.util.concurrent.TimeUnit.SECONDS);
                        } catch (InterruptedException ie) {
                            Thread.currentThread().interrupt();
                        }
                        return raw;
                    }

                    @Override
                    public String readFavoritesJson() {
                        return realCloudPrefs.getString(Prefs.FAVORITES, "[]");
                    }

                    @Override
                    public String readTombstonesJson() {
                        return realCloudPrefs.getString(Prefs.SYNC_TOMBSTONES, "");
                    }

                    @Override
                    public void writeMerged(String h, String f, String t, CloudSync.MergeResult r) {
                        realCloudPrefs
                                .edit()
                                .putString(Prefs.WATCH_HISTORY, h)
                                .putString(Prefs.FAVORITES, f)
                                .putString(Prefs.SYNC_TOMBSTONES, t)
                                .apply();
                    }
                };
        java.util.concurrent.ExecutorService cloudPool =
                java.util.concurrent.Executors.newFixedThreadPool(2);
        CloudSync.MergeResult mergedRes;
        try {
            java.util.concurrent.Future<CloudSync.MergeResult> mergeFut =
                    cloudPool.submit(
                            () ->
                                    CloudSync.mergeSerial(
                                            WatchHistory.STORAGE_EXECUTOR,
                                            pausedStore,
                                            null,
                                            false,
                                            true,
                                            "",
                                            System.currentTimeMillis()));
            check(
                    cloudReadOld.await(5, java.util.concurrent.TimeUnit.SECONDS),
                    "R8.2: Background cloud merge paused after reading old history");
            SettingsScreen.BackupRestorePlan cloudPlan =
                    SettingsScreen.readAndValidateBackupStream(
                            new java.io.ByteArrayInputStream(archiveBytes), true);
            try {
                SettingsScreen.commitBackupRestoreOnWorker(cloudAct, cloudPlan);
            } finally {
                cloudPlan.cleanupTempFiles();
                cloudRelease.countDown();
            }
            mergedRes = mergeFut.get(5, java.util.concurrent.TimeUnit.SECONDS);
        } finally {
            cloudRelease.countDown();
            cloudPool.shutdownNow();
        }
        String diskHistAfterCloud = realCloudPrefs.getString(Prefs.WATCH_HISTORY, "[]");
        check(
                diskHistAfterCloud.contains("backupEp")
                        && !diskHistAfterCloud.contains("oldEp")
                        && mergedRes.payloadJson.contains("backupEp")
                        && !mergedRes.payloadJson.contains("oldEp"),
                "R8.2: In-flight CloudSync.mergeSerial recomputes from post-restore history instead of overwriting or uploading stale oldEp");

        // R8.3: Legacy cold-start snapshot recovery preserves effective site searchable flag
        String sOrigin = "http://127.0.0.1:18082/sub.json";
        String sApi = "http://127.0.0.1:18082/t4";
        for (int dirCase = 0; dirCase < 3; dirCase++) {
            // 0 = same (1 vs omitted -> default 1, should recover); 1 = lost (old 0 vs cur 1, keep
            // cur); 2 = unexpected (old 1 vs cur 0, keep cur)
            boolean expectRecover = (dirCase == 0);
            File sDir = new File(r8Dir, "searchable_" + dirCase);
            sDir.mkdirs();
            ConfigLibrary sLib = new ConfigLibrary(sDir);
            TvMultiSourceStore sStore = new TvMultiSourceStore(sDir);
            org.json.JSONObject oldSite =
                    new org.json.JSONObject()
                            .put("key", "catalog")
                            .put("name", "Catalog")
                            .put("type", 4)
                            .put("api", sApi)
                            .put("ext", "catalog");
            if (dirCase == 1) oldSite.put("searchable", 0);
            else if (dirCase == 2) oldSite.put("searchable", 1);
            // dirCase == 0 omits searchable (default 1) to test default vs explicit 1 equivalence!
            String oldRaw =
                    new org.json.JSONObject()
                            .put(
                                    "sites",
                                    new org.json.JSONArray()
                                            .put(oldSite)
                                            .put(
                                                    new org.json.JSONObject()
                                                            .put("key", "other")
                                                            .put("name", "Other")
                                                            .put("type", 4)
                                                            .put("api", sApi)
                                                            .put("searchable", 0)))
                            .toString();
            TvMultiSourceStore.SubscriptionRecord sRec =
                    sStore.registerSubscription(sLib, oldRaw, sOrigin, "S", true, 1L);
            String curRaw =
                    new org.json.JSONObject()
                            .put(
                                    "sites",
                                    new org.json.JSONArray()
                                            .put(
                                                    new org.json.JSONObject()
                                                            .put(
                                                                    "key",
                                                                    TvMultiSourceStore
                                                                            .stableSiteKey(
                                                                                    sRec.id,
                                                                                    "catalog"))
                                                            .put("name", "Catalog")
                                                            .put("type", 4)
                                                            .put("api", sApi)
                                                            .put("ext", "catalog")
                                                            .put(
                                                                    "searchable",
                                                                    dirCase == 2 ? 0 : 1)))
                            .toString();
            ConfigLibrary.Entry curEnt = sLib.remember(curRaw, sOrigin, "S", "", 2L);
            File sIdx = new File(sLib.directory, "index.json");
            org.json.JSONArray sArr =
                    new org.json.JSONArray(
                            new String(Files.readAllBytes(sIdx.toPath()), StandardCharsets.UTF_8));
            sArr.getJSONObject(0).remove("cleanHistory");
            Files.write(sIdx.toPath(), sArr.toString().getBytes(StandardCharsets.UTF_8));
            TvMultiSourceStore.EffectiveBuild sBuilt =
                    new TvMultiSourceStore(sDir)
                            .buildEffectiveConfig(new ConfigLibrary(sDir), "", null);
            boolean keptCurrent = curEnt.digest.equals(sLib.entries().get(0).digest);
            check(
                    expectRecover
                            ? (!keptCurrent
                                    && sBuilt.config.sites.size() == 2
                                    && sBuilt.config.sites.get(0).searchable)
                            : (keptCurrent
                                    && sBuilt.config.sites.size() == 1
                                    && sBuilt.config.sites.get(0).searchable == (dirCase != 2)),
                    "R8.3 searchable preservation case " + dirCase);
        }

        // R8.4B: historyEntriesFingerprint invalidates on title/poster/line/index changes even
        // when timestamp & position are unchanged
        java.lang.reflect.Method fpMethod =
                CatalogScreen.class.getDeclaredMethod("historyEntriesFingerprint", List.class);
        fpMethod.setAccessible(true);
        WatchHistory.Entry e1 = new WatchHistory.Entry();
        e1.site = "one";
        e1.id = "series";
        e1.title = "Old title";
        e1.poster = "https://poster.example/a.jpg";
        e1.line = "Line-A";
        e1.episode = "EP02";
        e1.index = 0;
        e1.position = 720000;
        e1.duration = 1800000;
        e1.updated = 12345678L;
        WatchHistory.Entry e2 = WatchHistory.cloneEntry(e1);
        e2.title = "New title";
        WatchHistory.Entry e3 = WatchHistory.cloneEntry(e1);
        e3.poster = "https://poster.example/b.jpg";
        WatchHistory.Entry e4 = WatchHistory.cloneEntry(e1);
        e4.line = "Line-B";
        WatchHistory.Entry e5 = WatchHistory.cloneEntry(e1);
        e5.index = 1;
        String fp1 = (String) fpMethod.invoke(null, java.util.Collections.singletonList(e1));
        check(
                !fp1.equals(fpMethod.invoke(null, java.util.Collections.singletonList(e2)))
                        && !fp1.equals(
                                fpMethod.invoke(null, java.util.Collections.singletonList(e3)))
                        && !fp1.equals(
                                fpMethod.invoke(null, java.util.Collections.singletonList(e4)))
                        && !fp1.equals(
                                fpMethod.invoke(null, java.util.Collections.singletonList(e5))),
                "R8.4B: historyEntriesFingerprint invalidates on title, poster, line, or episode index changes");
    }

    private static void testTvOfficialNoticeContracts() {
        OnboardingScreen.MemoryStore store = new OnboardingScreen.MemoryStore();
        check(
                TvOfficialNotice.Controller.shouldShowOnLaunch(store, 100),
                "TvOfficialNotice: fresh install shows official notice once");
        TvOfficialNotice.Controller.markSeen(store, 100);
        check(
                !TvOfficialNotice.Controller.shouldShowOnLaunch(store, 100),
                "TvOfficialNotice: second launch suppresses official notice after markSeen");
        check(
                TvOfficialNotice.Controller.shouldShowOnLaunch(store, 101),
                "TvOfficialNotice: upgrading to a new versionCode re-shows post-update notice once");
        TvOfficialNotice.Controller.resetForTest(store);
        check(
                TvOfficialNotice.Controller.shouldShowOnLaunch(store, 100),
                "TvOfficialNotice: resetForTest re-enables first-launch notice");
        check(
                "PILIPALA来信".equals(TvOfficialNotice.AUTHOR_SOCIAL_NAME)
                        && TvOfficialNotice.AUTHOR_SOCIAL_PLATFORMS.contains("小红书")
                        && TvOfficialNotice.AUTHOR_SOCIAL_PLATFORMS.contains("B站")
                        && TvOfficialNotice.AUTHOR_SOCIAL_PLATFORMS.contains("抖音")
                        && TvOfficialNotice.AUTHOR_SOCIAL_PLATFORMS.contains("公众号")
                        && TvOfficialNotice.AUTHOR_SOCIAL_PLATFORMS.contains("视频号"),
                "TvOfficialNotice: author social handle and all 5 platforms present");
        check(
                "marcotv.wlj9919.top".equals(TvOfficialNotice.OFFICIAL_SITE_DISPLAY)
                        && "https://marcotv.wlj9919.top".equals(TvOfficialNotice.OFFICIAL_SITE_URL)
                        && "https://marcotv.wlj9919.top/movie/#group"
                                .equals(TvOfficialNotice.OFFICIAL_GROUP_URL)
                        && "https://marcotv.wlj9919.top/movie/#donate"
                                .equals(TvOfficialNotice.OFFICIAL_DONATE_URL)
                        && TvOfficialNotice.SECURITY_REMINDER.contains("免费")
                        && TvOfficialNotice.SECURITY_REMINDER.contains("退款")
                        && TvOfficialNotice.SECURITY_REMINDER.contains("唯一官方")
                        && TvOfficialNotice.SECURITY_REMINDER.contains(
                                TvOfficialNotice.OFFICIAL_SITE_DISPLAY),
                "TvOfficialNotice: official website, community group/donate links, and anti-scam reminder present");
        check(
                TvSettingsRegistry.CAT_UPDATES_DIAG.equals(
                                TvSettingsRegistry.categoryIdForRowTag(
                                        TvOfficialNotice.SETTINGS_ROW_TAG))
                        && TvSettingsRegistry.CAT_UPDATES_DIAG.equals(
                                TvSettingsRegistry.categoryIdForRowTag(
                                        TvOfficialNotice.DONATE_ROW_TAG)),
                "TvOfficialNotice: contact/group and donate rows registered under updates_diag");
        check(Prefs.KEYS.length == 46, "TvOfficialNotice: Prefs.KEYS remains strictly 46");
    }

    private static void testNinthRecheckReworkContracts(File tmpRoot) throws Exception {
        File r9Dir = new File(tmpRoot, "r9-rework-" + System.nanoTime());
        r9Dir.mkdirs();

        // Build source backup archive with 2 new sources, HOME_COLUMNS=5, EP02@720000ms
        File srcDir = new File(r9Dir, "src");
        srcDir.mkdirs();
        MainActivity srcAct = newHeadlessActivity(srcDir);
        ConfigLibrary srcLib = new ConfigLibrary(srcDir);
        String urlA = "https://sub.example/r9-a.json";
        String urlB = "https://sub.example/r9-b.json";
        String rawOldA =
                "{\"sites\":[{\"key\":\"oldA\",\"name\":\"OldA\",\"type\":3,\"api\":\"csp_OldA\"}]}";
        String rawOldB =
                "{\"sites\":[{\"key\":\"oldB\",\"name\":\"OldB\",\"type\":3,\"api\":\"csp_OldB\"}]}";
        String rawNewA =
                "{\"sites\":[{\"key\":\"newA\",\"name\":\"NewA\",\"type\":3,\"api\":\"csp_NewA\"}]}";
        String rawNewB =
                "{\"sites\":[{\"key\":\"newB\",\"name\":\"NewB\",\"type\":3,\"api\":\"csp_NewB\"}]}";
        String rawLaterC =
                "{\"sites\":[{\"key\":\"laterC\",\"name\":\"LaterC\",\"type\":3,\"api\":\"csp_LaterC\"}]}";
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewA, urlA, "A新", true, 10L);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewB, urlB, "B新", true, 11L);
        String oldHist =
                new org.json.JSONArray()
                        .put(
                                new org.json.JSONObject()
                                        .put("site", "fixture")
                                        .put("id", "old-watch")
                                        .put("title", "old-watch")
                                        .put("episode", "EP01")
                                        .put("position", 120000)
                                        .put("duration", 1800000))
                        .toString();
        String newHist =
                new org.json.JSONArray()
                        .put(
                                new org.json.JSONObject()
                                        .put("site", "fixture")
                                        .put("id", "new-watch")
                                        .put("title", "new-watch")
                                        .put("episode", "EP02")
                                        .put("position", 720000)
                                        .put("duration", 1800000))
                        .toString();
        org.json.JSONObject backupObj = SettingsScreen.buildBackupJson(srcAct);
        backupObj.getJSONObject("settings").put(Prefs.HOME_COLUMNS, 5);
        backupObj.getJSONObject("settings").put(Prefs.WATCH_HISTORY, newHist);
        check(
                !backupObj.getJSONObject("settings").has(ConfigLibrary.RESTORE_TX_APPLIED_ID_PREF),
                "R9.1: Backup export never includes internal restore_tx_applied_id marker");
        byte[] backupBytes = backupObj.toString().getBytes(StandardCharsets.UTF_8);

        // Case 1: Post-finalize I/O error (prefs_persisted fault) -> later EP03/930000ms +
        // HOME_COLUMNS=7 + later subscription C -> two startup recoveries preserve ALL later edits
        // and delete WAL with 0 preference replays.
        File c1Dir = new File(r9Dir, "case1_post_finalize_progress");
        c1Dir.mkdirs();
        File c1PrefsFile = new File(c1Dir, "prefs.json");
        Files.write(
                c1PrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity c1Act = newHeadlessActivity(c1Dir);
        ConfigLibrary c1Lib = new ConfigLibrary(c1Dir);
        c1Act.multiSourceStore.registerSubscription(c1Lib, rawOldA, urlA, "A旧", true, 1L);
        c1Act.multiSourceStore.registerSubscription(c1Lib, rawOldB, urlB, "B旧", true, 2L);
        c1Act.prefs = makeFileBackedPrefs(c1PrefsFile, null);
        ConfigLibrary.restoreCommitFaultInjector =
                step -> {
                    if ("prefs_persisted".equals(step)) {
                        throw new java.io.IOException("simulated finalize I/O failure");
                    }
                };
        boolean caughtFinalizeErr = false;
        try (java.io.ByteArrayInputStream in = new java.io.ByteArrayInputStream(backupBytes)) {
            SettingsScreen.BackupRestorePlan plan =
                    SettingsScreen.readAndValidateBackupStream(in, true);
            try {
                SettingsScreen.commitBackupRestoreOnWorker(c1Act, plan);
            } catch (java.io.IOException expected) {
                caughtFinalizeErr = true;
            } finally {
                plan.cleanupTempFiles();
            }
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
        }
        check(caughtFinalizeErr, "R9.1A: Finalize I/O error propagated cleanly");
        File c1Manifest = new File(new File(c1Dir, "restore-tx"), "manifest.json");
        check(c1Manifest.isFile(), "R9.1A: WAL manifest remains on disk after finalize failure");
        String appliedTxId = c1Act.prefs.getString(ConfigLibrary.RESTORE_TX_APPLIED_ID_PREF, "");
        check(
                !appliedTxId.isEmpty(),
                "R9.1A: Atomic restore_tx_applied_id persisted alongside restored prefs");

        // Subsequent user edits in the same process: EP03 @ 930000 ms, HOME_COLUMNS=7, and a
        // brand-new subscription C.
        WatchHistory.Entry laterProg = new WatchHistory.Entry();
        laterProg.id = "new-watch";
        laterProg.site = "fixture";
        laterProg.title = "new-watch";
        laterProg.episode = "EP03";
        laterProg.position = 930000;
        laterProg.duration = 1800000;
        WatchHistory.enqueueUpsert(c1Act.historyPersistence(), laterProg)
                .get(15, java.util.concurrent.TimeUnit.SECONDS);
        c1Act.prefs.edit().putInt(Prefs.HOME_COLUMNS, 7).commit();
        c1Act.multiSourceStore.registerSubscription(
                new ConfigLibrary(c1Dir),
                rawLaterC,
                "https://sub.example/r9-c.json",
                "C新",
                true,
                20L);

        // Two cold startup recoveries
        android.content.SharedPreferences c1ColdPrefs = makeFileBackedPrefs(c1PrefsFile, null);
        int[] c1Replays = {0};
        for (int boot = 0; boot < 2; boot++) {
            ConfigLibrary.recoverInterruptedRestoreIfNeeded(
                    c1Dir,
                    snap -> {
                        c1Replays[0]++;
                        SettingsScreen.applyRestorablePrefsSnapshot(c1ColdPrefs, snap, true);
                    },
                    txId ->
                            txId != null
                                    && txId.equals(
                                            c1ColdPrefs.getString(
                                                    ConfigLibrary.RESTORE_TX_APPLIED_ID_PREF, "")));
            org.json.JSONObject card =
                    new org.json.JSONArray(c1ColdPrefs.getString(Prefs.WATCH_HISTORY, "[]"))
                            .getJSONObject(0);
            List<ConfigLibrary.Entry> ents = new ConfigLibrary(c1Dir).entries();
            check(
                    c1Replays[0] == 0
                            && !c1Manifest.isFile()
                            && "EP03".equals(card.getString("episode"))
                            && card.getInt("position") == 930000
                            && c1ColdPrefs.getInt(Prefs.HOME_COLUMNS, -1) == 7
                            && ents.size() == 3,
                    "R9.1A boot "
                            + (boot + 1)
                            + ": preserves EP03/930000/7 cols and laterC subscription with WAL cleared");
        }

        // Case 2: Simulate hard crash BEFORE markPrefsPersisted updated manifest.json (manifest
        // still says COMMITTING_PREFS, prefs already atomically committed restore_tx_applied_id).
        File c2Dir = new File(r9Dir, "case2_atomic_pref_marker_fallback");
        c2Dir.mkdirs();
        File c2PrefsFile = new File(c2Dir, "prefs.json");
        Files.write(
                c2PrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .put(Prefs.WATCH_HISTORY, oldHist)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity c2Act = newHeadlessActivity(c2Dir);
        ConfigLibrary c2Lib = new ConfigLibrary(c2Dir);
        c2Act.multiSourceStore.registerSubscription(c2Lib, rawOldA, urlA, "A旧", true, 1L);
        c2Act.prefs = makeFileBackedPrefs(c2PrefsFile, null);
        ConfigLibrary.restoreCommitFaultInjector =
                step -> {
                    if ("prefs_persisted".equals(step)) {
                        throw new java.io.IOException("simulated finalize failure");
                    }
                };
        try (java.io.ByteArrayInputStream in = new java.io.ByteArrayInputStream(backupBytes)) {
            SettingsScreen.BackupRestorePlan plan =
                    SettingsScreen.readAndValidateBackupStream(in, true);
            try {
                SettingsScreen.commitBackupRestoreOnWorker(c2Act, plan);
            } catch (java.io.IOException ignored) {
            } finally {
                plan.cleanupTempFiles();
            }
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
        }
        // Revert manifest phase back to COMMITTING_PREFS on disk to simulate crash right after
        // edit.commit() before markPrefsPersisted() wrote manifest.json!
        File c2Manifest = new File(new File(c2Dir, "restore-tx"), "manifest.json");
        org.json.JSONObject c2ManJson =
                new org.json.JSONObject(
                        new String(
                                Files.readAllBytes(c2Manifest.toPath()), StandardCharsets.UTF_8));
        c2ManJson.put("phase", "COMMITTING_PREFS");
        c2ManJson.put("prefsPersisted", false);
        Files.write(c2Manifest.toPath(), c2ManJson.toString().getBytes(StandardCharsets.UTF_8));
        c2Act.prefs.edit().putInt(Prefs.HOME_COLUMNS, 7).commit();
        int[] c2Replays = {0};
        android.content.SharedPreferences c2ColdPrefs = makeFileBackedPrefs(c2PrefsFile, null);
        ConfigLibrary.recoverInterruptedRestoreIfNeeded(
                c2Dir,
                snap -> {
                    c2Replays[0]++;
                    SettingsScreen.applyRestorablePrefsSnapshot(c2ColdPrefs, snap, true);
                },
                txId ->
                        txId != null
                                && txId.equals(
                                        c2ColdPrefs.getString(
                                                ConfigLibrary.RESTORE_TX_APPLIED_ID_PREF, "")));
        check(
                c2Replays[0] == 0
                        && !c2Manifest.isFile()
                        && c2ColdPrefs.getInt(Prefs.HOME_COLUMNS, -1) == 7,
                "R9.1B: Atomic restore_tx_applied_id prevents replay even if manifest stayed COMMITTING_PREFS");
    }

    private static void testTenthRecheckReworkContracts(File tmpRoot) throws Exception {
        File r10Dir = new File(tmpRoot, "tenth-recheck-rework");
        r10Dir.mkdirs();

        // 1. P2 #2: When manifest stays COMMITTING_PREFS (e.g. manifest lock/IO failure) after
        // prefs committed restore_tx_applied_id, disabling subscription B followed by ordinary
        // ConfigLibrary.entries() & TvMultiSourceStore.readState() must NOT overwrite B back to
        // enabled=true, and two subsequent cold startups keep B disabled and clean WAL.
        File srcDir = new File(r10Dir, "src");
        srcDir.mkdirs();
        String urlA = "https://sub.example/r10-a.json";
        String urlB = "https://sub.example/r10-b.json";
        String rawOldA =
                "{\"sites\":[{\"key\":\"oldA\",\"name\":\"oldA\",\"type\":1,\"api\":\"https://old-a.example\"}]}";
        String rawOldB =
                "{\"sites\":[{\"key\":\"oldB\",\"name\":\"oldB\",\"type\":1,\"api\":\"https://old-b.example\"}]}";
        String rawNewA =
                "{\"sites\":[{\"key\":\"newA\",\"name\":\"newA\",\"type\":1,\"api\":\"https://new-a.example\"}]}";
        String rawNewB =
                "{\"sites\":[{\"key\":\"newB\",\"name\":\"newB\",\"type\":1,\"api\":\"https://new-b.example\"}]}";
        MainActivity srcAct = newHeadlessActivity(srcDir);
        ConfigLibrary srcLib = new ConfigLibrary(srcDir);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewA, urlA, "A", true, 10L);
        srcAct.multiSourceStore.registerSubscription(srcLib, rawNewB, urlB, "B", true, 11L);
        org.json.JSONObject bk = SettingsScreen.buildBackupJson(srcAct);
        bk.getJSONObject("settings").put(Prefs.HOME_COLUMNS, 5);
        byte[] bkBytes = bk.toString().getBytes(StandardCharsets.UTF_8);

        File tDir = new File(r10Dir, "marker_ordinary_read");
        tDir.mkdirs();
        File tPrefsFile = new File(tDir, "prefs.json");
        Files.write(
                tPrefsFile.toPath(),
                new org.json.JSONObject()
                        .put(Prefs.HOME_COLUMNS, 6)
                        .toString()
                        .getBytes(StandardCharsets.UTF_8));
        MainActivity tAct = newHeadlessActivity(tDir);
        ConfigLibrary tLib = new ConfigLibrary(tDir);
        tAct.multiSourceStore.registerSubscription(tLib, rawOldA, urlA, "A", true, 1L);
        tAct.multiSourceStore.registerSubscription(tLib, rawOldB, urlB, "B", true, 2L);
        tAct.prefs = makeFileBackedPrefs(tPrefsFile, null);
        ConfigLibrary.restoreCommitFaultInjector =
                step -> {
                    if ("prefs_persisted".equals(step)) {
                        throw new java.io.IOException("simulated finalize fail");
                    }
                };
        try (java.io.ByteArrayInputStream in = new java.io.ByteArrayInputStream(bkBytes)) {
            SettingsScreen.BackupRestorePlan plan =
                    SettingsScreen.readAndValidateBackupStream(in, true);
            try {
                SettingsScreen.commitBackupRestoreOnWorker(tAct, plan);
            } catch (java.io.IOException ignored) {
            } finally {
                plan.cleanupTempFiles();
            }
        } finally {
            ConfigLibrary.restoreCommitFaultInjector = null;
        }
        // Revert manifest phase to COMMITTING_PREFS while prefs hold matching txId
        File manFile = new File(new File(tDir, "restore-tx"), "manifest.json");
        org.json.JSONObject manJson =
                new org.json.JSONObject(
                        new String(Files.readAllBytes(manFile.toPath()), StandardCharsets.UTF_8));
        manJson.put("phase", "COMMITTING_PREFS");
        manJson.put("prefsPersisted", false);
        Files.write(manFile.toPath(), manJson.toString().getBytes(StandardCharsets.UTF_8));

        // Disable B, update HOME_COLUMNS=7, then invoke ordinary ConfigLibrary.entries() &
        // readState()
        TvMultiSourceStore.State stBefore = tAct.multiSourceStore.readState();
        String bId = "";
        for (TvMultiSourceStore.SubscriptionRecord sr : stBefore.subscriptions) {
            if ("B".equals(sr.name)) bId = sr.id;
        }
        check(!bId.isEmpty(), "R10.1: Found restored subscription B");
        tAct.multiSourceStore.setSubscriptionEnabled(bId, false);
        tAct.prefs.edit().putInt(Prefs.HOME_COLUMNS, 7).commit();
        new ConfigLibrary(tDir).entries();
        tAct.multiSourceStore.invalidateCache();
        TvMultiSourceStore.State afterRead = tAct.multiSourceStore.readState();
        boolean bStillOffAfterRead = false;
        for (TvMultiSourceStore.SubscriptionRecord sr : afterRead.subscriptions) {
            if (bId.equals(sr.id)) bStillOffAfterRead = !sr.enabled;
        }
        check(
                bStillOffAfterRead,
                "R10.1: Ordinary ConfigLibrary.entries() & readState() do NOT re-enable disabled B");

        android.content.SharedPreferences coldPrefs = makeFileBackedPrefs(tPrefsFile, null);
        int[] replays = {0};
        for (int boot = 0; boot < 2; boot++) {
            ConfigLibrary.recoverInterruptedRestoreIfNeeded(
                    tDir,
                    snap -> {
                        replays[0]++;
                        SettingsScreen.applyRestorablePrefsSnapshot(coldPrefs, snap, true);
                    },
                    txId ->
                            txId != null
                                    && txId.equals(
                                            coldPrefs.getString(
                                                    ConfigLibrary.RESTORE_TX_APPLIED_ID_PREF, "")));
            TvMultiSourceStore coldStore = new TvMultiSourceStore(tDir);
            boolean bOffCold = false;
            for (TvMultiSourceStore.SubscriptionRecord sr : coldStore.readState().subscriptions) {
                if (bId.equals(sr.id)) bOffCold = !sr.enabled;
            }
            check(
                    bOffCold
                            && replays[0] == 0
                            && !manFile.isFile()
                            && coldPrefs.getInt(Prefs.HOME_COLUMNS, -1) == 7,
                    "R10.1 boot "
                            + (boot + 1)
                            + ": B remains disabled, 0 replays, WAL cleared, 7 cols");
        }

        // 2. #97 Netdisk cold-start history resume & QR backup line guard contracts
        Cms.Site wogg = new Cms.Site();
        wogg.key = "wogg_key";
        wogg.name = "玩偶哥哥┃4K弹幕";
        wogg.api = "csp_WoGGGuard";
        Cms.Line duduLine = new Cms.Line();
        duduLine.name = "嘟嘟无限1";
        Cms.Episode duduEp = new Cms.Episode();
        duduEp.name = "S01E19";
        duduEp.url = "http://127.0.0.1:6678/proxy/play/嘟嘟盘/test/S01E19.mkv";
        Cms.Line youxiLine = new Cms.Line();
        youxiLine.name = "优汐智3";
        Cms.Episode youxiEp = new Cms.Episode();
        youxiEp.name = "S01E19";
        youxiEp.url = "uc://qr-required/18.mp4";
        Cms.Line directLine = new Cms.Line();
        directLine.name = "标准高清线";
        Cms.Episode directEp = new Cms.Episode();
        directEp.name = "S01E19";
        directEp.url = "https://cdn.example.com/s01e19.m3u8";
        Cms.Site plainSite = new Cms.Site();
        plainSite.key = "plain";
        plainSite.name = "标准片源";
        plainSite.api = "https://api.example.com/vod";

        check(
                PlaybackController.looksLikeNetdiskLine(wogg, duduLine, duduEp.url),
                "R10.2: recognizes 嘟嘟盘 /proxy/play as netdisk/proxy line");
        check(
                PlaybackController.looksLikeNetdiskLine(wogg, youxiLine, youxiEp.url),
                "R10.2: recognizes 优汐智3 as netdisk line");
        check(
                !PlaybackController.canAutoHopToLine(wogg, youxiLine, youxiEp),
                "R10.2: refuses auto-hopping onto netdisk/QR backup line 优汐智3");
        check(
                PlaybackController.canAutoHopToLine(plainSite, directLine, directEp),
                "R10.2: permits auto-hopping onto non-netdisk direct line");
        check(
                PlaybackController.shouldFreshReResolveOriginalLine(
                        wogg, duduLine, duduEp, false, 0, new WatchHistory.Entry()),
                "R10.2: triggers fresh original-line re-resolve on startup failure before hopping");
        duduEp.media.put("_freshReResolve", true);
        check(
                !PlaybackController.shouldFreshReResolveOriginalLine(
                        wogg, duduLine, duduEp, false, 0, new WatchHistory.Entry()),
                "R10.2: fresh re-resolve runs at most once per episode (no infinite loop)");

        // 3. #99/#100 Thread pool bounds & core timeout contracts
        DetailCache dc = new DetailCache();
        dc.put("k1", "{\"list\":[]}");
        check(dc.get("k1") != null, "R10.3: DetailCache put/get works");
        dc.remove("k1");
        check(dc.get("k1") == null, "R10.3: DetailCache.remove invalidates single entry");
    }

    static void testEleventhRecheckReworkContracts() {
        // R11 #97: Fresh original-line re-resolve MUST match strictly by stable line & episode
        // identity and NEVER fall back by index onto a QR/netdisk backup occupying index 0.
        Cms.Line origLine = new Cms.Line();
        origLine.name = "嘟嘟无限1";
        Cms.Episode origEp = new Cms.Episode();
        origEp.name = "S01E19";
        origEp.url = "https://fixture.test/expired";
        origLine.episodes.add(origEp);

        // Case A: Original line reordered to index 1 while QR backup takes index 0
        Cms.Video reordered = new Cms.Video();
        Cms.Line qrLine = new Cms.Line();
        qrLine.name = "优汐扫码";
        Cms.Episode qrEp = new Cms.Episode();
        qrEp.name = "S01E19";
        qrEp.url = "https://fixture.test/qr-backup";
        qrLine.episodes.add(qrEp);
        Cms.Line freshDudu = new Cms.Line();
        freshDudu.name = " 嘟嘟无限1 ";
        Cms.Episode freshDuduEp = new Cms.Episode();
        freshDuduEp.name = "S01E19";
        freshDuduEp.url = "https://fixture.test/refreshed";
        freshDudu.episodes.add(freshDuduEp);
        reordered.lines.add(qrLine);
        reordered.lines.add(freshDudu);

        PlaybackController.FreshOriginalTarget hit =
                PlaybackController.resolveFreshOriginalTarget(
                        reordered, origLine, origEp, origLine.name, origEp.name, 0);
        check(
                hit.line == freshDudu && hit.episode == freshDuduEp,
                "R11.1: reordered original line matches by normalized identity instead of index 0 QR line");

        // Case B: Original line vanished and QR backup took index 0 -> MUST refuse auto-selection
        Cms.Video vanished = new Cms.Video();
        vanished.lines.add(qrLine);
        PlaybackController.FreshOriginalTarget missing =
                PlaybackController.resolveFreshOriginalTarget(
                        vanished, origLine, origEp, origLine.name, origEp.name, 0);
        check(
                missing.line == null && missing.episode == null,
                "R11.2: vanished original line refuses index fallback onto index 0 QR backup");

        // Case C: Original line retained, but requested episode removed -> MUST refuse random ep
        Cms.Video epMissing = new Cms.Video();
        Cms.Line otherEpLine = new Cms.Line();
        otherEpLine.name = "嘟嘟无限1";
        Cms.Episode ep02 = new Cms.Episode();
        ep02.name = "S01E02";
        ep02.url = "https://fixture.test/ep02";
        otherEpLine.episodes.add(ep02);
        epMissing.lines.add(otherEpLine);
        PlaybackController.FreshOriginalTarget epMiss =
                PlaybackController.resolveFreshOriginalTarget(
                        epMissing, origLine, origEp, origLine.name, origEp.name, 0);
        check(
                epMiss.line == otherEpLine && epMiss.episode == null,
                "R11.3: missing original episode does not silently substitute another episode by index");
    }

    static void testTwelfthRecheckSameLineSeasonContracts() {
        // R12 #97: Same-line season identity prevents S02E01 from silently hopping onto S01E01!
        Cms.Line origLine = new Cms.Line();
        origLine.name = "嘟嘟无限1";
        Cms.Episode origS02E01 = new Cms.Episode();
        origS02E01.name = "S02E01";
        origS02E01.url = "https://fixture.test/expired";
        origLine.episodes.add(origS02E01);

        // Case 1: Exact same season+episode name retained
        Cms.Video exactSeason = new Cms.Video();
        Cms.Line lExact = new Cms.Line();
        lExact.name = "嘟嘟无限1";
        Cms.Episode e1 = new Cms.Episode();
        e1.name = "S01E01";
        e1.url = "https://fixture.test/s1";
        Cms.Episode e2 = new Cms.Episode();
        e2.name = "S02E01";
        e2.url = "https://fixture.test/s2";
        lExact.episodes.add(e1);
        lExact.episodes.add(e2);
        exactSeason.lines.add(lExact);
        PlaybackController.FreshOriginalTarget hitExact =
                PlaybackController.resolveFreshOriginalTarget(
                        exactSeason, origLine, origS02E01, origLine.name, origS02E01.name, 0);
        check(
                hitExact.line == lExact
                        && hitExact.episode == e2
                        && "https://fixture.test/s2".equals(hitExact.episode.url),
                "R12.1: exact S02E01 selects S02E01 even when S01E01 is at index 0");

        // Case 2: Renamed season marker ("第二季 第1集") matches S02E01 while skipping S01E01
        Cms.Video renamedSeason = new Cms.Video();
        Cms.Line lRenamed = new Cms.Line();
        lRenamed.name = "嘟嘟无限1";
        Cms.Episode r1 = new Cms.Episode();
        r1.name = "S01E01";
        r1.url = "https://fixture.test/s1";
        Cms.Episode r2 = new Cms.Episode();
        r2.name = "第二季 第1集";
        r2.url = "https://fixture.test/s2";
        lRenamed.episodes.add(r1);
        lRenamed.episodes.add(r2);
        renamedSeason.lines.add(lRenamed);
        PlaybackController.FreshOriginalTarget hitRenamed =
                PlaybackController.resolveFreshOriginalTarget(
                        renamedSeason, origLine, origS02E01, origLine.name, origS02E01.name, 0);
        check(
                hitRenamed.line == lRenamed
                        && hitRenamed.episode == r2
                        && "https://fixture.test/s2".equals(hitRenamed.episode.url),
                "R12.2: renamed '第二季 第1集' uniquely matches S02E01 instead of S01E01");

        // Case 3: Season 2 truly removed (only S01E01 remains) -> MUST return null episode (no
        // wrong-season hop!)
        Cms.Video s2Removed = new Cms.Video();
        Cms.Line lOnlyS1 = new Cms.Line();
        lOnlyS1.name = "嘟嘟无限1";
        Cms.Episode onlyS1 = new Cms.Episode();
        onlyS1.name = "S01E01";
        onlyS1.url = "https://fixture.test/s1";
        lOnlyS1.episodes.add(onlyS1);
        s2Removed.lines.add(lOnlyS1);
        PlaybackController.FreshOriginalTarget missS2 =
                PlaybackController.resolveFreshOriginalTarget(
                        s2Removed, origLine, origS02E01, origLine.name, origS02E01.name, 0);
        check(
                missS2.line == lOnlyS1 && missS2.episode == null,
                "R12.3: removed Season 2 refuses to hop to S01E01");

        // Case 4: Ambiguous Season 2 duplicates ("第二季 第1集" + "第2季 EP01") -> refuses silent guess
        Cms.Video ambigS2 = new Cms.Video();
        Cms.Line lAmbig = new Cms.Line();
        lAmbig.name = "嘟嘟无限1";
        Cms.Episode a1 = new Cms.Episode();
        a1.name = "第二季 第1集";
        a1.url = "https://fixture.test/s2a";
        Cms.Episode a2 = new Cms.Episode();
        a2.name = "第2季 EP01";
        a2.url = "https://fixture.test/s2b";
        lAmbig.episodes.add(a1);
        lAmbig.episodes.add(a2);
        ambigS2.lines.add(lAmbig);
        PlaybackController.FreshOriginalTarget missAmbig =
                PlaybackController.resolveFreshOriginalTarget(
                        ambigS2, origLine, origS02E01, origLine.name, origS02E01.name, 0);
        check(
                missAmbig.line == lAmbig && missAmbig.episode == null,
                "R12.4: ambiguous duplicate Season 2 candidates refuse silent selection");
    }

    public static void main(String[] args) throws Exception {
        File tmpRoot =
                args.length > 0
                        ? new File(args[0])
                        : Files.createTempDirectory("tv-playback-ms-checks-").toFile();
        tmpRoot.mkdirs();

        testR7ReworkContracts();
        testLightSeekCapsuleContracts();
        testMinimalistSpeedMonitorContracts();
        testClassicTwoTierToolbarContracts();
        testMultiSourceStoreContracts(tmpRoot);
        testPostReviewReworkCounterexamples(tmpRoot);
        testSecondRecheckReworkContracts(tmpRoot);
        testThirdRecheckReworkContracts(tmpRoot);
        testFourthRecheckReworkContracts(tmpRoot);
        testFifthRecheckReworkContracts(tmpRoot);
        testSixthRecheckReworkContracts(tmpRoot);
        testSeventhRecheckReworkContracts(tmpRoot);
        testEighthRecheckReworkContracts(tmpRoot);
        testNinthRecheckReworkContracts(tmpRoot);
        testTenthRecheckReworkContracts(tmpRoot);
        testEleventhRecheckReworkContracts();
        testTwelfthRecheckSameLineSeasonContracts();
        testTvOfficialNoticeContracts();
        testSourceCodeStructuralGuards();

        System.out.println("PASS TvPlaybackMultiSourceChecks (" + passed + " checks)");
    }
}

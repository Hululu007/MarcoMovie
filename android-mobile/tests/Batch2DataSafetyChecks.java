package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/**
 * Deterministic regression tests for Batch 2 (D1-D4):
 * - D1: Private search & watch-progress isolation + targeted legacy private cleanup
 * - D2: Stale subscription refresh / A-slow B-fast / A->B->A edit & delete non-resurrection
 * - D3: Mobile delete/clear/unfavorite -> tombstone -> 2x cloud merge -> 2nd client -> re-favorite
 * - D4: Concurrent search session isolation (late A after B, return cache, space switch, page exit)
 */
public final class Batch2DataSafetyChecks {
    private static int checks;

    private static void check(boolean cond, String name) {
        if (!cond) throw new AssertionError("FAIL: " + name);
        checks++;
        System.out.println("PASS " + name);
    }

    /** Thread-safe in-memory SharedPreferences backed by a Map to simulate restarts cleanly. */
    static final class MapPrefs implements SharedPreferences {
        private final Map<String, Object> data;

        MapPrefs() {
            this(new HashMap<String, Object>());
        }

        MapPrefs(Map<String, Object> backing) {
            this.data = backing;
        }

        synchronized Map<String, Object> snapshotMap() {
            return new HashMap<>(data);
        }

        @Override
        public synchronized Map<String, ?> getAll() {
            return new HashMap<>(data);
        }

        @Override
        public synchronized String getString(String key, String defValue) {
            Object v = data.get(key);
            return v instanceof String ? (String) v : defValue;
        }

        @Override
        @SuppressWarnings("unchecked")
        public synchronized Set<String> getStringSet(String key, Set<String> defValues) {
            Object v = data.get(key);
            return v instanceof Set ? new HashSet<>((Set<String>) v) : defValues;
        }

        @Override
        public synchronized int getInt(String key, int defValue) {
            Object v = data.get(key);
            return v instanceof Integer ? (Integer) v : defValue;
        }

        @Override
        public synchronized long getLong(String key, long defValue) {
            Object v = data.get(key);
            return v instanceof Long ? (Long) v : defValue;
        }

        @Override
        public synchronized float getFloat(String key, float defValue) {
            Object v = data.get(key);
            return v instanceof Float ? (Float) v : defValue;
        }

        @Override
        public synchronized boolean getBoolean(String key, boolean defValue) {
            Object v = data.get(key);
            return v instanceof Boolean ? (Boolean) v : defValue;
        }

        @Override
        public synchronized boolean contains(String key) {
            return data.containsKey(key);
        }

        @Override
        public Editor edit() {
            return new Editor() {
                private final Map<String, Object> updates = new HashMap<>();
                private final Set<String> removals = new HashSet<>();
                private boolean clearAll;

                @Override
                public Editor putString(String key, String value) {
                    updates.put(key, value);
                    removals.remove(key);
                    return this;
                }

                @Override
                public Editor putStringSet(String key, Set<String> values) {
                    updates.put(key, values == null ? null : new HashSet<>(values));
                    removals.remove(key);
                    return this;
                }

                @Override
                public Editor putInt(String key, int value) {
                    updates.put(key, value);
                    removals.remove(key);
                    return this;
                }

                @Override
                public Editor putLong(String key, long value) {
                    updates.put(key, value);
                    removals.remove(key);
                    return this;
                }

                @Override
                public Editor putFloat(String key, float value) {
                    updates.put(key, value);
                    removals.remove(key);
                    return this;
                }

                @Override
                public Editor putBoolean(String key, boolean value) {
                    updates.put(key, value);
                    removals.remove(key);
                    return this;
                }

                @Override
                public Editor remove(String key) {
                    removals.add(key);
                    updates.remove(key);
                    return this;
                }

                @Override
                public Editor clear() {
                    clearAll = true;
                    updates.clear();
                    removals.clear();
                    return this;
                }

                @Override
                public boolean commit() {
                    apply();
                    return true;
                }

                @Override
                public void apply() {
                    synchronized (MapPrefs.this) {
                        if (clearAll) data.clear();
                        for (String r : removals) data.remove(r);
                        for (Map.Entry<String, Object> e : updates.entrySet()) {
                            if (e.getValue() == null) data.remove(e.getKey());
                            else data.put(e.getKey(), e.getValue());
                        }
                    }
                }
            };
        }

        @Override
        public void registerOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}

        @Override
        public void unregisterOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}
    }

    private static WatchHistory.Persistence prefsPersistence(
            final SharedPreferences prefs, final boolean privateMode) {
        if (privateMode) {
            return new WatchHistory.Persistence() {
                @Override
                public String readRaw() {
                    return "[]";
                }

                @Override
                public boolean readCorruptedPref() {
                    return false;
                }

                @Override
                public void writeState(String historyJson, boolean corrupted) {}
            };
        }
        return new WatchHistory.Persistence() {
            @Override
            public String readRaw() {
                return prefs.getString(Prefs.WATCH_HISTORY, "[]");
            }

            @Override
            public boolean readCorruptedPref() {
                return prefs.getBoolean(WatchHistory.CORRUPTED_PREF, false);
            }

            @Override
            public void writeState(String historyJson, boolean corrupted) {
                prefs.edit()
                        .putString(Prefs.WATCH_HISTORY, historyJson)
                        .putBoolean(WatchHistory.CORRUPTED_PREF, corrupted)
                        .apply();
            }
        };
    }

    private static CloudSync.LocalStore storeFor(final SharedPreferences prefs) {
        return new CloudSync.LocalStore() {
            @Override
            public String readHistoryJson() {
                return prefs.getString(Prefs.WATCH_HISTORY, "[]");
            }

            @Override
            public String readFavoritesJson() {
                return prefs.getString(Prefs.FAVORITES, "[]");
            }

            @Override
            public String readTombstonesJson() {
                return prefs.getString(Prefs.SYNC_TOMBSTONES, "");
            }

            @Override
            public void writeMerged(
                    String historyJson,
                    String favoritesJson,
                    String tombstonesJson,
                    CloudSync.MergeResult result) {
                prefs.edit()
                        .putString(Prefs.WATCH_HISTORY, historyJson)
                        .putString(Prefs.FAVORITES, favoritesJson)
                        .putString(Prefs.SYNC_TOMBSTONES, tombstonesJson)
                        .apply();
            }
        };
    }

    private static void testD1PrivateIsolationAndCleanup(File tempDir) throws Exception {
        Map<String, Object> publicDisk = new HashMap<>();
        Map<String, Object> privateDisk = new HashMap<>();
        MapPrefs pubPrefs = new MapPrefs(publicDisk);
        MapPrefs privPrefs = new MapPrefs(privateDisk);

        // 1. Public search "甲" persists; private search "乙" does NOT persist anywhere.
        MobileSearchPage.saveSearchHistory(pubPrefs, false, "甲");
        MobileSearchPage.saveSearchHistory(privPrefs, true, "乙");
        check(
                MobileSearchPage.readSearchHistory(pubPrefs, false)
                        .equals(Collections.singletonList("甲")),
                "D1: public search keyword persists in public prefs");
        check(
                !privPrefs.contains(Prefs.GLOBAL_SEARCH_HISTORY)
                        && MobileSearchPage.readSearchHistory(privPrefs, true).isEmpty(),
                "D1: private search keyword never persisted to private prefs");

        // 2. Public watch progress persists; private watch progress does NOT persist.
        WatchHistory.setCorrupted(false);
        WatchHistory.Entry pubEntry = new WatchHistory.Entry();
        pubEntry.site = "pub_site";
        pubEntry.id = "m1";
        pubEntry.title = "公开影片";
        pubEntry.line = "线路1";
        pubEntry.episode = "第1集";
        pubEntry.position = 45_000;
        pubEntry.duration = 2_400_000;
        pubEntry.updated = 10_000L;
        WatchHistory.enqueueUpsert(prefsPersistence(pubPrefs, false), pubEntry).get();

        WatchHistory.Entry privEntry = new WatchHistory.Entry();
        privEntry.site = "priv_site";
        privEntry.id = "p1";
        privEntry.title = "私密影片";
        privEntry.line = "线路1";
        privEntry.episode = "第1集";
        privEntry.position = 90_000;
        privEntry.duration = 2_400_000;
        privEntry.updated = 20_000L;
        WatchHistory.enqueueUpsert(prefsPersistence(privPrefs, true), privEntry).get();

        // Simulate app restart by constructing fresh MapPrefs over persisted disk maps.
        MapPrefs pubAfterRestart = new MapPrefs(publicDisk);
        MapPrefs privAfterRestart = new MapPrefs(privateDisk);
        check(
                MobileSearchPage.readSearchHistory(pubAfterRestart, false)
                        .equals(Collections.singletonList("甲")),
                "D1: public search keyword survives restart");
        check(
                WatchHistory.read(pubAfterRestart.getString(Prefs.WATCH_HISTORY, "[]")).size() == 1
                        && !privAfterRestart.contains(Prefs.WATCH_HISTORY)
                        && !privAfterRestart.contains(Prefs.GLOBAL_SEARCH_HISTORY),
                "D1: public progress survives restart while private search & progress remain absent");

        // 3. Targeted cleanup of legacy private search & watch-history entries, preserving private
        // subscriptions, selected site, favorites, and all public data.
        ConfigLibrary privLib = new ConfigLibrary(new File(tempDir, "private-config"));
        String privCfgRaw =
                "{\"sites\":[{\"key\":\"priv_s\",\"name\":\"私密片源\",\"type\":1,\"api\":\"https://priv.example/api.php\"}]}";
        privLib.remember(privCfgRaw, "https://priv.example/sub.json", "私密订阅", "priv_s");
        privAfterRestart
                .edit()
                .putString(Prefs.GLOBAL_SEARCH_HISTORY, "[\"旧候选遗留私密词\"]")
                .putString(Prefs.WATCH_HISTORY, "[{\"site\":\"priv_s\",\"id\":\"old\"}]")
                .putBoolean(WatchHistory.CORRUPTED_PREF, true)
                .putString(Prefs.ORIGIN, "https://priv.example/sub.json")
                .putString(Prefs.SELECTED_SITE, "priv_s")
                .putString(
                        Prefs.FAVORITES,
                        "[{\"site\":\"priv_s\",\"id\":\"fav1\",\"title\":\"私密收藏\"}]")
                .apply();

        boolean cleaned = MainActivity.cleanupLegacyPrivateHistory(privAfterRestart);
        check(cleaned, "D1: targeted legacy cleanup reports cleaned=true when legacy keys existed");
        check(
                !privAfterRestart.contains(Prefs.GLOBAL_SEARCH_HISTORY)
                        && !privAfterRestart.contains(Prefs.WATCH_HISTORY)
                        && !privAfterRestart.contains(WatchHistory.CORRUPTED_PREF),
                "D1: legacy private search/watch-history/corrupted keys purged");
        check(
                "https://priv.example/sub.json".equals(privAfterRestart.getString(Prefs.ORIGIN, ""))
                        && "priv_s".equals(privAfterRestart.getString(Prefs.SELECTED_SITE, ""))
                        && Favorites.contains(
                                privAfterRestart.getString(Prefs.FAVORITES, "[]"), "priv_s", "fav1")
                        && privLib.entries().size() == 1,
                "D1: private subscriptions, selected site, and favorites preserved intact");
        check(
                MobileSearchPage.readSearchHistory(pubAfterRestart, false)
                                .equals(Collections.singletonList("甲"))
                        && WatchHistory.read(pubAfterRestart.getString(Prefs.WATCH_HISTORY, "[]"))
                                        .size()
                                == 1,
                "D1: public search history and watch progress untouched by private cleanup");
        check(
                !MainActivity.cleanupLegacyPrivateHistory(privAfterRestart),
                "D1: targeted legacy cleanup is idempotent on second run");
    }

    private static void testD2StaleSubscriptionAndRaces(File tempDir) throws Exception {
        File cfgDir = new File(tempDir, "d2-store");
        ConfigStore store = new ConfigStore(cfgDir);
        final MapPrefs prefs = new MapPrefs();
        ConfigStore.PointerStore pointerStore =
                new ConfigStore.PointerStore() {
                    @Override
                    public ConfigStore.PointerSnapshot readCurrentPointers() {
                        return new ConfigStore.PointerSnapshot(
                                prefs.getString(Prefs.ORIGIN, null),
                                prefs.getString(Prefs.SELECTED_SITE, null));
                    }

                    @Override
                    public void applyPointers(ConfigStore.PointerSnapshot snapshot) {
                        SharedPreferences.Editor ed = prefs.edit();
                        if (snapshot.origin != null) ed.putString(Prefs.ORIGIN, snapshot.origin);
                        else ed.remove(Prefs.ORIGIN);
                        if (snapshot.selectedSite != null) {
                            ed.putString(Prefs.SELECTED_SITE, snapshot.selectedSite);
                        } else {
                            ed.remove(Prefs.SELECTED_SITE);
                        }
                        ed.apply();
                    }
                };

        final String originA = "https://host-a.example/dir-a/config.json";
        final String rawA1 =
                "{\"spider\":\"./a.jar\",\"sites\":[{\"key\":\"site_a\",\"name\":\"A源v1\",\"type\":1,\"api\":\"./api_a\"}]}";
        final String rawA2 =
                "{\"spider\":\"./a_v2.jar\",\"sites\":[{\"key\":\"site_a\",\"name\":\"A源v2\",\"type\":1,\"api\":\"./api_a_v2\"}]}";
        final String originB = "https://host-b.example/dir-b/config.json";
        final String rawB =
                "{\"spider\":\"./b.jar\",\"sites\":[{\"key\":\"site_b\",\"name\":\"B源\",\"type\":1,\"api\":\"./api_b\"}]}";

        // Start active on A.
        store.saveAsync(
                        rawA1,
                        new ConfigStore.PointerSnapshot(originA, "site_a"),
                        pointerStore,
                        null)
                .get(5, TimeUnit.SECONDS);
        final long seqAtAStart = store.latestWriteSeq();

        // Latch-controlled race: slow refresh of A starts, then fast switch to B finishes first.
        final CountDownLatch aStarted = new CountDownLatch(1);
        final CountDownLatch releaseA = new CountDownLatch(1);
        ExecutorService exec = Executors.newSingleThreadExecutor();
        try {
            Future<Boolean> slowRefreshCommit =
                    exec.submit(
                            () -> {
                                aStarted.countDown();
                                releaseA.await(5, TimeUnit.SECONDS);
                                ConfigStore.CommitResult res =
                                        store.saveIfExpectedSeq(
                                                seqAtAStart,
                                                rawA2,
                                                new ConfigStore.PointerSnapshot(originA, "site_a"),
                                                pointerStore,
                                                null);
                                return res.accepted && Boolean.TRUE.equals(res.future.get());
                            });

            check(aStarted.await(5, TimeUnit.SECONDS), "D2: slow refresh A entered flight");
            // User rapidly switches to B while A refresh is still blocked.
            Boolean bWritten =
                    store.saveAsync(
                                    rawB,
                                    new ConfigStore.PointerSnapshot(originB, "site_b"),
                                    pointerStore,
                                    null)
                            .get(5, TimeUnit.SECONDS);
            check(Boolean.TRUE.equals(bWritten), "D2: fast switch to B persisted cleanly");

            // Now release slow refresh A.
            releaseA.countDown();
            Boolean aCommitted = slowRefreshCommit.get(5, TimeUnit.SECONDS);
            check(
                    Boolean.FALSE.equals(aCommitted),
                    "D2: stale slow refresh A rejected by expectedWriteSeq CAS");
        } finally {
            exec.shutdownNow();
        }

        // Simulated restart: reload config.json using persisted Prefs.ORIGIN and verify B +
        // relative URLs.
        String persistedRaw =
                new String(
                        Files.readAllBytes(new File(cfgDir, "config.json").toPath()),
                        StandardCharsets.UTF_8);
        String persistedOrigin = prefs.getString(Prefs.ORIGIN, "");
        String persistedSite = prefs.getString(Prefs.SELECTED_SITE, "");
        Cms.Config reloaded = Cms.parseConfig(persistedRaw, persistedOrigin);
        check(
                originB.equals(persistedOrigin)
                        && "site_b".equals(persistedSite)
                        && rawB.equals(persistedRaw),
                "D2: after restart origin, selected site, and body all belong to B");
        check(
                "https://host-b.example/dir-b/b.jar".equals(reloaded.spider)
                        && reloaded.sites.size() == 1
                        && "https://host-b.example/dir-b/api_b".equals(reloaded.sites.get(0).api),
                "D2: relative spider and site URLs resolve against B origin, never A");

        // A -> B -> A edit/delete while refresh of A is in flight.
        ConfigLibrary library = new ConfigLibrary(new File(tempDir, "d2-library"));
        ConfigLibrary.Entry entryA = library.remember(rawA1, originA, "订阅A", "site_a", 1000L);
        library.remember(rawB, originB, "订阅B", "site_b", 2000L);

        // Case 1: Delete A while slow refresh is in flight -> must NOT resurrect A!
        final CountDownLatch delFetchEntered = new CountDownLatch(1);
        final CountDownLatch delFetchRelease = new CountDownLatch(1);
        ExecutorService exec2 = Executors.newSingleThreadExecutor();
        try {
            Future<SubscriptionManager.RefreshSummary> refreshFuture =
                    exec2.submit(
                            () ->
                                    SubscriptionManager.refreshDueSubscriptions(
                                            library,
                                            originB,
                                            rawB,
                                            100_000_000L,
                                            true,
                                            url -> {
                                                if (originA.equals(url)) {
                                                    delFetchEntered.countDown();
                                                    delFetchRelease.await(5, TimeUnit.SECONDS);
                                                    return rawA2;
                                                }
                                                return rawB;
                                            }));
            check(delFetchEntered.await(5, TimeUnit.SECONDS), "D2: delete-race fetch A in flight");
            check(library.remove(entryA.id), "D2: deleted A while A refresh in flight");
            delFetchRelease.countDown();
            SubscriptionManager.RefreshSummary delSummary = refreshFuture.get(5, TimeUnit.SECONDS);
            boolean foundA = false;
            for (ConfigLibrary.Entry e : library.entries()) {
                if (originA.equals(e.origin)) foundA = true;
            }
            check(!foundA, "D2: stale refresh A did not resurrect deleted subscription A");
            check(
                    delSummary.updatedCount == 0,
                    "D2: discarded deleted-entry refresh not counted as updated");
        } finally {
            exec2.shutdownNow();
        }

        // Case 2: Edit A (content + custom name + selected site) while slow refresh of A is in
        // flight -> must NOT undo user edit!
        final String rawAEdited =
                "{\"spider\":\"./a_custom.jar\",\"sites\":[{\"key\":\"site_custom\",\"name\":\"用户手改A\",\"type\":1,\"api\":\"./api_custom\"}]}";
        library.remember(rawA1, originA, "订阅A", "site_a", 1000L);
        final CountDownLatch editFetchEntered = new CountDownLatch(1);
        final CountDownLatch editFetchRelease = new CountDownLatch(1);
        ExecutorService exec3 = Executors.newSingleThreadExecutor();
        try {
            Future<SubscriptionManager.RefreshSummary> refreshFuture =
                    exec3.submit(
                            () ->
                                    SubscriptionManager.refreshDueSubscriptions(
                                            library,
                                            originA,
                                            rawA1,
                                            200_000_000L,
                                            true,
                                            url -> {
                                                if (originA.equals(url)) {
                                                    editFetchEntered.countDown();
                                                    editFetchRelease.await(5, TimeUnit.SECONDS);
                                                    return rawA2;
                                                }
                                                return rawB;
                                            }));
            check(editFetchEntered.await(5, TimeUnit.SECONDS), "D2: edit-race fetch A in flight");
            library.remember(rawAEdited, originA, "我的自定义A", "site_custom", 150_000_000L);
            editFetchRelease.countDown();
            refreshFuture.get(5, TimeUnit.SECONDS);

            ConfigLibrary.Entry afterEdit = null;
            for (ConfigLibrary.Entry e : library.entries()) {
                if (originA.equals(e.origin)) afterEdit = e;
            }
            check(
                    afterEdit != null
                            && rawAEdited.equals(library.raw(afterEdit))
                            && "我的自定义A".equals(afterEdit.name)
                            && "site_custom".equals(afterEdit.selected),
                    "D2: stale refresh A did not overwrite concurrent user edit or selection");
        } finally {
            exec3.shutdownNow();
        }
    }

    private static void testD3TombstoneDeleteSyncAndRefav() throws Exception {
        WatchHistory.setCorrupted(false);
        // 1. Seed a cloud snapshot with 2 history items + 1 favorite.
        WatchHistory.Entry h1 = new WatchHistory.Entry();
        h1.site = "s1";
        h1.id = "v1";
        h1.title = "电影一";
        h1.line = "L1";
        h1.episode = "正片";
        h1.position = 120_000;
        h1.duration = 5_000_000;
        h1.updated = 10_000L;

        WatchHistory.Entry h2 = new WatchHistory.Entry();
        h2.site = "s1";
        h2.id = "v2";
        h2.title = "电影二";
        h2.line = "L1";
        h2.episode = "第2集";
        h2.position = 60_000;
        h2.duration = 2_400_000;
        h2.updated = 10_500L;

        Cms.Video favVideo = new Cms.Video();
        favVideo.id = "v1";
        favVideo.title = "电影一";
        favVideo.poster = "https://img.example/1.jpg";

        String seedHist = WatchHistory.upsert(WatchHistory.upsert("[]", h1), h2);
        String seedFav = Favorites.toggle("[]", "s1", favVideo);
        String seedTombs = CloudSync.Tombstones.recordFavoriteToggle("", "s1\nv1", true, 10_000L);
        String cloudSnapshot =
                CloudSync.exportPayload(seedHist, seedFav, seedTombs, null, false, 11_000L);

        // Mobile Client 1 & Client 2 both start synced to the cloud snapshot.
        Map<String, Object> client1Disk = new HashMap<>();
        Map<String, Object> client2Disk = new HashMap<>();
        MapPrefs client1 = new MapPrefs(client1Disk);
        MapPrefs client2 = new MapPrefs(client2Disk);

        CloudSync.mergeSerial(
                WatchHistory.STORAGE_EXECUTOR,
                storeFor(client1),
                null,
                false,
                true,
                cloudSnapshot,
                11_100L);
        CloudSync.mergeSerial(
                WatchHistory.STORAGE_EXECUTOR,
                storeFor(client2),
                null,
                false,
                true,
                cloudSnapshot,
                11_100L);
        check(
                WatchHistory.read(client1.getString(Prefs.WATCH_HISTORY, "[]")).size() == 2
                        && Favorites.read(client1.getString(Prefs.FAVORITES, "[]")).size() == 1,
                "D3: client 1 hydrated with 2 history + 1 favorite from cloud snapshot");

        // 2. Client 1 performs offline mobile actions via atomic CloudSyncDialog helpers:
        //    - Single history delete (h1)
        //    - Clear remaining history (h2)
        //    - Unfavorite (v1) even with same timestamp edge case
        WatchHistory.callOnStorageExecutor(
                () -> {
                    CloudSyncDialog.removeHistoryWithTombstoneSync(
                            client1, false, h1.key(), 10_000L);
                    CloudSyncDialog.clearHistoryWithTombstoneSync(client1, false, 10_200L);
                    CloudSyncDialog.toggleFavoriteWithTombstoneSync(
                            client1, false, "s1", favVideo, 10_000L);
                    return null;
                });

        check(
                WatchHistory.read(client1.getString(Prefs.WATCH_HISTORY, "[]")).isEmpty()
                        && Favorites.read(client1.getString(Prefs.FAVORITES, "[]")).isEmpty(),
                "D3: local history & favorites empty immediately after mobile delete/clear/unfavorite");
        CloudSync.Tombstones c1Tombs =
                CloudSync.Tombstones.read(client1.getString(Prefs.SYNC_TOMBSTONES, ""));
        check(
                c1Tombs.get("hist:" + h1.key()) >= h1.updated
                        && c1Tombs.get("hist:" + h2.key()) >= h2.updated
                        && c1Tombs.get("fav:s1\nv1") > 10_000L,
                "D3: atomic tombstones persisted with clock-skew-safe timestamps");

        // 3. Merge client 1 with the OLD preset cloud snapshot TWICE!
        CloudSync.MergeResult merge1 =
                CloudSync.mergeSerial(
                        WatchHistory.STORAGE_EXECUTOR,
                        storeFor(client1),
                        null,
                        false,
                        true,
                        cloudSnapshot,
                        12_000L);
        CloudSync.MergeResult merge2 =
                CloudSync.mergeSerial(
                        WatchHistory.STORAGE_EXECUTOR,
                        storeFor(client1),
                        null,
                        false,
                        true,
                        cloudSnapshot,
                        13_000L);
        check(
                merge1.historyCount == 0
                        && merge1.favoriteCount == 0
                        && merge2.historyCount == 0
                        && merge2.favoriteCount == 0,
                "D3: merging old preset cloud snapshot twice never resurrects deleted history or favorite");

        // 4. Simulate client 1 restart and sync Client 2 against merged cloud payload -> BOTH
        // empty.
        MapPrefs client1Restarted = new MapPrefs(client1Disk);
        String cloudAfterDelete = merge2.payloadJson;
        CloudSync.MergeResult client2Sync =
                CloudSync.mergeSerial(
                        WatchHistory.STORAGE_EXECUTOR,
                        storeFor(client2),
                        null,
                        false,
                        true,
                        cloudAfterDelete,
                        14_000L);
        check(
                WatchHistory.read(client1Restarted.getString(Prefs.WATCH_HISTORY, "[]")).isEmpty()
                        && Favorites.read(client1Restarted.getString(Prefs.FAVORITES, "[]"))
                                .isEmpty()
                        && client2Sync.historyCount == 0
                        && client2Sync.favoriteCount == 0
                        && WatchHistory.read(client2.getString(Prefs.WATCH_HISTORY, "[]")).isEmpty()
                        && Favorites.read(client2.getString(Prefs.FAVORITES, "[]")).isEmpty(),
                "D3: after restart & 2nd test client sync, both clients have 0 history and 0 favorites");

        // 5. Re-favorite the SAME movie on client 1 -> sync to cloud -> sync to client 2 -> EXACTLY
        // 1!
        boolean refaved =
                WatchHistory.callOnStorageExecutor(
                        () ->
                                CloudSyncDialog.toggleFavoriteWithTombstoneSync(
                                        client1Restarted, false, "s1", favVideo, 14_000L));
        check(refaved, "D3: re-favoriting same movie returns true");
        CloudSync.MergeResult c1PushRefav =
                CloudSync.mergeSerial(
                        WatchHistory.STORAGE_EXECUTOR,
                        storeFor(client1Restarted),
                        null,
                        false,
                        true,
                        cloudAfterDelete,
                        15_000L);
        CloudSync.MergeResult c2PullRefav =
                CloudSync.mergeSerial(
                        WatchHistory.STORAGE_EXECUTOR,
                        storeFor(client2),
                        null,
                        false,
                        true,
                        c1PushRefav.payloadJson,
                        16_000L);
        List<Favorites.Entry> c1Favs =
                Favorites.read(client1Restarted.getString(Prefs.FAVORITES, "[]"));
        List<Favorites.Entry> c2Favs = Favorites.read(client2.getString(Prefs.FAVORITES, "[]"));
        check(
                c1PushRefav.favoriteCount == 1
                        && c2PullRefav.favoriteCount == 1
                        && c1Favs.size() == 1
                        && c2Favs.size() == 1
                        && "v1".equals(c2Favs.get(0).id),
                "D3: re-favoriting same movie syncs to exactly 1 entry across both clients");

        // 6. Private mode isolation: mutating favorites/history in private mode writes ZERO
        // tombstones.
        MapPrefs privPrefs = new MapPrefs();
        WatchHistory.callOnStorageExecutor(
                () -> {
                    CloudSyncDialog.toggleFavoriteWithTombstoneSync(
                            privPrefs, true, "priv_s", favVideo, 20_000L);
                    CloudSyncDialog.toggleFavoriteWithTombstoneSync(
                            privPrefs, true, "priv_s", favVideo, 20_100L);
                    CloudSyncDialog.removeHistoryWithTombstoneSync(
                            privPrefs, true, "priv_s\nv1", 20_200L);
                    CloudSyncDialog.clearHistoryWithTombstoneSync(privPrefs, true, 20_300L);
                    return null;
                });
        check(
                !privPrefs.contains(Prefs.SYNC_TOMBSTONES),
                "D3: private mode operations never write cloud sync tombstones");
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

    private static void testD4ConcurrentSearchIsolation() {
        MobileSearchPage.invalidateSession();
        Object cfg = new Object();
        long page1 = MobileSearchPage.beginPage();

        Cms.Site sA = makeSite("site_a", "甲片源");
        Cms.Site sB1 = makeSite("site_b1", "乙片源一");
        Cms.Site sB2 = makeSite("site_b2", "乙片源二");

        // Start query A ("甲"), then immediately start query B ("乙") before A responds.
        MobileSearchPage.SearchSession sessionA =
                MobileSearchPage.startSession(page1, "甲", false, cfg, 1, 10, 1);
        MobileSearchPage.SearchSession sessionB =
                MobileSearchPage.startSession(page1, "乙", false, cfg, 1, 10, 2);
        check(sessionA.cancelled, "D4: starting query B immediately cancels query A");

        // Query B receives results from both sites and renders.
        List<MobileSearchPage.Hit> bBatch1 =
                Collections.singletonList(new MobileSearchPage.Hit(sB1, makeVideo("b1", "乙电影一")));
        List<MobileSearchPage.Hit> bBatch2 =
                Collections.singletonList(new MobileSearchPage.Hit(sB2, makeVideo("b2", "乙电影二")));
        check(
                MobileSearchPage.acceptBatchIfCurrent(sessionB, false, cfg, 1, 10, bBatch1)
                        && MobileSearchPage.acceptBatchIfCurrent(
                                sessionB, false, cfg, 1, 10, bBatch2),
                "D4: query B batches accepted");

        // Late callback from query A arrives AFTER query B is displayed!
        List<MobileSearchPage.Hit> aLateBatch =
                Collections.singletonList(new MobileSearchPage.Hit(sA, makeVideo("a1", "甲电影迟到")));
        boolean acceptedA =
                MobileSearchPage.acceptBatchIfCurrent(sessionA, false, cfg, 1, 10, aLateBatch);
        check(!acceptedA, "D4: late callback from query A rejected after query B displayed");

        // Verify B's keyword, count, titles, filter, click targets, and return cache are untouched.
        List<MobileSearchPage.Hit> bHits = sessionB.snapshotHits();
        Map<String, Integer> bCounts = sessionB.siteCounts();
        check(
                "乙".equals(sessionB.keyword)
                        && bHits.size() == 2
                        && sessionB.status().contains("2/2")
                        && sessionB.status().contains("2 条结果"),
                "D4: query B keyword, count, and status untouched by late A");
        check(
                "乙电影一".equals(bHits.get(0).video.title)
                        && "b1".equals(bHits.get(0).video.id)
                        && "site_b1".equals(bHits.get(0).site.key)
                        && "乙电影二".equals(bHits.get(1).video.title)
                        && "b2".equals(bHits.get(1).video.id)
                        && "site_b2".equals(bHits.get(1).site.key),
                "D4: query B titles and click targets contain zero entries from A");
        check(
                !bCounts.containsKey("site_a")
                        && Integer.valueOf(1).equals(bCounts.get("site_b1"))
                        && Integer.valueOf(1).equals(bCounts.get("site_b2")),
                "D4: site filter counts exclude A completely");
        sessionB.setSelectedSiteFilter("site_b1");
        List<MobileSearchPage.Hit> filtered = sessionB.filteredHits();
        check(
                filtered.size() == 1 && "b1".equals(filtered.get(0).video.id),
                "D4: site filter yields exact B click target");

        // Return cache within same context restores B cleanly (zero A contamination).
        MobileSearchPage.SearchSession returned = MobileSearchPage.cachedSessionFor(false, cfg, 1);
        check(
                returned == sessionB && returned.snapshotHits().size() == 2,
                "D4: return cache preserves completed query B in same space/source");

        // Switching space (privateMode=true) or source/epoch rejects cache and callbacks.
        check(
                MobileSearchPage.cachedSessionFor(true, cfg, 1) == null
                        && MobileSearchPage.cachedSessionFor(false, new Object(), 1) == null
                        && MobileSearchPage.cachedSessionFor(false, cfg, 2) == null,
                "D4: space switch or config/epoch change never leaks cached search results");

        // Exiting page while query C is in flight cancels C and drops its late callback.
        long page2 = MobileSearchPage.beginPage();
        MobileSearchPage.SearchSession sessionC =
                MobileSearchPage.startSession(page2, "丙", false, cfg, 1, 11, 2);
        MobileSearchPage.onPageExit();
        check(sessionC.cancelled, "D4: exiting Search page cancels in-flight query C");
        List<MobileSearchPage.Hit> cLateBatch =
                Collections.singletonList(new MobileSearchPage.Hit(sA, makeVideo("c1", "丙迟到")));
        check(
                !MobileSearchPage.acceptBatchIfCurrent(sessionC, false, cfg, 1, 11, cLateBatch)
                        && MobileSearchPage.cachedSessionFor(false, cfg, 1) == null,
                "D4: late callback after page exit dropped and never populates cache");
    }

    private static void testStaticWiringGuards(File srcRoot) throws Exception {
        String sourceController =
                new String(
                        Files.readAllBytes(new File(srcRoot, "SourceController.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                !sourceController.contains("a.configStore.write("),
                "D2 wiring: SourceController has zero raw configStore.write() bypasses");
        check(
                sourceController.contains("saveIfExpectedSeq("),
                "D2 wiring: SourceController uses saveIfExpectedSeq CAS");
        check(
                sourceController.contains("MobileSearchPage.invalidateSession()"),
                "D4 wiring: SourceController.closeEngines invalidates search session");

        String uiWidgets =
                new String(
                        Files.readAllBytes(new File(srcRoot, "UiWidgets.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                !uiWidgets.contains("String origin = a.configOrigin;"),
                "D2 wiring: UiWidgets.importTextOrUrl does not inherit previous origin for pasted raw JSON");
        check(
                uiWidgets.contains("SourceController.beginConfigImport(a)"),
                "D2 wiring: UiWidgets.importTextOrUrl guards async imports with importSeq");

        String libPage =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileLibraryPage.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                libPage.contains("CloudSyncDialog.clearHistoryWithTombstone(")
                        && libPage.contains("CloudSyncDialog.removeHistoryWithTombstone(")
                        && libPage.contains("CloudSyncDialog.removeFavoriteWithTombstone(")
                        && !libPage.contains("CloudSyncDialog.toggleFavoriteWithTombstone("),
                "D3/R6 wiring: MobileLibraryPage routes clear, delete, and idempotent unfavorite through atomic CloudSyncDialog");
        check(
                !libPage.contains("putString(Prefs.WATCH_HISTORY")
                        && !libPage.contains("putString(Prefs.FAVORITES"),
                "D3 wiring: MobileLibraryPage has zero direct un-tombstoned prefs writes");

        String homePage =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileHomePage.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                homePage.contains("CloudSyncDialog.removeHistoryWithTombstone("),
                "D3 wiring: MobileHomePage continue-watching removal uses atomic tombstone helper");

        String detailScreen =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileDetailScreen.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                detailScreen.contains("CloudSyncDialog.toggleFavoriteWithTombstone(")
                        && !detailScreen.contains("Favorites.toggle("),
                "D3 wiring: MobileDetailScreen favorite button uses atomic tombstone helper");

        String privacySpace =
                new String(
                        Files.readAllBytes(new File(srcRoot, "PrivacySpace.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                privacySpace.contains("MainActivity.cleanupLegacyPrivateHistory(")
                        && privacySpace.contains("MobileRootShell.resetStaticState()"),
                "D1/D4 wiring: PrivacySpace.switchSpace cleans legacy private history and resets mobile shell");
    }

    public static void main(String[] args) throws Exception {
        File tempDir = new File(args[0]);
        File srcRoot = new File(args[1]);
        testD1PrivateIsolationAndCleanup(tempDir);
        testD2StaleSubscriptionAndRaces(tempDir);
        testD3TombstoneDeleteSyncAndRefav();
        testD4ConcurrentSearchIsolation();
        testStaticWiringGuards(srcRoot);
        System.out.println(checks + " Batch 2 data safety checks passed");
        System.exit(0);
    }
}

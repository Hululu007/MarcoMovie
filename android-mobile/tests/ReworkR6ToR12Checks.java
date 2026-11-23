package com.pilipala.marcomovie;

import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.net.Uri;
import androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist;
import androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist;
import androidx.media3.exoplayer.hls.playlist.HlsPlaylist;
import androidx.media3.exoplayer.hls.playlist.HlsPlaylistParser;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;

/**
 * Automated regression suite for Codex Rework Items R6-R10 & R12 (R11 CI & R7 ffprobe offline
 * decode/seek checks are executed by {@code run_rework_r6_r12_checks.py}):
 *
 * <ul>
 *   <li>R6: Idempotent unfavorite removal (repeated clicks, remote-already-deleted, re-favorite).
 *   <li>R7: Multi-{@code #EXT-X-MAP} fMP4 HLS parsing, local playlist generation, end-to-end
 *       download of dual-MAP separated-audio fMP4 bundle, and failure rejection on missing init.
 *   <li>R8: Broken home source error propagation (never masked as empty library) vs true empty
 *       listing and valid fallback listing.
 *   <li>R9: Latch-controlled slow file import A cannot overwrite newer selection B, nor commit
 *       after Activity destroy or private-space switch.
 *   <li>R10: Kernel fallback preserves minute-20 resume position and honors {@code AUTO_SWITCH_KERNEL}
 *       in both inline and fullscreen; manual episode switch flushes outgoing progress first.
 *   <li>R12: Request-owned loading-site guard prevents A-after-B marker clobbering, distinguishes
 *       benign OS background reclaim from attributable crashes, and preserves real crash recovery.
 * </ul>
 */
public final class ReworkR6ToR12Checks {
    private static int checks;

    private static void check(boolean cond, String label) {
        if (!cond) {
            throw new AssertionError("FAIL: " + label);
        }
        checks++;
        System.out.println("PASS " + label);
    }

    static final class MapPrefs implements SharedPreferences {
        private final Map<String, Object> data = new HashMap<>();

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

    // -------------------------------------------------------------------------
    // R6: Idempotent Unfavorite Removal
    // -------------------------------------------------------------------------

    private static void testR6IdempotentUnfavorite(File srcRoot) throws Exception {
        MapPrefs prefs = new MapPrefs();
        Cms.Video v = new Cms.Video();
        v.id = "v";
        v.title = "V";
        v.poster = "https://img.example/v.jpg";

        // Initial favorite present
        prefs.edit().putString(Prefs.FAVORITES, Favorites.toggle("[]", "site", v)).apply();
        check(
                Favorites.contains(prefs.getString(Prefs.FAVORITES, "[]"), "site", "v"),
                "R6 setup: favorite initially present");

        // Double-tap / duplicate invocation of idempotent remove stays absent
        boolean r1 =
                CloudSyncDialog.removeFavoriteWithTombstoneSync(prefs, false, "site", "v", 1000L);
        boolean r2 =
                CloudSyncDialog.removeFavoriteWithTombstoneSync(prefs, false, "site", "v", 1001L);
        check(
                !r1
                        && !r2
                        && !Favorites.contains(prefs.getString(Prefs.FAVORITES, "[]"), "site", "v"),
                "R6: repeated removeFavoriteWithTombstoneSync stays absent (never re-adds)");

        // Cloud merge against remote snapshot that still had the item keeps it deleted
        String staleRemote =
                CloudSync.exportPayload(
                        "[]", Favorites.toggle("[]", "site", v), "", null, false, 500L);
        CloudSync.mergeSerial(
                WatchHistory.STORAGE_EXECUTOR,
                storeFor(prefs),
                null,
                false,
                true,
                staleRemote,
                1200L);
        check(
                Favorites.read(prefs.getString(Prefs.FAVORITES, "[]")).isEmpty()
                        && !Favorites.contains(prefs.getString(Prefs.FAVORITES, "[]"), "site", "v"),
                "R6: cloud merge honors delete tombstone after repeated unfavorite");

        // Another client already deleted it (already empty locally), clicking remove stays empty
        boolean r3 =
                CloudSyncDialog.removeFavoriteWithTombstoneSync(prefs, false, "site", "v", 1500L);
        check(
                !r3 && Favorites.read(prefs.getString(Prefs.FAVORITES, "[]")).isEmpty(),
                "R6: removing already-absent item after remote delete stays empty");

        // Subsequent intentional re-favorite via toggleFavoriteWithTombstoneSync succeeds
        boolean refaved =
                CloudSyncDialog.toggleFavoriteWithTombstoneSync(prefs, false, "site", v, 2000L);
        check(
                refaved
                        && Favorites.contains(prefs.getString(Prefs.FAVORITES, "[]"), "site", "v")
                        && Favorites.read(prefs.getString(Prefs.FAVORITES, "[]")).size() == 1,
                "R6: intentional re-favorite after idempotent removal succeeds cleanly");

        // Static wiring check
        String libSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileLibraryPage.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                libSrc.contains("CloudSyncDialog.removeFavoriteWithTombstone(")
                        && !libSrc.contains("CloudSyncDialog.toggleFavoriteWithTombstone("),
                "R6 wiring: MobileLibraryPage unfavorite action uses idempotent removeFavoriteWithTombstone");
    }

    // -------------------------------------------------------------------------
    // R7: Multi-#EXT-X-MAP fMP4 Separated-Audio Offline HLS
    // -------------------------------------------------------------------------

    private static Context stubContext(final File root) {
        final File filesDir = new File(root, "files");
        final File moviesDir = new File(root, "movies");
        filesDir.mkdirs();
        moviesDir.mkdirs();
        return new ContextWrapper(null) {
            @Override
            public Context getApplicationContext() {
                return this;
            }

            @Override
            public File getFilesDir() {
                return filesDir;
            }

            @Override
            public File getExternalFilesDir(String type) {
                return moviesDir;
            }
        };
    }

    private static void waitTaskDoneOrFailed(DownloadManager dm, String id, long timeoutMs)
            throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            DownloadManager.Task t = findTask(dm, id);
            if (t != null
                    && (t.state == DownloadManager.DONE
                            || t.state == DownloadManager.FAILED
                            || t.state == DownloadManager.PAUSED)) {
                return;
            }
            Thread.sleep(40);
        }
        throw new AssertionError("Download task " + id + " timed out");
    }

    private static DownloadManager.Task enqueueOne(
            DownloadManager dm, Cms.Site site, Cms.Video video, Cms.Line line, Cms.Episode ep) {
        Set<String> prevIds = new HashSet<>();
        for (DownloadManager.Task prev : dm.snapshot()) prevIds.add(prev.id);
        dm.enqueue(site, video, line, Collections.singletonList(ep));
        for (DownloadManager.Task cur : dm.snapshot()) {
            if (!prevIds.contains(cur.id)) return cur;
        }
        throw new AssertionError("Failed to enqueue task: " + video.id);
    }

    private static DownloadManager.Task findTask(DownloadManager dm, String id) {
        for (DownloadManager.Task t : dm.snapshot()) {
            if (id.equals(t.id)) return t;
        }
        return null;
    }

    private static void testR7MultiMapFmp4OfflineHls(File mediaDir, File workDir) throws Exception {
        // 1. Direct parser + local playlist emitter verification (MapVerify equivalent)
        Class<?> dmCls = DownloadManager.class;
        Class<?> mediaCls = Class.forName(dmCls.getName() + "$Media");
        Method parseMedia = dmCls.getDeclaredMethod("parseMedia", String.class, String.class);
        parseMedia.setAccessible(true);
        Method buildLocal =
                dmCls.getDeclaredMethod(
                        "buildLocalMediaPlaylist", mediaCls, String.class, String.class);
        buildLocal.setAccessible(true);
        Field initSegmentsField = mediaCls.getDeclaredField("initSegments");
        initSegmentsField.setAccessible(true);

        String sampleMultiMap =
                "#EXTM3U\n"
                        + "#EXT-X-TARGETDURATION:4\n"
                        + "#EXT-X-MAP:URI=\"init1.mp4\"\n"
                        + "#EXTINF:4,\n"
                        + "first.m4s\n"
                        + "#EXT-X-DISCONTINUITY\n"
                        + "#EXT-X-MAP:URI=\"init2.mp4\"\n"
                        + "#EXTINF:4,\n"
                        + "later.m4s\n"
                        + "#EXT-X-ENDLIST\n";
        Object parsedMedia =
                parseMedia.invoke(null, sampleMultiMap, "https://fixture.invalid/show.m3u8");
        @SuppressWarnings("unchecked")
        List<Object> inits = (List<Object>) initSegmentsField.get(parsedMedia);
        check(
                inits != null && inits.size() == 2,
                "R7 parser: retains both distinct #EXT-X-MAP init segments");
        String emitted = (String) buildLocal.invoke(null, parsedMedia, "v", "v_init.mp4");
        int idxMap0 = emitted.indexOf("#EXT-X-MAP:URI=\"v_init_0.mp4\"");
        int idxSeg0 = emitted.indexOf("v_000000.m4s");
        int idxDisc = emitted.indexOf("#EXT-X-DISCONTINUITY");
        int idxMap1 = emitted.indexOf("#EXT-X-MAP:URI=\"v_init_1.mp4\"");
        int idxSeg1 = emitted.indexOf("v_000001.m4s");
        check(
                idxMap0 > 0
                        && idxSeg0 > idxMap0
                        && idxDisc > idxSeg0
                        && idxMap1 > idxDisc
                        && idxSeg1 > idxMap1,
                "R7 playlist: emits v_init_0.mp4 -> seg0 -> DISCONTINUITY -> v_init_1.mp4 -> seg1 in exact order");

        // 2. End-to-end download of real dual-MAP fMP4 separated-audio HLS from local HttpServer
        final byte[] vInit1 = Files.readAllBytes(new File(mediaDir, "v_init1.mp4").toPath());
        final byte[] vSeg1 = Files.readAllBytes(new File(mediaDir, "v_seg1.m4s").toPath());
        final byte[] vInit2 = Files.readAllBytes(new File(mediaDir, "v_init2.mp4").toPath());
        final byte[] vSeg2 = Files.readAllBytes(new File(mediaDir, "v_seg2.m4s").toPath());
        final byte[] aInit1 = Files.readAllBytes(new File(mediaDir, "a_init1.mp4").toPath());
        final byte[] aSeg1 = Files.readAllBytes(new File(mediaDir, "a_seg1.m4s").toPath());
        final byte[] aInit2 = Files.readAllBytes(new File(mediaDir, "a_init2.mp4").toPath());
        final byte[] aSeg2 = Files.readAllBytes(new File(mediaDir, "a_seg2.m4s").toPath());

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String base = "http://127.0.0.1:" + port;
        Map<String, byte[]> routes = new HashMap<>();
        routes.put(
                "/master.m3u8",
                ("#EXTM3U\n"
                                + "#EXT-X-VERSION:7\n"
                                + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"ZH\",LANGUAGE=\"zh\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n"
                                + "#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=128x72,AUDIO=\"aud\"\n"
                                + "video.m3u8\n")
                        .getBytes(StandardCharsets.UTF_8));
        routes.put(
                "/video.m3u8",
                ("#EXTM3U\n"
                                + "#EXT-X-VERSION:7\n"
                                + "#EXT-X-TARGETDURATION:3\n"
                                + "#EXT-X-MEDIA-SEQUENCE:0\n"
                                + "#EXT-X-MAP:URI=\"v_init1.mp4\"\n"
                                + "#EXTINF:2.000,\n"
                                + "v_seg1.m4s\n"
                                + "#EXT-X-DISCONTINUITY\n"
                                + "#EXT-X-MAP:URI=\"v_init2.mp4\"\n"
                                + "#EXTINF:2.000,\n"
                                + "v_seg2.m4s\n"
                                + "#EXT-X-ENDLIST\n")
                        .getBytes(StandardCharsets.UTF_8));
        routes.put(
                "/audio.m3u8",
                ("#EXTM3U\n"
                                + "#EXT-X-VERSION:7\n"
                                + "#EXT-X-TARGETDURATION:3\n"
                                + "#EXT-X-MEDIA-SEQUENCE:0\n"
                                + "#EXT-X-MAP:URI=\"a_init1.mp4\"\n"
                                + "#EXTINF:2.000,\n"
                                + "a_seg1.m4s\n"
                                + "#EXT-X-DISCONTINUITY\n"
                                + "#EXT-X-MAP:URI=\"a_init2.mp4\"\n"
                                + "#EXTINF:2.000,\n"
                                + "a_seg2.m4s\n"
                                + "#EXT-X-ENDLIST\n")
                        .getBytes(StandardCharsets.UTF_8));
        routes.put(
                "/broken-master.m3u8",
                ("#EXTM3U\n"
                                + "#EXT-X-VERSION:7\n"
                                + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"ZH\",LANGUAGE=\"zh\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n"
                                + "#EXT-X-STREAM-INF:BANDWIDTH=2400000,AUDIO=\"aud\"\n"
                                + "broken-video.m3u8\n")
                        .getBytes(StandardCharsets.UTF_8));
        routes.put(
                "/broken-video.m3u8",
                ("#EXTM3U\n"
                                + "#EXT-X-VERSION:7\n"
                                + "#EXT-X-TARGETDURATION:3\n"
                                + "#EXT-X-MAP:URI=\"v_init1.mp4\"\n"
                                + "#EXTINF:2.000,\n"
                                + "v_seg1.m4s\n"
                                + "#EXT-X-DISCONTINUITY\n"
                                + "#EXT-X-MAP:URI=\"missing_init2.mp4\"\n"
                                + "#EXTINF:2.000,\n"
                                + "v_seg2.m4s\n"
                                + "#EXT-X-ENDLIST\n")
                        .getBytes(StandardCharsets.UTF_8));
        routes.put("/v_init1.mp4", vInit1);
        routes.put("/v_seg1.m4s", vSeg1);
        routes.put("/v_init2.mp4", vInit2);
        routes.put("/v_seg2.m4s", vSeg2);
        routes.put("/a_init1.mp4", aInit1);
        routes.put("/a_seg1.m4s", aSeg1);
        routes.put("/a_init2.mp4", aInit2);
        routes.put("/a_seg2.m4s", aSeg2);

        server.createContext(
                "/",
                ex -> {
                    byte[] body = routes.get(ex.getRequestURI().getPath());
                    if (body == null) {
                        ex.sendResponseHeaders(404, -1);
                        ex.close();
                        return;
                    }
                    ex.sendResponseHeaders(200, body.length);
                    try (OutputStream out = ex.getResponseBody()) {
                        out.write(body);
                    }
                });
        server.start();
        try {
            File dlRoot = new File(workDir, "r7-dl");
            DownloadManager dm = DownloadManager.get(stubContext(dlRoot));

            Cms.Site site = new Cms.Site();
            site.key = "vod";
            site.name = "VOD";
            site.api = base + "/master.m3u8";
            Cms.Line line = new Cms.Line();
            line.name = "Line1";
            Cms.Video video = new Cms.Video();
            video.id = "r7_dual_map";
            video.title = "DualMapShow";
            Cms.Episode ep = new Cms.Episode();
            ep.name = "EP01";
            ep.url = base + "/master.m3u8";
            line.episodes.add(ep);
            DownloadManager.Task okTask = enqueueOne(dm, site, video, line, ep);
            waitTaskDoneOrFailed(dm, okTask.id, 30_000L);
            DownloadManager.Task doneTask = findTask(dm, okTask.id);
            check(
                    doneTask != null
                            && doneTask.state == DownloadManager.DONE
                            && doneTask.path.endsWith("master.m3u8"),
                    "R7 download: dual-MAP separated-audio fMP4 finishes DONE as local master.m3u8 (state="
                            + (doneTask == null
                                    ? "null"
                                    : doneTask.state + ", err=" + doneTask.error)
                            + ")");
            File bundleDir = new File(doneTask.path).getParentFile();
            check(
                    new File(bundleDir, "v_init_0.mp4").length() == vInit1.length
                            && new File(bundleDir, "v_init_1.mp4").length() == vInit2.length
                            && new File(bundleDir, "a_init_0.mp4").length() == aInit1.length
                            && new File(bundleDir, "a_init_1.mp4").length() == aInit2.length
                            && new File(bundleDir, "v_000000.m4s").length() == vSeg1.length
                            && new File(bundleDir, "v_000001.m4s").length() == vSeg2.length
                            && new File(bundleDir, "a_000000.m4s").length() == aSeg1.length
                            && new File(bundleDir, "a_000001.m4s").length() == aSeg2.length,
                    "R7 bundle: all 4 distinct video/audio init files and all 4 m4s segments preserved intact");
            String localVideoM3u8 =
                    new String(
                            Files.readAllBytes(new File(bundleDir, "video.m3u8").toPath()),
                            StandardCharsets.UTF_8);
            String localAudioM3u8 =
                    new String(
                            Files.readAllBytes(new File(bundleDir, "audio.m3u8").toPath()),
                            StandardCharsets.UTF_8);
            check(
                    localVideoM3u8.contains("v_init_0.mp4")
                            && localVideoM3u8.contains("v_init_1.mp4")
                            && localAudioM3u8.contains("a_init_0.mp4")
                            && localAudioM3u8.contains("a_init_1.mp4"),
                    "R7 bundle: both video.m3u8 and audio.m3u8 reference both per-segment MAP files");

            // Parse the emitted offline master/video/audio playlists with production Media3
            // HlsPlaylistParser to verify per-segment initializationSegment & discontinuity mapping
            String localMasterM3u8 =
                    new String(
                            Files.readAllBytes(new File(bundleDir, "master.m3u8").toPath()),
                            StandardCharsets.UTF_8);
            HlsPlaylistParser m3Parser = new HlsPlaylistParser();
            HlsPlaylist parsedMaster =
                    m3Parser.parse(
                            Uri.parse("file:///offline/master.m3u8"),
                            new ByteArrayInputStream(
                                    localMasterM3u8.getBytes(StandardCharsets.UTF_8)));
            check(
                    parsedMaster instanceof HlsMultivariantPlaylist
                            && ((HlsMultivariantPlaylist) parsedMaster).variants.size() == 1
                            && ((HlsMultivariantPlaylist) parsedMaster).audios.size() == 1,
                    "R7 Media3 parser: offline master.m3u8 declares both video variant and separated audio rendition");
            HlsPlaylistParser mediaParser =
                    new HlsPlaylistParser((HlsMultivariantPlaylist) parsedMaster, null);
            HlsMediaPlaylist parsedVideo =
                    (HlsMediaPlaylist)
                            mediaParser.parse(
                                    Uri.parse("file:///offline/video.m3u8"),
                                    new ByteArrayInputStream(
                                            localVideoM3u8.getBytes(StandardCharsets.UTF_8)));
            HlsMediaPlaylist parsedAudio =
                    (HlsMediaPlaylist)
                            mediaParser.parse(
                                    Uri.parse("file:///offline/audio.m3u8"),
                                    new ByteArrayInputStream(
                                            localAudioM3u8.getBytes(StandardCharsets.UTF_8)));
            check(
                    parsedVideo.segments.size() == 2
                            && parsedVideo.segments.get(0).initializationSegment != null
                            && "v_init_0.mp4"
                                    .equals(parsedVideo.segments.get(0).initializationSegment.url)
                            && parsedVideo.segments.get(0).relativeDiscontinuitySequence == 0
                            && parsedVideo.segments.get(1).initializationSegment != null
                            && "v_init_1.mp4"
                                    .equals(parsedVideo.segments.get(1).initializationSegment.url)
                            && parsedVideo.segments.get(1).relativeDiscontinuitySequence == 1,
                    "R7 Media3 parser: video.m3u8 maps seg0->v_init_0.mp4 (disc=0) and seg1->v_init_1.mp4 (disc=1)");
            check(
                    parsedAudio.segments.size() == 2
                            && parsedAudio.segments.get(0).initializationSegment != null
                            && "a_init_0.mp4"
                                    .equals(parsedAudio.segments.get(0).initializationSegment.url)
                            && parsedAudio.segments.get(0).relativeDiscontinuitySequence == 0
                            && parsedAudio.segments.get(1).initializationSegment != null
                            && "a_init_1.mp4"
                                    .equals(parsedAudio.segments.get(1).initializationSegment.url)
                            && parsedAudio.segments.get(1).relativeDiscontinuitySequence == 1,
                    "R7 Media3 parser: audio.m3u8 maps seg0->a_init_0.mp4 (disc=0) and seg1->a_init_1.mp4 (disc=1)");

            // Write master.m3u8 path for Python runner's offline ffprobe/ffmpeg verification AFTER
            // server is stopped!
            Files.write(
                    new File(workDir, "r7-master-path.txt").toPath(),
                    doneTask.path.getBytes(StandardCharsets.UTF_8));

            // Failure case: second MAP 404 MUST fail and NEVER mark DONE
            Cms.Video badVideo = new Cms.Video();
            badVideo.id = "r7_missing_init2";
            badVideo.title = "BrokenDualMap";
            Cms.Episode badEp = new Cms.Episode();
            badEp.name = "EP02";
            badEp.url = base + "/broken-master.m3u8";
            DownloadManager.Task failTask = enqueueOne(dm, site, badVideo, line, badEp);
            waitTaskDoneOrFailed(dm, failTask.id, 20_000L);
            DownloadManager.Task failed = findTask(dm, failTask.id);
            check(
                    failed != null
                            && failed.state == DownloadManager.FAILED
                            && (failed.path == null || failed.path.isEmpty()),
                    "R7 failure: missing second #EXT-X-MAP fails explicitly and never marks DONE");
        } finally {
            server.stop(0);
        }
    }

    // -------------------------------------------------------------------------
    // R8: Broken Home Source Must Surface Error (Never Empty Library)
    // -------------------------------------------------------------------------

    private static void testR8BrokenHomeSource(File srcRoot) throws Exception {
        Cms.Category cat = new Cms.Category();
        cat.id = "one";
        cat.name = "电影";
        String catsOnlyHome = "{\"class\":[{\"type_id\":\"one\",\"type_name\":\"电影\"}]}";

        // 1. Both homeVideos() and category() throw -> MUST throw IOException (NOT empty success!)
        AtomicInteger enteredHomeVideos = new AtomicInteger();
        AtomicInteger enteredCategory = new AtomicInteger();
        SourceEngine failingSource =
                (SourceEngine)
                        Proxy.newProxyInstance(
                                SourceEngine.class.getClassLoader(),
                                new Class<?>[] {SourceEngine.class},
                                (proxy, method, args) -> {
                                    if ("homeVideos".equals(method.getName())) {
                                        enteredHomeVideos.incrementAndGet();
                                    } else if ("category".equals(method.getName())) {
                                        enteredCategory.incrementAndGet();
                                    }
                                    throw new IOException("fixture unavailable");
                                });
        boolean threw = false;
        String errMsg = "";
        try {
            MobileHomePage.resolveHomeListing(
                    failingSource, catsOnlyHome, Collections.singletonList(cat));
        } catch (Exception e) {
            threw = true;
            errMsg = e.getMessage() == null ? "" : e.getMessage();
        }
        check(
                threw
                        && enteredHomeVideos.get() == 1
                        && enteredCategory.get() == 1
                        && errMsg.contains("fixture unavailable"),
                "R8: all home/category fallback failures propagate error instead of empty success");

        // 2. True empty list (category returns {"list":[]}) MUST succeed cleanly with 0 videos
        SourceEngine trueEmptySource =
                (SourceEngine)
                        Proxy.newProxyInstance(
                                SourceEngine.class.getClassLoader(),
                                new Class<?>[] {SourceEngine.class},
                                (proxy, method, args) -> "{\"list\":[]}");
        Cms.Listing emptyListing =
                MobileHomePage.resolveHomeListing(
                        trueEmptySource, catsOnlyHome, Collections.singletonList(cat));
        check(
                emptyListing != null && emptyListing.videos.isEmpty(),
                "R8 control: genuinely empty source returns empty listing without false error");

        // 3. homeVideos() throws, category() returns valid fallback video -> displays normally
        SourceEngine partialSource =
                (SourceEngine)
                        Proxy.newProxyInstance(
                                SourceEngine.class.getClassLoader(),
                                new Class<?>[] {SourceEngine.class},
                                (proxy, method, args) -> {
                                    if ("homeVideos".equals(method.getName())) {
                                        throw new IOException("homeVideos unsupported");
                                    }
                                    return "{\"list\":[{\"vod_id\":\"101\",\"vod_name\":\"备用影片\",\"vod_pic\":\"https://img.example/101.jpg\"}]}";
                                });
        Cms.Listing recovered =
                MobileHomePage.resolveHomeListing(
                        partialSource, catsOnlyHome, Collections.singletonList(cat));
        check(
                recovered.videos.size() == 1 && "备用影片".equals(recovered.videos.get(0).title),
                "R8: valid category fallback succeeds even when homeVideos() throws");

        // Static wiring check: MobileHomePage shows stage error and recoverSwitchBtn on catch
        String homeSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileHomePage.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                homeSrc.contains("SourceController.stageMessage(\"列表读取失败\", e)")
                        && homeSrc.contains("recoverSwitchBtn.setVisibility(View.VISIBLE)"),
                "R8 wiring: MobileHomePage error branch displays stage failure and keeps switch-source CTA visible");
    }

    // -------------------------------------------------------------------------
    // R9: Slow File Import Cannot Overwrite Newer Selection / Destroy / Space
    // -------------------------------------------------------------------------

    private static void testR9SlowFileImportGuards(File srcRoot) throws Exception {
        ExecutorService workers = Executors.newFixedThreadPool(2);
        ExecutorService fakeMain = Executors.newSingleThreadExecutor();
        try {
            final AtomicLong importSeq = new AtomicLong(0L);
            final AtomicBoolean finishing = new AtomicBoolean(false);
            final AtomicBoolean destroyed = new AtomicBoolean(false);
            final AtomicBoolean switchingPrivacy = new AtomicBoolean(false);
            final AtomicBoolean privateMode = new AtomicBoolean(false);

            SourceController.LocalImportGuardState guard =
                    new SourceController.LocalImportGuardState() {
                        @Override
                        public long beginImport() {
                            return importSeq.incrementAndGet();
                        }

                        @Override
                        public boolean isPrivateMode() {
                            return privateMode.get();
                        }

                        @Override
                        public boolean canCommit(boolean snapPrivate, long seq) {
                            return SourceController.canCommitConfigImport(
                                    finishing.get(),
                                    destroyed.get(),
                                    switchingPrivacy.get(),
                                    privateMode.get(),
                                    snapPrivate,
                                    importSeq.get(),
                                    seq);
                        }
                    };

            final byte[] cfgA =
                    "{\"sites\":[{\"key\":\"site_a\",\"name\":\"SlowFileA\",\"type\":1,\"api\":\"https://a.example/api\"}]}"
                            .getBytes(StandardCharsets.UTF_8);
            final byte[] cfgB =
                    "{\"sites\":[{\"key\":\"site_b\",\"name\":\"FastFileB\",\"type\":1,\"api\":\"https://b.example/api\"}]}"
                            .getBytes(StandardCharsets.UTF_8);

            // 1. Slow file provider A blocked on latch; fast file B finishes first; A released last
            final CountDownLatch aReading = new CountDownLatch(1);
            final CountDownLatch releaseA = new CountDownLatch(1);
            final CountDownLatch bCommitted = new CountDownLatch(1);
            final CountDownLatch aDone = new CountDownLatch(1);
            final AtomicReference<String> activeSite = new AtomicReference<>("");
            final AtomicInteger commitCount = new AtomicInteger();

            SourceController.LocalImportResultHandler handler =
                    new SourceController.LocalImportResultHandler() {
                        @Override
                        public void onConfigReady(Cms.Config config, String origin) {
                            activeSite.set(config.sites.get(0).key);
                            commitCount.incrementAndGet();
                            if ("site_b".equals(config.sites.get(0).key)) {
                                bCommitted.countDown();
                            }
                        }

                        @Override
                        public void onError(Exception error) {
                            throw new AssertionError("Unexpected import error: " + error);
                        }
                    };

            SourceController.executeGuardedConfigFileImport(
                    workers,
                    fakeMain::execute,
                    guard,
                    new SourceController.LocalImportProvider() {
                        @Override
                        public String displayName() {
                            return "a.json";
                        }

                        @Override
                        public byte[] readBytes() throws Exception {
                            aReading.countDown();
                            releaseA.await(5, TimeUnit.SECONDS);
                            return cfgA;
                        }

                        @Override
                        public String scheme() {
                            return "content";
                        }

                        @Override
                        public String uriString() {
                            return "content://doc/a.json";
                        }
                    },
                    handler);
            check(aReading.await(5, TimeUnit.SECONDS), "R9: slow file provider A started reading");

            SourceController.executeGuardedConfigFileImport(
                    workers,
                    fakeMain::execute,
                    guard,
                    new SourceController.LocalImportProvider() {
                        @Override
                        public String displayName() {
                            return "b.json";
                        }

                        @Override
                        public byte[] readBytes() {
                            return cfgB;
                        }

                        @Override
                        public String scheme() {
                            return "content";
                        }

                        @Override
                        public String uriString() {
                            return "content://doc/b.json";
                        }
                    },
                    handler);
            check(bCommitted.await(5, TimeUnit.SECONDS), "R9: fast file B committed first");

            releaseA.countDown();
            workers.submit(() -> fakeMain.execute(aDone::countDown));
            check(aDone.await(5, TimeUnit.SECONDS), "R9: slow file A finished draining");
            check(
                    "site_b".equals(activeSite.get()) && commitCount.get() == 1,
                    "R9: slow file A discarded after fast B committed (no overwrite)");

            // 2. Activity destroyed while file C is in flight -> discarded
            final CountDownLatch cReading = new CountDownLatch(1);
            final CountDownLatch releaseC = new CountDownLatch(1);
            final CountDownLatch cDone = new CountDownLatch(1);
            SourceController.executeGuardedConfigFileImport(
                    workers,
                    fakeMain::execute,
                    guard,
                    new SourceController.LocalImportProvider() {
                        @Override
                        public String displayName() {
                            return "c.json";
                        }

                        @Override
                        public byte[] readBytes() throws Exception {
                            cReading.countDown();
                            releaseC.await(5, TimeUnit.SECONDS);
                            return cfgA;
                        }

                        @Override
                        public String scheme() {
                            return "content";
                        }

                        @Override
                        public String uriString() {
                            return "content://doc/c.json";
                        }
                    },
                    handler);
            check(cReading.await(5, TimeUnit.SECONDS), "R9: file C started reading before destroy");
            destroyed.set(true);
            releaseC.countDown();
            workers.submit(() -> fakeMain.execute(cDone::countDown));
            check(cDone.await(5, TimeUnit.SECONDS), "R9: file C drained after destroy");
            check(
                    "site_b".equals(activeSite.get()) && commitCount.get() == 1,
                    "R9: file import discarded when Activity destroyed while in flight");

            // 3. Private-space switch while file D is in flight -> discarded
            destroyed.set(false);
            privateMode.set(false);
            final CountDownLatch dReading = new CountDownLatch(1);
            final CountDownLatch releaseD = new CountDownLatch(1);
            final CountDownLatch dDone = new CountDownLatch(1);
            SourceController.executeGuardedConfigFileImport(
                    workers,
                    fakeMain::execute,
                    guard,
                    new SourceController.LocalImportProvider() {
                        @Override
                        public String displayName() {
                            return "d.json";
                        }

                        @Override
                        public byte[] readBytes() throws Exception {
                            dReading.countDown();
                            releaseD.await(5, TimeUnit.SECONDS);
                            return cfgA;
                        }

                        @Override
                        public String scheme() {
                            return "content";
                        }

                        @Override
                        public String uriString() {
                            return "content://doc/d.json";
                        }
                    },
                    handler);
            check(
                    dReading.await(5, TimeUnit.SECONDS),
                    "R9: file D started reading before space switch");
            privateMode.set(true);
            releaseD.countDown();
            workers.submit(() -> fakeMain.execute(dDone::countDown));
            check(dDone.await(5, TimeUnit.SECONDS), "R9: file D drained after space switch");
            check(
                    "site_b".equals(activeSite.get()) && commitCount.get() == 1,
                    "R9: file import discarded after private space switch");
        } finally {
            workers.shutdownNow();
            fakeMain.shutdownNow();
        }

        // Static wiring check: importLocalUri captures beginConfigImport & guards every commit
        String scSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "SourceController.java").toPath()),
                        StandardCharsets.UTF_8);
        int localUriIdx = scSrc.indexOf("static void importLocalUri(");
        String localUriBody = scSrc.substring(localUriIdx, localUriIdx + 6500);
        check(
                localUriBody.contains("final long importSeq = beginConfigImport(a);")
                        && localUriBody.contains("final boolean snapshotPrivate = a.privateMode;")
                        && localUriBody.contains(
                                "canCommitConfigImport(a, snapshotPrivate, importSeq)"),
                "R9 wiring: SourceController.importLocalUri guards every async commit with importSeq + space + lifecycle");
    }

    // -------------------------------------------------------------------------
    // R10: Kernel Fallback Resume Position & AUTO_SWITCH_KERNEL Enforcement
    // -------------------------------------------------------------------------

    private static void testR10KernelFallbackAndProgress(File srcRoot) throws Exception {
        int pos20Min = 20 * 60 * 1000;

        // 1. Fullscreen MPV error at 20:00 with autoSwitch=true -> Media3 at 20:00
        JSONObject mediaMpvOn = new JSONObject();
        PlaybackController.FullscreenFallbackAction d1 =
                PlaybackController.decideFullscreenKernelFallback(
                        true,
                        4001,
                        0,
                        PlaybackController.ENGINE_MPV,
                        mediaMpvOn,
                        false,
                        2,
                        pos20Min,
                        pos20Min,
                        0,
                        true);
        check(
                d1.action == PlaybackController.FullscreenFallbackAction.ACTION_MPV_TO_MEDIA3
                        && d1.resumeAtMs == pos20Min
                        && mediaMpvOn.optBoolean("_mpvFallback"),
                "R10 fullscreen: MPV error at 20:00 with autoSwitch=true switches to Media3 preserving 20:00");

        // 2. Fullscreen decoder error where errored player returns pos=0 but bookmark=20:00:
        //    preserves 20:00 across SW and System fallbacks!
        JSONObject mediaDecOn = new JSONObject();
        mediaDecOn.put("_hwRetry", true);
        PlaybackController.FullscreenFallbackAction dSw =
                PlaybackController.decideFullscreenKernelFallback(
                        false,
                        4001,
                        0,
                        PlaybackController.ENGINE_MEDIA3,
                        mediaDecOn,
                        false,
                        2,
                        0,
                        pos20Min,
                        0,
                        true);
        check(
                dSw.action == PlaybackController.FullscreenFallbackAction.ACTION_SOFTWARE_FALLBACK
                        && dSw.resumeAtMs == pos20Min,
                "R10 fullscreen: SW fallback preserves 20:00 bookmark when errored player returns pos=0");
        PlaybackController.FullscreenFallbackAction dSys =
                PlaybackController.decideFullscreenKernelFallback(
                        false,
                        4001,
                        0,
                        PlaybackController.ENGINE_MEDIA3,
                        mediaDecOn,
                        false,
                        2,
                        0,
                        pos20Min,
                        0,
                        true);
        check(
                dSys.action == PlaybackController.FullscreenFallbackAction.ACTION_SYSTEM_FALLBACK
                        && dSys.resumeAtMs == pos20Min,
                "R10 fullscreen: System fallback preserves 20:00 bookmark when SW fallback fails");

        // 3. Fullscreen with AUTO_SWITCH_KERNEL=false stops in failure state (ZERO kernel switch!)
        JSONObject mediaMpvOff = new JSONObject();
        PlaybackController.FullscreenFallbackAction dMpvOff =
                PlaybackController.decideFullscreenKernelFallback(
                        true,
                        4001,
                        0,
                        PlaybackController.ENGINE_MPV,
                        mediaMpvOff,
                        false,
                        2,
                        pos20Min,
                        pos20Min,
                        0,
                        false);
        check(
                dMpvOff.action == PlaybackController.FullscreenFallbackAction.ACTION_NONE
                        && !mediaMpvOff.optBoolean("_mpvFallback"),
                "R10 fullscreen: AUTO_SWITCH_KERNEL=false prevents MPV->Media3 auto switch");

        JSONObject mediaDecOff = new JSONObject();
        PlaybackController.FullscreenFallbackAction dDecOff =
                PlaybackController.decideFullscreenKernelFallback(
                        false,
                        4001,
                        0,
                        PlaybackController.ENGINE_MEDIA3,
                        mediaDecOff,
                        false,
                        2,
                        pos20Min,
                        pos20Min,
                        0,
                        false);
        check(
                dDecOff.action == PlaybackController.FullscreenFallbackAction.ACTION_NONE
                        && !mediaDecOff.optBoolean("_hwRetry")
                        && !mediaDecOff.optBoolean("_softwareFallback")
                        && !mediaDecOff.optBoolean("_systemFallback"),
                "R10 fullscreen: AUTO_SWITCH_KERNEL=false prevents Media3 SW/System auto switch");

        // 4. Inline advanceFallbackPlan with AUTO_SWITCH_KERNEL=false returns null
        JSONObject inlineOff = new JSONObject();
        check(
                PlaybackController.advanceFallbackPlan(
                                inlineOff, PlaybackController.ENGINE_MPV, false, false)
                        == null,
                "R10 inline: AUTO_SWITCH_KERNEL=false halts fallback ladder in visible failure state");

        // 5. Static wiring checks on MobileInlinePlayer (flush before release in startEpisode +
        //    captureResumePosition before startResolvedStream on fallback)
        String inlineSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MobileInlinePlayer.java").toPath()),
                        StandardCharsets.UTF_8);
        int startEpIdx = inlineSrc.indexOf("void startEpisode(");
        int flushIdx = inlineSrc.indexOf("flushHistoryProgress();", startEpIdx);
        int releaseIdx = inlineSrc.indexOf("releaseInternalPlayer();", startEpIdx);
        check(
                startEpIdx > 0 && flushIdx > startEpIdx && releaseIdx > flushIdx,
                "R10 wiring: MobileInlinePlayer.startEpisode flushes outgoing progress BEFORE releaseInternalPlayer");
        int captureIdx = inlineSrc.indexOf("int resumePos = captureResumePosition();");
        int restartIdx = inlineSrc.indexOf("startResolvedStream();", captureIdx);
        check(
                captureIdx > 0 && restartIdx > captureIdx,
                "R10 wiring: MobileInlinePlayer error fallback captures resume position BEFORE startResolvedStream");
    }

    // -------------------------------------------------------------------------
    // R12: Slow Home Load Guard Ownership & Benign OS Reclaim vs Real Crash
    // -------------------------------------------------------------------------

    private static void testR12LoadingGuardAndCrashAttribution(File srcRoot) throws Exception {
        final MapPrefs prefs = new MapPrefs();
        prefs.edit()
                .putString(Prefs.SELECTED_SITE, "site_a")
                .putString(Prefs.PREFERRED_SITE, "site_a\nA源")
                .apply();
        MobileHomePage.LoadingMarkerStore store =
                key -> prefs.edit().putString(Prefs.LOADING_SITE, key).apply();
        MobileHomePage.LoadingSiteGuard guard = new MobileHomePage.LoadingSiteGuard();

        // 1. Slow load A followed by newer load B: A finishing later MUST NOT clear B's guard!
        long tokA = guard.acquire(store, "site_a");
        check("site_a".equals(prefs.getString(Prefs.LOADING_SITE, "")), "R12: A acquires marker");
        long tokB = guard.acquire(store, "site_b");
        check("site_b".equals(prefs.getString(Prefs.LOADING_SITE, "")), "R12: B supersedes marker");
        boolean releasedByA = guard.releaseIfOwner(store, tokA);
        check(
                !releasedByA && "site_b".equals(prefs.getString(Prefs.LOADING_SITE, "")),
                "R12: slow request A finishing after B starts does NOT clear B's crash guard");
        boolean releasedByB = guard.releaseIfOwner(store, tokB);
        check(
                releasedByB && "".equals(prefs.getString(Prefs.LOADING_SITE, "")),
                "R12: active owner B clears marker cleanly upon completion");

        // 2. Normal backgrounding (onStop) during a slow load clears marker so OS reclaim is NOT
        //    treated as a crash!
        guard.acquire(store, "site_slow");
        guard.clearOnNormalStop(store);
        check(
                "".equals(prefs.getString(Prefs.LOADING_SITE, ""))
                        && !MainActivity.shouldTreatLoadingSiteAsCrash(
                                prefs.getString(Prefs.LOADING_SITE, ""),
                                MainActivity.EXIT_REASON_UNKNOWN),
                "R12: normal onStop clears loading marker; OS reclaim after backgrounding is not a crash");

        // 3. Even if OS reclaims abruptly (API 30+ REASON_LOW_MEMORY=3, REASON_FREEZER=14,
        //    REASON_USER_REQUESTED=10, REASON_USER_STOPPED=11) with LOADING_SITE still set,
        //    startup does NOT treat it as a crash and preserves SELECTED_SITE / PREFERRED_SITE!
        for (int benignReason : new int[] {1, 3, 10, 11, 14, 16}) {
            check(
                    !MainActivity.shouldTreatLoadingSiteAsCrash("site_slow", benignReason),
                    "R12: benign OS exit reason="
                            + benignReason
                            + " does not misclassify slow load as crash");
        }

        // 4. Attributable crash (REASON_SIGNALED=2, REASON_CRASH=4, REASON_CRASH_NATIVE=5,
        //    REASON_ANR=6, or API<30 EXIT_REASON_UNKNOWN=0 when foreground died before onStop)
        //    triggers crash recovery and clears crashed site!
        for (int crashReason : new int[] {0, 2, 4, 5, 6}) {
            check(
                    MainActivity.shouldTreatLoadingSiteAsCrash("site_bad", crashReason),
                    "R12: crash exit reason=" + crashReason + " triggers recovery");
        }
        prefs.edit()
                .putString(Prefs.LOADING_SITE, "site_bad")
                .putString(Prefs.SELECTED_SITE, "site_bad")
                .putString(Prefs.PREFERRED_SITE, "site_bad\n坏源")
                .apply();
        MainActivity.clearRecoveredCrashSite(prefs);
        check(
                "".equals(prefs.getString(Prefs.LOADING_SITE, ""))
                        && "".equals(prefs.getString(Prefs.SELECTED_SITE, ""))
                        && "".equals(prefs.getString(Prefs.PREFERRED_SITE, "")),
                "R12: attributable crash recovery clears crashed loading/selected/preferred site");

        // Static wiring check: MainActivity.onStop clears loading marker on normal stop
        String mainSrc =
                new String(
                        Files.readAllBytes(new File(srcRoot, "MainActivity.java").toPath()),
                        StandardCharsets.UTF_8);
        check(
                mainSrc.contains("MobileHomePage.clearLoadingSiteOnNormalStop(this)")
                        && mainSrc.contains("shouldTreatLoadingSiteAsCrash("),
                "R12 wiring: MainActivity clears loading marker on normal onStop and checks exit reason on boot");
    }

    public static void main(String[] args) throws Exception {
        File mediaDir = new File(args[0]);
        File workDir = new File(args[1]);
        File srcRoot = new File(args[2]);
        testR6IdempotentUnfavorite(srcRoot);
        testR7MultiMapFmp4OfflineHls(mediaDir, workDir);
        testR8BrokenHomeSource(srcRoot);
        testR9SlowFileImportGuards(srcRoot);
        testR10KernelFallbackAndProgress(srcRoot);
        testR12LoadingGuardAndCrashAttribution(srcRoot);
        System.out.println(checks + " R6-R10 & R12 checks passed");
        System.exit(0);
    }
}

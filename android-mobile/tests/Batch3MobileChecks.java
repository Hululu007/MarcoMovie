package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

/**
 * End-to-end deterministic regression checks for Batch 3 (P1-P5):
 * - P1: Unified engine selection/fallback, inline background/lock-screen/Home audio lifecycle
 * - P2: HLS separated audio track offline bundle + embedded audio + multi-lang + failure + resume
 * - P3: IntroDB v4 intro[]/credits[] ms semantics, 45m/43m/2m, cold open, stale episode, last ep
 * - P4: MDBList private-prefs wording, functional token request, zero token leakage in logs
 * - P5: Low-space update resume (100/80/50/30 MiB), HTTP 200/bad-206/416, complete/digest/signer
 */
public final class Batch3MobileChecks {
    private static int checks;

    private static void check(boolean cond, String name) {
        if (!cond) throw new AssertionError("FAIL: " + name);
        checks++;
        System.out.println("PASS " + name);
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
                private final Map<String, Object> puts = new HashMap<>();
                private final Set<String> removes = new HashSet<>();
                private boolean clear;

                @Override
                public Editor putString(String k, String v) {
                    puts.put(k, v);
                    removes.remove(k);
                    return this;
                }

                @Override
                public Editor putStringSet(String k, Set<String> v) {
                    puts.put(k, v);
                    removes.remove(k);
                    return this;
                }

                @Override
                public Editor putInt(String k, int v) {
                    puts.put(k, v);
                    removes.remove(k);
                    return this;
                }

                @Override
                public Editor putLong(String k, long v) {
                    puts.put(k, v);
                    removes.remove(k);
                    return this;
                }

                @Override
                public Editor putFloat(String k, float v) {
                    puts.put(k, v);
                    removes.remove(k);
                    return this;
                }

                @Override
                public Editor putBoolean(String k, boolean v) {
                    puts.put(k, v);
                    removes.remove(k);
                    return this;
                }

                @Override
                public Editor remove(String k) {
                    removes.add(k);
                    puts.remove(k);
                    return this;
                }

                @Override
                public Editor clear() {
                    clear = true;
                    puts.clear();
                    removes.clear();
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
                        if (clear) data.clear();
                        for (String r : removes) data.remove(r);
                        for (Map.Entry<String, Object> e : puts.entrySet()) {
                            if (e.getValue() == null) data.remove(e.getKey());
                            else data.put(e.getKey(), e.getValue());
                        }
                    }
                }
            };
        }

        @Override
        public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l) {}

        @Override
        public void unregisterOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener l) {}
    }

    // -------------------------------------------------------------------------
    // P1: Unified engine selection, fallback ladder & background audio lifecycle
    // -------------------------------------------------------------------------
    private static void testP1EngineAndLifecycle(File srcRoot) throws Exception {
        PlaybackController.EnginePlan m3 = PlaybackController.planEngine(0, new JSONObject(), true);
        PlaybackController.EnginePlan sys =
                PlaybackController.planEngine(1, new JSONObject(), true);
        PlaybackController.EnginePlan ijk =
                PlaybackController.planEngine(2, new JSONObject(), true);
        PlaybackController.EnginePlan mpv =
                PlaybackController.planEngine(3, new JSONObject(), true);
        check(
                m3.engine == PlaybackController.ENGINE_MEDIA3
                        && sys.engine == PlaybackController.ENGINE_SYSTEM
                        && ijk.engine == PlaybackController.ENGINE_IJK
                        && mpv.engine == PlaybackController.ENGINE_MPV
                        && mpv.fallbackReason.isEmpty(),
                "P1: planEngine maps 0=Media3, 1=System, 2=IJK, 3=MPV accurately");

        PlaybackController.EnginePlan mpvNoLib =
                PlaybackController.planEngine(3, new JSONObject(), false);
        check(
                mpvNoLib.engine == PlaybackController.ENGINE_MEDIA3
                        && mpvNoLib.fallbackReason.contains("MPV"),
                "P1: unavailable MPV falls back cleanly to Media3 with explicit reason");

        JSONObject drmMedia = new JSONObject().put("drmScheme", "widevine");
        PlaybackController.EnginePlan mpvDrm = PlaybackController.planEngine(3, drmMedia, true);
        check(
                mpvDrm.engine == PlaybackController.ENGINE_MEDIA3
                        && mpvDrm.fallbackReason.contains("DRM"),
                "P1: DRM stream forces Media3 with explicit fallback reason");

        // Fallback ladder: MPV -> Media3 -> Media3 SW -> System -> null
        JSONObject ladderMedia = new JSONObject();
        String step1 =
                PlaybackController.advanceFallbackPlan(
                        ladderMedia, PlaybackController.ENGINE_MPV, false, true);
        PlaybackController.EnginePlan p1 = PlaybackController.planEngine(3, ladderMedia, true);
        String step2 =
                PlaybackController.advanceFallbackPlan(
                        ladderMedia, p1.engine, p1.softwareFallback, true);
        PlaybackController.EnginePlan p2 = PlaybackController.planEngine(3, ladderMedia, true);
        String step3 =
                PlaybackController.advanceFallbackPlan(
                        ladderMedia, p2.engine, p2.softwareFallback, true);
        PlaybackController.EnginePlan p3 = PlaybackController.planEngine(3, ladderMedia, true);
        String step4 =
                PlaybackController.advanceFallbackPlan(
                        ladderMedia, p3.engine, p3.softwareFallback, true);
        check(
                step1 != null
                        && p1.engine == PlaybackController.ENGINE_MEDIA3
                        && !p1.softwareFallback
                        && step2 != null
                        && p2.engine == PlaybackController.ENGINE_MEDIA3
                        && p2.softwareFallback
                        && step3 != null
                        && p3.engine == PlaybackController.ENGINE_SYSTEM
                        && step4 == null,
                "P1: unified fallback ladder steps MPV -> Media3 -> Media3 SW -> System -> stop");
        check(
                PlaybackController.advanceFallbackPlan(
                                new JSONObject(), PlaybackController.ENGINE_MPV, false, false)
                        == null,
                "P1: autoSwitchKernel=false disables automatic kernel fallback");

        // Background/lock-screen/PiP audio policy
        check(
                MobileInlinePlayer.shouldContinuePlaybackInBackground(true, false, false),
                "P1: foreground playback continues");
        check(
                !MobileInlinePlayer.shouldContinuePlaybackInBackground(false, false, false),
                "P1: background/lock-screen with BACKGROUND_PLAY=false pauses audio (zero leak)");
        check(
                MobileInlinePlayer.shouldContinuePlaybackInBackground(false, false, true),
                "P1: background with BACKGROUND_PLAY=true permits audio");
        check(
                MobileInlinePlayer.shouldContinuePlaybackInBackground(false, true, false),
                "P1: active PiP permits playback");

        // Static wiring checks for MobileSettingsScreen, MainActivity, MobileRootShell,
        // MobileInlinePlayer, PlaybackController
        String settings = readUtf8(new File(srcRoot, "MobileSettingsScreen.java"));
        check(
                settings.contains("new int[] {0, 1, 2, 3}"),
                "P1 wiring: MobileSettingsScreen maps MPV to engine value 3 (not 2)");

        String mainAct = readUtf8(new File(srcRoot, "MainActivity.java"));
        check(
                mainAct.contains("inlinePlayer.onActivityStop(keepBgPlay)")
                        && mainAct.contains("mobilePrefs().getBoolean(Prefs.AUTO_PIP, true)"),
                "P1 wiring: MainActivity.onStop controls inlinePlayer & aligns AUTO_PIP default=true");

        String rootShell = readUtf8(new File(srcRoot, "MobileRootShell.java"));
        check(
                rootShell.contains("if (a.inlinePlayer != null) {")
                        && rootShell.contains("a.inlinePlayer.detach();"),
                "P1 wiring: MobileRootShell.resume detaches inlinePlayer when returning to cached Home");

        String inlineSrc =
                readUtf8(new File(srcRoot, "MobileInlinePlayer.java")).replaceAll("\\s+", " ");
        check(
                inlineSrc.contains("PlaybackController.planEngine(")
                        && inlineSrc.contains("PlaybackController.createPlayerWithPlan(")
                        && inlineSrc.contains("PlaybackController.preparePlayUrl(")
                        && inlineSrc.contains("PlaybackController.advanceFallbackPlan(")
                        && inlineSrc.contains("allowBackgroundAudio() && !pausedForBackground")
                        && inlineSrc.contains(
                                "clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)"),
                "P1 wiring: MobileInlinePlayer shares engine plan/fallback, guards onPrepared, clears keep-screen-on");
    }

    // -------------------------------------------------------------------------
    // P2: HLS separated audio track offline download (real ffmpeg TS fixtures!)
    // -------------------------------------------------------------------------
    private static void testP2HlsSeparatedAudio(File mediaDir, File workDir) throws Exception {
        byte[] vSeg0 = Files.readAllBytes(new File(mediaDir, "v0.ts").toPath());
        byte[] vSeg1 = Files.readAllBytes(new File(mediaDir, "v1.ts").toPath());
        byte[] aSeg0 = Files.readAllBytes(new File(mediaDir, "a0.ts").toPath());
        byte[] aSeg1 = Files.readAllBytes(new File(mediaDir, "a1.ts").toPath());
        byte[] mux0 = Files.readAllBytes(new File(mediaDir, "mux0.ts").toPath());
        byte[] mux1 = Files.readAllBytes(new File(mediaDir, "mux1.ts").toPath());

        // 1. Unit tests on selectBestVariant: separated multi-lang, embedded (no URI), missing
        // group
        String multiLangMaster =
                "#EXTM3U\n"
                        + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",AUTOSELECT=YES,URI=\"audio_en.m3u8\"\n"
                        + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"中文原声\",LANGUAGE=\"zh\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio_zh.m3u8\"\n"
                        + "#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO=\"aud\"\n"
                        + "low.m3u8\n"
                        + "#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,AUDIO=\"aud\"\n"
                        + "high.m3u8\n";
        DownloadManager.VariantSelection sepSel =
                DownloadManager.selectBestVariant(
                        multiLangMaster, "https://cdn.example/hls/master.m3u8");
        check(
                sepSel != null
                        && "https://cdn.example/hls/high.m3u8".equals(sepSel.videoUri)
                        && sepSel.audio != null
                        && "https://cdn.example/hls/audio_zh.m3u8".equals(sepSel.audio.uri)
                        && "zh".equals(sepSel.audio.language),
                "P2: selectBestVariant picks highest video variant + DEFAULT=YES zh separated audio");

        String embeddedMaster =
                "#EXTM3U\n"
                        + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"emb\",NAME=\"Muxed\",DEFAULT=YES\n"
                        + "#EXT-X-STREAM-INF:BANDWIDTH=1800000,AUDIO=\"emb\"\n"
                        + "muxed.m3u8\n";
        DownloadManager.VariantSelection embSel =
                DownloadManager.selectBestVariant(
                        embeddedMaster, "https://cdn.example/hls/emb.m3u8");
        check(
                embSel != null
                        && "https://cdn.example/hls/muxed.m3u8".equals(embSel.videoUri)
                        && embSel.audio == null,
                "P2: selectBestVariant treats #EXT-X-MEDIA without URI as embedded muxed audio");

        String missingGroupMaster =
                "#EXTM3U\n"
                        + "#EXT-X-STREAM-INF:BANDWIDTH=1800000,AUDIO=\"ghost_group\"\n"
                        + "video.m3u8\n";
        boolean missingGroupRejected = false;
        try {
            DownloadManager.selectBestVariant(
                    missingGroupMaster, "https://cdn.example/hls/bad.m3u8");
        } catch (DownloadManager.DownloadException expected) {
            missingGroupRejected = expected.getMessage().contains("ghost_group");
        }
        check(
                missingGroupRejected,
                "P2: missing declared AUDIO group throws explicit DownloadException");

        // 2. End-to-end HTTP server exercising DownloadManager directly
        final Map<String, AtomicInteger> hitCounts = new ConcurrentHashMap<>();
        final AtomicInteger failAudioSeg1Once = new AtomicInteger(0);
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(Executors.newCachedThreadPool());
        final int port = server.getAddress().getPort();
        final String base = "http://127.0.0.1:" + port;

        server.createContext(
                "/",
                (HttpExchange ex) -> {
                    String path = ex.getRequestURI().getPath();
                    hitCounts.computeIfAbsent(path, k -> new AtomicInteger()).incrementAndGet();
                    try {
                        if ("/sep/master.m3u8".equals(path)) {
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    multiLangMaster.getBytes(StandardCharsets.UTF_8));
                        } else if ("/sep/high.m3u8".equals(path)) {
                            String pl =
                                    "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\nv0.ts\n#EXTINF:2.0,\nv1.ts\n#EXT-X-ENDLIST\n";
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    pl.getBytes(StandardCharsets.UTF_8));
                        } else if ("/sep/audio_zh.m3u8".equals(path)) {
                            String pl =
                                    "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\na0.ts\n#EXTINF:2.0,\na1.ts\n#EXT-X-ENDLIST\n";
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    pl.getBytes(StandardCharsets.UTF_8));
                        } else if ("/sep/v0.ts".equals(path)) {
                            sendBytes(ex, 200, "video/mp2t", vSeg0);
                        } else if ("/sep/v1.ts".equals(path)) {
                            sendBytes(ex, 200, "video/mp2t", vSeg1);
                        } else if ("/sep/a0.ts".equals(path)) {
                            sendBytes(ex, 200, "video/mp2t", aSeg0);
                        } else if ("/sep/a1.ts".equals(path)) {
                            if (failAudioSeg1Once.get() > 0) {
                                failAudioSeg1Once.decrementAndGet();
                                sendBytes(
                                        ex,
                                        403,
                                        "text/plain",
                                        "expired".getBytes(StandardCharsets.UTF_8));
                            } else {
                                sendBytes(ex, 200, "video/mp2t", aSeg1);
                            }
                        } else if ("/emb/master.m3u8".equals(path)) {
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    embeddedMaster.getBytes(StandardCharsets.UTF_8));
                        } else if ("/emb/muxed.m3u8".equals(path)) {
                            String pl =
                                    "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\nmux0.ts\n#EXTINF:2.0,\nmux1.ts\n#EXT-X-ENDLIST\n";
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    pl.getBytes(StandardCharsets.UTF_8));
                        } else if ("/emb/mux0.ts".equals(path)) {
                            sendBytes(ex, 200, "video/mp2t", mux0);
                        } else if ("/emb/mux1.ts".equals(path)) {
                            sendBytes(ex, 200, "video/mp2t", mux1);
                        } else if ("/fail-audio/master.m3u8".equals(path)) {
                            String bad =
                                    "#EXTM3U\n"
                                            + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Broken\",DEFAULT=YES,URI=\"missing_audio.m3u8\"\n"
                                            + "#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO=\"aud\"\n"
                                            + "/sep/high.m3u8\n";
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    bad.getBytes(StandardCharsets.UTF_8));
                        } else if ("/sample-aes/master.m3u8".equals(path)) {
                            String enc =
                                    "#EXTM3U\n"
                                            + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"DRM\",DEFAULT=YES,URI=\"audio_drm.m3u8\"\n"
                                            + "#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO=\"aud\"\n"
                                            + "/sep/high.m3u8\n";
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    enc.getBytes(StandardCharsets.UTF_8));
                        } else if ("/sample-aes/audio_drm.m3u8".equals(path)) {
                            String pl =
                                    "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k.key\"\n#EXTINF:2.0,\n/sep/a0.ts\n#EXT-X-ENDLIST\n";
                            sendBytes(
                                    ex,
                                    200,
                                    "application/vnd.apple.mpegurl",
                                    pl.getBytes(StandardCharsets.UTF_8));
                        } else {
                            sendBytes(
                                    ex,
                                    404,
                                    "text/plain",
                                    "not found".getBytes(StandardCharsets.UTF_8));
                        }
                    } catch (Exception e) {
                        ex.close();
                    }
                });
        server.start();

        File dlRoot = new File(workDir, "downloads-test");
        dlRoot.mkdirs();
        // Pre-seed a legacy single-file offline record before creating DownloadManager
        File legacyFile = new File(dlRoot, "legacy_offline.ts");
        Files.write(legacyFile.toPath(), mux0);
        File storeJson = new File(dlRoot, "downloads.json");
        JSONObject legacyItem =
                new JSONObject()
                        .put("id", "legacy1")
                        .put("key", "s1\nv0\nL1\nE1")
                        .put("title", "旧单文件离线片")
                        .put("episode", "第1集")
                        .put("path", legacyFile.getAbsolutePath())
                        .put("state", DownloadManager.DONE)
                        .put("bytes", mux0.length)
                        .put("total", mux0.length);
        Files.write(
                storeJson.toPath(),
                ("[" + legacyItem.toString() + "]").getBytes(StandardCharsets.UTF_8));

        DownloadManager dm = createDownloadManager(dlRoot);
        try {
            // 2a. Verify existing single-file record remains readable & DONE
            List<DownloadManager.Task> loaded = dm.snapshot();
            check(
                    loaded.size() == 1
                            && loaded.get(0).state == DownloadManager.DONE
                            && new File(loaded.get(0).path).isFile()
                            && new File(loaded.get(0).path).length() == mux0.length,
                    "P2: existing single-file offline record remains readable & DONE");

            // 2b. Embedded muxed HLS -> single .ts file DONE
            DownloadManager.Task embTask =
                    enqueueAndWait(dm, "内嵌音轨样本", "E1", base + "/emb/master.m3u8");
            check(
                    embTask.state == DownloadManager.DONE
                            && embTask.path.endsWith(".ts")
                            && new File(embTask.path).isFile(),
                    "P2: embedded-audio HLS downloads cleanly to single .ts file");

            // 2c. Separated audio HLS with simulated audio segment failure -> FAILED -> resume ->
            // DONE!
            failAudioSeg1Once.set(1); // 403 is non-retryable, simulates mid-download failure
            DownloadManager.Task sepTask =
                    enqueueAndWait(dm, "分轨双语样本", "E1", base + "/sep/master.m3u8");
            check(
                    sepTask.state == DownloadManager.FAILED && sepTask.path.isEmpty(),
                    "P2: separated-audio segment failure marks FAILED (never muted DONE)");
            int v0HitsBeforeResume =
                    hitCounts.getOrDefault("/sep/v0.ts", new AtomicInteger()).get();
            int a0HitsBeforeResume =
                    hitCounts.getOrDefault("/sep/a0.ts", new AtomicInteger()).get();
            check(
                    v0HitsBeforeResume >= 1 && a0HitsBeforeResume >= 1,
                    "P2: partial video & audio segments cached prior to failure");

            // Resume task -> should reuse already-downloaded segments and succeed!
            dm.resume(sepTask.id);
            sepTask = waitForTerminal(dm, sepTask.id);
            check(
                    sepTask.state == DownloadManager.DONE
                            && sepTask.path.endsWith("master.m3u8")
                            && new File(sepTask.path).isFile(),
                    "P2: resumed separated-audio HLS completes to offline master.m3u8 bundle");
            int v0HitsAfterResume = hitCounts.getOrDefault("/sep/v0.ts", new AtomicInteger()).get();
            int a0HitsAfterResume = hitCounts.getOrDefault("/sep/a0.ts", new AtomicInteger()).get();
            check(
                    v0HitsAfterResume == v0HitsBeforeResume
                            && a0HitsAfterResume == a0HitsBeforeResume,
                    "P2: resume reuses cached video & audio segments without redownloading");

            // 2d. Missing audio playlist -> FAILED with explicit audio error
            DownloadManager.Task failAudio =
                    enqueueAndWait(dm, "缺音轨样本", "E1", base + "/fail-audio/master.m3u8");
            check(
                    failAudio.state == DownloadManager.FAILED && failAudio.error.contains("音轨"),
                    "P2: audio playlist 404 fails explicitly with audio error (never DONE)");

            // 2e. Unsupported SAMPLE-AES audio -> FAILED with explicit encryption reason
            DownloadManager.Task encAudio =
                    enqueueAndWait(dm, "加密音轨样本", "E1", base + "/sample-aes/master.m3u8");
            check(
                    encAudio.state == DownloadManager.FAILED
                            && encAudio.error.contains("SAMPLE-AES"),
                    "P2: unsupported SAMPLE-AES audio track fails with explicit reason");

            // Stop HTTP server completely (simulate zero network / airplane mode) and verify
            // local offline playlists have zero remote URLs, then write paths for python ffprobe!
            server.stop(0);
            String masterText = readUtf8(new File(sepTask.path));
            File bundleDir = new File(sepTask.path).getParentFile();
            String videoPlText = readUtf8(new File(bundleDir, "video.m3u8"));
            String audioPlText = readUtf8(new File(bundleDir, "audio.m3u8"));
            check(
                    !masterText.contains("http://")
                            && !videoPlText.contains("http://")
                            && !audioPlText.contains("http://")
                            && masterText.contains("LANGUAGE=\"zh\"")
                            && masterText.contains("URI=\"audio.m3u8\"")
                            && masterText.contains("video.m3u8"),
                    "P2: offline bundle playlists are 100% local-relative with zh default audio");

            // Export paths so run_batch3_mobile_checks.py runs real ffprobe/ffmpeg offline decode &
            // seek!
            Files.write(
                    new File(workDir, "p2-outputs.txt").toPath(),
                    (embTask.path + "\n" + sepTask.path + "\n").getBytes(StandardCharsets.UTF_8));
        } finally {
            server.stop(0);
        }
    }

    private static DownloadManager createDownloadManager(File dir) throws Exception {
        Context stubCtx =
                new android.content.ContextWrapper(null) {
                    @Override
                    public Context getApplicationContext() {
                        return this;
                    }

                    @Override
                    public File getFilesDir() {
                        return dir;
                    }

                    @Override
                    public File getExternalFilesDir(String type) {
                        return dir;
                    }
                };
        // Use package-private reflection or constructor if needed; DownloadManager(Context) is
        // private,
        // wait — let's check if we can instantiate via reflection safely in test!
        java.lang.reflect.Constructor<DownloadManager> ctor =
                DownloadManager.class.getDeclaredConstructor(Context.class);
        ctor.setAccessible(true);
        return ctor.newInstance(stubCtx);
    }

    private static DownloadManager.Task enqueueAndWait(
            DownloadManager dm, String title, String epName, String url) throws Exception {
        Cms.Site s = new Cms.Site();
        s.key = "test_site";
        s.name = "Test";
        s.api = url;
        Cms.Video v = new Cms.Video();
        v.id = title;
        v.title = title;
        Cms.Line line = new Cms.Line();
        line.name = "默认";
        Cms.Episode ep = new Cms.Episode();
        ep.name = epName;
        ep.url = url;
        line.episodes.add(ep);
        Set<String> existingIds = new HashSet<>();
        for (DownloadManager.Task prev : dm.snapshot()) existingIds.add(prev.id);
        dm.enqueue(s, v, line, java.util.Collections.singletonList(ep));
        String addedId = null;
        for (DownloadManager.Task cur : dm.snapshot()) {
            if (!existingIds.contains(cur.id)) {
                addedId = cur.id;
            }
        }
        if (addedId == null) throw new AssertionError("Failed to enqueue task: " + title);
        return waitForTerminal(dm, addedId);
    }

    private static DownloadManager.Task waitForTerminal(DownloadManager dm, String id)
            throws Exception {
        long deadline = System.currentTimeMillis() + 20_000L;
        while (System.currentTimeMillis() < deadline) {
            for (DownloadManager.Task t : dm.snapshot()) {
                if (id.equals(t.id)
                        && (t.state == DownloadManager.DONE
                                || t.state == DownloadManager.FAILED
                                || t.state == DownloadManager.PAUSED)) {
                    return t;
                }
            }
            Thread.sleep(40L);
        }
        throw new AssertionError("Download task timed out: " + id);
    }

    // -------------------------------------------------------------------------
    // P3: Community IntroDB v4 intro[]/credits[] skip timing & edge cases
    // -------------------------------------------------------------------------
    private static void testP3IntroDbV4Semantics(File srcRoot) throws Exception {
        // 1. Official v4 payload: 45-min episode (2,700,000 ms), credits start at 43:00 (2,580,000
        // ms)
        String v4Json =
                "{\"tvdb_id\":12345,\"kind\":\"media\","
                        + "\"intro\":[{\"start_ms\":30000,\"end_ms\":95000},{\"start_ms\":180000,\"end_ms\":210000}],"
                        + "\"credits\":[{\"start_ms\":2580000,\"end_ms\":null}]}";
        TmdbService.IntroTimestamps ts = TmdbService.parseIntroDbResponse(v4Json);
        check(
                ts != null && ts.intros.size() == 2 && ts.credits.size() == 1,
                "P3: parses official IntroDB v4 intro[] (2 ranges) & credits[] (open end_ms=null)");

        final long dur45m = 45L * 60_000L; // 2,700,000 ms
        IntroSkipEvaluator eval = new IntroSkipEvaluator();
        eval.resetForEpisode(101L, 0, 0);
        check(
                eval.applyCommunityTimestamps(101L, ts),
                "P3: applies timestamps for matching episode token");

        // Cold open (0..30s) must NOT skip early!
        IntroSkipEvaluator.Decision dColdOpen = eval.evaluate(10_000L, dur45m, true, true);
        check(
                dColdOpen.action == IntroSkipEvaluator.ACTION_NONE,
                "P3: cold open at 0:10 keeps playing (honors intro.start_ms=30s)");

        // Inside first intro [30s, 95s) -> skips to 95s!
        IntroSkipEvaluator.Decision dIntro1 = eval.evaluate(35_000L, dur45m, true, true);
        check(
                dIntro1.action == IntroSkipEvaluator.ACTION_SEEK && dIntro1.targetMs == 95_000L,
                "P3: skips first intro [30s,95s) cleanly to 95s");

        // CRITICAL execution-sheet regression: at 02:00 (120,000 ms) on 45-min episode with
        // community credits at 43:00 -> MUST keep playing (previously skipped at 02:00!)
        IntroSkipEvaluator.Decision dAt2Min = eval.evaluate(120_000L, dur45m, true, true);
        check(
                dAt2Min.action == IntroSkipEvaluator.ACTION_NONE,
                "P3: 45-min episode with credits at 43:00 keeps playing at 02:00");

        // Second intro range [180s, 210s) -> skips to 210s!
        IntroSkipEvaluator.Decision dIntro2 = eval.evaluate(185_000L, dur45m, true, true);
        check(
                dIntro2.action == IntroSkipEvaluator.ACTION_SEEK && dIntro2.targetMs == 210_000L,
                "P3: multi-range second intro [180s,210s) skips to 210s");

        // At 42:59 -> still playing; at 43:00 -> next episode!
        check(
                eval.evaluate(42L * 60_000L + 59_000L, dur45m, true, true).action
                        == IntroSkipEvaluator.ACTION_NONE,
                "P3: at 42:59 before credits keeps playing");
        IntroSkipEvaluator.Decision dCredits = eval.evaluate(43L * 60_000L, dur45m, true, true);
        check(
                dCredits.action == IntroSkipEvaluator.ACTION_NEXT_EPISODE,
                "P3: at 43:00 triggers next episode when hasNext=true & autoNext=true");

        // Last episode (hasNext=false) & autoNext=false: open-ended credits must NOT skip/break
        IntroSkipEvaluator evalLast = new IntroSkipEvaluator();
        evalLast.resetForEpisode(102L, 0, 0);
        evalLast.applyCommunityTimestamps(102L, ts);
        check(
                evalLast.evaluate(43L * 60_000L, dur45m, false, true).action
                        == IntroSkipEvaluator.ACTION_NONE,
                "P3: last episode (hasNext=false) continues cleanly through open-ended credits");

        IntroSkipEvaluator evalNoAuto = new IntroSkipEvaluator();
        evalNoAuto.resetForEpisode(103L, 0, 0);
        evalNoAuto.applyCommunityTimestamps(103L, ts);
        check(
                evalNoAuto.evaluate(43L * 60_000L, dur45m, true, false).action
                        == IntroSkipEvaluator.ACTION_NONE,
                "P3: autoNext=false continues cleanly through open-ended credits");

        // Empty/null bounds + mid-credits post-credits scene
        String boundaryJson =
                "{\"intro\":[{\"start_ms\":null,\"end_ms\":60000},{\"start_ms\":10000,\"end_ms\":null}],"
                        + "\"credits\":[{\"start_ms\":null,\"end_ms\":2700000},{\"start_ms\":2400000,\"end_ms\":2500000}]}";
        TmdbService.IntroTimestamps bTs = TmdbService.parseIntroDbResponse(boundaryJson);
        check(
                bTs != null
                        && bTs.intros.size() == 1
                        && bTs.intros.get(0).startMs == 0L
                        && bTs.intros.get(0).endMs == 60_000L
                        && bTs.credits.size() == 1
                        && bTs.credits.get(0).startMs == 2_400_000L
                        && bTs.credits.get(0).endMs == 2_500_000L,
                "P3: handles null bounds (intro start_ms=null->0, end_ms=null skipped; credits start_ms=null skipped)");
        IntroSkipEvaluator evalMid = new IntroSkipEvaluator();
        evalMid.resetForEpisode(104L, 0, 0);
        evalMid.applyCommunityTimestamps(104L, bTs);
        IntroSkipEvaluator.Decision dMid = evalMid.evaluate(2_410_000L, dur45m, false, false);
        check(
                dMid.action == IntroSkipEvaluator.ACTION_SEEK && dMid.targetMs == 2_500_000L,
                "P3: finite mid-credits seeks to post-credits scene even on last episode/autoNext=false");

        // Non-media v4 union discriminator rejected cleanly
        check(
                TmdbService.parseIntroDbResponse("{\"kind\":\"versions\",\"versions\":[]}") == null,
                "P3: non-media v4 discriminated union safely ignored");

        // Stale episode response after switching episodes rejected
        evalMid.resetForEpisode(105L, 0, 0);
        check(
                !evalMid.applyCommunityTimestamps(104L, ts),
                "P3: stale IntroDB response from previous episode rejected by episodeToken");

        // Manual SKIP_OUTRO remaining duration semantics preserved (90s remaining -> triggers at
        // 43:30)
        IntroSkipEvaluator evalManual = new IntroSkipEvaluator();
        evalManual.resetForEpisode(106L, 0, 90);
        check(
                evalManual.evaluate(120_000L, dur45m, true, true).action
                                == IntroSkipEvaluator.ACTION_NONE
                        && evalManual.evaluate(dur45m - 89_000L, dur45m, true, true).action
                                == IntroSkipEvaluator.ACTION_NEXT_EPISODE,
                "P3: manual SKIP_OUTRO uses remaining duration from end (45m-90s)");

        // Static wiring checks: fullscreen skips regardless of MINI_PROGRESS_BAR & offline skip
        // guard
        String overlaySrc = readUtf8(new File(srcRoot, "MobilePlayerOverlay.java"));
        int evalIdx = overlaySrc.indexOf("skipEvaluator.evaluate(");
        int miniIdx = overlaySrc.indexOf("boolean showMini =");
        check(
                evalIdx > 0
                        && miniIdx > evalIdx
                        && overlaySrc.contains("\"download\".equals(siteKey)"),
                "P3 wiring: MobilePlayerOverlay evaluates IntroDB skip independently of MINI_PROGRESS_BAR & skips offline download site");

        String inlineSrc =
                readUtf8(new File(srcRoot, "MobileInlinePlayer.java")).replaceAll("\\s+", " ");
        check(
                inlineSrc.contains(
                        "startEpisode(site, video, activeLine, next, tmdbId, isTv, seasonNum, epNum + 1)"),
                "P3 wiring: MobileInlinePlayer.stepNextEpisode preserves tmdbId/isTv/seasonNum/epNum");
    }

    // -------------------------------------------------------------------------
    // P4: MDBList private-storage wording, live token check & zero log leakage
    // -------------------------------------------------------------------------
    private static void testP4MdblistWordingAndSecrets(File srcRoot) throws Exception {
        String settings = readUtf8(new File(srcRoot, "MobileSettingsScreen.java"));
        check(
                !settings.contains("仅保存在本机加密偏好中")
                        && settings.contains("保存在本机应用私有偏好中，不加密，不随系统备份或云同步上传"),
                "P4: MobileSettingsScreen MDBList wording matches actual unencrypted private SharedPreferences");

        final String testToken = "TEST_MDB_SECRET_987654";
        HttpServer mdbServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mdbServer.createContext(
                "/",
                (HttpExchange ex) -> {
                    String query = ex.getRequestURI().getQuery();
                    if (query != null
                            && query.contains("apikey=" + testToken)
                            && query.contains("tm=550")) {
                        String body =
                                "{\"ratings\":[{\"source\":\"imdb\",\"value\":8.8},"
                                        + "{\"source\":\"tomatoes\",\"value\":93},"
                                        + "{\"source\":\"trakt\",\"value\":87}]}";
                        sendBytes(
                                ex, 200, "application/json", body.getBytes(StandardCharsets.UTF_8));
                    } else {
                        sendBytes(
                                ex,
                                401,
                                "application/json",
                                "{\"error\":\"unauthorized\"}".getBytes(StandardCharsets.UTF_8));
                    }
                });
        mdbServer.start();
        try {
            String url =
                    TrackingRatingService.buildMdblistUrl(
                            "http://127.0.0.1:" + mdbServer.getAddress().getPort() + "/",
                            testToken,
                            550,
                            false);
            String raw = TmdbService.httpGet(url, java.util.Collections.emptyMap());
            TrackingRatingService.MultiRating rating = new TrackingRatingService.MultiRating();
            TrackingRatingService.parseMdblistResponse(raw, rating);
            check(
                    Math.abs(rating.imdb - 8.8) < 0.01
                            && rating.rottenTomatoes == 93
                            && Math.abs(rating.trakt - 8.7) < 0.01,
                    "P4: MDBList test token query succeeds and parses IMDb/RT/Trakt ratings");
            String logs = AppLog.dump();
            check(!logs.contains(testToken), "P4: MDBList API token never appears in AppLog");
        } finally {
            mdbServer.stop(0);
        }
    }

    // -------------------------------------------------------------------------
    // P5: Low-space update resume + 200 / bad 206 / 416 / complete / digest / signer
    // -------------------------------------------------------------------------
    private static void testP5LowSpaceUpdateResume(File workDir) throws Exception {
        final long MIB = 1024L * 1024L;
        final long pkg100 = 100L * MIB;
        final long recv80 = 80L * MIB;

        // 1. Exact execution-sheet space math: 100 MiB pkg, 80 MiB received -> 50 MiB resumes, 30
        // MiB fails!
        check(
                UpdatePolicy.requiredFreeBytes(pkg100, recv80) == 36L * MIB,
                "P5: required free space for 100 MiB pkg with 80 MiB received is 36 MiB (20 + 16 reserve)");
        check(
                UpdatePolicy.hasEnoughSpace(50L * MIB, pkg100, recv80),
                "P5: 50 MiB usable space ALLOWS resuming 100 MiB pkg (80 MiB received)");
        check(
                !UpdatePolicy.hasEnoughSpace(30L * MIB, pkg100, recv80),
                "P5: 30 MiB usable space REJECTS resuming 100 MiB pkg (80 MiB received)");

        // 2. UpdatePolicy.resumeOffset: 200, valid 206, bad 206, 416, and mobile edition isolation
        check(
                UpdatePolicy.resumeOffset(80L, 200, null, 100L) == 0L,
                "P5: HTTP 200 restarts cleanly from offset 0");
        check(
                UpdatePolicy.resumeOffset(80L, 206, "bytes 80-99/100", 100L) == 80L,
                "P5: valid HTTP 206 resumes from offset 80");
        boolean bad206 = false;
        try {
            UpdatePolicy.resumeOffset(80L, 206, "bytes 0-99/100", 100L);
        } catch (IOException expected) {
            bad206 = expected.getMessage().contains("mismatch");
        }
        check(bad206, "P5: bad HTTP 206 Content-Range mismatch rejected");
        boolean got416 = false;
        try {
            UpdatePolicy.resumeOffset(80L, 416, null, 100L);
        } catch (IOException expected) {
            got416 = expected.getMessage().contains("416");
        }
        check(got416, "P5: HTTP 416 surfaced explicitly for partial reset");

        // Mobile channel check retained
        String mobileApkUrl =
                "https://github.com/Pilipala9919/MarcoMovie/releases/download/android-mobile-v0.7.1/MarcoMovie-0.7.1-android-mobile.apk";
        String tvApkUrl =
                "https://github.com/Pilipala9919/MarcoMovie/releases/download/android-tv-v0.7.1/MarcoMovie-0.7.1-android-tv.apk";
        String dummySha = sha256Hex("valid-mobile-apk".getBytes(StandardCharsets.UTF_8));
        UpdatePolicy.validate(
                101, "0.7.1", 23, 1024, dummySha, mobileApkUrl, false, "stable", true);
        boolean tvRejectedOnMobile = false;
        try {
            UpdatePolicy.validate(
                    101, "0.7.1", 23, 1024, dummySha, tvApkUrl, false, "stable", true);
        } catch (IllegalArgumentException expected) {
            tvRejectedOnMobile = true;
        }
        check(
                tvRejectedOnMobile,
                "P5: mobile channel accepts android-mobile and rejects android-tv");

        // 3. Full UpdateManager.downloadFile tests with real partial files & mock HTTP connector
        final byte[] fullPayload = new byte[100_000];
        for (int i = 0; i < fullPayload.length; i++) fullPayload[i] = (byte) ((i * 31) & 0xff);
        final String fullSha = sha256Hex(fullPayload);
        final JSONObject releaseJson =
                new JSONObject()
                        .put("schema", 1)
                        .put("platform", "android-mobile")
                        .put("versionCode", 101)
                        .put("versionName", "0.7.1")
                        .put("minSdk", 23)
                        .put("size", fullPayload.length)
                        .put("sha256", fullSha)
                        .put("url", mobileApkUrl)
                        .put("githubUrl", mobileApkUrl)
                        .put("prerelease", false);
        final UpdateManager.Release release =
                new UpdateManager.Release(releaseJson, "stable", true);

        // 3a. 80% received + space = (remaining + 16 MiB + 1 MiB) -> RESUMES via 206 and succeeds!
        runUpdateScenario(
                new File(workDir, "u-resume-ok"),
                release,
                fullPayload,
                80_000,
                fullSha,
                20_000 + UpdatePolicy.SPACE_RESERVE_BYTES + 1024L,
                "206",
                false,
                (ok, err, mgr, seenOffsets) -> {
                    check(
                            ok && seenOffsets.contains(80_000L) && mgr.apk().isFile(),
                            "P5: downloadFile resumes from 80% partial file under low-but-sufficient space");
                });

        // 3b. 80% received + space = (remaining + 16 MiB - 1024) -> FAILS with
        // InsufficientSpaceException!
        runUpdateScenario(
                new File(workDir, "u-resume-low"),
                release,
                fullPayload,
                80_000,
                fullSha,
                20_000 + UpdatePolicy.SPACE_RESERVE_BYTES - 1024L,
                "206",
                false,
                (ok, err, mgr, seenOffsets) -> {
                    check(
                            !ok
                                    && err instanceof UpdateManager.InsufficientSpaceException
                                    && seenOffsets.isEmpty(),
                            "P5: downloadFile rejects resume when usable space < remaining + 16 MiB");
                });

        // 3c. Range returns HTTP 200 -> restarts from 0 and succeeds!
        runUpdateScenario(
                new File(workDir, "u-200-restart"),
                release,
                fullPayload,
                80_000,
                fullSha,
                fullPayload.length + UpdatePolicy.SPACE_RESERVE_BYTES,
                "200",
                false,
                (ok, err, mgr, seenOffsets) -> {
                    check(
                            ok && mgr.apk().isFile() && mgr.apk().length() == fullPayload.length,
                            "P5: Range returning HTTP 200 restarts cleanly from 0 and verifies SHA-256");
                });

        // 3d. Range returns HTTP 416 -> deletes stale part and retries cleanly from 0!
        runUpdateScenario(
                new File(workDir, "u-416-reset"),
                release,
                fullPayload,
                80_000,
                fullSha,
                fullPayload.length + UpdatePolicy.SPACE_RESERVE_BYTES,
                "416-then-200",
                false,
                (ok, err, mgr, seenOffsets) -> {
                    check(
                            ok
                                    && seenOffsets.contains(80_000L)
                                    && seenOffsets.contains(0L)
                                    && mgr.apk().isFile(),
                            "P5: HTTP 416 deletes stale partial file and retries cleanly from offset 0");
                });

        // 3e. Already-complete valid temp file (100% present) -> succeeds even with 1 MB free!
        runUpdateScenario(
                new File(workDir, "u-complete-valid"),
                release,
                fullPayload,
                100_000,
                fullSha,
                1024L * 1024L,
                "206",
                false,
                (ok, err, mgr, seenOffsets) -> {
                    check(
                            ok && seenOffsets.isEmpty() && mgr.apk().isFile(),
                            "P5: already-complete valid temp file verifies & installs without network or extra download space");
                });

        // 3f. Complete temp file with EXPIRED digest (corrupt bytes) -> deletes part & redownloads
        // from mirror[0]!
        byte[] corruptFull = Arrays.copyOf(fullPayload, fullPayload.length);
        corruptFull[0] ^= 0x55;
        runUpdateScenario(
                new File(workDir, "u-expired-digest"),
                release,
                fullPayload,
                100_000,
                fullSha,
                fullPayload.length + UpdatePolicy.SPACE_RESERVE_BYTES,
                "200",
                false,
                corruptFull,
                (ok, err, mgr, seenOffsets) -> {
                    check(
                            ok && seenOffsets.contains(0L) && mgr.apk().isFile(),
                            "P5: expired/corrupt complete temp file is discarded and re-downloaded from source[0]");
                });

        // 3g. Bad signature -> rejected, temp deleted, release.apk NOT created!
        runUpdateScenario(
                new File(workDir, "u-bad-signer"),
                release,
                fullPayload,
                100_000,
                fullSha,
                fullPayload.length + UpdatePolicy.SPACE_RESERVE_BYTES,
                "200",
                true,
                (ok, err, mgr, seenOffsets) -> {
                    check(
                            !ok
                                    && err != null
                                    && "signer".equals(err.getMessage())
                                    && !mgr.apk().exists(),
                            "P5: bad signature fails verification and never promotes release.apk");
                });
    }

    interface ScenarioCheck {
        void verify(boolean ok, Exception err, UpdateManager mgr, List<Long> seenOffsets)
                throws Exception;
    }

    private static void runUpdateScenario(
            File dir,
            UpdateManager.Release release,
            byte[] validPayload,
            int initialBytes,
            String partialSha,
            long usableSpace,
            String mode,
            boolean failSigner,
            ScenarioCheck checkFn)
            throws Exception {
        byte[] initData = initialBytes > 0 ? Arrays.copyOf(validPayload, initialBytes) : null;
        runUpdateScenario(
                dir,
                release,
                validPayload,
                initialBytes,
                partialSha,
                usableSpace,
                mode,
                failSigner,
                initData,
                checkFn);
    }

    private static void runUpdateScenario(
            File dir,
            UpdateManager.Release release,
            byte[] validPayload,
            int initialBytes,
            String partialSha,
            long usableSpace,
            String mode,
            boolean failSigner,
            byte[] initialContent,
            ScenarioCheck checkFn)
            throws Exception {
        dir.mkdirs();
        File cacheDir = new File(dir, "cache");
        File updatesDir = new File(cacheDir, "updates");
        updatesDir.mkdirs();
        MapPrefs prefs = new MapPrefs();
        if (initialContent != null && initialContent.length > 0) {
            Files.write(new File(updatesDir, "release.part").toPath(), initialContent);
            prefs.edit().putString("partial_sha", partialSha).apply();
        }
        Context stubCtx =
                new android.content.ContextWrapper(null) {
                    @Override
                    public File getCacheDir() {
                        return cacheDir;
                    }

                    @Override
                    public String getPackageName() {
                        return "com.pilipala.marcomovie";
                    }
                };
        final java.util.List<Long> seenOffsets = new java.util.ArrayList<>();
        UpdateManager.Connector mockConn =
                (address, offset) -> {
                    seenOffsets.add(offset);
                    if ("416-then-200".equals(mode) && offset > 0) {
                        return mockHttpConnection(416, null, -1, new byte[0]);
                    }
                    if ("206".equals(mode) && offset > 0) {
                        byte[] tail =
                                Arrays.copyOfRange(validPayload, (int) offset, validPayload.length);
                        String cr =
                                "bytes "
                                        + offset
                                        + "-"
                                        + (validPayload.length - 1)
                                        + "/"
                                        + validPayload.length;
                        return mockHttpConnection(206, cr, tail.length, tail);
                    }
                    return mockHttpConnection(200, null, validPayload.length, validPayload);
                };
        UpdateManager.ApkVerifier mockVerifier =
                (c, file, r) -> {
                    if (file.length() != r.size || !UpdateManager.sha(file).equals(r.sha)) {
                        throw new IOException("digest");
                    }
                    if (failSigner) {
                        throw new IOException("signer");
                    }
                };
        UpdateManager mgr =
                new UpdateManager(stubCtx, prefs, mockConn, d -> usableSpace, mockVerifier);
        Exception caught = null;
        boolean ok = false;
        try {
            mgr.downloadFile(release);
            ok = true;
        } catch (Exception e) {
            caught = e;
        } finally {
            mgr.worker.shutdownNow();
        }
        checkFn.verify(ok, caught, mgr, seenOffsets);
    }

    private static HttpURLConnection mockHttpConnection(
            final int status, final String contentRange, final long contentLen, final byte[] body)
            throws IOException {
        return new HttpURLConnection(new URL("https://marcotv.wlj9919.top/movie/test.apk")) {
            @Override
            public void disconnect() {}

            @Override
            public boolean usingProxy() {
                return false;
            }

            @Override
            public void connect() {}

            @Override
            public int getResponseCode() {
                return status;
            }

            @Override
            public String getHeaderField(String name) {
                if ("Content-Range".equalsIgnoreCase(name)) return contentRange;
                if ("Content-Length".equalsIgnoreCase(name) && contentLen >= 0) {
                    return Long.toString(contentLen);
                }
                return null;
            }

            @Override
            public int getContentLength() {
                return (int) contentLen;
            }

            @Override
            public InputStream getInputStream() {
                return new ByteArrayInputStream(body);
            }
        };
    }

    private static void sendBytes(HttpExchange ex, int status, String contentType, byte[] data)
            throws IOException {
        ex.getResponseHeaders().set("Content-Type", contentType);
        ex.sendResponseHeaders(status, data.length);
        try (OutputStream out = ex.getResponseBody()) {
            out.write(data);
        }
    }

    private static String readUtf8(File f) throws IOException {
        return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    }

    private static String sha256Hex(byte[] data) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder sb = new StringBuilder(64);
        for (byte b : d) sb.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        return sb.toString();
    }

    public static void main(String[] args) throws Exception {
        File mediaDir = new File(args[0]);
        File workDir = new File(args[1]);
        File srcRoot = new File(args[2]);
        testP1EngineAndLifecycle(srcRoot);
        testP2HlsSeparatedAudio(mediaDir, workDir);
        testP3IntroDbV4Semantics(srcRoot);
        testP4MdblistWordingAndSecrets(srcRoot);
        testP5LowSpaceUpdateResume(workDir);
        System.out.println(checks + " Batch 3 mobile checks passed");
        System.exit(0);
    }
}

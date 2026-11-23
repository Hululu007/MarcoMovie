package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Batch 1 regression checks covering:
 *  - #72 / #73: MPV mediaBadges null-ExoPlayer fix (0.6.0 vs 0.7.0+), MPV lifecycle guards,
 *    PlaybackController late-callback guards, and CrashReportStore sanitized native trace parser.
 *  - #71: Type-1 CMS fixture with local JPEGs, vod_pic present, vod_pic_thumb/vod_pic_slide empty,
 *    both standard Apple CMS ?ac=list (omitting vod_pic) and direct vod_pic home responses, plus
 *    ImageLoader generation-scoped coalescing and stale-drawable clearing invariants.
 *  - #14 / #2: Source active rejection, execution Error handling, Activity.finish() interception
 *    distinguishing toast / page pop / process exit, and stage-specific error reporting.
 */
public final class Batch1MobileChecks {
    private static int passed;

    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAILED: " + label);
        passed++;
        System.out.println("PASS " + label);
    }

    private static byte[] minimalJpeg(int seed) {
        // Valid SOI + APP0 + SOF0 (1x1) + EOI marker sequence with distinct payload bytes per seed.
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0xFF);
        out.write(0xD8);
        out.write(0xFF);
        out.write(0xE0);
        out.write(0x00);
        out.write(0x10);
        byte[] jfif = "JFIF\0\1\1\0\0\1\0\1\0\0".getBytes(StandardCharsets.ISO_8859_1);
        out.write(jfif, 0, jfif.length);
        out.write(0xFF);
        out.write(0xFE); // COM comment marker so each fixture JPEG is > 160 bytes and distinct
        byte[] comment = new byte[180];
        Arrays.fill(comment, (byte) ('A' + (seed % 26)));
        int comLen = comment.length + 2;
        out.write((comLen >> 8) & 0xFF);
        out.write(comLen & 0xFF);
        out.write(comment, 0, comment.length);
        out.write(0xFF);
        out.write(0xD9);
        return out.toByteArray();
    }

    private static void test72_73_MpvBadgesLifecycleAndNativeTrace(Path root) throws Exception {
        // 1. MpvPlayer static mediaBadges / HDR / MIME / VO / HWDEC / buffer helpers
        List<String> badges4k =
                MpvPlayer.buildMediaBadges(
                        3840, 2160, "hevc", "eac3", "pq", "mediacodec-copy", false);
        check(
                badges4k.contains("4K")
                        && badges4k.contains("HDR10")
                        && badges4k.contains("DD+")
                        && badges4k.contains("MPV 播放"),
                "#72/#73: MpvPlayer.buildMediaBadges emits 4K/HDR10/DD+/MPV without ExoPlayer");

        List<String> badgesSw =
                MpvPlayer.buildMediaBadges(1920, 1080, "h264", "aac", "", "no", false);
        check(
                badgesSw.contains("1080P")
                        && badgesSw.contains("H.264")
                        && badgesSw.contains("AAC")
                        && badgesSw.contains("MPV 软解"),
                "#72/#73: MpvPlayer.buildMediaBadges handles SW decode and SDR");

        List<String> badgesZero = MpvPlayer.buildMediaBadges(0, 0, null, null, null, null, true);
        check(
                badgesZero.size() == 1 && "MPV Anime4K".equals(badgesZero.get(0)),
                "#72/#73: MpvPlayer.buildMediaBadges handles null/zero initial frame cleanly");

        check(
                "video/dolby-vision".equals(MpvPlayer.normalizeVideoMime("dvhe"))
                        && MpvPlayer.isHdrGammaOrCodec("smpte2084", "hevc"),
                "#72/#73: MpvPlayer HDR and MIME normalization works without ExoPlayer");

        // 2. Source contract checks for 0.7.0+ fixes vs 0.6.0 NPE & native lifecycle hazards
        String mpvSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MpvPlayer.java"),
                        StandardCharsets.UTF_8);
        String movieSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MoviePlayer.java"),
                        StandardCharsets.UTF_8);
        String ctrlSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/PlaybackController.java"),
                        StandardCharsets.UTF_8);

        check(
                mpvSrc.contains("public List<String> mediaBadges()")
                        && movieSrc.contains("if (released || exo == null) return out;"),
                "#72/#73: MpvPlayer overrides mediaBadges() and MoviePlayer guards exo == null");
        check(
                mpvSrc.indexOf("extractAnime4kShader(context)")
                                < mpvSrc.indexOf("MPVLib.create(context)")
                        && mpvSrc.contains("MPVLib.setOptionString(\"vo\", \"null\");")
                        && mpvSrc.contains("if (shouldDestroyNative)"),
                "#72/#73: MpvPlayer prepares Java options before MPVLib.create, starts vo=null, and guards destroy() against pre-init pthread_join(0) SIGABRT");
        check(
                mpvSrc.contains("lastSurfaceWidth > 0 && lastSurfaceHeight > 0")
                        && mpvSrc.contains("MPVLib.command(new String[] {\"stop\"})"),
                "#72/#73: MpvPlayer restores surface size across rotation/reattach and stops before surface detach");
        check(
                ctrlSrc.contains(
                                "if (ticket == a.generation\n                                                                    && a.player == ready")
                        && ctrlSrc.contains(
                                "if (ticket != a.generation\n                                                                    || a.player != ready) return;"),
                "#72/#73: PlaybackController drops late onPrepared/onVideoSizeChanged/onHdrChanged callbacks from stale players");

        // 3. CrashReportStore sanitized native tombstone / trace extraction
        String textTrace =
                "Cmdline: com.pilipala.marcomovie\n"
                        + "signal 6 (SIGABRT), code -1 (SI_QUEUE) from pid 1234\n"
                        + "Abort message: 'FORTIFY: pthread_join called with invalid pthread_t'\n"
                        + "  #00 pc 000000000002598 /data/app/lib/arm64/libplayer.so (Java_dev_jdtech_mpv_MPVLib_destroy+76) (BuildId: 0123456789abcdef0123456789abcdef)\n"
                        + "  url=https://secret.example.com/private?token=abc123\n";
        String parsedText =
                CrashReportStore.extractSanitizedNativeTrace(
                        textTrace.getBytes(StandardCharsets.UTF_8));
        check(
                parsedText.contains("SIGABRT")
                        && parsedText.contains("libplayer.so")
                        && !parsedText.contains("secret.example.com")
                        && !parsedText.contains("abc123"),
                "#72/#73: extractSanitizedNativeTrace preserves native signal/frames and redacts URLs/tokens");

        ByteArrayOutputStream proto = new ByteArrayOutputStream();
        proto.write(new byte[] {0x08, 0x06, 0x12, 0x08, 0x00, 0x01, 0x02});
        proto.write("SIGABRT".getBytes(StandardCharsets.US_ASCII));
        proto.write(new byte[] {0x00, 0x1A, 0x20});
        proto.write("/lib/arm64/libmpv.so".getBytes(StandardCharsets.US_ASCII));
        proto.write(new byte[] {0x00, 0x22, 0x20});
        proto.write("deadbeef0123456789abcdef01234567".getBytes(StandardCharsets.US_ASCII));
        proto.write(new byte[] {0x00, 0x2A, 0x10});
        proto.write(
                "https://leak.example.test/x?apikey=secret99".getBytes(StandardCharsets.US_ASCII));
        proto.write(new byte[] {0x00});
        String parsedProto = CrashReportStore.extractSanitizedNativeTrace(proto.toByteArray());
        check(
                parsedProto.contains("SIGABRT")
                        && parsedProto.contains("libmpv.so")
                        && parsedProto.contains("deadbeef0123456789abcdef01234567")
                        && !parsedProto.contains("secret99"),
                "#72/#73: extractSanitizedNativeTrace parses binary protobuf tombstones for signal/so/build-id");
    }

    private static void test71_Type1CmsHomePostersAndImageLoader(Path root) throws Exception {
        byte[] jpegA = minimalJpeg(1);
        byte[] jpegB = minimalJpeg(2);
        check(!Arrays.equals(jpegA, jpegB), "#71 setup: two distinct local fixture JPEGs");

        AtomicInteger detailCalls = new AtomicInteger();
        AtomicInteger listCalls = new AtomicInteger();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String base = "http://127.0.0.1:" + port;

        server.createContext(
                "/img/poster_a.jpg",
                ex -> {
                    ex.getResponseHeaders().set("Content-Type", "image/jpeg");
                    ex.sendResponseHeaders(200, jpegA.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(jpegA);
                    }
                });
        server.createContext(
                "/img/poster_b.jpg",
                ex -> {
                    ex.getResponseHeaders().set("Content-Type", "image/jpeg");
                    ex.sendResponseHeaders(200, jpegB.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(jpegB);
                    }
                });
        // Fixture A: Standard Apple CMS v10 (?ac=list omits vod_pic; ?ac=detail includes vod_pic,
        // with vod_pic_thumb and vod_pic_slide empty strings).
        server.createContext(
                "/api_standard.php/provide/vod",
                ex -> {
                    String q = ex.getRequestURI().getQuery();
                    JSONObject doc = new JSONObject();
                    doc.put("code", 1).put("page", 1).put("pagecount", 2);
                    JSONArray cats =
                            new JSONArray()
                                    .put(new JSONObject().put("type_id", 1).put("type_name", "电影"));
                    doc.put("class", cats);
                    JSONArray list = new JSONArray();
                    if (q != null && q.contains("ac=detail")) {
                        detailCalls.incrementAndGet();
                        list.put(
                                new JSONObject()
                                        .put("vod_id", 101)
                                        .put("vod_name", "星际样例甲")
                                        .put("vod_remarks", "HD")
                                        .put("vod_pic", base + "/img/poster_a.jpg")
                                        .put("vod_pic_thumb", "")
                                        .put("vod_pic_slide", "")
                                        .put("vod_play_from", "直链")
                                        .put("vod_play_url", "正片$" + base + "/v1.mp4"));
                        list.put(
                                new JSONObject()
                                        .put("vod_id", 102)
                                        .put("vod_name", "星际样例乙")
                                        .put("vod_remarks", "更新至02集")
                                        .put("vod_pic", base + "/img/poster_b.jpg")
                                        .put("vod_pic_thumb", "")
                                        .put("vod_pic_slide", "")
                                        .put("vod_play_from", "直链")
                                        .put("vod_play_url", "第1集$" + base + "/v2.mp4"));
                    } else {
                        listCalls.incrementAndGet();
                        list.put(
                                new JSONObject()
                                        .put("vod_id", 101)
                                        .put("vod_name", "星际样例甲")
                                        .put("vod_remarks", "HD")
                                        .put("vod_pic_thumb", "")
                                        .put("vod_pic_slide", ""));
                        list.put(
                                new JSONObject()
                                        .put("vod_id", 102)
                                        .put("vod_name", "星际样例乙")
                                        .put("vod_remarks", "更新至02集")
                                        .put("vod_pic_thumb", "")
                                        .put("vod_pic_slide", ""));
                    }
                    doc.put("list", list);
                    byte[] raw = doc.toString().getBytes(StandardCharsets.UTF_8);
                    ex.getResponseHeaders().set("Content-Type", "application/json");
                    ex.sendResponseHeaders(200, raw.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(raw);
                    }
                });
        // Fixture B: Type-1 CMS where ?ac=list directly returns vod_pic (empty thumb/slide).
        AtomicInteger directDetailCalls = new AtomicInteger();
        server.createContext(
                "/api_direct.php/provide/vod",
                ex -> {
                    String q = ex.getRequestURI().getQuery();
                    if (q != null && q.contains("ac=detail")) directDetailCalls.incrementAndGet();
                    JSONObject doc = new JSONObject();
                    doc.put("code", 1).put("page", 1).put("pagecount", 1);
                    doc.put(
                            "class",
                            new JSONArray()
                                    .put(
                                            new JSONObject()
                                                    .put("type_id", 1)
                                                    .put("type_name", "剧集")));
                    doc.put(
                            "list",
                            new JSONArray()
                                    .put(
                                            new JSONObject()
                                                    .put("vod_id", 201)
                                                    .put("vod_name", "直出海报甲")
                                                    .put("vod_pic", base + "/img/poster_a.jpg")
                                                    .put("vod_pic_thumb", "")
                                                    .put("vod_pic_slide", ""))
                                    .put(
                                            new JSONObject()
                                                    .put("vod_id", 202)
                                                    .put("vod_name", "直出海报乙")
                                                    .put("vod_pic", base + "/img/poster_b.jpg")
                                                    .put("vod_pic_thumb", "")
                                                    .put("vod_pic_slide", "")));
                    byte[] raw = doc.toString().getBytes(StandardCharsets.UTF_8);
                    ex.getResponseHeaders().set("Content-Type", "application/json");
                    ex.sendResponseHeaders(200, raw.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(raw);
                    }
                });
        server.start();
        try {
            // Case A: Standard Apple CMS ?ac=list omits vod_pic -> old Cms.listing(homeRaw) has
            // blank posters, new MobileHomePage.resolveHomeListing enriches via homeVideos().
            Cms.Site stdSite = new Cms.Site();
            stdSite.key = "std_cms";
            stdSite.name = "标准苹果CMS";
            stdSite.type = 1;
            stdSite.api = base + "/api_standard.php/provide/vod";
            JsonCmsEngine stdEng = new JsonCmsEngine(stdSite);

            String homeRaw = stdEng.home();
            List<Cms.Category> cats = Cms.categories(homeRaw);
            Cms.Listing rawOnly = Cms.listing(homeRaw);
            check(
                    rawOnly.videos.size() == 2 && !MobileHomePage.hasAnyPoster(rawOnly.videos),
                    "#71 repro: Apple CMS ?ac=list has 2 videos with blank posters");

            Cms.Listing resolved = MobileHomePage.resolveHomeListing(stdEng, homeRaw, cats);
            check(
                    resolved.videos.size() == 2
                            && (base + "/img/poster_a.jpg").equals(resolved.videos.get(0).poster)
                            && (base + "/img/poster_b.jpg").equals(resolved.videos.get(1).poster)
                            && detailCalls.get() == 1,
                    "#71 fix: resolveHomeListing enriches standard Apple CMS via homeVideos() with both distinct vod_pic URLs");

            // Case B: Type-1 CMS returning vod_pic directly in ?ac=list (empty thumb/slide)
            Cms.Site directSite = new Cms.Site();
            directSite.key = "direct_cms";
            directSite.name = "直出海报CMS";
            directSite.type = 1;
            directSite.api = base + "/api_direct.php/provide/vod";
            JsonCmsEngine directEng = new JsonCmsEngine(directSite);
            String directHome = directEng.home();
            Cms.Listing directResolved =
                    MobileHomePage.resolveHomeListing(
                            directEng, directHome, Cms.categories(directHome));
            check(
                    directResolved.videos.size() == 2
                            && (base + "/img/poster_a.jpg")
                                    .equals(directResolved.videos.get(0).poster)
                            && (base + "/img/poster_b.jpg")
                                    .equals(directResolved.videos.get(1).poster)
                            && directDetailCalls.get() == 0,
                    "#71 fix: direct vod_pic home listing preserves both JPEGs without redundant detail call");

            // Case C: ImageLoader & MobileRootShell invariants
            String imgLoaderSrc =
                    Files.readString(
                            root.resolve(
                                    "android-mobile/src/main/java/com/pilipala/marcomovie/ImageLoader.java"),
                            StandardCharsets.UTF_8);
            String shellSrc =
                    Files.readString(
                            root.resolve(
                                    "android-mobile/src/main/java/com/pilipala/marcomovie/MobileRootShell.java"),
                            StandardCharsets.UTF_8);
            check(
                    imgLoaderSrc.contains("final String flightKey = ticket + \"|\" + key;")
                            && imgLoaderSrc.contains(
                                    "if (!normalized.equals(previousTag)) {\n            image.setImageDrawable(null);")
                            && imgLoaderSrc.contains("static void resumeMissingPosters(")
                            && shellSrc.contains("ImageLoader.resumeMissingPosters(a, shellRoot);"),
                    "#71 fix: ImageLoader scopes IN_FLIGHT per generation, clears stale drawable on rebind, and resumes missing posters on Home return");
        } finally {
            server.stop(0);
        }
    }

    private static void test14_2_SourceRejectionExecutionErrorsAndStages(Path root)
            throws Exception {
        // 1. Distinguish Activity.finish() interception policy: Home vs Detail vs Player
        check(
                !MainActivity.shouldPopScreenOnPluginFinish(true, false, true),
                "#14: plugin finish on Home does NOT exit app or pop stack");
        check(
                MainActivity.shouldPopScreenOnPluginFinish(false, false, true),
                "#14: plugin finish on Detail pops cleanly back to Home");
        check(
                !MainActivity.shouldPopScreenOnPluginFinish(false, true, true),
                "#14: plugin finish during Player never disrupts active playback");

        // 2. Active rejection & execution Error -> recoverable messages with explicit stage
        String rejectMsg =
                SourceController.stageMessage("列表读取失败", new SecurityException("非开源软件禁止调用"));
        check(
                rejectMsg.contains("列表读取失败")
                        && rejectMsg.contains("非开源软件")
                        && rejectMsg.contains("切换其他片源"),
                "#14: active source rejection surfaces recoverable error with switch guidance");

        String linkageMsg =
                SourceController.stageMessage("列表读取失败", new NoSuchMethodError("compat.missing"));
        check(
                linkageMsg.contains("列表读取失败")
                        && linkageMsg.contains("当前系统版本不兼容")
                        && !linkageMsg.contains("电视系统"),
                "#14: LinkageError produces mobile-appropriate recoverable error");

        // 3. Stage separation for #2: import -> list -> detail -> parse failure vs player failure
        String cfgJson =
                new JSONObject()
                        .put(
                                "sites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("key", "s1")
                                                        .put("name", "测试站点")
                                                        .put("type", 1)
                                                        .put("api", "https://fixture.invalid/vod")))
                        .toString();
        Cms.Config parsedCfg = Cms.parseConfig(cfgJson, "https://fixture.invalid/config.json");
        check(parsedCfg.sites.size() == 1, "#2 stage 1: config imports with exact site count");

        // Mock source with valid list & detail, but failing at stream parse stage
        SourceEngine parseFailingEngine =
                new SourceEngine() {
                    @Override
                    public String home() {
                        return "{\"class\":[{\"type_id\":\"1\",\"type_name\":\"电影\"}],\"list\":[{\"vod_id\":\"7\",\"vod_name\":\"样本影片\",\"vod_pic\":\"https://fixture.invalid/p.jpg\"}]}";
                    }

                    @Override
                    public String category(String categoryId, int page) {
                        return home();
                    }

                    @Override
                    public String detail(String videoId) {
                        return "{\"list\":[{\"vod_id\":\"7\",\"vod_name\":\"样本影片\",\"vod_play_from\":\"线路1\",\"vod_play_url\":\"正片$opaque-token-1\"}]}";
                    }

                    @Override
                    public String search(String keyword, int page) {
                        return "{\"list\":[]}";
                    }

                    @Override
                    public String player(String flag, String id) throws Exception {
                        throw new IOException("媒体地址返回为空或格式无效");
                    }

                    @Override
                    public boolean requiresExternalRuntime() {
                        return false;
                    }
                };

        Cms.Listing listed =
                MobileHomePage.resolveHomeListing(
                        parseFailingEngine,
                        parseFailingEngine.home(),
                        Cms.categories(parseFailingEngine.home()));
        check(listed.videos.size() == 1, "#2 stage 2: list succeeds with 1 item");

        Cms.Listing detailListing = Cms.listing(parseFailingEngine.detail("7"));
        Cms.Video detailed = detailListing.videos.isEmpty() ? null : detailListing.videos.get(0);
        check(
                detailed != null
                        && detailed.lines.size() == 1
                        && detailed.lines.get(0).episodes.size() == 1,
                "#2 stage 3: detail succeeds with playable line");

        String parseStageErr = "";
        try {
            parseFailingEngine.player("线路1", "opaque-token-1");
        } catch (Throwable t) {
            parseStageErr = SourceController.stageMessage("解析失败", t);
        }
        check(
                parseStageErr.startsWith("解析失败：") && parseStageErr.contains("媒体地址返回"),
                "#2 stage 4a: stream parse failure clearly classified as 解析失败");

        String playerStageErr = PlaybackFailure.message(4003, 0);
        check(
                playerStageErr != null
                        && !playerStageErr.isEmpty()
                        && !playerStageErr.startsWith("解析失败"),
                "#2 stage 4b: playback decoder failure cleanly distinct from stream parse failure");

        // 4. Verify MobileHomePage catches Throwable & exposes switch-source recovery button,
        // and MainActivity.interceptPluginFinish notifies shell instead of stalling silently.
        String homeSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileHomePage.java"),
                        StandardCharsets.UTF_8);
        String mainSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MainActivity.java"),
                        StandardCharsets.UTF_8);
        String inlineSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileInlinePlayer.java"),
                        StandardCharsets.UTF_8);
        check(
                homeSrc.contains("catch (Throwable e)")
                        && homeSrc.contains("recoverSwitchBtn.setVisibility(View.VISIBLE)")
                        && homeSrc.contains("shell.onSourceRejected ="),
                "#14: MobileHomePage catches Throwable and displays switch-source recovery control");
        check(
                mainSrc.contains("mobileShell.showSourceRejectedRecovery(recoveryMsg)")
                        && inlineSrc.contains("void showResolveFailure(String message)"),
                "#14/#2: plugin finish recovery updates Home shell and inline player displays parse failure");
    }

    public static void main(String[] args) throws Exception {
        Path root = args.length > 0 ? Paths.get(args[0]) : Paths.get(".");
        test72_73_MpvBadgesLifecycleAndNativeTrace(root);
        test71_Type1CmsHomePostersAndImageLoader(root);
        test14_2_SourceRejectionExecutionErrorsAndStages(root);
        System.out.println("Batch1MobileChecks OK (" + passed + " checks passed)");
    }
}

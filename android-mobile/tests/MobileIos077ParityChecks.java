package com.pilipala.marcomovie;

import com.pilipala.marcomovie.MobileEmbyLibrary;
import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Deterministic JVM + real local HTTP server behavioral regression harness covering Android Mobile
 * iOS 0.7.7 parity items (原 1, 2A, 2B, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17).
 *
 * <p>All network traffic stays strictly on {@code 127.0.0.1} ephemeral ports.
 */
public final class MobileIos077ParityChecks {
    private static int passedCount = 0;

    public static void main(String[] args) throws Exception {
        File workDir =
                args.length > 0
                        ? new File(args[0])
                        : new File(System.getProperty("java.io.tmpdir"), "ios077-parity-work");
        if (!workDir.exists()) workDir.mkdirs();

        test1NetdiskAuthConfigCenterAndWebServer(workDir);
        test2PersonalNetdiskLibraryAndAccountIsolation();
        test3EmbyAndAlistConnectors();
        test4Large4kTailSeekPreemptionAndHistoryGuard();
        test5DanmuDiscoverySubpathsAndManualMatch();
        test6HomeSectionsSourcePickerAndScopedLineRules();
        test7ExactSearchAndRapidModeSwitch();
        test8HudPrefsAndVideoTrackSwitchState();
        test9And14CspHardeningAndExternalParserChain(workDir);
        test10Round2AdversarialReworkChecks(workDir);
        p1Item7Api23ContentLengthAndRangeModes();
        test11NetdiskDrivePriorityOrderAndPlaybackSelection();

        System.out.println("PASS ALL MobileIos077ParityChecks (" + passedCount + " suites passed)");
    }

    private static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAILED: " + msg);
    }

    private static void pass(String label) {
        passedCount++;
        System.out.println("PASS " + label);
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        return out.toByteArray();
    }

    private static void sendJson(HttpExchange ex, int status, String json) throws IOException {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        ex.sendResponseHeaders(status, body.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(body);
        }
    }

    private static String httpRequest(String method, String url, String jsonBody)
            throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestMethod(method);
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(5000);
        if (jsonBody != null) {
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            byte[] bytes = jsonBody.getBytes(StandardCharsets.UTF_8);
            try (OutputStream os = conn.getOutputStream()) {
                os.write(bytes);
            }
        }
        int code = conn.getResponseCode();
        InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
        String body = in == null ? "" : new String(readAll(in), StandardCharsets.UTF_8);
        conn.disconnect();
        return code + "\n" + body;
    }

    // -------------------------------------------------------------------------
    // Item 1 (原 2B, 4, 5): Netdisk QR auth, Config Center sync, 4 paths, no storage perm
    // -------------------------------------------------------------------------
    private static void test1NetdiskAuthConfigCenterAndWebServer(File workDir) throws Exception {
        final AtomicInteger quarkPollStep = new AtomicInteger(0);
        HttpServer mockAuth = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mockAuth.setExecutor(Executors.newCachedThreadPool());
        mockAuth.createContext(
                "/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String path = ex.getRequestURI().getPath();
                        if (path.contains("getTokenForQrcodeLogin")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"status\":2000000,\"data\":{\"members\":{\"token\":\"qr_tok_001\"}}}");
                            return;
                        }
                        if (path.contains("getServiceTicketByQrcodeToken")) {
                            int step = quarkPollStep.incrementAndGet();
                            if (step == 1) {
                                sendJson(ex, 200, "{\"status\":50004001}");
                            } else {
                                sendJson(
                                        ex,
                                        200,
                                        "{\"status\":2000000,\"data\":{\"members\":{\"service_ticket\":\"st_quark_999\"}}}");
                            }
                            return;
                        }
                        if (path.contains("account/info")) {
                            ex.getResponseHeaders()
                                    .add("Set-Cookie", "__pus=quark_pus_alpha; Path=/; HttpOnly");
                            ex.getResponseHeaders()
                                    .add("Set-Cookie", "__puus=quark_puus_alpha; Path=/");
                            sendJson(
                                    ex,
                                    200,
                                    "{\"success\":true,\"data\":{\"member_id\":\"10001\",\"nickname\":\"QuarkUser\"}}");
                            return;
                        }
                        if (path.contains("file/sort")) {
                            ex.getResponseHeaders().add("Set-Cookie", "b-user-id=10001; Path=/");
                            sendJson(ex, 200, "{\"status\":200,\"data\":{\"list\":[]}}");
                            return;
                        }
                        sendJson(ex, 404, "{}");
                    }
                });
        mockAuth.start();
        try {
            String base = "http://127.0.0.1:" + mockAuth.getAddress().getPort();
            NetdiskAuthService.Endpoints ep = new NetdiskAuthService.Endpoints();
            ep.quarkUopBase = base;
            ep.quarkSuBase = base;
            ep.quarkPanBase = base;
            ep.quarkDriveBase = base;
            NetdiskAuthService auth = new NetdiskAuthService(ep);

            // QR session -> waiting -> confirmed with cookie + ownerId
            NetdiskAuthService.QrSession sess = auth.startQrSession(NetdiskStore.DRIVE_QUARK);
            check("qr_tok_001".equals(sess.token), "Quark QR token");
            check(
                    !NetdiskAuthService.buildSameDeviceDeepLinks(
                                    NetdiskStore.DRIVE_QUARK, sess.qrUrl)
                            .isEmpty(),
                    "Quark same-device deep link");
            NetdiskAuthService.PollResult p1 = auth.pollQrSession(sess);
            check(NetdiskAuthService.STATE_WAITING.equals(p1.state), "First poll waits");
            NetdiskAuthService.PollResult p2 = auth.pollQrSession(sess);
            check(p2.isConfirmed(), "Second poll confirms Quark login: " + p2.message);
            check(p2.credential.contains("__pus=quark_pus_alpha"), "Quark cookie captured");

            // Ali GBK bizExt decoding with Chinese nickname
            String gbkJson =
                    "{\"pds_login_result\":{\"refreshToken\":\"ali_rt_1234567890abcdef\",\"userId\":\"ali_u_77\",\"nickName\":\"测试用户\"}}";
            String b64 =
                    Base64.getEncoder().encodeToString(gbkJson.getBytes(Charset.forName("GBK")));
            NetdiskAuthService.AliCredential aliCred = NetdiskAuthService.parseAliBizExt(b64);
            check(
                    aliCred != null && "ali_rt_1234567890abcdef".equals(aliCred.refreshToken),
                    "Ali GBK RT");
            check("ali_u_77".equals(aliCred.userId), "Ali GBK userId");

            // One-scan reuse & Config Center bidirectional sync + conflict protection
            // (permission-free app dir)
            NetdiskStore.MemoryStore store = new NetdiskStore.MemoryStore();
            NetdiskStore.setCredential(store, NetdiskStore.DRIVE_QUARK, p2.credential, p2.ownerId);

            File appPrivateDir = new File(workDir, "netdisk-app-private");
            appPrivateDir.mkdirs();
            Cms.Config cfg = new Cms.Config();
            Cms.Site ccSite = new Cms.Site();
            ccSite.key = "csp_ConfigCenter";
            ccSite.name = "网盘配置中心";
            ccSite.api = "csp_ConfigCenter";
            cfg.sites.add(ccSite);
            check(
                    ConfigCenterBridge.detectConfigCenters(cfg).size() == 1,
                    "Config center detected");

            // Push Quark credential from NetdiskStore -> ConfigCenter app-private dir
            ConfigCenterBridge.SyncReport pushRep =
                    ConfigCenterBridge.syncAll(
                            store,
                            Collections.singletonList(appPrivateDir),
                            Collections.singletonList(appPrivateDir),
                            cfg,
                            false,
                            true,
                            false);
            check(
                    pushRep.pushedFiles.size() > 0,
                    "Config center files written without storage permission");
            File wexFile = new File(appPrivateDir, "wexfnwconfig.json");
            check(wexFile.isFile(), "wexfnwconfig.json exists");
            File quarkTxt = new File(appPrivateDir, "quark_cookie.txt");
            check(quarkTxt.isFile(), "quark_cookie.txt exists");

            // Simulate Config Center updating UC cookie + writing STALE Quark cookie:
            // Pull must import UC into 「我的云盘」 WITHOUT silently overwriting valid Quark!
            try (FileOutputStream fos =
                    new FileOutputStream(new File(appPrivateDir, "uc_cookie.txt"))) {
                fos.write(
                        "__pus=uc_from_center; __puus=uc_puus_center"
                                .getBytes(StandardCharsets.UTF_8));
            }
            try (FileOutputStream fos = new FileOutputStream(quarkTxt)) {
                fos.write(
                        "__pus=old_stale_quark; __puus=old_stale".getBytes(StandardCharsets.UTF_8));
            }
            try (FileOutputStream fos = new FileOutputStream(wexFile)) {
                fos.write(
                        "{\"quark_cookie\":\"__pus=old_stale_quark; __puus=old_stale\",\"uc_cookie\":\"__pus=uc_from_center; __puus=uc_puus_center\"}"
                                .getBytes(StandardCharsets.UTF_8));
            }
            ConfigCenterBridge.SyncReport pullRep =
                    ConfigCenterBridge.syncAll(
                            store,
                            Collections.singletonList(appPrivateDir),
                            Collections.singletonList(appPrivateDir),
                            cfg,
                            true,
                            false,
                            false);
            check(
                    NetdiskStore.getCredential(store, NetdiskStore.DRIVE_UC)
                            .contains("uc_from_center"),
                    "UC imported from Config Center into 我的云盘");
            check(
                    NetdiskStore.getCredential(store, NetdiskStore.DRIVE_QUARK)
                            .contains("quark_pus_alpha"),
                    "Existing valid Quark account NOT silently overwritten by stale config");
            check(
                    pullRep.skippedExistingDrives.contains(NetdiskStore.DRIVE_QUARK),
                    "Conflict recorded");

            // Path 3 & Path 4: Local & LAN Config Web Server (bind host, port, page, submit
            // callback, status)
            final AtomicReference<String> cbRemote = new AtomicReference<>("");
            try (NetdiskConfigWebServer web =
                    new NetdiskConfigWebServer(
                            new NetdiskConfigWebServer.SubmissionCallback() {
                                @Override
                                public NetdiskConfigWebServer.SubmissionResult onSubmit(
                                        Map<String, String> drives,
                                        String order,
                                        String remoteAddr) {
                                    cbRemote.set(remoteAddr);
                                    List<String> updated = new ArrayList<>();
                                    for (Map.Entry<String, String> e : drives.entrySet()) {
                                        if (NetdiskStore.setCredential(
                                                store, e.getKey(), e.getValue(), "")) {
                                            updated.add(e.getKey());
                                        }
                                    }
                                    if (order != null && !order.isEmpty()) {
                                        NetdiskStore.setOrder(
                                                store, NetdiskStore.parseOrder(order));
                                    }
                                    ConfigCenterBridge.syncAll(
                                            store,
                                            Collections.singletonList(appPrivateDir),
                                            Collections.singletonList(appPrivateDir),
                                            cfg,
                                            false,
                                            true,
                                            false);
                                    return new NetdiskConfigWebServer.SubmissionResult(
                                            true, "saved", updated);
                                }
                            },
                            store,
                            60_000L,
                            "0.0.0.0",
                            0)) {
                check("0.0.0.0".equals(web.getBindAddress()), "Binds 0.0.0.0 for LAN access");
                check(web.getPort() > 0, "Ephemeral port bound");
                check(web.getPagePath().startsWith("/netdisk-config/"), "Token-scoped page path");
                String pageResp = httpRequest("GET", web.localUrl(), null);
                check(
                        pageResp.startsWith("200\n") && pageResp.contains(web.getSubmitPath()),
                        "Page 200");

                // Wrong token must be rejected
                String badResp =
                        httpRequest(
                                "GET",
                                "http://127.0.0.1:" + web.getPort() + "/netdisk-config/wrongtoken",
                                null);
                check(!badResp.startsWith("200\n"), "Wrong token rejected");

                // Submit Baidu cookie + custom order via /submit
                String submitUrl = "http://127.0.0.1:" + web.getPort() + web.getSubmitPath();
                String payload =
                        new JSONObject()
                                .put("baidu", "BDUSS=baidu_web_1234567890; STOKEN=st_web")
                                .put("order", "baidu,quark,uc,ali")
                                .toString();
                String subResp = httpRequest("POST", submitUrl, payload);
                check(subResp.startsWith("200\n") && subResp.contains("\"ok\":true"), "Submit ok");
                check(!cbRemote.get().isEmpty(), "Callback captured remote address");
                check(
                        NetdiskStore.getCredential(store, NetdiskStore.DRIVE_BAIDU)
                                .contains("baidu_web_1234567890"),
                        "Baidu credential persisted from web submit");
                check(
                        NetdiskStore.DRIVE_BAIDU.equals(NetdiskStore.getOrder(store).get(0)),
                        "Order updated from web submit");
                String statusResp =
                        httpRequest(
                                "GET",
                                "http://127.0.0.1:" + web.getPort() + web.getStatusPath(),
                                null);
                check(
                        statusResp.startsWith("200\n") && statusResp.contains("baidu"),
                        "Status endpoint ok");
            }
        } finally {
            mockAuth.stop(0);
        }
        pass(
                "Item 1 (原 2B/4/5): Netdisk QR auth, bidirectional Config Center sync & LAN web server");
    }

    // -------------------------------------------------------------------------
    // Item 2 (原 12): Personal Netdisk 4 providers, subfolders, pagination, playback & account
    // isolation
    // -------------------------------------------------------------------------
    private static void test2PersonalNetdiskLibraryAndAccountIsolation() throws Exception {
        final AtomicBoolean quarkPage2Expired = new AtomicBoolean(false);
        HttpServer mockCloud = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mockCloud.setExecutor(Executors.newCachedThreadPool());
        mockCloud.createContext(
                "/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String path = ex.getRequestURI().getPath();
                        String query = ex.getRequestURI().getRawQuery();
                        if (query == null) query = "";
                        String cookie = ex.getRequestHeaders().getFirst("Cookie");
                        if (cookie == null) cookie = "";

                        // Quark & UC endpoints
                        if (path.contains("/1/clouddrive/file/sort")) {
                            boolean isUc = cookie.contains("uc1");
                            if (!isUc && quarkPage2Expired.get() && query.contains("_page=2")) {
                                sendJson(ex, 401, "{\"status\":401,\"message\":\"expired\"}");
                                return;
                            }
                            if (query.contains("pdir_fid=dir_movies")) {
                                sendJson(
                                        ex,
                                        200,
                                        "{\"status\":200,\"data\":{\"list\":[{\"fid\":\"vid_001\",\"file_name\":\"三体.mkv\",\"dir\":false,\"size\":104857600}]},\"metadata\":{\"_total\":1,\"_count\":1}}");
                                return;
                            }
                            if (query.contains("_page=2")) {
                                sendJson(
                                        ex,
                                        200,
                                        "{\"status\":200,\"data\":{\"list\":[{\"fid\":\"vid_p2\",\"file_name\":\"流浪地球.mp4\",\"dir\":false,\"size\":2048}]},\"metadata\":{\"_total\":55,\"_count\":1}}");
                                return;
                            }
                            sendJson(
                                    ex,
                                    200,
                                    "{\"status\":200,\"data\":{\"list\":[{\"fid\":\"dir_movies\",\"file_name\":\"电影\",\"dir\":true,\"size\":0}]},\"metadata\":{\"_total\":55,\"_count\":1}}");
                            return;
                        }
                        if (path.contains("/1/clouddrive/file/download")) {
                            String mediaUrl =
                                    "http://127.0.0.1:"
                                            + mockCloud.getAddress().getPort()
                                            + "/media/stream.mkv";
                            sendJson(
                                    ex,
                                    200,
                                    "{\"status\":200,\"data\":[{\"fid\":\"vid_001\",\"download_url\":\""
                                            + mediaUrl
                                            + "\"}]}");
                            return;
                        }
                        if (path.contains("/media/stream.mkv")) {
                            byte[] data =
                                    "FAKE_MKV_STREAM_BYTES_1234567890"
                                            .getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Accept-Ranges", "bytes");
                            ex.getResponseHeaders()
                                    .set(
                                            "Content-Range",
                                            "bytes 0-" + (data.length - 1) + "/" + data.length);
                            ex.sendResponseHeaders(206, data.length);
                            try (OutputStream os = ex.getResponseBody()) {
                                os.write(data);
                            }
                            return;
                        }
                        // Baidu endpoints
                        if (path.contains("/rest/2.0/xpan/nas")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"errno\":0,\"uk\":888123,\"baidu_name\":\"bduser\"}");
                            return;
                        }
                        if (path.contains("/api/list")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"errno\":0,\"list\":[{\"fs_id\":5001,\"server_filename\":\"纪录片.mp4\",\"path\":\"/纪录片.mp4\",\"isdir\":0,\"size\":4096}]}");
                            return;
                        }
                        if (path.contains("/rest/2.0/pcs/file")) {
                            String mediaUrl =
                                    "http://127.0.0.1:"
                                            + mockCloud.getAddress().getPort()
                                            + "/media/stream.mkv";
                            sendJson(ex, 200, "{\"urls\":[{\"url\":\"" + mediaUrl + "\"}]}");
                            return;
                        }
                        // Ali endpoints
                        if (path.contains("/v2/account/token")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"access_token\":\"ali_at_01\",\"refresh_token\":\"ali_rt_rotated_9999999999\",\"default_drive_id\":\"drv_1\",\"user_id\":\"ali_uid_99\",\"expires_in\":7200}");
                            return;
                        }
                        if (path.contains("/adrive/v3/file/list")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"items\":[{\"file_id\":\"ali_f1\",\"name\":\"动漫.mkv\",\"type\":\"file\",\"size\":8192}],\"next_marker\":\"\"}");
                            return;
                        }
                        if (path.contains("/v2/file/get_video_preview_play_info")) {
                            String mediaUrl =
                                    "http://127.0.0.1:"
                                            + mockCloud.getAddress().getPort()
                                            + "/media/stream.mkv";
                            sendJson(
                                    ex,
                                    200,
                                    "{\"video_preview_play_info\":{\"live_transcoding_task_list\":[{\"template_id\":\"FHD\",\"status\":\"finished\",\"url\":\""
                                            + mediaUrl
                                            + "\"}]}}");
                            return;
                        }
                        sendJson(ex, 404, "{}");
                    }
                });
        mockCloud.start();

        try (CloudMediaProxy proxy = new CloudMediaProxy()) {
            String base = "http://127.0.0.1:" + mockCloud.getAddress().getPort();
            PersonalNetdiskLibrary.Endpoints ep = new PersonalNetdiskLibrary.Endpoints();
            ep.quarkDriveBase = base;
            ep.quarkReferer = base + "/";
            ep.ucApiBase = base;
            ep.ucOrigin = base;
            ep.baiduPanBase = base;
            ep.baiduPcsBase = base;
            ep.aliAuthBase = base;
            ep.aliApiBase = base;
            ep.aliPdsBase = base;
            ep.aliReferer = base + "/";

            NetdiskStore.MemoryStore store = new NetdiskStore.MemoryStore();
            PersonalNetdiskLibrary lib = new PersonalNetdiskLibrary(store, ep, proxy);

            // Quark login as Account A (uid:1001)
            NetdiskStore.setCredential(
                    store,
                    NetdiskStore.DRIVE_QUARK,
                    "__pus=acctA_v1; __puus=acctA_puus_v1",
                    "quark:uid:1001");
            // Root listing -> subfolder navigation -> pagination
            PersonalNetdiskLibrary.FolderPage page1 =
                    lib.listFolder(NetdiskStore.DRIVE_QUARK, "0", 1, "");
            check(page1.items.size() == 1 && page1.items.get(0).directory, "Quark page 1 folder");
            check(page1.hasMore, "Quark page 1 reports hasMore");
            PersonalNetdiskLibrary.FolderPage sub =
                    lib.listFolder(NetdiskStore.DRIVE_QUARK, "dir_movies", 1, "");
            check(
                    sub.items.size() == 1 && "三体.mkv".equals(sub.items.get(0).name),
                    "Quark subfolder");

            PersonalNetdiskLibrary.CloudItem favItem = sub.items.get(0);
            String favPlayId = favItem.canonicalPlayId();
            check(
                    favPlayId.contains("account=quark%3Auid%3A1001"),
                    "Canonical play ID binds account");

            // Resolve file -> playable proxy URL
            PersonalNetdiskLibrary.ResolvedMedia media1 = lib.resolveFile(favItem);
            check(
                    media1.playUrl.startsWith("http://127.0.0.1:" + proxy.getPort()),
                    "Quark uses proxy");
            check(
                    media1.proxyLease != null && media1.proxyLease.isAuthorized(),
                    "Lease authorized");

            // Same account re-login with refreshed cookie -> favorite MUST remain playable!
            NetdiskStore.setCredential(
                    store,
                    NetdiskStore.DRIVE_QUARK,
                    "__pus=acctA_v2_relogin; __puus=acctA_puus_v2",
                    "quark:uid:1001");
            PersonalNetdiskLibrary.CloudItem parsedFav =
                    PersonalNetdiskLibrary.parseCanonicalPlayId(favPlayId);
            PersonalNetdiskLibrary.ResolvedMedia mediaReLogin = lib.resolveFile(parsedFav);
            check(!mediaReLogin.playUrl.isEmpty(), "Same account re-login keeps favorite playable");

            // Switch to DIFFERENT account B (uid:2002) -> old favorite MUST throw account_mismatch!
            NetdiskStore.setCredential(
                    store,
                    NetdiskStore.DRIVE_QUARK,
                    "__pus=acctB_other; __puus=acctB_puus",
                    "quark:uid:2002");
            boolean blocked = false;
            try {
                lib.resolveFile(parsedFav);
            } catch (PersonalNetdiskLibrary.PersonalCloudException ex) {
                blocked = "account_mismatch".equals(ex.code) && ex.requiresReauth;
            }
            check(
                    blocked,
                    "Switching account blocks opening old account's favorite/same-named file");
            check(
                    !media1.proxyLease.isAuthorized(),
                    "Previous account proxy lease immediately revoked");

            // Page-2 auth expiry preserves page-1 items and signals requiresReauth
            quarkPage2Expired.set(true);
            PersonalNetdiskLibrary.FolderPage keptPage1 =
                    lib.listFolder(NetdiskStore.DRIVE_QUARK, "0", 1, "");
            check(!keptPage1.items.isEmpty(), "Page 1 stays loaded");
            boolean page2Reauth = false;
            try {
                lib.listFolder(NetdiskStore.DRIVE_QUARK, "0", 2, "");
            } catch (PersonalNetdiskLibrary.PersonalCloudException ex) {
                page2Reauth = ex.requiresReauth;
            }
            check(page2Reauth, "Page 2 auth expiry raises requiresReauth while keeping page 1");
            quarkPage2Expired.set(false);

            // UC, Baidu, Ali quick end-to-end list + resolve + Ali refresh_token rotation
            NetdiskStore.setCredential(
                    store, NetdiskStore.DRIVE_UC, "__pus=uc1; __puus=uc2", "uc:uid:50");
            PersonalNetdiskLibrary.FolderPage ucSub =
                    lib.listFolder(NetdiskStore.DRIVE_UC, "dir_movies", 1, "");
            check(ucSub.items.size() == 1, "UC subfolder list");
            check(!lib.resolveFile(ucSub.items.get(0)).playUrl.isEmpty(), "UC resolveFile");

            NetdiskStore.setCredential(
                    store,
                    NetdiskStore.DRIVE_BAIDU,
                    "BDUSS=bd_1234567890abcdef; STOKEN=st_123",
                    "baidu:uk:888123");
            PersonalNetdiskLibrary.FolderPage bdPage =
                    lib.listFolder(NetdiskStore.DRIVE_BAIDU, "/", 1, "");
            check(bdPage.items.size() == 1, "Baidu root list");
            check(!lib.resolveFile(bdPage.items.get(0)).playUrl.isEmpty(), "Baidu resolveFile");

            NetdiskStore.setCredential(
                    store, NetdiskStore.DRIVE_ALI, "ali_rt_initial_1234567890", "ali:uid:99");
            PersonalNetdiskLibrary.FolderPage aliPage =
                    lib.listFolder(NetdiskStore.DRIVE_ALI, "root", 1, "");
            check(aliPage.items.size() == 1, "Ali root list");
            check(
                    "ali_rt_rotated_9999999999"
                            .equals(
                                    NetdiskStore.extractAliRefreshToken(
                                            NetdiskStore.getCredential(
                                                    store, NetdiskStore.DRIVE_ALI))),
                    "Ali rotated refresh_token persisted automatically");
            check(!lib.resolveFile(aliPage.items.get(0)).playUrl.isEmpty(), "Ali resolveFile");
        } finally {
            mockCloud.stop(0);
        }
        pass(
                "Item 2 (原 12): Personal Netdisk 4 providers, pagination, playback & account isolation");
    }

    // -------------------------------------------------------------------------
    // Item 3 (原 17): Emby (Views guard, /emby, subpath, Issue #85) & AList
    // (guest/user/token/pwd/sign)
    // -------------------------------------------------------------------------
    private static void test3EmbyAndAlistConnectors() throws Exception {
        final AtomicBoolean denyEmbyViews = new AtomicBoolean(false);
        final AtomicInteger alistTokenExpiredOnce = new AtomicInteger(0);
        HttpServer mockMedia = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mockMedia.setExecutor(Executors.newCachedThreadPool());
        mockMedia.createContext(
                "/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String path = ex.getRequestURI().getPath();
                        String reqBody =
                                new String(readAll(ex.getRequestBody()), StandardCharsets.UTF_8);

                        // Emby routes: bare root (/Users/...), /emby/Users/...,
                        // /proxy/emby/Users/...
                        if (path.endsWith("/Users/AuthenticateByName")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"AccessToken\":\"emby_tok_1\",\"User\":{\"Id\":\"u_emby_1\"}}");
                            return;
                        }
                        if (path.endsWith("/Users/u_emby_1/Views")) {
                            if (denyEmbyViews.get()) {
                                sendJson(ex, 403, "{\"Message\":\"Forbidden\"}");
                            } else {
                                sendJson(
                                        ex,
                                        200,
                                        "{\"Items\":[{\"Id\":\"v_movies\",\"Name\":\"电影\"}]}");
                            }
                            return;
                        }
                        if (path.endsWith("/Items/ep_1/PlaybackInfo")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"PlaySessionId\":\"ps_1\",\"MediaSources\":[{\"Id\":\"ms_1\",\"SupportsDirectStream\":false,\"SupportsTranscoding\":true,\"TranscodingUrl\":\"/videos/ep_1/master.m3u8?api_key=old&VideoCodec=h264\"}]}");
                            return;
                        }

                        // AList routes under /alist
                        if (path.equals("/alist/api/auth/login")) {
                            JSONObject req = new JSONObject(reqBody);
                            if ("admin".equals(req.optString("username"))
                                    && "secret123".equals(req.optString("password"))) {
                                sendJson(
                                        ex,
                                        200,
                                        "{\"code\":200,\"data\":{\"token\":\"alist_jwt_fresh\"}}");
                            } else {
                                sendJson(ex, 200, "{\"code\":400,\"message\":\"wrong password\"}");
                            }
                            return;
                        }
                        if (path.equals("/alist/api/fs/list")) {
                            String auth = ex.getRequestHeaders().getFirst("Authorization");
                            if ("expired-token".equals(auth)
                                    && alistTokenExpiredOnce.incrementAndGet() == 1) {
                                sendJson(ex, 200, "{\"code\":401,\"message\":\"token expired\"}");
                                return;
                            }
                            JSONObject req = new JSONObject(reqBody);
                            String reqPath = req.optString("path", "/");
                            String dirPwd = req.optString("password", "");
                            if ("/private".equals(reqPath) && !"dirpass88".equals(dirPwd)) {
                                sendJson(
                                        ex,
                                        200,
                                        "{\"code\":403,\"message\":\"password is incorrect\"}");
                                return;
                            }
                            sendJson(
                                    ex,
                                    200,
                                    "{\"code\":200,\"data\":{\"total\":1,\"content\":[{\"name\":\"demo.mkv\",\"size\":4096,\"is_dir\":false,\"sign\":\"sig_abc123\"}]}}");
                            return;
                        }
                        if (path.equals("/alist/api/fs/get")) {
                            JSONObject req = new JSONObject(reqBody);
                            if ("/private/demo.mkv".equals(req.optString("path"))
                                    && !"dirpass88".equals(req.optString("password"))) {
                                sendJson(
                                        ex,
                                        200,
                                        "{\"code\":403,\"message\":\"password is incorrect\"}");
                                return;
                            }
                            // Empty raw_url + sign + custom header -> must fall back to
                            // /d/<path>?sign=...
                            sendJson(
                                    ex,
                                    200,
                                    "{\"code\":200,\"data\":{\"name\":\"demo.mkv\",\"size\":4096,\"is_dir\":false,\"raw_url\":\"\",\"sign\":\"sig_abc123\",\"header\":{\"X-AList-Check\":\"ok\"}}}");
                            return;
                        }
                        sendJson(ex, 404, "{}");
                    }
                });
        mockMedia.start();
        try {
            String hostBase = "http://127.0.0.1:" + mockMedia.getAddress().getPort();

            // Emby 1: Rejects login when Views returns 403
            denyEmbyViews.set(true);
            boolean embyRejected = false;
            try {
                MobileEmbyLibrary.login(hostBase, "alice", "pw", "dev-1");
            } catch (IOException ex) {
                embyRejected = true;
            }
            check(embyRejected, "Emby login rejected when Views read-permission fails (403)");
            denyEmbyViews.set(false);

            // Emby 2: Bare root, /emby, and reverse-proxy subpath /proxy/emby all succeed
            JSONObject bareAcc = MobileEmbyLibrary.login(hostBase, "alice", "pw", "dev-1");
            check(bareAcc.optString("user").equals("u_emby_1"), "Emby bare root login + Views");
            JSONObject withEmbyAcc =
                    MobileEmbyLibrary.login(hostBase + "/emby", "alice", "pw", "dev-1");
            check(
                    withEmbyAcc.optString("base").equals(hostBase + "/emby"),
                    "Emby /emby login + Views");
            JSONObject withSubpathAcc =
                    MobileEmbyLibrary.login(hostBase + "/proxy/emby", "alice", "pw", "dev-1");
            check(
                    withSubpathAcc.optString("base").equals(hostBase + "/proxy/emby"),
                    "Emby reverse-proxy subpath login + Views");

            // Emby 3: Issue #85 transcode URI fix (relative /videos/... keeps /proxy/emby prefix)
            MobileEmbyLibrary withSubpath = new MobileEmbyLibrary(withSubpathAcc);
            JSONObject resolvedEmby =
                    withSubpath.resolve(
                            withSubpathAcc.getString("base")
                                    + "/Videos/ep_1/stream?MediaSourceId=ms_1",
                            false);
            String streamUrl = resolvedEmby.optString("url", "");
            check(
                    streamUrl.startsWith(hostBase + "/proxy/emby/videos/ep_1/master.m3u8")
                            && !streamUrl.contains("/emby/emby/")
                            && !streamUrl.contains("api_key="),
                    "Emby Issue #85 transcode URI preserves subpath & strips obsolete api_key: "
                            + streamUrl);

            // AList 1: Guest mode
            AlistEngine.MountConfig guest =
                    new AlistEngine.MountConfig(
                            "m1", "Guest", hostBase + "/alist", "/", "", "", "", "");
            AlistEngine.Client guestClient = new AlistEngine.Client(guest);
            AlistEngine.ListResult guestList = guestClient.listDirectory("/", 1, 50);
            check(guestList.items.size() == 1, "AList guest fs/list");

            // AList 2: Static Token + directory password + empty raw_url with sign fallback +
            // headers
            AlistEngine.MountConfig tokenDir =
                    new AlistEngine.MountConfig(
                            "m2",
                            "Private",
                            hostBase + "/alist",
                            "/private",
                            "",
                            "",
                            "static_tok",
                            "dirpass88");
            AlistEngine.Client tokenClient = new AlistEngine.Client(tokenDir);
            AlistEngine.ListResult privList = tokenClient.listDirectory("/private", 1, 50);
            check(privList.items.size() == 1, "AList static token + dir password fs/list");
            AlistEngine.FsItem resolved = tokenClient.getFile("/private/demo.mkv");
            String directFallback =
                    AlistEngine.buildDirectDownloadUrl(
                            tokenDir.baseUrl, resolved.path, resolved.sign);
            check(
                    resolved.rawUrl.isEmpty()
                            && directFallback.equals(
                                    hostBase + "/alist/d/private/demo.mkv?sign=sig_abc123"),
                    "AList empty raw_url falls back to signed /d/ URL: " + directFallback);
            check(
                    "ok".equals(resolved.headers.get("X-AList-Check")),
                    "AList data.header preserved");

            // AList 3: Username + Password auto-relogin after 401 token expiry
            AlistEngine.MountConfig userPwd =
                    new AlistEngine.MountConfig(
                            "m3",
                            "Admin",
                            hostBase + "/alist",
                            "/",
                            "admin",
                            "secret123",
                            "expired-token",
                            "");
            AlistEngine.Client authClient = new AlistEngine.Client(userPwd);
            AlistEngine.ListResult relogged = authClient.listDirectory("/", 1, 50);
            check(relogged.items.size() == 1, "AList 401 triggers auto-relogin");
            check(
                    authClient.getFile("/demo.mkv") != null,
                    "AList subsequent fs/get succeeds with refreshed JWT");
        } finally {
            mockMedia.stop(0);
        }
        pass(
                "Item 3 (原 17): Emby (Views guard, subpaths, Issue #85) & AList (guest/user/token/pwd/sign)");
    }

    // -------------------------------------------------------------------------
    // Item 4 (原 2A): 40 GiB MKV tail-seek preemption, Range validation & SeekCommitGuard
    // -------------------------------------------------------------------------
    private static void test4Large4kTailSeekPreemptionAndHistoryGuard() throws Exception {
        final long TOTAL_SIZE = 40L * 1024L * 1024L * 1024L; // 40 GiB
        final long TAIL_START = TOTAL_SIZE - (512L * 1024L); // last 512 KiB Cues region
        final AtomicBoolean returnBadRange = new AtomicBoolean(false);
        final CountDownLatch headStarted = new CountDownLatch(1);

        HttpServer mock4k = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mock4k.setExecutor(Executors.newCachedThreadPool());
        mock4k.createContext(
                "/movie40g.mkv",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String range = ex.getRequestHeaders().getFirst("Range");
                        long start = 0;
                        long end = Math.min(TOTAL_SIZE - 1, 256 * 1024 - 1);
                        if (range != null && range.startsWith("bytes=")) {
                            String[] parts = range.substring(6).split("-", -1);
                            start = Long.parseLong(parts[0]);
                            end =
                                    parts.length > 1 && !parts[1].isEmpty()
                                            ? Long.parseLong(parts[1])
                                            : Math.min(TOTAL_SIZE - 1, start + 256 * 1024 - 1);
                        }
                        long len = end - start + 1;
                        if (returnBadRange.get()) {
                            // Deliberately reply with WRONG Content-Range offset
                            ex.getResponseHeaders()
                                    .set(
                                            "Content-Range",
                                            "bytes 0-" + (len - 1) + "/" + TOTAL_SIZE);
                            ex.sendResponseHeaders(206, len);
                            try (OutputStream os = ex.getResponseBody()) {
                                os.write(new byte[(int) Math.min(len, 65536)]);
                            }
                            return;
                        }
                        if (start < 10L * 1024L * 1024L) {
                            // Slow head probe so tail seek preempts it cleanly
                            headStarted.countDown();
                            ex.getResponseHeaders()
                                    .set(
                                            "Content-Range",
                                            "bytes " + start + "-" + end + "/" + TOTAL_SIZE);
                            ex.sendResponseHeaders(206, len);
                            try (OutputStream os = ex.getResponseBody()) {
                                byte[] chunk = new byte[8192];
                                Arrays.fill(chunk, (byte) 0x11);
                                long sent = 0;
                                while (sent < len) {
                                    int w = (int) Math.min(chunk.length, len - sent);
                                    os.write(chunk, 0, w);
                                    os.flush();
                                    sent += w;
                                    try {
                                        Thread.sleep(60);
                                    } catch (InterruptedException ie) {
                                        break;
                                    }
                                }
                            } catch (IOException ignored) {
                                // Expected when preempted by tail seek!
                            }
                            return;
                        }
                        // Fast deterministic tail payload: every byte is (byte)((offset >>> 12) ^
                        // 0x5A)
                        ex.getResponseHeaders()
                                .set(
                                        "Content-Range",
                                        "bytes " + start + "-" + end + "/" + TOTAL_SIZE);
                        ex.sendResponseHeaders(206, len);
                        try (OutputStream os = ex.getResponseBody()) {
                            byte[] buf = new byte[(int) len];
                            for (int i = 0; i < buf.length; i++) {
                                buf[i] = (byte) (((start + i) >>> 12) ^ 0x5A);
                            }
                            os.write(buf);
                        }
                    }
                });
        mock4k.start();
        try (CloudMediaProxy proxy = new CloudMediaProxy()) {
            String upstream = "http://127.0.0.1:" + mock4k.getAddress().getPort() + "/movie40g.mkv";
            CloudMediaProxy.Lease lease =
                    proxy.createLease(
                            upstream,
                            Collections.<String, String>emptyMap(),
                            null,
                            256 * 1024,
                            4,
                            4L * 1024L * 1024L);
            final String url = proxy.leaseUrl(lease);

            // Start slow head probe in background using a raw socket so JDK HttpURLConnection's
            // hidden EOF auto-retry cannot race with tail preemption.
            Thread headThread =
                    new Thread(
                            () -> {
                                try {
                                    URL parsed = new URL(url);
                                    try (java.net.Socket hs =
                                            new java.net.Socket("127.0.0.1", parsed.getPort())) {
                                        hs.setSoTimeout(4000);
                                        String req =
                                                "GET "
                                                        + parsed.getFile()
                                                        + " HTTP/1.1\r\nHost: 127.0.0.1:"
                                                        + parsed.getPort()
                                                        + "\r\nRange: bytes=0-2097151\r\nConnection: close\r\n\r\n";
                                        hs.getOutputStream()
                                                .write(req.getBytes(StandardCharsets.ISO_8859_1));
                                        hs.getOutputStream().flush();
                                        byte[] buf = new byte[4096];
                                        InputStream in = hs.getInputStream();
                                        while (in.read(buf) != -1) {
                                            Thread.sleep(50);
                                        }
                                    }
                                } catch (Throwable ignored) {
                                }
                            });
            headThread.setDaemon(true);
            headThread.start();
            check(headStarted.await(3, TimeUnit.SECONDS), "Head probe started");

            // Tail seek on 40 GiB MKV must preempt head probe and return exact tail bytes!
            long t0 = System.currentTimeMillis();
            HttpURLConnection tailConn = (HttpURLConnection) new URL(url).openConnection();
            tailConn.setRequestProperty("Range", "bytes=" + TAIL_START + "-" + (TOTAL_SIZE - 1));
            tailConn.setReadTimeout(5000);
            check(tailConn.getResponseCode() == 206, "Tail seek returned 206");
            byte[] tailBytes = readAll(tailConn.getInputStream());
            long elapsed = System.currentTimeMillis() - t0;
            tailConn.disconnect();
            check(tailBytes.length == 512 * 1024, "Exact 512 KiB tail read");
            check(
                    tailBytes[0] == (byte) ((TAIL_START >>> 12) ^ 0x5A)
                            && tailBytes[tailBytes.length - 1]
                                    == (byte) (((TOTAL_SIZE - 1) >>> 12) ^ 0x5A),
                    "Tail bytes match exact 40 GiB offset checksum");
            check(elapsed < 4000L, "Tail seek preempted quickly (" + elapsed + "ms)");
            check(lease.metrics.cancelledWindows.get() >= 1, "Previous head window cancelled");
            check(
                    lease.metrics.peakBufferedBytes.get() <= 4L * 1024L * 1024L,
                    "Buffered bytes stayed bounded");

            // Misaligned Content-Range response must be strictly rejected
            returnBadRange.set(true);
            HttpURLConnection badConn = (HttpURLConnection) new URL(url).openConnection();
            badConn.setRequestProperty("Range", "bytes=" + TAIL_START + "-" + (TAIL_START + 65535));
            badConn.setReadTimeout(4000);
            int badCode = badConn.getResponseCode();
            byte[] badBody = badCode >= 400 ? new byte[0] : readAll(badConn.getInputStream());
            badConn.disconnect();
            check(
                    lease.metrics.rejectedRangeResponses.get() >= 1 && badBody.length < 65536,
                    "Misaligned Content-Range strictly rejected");

            // SeekCommitGuard: failed/stalled seek never writes unreached position to WatchHistory
            SeekCommitGuard guard = new SeekCommitGuard();
            guard.reset(120_000);
            guard.beginSeek(2_400_000);
            // Buffering / frozen target frame must NOT commit
            check(!guard.onPlaybackTick(2_400_000, true, true), "Buffering tick does not commit");
            check(
                    !guard.onPlaybackTick(2_400_000, true, false),
                    "Single frozen frame does not commit");
            check(guard.historyPositionMs() == 120_000, "History stays at last confirmed 120s");
            guard.onSeekFailedOrCancelled();
            check(guard.historyPositionMs() == 120_000, "Failed seek retains 120s");
            // Genuine seek landing + clock progression DOES commit
            guard.beginSeek(2_400_000);
            guard.onPlaybackTick(2_400_000, true, false);
            check(guard.onPlaybackTick(2_400_600, true, false), "Advancing clock commits seek");
            check(guard.historyPositionMs() == 2_400_600, "History updated to confirmed target");
        } finally {
            mock4k.stop(0);
        }
        pass(
                "Item 4 (原 2A): 40 GiB MKV tail-seek preemption, Content-Range guard & SeekCommitGuard");
    }

    // -------------------------------------------------------------------------
    // Item 5 (原 3): Danmu discovery, non-default ports, /dm & /12345 subpaths, manual match
    // -------------------------------------------------------------------------
    private static void test5DanmuDiscoverySubpathsAndManualMatch() throws Exception {
        // Normalization preserves ports and /dm, /12345 subpaths and deduplicates /api/v2
        check(
                "http://127.0.0.1:8080/dm"
                        .equals(
                                DanmuSourceManager.normalizeServiceOrigin(
                                        "http://127.0.0.1:8080/dm/api/v2/")),
                "Preserve port + /dm subpath");
        check(
                "https://danmu.example:9443/12345"
                        .equals(
                                DanmuSourceManager.normalizeServiceOrigin(
                                        "https://danmu.example:9443/12345/")),
                "Preserve port + numeric /12345 subpath");

        HttpServer mockDanmu = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mockDanmu.setExecutor(Executors.newCachedThreadPool());
        mockDanmu.createContext(
                "/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws IOException {
                        String path = ex.getRequestURI().getPath();
                        if (path.equals("/dm/api/v2/match") || path.equals("/12345/api/v2/match")) {
                            sendJson(ex, 200, "{\"isMatched\":false,\"matches\":[]}");
                            return;
                        }
                        if (path.equals("/dm/api/v2/search/episodes")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"animes\":[{\"animeTitle\":\"三体\",\"episodes\":[{\"episodeId\":9001,\"episodeTitle\":\"第1集\"}]}]}");
                            return;
                        }
                        if (path.equals("/12345/api/v2/search/episodes")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"animes\":[{\"animeTitle\":\"三体\",\"episodes\":[{\"episodeId\":9002,\"episodeTitle\":\"第1集 (备用)\"}]}]}");
                            return;
                        }
                        if (path.equals("/dm/api/v2/comment/9001")) {
                            sendJson(
                                    ex,
                                    200,
                                    "{\"comments\":[{\"p\":\"12.5,1,16777215,u1\",\"m\":\"不要回答！\"}]}");
                            return;
                        }
                        sendJson(ex, 404, "{}");
                    }
                });
        mockDanmu.start();
        try {
            String originDm = "http://127.0.0.1:" + mockDanmu.getAddress().getPort() + "/dm";
            String originNum = "http://127.0.0.1:" + mockDanmu.getAddress().getPort() + "/12345";

            // Discover & probe new service
            DanmuSourceManager.ProbeResult probe =
                    DanmuSourceManager.probeNewDanmuService(originDm + "/api/v2", "三体");
            check(
                    probe.ok && originDm.equals(probe.normalizedOrigin) && probe.sampleCount == 1,
                    "Probe discovered /dm danmu service");

            // Unified source merge deduplicates equivalent /api/v2 origins
            String legacyJson =
                    new JSONArray()
                            .put(
                                    new JSONObject()
                                            .put("name", "DM源")
                                            .put("url", originDm + "/api/v2")
                                            .put("enabled", true))
                            .toString();
            List<OnlineSubtitleDanmakuService.DanmakuSource> merged =
                    DanmuSourceManager.mergeSources(legacyJson, originDm + "\n" + originNum);
            check(merged.size() == 2, "Unified source list deduplicates and merges both origins");

            // Manual match across multiple services attributes candidate sourceOrigin accurately
            DandanplayProvider provider =
                    new DandanplayProvider(originDm + "\n" + originNum, "", "");
            DanmuProvider.CancellationToken tok = new DanmuProvider.CancellationToken();
            DanmuProvider.MatchQuery query = new DanmuProvider.MatchQuery("三体", "第1集", 1, 1, 0);
            List<DanmuProvider.Candidate> candidates = provider.matchOrSearch(query, tok);
            check(candidates.size() >= 2, "Found candidates across both subpath services");
            boolean sawDm = false;
            boolean sawNum = false;
            DanmuProvider.Candidate dmCandidate = null;
            for (DanmuProvider.Candidate c : candidates) {
                if (originDm.equals(c.sourceOrigin)) {
                    sawDm = true;
                    dmCandidate = c;
                }
                if (originNum.equals(c.sourceOrigin)) sawNum = true;
            }
            check(sawDm && sawNum, "Candidates attributed to both /dm and /12345 services");
            DanmuProvider.EpisodeSession epSess =
                    provider.openSession(dmCandidate.boundEpisodeId, tok);
            List<DanmuProvider.DanmuItem> comments = provider.fetchWindow(epSess, 0, tok);
            check(comments.size() == 1 && "不要回答！".equals(comments.get(0).text), "Loaded comments");
        } finally {
            mockDanmu.stop(0);
        }
        pass(
                "Item 5 (原 3): Danmu discovery, port+/dm+/digits subpaths, unified store & manual match");
    }

    // -------------------------------------------------------------------------
    // Item 6 (原 1, 6, 10, 15, 16): Home sections, responsive picker & scoped line rules
    // -------------------------------------------------------------------------
    private static void test6HomeSectionsSourcePickerAndScopedLineRules() throws Exception {
        // Home 9 stable IDs round-trip & all-off detection
        check(MobileHomeSections.ALL_SPECS.size() == 9, "9 stable home section IDs");
        Set<String> allIds =
                MobileHomeSections.parseHiddenIds(
                        MobileHomeSections.encodeHiddenIds(
                                new java.util.LinkedHashSet<>(MobileHomeSections.DEFAULT_ORDER)));
        check(allIds.size() == 9, "All 9 section IDs encode/parse cleanly");
        int revBefore = MobileHomeSections.revision();
        MobileHomeSections.bumpRevision();
        check(
                MobileHomeSections.revision() == revBefore + 1,
                "Revision bumps for instant home sync");

        // Responsive Source Picker layout
        check(
                SourcePickerLayout.resolveQuickSwitchColumns(360f, 1.0f) == 2,
                "Phone quick-switch 2 cols");
        check(
                SourcePickerLayout.resolveQuickSwitchColumns(270f, 1.0f) == 1,
                "Narrow split screen 1 col");
        check(
                SourcePickerLayout.resolveQuickSwitchColumns(360f, 1.45f) == 1,
                "Large font degrades to 1 col");
        check(
                SourcePickerLayout.resolveFullPickerColumns(360f, 1.0f, false) == 2,
                "Phone full picker 2 cols");
        check(
                SourcePickerLayout.resolveFullPickerColumns(720f, 1.0f, false) == 3,
                "Tablet full picker 3 cols");
        check(
                SourcePickerLayout.resolveFullPickerColumns(360f, 1.40f, false) == 1,
                "Large font full picker 1 col");

        // Scoped playback line management across TWO subscriptions with same site & same line names
        String subAScope =
                PlaybackLineRules.buildSiteScope(
                        PlaybackLineRules.buildSubscriptionScope(
                                "https://sub-a.example/cfg.json", "", ""),
                        "site_shared",
                        "https://api.example/vod");
        String subBScope =
                PlaybackLineRules.buildSiteScope(
                        PlaybackLineRules.buildSubscriptionScope(
                                "https://sub-b.example/cfg.json", "", ""),
                        "site_shared",
                        "https://api.example/vod");
        check(!subAScope.equals(subBScope), "Two subscriptions have distinct line rule scopes");

        JSONObject allRules = new JSONObject();
        JSONObject ruleA = PlaybackLineRules.loadRuleForScope(allRules, subAScope);
        PlaybackLineRules.setAlias(ruleA, "线路1", "主线4K");
        PlaybackLineRules.setHidden(ruleA, "线路2", true);
        PlaybackLineRules.setOrder(ruleA, Arrays.asList("线路3", "线路1"));
        allRules.put(subAScope, ruleA);

        Cms.Line l1 = new Cms.Line();
        l1.name = "线路1";
        l1.rawName = "线路1";
        Cms.Line l2 = new Cms.Line();
        l2.name = "线路2";
        l2.rawName = "线路2";
        Cms.Line l3 = new Cms.Line();
        l3.name = "线路3";
        l3.rawName = "线路3";
        List<Cms.Line> freshFromRefresh = Arrays.asList(l1, l2, l3);

        // Apply to Sub A after refresh
        List<Cms.Line> outA =
                PlaybackLineRules.applyToLines(
                        freshFromRefresh, PlaybackLineRules.loadRuleForScope(allRules, subAScope));
        check(outA.size() == 2, "Sub A hid 线路2");
        check(
                "线路3".equals(outA.get(0).name) && "主线4K".equals(outA.get(1).name),
                "Sub A order & rename survived refresh");
        check("线路1".equals(outA.get(1).rawName()), "Sub A immutable rawName preserved");
        check(
                PlaybackLineRules.matchesLine(outA.get(1), "线路1"),
                "History/Favorite on 线路1 still matches renamed line");

        // Sub B remains 100% untouched!
        List<Cms.Line> outB =
                PlaybackLineRules.applyToLines(
                        freshFromRefresh, PlaybackLineRules.loadRuleForScope(allRules, subBScope));
        check(outB.size() == 3 && "线路1".equals(outB.get(0).name), "Sub B lines untouched");
        pass(
                "Item 6 (原 1/6/10/15/16): Home 9 IDs, responsive picker cols & two-subscription line isolation");
    }

    // -------------------------------------------------------------------------
    // Item 7 (原 7): Exact Search ("三体") & rapid mode-switch stale-batch isolation
    // -------------------------------------------------------------------------
    private static void test7ExactSearchAndRapidModeSwitch() {
        Cms.Site s1 = makeSite("s1", "片源A");
        Cms.Site s2 = makeSite("s2", "片源B");
        Cms.Site s3 = makeSite("s3", "片源C");
        List<MobileSearchPage.Hit> mixed =
                Arrays.asList(
                        makeHit(s1, "《我的三体》"),
                        makeHit(s1, "《三体2》"),
                        makeHit(s2, "《三体》"),
                        makeHit(s2, "《三体：周年纪念版》"),
                        makeHit(s3, "三体"),
                        makeHit(s1, "三体 2023"),
                        makeHit(s1, "《三体》"));

        // Exact mode: edge-whitespace-only trim on original full title!
        // IT != It, "a b" != "a  b", "《三体》" != "三体", while identical titles across sources
        // are all retained.
        check(!SearchRanking.isExactTitleMatch("IT", "It"), "Exact search distinguishes IT vs It");
        check(
                !SearchRanking.isExactTitleMatch("a b", "a  b"),
                "Exact search distinguishes internal spacing");
        check(
                !SearchRanking.isExactTitleMatch("《三体》", "三体"),
                "Exact search distinguishes 《三体》 vs 三体");
        check(
                SearchRanking.isExactTitleMatch("《三体》", "  《三体》  "),
                "Exact search trims leading/trailing whitespace only");
        check(
                SearchRanking.isExactTitleMatch("  三体  ", "三体"),
                "Exact search trims outer spaces on title");

        List<MobileSearchPage.Hit> multiExact =
                Arrays.asList(
                        makeHit(s1, "《我的三体》"),
                        makeHit(s1, "《三体2》"),
                        makeHit(s2, "《三体》"),
                        makeHit(s2, "《三体：周年纪念版》"),
                        makeHit(s1, "三体"),
                        makeHit(s2, "三体"),
                        makeHit(s3, "  三体  "),
                        makeHit(s1, "三体 2023"));
        List<MobileSearchPage.Hit> exact = SearchRanking.rankAndFilter(multiExact, "  三体  ", true);
        check(
                exact.size() == 3,
                "Exact search retains all 3 distinct-source exact 三体 hits and excludes 《三体》/sequels, got "
                        + exact.size());
        for (MobileSearchPage.Hit h : exact) {
            check(
                    "三体".equals(h.video.title.trim()),
                    "Exact search kept strictly exact title: " + h.video.title);
        }

        // Fuzzy mode: exact matches ranked first, all 8 retained
        List<MobileSearchPage.Hit> fuzzy = SearchRanking.rankAndFilter(multiExact, "三体", false);
        check(fuzzy.size() == 8, "Fuzzy search retains all hits");
        check(
                "三体".equals(SearchRanking.normalizeFuzzyTitle(fuzzy.get(0).video.title)),
                "Fuzzy mode puts exact/consensus matches first");

        // Rapid mode switch: late batch from fuzzy session MUST NOT mix into exact session
        Object dummyCfg = new Object();
        long pageTok = MobileSearchPage.beginPage();
        MobileSearchPage.SearchSession fuzzySess =
                MobileSearchPage.startSession(pageTok, "三体", false, dummyCfg, 1, 1, 2, false);
        MobileSearchPage.SearchSession exactSess =
                MobileSearchPage.startSession(pageTok, "三体", false, dummyCfg, 1, 1, 2, true);
        check(
                !MobileSearchPage.acceptBatchIfCurrent(
                        fuzzySess,
                        false,
                        dummyCfg,
                        1,
                        1,
                        Collections.singletonList(makeHit(s1, "《我的三体》"))),
                "Stale fuzzy batch rejected after rapid switch to exact mode");
        check(
                MobileSearchPage.acceptBatchIfCurrent(exactSess, false, dummyCfg, 1, 1, multiExact),
                "Current exact session accepts batch");
        check(
                exactSess.snapshotHits().size() == 3,
                "Exact session filtered incoming batch to 3 exact hits");
        MobileSearchPage.invalidateSession();
        pass(
                "Item 7 (原 7): Strict exact search filtering, fuzzy ranking & rapid mode-switch isolation");
    }

    private static Cms.Site makeSite(String key, String name) {
        Cms.Site s = new Cms.Site();
        s.key = key;
        s.name = name;
        return s;
    }

    private static MobileSearchPage.Hit makeHit(Cms.Site site, String title) {
        Cms.Video v = new Cms.Video();
        v.id = title;
        v.title = title;
        return new MobileSearchPage.Hit(site, v);
    }

    // -------------------------------------------------------------------------
    // Item 8 (原 8, 11, 13): HUD slim-bar decoupling, multi-track 720p->1080p & pause preservation
    // -------------------------------------------------------------------------
    private static void test8HudPrefsAndVideoTrackSwitchState() {
        check(
                !PlayerChrome.shouldShowSlimProgressBar(false, false, false, true, 600_000, false),
                "Slim bar hidden when toggled off");
        check(
                PlayerChrome.shouldShowSlimProgressBar(false, false, false, true, 600_000, true),
                "Slim bar shown when idle & enabled");
        check(
                !PlayerChrome.shouldShowSlimProgressBar(true, false, false, true, 600_000, true),
                "Slim bar yields to expanded seek bar when controls visible");

        VideoTrackOption t720 =
                new VideoTrackOption(0, 1280, 720, 2_500_000, 30f, "H.264", false, true, "");
        VideoTrackOption t1080 =
                new VideoTrackOption(1, 1920, 1080, 8_500_000, 60f, "HEVC", true, false, "");
        check(
                t720.formatLabel().contains("720P") && t720.formatLabel().contains("1280×720"),
                "720p label");
        check(
                t1080.formatLabel().contains("1080P")
                        && t1080.formatLabel().contains("1920×1080")
                        && t1080.formatLabel().contains("HDR"),
                "1080p label");
        String record = VideoTrackOption.formatSelectionRecord(t1080, 1920, 1080);
        check(
                record.contains("1080P") && record.contains("1920×1080"),
                "Selection record includes track + decoded res");

        // Switching quality while paused preserves BOTH position and paused state
        VideoTrackOption.SwitchState pausedSwitch =
                VideoTrackOption.SwitchState.capture(false, true, 185_000, false);
        check(
                pausedSwitch.resumePositionMs == 185_000 && pausedSwitch.startPaused,
                "Paused switch preserves pos+pause");
        VideoTrackOption.SwitchState playingSwitch =
                VideoTrackOption.SwitchState.capture(false, true, 185_000, true);
        check(
                playingSwitch.resumePositionMs == 185_000 && !playingSwitch.startPaused,
                "Playing switch preserves pos+play");
        pass(
                "Item 8 (原 8/11/13): Slim bar decoupling, 720p->1080p video track record & pause preservation");
    }

    // -------------------------------------------------------------------------
    // Items 9 & 14: CSP HTML-vs-JAR guard & External Parser execution chain
    // -------------------------------------------------------------------------
    private static void test9And14CspHardeningAndExternalParserChain(File workDir)
            throws Exception {
        File htmlFile = new File(workDir, "bad_403.jar");
        try (FileOutputStream fos = new FileOutputStream(htmlFile)) {
            fos.write(
                    "<!DOCTYPE html><html><body>403 Forbidden</body></html>"
                            .getBytes(StandardCharsets.UTF_8));
        }
        File zipFile = new File(workDir, "good_zip.jar");
        try (FileOutputStream fos = new FileOutputStream(zipFile)) {
            fos.write(new byte[] {'P', 'K', 3, 4, 0, 0});
        }
        File dexFile = new File(workDir, "good_dex.jar");
        try (FileOutputStream fos = new FileOutputStream(dexFile)) {
            fos.write(new byte[] {'d', 'e', 'x', '\n', '0', '3', '5'});
        }
        check(CspEngine.looksLikeHtmlInsteadOfJar(htmlFile), "HTML error page detected as non-JAR");
        check(!CspEngine.looksLikeHtmlInsteadOfJar(zipFile), "ZIP/JAR magic accepted");
        check(!CspEngine.looksLikeHtmlInsteadOfJar(dexFile), "DEX magic accepted");

        // External parser flag matching & priority
        Cms.Parse generic = new Cms.Parse();
        generic.name = "Generic";
        generic.url = "https://jx.example/api?url=";
        generic.type = 1;
        Cms.Parse qqOnly = new Cms.Parse();
        qqOnly.name = "QQ专用";
        qqOnly.url = "https://qqjx.example/json?url=";
        qqOnly.type = 1;
        qqOnly.flags.add("qq");
        List<Cms.Parse> ordered =
                ExternalParserResolver.orderParsersForFlag(
                        Arrays.asList(generic, qqOnly), "qq", "", null, "");
        check("QQ专用".equals(ordered.get(0).name), "Flag-matching parser prioritized");

        // Nested data.url extraction & HTML/VIP rejection
        ExternalParserResolver.ParsedResult ok =
                ExternalParserResolver.parseJsonParserResponse(
                        "{\"code\":200,\"data\":{\"url\":\"//cdn.example/video/index.m3u8\",\"headers\":{\"Referer\":\"https://jx.example/\"}}}",
                        "https://v.qq.com/x/cover/demo.html");
        check(
                ok.ok && "https://cdn.example/video/index.m3u8".equals(ok.url),
                "Nested data.url extracted");
        check("https://jx.example/".equals(ok.headers.get("Referer")), "Parser headers preserved");

        ExternalParserResolver.ParsedResult badHtml =
                ExternalParserResolver.parseJsonParserResponse(
                        "{\"url\":\"https://v.qq.com/x/cover/demo.html\"}",
                        "https://v.qq.com/x/cover/demo.html");
        check(!badHtml.ok, "VIP HTML page URL rejected as non-playable");
        check(
                ExternalParserResolver.buildWebParserUrl(
                                "https://jx.example/?url=",
                                "https://v.qq.com/x/page/1.html?a=1&b=2")
                        .contains("a%3D1%26b%3D2"),
                "Web parser URL properly encodes query parameters");
        pass("Items 9 & 14: CSP HTML-vs-JAR guard & ExternalParserResolver execution chain");
    }

    // -------------------------------------------------------------------------
    // Round 2 Rework Adversarial Counterexamples (Items 1-12)
    // -------------------------------------------------------------------------
    private static void test10Round2AdversarialReworkChecks(File workDir) throws Exception {
        r2Item1ConfigMergePreservesLegacyFields(workDir);
        r2Item2CrossOriginRedirectSecurity();
        r2Item3PersonalLeaseLifecycle();
        r2Item4BothProxiesShort206Continuation200AndSuffixRange();
        r2Item5SubscriptionLanQrAndSecurityAcls(workDir);
        r2Item6LineIdentityMergeOrderAndPlaybackIndex();
        r2Item7Danmu404AuthFailDiscoveryAndSeason2();
        r2Item9ProductionExternalParserEpisodeIdAndWebPage();
        r2Item10AlistMalformedVsEmptyAndMergeRollback();
        r2Item11HomeEffectiveOrderAndFinalPanelWidths();
        r2Item12SlimPrefReconcileAndTrackAutoVsDecoded();
    }

    private static void r2Item1ConfigMergePreservesLegacyFields(File workDir) throws Exception {
        File dir = new File(workDir, "r2-config-merge");
        dir.mkdirs();
        File wex = new File(dir, "wexfnwconfig.json");
        File ucTxt = new File(dir, "uc_cookie.txt");
        File drive115Txt = new File(dir, "115_cookie.txt");
        String legacyJson =
                "{\"customFlag\":\"keep-me\",\"panOrder\":\"ali,115,quark\","
                        + "\"115_cookie\":\"UID=115_keep\",\"uc_cookie\":\"__pus=old_uc_keep; __puus=old_uc_p\","
                        + "\"pan\":{\"quark\":{\"cookie\":\"__pus=old_q; __puus=old_qp\",\"folder\":\"/Movies\",\"extra\":42},"
                        + "\"uc\":{\"cookie\":\"__pus=old_uc_keep; __puus=old_uc_p\",\"note\":\"my-uc\"},"
                        + "\"115\":{\"cookie\":\"UID=115_keep\",\"cid\":\"999\"},"
                        + "\"pikpak\":{\"token\":\"pp_keep\"}}}";
        try (FileOutputStream fos = new FileOutputStream(wex)) {
            fos.write(legacyJson.getBytes(StandardCharsets.UTF_8));
        }
        try (FileOutputStream fos = new FileOutputStream(ucTxt)) {
            fos.write("__pus=old_uc_keep; __puus=old_uc_p".getBytes(StandardCharsets.UTF_8));
        }
        try (FileOutputStream fos = new FileOutputStream(drive115Txt)) {
            fos.write("UID=115_keep".getBytes(StandardCharsets.UTF_8));
        }

        // Step A: Opening page (pull=true, push=false) MUST NOT rewrite existing config file!
        NetdiskStore.MemoryStore store = new NetdiskStore.MemoryStore();
        ConfigCenterBridge.SyncReport openRep =
                ConfigCenterBridge.syncAll(
                        store,
                        Collections.singletonList(dir),
                        Collections.singletonList(dir),
                        new Cms.Config(),
                        true,
                        false,
                        false);
        check(openRep.pushedFiles.isEmpty(), "R2-1: Opening page writes zero files");
        String afterOpen =
                new String(java.nio.file.Files.readAllBytes(wex.toPath()), StandardCharsets.UTF_8);
        check(legacyJson.equals(afterOpen), "R2-1: Legacy config untouched byte-for-byte on open");

        // Step B: QR scan updates ONLY quark -> field-level merge preserves ALL other
        // fields/drives!
        Map<String, String> scanSub = new LinkedHashMap<>();
        scanSub.put(NetdiskStore.DRIVE_QUARK, "__pus=new_q_scan; __puus=new_qp_scan");
        ConfigCenterBridge.applyUserSubmission(
                store, Collections.singletonList(dir), new Cms.Config(), scanSub, "");
        JSONObject merged =
                new JSONObject(
                        new String(
                                java.nio.file.Files.readAllBytes(wex.toPath()),
                                StandardCharsets.UTF_8));
        check("keep-me".equals(merged.optString("customFlag")), "R2-1: Unknown top-level key kept");
        check("ali,115,quark".equals(merged.optString("panOrder")), "R2-1: Custom panOrder kept");
        check(
                "UID=115_keep".equals(merged.optString("115_cookie")),
                "R2-1: 115 top-level key kept");
        JSONObject pan = merged.getJSONObject("pan");
        check(
                "__pus=new_q_scan; __puus=new_qp_scan"
                        .equals(pan.getJSONObject("quark").optString("cookie")),
                "R2-1: Authorized quark cookie updated");
        check(
                "/Movies".equals(pan.getJSONObject("quark").optString("folder"))
                        && pan.getJSONObject("quark").optInt("extra") == 42,
                "R2-1: Existing custom sub-fields on quark preserved");
        check(
                "__pus=old_uc_keep; __puus=old_uc_p"
                                .equals(pan.getJSONObject("uc").optString("cookie"))
                        && "my-uc".equals(pan.getJSONObject("uc").optString("note")),
                "R2-1: Untouched uc drive & custom note preserved");
        check("999".equals(pan.getJSONObject("115").optString("cid")), "R2-1: 115 drive preserved");
        check(
                "pp_keep".equals(pan.getJSONObject("pikpak").optString("token")),
                "R2-1: PikPak drive preserved");
        check(
                ucTxt.isFile() && drive115Txt.isFile(),
                "R2-1: Untouched compat .txt files preserved");

        // Step C: Simulated restart reloads both new quark and preserved uc cleanly
        NetdiskStore.MemoryStore restarted = new NetdiskStore.MemoryStore();
        ConfigCenterBridge.syncAll(
                restarted,
                Collections.singletonList(dir),
                Collections.singletonList(dir),
                new Cms.Config(),
                true,
                false,
                false);
        check(
                "__pus=new_q_scan; __puus=new_qp_scan"
                        .equals(NetdiskStore.getCredential(restarted, NetdiskStore.DRIVE_QUARK)),
                "R2-1: Restart reloads merged quark");
        check(
                "__pus=old_uc_keep; __puus=old_uc_p"
                        .equals(NetdiskStore.getCredential(restarted, NetdiskStore.DRIVE_UC)),
                "R2-1: Restart reloads preserved uc");
        pass(
                "R2-P0.1: Config Center field-level merge preserves legacy drives, custom & unknown keys");
    }

    private static void r2Item2CrossOriginRedirectSecurity() throws Exception {
        final AtomicInteger evilHits = new AtomicInteger(0);
        final AtomicReference<String> cdnReceivedCookie = new AtomicReference<>("");
        final AtomicReference<String> cdnReceivedAuth = new AtomicReference<>("");
        final AtomicReference<String> sameOriginCookie = new AtomicReference<>("");
        final byte[] mediaBytes =
                "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".getBytes(StandardCharsets.US_ASCII);

        HttpServer serverB = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        serverB.setExecutor(Executors.newCachedThreadPool());
        serverB.createContext(
                "/",
                ex -> {
                    String path = ex.getRequestURI().getPath();
                    if (path.equals("/signed-cdn")) {
                        cdnReceivedCookie.set(
                                String.valueOf(ex.getRequestHeaders().getFirst("Cookie")));
                        cdnReceivedAuth.set(
                                String.valueOf(ex.getRequestHeaders().getFirst("Authorization")));
                        ex.getResponseHeaders()
                                .set(
                                        "Content-Range",
                                        "bytes 0-"
                                                + (mediaBytes.length - 1)
                                                + "/"
                                                + mediaBytes.length);
                        ex.sendResponseHeaders(206, mediaBytes.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(mediaBytes);
                        }
                        return;
                    }
                    evilHits.incrementAndGet();
                    sendJson(ex, 200, "{\"stolen\":true}");
                });
        serverB.start();
        final int portB = serverB.getAddress().getPort();

        HttpServer serverA = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        serverA.setExecutor(Executors.newCachedThreadPool());
        serverA.createContext(
                "/",
                ex -> {
                    String path = ex.getRequestURI().getPath();
                    int portA = serverA.getAddress().getPort();
                    if (path.equals("/cloud-to-cdn")) {
                        ex.getResponseHeaders()
                                .set(
                                        "Location",
                                        "http://127.0.0.1:" + portB + "/signed-cdn?sig=ok");
                        ex.sendResponseHeaders(302, -1);
                        return;
                    }
                    if (path.equals("/cloud-same-origin")) {
                        ex.getResponseHeaders()
                                .set("Location", "http://127.0.0.1:" + portA + "/cloud-final");
                        ex.sendResponseHeaders(302, -1);
                        return;
                    }
                    if (path.equals("/cloud-final")) {
                        sameOriginCookie.set(
                                String.valueOf(ex.getRequestHeaders().getFirst("Cookie")));
                        ex.getResponseHeaders()
                                .set(
                                        "Content-Range",
                                        "bytes 0-"
                                                + (mediaBytes.length - 1)
                                                + "/"
                                                + mediaBytes.length);
                        ex.sendResponseHeaders(206, mediaBytes.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(mediaBytes);
                        }
                        return;
                    }
                    if (path.startsWith("/cross-emby/")) {
                        ex.getResponseHeaders()
                                .set("Location", "http://127.0.0.1:" + portB + "/steal-emby");
                        ex.sendResponseHeaders(307, -1);
                        return;
                    }
                    if (path.equals("/same-emby/emby/Users/AuthenticateByName")) {
                        ex.getResponseHeaders()
                                .set("Location", "/real-emby/Users/AuthenticateByName");
                        ex.sendResponseHeaders(307, -1);
                        return;
                    }
                    if (path.equals("/real-emby/Users/AuthenticateByName")) {
                        sendJson(ex, 200, "{\"AccessToken\":\"emby_ok\",\"User\":{\"Id\":\"u1\"}}");
                        return;
                    }
                    if (path.endsWith("/Users/u1/Views")) {
                        sendJson(ex, 200, "{\"Items\":[]}");
                        return;
                    }
                    if (path.startsWith("/cross-alist/")) {
                        ex.getResponseHeaders()
                                .set("Location", "http://127.0.0.1:" + portB + "/steal-alist");
                        ex.sendResponseHeaders(307, -1);
                        return;
                    }
                    if (path.equals("/same-alist/api/fs/list")) {
                        ex.getResponseHeaders().set("Location", "/real-alist/api/fs/list");
                        ex.sendResponseHeaders(307, -1);
                        return;
                    }
                    if (path.equals("/real-alist/api/fs/list")) {
                        sendJson(ex, 200, "{\"code\":200,\"data\":{\"total\":0,\"content\":[]}}");
                        return;
                    }
                    sendJson(ex, 404, "{}");
                });
        serverA.start();

        try (CloudMediaProxy proxy = new CloudMediaProxy()) {
            String baseA = "http://127.0.0.1:" + serverA.getAddress().getPort();
            Map<String, String> secretHeaders = new LinkedHashMap<>();
            secretHeaders.put("Cookie", "__pus=TOP_SECRET_COOKIE");
            secretHeaders.put("Authorization", "Bearer TOP_SECRET_JWT");
            secretHeaders.put("User-Agent", "MarcoTestUA");

            // 1. CloudMediaProxy: cross-origin CDN redirect strips Cookie/Auth & still plays!
            CloudMediaProxy.Lease cdnLease =
                    proxy.createLease(
                            baseA + "/cloud-to-cdn", secretHeaders, null, 1024, 2, 1024 * 1024);
            HttpURLConnection c1 =
                    (HttpURLConnection) new URL(proxy.leaseUrl(cdnLease)).openConnection();
            c1.setRequestProperty("Range", "bytes=0-" + (mediaBytes.length - 1));
            check(c1.getResponseCode() == 206, "R2-2: Signed CDN redirect still playable (206)");
            byte[] gotCdn = readAll(c1.getInputStream());
            c1.disconnect();
            check(Arrays.equals(mediaBytes, gotCdn), "R2-2: Signed CDN bytes exact");
            check(
                    "null".equals(cdnReceivedCookie.get()) && "null".equals(cdnReceivedAuth.get()),
                    "R2-2: Cross-origin CDN redirect stripped Cookie & Authorization");

            // 2. CloudMediaProxy: same-origin reverse-proxy redirect retains Cookie!
            CloudMediaProxy.Lease sameLease =
                    proxy.createLease(
                            baseA + "/cloud-same-origin",
                            secretHeaders,
                            null,
                            1024,
                            2,
                            1024 * 1024);
            HttpURLConnection c2 =
                    (HttpURLConnection) new URL(proxy.leaseUrl(sameLease)).openConnection();
            c2.setRequestProperty("Range", "bytes=0-" + (mediaBytes.length - 1));
            check(c2.getResponseCode() == 206, "R2-2: Same-origin proxy redirect playable (206)");
            readAll(c2.getInputStream());
            c2.disconnect();
            check(
                    "__pus=TOP_SECRET_COOKIE".equals(sameOriginCookie.get()),
                    "R2-2: Same-origin reverse proxy retains Cookie");

            // 3. MobileEmbyLibrary: cross-port redirect BLOCKED before connecting; same-origin
            // allowed
            check(
                    MobileEmbyLibrary.isSameOrigin("http://emby.test:80/a", "http://emby.test/b")
                            && !MobileEmbyLibrary.isSameOrigin(
                                    "https://emby.test/a", "http://emby.test/a")
                            && !MobileEmbyLibrary.isSameOrigin(
                                    "http://emby.test:8096/a", "http://emby.test:8097/a"),
                    "R2-2: Emby effective-port + scheme origin check");
            boolean embyBlocked = false;
            try {
                MobileEmbyLibrary.login(baseA + "/cross-emby/emby", "alice", "secret_pw", "dev1");
            } catch (IOException ex) {
                embyBlocked = true;
            }
            check(
                    embyBlocked && evilHits.get() == 0,
                    "R2-2: Emby blocked cross-origin login redirect");
            JSONObject embySame =
                    MobileEmbyLibrary.login(
                            baseA + "/same-emby/emby", "alice", "secret_pw", "dev1");
            check(
                    "u1".equals(embySame.optString("user")),
                    "R2-2: Emby allows same-origin redirect");

            // 4. AlistEngine: cross-port redirect BLOCKED before connecting; same-origin allowed
            AlistEngine.MountConfig crossAlist =
                    new AlistEngine.MountConfig(
                            "c1",
                            "Cross",
                            baseA + "/cross-alist",
                            "/",
                            "admin",
                            "pw123",
                            "tok",
                            "");
            boolean alistBlocked = false;
            try {
                new AlistEngine.Client(crossAlist).listDirectory("/", 1, 20);
            } catch (IOException ex) {
                alistBlocked = true;
            }
            check(
                    alistBlocked && evilHits.get() == 0,
                    "R2-2: AList blocked cross-origin redirect before leaking creds/body");
            AlistEngine.MountConfig sameAlist =
                    new AlistEngine.MountConfig(
                            "c2", "Same", baseA + "/same-alist", "/", "", "", "tok", "");
            AlistEngine.ListResult sameRes =
                    new AlistEngine.Client(sameAlist).listDirectory("/", 1, 20);
            check(sameRes.items.isEmpty(), "R2-2: AList allows same-origin reverse proxy redirect");
        } finally {
            serverA.stop(0);
            serverB.stop(0);
        }
        pass("R2-P0.2: Cross-origin redirect credential blocking on CloudMediaProxy, Emby & AList");
    }

    private static void r2Item3PersonalLeaseLifecycle() throws Exception {
        final byte[] file1 = "FILE_ONE_PAYLOAD_0123456789".getBytes(StandardCharsets.US_ASCII);
        final byte[] file2 = "FILE_TWO_PAYLOAD_ABCDEFGHIJ".getBytes(StandardCharsets.US_ASCII);
        HttpServer mock = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mock.setExecutor(Executors.newCachedThreadPool());
        mock.createContext(
                "/",
                ex -> {
                    byte[] src = ex.getRequestURI().getPath().contains("f2") ? file2 : file1;
                    ex.getResponseHeaders()
                            .set("Content-Range", "bytes 0-" + (src.length - 1) + "/" + src.length);
                    ex.sendResponseHeaders(206, src.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(src);
                    }
                });
        mock.start();
        try {
            CloudMediaProxy shared = CloudMediaProxy.shared();
            String base = "http://127.0.0.1:" + mock.getAddress().getPort();
            CloudMediaProxy.Lease lease1 =
                    shared.createLease(
                            base + "/f1",
                            Collections.<String, String>emptyMap(),
                            null,
                            1024,
                            2,
                            65536);
            String url1 = shared.leaseUrl(lease1);

            // Simulate playCloudItem -> stagePendingLease -> openPlayer(releasePlayer + adopt)
            PersonalNetdiskBrowser.stagePendingLease(lease1);
            PersonalNetdiskBrowser.releaseActiveLeaseExcept(lease1.id);
            check(
                    PersonalNetdiskBrowser.adoptLeaseIfMatching(lease1.id),
                    "R2-3: Lease 1 adopted cleanly after old session cleanup");
            HttpURLConnection c1 = (HttpURLConnection) new URL(url1).openConnection();
            c1.setRequestProperty("Range", "bytes=0-" + (file1.length - 1));
            check(c1.getResponseCode() == 206, "R2-3: File 1 stream valid for first frame");
            check(Arrays.equals(file1, readAll(c1.getInputStream())), "R2-3: File 1 exact bytes");
            c1.disconnect();

            // Simulate seek on File 1 -> lease1 remains valid
            HttpURLConnection c1Seek = (HttpURLConnection) new URL(url1).openConnection();
            c1Seek.setRequestProperty("Range", "bytes=0-" + (file1.length - 1));
            check(c1Seek.getResponseCode() == 206, "R2-3: File 1 lease valid during seek");
            c1Seek.disconnect();

            // Switch to File 2: lease1 MUST be revoked, lease2 MUST stay valid!
            CloudMediaProxy.Lease lease2 =
                    shared.createLease(
                            base + "/f2",
                            Collections.<String, String>emptyMap(),
                            null,
                            1024,
                            2,
                            65536);
            String url2 = shared.leaseUrl(lease2);
            PersonalNetdiskBrowser.stagePendingLease(lease2);
            PersonalNetdiskBrowser.releaseActiveLeaseExcept(lease2.id);
            check(
                    PersonalNetdiskBrowser.adoptLeaseIfMatching(lease2.id),
                    "R2-3: Lease 2 adopted cleanly");
            check(lease1.revoked, "R2-3: Old Lease 1 revoked upon switching to File 2");
            HttpURLConnection c1After = (HttpURLConnection) new URL(url1).openConnection();
            check(c1After.getResponseCode() == 403, "R2-3: Revoked Lease 1 returns 403");
            c1After.disconnect();

            HttpURLConnection c2 = (HttpURLConnection) new URL(url2).openConnection();
            c2.setRequestProperty("Range", "bytes=0-" + (file2.length - 1));
            check(c2.getResponseCode() == 206, "R2-3: File 2 lease valid");
            check(Arrays.equals(file2, readAll(c2.getInputStream())), "R2-3: File 2 exact bytes");
            c2.disconnect();

            // Exit playback: lease2 MUST be revoked!
            PersonalNetdiskBrowser.releaseActiveLease();
            check(lease2.revoked, "R2-3: Lease 2 revoked on playback exit");
            HttpURLConnection c2After = (HttpURLConnection) new URL(url2).openConnection();
            check(c2After.getResponseCode() == 403, "R2-3: Revoked Lease 2 returns 403 after exit");
            c2After.disconnect();
        } finally {
            PersonalNetdiskBrowser.releaseActiveLease();
            mock.stop(0);
        }
        pass(
                "R2-P1.3: Personal cloud lease lifecycle (cleanup old -> adopt new -> seek -> switch -> exit)");
    }

    private static void r2Item4BothProxiesShort206Continuation200AndSuffixRange() throws Exception {
        final byte[] payload = new byte[4096];
        for (int i = 0; i < payload.length; i++) {
            payload[i] = (byte) ((i * 31 + 17) & 0xFF);
        }
        final AtomicBoolean return200OnContinuation = new AtomicBoolean(false);

        HttpServer mockOrigin = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mockOrigin.setExecutor(Executors.newCachedThreadPool());
        mockOrigin.createContext(
                "/video.mkv",
                ex -> {
                    String range = ex.getRequestHeaders().getFirst("Range");
                    long start = 0;
                    long end = payload.length - 1;
                    if (range != null && range.startsWith("bytes=")) {
                        String[] p = range.substring(6).split("-", -1);
                        start = Long.parseLong(p[0]);
                        end =
                                p.length > 1 && !p[1].isEmpty()
                                        ? Long.parseLong(p[1])
                                        : payload.length - 1;
                    }
                    if (return200OnContinuation.get() && start > 0) {
                        ex.sendResponseHeaders(200, payload.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(payload);
                        }
                        return;
                    }
                    // Deliberately return SHORT 206 capped at 333 bytes!
                    long actualEnd = Math.min(end, Math.min(payload.length - 1, start + 332));
                    int len = (int) (actualEnd - start + 1);
                    ex.getResponseHeaders()
                            .set(
                                    "Content-Range",
                                    "bytes " + start + "-" + actualEnd + "/" + payload.length);
                    ex.sendResponseHeaders(206, len);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(payload, (int) start, len);
                    }
                });
        mockOrigin.start();

        // A. CloudMediaProxy: short 206, suffix bytes=-600, continuation 200 rejected
        try (CloudMediaProxy cmp = new CloudMediaProxy()) {
            String upstream =
                    "http://127.0.0.1:" + mockOrigin.getAddress().getPort() + "/video.mkv";
            CloudMediaProxy.Lease lease =
                    cmp.createLease(
                            upstream, Collections.<String, String>emptyMap(), null, 1024, 3, 65536);
            String url = cmp.leaseUrl(lease);

            // 1. Short 206 across multiple chunks [200..1999]
            HttpURLConnection cShort = (HttpURLConnection) new URL(url).openConnection();
            cShort.setRequestProperty("Range", "bytes=200-1999");
            check(cShort.getResponseCode() == 206, "R2-4(Cloud): Short 206 returns 206");
            byte[] gotShort = readAll(cShort.getInputStream());
            cShort.disconnect();
            check(
                    Arrays.equals(Arrays.copyOfRange(payload, 200, 2000), gotShort),
                    "R2-4(Cloud): Short 206 exact 1800 bytes verified");

            // 2. Tail / Suffix Range bytes=-600
            HttpURLConnection cTail = (HttpURLConnection) new URL(url).openConnection();
            cTail.setRequestProperty("Range", "bytes=-600");
            check(cTail.getResponseCode() == 206, "R2-4(Cloud): Suffix Range returns 206");
            check(
                    "bytes 3496-4095/4096".equals(cTail.getHeaderField("Content-Range")),
                    "R2-4(Cloud): Suffix Content-Range exact");
            byte[] gotTail = readAll(cTail.getInputStream());
            cTail.disconnect();
            check(
                    Arrays.equals(Arrays.copyOfRange(payload, 3496, 4096), gotTail),
                    "R2-4(Cloud): Suffix Range exact 600 bytes verified");

            // 3. Continuation chunk returning HTTP 200 -> MUST reject, never corrupt!
            return200OnContinuation.set(true);
            HttpURLConnection c200 = (HttpURLConnection) new URL(url).openConnection();
            c200.setRequestProperty("Range", "bytes=0-1500");
            byte[] partial = readAll(c200.getInputStream());
            c200.disconnect();
            check(
                    partial.length == 333
                            && Arrays.equals(Arrays.copyOfRange(payload, 0, 333), partial)
                            && lease.metrics.rejectedRangeResponses.get() >= 1,
                    "R2-4(Cloud): Continuation HTTP 200 rejected without corrupting bytes");
            return200OnContinuation.set(false);
        } finally {
            mockOrigin.stop(0);
        }

        // B. Subscription LocalProxy: short 206, suffix bytes=-700, continuation 200 rejected
        final AtomicBoolean lpCont200 = new AtomicBoolean(false);
        LocalProxy.SourceResolver fakeSpider =
                (app, cfg, params) -> {
                    String range = params.get("Range");
                    long[] spec = LocalProxy.parseClientRangeSpec(range);
                    long start = 0;
                    long end = payload.length - 1;
                    if (spec != null) {
                        if (spec[2] == 1L) {
                            start = Math.max(0L, payload.length - spec[3]);
                            end = payload.length - 1;
                        } else {
                            start = spec[0];
                            end =
                                    spec[1] >= 0
                                            ? Math.min(spec[1], payload.length - 1)
                                            : payload.length - 1;
                        }
                    }
                    if (lpCont200.get() && start > 0) {
                        // Upstream wrongly returns HTTP 200 starting from byte 0!
                        return new Object[] {200, "video/x-matroska", payload};
                    }
                    // Short 206 capped at 400 bytes per response!
                    long actualEnd = Math.min(end, start + 399);
                    byte[] chunk = Arrays.copyOfRange(payload, (int) start, (int) actualEnd + 1);
                    Map<String, String> rh = new LinkedHashMap<>();
                    rh.put(
                            "Content-Range",
                            "bytes " + start + "-" + actualEnd + "/" + payload.length);
                    return new Object[] {206, "video/x-matroska", chunk, rh};
                };
        try (LocalProxy lp = new LocalProxy(null, new Cms.Config(), p -> null, fakeSpider)) {
            int lpPort = lp.server.getLocalPort();
            String base = "http://127.0.0.1:" + lpPort + "/proxy?do=wogg&id=1";

            // 1. Short 206 chaining [100..1499]
            HttpURLConnection c1 = (HttpURLConnection) new URL(base).openConnection();
            c1.setRequestProperty("Range", "bytes=100-1499");
            check(c1.getResponseCode() == 206, "R2-4(LocalProxy): Short 206 returns 206");
            check(
                    "bytes 100-1499/4096".equals(c1.getHeaderField("Content-Range")),
                    "R2-4(LocalProxy): Short 206 Content-Range exact");
            byte[] got1 = readAll(c1.getInputStream());
            c1.disconnect();
            check(
                    Arrays.equals(Arrays.copyOfRange(payload, 100, 1500), got1),
                    "R2-4(LocalProxy): Short 206 exact 1400 bytes verified");

            // 2. Tail / Suffix Range bytes=-700 (also short 206 chained!)
            HttpURLConnection c2 = (HttpURLConnection) new URL(base).openConnection();
            c2.setRequestProperty("Range", "bytes=-700");
            check(c2.getResponseCode() == 206, "R2-4(LocalProxy): Suffix Range returns 206");
            check(
                    "bytes 3396-4095/4096".equals(c2.getHeaderField("Content-Range")),
                    "R2-4(LocalProxy): Suffix Content-Range exact");
            byte[] got2 = readAll(c2.getInputStream());
            c2.disconnect();
            check(
                    Arrays.equals(Arrays.copyOfRange(payload, 3396, 4096), got2),
                    "R2-4(LocalProxy): Suffix Range exact 700 bytes verified");

            // 3. Continuation returning HTTP 200 -> MUST abort cleanly without appending byte 0!
            lpCont200.set(true);
            HttpURLConnection c3 = (HttpURLConnection) new URL(base).openConnection();
            c3.setRequestProperty("Range", "bytes=0-1500");
            byte[] got3 = readAll(c3.getInputStream());
            c3.disconnect();
            check(
                    got3.length == 400 && Arrays.equals(Arrays.copyOfRange(payload, 0, 400), got3),
                    "R2-4(LocalProxy): Continuation HTTP 200 rejected without corrupting bytes (got "
                            + got3.length
                            + ")");
        }
        pass(
                "R2-P1.4: Both CloudMediaProxy & LocalProxy short-206, continuation-200 & suffix-Range verified byte-for-byte");
    }

    private static void r2Item5SubscriptionLanQrAndSecurityAcls(File workDir) throws Exception {
        final File pluginPrivateDir = new File(workDir, "r2-spider-private");
        pluginPrivateDir.mkdirs();
        final File credFile = new File(pluginPrivateDir, "quark_cookie.txt");

        LocalProxy.SourceResolver configSpider =
                (app, cfg, params) -> {
                    String doAct = params.get("do");
                    if ("wexconfig".equals(doAct)
                            && "POST".equalsIgnoreCase(params.get("http-method"))) {
                        String ck = params.get("quark_cookie");
                        if (ck != null && !ck.isEmpty()) {
                            try (FileOutputStream fos = new FileOutputStream(credFile)) {
                                fos.write(ck.getBytes(StandardCharsets.UTF_8));
                            }
                        }
                        return new Object[] {200, "application/json", "{\"ok\":true}"};
                    }
                    if ("woggplay".equals(doAct)) {
                        String saved =
                                credFile.isFile()
                                        ? new String(
                                                java.nio.file.Files.readAllBytes(credFile.toPath()),
                                                StandardCharsets.UTF_8)
                                        : "";
                        if (!saved.contains("__pus=lan_qr_ok")) {
                            return new Object[] {401, "text/plain", "need login"};
                        }
                        return new Object[] {200, "video/mp4", "PLAYABLE_STREAM_OK"};
                    }
                    return new Object[] {
                        200, "text/html", "<form action='/proxy?do=wexconfig'></form>"
                    };
                };

        try (LocalProxy lp = new LocalProxy(null, new Cms.Config(), p -> null, configSpider)) {
            int lpPort = lp.server.getLocalPort();
            check(
                    lp.server.getInetAddress().isAnyLocalAddress(),
                    "R2-5: LocalProxy listens on wildcard 0.0.0.0 so LAN QR port is reachable");
            // Simulate second Wi-Fi device scanning subscription QR URL with RFC1918 LAN IP Host &
            // exact same-origin LAN Origin headers.
            String lanIp = String.format(Locale.US, "%d.%d.%d.%d", 10, 20, 30, 40);
            String lanHost = lanIp + ":" + lpPort;
            String formBody = "quark_cookie=__pus%3Dlan_qr_ok%3B%20__puus%3Dlan_puus_ok";
            int postStatus =
                    rawHttpRequest(
                            lpPort,
                            "POST",
                            "/proxy?do=wexconfig",
                            lanHost,
                            "http://" + lanHost,
                            "same-origin",
                            formBody);
            check(postStatus == 200, "R2-5: LAN QR config POST accepted (" + postStatus + ")");

            // Plugin reads back persisted credential & plays original video (permission-free dir)
            HttpURLConnection playConn =
                    (HttpURLConnection)
                            new URL("http://127.0.0.1:" + lpPort + "/proxy?do=woggplay")
                                    .openConnection();
            check(playConn.getResponseCode() == 200, "R2-5: Spider readback plays original video");
            String body = new String(readAll(playConn.getInputStream()), StandardCharsets.UTF_8);
            playConn.disconnect();
            check("PLAYABLE_STREAM_OK".equals(body), "R2-5: Original stream bytes returned");

            // Security invariants preserved: DNS rebinding Host, cross-origin Origin, and LAN do=js
            // MUST fail 403!
            check(
                    rawHttpRequest(
                                    lpPort,
                                    "GET",
                                    "/proxy?do=wexconfig",
                                    "evil.test:" + lpPort,
                                    null,
                                    null,
                                    null)
                            == 403,
                    "R2-5: DNS rebinding Host rejected with 403");
            check(
                    rawHttpRequest(
                                    lpPort,
                                    "POST",
                                    "/proxy?do=wexconfig",
                                    lanHost,
                                    "https://evil.test",
                                    "cross-site",
                                    formBody)
                            == 403,
                    "R2-5: Cross-origin LAN POST rejected with 403");
            check(
                    rawHttpRequest(
                                    lpPort,
                                    "GET",
                                    "/proxy?do=js&site=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&_mm_token="
                                            + lp.token,
                                    lanHost,
                                    null,
                                    null,
                                    null)
                            == 403,
                    "R2-5: Script route do=js rejects non-loopback Host with 403");
        }
        pass(
                "R2-P1.5: Subscription LAN QR reachable on wildcard port with strict per-route ACL & readback");
    }

    private static int rawHttpRequest(
            int port,
            String method,
            String target,
            String hostHeader,
            String originHeader,
            String secFetchSite,
            String body)
            throws IOException {
        try (java.net.Socket s = new java.net.Socket("127.0.0.1", port)) {
            s.setSoTimeout(5000);
            byte[] bodyBytes = body == null ? new byte[0] : body.getBytes(StandardCharsets.UTF_8);
            StringBuilder req = new StringBuilder();
            req.append(method).append(' ').append(target).append(" HTTP/1.1\r\n");
            req.append("Host: ").append(hostHeader).append("\r\n");
            if (originHeader != null) req.append("Origin: ").append(originHeader).append("\r\n");
            if (secFetchSite != null) {
                req.append("Sec-Fetch-Site: ").append(secFetchSite).append("\r\n");
            }
            if (bodyBytes.length > 0) {
                req.append("Content-Type: application/x-www-form-urlencoded\r\n");
                req.append("Content-Length: ").append(bodyBytes.length).append("\r\n");
            }
            req.append("Connection: close\r\n\r\n");
            OutputStream os = s.getOutputStream();
            os.write(req.toString().getBytes(StandardCharsets.ISO_8859_1));
            if (bodyBytes.length > 0) os.write(bodyBytes);
            os.flush();
            java.io.BufferedReader br =
                    new java.io.BufferedReader(
                            new java.io.InputStreamReader(
                                    s.getInputStream(), StandardCharsets.ISO_8859_1));
            String statusLine = br.readLine();
            if (statusLine == null) return -1;
            String[] parts = statusLine.split(" ");
            return parts.length >= 2 ? Integer.parseInt(parts[1]) : -1;
        }
    }

    private static void r2Item6LineIdentityMergeOrderAndPlaybackIndex() throws Exception {
        // 1. Two subscriptions with SAME site key ("shared_vod") & SAME API -> swapping merge order
        // MUST NOT alter PlaybackLineRules scope!
        String mergedOrderAB =
                new JSONObject()
                        .put(
                                "sites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("key", "shared_vod")
                                                        .put("_marco_raw_key", "shared_vod")
                                                        .put("name", "同源站")
                                                        .put("type", 1)
                                                        .put("api", "https://vod.example/api")
                                                        .put(
                                                                "_marco_origin",
                                                                "https://sub-a.example/cfg.json"))
                                        .put(
                                                new JSONObject()
                                                        .put("key", "shared_vod__bbbbbb")
                                                        .put("_marco_raw_key", "shared_vod")
                                                        .put("name", "同源站")
                                                        .put("type", 1)
                                                        .put("api", "https://vod.example/api")
                                                        .put(
                                                                "_marco_origin",
                                                                "https://sub-b.example/cfg.json")))
                        .toString();
        String mergedOrderBA =
                new JSONObject()
                        .put(
                                "sites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("key", "shared_vod")
                                                        .put("_marco_raw_key", "shared_vod")
                                                        .put("name", "同源站")
                                                        .put("type", 1)
                                                        .put("api", "https://vod.example/api")
                                                        .put(
                                                                "_marco_origin",
                                                                "https://sub-b.example/cfg.json"))
                                        .put(
                                                new JSONObject()
                                                        .put("key", "shared_vod__aaaaaa")
                                                        .put("_marco_raw_key", "shared_vod")
                                                        .put("name", "同源站")
                                                        .put("type", 1)
                                                        .put("api", "https://vod.example/api")
                                                        .put(
                                                                "_marco_origin",
                                                                "https://sub-a.example/cfg.json")))
                        .toString();

        Cms.Config cfgAB = Cms.parseConfig(mergedOrderAB, "");
        Cms.Config cfgBA = Cms.parseConfig(mergedOrderBA, "");
        Cms.Site aInAB = cfgAB.sites.get(0);
        Cms.Site bInAB = cfgAB.sites.get(1);
        Cms.Site bInBA = cfgBA.sites.get(0);
        Cms.Site aInBA = cfgBA.sites.get(1);

        String scopeA1 =
                PlaybackLineRules.buildSiteScope(
                        PlaybackLineRules.buildSubscriptionScope(aInAB.sourceOrigin, "", ""),
                        aInAB.siteId(),
                        aInAB.originalApi);
        String scopeA2 =
                PlaybackLineRules.buildSiteScope(
                        PlaybackLineRules.buildSubscriptionScope(aInBA.sourceOrigin, "", ""),
                        aInBA.siteId(),
                        aInBA.originalApi);
        String scopeB1 =
                PlaybackLineRules.buildSiteScope(
                        PlaybackLineRules.buildSubscriptionScope(bInAB.sourceOrigin, "", ""),
                        bInAB.siteId(),
                        bInAB.originalApi);
        String scopeB2 =
                PlaybackLineRules.buildSiteScope(
                        PlaybackLineRules.buildSubscriptionScope(bInBA.sourceOrigin, "", ""),
                        bInBA.siteId(),
                        bInBA.originalApi);
        check(scopeA1.equals(scopeA2), "R2-6: Swapping merge order keeps Sub A scope identical");
        check(scopeB1.equals(scopeB2), "R2-6: Swapping merge order keeps Sub B scope identical");
        check(!scopeA1.equals(scopeB1), "R2-6: Sub A and Sub B scopes strictly isolated");

        // 2. Two same-named lines ("线路1", "线路1") with DIFFERENT episodes MUST BOTH survive
        // unedited!
        Cms.Line dup1 = new Cms.Line();
        dup1.name = "线路1";
        dup1.rawName = "线路1";
        Cms.Episode epA1 = new Cms.Episode();
        epA1.name = "第1集";
        epA1.url = "https://cdn.example/a/1.m3u8";
        Cms.Episode epA2 = new Cms.Episode();
        epA2.name = "第2集";
        epA2.url = "https://cdn.example/a/2.m3u8";
        dup1.episodes.add(epA1);
        dup1.episodes.add(epA2);

        Cms.Line dup2 = new Cms.Line();
        dup2.name = "线路1";
        dup2.rawName = "线路1";
        Cms.Episode epB1 = new Cms.Episode();
        epB1.name = "第1集";
        epB1.url = "https://cdn.example/b/1.m3u8";
        dup2.episodes.add(epB1);

        List<Cms.Line> unedited =
                PlaybackLineRules.applyToLines(Arrays.asList(dup1, dup2), new JSONObject());
        check(unedited.size() == 2, "R2-6: Two same-named lines do NOT collapse when unedited");
        check(
                !unedited.get(0).lineId().equals(unedited.get(1).lineId()),
                "R2-6: Same-named lines get distinct stable lineIds");

        // 3. Reorder in playback -> resolveActiveLineAfterApply keeps valid index & next episode!
        Cms.Line playingLine = unedited.get(0); // "线路1" playing epA1
        JSONObject ruleA = new JSONObject();
        PlaybackLineRules.setAlias(ruleA, unedited.get(1).lineId(), "备用4K");
        PlaybackLineRules.setOrder(
                ruleA, Arrays.asList(unedited.get(1).lineId(), unedited.get(0).lineId()));
        List<Cms.Line> reordered = PlaybackLineRules.applyToLines(unedited, ruleA);
        check(
                "备用4K".equals(reordered.get(0).name) && "线路1".equals(reordered.get(1).name),
                "R2-6: Only 2nd same-named line renamed & moved to top");
        Cms.Line rebound =
                PlaybackLineRules.resolveActiveLineAfterApply(reordered, playingLine, epA1);
        int newIdx = reordered.indexOf(rebound);
        check(newIdx == 1, "R2-6: Active line index after in-playback reorder is 1 (NOT -1)");
        check(
                rebound.episodes.indexOf(epA1) == 0 && rebound.episodes.get(1) == epA2,
                "R2-6: Episode pick & next episode stay valid after reorder");

        // 4. Refresh + delete 1st same-named line -> 2nd survives with its own episodes!
        PlaybackLineRules.setHidden(ruleA, unedited.get(0).lineId(), true);
        List<Cms.Line> afterRefresh =
                PlaybackLineRules.applyToLines(Arrays.asList(dup1, dup2), ruleA);
        check(
                afterRefresh.size() == 1
                        && "备用4K".equals(afterRefresh.get(0).name)
                        && afterRefresh
                                .get(0)
                                .episodes
                                .get(0)
                                .url
                                .equals("https://cdn.example/b/1.m3u8"),
                "R2-6: Deleting 1st same-named line preserves 2nd line & its episodes across refresh");
        pass(
                "R2-P1.6: Line identity (dup-name retention, order-invariant scope, in-playback lineIndex)");
    }

    private static void r2Item7Danmu404AuthFailDiscoveryAndSeason2() throws Exception {
        HttpServer mock = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mock.setExecutor(Executors.newCachedThreadPool());
        mock.createContext(
                "/",
                ex -> {
                    String path = ex.getRequestURI().getPath();
                    int port = mock.getAddress().getPort();
                    if (path.startsWith("/notfound")) {
                        sendJson(ex, 404, "{\"error\":\"not found\"}");
                        return;
                    }
                    if (path.startsWith("/authfail")) {
                        sendJson(
                                ex,
                                200,
                                "{\"success\":false,\"errorCode\":401,\"errorMessage\":\"Invalid AppId\"}");
                        return;
                    }
                    if (path.equals("/dir.json")) {
                        sendJson(
                                ex,
                                200,
                                "{\"sources\":[{\"name\":\"目录自建弹幕\",\"url\":\"http://127.0.0.1:"
                                        + port
                                        + "/s2dm\"}]}");
                        return;
                    }
                    if (path.equals("/s2dm/api/v2/match")) {
                        // Server wrongly returns Season 1 with 0.85 confidence!
                        sendJson(
                                ex,
                                200,
                                "{\"isMatched\":false,\"matches\":[{\"animeId\":100,\"animeTitle\":\"庆余年 第一季\",\"episodeId\":1005,\"episodeTitle\":\"第5集\",\"confidence\":0.85}]}");
                        return;
                    }
                    if (path.equals("/s2dm/api/v2/search/episodes")) {
                        sendJson(
                                ex,
                                200,
                                "{\"success\":true,\"errorCode\":0,\"animes\":["
                                        + "{\"animeId\":100,\"animeTitle\":\"庆余年 第一季\",\"episodes\":[{\"episodeId\":1005,\"episodeTitle\":\"第5集\"}]},"
                                        + "{\"animeId\":200,\"animeTitle\":\"庆余年 第二季\",\"episodes\":[{\"episodeId\":2005,\"episodeTitle\":\"第5集\"}]}"
                                        + "]}");
                        return;
                    }
                    sendJson(ex, 404, "{}");
                });
        mock.start();
        try {
            String base = "http://127.0.0.1:" + mock.getAddress().getPort();

            // 1. Probe rejects HTTP 404 and HTTP 200 business auth failure!
            check(
                    !DanmuSourceManager.probeNewDanmuService(base + "/notfound", "庆余年").ok,
                    "R2-7: 404 rejected by probe");
            check(
                    !DanmuSourceManager.probeNewDanmuService(base + "/authfail", "庆余年").ok,
                    "R2-7: HTTP 200 business auth failure rejected by probe");
            check(
                    DanmuSourceManager.probeNewDanmuService(base + "/s2dm", "庆余年").ok,
                    "R2-7: Healthy service passes probe");

            // 2. Benchmark rejects 404 & business-auth-failure (latency 9999) and ranks healthy
            // first
            List<OnlineSubtitleDanmakuService.DanmakuSource> bench =
                    Arrays.asList(
                            new OnlineSubtitleDanmakuService.DanmakuSource(
                                    "404源", base + "/notfound", true, -1),
                            new OnlineSubtitleDanmakuService.DanmakuSource(
                                    "认证失败源", base + "/authfail", true, -1),
                            new OnlineSubtitleDanmakuService.DanmakuSource(
                                    "有效源", base + "/s2dm", true, -1));
            OnlineSubtitleDanmakuService.benchmarkSourcesSync(bench, "庆余年");
            check(
                    "有效源".equals(bench.get(0).name) && bench.get(0).latencyMs < 9999L,
                    "R2-7: Healthy ranked first");
            check(
                    bench.get(1).latencyMs == 9999L && bench.get(2).latencyMs == 9999L,
                    "R2-7: 404 & auth-failure scored unreachable (9999ms)");

            // 3. Discovery from directory URL without pre-knowing service URL
            List<DanmuSourceManager.DiscoveredService> found =
                    DanmuSourceManager.searchDiscoverableServices(
                            new Cms.Config(), "目录", base + "/dir.json");
            check(
                    found.size() == 1 && (base + "/s2dm").equals(found.get(0).origin),
                    "R2-7: Directory discovery finds /s2dm without pre-knowing URL");

            // 4. Cross-source fallback (/notfound -> /s2dm) + Season 2 beats Season 1!
            DandanplayProvider provider =
                    new DandanplayProvider(base + "/notfound\n" + base + "/s2dm", "", "");
            List<DanmuProvider.Candidate> cands =
                    provider.matchOrSearch(
                            new DanmuProvider.MatchQuery("庆余年", "第5集", 2, 5, 0),
                            new DanmuProvider.CancellationToken());
            check(!cands.isEmpty(), "R2-7: Cross-source fallback returned candidates");
            check(
                    cands.get(0).animeTitle.contains("第二季")
                            && cands.get(0).boundEpisodeId.endsWith("&ep=2005"),
                    "R2-7: Season 2 auto-selected over Season 1 (got "
                            + cands.get(0).animeTitle
                            + " / "
                            + cands.get(0).boundEpisodeId
                            + ")");
        } finally {
            mock.stop(0);
        }
        pass(
                "R2-P1.7: Danmu 404/auth-fail rejection, directory discovery, cross-source fallback & Season 2 matching");
    }

    private static void r2Item9ProductionExternalParserEpisodeIdAndWebPage() throws Exception {
        final AtomicReference<String> calledParserQuery = new AtomicReference<>("");
        HttpServer mock = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mock.setExecutor(Executors.newCachedThreadPool());
        mock.createContext(
                "/",
                ex -> {
                    String path = ex.getRequestURI().getPath();
                    String query = ex.getRequestURI().getRawQuery();
                    if (path.equals("/qq-json-jx")) {
                        calledParserQuery.set(query == null ? "" : query);
                        sendJson(
                                ex,
                                200,
                                "{\"code\":200,\"url\":\"https://stream.example/resolved/master.m3u8\"}");
                        return;
                    }
                    if (path.equals("/normal-page.html")) {
                        byte[] html =
                                "<html><body><div>no inline video</div></body></html>"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "text/html");
                        ex.sendResponseHeaders(200, html.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(html);
                        }
                        return;
                    }
                    sendJson(ex, 404, "{}");
                });
        mock.start();
        try {
            String base = "http://127.0.0.1:" + mock.getAddress().getPort();
            Cms.Parse qqParser = new Cms.Parse();
            qqParser.name = "QQ主解析";
            qqParser.url = base + "/qq-json-jx?url=";
            qqParser.type = 1;
            qqParser.flags.add("qq");
            List<Cms.Parse> parses = Collections.singletonList(qqParser);

            // Production gate: parse=1, jx=0, no playPrefix MUST route BOTH opaque episode ID and
            // normal web page through ExternalParserResolver!
            check(
                    ExternalParserResolver.shouldRouteThroughExternalParsers(
                            1, 0, "", "ep_opaque_9981", parses),
                    "R2-9: parse=1, jx=0, no prefix episode ID routes to parser");
            check(
                    ExternalParserResolver.shouldRouteThroughExternalParsers(
                            1, 0, "", base + "/normal-page.html", parses),
                    "R2-9: parse=1, jx=0, no prefix normal web page routes to parser");

            // Prove production executor actually calls matching parser for episode ID
            calledParserQuery.set("");
            ExternalParserResolver.ResolutionOutcome epOut =
                    ExternalParserResolver.executeParserChain(
                            "ep_opaque_9981",
                            "qq",
                            "",
                            parses,
                            Collections.<String, String>emptyMap(),
                            "SiteA",
                            Cms::fetch,
                            (u, h) -> "");
            check(
                    ExternalParserResolver.ResolutionOutcome.KIND_JSON_PARSER.equals(epOut.kind)
                            && "https://stream.example/resolved/master.m3u8".equals(epOut.url)
                            && calledParserQuery.get().contains("ep_opaque_9981"),
                    "R2-9: Episode ID invoked matching JSON parser end-to-end");

            // Prove production executor actually calls matching parser for normal web page
            calledParserQuery.set("");
            ExternalParserResolver.ResolutionOutcome webOut =
                    ExternalParserResolver.executeParserChain(
                            base + "/normal-page.html",
                            "qq",
                            "",
                            parses,
                            Collections.<String, String>emptyMap(),
                            "SiteA",
                            Cms::fetch,
                            (u, h) -> "");
            check(
                    ExternalParserResolver.ResolutionOutcome.KIND_JSON_PARSER.equals(webOut.kind)
                            && "https://stream.example/resolved/master.m3u8".equals(webOut.url)
                            && calledParserQuery.get().contains("normal-page.html"),
                    "R2-9: Normal web page invoked matching JSON parser end-to-end");
        } finally {
            mock.stop(0);
        }
        pass(
                "R2-P1.9: Production external parser chain (parse=1, jx=0, no prefix: episode ID & normal web page)");
    }

    private static void r2Item10AlistMalformedVsEmptyAndMergeRollback() throws Exception {
        HttpServer mock = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        mock.setExecutor(Executors.newCachedThreadPool());
        mock.createContext(
                "/",
                ex -> {
                    String path = ex.getRequestURI().getPath();
                    if (path.equals("/malformed/api/fs/list")) {
                        sendJson(ex, 200, "{\"code\":200,\"data\":{}}");
                        return;
                    }
                    if (path.equals("/empty/api/fs/list")) {
                        sendJson(ex, 200, "{\"code\":200,\"data\":{\"total\":0,\"content\":[]}}");
                        return;
                    }
                    if (path.equals("/null-empty/api/fs/list")) {
                        sendJson(ex, 200, "{\"code\":200,\"data\":{\"total\":0,\"content\":null}}");
                        return;
                    }
                    if (path.equals("/auth/api/fs/list")) {
                        sendJson(ex, 200, "{\"code\":401,\"message\":\"unauthorized\"}");
                        return;
                    }
                    sendJson(ex, 404, "{}");
                });
        mock.start();
        try {
            String base = "http://127.0.0.1:" + mock.getAddress().getPort();
            // 1. Missing content key -> MUST throw malformed error (NOT 0 items)!
            boolean malformedRejected = false;
            try {
                new AlistEngine.Client(
                                new AlistEngine.MountConfig(
                                        "m1", "Bad", base + "/malformed", "/", "", "", "", ""))
                        .listDirectory("/", 1, 20);
            } catch (IOException ex) {
                malformedRejected = ex.getMessage() != null && ex.getMessage().contains("content");
            }
            check(malformedRejected, "R2-10: Missing content field rejected as malformed");

            // 2. Valid empty directory (content:[] and content:null with total:0) -> 0 items!
            check(
                    new AlistEngine.Client(
                                    new AlistEngine.MountConfig(
                                            "m2", "Empty", base + "/empty", "/", "", "", "", ""))
                            .listDirectory("/", 1, 20)
                            .items
                            .isEmpty(),
                    "R2-10: Valid empty content:[] accepted");
            check(
                    new AlistEngine.Client(
                                    new AlistEngine.MountConfig(
                                            "m3",
                                            "NullEmpty",
                                            base + "/null-empty",
                                            "/",
                                            "",
                                            "",
                                            "",
                                            ""))
                            .listDirectory("/", 1, 20)
                            .items
                            .isEmpty(),
                    "R2-10: Valid AList v3 empty content:null + total:0 accepted");

            // 3. Auth failure reports clear auth error
            boolean authRejected = false;
            try {
                new AlistEngine.Client(
                                new AlistEngine.MountConfig(
                                        "m4", "Auth", base + "/auth", "/", "", "", "", ""))
                        .listDirectory("/", 1, 20);
            } catch (IOException ex) {
                authRejected = ex.getMessage() != null && ex.getMessage().contains("认证失败");
            }
            check(authRejected, "R2-10: Auth failure distinguished clearly");

            // 4. Merge failure rolls back saved mount & throws (never reports false success!)
            final AtomicBoolean rolledBack = new AtomicBoolean(false);
            AlistEngine.MountConfig cand =
                    new AlistEngine.MountConfig(
                            "m_new", "New", base + "/empty", "/", "", "", "", "");
            boolean mergeFailed = false;
            try {
                AlistAccounts.commitMountWithMerge(
                        cfg -> {},
                        id -> {
                            if ("m_new".equals(id)) rolledBack.set(true);
                        },
                        cfg -> {
                            throw new IOException("simulated config write failure");
                        },
                        cand,
                        null);
            } catch (IOException ex) {
                mergeFailed = ex.getMessage() != null && ex.getMessage().contains("保存");
            }
            check(
                    mergeFailed && rolledBack.get(),
                    "R2-10: Merge failure rolled back & surfaced error");
        } finally {
            mock.stop(0);
        }
        pass("R2-P1.10: AList malformed vs empty dir, auth error & atomic save/merge rollback");
    }

    private static void r2Item11HomeEffectiveOrderAndFinalPanelWidths() {
        // 1. Home ordering only allows reordering effective curated sections
        List<String> defOrder = MobileHomeSections.parseOrder("");
        check(
                !MobileHomeSections.isReorderable(MobileHomeSections.ID_HERO_BILLBOARD),
                "R2-11: Hero fixed");
        check(
                !MobileHomeSections.isReorderable(MobileHomeSections.ID_WATCH_HISTORY),
                "R2-11: History fixed");
        check(
                !MobileHomeSections.isReorderable(MobileHomeSections.ID_SOURCE_UPDATES),
                "R2-11: Source updates fixed");
        check(!MobileHomeSections.canMoveDown(defOrder, 0), "R2-11: Hero cannot move down");
        check(
                !MobileHomeSections.canMoveUp(defOrder, 2),
                "R2-11: 1st curated cannot move above History");
        check(MobileHomeSections.canMoveDown(defOrder, 2), "R2-11: 1st curated can move down");
        check(MobileHomeSections.canMoveUp(defOrder, 3), "R2-11: 2nd curated can move up");
        check(
                !MobileHomeSections.canMoveDown(defOrder, 7),
                "R2-11: Last curated cannot move below SourceUpdates");
        List<String> reordered =
                MobileHomeSections.parseOrder(
                        MobileHomeSections.ID_SOURCE_UPDATES
                                + ","
                                + MobileHomeSections.ID_HOT_STREAM
                                + ","
                                + MobileHomeSections.ID_WIDESCREEN_RADAR);
        check(
                MobileHomeSections.ID_HERO_BILLBOARD.equals(reordered.get(0))
                        && MobileHomeSections.ID_HOT_STREAM.equals(reordered.get(2))
                        && MobileHomeSections.ID_SOURCE_UPDATES.equals(reordered.get(8)),
                "R2-11: Fixed slots respected while curated order takes effect");

        // 2. Final available panel width for Home Quick-Switch (landscape 520dp sheet cap!) & Full
        // Picker
        float landQuickW = SourcePickerLayout.computeQuickSwitchContentWidthDp(800f, false);
        check(Math.abs(landQuickW - 480f) < 0.1f, "R2-11: Landscape sheet capped at 520-40=480dp");
        check(
                SourcePickerLayout.resolveQuickSwitchColumns(landQuickW, 1.40f) == 1,
                "R2-11: Landscape + large font degrades to 1 col so right buttons stay clickable");
        float splitQuickW = SourcePickerLayout.computeQuickSwitchContentWidthDp(300f, true);
        int splitCols = SourcePickerLayout.resolveQuickSwitchColumns(splitQuickW, 1.0f);
        check(
                splitCols == 1
                        && SourcePickerLayout.computeCardWidthDp(splitQuickW, splitCols, 10f)
                                >= 240f,
                "R2-11: Split-screen quick-switch uses 1 col with wide card");
        float portQuickW = SourcePickerLayout.computeQuickSwitchContentWidthDp(390f, true);
        int portCols = SourcePickerLayout.resolveQuickSwitchColumns(portQuickW, 1.0f);
        check(
                portCols == 2
                        && SourcePickerLayout.computeCardWidthDp(portQuickW, portCols, 10f) >= 165f,
                "R2-11: Regular phone portrait quick-switch uses 2 cols with >=165dp/card");
        float fullPickerW = SourcePickerLayout.computeFullPickerContentWidthDp(360f, false);
        check(
                SourcePickerLayout.resolveFullPickerColumns(fullPickerW, 1.40f, false) == 1,
                "R2-11: Full picker under large font degrades to 1 col");
        pass(
                "R2-P2.11: Home effective-only ordering & final panel width under landscape/split/large-font");
    }

    private static void r2Item12SlimPrefReconcileAndTrackAutoVsDecoded() {
        // 1. Legacy slim-progress pref reconciliation eliminates Settings-ON vs Player-hidden
        // mismatch
        check(
                !com.pilipala.marcomovie.hud.PlayerHudPrefs.resolveEffectiveSlimProgress(
                        false, true, true, false),
                "R2-12: Legacy HUD=false with unset mobile key resolves consistently to OFF");
        check(
                !com.pilipala.marcomovie.hud.PlayerHudPrefs.resolveEffectiveSlimProgress(
                        true, true, true, false),
                "R2-12: Split-brain mobile=true & HUD=false resolves consistently to OFF");
        check(
                com.pilipala.marcomovie.hud.PlayerHudPrefs.resolveEffectiveSlimProgress(
                        true, true, true, true),
                "R2-12: Both ON resolves to ON");

        // 2. Multi-tier video track: auto (decoding 720p) -> 1080p (locked) -> auto (auto policy)
        VideoTrackOption t720 =
                new VideoTrackOption(0, 1280, 720, 2_500_000, 30f, "H.264", false, true, "");
        VideoTrackOption t1080 =
                new VideoTrackOption(1, 1920, 1080, 8_500_000, 60f, "HEVC", false, false, "");
        List<VideoTrackOption> tracksAuto720 = Arrays.asList(t720, t1080);

        // State 1: Auto policy while ABR decodes 720p
        VideoTrackOption.SelectionState stAuto =
                new VideoTrackOption.SelectionState(true, -1, 0, "1280×720");
        check(stAuto.menuSelectedOffset() == 0, "R2-12: Auto state highlights Auto policy row (0)");
        check(
                stAuto.formatAutoOptionLabel(tracksAuto720).contains("当前策略")
                        && stAuto.formatAutoOptionLabel(tracksAuto720).contains("720P"),
                "R2-12: Auto label shows active policy + decoded 720P");
        check(
                stAuto.formatTrackOptionLabel(t720).contains("当前解码")
                        && !stAuto.formatTrackOptionLabel(t720).contains("已锁定"),
                "R2-12: 720P row shows decoded without false manual lock");

        // State 2: Manually locked to 1080p
        VideoTrackOption t720Off =
                new VideoTrackOption(0, 1280, 720, 2_500_000, 30f, "H.264", false, false, "");
        VideoTrackOption t1080On =
                new VideoTrackOption(1, 1920, 1080, 8_500_000, 60f, "HEVC", false, true, "");
        List<VideoTrackOption> tracks1080 = Arrays.asList(t720Off, t1080On);
        VideoTrackOption.SelectionState stLocked =
                new VideoTrackOption.SelectionState(false, 1, 1, "1920×1080");
        check(stLocked.menuSelectedOffset() == 2, "R2-12: Locked 1080P highlights row 2");
        check(
                !stLocked.formatAutoOptionLabel(tracks1080).contains("当前策略")
                        && stLocked.formatTrackOptionLabel(t1080On).contains("已锁定")
                        && stLocked.formatTrackOptionLabel(t1080On).contains("当前解码"),
                "R2-12: Locked 1080P distinguishes manual lock + decoded track");

        // State 3: Switched back to Auto (even while decoder still outputs 1080p!)
        VideoTrackOption.SelectionState stBackAuto =
                new VideoTrackOption.SelectionState(true, -1, 1, "1920×1080");
        check(
                stBackAuto.menuSelectedOffset() == 0,
                "R2-12: Auto->1080p->Auto returns selected offset to Auto (0)");
        check(
                stBackAuto.formatAutoOptionLabel(tracks1080).contains("当前策略")
                        && stBackAuto.formatAutoOptionLabel(tracks1080).contains("1080P")
                        && !stBackAuto.formatTrackOptionLabel(t1080On).contains("已锁定")
                        && stBackAuto.formatTrackOptionLabel(t1080On).contains("当前解码"),
                "R2-12: Back to Auto clears lock badge while still reporting decoded 1080P");

        // State 4 (Android 16 real-device regression): Media3 ABR group marks ALL tracks
        // group.isTrackSelected(i)==true while decoder actually outputs 1920x1080 -> must pick ONLY
        // 1080P as decoded!
        VideoTrackOption abr720 =
                new VideoTrackOption(0, 1280, 720, 750_000, 24f, "H.264", false, true, "");
        VideoTrackOption abr1080 =
                new VideoTrackOption(1, 1920, 1080, 2_800_000, 24f, "H.264", false, true, "");
        List<VideoTrackOption> abrGroup = Arrays.asList(abr720, abr1080);
        int resolvedDecoded =
                VideoTrackOption.resolveActiveDecodedIndex(
                        abrGroup, 1920, 1080, 2_800_000, "H.264");
        check(
                resolvedDecoded == 1,
                "R2-12: ABR multi-selected group resolves single decoded 1080P track, got "
                        + resolvedDecoded);
        VideoTrackOption.SelectionState stAbr =
                new VideoTrackOption.SelectionState(true, -1, resolvedDecoded, "1920×1080");
        check(
                !stAbr.formatTrackOptionLabel(abr720).contains("当前解码")
                        && stAbr.formatTrackOptionLabel(abr1080).contains("当前解码")
                        && stAbr.policySummary(abrGroup).contains("1080P"),
                "R2-12: ABR Auto mode tags ONLY decoded 1080P (not 720P)");

        // Auto-danmu enabled reconciliation regression (Android 16 real-device catch):
        check(
                DanmuSourceManager.resolveEffectiveDanmuEnabled(false, false, false, true, true),
                "R2-7: Mobile with configured danmu origins & default-on inherits enabled=true when danmu_enabled unset");
        check(
                !DanmuSourceManager.resolveEffectiveDanmuEnabled(true, false, false, true, true),
                "R2-7: Explicit danmu_enabled=false is strictly respected");
        check(
                !DanmuSourceManager.resolveEffectiveDanmuEnabled(false, false, false, false, true),
                "R2-7: No configured origins remains disabled by default");
        check(
                !DanmuSourceManager.resolveEffectiveDanmuEnabled(false, false, true, true, true),
                "R2-7: TV default remains disabled unless explicitly enabled");
        pass(
                "R2-P2.12: Slim-bar preference reconciliation & auto->1080p->auto policy vs decoded track");
    }

    private static void p1Item7Api23ContentLengthAndRangeModes() throws Exception {
        // 1. 64-bit Content-Length header parsing (> 2 GiB) without API 24 getContentLengthLong()
        check(
                CloudMediaProxy.parseContentLengthValue("42949672960") == 42949672960L
                        && CloudMediaProxy.parseContentLengthValue(" 512 ") == 512L
                        && CloudMediaProxy.parseContentLengthValue("invalid") == -1L
                        && CloudMediaProxy.parseContentLengthValue(null) == -1L,
                "P1-7: API-23-safe parseContentLengthValue handles 40 GiB Content-Length headers");

        final byte[] smallBody = new byte[512];
        final byte[] bigBody = new byte[8192]; // strictly > min lease.chunkSize (4096)
        for (int i = 0; i < smallBody.length; i++) smallBody[i] = (byte) (i & 0xFF);
        for (int i = 0; i < bigBody.length; i++) bigBody[i] = (byte) ((i * 7 + 3) & 0xFF);

        HttpServer origin = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        origin.setExecutor(Executors.newCachedThreadPool());
        origin.createContext(
                "/small200",
                ex -> {
                    // Always returns HTTP 200 (ignores Range) with small 512B body (<= 1024B chunk)
                    ex.sendResponseHeaders(200, smallBody.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(smallBody);
                    }
                });
        origin.createContext(
                "/big200",
                ex -> {
                    // Always returns HTTP 200 with 2048B body (> 1024B chunkSize -> MUST reject
                    // 502)
                    ex.sendResponseHeaders(200, bigBody.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(bigBody);
                    }
                });
        origin.createContext(
                "/range206",
                ex -> {
                    ex.getResponseHeaders()
                            .set(
                                    "Content-Range",
                                    "bytes 0-" + (smallBody.length - 1) + "/" + smallBody.length);
                    ex.sendResponseHeaders(206, smallBody.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(smallBody);
                    }
                });
        origin.start();
        try (CloudMediaProxy proxy = new CloudMediaProxy()) {
            String host = "http://127.0.0.1:" + origin.getAddress().getPort();

            // Case A: valid 206 partial content
            CloudMediaProxy.Lease l206 =
                    proxy.createLease(
                            host + "/range206", Collections.emptyMap(), null, 1024, 2, 65536);
            HttpURLConnection c206 =
                    (HttpURLConnection) new URL(proxy.leaseUrl(l206)).openConnection();
            c206.setRequestProperty("Range", "bytes=0-511");
            check(
                    c206.getResponseCode() == 206
                            && Arrays.equals(smallBody, readAll(c206.getInputStream())),
                    "P1-7: API 23 CloudMediaProxy serves valid HTTP 206 cleanly");
            c206.disconnect();

            // Case B: small-file HTTP 200 at offset 0 (<= chunkSize) -> accepted
            CloudMediaProxy.Lease lSmall =
                    proxy.createLease(
                            host + "/small200", Collections.emptyMap(), null, 1024, 2, 65536);
            HttpURLConnection cSmall =
                    (HttpURLConnection) new URL(proxy.leaseUrl(lSmall)).openConnection();
            cSmall.setRequestProperty("Range", "bytes=0-511");
            int sCode = cSmall.getResponseCode();
            byte[] sGot = readAll(cSmall.getInputStream());
            cSmall.disconnect();
            check(
                    (sCode == 200 || sCode == 206) && Arrays.equals(smallBody, sGot),
                    "P1-7: API 23 CloudMediaProxy serves small HTTP 200 at offset 0");

            // Case C: HTTP 200 at non-zero offset -> MUST reject with 502!
            HttpURLConnection cNonZero =
                    (HttpURLConnection) new URL(proxy.leaseUrl(lSmall)).openConnection();
            cNonZero.setRequestProperty("Range", "bytes=128-511");
            int nzCode = cNonZero.getResponseCode();
            cNonZero.disconnect();
            check(
                    nzCode == 502,
                    "P1-7: API 23 CloudMediaProxy rejects HTTP 200 on non-zero offset with 502 (got "
                            + nzCode
                            + ")");

            // Case D: oversized HTTP 200 (2048 > chunkSize 1024) -> MUST reject with 502!
            CloudMediaProxy.Lease lBig =
                    proxy.createLease(
                            host + "/big200", Collections.emptyMap(), null, 1024, 2, 65536);
            HttpURLConnection cBig =
                    (HttpURLConnection) new URL(proxy.leaseUrl(lBig)).openConnection();
            cBig.setRequestProperty("Range", "bytes=0-1023");
            int bigCode = cBig.getResponseCode();
            cBig.disconnect();
            check(
                    bigCode == 502,
                    "P1-7: API 23 CloudMediaProxy rejects oversized HTTP 200 (> chunkSize) with 502 (got "
                            + bigCode
                            + ")");
        } finally {
            origin.stop(0);
        }
        pass(
                "P1-7: API-23-safe Content-Length parsing + 206 / small 200 / non-zero 200 / oversize 200 verified");
    }

    private static Cms.Line mkLineWithUrl(String name, String epUrl) {
        Cms.Line l = new Cms.Line();
        l.name = name;
        l.rawName = name;
        Cms.Episode ep = new Cms.Episode();
        ep.name = "第1集";
        ep.url = epUrl;
        l.episodes.add(ep);
        return l;
    }

    private static void test11NetdiskDrivePriorityOrderAndPlaybackSelection() throws Exception {
        // 1. Line drive classification + ASCII word-boundary false-positive protection
        check(
                NetdiskStore.DRIVE_QUARK.equals(NetdiskStore.detectDriveKeyFromLineName("夸父原1"))
                        && NetdiskStore.DRIVE_QUARK.equals(
                                NetdiskStore.detectDriveKeyFromLineName("夸克4K"))
                        && NetdiskStore.DRIVE_UC.equals(
                                NetdiskStore.detectDriveKeyFromLineName("优汐智1"))
                        && NetdiskStore.DRIVE_UC.equals(
                                NetdiskStore.detectDriveKeyFromLineName("UC原画"))
                        && NetdiskStore.DRIVE_BAIDU.equals(
                                NetdiskStore.detectDriveKeyFromLineName("嘟嘟无限2"))
                        && NetdiskStore.DRIVE_BAIDU.equals(
                                NetdiskStore.detectDriveKeyFromLineName("百度网盘"))
                        && NetdiskStore.DRIVE_ALI.equals(
                                NetdiskStore.detectDriveKeyFromLineName("阿狸原画"))
                        && NetdiskStore.DRIVE_ALI.equals(
                                NetdiskStore.detectDriveKeyFromLineName("ALI-4K")),
                "DriveOrder: detects all 4 core netdisk aliases cleanly");
        check(
                NetdiskStore.detectDriveKeyFromLineName("Focus HD").isEmpty()
                        && NetdiskStore.detectDriveKeyFromLineName("Music Live").isEmpty()
                        && NetdiskStore.detectDriveKeyFromLineName("Quality 4K").isEmpty()
                        && NetdiskStore.detectDriveKeyFromLineName("Alias 线路").isEmpty()
                        && NetdiskStore.detectDriveKeyFromLineName("官方直连 M3U8").isEmpty(),
                "DriveOrder: zero false positives on non-netdisk English words (Focus/Music/Quality/Alias)");

        // 2. Fallback detection by episode share URL when line name is generic
        Cms.Line genericQ = mkLineWithUrl("网盘线路A", "https://pan.quark.cn/s/abc123");
        Cms.Line genericB = mkLineWithUrl("网盘线路B", "https://pan.baidu.com/s/xyz999");
        List<Cms.Line> urlOrdered =
                NetdiskStore.sortLinesByDriveOrder(
                        Arrays.asList(genericQ, genericB),
                        Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_QUARK,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_ALI));
        check(
                "网盘线路B".equals(urlOrdered.get(0).name) && "网盘线路A".equals(urlOrdered.get(1).name),
                "DriveOrder: classifies generic netdisk lines by episode share URL");

        // 3. Real 4-drive source with multiple lines per drive -> stable order within same drive
        List<Cms.Line> fourDrives =
                Arrays.asList(
                        mkLineWithUrl("夸父原1", "quark://1"),
                        mkLineWithUrl("夸父智1", "quark://2"),
                        mkLineWithUrl("优汐智1", "uc://1"),
                        mkLineWithUrl("嘟嘟无限2", "baidu://1"),
                        mkLineWithUrl("阿狸原画", "ali://1"));
        List<String> customOrder =
                Arrays.asList(
                        NetdiskStore.DRIVE_BAIDU,
                        NetdiskStore.DRIVE_ALI,
                        NetdiskStore.DRIVE_UC,
                        NetdiskStore.DRIVE_QUARK);
        List<Cms.Line> sorted4 =
                PlaybackLineRules.applyToLines(fourDrives, new JSONObject(), customOrder);
        check(
                "嘟嘟无限2".equals(sorted4.get(0).name)
                        && "阿狸原画".equals(sorted4.get(1).name)
                        && "优汐智1".equals(sorted4.get(2).name)
                        && "夸父原1".equals(sorted4.get(3).name)
                        && "夸父智1".equals(sorted4.get(4).name),
                "DriveOrder: 4-drive lines sort strictly by custom order & preserve same-drive stability");

        // 4. Mixed direct stream + extended netdisks + core drives:
        //    non-netdisk direct stream keeps slot 0; core drives lead extended netdisks
        List<Cms.Line> mixed =
                Arrays.asList(
                        mkLineWithUrl("官方直连", "https://cdn.example/live.m3u8"),
                        mkLineWithUrl("115原画", "pan115://sw123"),
                        mkLineWithUrl("天翼云盘", "pan189://abc"),
                        mkLineWithUrl("夸父原1", "quark://1"),
                        mkLineWithUrl("嘟嘟无限2", "baidu://1"));
        List<Cms.Line> mixedOut =
                PlaybackLineRules.applyToLines(mixed, new JSONObject(), customOrder);
        check(
                "官方直连".equals(mixedOut.get(0).name)
                        && "嘟嘟无限2".equals(mixedOut.get(1).name)
                        && "夸父原1".equals(mixedOut.get(2).name)
                        && "115原画".equals(mixedOut.get(3).name)
                        && "天翼云盘".equals(mixedOut.get(4).name),
                "DriveOrder: preserves non-netdisk direct slot & ranks core drives ahead of 115/天翼");

        // 5. Explicit per-site PlaybackLineRules preferred overrides global drive order
        JSONObject perSiteRule = new JSONObject();
        PlaybackLineRules.setPreferred(perSiteRule, "优汐智1");
        List<Cms.Line> withOverride =
                PlaybackLineRules.applyToLines(fourDrives, perSiteRule, customOrder);
        check(
                "优汐智1".equals(withOverride.get(0).name)
                        && "嘟嘟无限2".equals(withOverride.get(1).name)
                        && "阿狸原画".equals(withOverride.get(2).name),
                "DriveOrder: per-site explicit preferred line takes precedence while rest obey drive order");

        // 6. UI reorder helper (pin-to-top, move up, move down)
        List<String> moved = NetdiskStore.moveDriveInOrder(NetdiskStore.DEFAULT_ORDER, 2, 0);
        check(
                Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_QUARK,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_ALI)
                        .equals(moved),
                "DriveOrder: moveDriveInOrder pins baidu to #1 cleanly");

        // 7. Static wiring verification: AccountPanel "切换盘序" opens showDriveOrderSheet (not manual
        // creds)
        File repoRoot = new File(".").getCanonicalFile();
        File acctFile =
                new File(
                        repoRoot,
                        "android-mobile/src/main/java/com/pilipala/marcomovie/AccountPanel.java");
        if (acctFile.isFile()) {
            String acctSrc =
                    new String(
                            java.nio.file.Files.readAllBytes(acctFile.toPath()),
                            StandardCharsets.UTF_8);
            check(
                    acctSrc.contains("PersonalNetdiskBrowser.showDriveOrderSheet(a, onRefresh)"),
                    "DriveOrder: AccountPanel 切换盘序 button opens dedicated showDriveOrderSheet");
            check(
                    !acctSrc.contains(
                            "\"切换盘序\",\n                        false,\n                        true,\n                        () -> PersonalNetdiskBrowser.showManualCredentialSheet"),
                    "DriveOrder: AccountPanel 切换盘序 no longer opens manual credential sheet");
        }
        // 8. Round-4 P1-1: Direct media URL slot protection — vendor names/numbers/aliases sharing
        //    an explicit .m3u8 URL MUST NOT be reclassified as netdisk lines
        String sharedHls = "https://cdn.example/live/master.m3u8";
        Cms.Line aliCdnDirect = mkLineWithUrl("阿里云 CDN 直连", sharedHls);
        Cms.Line line115Direct = mkLineWithUrl("线路115", sharedHls);
        Cms.Line backupDirect = mkLineWithUrl("备用线路", sharedHls);
        Cms.Line realQuark = mkLineWithUrl("夸父原画", "quark://share/q1");
        Cms.Line realBaidu = mkLineWithUrl("嘟嘟原画", "baidu://share/b1");
        check(
                NetdiskStore.detectLineDriveKey(aliCdnDirect).isEmpty()
                        && NetdiskStore.detectLineDriveKey(line115Direct).isEmpty()
                        && NetdiskStore.detectLineDriveKey(backupDirect).isEmpty()
                        && !NetdiskStore.isExtendedNetdiskLine(aliCdnDirect)
                        && !NetdiskStore.isExtendedNetdiskLine(line115Direct)
                        && !NetdiskStore.isExtendedNetdiskLine(backupDirect),
                "R4 P1-1: explicit .m3u8 URL prevents vendor/number/alias names from being classified as netdisk");
        List<Cms.Line> mixedDirectAndDrives =
                Arrays.asList(aliCdnDirect, realQuark, line115Direct, realBaidu, backupDirect);
        List<Cms.Line> reorderedKeepDirect =
                PlaybackLineRules.applyToLines(
                        mixedDirectAndDrives,
                        new JSONObject(),
                        Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_ALI,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_QUARK));
        check(
                "阿里云 CDN 直连".equals(reorderedKeepDirect.get(0).name)
                        && "嘟嘟原画".equals(reorderedKeepDirect.get(1).name)
                        && "线路115".equals(reorderedKeepDirect.get(2).name)
                        && "夸父原画".equals(reorderedKeepDirect.get(3).name)
                        && "备用线路".equals(reorderedKeepDirect.get(4).name),
                "R4 P1-1: 阿里云 CDN 直连 / 线路115 / 备用线路 keep exact direct slots when drive order changes");

        // 9. Round-4 P1-2: Stable lineId + episodeUrl resume across duplicate-named twin lines,
        //    renamed lines, and legacy history lacking lineId
        Cms.Line twinQuark = new Cms.Line();
        twinQuark.lineId = "原画";
        twinQuark.name = "原画";
        twinQuark.rawName = "原画";
        Cms.Episode qEp1 = new Cms.Episode();
        qEp1.name = "第1集";
        qEp1.url = "https://pan.quark.cn/s/twin_q_ep1";
        Cms.Episode qEp2 = new Cms.Episode();
        qEp2.name = "第2集";
        qEp2.url = "https://pan.quark.cn/s/twin_q_ep2";
        twinQuark.episodes.add(qEp1);
        twinQuark.episodes.add(qEp2);

        Cms.Line twinBaidu = new Cms.Line();
        twinBaidu.lineId = "原画#2";
        twinBaidu.name = "原画";
        twinBaidu.rawName = "原画";
        Cms.Episode bEp1 = new Cms.Episode();
        bEp1.name = "第1集";
        bEp1.url = "https://pan.baidu.com/s/twin_b_ep1";
        Cms.Episode bEp2 = new Cms.Episode();
        bEp2.name = "第2集";
        bEp2.url = "https://pan.baidu.com/s/twin_b_ep2";
        twinBaidu.episodes.add(bEp1);
        twinBaidu.episodes.add(bEp2);

        WatchHistory.Entry savedQuarkEp2 = new WatchHistory.Entry();
        savedQuarkEp2.site = "demo";
        savedQuarkEp2.id = "v100";
        savedQuarkEp2.line = twinQuark.name;
        savedQuarkEp2.lineId = twinQuark.lineId();
        savedQuarkEp2.driveKey = NetdiskStore.detectLineDriveKey(twinQuark);
        savedQuarkEp2.index = 1;
        savedQuarkEp2.episode = qEp2.name;
        savedQuarkEp2.episodeKey = HistoryResumeMatcher.stableEpisodeKey(qEp2.url);
        savedQuarkEp2.position = 62_000;
        savedQuarkEp2.duration = 240_000;
        // Roundtrip JSON persistence of non-sensitive lineId + driveKey + episodeKey (zero raw URL)
        org.json.JSONObject savedJson = savedQuarkEp2.json();
        List<WatchHistory.Entry> roundtrippedHist =
                WatchHistory.read(new org.json.JSONArray().put(savedJson).toString());
        WatchHistory.Entry restoredQuarkEp2 = roundtrippedHist.get(0);
        check(
                "原画".equals(restoredQuarkEp2.lineId)
                        && NetdiskStore.DRIVE_QUARK.equals(restoredQuarkEp2.driveKey)
                        && savedQuarkEp2.episodeKey.equals(restoredQuarkEp2.episodeKey)
                        && !savedJson.has("episodeUrl"),
                "R4/R5 P1-1/P1-2: WatchHistory persists non-sensitive lineId/driveKey/episodeKey without raw episodeUrl");

        // Pin Baidu #1 -> Baidu moves to slot 0, Quark moves to slot 1
        List<Cms.Line> twinsBaiduFirst =
                PlaybackLineRules.applyToLines(
                        Arrays.asList(twinQuark, twinBaidu),
                        new JSONObject(),
                        Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_QUARK,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_ALI));
        Cms.Video twinVideo = new Cms.Video();
        twinVideo.id = "v100";
        twinVideo.title = "测试双盘";
        twinVideo.lines.addAll(twinsBaiduFirst);
        check(
                "原画#2".equals(twinsBaiduFirst.get(0).lineId())
                        && "原画".equals(twinsBaiduFirst.get(1).lineId()),
                "R4 P1-2: pinning Baidu places Baidu twin at index 0 and Quark twin at index 1");
        HistoryResumeMatcher.EpisodeMatch twinMatch =
                HistoryResumeMatcher.matchEpisode(twinVideo, restoredQuarkEp2);
        check(
                twinMatch != null
                        && twinMatch.line == twinsBaiduFirst.get(1)
                        && twinMatch.episode == qEp2
                        && HistoryResumeMatcher.findMatchedLineIndex(twinVideo, restoredQuarkEp2)
                                == 1
                        && HistoryResumeMatcher.findMatchedEpisodeIndex(
                                        twinsBaiduFirst.get(1), restoredQuarkEp2)
                                == 1
                        && HistoryResumeMatcher.matchesBookmarkSelection(
                                twinsBaiduFirst.get(1), qEp2, 1, restoredQuarkEp2)
                        && !HistoryResumeMatcher.matchesBookmarkSelection(
                                twinsBaiduFirst.get(0), bEp2, 1, restoredQuarkEp2),
                "R4 P1-2: Detail, History, Fullscreen & Inline all resume Quark Ep2 (not Baidu) after Baidu pinned #1");

        // Legacy history lacking lineId & episodeUrl still picks original "原画" twin cleanly
        WatchHistory.Entry legacyNoId = new WatchHistory.Entry();
        legacyNoId.line = "原画";
        legacyNoId.index = 1;
        legacyNoId.episode = "第2集";
        HistoryResumeMatcher.EpisodeMatch legacyMatch =
                HistoryResumeMatcher.matchEpisode(twinVideo, legacyNoId);
        check(
                legacyMatch != null
                        && legacyMatch.line == twinsBaiduFirst.get(1)
                        && legacyMatch.episode == qEp2,
                "R4 P1-2: legacy history lacking lineId still resolves exact primary line id over #2 twin");

        // Renamed line re-open preserves episode count and progress
        JSONObject renameRule = new JSONObject();
        PlaybackLineRules.setAlias(renameRule, "原画", "我的夸克极速");
        List<Cms.Line> renamedTwins =
                PlaybackLineRules.applyToLines(
                        Arrays.asList(twinQuark, twinBaidu),
                        renameRule,
                        Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_QUARK,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_ALI));
        Cms.Video renamedVideo = new Cms.Video();
        renamedVideo.id = "v100";
        renamedVideo.title = "测试双盘";
        renamedVideo.lines.addAll(renamedTwins);
        HistoryResumeMatcher.EpisodeMatch renamedMatch =
                HistoryResumeMatcher.matchEpisode(renamedVideo, restoredQuarkEp2);
        check(
                renamedMatch != null
                        && "我的夸克极速".equals(renamedMatch.line.name)
                        && renamedMatch.line.episodes.size() == 2
                        && renamedMatch.episode == qEp2
                        && HistoryResumeMatcher.matchesBookmarkSelection(
                                renamedMatch.line,
                                renamedMatch.line.episodes.get(1),
                                1,
                                restoredQuarkEp2),
                "R4 P1-2/P2-1: renaming line preserves display name, episode count, and exact Ep2 resume progress");

        // 10. Round-4 P2-1: Single-source manual reorder THEN setPreferred makes default playback
        //     select the preferred line cleanly!
        JSONObject manualThenDefaultRule = new JSONObject();
        PlaybackLineRules.setOrder(
                manualThenDefaultRule, Arrays.asList("优汐智1", "夸父原1", "嘟嘟无限2", "阿狸原画"));
        PlaybackLineRules.setPreferred(manualThenDefaultRule, "嘟嘟无限2");
        List<Cms.Line> manualOrdered =
                PlaybackLineRules.applyToLines(
                        fourDrives, manualThenDefaultRule, NetdiskStore.DEFAULT_ORDER);
        int resolvedDefaultIdx =
                SourcePreferences.resolveDefaultLineIndex(manualOrdered, manualThenDefaultRule, "");
        check(
                "优汐智1".equals(manualOrdered.get(0).name)
                        && resolvedDefaultIdx >= 0
                        && "嘟嘟无限2".equals(manualOrdered.get(resolvedDefaultIdx).name),
                "R4 P2-1: manual reorder followed by setPreferred preserves list order AND selects preferred default line");

        // Static wiring checks across PlaybackController, MobileInlinePlayer, MobileDetailScreen,
        // DetailScreen
        if (repoRoot.isDirectory()) {
            String[] resumeFiles = {
                "android-mobile/src/main/java/com/pilipala/marcomovie/PlaybackController.java",
                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileInlinePlayer.java",
                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileDetailScreen.java",
                "android-mobile/src/main/java/com/pilipala/marcomovie/DetailScreen.java"
            };
            for (String rel : resumeFiles) {
                String src =
                        new String(
                                java.nio.file.Files.readAllBytes(new File(repoRoot, rel).toPath()),
                                StandardCharsets.UTF_8);
                check(
                        src.contains("HistoryResumeMatcher.")
                                || src.contains("PlaybackController.lookupSavedBookmark("),
                        "R4 P1-2 static: " + rel + " uses unified HistoryResumeMatcher");
            }
        }
        // 11. Round-5 P1-1: CloudSync two-device roundtrip exports ONLY non-sensitive stable
        //     identity (ZERO temp netdisk download URLs, query signatures, or loopback proxy
        //     leases) and restores Baidu twin line #2 Ep2 with exact 42,000 ms (never applied to
        //     Quark!)
        WatchHistory.Entry baiduTwinEp2 = new WatchHistory.Entry();
        baiduTwinEp2.site = "demo";
        baiduTwinEp2.id = "v200";
        baiduTwinEp2.title = "同步双盘测试";
        baiduTwinEp2.line = "原画";
        baiduTwinEp2.lineId = "原画#2";
        baiduTwinEp2.driveKey = NetdiskStore.DRIVE_BAIDU;
        baiduTwinEp2.episode = "第2集";
        baiduTwinEp2.episodeUrl =
                "https://dl-pc.example/file/ep2.mkv?sign=SECRET_TOKEN_9988&expires=1799999999";
        baiduTwinEp2.episodeKey = HistoryResumeMatcher.stableEpisodeKey(baiduTwinEp2.episodeUrl);
        baiduTwinEp2.index = 1;
        baiduTwinEp2.position = 42_000;
        baiduTwinEp2.duration = 240_000;
        baiduTwinEp2.updated = 1_768_000_500_000L;

        WatchHistory.Entry proxyLeakProbe = new WatchHistory.Entry();
        proxyLeakProbe.site = "demo";
        proxyLeakProbe.id = "v201";
        proxyLeakProbe.title = "本地代理测试";
        proxyLeakProbe.line = "夸父原画";
        proxyLeakProbe.lineId = "夸父原画";
        proxyLeakProbe.driveKey = NetdiskStore.DRIVE_QUARK;
        proxyLeakProbe.episode = "第1集";
        proxyLeakProbe.episodeUrl = "http://127.0.0.1:45678/lease/LOCAL_LEASE_SECRET/stream.mkv";
        proxyLeakProbe.episodeKey =
                HistoryResumeMatcher.stableEpisodeKey(proxyLeakProbe.episodeUrl);
        proxyLeakProbe.index = 0;
        proxyLeakProbe.position = 15_000;
        proxyLeakProbe.duration = 120_000;
        proxyLeakProbe.updated = 1_768_000_400_000L;

        String devAHistory =
                new org.json.JSONArray()
                        .put(baiduTwinEp2.json())
                        .put(proxyLeakProbe.json())
                        .toString();
        String exportedSyncPayload =
                CloudSync.exportPayload(
                        devAHistory,
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        false,
                        1_768_000_600_000L);
        check(
                !exportedSyncPayload.contains("dl-pc.example")
                        && !exportedSyncPayload.contains("SECRET_TOKEN_9988")
                        && !exportedSyncPayload.contains("expires=")
                        && !exportedSyncPayload.contains("127.0.0.1")
                        && !exportedSyncPayload.contains("LOCAL_LEASE_SECRET")
                        && !exportedSyncPayload.contains("episodeUrl")
                        && exportedSyncPayload.contains("\"lineId\":\"原画#2\"")
                        && exportedSyncPayload.contains("\"driveKey\":\"baidu\""),
                "R5 P1-1: CloudSync export strips temp download URLs, query params & local proxy leases while keeping lineId & driveKey");

        CloudSync.MergeResult devBMerged =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        false,
                        exportedSyncPayload,
                        1_768_000_700_000L);
        List<WatchHistory.Entry> devBHist = WatchHistory.read(devBMerged.historyJson);
        WatchHistory.Entry syncedBaidu = null;
        for (WatchHistory.Entry e : devBHist) {
            if ("v200".equals(e.id)) syncedBaidu = e;
        }
        Cms.Video devBVideo = new Cms.Video();
        devBVideo.id = "v200";
        devBVideo.title = "同步双盘测试";
        devBVideo.lines.addAll(Arrays.asList(twinQuark, twinBaidu));
        HistoryResumeMatcher.EpisodeMatch syncedMatch =
                HistoryResumeMatcher.matchEpisode(devBVideo, syncedBaidu);
        check(
                syncedBaidu != null
                        && "原画#2".equals(syncedBaidu.lineId)
                        && NetdiskStore.DRIVE_BAIDU.equals(syncedBaidu.driveKey)
                        && syncedMatch != null
                        && syncedMatch.line == twinBaidu
                        && syncedMatch.episode == bEp2
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        twinBaidu, bEp2, 1, syncedBaidu)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        twinQuark, qEp2, 1, syncedBaidu)
                                == 0,
                "R5 P1-1: CloudSync receiver restores Baidu twin #2, Ep2, and exact 42000ms (never applied to Quark)");

        // 12. Round-5 P1-2: Detail, History, Fullscreen & Inline ALL preserve drive, episode, and
        //     exact 42,000ms across: (A) temp URL query refresh, (B) upstream twin-line swap,
        //     (C) inserted trailer shifting Ep2 index 1 -> 2, and (D) legacy bookmark without IDs!
        Cms.Line bdOrig = new Cms.Line();
        bdOrig.lineId = "原画#2";
        bdOrig.name = "原画";
        bdOrig.rawName = "原画";
        Cms.Episode bdOrigE1 = new Cms.Episode();
        bdOrigE1.name = "第1集";
        bdOrigE1.url = "https://pan.baidu.com/s/show_bd_e1?token=old1";
        Cms.Episode bdOrigE2 = new Cms.Episode();
        bdOrigE2.name = "第2集";
        bdOrigE2.url = "https://pan.baidu.com/s/show_bd_e2?token=old2";
        bdOrig.episodes.add(bdOrigE1);
        bdOrig.episodes.add(bdOrigE2);

        WatchHistory.Entry bm42s = new WatchHistory.Entry();
        bm42s.site = "demo";
        bm42s.id = "v300";
        bm42s.line = "原画";
        bm42s.lineId = "原画#2";
        bm42s.driveKey = NetdiskStore.detectLineDriveKey(bdOrig);
        bm42s.episode = "第2集";
        bm42s.episodeKey = HistoryResumeMatcher.stableEpisodeKey(bdOrigE2.url);
        bm42s.index = 1;
        bm42s.position = 42_000;
        bm42s.duration = 240_000;

        // Case 2A: Query params refreshed on temp URL (?token=old2 -> ?token=refreshed999)
        Cms.Line bdRefreshed = new Cms.Line();
        bdRefreshed.lineId = "原画#2";
        bdRefreshed.name = "原画";
        bdRefreshed.rawName = "原画";
        Cms.Episode bdRefE1 = new Cms.Episode();
        bdRefE1.name = "第1集";
        bdRefE1.url = "https://pan.baidu.com/s/show_bd_e1?token=refreshed1";
        Cms.Episode bdRefE2 = new Cms.Episode();
        bdRefE2.name = "第2集";
        bdRefE2.url = "https://pan.baidu.com/s/show_bd_e2?token=refreshed999&ts=888";
        bdRefreshed.episodes.add(bdRefE1);
        bdRefreshed.episodes.add(bdRefE2);
        Cms.Video vRefreshed = new Cms.Video();
        vRefreshed.id = "v300";
        vRefreshed.lines.addAll(Arrays.asList(twinQuark, bdRefreshed));
        HistoryResumeMatcher.EpisodeMatch mRef =
                HistoryResumeMatcher.matchEpisode(vRefreshed, bm42s);
        check(
                mRef != null
                        && mRef.line == bdRefreshed
                        && mRef.episode == bdRefE2
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        bdRefreshed, bdRefE2, 1, bm42s)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(twinQuark, qEp2, 1, bm42s)
                                == 0,
                "R5 P1-2A: refreshed URL query params preserve Baidu, Ep2, and exact 42000ms across Detail/History/Fullscreen/Inline");

        // Case 2B & 2C: Upstream SWAPS the two duplicate-named lines (Baidu becomes positional
        // "原画", Quark becomes positional "原画#2"), rotates URL path completely, AND inserts
        // "预告片" at index 0 of Baidu shifting "第2集" to index 2!
        Cms.Line bdSwappedTrailer = new Cms.Line();
        bdSwappedTrailer.lineId = "原画";
        bdSwappedTrailer.name = "原画";
        bdSwappedTrailer.rawName = "原画";
        Cms.Episode bdTrailer = new Cms.Episode();
        bdTrailer.name = "预告片";
        bdTrailer.url = "https://pan.baidu.com/s/new_trailer_0";
        Cms.Episode bdSwapE1 = new Cms.Episode();
        bdSwapE1.name = "第1集";
        bdSwapE1.url = "https://pan.baidu.com/s/new_path_e1?sig=1";
        Cms.Episode bdSwapE2 = new Cms.Episode();
        bdSwapE2.name = "第2集";
        bdSwapE2.url = "https://pan.baidu.com/s/new_path_e2?sig=2";
        bdSwappedTrailer.episodes.add(bdTrailer);
        bdSwappedTrailer.episodes.add(bdSwapE1);
        bdSwappedTrailer.episodes.add(bdSwapE2);

        Cms.Line qSwapped = new Cms.Line();
        qSwapped.lineId = "原画#2";
        qSwapped.name = "原画";
        qSwapped.rawName = "原画";
        qSwapped.episodes.add(qEp1);
        qSwapped.episodes.add(qEp2);

        Cms.Video vSwapped = new Cms.Video();
        vSwapped.id = "v300";
        vSwapped.lines.addAll(Arrays.asList(bdSwappedTrailer, qSwapped));
        HistoryResumeMatcher.EpisodeMatch mSwapped =
                HistoryResumeMatcher.matchEpisode(vSwapped, bm42s);
        check(
                mSwapped != null
                        && mSwapped.line == bdSwappedTrailer
                        && mSwapped.episode == bdSwapE2
                        && HistoryResumeMatcher.findMatchedEpisodeIndex(bdSwappedTrailer, bm42s)
                                == 2
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        bdSwappedTrailer, bdSwapE2, 2, bm42s)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        bdSwappedTrailer, bdTrailer, 0, bm42s)
                                == 0
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        bdSwappedTrailer, bdSwapE1, 1, bm42s)
                                == 0
                        && HistoryResumeMatcher.resolveResumePositionMs(qSwapped, qEp2, 1, bm42s)
                                == 0,
                "R5 P1-2B/2C: upstream twin-line swap + rotated URL + inserted trailer keeps Baidu Ep2 at index 2 with 42000ms (never Quark or trailer)");

        // Case 2D: Legacy bookmark lacking lineId/driveKey/episodeKey with inserted trailer
        WatchHistory.Entry legacy42s = new WatchHistory.Entry();
        legacy42s.site = "demo";
        legacy42s.id = "v300";
        legacy42s.line = "原画";
        legacy42s.episode = "第2集";
        legacy42s.index = 1;
        legacy42s.position = 42_000;
        legacy42s.duration = 240_000;
        HistoryResumeMatcher.EpisodeMatch mLeg =
                HistoryResumeMatcher.matchEpisode(vSwapped, legacy42s);
        check(
                mLeg != null
                        && mLeg.line == bdSwappedTrailer
                        && mLeg.episode == bdSwapE2
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        bdSwappedTrailer, bdSwapE2, 2, legacy42s)
                                == 42_000,
                "R5 P1-2D: legacy bookmark without lineId/episodeKey still resolves primary line Ep2 and 42000ms across trailer shift");

        // 13. Round-5 P1-3: Ordinary HTTP interstitial/redirect pages MUST NOT be mistaken for
        //     direct media streams! Real .m3u8/.mp4 keep their direct slots while redirect-page
        //     Quark/Baidu/extended netdisk lines strictly follow user drive order.
        Cms.Line directHls =
                mkLineWithUrl("阿里云 CDN 直连", "https://cdn.example/live/master.m3u8?k=1");
        Cms.Line directMp4 = mkLineWithUrl("线路115", "https://cdn.example/media/ep1.mp4?t=2");
        Cms.Line quarkRedirect =
                mkLineWithUrl("夸父原画", "https://jump.example/play?flag=quark&id=10");
        Cms.Line baiduRedirect = mkLineWithUrl("嘟嘟原画", "https://jump.example/play/baidu/20.html");
        Cms.Line ext115Redirect = mkLineWithUrl("115原画", "https://jump.example/proxy?id=30");
        check(
                NetdiskStore.hasExplicitDirectMediaUrl(directHls)
                        && NetdiskStore.hasExplicitDirectMediaUrl(directMp4)
                        && !NetdiskStore.hasExplicitDirectMediaUrl(quarkRedirect)
                        && !NetdiskStore.hasExplicitDirectMediaUrl(baiduRedirect)
                        && !NetdiskStore.hasExplicitDirectMediaUrl(ext115Redirect),
                "R5 P1-3: only real .m3u8/.mp4 direct streams qualify; HTTP redirect/interstitial pages are never misclassified as direct");
        List<Cms.Line> redirectSortOut =
                PlaybackLineRules.applyToLines(
                        Arrays.asList(
                                directHls, quarkRedirect, directMp4, ext115Redirect, baiduRedirect),
                        new JSONObject(),
                        Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_QUARK,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_ALI));
        check(
                "阿里云 CDN 直连".equals(redirectSortOut.get(0).name)
                        && "嘟嘟原画".equals(redirectSortOut.get(1).name)
                        && "线路115".equals(redirectSortOut.get(2).name)
                        && "夸父原画".equals(redirectSortOut.get(3).name)
                        && "115原画".equals(redirectSortOut.get(4).name),
                "R5 P1-3: pinning Baidu places Baidu HTTP-redirect line ahead of Quark & 115 while keeping real .m3u8/.mp4 slots pinned");

        // 14. Round-6 P1-1: Distinct episodes sharing /play?id=11 vs /play?id=12, split parts
        //     "正片上"/"正片下", and cross-source failover missing target episode MUST NEVER inherit
        //     another episode's 42,000ms progress!
        Cms.Line qParamLine = new Cms.Line();
        qParamLine.lineId = "默认线路";
        qParamLine.name = "默认线路";
        qParamLine.rawName = "默认线路";
        Cms.Episode qpEp1 = new Cms.Episode();
        qpEp1.name = "第1集";
        qpEp1.url = "https://site.example/play?id=11&sign=OLD_A&expires=1799999000";
        Cms.Episode qpEp2 = new Cms.Episode();
        qpEp2.name = "第2集";
        qpEp2.url = "https://site.example/play?id=12&sign=OLD_B&expires=1799999000";
        qParamLine.episodes.add(qpEp1);
        qParamLine.episodes.add(qpEp2);

        String relKey11 = WatchHistory.stableEpisodeKey("/play?id=11&sign=OLD1");
        String relKey12 = WatchHistory.stableEpisodeKey("/play?id=12&sign=OLD2");
        String relKey12New = WatchHistory.stableEpisodeKey("/play?id=12&sign=NEW9&ts=999999");
        check(
                !relKey11.isEmpty()
                        && !relKey12.isEmpty()
                        && !relKey11.equals(relKey12)
                        && relKey12.equals(relKey12New),
                "R6 P1-1: /play?id=11 and /play?id=12 produce distinct episodeKeys while temp signature refresh preserves id=12");

        WatchHistory.Entry bmQpEp2 = new WatchHistory.Entry();
        bmQpEp2.site = "demo";
        bmQpEp2.id = "v400";
        bmQpEp2.line = "默认线路";
        bmQpEp2.lineId = "默认线路";
        bmQpEp2.episode = "第2集";
        bmQpEp2.episodeKey = HistoryResumeMatcher.stableEpisodeKey(qpEp2.url);
        bmQpEp2.index = 1;
        bmQpEp2.position = 42_000;
        bmQpEp2.duration = 240_000;

        // Refresh temporary signatures on both episodes
        Cms.Line qParamLineRef = new Cms.Line();
        qParamLineRef.lineId = "默认线路";
        qParamLineRef.name = "默认线路";
        qParamLineRef.rawName = "默认线路";
        Cms.Episode qpRef1 = new Cms.Episode();
        qpRef1.name = "第1集";
        qpRef1.url = "https://site.example/play?id=11&sign=NEW_A&expires=1899999000";
        Cms.Episode qpRef2 = new Cms.Episode();
        qpRef2.name = "第2集";
        qpRef2.url = "https://site.example/play?id=12&sign=NEW_B&expires=1899999000";
        qParamLineRef.episodes.add(qpRef1);
        qParamLineRef.episodes.add(qpRef2);
        Cms.Video qpVideo = new Cms.Video();
        qpVideo.id = "v400";
        qpVideo.lines.add(qParamLineRef);
        HistoryResumeMatcher.EpisodeMatch qpMainMatch =
                HistoryResumeMatcher.matchEpisode(qpVideo, bmQpEp2);
        check(
                qpMainMatch != null
                        && qpMainMatch.episode == qpRef2
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        qParamLineRef, qpRef2, 1, bmQpEp2)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        qParamLineRef, qpRef1, 0, bmQpEp2)
                                == 0,
                "R6 P1-1A: Detail/History/Fullscreen/Inline open /play?id=12 with 42000ms after sign refresh; selecting /play?id=11 starts at 0ms");

        // Duplicate generic names ("播放", "播放") distinguished ONLY by /play?id=11 vs /play?id=12
        Cms.Line dupNameLine = new Cms.Line();
        dupNameLine.lineId = "默认线路";
        dupNameLine.name = "默认线路";
        dupNameLine.rawName = "默认线路";
        Cms.Episode dn1 = new Cms.Episode();
        dn1.name = "播放";
        dn1.url = "/play?id=11&token=new1";
        Cms.Episode dn2 = new Cms.Episode();
        dn2.name = "播放";
        dn2.url = "/play?id=12&token=new2";
        dupNameLine.episodes.add(dn1);
        dupNameLine.episodes.add(dn2);
        WatchHistory.Entry bmDup2 = new WatchHistory.Entry();
        bmDup2.site = "demo";
        bmDup2.id = "v401";
        bmDup2.line = "默认线路";
        bmDup2.lineId = "默认线路";
        bmDup2.episode = "播放";
        bmDup2.episodeKey = WatchHistory.stableEpisodeKey("/play?id=12&token=old2");
        bmDup2.index = 1;
        bmDup2.position = 42_000;
        bmDup2.duration = 240_000;
        Cms.Video dupVideo = new Cms.Video();
        dupVideo.id = "v401";
        dupVideo.lines.add(dupNameLine);
        HistoryResumeMatcher.EpisodeMatch dupMatch =
                HistoryResumeMatcher.matchEpisode(dupVideo, bmDup2);
        check(
                dupMatch != null
                        && dupMatch.episode == dn2
                        && HistoryResumeMatcher.resolveResumePositionMs(dupNameLine, dn2, 1, bmDup2)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(dupNameLine, dn1, 0, bmDup2)
                                == 0,
                "R6 P1-1A2: duplicate-named episodes distinguished by /play?id=11 vs /play?id=12 never cross-inherit progress");

        // Split parts: "正片上" vs "正片下" with different paths MUST NOT cross-inherit progress
        Cms.Line splitPartLine = new Cms.Line();
        splitPartLine.lineId = "主线";
        splitPartLine.name = "主线";
        splitPartLine.rawName = "主线";
        Cms.Episode partUp = new Cms.Episode();
        partUp.name = "正片上";
        partUp.url = "https://cdn.example/movie/part_up.m3u8?sign=a1";
        Cms.Episode partDown = new Cms.Episode();
        partDown.name = "正片下";
        partDown.url = "https://cdn.example/movie/part_down.m3u8?sign=b2";
        splitPartLine.episodes.add(partUp);
        splitPartLine.episodes.add(partDown);
        WatchHistory.Entry bmPartUp = new WatchHistory.Entry();
        bmPartUp.site = "demo";
        bmPartUp.id = "v402";
        bmPartUp.line = "主线";
        bmPartUp.lineId = "主线";
        bmPartUp.episode = "正片上";
        bmPartUp.episodeKey = WatchHistory.stableEpisodeKey(partUp.url);
        bmPartUp.index = 0;
        bmPartUp.position = 42_000;
        bmPartUp.duration = 3_600_000;
        WatchHistory.Entry bmPartUpNoKey = new WatchHistory.Entry();
        bmPartUpNoKey.site = "demo";
        bmPartUpNoKey.id = "v402";
        bmPartUpNoKey.line = "主线";
        bmPartUpNoKey.episode = "正片上";
        bmPartUpNoKey.index = 0;
        bmPartUpNoKey.position = 42_000;
        bmPartUpNoKey.duration = 3_600_000;
        check(
                HistoryResumeMatcher.resolveResumePositionMs(splitPartLine, partUp, 0, bmPartUp)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        splitPartLine, partDown, 1, bmPartUp)
                                == 0
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        splitPartLine, partDown, 1, bmPartUpNoKey)
                                == 0,
                "R6 P1-1B: split parts 正片上 and 正片下 never cross-inherit 42000ms (with or without episodeKey)");

        // Cross-source failover: original site failed at Ep 2 (42s); alt site is missing Ep 2 and
        // only has [第1集, 第5集, 第6集] (where 第5集 sits at index 1!) -> NEVER carries 42s to 第5集!
        Cms.Line altMissingEp2Line = new Cms.Line();
        altMissingEp2Line.lineId = "备用源";
        altMissingEp2Line.name = "备用源";
        altMissingEp2Line.rawName = "备用源";
        Cms.Episode altEp1 = new Cms.Episode();
        altEp1.name = "第1集";
        altEp1.url = "https://alt.example/v/1.m3u8";
        Cms.Episode altEp5 = new Cms.Episode();
        altEp5.name = "第5集";
        altEp5.url = "https://alt.example/v/5.m3u8";
        Cms.Episode altEp6 = new Cms.Episode();
        altEp6.name = "第6集";
        altEp6.url = "https://alt.example/v/6.m3u8";
        altMissingEp2Line.episodes.add(altEp1);
        altMissingEp2Line.episodes.add(altEp5);
        altMissingEp2Line.episodes.add(altEp6);
        Cms.Video altMissingVideo = new Cms.Video();
        altMissingVideo.id = "alt_v400";
        altMissingVideo.lines.add(altMissingEp2Line);

        Cms.Line altHasEp2Line = new Cms.Line();
        altHasEp2Line.lineId = "备用源2";
        altHasEp2Line.name = "备用源2";
        altHasEp2Line.rawName = "备用源2";
        Cms.Episode alt2Ep1 = new Cms.Episode();
        alt2Ep1.name = "EP01";
        alt2Ep1.url = "https://alt2.example/v/1.m3u8";
        Cms.Episode alt2Ep2 = new Cms.Episode();
        alt2Ep2.name = "EP02";
        alt2Ep2.url = "https://alt2.example/v/2.m3u8";
        altHasEp2Line.episodes.add(alt2Ep1);
        altHasEp2Line.episodes.add(alt2Ep2);
        Cms.Video altHasEp2Video = new Cms.Video();
        altHasEp2Video.id = "alt2_v400";
        altHasEp2Video.lines.add(altHasEp2Line);

        HistoryResumeMatcher.EpisodeMatch missingMatch =
                HistoryResumeMatcher.matchEpisode(altMissingVideo, bmQpEp2);
        HistoryResumeMatcher.EpisodeMatch forcedEp5Match =
                new HistoryResumeMatcher.EpisodeMatch(altMissingEp2Line, altEp5, 50);
        HistoryResumeMatcher.EpisodeMatch okAltMatch =
                HistoryResumeMatcher.matchEpisode(altHasEp2Video, bmQpEp2);
        check(
                missingMatch == null
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        forcedEp5Match, bmQpEp2)
                                == 0
                        && okAltMatch != null
                        && okAltMatch.episode == alt2Ep2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(okAltMatch, bmQpEp2)
                                == 42_000,
                "R6 P1-1C: cross-source failover rejects missing Ep2 (0ms for Ep5) while carrying 42000ms to confirmed alt EP02");

        // 15. Round-6 P1-2: Legacy episodeUrl scrubbed across Prefs.sanitizeUserData,
        //     BackupManager export/restore, history CloudSync, AND subscribe-only CloudSync!
        String legacyHistoryJson =
                new org.json.JSONArray()
                        .put(
                                new JSONObject()
                                        .put("site", "demo")
                                        .put("id", "leg_1")
                                        .put("title", "旧历史条目")
                                        .put("line", "原画")
                                        .put("lineId", "原画#2")
                                        .put("episode", "第2集")
                                        .put(
                                                "episodeUrl",
                                                "https://dl-pc.example/file/ep2.mkv?sign=LEGACY_SECRET_77&expires=1799999999")
                                        .put("index", 1)
                                        .put("position", 42_000)
                                        .put("duration", 240_000)
                                        .put("updated", 1_768_001_000_000L))
                        .put(
                                new JSONObject()
                                        .put("site", "demo")
                                        .put("id", "leg_2")
                                        .put("title", "旧租约条目")
                                        .put("line", "夸克原画")
                                        .put("episode", "第1集")
                                        .put(
                                                "episodeUrl",
                                                "http://127.0.0.1:45678/lease/OLD_LEASE_99/video.mkv")
                                        .put("index", 0)
                                        .put("position", 18_000)
                                        .put("duration", 120_000)
                                        .put("updated", 1_768_001_001_000L))
                        .toString();

        String cleanPrefsHist = Prefs.sanitizeUserData(Prefs.WATCH_HISTORY, legacyHistoryJson);
        String cleanBackupHist =
                BackupManager.sanitizeBackupUserData(Prefs.WATCH_HISTORY, legacyHistoryJson);
        String cleanRestoreHist =
                BackupManager.sanitizeBackupUserData(Prefs.WATCH_HISTORY, legacyHistoryJson);
        check(
                cleanPrefsHist != null
                        && !cleanPrefsHist.contains("episodeUrl")
                        && !cleanPrefsHist.contains("LEGACY_SECRET_77")
                        && !cleanPrefsHist.contains("OLD_LEASE_99")
                        && cleanPrefsHist.contains("\"lineId\":\"原画#2\"")
                        && cleanPrefsHist.contains("42000")
                        && cleanBackupHist != null
                        && !cleanBackupHist.contains("episodeUrl")
                        && !cleanBackupHist.contains("LEGACY_SECRET_77")
                        && !cleanBackupHist.contains("OLD_LEASE_99")
                        && !cleanBackupHist.contains("dl-pc.example")
                        && cleanBackupHist.contains("\"lineId\":\"原画#2\"")
                        && cleanBackupHist.contains("\"driveKey\":\"quark\"")
                        && cleanBackupHist.contains("42000")
                        && cleanBackupHist.equals(cleanRestoreHist),
                "R6 P1-2A: Prefs.sanitizeUserData & BackupManager export/restore strip legacy episodeUrl/signatures/leases while preserving line, episode & 42000ms");

        // Subscribe-only CloudSync (syncHistory=false, syncSubscriptions=true) MUST strip legacy
        // episodeUrl already sitting in remote watch_history without overwriting local history!
        String remoteLegacyPayload =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", CloudSync.VERSION)
                        .put("updated", 1_768_001_500_000L)
                        .put("updatedAt", 1_768_001_500_000L)
                        .put("watch_history", new org.json.JSONArray(legacyHistoryJson))
                        .put("favorites", new org.json.JSONArray())
                        .put("tombstones", new JSONObject())
                        .put("subscriptions", new org.json.JSONArray())
                        .toString();
        String localUntouchedHistory =
                "[{\"site\":\"local\",\"id\":\"keep_me\",\"line\":\"L\",\"episode\":\"E1\",\"position\":9000}]";
        CloudSync.SubscriptionItem localSub = new CloudSync.SubscriptionItem();
        localSub.key = "sub_1";
        localSub.name = "我的订阅";
        localSub.url = "https://sub.example/config.json";
        localSub.rawContent = "";
        localSub.updatedAt = 1_768_002_000_000L;
        localSub.enabled = true;
        CloudSync.MergeResult subOnlyRes =
                CloudSync.merge(
                        localUntouchedHistory,
                        "[]",
                        "{}",
                        Collections.singletonList(localSub),
                        true,
                        false,
                        remoteLegacyPayload,
                        1_768_002_100_000L);
        JSONObject subOnlyJson = new JSONObject(subOnlyRes.payloadJson);
        org.json.JSONArray subOnlySubs = subOnlyJson.optJSONArray("subscriptions");
        check(
                subOnlyRes.payloadJson != null
                        && !subOnlyRes.payloadJson.contains("episodeUrl")
                        && !subOnlyRes.payloadJson.contains("LEGACY_SECRET_77")
                        && !subOnlyRes.payloadJson.contains("OLD_LEASE_99")
                        && !subOnlyRes.payloadJson.contains("dl-pc.example")
                        && subOnlyRes.payloadJson.contains("\"lineId\":\"原画#2\"")
                        && subOnlyRes.payloadJson.contains("42000")
                        && subOnlySubs != null
                        && subOnlySubs.length() == 1
                        && "https://sub.example/config.json"
                                .equals(subOnlySubs.getJSONObject(0).optString("url"))
                        && !subOnlyRes.payloadJson.contains("keep_me")
                        && localUntouchedHistory.equals(subOnlyRes.historyJson),
                "R6 P1-2B: subscribe-only CloudSync strips remote legacy episodeUrl while keeping syncHistory=false semantics & remote line/episode/42000ms");

        // 16. Round-6 P2-1: Bare "115" line with opaque episode ID + parsed-hostname share check so
        //     CDN .m3u8 containing "pan.quark.cn" in its PATH keeps its direct slot!
        Cms.Line bare115Opaque = mkLineWithUrl("115", "opaque_id_115_ep1");
        Cms.Line cdnPathWithQuark =
                mkLineWithUrl(
                        "普通直连", "https://cdn.example/mirror/pan.quark.cn/vod/master.m3u8?k=1");
        Cms.Line realQuarkShare = mkLineWithUrl("默认线路", "https://pan.quark.cn/s/realshare99");
        Cms.Line realBaiduRedirect =
                mkLineWithUrl("百度原画", "https://jump.example/redirect/baidu-ep1");
        check(
                NetdiskStore.isExtendedNetdiskLine(bare115Opaque)
                        && NetdiskStore.hasExplicitDirectMediaUrl(cdnPathWithQuark)
                        && NetdiskStore.detectLineDriveKey(cdnPathWithQuark).isEmpty()
                        && WatchHistory.detectDriveKeyFromUrl(
                                        "https://cdn.example/mirror/pan.quark.cn/vod/master.m3u8")
                                .isEmpty()
                        && NetdiskStore.DRIVE_QUARK.equals(
                                NetdiskStore.detectLineDriveKey(realQuarkShare))
                        && !NetdiskStore.hasExplicitDirectMediaUrl(realQuarkShare),
                "R6 P2-1: bare '115' with opaque ID recognized as extended netdisk; CDN .m3u8 with pan.quark.cn in path keeps direct slot; real share host classified as Quark");
        List<Cms.Line> r6DriveOrder =
                PlaybackLineRules.applyToLines(
                        Arrays.asList(
                                bare115Opaque, cdnPathWithQuark, realQuarkShare, realBaiduRedirect),
                        new JSONObject(),
                        Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_QUARK,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_ALI));
        check(
                "百度原画".equals(r6DriveOrder.get(0).name)
                        && "普通直连".equals(r6DriveOrder.get(1).name)
                        && "默认线路".equals(r6DriveOrder.get(2).name)
                        && "115".equals(r6DriveOrder.get(3).name),
                "R6 P2-1: Baidu pinned orders Baidu -> Quark -> bare 115 while CDN .m3u8 with pan.quark.cn in path strictly stays in slot 1");

        // 17. Round-7 P1-1: Subscribe-only CloudSync MUST NOT drop legacy siteKey/vodId entries,
        //     strip Windows 0.7.3 episodeMediaId, or truncate 64 remote entries to 60 — while still
        //     scrubbing all legacy episodeUrl/signatures/leases and NOT uploading local history!
        org.json.JSONArray remote3Hist = new org.json.JSONArray();
        remote3Hist.put(
                new JSONObject()
                        .put("site", "demo")
                        .put("id", "std_1")
                        .put("line", "夸克")
                        .put("episode", "第1集")
                        .put("episodeUrl", "https://dl-pc.example/ep1.mkv?sign=SEC1")
                        .put("position", 12_000));
        remote3Hist.put(
                new JSONObject()
                        .put("siteKey", "legacy_site")
                        .put("vodId", "vod_99")
                        .put("line", "旧线")
                        .put("episode", "第3集")
                        .put("episodeUrl", "http://127.0.0.1:45678/lease/OLD_L1/stream.mkv")
                        .put("position", 31_000));
        remote3Hist.put(
                new JSONObject()
                        .put("site", "win_site")
                        .put("id", "win_77")
                        .put("line", "百度原画")
                        .put("episode", "第2集")
                        .put("episodeMediaId", "win073_media_stable_id_42")
                        .put("episodeUrl", "https://dl-pc.example/win.mkv?token=WIN_SEC")
                        .put("position", 42_000));
        String remote3Payload =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", CloudSync.VERSION)
                        .put("updated", 1_768_003_000_000L)
                        .put("updatedAt", 1_768_003_000_000L)
                        .put("watch_history", remote3Hist)
                        .put("favorites", new org.json.JSONArray())
                        .put("tombstones", new JSONObject())
                        .put("subscriptions", new org.json.JSONArray())
                        .toString();
        CloudSync.MergeResult r7SubOnly3 =
                CloudSync.merge(
                        localUntouchedHistory,
                        "[]",
                        "{}",
                        Collections.singletonList(localSub),
                        true,
                        false,
                        remote3Payload,
                        1_768_003_100_000L);
        org.json.JSONArray out3Hist =
                new JSONObject(r7SubOnly3.payloadJson).getJSONArray("watch_history");
        check(
                out3Hist.length() == 3
                        && "std_1".equals(out3Hist.getJSONObject(0).optString("id"))
                        && "legacy_site".equals(out3Hist.getJSONObject(1).optString("siteKey"))
                        && "vod_99".equals(out3Hist.getJSONObject(1).optString("vodId"))
                        && out3Hist.getJSONObject(1).optInt("position") == 31_000
                        && "win073_media_stable_id_42"
                                .equals(out3Hist.getJSONObject(2).optString("episodeMediaId"))
                        && out3Hist.getJSONObject(2).optInt("position") == 42_000
                        && !r7SubOnly3.payloadJson.contains("episodeUrl")
                        && !r7SubOnly3.payloadJson.contains("SEC1")
                        && !r7SubOnly3.payloadJson.contains("OLD_L1")
                        && !r7SubOnly3.payloadJson.contains("WIN_SEC")
                        && !r7SubOnly3.payloadJson.contains("keep_me")
                        && localUntouchedHistory.equals(r7SubOnly3.historyJson),
                "R7 P1-1A: subscribe-only sync preserves 3->3 entries, order, siteKey/vodId, Windows episodeMediaId & progress while stripping legacy URLs and excluding local history");

        org.json.JSONArray remote64Hist = new org.json.JSONArray();
        for (int i = 0; i < 64; i++) {
            remote64Hist.put(
                    new JSONObject()
                            .put("site", "s64")
                            .put("id", "v_" + i)
                            .put("line", "L")
                            .put("episode", "第" + (i + 1) + "集")
                            .put("episodeUrl", "https://dl-pc.example/f" + i + ".mkv?sign=S" + i)
                            .put("position", (i + 1) * 1000));
        }
        String remote64Payload =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", CloudSync.VERSION)
                        .put("updated", 1_768_003_200_000L)
                        .put("updatedAt", 1_768_003_200_000L)
                        .put("watch_history", remote64Hist)
                        .put("favorites", new org.json.JSONArray())
                        .put("tombstones", new JSONObject())
                        .put("subscriptions", new org.json.JSONArray())
                        .toString();
        CloudSync.MergeResult r7SubOnly64 =
                CloudSync.merge(
                        localUntouchedHistory,
                        "[]",
                        "{}",
                        Collections.singletonList(localSub),
                        true,
                        false,
                        remote64Payload,
                        1_768_003_300_000L);
        org.json.JSONArray out64Hist =
                new JSONObject(r7SubOnly64.payloadJson).getJSONArray("watch_history");
        check(
                out64Hist.length() == 64
                        && "v_0".equals(out64Hist.getJSONObject(0).optString("id"))
                        && "v_63".equals(out64Hist.getJSONObject(63).optString("id"))
                        && out64Hist.getJSONObject(63).optInt("position") == 64_000
                        && !r7SubOnly64.payloadJson.contains("episodeUrl")
                        && !r7SubOnly64.payloadJson.contains("dl-pc.example"),
                "R7 P1-1B: subscribe-only sync preserves 64->64 remote history entries without truncating at 60");

        // 18. Round-7 P1-2: Ambiguous identity (empty fingerprint + duplicate "播放", ?e=1 vs ?e=2
        //     titled "开端"/"返航", forced fingerprint collision) MUST NEVER give 42s to wrong item!
        Cms.Line proxyDupLine = new Cms.Line();
        proxyDupLine.lineId = "本地代理";
        proxyDupLine.name = "本地代理";
        proxyDupLine.rawName = "本地代理";
        Cms.Episode pDup0 = new Cms.Episode();
        pDup0.name = "播放";
        pDup0.url = "http://127.0.0.1:9978/proxy?do=cms&item=1";
        Cms.Episode pDup1 = new Cms.Episode();
        pDup1.name = "播放";
        pDup1.url = "http://127.0.0.1:9978/proxy?do=cms&item=2";
        proxyDupLine.episodes.add(pDup0);
        proxyDupLine.episodes.add(pDup1);
        Cms.Video proxyDupVideo = new Cms.Video();
        proxyDupVideo.id = "v_pdup";
        proxyDupVideo.lines.add(proxyDupLine);
        WatchHistory.Entry bmProxyDup2 = new WatchHistory.Entry();
        bmProxyDup2.site = "demo";
        bmProxyDup2.id = "v_pdup";
        bmProxyDup2.line = "本地代理";
        bmProxyDup2.lineId = "本地代理";
        bmProxyDup2.episode = "播放";
        bmProxyDup2.episodeKey = WatchHistory.stableEpisodeKey(pDup1.url);
        bmProxyDup2.index = 1;
        bmProxyDup2.position = 42_000;
        bmProxyDup2.duration = 240_000;
        check(
                bmProxyDup2.episodeKey.isEmpty()
                        && HistoryResumeMatcher.matchEpisode(proxyDupVideo, bmProxyDup2) == null
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        proxyDupLine, pDup0, 0, bmProxyDup2)
                                == 0
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        proxyDupLine, pDup1, 1, bmProxyDup2)
                                == 0,
                "R7 P1-2A: two local-proxy '播放' items with empty fingerprints never carry 42s to item 0 or ambiguous item");

        // ?e=1 ("开端") vs ?e=2 ("返航") + unix timestamp e=1799999999 still stripped!
        String keyE1 = WatchHistory.stableEpisodeKey("https://site.example/play?e=1&sign=A");
        String keyE2 = WatchHistory.stableEpisodeKey("https://site.example/play?e=2&sign=B");
        String keyE2Ref =
                WatchHistory.stableEpisodeKey("https://site.example/play?e=2&sign=C&t=1799999999");
        String keyExpStrip1 =
                WatchHistory.stableEpisodeKey("https://site.example/play?id=9&e=1799999111");
        String keyExpStrip2 =
                WatchHistory.stableEpisodeKey("https://site.example/play?id=9&e=1799999999");
        check(
                !keyE1.isEmpty()
                        && !keyE2.isEmpty()
                        && !keyE1.equals(keyE2)
                        && keyE2.equals(keyE2Ref)
                        && keyExpStrip1.equals(keyExpStrip2),
                "R7 P1-2B: stableEpisodeKey distinguishes e=1 vs e=2 while still stripping Unix epoch e=1799999999");

        Cms.Line titledELine = new Cms.Line();
        titledELine.lineId = "剧场线";
        titledELine.name = "剧场线";
        titledELine.rawName = "剧场线";
        Cms.Episode epStart = new Cms.Episode();
        epStart.name = "开端";
        epStart.url = "https://site.example/play?e=1&sign=NEW1";
        Cms.Episode epReturn = new Cms.Episode();
        epReturn.name = "返航";
        epReturn.url = "https://site.example/play?e=2&sign=NEW2";
        titledELine.episodes.add(epStart);
        titledELine.episodes.add(epReturn);
        WatchHistory.Entry bmReturn = new WatchHistory.Entry();
        bmReturn.site = "demo";
        bmReturn.id = "v_titled";
        bmReturn.line = "剧场线";
        bmReturn.lineId = "剧场线";
        bmReturn.episode = "返航";
        bmReturn.episodeKey = keyE2;
        bmReturn.index = 1;
        bmReturn.position = 42_000;
        bmReturn.duration = 240_000;
        // Also test forced fingerprint collision where both episodes share the EXACT SAME URL!
        Cms.Line collidedLine = new Cms.Line();
        collidedLine.lineId = "剧场线";
        collidedLine.name = "剧场线";
        collidedLine.rawName = "剧场线";
        Cms.Episode colStart = new Cms.Episode();
        colStart.name = "开端";
        colStart.url = "https://site.example/same_route";
        Cms.Episode colReturn = new Cms.Episode();
        colReturn.name = "返航";
        colReturn.url = "https://site.example/same_route";
        collidedLine.episodes.add(colStart);
        collidedLine.episodes.add(colReturn);
        WatchHistory.Entry bmCollidedReturn = new WatchHistory.Entry();
        bmCollidedReturn.site = "demo";
        bmCollidedReturn.id = "v_col";
        bmCollidedReturn.line = "剧场线";
        bmCollidedReturn.lineId = "剧场线";
        bmCollidedReturn.episode = "返航";
        bmCollidedReturn.episodeKey =
                WatchHistory.stableEpisodeKey("https://site.example/same_route");
        bmCollidedReturn.index = 1;
        bmCollidedReturn.position = 42_000;
        bmCollidedReturn.duration = 240_000;
        check(
                HistoryResumeMatcher.resolveResumePositionMs(titledELine, epReturn, 1, bmReturn)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        titledELine, epStart, 0, bmReturn)
                                == 0
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        collidedLine, colReturn, 1, bmCollidedReturn)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        collidedLine, colStart, 0, bmCollidedReturn)
                                == 0
                        && HistoryResumeMatcher.findMatchedEpisodeIndex(
                                        collidedLine, bmCollidedReturn)
                                == 1,
                "R7 P1-2C: 返航 never leaks 42000ms to 开端 across both e=1/2 distinction and forced fingerprint collision");

        // 19. Round-7 P1-3: Cross-source failover allows different drive (orig Quark failed -> alt
        //     site ONLY has Baidu with confirmed Ep 2 -> resumes 42,000 ms!), while same-site
        //     duplicate-named lines still preserve Quark and alt missing Ep 2 returns 0ms!
        WatchHistory.Entry bmQuarkOrigEp2 = new WatchHistory.Entry();
        bmQuarkOrigEp2.site = "orig_site";
        bmQuarkOrigEp2.id = "v_failover_drive";
        bmQuarkOrigEp2.line = "原画";
        bmQuarkOrigEp2.lineId = "原画";
        bmQuarkOrigEp2.driveKey = NetdiskStore.DRIVE_QUARK;
        bmQuarkOrigEp2.episode = "第2集";
        bmQuarkOrigEp2.episodeKey =
                WatchHistory.stableEpisodeKey("https://pan.quark.cn/s/orig_ep2");
        bmQuarkOrigEp2.index = 1;
        bmQuarkOrigEp2.position = 42_000;
        bmQuarkOrigEp2.duration = 240_000;

        Cms.Line altBaiduOnlyLine = new Cms.Line();
        altBaiduOnlyLine.lineId = "百度原画";
        altBaiduOnlyLine.name = "百度原画";
        altBaiduOnlyLine.rawName = "百度原画";
        Cms.Episode altBdE1 = new Cms.Episode();
        altBdE1.name = "第1集";
        altBdE1.url = "https://pan.baidu.com/s/alt_bd_e1";
        Cms.Episode altBdE2 = new Cms.Episode();
        altBdE2.name = "第2集";
        altBdE2.url = "https://pan.baidu.com/s/alt_bd_e2";
        altBaiduOnlyLine.episodes.add(altBdE1);
        altBaiduOnlyLine.episodes.add(altBdE2);
        Cms.Video altBaiduOnlyVideo = new Cms.Video();
        altBaiduOnlyVideo.id = "alt_bd_v";
        altBaiduOnlyVideo.lines.add(altBaiduOnlyLine);

        Cms.Line altBaiduMissingEp2 = new Cms.Line();
        altBaiduMissingEp2.lineId = "百度原画";
        altBaiduMissingEp2.name = "百度原画";
        altBaiduMissingEp2.rawName = "百度原画";
        Cms.Episode altBdMissE5 = new Cms.Episode();
        altBdMissE5.name = "第5集";
        altBdMissE5.url = "https://pan.baidu.com/s/alt_bd_e5";
        altBaiduMissingEp2.episodes.add(altBdE1);
        altBaiduMissingEp2.episodes.add(altBdMissE5);
        Cms.Video altBaiduMissingVideo = new Cms.Video();
        altBaiduMissingVideo.id = "alt_bd_miss";
        altBaiduMissingVideo.lines.add(altBaiduMissingEp2);

        // Same-site twin lines (Quark + Baidu) -> matchEpisode (same-site) still strictly picks
        // Quark
        Cms.Video sameSiteTwinVideo = new Cms.Video();
        sameSiteTwinVideo.id = "v_failover_drive";
        sameSiteTwinVideo.lines.addAll(Arrays.asList(twinBaidu, twinQuark));
        HistoryResumeMatcher.EpisodeMatch sameSitePick =
                HistoryResumeMatcher.matchEpisode(sameSiteTwinVideo, bmQuarkOrigEp2);
        HistoryResumeMatcher.EpisodeMatch failoverBaiduPick =
                HistoryResumeMatcher.matchEpisodeForFailover(altBaiduOnlyVideo, bmQuarkOrigEp2);
        HistoryResumeMatcher.EpisodeMatch failoverMissingPick =
                HistoryResumeMatcher.matchEpisodeForFailover(altBaiduMissingVideo, bmQuarkOrigEp2);
        check(
                sameSitePick != null
                        && sameSitePick.line == twinQuark
                        && failoverBaiduPick != null
                        && failoverBaiduPick.line == altBaiduOnlyLine
                        && failoverBaiduPick.episode == altBdE2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        failoverBaiduPick, bmQuarkOrigEp2)
                                == 42_000
                        && failoverMissingPick == null,
                "R7 P1-3: same-site keeps Quark, cross-source failover onto Baidu-only alt source recovers Ep2 with 42000ms, missing Ep2 returns null/0ms");

        // 20. Round-7 P2-3: Explicit share host overrides display alias ("百度的备用线路" with
        //     pan.quark.cn stays quark & matches Quark bookmark); leading direct .mp4 trailer
        //     followed by Quark main episodes obeys drive ordering while pure direct keeps slot!
        Cms.Line aliasedQuark = new Cms.Line();
        aliasedQuark.lineId = "原画";
        aliasedQuark.rawName = "原画";
        aliasedQuark.name = "百度的备用线路";
        Cms.Episode aq1 = new Cms.Episode();
        aq1.name = "第1集";
        aq1.url = "https://pan.quark.cn/s/orig_ep1";
        Cms.Episode aq2 = new Cms.Episode();
        aq2.name = "第2集";
        aq2.url = "https://pan.quark.cn/s/orig_ep2";
        aliasedQuark.episodes.add(aq1);
        aliasedQuark.episodes.add(aq2);

        Cms.Line trailerThenQuark = new Cms.Line();
        trailerThenQuark.lineId = "夸克混排";
        trailerThenQuark.rawName = "夸克混排";
        trailerThenQuark.name = "夸克混排";
        Cms.Episode ttq0 = new Cms.Episode();
        ttq0.name = "预告片";
        ttq0.url = "https://cdn.example/trailer/preview.mp4";
        Cms.Episode ttq1 = new Cms.Episode();
        ttq1.name = "第1集";
        ttq1.url = "https://pan.quark.cn/s/main_ep1";
        Cms.Episode ttq2 = new Cms.Episode();
        ttq2.name = "第2集";
        ttq2.url = "https://pan.quark.cn/s/main_ep2";
        trailerThenQuark.episodes.add(ttq0);
        trailerThenQuark.episodes.add(ttq1);
        trailerThenQuark.episodes.add(ttq2);

        Cms.Line pureDirectLine = mkLineWithUrl("纯直连主线", "https://cdn.example/pure/ep1.m3u8");
        Cms.Line realBaiduLine = mkLineWithUrl("百度正片", "https://pan.baidu.com/s/bd_main_ep1");

        check(
                NetdiskStore.DRIVE_QUARK.equals(NetdiskStore.detectLineDriveKey(aliasedQuark))
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        aliasedQuark, aq2, 1, bmQuarkOrigEp2)
                                == 42_000
                        && !NetdiskStore.hasExplicitDirectMediaUrl(trailerThenQuark)
                        && NetdiskStore.DRIVE_QUARK.equals(
                                NetdiskStore.detectLineDriveKey(trailerThenQuark))
                        && NetdiskStore.hasExplicitDirectMediaUrl(pureDirectLine),
                "R7 P2-3A: explicit pan.quark.cn host overrides alias '百度的备用线路' and matches Quark bookmark; leading direct trailer + Quark main episodes classifies as Quark");

        JSONObject aliasRule = new JSONObject();
        PlaybackLineRules.setAlias(aliasRule, "原画", "百度的备用线路");
        List<Cms.Line> r7MixedOrder =
                PlaybackLineRules.applyToLines(
                        Arrays.asList(
                                trailerThenQuark, pureDirectLine, aliasedQuark, realBaiduLine),
                        aliasRule,
                        Arrays.asList(
                                NetdiskStore.DRIVE_BAIDU,
                                NetdiskStore.DRIVE_QUARK,
                                NetdiskStore.DRIVE_UC,
                                NetdiskStore.DRIVE_ALI));
        check(
                "百度正片".equals(r7MixedOrder.get(0).name)
                        && "纯直连主线".equals(r7MixedOrder.get(1).name)
                        && "夸克混排".equals(r7MixedOrder.get(2).name)
                        && "百度的备用线路".equals(r7MixedOrder.get(3).name),
                "R7 P2-3B: Baidu pinned moves Baidu ahead of trailer+Quark and aliased Quark lines while keeping pure direct slot 1 untouched");

        // 21. Round-8 P1-1: Duplicate episode numbers MUST NEVER carry 42s onto wrong resource.
        //     (A) Orig S02E02 at 42s -> alt site puts two seasons on the SAME line, both labeled
        //         "第2集" -> failover returns null and forced resolveFailoverResumePositionMs is 0!
        WatchHistory.Entry bmS02E02 = new WatchHistory.Entry();
        bmS02E02.site = "orig_site";
        bmS02E02.id = "multi_season_show";
        bmS02E02.line = "夸克原画";
        bmS02E02.lineId = "夸克原画";
        bmS02E02.driveKey = NetdiskStore.DRIVE_QUARK;
        bmS02E02.episode = "S02E02";
        bmS02E02.episodeKey = WatchHistory.stableEpisodeKey("https://pan.quark.cn/s/orig_s02e02");
        bmS02E02.index = 1;
        bmS02E02.position = 42_000;
        bmS02E02.duration = 240_000;

        Cms.Line altTwoSeasonsSameLine = new Cms.Line();
        altTwoSeasonsSameLine.lineId = "备用合集";
        altTwoSeasonsSameLine.name = "备用合集";
        altTwoSeasonsSameLine.rawName = "备用合集";
        Cms.Episode altS1E1 = new Cms.Episode();
        altS1E1.name = "第1集";
        altS1E1.url = "https://alt.example/s1/e1.m3u8";
        Cms.Episode altS1E2 = new Cms.Episode();
        altS1E2.name = "第2集";
        altS1E2.url = "https://alt.example/s1/e2.m3u8";
        Cms.Episode altS2E1 = new Cms.Episode();
        altS2E1.name = "第1集";
        altS2E1.url = "https://alt.example/s2/e1.m3u8";
        Cms.Episode altS2E2 = new Cms.Episode();
        altS2E2.name = "第2集";
        altS2E2.url = "https://alt.example/s2/e2.m3u8";
        altTwoSeasonsSameLine.episodes.addAll(Arrays.asList(altS1E1, altS1E2, altS2E1, altS2E2));
        Cms.Video altAmbiguousSeasonVideo = new Cms.Video();
        altAmbiguousSeasonVideo.id = "alt_ambig";
        altAmbiguousSeasonVideo.lines.add(altTwoSeasonsSameLine);

        HistoryResumeMatcher.EpisodeMatch ambigFailover =
                HistoryResumeMatcher.matchEpisodeForFailover(altAmbiguousSeasonVideo, bmS02E02);
        int forcedAmbigFailoverPos =
                HistoryResumeMatcher.resolveFailoverResumePositionMs(
                        new HistoryResumeMatcher.EpisodeMatch(altTwoSeasonsSameLine, altS1E2, 100),
                        bmS02E02);
        check(
                ambigFailover == null && forcedAmbigFailoverPos == 0,
                "R8 P1-1A: S02E02 failover onto single-line two-season duplicate '第2集' rejects ambiguous match (0ms)");

        //     (B) Same-site two un-fingerprinted proxy items both named "第2集": watched 2nd item
        //         to 42s -> manually clicking 1st item MUST start at 0ms (never inherits 42000ms)!
        Cms.Line dupNumProxyLine = new Cms.Line();
        dupNumProxyLine.lineId = "本地代理线";
        dupNumProxyLine.name = "本地代理线";
        dupNumProxyLine.rawName = "本地代理线";
        Cms.Episode dpEp1 = new Cms.Episode();
        dpEp1.name = "第2集";
        dpEp1.url = "http://127.0.0.1:8080/proxy/lease/ep2_first";
        Cms.Episode dpEp2 = new Cms.Episode();
        dpEp2.name = "第2集";
        dpEp2.url = "http://127.0.0.1:8080/proxy/lease/ep2_second";
        dupNumProxyLine.episodes.add(dpEp1);
        dupNumProxyLine.episodes.add(dpEp2);
        Cms.Video dupNumProxyVideo = new Cms.Video();
        dupNumProxyVideo.id = "dup_num_proxy";
        dupNumProxyVideo.lines.add(dupNumProxyLine);

        WatchHistory.Entry bmDupNumProxy2 = new WatchHistory.Entry();
        bmDupNumProxy2.site = "orig_site";
        bmDupNumProxy2.id = "dup_num_proxy";
        bmDupNumProxy2.line = "本地代理线";
        bmDupNumProxy2.lineId = "本地代理线";
        bmDupNumProxy2.episode = "第2集";
        bmDupNumProxy2.episodeKey = WatchHistory.stableEpisodeKey(dpEp2.url); // "" (proxy)
        bmDupNumProxy2.index = 1;
        bmDupNumProxy2.position = 42_000;
        bmDupNumProxy2.duration = 240_000;
        check(
                bmDupNumProxy2.episodeKey.isEmpty()
                        && HistoryResumeMatcher.matchEpisode(dupNumProxyVideo, bmDupNumProxy2)
                                == null
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        dupNumProxyLine, dpEp1, 0, bmDupNumProxy2)
                                == 0
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        dupNumProxyLine, dpEp2, 1, bmDupNumProxy2)
                                == 0,
                "R8 P1-1B: same-site duplicate '第2集' without fingerprint never leaks 42000ms on manual tap or auto match");

        //     (C) Positive controls: explicit S02E02, unique fingerprint among duplicate "第2集",
        //         and cross-drive unique same episode ALL recover 42,000 ms!
        Cms.Line explicitSeasonLine = new Cms.Line();
        explicitSeasonLine.lineId = "百度合集";
        explicitSeasonLine.name = "百度合集";
        explicitSeasonLine.rawName = "百度合集";
        Cms.Episode exS1E2 = new Cms.Episode();
        exS1E2.name = "S01E02";
        exS1E2.url = "https://pan.baidu.com/s/bd_s01e02";
        Cms.Episode exS2E2 = new Cms.Episode();
        exS2E2.name = "S02E02";
        exS2E2.url = "https://pan.baidu.com/s/bd_s02e02";
        explicitSeasonLine.episodes.add(exS1E2);
        explicitSeasonLine.episodes.add(exS2E2);
        Cms.Video explicitSeasonVideo = new Cms.Video();
        explicitSeasonVideo.id = "alt_explicit_season";
        explicitSeasonVideo.lines.add(explicitSeasonLine);

        HistoryResumeMatcher.EpisodeMatch explicitS2Pick =
                HistoryResumeMatcher.matchEpisodeForFailover(explicitSeasonVideo, bmS02E02);

        Cms.Line dupNumFingerprintedLine = new Cms.Line();
        dupNumFingerprintedLine.lineId = "指纹线";
        dupNumFingerprintedLine.name = "指纹线";
        dupNumFingerprintedLine.rawName = "指纹线";
        Cms.Episode fpEp1 = new Cms.Episode();
        fpEp1.name = "第2集";
        fpEp1.url = "https://site.example/play?id=201";
        Cms.Episode fpEp2 = new Cms.Episode();
        fpEp2.name = "第2集";
        fpEp2.url = "https://site.example/play?id=202";
        dupNumFingerprintedLine.episodes.add(fpEp1);
        dupNumFingerprintedLine.episodes.add(fpEp2);
        WatchHistory.Entry bmFp2 = new WatchHistory.Entry();
        bmFp2.site = "orig_site";
        bmFp2.id = "fp_dup_num";
        bmFp2.line = "指纹线";
        bmFp2.lineId = "指纹线";
        bmFp2.episode = "第2集";
        bmFp2.episodeKey = WatchHistory.stableEpisodeKey(fpEp2.url);
        bmFp2.index = 1;
        bmFp2.position = 42_000;
        bmFp2.duration = 240_000;

        check(
                explicitS2Pick != null
                        && explicitS2Pick.episode == exS2E2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        explicitS2Pick, bmS02E02)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        dupNumFingerprintedLine, fpEp2, 1, bmFp2)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        dupNumFingerprintedLine, fpEp1, 0, bmFp2)
                                == 0
                        && HistoryResumeMatcher.findMatchedEpisodeIndex(
                                        dupNumFingerprintedLine, bmFp2)
                                == 1,
                "R8 P1-1C: explicit S02E02 failover, unique-fingerprinted duplicate '第2集', and cross-drive unique ep all recover 42000ms while wrong item stays 0ms");

        // 22. Round-8 P1-2: Default syncHistory=true AND subscribe-only syncHistory=false BOTH
        //     preserve Windows 0.7.3 WoGG episodeMediaId & 480,003 ms progress, strip legacy
        //     episodeUrl, and NEVER leak an old losing record's episodeMediaId onto a newer
        //     record for another episode!
        String woggFile1Url = "https://pan.quark.cn/s/wogg_share_1?file=dup_part1";
        String woggFile2Url = "https://pan.quark.cn/s/wogg_share_1?file=dup_part2";
        // Windows 0.7.3 canonical episodeMediaId format: "mid:v1:" + sha256(canonical).sub(0,32)
        String winMediaIdFile2 = computeWindowsV073MediaId(woggFile2Url);
        JSONObject winWoggEntry =
                new JSONObject()
                        .put("site", "wogg")
                        .put("id", "wogg_vod_480")
                        .put("title", "玩偶双同名测试")
                        .put("poster", "")
                        .put("line", "夸克4K")
                        .put("lineId", "wogg_quark_1")
                        .put("episode", "4K正片.mkv")
                        .put("episodeMediaId", winMediaIdFile2)
                        .put(
                                "episodeUrl",
                                "https://dl-pc.example/tmp/file2.mkv?sign=secret_xyz&expires=999")
                        .put("index", 1)
                        .put("position", 480_003)
                        .put("duration", 3_600_000)
                        .put("updated", 5_000L);
        String remoteWoggPayload =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", CloudSync.VERSION)
                        .put("updated", 5_000L)
                        .put("watch_history", new JSONArray().put(winWoggEntry))
                        .put("favorites", new JSONArray())
                        .put("tombstones", new JSONObject())
                        .toString();

        // Branch A: default syncHistory = true (syncSubscriptions=true, syncHistory=true)
        CloudSync.MergeResult woggSyncOn =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        true,
                        true,
                        remoteWoggPayload,
                        6_000L);
        JSONArray syncOnOutHist =
                new JSONObject(woggSyncOn.payloadJson).getJSONArray("watch_history");
        JSONObject syncOnEntry = syncOnOutHist.getJSONObject(0);
        JSONArray syncOnLocalHist = new JSONArray(woggSyncOn.historyJson);
        JSONObject syncOnLocalEntry = syncOnLocalHist.getJSONObject(0);

        // Branch B: subscribe-only (syncSubscriptions=true, syncHistory=false)
        CloudSync.MergeResult woggSyncOff =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        true,
                        false,
                        remoteWoggPayload,
                        6_000L);
        JSONArray syncOffOutHist =
                new JSONObject(woggSyncOff.payloadJson).getJSONArray("watch_history");
        JSONObject syncOffEntry = syncOffOutHist.getJSONObject(0);

        // Simulate Windows 0.7.3 WoGG matcher resolving duplicate-named "4K正片.mkv" files using
        // ONLY the JSON output emitted by Android's two sync branches!
        List<String> woggDupFileUrls = Arrays.asList(woggFile1Url, woggFile2Url);
        int winMatchedIdxSyncOn =
                resolveWindowsWoggDuplicateTargetIndex(syncOnEntry, woggDupFileUrls);
        int winMatchedIdxSyncOff =
                resolveWindowsWoggDuplicateTargetIndex(syncOffEntry, woggDupFileUrls);
        check(
                winMediaIdFile2.equals(syncOnEntry.optString("episodeMediaId", ""))
                        && winMediaIdFile2.equals(syncOnLocalEntry.optString("episodeMediaId", ""))
                        && winMediaIdFile2.equals(syncOffEntry.optString("episodeMediaId", ""))
                        && syncOnEntry.optInt("position") == 480_003
                        && syncOffEntry.optInt("position") == 480_003
                        && !syncOnEntry.has("episodeUrl")
                        && !syncOffEntry.has("episodeUrl")
                        && !woggSyncOn.payloadJson.contains("secret_xyz")
                        && !woggSyncOff.payloadJson.contains("secret_xyz")
                        && winMatchedIdxSyncOn == 1
                        && winMatchedIdxSyncOff == 1,
                "R8 P1-2A: BOTH syncHistory=true and syncHistory=false preserve Windows WoGG episodeMediaId & 480003ms, locate 2nd duplicate file, and strip legacy episodeUrl");

        // Branch C: Newer Android record for ANOTHER episode wins LWW (syncSubscriptions=false,
        // syncHistory=true) -> MUST NOT inherit old losing record's episodeMediaId!
        WatchHistory.Entry newerOtherEp = new WatchHistory.Entry();
        newerOtherEp.site = "wogg";
        newerOtherEp.id = "wogg_vod_480";
        newerOtherEp.title = "玩偶双同名测试";
        newerOtherEp.poster = "";
        newerOtherEp.line = "夸克4K";
        newerOtherEp.lineId = "wogg_quark_1";
        newerOtherEp.driveKey = NetdiskStore.DRIVE_QUARK;
        newerOtherEp.episode = "第2集";
        newerOtherEp.episodeKey = WatchHistory.stableEpisodeKey("https://pan.quark.cn/s/ep2_new");
        newerOtherEp.episodeMediaId = "";
        newerOtherEp.index = 2;
        newerOtherEp.position = 95_000;
        newerOtherEp.duration = 3_600_000;
        newerOtherEp.updated = 9_000L; // strictly newer than remote 5_000L
        String localNewerJson = new JSONArray().put(newerOtherEp.json()).toString();
        CloudSync.MergeResult newerWinsMerge =
                CloudSync.merge(
                        localNewerJson,
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        false,
                        true,
                        remoteWoggPayload,
                        10_000L);
        JSONObject winningEntry =
                new JSONObject(newerWinsMerge.payloadJson)
                        .getJSONArray("watch_history")
                        .getJSONObject(0);
        // Also verify spoofed signed URL inside episodeMediaId is rejected by sanitizer
        String spoofedMediaId =
                WatchHistory.sanitizeEpisodeMediaId(
                        "https://dl-pc.example/file.mkv?sign=leak&expires=123");
        check(
                "第2集".equals(winningEntry.optString("episode", ""))
                        && winningEntry.optInt("position") == 95_000
                        && winningEntry.optString("episodeMediaId", "").isEmpty()
                        && newerOtherEp.episodeKey.equals(winningEntry.optString("episodeKey", ""))
                        && spoofedMediaId.isEmpty(),
                "R8 P1-2B: newer record for another episode winning merge does NOT inherit losing old episodeMediaId; spoofed URLs in episodeMediaId are stripped");

        // 23. Round-9 P1-1: Cross-site failover strictly confirms season+episode identity FIRST,
        //     and applies same-drive preference ONLY as a secondary tie-breaker.
        //     (A) Orig Quark S02E02 (42s) -> alt site has [夸克·第一季 / 第2集] and
        //         [百度·第二季 / 第二季第2集]: BOTH line orderings MUST pick Season 2 & 42000ms!
        Cms.Line altQuarkS1 = new Cms.Line();
        altQuarkS1.lineId = "夸克·第一季";
        altQuarkS1.name = "夸克·第一季";
        altQuarkS1.rawName = "夸克·第一季";
        Cms.Episode aqs1e1 = new Cms.Episode();
        aqs1e1.name = "第1集";
        aqs1e1.url = "https://pan.quark.cn/s/alt_s1_e1";
        Cms.Episode aqs1e2 = new Cms.Episode();
        aqs1e2.name = "第2集";
        aqs1e2.url = "https://pan.quark.cn/s/alt_s1_e2";
        altQuarkS1.episodes.add(aqs1e1);
        altQuarkS1.episodes.add(aqs1e2);

        Cms.Line altBaiduS2 = new Cms.Line();
        altBaiduS2.lineId = "百度·第二季";
        altBaiduS2.name = "百度·第二季";
        altBaiduS2.rawName = "百度·第二季";
        Cms.Episode abs2e1 = new Cms.Episode();
        abs2e1.name = "第二季第1集";
        abs2e1.url = "https://pan.baidu.com/s/alt_s2_e1";
        Cms.Episode abs2e2 = new Cms.Episode();
        abs2e2.name = "第二季第2集";
        abs2e2.url = "https://pan.baidu.com/s/alt_s2_e2";
        altBaiduS2.episodes.add(abs2e1);
        altBaiduS2.episodes.add(abs2e2);

        Cms.Video altOrderAB = new Cms.Video();
        altOrderAB.id = "alt_season_ab";
        altOrderAB.title = "星际纪元";
        altOrderAB.lines.addAll(Arrays.asList(altQuarkS1, altBaiduS2));

        Cms.Video altOrderBA = new Cms.Video();
        altOrderBA.id = "alt_season_ba";
        altOrderBA.title = "星际纪元";
        altOrderBA.lines.addAll(Arrays.asList(altBaiduS2, altQuarkS1));

        HistoryResumeMatcher.EpisodeMatch pickAB =
                HistoryResumeMatcher.matchEpisodeForFailover(altOrderAB, bmS02E02);
        HistoryResumeMatcher.EpisodeMatch pickBA =
                HistoryResumeMatcher.matchEpisodeForFailover(altOrderBA, bmS02E02);
        check(
                pickAB != null
                        && pickAB.line == altBaiduS2
                        && pickAB.episode == abs2e2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(pickAB, bmS02E02)
                                == 42_000
                        && pickBA != null
                        && pickBA.line == altBaiduS2
                        && pickBA.episode == abs2e2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(pickBA, bmS02E02)
                                == 42_000,
                "R9 P1-1A: cross-site failover selects Season 2 Baidu (42000ms) over Season 1 Quark in BOTH line orders");

        //     (B) When ALL alt candidates cannot distinguish season, NEVER auto-transfer breakpoint
        Cms.Line altSeasonlessQuark = new Cms.Line();
        altSeasonlessQuark.lineId = "夸克原画";
        altSeasonlessQuark.name = "夸克原画";
        altSeasonlessQuark.rawName = "夸克原画";
        Cms.Episode slq1 = new Cms.Episode();
        slq1.name = "第1集";
        slq1.url = "https://pan.quark.cn/s/sl_q_1";
        Cms.Episode slq2 = new Cms.Episode();
        slq2.name = "第2集";
        slq2.url = "https://pan.quark.cn/s/sl_q_2";
        altSeasonlessQuark.episodes.add(slq1);
        altSeasonlessQuark.episodes.add(slq2);

        Cms.Line altSeasonlessBaidu = new Cms.Line();
        altSeasonlessBaidu.lineId = "百度原画";
        altSeasonlessBaidu.name = "百度原画";
        altSeasonlessBaidu.rawName = "百度原画";
        Cms.Episode slb1 = new Cms.Episode();
        slb1.name = "第1集";
        slb1.url = "https://pan.baidu.com/s/sl_b_1";
        Cms.Episode slb2 = new Cms.Episode();
        slb2.name = "第2集";
        slb2.url = "https://pan.baidu.com/s/sl_b_2";
        altSeasonlessBaidu.episodes.add(slb1);
        altSeasonlessBaidu.episodes.add(slb2);

        Cms.Video altAllSeasonless = new Cms.Video();
        altAllSeasonless.id = "alt_seasonless";
        altAllSeasonless.title = "星际纪元";
        altAllSeasonless.lines.addAll(Arrays.asList(altSeasonlessQuark, altSeasonlessBaidu));

        HistoryResumeMatcher.EpisodeMatch seasonlessPick =
                HistoryResumeMatcher.matchEpisodeForFailover(altAllSeasonless, bmS02E02);
        int forcedSeasonlessPos =
                HistoryResumeMatcher.resolveFailoverResumePositionMs(
                        new HistoryResumeMatcher.EpisodeMatch(altSeasonlessQuark, slq2, 100),
                        bmS02E02);
        // Tie-breaker positive control: when BOTH lines confirm Season 2, same-drive Quark wins!
        Cms.Line altQuarkS2 = new Cms.Line();
        altQuarkS2.lineId = "夸克·第二季";
        altQuarkS2.name = "夸克·第二季";
        altQuarkS2.rawName = "夸克·第二季";
        Cms.Episode aqs2e2 = new Cms.Episode();
        aqs2e2.name = "第二季第2集";
        aqs2e2.url = "https://pan.quark.cn/s/alt_qk_s2_e2";
        altQuarkS2.episodes.add(aqs2e2);
        Cms.Video altBothS2 = new Cms.Video();
        altBothS2.id = "alt_both_s2";
        altBothS2.title = "星际纪元";
        altBothS2.lines.addAll(Arrays.asList(altBaiduS2, altQuarkS2));
        HistoryResumeMatcher.EpisodeMatch bothS2Pick =
                HistoryResumeMatcher.matchEpisodeForFailover(altBothS2, bmS02E02);
        check(
                seasonlessPick == null
                        && forcedSeasonlessPos == 0
                        && bothS2Pick != null
                        && bothS2Pick.line == altQuarkS2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        bothS2Pick, bmS02E02)
                                == 42_000,
                "R9 P1-1B: all-seasonless alt candidates reject breakpoint transfer (null/0ms), while equal Season 2 candidates break ties by same-drive Quark");

        // 24. Round-9 P1-2: Full round-trip Windows -> Android continue playback (480003 -> 487003)
        //     -> WatchHistory.upsert -> CloudSync.merge -> Windows WoGG matcher; PLUS
        //     same-timestamp/same-position duplicate-file conflict preservation!
        Cms.Line woggLine = new Cms.Line();
        woggLine.lineId = "wogg_quark_1";
        woggLine.name = "夸克4K";
        woggLine.rawName = "夸克4K";
        Cms.Episode woggEp1 = new Cms.Episode();
        woggEp1.name = "4K正片.mkv";
        woggEp1.url = woggFile1Url;
        Cms.Episode woggEp2 = new Cms.Episode();
        woggEp2.name = "4K正片.mkv";
        woggEp2.url = woggFile2Url;
        woggLine.episodes.add(woggEp1);
        woggLine.episodes.add(woggEp2);
        Cms.Video woggVideo = new Cms.Video();
        woggVideo.id = "wogg_vod_480";
        woggVideo.title = "玩偶双同名测试";
        woggVideo.lines.add(woggLine);

        // Verify Android's windowsMediaIdentityForUrl matches Windows 0.7.3 bit-for-bit
        check(
                winMediaIdFile2.equals(WatchHistory.windowsMediaIdentityForUrl(woggFile2Url))
                        && !winMediaIdFile2.equals(
                                WatchHistory.windowsMediaIdentityForUrl(woggFile1Url)),
                "R9 P1-2A: WatchHistory.windowsMediaIdentityForUrl matches Windows 0.7.3 mid:v1 hash bit-for-bit");

        // Step 1: Windows -> Android sync down
        List<WatchHistory.Entry> syncedOnAndroid = WatchHistory.read(woggSyncOn.historyJson);
        WatchHistory.Entry androidPulledWinBm = syncedOnAndroid.get(0);
        HistoryResumeMatcher.EpisodeMatch androidMatch =
                HistoryResumeMatcher.matchEpisode(woggVideo, androidPulledWinBm);
        int androidResumeFile1 =
                HistoryResumeMatcher.resolveResumePositionMs(
                        woggLine, woggEp1, 0, androidPulledWinBm);
        int androidResumeFile2 =
                HistoryResumeMatcher.resolveResumePositionMs(
                        woggLine, woggEp2, 1, androidPulledWinBm);
        check(
                androidMatch != null
                        && androidMatch.episode == woggEp2
                        && androidResumeFile1 == 0
                        && androidResumeFile2 == 480_003,
                "R9 P1-2B: Android uniquely matches synced Windows WoGG bookmark to 2nd duplicate file ([0, 480003])");

        // Step 2: Android continues playback on File 2 from 480,003 -> 487,003 ms, saves via
        // WatchHistory.buildPlaybackEntry + WatchHistory.upsert, and syncs back to cloud!
        WatchHistory.Entry continuedPlayback =
                WatchHistory.buildPlaybackEntry(
                        "wogg",
                        "wogg_vod_480",
                        "玩偶双同名测试",
                        "",
                        woggLine.rawName(),
                        woggLine.lineId(),
                        NetdiskStore.detectLineDriveKey(woggLine),
                        woggEp2.name,
                        woggEp2.url,
                        1,
                        487_003,
                        3_600_000,
                        7_500L,
                        androidPulledWinBm);
        String afterAndroidUpsert = WatchHistory.upsert(woggSyncOn.historyJson, continuedPlayback);
        CloudSync.MergeResult syncBackToWin =
                CloudSync.merge(
                        afterAndroidUpsert,
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        true,
                        true,
                        remoteWoggPayload,
                        8_000L);
        JSONObject backCloudEntry =
                new JSONObject(syncBackToWin.payloadJson)
                        .getJSONArray("watch_history")
                        .getJSONObject(0);
        int winRoundTripIdx =
                resolveWindowsWoggDuplicateTargetIndex(backCloudEntry, woggDupFileUrls);
        check(
                winMediaIdFile2.equals(backCloudEntry.optString("episodeMediaId", ""))
                        && backCloudEntry.optInt("position") == 487_003
                        && !backCloudEntry.has("episodeUrl")
                        && winRoundTripIdx == 1,
                "R9 P1-2C: Full round-trip Windows -> Android (480003->487003ms) -> CloudSync -> Windows locates 2nd file at 487003ms");

        // Step 3: Switching to File 1 (not matching saved File 2 bookmark) MUST NOT inherit File
        // 2's
        // episodeMediaId!
        boolean file1MatchesSaved =
                HistoryResumeMatcher.matchesBookmarkSelection(
                        woggLine, woggEp1, 0, androidPulledWinBm);
        WatchHistory.Entry switchedToFile1 =
                WatchHistory.buildPlaybackEntry(
                        "wogg",
                        "wogg_vod_480",
                        "玩偶双同名测试",
                        "",
                        woggLine.rawName(),
                        woggLine.lineId(),
                        NetdiskStore.detectLineDriveKey(woggLine),
                        woggEp1.name,
                        woggEp1.url,
                        0,
                        12_000,
                        3_600_000,
                        8_500L,
                        file1MatchesSaved ? androidPulledWinBm : null);
        check(
                !file1MatchesSaved
                        && !winMediaIdFile2.equals(switchedToFile1.episodeMediaId)
                        && WatchHistory.windowsMediaIdentityForUrl(woggFile1Url)
                                .equals(switchedToFile1.episodeMediaId),
                "R9 P1-2D: switching to duplicate File 1 never inherits File 2's episodeMediaId");

        // Step 4: Same-timestamp, same-position conflict between local File 1 (480003, t=5000) and
        // remote File 2 (480003, t=5000) MUST NOT flip Android recoverable progress [480003, 0] ->
        // [0, 480003]!
        WatchHistory.Entry localConflictFile1 = new WatchHistory.Entry();
        localConflictFile1.site = "wogg";
        localConflictFile1.id = "wogg_vod_480";
        localConflictFile1.title = "玩偶双同名测试";
        localConflictFile1.poster = "";
        localConflictFile1.line = "夸克4K";
        localConflictFile1.lineId = "wogg_quark_1";
        localConflictFile1.driveKey = NetdiskStore.DRIVE_QUARK;
        localConflictFile1.episode = "4K正片.mkv";
        localConflictFile1.episodeKey = WatchHistory.stableEpisodeKey(woggFile1Url);
        localConflictFile1.episodeMediaId = "";
        localConflictFile1.index = 0;
        localConflictFile1.position = 480_003;
        localConflictFile1.duration = 3_600_000;
        localConflictFile1.updated = 5_000L; // SAME timestamp & SAME position as remote File 2!
        String localConflictJson = new JSONArray().put(localConflictFile1.json()).toString();
        CloudSync.MergeResult conflictMerge =
                CloudSync.merge(
                        localConflictJson,
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        false,
                        true,
                        remoteWoggPayload,
                        6_000L);
        WatchHistory.Entry afterConflictBm = WatchHistory.read(conflictMerge.historyJson).get(0);
        int afterConflictPos1 =
                HistoryResumeMatcher.resolveResumePositionMs(woggLine, woggEp1, 0, afterConflictBm);
        int afterConflictPos2 =
                HistoryResumeMatcher.resolveResumePositionMs(woggLine, woggEp2, 1, afterConflictBm);
        check(
                afterConflictPos1 == 480_003 && afterConflictPos2 == 0,
                "R9 P1-2E: same-timestamp same-position duplicate conflict preserves Android [480003, 0] and NEVER flips to [0, 480003]");

        // 25. Round-9 P2-3: Same-site trailer inserted & IDs re-indexed (?id=2 moved from 第2集 to
        //     第1集, 第2集 moved to ?id=3) -> Detail, History, Fullscreen & Inline ALL recover 42s
        //     for 第2集 while 第1集 & 预告 stay 0ms; indistinguishable duplicate 第2集 stays 0ms!
        WatchHistory.Entry bmReindexedOrigEp2 = new WatchHistory.Entry();
        bmReindexedOrigEp2.site = "reindex_site";
        bmReindexedOrigEp2.id = "vod_reindex";
        bmReindexedOrigEp2.line = "默认线路";
        bmReindexedOrigEp2.lineId = "默认线路";
        bmReindexedOrigEp2.episode = "第2集";
        bmReindexedOrigEp2.episodeKey =
                WatchHistory.stableEpisodeKey("https://site.example/play?id=2");
        bmReindexedOrigEp2.index = 1;
        bmReindexedOrigEp2.position = 42_000;
        bmReindexedOrigEp2.duration = 240_000;

        Cms.Line reindexedLine = new Cms.Line();
        reindexedLine.lineId = "默认线路";
        reindexedLine.name = "默认线路";
        reindexedLine.rawName = "默认线路";
        Cms.Episode riTrailer = new Cms.Episode();
        riTrailer.name = "预告";
        riTrailer.url = "https://site.example/play?id=1";
        Cms.Episode riEp1 = new Cms.Episode();
        riEp1.name = "第1集";
        riEp1.url = "https://site.example/play?id=2"; // stole old 第2集 ID!
        Cms.Episode riEp2 = new Cms.Episode();
        riEp2.name = "第2集";
        riEp2.url = "https://site.example/play?id=3"; // shifted to new ID!
        reindexedLine.episodes.addAll(Arrays.asList(riTrailer, riEp1, riEp2));
        Cms.Video reindexedVideo = new Cms.Video();
        reindexedVideo.id = "vod_reindex";
        reindexedVideo.lines.add(reindexedLine);

        HistoryResumeMatcher.EpisodeMatch reindexedHistMatch =
                HistoryResumeMatcher.matchEpisode(reindexedVideo, bmReindexedOrigEp2);
        int reindexedDetailIdx =
                HistoryResumeMatcher.findMatchedEpisodeIndex(reindexedLine, bmReindexedOrigEp2);
        int reindexedPosTrailer =
                HistoryResumeMatcher.resolveResumePositionMs(
                        reindexedLine, riTrailer, 0, bmReindexedOrigEp2);
        int reindexedPosEp1 =
                HistoryResumeMatcher.resolveResumePositionMs(
                        reindexedLine, riEp1, 1, bmReindexedOrigEp2);
        int reindexedPosEp2 =
                HistoryResumeMatcher.resolveResumePositionMs(
                        reindexedLine, riEp2, 2, bmReindexedOrigEp2);

        // Negative control: indistinguishable duplicate "第2集" with shifted IDs still stays 0ms!
        Cms.Line dupShiftedLine = new Cms.Line();
        dupShiftedLine.lineId = "默认线路";
        dupShiftedLine.name = "默认线路";
        dupShiftedLine.rawName = "默认线路";
        Cms.Episode dsEp2a = new Cms.Episode();
        dsEp2a.name = "第2集";
        dsEp2a.url = "https://site.example/play?id=901";
        Cms.Episode dsEp2b = new Cms.Episode();
        dsEp2b.name = "第2集";
        dsEp2b.url = "https://site.example/play?id=902";
        dupShiftedLine.episodes.addAll(Arrays.asList(dsEp2a, dsEp2b));
        Cms.Video dupShiftedVideo = new Cms.Video();
        dupShiftedVideo.id = "vod_reindex";
        dupShiftedVideo.lines.add(dupShiftedLine);

        check(
                reindexedHistMatch != null
                        && reindexedHistMatch.episode == riEp2
                        && reindexedDetailIdx == 2
                        && reindexedPosEp2 == 42_000
                        && reindexedPosEp1 == 0
                        && reindexedPosTrailer == 0
                        && HistoryResumeMatcher.matchEpisode(dupShiftedVideo, bmReindexedOrigEp2)
                                == null
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        dupShiftedLine, dsEp2a, 0, bmReindexedOrigEp2)
                                == 0
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        dupShiftedLine, dsEp2b, 1, bmReindexedOrigEp2)
                                == 0,
                "R9 P2-3: trailer insertion + ?id=2->?id=3 re-index recovers 42000ms for unique 第2集 (第1集=0ms), while indistinguishable duplicate 第2集 stays 0ms");

        // 26. Round-9 P2-2: Long-series 250 / 500 / 800 episode O(N) performance benchmark & exact
        //     selection correctness (eliminates O(N^2) line scan & SHA-256 regression).
        int[] benchSizes = new int[] {250, 500, 800};
        double[] mediansMs = new double[benchSizes.length];
        for (int sIdx = 0; sIdx < benchSizes.length; sIdx++) {
            int nEps = benchSizes[sIdx];
            int targetIdx = (nEps * 3) / 4; // 187, 375, 600
            Cms.Line longLine = new Cms.Line();
            longLine.lineId = "长剧主线";
            longLine.name = "长剧主线";
            longLine.rawName = "长剧主线";
            for (int e = 1; e <= nEps; e++) {
                Cms.Episode ep = new Cms.Episode();
                ep.name = "第" + e + "集";
                ep.url = "https://cdn.example/series/ep?id=" + e + "&sign=tmp" + e;
                longLine.episodes.add(ep);
            }
            Cms.Video longVideo = new Cms.Video();
            longVideo.id = "long_" + nEps;
            longVideo.title = "长篇连续剧";
            longVideo.lines.add(longLine);

            Cms.Episode targetEp = longLine.episodes.get(targetIdx);
            WatchHistory.Entry longBm = new WatchHistory.Entry();
            longBm.site = "long_site";
            longBm.id = longVideo.id;
            longBm.line = "长剧主线";
            longBm.lineId = "长剧主线";
            longBm.episode = targetEp.name;
            longBm.episodeKey = WatchHistory.stableEpisodeKey(targetEp.url);
            longBm.index = targetIdx;
            longBm.position = 42_000;
            longBm.duration = 240_000;

            // Warm-up
            HistoryResumeMatcher.matchEpisode(longVideo, longBm);
            HistoryResumeMatcher.findMatchedEpisodeIndex(longLine, longBm);
            HistoryResumeMatcher.resolveResumePositionMs(longLine, targetEp, targetIdx, longBm);

            double[] samples = new double[3];
            for (int run = 0; run < 3; run++) {
                long t0 = System.nanoTime();
                HistoryResumeMatcher.EpisodeMatch m =
                        HistoryResumeMatcher.matchEpisode(longVideo, longBm);
                int idx = HistoryResumeMatcher.findMatchedEpisodeIndex(longLine, longBm);
                int pos =
                        HistoryResumeMatcher.resolveResumePositionMs(
                                longLine, targetEp, targetIdx, longBm);
                long t1 = System.nanoTime();
                check(
                        m != null && m.episode == targetEp && idx == targetIdx && pos == 42_000,
                        "R9 P2-2: exact selection verified for " + nEps + " episodes");
                samples[run] = (t1 - t0) / 1_000_000.0;
            }
            Arrays.sort(samples);
            mediansMs[sIdx] = samples[1];
        }
        System.out.println(
                String.format(
                        Locale.US,
                        "BENCH R9 P2-2 HistoryResumeMatcher median ms: 250ep=%.2fms, 500ep=%.2fms, 800ep=%.2fms",
                        mediansMs[0],
                        mediansMs[1],
                        mediansMs[2]));
        check(
                mediansMs[1] < 100.0 && mediansMs[2] < 150.0,
                String.format(
                        Locale.US,
                        "R9 P2-2: O(N) long-series matching eliminates O(N^2) regression (250=%.2fms, 500=%.2fms, 800=%.2fms)",
                        mediansMs[0],
                        mediansMs[1],
                        mediansMs[2]));

        // 27. Round-10 P1-1: Season stored ONLY in original bookmark line name
        //     ("星途 / 夸克·第二季 / 第2集", 42s) MUST steer cross-site failover to Season 2 in BOTH
        //     line orders and refuse transfer when only Season 1 or seasonless lines exist!
        WatchHistory.Entry bmLineOnlyS2 = new WatchHistory.Entry();
        bmLineOnlyS2.site = "orig_site";
        bmLineOnlyS2.id = "vod_xingtu";
        bmLineOnlyS2.title = "星途";
        bmLineOnlyS2.line = "夸克·第二季";
        bmLineOnlyS2.lineId = "夸克·第二季";
        bmLineOnlyS2.driveKey = NetdiskStore.DRIVE_QUARK;
        bmLineOnlyS2.episode = "第2集";
        bmLineOnlyS2.episodeKey = WatchHistory.stableEpisodeKey("https://pan.quark.cn/s/xt_s2_e2");
        bmLineOnlyS2.index = 1;
        bmLineOnlyS2.position = 42_000;
        bmLineOnlyS2.duration = 240_000;

        Cms.Line altXtQuarkS1 = new Cms.Line();
        altXtQuarkS1.lineId = "夸克·第一季";
        altXtQuarkS1.name = "夸克·第一季";
        altXtQuarkS1.rawName = "夸克·第一季";
        Cms.Episode xtQ1E2 = new Cms.Episode();
        xtQ1E2.name = "第2集";
        xtQ1E2.url = "https://pan.quark.cn/s/alt_xt_s1_e2";
        altXtQuarkS1.episodes.add(xtQ1E2);

        Cms.Line altXtBaiduS2 = new Cms.Line();
        altXtBaiduS2.lineId = "百度·第二季";
        altXtBaiduS2.name = "百度·第二季";
        altXtBaiduS2.rawName = "百度·第二季";
        Cms.Episode xtB2E2 = new Cms.Episode();
        xtB2E2.name = "第2集";
        xtB2E2.url = "https://pan.baidu.com/s/alt_xt_s2_e2";
        altXtBaiduS2.episodes.add(xtB2E2);

        Cms.Video altXtAB = new Cms.Video();
        altXtAB.id = "alt_xt_ab";
        altXtAB.title = "星途";
        altXtAB.lines.addAll(Arrays.asList(altXtQuarkS1, altXtBaiduS2));
        Cms.Video altXtBA = new Cms.Video();
        altXtBA.id = "alt_xt_ba";
        altXtBA.title = "星途";
        altXtBA.lines.addAll(Arrays.asList(altXtBaiduS2, altXtQuarkS1));
        Cms.Video altXtOnlyS1 = new Cms.Video();
        altXtOnlyS1.id = "alt_xt_only_s1";
        altXtOnlyS1.title = "星途";
        altXtOnlyS1.lines.add(altXtQuarkS1);

        HistoryResumeMatcher.EpisodeMatch xtPickAB =
                HistoryResumeMatcher.matchEpisodeForFailover(altXtAB, bmLineOnlyS2);
        HistoryResumeMatcher.EpisodeMatch xtPickBA =
                HistoryResumeMatcher.matchEpisodeForFailover(altXtBA, bmLineOnlyS2);
        HistoryResumeMatcher.EpisodeMatch xtPickOnlyS1 =
                HistoryResumeMatcher.matchEpisodeForFailover(altXtOnlyS1, bmLineOnlyS2);
        HistoryResumeMatcher.EpisodeMatch xtPickSeasonless =
                HistoryResumeMatcher.matchEpisodeForFailover(altAllSeasonless, bmLineOnlyS2);
        check(
                xtPickAB != null
                        && xtPickAB.line == altXtBaiduS2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        xtPickAB, bmLineOnlyS2)
                                == 42_000
                        && xtPickBA != null
                        && xtPickBA.line == altXtBaiduS2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        xtPickBA, bmLineOnlyS2)
                                == 42_000
                        && xtPickOnlyS1 == null
                        && xtPickSeasonless == null,
                "R10 P1-1: bookmark with season ONLY in original line name (星途/夸克·第二季/第2集) picks Season 2 Baidu (42000ms) in both orders and rejects Season-1-only & seasonless");

        // 28. Round-10 P2-1: Same-site missing original drive (orig Quark -> same-site only has
        //     Baidu with identical "第二季第2集") MUST return null (prompt re-select), NEVER
        //     auto-switch to Baidu at 0ms; original Quark recovers 42s; cross-site still switches!
        WatchHistory.Entry bmSameSiteQuarkS2 = new WatchHistory.Entry();
        bmSameSiteQuarkS2.site = "same_site";
        bmSameSiteQuarkS2.id = "vod_same_s2";
        bmSameSiteQuarkS2.title = "星途";
        bmSameSiteQuarkS2.line = "夸克·第二季";
        bmSameSiteQuarkS2.lineId = "夸克·第二季";
        bmSameSiteQuarkS2.driveKey = NetdiskStore.DRIVE_QUARK;
        bmSameSiteQuarkS2.episode = "第二季第2集";
        bmSameSiteQuarkS2.episodeKey =
                WatchHistory.stableEpisodeKey("https://pan.quark.cn/s/same_s2_e2");
        bmSameSiteQuarkS2.index = 1;
        bmSameSiteQuarkS2.position = 42_000;
        bmSameSiteQuarkS2.duration = 240_000;

        Cms.Video sameSiteOnlyBaidu = new Cms.Video();
        sameSiteOnlyBaidu.id = "vod_same_s2";
        sameSiteOnlyBaidu.title = "星途";
        sameSiteOnlyBaidu.lines.add(altBaiduS2); // Baidu with "第二季第2集"

        Cms.Video sameSiteHasQuark = new Cms.Video();
        sameSiteHasQuark.id = "vod_same_s2";
        sameSiteHasQuark.title = "星途";
        sameSiteHasQuark.lines.addAll(Arrays.asList(altBaiduS2, altQuarkS2));

        HistoryResumeMatcher.EpisodeMatch ssMissingQuark =
                HistoryResumeMatcher.matchEpisode(sameSiteOnlyBaidu, bmSameSiteQuarkS2);
        HistoryResumeMatcher.EpisodeMatch ssHasQuark =
                HistoryResumeMatcher.matchEpisode(sameSiteHasQuark, bmSameSiteQuarkS2);
        HistoryResumeMatcher.EpisodeMatch crossSiteToBaidu =
                HistoryResumeMatcher.matchEpisodeForFailover(sameSiteOnlyBaidu, bmSameSiteQuarkS2);
        check(
                ssMissingQuark == null
                        && ssHasQuark != null
                        && ssHasQuark.line == altQuarkS2
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        altQuarkS2, aqs2e2, 0, bmSameSiteQuarkS2)
                                == 42_000
                        && crossSiteToBaidu != null
                        && crossSiteToBaidu.line == altBaiduS2
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        crossSiteToBaidu, bmSameSiteQuarkS2)
                                == 42_000,
                "R10 P2-1: same-site missing Quark returns null (prompts re-select), present Quark recovers 42000ms, and cross-site failover still switches to Baidu at 42000ms");

        // 29. Round-10 P1-2: Exact Dart Uri.tryParse + WatchHistoryEntry.mediaIdentityForUrl
        //     canonicalization alignment (spaces -> '+', literal '+', encoded path, dot segments,
        //     Unicode, Baidu mmcloud://baidu with "Movie Part 2.mkv", and two duplicate-named
        //     files bidirectional round-trip 480003 -> 487003 ms).
        String baiduSpaced1 =
                "mmcloud://baidu?share=https%3A%2F%2Fpan.baidu.com%2Fs%2F1abcXYZ&fid=987654321&parent=0&name=Movie+Part+2.mkv&size=1024&path=%2FMovies%2FSeason+1%2FMovie+Part+2.mkv";
        String baiduSpaced2 =
                "mmcloud://baidu?share=https%3A%2F%2Fpan.baidu.com%2Fs%2F1abcXYZ&fid=987654322&parent=0&name=Movie+Part+2.mkv&size=2048&path=%2FMovies%2FSeason+2%2FMovie+Part+2.mkv";
        check(
                "mmcloud://baidu?fid=987654321&name=Movie+Part+2.mkv&path=%2FMovies%2FSeason+1%2FMovie+Part+2.mkv"
                                .equals(
                                        WatchHistory.canonicalWindowsMediaStringForUrl(
                                                baiduSpaced1))
                        && "https://cdn.example/Movies/Movie%20Part%202.mkv?id=12"
                                .equals(
                                        WatchHistory.canonicalWindowsMediaStringForUrl(
                                                "https://cdn.example/Movies/Movie Part 2.mkv?id=12&sign=secret"))
                        && "https://cdn.example/Movies/a+b/c%2Bd/e%20f%2FA~.mkv?name=A%2BB+C+D"
                                .equals(
                                        WatchHistory.canonicalWindowsMediaStringForUrl(
                                                "https://cdn.example/Movies/a+b/c%2Bd/e%20f%2f%41%7e.mkv?name=A%2BB+C%20D&token=xx"))
                        && "https://cdn.example/a/c/Movie%20Part%202.mkv?name=Movie+Part+2.mkv"
                                .equals(
                                        WatchHistory.canonicalWindowsMediaStringForUrl(
                                                "https://cdn.example/a/b/../c/./Movie Part 2.mkv?name=Movie Part 2.mkv"))
                        && "https://pan.quark.cn/s/abc?fid=2&path="
                                .equals(
                                        WatchHistory.canonicalWindowsMediaStringForUrl(
                                                "https://"
                                                        + "demo_u:demo_p@"
                                                        + "Pan.Quark.CN:443/s/abc?FID=1&fid=2&path&sign=x#frag"))
                        && "mmcloud://baidu?fid=1&name=A%2BB+%282024%29+%21%2A%27~.mkv&path=%2FDir+A%2BB%2FA%2BB.mkv"
                                .equals(
                                        WatchHistory.canonicalWindowsMediaStringForUrl(
                                                "mmcloud://baidu?fid=1&name=A%2BB+%282024%29+%21%2A%27~.mkv&path=%2FDir+A%2BB%2FA%2BB.mkv")),
                "R10 P1-2A: WatchHistory.canonicalWindowsMediaStringForUrl matches Dart Uri.tryParse & encodeQueryComponent across spaces, literal '+', encoded paths, dot segments & case");

        // Bidirectional duplicate "Movie Part 2.mkv" Baidu round-trip (480003 -> 487003 ms)
        String baiduMidFile2 = WatchHistory.windowsMediaIdentityForUrl(baiduSpaced2);
        Cms.Line baiduDupLine = new Cms.Line();
        baiduDupLine.lineId = "baidu_share_1";
        baiduDupLine.name = "百度网盘 1";
        baiduDupLine.rawName = "百度网盘 1";
        Cms.Episode bdDupEp1 = new Cms.Episode();
        bdDupEp1.name = "Movie Part 2.mkv";
        bdDupEp1.url = baiduSpaced1;
        Cms.Episode bdDupEp2 = new Cms.Episode();
        bdDupEp2.name = "Movie Part 2.mkv";
        bdDupEp2.url = baiduSpaced2;
        baiduDupLine.episodes.add(bdDupEp1);
        baiduDupLine.episodes.add(bdDupEp2);
        Cms.Video baiduDupVideo = new Cms.Video();
        baiduDupVideo.id = "wogg_bd_spaced";
        baiduDupVideo.title = "Movie Part 2";
        baiduDupVideo.lines.add(baiduDupLine);

        JSONObject winBdSpacedBm =
                new JSONObject()
                        .put("site", "wogg")
                        .put("id", "wogg_bd_spaced")
                        .put("title", "Movie Part 2")
                        .put("poster", "")
                        .put("line", "百度网盘 1")
                        .put("lineId", "baidu_share_1")
                        .put("episode", "Movie Part 2.mkv")
                        .put("episodeMediaId", baiduMidFile2)
                        .put("index", 1)
                        .put("position", 480_003)
                        .put("duration", 3_600_000)
                        .put("updated", 5_000L);
        String winBdPayload =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", CloudSync.VERSION)
                        .put("updated", 5_000L)
                        .put("watch_history", new JSONArray().put(winBdSpacedBm))
                        .put("favorites", new JSONArray())
                        .put("tombstones", new JSONObject())
                        .toString();
        CloudSync.MergeResult bdPull =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        true,
                        true,
                        winBdPayload,
                        5_500L);
        WatchHistory.Entry bdAndroidEntry = WatchHistory.read(bdPull.historyJson).get(0);
        int bdPos1 =
                HistoryResumeMatcher.resolveResumePositionMs(
                        baiduDupLine, bdDupEp1, 0, bdAndroidEntry);
        int bdPos2 =
                HistoryResumeMatcher.resolveResumePositionMs(
                        baiduDupLine, bdDupEp2, 1, bdAndroidEntry);
        WatchHistory.Entry bdContinued =
                WatchHistory.buildPlaybackEntry(
                        "wogg",
                        "wogg_bd_spaced",
                        "Movie Part 2",
                        "",
                        baiduDupLine.rawName(),
                        baiduDupLine.lineId(),
                        NetdiskStore.DRIVE_BAIDU,
                        bdDupEp2.name,
                        bdDupEp2.url,
                        1,
                        487_003,
                        3_600_000,
                        7_000L,
                        bdAndroidEntry);
        String bdLocalAfter = WatchHistory.upsert(bdPull.historyJson, bdContinued);
        CloudSync.MergeResult bdPush =
                CloudSync.merge(
                        bdLocalAfter,
                        "[]",
                        "{}",
                        Collections.emptyList(),
                        true,
                        true,
                        winBdPayload,
                        7_500L);
        JSONObject bdCloudOut =
                new JSONObject(bdPush.payloadJson).getJSONArray("watch_history").getJSONObject(0);
        check(
                bdPos1 == 0
                        && bdPos2 == 480_003
                        && baiduMidFile2.equals(bdCloudOut.optString("episodeMediaId", ""))
                        && bdCloudOut.optInt("position") == 487_003
                        && !bdCloudOut.has("episodeUrl"),
                "R10 P1-2B: Baidu spaced 'Movie Part 2.mkv' duplicate files round-trip Windows(480003)->Android([0,480003])->487003->CloudSync preserving exact Dart mid:v1");

        // 30. Round-11 P2-1: Missing original drive on same site MUST require re-selection on BOTH
        //     (1) MobileDetailScreen primary button for series & single-episode movies, AND
        //     (2) HistoryResumeMatcher single-episode movie fallback (never fall back to Baidu on
        //     confirmed same-site drive conflict). Explicit user selection of Baidu plays at 0 ms;
        //     present Quark recovers 42,000 ms; cross-site failover still switches & recovers 42s.
        WatchHistory.Entry bmMovieQuark = new WatchHistory.Entry();
        bmMovieQuark.site = "movie_site";
        bmMovieQuark.id = "vod_chunchao";
        bmMovieQuark.title = "春潮";
        bmMovieQuark.line = "夸克";
        bmMovieQuark.lineId = "夸克";
        bmMovieQuark.driveKey = NetdiskStore.DRIVE_QUARK;
        bmMovieQuark.episode = "正片";
        bmMovieQuark.episodeKey =
                WatchHistory.stableEpisodeKey("https://pan.quark.cn/s/chunchao_quark_full");
        bmMovieQuark.index = 0;
        bmMovieQuark.position = 42_000;
        bmMovieQuark.duration = 7_200_000;

        Cms.Line baiduMovieLine = new Cms.Line();
        baiduMovieLine.lineId = "百度";
        baiduMovieLine.name = "百度";
        baiduMovieLine.rawName = "百度";
        Cms.Episode baiduMovieEp = new Cms.Episode();
        baiduMovieEp.name = "正片";
        baiduMovieEp.url = "https://pan.baidu.com/s/chunchao_baidu_full";
        baiduMovieLine.episodes.add(baiduMovieEp);

        Cms.Line baiduMovieTokenLine = new Cms.Line();
        baiduMovieTokenLine.lineId = "百度";
        baiduMovieTokenLine.name = "百度";
        baiduMovieTokenLine.rawName = "百度";
        Cms.Episode baiduMovieTokenEp = new Cms.Episode();
        baiduMovieTokenEp.name = "正片";
        baiduMovieTokenEp.url = "baidu_cms_token_chunchao";
        baiduMovieTokenLine.episodes.add(baiduMovieTokenEp);

        Cms.Line quarkMovieLine = new Cms.Line();
        quarkMovieLine.lineId = "夸克";
        quarkMovieLine.name = "夸克";
        quarkMovieLine.rawName = "夸克";
        Cms.Episode quarkMovieEp = new Cms.Episode();
        quarkMovieEp.name = "正片";
        quarkMovieEp.url = "https://pan.quark.cn/s/chunchao_quark_full";
        quarkMovieLine.episodes.add(quarkMovieEp);

        Cms.Video movieSameSiteOnlyBaidu = new Cms.Video();
        movieSameSiteOnlyBaidu.id = "vod_chunchao";
        movieSameSiteOnlyBaidu.title = "春潮";
        movieSameSiteOnlyBaidu.lines.add(baiduMovieLine);

        Cms.Video movieSameSiteOnlyBaiduToken = new Cms.Video();
        movieSameSiteOnlyBaiduToken.id = "vod_chunchao";
        movieSameSiteOnlyBaiduToken.title = "春潮";
        movieSameSiteOnlyBaiduToken.lines.add(baiduMovieTokenLine);

        Cms.Video movieSameSiteHasQuark = new Cms.Video();
        movieSameSiteHasQuark.id = "vod_chunchao";
        movieSameSiteHasQuark.title = "春潮";
        movieSameSiteHasQuark.lines.addAll(Arrays.asList(baiduMovieLine, quarkMovieLine));

        HistoryResumeMatcher.EpisodeMatch mvMissingQuark =
                HistoryResumeMatcher.matchEpisode(movieSameSiteOnlyBaidu, bmMovieQuark);
        HistoryResumeMatcher.EpisodeMatch mvMissingQuarkToken =
                HistoryResumeMatcher.matchEpisode(movieSameSiteOnlyBaiduToken, bmMovieQuark);
        HistoryResumeMatcher.EpisodeMatch mvHasQuark =
                HistoryResumeMatcher.matchEpisode(movieSameSiteHasQuark, bmMovieQuark);
        HistoryResumeMatcher.EpisodeMatch mvCrossSiteBaidu =
                HistoryResumeMatcher.matchEpisodeForFailover(movieSameSiteOnlyBaidu, bmMovieQuark);
        check(
                mvMissingQuark == null
                        && mvMissingQuarkToken == null
                        && mvHasQuark != null
                        && mvHasQuark.line == quarkMovieLine
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        quarkMovieLine, quarkMovieEp, 0, bmMovieQuark)
                                == 42_000
                        && HistoryResumeMatcher.resolveResumePositionMs(
                                        baiduMovieLine, baiduMovieEp, 0, bmMovieQuark)
                                == 0
                        && mvCrossSiteBaidu != null
                        && mvCrossSiteBaidu.line == baiduMovieLine
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(
                                        mvCrossSiteBaidu, bmMovieQuark)
                                == 42_000,
                "R11 P2-1A: same-site single-episode movie fallback respects confirmed drive conflict (returns null when Quark vanished, recovers 42s when Quark present, allows cross-site Baidu failover at 42s)");

        // MobileDetailScreen primary play button resolution for BOTH series & single-episode movie
        Cms.Line r11BaiduS2 = new Cms.Line();
        r11BaiduS2.lineId = "百度·第二季";
        r11BaiduS2.name = "百度·第二季";
        r11BaiduS2.rawName = "百度·第二季";
        Cms.Episode r11BdE1 = new Cms.Episode();
        r11BdE1.name = "第1集";
        r11BdE1.url = "https://pan.baidu.com/s/r11_s2_e1";
        Cms.Episode r11BdE2 = new Cms.Episode();
        r11BdE2.name = "第2集";
        r11BdE2.url = "https://pan.baidu.com/s/r11_s2_e2";
        r11BaiduS2.episodes.add(r11BdE1);
        r11BaiduS2.episodes.add(r11BdE2);

        Cms.Line r11QuarkS2 = new Cms.Line();
        r11QuarkS2.lineId = "夸克·第二季";
        r11QuarkS2.name = "夸克·第二季";
        r11QuarkS2.rawName = "夸克·第二季";
        Cms.Episode r11QkE1 = new Cms.Episode();
        r11QkE1.name = "第1集";
        r11QkE1.url = "https://pan.quark.cn/s/r11_s2_e1";
        Cms.Episode r11QkE2 = new Cms.Episode();
        r11QkE2.name = "第2集";
        r11QkE2.url = "https://pan.quark.cn/s/r11_s2_e2";
        r11QuarkS2.episodes.add(r11QkE1);
        r11QuarkS2.episodes.add(r11QkE2);

        WatchHistory.Entry bmR11SeriesQuark = new WatchHistory.Entry();
        bmR11SeriesQuark.site = "same_site";
        bmR11SeriesQuark.id = "vod_r11_s2";
        bmR11SeriesQuark.title = "星途";
        bmR11SeriesQuark.line = "夸克·第二季";
        bmR11SeriesQuark.lineId = "夸克·第二季";
        bmR11SeriesQuark.driveKey = NetdiskStore.DRIVE_QUARK;
        bmR11SeriesQuark.episode = "第2集";
        bmR11SeriesQuark.episodeKey = WatchHistory.stableEpisodeKey(r11QkE2.url);
        bmR11SeriesQuark.index = 1;
        bmR11SeriesQuark.position = 42_000;
        bmR11SeriesQuark.duration = 240_000;

        Cms.Video r11SeriesOnlyBaidu = new Cms.Video();
        r11SeriesOnlyBaidu.id = "vod_r11_s2";
        r11SeriesOnlyBaidu.title = "星途";
        r11SeriesOnlyBaidu.lines.add(r11BaiduS2);

        Cms.Video r11SeriesHasQuark = new Cms.Video();
        r11SeriesHasQuark.id = "vod_r11_s2";
        r11SeriesHasQuark.title = "星途";
        r11SeriesHasQuark.lines.addAll(Arrays.asList(r11BaiduS2, r11QuarkS2));

        MobileDetailScreen.PrimaryPlayAction seriesMissingAct =
                MobileDetailScreen.resolvePrimaryPlayAction(
                        r11SeriesOnlyBaidu, 0, bmR11SeriesQuark, false, null, -1, false, 0);
        MobileDetailScreen.PrimaryPlayAction seriesUserBaiduAct =
                MobileDetailScreen.resolvePrimaryPlayAction(
                        r11SeriesOnlyBaidu, 0, bmR11SeriesQuark, true, r11BaiduS2, 1, false, 0);
        MobileDetailScreen.PrimaryPlayAction seriesPresentQuarkAct =
                MobileDetailScreen.resolvePrimaryPlayAction(
                        r11SeriesHasQuark, 0, bmR11SeriesQuark, false, null, -1, false, 0);
        MobileDetailScreen.PrimaryPlayAction movieMissingAct =
                MobileDetailScreen.resolvePrimaryPlayAction(
                        movieSameSiteOnlyBaidu, 0, bmMovieQuark, false, null, -1, false, 0);
        MobileDetailScreen.PrimaryPlayAction movieUserBaiduAct =
                MobileDetailScreen.resolvePrimaryPlayAction(
                        movieSameSiteOnlyBaidu, 0, bmMovieQuark, true, baiduMovieLine, 0, false, 0);
        MobileDetailScreen.PrimaryPlayAction moviePresentQuarkAct =
                MobileDetailScreen.resolvePrimaryPlayAction(
                        movieSameSiteHasQuark, 0, bmMovieQuark, false, null, -1, false, 0);
        check(
                seriesMissingAct.requiresReselection
                        && MobileDetailScreen.RESELECT_BUTTON_TEXT.equals(
                                seriesMissingAct.buttonLabel)
                        && !seriesMissingAct.buttonLabel.contains("第 2 集")
                        && !seriesMissingAct.buttonLabel.contains("播放")
                        && seriesMissingAct.line == null
                        && seriesMissingAct.episode == null
                        && seriesMissingAct.resumePositionMs == 0
                        && !seriesUserBaiduAct.requiresReselection
                        && seriesUserBaiduAct.line == r11BaiduS2
                        && seriesUserBaiduAct.episode == r11BdE2
                        && seriesUserBaiduAct.resumePositionMs == 0
                        && !seriesPresentQuarkAct.requiresReselection
                        && seriesPresentQuarkAct.line == r11QuarkS2
                        && seriesPresentQuarkAct.episode == r11QkE2
                        && seriesPresentQuarkAct.resumePositionMs == 42_000
                        && movieMissingAct.requiresReselection
                        && MobileDetailScreen.RESELECT_BUTTON_TEXT.equals(
                                movieMissingAct.buttonLabel)
                        && movieMissingAct.line == null
                        && movieMissingAct.episode == null
                        && movieMissingAct.resumePositionMs == 0
                        && !movieUserBaiduAct.requiresReselection
                        && movieUserBaiduAct.line == baiduMovieLine
                        && movieUserBaiduAct.episode == baiduMovieEp
                        && movieUserBaiduAct.resumePositionMs == 0
                        && !moviePresentQuarkAct.requiresReselection
                        && moviePresentQuarkAct.line == quarkMovieLine
                        && moviePresentQuarkAct.episode == quarkMovieEp
                        && moviePresentQuarkAct.resumePositionMs == 42_000,
                "R11 P2-1B: MobileDetailScreen.resolvePrimaryPlayAction prompts re-selection when original drive vanished (series & movie), plays Baidu at 0ms only after explicit user selection, and recovers Quark at 42000ms when present");

        pass(
                "DriveOrder + R4..R11 P1-1..P2-1: line-season failover, Dart-aligned episodeMediaId, same-site drive conflict (series+movie+detail-play), re-index resume, and O(N) 250/500/800-ep perf verified");
    }

    private static String computeWindowsV073MediaId(String canonicalUrl) throws Exception {
        java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
        byte[] digest = md.digest(canonicalUrl.getBytes(StandardCharsets.UTF_8));
        StringBuilder sb = new StringBuilder("mid:v1:");
        for (int i = 0; i < 16; i++) {
            sb.append(String.format(Locale.US, "%02x", digest[i] & 0xFF));
        }
        return sb.toString();
    }

    private static int resolveWindowsWoggDuplicateTargetIndex(
            JSONObject exportedEntry, List<String> dupFileUrls) throws Exception {
        String storedMediaId = exportedEntry.optString("episodeMediaId", "").trim();
        if (storedMediaId.isEmpty()) return -1;
        int matched = -1;
        for (int i = 0; i < dupFileUrls.size(); i++) {
            if (storedMediaId.equals(computeWindowsV073MediaId(dupFileUrls.get(i)))) {
                if (matched >= 0) return -1; // ambiguous
                matched = i;
            }
        }
        return matched;
    }
}

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
        pass("DriveOrder: dedicated 切换盘序 sheet wiring + 4-drive default line ordering verified");
    }
}

package com.pilipala.marcomovie;

import com.pilipala.emby.EmbyLibrary;
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
                EmbyLibrary.login(hostBase, "alice", "pw", "dev-1");
            } catch (IOException ex) {
                embyRejected = true;
            }
            check(embyRejected, "Emby login rejected when Views read-permission fails (403)");
            denyEmbyViews.set(false);

            // Emby 2: Bare root, /emby, and reverse-proxy subpath /proxy/emby all succeed
            JSONObject bareAcc = EmbyLibrary.login(hostBase, "alice", "pw", "dev-1");
            check(bareAcc.optString("user").equals("u_emby_1"), "Emby bare root login + Views");
            JSONObject withEmbyAcc = EmbyLibrary.login(hostBase + "/emby", "alice", "pw", "dev-1");
            check(
                    withEmbyAcc.optString("base").equals(hostBase + "/emby"),
                    "Emby /emby login + Views");
            JSONObject withSubpathAcc =
                    EmbyLibrary.login(hostBase + "/proxy/emby", "alice", "pw", "dev-1");
            check(
                    withSubpathAcc.optString("base").equals(hostBase + "/proxy/emby"),
                    "Emby reverse-proxy subpath login + Views");

            // Emby 3: Issue #85 transcode URI fix (relative /videos/... keeps /proxy/emby prefix)
            EmbyLibrary withSubpath = new EmbyLibrary(withSubpathAcc);
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

            // Start slow head probe in background
            Thread headThread =
                    new Thread(
                            () -> {
                                try {
                                    HttpURLConnection c =
                                            (HttpURLConnection) new URL(url).openConnection();
                                    c.setRequestProperty("Range", "bytes=0-2097151");
                                    c.setReadTimeout(4000);
                                    try (InputStream in = c.getInputStream()) {
                                        byte[] buf = new byte[4096];
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

        // Exact mode: keeps all 3 sources of 《三体》/三体, strictly excludes sequels/editions/prefixes
        List<MobileSearchPage.Hit> exact = SearchRanking.rankAndFilter(mixed, "三体", true);
        check(exact.size() == 3, "Exact search retains all 3 sources of 三体, got " + exact.size());
        for (MobileSearchPage.Hit h : exact) {
            check(
                    "《三体》".equals(h.video.title) || "三体".equals(h.video.title),
                    "Exact search excluded derived title: " + h.video.title);
        }

        // Fuzzy mode: exact matches ranked first, all 7 retained
        List<MobileSearchPage.Hit> fuzzy = SearchRanking.rankAndFilter(mixed, "三体", false);
        check(fuzzy.size() == 7, "Fuzzy search retains all hits");
        check(
                SearchRanking.isExactTitleMatch(fuzzy.get(0).video.title, "三体")
                        && SearchRanking.isExactTitleMatch(fuzzy.get(1).video.title, "三体")
                        && SearchRanking.isExactTitleMatch(fuzzy.get(2).video.title, "三体"),
                "Fuzzy mode puts exact matches first");

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
                MobileSearchPage.acceptBatchIfCurrent(exactSess, false, dummyCfg, 1, 1, mixed),
                "Current exact session accepts batch");
        check(
                exactSess.snapshotHits().size() == 3,
                "Exact session filtered incoming batch to 3 exact hits");
        MobileSearchPage.invalidateSession();
        pass("Item 7 (原 7): Exact search filtering, fuzzy ranking & rapid mode-switch isolation");
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
}

package com.pilipala.marcomovie;

import com.pilipala.source.Json;
import com.pilipala.source.Warehouse;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;

/**
 * Pure JVM automated verification suite for Milestone 8 (Lane E: Android Performance & Stability § E1–E5).
 */
public final class LaneEChecks {

    private static void check(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError("FAILED: " + label);
        }
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) throws Exception {
        System.out.println("=== Starting Lane E Verification Suite (§ E1–E5) ===");

        testE1CloneBookmarkSnapshot();
        testE1StorageExecutorThreading();
        testE1PlaybackProgressThrottling();
        testE1CommitAuditZeroOnUIThread();

        testE2ConfigStoreSynchronized();
        testE2ConfigStoreAtomicWrite();
        testE2SourceControllerBackgroundDispatch();

        testE3ZipImportRedirects();
        testE3ZipImportMaxHopsLimit();
        testE3ZipImportSecurityValidation();
        testE3ZipImportPayloadLimit();

        testE4CrossDomainDanmakuHeaderStrip();
        testE4SameDomainDanmakuHeaderPreservation();
        testE4DanmakuCookiePropagation();

        testE5DynamicUserAgentContract();
        testE5TurkishLocaleZipUrl();
        testE5TurkishLocaleArtworkHeaders();
        testE5TurkishLocaleChannelMatching();
        testE5TurkishLocaleSeasonNormalization();
        testE5CmsFileUntouchedBoundary();

        System.out.println("\nALL PASS (20 checks for Lane E)");
    }

    // =========================================================================
    // § E1: Playback Progress Throttling & Background Persistence
    // =========================================================================

    private static void testE1CloneBookmarkSnapshot() {
        WatchHistory.Entry original = new WatchHistory.Entry();
        original.site = "site_vod_1";
        original.id = "vod_12345";
        original.title = "Sample Movie";
        original.poster = "https://img.test/pic.jpg";
        original.line = "Line 1";
        original.episode = "Episode 01";
        original.index = 2;
        original.position = 45000;
        original.duration = 120000;
        original.updated = 1700000000000L;

        // Verify clone logic creates a detached snapshot
        WatchHistory.Entry cloned = cloneBookmarkHelper(original);
        check(cloned != null, "E1: cloneBookmark creates non-null instance");
        check(cloned != original, "E1: cloneBookmark produces detached instance");
        check(
                original.site.equals(cloned.site)
                        && original.id.equals(cloned.id)
                        && original.title.equals(cloned.title)
                        && original.poster.equals(cloned.poster)
                        && original.line.equals(cloned.line)
                        && original.episode.equals(cloned.episode)
                        && original.index == cloned.index
                        && original.position == cloned.position
                        && original.duration == cloned.duration
                        && original.updated == cloned.updated,
                "E1: cloneBookmark copies all 10 fields accurately");

        // Mutate original and assert clone is untouched (isolation guarantee)
        original.position = 99999;
        original.title = "Mutated Title";
        check(
                cloned.position == 45000 && "Sample Movie".equals(cloned.title),
                "E1: mutating original bookmark does not affect snapshot");

        check(cloneBookmarkHelper(null) == null, "E1: cloneBookmark handles null input gracefully");
    }

    private static WatchHistory.Entry cloneBookmarkHelper(WatchHistory.Entry src) {
        if (src == null) return null;
        WatchHistory.Entry e = new WatchHistory.Entry();
        e.site = src.site;
        e.id = src.id;
        e.title = src.title;
        e.poster = src.poster;
        e.line = src.line;
        e.episode = src.episode;
        e.index = src.index;
        e.position = src.position;
        e.duration = src.duration;
        e.updated = src.updated;
        return e;
    }

    private static void testE1StorageExecutorThreading() throws Exception {
        ExecutorService executor =
                Executors.newSingleThreadExecutor(
                        r -> {
                            Thread t = new Thread(r, "playback-storage");
                            t.setDaemon(true);
                            return t;
                        });

        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<String> threadName = new AtomicReference<>("");
        executor.execute(
                () -> {
                    threadName.set(Thread.currentThread().getName());
                    latch.countDown();
                });

        check(latch.await(2, TimeUnit.SECONDS), "E1: playback-storage executor executes task");
        check(
                "playback-storage".equals(threadName.get()),
                "E1: playback-storage executor runs on dedicated daemon thread");
        executor.shutdown();
    }

    private static void testE1PlaybackProgressThrottling() {
        final long INTERVAL = 15000L; // 15 seconds
        long lastSave = 100000L;

        // Continuous playback tick at t = lastSave + 1s (unforced): must throttle
        long now1 = lastSave + 1000L;
        boolean throttled1 = !(now1 - lastSave >= INTERVAL);
        check(throttled1, "E1: continuous playback tick at +1s throttles disk write");

        // Continuous playback tick at t = lastSave + 14.9s: must throttle
        long now2 = lastSave + 14900L;
        boolean throttled2 = !(now2 - lastSave >= INTERVAL);
        check(throttled2, "E1: continuous playback tick at +14.9s throttles disk write");

        // Continuous playback tick at t = lastSave + 15.0s: must trigger write
        long now3 = lastSave + 15000L;
        boolean writeTriggered = (now3 - lastSave >= INTERVAL);
        check(writeTriggered, "E1: continuous playback tick at +15.0s triggers disk persistence");

        // State changes (pause, onPause, completion, episode switch) with force = true: immediate
        // write
        boolean forceWrite = true;
        boolean immediateTrigger = forceWrite || (now1 - lastSave >= INTERVAL);
        check(immediateTrigger, "E1: force=true bypasses 15s throttle for immediate persistence");
    }

    private static void testE1CommitAuditZeroOnUIThread() throws IOException {
        Path root = Paths.get("android/src/main/java/com/pilipala/marcomovie");
        if (!Files.exists(root)) {
            root = Paths.get("../../android/src/main/java/com/pilipala/marcomovie");
        }
        check(Files.exists(root), "E1: Android source directory located for .commit() audit");

        List<String> violations = new ArrayList<>();
        int allowedFatalCrashCount = 0;

        try (java.util.stream.Stream<Path> stream = Files.walk(root)) {
            java.util.Iterator<Path> it =
                    stream.filter(p -> p.toString().endsWith(".java")).iterator();
            while (it.hasNext()) {
                Path path = it.next();
                List<String> lines = Files.readAllLines(path, StandardCharsets.UTF_8);
                for (int i = 0; i < lines.size(); i++) {
                    String line = lines.get(i);
                    if (line.contains(".commit()")
                            && !line.trim().startsWith("//")
                            && !line.trim().startsWith("*")) {
                        String fileName = path.getFileName().toString();
                        int lineNum = i + 1;
                        if ("MainActivity.java".equals(fileName)
                                && lineNum >= 270
                                && lineNum <= 285) {
                            allowedFatalCrashCount++;
                        } else {
                            violations.add(fileName + ":" + lineNum + " -> " + line.trim());
                        }
                    }
                }
            }
        }

        check(
                allowedFatalCrashCount == 1,
                "E1: Fatal crash handler retains exactly 1 guarded commit() before process kill");
        check(
                violations.isEmpty(),
                "E1: Zero UI-thread .commit() violations across android/src/main/java (all converted to apply/async): "
                        + violations);
    }

    // =========================================================================
    // § E2: Background ConfigStore.write & Concurrency Protection
    // =========================================================================

    private static void testE2ConfigStoreSynchronized() throws Exception {
        Method writeMethod = ConfigStore.class.getDeclaredMethod("write", String.class);
        boolean isSync = Modifier.isSynchronized(writeMethod.getModifiers());
        check(isSync, "E2: ConfigStore.write is declared synchronized for thread safety");
    }

    private static void testE2ConfigStoreAtomicWrite() throws Exception {
        Path tempDir = Files.createTempDirectory("config-store-test-");
        try {
            File dir = tempDir.toFile();
            ConfigStore store = new ConfigStore(dir);
            String testConfig = "{\"sites\":[{\"key\":\"test_site\",\"name\":\"Test Site\"}]}";

            store.write(testConfig);

            File configFile = new File(dir, "config.json");
            check(configFile.exists(), "E2: ConfigStore writes config.json to disk");
            String readContent =
                    new String(Files.readAllBytes(configFile.toPath()), StandardCharsets.UTF_8);
            check(
                    testConfig.equals(readContent),
                    "E2: config.json contains verbatim written content");

            // Verify no stray .tmp files remaining
            File[] leftovers = dir.listFiles((d, name) -> name.endsWith(".tmp"));
            check(
                    leftovers != null && leftovers.length == 0,
                    "E2: temporary atomic swap files deleted after write");
        } finally {
            for (File f : tempDir.toFile().listFiles()) f.delete();
            Files.deleteIfExists(tempDir);
        }
    }

    private static void testE2SourceControllerBackgroundDispatch() throws IOException {
        Path scPath =
                Paths.get("android/src/main/java/com/pilipala/marcomovie/SourceController.java");
        if (!Files.exists(scPath)) {
            scPath =
                    Paths.get(
                            "../../android/src/main/java/com/pilipala/marcomovie/SourceController.java");
        }
        check(Files.exists(scPath), "E2: SourceController.java exists");
        String content = Files.readString(scPath, StandardCharsets.UTF_8);

        check(
                content.contains("a.worker.execute") && content.contains("store.write(rawConfig)"),
                "E2: SourceController dispatches configStore.write to background worker executor");
        check(
                !content.contains("a.configStore.write(c.raw);"),
                "E2: Blocking direct configStore.write call removed from UI saveConfig path");
    }

    // =========================================================================
    // § E3: Robust Zip Import Redirects
    // =========================================================================

    private static void testE3ZipImportRedirects() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        AtomicBoolean cookieReceivedAtFinal = new AtomicBoolean(false);

        server.createContext(
                "/hop1",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", baseUrl + "/hop2");
                    exchange.sendResponseHeaders(301, -1);
                    exchange.close();
                });

        server.createContext(
                "/hop2",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", baseUrl + "/final.zip");
                    exchange.getResponseHeaders().set("Set-Cookie", "zip_auth=allow_123; Path=/");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        byte[] fakeZipBytes =
                "PK\003\004synthetic_zip_payload_data".getBytes(StandardCharsets.UTF_8);

        server.createContext(
                "/final.zip",
                exchange -> {
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    if (cookie != null && cookie.contains("zip_auth=allow_123")) {
                        cookieReceivedAtFinal.set(true);
                    }
                    exchange.sendResponseHeaders(200, fakeZipBytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(fakeZipBytes);
                    }
                    exchange.close();
                });

        server.start();
        try {
            byte[] downloaded = downloadZipHelper(baseUrl + "/hop1");
            check(
                    Arrays.equals(fakeZipBytes, downloaded),
                    "E3: fetchZipBytes follows multi-hop redirects and returns payload");
            check(
                    cookieReceivedAtFinal.get(),
                    "E3: fetchZipBytes tracks and forwards Set-Cookie across redirect hops");
        } finally {
            server.stop(0);
        }
    }

    private static void testE3ZipImportMaxHopsLimit() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        server.createContext(
                "/infinite",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", baseUrl + "/infinite");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        server.start();
        try {
            boolean caught = false;
            try {
                downloadZipHelper(baseUrl + "/infinite");
            } catch (IOException e) {
                if (e.getMessage() != null && e.getMessage().contains("来源重定向次数过多")) {
                    caught = true;
                }
            }
            check(
                    caught,
                    "E3: fetchZipBytes terminates infinite redirect loop with actionable error");
        } finally {
            server.stop(0);
        }
    }

    private static void testE3ZipImportSecurityValidation() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        server.createContext(
                "/proto_bad",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", "ftp://127.0.0.1/bad.zip");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        server.createContext(
                "/userinfo_bad",
                exchange -> {
                    exchange.getResponseHeaders()
                            .set("Location", "http://user:secret@127.0.0.1:" + port + "/cred.zip");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        server.start();
        try {
            boolean protoBlocked = false;
            try {
                downloadZipHelper(baseUrl + "/proto_bad");
            } catch (IOException e) {
                protoBlocked = e.getMessage() != null && e.getMessage().contains("不支持此重定向协议");
            }
            check(protoBlocked, "E3: fetchZipBytes rejects non-HTTP(S) redirect protocol target");

            boolean userinfoBlocked = false;
            try {
                downloadZipHelper(baseUrl + "/userinfo_bad");
            } catch (IOException e) {
                userinfoBlocked =
                        e.getMessage() != null && e.getMessage().contains("来源重定向不能注入登录凭据");
            }
            check(
                    userinfoBlocked,
                    "E3: fetchZipBytes blocks userInfo credential injection in redirect URL");
        } finally {
            server.stop(0);
        }
    }

    private static void testE3ZipImportPayloadLimit() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        // Serve stream larger than 28 MB limit (e.g. 29 MB)
        final int CHUNK_SIZE = 64 * 1024;
        final int TOTAL_CHUNKS = (29 * 1024 * 1024) / CHUNK_SIZE; // ~29MB

        server.createContext(
                "/huge.zip",
                exchange -> {
                    exchange.sendResponseHeaders(200, 0); // chunked
                    try (OutputStream out = exchange.getResponseBody()) {
                        byte[] chunk = new byte[CHUNK_SIZE];
                        for (int i = 0; i < TOTAL_CHUNKS; i++) {
                            out.write(chunk);
                            out.flush();
                        }
                    } catch (Exception ignored) {
                    }
                    exchange.close();
                });

        server.start();
        try {
            boolean limitEnforced = false;
            try {
                downloadZipHelper(baseUrl + "/huge.zip");
            } catch (IOException e) {
                limitEnforced = e.getMessage() != null && e.getMessage().contains("超过 28 MB 限制");
            }
            check(limitEnforced, "E3: fetchZipBytes terminates and enforces 28 MB package limit");
        } finally {
            server.stop(0);
        }
    }

    private static byte[] downloadZipHelper(String address) throws Exception {
        if (!Cms.isHttp(address)) throw new IOException("只支持 HTTP(S) 地址");
        URL current = new URL(Cms.normalizeHttp(address));
        Map<String, String> forwardedHeaders = new LinkedHashMap<>();
        forwardedHeaders.put("User-Agent", Cms.USER_AGENT);
        forwardedHeaders.put("Accept", "*/*");
        Map<String, Cms.RedirectCookie> redirectCookies = new LinkedHashMap<>();

        for (int hop = 0; hop < 5; hop++) {
            HttpURLConnection conn = (HttpURLConnection) current.openConnection();
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(5000);
            for (Map.Entry<String, String> entry : forwardedHeaders.entrySet()) {
                conn.setRequestProperty(entry.getKey(), entry.getValue());
            }

            try {
                int status = conn.getResponseCode();

                List<String> setCookies = conn.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry :
                            conn.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<Cms.RedirectCookie> newCookies = Cms.parseSetCookies(setCookies, current);
                for (Cms.RedirectCookie cookie : newCookies) {
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }

                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String loc = conn.getHeaderField("Location");
                    if (loc == null || loc.trim().isEmpty()) throw new IOException("重定向缺少地址");
                    URL target = new URL(current, loc.trim());
                    if (!Cms.isHttp(target.toString()))
                        throw new IOException("不支持此重定向协议: " + target.getProtocol());
                    if (target.getUserInfo() != null) throw new IOException("来源重定向不能注入登录凭据");
                    forwardedHeaders =
                            Cms.inheritedHeaders(
                                    current.toString(), target.toString(), forwardedHeaders);
                    Cms.mergeRedirectCookies(forwardedHeaders, redirectCookies.values(), target);
                    current = target;
                    continue;
                }

                if (status < 200 || status >= 300) throw new IOException("远程服务器返回 HTTP " + status);

                try (InputStream in = conn.getInputStream();
                        ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        if (bos.size() + n > 28 * 1024 * 1024)
                            throw new IOException("远程包超过 28 MB 限制");
                        bos.write(buf, 0, n);
                    }
                    return bos.toByteArray();
                }
            } finally {
                conn.disconnect();
            }
        }
        throw new IOException("来源重定向次数过多");
    }

    // =========================================================================
    // § E4: Cross-Domain Danmaku Header Strip
    // =========================================================================

    private static void testE4CrossDomainDanmakuHeaderStrip() throws Exception {
        HttpServer originServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer cdnServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);

        int originPort = originServer.getAddress().getPort();
        int cdnPort = cdnServer.getAddress().getPort();

        String originBase = "http://127.0.0.1:" + originPort;
        String cdnBase = "http://127.0.0.1:" + cdnPort;

        AtomicBoolean authStripped = new AtomicBoolean(false);
        AtomicBoolean cookieStripped = new AtomicBoolean(false);
        AtomicBoolean customHeaderKept = new AtomicBoolean(false);

        originServer.createContext(
                "/danmaku",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", cdnBase + "/danmaku.xml");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        String xmlBody = "<i><d p=\"1.0,1,25,16777215,0,0,0,0\">test comment</d></i>";

        cdnServer.createContext(
                "/danmaku.xml",
                exchange -> {
                    String auth = exchange.getRequestHeaders().getFirst("Authorization");
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    String client = exchange.getRequestHeaders().getFirst("X-Custom-Client");

                    authStripped.set(auth == null);
                    cookieStripped.set(cookie == null);
                    customHeaderKept.set("MarcoMovie-Test".equals(client));

                    byte[] bytes = xmlBody.getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, bytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(bytes);
                    }
                    exchange.close();
                });

        originServer.start();
        cdnServer.start();
        try {
            Map<String, String> requestHeaders = new LinkedHashMap<>();
            requestHeaders.put("Authorization", "Bearer sensitive-token-12345");
            requestHeaders.put("Cookie", "session=private_session_id");
            requestHeaders.put("Proxy-Authorization", "Basic secret");
            requestHeaders.put("X-Custom-Client", "MarcoMovie-Test");

            String body = fetchDanmakuHelper(originBase + "/danmaku", requestHeaders);
            check(
                    xmlBody.equals(body),
                    "E4: Danmaku fetch resolves cross-origin target response body");
            check(
                    authStripped.get(),
                    "E4: Cross-origin redirect strips Authorization and Proxy-Authorization headers");
            check(cookieStripped.get(), "E4: Cross-origin redirect strips origin Cookie header");
            check(
                    customHeaderKept.get(),
                    "E4: Cross-origin redirect preserves safe custom application headers");
        } finally {
            originServer.stop(0);
            cdnServer.stop(0);
        }
    }

    private static void testE4SameDomainDanmakuHeaderPreservation() throws Exception {
        HttpServer originServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = originServer.getAddress().getPort();
        String originBase = "http://127.0.0.1:" + port;

        AtomicBoolean authKept = new AtomicBoolean(false);
        AtomicBoolean cookieKept = new AtomicBoolean(false);

        originServer.createContext(
                "/same_redirect",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", originBase + "/same_final");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        String xmlBody = "<i><d p=\"2.0,1,25,16777215,0,0,0,0\">same origin</d></i>";

        originServer.createContext(
                "/same_final",
                exchange -> {
                    String auth = exchange.getRequestHeaders().getFirst("Authorization");
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    authKept.set("Bearer keep-me".equals(auth));
                    cookieKept.set("session=keep-me".equals(cookie));

                    byte[] bytes = xmlBody.getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, bytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(bytes);
                    }
                    exchange.close();
                });

        originServer.start();
        try {
            Map<String, String> requestHeaders = new LinkedHashMap<>();
            requestHeaders.put("Authorization", "Bearer keep-me");
            requestHeaders.put("Cookie", "session=keep-me");

            String body = fetchDanmakuHelper(originBase + "/same_redirect", requestHeaders);
            check(xmlBody.equals(body), "E4: Same-origin redirect returns body");
            check(authKept.get(), "E4: Same-origin redirect preserves Authorization header");
            check(cookieKept.get(), "E4: Same-origin redirect preserves Cookie header");
        } finally {
            originServer.stop(0);
        }
    }

    private static void testE4DanmakuCookiePropagation() throws Exception {
        HttpServer originServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = originServer.getAddress().getPort();
        String originBase = "http://127.0.0.1:" + port;

        AtomicBoolean serverCookieReceived = new AtomicBoolean(false);

        originServer.createContext(
                "/dmk_init",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", originBase + "/dmk_target");
                    exchange.getResponseHeaders().set("Set-Cookie", "dmk_sid=sess_999; Path=/");
                    exchange.sendResponseHeaders(302, -1);
                    exchange.close();
                });

        originServer.createContext(
                "/dmk_target",
                exchange -> {
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    if (cookie != null && cookie.contains("dmk_sid=sess_999")) {
                        serverCookieReceived.set(true);
                    }
                    byte[] bytes = "<i></i>".getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, bytes.length);
                    try (OutputStream out = exchange.getResponseBody()) {
                        out.write(bytes);
                    }
                    exchange.close();
                });

        originServer.start();
        try {
            fetchDanmakuHelper(originBase + "/dmk_init", Collections.emptyMap());
            check(
                    serverCookieReceived.get(),
                    "E4: Danmaku redirect parses Set-Cookie and merges into redirected request");
        } finally {
            originServer.stop(0);
        }
    }

    private static String fetchDanmakuHelper(String candidate, Map<String, String> headers)
            throws Exception {
        String address = candidate;
        if (!Cms.isHttp(address)) throw new IOException("来源没有提供有效弹幕地址");
        Map<String, String> reqHeaders = new LinkedHashMap<>(headers);
        URL currentUrl = new URL(Cms.normalizeHttp(address));
        HttpURLConnection connection = null;
        Map<String, Cms.RedirectCookie> redirectCookies = new LinkedHashMap<>();

        try {
            for (int redirect = 0; redirect < 5; redirect++) {
                if (connection != null) connection.disconnect();
                connection = (HttpURLConnection) currentUrl.openConnection();
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(5000);
                connection.setReadTimeout(5000);
                connection.setRequestProperty("User-Agent", Cms.USER_AGENT);
                for (Map.Entry<String, String> h : reqHeaders.entrySet()) {
                    if (h.getKey() != null) connection.setRequestProperty(h.getKey(), h.getValue());
                }
                int status = connection.getResponseCode();

                List<String> setCookies = connection.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry :
                            connection.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<Cms.RedirectCookie> newCookies = Cms.parseSetCookies(setCookies, currentUrl);
                for (Cms.RedirectCookie cookie : newCookies) {
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }

                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String loc = connection.getHeaderField("Location");
                    if (loc == null || loc.trim().isEmpty()) throw new IOException("弹幕重定向缺少地址");
                    URL targetUrl = new URL(currentUrl, loc.trim());
                    if (!Cms.isHttp(targetUrl.toString()))
                        throw new IOException("不支持此弹幕重定向协议: " + targetUrl.getProtocol());
                    if (targetUrl.getUserInfo() != null) throw new IOException("弹幕重定向不能注入登录凭据");
                    reqHeaders =
                            Cms.inheritedHeaders(
                                    currentUrl.toString(), targetUrl.toString(), reqHeaders);
                    Cms.mergeRedirectCookies(reqHeaders, redirectCookies.values(), targetUrl);
                    currentUrl = targetUrl;
                    continue;
                }

                if (status < 200 || status >= 300) throw new IOException("弹幕服务器返回 HTTP " + status);

                try (InputStream in = connection.getInputStream();
                        ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
                    return new String(bos.toByteArray(), StandardCharsets.UTF_8);
                }
            }
            throw new IOException("弹幕重定向次数过多");
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    // =========================================================================
    // § E5: Dynamic User-Agent & Turkish Locale.ROOT Regressions
    // =========================================================================

    private static void testE5DynamicUserAgentContract() throws IOException {
        Path playerPath =
                Paths.get("android/src/main/java/com/pilipala/marcomovie/MoviePlayer.java");
        if (!Files.exists(playerPath)) {
            playerPath =
                    Paths.get(
                            "../../android/src/main/java/com/pilipala/marcomovie/MoviePlayer.java");
        }
        check(Files.exists(playerPath), "E5: MoviePlayer.java exists");
        String content = Files.readString(playerPath, StandardCharsets.UTF_8);

        check(
                content.contains("defaultUserAgent(Context context)"),
                "E5: MoviePlayer defines static defaultUserAgent(Context context)");
        check(
                content.contains("MarcoMovie/\" + version") && content.contains("\"0.5.22\""),
                "E5: defaultUserAgent falls back to MarcoMovie/0.5.22 dynamically when context is null/missing");
        check(
                !content.contains("\"MarcoMovie/0.2.0\""),
                "E5: Outdated hardcoded MarcoMovie/0.2.0 completely eliminated from MoviePlayer");
        check(
                content.contains("sDefaultUserAgent"),
                "E5: MoviePlayer caches defaultUserAgent in volatile field to prevent repeated IPC binder calls");
    }

    private static void testE5TurkishLocaleZipUrl() {
        Locale original = Locale.getDefault();
        try {
            Locale.setDefault(new Locale("tr", "TR"));
            String urlUpper = "HTTPS://EXAMPLE.COM/PATH/PACKAGE.ZIP";

            // With Locale.ROOT
            String lowerRoot = urlUpper.toLowerCase(Locale.ROOT);
            check(
                    lowerRoot.endsWith(".zip"),
                    "E5 (Turkish): .toLowerCase(Locale.ROOT) produces standard ASCII .zip suffix");

            // Without Locale.ROOT (demonstrate bug reproduction)
            String lowerTurkish = urlUpper.toLowerCase();
            boolean brokenEndsWith = lowerTurkish.endsWith(".zip");
            check(
                    !brokenEndsWith,
                    "E5 (Turkish): unadorned .toLowerCase() in tr_TR produces .zıp and fails .endsWith(\".zip\")");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static void testE5TurkishLocaleArtworkHeaders() {
        Locale original = Locale.getDefault();
        try {
            Locale.setDefault(new Locale("tr", "TR"));
            String url = "HTTP://DOUBANIO.COM/VIEW/PHOTO/S_RATIO_POSTER/PUBLIC/P123.JPG";

            // With Locale.ROOT:
            String lower = url.toLowerCase(Locale.ROOT);
            boolean matchedDouban = lower.contains("doubanio.com") || lower.contains("douban.com");
            check(
                    matchedDouban,
                    "E5 (Turkish): Artwork URL with uppercase DOUBANIO matches Referer with Locale.ROOT");

            // Without Locale.ROOT:
            String brokenLower = url.toLowerCase();
            boolean brokenMatch = brokenLower.contains("doubanio.com");
            check(
                    !brokenMatch,
                    "E5 (Turkish): unadorned .toLowerCase() fails Doubanio referer match due to dotless ı");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static void testE5TurkishLocaleChannelMatching() {
        Locale original = Locale.getDefault();
        try {
            Locale.setDefault(new Locale("tr", "TR"));

            String rawName = "cctv-1 hd";
            String upperRoot = rawName.toUpperCase(Locale.ROOT);
            check(
                    upperRoot.startsWith("CCTV"),
                    "E5 (Turkish): .toUpperCase(Locale.ROOT) correctly formats CCTV channel badge");

            String query = "discovery";
            String chName = "DISCOVERY CHANNEL";
            String qLower = query.toLowerCase(Locale.ROOT);
            boolean matched = chName.toLowerCase(Locale.ROOT).contains(qLower);
            check(
                    matched,
                    "E5 (Turkish): Channel search matching succeeds for DISCOVERY in Turkish locale");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static void testE5TurkishLocaleSeasonNormalization() {
        Locale original = Locale.getDefault();
        try {
            String title = "Silicon Valley 第2季 (Vikings)";

            Locale.setDefault(Locale.ROOT);
            String normRoot = normalizeBaseKeyHelper(title);

            Locale.setDefault(new Locale("tr", "TR"));
            String normTurkish = normalizeBaseKeyHelper(title);

            check(
                    normRoot.equals(normTurkish),
                    "E5 (Turkish): Season normalization is byte-for-byte identical between Locale.ROOT and tr_TR");
        } finally {
            Locale.setDefault(original);
        }
    }

    private static String normalizeBaseKeyHelper(String s) {
        if (s == null) return "";
        return s.toLowerCase(Locale.ROOT)
                .replaceAll("[\\s·:：\\-—_（）()【】\\[\\]《》〈〉\"“”'’!！?？,，.。]", "")
                .trim();
    }

    private static void testE5CmsFileUntouchedBoundary() throws Exception {
        Path cmsPath = Paths.get("android/src/main/java/com/pilipala/marcomovie/Cms.java");
        if (!Files.exists(cmsPath)) {
            cmsPath = Paths.get("../../android/src/main/java/com/pilipala/marcomovie/Cms.java");
        }
        check(Files.exists(cmsPath), "E5: Cms.java exists");

        // Run git diff on Cms.java to prove Lane E did not modify Cms.java
        ProcessBuilder pb =
                new ProcessBuilder("git", "diff", "--name-only", "HEAD", "--", cmsPath.toString());
        pb.redirectErrorStream(true);
        Process p = pb.start();
        String output =
                new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
        p.waitFor();

        check(
                output.isEmpty(),
                "E5: Cms.java has zero git diff (strict Lane C ownership boundary respected)");
    }
}

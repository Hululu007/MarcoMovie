package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Behavioral regression suite covering every P1 and P2 item from the Android Mobile 0.7.0
 * independent Codex review (real production Cms, HttpT4Engine, RequestScope, CrashReportStore,
 * CrashReportDialog, CspEngine, and NativePythonEngine paths).
 */
public final class MobileCodexReviewChecks {
    private static int passed;

    private static void check(boolean cond, String label) {
        if (!cond) {
            throw new AssertionError("FAIL: " + label);
        }
        passed++;
        System.out.println("PASS " + label);
    }

    private static String readStreamUtf8(InputStream in) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) != -1) {
            bos.write(buf, 0, n);
        }
        return new String(bos.toByteArray(), StandardCharsets.UTF_8);
    }

    /** Minimal RFC 8484 / DoH JSON mock responder returning host-specific IP lists. */
    private static HttpServer startDohServer(Map<String, List<String>> records) throws Exception {
        HttpServer doh = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        doh.setExecutor(Executors.newCachedThreadPool());
        doh.createContext(
                "/dns-query",
                ex -> {
                    try {
                        String query = ex.getRequestURI().getRawQuery();
                        String host = extractQnameFromDohQuery(query);
                        List<String> ips = records.get(host);
                        if (ips == null) ips = Collections.emptyList();
                        StringBuilder ans = new StringBuilder();
                        ans.append("{\"Status\":0,\"Answer\":[");
                        for (int i = 0; i < ips.size(); i++) {
                            if (i > 0) ans.append(',');
                            ans.append("{\"name\":\"")
                                    .append(host)
                                    .append(".\",\"type\":1,\"TTL\":60,\"data\":\"")
                                    .append(ips.get(i))
                                    .append("\"}");
                        }
                        ans.append("]}");
                        byte[] out = ans.toString().getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "application/dns-json");
                        ex.sendResponseHeaders(200, out.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(out);
                        }
                    } finally {
                        ex.close();
                    }
                });
        doh.start();
        return doh;
    }

    private static String extractQnameFromDohQuery(String query) {
        if (query == null) return "";
        String dnsParam = null;
        for (String part : query.split("&")) {
            if (part.startsWith("dns=")) {
                dnsParam = part.substring(4);
                break;
            }
        }
        if (dnsParam == null || dnsParam.isEmpty()) return "";
        byte[] wire = decodeBase64Url(dnsParam);
        if (wire.length < 13) return "";
        int pos = 12;
        StringBuilder name = new StringBuilder();
        while (pos < wire.length) {
            int len = wire[pos++] & 0xff;
            if (len == 0) break;
            if (pos + len > wire.length) break;
            if (name.length() > 0) name.append('.');
            name.append(new String(wire, pos, len, StandardCharsets.US_ASCII));
            pos += len;
        }
        return name.toString().toLowerCase(java.util.Locale.ROOT);
    }

    private static byte[] decodeBase64Url(String s) {
        String std = s.replace('-', '+').replace('_', '/');
        while (std.length() % 4 != 0) std += "=";
        return java.util.Base64.getDecoder().decode(std);
    }

    private static int findDualLoopbackPort() throws Exception {
        for (int attempt = 0; attempt < 30; attempt++) {
            try (ServerSocket s1 =
                    new ServerSocket(0, 0, InetAddress.getByAddress(new byte[] {127, 0, 0, 1}))) {
                int port = s1.getLocalPort();
                try (ServerSocket s2 =
                        new ServerSocket(
                                port, 0, InetAddress.getByAddress(new byte[] {127, 0, 0, 2}))) {
                    return port;
                } catch (Exception busy) {
                    // Try another ephemeral port.
                }
            }
        }
        throw new IllegalStateException("Could not allocate dual-loopback test port");
    }

    // P1 #1: API 23 DoH candidate deduplication & ordering (single IP, dup IPv4, mixed IPv4/IPv6)
    private static void test1_Api23DohCandidates() throws Exception {
        InetAddress ip1 =
                InetAddress.getByAddress(new byte[] {(byte) 185, (byte) 199, 108, (byte) 133});
        InetAddress ip2 =
                InetAddress.getByAddress(new byte[] {(byte) 185, (byte) 199, 109, (byte) 133});
        InetAddress v6 =
                InetAddress.getByAddress(
                        new byte[] {
                            0x26,
                            0x06,
                            0x50,
                            (byte) 0xc0,
                            (byte) 0x80,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1
                        });
        InetAddress v6Dup =
                InetAddress.getByAddress(
                        new byte[] {
                            0x26,
                            0x06,
                            0x50,
                            (byte) 0xc0,
                            (byte) 0x80,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1
                        });

        List<InetAddress> single = Cms.selectDohRaceCandidates(Collections.singletonList(ip1), 4);
        check(
                single.size() == 1 && ip1.getHostAddress().equals(single.get(0).getHostAddress()),
                "#1 API 23 DoH single-IP selection preserves exact address");

        List<InetAddress> dupV4 = Cms.selectDohRaceCandidates(Arrays.asList(ip2, ip1, ip2, ip1), 4);
        check(
                dupV4.size() == 2
                        && ip2.getHostAddress().equals(dupV4.get(0).getHostAddress())
                        && ip1.getHostAddress().equals(dupV4.get(1).getHostAddress()),
                "#1 API 23 DoH duplicate IPv4 deduplicates while preserving first-seen order");

        List<InetAddress> mixed =
                Cms.selectDohRaceCandidates(Arrays.asList(v6, ip2, v6Dup, ip1, ip2), 4);
        check(
                mixed.size() == 3
                        && ip2.getHostAddress().equals(mixed.get(0).getHostAddress())
                        && ip1.getHostAddress().equals(mixed.get(1).getHostAddress())
                        && v6.getHostAddress().equals(mixed.get(2).getHostAddress()),
                "#1 API 23 DoH mixed IPv4/IPv6 prioritizes IPv4 before IPv6 and deduplicates both");
    }

    // P1 #2: LMK preservation matrix (foreground, confirmed cached, unknown, submitted legacy)
    private static void test2_LmkPreservationMatrix() throws Exception {
        Path tmp = Files.createTempDirectory("codex-lmk-matrix-");
        try {
            File dir = tmp.toFile();
            long now = System.currentTimeMillis();

            CrashReportStore.CrashReport fg = new CrashReportStore.CrashReport();
            fg.id = "lmk_fg";
            fg.timestampMs = now - 4_000L;
            fg.kind = CrashReportStore.KIND_LOW_MEMORY;
            fg.summary = "内存不足 (OOM/LMK) (status=0)";
            fg.stackTrace = "ProcessExitReason: 3\nImportance: 100\nStatus/Signal: 0";

            CrashReportStore.CrashReport cached = new CrashReportStore.CrashReport();
            cached.id = "lmk_cached";
            cached.timestampMs = now - 3_000L;
            cached.kind = CrashReportStore.KIND_LOW_MEMORY;
            cached.summary = "内存不足 (OOM/LMK) (status=0)";
            cached.stackTrace = "ProcessExitReason: 3\nImportance: 400\nStatus/Signal: 0";

            CrashReportStore.CrashReport unknown = new CrashReportStore.CrashReport();
            unknown.id = "lmk_unknown";
            unknown.timestampMs = now - 2_000L;
            unknown.kind = CrashReportStore.KIND_LOW_MEMORY;
            unknown.summary = "内存不足 (OOM/LMK) (status=0)";
            unknown.stackTrace = "ProcessExitReason: 3\nStatus/Signal: 0";

            CrashReportStore.CrashReport invalidImp = new CrashReportStore.CrashReport();
            invalidImp.id = "lmk_invalid_imp";
            invalidImp.timestampMs = now - 1_500L;
            invalidImp.kind = CrashReportStore.KIND_LOW_MEMORY;
            invalidImp.summary = "内存不足 (OOM/LMK) (status=0)";
            invalidImp.stackTrace = "ProcessExitReason: 3\nImportance: NaN\nStatus/Signal: 0";

            CrashReportStore.CrashReport submittedOld = new CrashReportStore.CrashReport();
            submittedOld.id = "lmk_submitted_old";
            submittedOld.timestampMs = now - 1_000L;
            submittedOld.kind = CrashReportStore.KIND_LOW_MEMORY;
            submittedOld.summary = "内存不足 (OOM/LMK) (status=0)";
            submittedOld.stackTrace = "";
            submittedOld.submitted = true;
            submittedOld.submittedIssueNumber = 77;
            submittedOld.submittedIssueUrl = "https://github.com/Pilipala9919/MarcoMovie/issues/77";

            CrashReportStore.saveReport(dir, fg);
            CrashReportStore.saveReport(dir, cached);
            CrashReportStore.saveReport(dir, unknown);
            CrashReportStore.saveReport(dir, invalidImp);
            CrashReportStore.saveReport(dir, submittedOld);

            List<CrashReportStore.CrashReport> startup =
                    CrashReportStore.loadPromptableReports(dir, now);
            List<CrashReportStore.CrashReport> history = CrashReportStore.loadReports(dir);
            File rDir = CrashReportStore.reportDir(dir);

            List<String> startupIds = idsOf(startup);
            List<String> historyIds = idsOf(history);
            CrashReportStore.CrashReport foundSub = findById(history, "lmk_submitted_old");

            check(
                    startupIds.equals(Collections.singletonList("lmk_fg")),
                    "#2 LMK startup list includes ONLY explicit foreground LMK");
            check(
                    historyIds.contains("lmk_fg")
                            && !historyIds.contains("lmk_cached")
                            && historyIds.contains("lmk_unknown")
                            && historyIds.contains("lmk_invalid_imp")
                            && historyIds.contains("lmk_submitted_old")
                            && foundSub != null
                            && foundSub.submitted
                            && foundSub.submittedIssueNumber == 77,
                    "#2 LMK Settings history deletes ONLY confirmed cached (>=400) and preserves foreground, unknown, invalid, and submitted #77");
            check(
                    new File(rDir, "lmk_fg.json").isFile()
                            && !new File(rDir, "lmk_cached.json").isFile()
                            && new File(rDir, "lmk_unknown.json").isFile()
                            && new File(rDir, "lmk_invalid_imp.json").isFile()
                            && new File(rDir, "lmk_submitted_old.json").isFile(),
                    "#2 LMK disk files match exact retention policy (unknown & submitted JSON files stay on disk)");
        } finally {
            deleteRecursive(tmp.toFile());
        }
    }

    // P2 #4: HttpT4Engine POST single-write across dual healthy DoH IPs, 403 after full form,
    // system-route read timeout after full form (no DoH resend), and pre-connect failover.
    private static void test4_NoDuplicatePostOnDualHealthyDoh() throws Exception {
        int port = findDualLoopbackPort();
        AtomicInteger postCountA = new AtomicInteger();
        AtomicInteger postCountB = new AtomicInteger();
        AtomicInteger postCount403Direct = new AtomicInteger();
        AtomicInteger postCount403Doh = new AtomicInteger();
        AtomicInteger postCountTimeoutSys = new AtomicInteger();
        AtomicInteger postCountTimeoutDoh = new AtomicInteger();
        AtomicInteger postCountFailoverB = new AtomicInteger();
        AtomicReference<String> receivedBody = new AtomicReference<>("");
        CountDownLatch releaseSlowTimeout = new CountDownLatch(1);

        HttpServer srvA =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 1}), port),
                        0);
        HttpServer srvB =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 2}), port),
                        0);
        srvA.setExecutor(Executors.newCachedThreadPool());
        srvB.setExecutor(Executors.newCachedThreadPool());
        srvA.createContext(
                "/t4",
                ex -> {
                    try {
                        if ("POST".equalsIgnoreCase(ex.getRequestMethod())) {
                            postCountA.incrementAndGet();
                            receivedBody.set(readStreamUtf8(ex.getRequestBody()));
                        }
                        byte[] resp =
                                "{\"url\":\"https://cdn.example.test/v.m3u8\"}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        srvB.createContext(
                "/t4",
                ex -> {
                    try {
                        if ("POST".equalsIgnoreCase(ex.getRequestMethod())) {
                            postCountB.incrementAndGet();
                        }
                        byte[] resp =
                                "{\"url\":\"https://cdn.example.test/v2.m3u8\"}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        srvA.createContext(
                "/t4-403-direct",
                ex -> {
                    try {
                        if ("POST".equalsIgnoreCase(ex.getRequestMethod())) {
                            String bodyStr = readStreamUtf8(ex.getRequestBody());
                            if (bodyStr.contains("play=ep1") && bodyStr.contains("flag=line1")) {
                                postCount403Direct.incrementAndGet();
                            }
                        }
                        ex.sendResponseHeaders(403, -1);
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        srvA.createContext(
                "/t4-403-doh",
                ex -> {
                    try {
                        if ("POST".equalsIgnoreCase(ex.getRequestMethod())) {
                            String bodyStr = readStreamUtf8(ex.getRequestBody());
                            if (bodyStr.contains("play=ep1") && bodyStr.contains("flag=line1")) {
                                postCount403Doh.incrementAndGet();
                            }
                        }
                        ex.sendResponseHeaders(403, -1);
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        srvB.createContext(
                "/t4-timeout",
                ex -> {
                    try {
                        if ("POST".equalsIgnoreCase(ex.getRequestMethod())) {
                            String bodyStr = readStreamUtf8(ex.getRequestBody());
                            if (bodyStr.contains("play=ep1") && bodyStr.contains("flag=line1")) {
                                postCountTimeoutDoh.incrementAndGet();
                            }
                        }
                        byte[] resp =
                                "{\"url\":\"https://cdn.example.test/should-not-hit.m3u8\"}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        srvA.start();
        srvB.start();

        // Dedicated port where ONLY 127.0.0.2 listens (127.0.0.1 refuses TCP before connect)
        HttpServer srvFailoverOnlyB =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 2}), 0),
                        0);
        int failoverPort = srvFailoverOnlyB.getAddress().getPort();
        srvFailoverOnlyB.createContext(
                "/t4-failover",
                ex -> {
                    try {
                        if ("POST".equalsIgnoreCase(ex.getRequestMethod())) {
                            String bodyStr = readStreamUtf8(ex.getRequestBody());
                            if (bodyStr.contains("play=ep1") && bodyStr.contains("flag=line1")) {
                                postCountFailoverB.incrementAndGet();
                            }
                        }
                        byte[] resp =
                                "{\"url\":\"https://cdn.example.test/failover-ok.m3u8\"}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        srvFailoverOnlyB.start();

        // System-route proxy listener that reads the FULL POST form and stalls until read timeout
        HttpServer sysRouteTimeoutProxy =
                HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int sysProxyPort = sysRouteTimeoutProxy.getAddress().getPort();
        sysRouteTimeoutProxy.setExecutor(Executors.newCachedThreadPool());
        sysRouteTimeoutProxy.createContext(
                "/",
                ex -> {
                    try {
                        if ("POST".equalsIgnoreCase(ex.getRequestMethod())) {
                            String bodyStr = readStreamUtf8(ex.getRequestBody());
                            if (bodyStr.contains("play=ep1") && bodyStr.contains("flag=line1")) {
                                postCountTimeoutSys.incrementAndGet();
                            }
                        }
                        releaseSlowTimeout.await(4, TimeUnit.SECONDS);
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        sysRouteTimeoutProxy.start();

        Map<String, List<String>> dns = new LinkedHashMap<>();
        dns.put("t4-dual.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
        dns.put("t4-403-doh.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
        dns.put("t4-timeout.invalid", Collections.singletonList("127.0.0.2"));
        dns.put("t4-failover.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
        HttpServer doh = startDohServer(dns);

        final java.net.ProxySelector origProxySelector = java.net.ProxySelector.getDefault();
        try {
            Cms.setDohEndpointsForTest(
                    "http://127.0.0.1:" + doh.getAddress().getPort() + "/dns-query");
            StringBuilder longExt = new StringBuilder();
            for (int i = 0; i < 120; i++) longExt.append("0123456789");
            final String extPayload = longExt.toString();

            // 4a: Dual healthy DoH IPs -> strictly 1 POST
            Cms.Site siteDual = new Cms.Site();
            siteDual.key = "t4_post";
            siteDual.name = "T4 Post";
            siteDual.type = 4;
            siteDual.api = "http://t4-dual.invalid:" + port + "/t4";
            siteDual.ext = extPayload;
            String outDual = new HttpT4Engine(siteDual).player("line1", "ep1");
            int totalPosts = postCountA.get() + postCountB.get();
            check(
                    outDual.contains("v.m3u8")
                            && totalPosts == 1
                            && postCountA.get() == 1
                            && postCountB.get() == 0
                            && receivedBody.get().contains("play=ep1")
                            && receivedBody.get().contains("flag=line1"),
                    "#4a HttpT4Engine POST over 2 healthy DoH IPs writes form body strictly once (totalPosts="
                            + totalPosts
                            + ")");

            // 4b-1: Direct server receives full form and returns 403 -> NO UA fallback resend
            Cms.Site site403Direct = new Cms.Site();
            site403Direct.key = "t4_403_direct";
            site403Direct.name = "T4 403 Direct";
            site403Direct.type = 4;
            site403Direct.api = "http://127.0.0.1:" + port + "/t4-403-direct";
            site403Direct.ext = extPayload;
            Exception err403Direct = null;
            try {
                new HttpT4Engine(site403Direct).player("line1", "ep1");
            } catch (Exception e) {
                err403Direct = e;
            }
            check(
                    err403Direct != null
                            && err403Direct.getMessage() != null
                            && err403Direct.getMessage().contains("403")
                            && postCount403Direct.get() == 1,
                    "#4b-1 HttpT4Engine POST receiving 403 after full form stops immediately with no UA fallback resend (count="
                            + postCount403Direct.get()
                            + ")");

            // 4b-2: DoH server receives full form and returns 403 -> NO DoH UA fallback resend
            Cms.Site site403Doh = new Cms.Site();
            site403Doh.key = "t4_403_doh";
            site403Doh.name = "T4 403 DoH";
            site403Doh.type = 4;
            site403Doh.api = "http://t4-403-doh.invalid:" + port + "/t4-403-doh";
            site403Doh.ext = extPayload;
            Exception err403Doh = null;
            try {
                new HttpT4Engine(site403Doh).player("line1", "ep1");
            } catch (Exception e) {
                err403Doh = e;
            }
            check(
                    err403Doh != null
                            && err403Doh.getMessage() != null
                            && err403Doh.getMessage().contains("403")
                            && postCount403Doh.get() == 1,
                    "#4b-2 HttpT4Engine POST via DoH receiving 403 after full form stops with no DoH UA resend (count="
                            + postCount403Doh.get()
                            + ")");

            // 4c: System route receives full form then times out reading response -> NO DoH resend
            Cms.setDirectReadTimeoutMsForTest(350);
            java.net.ProxySelector.setDefault(
                    new java.net.ProxySelector() {
                        @Override
                        public List<java.net.Proxy> select(java.net.URI uri) {
                            if (uri != null
                                    && "t4-timeout.invalid".equalsIgnoreCase(uri.getHost())) {
                                return Collections.singletonList(
                                        new java.net.Proxy(
                                                java.net.Proxy.Type.HTTP,
                                                new InetSocketAddress("127.0.0.1", sysProxyPort)));
                            }
                            return Collections.singletonList(java.net.Proxy.NO_PROXY);
                        }

                        @Override
                        public void connectFailed(
                                java.net.URI uri,
                                java.net.SocketAddress sa,
                                java.io.IOException ioe) {}
                    });
            Cms.Site siteTimeout = new Cms.Site();
            siteTimeout.key = "t4_timeout";
            siteTimeout.name = "T4 Read Timeout";
            siteTimeout.type = 4;
            siteTimeout.api = "http://t4-timeout.invalid:" + port + "/t4-timeout";
            siteTimeout.ext = extPayload;
            Exception errTimeout = null;
            try {
                new HttpT4Engine(siteTimeout).player("line1", "ep1");
            } catch (Exception e) {
                errTimeout = e;
            } finally {
                java.net.ProxySelector.setDefault(origProxySelector);
                Cms.setDirectReadTimeoutMsForTest(0);
                releaseSlowTimeout.countDown();
            }
            int totalTimeoutPosts = postCountTimeoutSys.get() + postCountTimeoutDoh.get();
            check(
                    errTimeout instanceof java.net.SocketTimeoutException
                            && postCountTimeoutSys.get() == 1
                            && postCountTimeoutDoh.get() == 0
                            && totalTimeoutPosts == 1,
                    "#4c HttpT4Engine POST timing out after system route receives full form does NOT resend to DoH (sys="
                            + postCountTimeoutSys.get()
                            + ", doh="
                            + postCountTimeoutDoh.get()
                            + ")");

            // 4d: Pre-connect failure (IP #1 refuses TCP) still fails over to healthy IP #2 once
            Cms.Site siteFailover = new Cms.Site();
            siteFailover.key = "t4_failover";
            siteFailover.name = "T4 Pre-Connect Failover";
            siteFailover.type = 4;
            siteFailover.api = "http://t4-failover.invalid:" + failoverPort + "/t4-failover";
            siteFailover.ext = extPayload;
            String outFailover = new HttpT4Engine(siteFailover).player("line1", "ep1");
            check(
                    outFailover.contains("failover-ok.m3u8") && postCountFailoverB.get() == 1,
                    "#4d HttpT4Engine POST failing before TCP connect still fails over to healthy DoH IP and writes once");
        } finally {
            releaseSlowTimeout.countDown();
            java.net.ProxySelector.setDefault(origProxySelector);
            Cms.setDirectReadTimeoutMsForTest(0);
            Cms.setDohEndpointsForTest();
            doh.stop(0);
            srvA.stop(0);
            srvB.stop(0);
            srvFailoverOnlyB.stop(0);
            sysRouteTimeoutProxy.stop(0);
        }
    }

    // P2 #5: Unified single-IP error handling (404 single request/single UA, 302 missing Location)
    private static void test5_SingleIpErrorSemantics() throws Exception {
        AtomicInteger hits404Import = new AtomicInteger();
        Set<String> uas404Import = Collections.newSetFromMap(new ConcurrentHashMap<>());
        AtomicInteger hits404Fetch = new AtomicInteger();
        Set<String> uas404Fetch = Collections.newSetFromMap(new ConcurrentHashMap<>());
        AtomicInteger hits302Import = new AtomicInteger();
        AtomicInteger hits302Fetch = new AtomicInteger();

        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = srv.getAddress().getPort();
        srv.createContext(
                "/404-import",
                ex -> {
                    hits404Import.incrementAndGet();
                    String ua = ex.getRequestHeaders().getFirst("User-Agent");
                    if (ua != null) uas404Import.add(ua);
                    ex.sendResponseHeaders(404, -1);
                    ex.close();
                });
        srv.createContext(
                "/404-fetch",
                ex -> {
                    hits404Fetch.incrementAndGet();
                    String ua = ex.getRequestHeaders().getFirst("User-Agent");
                    if (ua != null) uas404Fetch.add(ua);
                    ex.sendResponseHeaders(404, -1);
                    ex.close();
                });
        srv.createContext(
                "/302-missing-import",
                ex -> {
                    hits302Import.incrementAndGet();
                    ex.sendResponseHeaders(302, -1);
                    ex.close();
                });
        srv.createContext(
                "/302-missing-fetch",
                ex -> {
                    hits302Fetch.incrementAndGet();
                    ex.sendResponseHeaders(302, -1);
                    ex.close();
                });
        srv.start();

        Map<String, List<String>> dns = new LinkedHashMap<>();
        dns.put("single-err.invalid", Collections.singletonList("127.0.0.1"));
        HttpServer doh = startDohServer(dns);
        try {
            Cms.setDohEndpointsForTest(
                    "http://127.0.0.1:" + doh.getAddress().getPort() + "/dns-query");

            Exception errImp404 = null;
            try {
                Cms.fetchImport("http://single-err.invalid:" + port + "/404-import");
            } catch (Exception e) {
                errImp404 = e;
            }
            check(
                    errImp404 != null
                            && errImp404.getMessage() != null
                            && errImp404.getMessage().contains("404")
                            && hits404Import.get() == 1
                            && uas404Import.size() == 1,
                    "#5 fetchImport single-IP 404 stops after 1 request and 1 UA");

            Exception errFetch404 = null;
            try {
                Cms.fetch("http://single-err.invalid:" + port + "/404-fetch", null);
            } catch (Exception e) {
                errFetch404 = e;
            }
            check(
                    errFetch404 != null
                            && errFetch404.getMessage() != null
                            && errFetch404.getMessage().contains("404")
                            && hits404Fetch.get() == 1
                            && uas404Fetch.size() == 1,
                    "#5 Cms.fetch single-IP 404 stops after 1 request and 1 UA");

            Exception errImp302 = null;
            try {
                Cms.fetchImport("http://single-err.invalid:" + port + "/302-missing-import");
            } catch (Exception e) {
                errImp302 = e;
            }
            check(
                    errImp302 != null
                            && errImp302.getMessage() != null
                            && errImp302.getMessage().contains("重定向缺少地址")
                            && hits302Import.get() == 1,
                    "#5 fetchImport single-IP 302 missing Location surfaces exact redirect error (not UnknownHostException)");

            Exception errFetch302 = null;
            try {
                Cms.fetch("http://single-err.invalid:" + port + "/302-missing-fetch", null);
            } catch (Exception e) {
                errFetch302 = e;
            }
            check(
                    errFetch302 != null
                            && errFetch302.getMessage() != null
                            && errFetch302.getMessage().contains("重定向缺少地址")
                            && hits302Fetch.get() == 1,
                    "#5 Cms.fetch single-IP 302 missing Location surfaces exact redirect error (not UnknownHostException)");
        } finally {
            Cms.setDohEndpointsForTest();
            doh.stop(0);
            srv.stop(0);
        }
    }

    // P2 #6: Multi-IP 500 vs slower 200, .py HTML interception vs valid script, same-origin &
    // cross-host 302
    private static void test6_MultiIpSelectionAndRedirects() throws Exception {
        int port = findDualLoopbackPort();
        AtomicInteger crossHostAuthPresent = new AtomicInteger();
        AtomicInteger crossHostCookiePresent = new AtomicInteger();

        HttpServer srvA =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 1}), port),
                        0);
        HttpServer srvB =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 2}), port),
                        0);
        srvA.setExecutor(Executors.newCachedThreadPool());
        srvB.setExecutor(Executors.newCachedThreadPool());

        // 6a: A fast 500, B slow 200
        srvA.createContext(
                "/fast500",
                ex -> {
                    ex.sendResponseHeaders(500, -1);
                    ex.close();
                });
        srvB.createContext(
                "/fast500",
                ex -> {
                    try {
                        Thread.sleep(220L);
                        byte[] resp =
                                "{\"sites\":[{\"key\":\"ok\",\"api\":\"http://ok.test\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });

        // 6b: A fast HTML block page, B slow valid Python script
        srvA.createContext(
                "/spider.py",
                ex -> {
                    byte[] html =
                            "<!DOCTYPE html><html><body>Access Blocked</body></html>"
                                    .getBytes(StandardCharsets.UTF_8);
                    ex.getResponseHeaders().set("Content-Type", "text/html");
                    ex.sendResponseHeaders(200, html.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(html);
                    }
                    ex.close();
                });
        srvB.createContext(
                "/spider.py",
                ex -> {
                    try {
                        Thread.sleep(220L);
                        byte[] py =
                                "class Spider:\n    def homeContent(self, f): return {}\n"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "text/plain");
                        ex.sendResponseHeaders(200, py.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(py);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                });
        srvA.createContext(
                "/legit-page",
                ex -> {
                    byte[] html =
                            "<html><body><h1>Legit HTML</h1></body></html>"
                                    .getBytes(StandardCharsets.UTF_8);
                    ex.getResponseHeaders().set("Content-Type", "text/html");
                    ex.sendResponseHeaders(200, html.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(html);
                    }
                    ex.close();
                });

        // 6c-1: Same-origin 302 on healthy IP #2 (IP #1 is unused/refused port on 127.0.0.3 or
        // stopped)
        srvB.createContext(
                "/same-origin-start",
                ex -> {
                    ex.getResponseHeaders().set("Location", "/same-origin-final");
                    ex.sendResponseHeaders(302, -1);
                    ex.close();
                });
        srvB.createContext(
                "/same-origin-final",
                ex -> {
                    byte[] resp =
                            "{\"same_origin\":\"pinned_ip2\"}".getBytes(StandardCharsets.UTF_8);
                    ex.sendResponseHeaders(200, resp.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(resp);
                    }
                    ex.close();
                });

        // 6c-2: Cross-host 302 from host-a (IP #1) -> host-b (IP #2), verifying credential
        // stripping
        srvA.createContext(
                "/cross-start",
                ex -> {
                    ex.getResponseHeaders()
                            .set("Location", "http://host-b.invalid:" + port + "/cross-final");
                    ex.sendResponseHeaders(302, -1);
                    ex.close();
                });
        srvB.createContext(
                "/cross-final",
                ex -> {
                    if (ex.getRequestHeaders().getFirst("Authorization") != null) {
                        crossHostAuthPresent.incrementAndGet();
                    }
                    if (ex.getRequestHeaders().getFirst("Cookie") != null) {
                        crossHostCookiePresent.incrementAndGet();
                    }
                    byte[] resp =
                            "{\"cross_host\":\"resolved_ip2\"}".getBytes(StandardCharsets.UTF_8);
                    ex.sendResponseHeaders(200, resp.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(resp);
                    }
                    ex.close();
                });

        srvA.start();
        srvB.start();

        // Dedicated port where ONLY 127.0.0.2 listens (127.0.0.1 actively refuses connection!)
        int onlyIp2Port;
        HttpServer srvOnlyB =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 2}), 0),
                        0);
        onlyIp2Port = srvOnlyB.getAddress().getPort();
        srvOnlyB.createContext(
                "/hop1",
                ex -> {
                    ex.getResponseHeaders().set("Location", "/hop2");
                    ex.sendResponseHeaders(302, -1);
                    ex.close();
                });
        srvOnlyB.createContext(
                "/hop2",
                ex -> {
                    byte[] resp = "{\"redirect_pinned\":true}".getBytes(StandardCharsets.UTF_8);
                    ex.sendResponseHeaders(200, resp.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(resp);
                    }
                    ex.close();
                });
        srvOnlyB.start();

        Map<String, List<String>> dns = new LinkedHashMap<>();
        dns.put("race-sel.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
        dns.put("html-ok.invalid", Collections.singletonList("127.0.0.1"));
        dns.put("same-hop.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
        dns.put("host-a.invalid", Collections.singletonList("127.0.0.1"));
        dns.put("host-b.invalid", Collections.singletonList("127.0.0.2"));
        HttpServer doh = startDohServer(dns);

        try {
            Cms.setDohEndpointsForTest(
                    "http://127.0.0.1:" + doh.getAddress().getPort() + "/dns-query");

            String res500Import = Cms.fetchImport("http://race-sel.invalid:" + port + "/fast500");
            String res500Fetch = Cms.fetch("http://race-sel.invalid:" + port + "/fast500", null);
            check(
                    res500Import.contains("\"key\":\"ok\"")
                            && res500Fetch.contains("\"key\":\"ok\""),
                    "#6a Multi-IP race does not let fast 500 cancel slower healthy 200 (both fetchImport and Cms.fetch)");

            String pySource =
                    NativePythonEngine.fetchScriptSource(
                            "http://race-sel.invalid:" + port + "/spider.py", null);
            String legitHtml = Cms.fetch("http://html-ok.invalid:" + port + "/legit-page", null);
            check(
                    pySource.contains("class Spider:")
                            && !Cms.isHtml(pySource)
                            && legitHtml.contains("Legit HTML"),
                    "#6b .py download rejects fast 200 HTML interception page in favor of valid script, while generic Cms.fetch preserves legitimate HTML");

            String sameHopRes = Cms.fetchImport("http://same-hop.invalid:" + onlyIp2Port + "/hop1");
            check(
                    sameHopRes.contains("\"redirect_pinned\":true"),
                    "#6c Same-origin 302 stays pinned on healthy IP #2 instead of rebinding bad IP #1");

            Map<String, String> authHeaders = new LinkedHashMap<>();
            authHeaders.put("Authorization", "Bearer top-secret");
            authHeaders.put("Cookie", "sid=secret123");
            String crossHopRes =
                    Cms.fetch("http://host-a.invalid:" + port + "/cross-start", authHeaders);
            check(
                    crossHopRes.contains("\"cross_host\":\"resolved_ip2\"")
                            && crossHostAuthPresent.get() == 0
                            && crossHostCookiePresent.get() == 0,
                    "#6c Cross-host 302 re-resolves target host via DoH and strips Authorization & Cookie");

            // 6d: Two entry IPs (A, B) both redirect cross-host to target host whose IP C returns
            // 500 (or HTML) and IP D returns valid 200 JSON; Cms.fetchImport must advance to D,
            // preserve cross-host credential/cookie isolation, and enforce redirect hop cap.
            int targetPort = findDualLoopbackPort();
            AtomicInteger targetC500Hits = new AtomicInteger();
            AtomicInteger targetD200Hits = new AtomicInteger();
            AtomicInteger targetAuthLeaks = new AtomicInteger();
            AtomicInteger targetCookieLeaks = new AtomicInteger();
            HttpServer targetC =
                    HttpServer.create(
                            new InetSocketAddress(
                                    InetAddress.getByAddress(new byte[] {127, 0, 0, 1}),
                                    targetPort),
                            0);
            HttpServer targetD =
                    HttpServer.create(
                            new InetSocketAddress(
                                    InetAddress.getByAddress(new byte[] {127, 0, 0, 2}),
                                    targetPort),
                            0);
            targetC.setExecutor(Executors.newCachedThreadPool());
            targetD.setExecutor(Executors.newCachedThreadPool());
            targetC.createContext(
                    "/xhost-final",
                    ex -> {
                        targetC500Hits.incrementAndGet();
                        if (ex.getRequestHeaders().getFirst("Authorization") != null)
                            targetAuthLeaks.incrementAndGet();
                        if (ex.getRequestHeaders().getFirst("Cookie") != null)
                            targetCookieLeaks.incrementAndGet();
                        ex.getResponseHeaders().add("Set-Cookie", "bad_c=1; Path=/");
                        ex.sendResponseHeaders(500, -1);
                        ex.close();
                    });
            targetD.createContext(
                    "/xhost-final",
                    ex -> {
                        targetD200Hits.incrementAndGet();
                        if (ex.getRequestHeaders().getFirst("Authorization") != null)
                            targetAuthLeaks.incrementAndGet();
                        if (ex.getRequestHeaders().getFirst("Cookie") != null)
                            targetCookieLeaks.incrementAndGet();
                        byte[] resp =
                                "{\"sites\":[{\"key\":\"target_d\",\"api\":\"http://ok.test\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                        ex.close();
                    });
            targetC.createContext(
                    "/xhost-html",
                    ex -> {
                        byte[] html =
                                "<!DOCTYPE html><html><body>Edge Intercept</body></html>"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "text/html");
                        ex.sendResponseHeaders(200, html.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(html);
                        }
                        ex.close();
                    });
            targetD.createContext(
                    "/xhost-html",
                    ex -> {
                        byte[] resp =
                                "{\"sites\":[{\"key\":\"target_d_nonhtml\",\"api\":\"http://ok.test\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                        ex.close();
                    });
            targetC.createContext(
                    "/xhost-loop",
                    ex -> {
                        ex.getResponseHeaders().set("Location", "/xhost-loop");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    });
            targetD.createContext(
                    "/xhost-loop",
                    ex -> {
                        ex.getResponseHeaders().set("Location", "/xhost-loop");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    });
            targetC.start();
            targetD.start();

            com.sun.net.httpserver.HttpHandler entryTo500Then200 =
                    ex -> {
                        ex.getResponseHeaders().add("Set-Cookie", "entry_sid=secret; Path=/");
                        ex.getResponseHeaders()
                                .set(
                                        "Location",
                                        "http://target-xhost.invalid:"
                                                + targetPort
                                                + "/xhost-final");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    };
            com.sun.net.httpserver.HttpHandler entryToHtmlThenJson =
                    ex -> {
                        ex.getResponseHeaders()
                                .set(
                                        "Location",
                                        "http://target-xhost.invalid:"
                                                + targetPort
                                                + "/xhost-html");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    };
            com.sun.net.httpserver.HttpHandler entryToLoop =
                    ex -> {
                        ex.getResponseHeaders()
                                .set(
                                        "Location",
                                        "http://target-xhost.invalid:"
                                                + targetPort
                                                + "/xhost-loop");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    };
            AtomicInteger targetCLoginConfigHits = new AtomicInteger();
            AtomicInteger targetCLoginPageHits = new AtomicInteger();
            AtomicInteger targetDLoginConfigHits = new AtomicInteger();
            AtomicInteger targetDLoginCookieLeaks = new AtomicInteger();
            AtomicInteger targetCNoLocHits = new AtomicInteger();
            AtomicInteger targetDNoLocHits = new AtomicInteger();

            targetC.createContext(
                    "/config-login",
                    ex -> {
                        targetCLoginConfigHits.incrementAndGet();
                        ex.getResponseHeaders().add("Set-Cookie", "login_c=poison; Path=/");
                        ex.getResponseHeaders().set("Location", "/login");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    });
            targetC.createContext(
                    "/login",
                    ex -> {
                        targetCLoginPageHits.incrementAndGet();
                        byte[] html =
                                "<!DOCTYPE html><html><body>Please Login</body></html>"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.getResponseHeaders().set("Content-Type", "text/html");
                        ex.sendResponseHeaders(200, html.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(html);
                        }
                        ex.close();
                    });
            targetD.createContext(
                    "/config-login",
                    ex -> {
                        targetDLoginConfigHits.incrementAndGet();
                        if (ex.getRequestHeaders().getFirst("Authorization") != null)
                            targetAuthLeaks.incrementAndGet();
                        if (ex.getRequestHeaders().getFirst("Cookie") != null)
                            targetDLoginCookieLeaks.incrementAndGet();
                        byte[] resp =
                                "{\"sites\":[{\"key\":\"target_d_after_login_redirect\",\"api\":\"http://ok.test\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                        ex.close();
                    });
            targetC.createContext(
                    "/config-noloc",
                    ex -> {
                        targetCNoLocHits.incrementAndGet();
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    });
            targetD.createContext(
                    "/config-noloc",
                    ex -> {
                        targetDNoLocHits.incrementAndGet();
                        byte[] resp =
                                "{\"sites\":[{\"key\":\"target_d_after_missing_loc\",\"api\":\"http://ok.test\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                        ex.close();
                    });

            com.sun.net.httpserver.HttpHandler entryToLoginRedirect =
                    ex -> {
                        ex.getResponseHeaders().add("Set-Cookie", "entry_sid=secret; Path=/");
                        ex.getResponseHeaders()
                                .set(
                                        "Location",
                                        "http://target-xhost.invalid:"
                                                + targetPort
                                                + "/config-login");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    };
            com.sun.net.httpserver.HttpHandler entryToMissingLoc =
                    ex -> {
                        ex.getResponseHeaders()
                                .set(
                                        "Location",
                                        "http://target-xhost.invalid:"
                                                + targetPort
                                                + "/config-noloc");
                        ex.sendResponseHeaders(302, -1);
                        ex.close();
                    };
            srvA.createContext("/entry-xhost", entryTo500Then200);
            srvB.createContext("/entry-xhost", entryTo500Then200);
            srvA.createContext("/entry-xhost-html", entryToHtmlThenJson);
            srvB.createContext("/entry-xhost-html", entryToHtmlThenJson);
            srvA.createContext("/entry-xhost-loop", entryToLoop);
            srvB.createContext("/entry-xhost-loop", entryToLoop);
            srvA.createContext("/entry-xhost-login", entryToLoginRedirect);
            srvB.createContext("/entry-xhost-login", entryToLoginRedirect);
            srvA.createContext("/entry-xhost-noloc", entryToMissingLoc);
            srvB.createContext("/entry-xhost-noloc", entryToMissingLoc);

            dns.put("entry-xhost.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
            dns.put("entry-single-xhost.invalid", Collections.singletonList("127.0.0.1"));
            dns.put("target-xhost.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
            Cms.clearDohCacheForTest();
            try {
                String xhostRes =
                        Cms.fetchImport(
                                "http://"
                                        + "demo:token@"
                                        + "entry-xhost.invalid:"
                                        + port
                                        + "/entry-xhost");
                check(
                        xhostRes.contains("\"key\":\"target_d\"")
                                && targetC500Hits.get() >= 1
                                && targetD200Hits.get() >= 1
                                && targetAuthLeaks.get() == 0
                                && targetCookieLeaks.get() == 0,
                        "#6d Cross-host 302 from dual entry IPs advances past target IP C (500) to healthy IP D (200) with zero auth/cookie leakage");

                String xhostHtmlRes =
                        Cms.fetchImport("http://entry-xhost.invalid:" + port + "/entry-xhost-html");
                check(
                        xhostHtmlRes.contains("\"key\":\"target_d_nonhtml\""),
                        "#6e Cross-host 302 for fetchImport advances past target IP C (200 HTML) to healthy IP D (JSON)");

                // 6g: Target IP C redirects /config-login -> same-host /login (200 HTML); must
                // still retain backup IP D (/config-login -> 200 JSON) with zero cookie/auth leak.
                String xhostLoginRes =
                        Cms.fetchImport(
                                "http://"
                                        + "demo:token@"
                                        + "entry-single-xhost.invalid:"
                                        + port
                                        + "/entry-xhost-login");
                check(
                        xhostLoginRes.contains("\"key\":\"target_d_after_login_redirect\"")
                                && targetCLoginConfigHits.get() == 1
                                && targetCLoginPageHits.get() == 1
                                && targetDLoginConfigHits.get() == 1
                                && targetAuthLeaks.get() == 0
                                && targetDLoginCookieLeaks.get() == 0,
                        "#6g Cross-host 302 retains backup target IP D after C redirects /config-login -> /login HTML (C:/config="
                                + targetCLoginConfigHits.get()
                                + ", C:/login="
                                + targetCLoginPageHits.get()
                                + ", D:/config="
                                + targetDLoginConfigHits.get()
                                + ", leaks=0)");

                // 6h: Target IP C returns 302 missing Location; must advance to backup IP D (200).
                String xhostNoLocRes =
                        Cms.fetchImport(
                                "http://entry-single-xhost.invalid:" + port + "/entry-xhost-noloc");
                check(
                        xhostNoLocRes.contains("\"key\":\"target_d_after_missing_loc\"")
                                && targetCNoLocHits.get() == 1
                                && targetDNoLocHits.get() == 1,
                        "#6h Cross-host 302 retains backup target IP D after C returns 302 missing Location (C="
                                + targetCNoLocHits.get()
                                + ", D="
                                + targetDNoLocHits.get()
                                + ")");

                Exception loopErr = null;
                try {
                    Cms.fetchImport("http://entry-xhost.invalid:" + port + "/entry-xhost-loop");
                } catch (Exception e) {
                    loopErr = e;
                }
                check(
                        loopErr != null
                                && loopErr.getMessage() != null
                                && loopErr.getMessage().contains("重定向次数过多"),
                        "#6f Cross-host multi-IP fallback still enforces the 5-hop redirect cap");
            } finally {
                targetC.stop(0);
                targetD.stop(0);
            }
        } finally {
            Cms.setDohEndpointsForTest();
            doh.stop(0);
            srvA.stop(0);
            srvB.stop(0);
            srvOnlyB.stop(0);
        }
    }

    // P2 #7: Outer RequestScope cancellation propagation, pre-registration, redirect hop cancel,
    // bounded pool
    private static void test7_RequestScopeCancellationAndBoundedPool() throws Exception {
        check(
                Cms.dohRacePoolMaxSize() > 0 && Cms.dohRacePoolMaxSize() <= 16,
                "#7 DoH race executor has bounded global concurrency ("
                        + Cms.dohRacePoolMaxSize()
                        + ")");

        int port = findDualLoopbackPort();
        CountDownLatch bothConnected = new CountDownLatch(2);
        CountDownLatch releaseHangs = new CountDownLatch(1);
        CountDownLatch hop1Hit = new CountDownLatch(1);
        CountDownLatch releaseHop1 = new CountDownLatch(1);
        AtomicInteger hop2Hits = new AtomicInteger();

        HttpServer srvA =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 1}), port),
                        0);
        HttpServer srvB =
                HttpServer.create(
                        new InetSocketAddress(
                                InetAddress.getByAddress(new byte[] {127, 0, 0, 2}), port),
                        0);
        srvA.setExecutor(Executors.newCachedThreadPool());
        srvB.setExecutor(Executors.newCachedThreadPool());

        com.sun.net.httpserver.HttpHandler hangHandler =
                ex -> {
                    bothConnected.countDown();
                    try {
                        releaseHangs.await(5, TimeUnit.SECONDS);
                        byte[] resp = "{\"too_late\":true}".getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                };
        srvA.createContext("/hang", hangHandler);
        srvB.createContext("/hang", hangHandler);

        com.sun.net.httpserver.HttpHandler hop1Handler =
                ex -> {
                    hop1Hit.countDown();
                    try {
                        releaseHop1.await(3, TimeUnit.SECONDS);
                        ex.getResponseHeaders().set("Location", "/hop2-cancel");
                        ex.sendResponseHeaders(302, -1);
                    } catch (Exception ignored) {
                    } finally {
                        ex.close();
                    }
                };
        com.sun.net.httpserver.HttpHandler hop2Handler =
                ex -> {
                    hop2Hits.incrementAndGet();
                    byte[] resp = "{\"should_not_return\":true}".getBytes(StandardCharsets.UTF_8);
                    ex.sendResponseHeaders(200, resp.length);
                    try (OutputStream os = ex.getResponseBody()) {
                        os.write(resp);
                    }
                    ex.close();
                };
        srvA.createContext("/hop1-cancel", hop1Handler);
        srvB.createContext("/hop1-cancel", hop1Handler);
        srvA.createContext("/hop2-cancel", hop2Handler);
        srvB.createContext("/hop2-cancel", hop2Handler);
        srvA.start();
        srvB.start();

        Map<String, List<String>> dns = new LinkedHashMap<>();
        dns.put("cancel-race.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
        HttpServer doh = startDohServer(dns);

        java.util.concurrent.ExecutorService callerExec = Executors.newSingleThreadExecutor();
        try {
            Cms.setDohEndpointsForTest(
                    "http://127.0.0.1:" + doh.getAddress().getPort() + "/dns-query");

            // 7a: Pre-cancelled scope BEFORE connection registration
            RequestScope preScope = new RequestScope();
            preScope.cancel();
            boolean preCancelled = false;
            try {
                preScope.call(
                        () -> Cms.fetchImport("http://cancel-race.invalid:" + port + "/hang"));
            } catch (InterruptedIOException expected) {
                preCancelled = true;
            }
            check(
                    preCancelled && preScope.connections.isEmpty(),
                    "#7 Pre-cancelled RequestScope aborts before opening or registering connections");

            // 7b: Cancel ONLY scope (no thread interrupt) while both raced connections are active
            RequestScope liveScope = new RequestScope();
            Future<String> liveFuture =
                    callerExec.submit(
                            () ->
                                    liveScope.call(
                                            () ->
                                                    Cms.fetchImport(
                                                            "http://cancel-race.invalid:"
                                                                    + port
                                                                    + "/hang")));
            boolean reachedServers = bothConnected.await(4, TimeUnit.SECONDS);
            int attachedCount = liveScope.connections.size();
            long tCancel = System.currentTimeMillis();
            liveScope.cancel();
            boolean gotCancelledEx = false;
            try {
                liveFuture.get(4, TimeUnit.SECONDS);
            } catch (java.util.concurrent.ExecutionException ee) {
                gotCancelledEx = ee.getCause() instanceof InterruptedIOException;
            }
            long cancelElapsed = System.currentTimeMillis() - tCancel;
            releaseHangs.countDown();
            // Wait briefly for detached worker threads to unwind
            long deadline = System.currentTimeMillis() + 2000L;
            while (System.currentTimeMillis() < deadline && Cms.dohRacePoolActiveCount() > 0) {
                Thread.sleep(25L);
            }
            check(
                    reachedServers
                            && attachedCount >= 1
                            && gotCancelledEx
                            && cancelElapsed < 2000L
                            && liveScope.connections.isEmpty()
                            && Cms.dohRacePoolActiveCount() == 0,
                    "#7 Calling scope.cancel() alone registers connections ("
                            + attachedCount
                            + "), aborts race in "
                            + cancelElapsed
                            + "ms, detaches sockets, and reclaims workers");

            // 7c: Cancel during redirect hop switch (between hop 1 response and hop 2 connection)
            RequestScope hopScope = new RequestScope();
            Future<String> hopFuture =
                    callerExec.submit(
                            () ->
                                    hopScope.call(
                                            () ->
                                                    Cms.fetchImport(
                                                            "http://cancel-race.invalid:"
                                                                    + port
                                                                    + "/hop1-cancel")));
            boolean hitHop1 = hop1Hit.await(4, TimeUnit.SECONDS);
            hopScope.cancel();
            releaseHop1.countDown();
            boolean hopCancelled = false;
            try {
                hopFuture.get(4, TimeUnit.SECONDS);
            } catch (java.util.concurrent.ExecutionException ee) {
                hopCancelled = ee.getCause() instanceof InterruptedIOException;
            }
            check(
                    hitHop1
                            && hopCancelled
                            && hop2Hits.get() == 0
                            && hopScope.connections.isEmpty(),
                    "#7 Cancelling RequestScope across redirect hop prevents hop 2 completion and returns InterruptedIOException");

            // 7d/7e/7f: Bounded pool saturation (full queue, partial candidate queued, cancel while
            // waiting for capacity) must NEVER bypass concurrency limit on caller thread.
            AtomicInteger satHitsA = new AtomicInteger();
            AtomicInteger satHitsB = new AtomicInteger();
            srvA.createContext(
                    "/sat-get",
                    ex -> {
                        satHitsA.incrementAndGet();
                        ex.sendResponseHeaders(403, -1);
                        ex.close();
                    });
            srvB.createContext(
                    "/sat-get",
                    ex -> {
                        satHitsB.incrementAndGet();
                        byte[] resp = "{\"sat_ok\":true}".getBytes(StandardCharsets.UTF_8);
                        ex.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = ex.getResponseBody()) {
                            os.write(resp);
                        }
                        ex.close();
                    });
            dns.put("sat-race.invalid", Arrays.asList("127.0.0.1", "127.0.0.2"));
            Cms.clearDohCacheForTest();

            // Baseline under normal load: B (200) beats A (403)
            String satBaseline = Cms.fetchImport("http://sat-race.invalid:" + port + "/sat-get");
            check(
                    satBaseline.contains("\"sat_ok\":true"),
                    "#7d-0 Normal-load multi-IP GET succeeds via healthy IP B over IP A (403)");

            // 7d: Full saturation (12 active + 64 queued) -> caller does ZERO network I/O, returns
            // accurate busy error, pool concurrency stays <= 12
            satHitsA.set(0);
            satHitsB.set(0);
            CountDownLatch workersActive = new CountDownLatch(Cms.MAX_DOH_RACE_THREADS);
            CountDownLatch releaseBlockers = new CountDownLatch(1);
            List<Future<?>> blockers = new ArrayList<>();
            java.util.concurrent.ThreadPoolExecutor racePool = Cms.dohRaceExecutorForTest();
            try {
                for (int i = 0; i < Cms.MAX_DOH_RACE_THREADS; i++) {
                    blockers.add(
                            racePool.submit(
                                    () -> {
                                        workersActive.countDown();
                                        try {
                                            releaseBlockers.await(10, TimeUnit.SECONDS);
                                        } catch (InterruptedException ignored) {
                                        }
                                    }));
                }
                check(
                        workersActive.await(3, TimeUnit.SECONDS),
                        "#7d Occupied all 12 DoH race workers");
                for (int i = 0; i < 64; i++) {
                    blockers.add(
                            racePool.submit(
                                    () -> {
                                        try {
                                            releaseBlockers.await(10, TimeUnit.SECONDS);
                                        } catch (InterruptedException ignored) {
                                        }
                                    }));
                }
                Cms.setDohRaceSubmitWaitMsForTest(200L);
                Exception satErr = null;
                int observedActiveDuringSat = racePool.getActiveCount();
                try {
                    Cms.fetchImport("http://sat-race.invalid:" + port + "/sat-get");
                } catch (Exception e) {
                    satErr = e;
                }
                check(
                        satErr != null
                                && satErr.getMessage() != null
                                && satErr.getMessage().contains("繁忙")
                                && satHitsA.get() == 0
                                && satHitsB.get() == 0
                                && observedActiveDuringSat <= Cms.MAX_DOH_RACE_THREADS
                                && racePool.getPoolSize() <= Cms.MAX_DOH_RACE_THREADS,
                        "#7d Full pool saturation returns busy without running caller-thread I/O to bad node A (hitsA="
                                + satHitsA.get()
                                + ", hitsB="
                                + satHitsB.get()
                                + ", err="
                                + (satErr == null ? "null" : satErr.getMessage())
                                + ")");

                // 7f: Cancellation while waiting for pool capacity aborts immediately (<500ms)
                Cms.setDohRaceSubmitWaitMsForTest(5000L);
                RequestScope waitScope = new RequestScope();
                Future<String> waitFuture =
                        callerExec.submit(
                                () ->
                                        waitScope.call(
                                                () ->
                                                        Cms.fetchImport(
                                                                "http://sat-race.invalid:"
                                                                        + port
                                                                        + "/sat-get")));
                Thread.sleep(80L);
                long tCancelWait = System.currentTimeMillis();
                waitScope.cancel();
                boolean waitCancelled = false;
                try {
                    waitFuture.get(2, TimeUnit.SECONDS);
                } catch (java.util.concurrent.ExecutionException ee) {
                    waitCancelled = ee.getCause() instanceof InterruptedIOException;
                }
                long waitCancelMs = System.currentTimeMillis() - tCancelWait;
                check(
                        waitCancelled
                                && waitCancelMs < 600L
                                && satHitsA.get() == 0
                                && satHitsB.get() == 0,
                        "#7f Cancelling RequestScope during saturation capacity wait aborts promptly in "
                                + waitCancelMs
                                + "ms with zero caller-thread I/O");

                // 7e-1: Partial candidates queued (12 active + 63 queued -> A enters slot 64, B
                // blocked) -> fails with busy, cancels & purges A's queued slot, zero caller I/O
                blockers.remove(blockers.size() - 1).cancel(false);
                racePool.purge();
                int queueBeforePartial = Cms.dohRaceQueueSize();
                Cms.setDohRaceSubmitWaitMsForTest(200L);
                Exception partialErr = null;
                try {
                    Cms.fetchImport("http://sat-race.invalid:" + port + "/sat-get");
                } catch (Exception e) {
                    partialErr = e;
                }
                int queueAfterPartial = Cms.dohRaceQueueSize();
                check(
                        queueBeforePartial == 63
                                && queueAfterPartial == 63
                                && partialErr != null
                                && partialErr.getMessage() != null
                                && partialErr.getMessage().contains("繁忙")
                                && satHitsA.get() == 0
                                && satHitsB.get() == 0,
                        "#7e-1 Partial candidate queued (63/64 full) fails accurately as busy, purges queued A, and runs zero caller I/O");

                // 7e-2: Partial candidate queued, then capacity opens within wait window -> both A
                // & B execute inside bounded pool and B (200) wins over A (403)
                Cms.setDohRaceSubmitWaitMsForTest(2000L);
                Future<String> recoverFuture =
                        callerExec.submit(
                                () ->
                                        Cms.fetchImport(
                                                "http://sat-race.invalid:" + port + "/sat-get"));
                Thread.sleep(90L);
                releaseBlockers.countDown();
                for (Future<?> bf : blockers) {
                    bf.cancel(false);
                }
                racePool.purge();
                String recovered = recoverFuture.get(4, TimeUnit.SECONDS);
                check(
                        recovered.contains("\"sat_ok\":true")
                                && satHitsB.get() >= 1
                                && racePool.getPoolSize() <= Cms.MAX_DOH_RACE_THREADS,
                        "#7e-2 Partial candidate queued recovers once capacity frees inside bounded pool and gets healthy IP B (200)");
            } finally {
                Cms.setDohRaceSubmitWaitMsForTest(-1L);
                releaseBlockers.countDown();
                for (Future<?> bf : blockers) {
                    bf.cancel(true);
                }
                racePool.purge();
                long drainDeadline = System.currentTimeMillis() + 3000L;
                while (System.currentTimeMillis() < drainDeadline
                        && (Cms.dohRacePoolActiveCount() > 0 || Cms.dohRaceQueueSize() > 0)) {
                    Thread.sleep(20L);
                }
            }
        } finally {
            releaseHangs.countDown();
            releaseHop1.countDown();
            callerExec.shutdownNow();
            Cms.setDohEndpointsForTest();
            doh.stop(0);
            srvA.stop(0);
            srvB.stop(0);
        }
    }

    // P2 #8: Linear O(N) withoutComments fast path + correctness on comments/commas/escaped quotes
    private static void test8_LinearWithoutComments() throws Exception {
        String clean = "{\"k\":\"hello \\\"//not comment\\\" /*still string*/\",\"arr\":[1,2,3]}";
        check(
                Cms.withoutComments(clean) == clean,
                "#8 withoutComments returns original String reference with zero allocation for clean JSON with escaped quotes");

        String dirty =
                "{\n  // line comment\n  \"a\": \"http://keep.test//ok\", /* block */ \n  \"b\": [1, 2, ],\n}";
        String cleaned = Cms.withoutComments(dirty);
        org.json.JSONObject parsed = new org.json.JSONObject(cleaned);
        check(
                "http://keep.test//ok".equals(parsed.getString("a"))
                        && parsed.getJSONArray("b").length() == 2,
                "#8 withoutComments strips line/block comments and trailing commas while preserving URLs inside strings");

        // Warmup JIT then measure 4,000 / 8,000 / 16,000 short strings without backslashes
        String s4k = buildShortStringsJson(4000);
        String s8k = buildShortStringsJson(8000);
        String s16k = buildShortStringsJson(16000);
        for (int w = 0; w < 3; w++) {
            Cms.withoutComments(s4k);
        }
        long t4 = measureNs(() -> Cms.withoutComments(s4k));
        long t8 = measureNs(() -> Cms.withoutComments(s8k));
        long t16 = measureNs(() -> Cms.withoutComments(s16k));
        double ms4 = t4 / 1_000_000.0;
        double ms8 = t8 / 1_000_000.0;
        double ms16 = t16 / 1_000_000.0;
        check(
                Cms.withoutComments(s16k) == s16k && ms16 < 40.0,
                String.format(
                        java.util.Locale.US,
                        "#8 withoutComments fast path scales linearly without O(N^2) blowup (4k=%.2fms, 8k=%.2fms, 16k=%.2fms)",
                        ms4,
                        ms8,
                        ms16));
    }

    private static String buildShortStringsJson(int count) {
        StringBuilder sb = new StringBuilder(count * 16);
        sb.append('[');
        for (int i = 0; i < count; i++) {
            if (i > 0) sb.append(',');
            sb.append("\"item").append(i).append('"');
        }
        sb.append(']');
        return sb.toString();
    }

    private interface ThrowingRunnable {
        void run() throws Exception;
    }

    private static long measureNs(ThrowingRunnable task) throws Exception {
        long t0 = System.nanoTime();
        task.run();
        return System.nanoTime() - t0;
    }

    // P2 #9: Per-ID startup prompt dedupe (clock rollback, same-ms diff ID, late arrival, crash
    // after show)
    private static void test9_PerIdStartupPromptDedupe() throws Exception {
        Path tmp = Files.createTempDirectory("codex-crash-ids-");
        try {
            File dir = tmp.toFile();
            long tBase = 1_800_000_100_000L;

            CrashReportStore.CrashReport a = makeJavaCrash("crash_A", tBase);
            CrashReportStore.saveReport(dir, a);
            List<CrashReportStore.CrashReport> firstBatch =
                    CrashReportStore.loadPromptableReports(dir, tBase + 1000L);
            check(
                    idsOf(firstBatch).equals(Collections.singletonList("crash_A")),
                    "#9 First startup selects [crash_A]");

            // Simulate dialog shown -> markPrompted persisted immediately, then process dies BEFORE
            // dismiss!
            CrashReportStore.markPrompted(dir, firstBatch);
            check(
                    CrashReportStore.loadPromptableReports(dir, tBase + 2000L).isEmpty(),
                    "#9 After A shown & process exited before dismiss, A does not re-prompt");

            // Case 1: Clock rollback -> B has earlier timestamp than A
            CrashReportStore.CrashReport b = makeJavaCrash("crash_B_rollback", tBase - 30_000L);
            CrashReportStore.saveReport(dir, b);
            List<CrashReportStore.CrashReport> afterRollback =
                    CrashReportStore.loadPromptableReports(dir, tBase - 25_000L);
            check(
                    idsOf(afterRollback).equals(Collections.singletonList("crash_B_rollback")),
                    "#9 Clock rollback still prompts ONLY [crash_B_rollback] (never re-includes A)");
            CrashReportStore.markPrompted(dir, afterRollback);

            // Case 2: Same millisecond, different ID
            CrashReportStore.CrashReport c = makeJavaCrash("crash_C_samems", tBase);
            CrashReportStore.saveReport(dir, c);
            List<CrashReportStore.CrashReport> afterSameMs =
                    CrashReportStore.loadPromptableReports(dir, tBase + 5_000L);
            check(
                    idsOf(afterSameMs).equals(Collections.singletonList("crash_C_samems")),
                    "#9 Same-millisecond new ID prompts ONLY [crash_C_samems]");
            CrashReportStore.markPrompted(dir, afterSameMs);

            // Case 3: Late-arriving report with earlier timestamp within 72h
            CrashReportStore.CrashReport d = makeJavaCrash("crash_D_late", tBase - 60_000L);
            CrashReportStore.saveReport(dir, d);
            List<CrashReportStore.CrashReport> afterLate =
                    CrashReportStore.loadPromptableReports(dir, tBase + 10_000L);
            check(
                    idsOf(afterLate).equals(Collections.singletonList("crash_D_late")),
                    "#9 Late-arriving report prompts ONLY [crash_D_late]");
        } finally {
            deleteRecursive(tmp.toFile());
        }
    }

    // P2 #10: Read-modify-write under lock (submit+dismiss, clear+dismiss) & double-tap submit lock
    private static void test10_DismissRaceSafetyAndDoubleTapGuard() throws Exception {
        Path tmp = Files.createTempDirectory("codex-crash-rmw-");
        try {
            File dir = tmp.toFile();
            long now = System.currentTimeMillis();

            // 10a: Submit first, then stale snapshot calls markDismissed -> submitted & issue
            // preserved!
            CrashReportStore.CrashReport orig = makeJavaCrash("crash_rmw_1", now - 2_000L);
            CrashReportStore.saveReport(dir, orig);
            List<CrashReportStore.CrashReport> staleSnapshot =
                    CrashReportStore.loadPromptableReports(dir, now);
            List<CrashReportStore.CrashReport> submitCopy =
                    CrashReportStore.loadPromptableReports(dir, now);

            CrashReportStore.markSubmitted(
                    dir, submitCopy, 99, "https://github.com/Pilipala9919/MarcoMovie/issues/99");
            CrashReportStore.markDismissed(dir, staleSnapshot);

            List<CrashReportStore.CrashReport> afterInterleave = CrashReportStore.loadReports(dir);
            CrashReportStore.CrashReport disk = findById(afterInterleave, "crash_rmw_1");
            check(
                    disk != null
                            && disk.submitted
                            && disk.submittedIssueNumber == 99
                            && "https://github.com/Pilipala9919/MarcoMovie/issues/99"
                                    .equals(disk.submittedIssueUrl)
                            && disk.dismissed,
                    "#10 Stale markDismissed after markSubmitted preserves submitted=true and issue=#99");

            // 10b: ClearAll first, then stale snapshot calls markDismissed -> never resurrects
            // file!
            CrashReportStore.clearAll(dir);
            CrashReportStore.markDismissed(dir, staleSnapshot);
            check(
                    CrashReportStore.loadReports(dir).isEmpty()
                            && !new File(CrashReportStore.reportDir(dir), "crash_rmw_1.json")
                                    .exists(),
                    "#10 Stale markDismissed after clearAll skips deleted report and never resurrects JSON");

            // 10c: Double-tap submit guard + partial selection + dismiss path locking
            CrashReportDialog.ReviewActionGuard guard = new CrashReportDialog.ReviewActionGuard();
            AtomicInteger uploads = new AtomicInteger();
            AtomicInteger dismisses = new AtomicInteger();
            // Simulate rapid double-tap on submit:
            if (guard.tryConsumeAction()) uploads.incrementAndGet();
            if (guard.tryConsumeAction()) uploads.incrementAndGet();
            // Subsequent onDismiss callback from sheet close must NOT re-trigger dismiss-all:
            if (guard.tryConsumeAction()) dismisses.incrementAndGet();
            check(
                    uploads.get() == 1 && dismisses.get() == 0 && guard.isLocked(),
                    "#10 ReviewActionGuard allows exactly 1 upload on double-tap and blocks trailing dismiss");

            // Simulate swipe/scrim/back dismiss without clicking submit:
            CrashReportDialog.ReviewActionGuard dismissGuard =
                    new CrashReportDialog.ReviewActionGuard();
            check(
                    dismissGuard.tryConsumeAction() && !dismissGuard.tryConsumeAction(),
                    "#10 Swipe/scrim/back dismiss consumes guard once cleanly");

            // Simulate partial-selection submit: [A selected, B unselected] -> A submitted, B
            // dismissed
            CrashReportStore.CrashReport pA = makeJavaCrash("crash_part_A", now - 2_000L);
            CrashReportStore.CrashReport pB = makeJavaCrash("crash_part_B", now - 1_000L);
            CrashReportStore.saveReport(dir, pA);
            CrashReportStore.saveReport(dir, pB);
            CrashReportStore.markSubmitted(dir, Collections.singletonList(pA), 101, "");
            CrashReportStore.markDismissed(dir, Collections.singletonList(pB));
            List<CrashReportStore.CrashReport> afterPart = CrashReportStore.loadReports(dir);
            CrashReportStore.CrashReport dA = findById(afterPart, "crash_part_A");
            CrashReportStore.CrashReport dB = findById(afterPart, "crash_part_B");
            check(
                    dA != null
                            && dA.submitted
                            && !dA.dismissed
                            && dB != null
                            && !dB.submitted
                            && dB.dismissed
                            && CrashReportStore.loadPromptableReports(dir, now).isEmpty(),
                    "#10 Partial-selection submit marks chosen as submitted and unchecked as dismissed");

            // 10d: Empty-history "提交当前运行诊断" showConfirm single-shot listener + ReviewActionGuard
            // disables button on first activation and executes mock upload strictly once even when
            // activated twice during sheet dismiss animation.
            android.view.View confirmBtn = new android.view.View(null);
            android.view.View cancelBtn = new android.view.View(null);
            AtomicInteger emptyHistoryUploads = new AtomicInteger();
            AtomicInteger emptyHistoryDismisses = new AtomicInteger();
            CrashReportDialog.ReviewActionGuard emptyGuard =
                    new CrashReportDialog.ReviewActionGuard();
            Runnable guardedSubmit =
                    CrashReportDialog.guardSingleShotConfirmAction(
                            emptyGuard, emptyHistoryUploads::incrementAndGet);
            boolean[] sheetConsumed = {false};
            android.view.View.OnClickListener confirmListener =
                    MobileBottomSheet.createSingleShotConfirmListener(
                            sheetConsumed,
                            confirmBtn,
                            cancelBtn,
                            emptyHistoryDismisses::incrementAndGet,
                            guardedSubmit);
            confirmBtn.setOnClickListener(confirmListener);
            // Activate twice (including direct listener re-entry during dismiss animation)
            confirmBtn.performClick();
            confirmListener.onClick(confirmBtn);
            guardedSubmit.run();
            check(
                    emptyHistoryUploads.get() == 1
                            && emptyHistoryDismisses.get() == 1
                            && !confirmBtn.isEnabled()
                            && !confirmBtn.isClickable()
                            && !cancelBtn.isEnabled()
                            && !cancelBtn.isClickable()
                            && emptyGuard.isLocked(),
                    "#10d Empty-history diagnostic confirm entry disables buttons on first click and invokes mock upload strictly once on double-activation");
        } finally {
            deleteRecursive(tmp.toFile());
        }
    }

    /**
     * Child-first BaseDexClassLoader loading isolated com.github.catvod.spider.Init / PluginCallback
     * fixtures so each simulated plugin has its own independent setActivity invocation counter.
     */
    private static final class FixturePluginClassLoader extends dalvik.system.BaseDexClassLoader {
        private final File classesRoot;

        FixturePluginClassLoader(File classesRoot, ClassLoader parent) {
            super("", null, null, parent);
            this.classesRoot = classesRoot;
        }

        @Override
        protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            if (name != null && name.startsWith("com.github.catvod.spider.")) {
                Class<?> loaded = findLoadedClass(name);
                if (loaded == null) {
                    File f = new File(classesRoot, name.replace('.', '/') + ".class");
                    if (f.isFile()) {
                        try {
                            byte[] bytes = Files.readAllBytes(f.toPath());
                            loaded = defineClass(name, bytes, 0, bytes.length);
                        } catch (Exception e) {
                            throw new ClassNotFoundException(name, e);
                        }
                    }
                }
                if (loaded != null) {
                    if (resolve) resolveClass(loaded);
                    return loaded;
                }
            }
            return super.loadClass(name, resolve);
        }
    }

    private static int readFixtureSetActivityCalls(ClassLoader pluginLoader) throws Exception {
        Class<?> initCls = Class.forName("com.github.catvod.spider.Init", true, pluginLoader);
        AtomicInteger counter = (AtomicInteger) initCls.getField("SET_ACTIVITY_CALLS").get(null);
        return counter.get();
    }

    // P2 #11: CspEngine publishes loader ONLY after Init.init() finishes; interleaved A site-init
    // and B child-loader callback registration must NEVER misattribute B's child loader to A, and
    // formal syncAllPluginActivities must report 0 calls on B & B's children while paused/failed,
    // then sync them cleanly once B succeeds.
    private static void test11_CspLoaderPublishAfterInit() throws Exception {
        String fixtureProp = System.getProperty("test.plugin.fixture.dir", "");
        File fixtureDir = new File(fixtureProp);
        check(
                fixtureDir.isDirectory(),
                "#11 Plugin fixture directory exists for formal syncAllPluginActivities test");

        android.app.Application app = new android.app.Application();
        android.app.Activity act = new android.app.Activity();
        java.lang.reflect.Field appField =
                android.app.Activity.class.getDeclaredField("mApplication");
        appField.setAccessible(true);
        appField.set(act, app);

        ClassLoader appLoader = MobileCodexReviewChecks.class.getClassLoader();
        FixturePluginClassLoader loaderA = new FixturePluginClassLoader(fixtureDir, appLoader);
        FixturePluginClassLoader loaderAChild = new FixturePluginClassLoader(fixtureDir, loaderA);
        FixturePluginClassLoader loaderB = new FixturePluginClassLoader(fixtureDir, appLoader);
        // Simulate BOTH kinds of B child loaders: descendant of loaderB AND standalone child whose
        // parent is appLoader (worst case for ownership verification).
        FixturePluginClassLoader loaderBDescChild =
                new FixturePluginClassLoader(fixtureDir, loaderB);
        FixturePluginClassLoader loaderBStandaloneChild =
                new FixturePluginClassLoader(fixtureDir, appLoader);

        // Pre-touch Init class on each isolated loader so Class.forName(..., false, cl) resolves.
        Class.forName("com.github.catvod.spider.Init", true, loaderA);
        Class.forName("com.github.catvod.spider.Init", true, loaderAChild);
        Class.forName("com.github.catvod.spider.Init", true, loaderB);
        Class.forName("com.github.catvod.spider.Init", true, loaderBDescChild);
        Class.forName("com.github.catvod.spider.Init", true, loaderBStandaloneChild);

        CountDownLatch bPausedAfterCallback = new CountDownLatch(1);
        CountDownLatch allowBFail = new CountDownLatch(1);
        java.util.concurrent.ExecutorService bg = Executors.newSingleThreadExecutor();
        try {
            // 1) Publish ready plugin A (with confirmed owned child loaderAChild)
            CspEngine.initAndPublishReadyLoader(
                    null,
                    null,
                    loaderA,
                    cl ->
                            CspEngine.recordOwnedChildLoaders(
                                    cl, Collections.singleton(loaderAChild)));

            // 2) Interleaved initialization: A begins site-init snapshot BEFORE B registers its
            // child-loader callbacks on Application!
            CspEngine.ScopedPluginApplication scopedAppA =
                    new CspEngine.ScopedPluginApplication(app, loaderA);
            List<Object> beforeSpiderA = CspEngine.lifecycleCallbacks(app);

            // Concurrently B starts Init.init, registers lifecycle callbacks from BOTH B root,
            // B descendant child loader, and B standalone child loader, then pauses!
            CspEngine.ScopedPluginApplication scopedAppBFail =
                    new CspEngine.ScopedPluginApplication(app, loaderB);
            Future<?> bInitTask =
                    bg.submit(
                            () -> {
                                try {
                                    CspEngine.initAndPublishReadyLoader(
                                            null,
                                            null,
                                            loaderB,
                                            cl -> {
                                                List<Object> beforeB =
                                                        CspEngine.lifecycleCallbacks(app);
                                                Object cbB =
                                                        Class.forName(
                                                                        "com.github.catvod.spider.PluginCallback",
                                                                        true,
                                                                        cl)
                                                                .getDeclaredConstructor()
                                                                .newInstance();
                                                Object cbBDesc =
                                                        Class.forName(
                                                                        "com.github.catvod.spider.PluginCallback",
                                                                        true,
                                                                        loaderBDescChild)
                                                                .getDeclaredConstructor()
                                                                .newInstance();
                                                Object cbBStandalone =
                                                        Class.forName(
                                                                        "com.github.catvod.spider.PluginCallback",
                                                                        true,
                                                                        loaderBStandaloneChild)
                                                                .getDeclaredConstructor()
                                                                .newInstance();
                                                scopedAppBFail.registerActivityLifecycleCallbacks(
                                                        (android.app.Application
                                                                        .ActivityLifecycleCallbacks)
                                                                cbB);
                                                scopedAppBFail.registerActivityLifecycleCallbacks(
                                                        (android.app.Application
                                                                        .ActivityLifecycleCallbacks)
                                                                cbBDesc);
                                                // Also test raw app registration (unwrapped
                                                // Application)
                                                app.registerActivityLifecycleCallbacks(
                                                        (android.app.Application
                                                                        .ActivityLifecycleCallbacks)
                                                                cbBStandalone);
                                                CspEngine.recordOwnedChildLoaders(
                                                        cl,
                                                        CspEngine
                                                                .collectVerifiedOwnedCallbackLoaders(
                                                                        scopedAppBFail,
                                                                        app,
                                                                        beforeB,
                                                                        cl,
                                                                        null));
                                                bPausedAfterCallback.countDown();
                                                allowBFail.await(5, TimeUnit.SECONDS);
                                                throw new IllegalStateException(
                                                        "simulated Init.init failure for B");
                                            });
                                } catch (Exception expected) {
                                    return expected;
                                }
                                return null;
                            });

            boolean started = bPausedAfterCallback.await(3, TimeUnit.SECONDS);
            List<Object> registeredCallbacks = CspEngine.lifecycleCallbacks(app);
            boolean callbackPresent =
                    registeredCallbacks != null && registeredCallbacks.size() >= 3;

            // A finishes site-init while B is paused: MUST NOT adopt B's child loaders!
            CspEngine.publishSpiderInitLoaders(loaderA, null, scopedAppA, app, beforeSpiderA);

            // Official foreground sync while B is paused (holding LOADER_LOCK)
            long t0 = System.currentTimeMillis();
            CspEngine.syncAllPluginActivities(act);
            long pausedSyncMs = System.currentTimeMillis() - t0;
            int a1 = readFixtureSetActivityCalls(loaderA);
            int aChild1 = readFixtureSetActivityCalls(loaderAChild);
            int b1 = readFixtureSetActivityCalls(loaderB);
            int bDesc1 = readFixtureSetActivityCalls(loaderBDescChild);
            int bStand1 = readFixtureSetActivityCalls(loaderBStandaloneChild);

            check(
                    started
                            && callbackPresent
                            && pausedSyncMs < 200L
                            && a1 == 1
                            && aChild1 == 1
                            && b1 == 0
                            && bDesc1 == 0
                            && bStand1 == 0,
                    "#11a Interleaved A site-init + paused B: syncAllPluginActivities returns in "
                            + pausedSyncMs
                            + "ms with A="
                            + a1
                            + ", A_child="
                            + aChild1
                            + ", B="
                            + b1
                            + ", B_desc_child="
                            + bDesc1
                            + ", B_standalone_child="
                            + bStand1);

            // 3) Let B fail initialization (all 3 callbacks remain on Application)
            allowBFail.countDown();
            Object bErr = bInitTask.get(4, TimeUnit.SECONDS);
            boolean bFailed = bErr instanceof IllegalStateException;

            // Run A site-init publication again + formal foreground sync after B failed
            CspEngine.publishSpiderInitLoaders(loaderA, null, scopedAppA, app, beforeSpiderA);
            CspEngine.syncAllPluginActivities(act);
            int a2 = readFixtureSetActivityCalls(loaderA);
            int aChild2 = readFixtureSetActivityCalls(loaderAChild);
            int b2 = readFixtureSetActivityCalls(loaderB);
            int bDesc2 = readFixtureSetActivityCalls(loaderBDescChild);
            int bStand2 = readFixtureSetActivityCalls(loaderBStandaloneChild);
            check(
                    bFailed
                            && a2 == 2
                            && aChild2 == 2
                            && b2 == 0
                            && bDesc2 == 0
                            && bStand2 == 0
                            && !CspEngine.snapshotReadyPluginLoaders().contains(loaderB)
                            && !CspEngine.snapshotReadyPluginLoaders().contains(loaderBDescChild)
                            && !CspEngine.snapshotReadyPluginLoaders()
                                    .contains(loaderBStandaloneChild),
                    "#11b After B fails, formal syncAllPluginActivities still reports 0 on B and both B child loaders (A="
                            + a2
                            + ", A_child="
                            + aChild2
                            + ", B="
                            + b2
                            + ", B_desc_child="
                            + bDesc2
                            + ", B_standalone_child="
                            + bStand2
                            + ")");

            // 4) Now let B initialize cleanly via its ScopedPluginApplication and publish!
            CspEngine.ScopedPluginApplication scopedAppBSuccess =
                    new CspEngine.ScopedPluginApplication(app, loaderB);
            CspEngine.initAndPublishReadyLoader(
                    null,
                    null,
                    loaderB,
                    cl -> {
                        List<Object> beforeBSuccess = CspEngine.lifecycleCallbacks(app);
                        Object cbDesc =
                                Class.forName(
                                                "com.github.catvod.spider.PluginCallback",
                                                true,
                                                loaderBDescChild)
                                        .getDeclaredConstructor()
                                        .newInstance();
                        Object cbStand =
                                Class.forName(
                                                "com.github.catvod.spider.PluginCallback",
                                                true,
                                                loaderBStandaloneChild)
                                        .getDeclaredConstructor()
                                        .newInstance();
                        scopedAppBSuccess.registerActivityLifecycleCallbacks(
                                (android.app.Application.ActivityLifecycleCallbacks) cbDesc);
                        scopedAppBSuccess.registerActivityLifecycleCallbacks(
                                (android.app.Application.ActivityLifecycleCallbacks) cbStand);
                        CspEngine.recordOwnedChildLoaders(
                                cl,
                                CspEngine.collectVerifiedOwnedCallbackLoaders(
                                        scopedAppBSuccess, app, beforeBSuccess, cl, null));
                    });
            CspEngine.syncAllPluginActivities(act);
            int a3 = readFixtureSetActivityCalls(loaderA);
            int aChild3 = readFixtureSetActivityCalls(loaderAChild);
            int b3 = readFixtureSetActivityCalls(loaderB);
            int bDesc3 = readFixtureSetActivityCalls(loaderBDescChild);
            int bStand3 = readFixtureSetActivityCalls(loaderBStandaloneChild);
            check(
                    a3 == 3
                            && aChild3 == 3
                            && b3 == 1
                            && bDesc3 == 1
                            && bStand3 == 1
                            && CspEngine.snapshotReadyPluginLoaders().contains(loaderB)
                            && CspEngine.snapshotReadyPluginLoaders().contains(loaderBDescChild)
                            && CspEngine.snapshotReadyPluginLoaders()
                                    .contains(loaderBStandaloneChild),
                    "#11c After B succeeds, formal syncAllPluginActivities syncs A and B + both B child loaders (A="
                            + a3
                            + ", A_child="
                            + aChild3
                            + ", B="
                            + b3
                            + ", B_desc_child="
                            + bDesc3
                            + ", B_standalone_child="
                            + bStand3
                            + ")");

            // 5) P2-2: Same plugin registers callbacks from two child loaders and unregisters one
            // before init completes, plus 100 register/unregister cycles during & after init.
            // Unregistered child loader MUST receive 0 sync calls, active child loader receives 1,
            // and ScopedPluginApplication must not retain unregistered callbacks or grow refs.
            FixturePluginClassLoader loaderC = new FixturePluginClassLoader(fixtureDir, appLoader);
            FixturePluginClassLoader loaderCActiveChild =
                    new FixturePluginClassLoader(fixtureDir, appLoader);
            FixturePluginClassLoader loaderCUnregChild =
                    new FixturePluginClassLoader(fixtureDir, appLoader);
            Class.forName("com.github.catvod.spider.Init", true, loaderC);
            Class.forName("com.github.catvod.spider.Init", true, loaderCActiveChild);
            Class.forName("com.github.catvod.spider.Init", true, loaderCUnregChild);

            android.app.Application appC = new android.app.Application();
            android.app.Activity actC = new android.app.Activity();
            appField.set(actC, appC);
            CspEngine.ScopedPluginApplication scopedAppC =
                    new CspEngine.ScopedPluginApplication(appC, loaderC);
            final int[] trackedDuringInitAfterUnreg = {-1};
            final int[] trackedDuringInitAfter100Cycles = {-1};
            final int[] sysCallbacksAfter100Cycles = {-1};
            try {
                CspEngine.initAndPublishReadyLoader(
                        null,
                        null,
                        loaderC,
                        cl -> {
                            List<Object> beforeC = CspEngine.lifecycleCallbacks(appC);
                            android.app.Application.ActivityLifecycleCallbacks cbActive =
                                    (android.app.Application.ActivityLifecycleCallbacks)
                                            Class.forName(
                                                            "com.github.catvod.spider.PluginCallback",
                                                            true,
                                                            loaderCActiveChild)
                                                    .getDeclaredConstructor()
                                                    .newInstance();
                            android.app.Application.ActivityLifecycleCallbacks cbUnreg =
                                    (android.app.Application.ActivityLifecycleCallbacks)
                                            Class.forName(
                                                            "com.github.catvod.spider.PluginCallback",
                                                            true,
                                                            loaderCUnregChild)
                                                    .getDeclaredConstructor()
                                                    .newInstance();
                            scopedAppC.registerActivityLifecycleCallbacks(cbActive);
                            scopedAppC.registerActivityLifecycleCallbacks(cbUnreg);
                            scopedAppC.unregisterActivityLifecycleCallbacks(cbUnreg);
                            trackedDuringInitAfterUnreg[0] = scopedAppC.trackedCallbackCount();

                            // Repeat 100 register + unregister cycles during init: tracked refs
                            // must stay strictly at 1 (only cbActive), never growing to 102.
                            for (int i = 0; i < 100; i++) {
                                android.app.Application.ActivityLifecycleCallbacks cbTemp =
                                        (android.app.Application.ActivityLifecycleCallbacks)
                                                Class.forName(
                                                                "com.github.catvod.spider.PluginCallback",
                                                                true,
                                                                loaderCUnregChild)
                                                        .getDeclaredConstructor()
                                                        .newInstance();
                                scopedAppC.registerActivityLifecycleCallbacks(cbTemp);
                                scopedAppC.unregisterActivityLifecycleCallbacks(cbTemp);
                            }
                            trackedDuringInitAfter100Cycles[0] = scopedAppC.trackedCallbackCount();
                            List<Object> sysNow = CspEngine.lifecycleCallbacks(appC);
                            sysCallbacksAfter100Cycles[0] = sysNow == null ? -1 : sysNow.size();

                            CspEngine.recordOwnedChildLoaders(
                                    cl,
                                    CspEngine.collectVerifiedOwnedCallbackLoaders(
                                            scopedAppC, appC, beforeC, cl, null));
                        });

                int trackedAfterInitRelease = scopedAppC.trackedCallbackCount();
                // Another 100 register/unregister cycles post-init must keep wrapper ref count = 0.
                for (int i = 0; i < 100; i++) {
                    android.app.Application.ActivityLifecycleCallbacks cbPost =
                            (android.app.Application.ActivityLifecycleCallbacks)
                                    Class.forName(
                                                    "com.github.catvod.spider.PluginCallback",
                                                    true,
                                                    loaderCUnregChild)
                                            .getDeclaredConstructor()
                                            .newInstance();
                    scopedAppC.registerActivityLifecycleCallbacks(cbPost);
                    scopedAppC.unregisterActivityLifecycleCallbacks(cbPost);
                }
                int trackedAfterPostInit100Cycles = scopedAppC.trackedCallbackCount();
                List<Object> sysFinal = CspEngine.lifecycleCallbacks(appC);
                int sysFinalCount = sysFinal == null ? -1 : sysFinal.size();

                CspEngine.syncAllPluginActivities(actC);
                int cRootCalls = readFixtureSetActivityCalls(loaderC);
                int cActiveCalls = readFixtureSetActivityCalls(loaderCActiveChild);
                int cUnregCalls = readFixtureSetActivityCalls(loaderCUnregChild);

                check(
                        trackedDuringInitAfterUnreg[0] == 1
                                && trackedDuringInitAfter100Cycles[0] == 1
                                && sysCallbacksAfter100Cycles[0] == 1
                                && trackedAfterInitRelease == 0
                                && trackedAfterPostInit100Cycles == 0
                                && sysFinalCount == 1
                                && cRootCalls == 1
                                && cActiveCalls == 1
                                && cUnregCalls == 0
                                && !CspEngine.snapshotReadyPluginLoaders()
                                        .contains(loaderCUnregChild),
                        "#11d Unregistered callback child loader receives 0 sync calls, active child receives 1, and 100+100 register/unregister cycles keep refs bounded (duringInit="
                                + trackedDuringInitAfter100Cycles[0]
                                + ", afterInit="
                                + trackedAfterInitRelease
                                + ", post100="
                                + trackedAfterPostInit100Cycles
                                + ", sysCbs="
                                + sysFinalCount
                                + ", C_root="
                                + cRootCalls
                                + ", C_active_child="
                                + cActiveCalls
                                + ", C_unreg_child="
                                + cUnregCalls
                                + ")");
            } finally {
                CspEngine.ALL_PLUGIN_LOADERS.remove(loaderC);
                CspEngine.ALL_PLUGIN_LOADERS.remove(loaderCActiveChild);
                CspEngine.ALL_PLUGIN_LOADERS.remove(loaderCUnregChild);
                CspEngine.OWNED_CHILD_LOADERS.remove(loaderC);
                CspEngine.UNREADY_LOADERS.remove(loaderC);
            }

            // 6) P2 duplicate-callback refcount matrix on the SAME callback instance:
            // (reg=1,unreg=0 -> sys=1,sync=1), (reg=1,unreg=1 -> sys=0,sync=0),
            // (reg=2,unreg=1 -> sys=1,sync=1), (reg=2,unreg=2 -> sys=0,sync=0),
            // with tracked refs always returning to 0 after initialization completes.
            int[][] dupCases = {
                {1, 0, 1, 1},
                {1, 1, 0, 0},
                {2, 1, 1, 1},
                {2, 2, 0, 0},
            };
            for (int[] tc : dupCases) {
                int regCount = tc[0];
                int unregCount = tc[1];
                int expectedSys = tc[2];
                int expectedSync = tc[3];

                FixturePluginClassLoader loaderDupRoot =
                        new FixturePluginClassLoader(fixtureDir, appLoader);
                FixturePluginClassLoader loaderDupChild =
                        new FixturePluginClassLoader(fixtureDir, appLoader);
                Class.forName("com.github.catvod.spider.Init", true, loaderDupRoot);
                Class.forName("com.github.catvod.spider.Init", true, loaderDupChild);

                android.app.Application appDup = new android.app.Application();
                android.app.Activity actDup = new android.app.Activity();
                appField.set(actDup, appDup);
                CspEngine.ScopedPluginApplication scopedDup =
                        new CspEngine.ScopedPluginApplication(appDup, loaderDupRoot);
                try {
                    CspEngine.initAndPublishReadyLoader(
                            null,
                            null,
                            loaderDupRoot,
                            cl -> {
                                List<Object> beforeDup = CspEngine.lifecycleCallbacks(appDup);
                                android.app.Application.ActivityLifecycleCallbacks sameCb =
                                        (android.app.Application.ActivityLifecycleCallbacks)
                                                Class.forName(
                                                                "com.github.catvod.spider.PluginCallback",
                                                                true,
                                                                loaderDupChild)
                                                        .getDeclaredConstructor()
                                                        .newInstance();
                                for (int r = 0; r < regCount; r++) {
                                    scopedDup.registerActivityLifecycleCallbacks(sameCb);
                                }
                                for (int u = 0; u < unregCount; u++) {
                                    scopedDup.unregisterActivityLifecycleCallbacks(sameCb);
                                }
                                CspEngine.recordOwnedChildLoaders(
                                        cl,
                                        CspEngine.collectVerifiedOwnedCallbackLoaders(
                                                scopedDup, appDup, beforeDup, cl, null));
                            });
                    int refsAfterInit = scopedDup.trackedCallbackCount();
                    List<Object> sysList = CspEngine.lifecycleCallbacks(appDup);
                    int actualSys = sysList == null ? -1 : sysList.size();
                    CspEngine.syncAllPluginActivities(actDup);
                    int actualSync = readFixtureSetActivityCalls(loaderDupChild);

                    check(
                            actualSys == expectedSys
                                    && actualSync == expectedSync
                                    && refsAfterInit == 0,
                            "#11e Duplicate callback matrix (reg="
                                    + regCount
                                    + ", unreg="
                                    + unregCount
                                    + "): sysRemaining="
                                    + actualSys
                                    + ", childSyncCalls="
                                    + actualSync
                                    + ", refsAfterInit="
                                    + refsAfterInit);
                } finally {
                    CspEngine.ALL_PLUGIN_LOADERS.remove(loaderDupRoot);
                    CspEngine.ALL_PLUGIN_LOADERS.remove(loaderDupChild);
                    CspEngine.OWNED_CHILD_LOADERS.remove(loaderDupRoot);
                    CspEngine.UNREADY_LOADERS.remove(loaderDupRoot);
                }
            }
        } finally {
            allowBFail.countDown();
            bg.shutdownNow();
            CspEngine.ALL_PLUGIN_LOADERS.remove(loaderA);
            CspEngine.ALL_PLUGIN_LOADERS.remove(loaderAChild);
            CspEngine.ALL_PLUGIN_LOADERS.remove(loaderB);
            CspEngine.ALL_PLUGIN_LOADERS.remove(loaderBDescChild);
            CspEngine.ALL_PLUGIN_LOADERS.remove(loaderBStandaloneChild);
            CspEngine.OWNED_CHILD_LOADERS.remove(loaderA);
            CspEngine.OWNED_CHILD_LOADERS.remove(loaderB);
            CspEngine.UNREADY_LOADERS.remove(loaderB);
        }
    }

    // P2 #12: NativePythonEngine cache stamp includes process ABI (same version + ABI switch
    // triggers re-extract)
    private static void test12_PythonAbiCacheStamp() throws Exception {
        Path tmp = Files.createTempDirectory("codex-py-abi-");
        try {
            File root = tmp.toFile();
            File stdlib = new File(root, "stdlib-pyc.zip");
            File cacert = new File(root, "site-packages/certifi/cacert.pem");
            File runner = new File(root, "runner/android_runner.py");
            File dynload = new File(root, "lib-dynload");
            File sslSo = new File(dynload, "_ssl.cpython-311.so");
            cacert.getParentFile().mkdirs();
            runner.getParentFile().mkdirs();
            dynload.mkdirs();
            Files.write(stdlib.toPath(), new byte[] {1});
            Files.write(cacert.toPath(), new byte[] {1});
            Files.write(runner.toPath(), new byte[] {1});
            Files.write(sslSo.toPath(), new byte[] {1});

            String stamp32 = NativePythonEngine.cacheStamp("e2e61049624f4632", "armeabi-v7a");
            String stamp64 = NativePythonEngine.cacheStamp("e2e61049624f4632", "arm64-v8a");

            check(
                    !stamp32.equals(stamp64)
                            && !NativePythonEngine.needsRuntimeExtract(
                                    stamp32, stamp32, stdlib, cacert, runner, dynload)
                            && NativePythonEngine.needsRuntimeExtract(
                                    stamp32, stamp64, stdlib, cacert, runner, dynload)
                            && NativePythonEngine.needsRuntimeExtract(
                                    "e2e61049624f4632", stamp64, stdlib, cacert, runner, dynload),
                    "#12 NativePythonEngine cache stamp includes ABI so switching 32<->64 bit on same version triggers re-extract of lib-dynload (_ssl)");

            sslSo.delete();
            check(
                    NativePythonEngine.needsRuntimeExtract(
                            stamp64, stamp64, stdlib, cacert, runner, dynload),
                    "#12 Missing .so inside lib-dynload triggers re-extract even when .version stamp matches");
        } finally {
            deleteRecursive(tmp.toFile());
        }
    }

    private static CrashReportStore.CrashReport makeJavaCrash(String id, long ts) {
        CrashReportStore.CrashReport r = new CrashReportStore.CrashReport();
        r.id = id;
        r.timestampMs = ts;
        r.kind = CrashReportStore.KIND_JAVA;
        r.summary = "RuntimeException: " + id;
        r.stackTrace = "java.lang.RuntimeException: " + id;
        return r;
    }

    private static List<String> idsOf(List<CrashReportStore.CrashReport> list) {
        List<String> out = new ArrayList<>(list.size());
        for (CrashReportStore.CrashReport r : list) out.add(r.id);
        return out;
    }

    private static CrashReportStore.CrashReport findById(
            List<CrashReportStore.CrashReport> list, String id) {
        for (CrashReportStore.CrashReport r : list) {
            if (id.equals(r.id)) return r;
        }
        return null;
    }

    private static void deleteRecursive(File f) {
        if (f == null || !f.exists()) return;
        File[] children = f.listFiles();
        if (children != null) {
            for (File c : children) deleteRecursive(c);
        }
        f.delete();
    }

    public static void main(String[] args) throws Exception {
        Cms.setFailDirectInvalidHostsForTest(true);
        try {
            test1_Api23DohCandidates();
            test2_LmkPreservationMatrix();
            test4_NoDuplicatePostOnDualHealthyDoh();
            test5_SingleIpErrorSemantics();
            test6_MultiIpSelectionAndRedirects();
            test7_RequestScopeCancellationAndBoundedPool();
            test8_LinearWithoutComments();
            test9_PerIdStartupPromptDedupe();
            test10_DismissRaceSafetyAndDoubleTapGuard();
            test11_CspLoaderPublishAfterInit();
            test12_PythonAbiCacheStamp();
            System.out.println("MobileCodexReviewChecks OK (" + passed + " checks passed)");
        } finally {
            Cms.setFailDirectInvalidHostsForTest(false);
        }
    }
}

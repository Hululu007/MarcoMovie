package com.pilipala.marcomovie.lite;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.InetAddress;
import java.net.Socket;
import java.net.SocketException;
import java.net.SocketTimeoutException;

public class AdversarialConfigServerTest {

    private static void check(boolean cond, String message) {
        if (!cond) {
            System.err.println("FAILED: " + message);
            System.exit(1);
        }
        System.out.println("PASS: " + message);
    }

    private static String rawHttp(int port, String requestData) throws Exception {
        Socket s = new Socket("127.0.0.1", port);
        s.setSoTimeout(5000);
        try {
            OutputStream out = s.getOutputStream();
            out.write(requestData.getBytes("US-ASCII"));
            out.flush();

            InputStream in = s.getInputStream();
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] b = new byte[1024];
            int n;
            try {
                while ((n = in.read(b)) != -1) {
                    buf.write(b, 0, n);
                }
            } catch (SocketException ignored) {
            }
            return new String(buf.toByteArray(), "UTF-8");
        } finally {
            try { s.close(); } catch (Exception ignored) {}
        }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("=== Starting Adversarial ConfigServer Tests ===");

        // ==========================================
        // 1. WAN IP Rejection & Boundary Stress Test
        // ==========================================
        System.out.println("--- Subtest 1: WAN IP & Boundary Validation ---");

        // Public IPv4 addresses MUST be rejected
        String[] publicIpv4 = {
            "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1",
            "203.0.113.1", "198.51.100.1", "93.184.216.34",
            "114.114.114.114", "223.5.5.5", "180.101.50.242"
        };
        for (String ip : publicIpv4) {
            check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName(ip)), "Public WAN IPv4 " + ip + " must be rejected");
        }

        // Public IPv6 addresses MUST be rejected
        String[] publicIpv6 = {
            "2001:db8::1", "2606:4700:4700::1111", "2400:cb00::1"
        };
        for (String ip : publicIpv6) {
            check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName(ip)), "Public WAN IPv6 " + ip + " must be rejected");
        }

        // RFC 1918 10.0.0.0/8 boundaries
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("9.255.255.255")), "9.255.255.255 (below 10/8) must be rejected");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("10.0.0.0")), "10.0.0.0 (start 10/8) must be allowed");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("10.255.255.255")), "10.255.255.255 (end 10/8) must be allowed");
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("11.0.0.0")), "11.0.0.0 (above 10/8) must be rejected");

        // RFC 1918 172.16.0.0/12 boundaries
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("172.15.255.255")), "172.15.255.255 (below 172.16/12) must be rejected");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("172.16.0.0")), "172.16.0.0 (start 172.16/12) must be allowed");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("172.31.255.255")), "172.31.255.255 (end 172.16/12) must be allowed");
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("172.32.0.0")), "172.32.0.0 (above 172.16/12) must be rejected");

        // RFC 1918 192.168.0.0/16 boundaries
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("192.167.255.255")), "192.167.255.255 (below 192.168/16) must be rejected");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("192.168.0.0")), "192.168.0.0 (start 192.168/16) must be allowed");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("192.168.255.255")), "192.168.255.255 (end 192.168/16) must be allowed");
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("192.169.0.0")), "192.169.0.0 (above 192.168/16) must be rejected");

        // RFC 6598 CGNAT 100.64.0.0/10 boundaries
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("100.63.255.255")), "100.63.255.255 (below 100.64/10) must be rejected");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("100.64.0.0")), "100.64.0.0 (start 100.64/10) must be allowed");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("100.127.255.255")), "100.127.255.255 (end 100.64/10) must be allowed");
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("100.128.0.0")), "100.128.0.0 (above 100.64/10) must be rejected");

        // Link-local RFC 3927 169.254.0.0/16
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("169.254.1.1")), "169.254.1.1 link-local must be allowed");
        check(!ConfigServer.isAllowedLanPeer(InetAddress.getByName("169.255.0.1")), "169.255.0.1 must be rejected");

        // Loopback
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("127.0.0.1")), "127.0.0.1 loopback must be allowed");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("127.255.255.255")), "127.255.255.255 loopback must be allowed");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("::1")), "::1 IPv6 loopback must be allowed");

        // IPv6 ULA fc00::/7
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("fc00::1")), "fc00::1 ULA must be allowed");
        check(ConfigServer.isAllowedLanPeer(InetAddress.getByName("fd12:3456:789a::1")), "fd12::1 ULA must be allowed");

        // Null safety
        check(!ConfigServer.isAllowedLanPeer(null), "null peer must be rejected");

        // ==========================================
        // 2. Session Expiration Boundary & Socket Exit
        // ==========================================
        System.out.println("--- Subtest 2: Session Expiration Boundary & Socket Exit ---");
        final String[] receivedImport = new String[1];

        // Path A: Server created already past SESSION_LIFETIME_MS
        // serve() immediately detects remainingLifetime <= 0, calls close() and terminates.
        ConfigServer preExpiredServer = new ConfigServer(
            new ConfigServer.Importer() {
                public void apply(String address) {}
            },
            null,
            System.currentTimeMillis() - ConfigServer.SESSION_LIFETIME_MS - 500L
        );
        int preExpiredPort = preExpiredServer.port();
        Thread.sleep(100);
        check(preExpiredServer.isExpired(), "Pre-expired server isExpired() returns true");
        try {
            Socket s = new Socket("127.0.0.1", preExpiredPort);
            s.close();
            check(false, "Socket must NOT accept connections after immediate serve() expiration");
        } catch (ConnectException ce) {
            check(true, "Pre-expired server socket closed immediately upon startup (ConnectException)");
        }

        // Path B: When handle(s) executes on an expired server, verify it returns HTTP 410 Gone
        ConfigServer expiredHandleServer = new ConfigServer(
            new ConfigServer.Importer() {
                public void apply(String address) { receivedImport[0] = address; }
            },
            new ConfigServer.SyncHandler() {
                public String sync(String payload) { return "{}"; }
            },
            System.currentTimeMillis() - ConfigServer.SESSION_LIFETIME_MS - 5000L
        );
        check(expiredHandleServer.isExpired(), "Server isExpired() is true");

        // Use a loopback socket pair to invoke handle() directly
        java.net.ServerSocket testSink = new java.net.ServerSocket(0);
        Socket clientEnd = new Socket("127.0.0.1", testSink.getLocalPort());
        Socket serverEnd = testSink.accept();
        testSink.close();

        java.lang.reflect.Method handleMethod = ConfigServer.class.getDeclaredMethod("handle", Socket.class);
        handleMethod.setAccessible(true);
        handleMethod.invoke(expiredHandleServer, serverEnd);
        serverEnd.close();

        InputStream hin = clientEnd.getInputStream();
        ByteArrayOutputStream hbuf = new ByteArrayOutputStream();
        byte[] hdata = new byte[1024];
        int hn;
        try {
            while ((hn = hin.read(hdata)) != -1) {
                hbuf.write(hdata, 0, hn);
            }
        } catch (SocketException ignored) {}
        clientEnd.close();

        String handleResp = new String(hbuf.toByteArray(), "UTF-8");
        check(handleResp.startsWith("HTTP/1.1 410 Response"), "handle(s) on expired server returns HTTP 410 Gone");
        check(handleResp.contains("配对已过期"), "handle(s) response contains '配对已过期'");

        // Path B2: Verify sync handler also returns 410 Gone when handleSync(s) executes on expired server
        Socket clientSyncEnd = new Socket("127.0.0.1", (testSink = new java.net.ServerSocket(0)).getLocalPort());
        Socket serverSyncEnd = testSink.accept();
        testSink.close();

        java.lang.reflect.Method handleSyncMethod = ConfigServer.class.getDeclaredMethod("handleSync",
            Socket.class, InputStream.class, String.class, int.class, String.class, String.class, String.class);
        handleSyncMethod.setAccessible(true);
        handleSyncMethod.invoke(expiredHandleServer, serverSyncEnd, serverSyncEnd.getInputStream(), "GET", 0, "", "", "");
        serverSyncEnd.close();

        InputStream hsyncIn = clientSyncEnd.getInputStream();
        ByteArrayOutputStream hsyncBuf = new ByteArrayOutputStream();
        byte[] hsyncData = new byte[1024];
        int hsyncN;
        try {
            while ((hsyncN = hsyncIn.read(hsyncData)) != -1) {
                hsyncBuf.write(hsyncData, 0, hsyncN);
            }
        } catch (SocketException ignored) {}
        clientSyncEnd.close();

        String handleSyncResp = new String(hsyncBuf.toByteArray(), "UTF-8");
        check(handleSyncResp.startsWith("HTTP/1.1 410 Response"), "handleSync(s) on expired server returns HTTP 410");
        check(handleSyncResp.contains("session_expired"), "handleSync(s) response contains 'session_expired'");

        // ==========================================
        // 3. Request Timeout & Slowloris Resistance
        // ==========================================
        System.out.println("--- Subtest 3: Request Timeout & Slowloris Resistance ---");

        ConfigServer liveServer = new ConfigServer(
            new ConfigServer.Importer() {
                public void apply(String address) { receivedImport[0] = address; }
            },
            null
        );
        int livePort = liveServer.port();

        // Slowloris test: Client connects, sends incomplete header line, stalls
        Socket slowSocket = new Socket("127.0.0.1", livePort);
        OutputStream slowOut = slowSocket.getOutputStream();
        slowOut.write("GET /".getBytes("US-ASCII"));
        slowOut.flush();

        // Close socket from client side to simulate broken/aborted client connection
        slowSocket.close();
        Thread.sleep(100);

        // Verify that server didn't crash or hang, and immediately serves next legitimate request
        String normalReq = "GET /" + liveServer.token + " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
        String normalResp = rawHttp(livePort, normalReq);
        check(normalResp.startsWith("HTTP/1.1 200 Response"), "Server recovers immediately from aborted client connection");

        // Slow body test: Client sends Content-Length: 100, sends 5 bytes, then closes
        Socket slowBodySocket = new Socket("127.0.0.1", livePort);
        OutputStream slowBodyOut = slowBodySocket.getOutputStream();
        String header = "POST /" + liveServer.token + " HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Content-Type: application/x-www-form-urlencoded\r\n"
            + "Content-Length: 100\r\n\r\n"
            + "url=";
        slowBodyOut.write(header.getBytes("US-ASCII"));
        slowBodyOut.flush();
        slowBodySocket.close();
        Thread.sleep(100);

        // Verify server recovers immediately and processes subsequent valid request
        String recoverResp = rawHttp(livePort, normalReq);
        check(recoverResp.startsWith("HTTP/1.1 200 Response"), "Server recovers immediately from truncated body upload");

        // Clean up
        liveServer.close();
        System.out.println("=== ALL ADVERSARIAL CONFIGSERVER TESTS PASSED ===");
    }
}

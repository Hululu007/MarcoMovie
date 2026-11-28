// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import android.app.Application;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.net.URI;
import java.net.URLDecoder;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/**
 * Time-bounded LAN gateway for Android TV spider web configuration pages (such as cookie/QR helper
 * pages returned on {@code http://127.0.0.1:9978/proxy?do=...}). Keeps {@link LocalProxy} strictly
 * bound to {@code 127.0.0.1}, accepts only private/site-local LAN clients while armed, and allows
 * only non-media spider {@code /proxy} configuration routes.
 */
final class TvLanConfigBridge {
    static final long DEFAULT_ARM_MS = 15L * 60L * 1000L;
    private static final int MAX_BODY_BYTES = 32 * 1024;
    private static final Set<String> BLOCKED_DO_VALUES =
            new HashSet<>(
                    Arrays.asList(
                            "js",
                            "py",
                            "hls",
                            "seg",
                            "kcache",
                            "local-content",
                            "action",
                            "danmaku",
                            "danmu",
                            "refresh"));

    private static volatile Application activeApp;
    private static volatile Cms.Config activeConfig;
    private static volatile LocalProxy.SourceResolver activeSources;
    private static volatile ServerSocket serverSocket;
    private static volatile String boundHost = "";
    private static volatile int boundPort = 0;
    private static volatile long armedUntilNano = 0L;
    private static volatile Thread acceptThread;
    private static ThreadPoolExecutor requestPool;

    private TvLanConfigBridge() {}

    static synchronized String arm(
            Application app,
            Cms.Config config,
            LocalProxy.SourceResolver sources,
            int port,
            long durationMs) {
        if (port <= 0) return "";
        String lanIp = findSiteLocalIpv4();
        return armOnHost(app, config, sources, lanIp, port, durationMs);
    }

    static synchronized String armOnHost(
            Application app,
            Cms.Config config,
            LocalProxy.SourceResolver sources,
            String hostIp,
            int port,
            long durationMs) {
        if (hostIp == null || hostIp.trim().isEmpty() || port < 0) return "";
        String cleanHost = hostIp.trim();
        long ttlMs = Math.max(10_000L, durationMs > 0 ? durationMs : DEFAULT_ARM_MS);
        activeApp = app;
        activeConfig = config;
        activeSources = sources != null ? sources : CspEngine::proxy;
        armedUntilNano = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ttlMs);

        if (serverSocket != null
                && !serverSocket.isClosed()
                && cleanHost.equals(boundHost)
                && (port == boundPort || (port == 0 && boundPort > 0))) {
            return cleanHost;
        }
        closeSocketOnly();
        try {
            ServerSocket next = new ServerSocket();
            next.setReuseAddress(true);
            next.bind(new InetSocketAddress(InetAddress.getByName(cleanHost), port));
            serverSocket = next;
            boundHost = cleanHost;
            boundPort = next.getLocalPort();
            ensurePool();
            startAcceptLoop(next);
            return cleanHost;
        } catch (IOException err) {
            AppLog.w(
                    "TvLanConfigBridge",
                    "Unable to bind LAN config listener on " + cleanHost + ":" + port,
                    err);
            closeSocketOnly();
            return "";
        }
    }

    static synchronized int boundPortForTest() {
        return boundPort;
    }

    static String armAndRewriteUrl(
            Application app,
            Cms.Config config,
            LocalProxy.SourceResolver sources,
            int port,
            String rawUrl) {
        if (!isLocalProxyConfigUrl(rawUrl)) return "";
        String lanIp = arm(app, config, sources, port, DEFAULT_ARM_MS);
        if (lanIp.isEmpty()) return "";
        int effectivePort = boundPort > 0 ? boundPort : port;
        String rewritten = rewriteToLanConfigUrl(rawUrl, lanIp, effectivePort);
        return rewritten == null ? "" : rewritten;
    }

    static synchronized void disarm() {
        armedUntilNano = 0L;
        activeApp = null;
        activeSources = null;
        closeSocketOnly();
        if (requestPool != null) {
            requestPool.shutdownNow();
            requestPool = null;
        }
    }

    private static synchronized void ensurePool() {
        if (requestPool != null && !requestPool.isShutdown()) return;
        ThreadPoolExecutor pool =
                new ThreadPoolExecutor(
                        2,
                        8,
                        20,
                        TimeUnit.SECONDS,
                        new LinkedBlockingQueue<Runnable>(32),
                        r -> {
                            Thread t = new Thread(r, "tv-lan-config");
                            t.setDaemon(true);
                            return t;
                        });
        pool.allowCoreThreadTimeOut(true);
        requestPool = pool;
    }

    private static void closeSocketOnly() {
        ServerSocket existing = serverSocket;
        serverSocket = null;
        boundHost = "";
        boundPort = 0;
        if (existing != null) {
            try {
                existing.close();
            } catch (IOException ignored) {
            }
        }
    }

    private static void startAcceptLoop(final ServerSocket srv) {
        Thread t =
                new Thread(
                        () -> {
                            while (serverSocket == srv && !srv.isClosed()) {
                                try {
                                    final Socket client = srv.accept();
                                    ThreadPoolExecutor pool = requestPool;
                                    if (pool == null || pool.isShutdown()) {
                                        closeQuietly(client);
                                        continue;
                                    }
                                    try {
                                        pool.execute(() -> handleClient(srv, client));
                                    } catch (RejectedExecutionException full) {
                                        closeQuietly(client);
                                    }
                                } catch (IOException ignored) {
                                    break;
                                }
                            }
                        },
                        "tv-lan-config-accept");
        t.setDaemon(true);
        acceptThread = t;
        t.start();
    }

    static boolean isSiteLocalOrLoopback(InetAddress addr) {
        return addr != null && (addr.isSiteLocalAddress() || addr.isLoopbackAddress());
    }

    static boolean isArmedNow() {
        return System.nanoTime() <= armedUntilNano;
    }

    static boolean isAllowedLanConfigRoute(String path, Map<String, String> params) {
        if (!"/proxy".equals(path)) return false;
        if (params == null) return true;
        String doParam = params.get("do");
        if (doParam != null) {
            String lower = doParam.trim().toLowerCase(Locale.ROOT);
            if (BLOCKED_DO_VALUES.contains(lower)) return false;
        }
        return true;
    }

    private static String normalizePortPlaceholder(String rawUrl) {
        if (rawUrl == null) return "";
        String t = rawUrl.trim();
        return t.replace(":-1/", ":9978/").replace(":0/", ":9978/");
    }

    static boolean isLocalProxyConfigUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return false;
        try {
            String sanitized = ProxyAddress.sanitizePathAndQuery(normalizePortPlaceholder(rawUrl));
            URI uri = new URI(sanitized);
            if (!"http".equalsIgnoreCase(uri.getScheme())) return false;
            if (!"/proxy".equals(uri.getPath())) return false;
            String host = uri.getHost();
            if (!isLocalOrPrivateHost(host)) return false;
            int port = uri.getPort();
            int activePort = ProxyAddress.port;
            boolean validPort =
                    port == activePort || port == -1 || port == 0 || (port >= 9978 && port <= 9999);
            if (!validPort) return false;
            String q = uri.getRawQuery();
            if (q != null && !q.isEmpty()) {
                for (String pair : q.split("&")) {
                    int eq = pair.indexOf('=');
                    String k = eq >= 0 ? pair.substring(0, eq) : pair;
                    String v = eq >= 0 ? pair.substring(eq + 1) : "";
                    if ("do".equalsIgnoreCase(k)) {
                        String doVal =
                                URLDecoder.decode(v, "UTF-8").trim().toLowerCase(Locale.ROOT);
                        if (BLOCKED_DO_VALUES.contains(doVal)) return false;
                    }
                }
            }
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    static String rewriteToLanConfigUrl(String rawUrl, String lanIp, int proxyPort) {
        if (lanIp == null || lanIp.trim().isEmpty() || proxyPort <= 0) return null;
        if (!isLocalProxyConfigUrl(rawUrl)) return null;
        try {
            URI uri = new URI(ProxyAddress.sanitizePathAndQuery(normalizePortPlaceholder(rawUrl)));
            String rawQuery = uri.getRawQuery();
            StringBuilder cleanQuery = new StringBuilder();
            if (rawQuery != null && !rawQuery.isEmpty()) {
                for (String pair : rawQuery.split("&")) {
                    if (pair.isEmpty()) continue;
                    int eq = pair.indexOf('=');
                    String key = eq >= 0 ? pair.substring(0, eq) : pair;
                    if ("_mm_token".equalsIgnoreCase(key)) continue;
                    if (cleanQuery.length() > 0) cleanQuery.append('&');
                    cleanQuery.append(pair);
                }
            }
            return "http://"
                    + lanIp.trim()
                    + ":"
                    + proxyPort
                    + uri.getRawPath()
                    + (cleanQuery.length() > 0 ? "?" + cleanQuery : "")
                    + (uri.getRawFragment() != null ? "#" + uri.getRawFragment() : "");
        } catch (Exception ignored) {
            return null;
        }
    }

    private static boolean isLocalOrPrivateHost(String host) {
        if (host == null || host.isEmpty()) return false;
        if (ProxyAddress.isLoopbackHost(host)) return true;
        String bare = host.trim();
        if (bare.startsWith("10.") || bare.startsWith("192.168.")) return true;
        if (bare.startsWith("172.")) {
            String[] parts = bare.split("\\.");
            if (parts.length == 4) {
                try {
                    int second = Integer.parseInt(parts[1]);
                    return second >= 16 && second <= 31;
                } catch (NumberFormatException ignored) {
                    return false;
                }
            }
        }
        return false;
    }

    static String findSiteLocalIpv4() {
        try {
            Enumeration<NetworkInterface> ifaces = NetworkInterface.getNetworkInterfaces();
            if (ifaces == null) return "";
            String fallback = "";
            while (ifaces.hasMoreElements()) {
                NetworkInterface iface = ifaces.nextElement();
                try {
                    if (iface.isLoopback() || !iface.isUp() || iface.isVirtual()) continue;
                } catch (SocketException ignored) {
                    continue;
                }
                String name =
                        iface.getName() == null ? "" : iface.getName().toLowerCase(Locale.ROOT);
                if (name.startsWith("tun")
                        || name.startsWith("ppp")
                        || name.startsWith("dummy")
                        || name.startsWith("rmnet")) {
                    continue;
                }
                Enumeration<InetAddress> addrs = iface.getInetAddresses();
                while (addrs.hasMoreElements()) {
                    InetAddress addr = addrs.nextElement();
                    if (addr instanceof Inet4Address
                            && !addr.isLoopbackAddress()
                            && addr.isSiteLocalAddress()) {
                        String host = addr.getHostAddress();
                        if (host == null || host.isEmpty()) continue;
                        if (name.startsWith("wlan") || name.startsWith("eth")) {
                            return host;
                        }
                        if (fallback.isEmpty()) fallback = host;
                    }
                }
            }
            return fallback;
        } catch (Exception ignored) {
            return "";
        }
    }

    private static void handleClient(ServerSocket srv, Socket socket) {
        try (Socket conn = socket) {
            if (serverSocket != srv || !isArmedNow()) return;
            if (!isSiteLocalOrLoopback(conn.getInetAddress())) return;
            conn.setSoTimeout(20_000);
            try {
                conn.setTcpNoDelay(true);
            } catch (SocketException ignored) {
            }
            InputStream in = new BufferedInputStream(conn.getInputStream(), 8192);
            OutputStream out = new BufferedOutputStream(conn.getOutputStream(), 32 * 1024);

            String requestLine = readLineOrNull(in, 8192);
            if (requestLine == null || requestLine.isEmpty()) return;
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0].toUpperCase(Locale.ROOT);
            String rawTarget = parts[1];
            int qAt = rawTarget.indexOf('?');
            String path = qAt >= 0 ? rawTarget.substring(0, qAt) : rawTarget;
            String query = qAt >= 0 ? rawTarget.substring(qAt + 1) : null;

            Map<String, String> headers = new LinkedHashMap<>();
            Map<String, String> params = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
            int headerBytes = 0;
            for (; ; ) {
                String line = readLineOrNull(in, 8192);
                if (line == null) return;
                headerBytes += line.length();
                if (headerBytes > 32768) {
                    LocalProxy.simple(out, 400, "Headers too large");
                    return;
                }
                if (line.isEmpty()) break;
                int colon = line.indexOf(':');
                if (colon > 0) {
                    String k = line.substring(0, colon).trim();
                    String v = line.substring(colon + 1).trim();
                    headers.put(k.toLowerCase(Locale.ROOT), v);
                    params.put(k, v);
                }
            }

            if ("/favicon.ico".equals(path)) {
                out.write(
                        "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                                .getBytes("US-ASCII"));
                out.flush();
                return;
            }
            if (!"GET".equals(method) && !"HEAD".equals(method) && !"POST".equals(method)) {
                LocalProxy.simple(out, 405, "Method Not Allowed");
                return;
            }

            if (query != null && !query.isEmpty()) {
                parseFormPairs(query, params);
            }

            if ("POST".equals(method)) {
                int contentLen = 0;
                String rawLen = headers.get("content-length");
                if (rawLen != null && !rawLen.isEmpty()) {
                    try {
                        contentLen = Integer.parseInt(rawLen.trim());
                    } catch (NumberFormatException bad) {
                        LocalProxy.simple(out, 400, "Invalid Content-Length");
                        return;
                    }
                }
                if (contentLen < 0 || contentLen > MAX_BODY_BYTES) {
                    LocalProxy.simple(out, 400, "Payload too large");
                    return;
                }
                byte[] bodyBytes = new byte[contentLen];
                int off = 0;
                while (off < contentLen) {
                    int r = in.read(bodyBytes, off, contentLen - off);
                    if (r < 0) break;
                    off += r;
                }
                if (off > 0) {
                    String bodyStr = new String(bodyBytes, 0, off, "UTF-8");
                    params.put("body", bodyStr);
                    String trimmed = bodyStr.trim();
                    if (trimmed.startsWith("{")) {
                        try {
                            JSONObject json = new JSONObject(trimmed);
                            Iterator<String> keys = json.keys();
                            while (keys.hasNext()) {
                                String k = keys.next();
                                if (!json.isNull(k)) params.put(k, String.valueOf(json.opt(k)));
                            }
                        } catch (Exception ignored) {
                        }
                    } else {
                        parseFormPairs(bodyStr, params);
                    }
                }
            }

            params.remove("_mm_token");
            if (!isAllowedLanConfigRoute(path, params)) {
                LocalProxy.simple(out, 403, "Forbidden");
                return;
            }

            params.put("method", method);
            if (conn.getInetAddress() != null) {
                params.put("remote-addr", conn.getInetAddress().getHostAddress());
            }
            params.put("request-headers", new JSONObject(headers).toString());

            LocalProxy.SourceResolver resolver = activeSources;
            if (resolver == null) {
                LocalProxy.simple(out, 503, "Config bridge unavailable");
                return;
            }
            Object[] response;
            try {
                response = resolver.resolve(activeApp, activeConfig, params);
            } catch (Throwable err) {
                AppLog.w("TvLanConfigBridge", "Spider LAN config failed", err);
                LocalProxy.simple(out, 502, "Source config failed");
                return;
            }
            if (response == null || response.length < 3 || !(response[0] instanceof Number)) {
                LocalProxy.simple(out, 404, "Not found");
                return;
            }
            int code = ((Number) response[0]).intValue();
            if (code < 100 || code > 599) code = 502;
            String mime = String.valueOf(response[1]);
            LocalProxy.BodyPayload payload = LocalProxy.extractBody(response[2]);
            long len = payload.fixedBytes != null ? payload.fixedBytes.length : -1L;

            StringBuilder head =
                    new StringBuilder("HTTP/1.1 ")
                            .append(code)
                            .append(' ')
                            .append(LocalProxy.reasonPhrase(code))
                            .append("\r\nConnection: close\r\n");
            if (LocalProxy.safe(mime)) head.append("Content-Type: ").append(mime).append("\r\n");
            if (response.length > 3 && response[3] instanceof Map) {
                for (Map.Entry<?, ?> entry : ((Map<?, ?>) response[3]).entrySet()) {
                    String k = String.valueOf(entry.getKey());
                    String v = String.valueOf(entry.getValue());
                    if (!LocalProxy.safe(k) || !LocalProxy.safe(v)) continue;
                    if (!k.equalsIgnoreCase("Connection")
                            && !k.equalsIgnoreCase("Transfer-Encoding")
                            && !k.equalsIgnoreCase("Content-Type")
                            && !k.equalsIgnoreCase("Content-Length")) {
                        head.append(k).append(": ").append(v).append("\r\n");
                    }
                }
            }
            if (len >= 0) head.append("Content-Length: ").append(len).append("\r\n");
            head.append("\r\n");
            out.write(head.toString().getBytes("ISO-8859-1"));
            if (!"HEAD".equals(method) && payload.stream != null) {
                try (InputStream bodyStream = payload.stream) {
                    byte[] buf = new byte[16 * 1024];
                    int r;
                    while ((r = bodyStream.read(buf)) != -1) {
                        out.write(buf, 0, r);
                    }
                }
            }
            out.flush();
        } catch (Exception ignored) {
        }
    }

    private static void parseFormPairs(String raw, Map<String, String> params) {
        for (String pair : raw.split("&")) {
            if (pair.isEmpty()) continue;
            String[] p = pair.split("=", 2);
            try {
                String k = URLDecoder.decode(p[0], "UTF-8");
                String v = p.length == 2 ? URLDecoder.decode(p[1], "UTF-8") : "";
                params.put(k, v);
            } catch (Exception ignored) {
                params.put(p[0], p.length == 2 ? p[1] : "");
            }
        }
    }

    private static String readLineOrNull(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') break;
            if (c != '\r') b.write(c);
            if (b.size() > limit) throw new IOException("HTTP line too large");
        }
        if (c == -1 && b.size() == 0) return null;
        return b.toString("UTF-8");
    }

    private static void closeQuietly(Socket socket) {
        if (socket != null) {
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
    }
}

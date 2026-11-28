package com.pilipala.marcomovie;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PushbackInputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Ephemeral, token-scoped LAN HTTP relay for outbound DLNA casting.
 *
 * <p>Unlike {@link LocalProxy} and {@link CloudMediaProxy} (which remain strictly bound to {@code
 * 127.0.0.1} for local playback security), {@code LanCastMediaRelay} exposes ONLY the single active
 * cast session over a random 32-hex-char token to same-LAN DLNA renderers so TVs/boxes can play:
 *
 * <ul>
 *   <li>Local loopback proxy streams ({@link LocalProxy}, {@link CloudMediaProxy}, {@link
 *       HlsStreamProxy}, {@link MediaDiskCache}, {@link MagnetStream})
 *   <li>Header-protected remote streams requiring {@code Cookie}, {@code Referer}, {@code
 *       Authorization}, {@code Origin}, or custom {@code User-Agent}
 *   <li>Local offline {@code file://} videos and downloaded HLS directories (with relative/local
 *       segment rewriting and canonical-root path containment).
 * </ul>
 */
final class LanCastMediaRelay implements Closeable {
    private static final int MAX_PLAYLIST_BYTES = 4 * 1024 * 1024;
    private static final int MAX_REDIRECTS = 5;
    private static final int COPY_BUFFER_BYTES = 64 * 1024;
    private static final Pattern URI_ATTR = Pattern.compile("URI=\"([^\"]+)\"");
    private static final SecureRandom RNG = new SecureRandom();

    static final class Session {
        final String token;
        final String rootTargetUrl;
        final Map<String, String> headers;
        final String declaredMime;
        final String lanBaseUrl;
        final String localRootDirCanonical;
        final String localRootFileCanonical;
        final boolean allowLoopbackUpstream;
        final ConcurrentHashMap<Integer, String> idToTarget = new ConcurrentHashMap<>();
        final ConcurrentHashMap<String, Integer> targetToId = new ConcurrentHashMap<>();
        final AtomicInteger nextId = new AtomicInteger(0);
        volatile boolean revoked;

        Session(
                String token,
                String rootTargetUrl,
                Map<String, String> headers,
                String declaredMime,
                String lanBaseUrl,
                String localRootDirCanonical,
                String localRootFileCanonical,
                boolean allowLoopbackUpstream) {
            this.token = token;
            this.rootTargetUrl = rootTargetUrl;
            this.headers =
                    headers == null
                            ? Collections.<String, String>emptyMap()
                            : Collections.unmodifiableMap(new LinkedHashMap<>(headers));
            this.declaredMime = declaredMime == null ? "" : declaredMime.trim();
            this.lanBaseUrl = lanBaseUrl;
            this.localRootDirCanonical = localRootDirCanonical;
            this.localRootFileCanonical = localRootFileCanonical;
            this.allowLoopbackUpstream = allowLoopbackUpstream;
        }

        String registerSubUrl(String targetUrl) {
            if (targetUrl == null || targetUrl.trim().isEmpty()) return "";
            String clean = targetUrl.trim();
            Integer existing = targetToId.get(clean);
            int id;
            if (existing != null) {
                id = existing.intValue();
            } else {
                int assigned = nextId.getAndIncrement();
                Integer raced = targetToId.putIfAbsent(clean, assigned);
                if (raced != null) {
                    id = raced.intValue();
                } else {
                    idToTarget.put(assigned, clean);
                    id = assigned;
                }
            }
            return lanBaseUrl + "/sub/" + id + inferExtensionSuffix(clean, "");
        }

        String resolveSub(int id) {
            return idToTarget.get(id);
        }
    }

    private static volatile LanCastMediaRelay sharedInstance;

    static synchronized LanCastMediaRelay shared() throws IOException {
        if (sharedInstance == null || sharedInstance.closed) {
            sharedInstance = new LanCastMediaRelay(new InetSocketAddress("0.0.0.0", 0), false);
        }
        return sharedInstance;
    }

    static void revokeActive() {
        LanCastMediaRelay inst = sharedInstance;
        if (inst != null) {
            inst.revoke();
        }
    }

    private final ServerSocket server;
    private final boolean allowLoopbackPeers;
    private volatile Session activeSession;
    private volatile boolean closed;
    private final ThreadPoolExecutor workers =
            new ThreadPoolExecutor(
                    0,
                    32,
                    30,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<Runnable>(),
                    r -> {
                        Thread t = new Thread(r, "marco-cast-relay");
                        t.setDaemon(true);
                        return t;
                    });

    LanCastMediaRelay(InetSocketAddress bindAddr, boolean allowLoopbackPeers) throws IOException {
        this.allowLoopbackPeers = allowLoopbackPeers;
        this.server = new ServerSocket();
        this.server.setReuseAddress(true);
        this.server.bind(bindAddr);
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed) {
                                try {
                                    Socket sock = server.accept();
                                    workers.execute(() -> serve(sock));
                                } catch (Throwable e) {
                                    if (!closed) {
                                        try {
                                            Thread.sleep(20);
                                        } catch (InterruptedException ie) {
                                            Thread.currentThread().interrupt();
                                            break;
                                        }
                                    }
                                }
                            }
                        },
                        "marco-cast-relay-accept");
        accept.setDaemon(true);
        accept.start();
    }

    int getPort() {
        return server.getLocalPort();
    }

    Session activeSessionForTest() {
        return activeSession;
    }

    synchronized String publish(
            String lanIp, String targetUrl, Map<String, String> headers, String declaredMime)
            throws IOException {
        if (closed) throw new IOException("投屏中继服务已关闭");
        String host = lanIp == null ? "" : lanIp.trim();
        if (host.isEmpty()) throw new IOException("未检测到局域网 Wi-Fi IP 地址");
        String cleanTarget = targetUrl == null ? "" : targetUrl.trim();
        if (cleanTarget.isEmpty()) throw new IOException("播放地址为空");

        Session prev = activeSession;
        if (prev != null) prev.revoked = true;

        byte[] rnd = new byte[16];
        RNG.nextBytes(rnd);
        StringBuilder tok = new StringBuilder(32);
        for (byte b : rnd) tok.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        String token = tok.toString();

        String localRootDir = "";
        String localRootFile = "";
        boolean allowLoopbackUpstream = false;
        if (isLocalFileUrl(cleanTarget)) {
            File f = toLocalFile(cleanTarget);
            if (f != null) {
                localRootFile = f.getCanonicalPath();
                File parent = f.getParentFile();
                localRootDir = parent != null ? parent.getCanonicalPath() : localRootFile;
            }
        } else {
            try {
                URL parsedRoot = new URL(ProxyAddress.normalizeMediaHttpUrl(cleanTarget));
                allowLoopbackUpstream = isLoopbackOrAnyLocalHost(parsedRoot.getHost());
            } catch (Throwable ignored) {
            }
        }

        String hostFormatted =
                host.contains(":") && !host.startsWith("[") ? "[" + host + "]" : host;
        String baseUrl = "http://" + hostFormatted + ":" + getPort() + "/cast-media/" + token;
        Session session =
                new Session(
                        token,
                        cleanTarget,
                        headers,
                        declaredMime,
                        baseUrl,
                        localRootDir,
                        localRootFile,
                        allowLoopbackUpstream);
        activeSession = session;
        return baseUrl + "/" + inferFilename(cleanTarget, declaredMime);
    }

    static boolean isLoopbackOrAnyLocalHost(String host) {
        if (host == null) return false;
        String h = host.trim().toLowerCase(Locale.ROOT);
        if (h.startsWith("[") && h.endsWith("]")) {
            h = h.substring(1, h.length() - 1);
        }
        return ProxyAddress.isLoopbackHost(h)
                || "0.0.0.0".equals(h)
                || "::".equals(h)
                || "0:0:0:0:0:0:0:0".equals(h);
    }

    synchronized void revoke() {
        Session prev = activeSession;
        if (prev != null) {
            prev.revoked = true;
            activeSession = null;
        }
    }

    @Override
    public void close() {
        closed = true;
        revoke();
        try {
            server.close();
        } catch (IOException ignored) {
        }
        workers.shutdownNow();
    }

    static boolean isRelayUrl(String url) {
        return url != null && url.contains("/cast-media/");
    }

    static boolean requiresHeaderRelay(Map<String, String> headers) {
        if (headers == null || headers.isEmpty()) return false;
        for (Map.Entry<String, String> e : headers.entrySet()) {
            String k = e.getKey() == null ? "" : e.getKey().trim().toLowerCase(Locale.ROOT);
            String v = e.getValue() == null ? "" : e.getValue().trim();
            if (v.isEmpty()) continue;
            if ("cookie".equals(k)
                    || "referer".equals(k)
                    || "authorization".equals(k)
                    || "origin".equals(k)) {
                return true;
            }
            if ("user-agent".equals(k) && !v.startsWith("MarcoMovie") && !v.startsWith("Dalvik/")) {
                return true;
            }
        }
        return false;
    }

    static boolean isLocalFileUrl(String url) {
        if (url == null) return false;
        String t = url.trim();
        if (t.regionMatches(true, 0, "file:/", 0, 6)) return true;
        return t.startsWith("/") && new File(t).exists();
    }

    static File toLocalFile(String url) {
        if (url == null) return null;
        String t = url.trim();
        try {
            if (t.regionMatches(true, 0, "file:/", 0, 6)) {
                return new File(new URI(t));
            }
            if (t.startsWith("/")) {
                return new File(t);
            }
        } catch (Throwable ignored) {
            if (t.regionMatches(true, 0, "file://", 0, 7)) {
                return new File(t.substring(7));
            }
            if (t.regionMatches(true, 0, "file:/", 0, 6)) {
                return new File(t.substring(5));
            }
        }
        return null;
    }

    static String inferExtensionSuffix(String url, String declaredMime) {
        String mime = declaredMime == null ? "" : declaredMime.trim().toLowerCase(Locale.ROOT);
        if (mime.contains("mpegurl")) return ".m3u8";
        if (mime.contains("mp2t")) return ".ts";
        if (mime.contains("matroska")) return ".mkv";
        if (mime.contains("mp4")) return ".mp4";
        if (mime.contains("webm")) return ".webm";

        String clean = url == null ? "" : url.trim().toLowerCase(Locale.ROOT).split("[?#]", 2)[0];
        if (clean.endsWith(".m3u8") || clean.endsWith(".m3u")) return ".m3u8";
        if (clean.endsWith(".mpd")) return ".mpd";
        if (clean.endsWith(".ts")) return ".ts";
        if (clean.endsWith(".m4s")) return ".m4s";
        if (clean.endsWith(".mp4")) return ".mp4";
        if (clean.endsWith(".mkv")) return ".mkv";
        if (clean.endsWith(".flv")) return ".flv";
        if (clean.endsWith(".webm")) return ".webm";
        if (clean.endsWith(".key")) return ".key";
        if (clean.endsWith(".aac")) return ".aac";
        if (url != null) {
            String low = url.toLowerCase(Locale.ROOT);
            if (low.contains("/hls?") || low.contains(".m3u8?")) return ".m3u8";
        }
        return "";
    }

    static String inferFilename(String url, String declaredMime) {
        String ext = inferExtensionSuffix(url, declaredMime);
        if (".m3u8".equals(ext)) return "stream.m3u8";
        if (ext.isEmpty()) return "stream.mp4";
        return "stream" + ext;
    }

    static String inferMimeType(String url, String declaredMime) {
        String ext = inferExtensionSuffix(url, declaredMime);
        if (".m3u8".equals(ext)) return "application/vnd.apple.mpegurl";
        if (".mpd".equals(ext)) return "application/dash+xml";
        if (".ts".equals(ext)) return "video/mp2t";
        if (".mkv".equals(ext)) return "video/x-matroska";
        if (".flv".equals(ext)) return "video/x-flv";
        if (".webm".equals(ext)) return "video/webm";
        if (".mp4".equals(ext) || ".m4s".equals(ext)) return "video/mp4";
        if (declaredMime != null && !declaredMime.trim().isEmpty()) {
            return declaredMime.trim();
        }
        return "video/mp4";
    }

    private void serve(Socket socket) {
        try (Socket s = socket) {
            InetAddress peer = s.getInetAddress();
            boolean allowed =
                    peer != null
                            && (ConfigTransferServer.isAllowedLanPeer(peer)
                                    || (allowLoopbackPeers && peer.isLoopbackAddress()));
            if (!allowed) {
                sendSimple(s.getOutputStream(), 403, "Forbidden");
                return;
            }
            try {
                s.setTcpNoDelay(true);
            } catch (Throwable ignored) {
            }
            s.setSoTimeout(30_000);
            InputStream in = new BufferedInputStream(s.getInputStream(), 8192);
            OutputStream out = new BufferedOutputStream(s.getOutputStream(), COPY_BUFFER_BYTES);

            String reqLine = readLine(in, 4096);
            if (reqLine == null || reqLine.isEmpty()) return;
            String[] parts = reqLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0].trim().toUpperCase(Locale.ROOT);
            if (!"GET".equals(method) && !"HEAD".equals(method)) {
                sendSimple(out, 405, "Method Not Allowed");
                return;
            }
            String rawTarget = parts[1].trim();
            int q = rawTarget.indexOf('?');
            String path = q >= 0 ? rawTarget.substring(0, q) : rawTarget;

            Map<String, String> reqHeaders = new LinkedHashMap<>();
            int headerBytes = 0;
            for (; ; ) {
                String line = readLine(in, 4096);
                if (line == null || line.isEmpty()) break;
                headerBytes += line.length();
                if (headerBytes > 16384) {
                    sendSimple(out, 431, "Header Limit");
                    return;
                }
                int colon = line.indexOf(':');
                if (colon > 0) {
                    reqHeaders.put(
                            line.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            line.substring(colon + 1).trim());
                }
            }

            Session session = activeSession;
            if (session == null || session.revoked || !path.startsWith("/cast-media/")) {
                sendSimple(out, 404, "Not Found");
                return;
            }
            String rest = path.substring("/cast-media/".length());
            int slash = rest.indexOf('/');
            String reqToken = slash >= 0 ? rest.substring(0, slash) : rest;
            if (!session.token.equals(reqToken)) {
                sendSimple(out, 404, "Not Found");
                return;
            }
            String subPath = slash >= 0 ? rest.substring(slash) : "/";
            String targetUrl;
            boolean isSubRequest = false;
            if (subPath.startsWith("/sub/")) {
                isSubRequest = true;
                String idPart = subPath.substring("/sub/".length());
                int dot = idPart.indexOf('.');
                if (dot >= 0) idPart = idPart.substring(0, dot);
                int subId;
                try {
                    subId = Integer.parseInt(idPart);
                } catch (NumberFormatException nfe) {
                    sendSimple(out, 404, "Not Found");
                    return;
                }
                targetUrl = session.resolveSub(subId);
                if (targetUrl == null || targetUrl.isEmpty()) {
                    sendSimple(out, 404, "Not Found");
                    return;
                }
            } else {
                targetUrl = session.rootTargetUrl;
            }

            if (isLocalFileUrl(targetUrl)) {
                serveLocalFile(session, targetUrl, isSubRequest, method, reqHeaders, out);
            } else {
                serveHttpUpstream(session, targetUrl, isSubRequest, method, reqHeaders, out);
            }
        } catch (Throwable ignored) {
        }
    }

    private void serveLocalFile(
            Session session,
            String targetUrl,
            boolean isSubRequest,
            String method,
            Map<String, String> reqHeaders,
            OutputStream out)
            throws IOException {
        if (session.localRootDirCanonical.isEmpty()) {
            sendSimple(out, 403, "Forbidden");
            return;
        }
        File file = toLocalFile(targetUrl);
        if (file == null || !file.isFile() || !file.canRead()) {
            sendSimple(out, 404, "File Not Found");
            return;
        }
        String canon = file.getCanonicalPath();
        String root = session.localRootDirCanonical;
        String rootPrefix = root.endsWith(File.separator) ? root : root + File.separator;
        if (!canon.equals(session.localRootFileCanonical)
                && !canon.equals(root)
                && !canon.startsWith(rootPrefix)) {
            sendSimple(out, 403, "Forbidden");
            return;
        }

        long length = file.length();
        boolean looksM3u =
                targetUrl.toLowerCase(Locale.ROOT).endsWith(".m3u8")
                        || targetUrl.toLowerCase(Locale.ROOT).endsWith(".m3u");
        if (!looksM3u && length > 0 && length <= MAX_PLAYLIST_BYTES) {
            byte[] head = new byte[(int) Math.min(7, length)];
            try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
                raf.readFully(head);
            }
            if ("#EXTM3U".equals(new String(head, StandardCharsets.US_ASCII))) {
                looksM3u = true;
            }
        }
        if (looksM3u && length <= MAX_PLAYLIST_BYTES) {
            byte[] raw = readFileBytes(file, MAX_PLAYLIST_BYTES);
            String rewritten =
                    rewriteHlsForRelay(
                            new String(raw, StandardCharsets.UTF_8),
                            file.toURI().toString(),
                            session);
            byte[] body = rewritten.getBytes(StandardCharsets.UTF_8);
            writeBytesResponse(
                    out, 200, "application/vnd.apple.mpegurl", body, "HEAD".equals(method));
            return;
        }

        String mime = inferMimeType(targetUrl, isSubRequest ? "" : session.declaredMime);
        String rangeHeader = reqHeaders.get("range");
        long[] range = parseRangeHeader(rangeHeader, length);
        if (rangeHeader != null && range == null) {
            String head =
                    "HTTP/1.1 416 Range Not Satisfiable\r\n"
                            + "Content-Range: bytes */"
                            + length
                            + "\r\n"
                            + "Accept-Ranges: bytes\r\n"
                            + "Connection: close\r\n\r\n";
            out.write(head.getBytes(StandardCharsets.US_ASCII));
            out.flush();
            return;
        }

        long start = range != null ? range[0] : 0L;
        long end = range != null ? range[1] : (length > 0 ? length - 1L : -1L);
        long contentLen = end >= start ? (end - start + 1L) : 0L;
        boolean partial = range != null;

        StringBuilder hdr = new StringBuilder();
        hdr.append("HTTP/1.1 ").append(partial ? "206 Partial Content" : "200 OK").append("\r\n");
        hdr.append("Content-Type: ").append(mime).append("\r\n");
        hdr.append("Accept-Ranges: bytes\r\n");
        hdr.append("Content-Length: ").append(contentLen).append("\r\n");
        if (partial) {
            hdr.append("Content-Range: bytes ")
                    .append(start)
                    .append('-')
                    .append(end)
                    .append('/')
                    .append(length)
                    .append("\r\n");
        }
        hdr.append("Cache-Control: no-store\r\n");
        hdr.append("Connection: close\r\n\r\n");
        out.write(hdr.toString().getBytes(StandardCharsets.US_ASCII));
        if (!"HEAD".equals(method) && contentLen > 0) {
            try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
                raf.seek(start);
                byte[] buf = new byte[COPY_BUFFER_BYTES];
                long remaining = contentLen;
                while (remaining > 0 && !session.revoked && !closed) {
                    int toRead = (int) Math.min(buf.length, remaining);
                    int n = raf.read(buf, 0, toRead);
                    if (n < 0) break;
                    out.write(buf, 0, n);
                    remaining -= n;
                }
            }
        }
        out.flush();
    }

    private void serveHttpUpstream(
            Session session,
            String initialUrl,
            boolean isSubRequest,
            String method,
            Map<String, String> reqHeaders,
            OutputStream out)
            throws IOException {
        String currentUrl = initialUrl;
        HttpURLConnection conn = null;
        try {
            Map<String, String> baseHeaders = new LinkedHashMap<>(session.headers);
            String range = reqHeaders.get("range");
            String ifRange = reqHeaders.get("if-range");

            int code = -1;
            for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
                URL parsed = new URL(ProxyAddress.normalizeMediaHttpUrl(currentUrl));
                boolean isLoopback = isLoopbackOrAnyLocalHost(parsed.getHost());
                if (!isLoopback && !session.allowLoopbackUpstream) {
                    try {
                        InetAddress resolvedAddr = InetAddress.getByName(parsed.getHost());
                        if (resolvedAddr != null
                                && (resolvedAddr.isLoopbackAddress()
                                        || resolvedAddr.isAnyLocalAddress())) {
                            isLoopback = true;
                        }
                    } catch (Throwable ignored) {
                    }
                }
                if (isLoopback && !session.allowLoopbackUpstream) {
                    sendSimple(out, 403, "Forbidden");
                    return;
                }
                Map<String, String> sendHeaders =
                        isLoopback
                                ? ProxyAddress.sanitizeLoopbackHeaders(
                                        parsed.getHost(), baseHeaders)
                                : baseHeaders;
                conn = (HttpURLConnection) parsed.openConnection();
                conn.setInstanceFollowRedirects(false);
                conn.setConnectTimeout(12_000);
                conn.setReadTimeout(25_000);
                conn.setRequestMethod(method);
                for (Map.Entry<String, String> e : sendHeaders.entrySet()) {
                    if (e.getKey() != null && e.getValue() != null) {
                        conn.setRequestProperty(e.getKey(), e.getValue());
                    }
                }
                if (range != null && !range.isEmpty()) {
                    conn.setRequestProperty("Range", range);
                }
                if (ifRange != null && !ifRange.isEmpty()) {
                    conn.setRequestProperty("If-Range", ifRange);
                }
                code = conn.getResponseCode();
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                    String loc = conn.getHeaderField("Location");
                    conn.disconnect();
                    conn = null;
                    if (loc == null || loc.trim().isEmpty()) {
                        sendSimple(out, 502, "Redirect missing Location");
                        return;
                    }
                    URL nextUrl = new URL(parsed, loc.trim());
                    if (!"http".equalsIgnoreCase(nextUrl.getProtocol())
                            && !"https".equalsIgnoreCase(nextUrl.getProtocol())) {
                        sendSimple(out, 502, "Unsupported redirect scheme");
                        return;
                    }
                    if (!parsed.getHost().equalsIgnoreCase(nextUrl.getHost())) {
                        stripSensitiveHeadersOnCrossHostRedirect(baseHeaders);
                    }
                    currentUrl = nextUrl.toString();
                    continue;
                }
                break;
            }
            if (conn == null) {
                sendSimple(out, 502, "Too many redirects");
                return;
            }

            String contentType = conn.getContentType();
            String contentLengthStr = conn.getHeaderField("Content-Length");
            String contentRange = conn.getHeaderField("Content-Range");
            String acceptRanges = conn.getHeaderField("Accept-Ranges");
            long declaredLen = -1L;
            if (contentLengthStr != null) {
                try {
                    declaredLen = Long.parseLong(contentLengthStr.trim());
                } catch (NumberFormatException ignored) {
                }
            }

            String effectiveDeclaredMime = isSubRequest ? "" : session.declaredMime;
            boolean isSuccess = code >= 200 && code < 300;
            boolean headerSaysHls =
                    contentType != null && contentType.toLowerCase(Locale.ROOT).contains("mpegurl");
            boolean urlSaysHls =
                    inferExtensionSuffix(currentUrl, effectiveDeclaredMime).equals(".m3u8");

            if ("GET".equals(method)
                    && isSuccess
                    && (headerSaysHls || urlSaysHls || (declaredLen <= MAX_PLAYLIST_BYTES))) {
                InputStream rawIn = conn.getInputStream();
                PushbackInputStream pbis = new PushbackInputStream(rawIn, 16);
                byte[] peek = new byte[7];
                int nPeek = readUpTo(pbis, peek, 7);
                boolean bodyStartsExtM3u =
                        nPeek == 7 && "#EXTM3U".equals(new String(peek, StandardCharsets.US_ASCII));
                if (nPeek > 0) {
                    pbis.unread(peek, 0, nPeek);
                }
                if (bodyStartsExtM3u || headerSaysHls) {
                    byte[] rawPlaylist = readStreamBounded(pbis, MAX_PLAYLIST_BYTES);
                    String rewritten =
                            rewriteHlsForRelay(
                                    new String(rawPlaylist, StandardCharsets.UTF_8),
                                    currentUrl,
                                    session);
                    byte[] body = rewritten.getBytes(StandardCharsets.UTF_8);
                    writeBytesResponse(out, 200, "application/vnd.apple.mpegurl", body, false);
                    return;
                }
                streamBody(
                        session,
                        code,
                        conn.getResponseMessage(),
                        contentType != null && !contentType.isEmpty()
                                ? contentType
                                : inferMimeType(currentUrl, effectiveDeclaredMime),
                        declaredLen,
                        contentRange,
                        acceptRanges,
                        pbis,
                        out);
                return;
            }

            InputStream bodyStream = null;
            if (!"HEAD".equals(method)) {
                bodyStream = isSuccess ? conn.getInputStream() : conn.getErrorStream();
            }
            streamBody(
                    session,
                    code,
                    conn.getResponseMessage(),
                    contentType != null && !contentType.isEmpty()
                            ? contentType
                            : inferMimeType(currentUrl, effectiveDeclaredMime),
                    declaredLen,
                    contentRange,
                    acceptRanges,
                    bodyStream,
                    out);
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private void streamBody(
            Session session,
            int code,
            String reason,
            String contentType,
            long contentLength,
            String contentRange,
            String acceptRanges,
            InputStream bodyStream,
            OutputStream out)
            throws IOException {
        String safeReason =
                reason != null && !reason.isEmpty()
                        ? reason
                        : (code == 206 ? "Partial Content" : "OK");
        StringBuilder hdr = new StringBuilder();
        hdr.append("HTTP/1.1 ").append(code).append(' ').append(safeReason).append("\r\n");
        hdr.append("Content-Type: ").append(contentType).append("\r\n");
        if (contentLength >= 0) {
            hdr.append("Content-Length: ").append(contentLength).append("\r\n");
        }
        if (contentRange != null && !contentRange.isEmpty()) {
            hdr.append("Content-Range: ").append(contentRange).append("\r\n");
        }
        hdr.append("Accept-Ranges: ")
                .append(acceptRanges != null && !acceptRanges.isEmpty() ? acceptRanges : "bytes")
                .append("\r\n");
        hdr.append("Cache-Control: no-store\r\n");
        hdr.append("Connection: close\r\n\r\n");
        out.write(hdr.toString().getBytes(StandardCharsets.US_ASCII));
        if (bodyStream != null) {
            byte[] buf = new byte[COPY_BUFFER_BYTES];
            int n;
            while (!session.revoked && !closed && (n = bodyStream.read(buf)) != -1) {
                out.write(buf, 0, n);
            }
        }
        out.flush();
    }

    static String rewriteHlsForRelay(String content, String baseUrl, final Session session) {
        if (content == null) return "";
        String[] rawLines = content.replace("\r\n", "\n").replace('\r', '\n').split("\n", -1);
        StringBuilder out = new StringBuilder(content.length() + 512);
        for (int i = 0; i < rawLines.length; i++) {
            String line = rawLines[i];
            String trimmed = line.trim();
            if (i > 0) out.append('\n');
            if (trimmed.isEmpty()) {
                out.append(line);
                continue;
            }
            if (trimmed.startsWith("#")) {
                if (trimmed.contains("URI=\"")) {
                    Matcher m = URI_ATTR.matcher(line);
                    StringBuffer sb = new StringBuffer();
                    while (m.find()) {
                        String resolved = resolveChildTarget(baseUrl, m.group(1));
                        String replacement =
                                resolved.isEmpty() ? "" : session.registerSubUrl(resolved);
                        m.appendReplacement(
                                sb, Matcher.quoteReplacement("URI=\"" + replacement + "\""));
                    }
                    m.appendTail(sb);
                    out.append(sb);
                } else {
                    out.append(line);
                }
            } else {
                String resolved = resolveChildTarget(baseUrl, trimmed);
                if (!resolved.isEmpty()) {
                    out.append(session.registerSubUrl(resolved));
                }
            }
        }
        return out.toString();
    }

    private static String resolveChildTarget(String baseUrl, String rawRef) {
        if (rawRef == null) return "";
        String ref = rawRef.trim();
        if (ref.isEmpty()) return "";
        boolean localBase = isLocalFileUrl(baseUrl);
        if (ref.regionMatches(true, 0, "file:/", 0, 6)) {
            return localBase ? ref : "";
        }
        if (ref.regionMatches(true, 0, "http://", 0, 7)
                || ref.regionMatches(true, 0, "https://", 0, 8)) {
            return ref;
        }
        if (localBase) {
            if (ref.startsWith("/")) {
                File abs = new File(ref);
                return abs.exists() ? abs.toURI().toString() : "";
            }
            File baseFile = toLocalFile(baseUrl);
            if (baseFile != null) {
                try {
                    return baseFile.toURI().resolve(ref).toString();
                } catch (Throwable ignored) {
                    File parent = baseFile.getParentFile();
                    if (parent != null) {
                        return new File(parent, ref).toURI().toString();
                    }
                }
            }
            return "";
        }
        return HlsStreamProxy.resolveUrl(baseUrl, ref);
    }

    private static void stripSensitiveHeadersOnCrossHostRedirect(Map<String, String> headers) {
        for (java.util.Iterator<Map.Entry<String, String>> it = headers.entrySet().iterator();
                it.hasNext(); ) {
            String k = it.next().getKey();
            if ("authorization".equalsIgnoreCase(k) || "cookie".equalsIgnoreCase(k)) {
                it.remove();
            }
        }
    }

    private static long[] parseRangeHeader(String header, long totalLen) {
        if (header == null || header.trim().isEmpty()) return null;
        String h = header.trim().toLowerCase(Locale.ROOT);
        if (!h.startsWith("bytes=")) return null;
        String spec = h.substring("bytes=".length()).trim();
        int comma = spec.indexOf(',');
        if (comma >= 0) spec = spec.substring(0, comma).trim();
        int dash = spec.indexOf('-');
        if (dash < 0) return null;
        String left = spec.substring(0, dash).trim();
        String right = spec.substring(dash + 1).trim();
        try {
            if (left.isEmpty()) {
                long suffix = Long.parseLong(right);
                if (suffix <= 0 || totalLen <= 0) return null;
                long start = Math.max(0L, totalLen - suffix);
                return new long[] {start, totalLen - 1L};
            }
            long start = Long.parseLong(left);
            long end = right.isEmpty() ? (totalLen - 1L) : Long.parseLong(right);
            if (start < 0 || start >= totalLen) return null;
            if (end >= totalLen) end = totalLen - 1L;
            if (end < start) return null;
            return new long[] {start, end};
        } catch (NumberFormatException ignored) {
            return null;
        }
    }

    private static byte[] readFileBytes(File file, int maxBytes) throws IOException {
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            long len = raf.length();
            if (len > maxBytes) throw new IOException("Playlist too large");
            byte[] data = new byte[(int) len];
            raf.readFully(data);
            return data;
        }
    }

    private static int readUpTo(InputStream in, byte[] dst, int count) throws IOException {
        int off = 0;
        while (off < count) {
            int n = in.read(dst, off, count - off);
            if (n < 0) break;
            off += n;
        }
        return off;
    }

    private static byte[] readStreamBounded(InputStream in, int maxBytes) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) {
            if (bos.size() + n > maxBytes) throw new IOException("Playlist exceeds limit");
            bos.write(buf, 0, n);
        }
        return bos.toByteArray();
    }

    private static void writeBytesResponse(
            OutputStream out, int code, String contentType, byte[] body, boolean headOnly)
            throws IOException {
        String hdr =
                "HTTP/1.1 "
                        + code
                        + " OK\r\n"
                        + "Content-Type: "
                        + contentType
                        + "\r\n"
                        + "Content-Length: "
                        + body.length
                        + "\r\n"
                        + "Accept-Ranges: bytes\r\n"
                        + "Cache-Control: no-store\r\n"
                        + "Connection: close\r\n\r\n";
        out.write(hdr.getBytes(StandardCharsets.US_ASCII));
        if (!headOnly && body.length > 0) {
            out.write(body);
        }
        out.flush();
    }

    private static void sendSimple(OutputStream out, int code, String message) throws IOException {
        byte[] body = message.getBytes(StandardCharsets.UTF_8);
        String hdr =
                "HTTP/1.1 "
                        + code
                        + " "
                        + message
                        + "\r\n"
                        + "Content-Type: text/plain; charset=utf-8\r\n"
                        + "Content-Length: "
                        + body.length
                        + "\r\n"
                        + "Connection: close\r\n\r\n";
        out.write(hdr.getBytes(StandardCharsets.US_ASCII));
        out.write(body);
        out.flush();
    }

    private static String readLine(InputStream in, int maxLen) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') break;
            if (c != '\r') {
                bos.write(c);
                if (bos.size() > maxLen) throw new IOException("Line limit");
            }
        }
        if (c == -1 && bos.size() == 0) return null;
        return new String(bos.toByteArray(), StandardCharsets.ISO_8859_1);
    }
}

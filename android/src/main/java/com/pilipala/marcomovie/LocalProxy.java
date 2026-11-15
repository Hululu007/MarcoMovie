package com.pilipala.marcomovie;

import android.app.Application;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.JSONObject;

/** Independent loopback-only implementation of the observed CSP HTTP response ABI. */
public final class LocalProxy implements Closeable {
    static boolean loopbackHost(String host) {
        return ProxyAddress.isLoopbackHost(host);
    }

    final Application app;
    final Cms.Config config;
    final ServerSocket server;
    final String token = UUID.randomUUID().toString().replace("-", "");
    final ThreadPoolExecutor requests =
            new ThreadPoolExecutor(4, 32, 60, TimeUnit.SECONDS, new SynchronousQueue<Runnable>());
    final Map<Socket, RequestScope> activeRequests = new ConcurrentHashMap<>();

    interface ScriptResolver {
        Object[] resolve(Map<String, String> params) throws Exception;
    }

    interface SourceResolver {
        Object[] resolve(Application app, Cms.Config config, Map<String, String> params)
                throws Exception;
    }

    private final ScriptResolver scripts;
    private final SourceResolver sources;
    volatile boolean closed;

    public LocalProxy(Application application, Cms.Config source) throws IOException {
        this(application, source, JsEngine::proxyFor, CspEngine::proxy);
    }

    LocalProxy(Application application, Cms.Config source, ScriptResolver scripts)
            throws IOException {
        this(application, source, scripts, CspEngine::proxy);
    }

    LocalProxy(
            Application application,
            Cms.Config source,
            ScriptResolver scripts,
            SourceResolver sources)
            throws IOException {
        ProxyAddress.ensureLoopbackDirectProxySelector();
        app = application;
        config = source;
        this.scripts = scripts;
        this.sources = sources;
        server = bind();
        ProxyAddress.port = server.getLocalPort();
        ProxyAddress.token = token;
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed)
                                try {
                                    Socket socket = server.accept();
                                    RequestScope scope = new RequestScope();
                                    activeRequests.put(socket, scope);
                                    try {
                                        if (closed) throw new RejectedExecutionException();
                                        requests.execute(
                                                () -> {
                                                    try {
                                                        scope.call(
                                                                () -> {
                                                                    serve(socket);
                                                                    return null;
                                                                });
                                                    } catch (Exception ignored) {
                                                    } finally {
                                                        scope.cancel();
                                                        activeRequests.remove(socket);
                                                        try {
                                                            socket.close();
                                                        } catch (IOException ignored) {
                                                        }
                                                    }
                                                });
                                    } catch (RejectedExecutionException full) {
                                        activeRequests.remove(socket);
                                        scope.cancel();
                                        socket.close();
                                    }
                                } catch (IOException e) {
                                    if (!closed) close();
                                }
                        },
                        "movie-loopback-proxy");
        accept.setDaemon(true);
        accept.start();
    }

    static ServerSocket bind() throws IOException {
        ServerSocket socket = new ServerSocket();
        try {
            socket.setReuseAddress(true);
            socket.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 9978));
            return socket;
        } catch (BindException occupied) {
            socket.close();
            ServerSocket fallback = new ServerSocket();
            try {
                fallback.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0));
                return fallback;
            } catch (IOException failure) {
                fallback.close();
                throw failure;
            }
        } catch (IOException error) {
            socket.close();
            throw error;
        }
    }

    static String address() {
        return ProxyAddress.base();
    }

    /** Only the CSP host's reserved /proxy URLs are relocated, never arbitrary loopback services. */
    static String rewrite(String value) {
        return ProxyAddress.rewrite(value, ProxyAddress.port, ProxyAddress.token);
    }

    static String line(InputStream in, int limit) throws IOException {
        String s = lineOrNull(in, limit);
        return s == null ? "" : s;
    }

    private static String lineOrNull(InputStream in, int limit) throws IOException {
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

    private static final class BodyPayload {
        final InputStream stream;
        final byte[] fixedBytes;

        BodyPayload(InputStream stream, byte[] fixedBytes) {
            this.stream = stream;
            this.fixedBytes = fixedBytes;
        }
    }

    private static BodyPayload extractBody(Object raw) throws UnsupportedEncodingException {
        if (raw instanceof InputStream) {
            return new BodyPayload((InputStream) raw, null);
        }
        if (raw instanceof byte[]) {
            byte[] b = (byte[]) raw;
            return new BodyPayload(new ByteArrayInputStream(b), b);
        }
        if (raw instanceof java.nio.ByteBuffer) {
            java.nio.ByteBuffer buf = ((java.nio.ByteBuffer) raw).slice();
            byte[] b = new byte[buf.remaining()];
            buf.get(b);
            return new BodyPayload(new ByteArrayInputStream(b), b);
        }
        byte[] b = raw == null ? new byte[0] : raw.toString().getBytes("UTF-8");
        return new BodyPayload(new ByteArrayInputStream(b), b);
    }

    private static String extractHeaderIgnoreCase(Object headersObj, String targetKey) {
        if (!(headersObj instanceof Map)) return null;
        for (Map.Entry<?, ?> e : ((Map<?, ?>) headersObj).entrySet()) {
            if (e.getKey() != null
                    && String.valueOf(e.getKey()).equalsIgnoreCase(targetKey)
                    && e.getValue() != null) {
                return String.valueOf(e.getValue());
            }
        }
        return null;
    }

    private static String reasonPhrase(int code) {
        switch (code) {
            case 200:
                return "OK";
            case 206:
                return "Partial Content";
            case 301:
                return "Moved Permanently";
            case 302:
                return "Found";
            case 303:
                return "See Other";
            case 307:
                return "Temporary Redirect";
            case 308:
                return "Permanent Redirect";
            case 400:
                return "Bad Request";
            case 403:
                return "Forbidden";
            case 404:
                return "Not Found";
            case 416:
                return "Range Not Satisfiable";
            case 502:
                return "Bad Gateway";
            default:
                return "Response";
        }
    }

    static long[] parseContentRange(String contentRange) {
        if (contentRange == null) return null;
        // e.g. "bytes 0-1048575/4582918231"
        String s = contentRange.trim();
        if (!s.regionMatches(true, 0, "bytes ", 0, 6)) return null;
        int slash = s.indexOf('/');
        String rangePart = (slash > 6 ? s.substring(6, slash) : s.substring(6)).trim();
        String totalPart = slash > 6 ? s.substring(slash + 1).trim() : "*";
        int dash = rangePart.indexOf('-');
        if (dash <= 0 || dash >= rangePart.length() - 1) return null;
        try {
            long start = Long.parseLong(rangePart.substring(0, dash).trim());
            long end = Long.parseLong(rangePart.substring(dash + 1).trim());
            long total = "*".equals(totalPart) ? -1L : Long.parseLong(totalPart);
            if (end >= start && start >= 0) return new long[] {start, end, total};
        } catch (NumberFormatException ignored) {
        }
        return null;
    }

    private static long parseClientRequestedEnd(String rangeHeader) {
        if (rangeHeader == null) return -1L;
        String s = rangeHeader.trim();
        if (!s.regionMatches(true, 0, "bytes=", 0, 6)) return -1L;
        int dash = s.indexOf('-', 6);
        if (dash < 0 || dash >= s.length() - 1) return -1L;
        String endPart = s.substring(dash + 1).trim();
        int comma = endPart.indexOf(',');
        if (comma >= 0) endPart = endPart.substring(0, comma).trim();
        if (endPart.isEmpty()) return -1L;
        try {
            return Long.parseLong(endPart);
        } catch (NumberFormatException ignored) {
            return -1L;
        }
    }

    void serve(Socket socket) {
        try (Socket connection = socket) {
            if (connection.getInetAddress() == null
                    || !connection.getInetAddress().isLoopbackAddress()) return;
            try {
                connection.setTcpNoDelay(true);
            } catch (SocketException ignored) {
            }
            connection.setSoTimeout(30000);
            InputStream in = new BufferedInputStream(connection.getInputStream(), 8192);
            OutputStream out = new BufferedOutputStream(connection.getOutputStream(), 64 * 1024);
            boolean firstRequest = true;
            int emptyLeadingLines = 0;
            while (!closed) {
                if (!firstRequest) {
                    connection.setSoTimeout(15000);
                }
                String requestLine = lineOrNull(in, 8192);
                if (requestLine == null) break;
                if (requestLine.isEmpty()) {
                    if (++emptyLeadingLines > 2) break;
                    continue;
                }
                emptyLeadingLines = 0;
                if (!firstRequest) {
                    connection.setSoTimeout(30000);
                }
                firstRequest = false;
                if (!serveSingleRequest(requestLine, in, out)) {
                    break;
                }
            }
        } catch (Exception ignored) {
        }
    }

    private boolean serveSingleRequest(String requestLine, InputStream in, OutputStream out)
            throws Exception {
        String[] request = requestLine.split(" ");
        if (request.length < 2) return false;
        String method = request[0];
        String rawTarget = request[1];
        String protocol = request.length >= 3 ? request[2] : "HTTP/1.1";
        int qAt = rawTarget.indexOf('?');
        String path = qAt >= 0 ? rawTarget.substring(0, qAt) : rawTarget;
        String query = qAt >= 0 ? rawTarget.substring(qAt + 1) : null;
        if (!"/proxy".equals(path) || (!method.equals("GET") && !method.equals("HEAD"))) {
            simple(out, 404, "Not found");
            return false;
        }
        Map<String, String> headers = new LinkedHashMap<>();
        Map<String, String> params = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        Map<String, String> queryParams = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        boolean duplicateQuery = false;
        int size = 0;
        for (; ; ) {
            String h = lineOrNull(in, 8192);
            if (h == null) return false;
            size += h.length();
            if (size > 32768) throw new IOException("Headers too large");
            if (h.isEmpty()) break;
            int at = h.indexOf(':');
            if (at > 0) {
                String rawKey = h.substring(0, at).trim();
                String lowerKey = rawKey.toLowerCase(Locale.ROOT);
                String val = h.substring(at + 1).trim();
                headers.put(lowerKey, val);
                params.put(rawKey, val);
            }
        }
        boolean chunkedClient = "1".equals(headers.remove("x-movie-chunked-client"));
        params.remove("x-movie-chunked-client");
        String connHeader = headers.get("connection");
        boolean clientWantsClose =
                "close".equalsIgnoreCase(connHeader)
                        || ("HTTP/1.0".equalsIgnoreCase(protocol)
                                && !"keep-alive".equalsIgnoreCase(connHeader));

        if (query != null) {
            for (String pair : query.split("&")) {
                if (pair.isEmpty()) continue;
                String[] p = pair.split("=", 2);
                try {
                    String key = URLDecoder.decode(p[0], "UTF-8");
                    String value = p.length == 2 ? URLDecoder.decode(p[1], "UTF-8") : "";
                    if (queryParams.containsKey(key)
                            && Arrays.asList("do", "site", "sitekey", "_mm_token")
                                    .contains(key.toLowerCase(Locale.ROOT))) duplicateQuery = true;
                    queryParams.put(key, value);
                    params.put(key, value);
                } catch (Exception ignored) {
                    params.put(p[0], p.length == 2 ? p[1] : "");
                }
            }
        }
        String requestToken = params.remove("_mm_token");
        boolean isJs =
                "js".equalsIgnoreCase(params.get("do")) || "py".equalsIgnoreCase(params.get("do"));
        if (isJs) {
            String route = queryParams.get("do");
            String key = queryParams.get("py".equalsIgnoreCase(route) ? "siteKey" : "site");
            if (duplicateQuery
                    || !("js".equalsIgnoreCase(route) || "py".equalsIgnoreCase(route))
                    || key == null
                    || !key.matches("[a-f0-9]{32}")) {
                simple(out, 400, "Invalid script route");
                return false;
            }
            requestToken = queryParams.get("_mm_token");
        }
        if (!ProxyAddress.isAllowedRequest(
                headers.get("host"),
                headers.get("origin"),
                headers.get("sec-fetch-site"),
                requestToken,
                token,
                isJs)) {
            simple(out, 403, "Forbidden");
            return false;
        }
        if ("ck".equalsIgnoreCase(params.get("do"))) {
            simple(out, 200, "ok");
            return false;
        }
        String upstreamOrigin = headers.remove("x-movie-origin");
        params.remove("x-movie-origin");
        if (upstreamOrigin != null && !upstreamOrigin.isEmpty()) {
            headers.put("origin", upstreamOrigin);
            params.put("Origin", upstreamOrigin);
        }
        String upstreamHost = headers.remove("x-movie-host");
        params.remove("x-movie-host");
        if (upstreamHost != null && !upstreamHost.isEmpty()) {
            headers.put("host", upstreamHost);
            params.put("Host", upstreamHost);
        }
        if (headers.containsKey("range")) {
            headers.put("Range", headers.get("range"));
        }
        if (headers.containsKey("user-agent")) {
            headers.put("User-Agent", headers.get("user-agent"));
        }
        if (headers.containsKey("cookie")) {
            headers.put("Cookie", headers.get("cookie"));
        }
        if (headers.containsKey("referer")) {
            headers.put("Referer", headers.get("referer"));
        }
        params.put("request-headers", new JSONObject(headers).toString());
        if (isJs) {
            // Python/JS dictionaries are case-sensitive even though HTTP names are not.
            Map<String, String> scriptParams = new LinkedHashMap<>(params);
            for (Map.Entry<String, String> header : headers.entrySet()) {
                String key = header.getKey().toLowerCase(Locale.ROOT);
                if (!Arrays.asList("do", "site", "sitekey", "_mm_token").contains(key))
                    scriptParams.put(key, header.getValue());
            }
            scriptParams.put("do", queryParams.get("do").toLowerCase(Locale.ROOT));
            String routeKey = "py".equals(scriptParams.get("do")) ? "siteKey" : "site";
            scriptParams.put(routeKey, queryParams.get(routeKey));
            params = scriptParams;
        }
        Object[] response;
        try {
            response = isJs ? scripts.resolve(params) : sources.resolve(app, config, params);
        } catch (Throwable e) {
            AppLog.w("LocalProxy", "source proxy failed", e);
            simple(out, 502, "Source proxy failed");
            return false;
        }
        if (response == null || response.length < 3 || !(response[0] instanceof Number)) {
            simple(out, 502, "Invalid source response");
            return false;
        }
        int code = ((Number) response[0]).intValue();
        if (code < 100 || code > 599) code = 502;
        String mime = String.valueOf(response[1]);
        BodyPayload bodyPayload = extractBody(response[2]);
        byte[] fixedBytes = bodyPayload.fixedBytes;
        InputStream body = bodyPayload.stream;

        long contentLength = fixedBytes != null ? fixedBytes.length : -1L;
        String contentRange = null;
        boolean hasAcceptRanges = false;
        Map<String, String> extraHeaders = new LinkedHashMap<>();
        if (response.length > 3 && response[3] instanceof Map) {
            Set<String> scriptHopHeaders =
                    new HashSet<>(
                            Arrays.asList(
                                    "connection",
                                    "keep-alive",
                                    "proxy-authenticate",
                                    "proxy-authorization",
                                    "te",
                                    "trailer",
                                    "transfer-encoding",
                                    "upgrade",
                                    "set-cookie",
                                    "set-cookie2"));
            if (isJs)
                for (Map.Entry<?, ?> e : ((Map<?, ?>) response[3]).entrySet())
                    if (String.valueOf(e.getKey()).equalsIgnoreCase("Connection"))
                        for (String name : String.valueOf(e.getValue()).split(","))
                            scriptHopHeaders.add(name.trim().toLowerCase(Locale.ROOT));
            for (Object item : ((Map<?, ?>) response[3]).entrySet()) {
                Map.Entry<?, ?> e = (Map.Entry<?, ?>) item;
                String k = String.valueOf(e.getKey());
                String v = String.valueOf(e.getValue());
                if (!safe(k) || !safe(v)) continue;
                if (isJs
                        && (scriptHopHeaders.contains(k.toLowerCase(Locale.ROOT))
                                || k.toLowerCase(Locale.ROOT).startsWith("access-control-")))
                    continue;
                if (k.equalsIgnoreCase("Content-Length")) {
                    if (isJs) {
                        if (method.equals("HEAD")) {
                            try {
                                long declared = Long.parseLong(v.trim());
                                if (declared < 0 || declared > 9007199254740991L)
                                    throw new NumberFormatException();
                                contentLength = declared;
                            } catch (NumberFormatException invalid) {
                                simple(out, 502, "Invalid script HEAD length");
                                return false;
                            }
                        }
                        continue; // GET always uses the buffered body's exact byte length.
                    }
                    try {
                        long parsed = Long.parseLong(v.trim());
                        if (parsed >= 0) contentLength = parsed;
                    } catch (NumberFormatException ignored) {
                    }
                } else if (k.equalsIgnoreCase("Content-Range")) {
                    contentRange = v.trim();
                    extraHeaders.put("Content-Range", contentRange);
                } else if (k.equalsIgnoreCase("Accept-Ranges")) {
                    hasAcceptRanges = true;
                    extraHeaders.put("Accept-Ranges", v.trim());
                } else if (!k.equalsIgnoreCase("Transfer-Encoding")
                        && !k.equalsIgnoreCase("Connection")
                        && !k.equalsIgnoreCase("Content-Type")) {
                    extraHeaders.put(k, v);
                }
            }
        }
        long[] cr = parseContentRange(contentRange);
        if (isJs
                && code == 206
                && (cr == null
                        || fixedBytes == null
                        || !contentRange.matches("bytes [0-9]+-[0-9]+/([0-9]+|\\*)")
                        || (!contentRange.endsWith("/*") && (cr[2] <= 0 || cr[1] >= cr[2]))
                        || (!method.equals("HEAD") && cr[1] - cr[0] + 1 != fixedBytes.length))) {
            simple(out, 502, "Invalid script byte range");
            return false;
        }
        if (isJs && code == 206 && method.equals("HEAD")) contentLength = cr[1] - cr[0] + 1;
        if (isJs && code == 200) extraHeaders.remove("Content-Range");
        long clientReqEnd = parseClientRequestedEnd(headers.get("range"));
        long desiredEnd = -1L;
        boolean chainChunks = false;
        if (cr != null) {
            if (contentLength < 0) {
                contentLength = (cr[1] - cr[0]) + 1L;
            }
            if (!isJs && code == 206 && clientReqEnd >= cr[0] && cr[1] > clientReqEnd) {
                long clampedLen = (clientReqEnd - cr[0]) + 1L;
                if (fixedBytes == null || fixedBytes.length >= clampedLen) {
                    cr[1] = clientReqEnd;
                    contentRange =
                            "bytes "
                                    + cr[0]
                                    + "-"
                                    + cr[1]
                                    + "/"
                                    + (cr[2] > 0 ? String.valueOf(cr[2]) : "*");
                    extraHeaders.put("Content-Range", contentRange);
                    contentLength = clampedLen;
                }
            }
            if (!chunkedClient && !isJs && code == 206 && cr[2] > 0) {
                desiredEnd =
                        clientReqEnd >= cr[0] ? Math.min(clientReqEnd, cr[2] - 1L) : (cr[2] - 1L);
                if (cr[1] < desiredEnd) {
                    chainChunks = true;
                    extraHeaders.put(
                            "Content-Range", "bytes " + cr[0] + "-" + desiredEnd + "/" + cr[2]);
                    contentLength = (desiredEnd - cr[0]) + 1L;
                }
            }
        }

        boolean keepAlive =
                !closed && !clientWantsClose && !chainChunks && requests.getActiveCount() < 24;

        try (InputStream payload = body) {
            StringBuilder head =
                    new StringBuilder("HTTP/1.1 ")
                            .append(code)
                            .append(' ')
                            .append(reasonPhrase(code))
                            .append("\r\nConnection: ")
                            .append(keepAlive ? "keep-alive" : "close")
                            .append("\r\n");
            if (safe(mime)) head.append("Content-Type: ").append(mime).append("\r\n");
            if (!hasAcceptRanges && (!isJs || code == 206) && (code == 200 || code == 206)) {
                head.append("Accept-Ranges: bytes\r\n");
            }
            for (Map.Entry<String, String> e : extraHeaders.entrySet()) {
                head.append(e.getKey()).append(": ").append(e.getValue()).append("\r\n");
            }
            boolean useChunked = contentLength < 0;
            if (useChunked) {
                head.append("Transfer-Encoding: chunked\r\n\r\n");
            } else {
                head.append("Content-Length: ").append(contentLength).append("\r\n\r\n");
            }
            out.write(head.toString().getBytes("ISO-8859-1"));
            if (!method.equals("HEAD")) {
                byte[] buffer = new byte[64 * 1024];
                int n;
                if (useChunked) {
                    while ((n = payload.read(buffer)) != -1) {
                        if (n == 0) continue;
                        out.write((Integer.toHexString(n) + "\r\n").getBytes("US-ASCII"));
                        out.write(buffer, 0, n);
                        out.write(new byte[] {13, 10});
                    }
                    out.write("0\r\n\r\n".getBytes("US-ASCII"));
                } else {
                    long remaining = contentLength;
                    long currentOffset = cr != null ? cr[0] : 0L;
                    while (remaining > 0
                            && (n =
                                            payload.read(
                                                    buffer,
                                                    0,
                                                    (int) Math.min(buffer.length, remaining)))
                                    != -1) {
                        if (n == 0) continue;
                        out.write(buffer, 0, n);
                        remaining -= n;
                        currentOffset += n;
                    }
                    while (chainChunks && remaining > 0 && !closed) {
                        String nextRange =
                                "bytes="
                                        + currentOffset
                                        + "-"
                                        + (clientReqEnd >= currentOffset ? clientReqEnd : "");
                        headers.put("range", nextRange);
                        headers.put("Range", nextRange);
                        params.put("Range", nextRange);
                        params.put("request-headers", new JSONObject(headers).toString());
                        Object[] nextResp =
                                isJs
                                        ? scripts.resolve(params)
                                        : sources.resolve(app, config, params);
                        if (nextResp == null
                                || nextResp.length < 3
                                || !(nextResp[0] instanceof Number)) {
                            break;
                        }
                        int nextCode = ((Number) nextResp[0]).intValue();
                        if (nextCode != 206 && nextCode != 200) {
                            break;
                        }
                        long skipBytes = 0L;
                        if (nextResp.length > 3) {
                            long[] nextCr =
                                    parseContentRange(
                                            extractHeaderIgnoreCase(nextResp[3], "Content-Range"));
                            if (nextCr != null) {
                                if (nextCr[0] > currentOffset || nextCr[1] < currentOffset) {
                                    break;
                                }
                                skipBytes = currentOffset - nextCr[0];
                            }
                        }
                        BodyPayload nextPayload = extractBody(nextResp[2]);
                        long chunkRead = 0L;
                        try (InputStream nextStream = nextPayload.stream) {
                            while (skipBytes > 0L) {
                                int skipped =
                                        nextStream.read(
                                                buffer,
                                                0,
                                                (int) Math.min((long) buffer.length, skipBytes));
                                if (skipped < 0) break;
                                skipBytes -= skipped;
                            }
                            if (skipBytes > 0L) break;
                            while (remaining > 0
                                    && (n =
                                                    nextStream.read(
                                                            buffer,
                                                            0,
                                                            (int)
                                                                    Math.min(
                                                                            buffer.length,
                                                                            remaining)))
                                            != -1) {
                                if (n == 0) continue;
                                out.write(buffer, 0, n);
                                remaining -= n;
                                currentOffset += n;
                                chunkRead += n;
                            }
                        }
                        if (chunkRead <= 0L) break;
                    }
                    if (remaining > 0L) {
                        keepAlive = false;
                    }
                }
            }
            out.flush();
            return keepAlive;
        }
    }

    static boolean safe(String s) {
        return s != null && s.indexOf('\r') < 0 && s.indexOf('\n') < 0;
    }

    static void simple(OutputStream o, int status, String message) throws IOException {
        byte[] b = message.getBytes("UTF-8");
        o.write(
                ("HTTP/1.1 "
                                + status
                                + " "
                                + reasonPhrase(status)
                                + "\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: "
                                + b.length
                                + "\r\n\r\n")
                        .getBytes("US-ASCII"));
        o.write(b);
        o.flush();
    }

    public void close() {
        closed = true;
        try {
            server.close();
        } catch (IOException ignored) {
        }
        for (Map.Entry<Socket, RequestScope> request : activeRequests.entrySet()) {
            request.getValue().cancel();
            try {
                request.getKey().close();
            } catch (IOException ignored) {
            }
        }
        requests.shutdownNow();
    }
}

package com.pilipala.marcomovie;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Authenticated, preemptive, bounded-prefetch loopback Range media proxy.
 *
 * <p>Direct Java counterpart to iOS 0.7.7 {@code CloudMediaLease} and {@code NetdiskRangeProxy}:
 *
 * <ul>
 *   <li>Multi-worker concurrent chunk prefetch ({@code 6 workers × 1 MiB}) capped at {@code 24 MiB}
 *       buffered bytes.
 *   <li>Generation-based instant seek preemption: every new Range GET increments the lease
 *       generation and immediately aborts in-flight upstream connections from the previous window,
 *       preventing head-probe downloads from starving 40 GiB MKV tail Cues seeks.
 *   <li>Strict {@code 206 Partial Content} + exact {@code Content-Range} validation on every chunk
 *       so misaligned, full-body 200, or late-arriving stale responses can never overwrite or
 *       corrupt the active seek position.
 *   <li>Live {@link AccessGuard} verification on every request & chunk so switching personal cloud
 *       accounts immediately revokes old playback leases.
 * </ul>
 */
final class CloudMediaProxy implements Closeable {
    static final int DEFAULT_CHUNK_WORKERS = 6;
    static final int DEFAULT_CHUNK_SIZE = 1024 * 1024; // 1 MiB
    static final long DEFAULT_MAX_BUFFERED_BYTES = 24L * 1024 * 1024; // 24 MiB

    interface AccessGuard {
        boolean isCurrent();
    }

    static final class LeaseMetrics {
        final AtomicInteger cancelledWindows = new AtomicInteger();
        final AtomicInteger preemptedRequests = new AtomicInteger();
        final AtomicInteger rejectedRangeResponses = new AtomicInteger();
        final AtomicInteger completedChunks = new AtomicInteger();
        final AtomicLong currentBufferedBytes = new AtomicLong();
        final AtomicLong peakBufferedBytes = new AtomicLong();
        final AtomicReference<String> lastServedRange = new AtomicReference<>("");

        void recordReserve(long bytes) {
            long now = currentBufferedBytes.addAndGet(bytes);
            long prev;
            while (now > (prev = peakBufferedBytes.get())) {
                if (peakBufferedBytes.compareAndSet(prev, now)) break;
            }
        }

        void recordRelease(long bytes) {
            long next = currentBufferedBytes.addAndGet(-bytes);
            if (next < 0) currentBufferedBytes.set(0);
        }
    }

    static final class RangeWindow {
        final long generation;
        final AtomicBoolean cancelled = new AtomicBoolean(false);
        final ConcurrentHashMap<HttpURLConnection, Boolean> activeConnections =
                new ConcurrentHashMap<>();

        RangeWindow(long generation) {
            this.generation = generation;
        }

        void cancel() {
            if (cancelled.compareAndSet(false, true)) {
                for (HttpURLConnection conn : activeConnections.keySet()) {
                    try {
                        conn.disconnect();
                    } catch (Throwable ignored) {
                    }
                }
                activeConnections.clear();
            }
        }
    }

    static final class Lease {
        final String id;
        final String token;
        final String upstreamUrl;
        final Map<String, String> upstreamHeaders;
        final AccessGuard accessGuard;
        final int chunkSize;
        final int chunkWorkers;
        final long maxBufferedBytes;
        final LeaseMetrics metrics = new LeaseMetrics();
        final AtomicLong activeGeneration = new AtomicLong(0L);
        final AtomicReference<RangeWindow> currentWindow = new AtomicReference<>();
        final Object bufferLock = new Object();
        volatile long knownTotalSize = -1L;
        volatile String knownContentType = "application/octet-stream";
        volatile boolean revoked;

        Lease(
                String id,
                String token,
                String upstreamUrl,
                Map<String, String> upstreamHeaders,
                AccessGuard accessGuard,
                int chunkSize,
                int chunkWorkers,
                long maxBufferedBytes) {
            this.id = id;
            this.token = token;
            this.upstreamUrl = upstreamUrl;
            this.upstreamHeaders =
                    upstreamHeaders == null
                            ? Collections.<String, String>emptyMap()
                            : Collections.unmodifiableMap(new LinkedHashMap<>(upstreamHeaders));
            this.accessGuard = accessGuard;
            this.chunkSize = Math.max(4096, chunkSize);
            this.chunkWorkers = Math.max(1, Math.min(8, chunkWorkers));
            this.maxBufferedBytes = Math.max(this.chunkSize * 2L, maxBufferedBytes);
        }

        boolean isAuthorized() {
            return !revoked && (accessGuard == null || accessGuard.isCurrent());
        }

        void revoke() {
            revoked = true;
            RangeWindow prev = currentWindow.getAndSet(null);
            if (prev != null) {
                prev.cancel();
                metrics.cancelledWindows.incrementAndGet();
            }
            synchronized (bufferLock) {
                bufferLock.notifyAll();
            }
        }

        RangeWindow openNextWindow() {
            long gen = activeGeneration.incrementAndGet();
            RangeWindow next = new RangeWindow(gen);
            RangeWindow prev = currentWindow.getAndSet(next);
            if (prev != null) {
                prev.cancel();
                metrics.cancelledWindows.incrementAndGet();
                metrics.preemptedRequests.incrementAndGet();
            }
            synchronized (bufferLock) {
                bufferLock.notifyAll();
            }
            return next;
        }

        boolean isWindowCurrent(RangeWindow window) {
            return window != null
                    && !window.cancelled.get()
                    && activeGeneration.get() == window.generation
                    && isAuthorized();
        }
    }

    private static volatile CloudMediaProxy sharedInstance;

    static synchronized CloudMediaProxy shared() throws IOException {
        if (sharedInstance == null || sharedInstance.closed) {
            sharedInstance = new CloudMediaProxy();
        }
        return sharedInstance;
    }

    private final ServerSocket server;
    private final Map<String, Lease> leases = new ConcurrentHashMap<>();
    private final ThreadPoolExecutor connectionPool =
            new ThreadPoolExecutor(
                    0,
                    64,
                    30,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<Runnable>(),
                    r -> {
                        Thread t = new Thread(r, "marco-cloud-proxy-conn");
                        t.setDaemon(true);
                        return t;
                    });
    private final ExecutorService chunkPool =
            Executors.newCachedThreadPool(
                    r -> {
                        Thread t = new Thread(r, "marco-cloud-proxy-chunk");
                        t.setDaemon(true);
                        return t;
                    });
    private volatile boolean closed;

    CloudMediaProxy() throws IOException {
        this.server = new ServerSocket();
        this.server.setReuseAddress(true);
        this.server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0));
        Thread accept =
                new Thread(
                        () -> {
                            while (!closed) {
                                try {
                                    Socket sock = server.accept();
                                    connectionPool.execute(() -> serve(sock));
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
                        "marco-cloud-proxy-accept");
        accept.setDaemon(true);
        accept.start();
    }

    int getPort() {
        return server.getLocalPort();
    }

    Lease createLease(String upstreamUrl, Map<String, String> headers, AccessGuard accessGuard) {
        return createLease(
                upstreamUrl,
                headers,
                accessGuard,
                DEFAULT_CHUNK_SIZE,
                DEFAULT_CHUNK_WORKERS,
                DEFAULT_MAX_BUFFERED_BYTES);
    }

    Lease createLease(
            String upstreamUrl,
            Map<String, String> headers,
            AccessGuard accessGuard,
            int chunkSize,
            int chunkWorkers,
            long maxBufferedBytes) {
        String id = UUID.randomUUID().toString().replace("-", "");
        String token = UUID.randomUUID().toString().replace("-", "");
        Lease lease =
                new Lease(
                        id,
                        token,
                        upstreamUrl,
                        headers,
                        accessGuard,
                        chunkSize,
                        chunkWorkers,
                        maxBufferedBytes);
        leases.put(id, lease);
        return lease;
    }

    String leaseUrl(Lease lease) {
        return "http://127.0.0.1:" + getPort() + "/cloud/" + lease.id + "?_cm_token=" + lease.token;
    }

    void releaseLease(Lease lease) {
        if (lease == null) return;
        lease.revoke();
        leases.remove(lease.id);
    }

    void revokeAll() {
        for (Lease l : leases.values()) {
            l.revoke();
        }
        leases.clear();
    }

    private void serve(Socket socket) {
        try (Socket s = socket) {
            if (s.getInetAddress() == null || !s.getInetAddress().isLoopbackAddress()) return;
            try {
                s.setTcpNoDelay(true);
            } catch (Throwable ignored) {
            }
            s.setSoTimeout(30_000);
            InputStream in = new BufferedInputStream(s.getInputStream(), 8192);
            OutputStream out = new BufferedOutputStream(s.getOutputStream(), 64 * 1024);

            String reqLine = readLine(in, 4096);
            if (reqLine == null || reqLine.isEmpty()) return;
            String[] parts = reqLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0].trim().toUpperCase(Locale.ROOT);
            if (!"GET".equals(method) && !"HEAD".equals(method)) {
                sendError(out, 405, "Method Not Allowed");
                return;
            }
            String rawTarget = parts[1].trim();
            int q = rawTarget.indexOf('?');
            String path = q >= 0 ? rawTarget.substring(0, q) : rawTarget;
            String query = q >= 0 ? rawTarget.substring(q + 1) : "";

            Map<String, String> headers = new HashMap<>();
            for (; ; ) {
                String line = readLine(in, 4096);
                if (line == null || line.isEmpty()) break;
                int colon = line.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            line.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            line.substring(colon + 1).trim());
                }
            }

            if (!path.startsWith("/cloud/")) {
                sendError(out, 404, "Not Found");
                return;
            }
            String leaseId = path.substring("/cloud/".length());
            Lease lease = leases.get(leaseId);
            String token = extractQueryParam(query, "_cm_token");
            if (lease == null || !lease.token.equals(token)) {
                sendError(out, 403, "Forbidden");
                return;
            }
            if (!lease.isAuthorized()) {
                lease.revoke();
                sendError(out, 403, "Account session revoked");
                return;
            }

            String rangeHeader = headers.get("range");
            RangeSpec reqRange = parseClientRange(rangeHeader);
            if (reqRange == null) {
                // Default to open-ended from byte 0
                reqRange = new RangeSpec(0L, -1L, false);
            }

            RangeWindow window =
                    "GET".equals(method)
                            ? lease.openNextWindow()
                            : new RangeWindow(lease.activeGeneration.get());

            try {
                handleRangeRequest(lease, window, method, reqRange, out);
            } finally {
                if ("GET".equals(method)) {
                    window.cancel();
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private void handleRangeRequest(
            final Lease lease,
            final RangeWindow window,
            String method,
            RangeSpec reqRange,
            OutputStream out)
            throws Exception {
        long start = reqRange.start;
        long initialEnd =
                reqRange.end >= start
                        ? Math.min(reqRange.end, start + lease.chunkSize - 1L)
                        : (start + lease.chunkSize - 1L);

        // Probe first chunk (bounded to chunkSize so open-ended bytes=0- never triggers multi-GiB
        // download)
        ChunkFetchResult first = fetchValidatedChunk(lease, window, start, initialEnd);
        if (first == null || !lease.isWindowCurrent(window)) {
            return;
        }
        if (first.statusCode == 416) {
            sendError(out, 416, "Range Not Satisfiable");
            return;
        }
        if (first.statusCode != 206 && !(first.statusCode == 200 && start == 0L)) {
            sendError(
                    out, first.statusCode >= 400 ? first.statusCode : 502, "Upstream Range error");
            return;
        }

        long totalSize = first.totalSize > 0 ? first.totalSize : lease.knownTotalSize;
        if (totalSize > 0) lease.knownTotalSize = totalSize;
        if (first.contentType != null && !first.contentType.isEmpty()) {
            lease.knownContentType = first.contentType;
        }

        long finalEnd;
        if (reqRange.end >= start) {
            finalEnd = totalSize > 0 ? Math.min(reqRange.end, totalSize - 1L) : reqRange.end;
        } else if (totalSize > 0) {
            finalEnd = totalSize - 1L;
        } else {
            finalEnd = first.rangeEnd;
        }

        if (finalEnd < start) {
            sendError(out, 416, "Range Not Satisfiable");
            return;
        }

        long contentLength = (finalEnd - start) + 1L;
        boolean partial = reqRange.hasRangeHeader || first.statusCode == 206;
        StringBuilder head = new StringBuilder();
        head.append("HTTP/1.1 ")
                .append(partial ? "206 Partial Content" : "200 OK")
                .append("\r\nConnection: close\r\nAccept-Ranges: bytes\r\nContent-Type: ")
                .append(lease.knownContentType)
                .append("\r\nContent-Length: ")
                .append(contentLength)
                .append("\r\n");
        if (partial && totalSize > 0) {
            String cr = "bytes " + start + "-" + finalEnd + "/" + totalSize;
            head.append("Content-Range: ").append(cr).append("\r\n");
            lease.metrics.lastServedRange.set(cr);
        }
        head.append("\r\n");
        out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
        out.flush();

        if ("HEAD".equals(method)) {
            return;
        }

        // Write first chunk immediately so playback / MKV header & Cues probing starts right away.
        int firstWrite = (int) Math.min(first.bytes.length, contentLength);
        if (!lease.isWindowCurrent(window)) return;
        out.write(first.bytes, 0, firstWrite);
        out.flush();
        lease.metrics.completedChunks.incrementAndGet();

        long nextOffset = start + firstWrite;
        if (nextOffset > finalEnd) {
            return;
        }

        // Bounded concurrent prefetch pipeline for remaining chunks.
        Map<Long, Future<ChunkFetchResult>> inflight = new LinkedHashMap<>();
        long scheduleOffset = nextOffset;
        try {
            while (nextOffset <= finalEnd && lease.isWindowCurrent(window) && !closed) {
                while (scheduleOffset <= finalEnd
                        && inflight.size() < lease.chunkWorkers
                        && lease.isWindowCurrent(window)) {
                    final long cStart = scheduleOffset;
                    final long cEnd = Math.min(finalEnd, cStart + lease.chunkSize - 1L);
                    final long cLen = (cEnd - cStart) + 1L;
                    if (!reserveBuffer(lease, window, cLen)) break;
                    scheduleOffset = cEnd + 1L;
                    Future<ChunkFetchResult> fut =
                            chunkPool.submit(
                                    new Callable<ChunkFetchResult>() {
                                        @Override
                                        public ChunkFetchResult call() {
                                            try {
                                                if (!lease.isWindowCurrent(window)) {
                                                    releaseBuffer(lease, cLen);
                                                    return null;
                                                }
                                                ChunkFetchResult res =
                                                        fetchValidatedChunk(
                                                                lease, window, cStart, cEnd);
                                                if (res == null || !lease.isWindowCurrent(window)) {
                                                    releaseBuffer(lease, cLen);
                                                    return null;
                                                }
                                                res.reservedBytes = cLen;
                                                return res;
                                            } catch (Throwable t) {
                                                releaseBuffer(lease, cLen);
                                                return null;
                                            }
                                        }
                                    });
                    inflight.put(cStart, fut);
                }

                Future<ChunkFetchResult> headFuture = inflight.remove(nextOffset);
                if (headFuture == null) break;
                ChunkFetchResult chunk;
                try {
                    chunk = headFuture.get();
                } catch (Exception e) {
                    break;
                }
                if (chunk == null) break;
                try {
                    if (!lease.isWindowCurrent(window)) break;
                    if (chunk.statusCode != 206 || chunk.rangeStart != nextOffset) {
                        lease.metrics.rejectedRangeResponses.incrementAndGet();
                        break;
                    }
                    long remaining = (finalEnd - nextOffset) + 1L;
                    int toWrite = (int) Math.min(chunk.bytes.length, remaining);
                    if (toWrite <= 0) break;
                    out.write(chunk.bytes, 0, toWrite);
                    out.flush();
                    nextOffset += toWrite;
                    lease.metrics.completedChunks.incrementAndGet();
                } finally {
                    if (chunk.reservedBytes > 0) {
                        releaseBuffer(lease, chunk.reservedBytes);
                        chunk.reservedBytes = 0;
                    }
                }
            }
        } finally {
            window.cancel();
            for (Future<ChunkFetchResult> f : inflight.values()) {
                f.cancel(true);
                try {
                    if (f.isDone() && !f.isCancelled()) {
                        ChunkFetchResult leftover = f.get();
                        if (leftover != null && leftover.reservedBytes > 0) {
                            releaseBuffer(lease, leftover.reservedBytes);
                            leftover.reservedBytes = 0;
                        }
                    }
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private boolean reserveBuffer(Lease lease, RangeWindow window, long bytes) {
        synchronized (lease.bufferLock) {
            while (lease.isWindowCurrent(window)
                    && lease.metrics.currentBufferedBytes.get() + bytes > lease.maxBufferedBytes) {
                try {
                    lease.bufferLock.wait(25L);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return false;
                }
            }
            if (!lease.isWindowCurrent(window)) return false;
            lease.metrics.recordReserve(bytes);
            return true;
        }
    }

    private void releaseBuffer(Lease lease, long bytes) {
        synchronized (lease.bufferLock) {
            lease.metrics.recordRelease(bytes);
            lease.bufferLock.notifyAll();
        }
    }

    private static final class ChunkFetchResult {
        final int statusCode;
        final long rangeStart;
        final long rangeEnd;
        final long totalSize;
        final String contentType;
        final byte[] bytes;
        long reservedBytes;

        ChunkFetchResult(
                int statusCode,
                long rangeStart,
                long rangeEnd,
                long totalSize,
                String contentType,
                byte[] bytes) {
            this.statusCode = statusCode;
            this.rangeStart = rangeStart;
            this.rangeEnd = rangeEnd;
            this.totalSize = totalSize;
            this.contentType = contentType;
            this.bytes = bytes;
        }
    }

    private ChunkFetchResult fetchValidatedChunk(
            Lease lease, RangeWindow window, long start, long end) throws IOException {
        if (!lease.isWindowCurrent(window)) return null;
        String currentUrl = lease.upstreamUrl;
        for (int redirect = 0; redirect < 6; redirect++) {
            if (!lease.isWindowCurrent(window)) return null;
            HttpURLConnection conn = ProxyAddress.openHttpConnection(new URL(currentUrl));
            window.activeConnections.put(conn, Boolean.TRUE);
            try {
                conn.setRequestMethod("GET");
                conn.setInstanceFollowRedirects(false);
                conn.setConnectTimeout(15_000);
                conn.setReadTimeout(20_000);
                for (Map.Entry<String, String> h : lease.upstreamHeaders.entrySet()) {
                    if ("Range".equalsIgnoreCase(h.getKey())) continue;
                    conn.setRequestProperty(h.getKey(), h.getValue());
                }
                conn.setRequestProperty("Range", "bytes=" + start + "-" + end);
                int code = conn.getResponseCode();
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                    String loc = conn.getHeaderField("Location");
                    if (loc == null || loc.trim().isEmpty()) {
                        return new ChunkFetchResult(502, start, end, -1L, "", new byte[0]);
                    }
                    currentUrl = new URL(new URL(currentUrl), loc.trim()).toString();
                    continue;
                }
                if (!lease.isWindowCurrent(window)) return null;
                String ct = conn.getContentType();
                if (code == 416) {
                    return new ChunkFetchResult(416, start, end, -1L, ct, new byte[0]);
                }
                if (code == 206) {
                    String crHeader = conn.getHeaderField("Content-Range");
                    long[] cr = LocalProxy.parseContentRange(crHeader);
                    if (cr == null || cr[0] != start || cr[1] < start || cr[1] > end) {
                        // Strict byte-range validation: never accept misaligned Content-Range!
                        lease.metrics.rejectedRangeResponses.incrementAndGet();
                        return new ChunkFetchResult(502, start, end, -1L, ct, new byte[0]);
                    }
                    long expectedLen = (cr[1] - cr[0]) + 1L;
                    byte[] data =
                            readExactBounded(
                                    conn.getInputStream(), (int) expectedLen, lease, window);
                    if (data == null
                            || data.length != expectedLen
                            || !lease.isWindowCurrent(window)) {
                        return null;
                    }
                    return new ChunkFetchResult(206, cr[0], cr[1], cr[2], ct, data);
                }
                if (code == 200) {
                    long cl = conn.getContentLengthLong();
                    // Only allow HTTP 200 when requesting offset 0 AND total length fits in one
                    // chunk.
                    // Never read-and-discard gigabytes when upstream ignores Range on a 40 GiB MKV!
                    if (start != 0L || cl <= 0 || cl > lease.chunkSize) {
                        lease.metrics.rejectedRangeResponses.incrementAndGet();
                        return new ChunkFetchResult(502, start, end, cl, ct, new byte[0]);
                    }
                    byte[] data = readExactBounded(conn.getInputStream(), (int) cl, lease, window);
                    if (data == null || !lease.isWindowCurrent(window)) return null;
                    return new ChunkFetchResult(200, 0L, cl - 1L, cl, ct, data);
                }
                return new ChunkFetchResult(code, start, end, -1L, ct, new byte[0]);
            } finally {
                window.activeConnections.remove(conn);
                conn.disconnect();
            }
        }
        return new ChunkFetchResult(502, start, end, -1L, "", new byte[0]);
    }

    private static byte[] readExactBounded(
            InputStream in, int expectedBytes, Lease lease, RangeWindow window) throws IOException {
        if (in == null || expectedBytes < 0) return null;
        try (InputStream stream = in) {
            byte[] out = new byte[expectedBytes];
            int off = 0;
            while (off < expectedBytes) {
                if (!lease.isWindowCurrent(window)) return null;
                int n = stream.read(out, off, expectedBytes - off);
                if (n < 0) return null;
                off += n;
            }
            return out;
        }
    }

    static final class RangeSpec {
        final long start;
        final long end;
        final boolean hasRangeHeader;

        RangeSpec(long start, long end, boolean hasRangeHeader) {
            this.start = start;
            this.end = end;
            this.hasRangeHeader = hasRangeHeader;
        }
    }

    static RangeSpec parseClientRange(String header) {
        if (header == null || header.trim().isEmpty()) return null;
        String s = header.trim();
        if (!s.regionMatches(true, 0, "bytes=", 0, 6)) return null;
        String spec = s.substring(6).trim();
        int comma = spec.indexOf(',');
        if (comma >= 0) spec = spec.substring(0, comma).trim();
        int dash = spec.indexOf('-');
        if (dash < 0) return null;
        String startStr = spec.substring(0, dash).trim();
        String endStr = spec.substring(dash + 1).trim();
        try {
            if (startStr.isEmpty()) return null;
            long start = Long.parseLong(startStr);
            if (start < 0) return null;
            long end = endStr.isEmpty() ? -1L : Long.parseLong(endStr);
            if (end >= 0 && end < start) return null;
            return new RangeSpec(start, end, true);
        } catch (NumberFormatException ignored) {
            return null;
        }
    }

    private static String extractQueryParam(String query, String key) {
        if (query == null || query.isEmpty()) return "";
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            if (eq > 0 && key.equals(pair.substring(0, eq))) {
                return pair.substring(eq + 1);
            }
        }
        return "";
    }

    private static String readLine(InputStream in, int max) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') break;
            if (c != '\r') bos.write(c);
            if (bos.size() > max) throw new IOException("Line too long");
        }
        if (c == -1 && bos.size() == 0) return null;
        return new String(bos.toByteArray(), StandardCharsets.ISO_8859_1);
    }

    private static void sendError(OutputStream out, int code, String text) throws IOException {
        byte[] body = (text == null ? "" : text).getBytes(StandardCharsets.UTF_8);
        String head =
                "HTTP/1.1 "
                        + code
                        + " "
                        + text
                        + "\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: "
                        + body.length
                        + "\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.US_ASCII));
        out.write(body);
        out.flush();
    }

    @Override
    public void close() {
        closed = true;
        revokeAll();
        try {
            server.close();
        } catch (IOException ignored) {
        }
        connectionPool.shutdownNow();
        chunkPool.shutdownNow();
    }
}

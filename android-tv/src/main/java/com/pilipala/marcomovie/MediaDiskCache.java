package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import okhttp3.Call;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONObject;

/**
 * Persistent 256 KiB block-aligned HTTP Range disk cache for direct VOD streams.
 *
 * <p>Stores blocks on disk under {@code <cacheDir>/media-cache/<sha256>/b_<index>.bin} with
 * bounded LRU eviction, full HTTP 206 Range serving, and automatic 416 non-Range fallback for
 * upstream servers that reject partial requests.
 */
public final class MediaDiskCache {
    public static final int BLOCK_SIZE = 256 * 1024;
    private static final int STREAM_CHUNK_SIZE = 64 * 1024;
    private static final int MAX_PENDING_BLOCKS = 24;
    private static final int MAX_SESSIONS = 64;
    private static volatile MediaDiskCache shared;

    static final class Session {
        final String id;
        final String url;
        final Map<String, String> headers;
        final String cacheKey;

        Session(String id, String url, Map<String, String> headers, String cacheKey) {
            this.id = id;
            this.url = url;
            this.headers =
                    headers == null
                            ? Collections.emptyMap()
                            : Collections.unmodifiableMap(new LinkedHashMap<>(headers));
            this.cacheKey = cacheKey;
        }
    }

    static final class Meta {
        long contentLength = -1L;
        String contentType = "application/octet-stream";
        boolean rangeSupported = true;
    }

    private final File rootDir;
    private volatile long maxBytes;
    private final Map<String, Session> sessions =
            Collections.synchronizedMap(
                    new LinkedHashMap<String, Session>(32, 0.75f, true) {
                        @Override
                        protected boolean removeEldestEntry(Map.Entry<String, Session> eldest) {
                            return size() > MAX_SESSIONS;
                        }
                    });

    public MediaDiskCache(File rootDir, long maxBytes) {
        this.rootDir = rootDir;
        this.maxBytes = Math.max(0L, maxBytes);
        if (this.rootDir != null && !this.rootDir.exists()) {
            this.rootDir.mkdirs();
        }
    }

    public static MediaDiskCache getInstance(File cacheDir, int maxMb) {
        long cap = Math.max(0L, (long) maxMb) * 1024L * 1024L;
        MediaDiskCache existing = shared;
        if (existing != null) {
            existing.setMaxBytes(cap);
            return existing;
        }
        synchronized (MediaDiskCache.class) {
            if (shared == null) {
                shared = new MediaDiskCache(new File(cacheDir, "media-cache"), cap);
            } else {
                shared.setMaxBytes(cap);
            }
            return shared;
        }
    }

    static MediaDiskCache currentInstance() {
        return shared;
    }

    public void setMaxBytes(long bytes) {
        this.maxBytes = Math.max(0L, bytes);
    }

    public long getMaxBytes() {
        return maxBytes;
    }

    public static boolean isCacheableDirectUrl(String url, String declaredMime) {
        if (url == null || !Cms.isHttp(url)) return false;
        if (HlsStreamProxy.looksLikeHls(url, declaredMime)) return false;
        if (declaredMime != null && declaredMime.toLowerCase(Locale.ROOT).contains("dash")) {
            return false;
        }
        try {
            URI u = new URI(url);
            if (ProxyAddress.isLoopbackHost(u.getHost())) return false;
        } catch (Exception ignored) {
            return false;
        }
        String lower = url.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        if (lower.contains("/proxy/play") || lower.contains("/proxy/")) {
            return false;
        }
        if (lower.endsWith(".mpd") || lower.endsWith(".m3u8") || lower.endsWith(".m3u")) {
            return false;
        }
        return true;
    }

    public String register(String url, Map<String, String> headers) {
        LocalProxy.diskCacheRouteHandler =
                (path, method, queryParams, reqHeaders, out) ->
                        MediaDiskCache.handleRoute(path, method, reqHeaders, out);
        String sid = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
        String key = sha256(url);
        Session session = new Session(sid, url, headers, key);
        sessions.put(sid, session);
        String tok = ProxyAddress.token;
        StringBuilder sb = new StringBuilder(ProxyAddress.base()).append("/kcache/").append(sid);
        if (tok != null && !tok.isEmpty()) {
            sb.append("?_mm_token=").append(tok);
        }
        return sb.toString();
    }

    Session getSession(String sid) {
        return sid == null ? null : sessions.get(sid);
    }

    static boolean handleRoute(
            String path, String method, Map<String, String> requestHeaders, OutputStream out)
            throws IOException {
        MediaDiskCache cache = currentInstance();
        if (cache == null) {
            LocalProxy.simple(out, 404, "Disk cache unavailable");
            return false;
        }
        return cache.handle(path, method, requestHeaders, out);
    }

    boolean handle(String path, String method, Map<String, String> requestHeaders, OutputStream out)
            throws IOException {
        if (path == null || !path.startsWith("/kcache/")) {
            LocalProxy.simple(out, 404, "Not found");
            return false;
        }
        String sid = path.substring("/kcache/".length());
        int slash = sid.indexOf('/');
        if (slash >= 0) sid = sid.substring(0, slash);
        Session session = getSession(sid);
        if (session == null) {
            LocalProxy.simple(out, 404, "Cache session expired");
            return false;
        }
        String rangeHeader = requestHeaders != null ? requestHeaders.get("range") : null;
        return serveSession(session, method, rangeHeader, out);
    }

    boolean serveSession(Session session, String method, String rangeHeader, OutputStream out)
            throws IOException {
        File entryDir = new File(rootDir, session.cacheKey);
        if (!entryDir.exists()) entryDir.mkdirs();

        Meta meta = loadMeta(entryDir);
        if (meta == null) {
            meta = probeUpstream(session, entryDir);
        }
        touchMeta(entryDir);

        if (meta == null || meta.contentLength <= 0 || !meta.rangeSupported) {
            return passthroughStream(session, method, rangeHeader, out);
        }

        long total = meta.contentLength;
        long start = 0L;
        long end = total - 1L;
        boolean isPartial = false;
        if (rangeHeader != null && !rangeHeader.trim().isEmpty()) {
            long[] parsed = parseRangeHeader(rangeHeader, total);
            if (parsed == null) {
                String resp =
                        "HTTP/1.1 416 Range Not Satisfiable\r\n"
                                + "Content-Range: bytes */"
                                + total
                                + "\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
                out.write(resp.getBytes(StandardCharsets.ISO_8859_1));
                out.flush();
                return false;
            }
            start = parsed[0];
            end = parsed[1];
            isPartial = true;
        }

        long length = (end - start) + 1L;
        StringBuilder head =
                new StringBuilder("HTTP/1.1 ")
                        .append(isPartial ? "206 Partial Content" : "200 OK")
                        .append("\r\nConnection: close\r\nAccept-Ranges: bytes\r\nContent-Type: ")
                        .append(
                                LocalProxy.safe(meta.contentType)
                                        ? meta.contentType
                                        : "application/octet-stream")
                        .append("\r\nContent-Length: ")
                        .append(length)
                        .append("\r\n");
        if (isPartial) {
            head.append("Content-Range: bytes ")
                    .append(start)
                    .append('-')
                    .append(end)
                    .append('/')
                    .append(total)
                    .append("\r\n");
        }
        head.append("\r\n");
        out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
        if ("HEAD".equals(method)) {
            out.flush();
            return false;
        }

        long pos = start;
        while (pos <= end) {
            long blockIndex = pos / BLOCK_SIZE;
            int offsetInBlock = (int) (pos % BLOCK_SIZE);
            byte[] cached = readCachedBlock(entryDir, blockIndex);
            if (cached != null) {
                if (offsetInBlock >= cached.length) break;
                int available = cached.length - offsetInBlock;
                int toWrite = (int) Math.min((long) available, (end - pos) + 1L);
                out.write(cached, offsetInBlock, toWrite);
                pos += toWrite;
                if (pos > end) {
                    out.flush();
                }
                continue;
            }
            long endBlock = end / (long) BLOCK_SIZE;
            long lastMissBlock = blockIndex;
            while (lastMissBlock + 1L <= endBlock
                    && !hasCachedBlock(entryDir, lastMissBlock + 1L)) {
                lastMissBlock++;
            }
            long advancedTo =
                    streamContiguousMiss(
                            session, entryDir, meta, pos, end, blockIndex, lastMissBlock, out);
            if (advancedTo <= pos) {
                break;
            }
            pos = advancedTo;
        }
        out.flush();
        scheduleTrimAsync();
        return false;
    }

    private final ConcurrentHashMap<String, byte[]> pendingBlocks = new ConcurrentHashMap<>();
    private final ThreadPoolExecutor diskWriteExecutor =
            new ThreadPoolExecutor(
                    1,
                    1,
                    30L,
                    TimeUnit.SECONDS,
                    new LinkedBlockingQueue<Runnable>(MAX_PENDING_BLOCKS),
                    r -> {
                        Thread t = new Thread(r, "marco-tv-cache-writer");
                        t.setDaemon(true);
                        return t;
                    },
                    new ThreadPoolExecutor.AbortPolicy());
    private final ExecutorService trimExecutor =
            Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "marco-tv-cache-trim");
                        t.setDaemon(true);
                        return t;
                    });
    private final AtomicBoolean trimScheduled = new AtomicBoolean(false);

    private void scheduleTrimAsync() {
        if (trimScheduled.compareAndSet(false, true)) {
            trimExecutor.execute(
                    () -> {
                        try {
                            trimIfNeeded();
                        } finally {
                            trimScheduled.set(false);
                        }
                    });
        }
    }

    private static String pendingBlockKey(File entryDir, long blockIndex) {
        return entryDir.getName() + ":" + blockIndex;
    }

    private boolean hasCachedBlock(File entryDir, long blockIndex) {
        if (pendingBlocks.containsKey(pendingBlockKey(entryDir, blockIndex))) {
            return true;
        }
        File blockFile = new File(entryDir, "b_" + blockIndex + ".bin");
        return blockFile.isFile() && blockFile.length() > 0;
    }

    private byte[] readCachedBlock(File entryDir, long blockIndex) throws IOException {
        byte[] pending = pendingBlocks.get(pendingBlockKey(entryDir, blockIndex));
        if (pending != null && pending.length > 0) {
            return pending;
        }
        File blockFile = new File(entryDir, "b_" + blockIndex + ".bin");
        if (blockFile.isFile() && blockFile.length() > 0) {
            return readFile(blockFile);
        }
        return null;
    }

    private void enqueueBlockWrite(final File entryDir, final long blockIndex, final byte[] data) {
        if (maxBytes <= 0 || data == null || data.length == 0) return;
        final String key = pendingBlockKey(entryDir, blockIndex);
        if (pendingBlocks.size() >= MAX_PENDING_BLOCKS && !pendingBlocks.containsKey(key)) {
            return;
        }
        pendingBlocks.put(key, data);
        final File target = new File(entryDir, "b_" + blockIndex + ".bin");
        try {
            diskWriteExecutor.execute(
                    () -> {
                        try {
                            writeAtomically(target, data);
                            touchMeta(entryDir);
                        } catch (Throwable ignored) {
                        } finally {
                            pendingBlocks.remove(key, data);
                        }
                    });
        } catch (Throwable rejected) {
            pendingBlocks.remove(key, data);
        }
    }

    private long streamContiguousMiss(
            Session session,
            File entryDir,
            Meta meta,
            long startPos,
            long endPos,
            long firstMissBlock,
            long lastMissBlock,
            OutputStream out)
            throws IOException {
        long missStart = firstMissBlock * (long) BLOCK_SIZE;
        long alignEnd =
                Math.min(meta.contentLength - 1L, (lastMissBlock + 1L) * (long) BLOCK_SIZE - 1L);
        if (missStart > alignEnd) return startPos;
        String rangeSpec =
                endPos >= meta.contentLength - 1L
                        ? ("bytes=" + missStart + "-")
                        : ("bytes=" + missStart + "-" + alignEnd);

        try (UpstreamCall up = openUpstreamCall(session.url, session.headers, rangeSpec)) {
            int code = up.response.code();
            if (code == 416) {
                up.close();
                return streamMissWithoutRange(
                        session, entryDir, meta, startPos, endPos, missStart, alignEnd, out);
            }
            if (code != 206 && code != 200) {
                throw new IOException("Upstream block HTTP " + code);
            }
            ResponseBody body = up.response.body();
            if (body == null) throw new IOException("Upstream empty body");
            if (code == 206) {
                long[] cr = LocalProxy.parseContentRange(up.response.header("Content-Range"));
                if (cr != null && cr[0] != missStart) {
                    throw new IOException(
                            "Upstream Content-Range mismatch: expected "
                                    + missStart
                                    + " got "
                                    + cr[0]);
                }
            } else {
                if (missStart > 2L * 1024L * 1024L) {
                    throw new IOException("Upstream ignored Range for offset " + missStart);
                }
                skipExact(body.byteStream(), missStart);
            }
            return pumpUpstreamAndCacheBlocks(
                    entryDir,
                    meta,
                    body.byteStream(),
                    missStart,
                    startPos,
                    endPos,
                    lastMissBlock,
                    alignEnd,
                    out);
        }
    }

    private long streamMissWithoutRange(
            Session session,
            File entryDir,
            Meta meta,
            long startPos,
            long endPos,
            long missStart,
            long alignEnd,
            OutputStream out)
            throws IOException {
        if (missStart > 2L * 1024L * 1024L) {
            throw new IOException("Upstream rejected Range for tail offset " + missStart);
        }
        try (UpstreamCall retry = openUpstreamCall(session.url, session.headers, null)) {
            int code = retry.response.code();
            if (code < 200 || code >= 300) {
                throw new IOException("Upstream fallback HTTP " + code);
            }
            ResponseBody body = retry.response.body();
            if (body == null) throw new IOException("Upstream fallback empty body");
            InputStream in = body.byteStream();
            skipExact(in, missStart);
            return pumpUpstreamAndCacheBlocks(
                    entryDir,
                    meta,
                    in,
                    missStart,
                    startPos,
                    endPos,
                    alignEnd / (long) BLOCK_SIZE,
                    alignEnd,
                    out);
        }
    }

    private long pumpUpstreamAndCacheBlocks(
            File entryDir,
            Meta meta,
            InputStream in,
            long streamPos,
            long clientPos,
            long endPos,
            long lastMissBlock,
            long alignEnd,
            OutputStream out)
            throws IOException {
        long curPos = clientPos;
        long curBlockIdx = streamPos / (long) BLOCK_SIZE;
        int blockFilled = (int) (streamPos % (long) BLOCK_SIZE);
        byte[] blockBuf = null;
        if (maxBytes > 0 && curBlockIdx * (long) BLOCK_SIZE < meta.contentLength) {
            int targetLen =
                    (int)
                            Math.min(
                                    (long) BLOCK_SIZE,
                                    meta.contentLength - curBlockIdx * (long) BLOCK_SIZE);
            if (targetLen > 0) blockBuf = new byte[targetLen];
        }
        byte[] ioBuf = new byte[STREAM_CHUNK_SIZE];
        boolean firstFlushed = false;
        boolean drainPartialFinalBlock =
                alignEnd > endPos && (alignEnd - endPos) <= (long) BLOCK_SIZE;
        while (true) {
            RequestScope.checkCurrent();
            int n = in.read(ioBuf);
            if (n < 0) {
                if (blockBuf != null && blockFilled > 0 && streamPos >= meta.contentLength) {
                    enqueueBlockWrite(entryDir, curBlockIdx, Arrays.copyOf(blockBuf, blockFilled));
                }
                break;
            }
            if (n == 0) continue;

            long chunkStart = streamPos;
            long chunkEnd = streamPos + (long) n - 1L;
            if (curPos <= endPos && chunkEnd >= curPos) {
                int srcOff = (int) Math.max(0L, curPos - chunkStart);
                long sendEnd = Math.min(endPos, chunkEnd);
                int sendLen = (int) (sendEnd - curPos + 1L);
                if (sendLen > 0) {
                    out.write(ioBuf, srcOff, sendLen);
                    curPos += sendLen;
                    if (!firstFlushed) {
                        out.flush();
                        firstFlushed = true;
                    }
                }
            }

            if (maxBytes > 0) {
                int off = 0;
                while (off < n) {
                    if (blockBuf == null) {
                        if (curBlockIdx * (long) BLOCK_SIZE >= meta.contentLength) break;
                        int targetLen =
                                (int)
                                        Math.min(
                                                (long) BLOCK_SIZE,
                                                meta.contentLength
                                                        - curBlockIdx * (long) BLOCK_SIZE);
                        if (targetLen <= 0) break;
                        blockBuf = new byte[targetLen];
                        blockFilled = 0;
                    }
                    int copy = Math.min(n - off, blockBuf.length - blockFilled);
                    System.arraycopy(ioBuf, off, blockBuf, blockFilled, copy);
                    blockFilled += copy;
                    off += copy;
                    if (blockFilled == blockBuf.length) {
                        enqueueBlockWrite(entryDir, curBlockIdx, blockBuf);
                        blockBuf = null;
                        curBlockIdx++;
                        blockFilled = 0;
                    }
                }
            }
            streamPos += n;

            if (curPos > endPos) {
                out.flush();
                if (!drainPartialFinalBlock
                        || streamPos > alignEnd
                        || curBlockIdx > lastMissBlock) {
                    break;
                }
            }
        }
        return curPos;
    }

    private static void skipExact(InputStream in, long bytesToSkip) throws IOException {
        if (bytesToSkip <= 0L) return;
        byte[] discard = new byte[16384];
        long rem = bytesToSkip;
        while (rem > 0L) {
            RequestScope.checkCurrent();
            int n = in.read(discard, 0, (int) Math.min(discard.length, rem));
            if (n < 0) throw new IOException("Upstream EOF while skipping");
            rem -= n;
        }
    }

    byte[] getOrFetchBlock(Session session, File entryDir, Meta meta, long blockIndex)
            throws IOException {
        byte[] cached = readCachedBlock(entryDir, blockIndex);
        if (cached != null && cached.length > 0) {
            return cached;
        }
        long blockStart = blockIndex * (long) BLOCK_SIZE;
        long blockEnd = Math.min(meta.contentLength - 1L, blockStart + BLOCK_SIZE - 1L);
        if (blockStart > blockEnd) return new byte[0];

        try (UpstreamCall up =
                openUpstreamCall(
                        session.url, session.headers, "bytes=" + blockStart + "-" + blockEnd)) {
            int code = up.response.code();
            if (code == 416) {
                up.close();
                return fetchBlockWithoutRange(session, blockStart, blockEnd);
            }
            if (code != 206 && code != 200) {
                throw new IOException("Upstream block HTTP " + code);
            }
            ResponseBody body = up.response.body();
            if (body == null) throw new IOException("Upstream empty body");
            byte[] data;
            if (code == 206) {
                data = readExactUpTo(body.byteStream(), (int) (blockEnd - blockStart + 1L));
            } else {
                if (blockStart > 2L * 1024L * 1024L) {
                    throw new IOException("Upstream ignored Range for offset " + blockStart);
                }
                data =
                        readSliceFromFull(
                                body.byteStream(), blockStart, (int) (blockEnd - blockStart + 1L));
            }
            if (maxBytes > 0 && data.length > 0) {
                enqueueBlockWrite(entryDir, blockIndex, data);
            }
            return data;
        }
    }

    private byte[] fetchBlockWithoutRange(Session session, long blockStart, long blockEnd)
            throws IOException {
        if (blockStart > 2L * 1024L * 1024L) {
            throw new IOException("Upstream rejected Range for tail offset " + blockStart);
        }
        try (UpstreamCall retry = openUpstreamCall(session.url, session.headers, null)) {
            int code = retry.response.code();
            if (code < 200 || code >= 300) {
                throw new IOException("Upstream fallback HTTP " + code);
            }
            ResponseBody body = retry.response.body();
            if (body == null) throw new IOException("Upstream fallback empty body");
            return readSliceFromFull(
                    body.byteStream(), blockStart, (int) (blockEnd - blockStart + 1L));
        }
    }

    private Meta probeUpstream(Session session, File entryDir) throws IOException {
        try (UpstreamCall up =
                openUpstreamCall(session.url, session.headers, "bytes=0-" + (BLOCK_SIZE - 1))) {
            Response resp = up.response;
            int code = resp.code();
            Meta meta = new Meta();
            String ct = resp.header("Content-Type");
            if (ct != null && !ct.trim().isEmpty()) meta.contentType = ct.trim();
            ResponseBody body = resp.body();
            InputStream rawIn = body != null ? body.byteStream() : null;

            if (code == 206 && rawIn != null) {
                long[] cr = LocalProxy.parseContentRange(resp.header("Content-Range"));
                if (cr != null && cr[2] > 0) {
                    meta.contentLength = cr[2];
                    meta.rangeSupported = true;
                    byte[] firstBlock =
                            readExactUpTo(
                                    rawIn, (int) Math.min((long) BLOCK_SIZE, meta.contentLength));
                    if (maxBytes > 0 && firstBlock.length > 0) {
                        writeAtomically(new File(entryDir, "b_0.bin"), firstBlock);
                    }
                    saveMeta(entryDir, meta);
                    return meta;
                }
            } else if (code == 200 && rawIn != null) {
                long len = parseOkHttpContentLength(resp);
                meta.contentLength = len;
                meta.rangeSupported = "bytes".equalsIgnoreCase(resp.header("Accept-Ranges"));
                if (len > 0 && len <= BLOCK_SIZE) {
                    byte[] whole = readExactUpTo(rawIn, (int) len);
                    meta.contentLength = whole.length;
                    meta.rangeSupported = true;
                    if (maxBytes > 0 && whole.length > 0) {
                        writeAtomically(new File(entryDir, "b_0.bin"), whole);
                    }
                    saveMeta(entryDir, meta);
                    return meta;
                }
            } else if (code == 416) {
                meta.rangeSupported = false;
                return meta;
            }
            return meta;
        }
    }

    private boolean passthroughStream(
            Session session, String method, String rangeHeader, OutputStream out)
            throws IOException {
        UpstreamCall up = openUpstreamCall(session.url, session.headers, rangeHeader);
        try {
            int code = up.response.code();
            if (code == 416 && rangeHeader != null) {
                up.close();
                up = openUpstreamCall(session.url, session.headers, null);
                code = up.response.code();
            }
            if (code >= 400) {
                LocalProxy.simple(out, code, "Upstream HTTP " + code);
                return false;
            }
            String ct = up.response.header("Content-Type");
            long len = parseOkHttpContentLength(up.response);
            String cr = up.response.header("Content-Range");
            StringBuilder head =
                    new StringBuilder("HTTP/1.1 ")
                            .append(code)
                            .append(code == 206 ? " Partial Content" : " OK")
                            .append("\r\nConnection: close\r\nContent-Type: ")
                            .append(
                                    ct != null && LocalProxy.safe(ct)
                                            ? ct
                                            : "application/octet-stream")
                            .append("\r\n");
            if (cr != null && LocalProxy.safe(cr)) {
                head.append("Content-Range: ").append(cr).append("\r\n");
            }
            if (len >= 0) {
                head.append("Content-Length: ").append(len).append("\r\n\r\n");
            } else {
                head.append("Transfer-Encoding: chunked\r\n\r\n");
            }
            out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
            ResponseBody body = up.response.body();
            if (!"HEAD".equals(method) && body != null) {
                byte[] buf = new byte[STREAM_CHUNK_SIZE];
                int n;
                InputStream in = body.byteStream();
                if (len >= 0) {
                    long rem = len;
                    while (rem > 0
                            && (n = in.read(buf, 0, (int) Math.min(buf.length, rem))) != -1) {
                        if (n > 0) {
                            out.write(buf, 0, n);
                            rem -= n;
                        }
                    }
                } else {
                    while ((n = in.read(buf)) != -1) {
                        if (n == 0) continue;
                        out.write(
                                (Integer.toHexString(n) + "\r\n")
                                        .getBytes(StandardCharsets.US_ASCII));
                        out.write(buf, 0, n);
                        out.write(new byte[] {13, 10});
                    }
                    out.write("0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                }
            }
            out.flush();
            return false;
        } finally {
            up.close();
        }
    }

    static final class UpstreamCall implements java.io.Closeable {
        final Call call;
        final Response response;
        final Runnable cancelHook;

        UpstreamCall(Call call, Response response, Runnable cancelHook) {
            this.call = call;
            this.response = response;
            this.cancelHook = cancelHook;
        }

        @Override
        public void close() {
            RequestScope.offCancel(cancelHook);
            try {
                response.close();
            } catch (Throwable ignored) {
            }
        }
    }

    static UpstreamCall openUpstreamCall(
            String url, Map<String, String> headers, String rangeHeader) throws IOException {
        if (!Cms.isHttp(url)) {
            throw new IOException("不支持的媒体地址");
        }
        RequestScope.checkCurrent();
        OkHttpClient client = MoviePlayer.mediaHttpClient();
        Request.Builder rb = new Request.Builder().url(url);
        boolean hasUa = false;
        if (headers != null) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                String k = entry.getKey();
                String v = entry.getValue();
                if (k == null
                        || v == null
                        || k.equalsIgnoreCase("Host")
                        || k.equalsIgnoreCase("Range")
                        || k.equalsIgnoreCase("Accept-Encoding")) {
                    continue;
                }
                if (k.equalsIgnoreCase("User-Agent")) hasUa = true;
                rb.header(k, v);
            }
        }
        if (!hasUa) {
            rb.header("User-Agent", "MarcoMovie/0.2.0");
        }
        rb.header("Accept-Encoding", "identity");
        if (rangeHeader != null && !rangeHeader.isEmpty()) {
            rb.header("Range", rangeHeader);
        }
        Call call = client.newCall(rb.build());
        Runnable cancelHook = call::cancel;
        RequestScope.onCancel(cancelHook);
        try {
            Response resp = call.execute();
            return new UpstreamCall(call, resp, cancelHook);
        } catch (IOException err) {
            RequestScope.offCancel(cancelHook);
            throw err;
        }
    }

    private static long parseOkHttpContentLength(Response resp) {
        String header = resp.header("Content-Length");
        if (header != null) {
            try {
                return Long.parseLong(header.trim());
            } catch (NumberFormatException ignored) {
            }
        }
        ResponseBody body = resp.body();
        return body != null ? body.contentLength() : -1L;
    }

    static long[] parseRangeHeader(String rangeHeader, long total) {
        if (rangeHeader == null || total <= 0) return null;
        String s = rangeHeader.trim();
        if (!s.regionMatches(true, 0, "bytes=", 0, 6)) return null;
        String spec = s.substring(6).trim();
        int comma = spec.indexOf(',');
        if (comma >= 0) spec = spec.substring(0, comma).trim();
        int dash = spec.indexOf('-');
        if (dash < 0) return null;
        String startPart = spec.substring(0, dash).trim();
        String endPart = spec.substring(dash + 1).trim();
        try {
            long start;
            long end;
            if (startPart.isEmpty()) {
                long suffix = Long.parseLong(endPart);
                if (suffix <= 0) return null;
                start = Math.max(0L, total - suffix);
                end = total - 1L;
            } else {
                start = Long.parseLong(startPart);
                end =
                        endPart.isEmpty()
                                ? total - 1L
                                : Math.min(total - 1L, Long.parseLong(endPart));
            }
            if (start < 0 || start >= total || end < start) return null;
            return new long[] {start, end};
        } catch (NumberFormatException invalid) {
            return null;
        }
    }

    public synchronized void trimIfNeeded() {
        if (rootDir == null || !rootDir.isDirectory()) return;
        File[] children = rootDir.listFiles();
        if (children == null || children.length == 0) return;
        long total = 0L;
        List<File> dirs = new ArrayList<>();
        for (File child : children) {
            if (child.isDirectory()) {
                dirs.add(child);
                total += directoryBytes(child);
            }
        }
        if (total <= maxBytes) return;
        Collections.sort(
                dirs,
                new Comparator<File>() {
                    @Override
                    public int compare(File a, File b) {
                        return Long.compare(entryLastUsed(a), entryLastUsed(b));
                    }
                });
        for (File dir : dirs) {
            if (total <= maxBytes) break;
            long size = directoryBytes(dir);
            deleteRecursive(dir);
            total -= size;
        }
    }

    public synchronized void clear() {
        if (rootDir == null || !rootDir.isDirectory()) return;
        File[] children = rootDir.listFiles();
        if (children == null) return;
        for (File child : children) {
            deleteRecursive(child);
        }
    }

    long totalCachedBytes() {
        return directoryBytes(rootDir);
    }

    private static long entryLastUsed(File dir) {
        File meta = new File(dir, "meta.json");
        return meta.isFile() ? meta.lastModified() : dir.lastModified();
    }

    private static long directoryBytes(File file) {
        if (file == null || !file.exists()) return 0L;
        if (file.isFile()) return file.length();
        File[] list = file.listFiles();
        if (list == null) return 0L;
        long sum = 0L;
        for (File item : list) sum += directoryBytes(item);
        return sum;
    }

    private static void deleteRecursive(File file) {
        if (file == null || !file.exists()) return;
        if (file.isDirectory()) {
            File[] list = file.listFiles();
            if (list != null) {
                for (File item : list) deleteRecursive(item);
            }
        }
        file.delete();
    }

    private static Meta loadMeta(File entryDir) {
        File file = new File(entryDir, "meta.json");
        if (!file.isFile()) return null;
        try {
            JSONObject obj = new JSONObject(new String(readFile(file), StandardCharsets.UTF_8));
            Meta meta = new Meta();
            meta.contentLength = obj.optLong("contentLength", -1L);
            meta.contentType = obj.optString("contentType", "application/octet-stream");
            meta.rangeSupported = obj.optBoolean("rangeSupported", true);
            return meta;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static void saveMeta(File entryDir, Meta meta) {
        try {
            JSONObject obj =
                    new JSONObject()
                            .put("contentLength", meta.contentLength)
                            .put("contentType", meta.contentType)
                            .put("rangeSupported", meta.rangeSupported);
            writeAtomically(
                    new File(entryDir, "meta.json"),
                    obj.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {
        }
    }

    private static void touchMeta(File entryDir) {
        File meta = new File(entryDir, "meta.json");
        if (meta.isFile()) {
            meta.setLastModified(System.currentTimeMillis());
        }
    }

    private static byte[] readExactUpTo(InputStream in, int maxBytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(Math.min(maxBytes, 65536));
        byte[] buf = new byte[16384];
        int remaining = maxBytes;
        while (remaining > 0) {
            int n = in.read(buf, 0, Math.min(buf.length, remaining));
            if (n < 0) break;
            if (n > 0) {
                out.write(buf, 0, n);
                remaining -= n;
            }
        }
        return out.toByteArray();
    }

    private static byte[] readSliceFromFull(InputStream in, long skip, int length)
            throws IOException {
        byte[] discard = new byte[16384];
        long rem = skip;
        while (rem > 0) {
            int n = in.read(discard, 0, (int) Math.min(discard.length, rem));
            if (n < 0) return new byte[0];
            rem -= n;
        }
        return readExactUpTo(in, length);
    }

    private static byte[] readFile(File file) throws IOException {
        byte[] data = new byte[(int) file.length()];
        int offset = 0;
        try (FileInputStream in = new FileInputStream(file)) {
            while (offset < data.length) {
                int n = in.read(data, offset, data.length - offset);
                if (n < 0) break;
                offset += n;
            }
        }
        if (offset == data.length) return data;
        byte[] trimmed = new byte[offset];
        System.arraycopy(data, 0, trimmed, 0, offset);
        return trimmed;
    }

    private static void writeAtomically(File target, byte[] data) throws IOException {
        File tmp =
                new File(
                        target.getParentFile(),
                        target.getName() + "." + Thread.currentThread().getId() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(data);
        }
        if (!tmp.renameTo(target)) {
            try (FileOutputStream out = new FileOutputStream(target)) {
                out.write(data);
            } finally {
                tmp.delete();
            }
        }
    }

    private static String sha256(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                sb.append(String.format(Locale.ROOT, "%02x", b & 0xFF));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(input.hashCode());
        }
    }
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URLDecoder;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Short-lived phone configuration and LAN peer sync endpoint; never logs or echoes credentials.
 */
public final class ConfigServer {
    public static final int MAX_SYNC_BYTES = 8 * 1024 * 1024;
    public static final long SESSION_LIFETIME_MS = 5 * 60 * 1000L;
    public static final long REQUEST_TIMEOUT_MS = 20000L;
    private final long createdAtMs;

    public boolean isExpired() {
        return closed || (System.currentTimeMillis() - createdAtMs >= SESSION_LIFETIME_MS);
    }

    public interface Importer {
        void apply(String address) throws Exception;
    }

    public interface SyncHandler {
        String sync(String remotePayloadJson) throws Exception;
    }

    private final ServerSocket server;
    private final Importer importer;
    private final SyncHandler syncHandler;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private volatile boolean closed;
    private volatile Socket active;
    public final String token = UUID.randomUUID().toString();

    public ConfigServer(Importer sink) throws IOException {
        this(sink, null);
    }

    public ConfigServer(Importer sink, SyncHandler sync) throws IOException {
        this(sink, sync, System.currentTimeMillis());
    }

    ConfigServer(Importer sink, SyncHandler sync, long createdAtMs) throws IOException {
        importer = sink;
        syncHandler = sync;
        this.createdAtMs = createdAtMs;
        server = new ServerSocket(0, 4);
        worker.execute(
                new Runnable() {
                    public void run() {
                        serve();
                    }
                });
    }

    public int port() {
        return server.getLocalPort();
    }

    public void close() {
        closed = true;
        try {
            server.close();
        } catch (Exception ignored) {
        }
        try {
            if (active != null) active.close();
        } catch (Exception ignored) {
        }
        worker.shutdownNow();
    }

    private static String line(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') return new String(b.toByteArray(), "US-ASCII").trim();
            if (b.size() >= 4096) throw new IOException("header limit");
            b.write(c);
        }
        throw new EOFException();
    }

    private void serve() {
        while (!closed) {
            long remainingLifetime =
                    (createdAtMs + SESSION_LIFETIME_MS) - System.currentTimeMillis();
            if (remainingLifetime <= 0) {
                close();
                break;
            }
            Socket s = null;
            try {
                server.setSoTimeout((int) Math.min(remainingLifetime, 5000));
                s = server.accept();
                active = s;
                handle(s);
            } catch (SocketTimeoutException te) {
                // Timeout on accept, recheck lifetime
            } catch (Exception ignored) {
            } finally {
                try {
                    if (s != null) s.close();
                } catch (Exception ignored) {
                }
                active = null;
            }
        }
    }

    private void reply(Socket s, int code, String contentType, String body) throws IOException {
        byte[] b = body.getBytes("UTF-8");
        OutputStream o = s.getOutputStream();
        o.write(
                ("HTTP/1.1 "
                                + code
                                + " Response\r\nContent-Type: "
                                + contentType
                                + "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\nConnection: close\r\nContent-Length: "
                                + b.length
                                + "\r\n\r\n")
                        .getBytes("US-ASCII"));
        o.write(b);
        o.flush();
    }

    static boolean isAllowedLanPeer(InetAddress peer) {
        if (peer == null) return false;
        if (peer.isLoopbackAddress() || peer.isSiteLocalAddress() || peer.isLinkLocalAddress()) {
            return true;
        }
        if (peer instanceof Inet4Address) {
            byte[] raw = peer.getAddress();
            int b0 = raw[0] & 0xff;
            int b1 = raw[1] & 0xff;
            // RFC 6598 Carrier-Grade NAT / Tailscale / ZeroTier 100.64.0.0/10
            if (b0 == 100 && b1 >= 64 && b1 <= 127) return true;
        }
        byte[] raw = peer.getAddress();
        // IPv6 Unique Local fc00::/7
        return raw != null && raw.length == 16 && (raw[0] & 0xfe) == 0xfc;
    }

    private static byte[] readExact(InputStream in, int length) throws IOException {
        byte[] b = new byte[length];
        int p = 0, n;
        while (p < length && (n = in.read(b, p, length - p)) > 0) p += n;
        if (p != length) throw new EOFException();
        return b;
    }

    private void handle(Socket s) throws Exception {
        if (!isAllowedLanPeer(s.getInetAddress())) {
            reply(s, 403, "text/plain; charset=utf-8", "Forbidden: LAN access only");
            return;
        }
        if (isExpired()) {
            reply(s, 410, "text/html; charset=utf-8", "配对已过期，请重新扫码");
            close();
            return;
        }
        final long deadline = System.currentTimeMillis() + REQUEST_TIMEOUT_MS;
        s.setSoTimeout((int) REQUEST_TIMEOUT_MS);

        InputStream in = s.getInputStream();
        String[] request = line(in).split(" ");
        int length = 0;
        String transfer = "", content = "", origin = "", referer = "", host = "";
        for (int i = 0; i < 40; i++) {
            int rem = (int) Math.max(1, deadline - System.currentTimeMillis());
            s.setSoTimeout(rem);
            String h = line(in);
            if (h.length() == 0) break;
            int colon = h.indexOf(':');
            if (colon < 0) throw new IOException();
            String k = h.substring(0, colon).toLowerCase(Locale.US),
                    v = h.substring(colon + 1).trim();
            if (k.equals("content-length")) length = Integer.parseInt(v);
            if (k.equals("transfer-encoding")) transfer = v;
            if (k.equals("content-type")) content = v;
            if (k.equals("origin")) origin = v;
            if (k.equals("referer")) referer = v;
            if (k.equals("host")) host = v;
            if (i == 39) throw new IOException();
        }
        if (request.length != 3) {
            reply(s, 400, "text/html; charset=utf-8", "请求无效");
            return;
        }
        String pathOnly = request[1];
        int qIdx = pathOnly.indexOf('?');
        if (qIdx >= 0) pathOnly = pathOnly.substring(0, qIdx);

        String syncPath = "/" + token + "/sync";
        if (pathOnly.equals(syncPath)) {
            handleSync(s, in, request[0], length, transfer, content, origin);
            return;
        }

        if (!pathOnly.equals("/" + token)) {
            reply(s, 403, "text/html; charset=utf-8", "配对已失效，请重新扫码");
            return;
        }
        if (request[0].equals("GET")) {
            reply(
                    s,
                    200,
                    "text/html; charset=utf-8",
                    "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Marco Movie Lite</title><h1>配置电视</h1><p>请输入你自行获取的配置地址。软件不提供影视资源。</p><form method=post><input name=url type=url required placeholder='https://…' size=35><button>提交到电视</button></form><p>也可在手机或电脑端 Marco Movie「多端网络同步」中扫描此二维码双向同步观看进度、收藏与公开订阅源。</p>");
            return;
        }
        if (!request[0].equals("POST")) {
            reply(s, 405, "text/html; charset=utf-8", "不支持的操作");
            return;
        }
        if (origin.length() > 0 && (host.length() == 0 || !origin.equalsIgnoreCase("http://" + host))) {
            reply(s, 403, "text/html; charset=utf-8", "禁止跨站提交");
            return;
        }
        if (origin.length() == 0
                && referer.length() > 0
                && host.length() > 0
                && !referer.toLowerCase(Locale.US)
                        .startsWith("http://" + host.toLowerCase(Locale.US) + "/")) {
            reply(s, 403, "text/html; charset=utf-8", "禁止跨站提交");
            return;
        }
        if (length < 1
                || length > 8192
                || transfer.length() > 0
                || !content.toLowerCase(Locale.US).startsWith("application/x-www-form-urlencoded")) {
            reply(s, 400, "text/html; charset=utf-8", "提交格式不正确");
            return;
        }
        int rem = (int) Math.max(1, deadline - System.currentTimeMillis());
        s.setSoTimeout(rem);
        byte[] b = readExact(in, length);
        String address = null;
        for (String field : new String(b, "UTF-8").split("&")) {
            String[] kv = field.split("=", 2);
            if (kv.length == 2 && kv[0].equals("url"))
                address = URLDecoder.decode(kv[1], "UTF-8");
        }
        try {
            if (address == null || importer == null) throw new IOException();
            if (System.currentTimeMillis() >= deadline) {
                throw new SocketTimeoutException("Request budget exceeded");
            }
            importer.apply(LiteCatalog.http(address));
            reply(s, 200, "text/html; charset=utf-8", "<meta charset=utf-8><h2>配置已保存到电视</h2><p>请返回电视选择片源。</p>");
        } catch (Exception failure) {
            reply(
                    s,
                    422,
                    "text/html; charset=utf-8",
                    "<meta charset=utf-8><h2>导入失败，原配置已保留</h2><p>请检查配置地址、网络及旧系统 HTTPS 兼容性，然后重试。</p>");
        }
    }

    private void handleSync(
            Socket s,
            InputStream in,
            String method,
            int length,
            String transfer,
            String content,
            String origin)
            throws Exception {
        if (!isAllowedLanPeer(s.getInetAddress())) {
            reply(s, 403, "application/json; charset=utf-8", "{\"error\":\"lan_only\"}");
            return;
        }
        if (isExpired()) {
            reply(s, 410, "application/json; charset=utf-8", "{\"error\":\"session_expired\"}");
            close();
            return;
        }
        if (syncHandler == null) {
            reply(s, 404, "application/json; charset=utf-8", "{\"error\":\"sync_unavailable\"}");
            return;
        }
        if (origin.length() > 0) {
            reply(s, 403, "application/json; charset=utf-8", "{\"error\":\"browser_origin_blocked\"}");
            return;
        }
        if ("GET".equals(method)) {
            try {
                String out = syncHandler.sync(null);
                reply(s, 200, "application/json; charset=utf-8", out == null ? "{}" : out);
            } catch (Exception e) {
                reply(s, 500, "application/json; charset=utf-8", "{\"error\":\"export_failed\"}");
            }
            return;
        }
        if (!"POST".equals(method)) {
            reply(s, 405, "application/json; charset=utf-8", "{\"error\":\"method_not_allowed\"}");
            return;
        }
        if (transfer.length() > 0 || length < 2 || length > MAX_SYNC_BYTES) {
            reply(s, 400, "application/json; charset=utf-8", "{\"error\":\"invalid_length\"}");
            return;
        }
        if (!content.toLowerCase(Locale.US).startsWith("application/json")) {
            reply(s, 415, "application/json; charset=utf-8", "{\"error\":\"json_required\"}");
            return;
        }
        byte[] b = readExact(in, length);
        String remoteJson = new String(b, "UTF-8");
        try {
            String mergedJson = syncHandler.sync(remoteJson);
            reply(s, 200, "application/json; charset=utf-8", mergedJson == null ? "{}" : mergedJson);
        } catch (Exception e) {
            reply(s, 422, "application/json; charset=utf-8", "{\"error\":\"merge_failed\"}");
        }
    }
}

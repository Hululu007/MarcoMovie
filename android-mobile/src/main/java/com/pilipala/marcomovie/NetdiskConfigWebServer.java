package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Token-scoped local & LAN HTTP configuration web server for netdisk credentials and drive order.
 *
 * <p>Supports BOTH:
 *
 * <ul>
 *   <li>Path 3: Same-device browser / WebView ({@code http://127.0.0.1:<port>/netdisk-config/<token>})
 *   <li>Path 4: Another device on the same Wi-Fi scanning QR ({@code http://<lanIp>:<port>/netdisk-config/<token>})
 * </ul>
 *
 * <p>Explicitly reports actual bound host, port, page path, submit path, and callback execution.
 */
final class NetdiskConfigWebServer implements Closeable {
    interface SubmissionCallback {
        SubmissionResult onSubmit(Map<String, String> drives, String order, String remoteAddr)
                throws Exception;
    }

    static final class SubmissionResult {
        final boolean ok;
        final String message;
        final List<String> updatedDrives;

        SubmissionResult(boolean ok, String message, List<String> updatedDrives) {
            this.ok = ok;
            this.message = message == null ? "" : message;
            this.updatedDrives =
                    updatedDrives == null ? Collections.<String>emptyList() : updatedDrives;
        }
    }

    private final ServerSocket socket;
    private final String bindHost;
    private final String token;
    private final String basePath;
    private final String submitPath;
    private final String statusPath;
    private final long expiresAtNanos;
    private final SubmissionCallback callback;
    private final NetdiskStore.KeyValueStore statusStore;
    private volatile boolean closed;

    private final ThreadPoolExecutor workers =
            new ThreadPoolExecutor(
                    0,
                    8,
                    15,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<Runnable>(),
                    r -> {
                        Thread t = new Thread(r, "marco-netdisk-web");
                        t.setDaemon(true);
                        return t;
                    });

    NetdiskConfigWebServer(SubmissionCallback callback, NetdiskStore.KeyValueStore statusStore)
            throws IOException {
        this(callback, statusStore, TimeUnit.MINUTES.toMillis(15), "0.0.0.0", 0);
    }

    NetdiskConfigWebServer(
            SubmissionCallback callback,
            NetdiskStore.KeyValueStore statusStore,
            long ttlMs,
            String bindAddress,
            int port)
            throws IOException {
        this.callback = callback;
        this.statusStore = statusStore;
        this.bindHost = bindAddress == null || bindAddress.isEmpty() ? "0.0.0.0" : bindAddress;
        this.expiresAtNanos =
                System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(Math.max(1000L, ttlMs));
        byte[] raw = new byte[16];
        new SecureRandom().nextBytes(raw);
        StringBuilder sb = new StringBuilder(32);
        for (byte b : raw) sb.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        this.token = sb.toString();
        this.basePath = "/netdisk-config/" + token;
        this.submitPath = basePath + "/submit";
        this.statusPath = basePath + "/status";

        this.socket = new ServerSocket();
        this.socket.setReuseAddress(true);
        this.socket.bind(new InetSocketAddress(this.bindHost, port));

        Thread accept =
                new Thread(
                        () -> {
                            while (!closed) {
                                try {
                                    Socket client = socket.accept();
                                    try {
                                        workers.execute(() -> serve(client));
                                    } catch (RejectedExecutionException full) {
                                        client.close();
                                    }
                                } catch (IOException e) {
                                    if (!closed) close();
                                }
                            }
                        },
                        "marco-netdisk-web-accept");
        accept.setDaemon(true);
        accept.start();
    }

    String getBindAddress() {
        return bindHost;
    }

    int getPort() {
        return socket.getLocalPort();
    }

    String getToken() {
        return token;
    }

    String getPagePath() {
        return basePath;
    }

    String getSubmitPath() {
        return submitPath;
    }

    String getStatusPath() {
        return statusPath;
    }

    String localUrl() {
        return "http://127.0.0.1:" + getPort() + basePath;
    }

    String lanUrl(String lanIp) {
        String host = (lanIp == null || lanIp.trim().isEmpty()) ? "127.0.0.1" : lanIp.trim();
        return "http://" + host + ":" + getPort() + basePath;
    }

    boolean isExpired() {
        return closed || System.nanoTime() >= expiresAtNanos;
    }

    static String detectLanIpv4() {
        try {
            List<NetworkInterface> list = Collections.list(NetworkInterface.getNetworkInterfaces());
            for (NetworkInterface nif : list) {
                if (!nif.isUp() || nif.isLoopback()) continue;
                for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                    if (addr instanceof Inet4Address && addr.isSiteLocalAddress()) {
                        return addr.getHostAddress();
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        return "";
    }

    private void serve(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(20_000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            InetAddress peer = s.getInetAddress();
            if (!ConfigTransferServer.isAllowedLanPeer(peer)) {
                reply(out, 403, "text/plain", "仅允许本机或同一局域网设备访问");
                return;
            }
            String reqLine = readLine(in, 4096);
            String[] parts = reqLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0].trim().toUpperCase(Locale.ROOT);
            String target = parts[1].trim();
            int q = target.indexOf('?');
            String reqPath = q >= 0 ? target.substring(0, q) : target;

            Map<String, String> headers = new HashMap<>();
            int hdrTotal = 0;
            for (; ; ) {
                String line = readLine(in, 4096);
                hdrTotal += line.length();
                if (hdrTotal > 16384) throw new IOException("Header too large");
                if (line.isEmpty()) break;
                int colon = line.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            line.substring(0, colon).trim().toLowerCase(Locale.ROOT),
                            line.substring(colon + 1).trim());
                }
            }

            if (isExpired()) {
                reply(out, 410, "text/plain", "配置网页已过期，请在设备上重新打开");
                return;
            }

            String host = headers.containsKey("host") ? headers.get("host") : "";
            if (!isAllowedHostHeader(s, host)) {
                reply(out, 403, "text/plain", "请通过应用提供的地址打开配置页");
                return;
            }

            String origin = headers.get("origin");
            if (origin != null && !origin.isEmpty() && !origin.equalsIgnoreCase("http://" + host)) {
                reply(out, 403, "text/plain", "请求来源不匹配");
                return;
            }

            if ("GET".equals(method) && basePath.equals(reqPath)) {
                reply(out, 200, "text/html", renderPage("", false));
                return;
            }
            if ("GET".equals(method) && statusPath.equals(reqPath)) {
                JSONObject st = new JSONObject();
                st.put("bindAddress", bindHost);
                st.put("port", getPort());
                st.put("path", basePath);
                st.put("submitPath", submitPath);
                JSONObject drives = new JSONObject();
                for (String d : NetdiskStore.DEFAULT_ORDER) {
                    drives.put(d, statusStore != null && NetdiskStore.isLoggedIn(statusStore, d));
                }
                st.put("loggedIn", drives);
                st.put(
                        "order",
                        new JSONArray(
                                statusStore != null
                                        ? NetdiskStore.getOrder(statusStore)
                                        : NetdiskStore.DEFAULT_ORDER));
                reply(out, 200, "application/json", st.toString());
                return;
            }
            if ("POST".equals(method) && (submitPath.equals(reqPath) || basePath.equals(reqPath))) {
                handleSubmit(headers, in, out, peer.getHostAddress());
                return;
            }
            reply(out, 404, "text/plain", "路径不存在");
        } catch (Exception ignored) {
        }
    }

    private boolean isAllowedHostHeader(Socket s, String host) {
        if (host == null || host.isEmpty()) return false;
        int port = getPort();
        String localIp = s.getLocalAddress() != null ? s.getLocalAddress().getHostAddress() : "";
        if (host.equalsIgnoreCase(localIp + ":" + port)) return true;
        if (host.equalsIgnoreCase("127.0.0.1:" + port)
                || host.equalsIgnoreCase("localhost:" + port)) {
            return s.getInetAddress() != null && s.getInetAddress().isLoopbackAddress();
        }
        return false;
    }

    private void handleSubmit(
            Map<String, String> headers, InputStream in, OutputStream out, String remoteAddr)
            throws Exception {
        String rawLen = headers.get("content-length");
        int len = -1;
        try {
            if (rawLen != null) len = Integer.parseInt(rawLen.trim());
        } catch (NumberFormatException ignored) {
        }
        if (len < 0 || len > 128 * 1024) {
            reply(out, 413, "text/plain", "提交内容过大");
            return;
        }
        byte[] rawBody = new byte[len];
        for (int off = 0; off < len; ) {
            int n = in.read(rawBody, off, len - off);
            if (n < 0) throw new EOFException();
            off += n;
        }
        String bodyStr = new String(rawBody, StandardCharsets.UTF_8).trim();
        String contentType =
                headers.containsKey("content-type")
                        ? headers.get("content-type").toLowerCase(Locale.ROOT)
                        : "";
        boolean wantsJson = contentType.contains("application/json");

        Map<String, String> submittedDrives = new LinkedHashMap<>();
        String submittedOrder = "";
        if (wantsJson || bodyStr.startsWith("{")) {
            JSONObject obj = new JSONObject(bodyStr);
            Iterator<String> keys = obj.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                if (obj.isNull(k)) continue;
                String v = String.valueOf(obj.opt(k)).trim();
                if ("order".equalsIgnoreCase(k) || "panOrder".equalsIgnoreCase(k)) {
                    submittedOrder = v;
                } else {
                    String drive = NetdiskStore.normalizeDriveKey(k);
                    if (!drive.isEmpty() && !v.isEmpty()) submittedDrives.put(drive, v);
                }
            }
        } else {
            for (String pair : bodyStr.split("&")) {
                if (pair.isEmpty()) continue;
                String[] kv = pair.split("=", 2);
                String k = URLDecoder.decode(kv[0], "UTF-8").trim();
                String v = kv.length == 2 ? URLDecoder.decode(kv[1], "UTF-8").trim() : "";
                if ("order".equalsIgnoreCase(k) || "panOrder".equalsIgnoreCase(k)) {
                    submittedOrder = v;
                } else {
                    String drive = NetdiskStore.normalizeDriveKey(k);
                    if (!drive.isEmpty() && !v.isEmpty()) submittedDrives.put(drive, v);
                }
            }
        }

        // Validate every non-empty drive credential before invoking callback.
        for (Map.Entry<String, String> e : submittedDrives.entrySet()) {
            if (!NetdiskStore.isCredentialUsable(e.getKey(), e.getValue())) {
                String errMsg = NetdiskStore.displayName(e.getKey()) + " 凭据格式无效，请检查后重试";
                if (wantsJson) {
                    reply(
                            out,
                            400,
                            "application/json",
                            new JSONObject().put("ok", false).put("message", errMsg).toString());
                } else {
                    reply(out, 400, "text/html", renderPage(errMsg, true));
                }
                return;
            }
        }
        if (submittedDrives.isEmpty() && submittedOrder.isEmpty()) {
            String errMsg = "请至少填写一项有效的网盘 Cookie / Token 或盘序";
            if (wantsJson) {
                reply(
                        out,
                        400,
                        "application/json",
                        new JSONObject().put("ok", false).put("message", errMsg).toString());
            } else {
                reply(out, 400, "text/html", renderPage(errMsg, true));
            }
            return;
        }

        SubmissionResult res =
                callback != null
                        ? callback.onSubmit(submittedDrives, submittedOrder, remoteAddr)
                        : new SubmissionResult(true, "已接收配置", Collections.<String>emptyList());
        if (wantsJson) {
            JSONObject resp = new JSONObject();
            resp.put("ok", res.ok);
            resp.put("message", res.message);
            resp.put("updated", new JSONArray(res.updatedDrives));
            reply(out, res.ok ? 200 : 400, "application/json", resp.toString());
        } else {
            reply(out, res.ok ? 200 : 400, "text/html", renderPage(res.message, !res.ok));
        }
    }

    private String renderPage(String note, boolean isError) {
        String quarkState =
                statusStore != null
                                && NetdiskStore.isLoggedIn(statusStore, NetdiskStore.DRIVE_QUARK)
                        ? "已登录（留空将保留现有账号）"
                        : "未登录";
        String ucState =
                statusStore != null && NetdiskStore.isLoggedIn(statusStore, NetdiskStore.DRIVE_UC)
                        ? "已登录（留空将保留现有账号）"
                        : "未登录";
        String baiduState =
                statusStore != null
                                && NetdiskStore.isLoggedIn(statusStore, NetdiskStore.DRIVE_BAIDU)
                        ? "已登录（留空将保留现有账号）"
                        : "未登录";
        String aliState =
                statusStore != null && NetdiskStore.isLoggedIn(statusStore, NetdiskStore.DRIVE_ALI)
                        ? "已登录（留空将保留现有账号）"
                        : "未登录";
        String orderVal =
                statusStore != null
                        ? joinOrder(NetdiskStore.getOrder(statusStore))
                        : "quark,uc,baidu,ali";
        String noteHtml =
                note == null || note.isEmpty()
                        ? ""
                        : "<p class='note "
                                + (isError ? "err" : "ok")
                                + "'>"
                                + escapeHtml(note)
                                + "</p>";
        return "<!doctype html><html lang=zh-CN><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<title>Marco Movie 网盘配置中心</title>"
                + "<style>body{margin:0;background:#101216;color:#f5f5f7;font:15px system-ui;padding:22px}"
                + "main{max-width:560px;margin:0 auto}h1{font-size:24px;margin:0 0 8px}p.sub{color:#9aa3b2;margin:0 0 16px}"
                + "label{display:block;font-weight:600;margin:14px 0 6px}span.st{font-weight:400;font-size:12px;color:#5ac8fa;margin-left:6px}"
                + "textarea,input{box-sizing:border-box;width:100%;border:1px solid #2a303c;border-radius:12px;background:#1a1e26;color:#fff;padding:11px;font:inherit}"
                + "textarea{min-height:68px;resize:vertical}button{margin-top:18px;width:100%;border:0;border-radius:14px;padding:14px;background:#34c759;color:#0a120c;font-weight:700;font-size:16px}"
                + ".note{padding:11px 13px;border-radius:12px;margin:12px 0}.note.ok{background:#123821;color:#8ff0a4}.note.err{background:#3d1619;color:#ff9b9b}</style>"
                + "<main><h1>Marco Movie 网盘配置中心</h1>"
                + "<p class=sub>提交后将同步至本机「我的云盘」与已识别订阅配置中心；留空项不会覆盖已有有效账号。</p>"
                + noteHtml
                + "<form method=post action='"
                + escapeHtml(submitPath)
                + "' accept-charset=UTF-8>"
                + "<label>夸克网盘 Cookie<span class=st>"
                + quarkState
                + "</span></label><textarea name=quark placeholder='__pus=...; __puus=...'></textarea>"
                + "<label>UC 网盘 Cookie<span class=st>"
                + ucState
                + "</span></label><textarea name=uc placeholder='__pus=...; __puus=...'></textarea>"
                + "<label>百度网盘 Cookie<span class=st>"
                + baiduState
                + "</span></label><textarea name=baidu placeholder='BDUSS=...; STOKEN=...'></textarea>"
                + "<label>阿里云盘 Refresh Token<span class=st>"
                + aliState
                + "</span></label><input name=ali autocomplete=off placeholder='输入 refresh_token 或 ali_token=...'>"
                + "<label>网盘优先顺序</label><input name=order value='"
                + escapeHtml(orderVal)
                + "'>"
                + "<button type=submit>保存并同步到设备</button></form></main></html>";
    }

    private static String joinOrder(List<String> list) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(list.get(i));
        }
        return sb.toString();
    }

    private static String escapeHtml(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&#39;");
    }

    private static String readLine(InputStream in, int max) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') break;
            if (c != '\r') bos.write(c);
            if (bos.size() > max) throw new IOException("Line too long");
        }
        return new String(bos.toByteArray(), StandardCharsets.ISO_8859_1);
    }

    private static void reply(OutputStream out, int code, String contentType, String bodyText)
            throws IOException {
        byte[] body = (bodyText == null ? "" : bodyText).getBytes(StandardCharsets.UTF_8);
        String head =
                "HTTP/1.1 "
                        + code
                        + " Response\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: same-origin\r\n"
                        + "X-Content-Type-Options: nosniff\r\n"
                        + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'\r\n"
                        + "Content-Type: "
                        + contentType
                        + "; charset=utf-8\r\nContent-Length: "
                        + body.length
                        + "\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.US_ASCII));
        out.write(body);
        out.flush();
    }

    @Override
    public void close() {
        closed = true;
        try {
            socket.close();
        } catch (IOException ignored) {
        }
        workers.shutdownNow();
    }
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.MulticastSocket;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.json.JSONObject;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/**
 * Android 4.0+ (API 14+) TV Lite Wireless Cast Receiver: UPnP / DLNA Digital Media Renderer (SSDP
 * multicast + XXE-hardened SOAP control) and token-scoped QR Web Direct Cast &amp; Remote Control.
 */
public final class LiteCast implements Closeable {
    public static final String SSDP_ADDR = "239.255.255.250";
    public static final int SSDP_PORT = 1900;
    public static final int MAX_HTTP_BODY = 65536;

    static final String NT_ROOT = "upnp:rootdevice";
    static final String NT_RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1";
    static final String NT_AV_TRANSPORT = "urn:schemas-upnp-org:service:AVTransport:1";
    static final String NT_RENDERING_CONTROL = "urn:schemas-upnp-org:service:RenderingControl:1";
    static final String NT_CONNECTION_MANAGER = "urn:schemas-upnp-org:service:ConnectionManager:1";

    public interface Bridge {
        void openMedia(String url, String title, Map<String, String> headers);

        void resume();

        void pause();

        void stop();

        void seekTo(int posMs);

        int positionMs();

        int durationMs();

        String transportState();

        int getVolumePercent();

        void setVolumePercent(int percent);

        boolean isMuted();

        void setMuted(boolean muted);

        void onStatusChanged(String statusText);

        void onClosed();
    }

    public final String deviceUuid;
    public volatile String friendlyName;
    public volatile String lanIp;
    public final Bridge bridge;
    public final ServerSocket httpSocket;
    public final String webCastPath;
    public volatile boolean closed;

    public volatile String currentUri = "";
    public volatile String currentTitle = "";
    public volatile String lastClientInfo = "等待同一局域网设备投屏…";
    volatile boolean mediaOpened;

    MulticastSocket ssdpSocket;
    DatagramSocket notifySocket;
    ScheduledExecutorService scheduler;

    final ThreadPoolExecutor httpPool =
            new ThreadPoolExecutor(
                    0,
                    4,
                    15,
                    TimeUnit.SECONDS,
                    new SynchronousQueue<Runnable>(),
                    new ThreadFactory() {
                        public Thread newThread(Runnable r) {
                            Thread t = new Thread(r, "lite-cast-http");
                            t.setDaemon(true);
                            return t;
                        }
                    });

    public LiteCast(
            String uuid,
            String friendlyName,
            String lanIp,
            Bridge bridge,
            boolean enableSsdp,
            InetSocketAddress httpBind)
            throws IOException {
        if (bridge == null) throw new IllegalArgumentException("bridge required");
        String cleanUuid = uuid == null ? "" : uuid.trim();
        if (cleanUuid.startsWith("uuid:")) cleanUuid = cleanUuid.substring(5).trim();
        cleanUuid = cleanUuid.replaceAll("[^A-Za-z0-9-]", "");
        this.deviceUuid = cleanUuid.length() > 0 ? cleanUuid : UUID.randomUUID().toString();
        this.friendlyName =
                friendlyName == null || friendlyName.trim().length() == 0
                        ? "Marco Movie Lite 电视端"
                        : friendlyName.trim();
        this.lanIp = lanIp == null ? "" : lanIp.trim();
        this.bridge = bridge;

        byte[] tokenBytes = new byte[16];
        new SecureRandom().nextBytes(tokenBytes);
        StringBuilder token = new StringBuilder(32);
        for (int i = 0; i < tokenBytes.length; i++) {
            token.append(String.format(Locale.US, "%02x", tokenBytes[i] & 255));
        }
        this.webCastPath = "/cast/" + token.toString();

        this.httpSocket = new ServerSocket();
        this.httpSocket.setReuseAddress(true);
        this.httpSocket.bind(httpBind);

        Thread acceptThread =
                new Thread(
                        new Runnable() {
                            public void run() {
                                while (!closed) {
                                    try {
                                        final Socket client = httpSocket.accept();
                                        try {
                                            httpPool.execute(
                                                    new Runnable() {
                                                        public void run() {
                                                            serveHttp(client);
                                                        }
                                                    });
                                        } catch (RejectedExecutionException full) {
                                            client.close();
                                        }
                                    } catch (IOException err) {
                                        if (!closed) close();
                                    }
                                }
                            }
                        },
                        "lite-cast-accept");
        acceptThread.setDaemon(true);
        acceptThread.start();

        if (enableSsdp && this.lanIp.length() > 0) {
            startSsdp();
        }
    }

    public int httpPort() {
        return httpSocket.getLocalPort();
    }

    public String webCastUrl() {
        if (lanIp == null || lanIp.length() == 0) return "";
        return "http://" + lanIp + ":" + httpPort() + webCastPath;
    }

    public String dlnaLocationUrl() {
        if (lanIp == null || lanIp.length() == 0) return "";
        return "http://" + lanIp + ":" + httpPort() + "/dlna/device.xml";
    }

    public void updateFriendlyName(String name) {
        if (name == null || name.trim().length() == 0) return;
        friendlyName = name.trim();
        if (scheduler != null && !closed) {
            scheduler.execute(
                    new Runnable() {
                        public void run() {
                            sendNotify("ssdp:alive");
                        }
                    });
        }
    }

    private void startSsdp() {
        try {
            notifySocket = new DatagramSocket();
        } catch (Exception ignored) {
        }
        try {
            MulticastSocket ms = new MulticastSocket((java.net.SocketAddress) null);
            ms.setReuseAddress(true);
            ms.bind(new InetSocketAddress(SSDP_PORT));
            InetAddress group = InetAddress.getByName(SSDP_ADDR);
            boolean joined = false;
            try {
                for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                    if (!nif.isUp() || nif.isLoopback() || !nif.supportsMulticast()) continue;
                    for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                        if (addr instanceof Inet4Address && addr.isSiteLocalAddress()) {
                            try {
                                ms.joinGroup(new InetSocketAddress(group, SSDP_PORT), nif);
                                joined = true;
                            } catch (Exception ignored) {
                            }
                        }
                    }
                }
            } catch (Exception ignored) {
            }
            if (!joined) {
                try {
                    ms.joinGroup(group);
                } catch (Exception ignored) {
                }
            }
            ssdpSocket = ms;
            Thread reader =
                    new Thread(
                            new Runnable() {
                                public void run() {
                                    byte[] buf = new byte[4096];
                                    while (!closed && ssdpSocket != null) {
                                        try {
                                            DatagramPacket pkt =
                                                    new DatagramPacket(buf, buf.length);
                                            ssdpSocket.receive(pkt);
                                            handleSsdpPacket(pkt);
                                        } catch (IOException err) {
                                            if (closed) break;
                                        }
                                    }
                                }
                            },
                            "lite-cast-ssdp");
            reader.setDaemon(true);
            reader.start();
        } catch (Exception ignored) {
        }

        scheduler =
                Executors.newSingleThreadScheduledExecutor(
                        new ThreadFactory() {
                            public Thread newThread(Runnable r) {
                                Thread t = new Thread(r, "lite-cast-announce");
                                t.setDaemon(true);
                                return t;
                            }
                        });
        scheduler.execute(
                new Runnable() {
                    public void run() {
                        sendNotify("ssdp:alive");
                    }
                });
        scheduler.scheduleWithFixedDelay(
                new Runnable() {
                    public void run() {
                        sendNotify("ssdp:alive");
                    }
                },
                25,
                45,
                TimeUnit.SECONDS);
    }

    private void handleSsdpPacket(DatagramPacket pkt) {
        InetAddress sender = pkt.getAddress();
        if (!ConfigServer.isAllowedLanPeer(sender)) return;
        String text;
        try {
            text = new String(pkt.getData(), pkt.getOffset(), pkt.getLength(), "UTF-8");
        } catch (Exception e) {
            return;
        }
        if (!text.startsWith("M-SEARCH * HTTP/1.1")) return;
        String man = "";
        String st = "";
        String[] lines = text.split("\r?\n");
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            int colon = line.indexOf(':');
            if (colon <= 0) continue;
            String k = line.substring(0, colon).trim().toLowerCase(Locale.US);
            String v = line.substring(colon + 1).trim();
            if ("man".equals(k)) man = v;
            else if ("st".equals(k)) st = v;
        }
        if (!man.toLowerCase(Locale.US).contains("ssdp:discover") || st.length() == 0) return;
        String location = dlnaLocationUrl();
        if (location.length() == 0) return;
        String udn = "uuid:" + deviceUuid;
        List<String[]> replies = new ArrayList<String[]>();
        if ("ssdp:all".equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_ROOT, udn + "::" + NT_ROOT});
            replies.add(new String[] {udn, udn});
            replies.add(new String[] {NT_RENDERER, udn + "::" + NT_RENDERER});
            replies.add(new String[] {NT_AV_TRANSPORT, udn + "::" + NT_AV_TRANSPORT});
            replies.add(new String[] {NT_RENDERING_CONTROL, udn + "::" + NT_RENDERING_CONTROL});
            replies.add(new String[] {NT_CONNECTION_MANAGER, udn + "::" + NT_CONNECTION_MANAGER});
        } else if (NT_ROOT.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_ROOT, udn + "::" + NT_ROOT});
        } else if (udn.equalsIgnoreCase(st)) {
            replies.add(new String[] {udn, udn});
        } else if (NT_RENDERER.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_RENDERER, udn + "::" + NT_RENDERER});
        } else if (NT_AV_TRANSPORT.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_AV_TRANSPORT, udn + "::" + NT_AV_TRANSPORT});
        } else if (NT_RENDERING_CONTROL.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_RENDERING_CONTROL, udn + "::" + NT_RENDERING_CONTROL});
        } else if (NT_CONNECTION_MANAGER.equalsIgnoreCase(st)) {
            replies.add(new String[] {NT_CONNECTION_MANAGER, udn + "::" + NT_CONNECTION_MANAGER});
        }
        DatagramSocket sock = notifySocket != null ? notifySocket : ssdpSocket;
        if (sock == null) return;
        for (int i = 0; i < replies.size(); i++) {
            String[] pair = replies.get(i);
            String resp =
                    "HTTP/1.1 200 OK\r\n"
                            + "CACHE-CONTROL: max-age=1800\r\n"
                            + "EXT:\r\n"
                            + "LOCATION: "
                            + location
                            + "\r\n"
                            + "SERVER: Android/4.0 UPnP/1.0 MarcoMovieLite/1.0\r\n"
                            + "ST: "
                            + pair[0]
                            + "\r\n"
                            + "USN: "
                            + pair[1]
                            + "\r\n"
                            + "Content-Length: 0\r\n\r\n";
            try {
                byte[] bytes = resp.getBytes("UTF-8");
                sock.send(new DatagramPacket(bytes, bytes.length, sender, pkt.getPort()));
            } catch (Exception ignored) {
            }
        }
    }

    private void sendNotify(String nts) {
        DatagramSocket sock = notifySocket != null ? notifySocket : ssdpSocket;
        String location = dlnaLocationUrl();
        if (sock == null || location.length() == 0) return;
        try {
            InetAddress group = InetAddress.getByName(SSDP_ADDR);
            String udn = "uuid:" + deviceUuid;
            String[][] types = {
                {NT_ROOT, udn + "::" + NT_ROOT},
                {udn, udn},
                {NT_RENDERER, udn + "::" + NT_RENDERER},
                {NT_AV_TRANSPORT, udn + "::" + NT_AV_TRANSPORT},
                {NT_RENDERING_CONTROL, udn + "::" + NT_RENDERING_CONTROL},
                {NT_CONNECTION_MANAGER, udn + "::" + NT_CONNECTION_MANAGER}
            };
            for (int i = 0; i < types.length; i++) {
                String[] pair = types[i];
                String msg =
                        "NOTIFY * HTTP/1.1\r\n"
                                + "HOST: "
                                + SSDP_ADDR
                                + ":"
                                + SSDP_PORT
                                + "\r\n"
                                + "CACHE-CONTROL: max-age=1800\r\n"
                                + "LOCATION: "
                                + location
                                + "\r\n"
                                + "NT: "
                                + pair[0]
                                + "\r\n"
                                + "NTS: "
                                + nts
                                + "\r\n"
                                + "SERVER: Android/4.0 UPnP/1.0 MarcoMovieLite/1.0\r\n"
                                + "USN: "
                                + pair[1]
                                + "\r\n"
                                + "Content-Length: 0\r\n\r\n";
                byte[] bytes = msg.getBytes("UTF-8");
                sock.send(new DatagramPacket(bytes, bytes.length, group, SSDP_PORT));
            }
        } catch (Exception ignored) {
        }
    }

    public static String validateCastMediaUrl(String raw) {
        if (raw == null) return "";
        String url = raw.trim();
        if (url.length() == 0 || url.length() > 8192) return "";
        for (int i = 0; i < url.length(); i++) {
            char c = url.charAt(i);
            if (c < 0x20 || c == 0x7f) return "";
        }
        try {
            URI uri = new URI(url);
            String scheme = uri.getScheme();
            if (scheme == null) return "";
            String ls = scheme.toLowerCase(Locale.US);
            if (!"http".equals(ls) && !"https".equals(ls)) return "";
            String host = uri.getHost();
            if (host == null || host.trim().length() == 0) return "";
            String lh = host.trim().toLowerCase(Locale.US);
            if (lh.startsWith("[") && lh.endsWith("]")) {
                lh = lh.substring(1, lh.length() - 1);
            }
            if ("localhost".equals(lh)
                    || "0.0.0.0".equals(lh)
                    || "::1".equals(lh)
                    || "0:0:0:0:0:0:0:1".equals(lh)
                    || lh.startsWith("127.")) {
                return "";
            }
            return url;
        } catch (Exception bad) {
            return "";
        }
    }

    private static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') return new String(b.toByteArray(), "US-ASCII").trim();
            if (b.size() >= 4096) throw new IOException("line too long");
            b.write(c);
        }
        if (b.size() > 0) return new String(b.toByteArray(), "US-ASCII").trim();
        throw new EOFException();
    }

    private static byte[] readExact(InputStream in, int length) throws IOException {
        byte[] b = new byte[length];
        int p = 0;
        while (p < length) {
            int n = in.read(b, p, length - p);
            if (n < 0) throw new EOFException();
            p += n;
        }
        return b;
    }

    private static String escapeXml(String s) {
        if (s == null) return "";
        StringBuilder out = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '&') out.append("&amp;");
            else if (c == '<') out.append("&lt;");
            else if (c == '>') out.append("&gt;");
            else if (c == '"') out.append("&quot;");
            else if (c == '\'') out.append("&#39;");
            else out.append(c);
        }
        return out.toString();
    }

    private void serveHttp(Socket client) {
        try {
            client.setSoTimeout(15000);
            InputStream in = client.getInputStream();
            OutputStream out = client.getOutputStream();
            if (!ConfigServer.isAllowedLanPeer(client.getInetAddress())) {
                replyHttp(out, 403, "text/plain", "Forbidden", null);
                return;
            }
            String[] first = readLine(in).split(" ");
            if (first.length != 3) return;
            String method = first[0].trim().toUpperCase(Locale.US);
            String reqPath = first[1].trim();
            int qIdx = reqPath.indexOf('?');
            if (qIdx >= 0) reqPath = reqPath.substring(0, qIdx);

            Map<String, String> headers = new HashMap<String, String>();
            int total = 0;
            for (; ; ) {
                String row = readLine(in);
                total += row.length();
                if (total > 16384) throw new IOException("header limit");
                if (row.length() == 0) break;
                int colon = row.indexOf(':');
                if (colon > 0) {
                    headers.put(
                            row.substring(0, colon).trim().toLowerCase(Locale.US),
                            row.substring(colon + 1).trim());
                }
            }
            if (reqPath.startsWith("/dlna/")) {
                serveDlna(client, method, reqPath, headers, in, out);
                return;
            }
            if (reqPath.equals(webCastPath) || reqPath.equals(webCastPath + "/api")) {
                serveWebCast(client, method, reqPath, headers, in, out);
                return;
            }
            replyHttp(out, 404, "text/plain", "Not Found", null);
        } catch (Exception ignored) {
        } finally {
            try {
                client.close();
            } catch (Exception ignored) {
            }
        }
    }

    private void serveDlna(
            Socket s,
            String method,
            String reqPath,
            Map<String, String> headers,
            InputStream in,
            OutputStream out)
            throws IOException {
        if (headers.containsKey("origin") || headers.containsKey("sec-fetch-site")) {
            replyHttp(out, 403, "text/plain", "Browser origin blocked", null);
            return;
        }
        if ("GET".equals(method)) {
            if ("/dlna/device.xml".equals(reqPath)) {
                replyHttp(out, 200, "text/xml", buildDeviceXml(), null);
                return;
            }
            if ("/dlna/AVTransport.xml".equals(reqPath)
                    || "/dlna/RenderingControl.xml".equals(reqPath)
                    || "/dlna/ConnectionManager.xml".equals(reqPath)) {
                replyHttp(out, 200, "text/xml", buildMinimalScpd(), null);
                return;
            }
            replyHttp(out, 404, "text/plain", "Not Found", null);
            return;
        }
        if ("SUBSCRIBE".equals(method) && reqPath.startsWith("/dlna/event/")) {
            Map<String, String> extra = new LinkedHashMap<String, String>();
            String sid = headers.get("sid");
            if (sid == null || sid.length() == 0) sid = "uuid:" + UUID.randomUUID().toString();
            extra.put("SID", sid);
            extra.put("TIMEOUT", "Second-1800");
            replyHttp(out, 200, "text/plain", "", extra);
            return;
        }
        if ("UNSUBSCRIBE".equals(method) && reqPath.startsWith("/dlna/event/")) {
            replyHttp(out, 200, "text/plain", "", null);
            return;
        }
        if (!"POST".equals(method) || !reqPath.startsWith("/dlna/control/")) {
            replyHttp(out, 405, "text/plain", "Method Not Allowed", null);
            return;
        }
        if (headers.containsKey("transfer-encoding")) {
            replyHttp(out, 415, "text/plain", "Chunked unsupported", null);
            return;
        }
        int length;
        try {
            length =
                    Integer.parseInt(
                            headers.containsKey("content-length")
                                    ? headers.get("content-length")
                                    : "-1");
        } catch (NumberFormatException e) {
            length = -1;
        }
        if (length <= 0 || length > MAX_HTTP_BODY) {
            replyHttp(out, 413, "text/plain", "Invalid length", null);
            return;
        }
        String xml = new String(readExact(in, length), "UTF-8");
        Element actionEl;
        try {
            actionEl = parseSoapAction(xml);
        } catch (Exception bad) {
            replyHttp(out, 400, "text/plain", "Forbidden or malformed XML", null);
            return;
        }
        if (actionEl == null) {
            replyHttp(out, 400, "text/plain", "Missing SOAP action", null);
            return;
        }
        String action = localNameOf(actionEl);
        Map<String, String> args = childMap(actionEl);
        String peer = s.getInetAddress() != null ? s.getInetAddress().getHostAddress() : "局域网";
        handleSoap(reqPath, action, args, peer, out);
    }

    private static DocumentBuilder safeBuilder() throws Exception {
        DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
        dbf.setNamespaceAware(true);
        try {
            dbf.setExpandEntityReferences(false);
        } catch (Throwable ignored) {
        }
        try {
            dbf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        } catch (Throwable ignored) {
        }
        try {
            dbf.setFeature("http://xml.org/sax/features/external-general-entities", false);
        } catch (Throwable ignored) {
        }
        try {
            dbf.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
        } catch (Throwable ignored) {
        }
        return dbf.newDocumentBuilder();
    }

    public static Element parseSoapAction(String xml) throws Exception {
        if (xml == null || xml.indexOf('\0') >= 0) throw new IOException("Invalid XML");
        String upper = xml.toUpperCase(Locale.US);
        if (upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY")) {
            throw new IOException("DOCTYPE/ENTITY forbidden");
        }
        Document doc = safeBuilder().parse(new ByteArrayInputStream(xml.getBytes("UTF-8")));
        Element root = doc.getDocumentElement();
        if (root == null) return null;
        NodeList children = root.getChildNodes();
        for (int i = 0; i < children.getLength(); i++) {
            Node n = children.item(i);
            if (n.getNodeType() == Node.ELEMENT_NODE && "Body".equalsIgnoreCase(localNameOf(n))) {
                NodeList bodyKids = n.getChildNodes();
                for (int j = 0; j < bodyKids.getLength(); j++) {
                    Node act = bodyKids.item(j);
                    if (act.getNodeType() == Node.ELEMENT_NODE) return (Element) act;
                }
            }
        }
        return null;
    }

    private static String localNameOf(Node n) {
        String ln = n.getLocalName();
        if (ln != null && ln.length() > 0) return ln;
        String name = n.getNodeName();
        if (name == null) return "";
        int colon = name.indexOf(':');
        return colon >= 0 ? name.substring(colon + 1) : name;
    }

    private static Map<String, String> childMap(Element el) {
        Map<String, String> map = new LinkedHashMap<String, String>();
        NodeList kids = el.getChildNodes();
        for (int i = 0; i < kids.getLength(); i++) {
            Node k = kids.item(i);
            if (k.getNodeType() == Node.ELEMENT_NODE) {
                String text = k.getTextContent();
                map.put(localNameOf(k), text == null ? "" : text.trim());
            }
        }
        return map;
    }

    private static String extractDidlTitle(String meta) {
        if (meta == null || meta.trim().length() == 0 || meta.indexOf('\0') >= 0) return "";
        String upper = meta.toUpperCase(Locale.US);
        if (upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY")) return "";
        try {
            Document doc = safeBuilder().parse(new ByteArrayInputStream(meta.getBytes("UTF-8")));
            NodeList all = doc.getElementsByTagName("*");
            for (int i = 0; i < all.getLength(); i++) {
                Node n = all.item(i);
                if ("title".equalsIgnoreCase(localNameOf(n))) {
                    String t = n.getTextContent();
                    if (t != null && t.trim().length() > 0) return t.trim();
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    public static int parseDlnaTimeMs(String raw) {
        if (raw == null) return -1;
        String s = raw.trim();
        if (s.length() == 0) return -1;
        try {
            if (s.indexOf(':') >= 0) {
                String[] p = s.split(":");
                if (p.length == 3) {
                    int h = Integer.parseInt(p[0].trim());
                    int m = Integer.parseInt(p[1].trim());
                    double sec = Double.parseDouble(p[2].trim());
                    return Math.max(0, (int) Math.round((h * 3600L + m * 60L) * 1000.0 + sec * 1000.0));
                }
            }
            return Math.max(0, (int) Math.round(Double.parseDouble(s) * 1000.0));
        } catch (Exception e) {
            return -1;
        }
    }

    public static String formatDlnaTime(int ms) {
        int sec = Math.max(0, ms / 1000);
        return String.format(Locale.US, "%02d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60);
    }

    private void handleSoap(
            String reqPath,
            String action,
            Map<String, String> args,
            String peer,
            OutputStream out)
            throws IOException {
        String ns =
                reqPath.endsWith("RenderingControl")
                        ? NT_RENDERING_CONTROL
                        : reqPath.endsWith("ConnectionManager")
                                ? NT_CONNECTION_MANAGER
                                : NT_AV_TRANSPORT;
        if ("SetAVTransportURI".equalsIgnoreCase(action)) {
            String valid = validateCastMediaUrl(args.get("CurrentURI"));
            if (valid.length() == 0) {
                replyHttp(out, 500, "text/xml", "<Fault>Unsupported URI</Fault>", null);
                return;
            }
            String title = extractDidlTitle(args.get("CurrentURIMetaData"));
            if (title.length() == 0) title = "DLNA 无线投屏";
            currentUri = valid;
            currentTitle = title;
            mediaOpened = true;
            lastClientInfo = "DLNA 已连接 (" + peer + ") · " + title;
            bridge.onStatusChanged(lastClientInfo);
            bridge.openMedia(valid, title, Collections.<String, String>emptyMap());
            replySoap(out, NT_AV_TRANSPORT, "SetAVTransportURI", "");
            return;
        }
        if ("Play".equalsIgnoreCase(action)) {
            if (!mediaOpened && currentUri.length() > 0) {
                mediaOpened = true;
                bridge.openMedia(
                        currentUri,
                        currentTitle.length() > 0 ? currentTitle : "DLNA 无线投屏",
                        Collections.<String, String>emptyMap());
            } else {
                bridge.resume();
            }
            replySoap(out, NT_AV_TRANSPORT, "Play", "");
            return;
        }
        if ("Pause".equalsIgnoreCase(action)) {
            bridge.pause();
            replySoap(out, NT_AV_TRANSPORT, "Pause", "");
            return;
        }
        if ("Stop".equalsIgnoreCase(action)) {
            mediaOpened = false;
            lastClientInfo = "投屏已结束 · 等待新的连接";
            bridge.onStatusChanged(lastClientInfo);
            bridge.stop();
            replySoap(out, NT_AV_TRANSPORT, "Stop", "");
            return;
        }
        if ("Seek".equalsIgnoreCase(action)) {
            int ms = parseDlnaTimeMs(args.get("Target"));
            if (ms >= 0) bridge.seekTo(ms);
            replySoap(out, NT_AV_TRANSPORT, "Seek", "");
            return;
        }
        if ("GetPositionInfo".equalsIgnoreCase(action)) {
            String dur = formatDlnaTime(bridge.durationMs());
            String pos = formatDlnaTime(bridge.positionMs());
            replySoap(
                    out,
                    NT_AV_TRANSPORT,
                    "GetPositionInfo",
                    "<Track>1</Track><TrackDuration>"
                            + dur
                            + "</TrackDuration><TrackMetaData></TrackMetaData><TrackURI>"
                            + escapeXml(currentUri)
                            + "</TrackURI><RelTime>"
                            + pos
                            + "</RelTime><AbsTime>"
                            + pos
                            + "</AbsTime><RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount>");
            return;
        }
        if ("GetTransportInfo".equalsIgnoreCase(action)) {
            String st = bridge.transportState();
            replySoap(
                    out,
                    NT_AV_TRANSPORT,
                    "GetTransportInfo",
                    "<CurrentTransportState>"
                            + escapeXml(st == null ? "STOPPED" : st)
                            + "</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>");
            return;
        }
        if ("GetMediaInfo".equalsIgnoreCase(action)) {
            String dur = formatDlnaTime(bridge.durationMs());
            replySoap(
                    out,
                    NT_AV_TRANSPORT,
                    "GetMediaInfo",
                    "<NrTracks>1</NrTracks><MediaDuration>"
                            + dur
                            + "</MediaDuration><CurrentURI>"
                            + escapeXml(currentUri)
                            + "</CurrentURI><CurrentURIMetaData></CurrentURIMetaData><NextURI></NextURI><NextURIMetaData></NextURIMetaData><PlayMedium>NETWORK</PlayMedium><RecordMedium>NOT_IMPLEMENTED</RecordMedium><WriteStatus>NOT_IMPLEMENTED</WriteStatus>");
            return;
        }
        if ("GetVolume".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_RENDERING_CONTROL,
                    "GetVolume",
                    "<CurrentVolume>" + bridge.getVolumePercent() + "</CurrentVolume>");
            return;
        }
        if ("SetVolume".equalsIgnoreCase(action)) {
            try {
                int v = Integer.parseInt(args.get("DesiredVolume"));
                bridge.setVolumePercent(Math.max(0, Math.min(100, v)));
            } catch (Exception ignored) {
            }
            replySoap(out, NT_RENDERING_CONTROL, "SetVolume", "");
            return;
        }
        if ("GetMute".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_RENDERING_CONTROL,
                    "GetMute",
                    "<CurrentMute>" + (bridge.isMuted() ? "1" : "0") + "</CurrentMute>");
            return;
        }
        if ("SetMute".equalsIgnoreCase(action)) {
            String dm = args.get("DesiredMute");
            bridge.setMuted("1".equals(dm) || "true".equalsIgnoreCase(dm));
            replySoap(out, NT_RENDERING_CONTROL, "SetMute", "");
            return;
        }
        if ("GetProtocolInfo".equalsIgnoreCase(action)) {
            replySoap(
                    out,
                    NT_CONNECTION_MANAGER,
                    "GetProtocolInfo",
                    "<Source></Source><Sink>http-get:*:video/mp4:*,http-get:*:video/*:*,http-get:*:application/vnd.apple.mpegurl:*,http-get:*:audio/*:*</Sink>");
            return;
        }
        replySoap(out, ns, action, "");
    }

    private void serveWebCast(
            Socket s,
            String method,
            String reqPath,
            Map<String, String> headers,
            InputStream in,
            OutputStream out)
            throws IOException {
        String host = headers.containsKey("host") ? headers.get("host") : "";
        String expected = s.getLocalAddress().getHostAddress() + ":" + httpSocket.getLocalPort();
        if (!host.equalsIgnoreCase(expected)) {
            replyHttp(out, 403, "text/plain", "Forbidden host", null);
            return;
        }
        boolean isApi = reqPath.equals(webCastPath + "/api");
        if ("GET".equals(method)) {
            if (isApi) {
                replyHttp(out, 200, "application/json", statusJson(true, "").toString(), null);
            } else {
                replyHttp(out, 200, "text/html", renderWebCastHtml(), null);
            }
            return;
        }
        if (!"POST".equals(method) || !isApi) {
            replyHttp(out, 405, "text/plain", "Method Not Allowed", null);
            return;
        }
        String origin = headers.get("origin");
        if (origin != null && !origin.equalsIgnoreCase("http://" + host)) {
            replyHttp(out, 403, "text/plain", "Cross-origin blocked", null);
            return;
        }
        if (headers.containsKey("transfer-encoding")) {
            replyHttp(out, 415, "text/plain", "Chunked unsupported", null);
            return;
        }
        int len;
        try {
            len = Integer.parseInt(headers.containsKey("content-length") ? headers.get("content-length") : "-1");
        } catch (Exception e) {
            len = -1;
        }
        if (len <= 0 || len > MAX_HTTP_BODY) {
            replyHttp(out, 413, "text/plain", "Payload error", null);
            return;
        }
        JSONObject req;
        try {
            req = new JSONObject(new String(readExact(in, len), "UTF-8"));
        } catch (Exception bad) {
            replyHttp(out, 400, "application/json", "{\"ok\":false,\"message\":\"请求无效\"}", null);
            return;
        }
        String cmd = req.optString("action", "play").trim().toLowerCase(Locale.US);
        if ("play".equals(cmd)) {
            String valid = validateCastMediaUrl(req.optString("url", ""));
            if (valid.length() == 0) {
                replyHttp(
                        out,
                        400,
                        "application/json",
                        statusJson(false, "请输入有效的 HTTP / HTTPS 视频流地址").toString(),
                        null);
                return;
            }
            String title = ConfigServer.sanitizeKeyword(req.optString("title", ""));
            if (title.length() == 0) title = "手机网页直投";
            Map<String, String> h = new LinkedHashMap<String, String>();
            String ref = req.optString("referer", "").trim();
            if (ref.length() > 0 && ref.indexOf('\r') < 0 && ref.indexOf('\n') < 0) {
                h.put("Referer", ref);
            }
            String ua = req.optString("userAgent", "").trim();
            if (ua.length() > 0 && ua.indexOf('\r') < 0 && ua.indexOf('\n') < 0) {
                h.put("User-Agent", ua);
            }
            currentUri = valid;
            currentTitle = title;
            mediaOpened = true;
            lastClientInfo = "扫码直投已连接 · " + title;
            bridge.onStatusChanged(lastClientInfo);
            bridge.openMedia(valid, title, h);
            replyHttp(out, 200, "application/json", statusJson(true, "已在电视开始播放：" + title).toString(), null);
            return;
        }
        if ("toggle".equals(cmd)) {
            if ("PLAYING".equalsIgnoreCase(bridge.transportState())) bridge.pause();
            else bridge.resume();
            replyHttp(out, 200, "application/json", statusJson(true, "已切换播放状态").toString(), null);
            return;
        }
        if ("stop".equals(cmd)) {
            mediaOpened = false;
            bridge.stop();
            replyHttp(out, 200, "application/json", statusJson(true, "已停止投屏").toString(), null);
            return;
        }
        if ("seek".equals(cmd)) {
            int delta = req.optInt("deltaSeconds", 0);
            int target = Math.max(0, bridge.positionMs() + delta * 1000);
            bridge.seekTo(target);
            replyHttp(out, 200, "application/json", statusJson(true, "已跳转至 " + formatDlnaTime(target)).toString(), null);
            return;
        }
        if ("volume".equals(cmd)) {
            int next = Math.max(0, Math.min(100, bridge.getVolumePercent() + req.optInt("delta", 0)));
            bridge.setVolumePercent(next);
            replyHttp(out, 200, "application/json", statusJson(true, "音量：" + next + "%").toString(), null);
            return;
        }
        replyHttp(out, 400, "application/json", statusJson(false, "未知指令").toString(), null);
    }

    private JSONObject statusJson(boolean ok, String msg) {
        JSONObject j = new JSONObject();
        try {
            j.put("ok", ok);
            j.put("message", msg == null ? "" : msg);
            j.put("state", bridge.transportState());
            j.put("title", currentTitle);
            j.put("positionMs", Math.max(0, bridge.positionMs()));
            j.put("durationMs", Math.max(0, bridge.durationMs()));
            j.put("volume", bridge.getVolumePercent());
        } catch (Exception ignored) {
        }
        return j;
    }

    private String renderWebCastHtml() {
        String escApi = escapeXml(webCastPath + "/api");
        String escName = escapeXml(friendlyName);
        return "<!doctype html><html lang='zh-CN'><meta charset='utf-8'>"
                + "<meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1'>"
                + "<title>"
                + escName
                + " · 无线投屏</title>"
                + "<style>body{margin:0;background:#101013;color:#f5f5f7;font:15px/1.5 -apple-system,sans-serif;padding:18px}"
                + "main{max-width:480px;margin:1vh auto}.card{background:#1c1d24;border:1px solid #343644;border-radius:16px;padding:18px;margin-bottom:14px}"
                + "input{width:100%;box-sizing:border-box;padding:11px 13px;font-size:16px;background:#262832;color:#fff;border:1px solid #44475a;border-radius:10px;margin:6px 0 10px}"
                + "button{padding:11px;font-size:14px;font-weight:600;border-radius:10px;border:0;background:#2b2e3b;color:#fff}"
                + "button.pri{width:100%;background:#f5f5f7;color:#101013;font-size:16px;padding:12px}"
                + ".grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:10px}</style>"
                + "<main><div class='card'><h2>"
                + escName
                + " · 扫码直投</h2>"
                + "<input id='u' type='url' placeholder='https://media.example/video.m3u8'>"
                + "<input id='t' type='text' maxlength='80' placeholder='视频标题（选填）'>"
                + "<button class='pri' id='go'>立即投屏到电视</button>"
                + "<div id='m' style='margin-top:10px;color:#9cd8ff;font-size:13.5px'>准备就绪</div></div>"
                + "<div class='card'><h3>手机遥控</h3><div class='grid'>"
                + "<button data-c='seek' data-v='-15'>快退 15s</button>"
                + "<button data-c='toggle'>播放 / 暂停</button>"
                + "<button data-c='seek' data-v='30'>快进 30s</button>"
                + "<button data-c='volume' data-v='-10'>音量 -</button>"
                + "<button data-c='stop'>结束投屏</button>"
                + "<button data-c='volume' data-v='10'>音量 +</button>"
                + "</div></div></main><script>"
                + "(function(){var api='"
                + escApi
                + "',m=document.getElementById('m');"
                + "function p(d){fetch(api,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)})"
                + ".then(function(r){return r.json();}).then(function(j){if(j&&j.message)m.textContent=j.message;});}"
                + "document.getElementById('go').onclick=function(){p({action:'play',url:document.getElementById('u').value,title:document.getElementById('t').value});};"
                + "var bs=document.querySelectorAll('button[data-c]');"
                + "for(var i=0;i<bs.length;i++){(function(b){b.onclick=function(){var c=b.getAttribute('data-c'),v=parseInt(b.getAttribute('data-v')||'0',10);"
                + "if(c==='seek')p({action:'seek',deltaSeconds:v});else if(c==='volume')p({action:'volume',delta:v});else p({action:c});};})(bs[i]);}"
                + "})();</script></html>";
    }

    private String buildDeviceXml() {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
                + "<specVersion><major>1</major><minor>0</minor></specVersion>"
                + "<device><deviceType>"
                + NT_RENDERER
                + "</deviceType><friendlyName>"
                + escapeXml(friendlyName)
                + "</friendlyName><manufacturer>Marco Movie</manufacturer>"
                + "<modelName>Marco Movie Lite</modelName><UDN>uuid:"
                + escapeXml(deviceUuid)
                + "</UDN><serviceList>"
                + "<service><serviceType>"
                + NT_AV_TRANSPORT
                + "</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>"
                + "<SCPDURL>/dlna/AVTransport.xml</SCPDURL><controlURL>/dlna/control/AVTransport</controlURL><eventSubURL>/dlna/event/AVTransport</eventSubURL></service>"
                + "<service><serviceType>"
                + NT_RENDERING_CONTROL
                + "</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>"
                + "<SCPDURL>/dlna/RenderingControl.xml</SCPDURL><controlURL>/dlna/control/RenderingControl</controlURL><eventSubURL>/dlna/event/RenderingControl</eventSubURL></service>"
                + "<service><serviceType>"
                + NT_CONNECTION_MANAGER
                + "</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>"
                + "<SCPDURL>/dlna/ConnectionManager.xml</SCPDURL><controlURL>/dlna/control/ConnectionManager</controlURL><eventSubURL>/dlna/event/ConnectionManager</eventSubURL></service>"
                + "</serviceList></device></root>";
    }

    private static String buildMinimalScpd() {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                + "<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">"
                + "<specVersion><major>1</major><minor>0</minor></specVersion>"
                + "<actionList></actionList><serviceStateTable></serviceStateTable></scpd>";
    }

    private static void replySoap(OutputStream out, String ns, String action, String inner)
            throws IOException {
        String body =
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                        + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
                        + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                        + "<s:Body><u:"
                        + action
                        + "Response xmlns:u=\""
                        + ns
                        + "\">"
                        + (inner == null ? "" : inner)
                        + "</u:"
                        + action
                        + "Response></s:Body></s:Envelope>";
        Map<String, String> extra = new LinkedHashMap<String, String>();
        extra.put("EXT", "");
        replyHttp(out, 200, "text/xml", body, extra);
    }

    private static void replyHttp(
            OutputStream out,
            int code,
            String contentType,
            String body,
            Map<String, String> extra)
            throws IOException {
        byte[] bytes = (body == null ? "" : body).getBytes("UTF-8");
        StringBuilder head = new StringBuilder(256);
        head.append("HTTP/1.1 ").append(code).append(" OK\r\n");
        head.append("Content-Type: ").append(contentType).append("; charset=utf-8\r\n");
        head.append("Content-Length: ").append(bytes.length).append("\r\n");
        head.append("Cache-Control: no-store\r\nConnection: close\r\n");
        if (extra != null) {
            for (Map.Entry<String, String> e : extra.entrySet()) {
                head.append(e.getKey()).append(": ").append(e.getValue()).append("\r\n");
            }
        }
        head.append("\r\n");
        out.write(head.toString().getBytes("US-ASCII"));
        out.write(bytes);
        out.flush();
    }

    public void close() {
        if (closed) return;
        closed = true;
        try {
            sendNotify("ssdp:byebye");
        } catch (Exception ignored) {
        }
        if (scheduler != null) {
            scheduler.shutdownNow();
            scheduler = null;
        }
        if (ssdpSocket != null) {
            try {
                ssdpSocket.close();
            } catch (Exception ignored) {
            }
            ssdpSocket = null;
        }
        if (notifySocket != null) {
            try {
                notifySocket.close();
            } catch (Exception ignored) {
            }
            notifySocket = null;
        }
        try {
            httpSocket.close();
        } catch (Exception ignored) {
        }
        httpPool.shutdownNow();
        try {
            bridge.onClosed();
        } catch (Exception ignored) {
        }
    }
}

package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

/**
 * Pure-Java LAN UPnP / DLNA MediaRenderer discovery &amp; selectable cast client.
 *
 * <p>Enables iQIYI/Youku/Tencent-style selectable casting from the TV Cast screen and TV Player:
 * discovers LAN DLNA MediaRenderer devices via SSDP M-SEARCH, validates XXE-safe {@code device.xml}
 * descriptors on LAN hosts, and dispatches SOAP {@code AVTransport} / {@code RenderingControl}
 * actions ({@code SetAVTransportURI}, {@code Play}, {@code Pause}, {@code Seek}, {@code Stop}).
 */
final class DlnaCastClient {
    static final String SSDP_ADDR = "239.255.255.250";
    static final int SSDP_PORT = 1900;
    static final String ST_RENDERER_1 = "urn:schemas-upnp-org:device:MediaRenderer:1";
    static final String ST_RENDERER_2 = "urn:schemas-upnp-org:device:MediaRenderer:2";
    static final String ST_AV_TRANSPORT_1 = "urn:schemas-upnp-org:service:AVTransport:1";
    static final String ST_AV_TRANSPORT_2 = "urn:schemas-upnp-org:service:AVTransport:2";
    static final String ST_RENDERING_1 = "urn:schemas-upnp-org:service:RenderingControl:1";

    static final class Device {
        final String udn;
        final String friendlyName;
        final String manufacturer;
        final String hostIp;
        final String locationUrl;
        final String avTransportControlUrl;
        final String avTransportServiceType;
        final String renderingControlUrl;

        Device(
                String udn,
                String friendlyName,
                String manufacturer,
                String hostIp,
                String locationUrl,
                String avTransportControlUrl,
                String avTransportServiceType,
                String renderingControlUrl) {
            this.udn = udn == null ? "" : udn.trim();
            this.friendlyName =
                    friendlyName == null || friendlyName.trim().isEmpty()
                            ? ("DLNA 设备 (" + (hostIp == null ? "局域网" : hostIp) + ")")
                            : friendlyName.trim();
            this.manufacturer = manufacturer == null ? "" : manufacturer.trim();
            this.hostIp = hostIp == null ? "" : hostIp.trim();
            this.locationUrl = locationUrl == null ? "" : locationUrl.trim();
            this.avTransportControlUrl =
                    avTransportControlUrl == null ? "" : avTransportControlUrl.trim();
            this.avTransportServiceType =
                    avTransportServiceType == null || avTransportServiceType.trim().isEmpty()
                            ? ST_AV_TRANSPORT_1
                            : avTransportServiceType.trim();
            this.renderingControlUrl =
                    renderingControlUrl == null ? "" : renderingControlUrl.trim();
        }
    }

    private DlnaCastClient() {}

    /** Extracts unique valid LAN HTTP LOCATION URLs from raw SSDP response datagrams. */
    static List<String> parseSsdpLocations(List<String> rawResponses) {
        List<String> out = new ArrayList<>();
        if (rawResponses == null || rawResponses.isEmpty()) return out;
        Set<String> seen = new LinkedHashSet<>();
        for (String resp : rawResponses) {
            if (resp == null || resp.isEmpty()) continue;
            for (String line : resp.split("\r?\n")) {
                int colon = line.indexOf(':');
                if (colon <= 0) continue;
                String key = line.substring(0, colon).trim().toLowerCase(Locale.ROOT);
                if (!"location".equals(key)) continue;
                String loc = line.substring(colon + 1).trim();
                if (isSafeLanHttpUrl(loc) && seen.add(loc)) {
                    out.add(loc);
                }
                break;
            }
        }
        return out;
    }

    static boolean isSafeLanHttpUrl(String raw) {
        if (raw == null) return false;
        String url = raw.trim();
        if (url.isEmpty() || url.length() > 2048) return false;
        try {
            URI uri = new URI(url);
            String scheme = uri.getScheme();
            if (scheme == null) return false;
            if (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme)) return false;
            String host = uri.getHost();
            if (host == null || host.trim().isEmpty()) return false;
            String low = host.trim().toLowerCase(Locale.ROOT);
            if ("localhost".equals(low)
                    || "0.0.0.0".equals(low)
                    || "::1".equals(low)
                    || low.startsWith("127.")) {
                return false;
            }
            InetAddress addr = InetAddress.getByName(low);
            return addr != null
                    && !addr.isLoopbackAddress()
                    && !addr.isAnyLocalAddress()
                    && (addr.isSiteLocalAddress() || addr.isLinkLocalAddress());
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static DocumentBuilder newSafeXmlBuilder() throws Exception {
        DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
        dbf.setNamespaceAware(true);
        try {
            dbf.setXIncludeAware(false);
        } catch (Throwable ignored) {
        }
        try {
            dbf.setExpandEntityReferences(false);
        } catch (Throwable ignored) {
        }
        try {
            dbf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        } catch (Throwable ignored) {
        }
        String[] disable = {
            "http://xml.org/sax/features/external-general-entities",
            "http://xml.org/sax/features/external-parameter-entities",
            "http://apache.org/xml/features/nonvalidating/load-external-dtd"
        };
        for (String feat : disable) {
            try {
                dbf.setFeature(feat, false);
            } catch (Throwable ignored) {
            }
        }
        return dbf.newDocumentBuilder();
    }

    private static String localName(Node n) {
        if (n == null) return "";
        String ln = n.getLocalName();
        if (ln != null && !ln.isEmpty()) return ln;
        String raw = n.getNodeName();
        if (raw == null) return "";
        int colon = raw.indexOf(':');
        return colon >= 0 ? raw.substring(colon + 1) : raw;
    }

    private static String firstChildText(Element parent, String tag) {
        if (parent == null || tag == null) return "";
        NodeList kids = parent.getChildNodes();
        for (int i = 0; i < kids.getLength(); i++) {
            Node n = kids.item(i);
            if (n.getNodeType() == Node.ELEMENT_NODE && tag.equalsIgnoreCase(localName(n))) {
                String txt = n.getTextContent();
                return txt == null ? "" : txt.trim();
            }
        }
        return "";
    }

    /**
     * Parses an XXE-checked UPnP {@code device.xml} document and extracts an AVTransport-capable
     * DLNA MediaRenderer target. Returns {@code null} if malformed, unsafe, or lacking AVTransport.
     */
    static Device parseDeviceDescriptionXml(String locationUrl, String xml) {
        if (!isSafeLanHttpUrl(locationUrl) || xml == null || xml.trim().isEmpty()) return null;
        if (xml.indexOf('\0') >= 0) return null;
        String upper = xml.toUpperCase(Locale.ROOT);
        if (upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY")) return null;
        try {
            Document doc =
                    newSafeXmlBuilder()
                            .parse(new ByteArrayInputStream(xml.getBytes(StandardCharsets.UTF_8)));
            Element root = doc.getDocumentElement();
            if (root == null) return null;

            String urlBase = firstChildText(root, "URLBase");
            URI baseUri = new URI(isSafeLanHttpUrl(urlBase) ? urlBase : locationUrl);
            String hostIp = baseUri.getHost() == null ? "" : baseUri.getHost();

            NodeList devices = doc.getElementsByTagName("*");
            Element bestDevice = null;
            for (int i = 0; i < devices.getLength(); i++) {
                Node n = devices.item(i);
                if (n.getNodeType() == Node.ELEMENT_NODE
                        && "device".equalsIgnoreCase(localName(n))) {
                    bestDevice = (Element) n;
                    String dt = firstChildText(bestDevice, "deviceType");
                    if (dt.toLowerCase(Locale.ROOT).contains("mediarenderer")) break;
                }
            }
            if (bestDevice == null) return null;

            String udn = firstChildText(bestDevice, "UDN");
            String friendlyName = firstChildText(bestDevice, "friendlyName");
            String manufacturer = firstChildText(bestDevice, "manufacturer");
            String avControlUrl = "";
            String avServiceType = ST_AV_TRANSPORT_1;
            String rcControlUrl = "";

            NodeList all = doc.getElementsByTagName("*");
            for (int i = 0; i < all.getLength(); i++) {
                Node n = all.item(i);
                if (n.getNodeType() != Node.ELEMENT_NODE
                        || !"service".equalsIgnoreCase(localName(n))) {
                    continue;
                }
                Element svc = (Element) n;
                String svcType = firstChildText(svc, "serviceType");
                String ctrl = firstChildText(svc, "controlURL");
                if (ctrl.isEmpty()) continue;
                String resolved = resolveControlUrl(baseUri, ctrl);
                if (resolved.isEmpty()) continue;
                String lowType = svcType.toLowerCase(Locale.ROOT);
                if (lowType.contains("avtransport") && avControlUrl.isEmpty()) {
                    avControlUrl = resolved;
                    avServiceType = svcType;
                } else if (lowType.contains("renderingcontrol") && rcControlUrl.isEmpty()) {
                    rcControlUrl = resolved;
                }
            }
            if (avControlUrl.isEmpty()) return null;
            return new Device(
                    udn,
                    friendlyName,
                    manufacturer,
                    hostIp,
                    locationUrl,
                    avControlUrl,
                    avServiceType,
                    rcControlUrl);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static String resolveControlUrl(URI baseUri, String rawControlUrl) {
        try {
            URI resolved = baseUri.resolve(rawControlUrl.trim());
            String str = resolved.toString();
            if (!isSafeLanHttpUrl(str)) return "";
            // Prevent cross-host redirection inside a rogue device.xml
            if (baseUri.getHost() != null
                    && !baseUri.getHost().equalsIgnoreCase(resolved.getHost())) {
                return "";
            }
            return str;
        } catch (Throwable ignored) {
            return "";
        }
    }

    static String escapeXml(String s) {
        if (s == null || s.isEmpty()) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&apos;");
    }

    static String buildDidlMetadata(String mediaUrl, String title) {
        String safeTitle =
                title == null || title.trim().isEmpty() ? "Marco Movie 投屏视频" : title.trim();
        String safeUrl = mediaUrl == null ? "" : mediaUrl.trim();
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
                + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
                + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
                + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
                + "<dc:title>"
                + escapeXml(safeTitle)
                + "</dc:title>"
                + "<upnp:class>object.item.videoItem</upnp:class>"
                + "<res protocolInfo=\"http-get:*:video/*:*\">"
                + escapeXml(safeUrl)
                + "</res>"
                + "</item></DIDL-Lite>";
    }

    static String buildSoapEnvelope(String serviceType, String action, Map<String, String> args) {
        String ns =
                serviceType == null || serviceType.trim().isEmpty()
                        ? ST_AV_TRANSPORT_1
                        : serviceType.trim();
        String safeAction = action == null ? "" : action.replaceAll("[^A-Za-z0-9_]", "");
        StringBuilder sb = new StringBuilder(384);
        sb.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
        sb.append(
                "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
                        + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">");
        sb.append("<s:Body><u:").append(safeAction).append(" xmlns:u=\"").append(ns).append("\">");
        if (args != null) {
            for (Map.Entry<String, String> e : args.entrySet()) {
                String k = e.getKey() == null ? "" : e.getKey().replaceAll("[^A-Za-z0-9_]", "");
                if (k.isEmpty()) continue;
                sb.append('<')
                        .append(k)
                        .append('>')
                        .append(escapeXml(e.getValue()))
                        .append("</")
                        .append(k)
                        .append('>');
            }
        }
        sb.append("</u:").append(safeAction).append("></s:Body></s:Envelope>");
        return sb.toString();
    }

    static List<Device> discoverDevices(int timeoutMs, String excludeUuid) {
        int clampedTimeout = Math.max(800, Math.min(4500, timeoutMs));
        List<String> rawPackets = new ArrayList<>();
        String[] targets = {ST_RENDERER_1, ST_RENDERER_2, ST_AV_TRANSPORT_1, "ssdp:all"};
        DatagramSocket socket = null;
        try {
            socket = new DatagramSocket(null);
            socket.setReuseAddress(true);
            socket.bind(new InetSocketAddress(0));
            socket.setSoTimeout(350);
            InetAddress group = InetAddress.getByName(SSDP_ADDR);
            for (String st : targets) {
                String msg =
                        "M-SEARCH * HTTP/1.1\r\n"
                                + "HOST: "
                                + SSDP_ADDR
                                + ":"
                                + SSDP_PORT
                                + "\r\n"
                                + "MAN: \"ssdp:discover\"\r\n"
                                + "MX: 2\r\n"
                                + "ST: "
                                + st
                                + "\r\n"
                                + "USER-AGENT: Android/12 UPnP/1.0 MarcoMovie/1.0\r\n\r\n";
                byte[] bytes = msg.getBytes(StandardCharsets.UTF_8);
                socket.send(new DatagramPacket(bytes, bytes.length, group, SSDP_PORT));
            }
            long deadline = System.currentTimeMillis() + clampedTimeout;
            byte[] buf = new byte[4096];
            while (System.currentTimeMillis() < deadline && rawPackets.size() < 96) {
                try {
                    DatagramPacket pkt = new DatagramPacket(buf, buf.length);
                    socket.receive(pkt);
                    rawPackets.add(
                            new String(
                                    pkt.getData(),
                                    pkt.getOffset(),
                                    pkt.getLength(),
                                    StandardCharsets.UTF_8));
                } catch (SocketTimeoutException ignored) {
                }
            }
        } catch (Throwable ignored) {
        } finally {
            if (socket != null) {
                try {
                    socket.close();
                } catch (Throwable ignored) {
                }
            }
        }

        List<String> locations = parseSsdpLocations(rawPackets);
        List<Device> devices = new ArrayList<>();
        Set<String> seenKeys = new LinkedHashSet<>();
        String cleanExclude =
                excludeUuid == null
                        ? ""
                        : CastService.normalizeUuid(excludeUuid).toLowerCase(Locale.ROOT);
        for (String loc : locations) {
            String xml = fetchSmallXml(loc, 2400);
            if (xml == null || xml.isEmpty()) continue;
            Device dev = parseDeviceDescriptionXml(loc, xml);
            if (dev == null) continue;
            String normUdn =
                    dev.udn.isEmpty()
                            ? ""
                            : CastService.normalizeUuid(dev.udn).toLowerCase(Locale.ROOT);
            if (!cleanExclude.isEmpty() && cleanExclude.equals(normUdn)) {
                // Do not show this device's own local receiver in its outbound target picker
                continue;
            }
            String dedupKey = !normUdn.isEmpty() ? normUdn : dev.avTransportControlUrl;
            if (seenKeys.add(dedupKey)) {
                devices.add(dev);
            }
        }
        Collections.sort(devices, (x, y) -> x.friendlyName.compareToIgnoreCase(y.friendlyName));
        return devices;
    }

    private static String fetchSmallXml(String urlStr, int timeoutMs) {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(urlStr).openConnection();
            conn.setConnectTimeout(timeoutMs);
            conn.setReadTimeout(timeoutMs);
            conn.setInstanceFollowRedirects(false);
            conn.setRequestProperty("User-Agent", "MarcoMovie-DLNA/1.0");
            int code = conn.getResponseCode();
            if (code < 200 || code >= 300) return null;
            try (InputStream in = conn.getInputStream();
                    ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buf = new byte[4096];
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (out.size() + n > 256 * 1024) return null;
                    out.write(buf, 0, n);
                }
                return new String(out.toByteArray(), StandardCharsets.UTF_8);
            }
        } catch (Throwable ignored) {
            return null;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    static void castUrl(Device device, String mediaUrl, String title) throws IOException {
        if (device == null || device.avTransportControlUrl.isEmpty()) {
            throw new IOException("投屏设备控制地址不可用");
        }
        String valid = CastService.validateCastMediaUrl(mediaUrl);
        if (valid.isEmpty()) {
            throw new IOException("当前视频地址暂不支持局域网设备直接拉流");
        }
        Map<String, String> setArgs = new LinkedHashMap<>();
        setArgs.put("InstanceID", "0");
        setArgs.put("CurrentURI", valid);
        setArgs.put("CurrentURIMetaData", buildDidlMetadata(valid, title));
        postSoap(
                device.avTransportControlUrl,
                device.avTransportServiceType,
                "SetAVTransportURI",
                setArgs);

        Map<String, String> playArgs = new LinkedHashMap<>();
        playArgs.put("InstanceID", "0");
        playArgs.put("Speed", "1");
        postSoap(device.avTransportControlUrl, device.avTransportServiceType, "Play", playArgs);
    }

    static void sendTransportAction(Device device, String action, Map<String, String> extraArgs)
            throws IOException {
        if (device == null || device.avTransportControlUrl.isEmpty()) {
            throw new IOException("投屏设备未连接");
        }
        Map<String, String> args = new LinkedHashMap<>();
        args.put("InstanceID", "0");
        if (extraArgs != null) args.putAll(extraArgs);
        postSoap(device.avTransportControlUrl, device.avTransportServiceType, action, args);
    }

    static void postSoap(
            String controlUrl, String serviceType, String action, Map<String, String> args)
            throws IOException {
        if (!isSafeLanHttpUrl(controlUrl)) {
            throw new IOException("非局域网投屏控制地址已拦截");
        }
        String body = buildSoapEnvelope(serviceType, action, args);
        byte[] payload = body.getBytes(StandardCharsets.UTF_8);
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(controlUrl).openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(4500);
            conn.setReadTimeout(4500);
            conn.setDoOutput(true);
            conn.setFixedLengthStreamingMode(payload.length);
            conn.setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"");
            conn.setRequestProperty("SOAPACTION", "\"" + serviceType + "#" + action + "\"");
            conn.setRequestProperty("User-Agent", "MarcoMovie-DLNA/1.0");
            try (OutputStream out = conn.getOutputStream()) {
                out.write(payload);
                out.flush();
            }
            int code = conn.getResponseCode();
            if (code < 200 || code >= 300) {
                throw new IOException("设备返回 HTTP " + code);
            }
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    /**
     * Pure-JVM helper resolving a castable remote HTTP(S) URL for external LAN DLNA renderers:
     * accepts direct URLs immediately, unwraps local {@link HlsStreamProxy} or {@link
     * MediaDiskCache} loopback URLs back to their upstream HTTP(S) origins, and falls back to the
     * episode's raw HTTP(S) URL when available.
     */
    static String resolveCastableMediaUrl(String playUrl, String fallbackRawUrl) {
        String valid = CastService.validateCastMediaUrl(playUrl);
        if (!valid.isEmpty()) return valid;
        String unwrappedHls = HlsStreamProxy.originalUrlForLocalUrl(playUrl);
        valid = CastService.validateCastMediaUrl(unwrappedHls);
        if (!valid.isEmpty()) return valid;
        String unwrappedCache = MediaDiskCache.originalUrlForLocalUrl(playUrl);
        valid = CastService.validateCastMediaUrl(unwrappedCache);
        if (!valid.isEmpty()) return valid;
        return CastService.validateCastMediaUrl(fallbackRawUrl);
    }

    /**
     * Opens an iQIYI/Youku/Tencent-style selectable DLNA cast device picker dialog during playback
     * or from the Cast hub. Uses a Day/Night {@link MobileBottomSheet} on phones/tablets.
     */
    static void showCastDevicePicker(
            final MainActivity a,
            final String mediaUrl,
            final String mediaTitle,
            final Runnable onCastStarted) {
        if (a == null || a.isFinishing()) return;
        if (a.privateMode) {
            a.toast("隐私空间已隔离局域网投屏，退出后即可使用");
            return;
        }
        if (!a.isTvDevice()) {
            showMobileCastDevicePicker(a, mediaUrl, mediaTitle, onCastStarted);
            return;
        }
        final LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));

        final TextView status = a.text("正在搜索同一局域网内可投屏设备（电视 / 投影仪 / 盒子）…", 13.5f, 0xff9ec5ff);
        status.setLineSpacing(a.dp(3), 1f);
        box.addView(status, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 10);

        final LinearLayout listHost = a.vertical();
        box.addView(listHost, new LinearLayout.LayoutParams(-1, -2));

        final AppDialog[] dlgRef = new AppDialog[1];
        final Runnable[] scanRef = new Runnable[1];
        final Button rescanBtn =
                a.button(
                        "重新搜索设备",
                        "dlna-rescan",
                        () -> {
                            if (scanRef[0] != null) scanRef[0].run();
                        });
        LinearLayout.LayoutParams rescanLp = new LinearLayout.LayoutParams(-2, a.dp(40));
        rescanLp.topMargin = a.dp(8);
        box.addView(rescanBtn, rescanLp);
        final String selfUuid =
                a.castService != null
                        ? a.castService.deviceUuid
                        : a.prefs.getString(Prefs.CAST_DEVICE_UUID, "");

        scanRef[0] =
                () -> {
                    status.setText("正在搜索局域网内的可投屏设备…");
                    status.setTextColor(0xff9ec5ff);
                    listHost.removeAllViews();
                    a.worker.execute(
                            () -> {
                                final List<Device> found = discoverDevices(2200, selfUuid);
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || dlgRef[0] == null
                                                    || !dlgRef[0].isShowing()) {
                                                return;
                                            }
                                            listHost.removeAllViews();
                                            if (found.isEmpty()) {
                                                status.setText(
                                                        "未发现其他局域网 DLNA 投屏设备。\n请确认目标电视 / 投影仪与本机在同一 Wi-Fi 并已开启投屏接收，然后点击「重新搜索」。");
                                                status.setTextColor(0xffffc46b);
                                                return;
                                            }
                                            status.setText(
                                                    "找到 " + found.size() + " 台可投屏设备，点击即可投屏播放：");
                                            status.setTextColor(0xff7ee7c6);
                                            for (int i = 0; i < found.size(); i++) {
                                                final Device dev = found.get(i);
                                                String label =
                                                        dev.friendlyName
                                                                + (dev.hostIp.isEmpty()
                                                                        ? ""
                                                                        : "   ("
                                                                                + dev.hostIp
                                                                                + ")");
                                                Runnable onPickDevice =
                                                        () -> {
                                                            if (mediaUrl == null
                                                                    || mediaUrl.trim().isEmpty()) {
                                                                a.toast(
                                                                        "已选中投屏设备："
                                                                                + dev.friendlyName
                                                                                + "，播放影片时点「投屏」即可直接推送");
                                                                if (dlgRef[0] != null) {
                                                                    dlgRef[0].dismiss();
                                                                }
                                                                return;
                                                            }
                                                            status.setText(
                                                                    "正在向「"
                                                                            + dev.friendlyName
                                                                            + "」发起投屏…");
                                                            status.setTextColor(0xff9ec5ff);
                                                            a.worker.execute(
                                                                    () -> {
                                                                        try {
                                                                            castUrl(
                                                                                    dev,
                                                                                    mediaUrl,
                                                                                    mediaTitle);
                                                                            a.ui.post(
                                                                                    () -> {
                                                                                        if (dlgRef[
                                                                                                        0]
                                                                                                != null) {
                                                                                            dlgRef[
                                                                                                    0]
                                                                                                    .dismiss();
                                                                                        }
                                                                                        if (onCastStarted
                                                                                                != null) {
                                                                                            onCastStarted
                                                                                                    .run();
                                                                                        }
                                                                                        showActiveRemoteDialog(
                                                                                                a,
                                                                                                dev,
                                                                                                mediaUrl,
                                                                                                mediaTitle);
                                                                                    });
                                                                        } catch (Throwable err) {
                                                                            a.ui.post(
                                                                                    () -> {
                                                                                        status
                                                                                                .setText(
                                                                                                        "投屏失败："
                                                                                                                + (err
                                                                                                                                        .getMessage()
                                                                                                                                != null
                                                                                                                        ? err
                                                                                                                                .getMessage()
                                                                                                                        : "设备无响应"));
                                                                                        status
                                                                                                .setTextColor(
                                                                                                        0xffff8b7b);
                                                                                    });
                                                                        }
                                                                    });
                                                        };
                                                LinearLayout devRow = a.row();
                                                devRow.setTag("dlna-target:" + i);
                                                devRow.setGravity(
                                                        Gravity.START | Gravity.CENTER_VERTICAL);
                                                devRow.setPadding(
                                                        a.dp(14), a.dp(11), a.dp(14), a.dp(11));
                                                devRow.setBackground(a.bg(0xff1e2430, 12));
                                                MobileIcons.IconView castIc =
                                                        MobileIcons.create(
                                                                a,
                                                                MobileIcons.IC_CAST,
                                                                18f,
                                                                0xff7ee7c6);
                                                LinearLayout.LayoutParams ilp =
                                                        new LinearLayout.LayoutParams(
                                                                a.dp(18), a.dp(18));
                                                ilp.rightMargin = a.dp(10);
                                                devRow.addView(castIc, ilp);
                                                TextView nameTv =
                                                        a.text(label, 14f, MainActivity.WHITE);
                                                nameTv.setSingleLine(true);
                                                nameTv.setEllipsize(
                                                        android.text.TextUtils.TruncateAt.END);
                                                devRow.addView(
                                                        nameTv,
                                                        new LinearLayout.LayoutParams(0, -2, 1f));
                                                MobileDetailScreen.bindTouchFeedback(devRow);
                                                devRow.setOnClickListener(v -> onPickDevice.run());
                                                LinearLayout.LayoutParams lp =
                                                        new LinearLayout.LayoutParams(-1, -2);
                                                lp.bottomMargin = a.dp(8);
                                                listHost.addView(devRow, lp);
                                            }
                                            if (listHost.getChildCount() > 0) {
                                                listHost.getChildAt(0).requestFocus();
                                            }
                                        });
                            });
                };

        AppDialog.Builder b =
                new AppDialog.Builder(a)
                        .setTitle("选择投屏设备")
                        .setWide(true)
                        .setView(box)
                        .setNegativeButton("关闭", null);
        if (mediaUrl == null || mediaUrl.trim().isEmpty()) {
            b.setPositiveButton(
                    "查看本机接收设置",
                    (d, w) -> {
                        if (a.activeCastScreen != null) a.activeCastScreen.show();
                    });
        }
        AppDialog dlg = b.create();
        dlgRef[0] = dlg;
        dlg.show();
        scanRef[0].run();
    }

    private static void showActiveRemoteDialog(
            final MainActivity a,
            final Device dev,
            final String mediaUrl,
            final String mediaTitle) {
        if (a == null || a.isFinishing()) return;
        LinearLayout panel = a.vertical();
        panel.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(4));

        TextView head =
                a.text("正在投屏至：" + dev.friendlyName + " (" + dev.hostIp + ")", 15, 0xff7ee7c6);
        head.setTypeface(null, Typeface.BOLD);
        panel.addView(head);
        if (mediaTitle != null && !mediaTitle.trim().isEmpty()) {
            a.gap(panel, 4);
            panel.addView(a.text("当前影片：" + mediaTitle.trim(), 13, 0xffd0d7e6));
        }
        a.gap(panel, 12);

        final TextView feedback = a.text("已连接，可使用遥控器控制播放状态", 12.5f, MainActivity.MUTED);
        panel.addView(feedback);
        a.gap(panel, 12);

        LinearLayout row = a.row();
        final AppDialog[] remoteRef = new AppDialog[1];
        Runnable sendPause =
                () ->
                        a.worker.execute(
                                () -> {
                                    try {
                                        sendTransportAction(dev, "Pause", null);
                                        a.ui.post(() -> feedback.setText("已发送：暂停播放"));
                                    } catch (Throwable e) {
                                        a.ui.post(() -> feedback.setText("暂停指令发送失败"));
                                    }
                                });
        Runnable sendPlay =
                () ->
                        a.worker.execute(
                                () -> {
                                    try {
                                        Map<String, String> args = new LinkedHashMap<>();
                                        args.put("Speed", "1");
                                        sendTransportAction(dev, "Play", args);
                                        a.ui.post(() -> feedback.setText("已发送：继续播放"));
                                    } catch (Throwable e) {
                                        a.ui.post(() -> feedback.setText("继续播放指令发送失败"));
                                    }
                                });
        Runnable sendStop =
                () ->
                        a.worker.execute(
                                () -> {
                                    try {
                                        sendTransportAction(dev, "Stop", null);
                                    } catch (Throwable ignored) {
                                    }
                                    a.ui.post(
                                            () -> {
                                                a.toast("已退出投屏");
                                                if (remoteRef[0] != null) remoteRef[0].dismiss();
                                            });
                                });

        Button pauseBtn = a.button("暂停", "dlna-remote-pause", sendPause);
        Button playBtn = a.button("继续播放", "dlna-remote-play", sendPlay);
        Button switchBtn =
                a.button(
                        "切换设备",
                        "dlna-remote-switch",
                        () -> {
                            if (remoteRef[0] != null) remoteRef[0].dismiss();
                            showCastDevicePicker(a, mediaUrl, mediaTitle, null);
                        });
        Button stopBtn = a.button("退出投屏", "dlna-remote-stop", sendStop);
        Button[] btns = {pauseBtn, playBtn, switchBtn, stopBtn};
        for (int i = 0; i < btns.length; i++) {
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
            if (i > 0) lp.leftMargin = a.dp(8);
            row.addView(btns[i], lp);
        }
        panel.addView(row, new LinearLayout.LayoutParams(-1, -2));

        AppDialog dlg =
                new AppDialog.Builder(a)
                        .setTitle("投屏遥控")
                        .setWide(true)
                        .setView(panel)
                        .setNegativeButton("隐藏面板", null)
                        .create();
        remoteRef[0] = dlg;
        dlg.show();
        pauseBtn.requestFocus();
    }

    private static void showMobileCastDevicePicker(
            final MainActivity a,
            final String mediaUrl,
            final String mediaTitle,
            final Runnable onCastStarted) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        final LinearLayout body = a.vertical();
        body.setTag("mobile-dlna-picker");

        if (mediaTitle != null && !mediaTitle.trim().isEmpty()) {
            TextView mediaBanner = a.text("当前播放：" + mediaTitle.trim(), 12.5f, p.textSecondary);
            mediaBanner.setSingleLine(true);
            mediaBanner.setEllipsize(TextUtils.TruncateAt.END);
            mediaBanner.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
            mediaBanner.setBackground(MobileTheme.subtleBg(a, 12));
            LinearLayout.LayoutParams mbLp = new LinearLayout.LayoutParams(-1, -2);
            mbLp.bottomMargin = a.dp(12);
            body.addView(mediaBanner, mbLp);
        }

        LinearLayout statusBar = a.row();
        statusBar.setGravity(Gravity.CENTER_VERTICAL);
        statusBar.setPadding(a.dp(2), 0, a.dp(2), a.dp(10));

        final BrandLogoLoaderView spinner = new BrandLogoLoaderView(a);
        spinner.setReducedMotion(MobileMotion.isReduced(a));
        spinner.setActive(true);
        LinearLayout.LayoutParams spLp = new LinearLayout.LayoutParams(a.dp(18), a.dp(18));
        spLp.rightMargin = a.dp(8);
        statusBar.addView(spinner, spLp);

        final TextView status = a.text("正在搜索同一局域网内的电视 / 盒子 / 投影仪…", 13f, p.textSecondary);
        status.setLineSpacing(a.dp(2), 1f);
        statusBar.addView(status, new LinearLayout.LayoutParams(0, -2, 1f));

        final Runnable[] scanRef = new Runnable[1];
        LinearLayout rescanPill = a.row();
        rescanPill.setTag("dlna-rescan");
        rescanPill.setGravity(Gravity.CENTER_VERTICAL);
        rescanPill.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
        rescanPill.setBackground(MobileTheme.subtleBg(a, 999));
        MobileIcons.IconView refreshIc =
                MobileIcons.create(a, MobileIcons.IC_REFRESH, 13f, p.accent);
        LinearLayout.LayoutParams riLp = new LinearLayout.LayoutParams(a.dp(13), a.dp(13));
        riLp.rightMargin = a.dp(4);
        rescanPill.addView(refreshIc, riLp);
        TextView refreshTxt = a.text("重新搜索", 12f, p.accent);
        refreshTxt.setTypeface(null, Typeface.BOLD);
        rescanPill.addView(refreshTxt);
        MobileMotion.bindPress(rescanPill, 0.94f);
        rescanPill.setOnClickListener(
                v -> {
                    if (scanRef[0] != null) scanRef[0].run();
                });
        LinearLayout.LayoutParams rpLp = new LinearLayout.LayoutParams(-2, -2);
        rpLp.leftMargin = a.dp(8);
        statusBar.addView(rescanPill, rpLp);
        body.addView(statusBar, new LinearLayout.LayoutParams(-1, -2));

        final LinearLayout listHost = a.vertical();
        body.addView(listHost, new LinearLayout.LayoutParams(-1, -2));

        final Dialog[] dlgRef = new Dialog[1];
        final String selfUuid =
                a.castService != null
                        ? a.castService.deviceUuid
                        : a.prefs.getString(Prefs.CAST_DEVICE_UUID, "");

        scanRef[0] =
                () -> {
                    spinner.setVisibility(View.VISIBLE);
                    spinner.setActive(true);
                    status.setText("正在搜索同一局域网内的可投屏设备…");
                    status.setTextColor(p.textSecondary);
                    listHost.removeAllViews();
                    a.worker.execute(
                            () -> {
                                final List<Device> found = discoverDevices(2200, selfUuid);
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || dlgRef[0] == null
                                                    || !dlgRef[0].isShowing()) {
                                                return;
                                            }
                                            spinner.setActive(false);
                                            spinner.setVisibility(View.GONE);
                                            listHost.removeAllViews();
                                            if (found.isEmpty()) {
                                                status.setText("未发现同一局域网内的 DLNA 投屏设备");
                                                status.setTextColor(p.warning);
                                                TextView hint =
                                                        a.text(
                                                                "请确认目标电视 / 盒子 / 投影仪与本机连接同一 Wi-Fi，并已开启无线投屏或 DLNA 接收功能，然后点击右上角「重新搜索」。",
                                                                12.5f,
                                                                p.textTertiary);
                                                hint.setLineSpacing(a.dp(3), 1f);
                                                hint.setPadding(
                                                        a.dp(14), a.dp(12), a.dp(14), a.dp(12));
                                                hint.setBackground(MobileTheme.subtleBg(a, 14));
                                                listHost.addView(
                                                        hint,
                                                        new LinearLayout.LayoutParams(-1, -2));
                                                return;
                                            }
                                            status.setText("发现 " + found.size() + " 台设备，轻触立即投屏");
                                            status.setTextColor(p.success);
                                            for (int i = 0; i < found.size(); i++) {
                                                final Device dev = found.get(i);
                                                LinearLayout row = a.row();
                                                row.setTag("dlna-target:" + i);
                                                row.setGravity(Gravity.CENTER_VERTICAL);
                                                row.setPadding(
                                                        a.dp(12), a.dp(11), a.dp(12), a.dp(11));
                                                row.setBackground(MobileTheme.cardBg(a, 14));

                                                FrameLayout icBadge = new FrameLayout(a);
                                                icBadge.setBackground(
                                                        a.bg(
                                                                MobileTheme.withAlpha(
                                                                        p.accent,
                                                                        p.isDark ? 0x2E : 0x1A),
                                                                10));
                                                MobileIcons.IconView castIc =
                                                        MobileIcons.create(
                                                                a,
                                                                MobileIcons.IC_CAST,
                                                                17f,
                                                                p.accent);
                                                icBadge.addView(
                                                        castIc,
                                                        new FrameLayout.LayoutParams(
                                                                a.dp(17),
                                                                a.dp(17),
                                                                Gravity.CENTER));
                                                LinearLayout.LayoutParams icLp =
                                                        new LinearLayout.LayoutParams(
                                                                a.dp(36), a.dp(36));
                                                icLp.rightMargin = a.dp(12);
                                                row.addView(icBadge, icLp);

                                                LinearLayout copy = a.vertical();
                                                TextView nameTv =
                                                        a.text(
                                                                dev.friendlyName,
                                                                14.5f,
                                                                p.textPrimary);
                                                nameTv.setTypeface(null, Typeface.BOLD);
                                                nameTv.setSingleLine(true);
                                                nameTv.setEllipsize(TextUtils.TruncateAt.END);
                                                copy.addView(nameTv);
                                                if (!dev.hostIp.isEmpty()) {
                                                    TextView ipTv =
                                                            a.text(
                                                                    dev.hostIp,
                                                                    11.5f,
                                                                    p.textTertiary);
                                                    ipTv.setPadding(0, a.dp(2), 0, 0);
                                                    copy.addView(ipTv);
                                                }
                                                row.addView(
                                                        copy,
                                                        new LinearLayout.LayoutParams(0, -2, 1f));

                                                MobileIcons.IconView chev =
                                                        MobileIcons.create(
                                                                a,
                                                                MobileIcons.IC_CHEVRON_RIGHT,
                                                                14f,
                                                                p.textTertiary);
                                                row.addView(
                                                        chev,
                                                        new LinearLayout.LayoutParams(
                                                                a.dp(14), a.dp(14)));

                                                MobileMotion.bindPress(row, 0.97f);
                                                row.setOnClickListener(
                                                        v -> {
                                                            if (mediaUrl == null
                                                                    || mediaUrl.trim().isEmpty()) {
                                                                a.toast(
                                                                        "已选中设备："
                                                                                + dev.friendlyName
                                                                                + "，播放影片时点「投屏」即可推送");
                                                                if (dlgRef[0] != null) {
                                                                    dlgRef[0].dismiss();
                                                                }
                                                                return;
                                                            }
                                                            spinner.setVisibility(View.VISIBLE);
                                                            spinner.setActive(true);
                                                            status.setText(
                                                                    "正在向「"
                                                                            + dev.friendlyName
                                                                            + "」发起投屏…");
                                                            status.setTextColor(p.accent);
                                                            a.worker.execute(
                                                                    () -> {
                                                                        try {
                                                                            castUrl(
                                                                                    dev,
                                                                                    mediaUrl,
                                                                                    mediaTitle);
                                                                            a.ui.post(
                                                                                    () -> {
                                                                                        if (dlgRef[
                                                                                                        0]
                                                                                                != null) {
                                                                                            dlgRef[
                                                                                                    0]
                                                                                                    .dismiss();
                                                                                        }
                                                                                        if (onCastStarted
                                                                                                != null) {
                                                                                            onCastStarted
                                                                                                    .run();
                                                                                        }
                                                                                        showMobileActiveRemoteSheet(
                                                                                                a,
                                                                                                dev,
                                                                                                mediaUrl,
                                                                                                mediaTitle);
                                                                                    });
                                                                        } catch (Throwable err) {
                                                                            a.ui.post(
                                                                                    () -> {
                                                                                        spinner
                                                                                                .setActive(
                                                                                                        false);
                                                                                        spinner
                                                                                                .setVisibility(
                                                                                                        View
                                                                                                                .GONE);
                                                                                        status
                                                                                                .setText(
                                                                                                        "投屏失败："
                                                                                                                + (err
                                                                                                                                        .getMessage()
                                                                                                                                != null
                                                                                                                        ? err
                                                                                                                                .getMessage()
                                                                                                                        : "设备无响应"));
                                                                                        status
                                                                                                .setTextColor(
                                                                                                        p.danger);
                                                                                    });
                                                                        }
                                                                    });
                                                        });
                                                LinearLayout.LayoutParams rLp =
                                                        new LinearLayout.LayoutParams(-1, -2);
                                                rLp.bottomMargin = a.dp(8);
                                                listHost.addView(row, rLp);
                                            }
                                        });
                            });
                };

        dlgRef[0] =
                MobileBottomSheet.show(a, "投屏到设备", "选择同一 Wi-Fi 下的电视或投屏盒子", null, null, body, true);
        scanRef[0].run();
    }

    private static void showMobileActiveRemoteSheet(
            final MainActivity a,
            final Device dev,
            final String mediaUrl,
            final String mediaTitle) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout body = a.vertical();
        body.setTag("mobile-dlna-remote");

        LinearLayout card = a.vertical();
        card.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        card.setBackground(MobileTheme.cardBg(a, 16));

        LinearLayout headRow = a.row();
        headRow.setGravity(Gravity.CENTER_VERTICAL);
        View dot = new View(a);
        dot.setBackground(a.bg(p.success, 999));
        LinearLayout.LayoutParams dLp = new LinearLayout.LayoutParams(a.dp(8), a.dp(8));
        dLp.rightMargin = a.dp(8);
        headRow.addView(dot, dLp);
        TextView head =
                a.text(
                        dev.friendlyName + (dev.hostIp.isEmpty() ? "" : " · " + dev.hostIp),
                        14.5f,
                        p.textPrimary);
        head.setTypeface(null, Typeface.BOLD);
        head.setSingleLine(true);
        head.setEllipsize(TextUtils.TruncateAt.END);
        headRow.addView(head, new LinearLayout.LayoutParams(0, -2, 1f));
        card.addView(headRow, new LinearLayout.LayoutParams(-1, -2));

        if (mediaTitle != null && !mediaTitle.trim().isEmpty()) {
            TextView titleTv = a.text("正在投屏：" + mediaTitle.trim(), 12.5f, p.textSecondary);
            titleTv.setSingleLine(true);
            titleTv.setEllipsize(TextUtils.TruncateAt.END);
            titleTv.setPadding(0, a.dp(6), 0, 0);
            card.addView(titleTv);
        }

        final TextView feedback = a.text("已连接，可远程控制大屏播放状态", 12f, p.textTertiary);
        feedback.setPadding(0, a.dp(4), 0, 0);
        card.addView(feedback);

        LinearLayout.LayoutParams cLp = new LinearLayout.LayoutParams(-1, -2);
        cLp.bottomMargin = a.dp(14);
        body.addView(card, cLp);

        final Dialog[] remoteRef = new Dialog[1];
        LinearLayout btnRow = a.row();
        btnRow.setGravity(Gravity.CENTER_VERTICAL);

        Runnable sendPause =
                () ->
                        a.worker.execute(
                                () -> {
                                    try {
                                        sendTransportAction(dev, "Pause", null);
                                        a.ui.post(() -> feedback.setText("已发送：暂停播放"));
                                    } catch (Throwable e) {
                                        a.ui.post(() -> feedback.setText("暂停指令发送失败"));
                                    }
                                });
        Runnable sendPlay =
                () ->
                        a.worker.execute(
                                () -> {
                                    try {
                                        Map<String, String> args = new LinkedHashMap<>();
                                        args.put("Speed", "1");
                                        sendTransportAction(dev, "Play", args);
                                        a.ui.post(() -> feedback.setText("已发送：继续播放"));
                                    } catch (Throwable e) {
                                        a.ui.post(() -> feedback.setText("继续播放指令发送失败"));
                                    }
                                });
        Runnable sendSwitch =
                () -> {
                    if (remoteRef[0] != null) remoteRef[0].dismiss();
                    showCastDevicePicker(a, mediaUrl, mediaTitle, null);
                };
        Runnable sendStop =
                () ->
                        a.worker.execute(
                                () -> {
                                    try {
                                        sendTransportAction(dev, "Stop", null);
                                    } catch (Throwable ignored) {
                                    }
                                    a.ui.post(
                                            () -> {
                                                a.toast("已退出投屏");
                                                if (remoteRef[0] != null) remoteRef[0].dismiss();
                                            });
                                });

        int[] icons = {
            MobileIcons.IC_PAUSE,
            MobileIcons.IC_PLAY,
            MobileIcons.IC_SWITCH_SOURCE,
            MobileIcons.IC_CLOSE
        };
        String[] labels = {"暂停", "继续", "换设备", "退出"};
        String[] tags = {
            "dlna-remote-pause", "dlna-remote-play", "dlna-remote-switch", "dlna-remote-stop"
        };
        Runnable[] actions = {sendPause, sendPlay, sendSwitch, sendStop};
        for (int i = 0; i < icons.length; i++) {
            final Runnable act = actions[i];
            boolean danger = i == 3;
            LinearLayout cell = a.vertical();
            cell.setTag(tags[i]);
            cell.setGravity(Gravity.CENTER);
            cell.setPadding(a.dp(6), a.dp(12), a.dp(6), a.dp(12));
            cell.setBackground(
                    danger
                            ? a.bg(MobileTheme.withAlpha(p.danger, p.isDark ? 0x2E : 0x18), 14)
                            : MobileTheme.subtleBg(a, 14));
            MobileIcons.IconView ic =
                    MobileIcons.create(a, icons[i], 18f, danger ? p.danger : p.textPrimary);
            cell.addView(ic, new LinearLayout.LayoutParams(a.dp(18), a.dp(18)));
            TextView lbl = a.text(labels[i], 12f, danger ? p.danger : p.textPrimary);
            lbl.setTypeface(null, Typeface.BOLD);
            lbl.setPadding(0, a.dp(6), 0, 0);
            cell.addView(lbl);
            MobileMotion.bindPress(cell, 0.94f);
            cell.setOnClickListener(v -> act.run());
            LinearLayout.LayoutParams cellLp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (i > 0) cellLp.leftMargin = a.dp(8);
            btnRow.addView(cell, cellLp);
        }
        body.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));

        remoteRef[0] = MobileBottomSheet.show(a, "投屏遥控", null, null, null, body, false);
    }

    /** Returns active site-local IPv4 network interfaces for multi-NIC SSDP sending. */
    static List<NetworkInterface> activeLanInterfaces() {
        List<NetworkInterface> list = new ArrayList<>();
        try {
            for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nif.isUp() || nif.isLoopback() || !nif.supportsMulticast()) continue;
                for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                    if (addr instanceof Inet4Address && addr.isSiteLocalAddress()) {
                        list.add(nif);
                        break;
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        return list;
    }
}

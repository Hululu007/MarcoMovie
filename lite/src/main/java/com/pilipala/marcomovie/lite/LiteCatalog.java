// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.util.Base64;
import android.util.Xml;
import com.pilipala.source.Json;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.zip.GZIPInputStream;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.*;
import org.xmlpull.v1.XmlPullParser;

/**
 * API 14-only, non-executing CMS & Live adapter.
 *
 * <p>Supports JSON CMS ({@code type=1}), MacCMS XML ({@code type=0}), Emby accounts, GZIP / Base64
 * / 2423 Hex-AES configurations, and M3U / TXT live channel lists. Unsupported plugins remain
 * visible and explicitly labeled.
 */
public final class LiteCatalog {
    public static final int MAX_BYTES = 2 * 1024 * 1024;
    public static final long REQUEST_BUDGET_NS = 18000000000L;
    public static final String USER_AGENT = "okhttp/3.15";
    public static final String SAFARI_USER_AGENT =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    private static final Set<HttpURLConnection> IN_FLIGHT =
            Collections.synchronizedSet(new HashSet<HttpURLConnection>());

    public static void cancelAll() {
        HttpURLConnection[] active;
        synchronized (IN_FLIGHT) {
            active = IN_FLIGHT.toArray(new HttpURLConnection[IN_FLIGHT.size()]);
            IN_FLIGHT.clear();
        }
        for (int i = 0; i < active.length; i++) {
            try {
                active[i].disconnect();
            } catch (Exception ignored) {
            }
        }
    }

    public static final class Site {
        public static final String STATUS_OK = "ok";
        public static final String STATUS_NEEDS_JAR = "needs-jar";
        public static final String STATUS_UNSUPPORTED_TYPE = "unsupported-type";
        public static final String STATUS_ADAPTER_MISSING = "adapter-missing";
        public static final String STATUS_EXT_TOO_LARGE = "ext-too-large";
        public static final String STATUS_CUSTOM_SITE_URL = "custom-site-url";
        public static final String STATUS_PARSER_REQUIRED = "parser-required";
        public static final int MAX_EXT_SIZE = 128 * 1024;

        public String key, name, api, playUrl = "";
        public String originalKey = "", originalApi = "", group = "默认分组";
        public int type;
        public boolean supported;
        public boolean searchable = true;
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
        public String jar = "";
        public Object ext;
        public boolean extTooLarge;
        public boolean requiresParser;

        public String siteId() {
            String k =
                    originalKey != null && originalKey.length() > 0
                            ? originalKey
                            : (key == null ? "" : key);
            String a =
                    originalApi != null && originalApi.length() > 0
                            ? originalApi
                            : (api == null ? "" : api);
            return k + "\n" + a;
        }

        public boolean isExtTooLarge() {
            if (extTooLarge) return true;
            if (ext instanceof String) {
                return ((String) ext).length() > MAX_EXT_SIZE;
            }
            if (ext instanceof JSONObject || ext instanceof JSONArray) {
                return ext.toString().length() > MAX_EXT_SIZE;
            }
            return false;
        }

        public boolean isNetdiskSite() {
            String lowerApi = api == null ? "" : api.toLowerCase(Locale.ROOT);
            String lowerName = name == null ? "" : name.toLowerCase(Locale.ROOT);
            String lowerKey = key == null ? "" : key.toLowerCase(Locale.ROOT);
            if (lowerName.contains("秒播")
                    || lowerApi.startsWith("csp_wex")
                    || lowerApi.contains("ikanbot")
                    || lowerApi.contains("yiys")) {
                return false;
            }
            return lowerApi.contains("wogg")
                    || lowerApi.contains("ainew")
                    || lowerApi.contains("qwmkv")
                    || lowerApi.contains("soai")
                    || lowerApi.contains("sokaka")
                    || lowerApi.contains("seedhub")
                    || lowerApi.contains("pansou")
                    || lowerApi.contains("s_zps")
                    || lowerApi.contains("ypanso")
                    || lowerApi.contains("bpanso")
                    || lowerApi.contains("yiso")
                    || lowerApi.contains("panta")
                    || lowerApi.contains("mypan")
                    || lowerKey.contains("mypan")
                    || lowerName.contains("我的云盘")
                    || lowerName.contains("我的网盘")
                    || lowerName.contains("我的┃网盘")
                    || lowerName.contains("网盘")
                    || lowerName.contains("云盘")
                    || lowerApi.contains("alipansou")
                    || lowerApi.contains("tudou");
        }

        public String capabilityStatus() {
            if (isExtTooLarge()) {
                return STATUS_EXT_TOO_LARGE;
            }
            if ("mydrive".equals(key)) {
                return STATUS_UNSUPPORTED_TYPE;
            }
            if (api != null && api.startsWith("emby://account/")) {
                return STATUS_OK;
            }
            if ((type == 3 || isScriptOrJarApi(api)) && isNetdiskSite()) {
                return STATUS_ADAPTER_MISSING;
            }
            if (type == 3
                    || isScriptOrJarApi(api)
                    || (type != 0 && type != 1 && jar != null && jar.length() > 0)) {
                return STATUS_NEEDS_JAR;
            }
            if (type != 0 && type != 1) {
                return STATUS_UNSUPPORTED_TYPE;
            }
            try {
                http(api);
            } catch (Exception invalid) {
                return STATUS_CUSTOM_SITE_URL;
            }
            return STATUS_OK;
        }

        public String playbackHint() {
            if (requiresParser && (playUrl == null || playUrl.trim().length() == 0)) {
                return capabilityReason(STATUS_PARSER_REQUIRED);
            }
            return "";
        }

        public static String capabilityReason(String status) {
            if (STATUS_OK.equals(status)) {
                return "正常可用";
            } else if (STATUS_NEEDS_JAR.equals(status)) {
                return "此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持";
            } else if (STATUS_UNSUPPORTED_TYPE.equals(status)) {
                return "暂不支持此类型来源，已保留在列表中";
            } else if (STATUS_ADAPTER_MISSING.equals(status)) {
                return "此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路";
            } else if (STATUS_EXT_TOO_LARGE.equals(status)) {
                return "扩展参数超过大小上限，无法加载";
            } else if (STATUS_CUSTOM_SITE_URL.equals(status)) {
                return "此来源不是可直接请求的 HTTP(S) CMS";
            } else if (STATUS_PARSER_REQUIRED.equals(status)) {
                return "需要解析器，当前环境缺少可用解析配置";
            }
            return "此来源暂不可用";
        }

        public String limitation() {
            return capabilityReason(capabilityStatus());
        }
    }

    public static final class Category {
        public String id, name;
    }

    public static final class LiveSource {
        public String name = "";
        public String url = "";
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
    }

    public static final class LiveChannel {
        public String name = "";
        public String group = "";
        public final List<String> urls = new ArrayList<String>();
        public final Map<String, String> headers = new LinkedHashMap<String, String>();
    }

    public static final class LiveGroup {
        public String name = "";
        public final List<LiveChannel> channels = new ArrayList<LiveChannel>();
    }

    public static String http(String value) throws Exception {
        URL u = new URL(value.trim());
        String scheme = u.getProtocol();
        if ((!"http".equals(scheme) && !"https".equals(scheme))
                || u.getHost().length() == 0
                || u.getUserInfo() != null) {
            throw new IOException("请输入有效的 HTTP(S) 配置地址");
        }
        return u.toExternalForm();
    }

    public static String withoutComments(String s) {
        if (s == null) return "";
        if (s.startsWith("\ufeff")) s = s.substring(1);
        StringBuilder out = new StringBuilder(s.length());
        boolean inStr = false, esc = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (inStr) {
                out.append(c);
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') inStr = false;
            } else {
                if (c == '"') {
                    inStr = true;
                    out.append(c);
                } else if (c == '/' && i + 1 < s.length() && s.charAt(i + 1) == '/') {
                    i += 2;
                    while (i < s.length() && s.charAt(i) != '\n') i++;
                    if (i < s.length()) out.append('\n');
                } else if (c == '/' && i + 1 < s.length() && s.charAt(i + 1) == '*') {
                    i += 2;
                    while (i + 1 < s.length() && !(s.charAt(i) == '*' && s.charAt(i + 1) == '/'))
                        i++;
                    i++;
                } else out.append(c);
            }
        }
        String clean = out.toString();
        StringBuilder noTrailing = new StringBuilder(clean.length());
        inStr = false;
        esc = false;
        for (int i = 0; i < clean.length(); i++) {
            char c = clean.charAt(i);
            if (inStr) {
                noTrailing.append(c);
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') inStr = false;
                continue;
            }
            if (c == '"') {
                inStr = true;
                noTrailing.append(c);
                continue;
            }
            if (c == ',') {
                int j = i + 1;
                while (j < clean.length() && Character.isWhitespace(clean.charAt(j))) j++;
                if (j < clean.length() && (clean.charAt(j) == '}' || clean.charAt(j) == ']')) {
                    continue;
                }
            }
            noTrailing.append(c);
        }
        return noTrailing.toString();
    }

    public static boolean isHtml(String s) {
        if (s == null) return false;
        String t = s.replaceFirst("^\\uFEFF", "").trim().toLowerCase(Locale.ROOT);
        return t.startsWith("<!doctype") || t.startsWith("<html");
    }

    static boolean isScriptOrJarApi(String api) {
        if (api == null) return false;
        String lower = api.trim().toLowerCase(Locale.ROOT).split("[?#]", 2)[0];
        return lower.startsWith("csp_")
                || lower.endsWith(".js")
                || lower.endsWith(".mjs")
                || lower.endsWith(".py")
                || lower.endsWith(".jar");
    }

    static boolean hasXmlInUrlPath(String httpUrl) {
        try {
            String urlPath = new URL(http(httpUrl)).getPath();
            if (urlPath == null) return false;
            String lowerPath = urlPath.toLowerCase(Locale.ROOT);
            return lowerPath.contains("xml") || lowerPath.endsWith(".xml");
        } catch (Exception e) {
            return false;
        }
    }

    static final class HttpStatusException extends IOException {
        final int status;

        HttpStatusException(int status) {
            super("服务器返回 HTTP " + status);
            this.status = status;
        }
    }

    static final class RedirectCookie {
        final String name;
        final String value;
        final String domain;
        final boolean hostOnly;
        final String path;

        RedirectCookie(String name, String value, String domain, boolean hostOnly, String path) {
            this.name = name;
            this.value = value;
            this.domain = domain;
            this.hostOnly = hostOnly;
            this.path = path;
        }

        boolean matches(URL target) {
            String targetHost = target.getHost().toLowerCase(Locale.ROOT);
            if (hostOnly) {
                if (!targetHost.equals(domain)) return false;
            } else {
                if (!targetHost.equals(domain) && !targetHost.endsWith("." + domain)) return false;
            }
            String targetPath = target.getPath();
            if (targetPath == null || targetPath.length() == 0) targetPath = "/";
            if ("/".equals(path) || targetPath.equals(path)) return true;
            if (targetPath.startsWith(path)) {
                return path.endsWith("/") || targetPath.charAt(path.length()) == '/';
            }
            return false;
        }
    }

    static List<RedirectCookie> parseSetCookies(List<String> headerValues, URL requestUrl) {
        List<RedirectCookie> result = new ArrayList<RedirectCookie>();
        if (headerValues == null || headerValues.isEmpty()) return result;
        String reqHost = requestUrl.getHost().toLowerCase(Locale.ROOT);
        for (int j = 0; j < headerValues.size(); j++) {
            String raw = headerValues.get(j);
            if (raw == null || raw.trim().length() == 0) continue;
            String[] parts = raw.split(";");
            if (parts.length == 0) continue;
            String first = parts[0].trim();
            int eq = first.indexOf('=');
            if (eq <= 0) continue;
            String name = first.substring(0, eq).trim();
            String value = first.substring(eq + 1).trim();
            if (name.length() == 0) continue;

            String domain = reqHost;
            boolean hostOnly = true;
            String path = "/";
            boolean expired = value.length() == 0;

            for (int i = 1; i < parts.length; i++) {
                String attr = parts[i].trim();
                if (attr.length() == 0) continue;
                int aEq = attr.indexOf('=');
                String aKey =
                        (aEq < 0 ? attr : attr.substring(0, aEq)).trim().toLowerCase(Locale.ROOT);
                String aVal = aEq < 0 ? "" : attr.substring(aEq + 1).trim();
                if ("domain".equals(aKey) && aVal.length() > 0) {
                    String clean = aVal.replaceAll("^\\.+", "").toLowerCase(Locale.ROOT);
                    if (clean.indexOf('.') >= 0
                            && (reqHost.equals(clean) || reqHost.endsWith("." + clean))) {
                        domain = clean;
                        hostOnly = false;
                    }
                } else if ("path".equals(aKey) && aVal.startsWith("/")) {
                    path = aVal;
                } else if ("max-age".equals(aKey)) {
                    try {
                        long secs = Long.parseLong(aVal);
                        if (secs <= 0) expired = true;
                    } catch (Exception ignored) {
                    }
                }
            }
            if (!expired) {
                result.add(new RedirectCookie(name, value, domain, hostOnly, path));
            }
        }
        return result;
    }

    static void mergeRedirectCookies(
            Map<String, String> headers, Collection<RedirectCookie> cookies, URL target) {
        Map<String, String> map = new LinkedHashMap<String, String>();
        String existing = null;
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if ("cookie".equalsIgnoreCase(entry.getKey())) {
                existing = entry.getValue();
                break;
            }
        }
        if (existing != null && existing.trim().length() > 0) {
            String[] pairs = existing.split(";");
            for (int i = 0; i < pairs.length; i++) {
                int eq = pairs[i].indexOf('=');
                if (eq > 0) {
                    map.put(pairs[i].substring(0, eq).trim(), pairs[i].substring(eq + 1).trim());
                }
            }
        }
        for (Iterator<RedirectCookie> it = cookies.iterator(); it.hasNext(); ) {
            RedirectCookie rc = it.next();
            if (rc.matches(target)) {
                map.put(rc.name, rc.value);
            }
        }
        if (!map.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            for (Map.Entry<String, String> e : map.entrySet()) {
                if (sb.length() > 0) sb.append("; ");
                sb.append(e.getKey()).append("=").append(e.getValue());
            }
            for (Iterator<String> it = headers.keySet().iterator(); it.hasNext(); ) {
                if ("cookie".equalsIgnoreCase(it.next())) it.remove();
            }
            headers.put("Cookie", sb.toString());
        }
    }

    static Map<String, String> inheritedHeaders(URL before, URL after, Map<String, String> input) {
        Map<String, String> out = new LinkedHashMap<String, String>();
        int bp = before.getPort() < 0 ? before.getDefaultPort() : before.getPort();
        int ap = after.getPort() < 0 ? after.getDefaultPort() : after.getPort();
        boolean sameOrigin =
                before.getProtocol().equalsIgnoreCase(after.getProtocol())
                        && before.getHost().equalsIgnoreCase(after.getHost())
                        && bp == ap;
        for (Map.Entry<String, String> entry : input.entrySet()) {
            String key = entry.getKey();
            if (sameOrigin
                    || !(key.equalsIgnoreCase("Authorization")
                            || key.equalsIgnoreCase("Proxy-Authorization")
                            || key.equalsIgnoreCase("Cookie")
                            || key.equalsIgnoreCase("Cookie2"))) {
                out.put(key, entry.getValue());
            }
        }
        return out;
    }

    private static String fetchOnce(
            String address, Map<String, String> requestHeaders, String defaultUa)
            throws Exception {
        String current = http(address);
        long deadlineNs = System.nanoTime() + REQUEST_BUDGET_NS;
        Map<String, String> headers = new LinkedHashMap<String, String>();
        if (requestHeaders != null) headers.putAll(requestHeaders);
        Map<String, RedirectCookie> redirectCookies = new LinkedHashMap<String, RedirectCookie>();
        for (int redirects = 0; redirects < 6; redirects++) {
            if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs)
                throw new InterruptedIOException();
            HttpURLConnection c = (HttpURLConnection) new URL(current).openConnection();
            IN_FLIGHT.add(c);
            if (c instanceof javax.net.ssl.HttpsURLConnection)
                NetworkTls.configure((javax.net.ssl.HttpsURLConnection) c);
            int remainingMs = (int) Math.max(1000L, (deadlineNs - System.nanoTime()) / 1000000L);
            c.setConnectTimeout(Math.min(10000, remainingMs));
            c.setReadTimeout(Math.min(12000, remainingMs));
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("User-Agent", defaultUa != null ? defaultUa : USER_AGENT);
            if (headers != null)
                for (Map.Entry<String, String> h : headers.entrySet())
                    c.setRequestProperty(h.getKey(), h.getValue());
            try {
                int status = c.getResponseCode();
                List<String> setCookies = c.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry : c.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<RedirectCookie> newCookies = parseSetCookies(setCookies, new URL(current));
                for (int i = 0; i < newCookies.size(); i++) {
                    RedirectCookie cookie = newCookies.get(i);
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }
                if (status >= 300 && status < 400) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null) throw new IOException("重定向缺少地址");
                    String next = http(new URL(new URL(current), loc).toString());
                    URL before = new URL(current), after = new URL(next);
                    if ("https".equals(before.getProtocol()) && "http".equals(after.getProtocol()))
                        throw new IOException("不支持降级连接");
                    if (after.getUserInfo() != null) throw new IOException("来源重定向不能注入登录凭据");
                    if (headers != null) {
                        headers = inheritedHeaders(before, after, headers);
                    }
                    mergeRedirectCookies(headers, redirectCookies.values(), after);
                    current = next;
                    continue;
                }
                if (status < 200 || status >= 300) throw new HttpStatusException(status);
                InputStream in = c.getInputStream();
                if ("gzip".equalsIgnoreCase(c.getContentEncoding())) {
                    in = new java.util.zip.GZIPInputStream(in);
                }
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] b = new byte[8192];
                int n;
                while ((n = in.read(b)) != -1) {
                    if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadlineNs)
                        throw new InterruptedIOException();
                    if (out.size() + n > MAX_BYTES) throw new IOException("配置或列表超过大小限制");
                    out.write(b, 0, n);
                }
                return decodeText(out.toByteArray());
            } finally {
                IN_FLIGHT.remove(c);
                c.disconnect();
            }
        }
        throw new IOException("重定向过多");
    }

    public static String fetch(String address, Map<String, String> headers) throws Exception {
        String customUa = null;
        if (headers != null) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                if ("user-agent".equalsIgnoreCase(entry.getKey())) {
                    customUa = entry.getValue();
                    break;
                }
            }
        }
        return fetchOnce(address, headers, customUa != null ? customUa : USER_AGENT);
    }

    public static String fetchConfig(String address) throws Exception {
        Map<String, String> headers = new LinkedHashMap<String, String>();
        headers.put("User-Agent", USER_AGENT);
        String result;
        try {
            result = fetchOnce(address, headers, USER_AGENT);
            if (!isHtml(result)) {
                return result;
            }
        } catch (HttpStatusException e) {
            if (e.status != 403) {
                throw e;
            }
        }
        Map<String, String> fallbackHeaders = new LinkedHashMap<String, String>();
        fallbackHeaders.put("User-Agent", SAFARI_USER_AGENT);
        result = fetchOnce(address, fallbackHeaders, SAFARI_USER_AGENT);
        if (isHtml(result)) {
            throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        return result;
    }

    public static String decodeText(byte[] bytes) throws IOException {
        if (bytes.length >= 2 && (bytes[0] & 255) == 0x1f && (bytes[1] & 255) == 0x8b) {
            GZIPInputStream gz = new GZIPInputStream(new ByteArrayInputStream(bytes));
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = gz.read(buf)) != -1) {
                    if (out.size() + n > MAX_BYTES) throw new IOException("解压后内容超过大小限制");
                    out.write(buf, 0, n);
                }
                bytes = out.toByteArray();
            } finally {
                gz.close();
            }
        }
        if (bytes.length >= 2 && (bytes[0] & 255) == 0xFF && (bytes[1] & 255) == 0xD8) {
            int marker = -1;
            for (int i = bytes.length - 2; i >= 2; i--) {
                if (bytes[i] == '*' && bytes[i + 1] == '*') {
                    marker = i + 2;
                    break;
                }
            }
            if (marker >= 0) {
                int len = bytes.length - marker;
                byte[] sub = new byte[len];
                System.arraycopy(bytes, marker, sub, 0, len);
                return new String(Base64.decode(sub, Base64.DEFAULT), "UTF-8");
            }
        }
        if (bytes.length >= 3
                && (bytes[0] & 255) == 0xEF
                && (bytes[1] & 255) == 0xBB
                && (bytes[2] & 255) == 0xBF)
            return new String(bytes, 3, bytes.length - 3, "UTF-8");
        if (bytes.length >= 2 && (bytes[0] & 255) == 255 && (bytes[1] & 255) == 254)
            return new String(bytes, 2, bytes.length - 2, "UTF-16LE");
        if (bytes.length >= 2 && (bytes[0] & 255) == 254 && (bytes[1] & 255) == 255)
            return new String(bytes, 2, bytes.length - 2, "UTF-16BE");
        return new String(bytes, "UTF-8");
    }

    public static String decrypt2423(String raw) {
        if (raw == null) return "";
        String s = raw.replaceAll("\\s+", "");
        if (!s.startsWith("2423")) return raw;
        try {
            int keyEnd = s.indexOf("2324");
            while (keyEnd >= 0 && (keyEnd % 2 != 0)) {
                keyEnd = s.indexOf("2324", keyEnd + 1);
            }
            if (keyEnd < 4) return raw;
            String keyHex = s.substring(4, keyEnd);
            String body = s.substring(keyEnd + 4);
            if (body.length() < 26) return raw;
            String ivHex = body.substring(body.length() - 26);
            String cipherHex = body.substring(0, body.length() - 26);
            String keyStr = new String(hexToBytes(keyHex), "UTF-8").trim();
            String ivStr = new String(hexToBytes(ivHex), "UTF-8").trim();
            byte[] keyBytes = padRight16(keyStr.getBytes("UTF-8"));
            byte[] ivBytes = padRight16(ivStr.getBytes("UTF-8"));
            Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            cipher.init(
                    Cipher.DECRYPT_MODE,
                    new SecretKeySpec(keyBytes, "AES"),
                    new IvParameterSpec(ivBytes));
            byte[] decrypted = cipher.doFinal(hexToBytes(cipherHex));
            return new String(decrypted, "UTF-8").trim();
        } catch (Exception ignored) {
            return raw;
        }
    }

    private static byte[] padRight16(byte[] src) {
        byte[] out = new byte[16];
        for (int i = 0; i < 16; i++) {
            out[i] = i < src.length ? src[i] : (byte) '0';
        }
        return out;
    }

    private static byte[] hexToBytes(String hex) {
        int len = hex.length() / 2;
        byte[] out = new byte[len];
        for (int i = 0; i < len; i++) {
            int hi = Character.digit(hex.charAt(i * 2), 16);
            int lo = Character.digit(hex.charAt(i * 2 + 1), 16);
            out[i] = (byte) ((Math.max(0, hi) << 4) | Math.max(0, lo));
        }
        return out;
    }

    public static JSONObject decodeConfig(String raw) throws Exception {
        if (isHtml(raw)) {
            throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        String cleaned = withoutComments(raw).trim();
        if (isHtml(cleaned)) {
            throw new IOException("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        if (cleaned.startsWith("\ufeff")) cleaned = cleaned.substring(1).trim();
        if (cleaned.startsWith("2423")) {
            cleaned = withoutComments(decrypt2423(cleaned)).trim();
        }
        int star = cleaned.indexOf("**");
        if (!cleaned.startsWith("{") && !cleaned.startsWith("[")) {
            if (star >= 0) {
                try {
                    String decoded =
                            new String(
                                    Base64.decode(
                                            cleaned.substring(star + 2).replaceAll("\\s+", ""),
                                            Base64.DEFAULT),
                                    "UTF-8");
                    if (decoded.trim().startsWith("{") || decoded.trim().startsWith("["))
                        cleaned = withoutComments(decoded).trim();
                } catch (Exception ignored) {
                }
            } else if (cleaned.length() >= 16 && !cleaned.contains(" ")) {
                try {
                    String decoded =
                            new String(
                                    Base64.decode(
                                            cleaned.replaceAll("\\s+", ""),
                                            Base64.DEFAULT),
                                    "UTF-8");
                    if (decoded.trim().startsWith("{") || decoded.trim().startsWith("["))
                        cleaned = withoutComments(decoded).trim();
                } catch (Exception ignored) {
                }
            }
        }
        if (cleaned.startsWith("[")) {
            JSONArray sites = new JSONArray(cleaned);
            if (sites.length() == 0) throw new IOException("配置数组需要包含带 api 的来源对象");
            for (int i = 0; i < sites.length(); i++) {
                JSONObject item = sites.optJSONObject(i);
                Object api = item == null ? null : item.opt("api");
                if (!(api instanceof String) || ((String) api).trim().length() == 0)
                    throw new IOException("配置数组需要包含带 api 的来源对象");
            }
            return new JSONObject().put("sites", sites);
        }
        return new JSONObject(cleaned);
    }

    public static String importConfig(String raw, String origin) throws Exception {
        return com.pilipala.source.Warehouse.resolve(
                raw,
                origin,
                new com.pilipala.source.Warehouse.Reader() {
                    public String read(String url) throws Exception {
                        return fetchConfig(url);
                    }
                },
                new com.pilipala.source.Warehouse.Decoder() {
                    public JSONObject decode(String text) throws Exception {
                        return decodeConfig(text);
                    }
                },
                new com.pilipala.source.Warehouse.Validator() {
                    public void validate(String text, String base) throws Exception {
                        parse(text, base);
                    }
                });
    }

    public static List<Site> parse(String raw, String base) throws Exception {
        JSONObject document = decodeConfig(raw);
        base = Json.str(document, com.pilipala.source.Warehouse.ORIGIN, base);
        JSONArray rows = document.optJSONArray("sites");
        if ((rows == null || rows.length() == 0) && Json.str(document, "api", "").length() > 0)
            rows = new JSONArray().put(document);
        if (rows == null || rows.length() == 0) throw new IOException("配置没有 sites 列表");
        String defaultJsonParseUrl = "";
        JSONArray parses = document.optJSONArray("parses");
        if (parses != null) {
            for (int i = 0; i < parses.length(); i++) {
                JSONObject pj = parses.optJSONObject(i);
                if (pj != null) {
                    int pType = Json.integer(pj, "type", 0);
                    String pUrl = Json.str(pj, "url", "");
                    if ((pType == 1 || pType == 2 || pType == 3)
                            && (pUrl.startsWith("http://") || pUrl.startsWith("https://"))) {
                        defaultJsonParseUrl = pUrl;
                        break;
                    }
                }
            }
        }
        List<Site> sites = new ArrayList<Site>();
        for (int i = 0; i < rows.length() && i < 500; i++) {
            JSONObject row = rows.getJSONObject(i);
            Site s = new Site();
            s.name = Json.str(row, "name", "未命名");
            s.key = Json.str(row, "key", s.name + "_" + i);
            s.originalKey = s.key;
            String parsedGroup = Json.str(row, "group", "").trim();
            s.group = parsedGroup.length() > 0 ? parsedGroup : "默认分组";
            s.type = Json.integer(row, "type", -1);
            s.api = Json.str(row, "api", "");
            s.playUrl = Json.str(row, "playUrl", "");
            if (s.playUrl.length() == 0
                    && (Json.integer(row, "parse", 0) == 1 || Json.integer(row, "jx", 0) == 1)) {
                s.playUrl = defaultJsonParseUrl;
            }
            s.searchable = Json.integer(row, "searchable", 1) != 0;
            s.ext = row.opt("ext");
            s.requiresParser =
                    s.playUrl.length() > 0
                            || Json.integer(row, "parse", 0) == 1
                            || Json.integer(row, "jx", 0) == 1;
            String rawJar = Json.str(row, "jar", "");
            if (rawJar.length() > 0) {
                if ((rawJar.startsWith("./") || rawJar.startsWith("../"))
                        && base != null
                        && base.length() > 0) {
                    try {
                        s.jar = new URL(new URL(base), rawJar).toString();
                    } catch (Exception ignored) {
                        s.jar = rawJar;
                    }
                } else {
                    s.jar = rawJar;
                }
            }
            if (base != null && base.length() > 0) {
                if (s.ext instanceof String) {
                    String extStr = (String) s.ext;
                    if (extStr.startsWith("./") || extStr.startsWith("../")) {
                        try {
                            s.ext = new URL(new URL(base), extStr).toString();
                        } catch (Exception ignored) {
                        }
                    }
                } else if (s.ext instanceof JSONObject) {
                    JSONObject extObj = (JSONObject) s.ext;
                    for (String field : new String[] {"json", "url", "rule"}) {
                        String val = Json.str(extObj, field, null);
                        if (val != null && (val.startsWith("./") || val.startsWith("../"))) {
                            try {
                                extObj.put(field, new URL(new URL(base), val).toString());
                            } catch (Exception ignored) {
                            }
                        }
                    }
                }
            }
            if (!s.api.startsWith("csp_")
                    && !s.api.startsWith("js_")
                    && base != null
                    && base.length() > 0) {
                try {
                    s.api = new URL(new URL(base), s.api).toString();
                } catch (Exception ignored) {
                }
            }
            s.originalApi = s.api;
            if (s.type == -1
                    && (s.api.startsWith("http://") || s.api.startsWith("https://"))
                    && (s.jar == null || s.jar.length() == 0)
                    && !isScriptOrJarApi(s.api)) {
                s.type = hasXmlInUrlPath(s.api) ? 0 : 1;
            }
            boolean directPlayUrl =
                    s.playUrl.length() == 0
                            || s.playUrl.startsWith("http://")
                            || s.playUrl.startsWith("https://");
            s.supported = Site.STATUS_OK.equals(s.capabilityStatus()) && directPlayUrl;
            String ua = Json.str(row, "ua", "");
            if (ua.length() > 0 && ua.indexOf('\r') < 0 && ua.indexOf('\n') < 0) {
                s.headers.put("User-Agent", ua);
            }
            putSafeHeaders(s.headers, row.optJSONObject("header"));
            putSafeHeaders(s.headers, row.optJSONObject("headers"));
            JSONObject extObj = row.optJSONObject("ext");
            if (extObj != null) {
                String extUa = Json.str(extObj, "ua", "");
                if (extUa.length() > 0 && extUa.indexOf('\r') < 0 && extUa.indexOf('\n') < 0) {
                    s.headers.put("User-Agent", extUa);
                }
                putSafeHeaders(s.headers, extObj.optJSONObject("header"));
                putSafeHeaders(s.headers, extObj.optJSONObject("headers"));
            }
            sites.add(s);
        }
        return sites;
    }

    public static void applySiteOverride(Site s, JSONObject ov) {
        if (s == null || ov == null) return;
        if (s.originalKey == null || s.originalKey.length() == 0) s.originalKey = s.key;
        if (s.originalApi == null || s.originalApi.length() == 0) s.originalApi = s.api;
        if (ov.has("name")) {
            String n = ov.optString("name", "").trim();
            if (n.length() > 0) s.name = n;
        }
        if (ov.has("group")) {
            String g = ov.optString("group", "").trim();
            s.group = g.length() > 0 ? g : "默认分组";
        }
        if (ov.has("api")) {
            String a = ov.optString("api", "").trim();
            if (a.length() > 0) {
                s.api = a;
                if ((a.startsWith("http://") || a.startsWith("https://"))
                        && !isScriptOrJarApi(a)) {
                    s.jar = "";
                    s.type = hasXmlInUrlPath(a) ? 0 : 1;
                }
            }
        }
        if (ov.has("playUrl")) {
            s.playUrl = ov.optString("playUrl", "").trim();
        }
        if (ov.has("ext")) {
            String e = ov.optString("ext", "").trim();
            if (e.length() == 0) {
                s.ext = null;
                s.extTooLarge = false;
            } else {
                s.ext = e;
                s.extTooLarge = e.length() > Site.MAX_EXT_SIZE;
            }
        }
        if (ov.has("searchable")) {
            s.searchable = ov.optBoolean("searchable", s.searchable);
        }
        boolean directPlayUrl =
                s.playUrl == null
                        || s.playUrl.length() == 0
                        || s.playUrl.startsWith("http://")
                        || s.playUrl.startsWith("https://");
        s.supported = Site.STATUS_OK.equals(s.capabilityStatus()) && directPlayUrl;
    }

    public static List<Site> applySiteEditsToList(List<Site> rawSites, JSONObject saved) {
        if (rawSites == null) return new ArrayList<Site>();
        if (saved == null) return new ArrayList<Site>(rawSites);
        JSONObject overrides = saved.optJSONObject("overrides");
        Set<String> hiddenSet = new HashSet<String>();
        JSONArray hidden = saved.optJSONArray("hidden");
        if (hidden != null) {
            for (int i = 0; i < hidden.length(); i++) {
                String k = hidden.optString(i, "");
                if (k.length() > 0) hiddenSet.add(k);
            }
        }
        Map<String, Site> pending = new LinkedHashMap<String, Site>();
        Map<String, String> keyToId = new LinkedHashMap<String, String>();
        for (int i = 0; i < rawSites.size(); i++) {
            Site site = rawSites.get(i);
            String id = site.siteId();
            if (hiddenSet.contains(id) || hiddenSet.contains(site.key)) continue;
            if (overrides != null) {
                JSONObject ov = overrides.optJSONObject(id);
                if (ov == null) ov = overrides.optJSONObject(site.key);
                if (ov != null) applySiteOverride(site, ov);
            }
            if (site.group == null || site.group.trim().length() == 0) site.group = "默认分组";
            pending.put(id, site);
            if (!keyToId.containsKey(site.key)) keyToId.put(site.key, id);
        }
        List<Site> result = new ArrayList<Site>();
        JSONArray order = saved.optJSONArray("order");
        if (order != null) {
            for (int i = 0; i < order.length(); i++) {
                String tok = order.optString(i);
                Site site = pending.remove(tok);
                if (site == null) {
                    String mappedId = keyToId.get(tok);
                    if (mappedId != null) site = pending.remove(mappedId);
                }
                if (site != null) result.add(site);
            }
        }
        result.addAll(pending.values());
        return result;
    }

    private static void putSafeHeaders(Map<String, String> target, JSONObject hs) {
        if (hs == null) return;
        Iterator<String> keys = hs.keys();
        while (keys.hasNext()) {
            String k = keys.next();
            if (k == null || k.length() == 0 || hs.isNull(k)) continue;
            String v = Json.str(hs, k, "");
            if (k.indexOf('\r') < 0
                    && k.indexOf('\n') < 0
                    && v.indexOf('\r') < 0
                    && v.indexOf('\n') < 0) {
                for (Iterator<String> it = target.keySet().iterator(); it.hasNext(); ) {
                    if (it.next().equalsIgnoreCase(k)) {
                        it.remove();
                    }
                }
                if ("user-agent".equalsIgnoreCase(k)) k = "User-Agent";
                else if ("referer".equalsIgnoreCase(k)) k = "Referer";
                else if ("cookie".equalsIgnoreCase(k)) k = "Cookie";
                else if ("origin".equalsIgnoreCase(k)) k = "Origin";
                else if ("authorization".equalsIgnoreCase(k)) k = "Authorization";
                target.put(k, v);
            }
        }
    }

    public static List<Category> categories(String raw) {
        List<Category> out = new ArrayList<Category>();
        try {
            JSONObject obj = parseCmsResponse(raw);
            JSONArray arr = obj.optJSONArray("class");
            if (arr != null)
                for (int i = 0; i < Math.min(arr.length(), 30); i++) {
                    JSONObject c = arr.optJSONObject(i);
                    if (c == null) continue;
                    String id = c.optString("type_id").trim(),
                            name = c.optString("type_name").trim();
                    if (id.length() > 0 && name.length() > 0) {
                        Category cat = new Category();
                        cat.id = id;
                        cat.name = name;
                        out.add(cat);
                    }
                }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static JSONObject parseCmsResponse(String raw) throws Exception {
        if (raw == null) throw new IOException("空响应");
        String trimmed = raw.trim();
        if (trimmed.startsWith("\ufeff")) trimmed = trimmed.substring(1).trim();
        JSONObject root = trimmed.startsWith("<") ? parseXmlCms(trimmed) : new JSONObject(trimmed);
        if (!root.has("list") && root.has("data") && root.optJSONObject("data") != null) {
            JSONObject data = root.optJSONObject("data");
            if (data.has("list")) {
                root.put("list", data.get("list"));
            }
            if (!root.has("page") && data.has("page")) root.put("page", data.get("page"));
            if (!root.has("pagecount") && data.has("pagecount"))
                root.put("pagecount", data.get("pagecount"));
            if (!root.has("total") && data.has("total")) root.put("total", data.get("total"));
            if (!root.has("limit") && data.has("limit")) root.put("limit", data.get("limit"));
        }
        return root;
    }

    public static JSONObject parseXmlCms(String xml) throws Exception {
        XmlPullParser parser = Xml.newPullParser();
        parser.setInput(new StringReader(xml));
        JSONArray classes = new JSONArray();
        JSONArray list = new JSONArray();
        int page = 1, pagecount = 1;
        JSONObject currentVideo = null;
        List<String> froms = new ArrayList<String>();
        List<String> urls = new ArrayList<String>();
        String currentDdFlag = "";
        int event = parser.getEventType();
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG) {
                String tag = parser.getName();
                if ("list".equalsIgnoreCase(tag)) {
                    try {
                        String pg = parser.getAttributeValue(null, "page");
                        String pc = parser.getAttributeValue(null, "pagecount");
                        if (pg != null) page = Math.max(1, Integer.parseInt(pg.trim()));
                        if (pc != null) pagecount = Math.max(1, Integer.parseInt(pc.trim()));
                    } catch (Exception ignored) {
                    }
                } else if ("ty".equalsIgnoreCase(tag)) {
                    String id = parser.getAttributeValue(null, "id");
                    String name = safeNextText(parser).trim();
                    if (id != null && id.trim().length() > 0 && name.length() > 0) {
                        classes.put(
                                new JSONObject().put("type_id", id.trim()).put("type_name", name));
                    }
                } else if ("video".equalsIgnoreCase(tag)) {
                    currentVideo = new JSONObject();
                    froms.clear();
                    urls.clear();
                } else if (currentVideo != null) {
                    if ("id".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_id", safeNextText(parser).trim());
                    } else if ("name".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_name", safeNextText(parser).trim());
                    } else if ("pic".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_pic", safeNextText(parser).trim());
                    } else if ("type".equalsIgnoreCase(tag)) {
                        currentVideo.put("type_name", safeNextText(parser).trim());
                    } else if ("year".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_year", safeNextText(parser).trim());
                    } else if ("area".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_area", safeNextText(parser).trim());
                    } else if ("note".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_remarks", safeNextText(parser).trim());
                    } else if ("actor".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_actor", safeNextText(parser).trim());
                    } else if ("director".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_director", safeNextText(parser).trim());
                    } else if ("des".equalsIgnoreCase(tag)) {
                        currentVideo.put("vod_content", safeNextText(parser).trim());
                    } else if ("dd".equalsIgnoreCase(tag)) {
                        String flag = parser.getAttributeValue(null, "flag");
                        currentDdFlag =
                                flag != null && flag.trim().length() > 0
                                        ? flag.trim()
                                        : ("线路" + (froms.size() + 1));
                        String playData = safeNextText(parser).trim();
                        if (playData.length() > 0) {
                            froms.add(currentDdFlag);
                            urls.add(playData);
                        }
                    }
                }
            } else if (event == XmlPullParser.END_TAG) {
                String tag = parser.getName();
                if ("video".equalsIgnoreCase(tag) && currentVideo != null) {
                    if (currentVideo.optString("vod_id").length() > 0
                            && currentVideo.optString("vod_name").length() > 0) {
                        if (!froms.isEmpty()) {
                            currentVideo.put("vod_play_from", join(froms, "$$$"));
                            currentVideo.put("vod_play_url", join(urls, "$$$"));
                        }
                        list.put(currentVideo);
                    }
                    currentVideo = null;
                }
            }
            event = parser.next();
        }
        return new JSONObject()
                .put("page", page)
                .put("pagecount", pagecount)
                .put("class", classes)
                .put("list", list);
    }

    private static String safeNextText(XmlPullParser parser) {
        try {
            String t = parser.nextText();
            return t == null ? "" : t;
        } catch (Exception e) {
            return "";
        }
    }

    private static String join(List<String> items, String sep) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(sep);
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    public static String query(String api, String... pairs) throws Exception {
        StringBuilder b = new StringBuilder(api);
        for (int i = 0; i < pairs.length; i += 2)
            b.append(b.indexOf("?") < 0 ? '?' : '&')
                    .append(URLEncoder.encode(pairs[i], "UTF-8"))
                    .append('=')
                    .append(URLEncoder.encode(pairs[i + 1], "UTF-8"));
        return b.toString();
    }

    public static JSONArray list(String raw) throws Exception {
        JSONArray a = parseCmsResponse(raw).optJSONArray("list");
        if (a == null) throw new IOException("返回内容不是 CMS 列表");
        return a;
    }

    public static List<LiveSource> parseLives(String rawConfig, String base) {
        List<LiveSource> out = new ArrayList<LiveSource>();
        if (rawConfig == null || rawConfig.trim().length() == 0) return out;
        try {
            JSONObject doc = decodeConfig(rawConfig);
            base = Json.str(doc, com.pilipala.source.Warehouse.ORIGIN, base);
            JSONArray lives = doc.optJSONArray("lives");
            if (lives == null) return out;
            for (int i = 0; i < lives.length() && out.size() < 32; i++) {
                JSONObject item = lives.optJSONObject(i);
                if (item == null) continue;
                JSONArray channels = item.optJSONArray("channels");
                if (channels != null && channels.length() > 0) {
                    for (int j = 0; j < channels.length() && out.size() < 32; j++) {
                        JSONObject ch = channels.optJSONObject(j);
                        if (ch == null) continue;
                        JSONArray urls = ch.optJSONArray("urls");
                        String rawUrl =
                                urls != null && urls.length() > 0
                                        ? urls.optString(0, "")
                                        : ch.optString("url", "");
                        addLiveSourceItem(
                                out,
                                ch.optString("name", item.optString("group", "直播源")),
                                rawUrl,
                                item,
                                base);
                    }
                } else {
                    addLiveSourceItem(
                            out,
                            item.optString("name", "直播源 " + (out.size() + 1)),
                            item.optString("url", ""),
                            item,
                            base);
                }
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    private static void addLiveSourceItem(
            List<LiveSource> out, String name, String rawUrl, JSONObject meta, String base) {
        if (rawUrl == null) return;
        String u = rawUrl.trim();
        if (u.length() == 0) return;
        if (u.startsWith("proxy://")) {
            int extIdx = u.indexOf("ext=");
            if (extIdx > 0) {
                String ext = u.substring(extIdx + 4);
                int amp = ext.indexOf('&');
                if (amp > 0) ext = ext.substring(0, amp);
                try {
                    String decoded =
                            new String(
                                    Base64.decode(
                                            URLDecoder.decode(ext, "UTF-8"),
                                            Base64.DEFAULT | Base64.URL_SAFE),
                                    "UTF-8")
                                    .trim();
                    if (decoded.startsWith("http://") || decoded.startsWith("https://")) {
                        u = decoded;
                    }
                } catch (Exception ignored) {
                }
            }
        } else if (!u.startsWith("http://")
                && !u.startsWith("https://")
                && base != null
                && base.length() > 0) {
            try {
                u = new URL(new URL(base), u).toString();
            } catch (Exception ignored) {
            }
        }
        if (!(u.startsWith("http://") || u.startsWith("https://") || u.startsWith("proxy://"))) {
            return;
        }
        LiveSource src = new LiveSource();
        src.name = name == null || name.trim().length() == 0 ? "直播源" : name.trim();
        src.url = u;
        String ua = Json.str(meta, "ua", "");
        if (ua.length() > 0 && ua.indexOf('\r') < 0 && ua.indexOf('\n') < 0) {
            src.headers.put("User-Agent", ua);
        }
        putSafeHeaders(src.headers, meta.optJSONObject("header"));
        putSafeHeaders(src.headers, meta.optJSONObject("headers"));
        out.add(src);
    }

    public static List<LiveGroup> fetchLiveGroups(LiveSource src) throws Exception {
        if (src == null || src.url == null) return Collections.emptyList();
        String u = src.url.trim();
        String content;
        if (u.startsWith("proxy://")) {
            int extIdx = u.indexOf("ext=");
            if (extIdx < 0) throw new IOException("不支持的代理直播地址");
            String ext = u.substring(extIdx + 4);
            int amp = ext.indexOf('&');
            if (amp > 0) ext = ext.substring(0, amp);
            String decoded =
                    new String(
                                    Base64.decode(
                                            URLDecoder.decode(ext, "UTF-8"),
                                            Base64.DEFAULT | Base64.URL_SAFE),
                                    "UTF-8")
                            .trim();
            if (decoded.startsWith("http://") || decoded.startsWith("https://")) {
                content = fetch(decoded, src.headers);
            } else {
                content = decoded;
            }
        } else {
            content = fetch(u, src.headers);
        }
        return parseLiveContent(content);
    }

    public static List<LiveGroup> parseLiveContent(String raw) {
        if (raw == null) return Collections.emptyList();
        String text = raw.trim();
        if (text.startsWith("\ufeff")) text = text.substring(1).trim();
        int star = text.indexOf("**");
        if (star >= 0 && !text.startsWith("#EXTM3U") && !text.contains(",#genre#")) {
            try {
                text =
                        new String(
                                        Base64.decode(
                                                text.substring(star + 2).replaceAll("\\s+", ""),
                                                Base64.DEFAULT),
                                        "UTF-8")
                                .trim();
            } catch (Exception ignored) {
            }
        } else if (!text.startsWith("#EXTM3U")
                && !text.contains(",#genre#")
                && !text.contains("http://")
                && !text.contains("https://")) {
            try {
                String decoded =
                        new String(Base64.decode(text.replaceAll("\\s+", ""), Base64.DEFAULT), "UTF-8")
                                .trim();
                if (decoded.contains("http://") || decoded.contains("https://")) text = decoded;
            } catch (Exception ignored) {
            }
        }
        Map<String, LiveGroup> groups = new LinkedHashMap<String, LiveGroup>();
        Map<String, LiveChannel> channelMap = new LinkedHashMap<String, LiveChannel>();
        String[] lines = text.split("\r?\n");
        boolean isM3u = text.startsWith("#EXTM3U") || text.contains("#EXTINF:");
        if (isM3u) {
            String currentGroup = "直播频道";
            String currentName = "";
            Map<String, String> pendingHeaders = new LinkedHashMap<String, String>();
            for (int i = 0; i < lines.length && channelMap.size() < 800; i++) {
                String line = lines[i].trim();
                if (line.length() == 0) continue;
                if (line.startsWith("#EXTINF:")) {
                    currentGroup = extractAttr(line, "group-title", "直播频道");
                    int comma = line.lastIndexOf(',');
                    currentName =
                            comma >= 0 && comma + 1 < line.length()
                                    ? line.substring(comma + 1).trim()
                                    : extractAttr(line, "tvg-name", "频道");
                } else if (line.startsWith("#EXTGRP:")) {
                    String g = line.substring(8).trim();
                    if (g.length() > 0) currentGroup = g;
                } else if (line.startsWith("#EXTVLCOPT:http-user-agent=")) {
                    pendingHeaders.put("User-Agent", line.substring(27).trim());
                } else if (line.startsWith("#EXTVLCOPT:http-referrer=")) {
                    pendingHeaders.put("Referer", line.substring(25).trim());
                } else if (!line.startsWith("#")) {
                    addChannelUrl(
                            groups,
                            channelMap,
                            currentGroup,
                            currentName.length() > 0 ? currentName : "频道 " + (channelMap.size() + 1),
                            line,
                            pendingHeaders);
                    currentName = "";
                    pendingHeaders = new LinkedHashMap<String, String>();
                }
            }
        } else {
            String currentGroup = "默认分组";
            for (int i = 0; i < lines.length && channelMap.size() < 800; i++) {
                String line = lines[i].trim();
                if (line.length() == 0 || line.startsWith("#") || line.startsWith("//")) continue;
                int comma = line.indexOf(',');
                if (comma <= 0) continue;
                String left = line.substring(0, comma).trim();
                String right = line.substring(comma + 1).trim();
                if (right.startsWith("#genre#")) {
                    if (left.length() > 0) currentGroup = left;
                    continue;
                }
                for (String u : right.split("#")) {
                    addChannelUrl(
                            groups,
                            channelMap,
                            currentGroup,
                            left,
                            u.trim(),
                            Collections.<String, String>emptyMap());
                }
            }
        }
        return new ArrayList<LiveGroup>(groups.values());
    }

    private static void addChannelUrl(
            Map<String, LiveGroup> groups,
            Map<String, LiveChannel> channelMap,
            String groupName,
            String chName,
            String rawUrl,
            Map<String, String> extraHeaders) {
        if (rawUrl == null || rawUrl.length() == 0) return;
        String urlPart = rawUrl;
        Map<String, String> inlineHeaders = new LinkedHashMap<String, String>(extraHeaders);
        int pipe = rawUrl.indexOf('|');
        if (pipe > 0) {
            urlPart = rawUrl.substring(0, pipe).trim();
            String tail = rawUrl.substring(pipe + 1);
            for (String kv : tail.split("&|\\|")) {
                int eq = kv.indexOf('=');
                if (eq > 0) {
                    String k = kv.substring(0, eq).trim();
                    String v = kv.substring(eq + 1).trim();
                    if ("referer".equalsIgnoreCase(k)) inlineHeaders.put("Referer", v);
                    else if ("user-agent".equalsIgnoreCase(k) || "ua".equalsIgnoreCase(k))
                        inlineHeaders.put("User-Agent", v);
                }
            }
        }
        int dollar = urlPart.indexOf('$');
        if (dollar > 0) urlPart = urlPart.substring(0, dollar).trim();
        try {
            urlPart = http(urlPart);
        } catch (Exception invalid) {
            return;
        }
        String gKey = groupName == null || groupName.length() == 0 ? "直播频道" : groupName;
        LiveGroup grp = groups.get(gKey);
        if (grp == null) {
            grp = new LiveGroup();
            grp.name = gKey;
            groups.put(gKey, grp);
        }
        String chKey = gKey + "\n" + chName;
        LiveChannel ch = channelMap.get(chKey);
        if (ch == null) {
            ch = new LiveChannel();
            ch.name = chName;
            ch.group = gKey;
            ch.headers.putAll(inlineHeaders);
            channelMap.put(chKey, ch);
            grp.channels.add(ch);
        }
        if (!ch.urls.contains(urlPart)) {
            ch.urls.add(urlPart);
        }
    }

    private static String extractAttr(String line, String attr, String fallback) {
        int idx = line.indexOf(attr + "=\"");
        if (idx >= 0) {
            int start = idx + attr.length() + 2;
            int end = line.indexOf('"', start);
            if (end > start) {
                String v = line.substring(start, end).trim();
                if (v.length() > 0) return v;
            }
        }
        return fallback;
    }
}

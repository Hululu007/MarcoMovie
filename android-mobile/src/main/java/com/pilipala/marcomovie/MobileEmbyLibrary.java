package com.pilipala.marcomovie;

import java.io.*;
import java.net.*;
import java.util.*;
import javax.net.ssl.SSLException;
import org.json.*;

/** Android Mobile / Tablet Emby REST client (isolated from shared/java/ per P1-10). */
public final class MobileEmbyLibrary {
    public static final String PREFIX = "emby://account/";
    public static final String LIVE_CATALOG_PREFIX = "mmemby://live-catalog?account=";
    public static final String LIVE_PLAY_PREFIX = "mmemby://live?";
    private static final int PAGE_SIZE = 40;
    private final String base, user, token, device, account;

    public String accountId() {
        return account;
    }

    public static String parseLiveAccount(String url) {
        if (url == null) return "";
        try {
            URI u = new URI(url.trim());
            if (!"mmemby".equalsIgnoreCase(u.getScheme())) return "";
            String host = u.getHost();
            if (!"live".equalsIgnoreCase(host) && !"live-catalog".equalsIgnoreCase(host)) {
                return "";
            }
            Map<String, String> q = query(u.getRawQuery());
            return q.containsKey("account") ? q.get("account").trim() : "";
        } catch (Exception ignored) {
            return "";
        }
    }

    public static String parseLiveChannelId(String url) {
        if (url == null) return "";
        try {
            URI u = new URI(url.trim());
            if (!"mmemby".equalsIgnoreCase(u.getScheme())
                    || !"live".equalsIgnoreCase(u.getHost())) {
                return "";
            }
            Map<String, String> q = query(u.getRawQuery());
            return q.containsKey("id") ? q.get("id").trim() : "";
        } catch (Exception ignored) {
            return "";
        }
    }

    public static String accountKey(JSONObject session) throws Exception {
        String rawBase = session.getString("base");
        String normBase =
                rawBase.toLowerCase(Locale.US).endsWith("/emby")
                        ? normalize(rawBase)
                        : normalizeRoot(rawBase);
        String identity = normBase + "\n" + session.getString("user");
        byte[] digest =
                java.security.MessageDigest.getInstance("SHA-256")
                        .digest(identity.getBytes("UTF-8"));
        StringBuilder key = new StringBuilder();
        for (byte value : digest) key.append(String.format(Locale.US, "%02x", value & 255));
        return key.toString();
    }

    public Map<String, String> imageHeaders(String address) throws Exception {
        URL url = new URL(address);
        String bare =
                address.substring(
                        0, address.indexOf('#') < 0 ? address.length() : address.indexOf('#'));
        if (!sameOrigin(new URI(base), new URI(bare))
                || !bare.startsWith(base + "/Items/")
                || !url.getPath().matches(".*/Items/[a-zA-Z0-9_-]+/Images/Primary"))
            throw new IOException("Emby 海报地址与账户不匹配");
        Map<String, String> h = new HashMap<String, String>();
        h.put("X-Emby-Token", token);
        return h;
    }

    public MobileEmbyLibrary(JSONObject session) throws Exception {
        account = accountKey(session);
        String rawBase = session.getString("base");
        // Respect bare-root servers saved during login fallback while normalizing legacy entries.
        base =
                rawBase.toLowerCase(Locale.US).endsWith("/emby")
                        ? normalize(rawBase)
                        : normalizeRoot(rawBase);
        user = segment(session.getString("user"));
        token = session.getString("token");
        device = session.getString("device");
    }

    static String normalize(String raw) throws Exception {
        String root = normalizeRoot(raw);
        return root.toLowerCase(Locale.US).endsWith("/emby") ? root : root + "/emby";
    }

    static String normalizeRoot(String raw) throws Exception {
        if (raw == null || raw.trim().length() == 0) throw new IOException("请输入 Emby 服务器根地址");
        String cleaned = raw.trim();
        int hash = cleaned.indexOf('#');
        if (hash >= 0 && cleaned.toLowerCase(Locale.US).contains("/web/")) {
            cleaned = cleaned.substring(0, hash);
        }
        URL url = new URL(cleaned);
        if (!(url.getProtocol().equals("http") || url.getProtocol().equals("https"))
                || url.getHost().length() == 0
                || url.getUserInfo() != null
                || url.getQuery() != null
                || url.getRef() != null) throw new IOException("请输入 Emby 服务器根地址");
        String root = url.toExternalForm().replaceAll("/+$", "");
        String lower = root.toLowerCase(Locale.US);
        int webIdx = lower.indexOf("/web/");
        if (webIdx > 0) {
            root = root.substring(0, webIdx).replaceAll("/+$", "");
        } else if (lower.endsWith("/web")) {
            root = root.substring(0, root.length() - 4).replaceAll("/+$", "");
        }
        return root;
    }

    private static int effectivePort(URI uri) {
        int port = uri.getPort();
        if (port > 0) return port;
        return "https".equalsIgnoreCase(uri.getScheme()) ? 443 : 80;
    }

    public static boolean isSameOrigin(String a, String b) {
        if (a == null || b == null) return false;
        try {
            return sameOrigin(new URI(a), new URI(b));
        } catch (Exception ignored) {
            return false;
        }
    }

    private static boolean sameOrigin(URI a, URI b) {
        if (a == null || b == null) return false;
        if (a.getScheme() == null || b.getScheme() == null) return false;
        if (a.getHost() == null || b.getHost() == null) return false;
        return a.getScheme().equalsIgnoreCase(b.getScheme())
                && a.getHost().equalsIgnoreCase(b.getHost())
                && effectivePort(a) == effectivePort(b);
    }

    private static String segment(String value) throws IOException {
        if (!value.matches("[a-zA-Z0-9_-]+")) throw new IOException("Emby 媒体或账户编号无效");
        return value;
    }

    private static String encode(String value) throws Exception {
        return URLEncoder.encode(value, "UTF-8");
    }

    public static JSONObject splitServerUrl(String rawUrl) {
        JSONObject out = new JSONObject();
        try {
            String trimmed = rawUrl == null ? "" : rawUrl.trim();
            if (trimmed.isEmpty()) {
                return out.put("useHttps", false)
                        .put("host", "")
                        .put("port", "8096")
                        .put("subpath", "");
            }
            boolean hasScheme = trimmed.contains("://");
            URI uri = new URI(hasScheme ? trimmed : ("http://" + trimmed));
            String scheme =
                    uri.getScheme() == null ? "http" : uri.getScheme().toLowerCase(Locale.US);
            int port = uri.getPort();
            boolean useHttps = "https".equals(scheme) || port == 443 || port == 8920;
            String host = uri.getHost() == null ? "" : uri.getHost();
            if (host.indexOf(':') >= 0 && !host.startsWith("[")) {
                host = "[" + host + "]";
            }
            String path = uri.getPath() == null ? "" : uri.getPath().replaceAll("/+$", "");
            int webIdx = path.toLowerCase(Locale.US).indexOf("/web/");
            if (webIdx >= 0) {
                path = path.substring(0, webIdx).replaceAll("/+$", "");
            } else if (path.toLowerCase(Locale.US).endsWith("/web")) {
                path = path.substring(0, path.length() - 4).replaceAll("/+$", "");
            }
            String portStr = port > 0 ? String.valueOf(port) : (useHttps ? "443" : "8096");
            out.put("useHttps", useHttps);
            out.put("host", host);
            out.put("port", portStr);
            out.put("subpath", path);
        } catch (Exception ignored) {
            try {
                out.put("useHttps", false)
                        .put("host", rawUrl == null ? "" : rawUrl.trim())
                        .put("port", "8096")
                        .put("subpath", "");
            } catch (Exception ignored2) {
            }
        }
        return out;
    }

    public static String assembleServerUrl(
            boolean useHttps, String hostOrUrl, String subpath, String port) throws IOException {
        String rawHost = hostOrUrl == null ? "" : hostOrUrl.trim();
        if (rawHost.isEmpty()) throw new IOException("请填写服务器地址");
        String rawSub = subpath == null ? "" : subpath.trim();
        String rawPort = port == null ? "" : port.trim();
        if (rawHost.regionMatches(true, 0, "http://", 0, 7)
                || rawHost.regionMatches(true, 0, "https://", 0, 8)) {
            JSONObject parsed = splitServerUrl(rawHost);
            useHttps = rawHost.regionMatches(true, 0, "https://", 0, 8);
            rawHost = parsed.optString("host", "");
            if (rawSub.isEmpty()) rawSub = parsed.optString("subpath", "");
            if (rawPort.isEmpty()) rawPort = parsed.optString("port", "");
        } else {
            int slash = rawHost.indexOf('/');
            if (slash >= 0) {
                if (rawSub.isEmpty()) rawSub = rawHost.substring(slash);
                rawHost = rawHost.substring(0, slash).trim();
            }
            if (!rawHost.startsWith("[")) {
                int colon = rawHost.lastIndexOf(':');
                if (colon > 0 && colon == rawHost.indexOf(':')) {
                    String inlinePort = rawHost.substring(colon + 1).trim();
                    if (rawPort.isEmpty() && inlinePort.matches("\\d+")) {
                        rawPort = inlinePort;
                    }
                    rawHost = rawHost.substring(0, colon).trim();
                }
            }
        }
        if (rawHost.isEmpty()) throw new IOException("请输入有效的服务器地址");
        if (rawHost.indexOf(':') >= 0 && !rawHost.startsWith("[")) {
            rawHost = "[" + rawHost + "]";
        }
        String portSuffix = "";
        if (!rawPort.isEmpty()) {
            int p;
            try {
                p = Integer.parseInt(rawPort);
            } catch (NumberFormatException nfe) {
                throw new IOException("端口号无效：" + rawPort);
            }
            if (p <= 0 || p > 65535) throw new IOException("端口号超出范围：" + rawPort);
            if (!(useHttps && p == 443) && !(!useHttps && p == 80)) {
                portSuffix = ":" + p;
            }
        }
        String normSub = rawSub.replaceAll("/+$", "");
        if (!normSub.isEmpty() && !normSub.startsWith("/")) {
            normSub = "/" + normSub;
        }
        return (useHttps ? "https://" : "http://") + rawHost + portSuffix + normSub;
    }

    private static JSONObject request(String url, String device, String token, JSONObject body)
            throws Exception {
        String currentUrl = url;
        URI originUri = new URI(url);
        for (int hop = 0; hop < 6; hop++) {
            URI currentUri = new URI(currentUrl);
            if (!("http".equalsIgnoreCase(currentUri.getScheme())
                    || "https".equalsIgnoreCase(currentUri.getScheme()))) {
                throw new IOException("Emby 请求协议无效");
            }
            if (!sameOrigin(originUri, currentUri)) {
                throw new IOException("Emby 拒绝跨源重定向以保护账号凭据");
            }
            HttpURLConnection c = (HttpURLConnection) new URL(currentUrl).openConnection();
            try {
                c.setInstanceFollowRedirects(false);
                c.setConnectTimeout(10000);
                c.setReadTimeout(15000);
                String authHeader =
                        "Emby Client=\"Marco Movie\", Device=\"Android\", DeviceId=\""
                                + device
                                + "\", Version=\"1\""
                                + (token.length() > 0 ? ", Token=\"" + token + "\"" : "");
                c.setRequestProperty("Authorization", authHeader);
                c.setRequestProperty("X-Emby-Authorization", authHeader);
                c.setRequestProperty("User-Agent", "MarcoMovie/1.0");
                if (token.length() > 0) c.setRequestProperty("X-Emby-Token", token);
                c.setRequestProperty("Accept", "application/json");
                if (body != null) {
                    c.setRequestMethod("POST");
                    c.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                    c.setDoOutput(true);
                    OutputStream stream = c.getOutputStream();
                    try {
                        stream.write(body.toString().getBytes("UTF-8"));
                    } finally {
                        stream.close();
                    }
                }
                int status = c.getResponseCode();
                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null || loc.trim().length() == 0) {
                        throw new IOException("Emby 重定向地址缺失（HTTP " + status + "）");
                    }
                    URL nextUrl = new URL(new URL(currentUrl), loc.trim());
                    String proto = nextUrl.getProtocol();
                    if (!("http".equalsIgnoreCase(proto) || "https".equalsIgnoreCase(proto))) {
                        throw new IOException("Emby 重定向协议无效");
                    }
                    URI nextUri = nextUrl.toURI();
                    if (!sameOrigin(originUri, nextUri)) {
                        throw new IOException("Emby 拒绝跨源重定向以保护账号凭据");
                    }
                    currentUrl = nextUrl.toExternalForm();
                    continue;
                }
                if (status == 401 || status == 403) throw new IOException("Emby 拒绝访问，请检查账号或重新登录");
                if (status < 200 || status >= 300)
                    throw new IOException("Emby 请求失败（HTTP " + status + "）");
                InputStream in = c.getInputStream();
                try {
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        if (out.size() + n > 4 * 1024 * 1024) throw new IOException("Emby 响应过大");
                        out.write(buf, 0, n);
                    }
                    if (out.size() == 0) return new JSONObject();
                    try {
                        return new JSONObject(out.toString("UTF-8"));
                    } catch (JSONException jsonErr) {
                        throw new IOException("Emby 响应非有效 JSON 数据", jsonErr);
                    }
                } finally {
                    in.close();
                }
            } catch (SSLException sslErr) {
                throw new IOException(
                        "SSL/HTTPS 握手失败（若服务器使用 8096 等 HTTP 端口，请关闭 HTTPS 开关或改用 http:// 地址）："
                                + sslErr.getMessage(),
                        sslErr);
            } finally {
                c.disconnect();
            }
        }
        throw new IOException("Emby 重定向次数过多");
    }

    public static JSONObject login(String address, String name, String password, String device)
            throws Exception {
        return login(address, name, password, device, "");
    }

    public static JSONObject login(
            String address, String name, String password, String device, String customDisplayName)
            throws Exception {
        String bareRoot = normalizeRoot(address);
        boolean userSpecifiedEmby = bareRoot.toLowerCase(Locale.US).endsWith("/emby");
        String base = userSpecifiedEmby ? bareRoot : bareRoot + "/emby";
        String cleanUser = name == null ? "" : name.trim();
        JSONObject authBody = new JSONObject().put("Username", cleanUser).put("Pw", password);
        JSONObject response;
        try {
            response = request(base + "/Users/AuthenticateByName", device, "", authBody);
        } catch (IOException firstErr) {
            // Retry bare root when /emby subpath returns 404/405 or HTML proxy page.
            String msg = firstErr.getMessage();
            if (!userSpecifiedEmby
                    && msg != null
                    && (msg.contains("HTTP 404")
                            || msg.contains("HTTP 405")
                            || msg.contains("非有效 JSON"))) {
                base = bareRoot;
                response = request(base + "/Users/AuthenticateByName", device, "", authBody);
            } else {
                throw firstErr;
            }
        }
        String token = response.getString("AccessToken");
        if (token.length() == 0) throw new IOException("Emby 未返回登录凭据");
        String userId = segment(response.getJSONObject("User").getString("Id"));
        // Verify library read permissions via /Users/{user}/Views BEFORE persisting the account!
        JSONObject views = request(base + "/Users/" + userId + "/Views", device, token, null);
        if (views.optJSONArray("Items") == null) {
            throw new IOException("Emby 账号无权读取媒体库视图（Views 响应缺少 Items）");
        }
        String cleanLabel = customDisplayName == null ? "" : customDisplayName.trim();
        return new JSONObject()
                .put("base", base)
                .put("token", token)
                .put("device", device)
                .put("user", userId)
                .put("username", cleanUser)
                .put("label", cleanLabel)
                .put("name", cleanLabel.length() > 0 ? cleanLabel : cleanUser);
    }

    public Map<String, String> headersFor(String address) throws Exception {
        Map<String, String> h = new HashMap<String, String>();
        if (address == null || address.length() == 0) return h;
        try {
            URI server = new URI(base);
            URI target = new URI(address);
            String basePath = server.getPath() == null ? "" : server.getPath();
            String expectedPrefix = (basePath + "/videos/").toLowerCase(Locale.US);
            String targetPath =
                    target.getPath() == null ? "" : target.getPath().toLowerCase(Locale.US);
            if (sameOrigin(server, target) && targetPath.startsWith(expectedPrefix)) {
                h.put("X-Emby-Token", token);
            }
        } catch (Exception ignored) {
        }
        return h;
    }

    private static Map<String, String> query(String raw) throws Exception {
        Map<String, String> values = new LinkedHashMap<String, String>();
        if (raw == null) return values;
        for (String entry : raw.split("&")) {
            String[] pair = entry.split("=", 2);
            values.put(
                    URLDecoder.decode(pair[0], "UTF-8"),
                    pair.length == 2 ? URLDecoder.decode(pair[1], "UTF-8") : "");
        }
        return values;
    }

    private static String queryString(Map<String, String> values) throws Exception {
        StringBuilder out = new StringBuilder();
        for (Map.Entry<String, String> entry : values.entrySet()) {
            if (out.length() > 0) out.append('&');
            out.append(encode(entry.getKey())).append('=').append(encode(entry.getValue()));
        }
        return out.toString();
    }

    public JSONObject resolve(String address, boolean legacyPlayer) throws Exception {
        URI original = new URI(address);
        String basePath = new URI(base).getPath();
        if (basePath == null) basePath = "";
        String prefix = basePath + "/Videos/";
        String prefixLower = prefix.toLowerCase(Locale.US);
        String origPath = original.getPath() == null ? "" : original.getPath();
        if (headersFor(address).isEmpty()
                || !origPath.toLowerCase(Locale.US).startsWith(prefixLower))
            throw new IOException("Emby 播放地址与账户不匹配");
        String rest = origPath.substring(prefix.length());
        int end = rest.indexOf('/');
        if (end < 1) throw new IOException("Emby 剧集编号无效");
        String id = segment(rest.substring(0, end));
        Map<String, String> q = query(original.getRawQuery());
        String wanted = q.containsKey("MediaSourceId") ? q.get("MediaSourceId") : id;
        JSONObject profile =
                new JSONObject()
                        .put("Name", "Marco Movie")
                        .put("MaxStreamingBitrate", 80000000)
                        .put(
                                "DirectPlayProfiles",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("Type", "Video")
                                                        .put(
                                                                "Container",
                                                                legacyPlayer
                                                                        ? "mp4,m4v"
                                                                        : "mp4,m4v,mkv,mov,ts,webm")
                                                        .put(
                                                                "VideoCodec",
                                                                legacyPlayer
                                                                        ? "h264"
                                                                        : "h264,hevc,h265,vp9,av1")
                                                        .put(
                                                                "AudioCodec",
                                                                legacyPlayer
                                                                        ? "aac,mp3"
                                                                        : "aac,mp3,ac3,eac3,dts,truehd,flac,opus")))
                        .put(
                                "TranscodingProfiles",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("Type", "Video")
                                                        .put("Container", "ts")
                                                        .put("Protocol", "hls")
                                                        .put("VideoCodec", "h264")
                                                        .put("AudioCodec", "aac")
                                                        .put("Context", "Streaming")
                                                        .put("MaxAudioChannels", "2")
                                                        .put("MinSegments", 1)));
        JSONObject body =
                new JSONObject()
                        .put("UserId", user)
                        .put("IsPlayback", true)
                        .put("AutoOpenLiveStream", false)
                        .put("EnableDirectPlay", true)
                        .put("EnableDirectStream", true)
                        .put("EnableTranscoding", true)
                        .put("MaxStreamingBitrate", 80000000)
                        .put("DeviceProfile", profile);
        if (!wanted.equals(id)) body.put("MediaSourceId", wanted);
        JSONObject info = request(base + "/Items/" + id + "/PlaybackInfo", device, token, body);
        if (!info.optString("ErrorCode").isEmpty()) throw new IOException("Emby 无法为当前账号或设备提供播放方案");
        JSONArray sources = info.optJSONArray("MediaSources");
        JSONObject source = null;
        if (sources != null)
            for (int i = 0; i < sources.length(); i++) {
                JSONObject candidate = sources.optJSONObject(i);
                if (candidate != null && wanted.equals(candidate.optString("Id")))
                    source = candidate;
            }
        if (source == null && wanted.equals(id) && sources != null && sources.length() > 0)
            source = sources.optJSONObject(0);
        if (source == null || source.optString("Id").isEmpty())
            throw new IOException("Emby 未返回所选媒体版本");
        if (source.optBoolean("RequiresOpening")) throw new IOException("当前 Emby 资源需要实时流打开协议");
        String session = info.optString("PlaySessionId"), sourceId = source.getString("Id");
        if (session.isEmpty()) throw new IOException("Emby 播放会话缺失");
        boolean direct =
                source.optBoolean("SupportsDirectStream")
                        || source.optBoolean("SupportsDirectPlay");
        String rawPath = source.optString("Path", "").trim();
        if (source.optBoolean("SupportsDirectPlay")
                && (rawPath.regionMatches(true, 0, "http://", 0, 7)
                        || rawPath.regionMatches(true, 0, "https://", 0, 8))) {
            Map<String, String> outHeaders = new LinkedHashMap<String, String>();
            JSONObject reqHeaders = source.optJSONObject("RequiredHttpHeaders");
            if (reqHeaders != null) {
                Iterator<String> keys = reqHeaders.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    String val = reqHeaders.optString(k, "");
                    if (val.length() > 0) outHeaders.put(k, val);
                }
            }
            if (isSameOriginUrl(rawPath)) {
                outHeaders.put("X-Emby-Token", token);
            }
            JSONObject metadata =
                    new JSONObject()
                            .put("ItemId", id)
                            .put("MediaSourceId", sourceId)
                            .put("PlaySessionId", session)
                            .put("PlayMethod", "DirectPlay")
                            .put("CanSeek", true);
            return new JSONObject()
                    .put("parse", 0)
                    .put("url", rawPath)
                    .put("header", new JSONObject(outHeaders))
                    .put("embySession", metadata);
        }
        Map<String, String> params = new LinkedHashMap<String, String>();
        String stream;
        if (direct) {
            stream = base + "/Videos/" + id + "/stream";
            params.put("Static", "true");
        } else {
            if (!source.optBoolean("SupportsTranscoding")
                    || source.optString("TranscodingUrl").isEmpty())
                throw new IOException("Emby 没有可用的直连或转码方案");
            URI server = new URI(base);
            URI target =
                    resolveServerMediaUri(server, basePath, source.getString("TranscodingUrl"));
            String targetPath = target.getPath() == null ? "" : target.getPath();
            if (!sameOrigin(server, target)
                    || target.getUserInfo() != null
                    || !targetPath.toLowerCase(Locale.US).startsWith(prefixLower))
                throw new IOException("Emby 转码地址与服务器不匹配");
            params.putAll(query(target.getRawQuery()));
            for (String key : new ArrayList<String>(params.keySet()))
                if (key.equalsIgnoreCase("api_key") || key.equalsIgnoreCase("x-emby-token"))
                    params.remove(key);
            stream =
                    new URI(target.getScheme(), target.getAuthority(), targetPath, null, null)
                            .toString();
        }
        params.put("MediaSourceId", sourceId);
        params.put("PlaySessionId", session);
        params.put("DeviceId", device);
        JSONObject metadata =
                new JSONObject()
                        .put("ItemId", id)
                        .put("MediaSourceId", sourceId)
                        .put("PlaySessionId", session)
                        .put("PlayMethod", direct ? "DirectStream" : "Transcode")
                        .put("CanSeek", true);
        return new JSONObject()
                .put("parse", 0)
                .put("url", stream + "?" + queryString(params))
                .put("header", new JSONObject(headersFor(stream)))
                .put("embySession", metadata);
    }

    public void report(
            JSONObject metadata, String event, long positionMs, boolean paused, boolean stopped)
            throws Exception {
        JSONObject body =
                new JSONObject(metadata.toString())
                        .put("PositionTicks", Math.max(0, positionMs) * 10000L)
                        .put("IsPaused", paused)
                        .put("EventName", event);
        String suffix = stopped ? "/Stopped" : event.equals("Start") ? "" : "/Progress";
        try {
            request(base + "/Sessions/Playing" + suffix, device, token, body);
        } finally {
            if (stopped) {
                String liveStreamId = metadata.optString("LiveStreamId", "").trim();
                if (liveStreamId.length() > 0) {
                    try {
                        request(
                                base + "/LiveTv/LiveStreams/Close",
                                device,
                                token,
                                new JSONObject().put("LiveStreamId", liveStreamId));
                    } catch (Exception ignored) {
                    }
                }
            }
        }
    }

    /** Fetches Live TV channels (with CurrentProgram EPG) from Emby or Jellyfin. */
    public JSONArray liveChannels() throws Exception {
        JSONArray out = new JSONArray();
        int start = 0;
        final int limit = 200;
        while (start < 2000) {
            String path =
                    "/LiveTv/Channels?UserId="
                            + user
                            + "&AddCurrentProgram=true&EnableUserData=false&Limit="
                            + limit
                            + "&StartIndex="
                            + start;
            JSONObject resp = get(path);
            JSONArray items = resp.optJSONArray("Items");
            if (items == null || items.length() == 0) break;
            for (int i = 0; i < items.length(); i++) {
                JSONObject row = items.optJSONObject(i);
                if (row == null) continue;
                String rawId = row.optString("Id", "").trim();
                if (rawId.length() == 0) continue;
                String id = segment(rawId);
                String name = row.optString("Name", "").trim();
                if (name.length() == 0) name = "频道 " + (out.length() + 1);
                String number = row.optString("Number", row.optString("ChannelNumber", "")).trim();
                String tag =
                        row.optJSONObject("ImageTags") == null
                                ? ""
                                : row.optJSONObject("ImageTags").optString("Primary", "");
                String logo =
                        tag.length() > 0
                                ? base
                                        + "/Items/"
                                        + id
                                        + "/Images/Primary?maxWidth=300&tag="
                                        + encode(tag)
                                        + "#mm-emby="
                                        + account
                                : "";
                String epg = "";
                JSONObject prog = row.optJSONObject("CurrentProgram");
                if (prog != null) {
                    String pName = prog.optString("Name", "").trim();
                    String pEp = prog.optString("EpisodeTitle", "").trim();
                    if (pName.length() > 0) {
                        epg =
                                pEp.length() > 0 && !pEp.equalsIgnoreCase(pName)
                                        ? pName + " · " + pEp
                                        : pName;
                    }
                }
                String group = "";
                JSONArray tags = row.optJSONArray("Tags");
                if (tags != null && tags.length() > 0) {
                    group = tags.optString(0, "").trim();
                }
                out.put(
                        new JSONObject()
                                .put("id", id)
                                .put("name", name)
                                .put("number", number)
                                .put("logo", logo)
                                .put("epg", epg)
                                .put("group", group)
                                .put(
                                        "url",
                                        LIVE_PLAY_PREFIX
                                                + "account="
                                                + encode(account)
                                                + "&id="
                                                + encode(id)));
            }
            start += items.length();
            int total = resp.optInt("TotalRecordCount", start);
            if (items.length() < limit || start >= total) break;
        }
        return out;
    }

    /** Resolves an Emby / Jellyfin Live TV channel into a playable stream URL with live session metadata. */
    public JSONObject resolveLiveChannel(String rawIdOrUri, boolean legacyPlayer) throws Exception {
        String id = rawIdOrUri == null ? "" : rawIdOrUri.trim();
        if (id.startsWith(LIVE_PLAY_PREFIX)) {
            String acct = parseLiveAccount(id);
            if (acct.length() > 0 && !acct.equals(account)) {
                throw new IOException("Emby 直播频道与当前账户不匹配");
            }
            id = parseLiveChannelId(id);
        }
        id = segment(id);
        JSONObject profile =
                new JSONObject()
                        .put("Name", "Marco Movie Live")
                        .put("MaxStreamingBitrate", 80000000)
                        .put(
                                "DirectPlayProfiles",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("Type", "Video")
                                                        .put(
                                                                "Container",
                                                                legacyPlayer
                                                                        ? "ts,mp4,m3u8"
                                                                        : "ts,mpegts,mp4,m4v,mkv,hls,m3u8")
                                                        .put(
                                                                "VideoCodec",
                                                                legacyPlayer
                                                                        ? "h264"
                                                                        : "h264,hevc,h265,mpeg2video")
                                                        .put(
                                                                "AudioCodec",
                                                                legacyPlayer
                                                                        ? "aac,mp3"
                                                                        : "aac,mp3,mp2,ac3,eac3")))
                        .put(
                                "TranscodingProfiles",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("Type", "Video")
                                                        .put("Container", "ts")
                                                        .put("Protocol", "hls")
                                                        .put("VideoCodec", "h264")
                                                        .put("AudioCodec", "aac")
                                                        .put("Context", "Streaming")
                                                        .put("MaxAudioChannels", "2")
                                                        .put("MinSegments", 1)));
        JSONObject body =
                new JSONObject()
                        .put("UserId", user)
                        .put("IsPlayback", true)
                        .put("AutoOpenLiveStream", true)
                        .put("EnableDirectPlay", true)
                        .put("EnableDirectStream", true)
                        .put("EnableTranscoding", true)
                        .put("MaxStreamingBitrate", 80000000)
                        .put("DeviceProfile", profile);
        JSONObject info = request(base + "/Items/" + id + "/PlaybackInfo", device, token, body);
        if (!info.optString("ErrorCode").isEmpty()) {
            throw new IOException("Emby 无法打开此直播频道（" + info.optString("ErrorCode") + "）");
        }
        JSONArray sources = info.optJSONArray("MediaSources");
        if (sources == null || sources.length() == 0) {
            throw new IOException("Emby 未返回可用的直播流来源");
        }
        JSONObject source = sources.optJSONObject(0);
        String session = info.optString("PlaySessionId", "");
        if (source == null) throw new IOException("Emby 直播流信息无效");
        String liveStreamId = source.optString("LiveStreamId", "").trim();
        if (liveStreamId.length() == 0
                && source.optBoolean("RequiresOpening", false)
                && source.optString("OpenToken", "").trim().length() > 0) {
            JSONObject openReq =
                    new JSONObject()
                            .put("OpenToken", source.optString("OpenToken").trim())
                            .put("UserId", user)
                            .put("PlaySessionId", session)
                            .put("ItemId", id)
                            .put("EnableDirectPlay", true)
                            .put("EnableDirectStream", true)
                            .put("DeviceProfile", profile);
            JSONObject opened = request(base + "/LiveTv/LiveStreams/Open", device, token, openReq);
            JSONObject openedSource = opened.optJSONObject("MediaSource");
            if (openedSource != null) {
                source = openedSource;
                liveStreamId = source.optString("LiveStreamId", "").trim();
            }
        }
        String sourceId = source.optString("Id", id);
        boolean direct =
                source.optBoolean("SupportsDirectStream", false)
                        || source.optBoolean("SupportsDirectPlay", false);
        String directRel = source.optString("DirectStreamUrl", "").trim();
        String transRel = source.optString("TranscodingUrl", "").trim();
        String rawPath = source.optString("Path", "").trim();

        String streamUrl;
        Map<String, String> outHeaders = new LinkedHashMap<String, String>();
        String playMethod;
        if (direct && directRel.length() > 0) {
            streamUrl = resolveSameOriginLiveUrl(directRel, sourceId, session, liveStreamId);
            outHeaders.put("X-Emby-Token", token);
            playMethod = "DirectStream";
        } else if (!direct && transRel.length() > 0) {
            streamUrl = resolveSameOriginLiveUrl(transRel, sourceId, session, liveStreamId);
            outHeaders.put("X-Emby-Token", token);
            playMethod = "Transcode";
        } else if (direct && liveStreamId.length() > 0) {
            Map<String, String> params = new LinkedHashMap<String, String>();
            params.put("Static", "true");
            params.put("MediaSourceId", sourceId);
            params.put("LiveStreamId", liveStreamId);
            if (session.length() > 0) params.put("PlaySessionId", session);
            params.put("DeviceId", device);
            streamUrl = base + "/Videos/" + id + "/stream?" + queryString(params);
            outHeaders.put("X-Emby-Token", token);
            playMethod = "DirectStream";
        } else if (transRel.length() > 0) {
            streamUrl = resolveSameOriginLiveUrl(transRel, sourceId, session, liveStreamId);
            outHeaders.put("X-Emby-Token", token);
            playMethod = "Transcode";
        } else if (direct
                && (rawPath.regionMatches(true, 0, "http://", 0, 7)
                        || rawPath.regionMatches(true, 0, "https://", 0, 8))) {
            streamUrl = rawPath;
            playMethod = "DirectPlay";
            JSONObject reqHeaders = source.optJSONObject("RequiredHttpHeaders");
            if (reqHeaders != null) {
                Iterator<String> keys = reqHeaders.keys();
                while (keys.hasNext()) {
                    String k = keys.next();
                    String val = reqHeaders.optString(k, "");
                    if (val.length() > 0) outHeaders.put(k, val);
                }
            }
            if (isSameOriginUrl(rawPath)) {
                outHeaders.put("X-Emby-Token", token);
            }
        } else {
            throw new IOException("Emby 直播频道没有可用的直连或转码地址");
        }
        JSONObject metadata =
                new JSONObject()
                        .put("ItemId", id)
                        .put("MediaSourceId", sourceId)
                        .put("PlaySessionId", session)
                        .put("PlayMethod", playMethod)
                        .put("CanSeek", false);
        if (liveStreamId.length() > 0) {
            metadata.put("LiveStreamId", liveStreamId);
        }
        return new JSONObject()
                .put("parse", 0)
                .put("url", streamUrl)
                .put("header", new JSONObject(outHeaders))
                .put("embySession", metadata);
    }

    /**
     * Resolves an Emby {@code TranscodingUrl} (absolute, root-relative {@code /videos/...},
     * {@code /emby/videos/...}, or subpath-relative {@code Videos/...}) against {@code base}
     * without losing reverse-proxy subpaths or {@code /emby} prefixes (Issue #85).
     */
    private URI resolveServerMediaUri(URI server, String basePath, String rawUrl) throws Exception {
        String trimmed = rawUrl == null ? "" : rawUrl.trim();
        if (trimmed.startsWith("/") && !trimmed.startsWith("//")) {
            String lower = trimmed.toLowerCase(Locale.US);
            String bpLower = basePath.toLowerCase(Locale.US);
            if (basePath.length() > 0 && !lower.startsWith(bpLower + "/")) {
                if (lower.startsWith("/videos/")) {
                    trimmed = basePath + trimmed;
                } else if (lower.startsWith("/emby/") && bpLower.endsWith("/emby")) {
                    String proxyPrefix = basePath.substring(0, basePath.length() - 5);
                    if (proxyPrefix.length() > 0) {
                        trimmed = proxyPrefix + trimmed;
                    }
                }
            }
        }
        return new URL(new URL(base + "/"), trimmed).toURI().normalize();
    }

    private boolean isSameOriginUrl(String candidate) {
        try {
            URI server = new URI(base);
            URI target = new URI(candidate);
            return sameOrigin(server, target);
        } catch (Exception ignored) {
            return false;
        }
    }

    private String resolveSameOriginLiveUrl(
            String relOrAbs, String sourceId, String session, String liveStreamId)
            throws Exception {
        URI target = new URL(new URL(base + "/"), relOrAbs).toURI().normalize();
        URI server = new URI(base);
        if (!sameOrigin(server, target) || target.getUserInfo() != null) {
            throw new IOException("Emby 直播流地址与服务器不匹配");
        }
        Map<String, String> params = new LinkedHashMap<String, String>();
        params.putAll(query(target.getRawQuery()));
        for (String key : new ArrayList<String>(params.keySet())) {
            if (key.equalsIgnoreCase("api_key") || key.equalsIgnoreCase("x-emby-token")) {
                params.remove(key);
            }
        }
        if (sourceId.length() > 0 && !params.containsKey("MediaSourceId")) {
            params.put("MediaSourceId", sourceId);
        }
        if (session.length() > 0 && !params.containsKey("PlaySessionId")) {
            params.put("PlaySessionId", session);
        }
        if (liveStreamId.length() > 0 && !params.containsKey("LiveStreamId")) {
            params.put("LiveStreamId", liveStreamId);
        }
        if (!params.containsKey("DeviceId")) {
            params.put("DeviceId", device);
        }
        String cleanPath =
                new URI(target.getScheme(), target.getAuthority(), target.getPath(), null, null)
                        .toString();
        return params.isEmpty() ? cleanPath : cleanPath + "?" + queryString(params);
    }

    public Reporter track(JSONObject metadata) {
        return new Reporter(this, metadata);
    }

    /** Coalesces telemetry so slow servers cannot create an unbounded per-player queue. */
    public static final class Reporter implements Runnable {
        private static final java.util.concurrent.ThreadPoolExecutor EXECUTOR =
                new java.util.concurrent.ThreadPoolExecutor(
                        0,
                        1,
                        15,
                        java.util.concurrent.TimeUnit.SECONDS,
                        new java.util.concurrent.ArrayBlockingQueue<Runnable>(32),
                        new java.util.concurrent.ThreadFactory() {
                            public Thread newThread(Runnable work) {
                                Thread t = new Thread(work, "emby-checkin");
                                t.setDaemon(true);
                                return t;
                            }
                        });
        private final MobileEmbyLibrary library;
        private final JSONObject metadata;
        private boolean running, pending, stopped, started, paused;
        private long position, lastUpdate = -10000;
        private final long began = System.nanoTime();
        private String event = "TimeUpdate";

        private Reporter(MobileEmbyLibrary library, JSONObject metadata) {
            this.library = library;
            this.metadata = metadata;
        }

        public synchronized boolean matches(JSONObject other) {
            return !stopped
                    && other != null
                    && metadata.optString("PlaySessionId").equals(other.optString("PlaySessionId"));
        }

        public synchronized void update(long positionMs, boolean isPaused) {
            if (stopped) return;
            position = Math.max(0, positionMs);
            boolean changed = paused != isPaused;
            paused = isPaused;
            long now = (System.nanoTime() - began) / 1000000;
            if (!changed && now - lastUpdate < 10000) return;
            lastUpdate = now;
            event = changed ? (paused ? "Pause" : "Unpause") : "TimeUpdate";
            pending = true;
            schedule();
        }

        public synchronized void stop(long positionMs) {
            if (stopped) return;
            stopped = true;
            position = Math.max(0, positionMs);
            pending = true;
            schedule();
        }

        private void schedule() {
            if (running) return;
            running = true;
            try {
                EXECUTOR.execute(this);
            } catch (java.util.concurrent.RejectedExecutionException busy) {
                running = false;
            }
        }

        public void run() {
            while (true) {
                long at;
                boolean pause, stop;
                String why;
                synchronized (this) {
                    if (!pending) {
                        running = false;
                        return;
                    }
                    pending = false;
                    at = position;
                    pause = paused;
                    stop = stopped;
                    why = started ? event : "Start";
                }
                try {
                    library.report(metadata, why, at, pause, stop);
                    synchronized (this) {
                        if (!stop) started = true;
                    }
                } catch (Exception ignored) {
                    /* Check-in failure must not interrupt local video. */
                }
            }
        }
    }

    private JSONObject get(String path) throws Exception {
        return request(base + path, device, token, null);
    }

    private JSONObject card(JSONObject i) throws Exception {
        String id = segment(i.getString("Id"));
        String tag =
                i.optJSONObject("ImageTags") == null
                        ? ""
                        : i.getJSONObject("ImageTags").optString("Primary");
        JSONObject out =
                new JSONObject()
                        .put("vod_id", id)
                        .put("vod_name", i.optString("Name"))
                        .put("vod_year", i.optString("ProductionYear"))
                        .put("vod_content", i.optString("Overview"))
                        .put(
                                "vod_pic",
                                base
                                        + "/Items/"
                                        + id
                                        + "/Images/Primary?maxWidth=500&tag="
                                        + encode(tag)
                                        + "#mm-emby="
                                        + account);
        double rating = i.optDouble("CommunityRating", 0.0);
        if (rating >= 2.0 && rating <= 9.9) {
            out.put("vod_douban_score", String.format(java.util.Locale.US, "%.1f", rating));
        }
        return out;
    }

    public JSONObject home() throws Exception {
        JSONArray views = get("/Users/" + user + "/Views").getJSONArray("Items"),
                groups = new JSONArray();
        for (int i = 0; i < views.length(); i++) {
            JSONObject row = views.getJSONObject(i);
            groups.put(
                    new JSONObject()
                            .put("type_id", row.getString("Id"))
                            .put("type_name", row.optString("Name")));
        }
        if (groups.length() == 0) {
            groups.put(new JSONObject().put("type_id", "").put("type_name", "全部媒体"));
        }
        return new JSONObject().put("class", groups).put("list", new JSONArray());
    }

    public JSONObject list(String parent, String query, int page) throws Exception {
        int start = Math.max(0, page - 1) * PAGE_SIZE;
        String path =
                "/Users/"
                        + user
                        + "/Items?Recursive=true&IncludeItemTypes=Movie,Series,Video&Fields=Overview,ProductionYear,CommunityRating&Limit="
                        + PAGE_SIZE
                        + "&StartIndex="
                        + start;
        if (parent.length() > 0) path += "&ParentId=" + segment(parent);
        if (query.length() > 0) path += "&SearchTerm=" + encode(query);
        JSONObject response = get(path);
        JSONArray rows = response.getJSONArray("Items"), cards = new JSONArray();
        for (int i = 0; i < rows.length(); i++) cards.put(card(rows.getJSONObject(i)));
        return new JSONObject()
                .put("list", cards)
                .put("page", page)
                .put(
                        "pagecount",
                        Math.max(
                                page,
                                (response.optInt("TotalRecordCount", start + rows.length())
                                                + PAGE_SIZE
                                                - 1)
                                        / PAGE_SIZE));
    }

    public JSONObject detail(String id) throws Exception {
        JSONObject item =
                get("/Users/" + user + "/Items/" + segment(id) + "?Fields=MediaSources,Overview");
        JSONObject video = card(item);
        List<String> lines = new ArrayList<String>();
        if (item.optString("Type").equals("Series")) {
            int start = 0;
            while (start < 10000) {
                JSONObject page =
                        get(
                                "/Shows/"
                                        + segment(id)
                                        + "/Episodes?UserId="
                                        + user
                                        + "&Fields=MediaSources&Limit=200&StartIndex="
                                        + start);
                JSONArray episodes = page.getJSONArray("Items");
                for (int i = 0; i < episodes.length(); i++)
                    addEpisode(lines, episodes.getJSONObject(i));
                start += episodes.length();
                if (episodes.length() == 0 || start >= page.optInt("TotalRecordCount", start))
                    break;
            }
        } else addEpisode(lines, item);
        StringBuilder flat = new StringBuilder();
        for (String e : lines) {
            if (flat.length() > 0) flat.append('#');
            flat.append(e);
        }
        return new JSONObject()
                .put(
                        "list",
                        new JSONArray()
                                .put(
                                        video.put("vod_play_from", "Emby")
                                                .put("vod_play_url", flat.toString())));
    }

    private void addEpisode(List<String> episodes, JSONObject item) throws Exception {
        String id = segment(item.getString("Id")), source = id;
        JSONArray media = item.optJSONArray("MediaSources");
        if (media != null && media.length() > 0)
            source = media.getJSONObject(0).optString("Id", id);
        String label = item.optString("Name", "正片").replace('#', '＃').replace('$', '＄');
        if (item.has("ParentIndexNumber") && item.has("IndexNumber"))
            label =
                    "S"
                            + item.getInt("ParentIndexNumber")
                            + "E"
                            + item.getInt("IndexNumber")
                            + " "
                            + label;
        episodes.add(
                label
                        + "$"
                        + base
                        + "/Videos/"
                        + id
                        + "/stream?Static=true&MediaSourceId="
                        + encode(source));
    }
}

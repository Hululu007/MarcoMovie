// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.GZIPOutputStream;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONArray;
import org.json.JSONObject;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

public final class LiteJvmChecks {
    private static int checks = 0;

    private static void check(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError("Check failed: " + label);
        }
        checks++;
    }

    private static String toHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (int i = 0; i < bytes.length; i++) {
            String h = Integer.toHexString(bytes[i] & 0xff);
            if (h.length() == 1) sb.append('0');
            sb.append(h);
        }
        return sb.toString();
    }

    private static String readHttp(String urlStr, String rangeHeader) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        if (rangeHeader != null) conn.setRequestProperty("Range", rangeHeader);
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(5000);
        int code = conn.getResponseCode();
        InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (in != null) {
            byte[] buf = new byte[1024];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            in.close();
        }
        conn.disconnect();
        return code + ":" + new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    private static String rawPostConfigServer(int port, String token, String origin, byte[] body)
            throws Exception {
        java.net.Socket sock = new java.net.Socket("127.0.0.1", port);
        try {
            sock.setSoTimeout(5000);
            String headers =
                    "POST /"
                            + token
                            + " HTTP/1.1\r\n"
                            + "Host: 127.0.0.1:"
                            + port
                            + "\r\n"
                            + "Origin: "
                            + origin
                            + "\r\n"
                            + "Content-Type: application/x-www-form-urlencoded\r\n"
                            + "Content-Length: "
                            + body.length
                            + "\r\n\r\n";
            OutputStream out = sock.getOutputStream();
            out.write(headers.getBytes(StandardCharsets.US_ASCII));
            out.write(body);
            out.flush();
            InputStream in = sock.getInputStream();
            ByteArrayOutputStream resp = new ByteArrayOutputStream();
            byte[] buf = new byte[512];
            int n;
            while ((n = in.read(buf)) != -1) resp.write(buf, 0, n);
            return new String(resp.toByteArray(), StandardCharsets.UTF_8);
        } finally {
            sock.close();
        }
    }

    public static void main(String[] args) throws Exception {
        testResolveWebdavFileUrlMatrix();
        testWebdavErrorDiagnostics();
        testConfigDecodingAndSites();
        testXmlAndJsonCmsParsing();
        testLiveParsing();
        testStoreJsonPersistence();
        testStoreCorruptionProtection();
        testEpisodeGroupingAndPlayerHelpers();
        testMediaProxyLoopback();
        testLiteSyncV2AndLanServer();
        testLiteSyncEtagAndConcurrency();
        testConfigPullAndCapabilityStatus();
        System.out.println(
                "PASS " + checks + " TV Lite JVM checks ("
                        + checks
                        + " total § C5 pull & C6 capability checks passed)");
    }

    private static void testResolveWebdavFileUrlMatrix() throws Exception {
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/")),
                "LiteSync Jianguoyun root folder trailing slash appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav")),
                "LiteSync Jianguoyun root folder without trailing slash appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("dav.jianguoyun.com/dav/")),
                "LiteSync Jianguoyun scheme-less URL auto-prepends https and appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/我的坚果云/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/我的坚果云/")),
                "LiteSync Jianguoyun custom folder preserves user subfolder");
        check(
                "https://dav.jianguoyun.com/dav/a/x.json"
                        .equals(LiteSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/a/x.json")),
                "LiteSync Jianguoyun explicit json file URL left untouched");
        check(
                "https://nas.local:5006/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("https://nas.local:5006/")),
                "LiteSync Non-Jianguoyun WebDAV server does not append MarcoMovie subfolder");
    }

    private static void testWebdavErrorDiagnostics() {
        String err404 = LiteSync.formatWebdavWriteError(404);
        check(
                err404.contains("HTTP 404") && err404.contains("坚果云请在地址后加一个文件夹名"),
                "LiteSync HTTP 404 provides actionable Jianguoyun diagnostic error message");
        String err409 = LiteSync.formatWebdavWriteError(409);
        check(
                err409.contains("HTTP 409") && err409.contains("坚果云请在地址后加一个文件夹名"),
                "LiteSync HTTP 409 provides actionable Jianguoyun diagnostic error message");
        check(
                "WebDAV 写入失败 (HTTP 405)：服务器不允许写入".equals(LiteSync.formatWebdavWriteError(405)),
                "LiteSync HTTP 405 provides method not allowed message");
        check(
                "WebDAV 写入失败 (HTTP 423)：文件被锁定".equals(LiteSync.formatWebdavWriteError(423)),
                "LiteSync HTTP 423 provides locked file message");
        check(
                "WebDAV 写入失败 (HTTP 507)：空间不足".equals(LiteSync.formatWebdavWriteError(507)),
                "LiteSync HTTP 507 provides insufficient storage message");
    }

    private static void testConfigDecodingAndSites() throws Exception {
        String rawJson = "{\"sites\":["
            + "{\"key\":\"json_cms\",\"name\":\"JSON源\",\"type\":1,\"api\":\"http://127.0.0.1:9/api.php/provide/vod/\",\"ua\":\"CustomUA/1.0\",\"ext\":{\"headers\":{\"Referer\":\"http://ref.example/\"}}},"
            + "{\"key\":\"xml_cms\",\"name\":\"XML源\",\"type\":0,\"api\":\"http://127.0.0.1:9/api.php/provide/vod/at/xml/\"}"
            + "],\"lives\":[{\"name\":\"测试直播\",\"url\":\"http://127.0.0.1:9/live.txt\",\"ua\":\"LiveUA/2.0\"}]}";

        // 1. Plain JSON config
        List<LiteCatalog.Site> plainSites = LiteCatalog.parse(rawJson, "http://127.0.0.1:9/config.json");
        check(plainSites.size() == 2, "plain config sites count");
        check(plainSites.get(0).supported && plainSites.get(0).type == 1, "type 1 JSON CMS supported");
        check("CustomUA/1.0".equals(plainSites.get(0).headers.get("User-Agent")), "site custom UA extracted");
        check("http://ref.example/".equals(plainSites.get(0).headers.get("Referer")), "site ext.headers extracted");
        check(plainSites.get(1).supported && plainSites.get(1).type == 0, "type 0 XML CMS supported");

        // 2. GZIP compressed config
        ByteArrayOutputStream gzBuffer = new ByteArrayOutputStream();
        GZIPOutputStream gz = new GZIPOutputStream(gzBuffer);
        gz.write(rawJson.getBytes(StandardCharsets.UTF_8));
        gz.close();
        String decodedGzip = LiteCatalog.decodeText(gzBuffer.toByteArray());
        check(LiteCatalog.parse(decodedGzip, "http://127.0.0.1:9/config.gz").size() == 2, "GZIP config decoded");

        // 3. '**' Base64 config
        String b64Config = "prefix**" + java.util.Base64.getEncoder().encodeToString(rawJson.getBytes(StandardCharsets.UTF_8));
        check(LiteCatalog.parse(b64Config, "http://127.0.0.1:9/config.b64").size() == 2, "** Base64 config decoded");

        // 4. '2423' Hex-AES-128-CBC config (13-byte IV in 26-char hex tail, right-padded with '0' to 16 bytes)
        String keyStr = "mysecretkey12345"; // 16 chars
        String iv13 = "1234567890abc";      // 13 chars -> 26 hex chars
        String iv16 = "1234567890abc000";   // padded to 16 bytes
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(
            Cipher.ENCRYPT_MODE,
            new SecretKeySpec(keyStr.getBytes(StandardCharsets.UTF_8), "AES"),
            new IvParameterSpec(iv16.getBytes(StandardCharsets.UTF_8))
        );
        byte[] encrypted = cipher.doFinal(rawJson.getBytes(StandardCharsets.UTF_8));
        String hexPayload = "2423"
            + toHex(keyStr.getBytes(StandardCharsets.UTF_8))
            + "2324"
            + toHex(encrypted)
            + toHex(iv13.getBytes(StandardCharsets.UTF_8));
        check(LiteCatalog.parse(hexPayload, "http://127.0.0.1:9/config.2423").size() == 2, "2423 Hex-AES config decoded");

        // 4b. '2423' Hex-AES with odd-offset "2324" within key (e.g. "22@" hex has "2324" at odd offset 1)
        String oddKeyStr = "22@key1234567890"; // 16 chars, hex starts with "323240..." where index 1-4 is "2324"
        Cipher oddCipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        oddCipher.init(
            Cipher.ENCRYPT_MODE,
            new SecretKeySpec(oddKeyStr.getBytes(StandardCharsets.UTF_8), "AES"),
            new IvParameterSpec(iv16.getBytes(StandardCharsets.UTF_8))
        );
        byte[] oddEncrypted = oddCipher.doFinal(rawJson.getBytes(StandardCharsets.UTF_8));
        String oddHexPayload = "2423"
            + toHex(oddKeyStr.getBytes(StandardCharsets.UTF_8))
            + "2324"
            + toHex(oddEncrypted)
            + toHex(iv13.getBytes(StandardCharsets.UTF_8));
        check(LiteCatalog.parse(oddHexPayload, "http://127.0.0.1:9/config.2423").size() == 2, "2423 Hex-AES config with odd-index 2324 inside key decoded");

        // 4c. '2423' Hex-AES with embedded whitespace
        String hexWithWhitespace = "  2423 \r\n"
            + toHex(keyStr.getBytes(StandardCharsets.UTF_8))
            + " \n 2324 \t"
            + toHex(encrypted)
            + "\r\n "
            + toHex(iv13.getBytes(StandardCharsets.UTF_8))
            + " \n ";
        check(LiteCatalog.parse(hexWithWhitespace, "http://127.0.0.1:9/config.2423").size() == 2, "2423 Hex-AES config with whitespace decoded");

        // 5. Live sources extracted from config
        List<LiteCatalog.LiveSource> liveSources = LiteCatalog.parseLives(rawJson, "http://127.0.0.1:9/config.json");
        check(liveSources.size() == 1 && "http://127.0.0.1:9/live.txt".equals(liveSources.get(0).url), "live source parsed");
        check("LiveUA/2.0".equals(liveSources.get(0).headers.get("User-Agent")), "live source UA parsed");

        // 6. JSON null fields handling in Lite
        JSONObject nullLiteCfg = new JSONObject();
        JSONArray nullLiteSites = new JSONArray();
        JSONObject nullLiteSite = new JSONObject();
        nullLiteSite.put("key", "null-lite");
        nullLiteSite.put("name", "Null Lite");
        nullLiteSite.put("type", 1);
        nullLiteSite.put("api", "http://127.0.0.1:9/api.php/provide/vod/");
        nullLiteSite.put("playUrl", JSONObject.NULL);
        nullLiteSite.put("ua", JSONObject.NULL);
        JSONObject nullExt = new JSONObject();
        nullExt.put("ua", JSONObject.NULL);
        nullLiteSite.put("ext", nullExt);
        nullLiteSites.put(nullLiteSite);
        nullLiteCfg.put("sites", nullLiteSites);
        List<LiteCatalog.Site> parsedNullLite = LiteCatalog.parse(nullLiteCfg.toString(), "http://127.0.0.1:9/config.json");
        check(parsedNullLite.size() == 1, "Lite null config parses site");
        check("".equals(parsedNullLite.get(0).playUrl), "Lite playUrl with null degrades to empty string");
        check(parsedNullLite.get(0).headers.get("User-Agent") == null, "Lite User-Agent with null is not set to literal null");

        JSONObject nullLiveCfg = new JSONObject();
        JSONArray nullLiveArr = new JSONArray();
        JSONObject nullLiveItem = new JSONObject();
        nullLiveItem.put("name", "Live Null");
        nullLiveItem.put("url", "http://127.0.0.1:9/live.txt");
        nullLiveItem.put("ua", JSONObject.NULL);
        nullLiveArr.put(nullLiveItem);
        nullLiveCfg.put("lives", nullLiveArr);
        List<LiteCatalog.LiveSource> parsedNullLives = LiteCatalog.parseLives(nullLiveCfg.toString(), "http://127.0.0.1:9/config.json");
        check(parsedNullLives.size() == 1 && parsedNullLives.get(0).headers.get("User-Agent") == null, "Lite live UA with null is not set to literal null");

        // 7. Missing type HTTP CMS sites default to type 1 or 0 and marked supported
        String missingTypeJsonLite = "{\"sites\":[{\"key\":\"no_type_json\",\"name\":\"NoTypeJson\",\"api\":\"http://127.0.0.1:9/api.php/provide/vod/\"}]}";
        List<LiteCatalog.Site> parsedMissingJson = LiteCatalog.parse(missingTypeJsonLite, "http://127.0.0.1:9/config.json");
        check(parsedMissingJson.size() == 1 && parsedMissingJson.get(0).type == 1 && parsedMissingJson.get(0).supported, "Lite missing type JSON site defaults to type 1 and is supported");

        String missingTypeXmlLite = "{\"sites\":[{\"key\":\"no_type_xml\",\"name\":\"NoTypeXml\",\"api\":\"http://127.0.0.1:9/vod.xml\"}]}";
        List<LiteCatalog.Site> parsedMissingXml = LiteCatalog.parse(missingTypeXmlLite, "http://127.0.0.1:9/config.json");
        check(parsedMissingXml.size() == 1 && parsedMissingXml.get(0).type == 0 && parsedMissingXml.get(0).supported, "Lite missing type XML site defaults to type 0 and is supported");
    }

    private static void testXmlAndJsonCmsParsing() throws Exception {
        String xmlList = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<rss version=\"5.1\">"
            + "<class><ty id=\"1\">电影</ty><ty id=\"2\">剧集</ty></class>"
            + "<list page=\"1\" pagecount=\"4\" pagesize=\"20\" recordcount=\"80\">"
            + "<video><id>101</id><name><![CDATA[测试XML电影]]></name><type>电影</type><pic>http://127.0.0.1:9/poster.jpg</pic><note><![CDATA[HD高清]]></note><year>2025</year><area>中国</area></video>"
            + "</list></rss>";

        JSONObject parsedPage = LiteCatalog.parseCmsResponse(xmlList);
        check(parsedPage.optInt("pagecount") == 4, "XML pageCount parsed");
        List<LiteCatalog.Category> cats = LiteCatalog.categories(xmlList);
        check(cats.size() == 2 && "电影".equals(cats.get(0).name), "XML categories parsed");
        JSONArray list = LiteCatalog.list(xmlList);
        check(list.length() == 1 && "101".equals(list.getJSONObject(0).optString("vod_id")), "XML video item id parsed");
        check("测试XML电影".equals(list.getJSONObject(0).optString("vod_name")), "XML CDATA title parsed");
        check("HD高清".equals(list.getJSONObject(0).optString("vod_remarks")), "XML CDATA note parsed");
        check("2025".equals(list.getJSONObject(0).optString("vod_year")) && "中国".equals(list.getJSONObject(0).optString("vod_area")), "XML year and area parsed");

        String xmlDetail = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<rss version=\"5.1\"><list page=\"1\" pagecount=\"1\">"
            + "<video><id>101</id><name><![CDATA[测试XML电影]]></name><pic>http://127.0.0.1:9/poster.jpg</pic>"
            + "<type>电影</type><year>2025</year><area>中国</area><actor><![CDATA[演员A,演员B]]></actor><director><![CDATA[导演X]]></director>"
            + "<des><![CDATA[这是一部用于TV端XML解析验证的影片。]]></des>"
            + "<dl><dd flag=\"m3u8线路\"><![CDATA[第01集$http://127.0.0.1:9/ep1.m3u8#第02集$http://127.0.0.1:9/ep2.m3u8]]></dd>"
            + "<dd flag=\"备用MP4\"><![CDATA[正片$http://127.0.0.1:9/movie.mp4]]></dd></dl>"
            + "</video></list></rss>";

        JSONObject detailItem = LiteCatalog.list(xmlDetail).getJSONObject(0);
        check("101".equals(detailItem.optString("vod_id")) && "测试XML电影".equals(detailItem.optString("vod_name")), "XML detail id and name");
        check("演员A,演员B".equals(detailItem.optString("vod_actor")) && "导演X".equals(detailItem.optString("vod_director")), "XML actor and director");
        check("这是一部用于TV端XML解析验证的影片。".equals(detailItem.optString("vod_content")), "XML synopsis parsed");
        check("m3u8线路$$$备用MP4".equals(detailItem.optString("vod_play_from")), "XML dd flag lines joined with $$$");
        check(detailItem.optString("vod_play_url").contains("ep1.m3u8") && detailItem.optString("vod_play_url").contains("$$$"), "XML dd episode URLs joined with $$$");
    }

    private static void testLiveParsing() throws Exception {
        String txtContent = "央视频道,#genre#\n"
            + "CCTV-1综合,http://127.0.0.1:9/cctv1.m3u8\n"
            + "CCTV-5体育,http://127.0.0.1:9/cctv5.m3u8\n"
            + "卫视频道,#genre#\n"
            + "湖南卫视,http://127.0.0.1:9/hunan.m3u8#http://127.0.0.1:9/hunan_backup.m3u8\n";
        List<LiteCatalog.LiveGroup> txtGroups = LiteCatalog.parseLiveContent(txtContent);
        check(txtGroups.size() == 2, "TXT live groups count");
        check("央视频道".equals(txtGroups.get(0).name) && txtGroups.get(0).channels.size() == 2, "TXT group 1 channels");
        check("卫视频道".equals(txtGroups.get(1).name) && txtGroups.get(1).channels.get(0).urls.size() == 2, "TXT multi-source URLs preserved");

        String m3uContent = "#EXTM3U\n"
            + "#EXTINF:-1 group-title=\"纪录频道\",CCTV-9纪录\n"
            + "#EXTVLCOPT:http-user-agent=M3uPlayer/1.0\n"
            + "http://127.0.0.1:9/cctv9.m3u8\n"
            + "#EXTINF:-1 group-title=\"纪录频道\",探索频道\n"
            + "http://127.0.0.1:9/discovery.m3u8\n";
        List<LiteCatalog.LiveGroup> m3uGroups = LiteCatalog.parseLiveContent(m3uContent);
        check(m3uGroups.size() == 1 && "纪录频道".equals(m3uGroups.get(0).name), "M3U group-title parsed");
        check(m3uGroups.get(0).channels.size() == 2 && "CCTV-9纪录".equals(m3uGroups.get(0).channels.get(0).name), "M3U channels parsed");
        check("M3uPlayer/1.0".equals(m3uGroups.get(0).channels.get(0).headers.get("User-Agent")), "M3U EXTVLCOPT UA header parsed");

        LiteCatalog.LiveSource proxySource = new LiteCatalog.LiveSource();
        proxySource.name = "内置代理直播";
        proxySource.url = "proxy://do=live&type=txt&ext=" + java.util.Base64.getUrlEncoder().encodeToString(txtContent.getBytes(StandardCharsets.UTF_8));
        List<LiteCatalog.LiveGroup> proxyGroups = LiteCatalog.fetchLiveGroups(proxySource);
        check(proxyGroups.size() == 2 && proxyGroups.get(0).channels.size() == 2, "proxy:// base64 live source parsed");
    }

    private static void testStoreJsonPersistence() {
        String historyRaw = "[]";
        LiteStore.HistoryEntry h1 = new LiteStore.HistoryEntry();
        h1.siteKey = "cms1";
        h1.siteName = "CMS一";
        h1.siteApi = "http://127.0.0.1:9/cms1";
        h1.vodId = "v1";
        h1.vodName = "仙逆";
        h1.lineName = "线路A";
        h1.epName = "第12集";
        h1.epUrl = "http://127.0.0.1:9/v1_12.m3u8";
        h1.positionMs = 125000;
        h1.durationMs = 1440000;
        h1.updatedAt = 1000L;

        LiteStore.HistoryEntry h2 = new LiteStore.HistoryEntry();
        h2.siteKey = "cms2";
        h2.siteName = "CMS二";
        h2.siteApi = "http://127.0.0.1:9/cms2";
        h2.vodId = "v2";
        h2.vodName = "凡人修仙传";
        h2.lineName = "线路B";
        h2.epName = "第05集";
        h2.epUrl = "http://127.0.0.1:9/v2_05.m3u8";
        h2.positionMs = 65000;
        h2.durationMs = 1200000;
        h2.updatedAt = 2000L;

        historyRaw = LiteStore.recordHistoryJson(historyRaw, h1);
        historyRaw = LiteStore.recordHistoryJson(historyRaw, h2);
        List<LiteStore.HistoryEntry> history = LiteStore.parseHistoryJson(historyRaw);
        check(history.size() == 2 && "v2".equals(history.get(0).vodId), "history most recent first");

        // Updating v1 moves it to index 0 and deduplicates
        h1.positionMs = 300000;
        h1.updatedAt = 3000L;
        historyRaw = LiteStore.recordHistoryJson(historyRaw, h1);
        history = LiteStore.parseHistoryJson(historyRaw);
        check(history.size() == 2 && "v1".equals(history.get(0).vodId) && history.get(0).positionMs == 300000, "history deduplicated & updated");

        // Favorites JSON
        String favRaw = "[]";
        LiteStore.FavoriteEntry fav = new LiteStore.FavoriteEntry();
        fav.siteKey = "cms1";
        fav.siteName = "CMS一";
        fav.vodId = "v1";
        fav.vodName = "仙逆";
        fav.vodRemarks = "更新至50集";
        fav.addedAt = 3000L;

        check(!LiteStore.containsFavorite(favRaw, fav.siteKey, fav.vodId), "initially not favorite");
        favRaw = LiteStore.toggleFavoriteJson(favRaw, fav);
        check(LiteStore.containsFavorite(favRaw, fav.siteKey, fav.vodId), "containsFavorite true after add");
        check(LiteStore.parseFavoritesJson(favRaw).size() == 1, "parseFavoritesJson size 1");
        favRaw = LiteStore.toggleFavoriteJson(favRaw, fav);
        check(!LiteStore.containsFavorite(favRaw, fav.siteKey, fav.vodId), "containsFavorite false after second toggle");
    }

    private static void testEpisodeGroupingAndPlayerHelpers() {
        // Build 220 episodes to verify no 150-episode hard truncation
        StringBuilder raw = new StringBuilder();
        for (int i = 1; i <= 220; i++) {
            if (i > 1) raw.append('#');
            raw.append("第").append(i).append("集$http://127.0.0.1:9/ep").append(i).append(".m3u8");
        }
        List<LiteActivity.EpisodeItem> episodes = LiteActivity.parseLineEpisodes(raw.toString());
        check(episodes.size() == 220, "all 220 episodes preserved without 150 truncation");
        check("第1集".equals(episodes.get(0).name) && "http://127.0.0.1:9/ep220.m3u8".equals(episodes.get(219).url), "episode names and URLs parsed");

        // Time formatting
        check("02:05".equals(LiteActivity.formatTime(125000)), "formatTime MM:SS");
        check("1:05:00".equals(LiteActivity.formatTime(3900000)), "formatTime H:MM:SS");

        // Aspect ratio calculation
        int[] fit = LiteActivity.computeAspectDimensions(1920, 1080, 1920, 800, 0);
        check(fit[0] == 1920 && fit[1] == 800, "aspect mode 0 fit preserves 2.40:1 letterbox");
        int[] fill = LiteActivity.computeAspectDimensions(1920, 1080, 1920, 800, 1);
        check(fill[0] == 1920 && fill[1] == 1080, "aspect mode 1 fill stretches full container");
        int[] r43 = LiteActivity.computeAspectDimensions(1920, 1080, 1920, 1080, 3);
        check(r43[0] == 1440 && r43[1] == 1080, "aspect mode 3 4:3 pillarboxes to 1440x1080");

        // Long-press seek acceleration
        check(LiteActivity.computeLongPressSeekStepMs(0) == 15000, "seek repeat 0 = 15s");
        check(LiteActivity.computeLongPressSeekStepMs(3) == 25000, "seek repeat 3 = 25s");
        check(LiteActivity.computeLongPressSeekStepMs(7) == 45000, "seek repeat 7 = 45s");
        check(LiteActivity.computeLongPressSeekStepMs(12) == 75000, "seek repeat 12 = 75s");
        check(LiteActivity.computeLongPressSeekStepMs(20) == 120000, "seek repeat 20 = 120s");

        // 64-bit Content-Length (>2 GB 4K files on API 14+)
        check(LiteMediaProxy.parseContentLength("8589934592") == 8589934592L, "64-bit Content-Length >2GB parsed");
        check(LiteMediaProxy.parseContentLength(null) == -1L, "null Content-Length returns -1");

        // Consistent play line ordering across detail, in-player line switch, and resume
        JSONObject vod = new JSONObject();
        try {
            vod.put("vod_play_from", "解析源$$$m3u8直连$$$备用直连");
            vod.put("vod_play_url", "第1集$https://example.invalid/page.html$$$第1集$http://127.0.0.1:9/a.m3u8$$$第1集$http://127.0.0.1:9/b.mp4");
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        String[][] ordered = LiteActivity.orderedPlayLines(vod, "备用直连");
        check(ordered[0].length == 3 && ordered[1].length == 3, "orderedPlayLines preserves all 3 lines");
        check("备用直连".equals(ordered[1][0]) && "解析源".equals(ordered[1][1]) && "m3u8直连".equals(ordered[1][2]),
            "orderedPlayLines promotes preferred line to index 0 while preserving remaining order");
    }

    private static void testMediaProxyLoopback() throws Exception {
        final byte[] mp4Bytes = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".getBytes(StandardCharsets.UTF_8);
        final String[] lastUa = new String[1];
        final String[] lastRef = new String[1];

        HttpServer upstream = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final int upstreamPort = upstream.getAddress().getPort();
        upstream.createContext("/video.mp4", new HttpHandler() {
            @Override
            public void handle(HttpExchange ex) {
                try {
                    lastUa[0] = ex.getRequestHeaders().getFirst("User-Agent");
                    lastRef[0] = ex.getRequestHeaders().getFirst("Referer");
                    String range = ex.getRequestHeaders().getFirst("Range");
                    int start = 0;
                    int end = mp4Bytes.length - 1;
                    int code = 200;
                    if (range != null && range.startsWith("bytes=")) {
                        String[] parts = range.substring(6).split("-", 2);
                        start = Integer.parseInt(parts[0]);
                        if (parts.length > 1 && !parts[1].isEmpty()) {
                            end = Integer.parseInt(parts[1]);
                        }
                        code = 206;
                        ex.getResponseHeaders().set("Content-Range", "bytes " + start + "-" + end + "/" + mp4Bytes.length);
                    }
                    byte[] slice = Arrays.copyOfRange(mp4Bytes, start, end + 1);
                    ex.getResponseHeaders().set("Content-Type", "video/mp4");
                    ex.getResponseHeaders().set("Accept-Ranges", "bytes");
                    ex.sendResponseHeaders(code, slice.length);
                    OutputStream os = ex.getResponseBody();
                    os.write(slice);
                    os.close();
                } catch (Exception ignored) {
                }
            }
        });
        upstream.createContext("/hls/master.m3u8", new HttpHandler() {
            @Override
            public void handle(HttpExchange ex) {
                try {
                    String m3u8 = "#EXTM3U\n"
                        + "#EXT-X-VERSION:3\n"
                        + "#EXT-X-KEY:METHOD=AES-128,URI=\"enc.key\"\n"
                        + "#EXTINF:4.0,\n"
                        + "seg001.ts\n";
                    byte[] body = m3u8.getBytes(StandardCharsets.UTF_8);
                    ex.getResponseHeaders().set("Content-Type", "application/vnd.apple.mpegurl");
                    ex.sendResponseHeaders(200, body.length);
                    OutputStream os = ex.getResponseBody();
                    os.write(body);
                    os.close();
                } catch (Exception ignored) {
                }
            }
        });
        upstream.start();

        try {
            Map<String, String> customHeaders = new HashMap<String, String>();
            customHeaders.put("User-Agent", "ProxyTestUA/1.0");
            customHeaders.put("Referer", "http://origin.example/");

            // 1. Proxy URL wrapping in MODE_ALWAYS or HTTPS
            String rawMp4Url = "http://127.0.0.1:" + upstreamPort + "/video.mp4";
            String proxiedMp4 = LiteMediaProxy.wrapIfNeeded(rawMp4Url, customHeaders, LiteMediaProxy.MODE_ALWAYS, false);
            check(proxiedMp4.startsWith("http://127.0.0.1:") && !proxiedMp4.equals(rawMp4Url), "wrapIfNeeded MODE_ALWAYS wraps local URL");
            String autoHttps = LiteMediaProxy.wrapIfNeeded("https://example.invalid/live.m3u8", null, LiteMediaProxy.MODE_AUTO, false);
            check(autoHttps.startsWith("http://127.0.0.1:"), "wrapIfNeeded MODE_AUTO wraps remote HTTPS URL");

            // 2. Invalid token returns 403 Forbidden
            String badTokenUrl = "http://127.0.0.1:" + LiteMediaProxy.get().port() + "/wrong-token/stream.mp4?u=abc";
            check(readHttp(badTokenUrl, null).startsWith("403:"), "proxy rejects wrong token with 403");

            // 3. Byte-range request through proxy forwards Range & custom headers
            String rangeResp = readHttp(proxiedMp4, "bytes=10-15");
            check("206:ABCDEF".equals(rangeResp), "proxy forwards 206 Partial Content byte range");
            check("ProxyTestUA/1.0".equals(lastUa[0]) && "http://origin.example/".equals(lastRef[0]), "proxy injects custom UA and Referer");

            // 4. M3U8 playlist rewriting rewrites relative segments and EXT-X-KEY URI to loopback proxy
            String rawM3u8Url = "http://127.0.0.1:" + upstreamPort + "/hls/master.m3u8";
            String proxiedM3u8 = LiteMediaProxy.get().buildProxyUrl(rawM3u8Url, customHeaders);
            String m3u8Resp = readHttp(proxiedM3u8, null);
            check(m3u8Resp.startsWith("200:"), "proxy serves rewritten M3U8");
            check(m3u8Resp.contains("URI=\"http://127.0.0.1:") && m3u8Resp.contains("/stream.ts?u="), "proxy rewrites EXT-X-KEY URI and relative .ts segment URLs");
            // 5. ConfigServer CSRF cross-origin POST rejection vs same-origin acceptance
            final String[] importedUrl = new String[1];
            ConfigServer cs = new ConfigServer(new ConfigServer.Importer() {
                @Override
                public void apply(String address) {
                    importedUrl[0] = address;
                }
            });
            try {
                byte[] postBody = "url=http%3A%2F%2F127.0.0.1%3A9%2Fcfg.json".getBytes(StandardCharsets.UTF_8);
                check(rawPostConfigServer(cs.port(), cs.token, "http://evil.example", postBody).startsWith("HTTP/1.1 403")
                    && importedUrl[0] == null, "ConfigServer rejects cross-origin POST with 403");
                check(rawPostConfigServer(cs.port(), cs.token, "http://127.0.0.1:" + cs.port(), postBody).startsWith("HTTP/1.1 200")
                    && "http://127.0.0.1:9/cfg.json".equals(importedUrl[0]), "ConfigServer accepts same-origin POST");
            } finally {
                cs.close();
            }
        } finally {
            LiteMediaProxy.get().close();
            upstream.stop(0);
        }
    }

    private static void testLiteSyncV2AndLanServer() throws Exception {
        // 1. Multi-subscription preservation + private stripping + history/fav tombstones
        String mixedRaw =
                "{\"sites\":["
                        + "{\"key\":\"open_cms\",\"name\":\"公开影视\",\"type\":1,\"api\":\"http://127.0.0.1:9/open\"},"
                        + "{\"key\":\"priv_cms\",\"name\":\"隐私影视\",\"type\":1,\"api\":\"http://127.0.0.1:9/priv\",\"isPrivate\":true}"
                        + "]}";
        String secondRaw =
                "{\"sites\":[{\"key\":\"backup_cms\",\"name\":\"备用影视\",\"type\":1,\"api\":\"http://127.0.0.1:9/backup\"}]}";

        JSONObject remoteFromDesktop =
                new JSONObject()
                        .put("schema", LiteSync.SCHEMA)
                        .put("version", 2)
                        .put("updated", 5000L)
                        .put(
                                "watch_history",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("site", "open_cms")
                                                        .put("id", "v100")
                                                        .put("title", "流浪地球")
                                                        .put("episode", "正片")
                                                        .put("position", 360000)
                                                        .put("duration", 7200000)
                                                        .put("updated", 4500L))
                                        .put(
                                                new JSONObject()
                                                        .put("site", "open_cms")
                                                        .put("id", "v_del")
                                                        .put("title", "已删影片")
                                                        .put("position", 10000)
                                                        .put("duration", 60000)
                                                        .put("updated", 1200L)))
                        .put(
                                "favorites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("site", "open_cms")
                                                        .put("id", "f200")
                                                        .put("title", "大闹天宫")
                                                        .put("updated", 4200L)))
                        .put(
                                "subscriptions",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("name", "桌面端订阅一")
                                                        .put("url", "https://one.example/sub.json")
                                                        .put("rawContent", mixedRaw)
                                                        .put("enabled", true)
                                                        .put("updatedAt", 4000L))
                                        .put(
                                                new JSONObject()
                                                        .put("name", "桌面端订阅二")
                                                        .put("url", "https://two.example/sub.json")
                                                        .put("rawContent", secondRaw)
                                                        .put("enabled", true)
                                                        .put("updatedAt", 4100L)));

        LiteSync.Tombstones localTombs = LiteSync.Tombstones.read("");
        localTombs.putMax("hist:open_cms\nv_del", 3000L);

        LiteSync.MergeResult mergedOnFreshLite =
                LiteSync.merge(
                        "[]",
                        "[]",
                        localTombs.json(),
                        null,
                        true,
                        remoteFromDesktop.toString(),
                        5500L);

        check(mergedOnFreshLite.historyCount == 1, "LiteSync filters tombstoned history");
        check(mergedOnFreshLite.favoriteCount == 1, "LiteSync imports remote favorite");
        check(
                mergedOnFreshLite.activeSubscription != null
                        && "桌面端订阅一".equals(mergedOnFreshLite.activeSubscription.name)
                        && !mergedOnFreshLite.activeSubscription.rawContent.contains("priv_cms"),
                "LiteSync adopts first public subscription on fresh box and strips private sites");
        JSONObject outPayload = new JSONObject(mergedOnFreshLite.payloadJson);
        check(
                outPayload.getJSONArray("subscriptions").length() == 2,
                "LiteSync preserves all secondary remote subscriptions without dropping them");

        // 2. Opt-out of subscription sync preserves remote subscriptions without adopting locally
        LiteSync.MergeResult optOutRes =
                LiteSync.merge("[]", "[]", "", null, false, remoteFromDesktop.toString(), 5600L);
        check(
                optOutRes.activeSubscription == null
                        && new JSONObject(optOutRes.payloadJson)
                                        .getJSONArray("subscriptions")
                                        .length()
                                == 2,
                "LiteSync syncSubs=false preserves remote subscriptions without mutating local");

        // 3. ConfigServer LAN /<token>/sync bidirectional sync
        final String[] boxHist = new String[] {mergedOnFreshLite.historyJson};
        final String[] boxFav = new String[] {mergedOnFreshLite.favoritesJson};
        final String[] boxTomb = new String[] {mergedOnFreshLite.tombstonesJson};
        final LiteSync.LocalSubscription boxSub = mergedOnFreshLite.activeSubscription;

        ConfigServer syncServer =
                new ConfigServer(
                        new ConfigServer.Importer() {
                            @Override
                            public void apply(String address) {}
                        },
                        new ConfigServer.SyncHandler() {
                            @Override
                            public String sync(String remoteJson) {
                                if (remoteJson == null) {
                                    return LiteSync.exportPayload(
                                            boxHist[0], boxFav[0], boxTomb[0], boxSub, true, 6000L);
                                }
                                LiteSync.MergeResult m =
                                        LiteSync.merge(
                                                boxHist[0],
                                                boxFav[0],
                                                boxTomb[0],
                                                boxSub,
                                                true,
                                                remoteJson,
                                                6000L);
                                boxHist[0] = m.historyJson;
                                boxFav[0] = m.favoritesJson;
                                boxTomb[0] = m.tombstonesJson;
                                return m.payloadJson;
                            }
                        });
        try {
            String lanUrl = "http://127.0.0.1:" + syncServer.port() + "/" + syncServer.token;
            LiteStore.FavoriteEntry clientNewFav = new LiteStore.FavoriteEntry();
            clientNewFav.siteKey = "open_cms";
            clientNewFav.vodId = "f999";
            clientNewFav.vodName = "手机新收藏";
            clientNewFav.addedAt = 5900L;
            final String clientFavRaw = LiteStore.toggleFavoriteJson("[]", clientNewFav);

            LiteSync.MergeResult lanClientRes =
                    LiteSync.syncLanPeer(
                            lanUrl,
                            new LiteSync.LanPeerCallback() {
                                @Override
                                public String exportLocalPayload() {
                                    return LiteSync.exportPayload(
                                            "[]", clientFavRaw, "", null, true, 5950L);
                                }

                                @Override
                                public LiteSync.MergeResult applyMergedPayload(
                                        String remoteMergedPayloadJson) {
                                    return LiteSync.merge(
                                            "[]",
                                            clientFavRaw,
                                            "",
                                            null,
                                            true,
                                            remoteMergedPayloadJson,
                                            6100L);
                                }
                            });
            check(
                    lanClientRes.historyCount == 1
                            && lanClientRes.favoriteCount == 2
                            && lanClientRes.subscriptionCount == 1,
                    "LiteSync LAN peer receives box history + subscription and merges favorites");
            check(
                    LiteStore.parseFavoritesJson(boxFav[0]).size() == 2,
                    "ConfigServer receiver simultaneously receives peer's new favorite");
        } finally {
            syncServer.close();
        }

        // 4. WebDAV MKCOL + PUT + GET roundtrip
        final java.util.Set<String> dirs =
                java.util.Collections.synchronizedSet(new java.util.HashSet<String>());
        final java.util.List<String> mkcolSeq =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        final java.util.List<String> auth401Mkcol =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        final java.util.List<String> auth403Mkcol =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        final byte[][] davData = new byte[1][];
        HttpServer dav = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        dav.createContext(
                "/",
                new HttpHandler() {
                    @Override
                    public void handle(HttpExchange ex) throws java.io.IOException {
                        try {
                            String m = ex.getRequestMethod();
                            String p = ex.getRequestURI().getPath();
                            if (p.startsWith("/auth401/")) {
                                if ("MKCOL".equalsIgnoreCase(m)) {
                                    String norm = p.endsWith("/") ? p : (p + "/");
                                    auth401Mkcol.add(norm);
                                    ex.sendResponseHeaders(401, -1);
                                    return;
                                }
                                if ("PUT".equalsIgnoreCase(m)) {
                                    ex.sendResponseHeaders(404, -1);
                                    return;
                                }
                            }
                            if (p.startsWith("/auth403/")) {
                                if ("MKCOL".equalsIgnoreCase(m)) {
                                    String norm = p.endsWith("/") ? p : (p + "/");
                                    auth403Mkcol.add(norm);
                                    ex.sendResponseHeaders(403, -1);
                                    return;
                                }
                                if ("PUT".equalsIgnoreCase(m)) {
                                    ex.sendResponseHeaders(404, -1);
                                    return;
                                }
                            }
                            if (p.startsWith("/forbidden")) {
                                if ("MKCOL".equalsIgnoreCase(m)) {
                                    ex.sendResponseHeaders(403, -1);
                                    return;
                                }
                                if ("PUT".equalsIgnoreCase(m)) {
                                    ex.sendResponseHeaders(404, -1);
                                    return;
                                }
                            }
                            if ("MKCOL".equalsIgnoreCase(m)) {
                                String norm = p.endsWith("/") ? p : (p + "/");
                                dirs.add(norm);
                                mkcolSeq.add(norm);
                                ex.sendResponseHeaders(201, -1);
                                return;
                            }
                            if ("GET".equalsIgnoreCase(m)) {
                                if (davData[0] == null) {
                                    ex.sendResponseHeaders(404, -1);
                                } else {
                                    ex.sendResponseHeaders(200, davData[0].length);
                                    OutputStream os = ex.getResponseBody();
                                    os.write(davData[0]);
                                    os.close();
                                }
                                return;
                            }
                            if ("PUT".equalsIgnoreCase(m)) {
                                ByteArrayOutputStream bos = new ByteArrayOutputStream();
                                InputStream is = ex.getRequestBody();
                                byte[] buf = new byte[2048];
                                int n;
                                while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
                                if ("/dav/marco-movie-sync.json".equals(p)
                                        || "/marco-movie-sync.json".equals(p)) {
                                    ex.sendResponseHeaders(404, -1);
                                    return;
                                }
                                if (!dirs.contains("/dav/") || !dirs.contains("/dav/lite/")) {
                                    ex.sendResponseHeaders(409, -1);
                                    return;
                                }
                                davData[0] = bos.toByteArray();
                                ex.sendResponseHeaders(201, -1);
                                return;
                            }
                            ex.sendResponseHeaders(405, -1);
                        } finally {
                            ex.close();
                        }
                    }
                });
        dav.start();
        try {
            int port = dav.getAddress().getPort();
            String davUrl = "http://127.0.0.1:" + port + "/dav/lite/";
            LiteSync.MergeResult pushed =
                    LiteSync.syncWebdav(
                            davUrl,
                            "liteuser",
                            "litepass",
                            new LiteSync.MergeCallback() {
                                @Override
                                public LiteSync.MergeResult merge(String remote) {
                                    return LiteSync.merge(
                                            boxHist[0],
                                            boxFav[0],
                                            boxTomb[0],
                                            boxSub,
                                            true,
                                            remote,
                                            7000L);
                                }
                            });
            check(
                    pushed.historyCount == 1 && pushed.favoriteCount == 2 && davData[0] != null,
                    "LiteSync WebDAV MKCOL creates nested collections and uploads v2 JSON");
            check(
                    mkcolSeq.contains("/dav/") && mkcolSeq.contains("/dav/lite/"),
                    "LiteSync MKCOL creates nested collections in hierarchy");
            check(
                    mkcolSeq.indexOf("/dav/") < mkcolSeq.indexOf("/dav/lite/"),
                    "LiteSync MKCOL sequence creates parent before child");

            try {
                LiteSync.syncWebdav(
                        "http://127.0.0.1:" + port + "/forbidden/",
                        "liteuser",
                        "litepass",
                        new LiteSync.MergeCallback() {
                            @Override
                            public LiteSync.MergeResult merge(String remote) {
                                return LiteSync.merge(
                                        boxHist[0],
                                        boxFav[0],
                                        boxTomb[0],
                                        boxSub,
                                        true,
                                        remote,
                                        7000L);
                            }
                        });
                check(false, "LiteSync persistent write failure must throw IOException");
            } catch (java.io.IOException expected) {
                check(
                        expected.getMessage().contains("目标文件夹不存在或不可写。坚果云请在地址后加一个文件夹名"),
                        "LiteSync WebDAV 404/409 write failure provides actionable diagnostic message");
            }

            // 5. MKCOL halts recursion immediately on HTTP 401
            try {
                LiteSync.syncWebdav(
                        "http://127.0.0.1:" + port + "/auth401/sub1/sub2/",
                        "liteuser",
                        "litepass",
                        new LiteSync.MergeCallback() {
                            @Override
                            public LiteSync.MergeResult merge(String remote) {
                                return LiteSync.merge(
                                        boxHist[0],
                                        boxFav[0],
                                        boxTomb[0],
                                        boxSub,
                                        true,
                                        remote,
                                        7000L);
                            }
                        });
                check(false, "LiteSync MKCOL 401 failure must throw IOException on PUT");
            } catch (java.io.IOException expected) {
                // Expected PUT failure
            }
            check(
                    auth401Mkcol.size() == 1 && "/auth401/".equals(auth401Mkcol.get(0)),
                    "LiteSync MKCOL halts recursion immediately on HTTP 401 without requesting child directories");
            check(
                    !auth401Mkcol.contains("/auth401/sub1/")
                            && !auth401Mkcol.contains("/auth401/sub1/sub2/"),
                    "LiteSync does not issue child MKCOL requests on 401");

            // 6. MKCOL halts recursion immediately on HTTP 403
            try {
                LiteSync.syncWebdav(
                        "http://127.0.0.1:" + port + "/auth403/sub1/sub2/",
                        "liteuser",
                        "litepass",
                        new LiteSync.MergeCallback() {
                            @Override
                            public LiteSync.MergeResult merge(String remote) {
                                return LiteSync.merge(
                                        boxHist[0],
                                        boxFav[0],
                                        boxTomb[0],
                                        boxSub,
                                        true,
                                        remote,
                                        7000L);
                            }
                        });
                check(false, "LiteSync MKCOL 403 failure must throw IOException on PUT");
            } catch (java.io.IOException expected) {
                // Expected PUT failure
            }
            check(
                    auth403Mkcol.size() == 1 && "/auth403/".equals(auth403Mkcol.get(0)),
                    "LiteSync MKCOL halts recursion immediately on HTTP 403 without requesting child directories");
            check(
                    !auth403Mkcol.contains("/auth403/sub1/")
                            && !auth403Mkcol.contains("/auth403/sub1/sub2/"),
                    "LiteSync does not issue child MKCOL requests on 403");
        } finally {
            dav.stop(0);
        }
    }

    private static void testStoreCorruptionProtection() {
        LiteStore.setHistoryCorrupted(false);
        String corrupt = "{malformed json...";
        check(
                LiteStore.isMalformedHistory(corrupt),
                "LiteStore isMalformedHistory returns true for invalid JSON");
        check(
                !LiteStore.isMalformedHistory("[]"),
                "LiteStore isMalformedHistory returns false for empty array");
        check(
                !LiteStore.isMalformedHistory("[{\"vodId\":\"1\"}]"),
                "LiteStore isMalformedHistory returns false for valid array");

        List<LiteStore.HistoryEntry> parsed = LiteStore.parseHistoryJson(corrupt);
        check(parsed.isEmpty(), "LiteStore parseHistoryJson returns empty list on malformed JSON");
        check(
                LiteStore.isHistoryCorrupted(),
                "LiteStore enters corruption lockout on parse failure");

        LiteStore.HistoryEntry entry = new LiteStore.HistoryEntry();
        entry.vodId = "v_new";
        entry.vodName = "新剧";
        String saved = LiteStore.recordHistoryJson(corrupt, entry);
        check(
                corrupt.equals(saved),
                "LiteStore recordHistoryJson refuses destructive overwrite when corrupted");

        LiteStore.setHistoryCorrupted(false);
    }

    private static void testLiteSyncEtagAndConcurrency() throws Exception {
        HttpServer dav = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final java.util.concurrent.atomic.AtomicReference<String> lastIfMatch =
                new java.util.concurrent.atomic.AtomicReference<>();
        final java.util.concurrent.atomic.AtomicReference<String> lastIfNoneMatch =
                new java.util.concurrent.atomic.AtomicReference<>();
        final java.util.concurrent.atomic.AtomicReference<String> serverEtag =
                new java.util.concurrent.atomic.AtomicReference<>("\"etag-lite-1\"");
        final java.util.concurrent.atomic.AtomicReference<byte[]> storedPayload =
                new java.util.concurrent.atomic.AtomicReference<>(null);
        final java.util.concurrent.atomic.AtomicInteger putCount =
                new java.util.concurrent.atomic.AtomicInteger();
        final java.util.concurrent.atomic.AtomicBoolean return412Once =
                new java.util.concurrent.atomic.AtomicBoolean();
        final java.util.concurrent.atomic.AtomicBoolean always412 =
                new java.util.concurrent.atomic.AtomicBoolean();
        final java.util.concurrent.atomic.AtomicBoolean omitEtagOnGet =
                new java.util.concurrent.atomic.AtomicBoolean();

        dav.createContext(
                "/lite-etag/MarcoMovie/",
                ex -> {
                    try {
                        String method = ex.getRequestMethod();
                        if ("GET".equals(method)) {
                            byte[] body = storedPayload.get();
                            if (body == null) {
                                ex.sendResponseHeaders(404, -1);
                                return;
                            }
                            if (!omitEtagOnGet.get()) {
                                ex.getResponseHeaders().set("ETag", serverEtag.get());
                            }
                            ex.getResponseHeaders()
                                    .set("Content-Type", "application/json; charset=utf-8");
                            ex.sendResponseHeaders(200, body.length);
                            try (OutputStream out = ex.getResponseBody()) {
                                out.write(body);
                            }
                            return;
                        }
                        if ("MKCOL".equals(method)) {
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        if ("PUT".equals(method)) {
                            putCount.incrementAndGet();
                            lastIfMatch.set(ex.getRequestHeaders().getFirst("If-Match"));
                            lastIfNoneMatch.set(ex.getRequestHeaders().getFirst("If-None-Match"));

                            if (always412.get()) {
                                ex.sendResponseHeaders(412, -1);
                                return;
                            }
                            if (return412Once.compareAndSet(true, false)) {
                                serverEtag.set("\"etag-lite-2\"");
                                storedPayload.set(
                                        "{\"schema\":\"marco-movie-sync\",\"version\":2,\"updated\":8000,\"watch_history\":[]}"
                                                .getBytes(StandardCharsets.UTF_8));
                                ex.sendResponseHeaders(412, -1);
                                return;
                            }

                            ByteArrayOutputStream bos = new ByteArrayOutputStream();
                            byte[] buf = new byte[2048];
                            int n;
                            InputStream in = ex.getRequestBody();
                            while ((n = in.read(buf)) != -1) {
                                bos.write(buf, 0, n);
                            }
                            storedPayload.set(bos.toByteArray());
                            ex.getResponseHeaders().set("ETag", serverEtag.get());
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });
        dav.start();
        try {
            int port = dav.getAddress().getPort();
            String url = "http://127.0.0.1:" + port + "/lite-etag/MarcoMovie/";

            // 1. Initial push when file absent on GET (404) -> sends If-None-Match: *
            storedPayload.set(null);
            LiteSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            LiteSync.merge(
                                    "[]",
                                    "[]",
                                    "",
                                    null,
                                    false,
                                    remote,
                                    1000L));
            check(
                    "*".equals(lastIfNoneMatch.get()) && lastIfMatch.get() == null,
                    "LiteSync WebDAV sends If-None-Match: * on initial push when file absent");

            // 2. Subsequent sync with existing file and ETag -> sends If-Match: <etag>
            lastIfNoneMatch.set(null);
            lastIfMatch.set(null);
            LiteSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            LiteSync.merge(
                                    "[]",
                                    "[]",
                                    "",
                                    null,
                                    false,
                                    remote,
                                    2000L));
            check(
                    lastIfNoneMatch.get() == null && "\"etag-lite-1\"".equals(lastIfMatch.get()),
                    "LiteSync WebDAV sends If-Match: <etag> when remote file exists");

            // 3. Fallback to unconditioned PUT when server GET omits ETag
            omitEtagOnGet.set(true);
            lastIfNoneMatch.set(null);
            lastIfMatch.set(null);
            LiteSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            LiteSync.merge(
                                    "[]",
                                    "[]",
                                    "",
                                    null,
                                    false,
                                    remote,
                                    3000L));
            check(
                    lastIfNoneMatch.get() == null && lastIfMatch.get() == null,
                    "LiteSync WebDAV falls back gracefully to unconditioned PUT when ETag omitted");
            omitEtagOnGet.set(false);

            // 4. HTTP 412 triggers retry loop and succeeds with updated ETag
            return412Once.set(true);
            putCount.set(0);
            LiteSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            LiteSync.merge(
                                    "[]",
                                    "[]",
                                    "",
                                    null,
                                    false,
                                    remote,
                                    4000L));
            check(
                    putCount.get() == 2 && "\"etag-lite-2\"".equals(lastIfMatch.get()),
                    "LiteSync WebDAV 412 triggers retry loop, re-fetches updated ETag and succeeds");

            // 5. Persistent HTTP 412 exhausts retries and throws actionable IOException
            always412.set(true);
            try {
                LiteSync.syncWebdav(
                        url,
                        "alice",
                        "pass",
                        remote ->
                                LiteSync.merge(
                                        "[]",
                                        "[]",
                                        "",
                                        null,
                                        false,
                                        remote,
                                        5000L));
                check(false, "LiteSync persistent 412 must throw IOException");
            } catch (java.io.IOException expected) {
                check(
                        expected.getMessage().contains("HTTP 412")
                                && expected.getMessage().contains("写入冲突"),
                        "LiteSync WebDAV persistent 412 conflict provides actionable diagnostic message");
            }
        } finally {
            dav.stop(0);
        }
    }

    private static void testConfigPullAndCapabilityStatus() throws Exception {
        // 1. 7 unified capability statuses and Chinese reasons
        LiteCatalog.Site sOk = new LiteCatalog.Site();
        sOk.type = 1;
        sOk.api = "http://127.0.0.1:9/api";
        check(
                LiteCatalog.Site.STATUS_OK.equals(sOk.capabilityStatus())
                        && "正常可用".equals(sOk.limitation()),
                "Lite capability status ok");

        LiteCatalog.Site sJar = new LiteCatalog.Site();
        sJar.type = 3;
        sJar.api = "http://127.0.0.1:9/spider.jar";
        check(
                LiteCatalog.Site.STATUS_NEEDS_JAR.equals(sJar.capabilityStatus())
                        && "此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持".equals(sJar.limitation()),
                "Lite capability status needs-jar");

        LiteCatalog.Site sType = new LiteCatalog.Site();
        sType.type = 99;
        sType.api = "http://127.0.0.1:9/unknown";
        check(
                LiteCatalog.Site.STATUS_UNSUPPORTED_TYPE.equals(sType.capabilityStatus())
                        && "暂不支持此类型来源，已保留在列表中".equals(sType.limitation()),
                "Lite capability status unsupported-type");

        LiteCatalog.Site sNetdisk = new LiteCatalog.Site();
        sNetdisk.type = 3;
        sNetdisk.api = "csp_Ali";
        sNetdisk.name = "阿里网盘";
        check(
                LiteCatalog.Site.STATUS_ADAPTER_MISSING.equals(sNetdisk.capabilityStatus())
                        && "此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路".equals(sNetdisk.limitation()),
                "Lite capability status adapter-missing");

        LiteCatalog.Site sExt = new LiteCatalog.Site();
        sExt.type = 1;
        sExt.api = "http://127.0.0.1:9/api";
        sExt.extTooLarge = true;
        check(
                LiteCatalog.Site.STATUS_EXT_TOO_LARGE.equals(sExt.capabilityStatus())
                        && "扩展参数超过大小上限，无法加载".equals(sExt.limitation()),
                "Lite capability status ext-too-large");

        LiteCatalog.Site sUrl = new LiteCatalog.Site();
        sUrl.type = 1;
        sUrl.api = "custom://invalid";
        check(
                LiteCatalog.Site.STATUS_CUSTOM_SITE_URL.equals(sUrl.capabilityStatus())
                        && "此来源不是可直接请求的 HTTP(S) CMS".equals(sUrl.limitation()),
                "Lite capability status custom-site-url");

        LiteCatalog.Site sParse = new LiteCatalog.Site();
        sParse.type = 1;
        sParse.api = "http://127.0.0.1:9/api";
        sParse.requiresParser = true;
        sParse.playUrl = "";
        check(
                LiteCatalog.Site.STATUS_PARSER_REQUIRED.equals(sParse.capabilityStatus())
                        && "需要解析器，当前环境缺少可用解析配置".equals(sParse.limitation()),
                "Lite capability status parser-required");

        // 2. decodeConfig HTML detection
        boolean directHtmlCaught = false;
        try {
            LiteCatalog.decodeConfig("<!DOCTYPE html><html><body>Login Required</body></html>");
        } catch (java.io.IOException e) {
            directHtmlCaught =
                    e.getMessage() != null
                            && e.getMessage().contains("地址返回的是网页而不是配置（可能需要登录或被拦截）");
        }
        check(directHtmlCaught, "Lite decodeConfig rejects HTML with diagnostic error");

        // 3. decodeText gzip bomb protection
        ByteArrayOutputStream bombStream = new ByteArrayOutputStream();
        try (GZIPOutputStream gzos = new GZIPOutputStream(bombStream)) {
            byte[] chunk = new byte[65536];
            for (int i = 0; i < 40; i++) {
                gzos.write(chunk);
            }
        }
        byte[] bombBytes = bombStream.toByteArray();
        boolean bombCaught = false;
        try {
            LiteCatalog.decodeText(bombBytes);
        } catch (java.io.IOException e) {
            bombCaught = e.getMessage() != null && e.getMessage().contains("解压后内容超过大小限制");
        }
        check(bombCaught, "Lite decodeText rejects gzip bomb exceeding 2MB");

        // 4. Cross-domain header stripping unit check
        Map<String, String> headersToStrip = new HashMap<String, String>();
        headersToStrip.put("Authorization", "Basic dXNlcjpwYXNz");
        headersToStrip.put("Cookie", "session=123");
        headersToStrip.put("Custom-Header", "kept");
        Map<String, String> stripped =
                LiteCatalog.inheritedHeaders(
                        new URL("http://a.com/"), new URL("http://b.com/"), headersToStrip);
        check(
                !stripped.containsKey("Authorization")
                        && !stripped.containsKey("Cookie")
                        && "kept".equals(stripped.get("Custom-Header")),
                "Lite inheritedHeaders strips auth and cookie across domains");

        // 5. HttpServer tests
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        int port = server.getAddress().getPort();
        String baseUrl = "http://127.0.0.1:" + port;

        server.createContext(
                "/gzip-ok",
                exchange -> {
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    try (GZIPOutputStream gz = new GZIPOutputStream(out)) {
                        gz.write(
                                "{\"sites\":[{\"key\":\"gz-site\",\"name\":\"GZ Site\",\"type\":1,\"api\":\"http://127.0.0.1:9/api\"}]}"
                                        .getBytes(StandardCharsets.UTF_8));
                    }
                    byte[] gzipped = out.toByteArray();
                    exchange.getResponseHeaders().set("Content-Encoding", "gzip");
                    exchange.sendResponseHeaders(200, gzipped.length);
                    try (OutputStream os = exchange.getResponseBody()) {
                        os.write(gzipped);
                    }
                });

        server.createContext(
                "/gzip-bomb-http",
                exchange -> {
                    exchange.getResponseHeaders().set("Content-Encoding", "gzip");
                    exchange.sendResponseHeaders(200, bombBytes.length);
                    try (OutputStream os = exchange.getResponseBody()) {
                        os.write(bombBytes);
                    }
                });

        server.createContext(
                "/dual-ua",
                exchange -> {
                    String ua = exchange.getRequestHeaders().getFirst("User-Agent");
                    if (LiteCatalog.USER_AGENT.equals(ua)) {
                        byte[] resp =
                                "<html><body>403 Forbidden</body></html>"
                                        .getBytes(StandardCharsets.UTF_8);
                        exchange.sendResponseHeaders(403, resp.length);
                        try (OutputStream os = exchange.getResponseBody()) {
                            os.write(resp);
                        }
                    } else if (LiteCatalog.SAFARI_USER_AGENT.equals(ua)) {
                        byte[] resp =
                                "{\"sites\":[{\"key\":\"dual-site\",\"name\":\"Dual Site\",\"type\":1,\"api\":\"http://127.0.0.1:9/api\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        exchange.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = exchange.getResponseBody()) {
                            os.write(resp);
                        }
                    }
                });

        server.createContext(
                "/html-blocked",
                exchange -> {
                    byte[] resp =
                            "<!DOCTYPE html><html><body>Captcha Required</body></html>"
                                    .getBytes(StandardCharsets.UTF_8);
                    exchange.getResponseHeaders().set("Content-Type", "text/html; charset=utf-8");
                    exchange.sendResponseHeaders(200, resp.length);
                    try (OutputStream os = exchange.getResponseBody()) {
                        os.write(resp);
                    }
                });

        server.createContext(
                "/redirect-step1",
                exchange -> {
                    exchange.getResponseHeaders().set("Location", baseUrl + "/redirect-step2");
                    exchange.getResponseHeaders()
                            .set("Set-Cookie", "session_id=secret456; Path=/");
                    exchange.sendResponseHeaders(302, -1);
                });

        server.createContext(
                "/redirect-step2",
                exchange -> {
                    String cookie = exchange.getRequestHeaders().getFirst("Cookie");
                    if (cookie != null && cookie.contains("session_id=secret456")) {
                        byte[] resp =
                                "{\"sites\":[{\"key\":\"cookie-site\",\"name\":\"Cookie Site\",\"type\":1,\"api\":\"http://127.0.0.1:9/api\"}]}"
                                        .getBytes(StandardCharsets.UTF_8);
                        exchange.sendResponseHeaders(200, resp.length);
                        try (OutputStream os = exchange.getResponseBody()) {
                            os.write(resp);
                        }
                    } else {
                        byte[] err = "missing cookie".getBytes(StandardCharsets.UTF_8);
                        exchange.sendResponseHeaders(500, err.length);
                        try (OutputStream os = exchange.getResponseBody()) {
                            os.write(err);
                        }
                    }
                });

        server.createContext(
                "/status-201",
                exchange -> {
                    byte[] resp =
                            "{\"sites\":[{\"key\":\"created-site\",\"name\":\"Created Site\",\"type\":1,\"api\":\"http://127.0.0.1:9/api\"}]}"
                                    .getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(201, resp.length);
                    try (OutputStream os = exchange.getResponseBody()) {
                        os.write(resp);
                    }
                });

        server.start();
        try {
            String gzResult = LiteCatalog.fetch(baseUrl + "/gzip-ok", null);
            check(gzResult.contains("\"key\":\"gz-site\""), "Lite fetch decompresses gzip response");

            boolean httpBombCaught = false;
            try {
                LiteCatalog.fetch(baseUrl + "/gzip-bomb-http", null);
            } catch (java.io.IOException e) {
                httpBombCaught =
                        e.getMessage() != null && e.getMessage().contains("超过大小限制");
            }
            check(httpBombCaught, "Lite fetch rejects gzip bomb exceeding MAX_BYTES");

            String dualResult = LiteCatalog.fetch(baseUrl + "/dual-ua", null);
            check(
                    dualResult.contains("\"key\":\"dual-site\""),
                    "Lite fetch retries with Safari UA on error/HTML");

            boolean httpHtmlCaught = false;
            try {
                LiteCatalog.fetch(baseUrl + "/html-blocked", null);
            } catch (java.io.IOException e) {
                httpHtmlCaught =
                        e.getMessage() != null
                                && e.getMessage().contains("地址返回的是网页而不是配置（可能需要登录或被拦截）");
            }
            check(httpHtmlCaught, "Lite fetch throws diagnostic error on persistent HTML");

            String cookieFetch = LiteCatalog.fetch(baseUrl + "/redirect-step1", null);
            check(
                    cookieFetch.contains("\"key\":\"cookie-site\""),
                    "Lite fetch preserves cookies across same-domain redirects");

            String status201Result = LiteCatalog.fetch(baseUrl + "/status-201", null);
            check(status201Result.contains("\"key\":\"created-site\""), "Lite fetch accepts 201 status code");
        } finally {
            server.stop(0);
        }
    }
}

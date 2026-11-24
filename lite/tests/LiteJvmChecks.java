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
        testRound2LiteWebdavRobustness();
        testSiteOverridesSearchQrAndCast();
        int baselineChecks = checks;
        test059ViewingAndSourceRegressions();
        int addedChecks = checks - baselineChecks;
        System.out.println(
                "PASS "
                        + checks
                        + " TV Lite JVM checks ("
                        + baselineChecks
                        + " baseline + "
                        + addedChecks
                        + " new 0.5.9 regressions; 0 failed, 0 skipped)");
    }

    private static void testResolveWebdavFileUrlMatrix() throws Exception {
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("dav.jianguoyun.com")),
                "LiteSync Jianguoyun bare host resolves to /dav/MarcoMovie/marco-movie-sync.json");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/")),
                "LiteSync Jianguoyun root slash resolves to /dav/MarcoMovie/marco-movie-sync.json");
        check(
                "http://nas.test:5006/My%20Movies/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("http://nas.test:5006/My Movies/")),
                "LiteSync URL with spaces encodes space as %20");
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
                "https://nas.test:5006/marco-movie-sync.json"
                        .equals(LiteSync.resolveWebdavFileUrl("https://nas.test:5006/")),
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

        // 8. Direct MacCMS VOD JSON / XML endpoint import (#55)
        String directCmsJson = "{\"code\":1,\"msg\":\"数据列表\",\"page\":1,\"pagecount\":10,\"list\":[{\"vod_id\":1001,\"vod_name\":\"测试片\"}]}";
        List<LiteCatalog.Site> directJsonSites = LiteCatalog.parse(directCmsJson, "http://vod.example/api.php/provide/vod/?ac=list&pg=1");
        check(directJsonSites.size() == 1 && directJsonSites.get(0).type == 1 && directJsonSites.get(0).supported && "http://vod.example/api.php/provide/vod/".equals(directJsonSites.get(0).api), "Lite imports direct MacCMS JSON VOD endpoint (#55)");
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
            // 6. ConfigServer LAN peer validation
            check(ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("127.0.0.1")), "ConfigServer allows loopback 127.0.0.1");
            check(ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("::1")), "ConfigServer allows IPv6 loopback ::1");
            check(ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("192.168.1.100")), "ConfigServer allows 192.168.x.x");
            check(ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("10.10.10.10")), "ConfigServer allows 10.x.x.x");
            check(ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("172.20.0.1")), "ConfigServer allows 172.16-31.x.x");
            check(ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("100.64.0.5")), "ConfigServer allows CGNAT/Tailscale 100.64-127.x.x");
            check(!ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("8.8.8.8")), "ConfigServer blocks WAN 8.8.8.8");
            check(!ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("1.1.1.1")), "ConfigServer blocks WAN 1.1.1.1");
            check(!ConfigServer.isAllowedLanPeer(java.net.InetAddress.getByName("203.0.113.1")), "ConfigServer blocks WAN 203.0.113.1");

            // 7. ConfigServer session timeout & dynamic exit
            ConfigServer expiredCs = new ConfigServer(
                    new ConfigServer.Importer() {
                        @Override
                        public void apply(String address) {}
                    },
                    null,
                    System.currentTimeMillis() - ConfigServer.SESSION_LIFETIME_MS - 1000L);
            try {
                check(expiredCs.isExpired(), "ConfigServer isExpired returns true when past lifetime");
            } finally {
                expiredCs.close();
            }
            ConfigServer expiringCs = new ConfigServer(
                    new ConfigServer.Importer() {
                        @Override
                        public void apply(String address) {}
                    },
                    null,
                    System.currentTimeMillis() - ConfigServer.SESSION_LIFETIME_MS + 150L);
            try {
                check(!expiringCs.isExpired(), "ConfigServer not expired initially");
                Thread.sleep(250L);
                check(expiringCs.isExpired(), "ConfigServer isExpired becomes true after lifetime");
            } finally {
                expiringCs.close();
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
                check(expected.getMessage() != null, "LiteSync MKCOL 401 PUT failure includes message");
            }
            check(
                    auth401Mkcol.size() == 1 && "/auth401/".equals(auth401Mkcol.get(0)),
                    "LiteSync MKCOL halts recursion immediately on HTTP 401 without requesting child directories");
            check(
                    !auth401Mkcol.contains("/auth401/sub1/")
                            && !auth401Mkcol.contains("/auth401/sub1/sub2/"),
                    "LiteSync does not issue child MKCOL requests on 401");

            // 6. MKCOL continues past HTTP 403 to child collections (only 401 stops per M-W2)
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
                check(false, "LiteSync persistent PUT 404 failure must throw IOException");
            } catch (java.io.IOException expected) {
                check(expected.getMessage() != null, "LiteSync /auth403/ PUT failure includes message");
            }
            check(
                    auth403Mkcol.size() == 3 && "/auth403/".equals(auth403Mkcol.get(0)),
                    "LiteSync MKCOL continues past HTTP 403 on parent collection");
            check(
                    auth403Mkcol.contains("/auth403/sub1/")
                            && auth403Mkcol.contains("/auth403/sub1/sub2/"),
                    "LiteSync issues child MKCOL requests when parent returns 403");
        } finally {
            dav.stop(0);
        }
    }

    private static android.content.SharedPreferences createMemoryPrefs(
            final Map<String, Object> backing,
            final java.util.concurrent.atomic.AtomicInteger commitCalls,
            final java.util.concurrent.atomic.AtomicInteger applyCalls) {
        final android.content.SharedPreferences.Editor editor =
                (android.content.SharedPreferences.Editor)
                        java.lang.reflect.Proxy.newProxyInstance(
                                LiteJvmChecks.class.getClassLoader(),
                                new Class<?>[] {android.content.SharedPreferences.Editor.class},
                                (proxy, method, args) -> {
                                    String m = method.getName();
                                    if ("putString".equals(m)
                                            || "putBoolean".equals(m)
                                            || "putInt".equals(m)
                                            || "putLong".equals(m)
                                            || "putFloat".equals(m)) {
                                        if (args[1] == null) backing.remove((String) args[0]);
                                        else backing.put((String) args[0], args[1]);
                                        return proxy;
                                    }
                                    if ("remove".equals(m)) {
                                        backing.remove((String) args[0]);
                                        return proxy;
                                    }
                                    if ("clear".equals(m)) {
                                        backing.clear();
                                        return proxy;
                                    }
                                    if ("commit".equals(m)) {
                                        commitCalls.incrementAndGet();
                                        return Boolean.TRUE;
                                    }
                                    if ("apply".equals(m)) {
                                        applyCalls.incrementAndGet();
                                        return null;
                                    }
                                    return proxy;
                                });
        return (android.content.SharedPreferences)
                java.lang.reflect.Proxy.newProxyInstance(
                        LiteJvmChecks.class.getClassLoader(),
                        new Class<?>[] {android.content.SharedPreferences.class},
                        (proxy, method, args) -> {
                            String m = method.getName();
                            if ("edit".equals(m)) return editor;
                            if ("getAll".equals(m)) return new HashMap<String, Object>(backing);
                            if ("contains".equals(m)) return backing.containsKey(args[0]);
                            if ("getString".equals(m)) {
                                Object v = backing.get(args[0]);
                                return v instanceof String ? (String) v : (String) args[1];
                            }
                            if ("getBoolean".equals(m)) {
                                Object v = backing.get(args[0]);
                                return v instanceof Boolean ? (Boolean) v : (Boolean) args[1];
                            }
                            return null;
                        });
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

        Map<String, Object> backing = new HashMap<String, Object>();
        backing.put("watch_history_v1", corrupt);
        java.util.concurrent.atomic.AtomicInteger commitCalls =
                new java.util.concurrent.atomic.AtomicInteger();
        java.util.concurrent.atomic.AtomicInteger applyCalls =
                new java.util.concurrent.atomic.AtomicInteger();
        android.content.SharedPreferences sp =
                createMemoryPrefs(backing, commitCalls, applyCalls);

        // 10 consecutive reads of corrupted history must produce ONLY ONE backup and avoid commit()
        for (int i = 0; i < 10; i++) {
            List<LiteStore.HistoryEntry> parsed = LiteStore.getHistory(sp);
            check(
                    parsed.isEmpty(),
                    "LiteStore getHistory returns empty list on malformed JSON #" + i);
        }
        int backupKeys = 0;
        for (String key : backing.keySet()) {
            if (key.startsWith("watch_history_corrupt_")) backupKeys++;
        }
        check(
                backupKeys == 1,
                "LiteStore 10 consecutive reads of corrupted history produce only 1 backup");
        check(
                commitCalls.get() == 0 && applyCalls.get() == 1,
                "LiteStore corruption backup uses apply() instead of blocking commit()");
        check(
                LiteStore.isHistoryCorrupted(sp)
                        && sp.getBoolean(LiteStore.KEY_HISTORY_CORRUPTED, false),
                "LiteStore sets both memory flag and watch_history_corrupted pref");

        LiteStore.HistoryEntry entry = new LiteStore.HistoryEntry();
        entry.siteKey = "cms1";
        entry.vodId = "v_new";
        entry.vodName = "新剧";
        LiteStore.saveHistory(sp, entry);
        check(
                corrupt.equals(sp.getString("watch_history_v1", "")),
                "LiteStore saveHistory refuses destructive overwrite when corrupted");

        // Clearing history clears both flag and pref while preserving backup, then saveHistory works
        LiteStore.clearHistory(sp);
        int backupKeysAfterClear = 0;
        for (String key : backing.keySet()) {
            if (key.startsWith("watch_history_corrupt_")) backupKeysAfterClear++;
        }
        check(
                !LiteStore.isHistoryCorrupted()
                        && !sp.getBoolean(LiteStore.KEY_HISTORY_CORRUPTED, false)
                        && backupKeysAfterClear == 1,
                "LiteStore clearHistory clears flag and pref while preserving corrupt backup");

        LiteStore.saveHistory(sp, entry);
        List<LiteStore.HistoryEntry> afterClear = LiteStore.getHistory(sp);
        check(
                afterClear.size() == 1 && "v_new".equals(afterClear.get(0).vodId),
                "LiteStore saveHistory succeeds after clearHistory");

        // Full valid overwrite via setHistoryRaw also clears both flag and pref
        backing.put("watch_history_v1", corrupt);
        LiteStore.getHistory(sp);
        check(LiteStore.isHistoryCorrupted(sp), "LiteStore re-enters corruption state");
        LiteStore.setHistoryRaw(sp, "[{\"siteKey\":\"cms1\",\"vodId\":\"v_ok\",\"vodName\":\"恢复剧集\"}]");
        check(
                !LiteStore.isHistoryCorrupted()
                        && !sp.getBoolean(LiteStore.KEY_HISTORY_CORRUPTED, false)
                        && LiteStore.getHistory(sp).size() == 1,
                "LiteStore setHistoryRaw with valid JSON clears flag and pref");
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
        List<LiteCatalog.Site> explicitJarCms =
                LiteCatalog.parse(
                        "{\"sites\":["
                                + "{\"key\":\"cms_jar_1\",\"name\":\"CMS1\",\"type\":1,\"api\":\"http://127.0.0.1:9/vod\",\"jar\":\"./spider.jar\"},"
                                + "{\"key\":\"cms_jar_0\",\"name\":\"CMS0\",\"type\":0,\"api\":\"http://127.0.0.1:9/xml\",\"jar\":\"./spider.jar\"},"
                                + "{\"key\":\"jar_only\",\"name\":\"JarOnly\",\"api\":\"csp_Demo\",\"jar\":\"./spider.jar\"}"
                                + "]}",
                        "http://127.0.0.1:9/cfg.json");
        check(
                LiteCatalog.Site.STATUS_OK.equals(sParse.capabilityStatus())
                        && "需要解析器，当前环境缺少可用解析配置".equals(sParse.playbackHint())
                        && LiteCatalog.Site.STATUS_OK.equals(
                                explicitJarCms.get(0).capabilityStatus())
                        && explicitJarCms.get(0).supported
                        && LiteCatalog.Site.STATUS_OK.equals(
                                explicitJarCms.get(1).capabilityStatus())
                        && explicitJarCms.get(1).supported
                        && LiteCatalog.Site.STATUS_NEEDS_JAR.equals(
                                explicitJarCms.get(2).capabilityStatus())
                        && !explicitJarCms.get(2).supported,
                "Lite capability status parser hint and explicit CMS jar alignment");
        verifyRound2LiteFixes();

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
                        new URL("http://a.test/"), new URL("http://b.test/"), headersToStrip);
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

        final java.util.concurrent.atomic.AtomicInteger dualUaHits =
                new java.util.concurrent.atomic.AtomicInteger();
        server.createContext(
                "/dual-ua",
                exchange -> {
                    dualUaHits.incrementAndGet();
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

        final java.util.concurrent.atomic.AtomicInteger htmlBlockedHits =
                new java.util.concurrent.atomic.AtomicInteger();
        server.createContext(
                "/html-blocked",
                exchange -> {
                    htmlBlockedHits.incrementAndGet();
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
                "/json-as-text-html",
                exchange -> {
                    byte[] resp =
                            "{\"sites\":[{\"key\":\"html-ct\",\"name\":\"HtmlCT\",\"type\":1,\"api\":\"http://127.0.0.1:9/api\"}]}"
                                    .getBytes(StandardCharsets.UTF_8);
                    exchange.getResponseHeaders().set("Content-Type", "text/html; charset=utf-8");
                    exchange.sendResponseHeaders(200, resp.length);
                    try (OutputStream os = exchange.getResponseBody()) {
                        os.write(resp);
                    }
                });

        final java.util.concurrent.atomic.AtomicInteger err500Hits =
                new java.util.concurrent.atomic.AtomicInteger();
        server.createContext(
                "/err-500",
                exchange -> {
                    err500Hits.incrementAndGet();
                    byte[] resp = "internal error".getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(500, resp.length);
                    try (OutputStream os = exchange.getResponseBody()) {
                        os.write(resp);
                    }
                });

        server.createContext(
                "/echo-custom-header",
                exchange -> {
                    String custom = exchange.getRequestHeaders().getFirst("X-Custom-Token");
                    byte[] resp = (custom == null ? "" : custom).getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, resp.length);
                    try (OutputStream os = exchange.getResponseBody()) {
                        os.write(resp);
                    }
                });

        for (int hop = 1; hop <= 6; hop++) {
            final int currentHop = hop;
            server.createContext(
                    "/hop-" + currentHop,
                    exchange -> {
                        String nextTarget =
                                currentHop < 6 ? "/hop-" + (currentHop + 1) : "/hop-final";
                        exchange.getResponseHeaders().set("Location", baseUrl + nextTarget);
                        exchange.sendResponseHeaders(302, -1);
                        exchange.close();
                    });
        }
        server.createContext(
                "/hop-final",
                exchange -> {
                    byte[] resp = "hop-ok".getBytes(StandardCharsets.UTF_8);
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

            // Generic fetch() is single-request and accepts text/html responses
            dualUaHits.set(0);
            boolean singleReq403Failed = false;
            try {
                LiteCatalog.fetch(baseUrl + "/dual-ua", null);
            } catch (java.io.IOException expected) {
                singleReq403Failed = true;
            }
            check(
                    singleReq403Failed && dualUaHits.get() == 1,
                    "Lite generic fetch makes only one request without Safari UA retry");

            htmlBlockedHits.set(0);
            String rawHtmlAllowed = LiteCatalog.fetch(baseUrl + "/html-blocked", null);
            check(
                    rawHtmlAllowed.contains("Captcha Required") && htmlBlockedHits.get() == 1,
                    "Lite generic fetch accepts text/html responses in a single request");

            // fetchConfig() handles Safari UA fallback on 403/HTML and rejects HTML body
            dualUaHits.set(0);
            String dualResult = LiteCatalog.fetchConfig(baseUrl + "/dual-ua");
            check(
                    dualResult.contains("\"key\":\"dual-site\"") && dualUaHits.get() == 2,
                    "Lite fetchConfig retries with Safari UA on HTTP 403");

            String htmlCtJson = LiteCatalog.fetchConfig(baseUrl + "/json-as-text-html");
            check(
                    htmlCtJson.contains("\"key\":\"html-ct\""),
                    "Lite fetchConfig checks content prefix rather than Content-Type text/html");

            err500Hits.set(0);
            boolean err500Caught = false;
            try {
                LiteCatalog.fetchConfig(baseUrl + "/err-500");
            } catch (java.io.IOException expected) {
                err500Caught = true;
            }
            check(
                    err500Caught && err500Hits.get() == 1,
                    "Lite fetchConfig does not retry Safari UA on HTTP 500");

            boolean httpHtmlCaught = false;
            try {
                LiteCatalog.fetchConfig(baseUrl + "/html-blocked");
            } catch (java.io.IOException e) {
                httpHtmlCaught =
                        e.getMessage() != null
                                && e.getMessage().contains("地址返回的是网页而不是配置（可能需要登录或被拦截）");
            }
            check(httpHtmlCaught, "Lite fetchConfig throws diagnostic error on persistent HTML");

            // Redirect limit restored to 5 hops (hop-2 -> hop-3 -> hop-4 -> hop-5 -> hop-6 -> hop-final = 5 hops)
            check(
                    "hop-ok".equals(LiteCatalog.fetch(baseUrl + "/hop-2", null)),
                    "Lite fetch allows 5 redirect hops");
            boolean sixHopsRejected = false;
            try {
                LiteCatalog.fetch(baseUrl + "/hop-1", null);
            } catch (java.io.IOException expected) {
                sixHopsRejected = true;
            }
            check(sixHopsRejected, "Lite fetch rejects 6 redirect hops");

            // Full site header pass-through (custom headers preserved and sent)
            List<LiteCatalog.Site> customHeaderSites =
                    LiteCatalog.parse(
                            "{\"sites\":[{\"key\":\"ch\",\"name\":\"CH\",\"type\":1,\"api\":\""
                                    + baseUrl
                                    + "/echo-custom-header\",\"headers\":{\"X-Custom-Token\":\"alpha-99\"}}]}",
                            baseUrl);
            check(
                    "alpha-99".equals(customHeaderSites.get(0).headers.get("X-Custom-Token"))
                            && "alpha-99"
                                    .equals(
                                            LiteCatalog.fetch(
                                                    customHeaderSites.get(0).api,
                                                    customHeaderSites.get(0).headers)),
                    "Lite preserves and transmits custom site request headers");

            // C2 alignment in LiteCatalog.parse
            List<LiteCatalog.Site> xmlHostSites =
                    LiteCatalog.parse(
                            "{\"sites\":[{\"key\":\"xm\",\"name\":\"XM\",\"api\":\"https://xmlcms.test/api.php/provide/vod\"}]}",
                            "https://xmlcms.test/config.json");
            check(
                    xmlHostSites.get(0).type == 1 && xmlHostSites.get(0).supported,
                    "Lite C2 checks URL path only and keeps xml host as type 1 JSON");

            for (String scriptApi :
                    new String[] {
                        "https://site.example/a.js",
                        "https://site.example/a.mjs",
                        "https://site.example/a.py",
                        "https://site.example/a.jar",
                        "csp_Custom"
                    }) {
                List<LiteCatalog.Site> scriptSites =
                        LiteCatalog.parse(
                                "{\"sites\":[{\"key\":\"sc\",\"name\":\"SC\",\"api\":\""
                                        + scriptApi
                                        + "\"}]}",
                                "https://site.example/config.json");
                check(
                        scriptSites.get(0).type == -1 && !scriptSites.get(0).supported,
                        "Lite C2 does not treat script/jar api without type as CMS: " + scriptApi);
            }
            List<LiteCatalog.Site> withJarSites =
                    LiteCatalog.parse(
                            "{\"sites\":[{\"key\":\"wj\",\"name\":\"WJ\",\"api\":\"https://site.example/api/vod\",\"jar\":\"./custom.jar\"}]}",
                            "https://site.example/config.json");
            check(
                    withJarSites.get(0).type == -1 && !withJarSites.get(0).supported,
                    "Lite C2 does not treat missing-type site with jar field as CMS");

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

    private static void require(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAILED: " + label);
    }

    private static void verifyRound2LiteFixes() throws Exception {
        // 6b: resetHistoryKeepBackups skips tombstone recording when history is corrupted
        LiteStore.setHistoryCorrupted(false);
        Map<String, Object> storeMap = new HashMap<String, Object>();
        Map<String, Object> appMap = new HashMap<String, Object>();
        storeMap.put("watch_history_v1", "{corrupt-watch-history");
        java.util.concurrent.atomic.AtomicInteger commits =
                new java.util.concurrent.atomic.AtomicInteger();
        java.util.concurrent.atomic.AtomicInteger applies =
                new java.util.concurrent.atomic.AtomicInteger();
        android.content.SharedPreferences storePrefs =
                createMemoryPrefs(storeMap, commits, applies);
        android.content.SharedPreferences appPrefs = createMemoryPrefs(appMap, commits, applies);

        LiteStore.lastWarnMessage = null;
        require(LiteStore.getHistory(storePrefs).isEmpty(), "6b/6c: corrupted getHistory empty");
        require(
                LiteStore.lastWarnMessage != null
                        && LiteStore.lastWarnMessage.contains("History JSON corrupted"),
                "6c: parseHistoryJson logs warning instead of swallowing");
        require(LiteStore.isHistoryCorrupted(storePrefs), "6b: storePrefs marked corrupted");

        final java.util.concurrent.atomic.AtomicInteger tombstoneRuns =
                new java.util.concurrent.atomic.AtomicInteger();
        boolean recordedOnCorrupted =
                LiteStore.resetHistoryKeepBackups(
                        storePrefs, appPrefs, () -> tombstoneRuns.incrementAndGet());
        require(!recordedOnCorrupted, "6b: resetHistoryKeepBackups skips sync when corrupted");
        require(
                tombstoneRuns.get() == 0,
                "6b: resetHistoryKeepBackups must NOT write tombstones when history was corrupted");
        require(
                !LiteStore.isHistoryCorrupted(storePrefs)
                        && !storePrefs.getBoolean(LiteStore.KEY_HISTORY_CORRUPTED, false)
                        && "[]".equals(storePrefs.getString("watch_history_v1", "")),
                "6b: resetHistoryKeepBackups clears corrupted flag and resets history to []");
        boolean keptCorruptBackup = false;
        for (String key : storeMap.keySet()) {
            if (key.startsWith("watch_history_corrupt_")) keptCorruptBackup = true;
        }
        require(keptCorruptBackup, "6b: resetHistoryKeepBackups preserves corrupt backup key");

        // Healthy history reset DOES invoke tombstone callback
        LiteStore.HistoryEntry valid = new LiteStore.HistoryEntry();
        valid.siteKey = "s1";
        valid.vodId = "v1";
        valid.vodName = "Movie 1";
        valid.updatedAt = 1000L;
        storeMap.put("watch_history_v1", LiteStore.recordHistoryJson("[]", valid));
        boolean recordedOnHealthy =
                LiteStore.resetHistoryKeepBackups(
                        storePrefs, appPrefs, () -> tombstoneRuns.incrementAndGet());
        require(
                recordedOnHealthy && tombstoneRuns.get() == 1,
                "6b: healthy history reset invokes tombstone callback exactly once");

        // 6c: setHistoryRaw logs warning on malformed payload without setting historyCorrupted
        LiteStore.setHistoryCorrupted(false);
        storeMap.put(LiteStore.KEY_HISTORY_CORRUPTED, Boolean.FALSE);
        LiteStore.lastWarnMessage = null;
        LiteStore.setHistoryRaw(storePrefs, "[malformed_unquoted_item]");
        require(
                LiteStore.lastWarnMessage != null
                        && LiteStore.lastWarnMessage.contains(
                                "Rejected malformed history overwrite")
                        && !LiteStore.isHistoryCorrupted(storePrefs),
                "6c/6a: setHistoryRaw logs warning and rejects malformed payload without corrupting flag");
        LiteStore.setHistoryCorrupted(false);
    }

    private static final class FakeLiteContext extends android.content.Context {
        private final FakeLiteContext appContext;
        private final Map<String, Map<String, Object>> prefFiles;
        final java.util.concurrent.atomic.AtomicBoolean appContextRequested =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        final java.util.concurrent.atomic.AtomicBoolean prefsReadOnThis =
                new java.util.concurrent.atomic.AtomicBoolean(false);

        FakeLiteContext(
                FakeLiteContext appContext, Map<String, Map<String, Object>> sharedPrefFiles) {
            this.appContext = appContext;
            this.prefFiles = sharedPrefFiles;
        }

        @Override
        public android.content.Context getApplicationContext() {
            appContextRequested.set(true);
            return appContext != null ? appContext : this;
        }

        @Override
        public String getPackageName() {
            return "com.pilipala.marcomovie.lite.test";
        }

        @Override
        public synchronized android.content.SharedPreferences getSharedPreferences(
                String name, int mode) {
            prefsReadOnThis.set(true);
            Map<String, Object> backing = prefFiles.get(name);
            if (backing == null) {
                backing =
                        java.util.Collections.synchronizedMap(
                                new java.util.HashMap<String, Object>());
                prefFiles.put(name, backing);
            }
            return createMemoryPrefs(
                    backing,
                    new java.util.concurrent.atomic.AtomicInteger(),
                    new java.util.concurrent.atomic.AtomicInteger());
        }
    }

    private static void testRound2LiteWebdavRobustness() throws Exception {
        LiteSync.clearNoConditionalWriteHostsForTest();

        // 1-3: M-W2 baseCollectionDepth checks
        String jgyFile = LiteSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/");
        check(
                LiteSync.baseCollectionDepth(
                                "https://dav.jianguoyun.com/dav/", java.net.URI.create(jgyFile))
                        == 1,
                "M-W2 Lite Jianguoyun /dav/ base skips /dav/");
        check(
                LiteSync.baseCollectionDepth("dav.jianguoyun.com", java.net.URI.create(jgyFile))
                        == 1,
                "M-W2 Lite Jianguoyun host-only skips /dav/");
        String ncFile =
                LiteSync.resolveWebdavFileUrl(
                        "https://nc.example/remote.php/dav/files/alice/MarcoMovie/");
        check(
                LiteSync.baseCollectionDepth(
                                "https://nc.example/remote.php/dav/files/alice/",
                                java.net.URI.create(ncFile))
                        == 4,
                "M-W2 Lite Nextcloud base skips /remote.php/dav/files/<user>/");

        HttpServer r2Server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        HttpServer cond412Server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final java.util.concurrent.atomic.AtomicReference<String> weakIfMatch =
                new java.util.concurrent.atomic.AtomicReference<String>();
        final java.util.concurrent.atomic.AtomicReference<String> weakIfNoneMatch =
                new java.util.concurrent.atomic.AtomicReference<String>();
        final java.util.concurrent.atomic.AtomicReference<byte[]> weakStore =
                new java.util.concurrent.atomic.AtomicReference<byte[]>(
                        "{\"schema\":\"marco-movie-sync\",\"version\":2,\"updated\":100,\"watch_history\":[]}"
                                .getBytes(StandardCharsets.UTF_8));
        final java.util.List<String> rejectInmLog =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        final java.util.concurrent.atomic.AtomicReference<byte[]> rejectInmStore =
                new java.util.concurrent.atomic.AtomicReference<byte[]>(null);
        final java.util.List<String> cond412Log =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        final java.util.concurrent.atomic.AtomicReference<byte[]> cond412Store =
                new java.util.concurrent.atomic.AtomicReference<byte[]>(
                        "{\"schema\":\"marco-movie-sync\",\"version\":2,\"updated\":200,\"watch_history\":[]}"
                                .getBytes(StandardCharsets.UTF_8));
        final java.util.List<String> dav403Mkcols =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        final java.util.Set<String> dav403Created =
                java.util.Collections.synchronizedSet(new java.util.HashSet<String>());
        final java.util.concurrent.atomic.AtomicReference<byte[]> dav403Store =
                new java.util.concurrent.atomic.AtomicReference<byte[]>(null);
        final java.util.concurrent.atomic.AtomicReference<byte[]> spaceStore =
                new java.util.concurrent.atomic.AtomicReference<byte[]>(null);
        final java.util.concurrent.atomic.AtomicReference<byte[]> exitStore =
                new java.util.concurrent.atomic.AtomicReference<byte[]>(null);

        r2Server.createContext(
                "/weak/",
                ex -> {
                    try {
                        if ("GET".equals(ex.getRequestMethod())) {
                            byte[] b = weakStore.get();
                            ex.getResponseHeaders().set("ETag", "W/\"lite-weak-1\"");
                            ex.sendResponseHeaders(200, b.length);
                            OutputStream os = ex.getResponseBody();
                            os.write(b);
                            os.close();
                            return;
                        }
                        if ("PUT".equals(ex.getRequestMethod())) {
                            weakIfMatch.set(ex.getRequestHeaders().getFirst("If-Match"));
                            weakIfNoneMatch.set(ex.getRequestHeaders().getFirst("If-None-Match"));
                            ByteArrayOutputStream bos = new ByteArrayOutputStream();
                            InputStream is = ex.getRequestBody();
                            byte[] buf = new byte[1024];
                            int n;
                            while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
                            weakStore.set(bos.toByteArray());
                            ex.sendResponseHeaders(204, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/reject-inm/",
                ex -> {
                    try {
                        if ("GET".equals(ex.getRequestMethod())) {
                            byte[] b = rejectInmStore.get();
                            if (b == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.sendResponseHeaders(200, b.length);
                                OutputStream os = ex.getResponseBody();
                                os.write(b);
                                os.close();
                            }
                            return;
                        }
                        if ("PUT".equals(ex.getRequestMethod())) {
                            String inm = ex.getRequestHeaders().getFirst("If-None-Match");
                            ByteArrayOutputStream bos = new ByteArrayOutputStream();
                            InputStream is = ex.getRequestBody();
                            byte[] buf = new byte[1024];
                            int n;
                            while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
                            rejectInmLog.add("inm=" + inm);
                            if (inm != null) {
                                ex.sendResponseHeaders(501, -1);
                                return;
                            }
                            rejectInmStore.set(bos.toByteArray());
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        cond412Server.createContext(
                "/gzip-etag/",
                ex -> {
                    try {
                        if ("GET".equals(ex.getRequestMethod())) {
                            byte[] b = cond412Store.get();
                            ex.getResponseHeaders().set("ETag", "\"lite-gzip\"");
                            ex.sendResponseHeaders(200, b.length);
                            OutputStream os = ex.getResponseBody();
                            os.write(b);
                            os.close();
                            return;
                        }
                        if ("PUT".equals(ex.getRequestMethod())) {
                            String im = ex.getRequestHeaders().getFirst("If-Match");
                            String inm = ex.getRequestHeaders().getFirst("If-None-Match");
                            ByteArrayOutputStream bos = new ByteArrayOutputStream();
                            InputStream is = ex.getRequestBody();
                            byte[] buf = new byte[1024];
                            int n;
                            while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
                            cond412Log.add("im=" + im + ",inm=" + inm);
                            if (im != null || inm != null) {
                                ex.sendResponseHeaders(412, -1);
                                return;
                            }
                            cond412Store.set(bos.toByteArray());
                            ex.sendResponseHeaders(204, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/dav/",
                ex -> {
                    try {
                        String p = ex.getRequestURI().getPath();
                        String m = ex.getRequestMethod();
                        if ("MKCOL".equalsIgnoreCase(m)) {
                            String norm = p.endsWith("/") ? p : (p + "/");
                            dav403Mkcols.add(norm);
                            byte[] resp =
                                    ("mkcol-body-" + norm).getBytes(StandardCharsets.UTF_8);
                            if ("/dav/".equals(norm)) {
                                ex.sendResponseHeaders(403, resp.length);
                                OutputStream os = ex.getResponseBody();
                                os.write(resp);
                                os.close();
                                return;
                            }
                            dav403Created.add(norm);
                            ex.sendResponseHeaders(201, resp.length);
                            OutputStream os = ex.getResponseBody();
                            os.write(resp);
                            os.close();
                            return;
                        }
                        if ("GET".equalsIgnoreCase(m)) {
                            byte[] b = dav403Store.get();
                            if (b == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.sendResponseHeaders(200, b.length);
                                OutputStream os = ex.getResponseBody();
                                os.write(b);
                                os.close();
                            }
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(m)) {
                            ByteArrayOutputStream bos = new ByteArrayOutputStream();
                            InputStream is = ex.getRequestBody();
                            byte[] buf = new byte[1024];
                            int n;
                            while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
                            if (!dav403Created.contains("/dav/MarcoMovie/")) {
                                ex.sendResponseHeaders(409, -1);
                                return;
                            }
                            dav403Store.set(bos.toByteArray());
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/lite space/",
                ex -> {
                    try {
                        String m = ex.getRequestMethod();
                        if ("MKCOL".equalsIgnoreCase(m)) {
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        if ("GET".equalsIgnoreCase(m)) {
                            byte[] b = spaceStore.get();
                            if (b == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.sendResponseHeaders(200, b.length);
                                OutputStream os = ex.getResponseBody();
                                os.write(b);
                                os.close();
                            }
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(m)) {
                            ByteArrayOutputStream bos = new ByteArrayOutputStream();
                            InputStream is = ex.getRequestBody();
                            byte[] buf = new byte[1024];
                            int n;
                            while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
                            spaceStore.set(bos.toByteArray());
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.createContext(
                "/exit-push/",
                ex -> {
                    try {
                        String m = ex.getRequestMethod();
                        if ("GET".equalsIgnoreCase(m)) {
                            ex.sendResponseHeaders(404, -1);
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(m)) {
                            String auth = ex.getRequestHeaders().getFirst("Authorization");
                            if (!LiteSync.basicAuthHeader("exituser", "exitpass").equals(auth)) {
                                ex.sendResponseHeaders(401, -1);
                                return;
                            }
                            ByteArrayOutputStream bos = new ByteArrayOutputStream();
                            InputStream is = ex.getRequestBody();
                            byte[] buf = new byte[1024];
                            int n;
                            while ((n = is.read(buf)) != -1) bos.write(buf, 0, n);
                            exitStore.set(bos.toByteArray());
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        ex.sendResponseHeaders(405, -1);
                    } finally {
                        ex.close();
                    }
                });

        r2Server.start();
        cond412Server.start();
        try {
            int port = r2Server.getAddress().getPort();
            int port412 = cond412Server.getAddress().getPort();

            // 4. Weak ETag
            LiteSync.clearNoConditionalWriteHostsForTest();
            LiteSync.syncWebdav(
                    "http://127.0.0.1:" + port + "/weak/",
                    "u",
                    "p",
                    remote -> LiteSync.merge("[]", "[]", "", null, false, remote, 1100L));
            check(
                    weakIfMatch.get() == null && weakIfNoneMatch.get() == null,
                    "M-W1 Lite weak ETag does not send If-Match");

            // 5-6. Reject If-None-Match:*
            LiteSync.clearNoConditionalWriteHostsForTest();
            String rejectUrl = "http://127.0.0.1:" + port + "/reject-inm/";
            LiteSync.syncWebdav(
                    rejectUrl,
                    "u",
                    "p",
                    remote -> LiteSync.merge("[]", "[]", "", null, false, remote, 1200L));
            check(
                    rejectInmLog.size() == 2
                            && "inm=*".equals(rejectInmLog.get(0))
                            && "inm=null".equals(rejectInmLog.get(1))
                            && rejectInmStore.get() != null,
                    "M-W1 Lite server rejecting If-None-Match:* retries without header");
            check(
                    LiteSync.isHostMarkedNoConditionalWrite(
                            LiteSync.resolveWebdavFileUrl(rejectUrl)),
                    "M-W1 Lite remembers host after If-None-Match fallback");

            // 7-9. 412 unconditional PUT + host memory
            LiteSync.clearNoConditionalWriteHostsForTest();
            String cond412Url = "http://127.0.0.1:" + port412 + "/gzip-etag/";
            LiteSync.syncWebdav(
                    cond412Url,
                    "u",
                    "p",
                    remote -> LiteSync.merge("[]", "[]", "", null, false, remote, 1300L));
            check(
                    cond412Log.size() == 4 && "im=null,inm=null".equals(cond412Log.get(3)),
                    "M-W1 Lite 412 retries exhausted performs one unconditional PUT");
            check(
                    LiteSync.isHostMarkedNoConditionalWrite(
                            LiteSync.resolveWebdavFileUrl(cond412Url)),
                    "M-W1 Lite remembers host after 412 unconditional PUT");
            cond412Log.clear();
            LiteSync.syncWebdav(
                    cond412Url,
                    "u",
                    "p",
                    remote -> LiteSync.merge("[]", "[]", "", null, false, remote, 1400L));
            check(
                    cond412Log.size() == 1 && "im=null,inm=null".equals(cond412Log.get(0)),
                    "M-W1 Lite subsequent sync skips conditional headers immediately");

            // 10. Mock /dav/ returns 403 -> continues to /dav/MarcoMovie/ (201) and uploads
            LiteSync.clearNoConditionalWriteHostsForTest();
            LiteSync.syncWebdav(
                    "http://127.0.0.1:" + port + "/dav/MarcoMovie/",
                    "u",
                    "p",
                    remote -> LiteSync.merge("[]", "[]", "", null, false, remote, 1500L));
            check(
                    dav403Mkcols.contains("/dav/")
                            && dav403Mkcols.contains("/dav/MarcoMovie/")
                            && dav403Store.get() != null,
                    "M-W2 Lite MKCOL continues past /dav/ returning 403 and creates /dav/MarcoMovie/");

            // 11. URL with spaces syncs end-to-end
            LiteSync.syncWebdav(
                    "http://127.0.0.1:" + port + "/lite space/",
                    "u",
                    "p",
                    remote -> LiteSync.merge("[]", "[]", "", null, false, remote, 1600L));
            check(spaceStore.get() != null, "Lite URL with spaces syncs end-to-end");

            // 12. TLS handshake failure closes raw TCP socket
            final java.net.ServerSocket tlsTrap = new java.net.ServerSocket();
            tlsTrap.bind(new InetSocketAddress("127.0.0.1", 0));
            final java.util.concurrent.atomic.AtomicBoolean peerClosedCleanly =
                    new java.util.concurrent.atomic.AtomicBoolean(false);
            Thread acceptThread =
                    new Thread(
                            () -> {
                                try {
                                    java.net.Socket accepted = tlsTrap.accept();
                                    try {
                                        accepted.setSoTimeout(3000);
                                        int b = accepted.getInputStream().read();
                                        if (b == -1) {
                                            peerClosedCleanly.set(true);
                                        }
                                    } finally {
                                        accepted.close();
                                    }
                                } catch (Exception err) {
                                    System.err.println("TLS trap accept helper closed: " + err);
                                }
                            });
            acceptThread.setDaemon(true);
            acceptThread.start();
            try {
                javax.net.ssl.SSLSocketFactory failingFactory =
                        new javax.net.ssl.SSLSocketFactory() {
                            @Override
                            public String[] getDefaultCipherSuites() {
                                return new String[0];
                            }

                            @Override
                            public String[] getSupportedCipherSuites() {
                                return new String[0];
                            }

                            @Override
                            public java.net.Socket createSocket(
                                    java.net.Socket s, String host, int p, boolean autoClose)
                                    throws java.io.IOException {
                                throw new javax.net.ssl.SSLHandshakeException(
                                        "Simulated handshake failure before SSLSocket wrap");
                            }

                            @Override
                            public java.net.Socket createSocket(String host, int p) {
                                return null;
                            }

                            @Override
                            public java.net.Socket createSocket(
                                    String host, int p, java.net.InetAddress lh, int lp) {
                                return null;
                            }

                            @Override
                            public java.net.Socket createSocket(java.net.InetAddress host, int p) {
                                return null;
                            }

                            @Override
                            public java.net.Socket createSocket(
                                    java.net.InetAddress addr,
                                    int p,
                                    java.net.InetAddress la,
                                    int lp) {
                                return null;
                            }
                        };
                int mkcolErr =
                        LiteSync.sendRawMkcolWithFactory(
                                java.net.URI.create(
                                        "https://127.0.0.1:"
                                                + tlsTrap.getLocalPort()
                                                + "/dav/MarcoMovie/"),
                                "/dav/MarcoMovie/",
                                "",
                                failingFactory);
                acceptThread.join(3000);
                check(
                        mkcolErr == -1 && peerClosedCleanly.get(),
                        "Lite sendRawMkcol closes raw TCP socket when TLS handshake fails");
            } finally {
                tlsTrap.close();
            }

            // 13. M-W4 LiteSync.submitExitPush uses ApplicationContext and survives Activity executor shutdown
            LiteSync.clearNoConditionalWriteHostsForTest();
            Map<String, Map<String, Object>> sharedFiles =
                    java.util.Collections.synchronizedMap(
                            new java.util.HashMap<String, Map<String, Object>>());
            FakeLiteContext appCtx = new FakeLiteContext(null, sharedFiles);
            FakeLiteContext activityCtx = new FakeLiteContext(appCtx, sharedFiles);
            SecureStorage.setWebdavPass(appCtx, "exitpass");
            LiteStore.HistoryEntry he = new LiteStore.HistoryEntry();
            he.siteKey = "s_exit";
            he.siteName = "ExitSite";
            he.vodId = "v_exit";
            he.vodName = "退出推送影片";
            he.positionMs = 45000;
            he.durationMs = 90000;
            he.updatedAt = 9000L;
            LiteStore.saveHistory(appCtx, he);

            Map<String, Object> statusBacking =
                    java.util.Collections.synchronizedMap(new java.util.HashMap<String, Object>());
            android.content.SharedPreferences statusPrefs =
                    createMemoryPrefs(
                            statusBacking,
                            new java.util.concurrent.atomic.AtomicInteger(),
                            new java.util.concurrent.atomic.AtomicInteger());

            java.util.concurrent.ExecutorService simulatedActivityIo =
                    java.util.concurrent.Executors.newSingleThreadExecutor();
            java.util.concurrent.Future<LiteSync.MergeResult> exitFuture =
                    LiteSync.submitExitPush(
                            activityCtx,
                            "http://127.0.0.1:" + port + "/exit-push/",
                            "exituser",
                            false,
                            null,
                            statusPrefs);
            // Simulate LiteActivity.onDestroy() calling io.shutdownNow() immediately
            simulatedActivityIo.shutdownNow();
            LiteSync.MergeResult exitMerged =
                    exitFuture.get(10, java.util.concurrent.TimeUnit.SECONDS);
            check(
                    exitMerged != null
                            && exitMerged.historyCount == 1
                            && activityCtx.appContextRequested.get()
                            && appCtx.prefsReadOnThis.get()
                            && !activityCtx.prefsReadOnThis.get()
                            && exitStore.get() != null
                            && new String(exitStore.get(), StandardCharsets.UTF_8)
                                    .contains("v_exit"),
                    "M-W4 Lite submitExitPush uses ApplicationContext and completes after Activity executor shutdown");
        } finally {
            LiteSync.clearNoConditionalWriteHostsForTest();
            r2Server.stop(0);
            cond412Server.stop(0);
        }
    }

    private static String rawLiteHttp(int port, String rawReq) throws Exception {
        java.net.Socket s = new java.net.Socket("127.0.0.1", port);
        try {
            s.setSoTimeout(5000);
            OutputStream out = s.getOutputStream();
            out.write(rawReq.getBytes(StandardCharsets.UTF_8));
            out.flush();
            InputStream in = s.getInputStream();
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] b = new byte[2048];
            int n;
            while ((n = in.read(b)) != -1) buf.write(b, 0, n);
            return new String(buf.toByteArray(), StandardCharsets.UTF_8);
        } finally {
            s.close();
        }
    }

    private static void testSiteOverridesSearchQrAndCast() throws Exception {
        // 1-5: LiteCatalog manual grouping, field overrides, deletion & refresh survival
        String rawCfg =
                "{\"sites\":["
                        + "{\"key\":\"s_one\",\"name\":\"一线源\",\"type\":1,\"api\":\"https://one.example/api.php/provide/vod/\"},"
                        + "{\"key\":\"s_two\",\"name\":\"二线源\",\"type\":1,\"api\":\"https://two.example/api.php/provide/vod/\"},"
                        + "{\"key\":\"s_jar\",\"name\":\"插件源\",\"type\":3,\"api\":\"csp_DemoJar\"}"
                        + "]}";
        List<LiteCatalog.Site> parsed = LiteCatalog.parse(rawCfg, "https://sub.example/config.json");
        String oneId = parsed.get(0).siteId();
        String twoId = parsed.get(1).siteId();
        String jarId = parsed.get(2).siteId();

        JSONObject saved = new JSONObject();
        JSONObject overrides = new JSONObject();
        overrides.put(oneId, new JSONObject().put("group", "主力分组"));
        overrides.put(
                jarId,
                new JSONObject()
                        .put("name", "已修复CMS")
                        .put("group", "备用分组")
                        .put("api", "https://repaired.example/api.php/provide/vod/")
                        .put("playUrl", "https://parse.example/?u=")
                        .put("ext", "tok=1")
                        .put("searchable", false));
        saved.put("overrides", overrides);
        saved.put("hidden", new JSONArray().put(twoId));
        saved.put("order", new JSONArray().put(jarId).put(oneId));

        List<LiteCatalog.Site> edited = LiteCatalog.applySiteEditsToList(parsed, saved);
        check(edited.size() == 2, "Lite applySiteEditsToList hides deleted site");
        LiteCatalog.Site first = edited.get(0);
        check(
                "已修复CMS".equals(first.name)
                        && "备用分组".equals(first.group)
                        && first.supported
                        && first.type == 1
                        && !first.searchable,
                "Lite applySiteOverride upgrades unsupported JAR site to HTTP CMS");
        check(
                jarId.equals(first.siteId()) && "csp_DemoJar".equals(first.originalApi),
                "Lite siteId remains stable after api override");
        check("主力分组".equals(edited.get(1).group), "Lite custom group applied to remaining site");

        List<LiteCatalog.Site> refreshed =
                LiteCatalog.applySiteEditsToList(
                        LiteCatalog.parse(rawCfg, "https://sub.example/config.json"), saved);
        check(
                refreshed.size() == 2 && "已修复CMS".equals(refreshed.get(0).name),
                "Lite site overrides and deletions survive subscription re-parse");

        // 6-8: ConfigServer /<token>/search mobile QR input + CSRF rejection
        final String[] gotKw = new String[] {""};
        final boolean[] gotSubmit = new boolean[] {false};
        ConfigServer searchSrv =
                new ConfigServer(
                        null,
                        null,
                        new ConfigServer.SearchHandler() {
                            public void onKeyword(String keyword, boolean submitNow) {
                                gotKw[0] = keyword;
                                gotSubmit[0] = submitNow;
                            }
                        });
        try {
            int sp = searchSrv.port();
            String shost = "127.0.0.1:" + sp;
            String spath = "/" + searchSrv.token + "/search";
            String getHtml =
                    rawLiteHttp(sp, "GET " + spath + " HTTP/1.1\r\nHost: " + shost + "\r\n\r\n");
            check(
                    getHtml.startsWith("HTTP/1.1 200 ") && getHtml.contains("手机输入"),
                    "Lite ConfigServer /search renders mobile HTML");

            String csrfBody = "keyword=test&mode=search";
            byte[] csrfBytes = csrfBody.getBytes(StandardCharsets.UTF_8);
            String csrfResp =
                    rawLiteHttp(
                            sp,
                            "POST "
                                    + spath
                                    + " HTTP/1.1\r\nHost: "
                                    + shost
                                    + "\r\nOrigin: https://evil.example\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: "
                                    + csrfBytes.length
                                    + "\r\n\r\n"
                                    + csrfBody);
            check(
                    csrfResp.startsWith("HTTP/1.1 403 "),
                    "Lite ConfigServer /search blocks cross-origin POST");

            String okForm =
                    "keyword="
                            + java.net.URLEncoder.encode("让子弹飞", "UTF-8")
                            + "&mode=search";
            byte[] okBytes = okForm.getBytes(StandardCharsets.UTF_8);
            String okResp =
                    rawLiteHttp(
                            sp,
                            "POST "
                                    + spath
                                    + " HTTP/1.1\r\nHost: "
                                    + shost
                                    + "\r\nOrigin: http://"
                                    + shost
                                    + "\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: "
                                    + okBytes.length
                                    + "\r\n\r\n"
                                    + okForm);
            check(
                    okResp.startsWith("HTTP/1.1 200 ") && "让子弹飞".equals(gotKw[0]) && gotSubmit[0],
                    "Lite ConfigServer /search delivers UTF-8 keyword and submit flag");
        } finally {
            searchSrv.close();
        }

        // 9-14: LiteCast UPnP/DLNA DMR + XXE/CSRF/SSRF guards + QR Web Cast
        final String[] castUrl = new String[] {""};
        final String[] castTitle = new String[] {""};
        final Map<String, String> castHeaders = new HashMap<String, String>();
        LiteCast.Bridge bridge =
                new LiteCast.Bridge() {
                    public void openMedia(String url, String title, Map<String, String> headers) {
                        castUrl[0] = url;
                        castTitle[0] = title;
                        castHeaders.clear();
                        if (headers != null) castHeaders.putAll(headers);
                    }

                    public void resume() {}

                    public void pause() {}

                    public void stop() {}

                    public void seekTo(int posMs) {}

                    public int positionMs() {
                        return 5000;
                    }

                    public int durationMs() {
                        return 120000;
                    }

                    public String transportState() {
                        return "PLAYING";
                    }

                    public int getVolumePercent() {
                        return 75;
                    }

                    public void setVolumePercent(int percent) {}

                    public boolean isMuted() {
                        return false;
                    }

                    public void setMuted(boolean muted) {}

                    public void onStatusChanged(String statusText) {}

                    public void onClosed() {}
                };

        LiteCast cast =
                new LiteCast(
                        "abcdef12-3456-7890-abcd-ef1234567890",
                        "卧室Lite电视",
                        "10.0.0.9",
                        bridge,
                        false,
                        new InetSocketAddress("127.0.0.1", 0));
        try {
            int cp = cast.httpPort();
            String chost = "127.0.0.1:" + cp;

            String devXml =
                    rawLiteHttp(cp, "GET /dlna/device.xml HTTP/1.1\r\nHost: " + chost + "\r\n\r\n");
            check(
                    devXml.startsWith("HTTP/1.1 200 ")
                            && devXml.contains("卧室Lite电视")
                            && devXml.contains("MediaRenderer:1"),
                    "LiteCast serves DLNA device.xml");

            String browserDlna =
                    rawLiteHttp(
                            cp,
                            "GET /dlna/device.xml HTTP/1.1\r\nHost: "
                                    + chost
                                    + "\r\nOrigin: https://evil.example\r\n\r\n");
            check(
                    browserDlna.startsWith("HTTP/1.1 403 "),
                    "LiteCast blocks browser Origin on /dlna/*");

            String xxeBody =
                    "<?xml version=\"1.0\"?><!DOCTYPE a [<!ENTITY e SYSTEM \"file:///etc/hosts\">]><a>&e;</a>";
            byte[] xxeB = xxeBody.getBytes(StandardCharsets.UTF_8);
            String xxeResp =
                    rawLiteHttp(
                            cp,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + chost
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#Stop\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + xxeB.length
                                    + "\r\n\r\n"
                                    + xxeBody);
            check(xxeResp.startsWith("HTTP/1.1 400 "), "LiteCast rejects XXE DOCTYPE SOAP body");

            String ssrfSoap =
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
                            + "<s:Body><u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                            + "<InstanceID>0</InstanceID><CurrentURI>http://127.0.0.1:9999/local.mp4</CurrentURI>"
                            + "<CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>";
            byte[] ssrfB = ssrfSoap.getBytes(StandardCharsets.UTF_8);
            String ssrfResp =
                    rawLiteHttp(
                            cp,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + chost
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + ssrfB.length
                                    + "\r\n\r\n"
                                    + ssrfSoap);
            check(
                    ssrfResp.startsWith("HTTP/1.1 500 "),
                    "LiteCast rejects loopback SSRF URI in SetAVTransportURI");

            String okSoap =
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
                            + "<s:Body><u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
                            + "<InstanceID>0</InstanceID><CurrentURI>https://stream.example/movie.m3u8</CurrentURI>"
                            + "<CurrentURIMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;title&gt;大闹天宫&lt;/title&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData>"
                            + "</u:SetAVTransportURI></s:Body></s:Envelope>";
            byte[] okSoapB = okSoap.getBytes(StandardCharsets.UTF_8);
            String okSoapResp =
                    rawLiteHttp(
                            cp,
                            "POST /dlna/control/AVTransport HTTP/1.1\r\nHost: "
                                    + chost
                                    + "\r\nSOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\""
                                    + "\r\nContent-Type: text/xml\r\nContent-Length: "
                                    + okSoapB.length
                                    + "\r\n\r\n"
                                    + okSoap);
            check(
                    okSoapResp.startsWith("HTTP/1.1 200 ")
                            && "https://stream.example/movie.m3u8".equals(castUrl[0])
                            && "大闹天宫".equals(castTitle[0]),
                    "LiteCast SetAVTransportURI extracts DIDL title and opens media");

            String webJson =
                    new JSONObject()
                            .put("action", "play")
                            .put("url", "https://video.example/ep1.mp4")
                            .put("title", "Lite直投剧集")
                            .put("referer", "https://video.example/")
                            .toString();
            byte[] webB = webJson.getBytes(StandardCharsets.UTF_8);
            String webResp =
                    rawLiteHttp(
                            cp,
                            "POST "
                                    + cast.webCastPath
                                    + "/api HTTP/1.1\r\nHost: "
                                    + chost
                                    + "\r\nOrigin: http://"
                                    + chost
                                    + "\r\nSec-Fetch-Site: same-origin\r\nContent-Type: application/json\r\nContent-Length: "
                                    + webB.length
                                    + "\r\n\r\n"
                                    + webJson);
            check(
                    webResp.startsWith("HTTP/1.1 200 ")
                            && "https://video.example/ep1.mp4".equals(castUrl[0])
                            && "Lite直投剧集".equals(castTitle[0])
                            && "https://video.example/".equals(castHeaders.get("Referer")),
                    "LiteCast QR web API pushes stream URL, title, and Referer");
        } finally {
            cast.close();
        }
    }

    private static void test059ViewingAndSourceRegressions() throws Exception {
        // 1. Item 1: PlaybackSession history isolation & no live/cast auto-advance
        LiteCatalog.Site vodSite = new LiteCatalog.Site();
        vodSite.key = "site_vod";
        vodSite.name = "点播主站";
        vodSite.api = "http://vod.example/api.php/provide/vod/";
        vodSite.type = 1;
        vodSite.supported = true;
        JSONObject vodDetail =
                new JSONObject()
                        .put("vod_id", "v88")
                        .put("vod_name", "长安十二时辰")
                        .put("vod_pic", "http://vod.example/p.jpg");
        List<LiteActivity.EpisodeItem> eps =
                Arrays.asList(
                        new LiteActivity.EpisodeItem("第1集", "http://vod.example/ep1.mp4", 0),
                        new LiteActivity.EpisodeItem("第2集", "http://vod.example/ep2.mp4", 1),
                        new LiteActivity.EpisodeItem("第3集", "http://vod.example/ep3.mp4", 2));
        LiteActivity.PlaybackSession vodSess =
                LiteActivity.PlaybackSession.forVod(
                        1,
                        "http://vod.example/ep2.mp4",
                        "http://vod.example/ep2.mp4",
                        "第2集",
                        null,
                        vodSite,
                        vodDetail,
                        "高清直链",
                        0,
                        1,
                        eps);
        LiteStore.HistoryEntry histEntry =
                LiteActivity.buildHistoryEntryForSession(vodSess, 42000, 120000, 1000L);
        check(
                histEntry != null
                        && "site_vod".equals(histEntry.siteKey)
                        && vodSite.api.equals(histEntry.siteApi)
                        && "v88".equals(histEntry.vodId)
                        && "第2集".equals(histEntry.epName)
                        && histEntry.epIndex == 1
                        && histEntry.positionMs == 42000,
                "Item 1: VOD PlaybackSession builds accurate HistoryEntry");
        LiteStore.HistoryEntry nearEndEntry =
                LiteActivity.buildHistoryEntryForSession(vodSess, 118000, 120000, 2000L);
        check(
                nearEndEntry != null && nearEndEntry.positionMs == 0,
                "Item 1: VOD session >=95% resets resume position to 0");
        LiteCatalog.LiveGroup liveGrp = new LiteCatalog.LiveGroup();
        liveGrp.name = "央视";
        LiteActivity.PlaybackSession liveSess =
                LiteActivity.PlaybackSession.forLive(
                        2,
                        "http://live.example/cctv1.m3u8",
                        "CCTV-1",
                        null,
                        liveGrp,
                        0,
                        0,
                        0,
                        0,
                        null);
        LiteActivity.PlaybackSession castSess =
                LiteActivity.PlaybackSession.forCast(
                        3, "http://cast.example/clip.mp4", "投屏片段", null);
        check(
                LiteActivity.buildHistoryEntryForSession(liveSess, 15000, 60000, 3000L) == null
                        && LiteActivity.buildHistoryEntryForSession(castSess, 15000, 60000, 3000L)
                                == null,
                "Item 1: Live and Cast sessions never overwrite VOD history");
        check(
                LiteActivity.shouldAutoAdvanceNextEpisode(vodSess)
                        && !LiteActivity.shouldAutoAdvanceNextEpisode(liveSess)
                        && !LiteActivity.shouldAutoAdvanceNextEpisode(castSess),
                "Item 1: Only VOD with remaining episodes auto-advances; live/cast never do");
        LiteActivity.PlaybackSession lastEpSess =
                LiteActivity.PlaybackSession.forVod(
                        4,
                        "http://vod.example/ep3.mp4",
                        "http://vod.example/ep3.mp4",
                        "第3集",
                        null,
                        vodSite,
                        vodDetail,
                        "高清直链",
                        0,
                        2,
                        eps);
        check(
                !LiteActivity.shouldAutoAdvanceNextEpisode(lastEpSess),
                "Item 1: Final VOD episode does not auto-advance");

        // 2. Item 3: Subscription replacement rebinds existing site to new API/headers or selects new site
        LiteCatalog.Site oldA = new LiteCatalog.Site();
        oldA.key = "siteA";
        oldA.originalKey = "siteA";
        oldA.name = "站点A";
        oldA.api = "http://old-a.example/api";
        oldA.originalApi = oldA.api;
        oldA.type = 1;
        oldA.supported = true;
        LiteCatalog.Site updatedA = new LiteCatalog.Site();
        updatedA.key = "siteA";
        updatedA.originalKey = "siteA";
        updatedA.name = "站点A新版";
        updatedA.api = "http://new-a.example/api";
        updatedA.originalApi = updatedA.api;
        updatedA.headers.put("X-Env", "v2");
        updatedA.type = 1;
        updatedA.supported = true;
        LiteCatalog.Site siteB = new LiteCatalog.Site();
        siteB.key = "siteB";
        siteB.originalKey = "siteB";
        siteB.name = "站点B";
        siteB.api = "http://b.example/api";
        siteB.originalApi = siteB.api;
        siteB.type = 1;
        siteB.supported = true;
        LiteCatalog.Site reboundA =
                LiteCatalog.resolveSelectedSite(
                        Arrays.asList(updatedA, siteB), oldA, "siteA", oldA.api);
        check(
                reboundA == updatedA
                        && "http://new-a.example/api".equals(reboundA.api)
                        && "v2".equals(reboundA.headers.get("X-Env"))
                        && !LiteCatalog.sameSiteBinding(oldA, reboundA),
                "Item 3: Existing site key rebinds to new config Site with updated URL and headers");
        LiteCatalog.Site switchedB =
                LiteCatalog.resolveSelectedSite(Arrays.asList(siteB), oldA, "siteA", oldA.api);
        check(
                switchedB == siteB,
                "Item 3: Removed old site falls back to available new site B");
        LiteCatalog.Site onlySpider = new LiteCatalog.Site();
        onlySpider.key = "sp";
        onlySpider.api = "csp_Demo";
        onlySpider.type = 3;
        onlySpider.supported = false;
        check(
                LiteCatalog.resolveSelectedSite(Arrays.asList(onlySpider), oldA, "siteA", oldA.api)
                        == null,
                "Item 3: Unsupported-only subscription resolves selected site to null");

        // 3. Item 4: Strict MacCMS XML (type=0 uses ac=list + ac=videolist; type=1 keeps ac=detail)
        final java.util.List<String> xmlQueries =
                java.util.Collections.synchronizedList(new java.util.ArrayList<String>());
        HttpServer strictXmlSrv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        try {
            strictXmlSrv.createContext(
                    "/xml",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            String q = ex.getRequestURI().getRawQuery();
                            if (q == null) q = "";
                            xmlQueries.add(q);
                            if (q.contains("ac=detail")) {
                                byte[] err = "ac=detail not allowed on strict xml".getBytes(StandardCharsets.UTF_8);
                                ex.sendResponseHeaders(400, err.length);
                                ex.getResponseBody().write(err);
                                ex.close();
                                return;
                            }
                            String body;
                            if (q.contains("ac=list")) {
                                body =
                                        "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"5.1\">"
                                                + "<class><ty id=\"1\">电影</ty><ty id=\"2\">剧集</ty></class>"
                                                + "<list page=\"1\" pagecount=\"2\" pagesize=\"20\" recordcount=\"2\"/></rss>";
                            } else if (q.contains("ac=videolist") && q.contains("ids=42")) {
                                body =
                                        "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"5.1\">"
                                                + "<list page=\"1\" pagecount=\"1\"><video><id>42</id><name><![CDATA[严格XML片]]></name>"
                                                + "<dl><dd flag=\"xmlm3u8\"><![CDATA[正片$http://media.example/xml42.m3u8]]></dd></dl></video></list></rss>";
                            } else if (q.contains("ac=videolist")) {
                                body =
                                        "<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"5.1\">"
                                                + "<list page=\"2\" pagecount=\"3\"><video><id>42</id><name><![CDATA[严格XML片]]></name>"
                                                + "<note><![CDATA[HD]]></note></video></list></rss>";
                            } else {
                                byte[] err = "missing ac".getBytes(StandardCharsets.UTF_8);
                                ex.sendResponseHeaders(400, err.length);
                                ex.getResponseBody().write(err);
                                ex.close();
                                return;
                            }
                            byte[] out = body.getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Content-Type", "application/xml; charset=utf-8");
                            ex.sendResponseHeaders(200, out.length);
                            ex.getResponseBody().write(out);
                            ex.close();
                        }
                    });
            strictXmlSrv.start();
            int xPort = strictXmlSrv.getAddress().getPort();
            LiteCatalog.Site xmlSite = new LiteCatalog.Site();
            xmlSite.key = "strict_xml";
            xmlSite.name = "严格XML站";
            xmlSite.type = 0;
            xmlSite.api = "http://127.0.0.1:" + xPort + "/xml";
            xmlSite.supported = true;

            List<LiteCatalog.Category> xmlCats =
                    LiteCatalog.categories(LiteCatalog.fetch(LiteCatalog.cmsCategoriesUrl(xmlSite), null));
            JSONObject xmlPage2 =
                    LiteCatalog.parseCmsResponse(
                            LiteCatalog.fetch(LiteCatalog.cmsListUrl(xmlSite, "1", "", 2), null));
            JSONObject xmlSearch =
                    LiteCatalog.parseCmsResponse(
                            LiteCatalog.fetch(LiteCatalog.cmsListUrl(xmlSite, "", "严格", 1), null));
            JSONArray xmlDetailArr =
                    LiteCatalog.list(LiteCatalog.fetch(LiteCatalog.cmsDetailUrl(xmlSite, "42"), null));
            check(
                    xmlCats.size() == 2
                            && "1".equals(xmlCats.get(0).id)
                            && xmlPage2.optInt("pagecount") == 3
                            && xmlSearch.optJSONArray("list").length() == 1
                            && xmlDetailArr.length() == 1
                            && "42".equals(xmlDetailArr.getJSONObject(0).optString("vod_id")),
                    "Item 4: Strict MacCMS XML succeeds for categories/list/page/search/detail using ac=list & ac=videolist");
            boolean sawDetailOnXml = false;
            for (int i = 0; i < xmlQueries.size(); i++) {
                if (xmlQueries.get(i).contains("ac=detail")) sawDetailOnXml = true;
            }
            check(!sawDetailOnXml, "Item 4: Strict XML never sends ac=detail");
            LiteCatalog.Site jsonSite = new LiteCatalog.Site();
            jsonSite.type = 1;
            jsonSite.api = "http://127.0.0.1:" + xPort + "/json";
            check(
                    LiteCatalog.cmsListUrl(jsonSite, "", "", 1).contains("ac=detail")
                            && LiteCatalog.cmsDetailUrl(jsonSite, "42").contains("ac=detail"),
                    "Item 4: JSON CMS (type=1) preserves ac=detail");
        } finally {
            strictXmlSrv.stop(0);
        }

        // 4. Item 5: Structured vod_play_list + deduplication + mixed direct-stream priority
        JSONObject case15Vod =
                new JSONObject(
                        "{\"vod_id\":\"15\",\"vod_name\":\"结构化剧\",\"vod_play_list\":["
                                + "{\"player_info\":{\"show\":\"直链主线\",\"from\":\"m3u8\"},"
                                + "\"urls\":{\"1\":{\"name\":\"第1集\",\"url\":\"https://cdn.example/1.m3u8\"},"
                                + "\"2\":{\"name\":\"第2集\",\"url\":\"https://cdn.example/2.m3u8\"}}},"
                                + "{\"player_info\":{\"show\":\"备用线路\",\"from\":\"bak\"},"
                                + "\"url\":\"正片$https://cdn.example/bak.mp4\"}"
                                + "]}");
        List<LiteActivity.PlayLine> structLines = LiteActivity.extractPlayLines(case15Vod, "");
        check(
                structLines.size() == 2
                        && "直链主线".equals(structLines.get(0).name)
                        && structLines.get(0).episodes.size() == 2
                        && "https://cdn.example/2.m3u8".equals(structLines.get(0).episodes.get(1).url)
                        && "备用线路".equals(structLines.get(1).name)
                        && structLines.get(1).episodes.size() == 1
                        && "https://cdn.example/bak.mp4".equals(structLines.get(1).episodes.get(0).url),
                "Item 5: Structured vod_play_list yields 2 lines (2 eps & 1 ep) with exact media URLs");

        JSONObject combinedVod =
                new JSONObject(
                        "{\"vod_id\":\"15b\",\"vod_name\":\"混合字段剧\","
                                + "\"vod_play_from\":\"m3u8$$$oldonly\","
                                + "\"vod_play_url\":\"第1集$https://cdn.example/1.m3u8#第2集$https://cdn.example/2.m3u8$$$老线1$https://cdn.example/old.mp4\","
                                + "\"vod_play_list\":{\"1\":{\"player_info\":{\"show\":\"直链主线\",\"from\":\"m3u8\"},"
                                + "\"urls\":{\"1\":{\"name\":\"第1集\",\"url\":\"https://cdn.example/1.m3u8\"},"
                                + "\"2\":{\"name\":\"第2集\",\"url\":\"https://cdn.example/2.m3u8\"}}},"
                                + "\"2\":{\"player_info\":{\"show\":\"新增结构线\",\"from\":\"extra\"},"
                                + "\"url\":\"番外$https://cdn.example/extra.m3u8\"}}}");
        List<LiteActivity.PlayLine> mergedLines = LiteActivity.extractPlayLines(combinedVod, "");
        check(
                mergedLines.size() == 3
                        && "直链主线".equals(mergedLines.get(0).name)
                        && "oldonly".equals(mergedLines.get(1).name)
                        && "新增结构线".equals(mergedLines.get(2).name),
                "Item 5: Traditional + structured vod_play_list merge cleanly without duplicates and preserve order");

        JSONObject mixedPriorityVod =
                new JSONObject()
                        .put("vod_play_from", "解析线路$$$高清直链")
                        .put(
                                "vod_play_url",
                                "第1集$https://video.example/play?id=1$$$第1集$https://cdn.example/direct.m3u8");
        List<LiteActivity.PlayLine> autoMixed = LiteActivity.extractPlayLines(mixedPriorityVod, "");
        List<LiteActivity.PlayLine> explicitMixed =
                LiteActivity.extractPlayLines(mixedPriorityVod, "解析线路");
        check(
                autoMixed.size() == 2
                        && "高清直链".equals(autoMixed.get(0).name)
                        && "解析线路".equals(explicitMixed.get(0).name),
                "Item 5: Mixed lines prioritize direct stream by default while respecting explicit preferredLine");

        // 5. Item 6: JSON play parsing (intact URL params, Referer header, proxy loopback, redirects, errors)
        final String[] capturedRawParseUrl = new String[] {""};
        final int[] parseHitCount = new int[] {0};
        final Map<String, String> capturedMediaHeaders =
                java.util.Collections.synchronizedMap(new HashMap<String, String>());
        HttpServer parseSrv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        try {
            final int[] pPortHolder = new int[1];
            parseSrv.createContext(
                    "/parse",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            parseHitCount[0]++;
                            String rawQ = ex.getRequestURI().getRawQuery();
                            String extracted = "";
                            if (rawQ != null) {
                                for (String part : rawQ.split("&")) {
                                    if (part.startsWith("url=")) {
                                        extracted =
                                                java.net.URLDecoder.decode(
                                                        part.substring(4), "UTF-8");
                                    }
                                }
                            }
                            capturedRawParseUrl[0] = extracted;
                            String resp =
                                    "{\"code\":200,\"url\":\"http://127.0.0.1:"
                                            + pPortHolder[0]
                                            + "/media.mp4\",\"header\":{\"Referer\":\"https://ref.example/watch\",\"User-Agent\":\"ParseClient/2.0\"}}";
                            byte[] out = resp.getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Content-Type", "application/json");
                            ex.sendResponseHeaders(200, out.length);
                            ex.getResponseBody().write(out);
                            ex.close();
                        }
                    });
            parseSrv.createContext(
                    "/media.mp4",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            String ref = ex.getRequestHeaders().getFirst("Referer");
                            String ua = ex.getRequestHeaders().getFirst("User-Agent");
                            if (ref != null) capturedMediaHeaders.put("Referer", ref);
                            if (ua != null) capturedMediaHeaders.put("User-Agent", ua);
                            byte[] out = "MP4DATA".getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Content-Type", "video/mp4");
                            ex.sendResponseHeaders(200, out.length);
                            ex.getResponseBody().write(out);
                            ex.close();
                        }
                    });
            parseSrv.createContext(
                    "/legacy-redir",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            ex.getResponseHeaders()
                                    .set(
                                            "Location",
                                            "http://127.0.0.1:" + pPortHolder[0] + "/media.mp4");
                            ex.sendResponseHeaders(302, -1);
                            ex.close();
                        }
                    });
            parseSrv.createContext(
                    "/legacy-direct-media",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            byte[] out = "DIRECTMP4".getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Content-Type", "video/mp4");
                            ex.sendResponseHeaders(200, out.length);
                            ex.getResponseBody().write(out);
                            ex.close();
                        }
                    });
            parseSrv.createContext(
                    "/parse-empty",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            byte[] out = "{\"code\":200,\"url\":\"\"}".getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Content-Type", "application/json");
                            ex.sendResponseHeaders(200, out.length);
                            ex.getResponseBody().write(out);
                            ex.close();
                        }
                    });
            parseSrv.createContext(
                    "/parse-html",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            byte[] out = "<!doctype html><html><body>player</body></html>".getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Content-Type", "text/html");
                            ex.sendResponseHeaders(200, out.length);
                            ex.getResponseBody().write(out);
                            ex.close();
                        }
                    });
            parseSrv.start();
            int pPort = parseSrv.getAddress().getPort();
            pPortHolder[0] = pPort;

            String complexRawUrl =
                    "https://origin.example/v/play?id=99&token=a%26b%3Dc&name=hello%20world";
            String parseConfig =
                    "{\"sites\":[{\"key\":\"p_site\",\"name\":\"解析测试\",\"type\":1,"
                            + "\"api\":\"http://127.0.0.1:"
                            + pPort
                            + "/cms\",\"parse\":1}],"
                            + "\"parses\":[{\"name\":\"测试JSON\",\"type\":1,\"url\":\"http://127.0.0.1:"
                            + pPort
                            + "/parse?url=\"}]}";
            List<LiteCatalog.Site> pSites = LiteCatalog.parse(parseConfig, "");
            check(
                    pSites.size() == 1 && pSites.get(0).supported && pSites.get(0).playUrlParseType == 1,
                    "Item 6: Config with type=1 JSON parse marks site supported with JSON parse type");
            LiteCatalog.ResolvedPlay resolved =
                    LiteCatalog.resolvePlayUrl(complexRawUrl, pSites.get(0), "线路1");
            check(
                    complexRawUrl.equals(capturedRawParseUrl[0])
                            && ("http://127.0.0.1:" + pPort + "/media.mp4").equals(resolved.url)
                            && "https://ref.example/watch".equals(resolved.headers.get("Referer"))
                            && "ParseClient/2.0".equals(resolved.headers.get("User-Agent")),
                    "Item 6: JSON parser receives intact encoded URL and returns media URL + Referer/UA");

            int hitsBeforeDirect = parseHitCount[0];
            LiteCatalog.ResolvedPlay directBypass =
                    LiteCatalog.resolvePlayUrl(
                            "http://127.0.0.1:" + pPort + "/media.mp4", pSites.get(0), "直链");
            check(
                    parseHitCount[0] == hitsBeforeDirect
                            && "direct".equals(directBypass.mode)
                            && ("http://127.0.0.1:" + pPort + "/media.mp4")
                                    .equals(directBypass.url),
                    "Item 6: Direct stream bypasses JSON parser on parse=1 site");

            String proxiedLocal =
                    LiteMediaProxy.wrapIfNeeded(
                            resolved.url, resolved.headers, LiteMediaProxy.MODE_AUTO, false);
            check(
                    proxiedLocal.startsWith("http://127.0.0.1:")
                            && !proxiedLocal.equals(resolved.url),
                    "Item 6: MODE_AUTO wraps loopback media URL when custom headers (Referer) are required");
            String proxiedResp = readHttp(proxiedLocal, null);
            check(
                    proxiedResp.equals("200:MP4DATA")
                            && "https://ref.example/watch"
                                    .equals(capturedMediaHeaders.get("Referer"))
                            && "ParseClient/2.0".equals(capturedMediaHeaders.get("User-Agent")),
                    "Item 6: Media server receives exact Referer and User-Agent via LiteMediaProxy");

            LiteCatalog.Site legacyRedirSite = new LiteCatalog.Site();
            legacyRedirSite.type = 1;
            legacyRedirSite.api = "http://127.0.0.1:" + pPort + "/cms";
            legacyRedirSite.playUrl = "http://127.0.0.1:" + pPort + "/legacy-redir?u=";
            legacyRedirSite.supported = true;
            LiteCatalog.ResolvedPlay redirRes =
                    LiteCatalog.resolvePlayUrl("https://origin.example/page", legacyRedirSite, "");
            check(
                    ("http://127.0.0.1:" + pPort + "/media.mp4").equals(redirRes.url),
                    "Item 6: Legacy prefix HTTP redirect resolves to final media URL");

            LiteCatalog.Site legacyMediaSite = new LiteCatalog.Site();
            legacyMediaSite.type = 1;
            legacyMediaSite.api = "http://127.0.0.1:" + pPort + "/cms";
            legacyMediaSite.playUrl = "http://127.0.0.1:" + pPort + "/legacy-direct-media?u=";
            legacyMediaSite.supported = true;
            LiteCatalog.ResolvedPlay directMediaRes =
                    LiteCatalog.resolvePlayUrl("https://origin.example/item", legacyMediaSite, "");
            check(
                    directMediaRes.url.startsWith(
                            "http://127.0.0.1:" + pPort + "/legacy-direct-media?u="),
                    "Item 6: Legacy prefix returning direct video/* resolves to playable media URL");

            Map<String, String> crossOriginInput = new HashMap<String, String>();
            crossOriginInput.put("Authorization", "Bearer secret-token");
            crossOriginInput.put("Cookie", "sid=secret");
            crossOriginInput.put("Referer", "https://ref.example/watch");
            crossOriginInput.put("User-Agent", "SafeUA/1.0");
            Map<String, String> crossOriginSafe =
                    LiteCatalog.inheritedHeaders(
                            new URL("https://parse.example/api"),
                            new URL("https://cdn.other.example/video.m3u8"),
                            crossOriginInput);
            check(
                    !crossOriginSafe.containsKey("Authorization")
                            && !crossOriginSafe.containsKey("Cookie")
                            && "https://ref.example/watch".equals(crossOriginSafe.get("Referer"))
                            && "SafeUA/1.0".equals(crossOriginSafe.get("User-Agent")),
                    "Item 6: Cross-origin play resolution strips Authorization/Cookie while keeping Referer/UA");

            LiteCatalog.Site emptyParseSite = new LiteCatalog.Site();
            emptyParseSite.type = 1;
            emptyParseSite.api = "http://127.0.0.1:" + pPort + "/cms";
            emptyParseSite.playUrl = "json:http://127.0.0.1:" + pPort + "/parse-empty?url=";
            emptyParseSite.playUrlParseType = 1;
            emptyParseSite.supported = true;
            boolean emptyFailed = false;
            try {
                LiteCatalog.resolvePlayUrl("https://origin.example/page", emptyParseSite, "");
            } catch (Exception ex) {
                emptyFailed = ex.getMessage() != null && ex.getMessage().contains("空");
            }
            check(emptyFailed, "Item 6: JSON parser empty URL raises clear error");

            LiteCatalog.Site htmlParseSite = new LiteCatalog.Site();
            htmlParseSite.type = 1;
            htmlParseSite.api = "http://127.0.0.1:" + pPort + "/cms";
            htmlParseSite.playUrl = "json:http://127.0.0.1:" + pPort + "/parse-html?url=";
            htmlParseSite.playUrlParseType = 1;
            htmlParseSite.supported = true;
            boolean htmlFailed = false;
            try {
                LiteCatalog.resolvePlayUrl("https://origin.example/page", htmlParseSite, "");
            } catch (Exception ex) {
                htmlFailed = ex.getMessage() != null && ex.getMessage().contains("网页");
            }
            check(htmlFailed, "Item 6: HTML page from JSON parser raises clear limitation error");

            List<LiteCatalog.Site> webOnlySites =
                    LiteCatalog.parse(
                            "{\"sites\":[{\"key\":\"w\",\"name\":\"网页源\",\"type\":1,\"api\":\"http://127.0.0.1:"
                                    + pPort
                                    + "/cms\",\"parse\":1}],\"parses\":[{\"name\":\"嗅探\",\"type\":0,\"url\":\"http://127.0.0.1:"
                                    + pPort
                                    + "/sniff?url=\"}]}",
                            "");
            check(
                    webOnlySites.size() == 1
                            && webOnlySites.get(0).playbackHint().contains("type=0"),
                    "Item 6: type=0 web-sniff-only parse config surfaces specific limitation hint");

            List<LiteCatalog.Site> isolatedJsonSites =
                    LiteCatalog.parse(
                            "{\"sites\":[{\"key\":\"iso\",\"name\":\"独立解析\",\"type\":1,\"api\":\"http://127.0.0.1:"
                                    + pPort
                                    + "/cms\",\"playUrl\":\"json:http://127.0.0.1:"
                                    + pPort
                                    + "/parse-empty?url=\"}],\"parses\":[{\"name\":\"全局\",\"type\":1,\"url\":\"http://127.0.0.1:"
                                    + pPort
                                    + "/parse?url=\"}]}",
                            "");
            check(
                    isolatedJsonSites.size() == 1 && isolatedJsonSites.get(0).jsonParses.isEmpty(),
                    "Item 6: Explicit json: playUrl with parse=0 does not mix unrelated global parses[]");
        } finally {
            parseSrv.stop(0);
            try {
                LiteMediaProxy.get().close();
            } catch (Exception ignored) {
            }
        }

        // 6. Item 7: Lives-only config, inline multi-line channels, redirect-relative M3U, per-line Referer/UA
        String pureLivesConfig =
                "{\"lives\":[{\"group\":\"央视高清\",\"channels\":["
                        + "{\"name\":\"CCTV-1\",\"urls\":["
                        + "\"线路一$http://live.example/a.m3u8|Referer=https://ref1.example/&User-Agent=UA1\","
                        + "\"线路二$http://live.example/b.m3u8|Referer=https://ref2.example/&User-Agent=UA2\""
                        + "]}]}]}";
        List<LiteCatalog.Site> pureLiveSites = LiteCatalog.parse(pureLivesConfig, "");
        List<LiteCatalog.LiveSource> pureLiveSources = LiteCatalog.parseLives(pureLivesConfig, "");
        check(
                pureLiveSites.isEmpty() && pureLiveSources.size() == 1,
                "Item 7: Pure lives-only config imports cleanly without sites[]");
        List<LiteCatalog.LiveGroup> inlineGroups =
                LiteCatalog.fetchLiveGroups(pureLiveSources.get(0));
        check(
                inlineGroups.size() == 1
                        && "央视高清".equals(inlineGroups.get(0).name)
                        && inlineGroups.get(0).channels.size() == 1
                        && inlineGroups.get(0).channels.get(0).urls.size() == 2
                        && "https://ref1.example/"
                                .equals(
                                        inlineGroups.get(0).channels.get(0).headersForLine(0)
                                                .get("Referer"))
                        && "https://ref2.example/"
                                .equals(
                                        inlineGroups.get(0).channels.get(0).headersForLine(1)
                                                .get("Referer"))
                        && "UA2"
                                .equals(
                                        inlineGroups.get(0).channels.get(0).headersForLine(1)
                                                .get("User-Agent")),
                "Item 7: Inline lives[].channels[].urls builds groups/channels/2 lines with distinct per-line headers");

        HttpServer liveRedirSrv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        try {
            final int[] lPort = new int[1];
            liveRedirSrv.createContext(
                    "/entry.m3u",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            ex.getResponseHeaders()
                                    .set("Location", "http://127.0.0.1:" + lPort[0] + "/sub/list.m3u");
                            ex.sendResponseHeaders(302, -1);
                            ex.close();
                        }
                    });
            liveRedirSrv.createContext(
                    "/sub/list.m3u",
                    new HttpHandler() {
                        @Override
                        public void handle(HttpExchange ex) throws java.io.IOException {
                            String m3u =
                                    "#EXTM3U\n"
                                            + "#EXTINF:-1 group-title=\"本地组\",双线台\n"
                                            + "#EXTVLCOPT:http-referrer=https://m3u-ref-1.example/\n"
                                            + "#EXTVLCOPT:http-user-agent=M3U-UA-1\n"
                                            + "streams/line1.m3u8\n"
                                            + "#EXTINF:-1 group-title=\"本地组\",双线台\n"
                                            + "#EXTVLCOPT:http-referrer=https://m3u-ref-2.example/\n"
                                            + "#EXTVLCOPT:http-user-agent=M3U-UA-2\n"
                                            + "../alt/line2.m3u8\n";
                            byte[] out = m3u.getBytes(StandardCharsets.UTF_8);
                            ex.getResponseHeaders().set("Content-Type", "audio/x-mpegurl; charset=utf-8");
                            ex.sendResponseHeaders(200, out.length);
                            ex.getResponseBody().write(out);
                            ex.close();
                        }
                    });
            liveRedirSrv.start();
            lPort[0] = liveRedirSrv.getAddress().getPort();
            LiteCatalog.LiveSource redirLiveSrc = new LiteCatalog.LiveSource();
            redirLiveSrc.name = "重定向M3U";
            redirLiveSrc.url = "http://127.0.0.1:" + lPort[0] + "/entry.m3u";
            List<LiteCatalog.LiveGroup> redirGroups = LiteCatalog.fetchLiveGroups(redirLiveSrc);
            check(
                    redirGroups.size() == 1
                            && redirGroups.get(0).channels.size() == 1
                            && ("http://127.0.0.1:" + lPort[0] + "/sub/streams/line1.m3u8")
                                    .equals(redirGroups.get(0).channels.get(0).urls.get(0))
                            && ("http://127.0.0.1:" + lPort[0] + "/alt/line2.m3u8")
                                    .equals(redirGroups.get(0).channels.get(0).urls.get(1))
                            && "https://m3u-ref-1.example/"
                                    .equals(
                                            redirGroups.get(0).channels.get(0).headersForLine(0)
                                                    .get("Referer"))
                            && "https://m3u-ref-2.example/"
                                    .equals(
                                            redirGroups.get(0).channels.get(0).headersForLine(1)
                                                    .get("Referer")),
                    "Item 7: Relative M3U URLs resolve against post-redirect final URL with per-line EXTVLCOPT headers");
        } finally {
            liveRedirSrv.stop(0);
        }

        List<LiteCatalog.LiveGroup> txtGroups =
                LiteCatalog.parseLiveContent(
                        "卫视,#genre#\n湖南卫视,http://live.example/hn1.m3u8|Referer=https://r1.example/#http://live.example/hn2.m3u8|Referer=https://r2.example/\n",
                        "");
        check(
                txtGroups.size() == 1
                        && "卫视".equals(txtGroups.get(0).name)
                        && txtGroups.get(0).channels.size() == 1
                        && txtGroups.get(0).channels.get(0).urls.size() == 2
                        && "https://r1.example/"
                                .equals(
                                        txtGroups.get(0).channels.get(0).headersForLine(0)
                                                .get("Referer"))
                        && "https://r2.example/"
                                .equals(
                                        txtGroups.get(0).channels.get(0).headersForLine(1)
                                                .get("Referer")),
                "Item 7: Grouped TXT live playlist preserves multi-line per-line Referer headers");

        String b64LiveUrl =
                java.util.Base64.getEncoder()
                        .encodeToString(
                                "http://live.example/b64.m3u".getBytes(StandardCharsets.UTF_8));
        List<LiteCatalog.LiveSource> b64LiveSources =
                LiteCatalog.parseLives(
                        "{\"lives\":[{\"group\":\"redirect\",\"channels\":[{\"name\":\"live\",\"urls\":[\"proxy://do=live&type=txt&ext="
                                + b64LiveUrl
                                + "\"]}]}]}",
                        "");
        check(
                b64LiveSources.size() == 1
                        && "http://live.example/b64.m3u".equals(b64LiveSources.get(0).url),
                "Item 7: Legacy proxy:// Base64 live entry remains supported");

        // 7. Item 9: Same siteKey + vodId, different siteApi -> distinct history, favorites, 2-round LiteSync merge & legacy resolution
        LiteStore.HistoryEntry hA = new LiteStore.HistoryEntry();
        hA.siteKey = "same_key";
        hA.siteName = "站点甲";
        hA.siteApi = "http://a.example/cms";
        hA.vodId = "100";
        hA.vodName = "甲站电影";
        hA.epName = "第1集";
        hA.epUrl = "http://a.example/1.mp4";
        hA.positionMs = 12000;
        hA.updatedAt = 5000L;
        LiteStore.HistoryEntry hB = new LiteStore.HistoryEntry();
        hB.siteKey = "same_key";
        hB.siteName = "站点乙";
        hB.siteApi = "http://b.example/cms";
        hB.vodId = "100";
        hB.vodName = "乙站剧集";
        hB.epName = "第2集";
        hB.epUrl = "http://b.example/2.mp4";
        hB.positionMs = 24000;
        hB.updatedAt = 6000L;
        String dualHistJson = LiteStore.recordHistoryJson("[]", hA);
        dualHistJson = LiteStore.recordHistoryJson(dualHistJson, hB);
        List<LiteStore.HistoryEntry> dualHist = LiteStore.parseHistoryJson(dualHistJson);
        check(
                dualHist.size() == 2
                        && "甲站电影"
                                .equals(
                                        LiteStore.findHistoryInList(
                                                        dualHist,
                                                        "same_key",
                                                        "http://a.example/cms",
                                                        "100",
                                                        false)
                                                .vodName)
                        && "乙站剧集"
                                .equals(
                                        LiteStore.findHistoryInList(
                                                        dualHist,
                                                        "same_key",
                                                        "http://b.example/cms",
                                                        "100",
                                                        false)
                                                .vodName),
                "Item 9: Same siteKey+vodId with different siteApi keep independent history entries");

        LiteStore.FavoriteEntry fA = new LiteStore.FavoriteEntry();
        fA.siteKey = "same_key";
        fA.siteName = "站点甲";
        fA.siteApi = "http://a.example/cms";
        fA.vodId = "100";
        fA.vodName = "甲站电影";
        fA.addedAt = 5000L;
        LiteStore.FavoriteEntry fB = new LiteStore.FavoriteEntry();
        fB.siteKey = "same_key";
        fB.siteName = "站点乙";
        fB.siteApi = "http://b.example/cms";
        fB.vodId = "100";
        fB.vodName = "乙站剧集";
        fB.addedAt = 5100L;
        String dualFavJson = LiteStore.toggleFavoriteJson("[]", fA, false);
        dualFavJson = LiteStore.toggleFavoriteJson(dualFavJson, fB, false);
        check(
                LiteStore.parseFavoritesJson(dualFavJson).size() == 2,
                "Item 9: Same siteKey+vodId with different siteApi keep independent favorites");
        String remoteDualPayload =
                LiteSync.exportPayload(dualHistJson, dualFavJson, "", null, false, 6500L);
        String afterUnfavA = LiteStore.toggleFavoriteJson(dualFavJson, fA, false);
        LiteSync.Tombstones unfavATombs = LiteSync.Tombstones.read("");
        unfavATombs.putMax(
                "fav:" + LiteSync.itemKey("same_key", "http://a.example/cms", "100"), 7000L);
        LiteSync.MergeResult syncR1 =
                LiteSync.merge(
                        dualHistJson,
                        afterUnfavA,
                        unfavATombs.json(),
                        null,
                        false,
                        remoteDualPayload,
                        7100L);
        LiteSync.MergeResult syncR2 =
                LiteSync.merge(
                        syncR1.historyJson,
                        syncR1.favoritesJson,
                        syncR1.tombstonesJson,
                        null,
                        false,
                        remoteDualPayload,
                        7200L);
        List<LiteStore.FavoriteEntry> postSyncFavs =
                LiteStore.parseFavoritesJson(syncR2.favoritesJson);
        check(
                syncR1.historyCount == 2
                        && syncR2.historyCount == 2
                        && postSyncFavs.size() == 1
                        && "http://b.example/cms".equals(postSyncFavs.get(0).siteApi)
                        && "乙站剧集".equals(postSyncFavs.get(0).vodName),
                "Item 9: Unfavoriting Site A + two LiteSync merges removes Site A while keeping Site B");

        LiteCatalog.Site dupSiteA = new LiteCatalog.Site();
        dupSiteA.key = "same_key";
        dupSiteA.name = "站点甲";
        dupSiteA.api = "http://a.example/cms";
        dupSiteA.type = 1;
        dupSiteA.supported = true;
        LiteCatalog.Site dupSiteB = new LiteCatalog.Site();
        dupSiteB.key = "same_key";
        dupSiteB.name = "站点乙";
        dupSiteB.api = "http://b.example/cms";
        dupSiteB.type = 1;
        dupSiteB.supported = true;
        LiteCatalog.RecordSiteResolution byApi =
                LiteCatalog.resolveSiteForRecord(
                        Arrays.asList(dupSiteA, dupSiteB),
                        "same_key",
                        "http://b.example/cms",
                        "站点乙");
        LiteCatalog.RecordSiteResolution uniqueLegacy =
                LiteCatalog.resolveSiteForRecord(
                        Arrays.asList(dupSiteA), "same_key", "", "旧站点");
        LiteCatalog.RecordSiteResolution ambiguousLegacy =
                LiteCatalog.resolveSiteForRecord(
                        Arrays.asList(dupSiteA, dupSiteB), "same_key", "", "旧站点");
        LiteCatalog.RecordSiteResolution synthesized =
                LiteCatalog.resolveSiteForRecord(
                        Arrays.asList(dupSiteA),
                        "removed_key",
                        "http://gone.example/api.php/provide/vod/at/xml/",
                        "旧XML站");
        check(
                byApi.matchedSite == dupSiteB
                        && uniqueLegacy.matchedSite == dupSiteA
                        && ambiguousLegacy.matchedSite == null
                        && ambiguousLegacy.ambiguousCandidates.size() == 2
                        && synthesized.matchedSite != null
                        && synthesized.synthesizedFallback
                        && synthesized.matchedSite.type == 0,
                "Item 9: Record site resolution prefers siteApi, recovers unique legacy records, flags ambiguous legacy records, and synthesizes removed siteApi");

        // 8. Item 10: Global search feedback distinctions & Python/Spider/JAR/JS/Netdisk capability hints
        String zeroHit =
                LiteActivity.formatGlobalSearchSummary(
                        "冷门片", 3, 3, 3, 0, Arrays.<String>asList(), 0, 1, 2);
        String partialFailZero =
                LiteActivity.formatGlobalSearchSummary(
                        "冷门片", 3, 3, 2, 1, Arrays.asList("慢站"), 0, 0, 0);
        String partialFailHit =
                LiteActivity.formatGlobalSearchSummary(
                        "热门片", 15, 12, 10, 2, Arrays.asList("故障1", "故障2"), 9, 1, 3);
        String allFail =
                LiteActivity.formatGlobalSearchSummary(
                        "热门片", 2, 2, 0, 2, Arrays.asList("坏站A", "坏站B"), 0, 0, 0);
        String entryScope = LiteActivity.formatSearchEntryScope(15, 1, 2, 1);
        check(
                zeroHit.contains("确实零命中")
                        && zeroHit.contains("Emby")
                        && zeroHit.contains("跳过 2")
                        && partialFailZero.contains("2 个正常无命中")
                        && partialFailZero.contains("1 个失败")
                        && partialFailHit.contains("10 个成功，2 个失败")
                        && partialFailHit.contains("上限 12 源")
                        && allFail.contains("全部失败")
                        && entryScope.contains("12")
                        && entryScope.contains("Emby")
                        && entryScope.contains("Python"),
                "Item 10: Search feedback distinguishes true 0-hit, partial failure, all-failed, and scope limits");

        LiteCatalog.Site pySite = new LiteCatalog.Site();
        pySite.key = "py_demo";
        pySite.name = "Python源";
        pySite.type = 4;
        pySite.api = "py_douban";
        check(
                LiteCatalog.Site.STATUS_NEEDS_JAR.equals(pySite.capabilityStatus())
                        && pySite.limitation().contains("Python"),
                "Item 10: Python plugin site reports specific Python limitation reason");
    }
}

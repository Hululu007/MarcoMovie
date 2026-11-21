package com.pilipala.marcomovie;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Pure JVM regression checks for the 10-item Android TV UX specialization & optimization pass:
 * dialog sizing/QR bounds, Android TV storage permission fallbacks, Settings left-focus category
 * mapping, top immersive nav bar shrink progress, source-independent curated Home parsing &
 * matching, official HD landscape poster ranking & Douban credits/seasons parsing, continue-play
 * route caption, chunked DLNA SOAP & SSDP v2 handling, and selectable LAN DLNA discovery/XML/SOAP.
 */
public final class TvUxOptimizationChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError("FAILED: " + label);
        checks++;
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) throws Exception {
        testDialogAndQrSizing();
        testStoragePermissionFallbacks();
        testSettingsCategoryAndTopDockShrink();
        testCuratedHomeParsingAndSourceMatching();
        testOfficialLandscapePosterRankingAndDoubanParsing();
        testContinuePlaySubtitle();
        testCastServiceHardeningAndDlnaClient();
        testDanmakuSanitizationAndParsing();
        testCuratedShelfComfortWindowAndScopedFocusFrame();
        testCrashHardeningMiniDetailsAndHudRedesign();
        System.out.println("ALL PASS (" + checks + " TV UX optimization checks)");
    }

    private static void testDialogAndQrSizing() {
        check(
                PluginDialogStyler.resolveDialogWidthPx(1920, 176, 1320) == 1320,
                "PluginDialogStyler widens TV dialog up to 660dp cap on 1080p");
        check(
                PluginDialogStyler.resolveDialogWidthPx(960, 88, 660) == 660,
                "PluginDialogStyler fits 660px width cleanly inside 960px window");
        check(
                PluginDialogStyler.resolveDialogWidthPx(600, 88, 660) == 512,
                "PluginDialogStyler clamps narrow window to winW - marginH");

        int tvQr540 = PluginDialogStyler.resolveMaxQrSizePx(540, 132, 168, true);
        int tvQr1080 = PluginDialogStyler.resolveMaxQrSizePx(1080, 264, 336, true);
        check(
                tvQr540 >= 132 && tvQr540 <= 168 && tvQr1080 >= 264 && tvQr1080 <= 336,
                "PluginDialogStyler keeps TV QR code compact so scan dialogs never clip vertically");

        int maxContent = AppDialog.computeMaxContentHeight(540, 148, 56, 120);
        check(
                maxContent == 336,
                "AppDialog computes exact available content height from window minus chrome");
        check(
                AppDialog.computeMaxContentHeight(260, 200, 56, 120) == 120,
                "AppDialog enforces minimum scroll body height on ultra-short windows");
    }

    private static void testStoragePermissionFallbacks() {
        check(
                MainActivity.isManageAllFilesAction(
                                "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION")
                        && MainActivity.isManageAllFilesAction(
                                "android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION")
                        && !MainActivity.isManageAllFilesAction(
                                "android.settings.APPLICATION_DETAILS_SETTINGS"),
                "MainActivity identifies Android 11+ all-files storage settings intents");

        List<String> api30 = MainActivity.storagePermissionFallbackActions(30);
        check(
                api30.size() == 3
                        && "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION"
                                .equals(api30.get(0))
                        && "android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION"
                                .equals(api30.get(1))
                        && "android.settings.APPLICATION_DETAILS_SETTINGS".equals(api30.get(2)),
                "API 30+ TV storage fallback chain ends at app details settings");

        List<String> api28 = MainActivity.storagePermissionFallbackActions(28);
        check(
                api28.size() == 1
                        && "android.settings.APPLICATION_DETAILS_SETTINGS".equals(api28.get(0)),
                "Pre-API 30 TV storage fallback targets app details settings directly");
    }

    private static void testSettingsCategoryAndTopDockShrink() {
        check(
                SettingsScreen.resolveTvCategoryIndex("外观与壁纸") == 0
                        && SettingsScreen.resolveTvCategoryIndex("播放与字幕") == 1
                        && SettingsScreen.resolveTvCategoryIndex("片源与直播") == 2
                        && SettingsScreen.resolveTvCategoryIndex("数据与备份") == 3
                        && SettingsScreen.resolveTvCategoryIndex("软件更新") == 4
                        && SettingsScreen.resolveTvCategoryIndex("未知分类") == 0,
                "SettingsScreen resolves all 5 TV left-sidebar categories accurately");

        check(
                HomeDock.computeTopShrinkProgress(0, 180) == 0f
                        && Math.abs(HomeDock.computeTopShrinkProgress(90, 180) - 0.5f) < 0.001f
                        && HomeDock.computeTopShrinkProgress(260, 180) == 1f
                        && HomeDock.computeTopShrinkProgress(-20, 180) == 0f,
                "HomeDock top immersive shrink progress clamps cleanly in [0, 1]");

        float scrimTop = HomeDock.computeTopScrimAlpha(0f);
        float scrimMid = HomeDock.computeTopScrimAlpha(0.5f);
        float scrimFull = HomeDock.computeTopScrimAlpha(1f);
        check(
                scrimTop > 0.1f
                        && scrimTop < 0.25f
                        && scrimMid > scrimTop
                        && scrimFull > scrimMid
                        && scrimFull <= 0.96f,
                "HomeDock top scrim alpha eases smoothly without abrupt cutoff");

        String[] navLabels = HomeDock.tvNavLabels();
        String[] navKeys = HomeDock.tvNavKeys();
        check(
                navLabels.length == 8
                        && navKeys.length == 8
                        && "历史".equals(navLabels[2])
                        && "nav-history".equals(navKeys[2])
                        && "nav-accounts".equals(navKeys[5]),
                "HomeDock exposes 8 TV nav items including dedicated Watch History entry");

        check(
                MainActivity.isMenuShortPress(android.view.KeyEvent.ACTION_UP, false, 0)
                        && MainActivity.isMenuShortPress(
                                android.view.KeyEvent.ACTION_UP, true, 0x7531)
                        && !MainActivity.isMenuShortPress(
                                android.view.KeyEvent.ACTION_UP, true, 0x20)
                        && !MainActivity.isMenuShortPress(
                                android.view.KeyEvent.ACTION_DOWN, false, 0),
                "MainActivity accepts both standard TV MENU taps and MiTV synthetic 0x7531 MENU taps");

        float revTop = HomeAmbient.computeScrollReveal(0, 660);
        float revStart = HomeAmbient.computeScrollReveal(60, 660);
        float revMid = HomeAmbient.computeScrollReveal(320, 660);
        float revOffHero = HomeAmbient.computeScrollReveal(600, 660);
        float revNoHero = HomeAmbient.computeScrollReveal(0, 0);
        check(
                revTop >= 0.65f
                        && revTop <= 0.72f
                        && Math.abs(revStart - revTop) < 0.01f
                        && revMid > revTop
                        && revMid < 1f
                        && revOffHero == 1f
                        && revNoHero == 1f,
                "HomeAmbient holds seamless base glow under feathered hero and rises smoothly to full strength on scroll");
    }

    private static void testCuratedHomeParsingAndSourceMatching() {
        String collectionJson =
                "{\"subject_collection_items\":["
                        + "{\"id\":\"3600001\",\"title\":\"藏海传\",\"year\":\"2025\","
                        + "\"card_subtitle\":\"2025 / 中国大陆 / 古装 权谋 / 肖战 张婧仪\","
                        + "\"episodes_info\":\"更新至24集\",\"rating\":{\"value\":8.2},"
                        + "\"pic\":{\"large\":\"https://img1.doubanio.com/p1.jpg\"}},"
                        + "{\"id\":\"3600002\",\"title\":\"藏海传\",\"year\":\"2025\"}"
                        + "]}";
        List<Cms.Video> parsed = TvCuratedHome.parseCollectionVideos(collectionJson, false);
        check(
                parsed.size() == 1
                        && "藏海传".equals(parsed.get(0).title)
                        && "2025".equals(parsed.get(0).year)
                        && "中国大陆".equals(parsed.get(0).area)
                        && "8.2".equals(parsed.get(0).doubanScore),
                "TvCuratedHome parses and deduplicates Douban collection metadata");

        Cms.Video target = new Cms.Video();
        target.title = "庆余年 第二季";
        target.year = "2024";

        Cms.Video exact4k = new Cms.Video();
        exact4k.title = "庆余年 第二季";
        exact4k.year = "2024";
        exact4k.remarks = "4K HDR 更新至36集";

        Cms.Video wrongSeason = new Cms.Video();
        wrongSeason.title = "庆余年 第一季";
        wrongSeason.year = "2019";

        Cms.Video unrelated = new Cms.Video();
        unrelated.title = "长安十二时辰";
        unrelated.year = "2019";

        int exactScore = TvCuratedHome.scoreSourceMatch(target, exact4k);
        int wrongSeasonScore = TvCuratedHome.scoreSourceMatch(target, wrongSeason);
        int unrelatedScore = TvCuratedHome.scoreSourceMatch(target, unrelated);
        check(
                exactScore > 120 && exactScore > wrongSeasonScore && unrelatedScore < 0,
                "TvCuratedHome.scoreSourceMatch prefers exact title/season/year/4K and rejects unrelated");
    }

    private static void testOfficialLandscapePosterRankingAndDoubanParsing() {
        // Wallpaper (W) > Official Landscape Poster (R) > Clean 16:9 Still (S) > Rejected
        // BTS/Portrait
        int wScore = ImmersivePoster.scoreLandscapePhoto(1920, 1080, "官方主视觉横版壁纸", "W");
        int rScore = ImmersivePoster.scoreLandscapePhoto(1600, 900, "定档横版海报", "R");
        int sScore = ImmersivePoster.scoreLandscapePhoto(1600, 900, "剧照", "S");
        int btsScore = ImmersivePoster.scoreLandscapePhoto(1920, 1080, "开机发布会现场花絮", "S");
        int portraitScore = ImmersivePoster.scoreLandscapePhoto(1080, 1600, "官方海报", "R");
        int lowResScore = ImmersivePoster.scoreLandscapePhoto(640, 360, "剧照", "S");
        check(
                wScore > rScore
                        && rScore > sScore
                        && sScore > 0
                        && btsScore < 0
                        && portraitScore < 0
                        && lowResScore < 0,
                "ImmersivePoster.scoreLandscapePhoto ranks official W > R > clean 16:9 S and rejects BTS/portrait/low-res");

        String photosJson =
                "{\"photos\":["
                        + "{\"description\":\"首映礼发布会合影\",\"image\":{\"large\":{\"width\":1920,\"height\":1080,\"url\":\"https://img1.doubanio.com/bts.jpg\"}}},"
                        + "{\"description\":\"竖版海报\",\"image\":{\"large\":{\"width\":1000,\"height\":1500,\"url\":\"https://img1.doubanio.com/portrait.jpg\"}}},"
                        + "{\"description\":\"官方横版主视觉海报\",\"image\":{\"large\":{\"width\":1920,\"height\":1080,\"url\":\"https://img2.doubanio.com/official_wide.jpg\"}}},"
                        + "{\"description\":\"普通剧照\",\"image\":{\"large\":{\"width\":1280,\"height\":720,\"url\":\"https://img3.doubanio.com/still.jpg\"}}}"
                        + "]}";
        List<String> ranked = ImmersivePoster.extractBestDoubanLandscapeUrls(photosJson, "S");
        check(
                ranked.size() == 2
                        && ranked.get(0).contains("official_wide.jpg")
                        && ranked.get(1).contains("still.jpg"),
                "ImmersivePoster.extractBestDoubanLandscapeUrls filters out BTS/portrait and ranks official HD poster first");

        // Douban Rexxar real /credits grouped schema + seasons_count parsing
        String subjectJson =
                "{\"year\":\"2024\",\"countries\":[\"中国大陆\"],\"episodes_count\":36,\"seasons_count\":2,"
                        + "\"genres\":[\"古装\",\"剧情\"],\"intro\":\"范闲再入京都风云。\","
                        + "\"rating\":{\"value\":7.3}}";
        String groupedCreditsJson =
                "{\"credits\":["
                        + "{\"title\":\"导演\",\"celebrities\":[{\"name\":\"孙皓\",\"avatar\":{\"normal\":\"https://img1.doubanio.com/dir.jpg\"}}]},"
                        + "{\"title\":\"演员\",\"celebrities\":["
                        + "{\"name\":\"张若昀\",\"character\":\"饰 范闲\",\"avatar\":{\"normal\":\"https://img2.doubanio.com/zry.jpg\"}},"
                        + "{\"name\":\"李沁\",\"character\":\"饰 林婉儿\",\"avatar\":{\"normal\":\"https://img3.doubanio.com/lq.jpg\"}}"
                        + "]}]}";
        ImmersivePoster.SubjectDetails parsed =
                ImmersivePoster.parseDoubanSubjectJson(subjectJson, groupedCreditsJson);
        check(
                parsed.seasonsCount == 2
                        && parsed.episodesCount == 36
                        && parsed.cast.size() == 3
                        && "张若昀".equals(parsed.cast.get(1).name)
                        && "范闲".equals(parsed.cast.get(1).role)
                        && parsed.cast.get(1).avatarUrl.contains("zry.jpg"),
                "parseDoubanSubjectJson parses grouped Douban credits/celebrities and seasons_count");

        Cms.Video show = new Cms.Video();
        show.title = "庆余年 第二季";
        List<String> badges = ImmersivePoster.buildOfficialFactBadges(show, parsed, 0);
        String line = ImmersivePoster.formatOfficialFactLine(show, parsed);
        check(
                badges.contains("2024")
                        && badges.contains("中国大陆")
                        && badges.contains("共 2 季")
                        && badges.contains("全 36 集")
                        && line.contains("共 2 季"),
                "buildOfficialFactBadges & formatOfficialFactLine display year, region, multi-season count, and real episode count");
    }

    private static void testContinuePlaySubtitle() {
        WatchHistory.Entry bm = new WatchHistory.Entry();
        bm.line = "夸克4K";
        bm.episode = "三体.S01E05.2160p.HDR.mkv";
        bm.position = 1230000;
        bm.duration = 2700000;
        String sub =
                TvV17DetailScreen.formatContinuePlaySubtitle(
                        bm, "夸克4K  ·  三体.S01E05.2160p.HDR.mkv", "");
        check(
                sub.startsWith("上次播放：夸克4K  ·  三体.S01E05.2160p.HDR.mkv")
                        && sub.contains("20:30 / 45:00"),
                "formatContinuePlaySubtitle shows last played route resource name and progress beneath Play buttons");
        check(
                "".equals(TvV17DetailScreen.formatContinuePlaySubtitle(null, "夸克4K · EP01", "")),
                "formatContinuePlaySubtitle returns empty when not continuing playback");
    }

    private static void testCastServiceHardeningAndDlnaClient() throws Exception {
        // 1. Chunked HTTP SOAP body decoding
        String soapPayload = "<s:Envelope><s:Body><u:Play/></s:Body></s:Envelope>";
        String chunk1 = soapPayload.substring(0, 16);
        String chunk2 = soapPayload.substring(16);
        String chunkedWire =
                Integer.toHexString(chunk1.length())
                        + "\r\n"
                        + chunk1
                        + "\r\n"
                        + Integer.toHexString(chunk2.length())
                        + "\r\n"
                        + chunk2
                        + "\r\n0\r\n\r\n";
        byte[] decoded =
                CastService.readChunkedBody(
                        new ByteArrayInputStream(chunkedWire.getBytes(StandardCharsets.UTF_8)),
                        CastService.MAX_HTTP_BODY);
        check(
                soapPayload.equals(new String(decoded, StandardCharsets.UTF_8)),
                "CastService.readChunkedBody decodes chunked DLNA SOAP requests accurately");

        // 2. Case-insensitive M-SEARCH + MediaRenderer:2 / AVTransport:2 matching
        String lowerSearch =
                "m-search * http/1.1\r\n"
                        + "HOST: 239.255.255.250:1900\r\n"
                        + "MAN: \"ssdp:discover\"\r\n"
                        + "ST: urn:schemas-upnp-org:device:MediaRenderer:2\r\n\r\n";
        List<String[]> replies = CastService.matchSsdpReplies(lowerSearch, "abcd-1234");
        check(
                replies.size() == 1 && CastService.NT_RENDERER.equals(replies.get(0)[0]),
                "CastService.matchSsdpReplies handles case-insensitive M-SEARCH and MediaRenderer:2");

        // 3. validateCastMediaUrl preserves SSRF blocks while encoding unescaped pipe/space in
        // query
        String pipeUrl =
                CastService.validateCastMediaUrl("https://cdn.example/live/ch1.m3u8?tags=a|b c");
        check(
                pipeUrl.contains("%7C")
                        && pipeUrl.contains("%20")
                        && CastService.validateCastMediaUrl("http://127.0.0.1:8080/a.m3u8")
                                .isEmpty(),
                "CastService.validateCastMediaUrl encodes CDN query chars while keeping strict SSRF loopback block");

        // 4. DlnaCastClient SSDP location parsing (accepts LAN 10.x, rejects loopback/public)
        List<String> locs =
                DlnaCastClient.parseSsdpLocations(
                        Arrays.asList(
                                "HTTP/1.1 200 OK\r\nLOCATION: http://10.0.2.2:49152/description.xml\r\n\r\n",
                                "HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:8080/evil.xml\r\n\r\n",
                                "HTTP/1.1 200 OK\r\nLOCATION: http://10.0.2.2:49152/description.xml\r\n\r\n"));
        check(
                locs.size() == 1 && "http://10.0.2.2:49152/description.xml".equals(locs.get(0)),
                "DlnaCastClient.parseSsdpLocations deduplicates valid LAN devices and drops loopback");

        // 5. DlnaCastClient device.xml parsing + XXE & cross-host SSRF rejection
        String devXml =
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                        + "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
                        + "<device>"
                        + "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
                        + "<friendlyName>客厅极米投影仪</friendlyName>"
                        + "<manufacturer>XGIMI</manufacturer>"
                        + "<UDN>uuid:99887766-5544-3322-1100-aabbccddeeff</UDN>"
                        + "<serviceList><service>"
                        + "<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>"
                        + "<controlURL>/upnp/control/AVTransport</controlURL>"
                        + "</service></serviceList></device></root>";
        DlnaCastClient.Device dev =
                DlnaCastClient.parseDeviceDescriptionXml(
                        "http://10.0.2.2:49152/description.xml", devXml);
        check(
                dev != null
                        && "客厅极米投影仪".equals(dev.friendlyName)
                        && "http://10.0.2.2:49152/upnp/control/AVTransport"
                                .equals(dev.avTransportControlUrl),
                "DlnaCastClient parses LAN MediaRenderer device.xml and resolves AVTransport controlURL");

        String xxeXml = "<?xml version=\"1.0\"?><!DOCTYPE root [<!ENTITY a \"b\">]><root/>";
        check(
                DlnaCastClient.parseDeviceDescriptionXml(
                                "http://10.0.2.2:49152/description.xml", xxeXml)
                        == null,
                "DlnaCastClient rejects DOCTYPE/XXE payloads in device.xml");

        Map<String, String> args = new LinkedHashMap<>();
        args.put("InstanceID", "0");
        args.put("CurrentURI", "https://cdn.example/v.m3u8?a=1&b=2");
        String soap =
                DlnaCastClient.buildSoapEnvelope(
                        DlnaCastClient.ST_AV_TRANSPORT_1, "SetAVTransportURI", args);
        check(
                soap.contains("<u:SetAVTransportURI") && soap.contains("a=1&amp;b=2"),
                "DlnaCastClient.buildSoapEnvelope escapes XML special characters cleanly");
    }

    private static void testDanmakuSanitizationAndParsing() throws Exception {
        Map<String, String> quarkHeaders = new LinkedHashMap<>();
        quarkHeaders.put("Cookie", "__puus=secret; __pus=token");
        quarkHeaders.put("Referer", "https://pan.example/");
        quarkHeaders.put("User-Agent", "Mozilla/5.0 cloud-drive/2.5.20");
        quarkHeaders.put("Range", "bytes=0-1024");
        quarkHeaders.put("Accept-Encoding", "gzip, br");
        quarkHeaders.put("X-Custom-Token", "keep-same-origin");

        Map<String, String> crossOrigin =
                DanmakuView.sanitizeDanmakuHeaders(
                        "https://dm.example/api/v1/danmu?name=顶楼 第一季",
                        "https://dl.pan.example/file/video.mkv",
                        quarkHeaders);
        check(
                !crossOrigin.containsKey("Cookie")
                        && !crossOrigin.containsKey("Referer")
                        && !crossOrigin.containsKey("User-Agent")
                        && !crossOrigin.containsKey("Range")
                        && !crossOrigin.containsKey("Accept-Encoding"),
                "DanmakuView.sanitizeDanmakuHeaders strips cross-origin netdisk cookies, referer, UA, Range, and Accept-Encoding");

        Map<String, String> sameOrigin =
                DanmakuView.sanitizeDanmakuHeaders(
                        "https://cdn.example/dm.xml",
                        "https://cdn.example/video.mp4",
                        quarkHeaders);
        check(
                sameOrigin.containsKey("Cookie")
                        && !sameOrigin.containsKey("Range")
                        && !sameOrigin.containsKey("Accept-Encoding"),
                "DanmakuView.sanitizeDanmakuHeaders preserves same-origin cookies while stripping Range/Accept-Encoding");

        String encoded =
                DanmakuView.encodeDanmakuUrl("https://dm.example/api?title=顶楼 第一季 [4K]&ep=1");
        check(
                !encoded.contains(" ")
                        && !encoded.contains("[")
                        && encoded.contains("%20")
                        && encoded.contains("&ep=1"),
                "DanmakuView.encodeDanmakuUrl percent-encodes Chinese chars, spaces, and brackets cleanly");

        boolean emptyRejected = false;
        try {
            DanmakuData.parse("   \r\n  ");
        } catch (java.io.IOException expected) {
            emptyRejected = expected.getMessage() != null && expected.getMessage().contains("为空");
        }
        check(emptyRejected, "DanmakuData.parse rejects empty response body with clear message");

        String noisyXml =
                "prefix noise <?xml version=\"1.0\" encoding=\"utf-8\"?><i><d p=\"12.5,1,25,16777215,0,0,0,0\">好看</d></i>";
        List<DanmakuData.Comment> parsed = DanmakuData.parse(noisyXml);
        check(
                parsed.size() == 1 && "好看".equals(parsed.get(0).text),
                "DanmakuData.parse skips leading noise before XML payload");

        org.json.JSONObject multiDm =
                new org.json.JSONObject(
                        "{\"danmaku\":[{\"name\":\"自动\",\"url\":\"https://dm1.example/a.xml\"},"
                                + "{\"name\":\"备用\",\"url\":\"https://dm2.example/b.xml\"}]}");
        List<String> extracted = MediaOptions.extractDanmakuUrls(multiDm);
        check(
                extracted.size() == 2
                        && extracted.get(0).contains("dm1.example")
                        && extracted.get(1).contains("dm2.example"),
                "MediaOptions.extractDanmakuUrls preserves all danmaku array candidates for automatic failover");

        org.json.JSONObject hashDm =
                new org.json.JSONObject(
                        "{\"danmu\":\"线路1$https://dm1.example/1.xml#线路2$https://dm2.example/2.xml\"}");
        List<String> hashExtracted = MediaOptions.extractDanmakuUrls(hashDm);
        check(
                hashExtracted.size() == 2
                        && "https://dm1.example/1.xml".equals(hashExtracted.get(0))
                        && "https://dm2.example/2.xml".equals(hashExtracted.get(1)),
                "MediaOptions.extractDanmakuUrls parses name$url#name$url multi-route danmaku strings");
    }

    private static void testCuratedShelfComfortWindowAndScopedFocusFrame() {
        // Curated shelf cards at leftPad=88, slotStep=300, maxScroll=3000.
        // Card 1 (left=88), Card 2 (left=388), Card 3 (left=688) must NOT scroll from scrollX=0!
        int pad = 88;
        int step = 300;
        int max = 3000;
        check(
                HomeScreen.computeShelfScrollX(0, pad, step, pad, max) == 0
                        && HomeScreen.computeShelfScrollX(0, pad + step, step, pad, max) == 0
                        && HomeScreen.computeShelfScrollX(0, pad + step * 2, step, pad, max) == 0,
                "HomeScreen.computeShelfScrollX keeps focus free across cards 1-3 without shifting row");

        // Moving right to Card 4 (left=988) shifts row by 1 step so Card 4 rests in slot 3.
        int afterCard4 = HomeScreen.computeShelfScrollX(0, pad + step * 3, step, pad, max);
        check(
                afterCard4 == step,
                "HomeScreen.computeShelfScrollX advances cleanly by one slot when reaching card 4");

        // Moving back left from Card 4 -> Card 3 (slot 2) -> Card 2 (slot 1) must stay stationary!
        check(
                HomeScreen.computeShelfScrollX(afterCard4, pad + step * 2, step, pad, max) == step
                        && HomeScreen.computeShelfScrollX(afterCard4, pad + step, step, pad, max)
                                == step,
                "HomeScreen.computeShelfScrollX allows returning across slots 3->2->1 without bouncing row");

        // Moving left past slot 1 back to Card 1 (left=pad) shifts row back to 0.
        check(
                HomeScreen.computeShelfScrollX(afterCard4, pad, step, pad, max) == 0,
                "HomeScreen.computeShelfScrollX scrolls back left when moving past slot 1");

        // Clamps safely at maxScroll and handles short rows (maxScroll == 0).
        check(
                HomeScreen.computeShelfScrollX(2900, pad + step * 15, step, pad, max) == max
                        && HomeScreen.computeShelfScrollX(0, pad + step * 4, step, pad, 0) == 0,
                "HomeScreen.computeShelfScrollX clamps cleanly at maxScroll bounds");

        // Scoped TvFocusFrame: glide ONLY within same poster group and nearby neighbor cards.
        check(
                TvFocusFrame.shouldGlideBetween(
                                "home-curated-drama",
                                "home-curated-drama",
                                200f,
                                500f,
                                500f,
                                500f,
                                260f,
                                380f)
                        && TvFocusFrame.shouldGlideBetween(
                                "home-library-grid",
                                "home-library-grid",
                                400f,
                                300f,
                                400f,
                                720f,
                                260f,
                                380f),
                "TvFocusFrame glides cleanly between adjacent cards in the same shelf or grid");

        // Cross-group jumps (drama -> movie, movie -> library, or null group) must NOT fly!
        check(
                !TvFocusFrame.shouldGlideBetween(
                                "home-curated-drama",
                                "home-curated-movie",
                                200f,
                                500f,
                                200f,
                                920f,
                                260f,
                                380f)
                        && !TvFocusFrame.shouldGlideBetween(
                                null, "home-curated-drama", 200f, 500f, 200f, 500f, 260f, 380f)
                        && !TvFocusFrame.shouldGlideBetween(
                                "home-library-grid",
                                "home-library-grid",
                                1500f,
                                300f,
                                200f,
                                720f,
                                260f,
                                380f),
                "TvFocusFrame snaps instead of flying diagonally across sections or row wraps");
    }

    private static void testCrashHardeningMiniDetailsAndHudRedesign() throws Exception {
        // 1. Cms.Site non-null defaults prevent PlaybackController/SourceController NPEs
        Cms.Site blankSite = new Cms.Site();
        check(
                "".equals(blankSite.key)
                        && "".equals(blankSite.name)
                        && "".equals(blankSite.api)
                        && "".equals(blankSite.playUrl)
                        && "".equals(blankSite.jar),
                "Cms.Site initializes string fields to non-null empty strings");

        // 2. Startup prewarm only triggers for lightweight HTTP JSON/T4 sites, never heavy plugins
        Cms.Site httpSite = new Cms.Site();
        httpSite.key = "http1";
        httpSite.type = 1;
        httpSite.api = "https://cms.example/api.php/provide/list/";
        Cms.Site cspSite = new Cms.Site();
        cspSite.key = "csp1";
        cspSite.type = 3;
        cspSite.api = "csp_AppYs";
        Cms.Site catpawSite = new Cms.Site();
        catpawSite.key = "cp1";
        catpawSite.type = 3;
        catpawSite.api = "catpaw://site/1";
        check(
                MainActivity.shouldPrewarmSiteOnStartup(httpSite)
                        && !MainActivity.shouldPrewarmSiteOnStartup(cspSite)
                        && !MainActivity.shouldPrewarmSiteOnStartup(catpawSite)
                        && !MainActivity.shouldPrewarmSiteOnStartup(null),
                "MainActivity.shouldPrewarmSiteOnStartup excludes heavy CSP/CatPaw plugin runtimes");

        // 3. Startup boot-guard crash-loop circuit breaker & volatile cache purge
        java.io.File tempDir =
                java.nio.file.Files.createTempDirectory("marco-boot-guard-test-").toFile();
        try {
            java.io.File snap = new java.io.File(tempDir, "home_snap_v1");
            snap.mkdirs();
            new java.io.File(snap, "a.json").createNewFile();
            java.io.File wide = new java.io.File(tempDir, "tv_wide_v5_abc.img");
            wide.createNewFile();
            java.io.File keep = new java.io.File(tempDir, "unrelated_keep.txt");
            keep.createNewFile();

            int c0 = MainActivity.recordStartupBootGuard(tempDir);
            int c1 = MainActivity.recordStartupBootGuard(tempDir);
            int c2 = MainActivity.recordStartupBootGuard(tempDir);
            MainActivity.purgeVolatileCrashCaches(tempDir);
            MainActivity.clearStartupBootGuard(tempDir);
            int afterClear = MainActivity.recordStartupBootGuard(tempDir);
            check(
                    c0 == 0
                            && c1 == 1
                            && c2 == 2
                            && afterClear == 0
                            && !snap.exists()
                            && !wide.exists()
                            && keep.exists(),
                    "Startup crash-loop circuit breaker tracks streak, purges volatile caches, and clears cleanly");
        } finally {
            MainActivity.clearStartupBootGuard(tempDir);
            java.io.File[] children = tempDir.listFiles();
            if (children != null) {
                for (java.io.File f : children) f.delete();
            }
            tempDir.delete();
        }

        // 4. TvDetailHost curated source bounding excludes heavy CatPaw/Drpy/Js/Guard fan-out and
        // caps to 4
        java.util.List<Cms.Site> pool = new java.util.ArrayList<>();
        pool.add(catpawSite);
        Cms.Site drpySite = new Cms.Site();
        drpySite.key = "drpy1";
        drpySite.type = 3;
        drpySite.api = "https://cdn.example/drpy_libs/drpy2.min.js";
        pool.add(drpySite);
        Cms.Site jsSite = new Cms.Site();
        jsSite.key = "js1";
        jsSite.type = 3;
        jsSite.api = "https://cdn.example/spider.js";
        pool.add(jsSite);
        for (int i = 0; i < 8; i++) {
            Cms.Site s = new Cms.Site();
            s.key = "http_" + i;
            s.type = 1;
            s.api = "https://cdn.example/s" + i + "/api.php/provide/list/";
            pool.add(s);
        }
        List<Cms.Site> bounded =
                TvDetailHost.selectCuratedSearchSources(
                        pool, "http_5", TvDetailHost.CURATED_MAX_SOURCES);
        boolean hasHeavy = false;
        for (Cms.Site s : bounded) {
            if ("cp1".equals(s.key) || "drpy1".equals(s.key) || "js1".equals(s.key)) {
                hasHeavy = true;
            }
        }
        List<Cms.Site> heavyOnly =
                TvDetailHost.selectCuratedSearchSources(
                        Arrays.asList(catpawSite, drpySite, jsSite),
                        "",
                        TvDetailHost.CURATED_MAX_SOURCES);
        check(
                bounded.size() == TvDetailHost.CURATED_MAX_SOURCES
                        && "http_5".equals(bounded.get(0).key)
                        && !hasHeavy
                        && heavyOnly.size() == 1
                        && TvDetailHost.CURATED_MAX_CONCURRENCY == 1,
                "TvDetailHost bounds curated fallback to 4 light sources with concurrency 1 and skips heavy Node/JS/Guard runtimes");

        // 5. Cast avatar accent handles Integer.MIN_VALUE hashCode ("polygenelubricants") safely
        int minHashAccent = TvV17DetailScreen.castAvatarAccent("polygenelubricants");
        int nullAccent = TvV17DetailScreen.castAvatarAccent(null);
        check(
                "polygenelubricants".hashCode() == Integer.MIN_VALUE
                        && minHashAccent != 0
                        && nullAccent != 0,
                "TvV17DetailScreen.castAvatarAccent handles Integer.MIN_VALUE hashCode and null safely");

        // 6. ImmersivePoster byte-bounded caches stay within tight low-RAM TV budgets
        check(
                ImmersivePoster.WIDE_MEM_CACHE_MAX_BYTES <= 12 * 1024 * 1024
                        && ImmersivePoster.HERO_FEATHERED_CACHE_MAX_BYTES <= 8 * 1024 * 1024
                        && ImmersivePoster.PORTRAIT_HD_MEM_CACHE_MAX_BYTES <= 10 * 1024 * 1024,
                "ImmersivePoster bitmap caches are byte-bounded for low-RAM TVs");

        // 7. MiniDetails collapses episodes/seasons into popup triggers beside Return-to-Playback
        check(
                MiniDetails.INLINE_EPISODES_COLLAPSED
                        && "mini-episodes-trigger".equals(MiniDetails.TAG_EPISODES_TRIGGER)
                        && "mini-seasons-trigger".equals(MiniDetails.TAG_SEASONS_TRIGGER),
                "MiniDetails keeps episodes and seasons collapsed behind popup triggers");

        // 8. Top-right TV HUD is frameless with clearly distinct font family & scale for clock vs
        // progress
        check(
                PlayerChrome.TV_TOP_RIGHT_HUD_FRAMELESS
                        && !PlayerChrome.HUD_CLOCK_FONT_FAMILY.equals(
                                PlayerChrome.HUD_PROGRESS_FONT_FAMILY)
                        && PlayerChrome.HUD_CLOCK_SIZE_U >= PlayerChrome.HUD_PROGRESS_SIZE_U + 3.0f,
                "PlayerChrome TV top-right HUD is frameless with distinct typography for current time vs progress");
    }
}

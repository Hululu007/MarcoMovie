package com.pilipala.marcomovie;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Zero-config iOS-parity curated discovery catalog service (native Android port of {@code
 * CuratedDiscoveryService} in {@code flutter/lib/core/curated_discovery.dart}).
 *
 * <p>Architectural boundary:
 *
 * <ul>
 *   <li>Supplies ONLY public metadata lists across all 8 curated iOS collections (titles, ratings,
 *       years, genres, backdrops & posters from approved Douban metadata endpoints + offline seeds)
 *       — requires ZERO TMDB or IMDb API keys.
 *   <li>NEVER ships or plays built-in stream URLs. Tapping any curated item opens {@link
 *       MobileDetailScreen} with {@link #curatedSiteSentinel()}, which searches ONLY the user's own
 *       added subscription sources to resolve playable lines & episodes.
 * </ul>
 */
final class MobileCuratedDiscovery {
    static final String SENTINEL_SITE_KEY = "__curated_discovery__";
    static final String ID_CN_HOT = "cn_hot";
    static final String ID_WEEKLY_TRENDING = "weekly_trending";
    static final String ID_CN_VARIETY = "cn_variety";
    static final String ID_DOUBAN_TOP = "douban_top";
    static final String ID_ROTTEN_TOMATOES = "rotten_tomatoes";
    static final String ID_DISNEY = "disney";
    static final String ID_MARVEL = "marvel";
    static final String ID_DC = "dc";

    private static final long CACHE_TTL_MS = 30L * 60L * 1000L;
    private static final String MOBILE_UA =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
                    + " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

    private static final Pattern TAG_NOISE =
            Pattern.compile(
                    "(?i)[\\(\\[（【].*?(?:4k|hdr|臻彩|杜比|蓝光|国语|粤语|中字|未删减|完整版|高清|hd|1080p|2160p|抢先|tc|ts).*?[\\)\\]）】]");
    private static final Pattern PUNCT_NOISE = Pattern.compile("[\\s:：·\\-—_,.，。!！?？《》「」]+");
    private static final Pattern MOTION_COMIC = Pattern.compile("(?:动态漫|动态漫画|有声漫|解说|沙雕动画)");

    static final class ModuleSpec {
        final String id;
        final String title;
        final String subtitle;
        final String badgeText;
        final int iconId;
        final int accentColor;
        final String liveUrl;
        final String referer;
        final List<Cms.Video> seedItems;

        ModuleSpec(
                String id,
                String title,
                String subtitle,
                String badgeText,
                int iconId,
                int accentColor,
                String liveUrl,
                String referer,
                List<Cms.Video> seedItems) {
            this.id = id;
            this.title = title;
            this.subtitle = subtitle;
            this.badgeText = badgeText;
            this.iconId = iconId;
            this.accentColor = accentColor;
            this.liveUrl = liveUrl;
            this.referer = referer;
            this.seedItems = Collections.unmodifiableList(seedItems);
        }
    }

    private static final class CacheEntry {
        final long fetchedAtMs;
        final List<Cms.Video> items;

        CacheEntry(long fetchedAtMs, List<Cms.Video> items) {
            this.fetchedAtMs = fetchedAtMs;
            this.items = items;
        }
    }

    private static final Map<String, CacheEntry> CACHE = new ConcurrentHashMap<>();
    private static final Map<String, String> BACKDROP_BY_ID = new ConcurrentHashMap<>();
    private static final Map<String, String> GENRE_BY_ID = new ConcurrentHashMap<>();
    private static volatile boolean diskHydrated = false;
    static final List<ModuleSpec> MODULES = buildModules();

    private MobileCuratedDiscovery() {}

    /**
     * Hydrates cached curated module posters &amp; items from disk once on cold start so frame 1
     * displays last session's posters immediately before background refresh completes.
     */
    static void hydrateFromDiskIfNeeded(MainActivity a) {
        if (diskHydrated || a == null || a.privateMode) return;
        diskHydrated = true;
        try {
            java.io.File f = new java.io.File(a.getCacheDir(), "curated_discovery_v1.json");
            if (!f.isFile() || f.length() <= 2 || f.length() > 1024 * 1024) return;
            if (System.currentTimeMillis() - f.lastModified() > 7L * 24 * 3600 * 1000L) return;
            String raw;
            try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
                raw = Cms.read(in, 1024 * 1024);
            }
            JSONObject root = new JSONObject(raw);
            long savedAt = root.optLong("savedAt", f.lastModified());
            JSONObject mods = root.optJSONObject("modules");
            if (mods == null) return;
            for (ModuleSpec spec : MODULES) {
                if (CACHE.containsKey(spec.id)) continue;
                JSONArray arr = mods.optJSONArray(spec.id);
                if (arr == null || arr.length() == 0) continue;
                List<Cms.Video> items = new ArrayList<>();
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject vj = arr.optJSONObject(i);
                    if (vj == null) continue;
                    Cms.Video v = new Cms.Video();
                    v.id = vj.optString("id", "");
                    v.title = vj.optString("title", "");
                    v.poster = vj.optString("poster", "");
                    v.remarks = vj.optString("remarks", "");
                    v.year = vj.optString("year", "");
                    v.area = vj.optString("area", "");
                    v.genre = vj.optString("genre", "");
                    v.description = vj.optString("description", "");
                    String bd = vj.optString("backdrop", "");
                    if (!v.id.isEmpty() && !bd.isEmpty()) BACKDROP_BY_ID.put(v.id, bd);
                    if (!v.id.isEmpty() && !v.genre.isEmpty()) GENRE_BY_ID.put(v.id, v.genre);
                    if (!v.id.isEmpty() && !v.title.isEmpty()) items.add(v);
                }
                if (!items.isEmpty()) {
                    // Mark fetchedAtMs = 0 so fetchAllAsync still silently refreshes in background.
                    CACHE.put(spec.id, new CacheEntry(0L, items));
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private static void saveToDisk(MainActivity a) {
        if (a == null || a.privateMode || CACHE.isEmpty()) return;
        try {
            JSONObject root = new JSONObject();
            root.put("savedAt", System.currentTimeMillis());
            JSONObject mods = new JSONObject();
            for (ModuleSpec spec : MODULES) {
                CacheEntry entry = CACHE.get(spec.id);
                if (entry == null || entry.items == null || entry.items.isEmpty()) continue;
                JSONArray arr = new JSONArray();
                int limit = Math.min(24, entry.items.size());
                for (int i = 0; i < limit; i++) {
                    Cms.Video v = entry.items.get(i);
                    if (v == null) continue;
                    JSONObject vj = new JSONObject();
                    vj.put("id", v.id == null ? "" : v.id);
                    vj.put("title", v.title == null ? "" : v.title);
                    vj.put("poster", v.poster == null ? "" : v.poster);
                    vj.put("remarks", v.remarks == null ? "" : v.remarks);
                    vj.put("year", v.year == null ? "" : v.year);
                    vj.put("area", v.area == null ? "" : v.area);
                    vj.put("genre", v.genre == null ? "" : v.genre);
                    vj.put("description", v.description == null ? "" : v.description);
                    String bd = v.id != null ? BACKDROP_BY_ID.get(v.id) : null;
                    if (bd != null && !bd.isEmpty()) vj.put("backdrop", bd);
                    arr.put(vj);
                }
                mods.put(spec.id, arr);
            }
            root.put("modules", mods);
            java.io.File f = new java.io.File(a.getCacheDir(), "curated_discovery_v1.json");
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(f)) {
                out.write(root.toString().getBytes(StandardCharsets.UTF_8));
            }
        } catch (Throwable ignored) {
        }
    }

    static Cms.Site curatedSiteSentinel() {
        Cms.Site s = new Cms.Site();
        s.key = SENTINEL_SITE_KEY;
        s.name = "精选发现";
        s.type = 1;
        s.api = "";
        s.searchable = false;
        return s;
    }

    static boolean isCuratedSite(Cms.Site site) {
        return site != null && SENTINEL_SITE_KEY.equals(site.key);
    }

    static ModuleSpec moduleById(String id) {
        if (id != null) {
            for (ModuleSpec spec : MODULES) {
                if (id.equals(spec.id)) return spec;
            }
        }
        return MODULES.get(0);
    }

    static String backdropFor(Cms.Video video) {
        if (video == null) return "";
        String hit = video.id != null ? BACKDROP_BY_ID.get(video.id) : null;
        if (hit != null && !hit.isEmpty()) return hit;
        return video.poster == null ? "" : video.poster;
    }

    static String genreFor(Cms.Video video) {
        if (video == null || video.id == null) return "";
        String g = GENRE_BY_ID.get(video.id);
        return g == null ? "" : g;
    }

    static void clearCache() {
        CACHE.clear();
        BACKDROP_BY_ID.clear();
        GENRE_BY_ID.clear();
    }

    static List<Cms.Video> peekModule(ModuleSpec spec) {
        if (spec == null) return Collections.emptyList();
        CacheEntry hit = CACHE.get(spec.id);
        if (hit != null && !hit.items.isEmpty()) return hit.items;
        return spec.seedItems;
    }

    static List<Cms.Video> peekById(String id) {
        return peekModule(moduleById(id));
    }

    static List<Cms.Video> fetchModuleSync(ModuleSpec spec, boolean forceRefresh) {
        if (spec == null) return Collections.emptyList();
        CacheEntry hit = CACHE.get(spec.id);
        if (!forceRefresh
                && hit != null
                && !hit.items.isEmpty()
                && (System.currentTimeMillis() - hit.fetchedAtMs) < CACHE_TTL_MS) {
            return hit.items;
        }
        if (spec.liveUrl == null || spec.liveUrl.isEmpty()) {
            return spec.seedItems;
        }
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(spec.liveUrl).openConnection();
            conn.setConnectTimeout(4000);
            conn.setReadTimeout(5000);
            conn.setRequestProperty("User-Agent", MOBILE_UA);
            conn.setRequestProperty("Referer", spec.referer);
            conn.setRequestProperty("Accept", "application/json");
            if (conn.getResponseCode() == 200) {
                try (InputStream in = conn.getInputStream()) {
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                    String body = new String(out.toByteArray(), StandardCharsets.UTF_8);
                    List<Cms.Video> parsed = parseDoubanDiscoveryJson(body, spec.id);
                    if (!parsed.isEmpty()) {
                        CACHE.put(spec.id, new CacheEntry(System.currentTimeMillis(), parsed));
                        return parsed;
                    }
                }
            }
        } catch (Throwable ignored) {
        } finally {
            if (conn != null) conn.disconnect();
        }
        return hit != null && !hit.items.isEmpty() ? hit.items : spec.seedItems;
    }

    /** Fetches all curated modules on background threads and notifies UI cleanly per module. */
    static void fetchAllAsync(
            final MainActivity a, final int ticket, final Runnable onModuleUpdated) {
        if (a == null) return;
        for (final ModuleSpec spec : MODULES) {
            a.submitPage(
                    () -> {
                        List<Cms.Video> items = fetchModuleSync(spec, false);
                        if (items != null && !items.isEmpty()) {
                            saveToDisk(a);
                            a.ui.post(
                                    () -> {
                                        if (!a.isFinishing()
                                                && ticket == a.generation
                                                && onModuleUpdated != null) {
                                            onModuleUpdated.run();
                                        }
                                    });
                        }
                    });
        }
    }

    /**
     * Pure-JVM parser for Douban Rexxar {@code subject_collection_items} and {@code
     * new_search_subjects} JSON payloads into {@link Cms.Video} metadata items.
     */
    static List<Cms.Video> parseDoubanDiscoveryJson(String jsonText, String moduleId) {
        if (jsonText == null || jsonText.trim().isEmpty()) return Collections.emptyList();
        try {
            JSONObject root = new JSONObject(jsonText);
            JSONArray rawList = root.optJSONArray("subject_collection_items");
            if (rawList == null) rawList = root.optJSONArray("data");
            if (rawList == null || rawList.length() == 0) return Collections.emptyList();

            List<Cms.Video> out = new ArrayList<>();
            Set<String> seen = new LinkedHashSet<>();
            for (int i = 0; i < rawList.length(); i++) {
                JSONObject raw = rawList.optJSONObject(i);
                if (raw == null) continue;
                String title = raw.optString("title", "").trim();
                if (title.isEmpty() || !seen.add(title)) continue;

                String id = raw.optString("id", "").trim();
                String poster = "";
                JSONObject pic = raw.optJSONObject("pic");
                if (pic != null) {
                    poster = pic.optString("large", "").trim();
                    if (poster.isEmpty()) poster = pic.optString("normal", "").trim();
                }
                if (poster.isEmpty()) {
                    JSONObject coverObj = raw.optJSONObject("cover");
                    if (coverObj != null) {
                        poster = coverObj.optString("url", "").trim();
                    } else {
                        poster = raw.optString("cover", "").trim();
                    }
                }
                if (poster.contains("/s_ratio_poster/")) {
                    poster = poster.replace("/s_ratio_poster/", "/m_ratio_poster/");
                }

                String backdrop = "";
                JSONArray photos = raw.optJSONArray("photos");
                if (photos != null) {
                    for (int pi = 0; pi < photos.length(); pi++) {
                        Object entry = photos.opt(pi);
                        String u = "";
                        if (entry instanceof String) {
                            u = ((String) entry).trim();
                        } else if (entry instanceof JSONObject) {
                            u = ((JSONObject) entry).optString("url", "").trim();
                        }
                        if (!u.isEmpty()) {
                            backdrop = u;
                            break;
                        }
                    }
                }

                double score = 0.0;
                JSONObject rating = raw.optJSONObject("rating");
                if (rating != null) {
                    double v = rating.optDouble("value", 0.0);
                    if (!Double.isNaN(v) && v > 0.0) score = v;
                } else {
                    String rateStr = raw.optString("rate", "").trim();
                    if (!rateStr.isEmpty()) {
                        try {
                            double v = Double.parseDouble(rateStr);
                            if (v > 0.0) score = v;
                        } catch (NumberFormatException ignored) {
                        }
                    }
                }

                String year = raw.optString("year", "").trim();
                String cardSub = raw.optString("card_subtitle", "").trim();
                String parsedArea = "";
                String parsedGenre = "";
                if (!cardSub.isEmpty()) {
                    String[] parts = cardSub.split("/");
                    List<String> cleanParts = new ArrayList<>();
                    for (String p : parts) {
                        String t = p.trim();
                        if (!t.isEmpty()) cleanParts.add(t);
                    }
                    if (cleanParts.size() >= 2) parsedArea = cleanParts.get(1);
                    if (cleanParts.size() >= 3) {
                        String[] gTokens = cleanParts.get(2).split("\\s+");
                        StringBuilder gb = new StringBuilder();
                        int gCount = 0;
                        for (String gt : gTokens) {
                            if (gt.isEmpty()) continue;
                            if (gCount > 0) gb.append(" / ");
                            gb.append(gt);
                            gCount++;
                            if (gCount >= 2) break;
                        }
                        parsedGenre = gb.toString();
                    }
                }

                StringBuilder actorSb = new StringBuilder();
                JSONArray actorsRaw = raw.optJSONArray("actors");
                if (actorsRaw == null) actorsRaw = raw.optJSONArray("casts");
                if (actorsRaw != null) {
                    for (int ai = 0; ai < actorsRaw.length() && ai < 5; ai++) {
                        String act = actorsRaw.optString(ai, "").trim();
                        if (act.isEmpty()) continue;
                        if (actorSb.length() > 0) actorSb.append(", ");
                        actorSb.append(act);
                    }
                }

                String remarks;
                if (score > 0.0) {
                    remarks = String.format(Locale.US, "豆瓣 %.1f", score);
                } else if (!parsedGenre.isEmpty()) {
                    remarks = parsedGenre;
                } else {
                    remarks = year;
                }

                String videoId =
                        !id.isEmpty()
                                ? ("curated:" + moduleId + ":" + id)
                                : ("curated:" + moduleId + ":" + out.size());
                if (!backdrop.isEmpty()) {
                    BACKDROP_BY_ID.put(videoId, backdrop);
                }
                if (!parsedGenre.isEmpty()) {
                    GENRE_BY_ID.put(videoId, parsedGenre);
                }

                Cms.Video v = new Cms.Video();
                v.id = videoId;
                v.title = title;
                v.poster = poster;
                v.remarks = remarks;
                v.year = year;
                v.area = parsedArea;
                v.actor = actorSb.toString();
                v.description = cardSub;
                out.add(v);
                if (out.size() >= 16) break;
            }
            return out;
        } catch (Throwable ignored) {
            return Collections.emptyList();
        }
    }

    /** Pure-JVM fuzzy key normalizer matching iOS {@code CuratedDiscoveryService.normalizeMatchKey}. */
    static String normalizeMatchKey(String title) {
        if (title == null) return "";
        String s = title.trim().toLowerCase(Locale.ROOT);
        s =
                s.replace("第一季", "1")
                        .replace("第二季", "2")
                        .replace("第三季", "3")
                        .replace("第四季", "4")
                        .replace("第五季", "5")
                        .replace("第一部", "1")
                        .replace("第二部", "2")
                        .replace("第三部", "3");
        s = TAG_NOISE.matcher(s).replaceAll("");
        s = PUNCT_NOISE.matcher(s).replaceAll("");
        return s;
    }

    /**
     * Pure-JVM title relevance scorer (0..100) so resolving a curated item against the user's added
     * subscription sources picks the exact movie or series first.
     */
    static int titleMatchScore(String targetTitle, String candidateTitle) {
        if (targetTitle == null || candidateTitle == null) return 0;
        boolean targetMc = MOTION_COMIC.matcher(targetTitle).find();
        boolean candMc = MOTION_COMIC.matcher(candidateTitle).find();
        if (targetMc != candMc) return 0;
        String a = normalizeMatchKey(targetTitle);
        String b = normalizeMatchKey(candidateTitle);
        if (a.isEmpty() || b.isEmpty()) return 0;
        if (a.equals(b)) return 100;
        if (b.startsWith(a) || a.startsWith(b)) return 80;
        if (b.contains(a) || a.contains(b)) return 60;
        return 0;
    }

    private static Cms.Video seed(
            String id, String title, String year, String area, String remarks, String actor) {
        Cms.Video v = new Cms.Video();
        v.id = id;
        v.title = title;
        v.year = year;
        v.area = area;
        v.remarks = remarks;
        v.actor = actor;
        return v;
    }

    private static List<ModuleSpec> buildModules() {
        return Collections.unmodifiableList(
                Arrays.asList(
                        new ModuleSpec(
                                ID_CN_HOT,
                                "近期国内热门",
                                "近一月 · 热播剧集与华语口碑新作",
                                "热播",
                                MobileIcons.IC_SPARKLE,
                                0xFFFF5E3A,
                                "https://m.douban.com/rexxar/api/v2/subject_collection/tv_hot/items?start=0&count=16",
                                "https://m.douban.com/tv/chinese",
                                Arrays.asList(
                                        seed(
                                                "curated:cn:1",
                                                "漫长的季节",
                                                "2023",
                                                "中国大陆",
                                                "豆瓣 9.4",
                                                "范伟, 秦昊, 陈明昊"),
                                        seed(
                                                "curated:cn:2",
                                                "庆余年 第二季",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 7.3",
                                                "张若昀, 李沁, 陈道明"),
                                        seed(
                                                "curated:cn:3",
                                                "繁花",
                                                "2023",
                                                "中国大陆",
                                                "豆瓣 8.7",
                                                "胡歌, 马伊琍, 唐嫣"),
                                        seed(
                                                "curated:cn:4",
                                                "我的阿勒泰",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 8.9",
                                                "马伊琍, 周依然, 于适"),
                                        seed(
                                                "curated:cn:5",
                                                "唐朝诡事录之西行",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 8.6",
                                                "杨旭文, 杨志刚"),
                                        seed(
                                                "curated:cn:6",
                                                "三体",
                                                "2023",
                                                "中国大陆",
                                                "豆瓣 8.7",
                                                "张鲁一, 于和伟, 陈瑾"),
                                        seed(
                                                "curated:cn:7",
                                                "狂飙",
                                                "2023",
                                                "中国大陆",
                                                "豆瓣 8.5",
                                                "张译, 张颂文, 李一桐"),
                                        seed(
                                                "curated:cn:8",
                                                "山花烂漫时",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 9.6",
                                                "宋佳, 兰西雅, 都兰"))),
                        new ModuleSpec(
                                ID_WEEKLY_TRENDING,
                                "本周趋势",
                                "院线热映与近期飙升佳作",
                                "趋势",
                                MobileIcons.IC_PLAY,
                                0xFFFF9F0A,
                                "https://m.douban.com/rexxar/api/v2/subject_collection/movie_hot_gaia/items?start=0&count=16",
                                "https://m.douban.com/movie/",
                                Arrays.asList(
                                        seed(
                                                "curated:tr:1",
                                                "沙丘2",
                                                "2024",
                                                "美国",
                                                "豆瓣 8.2",
                                                "提莫西·查拉梅, 赞达亚"),
                                        seed(
                                                "curated:tr:2",
                                                "奥本海默",
                                                "2023",
                                                "美国",
                                                "豆瓣 8.8",
                                                "基里安·墨菲, 艾米莉·布朗特"),
                                        seed(
                                                "curated:tr:3",
                                                "周处除三害",
                                                "2023",
                                                "中国台湾",
                                                "豆瓣 8.1",
                                                "阮经天, 袁富华"),
                                        seed(
                                                "curated:tr:4",
                                                "九龙城寨之围城",
                                                "2024",
                                                "中国香港",
                                                "豆瓣 7.3",
                                                "古天乐, 洪金宝, 林峯"),
                                        seed(
                                                "curated:tr:5",
                                                "头脑特工队2",
                                                "2024",
                                                "美国",
                                                "豆瓣 8.4",
                                                "艾米·波勒, 玛雅·霍克"),
                                        seed(
                                                "curated:tr:6",
                                                "荒野机器人",
                                                "2024",
                                                "美国",
                                                "豆瓣 8.0",
                                                "露皮塔·尼永奥, 佩德罗·帕斯卡"),
                                        seed(
                                                "curated:tr:7",
                                                "流浪地球2",
                                                "2023",
                                                "中国大陆",
                                                "豆瓣 8.3",
                                                "吴京, 刘德华, 李雪健"),
                                        seed(
                                                "curated:tr:8",
                                                "好东西",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 9.1",
                                                "宋佳, 钟楚曦, 曾慕梅"))),
                        new ModuleSpec(
                                ID_CN_VARIETY,
                                "近一月 · 热门综艺",
                                "真人秀与热门口碑综艺合集",
                                "综艺",
                                MobileIcons.IC_LIVE,
                                0xFFBF5AF2,
                                "https://m.douban.com/rexxar/api/v2/subject_collection/show_domestic/items?start=0&count=16",
                                "https://m.douban.com/tv/variety",
                                Arrays.asList(
                                        seed(
                                                "curated:vr:1",
                                                "现在就出发",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 8.3",
                                                "沈腾, 白敬亭, 金晨"),
                                        seed(
                                                "curated:vr:2",
                                                "花儿与少年·丝路季",
                                                "2023",
                                                "中国大陆",
                                                "豆瓣 9.2",
                                                "秦海璐, 秦岚, 辛芷蕾"),
                                        seed(
                                                "curated:vr:3",
                                                "毛雪汪",
                                                "2021",
                                                "中国大陆",
                                                "豆瓣 8.6",
                                                "毛不易, 李雪琴"),
                                        seed(
                                                "curated:vr:4",
                                                "喜人奇妙夜",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 8.0",
                                                "马东, 黄渤, 秦昊"),
                                        seed(
                                                "curated:vr:5",
                                                "种地吧",
                                                "2023",
                                                "中国大陆",
                                                "豆瓣 9.0",
                                                "蒋敦豪, 鹭卓, 李耕耘"),
                                        seed(
                                                "curated:vr:6",
                                                "大侦探",
                                                "2024",
                                                "中国大陆",
                                                "豆瓣 8.4",
                                                "何炅, 张若昀, 大张伟"))),
                        new ModuleSpec(
                                ID_DOUBAN_TOP,
                                "豆瓣高分",
                                "豆瓣影迷公认必看佳片",
                                "豆瓣",
                                MobileIcons.IC_STAR,
                                0xFF00B51D,
                                "https://m.douban.com/rexxar/api/v2/subject_collection/movie_top250/items?start=0&count=16",
                                "https://m.douban.com/movie/top250",
                                Arrays.asList(
                                        seed(
                                                "curated:db:1",
                                                "肖申克的救赎",
                                                "1994",
                                                "美国",
                                                "豆瓣 9.7",
                                                "蒂姆·罗宾斯, 摩根·弗里曼"),
                                        seed(
                                                "curated:db:2",
                                                "霸王别姬",
                                                "1993",
                                                "中国香港",
                                                "豆瓣 9.6",
                                                "张国荣, 张丰毅, 巩俐"),
                                        seed(
                                                "curated:db:3",
                                                "星际穿越",
                                                "2014",
                                                "美国",
                                                "豆瓣 9.4",
                                                "马修·麦康纳, 安妮·海瑟薇"),
                                        seed(
                                                "curated:db:4",
                                                "盗梦空间",
                                                "2010",
                                                "美国",
                                                "豆瓣 9.4",
                                                "莱昂纳多·迪卡普里奥"),
                                        seed(
                                                "curated:db:5",
                                                "千与千寻",
                                                "2001",
                                                "日本",
                                                "豆瓣 9.4",
                                                "柊瑠美, 入野自由"),
                                        seed(
                                                "curated:db:6",
                                                "楚门的世界",
                                                "1998",
                                                "美国",
                                                "豆瓣 9.4",
                                                "金·凯瑞, 劳拉·琳妮"),
                                        seed(
                                                "curated:db:7",
                                                "海上钢琴师",
                                                "1998",
                                                "意大利",
                                                "豆瓣 9.3",
                                                "蒂姆·罗斯, 普路特·泰勒·文斯"),
                                        seed(
                                                "curated:db:8",
                                                "让子弹飞",
                                                "2010",
                                                "中国大陆",
                                                "豆瓣 9.0",
                                                "姜文, 葛优, 周润发"))),
                        new ModuleSpec(
                                ID_ROTTEN_TOMATOES,
                                "口碑新片",
                                "全球影评高分口碑榜单",
                                "口碑",
                                MobileIcons.IC_HEART_FILLED,
                                0xFFFA320A,
                                "https://m.douban.com/rexxar/api/v2/subject_collection/movie_score/items?start=0&count=16",
                                "https://m.douban.com/movie/",
                                Arrays.asList(
                                        seed(
                                                "curated:rt:1",
                                                "寄生虫",
                                                "2019",
                                                "韩国",
                                                "豆瓣 8.8",
                                                "宋康昊, 李善均"),
                                        seed(
                                                "curated:rt:2",
                                                "蜘蛛侠：纵横宇宙",
                                                "2023",
                                                "美国",
                                                "豆瓣 8.5",
                                                "沙梅克·摩尔, 海莉·斯坦菲尔德"),
                                        seed(
                                                "curated:rt:3",
                                                "疯狂的麦克斯4：狂暴之路",
                                                "2015",
                                                "澳大利亚",
                                                "豆瓣 8.7",
                                                "汤姆·哈迪, 查理兹·塞隆"),
                                        seed(
                                                "curated:rt:4",
                                                "壮志凌云2：独行侠",
                                                "2022",
                                                "美国",
                                                "豆瓣 8.0",
                                                "汤姆·克鲁斯, 迈尔斯·特勒"),
                                        seed(
                                                "curated:rt:5",
                                                "瞬息全宇宙",
                                                "2022",
                                                "美国",
                                                "豆瓣 7.7",
                                                "杨紫琼, 关继威"),
                                        seed(
                                                "curated:rt:6",
                                                "荒野机器人",
                                                "2024",
                                                "美国",
                                                "豆瓣 8.0",
                                                "露皮塔·尼永奥, 佩德罗·帕斯卡"))),
                        new ModuleSpec(
                                ID_DISNEY,
                                "迪士尼 · 皮克斯",
                                "奇幻动画与合家欢经典",
                                "Disney",
                                MobileIcons.IC_SPARKLE,
                                0xFF1D6BFF,
                                "https://movie.douban.com/j/new_search_subjects?sort=U&range=7,10&tags=%E8%BF%AA%E5%A3%AB%E5%B0%BC&start=0&limit=16",
                                "https://movie.douban.com/",
                                Arrays.asList(
                                        seed(
                                                "curated:ds:1",
                                                "疯狂动物城",
                                                "2016",
                                                "美国",
                                                "豆瓣 9.2",
                                                "金妮弗·古德温, 杰森·贝特曼"),
                                        seed(
                                                "curated:ds:2",
                                                "寻梦环游记",
                                                "2017",
                                                "美国",
                                                "豆瓣 9.1",
                                                "安东尼·冈萨雷斯"),
                                        seed(
                                                "curated:ds:3",
                                                "头脑特工队2",
                                                "2024",
                                                "美国",
                                                "豆瓣 8.4",
                                                "艾米·波勒, 玛雅·霍克"),
                                        seed(
                                                "curated:ds:4",
                                                "机器人总动员",
                                                "2008",
                                                "美国",
                                                "豆瓣 9.3",
                                                "本·贝尔特"),
                                        seed(
                                                "curated:ds:5",
                                                "心灵奇旅",
                                                "2020",
                                                "美国",
                                                "豆瓣 8.7",
                                                "杰米·福克斯"),
                                        seed(
                                                "curated:ds:6",
                                                "冰雪奇缘",
                                                "2013",
                                                "美国",
                                                "豆瓣 8.5",
                                                "克里斯汀·贝尔"),
                                        seed(
                                                "curated:ds:7",
                                                "飞屋环游记",
                                                "2009",
                                                "美国",
                                                "豆瓣 9.1",
                                                "爱德华·阿斯纳"),
                                        seed(
                                                "curated:ds:8",
                                                "加勒比海盗",
                                                "2003",
                                                "美国",
                                                "豆瓣 8.8",
                                                "约翰尼·德普"))),
                        new ModuleSpec(
                                ID_MARVEL,
                                "漫威宇宙",
                                "Marvel 超级英雄电影与剧集",
                                "MARVEL",
                                MobileIcons.IC_STAR,
                                0xFFE62429,
                                "https://movie.douban.com/j/new_search_subjects?sort=U&range=6,10&tags=%E6%BC%AB%E5%A8%81&start=0&limit=16",
                                "https://movie.douban.com/",
                                Arrays.asList(
                                        seed(
                                                "curated:mv:1",
                                                "复仇者联盟4：终局之战",
                                                "2019",
                                                "美国",
                                                "豆瓣 8.5",
                                                "小罗伯特·唐尼, 克里斯·埃文斯"),
                                        seed(
                                                "curated:mv:2",
                                                "复仇者联盟3：无限战争",
                                                "2018",
                                                "美国",
                                                "豆瓣 8.1",
                                                "小罗伯特·唐尼, 乔什·布洛林"),
                                        seed(
                                                "curated:mv:3",
                                                "钢铁侠",
                                                "2008",
                                                "美国",
                                                "豆瓣 8.4",
                                                "小罗伯特·唐尼"),
                                        seed(
                                                "curated:mv:4",
                                                "银河护卫队3",
                                                "2023",
                                                "美国",
                                                "豆瓣 8.4",
                                                "克里斯·帕拉特"),
                                        seed(
                                                "curated:mv:5",
                                                "洛基 第一季",
                                                "2021",
                                                "美国",
                                                "豆瓣 8.5",
                                                "汤姆·希德勒斯顿"),
                                        seed(
                                                "curated:mv:6",
                                                "美国队长2",
                                                "2014",
                                                "美国",
                                                "豆瓣 8.0",
                                                "克里斯·埃文斯"),
                                        seed(
                                                "curated:mv:7",
                                                "死侍与金刚狼",
                                                "2024",
                                                "美国",
                                                "豆瓣 7.0",
                                                "瑞安·雷诺兹"),
                                        seed(
                                                "curated:mv:8",
                                                "蜘蛛侠：英雄无归",
                                                "2021",
                                                "美国",
                                                "豆瓣 6.6",
                                                "汤姆·赫兰德"))),
                        new ModuleSpec(
                                ID_DC,
                                "DC 宇宙",
                                "哥谭暗黑史诗与正义联盟",
                                "DC",
                                MobileIcons.IC_PLAY,
                                0xFF0476F2,
                                "https://movie.douban.com/j/new_search_subjects?sort=U&range=6,10&tags=DC&start=0&limit=16",
                                "https://movie.douban.com/",
                                Arrays.asList(
                                        seed(
                                                "curated:dc:1",
                                                "蝙蝠侠：黑暗骑士",
                                                "2008",
                                                "美国",
                                                "豆瓣 9.2",
                                                "克里斯蒂安·贝尔, 希斯·莱杰"),
                                        seed(
                                                "curated:dc:2",
                                                "小丑",
                                                "2019",
                                                "美国",
                                                "豆瓣 8.7",
                                                "华金·菲尼克斯"),
                                        seed(
                                                "curated:dc:3",
                                                "新蝙蝠侠",
                                                "2022",
                                                "美国",
                                                "豆瓣 7.2",
                                                "罗伯特·帕丁森"),
                                        seed(
                                                "curated:dc:4",
                                                "企鹅人",
                                                "2024",
                                                "美国",
                                                "豆瓣 8.7",
                                                "科林·法瑞尔"),
                                        seed(
                                                "curated:dc:5",
                                                "守望者",
                                                "2009",
                                                "美国",
                                                "豆瓣 8.6",
                                                "杰基·厄尔·哈利"),
                                        seed(
                                                "curated:dc:6",
                                                "扎克·施奈德版正义联盟",
                                                "2021",
                                                "美国",
                                                "豆瓣 8.2",
                                                "本·阿弗莱克"),
                                        seed("curated:dc:7", "海王", "2018", "美国", "豆瓣 7.6", "杰森·莫玛"),
                                        seed(
                                                "curated:dc:8",
                                                "V字仇杀队",
                                                "2005",
                                                "美国",
                                                "豆瓣 8.9",
                                                "娜塔莉·波特曼")))));
    }
}

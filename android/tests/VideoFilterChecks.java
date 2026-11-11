package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpServer;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

public final class VideoFilterChecks {
    static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
        System.out.println("PASS " + label);
    }

    public static void main(String[] args) throws Exception {
        String schema =
                "{\"filters\":{\"movie\":[{\"key\":\"class\",\"name\":\"类型\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"剧情\",\"v\":\"genre-7\"}]},{\"key\":\"area\",\"name\":\"地区\",\"value\":[{\"n\":\"美国\",\"v\":\"US\"}]},{\"key\":\"year\",\"name\":\"年份\",\"value\":[{\"n\":\"2026\",\"v\":\"2026\"}]}]}}";
        List<VideoFilters.Definition> definitions =
                VideoFilters.definitions(schema, "movie", Collections.emptyList());
        Map<String, String> selected = new LinkedHashMap<>();
        selected.put("class", "genre-7");
        selected.put("area", "US");
        selected.put("year", "2026");
        Map<String, String> wire = VideoFilters.remoteValues(definitions, selected);
        check(wire.equals(selected), "remote opaque filter values preserved across all dimensions");
        check(
                definitions.get(0).labelFor("genre-7").equals("剧情"),
                "opaque source value has readable label");
        check(
                VideoFilters.remoteValues(
                                VideoFilters.definitions(schema, "series", Collections.emptyList()),
                                selected)
                        .isEmpty(),
                "category-specific schema never leaks to another category");
        List<Cms.Video> videos =
                Cms.listing(
                                "{\"list\":[{\"vod_id\":\"1\",\"vod_class\":\"剧情 / 悬疑\",\"vod_area\":\"大陆 / 香港\",\"vod_year\":\"2026\"},{\"vod_id\":\"2\",\"vod_class\":\"剧情\",\"vod_area\":\"美国\",\"vod_year\":\"2026\"},{\"vod_id\":\"3\",\"vod_class\":\"剧情\",\"vod_area\":\"内地\",\"vod_year\":\"2025\"},{\"vod_id\":\"4\"}]}")
                        .videos;
        List<VideoFilters.Definition> fallback = VideoFilters.definitions("{}", "movie", videos);
        Map<String, String> local = new LinkedHashMap<>();
        local.put("class", "剧情");
        local.put("area", "中国大陆");
        local.put("year", "2026");
        List<Cms.Video> filtered = VideoFilters.apply(videos, fallback, local);
        check(
                filtered.size() == 1 && filtered.get(0).id.equals("1"),
                "local filters combine with AND and normalize country aliases");
        check(
                VideoFilters.apply(videos, fallback, Collections.emptyMap()).size() == 4,
                "clearing filters restores all loaded results");
        check(
                VideoFilters.apply(videos, definitions, selected).size() == 4,
                "remote filtering does not reject missing listing metadata");
        check(
                !VideoFilters.matches("20260", "2026", "year"),
                "year does not partially match another number");
        check(
                VideoFilters.definitions("not json", "movie", videos).size() == 3,
                "malformed schema retains usable metadata filters");

        String spiderSchema =
                "{\"filters\":{\"1\":[{\"key\":\"cateId\",\"name\":\"剧情\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"科幻\",\"v\":\"scifi-1\"}]},{\"key\":\"area\",\"name\":\"产地\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"欧美\",\"v\":\"west\"}]},{\"key\":\"yr\",\"name\":\"年份\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"2025\",\"v\":\"2025\"}]}]}}";
        List<VideoFilters.Definition> spiderDefs =
                VideoFilters.definitions(spiderSchema, "1", Collections.emptyList());
        Map<String, String> spiderSelected = new LinkedHashMap<>();
        spiderSelected.put("class", "scifi-1");
        spiderSelected.put("area", "west");
        spiderSelected.put("year", "2025");
        Map<String, String> spiderWire = VideoFilters.remoteValues(spiderDefs, spiderSelected);
        check(
                "scifi-1".equals(spiderWire.get("cateId"))
                        && "west".equals(spiderWire.get("area"))
                        && "2025".equals(spiderWire.get("yr")),
                "spider filter keys (cateId/产地/yr) map cleanly to TV filter rows and wire keys");

        Map<String, String> cmsFallbackWire = VideoFilters.remoteValues(fallback, local, true);
        check(
                "剧情".equals(cmsFallbackWire.get("class"))
                        && "大陆".equals(cmsFallbackWire.get("area"))
                        && "2026".equals(cmsFallbackWire.get("year"))
                        && VideoFilters.hasLocal(fallback, local),
                "HTTP CMS fallback sends normalized query params while retaining local verification");

        List<Cms.Video> xmlVideos =
                Cms.listing(
                                "<rss><list page=\"1\" pagecount=\"2\"><video><id>x1</id><name>星际样本</name><type>科幻片</type><area>美国</area><year>2026</year></video><video><id>x2</id><name>古装样本</name><type>电影</type><note>HD / 2025 / 大陆 / 喜剧</note></video></list></rss>")
                        .videos;
        List<VideoFilters.Definition> xmlDefs = VideoFilters.definitions("{}", "1", xmlVideos);
        Map<String, String> xmlSelect = new LinkedHashMap<>();
        xmlSelect.put("class", "科幻");
        xmlSelect.put("area", "美国");
        xmlSelect.put("year", "2026");
        List<Cms.Video> xmlMatched = VideoFilters.apply(xmlVideos, xmlDefs, xmlSelect);
        check(
                xmlMatched.size() == 1 && "x1".equals(xmlMatched.get(0).id),
                "XML listing populates genre from <type> and filters accurately");
        Map<String, String> remarksSelect = new LinkedHashMap<>();
        remarksSelect.put("class", "喜剧");
        remarksSelect.put("area", "中国大陆");
        remarksSelect.put("year", "2025");
        List<Cms.Video> remarksMatched = VideoFilters.apply(xmlVideos, xmlDefs, remarksSelect);
        check(
                remarksMatched.size() == 1 && "x2".equals(remarksMatched.get(0).id),
                "remarks metadata fallback matches when structured area/year/genre are generic");

        AtomicReference<String> query = new AtomicReference<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext(
                "/api",
                exchange -> {
                    query.set(exchange.getRequestURI().getRawQuery());
                    byte[] body =
                            "{\"page\":3,\"pagecount\":8,\"list\":[]}"
                                    .getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, body.length);
                    exchange.getResponseBody().write(body);
                    exchange.close();
                });
        server.start();
        try {
            Cms.Site site = new Cms.Site();
            site.type = 1;
            site.api = "http://127.0.0.1:" + server.getAddress().getPort() + "/api";
            SourceEngine engine = new QueuedSourceEngine(new JsonCmsEngine(site));
            wire.put("ac", "player");
            wire.put("ids", "unwanted");
            Cms.Listing page = Cms.listing(engine.category("movie", 3, wire));
            String sent = URLDecoder.decode(query.get(), "UTF-8");
            check(
                    sent.contains("class=genre-7")
                            && sent.contains("area=US")
                            && sent.contains("year=2026")
                            && sent.contains("pg=3"),
                    "queued HTTP transport forwards every filter on later pages");
            check(
                    sent.contains("ac=detail")
                            && !sent.contains("unwanted")
                            && !sent.contains("player"),
                    "filter metadata cannot rewrite routing parameters");
            check(
                    page.videos.isEmpty() && page.pageCount == 8,
                    "empty filtered page retains server pagination");
        } finally {
            server.stop(0);
        }
    }
}

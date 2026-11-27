package com.pilipala.marcomovie;

import org.json.JSONArray;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Offline acceptance suite for Android TV exact/fuzzy search admission, normalization, alias
 * discipline, tiered ranking, pagination, deduplication, and rapid mode-switch isolation.
 *
 * <p>Uses synthetic records only and executes production {@link TvSearchMatcher}, {@link
 * TvSearchPages}, {@link SearchVariants}, {@link Cms#listing(String)}, and {@link
 * PhoneticSearchIndex}.
 */
public final class TvSearchAcceptanceChecks {
    private static int checks;

    private static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError("FAIL: " + label);
        checks++;
        System.out.println("PASS " + label);
    }

    private static Cms.Site site(String key, String name) {
        Cms.Site s = new Cms.Site();
        s.key = key;
        s.name = name;
        s.type = 1;
        s.searchable = true;
        return s;
    }

    private static Cms.Video parseRecordViaCms(JSONObject rec) throws Exception {
        JSONObject item = new JSONObject();
        item.put("vod_id", rec.getString("id"));
        item.put("vod_name", rec.getString("title"));
        item.put("vod_year", rec.optString("year", ""));
        if (rec.has("explicit_aliases")) {
            item.put("explicit_aliases", rec.getJSONArray("explicit_aliases"));
        }
        String json = new JSONObject().put("page", 1).put("pagecount", 1).put("list", new JSONArray().put(item)).toString();
        Cms.Listing listing = Cms.listing(json);
        if (listing.videos.size() != 1) {
            throw new AssertionError("Cms.listing failed for synthetic record " + rec.optString("key"));
        }
        return listing.videos.get(0);
    }

    private static JSONObject defaultSyntheticCases() throws Exception {
        String raw =
                "{\n"
                        + "  \"default_mode\": \"exact\",\n"
                        + "  \"records\": [\n"
                        + "    {\"key\":\"A/1\",\"site\":\"A\",\"id\":\"1\",\"title\":\"三体\",\"year\":\"2023\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"A/2\",\"site\":\"A\",\"id\":\"2\",\"title\":\"三体2\",\"year\":\"\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"B/3\",\"site\":\"B\",\"id\":\"3\",\"title\":\"三体\",\"year\":\"2008\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"A/4\",\"site\":\"A\",\"id\":\"4\",\"title\":\"三体：花絮\",\"year\":\"\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"B/5\",\"site\":\"B\",\"id\":\"5\",\"title\":\"流浪地球\",\"year\":\"\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"B/6\",\"site\":\"B\",\"id\":\"6\",\"title\":\"三体广播剧\",\"year\":\"\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"B/7\",\"site\":\"B\",\"id\":\"7\",\"title\":\"无关推荐\",\"year\":\"\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"C/8\",\"site\":\"C\",\"id\":\"8\",\"title\":\"Interstellar\",\"year\":\"2014\",\"explicit_aliases\":[\"星际穿越\"]},\n"
                        + "    {\"key\":\"C/9\",\"site\":\"C\",\"id\":\"9\",\"title\":\"Alien\",\"year\":\"1979\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"C/10\",\"site\":\"C\",\"id\":\"10\",\"title\":\"Aliens\",\"year\":\"1986\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"C/11\",\"site\":\"C\",\"id\":\"11\",\"title\":\"C++\",\"year\":\"\",\"explicit_aliases\":[]},\n"
                        + "    {\"key\":\"C/12\",\"site\":\"C\",\"id\":\"12\",\"title\":\"C\",\"year\":\"\",\"explicit_aliases\":[]}\n"
                        + "  ],\n"
                        + "  \"checks\": [\n"
                        + "    {\"query\":\"三体\",\"mode\":\"exact\",\"expected_keys\":[\"A/1\",\"B/3\"],\"ordered\":false},\n"
                        + "    {\"query\":\"三体\",\"mode\":\"fuzzy\",\"top_group\":[\"A/1\",\"B/3\"],\"expected_additional\":[\"A/2\",\"A/4\",\"B/6\"],\"forbidden\":[\"B/5\",\"B/7\"]},\n"
                        + "    {\"query\":\"三体\",\"mode\":\"exact\",\"site\":\"B\",\"expected_keys\":[\"B/3\"]},\n"
                        + "    {\"query\":\"三体2\",\"mode\":\"exact\",\"expected_keys\":[\"A/2\"]},\n"
                        + "    {\"query\":\"　ＡＬＩＥＮ　\",\"mode\":\"exact\",\"expected_keys\":[\"C/9\"]},\n"
                        + "    {\"query\":\"C++\",\"mode\":\"exact\",\"expected_keys\":[\"C/11\"]},\n"
                        + "    {\"query\":\"星际穿越\",\"mode\":\"exact\",\"expected_keys\":[\"C/8\"]},\n"
                        + "    {\"query\":\"st\",\"mode\":\"exact\",\"expected_keys\":[]},\n"
                        + "    {\"query\":\"santi\",\"mode\":\"fuzzy\",\"must_include\":[\"A/1\",\"B/3\"]},\n"
                        + "    {\"query\":\"荒原之外\",\"mode\":\"exact\",\"expected_keys\":[]},\n"
                        + "    {\"query\":\"   \",\"mode\":\"exact\",\"expected_keys\":[],\"source_calls\":0}\n"
                        + "  ]\n"
                        + "}";
        return new JSONObject(raw);
    }

    private static List<String> jsonStrings(JSONArray arr) {
        List<String> out = new ArrayList<>();
        if (arr == null) return out;
        for (int i = 0; i < arr.length(); i++) out.add(arr.optString(i, ""));
        return out;
    }

    public static void main(String[] args) throws Exception {
        Path repoRoot = Paths.get(args.length > 0 ? args[0] : ".");
        Path casesPath =
                args.length > 1 && !args[1].isEmpty()
                        ? Paths.get(args[1])
                        : repoRoot.resolve(
                                "dist/reviews/tv-rc-twelfth-recheck-2026-11-26/search_acceptance_cases.json");
        Path outJsonPath = args.length > 2 && !args[2].isEmpty() ? Paths.get(args[2]) : null;

        JSONObject spec =
                Files.isRegularFile(casesPath)
                        ? new JSONObject(
                                new String(Files.readAllBytes(casesPath), StandardCharsets.UTF_8))
                        : defaultSyntheticCases();

        // Build local phonetic index from real TV assets
        PhoneticSearchIndex phonetic =
                new PhoneticSearchIndex(
                        Files.newInputStream(
                                repoRoot.resolve(
                                        "android-tv/src/main/assets/search/pinyin-characters.tsv")),
                        Files.newInputStream(
                                repoRoot.resolve(
                                        "android-tv/src/main/assets/search/pinyin-phrases.dict.yaml")),
                        Files.newInputStream(
                                repoRoot.resolve(
                                        "android-tv/src/main/assets/search/title-phrases.txt")));
        phonetic.learn("三体");

        // Parse synthetic records through real Cms.listing() so alias mapping is exercised end-to-end
        Map<String, Cms.Site> sitesByKey = new LinkedHashMap<>();
        Map<String, List<Cms.Video>> corpusBySite = new LinkedHashMap<>();
        JSONArray records = spec.getJSONArray("records");
        for (int i = 0; i < records.length(); i++) {
            JSONObject rec = records.getJSONObject(i);
            String sk = rec.getString("site");
            sitesByKey.computeIfAbsent(sk, k -> site(k, "合成源" + k));
            corpusBySite.computeIfAbsent(sk, k -> new ArrayList<>()).add(parseRecordViaCms(rec));
        }

        // Default mode check
        check(
                TvSearchMatcher.Mode.fromPref(null) == TvSearchMatcher.Mode.EXACT
                        && TvSearchMatcher.Mode.fromPref("") == TvSearchMatcher.Mode.EXACT
                        && TvSearchMatcher.Mode.fromPref("fuzzy") == TvSearchMatcher.Mode.FUZZY,
                "default search mode is EXACT and pref round-trip works");

        JSONArray reportCases = new JSONArray();
        JSONArray specChecks = spec.getJSONArray("checks");
        for (int idx = 0; idx < specChecks.length(); idx++) {
            JSONObject c = specChecks.getJSONObject(idx);
            String query = c.getString("query");
            TvSearchMatcher.Mode mode = TvSearchMatcher.Mode.fromPref(c.getString("mode"));
            String filterSite = c.optString("site", "");

            final AtomicInteger sourceCalls = new AtomicInteger();
            List<String> recallTerms = TvSearchMatcher.buildRecallTerms(mode, query, phonetic);
            List<GlobalSearchScreen.SourceResult> results = new ArrayList<>();
            if (!recallTerms.isEmpty()) {
                for (Map.Entry<String, Cms.Site> entry : sitesByKey.entrySet()) {
                    final Cms.Site s = entry.getValue();
                    final List<Cms.Video> siteCorpus = corpusBySite.get(s.key);
                    TvSearchPages pages =
                            TvSearchPages.firstVideos(
                                    query,
                                    recallTerms,
                                    TvSearchMatcher.videoPredicate(mode, query, phonetic),
                                    (term, page) -> {
                                        sourceCalls.incrementAndGet();
                                        Cms.Listing l = new Cms.Listing();
                                        l.page = 1;
                                        l.pageCount = 1;
                                        // Simulates noisy CMS returning its entire synthetic bucket
                                        l.videos.addAll(siteCorpus);
                                        return l;
                                    },
                                    TvSearchPages.MAX_RESULTS);
                    List<Cms.Video> ranked = new ArrayList<>(pages.videos);
                    TvSearchMatcher.rankSourceVideos(mode, query, ranked, s.name, phonetic);
                    results.add(
                            new GlobalSearchScreen.SourceResult(
                                    s,
                                    ranked,
                                    ranked.isEmpty()
                                            ? SearchCoordinator.Outcome.EMPTY
                                            : SearchCoordinator.Outcome.RESULT,
                                    pages));
                }
            }

            List<TvSearchMatcher.RankedHit> hits =
                    TvSearchMatcher.collectAndRank(mode, query, results, filterSite, "", phonetic);
            List<String> actualKeys = new ArrayList<>();
            List<String> actualTitles = new ArrayList<>();
            JSONArray actualItems = new JSONArray();
            for (TvSearchMatcher.RankedHit hit : hits) {
                String k = hit.site.key + "/" + hit.video.id;
                actualKeys.add(k);
                actualTitles.add(hit.video.title);
                actualItems.put(
                        new JSONObject()
                                .put("key", k)
                                .put("site", hit.site.key)
                                .put("id", hit.video.id)
                                .put("title", hit.video.title)
                                .put("year", hit.video.year == null ? "" : hit.video.year)
                                .put("tier", hit.tier));
            }

            if (c.has("source_calls")) {
                check(
                        sourceCalls.get() == c.getInt("source_calls"),
                        "case[" + idx + "] query='" + query + "' source_calls==" + c.getInt("source_calls"));
            }
            if (c.has("expected_keys")) {
                List<String> expected = jsonStrings(c.getJSONArray("expected_keys"));
                boolean ordered = c.optBoolean("ordered", true);
                if (ordered) {
                    check(
                            actualKeys.equals(expected),
                            "case["
                                    + idx
                                    + "] exact ordered query='"
                                    + query
                                    + "' mode="
                                    + mode.prefValue
                                    + " got="
                                    + actualKeys);
                } else {
                    check(
                            actualKeys.size() == expected.size()
                                    && new HashSet<>(actualKeys).equals(new HashSet<>(expected)),
                            "case["
                                    + idx
                                    + "] exact set query='"
                                    + query
                                    + "' mode="
                                    + mode.prefValue
                                    + " got="
                                    + actualKeys);
                }
            }
            if (c.has("top_group")) {
                List<String> top = jsonStrings(c.getJSONArray("top_group"));
                check(
                        actualKeys.size() >= top.size()
                                && new HashSet<>(actualKeys.subList(0, top.size()))
                                        .equals(new HashSet<>(top)),
                        "case["
                                + idx
                                + "] fuzzy top_group first query='"
                                + query
                                + "' got="
                                + actualKeys);
            }
            if (c.has("expected_additional")) {
                List<String> add = jsonStrings(c.getJSONArray("expected_additional"));
                check(
                        actualKeys.containsAll(add),
                        "case["
                                + idx
                                + "] fuzzy additional query='"
                                + query
                                + "' got="
                                + actualKeys);
            }
            if (c.has("forbidden")) {
                List<String> forbid = jsonStrings(c.getJSONArray("forbidden"));
                for (String f : forbid) {
                    check(
                            !actualKeys.contains(f),
                            "case["
                                    + idx
                                    + "] forbidden excluded "
                                    + f
                                    + " query='"
                                    + query
                                    + "'");
                }
            }
            if (c.has("must_include")) {
                List<String> must = jsonStrings(c.getJSONArray("must_include"));
                check(
                        actualKeys.containsAll(must),
                        "case["
                                + idx
                                + "] must_include query='"
                                + query
                                + "' got="
                                + actualKeys);
            }

            reportCases.put(
                    new JSONObject()
                            .put("index", idx)
                            .put("query", query)
                            .put("mode", mode.prefValue)
                            .put("site_filter", filterSite)
                            .put("source_calls", sourceCalls.get())
                            .put("actual_keys", new JSONArray(actualKeys))
                            .put("actual_titles", new JSONArray(actualTitles))
                            .put("items", actualItems)
                            .put("passed", true));
        }

        // Alias constraint check: removing explicit_aliases makes "星际穿越" -> 0 hits; description/actor never impersonate alias
        JSONObject noAliasItem =
                new JSONObject()
                        .put("vod_id", "8")
                        .put("vod_name", "Interstellar")
                        .put("vod_year", "2014")
                        .put("vod_content", "星际穿越 科幻电影")
                        .put("vod_actor", "星际穿越")
                        .put("vod_remarks", "星际穿越 4K蓝光");
        Cms.Video parsedNoAlias =
                Cms.listing(
                                new JSONObject()
                                        .put("page", 1)
                                        .put("pagecount", 1)
                                        .put("list", new JSONArray().put(noAliasItem))
                                        .toString())
                        .videos
                        .get(0);
        check(
                parsedNoAlias.aliases.isEmpty()
                        && !TvSearchMatcher.matches(
                                TvSearchMatcher.Mode.EXACT, "星际穿越", parsedNoAlias, phonetic)
                        && !TvSearchMatcher.matches(
                                TvSearchMatcher.Mode.FUZZY, "星际穿越", parsedNoAlias, phonetic),
                "removing explicit_aliases yields 0 matches; description/actor/remarks never impersonate title");

        // Transition 1: Page 1 all irrelevant, Page 2 contains strict exact match -> bounded auto-advance finds it & keeps cursor
        AtomicInteger pagedCalls = new AtomicInteger();
        TvSearchPages paged =
                TvSearchPages.firstVideos(
                        "三体",
                        Collections.singletonList("三体"),
                        TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.EXACT, "三体", phonetic),
                        (term, page) -> {
                            pagedCalls.incrementAndGet();
                            Cms.Listing l = new Cms.Listing();
                            l.page = page;
                            l.pageCount = 3;
                            if (page == 1) {
                                Cms.Video n1 = new Cms.Video();
                                n1.id = "n1";
                                n1.title = "流浪地球";
                                Cms.Video n2 = new Cms.Video();
                                n2.id = "n2";
                                n2.title = "三体2";
                                l.videos.add(n1);
                                l.videos.add(n2);
                            } else if (page == 2) {
                                Cms.Video hit = new Cms.Video();
                                hit.id = "hit2";
                                hit.title = "三体";
                                hit.year = "2023";
                                l.videos.add(hit);
                            } else if (page == 3) {
                                Cms.Video hit3 = new Cms.Video();
                                hit3.id = "hit3";
                                hit3.title = "三体";
                                hit3.year = "2008";
                                l.videos.add(hit3);
                            }
                            return l;
                        },
                        TvSearchPages.MAX_RESULTS);
        check(
                pagedCalls.get() == 2
                        && paged.videos.size() == 1
                        && "hit2".equals(paged.videos.get(0).id)
                        && paged.hasMore(),
                "transition 1: page 1 all-noise advances to page 2 exact hit and preserves page 3 cursor");
        TvSearchPages pagedNext =
                paged.nextVideos(
                        TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.EXACT, "三体", phonetic),
                        (term, page) -> {
                            Cms.Listing l = new Cms.Listing();
                            l.page = page;
                            l.pageCount = 3;
                            Cms.Video dup = new Cms.Video();
                            dup.id = "hit2";
                            dup.title = "三体";
                            Cms.Video hit3 = new Cms.Video();
                            hit3.id = "hit3";
                            hit3.title = "三体";
                            hit3.year = "2008";
                            l.videos.add(dup);
                            l.videos.add(hit3);
                            return l;
                        },
                        TvSearchPages.MAX_RESULTS,
                        TvSearchPages.MAX_RESULTS);
        check(
                pagedNext.videos.size() == 2
                        && "hit2".equals(pagedNext.videos.get(0).id)
                        && "hit3".equals(pagedNext.videos.get(1).id)
                        && !pagedNext.hasMore(),
                "transition 2: cross-page duplicate siteKey+vodId deduped while distinct year/id preserved");

        // Transition 2b: Same siteKey+vodId deduped across retries/batches; distinct sites & distinct years kept
        Cms.Site siteA = site("A", "星海源");
        Cms.Site siteB = site("B", "远航源");
        Cms.Video a1 = new Cms.Video();
        a1.id = "1";
        a1.title = "三体";
        a1.year = "2023";
        Cms.Video a1Dup = new Cms.Video();
        a1Dup.id = "1";
        a1Dup.title = "三体";
        a1Dup.year = "2023";
        Cms.Video b1 = new Cms.Video();
        b1.id = "1";
        b1.title = "三体";
        b1.year = "2008";
        List<TvSearchMatcher.RankedHit> dedupHits =
                TvSearchMatcher.collectAndRank(
                        TvSearchMatcher.Mode.EXACT,
                        "三体",
                        Arrays.asList(
                                new GlobalSearchScreen.SourceResult(
                                        siteA,
                                        Arrays.asList(a1, a1Dup),
                                        SearchCoordinator.Outcome.RESULT),
                                new GlobalSearchScreen.SourceResult(
                                        siteB,
                                        Collections.singletonList(b1),
                                        SearchCoordinator.Outcome.RESULT)),
                        "",
                        "",
                        phonetic);
        check(
                dedupHits.size() == 2
                        && "A:1".equals(dedupHits.get(0).stableKey())
                        && "B:1".equals(dedupHits.get(1).stableKey()),
                "transition 2b: same siteKey+vodId deduplicated; different site same vodId & title preserved");

        // Transition 3: Rapid EXACT -> FUZZY -> EXACT drops late FUZZY response via serial + mode guard
        final AtomicInteger currentSerial = new AtomicInteger(1);
        final AtomicReference<TvSearchMatcher.Mode> currentMode =
                new AtomicReference<>(TvSearchMatcher.Mode.FUZZY);
        final List<String> published = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch slowEntered = new CountDownLatch(1);
        CountDownLatch releaseSlow = new CountDownLatch(1);
        CountDownLatch fuzzyDelivered = new CountDownLatch(1);
        final int fuzzySerial = currentSerial.incrementAndGet();
        final TvSearchMatcher.Mode fuzzyMode = TvSearchMatcher.Mode.FUZZY;
        SearchCoordinator fuzzyCoord =
                new SearchCoordinator(
                        (s, q) -> {
                            slowEntered.countDown();
                            releaseSlow.await(2, TimeUnit.SECONDS);
                            Cms.Video v = new Cms.Video();
                            v.id = "late_fuzzy";
                            v.title = "三体2";
                            return Collections.singletonList(v);
                        },
                        (s, videos, o) -> {
                            if (currentSerial.get() == fuzzySerial
                                    && currentMode.get() == fuzzyMode) {
                                for (Cms.Video v : videos) published.add(v.id);
                            }
                            fuzzyDelivered.countDown();
                        });
        fuzzyCoord.start(Collections.singletonList(siteA), "三体");
        check(slowEntered.await(2, TimeUnit.SECONDS), "transition 3: slow fuzzy worker entered");
        // User switches back to EXACT before slow FUZZY finishes
        currentMode.set(TvSearchMatcher.Mode.EXACT);
        currentSerial.incrementAndGet();
        releaseSlow.countDown();
        fuzzyDelivered.await(2, TimeUnit.SECONDS);
        fuzzyCoord.close();
        check(
                published.isEmpty(),
                "transition 3: late FUZZY callback dropped after switching back to EXACT");

        // Responsive column layout policy check (720p / 1080p / 1.3x / wide)
        check(
                GlobalSearchScreen.computeTvSearchColumns(740f, 1.0f) == 5
                        && GlobalSearchScreen.computeTvSearchColumns(599f, 1.0f) == 4
                        && GlobalSearchScreen.computeTvSearchColumns(599f, 1.3f) == 3
                        && GlobalSearchScreen.computeTvSearchColumns(440f, 1.0f) == 3,
                "responsive Apple TV search wall columns adapt cleanly to width and 1.3x fontScale");

        // R13 #1a: Page 1 & 2 repeat identical pinned unrelated item, Page 3 has exact hit -> found & bounded
        AtomicInteger r13ThirdPageCalls = new AtomicInteger();
        TvSearchPages r13ThirdPage =
                TvSearchPages.firstVideos(
                        "三体",
                        Collections.singletonList("三体"),
                        TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.EXACT, "三体", phonetic),
                        (term, page) -> {
                            r13ThirdPageCalls.incrementAndGet();
                            Cms.Listing l = new Cms.Listing();
                            l.page = page;
                            l.pageCount = 3;
                            Cms.Video v = new Cms.Video();
                            if (page < 3) {
                                v.id = "pinned";
                                v.title = "无关推荐";
                            } else {
                                v.id = "found";
                                v.title = "三体";
                            }
                            l.videos.add(v);
                            return l;
                        },
                        TvSearchPages.MAX_RESULTS);
        check(
                r13ThirdPageCalls.get() == 3
                        && r13ThirdPage.videos.size() == 1
                        && "found".equals(r13ThirdPage.videos.get(0).id),
                "R13 #1a: skips repeated pinned unrelated page 1-2 and finds exact hit on page 3");

        // R13 #1a-bounded: Endless repeating server still stops boundedly
        AtomicInteger r13EndlessCalls = new AtomicInteger();
        TvSearchPages r13Endless =
                TvSearchPages.firstVideos(
                        "三体",
                        Collections.singletonList("三体"),
                        TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.EXACT, "三体", phonetic),
                        (term, page) -> {
                            r13EndlessCalls.incrementAndGet();
                            Cms.Listing l = new Cms.Listing();
                            l.page = page;
                            l.pageCount = 99;
                            Cms.Video v = new Cms.Video();
                            v.id = "pinned";
                            v.title = "无关推荐";
                            l.videos.add(v);
                            return l;
                        },
                        TvSearchPages.MAX_RESULTS);
        check(
                r13Endless.videos.isEmpty()
                        && r13EndlessCalls.get() <= 3
                        && !r13Endless.hasMore(),
                "R13 #1a-bounded: endless repeating irrelevant source terminates boundedly");

        // R13 #1b: Page 2 enriches same ID with explicit alias -> admitted & shown once
        TvSearchPages r13Enriched =
                TvSearchPages.firstVideos(
                        "三体",
                        Collections.singletonList("三体"),
                        TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.EXACT, "三体", phonetic),
                        (term, page) -> {
                            Cms.Listing l = new Cms.Listing();
                            l.page = page;
                            l.pageCount = 2;
                            Cms.Video v = new Cms.Video();
                            v.id = "same";
                            v.title = "Three Body";
                            if (page == 2) v.aliases.add("三体");
                            l.videos.add(v);
                            return l;
                        },
                        TvSearchPages.MAX_RESULTS);
        check(
                r13Enriched.videos.size() == 1 && "same".equals(r13Enriched.videos.get(0).id),
                "R13 #1b: same video ID enriched with full alias on page 2 is re-evaluated and admitted once");

        // R13 #1c: Singular string alias with slash stays intact ("Face/Off" -> 1, "Face" -> 0, "Off" -> 0)
        Cms.Listing faceOffListing =
                Cms.listing(
                        "{\"page\":1,\"pagecount\":1,\"list\":[{\"vod_id\":\"f1\",\"vod_name\":\"变脸\",\"alias\":\"Face/Off\"}]}");
        Cms.Video faceOff = faceOffListing.videos.get(0);
        check(
                faceOff.aliases.size() == 1
                        && "Face/Off".equals(faceOff.aliases.get(0))
                        && TvSearchMatcher.matches(TvSearchMatcher.Mode.EXACT, "Face/Off", faceOff, phonetic)
                        && !TvSearchMatcher.matches(TvSearchMatcher.Mode.EXACT, "Face", faceOff, phonetic)
                        && !TvSearchMatcher.matches(TvSearchMatcher.Mode.EXACT, "Off", faceOff, phonetic),
                "R13 #1c: singular string alias preserves slash punctuation (Face/Off=1, Face=0, Off=0)");

        // R13 #2: Fuzzy search ranks BEFORE low-RAM per-source cap truncation (200-site cap == 4)
        int lowRamCap = TvSearchBudget.initialPerSourceCap(200, true, true);
        TvSearchPages r13FuzzyCap =
                TvSearchPages.firstVideos(
                        "三体",
                        TvSearchMatcher.buildRecallTerms(TvSearchMatcher.Mode.FUZZY, "三体", phonetic),
                        TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.FUZZY, "三体", phonetic),
                        (term, page) -> {
                            Cms.Listing l = new Cms.Listing();
                            l.page = 1;
                            l.pageCount = 1;
                            String[][] raw = {
                                {"p1", "三体：花絮", ""},
                                {"p2", "三体2", ""},
                                {"p3", "三体前传", ""},
                                {"p4", "三体广播剧", ""},
                                {"exact-alias", "Three Body", "三体"},
                            };
                            for (String[] row : raw) {
                                Cms.Video v = new Cms.Video();
                                v.id = row[0];
                                v.title = row[1];
                                if (!row[2].isEmpty()) v.aliases.add(row[2]);
                                l.videos.add(v);
                            }
                            return l;
                        },
                        lowRamCap);
        check(
                lowRamCap == 4
                        && r13FuzzyCap.videos.size() == 4
                        && "exact-alias".equals(r13FuzzyCap.videos.get(0).id),
                "R13 #2: fuzzy search ranks full alias #1 BEFORE applying low-RAM 200-site cap=4 truncation");

        // R13 #3: Pagination focus resolution stays on first newly added card (#25) or anchor, never 0
        List<TvSearchMatcher.RankedHit> hits48 = new ArrayList<>();
        Set<String> prev24 = new LinkedHashSet<>();
        for (int i = 0; i < 48; i++) {
            Cms.Video v = new Cms.Video();
            v.id = "v" + i;
            v.title = "三体" + i;
            TvSearchMatcher.RankedHit rh =
                    new TvSearchMatcher.RankedHit(siteA, v, 1, false, false, false, 0, i);
            hits48.add(rh);
            if (i < 24) prev24.add(rh.stableKey());
        }
        int localTarget =
                GlobalSearchScreen.resolvePaginationFocusIndex(hits48, prev24, 24, "A:v23");
        int noNewTarget =
                GlobalSearchScreen.resolvePaginationFocusIndex(
                        hits48.subList(0, 24), prev24, 24, "A:v23");
        check(
                localTarget == 24 && noNewTarget == 23,
                "R13 #3: pagination focus advances to index 24 (card #25) or keeps anchor 23, never jumps to 0");

        // R13 #4: Unicode blank queries (ASCII space, U+3000, U+00A0) -> 0 recall terms & 0 source calls
        for (String blankQ : new String[] {"   ", "\u3000", "\u00a0", " \u3000\u00a0 "}) {
            AtomicInteger blankCalls = new AtomicInteger();
            List<String> terms = TvSearchMatcher.buildRecallTerms(TvSearchMatcher.Mode.EXACT, blankQ, phonetic);
            TvSearchPages blankPages =
                    TvSearchPages.firstVideos(
                            blankQ,
                            terms,
                            TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.EXACT, blankQ, phonetic),
                            (term, page) -> {
                                blankCalls.incrementAndGet();
                                return new Cms.Listing();
                            },
                            TvSearchPages.MAX_RESULTS);
            check(
                    TvSearchMatcher.isBlankQuery(blankQ)
                            && terms.isEmpty()
                            && blankCalls.get() == 0
                            && blankPages.videos.isEmpty(),
                    "R13 #4: Unicode blank query produces 0 recall terms and 0 source calls");
        }

        // Trending shows discovery (offline/seed check with 0 CMS source calls)
        TvCuratedHome.Catalog hotSeed = TvCuratedHome.peekOrSeed(null);
        check(
                hotSeed != null && !hotSeed.hotDramas.isEmpty() && !hotSeed.hotMovies.isEmpty(),
                "Search empty-state hot recommendations available instantaneously with 0 CMS source calls");

        // R14 #1: 200-site low-RAM cap=4 auto-advance MUST preserve remainder on page 2 and page 3 cursor
        int r14LowRamCap = TvSearchBudget.initialPerSourceCap(200, true, true);
        SearchVariants.VideoMatch exactSanti =
                TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.EXACT, "三体", phonetic);
        for (int[] r14Spec : new int[][] {{1, 5, 6}, {1, 4, 5}, {0, 5, 11}}) {
            final boolean noiseFirst = r14Spec[0] == 1;
            final int secondPageMatches = r14Spec[1];
            final int expectedTotal = r14Spec[2];
            TvSearchPages.Fetch budgetFetch =
                    (term, pageNum) -> {
                        Cms.Listing l = new Cms.Listing();
                        l.page = pageNum;
                        l.pageCount = 3;
                        int cnt =
                                pageNum == 1
                                        ? (noiseFirst ? 1 : 5)
                                        : pageNum == 2 ? secondPageMatches : 1;
                        for (int i = 1; i <= cnt; i++) {
                            Cms.Video v = new Cms.Video();
                            v.id = "p" + pageNum + "-" + i;
                            v.title = (pageNum == 1 && noiseFirst) ? "无关推荐" : "三体";
                            l.videos.add(v);
                        }
                        return l;
                    };
            TvSearchPages pg =
                    TvSearchPages.firstVideos(
                            "三体",
                            Collections.singletonList("三体"),
                            exactSanti,
                            budgetFetch,
                            r14LowRamCap);
            check(
                    pg.videos.size() == r14LowRamCap && pg.hasMore() && !pg.limited,
                    "R14 #1: initial cap=" + r14LowRamCap + " preserves hasMore (noiseFirst=" + noiseFirst + ", p2=" + secondPageMatches + ")");
            for (int step = 0; step < 4 && pg.hasMore(); step++) {
                pg = pg.nextVideos(exactSanti, budgetFetch, 16, 100);
            }
            Set<String> uniqueIds = new LinkedHashSet<>();
            for (Cms.Video v : pg.videos) uniqueIds.add(v.id);
            check(
                    pg.videos.size() == expectedTotal && uniqueIds.size() == expectedTotal,
                    "R14 #1: manual load more recovers all " + expectedTotal + " unique hits (got " + pg.videos.size() + ")");
        }

        // R14 #3: Late single-source pagination callback MUST NOT hijack "全部" or another source
        check(
                GlobalSearchScreen.shouldApplyPaginationViewUpdate("star_a", "star_a", 3, 3),
                "R14 #3: staying on original source applies pagination limit/focus");
        check(
                !GlobalSearchScreen.shouldApplyPaginationViewUpdate("star_a", "", 3, 4),
                "R14 #3: switching from single source to 全部 blocks stale pagination focus/limit");
        check(
                !GlobalSearchScreen.shouldApplyPaginationViewUpdate("star_a", "star_b", 3, 4),
                "R14 #3: switching from single source to another source blocks stale pagination focus/limit");
        check(
                !GlobalSearchScreen.shouldApplyPaginationViewUpdate("star_a", "star_a", 3, 5),
                "R14 #3: switching away and back blocks stale pagination from prior epoch");
        check(
                GlobalSearchScreen.shouldApplyPaginationViewUpdate("", "", 1, 1),
                "R14 #3: staying on 全部 applies pagination limit/focus");

        // R15 P2: Late higher-tier full match arriving while user is focused on card #24 (A:p24)
        // in "全部" MUST NOT evict A:p24 or shift its index; active re-search / staying on A ranks
        // full match #1!
        {
            List<Cms.Video> aInit = new ArrayList<>();
            for (int i = 1; i <= 24; i++) {
                Cms.Video v = new Cms.Video();
                v.id = "p" + i;
                v.title = "三体前传" + i;
                aInit.add(v);
            }
            Cms.Video bBonus = new Cms.Video();
            bBonus.id = "bonus";
            bBonus.title = "三体其他";
            GlobalSearchScreen.SourceResult otherB =
                    new GlobalSearchScreen.SourceResult(
                            siteB,
                            Collections.singletonList(bBonus),
                            SearchCoordinator.Outcome.RESULT);
            SearchVariants.VideoMatch fuzzyPred =
                    TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.FUZZY, "三体", phonetic);
            TvSearchPages.Fetch strongLateFetch =
                    (term, page) -> {
                        Cms.Listing l = new Cms.Listing();
                        l.page = page;
                        l.pageCount = 2;
                        if (page == 1) {
                            l.videos.addAll(aInit);
                        } else {
                            Cms.Video late = new Cms.Video();
                            late.id = "late_exact";
                            late.title = "三体";
                            l.videos.add(late);
                        }
                        return l;
                    };
            TvSearchPages firstA =
                    TvSearchPages.firstVideos(
                            "三体",
                            Collections.singletonList("三体"),
                            fuzzyPred,
                            strongLateFetch,
                            24);
            List<TvSearchMatcher.RankedHit> beforeRanked =
                    TvSearchMatcher.collectAndRank(
                            TvSearchMatcher.Mode.FUZZY,
                            "三体",
                            Arrays.asList(
                                    new GlobalSearchScreen.SourceResult(
                                            siteA,
                                            firstA.videos,
                                            SearchCoordinator.Outcome.RESULT,
                                            firstA),
                                    otherB),
                            "",
                            "",
                            phonetic);
            List<TvSearchMatcher.RankedHit> beforeVis =
                    GlobalSearchScreen.projectVisibleHits(beforeRanked, 24, Collections.emptyList(), "", false);
            List<String> prevKeys24 = new ArrayList<>();
            for (TvSearchMatcher.RankedHit h : beforeVis) prevKeys24.add(h.stableKey());
            String focused24 = prevKeys24.get(23);

            // 1) Late higher-tier exact hit while user switched to "全部" and focused A:p24
            TvSearchPages secondA = firstA.nextVideos(fuzzyPred, strongLateFetch, 16, 100);
            List<TvSearchMatcher.RankedHit> afterStrongRanked =
                    TvSearchMatcher.collectAndRank(
                            TvSearchMatcher.Mode.FUZZY,
                            "三体",
                            Arrays.asList(
                                    new GlobalSearchScreen.SourceResult(
                                            siteA,
                                            secondA.videos,
                                            SearchCoordinator.Outcome.RESULT,
                                            secondA),
                                    otherB),
                            "",
                            "",
                            phonetic);
            List<TvSearchMatcher.RankedHit> afterStrongVis =
                    GlobalSearchScreen.projectVisibleHits(
                            afterStrongRanked, 24, prevKeys24, focused24, true);
            List<String> afterStrongKeys = new ArrayList<>();
            for (TvSearchMatcher.RankedHit h : afterStrongVis) afterStrongKeys.add(h.stableKey());
            check(
                    "A:p24".equals(focused24)
                            && secondA.videos.size() == 25
                            && "A:late_exact".equals(afterStrongRanked.get(0).stableKey())
                            && afterStrongVis.size() == 24
                            && afterStrongKeys.indexOf("A:p24") == 23
                            && "A:p1".equals(afterStrongKeys.get(0)),
                    "R15 P2a: late full match enters cache & ranks #1 in ranked, while focused A:p24 stays at index 23");

            // 2) Active re-search / leaving wall (preserveFocusedPosition=false) puts full match #1!
            List<TvSearchMatcher.RankedHit> activeResearchVis =
                    GlobalSearchScreen.projectVisibleHits(
                            afterStrongRanked, 24, Collections.emptyList(), "", false);
            check(
                    activeResearchVis.size() == 24
                            && "A:late_exact".equals(activeResearchVis.get(0).stableKey()),
                    "R15 P2b: active re-search / filter refresh ranks late full match 《三体》 #1");

            // 3) Staying on source A (pendingPaginationFocus -> preserveFocusedPosition=false, limit=48)
            // reveals and focuses newly added full match A:late_exact!
            List<TvSearchMatcher.RankedHit> stayOnARanked =
                    TvSearchMatcher.collectAndRank(
                            TvSearchMatcher.Mode.FUZZY,
                            "三体",
                            Collections.singletonList(
                                    new GlobalSearchScreen.SourceResult(
                                            siteA,
                                            secondA.videos,
                                            SearchCoordinator.Outcome.RESULT,
                                            secondA)),
                            "A",
                            "",
                            phonetic);
            List<TvSearchMatcher.RankedHit> stayOnAVis =
                    GlobalSearchScreen.projectVisibleHits(stayOnARanked, 48, prevKeys24, focused24, false);
            int stayTargetIdx =
                    GlobalSearchScreen.resolvePaginationFocusIndex(
                            stayOnAVis, new LinkedHashSet<>(prevKeys24), 24, focused24);
            check(
                    stayOnAVis.size() == 25
                            && "A:late_exact".equals(stayOnAVis.get(0).stableKey())
                            && stayTargetIdx == 0,
                    "R15 P2c: staying on original source A expands to 25 and focuses newly arrived 《三体》 at index 0");

            // 4) Late same-tier prefix hit keeps A:p24 at index 23 cleanly
            TvSearchPages.Fetch sameTierFetch =
                    (term, page) -> {
                        Cms.Listing l = new Cms.Listing();
                        l.page = page;
                        l.pageCount = 2;
                        if (page == 1) {
                            l.videos.addAll(aInit);
                        } else {
                            Cms.Video late = new Cms.Video();
                            late.id = "late_same";
                            late.title = "三体番外";
                            l.videos.add(late);
                        }
                        return l;
                    };
            TvSearchPages secondSame = firstA.nextVideos(fuzzyPred, sameTierFetch, 16, 100);
            List<TvSearchMatcher.RankedHit> afterSameRanked =
                    TvSearchMatcher.collectAndRank(
                            TvSearchMatcher.Mode.FUZZY,
                            "三体",
                            Arrays.asList(
                                    new GlobalSearchScreen.SourceResult(
                                            siteA,
                                            secondSame.videos,
                                            SearchCoordinator.Outcome.RESULT,
                                            secondSame),
                                    otherB),
                            "",
                            "",
                            phonetic);
            List<TvSearchMatcher.RankedHit> afterSameVis =
                    GlobalSearchScreen.projectVisibleHits(
                            afterSameRanked, 24, prevKeys24, focused24, true);
            List<String> afterSameKeys = new ArrayList<>();
            for (TvSearchMatcher.RankedHit h : afterSameVis) afterSameKeys.add(h.stableKey());
            check(
                    secondSame.videos.size() == 25
                            && afterSameVis.size() == 24
                            && afterSameKeys.indexOf("A:p24") == 23
                            && "A:p1".equals(afterSameKeys.get(0)),
                    "R15 P2d: late same-tier hit updates cache while keeping A:p24 stable at index 23");
        }

        // R16 P2: Low-RAM TV 900-item global budget eviction protects active filter, visible cards
        // and focused card #24 across full_last_A, headroom_last_A_control, full_early_A_control,
        // 2-source-only cap (trimming incoming B with resumable cursor), and "全部" tab visible protection.
        {
            final String q = "三体";
            final SearchVariants.VideoMatch fuzzyPred =
                    TvSearchMatcher.videoPredicate(TvSearchMatcher.Mode.FUZZY, q, null);
            final int cap = TvSearchBudget.globalCap(true, true);
            final int step = TvSearchBudget.pageStepCap(true, true);
            final int perSource = TvSearchBudget.initialPerSourceCap(15, true, true);
            check(
                    cap == 900 && step == 60 && perSource == 60,
                    "R16 P2 precheck: low-RAM TV budget constants (cap=900, step=60, 15-source initial=60)");

            final boolean[][] scenarios = {
                {true, true},   // full_last_A (exact R16 failure case!)
                {false, true},  // headroom_last_A_control
                {true, false},  // full_early_A_control
            };
            final String[] scenarioNames = {
                "full_last_A",
                "headroom_last_A_control",
                "full_early_A_control",
            };
            for (int sc = 0; sc < scenarios.length; sc++) {
                final boolean fullBudget = scenarios[sc][0];
                final boolean aCompletedLast = scenarios[sc][1];
                final String scName = scenarioNames[sc];
                Map<String, GlobalSearchScreen.SourceResult> sources = new LinkedHashMap<>();
                List<String> arrival = new ArrayList<>();
                arrival.add("B");
                if (!aCompletedLast) arrival.add("A");
                for (int i = 0; i < 13; i++) arrival.add("background-" + i);
                if (aCompletedLast) arrival.add("A");
                for (String key : arrival) {
                    Cms.Site s = site(key, key);
                    final int rows = (fullBudget || "A".equals(key) || "B".equals(key)) ? 60 : 50;
                    TvSearchPages first =
                            TvSearchPages.firstVideos(
                                    q,
                                    Collections.singletonList(q),
                                    fuzzyPred,
                                    (term, page) -> {
                                        Cms.Listing l = new Cms.Listing();
                                        l.page = page;
                                        l.pageCount = 3;
                                        for (int idx = 0; idx < rows; idx++) {
                                            int idNum = 60 * (page - 1) + idx + 1;
                                            Cms.Video v = new Cms.Video();
                                            v.id = "p" + idNum;
                                            v.title = q + "前传" + idNum;
                                            l.videos.add(v);
                                        }
                                        return l;
                                    },
                                    perSource);
                    sources.put(
                            key,
                            new GlobalSearchScreen.SourceResult(
                                    s, first.videos, SearchCoordinator.Outcome.RESULT, first));
                }
                List<TvSearchMatcher.RankedHit> aBeforeRanked =
                        TvSearchMatcher.collectAndRank(
                                TvSearchMatcher.Mode.FUZZY,
                                q,
                                new ArrayList<>(sources.values()),
                                "A",
                                "",
                                null);
                List<TvSearchMatcher.RankedHit> aBeforeVis =
                        GlobalSearchScreen.projectVisibleHits(
                                aBeforeRanked, 24, Collections.emptyList(), "", false);
                List<String> aBeforeKeys = new ArrayList<>();
                for (TvSearchMatcher.RankedHit h : aBeforeVis) aBeforeKeys.add(h.stableKey());
                String focused24 = aBeforeKeys.get(23);

                // User requested network next page on B, switched to A and focused A:p24, now B returns 60 items.
                GlobalSearchScreen.SourceResult bPrev = sources.get("B");
                TvSearchPages bPage2 =
                        bPrev.pages.nextVideos(
                                fuzzyPred,
                                (term, page) -> {
                                    Cms.Listing l = new Cms.Listing();
                                    l.page = page;
                                    l.pageCount = 3;
                                    for (int idx = 0; idx < 60; idx++) {
                                        int idNum = 60 * (page - 1) + idx + 1;
                                        Cms.Video v = new Cms.Video();
                                        v.id = "p" + idNum;
                                        v.title = q + "前传" + idNum;
                                        l.videos.add(v);
                                    }
                                    return l;
                                },
                                step,
                                cap);
                sources.put(
                        "B",
                        new GlobalSearchScreen.SourceResult(
                                bPrev.site, bPage2.videos, SearchCoordinator.Outcome.RESULT, bPage2));
                boolean evicted =
                        TvSearchBudget.enforceGlobalResultsCap(
                                sources, "A", "B", aBeforeKeys, cap);
                int totalAfter = 0;
                for (GlobalSearchScreen.SourceResult sr : sources.values()) {
                    totalAfter += sr.videos.size();
                }
                List<TvSearchMatcher.RankedHit> aAfterRanked =
                        TvSearchMatcher.collectAndRank(
                                TvSearchMatcher.Mode.FUZZY,
                                q,
                                new ArrayList<>(sources.values()),
                                "A",
                                "",
                                null);
                List<TvSearchMatcher.RankedHit> aAfterVis =
                        GlobalSearchScreen.projectVisibleHits(
                                aAfterRanked, 24, aBeforeKeys, focused24, true);
                List<String> aAfterKeys = new ArrayList<>();
                for (TvSearchMatcher.RankedHit h : aAfterVis) aAfterKeys.add(h.stableKey());
                GlobalSearchScreen.SourceResult aAfter = sources.get("A");
                GlobalSearchScreen.SourceResult bAfter = sources.get("B");
                // Returning to B must still be able to fetch page 3!
                TvSearchPages bPage3 =
                        bAfter.pages.nextVideos(
                                fuzzyPred,
                                (term, page) -> {
                                    Cms.Listing l = new Cms.Listing();
                                    l.page = page;
                                    l.pageCount = 3;
                                    for (int idx = 0; idx < 60; idx++) {
                                        int idNum = 60 * (page - 1) + idx + 1;
                                        Cms.Video v = new Cms.Video();
                                        v.id = "p" + idNum;
                                        v.title = q + "前传" + idNum;
                                        l.videos.add(v);
                                    }
                                    return l;
                                },
                                step,
                                cap);
                boolean evictedBackgroundStillResumable =
                        !fullBudget
                                || (sources.get("background-12").videos.isEmpty()
                                        && sources.get("background-12").pages.hasMore());
                check(
                        totalAfter <= cap
                                && (fullBudget ? evicted : !evicted)
                                && "A:p24".equals(focused24)
                                && aAfter.videos.size() == 60
                                && aAfterVis.size() == 24
                                && aAfterKeys.indexOf("A:p24") == 23
                                && !GlobalSearchScreen.shouldApplyPaginationViewUpdate("B", "A", 1, 2)
                                && bAfter.videos.size() == 120
                                && bAfter.pages.hasMore()
                                && bPage3.videos.size() == 180
                                && evictedBackgroundStillResumable,
                        "R16 P2 ("
                                + scName
                                + "): total="
                                + totalAfter
                                + "<=900, A_cached="
                                + aAfter.videos.size()
                                + ", A:p24 idx="
                                + aAfterKeys.indexOf("A:p24")
                                + ", B resumable -> "
                                + bPage3.videos.size());
            }

            // R16 P2 extra 1: 2-source-only full budget (A=600 active last, B=300->360 late incoming)
            // -> Pass 2 trims incoming B back to 300 while keeping B.pages.hasMore()==true and A untouched!
            {
                Map<String, GlobalSearchScreen.SourceResult> twoSrc = new LinkedHashMap<>();
                TvSearchPages.Fetch bigFetch =
                        (term, page) -> {
                            Cms.Listing l = new Cms.Listing();
                            l.page = page;
                            l.pageCount = 12;
                            for (int idx = 0; idx < 60; idx++) {
                                int idNum = 60 * (page - 1) + idx + 1;
                                Cms.Video v = new Cms.Video();
                                v.id = "p" + idNum;
                                v.title = q + "前传" + idNum;
                                l.videos.add(v);
                            }
                            return l;
                        };
                TvSearchPages bPages =
                        TvSearchPages.firstVideos(q, Collections.singletonList(q), fuzzyPred, bigFetch, 60);
                for (int k = 0; k < 4; k++) bPages = bPages.nextVideos(fuzzyPred, bigFetch, 60, cap); // 300
                TvSearchPages aPages =
                        TvSearchPages.firstVideos(q, Collections.singletonList(q), fuzzyPred, bigFetch, 60);
                for (int k = 0; k < 9; k++) aPages = aPages.nextVideos(fuzzyPred, bigFetch, 60, cap); // 600
                twoSrc.put("B", new GlobalSearchScreen.SourceResult(site("B", "B"), bPages.videos, SearchCoordinator.Outcome.RESULT, bPages));
                twoSrc.put("A", new GlobalSearchScreen.SourceResult(site("A", "A"), aPages.videos, SearchCoordinator.Outcome.RESULT, aPages));
                List<String> aVisKeys = new ArrayList<>();
                for (int i = 1; i <= 24; i++) aVisKeys.add("A:p" + i);
                TvSearchPages bNext = bPages.nextVideos(fuzzyPred, bigFetch, 60, cap); // 360 -> total 960
                twoSrc.put("B", new GlobalSearchScreen.SourceResult(site("B", "B"), bNext.videos, SearchCoordinator.Outcome.RESULT, bNext));
                boolean ev2 = TvSearchBudget.enforceGlobalResultsCap(twoSrc, "A", "B", aVisKeys, cap);
                int tot2 = twoSrc.get("A").videos.size() + twoSrc.get("B").videos.size();
                TvSearchPages bResume = twoSrc.get("B").pages.nextVideos(fuzzyPred, bigFetch, 60, cap);
                check(
                        ev2
                                && tot2 == 900
                                && twoSrc.get("A").videos.size() == 600
                                && twoSrc.get("B").videos.size() == 300
                                && twoSrc.get("B").pages.hasMore()
                                && bResume.videos.size() == 360,
                        "R16 P2 (2-source-only full budget): trims incoming B to 300 with resumable cursor, keeps active A=600 intact");
            }

            // R16 P2 extra 2: "全部" activeFilter ("") with focused A:p24 in visible keys protects A from eviction!
            {
                Map<String, GlobalSearchScreen.SourceResult> allTab = new LinkedHashMap<>();
                List<String> keysOrder = new ArrayList<>();
                keysOrder.add("B");
                for (int i = 0; i < 13; i++) keysOrder.add("background-" + i);
                keysOrder.add("A");
                for (String key : keysOrder) {
                    TvSearchPages first =
                            TvSearchPages.firstVideos(
                                    q,
                                    Collections.singletonList(q),
                                    fuzzyPred,
                                    (term, page) -> {
                                        Cms.Listing l = new Cms.Listing();
                                        l.page = page;
                                        l.pageCount = 2;
                                        for (int idx = 0; idx < 60; idx++) {
                                            int idNum = 60 * (page - 1) + idx + 1;
                                            Cms.Video v = new Cms.Video();
                                            v.id = "p" + idNum;
                                            v.title = q + "前传" + idNum;
                                            l.videos.add(v);
                                        }
                                        return l;
                                    },
                                    60);
                    allTab.put(key, new GlobalSearchScreen.SourceResult(site(key, key), first.videos, SearchCoordinator.Outcome.RESULT, first));
                }
                List<String> visOnAll = new ArrayList<>();
                for (int i = 1; i <= 24; i++) visOnAll.add("A:p" + i);
                GlobalSearchScreen.SourceResult b0 = allTab.get("B");
                TvSearchPages b2 =
                        b0.pages.nextVideos(
                                fuzzyPred,
                                (term, page) -> {
                                    Cms.Listing l = new Cms.Listing();
                                    l.page = page;
                                    l.pageCount = 2;
                                    for (int idx = 0; idx < 60; idx++) {
                                        int idNum = 60 * (page - 1) + idx + 1;
                                        Cms.Video v = new Cms.Video();
                                        v.id = "p" + idNum;
                                        v.title = q + "前传" + idNum;
                                        l.videos.add(v);
                                    }
                                    return l;
                                },
                                60,
                                cap);
                allTab.put("B", new GlobalSearchScreen.SourceResult(b0.site, b2.videos, SearchCoordinator.Outcome.RESULT, b2));
                boolean evAll = TvSearchBudget.enforceGlobalResultsCap(allTab, "", "B", visOnAll, cap);
                int totAll = 0;
                for (GlobalSearchScreen.SourceResult sr : allTab.values()) totAll += sr.videos.size();
                boolean hasAp24 = false;
                for (Cms.Video v : allTab.get("A").videos) {
                    if ("p24".equals(v.id)) {
                        hasAp24 = true;
                        break;
                    }
                }
                check(
                        evAll
                                && totAll == 900
                                && allTab.get("A").videos.size() >= 24
                                && hasAp24,
                        "R16 P2 (all-tab visible focus protection): total=900 and visible A:p24 retained");
            }

            // R17 P2a: 15 sources x 60 = 900 expanded to 900 on "全部" -> stop zero-progress
            // pagination loops cleanly (0 repeated fetches across 3 More clicks), guide switching
            // to a single source tab, and switching to B immediately fetches page 2 (60 -> 120)!
            {
                Map<String, GlobalSearchScreen.SourceResult> all900 = new LinkedHashMap<>();
                List<String> order = new ArrayList<>();
                order.add("B");
                order.add("film");
                for (int i = 0; i < 12; i++) order.add("background-" + i);
                order.add("A");
                for (String key : order) {
                    TvSearchPages first =
                            TvSearchPages.firstVideos(
                                    q,
                                    Collections.singletonList(q),
                                    fuzzyPred,
                                    (term, page) -> {
                                        Cms.Listing l = new Cms.Listing();
                                        l.page = page;
                                        l.pageCount = 3;
                                        for (int idx = 0; idx < 60; idx++) {
                                            int idNum = 60 * (page - 1) + idx + 1;
                                            Cms.Video v = new Cms.Video();
                                            v.id = "p" + idNum;
                                            v.title = q + "前传" + idNum;
                                            l.videos.add(v);
                                        }
                                        return l;
                                    },
                                    60);
                    all900.put(
                            key,
                            new GlobalSearchScreen.SourceResult(
                                    site(key, key), first.videos, SearchCoordinator.Outcome.RESULT, first));
                }
                List<TvSearchMatcher.RankedHit> allRanked =
                        TvSearchMatcher.collectAndRank(
                                TvSearchMatcher.Mode.FUZZY,
                                q,
                                new ArrayList<>(all900.values()),
                                "",
                                "",
                                phonetic);
                int netCallsOnAll = 0;
                for (int click = 0; click < 3; click++) {
                    GlobalSearchScreen.SourceResult cand =
                            GlobalSearchScreen.selectNextPageSource(
                                    all900, "", 900, 900, allRanked.size(), 912 + click * 24, cap);
                    if (cand != null) netCallsOnAll++;
                }
                boolean exhaustedAll =
                        GlobalSearchScreen.isAllTabBudgetExhausted("", 900, 900, allRanked.size(), 912, cap);
                boolean exhaustedSingleB =
                        GlobalSearchScreen.isAllTabBudgetExhausted("B", 60, 900, 60, 72, cap);
                GlobalSearchScreen.SourceResult singleBNext =
                        GlobalSearchScreen.selectNextPageSource(all900, "B", 60, 900, 60, 72, cap);
                List<Integer> bControlPages = new ArrayList<>();
                TvSearchPages bPage2 =
                        singleBNext.pages.nextVideos(
                                fuzzyPred,
                                (term, page) -> {
                                    bControlPages.add(page);
                                    Cms.Listing l = new Cms.Listing();
                                    l.page = page;
                                    l.pageCount = 3;
                                    for (int idx = 0; idx < 60; idx++) {
                                        int idNum = 60 * (page - 1) + idx + 1;
                                        Cms.Video v = new Cms.Video();
                                        v.id = "p" + idNum;
                                        v.title = q + "前传" + idNum;
                                        l.videos.add(v);
                                    }
                                    return l;
                                },
                                60,
                                cap);
                all900.put(
                        "B",
                        new GlobalSearchScreen.SourceResult(
                                singleBNext.site, bPage2.videos, SearchCoordinator.Outcome.RESULT, bPage2));
                List<TvSearchBudget.ProtectedItem> bProt = new ArrayList<>();
                for (Cms.Video v : bPage2.videos) {
                    bProt.add(new TvSearchBudget.ProtectedItem("B", v.id));
                }
                TvSearchBudget.enforceGlobalResultsCapByItems(all900, "B", "B", bProt, cap);
                int totAfterB = 0;
                for (GlobalSearchScreen.SourceResult sr : all900.values()) totAfterB += sr.videos.size();
                check(
                        exhaustedAll
                                && netCallsOnAll == 0
                                && !exhaustedSingleB
                                && singleBNext != null
                                && "B".equals(singleBNext.site.key)
                                && bControlPages.equals(Collections.singletonList(2))
                                && all900.get("B").videos.size() == 120
                                && totAfterB <= cap,
                        "R17 P2a: 900-expanded All-tab halts redundant fetches (0 calls) while switching to single source B resumes 60->120");
            }

            // R17 P2b: Overlapping colon site keys ("film" + "film:hk") AND colon inside video IDs
            // ("ep:24:hd") stay fully protected under BOTH string-key and two-field ProtectedItem APIs!
            for (String specialKey : new String[] {"film:hk", "film-hk"}) {
                for (boolean useStructuredItems : new boolean[] {false, true}) {
                    for (boolean colonInVodId : new boolean[] {false, true}) {
                        Map<String, GlobalSearchScreen.SourceResult> map = new LinkedHashMap<>();
                        List<String> keysOrder = new ArrayList<>();
                        keysOrder.add("B");
                        keysOrder.add("film");
                        for (int i = 0; i < 12; i++) keysOrder.add("background-" + i);
                        keysOrder.add(specialKey);
                        for (String key : keysOrder) {
                            final String siteKey = key;
                            TvSearchPages first =
                                    TvSearchPages.firstVideos(
                                            q,
                                            Collections.singletonList(q),
                                            fuzzyPred,
                                            (term, page) -> {
                                                Cms.Listing l = new Cms.Listing();
                                                l.page = page;
                                                l.pageCount = 3;
                                                for (int idx = 0; idx < 60; idx++) {
                                                    int idNum = 60 * (page - 1) + idx + 1;
                                                    Cms.Video v = new Cms.Video();
                                                    v.id = colonInVodId ? ("ep:" + idNum + ":hd") : ("p" + idNum);
                                                    v.title =
                                                            siteKey.equals(specialKey)
                                                                    ? (q + "外传" + idNum)
                                                                    : ("纪实" + q + idNum);
                                                    l.videos.add(v);
                                                }
                                                return l;
                                            },
                                            60);
                            map.put(
                                    siteKey,
                                    new GlobalSearchScreen.SourceResult(
                                            site(siteKey, siteKey),
                                            first.videos,
                                            SearchCoordinator.Outcome.RESULT,
                                            first));
                        }
                        List<TvSearchMatcher.RankedHit> rankedBefore =
                                TvSearchMatcher.collectAndRank(
                                        TvSearchMatcher.Mode.FUZZY,
                                        q,
                                        new ArrayList<>(map.values()),
                                        "",
                                        "",
                                        phonetic);
                        List<TvSearchMatcher.RankedHit> visBefore =
                                GlobalSearchScreen.projectVisibleHits(
                                        rankedBefore, 24, Collections.emptyList(), "", false);
                        List<String> visKeysBefore = new ArrayList<>();
                        List<TvSearchBudget.ProtectedItem> visItemsBefore = new ArrayList<>();
                        for (TvSearchMatcher.RankedHit h : visBefore) {
                            visKeysBefore.add(h.stableKey());
                            visItemsBefore.add(new TvSearchBudget.ProtectedItem(h.site.key, h.video.id));
                        }
                        String focusKey = visKeysBefore.get(23);
                        GlobalSearchScreen.SourceResult bSrc = map.get("B");
                        TvSearchPages bNext =
                                bSrc.pages.nextVideos(
                                        fuzzyPred,
                                        (term, page) -> {
                                            Cms.Listing l = new Cms.Listing();
                                            l.page = page;
                                            l.pageCount = 3;
                                            for (int idx = 0; idx < 60; idx++) {
                                                int idNum = 60 * (page - 1) + idx + 1;
                                                Cms.Video v = new Cms.Video();
                                                v.id = colonInVodId ? ("ep:" + idNum + ":hd") : ("p" + idNum);
                                                v.title = "纪实" + q + idNum;
                                                l.videos.add(v);
                                            }
                                            return l;
                                        },
                                        60,
                                        cap);
                        map.put(
                                "B",
                                new GlobalSearchScreen.SourceResult(
                                        bSrc.site, bNext.videos, SearchCoordinator.Outcome.RESULT, bNext));
                        if (useStructuredItems) {
                            TvSearchBudget.enforceGlobalResultsCapByItems(
                                    map, "", "B", visItemsBefore, cap);
                        } else {
                            TvSearchBudget.enforceGlobalResultsCap(
                                    map, "", "B", visKeysBefore, cap);
                        }
                        int totalAfter = 0;
                        for (GlobalSearchScreen.SourceResult sr : map.values()) {
                            totalAfter += sr.videos.size();
                        }
                        List<TvSearchMatcher.RankedHit> rankedAfter =
                                TvSearchMatcher.collectAndRank(
                                        TvSearchMatcher.Mode.FUZZY,
                                        q,
                                        new ArrayList<>(map.values()),
                                        "",
                                        "",
                                        phonetic);
                        List<TvSearchMatcher.RankedHit> visAfter =
                                GlobalSearchScreen.projectVisibleHits(
                                        rankedAfter, 24, visKeysBefore, focusKey, true);
                        List<String> visKeysAfter = new ArrayList<>();
                        for (TvSearchMatcher.RankedHit h : visAfter) visKeysAfter.add(h.stableKey());
                        check(
                                totalAfter <= cap
                                        && map.get(specialKey).videos.size() == 60
                                        && visKeysAfter.size() == 24
                                        && visKeysAfter.indexOf(focusKey) == 23
                                        && visKeysAfter.get(0).equals(visKeysBefore.get(0)),
                                "R17 P2b (key="
                                        + specialKey
                                        + ", structured="
                                        + useStructuredItems
                                        + ", colonVod="
                                        + colonInVodId
                                        + "): retains 60 items, total<=900, focused index stays 23");
                    }
                }
            }
        }

        // R18 P2: Unambiguous two-field (siteKey, vodId) identity across dedup, bijective
        // stableKey, card tags, pagination/focus anchors, and budget protection.
        // Concrete collision pair: (site="film", vod="hk:p24", title="三体前传") vs
        // (site="film:hk", vod="p24", title="三体") under fuzzy query "三体".
        {
            TvSearchMatcher.HitId idA = new TvSearchMatcher.HitId("film", "hk:p24");
            TvSearchMatcher.HitId idB = new TvSearchMatcher.HitId("film:hk", "p24");
            check(!idA.equals(idB), "R18 P2: HitId distinguishes (film, hk:p24) vs (film:hk, p24)");
            check(
                    "film:hk%3Ap24".equals(idA.stableKey())
                            && "film%3Ahk:p24".equals(idB.stableKey())
                            && !idA.stableKey().equals(idB.stableKey()),
                    "R18 P2: bijective stableKey avoids colon boundary collision");
            check(
                    "star_a:p24".equals(TvSearchMatcher.stableKey("star_a", "p24")),
                    "R18 P2: plain keys without colons/percent stay backward-compatible");
            TvSearchMatcher.HitId literalPercent =
                    new TvSearchMatcher.HitId("film%3Ahk", "p%25:1");
            check(
                    literalPercent.equals(TvSearchMatcher.HitId.parseKey(literalPercent.stableKey()))
                            && idA.equals(TvSearchMatcher.HitId.parseKey(idA.stableKey()))
                            && idB.equals(TvSearchMatcher.HitId.parseKey(idB.stableKey())),
                    "R18 P2: HitId.parseKey round-trips colon and literal percent escapes losslessly");

            Cms.Site siteFilm = new Cms.Site();
            siteFilm.key = "film";
            siteFilm.name = "Film";
            Cms.Video vPrequel = new Cms.Video();
            vPrequel.id = "hk:p24";
            vPrequel.title = "三体前传";

            Cms.Site siteFilmHk = new Cms.Site();
            siteFilmHk.key = "film:hk";
            siteFilmHk.name = "Film HK";
            Cms.Video vExact = new Cms.Video();
            vExact.id = "p24";
            vExact.title = "三体";

            GlobalSearchScreen.SourceResult srFilm =
                    new GlobalSearchScreen.SourceResult(
                            siteFilm,
                            Collections.singletonList(vPrequel),
                            SearchCoordinator.Outcome.RESULT);
            GlobalSearchScreen.SourceResult srFilmHk =
                    new GlobalSearchScreen.SourceResult(
                            siteFilmHk,
                            Collections.singletonList(vExact),
                            SearchCoordinator.Outcome.RESULT);

            // Both arrival orders must preserve both items on "全部" with exact title "三体" at #0.
            for (int order = 0; order < 2; order++) {
                List<GlobalSearchScreen.SourceResult> pair =
                        order == 0
                                ? Arrays.asList(srFilm, srFilmHk)
                                : Arrays.asList(srFilmHk, srFilm);
                List<TvSearchMatcher.RankedHit> allHits =
                        TvSearchMatcher.collectAndRank(
                                TvSearchMatcher.Mode.FUZZY, "三体", pair, "", "", phonetic);
                check(
                        allHits.size() == 2
                                && "film:hk".equals(allHits.get(0).site.key)
                                && "p24".equals(allHits.get(0).video.id)
                                && "三体".equals(allHits.get(0).video.title)
                                && "film%3Ahk:p24".equals(allHits.get(0).stableKey())
                                && "film".equals(allHits.get(1).site.key)
                                && "hk:p24".equals(allHits.get(1).video.id)
                                && "三体前传".equals(allHits.get(1).video.title)
                                && "film:hk%3Ap24".equals(allHits.get(1).stableKey()),
                        "R18 P2 order="
                                + order
                                + ": All tab keeps both (film:hk,p24) and (film,hk:p24) with exact title first");

                // Single-source filters still yield 1 item each with the same bijective key.
                List<TvSearchMatcher.RankedHit> onlyFilm =
                        TvSearchMatcher.collectAndRank(
                                TvSearchMatcher.Mode.FUZZY, "三体", pair, "film", "", phonetic);
                List<TvSearchMatcher.RankedHit> onlyFilmHk =
                        TvSearchMatcher.collectAndRank(
                                TvSearchMatcher.Mode.FUZZY, "三体", pair, "film:hk", "", phonetic);
                check(
                        onlyFilm.size() == 1
                                && "film:hk%3Ap24".equals(onlyFilm.get(0).stableKey())
                                && onlyFilmHk.size() == 1
                                && "film%3Ahk:p24".equals(onlyFilmHk.get(0).stableKey()),
                        "R18 P2 order=" + order + ": single-source tabs keep matching bijective keys");

                // Late-arrival focus projection & pagination anchor keep the exact focused card.
                List<String> prevKeys = Collections.singletonList("film:hk%3Ap24");
                List<TvSearchMatcher.RankedHit> projected =
                        GlobalSearchScreen.projectVisibleHits(
                                allHits, 2, prevKeys, "film:hk%3Ap24", true);
                check(
                        projected.size() == 2
                                && "film:hk%3Ap24".equals(projected.get(0).stableKey())
                                && "film%3Ahk:p24".equals(projected.get(1).stableKey()),
                        "R18 P2 order="
                                + order
                                + ": late arrival of (film:hk,p24) preserves focus on (film,hk:p24) without dropping either");
                int pageFocusIdx =
                        GlobalSearchScreen.resolvePaginationFocusIndex(
                                allHits,
                                Collections.singleton("film:hk%3Ap24"),
                                1,
                                "film:hk%3Ap24");
                check(
                        pageFocusIdx == 0
                                && "film%3Ahk:p24".equals(allHits.get(pageFocusIdx).stableKey()),
                        "R18 P2 order=" + order + ": pagination focus recognizes newly revealed distinct key");
            }

            // True duplicate control: same site + same vodId still deduplicates to 1.
            Cms.Video vPrequelDup = new Cms.Video();
            vPrequelDup.id = "hk:p24";
            vPrequelDup.title = "三体前传";
            Cms.Video vExactDup = new Cms.Video();
            vExactDup.id = "p24";
            vExactDup.title = "三体";
            GlobalSearchScreen.SourceResult srFilmDup =
                    new GlobalSearchScreen.SourceResult(
                            siteFilm,
                            Arrays.asList(vPrequel, vPrequelDup),
                            SearchCoordinator.Outcome.RESULT);
            GlobalSearchScreen.SourceResult srFilmHkDup =
                    new GlobalSearchScreen.SourceResult(
                            siteFilmHk,
                            Arrays.asList(vExact, vExactDup),
                            SearchCoordinator.Outcome.RESULT);
            List<TvSearchMatcher.RankedHit> r18DedupHits =
                    TvSearchMatcher.collectAndRank(
                            TvSearchMatcher.Mode.FUZZY,
                            "三体",
                            Arrays.asList(srFilmDup, srFilmHkDup),
                            "",
                            "",
                            phonetic);
            check(
                    r18DedupHits.size() == 2,
                    "R18 P2: true duplicates (same siteKey + same vodId) still deduplicate cleanly");

            // Budget protection using canonical bijective key protects ONLY the named source.
            LinkedHashMap<String, GlobalSearchScreen.SourceResult> budgetMap =
                    new LinkedHashMap<>();
            budgetMap.put("film", srFilm);
            budgetMap.put("film:hk", srFilmHk);
            TvSearchBudget.enforceGlobalResultsCap(
                    budgetMap, "", "other", Collections.singletonList("film%3Ahk:p24"), 1);
            check(
                    budgetMap.get("film:hk").videos.size() == 1
                            && budgetMap.get("film").videos.isEmpty(),
                    "R18 P2: budget protection with bijective key film%3Ahk:p24 protects film:hk only");
        }

        JSONObject summary =
                new JSONObject()
                        .put("ok", true)
                        .put("total_checks", checks)
                        .put("cases_source", Files.isRegularFile(casesPath) ? casesPath.toString() : "embedded")
                        .put("cases", reportCases);
        if (outJsonPath != null) {
            Files.createDirectories(outJsonPath.toAbsolutePath().getParent());
            Files.write(
                    outJsonPath,
                    summary.toString(2).getBytes(StandardCharsets.UTF_8));
        }
        System.out.println("ALL PASS (" + checks + " TV search acceptance checks)");
    }
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import com.pilipala.source.Json;
import com.pilipala.source.Warehouse;
import java.io.*;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import org.json.*;

public final class LiteConformanceChecks {
    private static int passCount = 0;
    private static int failCount = 0;

    private static Path resolveConformanceDir(Path root) {
        Path[] candidates = new Path[] {
            root.resolve("shared/conformance"),
            root.resolve("../shared/conformance"),
            root.resolve("../../shared/conformance"),
            Paths.get("shared/conformance"),
            Paths.get("../shared/conformance"),
        };
        for (Path p : candidates) {
            if (Files.isDirectory(p)) return p.toAbsolutePath().normalize();
        }
        throw new IllegalStateException("Cannot locate shared/conformance/ directory from " + root);
    }

    private static String resolveUrl(String origin, String target) {
        if (target == null || target.isEmpty()) return "";
        if (origin == null || origin.isEmpty()) return target;
        try {
            return new URL(new URL(origin), target).toString();
        } catch (Exception e) {
            return target;
        }
    }

    private static boolean isDirectStreamUrl(String value) {
        if (value == null || value.isEmpty()) return false;
        String lower = value.trim().toLowerCase(Locale.ROOT);
        String path = lower.split("[?#]", 2)[0];
        return path.endsWith(".m3u8")
                || path.endsWith(".mp4")
                || path.endsWith(".flv")
                || path.endsWith(".mkv")
                || path.endsWith(".ts")
                || path.endsWith(".webm")
                || path.endsWith(".mpd")
                || lower.contains(".m3u8?")
                || lower.contains(".mp4?");
    }

    private static JSONObject applyPlatformOverrides(JSONObject expected, String platform) throws Exception {
        JSONObject copy = new JSONObject(expected.toString());
        JSONObject overrides = copy.optJSONObject("platformOverrides");
        if (overrides != null) {
            JSONObject platObj = overrides.optJSONObject(platform);
            if (platObj != null) {
                JSONArray overrideSites = platObj.optJSONArray("sites");
                JSONArray expSites = copy.optJSONArray("sites");
                if (overrideSites != null && expSites != null) {
                    for (int i = 0; i < overrideSites.length(); i++) {
                        JSONObject oSite = overrideSites.getJSONObject(i);
                        String key = oSite.optString("key");
                        for (int j = 0; j < expSites.length(); j++) {
                            JSONObject eSite = expSites.getJSONObject(j);
                            if (key.equals(eSite.optString("key"))) {
                                Iterator<String> it = oSite.keys();
                                while (it.hasNext()) {
                                    String k = it.next();
                                    eSite.put(k, oSite.get(k));
                                }
                            }
                        }
                    }
                }
                Iterator<String> topIt = platObj.keys();
                while (topIt.hasNext()) {
                    String k = topIt.next();
                    if (!"sites".equals(k)) {
                        copy.put(k, platObj.get(k));
                    }
                }
            }
        }
        return copy;
    }

    private static JSONObject normalizeConfig(List<LiteCatalog.Site> sites, JSONArray depots, JSONObject rootDoc, String origin) throws Exception {
        JSONObject out = new JSONObject();
        JSONArray sitesArr = new JSONArray();
        for (LiteCatalog.Site s : sites) {
            JSONObject sObj = new JSONObject();
            sObj.put("key", s.key);
            sObj.put("name", s.name);
            sObj.put("type", s.type);
            sObj.put("api", s.api);
            sObj.put("jar", s.jar == null ? "" : s.jar);
            sObj.put("playUrl", s.playUrl == null ? "" : s.playUrl);
            sObj.put("searchable", s.searchable);
            sObj.put("supported", s.supported);
            sObj.put("requiresParser", s.requiresParser);
            sObj.put("extTooLarge", s.isExtTooLarge());
            sObj.put("capabilityStatus", s.capabilityStatus());
            sObj.put("ext", s.ext == null || JSONObject.NULL.equals(s.ext) ? "" : s.ext);
            JSONObject headers = new JSONObject();
            for (Map.Entry<String, String> h : s.headers.entrySet()) {
                headers.put(h.getKey(), h.getValue());
            }
            sObj.put("headers", headers);
            sitesArr.put(sObj);
        }
        out.put("sites", sitesArr);
        if (depots != null && depots.length() > 0) {
            out.put("depots", depots);
        }
        if (rootDoc != null) {
            JSONArray parses = rootDoc.optJSONArray("parses");
            if (parses != null && parses.length() > 0) {
                JSONArray parsesArr = new JSONArray();
                for (int i = 0; i < parses.length(); i++) {
                    JSONObject pj = parses.optJSONObject(i);
                    if (pj != null) {
                        JSONObject pObj = new JSONObject();
                        pObj.put("name", pj.optString("name", ""));
                        pObj.put("url", pj.optString("url", ""));
                        pObj.put("type", pj.optInt("type", 0));
                        JSONObject pHeaders = new JSONObject();
                        JSONObject h = pj.optJSONObject("headers");
                        if (h != null) {
                            Iterator<String> hit = h.keys();
                            while (hit.hasNext()) {
                                String hk = hit.next();
                                pHeaders.put(hk, h.optString(hk));
                            }
                        }
                        pObj.put("headers", pHeaders);
                        parsesArr.put(pObj);
                    }
                }
                out.put("parses", parsesArr);
            }
            String rawSpider = rootDoc.optString("spider", "");
            if (rawSpider.isEmpty()) rawSpider = rootDoc.optString("jar", "");
            if (!rawSpider.isEmpty()) {
                String[] spParts = rawSpider.split(";md5;", 2);
                String resolvedSpider = (origin != null && !origin.isEmpty() && (spParts[0].startsWith("./") || spParts[0].startsWith("../")))
                    ? resolveUrl(origin, spParts[0])
                    : spParts[0];
                out.put("spider", resolvedSpider + (spParts.length == 2 ? ";md5;" + spParts[1] : ""));
            }
        }
        return out;
    }

    private static JSONObject normalizeListing(JSONObject root) throws Exception {
        JSONObject out = new JSONObject();
        out.put("page", root.optInt("page", 1));
        out.put("pageCount", root.optInt("pagecount", root.optInt("pageCount", 1)));
        JSONArray list = root.optJSONArray("list");
        JSONArray videosArr = new JSONArray();
        if (list != null) {
            for (int i = 0; i < list.length(); i++) {
                JSONObject item = list.getJSONObject(i);
                JSONObject vObj = new JSONObject();
                vObj.put("id", item.optString("vod_id", item.optString("id", "")));
                vObj.put("title", item.optString("vod_name", item.optString("title", "")));
                List<JSONObject> linesList = new ArrayList<>();
                if (item.has("vod_play_list")) {
                    JSONArray playList = item.optJSONArray("vod_play_list");
                    if (playList != null) {
                        for (int j = 0; j < playList.length(); j++) {
                            JSONObject lineObj = playList.getJSONObject(j);
                            JSONObject lObj = new JSONObject();
                            JSONObject pInfo = lineObj.optJSONObject("player_info");
                            String lineName = pInfo != null
                                ? pInfo.optString("show", pInfo.optString("from", "线路 " + (j + 1)))
                                : lineObj.optString("show", lineObj.optString("name", lineObj.optString("from", "线路 " + (j + 1))));
                            lObj.put("name", lineName);
                            JSONArray epsArr = new JSONArray();
                            Object urlsRaw = lineObj.opt("urls");
                            if (urlsRaw instanceof JSONArray) {
                                JSONArray urlsArr = (JSONArray) urlsRaw;
                                for (int k = 0; k < urlsArr.length(); k++) {
                                    JSONObject urlObj = urlsArr.getJSONObject(k);
                                    JSONObject eObj = new JSONObject();
                                    eObj.put("name", urlObj.optString("name", ""));
                                    eObj.put("url", urlObj.optString("url", ""));
                                    epsArr.put(eObj);
                                }
                            } else if (urlsRaw instanceof JSONObject) {
                                JSONObject urlsObj = (JSONObject) urlsRaw;
                                Iterator<String> uIt = urlsObj.keys();
                                while (uIt.hasNext()) {
                                    JSONObject urlObj = urlsObj.optJSONObject(uIt.next());
                                    if (urlObj == null) continue;
                                    JSONObject eObj = new JSONObject();
                                    eObj.put("name", urlObj.optString("name", ""));
                                    eObj.put("url", urlObj.optString("url", ""));
                                    epsArr.put(eObj);
                                }
                            }
                            String singleUrl = lineObj.optString("url", "");
                            if (!singleUrl.isEmpty()) {
                                for (String seg : singleUrl.split("#")) {
                                    String trimmedSeg = seg.trim();
                                    if (trimmedSeg.isEmpty()) continue;
                                    int sep = trimmedSeg.indexOf('$');
                                    JSONObject eObj = new JSONObject();
                                    if (sep < 0) {
                                        eObj.put("name", "第" + (epsArr.length() + 1) + "集");
                                        eObj.put("url", trimmedSeg);
                                    } else {
                                        eObj.put("name", trimmedSeg.substring(0, sep).trim());
                                        eObj.put("url", trimmedSeg.substring(sep + 1).trim());
                                    }
                                    epsArr.put(eObj);
                                }
                            }
                            lObj.put("episodes", epsArr);
                            linesList.add(lObj);
                        }
                    }
                } else if (item.has("vod_play_url") || item.has("vod_play_from")) {
                    String fromStr = item.optString("vod_play_from", "默认");
                    String urlStr = item.optString("vod_play_url", "");
                    String[] froms = fromStr.split("\\$\\$\\$");
                    String[] rawLines = urlStr.split("\\$\\$\\$");
                    for (int j = 0; j < rawLines.length; j++) {
                        JSONObject lObj = new JSONObject();
                        String lineName = j < froms.length && !froms[j].trim().isEmpty() ? froms[j].trim() : ("线路 " + (j + 1));
                        lObj.put("name", lineName);
                        JSONArray epsArr = new JSONArray();
                        String[] entries = rawLines[j].split("#");
                        for (int k = 0; k < entries.length; k++) {
                            String entry = entries[k].trim();
                            if (entry.isEmpty()) continue;
                            int sep = entry.indexOf('$');
                            String eName, eUrl;
                            if (sep < 0) {
                                eName = "第" + (epsArr.length() + 1) + "集";
                                eUrl = entry;
                            } else {
                                eName = entry.substring(0, sep).trim();
                                eUrl = entry.substring(sep + 1).trim();
                            }
                            JSONObject eObj = new JSONObject();
                            eObj.put("name", eName);
                            eObj.put("url", eUrl);
                            epsArr.put(eObj);
                        }
                        lObj.put("episodes", epsArr);
                        linesList.add(lObj);
                    }
                }
                // Prioritize direct stream lines
                List<JSONObject> direct = new ArrayList<>();
                List<JSONObject> indirect = new ArrayList<>();
                for (JSONObject l : linesList) {
                    JSONArray eps = l.optJSONArray("episodes");
                    boolean hasDirect = false;
                    if (eps != null && eps.length() > 0) {
                        String firstUrl = eps.getJSONObject(0).optString("url", "");
                        String lName = l.optString("name", "");
                        if (isDirectStreamUrl(firstUrl) || lName.toLowerCase(Locale.ROOT).contains("m3u8")) {
                            hasDirect = true;
                        }
                    }
                    if (hasDirect) direct.add(l);
                    else indirect.add(l);
                }
                JSONArray finalLines = new JSONArray();
                for (JSONObject d : direct) finalLines.put(d);
                for (JSONObject ind : indirect) finalLines.put(ind);

                vObj.put("lines", finalLines);
                videosArr.put(vObj);
            }
        }
        out.put("videos", videosArr);
        return out;
    }

    private static void assertConfigMatches(JSONObject actual, JSONObject expected, String caseId) throws Exception {
        if (expected.has("sites")) {
            JSONArray expSites = expected.getJSONArray("sites");
            JSONArray actSites = actual.getJSONArray("sites");
            if (expSites.length() != actSites.length()) {
                throw new AssertionError("[" + caseId + "] sites count mismatch: expected "
                    + expSites.length() + ", got " + actSites.length());
            }
            for (int i = 0; i < expSites.length(); i++) {
                JSONObject exp = expSites.getJSONObject(i);
                JSONObject act = actSites.getJSONObject(i);
                Iterator<String> it = exp.keys();
                while (it.hasNext()) {
                    String k = it.next();
                    if ("headers".equals(k)) {
                        JSONObject expH = exp.getJSONObject("headers");
                        JSONObject actH = act.optJSONObject("headers");
                        if (actH == null) throw new AssertionError("[" + caseId + "] missing headers in site " + i);
                        Iterator<String> hIt = expH.keys();
                        while (hIt.hasNext()) {
                            String hKey = hIt.next();
                            if (!expH.getString(hKey).equals(actH.optString(hKey))) {
                                throw new AssertionError("[" + caseId + "] site " + i + " header " + hKey
                                    + " mismatch: expected " + expH.getString(hKey) + ", got " + actH.optString(hKey));
                            }
                        }
                    } else if ("ext".equals(k) && exp.get("ext") instanceof JSONObject) {
                        JSONObject expExt = exp.getJSONObject("ext");
                        Object actExtRaw = act.opt("ext");
                        JSONObject actExt = actExtRaw instanceof JSONObject ? (JSONObject) actExtRaw : null;
                        if (actExt == null && actExtRaw instanceof String) {
                            try { actExt = new JSONObject((String) actExtRaw); } catch (Exception ignored) {}
                        }
                        if (actExt == null) throw new AssertionError("[" + caseId + "] site " + i + " ext must be JSONObject");
                        Iterator<String> extIt = expExt.keys();
                        while (extIt.hasNext()) {
                            String ek = extIt.next();
                            String ev = String.valueOf(expExt.get(ek));
                            String av = String.valueOf(actExt.opt(ek));
                            if (!ev.equals(av)) {
                                throw new AssertionError("[" + caseId + "] site " + i + " ext." + ek + " mismatch: expected " + ev + ", got " + av);
                            }
                        }
                    } else if (!"platformOverrides".equals(k)) {
                        String expVal = String.valueOf(exp.get(k));
                        String actVal = String.valueOf(act.opt(k));
                        if (!expVal.equals(actVal)) {
                            throw new AssertionError("[" + caseId + "] site " + i + " field " + k
                                + " mismatch: expected " + expVal + ", got " + actVal);
                        }
                    }
                }
            }
        }
        if (expected.has("depots")) {
            int expLen = expected.getJSONArray("depots").length();
            int actLen = actual.optJSONArray("depots") == null ? 0 : actual.optJSONArray("depots").length();
            if (expLen != actLen) {
                throw new AssertionError("[" + caseId + "] depots length mismatch");
            }
            JSONArray expD = expected.getJSONArray("depots");
            JSONArray actD = actual.getJSONArray("depots");
            for (int i = 0; i < expLen; i++) {
                JSONObject ed = expD.getJSONObject(i);
                JSONObject ad = actD.getJSONObject(i);
                if (!ed.getString("name").equals(ad.getString("name"))) {
                    throw new AssertionError("[" + caseId + "] depot " + i + " name mismatch");
                }
                if (!ed.getString("url").equals(ad.getString("url"))) {
                    throw new AssertionError("[" + caseId + "] depot " + i + " url mismatch");
                }
            }
        }
        if (expected.has("parses")) {
            int expLen = expected.getJSONArray("parses").length();
            int actLen = actual.optJSONArray("parses") == null ? 0 : actual.optJSONArray("parses").length();
            if (expLen != actLen) {
                throw new AssertionError("[" + caseId + "] parses length mismatch");
            }
            JSONArray expP = expected.getJSONArray("parses");
            JSONArray actP = actual.getJSONArray("parses");
            for (int i = 0; i < expLen; i++) {
                JSONObject ep = expP.getJSONObject(i);
                JSONObject ap = actP.getJSONObject(i);
                if (!ep.getString("name").equals(ap.getString("name"))) {
                    throw new AssertionError("[" + caseId + "] parse " + i + " name mismatch");
                }
                if (!ep.getString("url").equals(ap.getString("url"))) {
                    throw new AssertionError("[" + caseId + "] parse " + i + " url mismatch");
                }
                if (ep.getInt("type") != ap.getInt("type")) {
                    throw new AssertionError("[" + caseId + "] parse " + i + " type mismatch");
                }
            }
        }
        if (expected.has("spider")) {
            String expSpider = expected.getString("spider");
            String actSpider = actual.optString("spider", "");
            if (!expSpider.equals(actSpider)) {
                throw new AssertionError("[" + caseId + "] spider mismatch: expected " + expSpider + ", got " + actSpider);
            }
        }
    }

    private static void assertListingMatches(JSONObject actual, JSONObject expected, String caseId) throws Exception {
        if (expected.has("page") && actual.getInt("page") != expected.getInt("page")) {
            throw new AssertionError("[" + caseId + "] page mismatch");
        }
        if (expected.has("pageCount") && actual.getInt("pageCount") != expected.getInt("pageCount")) {
            throw new AssertionError("[" + caseId + "] pageCount mismatch");
        }
        if (expected.has("videos")) {
            JSONArray expV = expected.getJSONArray("videos");
            JSONArray actV = actual.optJSONArray("videos");
            if (actV == null || expV.length() != actV.length()) {
                throw new AssertionError("[" + caseId + "] videos count mismatch");
            }
            for (int i = 0; i < expV.length(); i++) {
                JSONObject eV = expV.getJSONObject(i);
                JSONObject aV = actV.getJSONObject(i);
                if (eV.has("id")) {
                    if (!eV.getString("id").equals(aV.optString("id"))) {
                        throw new AssertionError("[" + caseId + "] video " + i + " id mismatch");
                    }
                }
                if (eV.has("title")) {
                    if (!eV.getString("title").equals(aV.optString("title"))) {
                        throw new AssertionError("[" + caseId + "] video " + i + " title mismatch");
                    }
                }
                if (eV.has("lines")) {
                    JSONArray expL = eV.getJSONArray("lines");
                    JSONArray actL = aV.optJSONArray("lines");
                    if (actL == null || expL.length() != actL.length()) {
                        throw new AssertionError("[" + caseId + "] video " + i + " lines count mismatch");
                    }
                    for (int j = 0; j < expL.length(); j++) {
                        JSONObject eL = expL.getJSONObject(j);
                        JSONObject aL = actL.getJSONObject(j);
                        if (!eL.getString("name").equals(aL.getString("name"))) {
                            throw new AssertionError("[" + caseId + "] video " + i + " line " + j + " name mismatch: expected "
                                + eL.getString("name") + ", got " + aL.getString("name"));
                        }
                        if (eL.has("episodes")) {
                            JSONArray expEps = eL.getJSONArray("episodes");
                            JSONArray actEps = aL.optJSONArray("episodes");
                            if (actEps == null || expEps.length() != actEps.length()) {
                                throw new AssertionError("[" + caseId + "] video " + i + " line " + j + " episodes count mismatch");
                            }
                            for (int k = 0; k < expEps.length(); k++) {
                                JSONObject eEp = expEps.getJSONObject(k);
                                JSONObject aEp = actEps.getJSONObject(k);
                                if (!eEp.getString("name").equals(aEp.getString("name"))) {
                                    throw new AssertionError("[" + caseId + "] video " + i + " line " + j + " episode " + k + " name mismatch");
                                }
                                if (!eEp.getString("url").equals(aEp.getString("url"))) {
                                    throw new AssertionError("[" + caseId + "] video " + i + " line " + j + " episode " + k + " url mismatch");
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    public static void main(String[] args) throws Exception {
        Path root = Paths.get(args.length > 0 ? args[0] : ".");
        Path conformanceDir = resolveConformanceDir(root);

        File[] caseDirs = conformanceDir.toFile().listFiles(File::isDirectory);
        if (caseDirs == null || caseDirs.length == 0) {
            throw new IllegalStateException("No case directories found in " + conformanceDir);
        }
        Arrays.sort(caseDirs, Comparator.comparing(File::getName));

        System.out.println("=== Tri-Platform Conformance Suite: TV Lite Runner ===");
        System.out.println("Discovered " + caseDirs.length + " cases in " + conformanceDir);

        for (File dir : caseDirs) {
            String caseId = dir.getName();
            if (!caseId.startsWith("case_")) continue;
            try {
                Path inputPath = dir.toPath().resolve("input.bin");
                Path metaPath = dir.toPath().resolve("meta.json");
                Path expectedPath = dir.toPath().resolve("expected.json");

                byte[] inputBytes = Files.readAllBytes(inputPath);
                JSONObject meta = new JSONObject(new String(Files.readAllBytes(metaPath), StandardCharsets.UTF_8));
                JSONObject rawExpected = new JSONObject(new String(Files.readAllBytes(expectedPath), StandardCharsets.UTF_8));
                JSONObject expected = applyPlatformOverrides(rawExpected, "lite");

                if (expected.optBoolean("skip", false)) {
                    System.out.println("SKIP " + caseId + " (platformOverrides.lite.skip=true)");
                    passCount++;
                    continue;
                }

                String entrypoint = meta.optString("entrypoint", meta.optString("type", "config")).toLowerCase(Locale.ROOT);
                String origin = meta.optString("origin", "");
                boolean expectError = expected.optBoolean("error", false);

                if (expectError) {
                    try {
                        String text = LiteCatalog.decodeText(inputBytes);
                        LiteCatalog.parse(text, origin);
                        throw new AssertionError("[" + caseId + "] Expected exception was not thrown");
                    } catch (Exception ex) {
                        System.out.println("PASS " + caseId + " (caught expected error: " + ex.getMessage() + ")");
                        passCount++;
                        continue;
                    }
                }

                if ("listing".equals(entrypoint) || "lines".equals(entrypoint)) {
                    String text = LiteCatalog.decodeText(inputBytes);
                    JSONObject cmsRoot = LiteCatalog.parseCmsResponse(text);
                    JSONObject actual = normalizeListing(cmsRoot);
                    assertListingMatches(actual, expected, caseId);
                } else {
                    String text = LiteCatalog.decodeText(inputBytes);
                    JSONObject rootJson = LiteCatalog.decodeConfig(text);
                    List<LiteCatalog.Site> sites;
                    JSONArray depots = null;
                    if (Warehouse.isCatalog(rootJson)) {
                        sites = Collections.emptyList();
                        depots = Warehouse.depots(rootJson, origin);
                    } else {
                        sites = LiteCatalog.parse(text, origin);
                    }
                    JSONObject actual = normalizeConfig(sites, depots, rootJson, origin);
                    assertConfigMatches(actual, expected, caseId);
                }
                System.out.println("PASS " + caseId);
                passCount++;
            } catch (Throwable t) {
                System.out.println("FAIL " + caseId + ": " + t.getMessage());
                t.printStackTrace(System.out);
                failCount++;
            }
        }

        System.out.println("\nLite Conformance Summary: " + passCount + " PASSED, " + failCount + " FAILED");
        if (failCount > 0) {
            System.exit(1);
        }
    }
}

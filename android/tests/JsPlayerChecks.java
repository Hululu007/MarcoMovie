package com.pilipala.marcomovie;

import java.nio.file.*;
import org.json.*;

public final class JsPlayerChecks {
    private static int checks;

    private static void check(boolean pass, String label) {
        if (!pass) throw new AssertionError(label);
        checks++;
        System.out.println("PASS " + label);
    }

    private static JSONObject normalize(JSONObject result) throws Exception {
        return new JSONObject(JsEngine.normalizePlayerResult(result.toString()));
    }

    public static void main(String[] args) throws Exception {
        Cms.Site jarScript = new Cms.Site();
        jarScript.type = 3;
        jarScript.api = "https://x/a.jar";
        check(!JsEngine.eligible(jarScript), "jar endpoint is not eligible as script source");

        Cms.Site cspScript = new Cms.Site();
        cspScript.type = 3;
        cspScript.api = "https://fixture.invalid/csp_custom";
        check(!JsEngine.eligible(cspScript), "csp endpoint is not eligible as script source");

        Cms.Site subpathCsp = new Cms.Site();
        subpathCsp.type = 3;
        subpathCsp.api = "https://a.com/sub/csp_app";
        check(
                !JsEngine.eligible(subpathCsp),
                "subpath csp endpoint is not eligible as script source");

        Cms.Site subpathCspQueryFrag = new Cms.Site();
        subpathCspQueryFrag.type = 3;
        subpathCspQueryFrag.api = "https://a.com/sub/csp_app?token=123#frag";
        check(
                !JsEngine.eligible(subpathCspQueryFrag),
                "subpath csp endpoint with query and fragment is not eligible");

        Cms.Site spidersCsp = new Cms.Site();
        spidersCsp.type = 3;
        spidersCsp.api = "http://box/spiders/csp_app";
        check(
                !JsEngine.eligible(spidersCsp),
                "http spiders csp endpoint is not eligible as script source");

        Cms.Site deepCsp = new Cms.Site();
        deepCsp.type = 3;
        deepCsp.api = "https://example.com/a/b/c/csp_custom";
        check(
                !JsEngine.eligible(deepCsp),
                "deeply nested csp endpoint is not eligible as script source");

        Cms.Site trailingSlashCsp = new Cms.Site();
        trailingSlashCsp.type = 3;
        trailingSlashCsp.api = "https://a.com/a/b/csp_xyz/";
        check(
                !JsEngine.eligible(trailingSlashCsp),
                "nested csp endpoint with trailing slash is rejected");

        Cms.Site gatewayScript = new Cms.Site();
        gatewayScript.type = 3;
        gatewayScript.api = "https://x/api/drpy?id=1";
        check(JsEngine.eligible(gatewayScript), "extensionless type 3 remote script is eligible");

        Cms.Site queryTokenCsp = new Cms.Site();
        queryTokenCsp.type = 3;
        queryTokenCsp.api = "https://x/api/drpy?token=csp_123";
        check(
                JsEngine.eligible(queryTokenCsp),
                "query param with csp_ remains eligible script source");

        Cms.Site queryParamCsp = new Cms.Site();
        queryParamCsp.type = 3;
        queryParamCsp.api = "https://server.com/api/drpy?csp_=1#csp_hash";
        check(
                JsEngine.eligible(queryParamCsp),
                "query key and fragment with csp_ remain eligible script source");

        Cms.Site nonCspSubstr = new Cms.Site();
        nonCspSubstr.type = 3;
        nonCspSubstr.api = "https://x/sub/my_csp_app";
        check(
                JsEngine.eligible(nonCspSubstr),
                "non-segment csp substring remains eligible script source");

        Cms.Site contentScript = new Cms.Site();
        contentScript.type = 3;
        contentScript.api = "https://fixture.invalid/sub.php";
        check(
                JsEngine.eligible(contentScript),
                "extensionless type 3 PHP endpoint is eligible as remote script source");
        Cms.Config importedScript =
                Cms.parseConfig(
                        "module.exports={home(){return {list:[]}}}",
                        "https://fixture.invalid/sub.php");
        check(
                JsEngine.eligible(importedScript.sites.get(0)),
                "PHP script import reaches JavaScript host selection");
        check(JsEngine.isEsModule("import'./side.js';"), "compact side-effect import is ESM");
        check(JsEngine.isEsModule("import{home}from'./api.js';"), "compact named import is ESM");
        check(JsEngine.isEsModule("export{home}from'./api.js';"), "compact re-export is ESM");
        check(
                !JsEngine.isEsModule("import('./optional.js');"),
                "dynamic import is not a static declaration");
        check(
                JsEngine.commonJsCandidates("https://fixture.invalid/helper?token=x#part")[1]
                        .equals("https://fixture.invalid/helper.js?token=x#part"),
                "CommonJS suffix is added before query and fragment");
        check(
                JsEngine.commonJsCandidates("https://fixture.invalid/helper.js?token=x").length
                        == 1,
                "explicit CommonJS suffix does not create unrelated fallback requests");
        JSONObject direct =
                new JSONObject(
                        "{\"parse\":1,\"jx\":0,\"url\":\"https://media.example/clip.MP4?token=fixture#part\",\"header\":{\"Referer\":\"https://site.example/\"},\"flag\":\"line\"}");
        check(
                normalize(direct).getInt("parse") == 0,
                "direct media suffix with query and fragment");
        check(
                normalize(direct)
                        .getJSONObject("header")
                        .getString("Referer")
                        .equals("https://site.example/"),
                "per-source header retained");
        direct.put("jx", 1);
        check(normalize(direct).getInt("parse") == 1, "external parser request preserved");
        direct.put("jx", 0).put("playUrl", "https://parser.example/?url=");
        check(normalize(direct).getInt("parse") == 1, "configured parser prefix preserved");
        direct.put("playUrl", "").put("url", "https://site.example/watch?video=clip.mp4");
        check(normalize(direct).getInt("parse") == 1, "media suffix in query is not direct media");
        direct.put("url", "file:///clip.mp4");
        check(normalize(direct).getInt("parse") == 1, "non-HTTP URI preserved");
        direct.put("url", "https://media.example/clip.mp4").remove("jx");
        check(normalize(direct).getInt("parse") == 1, "missing parser intent preserved");
        System.out.println(checks + " JS player checks passed; no live media playback implied.");
    }
}

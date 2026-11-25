// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.DialogInterface;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.Collections;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

public final class LiteProbe extends Instrumentation {
    int count;
    int baselineCount;
    int newChecksCount;
    LiteActivity a;
    boolean candidate;
    boolean extended = true;
    String mode = "full";
    final StringBuilder report = new StringBuilder();

    void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        count++;
        report.append("  [PASS #").append(count).append("] ").append(name).append('\n');
    }

    void main(Runnable job) {
        runOnMainSync(job);
    }

    void pressKey(final int keyCode) {
        sendKeyDownUpSync(keyCode);
        SystemClock.sleep(220);
    }

    String request(int port, String path, String data) throws Exception {
        return requestUrl("http://127.0.0.1:" + port + path, data);
    }

    String requestUrl(String fullUrl, String data) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(fullUrl).openConnection();
        c.setConnectTimeout(4000);
        c.setReadTimeout(20000);
        if (data != null) {
            c.setDoOutput(true);
            c.setRequestMethod("POST");
            c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            byte[] bytes = data.getBytes("UTF-8");
            c.setFixedLengthStreamingMode(bytes.length);
            c.getOutputStream().write(bytes);
        }
        int code = c.getResponseCode();
        InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (in != null) {
            byte[] b = new byte[1024];
            int n;
            while ((n = in.read(b)) != -1) out.write(b, 0, n);
            in.close();
        }
        c.disconnect();
        return code + ":" + new String(out.toByteArray(), "UTF-8");
    }

    void clearServerLogs() throws Exception {
        requestUrl("http://10.0.2.2:8773/_logs/clear", null);
    }

    JSONArray fetchServerLogs() throws Exception {
        String raw = requestUrl("http://10.0.2.2:8773/_logs", null);
        int colon = raw.indexOf(':');
        return new JSONArray(colon >= 0 ? raw.substring(colon + 1) : "[]");
    }

    void importConfigViaPairing(String configUrl) throws Exception {
        main(
                new Runnable() {
                    public void run() {
                        a.configure();
                    }
                });
        long dl = SystemClock.uptimeMillis() + 5000;
        while (a.pairing == null && SystemClock.uptimeMillis() < dl) SystemClock.sleep(100);
        if (a.pairing == null) throw new AssertionError("pairing server unavailable");
        String resp =
                request(
                        a.pairing.port(),
                        "/" + a.pairing.token,
                        "url=" + URLEncoder.encode(configUrl, "UTF-8"));
        if (!resp.startsWith("200:")) {
            throw new AssertionError("pairing import failed for " + configUrl + ": " + resp);
        }
        main(
                new Runnable() {
                    public void run() {
                        a.home();
                    }
                });
        SystemClock.sleep(250);
    }

    boolean waitReady(long timeoutMs) {
        long dl = SystemClock.uptimeMillis() + timeoutMs;
        while (!a.ready && SystemClock.uptimeMillis() < dl) {
            SystemClock.sleep(200);
        }
        return a.ready;
    }

    boolean waitFailed(long timeoutMs) {
        long dl = SystemClock.uptimeMillis() + timeoutMs;
        while (!a.playbackFailed && SystemClock.uptimeMillis() < dl) {
            SystemClock.sleep(200);
        }
        return a.playbackFailed;
    }

    boolean waitClockAdvances() {
        final int[] pos = new int[2];
        main(
                new Runnable() {
                    public void run() {
                        pos[0] = a.player != null ? a.player.getCurrentPosition() : -1;
                    }
                });
        if (pos[0] < 0) return false;
        long dl = SystemClock.uptimeMillis() + 5000;
        while (SystemClock.uptimeMillis() < dl) {
            SystemClock.sleep(500);
            main(
                    new Runnable() {
                        public void run() {
                            pos[1] = a.player != null ? a.player.getCurrentPosition() : -1;
                        }
                    });
            if (pos[1] > pos[0]) return true;
        }
        return false;
    }

    boolean waitDetailId(String expectedVodId, long timeoutMs) {
        long dl = SystemClock.uptimeMillis() + timeoutMs;
        while (SystemClock.uptimeMillis() < dl) {
            if (a.currentDetail != null
                    && expectedVodId.equals(a.currentDetail.optString("vod_id"))) {
                return true;
            }
            SystemClock.sleep(150);
        }
        return false;
    }

    boolean waitStatusContains(String needle, long timeoutMs) {
        long dl = SystemClock.uptimeMillis() + timeoutMs;
        while (SystemClock.uptimeMillis() < dl) {
            final String[] txt = new String[] {""};
            main(
                    new Runnable() {
                        public void run() {
                            txt[0] = a.status != null ? a.status.getText().toString() : "";
                        }
                    });
            if (txt[0].contains(needle)) return true;
            SystemClock.sleep(150);
        }
        return false;
    }

    boolean waitCardsAtLeast(int minCount, long timeoutMs) {
        long dl = SystemClock.uptimeMillis() + timeoutMs;
        while (SystemClock.uptimeMillis() < dl) {
            if (a.lastRenderedCards != null && a.lastRenderedCards.size() >= minCount) return true;
            SystemClock.sleep(150);
        }
        return false;
    }

    LiteCatalog.Site findSiteByKey(String key) {
        for (int i = 0; i < a.sites.size(); i++) {
            if (key.equals(a.sites.get(i).key)) return a.sites.get(i);
        }
        return null;
    }

    @Override
    public void onCreate(Bundle b) {
        super.onCreate(b);
        if (b != null) {
            candidate = "true".equals(b.getString("candidate"));
            if (b.containsKey("extended")) {
                extended = !"false".equals(b.getString("extended"));
            }
            String m = b.getString("mode");
            if (m != null && m.trim().length() > 0) mode = m.trim();
        }
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        try {
            check(Build.VERSION.SDK_INT == 14, "real API14 runtime");
            a =
                    (LiteActivity)
                            startActivitySync(
                                    new Intent(getTargetContext(), LiteActivity.class)
                                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            check(a != null, "launch");

            if ("verify059".equals(mode)) {
                runVerify059Upgrade();
                result.putString(
                        "stream",
                        report.toString() + "PASS " + count + " upgrade checks (verify059)\n");
                finish(Activity.RESULT_OK, result);
                return;
            }

            runBaseline28Checks();
            baselineCount = count;

            if (extended) {
                runExtended059Checks();
                runRound2ReworkChecks();
                runRound3ReworkChecks();
                runRound4ReworkChecks();
                run0510NoticeAndSettingsChecks();
                newChecksCount = count - baselineCount;
            }

            String summary =
                    "PASS "
                            + baselineCount
                            + " API14 checks"
                            + (extended
                                    ? (" + "
                                            + newChecksCount
                                            + " new Lite E2E checks (total "
                                            + count
                                            + " PASSED, 0 FAILED, 0 SKIPPED)")
                                    : "")
                            + "\n";
            result.putString("stream", report.toString() + summary);
            finish(Activity.RESULT_OK, result);
        } catch (Throwable failure) {
            result.putString(
                    "stream",
                    report.toString() + "FAIL after " + count + ": " + failure.toString() + "\n");
            finish(Activity.RESULT_CANCELED, result);
        } finally {
            if (a != null) {
                main(
                        new Runnable() {
                            public void run() {
                                a.finish();
                            }
                        });
            }
        }
    }

    private void runVerify059Upgrade() throws Exception {
        main(
                new Runnable() {
                    public void run() {
                        a.home();
                    }
                });
        check(
                "http://10.0.2.2:8773/config"
                        .equals(a.getPreferences(0).getString("address", "")),
                "upgrade: 0.5.9 preserves 0.5.8 subscription address without clearing data");
        check(
                a.sites.size() == 2 && a.sites.get(0).supported,
                "upgrade: 0.5.9 preserves and loads 0.5.8 sites");
        List<LiteStore.HistoryEntry> hist = LiteStore.getHistory(a);
        List<LiteStore.FavoriteEntry> favs = LiteStore.getFavorites(a);
        check(hist.size() == 2, "upgrade: 0.5.9 preserves both 0.5.8 history records");
        check(favs.size() == 2, "upgrade: 0.5.9 preserves both 0.5.8 favorite records");
        final LiteStore.HistoryEntry withApi = hist.get(0);
        final LiteStore.HistoryEntry legacyEmptyApi = hist.get(1);
        check(
                "demo".equals(withApi.vodId) && withApi.positionMs == 14500,
                "upgrade: 0.5.9 preserves exact 0.5.8 resume progress 14500ms");
        check(
                "demo_legacy".equals(legacyEmptyApi.vodId) && legacyEmptyApi.siteApi.length() == 0,
                "upgrade: 0.5.9 preserves legacy empty-siteApi history record");
        main(
                new Runnable() {
                    public void run() {
                        a.openHistoryOrFavorite(
                                withApi.siteKey,
                                withApi.siteApi,
                                withApi.siteName,
                                withApi.vodId,
                                withApi.vodName);
                    }
                });
        check(
                waitDetailId("demo", 10000),
                "upgrade: 0.5.9 reopens 0.5.8 history entry into detail cleanly");
        check(
                LiteStore.isFavorite(a, withApi.siteKey, withApi.siteApi, withApi.vodId, true),
                "upgrade: 0.5.9 recognizes 0.5.8 favorite after upgrade");
        LiteCatalog.RecordSiteResolution legacyRes =
                LiteCatalog.resolveSiteForRecord(
                        a.sites,
                        legacyEmptyApi.siteKey,
                        legacyEmptyApi.siteApi,
                        legacyEmptyApi.siteName);
        check(
                legacyRes.matchedSite != null
                        && legacyRes.matchedSite.api.equals(a.sites.get(0).api),
                "upgrade: 0.5.9 uniquely resolves legacy 0.5.8 empty-siteApi record");
        check(
                LiteStore.isFavorite(
                        a, legacyEmptyApi.siteKey, a.sites.get(0).api, legacyEmptyApi.vodId, true),
                "upgrade: 0.5.9 recognizes legacy 0.5.8 empty-siteApi favorite");

        // R1 post-upgrade verification: 0.5.8 unscoped tombstone (20) vs older API-identified cloud (10),
        // canonicalizing no-API record + API update, single unfavorite, 2 consecutive syncs, and restart!
        final String siteKey = a.sites.get(0).key;
        final String siteApi = a.sites.get(0).api;
        JSONObject deletedOlderCloud =
                new JSONObject()
                        .put("site", siteKey)
                        .put("siteApi", siteApi)
                        .put("id", "058_deleted")
                        .put("title", "0.5.8已删影片")
                        .put("episode", "第1集")
                        .put("position", 5000)
                        .put("updated", 10L);
        JSONObject updatedLegacyCloud =
                new JSONObject()
                        .put("site", siteKey)
                        .put("siteApi", siteApi)
                        .put("id", "demo_legacy")
                        .put("title", "旧版无API影片")
                        .put("episode", "第2集")
                        .put("position", 12000)
                        .put("updated", 1700000003000L);
        String cloudPayload =
                new JSONObject()
                        .put("schema", "marco-movie-sync")
                        .put("version", 2)
                        .put(
                                "watch_history",
                                new JSONArray().put(deletedOlderCloud).put(updatedLegacyCloud))
                        .put(
                                "favorites",
                                new JSONArray().put(deletedOlderCloud).put(updatedLegacyCloud))
                        .put("tombstones", new JSONObject())
                        .toString();
        LiteSync.MergeResult upM1 = a.mergeAndApplyOnAnyThread(cloudPayload);
        LiteSync.MergeResult upM2 = a.mergeAndApplyOnAnyThread(cloudPayload);
        check(
                upM1.historyCount == 2
                        && upM1.favoriteCount == 2
                        && upM2.historyCount == 2
                        && upM2.favoriteCount == 2
                        && LiteStore.findHistory(a, siteKey, siteApi, "058_deleted", true) == null
                        && !LiteStore.isFavorite(a, siteKey, siteApi, "058_deleted", true),
                "upgrade R1: 0.5.8 tombstone(20) blocks older API cloud(10) and no-API+API canonicalize without duplicates across 2 syncs");

        LiteStore.FavoriteEntry legacyFavEntry = new LiteStore.FavoriteEntry();
        legacyFavEntry.siteKey = siteKey;
        legacyFavEntry.siteApi = siteApi;
        legacyFavEntry.vodId = "demo_legacy";
        legacyFavEntry.vodName = "旧版无API影片";
        boolean stillFavAfterSingleToggle = LiteStore.toggleFavorite(a, legacyFavEntry, true);
        a.recordFavoriteToggleTombstone(siteKey, siteApi, "demo_legacy", false, true);
        check(
                !stillFavAfterSingleToggle
                        && !LiteStore.isFavorite(a, siteKey, siteApi, "demo_legacy", true)
                        && LiteStore.getFavorites(a).size() == 1,
                "upgrade R1: single unfavorite clears canonicalized legacy favorite");

        String oldNoApiCloudCopy =
                new JSONObject()
                        .put("schema", "marco-movie-sync")
                        .put("version", 2)
                        .put("watch_history", new JSONArray())
                        .put(
                                "favorites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("site", siteKey)
                                                        .put("id", "demo_legacy")
                                                        .put("title", "旧版无API影片")
                                                        .put("updated", 1700000001000L)))
                        .put("tombstones", new JSONObject())
                        .toString();
        LiteSync.MergeResult upUnfav1 = a.mergeAndApplyOnAnyThread(oldNoApiCloudCopy);
        LiteSync.MergeResult upUnfav2 = a.mergeAndApplyOnAnyThread(oldNoApiCloudCopy);
        check(
                upUnfav1.favoriteCount == 1
                        && upUnfav2.favoriteCount == 1
                        && !LiteStore.isFavorite(a, siteKey, siteApi, "demo_legacy", true)
                        && LiteStore.isFavorite(a, siteKey, siteApi, "demo", true),
                "upgrade R1: two consecutive merges after unfavorite do not resurrect old no-API copy");

        // Restart LiteActivity to confirm persistence across cold restart
        main(
                new Runnable() {
                    public void run() {
                        a.finish();
                    }
                });
        SystemClock.sleep(500);
        a =
                (LiteActivity)
                        startActivitySync(
                                new Intent(getTargetContext(), LiteActivity.class)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        check(
                a != null
                        && LiteStore.getFavorites(a).size() == 1
                        && LiteStore.isFavorite(a, siteKey, siteApi, "demo", true)
                        && !LiteStore.isFavorite(a, siteKey, siteApi, "demo_legacy", true)
                        && LiteStore.findHistory(a, siteKey, siteApi, "058_deleted", true) == null,
                "upgrade R1: post-sync unfavorite and no-resurrection state persist across activity restart");
    }

    private void runBaseline28Checks() throws Exception {
        LiteStore.clearHistory(a);
        LiteStore.clearFavorites(a);
        a.getPreferences(0)
                .edit()
                .remove("resume_address")
                .remove("resume_site_api")
                .remove("resume_ms")
                .putBoolean("experimental_decoder", candidate)
                .commit();
        check(
                LiteCatalog.query("http://example.invalid/api", "wd", "中文 a").contains("%E4%B8%AD"),
                "query encoding");
        try {
            LiteCatalog.http("file:///private");
            throw new AssertionError("scheme");
        } catch (IOException ok) {
            check(true, "file scheme blocked");
        }
        main(
                new Runnable() {
                    public void run() {
                        a.configure();
                    }
                });
        check(a.pairing != null, "pair server and QR generated");
        int port = a.pairing.port();
        String path = "/" + a.pairing.token;
        check(request(port, path, null).startsWith("200:"), "phone page");
        check(request(port, "/wrong", null).startsWith("403:"), "invalid pairing rejected");
        String fixture = "http://10.0.2.2:8773/config";
        check(
                request(port, path, "url=" + URLEncoder.encode(fixture, "UTF-8")).startsWith("200:"),
                "phone submit succeeds");
        check(
                a.getPreferences(0).getString("address", "").equals(fixture),
                "configuration persisted");
        String saved = a.getPreferences(0).getString("config", "");
        check(
                request(
                                port,
                                path,
                                "url="
                                        + URLEncoder.encode(
                                                "http://10.0.2.2:8773/invalid", "UTF-8"))
                        .startsWith("422:"),
                "invalid config rejected");
        check(
                saved.equals(a.getPreferences(0).getString("config", "")),
                "failed import preserves config");
        main(
                new Runnable() {
                    public void run() {
                        a.home();
                    }
                });
        check(a.pairing == null, "pairing closes when leaving");
        check(a.sites.size() == 2, "sites retained");
        check(
                a.sites.get(0).supported && !a.sites.get(1).supported,
                "unsupported plugin explicit");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = a.sites.get(0);
                        a.catalog("", 1);
                    }
                });
        check(waitStatusContains("1", 8000), "CMS list loaded");
        main(
                new Runnable() {
                    public void run() {
                        a.detail("demo");
                    }
                });
        check(waitDetailId("demo", 8000), "detail and episode loaded");
        main(
                new Runnable() {
                    public void run() {
                        a.play("http://10.0.2.2:8773/video.mp4", "合成播放测试");
                    }
                });
        check(waitReady(30000), "system player prepared");
        check(waitClockAdvances(), "playback clock advances");
        main(
                new Runnable() {
                    public void run() {
                        a.dispatchKeyEvent(
                                new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER));
                    }
                });
        check(!a.player.isPlaying(), "remote pause");
        main(
                new Runnable() {
                    public void run() {
                        a.dispatchKeyEvent(
                                new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER));
                    }
                });
        check(a.player.isPlaying(), "remote resume");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check(a.player == null && a.currentDetail != null, "back releases playback to episodes");
        main(
                new Runnable() {
                    public void run() {
                        a.play("http://10.0.2.2:8773/stream.m3u8", "HLS 合成测试");
                    }
                });
        check(waitReady(30000), "HLS prepared");
        check(a.player.name().contains(candidate ? "IJK" : "系统"), "selected backend active");
        check(waitClockAdvances(), "HLS clock advances");
        main(
                new Runnable() {
                    public void run() {
                        a.player.seekTo(18000);
                    }
                });
        SystemClock.sleep(3000);
        final int[] hlsPos = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        hlsPos[0] = a.player.getCurrentPosition();
                    }
                });
        check(hlsPos[0] >= 15000, "HLS seek progresses");
        main(
                new Runnable() {
                    public void run() {
                        callActivityOnStop(a);
                    }
                });
        check(a.player == null, "background releases decoder");
        main(
                new Runnable() {
                    public void run() {
                        callActivityOnStart(a);
                    }
                });
        check(!a.homeVisible && a.currentDetail != null, "foreground returns to usable detail");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check(a.player == null, "HLS released");
        if (candidate) {
            check(
                    NetworkTls.context(null).getProvider().getName().contains("Conscrypt"),
                    "candidate TLS provider loads on API14");
            try {
                LiteCatalog.fetch("https://10.0.2.2:8774/config", null);
                throw new AssertionError("untrusted certificate accepted");
            } catch (javax.net.ssl.SSLException expected) {
                check(true, "untrusted cert rejected");
            }
            java.security.cert.CertificateFactory cf =
                    java.security.cert.CertificateFactory.getInstance("X.509");
            InputStream cert = getContext().getAssets().open("test-ca.pem");
            java.security.cert.Certificate ca = cf.generateCertificate(cert);
            cert.close();
            java.security.KeyStore store =
                    java.security.KeyStore.getInstance(java.security.KeyStore.getDefaultType());
            store.load(null, null);
            store.setCertificateEntry("test", ca);
            javax.net.ssl.TrustManagerFactory trust =
                    javax.net.ssl.TrustManagerFactory.getInstance(
                            javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm());
            trust.init(store);
            javax.net.ssl.SSLContext tls = NetworkTls.context(trust.getTrustManagers());
            javax.net.ssl.HttpsURLConnection c =
                    (javax.net.ssl.HttpsURLConnection)
                            new URL("https://10.0.2.2:8774/config").openConnection();
            c.setSSLSocketFactory(tls.getSocketFactory());
            c.setConnectTimeout(5000);
            c.setReadTimeout(5000);
            check(c.getResponseCode() == 200, "TLS1.2 request with trusted test CA");
            c.disconnect();
            javax.net.ssl.SSLSocket socket =
                    (javax.net.ssl.SSLSocket)
                            tls.getSocketFactory().createSocket("10.0.2.2", 8774);
            socket.setSoTimeout(5000);
            socket.startHandshake();
            check(socket.getSession().getProtocol().equals("TLSv1.2"), "TLS1.2 negotiated");
            check(
                    !javax.net.ssl.HttpsURLConnection.getDefaultHostnameVerifier()
                            .verify("wrong.example", socket.getSession()),
                    "hostname mismatch rejected");
            socket.close();
        }
    }

    private void runExtended059Checks() throws Exception {
        // Clear clean slate for 0.5.9 E2E checks
        LiteStore.clearHistory(a);
        LiteStore.clearFavorites(a);
        a.getPreferences(0)
                .edit()
                .remove("resume_address")
                .remove("resume_site_api")
                .remove("resume_ms")
                .remove("preferred_line")
                .commit();

        // === ITEM 1: Live-after-VOD resume + finite live no auto-next + VOD auto-next + Cast + Emby ===
        importConfigViaPairing("http://10.0.2.2:8773/config-v059");
        final LiteCatalog.Site siteA = findSiteByKey("site_a");
        check(siteA != null && siteA.supported, "Item 1: imported comprehensive 0.5.9 config");

        main(
                new Runnable() {
                    public void run() {
                        a.selected = siteA;
                        a.detail("vod_drama");
                    }
                });
        check(waitDetailId("vod_drama", 10000), "Item 1: loaded multi-episode VOD drama");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep2 = a.currentLineEpisodes.get(1);
                        a.playingEpisodeIndex = ep2.originalIndex;
                        a.play(ep2.url, ep2.name);
                    }
                });
        check(waitReady(30000), "Item 1: VOD ep2 prepared");
        main(
                new Runnable() {
                    public void run() {
                        a.player.seekTo(12000);
                    }
                });
        SystemClock.sleep(2200);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        List<LiteStore.HistoryEntry> histAfterEp2 = LiteStore.getHistory(a);
        check(
                !histAfterEp2.isEmpty()
                        && "vod_drama".equals(histAfterEp2.get(0).vodId)
                        && "第2集".equals(histAfterEp2.get(0).epName)
                        && histAfterEp2.get(0).positionMs >= 10000,
                "Item 1: VOD ep2 progress saved accurately ("
                        + (histAfterEp2.isEmpty() ? 0 : histAfterEp2.get(0).positionMs)
                        + "ms)");
        final int savedEp2Pos = histAfterEp2.get(0).positionMs;

        // Enter Live and play finite 3s live stream -> must NOT trigger VOD ep3!
        List<LiteCatalog.LiveSource> liveSources =
                LiteCatalog.parseLives(
                        a.getPreferences(0).getString("config", ""),
                        a.getPreferences(0).getString("address", ""));
        final List<LiteCatalog.LiveGroup> inlineLiveGroups =
                LiteCatalog.fetchLiveGroups(liveSources.get(0));
        final LiteCatalog.LiveGroup testLiveGrp = inlineLiveGroups.get(0);
        int shortLiveIdx = -1;
        int fastBadIdx = -1;
        int hangBadIdx = -1;
        int allBadIdx = -1;
        for (int i = 0; i < testLiveGrp.channels.size(); i++) {
            String cn = testLiveGrp.channels.get(i).name;
            if ("短直播结束台".equals(cn)) shortLiveIdx = i;
            else if ("坏线快错台".equals(cn)) fastBadIdx = i;
            else if ("坏线无响应台".equals(cn)) hangBadIdx = i;
            else if ("全坏线路台".equals(cn)) allBadIdx = i;
        }
        check(
                shortLiveIdx >= 0 && fastBadIdx >= 0 && hangBadIdx >= 0 && allBadIdx >= 0,
                "Item 1/2: inline live test channels parsed");

        final int sLiveIdx = shortLiveIdx;
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                testLiveGrp, sLiveIdx, 0, Collections.<String, String>emptyMap());
                    }
                });
        check(waitReady(25000), "Item 1: finite short live stream prepared");
        check(
                waitStatusContains("直播流已结束", 15000),
                "Item 1: finite live stream ends cleanly without triggering VOD next episode");
        check(
                a.activeSession != null
                        && a.activeSession.kind == LiteActivity.PlaybackSession.KIND_LIVE,
                "Item 1: active session remains LIVE after finite stream ends");

        // Switch channel in live, then return to Home and verify Continue Watching returns to VOD ep2!
        final int fbIdx = fastBadIdx;
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                testLiveGrp, fbIdx, 1, Collections.<String, String>emptyMap());
                    }
                });
        check(waitReady(25000), "Item 1: switched live channel prepared");
        SystemClock.sleep(1500);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        main(
                new Runnable() {
                    public void run() {
                        a.home();
                    }
                });
        List<LiteStore.HistoryEntry> histAfterLive = LiteStore.getHistory(a);
        check(
                !histAfterLive.isEmpty()
                        && "vod_drama".equals(histAfterLive.get(0).vodId)
                        && "第2集".equals(histAfterLive.get(0).epName)
                        && histAfterLive.get(0).positionMs == savedEp2Pos,
                "Item 1: Live playback + channel switch + exit NEVER overwrote VOD ep2 history");

        // Click Home Continue Watching card 0 -> detail -> resume VOD ep2 at original progress
        check(a.lastRenderedCards.size() >= 1, "Item 1: Home Continue Watching card rendered");
        main(
                new Runnable() {
                    public void run() {
                        a.currentDetail = null;
                        a.lastRenderedCards.get(0).performClick();
                    }
                });
        check(waitDetailId("vod_drama", 10000), "Item 1: Home Continue Watching opens original drama");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep2 = a.currentLineEpisodes.get(1);
                        a.playingEpisodeIndex = ep2.originalIndex;
                        a.play(ep2.url, ep2.name);
                    }
                });
        check(waitReady(30000), "Item 1: Resumed VOD ep2 prepared");
        SystemClock.sleep(1000);
        final int[] resumedPos = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        resumedPos[0] = a.player.getCurrentPosition();
                    }
                });
        check(
                resumedPos[0] >= 8000,
                "Item 1: Resumed VOD ep2 jumped back to original progress ("
                        + resumedPos[0]
                        + "ms)");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // Normal VOD auto-advance regression
        main(
                new Runnable() {
                    public void run() {
                        a.selected = siteA;
                        a.detail("vod_short_auto");
                    }
                });
        check(waitDetailId("vod_short_auto", 10000), "Item 1: loaded auto-next regression drama");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep1 = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep1.originalIndex;
                        a.play(ep1.url, ep1.name);
                    }
                });
        check(waitReady(25000), "Item 1: short VOD ep1 prepared");
        long autoNextDl = SystemClock.uptimeMillis() + 25000;
        boolean autoAdvanced = false;
        while (SystemClock.uptimeMillis() < autoNextDl) {
            if (a.ready
                    && a.activeSession != null
                    && a.activeSession.kind == LiteActivity.PlaybackSession.KIND_VOD
                    && "第2集".equals(a.activeSession.epName)) {
                autoAdvanced = true;
                break;
            }
            SystemClock.sleep(250);
        }
        check(autoAdvanced, "Item 1: normal VOD ep1 auto-advances to ep2 on completion");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // Cast exit regression
        main(
                new Runnable() {
                    public void run() {
                        a.playCastStream(
                                "http://10.0.2.2:8773/video.mp4",
                                "投屏回归测试",
                                Collections.<String, String>emptyMap());
                    }
                });
        check(waitReady(25000), "Item 1: cast playback prepared");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check(
                !a.inPlayback && !a.inCastPlayback && a.player == null,
                "Item 1: cast exit releases playback cleanly");

        // Emby stop reporting regression
        clearServerLogs();
        JSONObject embySessCfg =
                new JSONObject()
                        .put("base", "http://10.0.2.2:8773/emby")
                        .put("user", "user1")
                        .put("token", "mock-token-123")
                        .put("device", "dev1");
        JSONObject embyMeta =
                new JSONObject()
                        .put("ItemId", "emby_item_1")
                        .put("MediaSourceId", "ms_1")
                        .put("PlaySessionId", "ps_1");
        final com.pilipala.emby.EmbyLibrary.Reporter mockReporter =
                new com.pilipala.emby.EmbyLibrary(embySessCfg).track(embyMeta);
        main(
                new Runnable() {
                    public void run() {
                        LiteCatalog.Site embySite = new LiteCatalog.Site();
                        embySite.key = "emby_mock";
                        embySite.name = "MockEmby";
                        embySite.api = "emby://account/mock-emby-1";
                        embySite.supported = true;
                        JSONObject embyVod = new JSONObject();
                        try {
                            embyVod.put("vod_id", "emby_item_1");
                            embyVod.put("vod_name", "Emby测试片");
                        } catch (Exception ignored) {
                        }
                        LiteActivity.PlaybackSession embySess =
                                LiteActivity.PlaybackSession.forVod(
                                        ++a.playbackSessionSeq,
                                        "http://10.0.2.2:8773/video.mp4",
                                        "emby://item/emby_item_1",
                                        "正片",
                                        Collections.<String, String>emptyMap(),
                                        embySite,
                                        embyVod,
                                        "Emby",
                                        0,
                                        0,
                                        Collections.<LiteActivity.EpisodeItem>emptyList());
                        a.playResolved(embySess, mockReporter);
                    }
                });
        check(waitReady(25000), "Item 1: Emby playback prepared");
        SystemClock.sleep(1000);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        SystemClock.sleep(1000);
        JSONArray embyLogs = fetchServerLogs();
        boolean sawEmbyStop = false;
        for (int i = 0; i < embyLogs.length(); i++) {
            String p = embyLogs.getJSONObject(i).optString("path");
            if (p.contains("/emby/Sessions/Playing/Stopped")) sawEmbyStop = true;
        }
        check(sawEmbyStop, "Item 1: Emby playback exit reports /Sessions/Playing/Stopped");

        // === ITEM 2: Bad-line D-pad recovery (fast fail, hanging unresponsive, all-failed Back) ===
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                testLiveGrp, fbIdx, 0, Collections.<String, String>emptyMap());
                    }
                });
        check(waitFailed(15000), "Item 2: fast-error line 1 fails and enables toolbar recovery");
        check(
                a.switchLineBtnView != null && a.switchLineBtnView.hasFocus(),
                "Item 2: D-pad focus automatically lands on switch-line button after fast error");
        pressKey(KeyEvent.KEYCODE_DPAD_CENTER);
        check(
                waitReady(25000)
                        && a.activeSession != null
                        && a.activeSession.liveUrlIndex == 1,
                "Item 2: D-pad OK switches fast-error channel to working line 2");
        check(waitClockAdvances(), "Item 2: line 2 playback clock advances after fast-error recovery");

        final int hbIdx = hangBadIdx;
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                testLiveGrp, hbIdx, 0, Collections.<String, String>emptyMap());
                    }
                });
        SystemClock.sleep(1500);
        check(!a.ready && a.inPlayback, "Item 2: hanging line 1 is still preparing");
        pressKey(KeyEvent.KEYCODE_DPAD_DOWN);
        check(
                a.switchLineBtnView != null && a.switchLineBtnView.hasFocus(),
                "Item 2: D-pad DOWN during unresponsive prepare opens toolbar and focuses switch-line");
        pressKey(KeyEvent.KEYCODE_DPAD_CENTER);
        check(
                waitReady(30000)
                        && a.activeSession != null
                        && a.activeSession.liveUrlIndex == 1,
                "Item 2: D-pad OK switches hanging channel to working line 2");
        check(waitClockAdvances(), "Item 2: line 2 HLS clock advances after hanging-line recovery");
        SystemClock.sleep(1500);
        check(
                a.ready && a.player != null && a.player.isPlaying(),
                "Item 2: delayed error from abandoned hanging line does not disrupt line 2");

        final int abIdx = allBadIdx;
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                testLiveGrp, abIdx, 0, Collections.<String, String>emptyMap());
                    }
                });
        check(waitFailed(15000), "Item 2: all-bad channel line 1 fails");
        pressKey(KeyEvent.KEYCODE_DPAD_CENTER);
        check(
                waitFailed(15000)
                        && a.activeSession != null
                        && a.activeSession.liveUrlIndex == 1,
                "Item 2: all-bad channel line 2 also fails");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check(!a.inPlayback && a.player == null, "Item 2: user can return to channel list when all lines fail");

        // === ITEM 3: Subscription switch resets old source, category, and page ===
        main(
                new Runnable() {
                    public void run() {
                        a.selected = siteA;
                        a.catalog("", "cat1", 2);
                    }
                });
        check(waitStatusContains("第 2", 8000), "Item 3: browsed Site A cat1 page 2");
        clearServerLogs();
        importConfigViaPairing("http://10.0.2.2:8773/config-only-b");
        main(
                new Runnable() {
                    public void run() {
                        a.catalog("", "", 1);
                    }
                });
        check(waitStatusContains("第 1", 8000), "Item 3: Current source loaded after switch to B-only");
        main(
                new Runnable() {
                    public void run() {
                        a.catalog("测试", "", 1);
                    }
                });
        check(waitStatusContains("搜索", 8000), "Item 3: Search current source loaded after switch to B-only");
        JSONArray switchLogs = fetchServerLogs();
        int bHits = 0;
        int aHits = 0;
        int staleCatHits = 0;
        for (int i = 0; i < switchLogs.length(); i++) {
            JSONObject log = switchLogs.getJSONObject(i);
            String p = log.optString("path");
            String q = log.optString("query");
            if (p.equals("/cms-only-b")) bHits++;
            if (p.equals("/cms-a")) aHits++;
            if (q.contains("t=cat1")) staleCatHits++;
        }
        check(
                bHits >= 2 && aHits == 0 && staleCatHits == 0,
                "Item 3: After switching from A(cat1,p2) to B-only, server saw only B ("
                        + bHits
                        + ") and 0 A/cat1 requests");

        importConfigViaPairing("http://10.0.2.2:8773/config-only-unsupported");
        check(
                waitStatusContains("外部插件", 4000),
                "Item 3: Unsupported-only subscription displays understandable prompt");

        // === ITEM 4: Strict MacCMS XML (type=0) ===
        importConfigViaPairing("http://10.0.2.2:8773/config-v059");
        clearServerLogs();
        final LiteCatalog.Site xmlSite = findSiteByKey("site_xml");
        check(xmlSite != null && xmlSite.type == 0 && xmlSite.supported, "Item 4: strict XML site present");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = xmlSite;
                        a.categories.clear();
                        a.catalog("", "", 1);
                    }
                });
        check(waitStatusContains("第 1 / 2", 8000) && a.categories.size() >= 2, "Item 4: strict XML categories & page 1 loaded");
        main(
                new Runnable() {
                    public void run() {
                        a.catalog("", "10", 2);
                    }
                });
        check(waitStatusContains("第 2 / 2", 8000), "Item 4: strict XML category pagination loaded");
        main(
                new Runnable() {
                    public void run() {
                        a.catalog("严格", "", 1);
                    }
                });
        check(waitStatusContains("搜索", 8000), "Item 4: strict XML single-source search loaded");
        main(
                new Runnable() {
                    public void run() {
                        a.detail("xml_1");
                    }
                });
        check(waitDetailId("xml_1", 8000), "Item 4: strict XML detail loaded");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000) && waitClockAdvances(), "Item 4: strict XML episode played and clock advanced");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray xmlLogs = fetchServerLogs();
        boolean sawXmlList = false;
        boolean sawXmlVideoList = false;
        boolean sawXmlDetail = false;
        for (int i = 0; i < xmlLogs.length(); i++) {
            JSONObject log = xmlLogs.getJSONObject(i);
            if ("/xml-strict".equals(log.optString("path"))) {
                String q = log.optString("query");
                if (q.contains("ac=list")) sawXmlList = true;
                if (q.contains("ac=videolist")) sawXmlVideoList = true;
                if (q.contains("ac=detail")) sawXmlDetail = true;
            }
        }
        check(
                sawXmlList && sawXmlVideoList && !sawXmlDetail,
                "Item 4: server log confirms strict XML used ac=list & ac=videolist with 0 ac=detail");

        // === ITEM 5: Structured vod_play_list (case 15) ===
        final LiteCatalog.Site siteA2 = findSiteByKey("site_a");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = siteA2;
                        a.detail("vod_case15");
                    }
                });
        check(waitDetailId("vod_case15", 8000), "Item 5: case 15 structured vod_play_list detail loaded");
        final List<LiteActivity.PlayLine> c15Lines =
                LiteActivity.extractPlayLines(a.currentDetail, "");
        check(
                c15Lines.size() == 2
                        && c15Lines.get(0).episodes.size() == 2
                        && c15Lines.get(1).episodes.size() == 1,
                "Item 5: case 15 yields 2 lines (2 eps and 1 ep)");
        clearServerLogs();
        String[] expectedCase15Paths = {"/case15-a1.mp4", "/case15-a2.mp4", "/case15-b1.mp4"};
        int[][] c15Coords = {{0, 0}, {0, 1}, {1, 0}};
        for (int idx = 0; idx < c15Coords.length; idx++) {
            final int li = c15Coords[idx][0];
            final int ei = c15Coords[idx][1];
            main(
                    new Runnable() {
                        public void run() {
                            a.activeDetailLine = li;
                            a.currentLineEpisodes =
                                    new java.util.ArrayList<LiteActivity.EpisodeItem>(
                                            c15Lines.get(li).episodes);
                            LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(ei);
                            a.playingEpisodeIndex = ep.originalIndex;
                            a.play(ep.url, ep.name);
                        }
                    });
            check(waitReady(25000), "Item 5: case 15 episode " + expectedCase15Paths[idx] + " prepared");
            main(
                    new Runnable() {
                        public void run() {
                            a.onBackPressed();
                        }
                    });
        }
        JSONArray c15Logs = fetchServerLogs();
        int c15Hits = 0;
        for (int pIdx = 0; pIdx < expectedCase15Paths.length; pIdx++) {
            for (int i = 0; i < c15Logs.length(); i++) {
                if (expectedCase15Paths[pIdx].equals(c15Logs.getJSONObject(i).optString("path"))) {
                    c15Hits++;
                    break;
                }
            }
        }
        check(c15Hits == 3, "Item 5: all 3 case 15 episodes hit their exact respective media URLs");

        // === ITEM 6: JSON Play Parse (intact encoded params + Referer + direct bypass + empty error recovery) ===
        final LiteCatalog.Site parseSite = findSiteByKey("site_parse");
        check(parseSite != null && parseSite.supported, "Item 6: JSON parse site present and supported");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = parseSite;
                        a.detail("vod_parse");
                    }
                });
        check(waitDetailId("vod_parse", 8000), "Item 6: JSON parse detail loaded");
        final List<LiteActivity.PlayLine> pLines =
                LiteActivity.extractPlayLines(a.currentDetail, "");
        check(
                pLines.size() == 2 && pLines.get(0).directStream && !pLines.get(1).directStream,
                "Item 6/5: mixed direct+parse video defaults direct line first while keeping parse line");

        // Play parse line (line 1)
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 1;
                        a.currentLineEpisodes =
                                new java.util.ArrayList<LiteActivity.EpisodeItem>(
                                        pLines.get(1).episodes);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(
                waitReady(30000) && waitClockAdvances(),
                "Item 6: JSON parsed stream prepared and clock advanced on API 14");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray parseLogs = fetchServerLogs();
        int parseCountAfterParse = 0;
        boolean parseUrlIntact = false;
        boolean parseMediaRefOk = false;
        String expectedOrig = "https://origin.example/watch?a=1&b=hello%20world&c=x%26y";
        for (int i = 0; i < parseLogs.length(); i++) {
            JSONObject log = parseLogs.getJSONObject(i);
            if ("/parse".equals(log.optString("path"))) {
                parseCountAfterParse++;
                if (expectedOrig.equals(log.optString("decodedUrlParam"))) {
                    parseUrlIntact = true;
                }
            }
            if ("/parse-media.mp4".equals(log.optString("path"))
                    && log.optInt("status") == 200
                    && "https://parse-ref.example/watch".equals(log.optString("referer"))
                    && "ParsePlayer/1.0".equals(log.optString("userAgent"))) {
                parseMediaRefOk = true;
            }
        }
        check(
                parseCountAfterParse == 1 && parseUrlIntact && parseMediaRefOk,
                "Item 6: JSON parser received intact encoded params and media server received exact Referer/UA");

        // Play direct line (line 0) on same parse=1 site -> bypasses /parse!
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 0;
                        a.currentLineEpisodes =
                                new java.util.ArrayList<LiteActivity.EpisodeItem>(
                                        pLines.get(0).episodes);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000), "Item 6: direct line on same parse=1 video prepared directly");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray afterDirectLogs = fetchServerLogs();
        int parseCountAfterDirect = 0;
        for (int i = 0; i < afterDirectLogs.length(); i++) {
            if ("/parse".equals(afterDirectLogs.getJSONObject(i).optString("path"))) {
                parseCountAfterDirect++;
            }
        }
        check(
                parseCountAfterDirect == parseCountAfterParse,
                "Item 6: direct stream bypassed JSON parser cleanly");

        // Empty JSON parse error allows recovery/Back
        final LiteCatalog.Site emptyParseSite = findSiteByKey("site_parse_empty");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = emptyParseSite;
                        a.detail("vod_parse_empty");
                    }
                });
        check(waitDetailId("vod_parse_empty", 8000), "Item 6: empty-parse detail loaded");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitFailed(15000), "Item 6: empty JSON parse triggers failure recovery state");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check(!a.inPlayback && a.currentDetail != null, "Item 6: Back exits failed JSON parse cleanly");

        // === ITEM 7: Pure live subscription + redirect-relative M3U + per-line different Referers ===
        importConfigViaPairing("http://10.0.2.2:8773/config-pure-live");
        check(
                a.sites.isEmpty() && waitStatusContains("纯直播订阅", 4000),
                "Item 7: pure lives-only subscription imports cleanly without sites[]");
        List<LiteCatalog.LiveSource> pureLiveSrcs =
                LiteCatalog.parseLives(
                        a.getPreferences(0).getString("config", ""),
                        a.getPreferences(0).getString("address", ""));
        check(pureLiveSrcs.size() == 2, "Item 7: pure live config exposes both inline and redirected M3U sources");
        List<LiteCatalog.LiveGroup> inlinePureGrps =
                LiteCatalog.fetchLiveGroups(pureLiveSrcs.get(0));
        check(
                inlinePureGrps.size() == 1
                        && "内嵌双线组".equals(inlinePureGrps.get(0).name)
                        && inlinePureGrps.get(0).channels.get(0).urls.size() == 2,
                "Item 7: inline live source builds group/channel/2 lines");
        final List<LiteCatalog.LiveGroup> redirM3uGrps =
                LiteCatalog.fetchLiveGroups(pureLiveSrcs.get(1));
        check(
                redirM3uGrps.size() == 1
                        && "重定向相对组".equals(redirM3uGrps.get(0).name)
                        && redirM3uGrps.get(0).channels.size() == 1
                        && redirM3uGrps.get(0).channels.get(0).urls.size() == 2,
                "Item 7: redirected relative-URL M3U resolves group/channel/2 lines with distinct Referers");

        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                redirM3uGrps.get(0),
                                0,
                                0,
                                Collections.<String, String>emptyMap());
                    }
                });
        check(waitReady(25000), "Item 7: live line 1 (with Referer #1) prepared");
        // Switch live line using ONLY remote keys (MENU -> DPAD_RIGHT to switch-line -> DPAD_CENTER)
        pressKey(KeyEvent.KEYCODE_MENU);
        for (int step = 0; step < 6; step++) {
            if (a.switchLineBtnView != null && a.switchLineBtnView.hasFocus()) break;
            pressKey(KeyEvent.KEYCODE_DPAD_RIGHT);
        }
        check(
                a.switchLineBtnView != null && a.switchLineBtnView.hasFocus(),
                "Item 7: remote keys navigated to live switch-line button");
        pressKey(KeyEvent.KEYCODE_DPAD_CENTER);
        check(
                waitReady(25000)
                        && a.activeSession != null
                        && a.activeSession.liveUrlIndex == 1
                        && waitClockAdvances(),
                "Item 7: remote switched to live line 2 (with Referer #2) and clock advanced");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray liveRefLogs = fetchServerLogs();
        boolean sawRef1Ok = false;
        boolean sawRef2Ok = false;
        boolean sawLive403 = false;
        for (int i = 0; i < liveRefLogs.length(); i++) {
            JSONObject log = liveRefLogs.getJSONObject(i);
            String p = log.optString("path");
            int st = log.optInt("status");
            if (p.startsWith("/hls-ref")) {
                if (st == 403) sawLive403 = true;
                if (p.equals("/hls-ref1/stream.m3u8")
                        && st == 200
                        && "https://ref-line1.example/".equals(log.optString("referer"))) {
                    sawRef1Ok = true;
                }
                if (p.equals("/hls-ref2/stream.m3u8")
                        && st == 200
                        && "https://ref-line2.example/".equals(log.optString("referer"))) {
                    sawRef2Ok = true;
                }
            }
        }
        check(
                sawRef1Ok && sawRef2Ok && !sawLive403,
                "Item 7: media server verified distinct per-line Referers for both HLS lines (0 403s)");

        // === ITEM 8: Detail return to original entry (Catalog, Site A -> Global Search -> Site B, History, Favorites) ===
        importConfigViaPairing("http://10.0.2.2:8773/config-v059");
        final LiteCatalog.Site siteA3 = findSiteByKey("site_a");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = siteA3;
                        a.catalog("", "cat1", 2);
                    }
                });
        check(waitCardsAtLeast(2, 8000), "Item 8: Site A cat1 page 2 cards rendered");
        main(
                new Runnable() {
                    public void run() {
                        a.currentDetail = null;
                        a.lastRenderedCards.get(1).performClick();
                    }
                });
        check(waitDetailId("vod_drama", 8000), "Item 8: opened detail from Site A cat1 page 2");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        SystemClock.sleep(300);
        check(
                "catalog".equals(a.currentPageKind)
                        && "site_a".equals(a.selected.key)
                        && "cat1".equals(a.lastCategory)
                        && a.lastPage == 2,
                "Item 8: Back from catalog detail restores Site A cat1 page 2");

        // Special case: From Site A category -> Global Search -> click Site B result -> Back -> select next movie in same batch!
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("共搜");
                    }
                });
        check(waitCardsAtLeast(2, 10000), "Item 8: Global search returned results from A and B");
        int siteBCardIdx = -1;
        int nextCardIdx = -1;
        // Card order follows site order in config-v059: site_a first, site_b second
        siteBCardIdx = 1;
        nextCardIdx = 0;
        final int clickB = siteBCardIdx;
        main(
                new Runnable() {
                    public void run() {
                        a.lastRenderedCards.get(clickB).performClick();
                    }
                });
        check(
                waitDetailId("vod_b1", 8000) && "site_b".equals(a.selected.key),
                "Item 8: Opened Site B result from Global Search");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        SystemClock.sleep(300);
        check(
                "global_search".equals(a.currentPageKind)
                        && "共搜".equals(a.lastQuery)
                        && a.lastRenderedCards.size() >= 2,
                "Item 8: Back from Site B detail returns to Global Search batch (not Site A catalog)");
        final int clickNext = nextCardIdx;
        main(
                new Runnable() {
                    public void run() {
                        a.lastRenderedCards.get(clickNext).performClick();
                    }
                });
        check(
                waitDetailId("vod_drama", 8000) && "site_a".equals(a.selected.key),
                "Item 8: Can directly open next movie from restored Global Search batch");

        // History & Favorites detail return
        LiteStore.FavoriteEntry navFav = new LiteStore.FavoriteEntry();
        navFav.siteKey = siteA3.key;
        navFav.siteName = siteA3.name;
        navFav.siteApi = siteA3.api;
        navFav.vodId = "vod_drama";
        navFav.vodName = "测试连续剧";
        LiteStore.toggleFavorite(a, navFav, true);

        main(
                new Runnable() {
                    public void run() {
                        a.historyPage();
                    }
                });
        check(waitCardsAtLeast(1, 4000), "Item 8: history page cards rendered");
        main(
                new Runnable() {
                    public void run() {
                        a.lastRenderedCards.get(0).performClick();
                    }
                });
        check(waitDetailId("vod_drama", 8000), "Item 8: opened detail from history");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check("history".equals(a.currentPageKind), "Item 8: Back returns to history list");

        main(
                new Runnable() {
                    public void run() {
                        a.favoritesPage();
                    }
                });
        check(waitCardsAtLeast(1, 4000), "Item 8: favorites page cards rendered");
        main(
                new Runnable() {
                    public void run() {
                        a.lastRenderedCards.get(0).performClick();
                    }
                });
        check(waitDetailId("vod_drama", 8000), "Item 8: opened detail from favorites");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check("favorites".equals(a.currentPageKind), "Item 8: Back returns to favorites list");

        // === ITEM 9: Two sites with same siteKey + vodId, different siteApi & titles + 2-round sync ===
        LiteStore.clearHistory(a);
        LiteStore.clearFavorites(a);
        LiteStore.setTombstonesRaw(a, "");
        importConfigViaPairing("http://10.0.2.2:8773/config-dup-key");
        check(
                a.sites.size() == 2
                        && a.sites.get(0).key.equals(a.sites.get(1).key)
                        && !a.sites.get(0).api.equals(a.sites.get(1).api),
                "Item 9: loaded two sites sharing siteKey with distinct siteApi");
        final LiteCatalog.Site dup1 = a.sites.get(0);
        final LiteCatalog.Site dup2 = a.sites.get(1);

        // Save history + favorite for both sites (same siteKey="dup_cms", same vodId="100", different titles)
        LiteStore.HistoryEntry dh1 = new LiteStore.HistoryEntry();
        dh1.siteKey = dup1.key;
        dh1.siteName = dup1.name;
        dh1.siteApi = dup1.api;
        dh1.vodId = "100";
        dh1.vodName = "甲站电影";
        dh1.epName = "第1集";
        dh1.epUrl = "http://10.0.2.2:8773/video.mp4";
        dh1.positionMs = 11000;
        dh1.updatedAt = 8000L;
        LiteStore.HistoryEntry dh2 = new LiteStore.HistoryEntry();
        dh2.siteKey = dup2.key;
        dh2.siteName = dup2.name;
        dh2.siteApi = dup2.api;
        dh2.vodId = "100";
        dh2.vodName = "乙站剧集";
        dh2.epName = "第1集";
        dh2.epUrl = "http://10.0.2.2:8773/video2.mp4";
        dh2.positionMs = 13000;
        dh2.updatedAt = 9000L;
        LiteStore.saveHistory(a, dh1);
        LiteStore.saveHistory(a, dh2);

        LiteStore.FavoriteEntry df1 = new LiteStore.FavoriteEntry();
        df1.siteKey = dup1.key;
        df1.siteName = dup1.name;
        df1.siteApi = dup1.api;
        df1.vodId = "100";
        df1.vodName = "甲站电影";
        df1.addedAt = 8000L;
        LiteStore.FavoriteEntry df2 = new LiteStore.FavoriteEntry();
        df2.siteKey = dup2.key;
        df2.siteName = dup2.name;
        df2.siteApi = dup2.api;
        df2.vodId = "100";
        df2.vodName = "乙站剧集";
        df2.addedAt = 8100L;
        LiteStore.toggleFavorite(a, df1, false);
        LiteStore.toggleFavorite(a, df2, false);

        check(
                LiteStore.getHistory(a).size() == 2 && LiteStore.getFavorites(a).size() == 2,
                "Item 9: both same-key same-vodId entries persisted independently on device");

        // Reopen each via openHistoryOrFavorite -> verify each hits its own site & title
        main(
                new Runnable() {
                    public void run() {
                        a.openHistoryOrFavorite(dup1.key, dup1.api, dup1.name, "100", "甲站电影");
                    }
                });
        check(
                waitDetailId("100", 8000)
                        && "甲站电影".equals(a.currentDetail.optString("vod_name")),
                "Item 9: reopening Site 1 record loads 甲站电影");
        main(
                new Runnable() {
                    public void run() {
                        a.currentDetail = null;
                        a.openHistoryOrFavorite(dup2.key, dup2.api, dup2.name, "100", "乙站剧集");
                    }
                });
        check(
                waitDetailId("100", 8000)
                        && "乙站剧集".equals(a.currentDetail.optString("vod_name")),
                "Item 9: reopening Site 2 record loads 乙站剧集");

        // Unfavorite Site 1 + run two LiteSync merges against remote with both -> Site 2 stays!
        String remoteBoth =
                LiteSync.exportPayload(
                        LiteStore.getHistoryRaw(a),
                        LiteStore.getFavoritesRaw(a),
                        "",
                        null,
                        false,
                        9500L);
        LiteStore.toggleFavorite(a, df1, false);
        a.recordFavoriteToggleTombstone(dup1.key, dup1.api, "100", false, false);
        LiteSync.MergeResult m1 = a.mergeAndApplyOnAnyThread(remoteBoth);
        LiteSync.MergeResult m2 = a.mergeAndApplyOnAnyThread(remoteBoth);
        List<LiteStore.FavoriteEntry> after2Merges = LiteStore.getFavorites(a);
        check(
                m1.favoriteCount == 1
                        && m2.favoriteCount == 1
                        && after2Merges.size() == 1
                        && dup2.api.equals(after2Merges.get(0).siteApi)
                        && "乙站剧集".equals(after2Merges.get(0).vodName),
                "Item 9: unfavoriting Site 1 + two LiteSync merges keeps Site 2 intact");

        // === ITEM 10: Global Search feedback (partial failure vs true zero-hit + capability hints) ===
        importConfigViaPairing("http://10.0.2.2:8773/config-v059");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("共搜");
                    }
                });
        check(
                waitStatusContains("失败", 10000)
                        && waitStatusContains("故障源", 2000)
                        && waitStatusContains("跳过", 2000),
                "Item 10: partial-failure global search reports succeeded/failed sites and skipped plugins");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("绝对零命中词XYZ");
                    }
                });
        check(
                waitStatusContains("正常无命中", 10000) && waitStatusContains("失败", 2000),
                "Item 10: zero-hit with partial failure distinguishes normal 0-hit vs failed site");

        importConfigViaPairing("http://10.0.2.2:8773/config-only-b");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("绝对零命中词XYZ");
                    }
                });
        check(
                waitStatusContains("确实零命中", 10000),
                "Item 10: all-succeeding empty search explicitly reports true zero-hit");
    }

    private static View findChildWithText(View root, String exactText) {
        if (root instanceof android.widget.TextView
                && exactText.equals(((android.widget.TextView) root).getText().toString())) {
            return root;
        }
        if (root instanceof android.view.ViewGroup) {
            android.view.ViewGroup g = (android.view.ViewGroup) root;
            for (int i = 0; i < g.getChildCount(); i++) {
                View found = findChildWithText(g.getChildAt(i), exactText);
                if (found != null) return found;
            }
        }
        return null;
    }

    private void runRound2ReworkChecks() throws Exception {
        final String base = "http://10.0.2.2:8773";

        // === R2: Distinct from codes sharing display name, overlapping episode union, safe VOD line switch ===
        JSONObject dupShow =
                new JSONObject()
                        .put(
                                "vod_play_list",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put(
                                                                "player_info",
                                                                new JSONObject()
                                                                        .put("show", "高清")
                                                                        .put("from", "A"))
                                                        .put("url", "EP1$" + base + "/video.mp4"))
                                        .put(
                                                new JSONObject()
                                                        .put(
                                                                "player_info",
                                                                new JSONObject()
                                                                        .put("show", "高清")
                                                                        .put("from", "B"))
                                                        .put("url", "EP1$" + base + "/video2.mp4")));
        List<LiteActivity.PlayLine> dupLines = LiteActivity.extractPlayLines(dupShow, "");
        check(
                dupLines.size() == 2
                        && "A".equals(dupLines.get(0).rawFrom)
                        && "B".equals(dupLines.get(1).rawFrom),
                "R2: distinct from codes A/B sharing display name '高清' are both kept on API14");

        JSONObject overlapVod =
                new JSONObject()
                        .put("vod_play_from", "one")
                        .put(
                                "vod_play_url",
                                "1$" + base + "/video.mp4#2$" + base + "/video2.mp4")
                        .put(
                                "vod_play_list",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put(
                                                                "player_info",
                                                                new JSONObject()
                                                                        .put("show", "高清")
                                                                        .put("from", "one"))
                                                        .put(
                                                                "url",
                                                                "2$"
                                                                        + base
                                                                        + "/video2.mp4#3$"
                                                                        + base
                                                                        + "/case15-b1.mp4")));
        List<LiteActivity.PlayLine> ovLines = LiteActivity.extractPlayLines(overlapVod, "");
        check(
                ovLines.size() == 1 && ovLines.get(0).episodes.size() == 3,
                "R2: overlapping traditional [1,2] and structured [2,3] episodes merge into [1,2,3] on API14");

        final JSONObject switchVod =
                new JSONObject()
                        .put("vod_id", "r2_switch")
                        .put("vod_name", "R2换线防跳集")
                        .put("vod_play_from", "A$$$B$$$C")
                        .put(
                                "vod_play_url",
                                "EP1$"
                                        + base
                                        + "/video.mp4#EP2$"
                                        + base
                                        + "/video2.mp4$$$Trailer$"
                                        + base
                                        + "/short-live.mp4#EP1$"
                                        + base
                                        + "/case15-a1.mp4#EP2$"
                                        + base
                                        + "/case15-b1.mp4$$$花絮A$"
                                        + base
                                        + "/video.mp4#特辑B$"
                                        + base
                                        + "/video2.mp4");
        final LiteCatalog.Site dummySwitchSite =
                LiteCatalog.parse(
                                "{\"sites\":[{\"key\":\"r2_sw\",\"name\":\"R2Switch\",\"type\":1,\"api\":\""
                                        + base
                                        + "/cms-a\"}]}",
                                base)
                        .get(0);
        main(
                new Runnable() {
                    public void run() {
                        a.selected = dummySwitchSite;
                        a.activeDetailLine = 0;
                        a.showDetail(switchVod);
                        a.playingEpisodeIndex = 1;
                        a.play(base + "/video2.mp4", "EP2");
                    }
                });
        check(waitReady(25000), "R2: line A/EP2 prepared before line switch");
        final List<LiteActivity.PlayLine> swLines = LiteActivity.extractPlayLines(switchVod, "");
        main(
                new Runnable() {
                    public void run() {
                        a.showInPlayerLineDialog(swLines);
                    }
                });
        SystemClock.sleep(350);
        // Select line B (index 1) via D-pad (ICS exits touch mode on first DPAD_DOWN)
        for (int tries = 0; tries < 5; tries++) {
            final int[] selPos = new int[] {-1};
            main(
                    new Runnable() {
                        public void run() {
                            if (a.activeInPlayerDialog != null
                                    && a.activeInPlayerDialog.getListView() != null) {
                                selPos[0] =
                                        a.activeInPlayerDialog
                                                .getListView()
                                                .getSelectedItemPosition();
                            }
                        }
                    });
            if (selPos[0] == 1) break;
            pressKey(KeyEvent.KEYCODE_DPAD_DOWN);
        }
        pressKey(KeyEvent.KEYCODE_DPAD_CENTER);
        SystemClock.sleep(600);
        check(
                waitReady(25000)
                        && a.activeSession != null
                        && "B".equals(a.activeSession.lineName)
                        && "EP2".equals(a.activeSession.epName)
                        && (base + "/case15-b1.mp4").equals(a.activeSession.streamUrl)
                        && waitClockAdvances(),
                "R2: D-pad VOD line switch A/EP2 -> B([Trailer,EP1,EP2]) plays B/EP2 (not EP1) and advances clock (got "
                        + (a.activeSession != null
                                ? (a.activeSession.lineName
                                        + "/"
                                        + a.activeSession.epName
                                        + " "
                                        + a.activeSession.streamUrl)
                                : "null")
                        + ")");

        // Switch from B/EP2 to unmatchable line C ([花絮A, 特辑B]) -> must open episode picker instead of jumping!
        final String beforeAmbigUrl = a.activeSession.streamUrl;
        main(
                new Runnable() {
                    public void run() {
                        a.switchToPlayLineInPlayer(swLines, 2);
                    }
                });
        SystemClock.sleep(350);
        final boolean[] ambigDialogOpen = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        ambigDialogOpen[0] =
                                a.activeInPlayerDialog != null && a.activeInPlayerDialog.isShowing();
                        a.dismissActiveInPlayerDialog();
                    }
                });
        check(
                ambigDialogOpen[0]
                        && waitStatusContains("未能自动匹配当前剧集", 2000)
                        && a.activeSession != null
                        && beforeAmbigUrl.equals(a.activeSession.streamUrl),
                "R2: uncertain target line C opens episode picker without jumping to wrong episode");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // === R5: Active cast controllable; after exiting cast A, stale bridge cannot control local VOD B ===
        final LiteCast.Bridge castBridge = a.createCastBridge();
        main(
                new Runnable() {
                    public void run() {
                        a.playCastStream(
                                base + "/video.mp4",
                                "R5投屏A",
                                Collections.<String, String>emptyMap());
                    }
                });
        check(waitReady(25000), "R5: active cast A prepared");
        SystemClock.sleep(400);
        check(
                "PLAYING".equals(castBridge.transportState()) && castBridge.durationMs() > 0,
                "R5: active cast bridge reports PLAYING and valid duration");
        castBridge.pause();
        SystemClock.sleep(500);
        check(
                "PAUSED_PLAYBACK".equals(castBridge.transportState()),
                "R5: active cast bridge pause() pauses cast playback");
        castBridge.resume();
        SystemClock.sleep(500);
        check(
                "PLAYING".equals(castBridge.transportState()),
                "R5: active cast bridge resume() resumes cast playback");
        // Exit cast A and start local VOD B
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        SystemClock.sleep(300);
        main(
                new Runnable() {
                    public void run() {
                        a.selected = dummySwitchSite;
                        a.activeDetailLine = 0;
                        a.showDetail(switchVod);
                        a.playingEpisodeIndex = 0;
                        a.play(base + "/video.mp4", "EP1");
                    }
                });
        check(waitReady(25000), "R5: local VOD B prepared after exiting cast A");
        SystemClock.sleep(600);
        check(
                "STOPPED".equals(castBridge.transportState())
                        && castBridge.positionMs() == 0
                        && castBridge.durationMs() == 0,
                "R5: stale cast bridge reports STOPPED and 0ms during local VOD B");
        castBridge.pause();
        castBridge.stop();
        SystemClock.sleep(500);
        final boolean[] localStillPlaying = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        localStillPlaying[0] =
                                a.inPlayback
                                        && !a.inCastPlayback
                                        && a.player != null
                                        && a.player.isPlaying();
                    }
                });
        check(
                localStillPlaying[0],
                "R5: stale cast bridge pause()/stop() cannot interrupt local VOD B");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // === R3 & R4 & R7 & R8: Parser precedence, override, prefix headers, rawFrom routing, nested/relative URL, proxy Referer, M3U %decode, XML single ac, search failure ===
        importConfigViaPairing(base + "/config-r2-parse");

        // R3a: Explicit site playUrl beats failing global 503 parser
        final LiteCatalog.Site sExplicit = findSiteByKey("r2_explicit");
        check(sExplicit != null && sExplicit.supported, "R3: loaded r2_explicit site");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sExplicit;
                        a.detail("r2_exp_1");
                    }
                });
        check(waitDetailId("r2_exp_1", 10000), "R3: loaded r2_explicit detail");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000) && waitClockAdvances(), "R3: explicit site playUrl resolves and plays");
        JSONArray r3aLogs = fetchServerLogs();
        boolean sawSiteParse = false, sawExpMedia = false, sawGlobal503 = false;
        for (int i = 0; i < r3aLogs.length(); i++) {
            String p = r3aLogs.getJSONObject(i).optString("path");
            if ("/r2-site-parse".equals(p)) sawSiteParse = true;
            if ("/r2-ok-explicit.mp4".equals(p)) sawExpMedia = true;
            if ("/r2-global-503".equals(p)) sawGlobal503 = true;
        }
        check(
                sawSiteParse && sawExpMedia && !sawGlobal503,
                "R3: server logs confirm /r2-site-parse + /r2-ok-explicit.mp4 hit and /r2-global-503 skipped");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // R3b: Manual override playUrl overrides global 503 parser
        final LiteCatalog.Site sOverrideBefore = findSiteByKey("r2_override");
        check(sOverrideBefore != null, "R3: found r2_override site");
        main(
                new Runnable() {
                    public void run() {
                        try {
                            JSONObject edits = a.readSiteEditsJson();
                            JSONObject overrides = edits.optJSONObject("overrides");
                            if (overrides == null) overrides = new JSONObject();
                            overrides.put(
                                    sOverrideBefore.siteId(),
                                    new JSONObject().put("playUrl", base + "/r2-override-parse?url="));
                            edits.put("overrides", overrides);
                            a.writeSiteEditsJson(edits);
                            a.loadedConfigSignature = "";
                            a.loadConfiguredSites();
                        } catch (Exception ignored) {
                        }
                    }
                });
        final LiteCatalog.Site sOverrideAfter = findSiteByKey("r2_override");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sOverrideAfter;
                        a.detail("r2_ovr_1");
                    }
                });
        check(waitDetailId("r2_ovr_1", 10000), "R3: loaded r2_override detail");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000) && waitClockAdvances(), "R3: overridden playUrl resolves and plays");
        JSONArray r3bLogs = fetchServerLogs();
        boolean sawOvrParse = false, sawOvrMedia = false, sawOvr503 = false;
        for (int i = 0; i < r3bLogs.length(); i++) {
            String p = r3bLogs.getJSONObject(i).optString("path");
            if ("/r2-override-parse".equals(p)) sawOvrParse = true;
            if ("/r2-ok-override.mp4".equals(p)) sawOvrMedia = true;
            if ("/r2-global-503".equals(p)) sawOvr503 = true;
        }
        check(
                sawOvrParse && sawOvrMedia && !sawOvr503,
                "R3: manual override hit /r2-override-parse + /r2-ok-override.mp4 without hitting 503");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // R3c: Same-origin legacy prefix sends site Referer on preflight and plays (0 403s)
        final LiteCatalog.Site sPrefix = findSiteByKey("r2_prefix");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sPrefix;
                        a.detail("r2_pre_1");
                    }
                });
        check(waitDetailId("r2_pre_1", 10000), "R3: loaded r2_prefix detail");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000) && waitClockAdvances(), "R3: same-origin prefix with Referer plays");
        JSONArray r3cLogs = fetchServerLogs();
        boolean sawPrefix200 = false, sawPrefix403 = false;
        for (int i = 0; i < r3cLogs.length(); i++) {
            JSONObject row = r3cLogs.getJSONObject(i);
            if ("/r2-prefix-ref".equals(row.optString("path"))) {
                int st = row.optInt("status");
                if ((st == 200 || st == 206) && "https://r2-site.example/".equals(row.optString("referer"))) {
                    sawPrefix200 = true;
                }
                if (st == 403) sawPrefix403 = true;
            }
        }
        check(
                sawPrefix200 && !sawPrefix403,
                "R3: same-origin prefix preflight and playback received site Referer with 0 403s");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // R3d: Structured display name "高清" with rawFrom="B" routes to parser B (/r2-ok-b.mp4, NOT /r2-wrong.mp4)
        final LiteCatalog.Site sRouting = findSiteByKey("r2_routing");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sRouting;
                        a.detail("r2_rt_1");
                    }
                });
        check(waitDetailId("r2_rt_1", 10000), "R3: loaded r2_routing detail");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000) && waitClockAdvances(), "R3: structured from=B routed and played");
        JSONArray r3dLogs = fetchServerLogs();
        boolean sawParseB = false, sawOkB = false, sawWrong = false;
        for (int i = 0; i < r3dLogs.length(); i++) {
            String p = r3dLogs.getJSONObject(i).optString("path");
            if ("/r2-parse-b".equals(p)) sawParseB = true;
            if ("/r2-ok-b.mp4".equals(p)) sawOkB = true;
            if ("/r2-parse-wrong".equals(p) || "/r2-wrong.mp4".equals(p)) sawWrong = true;
        }
        check(
                sawParseB && sawOkB && !sawWrong,
                "R3: structured show='高清'/from='B' routed to /r2-parse-b and played /r2-ok-b.mp4");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // R4: Query-nested .m3u8? goes to parser + redirected JSON bare relative media/out.m3u8 resolves & plays
        final LiteCatalog.Site sRel = findSiteByKey("r2_rel_query");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sRel;
                        a.detail("r2_r4_1");
                    }
                });
        check(waitDetailId("r2_r4_1", 10000), "R4: loaded r2_rel_query detail");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(
                waitReady(30000) && waitClockAdvances(),
                "R4: query-nested .m3u8? parsed & bare relative media/out.m3u8 played on API14");
        JSONArray r4Logs = fetchServerLogs();
        boolean sawRelEntry = false, sawRelMedia = false;
        for (int i = 0; i < r4Logs.length(); i++) {
            String p = r4Logs.getJSONObject(i).optString("path");
            if ("/r2-rel-parse-entry".equals(p)) sawRelEntry = true;
            if ("/r2-v2/parsers/media/out.m3u8".equals(p)) sawRelMedia = true;
        }
        check(
                sawRelEntry && sawRelMedia,
                "R4: server logs confirm parser hit and final-URL relative /r2-v2/parsers/media/out.m3u8 fetched");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // R7: proxy:// channel Referer + M3U %encoded Referer playback + XML prefilled ?lang=zh&ac=list
        clearServerLogs();
        List<LiteCatalog.LiveSource> r7Lives =
                LiteCatalog.parseLives(
                        a.getPreferences(0).getString("config", ""),
                        a.getPreferences(0).getString("address", ""));
        check(!r7Lives.isEmpty(), "R7: parsed proxy:// live source");
        final List<LiteCatalog.LiveGroup> r7Groups = LiteCatalog.fetchLiveGroups(r7Lives.get(0));
        check(
                !r7Groups.isEmpty() && !r7Groups.get(0).channels.isEmpty(),
                "R7: fetched proxy:// M3U playlist using channel-level Referer");
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                r7Groups.get(0), 0, 0, Collections.<String, String>emptyMap());
                    }
                });
        check(
                waitReady(30000) && waitClockAdvances(),
                "R7: played M3U channel with percent-decoded Referer header");
        JSONArray r7Logs = fetchServerLogs();
        boolean sawProxyM3u200 = false, sawPctHls200 = false, sawR7403 = false;
        for (int i = 0; i < r7Logs.length(); i++) {
            JSONObject row = r7Logs.getJSONObject(i);
            String p = row.optString("path");
            int st = row.optInt("status");
            if ("/r2-proxy-m3u".equals(p) && st == 200) sawProxyM3u200 = true;
            if ("/r2-pct-hls/stream.m3u8".equals(p)
                    && st == 200
                    && "https://r2-pct-tv.example/".equals(row.optString("referer"))) {
                sawPctHls200 = true;
            }
            if (st == 403) sawR7403 = true;
        }
        check(
                sawProxyM3u200 && sawPctHls200 && !sawR7403,
                "R7: server confirmed proxy Referer + percent-decoded HLS Referer with 0 403s");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        final LiteCatalog.Site sXmlPre = findSiteByKey("r2_xml_prefill");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sXmlPre;
                        a.detail("r2_xml_1");
                    }
                });
        check(
                waitDetailId("r2_xml_1", 10000)
                        && "预带XML片".equals(a.currentDetail.optString("vod_name")),
                "R7: XML source prefilled with ?lang=zh&ac=list loads detail cleanly with single ac=videolist");

        // R8: Single-source HTML login & XML error fail (not zero-hit), plus all-failed, partial-failed, pure empty RSS
        final LiteCatalog.Site sHtml = findSiteByKey("r2_html_login");
        final LiteCatalog.Site sXmlErr = findSiteByKey("r2_xml_error");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sHtml;
                        a.catalog("测试", "", 1);
                    }
                });
        check(
                waitStatusContains("加载失败", 10000) && !a.status.getText().toString().contains("零命中"),
                "R8: single-source HTTP 200 HTML login page reports failure instead of zero-hit");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sXmlErr;
                        a.catalog("测试", "", 1);
                    }
                });
        check(
                waitStatusContains("加载失败", 10000) && !a.status.getText().toString().contains("零命中"),
                "R8: single-source HTTP 200 XML error doc reports failure instead of zero-hit");

        importConfigViaPairing(base + "/config-r2-all-fail-search");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("测试");
                    }
                });
        check(
                waitStatusContains("全部失败", 10000),
                "R8: global search across HTML login + XML error sites reports all-failed");

        importConfigViaPairing(base + "/config-r2-partial-fail-search");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("测试");
                    }
                });
        check(
                waitStatusContains("1 个正常无命中", 10000) && waitStatusContains("2 个失败", 2000),
                "R8: global search with 1 valid empty RSS + 2 error sites reports partial failure");

        importConfigViaPairing(base + "/config-r2-pure-empty-rss");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("测试");
                    }
                });
        check(
                waitStatusContains("确实零命中", 10000),
                "R8: global search on valid empty RSS reports true zero-hit");

        // === R6: First-time QR '当前源' pill, cross-source category isolation, history reorder identity focus, >15s post-error timer ===
        // R6a: First-time QR import from empty config reveals usable currentSiteNavPill immediately
        main(
                new Runnable() {
                    public void run() {
                        a.getPreferences(0)
                                .edit()
                                .remove("config")
                                .remove("address")
                                .remove("selected_site")
                                .remove("selected_site_api")
                                .commit();
                        a.selected = null;
                        a.loadedConfigSignature = "";
                        a.home();
                    }
                });
        check(
                a.currentSiteNavPill != null
                        && a.currentSiteNavPill.getVisibility() == View.GONE,
                "R6a: currentSiteNavPill starts hidden when no config is imported");
        main(
                new Runnable() {
                    public void run() {
                        a.configure();
                    }
                });
        long qrDl = SystemClock.uptimeMillis() + 5000;
        while (a.pairing == null && SystemClock.uptimeMillis() < qrDl) SystemClock.sleep(100);
        String qrResp =
                request(
                        a.pairing.port(),
                        "/" + a.pairing.token,
                        "url=" + URLEncoder.encode(base + "/config-v059", "UTF-8"));
        check(qrResp.startsWith("200:"), "R6a: first-time QR import returned 200");
        SystemClock.sleep(600);
        final boolean[] pillReady = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        pillReady[0] =
                                a.currentSiteNavPill != null
                                        && a.currentSiteNavPill.getVisibility() == View.VISIBLE;
                        if (pillReady[0]) a.currentSiteNavPill.performClick();
                    }
                });
        check(
                pillReady[0] && waitCardsAtLeast(1, 10000),
                "R6a: first-time QR import immediately makes top '当前源' button visible and clickable");

        // R6b: Site A (cat1='动作') -> Global Search -> Site B detail -> Back -> click '当前：辅站B' must NOT show '动作' or send t=cat1 to B
        final LiteCatalog.Site r6SiteA = findSiteByKey("site_a");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = r6SiteA;
                        a.categories.clear();
                        a.categoriesSiteId = r6SiteA.siteId();
                        a.catalog("", "", 1);
                    }
                });
        check(waitCardsAtLeast(2, 10000) && !a.categories.isEmpty(), "R6b: Site A categories loaded");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("共搜");
                    }
                });
        check(waitCardsAtLeast(2, 10000), "R6b: global search rendered Site A & Site B cards");
        main(
                new Runnable() {
                    public void run() {
                        a.lastRenderedCards.get(1).performClick();
                    }
                });
        check(
                waitDetailId("vod_b1", 10000) && "site_b".equals(a.selected.key),
                "R6b: opened Site B detail from global search");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        check(waitCardsAtLeast(2, 10000), "R6b: back returned to global search");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.currentSiteNavPill.performClick();
                    }
                });
        check(waitCardsAtLeast(1, 10000), "R6b: clicked '当前：辅站B' pill");
        final boolean[] leakedActionChip = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        leakedActionChip[0] = findChildWithText(a.page, "动作") != null;
                    }
                });
        JSONArray r6bLogs = fetchServerLogs();
        boolean sentACatToB = false;
        for (int i = 0; i < r6bLogs.length(); i++) {
            JSONObject row = r6bLogs.getJSONObject(i);
            if ("/cms-b".equals(row.optString("path")) && row.optString("query").contains("t=cat1")) {
                sentACatToB = true;
            }
        }
        check(
                !leakedActionChip[0] && !sentACatToB,
                "R6b: clicking '当前：辅站B' never renders Site A's '动作' category or sends t=cat1 to B");

        // R6c: History list reorders after playback -> Back restores focus by video identity (index 0, NOT stale index 1)
        LiteStore.clearHistory(a);
        LiteStore.HistoryEntry m1 = new LiteStore.HistoryEntry();
        m1.siteKey = r6SiteA.key;
        m1.siteName = r6SiteA.name;
        m1.siteApi = r6SiteA.api;
        m1.vodId = "vod_drama";
        m1.vodName = "连播测试剧";
        m1.epName = "第1集";
        m1.epUrl = base + "/video.mp4";
        m1.updatedAt = 20000L;
        LiteStore.HistoryEntry m2 = new LiteStore.HistoryEntry();
        m2.siteKey = r6SiteA.key;
        m2.siteName = r6SiteA.name;
        m2.siteApi = r6SiteA.api;
        m2.vodId = "vod_case15";
        m2.vodName = "结构化选集测试片";
        m2.epName = "第01集";
        m2.epUrl = base + "/case15-a1.mp4";
        m2.updatedAt = 10000L;
        LiteStore.saveHistory(a, m2, true);
        LiteStore.saveHistory(a, m1, true);
        // History order is now [0: vod_drama, 1: vod_case15]
        main(
                new Runnable() {
                    public void run() {
                        a.historyPage();
                    }
                });
        check(waitCardsAtLeast(2, 5000), "R6c: history page rendered 2 items");
        main(
                new Runnable() {
                    public void run() {
                        // Click index 1 (vod_case15)
                        a.lastRenderedCards.get(1).performClick();
                    }
                });
        check(waitDetailId("vod_case15", 10000), "R6c: opened index 1 history item (vod_case15)");
        // Simulate playback moving vod_case15 to index 0 (newest updatedAt)
        m2.updatedAt = 30000L;
        LiteStore.saveHistory(a, m2, true);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        SystemClock.sleep(400);
        check(
                "history".equals(a.currentPageKind) && a.lastRestoredFocusIndex == 0,
                "R6c: history reorder restores focus by video identity to index 0 (got "
                        + a.lastRestoredFocusIndex
                        + ")");

        // R6d: After fast playback error, waiting >15s must NOT overwrite error text or steal focus
        List<LiteCatalog.LiveSource> r6Lives =
                LiteCatalog.parseLives(
                        a.getPreferences(0).getString("config", ""),
                        a.getPreferences(0).getString("address", ""));
        final List<LiteCatalog.LiveGroup> r6Groups = LiteCatalog.fetchLiveGroups(r6Lives.get(0));
        int fastBadCh = -1;
        for (int i = 0; i < r6Groups.get(0).channels.size(); i++) {
            if ("坏线快错台".equals(r6Groups.get(0).channels.get(i).name)) {
                fastBadCh = i;
                break;
            }
        }
        final int fastBadChFinal = fastBadCh;
        main(
                new Runnable() {
                    public void run() {
                        a.playLiveChannel(
                                r6Groups.get(0),
                                fastBadChFinal,
                                0,
                                Collections.<String, String>emptyMap());
                    }
                });
        check(
                waitFailed(15000) && waitStatusContains("无法播放", 2000),
                "R6d: bad fast-error line failed with error message");
        final View[] backToolbarBtn = new View[1];
        main(
                new Runnable() {
                    public void run() {
                        backToolbarBtn[0] = findChildWithText(a.playerControlRow, "返回");
                        if (backToolbarBtn[0] != null) {
                            backToolbarBtn[0].requestFocus();
                        }
                    }
                });
        check(
                backToolbarBtn[0] != null && backToolbarBtn[0].hasFocus(),
                "R6d: moved focus away from switchLine button to '返回'");
        SystemClock.sleep(16500);
        final String[] post16sStatus = new String[1];
        final boolean[] backStillFocused = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        post16sStatus[0] = a.status != null ? a.status.getText().toString() : "";
                        backStillFocused[0] =
                                backToolbarBtn[0] != null && backToolbarBtn[0].hasFocus();
                    }
                });
        check(
                post16sStatus[0].contains("无法播放")
                        && !post16sStatus[0].contains("播放准备较慢")
                        && backStillFocused[0],
                "R6d: >15s after playback error, stale slow-prepare timer neither overwrote error text nor stole focus");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
    }

    private static View findChildContainingText(View root, String needle) {
        if (root instanceof android.widget.TextView
                && ((android.widget.TextView) root).getText().toString().contains(needle)) {
            return root;
        }
        if (root instanceof android.view.ViewGroup) {
            android.view.ViewGroup g = (android.view.ViewGroup) root;
            for (int i = 0; i < g.getChildCount(); i++) {
                View found = findChildContainingText(g.getChildAt(i), needle);
                if (found != null) return found;
            }
        }
        return null;
    }

    private void runRound3ReworkChecks() throws Exception {
        final String base = "http://10.0.2.2:8773";

        // === R3 Item 1 (P1): Preserve unattributed legacy history/favorites when only A is loaded but B exists in saved data ===
        importConfigViaPairing(base + "/config-r3-only-dup1");
        final String apiA = base + "/cms-dup1";
        final String apiB = base + "/cms-dup2";
        LiteStore.clearHistory(a);
        LiteStore.clearFavorites(a);
        LiteStore.setTombstonesRaw(a, "");
        String cloudAllThree =
                new JSONObject()
                        .put("schema", "marco-movie-sync")
                        .put("version", 2)
                        .put(
                                "watch_history",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("site", "dup_cms")
                                                        .put("siteApi", apiA)
                                                        .put("id", "100")
                                                        .put("title", "甲站电影")
                                                        .put("episode", "第1集")
                                                        .put("position", 11000)
                                                        .put("updated", 11L))
                                        .put(
                                                new JSONObject()
                                                        .put("site", "dup_cms")
                                                        .put("siteApi", apiB)
                                                        .put("id", "100")
                                                        .put("title", "乙站剧集")
                                                        .put("episode", "第1集")
                                                        .put("position", 12000)
                                                        .put("updated", 12L))
                                        .put(
                                                new JSONObject()
                                                        .put("site", "dup_cms")
                                                        .put("siteApi", "")
                                                        .put("id", "100")
                                                        .put("title", "旧未归属片")
                                                        .put("episode", "第1集")
                                                        .put("position", 10000)
                                                        .put("updated", 10L)))
                        .put(
                                "favorites",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("site", "dup_cms")
                                                        .put("siteApi", apiA)
                                                        .put("id", "100")
                                                        .put("title", "甲站电影")
                                                        .put("updated", 11L))
                                        .put(
                                                new JSONObject()
                                                        .put("site", "dup_cms")
                                                        .put("siteApi", apiB)
                                                        .put("id", "100")
                                                        .put("title", "乙站剧集")
                                                        .put("updated", 12L))
                                        .put(
                                                new JSONObject()
                                                        .put("site", "dup_cms")
                                                        .put("siteApi", "")
                                                        .put("id", "100")
                                                        .put("title", "旧未归属片")
                                                        .put("updated", 10L)))
                        .put("tombstones", new JSONObject())
                        .toString();
        LiteSync.MergeResult seeded3 = a.mergeAndApplyOnAnyThread(cloudAllThree);
        check(
                seeded3.historyCount == 3
                        && seeded3.favoriteCount == 3
                        && !a.isUniqueSiteKey("dup_cms"),
                "R3-1: only-A subscription with saved A/B records marks siteKey ambiguous and preserves all 3 entries");

        // Save A progress + unfavorite A -> B and unattributed "" MUST survive; no bare tombstone written
        LiteStore.HistoryEntry updHistA = new LiteStore.HistoryEntry();
        updHistA.siteKey = "dup_cms";
        updHistA.siteName = "同键甲站";
        updHistA.siteApi = apiA;
        updHistA.vodId = "100";
        updHistA.vodName = "甲站电影";
        updHistA.epName = "第1集";
        updHistA.epUrl = base + "/video.mp4";
        updHistA.positionMs = 15000;
        updHistA.updatedAt = 50L;
        boolean uiUnique = a.isUniqueSiteKey("dup_cms");
        LiteStore.saveHistory(a, updHistA, uiUnique);
        LiteStore.FavoriteEntry favEntryA = new LiteStore.FavoriteEntry();
        favEntryA.siteKey = "dup_cms";
        favEntryA.siteName = "同键甲站";
        favEntryA.siteApi = apiA;
        favEntryA.vodId = "100";
        favEntryA.vodName = "甲站电影";
        LiteStore.toggleFavorite(a, favEntryA, uiUnique);
        a.recordFavoriteToggleTombstone("dup_cms", apiA, "100", false, uiUnique);
        JSONObject tombsAfterUnfav = new JSONObject(LiteStore.getTombstonesRaw(a));
        check(
                LiteStore.getHistory(a).size() == 3
                        && LiteStore.getFavorites(a).size() == 2
                        && tombsAfterUnfav.has("fav:" + LiteSync.itemKey("dup_cms", apiA, "100"))
                        && !tombsAfterUnfav.has("fav:" + LiteSync.itemKey("dup_cms", "", "100")),
                "R3-1: saving A progress & unfavoriting A under only-A config preserves B and unattributed legacy record without bare tombstone");

        // Restore A+B subscription and replay old cloud twice -> only A removed, B & unattributed "" survive
        importConfigViaPairing(base + "/config-dup-key");
        LiteSync.MergeResult repA = a.mergeAndApplyOnAnyThread(cloudAllThree);
        LiteSync.MergeResult repB = a.mergeAndApplyOnAnyThread(cloudAllThree);
        check(
                repA.favoriteCount == 2
                        && repB.favoriteCount == 2
                        && !LiteStore.containsFavorite(repB.favoritesJson, "dup_cms", apiA, "100", false)
                        && LiteStore.containsFavorite(repB.favoritesJson, "dup_cms", apiB, "100", false)
                        && LiteStore.containsFavorite(repB.favoritesJson, "dup_cms", "", "100", false),
                "R3-1: restoring A+B subscription and replaying old cloud twice keeps B and unattributed legacy favorite");

        // === R3 Item 2 (P1): Bare URL sequential labels & resume ep2; same-name shared-URL line B resume; S02E02 & EP2->EP3 switch ===
        importConfigViaPairing(base + "/config-r3-cases");
        final LiteCatalog.Site r3RouteSite = findSiteByKey("r3_rename_route");
        check(r3RouteSite != null && r3RouteSite.supported, "R3-2/3: loaded r3_rename_route site");

        // 2a: Bare URL array labels 第1集 / 第2集 -> play 2nd (video2.mp4) -> resume button requests video2.mp4 & seeks
        final JSONObject bareVod =
                new JSONObject()
                        .put("vod_id", "r3_bare_arr")
                        .put("vod_name", "裸URL数组测试")
                        .put(
                                "vod_play_list",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put(
                                                                "player_info",
                                                                new JSONObject()
                                                                        .put("show", "HD")
                                                                        .put("from", "plain"))
                                                        .put(
                                                                "urls",
                                                                new JSONArray()
                                                                        .put(base + "/video.mp4")
                                                                        .put(base + "/video2.mp4"))));
        final List<LiteActivity.PlayLine> barePl = LiteActivity.extractPlayLines(bareVod, "");
        check(
                barePl.size() == 1
                        && barePl.get(0).episodes.size() == 2
                        && "第1集".equals(barePl.get(0).episodes.get(0).name)
                        && "第2集".equals(barePl.get(0).episodes.get(1).name),
                "R3-2a: bare URL array names episodes 第1集 / 第2集 sequentially on API14");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = r3RouteSite;
                        a.activeDetailLine = 0;
                        a.showDetail(bareVod);
                        LiteActivity.EpisodeItem ep2 = barePl.get(0).episodes.get(1);
                        a.playingEpisodeIndex = ep2.originalIndex;
                        a.play(ep2.url, ep2.name);
                    }
                });
        check(waitReady(25000), "R3-2a: bare URL episode 2 prepared");
        main(
                new Runnable() {
                    public void run() {
                        a.player.seekTo(12000);
                    }
                });
        SystemClock.sleep(1600);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                        a.activeDetailLine = -1;
                        a.showDetail(bareVod);
                    }
                });
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        View resumeBtn = findChildContainingText(a.page, "续播");
                        if (resumeBtn == null) throw new RuntimeException("missing resume button");
                        resumeBtn.performClick();
                    }
                });
        check(waitReady(25000), "R3-2a: clicking resume after bare URL ep2 prepared");
        SystemClock.sleep(800);
        final int[] bareResumedPos = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        bareResumedPos[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                    }
                });
        JSONArray bareLogs = fetchServerLogs();
        boolean sawVideo2 = false, sawVideo1 = false;
        for (int i = 0; i < bareLogs.length(); i++) {
            String p = bareLogs.getJSONObject(i).optString("path");
            if ("/video2.mp4".equals(p)) sawVideo2 = true;
            if ("/video.mp4".equals(p)) sawVideo1 = true;
        }
        check(
                sawVideo2
                        && !sawVideo1
                        && (base + "/video2.mp4").equals(a.activeSession.streamUrl)
                        && bareResumedPos[0] >= 9000,
                "R3-2a: resume button requests /video2.mp4 (not /video.mp4) and restores progress ("
                        + bareResumedPos[0]
                        + "ms)");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // 2b: Same display name '高清' + same raw URL across lines A & B -> watch B -> reopen detail selects B & resumes /r3-clip-b.mp4
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = r3RouteSite;
                        a.detail("r3_rr_1");
                    }
                });
        check(waitDetailId("r3_rr_1", 10000), "R3-2b: loaded same-name shared-URL dual-line detail");
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 1;
                        a.showDetail(a.currentDetail);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000), "R3-2b: line B prepared");
        main(
                new Runnable() {
                    public void run() {
                        a.player.seekTo(11000);
                    }
                });
        SystemClock.sleep(1600);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                        a.activeDetailLine = -1;
                        a.showDetail(a.currentDetail);
                    }
                });
        LiteStore.HistoryEntry savedSharedLine =
                LiteStore.findHistory(a, r3RouteSite.key, r3RouteSite.api, "r3_rr_1", true);
        check(
                savedSharedLine != null
                        && "B".equals(savedSharedLine.lineFrom)
                        && a.activeDetailLine == 1,
                "R3-2b: history persisted lineFrom=B and reopening detail restored line B (idx="
                        + a.activeDetailLine
                        + ")");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        View resumeBtn = findChildContainingText(a.page, "续播");
                        if (resumeBtn == null) throw new RuntimeException("missing resume button");
                        resumeBtn.performClick();
                    }
                });
        check(waitReady(25000), "R3-2b: clicking resume on restored line B prepared");
        SystemClock.sleep(800);
        final int[] sharedResumedPos = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        sharedResumedPos[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                    }
                });
        JSONArray sharedLogs = fetchServerLogs();
        boolean sawR3ParseB = false, sawR3ClipB = false, sawR3ParseA = false, sawR3ClipA = false;
        for (int i = 0; i < sharedLogs.length(); i++) {
            String p = sharedLogs.getJSONObject(i).optString("path");
            if ("/r3-parse-b".equals(p)) sawR3ParseB = true;
            if ("/r3-clip-b.mp4".equals(p)) sawR3ClipB = true;
            if ("/r3-parse-a".equals(p)) sawR3ParseA = true;
            if ("/r3-clip-a.mp4".equals(p)) sawR3ClipA = true;
        }
        check(
                sawR3ParseB
                        && sawR3ClipB
                        && !sawR3ParseA
                        && !sawR3ClipA
                        && sharedResumedPos[0] >= 8000,
                "R3-2b: resume hits /r3-parse-b + /r3-clip-b.mp4 (0 /r3-parse-a) with restored progress ("
                        + sharedResumedPos[0]
                        + "ms)");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // 2c: Cross-season S02E02->[S01E02,S01E03] and singleton [EP2]->[EP3] open episode picker without jumping
        final JSONObject conflictVod =
                new JSONObject()
                        .put("vod_id", "r3_conflict")
                        .put("vod_name", "R3换线冲突测试")
                        .put("vod_play_from", "S2$$$S1$$$SingleA$$$SingleB")
                        .put(
                                "vod_play_url",
                                "S02E01$"
                                        + base
                                        + "/video.mp4#S02E02$"
                                        + base
                                        + "/video2.mp4$$$S01E02$"
                                        + base
                                        + "/case15-a1.mp4#S01E03$"
                                        + base
                                        + "/case15-b1.mp4$$$EP2$"
                                        + base
                                        + "/video2.mp4$$$EP3$"
                                        + base
                                        + "/case15-b1.mp4");
        final List<LiteActivity.PlayLine> confLines = LiteActivity.extractPlayLines(conflictVod, "");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = r3RouteSite;
                        a.activeDetailLine = 0;
                        a.showDetail(conflictVod);
                        a.playingEpisodeIndex = 1;
                        a.play(base + "/video2.mp4", "S02E02");
                    }
                });
        check(waitReady(25000), "R3-2c: S02E02 prepared");
        final boolean[] seasonPickerShown = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        a.switchToPlayLineInPlayer(confLines, 1);
                        seasonPickerShown[0] =
                                a.activeInPlayerDialog != null && a.activeInPlayerDialog.isShowing();
                        a.dismissActiveInPlayerDialog();
                    }
                });
        check(
                seasonPickerShown[0] && (base + "/video2.mp4").equals(a.activeSession.streamUrl),
                "R3-2c: switching S02E02 to [S01E02,S01E03] opens episode picker without jumping");
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 2;
                        a.showDetail(conflictVod);
                        a.playingEpisodeIndex = 0;
                        a.play(base + "/video2.mp4", "EP2");
                    }
                });
        check(waitReady(25000), "R3-2c: singleton EP2 prepared");
        final boolean[] singletonPickerShown = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        a.switchToPlayLineInPlayer(confLines, 3);
                        singletonPickerShown[0] =
                                a.activeInPlayerDialog != null && a.activeInPlayerDialog.isShowing();
                        a.dismissActiveInPlayerDialog();
                    }
                });
        check(
                singletonPickerShown[0] && (base + "/video2.mp4").equals(a.activeSession.streamUrl),
                "R3-2c: switching singleton [EP2] to [EP3] opens episode picker without jumping");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // === R3 Item 3 (P1): Matching global parse UA, rename preserving inherited routing, rename preserving type=0 /gateway ===
        final LiteCatalog.Site r3SameHeaderSite = findSiteByKey("r3_same_header");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = r3SameHeaderSite;
                        a.detail("r3_wh_1");
                    }
                });
        check(waitDetailId("r3_wh_1", 10000), "R3-3a: loaded r3_same_header detail");
        main(
                new Runnable() {
                    public void run() {
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000) && waitClockAdvances(), "R3-3a: same-endpoint parse played with global UA");
        JSONArray r3aLogs = fetchServerLogs();
        boolean sawWh200 = false, sawWh403 = false, sawWhClipB = false;
        for (int i = 0; i < r3aLogs.length(); i++) {
            JSONObject row = r3aLogs.getJSONObject(i);
            String p = row.optString("path");
            int st = row.optInt("status");
            if ("/r3-with-header".equals(p)) {
                if (st == 200 && "ParserMobile/1".equals(row.optString("userAgent"))) sawWh200 = true;
                if (st == 403) sawWh403 = true;
            }
            if ("/r3-clip-b.mp4".equals(p) && (st == 200 || st == 206)) sawWhClipB = true;
        }
        check(
                sawWh200 && sawWhClipB && !sawWh403,
                "R3-3a: server confirmed /r3-with-header received UA=ParserMobile/1 (0 403s) and played /r3-clip-b.mp4");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // 3b: Rename r3_rename_route (saving all unchanged fields including inherited playUrl) -> line B STILL hits /r3-parse-b & /r3-clip-b.mp4
        final LiteCatalog.Site r3XmlGwBefore = findSiteByKey("r3_xml_gateway");
        main(
                new Runnable() {
                    public void run() {
                        try {
                            JSONObject edits = a.readSiteEditsJson();
                            JSONObject overrides = edits.optJSONObject("overrides");
                            if (overrides == null) overrides = new JSONObject();
                            overrides.put(
                                    r3RouteSite.siteId(),
                                    new JSONObject()
                                            .put("name", "已改名路由站")
                                            .put("group", r3RouteSite.group)
                                            .put("api", r3RouteSite.api)
                                            .put("playUrl", r3RouteSite.playUrl)
                                            .put("ext", "")
                                            .put("searchable", false));
                            overrides.put(
                                    r3XmlGwBefore.siteId(),
                                    new JSONObject()
                                            .put("name", "已改名网关XML站")
                                            .put("group", r3XmlGwBefore.group)
                                            .put("api", r3XmlGwBefore.api)
                                            .put("playUrl", r3XmlGwBefore.playUrl)
                                            .put("ext", "")
                                            .put("searchable", false));
                            edits.put("overrides", overrides);
                            a.writeSiteEditsJson(edits);
                            a.loadedConfigSignature = "";
                            a.loadConfiguredSites();
                        } catch (Exception ignored) {
                        }
                    }
                });
        final LiteCatalog.Site r3RenamedRoute = findSiteByKey("r3_rename_route");
        final LiteCatalog.Site r3RenamedGw = findSiteByKey("r3_xml_gateway");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = r3RenamedRoute;
                        a.detail("r3_rr_1");
                    }
                });
        check(
                waitDetailId("r3_rr_1", 10000) && "已改名路由站".equals(r3RenamedRoute.name),
                "R3-3b: loaded renamed route site detail");
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 1;
                        a.showDetail(a.currentDetail);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000) && waitClockAdvances(), "R3-3b: renamed site line B prepared & played");
        JSONArray r3bLogs = fetchServerLogs();
        boolean sawRenB = false, sawRenClipB = false, sawRenA = false, sawRenClipA = false;
        for (int i = 0; i < r3bLogs.length(); i++) {
            String p = r3bLogs.getJSONObject(i).optString("path");
            if ("/r3-parse-b".equals(p)) sawRenB = true;
            if ("/r3-clip-b.mp4".equals(p)) sawRenClipB = true;
            if ("/r3-parse-a".equals(p)) sawRenA = true;
            if ("/r3-clip-a.mp4".equals(p)) sawRenClipA = true;
        }
        check(
                sawRenB && sawRenClipB && !sawRenA && !sawRenClipA,
                "R3-3b: renaming site preserves inherited parser routing (/r3-parse-b -> /r3-clip-b.mp4, 0 /r3-parse-a)");
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });

        // 3c: Renamed explicit type=0 /r3-gateway still sends ac=videolist (0 ac=detail / 400)
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = r3RenamedGw;
                        a.detail("1");
                    }
                });
        check(
                waitDetailId("1", 10000)
                        && r3RenamedGw.type == 0
                        && "网关XML片".equals(a.currentDetail.optString("vod_name")),
                "R3-3c: renamed explicit type=0 /r3-gateway loads detail");
        JSONArray r3cLogs = fetchServerLogs();
        boolean sawGwVideolist = false, sawGwDetailOr400 = false;
        for (int i = 0; i < r3cLogs.length(); i++) {
            JSONObject row = r3cLogs.getJSONObject(i);
            if ("/r3-gateway".equals(row.optString("path"))) {
                if (row.optString("query").contains("ac=videolist") && row.optInt("status") == 200) {
                    sawGwVideolist = true;
                }
                if (row.optString("query").contains("ac=detail") || row.optInt("status") == 400) {
                    sawGwDetailOr400 = true;
                }
            }
        }
        check(
                sawGwVideolist && !sawGwDetailOr400,
                "R3-3c: server confirmed renamed type=0 /r3-gateway sent ac=videolist (200, 0 ac=detail/400)");

        // === R3 Item 4 (P2): Search distinguishes XML error root + JSON 403 w/ empty list from <!DOCTYPE rss> valid zero-hit ===
        final LiteCatalog.Site sXmlErrList = findSiteByKey("r3_xml_err_list");
        final LiteCatalog.Site sJson403List = findSiteByKey("r3_json_403_list");
        final LiteCatalog.Site sDoctypeRss = findSiteByKey("r3_doctype_rss");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sXmlErrList;
                        a.catalog("测试", "", 1);
                    }
                });
        check(
                waitStatusContains("加载失败", 10000) && !a.status.getText().toString().contains("零命中"),
                "R3-4: single-source <error><code>503</code><list/></error> reports failure (not zero-hit)");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sJson403List;
                        a.catalog("测试", "", 1);
                    }
                });
        check(
                waitStatusContains("加载失败", 10000) && !a.status.getText().toString().contains("零命中"),
                "R3-4: single-source JSON 403 with empty list reports failure (not zero-hit)");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sDoctypeRss;
                        a.catalog("测试", "", 1);
                    }
                });
        check(
                waitStatusContains("确实零命中", 10000),
                "R3-4: single-source <!DOCTYPE rss> valid empty RSS reports true zero-hit on API14");

        importConfigViaPairing(base + "/config-r3-search-all-fail");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("测试");
                    }
                });
        check(
                waitStatusContains("全部失败", 10000),
                "R3-4: global search on XML error-with-list + JSON 403-with-list reports all-failed");

        importConfigViaPairing(base + "/config-r3-search-partial-fail");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("测试");
                    }
                });
        check(
                waitStatusContains("1 个正常无命中", 10000) && waitStatusContains("2 个失败", 2000),
                "R3-4: global search with <!DOCTYPE rss> empty + 2 error-with-list sites reports partial failure");

        importConfigViaPairing(base + "/config-r3-search-doctype-zero");
        main(
                new Runnable() {
                    public void run() {
                        a.globalSearch("测试");
                    }
                });
        check(
                waitStatusContains("确实零命中", 10000),
                "R3-4: global search on <!DOCTYPE rss> valid empty RSS reports true zero-hit");
    }

    private static boolean hasServerLog(JSONArray logs, String path, String querySub) {
        if (logs == null) return false;
        for (int i = 0; i < logs.length(); i++) {
            JSONObject rec = logs.optJSONObject(i);
            if (rec == null || !path.equals(rec.optString("path"))) continue;
            if (querySub == null || rec.optString("query").contains(querySub)) {
                return true;
            }
        }
        return false;
    }

    private static int countServerLogs(JSONArray logs, String path) {
        if (logs == null) return 0;
        int n = 0;
        for (int i = 0; i < logs.length(); i++) {
            JSONObject rec = logs.optJSONObject(i);
            if (rec != null && path.equals(rec.optString("path"))) n++;
        }
        return n;
    }

    private void submitEditSiteForm(
            final String siteKey,
            final String newName,
            final String newApi,
            final String newPlayUrl) {
        main(
                new Runnable() {
                    public void run() {
                        LiteCatalog.Site target = findSiteByKey(siteKey);
                        if (target == null) {
                            throw new IllegalStateException("Site not found: " + siteKey);
                        }
                        a.editSiteFieldsPage(target);
                        List<android.widget.EditText> edits =
                                new java.util.ArrayList<android.widget.EditText>();
                        for (int i = 0; i < a.page.getChildCount(); i++) {
                            View v = a.page.getChildAt(i);
                            if (v instanceof android.widget.EditText) {
                                edits.add((android.widget.EditText) v);
                            }
                        }
                        if (edits.size() < 4) {
                            throw new IllegalStateException(
                                    "Unexpected EditText count: " + edits.size());
                        }
                        if (newName != null) edits.get(0).setText(newName);
                        if (newApi != null) edits.get(2).setText(newApi);
                        if (newPlayUrl != null) edits.get(3).setText(newPlayUrl);
                        View saveBtn = findChildContainingText(a.page, "保存线路修改");
                        if (saveBtn == null) {
                            throw new IllegalStateException(
                                    "Save button not found in editSiteFieldsPage");
                        }
                        saveBtn.performClick();
                        // Simulate full app restart reload from persisted preferences & site edits
                        a.loadedConfigSignature = "";
                        a.loadConfiguredSites();
                    }
                });
    }

    private void runRound4ReworkChecks() throws Exception {
        final String base = "http://10.0.2.2:8773";

        // === R4 Item 1 (P1): Real edit form two consecutive saves, active clear, explicit global-first, XML->JSON API switch ===
        importConfigViaPairing(base + "/config-r3-cases");
        main(
                new Runnable() {
                    public void run() {
                        a.writeSiteEditsJson(new JSONObject());
                        a.loadedConfigSignature = "";
                        a.loadConfiguredSites();
                    }
                });

        // Step 1: Enter manual API + manual parse prefix (/r3-parse-a?url=) and click save
        submitEditSiteForm("r3_rename_route", null, base + "/r4-cms-custom", base + "/r3-parse-a?url=");
        final LiteCatalog.Site sAfterEdit1 = findSiteByKey("r3_rename_route");
        check(
                sAfterEdit1 != null
                        && (base + "/r4-cms-custom").equals(sAfterEdit1.api)
                        && (base + "/r3-parse-a?url=").equals(sAfterEdit1.playUrl)
                        && sAfterEdit1.explicitSitePlayUrl,
                "R4-1a: first real edit form save persists manual API and explicit playUrl");

        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sAfterEdit1;
                        a.currentDetail = null;
                        a.detail("r3_rr_1");
                    }
                });
        check(
                waitDetailId("r3_rr_1", 10000),
                "R4-1a: manual custom CMS API loaded detail after save #1");
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 1;
                        a.showDetail(a.currentDetail);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000), "R4-1a: line B played via manual parser after save #1");
        SystemClock.sleep(500);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray r4Log1 = fetchServerLogs();
        check(
                hasServerLog(r4Log1, "/r4-cms-custom", "ids=r3_rr_1")
                        && hasServerLog(r4Log1, "/r3-parse-a", null)
                        && hasServerLog(r4Log1, "/r3-clip-a.mp4", null)
                        && countServerLogs(r4Log1, "/r3-parse-b") == 0,
                "R4-1a: server confirmed save #1 hit /r4-cms-custom -> /r3-parse-a -> /r3-clip-a.mp4");

        // Step 2: Re-enter real edit form, ONLY rename, click save, simulate restart reload
        submitEditSiteForm("r3_rename_route", "二次改名保覆盖", null, null);
        final LiteCatalog.Site sAfterEdit2 = findSiteByKey("r3_rename_route");
        check(
                sAfterEdit2 != null
                        && "二次改名保覆盖".equals(sAfterEdit2.name)
                        && (base + "/r4-cms-custom").equals(sAfterEdit2.api)
                        && (base + "/r3-parse-a?url=").equals(sAfterEdit2.playUrl)
                        && sAfterEdit2.explicitSitePlayUrl,
                "R4-1b: second real edit form rename-only save preserves manual API and playUrl after reload");

        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sAfterEdit2;
                        a.currentDetail = null;
                        a.detail("r3_rr_1");
                    }
                });
        check(
                waitDetailId("r3_rr_1", 10000),
                "R4-1b: custom CMS API still loaded detail after rename-only save #2");
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 1;
                        a.showDetail(a.currentDetail);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000), "R4-1b: line B still played via manual parser after save #2");
        SystemClock.sleep(500);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray r4Log2 = fetchServerLogs();
        check(
                hasServerLog(r4Log2, "/r4-cms-custom", "ids=r3_rr_1")
                        && hasServerLog(r4Log2, "/r3-parse-a", null)
                        && hasServerLog(r4Log2, "/r3-clip-a.mp4", null)
                        && countServerLogs(r4Log2, "/r3-parse-b") == 0
                        && countServerLogs(r4Log2, "/r3-clip-b.mp4") == 0,
                "R4-1b: server confirmed save #2 still hit /r4-cms-custom -> /r3-parse-a -> /r3-clip-a.mp4 (0 /r3-parse-b)");

        // Step 3: Active clear playUrl in real edit form reverts to global routing (/r3-parse-b -> /r3-clip-b.mp4)
        submitEditSiteForm("r3_rename_route", null, null, "");
        final LiteCatalog.Site sAfterClear = findSiteByKey("r3_rename_route");
        check(
                sAfterClear != null && !sAfterClear.explicitSitePlayUrl,
                "R4-1c: actively clearing playUrl in edit form clears explicit override");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sAfterClear;
                        a.activeDetailLine = 1;
                        a.showDetail(a.currentDetail);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000), "R4-1c: line B played via global route after active clear");
        SystemClock.sleep(400);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray r4LogClear = fetchServerLogs();
        check(
                hasServerLog(r4LogClear, "/r3-parse-b", null)
                        && hasServerLog(r4LogClear, "/r3-clip-b.mp4", null)
                        && countServerLogs(r4LogClear, "/r3-parse-a") == 0,
                "R4-1c: server confirmed active clear routed line B back to /r3-parse-b -> /r3-clip-b.mp4");

        // Step 4: Deliberately entering the first inherited global parse URL into empty box must stick as explicit
        main(
                new Runnable() {
                    public void run() {
                        a.writeSiteEditsJson(new JSONObject());
                        a.loadedConfigSignature = "";
                        a.loadConfiguredSites();
                    }
                });
        submitEditSiteForm("r3_rename_route", null, null, base + "/r3-with-header?url=");
        final LiteCatalog.Site sGlobalFirst = findSiteByKey("r3_rename_route");
        check(
                sGlobalFirst != null
                        && sGlobalFirst.explicitSitePlayUrl
                        && (base + "/r3-with-header?url=").equals(sGlobalFirst.playUrl),
                "R4-1d: entering global-first parse URL in empty box marks explicitSitePlayUrl=true");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sGlobalFirst;
                        a.currentDetail = null;
                        a.detail("r3_rr_1");
                    }
                });
        waitDetailId("r3_rr_1", 10000);
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 1;
                        a.showDetail(a.currentDetail);
                        LiteActivity.EpisodeItem ep = a.currentLineEpisodes.get(0);
                        a.playingEpisodeIndex = ep.originalIndex;
                        a.play(ep.url, ep.name);
                    }
                });
        check(waitReady(25000), "R4-1d: explicit global-first parser played cleanly");
        SystemClock.sleep(400);
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                    }
                });
        JSONArray r4LogGf = fetchServerLogs();
        boolean gfHitWithUa = false;
        for (int i = 0; i < r4LogGf.length(); i++) {
            JSONObject rec = r4LogGf.optJSONObject(i);
            if (rec != null
                    && "/r3-with-header".equals(rec.optString("path"))
                    && "ParserMobile/1".equals(rec.optString("userAgent"))
                    && rec.optInt("status") == 200) {
                gfHitWithUa = true;
            }
        }
        check(
                gfHitWithUa
                        && hasServerLog(r4LogGf, "/r3-clip-b.mp4", null)
                        && countServerLogs(r4LogGf, "/r3-parse-b") == 0,
                "R4-1d: server confirmed explicit global-first hit /r3-with-header with UA=ParserMobile/1 (0 /r3-parse-b)");

        // Step 5: Explicit XML site renamed stays XML (ac=videolist); changed to /r4-catalog.json switches to JSON (ac=detail)
        submitEditSiteForm("r3_xml_gateway", "网关XML改名后", null, null);
        final LiteCatalog.Site sXmlRenamed = findSiteByKey("r3_xml_gateway");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sXmlRenamed;
                        a.currentDetail = null;
                        a.detail("1");
                    }
                });
        check(
                waitDetailId("1", 10000) && sXmlRenamed != null && sXmlRenamed.type == 0,
                "R4-1e: explicit XML site renamed via edit form preserves type=0 and loads detail");
        JSONArray r4LogXml = fetchServerLogs();
        check(
                hasServerLog(r4LogXml, "/r3-gateway", "ac=videolist"),
                "R4-1e: server confirmed renamed XML site sent ac=videolist");

        submitEditSiteForm("r3_xml_gateway", null, base + "/r4-catalog.json", null);
        final LiteCatalog.Site sMovedJson = findSiteByKey("r3_xml_gateway");
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sMovedJson;
                        a.currentDetail = null;
                        a.detail("1");
                    }
                });
        check(
                waitDetailId("1", 10000)
                        && sMovedJson != null
                        && sMovedJson.type == 1
                        && "R4严格JSON片".equals(a.currentDetail.optString("vod_name")),
                "R4-1f: changing explicit XML site API to /r4-catalog.json switches to type=1 and loads JSON detail");
        JSONArray r4LogJson = fetchServerLogs();
        boolean jsonDetail200 = false;
        boolean jsonAny400 = false;
        for (int i = 0; i < r4LogJson.length(); i++) {
            JSONObject rec = r4LogJson.optJSONObject(i);
            if (rec != null && "/r4-catalog.json".equals(rec.optString("path"))) {
                if (rec.optString("query").contains("ac=detail") && rec.optInt("status") == 200) {
                    jsonDetail200 = true;
                }
                if (rec.optInt("status") == 400) jsonAny400 = true;
            }
        }
        check(
                jsonDetail200 && !jsonAny400,
                "R4-1f: server confirmed /r4-catalog.json received ac=detail (200, 0 HTTP 400)");

        // === R4 Item 2 (P2): Same-episode line switch carries progress; Chinese season & shared short-token conflicts open picker ===
        main(
                new Runnable() {
                    public void run() {
                        a.writeSiteEditsJson(new JSONObject());
                        a.loadedConfigSignature = "";
                        a.loadConfiguredSites();
                    }
                });
        final LiteCatalog.Site sR4Play = findSiteByKey("r3_rename_route");
        final JSONObject vodCrossResume =
                new JSONObject()
                        .put("vod_id", "r4_cross_resume")
                        .put("vod_name", "R4换线保进度片")
                        .put("vod_play_from", "A$$$B")
                        .put(
                                "vod_play_url",
                                "EP1$"
                                        + base
                                        + "/video.mp4#EP2$"
                                        + base
                                        + "/video2.mp4$$$第01集$"
                                        + base
                                        + "/case15-a1.mp4#第02集$"
                                        + base
                                        + "/case15-b1.mp4");
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sR4Play;
                        a.activeDetailLine = 0;
                        a.showDetail(vodCrossResume);
                        a.playingEpisodeIndex = 1;
                        a.play(base + "/video2.mp4", "EP2");
                    }
                });
        check(waitReady(25000), "R4-2a: line A EP2 prepared");
        main(
                new Runnable() {
                    public void run() {
                        a.player.seekTo(12000);
                    }
                });
        long seekDeadline = SystemClock.elapsedRealtime() + 8000;
        int posBeforeSwitch = 0;
        while (SystemClock.elapsedRealtime() < seekDeadline) {
            final int[] curPos = new int[1];
            main(
                    new Runnable() {
                        public void run() {
                            curPos[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                        }
                    });
            posBeforeSwitch = curPos[0];
            if (posBeforeSwitch >= 9000) break;
            SystemClock.sleep(120);
        }
        final List<LiteActivity.PlayLine> crossLines =
                LiteActivity.extractPlayLines(vodCrossResume, "");
        main(
                new Runnable() {
                    public void run() {
                        a.saveResume();
                        a.switchToPlayLineInPlayer(crossLines, 1);
                    }
                });
        check(waitReady(25000), "R4-2a: line B 第02集 prepared after switch");
        SystemClock.sleep(1000);
        final int[] posAfterSwitch1 = new int[1];
        final String[] switchedMeta = new String[2];
        main(
                new Runnable() {
                    public void run() {
                        posAfterSwitch1[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                        switchedMeta[0] = a.activeSession != null ? a.activeSession.epName : "";
                        switchedMeta[1] = a.activeSession != null ? a.activeSession.streamUrl : "";
                    }
                });
        SystemClock.sleep(800);
        final int[] posAfterSwitch2 = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        posAfterSwitch2[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                        a.onBackPressed();
                    }
                });
        check(
                "第02集".equals(switchedMeta[0])
                        && (base + "/case15-b1.mp4").equals(switchedMeta[1])
                        && posBeforeSwitch >= 9000
                        && posAfterSwitch1[0] >= 8500
                        && posAfterSwitch2[0] > posAfterSwitch1[0],
                "R4-2a: EP2 -> 第02集 carries progress ("
                        + posBeforeSwitch
                        + "ms -> "
                        + posAfterSwitch1[0]
                        + "ms -> "
                        + posAfterSwitch2[0]
                        + "ms) on /case15-b1.mp4");

        // R4-2b: Chinese season "第二季 第02集" -> ["第一季 第02集", "第一季 第03集"] keeps playing & opens picker
        final JSONObject vodCnSeason =
                new JSONObject()
                        .put("vod_id", "r4_cn_season")
                        .put("vod_name", "R4中文季冲突片")
                        .put("vod_play_from", "A$$$B")
                        .put(
                                "vod_play_url",
                                "第二季 第02集$"
                                        + base
                                        + "/video2.mp4$$$第一季 第02集$"
                                        + base
                                        + "/case15-a1.mp4#第一季 第03集$"
                                        + base
                                        + "/case15-b1.mp4");
        main(
                new Runnable() {
                    public void run() {
                        a.activeDetailLine = 0;
                        a.showDetail(vodCnSeason);
                        a.playingEpisodeIndex = 0;
                        a.play(base + "/video2.mp4", "第二季 第02集");
                    }
                });
        check(waitReady(25000), "R4-2b: 第二季 第02集 prepared");
        final List<LiteActivity.PlayLine> cnSeasonLines =
                LiteActivity.extractPlayLines(vodCnSeason, "");
        final boolean[] cnPickerShown = new boolean[1];
        final String[] cnAfterMeta = new String[2];
        final int[] cnLineAfter = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        a.switchToPlayLineInPlayer(cnSeasonLines, 1);
                        cnPickerShown[0] =
                                a.activeInPlayerDialog != null
                                        && a.activeInPlayerDialog.isShowing();
                        cnAfterMeta[0] = a.activeSession != null ? a.activeSession.epName : "";
                        cnAfterMeta[1] = a.activeSession != null ? a.activeSession.streamUrl : "";
                        cnLineAfter[0] = a.activeDetailLine;
                        a.dismissActiveInPlayerDialog();
                        a.onBackPressed();
                    }
                });
        check(
                cnPickerShown[0]
                        && "第二季 第02集".equals(cnAfterMeta[0])
                        && (base + "/video2.mp4").equals(cnAfterMeta[1])
                        && cnLineAfter[0] == 0,
                "R4-2b: 第二季 第02集 -> 第一季 line keeps current playback and opens episode picker");

        // R4-2c: Shared short token "2" across different parsers with season conflict (S02E02 vs S01E02):
        // watch S02E02$2 past 12s -> switch to B opens picker -> cancel keeps S02E02 playing at >=10s;
        // switch again and manually pick S01E02$2 -> hits /r3-parse-b + /r3-clip-b.mp4 and starts at ~0s (NOT ~11.4s);
        // watch S01E02$2 past 9s and reopen -> restores its OWN progress; picking S01E03$3 starts at ~0s.
        final JSONObject vodSharedToken =
                new JSONObject()
                        .put("vod_id", "r4_shared_token")
                        .put("vod_name", "R4短标识冲突片")
                        .put(
                                "vod_play_list",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put(
                                                                "player_info",
                                                                new JSONObject()
                                                                        .put("show", "线A")
                                                                        .put("from", "A"))
                                                        .put("url", "S02E02$2"))
                                        .put(
                                                new JSONObject()
                                                        .put(
                                                                "player_info",
                                                                new JSONObject()
                                                                        .put("show", "线B")
                                                                        .put("from", "B"))
                                                        .put("url", "S01E02$2#S01E03$3")));
        clearServerLogs();
        main(
                new Runnable() {
                    public void run() {
                        a.selected = sR4Play;
                        a.activeDetailLine = 0;
                        a.showDetail(vodSharedToken);
                        a.playingEpisodeIndex = 0;
                        a.play("2", "S02E02");
                    }
                });
        check(waitReady(25000), "R4-2c: S02E02 (token 2 via /r3-parse-a) prepared");
        main(
                new Runnable() {
                    public void run() {
                        a.player.seekTo(12500);
                    }
                });
        long stSeekEnd = SystemClock.elapsedRealtime() + 8000;
        int s02PosBefore = 0;
        while (SystemClock.elapsedRealtime() < stSeekEnd) {
            final int[] cur = new int[1];
            main(
                    new Runnable() {
                        public void run() {
                            cur[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                        }
                    });
            s02PosBefore = cur[0];
            if (s02PosBefore >= 10000) break;
            SystemClock.sleep(120);
        }
        final List<LiteActivity.PlayLine> sharedTokenLines =
                LiteActivity.extractPlayLines(vodSharedToken, "");
        final boolean[] stPickerShown = new boolean[1];
        final String[] stAfterEp = new String[1];
        final int[] s02PosAfterCancel = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        a.saveResume();
                        a.switchToPlayLineInPlayer(sharedTokenLines, 1);
                        stPickerShown[0] =
                                a.activeInPlayerDialog != null
                                        && a.activeInPlayerDialog.isShowing();
                        stAfterEp[0] = a.activeSession != null ? a.activeSession.epName : "";
                        a.dismissActiveInPlayerDialog();
                        s02PosAfterCancel[0] =
                                a.player != null ? a.player.getCurrentPosition() : 0;
                    }
                });
        SystemClock.sleep(300);
        JSONArray r4LogSt = fetchServerLogs();
        check(
                stPickerShown[0]
                        && "S02E02".equals(stAfterEp[0])
                        && s02PosBefore >= 10000
                        && s02PosAfterCancel[0] >= 10000
                        && hasServerLog(r4LogSt, "/r3-parse-a", null)
                        && countServerLogs(r4LogSt, "/r3-parse-b") == 0,
                "R4-2c: shared short token 2 with S02E02 vs S01E02 keeps S02E02 playing ("
                        + s02PosAfterCancel[0]
                        + "ms), opens picker, and sends 0 requests to /r3-parse-b on cancel");

        // Now switch to line B again and actually click S01E02$2 (index 0) in the picker
        clearServerLogs();
        final boolean[] clickedS01E02 = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        a.saveResume();
                        a.switchToPlayLineInPlayer(sharedTokenLines, 1);
                        if (a.activeInPlayerDialog != null
                                && a.activeInPlayerDialog.isShowing()
                                && a.activeInPlayerDialog.getListView() != null) {
                            a.activeInPlayerDialog
                                    .getListView()
                                    .performItemClick(
                                            a.activeInPlayerDialog.getListView().getChildAt(0),
                                            0,
                                            0);
                            clickedS01E02[0] = true;
                        }
                    }
                });
        check(
                clickedS01E02[0] && waitReady(25000),
                "R4-2d: manually picking S01E02$2 from picker prepared cleanly");
        SystemClock.sleep(1000);
        final int[] s01E02PosMs = new int[1];
        final String[] s01E02Meta = new String[2];
        main(
                new Runnable() {
                    public void run() {
                        s01E02PosMs[0] = a.player != null ? a.player.getCurrentPosition() : -1;
                        s01E02Meta[0] = a.activeSession != null ? a.activeSession.epName : "";
                        s01E02Meta[1] = a.activeSession != null ? a.activeSession.lineFrom : "";
                    }
                });
        JSONArray r4LogS01 = fetchServerLogs();
        check(
                "S01E02".equals(s01E02Meta[0])
                        && "B".equals(s01E02Meta[1])
                        && hasServerLog(r4LogS01, "/r3-parse-b", "url=2")
                        && hasServerLog(r4LogS01, "/r3-clip-b.mp4", null)
                        && s01E02PosMs[0] >= 0
                        && s01E02PosMs[0] < 4500,
                "R4-2d: manual S01E02$2 plays /r3-parse-b -> /r3-clip-b.mp4 from start ("
                        + s01E02PosMs[0]
                        + "ms, NOT inheriting S02E02's "
                        + s02PosBefore
                        + "ms)");

        // Positive control: watching S01E02$2 past 10s and reopening S01E02$2 DOES restore its own progress;
        // switching to S01E03$3 starts from 0.
        main(
                new Runnable() {
                    public void run() {
                        a.player.seekTo(10500);
                    }
                });
        long ownSeekEnd = SystemClock.elapsedRealtime() + 8000;
        int ownSavedPos = 0;
        while (SystemClock.elapsedRealtime() < ownSeekEnd) {
            final int[] cur = new int[1];
            main(
                    new Runnable() {
                        public void run() {
                            cur[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                        }
                    });
            ownSavedPos = cur[0];
            if (ownSavedPos >= 8500) break;
            SystemClock.sleep(120);
        }
        main(
                new Runnable() {
                    public void run() {
                        a.onBackPressed();
                        a.activeDetailLine = 1;
                        a.showDetail(vodSharedToken);
                        a.playingEpisodeIndex = 0;
                        a.play("2", "S01E02");
                    }
                });
        check(waitReady(25000), "R4-2e: reopening S01E02$2 with its own history prepared");
        SystemClock.sleep(900);
        final int[] ownResumedPos = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        ownResumedPos[0] = a.player != null ? a.player.getCurrentPosition() : 0;
                        a.playingEpisodeIndex = 1;
                        a.play("3", "S01E03");
                    }
                });
        check(waitReady(25000), "R4-2e: S01E03$3 control prepared");
        SystemClock.sleep(1000);
        final int[] s01E03Pos = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        s01E03Pos[0] = a.player != null ? a.player.getCurrentPosition() : -1;
                        a.onBackPressed();
                    }
                });
        check(
                ownSavedPos >= 8500
                        && ownResumedPos[0] >= 7500
                        && s01E03Pos[0] >= 0
                        && s01E03Pos[0] < 4500,
                "R4-2e: S01E02$2 restores its own progress ("
                        + ownResumedPos[0]
                        + "ms) while S01E03$3 starts from start ("
                        + s01E03Pos[0]
                        + "ms)");

        // === R4 Item 3 (P2): Clicking ambiguous legacy history or favorite does NOT auto-request A; cancel preserves record; restoring A+B lets user choose B ===
        importConfigViaPairing(base + "/config-r3-only-dup1");
        final String dupA = base + "/cms-dup1";
        final String dupB = base + "/cms-dup2";
        main(
                new Runnable() {
                    public void run() {
                        LiteStore.clearHistory(a);
                        LiteStore.clearFavorites(a);
                        String[] apis = new String[] {dupA, dupB, ""};
                        String[] names = new String[] {"甲站电影", "乙站剧集", "乙站剧集（旧记录）"};
                        for (int i = 0; i < 3; i++) {
                            LiteStore.HistoryEntry h = new LiteStore.HistoryEntry();
                            h.siteKey = "dup_cms";
                            h.siteApi = apis[i];
                            h.siteName = i == 0 ? "同键甲站" : (i == 1 ? "同键乙站" : "旧源");
                            h.vodId = "100";
                            h.vodName = names[i];
                            h.updatedAt = 20000L + i;
                            LiteStore.saveHistory(a, h, false);

                            LiteStore.FavoriteEntry f = new LiteStore.FavoriteEntry();
                            f.siteKey = "dup_cms";
                            f.siteApi = apis[i];
                            f.siteName = h.siteName;
                            f.vodId = "100";
                            f.vodName = names[i];
                            f.addedAt = 20000L + i;
                            LiteStore.toggleFavorite(a, f, false);
                        }
                    }
                });

        // Click legacy history card 0 ("乙站剧集（旧记录）") under only-A config
        clearServerLogs();
        final boolean[] histGuardDialog = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        a.currentDetail = null;
                        a.historyPage();
                        a.lastRenderedCards.get(0).performClick();
                        histGuardDialog[0] =
                                a.activeRecordSourceDialog != null
                                        && a.activeRecordSourceDialog.isShowing();
                    }
                });
        SystemClock.sleep(600);
        JSONArray r4LogHist = fetchServerLogs();
        final boolean[] histStillNoDetail = new boolean[1];
        final int[] histCountAfterCancel = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        histStillNoDetail[0] = a.currentDetail == null;
                        a.dismissActiveRecordSourceDialog();
                        histCountAfterCancel[0] = LiteStore.getHistory(a).size();
                    }
                });
        check(
                histGuardDialog[0]
                        && histStillNoDetail[0]
                        && countServerLogs(r4LogHist, "/cms-dup1") == 0
                        && histCountAfterCancel[0] == 3,
                "R4-3a: clicking ambiguous legacy history shows confirmation dialog with 0 requests to /cms-dup1 and preserves all 3 records on cancel");

        // Click legacy favorite card 0 ("乙站剧集（旧记录）") under only-A config
        clearServerLogs();
        final boolean[] favGuardDialog = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        a.currentDetail = null;
                        a.favoritesPage();
                        a.lastRenderedCards.get(0).performClick();
                        favGuardDialog[0] =
                                a.activeRecordSourceDialog != null
                                        && a.activeRecordSourceDialog.isShowing();
                    }
                });
        SystemClock.sleep(600);
        JSONArray r4LogFav = fetchServerLogs();
        final boolean[] favStillNoDetail = new boolean[1];
        final int[] favCountAfterCancel = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        favStillNoDetail[0] = a.currentDetail == null;
                        a.dismissActiveRecordSourceDialog();
                        favCountAfterCancel[0] = LiteStore.getFavorites(a).size();
                    }
                });
        check(
                favGuardDialog[0]
                        && favStillNoDetail[0]
                        && countServerLogs(r4LogFav, "/cms-dup1") == 0
                        && favCountAfterCancel[0] == 3,
                "R4-3b: clicking ambiguous legacy favorite shares guard dialog with 0 requests to /cms-dup1 and preserves all 3 records on cancel");

        // Restore A+B subscription and verify user can pick B ("同键乙站") to open 乙站剧集
        importConfigViaPairing(base + "/config-dup-key");
        clearServerLogs();
        final int[] restoredOptionCount = new int[1];
        main(
                new Runnable() {
                    public void run() {
                        a.currentDetail = null;
                        a.historyPage();
                        a.lastRenderedCards.get(0).performClick();
                        if (a.activeRecordSourceDialog != null
                                && a.activeRecordSourceDialog.isShowing()
                                && a.activeRecordSourceDialog.getListView() != null) {
                            restoredOptionCount[0] =
                                    a.activeRecordSourceDialog.getListView().getCount();
                            a.activeRecordSourceDialog
                                    .getListView()
                                    .performItemClick(
                                            a.activeRecordSourceDialog
                                                    .getListView()
                                                    .getChildAt(1),
                                            1,
                                            1);
                        }
                    }
                });
        check(
                restoredOptionCount[0] == 2
                        && waitDetailId("100", 10000)
                        && "乙站剧集".equals(a.currentDetail.optString("vod_name")),
                "R4-3c: after restoring A+B subscription, legacy history offers both sources and picking B opens 乙站剧集");
        JSONArray r4LogRestored = fetchServerLogs();
        check(
                hasServerLog(r4LogRestored, "/cms-dup2", "ids=100")
                        && countServerLogs(r4LogRestored, "/cms-dup1") == 0,
                "R4-3c: server confirmed picking B requested /cms-dup2?ac=detail&ids=100 (0 /cms-dup1)");
    }

    static void collectTexts(View view, StringBuilder out) {
        if (view == null) return;
        if (view instanceof TextView) {
            CharSequence t = ((TextView) view).getText();
            if (t != null && t.length() > 0) {
                if (out.length() > 0) out.append('\n');
                out.append(t);
            }
        }
        if (view instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) view;
            for (int i = 0; i < g.getChildCount(); i++) {
                collectTexts(g.getChildAt(i), out);
            }
        }
    }

    static View findClickableViewContainingText(View view, String needle) {
        if (view == null) return null;
        if (view instanceof TextView && view.isClickable()) {
            CharSequence t = ((TextView) view).getText();
            if (t != null && t.toString().contains(needle)) return view;
        }
        if (view instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) view;
            for (int i = 0; i < g.getChildCount(); i++) {
                View found = findClickableViewContainingText(g.getChildAt(i), needle);
                if (found != null) return found;
            }
        }
        return null;
    }

    static boolean containsImageView(View view) {
        if (view == null) return false;
        if (view instanceof ImageView) return true;
        if (view instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) view;
            for (int i = 0; i < g.getChildCount(); i++) {
                if (containsImageView(g.getChildAt(i))) return true;
            }
        }
        return false;
    }

    private void run0510NoticeAndSettingsChecks() throws Exception {
        // 1. Fresh first launch shows official author social + website + anti-malware notice dialog
        main(
                new Runnable() {
                    public void run() {
                        a.getPreferences(0)
                                .edit()
                                .remove(LiteActivity.PREF_OFFICIAL_NOTICE_SEEN)
                                .commit();
                        a.finish();
                    }
                });
        SystemClock.sleep(500);
        a =
                (LiteActivity)
                        startActivitySync(
                                new Intent(getTargetContext(), LiteActivity.class)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        check(a != null, "0.5.10-1a: cold relaunch after clearing first-launch flag succeeded");

        final boolean[] firstLaunchShowing = new boolean[1];
        final String[] firstDialogText = new String[] {""};
        final boolean[] dismissedAfterOk = new boolean[1];
        final boolean[] seenAfterOk = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        if (a.activeOfficialNoticeDialog != null
                                && a.activeOfficialNoticeDialog.isShowing()) {
                            firstLaunchShowing[0] = true;
                            StringBuilder sb = new StringBuilder();
                            collectTexts(
                                    a.activeOfficialNoticeDialog.getWindow().getDecorView(), sb);
                            firstDialogText[0] = sb.toString();
                            android.widget.Button okBtn =
                                    a.activeOfficialNoticeDialog.getButton(
                                            DialogInterface.BUTTON_POSITIVE);
                            if (okBtn != null) okBtn.performClick();
                        }
                    }
                });
        SystemClock.sleep(250);
        main(
                new Runnable() {
                    public void run() {
                        dismissedAfterOk[0] =
                                a.activeOfficialNoticeDialog == null
                                        || !a.activeOfficialNoticeDialog.isShowing();
                        seenAfterOk[0] =
                                a.getPreferences(0)
                                        .getBoolean(LiteActivity.PREF_OFFICIAL_NOTICE_SEEN, false);
                    }
                });
        check(
                firstLaunchShowing[0]
                        && firstDialogText[0].contains("PILIPALA来信（小红书、B站、抖音、公众号、视频号）")
                        && firstDialogText[0].contains("Marco官网：marcotv.wlj9919.top")
                        && firstDialogText[0].contains(
                                "下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。"),
                "0.5.10-1b: first-launch dialog displays author social handles, official site, and anti-malware notice");
        check(
                dismissedAfterOk[0] && seenAfterOk[0],
                "0.5.10-1c: clicking 我知道了 dismisses first-launch notice and persists seen flag");

        // 2. Subsequent cold launch does NOT show first-launch notice again
        main(
                new Runnable() {
                    public void run() {
                        a.finish();
                    }
                });
        SystemClock.sleep(500);
        a =
                (LiteActivity)
                        startActivitySync(
                                new Intent(getTargetContext(), LiteActivity.class)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        final boolean[] secondLaunchShowing = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        secondLaunchShowing[0] =
                                a.activeOfficialNoticeDialog != null
                                        && a.activeOfficialNoticeDialog.isShowing();
                    }
                });
        check(
                a != null && !secondLaunchShowing[0],
                "0.5.10-2: second launch after acknowledgment does not re-show first-launch notice");

        // 3. Back/cancel dismissal also persists seen; neutral button opens Settings page
        final boolean[] seenAfterCancel = new boolean[1];
        final boolean[] neutralOpenedSettings = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        a.getPreferences(0)
                                .edit()
                                .putBoolean(LiteActivity.PREF_OFFICIAL_NOTICE_SEEN, false)
                                .commit();
                        a.maybeShowFirstLaunchOfficialNotice();
                        if (a.activeOfficialNoticeDialog != null) {
                            a.activeOfficialNoticeDialog.cancel();
                        }
                    }
                });
        SystemClock.sleep(300);
        main(
                new Runnable() {
                    public void run() {
                        seenAfterCancel[0] =
                                a.getPreferences(0)
                                        .getBoolean(LiteActivity.PREF_OFFICIAL_NOTICE_SEEN, false);
                        a.getPreferences(0)
                                .edit()
                                .putBoolean(LiteActivity.PREF_OFFICIAL_NOTICE_SEEN, false)
                                .commit();
                        a.maybeShowFirstLaunchOfficialNotice();
                        if (a.activeOfficialNoticeDialog != null) {
                            android.widget.Button moreBtn =
                                    a.activeOfficialNoticeDialog.getButton(
                                            DialogInterface.BUTTON_NEUTRAL);
                            if (moreBtn != null) moreBtn.performClick();
                        }
                    }
                });
        SystemClock.sleep(300);
        main(
                new Runnable() {
                    public void run() {
                        neutralOpenedSettings[0] =
                                "settings".equals(a.currentPageKind)
                                        && a.getPreferences(0)
                                                .getBoolean(
                                                        LiteActivity.PREF_OFFICIAL_NOTICE_SEEN,
                                                        false);
                    }
                });
        check(
                seenAfterCancel[0] && neutralOpenedSettings[0],
                "0.5.10-3: canceling notice persists seen flag and neutral button navigates to Settings page");

        // 4. Home top header has 设置 pill and home quick bar has 设置与联系反馈; clicking 设置 renders contact & group info
        final boolean[] navAndHomeFound = new boolean[1];
        final String[] settingsPageText = new String[] {""};
        main(
                new Runnable() {
                    public void run() {
                        a.home();
                        View navSettings = findClickableViewContainingText(a.page, "设置");
                        View quickSettings =
                                findClickableViewContainingText(a.page, "设置与联系反馈");
                        navAndHomeFound[0] = navSettings != null && quickSettings != null;
                        if (navSettings != null) navSettings.performClick();
                        StringBuilder sb = new StringBuilder();
                        collectTexts(a.page, sb);
                        settingsPageText[0] = sb.toString();
                    }
                });
        check(
                navAndHomeFound[0]
                        && "settings".equals(a.currentPageKind)
                        && settingsPageText[0].contains("PILIPALA来信（小红书、B站、抖音、公众号、视频号）")
                        && settingsPageText[0].contains("marcotv.wlj9919.top")
                        && settingsPageText[0].contains("https://marcotv.wlj9919.top/movie/#group")
                        && settingsPageText[0].contains(
                                "下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。"),
                "0.5.10-4: Settings page accessible from header & home displays author social handles, website, group link, and notice");

        // 5. Clicking 官网交流群链接 opens QR + URL dialog cleanly; clicking 查看首次启动官方声明 opens notice dialog cleanly
        final boolean[] groupDialogOk = new boolean[1];
        final boolean[] reopenNoticeOk = new boolean[1];
        main(
                new Runnable() {
                    public void run() {
                        View groupBtn =
                                findClickableViewContainingText(a.page, "官网交流群链接");
                        if (groupBtn != null) groupBtn.performClick();
                        if (a.activeOfficialNoticeDialog != null
                                && a.activeOfficialNoticeDialog.isShowing()) {
                            View decor = a.activeOfficialNoticeDialog.getWindow().getDecorView();
                            StringBuilder sb = new StringBuilder();
                            collectTexts(decor, sb);
                            groupDialogOk[0] =
                                    containsImageView(decor)
                                            && sb.toString()
                                                    .contains(
                                                            "https://marcotv.wlj9919.top/movie/#group");
                            a.dismissActiveOfficialNoticeDialog();
                        }

                        View noticeBtn =
                                findClickableViewContainingText(a.page, "查看首次启动官方声明");
                        if (noticeBtn != null) noticeBtn.performClick();
                        if (a.activeOfficialNoticeDialog != null
                                && a.activeOfficialNoticeDialog.isShowing()) {
                            StringBuilder sb = new StringBuilder();
                            collectTexts(
                                    a.activeOfficialNoticeDialog.getWindow().getDecorView(), sb);
                            reopenNoticeOk[0] =
                                    sb.toString().contains("PILIPALA来信")
                                            && sb.toString().contains("marcotv.wlj9919.top");
                            a.home();
                        }
                    }
                });
        check(
                groupDialogOk[0]
                        && reopenNoticeOk[0]
                        && a.activeOfficialNoticeDialog == null,
                "0.5.10-5: Settings 官网交流群链接 shows QR+URL dialog and 查看首次启动官方声明 reopens and cleans up cleanly");
    }
}

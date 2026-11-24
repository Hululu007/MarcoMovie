// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.View;
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
                newChecksCount = count - baselineCount;
            }

            String summary =
                    "PASS "
                            + baselineCount
                            + " API14 checks"
                            + (extended
                                    ? (" + "
                                            + newChecksCount
                                            + " new 0.5.9 E2E checks (total "
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
}

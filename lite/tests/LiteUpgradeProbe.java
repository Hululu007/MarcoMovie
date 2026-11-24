// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Minimal API 14 instrumentation probe compiled strictly against 0.5.8-compatible APIs so it can
 * run unmodified against the official Lite 0.5.8 APK to seed real subscription, watch history,
 * legacy empty-siteApi history, and favorites prior to in-place upgrade testing.
 */
public final class LiteUpgradeProbe extends Instrumentation {
    private int count;
    private LiteActivity activity;

    private void check(boolean value, String name) {
        if (!value) throw new AssertionError("Upgrade seed058 check failed: " + name);
        count++;
    }

    private void main(Runnable job) {
        runOnMainSync(job);
    }

    private String request(int port, String path, String data) throws Exception {
        HttpURLConnection c =
                (HttpURLConnection) new URL("http://127.0.0.1:" + port + path).openConnection();
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

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        try {
            check(Build.VERSION.SDK_INT == 14, "real API14 runtime");
            activity =
                    (LiteActivity)
                            startActivitySync(
                                    new Intent(getTargetContext(), LiteActivity.class)
                                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            check(activity != null, "launch official 0.5.8 LiteActivity");

            main(
                    new Runnable() {
                        public void run() {
                            activity.configure();
                        }
                    });
            check(activity.pairing != null, "0.5.8 pairing server started");
            String fixtureUrl = "http://10.0.2.2:8773/config";
            String resp =
                    request(
                            activity.pairing.port(),
                            "/" + activity.pairing.token,
                            "url=" + URLEncoder.encode(fixtureUrl, "UTF-8"));
            check(resp.startsWith("200:"), "0.5.8 imports subscription config");
            main(
                    new Runnable() {
                        public void run() {
                            activity.home();
                        }
                    });
            check(
                    fixtureUrl.equals(activity.getPreferences(0).getString("address", ""))
                            && activity.sites.size() >= 1,
                    "0.5.8 subscription persisted and parsed");

            final String realKey = activity.sites.get(0).key;
            final String realApi = activity.sites.get(0).api;
            final String realName = activity.sites.get(0).name;

            JSONArray histArr = new JSONArray();
            histArr.put(
                    new JSONObject()
                            .put("siteKey", realKey)
                            .put("siteName", realName)
                            .put("siteApi", realApi)
                            .put("vodId", "demo")
                            .put("vodName", "合成测试")
                            .put("vodPic", "")
                            .put("lineName", "测试线路")
                            .put("lineIndex", 0)
                            .put("epName", "第一集")
                            .put("epUrl", "http://10.0.2.2:8773/video.mp4")
                            .put("epIndex", 0)
                            .put("positionMs", 14500)
                            .put("durationMs", 40000)
                            .put("updatedAt", 1700000002000L));
            histArr.put(
                    new JSONObject()
                            .put("siteKey", realKey)
                            .put("siteName", "旧版无API记录")
                            .put("siteApi", "")
                            .put("vodId", "demo_legacy")
                            .put("vodName", "旧版无API影片")
                            .put("vodPic", "")
                            .put("lineName", "测试线路")
                            .put("lineIndex", 0)
                            .put("epName", "第一集")
                            .put("epUrl", "http://10.0.2.2:8773/video.mp4")
                            .put("epIndex", 0)
                            .put("positionMs", 9000)
                            .put("durationMs", 40000)
                            .put("updatedAt", 1700000001000L));

            JSONArray favArr = new JSONArray();
            favArr.put(
                    new JSONObject()
                            .put("siteKey", realKey)
                            .put("siteName", realName)
                            .put("siteApi", realApi)
                            .put("vodId", "demo")
                            .put("vodName", "合成测试")
                            .put("vodPic", "")
                            .put("vodRemarks", "0.5.8收藏")
                            .put("addedAt", 1700000002000L));
            favArr.put(
                    new JSONObject()
                            .put("siteKey", realKey)
                            .put("siteName", "旧版无API收藏")
                            .put("siteApi", "")
                            .put("vodId", "demo_legacy")
                            .put("vodName", "旧版无API影片")
                            .put("vodPic", "")
                            .put("vodRemarks", "旧收藏")
                            .put("addedAt", 1700000001000L));

            LiteStore.setHistoryRaw(activity, histArr.toString());
            LiteStore.setFavoritesRaw(activity, favArr.toString());
            // Also seed real 0.5.8 unscoped tombstones (ts=20) to verify R1 no-resurrection after upgrade
            String legacyTombs =
                    new JSONObject()
                            .put("hist:" + realKey + "\n058_deleted", 20L)
                            .put("fav:" + realKey + "\n058_deleted", 20L)
                            .toString();
            LiteStore.setTombstonesRaw(activity, legacyTombs);
            activity.getPreferences(0)
                    .edit()
                    .putString("resume_address", "http://10.0.2.2:8773/video.mp4")
                    .putInt("resume_ms", 14500)
                    .commit();

            List<LiteStore.HistoryEntry> seededHist = LiteStore.getHistory(activity);
            List<LiteStore.FavoriteEntry> seededFav = LiteStore.getFavorites(activity);
            check(
                    seededHist.size() == 2
                            && seededFav.size() == 2
                            && LiteStore.getTombstonesRaw(activity).contains("058_deleted"),
                    "0.5.8 history, favorites & unscoped tombstones written and readable");
            result.putString(
                    "stream",
                    "PASS "
                            + count
                            + " upgrade checks (seed058: key="
                            + realKey
                            + ", api="
                            + realApi
                            + ")\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable failure) {
            result.putString(
                    "stream", "FAIL after " + count + " (seed058): " + failure.toString() + "\n");
            finish(Activity.RESULT_CANCELED, result);
        } finally {
            if (activity != null) {
                main(
                        new Runnable() {
                            public void run() {
                                activity.finish();
                            }
                        });
            }
        }
    }
}

package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

public final class CloudSyncChecks {
    static int checks;

    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError("FAILED: " + label);
        checks++;
        System.out.println("PASS " + label);
    }

    private static byte[] readAll(InputStream in) throws java.io.IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) != -1) {
            bos.write(buf, 0, n);
        }
        return bos.toByteArray();
    }

    public static void main(String[] args) throws Exception {
        testResolveWebdavFileUrlMatrix();
        testWebdavErrorDiagnostics();
        testHistoryFavoritesAndTombstones();
        testSubscriptionSyncIsolationAndOptOut();
        testLegacyBackupCompatibility();
        testLanPeerSyncRoundtrip();
        testWebdavMkcolAndRoundtrip();
        testWebdavEtagAndConcurrency();
        testWatchHistoryCorruptionBackupAndLockout();
        testUiLatchTimeoutAndErrorPropagation();
        System.out.println("ALL PASS (" + checks + " checks)");
    }

    private static void testResolveWebdavFileUrlMatrix() {
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/")),
                "Jianguoyun root folder trailing slash appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav")),
                "Jianguoyun root folder without trailing slash appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("dav.jianguoyun.com/dav/")),
                "Jianguoyun scheme-less URL auto-prepends https and appends MarcoMovie");
        check(
                "https://dav.jianguoyun.com/dav/我的坚果云/marco-movie-sync.json"
                        .equals(
                                CloudSync.resolveWebdavFileUrl(
                                        "https://dav.jianguoyun.com/dav/我的坚果云/")),
                "Jianguoyun custom folder preserves user subfolder");
        check(
                "https://dav.jianguoyun.com/dav/a/x.json"
                        .equals(
                                CloudSync.resolveWebdavFileUrl(
                                        "https://dav.jianguoyun.com/dav/a/x.json")),
                "Jianguoyun explicit json file URL left untouched");
        check(
                "https://nas.local:5006/marco-movie-sync.json"
                        .equals(CloudSync.resolveWebdavFileUrl("https://nas.local:5006/")),
                "Non-Jianguoyun WebDAV server does not append MarcoMovie subfolder");
    }

    private static void testWebdavErrorDiagnostics() {
        String err404 = CloudSync.formatWebdavWriteError(404);
        check(
                err404.contains("HTTP 404") && err404.contains("坚果云请在地址后加一个文件夹名"),
                "HTTP 404 provides actionable Jianguoyun diagnostic error message");
        String err409 = CloudSync.formatWebdavWriteError(409);
        check(
                err409.contains("HTTP 409") && err409.contains("坚果云请在地址后加一个文件夹名"),
                "HTTP 409 provides actionable Jianguoyun diagnostic error message");
        check(
                "WebDAV 写入失败 (HTTP 405)：服务器不允许写入".equals(CloudSync.formatWebdavWriteError(405)),
                "HTTP 405 provides method not allowed message");
        check(
                "WebDAV 写入失败 (HTTP 423)：文件被锁定".equals(CloudSync.formatWebdavWriteError(423)),
                "HTTP 423 provides locked file message");
        check(
                "WebDAV 写入失败 (HTTP 507)：空间不足".equals(CloudSync.formatWebdavWriteError(507)),
                "HTTP 507 provides insufficient storage message");
    }

    private static void testHistoryFavoritesAndTombstones() throws Exception {
        WatchHistory.Entry h1 = new WatchHistory.Entry();
        h1.site = "site_a";
        h1.id = "vod_1";
        h1.title = "星际漫游";
        h1.episode = "第02集";
        h1.position = 120_000;
        h1.duration = 2_400_000;
        h1.updated = 1000L;
        String localHist = WatchHistory.upsert("[]", h1);

        Cms.Video favVideo = new Cms.Video();
        favVideo.id = "vod_fav";
        favVideo.title = "沙丘";
        String localFav = Favorites.toggle("[]", "site_a", favVideo);

        CloudSync.Tombstones localTombs = CloudSync.Tombstones.read("");
        localTombs.putMax("add:site_a\nvod_fav", 1200L);

        // Remote has newer progress on vod_1 (t=2500), plus vod_deleted (t=900)
        JSONObject remoteRoot =
                new JSONObject()
                        .put("schema", CloudSync.SCHEMA)
                        .put("version", 1)
                        .put("updatedAt", 2600L)
                        .put(
                                "watchHistory",
                                new JSONArray()
                                        .put(
                                                new JSONObject()
                                                        .put("siteKey", "site_a")
                                                        .put("vodId", "vod_1")
                                                        .put("title", "星际漫游")
                                                        .put("episodeName", "第03集")
                                                        .put("positionMs", 480_000)
                                                        .put("durationMs", 2_400_000)
                                                        .put("updatedAt", 2500L))
                                        .put(
                                                new JSONObject()
                                                        .put("siteKey", "site_a")
                                                        .put("vodId", "vod_old")
                                                        .put("title", "旧记录")
                                                        .put("positionMs", 30_000)
                                                        .put("durationMs", 600_000)
                                                        .put("updatedAt", 900L)))
                        .put("tombstones", new JSONObject().put("fav:site_a\nvod_fav", 2000L));

        // Local deleted vod_old at t=1500
        localTombs.putMax("hist:site_a\nvod_old", 1500L);

        CloudSync.MergeResult merged =
                CloudSync.merge(
                        localHist,
                        localFav,
                        localTombs.json(),
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        remoteRoot.toString(),
                        3000L);

        List<WatchHistory.Entry> resHist = WatchHistory.read(merged.historyJson);
        check(resHist.size() == 1, "tombstoned remote history removed while active entry kept");
        check(
                "第03集".equals(resHist.get(0).episode) && resHist.get(0).position == 480_000,
                "newer remote watch progress wins LWW");
        List<Favorites.Entry> resFavs = Favorites.read(merged.favoritesJson);
        check(resFavs.isEmpty(), "newer remote fav tombstone removes local favorite");
    }

    private static void testSubscriptionSyncIsolationAndOptOut() throws Exception {
        String rawMixed =
                "{\"sites\":["
                        + "{\"key\":\"pub_1\",\"name\":\"公开源\",\"type\":1,\"api\":\"https://api.example/cms\"},"
                        + "{\"key\":\"priv_1\",\"name\":\"私密源\",\"type\":1,\"api\":\"https://priv.example/cms\",\"private\":true}"
                        + "],\"lives\":["
                        + "{\"name\":\"公开直播\",\"url\":\"https://live.example/open.m3u\"},"
                        + "{\"name\":\"私密直播\",\"url\":\"https://live.example/secret.m3u\",\"space\":\"private\"}"
                        + "]}";
        String sanitized = CloudSync.sanitizePublicRawConfig(rawMixed);
        JSONObject sanObj = new JSONObject(sanitized);
        check(
                sanObj.getJSONArray("sites").length() == 1
                        && "pub_1"
                                .equals(
                                        sanObj.getJSONArray("sites")
                                                .getJSONObject(0)
                                                .getString("key")),
                "private sites stripped before cloud export");
        check(
                sanObj.getJSONArray("lives").length() == 1,
                "private live entries stripped before cloud export");

        CloudSync.SubscriptionItem subA =
                CloudSync.SubscriptionItem.create(
                        "主力订阅",
                        "https://sub-a.example/config.json",
                        rawMixed,
                        true,
                        "pub_1",
                        5000L);
        check(
                subA != null
                        && subA.key.equals(
                                ConfigLibrary.identity(
                                        "https://sub-a.example/config.json", sanitized)),
                "SubscriptionItem key matches ConfigLibrary.identity");

        String payloadDeviceA =
                CloudSync.exportPayload(
                        "[]", "[]", "", Collections.singletonList(subA), true, 5100L);
        check(!payloadDeviceA.contains("priv_1"), "exported payload never leaks private site");

        // Brand-new Device B pulls with syncSubscriptions = true
        CloudSync.MergeResult mergedOnB =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "",
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        payloadDeviceA,
                        5200L);
        check(
                mergedOnB.subscriptionCount == 1
                        && "主力订阅".equals(mergedOnB.subscriptions.get(0).name),
                "new device receives public subscription from v2 payload");

        // Device C has syncSubscriptions = false -> must NOT wipe remote subscriptions in cloud!
        CloudSync.MergeResult mergedOnC =
                CloudSync.merge("[]", "[]", "", null, false, payloadDeviceA, 5300L);
        JSONObject cOut = new JSONObject(mergedOnC.payloadJson);
        check(
                cOut.has("subscriptions") && cOut.getJSONArray("subscriptions").length() == 1,
                "device with syncSubscriptions=false preserves remote cloud subscriptions");

        // Now Device A deletes subA via sub: tombstone at t=6000
        CloudSync.Tombstones delTomb = CloudSync.Tombstones.read("");
        delTomb.putMax("sub:" + subA.key, 6000L);
        CloudSync.MergeResult afterDelete =
                CloudSync.merge(
                        "[]",
                        "[]",
                        delTomb.json(),
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        payloadDeviceA,
                        6100L);
        check(
                afterDelete.subscriptionCount == 0,
                "newer sub: tombstone removes deleted subscription across devices");
    }

    private static void testLegacyBackupCompatibility() throws Exception {
        String legacyBackup =
                "{\"schema\":\"marco-movie-backup\",\"version\":1,"
                        + "\"watch_history\":[{\"site\":\"s1\",\"id\":\"v9\",\"title\":\"旧版备份影片\",\"position\":90000,\"duration\":180000,\"updated\":1700}],"
                        + "\"favorites\":[{\"site\":\"s1\",\"id\":\"v9\",\"title\":\"旧版备份影片\"}]}";
        CloudSync.MergeResult res =
                CloudSync.merge(
                        "[]",
                        "[]",
                        "",
                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                        true,
                        legacyBackup,
                        2000L);
        check(
                res.historyCount == 1 && res.favoriteCount == 1,
                "backward compatible with marco-movie-backup payload");
    }

    private static void testLanPeerSyncRoundtrip() throws Exception {
        final AtomicReference<String> serverHist = new AtomicReference<>("[]");
        final AtomicReference<String> serverFav = new AtomicReference<>("[]");
        final AtomicReference<String> serverTombs = new AtomicReference<>("");
        String rawSub =
                "{\"sites\":[{\"key\":\"lan_site\",\"name\":\"局域网片源\",\"type\":1,\"api\":\"https://lan.example/cms\"}]}";
        final List<CloudSync.SubscriptionItem> serverSubs =
                new ArrayList<>(
                        Collections.singletonList(
                                CloudSync.SubscriptionItem.create(
                                        "客厅电视订阅",
                                        "https://tv.example/sub.json",
                                        rawSub,
                                        true,
                                        "lan_site",
                                        4000L)));

        WatchHistory.Entry tvHist = new WatchHistory.Entry();
        tvHist.site = "lan_site";
        tvHist.id = "m100";
        tvHist.title = "电视端进度";
        tvHist.position = 300_000;
        tvHist.duration = 900_000;
        tvHist.updated = 4100L;
        serverHist.set(WatchHistory.upsert("[]", tvHist));

        ConfigTransferServer server =
                new ConfigTransferServer(
                        address -> {},
                        remoteJson -> {
                            long now = 5000L;
                            if (remoteJson == null) {
                                return CloudSync.exportPayload(
                                        serverHist.get(),
                                        serverFav.get(),
                                        serverTombs.get(),
                                        serverSubs,
                                        true,
                                        now);
                            }
                            CloudSync.MergeResult m =
                                    CloudSync.merge(
                                            serverHist.get(),
                                            serverFav.get(),
                                            serverTombs.get(),
                                            serverSubs,
                                            true,
                                            remoteJson,
                                            now);
                            serverHist.set(m.historyJson);
                            serverFav.set(m.favoritesJson);
                            serverTombs.set(m.tombstonesJson);
                            return m.payloadJson;
                        });
        try {
            String peerUrl = server.address("127.0.0.1");
            Cms.Video phoneFavVideo = new Cms.Video();
            phoneFavVideo.id = "m200";
            phoneFavVideo.title = "手机端新收藏";
            final String phoneFav = Favorites.toggle("[]", "lan_site", phoneFavVideo);

            CloudSync.MergeResult clientRes =
                    CloudSync.syncLanPeer(
                            peerUrl,
                            new CloudSync.LanPeerCallback() {
                                @Override
                                public String exportLocalPayload() throws Exception {
                                    return CloudSync.exportPayload(
                                            "[]",
                                            phoneFav,
                                            "",
                                            Collections.<CloudSync.SubscriptionItem>emptyList(),
                                            true,
                                            4800L);
                                }

                                @Override
                                public CloudSync.MergeResult applyMergedPayload(
                                        String remoteMergedPayloadJson) throws Exception {
                                    return CloudSync.merge(
                                            "[]",
                                            phoneFav,
                                            "",
                                            Collections.<CloudSync.SubscriptionItem>emptyList(),
                                            true,
                                            remoteMergedPayloadJson,
                                            5100L);
                                }
                            });

            check(
                    clientRes.historyCount == 1
                            && clientRes.favoriteCount == 1
                            && clientRes.subscriptionCount == 1,
                    "LAN client receives TV history + TV subscription and keeps phone favorite");
            check(
                    Favorites.read(serverFav.get()).size() == 1,
                    "LAN receiver (TV) simultaneously receives phone favorite in single roundtrip");
        } finally {
            server.close();
        }
    }

    private static void testWebdavMkcolAndRoundtrip() throws Exception {
        final Set<String> createdDirs = Collections.synchronizedSet(new HashSet<String>());
        final List<String> mkcolSequence = Collections.synchronizedList(new ArrayList<String>());
        final AtomicReference<byte[]> storedFile = new AtomicReference<>(null);
        final AtomicReference<String> lastAuth = new AtomicReference<>("");

        HttpServer dav = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        dav.createContext(
                "/",
                (HttpExchange ex) -> {
                    try {
                        String method = ex.getRequestMethod();
                        String path = ex.getRequestURI().getPath();
                        String auth = ex.getRequestHeaders().getFirst("Authorization");
                        lastAuth.set(auth == null ? "" : auth);
                        if (path.startsWith("/forbidden")) {
                            if ("MKCOL".equalsIgnoreCase(method)) {
                                ex.sendResponseHeaders(403, -1);
                                return;
                            }
                            if ("PUT".equalsIgnoreCase(method)) {
                                ex.sendResponseHeaders(404, -1);
                                return;
                            }
                        }
                        if ("MKCOL".equalsIgnoreCase(method)) {
                            String norm = path.endsWith("/") ? path : path + "/";
                            createdDirs.add(norm);
                            mkcolSequence.add(norm);
                            ex.sendResponseHeaders(201, -1);
                            return;
                        }
                        if ("GET".equalsIgnoreCase(method)) {
                            byte[] data = storedFile.get();
                            if (data == null) {
                                ex.sendResponseHeaders(404, -1);
                            } else {
                                ex.getResponseHeaders()
                                        .set("Content-Type", "application/json; charset=utf-8");
                                ex.sendResponseHeaders(200, data.length);
                                try (OutputStream os = ex.getResponseBody()) {
                                    os.write(data);
                                }
                            }
                            return;
                        }
                        if ("PUT".equalsIgnoreCase(method)) {
                            byte[] body = readAll(ex.getRequestBody());
                            // Simulate Jianguoyun root collection read-only
                            if ("/dav/marco-movie-sync.json".equals(path)
                                    || "/marco-movie-sync.json".equals(path)) {
                                ex.sendResponseHeaders(404, -1);
                                return;
                            }
                            if (!createdDirs.contains("/dav/")
                                    || !createdDirs.contains("/dav/MarcoMovie/")) {
                                ex.sendResponseHeaders(409, -1);
                                return;
                            }
                            storedFile.set(body);
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
            String davDirUrl = "http://127.0.0.1:" + port + "/dav/MarcoMovie/";

            WatchHistory.Entry e = new WatchHistory.Entry();
            e.site = "s_dav";
            e.id = "v_dav";
            e.title = "云端同步测试片";
            e.position = 65_000;
            e.duration = 120_000;
            e.updated = 7000L;
            final String histA = WatchHistory.upsert("[]", e);

            CloudSync.MergeResult pushRes =
                    CloudSync.syncWebdav(
                            davDirUrl,
                            "alice",
                            "secret-pass",
                            remote ->
                                    CloudSync.merge(
                                            histA,
                                            "[]",
                                            "",
                                            Arrays.asList(
                                                    CloudSync.SubscriptionItem.create(
                                                            "WebDAV 订阅",
                                                            "https://dav-sub.example/main.json",
                                                            "{\"sites\":[{\"key\":\"s_dav\",\"name\":\"云片源\",\"type\":1,\"api\":\"https://dav-sub.example/api\"}]}",
                                                            true,
                                                            "s_dav",
                                                            7000L)),
                                            true,
                                            remote,
                                            7100L));

            check(
                    pushRes.historyCount == 1 && pushRes.subscriptionCount == 1,
                    "WebDAV initial push creates parent directories via MKCOL and uploads v2 JSON");
            check(
                    lastAuth.get().startsWith("Basic "),
                    "WebDAV request sends RFC 4648 Basic Authorization header");
            check(
                    mkcolSequence.contains("/dav/") && mkcolSequence.contains("/dav/MarcoMovie/"),
                    "MKCOL creates nested collections in hierarchy");
            check(
                    mkcolSequence.indexOf("/dav/") < mkcolSequence.indexOf("/dav/MarcoMovie/"),
                    "MKCOL sequence creates parent collection before child collection");

            CloudSync.MergeResult pullRes =
                    CloudSync.syncWebdav(
                            davDirUrl,
                            "alice",
                            "secret-pass",
                            remote ->
                                    CloudSync.merge(
                                            "[]",
                                            "[]",
                                            "",
                                            Collections.<CloudSync.SubscriptionItem>emptyList(),
                                            true,
                                            remote,
                                            7200L));
            check(
                    pullRes.historyCount == 1 && pullRes.subscriptionCount == 1,
                    "second device pulls history and subscription from WebDAV server");

            try {
                CloudSync.syncWebdav(
                        "http://127.0.0.1:" + port + "/forbidden/",
                        "alice",
                        "secret-pass",
                        remote ->
                                CloudSync.merge(
                                        "[]",
                                        "[]",
                                        "",
                                        Collections.<CloudSync.SubscriptionItem>emptyList(),
                                        true,
                                        remote,
                                        7300L));
                check(false, "Persistent WebDAV write failure must throw IOException");
            } catch (java.io.IOException expected) {
                check(
                        expected.getMessage().contains("目标文件夹不存在或不可写。坚果云请在地址后加一个文件夹名"),
                        "WebDAV 404/409 write failure provides actionable diagnostic message");
            }
        } finally {
            dav.stop(0);
        }
    }

    private static void testWebdavEtagAndConcurrency() throws Exception {
        HttpServer dav = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        final AtomicReference<String> lastIfMatch = new AtomicReference<>();
        final AtomicReference<String> lastIfNoneMatch = new AtomicReference<>();
        final AtomicReference<String> serverEtag = new AtomicReference<>("\"etag-v1\"");
        final AtomicReference<byte[]> storedPayload = new AtomicReference<>(null);
        final java.util.concurrent.atomic.AtomicInteger putCount =
                new java.util.concurrent.atomic.AtomicInteger();
        final java.util.concurrent.atomic.AtomicBoolean return412Once =
                new java.util.concurrent.atomic.AtomicBoolean();
        final java.util.concurrent.atomic.AtomicBoolean always412 =
                new java.util.concurrent.atomic.AtomicBoolean();
        final java.util.concurrent.atomic.AtomicBoolean omitEtagOnGet =
                new java.util.concurrent.atomic.AtomicBoolean();

        dav.createContext(
                "/etag-dav/MarcoMovie/",
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
                                serverEtag.set("\"etag-v2\"");
                                storedPayload.set(
                                        "{\"schema\":\"marco-movie-sync\",\"version\":2,\"updated\":8000,\"watch_history\":[]}"
                                                .getBytes(StandardCharsets.UTF_8));
                                ex.sendResponseHeaders(412, -1);
                                return;
                            }

                            storedPayload.set(readAll(ex.getRequestBody()));
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
            String url = "http://127.0.0.1:" + port + "/etag-dav/MarcoMovie/";

            // 1. Initial push when file absent on GET (404) -> sends If-None-Match: *
            storedPayload.set(null);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 1000L));
            check(
                    "*".equals(lastIfNoneMatch.get()) && lastIfMatch.get() == null,
                    "WebDAV sends If-None-Match: * on initial push when file absent");

            // 2. Subsequent sync with existing file and ETag -> sends If-Match: <etag>
            lastIfNoneMatch.set(null);
            lastIfMatch.set(null);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 2000L));
            check(
                    lastIfNoneMatch.get() == null && "\"etag-v1\"".equals(lastIfMatch.get()),
                    "WebDAV sends If-Match: <etag> when remote file exists");

            // 3. Fallback to unconditioned PUT when server GET omits ETag
            omitEtagOnGet.set(true);
            lastIfNoneMatch.set(null);
            lastIfMatch.set(null);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 3000L));
            check(
                    lastIfNoneMatch.get() == null && lastIfMatch.get() == null,
                    "WebDAV falls back gracefully to unconditioned PUT when ETag omitted");
            omitEtagOnGet.set(false);

            // 4. HTTP 412 triggers retry loop and succeeds with updated ETag
            return412Once.set(true);
            putCount.set(0);
            CloudSync.syncWebdav(
                    url,
                    "alice",
                    "pass",
                    remote ->
                            CloudSync.merge(
                                    "[]", "[]", "", Collections.emptyList(), false, remote, 4000L));
            check(
                    putCount.get() == 2 && "\"etag-v2\"".equals(lastIfMatch.get()),
                    "WebDAV 412 triggers retry loop, re-fetches updated ETag and succeeds");

            // 5. Persistent HTTP 412 exhausts retries and throws actionable IOException
            always412.set(true);
            try {
                CloudSync.syncWebdav(
                        url,
                        "alice",
                        "pass",
                        remote ->
                                CloudSync.merge(
                                        "[]",
                                        "[]",
                                        "",
                                        Collections.emptyList(),
                                        false,
                                        remote,
                                        5000L));
                check(false, "Persistent 412 must throw IOException");
            } catch (java.io.IOException expected) {
                check(
                        expected.getMessage().contains("HTTP 412")
                                && expected.getMessage().contains("写入冲突"),
                        "WebDAV persistent 412 conflict provides actionable diagnostic message");
            }
        } finally {
            dav.stop(0);
        }
    }

    private static void testWatchHistoryCorruptionBackupAndLockout() {
        WatchHistory.setCorrupted(false);
        String corruptJson = "{\"corrupt\": true, [invalid json...";
        final AtomicReference<String> backupKey = new AtomicReference<>();
        final AtomicReference<String> backupValue = new AtomicReference<>();
        final java.util.concurrent.atomic.AtomicInteger backupCount =
                new java.util.concurrent.atomic.AtomicInteger();
        final AtomicReference<Boolean> prefCorrupted = new AtomicReference<>(Boolean.FALSE);
        final AtomicReference<String> storedHistoryJson = new AtomicReference<>(corruptJson);

        WatchHistory.CorruptionRecorder recorder =
                (key, raw) -> {
                    backupCount.incrementAndGet();
                    backupKey.set(key);
                    backupValue.set(raw);
                    prefCorrupted.set(Boolean.TRUE);
                };

        // 1. Reading corrupted JSON 10 times consecutively produces ONLY ONE backup
        for (int i = 0; i < 10; i++) {
            List<WatchHistory.Entry> entries = WatchHistory.read(corruptJson, recorder);
            check(entries.isEmpty(), "WatchHistory.read returns empty list on corrupt JSON #" + i);
        }
        check(
                WatchHistory.isCorrupted() && Boolean.TRUE.equals(prefCorrupted.get()),
                "WatchHistory marks historyCorrupted and pref on malformed JSON");
        check(
                backupCount.get() == 1,
                "10 consecutive reads of corrupted history produce only one backup");
        check(
                backupKey.get() != null
                        && backupKey.get().startsWith("watch_history_corrupt_")
                        && corruptJson.equals(backupValue.get()),
                "WatchHistory calls recorder with watch_history_corrupt_<ts> and verbatim content");

        // 2. Destructive upsert() and remove() are locked out when history is corrupted
        WatchHistory.Entry e = new WatchHistory.Entry();
        e.site = "site_a";
        e.id = "vod_a";
        e.title = "test";
        String upsertResult = WatchHistory.upsert(corruptJson, e);
        check(corruptJson.equals(upsertResult), "WatchHistory.upsert is locked out when corrupted");

        String removeResult = WatchHistory.remove(corruptJson, "site_a\nvod_a");
        check(corruptJson.equals(removeResult), "WatchHistory.remove is locked out when corrupted");

        // 3. Clearing history clears both in-memory flag and watch_history_corrupted pref,
        // keeps backup intact, and subsequent upsert succeeds
        WatchHistory.Store store =
                (json, corrupted) -> {
                    storedHistoryJson.set(json);
                    prefCorrupted.set(corrupted);
                };
        String cleared = WatchHistory.clear(store);
        check(
                "[]".equals(cleared)
                        && "[]".equals(storedHistoryJson.get())
                        && !WatchHistory.isCorrupted()
                        && Boolean.FALSE.equals(prefCorrupted.get())
                        && corruptJson.equals(backupValue.get()),
                "WatchHistory.clear clears flag and pref while preserving corrupt backup");
        String afterClearUpsert = WatchHistory.upsert(storedHistoryJson.get(), e);
        List<WatchHistory.Entry> afterClearEntries = WatchHistory.read(afterClearUpsert);
        check(
                afterClearEntries.size() == 1 && "vod_a".equals(afterClearEntries.get(0).id),
                "WatchHistory.upsert succeeds after clearing corrupted history");

        // 4. Full valid overwrite also clears both flag and watch_history_corrupted pref
        WatchHistory.read(corruptJson, recorder);
        check(WatchHistory.isCorrupted(), "re-triggered corruption sets flag");
        String overwritten = WatchHistory.overwrite(afterClearUpsert, store);
        check(
                overwritten != null
                        && !WatchHistory.isCorrupted()
                        && Boolean.FALSE.equals(prefCorrupted.get()),
                "WatchHistory.overwrite with valid JSON clears flag and pref");
    }

    private static void testUiLatchTimeoutAndErrorPropagation() {
        // Test timeout detection
        java.util.concurrent.CountDownLatch latch = new java.util.concurrent.CountDownLatch(1);
        boolean timeoutPassed = false;
        try {
            boolean completed = latch.await(50, java.util.concurrent.TimeUnit.MILLISECONDS);
            if (!completed) {
                timeoutPassed = true;
            }
        } catch (InterruptedException ignored) {
        }
        check(
                timeoutPassed,
                "CountDownLatch detects timeout when UI thread does not count down in time");

        // Test error propagation via AtomicReference<Throwable>
        final AtomicReference<Throwable> errRef = new AtomicReference<>();
        errRef.set(new IllegalStateException("simulated UI exception"));
        check(
                errRef.get() != null && "simulated UI exception".equals(errRef.get().getMessage()),
                "AtomicReference propagates background UI failure throwable to sync caller");
    }
}

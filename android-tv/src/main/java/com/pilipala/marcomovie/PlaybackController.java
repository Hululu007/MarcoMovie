package com.pilipala.marcomovie;

import android.graphics.Color;
import android.net.Uri;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import com.pilipala.marcomovie.hud.EpisodeHoldSwitchOverlay;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/**
 * Playback resolution (direct, plugin/JS player, web resolver, magnet stream), player page
 * lifecycle, mini-player transitions, remote seek gesture, control overlay auto-hide, and watch
 * history bookmark persistence extracted from {@link MainActivity}.
 */
final class PlaybackController {
    private static final ExecutorService PLAYER_RESOLVE =
            createBoundedDaemonPool(6, "player-resolve");
    private static final ExecutorService PLAYER_INIT = createBoundedDaemonPool(1, "player-init");

    private static ExecutorService createBoundedDaemonPool(int maxThreads, final String name) {
        java.util.concurrent.ThreadPoolExecutor pool =
                new java.util.concurrent.ThreadPoolExecutor(
                        maxThreads,
                        maxThreads,
                        25L,
                        java.util.concurrent.TimeUnit.SECONDS,
                        new java.util.concurrent.LinkedBlockingQueue<Runnable>(),
                        r -> {
                            Thread t = new Thread(r, name);
                            t.setDaemon(true);
                            return t;
                        });
        pool.allowCoreThreadTimeOut(true);
        return pool;
    }

    static final ExecutorService STORAGE_EXECUTOR = WatchHistory.STORAGE_EXECUTOR;
    private static final long DISK_SAVE_INTERVAL_MS = 15000L;

    private PlaybackController() {}

    static WatchHistory.Entry cloneBookmark(WatchHistory.Entry src) {
        return WatchHistory.cloneEntry(src);
    }

    static void updateInMemoryBookmark(MainActivity a) {
        if (a.player == null || !a.prepared || a.playingBookmark == null) return;
        try {
            int rawPos = a.player.getCurrentPosition();
            int position =
                    a.playbackControls != null
                            ? a.playbackControls.displayPosition(rawPos)
                            : rawPos;
            if (a.playbackControls != null
                    && a.playbackControls.pendingResumeMs > 0
                    && position < 2000) {
                position = a.playbackControls.pendingResumeMs;
            }
            if (position < 1000 && a.playingBookmark.position >= 1000) {
                position = a.playingBookmark.position;
            }
            a.playingBookmark.position = Math.max(0, position);
            int dur = a.player.getDuration();
            if (dur > 0) {
                a.playingBookmark.duration = dur;
            }
            a.playingBookmark.updated = System.currentTimeMillis();
        } catch (Exception ignored) {
        }
    }

    static String formatTime(int ms) {
        int sec = Math.max(0, ms / 1000);
        int h = sec / 3600;
        int m = (sec / 60) % 60;
        int s = sec % 60;
        StringBuilder sb = new StringBuilder(8);
        if (h > 0) {
            sb.append(h).append(':');
        }
        if (m < 10) sb.append('0');
        sb.append(m).append(':');
        if (s < 10) sb.append('0');
        sb.append(s);
        return sb.toString();
    }

    static void stopMagnet(MainActivity a) {
        if (a.magnetStream != null) {
            a.magnetStream.close();
            a.magnetStream = null;
        }
    }

    static void stopWeb(MainActivity a) {
        if (a.webResolver != null) {
            a.webResolver.stop();
            a.webResolver = null;
        }
    }

    static void resolveWebPage(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode ep, String prefix) {
        String address = (prefix == null ? "" : prefix) + ep.url;
        if (!Cms.isHttp(address)) {
            a.changingMiniEpisode = false;
            clearPlaybackLoading(a);
            failInPlaceSwitch(a, "解析页面地址不受支持。");
            return;
        }
        final int ticket = a.generation;
        final int serial = a.playbackResolveSerial;
        try {
            List<Cms.SniffRule> sniffRules =
                    a.config != null ? a.config.rules : java.util.Collections.emptyList();
            List<String> adHosts =
                    a.config != null ? a.config.ads : java.util.Collections.emptyList();
            String clickJs = ep.media != null ? ep.media.optString("click", "") : "";
            a.webResolver =
                    new WebResolver(
                            a,
                            address,
                            ep.headers,
                            sniffRules,
                            adHosts,
                            clickJs,
                            new WebResolver.Listener() {
                                public void media(String url, Map<String, String> headers) {
                                    if (ticket != a.generation || serial != a.playbackResolveSerial)
                                        return;
                                    a.webResolver = null;
                                    clearPlaybackLoading(a);
                                    Cms.Episode resolved = new Cms.Episode();
                                    resolved.name = ep.name;
                                    resolved.url = url;
                                    resolved.headers.putAll(headers);
                                    resolved.media = ep.media;
                                    openPlayer(a, s, v, resolved);
                                }

                                public void failed(String reason) {
                                    if (ticket == a.generation
                                            && serial == a.playbackResolveSerial) {
                                        a.changingMiniEpisode = false;
                                        clearPlaybackLoading(a);
                                        stopWeb(a);
                                        failInPlaceSwitch(a, reason);
                                    }
                                }
                            });
            if (a.webResolver.view() != null) {
                a.playbackLoading.addView(a.webResolver.view(), new FrameLayout.LayoutParams(1, 1));
            }
        } catch (Exception error) {
            AppLog.w("PlaybackController", "WebResolver init failed", error);
            a.changingMiniEpisode = false;
            clearPlaybackLoading(a);
            failInPlaceSwitch(a, "这台设备无法打开网页播放组件。");
        }
    }

    static void failInPlaceSwitch(MainActivity a, String message) {
        clearPendingHistoryMigration(a);
        if (a.playerChrome != null) a.playerChrome.setLoading(false);
        if (a.current != null && a.current.player) {
            if (a.playStatus != null) a.playStatus.setText(message);
            showControls(a, true);
        }
        a.toast(message);
    }

    static void clearPendingHistoryMigration(MainActivity a) {
        if (a != null) {
            a.pendingHistoryMigration = null;
        }
    }

    static void clearMismatchedHistoryMigration(MainActivity a, Cms.Site site, Cms.Video video) {
        if (a == null || a.pendingHistoryMigration == null) return;
        String siteKey = site == null ? null : site.key;
        String videoId = video == null ? null : video.id;
        if (!a.pendingHistoryMigration.matchesTarget(siteKey, videoId)) {
            a.pendingHistoryMigration = null;
        }
    }

    static boolean matchesHistoryFallbackBookmark(
            WatchHistory.Entry bm, Cms.Site failedSite, Cms.Video video) {
        return matchesHistoryFallbackBookmark(null, bm, failedSite, video);
    }

    static boolean matchesHistoryFallbackBookmark(
            MainActivity a, WatchHistory.Entry bm, Cms.Site failedSite, Cms.Video video) {
        if (bm == null || bm.title == null || bm.title.trim().isEmpty()) return false;
        if (failedSite == null
                || failedSite.key == null
                || failedSite.key.isEmpty()
                || "live".equals(failedSite.key)) {
            return false;
        }
        if (video == null || video.id == null || video.id.isEmpty()) {
            return false;
        }
        boolean siteMatch =
                a != null
                        ? TvMultiSourceStore.siteMatchesHistoryKey(a, failedSite, bm.site)
                        : TvMultiSourceStore.siteMatchesHistoryKey(failedSite, bm.site);
        return siteMatch && video.id.equals(bm.id);
    }

    private static boolean tryHistoryCrossSourceFailover(
            MainActivity a,
            Cms.Site failedSite,
            Cms.Video video,
            int currentPositionMs,
            String reason) {
        if (a == null
                || failedSite == null
                || "live".equals(failedSite.key)
                || a.historyFallbackInFlight) {
            return false;
        }
        WatchHistory.Entry bm = a.historyFallbackBookmark;
        if (bm == null) {
            return false;
        }
        if (!matchesHistoryFallbackBookmark(a, bm, failedSite, video)) {
            a.historyFallbackBookmark = null;
            return false;
        }
        if (!CatalogScreen.hasAlternativeHistorySources(a, failedSite.key)) {
            return false;
        }
        WatchHistory.Entry updated = WatchHistory.cloneEntry(bm);
        if (currentPositionMs > updated.position) {
            updated.position = currentPositionMs;
        }
        a.historyFallbackBookmark = null;
        CatalogScreen.resumeHistoryFromAlternativeSources(
                a, updated, failedSite.key, reason, false);
        return true;
    }

    static WatchHistory.Entry lookupSavedBookmark(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, Cms.Episode ep) {
        if (a == null
                || s == null
                || s.key == null
                || "live".equals(s.key)
                || v == null
                || v.id == null
                || ep == null) {
            return null;
        }
        int epIdx = line != null ? line.episodes.indexOf(ep) : -1;
        WatchHistory.Entry aliasCandidate = null;
        for (WatchHistory.Entry entry : a.watchHistory()) {
            if (entry == null || !v.id.equals(entry.id)) continue;
            boolean exactSite = s.key.equals(entry.site);
            boolean aliasSite =
                    !exactSite && TvMultiSourceStore.siteMatchesHistoryKey(a, s, entry.site);
            if (!exactSite && !aliasSite) continue;
            boolean sameName = ep.name != null && ep.name.equals(entry.episode);
            boolean sameIndex =
                    line != null
                            && line.name != null
                            && line.name.equals(entry.line)
                            && epIdx >= 0
                            && epIdx == entry.index;
            if (sameName || sameIndex) {
                if (exactSite) return entry;
                if (aliasCandidate == null) aliasCandidate = entry;
            }
            if (exactSite) break;
        }
        return aliasCandidate;
    }

    private static Cms.Site findPushSite(MainActivity a) {
        if (a == null || a.config == null) return null;
        for (Cms.Site site : a.config.sites) {
            if (site.api != null
                    && site.api.toLowerCase(Locale.ROOT).contains("push")
                    && a.available(site)) {
                return site;
            }
        }
        return null;
    }

    static boolean looksLikeNetdiskLine(Cms.Site s, Cms.Line line, String url) {
        String combined =
                ((s != null && s.name != null ? s.name : "")
                                + " "
                                + (s != null && s.api != null ? s.api : "")
                                + " "
                                + (line != null && line.name != null ? line.name : "")
                                + " "
                                + (url != null ? url : ""))
                        .toLowerCase(Locale.ROOT);
        return combined.contains("原画")
                || combined.contains("原畫")
                || combined.contains("网盘")
                || combined.contains("云盘")
                || combined.contains("百度")
                || combined.contains("摆渡")
                || combined.contains("夸克")
                || combined.contains("夸父")
                || combined.contains("阿里")
                || combined.contains("天翼")
                || combined.contains("移动")
                || combined.contains("优汐")
                || combined.contains("嘟嘟")
                || combined.contains("迅雷")
                || combined.contains("雷鲸")
                || combined.contains("玩偶")
                || combined.contains("盘他")
                || combined.contains("扫码")
                || combined.contains("115")
                || combined.contains("123")
                || combined.contains("uc")
                || combined.contains("pan")
                || combined.contains("quark")
                || combined.contains("baidu")
                || combined.contains("wogg")
                || combined.contains("bpanso")
                || combined.contains("dudu")
                || combined.contains("youxi")
                || combined.contains("qr")
                || combined.contains("/proxy/play");
    }

    static boolean shouldFreshReResolveOriginalLine(
            Cms.Site s,
            Cms.Line line,
            Cms.Episode ep,
            boolean prepared,
            int currentPos,
            WatchHistory.Entry historyFallback) {
        if (s == null || "live".equals(s.key) || line == null || ep == null) return false;
        if (ep.media != null && ep.media.optBoolean("_freshReResolve", false)) return false;
        String u = ep.url == null ? "" : ep.url.trim();
        boolean startupFailure = !prepared || currentPos <= 0;
        if (!startupFailure) return false;
        return !s.supported()
                || historyFallback != null
                || looksLikeNetdiskLine(s, line, u)
                || ProxyAddress.isSourceProxy(u)
                || u.contains("/proxy/");
    }

    static boolean canAutoHopToLine(Cms.Site s, Cms.Line candidateLine, Cms.Episode candidateEp) {
        if (candidateLine == null || candidateEp == null) return false;
        return !looksLikeNetdiskLine(s, candidateLine, candidateEp.url);
    }

    private static void triggerFreshOriginalLineReResolve(
            final MainActivity a,
            final int ticket,
            final Cms.Site s,
            final Cms.Video v,
            final Cms.Line origLine,
            final Cms.Episode origEp,
            final int resumePos) {
        final String origLineName = origLine != null && origLine.name != null ? origLine.name : "";
        final String origEpName = origEp != null && origEp.name != null ? origEp.name : "";
        final int origEpIdx =
                (origLine != null && origLine.episodes != null && origEp != null)
                        ? origLine.episodes.indexOf(origEp)
                        : -1;
        a.resumeAt = Math.max(0, resumePos);
        if (a.playStatus != null) {
            a.playStatus.setText("播放地址已失效，正在重新解析原片源…");
        }
        Future<?> req =
                RequestScope.submit(
                        PLAYER_RESOLVE,
                        () -> {
                            Cms.Video freshVideo = null;
                            Cms.Line freshLine = null;
                            Cms.Episode freshEp = null;
                            try {
                                if (v != null && v.id != null && !v.id.trim().isEmpty()) {
                                    String cacheKey =
                                            a.engineEpoch
                                                    + ":"
                                                    + s.key.length()
                                                    + ":"
                                                    + s.key
                                                    + v.id;
                                    a.detailCache.remove(cacheKey);
                                    SourceController.invalidateDetailDiskCache(a, s, v.id);
                                    String rawDetail = a.engine(s).detail(v.id);
                                    Cms.Listing listing = Cms.listing(rawDetail);
                                    if (!listing.videos.isEmpty()) {
                                        freshVideo = listing.videos.get(0);
                                        if (freshVideo.id == null || freshVideo.id.isEmpty()) {
                                            freshVideo.id = v.id;
                                        }
                                        if (freshVideo.title == null
                                                || freshVideo.title.isEmpty()) {
                                            freshVideo.title = v.title;
                                        }
                                        if (freshVideo.poster == null
                                                || freshVideo.poster.isEmpty()) {
                                            freshVideo.poster = v.poster;
                                        }
                                        FreshOriginalTarget matched =
                                                resolveFreshOriginalTarget(
                                                        freshVideo,
                                                        origLine,
                                                        origEp,
                                                        origLineName,
                                                        origEpName,
                                                        origEpIdx);
                                        freshLine = matched.line;
                                        freshEp = matched.episode;
                                        if (freshLine != null
                                                && freshEp != null
                                                && !freshVideo.lines.isEmpty()) {
                                            a.detailCache.put(cacheKey, rawDetail);
                                            SourceController.updateDetailDiskCache(
                                                    a, s, v.id, rawDetail);
                                        }
                                    }
                                }
                            } catch (Throwable err) {
                                AppLog.w(
                                        "PlaybackController",
                                        "fresh detail re-resolve failed, falling back to player()",
                                        err);
                            }
                            final boolean refreshedDetailReturned = freshVideo != null;
                            if (refreshedDetailReturned && (freshLine == null || freshEp == null)) {
                                // Original line or episode vanished / could not be uniquely
                                // confirmed (e.g. wrong season or QR/netdisk backup occupying the
                                // old index); preserve saved progress and let the user retry or
                                // pick manually.
                                final String msg;
                                if (freshLine == null) {
                                    String missingLabel =
                                            origLineName.isEmpty()
                                                    ? "原线路"
                                                    : "原线路「" + origLineName + "」";
                                    msg = missingLabel + "已下线或更换，已保留观看进度，请重试或手动切换其他线路";
                                } else {
                                    String epLabel =
                                            origEpName.isEmpty()
                                                    ? "原剧集"
                                                    : "原剧集「" + origEpName + "」";
                                    msg = epLabel + "未能唯一确认或已下线，已保留观看进度，请重试或手动选集";
                                }
                                a.ui.post(
                                        () -> {
                                            if (ticket != a.generation || a.isFinishing()) return;
                                            a.resumeAt = Math.max(0, resumePos);
                                            clearPlaybackLoading(a);
                                            if (a.playStatus != null) {
                                                a.playStatus.setText(msg);
                                            }
                                            if (a.playerChrome != null) {
                                                a.playerChrome.setTerminalError(msg);
                                            }
                                            if (a.playbackControls != null) {
                                                showControls(a, true);
                                            }
                                        });
                                return;
                            }
                            final Cms.Video targetVideo = freshVideo != null ? freshVideo : v;
                            final Cms.Line targetLine = freshLine != null ? freshLine : origLine;
                            final Cms.Episode targetEp = freshEp != null ? freshEp : origEp;
                            if (targetEp != null) {
                                try {
                                    if (targetEp.media == null) {
                                        targetEp.media = new org.json.JSONObject();
                                    }
                                    targetEp.media.put("_freshReResolve", true);
                                } catch (Exception ignored) {
                                }
                            }
                            a.ui.post(
                                    () -> {
                                        if (ticket != a.generation || a.isFinishing()) return;
                                        a.resumeAt = Math.max(0, resumePos);
                                        if (targetVideo != null
                                                && targetLine != null
                                                && targetEp != null) {
                                            rememberEpisodeOnBackStack(a, targetLine, targetEp);
                                            resolvePlayer(a, s, targetVideo, targetLine, targetEp);
                                        }
                                    });
                        });
        a.pageRequests.add(req);
    }

    static final class FreshOriginalTarget {
        final Cms.Line line;
        final Cms.Episode episode;

        FreshOriginalTarget(Cms.Line line, Cms.Episode episode) {
            this.line = line;
            this.episode = episode;
        }
    }

    static FreshOriginalTarget resolveFreshOriginalTarget(
            Cms.Video freshVideo,
            Cms.Line origLine,
            Cms.Episode origEp,
            String origLineName,
            String origEpName,
            int origEpIdx) {
        if (freshVideo == null || freshVideo.lines == null || freshVideo.lines.isEmpty()) {
            return new FreshOriginalTarget(null, null);
        }
        String cleanLineName = origLineName == null ? "" : origLineName.trim();
        String normOrigLine = normalizeLineIdentity(cleanLineName);
        Cms.Line freshLine = null;
        if (!cleanLineName.isEmpty()) {
            for (Cms.Line candLine : freshVideo.lines) {
                if (candLine != null
                        && cleanLineName.equals(candLine.name)
                        && !candLine.episodes.isEmpty()) {
                    freshLine = candLine;
                    break;
                }
            }
        }
        if (freshLine == null && !normOrigLine.isEmpty()) {
            for (Cms.Line candLine : freshVideo.lines) {
                if (candLine != null
                        && normOrigLine.equals(normalizeLineIdentity(candLine.name))
                        && !candLine.episodes.isEmpty()) {
                    freshLine = candLine;
                    break;
                }
            }
        }
        // NEVER fall back by old list index when origLineName vanished:
        // another line (e.g. QR/netdisk backup "优汐扫码") may now occupy the old index.
        if (freshLine == null || freshLine.episodes.isEmpty()) {
            return new FreshOriginalTarget(null, null);
        }
        Cms.Episode freshEp = null;
        String origStableId = extractStableEpisodeId(origEp);
        if (!origStableId.isEmpty()) {
            List<Cms.Episode> byId = new ArrayList<>();
            for (Cms.Episode candEp : freshLine.episodes) {
                if (candEp != null && origStableId.equals(extractStableEpisodeId(candEp))) {
                    byId.add(candEp);
                }
            }
            if (byId.size() == 1) {
                freshEp = byId.get(0);
            }
        }
        String cleanEpName = origEpName == null ? "" : origEpName.trim();
        String normOrigEp = normalizeLineIdentity(cleanEpName);
        if (freshEp == null && !cleanEpName.isEmpty()) {
            List<Cms.Episode> exactMatches = new ArrayList<>();
            for (Cms.Episode candEp : freshLine.episodes) {
                if (candEp != null && cleanEpName.equals(candEp.name)) {
                    exactMatches.add(candEp);
                }
            }
            if (exactMatches.size() == 1) {
                freshEp = exactMatches.get(0);
            }
        }
        if (freshEp == null && !normOrigEp.isEmpty()) {
            List<Cms.Episode> normMatches = new ArrayList<>();
            for (Cms.Episode candEp : freshLine.episodes) {
                if (candEp != null && normOrigEp.equals(normalizeLineIdentity(candEp.name))) {
                    normMatches.add(candEp);
                }
            }
            if (normMatches.size() == 1) {
                freshEp = normMatches.get(0);
            }
        }
        if (freshEp == null && !cleanEpName.isEmpty()) {
            int origSeason = TvSeriesScraper.extractSeasonNumber(cleanEpName);
            int origNum = TvSeriesScraper.extractEpisodeNumber(cleanEpName);
            boolean origSpecial = TvSeriesScraper.isSpecialEpisode(cleanEpName);
            if (origNum > 0) {
                List<Cms.Episode> equivMatches = new ArrayList<>();
                for (Cms.Episode candEp : freshLine.episodes) {
                    if (candEp == null) continue;
                    String candName = candEp.name == null ? "" : candEp.name.trim();
                    if (TvSeriesScraper.isSpecialEpisode(candName) != origSpecial) continue;
                    if (TvSeriesScraper.extractEpisodeNumber(candName) != origNum) continue;
                    int candSeason = TvSeriesScraper.extractSeasonNumber(candName);
                    if (origSeason > 0) {
                        // Explicit season on bookmark (e.g. S02E01 / 第二季 第1集):
                        // require the SAME explicit season so S02E01 NEVER silently falls back
                        // to S01E01 or an untagged episode!
                        if (candSeason != origSeason) continue;
                    } else {
                        // Unspecified season on bookmark (e.g. 第01集): never jump to Season 2+.
                        if (candSeason > 1) continue;
                    }
                    equivMatches.add(candEp);
                }
                if (equivMatches.size() == 1) {
                    freshEp = equivMatches.get(0);
                }
            }
        }
        if (freshEp == null
                && cleanEpName.isEmpty()
                && origStableId.isEmpty()
                && origEpIdx >= 0
                && origEpIdx < freshLine.episodes.size()) {
            freshEp = freshLine.episodes.get(origEpIdx);
        }
        return new FreshOriginalTarget(freshLine, freshEp);
    }

    static String extractStableEpisodeId(Cms.Episode ep) {
        if (ep == null || ep.media == null) return "";
        String[] keys = {"episode_id", "episodeId", "file_id", "fileId", "fid", "share_file_id"};
        for (String key : keys) {
            String val = Cms.optSafeString(ep.media, key, "").trim();
            if (!val.isEmpty()) return key + ":" + val;
        }
        return "";
    }

    static String normalizeLineIdentity(String name) {
        if (name == null) return "";
        return name.trim().replaceAll("\\s+", "").toLowerCase(Locale.ROOT);
    }

    private static Cms.Episode findMatchingEpisode(
            Cms.Line targetLine, Cms.Line fromLine, Cms.Episode ep) {
        return TvSeriesScraper.findMatchingEpisodeAcrossLines("", targetLine, fromLine, ep, null);
    }

    static DanmuOwnership.RequestContext beginDanmuContext(
            MainActivity a,
            Cms.Site s,
            Cms.Video v,
            Cms.Line line,
            Cms.Episode ep,
            boolean isSwitch) {
        String siteKey = s != null && s.key != null ? s.key : "";
        String vid = v != null && v.id != null ? v.id : "";
        String lineName = line != null && line.name != null ? line.name : "";
        String epName = ep != null && ep.name != null ? ep.name : "";
        String epUrl = ep != null && ep.url != null ? ep.url : "";
        int epIdx = (line != null && ep != null) ? line.episodes.indexOf(ep) : -1;
        DanmuOwnership.RequestContext ctx =
                DanmuOwnership.GLOBAL.beginResolve(
                        siteKey, vid, lineName, epName, epUrl, epIdx, isSwitch);
        if (a != null) {
            a.activeDanmuContext = ctx;
        }
        return ctx;
    }

    static DanmuOwnership.RequestContext ensureDanmuContext(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, Cms.Episode ep) {
        String siteKey = s != null && s.key != null ? s.key : "";
        String vid = v != null && v.id != null ? v.id : "";
        String lineName = line != null && line.name != null ? line.name : "";
        String epName = ep != null && ep.name != null ? ep.name : "";
        String epUrl = ep != null && ep.url != null ? ep.url : "";
        int epIdx = (line != null && ep != null) ? line.episodes.indexOf(ep) : -1;
        DanmuOwnership.RequestContext ctx =
                DanmuOwnership.GLOBAL.ensureActiveContext(
                        siteKey, vid, lineName, epName, epUrl, epIdx);
        if (a != null) {
            a.activeDanmuContext = ctx;
        }
        return ctx;
    }

    static void resolvePlayer(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Line line, Cms.Episode ep) {
        clearMismatchedHistoryMigration(a, s, v);
        if (a.miniMode) {
            a.changingMiniEpisode = true;
            showEpisodeDetails(a, s, v);
        }
        boolean switchingExisting =
                a.activeDanmuContext != null
                        || (a.activeEpisode != null && a.activeEpisode != ep)
                        || (a.activeLine != null && a.activeLine != line);
        final DanmuOwnership.RequestContext resolveDanmuCtx =
                beginDanmuContext(a, s, v, line, ep, switchingExisting);
        a.activeLine = line;
        a.activeEpisode = ep;
        if (a.resumeAt == 0) {
            WatchHistory.Entry saved = lookupSavedBookmark(a, s, v, line, ep);
            if (saved != null) {
                a.resumeAt = saved.resume();
            }
        }
        if (s.supported()) {
            String rewrittenEpUrl = LocalProxy.rewrite(ep.url);
            String cleanPath =
                    rewrittenEpUrl == null
                            ? ""
                            : rewrittenEpUrl.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
            boolean looksLikeWebPage =
                    cleanPath.endsWith(".html")
                            || cleanPath.endsWith(".htm")
                            || cleanPath.endsWith(".shtml")
                            || cleanPath.contains("/share/");
            if (Cms.isDirectStreamUrl(rewrittenEpUrl)
                    || (!s.requiresParser && Cms.isMedia(rewrittenEpUrl) && !looksLikeWebPage)) {
                openPlayer(a, s, v, ep);
                return;
            }
            if (v != null && v.lines != null) {
                for (Cms.Line sibling : v.lines) {
                    if (sibling == line) continue;
                    Cms.Episode match = findMatchingEpisode(sibling, line, ep);
                    if (match != null && Cms.isDirectStreamUrl(LocalProxy.rewrite(match.url))) {
                        a.activeLine = sibling;
                        a.activeEpisode = match;
                        beginDanmuContext(a, s, v, sibling, match, true);
                        rememberEpisodeOnBackStack(a, sibling, match);
                        openPlayer(a, s, v, match);
                        return;
                    }
                }
            }
            resolveCmsWithParser(a, s, v, ep, s.playUrl);
            return;
        }
        if (a.playbackLoading != null) return;
        showPlaybackLoading(a);
        PluginDialogStyler.watch(a);
        final int serial = a.playbackResolveSerial, ticket = a.generation;
        Future<?> request =
                RequestScope.submit(
                        PLAYER_RESOLVE,
                        () -> {
                            try {
                                Cms.Site targetSite = s;
                                Cms.Line chosenLine = line;
                                Cms.Episode chosenEp = ep;
                                String targetFlag = line != null ? line.name : "";
                                String targetId = ep.url != null ? ep.url : "";
                                if (targetId.regionMatches(true, 0, "push://", 0, 7)) {
                                    Cms.Site pushSite = findPushSite(a);
                                    if (pushSite != null) {
                                        targetSite = pushSite;
                                        String pushTarget = targetId.substring(7);
                                        Cms.Listing pushList =
                                                Cms.listing(a.engine(pushSite).detail(pushTarget));
                                        if (!pushList.videos.isEmpty()
                                                && !pushList.videos.get(0).lines.isEmpty()
                                                && !pushList.videos
                                                        .get(0)
                                                        .lines
                                                        .get(0)
                                                        .episodes
                                                        .isEmpty()) {
                                            Cms.Line pLine = pushList.videos.get(0).lines.get(0);
                                            targetFlag = pLine.name;
                                            targetId = pLine.episodes.get(0).url;
                                        }
                                    }
                                }
                                JSONObject result = null;
                                Cms.Episode resolvedCandidate = null;
                                Exception primaryError = null;
                                try {
                                    DanmuOwnership.RequestContext prevScope =
                                            DanmuOwnership.GLOBAL.bindThreadScope(resolveDanmuCtx);
                                    try {
                                        result =
                                                new JSONObject(
                                                        a.engine(targetSite)
                                                                .player(targetFlag, targetId));
                                    } finally {
                                        DanmuOwnership.GLOBAL.restoreThreadScope(prevScope);
                                    }
                                    resolvedCandidate =
                                            MediaOptions.episode(targetSite, chosenEp, result);
                                    if (resolvedCandidate.url.regionMatches(
                                            true, 0, "push://", 0, 7)) {
                                        Cms.Site pushSite = findPushSite(a);
                                        if (pushSite != null) {
                                            String pushTarget = resolvedCandidate.url.substring(7);
                                            Cms.Listing pushList =
                                                    Cms.listing(
                                                            a.engine(pushSite).detail(pushTarget));
                                            if (!pushList.videos.isEmpty()
                                                    && !pushList.videos.get(0).lines.isEmpty()
                                                    && !pushList.videos
                                                            .get(0)
                                                            .lines
                                                            .get(0)
                                                            .episodes
                                                            .isEmpty()) {
                                                Cms.Line pLine =
                                                        pushList.videos.get(0).lines.get(0);
                                                JSONObject pushRes;
                                                DanmuOwnership.RequestContext prevPushScope =
                                                        DanmuOwnership.GLOBAL.bindThreadScope(
                                                                resolveDanmuCtx);
                                                try {
                                                    pushRes =
                                                            new JSONObject(
                                                                    a.engine(pushSite)
                                                                            .player(
                                                                                    pLine.name,
                                                                                    pLine.episodes
                                                                                            .get(0)
                                                                                            .url));
                                                } finally {
                                                    DanmuOwnership.GLOBAL.restoreThreadScope(
                                                            prevPushScope);
                                                }
                                                resolvedCandidate =
                                                        MediaOptions.episode(
                                                                pushSite, chosenEp, pushRes);
                                                result = pushRes;
                                            }
                                        }
                                    }
                                } catch (Exception e) {
                                    primaryError = e;
                                }

                                boolean primaryPlayable =
                                        resolvedCandidate != null
                                                && resolvedCandidate.url != null
                                                && !resolvedCandidate.url.trim().isEmpty()
                                                && (Cms.isMedia(resolvedCandidate.url.trim())
                                                        || resolvedCandidate
                                                                .url
                                                                .trim()
                                                                .startsWith("magnet:?")
                                                        || (result != null
                                                                && (result.optInt("parse", 0) != 0
                                                                        || result.optInt("jx", 0)
                                                                                != 0)));
                                if (!primaryPlayable
                                        && s != null
                                        && (s.isNetdiskSite()
                                                || looksLikeNetdiskLine(s, line, targetId))
                                        && v != null
                                        && v.id != null
                                        && !v.id.trim().isEmpty()
                                        && !"0".equals(v.id.trim())
                                        && !"1".equals(v.id.trim())) {
                                    // PanSou / netdisk detail URLs carry short-lived tokens; do
                                    // one live detail refresh before failing over across sources.
                                    try {
                                        Cms.Listing freshList =
                                                Cms.listing(a.engine(s).detail(v.id.trim()));
                                        if (!freshList.videos.isEmpty()) {
                                            Cms.Video freshVideo = freshList.videos.get(0);
                                            int curIdx =
                                                    line != null
                                                            ? line.episodes.indexOf(chosenEp)
                                                            : 0;
                                            FreshOriginalTarget freshTarget =
                                                    resolveFreshOriginalTarget(
                                                            freshVideo,
                                                            line,
                                                            chosenEp,
                                                            line != null ? line.name : "",
                                                            chosenEp != null ? chosenEp.name : "",
                                                            Math.max(0, curIdx));
                                            if (freshTarget != null
                                                    && freshTarget.line != null
                                                    && freshTarget.episode != null
                                                    && freshTarget.episode.url != null) {
                                                DanmuOwnership.RequestContext freshCtx =
                                                        beginDanmuContext(
                                                                a,
                                                                s,
                                                                freshVideo,
                                                                freshTarget.line,
                                                                freshTarget.episode,
                                                                true);
                                                DanmuOwnership.RequestContext prevFreshScope =
                                                        DanmuOwnership.GLOBAL.bindThreadScope(
                                                                freshCtx);
                                                JSONObject freshRes;
                                                try {
                                                    freshRes =
                                                            new JSONObject(
                                                                    a.engine(s)
                                                                            .player(
                                                                                    freshTarget
                                                                                            .line
                                                                                            .name,
                                                                                    freshTarget
                                                                                            .episode
                                                                                            .url));
                                                } finally {
                                                    DanmuOwnership.GLOBAL.restoreThreadScope(
                                                            prevFreshScope);
                                                }
                                                Cms.Episode freshResolved =
                                                        MediaOptions.episode(
                                                                s, freshTarget.episode, freshRes);
                                                String freshUrl =
                                                        freshResolved.url == null
                                                                ? ""
                                                                : freshResolved.url.trim();
                                                if (!freshUrl.isEmpty()
                                                        && (Cms.isMedia(freshUrl)
                                                                || freshUrl.startsWith("magnet:?")
                                                                || freshRes.optInt("parse", 0) != 0
                                                                || freshRes.optInt("jx", 0) != 0)) {
                                                    result = freshRes;
                                                    resolvedCandidate = freshResolved;
                                                    chosenLine = freshTarget.line;
                                                    chosenEp = freshTarget.episode;
                                                    primaryError = null;
                                                    primaryPlayable = true;
                                                }
                                            }
                                        }
                                    } catch (Exception ignored) {
                                    }
                                }
                                if (!primaryPlayable
                                        && v != null
                                        && v.lines != null
                                        && v.lines.size() > 1
                                        && !looksLikeNetdiskLine(s, line, targetId)) {
                                    for (Cms.Line altLine : v.lines) {
                                        if (altLine == null
                                                || altLine == line
                                                || altLine.episodes.isEmpty()) {
                                            continue;
                                        }
                                        Cms.Episode altEp = findMatchingEpisode(altLine, line, ep);
                                        if (altEp == null || altEp.url == null) continue;
                                        if (looksLikeNetdiskLine(s, altLine, altEp.url)) continue;
                                        try {
                                            DanmuOwnership.RequestContext altCtx =
                                                    beginDanmuContext(
                                                            a, s, v, altLine, altEp, true);
                                            DanmuOwnership.RequestContext prevAltScope =
                                                    DanmuOwnership.GLOBAL.bindThreadScope(altCtx);
                                            JSONObject altRes;
                                            try {
                                                altRes =
                                                        new JSONObject(
                                                                a.engine(s)
                                                                        .player(
                                                                                altLine.name,
                                                                                altEp.url));
                                            } finally {
                                                DanmuOwnership.GLOBAL.restoreThreadScope(
                                                        prevAltScope);
                                            }
                                            Cms.Episode altResolved =
                                                    MediaOptions.episode(s, altEp, altRes);
                                            String altUrl =
                                                    altResolved.url == null
                                                            ? ""
                                                            : altResolved.url.trim();
                                            if (!altUrl.isEmpty()
                                                    && (Cms.isMedia(altUrl)
                                                            || altUrl.startsWith("magnet:?")
                                                            || altRes.optInt("parse", 0) != 0
                                                            || altRes.optInt("jx", 0) != 0)) {
                                                result = altRes;
                                                resolvedCandidate = altResolved;
                                                chosenLine = altLine;
                                                chosenEp = altEp;
                                                primaryError = null;
                                                break;
                                            }
                                        } catch (Exception ignored) {
                                        }
                                    }
                                }
                                if (primaryError != null && resolvedCandidate == null) {
                                    throw primaryError;
                                }
                                final JSONObject finalResult =
                                        result != null ? result : new JSONObject();
                                final Cms.Episode resolved =
                                        resolvedCandidate != null
                                                ? resolvedCandidate
                                                : MediaOptions.episode(
                                                        targetSite, chosenEp, finalResult);
                                final Cms.Line finalLine = chosenLine;
                                final Cms.Episode finalEp = chosenEp;
                                final boolean switchedLine =
                                        chosenLine != line && chosenLine != null;
                                a.ui.post(
                                        () -> {
                                            if (serial != a.playbackResolveSerial
                                                    || ticket != a.generation
                                                    || a.isFinishing()) {
                                                JSONObject unused =
                                                        resolved.media.optJSONObject("embySession");
                                                if (unused != null
                                                        && s != null
                                                        && s.api != null
                                                        && s.api.startsWith(
                                                                com.pilipala.emby.EmbyLibrary
                                                                        .PREFIX))
                                                    try {
                                                        com.pilipala.emby.EmbyAccounts.open(
                                                                        a, s.api)
                                                                .track(unused)
                                                                .stop(0);
                                                    } catch (Exception ignored) {
                                                    }
                                                return;
                                            }
                                            try {
                                                if (switchedLine) {
                                                    a.activeLine = finalLine;
                                                    a.activeEpisode = finalEp;
                                                    a.toast("当前线路响应异常，已自动切换至 " + finalLine.name);
                                                }
                                                String url =
                                                        resolved.url == null
                                                                ? ""
                                                                : resolved.url.trim();
                                                if (url.isEmpty() && finalEp.url != null) {
                                                    String fallbackEpUrl =
                                                            LocalProxy.rewrite(finalEp.url.trim());
                                                    if (Cms.isMedia(fallbackEpUrl)
                                                            || fallbackEpUrl.startsWith(
                                                                    "magnet:?")) {
                                                        url = fallbackEpUrl;
                                                        resolved.url = fallbackEpUrl;
                                                    }
                                                }
                                                if (finalResult.optInt("parse", 0) != 0
                                                        || finalResult.optInt("jx", 0) != 0) {
                                                    String playPrefix =
                                                            finalResult.optString(
                                                                    "playUrl", s.playUrl);
                                                    if ((playPrefix == null || playPrefix.isEmpty())
                                                            && a.config != null
                                                            && !a.config.parses.isEmpty()) {
                                                        clearPlaybackLoading(a);
                                                        resolveCmsWithParser(a, s, v, resolved, "");
                                                        return;
                                                    }
                                                    resolveWebPage(a, s, v, resolved, playPrefix);
                                                    return;
                                                }
                                                clearPlaybackLoading(a);
                                                if (url.isEmpty()) {
                                                    a.changingMiniEpisode = false;
                                                    String spiderMsg =
                                                            finalResult
                                                                    .optString(
                                                                            "msg",
                                                                            finalResult.optString(
                                                                                    "message",
                                                                                    finalResult
                                                                                            .optString(
                                                                                                    "tip",
                                                                                                    "")))
                                                                    .trim();
                                                    boolean isNetdisk =
                                                            looksLikeNetdiskLine(
                                                                    s, finalLine, finalEp.url);
                                                    boolean authNeeded =
                                                            isNetdisk
                                                                    && looksLikeNetdiskAuthRequired(
                                                                            spiderMsg);
                                                    if (!authNeeded
                                                            && tryHistoryCrossSourceFailover(
                                                                    a,
                                                                    s,
                                                                    v,
                                                                    a.resumeAt,
                                                                    isNetdisk
                                                                            ? "原网盘分享已失效"
                                                                            : "原片源未返回有效播放地址")) {
                                                        return;
                                                    }
                                                    if (!spiderMsg.isEmpty()) {
                                                        failInPlaceSwitch(a, spiderMsg);
                                                    } else if (isNetdisk) {
                                                        failInPlaceSwitch(
                                                                a,
                                                                "该网盘线路未返回播放地址，请先在「网盘与账号」扫码登录对应网盘，或点击右上角"
                                                                        + " ⇄ 切换其他线路");
                                                    } else {
                                                        failInPlaceSwitch(
                                                                a, "当前线路未返回有效播放地址，请点击右上角 ⇄ 切换其他线路");
                                                    }
                                                    return;
                                                }
                                                if (!Cms.isMedia(url)
                                                        && !url.startsWith("magnet:?")) {
                                                    a.changingMiniEpisode = false;
                                                    if (looksLikeNetdiskLine(s, finalLine, url)) {
                                                        failInPlaceSwitch(
                                                                a,
                                                                "该网盘线路需先在「网盘与账号」登录授权，或点击右上角 ⇄"
                                                                        + " 切换其他线路");
                                                    } else {
                                                        failInPlaceSwitch(
                                                                a, "来源返回的播放协议暂不支持，请切换其他线路");
                                                    }
                                                    return;
                                                }
                                                openPlayer(a, s, v, resolved);
                                            } catch (Exception error) {
                                                AppLog.w(
                                                        "PlaybackController",
                                                        "parse player response failed",
                                                        error);
                                                a.changingMiniEpisode = false;
                                                clearPlaybackLoading(a);
                                                failInPlaceSwitch(a, "播放信息无法读取，请重试");
                                            }
                                        });
                            } catch (Exception error) {
                                AppLog.w("PlaybackController", "engine.player failed", error);
                                a.ui.post(
                                        () -> {
                                            if (serial != a.playbackResolveSerial
                                                    || ticket != a.generation) return;
                                            a.changingMiniEpisode = false;
                                            clearPlaybackLoading(a);
                                            if (tryHistoryCrossSourceFailover(
                                                    a, s, v, a.resumeAt, "原片源解析失败")) {
                                                return;
                                            }
                                            failInPlaceSwitch(a, a.message(error));
                                        });
                            }
                        });
        a.pageRequests.add(request);
    }

    private static boolean looksLikeNetdiskAuthRequired(String msg) {
        if (msg == null || msg.trim().isEmpty()) return false;
        String lower = msg.toLowerCase(Locale.ROOT);
        return lower.contains("登录")
                || lower.contains("扫码")
                || lower.contains("cookie")
                || lower.contains("token")
                || lower.contains("授权")
                || lower.contains("login");
    }

    private static String extractEmbeddedStreamUrl(String baseUrl, String body) {
        if (body == null || body.isEmpty()) return "";
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile(
                                "(?:const|var|let)?\\s*(?:url|main|playurl|src|vid)\\s*[:=]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)(?:\\?[^\"']*)?)[\"']",
                                java.util.regex.Pattern.CASE_INSENSITIVE)
                        .matcher(body);
        if (!m.find()) {
            m =
                    java.util.regex.Pattern.compile(
                                    "[\"']((?:https?:)?//[^\"']+\\.(?:m3u8|mp4)(?:\\?[^\"']*)?|/[^\"'\\s<>]+\\.(?:m3u8|mp4)(?:\\?[^\"'\\s<>]*)?)[\"']",
                                    java.util.regex.Pattern.CASE_INSENSITIVE)
                            .matcher(body);
            if (!m.find()) return "";
        }
        String found = m.group(1).trim().replace("\\/", "/");
        if (found.isEmpty()) return "";
        try {
            if (found.startsWith("//")) return "https:" + found;
            if (Cms.isHttp(found)) return found;
            if (baseUrl != null && Cms.isHttp(baseUrl)) {
                return new java.net.URI(baseUrl).resolve(found).toString();
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    static void resolveCmsWithParser(
            MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode ep, String preferredPrefix) {
        if (a.playbackLoading != null) return;
        showPlaybackLoading(a);
        PluginDialogStyler.watch(a);
        final int serial = a.playbackResolveSerial, ticket = a.generation;
        Future<?> request =
                RequestScope.submit(
                        PLAYER_RESOLVE,
                        () -> {
                            // 0. If ep.url is an HTML share wrapper with an embedded .m3u8/.mp4,
                            // extract it directly before falling back to external parsers.
                            if (ep.url != null && Cms.isHttp(ep.url)) {
                                try {
                                    String html = Cms.fetch(ep.url, s.headers);
                                    String embedded = extractEmbeddedStreamUrl(ep.url, html);
                                    if (Cms.isDirectStreamUrl(embedded)) {
                                        final Cms.Episode directEp = new Cms.Episode();
                                        directEp.name = ep.name;
                                        directEp.url = embedded;
                                        directEp.headers.putAll(
                                                Cms.inheritedHeaders(s.api, embedded, s.headers));
                                        a.ui.post(
                                                () -> {
                                                    if (serial != a.playbackResolveSerial
                                                            || ticket != a.generation
                                                            || a.isFinishing()) return;
                                                    clearPlaybackLoading(a);
                                                    openPlayer(a, s, v, directEp);
                                                });
                                        return;
                                    }
                                } catch (Exception ignored) {
                                }
                            }
                            // 1. Try preferredPrefix or JSON parsers in config.parses
                            List<Cms.Parse> candidates = new java.util.ArrayList<>();
                            if (preferredPrefix != null && Cms.isHttp(preferredPrefix)) {
                                Cms.Parse direct = new Cms.Parse();
                                direct.name = s.name;
                                direct.url = preferredPrefix;
                                direct.type = 1;
                                direct.headers.putAll(s.headers);
                                candidates.add(direct);
                            }
                            if (a.config != null && a.config.parses != null) {
                                for (Cms.Parse p : a.config.parses) {
                                    if (p != null && Cms.isHttp(p.url)) candidates.add(p);
                                }
                            }
                            String webFallbackPrefix =
                                    preferredPrefix != null ? preferredPrefix : "";
                            for (int i = 0; i < Math.min(4, candidates.size()); i++) {
                                if (Thread.currentThread().isInterrupted()) return;
                                Cms.Parse p = candidates.get(i);
                                if (p.type == 0 && webFallbackPrefix.isEmpty()) {
                                    webFallbackPrefix = p.url;
                                }
                                if (p.type == 1 || p.type == 2 || p.type == 3 || i == 0) {
                                    try {
                                        String targetUrl =
                                                p.url + java.net.URLEncoder.encode(ep.url, "UTF-8");
                                        String resp = Cms.fetch(targetUrl, p.headers);
                                        if (resp != null && resp.trim().startsWith("{")) {
                                            JSONObject jo = new JSONObject(resp.trim());
                                            String mediaUrl = jo.optString("url", "").trim();
                                            if (Cms.isMedia(mediaUrl)) {
                                                final Cms.Episode resolved =
                                                        MediaOptions.episode(s, ep, jo);
                                                a.ui.post(
                                                        () -> {
                                                            if (serial != a.playbackResolveSerial
                                                                    || ticket != a.generation
                                                                    || a.isFinishing()) return;
                                                            clearPlaybackLoading(a);
                                                            openPlayer(a, s, v, resolved);
                                                        });
                                                return;
                                            }
                                        }
                                    } catch (Exception ignored) {
                                    }
                                }
                            }
                            final String finalPrefix = webFallbackPrefix;
                            a.ui.post(
                                    () -> {
                                        if (serial != a.playbackResolveSerial
                                                || ticket != a.generation
                                                || a.isFinishing()) return;
                                        if (Cms.isHttp(finalPrefix + ep.url)) {
                                            resolveWebPage(a, s, v, ep, finalPrefix);
                                        } else if (Cms.isMedia(ep.url)) {
                                            clearPlaybackLoading(a);
                                            openPlayer(a, s, v, ep);
                                        } else {
                                            a.changingMiniEpisode = false;
                                            clearPlaybackLoading(a);
                                            failInPlaceSwitch(a, "此剧集需要外部解析，未找到可用解析接口");
                                        }
                                    });
                        });
        a.pageRequests.add(request);
    }

    static void showPlaybackLoading(MainActivity a) {
        a.playbackLoadingFocus = a.getCurrentFocus();
        if (a.markerHost != null) a.markerHost.abort();
        a.playbackLoading = new PlaybackLoading(a);
        a.root.addView(a.playbackLoading, new FrameLayout.LayoutParams(-1, -1));
        if (a.playerChrome != null) a.playerChrome.update();
        a.playbackLoading.requestFocus();
    }

    static void clearPlaybackLoading(MainActivity a) {
        a.playbackResolveSerial++;
        if (a.playbackLoading != null) {
            if (a.playbackLoading.getParent() instanceof ViewGroup)
                ((ViewGroup) a.playbackLoading.getParent()).removeView(a.playbackLoading);
            a.playbackLoading = null;
            if (a.playerChrome != null) a.playerChrome.update();
            if (a.playbackLoadingFocus != null && UiCompat.isAttached(a.playbackLoadingFocus))
                a.playbackLoadingFocus.requestFocus();
            a.playbackLoadingFocus = null;
            if (a.playerChrome != null) a.playerChrome.update();
        }
    }

    static void openPlayer(MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode e) {
        clearMismatchedHistoryMigration(a, s, v);
        if (e.url != null) {
            e.url = e.url.trim();
            if (e.url.startsWith("//")) {
                e.url = "https:" + e.url;
            }
            if (e.url.regionMatches(true, 0, "webview://", 0, 10)) {
                e.url = e.url.substring(10).trim();
                resolveWebPage(a, s, v, e, "");
                return;
            }
            if (a.config != null
                    && (e.url.regionMatches(true, 0, "proxy://", 0, 8)
                            || e.url.contains("/proxy"))) {
                try {
                    a.ensureProxy(a.config);
                } catch (Exception ignored) {
                }
            }
            e.url = LocalProxy.rewrite(e.url);
        }
        if (e.url != null && e.url.startsWith("magnet:?")) {
            magnetPlayer(a, s, v, e);
            return;
        }
        if (!Cms.isMedia(e.url)) {
            clearPendingHistoryMigration(a);
            if (a.playerChrome != null) a.playerChrome.setLoading(false);
            a.notice("这条剧集需要解析或使用了特殊协议，基础版尚未支持。");
            return;
        }
        MainActivity.Screen screen = new MainActivity.Screen(() -> playerPage(a, s, v, e));
        screen.player = true;
        a.open(screen, a.current == null || !a.current.player);
    }

    static void magnetPlayer(MainActivity a, Cms.Site site, Cms.Video video, Cms.Episode episode) {
        a.open(
                new MainActivity.Screen(
                        () -> {
                            a.renderPage(video.title, "MAGNET PLAYBACK");
                            TextView state = a.text("正在获取磁力文件列表…", 17, MainActivity.MUTED);
                            a.body.addView(state);
                            final int ticket = a.generation;
                            try {
                                a.magnetStream =
                                        MagnetStream.start(
                                                a,
                                                episode.url,
                                                new MagnetStream.Listener() {
                                                    public void progress(String message) {
                                                        if (ticket == a.generation)
                                                            state.setText(message);
                                                    }

                                                    public void files(
                                                            List<MagnetStream.MediaFile> files,
                                                            int suggested,
                                                            MagnetStream.Selection selection) {
                                                        if (ticket != a.generation) return;
                                                        String[] names = new String[files.size()];
                                                        for (int i = 0; i < names.length; i++)
                                                            names[i] = files.get(i).name;
                                                        new AppDialog.Builder(a)
                                                                .setTitle("选择要播放的视频")
                                                                .setSingleChoiceItems(
                                                                        names,
                                                                        suggested,
                                                                        (dialog, index) -> {
                                                                            dialog.dismiss();
                                                                            selection.select(index);
                                                                        })
                                                                .setNegativeButton(
                                                                        "取消",
                                                                        (dialog, index) ->
                                                                                a.onBackPressed())
                                                                .setOnCancelListener(
                                                                        dialog -> a.onBackPressed())
                                                                .show();
                                                    }

                                                    public void ready(
                                                            String url, String mime, String name) {
                                                        if (ticket != a.generation) return;
                                                        Cms.Episode resolved = new Cms.Episode();
                                                        resolved.name = name;
                                                        resolved.url = url;
                                                        resolved.headers.putAll(episode.headers);
                                                        try {
                                                            resolved.media =
                                                                    new JSONObject(
                                                                                    episode.media
                                                                                            .toString())
                                                                            .put("mimeType", mime);
                                                        } catch (Exception ignored) {
                                                        }
                                                        if (!a.back.isEmpty())
                                                            a.current = a.back.pop();
                                                        openPlayer(a, site, video, resolved);
                                                    }

                                                    public void error(String message) {
                                                        if (ticket == a.generation) {
                                                            state.setText(message);
                                                            a.addButton(
                                                                    a.body,
                                                                    a.button(
                                                                            "重试",
                                                                            "primary",
                                                                            a::refresh));
                                                        }
                                                    }
                                                });
                            } catch (Exception error) {
                                AppLog.w("PlaybackController", "MagnetStream start failed", error);
                                state.setText("磁力播放初始化失败：" + error.getClass().getSimpleName());
                            }
                        }),
                true);
    }

    static void changeEpisode(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            Cms.Line line,
            Cms.Episode episode,
            int position) {
        if (episode != null && episode.media != null && episode != a.activeEpisode) {
            episode.media.remove("_eofReconnectCount");
            episode.media.remove("_ioReconnectCount");
            episode.media.remove("_hwRetry");
        }
        a.changingMiniEpisode = a.miniMode;
        a.resumeAt = position;
        if (a.miniMode) {
            showEpisodeDetails(a, site, video);
        } else {
            rememberEpisodeOnBackStack(a, line, episode);
            if (a.current != null && a.current.player) {
                prepareInPlaceSwitch(a, line, episode);
            }
        }
        resolvePlayer(a, site, video, line, episode);
    }

    static void rememberEpisodeOnBackStack(MainActivity a, Cms.Line line, Cms.Episode episode) {
        if (a.back.isEmpty() || line == null || episode == null) return;
        MainActivity.Screen prev = a.back.peek();
        if (prev == null) return;
        int epIdx = line.episodes.indexOf(episode);
        if (epIdx >= 0) {
            boolean desc = a.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false);
            int page = EpisodeSelection.pageFor(epIdx, line.episodes.size(), desc);
            prev.selection.select(line.name, page, line.episodes.size());
            prev.focus = "episode:" + line.name + ":" + epIdx;
            prev.episodeFocus = epIdx;
            prev.episodeFocusLine = line.name;
        }
    }

    static void prepareInPlaceSwitch(MainActivity a, Cms.Line line, Cms.Episode episode) {
        a.playbackSessionId++;
        a.playbackOutputState = null;
        if (a.playbackControls != null) {
            a.playbackControls.onSwitchingAway();
        }
        DanmuOwnership.GLOBAL.invalidateForSwitch();
        a.activeDanmuContext = null;
        finishSeek(a, false);
        savePlaybackHistory(a, true);
        stopWeb(a);
        stopMagnet(a);
        if (a.player != null) {
            try {
                a.player.release();
            } catch (Exception error) {
                AppLog.w("PlaybackController", "player.release failed", error);
            }
            a.player = null;
        }
        a.prepared = false;
        a.playing = false;
        if (a.playerChrome != null) {
            a.playerChrome.switchEpisode(episode, line);
        }
    }

    static void showEpisodeDetails(MainActivity a, Cms.Site site, Cms.Video video) {
        releasePlayer(a);
        if (!a.isTvDevice()) {
            a.applyMobileSystemBars(false);
            a.setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER);
            if (a.usableWidth > a.usableHeight && a.usableHeight > 0) {
                int tmp = a.usableWidth;
                a.usableWidth = a.usableHeight;
                a.usableHeight = tmp;
            }
        }
        if (a.current != null && a.current.player)
            a.current =
                    a.back.isEmpty()
                            ? new MainActivity.Screen(() -> a.detail(site, video))
                            : a.back.pop();
        if (a.current != null) {
            a.detail(site, video, video);
            a.restore(a.current);
        }
    }

    static void leavePlayback(MainActivity a) {
        a.playerLocked = false;
        if (a.hideLockButton != null) {
            a.ui.removeCallbacks(a.hideLockButton);
            a.hideLockButton = null;
        }
        if (!a.isTvDevice()) {
            a.applyMobileSystemBars(false);
            a.setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER);
            if (a.usableWidth > a.usableHeight && a.usableHeight > 0) {
                int tmp = a.usableWidth;
                a.usableWidth = a.usableHeight;
                a.usableHeight = tmp;
            }
        }
        if (!a.back.isEmpty()) {
            releasePlayer(a);
            clearPendingHistoryMigration(a);
            a.current = a.back.pop();
            a.renderReturn(a.current);
            a.restore(a.current);
        } else {
            clearPendingHistoryMigration(a);
            a.onBackPressed();
        }
    }

    static void minimizePlayback(MainActivity a) {
        if (a.playbackControls == null || a.miniMode) return;
        if (a.playerLocked) {
            setPlayerLocked(a, false);
        }
        a.miniMode = true;
        showControls(a, false);
        if (a.playerChrome != null) a.playerChrome.syncClockViews();
        a.playbackControls.subtitle.setVisibility(View.GONE);
        a.playbackControls.danmaku.setVisibility(View.GONE);
        a.miniDetails = new MiniDetails(a);
    }

    static void expandPlayback(MainActivity a) {
        if (!a.miniMode) return;
        a.miniMode = false;
        if (a.miniDetails != null) {
            a.miniDetails.remove();
            a.miniDetails = null;
        }
        UiCompat.setClipToOutline(a.playbackLayer, false);
        a.playbackLayer.setLayoutParams(new FrameLayout.LayoutParams(-1, -1));
        a.playbackControls.subtitle.setVisibility(View.VISIBLE);
        a.playbackControls.danmaku.setVisibility(View.VISIBLE);
        if (a.playerChrome != null) a.playerChrome.syncClockViews();
        a.playbackLayer.post(
                () -> {
                    if (a.playbackControls != null) {
                        a.playbackControls.resize(
                                a.playbackControls.videoWidth, a.playbackControls.videoHeight);
                        showControls(a, true);
                        a.playbackControls.timeline.requestFocus();
                    }
                });
    }

    static void playerPage(MainActivity a, Cms.Site s, Cms.Video v, Cms.Episode ep) {
        ep.url = LocalProxy.rewrite(ep.url);
        final DanmuOwnership.RequestContext pageDanmuCtx =
                ensureDanmuContext(
                        a, s, v, a.activeLine, a.activeEpisode != null ? a.activeEpisode : ep);
        try {
            String dm = ep.media.optString("danmaku");
            if (dm != null && !dm.isEmpty()) {
                ep.media.put("danmaku", LocalProxy.rewrite(dm));
            } else {
                String recentDm = CspEngine.consumeRecentPluginDanmaku(pageDanmuCtx, 25000L);
                if (!recentDm.isEmpty()) {
                    ep.media.put("danmaku", LocalProxy.rewrite(recentDm));
                    ep.media.put("_danmakuSource", "plugin");
                }
            }
            JSONArray subtitles = ep.media.optJSONArray("subtitles");
            if (subtitles != null)
                for (int i = 0; i < subtitles.length(); i++) {
                    JSONObject sub = subtitles.optJSONObject(i);
                    if (sub != null) sub.put("url", LocalProxy.rewrite(sub.optString("url")));
                }
        } catch (Exception ignored) {
        }
        final boolean keepLocked =
                !a.isTvDevice()
                        && a.current != null
                        && a.current.player
                        && !a.miniMode
                        && a.playerLocked;
        JSONObject embySession = ep.media.optJSONObject("embySession");
        com.pilipala.emby.EmbyLibrary.Reporter retained = a.embyReporter;
        if (retained != null && retained.matches(embySession)) a.embyReporter = null;
        else retained = null;
        releasePlayer(a, true);
        a.activeDanmuContext = pageDanmuCtx;
        try {
            android.app.ActivityManager am =
                    (android.app.ActivityManager)
                            a.getSystemService(android.content.Context.ACTIVITY_SERVICE);
            if (am != null
                    && ((android.os.Build.VERSION.SDK_INT >= 19 && am.isLowRamDevice())
                            || am.getMemoryClass() <= 128)) {
                a.images.evictAll();
                ImmersivePoster.trimMemory(
                        android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW);
            }
        } catch (Throwable ignored) {
        }
        a.embyReporter = retained;
        a.playingBookmark = null;
        a.deferPlayingBookmarkUntilMigrationCommit = false;
        if (s != null
                && s.api != null
                && s.api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)
                && embySession != null) {
            try {
                if (a.embyReporter == null)
                    a.embyReporter =
                            com.pilipala.emby.EmbyAccounts.open(a, s.api).track(embySession);
            } catch (Exception ignored) {
                // Check-in setup must not prevent an already resolved video from playing.
            }
        }
        String bookmarkId =
                v != null && v.id != null && !v.id.trim().isEmpty()
                        ? v.id.trim()
                        : (a.activeEpisode != null
                                        && a.activeEpisode.url != null
                                        && !a.activeEpisode.url.trim().isEmpty()
                                ? a.activeEpisode.url.trim()
                                : (v != null && v.title != null ? v.title.trim() : ""));
        if (v != null && !bookmarkId.isEmpty() && (v.id == null || v.id.trim().isEmpty())) {
            v.id = bookmarkId;
        }
        clearMismatchedHistoryMigration(a, s, v);
        if (s.key != null
                && !s.key.equals("live")
                && !bookmarkId.isEmpty()
                && a.activeLine != null
                && a.activeEpisode != null) {
            WatchHistory.Entry saved = lookupSavedBookmark(a, s, v, a.activeLine, a.activeEpisode);
            if (saved != null
                    && saved.site != null
                    && !s.key.equals(saved.site)
                    && a.pendingHistoryMigration == null) {
                a.pendingHistoryMigration =
                        new WatchHistory.PendingMigration(saved.key(), s.key, bookmarkId);
            }
            int initialResume =
                    a.resumeAt > 0
                            ? a.resumeAt
                            : (a.resumeAt < 0 ? 0 : (saved != null ? saved.resume() : 0));
            a.playingBookmark = new WatchHistory.Entry();
            a.playingBookmark.site = s.key;
            a.playingBookmark.id = bookmarkId;
            a.playingBookmark.title = v.title;
            a.playingBookmark.poster = v.poster;
            a.playingBookmark.line = a.activeLine.name;
            a.playingBookmark.episode = a.activeEpisode.name;
            String shareCand =
                    (v.id != null && (v.id.startsWith("push://") || v.id.contains("://")))
                            ? v.id.trim()
                            : (a.activeEpisode != null
                                            && a.activeEpisode.url != null
                                            && a.activeEpisode.url.startsWith("push://")
                                    ? a.activeEpisode.url.trim()
                                    : "");
            a.playingBookmark.shareUrl = shareCand;
            a.playingBookmark.index = a.activeLine.episodes.indexOf(a.activeEpisode);
            a.playingBookmark.position = Math.max(0, initialResume);
            a.playingBookmark.duration = saved != null ? Math.max(0, saved.duration) : 0;
            a.playingBookmark.updated = System.currentTimeMillis();
            a.lastBookmarkSave = a.playingBookmark.updated;
            final WatchHistory.Entry snapshot = cloneBookmark(a.playingBookmark);
            boolean deferForMigration =
                    a.pendingHistoryMigration != null
                            && a.pendingHistoryMigration.matchesTarget(s.key, bookmarkId);
            a.deferPlayingBookmarkUntilMigrationCommit = deferForMigration;
            if (a.prefs != null && snapshot != null && !deferForMigration) {
                WatchHistory.enqueueUpsert(a.historyPersistence(), snapshot);
                CloudSyncDialog.scheduleAutoPush(a, false);
            }
        }
        a.generation++;
        final int ticket = a.generation;
        final int sessionId = ++a.playbackSessionId;
        a.blackScreenRecoveryCount = ep.media.optInt("_blackScreenRecoveryCount", 0);
        a.playbackOutputState = null;
        a.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (!a.isTvDevice()) {
            a.applyMobileSystemBars(true);
            if (!keepLocked) {
                a.setRequestedOrientation(
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
            } else if (android.os.Build.VERSION.SDK_INT >= 18) {
                a.setRequestedOrientation(
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LOCKED);
            }
        }
        a.root = new FrameLayout(a);
        // Disable Android API 26+ defaultFocusHighlight and attach an explicit state_focused
        // pure-black background so a.root.requestFocus() when hiding TV controls never paints a
        // full-screen translucent gray highlight over letterbox bars or the video SurfaceView.
        UiCompat.setBackground(a.root, UiCompat.createFocusSafeColorBackground(Color.BLACK));
        UiCompat.setDefaultFocusHighlightEnabled(a.root, false);
        a.root.setFocusable(true);
        a.root.setFocusableInTouchMode(true);
        a.root.setTag("player-surface");
        a.scroll = null;
        boolean softwareVideoActive =
                a.prefs.getInt(Prefs.DECODER_MODE, 0) == 2
                        || (ep.media.optBoolean("_softwareFallback")
                                && ep.media.optInt("_fallbackMode", 2) == 2);
        boolean useCompatibleOutput =
                a.prefs.getInt(Prefs.VIDEO_OUTPUT, 0) == 1
                        || softwareVideoActive
                        || ep.media.optBoolean("_videoOutputFallback");
        VideoOutput surface = new VideoOutput(a, useCompatibleOutput);
        VideoOutput.setWindowHdrMode(a, false);
        a.playbackLayer = new FrameLayout(a);
        UiCompat.setDefaultFocusHighlightEnabled(a.playbackLayer, false);
        a.playbackLayer.setTag("playback-layer");
        a.root.addView(a.playbackLayer, new FrameLayout.LayoutParams(-1, -1));
        a.playbackLayer.addView(surface, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
        a.playerChrome = new PlayerChrome(a, v, ep, "live".equals(s.key));
        if (!a.isTvDevice()) {
            final PlayerChrome chrome = a.playerChrome;
            a.root.setOnApplyWindowInsetsListener(
                    (view, insets) -> {
                        int left = insets.getSystemWindowInsetLeft();
                        int top = insets.getSystemWindowInsetTop();
                        int right = insets.getSystemWindowInsetRight();
                        int bottom = insets.getSystemWindowInsetBottom();
                        if (android.os.Build.VERSION.SDK_INT >= 30) {
                            android.graphics.Insets safe =
                                    insets.getInsets(
                                            android.view.WindowInsets.Type.systemBars()
                                                    | android.view.WindowInsets.Type.displayCutout()
                                                    | android.view.WindowInsets.Type
                                                            .systemGestures());
                            left = safe.left;
                            top = safe.top;
                            right = safe.right;
                            android.graphics.Insets navigation =
                                    insets.getInsetsIgnoringVisibility(
                                            android.view.WindowInsets.Type.navigationBars());
                            left = Math.max(left, navigation.left);
                            right = Math.max(right, navigation.right);
                            bottom = Math.max(safe.bottom, navigation.bottom);
                        } else if (android.os.Build.VERSION.SDK_INT >= 28
                                && insets.getDisplayCutout() != null) {
                            android.view.DisplayCutout cutout = insets.getDisplayCutout();
                            left = Math.max(left, cutout.getSafeInsetLeft());
                            top = Math.max(top, cutout.getSafeInsetTop());
                            right = Math.max(right, cutout.getSafeInsetRight());
                            bottom = Math.max(bottom, cutout.getSafeInsetBottom());
                        }
                        chrome.safeInsets(left, top, right, bottom);
                        return insets;
                    });
            a.root.requestApplyInsets();
        }
        a.playbackControls =
                new PlaybackControls(
                        a, a.playerChrome.dock, a.playerChrome.progress, surface, s, v, ep);
        if (!a.isTvDevice()) TouchPlayerGesture.attach(a, surface);
        final PlaybackControls controls = a.playbackControls;
        a.root.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    int w = r - l, h = b - t;
                    if (w > 0 && h > 0) {
                        if (w != a.usableWidth || h != a.usableHeight) {
                            a.usableWidth = w;
                            a.usableHeight = h;
                            view.requestApplyInsets();
                            view.post(
                                    () -> {
                                        if (ticket != a.generation || a.isFinishing()) return;
                                        if (a.playerChrome != null) a.playerChrome.relayout();
                                        if (a.playbackControls != null) {
                                            a.playbackControls.resize(
                                                    a.playbackControls.videoWidth,
                                                    a.playbackControls.videoHeight);
                                        }
                                    });
                        }
                    }
                });
        a.presentRoot(a.root, false);
        if (!a.isTvDevice()) a.root.requestApplyInsets();
        final boolean useSystemBackend =
                !ep.media.optBoolean("_systemErrorFallback")
                        && (ep.media.optBoolean("_systemFallback")
                                || a.prefs.getInt(Prefs.PLAYER_ENGINE, 0) == 1);
        final Surface[] activeSurface = new Surface[1];
        final boolean[] initDispatched = new boolean[1];
        final int[] latestVideoWidth = new int[1];
        final int[] latestVideoHeight = new int[1];
        final boolean[] liveSuccessRecorded = new boolean[1];
        final Runnable launchPlayerInit =
                () -> {
                    if (initDispatched[0]
                            || ticket != a.generation
                            || sessionId != a.playbackSessionId) return;
                    initDispatched[0] = true;
                    PLAYER_INIT.execute(
                            () -> {
                                MoviePlayer candidate = null;
                                final boolean[] mpvBusyFallback = new boolean[1];
                                final MpvPlayer.CancelCheck mpvCancelled =
                                        () ->
                                                ticket != a.generation
                                                        || sessionId != a.playbackSessionId
                                                        || a.isFinishing();
                                try {
                                    if (mpvCancelled.isCancelled()) return;
                                    Map<String, String> mediaHeaders =
                                            Cms.inheritedHeaders(s.api, ep.url, s.headers);
                                    Cms.mergeHeaders(mediaHeaders, ep.headers);
                                    int engPref = a.prefs.getInt(Prefs.PLAYER_ENGINE, 0);
                                    JSONObject drmObj = ep.media.optJSONObject("drm");
                                    String drmScheme =
                                            drmObj == null
                                                    ? ep.media.optString("drmScheme", "")
                                                    : drmObj.optString(
                                                            "scheme", drmObj.optString("type", ""));
                                    boolean useMpv =
                                            !ep.media.optBoolean("_systemFallback")
                                                    && !ep.media.optBoolean("_softwareFallback")
                                                    && !ep.media.optBoolean("_mpvFallback")
                                                    && drmScheme.isEmpty()
                                                    && engPref == 3
                                                    && MpvPlayer.isAvailable();
                                    boolean preferIjk =
                                            engPref == 2
                                                    || (engPref == 0
                                                            && (ep.media.optBoolean("live")
                                                                    || ep.media.optInt(
                                                                                    "playerType", 0)
                                                                            == 2));
                                    if (!ep.media.optBoolean("_systemErrorFallback")
                                            && (ep.media.optBoolean("_systemFallback")
                                                    || engPref == 1)) {
                                        candidate = new SystemPlayer(a);
                                    } else if (useMpv) {
                                        try {
                                            candidate =
                                                    MpvPlayer.createWithBudget(
                                                            a,
                                                            MpvPlayer
                                                                    .DEFAULT_DESTROY_WAIT_BUDGET_MS,
                                                            mpvCancelled);
                                        } catch (InterruptedException cancelled) {
                                            Thread.currentThread().interrupt();
                                            return;
                                        } catch (MpvPlayer.MpvBusyTimeoutException busyTimeout) {
                                            AppLog.w(
                                                    "PlaybackController",
                                                    "MPV destroy timed out, single fallback to"
                                                            + " Media3",
                                                    busyTimeout);
                                            try {
                                                ep.media.put("_mpvFallback", true);
                                            } catch (Exception ignored) {
                                            }
                                            mpvBusyFallback[0] = true;
                                            candidate = new MoviePlayer(a);
                                        } catch (Exception mpvInitErr) {
                                            AppLog.w(
                                                    "PlaybackController",
                                                    "MPV init failed, falling back to Media3",
                                                    mpvInitErr);
                                            try {
                                                ep.media.put("_mpvFallback", true);
                                            } catch (Exception ignored) {
                                            }
                                            candidate = new MoviePlayer(a);
                                        }
                                    } else if (ep.media.optBoolean("_softwareFallback")) {
                                        candidate =
                                                new MoviePlayer(
                                                        a,
                                                        ep.media.optInt("_fallbackMode", 2),
                                                        preferIjk);
                                    } else if (preferIjk) {
                                        candidate = MoviePlayer.createIjk(a);
                                    } else {
                                        candidate = new MoviePlayer(a);
                                    }
                                    if (mpvCancelled.isCancelled()) {
                                        safeReleasePlayer(candidate);
                                        return;
                                    }
                                    String rawPlayUrl =
                                            Cms.isHttp(ep.url) ? Cms.normalizeHttp(ep.url) : ep.url;
                                    String playUrl = rawPlayUrl;
                                    boolean isLiveStream = ep.media.optBoolean("live");
                                    String declaredMime = MediaOptions.mime(ep.media);
                                    if (!isLiveStream
                                            && a.prefs.getBoolean(Prefs.HLS_PROXY_ENABLED, true)
                                            && HlsStreamProxy.looksLikeHls(
                                                    rawPlayUrl, declaredMime)) {
                                        try {
                                            SourceController.ensureProxy(a, a.config);
                                            playUrl =
                                                    HlsStreamProxy.register(
                                                            rawPlayUrl,
                                                            mediaHeaders,
                                                            a.prefs.getBoolean(
                                                                    Prefs.HLS_AD_STRIP, false));
                                        } catch (Exception proxyErr) {
                                            AppLog.w(
                                                    "PlaybackController",
                                                    "HLS proxy fallback to direct URL",
                                                    proxyErr);
                                        }
                                    } else if (!isLiveStream) {
                                        int cacheMb = a.prefs.getInt(Prefs.MEDIA_CACHE_MB, 256);
                                        if (cacheMb > 0
                                                && MediaDiskCache.isCacheableDirectUrl(
                                                        rawPlayUrl, declaredMime)) {
                                            try {
                                                SourceController.ensureProxy(a, a.config);
                                                playUrl =
                                                        MediaDiskCache.getInstance(
                                                                        a.getCacheDir(), cacheMb)
                                                                .register(rawPlayUrl, mediaHeaders);
                                            } catch (Exception cacheErr) {
                                                AppLog.w(
                                                        "PlaybackController",
                                                        "Disk cache proxy fallback to direct URL",
                                                        cacheErr);
                                            }
                                        }
                                    }
                                    candidate.configureDefaultAudio();
                                    candidate.setDataSource(a, Uri.parse(playUrl), mediaHeaders);
                                    try {
                                        if (ep.name != null
                                                && !ep.name.isEmpty()
                                                && ep.media
                                                        .optString("_episodeName", "")
                                                        .isEmpty()) {
                                            ep.media.put("_episodeName", ep.name);
                                        }
                                        if (a.activeLine != null
                                                && a.activeLine.name != null
                                                && !a.activeLine.name.isEmpty()
                                                && ep.media.optString("_lineName", "").isEmpty()) {
                                            ep.media.put("_lineName", a.activeLine.name);
                                        }
                                    } catch (Exception ignored) {
                                    }
                                    candidate.setOptions(ep.media);
                                    final MoviePlayer ready = candidate;
                                    final boolean notifiedMpvFallback = mpvBusyFallback[0];
                                    a.ui.post(
                                            () -> {
                                                if (ticket != a.generation
                                                        || sessionId != a.playbackSessionId
                                                        || a.isFinishing()) {
                                                    safeReleasePlayer(ready);
                                                    return;
                                                }
                                                if (useSystemBackend
                                                        && (activeSurface[0] == null
                                                                || !activeSurface[0].isValid())) {
                                                    initDispatched[0] = false;
                                                    safeReleasePlayer(ready);
                                                    return;
                                                }
                                                final PlaybackOutputState outputState =
                                                        new PlaybackOutputState(
                                                                sessionId,
                                                                ready instanceof MpvPlayer,
                                                                a.foreground);
                                                a.player = ready;
                                                a.playbackOutputState = outputState;
                                                if (notifiedMpvFallback) {
                                                    a.toast("旧 MPV 释放较慢，本次已自动切换 Media3 续播");
                                                }
                                                try {
                                                    surface.setExternalNativeRenderer(
                                                            ready instanceof MpvPlayer);
                                                    if (activeSurface[0] != null
                                                            && activeSurface[0].isValid()) {
                                                        outputState.onSurfaceAttached(
                                                                System.identityHashCode(
                                                                        activeSurface[0]),
                                                                true,
                                                                SystemClock.elapsedRealtime());
                                                        ready.setSurface(activeSurface[0]);
                                                        if (surface.getWidth() > 0
                                                                && surface.getHeight() > 0) {
                                                            ready.setSurfaceSize(
                                                                    surface.getWidth(),
                                                                    surface.getHeight());
                                                        }
                                                    }
                                                    ready.bindSubtitles(
                                                            controls.subtitle,
                                                            text -> {
                                                                if (ticket == a.generation
                                                                        && sessionId
                                                                                == a.playbackSessionId
                                                                        && a.player == ready) {
                                                                    controls.lastSubtitle =
                                                                            String.valueOf(text);
                                                                }
                                                            });
                                                    ready.setOnTextTracksChangedListener(
                                                            () -> {
                                                                if (ticket == a.generation
                                                                        && sessionId
                                                                                == a.playbackSessionId
                                                                        && a.player == ready
                                                                        && a.playbackControls
                                                                                == controls) {
                                                                    controls
                                                                            .onPlayerTextTracksChanged();
                                                                }
                                                            });
                                                    ready.setOnAudioTracksChangedListener(
                                                            () -> {
                                                                if (ticket == a.generation
                                                                        && sessionId
                                                                                == a.playbackSessionId
                                                                        && a.player == ready
                                                                        && a.playbackControls
                                                                                == controls) {
                                                                    controls
                                                                            .onPlayerAudioTracksChanged();
                                                                }
                                                            });
                                                    ready.setOnHdrChangedListener(
                                                            hdr -> {
                                                                if (ticket != a.generation
                                                                        || sessionId
                                                                                != a.playbackSessionId
                                                                        || a.player != ready
                                                                        || a.isFinishing()) return;
                                                                boolean hdrSurface =
                                                                        hdr
                                                                                && surface
                                                                                        .usesSurfaceView();
                                                                surface.setHdrContent(hdr);
                                                                VideoOutput.setWindowHdrMode(
                                                                        a, hdrSurface);
                                                                if (a.playerChrome != null) {
                                                                    a.playerChrome
                                                                            .setHdrSurfaceActive(
                                                                                    hdrSurface);
                                                                }
                                                            });
                                                    ready.setOnBufferingListener(
                                                            (buf, pct) -> {
                                                                if (ticket != a.generation
                                                                        || sessionId
                                                                                != a.playbackSessionId
                                                                        || a.player != ready
                                                                        || a.isFinishing()) return;
                                                                outputState.onBufferingChanged(
                                                                        buf,
                                                                        SystemClock
                                                                                .elapsedRealtime());
                                                                if (a.playerChrome != null) {
                                                                    a.playerChrome.setBuffering(
                                                                            buf, pct);
                                                                }
                                                            });
                                                    ready.setOnVideoOutputListener(
                                                            new MoviePlayer
                                                                    .OnVideoOutputListener() {
                                                                @Override
                                                                public void onFileOpened(
                                                                        MoviePlayer mp) {
                                                                    if (ticket != a.generation
                                                                            || sessionId
                                                                                    != a.playbackSessionId
                                                                            || a.player != ready
                                                                            || a.isFinishing())
                                                                        return;
                                                                    outputState.onFileOpened();
                                                                }

                                                                @Override
                                                                public void onVideoTrackPresence(
                                                                        MoviePlayer mp,
                                                                        boolean hasVideoTrack) {
                                                                    if (ticket != a.generation
                                                                            || sessionId
                                                                                    != a.playbackSessionId
                                                                            || a.player != ready
                                                                            || a.isFinishing())
                                                                        return;
                                                                    outputState
                                                                            .onVideoTrackPresence(
                                                                                    hasVideoTrack,
                                                                                    SystemClock
                                                                                            .elapsedRealtime());
                                                                    syncChromeLoadingForOutputState(
                                                                            a,
                                                                            ready,
                                                                            outputState,
                                                                            activeSurface[0]);
                                                                    maybeRecordLiveSuccess(
                                                                            a,
                                                                            s,
                                                                            ep,
                                                                            ready,
                                                                            outputState,
                                                                            latestVideoWidth[0],
                                                                            latestVideoHeight[0],
                                                                            liveSuccessRecorded);
                                                                }

                                                                @Override
                                                                public void onFirstFrameRendered(
                                                                        MoviePlayer mp,
                                                                        Surface renderedSurface,
                                                                        long firstFrameMs) {
                                                                    if (ticket != a.generation
                                                                            || sessionId
                                                                                    != a.playbackSessionId
                                                                            || a.player != ready
                                                                            || a.isFinishing())
                                                                        return;
                                                                    int surfId =
                                                                            renderedSurface == null
                                                                                    ? 0
                                                                                    : System
                                                                                            .identityHashCode(
                                                                                                    renderedSurface);
                                                                    outputState
                                                                            .onFirstFrameRendered(
                                                                                    surfId,
                                                                                    firstFrameMs);
                                                                    syncChromeLoadingForOutputState(
                                                                            a,
                                                                            ready,
                                                                            outputState,
                                                                            activeSurface[0]);
                                                                    maybeRecordLiveSuccess(
                                                                            a,
                                                                            s,
                                                                            ep,
                                                                            ready,
                                                                            outputState,
                                                                            latestVideoWidth[0],
                                                                            latestVideoHeight[0],
                                                                            liveSuccessRecorded);
                                                                }

                                                                @Override
                                                                public void
                                                                        onVideoOutputUnconfirmed(
                                                                                MoviePlayer mp,
                                                                                String reason) {
                                                                    if (ticket != a.generation
                                                                            || sessionId
                                                                                    != a.playbackSessionId
                                                                            || a.player != ready
                                                                            || a.isFinishing())
                                                                        return;
                                                                    outputState
                                                                            .onVideoOutputUnconfirmed();
                                                                    syncChromeLoadingForOutputState(
                                                                            a,
                                                                            ready,
                                                                            outputState,
                                                                            activeSurface[0]);
                                                                }

                                                                @Override
                                                                public void onVideoOutputConfigured(
                                                                        MoviePlayer mp,
                                                                        Surface surf,
                                                                        boolean configured) {
                                                                    if (ticket != a.generation
                                                                            || sessionId
                                                                                    != a.playbackSessionId
                                                                            || a.player != ready
                                                                            || a.isFinishing())
                                                                        return;
                                                                    int surfId =
                                                                            surf == null
                                                                                    ? 0
                                                                                    : System
                                                                                            .identityHashCode(
                                                                                                    surf);
                                                                    outputState.onMpvVoConfigured(
                                                                            surfId,
                                                                            configured,
                                                                            SystemClock
                                                                                    .elapsedRealtime());
                                                                    syncChromeLoadingForOutputState(
                                                                            a,
                                                                            ready,
                                                                            outputState,
                                                                            activeSurface[0]);
                                                                }
                                                            });
                                                    ready.setOnPreparedListener(
                                                            mp -> {
                                                                if (ticket != a.generation
                                                                        || sessionId
                                                                                != a.playbackSessionId
                                                                        || a.player != ready
                                                                        || a.isFinishing()) return;
                                                                a.prepared = true;
                                                                a.historyFallbackInFlight = false;
                                                                a.historyFallbackBookmark = null;
                                                                boolean hdr = mp.isHdrVideo();
                                                                boolean hdrSurface =
                                                                        hdr
                                                                                && surface
                                                                                        .usesSurfaceView();
                                                                surface.setHdrContent(hdr);
                                                                VideoOutput.setWindowHdrMode(
                                                                        a, hdrSurface);
                                                                outputState.onForegroundChanged(
                                                                        a.foreground,
                                                                        SystemClock
                                                                                .elapsedRealtime());
                                                                outputState.onDecoderPrepared(
                                                                        SystemClock
                                                                                .elapsedRealtime(),
                                                                        a.foreground);
                                                                Boolean knownVideoTrack =
                                                                        mp.hasConfirmedVideoTrack();
                                                                if (knownVideoTrack != null) {
                                                                    outputState
                                                                            .onVideoTrackPresence(
                                                                                    knownVideoTrack
                                                                                            .booleanValue(),
                                                                                    SystemClock
                                                                                            .elapsedRealtime());
                                                                }
                                                                if (a.playerChrome != null) {
                                                                    a.playerChrome
                                                                            .setHdrSurfaceActive(
                                                                                    hdrSurface);
                                                                }
                                                                syncChromeLoadingForOutputState(
                                                                        a,
                                                                        ready,
                                                                        outputState,
                                                                        activeSurface[0]);
                                                                maybeRecordLiveSuccess(
                                                                        a,
                                                                        s,
                                                                        ep,
                                                                        ready,
                                                                        outputState,
                                                                        latestVideoWidth[0],
                                                                        latestVideoHeight[0],
                                                                        liveSuccessRecorded);
                                                                a.playing = a.foreground;
                                                                try {
                                                                    if (a.foreground) mp.start();
                                                                    else mp.pause();
                                                                } catch (Exception startErr) {
                                                                    handleRecoverablePlaybackException(
                                                                            a,
                                                                            ticket,
                                                                            sessionId,
                                                                            ready,
                                                                            s,
                                                                            v,
                                                                            ep,
                                                                            "onPrepared.start",
                                                                            startErr);
                                                                    return;
                                                                }
                                                                controls.prepared();
                                                                if (!"live".equals(s.key)
                                                                        && a.foreground
                                                                        && !ep.media.optBoolean(
                                                                                "_dvColorWarned")) {
                                                                    String dvEpName =
                                                                            ep.media.optString(
                                                                                    "_episodeName",
                                                                                    ep.name != null
                                                                                            ? ep.name
                                                                                            : "");
                                                                    String dvLineName =
                                                                            ep.media.optString(
                                                                                    "_lineName",
                                                                                    a.activeLine
                                                                                                            != null
                                                                                                    && a.activeLine
                                                                                                                    .name
                                                                                                            != null
                                                                                            ? a.activeLine
                                                                                                    .name
                                                                                            : "");
                                                                    if (MoviePlayer
                                                                            .looksLikeTranscodedDolbyVisionColorRisk(
                                                                                    dvEpName,
                                                                                    dvLineName,
                                                                                    mp
                                                                                            .activeVideoMimeType())) {
                                                                        try {
                                                                            ep.media.put(
                                                                                    "_dvColorWarned",
                                                                                    true);
                                                                        } catch (
                                                                                Exception ignored) {
                                                                        }
                                                                        a.toast(
                                                                                "纯杜比视界片源经转码易偏色，建议选"
                                                                                        + " HDR10 / SDR"
                                                                                        + " / DV+HDR"
                                                                                        + " 片源");
                                                                    }
                                                                }
                                                                savePlaybackHistoryOnPrepared(a);
                                                                a.playStatus.setText(
                                                                        a.foreground
                                                                                ? ("live"
                                                                                                .equals(
                                                                                                        s.key)
                                                                                        ? (a
                                                                                                        .isTvDevice()
                                                                                                ? "正在直播 ·"
                                                                                                        + " 上下换台"
                                                                                                        + " · 菜单键工具条"
                                                                                                : "正在直播 ·"
                                                                                                        + " 单击显示选台工具栏")
                                                                                        : (a
                                                                                                        .isTvDevice()
                                                                                                ? "正在播放 ·"
                                                                                                        + " 确认暂停"
                                                                                                        + " · 上下键显示工具条"
                                                                                                : "正在播放 ·"
                                                                                                        + " 双击暂停"
                                                                                                        + " · 左右滑快进"
                                                                                                        + " · 上下滑调亮度音量"))
                                                                                : (a.isTvDevice()
                                                                                        ? "已暂停 ·"
                                                                                                + " 按确认继续"
                                                                                        : "已暂停 ·"
                                                                                                + " 双击继续"));
                                                                clock(
                                                                        a,
                                                                        ticket,
                                                                        sessionId,
                                                                        surface,
                                                                        activeSurface,
                                                                        s,
                                                                        v,
                                                                        ep);
                                                                if (a.changingMiniEpisode) {
                                                                    a.changingMiniEpisode = false;
                                                                    minimizePlayback(a);
                                                                } else if (a.foreground) {
                                                                    if (a.playerLocked) {
                                                                        showControls(a, false);
                                                                    } else if ("live"
                                                                            .equals(s.key)) {
                                                                        showControls(a, false);
                                                                        a.toast(
                                                                                "频道 "
                                                                                        + (a.liveSession
                                                                                                        == null
                                                                                                ? ""
                                                                                                : (a.liveSession
                                                                                                                        .index
                                                                                                                + 1)
                                                                                                        + " · ")
                                                                                        + v.title);
                                                                    } else scheduleHide(a);
                                                                }
                                                            });
                                                    ready.setOnVideoSizeChangedListener(
                                                            (mp, w, h) -> {
                                                                if (ticket == a.generation
                                                                        && sessionId
                                                                                == a.playbackSessionId
                                                                        && a.player == ready) {
                                                                    latestVideoWidth[0] = w;
                                                                    latestVideoHeight[0] = h;
                                                                    if (w > 0 && h > 0) {
                                                                        outputState
                                                                                .onVideoTrackPresence(
                                                                                        true,
                                                                                        SystemClock
                                                                                                .elapsedRealtime());
                                                                    }
                                                                    if (w > 0
                                                                            && h > 0
                                                                            && mp.isHdrVideo()) {
                                                                        boolean hdrSurface =
                                                                                surface
                                                                                        .usesSurfaceView();
                                                                        surface.setHdrContent(true);
                                                                        VideoOutput
                                                                                .setWindowHdrMode(
                                                                                        a,
                                                                                        hdrSurface);
                                                                        if (a.playerChrome
                                                                                != null) {
                                                                            a.playerChrome
                                                                                    .setHdrSurfaceActive(
                                                                                            hdrSurface);
                                                                        }
                                                                    }
                                                                    controls.resize(w, h);
                                                                    maybeRecordLiveSuccess(
                                                                            a,
                                                                            s,
                                                                            ep,
                                                                            ready,
                                                                            outputState,
                                                                            w,
                                                                            h,
                                                                            liveSuccessRecorded);
                                                                }
                                                            });
                                                    ready.setOnCompletionListener(
                                                            mp -> {
                                                                if (ticket != a.generation
                                                                        || sessionId
                                                                                != a.playbackSessionId
                                                                        || a.player != ready)
                                                                    return;
                                                                outputState.onCompleted();
                                                                if (a.markerHost != null)
                                                                    a.markerHost.abort();
                                                                int curPos =
                                                                        ready.getCurrentPosition();
                                                                int curDur = ready.getDuration();
                                                                if (curDur <= 0
                                                                        && a.playingBookmark != null
                                                                        && a.playingBookmark
                                                                                        .duration
                                                                                > 0) {
                                                                    curDur =
                                                                            a.playingBookmark
                                                                                    .duration;
                                                                }
                                                                int eofRetries =
                                                                        Math.max(
                                                                                ep.media.optInt(
                                                                                        "_eofReconnectCount",
                                                                                        0),
                                                                                a.activeEpisode
                                                                                                        != null
                                                                                                && a.activeEpisode
                                                                                                                .media
                                                                                                        != null
                                                                                        ? a
                                                                                                .activeEpisode
                                                                                                .media
                                                                                                .optInt(
                                                                                                        "_eofReconnectCount",
                                                                                                        0)
                                                                                        : 0);
                                                                if (MoviePlayer
                                                                                .isPrematureProgressiveEnd(
                                                                                        "live"
                                                                                                .equals(
                                                                                                        s.key),
                                                                                        curPos,
                                                                                        curDur)
                                                                        && eofRetries < 3
                                                                        && a.activeLine != null
                                                                        && a.activeEpisode
                                                                                != null) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_eofReconnectCount",
                                                                                eofRetries + 1);
                                                                        if (a.activeEpisode.media
                                                                                != null) {
                                                                            a.activeEpisode.media
                                                                                    .put(
                                                                                            "_eofReconnectCount",
                                                                                            eofRetries
                                                                                                    + 1);
                                                                        }
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    a.resumeAt = curPos;
                                                                    a.toast("网络波动，正在断点续连…");
                                                                    a.playStatus.setText(
                                                                            "网络中断，正在断点续连…");
                                                                    final Cms.Line retryLine =
                                                                            a.activeLine;
                                                                    final Cms.Episode retryEp =
                                                                            a.activeEpisode;
                                                                    a.ui.postDelayed(
                                                                            () -> {
                                                                                if (ticket
                                                                                                == a.generation
                                                                                        && !a
                                                                                                .isFinishing()) {
                                                                                    resolvePlayer(
                                                                                            a, s, v,
                                                                                            retryLine,
                                                                                            retryEp);
                                                                                }
                                                                            },
                                                                            450L);
                                                                    return;
                                                                }
                                                                if (a.playingBookmark != null) {
                                                                    if (curDur > 0) {
                                                                        a.playingBookmark.duration =
                                                                                curDur;
                                                                        a.playingBookmark.position =
                                                                                Math.max(
                                                                                        a.playingBookmark
                                                                                                .position,
                                                                                        curDur);
                                                                    } else if (a.playingBookmark
                                                                                    .position
                                                                            <= 0) {
                                                                        a.playingBookmark.position =
                                                                                1000;
                                                                    }
                                                                }
                                                                if (a.pendingHistoryMigration
                                                                                != null
                                                                        && a.pendingHistoryMigration
                                                                                .matchesSavedBookmark(
                                                                                        a.playingBookmark)) {
                                                                    tryCommitPendingHistoryMigration(
                                                                            a, true);
                                                                } else {
                                                                    savePlaybackHistory(a, true);
                                                                }
                                                                a.playing = false;
                                                                stopEmbySession(a);
                                                                a.playStatus.setText("播放结束");
                                                                controls.completed();
                                                            });
                                                    ready.setOnErrorListener(
                                                            (mp, what, extra) -> {
                                                                if (ticket != a.generation
                                                                        || sessionId
                                                                                != a.playbackSessionId
                                                                        || a.player != ready)
                                                                    return true;
                                                                if (a.markerHost != null)
                                                                    a.markerHost.abort();
                                                                int currentPos =
                                                                        mp.getCurrentPosition();
                                                                int preservedResumePos =
                                                                        currentPos > 0
                                                                                ? currentPos
                                                                                : Math.max(
                                                                                        0,
                                                                                        a.resumeAt);
                                                                if (a.activeLine != null
                                                                        && a.activeEpisode != null
                                                                        && shouldFreshReResolveOriginalLine(
                                                                                s,
                                                                                a.activeLine,
                                                                                ep,
                                                                                a.prepared,
                                                                                currentPos,
                                                                                a.historyFallbackBookmark)
                                                                        && (a.activeEpisode.media
                                                                                        == null
                                                                                || !a.activeEpisode
                                                                                        .media
                                                                                        .optBoolean(
                                                                                                "_freshReResolve",
                                                                                                false))) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_freshReResolve",
                                                                                true);
                                                                        if (a.activeEpisode.media
                                                                                != null) {
                                                                            a.activeEpisode.media
                                                                                    .put(
                                                                                            "_freshReResolve",
                                                                                            true);
                                                                        }
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    triggerFreshOriginalLineReResolve(
                                                                            a,
                                                                            ticket,
                                                                            s,
                                                                            v,
                                                                            a.activeLine,
                                                                            a.activeEpisode,
                                                                            preservedResumePos);
                                                                    return true;
                                                                }
                                                                if (!"live".equals(s.key)
                                                                        && what >= 2000
                                                                        && what < 3000
                                                                        && currentPos > 0
                                                                        && a.activeLine != null
                                                                        && a.activeEpisode
                                                                                != null) {
                                                                    int ioRetries =
                                                                            Math.max(
                                                                                    ep.media.optInt(
                                                                                            "_ioReconnectCount",
                                                                                            0),
                                                                                    a.activeEpisode
                                                                                                            .media
                                                                                                    != null
                                                                                            ? a
                                                                                                    .activeEpisode
                                                                                                    .media
                                                                                                    .optInt(
                                                                                                            "_ioReconnectCount",
                                                                                                            0)
                                                                                            : 0);
                                                                    if (ioRetries < 2) {
                                                                        try {
                                                                            ep.media.put(
                                                                                    "_ioReconnectCount",
                                                                                    ioRetries + 1);
                                                                            if (a.activeEpisode
                                                                                            .media
                                                                                    != null) {
                                                                                a.activeEpisode
                                                                                        .media.put(
                                                                                        "_ioReconnectCount",
                                                                                        ioRetries
                                                                                                + 1);
                                                                            }
                                                                        } catch (
                                                                                Exception ignored) {
                                                                        }
                                                                        a.resumeAt =
                                                                                preservedResumePos;
                                                                        a.toast(
                                                                                "连接波动，正在刷新播放链接并续播…");
                                                                        a.playStatus.setText(
                                                                                "连接波动，正在刷新播放链接…");
                                                                        final Cms.Line retryLine =
                                                                                a.activeLine;
                                                                        final Cms.Episode retryEp =
                                                                                a.activeEpisode;
                                                                        a.ui.postDelayed(
                                                                                () -> {
                                                                                    if (ticket
                                                                                                    == a.generation
                                                                                            && !a
                                                                                                    .isFinishing()) {
                                                                                        resolvePlayer(
                                                                                                a,
                                                                                                s,
                                                                                                v,
                                                                                                retryLine,
                                                                                                retryEp);
                                                                                    }
                                                                                },
                                                                                500L);
                                                                        return true;
                                                                    }
                                                                }
                                                                if (mp instanceof MpvPlayer
                                                                        && !ep.media.optBoolean(
                                                                                "_mpvFallback")) {
                                                                    try {
                                                                        ep.media.put(
                                                                                "_mpvFallback",
                                                                                true);
                                                                    } catch (Exception ignored) {
                                                                    }
                                                                    a.resumeAt = preservedResumePos;
                                                                    a.playStatus.setText(
                                                                            "MPV 播放异常，正在切换 Media3"
                                                                                    + " 内核…");
                                                                    a.ui.post(
                                                                            () -> {
                                                                                if (ticket
                                                                                        == a.generation)
                                                                                    playerPage(
                                                                                            a, s, v,
                                                                                            ep);
                                                                            });
                                                                    return true;
                                                                }
                                                                if (PlaybackFailure.decoderFallback(
                                                                                what)
                                                                        && a.prefs.getInt(
                                                                                        Prefs
                                                                                                .DECODER_MODE,
                                                                                        0)
                                                                                == 0) {
                                                                    if (currentPos >= 5000
                                                                            && !ep.media.optBoolean(
                                                                                    "_hwRetry")
                                                                            && !ep.media.optBoolean(
                                                                                    "_softwareFallback")
                                                                            && !ep.media.optBoolean(
                                                                                    "_systemFallback")
                                                                            && !mp
                                                                                    .isUnsupportedDolbyVisionProfile5()) {
                                                                        try {
                                                                            ep.media.put(
                                                                                    "_hwRetry",
                                                                                    true);
                                                                        } catch (
                                                                                Exception ignored) {
                                                                        }
                                                                        a.resumeAt = currentPos;
                                                                        a.playStatus.setText(
                                                                                "解码器波动，正在重新初始化硬件解码…");
                                                                        a.ui.postDelayed(
                                                                                () -> {
                                                                                    if (ticket
                                                                                                    == a.generation
                                                                                            && !a
                                                                                                    .isFinishing()) {
                                                                                        playerPage(
                                                                                                a,
                                                                                                s,
                                                                                                v,
                                                                                                ep);
                                                                                    }
                                                                                },
                                                                                250L);
                                                                        return true;
                                                                    }
                                                                    if (!ep.media.optBoolean(
                                                                                    "_softwareFallback")
                                                                            && !mp
                                                                                    .isUnsupportedDolbyVisionProfile5()) {
                                                                        try {
                                                                            ep.media.put(
                                                                                    "_softwareFallback",
                                                                                    true);
                                                                            ep.media.put(
                                                                                    "_fallbackMode",
                                                                                    mp
                                                                                            .softFallbackMode());
                                                                        } catch (
                                                                                Exception ignored) {
                                                                        }
                                                                        a.resumeAt =
                                                                                preservedResumePos;
                                                                        a.playStatus.setText(
                                                                                "正在尝试内置软解码…");
                                                                        a.ui.post(
                                                                                () -> {
                                                                                    if (ticket
                                                                                            == a.generation)
                                                                                        playerPage(
                                                                                                a,
                                                                                                s,
                                                                                                v,
                                                                                                ep);
                                                                                });
                                                                        return true;
                                                                    }
                                                                    if (!ep.media.optBoolean(
                                                                                    "_systemFallback")
                                                                            && a.prefs.getInt(
                                                                                            Prefs
                                                                                                    .PLAYER_ENGINE,
                                                                                            0)
                                                                                    != 1) {
                                                                        try {
                                                                            ep.media.put(
                                                                                    "_systemFallback",
                                                                                    true);
                                                                        } catch (
                                                                                Exception ignored) {
                                                                        }
                                                                        a.resumeAt =
                                                                                preservedResumePos;
                                                                        a.playStatus.setText(
                                                                                "正在切换至系统硬件播放器…");
                                                                        a.ui.post(
                                                                                () -> {
                                                                                    if (ticket
                                                                                            == a.generation)
                                                                                        playerPage(
                                                                                                a,
                                                                                                s,
                                                                                                v,
                                                                                                ep);
                                                                                });
                                                                        return true;
                                                                    }
                                                                }
                                                                if (tryAdvanceQualityOrLiveStream(
                                                                        a, ticket, s, v, ep)) {
                                                                    return true;
                                                                }
                                                                if (v != null
                                                                        && v.lines != null
                                                                        && v.lines.size() > 1
                                                                        && a.activeLine != null) {
                                                                    int curLineIdx =
                                                                            v.lines.indexOf(
                                                                                    a.activeLine);
                                                                    int hopCount =
                                                                            ep.media.optInt(
                                                                                    "_lineHopCount",
                                                                                    0);
                                                                    if (curLineIdx >= 0
                                                                            && hopCount
                                                                                    < Math.min(
                                                                                            3,
                                                                                            v.lines
                                                                                                            .size()
                                                                                                    - 1)) {
                                                                        Cms.Line nextLine = null;
                                                                        Cms.Episode nextEp = null;
                                                                        for (int off = 1;
                                                                                off
                                                                                        < v.lines
                                                                                                .size();
                                                                                off++) {
                                                                            Cms.Line candLine =
                                                                                    v.lines.get(
                                                                                            (curLineIdx
                                                                                                            + off)
                                                                                                    % v
                                                                                                            .lines
                                                                                                            .size());
                                                                            if (candLine == null
                                                                                    || candLine
                                                                                            == a.activeLine) {
                                                                                continue;
                                                                            }
                                                                            Cms.Episode candEp =
                                                                                    findMatchingEpisode(
                                                                                            candLine,
                                                                                            a.activeLine,
                                                                                            a.activeEpisode
                                                                                                            != null
                                                                                                    ? a.activeEpisode
                                                                                                    : ep);
                                                                            if (candEp != null
                                                                                    && canAutoHopToLine(
                                                                                            s,
                                                                                            candLine,
                                                                                            candEp)) {
                                                                                nextLine = candLine;
                                                                                nextEp = candEp;
                                                                                break;
                                                                            }
                                                                        }
                                                                        if (nextEp != null
                                                                                && nextLine
                                                                                        != null) {
                                                                            try {
                                                                                nextEp.media.put(
                                                                                        "_lineHopCount",
                                                                                        hopCount
                                                                                                + 1);
                                                                            } catch (
                                                                                    Exception
                                                                                            ignored) {
                                                                            }
                                                                            a.resumeAt =
                                                                                    preservedResumePos;
                                                                            a.playStatus.setText(
                                                                                    "当前线路异常，正在切换至 "
                                                                                            + nextLine.name
                                                                                            + "…");
                                                                            final Cms.Line hopLine =
                                                                                    nextLine;
                                                                            final Cms.Episode
                                                                                    hopEp = nextEp;
                                                                            a.ui.post(
                                                                                    () -> {
                                                                                        if (ticket
                                                                                                == a.generation) {
                                                                                            rememberEpisodeOnBackStack(
                                                                                                    a,
                                                                                                    hopLine,
                                                                                                    hopEp);
                                                                                            resolvePlayer(
                                                                                                    a,
                                                                                                    s,
                                                                                                    v,
                                                                                                    hopLine,
                                                                                                    hopEp);
                                                                                        }
                                                                                    });
                                                                            return true;
                                                                        }
                                                                    }
                                                                }
                                                                if (tryHistoryCrossSourceFailover(
                                                                        a,
                                                                        s,
                                                                        v,
                                                                        Math.max(
                                                                                0,
                                                                                mp
                                                                                        .getCurrentPosition()),
                                                                        "原片源播放失败")) {
                                                                    return true;
                                                                }
                                                                stopEmbySession(a);
                                                                clearPendingHistoryMigration(a);
                                                                a.prepared = false;
                                                                a.playing = false;
                                                                String failMsg =
                                                                        mp.getFailureMessage(what)
                                                                                + "（"
                                                                                + what
                                                                                + "）";
                                                                if (a.playerChrome != null) {
                                                                    a.playerChrome.setTerminalError(
                                                                            failMsg);
                                                                } else if (a.playStatus != null) {
                                                                    a.playStatus.setText(failMsg);
                                                                }
                                                                showControls(a, true);
                                                                return true;
                                                            });
                                                    a.playStatus.setText("正在加载播放…");
                                                    ready.prepareAsync();
                                                    if ("live".equals(s.key)) {
                                                        JSONArray liveQs =
                                                                ep.media.optJSONArray("qualities");
                                                        int curQIdx =
                                                                ep.media.optInt("_qualityIdx", 0);
                                                        if (liveQs != null
                                                                && curQIdx + 1 < liveQs.length()) {
                                                            a.ui.postDelayed(
                                                                    () -> {
                                                                        if (ticket == a.generation
                                                                                && sessionId
                                                                                        == a.playbackSessionId
                                                                                && !a.prepared
                                                                                && a.current != null
                                                                                && a.current
                                                                                        .player) {
                                                                            tryAdvanceQualityOrLiveStream(
                                                                                    a, ticket, s, v,
                                                                                    ep);
                                                                        }
                                                                    },
                                                                    7500L);
                                                        }
                                                    }
                                                } catch (Exception attachErr) {
                                                    handleRecoverablePlaybackException(
                                                            a,
                                                            ticket,
                                                            sessionId,
                                                            ready,
                                                            s,
                                                            v,
                                                            ep,
                                                            "uiAttach",
                                                            attachErr);
                                                }
                                            });
                                } catch (Exception ex) {
                                    AppLog.w("PlaybackController", "player init failed", ex);
                                    safeReleasePlayer(candidate);
                                    a.ui.post(
                                            () -> {
                                                if (ticket == a.generation
                                                        && sessionId == a.playbackSessionId) {
                                                    clearPendingHistoryMigration(a);
                                                    String failMsg = a.message(ex);
                                                    if (a.playerChrome != null) {
                                                        a.playerChrome.setTerminalError(failMsg);
                                                    } else if (a.playStatus != null) {
                                                        a.playStatus.setText(failMsg);
                                                    }
                                                    showControls(a, true);
                                                }
                                            });
                                }
                            });
                };
        surface.listen(
                new VideoOutput.Listener() {
                    public void available(Surface value) {
                        activeSurface[0] = value;
                        if (ticket != a.generation || sessionId != a.playbackSessionId) return;
                        if (a.playbackOutputState != null
                                && a.playbackOutputState.sessionId == sessionId) {
                            a.playbackOutputState.onSurfaceAttached(
                                    value == null ? 0 : System.identityHashCode(value),
                                    value != null && value.isValid(),
                                    SystemClock.elapsedRealtime());
                        }
                        if (a.player != null) {
                            final MoviePlayer currentPlayer = a.player;
                            try {
                                currentPlayer.setSurface(value);
                                if (surface.getWidth() > 0 && surface.getHeight() > 0) {
                                    currentPlayer.setSurfaceSize(
                                            surface.getWidth(), surface.getHeight());
                                }
                            } catch (Exception surfaceErr) {
                                handleRecoverablePlaybackException(
                                        a,
                                        ticket,
                                        sessionId,
                                        currentPlayer,
                                        s,
                                        v,
                                        ep,
                                        "surface.available",
                                        surfaceErr);
                            }
                            return;
                        }
                        launchPlayerInit.run();
                    }

                    public void resized(int width, int height) {
                        if (ticket == a.generation
                                && sessionId == a.playbackSessionId
                                && a.player != null) {
                            final MoviePlayer currentPlayer = a.player;
                            try {
                                currentPlayer.setSurfaceSize(width, height);
                            } catch (Exception resizeErr) {
                                handleRecoverablePlaybackException(
                                        a,
                                        ticket,
                                        sessionId,
                                        currentPlayer,
                                        s,
                                        v,
                                        ep,
                                        "surface.resized",
                                        resizeErr);
                            }
                        }
                    }

                    public void destroyed() {
                        activeSurface[0] = null;
                        if (ticket != a.generation || sessionId != a.playbackSessionId) return;
                        if (a.playbackOutputState != null
                                && a.playbackOutputState.sessionId == sessionId) {
                            a.playbackOutputState.onSurfaceDestroyed(SystemClock.elapsedRealtime());
                        }
                        if (a.player != null) {
                            try {
                                a.player.setSurface(null);
                            } catch (Exception detachErr) {
                                AppLog.w(
                                        "PlaybackController",
                                        "surface.destroyed setSurface(null) failed",
                                        detachErr);
                            }
                        }
                    }
                });
        if (!useSystemBackend) {
            launchPlayerInit.run();
        }
        if (keepLocked) {
            a.playerLocked = true;
            a.controlsVisible = false;
            if (a.playbackControls != null) a.playbackControls.visible(false);
            if (a.playerOverlay != null) {
                a.playerOverlay.animate().cancel();
                a.playerOverlay.setAlpha(0f);
                a.playerOverlay.setVisibility(View.GONE);
            }
            if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
            setUnlockButtonVisible(a, false, false);
            a.root.requestFocus();
        } else {
            a.playbackControls.timeline.requestFocus();
            if ("live".equals(s.key)) showControls(a, false);
        }
    }

    static boolean isPlayerLocked(MainActivity a) {
        return a != null && !a.isTvDevice() && a.playerLocked;
    }

    static void setPlayerLocked(MainActivity a, boolean locked) {
        if (a == null || a.isTvDevice() || a.playerLocked == locked) return;
        if (locked) {
            finishSeek(a, false);
            if (a.touchPlayerGesture != null) {
                a.touchPlayerGesture.cancelActiveGesture();
            }
            if (a.playbackControls != null) {
                a.playbackControls.sliderSeeking = false;
                a.playbackControls.touchSeeking = false;
                if (a.playbackControls.activeDialog != null) {
                    a.playbackControls.activeDialog.dismiss();
                    a.playbackControls.activeDialog = null;
                    a.playbackControls.dialogOpen = false;
                }
            }
            showControls(a, false);
            a.playerLocked = true;
            if (android.os.Build.VERSION.SDK_INT >= 18) {
                a.setRequestedOrientation(
                        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LOCKED);
            }
            setUnlockButtonVisible(a, true, true);
            if (a.touchPlayerGesture != null) {
                a.touchPlayerGesture.showBriefNotice("已锁定播放界面 · 防误触开启");
            }
        } else {
            a.playerLocked = false;
            a.setRequestedOrientation(
                    a.isPortrait()
                            ? android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            : android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
            setUnlockButtonVisible(a, false, false);
            showControls(a, true);
            if (a.touchPlayerGesture != null) {
                a.touchPlayerGesture.showBriefNotice("已解锁播放界面");
            }
        }
    }

    static void setUnlockButtonVisible(MainActivity a, boolean visible, boolean autoHide) {
        if (a == null) return;
        if (a.hideLockButton != null) {
            a.ui.removeCallbacks(a.hideLockButton);
        }
        if (a.playerChrome != null && a.playerChrome.unlockPill != null) {
            View pill = a.playerChrome.unlockPill;
            pill.animate().cancel();
            pill.setAlpha(1f);
            pill.setVisibility(visible && a.playerLocked ? View.VISIBLE : View.GONE);
        }
        if (visible && autoHide && a.playerLocked) {
            a.hideLockButton =
                    () -> {
                        if (a.playerLocked) {
                            setUnlockButtonVisible(a, false, false);
                        }
                    };
            a.ui.postDelayed(a.hideLockButton, 3500L);
        }
    }

    static void toggleUnlockButton(MainActivity a) {
        if (a == null || !a.playerLocked) return;
        boolean currentlyVisible =
                a.playerChrome != null
                        && a.playerChrome.unlockPill != null
                        && a.playerChrome.unlockPill.getVisibility() == View.VISIBLE;
        setUnlockButtonVisible(a, !currentlyVisible, !currentlyVisible);
    }

    static void revealLockedHint(MainActivity a) {
        if (a == null || !a.playerLocked) return;
        setUnlockButtonVisible(a, true, true);
        if (a.touchPlayerGesture != null) {
            a.touchPlayerGesture.showBriefNotice("屏幕已锁定 · 点击解锁恢复操作");
        }
    }

    static void showControls(MainActivity a, boolean visible) {
        showControls(a, visible, false);
    }

    static void showControls(MainActivity a, boolean visible, boolean progressOnly) {
        if (!visible) finishSeek(a, false);
        if (visible && !progressOnly) {
            a.seekGestureSerial++;
            if (a.playerChrome != null) a.playerChrome.hideLightSeekCapsuleNow();
        }
        if (visible && a.playerChrome != null) a.playerChrome.cancelEpisodeHoldSwitch();
        if (a.miniMode && visible) return;
        if (a.playerLocked && visible) {
            setUnlockButtonVisible(a, true, true);
            return;
        }
        boolean changed = a.controlsVisible != visible;
        a.controlsVisible = visible;
        if (visible && a.playClock != null && a.player != null && a.prepared) {
            try {
                int rawPos = a.player.getCurrentPosition();
                int displayPos =
                        a.playbackControls != null
                                ? a.playbackControls.displayPosition(rawPos)
                                : rawPos;
                int dur = a.player.getDuration();
                if (dur <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
                    dur = a.playingBookmark.duration;
                }
                String clockText =
                        formatTime(displayPos)
                                + " / "
                                + (dur > 0 ? formatTime(dur) : (a.isLive() ? "直播" : "--:--"));
                if (!clockText.contentEquals(a.playClock.getText())) {
                    a.playClock.setText(clockText);
                }
            } catch (Exception ignored) {
            }
        }
        if (a.playerChrome != null) {
            a.playerChrome.setProgressOnlyMode(visible && progressOnly);
        }
        if (a.playbackControls != null) a.playbackControls.visible(visible);
        if (a.playerChrome != null) a.playerChrome.update();
        if (a.playerOverlay != null) {
            a.playerOverlay.animate().cancel();
            if (visible) {
                a.playerOverlay.setAlpha(1f);
                a.playerOverlay.setTranslationY(0f);
                a.playerOverlay.setVisibility(View.VISIBLE);
                if (changed && !a.reduced && !a.isTvDevice()) {
                    a.playerOverlay.setAlpha(0f);
                    a.playerOverlay.animate().alpha(1f).setDuration(150).start();
                }
            } else {
                if (a.reduced || a.isTvDevice()) {
                    a.playerOverlay.setAlpha(0f);
                    a.playerOverlay.setVisibility(View.GONE);
                } else {
                    long hideDur = 140;
                    UiCompat.startWithEndAction(
                            a.playerOverlay.animate().alpha(0f).setDuration(hideDur),
                            a.playerOverlay,
                            hideDur,
                            () -> {
                                if (!a.controlsVisible && a.playerOverlay != null)
                                    a.playerOverlay.setVisibility(View.GONE);
                            });
                }
                a.root.requestFocus();
            }
        }
        if (visible) {
            if (a.playerChrome != null && a.playerChrome.terminalError && a.isTvDevice()) {
                a.playerChrome.focusPrimaryErrorAction();
            } else if (changed && a.playbackControls != null && a.isTvDevice()) {
                a.playbackControls.timeline.requestFocus();
            }
            scheduleHide(a);
        } else if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
    }

    static void scheduleHide(MainActivity a) {
        if (a.hideControls != null) a.ui.removeCallbacks(a.hideControls);
        a.hideControls =
                () -> {
                    if (a.prepared
                            && a.playing
                            && (a.playbackOutputState == null
                                    || !a.playbackOutputState.reportedStalled)
                            && (a.playerChrome == null || !a.playerChrome.terminalError)
                            && (a.playbackControls == null || !a.playbackControls.dialogOpen))
                        showControls(a, false);
                };
        a.ui.postDelayed(a.hideControls, 5000);
    }

    static final String STALLED_NO_PICTURE_MESSAGE = "检测到视频流未正常出画，请切换播放器内核或输出方式后重试";

    private static void safeReleasePlayer(MoviePlayer mp) {
        if (mp == null) return;
        try {
            mp.release();
        } catch (Exception ignored) {
        }
    }

    private static int safeCurrentPosition(MoviePlayer mp) {
        if (mp == null) return 0;
        try {
            return Math.max(0, mp.getCurrentPosition());
        } catch (Exception ignored) {
            return 0;
        }
    }

    private static boolean safeIsPlaying(MoviePlayer mp) {
        if (mp == null) return false;
        try {
            return mp.isPlaying();
        } catch (Exception ignored) {
            return false;
        }
    }

    private static boolean isMpvVoConfigured(MoviePlayer mp, Surface currentSurface) {
        if (!(mp instanceof MpvPlayer)) return false;
        MpvPlayer mpv = (MpvPlayer) mp;
        return currentSurface != null
                ? mpv.isVoConfiguredForSurface(currentSurface)
                : mpv.isVoConfigured();
    }

    /**
     * Pure-JVM production bridge from the 1Hz playback clock into {@link PlayerChrome.OverlayState}
     * so unit tests execute the exact same clock-to-overlay contract as Android runtime.
     */
    static PlaybackOutputState.WatchdogAction stepClockOutputOverlay(
            PlaybackOutputState outputState,
            PlayerChrome.OverlayState overlayState,
            long nowMs,
            boolean foreground,
            boolean mpvVoConfigured,
            boolean prepared) {
        outputState.onForegroundChanged(foreground, nowMs);
        PlaybackOutputState.WatchdogAction action =
                outputState.evaluateWatchdog(nowMs, mpvVoConfigured);
        PlaybackOutputState.UiOverlayMode mode = outputState.resolveOverlayMode(mpvVoConfigured);
        overlayState.applyOutputOverlayMode(mode, STALLED_NO_PICTURE_MESSAGE, prepared);
        return action;
    }

    private static void syncChromeLoadingForOutputState(
            MainActivity a,
            MoviePlayer ready,
            PlaybackOutputState outputState,
            Surface currentSurface) {
        if (a == null || a.playerChrome == null || outputState == null || !a.prepared) return;
        boolean mpvVoOk = isMpvVoConfigured(ready, currentSurface);
        PlaybackOutputState.UiOverlayMode mode = outputState.resolveOverlayMode(mpvVoOk);
        a.playerChrome.applyOutputOverlayMode(mode, STALLED_NO_PICTURE_MESSAGE);
        if (mode == PlaybackOutputState.UiOverlayMode.RECOVERY_STALLED_ERROR
                && !a.controlsVisible) {
            showControls(a, true);
        }
    }

    private static void maybeRecordLiveSuccess(
            MainActivity a,
            Cms.Site s,
            Cms.Episode ep,
            MoviePlayer mp,
            PlaybackOutputState outputState,
            int w,
            int h,
            boolean[] recordedFlag) {
        if (recordedFlag == null || recordedFlag[0]) return;
        if (a == null || s == null || ep == null || mp == null || outputState == null) return;
        if (!"live".equals(s.key) || a.prefs == null) return;
        if (!outputState.shouldRecordLiveSuccess()) return;
        if (outputState.videoTrack == PlaybackOutputState.VideoTrackPresence.PRESENT
                && (w <= 0 || h <= 0)) {
            w = mp.getVideoWidth();
            h = mp.getVideoHeight();
            if (w <= 0 || h <= 0) return;
        }
        recordedFlag[0] = true;
        String updated =
                LiveQualityPolicy.recordStreamSuccess(
                        a.prefs.getString(Prefs.LIVE_STREAM_METRICS, ""),
                        ep.url,
                        Math.max(0, w),
                        Math.max(0, h),
                        (int) Math.max(-1L, mp.getFirstFrameMs()),
                        System.currentTimeMillis());
        a.prefs.edit().putString(Prefs.LIVE_STREAM_METRICS, updated).apply();
    }

    private static void handleRecoverablePlaybackException(
            MainActivity a,
            int ticket,
            int sessionId,
            MoviePlayer failedPlayer,
            Cms.Site s,
            Cms.Video v,
            Cms.Episode ep,
            String phase,
            Exception error) {
        AppLog.w("PlaybackController", "recoverable playback exception at " + phase, error);
        if (a == null
                || ticket != a.generation
                || sessionId != a.playbackSessionId
                || a.isFinishing()) {
            safeReleasePlayer(failedPlayer);
            return;
        }
        if (a.player != null && failedPlayer != null && a.player != failedPlayer) {
            safeReleasePlayer(failedPlayer);
            return;
        }
        int savedPos = safeCurrentPosition(failedPlayer);
        if (savedPos > 0) a.resumeAt = savedPos;
        if (a.player == failedPlayer) {
            a.player = null;
        }
        safeReleasePlayer(failedPlayer);
        a.prepared = false;
        a.playing = false;
        if (failedPlayer instanceof MpvPlayer && !ep.media.optBoolean("_mpvFallback")) {
            try {
                ep.media.put("_mpvFallback", true);
            } catch (Exception ignored) {
            }
            if (a.playStatus != null) a.playStatus.setText("MPV 启动异常，正在切换 Media3 内核…");
            a.ui.post(
                    () -> {
                        if (ticket == a.generation
                                && sessionId == a.playbackSessionId
                                && !a.isFinishing()) {
                            playerPage(a, s, v, ep);
                        }
                    });
            return;
        }
        if (failedPlayer instanceof SystemPlayer && !ep.media.optBoolean("_systemErrorFallback")) {
            try {
                ep.media.put("_systemErrorFallback", true);
                ep.media.remove("_systemFallback");
            } catch (Exception ignored) {
            }
            if (a.playStatus != null) a.playStatus.setText("系统播放器异常，正在切换 Media3 内核…");
            a.ui.post(
                    () -> {
                        if (ticket == a.generation
                                && sessionId == a.playbackSessionId
                                && !a.isFinishing()) {
                            playerPage(a, s, v, ep);
                        }
                    });
            return;
        }
        clearPendingHistoryMigration(a);
        String failMsg = "播放器启动异常，请重试或切换内核";
        if (a.playerChrome != null) {
            a.playerChrome.setTerminalError(failMsg);
        } else if (a.playStatus != null) {
            a.playStatus.setText(failMsg);
        }
        showControls(a, true);
    }

    static void clock(
            MainActivity a,
            int ticket,
            int sessionId,
            VideoOutput surface,
            Surface[] activeSurface,
            Cms.Site s,
            Cms.Video v,
            Cms.Episode ep) {
        if (ticket != a.generation
                || sessionId != a.playbackSessionId
                || a.player == null
                || !a.prepared) return;
        updateInMemoryBookmark(a);
        savePlaybackHistory(a, false);
        PlaybackOutputState outputState = a.playbackOutputState;
        if (outputState != null && outputState.sessionId == sessionId) {
            long nowMs = SystemClock.elapsedRealtime();
            Surface curSurface =
                    activeSurface != null && activeSurface.length > 0 ? activeSurface[0] : null;
            boolean mpvVoOk = isMpvVoConfigured(a.player, curSurface);
            outputState.onForegroundChanged(a.foreground, nowMs);
            PlaybackOutputState.WatchdogAction action =
                    outputState.evaluateWatchdog(nowMs, mpvVoOk);
            if (action == PlaybackOutputState.WatchdogAction.REBIND_SURFACE) {
                a.blackScreenRecoveryCount++;
                AppLog.w(
                        "PlaybackDiag",
                        "black_screen_rebind session="
                                + sessionId
                                + " attempt="
                                + outputState.recoveryAttempts);
                if (curSurface != null && curSurface.isValid()) {
                    try {
                        if (a.player instanceof MpvPlayer) {
                            outputState.onMpvVoConfigured(
                                    System.identityHashCode(curSurface), false, nowMs);
                        }
                        a.player.setSurface(null);
                        a.player.setSurface(curSurface);
                        if (surface != null && surface.getWidth() > 0 && surface.getHeight() > 0) {
                            a.player.setSurfaceSize(surface.getWidth(), surface.getHeight());
                        }
                    } catch (Exception rebindErr) {
                        handleRecoverablePlaybackException(
                                a,
                                ticket,
                                sessionId,
                                a.player,
                                s,
                                v,
                                ep,
                                "watchdog.rebind",
                                rebindErr);
                        return;
                    }
                }
            } else if (action == PlaybackOutputState.WatchdogAction.FALLBACK_ONCE) {
                a.blackScreenRecoveryCount++;
                boolean canFallback = false;
                try {
                    if (a.player instanceof MpvPlayer && !ep.media.optBoolean("_mpvFallback")) {
                        ep.media.put("_mpvFallback", true);
                        canFallback = true;
                    } else if (surface != null
                            && surface.usesSurfaceView()
                            && !ep.media.optBoolean("_videoOutputFallback")) {
                        ep.media.put("_videoOutputFallback", true);
                        canFallback = true;
                    } else if (a.player instanceof SystemPlayer
                            && !ep.media.optBoolean("_systemErrorFallback")) {
                        ep.media.put("_systemErrorFallback", true);
                        ep.media.remove("_systemFallback");
                        canFallback = true;
                    }
                    ep.media.put("_blackScreenRecoveryCount", a.blackScreenRecoveryCount);
                } catch (Exception ignored) {
                }
                if (canFallback) {
                    int pos = safeCurrentPosition(a.player);
                    if (pos > 0) a.resumeAt = pos;
                    AppLog.w(
                            "PlaybackDiag",
                            "black_screen_fallback session="
                                    + sessionId
                                    + " count="
                                    + a.blackScreenRecoveryCount);
                    a.toast("检测到视频未出画，正在切换兼容输出续播…");
                    if (a.playStatus != null) a.playStatus.setText("正在切换兼容输出续播…");
                    a.ui.post(
                            () -> {
                                if (ticket == a.generation
                                        && sessionId == a.playbackSessionId
                                        && !a.isFinishing()) {
                                    playerPage(a, s, v, ep);
                                }
                            });
                    return;
                }
                outputState.markReportedStalled();
                action = PlaybackOutputState.WatchdogAction.REPORT_STALLED;
            }
            syncChromeLoadingForOutputState(a, a.player, outputState, curSurface);
            if (action == PlaybackOutputState.WatchdogAction.REPORT_STALLED) {
                AppLog.w(
                        "PlaybackDiag",
                        "black_screen_stalled session="
                                + sessionId
                                + " state="
                                + outputState.diagnosticStateName());
                showControls(a, true);
            }
        }
        try {
            if (a.embyReporter != null)
                a.embyReporter.update(a.player.getCurrentPosition(), !a.player.isPlaying());
            if (a.seekGesture.active) previewSeek(a);
            else if (a.playbackControls == null || !a.playbackControls.isUserSeeking()) {
                int rawPos = a.player.getCurrentPosition();
                int displayPos =
                        a.playbackControls != null
                                ? a.playbackControls.displayPosition(rawPos)
                                : rawPos;
                int dur = a.player.getDuration();
                if (dur <= 0 && a.playingBookmark != null && a.playingBookmark.duration > 0) {
                    dur = a.playingBookmark.duration;
                }
                if (a.playerChrome != null) {
                    a.playerChrome.updatePlaybackHud(displayPos, dur, a.isLive());
                }
                if (a.controlsVisible && a.playClock != null) {
                    String clockText =
                            formatTime(displayPos)
                                    + " / "
                                    + (dur > 0 ? formatTime(dur) : (a.isLive() ? "直播" : "--:--"));
                    if (!clockText.contentEquals(a.playClock.getText())) {
                        a.playClock.setText(clockText);
                    }
                }
                if (a.playbackControls != null) a.playbackControls.tick();
            }
            if (a.playerChrome != null) a.playerChrome.update();
        } catch (Exception ignored) {
        }
        a.ui.postDelayed(() -> clock(a, ticket, sessionId, surface, activeSurface, s, v, ep), 1000);
    }

    static void togglePlayback(MainActivity a) {
        if (a.player == null || !a.prepared) return;
        if (a.embyReporter == null
                && a.playbackControls != null
                && a.playbackControls.site != null
                && a.playbackControls.site.api != null
                && a.playbackControls.site.api.startsWith(com.pilipala.emby.EmbyLibrary.PREFIX)) {
            a.resumeAt = -1;
            resolvePlayer(
                    a,
                    a.playbackControls.site,
                    a.playbackControls.video,
                    a.activeLine,
                    a.activeEpisode);
            return;
        }
        try {
            if (a.player.isPlaying()) {
                observePendingHistoryMigration(a);
                a.player.pause();
                a.playing = false;
                if (a.playbackOutputState != null) {
                    a.playbackOutputState.onPlayStateChanged(
                            false, false, SystemClock.elapsedRealtime());
                }
                savePlaybackHistory(a, true);
                a.playStatus.setText(a.isTvDevice() ? "已暂停 · 按确认继续" : "已暂停 · 双击继续");
            } else {
                if (a.player.getDuration() > 0
                        && a.player.getCurrentPosition() >= a.player.getDuration() - 300) {
                    if (a.playbackControls != null) {
                        a.playbackControls.recordUserSeek(0);
                    } else {
                        notifyPendingHistoryMigrationSeek(a, 0);
                    }
                    a.player.seekTo(0);
                }
                a.player.start();
                a.playing = true;
                observePendingHistoryMigration(a);
                if (a.playbackOutputState != null) {
                    a.playbackOutputState.onPlayStateChanged(
                            true, true, SystemClock.elapsedRealtime());
                }
                a.playStatus.setText(
                        a.isTvDevice()
                                ? "正在播放 · 确认暂停 · 上下键显示工具条"
                                : "正在播放 · 双击暂停 · 左右滑快进 · 上下滑调亮度音量");
            }
            if (a.playerChrome != null) a.playerChrome.update();
            if (a.embyReporter != null)
                a.embyReporter.update(a.player.getCurrentPosition(), !a.playing);
        } catch (Exception error) {
            AppLog.w("PlaybackController", "togglePlayback failed", error);
        }
    }

    /**
     * Pure-JVM policy: in Modern TV Floating Card style with controls collapsed, left/right seek
     * uses ONLY the light directional time capsule without popping the full dock/timeline or moving
     * focus.
     */
    static boolean shouldUseLightSeekCapsule(
            boolean tvDevice, boolean modernTv, boolean controlsVisible, boolean progressOnlyMode) {
        return tvDevice && modernTv && (!controlsVisible || progressOnlyMode);
    }

    static boolean isDedicatedSeekKey(int keyCode) {
        return keyCode == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD
                || keyCode == KeyEvent.KEYCODE_MEDIA_REWIND;
    }

    static void beginSeek(MainActivity a, int direction) {
        if (a.player == null || !a.prepared || a.player.getDuration() <= 0 || a.isLive()) return;
        boolean startingNew = !a.seekGesture.active;
        int position = a.seekGesture.active ? a.seekGesture.target : a.player.getCurrentPosition();
        if (startingNew) {
            a.seekStatus = a.playStatus != null ? a.playStatus.getText().toString() : "";
            a.seekLightCapsuleMode =
                    shouldUseLightSeekCapsule(
                            a.isTvDevice(),
                            a.playerChrome != null && a.playerChrome.modernTv,
                            a.controlsVisible,
                            a.playerChrome != null && a.playerChrome.progressOnlyMode);
        }
        a.seekGestureSerial++;
        if (a.playerChrome != null) {
            a.playerChrome.cancelLightSeekCapsuleHide();
        }
        a.seekGesture.begin(
                direction, position, a.player.getDuration(), SystemClock.uptimeMillis());
        if (!a.seekLightCapsuleMode) {
            showControls(a, true, a.isTvDevice() && !a.controlsVisible);
            if (a.playbackControls != null && a.isTvDevice()) {
                a.playbackControls.timeline.requestFocus();
            }
        }
        previewSeek(a);
        a.ui.removeCallbacks(a.seekPulse);
        a.ui.postDelayed(a.seekPulse, 100);
    }

    static void previewSeek(MainActivity a) {
        if (!a.seekGesture.active) return;
        if (a.seekLightCapsuleMode) {
            if (a.playerChrome != null) {
                a.playerChrome.showLightSeekCapsule(
                        a.seekGesture.direction,
                        a.seekGesture.target,
                        a.seekGestureSerial,
                        a.generation);
            }
            return;
        }
        if (a.playbackControls == null) return;
        a.playbackControls.timeline.setProgress(a.seekGesture.target);
        a.playClock.setText(
                formatTime(a.seekGesture.target) + " / " + formatTime(a.seekGesture.duration));
        long now = SystemClock.uptimeMillis();
        int seekSpeed = a.seekGesture.speed(now);
        boolean accel = a.seekGesture.accelerated(now);
        String msg =
                (a.seekGesture.direction > 0 ? "快进" : "快退")
                        + (seekSpeed > 0
                                ? (accel ? " · 加速 " : " · ") + seekSpeed + " 秒/秒"
                                : " · 15 秒")
                        + " · 松开跳转";
        if (a.playStatus != null) a.playStatus.setText(msg);
        if (a.playerChrome != null && a.playerChrome.seekHint != null) {
            a.playerChrome.seekHint.setText(msg);
        }
    }

    static void finishSeek(MainActivity a, boolean commit) {
        if (!a.seekGesture.active) return;
        int dir = a.seekGesture.direction;
        a.seekGesture.advance(SystemClock.uptimeMillis());
        int target = a.seekGesture.target;
        a.seekGesture.cancel();
        a.ui.removeCallbacks(a.seekPulse);
        if (commit && a.player != null && a.prepared) {
            if (a.playbackControls != null) a.playbackControls.recordUserSeek(target);
            else notifyPendingHistoryMigrationSeek(a, target);
            a.player.seekTo(target);
            if (a.playingBookmark != null) a.playingBookmark.position = Math.max(0, target);
            savePlaybackHistory(a, true);
        }
        boolean light = a.seekLightCapsuleMode;
        int ser = a.seekGestureSerial;
        a.seekLightCapsuleMode = false;
        a.activeSeekKeyCode = 0;
        if (light) {
            if (a.player != null && a.prepared && a.playbackControls != null) {
                int position = commit ? target : a.player.getCurrentPosition();
                int dur = a.player.getDuration();
                a.playbackControls.timeline.setProgress(position);
                if (a.playClock != null) {
                    a.playClock.setText(formatTime(position) + " / " + formatTime(dur));
                }
                if (a.playerChrome != null) {
                    a.playerChrome.updatePlaybackHud(
                            a.playbackControls.displayPosition(position), dur, a.isLive());
                }
            }
            if (a.playerChrome != null) {
                if (commit) {
                    a.playerChrome.showLightSeekCapsule(dir, target, ser, a.generation);
                    a.playerChrome.scheduleLightSeekCapsuleHide(ser, a.generation, 1100L);
                } else {
                    a.playerChrome.hideLightSeekCapsuleNow();
                }
            }
            return;
        }
        if (a.playStatus != null) a.playStatus.setText(a.seekStatus);
        if (a.playerChrome != null && a.playerChrome.seekHint != null) {
            a.playerChrome.seekHint.setText("");
        }
        if (a.player != null && a.prepared && a.playbackControls != null) {
            int position = commit ? target : a.player.getCurrentPosition();
            int dur = a.player.getDuration();
            a.playbackControls.timeline.setProgress(position);
            a.playClock.setText(formatTime(position) + " / " + formatTime(dur));
            if (a.playerChrome != null) {
                a.playerChrome.updatePlaybackHud(
                        a.playbackControls.displayPosition(position), dur, a.isLive());
            }
        }
        if (commit) scheduleHide(a);
    }

    static boolean tryAdvanceQualityOrLiveStream(
            MainActivity a, int ticket, Cms.Site s, Cms.Video v, Cms.Episode ep) {
        if ("live".equals(s.key) && a.prefs != null && ep.url != null && !ep.url.isEmpty()) {
            String failedMetrics =
                    LiveQualityPolicy.recordStreamFailure(
                            a.prefs.getString(Prefs.LIVE_STREAM_METRICS, ""),
                            ep.url,
                            System.currentTimeMillis());
            a.prefs.edit().putString(Prefs.LIVE_STREAM_METRICS, failedMetrics).apply();
        }
        JSONArray qualities = ep.media.optJSONArray("qualities");
        int qIdx = ep.media.optInt("_qualityIdx", 0);
        if (qualities == null || qIdx + 1 >= qualities.length()) return false;
        JSONObject nextQ = qualities.optJSONObject(qIdx + 1);
        String nextUrl = nextQ != null ? nextQ.optString("url", "") : "";
        if (nextUrl.isEmpty()) return false;
        try {
            ep.media.put("_qualityIdx", qIdx + 1);
            ep.media.remove("_softwareFallback");
            ep.media.remove("_systemFallback");
            ep.media.remove("_systemErrorFallback");
            ep.media.remove("_mpvFallback");
            ep.media.remove("_videoOutputFallback");
            ep.media.remove("_blackScreenRecoveryCount");
        } catch (Exception ignored) {
        }
        applyCandidateHeaders(s, ep, nextQ);
        if (LiveQualityPolicy.isEmbyLiveUrl(nextUrl)) {
            a.ui.post(
                    () -> {
                        if (ticket == a.generation) {
                            LiveController.playEmbyLiveAsync(a, s, v, ep, nextUrl);
                        }
                    });
            return true;
        }
        ep.url = LocalProxy.rewrite(nextUrl);
        String qName = nextQ.optString("name", "备用线路");
        if (a.playStatus != null) {
            a.playStatus.setText("正在切换至 " + qName + "…");
        }
        if (a.playerChrome != null) {
            a.playerChrome.resetLoadingSpeedSession();
            a.playerChrome.setLoadingStatus("正在切换至 " + qName + "…", null);
        }
        a.ui.post(
                () -> {
                    if (ticket == a.generation) playerPage(a, s, v, ep);
                });
        return true;
    }

    static void applyCandidateHeaders(Cms.Site s, Cms.Episode ep, JSONObject qObj) {
        if (ep == null || qObj == null) return;
        ep.headers.clear();
        if (s != null && !"live".equals(s.key)) {
            ep.headers.putAll(s.headers);
        }
        JSONObject hs = qObj.optJSONObject("headers");
        if (hs != null) {
            java.util.Iterator<String> keys = hs.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                String val = hs.optString(k, "");
                if (!val.isEmpty()) ep.headers.put(k, val);
            }
        }
        if (s != null && "live".equals(s.key)) {
            s.headers.clear();
            s.headers.putAll(ep.headers);
            if (!LiveQualityPolicy.isEmbyLiveUrl(qObj.optString("url", ""))) {
                ep.media.remove("embySession");
                s.api = qObj.optString("url", "");
            }
        }
        String mime = qObj.optString("mimeType", "").trim();
        JSONObject drm = qObj.optJSONObject("drm");
        try {
            if (!mime.isEmpty()) ep.media.put("mimeType", mime);
            else ep.media.remove("mimeType");
            if (drm != null) ep.media.put("drm", new JSONObject(drm.toString()));
            else ep.media.remove("drm");
        } catch (Exception ignored) {
        }
    }

    static void notifyPendingHistoryMigrationSeek(MainActivity a, int targetPosMs) {
        if (a == null || a.pendingHistoryMigration == null) return;
        if (a.playingBookmark != null
                && !a.pendingHistoryMigration.matchesSavedBookmark(a.playingBookmark)) {
            return;
        }
        a.pendingHistoryMigration.resetProgressBaselineForSeek(
                targetPosMs, safeCurrentPosition(a.player));
    }

    static float safePlaybackSpeed(MoviePlayer player) {
        if (player == null) return 1.0f;
        try {
            float speed = player.getSpeed();
            return (Float.isNaN(speed) || Float.isInfinite(speed) || speed <= 0f) ? 1.0f : speed;
        } catch (Exception ignored) {
            return 1.0f;
        }
    }

    static boolean observePendingHistoryMigration(MainActivity a) {
        if (a == null
                || a.privateMode
                || a.player == null
                || !a.prepared
                || a.playingBookmark == null
                || a.pendingHistoryMigration == null
                || !a.pendingHistoryMigration.matchesSavedBookmark(a.playingBookmark)) {
            return false;
        }
        a.pendingHistoryMigration.syncPlayerSeekGeneration(
                a.player.seekGeneration(),
                a.player.lastSeekTargetMs(),
                a.player.lastSeekPrePosMs());
        int seekTargetMs =
                Math.max(
                        Math.max(0, a.playingBookmark.position),
                        a.playbackControls != null
                                ? Math.max(0, a.playbackControls.pendingResumeMs)
                                : 0);
        return a.pendingHistoryMigration.observePlaybackProgress(
                a.foreground,
                a.playing,
                safeIsPlaying(a.player),
                safeCurrentPosition(a.player),
                seekTargetMs,
                a.player.supportsSeekConfirmation(),
                a.player.isSeekInFlight(),
                safePlaybackSpeed(a.player),
                SystemClock.elapsedRealtime());
    }

    static boolean tryCommitPendingHistoryMigration(MainActivity a, boolean completedInForeground) {
        if (a == null) return false;
        WatchHistory.PendingMigration pending = a.pendingHistoryMigration;
        if (pending == null) return false;
        if (a.privateMode) {
            a.pendingHistoryMigration = null;
            return false;
        }
        if (a.player == null || !a.prepared || a.playingBookmark == null) return false;
        if (!pending.matchesSavedBookmark(a.playingBookmark)) {
            a.pendingHistoryMigration = null;
            return false;
        }
        if (completedInForeground) {
            pending.markCompletedInForeground(a.foreground, a.playing);
        }
        observePendingHistoryMigration(a);
        if (!pending.isProgressConfirmed()) {
            return false;
        }
        updateInMemoryBookmark(a);
        a.lastBookmarkSave = a.playingBookmark.updated;
        final WatchHistory.Entry snapshot = cloneBookmark(a.playingBookmark);
        if (a.prefs == null || !WatchHistory.isValidEntry(snapshot)) {
            return false;
        }
        a.pendingHistoryMigration = null;
        a.deferPlayingBookmarkUntilMigrationCommit = false;
        WatchHistory.enqueueUpsertAndMigrate(a.historyPersistence(), snapshot, pending.oldKey);
        CloudSyncDialog.scheduleAutoPush(a, completedInForeground);
        return true;
    }

    static void savePlaybackHistoryOnPrepared(MainActivity a) {
        if (a == null) return;
        if (a.privateMode) {
            a.pendingHistoryMigration = null;
            return;
        }
        if (a.player == null || !a.prepared || a.playingBookmark == null) return;
        WatchHistory.PendingMigration pending = a.pendingHistoryMigration;
        if (pending != null) {
            if (pending.matchesSavedBookmark(a.playingBookmark)) {
                tryCommitPendingHistoryMigration(a, false);
                return;
            }
            a.pendingHistoryMigration = null;
        }
        if (a.deferPlayingBookmarkUntilMigrationCommit) return;
        updateInMemoryBookmark(a);
        a.lastBookmarkSave = a.playingBookmark.updated;
        final WatchHistory.Entry snapshot = cloneBookmark(a.playingBookmark);
        if (a.prefs == null || snapshot == null) return;
        WatchHistory.enqueueUpsert(a.historyPersistence(), snapshot);
        CloudSyncDialog.scheduleAutoPush(a, false);
    }

    static void savePlaybackHistory(MainActivity a, boolean force) {
        if (a.privateMode) {
            a.pendingHistoryMigration = null;
            return;
        }
        if (a.player == null || !a.prepared || a.playingBookmark == null) return;
        WatchHistory.PendingMigration pending = a.pendingHistoryMigration;
        if (pending != null) {
            if (pending.matchesSavedBookmark(a.playingBookmark)) {
                tryCommitPendingHistoryMigration(a, false);
                return;
            }
            a.pendingHistoryMigration = null;
        }
        if (a.deferPlayingBookmarkUntilMigrationCommit) return;
        updateInMemoryBookmark(a);
        if (a.playingBookmark.position < 1000 && a.playingBookmark.position == 0) return;
        long now = System.currentTimeMillis();
        if (!force && now - a.lastBookmarkSave < DISK_SAVE_INTERVAL_MS) return;
        a.lastBookmarkSave = now;
        final WatchHistory.Entry snapshot = cloneBookmark(a.playingBookmark);
        if (a.prefs != null && snapshot != null) {
            WatchHistory.enqueueUpsert(a.historyPersistence(), snapshot);
        }
        CloudSyncDialog.scheduleAutoPush(a, force);
    }

    static void stopEmbySession(MainActivity a) {
        if (a.embyReporter == null) return;
        int position = 0;
        try {
            if (a.player != null && a.prepared) position = a.player.getCurrentPosition();
        } catch (Exception ignored) {
        }
        a.embyReporter.stop(position);
        a.embyReporter = null;
    }

    static void releasePlayer(MainActivity a) {
        releasePlayer(a, false);
    }

    static void releasePlayer(MainActivity a, boolean preserveDanmuScope) {
        a.playbackSessionId++;
        a.playbackOutputState = null;
        if (!preserveDanmuScope) {
            DanmuOwnership.GLOBAL.clearActiveScope();
            a.activeDanmuContext = null;
        }
        if (a.markerHost != null) a.markerHost.abort();
        a.seekGestureSerial++;
        a.suppressBackUpAfterSeekCancel = false;
        a.activeSeekKeyCode = 0;
        if (a.playerChrome != null) {
            a.playerChrome.cancelEpisodeHoldSwitch();
            a.playerChrome.hideLightSeekCapsuleNow();
            if (a.playerChrome.loadingSpeedMonitor != null) {
                a.playerChrome.loadingSpeedMonitor.stop();
            }
        }
        finishSeek(a, false);
        if (a.hideLockButton != null) {
            a.ui.removeCallbacks(a.hideLockButton);
            a.hideLockButton = null;
        }
        a.playerLocked = false;
        a.touchPlayerGesture = null;
        a.clearLiveNumber();
        savePlaybackHistory(a, true);
        a.deferPlayingBookmarkUntilMigrationCommit = false;
        stopEmbySession(a);
        a.miniMode = false;
        a.miniDetails = null;
        if (a.playbackControls != null) a.playbackControls.close();
        a.playbackControls = null;
        a.prepared = false;
        a.playing = false;
        if (a.player != null) {
            try {
                a.player.release();
            } catch (Exception error) {
                AppLog.w("PlaybackController", "player.release failed", error);
            }
            a.player = null;
        }
        VideoOutput.setWindowHdrMode(a, false);
        a.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    /**
     * Policy for HUD visibility on TV pause/resume toggle: clicking pause on TV keeps the frame
     * clean without popping up top/bottom toolbars or timeline HUD.
     */
    static boolean shouldShowHudOnPauseToggle(
            boolean tvDevice, boolean controlsAlreadyVisible, boolean nowPlaying) {
        if (!tvDevice) return true;
        return false;
    }

    static boolean dispatchPlaybackKey(MainActivity a, KeyEvent event) {
        if (a.current == null
                || !a.current.player
                || a.miniMode
                || (a.playbackControls != null && a.playbackControls.dialogOpen)) return false;
        int key = event.getKeyCode();
        EpisodeHoldSwitchOverlay holdOverlay =
                a.playerChrome != null ? a.playerChrome.episodeHoldOverlay : null;
        if (holdOverlay != null) {
            if (holdOverlay.isTracking() && !holdOverlay.isTrackingKey(key)) {
                holdOverlay.cancel();
            }
            if (EpisodeHoldSwitchOverlay.isEpisodeHoldKey(key)) {
                int action = event.getAction();
                boolean eligibleHold =
                        a.isTvDevice()
                                && !a.isLive()
                                && !a.isCast()
                                && a.prepared
                                && a.markerHost == null
                                && !a.seekGesture.active
                                && (!a.controlsVisible
                                        || (a.playerChrome != null
                                                && a.playerChrome.progressOnlyMode))
                                && (a.playbackControls == null
                                        || !a.playbackControls.isSkipCountdownActive());
                if (action == KeyEvent.ACTION_DOWN) {
                    if (event.getRepeatCount() == 0 && eligibleHold) {
                        int dir = EpisodeHoldSwitchOverlay.Controller.directionForKeyCode(key);
                        boolean hasTarget =
                                a.playbackControls != null
                                        && a.playbackControls.hasAdjacentEpisode(dir);
                        String targetName =
                                a.playbackControls != null
                                        ? a.playbackControls.peekAdjacentEpisodeName(dir)
                                        : "";
                        if (holdOverlay.beginHold(
                                key, event.getDownTime(), hasTarget, targetName)) {
                            return true;
                        }
                    } else if (holdOverlay.isTrackingKey(key)) {
                        holdOverlay.onKeyRepeat(key);
                        return true;
                    }
                } else if (action == KeyEvent.ACTION_UP && holdOverlay.isTrackingKey(key)) {
                    int upResult = holdOverlay.handleKeyUp(key, event.isCanceled());
                    if (upResult == EpisodeHoldSwitchOverlay.Controller.UP_SHORT_PRESS) {
                        if (key == KeyEvent.KEYCODE_DPAD_UP && a.playbackControls != null) {
                            KeyEvent syntheticDown =
                                    new KeyEvent(
                                            event.getDownTime(),
                                            event.getEventTime(),
                                            KeyEvent.ACTION_DOWN,
                                            KeyEvent.KEYCODE_DPAD_UP,
                                            0);
                            if (a.playbackControls.markers().open(syntheticDown)) {
                                return true;
                            }
                        }
                        showControls(a, true, false);
                        if (a.playbackControls != null) a.playbackControls.focusPrimaryAction();
                    }
                    return true;
                }
            }
        }
        View focus = a.getCurrentFocus();
        if (a.playerChrome != null && a.playerChrome.isErrorCardFocused(focus)) {
            return false;
        }
        if (a.isTvDevice()
                && key == KeyEvent.KEYCODE_DPAD_UP
                && a.playbackControls != null
                && a.playbackControls.markers().open(event)) return true;
        boolean down = event.getAction() == KeyEvent.ACTION_DOWN;
        boolean up = event.getAction() == KeyEvent.ACTION_UP;
        if (key == KeyEvent.KEYCODE_BACK) {
            if (down) {
                if (a.seekGesture.active) {
                    finishSeek(a, false);
                    a.suppressBackUpAfterSeekCancel = true;
                    return true;
                }
                if (a.suppressBackUpAfterSeekCancel) {
                    if (event.getRepeatCount() > 0) {
                        return true;
                    }
                    a.suppressBackUpAfterSeekCancel = false;
                }
            } else if (up && a.suppressBackUpAfterSeekCancel) {
                a.suppressBackUpAfterSeekCancel = false;
                return true;
            }
        }
        boolean dedicatedSeek = isDedicatedSeekKey(key);
        boolean horizontal =
                key == KeyEvent.KEYCODE_DPAD_LEFT
                        || key == KeyEvent.KEYCODE_DPAD_RIGHT
                        || dedicatedSeek;
        if (a.seekGesture.active && !horizontal && down)
            finishSeek(a, key != KeyEvent.KEYCODE_BACK);
        boolean confirm = key == KeyEvent.KEYCODE_DPAD_CENTER || key == KeyEvent.KEYCODE_ENTER;
        if (confirm
                && (!a.controlsVisible
                        || focus == a.root
                        || a.playbackControls != null && focus == a.playbackControls.timeline)) {
            if (down && event.getRepeatCount() == 0) {
                if (!a.prepared
                        && a.playerChrome != null
                        && a.playerChrome.terminalError
                        && a.playbackControls != null) {
                    a.playbackControls.reload(false);
                    return true;
                }
                boolean wasVisible = a.controlsVisible;
                togglePlayback(a);
                if (shouldShowHudOnPauseToggle(a.isTvDevice(), wasVisible, a.playing)) {
                    showControls(a, true);
                } else {
                    if (wasVisible && !a.playing) {
                        showControls(a, false);
                    } else if (a.playerChrome != null) {
                        a.playerChrome.update();
                    }
                }
            }
            return true;
        }
        if ((!a.controlsVisible || (a.playerChrome != null && a.playerChrome.progressOnlyMode))
                && (key == KeyEvent.KEYCODE_DPAD_UP
                        || key == KeyEvent.KEYCODE_DPAD_DOWN
                        || key == KeyEvent.KEYCODE_MENU)) {
            if (down) {
                showControls(a, true, false);
                if (a.playbackControls != null) a.playbackControls.focusPrimaryAction();
            }
            return true;
        }
        if (a.controlsVisible && key == KeyEvent.KEYCODE_MENU) {
            if (down && event.getRepeatCount() == 0) {
                if (a.playbackControls != null && focus == a.playbackControls.timeline) {
                    a.playbackControls.focusPrimaryAction();
                } else {
                    showControls(a, false);
                }
            }
            return true;
        }
        if (horizontal
                && !a.isLive()
                && (a.seekGesture.active
                        || dedicatedSeek
                        || !a.controlsVisible
                        || focus == a.root
                        || a.playbackControls != null && focus == a.playbackControls.timeline)) {
            int direction =
                    (key == KeyEvent.KEYCODE_DPAD_LEFT || key == KeyEvent.KEYCODE_MEDIA_REWIND)
                            ? -1
                            : 1;
            if (down) {
                if ((!a.seekGesture.active && event.getRepeatCount() == 0)
                        || (a.seekGesture.active
                                && a.seekGesture.direction != direction
                                && event.getRepeatCount() == 0)) {
                    a.activeSeekKeyCode = key;
                    beginSeek(a, direction);
                }
            } else if (up
                    && a.seekGesture.active
                    && a.seekGesture.direction == direction
                    && (a.activeSeekKeyCode == 0 || a.activeSeekKeyCode == key)) {
                finishSeek(a, !event.isCanceled());
            }
            return true;
        }
        if (key == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                || key == KeyEvent.KEYCODE_MEDIA_PLAY
                || key == KeyEvent.KEYCODE_MEDIA_PAUSE) {
            if (down && event.getRepeatCount() == 0) {
                boolean wasVisible = a.controlsVisible;
                if (key == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                        || (key == KeyEvent.KEYCODE_MEDIA_PLAY && !a.playing)
                        || (key == KeyEvent.KEYCODE_MEDIA_PAUSE && a.playing)) togglePlayback(a);
                if (shouldShowHudOnPauseToggle(a.isTvDevice(), wasVisible, a.playing)) {
                    showControls(a, true);
                } else {
                    if (wasVisible && !a.playing) {
                        showControls(a, false);
                    } else if (a.playerChrome != null) {
                        a.playerChrome.update();
                    }
                }
            }
            return true;
        }
        if (a.controlsVisible && down) scheduleHide(a);
        return false;
    }
}

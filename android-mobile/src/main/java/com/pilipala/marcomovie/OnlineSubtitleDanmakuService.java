package com.pilipala.marcomovie;

import android.net.Uri;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Online subtitle search/download + AI bilingual subtitle synthesizer (Assrt & OpenSubtitles REST
 * v1) and multi-source Danmaku resolver (LogVar-compatible endpoints + DandanPlay v2 API + latency
 * speed test sorting). Zero built-in API keys or third-party pirate URLs.
 */
final class OnlineSubtitleDanmakuService {
    interface Callback<T> {
        void onResult(T value);
    }

    static final class SubtitleCandidate {
        final String provider; // "assrt" | "opensubtitles"
        final String id;
        final String title;
        final String language;
        final String format;

        SubtitleCandidate(
                String provider, String id, String title, String language, String format) {
            this.provider = provider;
            this.id = id;
            this.title = title;
            this.language = language;
            this.format = format;
        }
    }

    static final class DanmakuSource {
        String name;
        String baseUrl;
        boolean enabled = true;
        long latencyMs = -1;

        DanmakuSource(String name, String baseUrl, boolean enabled, long latencyMs) {
            this.name = name;
            this.baseUrl = baseUrl;
            this.enabled = enabled;
            this.latencyMs = latencyMs;
        }

        JSONObject toJson() throws Exception {
            return new JSONObject()
                    .put("name", name)
                    .put("url", baseUrl)
                    .put("enabled", enabled)
                    .put("latencyMs", latencyMs);
        }
    }

    private static final Pattern SRT_BLOCK =
            Pattern.compile(
                    "(?m)^(\\d+)\\s*\\n(\\d{2}:\\d{2}:\\d{2}[,.]\\d{3}\\s*-->\\s*\\d{2}:\\d{2}:\\d{2}[,.]\\d{3}[^\\n]*)\\n([\\s\\S]*?)(?=\\n\\n|\\z)");

    private OnlineSubtitleDanmakuService() {}

    static List<DanmakuSource> loadDanmakuSources(MainActivity a) {
        return DanmuSourceManager.loadUnifiedSources(a);
    }

    static void saveDanmakuSources(MainActivity a, List<DanmakuSource> list) {
        DanmuSourceManager.saveUnifiedSources(a, list);
    }

    /**
     * Pure-JVM testable protocol-aware benchmark: only counts sources passing real Dandanplay v2
     * JSON validation (rejecting HTTP 404/401/403 and business auth failures).
     */
    static List<DanmakuSource> benchmarkSourcesSync(
            List<DanmakuSource> sources, String sampleKeyword) {
        if (sources == null || sources.isEmpty()) return new ArrayList<>();
        String kw =
                sampleKeyword == null || sampleKeyword.trim().isEmpty()
                        ? "三体"
                        : sampleKeyword.trim();
        for (DanmakuSource src : sources) {
            if (src == null) continue;
            DanmuSourceManager.ProbeResult probe =
                    DanmuSourceManager.probeSingleOrigin(src.baseUrl, kw);
            src.latencyMs = probe.ok ? Math.max(1L, probe.latencyMs) : 9999L;
        }
        Collections.sort(
                sources,
                new Comparator<DanmakuSource>() {
                    @Override
                    public int compare(DanmakuSource a1, DanmakuSource b1) {
                        long la = a1.latencyMs < 0 ? 9998L : a1.latencyMs;
                        long lb = b1.latencyMs < 0 ? 9998L : b1.latencyMs;
                        return Long.compare(la, lb);
                    }
                });
        return sources;
    }

    /** Benchmarks all user-configured Danmaku sources and sorts fastest reachable endpoints first. */
    static void benchmarkDanmakuSourcesAsync(
            final MainActivity a, final Callback<List<DanmakuSource>> callback) {
        final List<DanmakuSource> sources = loadDanmakuSources(a);
        if (sources.isEmpty()) {
            if (callback != null) callback.onResult(sources);
            return;
        }
        a.worker.execute(
                () -> {
                    benchmarkSourcesSync(sources, "三体");
                    saveDanmakuSources(a, sources);
                    a.ui.post(
                            () -> {
                                if (!a.isFinishing() && callback != null)
                                    callback.onResult(sources);
                            });
                });
    }

    /** Resolves Danmaku JSON text from the unified configured Danmaku sources via DandanplayProvider. */
    static void searchAndLoadDanmakuAsync(
            final MainActivity a,
            final String videoTitle,
            final String episodeName,
            final Callback<String> onDanmakuBody) {
        if (a == null || videoTitle == null || onDanmakuBody == null) return;
        final SeasonParser.SeasonMeta sm = SeasonParser.parseSeasonMeta(videoTitle);
        final String cleanSeries = EpisodeNameCleaner.cleanSearchTitle(sm.baseTitle);
        final EpisodeNameCleaner.CleanedEpisode cleanEp =
                EpisodeNameCleaner.clean(episodeName, cleanSeries, 0);

        a.worker.execute(
                () -> {
                    try {
                        DanmuSettingsPanel.DanmuConfig cfg =
                                DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
                        List<DanmakuSource> unified = loadDanmakuSources(a);
                        String origins = DanmuSourceManager.enabledOriginsMultiline(unified);
                        if (!origins.isEmpty()) {
                            String appId = cfg.appId;
                            String appSecret = cfg.appSecret;
                            if (appId.isEmpty()) {
                                appId =
                                        a.secretsPrefs()
                                                .getString(Prefs.SECRET_DANDAN_APP_ID, "")
                                                .trim();
                            }
                            if (appSecret.isEmpty()) {
                                appSecret =
                                        a.secretsPrefs()
                                                .getString(Prefs.SECRET_DANDAN_SECRET, "")
                                                .trim();
                            }
                            DandanplayProvider provider =
                                    new DandanplayProvider(origins, appId, appSecret);
                            DanmuProvider.MatchQuery query =
                                    new DanmuProvider.MatchQuery(
                                            cleanSeries,
                                            episodeName == null ? "" : episodeName,
                                            sm.seasonNumber,
                                            cleanEp.episodeNumber,
                                            0L);
                            DanmuProvider.CancellationToken token =
                                    new DanmuProvider.CancellationToken();
                            List<DanmuProvider.Candidate> candidates =
                                    provider.matchOrSearch(query, token);
                            if (candidates != null && !candidates.isEmpty()) {
                                DanmuProvider.EpisodeSession session =
                                        provider.openSession(
                                                candidates.get(0).boundEpisodeId, token);
                                List<DanmuProvider.DanmuItem> items = session.preloadComments;
                                if (items != null && !items.isEmpty()) {
                                    JSONArray commentsArr = new JSONArray();
                                    for (DanmuProvider.DanmuItem item : items) {
                                        String pField =
                                                String.format(
                                                        Locale.US,
                                                        "%.2f,%d,%d",
                                                        item.timeMs / 1000.0,
                                                        item.mode,
                                                        item.rgbColor & 0xFFFFFF);
                                        commentsArr.put(
                                                new JSONObject()
                                                        .put("cid", item.id)
                                                        .put("p", pField)
                                                        .put("m", item.text));
                                    }
                                    final String payload =
                                            new JSONObject()
                                                    .put("comments", commentsArr)
                                                    .toString();
                                    a.ui.post(() -> onDanmakuBody.onResult(payload));
                                    return;
                                }
                            }
                        }
                    } catch (Exception ignored) {
                    }
                    a.ui.post(() -> onDanmakuBody.onResult(null));
                });
    }

    private static String extractDandanComments(String base, String searchRaw) throws Exception {
        return extractDandanCommentsWithHeaders(base, searchRaw, Collections.emptyMap());
    }

    private static String extractDandanCommentsWithHeaders(
            String base, String searchRaw, Map<String, String> headers) throws Exception {
        if (searchRaw == null || !searchRaw.startsWith("{")) return null;
        JSONArray animes = new JSONObject(searchRaw).optJSONArray("animes");
        if (animes == null || animes.length() == 0) return null;
        JSONArray eps = animes.getJSONObject(0).optJSONArray("episodes");
        if (eps == null || eps.length() == 0) return null;
        long epId = eps.getJSONObject(0).optLong("episodeId", 0);
        if (epId <= 0) return null;
        return TmdbService.httpGet(
                base + "/api/v2/comment/" + epId + "?withRelated=true&chConvert=1", headers);
    }

    /** Searches Assrt & OpenSubtitles REST APIs using user-supplied tokens. */
    static void searchOnlineSubtitlesAsync(
            final MainActivity a,
            final String queryTitle,
            final Callback<List<SubtitleCandidate>> callback) {
        if (a == null || callback == null) return;
        final String q = EpisodeNameCleaner.cleanSearchTitle(queryTitle);
        final String assrtToken = a.secretsPrefs().getString(Prefs.SECRET_ASSRT_TOKEN, "").trim();
        final String osApiKey =
                a.secretsPrefs().getString(Prefs.SECRET_OPENSUBTITLES_KEY, "").trim();

        a.worker.execute(
                () -> {
                    final List<SubtitleCandidate> list = new ArrayList<>();
                    if (!assrtToken.isEmpty() && !q.isEmpty()) {
                        try {
                            String url =
                                    "https://api.assrt.net/v1/sub/search?token="
                                            + URLEncoder.encode(assrtToken, "UTF-8")
                                            + "&q="
                                            + URLEncoder.encode(q, "UTF-8")
                                            + "&cnt=12&no_muxer=1";
                            String raw = TmdbService.httpGet(url, Collections.emptyMap());
                            JSONObject subObj =
                                    raw == null ? null : new JSONObject(raw).optJSONObject("sub");
                            JSONArray subs = subObj == null ? null : subObj.optJSONArray("subs");
                            if (subs != null) {
                                for (int i = 0; i < subs.length(); i++) {
                                    JSONObject item = subs.getJSONObject(i);
                                    String id = String.valueOf(item.optInt("id", 0));
                                    String name =
                                            item.optString(
                                                    "native_name", item.optString("videoname", q));
                                    String fmt = item.optString("subtype", "SRT");
                                    JSONObject langObj = item.optJSONObject("lang");
                                    String lang =
                                            langObj == null
                                                    ? "简繁双语"
                                                    : langObj.optString("desc", "中文");
                                    list.add(new SubtitleCandidate("assrt", id, name, lang, fmt));
                                }
                            }
                        } catch (Exception e) {
                            AppLog.w("OnlineSub", "Assrt search failed", e);
                        }
                    }

                    if (!osApiKey.isEmpty() && !q.isEmpty()) {
                        try {
                            Map<String, String> headers = new HashMap<>();
                            headers.put("Api-Key", osApiKey);
                            String url =
                                    "https://api.opensubtitles.com/api/v1/subtitles?query="
                                            + URLEncoder.encode(q, "UTF-8")
                                            + "&languages=zh-cn,zh-tw,en";
                            String raw = TmdbService.httpGet(url, headers);
                            JSONArray data =
                                    raw == null ? null : new JSONObject(raw).optJSONArray("data");
                            if (data != null) {
                                for (int i = 0; i < Math.min(12, data.length()); i++) {
                                    JSONObject attr =
                                            data.getJSONObject(i).optJSONObject("attributes");
                                    if (attr == null) continue;
                                    JSONArray files = attr.optJSONArray("files");
                                    if (files == null || files.length() == 0) continue;
                                    int fileId = files.getJSONObject(0).optInt("file_id", 0);
                                    if (fileId <= 0) continue;
                                    list.add(
                                            new SubtitleCandidate(
                                                    "opensubtitles",
                                                    String.valueOf(fileId),
                                                    attr.optString("release", q),
                                                    attr.optString("language", "zh"),
                                                    "SRT"));
                                }
                            }
                        } catch (Exception e) {
                            AppLog.w("OnlineSub", "OpenSubtitles search failed", e);
                        }
                    }

                    a.ui.post(
                            () -> {
                                if (!a.isFinishing()) callback.onResult(list);
                            });
                });
    }

    /** Immutable selection token captured synchronously the moment the user picks an online sub. */
    static final class SubtitleSelectionToken {
        final long sessionId;
        final int playbackGeneration;
        final String episodeIdentity;

        SubtitleSelectionToken(long sessionId, int playbackGeneration, String episodeIdentity) {
            this.sessionId = sessionId;
            this.playbackGeneration = playbackGeneration;
            this.episodeIdentity = episodeIdentity == null ? "" : episodeIdentity;
        }
    }

    /** API-23-safe live playback state reader for validating async online subtitle deliveries. */
    interface PlaybackStateProbe {
        boolean isExiting();

        int currentGeneration();

        String currentEpisodeIdentity();
    }

    /** Pure-JVM downloader + delivery callbacks for testing delayed online subtitle invalidation. */
    interface SubtitleDownloadExecutor {
        String downloadSrt() throws Exception;
    }

    interface SubtitleDeliverySink {
        void runAiTranslation(String srtText, SubtitleSelectionToken token) throws Exception;

        void mountPlainSubtitle(String srtText, SubtitleSelectionToken token) throws Exception;
    }

    static String captureEpisodeIdentity(MainActivity a) {
        if (a == null) return "";
        String siteKey =
                a.playbackControls != null && a.playbackControls.site != null
                        ? String.valueOf(a.playbackControls.site.key)
                        : "";
        String vidId =
                a.playbackControls != null && a.playbackControls.video != null
                        ? String.valueOf(a.playbackControls.video.id)
                        : "";
        String lineId = a.activeLine != null ? a.activeLine.lineId() : "";
        String epName =
                a.activeEpisode != null && a.activeEpisode.name != null ? a.activeEpisode.name : "";
        String epUrl =
                a.activeEpisode != null && a.activeEpisode.url != null ? a.activeEpisode.url : "";
        return siteKey + "|" + vidId + "|" + lineId + "|" + epName + "|" + epUrl;
    }

    static SubtitleSelectionToken beginSubtitleSelection(
            int playbackGeneration, String episodeIdentity) {
        return new SubtitleSelectionToken(
                AiSubtitleTranslator.beginActiveTranslationSession(),
                playbackGeneration,
                episodeIdentity);
    }

    static boolean isSelectionStillActive(SubtitleSelectionToken token, PlaybackStateProbe probe) {
        if (token == null || probe == null) return false;
        if (probe.isExiting()) return false;
        if (!AiSubtitleTranslator.isTranslationSessionActive(token.sessionId)) return false;
        if (probe.currentGeneration() != token.playbackGeneration) return false;
        String curEp = probe.currentEpisodeIdentity();
        return token.episodeIdentity.equals(curEp == null ? "" : curEp);
    }

    /**
     * Pure-JVM delayed download coordinator: binds {@code token} BEFORE downloading and re-checks
     * it before/after network fetch so turning off subtitles, switching tracks, switching episodes,
     * or exiting playback while downloading produces 0 model calls, 0 overlay writes, and 0 mounts.
     */
    static boolean completeSubtitleSelectionAfterDownload(
            SubtitleSelectionToken token,
            PlaybackStateProbe probe,
            boolean bilingualAiTranslate,
            SubtitleDownloadExecutor downloader,
            SubtitleDeliverySink sink)
            throws Exception {
        if (!isSelectionStillActive(token, probe) || downloader == null || sink == null) {
            return false;
        }
        String srt = downloader.downloadSrt();
        if (!isSelectionStillActive(token, probe)) {
            return false;
        }
        if (bilingualAiTranslate) {
            sink.runAiTranslation(srt, token);
        } else {
            sink.mountPlainSubtitle(srt, token);
        }
        return true;
    }

    static final String ORIGINAL_SUBTITLE_CACHE_DIR = "online_subs_v1";
    static final String AI_DERIVED_SUBTITLE_CACHE_DIR = "online_subs_ai_v1";

    static String sanitizeSubtitleCacheName(String fileName) {
        String base =
                fileName == null || fileName.trim().isEmpty() ? "subtitle.srt" : fileName.trim();
        String safe = base.replaceAll("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]", "_");
        return safe.isEmpty() ? "subtitle.srt" : safe;
    }

    /**
     * Computes a stable per-candidate cache namespace prefix from {@code (provider, id)} (or
     * fallback download URL) so two distinct online subtitle candidates sharing the same remote
     * filename (e.g. {@code movie.srt}) NEVER overwrite each other's cached original or AI files.
     */
    static String buildCandidateCachePrefix(SubtitleCandidate cand, String fallbackIdentity) {
        String provider =
                cand != null && cand.provider != null
                        ? cand.provider.trim().toLowerCase(Locale.ROOT)
                        : "";
        String id = cand != null && cand.id != null ? cand.id.trim() : "";
        String rawKey;
        if (!provider.isEmpty() || !id.isEmpty()) {
            rawKey = provider + "|" + id;
        } else if (fallbackIdentity != null && !fallbackIdentity.trim().isEmpty()) {
            rawKey = "file|" + fallbackIdentity.trim();
        } else {
            rawKey = "anon";
        }
        String cleanProvider = provider.replaceAll("[^a-z0-9]", "");
        if (cleanProvider.isEmpty()) cleanProvider = "sub";
        return cleanProvider + "_" + AiAssistantService.sha256(rawKey).substring(0, 12);
    }

    /**
     * Resolves the cache file for a downloaded plain/original online subtitle. Original subtitle
     * files live under {@code online_subs_v1/} keyed by candidate identity + filename so neither
     * AI-derived outputs nor another candidate with the same filename can overwrite it.
     */
    static File resolveOriginalSubtitleCacheFile(File cacheDir, String fileName) {
        return resolveOriginalSubtitleCacheFile(cacheDir, null, fileName);
    }

    static File resolveOriginalSubtitleCacheFile(
            File cacheDir, SubtitleCandidate cand, String fileName) {
        File subDir = new File(cacheDir, ORIGINAL_SUBTITLE_CACHE_DIR);
        if (!subDir.exists()) subDir.mkdirs();
        String safeName = sanitizeSubtitleCacheName(fileName);
        if (cand == null) {
            return new File(subDir, safeName);
        }
        return new File(subDir, buildCandidateCachePrefix(cand, safeName) + "__" + safeName);
    }

    /**
     * Resolves a dedicated cache file for an AI-translated derived subtitle under {@code
     * online_subs_ai_v1/}, strictly separate from {@link #resolveOriginalSubtitleCacheFile} and
     * scoped to the candidate identity so generating AI bilingual/Chinese output for candidate B
     * preserves candidate A's original subtitle bytes and track switching across Media3, MPV, and
     * SystemPlayer.
     */
    static File resolveAiDerivedSubtitleCacheFile(
            File cacheDir, String fileName, boolean bilingual) {
        return resolveAiDerivedSubtitleCacheFile(cacheDir, null, fileName, bilingual);
    }

    static File resolveAiDerivedSubtitleCacheFile(
            File cacheDir, SubtitleCandidate cand, String fileName, boolean bilingual) {
        File aiDir = new File(cacheDir, AI_DERIVED_SUBTITLE_CACHE_DIR);
        if (!aiDir.exists()) aiDir.mkdirs();
        String safe = sanitizeSubtitleCacheName(fileName);
        String prefixed =
                cand == null ? safe : (buildCandidateCachePrefix(cand, safe) + "__" + safe);
        return buildDerivedAiFileFromSafeName(aiDir, prefixed, bilingual);
    }

    static File buildDerivedAiFileFromSafeName(File aiDir, String safeBaseName, boolean bilingual) {
        if (!aiDir.exists()) aiDir.mkdirs();
        String safe = sanitizeSubtitleCacheName(safeBaseName);
        String stem = safe;
        String ext = ".srt";
        int dot = safe.lastIndexOf('.');
        if (dot > 0) {
            stem = safe.substring(0, dot);
            ext = safe.substring(dot);
        }
        String suffix = bilingual ? "__marco_ai_bi" : "__marco_ai_zh";
        return new File(aiDir, stem + suffix + ext);
    }

    /** Downloads a selected online subtitle candidate, optionally AI-translates it, and attaches. */
    static void downloadAndAttachSubtitleAsync(
            final MainActivity a,
            final SubtitleCandidate cand,
            final boolean bilingualAiTranslate) {
        if (a == null || cand == null) return;
        // Bind selection session, playback generation, and episode identity SYNCHRONOUSLY at tap
        // time BEFORE submitting background work so subtitle-off / track-switch / episode-switch /
        // exit during slow download strictly invalidates this request.
        final SubtitleSelectionToken selection =
                beginSubtitleSelection(a.generation, captureEpisodeIdentity(a));
        final PlaybackStateProbe stateProbe =
                new PlaybackStateProbe() {
                    @Override
                    public boolean isExiting() {
                        return a.isFinishing() || a.player == null || a.playbackControls == null;
                    }

                    @Override
                    public int currentGeneration() {
                        return a.generation;
                    }

                    @Override
                    public String currentEpisodeIdentity() {
                        return captureEpisodeIdentity(a);
                    }
                };
        a.toast("正在下载字幕：" + cand.title);
        a.worker.execute(
                () -> {
                    try {
                        if (!isSelectionStillActive(selection, stateProbe)) return;
                        String downloadUrl = "";
                        String fileName = "subtitle_" + cand.id + ".srt";
                        if ("assrt".equals(cand.provider)) {
                            String token =
                                    a.secretsPrefs().getString(Prefs.SECRET_ASSRT_TOKEN, "").trim();
                            String detailRaw =
                                    TmdbService.httpGet(
                                            "https://api.assrt.net/v1/sub/detail?token="
                                                    + URLEncoder.encode(token, "UTF-8")
                                                    + "&id="
                                                    + URLEncoder.encode(cand.id, "UTF-8"),
                                            Collections.emptyMap());
                            JSONArray subs =
                                    new JSONObject(detailRaw)
                                            .getJSONObject("sub")
                                            .getJSONArray("subs");
                            if (subs.length() > 0) {
                                JSONObject first = subs.getJSONObject(0);
                                JSONArray fileList = first.optJSONArray("filelist");
                                if (fileList != null && fileList.length() > 0) {
                                    for (int i = 0; i < fileList.length(); i++) {
                                        JSONObject f = fileList.getJSONObject(i);
                                        String fn = f.optString("f", "");
                                        if (fn.toLowerCase(Locale.ROOT).endsWith(".srt")
                                                || fn.toLowerCase(Locale.ROOT).endsWith(".ass")
                                                || fn.toLowerCase(Locale.ROOT).endsWith(".vtt")) {
                                            downloadUrl = f.optString("url", "");
                                            fileName = fn;
                                            break;
                                        }
                                    }
                                }
                                if (downloadUrl.isEmpty()) {
                                    downloadUrl = first.optString("url", "");
                                }
                            }
                        } else if ("opensubtitles".equals(cand.provider)) {
                            String osKey =
                                    a.secretsPrefs()
                                            .getString(Prefs.SECRET_OPENSUBTITLES_KEY, "")
                                            .trim();
                            HttpURLConnection conn =
                                    (HttpURLConnection)
                                            new URL("https://api.opensubtitles.com/api/v1/download")
                                                    .openConnection();
                            conn.setRequestMethod("POST");
                            conn.setDoOutput(true);
                            conn.setRequestProperty("Api-Key", osKey);
                            conn.setRequestProperty("Content-Type", "application/json");
                            conn.setRequestProperty("Accept", "application/json");
                            conn.setRequestProperty("User-Agent", Cms.USER_AGENT);
                            byte[] req =
                                    new JSONObject()
                                            .put("file_id", Integer.parseInt(cand.id))
                                            .toString()
                                            .getBytes("UTF-8");
                            try (OutputStream out = conn.getOutputStream()) {
                                out.write(req);
                            }
                            try (InputStream in = conn.getInputStream()) {
                                JSONObject resp = new JSONObject(Cms.read(in, 65536));
                                downloadUrl = resp.optString("link", "");
                                String fn = resp.optString("file_name", "");
                                if (!fn.isEmpty()) fileName = fn;
                            } finally {
                                conn.disconnect();
                            }
                        }

                        if (!isSelectionStillActive(selection, stateProbe)) return;
                        if (downloadUrl.isEmpty()) throw new java.io.IOException("未获取到直链字幕文件");

                        HttpURLConnection dl =
                                (HttpURLConnection) new URL(downloadUrl).openConnection();
                        dl.setConnectTimeout(12000);
                        dl.setReadTimeout(20000);
                        dl.setRequestProperty("User-Agent", Cms.USER_AGENT);
                        byte[] bytes;
                        try (InputStream in = dl.getInputStream();
                                ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                            byte[] buf = new byte[8192];
                            int n;
                            while ((n = in.read(buf)) != -1) {
                                if (!isSelectionStillActive(selection, stateProbe)) return;
                                if (bos.size() + n > 6 * 1024 * 1024) break;
                                bos.write(buf, 0, n);
                            }
                            bytes = bos.toByteArray();
                        } finally {
                            dl.disconnect();
                        }

                        if (!isSelectionStillActive(selection, stateProbe)) return;

                        final File outFile =
                                resolveOriginalSubtitleCacheFile(a.getCacheDir(), cand, fileName);
                        try (OutputStream out = new FileOutputStream(outFile)) {
                            out.write(bytes);
                        }

                        if (!isSelectionStillActive(selection, stateProbe)) return;

                        final boolean runAiBilingual =
                                bilingualAiTranslate
                                        && AiBetaGate.isUnlocked(a)
                                        && AiAssistantService.isConfigured(a)
                                        && outFile.getName()
                                                .toLowerCase(Locale.ROOT)
                                                .endsWith(".srt");
                        if (runAiBilingual) {
                            String showTitle =
                                    a.playbackControls != null
                                                    && a.playbackControls.video != null
                                                    && a.playbackControls.video.title != null
                                            ? a.playbackControls.video.title
                                            : cand.title;
                            long posMs =
                                    a.player != null && a.prepared
                                            ? Math.max(0L, a.player.getCurrentPosition())
                                            : 0L;
                            boolean bilingualPref =
                                    a.mobilePrefs().getBoolean(Prefs.SUBTITLE_BILINGUAL, true);
                            final File aiDerivedFile =
                                    resolveAiDerivedSubtitleCacheFile(
                                            a.getCacheDir(), cand, fileName, bilingualPref);
                            AiSubtitleTranslator.translateAndMountFullEpisodeAsync(
                                    a,
                                    showTitle,
                                    new String(bytes, "UTF-8"),
                                    aiDerivedFile,
                                    posMs,
                                    null,
                                    selection.sessionId,
                                    selection.playbackGeneration,
                                    selection.episodeIdentity);
                            a.ui.post(
                                    () -> {
                                        if (isSelectionStillActive(selection, stateProbe)) {
                                            a.toast("正在后台生成全片 AI 双语字幕，首段就绪后自动无打断呈现…");
                                        }
                                    });
                            return;
                        }

                        final String display = cand.title;
                        a.ui.post(
                                () -> {
                                    if (!isSelectionStillActive(selection, stateProbe)) return;
                                    if (a.playbackControls != null) {
                                        a.playbackControls.clearLiveAiSubtitles();
                                        a.playbackControls.setActiveSubtitleFile(outFile);
                                    }
                                    if (a.player != null && a.prepared) {
                                        try {
                                            a.player.addExternalSubtitle(
                                                    Uri.fromFile(outFile),
                                                    display,
                                                    MediaOptions.subtitleMime(
                                                            outFile.getName(), ""));
                                            a.toast("已挂载在线字幕：" + display);
                                        } catch (Exception ex) {
                                            a.toast("字幕挂载失败：" + a.message(ex));
                                        }
                                    } else {
                                        a.toast("字幕已缓存：" + outFile.getName());
                                    }
                                });
                    } catch (Exception e) {
                        if (isSelectionStillActive(selection, stateProbe)) {
                            a.ui.post(
                                    () -> {
                                        if (isSelectionStillActive(selection, stateProbe)) {
                                            a.toast("在线字幕下载失败：" + a.message(e));
                                        }
                                    });
                        }
                    }
                });
    }
}

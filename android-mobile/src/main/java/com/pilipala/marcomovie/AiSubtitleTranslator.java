package com.pilipala.marcomovie;

import android.net.Uri;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Full-episode sliding-window AI bilingual subtitle translator and spoiler-safe subtitle context
 * extractor.
 *
 * <p>Key guarantees:
 * <ol>
 *   <li>Unlimited full-episode SRT parsing &amp; lossless tail preservation.
 *   <li>Per-chunk automatic retry (up to {@link #MAX_CHUNK_ATTEMPTS} attempts) on transient model
 *       or JSON shape errors.
 *   <li>Strict completion cache gate: writes the full-episode completion disk cache ONLY when 100%
 *       of cues ({@code translatedCues == totalCues}) succeeded — partial failures never poison the
 *       cache.
 *   <li>Zero mid-playback {@code exo.prepare()} interruptions: live progressive translations render
 *       directly on {@link SubtitleOverlayView} via {@link PlaybackControls#setLiveAiSubtitles}
 *       while maintaining a single deduplicated subtitle track in {@link MoviePlayer}.
 *   <li>Strict anti-spoiler context cutoff: {@link #extractContextAround} returns ONLY dialogue
 *       already reached at or before {@code positionMs}, excluding all future lines.
 * </ol>
 */
final class AiSubtitleTranslator {
    static final int DEFAULT_CHUNK_SIZE = 25;
    static final int MAX_CHUNK_ATTEMPTS = 3;
    static final int COMPLETION_CACHE_VERSION = 2;
    static final String COMPLETION_CACHE_PREFIX = "subfull_v2_";
    static final String AI_TRACK_NAME = "AI 全片双语字幕";
    private static final java.util.concurrent.atomic.AtomicLong ACTIVE_TRANSLATION_SESSION =
            new java.util.concurrent.atomic.AtomicLong(0L);

    static long beginActiveTranslationSession() {
        return ACTIVE_TRANSLATION_SESSION.incrementAndGet();
    }

    static boolean isTranslationSessionActive(long sessionId) {
        return sessionId > 0L && ACTIVE_TRANSLATION_SESSION.get() == sessionId;
    }

    /**
     * Cancels any in-flight background subtitle translation session (e.g. when the user explicitly
     * turns subtitles off or switches to another subtitle track) so late chunks or async mount
     * callbacks NEVER overwrite the user's selection.
     */
    static void cancelActiveTranslation() {
        ACTIVE_TRANSLATION_SESSION.incrementAndGet();
    }

    private static final Pattern SRT_BLOCK =
            Pattern.compile(
                    "(?m)^(\\d+)\\s*\\r?\\n(\\d{2}:\\d{2}:\\d{2}[,\\.]\\d{3}\\s*-->\\s*\\d{2}:\\d{2}:\\d{2}[,\\.]\\d{3}[^\\r\\n]*)\\r?\\n([\\s\\S]*?)(?=\\r?\\n\\r?\\n|\\z)");
    private static final Pattern TIME_RANGE =
            Pattern.compile(
                    "(\\d{2}):(\\d{2}):(\\d{2})[,\\.](\\d{3})\\s*-->\\s*(\\d{2}):(\\d{2}):(\\d{2})[,\\.](\\d{3})");
    private static final Pattern HTML_TAG = Pattern.compile("<[^>]+>");

    static final class SrtCue {
        final String index;
        final String timingLine;
        final long startMs;
        final long endMs;
        final String body;

        SrtCue(String index, String timingLine, long startMs, long endMs, String body) {
            this.index = index;
            this.timingLine = timingLine;
            this.startMs = startMs;
            this.endMs = endMs;
            this.body = body;
        }

        String singleLinePlain() {
            return HTML_TAG.matcher(body).replaceAll("").replace('\n', ' ').trim();
        }
    }

    interface ChunkTranslator {
        ChunkTranslation translate(
                String showTitle, List<String> sourceLines, Map<String, String> glossary)
                throws Exception;
    }

    static final class ChunkTranslation {
        final List<String> zhLines;
        final Map<String, String> newGlossary;

        ChunkTranslation(List<String> zhLines, Map<String, String> newGlossary) {
            this.zhLines = zhLines;
            this.newGlossary = newGlossary;
        }
    }

    static final class TranslationRunResult {
        final String renderedSrt;
        final int translatedCues;
        final int totalCues;
        final int retriedChunks;
        final int failedChunks;
        final boolean shouldCacheCompletion;

        TranslationRunResult(
                String renderedSrt,
                int translatedCues,
                int totalCues,
                int retriedChunks,
                int failedChunks,
                boolean shouldCacheCompletion) {
            this.renderedSrt = renderedSrt;
            this.translatedCues = translatedCues;
            this.totalCues = totalCues;
            this.retriedChunks = retriedChunks;
            this.failedChunks = failedChunks;
            this.shouldCacheCompletion = shouldCacheCompletion;
        }
    }

    interface ProgressListener {
        void onPartialReady(File srtFile, int translatedCues, int totalCues, boolean completed);
    }

    private AiSubtitleTranslator() {}

    static List<SrtCue> parseSrt(String srtText) {
        List<SrtCue> cues = new ArrayList<>();
        if (srtText == null || srtText.trim().isEmpty()) return cues;
        String normalized = srtText;
        if (normalized.startsWith("\uFEFF")) normalized = normalized.substring(1);
        normalized = normalized.replace("\r\n", "\n").replace('\r', '\n');
        Matcher m = SRT_BLOCK.matcher(normalized);
        while (m.find()) {
            String idx = m.group(1).trim();
            String timing = m.group(2).trim();
            String body = m.group(3).trim();
            if (body.isEmpty()) continue;
            long startMs = 0L;
            long endMs = 0L;
            Matcher tm = TIME_RANGE.matcher(timing);
            if (tm.find()) {
                startMs = parseTimeMs(tm.group(1), tm.group(2), tm.group(3), tm.group(4));
                endMs = parseTimeMs(tm.group(5), tm.group(6), tm.group(7), tm.group(8));
            }
            cues.add(new SrtCue(idx, timing, startMs, endMs, body));
        }
        return cues;
    }

    private static long parseTimeMs(String h, String m, String s, String ms) {
        try {
            return Long.parseLong(h) * 3600_000L
                    + Long.parseLong(m) * 60_000L
                    + Long.parseLong(s) * 1000L
                    + Long.parseLong(ms);
        } catch (Exception e) {
            return 0L;
        }
    }

    static int findCueIndexAt(List<SrtCue> cues, long positionMs) {
        if (cues == null || cues.isEmpty()) return 0;
        if (positionMs <= 0L) return 0;
        for (int i = 0; i < cues.size(); i++) {
            SrtCue c = cues.get(i);
            if (positionMs <= c.endMs) return i;
        }
        return cues.size() - 1;
    }

    /**
     * Looks up the active subtitle line at {@code positionMs} for live zero-interruption overlay
     * rendering during progressive full-episode translation.
     */
    static String activeCueTextAt(
            List<SrtCue> cues, String[] translations, long positionMs, boolean bilingual) {
        if (cues == null || cues.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < cues.size(); i++) {
            SrtCue c = cues.get(i);
            if (positionMs < c.startMs) break;
            if (positionMs >= c.startMs && positionMs <= c.endMs) {
                if (sb.length() > 0) sb.append('\n');
                String zh =
                        translations != null && i < translations.length && translations[i] != null
                                ? translations[i].trim()
                                : "";
                if (!zh.isEmpty()) {
                    sb.append(zh);
                    if (bilingual) sb.append('\n').append(c.singleLinePlain());
                } else if (translations == null) {
                    // Pre-rendered cached bilingual SRT cues already carry line breaks in c.body.
                    sb.append(HTML_TAG.matcher(c.body).replaceAll("").trim());
                } else {
                    sb.append(c.singleLinePlain());
                }
            }
        }
        return sb.toString();
    }

    static int countTranslatedCues(String[] translations) {
        if (translations == null) return 0;
        int n = 0;
        for (String t : translations) {
            if (t != null && !t.trim().isEmpty()) n++;
        }
        return n;
    }

    /** Only 100% completed episodes may populate the full-episode completion disk cache. */
    static boolean shouldWriteCompletionCache(int translatedCues, int totalCues) {
        return totalCues > 0 && translatedCues == totalCues;
    }

    /**
     * Encodes a versioned, completion-marked full-episode cache envelope (v2). Refuses to encode
     * partial translations so legacy/half-translated SRT files can never be mistaken for complete.
     */
    static String encodeCompletionCache(
            String srt, int translatedCues, int totalCues, boolean bilingual) {
        if (!shouldWriteCompletionCache(translatedCues, totalCues)) return null;
        if (srt == null || srt.trim().isEmpty()) return null;
        if (parseSrt(srt).size() != totalCues) return null;
        try {
            JSONObject obj = new JSONObject();
            obj.put("cache_version", COMPLETION_CACHE_VERSION);
            obj.put("complete", true);
            obj.put("bilingual", bilingual);
            obj.put("total_cues", totalCues);
            obj.put("translated_cues", translatedCues);
            obj.put("srt", srt);
            return obj.toString();
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Verifies and unwraps a v2 full-episode completion cache payload. Rejects legacy raw SRT
     * strings (even if they preserved all cue indices while translating only half), older cache
     * versions, mismatched bilingual mode, or incomplete cue counts.
     */
    static String decodeVerifiedCompletionCache(
            String rawCache, int expectedTotalCues, boolean expectedBilingual) {
        if (rawCache == null || expectedTotalCues <= 0) return null;
        String trimmed = rawCache.trim();
        if (!trimmed.startsWith("{")) return null;
        try {
            JSONObject obj = new JSONObject(trimmed);
            if (obj.optInt("cache_version", 0) != COMPLETION_CACHE_VERSION) return null;
            if (!obj.optBoolean("complete", false)) return null;
            if (obj.optBoolean("bilingual", !expectedBilingual) != expectedBilingual) return null;
            int total = obj.optInt("total_cues", 0);
            int translated = obj.optInt("translated_cues", 0);
            if (total != expectedTotalCues || translated != expectedTotalCues) return null;
            String srt = obj.optString("srt", "");
            if (srt.trim().isEmpty()) return null;
            if (parseSrt(srt).size() != expectedTotalCues) return null;
            return srt;
        } catch (Exception e) {
            return null;
        }
    }

    /** Pure-JVM engine mount abstraction verifying Media3 / MPV / SystemPlayer subtitle mounting. */
    interface SubtitleMountTarget {
        void setLiveOverlay(List<SrtCue> cues, String[] translations, boolean bilingual);

        void clearLiveOverlay();

        boolean upsertExternalSubtitle(
                String uri, String name, String mime, boolean reloadMediaSource, Runnable onMounted)
                throws Exception;
    }

    /** API-23-safe activity/session predicate checked before applying subtitle overlay or mounts. */
    interface ActivityCheck {
        boolean isActive();
    }

    /**
     * Safe mount order shared across Media3, MPV, and SystemPlayer: ALWAYS keeps/populates live
     * overlay first and clears it ONLY inside {@code onMounted} after the engine successfully
     * mounts the track, logging any failure instead of silently swallowing it.
     */
    static boolean applySubtitleMountSafely(
            SubtitleMountTarget target,
            String uri,
            String mime,
            List<SrtCue> cues,
            String[] translations,
            boolean bilingual,
            boolean reloadMediaSource) {
        return applySubtitleMountSafely(
                target, uri, mime, cues, translations, bilingual, reloadMediaSource, null);
    }

    static boolean applySubtitleMountSafely(
            SubtitleMountTarget target,
            String uri,
            String mime,
            List<SrtCue> cues,
            String[] translations,
            boolean bilingual,
            boolean reloadMediaSource,
            final ActivityCheck stillActive) {
        if (target == null) return false;
        if (stillActive != null && !stillActive.isActive()) return false;
        target.setLiveOverlay(cues, translations, bilingual);
        try {
            target.upsertExternalSubtitle(
                    uri,
                    AI_TRACK_NAME,
                    mime,
                    reloadMediaSource,
                    () -> {
                        if (stillActive == null || stillActive.isActive()) {
                            target.clearLiveOverlay();
                        }
                    });
            return true;
        } catch (Exception ex) {
            AppLog.w(
                    "AiSubtitleTranslator",
                    "upsertExternalSubtitle failed; keeping live overlay",
                    ex);
            return false;
        }
    }

    /**
     * Plans sliding-window chunk order prioritized around {@code focusCueIndex}: current chunk
     * first, then forward chunks ahead of playback, interleaved with backward backfill.
     */
    static List<int[]> planSlidingChunks(int totalCues, int focusCueIndex, int chunkSize) {
        List<int[]> plan = new ArrayList<>();
        if (totalCues <= 0) return plan;
        int size = Math.max(1, chunkSize);
        int numChunks = (totalCues + size - 1) / size;
        int clampedFocus = Math.max(0, Math.min(totalCues - 1, focusCueIndex));
        int focusChunk = clampedFocus / size;

        boolean[] scheduled = new boolean[numChunks];
        addChunkIfNew(plan, scheduled, focusChunk, size, totalCues);
        addChunkIfNew(plan, scheduled, focusChunk + 1, size, totalCues);
        addChunkIfNew(plan, scheduled, focusChunk + 2, size, totalCues);
        int fwd = focusChunk + 3;
        int bwd = focusChunk - 1;
        while (fwd < numChunks || bwd >= 0) {
            if (fwd < numChunks) addChunkIfNew(plan, scheduled, fwd++, size, totalCues);
            if (fwd < numChunks) addChunkIfNew(plan, scheduled, fwd++, size, totalCues);
            if (bwd >= 0) addChunkIfNew(plan, scheduled, bwd--, size, totalCues);
        }
        return plan;
    }

    private static void addChunkIfNew(
            List<int[]> plan, boolean[] scheduled, int chunkIdx, int size, int totalCues) {
        if (chunkIdx < 0 || chunkIdx >= scheduled.length || scheduled[chunkIdx]) return;
        scheduled[chunkIdx] = true;
        int start = chunkIdx * size;
        int end = Math.min(totalCues, start + size);
        plan.add(new int[] {start, end});
    }

    /**
     * Losslessly renders ALL cues in the episode. Any cue with a non-empty translation renders
     * bilingual (or Chinese-only); any untranslated cue preserves its original text intact.
     */
    static String renderSrt(List<SrtCue> cues, String[] translations, boolean bilingual) {
        StringBuilder sb = new StringBuilder(cues.size() * 96);
        for (int i = 0; i < cues.size(); i++) {
            SrtCue c = cues.get(i);
            String zh =
                    translations != null && i < translations.length && translations[i] != null
                            ? translations[i].trim()
                            : "";
            sb.append(c.index).append('\n').append(c.timingLine).append('\n');
            if (!zh.isEmpty()) {
                sb.append(zh);
                if (bilingual) {
                    sb.append('\n').append(c.body);
                }
            } else {
                sb.append(c.body);
            }
            sb.append("\n\n");
        }
        return sb.toString();
    }

    /**
     * Pure-JVM full-episode translation runner with per-chunk retry and exact completion accounting.
     */
    static TranslationRunResult translateFullEpisodeWithStats(
            String showTitle,
            String srtText,
            long currentPositionMs,
            int chunkSize,
            boolean bilingual,
            ChunkTranslator translator) {
        List<SrtCue> cues = parseSrt(srtText);
        if (cues.isEmpty()) {
            return new TranslationRunResult(srtText == null ? "" : srtText, 0, 0, 0, 0, false);
        }
        String[] translations = new String[cues.size()];
        Map<String, String> glossary = new LinkedHashMap<>();
        int focusIdx = findCueIndexAt(cues, currentPositionMs);
        List<int[]> chunks = planSlidingChunks(cues.size(), focusIdx, chunkSize);
        int retriedChunks = 0;
        int failedChunks = 0;

        for (int[] range : chunks) {
            List<String> lines = new ArrayList<>(range[1] - range[0]);
            for (int i = range[0]; i < range[1]; i++) {
                lines.add(cues.get(i).singleLinePlain());
            }
            ChunkTranslation res = null;
            for (int attempt = 1; attempt <= MAX_CHUNK_ATTEMPTS; attempt++) {
                if (attempt > 1) retriedChunks++;
                try {
                    ChunkTranslation cand = translator.translate(showTitle, lines, glossary);
                    if (isCompleteChunkTranslation(cand, lines.size())) {
                        res = cand;
                        break;
                    }
                } catch (Exception ignored) {
                }
            }
            if (res != null) {
                for (int i = 0; i < lines.size(); i++) {
                    translations[range[0] + i] = res.zhLines.get(i).trim();
                }
                if (res.newGlossary != null) {
                    for (Map.Entry<String, String> e : res.newGlossary.entrySet()) {
                        if (glossary.size() >= 24) break;
                        if (e.getKey() != null
                                && !e.getKey().trim().isEmpty()
                                && e.getValue() != null
                                && !e.getValue().trim().isEmpty()) {
                            glossary.put(e.getKey().trim(), e.getValue().trim());
                        }
                    }
                }
            } else {
                failedChunks++;
            }
        }
        int done = countTranslatedCues(translations);
        boolean cacheOk = shouldWriteCompletionCache(done, cues.size());
        return new TranslationRunResult(
                renderSrt(cues, translations, bilingual),
                done,
                cues.size(),
                retriedChunks,
                failedChunks,
                cacheOk);
    }

    private static boolean isCompleteChunkTranslation(ChunkTranslation res, int expectedSize) {
        if (res == null || res.zhLines == null || res.zhLines.size() != expectedSize) return false;
        for (int i = 0; i < expectedSize; i++) {
            String s = res.zhLines.get(i);
            if (s == null || s.trim().isEmpty()) return false;
        }
        return true;
    }

    /** Pure-JVM full-episode translation runner (testable with mock {@link ChunkTranslator}). */
    static String translateFullEpisodeSync(
            String showTitle,
            String srtText,
            long currentPositionMs,
            int chunkSize,
            boolean bilingual,
            ChunkTranslator translator) {
        return translateFullEpisodeWithStats(
                        showTitle, srtText, currentPositionMs, chunkSize, bilingual, translator)
                .renderedSrt;
    }

    /**
     * Extracts spoiler-free dialogue lines strictly up to {@code positionMs} (window {@code
     * [max(0, positionMs - windowMs) .. positionMs]}). Any future cue with {@code startMs >
     * positionMs} is unconditionally excluded so neither UI preview nor LLM prompts ever leak
     * unplayed dialogue.
     */
    static String extractContextAround(List<SrtCue> cues, long positionMs, long windowMs) {
        if (cues == null || cues.isEmpty()) return "";
        long cutoff = Math.max(0L, positionMs);
        long win = Math.max(5000L, windowMs);
        long from = Math.max(0L, cutoff - win);
        List<SrtCue> matched = new ArrayList<>();
        for (SrtCue c : cues) {
            if (c.startMs > cutoff) continue;
            if (c.endMs >= from) {
                matched.add(c);
            }
        }
        if (matched.isEmpty()) return "";
        int startIdx = Math.max(0, matched.size() - 12);
        StringBuilder sb = new StringBuilder();
        for (int i = startIdx; i < matched.size(); i++) {
            SrtCue c = matched.get(i);
            if (i > startIdx) sb.append('\n');
            sb.append('[').append(formatShortClock(c.startMs)).append("] ");
            sb.append(c.singleLinePlain());
        }
        return sb.toString();
    }

    static String extractContextAroundFile(File srtFile, long positionMs, long windowMs) {
        if (srtFile == null || !srtFile.exists() || !srtFile.isFile()) return "";
        try (InputStream in = new FileInputStream(srtFile)) {
            String raw = Cms.read(in, 2 * 1024 * 1024);
            return extractContextAround(parseSrt(raw), positionMs, windowMs);
        } catch (Exception ignored) {
            return "";
        }
    }

    static String formatShortClock(long ms) {
        long sec = Math.max(0L, ms / 1000L);
        long h = sec / 3600L;
        long m = (sec % 3600L) / 60L;
        long s = sec % 60L;
        if (h > 0) return String.format(Locale.US, "%d:%02d:%02d", h, m, s);
        return String.format(Locale.US, "%02d:%02d", m, s);
    }

    static ChunkTranslation parseChunkResponse(String rawReply, int expectedSize) {
        JSONObject obj = AiAssistantService.extractJsonObject(rawReply);
        if (obj == null) return null;
        JSONArray zhArr = obj.optJSONArray("zh");
        if (zhArr == null || zhArr.length() != expectedSize) return null;
        List<String> zh = new ArrayList<>(expectedSize);
        for (int i = 0; i < expectedSize; i++) {
            zh.add(zhArr.optString(i, ""));
        }
        Map<String, String> gloss = new LinkedHashMap<>();
        JSONObject gObj = obj.optJSONObject("glossary");
        if (gObj != null) {
            Iterator<String> keys = gObj.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                String v = gObj.optString(k, "").trim();
                if (!k.trim().isEmpty() && !v.isEmpty()) {
                    gloss.put(k.trim(), v);
                }
            }
        }
        return new ChunkTranslation(zh, gloss);
    }

    /**
     * Full-episode background sliding-window AI bilingual subtitle synthesis for Android Mobile.
     * Renders progressive chunks live on {@link SubtitleOverlayView} without interrupting video
     * playback via repeated {@code exo.prepare()}, deduplicates the single subtitle track in {@link
     * MoviePlayer}, retries failed chunks, and writes the completion disk cache ONLY on 100%
     * success.
     */
    static void translateAndMountFullEpisodeAsync(
            final MainActivity a,
            final String showTitle,
            final String rawSrtText,
            final File targetFile,
            final long currentPositionMs,
            final ProgressListener listener) {
        if (a == null) return;
        translateAndMountFullEpisodeAsync(
                a,
                showTitle,
                rawSrtText,
                targetFile,
                currentPositionMs,
                listener,
                beginActiveTranslationSession(),
                a.generation,
                OnlineSubtitleDanmakuService.captureEpisodeIdentity(a));
    }

    static void translateAndMountFullEpisodeAsync(
            final MainActivity a,
            final String showTitle,
            final String rawSrtText,
            final File targetFile,
            final long currentPositionMs,
            final ProgressListener listener,
            final long preBoundSessionId,
            final int preBoundTicket,
            final String preBoundEpisodeIdentity) {
        if (a == null
                || !AiBetaGate.isUnlocked(a)
                || !AiAssistantService.isConfigured(a)
                || targetFile == null) {
            return;
        }
        final long sessionId =
                preBoundSessionId > 0L ? preBoundSessionId : beginActiveTranslationSession();
        final int ticket = preBoundTicket >= 0 ? preBoundTicket : a.generation;
        final String boundEpId = preBoundEpisodeIdentity == null ? "" : preBoundEpisodeIdentity;
        if (!isTranslationSessionActive(sessionId) || ticket != a.generation) {
            return;
        }
        final List<SrtCue> cues = parseSrt(rawSrtText);
        if (cues.isEmpty()) return;

        final boolean bilingual = a.mobilePrefs().getBoolean(Prefs.SUBTITLE_BILINGUAL, true);
        final String fullCacheKey =
                COMPLETION_CACHE_PREFIX
                        + AiAssistantService.sha256((bilingual ? "bi|" : "zh|") + rawSrtText);

        a.worker.execute(
                () -> {
                    try {
                        if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) return;
                        String rawCache = AiAssistantService.readDiskCache(a, fullCacheKey);
                        String cachedSrt =
                                decodeVerifiedCompletionCache(rawCache, cues.size(), bilingual);
                        if (cachedSrt != null) {
                            if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) return;
                            writeUtf8(targetFile, cachedSrt);
                            List<SrtCue> cachedCues = parseSrt(cachedSrt);
                            updateOverlayAndSingleTrackOnUi(
                                    a,
                                    ticket,
                                    sessionId,
                                    boundEpId,
                                    targetFile,
                                    cachedCues,
                                    null,
                                    bilingual,
                                    true,
                                    "已加载缓存的全片 AI 双语字幕（" + cues.size() + " 条）",
                                    listener,
                                    cues.size(),
                                    cues.size(),
                                    true);
                            return;
                        }

                        final String[] translations = new String[cues.size()];
                        final Map<String, String> glossary = new LinkedHashMap<>();
                        int focusIdx = findCueIndexAt(cues, currentPositionMs);
                        List<int[]> chunks =
                                planSlidingChunks(cues.size(), focusIdx, DEFAULT_CHUNK_SIZE);

                        for (int cIdx = 0; cIdx < chunks.size(); cIdx++) {
                            if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) return;
                            if (!AiBetaGate.isUnlocked(a)) return;
                            int[] range = chunks.get(cIdx);
                            List<String> lines = new ArrayList<>(range[1] - range[0]);
                            for (int i = range[0]; i < range[1]; i++) {
                                lines.add(cues.get(i).singleLinePlain());
                            }
                            ChunkTranslation res = null;
                            for (int attempt = 1; attempt <= MAX_CHUNK_ATTEMPTS; attempt++) {
                                if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) return;
                                try {
                                    ChunkTranslation cand =
                                            requestChunkFromModel(a, showTitle, lines, glossary);
                                    if (isCompleteChunkTranslation(cand, lines.size())) {
                                        res = cand;
                                        break;
                                    }
                                } catch (Exception retryErr) {
                                    AppLog.w(
                                            "AiSubtitleTranslator",
                                            "Chunk " + cIdx + " attempt " + attempt + " failed",
                                            retryErr);
                                }
                                if (attempt < MAX_CHUNK_ATTEMPTS) {
                                    try {
                                        Thread.sleep(350L * attempt);
                                    } catch (InterruptedException ie) {
                                        Thread.currentThread().interrupt();
                                        return;
                                    }
                                }
                            }
                            if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) return;
                            if (res != null) {
                                for (int i = 0; i < lines.size(); i++) {
                                    translations[range[0] + i] = res.zhLines.get(i).trim();
                                }
                                if (res.newGlossary != null) {
                                    for (Map.Entry<String, String> e : res.newGlossary.entrySet()) {
                                        if (glossary.size() >= 24) break;
                                        glossary.put(e.getKey(), e.getValue());
                                    }
                                }
                            }
                            int translatedCount = countTranslatedCues(translations);
                            boolean isFirst = (cIdx == 0);
                            boolean isLast = (cIdx == chunks.size() - 1);
                            boolean isMilestone = (cIdx > 0 && cIdx % 4 == 0);
                            if (isFirst || isMilestone || isLast) {
                                String rendered = renderSrt(cues, translations, bilingual);
                                if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) return;
                                writeUtf8(targetFile, rendered);
                                boolean fullyDone =
                                        isLast
                                                && shouldWriteCompletionCache(
                                                        translatedCount, cues.size());
                                if (fullyDone) {
                                    String envelope =
                                            encodeCompletionCache(
                                                    rendered,
                                                    translatedCount,
                                                    cues.size(),
                                                    bilingual);
                                    if (envelope != null) {
                                        AiAssistantService.writeDiskCache(
                                                a, fullCacheKey, envelope);
                                    }
                                }
                                if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) return;
                                String toastMsg =
                                        isLast
                                                ? (fullyDone
                                                        ? ("全片 AI 双语字幕已完整生成（共 "
                                                                + translatedCount
                                                                + " 条）")
                                                        : ("已完成 "
                                                                + translatedCount
                                                                + "/"
                                                                + cues.size()
                                                                + " 条双语字幕（部分片段失败，未写入完成缓存，下次进入可补译）"))
                                                : (isFirst
                                                        ? ("当前片段 AI 双语字幕已就绪，其余 "
                                                                + (cues.size() - translatedCount)
                                                                + " 条正在后台无打断续译…")
                                                        : "");
                                updateOverlayAndSingleTrackOnUi(
                                        a,
                                        ticket,
                                        sessionId,
                                        boundEpId,
                                        targetFile,
                                        cues,
                                        translations.clone(),
                                        bilingual,
                                        false,
                                        toastMsg,
                                        listener,
                                        translatedCount,
                                        cues.size(),
                                        fullyDone);
                            } else if (res != null) {
                                // Still refresh live overlay immediately without disk churn or
                                // player prepare().
                                final String[] snap = translations.clone();
                                a.ui.post(
                                        () -> {
                                            if (!isSessionStillBound(
                                                    a, sessionId, ticket, boundEpId)) {
                                                return;
                                            }
                                            if (a.playbackControls != null) {
                                                a.playbackControls.setLiveAiSubtitles(
                                                        cues, snap, bilingual);
                                            }
                                        });
                            }
                        }
                    } catch (Exception e) {
                        AppLog.w("AiSubtitleTranslator", "Full-episode translation failed", e);
                    }
                });
    }

    private static boolean isSessionStillBound(
            MainActivity a, long sessionId, int ticket, String boundEpId) {
        if (a == null
                || a.isFinishing()
                || ticket != a.generation
                || !isTranslationSessionActive(sessionId)) {
            return false;
        }
        if (boundEpId != null && !boundEpId.isEmpty()) {
            String curEp = OnlineSubtitleDanmakuService.captureEpisodeIdentity(a);
            return boundEpId.equals(curEp);
        }
        return true;
    }

    private static ChunkTranslation requestChunkFromModel(
            MainActivity a, String showTitle, List<String> lines, Map<String, String> glossary)
            throws Exception {
        StringBuilder sys = new StringBuilder("你是专业影视字幕翻译专家。将输入外语台词数组逐条自然译为简体中文，贴合影视口语语境、简洁不啰嗦。");
        sys.append("严格只返回 JSON 对象：{\"zh\":[\"译文1\",...],\"glossary\":{\"专有名词\":\"译名\"}}。");
        sys.append("其中 zh 数组长度必须与输入完全一致（共 ")
                .append(lines.size())
                .append(" 条）；glossary 仅列本段重要人名/专有名词（可为空对象）。");
        StringBuilder usr = new StringBuilder();
        if (showTitle != null && !showTitle.trim().isEmpty()) {
            usr.append("影片名称：").append(showTitle.trim()).append('\n');
        }
        if (glossary != null && !glossary.isEmpty()) {
            usr.append("请严格沿用以下已定人名/专有名词译法：")
                    .append(new JSONObject(glossary).toString())
                    .append('\n');
        }
        usr.append("台词数组：").append(new JSONArray(lines).toString());
        String reply =
                AiAssistantService.chatCompletion(a, sys.toString(), usr.toString(), 2400, 0.2);
        return parseChunkResponse(reply, lines.size());
    }

    private static void updateOverlayAndSingleTrackOnUi(
            final MainActivity a,
            final int ticket,
            final long sessionId,
            final String boundEpId,
            final File targetFile,
            final List<SrtCue> cues,
            final String[] translations,
            final boolean bilingual,
            final boolean reloadPlayerMediaSource,
            final String toastMsg,
            final ProgressListener listener,
            final int done,
            final int total,
            final boolean completed) {
        a.ui.post(
                () -> {
                    if (!isSessionStillBound(a, sessionId, ticket, boundEpId)) {
                        return;
                    }
                    if (a.playbackControls != null) {
                        a.playbackControls.setActiveSubtitleFile(targetFile);
                    }
                    final boolean effectiveReload =
                            reloadPlayerMediaSource
                                    || (completed && a.player instanceof SystemPlayer);
                    final ActivityCheck stillActive =
                            () -> isSessionStillBound(a, sessionId, ticket, boundEpId);
                    if (a.player != null && a.prepared) {
                        final Uri subUri = Uri.fromFile(targetFile);
                        final String mime = MediaOptions.subtitleMime(targetFile.getName(), "");
                        SubtitleMountTarget mountTarget =
                                new SubtitleMountTarget() {
                                    @Override
                                    public void setLiveOverlay(
                                            List<SrtCue> c, String[] t, boolean bi) {
                                        if (a.playbackControls != null && stillActive.isActive()) {
                                            a.playbackControls.setLiveAiSubtitles(c, t, bi);
                                        }
                                    }

                                    @Override
                                    public void clearLiveOverlay() {
                                        if (a.playbackControls != null && stillActive.isActive()) {
                                            a.playbackControls.clearLiveAiSubtitles();
                                        }
                                    }

                                    @Override
                                    public boolean upsertExternalSubtitle(
                                            String u,
                                            String n,
                                            String m,
                                            boolean reload,
                                            Runnable onMounted) {
                                        return a.player.upsertAiGeneratedSubtitle(
                                                subUri, n, m, reload, onMounted);
                                    }
                                };
                        applySubtitleMountSafely(
                                mountTarget,
                                subUri.toString(),
                                mime,
                                cues,
                                translations,
                                bilingual,
                                effectiveReload,
                                stillActive);
                        if (toastMsg != null && !toastMsg.isEmpty() && stillActive.isActive()) {
                            a.toast(toastMsg);
                        }
                    } else if (a.playbackControls != null && stillActive.isActive()) {
                        a.playbackControls.setLiveAiSubtitles(cues, translations, bilingual);
                    }
                    if (listener != null && stillActive.isActive()) {
                        listener.onPartialReady(targetFile, done, total, completed);
                    }
                });
    }

    private static void writeUtf8(File f, String content) throws Exception {
        try (OutputStream out = new FileOutputStream(f)) {
            out.write(content.getBytes(StandardCharsets.UTF_8));
        }
    }
}

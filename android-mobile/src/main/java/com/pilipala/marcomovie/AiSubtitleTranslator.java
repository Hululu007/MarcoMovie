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
 * Full-episode sliding-window AI bilingual subtitle translator and subtitle context extractor.
 *
 * <p>Replaces the legacy 40-cue truncation with:
 * <ol>
 *   <li>Unlimited full-episode SRT parsing &amp; lossless tail preservation (untranslated cues
 *       always remain intact while background chunks finish).
 *   <li>Playback-position-aware sliding-window scheduling: translates the chunk at the user's
 *       current playback timestamp FIRST, then expands forward before backfilling earlier cues.
 *   <li>Glossary consistency: extracts recurring character names / proper nouns from the first
 *       chunk and injects them into subsequent chunks.
 *   <li>Local context extraction around any playback timestamp for the AI Cinema Copilot Q&amp;A.
 * </ol>
 */
final class AiSubtitleTranslator {
    static final int DEFAULT_CHUNK_SIZE = 25;

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
        // Prioritize two chunks immediately ahead of current playback so viewer never hits
        // untranslated text
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

    /** Pure-JVM full-episode translation runner (testable with mock {@link ChunkTranslator}). */
    static String translateFullEpisodeSync(
            String showTitle,
            String srtText,
            long currentPositionMs,
            int chunkSize,
            boolean bilingual,
            ChunkTranslator translator)
            throws Exception {
        List<SrtCue> cues = parseSrt(srtText);
        if (cues.isEmpty()) return srtText == null ? "" : srtText;
        String[] translations = new String[cues.size()];
        Map<String, String> glossary = new LinkedHashMap<>();
        int focusIdx = findCueIndexAt(cues, currentPositionMs);
        List<int[]> chunks = planSlidingChunks(cues.size(), focusIdx, chunkSize);
        for (int[] range : chunks) {
            List<String> lines = new ArrayList<>(range[1] - range[0]);
            for (int i = range[0]; i < range[1]; i++) {
                lines.add(cues.get(i).singleLinePlain());
            }
            ChunkTranslation res = translator.translate(showTitle, lines, glossary);
            if (res != null && res.zhLines != null && res.zhLines.size() == lines.size()) {
                for (int i = 0; i < lines.size(); i++) {
                    translations[range[0] + i] = res.zhLines.get(i);
                }
            }
            if (res != null && res.newGlossary != null) {
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
        }
        return renderSrt(cues, translations, bilingual);
    }

    /** Extracts dialogue lines around {@code positionMs} ± {@code windowMs} for Copilot Q&amp;A. */
    static String extractContextAround(List<SrtCue> cues, long positionMs, long windowMs) {
        if (cues == null || cues.isEmpty()) return "";
        long win = Math.max(5000L, windowMs);
        long from = Math.max(0L, positionMs - win);
        long to = positionMs + win;
        StringBuilder sb = new StringBuilder();
        int count = 0;
        for (SrtCue c : cues) {
            if (c.endMs >= from && c.startMs <= to) {
                if (count > 0) sb.append('\n');
                sb.append('[').append(formatShortClock(c.startMs)).append("] ");
                sb.append(c.singleLinePlain());
                count++;
                if (count >= 12) break;
            }
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
     * Writes progressive updates into {@code targetFile} and re-mounts into the active player.
     */
    static void translateAndMountFullEpisodeAsync(
            final MainActivity a,
            final String showTitle,
            final String rawSrtText,
            final File targetFile,
            final long currentPositionMs,
            final ProgressListener listener) {
        if (a == null || !AiAssistantService.isConfigured(a) || targetFile == null) return;
        final List<SrtCue> cues = parseSrt(rawSrtText);
        if (cues.isEmpty()) return;

        final boolean bilingual = a.mobilePrefs().getBoolean(Prefs.SUBTITLE_BILINGUAL, true);
        final int ticket = a.generation;
        final String fullCacheKey =
                "subfull_" + AiAssistantService.sha256((bilingual ? "bi|" : "zh|") + rawSrtText);

        a.worker.execute(
                () -> {
                    try {
                        String cachedSrt = AiAssistantService.readDiskCache(a, fullCacheKey);
                        if (cachedSrt != null && !cachedSrt.trim().isEmpty()) {
                            writeUtf8(targetFile, cachedSrt);
                            remountSubtitleOnUi(
                                    a,
                                    ticket,
                                    targetFile,
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
                        int translatedCount = 0;

                        for (int cIdx = 0; cIdx < chunks.size(); cIdx++) {
                            if (a.isFinishing() || ticket != a.generation) return;
                            int[] range = chunks.get(cIdx);
                            List<String> lines = new ArrayList<>(range[1] - range[0]);
                            for (int i = range[0]; i < range[1]; i++) {
                                lines.add(cues.get(i).singleLinePlain());
                            }
                            ChunkTranslation res =
                                    requestChunkFromModel(a, showTitle, lines, glossary);
                            if (res != null
                                    && res.zhLines != null
                                    && res.zhLines.size() == lines.size()) {
                                for (int i = 0; i < lines.size(); i++) {
                                    translations[range[0] + i] = res.zhLines.get(i);
                                }
                                translatedCount += lines.size();
                                if (res.newGlossary != null) {
                                    for (Map.Entry<String, String> e : res.newGlossary.entrySet()) {
                                        if (glossary.size() >= 24) break;
                                        glossary.put(e.getKey(), e.getValue());
                                    }
                                }
                            }
                            boolean isFirst = (cIdx == 0);
                            boolean isLast = (cIdx == chunks.size() - 1);
                            boolean isMilestone = (cIdx > 0 && cIdx % 4 == 0);
                            if (isFirst || isMilestone || isLast) {
                                String rendered = renderSrt(cues, translations, bilingual);
                                writeUtf8(targetFile, rendered);
                                if (isLast && translatedCount >= cues.size() / 2) {
                                    AiAssistantService.writeDiskCache(a, fullCacheKey, rendered);
                                }
                                String toastMsg =
                                        isLast
                                                ? ("全片 AI 双语字幕已生成（共 "
                                                        + translatedCount
                                                        + "/"
                                                        + cues.size()
                                                        + " 条）")
                                                : (isFirst
                                                        ? ("当前片段 AI 双语字幕已就绪，其余 "
                                                                + (cues.size() - translatedCount)
                                                                + " 条正在后台续译…")
                                                        : "");
                                remountSubtitleOnUi(
                                        a,
                                        ticket,
                                        targetFile,
                                        toastMsg,
                                        listener,
                                        translatedCount,
                                        cues.size(),
                                        isLast);
                            }
                        }
                    } catch (Exception e) {
                        AppLog.w("AiSubtitleTranslator", "Full-episode translation failed", e);
                    }
                });
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

    private static void remountSubtitleOnUi(
            final MainActivity a,
            final int ticket,
            final File targetFile,
            final String toastMsg,
            final ProgressListener listener,
            final int done,
            final int total,
            final boolean completed) {
        a.ui.post(
                () -> {
                    if (a.isFinishing() || ticket != a.generation) return;
                    if (a.playbackControls != null) {
                        a.playbackControls.setActiveSubtitleFile(targetFile);
                    }
                    if (a.player != null && a.prepared) {
                        try {
                            a.player.addExternalSubtitle(
                                    Uri.fromFile(targetFile),
                                    "AI 全片双语字幕",
                                    MediaOptions.subtitleMime(targetFile.getName(), ""));
                            if (toastMsg != null && !toastMsg.isEmpty()) {
                                a.toast(toastMsg);
                            }
                        } catch (Exception ignored) {
                        }
                    }
                    if (listener != null) {
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

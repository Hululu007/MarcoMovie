package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Pure-Java ordering, labeling, sanitization, and tooltip placement policy for the Android TV
 * playback toolbar (both Modern Floating Card and Classic Dual-Bar styles).
 *
 * <p>Separates {@link #ALL_KNOWN_KEYS} (all actions supported by the toolbar, including legacy
 * standalone tools) from the default display layouts ({@link #DEFAULT_MODERN_ORDER} / {@link
 * #DEFAULT_CLASSIC_ORDER} / Live defaults), so existing users who saved a custom {@code
 * tv_player_toolbar_order} retain their chosen buttons and ordering until they explicitly reset to
 * defaults.
 */
final class TvPlayerToolbarOrder {
    static final String KEY_PLAY_PAUSE = "play-pause";
    static final String KEY_NEXT_EPISODE = "next-episode";
    static final String KEY_EPISODES = "episodes";
    static final String KEY_SUBTITLES = "subtitles";
    static final String KEY_AUDIO_TRACKS = "audio-tracks";
    static final String KEY_LINES = "lines";
    static final String KEY_DANMAKU = "danmaku";
    static final String KEY_SPEED = "speed";
    static final String KEY_TRACKS = "tracks";
    static final String KEY_EPG = "epg";
    static final String KEY_DECODER = "decoder";
    static final String KEY_SKIP_INTRO = "skip-intro-tool";
    static final String KEY_SKIP_OUTRO = "skip-outro-tool";
    static final String KEY_MORE = "more";

    static final int MAX_CUSTOM_TOOLBAR_ITEMS = 12;

    /** Modern TV VOD default (8 items): Play · Next · Episodes · Lines · Danmu · Speed · Tracks · More. */
    private static final List<String> DEFAULT_MODERN_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(
                            KEY_PLAY_PAUSE,
                            KEY_NEXT_EPISODE,
                            KEY_EPISODES,
                            KEY_LINES,
                            KEY_DANMAKU,
                            KEY_SPEED,
                            KEY_TRACKS,
                            KEY_MORE));

    /**
     * Classic TV VOD default (7 items), grouped visually as:
     * [Episodes, Next] | [Lines/Quality] | [Danmu, Tracks, Speed] | [More].
     */
    private static final List<String> DEFAULT_CLASSIC_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(
                            KEY_EPISODES,
                            KEY_NEXT_EPISODE,
                            KEY_LINES,
                            KEY_DANMAKU,
                            KEY_TRACKS,
                            KEY_SPEED,
                            KEY_MORE));

    /** Modern TV Live default priority: Play · Channels · Lines · EPG · Next · More. */
    private static final List<String> DEFAULT_MODERN_LIVE_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(
                            KEY_PLAY_PAUSE,
                            KEY_EPISODES,
                            KEY_LINES,
                            KEY_EPG,
                            KEY_NEXT_EPISODE,
                            KEY_MORE));

    /**
     * Classic TV Live default (5 items), grouped visually as:
     * [Channels, Next] | [Lines, EPG] | [More].
     */
    private static final List<String> DEFAULT_CLASSIC_LIVE_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(KEY_EPISODES, KEY_NEXT_EPISODE, KEY_LINES, KEY_EPG, KEY_MORE));

    /** All VOD-compatible actions available in the toolbar editor (defaults + optional/legacy tools). */
    private static final List<String> ALL_MODERN_VOD_KEYS =
            Collections.unmodifiableList(
                    Arrays.asList(
                            KEY_PLAY_PAUSE,
                            KEY_NEXT_EPISODE,
                            KEY_EPISODES,
                            KEY_LINES,
                            KEY_DANMAKU,
                            KEY_SPEED,
                            KEY_TRACKS,
                            KEY_MORE,
                            KEY_SUBTITLES,
                            KEY_AUDIO_TRACKS,
                            KEY_SKIP_INTRO,
                            KEY_SKIP_OUTRO,
                            KEY_DECODER));

    private static final List<String> ALL_CLASSIC_VOD_KEYS =
            Collections.unmodifiableList(
                    Arrays.asList(
                            KEY_EPISODES,
                            KEY_NEXT_EPISODE,
                            KEY_LINES,
                            KEY_DANMAKU,
                            KEY_TRACKS,
                            KEY_SPEED,
                            KEY_MORE,
                            KEY_SUBTITLES,
                            KEY_AUDIO_TRACKS,
                            KEY_SKIP_INTRO,
                            KEY_SKIP_OUTRO,
                            KEY_DECODER));

    private static final Set<String> LIVE_APPLICABLE_MODERN_KEYS =
            Collections.unmodifiableSet(
                    new LinkedHashSet<>(
                            Arrays.asList(
                                    KEY_PLAY_PAUSE,
                                    KEY_EPISODES,
                                    KEY_LINES,
                                    KEY_EPG,
                                    KEY_NEXT_EPISODE,
                                    KEY_DECODER,
                                    KEY_MORE)));

    private static final Set<String> LIVE_APPLICABLE_CLASSIC_KEYS =
            Collections.unmodifiableSet(
                    new LinkedHashSet<>(
                            Arrays.asList(
                                    KEY_EPISODES,
                                    KEY_LINES,
                                    KEY_EPG,
                                    KEY_NEXT_EPISODE,
                                    KEY_DECODER,
                                    KEY_MORE)));

    private static final Set<String> ALL_KNOWN_KEYS;

    static {
        LinkedHashSet<String> all = new LinkedHashSet<>();
        all.addAll(ALL_MODERN_VOD_KEYS);
        all.add(KEY_EPG);
        ALL_KNOWN_KEYS = Collections.unmodifiableSet(all);
    }

    static final class TooltipPlacement {
        final int left;
        final int top;
        final float arrowCenterX;

        TooltipPlacement(int left, int top, float arrowCenterX) {
            this.left = left;
            this.top = top;
            this.arrowCenterX = arrowCenterX;
        }
    }

    private TvPlayerToolbarOrder() {}

    static List<String> defaultOrder(boolean modernTv) {
        return new ArrayList<>(modernTv ? DEFAULT_MODERN_ORDER : DEFAULT_CLASSIC_ORDER);
    }

    static List<String> defaultLiveOrder(boolean modernTv) {
        return new ArrayList<>(modernTv ? DEFAULT_MODERN_LIVE_ORDER : DEFAULT_CLASSIC_LIVE_ORDER);
    }

    static List<String> availableKeys(boolean modernTv) {
        return new ArrayList<>(modernTv ? ALL_MODERN_VOD_KEYS : ALL_CLASSIC_VOD_KEYS);
    }

    static List<String> unusedOptionalKeys(List<String> activeOrder, boolean modernTv) {
        Set<String> active =
                activeOrder == null
                        ? Collections.<String>emptySet()
                        : new LinkedHashSet<>(activeOrder);
        List<String> out = new ArrayList<>();
        for (String key : availableKeys(modernTv)) {
            if (!active.contains(key)) {
                out.add(key);
            }
        }
        return out;
    }

    static boolean isPinnedKey(String key) {
        return KEY_MORE.equals(key);
    }

    static boolean isKnownKey(String key) {
        return key != null && ALL_KNOWN_KEYS.contains(key);
    }

    static String sanitize(Object raw) {
        return Prefs.sanitizeTvToolbarOrder(raw);
    }

    static List<String> resolveOrder(String savedRaw, boolean modernTv) {
        return resolveOrder(savedRaw, modernTv, false);
    }

    static List<String> resolveOrder(String savedRaw, boolean modernTv, boolean live) {
        if (savedRaw == null || savedRaw.trim().isEmpty()) {
            return live ? defaultLiveOrder(modernTv) : defaultOrder(modernTv);
        }
        Set<String> allowed =
                live
                        ? (modernTv ? LIVE_APPLICABLE_MODERN_KEYS : LIVE_APPLICABLE_CLASSIC_KEYS)
                        : new LinkedHashSet<>(availableKeys(modernTv));
        List<String> resolved = new ArrayList<>();
        for (String token : savedRaw.split(",")) {
            String key = token == null ? "" : token.trim();
            if (allowed.contains(key) && !resolved.contains(key)) {
                resolved.add(key);
            }
        }
        if (resolved.isEmpty()) {
            return live ? defaultLiveOrder(modernTv) : defaultOrder(modernTv);
        }
        if (live && !resolved.contains(KEY_EPG)) {
            int afterLines = resolved.indexOf(KEY_LINES);
            if (afterLines >= 0) {
                resolved.add(afterLines + 1, KEY_EPG);
            } else {
                int moreIdx = resolved.indexOf(KEY_MORE);
                if (moreIdx >= 0) resolved.add(moreIdx, KEY_EPG);
                else resolved.add(KEY_EPG);
            }
        }
        if (!resolved.contains(KEY_MORE)) {
            resolved.add(KEY_MORE);
        }
        return resolved;
    }

    /**
     * Resolves the actually visible toolbar buttons for a given playback session (collapsing {@code
     * next-episode} and {@code episodes} on single-episode VOD while preserving relative order).
     */
    /**
     * Semantic visual grouping bucket for Classic Two-Tier bottom toolbar spacing (purely visual
     * spacing/dividers; never creates focusable headers).
     */
    static int groupBucket(String key, boolean live) {
        if (key == null) return 3;
        if (live) {
            if (KEY_PLAY_PAUSE.equals(key)
                    || KEY_EPISODES.equals(key)
                    || KEY_NEXT_EPISODE.equals(key)) {
                return 0;
            }
            if (KEY_LINES.equals(key) || KEY_EPG.equals(key)) {
                return 1;
            }
            return 2;
        }
        if (KEY_PLAY_PAUSE.equals(key)
                || KEY_EPISODES.equals(key)
                || KEY_NEXT_EPISODE.equals(key)) {
            return 0;
        }
        if (KEY_LINES.equals(key)) {
            return 1;
        }
        if (KEY_DANMAKU.equals(key)
                || KEY_TRACKS.equals(key)
                || KEY_SUBTITLES.equals(key)
                || KEY_AUDIO_TRACKS.equals(key)
                || KEY_SPEED.equals(key)) {
            return 2;
        }
        return 3;
    }

    /**
     * Determines whether the Lines/Quality action is meaningful for the current session: always
     * shown for live or multi-line/multi-quality VOD, or network VOD with cross-source switching;
     * hidden for standalone single local files without alternate lines or qualities.
     */
    static boolean shouldShowLinesAction(
            boolean live,
            int lineCount,
            int qualityCount,
            boolean localFile,
            boolean hasCrossSourceSearch) {
        if (live) return true;
        if (lineCount > 1 || qualityCount > 1) return true;
        return !localFile && hasCrossSourceSearch;
    }

    static List<String> visibleOrderForSession(
            String savedRaw, boolean modernTv, boolean live, boolean multiEpisode) {
        List<String> base = resolveOrder(savedRaw, modernTv, live);
        if (live || multiEpisode) return base;
        List<String> filtered = new ArrayList<>(base.size());
        for (String key : base) {
            if (KEY_NEXT_EPISODE.equals(key) || KEY_EPISODES.equals(key)) continue;
            filtered.add(key);
        }
        return filtered;
    }

    static String mergeEditedOrder(
            String existingSavedRaw, List<String> editedStyleOrder, boolean modernTv) {
        List<String> normalized = resolveOrder(joinKeys(editedStyleOrder), modernTv, false);
        List<String> activeDefaults = defaultOrder(modernTv);
        if (normalized.equals(activeDefaults)
                && (existingSavedRaw == null
                        || existingSavedRaw.trim().isEmpty()
                        || isDefaultOrder(existingSavedRaw, !modernTv))) {
            return "";
        }
        List<String> merged = new ArrayList<>(normalized);
        if (!modernTv && !merged.contains(KEY_PLAY_PAUSE)) {
            // Preserve play-pause for Modern TV when the user edits from Classic style.
            int insertAt = 0;
            if (existingSavedRaw != null && !existingSavedRaw.trim().isEmpty()) {
                List<String> existingModern = resolveOrder(existingSavedRaw, true, false);
                int prevIdx = existingModern.indexOf(KEY_PLAY_PAUSE);
                if (prevIdx > 0) {
                    for (int p = prevIdx - 1; p >= 0; p--) {
                        int mIdx = merged.indexOf(existingModern.get(p));
                        if (mIdx >= 0) {
                            insertAt = mIdx + 1;
                            break;
                        }
                    }
                }
            }
            merged.add(insertAt, KEY_PLAY_PAUSE);
        }
        return joinKeys(merged);
    }

    static boolean isDefaultOrder(String savedRaw, boolean modernTv) {
        if (savedRaw == null || savedRaw.trim().isEmpty()) return true;
        return resolveOrder(savedRaw, modernTv, false).equals(defaultOrder(modernTv));
    }

    static boolean moveItem(List<String> order, int fromIndex, int delta) {
        if (order == null || order.isEmpty() || delta == 0) return false;
        if (fromIndex < 0 || fromIndex >= order.size()) return false;
        int target = fromIndex + delta;
        if (target < 0 || target >= order.size()) return false;
        String item = order.remove(fromIndex);
        order.add(target, item);
        return true;
    }

    static String settingsLabel(String key) {
        if (key == null) return "";
        switch (key) {
            case KEY_PLAY_PAUSE:
                return "播放 / 暂停";
            case KEY_NEXT_EPISODE:
                return "下一集 / 下台";
            case KEY_EPISODES:
                return "选集 / 频道";
            case KEY_LINES:
                return "线路 / 画质";
            case KEY_DANMAKU:
                return "弹幕";
            case KEY_SPEED:
                return "倍速";
            case KEY_TRACKS:
                return "字幕 / 音轨";
            case KEY_EPG:
                return "节目单";
            case KEY_SUBTITLES:
                return "字幕（独立按钮）";
            case KEY_AUDIO_TRACKS:
                return "音轨（独立按钮）";
            case KEY_DECODER:
                return "解码 / 播放器";
            case KEY_SKIP_INTRO:
                return "跳过片头（独立按钮）";
            case KEY_SKIP_OUTRO:
                return "跳过片尾（独立按钮）";
            case KEY_MORE:
                return "更多";
            default:
                return key;
        }
    }

    static String shortChipLabel(String key) {
        if (key == null) return "";
        switch (key) {
            case KEY_PLAY_PAUSE:
                return "播放";
            case KEY_NEXT_EPISODE:
                return "下集";
            case KEY_EPISODES:
                return "选集";
            case KEY_LINES:
                return "线路";
            case KEY_DANMAKU:
                return "弹幕";
            case KEY_SPEED:
                return "倍速";
            case KEY_TRACKS:
                return "字幕/音轨";
            case KEY_EPG:
                return "节目单";
            case KEY_SUBTITLES:
                return "字幕";
            case KEY_AUDIO_TRACKS:
                return "音轨";
            case KEY_DECODER:
                return "解码";
            case KEY_SKIP_INTRO:
                return "片头";
            case KEY_SKIP_OUTRO:
                return "片尾";
            case KEY_MORE:
                return "更多";
            default:
                return key;
        }
    }

    static String settingsSummary(String savedRaw, boolean modernTv) {
        if (isDefaultOrder(savedRaw, modernTv)) {
            return "默认顺序（" + defaultOrder(modernTv).size() + " 项）";
        }
        List<String> order = resolveOrder(savedRaw, modernTv, false);
        StringBuilder sb = new StringBuilder("已自定义 · ");
        int previewCount = Math.min(4, order.size());
        for (int i = 0; i < previewCount; i++) {
            if (i > 0) sb.append(" / ");
            sb.append(shortChipLabel(order.get(i)));
        }
        if (order.size() > previewCount) {
            sb.append(" …");
        }
        return sb.toString();
    }

    static String tooltipLabel(
            String key,
            boolean live,
            boolean playing,
            float speed,
            int introSec,
            int outroSec,
            int engineMode) {
        if (key == null) return "";
        switch (key) {
            case KEY_PLAY_PAUSE:
                return playing ? "暂停" : "播放";
            case KEY_NEXT_EPISODE:
                return live ? "下一频道" : "下一集";
            case KEY_EPISODES:
                return live ? "频道列表" : "选集";
            case KEY_LINES:
                return live ? "切换线路" : "线路 / 画质";
            case KEY_DANMAKU:
                return "弹幕";
            case KEY_SPEED:
                return Math.abs(speed - 1f) < 0.01f ? "倍速" : ("倍速 " + formatSpeed(speed));
            case KEY_TRACKS:
                return "字幕 / 音轨";
            case KEY_EPG:
                return "节目单";
            case KEY_SUBTITLES:
                return "字幕";
            case KEY_AUDIO_TRACKS:
                return "音轨";
            case KEY_DECODER:
                String eng =
                        engineMode == 3
                                ? "MPV"
                                : (engineMode == 2 ? "IJK" : (engineMode == 1 ? "系统" : "Exo"));
                return "解码 · " + eng;
            case KEY_SKIP_INTRO:
                return introSec > 0 ? ("跳过片头 " + formatClockSeconds(introSec)) : "跳过片头";
            case KEY_SKIP_OUTRO:
                return outroSec > 0 ? ("跳过片尾 " + formatClockSeconds(outroSec)) : "跳过片尾";
            case KEY_MORE:
                return "更多";
            default:
                return "";
        }
    }

    static TooltipPlacement computeTooltipPlacement(
            int containerWidth,
            int containerHeight,
            int anchorCenterX,
            int anchorTopY,
            int bubbleWidth,
            int bubbleHeight,
            int edgeMarginPx,
            int gapPx,
            float minArrowInsetPx) {
        int safeEdge = Math.max(0, edgeMarginPx);
        int safeW = Math.max(1, bubbleWidth);
        int safeH = Math.max(1, bubbleHeight);
        int maxLeft = Math.max(safeEdge, containerWidth - safeW - safeEdge);
        int desiredLeft = anchorCenterX - safeW / 2;
        int left = Math.max(safeEdge, Math.min(maxLeft, desiredLeft));

        int maxTop = Math.max(safeEdge, containerHeight - safeH - safeEdge);
        int desiredTop = anchorTopY - safeH - Math.max(0, gapPx);
        int top = Math.max(safeEdge, Math.min(maxTop, desiredTop));

        float clampedInset = Math.max(0f, Math.min(minArrowInsetPx, safeW * 0.5f));
        float rawArrow = anchorCenterX - left;
        float arrowCenterX = Math.max(clampedInset, Math.min(safeW - clampedInset, rawArrow));
        return new TooltipPlacement(left, top, arrowCenterX);
    }

    private static String joinKeys(List<String> keys) {
        if (keys == null || keys.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < keys.size(); i++) {
            String k = keys.get(i);
            if (k == null || k.trim().isEmpty()) continue;
            if (sb.length() > 0) sb.append(',');
            sb.append(k.trim());
        }
        return sb.toString();
    }

    private static String formatSpeed(float speed) {
        if (Math.abs(speed - Math.round(speed)) < 0.01f) {
            return Math.round(speed) + "×";
        }
        String raw = String.format(Locale.ROOT, "%.2f", speed);
        while (raw.endsWith("0")) {
            raw = raw.substring(0, raw.length() - 1);
        }
        if (raw.endsWith(".")) {
            raw = raw.substring(0, raw.length() - 1);
        }
        return raw + "×";
    }

    private static String formatClockSeconds(int seconds) {
        int sec = Math.max(0, seconds);
        if (sec >= 3600) {
            return String.format(
                    Locale.ROOT, "%d:%02d:%02d", sec / 3600, (sec / 60) % 60, sec % 60);
        }
        return String.format(Locale.ROOT, "%02d:%02d", sec / 60, sec % 60);
    }
}

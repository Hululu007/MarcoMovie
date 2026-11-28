package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Pure-JVM catalog, visibility policy, add/remove, and ordering model for Android Mobile player
 * HUD buttons (both bottom horizontal pill deck and fixed top/left quick buttons).
 */
final class MobilePlayerHudButtons {
    static final String SENTINEL_EMPTY = "__none__";

    // Fixed-zone HUD quick button toggle bitmask stored in Prefs.MOBILE_HUD_TOGGLES.
    static final int TOGGLE_TOP_PIP = 1;
    static final int TOGGLE_TOP_CAST = 2;
    static final int TOGGLE_LEFT_STEPPERS = 4;
    static final int TOGGLE_LEFT_DANMAKU = 8;
    static final int TOGGLE_LEFT_LOCK = 16;
    static final int TOGGLE_ALL =
            TOGGLE_TOP_PIP
                    | TOGGLE_TOP_CAST
                    | TOGGLE_LEFT_STEPPERS
                    | TOGGLE_LEFT_DANMAKU
                    | TOGGLE_LEFT_LOCK;

    static final class Spec {
        final String key;
        final String label;
        final String shortLabel;
        final String liveShortLabel;
        final boolean vodOnly;
        final boolean defaultEnabled;

        Spec(
                String key,
                String label,
                String shortLabel,
                String liveShortLabel,
                boolean vodOnly,
                boolean defaultEnabled) {
            this.key = key;
            this.label = label;
            this.shortLabel = shortLabel;
            this.liveShortLabel = liveShortLabel;
            this.vodOnly = vodOnly;
            this.defaultEnabled = defaultEnabled;
        }
    }

    private static final List<Spec> CATALOG =
            Collections.unmodifiableList(
                    Arrays.asList(
                            new Spec("episodes", "选集 / 频道", "选集", "频道", false, true),
                            new Spec("lines", "换源 / 线路", "换源", "换源", false, true),
                            new Spec("speed", "播放倍速", "倍速", "倍速", true, true),
                            new Spec("subtitles", "字幕中心", "字幕", "字幕", false, true),
                            new Spec("decoder", "内核与解码", "内核", "内核", false, true),
                            new Spec("quality", "画质 / 视频轨", "画质", "画质", false, false),
                            new Spec("aspect", "画面比例", "比例", "比例", false, false),
                            new Spec("audio-tracks", "音轨选择", "音轨", "音轨", true, false),
                            new Spec("online-sub", "在线字幕搜索", "在线字幕", "在线字幕", true, false),
                            new Spec("picture-effect", "画面色彩", "色彩", "色彩", false, false),
                            new Spec("skip-tool", "片头片尾设置", "跳过", "跳过", true, false),
                            new Spec("sleep-timer", "睡眠定时", "定时", "定时", false, false),
                            new Spec("repeat-tool", "单集 / 列表循环", "循环", "循环", true, false),
                            new Spec("external-player", "外部播放器打开", "外部播", "外部播", false, false),
                            new Spec("restart-tool", "从头重播", "重播", "重播", true, false),
                            new Spec("pip-tool", "画中画小窗 (PiP)", "小窗", "小窗", false, false),
                            new Spec("cast-tool", "无线投屏", "投屏", "投屏", false, false)));

    private MobilePlayerHudButtons() {}

    static List<Spec> allSpecs() {
        return CATALOG;
    }

    static Spec findSpec(String key) {
        if (key == null) return null;
        for (Spec s : CATALOG) {
            if (s.key.equals(key)) return s;
        }
        return null;
    }

    static List<String> defaultEnabledKeys() {
        List<String> out = new ArrayList<>();
        for (Spec s : CATALOG) {
            if (s.defaultEnabled) out.add(s.key);
        }
        return out;
    }

    static String sanitizePrefValue(String raw) {
        if (raw == null) return "";
        String t = raw.trim();
        if (t.isEmpty()) return "";
        if (SENTINEL_EMPTY.equals(t)) return SENTINEL_EMPTY;
        StringBuilder sb = new StringBuilder();
        Set<String> seen = new LinkedHashSet<>();
        for (String part : t.split(",")) {
            String k = part == null ? "" : part.trim();
            if (findSpec(k) != null && seen.add(k)) {
                if (sb.length() > 0) sb.append(',');
                sb.append(k);
            }
        }
        return sb.toString();
    }

    static List<String> resolveEditableButtons(String customCsv, String legacyOrderCsv) {
        String cleanCustom = sanitizePrefValue(customCsv);
        if (cleanCustom.isEmpty()) {
            return PlaybackControls.resolveMobileHighFrequencyOrder(legacyOrderCsv, false);
        }
        if (SENTINEL_EMPTY.equals(cleanCustom)) {
            return new ArrayList<>();
        }
        return new ArrayList<>(Arrays.asList(cleanCustom.split(",")));
    }

    static List<String> resolveActiveButtons(
            String customCsv,
            String legacyOrderCsv,
            boolean live,
            boolean privateMode,
            boolean isCast) {
        String cleanCustom = sanitizePrefValue(customCsv);
        List<String> base;
        if (cleanCustom.isEmpty()) {
            base = PlaybackControls.resolveMobileHighFrequencyOrder(legacyOrderCsv, live);
        } else if (SENTINEL_EMPTY.equals(cleanCustom)) {
            base = Collections.emptyList();
        } else {
            base = Arrays.asList(cleanCustom.split(","));
        }
        List<String> out = new ArrayList<>(base.size());
        for (String key : base) {
            Spec s = findSpec(key);
            if (s == null) continue;
            if (live && s.vodOnly) continue;
            if ((privateMode || isCast) && "cast-tool".equals(key)) continue;
            out.add(key);
        }
        return out;
    }

    static List<String> availableToAdd(List<String> enabledKeys) {
        Set<String> active =
                enabledKeys == null
                        ? Collections.<String>emptySet()
                        : new LinkedHashSet<>(enabledKeys);
        List<String> out = new ArrayList<>();
        for (Spec s : CATALOG) {
            if (!active.contains(s.key)) {
                out.add(s.key);
            }
        }
        return out;
    }

    static boolean move(List<String> keys, int index, int delta) {
        if (keys == null || index < 0 || index >= keys.size()) return false;
        int target = index + delta;
        if (target < 0 || target >= keys.size()) return false;
        String moved = keys.set(target, keys.get(index));
        keys.set(index, moved);
        return true;
    }

    static boolean add(List<String> keys, String key) {
        if (keys == null || findSpec(key) == null || keys.contains(key)) return false;
        return keys.add(key);
    }

    static boolean remove(List<String> keys, String key) {
        if (keys == null || key == null) return false;
        return keys.remove(key);
    }

    static String encode(List<String> keys) {
        if (keys == null || keys.isEmpty()) return SENTINEL_EMPTY;
        StringBuilder sb = new StringBuilder();
        Set<String> seen = new LinkedHashSet<>();
        for (String k : keys) {
            if (findSpec(k) != null && seen.add(k)) {
                if (sb.length() > 0) sb.append(',');
                sb.append(k);
            }
        }
        return sb.length() == 0 ? SENTINEL_EMPTY : sb.toString();
    }

    static int clampToggles(int mask) {
        return mask & TOGGLE_ALL;
    }

    static boolean isToggleEnabled(int mask, int flag) {
        return (clampToggles(mask) & flag) != 0;
    }

    static String summary(String customCsv, String legacyOrderCsv, int toggleMask) {
        List<String> pills = resolveEditableButtons(customCsv, legacyOrderCsv);
        int clamped = clampToggles(toggleMask);
        int quickCount = Integer.bitCount(clamped);
        return "底栏 " + pills.size() + " 项 · 快捷 " + quickCount + "/5";
    }
}

package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.List;

/** Explicit defaults remain separate from a one-time manual source switch. */
final class SourcePreferences {
    static String identity(Cms.Site site) {
        String baseApi =
                site.originalApi != null && !site.originalApi.isEmpty()
                        ? site.originalApi
                        : site.api;
        return site.key + "\n" + baseApi;
    }

    static boolean isPreferred(MainActivity a, Cms.Site site) {
        String pref = a.prefs.getString(Prefs.PREFERRED_SITE, "");
        if (pref.isEmpty()) return false;
        return pref.equals(identity(site)) || pref.equals(site.key + "\n" + site.api);
    }

    static void restoreDefault(MainActivity a) {
        if (a.config == null) return;
        for (Cms.Site site : a.config.sites) {
            if (isPreferred(a, site) && a.available(site)) {
                a.prefs.edit().putString(Prefs.SELECTED_SITE, site.key).apply();
                return;
            }
        }
    }

    static void choose(MainActivity a) {
        if (a.config == null) return;
        List<Cms.Site> sites = new ArrayList<>();
        for (Cms.Site site : a.config.sites) if (a.available(site)) sites.add(site);
        String[] names = new String[sites.size() + 1];
        names[0] = "跟随上次选择";
        for (int i = 0; i < sites.size(); i++)
            names[i + 1] = (isPreferred(a, sites.get(i)) ? "★ " : "") + sites.get(i).name;
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("默认偏好源")
                .setItems(
                        names,
                        (d, index) -> {
                            android.content.SharedPreferences.Editor ed = a.prefs.edit();
                            ed.putString(
                                    Prefs.PREFERRED_SITE,
                                    index == 0 ? "" : identity(sites.get(index - 1)));
                            if (index > 0) {
                                ed.putString(Prefs.SELECTED_SITE, sites.get(index - 1).key);
                            }
                            ed.apply();
                            a.toast(index == 0 ? "已取消默认偏好源" : "已保存并切换默认偏好源");
                            SourcePicker.show(a);
                        })
                .show();
    }

    private static String normalizeLineFamilyKey(String name) {
        if (name == null) return "";
        String trimmed = name.trim().toLowerCase(java.util.Locale.ROOT);
        trimmed = trimmed.replaceAll("[#\\-_\\s]*\\d+$", "");
        trimmed = trimmed.replaceAll("[\\[\\]【】()（）\\s]", "");
        return trimmed;
    }

    private static String detectLineProviderToken(String name) {
        if (name == null) return "";
        String lower = name.toLowerCase(java.util.Locale.ROOT);
        if (lower.contains("夸克") || lower.contains("quark")) return "quark";
        if (lower.contains("阿里") || lower.contains("alipan") || lower.contains("aliyun"))
            return "ali";
        if (lower.contains("百度") || lower.contains("baidu")) return "baidu";
        if (lower.contains("天翼") || lower.contains("189")) return "189";
        if (lower.contains("移动") || lower.contains("139") || lower.contains("和彩云")) return "139";
        if (lower.contains("迅雷") || lower.contains("xunlei")) return "xunlei";
        if (lower.contains("115")) return "115";
        if (lower.contains("123")) return "123";
        if (lower.contains("uc")) return "uc";
        return "";
    }

    static int matchPreferredLineIndex(List<Cms.Line> lines, String preferred) {
        if (lines == null || lines.isEmpty() || preferred == null || preferred.trim().isEmpty()) {
            return -1;
        }
        String prefTrim = preferred.trim();
        for (int i = 0; i < lines.size(); i++) {
            Cms.Line cand = lines.get(i);
            if (cand != null
                    && cand.name != null
                    && cand.episodes != null
                    && !cand.episodes.isEmpty()
                    && prefTrim.equals(cand.name.trim())) {
                return i;
            }
        }
        String prefNorm = normalizeLineFamilyKey(prefTrim);
        if (!prefNorm.isEmpty()) {
            for (int i = 0; i < lines.size(); i++) {
                Cms.Line cand = lines.get(i);
                if (cand == null || cand.episodes == null || cand.episodes.isEmpty()) continue;
                if (prefNorm.equals(normalizeLineFamilyKey(cand.name))) {
                    return i;
                }
            }
        }
        String prefProvider = detectLineProviderToken(prefTrim);
        if (!prefProvider.isEmpty()) {
            boolean want4k =
                    prefTrim.toLowerCase(java.util.Locale.ROOT).contains("4k")
                            || prefTrim.contains("原画");
            int firstProviderIdx = -1;
            for (int i = 0; i < lines.size(); i++) {
                Cms.Line cand = lines.get(i);
                if (cand == null
                        || cand.name == null
                        || cand.episodes == null
                        || cand.episodes.isEmpty()) continue;
                if (!prefProvider.equals(detectLineProviderToken(cand.name))) continue;
                if (firstProviderIdx < 0) firstProviderIdx = i;
                String candLower = cand.name.toLowerCase(java.util.Locale.ROOT);
                if (!want4k || candLower.contains("4k") || cand.name.contains("原画")) {
                    return i;
                }
            }
            if (firstProviderIdx >= 0) return firstProviderIdx;
        }
        return -1;
    }

    static int lineIndex(MainActivity a, Cms.Video video) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return 0;
        String preferred = a.prefs.getString(Prefs.PREFERRED_LINE, "");
        int matched = matchPreferredLineIndex(video.lines, preferred);
        if (matched >= 0) return matched;
        for (int i = 0; i < video.lines.size(); i++)
            if (!video.lines.get(i).episodes.isEmpty()) return i;
        return 0;
    }

    static List<Cms.Site> prioritized(MainActivity a, List<Cms.Site> sites) {
        List<Cms.Site> ordered = new ArrayList<>();
        for (Cms.Site site : sites) if (isPreferred(a, site)) ordered.add(site);
        for (Cms.Site site : sites) if (!isPreferred(a, site)) ordered.add(site);
        return ordered;
    }

    static void chooseLine(MainActivity a, Cms.Video video) {
        chooseLine(a, video, null);
    }

    static void chooseLine(MainActivity a, Cms.Video video, Runnable onChanged) {
        String[] names = new String[video.lines.size() + 1];
        names[0] = "自动选择";
        String preferred = a.prefs.getString(Prefs.PREFERRED_LINE, "");
        for (int i = 0; i < video.lines.size(); i++) {
            String name = video.lines.get(i).name;
            names[i + 1] = (name.equals(preferred) ? "★ " : "") + name;
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("默认播放线路")
                .setItems(
                        names,
                        (d, index) -> {
                            a.prefs
                                    .edit()
                                    .putString(
                                            Prefs.PREFERRED_LINE,
                                            index == 0 ? "" : video.lines.get(index - 1).name)
                                    .apply();
                            if (a.current != null && a.current.selection != null) {
                                a.current.selection.selected = false;
                                a.current.selection.line = "";
                            }
                            a.toast(
                                    onChanged != null
                                            ? "已切换并设为默认播放线路；观看记录仍优先续播"
                                            : "已保存，下次打开影片时优先选择；观看记录仍优先续播");
                            if (onChanged != null) onChanged.run();
                        })
                .show();
    }
}

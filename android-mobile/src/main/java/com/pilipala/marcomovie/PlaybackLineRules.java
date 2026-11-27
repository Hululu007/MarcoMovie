package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.text.TextUtils;
import android.view.Gravity;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Subscription- and site-scoped playback line customization store (Item 6: 原 15/16).
 *
 * <p>Allows users to long-press any concrete playback line inside a video (in Detail or Player) to
 * rename, reorder, set default, delete/hide, or restore lines, with strict isolation guarantees:
 *
 * <ul>
 *   <li>Scoped by {@code subscriptionScope + "\n" + site.siteId() + "\n" + site.originalApi}, so
 *       two subscriptions that both expose a line named {@code "线路1"} never collide. Editing Sub
 *       A's {@code "线路1"} leaves Sub B's {@code "线路1"}, history, and favorites untouched.
 *   <li>Every {@link Cms.Line} preserves its immutable upstream {@link Cms.Line#rawName} so spider
 *       {@code player(flag, id)}, {@link WatchHistory.Entry#line}, and {@link DownloadManager}
 *       always bind to the canonical upstream line name even after user rename.
 *   <li>Applied dynamically on presentation so all user edits survive subscription refreshes.
 * </ul>
 */
final class PlaybackLineRules {
    private static final String PREF_KEY = "playback_line_rules_v1";

    private PlaybackLineRules() {}

    static String buildSubscriptionScope(
            String sourceOrigin, String fallbackConfigOrigin, String rawConfig) {
        String effOrigin =
                (sourceOrigin != null && !sourceOrigin.trim().isEmpty())
                        ? sourceOrigin.trim()
                        : (fallbackConfigOrigin == null ? "" : fallbackConfigOrigin.trim());
        if (!effOrigin.isEmpty()) {
            return NetdiskStore.sha256Hex(effOrigin).substring(0, 16);
        }
        String raw = rawConfig == null ? "" : rawConfig;
        return NetdiskStore.sha256Hex("local:" + raw).substring(0, 16);
    }

    static String buildSiteScope(String subscriptionScope, String siteId, String originalApi) {
        String sub = subscriptionScope == null ? "" : subscriptionScope.trim();
        String sid = siteId == null ? "" : siteId.trim();
        String api = originalApi == null ? "" : originalApi.trim();
        return sub + "\n" + sid + "\n" + api;
    }

    static String scopeFor(MainActivity a, Cms.Site site) {
        if (site == null) return "";
        String configOrigin =
                a != null
                                && a.config != null
                                && a.config.origin != null
                                && !a.config.origin.isEmpty()
                        ? a.config.origin
                        : (a != null ? a.configOrigin : "");
        String raw = a != null && a.config != null ? a.config.raw : "";
        String subScope = buildSubscriptionScope(site.sourceOrigin, configOrigin, raw);
        String api =
                site.originalApi != null && !site.originalApi.isEmpty()
                        ? site.originalApi
                        : site.api;
        return buildSiteScope(subScope, site.siteId(), api);
    }

    static JSONObject loadAll(Context context) {
        if (context == null) return new JSONObject();
        SharedPreferences prefs = context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        try {
            String raw = prefs.getString(PREF_KEY, "{}");
            return raw == null || raw.trim().isEmpty() ? new JSONObject() : new JSONObject(raw);
        } catch (Exception ignored) {
            return new JSONObject();
        }
    }

    static void saveAll(Context context, JSONObject root) {
        if (context == null || root == null) return;
        context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(PREF_KEY, root.toString())
                .apply();
    }

    static JSONObject loadRuleForScope(JSONObject allRoot, String scope) {
        if (allRoot == null || scope == null || scope.isEmpty()) return new JSONObject();
        JSONObject found = allRoot.optJSONObject(scope);
        return found != null ? found : new JSONObject();
    }

    static JSONObject loadRuleForSite(MainActivity a, Cms.Site site) {
        return loadRuleForScope(loadAll(a), scopeFor(a, site));
    }

    static void saveRuleForScope(Context context, String scope, JSONObject rule) {
        if (context == null || scope == null || scope.isEmpty() || rule == null) return;
        JSONObject all = loadAll(context);
        try {
            all.put(scope, rule);
            saveAll(context, all);
        } catch (Exception ignored) {
        }
    }

    /** Pure-JVM: sets custom display alias for a raw line name within {@code rule}. */
    static void setAlias(JSONObject rule, String rawLineName, String newDisplayName) {
        if (rule == null || rawLineName == null || rawLineName.trim().isEmpty()) return;
        try {
            JSONObject aliases = rule.optJSONObject("aliases");
            if (aliases == null) {
                aliases = new JSONObject();
                rule.put("aliases", aliases);
            }
            String clean = newDisplayName == null ? "" : newDisplayName.trim();
            if (clean.isEmpty() || clean.equals(rawLineName)) {
                aliases.remove(rawLineName);
            } else {
                aliases.put(rawLineName, clean);
            }
        } catch (Exception ignored) {
        }
    }

    /** Pure-JVM: hides (soft-deletes) a raw line name within {@code rule}. */
    static void setHidden(JSONObject rule, String rawLineName, boolean hidden) {
        if (rule == null || rawLineName == null || rawLineName.trim().isEmpty()) return;
        Set<String> set = readStringSet(rule.optJSONArray("hidden"));
        if (hidden) set.add(rawLineName);
        else set.remove(rawLineName);
        try {
            JSONArray arr = new JSONArray();
            for (String s : set) arr.put(s);
            rule.put("hidden", arr);
            if (hidden && rawLineName.equals(rule.optString("preferred", ""))) {
                rule.remove("preferred");
            }
        } catch (Exception ignored) {
        }
    }

    /** Pure-JVM: restores all hidden lines for this site scope. */
    static void restoreHidden(JSONObject rule) {
        if (rule == null) return;
        rule.remove("hidden");
    }

    static int hiddenCount(JSONObject rule) {
        if (rule == null) return 0;
        JSONArray arr = rule.optJSONArray("hidden");
        return arr == null ? 0 : arr.length();
    }

    static void setPreferred(JSONObject rule, String rawLineName) {
        if (rule == null) return;
        try {
            if (rawLineName == null || rawLineName.trim().isEmpty()) {
                rule.remove("preferred");
            } else {
                rule.put("preferred", rawLineName.trim());
            }
        } catch (Exception ignored) {
        }
    }

    static String preferredRawName(JSONObject rule) {
        return rule == null ? "" : rule.optString("preferred", "").trim();
    }

    /**
     * Resolves the index of the site's explicitly preferred default line (if any) in {@code lines},
     * honoring per-site "设为该片源默认优先线路" even when the user also manually reordered lines.
     */
    static int preferredLineIndex(List<Cms.Line> lines, JSONObject rule) {
        if (lines == null || lines.isEmpty() || rule == null) return -1;
        String pref = preferredRawName(rule);
        if (pref.isEmpty()) return -1;
        for (int i = 0; i < lines.size(); i++) {
            Cms.Line l = lines.get(i);
            if (l != null && !l.episodes.isEmpty() && pref.equals(l.lineId())) {
                return i;
            }
        }
        for (int i = 0; i < lines.size(); i++) {
            Cms.Line l = lines.get(i);
            if (l != null && !l.episodes.isEmpty() && matchesLine(l, pref)) {
                return i;
            }
        }
        return -1;
    }

    static void setOrder(JSONObject rule, List<String> orderedRawNames) {
        if (rule == null) return;
        try {
            JSONArray arr = new JSONArray();
            Set<String> seen = new LinkedHashSet<>();
            if (orderedRawNames != null) {
                for (String n : orderedRawNames) {
                    if (n != null && !n.trim().isEmpty() && seen.add(n.trim())) {
                        arr.put(n.trim());
                    }
                }
            }
            rule.put("order", arr);
        } catch (Exception ignored) {
        }
    }

    /**
     * Assigns deterministic per-line identities while keeping every {@link Cms.Line#rawName}
     * immutable. When a video exposes multiple lines sharing the same {@code rawName}, each line
     * receives a unique {@code lineId} ({@code rawName}, {@code rawName#2}, ...) so unedited
     * duplicate-named lines are NEVER collapsed into one and can be edited/deleted/reordered
     * independently. Existing unique {@code lineId} values are preserved across repeated in-memory
     * mutations (e.g. reordering in-place during playback).
     */
    static List<Cms.Line> applyToLines(List<Cms.Line> inputLines, JSONObject rule) {
        return applyToLines(inputLines, rule, null);
    }

    static List<Cms.Line> applyToLines(
            List<Cms.Line> inputLines, JSONObject rule, List<String> netdiskDriveOrder) {
        if (inputLines == null || inputLines.isEmpty()) return new ArrayList<>();
        JSONObject aliases = rule != null ? rule.optJSONObject("aliases") : null;
        Set<String> hidden =
                rule != null
                        ? readStringSet(rule.optJSONArray("hidden"))
                        : Collections.<String>emptySet();
        List<String> order =
                rule != null
                        ? readStringList(rule.optJSONArray("order"))
                        : Collections.<String>emptyList();
        String preferred = preferredRawName(rule);

        // Compute deterministic unique lineId per input line, preserving pre-assigned unique IDs.
        Set<String> assignedIds = new LinkedHashSet<>();
        Map<String, Integer> rawOccurrence = new LinkedHashMap<>();
        List<Cms.Line> cloned = new ArrayList<>(inputLines.size());
        for (Cms.Line orig : inputLines) {
            if (orig == null) continue;
            String raw = orig.rawName();
            String id = orig.lineId != null ? orig.lineId.trim() : "";
            if (id.isEmpty() || !assignedIds.add(id)) {
                int occ = rawOccurrence.containsKey(raw) ? rawOccurrence.get(raw) : 0;
                String candidate;
                do {
                    candidate = occ == 0 ? raw : (raw + "#" + (occ + 1));
                    occ++;
                } while (!assignedIds.add(candidate));
                rawOccurrence.put(raw, occ);
                id = candidate;
            } else {
                int occ = rawOccurrence.containsKey(raw) ? rawOccurrence.get(raw) : 0;
                rawOccurrence.put(raw, occ + 1);
            }

            Cms.Line copy = new Cms.Line();
            copy.rawName = raw;
            copy.lineId = id;
            String alias = "";
            if (aliases != null) {
                alias = aliases.optString(id, "").trim();
                if (alias.isEmpty() && id.equals(raw)) {
                    alias = aliases.optString(raw, "").trim();
                }
            }
            copy.name = alias.isEmpty() ? raw : alias;
            copy.episodes.addAll(orig.episodes);
            cloned.add(copy);
        }

        // Filter hidden (with last-line safety: never leave 0 lines if input had >= 1)
        List<Cms.Line> visible = new ArrayList<>(cloned.size());
        for (Cms.Line l : cloned) {
            if (!hidden.contains(l.lineId())) {
                visible.add(l);
            }
        }
        if (visible.isEmpty()) {
            visible.addAll(cloned);
        }

        // Apply custom ordering keyed by unique lineId (NEVER dropping same-named lines!)
        Map<String, Cms.Line> byId = new LinkedHashMap<>();
        for (Cms.Line l : visible) {
            byId.put(l.lineId(), l);
        }
        List<Cms.Line> ordered = new ArrayList<>(visible.size());
        if (!preferred.isEmpty() && byId.containsKey(preferred) && order.isEmpty()) {
            ordered.add(byId.remove(preferred));
        }
        for (String lid : order) {
            Cms.Line l = byId.remove(lid);
            if (l != null) ordered.add(l);
        }
        List<Cms.Line> remaining = new ArrayList<>(byId.values());
        if (netdiskDriveOrder != null && !netdiskDriveOrder.isEmpty() && remaining.size() > 1) {
            remaining = NetdiskStore.sortLinesByDriveOrder(remaining, netdiskDriveOrder);
        }
        ordered.addAll(remaining);
        return ordered;
    }

    /**
     * Re-binds the active line reference after {@link #applyToLines} produces new {@link Cms.Line}
     * instances, guaranteeing {@code video.lines.indexOf(activeLine)} never becomes {@code -1}
     * after in-playback rename/reorder.
     */
    static Cms.Line resolveActiveLineAfterApply(
            List<Cms.Line> transformed, Cms.Line previousActive, Cms.Episode previousEpisode) {
        if (transformed == null || transformed.isEmpty() || previousActive == null) return null;
        if (transformed.contains(previousActive)) return previousActive;
        String prevId = previousActive.lineId();
        if (!prevId.isEmpty()) {
            for (Cms.Line cand : transformed) {
                if (cand != null && prevId.equals(cand.lineId())) return cand;
            }
        }
        if (previousEpisode != null) {
            for (Cms.Line cand : transformed) {
                if (cand != null
                        && cand.rawName().equals(previousActive.rawName())
                        && cand.episodes.contains(previousEpisode)) {
                    return cand;
                }
            }
            if (previousEpisode.url != null && !previousEpisode.url.isEmpty()) {
                for (Cms.Line cand : transformed) {
                    if (cand == null) continue;
                    for (Cms.Episode ep : cand.episodes) {
                        if (ep != null && previousEpisode.url.equals(ep.url)) {
                            return cand;
                        }
                    }
                }
            }
        }
        for (Cms.Line cand : transformed) {
            if (cand != null && cand.rawName().equals(previousActive.rawName())) return cand;
        }
        return transformed.get(0);
    }

    /** Convenience mutator for a loaded video in place, keeping {@code a.activeLine} in sync. */
    static void applyToVideo(MainActivity a, Cms.Site site, Cms.Video video) {
        if (a == null || site == null || video == null || video.lines.isEmpty()) return;
        boolean trackingActive = a.activeLine != null && video.lines.contains(a.activeLine);
        Cms.Line prevActive = trackingActive ? a.activeLine : null;
        Cms.Episode prevEp = trackingActive ? a.activeEpisode : null;
        JSONObject rule = loadRuleForSite(a, site);
        List<String> driveOrder = NetdiskStore.getOrder(a);
        List<Cms.Line> transformed = applyToLines(video.lines, rule, driveOrder);
        video.lines.clear();
        video.lines.addAll(transformed);
        if (trackingActive) {
            Cms.Line rebound = resolveActiveLineAfterApply(video.lines, prevActive, prevEp);
            if (rebound != null) {
                a.activeLine = rebound;
            }
        }
    }

    /** Matches a WatchHistory / favorite line name against lineId, rawName, or current display name. */
    static boolean matchesLine(Cms.Line line, String savedLineName) {
        if (line == null || savedLineName == null || savedLineName.isEmpty()) return false;
        return savedLineName.equals(line.lineId())
                || savedLineName.equals(line.rawName())
                || savedLineName.equals(line.name);
    }

    /** Interactive long-press line management sheet (rename, move up/down/top, default, delete, restore). */
    static void showManageLineSheet(
            final MainActivity a,
            final Cms.Site site,
            final Cms.Video video,
            final Cms.Line line,
            final Runnable onChanged) {
        if (a == null || site == null || video == null || line == null || a.isFinishing()) return;
        final String scope = scopeFor(a, site);
        final JSONObject rule = loadRuleForSite(a, site);
        final String lid = line.lineId();
        final String raw = line.rawName();
        final int idx = video.lines.indexOf(line);
        final int total = video.lines.size();
        final int hiddenCnt = hiddenCount(rule);
        final boolean isPref = lid.equals(preferredRawName(rule));

        List<String> labels = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();

        labels.add("重命名此线路（仅影响当前订阅当前片源）");
        actions.add(() -> showRenameLineSheet(a, scope, rule, line, onChanged));

        labels.add(isPref ? "取消默认优先线路" : "设为该片源默认优先线路");
        actions.add(
                () -> {
                    setPreferred(rule, isPref ? "" : lid);
                    saveRuleForScope(a, scope, rule);
                    applyToVideo(a, site, video);
                    a.toast(isPref ? "已取消默认线路" : ("已设「" + line.name + "」为默认线路"));
                    if (onChanged != null) onChanged.run();
                });

        if (idx > 0) {
            labels.add("置顶此线路");
            actions.add(
                    () -> {
                        List<String> curOrder = currentLineIdOrder(video);
                        curOrder.remove(lid);
                        curOrder.add(0, lid);
                        setOrder(rule, curOrder);
                        saveRuleForScope(a, scope, rule);
                        applyToVideo(a, site, video);
                        a.toast("已置顶线路「" + line.name + "」");
                        if (onChanged != null) onChanged.run();
                    });
            labels.add("上移一位");
            actions.add(
                    () -> {
                        List<String> curOrder = currentLineIdOrder(video);
                        int pos = curOrder.indexOf(lid);
                        if (pos > 0) Collections.swap(curOrder, pos, pos - 1);
                        setOrder(rule, curOrder);
                        saveRuleForScope(a, scope, rule);
                        applyToVideo(a, site, video);
                        if (onChanged != null) onChanged.run();
                    });
        }
        if (idx >= 0 && idx + 1 < total) {
            labels.add("下移一位");
            actions.add(
                    () -> {
                        List<String> curOrder = currentLineIdOrder(video);
                        int pos = curOrder.indexOf(lid);
                        if (pos >= 0 && pos + 1 < curOrder.size()) {
                            Collections.swap(curOrder, pos, pos + 1);
                        }
                        setOrder(rule, curOrder);
                        saveRuleForScope(a, scope, rule);
                        applyToVideo(a, site, video);
                        if (onChanged != null) onChanged.run();
                    });
        }

        if (total > 1) {
            labels.add("删除（隐藏）此线路");
            actions.add(
                    () ->
                            MobileBottomSheet.showConfirm(
                                    a,
                                    "删除线路「" + line.name + "」？",
                                    "仅隐藏当前订阅该片源下的此播放线路，不影响其他订阅或历史收藏，可随时恢复。",
                                    "删除线路",
                                    true,
                                    () -> {
                                        setHidden(rule, lid, true);
                                        saveRuleForScope(a, scope, rule);
                                        applyToVideo(a, site, video);
                                        a.toast("已删除线路「" + line.name + "」");
                                        if (onChanged != null) onChanged.run();
                                    }));
        }

        if (hiddenCnt > 0) {
            labels.add("恢复已删除的线路（" + hiddenCnt + " 条）");
            actions.add(
                    () -> {
                        restoreHidden(rule);
                        saveRuleForScope(a, scope, rule);
                        a.toast("已恢复隐藏线路，刷新影片详情即可显示");
                        if (onChanged != null) onChanged.run();
                    });
        }

        String subtitle =
                raw.equals(line.name)
                        ? ("原始标识：" + lid + " · 刷新订阅后保留改动")
                        : ("原始标识：" + lid + "（已重命名）");
        MobileBottomSheet.showPicker(
                a,
                "管理线路 · " + line.name,
                subtitle,
                labels.toArray(new String[0]),
                -1,
                sel -> {
                    if (sel >= 0 && sel < actions.size()) actions.get(sel).run();
                });
    }

    private static void showRenameLineSheet(
            final MainActivity a,
            final String scope,
            final JSONObject rule,
            final Cms.Line line,
            final Runnable onChanged) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));

        TextView hint = a.text("原始线路名：" + line.rawName() + "\n留空将恢复为原始名称。", 12f, p.textSecondary);
        box.addView(hint);
        a.gap(box, 10);

        final EditText et = new EditText(a);
        et.setHint("输入自定义线路名称");
        et.setText(line.name);
        et.setSelection(line.name == null ? 0 : line.name.length());
        et.setHintTextColor(p.textTertiary);
        et.setTextColor(p.textPrimary);
        et.setTextSize(14f);
        et.setSingleLine(true);
        et.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        et.setBackground(MobileTheme.subtleBg(a, 12));
        box.addView(et, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 12);

        final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];
        TextView saveBtn = a.text("保存重命名", 13.5f, p.accentOnFill);
        saveBtn.setGravity(Gravity.CENTER);
        saveBtn.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        saveBtn.setBackground(MobileTheme.accentPillBg(a, 999));
        MobileMotion.bindPress(saveBtn, 0.95f);
        saveBtn.setOnClickListener(
                v -> {
                    String nextName = et.getText().toString().trim();
                    setAlias(rule, line.lineId(), nextName);
                    saveRuleForScope(a, scope, rule);
                    line.name = nextName.isEmpty() ? line.rawName() : nextName;
                    if (handleRef[0] != null) handleRef[0].dismiss();
                    a.toast("已保存线路名称：" + line.name);
                    if (onChanged != null) onChanged.run();
                });
        box.addView(saveBtn, new LinearLayout.LayoutParams(-1, -2));
        handleRef[0] = MobileBottomSheet.showCustom(a, "重命名线路", box, null);
    }

    private static List<String> currentLineIdOrder(Cms.Video video) {
        List<String> out = new ArrayList<>();
        if (video == null) return out;
        for (Cms.Line l : video.lines) {
            if (l != null && !out.contains(l.lineId())) out.add(l.lineId());
        }
        return out;
    }

    private static Set<String> readStringSet(JSONArray arr) {
        Set<String> out = new LinkedHashSet<>();
        if (arr == null) return out;
        for (int i = 0; i < arr.length(); i++) {
            String s = arr.optString(i, "").trim();
            if (!s.isEmpty()) out.add(s);
        }
        return out;
    }

    private static List<String> readStringList(JSONArray arr) {
        List<String> out = new ArrayList<>();
        if (arr == null) return out;
        for (int i = 0; i < arr.length(); i++) {
            String s = arr.optString(i, "").trim();
            if (!s.isEmpty() && !out.contains(s)) out.add(s);
        }
        return out;
    }
}

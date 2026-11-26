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
     * Pure-JVM: applies rename/hide/order/preferred rules to a list of video lines while keeping
     * every {@link Cms.Line#rawName} immutable. Protects against hiding every single line (if all
     * lines would be hidden, returns all lines with aliases still applied).
     */
    static List<Cms.Line> applyToLines(List<Cms.Line> inputLines, JSONObject rule) {
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

        List<Cms.Line> cloned = new ArrayList<>(inputLines.size());
        for (Cms.Line orig : inputLines) {
            if (orig == null) continue;
            String raw = orig.rawName();
            Cms.Line copy = new Cms.Line();
            copy.rawName = raw;
            String alias = aliases != null ? aliases.optString(raw, "").trim() : "";
            copy.name = alias.isEmpty() ? raw : alias;
            copy.episodes.addAll(orig.episodes);
            cloned.add(copy);
        }

        // Filter hidden (with last-line safety: never leave 0 lines if input had >= 1)
        List<Cms.Line> visible = new ArrayList<>(cloned.size());
        for (Cms.Line l : cloned) {
            if (!hidden.contains(l.rawName())) {
                visible.add(l);
            }
        }
        if (visible.isEmpty()) {
            visible.addAll(cloned);
        }

        // Apply custom ordering (preferred line moves first if no explicit order places it
        // elsewhere)
        Map<String, Cms.Line> byRaw = new LinkedHashMap<>();
        for (Cms.Line l : visible) {
            if (!byRaw.containsKey(l.rawName())) {
                byRaw.put(l.rawName(), l);
            }
        }
        List<Cms.Line> ordered = new ArrayList<>(visible.size());
        if (!preferred.isEmpty() && byRaw.containsKey(preferred) && order.isEmpty()) {
            ordered.add(byRaw.remove(preferred));
        }
        for (String raw : order) {
            Cms.Line l = byRaw.remove(raw);
            if (l != null) ordered.add(l);
        }
        ordered.addAll(byRaw.values());
        return ordered;
    }

    /** Convenience mutator for a loaded video in place. */
    static void applyToVideo(MainActivity a, Cms.Site site, Cms.Video video) {
        if (a == null || site == null || video == null || video.lines.isEmpty()) return;
        JSONObject rule = loadRuleForSite(a, site);
        List<Cms.Line> transformed = applyToLines(video.lines, rule);
        video.lines.clear();
        video.lines.addAll(transformed);
    }

    /** Matches a WatchHistory / favorite line name against either rawName or current display name. */
    static boolean matchesLine(Cms.Line line, String savedLineName) {
        if (line == null || savedLineName == null || savedLineName.isEmpty()) return false;
        return savedLineName.equals(line.rawName()) || savedLineName.equals(line.name);
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
        final String raw = line.rawName();
        final int idx = video.lines.indexOf(line);
        final int total = video.lines.size();
        final int hiddenCnt = hiddenCount(rule);
        final boolean isPref = raw.equals(preferredRawName(rule));

        List<String> labels = new ArrayList<>();
        List<Runnable> actions = new ArrayList<>();

        labels.add("重命名此线路（仅影响当前订阅当前片源）");
        actions.add(() -> showRenameLineSheet(a, scope, rule, line, onChanged));

        labels.add(isPref ? "取消默认优先线路" : "设为该片源默认优先线路");
        actions.add(
                () -> {
                    setPreferred(rule, isPref ? "" : raw);
                    saveRuleForScope(a, scope, rule);
                    applyToVideo(a, site, video);
                    a.toast(isPref ? "已取消默认线路" : ("已设「" + line.name + "」为默认线路"));
                    if (onChanged != null) onChanged.run();
                });

        if (idx > 0) {
            labels.add("置顶此线路");
            actions.add(
                    () -> {
                        List<String> curOrder = currentRawOrder(video);
                        curOrder.remove(raw);
                        curOrder.add(0, raw);
                        setOrder(rule, curOrder);
                        saveRuleForScope(a, scope, rule);
                        applyToVideo(a, site, video);
                        a.toast("已置顶线路「" + line.name + "」");
                        if (onChanged != null) onChanged.run();
                    });
            labels.add("上移一位");
            actions.add(
                    () -> {
                        List<String> curOrder = currentRawOrder(video);
                        int pos = curOrder.indexOf(raw);
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
                        List<String> curOrder = currentRawOrder(video);
                        int pos = curOrder.indexOf(raw);
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
                                        setHidden(rule, raw, true);
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
                        ? ("原始标识：" + raw + " · 刷新订阅后保留改动")
                        : ("原始标识：" + raw + "（已重命名）");
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
                    setAlias(rule, line.rawName(), nextName);
                    saveRuleForScope(a, scope, rule);
                    line.name = nextName.isEmpty() ? line.rawName() : nextName;
                    if (handleRef[0] != null) handleRef[0].dismiss();
                    a.toast("已保存线路名称：" + line.name);
                    if (onChanged != null) onChanged.run();
                });
        box.addView(saveBtn, new LinearLayout.LayoutParams(-1, -2));
        handleRef[0] = MobileBottomSheet.showCustom(a, "重命名线路", box, null);
    }

    private static List<String> currentRawOrder(Cms.Video video) {
        List<String> out = new ArrayList<>();
        if (video == null) return out;
        for (Cms.Line l : video.lines) {
            if (l != null && !out.contains(l.rawName())) out.add(l.rawName());
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

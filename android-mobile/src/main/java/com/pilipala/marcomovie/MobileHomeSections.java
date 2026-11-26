package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;

/**
 * Stable ID-backed Home section visibility & ordering store matching iOS 0.7.7 {@code
 * _buildIosHomeSectionsSettingsBody} (Item 6: 原 1/6/10).
 *
 * <p>Guarantees:
 *
 * <ul>
 *   <li>All 9 Home sections are identified by stable IDs ({@code hero_billboard}, {@code
 *       watch_history}, {@code disc_widescreen_radar}, {@code disc_editorial_picks}, {@code
 *       disc_hot_stream}, {@code disc_mood_capsules}, {@code disc_studio_galleries}, {@code
 *       disc_poster_mosaics}, {@code source_updates}).
 *   <li>Changes take effect immediately upon returning to Home (via {@link #revision()}).
 *   <li>Even when ALL 9 sections are disabled, Home renders a clean recovery card and Settings
 *       remains reachable via both the navigation dock and the Home recovery button.
 * </ul>
 */
final class MobileHomeSections {
    static final String ID_HERO_BILLBOARD = "hero_billboard";
    static final String ID_WATCH_HISTORY = "watch_history";
    static final String ID_WIDESCREEN_RADAR = "disc_widescreen_radar";
    static final String ID_EDITORIAL_PICKS = "disc_editorial_picks";
    static final String ID_HOT_STREAM = "disc_hot_stream";
    static final String ID_MOOD_CAPSULES = "disc_mood_capsules";
    static final String ID_STUDIO_GALLERIES = "disc_studio_galleries";
    static final String ID_POSTER_MOSAICS = "disc_poster_mosaics";
    static final String ID_SOURCE_UPDATES = "source_updates";

    static final List<String> DEFAULT_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(
                            ID_HERO_BILLBOARD,
                            ID_WATCH_HISTORY,
                            ID_WIDESCREEN_RADAR,
                            ID_EDITORIAL_PICKS,
                            ID_HOT_STREAM,
                            ID_MOOD_CAPSULES,
                            ID_STUDIO_GALLERIES,
                            ID_POSTER_MOSAICS,
                            ID_SOURCE_UPDATES));

    static final List<String> CURATED_IDS =
            Collections.unmodifiableList(
                    Arrays.asList(
                            ID_WIDESCREEN_RADAR,
                            ID_EDITORIAL_PICKS,
                            ID_HOT_STREAM,
                            ID_MOOD_CAPSULES,
                            ID_STUDIO_GALLERIES,
                            ID_POSTER_MOSAICS));

    static final class SectionSpec {
        final String id;
        final String title;
        final String subtitle;

        SectionSpec(String id, String title, String subtitle) {
            this.id = id;
            this.title = title;
            this.subtitle = subtitle;
        }
    }

    static final List<SectionSpec> ALL_SPECS =
            Collections.unmodifiableList(
                    Arrays.asList(
                            new SectionSpec(ID_HERO_BILLBOARD, "精选大图横幅", "首页顶部沉浸式海报错落轮播"),
                            new SectionSpec(ID_WATCH_HISTORY, "继续观看", "最近观影记录一键续播条"),
                            new SectionSpec(ID_WIDESCREEN_RADAR, "光影风向标", "16:9 宽屏精选热榜推荐"),
                            new SectionSpec(ID_EDITORIAL_PICKS, "月度策划 · 藤蔓特辑", "季度与主题策划专题合集"),
                            new SectionSpec(ID_HOT_STREAM, "热播剧影榜", "热门剧集与电影排行片单"),
                            new SectionSpec(ID_MOOD_CAPSULES, "灵感片单", "按心情与场景快速挑片"),
                            new SectionSpec(ID_STUDIO_GALLERIES, "影业档案室", "经典制片厂与系列主题馆"),
                            new SectionSpec(ID_POSTER_MOSAICS, "口碑典藏馆", "高分影评与豆瓣典藏片单"),
                            new SectionSpec(ID_SOURCE_UPDATES, "片源片单", "当前已选片源的分类与最新海报墙")));

    private static final AtomicInteger REVISION = new AtomicInteger(1);

    private MobileHomeSections() {}

    static int revision() {
        return REVISION.get();
    }

    static void bumpRevision() {
        REVISION.incrementAndGet();
    }

    static String titleOf(String id) {
        for (SectionSpec s : ALL_SPECS) {
            if (s.id.equals(id)) return s.title;
        }
        return id == null ? "" : id;
    }

    static Set<String> parseHiddenIds(String raw) {
        Set<String> hidden = new LinkedHashSet<>();
        if (raw == null || raw.trim().isEmpty()) return hidden;
        String t = raw.trim();
        if (t.startsWith("[")) {
            try {
                JSONArray arr = new JSONArray(t);
                for (int i = 0; i < arr.length(); i++) {
                    String id = arr.optString(i, "").trim();
                    if (DEFAULT_ORDER.contains(id)) hidden.add(id);
                }
                return hidden;
            } catch (Exception ignored) {
            }
        }
        for (String part : t.split(",")) {
            String id = part.trim();
            if (DEFAULT_ORDER.contains(id)) hidden.add(id);
        }
        return hidden;
    }

    static String encodeHiddenIds(Set<String> hidden) {
        JSONArray arr = new JSONArray();
        if (hidden != null) {
            for (String id : DEFAULT_ORDER) {
                if (hidden.contains(id)) arr.put(id);
            }
        }
        return arr.toString();
    }

    static boolean isReorderable(String id) {
        return id != null && CURATED_IDS.contains(id);
    }

    static boolean canMoveUp(List<String> order, int idx) {
        if (order == null || idx <= 0 || idx >= order.size()) return false;
        return isReorderable(order.get(idx)) && isReorderable(order.get(idx - 1));
    }

    static boolean canMoveDown(List<String> order, int idx) {
        if (order == null || idx < 0 || idx + 1 >= order.size()) return false;
        return isReorderable(order.get(idx)) && isReorderable(order.get(idx + 1));
    }

    static List<String> parseOrder(String raw) {
        List<String> curatedOrder = new ArrayList<>();
        Set<String> seenCurated = new LinkedHashSet<>();
        if (raw != null && !raw.trim().isEmpty()) {
            for (String part : raw.split(",")) {
                String id = part.trim();
                if (CURATED_IDS.contains(id) && seenCurated.add(id)) {
                    curatedOrder.add(id);
                }
            }
        }
        for (String id : CURATED_IDS) {
            if (seenCurated.add(id)) curatedOrder.add(id);
        }
        // Keep structural fixed sections (hero, history, source_updates) in their real rendered
        // slots while honoring user ordering for every curated section that actually reorders on
        // MobileHomePage.
        List<String> out = new ArrayList<>(DEFAULT_ORDER.size());
        out.add(ID_HERO_BILLBOARD);
        out.add(ID_WATCH_HISTORY);
        out.addAll(curatedOrder);
        out.add(ID_SOURCE_UPDATES);
        return out;
    }

    static String encodeOrder(List<String> order) {
        List<String> norm = parseOrder(order == null ? "" : joinCsv(order));
        return joinCsv(norm);
    }

    private static String joinCsv(List<String> items) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    static Set<String> loadHidden(Context context) {
        if (context == null) return new LinkedHashSet<>();
        SharedPreferences mobile =
                context.getSharedPreferences(Prefs.MOBILE_FILE, Context.MODE_PRIVATE);
        SharedPreferences main = context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        return loadHiddenFromValues(
                mobile.getString(Prefs.MOBILE_HOME_SECTION_HIDDEN, ""),
                mobile.contains(Prefs.MOBILE_HOME_SECTION_HIDDEN),
                mobile.getBoolean(Prefs.HOME_CAROUSEL, true),
                main.getBoolean(Prefs.MOBILE_SHOW_HISTORY, true));
    }

    /** Pure-JVM helper bridging legacy hero/history booleans with stable section IDs. */
    static Set<String> loadHiddenFromValues(
            String rawHidden,
            boolean hasExplicitHidden,
            boolean legacyHeroOn,
            boolean legacyHistOn) {
        Set<String> hidden = parseHiddenIds(rawHidden);
        if (!hasExplicitHidden) {
            if (!legacyHeroOn) hidden.add(ID_HERO_BILLBOARD);
            if (!legacyHistOn) hidden.add(ID_WATCH_HISTORY);
        } else {
            // Keep legacy switches synchronized if changed directly
            if (!legacyHeroOn) hidden.add(ID_HERO_BILLBOARD);
            if (!legacyHistOn) hidden.add(ID_WATCH_HISTORY);
        }
        return hidden;
    }

    static List<String> loadOrder(Context context) {
        if (context == null) return new ArrayList<>(DEFAULT_ORDER);
        SharedPreferences mobile =
                context.getSharedPreferences(Prefs.MOBILE_FILE, Context.MODE_PRIVATE);
        return parseOrder(mobile.getString(Prefs.MOBILE_HOME_SECTION_ORDER, ""));
    }

    static boolean isVisible(Context context, String sectionId) {
        return !loadHidden(context).contains(sectionId);
    }

    static List<String> visibleCuratedIds(Context context) {
        Set<String> hidden = loadHidden(context);
        List<String> order = loadOrder(context);
        List<String> out = new ArrayList<>();
        for (String id : order) {
            if (CURATED_IDS.contains(id) && !hidden.contains(id)) {
                out.add(id);
            }
        }
        return out;
    }

    static boolean areAllHidden(Context context, boolean hasActiveSource) {
        Set<String> hidden = loadHidden(context);
        for (String id : DEFAULT_ORDER) {
            if (ID_SOURCE_UPDATES.equals(id) && !hasActiveSource) continue;
            if (!hidden.contains(id)) return false;
        }
        return true;
    }

    static int visibleCount(Context context) {
        return Math.max(0, DEFAULT_ORDER.size() - loadHidden(context).size());
    }

    static void setVisible(Context context, String sectionId, boolean visible) {
        if (context == null || !DEFAULT_ORDER.contains(sectionId)) return;
        Set<String> hidden = loadHidden(context);
        if (visible) hidden.remove(sectionId);
        else hidden.add(sectionId);
        saveHidden(context, hidden);
    }

    static void saveHidden(Context context, Set<String> hidden) {
        if (context == null) return;
        Set<String> clean =
                hidden == null ? new LinkedHashSet<String>() : new LinkedHashSet<>(hidden);
        SharedPreferences mobile =
                context.getSharedPreferences(Prefs.MOBILE_FILE, Context.MODE_PRIVATE);
        SharedPreferences main = context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        mobile.edit()
                .putString(Prefs.MOBILE_HOME_SECTION_HIDDEN, encodeHiddenIds(clean))
                .putBoolean(Prefs.HOME_CAROUSEL, !clean.contains(ID_HERO_BILLBOARD))
                .apply();
        main.edit()
                .putBoolean(Prefs.MOBILE_SHOW_HISTORY, !clean.contains(ID_WATCH_HISTORY))
                .apply();
        bumpRevision();
    }

    static void saveOrder(Context context, List<String> order) {
        if (context == null) return;
        context.getSharedPreferences(Prefs.MOBILE_FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(Prefs.MOBILE_HOME_SECTION_ORDER, encodeOrder(order))
                .apply();
        bumpRevision();
    }

    static void resetDefaults(Context context) {
        saveHidden(context, Collections.<String>emptySet());
        saveOrder(context, DEFAULT_ORDER);
    }

    /** Interactive MobileBottomSheet manager for all 9 Home sections (toggle + reorder + reset). */
    static void showSettingsSheet(final MainActivity a, final Runnable onChanged) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final Set<String> hidden = loadHidden(a);
        final List<String> order = loadOrder(a);

        final LinearLayout box = a.vertical();
        box.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(8));

        TextView intro =
                a.text("按栏目 ID 控制首页显示内容，返回首页立即生效；即使全部关闭，也可随时在设置或首页恢复。", 12f, p.textSecondary);
        intro.setLineSpacing(a.dp(2), 1f);
        box.addView(intro);
        a.gap(box, 10);

        final LinearLayout rowsHost = a.vertical();
        box.addView(rowsHost, new LinearLayout.LayoutParams(-1, -2));

        final Runnable[] rebuild = new Runnable[1];
        rebuild[0] =
                () -> {
                    rowsHost.removeAllViews();
                    for (int i = 0; i < order.size(); i++) {
                        final int idx = i;
                        final String id = order.get(i);
                        SectionSpec spec = findSpec(id);
                        final boolean on = !hidden.contains(id);

                        LinearLayout row = a.row();
                        row.setGravity(Gravity.CENTER_VERTICAL);
                        row.setPadding(a.dp(12), a.dp(10), a.dp(10), a.dp(10));
                        row.setBackground(MobileTheme.subtleBg(a, 12));

                        LinearLayout col = a.vertical();
                        TextView titleTv = a.text(spec.title, 14f, p.textPrimary);
                        titleTv.setTypeface(null, Typeface.BOLD);
                        titleTv.setSingleLine(true);
                        titleTv.setEllipsize(TextUtils.TruncateAt.END);
                        col.addView(titleTv);
                        TextView subTv = a.text(spec.subtitle, 11.5f, p.textSecondary);
                        subTv.setSingleLine(true);
                        subTv.setEllipsize(TextUtils.TruncateAt.END);
                        col.addView(subTv);
                        row.addView(col, new LinearLayout.LayoutParams(0, -2, 1f));

                        if (isReorderable(id)) {
                            if (canMoveUp(order, idx)) {
                                TextView upBtn = a.text("↑", 13f, p.textSecondary);
                                upBtn.setGravity(Gravity.CENTER);
                                upBtn.setPadding(a.dp(8), a.dp(6), a.dp(8), a.dp(6));
                                MobileMotion.bindPress(upBtn, 0.92f);
                                upBtn.setOnClickListener(
                                        v -> {
                                            Collections.swap(order, idx, idx - 1);
                                            saveOrder(a, order);
                                            rebuild[0].run();
                                            if (onChanged != null) onChanged.run();
                                        });
                                row.addView(upBtn);
                            }
                            if (canMoveDown(order, idx)) {
                                TextView downBtn = a.text("↓", 13f, p.textSecondary);
                                downBtn.setGravity(Gravity.CENTER);
                                downBtn.setPadding(a.dp(8), a.dp(6), a.dp(8), a.dp(6));
                                MobileMotion.bindPress(downBtn, 0.92f);
                                downBtn.setOnClickListener(
                                        v -> {
                                            Collections.swap(order, idx, idx + 1);
                                            saveOrder(a, order);
                                            rebuild[0].run();
                                            if (onChanged != null) onChanged.run();
                                        });
                                row.addView(downBtn);
                            }
                        } else {
                            TextView fixedTag = a.text("固定位置", 10.5f, p.textTertiary);
                            fixedTag.setPadding(a.dp(6), a.dp(4), a.dp(4), a.dp(4));
                            row.addView(fixedTag);
                        }

                        TextView togglePill =
                                a.text(
                                        on ? "显示" : "隐藏",
                                        12f,
                                        on ? p.accentOnFill : p.textSecondary);
                        togglePill.setTypeface(null, Typeface.BOLD);
                        togglePill.setGravity(Gravity.CENTER);
                        togglePill.setPadding(a.dp(12), a.dp(6), a.dp(12), a.dp(6));
                        togglePill.setBackground(
                                on ? MobileTheme.accentPillBg(a, 999) : MobileTheme.cardBg(a, 999));
                        MobileMotion.bindPress(togglePill, 0.93f);
                        togglePill.setOnClickListener(
                                v -> {
                                    if (hidden.contains(id)) hidden.remove(id);
                                    else hidden.add(id);
                                    saveHidden(a, hidden);
                                    rebuild[0].run();
                                    if (onChanged != null) onChanged.run();
                                });
                        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(-2, -2);
                        tlp.leftMargin = a.dp(6);
                        row.addView(togglePill, tlp);

                        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
                        rlp.bottomMargin = a.dp(6);
                        rowsHost.addView(row, rlp);
                    }
                };
        rebuild[0].run();

        a.gap(box, 8);
        LinearLayout quickRow = a.row();
        TextView allOn = buildFooterBtn(a, p, "全部开启", false);
        allOn.setOnClickListener(
                v -> {
                    hidden.clear();
                    saveHidden(a, hidden);
                    rebuild[0].run();
                    if (onChanged != null) onChanged.run();
                });
        LinearLayout.LayoutParams q1 = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
        q1.rightMargin = a.dp(6);
        quickRow.addView(allOn, q1);

        TextView allOff = buildFooterBtn(a, p, "全部关闭", false);
        allOff.setOnClickListener(
                v -> {
                    hidden.clear();
                    hidden.addAll(DEFAULT_ORDER);
                    saveHidden(a, hidden);
                    rebuild[0].run();
                    if (onChanged != null) onChanged.run();
                });
        LinearLayout.LayoutParams q2 = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
        q2.rightMargin = a.dp(6);
        quickRow.addView(allOff, q2);

        TextView resetBtn = buildFooterBtn(a, p, "恢复默认", true);
        resetBtn.setOnClickListener(
                v -> {
                    hidden.clear();
                    order.clear();
                    order.addAll(DEFAULT_ORDER);
                    resetDefaults(a);
                    rebuild[0].run();
                    if (onChanged != null) onChanged.run();
                });
        quickRow.addView(resetBtn, new LinearLayout.LayoutParams(0, a.dp(38), 1f));
        box.addView(quickRow, new LinearLayout.LayoutParams(-1, -2));

        MobileBottomSheet.showCustom(a, "首页专题显示与排序", box, null);
    }

    private static SectionSpec findSpec(String id) {
        for (SectionSpec s : ALL_SPECS) {
            if (s.id.equals(id)) return s;
        }
        return new SectionSpec(id, id, "");
    }

    private static TextView buildFooterBtn(
            MainActivity a, MobileTheme.Palette p, String text, boolean primary) {
        TextView tv = a.text(text, 12.5f, primary ? p.accentOnFill : p.textPrimary);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setGravity(Gravity.CENTER);
        tv.setSingleLine(true);
        tv.setBackground(primary ? MobileTheme.accentPillBg(a, 999) : MobileTheme.subtleBg(a, 999));
        MobileMotion.bindPress(tv, 0.95f);
        return tv;
    }
}

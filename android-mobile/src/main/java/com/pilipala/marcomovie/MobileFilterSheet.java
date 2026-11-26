package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Single-screen multi-dimensional horizontal capsule filter sheet for Android Mobile / Tablet.
 *
 * <p>Rendered inside {@link MobileBottomSheet#showHandle} (automatically tagged {@code
 * "mobile-drawer"}, capped at 76% window height, with finger-tracking drag-to-dismiss). Displays
 * every available filter dimension simultaneously as fixed-label rows paired with single-line
 * horizontally scrollable pill strips; tapping an active capsule toggles it back to {@code 全部}
 * ({@link #toggleSelection}), and the header {@code 重置} action appears only when at least one
 * filter is active.
 */
final class MobileFilterSheet {
    private MobileFilterSheet() {}

    /** Pure-JVM helper counting how many active filter selections apply to {@code defs}. */
    static int countActiveSelections(
            List<VideoFilters.Definition> defs, Map<String, String> selections) {
        if (selections == null || selections.isEmpty()) return 0;
        if (defs == null || defs.isEmpty()) {
            int count = 0;
            for (String v : selections.values()) {
                if (v != null && !v.trim().isEmpty()) count++;
            }
            return count;
        }
        int count = 0;
        Set<String> seen = new HashSet<>();
        for (VideoFilters.Definition def : defs) {
            if (def == null || def.dimension == null || !seen.add(def.dimension)) continue;
            String val = selections.get(def.dimension);
            if (val != null && !val.trim().isEmpty()) {
                count++;
            }
        }
        return count;
    }

    /**
     * Pure-JVM helper applying a single-dimension filter choice. Empty/null {@code value} resets
     * that dimension back to {@code 全部}. Returns {@code true} iff {@code selections} changed (and
     * {@code false} when selecting the identical value).
     */
    static boolean applySelection(Map<String, String> selections, String dimension, String value) {
        if (selections == null || dimension == null || dimension.trim().isEmpty()) return false;
        String key = dimension.trim();
        String next = value == null ? "" : value.trim();
        String prev = selections.get(key);
        if (next.isEmpty()) {
            if (prev == null || prev.isEmpty()) return false;
            selections.remove(key);
            return true;
        }
        if (next.equals(prev)) return false;
        selections.put(key, next);
        return true;
    }

    /**
     * Pure-JVM toggle helper for interactive capsules: tapping an already-active non-empty value
     * deselects that dimension back to {@code ""} ({@code 全部}) so every filter choice is
     * reversible in a single tap. Returns {@code true} iff {@code selections} changed.
     */
    static boolean toggleSelection(Map<String, String> selections, String dimension, String value) {
        if (selections == null || dimension == null || dimension.trim().isEmpty()) return false;
        String key = dimension.trim();
        String next = value == null ? "" : value.trim();
        if (next.isEmpty()) {
            return applySelection(selections, key, "");
        }
        String prev = selections.get(key);
        if (next.equals(prev)) {
            selections.remove(key);
            return true;
        }
        selections.put(key, next);
        return true;
    }

    /** Pure-JVM helper resetting all active filter dimensions. Returns {@code true} if changed. */
    static boolean resetSelections(Map<String, String> selections) {
        if (selections == null || selections.isEmpty()) return false;
        selections.clear();
        return true;
    }

    /** Pure-JVM helper producing a compact left-column label (e.g. {@code 国家 / 地区 -> 地区}). */
    static String shortDimensionLabel(VideoFilters.Definition def) {
        if (def == null || def.label == null || def.label.trim().isEmpty()) return "筛选";
        String trimmed = def.label.trim();
        if ("国家 / 地区".equals(trimmed) || (trimmed.contains("国家") && trimmed.contains("地区"))) {
            return "地区";
        }
        if ("class".equals(def.dimension) && trimmed.length() > 3) {
            return "类型";
        }
        return trimmed;
    }

    /** Pure-JVM helper formatting the header reset action label (empty when 0 filters active). */
    static String formatResetLabel(int activeCount) {
        return activeCount > 0 ? ("重置 (" + activeCount + ")") : "";
    }

    /** Pure-JVM helper summarizing currently active selections for the sheet subtitle. */
    static String formatSubtitle(
            List<VideoFilters.Definition> defs, Map<String, String> selections) {
        int active = countActiveSelections(defs, selections);
        if (active <= 0) {
            boolean remote = VideoFilters.hasRemoteDefinitions(defs);
            return remote ? "点击下方胶囊即时筛选" : "按已加载影片资料筛选 · 点击即时生效";
        }
        StringBuilder sb = new StringBuilder();
        sb.append("已选 ").append(active).append(" 项");
        if (defs != null && selections != null) {
            int shown = 0;
            for (VideoFilters.Definition def : defs) {
                if (def == null || def.dimension == null) continue;
                String val = selections.get(def.dimension);
                if (val == null || val.trim().isEmpty()) continue;
                sb.append(shown == 0 ? "：" : " · ");
                sb.append(def.labelFor(val));
                shown++;
                if (shown >= 3) break;
            }
            if (active > shown) {
                sb.append(" 等");
            }
        }
        return sb.toString();
    }

    static Dialog show(
            final MainActivity a,
            final List<VideoFilters.Definition> definitions,
            final Map<String, String> selections,
            final Runnable changed) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        final LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(2), 0, a.dp(6));

        final List<Runnable> rowRefreshers = new ArrayList<>();
        final MobileBottomSheet.SheetHandle[] handleRef = {null};
        final Runnable refreshHeader =
                () -> {
                    MobileBottomSheet.SheetHandle h = handleRef[0];
                    if (h == null) return;
                    int active = countActiveSelections(definitions, selections);
                    h.setSubtitle(formatSubtitle(definitions, selections));
                    h.setAction(formatResetLabel(active), active > 0);
                };

        if (definitions == null || definitions.isEmpty()) {
            TextView empty = a.text("当前分类暂无可用筛选维度", 13.5f, p.textSecondary);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(0, a.dp(20), 0, a.dp(20));
            content.addView(empty, new LinearLayout.LayoutParams(-1, -2));
        } else {
            int hairlinePx = MobileTheme.hairlinePx(a);
            for (int r = 0; r < definitions.size(); r++) {
                final VideoFilters.Definition def = definitions.get(r);
                if (def == null || def.choices.isEmpty()) continue;

                if (content.getChildCount() > 0) {
                    View divider = new View(a);
                    divider.setBackgroundColor(p.hairline);
                    LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(-1, hairlinePx);
                    dlp.topMargin = a.dp(8);
                    dlp.bottomMargin = a.dp(8);
                    content.addView(divider, dlp);
                }

                LinearLayout dimRow = a.row();
                dimRow.setGravity(Gravity.CENTER_VERTICAL);
                dimRow.setPadding(0, a.dp(2), 0, a.dp(2));

                TextView dimLabel = a.text(shortDimensionLabel(def), 13f, p.textSecondary);
                dimLabel.setTypeface(null, Typeface.BOLD);
                dimLabel.setSingleLine(true);
                dimLabel.setEllipsize(TextUtils.TruncateAt.END);
                dimLabel.setGravity(Gravity.LEFT | Gravity.CENTER_VERTICAL);
                LinearLayout.LayoutParams labelLp = new LinearLayout.LayoutParams(a.dp(46), -2);
                labelLp.rightMargin = a.dp(8);
                dimRow.addView(dimLabel, labelLp);

                final HorizontalScrollView hsv = new HorizontalScrollView(a);
                hsv.setHorizontalScrollBarEnabled(false);
                hsv.setOverScrollMode(View.OVER_SCROLL_IF_CONTENT_SCROLLS);
                hsv.setClipToPadding(false);

                LinearLayout pillStrip = a.row();
                pillStrip.setGravity(Gravity.CENTER_VERTICAL);
                hsv.addView(pillStrip, new HorizontalScrollView.LayoutParams(-2, -2));

                final List<TextView> pillViews = new ArrayList<>(def.choices.size());
                final List<String> pillValues = new ArrayList<>(def.choices.size());

                final Runnable refreshRow =
                        () -> {
                            String curVal =
                                    selections == null ? null : selections.get(def.dimension);
                            String normCur = curVal == null ? "" : curVal;
                            for (int i = 0; i < pillViews.size(); i++) {
                                boolean active = normCur.equals(pillValues.get(i));
                                styleCapsule(a, p, pillViews.get(i), active);
                            }
                        };
                rowRefreshers.add(refreshRow);

                TextView initialActiveView = null;
                String initialSel = selections == null ? null : selections.get(def.dimension);
                String normInit = initialSel == null ? "" : initialSel;

                for (int c = 0; c < def.choices.size(); c++) {
                    final VideoFilters.Choice choice = def.choices.get(c);
                    final String choiceVal = choice.value == null ? "" : choice.value;
                    final boolean active = normInit.equals(choiceVal);

                    final TextView pill = a.text(choice.label, 13f, p.textPrimary);
                    pill.setSingleLine(true);
                    pill.setGravity(Gravity.CENTER);
                    pill.setPadding(a.dp(13), a.dp(6.5f), a.dp(13), a.dp(6.5f));
                    styleCapsule(a, p, pill, active);
                    MobileMotion.bindPress(pill, 0.94f);
                    pill.setOnClickListener(
                            v -> {
                                if (!toggleSelection(selections, def.dimension, choiceVal)) return;
                                refreshRow.run();
                                String nowVal =
                                        selections == null ? null : selections.get(def.dimension);
                                if (!choiceVal.isEmpty() && choiceVal.equals(nowVal)) {
                                    MobileMotion.popBounce(pill);
                                }
                                refreshHeader.run();
                                if (changed != null) changed.run();
                            });

                    LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(-2, -2);
                    if (c + 1 < def.choices.size()) plp.rightMargin = a.dp(8);
                    pillStrip.addView(pill, plp);
                    pillViews.add(pill);
                    pillValues.add(choiceVal);
                    if (active && !choiceVal.isEmpty()) {
                        initialActiveView = pill;
                    }
                }

                if (initialActiveView != null) {
                    final View targetPill = initialActiveView;
                    hsv.post(
                            () -> {
                                int scrollX = Math.max(0, targetPill.getLeft() - a.dp(24));
                                hsv.scrollTo(scrollX, 0);
                            });
                }

                dimRow.addView(hsv, new LinearLayout.LayoutParams(0, -2, 1f));
                content.addView(dimRow, new LinearLayout.LayoutParams(-1, -2));
            }
        }

        final int initialActive = countActiveSelections(definitions, selections);
        final String initialSubtitle = formatSubtitle(definitions, selections);
        final String initialAction = formatResetLabel(initialActive);
        Runnable onReset =
                () -> {
                    if (!resetSelections(selections)) return;
                    for (Runnable refresher : rowRefreshers) {
                        refresher.run();
                    }
                    refreshHeader.run();
                    if (changed != null) changed.run();
                };

        handleRef[0] =
                MobileBottomSheet.showHandle(
                        a, "分类筛选", initialSubtitle, initialAction, onReset, content, true);
        return handleRef[0].dialog();
    }

    private static void styleCapsule(
            MainActivity a, MobileTheme.Palette p, TextView pill, boolean active) {
        if (active) {
            pill.setBackground(MobileTheme.accentPillBg(a, 999));
            pill.setTextColor(p.accentOnFill);
            pill.setTypeface(null, Typeface.BOLD);
        } else {
            pill.setBackground(MobileTheme.subtleBg(a, 999));
            pill.setTextColor(p.textPrimary);
            pill.setTypeface(null, Typeface.NORMAL);
        }
    }
}

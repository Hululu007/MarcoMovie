package com.pilipala.marcomovie;

import android.graphics.Rect;
import android.view.*;
import android.widget.*;
import java.util.*;

/** Three persistent, horizontally browsable filter rows below the TV category bar. */
final class InlineFilters extends LinearLayout {
    final HomeScreen home;
    final MainActivity a;
    final List<List<View>> rows = new ArrayList<>();
    final Map<TextView, String[]> choices = new LinkedHashMap<>();
    String schema = "";

    InlineFilters(HomeScreen screen) {
        super(screen.a);
        home = screen;
        a = home.a;
        setOrientation(VERTICAL);
        setTag("home-inline-filters");
        setPadding(a.dp(10), a.dp(6), a.dp(6), a.dp(6));
        setBackground(a.bg(0x55282d37, 18));
        setVisibility(GONE);
    }

    void render() {
        if (!a.isTvDevice() || !home.state.filtersExpanded || home.snapshot == null) {
            setVisibility(GONE);
            return;
        }
        List<VideoFilters.Definition> definitions = home.filterDefinitions();
        StringBuilder signature = new StringBuilder();
        for (VideoFilters.Definition def : definitions) {
            signature.append(def.dimension).append(':').append(def.key).append(':');
            for (VideoFilters.Choice choice : def.choices)
                signature
                        .append(choice.value.length())
                        .append(':')
                        .append(choice.value)
                        .append(choice.label.length())
                        .append(':')
                        .append(choice.label);
        }
        if (!signature.toString().equals(schema)) {
            String focus =
                    hasFocus() && a.getCurrentFocus() != null
                            ? String.valueOf(a.getCurrentFocus().getTag())
                            : null;
            removeAllViews();
            rows.clear();
            choices.clear();
            schema = signature.toString();
            for (VideoFilters.Definition def : definitions) addRow(def);
            if (focus != null) {
                View replacement = findViewWithTag(focus);
                if (replacement != null) replacement.requestFocus();
            }
        }
        setVisibility(VISIBLE);
        for (TextView button : choices.keySet()) style(button);
    }

    void addRow(VideoFilters.Definition def) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = a.text(def.label, 11.5f * home.navScale, MainActivity.MUTED);
        row.addView(title, new LayoutParams(a.dp(Math.round(82 * home.navScale)), -2));
        HorizontalScrollView viewport = new HorizontalScrollView(a);
        viewport.setHorizontalScrollBarEnabled(false);
        viewport.setOverScrollMode(OVER_SCROLL_NEVER);
        viewport.setSmoothScrollingEnabled(false);
        viewport.setFocusable(false);
        LinearLayout options = a.row();
        options.setGravity(Gravity.CENTER_VERTICAL);
        List<View> line = new ArrayList<>();
        rows.add(line);
        for (int index = 0; index < def.choices.size(); index++) {
            VideoFilters.Choice choice = def.choices.get(index);
            TextView button = a.text(choice.label, 12f * home.navScale, MainActivity.WHITE);
            button.setGravity(Gravity.CENTER);
            button.setSingleLine(true);
            button.setIncludeFontPadding(false);
            button.setPadding(a.dp(12), 0, a.dp(12), 0);
            home.focusable(button, "home-filter:" + def.dimension + ":" + index);
            choices.put(button, new String[] {def.dimension, choice.value});
            button.setOnClickListener(
                    v -> {
                        String previous = home.state.selectedFilters.get(def.dimension);
                        if (choice.value.equals(previous == null ? "" : previous)) return;
                        if (choice.value.isEmpty())
                            home.state.selectedFilters.remove(def.dimension);
                        else home.state.selectedFilters.put(def.dimension, choice.value);
                        home.applyFilters();
                    });
            button.setOnFocusChangeListener(
                    (v, focused) -> {
                        style(button);
                        if (focused) post(home::wireNavigation);
                    });
            LayoutParams size = new LayoutParams(-2, a.dp(Math.round(34 * home.navScale)));
            size.rightMargin = a.dp(4);
            options.addView(button, size);
            line.add(button);
        }
        viewport.addView(options, new HorizontalScrollView.LayoutParams(-2, -1));
        row.addView(viewport, new LayoutParams(0, a.dp(Math.round(40 * home.navScale)), 1));
        addView(row, new LayoutParams(-1, -2));
    }

    void style(TextView button) {
        String[] value = choices.get(button);
        String selected = home.state.selectedFilters.get(value[0]);
        boolean checked = value[1].equals(selected == null ? "" : selected);
        button.setSelected(checked);
        button.setTextColor(checked || button.hasFocus() ? MainActivity.WHITE : 0xffb8c3d3);
        android.graphics.drawable.GradientDrawable background =
                a.bg(button.hasFocus() ? 0x885c7189 : checked ? 0x6652657d : 0x00000000, 17);
        if (button.hasFocus()) background.setStroke(Math.max(1, a.dp(1)), 0xffdcecff);
        button.setBackground(background);
        button.setContentDescription(button.getText() + (checked ? "，已选择" : ""));
    }

    boolean expanded() {
        return getVisibility() == VISIBLE && !rows.isEmpty();
    }

    View nearest(List<View> line, View from) {
        int[] location = new int[2];
        from.getLocationOnScreen(location);
        float center = location[0] + from.getWidth() / 2f;
        View best = line.get(0);
        float distance = Float.MAX_VALUE;
        Rect visible = new Rect();
        for (View option : line) {
            if (!option.getGlobalVisibleRect(visible) || visible.width() < option.getWidth() / 2)
                continue;
            float next = Math.abs(visible.exactCenterX() - center);
            if (next < distance) {
                best = option;
                distance = next;
            }
        }
        return best;
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        super.onLayout(changed, l, t, r, b);
        home.wireNavigation();
    }
}

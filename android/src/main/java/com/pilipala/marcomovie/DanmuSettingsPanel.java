package com.pilipala.marcomovie;

import android.app.AlertDialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.drawable.GradientDrawable;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import com.pilipala.marcomovie.DanmuProvider.BlockFilter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * Self-contained Android danmu preferences store and TV/Mobile settings panel UI.
 *
 * <p>Persists exclusively under {@code danmu_*} keys in {@link SharedPreferences} without touching
 * {@code Prefs.java}. Default server URL list is strictly empty ({@code ""}).
 */
public final class DanmuSettingsPanel {

    public static final String PREFS_FILE = "movie";
    public static final String KEY_ENABLED = "danmu_enabled";
    public static final String KEY_SERVER_URLS = "danmu_server_urls";
    public static final String KEY_APP_ID = "danmu_app_id";
    public static final String KEY_APP_SECRET = "danmu_app_secret";
    public static final String KEY_OPACITY = "danmu_opacity";
    public static final String KEY_DISPLAY_AREA = "danmu_display_area";
    public static final String KEY_FONT_SIZE = "danmu_font_size";
    public static final String KEY_SPEED_MULTIPLIER = "danmu_speed_multiplier";
    public static final String KEY_TIME_OFFSET_MS = "danmu_time_offset_ms";
    public static final String KEY_SHOW_SCROLL = "danmu_show_scroll";
    public static final String KEY_SHOW_TOP = "danmu_show_top";
    public static final String KEY_SHOW_BOTTOM = "danmu_show_bottom";
    public static final String KEY_MAX_ROWS = "danmu_max_rows";
    public static final String KEY_BLOCK_RULES = "danmu_block_rules";

    public static final float DEFAULT_OPACITY = 0.85f;
    public static final float DEFAULT_DISPLAY_AREA = 0.50f;
    public static final float DEFAULT_MOBILE_FONT_SIZE = 20f;
    public static final float DEFAULT_TV_FONT_SIZE = 24f;
    public static final float DEFAULT_SPEED_MULTIPLIER = 1.0f;
    public static final long DEFAULT_TIME_OFFSET_MS = 0L;
    public static final int DEFAULT_MOBILE_MAX_ROWS = 14;
    public static final int DEFAULT_TV_MAX_ROWS = 6;
    public static final float[] AREA_OPTIONS = new float[] {0.25f, 0.50f, 0.75f, 1.00f};
    public static final float[] SPEED_OPTIONS = new float[] {0.75f, 1.00f, 1.25f, 1.50f};

    public interface OnConfigChangedListener {
        void onDanmuConfigChanged(DanmuConfig config);
    }

    public static final class DanmuConfig {
        public final boolean enabled;
        public final String serverUrls;
        public final String appId;
        public final String appSecret;
        public final float opacity;
        public final float displayArea;
        public final float fontSizeSp;
        public final float speedMultiplier;
        public final long timeOffsetMs;
        public final boolean showScroll;
        public final boolean showTop;
        public final boolean showBottom;
        public final int maxRows;
        public final List<String> blockRules;
        public final boolean tvProfile;

        public DanmuConfig(
                boolean enabled,
                String serverUrls,
                String appId,
                String appSecret,
                float opacity,
                float displayArea,
                float fontSizeSp,
                float speedMultiplier,
                long timeOffsetMs,
                boolean showScroll,
                boolean showTop,
                boolean showBottom,
                int maxRows,
                List<String> blockRules,
                boolean tvProfile) {
            this.tvProfile = tvProfile;
            this.enabled = enabled;
            this.serverUrls = serverUrls == null ? "" : serverUrls.trim();
            this.appId = appId == null ? "" : appId.trim();
            this.appSecret = appSecret == null ? "" : appSecret.trim();
            this.opacity = clampOpacity(opacity);
            this.displayArea = snapArea(displayArea);
            this.fontSizeSp = clampFontSize(fontSizeSp, tvProfile);
            this.speedMultiplier = snapSpeed(speedMultiplier);
            this.timeOffsetMs = clampTimeOffsetMs(timeOffsetMs);
            this.showScroll = showScroll;
            this.showTop = showTop;
            this.showBottom = showBottom;
            this.maxRows = clampMaxRows(maxRows, tvProfile);
            this.blockRules = sanitizeBlockRules(blockRules);
        }

        public static DanmuConfig defaults(boolean isTv) {
            return new DanmuConfig(
                    false,
                    DandanplayProvider.DEFAULT_SERVER_URLS,
                    "",
                    "",
                    DEFAULT_OPACITY,
                    DEFAULT_DISPLAY_AREA,
                    isTv ? DEFAULT_TV_FONT_SIZE : DEFAULT_MOBILE_FONT_SIZE,
                    DEFAULT_SPEED_MULTIPLIER,
                    DEFAULT_TIME_OFFSET_MS,
                    true,
                    true,
                    true,
                    isTv ? DEFAULT_TV_MAX_ROWS : DEFAULT_MOBILE_MAX_ROWS,
                    Collections.<String>emptyList(),
                    isTv);
        }

        public DandanplayProvider createProvider() {
            return new DandanplayProvider(serverUrls, appId, appSecret);
        }

        public BlockFilter createBlockFilter() {
            return BlockFilter.compile(blockRules);
        }

        public Builder toBuilder() {
            return new Builder(this);
        }

        public static final class Builder {
            boolean enabled;
            String serverUrls;
            String appId;
            String appSecret;
            float opacity;
            float displayArea;
            float fontSizeSp;
            float speedMultiplier;
            long timeOffsetMs;
            boolean showScroll;
            boolean showTop;
            boolean showBottom;
            int maxRows;
            List<String> blockRules;
            boolean tvProfile;

            Builder(DanmuConfig src) {
                this.enabled = src.enabled;
                this.serverUrls = src.serverUrls;
                this.appId = src.appId;
                this.appSecret = src.appSecret;
                this.opacity = src.opacity;
                this.displayArea = src.displayArea;
                this.fontSizeSp = src.fontSizeSp;
                this.speedMultiplier = src.speedMultiplier;
                this.timeOffsetMs = src.timeOffsetMs;
                this.showScroll = src.showScroll;
                this.showTop = src.showTop;
                this.showBottom = src.showBottom;
                this.maxRows = src.maxRows;
                this.blockRules = new ArrayList<>(src.blockRules);
                this.tvProfile = src.tvProfile;
            }

            public DanmuConfig build() {
                return new DanmuConfig(
                        enabled,
                        serverUrls,
                        appId,
                        appSecret,
                        opacity,
                        displayArea,
                        fontSizeSp,
                        speedMultiplier,
                        timeOffsetMs,
                        showScroll,
                        showTop,
                        showBottom,
                        maxRows,
                        blockRules,
                        tvProfile);
            }
        }
    }

    private DanmuSettingsPanel() {}

    public static float clampOpacity(float value) {
        float clamped = Math.max(0.20f, Math.min(1.00f, value));
        return Math.round(clamped * 20f) / 20f;
    }

    public static float snapArea(float value) {
        float best = AREA_OPTIONS[1];
        float bestDiff = Float.MAX_VALUE;
        for (float opt : AREA_OPTIONS) {
            float diff = Math.abs(opt - value);
            if (diff < bestDiff) {
                bestDiff = diff;
                best = opt;
            }
        }
        return best;
    }

    public static float clampFontSize(float sp, boolean isTv) {
        float min = isTv ? 18f : 14f;
        float max = isTv ? 36f : 32f;
        return Math.max(min, Math.min(max, Math.round(sp)));
    }

    public static float snapSpeed(float value) {
        float best = SPEED_OPTIONS[1];
        float bestDiff = Float.MAX_VALUE;
        for (float opt : SPEED_OPTIONS) {
            float diff = Math.abs(opt - value);
            if (diff < bestDiff) {
                bestDiff = diff;
                best = opt;
            }
        }
        return best;
    }

    public static long clampTimeOffsetMs(long offsetMs) {
        long clamped = Math.max(-30000L, Math.min(30000L, offsetMs));
        return Math.round(clamped / 500.0) * 500L;
    }

    public static int clampMaxRows(int rows, boolean isTv) {
        int cap = isTv ? 8 : 14;
        return Math.max(2, Math.min(cap, rows));
    }

    public static List<String> sanitizeBlockRules(List<String> rawRules) {
        if (rawRules == null || rawRules.isEmpty()) return Collections.emptyList();
        List<String> out = new ArrayList<>();
        for (String rule : rawRules) {
            if (out.size() >= BlockFilter.MAX_RULES) break;
            if (rule == null) continue;
            String trimmed = rule.trim();
            if (trimmed.isEmpty()) continue;
            if (BlockFilter.validateRule(trimmed).valid && !out.contains(trimmed)) {
                out.add(trimmed);
            }
        }
        return Collections.unmodifiableList(out);
    }

    public static DanmuConfig loadConfig(Context context, boolean isTv) {
        if (context == null) return DanmuConfig.defaults(isTv);
        SharedPreferences prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE);
        DanmuConfig def = DanmuConfig.defaults(isTv);
        String rawRules = prefs.getString(KEY_BLOCK_RULES, "");
        List<String> rules = new ArrayList<>();
        if (rawRules != null && !rawRules.trim().isEmpty()) {
            for (String line : rawRules.split("\\r?\\n")) {
                if (!line.trim().isEmpty()) rules.add(line.trim());
            }
        }
        return new DanmuConfig(
                prefs.getBoolean(KEY_ENABLED, def.enabled),
                prefs.getString(KEY_SERVER_URLS, def.serverUrls),
                prefs.getString(KEY_APP_ID, def.appId),
                prefs.getString(KEY_APP_SECRET, def.appSecret),
                prefs.getFloat(KEY_OPACITY, def.opacity),
                prefs.getFloat(KEY_DISPLAY_AREA, def.displayArea),
                prefs.getFloat(KEY_FONT_SIZE, def.fontSizeSp),
                prefs.getFloat(KEY_SPEED_MULTIPLIER, def.speedMultiplier),
                prefs.getLong(KEY_TIME_OFFSET_MS, def.timeOffsetMs),
                prefs.getBoolean(KEY_SHOW_SCROLL, def.showScroll),
                prefs.getBoolean(KEY_SHOW_TOP, def.showTop),
                prefs.getBoolean(KEY_SHOW_BOTTOM, def.showBottom),
                prefs.getInt(KEY_MAX_ROWS, def.maxRows),
                rules,
                isTv);
    }

    public static void saveConfig(Context context, DanmuConfig config) {
        if (context == null || config == null) return;
        SharedPreferences prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE);
        StringBuilder rulesJoined = new StringBuilder();
        for (int i = 0; i < config.blockRules.size(); i++) {
            if (i > 0) rulesJoined.append('\n');
            rulesJoined.append(config.blockRules.get(i));
        }
        prefs.edit()
                .putBoolean(KEY_ENABLED, config.enabled)
                .putString(KEY_SERVER_URLS, config.serverUrls)
                .putString(KEY_APP_ID, config.appId)
                .putString(KEY_APP_SECRET, config.appSecret)
                .putFloat(KEY_OPACITY, config.opacity)
                .putFloat(KEY_DISPLAY_AREA, config.displayArea)
                .putFloat(KEY_FONT_SIZE, config.fontSizeSp)
                .putFloat(KEY_SPEED_MULTIPLIER, config.speedMultiplier)
                .putLong(KEY_TIME_OFFSET_MS, config.timeOffsetMs)
                .putBoolean(KEY_SHOW_SCROLL, config.showScroll)
                .putBoolean(KEY_SHOW_TOP, config.showTop)
                .putBoolean(KEY_SHOW_BOTTOM, config.showBottom)
                .putInt(KEY_MAX_ROWS, config.maxRows)
                .putString(KEY_BLOCK_RULES, rulesJoined.toString())
                .apply();
    }

    public static AlertDialog showDialog(
            Context context, boolean isTv, OnConfigChangedListener listener) {
        View panel = createPanelView(context, isTv, listener);
        AlertDialog dialog =
                new AlertDialog.Builder(context, android.R.style.Theme_DeviceDefault_Dialog)
                        .setTitle("弹幕设置")
                        .setView(panel)
                        .setPositiveButton("完成", null)
                        .create();
        dialog.show();
        return dialog;
    }

    public static View createPanelView(
            final Context context, final boolean isTv, final OnConfigChangedListener listener) {
        final DanmuConfig[] state = new DanmuConfig[] {loadConfig(context, isTv)};
        final float density = context.getResources().getDisplayMetrics().density;
        final int pad = Math.round(16f * density);

        ScrollView scroll = new ScrollView(context);
        scroll.setBackgroundColor(TvV17Theme.OPAQUE_SURFACE);

        LinearLayout root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root);

        final CheckBox enableBox = makeCheckBox(context, "开启弹幕", state[0].enabled);
        root.addView(enableBox);

        final TextView opacityLabel = makeSectionLabel(context, "");
        root.addView(opacityLabel);
        LinearLayout opacityRow = makeRow(context);
        Button opacityMinus = makeActionButton(context, "-5%", density);
        Button opacityPlus = makeActionButton(context, "+5%", density);
        opacityRow.addView(opacityMinus);
        opacityRow.addView(opacityPlus);
        root.addView(opacityRow);

        final TextView areaLabel = makeSectionLabel(context, "");
        root.addView(areaLabel);
        LinearLayout areaRow = makeRow(context);
        final Button[] areaButtons = new Button[AREA_OPTIONS.length];
        for (int i = 0; i < AREA_OPTIONS.length; i++) {
            final float opt = AREA_OPTIONS[i];
            Button b = makeActionButton(context, Math.round(opt * 100) + "%", density);
            areaButtons[i] = b;
            areaRow.addView(b);
            b.setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            DanmuConfig.Builder bldr = state[0].toBuilder();
                            bldr.displayArea = opt;
                            state[0] = bldr.build();
                            persistAndNotify(context, state[0], listener);
                            areaLabel.setText(formatArea(state[0].displayArea));
                        }
                    });
        }
        root.addView(areaRow);

        final TextView fontLabel = makeSectionLabel(context, "");
        root.addView(fontLabel);
        LinearLayout fontRow = makeRow(context);
        Button fontMinus = makeActionButton(context, "字号 -2", density);
        Button fontPlus = makeActionButton(context, "字号 +2", density);
        fontRow.addView(fontMinus);
        fontRow.addView(fontPlus);
        root.addView(fontRow);

        final TextView speedLabel = makeSectionLabel(context, "");
        root.addView(speedLabel);
        LinearLayout speedRow = makeRow(context);
        for (int i = 0; i < SPEED_OPTIONS.length; i++) {
            final float opt = SPEED_OPTIONS[i];
            Button b = makeActionButton(context, String.format(Locale.US, "%.2gx", opt), density);
            speedRow.addView(b);
            b.setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            DanmuConfig.Builder bldr = state[0].toBuilder();
                            bldr.speedMultiplier = opt;
                            state[0] = bldr.build();
                            persistAndNotify(context, state[0], listener);
                            speedLabel.setText(formatSpeed(state[0].speedMultiplier));
                        }
                    });
        }
        root.addView(speedRow);

        final TextView offsetLabel = makeSectionLabel(context, "");
        root.addView(offsetLabel);
        LinearLayout offsetRow = makeRow(context);
        Button offsetMinus = makeActionButton(context, "-0.5s", density);
        Button offsetReset = makeActionButton(context, "归零", density);
        Button offsetPlus = makeActionButton(context, "+0.5s", density);
        offsetRow.addView(offsetMinus);
        offsetRow.addView(offsetReset);
        offsetRow.addView(offsetPlus);
        root.addView(offsetRow);

        final CheckBox scrollBox = makeCheckBox(context, "显示滚动弹幕", state[0].showScroll);
        final CheckBox topBox = makeCheckBox(context, "显示顶部弹幕", state[0].showTop);
        final CheckBox bottomBox = makeCheckBox(context, "显示底部弹幕", state[0].showBottom);
        root.addView(scrollBox);
        root.addView(topBox);
        root.addView(bottomBox);

        root.addView(makeSectionLabel(context, "自定义兼容弹幕服务地址（每行一个，最多 8 个，默认留空）"));
        final EditText serverUrlsInput =
                makeInput(context, state[0].serverUrls, "https://danmu.example", true);
        root.addView(serverUrlsInput);

        root.addView(makeSectionLabel(context, "可选 Open API 凭据（AppId / AppSecret，可留空）"));
        final EditText appIdInput = makeInput(context, state[0].appId, "AppId（可选）", false);
        final EditText appSecretInput =
                makeInput(context, state[0].appSecret, "AppSecret（可选）", false);
        appSecretInput.setInputType(
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        root.addView(appIdInput);
        root.addView(appSecretInput);

        Button saveServerBtn = makeActionButton(context, "保存服务配置", density);
        root.addView(saveServerBtn);

        root.addView(makeSectionLabel(context, "屏蔽词管理（支持纯文本或 re: 正则，最多 100 条）"));
        final EditText ruleInput = makeInput(context, "", "输入关键词或 re:剧透|打卡", false);
        root.addView(ruleInput);
        final TextView ruleError = new TextView(context);
        ruleError.setTextColor(0xFFFF6961);
        ruleError.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f);
        ruleError.setVisibility(View.GONE);
        root.addView(ruleError);

        LinearLayout ruleActions = makeRow(context);
        Button addRuleBtn = makeActionButton(context, "添加屏蔽规则", density);
        Button clearRulesBtn = makeActionButton(context, "清空规则", density);
        ruleActions.addView(addRuleBtn);
        ruleActions.addView(clearRulesBtn);
        root.addView(ruleActions);

        final TextView rulesSummary = new TextView(context);
        rulesSummary.setTextColor(TvV17Theme.MUTED);
        rulesSummary.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f);
        root.addView(rulesSummary);

        Runnable refreshLabels =
                new Runnable() {
                    @Override
                    public void run() {
                        opacityLabel.setText(formatOpacity(state[0].opacity));
                        areaLabel.setText(formatArea(state[0].displayArea));
                        fontLabel.setText(formatFontSize(state[0].fontSizeSp));
                        speedLabel.setText(formatSpeed(state[0].speedMultiplier));
                        offsetLabel.setText(formatOffset(state[0].timeOffsetMs));
                        rulesSummary.setText(formatRulesSummary(state[0].blockRules));
                    }
                };
        refreshLabels.run();

        enableBox.setOnCheckedChangeListener(
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.enabled = isChecked;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                    }
                });
        scrollBox.setOnCheckedChangeListener(
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.showScroll = isChecked;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                    }
                });
        topBox.setOnCheckedChangeListener(
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.showTop = isChecked;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                    }
                });
        bottomBox.setOnCheckedChangeListener(
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.showBottom = isChecked;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                    }
                });

        opacityMinus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.opacity = clampOpacity(state[0].opacity - 0.05f);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        opacityLabel.setText(formatOpacity(state[0].opacity));
                    }
                });
        opacityPlus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.opacity = clampOpacity(state[0].opacity + 0.05f);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        opacityLabel.setText(formatOpacity(state[0].opacity));
                    }
                });
        fontMinus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.fontSizeSp = clampFontSize(state[0].fontSizeSp - 2f, isTv);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        fontLabel.setText(formatFontSize(state[0].fontSizeSp));
                    }
                });
        fontPlus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.fontSizeSp = clampFontSize(state[0].fontSizeSp + 2f, isTv);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        fontLabel.setText(formatFontSize(state[0].fontSizeSp));
                    }
                });
        offsetMinus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.timeOffsetMs = clampTimeOffsetMs(state[0].timeOffsetMs - 500L);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        offsetLabel.setText(formatOffset(state[0].timeOffsetMs));
                    }
                });
        offsetReset.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.timeOffsetMs = 0L;
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        offsetLabel.setText(formatOffset(state[0].timeOffsetMs));
                    }
                });
        offsetPlus.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.timeOffsetMs = clampTimeOffsetMs(state[0].timeOffsetMs + 500L);
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        offsetLabel.setText(formatOffset(state[0].timeOffsetMs));
                    }
                });
        saveServerBtn.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.serverUrls = serverUrlsInput.getText().toString().trim();
                        b.appId = appIdInput.getText().toString().trim();
                        b.appSecret = appSecretInput.getText().toString().trim();
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                    }
                });
        addRuleBtn.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        String candidate = ruleInput.getText().toString().trim();
                        BlockFilter.ValidationResult vr = BlockFilter.validateRule(candidate);
                        if (!vr.valid) {
                            ruleError.setText(vr.error);
                            ruleError.setVisibility(View.VISIBLE);
                            return;
                        }
                        if (state[0].blockRules.size() >= BlockFilter.MAX_RULES) {
                            ruleError.setText("屏蔽规则已达 100 条上限");
                            ruleError.setVisibility(View.VISIBLE);
                            return;
                        }
                        ruleError.setVisibility(View.GONE);
                        DanmuConfig.Builder b = state[0].toBuilder();
                        if (!b.blockRules.contains(candidate)) {
                            b.blockRules.add(candidate);
                        }
                        state[0] = b.build();
                        ruleInput.setText("");
                        persistAndNotify(context, state[0], listener);
                        rulesSummary.setText(formatRulesSummary(state[0].blockRules));
                    }
                });
        clearRulesBtn.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        ruleError.setVisibility(View.GONE);
                        DanmuConfig.Builder b = state[0].toBuilder();
                        b.blockRules.clear();
                        state[0] = b.build();
                        persistAndNotify(context, state[0], listener);
                        rulesSummary.setText(formatRulesSummary(state[0].blockRules));
                    }
                });

        return scroll;
    }

    private static void persistAndNotify(
            Context context, DanmuConfig config, OnConfigChangedListener listener) {
        saveConfig(context, config);
        if (listener != null) {
            listener.onDanmuConfigChanged(config);
        }
    }

    private static String formatOpacity(float opacity) {
        return "不透明度：" + Math.round(opacity * 100f) + "%";
    }

    private static String formatArea(float area) {
        return "显示区域：" + Math.round(area * 100f) + "%";
    }

    private static String formatFontSize(float sp) {
        return "字号：" + Math.round(sp) + "sp";
    }

    private static String formatSpeed(float mult) {
        return String.format(Locale.US, "滚动速度：%.2gx", mult);
    }

    private static String formatOffset(long offsetMs) {
        double sec = offsetMs / 1000.0;
        return String.format(Locale.US, "时间轴偏移：%+.1fs", sec);
    }

    private static String formatRulesSummary(List<String> rules) {
        if (rules.isEmpty()) return "已生效规则：0 / 100";
        StringBuilder sb = new StringBuilder("已生效规则（").append(rules.size()).append(" / 100）：");
        int shown = Math.min(6, rules.size());
        for (int i = 0; i < shown; i++) {
            if (i > 0) sb.append("、");
            sb.append(rules.get(i));
        }
        if (rules.size() > shown) {
            sb.append(" 等");
        }
        return sb.toString();
    }

    private static TextView makeSectionLabel(Context context, String text) {
        TextView tv = new TextView(context);
        tv.setText(text);
        tv.setTextColor(TvV17Theme.TEXT);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f);
        LinearLayout.LayoutParams lp =
                new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Math.round(10f * context.getResources().getDisplayMetrics().density);
        lp.bottomMargin = Math.round(4f * context.getResources().getDisplayMetrics().density);
        tv.setLayoutParams(lp);
        return tv;
    }

    private static CheckBox makeCheckBox(Context context, String label, boolean checked) {
        CheckBox box = new CheckBox(context);
        box.setText(label);
        box.setTextColor(TvV17Theme.TEXT);
        box.setChecked(checked);
        box.setFocusable(true);
        return box;
    }

    private static LinearLayout makeRow(Context context) {
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        return row;
    }

    private static Button makeActionButton(Context context, String text, float density) {
        Button b = new Button(context);
        b.setText(text);
        b.setTextColor(TvV17Theme.TEXT);
        b.setFocusable(true);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xFF2E3846);
        bg.setCornerRadius(8f * density);
        b.setBackground(bg);
        LinearLayout.LayoutParams lp =
                new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.rightMargin = Math.round(8f * density);
        lp.bottomMargin = Math.round(6f * density);
        b.setLayoutParams(lp);
        return b;
    }

    private static EditText makeInput(
            Context context, String initial, String hint, boolean multiline) {
        EditText et = new EditText(context);
        et.setText(initial);
        et.setHint(hint);
        et.setTextColor(TvV17Theme.TEXT);
        et.setHintTextColor(TvV17Theme.MUTED);
        et.setFocusable(true);
        if (multiline) {
            et.setInputType(
                    InputType.TYPE_CLASS_TEXT
                            | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                            | InputType.TYPE_TEXT_VARIATION_URI);
            et.setMinLines(2);
            et.setMaxLines(4);
        } else {
            et.setSingleLine(true);
        }
        return et;
    }
}

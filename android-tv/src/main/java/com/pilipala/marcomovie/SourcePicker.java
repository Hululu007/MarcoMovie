package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.view.*;
import android.widget.*;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

/** The source chooser stays above the current screen and never creates a second navigation page. */
final class SourcePicker {
    static final String DEFAULT_GROUP = "默认分组";

    private static String profile(String origin) {
        return "source-picker:" + (origin == null ? "" : origin);
    }

    static String siteGroup(Cms.Site site) {
        if (site == null || site.group == null || site.group.trim().isEmpty()) {
            return DEFAULT_GROUP;
        }
        return site.group.trim();
    }

    static void applySiteOverride(Cms.Site site, org.json.JSONObject ov) {
        if (site == null || ov == null) return;
        if (ov.has("name")) {
            String n = ov.optString("name", "").trim();
            if (!n.isEmpty()) site.name = n;
        }
        if (ov.has("group")) {
            String g = ov.optString("group", "").trim();
            if (!g.isEmpty()) site.group = g;
        }
        if (ov.has("api")) {
            String nextApi = ov.optString("api", "").trim();
            if (!nextApi.isEmpty()) {
                site.api = nextApi;
                String lower = nextApi.toLowerCase(java.util.Locale.ROOT);
                if ((lower.startsWith("http://") || lower.startsWith("https://"))
                        && !lower.endsWith(".js")
                        && !lower.endsWith(".mjs")
                        && !lower.endsWith(".py")
                        && !lower.endsWith(".jar")
                        && site.type != 0
                        && site.type != 1
                        && site.type != 4) {
                    site.type = lower.contains("xml") ? 0 : 1;
                }
            }
        }
        if (ov.has("playUrl")) {
            site.playUrl = ov.optString("playUrl", "").trim();
            site.requiresParser = !site.playUrl.isEmpty();
        }
        if (ov.has("ext")) {
            String extStr = ov.optString("ext", "");
            String trimmed = extStr.trim();
            if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
                try {
                    site.ext = new org.json.JSONObject(trimmed);
                } catch (org.json.JSONException ignored) {
                    site.ext = extStr;
                }
            } else {
                site.ext = extStr;
            }
            site.extTooLarge = extStr.length() > Cms.Site.MAX_EXT_SIZE;
        }
        if (ov.has("searchable")) {
            site.searchable = ov.optBoolean("searchable", site.searchable);
        }
    }

    static void applyEditsToConfig(Cms.Config config, org.json.JSONObject saved) {
        if (config == null || saved == null) return;
        org.json.JSONObject overrides = saved.optJSONObject("overrides");
        org.json.JSONArray order = saved.optJSONArray("order"),
                removed = saved.optJSONArray("removed");
        java.util.Map<String, Cms.Site> byKey = new java.util.LinkedHashMap<>();
        for (Cms.Site site : config.sites) {
            String id = site.siteId();
            if (overrides != null) {
                org.json.JSONObject ov = overrides.optJSONObject(id);
                if (ov == null && !id.equals(site.key)) ov = overrides.optJSONObject(site.key);
                if (ov != null) applySiteOverride(site, ov);
            }
            byKey.put(id, site);
        }
        if (removed != null) {
            for (int i = 0; i < removed.length(); i++) {
                byKey.remove(removed.optString(i));
            }
        }
        config.sites.clear();
        if (order != null) {
            for (int i = 0; i < order.length(); i++) {
                Cms.Site site = byKey.remove(order.optString(i));
                if (site != null) config.sites.add(site);
            }
        }
        config.sites.addAll(byKey.values());
    }

    static void applyEdits(MainActivity a, Cms.Config config, String origin) {
        String legacyProfile = profile(origin);
        if (!config.origin.isEmpty()) origin = config.origin;
        String currentProfile = profile(origin);
        if (!currentProfile.equals(legacyProfile)
                && !a.prefs.contains(currentProfile)
                && a.prefs.contains(legacyProfile)) {
            String old = a.prefs.getString(legacyProfile, "{}");
            a.prefs.edit().putString(currentProfile, old).remove(legacyProfile).apply();
        }
        try {
            org.json.JSONObject saved =
                    new org.json.JSONObject(a.prefs.getString(currentProfile, "{}"));
            applyEditsToConfig(config, saved);
        } catch (org.json.JSONException ignored) {
            /* Keep the imported order. */
        }
    }

    private static String activeProfileKey(MainActivity a, Cms.Config config) {
        String origin =
                (config != null && !config.origin.isEmpty()) ? config.origin : a.configOrigin;
        return profile(origin);
    }

    private static org.json.JSONObject loadSavedProfile(MainActivity a, Cms.Config config) {
        try {
            return new org.json.JSONObject(a.prefs.getString(activeProfileKey(a, config), "{}"));
        } catch (org.json.JSONException ignored) {
            return new org.json.JSONObject();
        }
    }

    private static boolean hasSiteOverride(MainActivity a, Cms.Config config, Cms.Site site) {
        org.json.JSONObject overrides = loadSavedProfile(a, config).optJSONObject("overrides");
        return overrides != null && (overrides.has(site.siteId()) || overrides.has(site.key));
    }

    private static java.util.List<String> collectGroups(Cms.Config config, boolean includePresets) {
        java.util.List<String> groups = new java.util.ArrayList<>();
        groups.add(DEFAULT_GROUP);
        if (config != null) {
            for (Cms.Site s : config.sites) {
                String g = siteGroup(s);
                if (!groups.contains(g)) groups.add(g);
            }
        }
        if (includePresets) {
            for (String preset : new String[] {"常用秒播", "4K网盘", "备用线路"}) {
                if (!groups.contains(preset)) groups.add(preset);
            }
        }
        return groups;
    }

    private static void reloadAndReopen(MainActivity a, Cms.Config config, String reopenGroup) {
        String origin =
                (config != null && !config.origin.isEmpty()) ? config.origin : a.configOrigin;
        if (config != null && config.raw != null && !config.raw.isEmpty()) {
            try {
                Cms.Config fresh = Cms.parseConfig(config.raw, origin);
                applyEdits(a, fresh, origin);
                a.closeEngines();
                a.config = fresh;
                ensureValidSelectedSite(a, fresh);
                a.back.clear();
                a.open(new MainActivity.Screen(a::home), false);
                if (reopenGroup != null) show(a, reopenGroup);
                return;
            } catch (Exception ignored) {
            }
        }
        a.closeEngines();
        if (a.config != null) ensureValidSelectedSite(a, a.config);
        a.back.clear();
        a.open(new MainActivity.Screen(a::home), false);
        if (reopenGroup != null) show(a, reopenGroup);
    }

    private static void ensureValidSelectedSite(MainActivity a, Cms.Config cfg) {
        String sel = a.prefs.getString(Prefs.SELECTED_SITE, "");
        for (Cms.Site s : cfg.sites) {
            if (s.key.equals(sel) && a.available(s)) return;
        }
        android.content.SharedPreferences.Editor ed = a.prefs.edit().remove(Prefs.SELECTED_SITE);
        for (Cms.Site s : cfg.sites) {
            if (a.available(s)) {
                ed.putString(Prefs.SELECTED_SITE, s.key);
                break;
            }
        }
        ed.apply();
    }

    static void manage(MainActivity a) {
        Cms.Config config = a.config;
        if (config == null) {
            a.notice("暂无可管理的线路");
            return;
        }
        org.json.JSONObject saved = loadSavedProfile(a, config);
        org.json.JSONArray removedArr = saved.optJSONArray("removed");
        final int removedCount = removedArr != null ? removedArr.length() : 0;
        if (config.sites.isEmpty() && removedCount == 0) {
            a.notice("暂无可管理的线路");
            return;
        }
        java.util.List<String> labels = new java.util.ArrayList<>();
        final int actionBatchGroup = config.sites.isEmpty() ? -1 : labels.size();
        if (!config.sites.isEmpty()) labels.add("▸ 批量移动线路到分组…");
        final int actionBatchDelete = config.sites.isEmpty() ? -1 : labels.size();
        if (!config.sites.isEmpty()) labels.add("▸ 批量删除多条线路…");
        final int actionRestore = removedCount > 0 ? labels.size() : -1;
        if (removedCount > 0) labels.add("↺ 恢复已删除的线路（" + removedCount + " 条）");
        final int headerCount = labels.size();
        for (int i = 0; i < config.sites.size(); i++) {
            Cms.Site s = config.sites.get(i);
            labels.add("[" + siteGroup(s) + "] " + s.name);
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("管理线路")
                .setItems(
                        labels.toArray(new String[0]),
                        (d, index) -> {
                            if (index == actionBatchGroup) {
                                showBatchGroupDialog(a, config);
                            } else if (index == actionBatchDelete) {
                                showBatchDeleteDialog(a, config);
                            } else if (index == actionRestore) {
                                showRestoreRemovedDialog(a, config);
                            } else if (index >= headerCount) {
                                Cms.Site site = config.sites.get(index - headerCount);
                                showSiteActionMenu(a, config, site, null);
                            }
                        })
                .setNegativeButton("返回", (d, w) -> show(a))
                .show();
    }

    private static void showSiteActionMenu(
            MainActivity a, Cms.Config config, Cms.Site site, String returnGroup) {
        if (a.config != config) return;
        int index = config.sites.indexOf(site);
        boolean avail = a.available(site);
        boolean isPref = avail && SourcePreferences.isPreferred(a, site);
        boolean overridden = hasSiteOverride(a, config, site);
        java.util.List<String> items = new java.util.ArrayList<>();
        java.util.List<String> codes = new java.util.ArrayList<>();
        items.add("修改分组（当前：" + siteGroup(site) + "）");
        codes.add("group");
        items.add("编辑线路信息");
        codes.add("edit");
        if (avail) {
            items.add(isPref ? "取消默认偏好源" : "设为默认偏好源");
            codes.add("pref");
        }
        if (overridden) {
            items.add("恢复原始配置");
            codes.add("reset");
        }
        if (index >= 0) {
            items.add("移到首位");
            codes.add("top");
            items.add("上移");
            codes.add("up");
            items.add("下移");
            codes.add("down");
        }
        items.add("删除这条线路");
        codes.add("delete");

        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle(site.name)
                .setItems(
                        items.toArray(new String[0]),
                        (action, choice) -> {
                            String code = codes.get(choice);
                            if ("group".equals(code)) {
                                showGroupPickerDialog(
                                        a,
                                        config,
                                        java.util.Collections.singletonList(site),
                                        returnGroup);
                            } else if ("edit".equals(code)) {
                                showEditSiteDialog(a, config, site, returnGroup);
                            } else if ("pref".equals(code)) {
                                a.prefs
                                        .edit()
                                        .putString(
                                                Prefs.PREFERRED_SITE,
                                                isPref ? "" : SourcePreferences.identity(site))
                                        .apply();
                                a.toast(isPref ? "已取消默认偏好源" : "已设为默认偏好源");
                                if (returnGroup != null) show(a, returnGroup);
                                else manage(a);
                            } else if ("reset".equals(code)) {
                                clearSiteOverride(a, config, site, returnGroup);
                            } else if ("top".equals(code)) {
                                edit(a, config, site, 0, returnGroup);
                            } else if ("up".equals(code)) {
                                edit(a, config, site, Math.max(0, index - 1), returnGroup);
                            } else if ("down".equals(code)) {
                                edit(
                                        a,
                                        config,
                                        site,
                                        Math.min(config.sites.size() - 1, index + 1),
                                        returnGroup);
                            } else if ("delete".equals(code)) {
                                new AppDialog.Builder(a)
                                        .wrapChoices()
                                        .setTitle("删除「" + site.name + "」？")
                                        .setMessage("删除后该线路不会在刷新订阅时重现；可在「管理线路 → 恢复已删除的线路」中找回。")
                                        .setNegativeButton(
                                                "取消",
                                                (c, w) -> {
                                                    if (returnGroup != null) show(a, returnGroup);
                                                    else manage(a);
                                                })
                                        .setPositiveButton(
                                                "删除",
                                                (ok, which) ->
                                                        edit(a, config, site, -1, returnGroup))
                                        .show();
                            }
                        })
                .setNegativeButton(
                        "返回",
                        (d, w) -> {
                            if (returnGroup != null) show(a, returnGroup);
                            else manage(a);
                        })
                .show();
    }

    private static void showGroupPickerDialog(
            MainActivity a,
            Cms.Config config,
            java.util.List<Cms.Site> targetSites,
            String returnGroup) {
        if (targetSites == null || targetSites.isEmpty()) return;
        java.util.List<String> groups = collectGroups(config, true);
        String[] labels = new String[groups.size() + 1];
        for (int i = 0; i < groups.size(); i++) labels[i] = groups.get(i);
        labels[groups.size()] = "+ 新建自定义分组…";
        String title =
                targetSites.size() == 1
                        ? "修改分组 · " + targetSites.get(0).name
                        : "批量移动 " + targetSites.size() + " 条线路到分组";
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle(title)
                .setItems(
                        labels,
                        (d, idx) -> {
                            if (idx < groups.size()) {
                                saveBatchGroupOverride(
                                        a, config, targetSites, groups.get(idx), returnGroup);
                            } else {
                                showCustomGroupInputDialog(a, config, targetSites, returnGroup);
                            }
                        })
                .setNegativeButton(
                        "取消",
                        (d, w) -> {
                            if (returnGroup != null) show(a, returnGroup);
                            else manage(a);
                        })
                .show();
    }

    private static void showCustomGroupInputDialog(
            MainActivity a,
            Cms.Config config,
            java.util.List<Cms.Site> targetSites,
            String returnGroup) {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(18), a.dp(10), a.dp(18), a.dp(6));
        EditText input = new EditText(a);
        input.setSingleLine(true);
        input.setHint("输入新分组名称（如：主力秒播）");
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0xff8e8e93);
        input.setBackground(a.bg(0x33ffffff, 10));
        input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        box.addView(TvQrInputHelper.wrap(a, input, "新分组名称"), new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("新建分组")
                .setView(box)
                .setNegativeButton(
                        "取消", (d, w) -> showGroupPickerDialog(a, config, targetSites, returnGroup))
                .setPositiveButton(
                        "确定",
                        (d, w) -> {
                            String g = input.getText().toString().trim();
                            if (g.isEmpty()) {
                                a.notice("分组名称不能为空");
                                return;
                            }
                            saveBatchGroupOverride(a, config, targetSites, g, returnGroup);
                        })
                .show();
    }

    private static void saveBatchGroupOverride(
            MainActivity a,
            Cms.Config config,
            java.util.List<Cms.Site> targetSites,
            String newGroup,
            String returnGroup) {
        if (a.config != config) return;
        String clean = newGroup == null ? "" : newGroup.trim();
        if (clean.isEmpty()) return;
        try {
            String key = activeProfileKey(a, config);
            org.json.JSONObject saved = loadSavedProfile(a, config);
            org.json.JSONObject overrides = saved.optJSONObject("overrides");
            if (overrides == null) overrides = new org.json.JSONObject();
            for (Cms.Site s : targetSites) {
                String id = s.siteId();
                org.json.JSONObject ov = overrides.optJSONObject(id);
                if (ov == null) ov = new org.json.JSONObject();
                ov.put("group", clean);
                overrides.put(id, ov);
                s.group = clean;
            }
            saved.put("overrides", overrides);
            a.prefs.edit().putString(key, saved.toString()).apply();
            a.toast("已移至分组：" + clean);
            if (returnGroup != null) show(a, clean);
            else manage(a);
        } catch (org.json.JSONException e) {
            a.notice("分组未能保存");
        }
    }

    private static void clearSiteOverride(
            MainActivity a, Cms.Config config, Cms.Site site, String returnGroup) {
        if (a.config != config) return;
        String key = activeProfileKey(a, config);
        org.json.JSONObject saved = loadSavedProfile(a, config);
        org.json.JSONObject overrides = saved.optJSONObject("overrides");
        if (overrides != null) {
            overrides.remove(site.siteId());
            overrides.remove(site.key);
        }
        a.prefs.edit().putString(key, saved.toString()).apply();
        a.toast("已恢复原始线路配置");
        reloadAndReopen(a, config, returnGroup != null ? returnGroup : "全部");
    }

    private static void showEditSiteDialog(
            MainActivity a, Cms.Config config, Cms.Site site, String returnGroup) {
        if (a.config != config) return;
        ScrollView scroll = new TvScrollView(a);
        LinearLayout form = a.vertical();
        form.setPadding(a.dp(18), a.dp(8), a.dp(18), a.dp(8));
        scroll.addView(form);

        EditText nameInput = addLabeledInput(a, form, "线路名称", site.name, "输入线路显示名称");
        EditText groupInput = addLabeledInput(a, form, "所属分组", siteGroup(site), DEFAULT_GROUP);
        HorizontalScrollView grpScroll = new HorizontalScrollView(a);
        grpScroll.setHorizontalScrollBarEnabled(false);
        LinearLayout grpRow = a.row();
        grpScroll.addView(grpRow);
        for (String g : collectGroups(config, true)) {
            Button chip =
                    a.button(
                            g,
                            null,
                            () -> {
                                groupInput.setText(g);
                                groupInput.setSelection(g.length());
                            });
            chip.setTextSize(11.5f);
            chip.setPadding(a.dp(10), a.dp(2), a.dp(10), a.dp(2));
            chip.setMinHeight(a.dp(28));
            chip.setMinimumHeight(a.dp(28));
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, a.dp(28));
            clp.setMargins(0, a.dp(4), a.dp(6), a.dp(4));
            grpRow.addView(chip, clp);
        }
        form.addView(grpScroll, new LinearLayout.LayoutParams(-1, -2));

        EditText apiInput =
                addLabeledInput(a, form, "接口地址 / Spider API", site.api, "https://… 或 csp_…");
        EditText playUrlInput =
                addLabeledInput(
                        a,
                        form,
                        "解析地址 PlayUrl（可选）",
                        site.playUrl == null ? "" : site.playUrl,
                        "留空使用直连或全局解析");
        String extInitial = site.ext == null ? "" : String.valueOf(site.ext);
        EditText extInput =
                addLabeledInput(a, form, "扩展参数 Ext（可选）", extInitial, "自定义扩展参数或规则地址", true);

        CheckBox searchableCheck = new CheckBox(a);
        searchableCheck.setText("允许参与全站聚合搜索");
        searchableCheck.setTextColor(Color.WHITE);
        searchableCheck.setChecked(site.searchable);
        LinearLayout.LayoutParams chkLp = new LinearLayout.LayoutParams(-1, -2);
        chkLp.topMargin = a.dp(8);
        form.addView(searchableCheck, chkLp);

        AppDialog.Builder builder =
                new AppDialog.Builder(a)
                        .setTitle("编辑线路 · " + site.name)
                        .setView(scroll)
                        .setOnCancelListener(
                                d -> {
                                    if (returnGroup != null) show(a, returnGroup);
                                    else manage(a);
                                })
                        .setNegativeButton(
                                "取消",
                                (d, w) -> {
                                    if (returnGroup != null) show(a, returnGroup);
                                    else manage(a);
                                })
                        .setPositiveButton(
                                "保存修改",
                                (d, w) -> {
                                    String newName = nameInput.getText().toString().trim();
                                    String newGroup = groupInput.getText().toString().trim();
                                    if (newGroup.isEmpty()) newGroup = DEFAULT_GROUP;
                                    String newApi = apiInput.getText().toString().trim();
                                    String newPlayUrl = playUrlInput.getText().toString().trim();
                                    String newExt = extInput.getText().toString();
                                    boolean newSearchable = searchableCheck.isChecked();
                                    if (newName.isEmpty() || newApi.isEmpty()) {
                                        a.notice("线路名称与接口地址不能为空");
                                        return;
                                    }
                                    try {
                                        String key = activeProfileKey(a, config);
                                        org.json.JSONObject saved = loadSavedProfile(a, config);
                                        org.json.JSONObject overrides =
                                                saved.optJSONObject("overrides");
                                        if (overrides == null)
                                            overrides = new org.json.JSONObject();
                                        org.json.JSONObject ov = new org.json.JSONObject();
                                        ov.put("name", newName);
                                        ov.put("group", newGroup);
                                        ov.put("api", newApi);
                                        ov.put("playUrl", newPlayUrl);
                                        ov.put("ext", newExt);
                                        ov.put("searchable", newSearchable);
                                        overrides.put(site.siteId(), ov);
                                        saved.put("overrides", overrides);
                                        a.prefs.edit().putString(key, saved.toString()).apply();
                                        applySiteOverride(site, ov);
                                        synchronized (a) {
                                            SourceEngine old = a.engines.remove(site.key);
                                            if (old != null) {
                                                a.worker.execute(
                                                        () -> {
                                                            try {
                                                                old.close();
                                                            } catch (Exception ignored) {
                                                            }
                                                        });
                                            }
                                        }
                                        a.toast("已保存线路修改");
                                        reloadAndReopen(
                                                a,
                                                config,
                                                returnGroup != null ? returnGroup : null);
                                        if (returnGroup == null) manage(a);
                                    } catch (org.json.JSONException e) {
                                        a.notice("无法保存线路修改");
                                    }
                                });
        if (hasSiteOverride(a, config, site)) {
            builder.setNeutralButton(
                    "恢复原始", (d, w) -> clearSiteOverride(a, config, site, returnGroup));
        }
        builder.show();
    }

    private static EditText addLabeledInput(
            MainActivity a, LinearLayout parent, String label, String value, String hint) {
        return addLabeledInput(a, parent, label, value, hint, false);
    }

    private static EditText addLabeledInput(
            MainActivity a,
            LinearLayout parent,
            String label,
            String value,
            String hint,
            boolean multiline) {
        TextView tv = a.text(label, 12, MainActivity.MUTED);
        tv.setPadding(0, a.dp(8), 0, a.dp(4));
        parent.addView(tv);
        EditText input = new EditText(a);
        if (multiline) {
            input.setSingleLine(false);
            input.setMaxLines(3);
        } else {
            input.setSingleLine(true);
        }
        input.setText(value == null ? "" : value);
        input.setHint(hint);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0xff8e8e93);
        input.setTextSize(13.5f);
        input.setBackground(a.bg(0x2effffff, 10));
        input.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        parent.addView(
                TvQrInputHelper.wrap(a, input, label, multiline, false, false, null),
                new LinearLayout.LayoutParams(-1, -2));
        return input;
    }

    private static View buildMultiSelectListView(
            MainActivity a, String[] labels, boolean[] checked) {
        LinearLayout listBox = a.vertical();
        Button[] rowButtons = new Button[labels.length];
        LinearLayout quickOps = new LinearLayout(a);
        quickOps.setOrientation(LinearLayout.HORIZONTAL);
        Button selectAll =
                a.button(
                        "全选",
                        "batch-select-all",
                        () -> {
                            for (int i = 0; i < checked.length; i++) {
                                checked[i] = true;
                                if (rowButtons[i] != null) {
                                    rowButtons[i].setText("☑  " + labels[i]);
                                }
                            }
                        });
        Button clearAll =
                a.button(
                        "清空",
                        "batch-clear-all",
                        () -> {
                            for (int i = 0; i < checked.length; i++) {
                                checked[i] = false;
                                if (rowButtons[i] != null) {
                                    rowButtons[i].setText("☐  " + labels[i]);
                                }
                            }
                        });
        LinearLayout.LayoutParams qlp1 = new LinearLayout.LayoutParams(0, a.dp(38), 1f);
        qlp1.rightMargin = a.dp(8);
        quickOps.addView(selectAll, qlp1);
        quickOps.addView(clearAll, new LinearLayout.LayoutParams(0, a.dp(38), 1f));
        listBox.addView(quickOps, new LinearLayout.LayoutParams(-1, -2));
        a.gap(listBox, 8);
        for (int i = 0; i < labels.length; i++) {
            final int idx = i;
            final Button itemBtn =
                    a.button(
                            (checked[idx] ? "☑  " : "☐  ") + labels[idx],
                            "batch-option:" + idx,
                            null);
            itemBtn.setOnClickListener(
                    v -> {
                        checked[idx] = !checked[idx];
                        itemBtn.setText((checked[idx] ? "☑  " : "☐  ") + labels[idx]);
                    });
            itemBtn.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);
            itemBtn.setPadding(a.dp(14), a.dp(8), a.dp(14), a.dp(8));
            itemBtn.setTextSize(14f);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, a.dp(44));
            lp.bottomMargin = a.dp(6);
            rowButtons[idx] = itemBtn;
            listBox.addView(itemBtn, lp);
        }
        return listBox;
    }

    private static void showBatchGroupDialog(MainActivity a, Cms.Config config) {
        showBatchGroupDialog(a, config, null);
    }

    private static void showBatchGroupDialog(
            MainActivity a, Cms.Config config, String returnGroup) {
        if (config.sites.isEmpty()) return;
        String[] labels = new String[config.sites.size()];
        final boolean[] checked = new boolean[config.sites.size()];
        for (int i = 0; i < config.sites.size(); i++) {
            Cms.Site s = config.sites.get(i);
            labels[i] = "[" + siteGroup(s) + "] " + s.name;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要分组的线路")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton(
                        "取消",
                        (d, w) -> {
                            if (returnGroup != null) show(a, returnGroup);
                            else manage(a);
                        })
                .setPositiveButton(
                        "选择分组",
                        (d, w) -> {
                            java.util.List<Cms.Site> chosen = new java.util.ArrayList<>();
                            for (int i = 0; i < checked.length; i++) {
                                if (checked[i]) chosen.add(config.sites.get(i));
                            }
                            if (chosen.isEmpty()) {
                                a.notice("请至少勾选一条线路");
                                return;
                            }
                            showGroupPickerDialog(a, config, chosen, returnGroup);
                        })
                .show();
    }

    private static void showBatchDeleteDialog(MainActivity a, Cms.Config config) {
        if (config.sites.isEmpty()) return;
        String[] labels = new String[config.sites.size()];
        final boolean[] checked = new boolean[config.sites.size()];
        for (int i = 0; i < config.sites.size(); i++) {
            Cms.Site s = config.sites.get(i);
            labels[i] = "[" + siteGroup(s) + "] " + s.name;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要删除的线路")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton("取消", (d, w) -> manage(a))
                .setPositiveButton(
                        "删除所选",
                        (d, w) -> {
                            java.util.List<Cms.Site> chosen = new java.util.ArrayList<>();
                            for (int i = 0; i < checked.length; i++) {
                                if (checked[i]) chosen.add(config.sites.get(i));
                            }
                            if (chosen.isEmpty()) {
                                a.notice("请至少勾选一条线路");
                                return;
                            }
                            removeSitesBatch(a, config, chosen);
                        })
                .show();
    }

    private static void removeSitesBatch(
            MainActivity a, Cms.Config config, java.util.List<Cms.Site> toRemove) {
        if (a.config != config || toRemove.isEmpty()) return;
        try {
            String key = activeProfileKey(a, config);
            org.json.JSONObject saved = loadSavedProfile(a, config);
            org.json.JSONArray hidden = saved.optJSONArray("removed");
            if (hidden == null) hidden = new org.json.JSONArray();
            java.util.Set<String> hiddenSet = new java.util.LinkedHashSet<>();
            for (int i = 0; i < hidden.length(); i++) hiddenSet.add(hidden.optString(i));
            GlobalSearchScreen.invalidateContext(a);
            for (Cms.Site s : toRemove) {
                hiddenSet.add(s.siteId());
                config.sites.remove(s);
            }
            org.json.JSONArray nextHidden = new org.json.JSONArray();
            for (String id : hiddenSet) nextHidden.put(id);
            saved.put("removed", nextHidden);
            org.json.JSONArray order = new org.json.JSONArray();
            for (Cms.Site s : config.sites) order.put(s.siteId());
            saved.put("order", order);
            a.prefs.edit().putString(key, saved.toString()).apply();
            ensureValidSelectedSite(a, config);
            a.back.clear();
            a.open(new MainActivity.Screen(a::home), false);
            a.toast("已删除 " + toRemove.size() + " 条线路");
            manage(a);
        } catch (org.json.JSONException e) {
            a.notice("无法保存删除操作");
        }
    }

    private static void showRestoreRemovedDialog(MainActivity a, Cms.Config config) {
        org.json.JSONObject saved = loadSavedProfile(a, config);
        org.json.JSONArray removed = saved.optJSONArray("removed");
        if (removed == null || removed.length() == 0) {
            a.notice("没有已删除的线路");
            return;
        }
        java.util.Map<String, String> nameById = new java.util.LinkedHashMap<>();
        if (config.raw != null && !config.raw.isEmpty()) {
            try {
                String origin = !config.origin.isEmpty() ? config.origin : a.configOrigin;
                Cms.Config rawParsed = Cms.parseConfig(config.raw, origin);
                for (Cms.Site s : rawParsed.sites) nameById.put(s.siteId(), s.name);
            } catch (Exception ignored) {
            }
        }
        final java.util.List<String> ids = new java.util.ArrayList<>();
        for (int i = 0; i < removed.length(); i++) {
            String id = removed.optString(i);
            if (!id.isEmpty()) ids.add(id);
        }
        String[] labels = new String[ids.size() + 1];
        labels[0] = "↺ 全部恢复（共 " + ids.size() + " 条）";
        for (int i = 0; i < ids.size(); i++) {
            String id = ids.get(i);
            String title = nameById.containsKey(id) ? nameById.get(id) : id;
            labels[i + 1] = "恢复 · " + title;
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("恢复已删除的线路")
                .setItems(
                        labels,
                        (d, idx) -> {
                            String key = activeProfileKey(a, config);
                            if (idx == 0) {
                                saved.remove("removed");
                            } else {
                                String restoreId = ids.get(idx - 1);
                                org.json.JSONArray next = new org.json.JSONArray();
                                for (String id : ids) {
                                    if (!id.equals(restoreId)) next.put(id);
                                }
                                try {
                                    saved.put("removed", next);
                                } catch (org.json.JSONException ignored) {
                                }
                            }
                            a.prefs.edit().putString(key, saved.toString()).apply();
                            a.toast("已恢复线路");
                            reloadAndReopen(a, config, "全部");
                        })
                .setNegativeButton("返回", (d, w) -> manage(a))
                .show();
    }

    private static void edit(
            MainActivity a, Cms.Config config, Cms.Site site, int target, String reopenGroup) {
        if (a.config != config) return;
        try {
            String key = activeProfileKey(a, config);
            org.json.JSONObject saved = loadSavedProfile(a, config);
            java.util.List<Cms.Site> sites = new java.util.ArrayList<>(config.sites);
            sites.remove(site);
            if (target >= 0) sites.add(target, site);
            else {
                org.json.JSONArray hidden = saved.optJSONArray("removed");
                if (hidden == null) hidden = new org.json.JSONArray();
                saved.put("removed", hidden.put(site.siteId()));
            }
            org.json.JSONArray order = new org.json.JSONArray();
            for (Cms.Site s : sites) order.put(s.siteId());
            saved.put("order", order);
            android.content.SharedPreferences.Editor editor =
                    a.prefs.edit().putString(key, saved.toString());
            if (target < 0 && site.key.equals(a.prefs.getString(Prefs.SELECTED_SITE, ""))) {
                editor.remove(Prefs.SELECTED_SITE);
                for (Cms.Site s : sites)
                    if (a.available(s)) {
                        editor.putString(Prefs.SELECTED_SITE, s.key);
                        break;
                    }
            }
            editor.apply();
            GlobalSearchScreen.invalidateContext(a);
            config.sites.clear();
            config.sites.addAll(sites);
            a.back.clear();
            a.open(new MainActivity.Screen(a::home), false);
            if (reopenGroup != null) show(a, reopenGroup);
            else manage(a);
        } catch (org.json.JSONException e) {
            a.notice("无法保存线路顺序");
        }
    }

    private static void commitSelectedSiteForCrashGuard(MainActivity a, String siteKey) {
        if (a == null || a.prefs == null) return;
        a.prefs
                .edit()
                .putString(Prefs.SELECTED_SITE, siteKey)
                .putString(Prefs.LOADING_SITE, siteKey)
                .commit();
    }

    private static final java.util.concurrent.ExecutorService SITE_PERSIST_EXECUTOR =
            java.util.concurrent.Executors.newSingleThreadExecutor(
                    r -> {
                        Thread t = new Thread(r, "tv-site-persist");
                        t.setDaemon(true);
                        return t;
                    });
    private static final java.util.concurrent.atomic.AtomicLong SITE_PERSIST_SEQ =
            new java.util.concurrent.atomic.AtomicLong(0L);

    private static void saveSelectedSiteOnly(MainActivity a, String siteKey) {
        if (a == null || a.prefs == null) return;
        String clean = siteKey == null ? "" : siteKey;
        a.prefs.edit().putString(Prefs.SELECTED_SITE, clean).apply();
        if (a.multiSourceStore != null && a.multiSourceStore.readState().initialized) {
            final TvMultiSourceStore store = a.multiSourceStore;
            SITE_PERSIST_EXECUTOR.execute(
                    () -> {
                        try {
                            String raw = TvMultiSourceStore.extractRawKeyFromStable(clean);
                            String shortId = TvMultiSourceStore.extractShortSubIdFromStable(clean);
                            String subId = "";
                            for (TvMultiSourceStore.SubscriptionRecord r :
                                    store.readState().subscriptions) {
                                if (TvMultiSourceStore.stableShortId(r.id).equals(shortId)) {
                                    subId = r.id;
                                    break;
                                }
                            }
                            store.setCurrentSite(clean, subId, raw);
                        } catch (Throwable ignored) {
                        }
                    });
        }
    }

    static final int TAB_LINES = 0;
    static final int TAB_SUBSCRIPTIONS = 1;

    static void show(MainActivity a) {
        show(a, "全部");
    }

    static void show(MainActivity a, String requestedGroup) {
        a.markUserInteraction();
        if (a.hasZeroEnabledSubscriptions()) {
            showUnified(a, requestedGroup, TAB_SUBSCRIPTIONS, captureFreshOrigin(a));
            return;
        }
        if (a.config == null) {
            if (a.isTvDevice() && a.configStore != null && !a.privateMode) {
                showManageSubscriptions(a);
                return;
            }
            a.importDialog();
            return;
        }
        showUnified(a, requestedGroup, TAB_LINES, captureFreshOrigin(a));
    }

    static void showManageSubscriptions(MainActivity a) {
        if (a == null) return;
        showUnified(a, "全部", TAB_SUBSCRIPTIONS, captureFreshOrigin(a));
    }

    static void showSavedConfigs(MainActivity a) {
        if (a == null) return;
        if (a.isTvDevice() && a.configStore != null && !a.privateMode) {
            showUnified(a, "全部", TAB_SUBSCRIPTIONS, captureFreshOrigin(a));
            return;
        }
        showLegacySavedConfigs(a);
    }

    static final class Origin {
        final MainActivity.Screen screen;
        final int homeGeneration;
        final boolean fromRetainedHome;
        final String returnFocusTag;
        final java.lang.ref.WeakReference<View> triggerViewRef;
        final int sourceRelTopPx;
        final int scrollY;

        Origin(
                MainActivity.Screen screen,
                int homeGeneration,
                boolean fromRetainedHome,
                String returnFocusTag,
                View triggerView,
                int sourceRelTopPx,
                int scrollY) {
            this.screen = screen;
            this.homeGeneration = homeGeneration;
            this.fromRetainedHome = fromRetainedHome;
            this.returnFocusTag = returnFocusTag;
            this.triggerViewRef =
                    triggerView == null ? null : new java.lang.ref.WeakReference<>(triggerView);
            this.sourceRelTopPx = sourceRelTopPx;
            this.scrollY = Math.max(0, scrollY);
        }

        boolean matches(MainActivity a) {
            return a != null && a.current == screen && a.generation == homeGeneration;
        }

        void restoreFocus(MainActivity a) {
            if (a == null || a.isFinishing()) return;
            View target = triggerViewRef == null ? null : triggerViewRef.get();
            if (target != null
                    && target.isAttachedToWindow()
                    && target.isShown()
                    && target.isFocusable()) {
                target.requestFocus();
                return;
            }
            if (returnFocusTag != null && a.root != null) {
                View byTag = MainActivity.findVisibleFocusableByTag(a.root, returnFocusTag);
                if (byTag != null) {
                    byTag.requestFocus();
                    return;
                }
            }
            if (fromRetainedHome && a.root != null) {
                View sw = MainActivity.findVisibleFocusableByTag(a.root, "source-switcher");
                if (sw != null) sw.requestFocus();
            }
        }
    }

    /** Always captures a fresh top-level entry origin so later opens never reuse stale scroll Y. */
    static Origin captureFreshOrigin(MainActivity a) {
        boolean fromRetainedHome =
                a.current != null && a.current.home && a.current.retainedHome != null;
        View trigger = a.getCurrentFocus();
        String focusTag =
                trigger != null && trigger.getTag() instanceof String
                        ? (String) trigger.getTag()
                        : (fromRetainedHome ? "source-switcher" : null);
        int relTop = 0;
        if (fromRetainedHome && a.current.retainedHome.source != null) {
            relTop = a.current.retainedHome.measureAnchorRelTopPx(a.current.retainedHome.source);
        }
        int scrollY = a.scroll != null ? a.scroll.getScrollY() : 0;
        Origin origin =
                new Origin(
                        a.current,
                        a.generation,
                        fromRetainedHome,
                        focusTag,
                        trigger,
                        relTop,
                        scrollY);
        a.activePickerOrigin = origin;
        return origin;
    }

    static int computePickerColumns(int innerWidthPx, float density, float fontScale, boolean tv) {
        float safeD = Math.max(0.5f, density);
        float safeF = Math.max(1.0f, fontScale);
        float innerDp = innerWidthPx / safeD;
        if (tv) {
            return innerDp >= (560f * safeF) ? 2 : 1;
        }
        return (innerDp >= (360f * safeF) && safeF <= 1.25f) ? 2 : 1;
    }

    static int computeFooterColumns(
            int innerWidthPx, int maxButtonNeededPx, int gapPx, int buttonCount) {
        int count = Math.max(1, buttonCount);
        int need = Math.max(1, maxButtonNeededPx);
        int gap = Math.max(0, gapPx);
        if (count <= 1) return 1;
        if (count * need + (count - 1) * gap <= innerWidthPx) return count;
        if (count >= 2 && (2 * need + gap) <= innerWidthPx) return 2;
        return 1;
    }

    static String formatSiteSubtitle(
            String group,
            boolean multiGroupAllView,
            boolean current,
            boolean preferred,
            boolean available) {
        StringBuilder sb = new StringBuilder();
        if (multiGroupAllView
                && group != null
                && !group.trim().isEmpty()
                && !DEFAULT_GROUP.equals(group.trim())) {
            sb.append(group.trim());
        }
        if (current) {
            if (sb.length() > 0) sb.append("  ·  ");
            sb.append("✓ 当前");
        }
        if (preferred) {
            if (sb.length() > 0) sb.append("  ·  ");
            sb.append("★ 常用");
        }
        if (!available) {
            if (sb.length() > 0) sb.append("  ·  ");
            sb.append("不可用");
        }
        return sb.toString();
    }

    /** Immutable precomputed snapshot of sites, groups, availability, and preferences. */
    static final class SiteRow {
        final Cms.Site site;
        final String key;
        final String name;
        final String group;
        final boolean available;
        final boolean current;
        final boolean preferred;
        final String subtitleMultiGroup;
        final String subtitleSingleGroup;
        final String previewLine;
        final long stableId;

        SiteRow(
                Cms.Site site,
                String group,
                boolean available,
                boolean current,
                boolean preferred,
                boolean showGroupSuffix) {
            this.site = site;
            this.key = site.key == null ? "" : site.key;
            this.name = site.name == null ? "" : site.name;
            this.group = group;
            this.available = available;
            this.current = current;
            this.preferred = preferred;
            this.subtitleMultiGroup =
                    formatSiteSubtitle(group, showGroupSuffix, current, preferred, available);
            this.subtitleSingleGroup =
                    formatSiteSubtitle(group, false, current, preferred, available);
            StringBuilder prev = new StringBuilder(this.name);
            if (group != null && !group.isEmpty() && !DEFAULT_GROUP.equals(group)) {
                prev.append("  ·  ").append(group);
            }
            if (current) prev.append("  ·  当前");
            if (preferred) prev.append("  ·  常用");
            if (!available) prev.append("  ·  不可用");
            this.previewLine = prev.toString();
            long h = 1125899906842597L;
            for (int i = 0; i < this.key.length(); i++) {
                h = 31L * h + this.key.charAt(i);
            }
            this.stableId = h;
        }
    }

    static final class PickerSnapshot {
        final int configHash;
        final int siteCount;
        final long multiSourceRev;
        final String selectedKey;
        final String preferredRaw;
        final int supportedCount;
        final boolean multiGroupAllView;
        final boolean anyLongSiteName;
        final java.util.List<String> filterGroups;
        final java.util.Map<String, Integer> groupCounts;
        final java.util.List<SiteRow> allRows;
        final java.util.Map<String, java.util.List<SiteRow>> rowsByGroup;

        PickerSnapshot(
                MainActivity a, Cms.Config cfg, long rev, String selectedKey, String preferredRaw) {
            this.configHash = System.identityHashCode(cfg);
            this.siteCount = cfg == null ? 0 : cfg.sites.size();
            this.multiSourceRev = rev;
            this.selectedKey = selectedKey == null ? "" : selectedKey;
            this.preferredRaw = preferredRaw == null ? "" : preferredRaw;
            java.util.List<String> groups = new java.util.ArrayList<>();
            java.util.Map<String, Integer> counts = new java.util.LinkedHashMap<>();
            java.util.Map<String, java.util.List<SiteRow>> byGrp = new java.util.LinkedHashMap<>();
            groups.add("全部");
            counts.put("全部", this.siteCount);
            if (cfg != null) {
                for (Cms.Site s : cfg.sites) {
                    if (s == null) continue;
                    String g = siteGroup(s);
                    Integer prev = counts.get(g);
                    if (prev == null) {
                        groups.add(g);
                        counts.put(g, 1);
                    } else {
                        counts.put(g, prev + 1);
                    }
                }
            }
            boolean showGroupSuffix = groups.size() > 2;
            this.multiGroupAllView = showGroupSuffix;
            java.util.List<SiteRow> all = new java.util.ArrayList<>(this.siteCount);
            int sup = 0;
            boolean hasLong = false;
            java.util.Set<String> preferredSet = parsePreferredSet(this.preferredRaw);
            if (cfg != null) {
                for (Cms.Site s : cfg.sites) {
                    if (s == null) continue;
                    String g = siteGroup(s);
                    boolean avail = a.available(s);
                    if (avail) sup++;
                    boolean cur = this.selectedKey.equals(s.key);
                    boolean pref = preferredSet.contains(s.key);
                    if (s.name != null && s.name.length() > 16) hasLong = true;
                    SiteRow row = new SiteRow(s, g, avail, cur, pref, showGroupSuffix);
                    all.add(row);
                    java.util.List<SiteRow> list = byGrp.get(g);
                    if (list == null) {
                        list = new java.util.ArrayList<>();
                        byGrp.put(g, list);
                    }
                    list.add(row);
                }
            }
            byGrp.put("全部", all);
            this.supportedCount = sup;
            this.anyLongSiteName = hasLong;
            this.filterGroups = java.util.Collections.unmodifiableList(groups);
            this.groupCounts = java.util.Collections.unmodifiableMap(counts);
            this.allRows = java.util.Collections.unmodifiableList(all);
            this.rowsByGroup = java.util.Collections.unmodifiableMap(byGrp);
        }

        boolean matches(Cms.Config cfg, long rev, String sel, String pref) {
            return System.identityHashCode(cfg) == configHash
                    && (cfg == null ? 0 : cfg.sites.size()) == siteCount
                    && rev == multiSourceRev
                    && (sel == null ? "" : sel).equals(selectedKey)
                    && (pref == null ? "" : pref).equals(preferredRaw);
        }

        java.util.List<SiteRow> rowsForGroup(String group) {
            java.util.List<SiteRow> list = rowsByGroup.get(group);
            return list != null ? list : allRows;
        }
    }

    private static volatile PickerSnapshot cachedPickerSnapshot;

    static void invalidatePickerCache() {
        cachedPickerSnapshot = null;
    }

    /** Precomputes the immutable PickerSnapshot off the UI thread so first open avoids scanning all sites. */
    static void warmSnapshotAsync(final MainActivity a) {
        if (a == null || a.config == null || !a.isTvDevice() || a.worker == null) return;
        final Cms.Config cfg = a.config;
        final long rev = a.multiSourceRevision();
        final String sel = a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
        final String pref = a.prefs != null ? a.prefs.getString(Prefs.PREFERRED_SITE, "") : "";
        PickerSnapshot existing = cachedPickerSnapshot;
        if (existing != null && existing.matches(cfg, rev, sel, pref)) return;
        a.worker.execute(
                () -> {
                    try {
                        if (a.isFinishing() || a.config != cfg) return;
                        PickerSnapshot snap = new PickerSnapshot(a, cfg, rev, sel, pref);
                        if (a.config == cfg) {
                            cachedPickerSnapshot = snap;
                        }
                    } catch (Throwable ignored) {
                    }
                });
    }

    /**
     * Pre-warms snapshot + lightweight PickerShell + pooled SiteViewHolders once Home settles so the
     * user's very first "换源" open on real TV avoids cold view-tree inflation (211ms -> ~30-45ms).
     */
    static void prewarmForHomeIdle(final MainActivity a) {
        if (a == null || !a.isTvDevice() || a.config == null) return;
        final int homeGen = a.generation;
        a.ui.postDelayed(
                () -> {
                    if (a.isFinishing()
                            || (Build.VERSION.SDK_INT >= 17 && a.isDestroyed())
                            || a.generation != homeGen
                            || a.config == null
                            || a.player != null
                            || a.sourceDialog != null
                            || a.current == null
                            || !a.current.home) {
                        return;
                    }
                    warmSnapshotAsync(a);
                    try {
                        PickerShell shell = ensureCachedShellForActivity(a);
                        if (shell != null) {
                            shell.schedulePoolPrewarm(8);
                            a.ui.postDelayed(
                                    () -> {
                                        if (a.isFinishing()
                                                || (Build.VERSION.SDK_INT >= 17 && a.isDestroyed())
                                                || a.generation != homeGen
                                                || a.config == null
                                                || a.player != null
                                                || a.sourceDialog != null
                                                || a.current == null
                                                || !a.current.home
                                                || cachedPickerShell != shell) {
                                            return;
                                        }
                                        try {
                                            shell.prebindForIdle(a);
                                        } catch (Throwable ignored) {
                                        }
                                    },
                                    180L);
                        }
                    } catch (Throwable ignored) {
                    }
                },
                2400L);
    }

    private static void applyFastTextProps(TextView tv) {
        if (tv == null) return;
        if (Build.VERSION.SDK_INT >= 23) {
            tv.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_SIMPLE);
            tv.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);
        }
    }

    private static final class GapItemDecoration extends RecyclerView.ItemDecoration {
        private final int gap;

        GapItemDecoration(int gap) {
            this.gap = gap;
        }

        @Override
        public void getItemOffsets(
                android.graphics.Rect outRect,
                View view,
                RecyclerView parent,
                RecyclerView.State state) {
            outRect.set(gap, gap, gap, gap);
        }
    }

    private static java.util.Set<String> parsePreferredSet(String raw) {
        java.util.Set<String> out = new java.util.HashSet<>();
        if (raw == null || raw.trim().isEmpty()) return out;
        for (String line : raw.split("\n")) {
            String t = line.trim();
            if (!t.isEmpty()) out.add(t);
        }
        return out;
    }

    private static PickerSnapshot obtainSnapshot(MainActivity a) {
        long rev = a.multiSourceRevision();
        String sel = a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
        String pref = a.prefs != null ? a.prefs.getString(Prefs.PREFERRED_SITE, "") : "";
        PickerSnapshot snap = cachedPickerSnapshot;
        if (snap != null && snap.matches(a.config, rev, sel, pref)) {
            return snap;
        }
        snap = new PickerSnapshot(a, a.config, rev, sel, pref);
        cachedPickerSnapshot = snap;
        return snap;
    }

    private static GradientDrawable makeCardDrawable(
            MainActivity a, int fill, int stroke, int strokeDp, int radiusDp) {
        GradientDrawable d = a.bg(fill, radiusDp);
        if (strokeDp > 0 && stroke != 0) {
            d.setStroke(Math.max(1, a.dp(strokeDp)), stroke);
        }
        return d;
    }

    private static final class SiteViewHolder extends RecyclerView.ViewHolder {
        final LinearLayout card;
        final TextView titleView;
        final TextView subView;
        final GradientDrawable idleBg;
        final GradientDrawable currentBg;
        final GradientDrawable focusedBg;
        final GradientDrawable focusedCurrentBg;
        final boolean tv;
        SiteRow boundRow;
        String boundTitle = "";
        String boundSub = "";
        boolean lastFocusedState;
        boolean visualInitialized;

        SiteViewHolder(MainActivity a, boolean tv) {
            super(a.vertical());
            this.tv = tv;
            card = (LinearLayout) itemView;
            card.setLayoutParams(
                    new RecyclerView.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT));

            // On TV, skip stroked rounded-rect SDF on idle cards (solid rounded card on dark panel)
            // so Mali-450 halves per-card SDF shader passes while keeping crisp focused/current
            // rings.
            idleBg =
                    tv
                            ? makeCardDrawable(a, 0xff1e2734, 0, 0, 10)
                            : makeCardDrawable(a, 0xff222a36, 0xff3b4657, 1, 14);
            currentBg = makeCardDrawable(a, 0xff16343c, 0xff49c5b6, 2, tv ? 10 : 14);
            focusedBg = makeCardDrawable(a, 0xff2f4156, MainActivity.WHITE, 3, tv ? 10 : 14);
            focusedCurrentBg = makeCardDrawable(a, 0xff1f4d57, MainActivity.WHITE, 3, tv ? 10 : 14);

            card.setFocusable(true);
            card.setFocusableInTouchMode(tv);
            card.setClickable(true);
            card.setGravity(Gravity.CENTER_VERTICAL);
            card.setPadding(
                    a.dp(tv ? 16 : 12), a.dp(tv ? 11 : 9), a.dp(tv ? 16 : 12), a.dp(tv ? 11 : 9));
            card.setMinimumHeight(a.dp(tv ? 74 : 60));
            UiCompat.setDefaultFocusHighlightEnabled(card, false);
            card.setBackground(idleBg);

            titleView = a.text("", tv ? 16.5f : 14.5f, MainActivity.WHITE);
            titleView.setTypeface(null, Typeface.BOLD);
            titleView.setMaxLines(2);
            titleView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            titleView.setLineSpacing(a.dp(2), 1.05f);
            applyFastTextProps(titleView);
            card.addView(titleView, new LinearLayout.LayoutParams(-1, -2));

            subView = a.text("", tv ? 13f : 11.5f, 0xff9fb0c4);
            subView.setSingleLine(true);
            subView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            applyFastTextProps(subView);
            LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-1, -2);
            slp.topMargin = a.dp(4);
            card.addView(subView, slp);
        }

        void applyVisualState(boolean focused) {
            SiteRow r = boundRow;
            if (r == null) return;
            visualInitialized = true;
            lastFocusedState = focused;
            if (focused) {
                card.setBackground(r.current ? focusedCurrentBg : focusedBg);
                titleView.setTextColor(MainActivity.WHITE);
                subView.setTextColor(r.current ? 0xffa7f3d0 : 0xffdbe7f4);
                if (!tv) {
                    card.setScaleX(1.015f);
                    card.setScaleY(1.015f);
                }
            } else {
                card.setBackground(r.current ? currentBg : idleBg);
                titleView.setTextColor(r.available ? 0xfff1f5f9 : 0xff8b96a6);
                subView.setTextColor(
                        r.current ? 0xff7ce3c6 : (r.available ? 0xff9fb0c4 : 0xff7f8a99));
                if (!tv) {
                    card.setScaleX(1f);
                    card.setScaleY(1f);
                }
            }
        }
    }

    private interface SiteRowListener {
        void onFocus(SiteRow row, int position);

        void onClick(SiteRow row);

        void onMenu(SiteRow row);

        boolean onKey(SiteRow row, int position, int keyCode, KeyEvent ev);
    }

    private static final class SiteGridAdapter extends RecyclerView.Adapter<SiteViewHolder> {
        private final MainActivity a;
        private final boolean tv;
        private final SiteRowListener listener;
        private java.util.List<SiteRow> items = java.util.Collections.emptyList();
        private boolean allGroupView = true;

        SiteGridAdapter(MainActivity a, boolean tv, SiteRowListener listener) {
            this.a = a;
            this.tv = tv;
            this.listener = listener;
            setHasStableIds(true);
        }

        void submit(java.util.List<SiteRow> next, boolean allGroupView) {
            java.util.List<SiteRow> resolved =
                    next == null ? java.util.Collections.emptyList() : next;
            if (this.items == resolved && this.allGroupView == allGroupView) {
                return;
            }
            this.items = resolved;
            this.allGroupView = allGroupView;
            notifyDataSetChanged();
        }

        int indexOfKey(String siteKey) {
            if (siteKey == null || siteKey.isEmpty()) return -1;
            for (int i = 0; i < items.size(); i++) {
                if (siteKey.equals(items.get(i).key)) return i;
            }
            return -1;
        }

        @Override
        public long getItemId(int position) {
            return items.get(position).stableId;
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        @Override
        public SiteViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            SiteViewHolder vh = new SiteViewHolder(a, tv);
            vh.card.setOnClickListener(
                    v -> {
                        if (vh.boundRow != null) listener.onClick(vh.boundRow);
                    });
            vh.card.setOnLongClickListener(
                    v -> {
                        if (vh.boundRow != null) listener.onMenu(vh.boundRow);
                        return true;
                    });
            vh.card.setOnFocusChangeListener(
                    (v, focused) -> {
                        vh.applyVisualState(focused);
                        if (focused && vh.boundRow != null) {
                            listener.onFocus(vh.boundRow, vh.getBindingAdapterPosition());
                        }
                    });
            vh.card.setOnKeyListener(
                    (v, keyCode, ev) ->
                            vh.boundRow != null
                                    && listener.onKey(
                                            vh.boundRow,
                                            vh.getBindingAdapterPosition(),
                                            keyCode,
                                            ev));
            return vh;
        }

        @Override
        public void onBindViewHolder(SiteViewHolder vh, int position) {
            SiteRow row = items.get(position);
            SiteRow prev = vh.boundRow;
            vh.boundRow = row;
            vh.card.setTag("source-choice:" + row.key);
            vh.card.setContentDescription(row.previewLine);
            if (!row.name.equals(vh.boundTitle)) {
                vh.boundTitle = row.name;
                vh.titleView.setText(row.name);
            }
            String sub = allGroupView ? row.subtitleMultiGroup : row.subtitleSingleGroup;
            if (sub.isEmpty()) {
                if (vh.subView.getVisibility() != View.GONE) {
                    vh.subView.setVisibility(View.GONE);
                }
                vh.boundSub = "";
            } else {
                if (vh.subView.getVisibility() != View.VISIBLE) {
                    vh.subView.setVisibility(View.VISIBLE);
                }
                if (!sub.equals(vh.boundSub)) {
                    vh.boundSub = sub;
                    vh.subView.setText(sub);
                }
            }
            boolean focused = vh.card.hasFocus();
            if (!vh.visualInitialized
                    || focused != vh.lastFocusedState
                    || prev == null
                    || prev.current != row.current
                    || prev.available != row.available) {
                vh.applyVisualState(focused);
            }
        }
    }

    private static final class SubscriptionViewHolder extends RecyclerView.ViewHolder {
        final LinearLayout card;
        final TextView titleView;
        final TextView metaView;
        final TextView enabledBadge;
        final TextView currentBadge;
        final GradientDrawable idleBg;
        final GradientDrawable currentBg;
        final GradientDrawable focusedBg;
        final GradientDrawable focusedCurrentBg;
        TvMultiSourceStore.SubscriptionRecord boundRec;
        boolean boundCurrent;

        SubscriptionViewHolder(MainActivity a, boolean tv, int cardGap) {
            super(new FrameLayout(a));
            FrameLayout wrap = (FrameLayout) itemView;
            wrap.setClipChildren(false);
            wrap.setClipToPadding(false);
            wrap.setPadding(cardGap, cardGap, cardGap, cardGap);
            wrap.setLayoutParams(
                    new RecyclerView.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT));

            idleBg = makeCardDrawable(a, 0xff202c38, 0x3854687d, 1, 14);
            currentBg = makeCardDrawable(a, 0xff19333d, 0xff5698a6, 2, 14);
            focusedBg = makeCardDrawable(a, 0xff35495b, MainActivity.WHITE, 3, 14);
            focusedCurrentBg = makeCardDrawable(a, 0xff234c58, MainActivity.WHITE, 3, 14);

            card = a.vertical();
            card.setFocusable(true);
            card.setFocusableInTouchMode(tv);
            card.setClickable(true);
            card.setPadding(a.dp(18), a.dp(14), a.dp(18), a.dp(14));
            card.setMinimumHeight(a.dp(tv ? 112 : 92));
            UiCompat.setDefaultFocusHighlightEnabled(card, false);
            card.setBackground(idleBg);

            titleView = a.text("", tv ? 18f : 15.5f, MainActivity.WHITE);
            titleView.setTypeface(null, Typeface.BOLD);
            titleView.setMaxLines(2);
            titleView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            card.addView(titleView, new LinearLayout.LayoutParams(-1, -2));

            metaView = a.text("", tv ? 13f : 12f, 0xffb9c4cf);
            metaView.setMaxLines(2);
            metaView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(-1, -2);
            mlp.topMargin = a.dp(5);
            card.addView(metaView, mlp);

            LinearLayout statesRow = a.row();
            statesRow.setGravity(Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams srLp = new LinearLayout.LayoutParams(-1, -2);
            srLp.topMargin = a.dp(10);

            enabledBadge = a.text("", tv ? 12.5f : 11.5f, 0xffb2e7cf);
            enabledBadge.setTypeface(null, Typeface.BOLD);
            enabledBadge.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
            enabledBadge.setBackground(a.bg(0x22b2e7cf, 999));
            statesRow.addView(enabledBadge, new LinearLayout.LayoutParams(-2, -2));

            currentBadge = a.text("当前浏览", tv ? 12.5f : 11.5f, 0xffafcaed);
            currentBadge.setTypeface(null, Typeface.BOLD);
            currentBadge.setPadding(a.dp(8), a.dp(2), a.dp(8), a.dp(2));
            currentBadge.setBackground(a.bg(0x2660a5fa, 999));
            LinearLayout.LayoutParams cbLp = new LinearLayout.LayoutParams(-2, -2);
            cbLp.leftMargin = a.dp(8);
            statesRow.addView(currentBadge, cbLp);

            card.addView(statesRow, srLp);
            wrap.addView(card, new FrameLayout.LayoutParams(-1, -2));
        }

        void applyVisualState(boolean focused) {
            if (focused) {
                card.setBackground(boundCurrent ? focusedCurrentBg : focusedBg);
                card.setScaleX(1.015f);
                card.setScaleY(1.015f);
            } else {
                card.setBackground(boundCurrent ? currentBg : idleBg);
                card.setScaleX(1f);
                card.setScaleY(1f);
            }
        }
    }

    private interface SubscriptionCardListener {
        void onClick(TvMultiSourceStore.SubscriptionRecord rec);

        void onFocus(TvMultiSourceStore.SubscriptionRecord rec, int position);

        boolean onKey(TvMultiSourceStore.SubscriptionRecord rec, int pos, int keyCode, KeyEvent ev);
    }

    private static final class SubscriptionGridAdapter
            extends RecyclerView.Adapter<SubscriptionViewHolder> {
        private final MainActivity a;
        private final boolean tv;
        private final int cardGap;
        private final SubscriptionCardListener listener;
        private java.util.List<TvMultiSourceStore.SubscriptionRecord> items =
                java.util.Collections.emptyList();
        private String currentSubId = "";

        SubscriptionGridAdapter(
                MainActivity a, boolean tv, int cardGap, SubscriptionCardListener listener) {
            this.a = a;
            this.tv = tv;
            this.cardGap = cardGap;
            this.listener = listener;
            setHasStableIds(true);
        }

        void submit(
                java.util.List<TvMultiSourceStore.SubscriptionRecord> next, String currentSubId) {
            this.items = next == null ? java.util.Collections.emptyList() : next;
            this.currentSubId = currentSubId == null ? "" : currentSubId;
            notifyDataSetChanged();
        }

        int indexOfId(String subId) {
            if (subId == null || subId.isEmpty()) return -1;
            for (int i = 0; i < items.size(); i++) {
                if (subId.equals(items.get(i).id)) return i;
            }
            return -1;
        }

        @Override
        public long getItemId(int position) {
            String id = items.get(position).id;
            long h = 1125899906842597L;
            for (int i = 0; i < id.length(); i++) h = 31L * h + id.charAt(i);
            return h;
        }

        @Override
        public int getItemCount() {
            return items.size();
        }

        @Override
        public SubscriptionViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            SubscriptionViewHolder vh = new SubscriptionViewHolder(a, tv, cardGap);
            vh.card.setOnClickListener(
                    v -> {
                        if (vh.boundRec != null) listener.onClick(vh.boundRec);
                    });
            vh.card.setOnFocusChangeListener(
                    (v, focused) -> {
                        vh.applyVisualState(focused);
                        if (focused && vh.boundRec != null) {
                            listener.onFocus(vh.boundRec, vh.getBindingAdapterPosition());
                        }
                    });
            vh.card.setOnKeyListener(
                    (v, keyCode, ev) ->
                            vh.boundRec != null
                                    && listener.onKey(
                                            vh.boundRec,
                                            vh.getBindingAdapterPosition(),
                                            keyCode,
                                            ev));
            return vh;
        }

        @Override
        public void onBindViewHolder(SubscriptionViewHolder vh, int position) {
            TvMultiSourceStore.SubscriptionRecord rec = items.get(position);
            vh.boundRec = rec;
            vh.boundCurrent = rec.enabled && rec.id.equals(currentSubId);
            vh.card.setTag("sub-card:" + rec.id);
            vh.titleView.setText(rec.name.isEmpty() ? "未命名订阅" : rec.name);

            StringBuilder meta = new StringBuilder();
            String recoveryHint =
                    a.multiSourceStore != null ? a.multiSourceStore.recoveryHintFor(rec.id) : "";
            String warningText =
                    (rec.lastError != null && !rec.lastError.isEmpty())
                            ? rec.lastError
                            : recoveryHint;
            if (warningText != null && !warningText.isEmpty()) {
                meta.append("⚠ ").append(warningText);
                vh.metaView.setTextColor(0xfffbbf24);
            } else {
                vh.metaView.setTextColor(0xffb9c4cf);
                if (rec.totalSiteCount > 0) {
                    if (rec.loadedSiteCount > 0 && rec.loadedSiteCount < rec.totalSiteCount) {
                        meta.append("已载入 ")
                                .append(rec.loadedSiteCount)
                                .append(" / ")
                                .append(rec.totalSiteCount)
                                .append(" 站");
                    } else {
                        meta.append("共 ").append(rec.totalSiteCount).append(" 站");
                    }
                } else {
                    meta.append("本地已保存订阅");
                }
                if (!rec.disabledSiteKeys.isEmpty()) {
                    meta.append(" · 已单独停用 ").append(rec.disabledSiteKeys.size()).append(" 站");
                }
                String stamp = SourceController.formatShortTimestamp(rec.lastUpdated);
                if (!stamp.isEmpty()) meta.append(" · 更新 ").append(stamp);
            }
            vh.metaView.setText(meta.toString());

            vh.enabledBadge.setText(rec.enabled ? "已启用" : "已停用");
            vh.enabledBadge.setTextColor(rec.enabled ? 0xffb2e7cf : 0xffc0c6ce);
            vh.enabledBadge.setBackground(a.bg(rec.enabled ? 0x22b2e7cf : 0x209ca3af, 999));
            vh.currentBadge.setVisibility(vh.boundCurrent ? View.VISIBLE : View.GONE);

            StringBuilder desc = new StringBuilder(rec.name);
            desc.append(" · ").append(rec.enabled ? "已启用" : "已停用");
            if (vh.boundCurrent) desc.append(" · 当前浏览");
            if (meta.length() > 0) desc.append(" · ").append(meta);
            vh.card.setContentDescription(desc.toString());
            vh.applyVisualState(vh.card.hasFocus());
        }
    }

    /** O(1) uniform span lookup so scrolling to item #185+ never walks 0..N on the UI thread. */
    private static final class UniformSpanSizeLookup extends GridLayoutManager.SpanSizeLookup {
        @Override
        public int getSpanSize(int position) {
            return 1;
        }

        @Override
        public int getSpanIndex(int position, int spanCount) {
            return spanCount > 0 ? (position % spanCount) : 0;
        }

        @Override
        public int getSpanGroupIndex(int adapterPosition, int spanCount) {
            return spanCount > 0 ? (adapterPosition / spanCount) : 0;
        }
    }

    /** Lightweight 4-phase timing snapshot for the most recent SourcePicker open. */
    static final class OpenProfile {
        volatile boolean shellReused;
        volatile long enterNs;
        volatile double dialogAndViewsMs;
        volatile double snapshotMs;
        volatile double groupPillsMs;
        volatile double bindLinesMs;
        volatile double preScrollMs;
        volatile double dialogShowMs;
        volatile double firstDrawMs = -1.0;
        volatile double selectedFocusedMs = -1.0;
        volatile int targetPos = -1;
        volatile String focusedTag = "";
    }

    static volatile OpenProfile lastOpenProfile = new OpenProfile();

    private static final class PickerShell {
        final MainActivity activity;
        final int panelWidth;
        final int maxDialogH;
        final int columns;
        final float fontScale;
        final boolean tv;
        final Dialog dialog;
        final LinearLayout panel;
        final Button tabLines;
        final Button tabSubs;
        final TextView headerSummary;
        final TextView focusPreview;
        final LinearLayout linesPane;
        final HorizontalScrollView grpScroll;
        final LinearLayout grpRow;
        final TextView linesEmptyView;
        final RecyclerView sitesRv;
        final GridLayoutManager sitesLm;
        final SiteGridAdapter siteAdapter;
        final LinearLayout subsPane;
        TextView subsZeroBanner;
        Button btnEnableAllSubs;
        RecyclerView subsRv;
        GridLayoutManager subsLm;
        SubscriptionGridAdapter subsAdapter;
        boolean subsPaneInitialized;
        final int cardGap;
        final int dialogHeightPx;
        int prewarmedHolders;
        final Button btnManageSubs;
        final java.util.List<Button> groupPillButtons = new java.util.ArrayList<>();
        final Runnable refreshTabStyles;
        final Runnable updateGroupPills;
        final Runnable bindLinesTab;
        final Runnable reloadSubsTab;
        final Runnable switchTab;
        int currentTab = TAB_LINES;
        String activeGroup = "全部";
        String lastFocusedSiteKey = "";
        String lastPreview = "";
        String lastHeaderSummary = "";
        String lastGroupSig = "";
        String lastStyledActiveGroup = "";
        String lastManageBtnText = "";
        int lastStyledTab = -1;
        String focusSubIdAfterReload = "";
        PickerSnapshot snap;
        Origin origin;
        boolean handingOff;
        int pendingFocusSitePos = -1;
        boolean drawRecorded;
        OpenProfile activeProfile;
        Runnable pendingPrewarmTask;
        ViewTreeObserver.OnDrawListener activeFirstDrawListener;

        PickerShell(
                final MainActivity a,
                final int panelWidth,
                final int maxDialogH,
                final int columns,
                final float fontScale,
                final boolean tv,
                final int padH,
                final int padTop,
                final int padBottom,
                final int innerWidth,
                final int cardGap) {
            this.activity = a;
            this.panelWidth = panelWidth;
            this.maxDialogH = maxDialogH;
            this.columns = columns;
            this.fontScale = fontScale;
            this.tv = tv;
            this.cardGap = cardGap;

            this.dialog =
                    new Dialog(a) {
                        @Override
                        public boolean dispatchKeyEvent(KeyEvent event) {
                            if (event != null && event.getAction() == KeyEvent.ACTION_DOWN) {
                                a.markUserInteraction();
                            }
                            return super.dispatchKeyEvent(event);
                        }
                    };
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
            dialog.setOnDismissListener(
                    d -> {
                        a.markUserInteraction();
                        pendingFocusSitePos = -1;
                        cancelPendingPrewarm();
                        detachFirstDrawListener();
                        if (a.sourceDialog == dialog) a.sourceDialog = null;
                        if (!handingOff) {
                            if (a.activePickerOrigin == origin) {
                                a.activePickerOrigin = null;
                            }
                            if (origin != null) origin.restoreFocus(a);
                        }
                    });

            this.panel = a.vertical();
            panel.setTag("source-picker");
            panel.setPadding(padH, padTop, padH, padBottom);
            panel.setClipChildren(false);
            panel.setClipToPadding(false);
            if (tv) {
                // Opaque GPU-rendered rounded dark surface avoids both GlassworkSurface's
                // software drawBehind stall and full-panel alpha blending on Mali-450.
                panel.setBackground(
                        TvV17Surface.rounded(
                                0xff141c27, a.dp(22), 0xff3b4c62, Math.max(1, a.dp(1))));
            } else {
                a.glass(panel, 22);
            }

            LinearLayout topBar = a.row();
            topBar.setGravity(Gravity.CENTER_VERTICAL);
            topBar.setClipChildren(false);
            topBar.setClipToPadding(false);

            this.tabLines =
                    createLightweightPillButton(
                            a, "选线路", "source-tab-lines", tv ? 15f : 13.5f, true, 16, 6, 38);
            this.tabSubs =
                    createLightweightPillButton(
                            a, "管理订阅源", "source-tab-subs", tv ? 15f : 13.5f, true, 16, 6, 38);
            tabLines.setId(View.generateViewId());
            tabSubs.setId(View.generateViewId());
            LinearLayout.LayoutParams tLp1 = new LinearLayout.LayoutParams(-2, -2);
            tLp1.rightMargin = a.dp(8);
            topBar.addView(tabLines, tLp1);
            topBar.addView(tabSubs, new LinearLayout.LayoutParams(-2, -2));

            this.headerSummary = a.text("", 12.5f, 0xffb9c5cd);
            headerSummary.setTag("source-picker-summary");
            headerSummary.setSingleLine(true);
            headerSummary.setEllipsize(android.text.TextUtils.TruncateAt.END);
            headerSummary.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams hsLp = new LinearLayout.LayoutParams(0, -2, 1f);
            hsLp.leftMargin = a.dp(12);
            topBar.addView(headerSummary, hsLp);

            final Button prefBtn =
                    a.navButton(
                            "默认偏好源",
                            "source-preferred",
                            () -> {
                                handingOff = true;
                                dialog.dismiss();
                                SourcePreferences.choose(a);
                            });
            prefBtn.setId(View.generateViewId());
            prefBtn.setTextSize(12.5f);
            prefBtn.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
            prefBtn.setMinHeight(a.dp(34));
            prefBtn.setMinimumHeight(a.dp(34));
            LinearLayout.LayoutParams pfLp = new LinearLayout.LayoutParams(-2, a.dp(34));
            pfLp.leftMargin = a.dp(10);
            topBar.addView(prefBtn, pfLp);
            panel.addView(topBar, new LinearLayout.LayoutParams(-1, -2));

            this.refreshTabStyles =
                    () -> {
                        boolean linesActive = currentTab == TAB_LINES;
                        lastStyledTab = currentTab;
                        applyTabPillVisual(tabLines, linesActive, tabLines.hasFocus());
                        applyTabPillVisual(tabSubs, !linesActive, tabSubs.hasFocus());
                    };
            tabLines.setOnFocusChangeListener((v, f) -> refreshTabStyles.run());
            tabSubs.setOnFocusChangeListener((v, f) -> refreshTabStyles.run());
            tabLines.setNextFocusRightId(tabSubs.getId());
            tabSubs.setNextFocusLeftId(tabLines.getId());
            tabSubs.setNextFocusRightId(prefBtn.getId());
            prefBtn.setNextFocusLeftId(tabSubs.getId());

            // Fixed exact pixel width + height eliminates WRAP_CONTENT re-measure +
            // WindowManager.relayoutWindow stalls when rapid DPAD_DOWN bursts update the preview.
            this.focusPreview = a.text("", 13f, 0xffe8f0f8);
            focusPreview.setTag("source-focus-preview");
            focusPreview.setFocusable(false);
            focusPreview.setMaxLines(2);
            focusPreview.setEllipsize(android.text.TextUtils.TruncateAt.END);
            focusPreview.setGravity(Gravity.CENTER_VERTICAL);
            focusPreview.setLineSpacing(a.dp(1), 1.08f);
            applyFastTextProps(focusPreview);
            focusPreview.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
            focusPreview.setBackground(a.bg(0xff1e2a38, 10));
            LinearLayout.LayoutParams fpLp =
                    new LinearLayout.LayoutParams(innerWidth, a.dp(tv ? 48 : 42));
            fpLp.topMargin = a.dp(8);
            panel.addView(focusPreview, fpLp);

            this.linesPane = a.vertical();
            linesPane.setTag("source-lines-pane");
            linesPane.setClipChildren(true);
            linesPane.setClipToPadding(true);

            this.grpScroll = new HorizontalScrollView(a);
            grpScroll.setTag("source-group-scroll");
            grpScroll.setHorizontalScrollBarEnabled(false);
            grpScroll.setClipChildren(true);
            grpScroll.setClipToPadding(true);
            this.grpRow = a.row();
            grpRow.setClipChildren(false);
            grpRow.setClipToPadding(false);
            grpRow.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(6));
            grpScroll.addView(grpRow, new HorizontalScrollView.LayoutParams(-2, -2));
            linesPane.addView(grpScroll, new LinearLayout.LayoutParams(-1, -2));

            this.linesEmptyView = a.text("当前暂无已启用片源，请切换至「管理订阅源」启用或导入订阅。", 14f, 0xffe8e4c4);
            linesEmptyView.setTag("source-lines-empty");
            linesEmptyView.setPadding(a.dp(14), a.dp(16), a.dp(14), a.dp(16));
            linesEmptyView.setBackground(a.bg(0x33585643, 12));
            linesEmptyView.setVisibility(View.GONE);
            linesPane.addView(linesEmptyView, new LinearLayout.LayoutParams(-1, -2));

            this.sitesRv = new RecyclerView(a);
            sitesRv.setTag("source-sites-recyclerview");
            sitesRv.setClipToPadding(true);
            sitesRv.setClipChildren(true);
            sitesRv.setItemAnimator(null);
            sitesRv.setHasFixedSize(true);
            sitesRv.setItemViewCacheSize(16);
            sitesRv.getRecycledViewPool().setMaxRecycledViews(0, 24);
            sitesRv.addItemDecoration(new GapItemDecoration(cardGap));
            sitesRv.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(4));
            this.sitesLm = new GridLayoutManager(a, columns);
            sitesLm.setSpanSizeLookup(new UniformSpanSizeLookup());
            sitesLm.setInitialPrefetchItemCount(8);
            sitesRv.setLayoutManager(sitesLm);

            // Lazily populate subsPane contents only when the user actually switches to
            // TAB_SUBSCRIPTIONS so first TAB_LINES open avoids inflating a second RecyclerView.
            this.subsPane = a.vertical();
            subsPane.setTag("source-subs-pane");
            subsPane.setClipChildren(true);
            subsPane.setClipToPadding(true);

            int chromeBudget = a.dp(tv ? 225 : 205);
            int listHeightPx =
                    Math.max(a.dp(140), Math.min(a.dp(tv ? 330 : 300), maxDialogH - chromeBudget));
            int tabStackHeightPx =
                    Math.min(
                            Math.max(a.dp(180), maxDialogH - a.dp(tv ? 210 : 190)),
                            listHeightPx + a.dp(tv ? 54 : 46));
            int sitesRvHeightPx = Math.max(a.dp(120), tabStackHeightPx - a.dp(tv ? 46 : 42));
            linesPane.addView(sitesRv, new LinearLayout.LayoutParams(innerWidth, sitesRvHeightPx));

            FrameLayout tabStack = new FrameLayout(a);
            tabStack.setClipChildren(true);
            tabStack.setClipToPadding(true);
            tabStack.addView(linesPane, new FrameLayout.LayoutParams(-1, -1));
            tabStack.addView(subsPane, new FrameLayout.LayoutParams(-1, -1));
            panel.addView(tabStack, new LinearLayout.LayoutParams(innerWidth, tabStackHeightPx));

            a.gap(panel, 8);
            this.btnManageSubs = a.navButton("管理订阅源", "source-library", () -> {});
            final Button btnManageLines =
                    a.navButton(
                            "管理线路",
                            "source-manage",
                            () -> {
                                if (a.config == null || a.config.sites.isEmpty()) {
                                    a.toast("暂无可管理的已启用线路");
                                    return;
                                }
                                handingOff = true;
                                dialog.dismiss();
                                manage(a);
                            });
            final Button btnAddSource =
                    a.navButton(
                            tv ? "添加新源" : "更新配置",
                            "source-update",
                            () -> {
                                handingOff = true;
                                dialog.dismiss();
                                a.importDialog();
                            });
            final Button btnDone = a.navButton("完成", "source-close", dialog::dismiss);
            final java.util.List<Button> footerBtns =
                    java.util.Arrays.asList(btnManageSubs, btnManageLines, btnAddSource, btnDone);
            int maxFootNeed = 0;
            for (Button fb : footerBtns) {
                fb.setId(View.generateViewId());
                fb.setTextSize(tv ? 13.5f : 12.5f);
                fb.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
                int need =
                        Math.round(fb.getPaint().measureText(String.valueOf(fb.getText())))
                                + a.dp(26);
                if (need > maxFootNeed) maxFootNeed = need;
            }
            int footCols =
                    computeFooterColumns(innerWidth, maxFootNeed, a.dp(8), footerBtns.size());
            LinearLayout footerGrid = a.vertical();
            footerGrid.setClipChildren(false);
            footerGrid.setClipToPadding(false);
            LinearLayout fRow = null;
            for (int i = 0; i < footerBtns.size(); i++) {
                Button fb = footerBtns.get(i);
                if (i % footCols == 0) {
                    fRow = a.row();
                    fRow.setClipChildren(false);
                    fRow.setClipToPadding(false);
                    footerGrid.addView(fRow, new LinearLayout.LayoutParams(-1, -2));
                }
                LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(0, a.dp(40), 1f);
                flp.setMargins(a.dp(4), a.dp(3), a.dp(4), a.dp(3));
                fRow.addView(fb, flp);
                int col = i % footCols;
                fb.setNextFocusLeftId(col > 0 ? footerBtns.get(i - 1).getId() : fb.getId());
                fb.setNextFocusRightId(
                        (col + 1 < footCols && i + 1 < footerBtns.size())
                                ? footerBtns.get(i + 1).getId()
                                : fb.getId());
                if (i + footCols < footerBtns.size()) {
                    fb.setNextFocusDownId(footerBtns.get(i + footCols).getId());
                } else {
                    fb.setNextFocusDownId(fb.getId());
                }
                if (i >= footCols) {
                    fb.setNextFocusUpId(footerBtns.get(i - footCols).getId());
                }
            }
            panel.addView(footerGrid, new LinearLayout.LayoutParams(-1, -2));

            int footRows = (footerBtns.size() + footCols - 1) / footCols;
            int footerH = footRows * a.dp(46);
            int fixedOverhead =
                    padTop
                            + padBottom
                            + a.dp(tv ? 46 : 42)
                            + a.dp(tv ? 56 : 50)
                            + a.dp(8)
                            + footerH;
            this.dialogHeightPx = Math.min(maxDialogH, fixedOverhead + tabStackHeightPx);

            this.updateGroupPills =
                    () -> {
                        for (Button p : groupPillButtons) {
                            boolean active = ("source-group:" + activeGroup).equals(p.getTag());
                            applyGroupPillVisual(p, active, p.hasFocus());
                        }
                    };

            this.siteAdapter =
                    new SiteGridAdapter(
                            a,
                            tv,
                            new SiteRowListener() {
                                @Override
                                public void onFocus(SiteRow row, int position) {
                                    lastFocusedSiteKey = row.key;
                                    String text = "当前聚焦：" + row.previewLine;
                                    if (!text.equals(lastPreview)) {
                                        lastPreview = text;
                                        focusPreview.setText(text);
                                    }
                                }

                                @Override
                                public void onClick(SiteRow row) {
                                    final boolean[] ho = {handingOff};
                                    handleSiteCardSelected(a, dialog, origin, ho, row, activeGroup);
                                    handingOff = ho[0];
                                }

                                @Override
                                public void onMenu(SiteRow row) {
                                    handingOff = true;
                                    dialog.dismiss();
                                    showSiteActionMenu(a, a.config, row.site, activeGroup);
                                }

                                @Override
                                public boolean onKey(
                                        SiteRow row, int position, int keyCode, KeyEvent ev) {
                                    if (keyCode == KeyEvent.KEYCODE_MENU
                                            && ev.getAction() == KeyEvent.ACTION_DOWN
                                            && ev.getRepeatCount() == 0) {
                                        onMenu(row);
                                        return true;
                                    }
                                    if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                            && ev.getAction() == KeyEvent.ACTION_DOWN) {
                                        int total = siteAdapter.getItemCount();
                                        if (position >= 0 && position + columns >= total) {
                                            btnManageSubs.requestFocus();
                                            return true;
                                        }
                                    }
                                    if (keyCode == KeyEvent.KEYCODE_DPAD_UP
                                            && ev.getAction() == KeyEvent.ACTION_DOWN
                                            && position >= 0
                                            && position < columns) {
                                        if (!groupPillButtons.isEmpty()) {
                                            groupPillButtons.get(0).requestFocus();
                                        } else {
                                            tabLines.requestFocus();
                                        }
                                        return true;
                                    }
                                    return false;
                                }
                            });
            sitesRv.setAdapter(siteAdapter);
            sitesRv.addOnLayoutChangeListener(
                    (v, l, t, r, b, ol, ot, or, ob) -> tryFocusPendingSiteCard());

            this.bindLinesTab =
                    () -> {
                        OpenProfile prof = activeProfile;
                        long tSnapStart = android.os.SystemClock.elapsedRealtimeNanos();
                        PickerSnapshot nextSnap = obtainSnapshot(a);
                        long tSnapEnd = android.os.SystemClock.elapsedRealtimeNanos();
                        snap = nextSnap;
                        if (!nextSnap.filterGroups.contains(activeGroup)) activeGroup = "全部";
                        String nextSummary =
                                "可用 "
                                        + nextSnap.supportedCount
                                        + " / 共 "
                                        + nextSnap.siteCount
                                        + " 线路";
                        if (!nextSummary.equals(lastHeaderSummary)) {
                            lastHeaderSummary = nextSummary;
                            headerSummary.setText(nextSummary);
                        }

                        long tPillsStart = android.os.SystemClock.elapsedRealtimeNanos();
                        boolean hasBatch = a.config != null && !a.config.sites.isEmpty();
                        if (nextSnap.siteCount > 0) {
                            if (grpScroll.getVisibility() != View.VISIBLE) {
                                grpScroll.setVisibility(View.VISIBLE);
                            }
                            StringBuilder sig = new StringBuilder();
                            for (String g : nextSnap.filterGroups) {
                                sig.append(g)
                                        .append('=')
                                        .append(nextSnap.groupCounts.get(g))
                                        .append('|');
                            }
                            sig.append(hasBatch ? "B1" : "B0");
                            String nextSig = sig.toString();
                            boolean rebuiltPills = !nextSig.equals(lastGroupSig);
                            if (rebuiltPills) {
                                lastGroupSig = nextSig;
                                grpRow.removeAllViews();
                                groupPillButtons.clear();
                                for (int gi = 0; gi < nextSnap.filterGroups.size(); gi++) {
                                    final String grp = nextSnap.filterGroups.get(gi);
                                    int gCnt =
                                            nextSnap.groupCounts.containsKey(grp)
                                                    ? nextSnap.groupCounts.get(grp)
                                                    : 0;
                                    final Button pill =
                                            createLightweightPillButton(
                                                    a,
                                                    grp + " (" + gCnt + ")",
                                                    "source-group:" + grp,
                                                    12.5f,
                                                    false,
                                                    12,
                                                    5,
                                                    32);
                                    pill.setId(View.generateViewId());
                                    pill.setOnClickListener(
                                            v -> {
                                                if (grp.equals(activeGroup)) return;
                                                activeGroup = grp;
                                                lastStyledActiveGroup = grp;
                                                updateGroupPills.run();
                                                java.util.List<SiteRow> grpItems =
                                                        snap.rowsForGroup(grp);
                                                siteAdapter.submit(grpItems, "全部".equals(grp));
                                                int targetPos =
                                                        siteAdapter.indexOfKey(lastFocusedSiteKey);
                                                if (targetPos < 0) {
                                                    targetPos =
                                                            siteAdapter.indexOfKey(
                                                                    snap.selectedKey);
                                                }
                                                if (targetPos < 0) targetPos = 0;
                                                sitesLm.scrollToPositionWithOffset(targetPos, 0);
                                            });
                                    pill.setOnFocusChangeListener(
                                            (v, f) -> {
                                                updateGroupPills.run();
                                                if (f && grpScroll.getWidth() > 0) {
                                                    grpScroll.smoothScrollTo(
                                                            Math.max(
                                                                    0,
                                                                    v.getLeft()
                                                                            - (grpScroll.getWidth()
                                                                                            - v
                                                                                                    .getWidth())
                                                                                    / 2),
                                                            0);
                                                }
                                            });
                                    LinearLayout.LayoutParams plp =
                                            new LinearLayout.LayoutParams(-2, -2);
                                    if (gi > 0) plp.leftMargin = a.dp(7);
                                    grpRow.addView(pill, plp);
                                    groupPillButtons.add(pill);
                                }
                                if (hasBatch) {
                                    Button batchBtn =
                                            createLightweightPillButton(
                                                    a,
                                                    "批量分组",
                                                    "source-batch-group",
                                                    12.5f,
                                                    false,
                                                    12,
                                                    5,
                                                    32);
                                    batchBtn.setId(View.generateViewId());
                                    batchBtn.setOnClickListener(
                                            v -> {
                                                handingOff = true;
                                                dialog.dismiss();
                                                showBatchGroupDialog(a, a.config, activeGroup);
                                            });
                                    batchBtn.setOnFocusChangeListener(
                                            (v, f) -> updateGroupPills.run());
                                    LinearLayout.LayoutParams blp =
                                            new LinearLayout.LayoutParams(-2, -2);
                                    blp.leftMargin = a.dp(7);
                                    grpRow.addView(batchBtn, blp);
                                    groupPillButtons.add(batchBtn);
                                }
                            }
                            if (rebuiltPills || !activeGroup.equals(lastStyledActiveGroup)) {
                                lastStyledActiveGroup = activeGroup;
                                updateGroupPills.run();
                            }
                        } else if (grpScroll.getVisibility() != View.GONE) {
                            grpScroll.setVisibility(View.GONE);
                        }
                        long tPillsEnd = android.os.SystemClock.elapsedRealtimeNanos();

                        java.util.List<SiteRow> curItems = nextSnap.rowsForGroup(activeGroup);
                        siteAdapter.submit(curItems, "全部".equals(activeGroup));
                        boolean empty = curItems.isEmpty();
                        linesEmptyView.setVisibility(empty ? View.VISIBLE : View.GONE);
                        sitesRv.setVisibility(empty ? View.GONE : View.VISIBLE);
                        if (!empty) {
                            int initIdx = siteAdapter.indexOfKey(nextSnap.selectedKey);
                            if (initIdx < 0) initIdx = 0;
                            String initPreview = "当前聚焦：" + curItems.get(initIdx).previewLine;
                            if (!initPreview.equals(lastPreview)) {
                                lastPreview = initPreview;
                                focusPreview.setText(initPreview);
                            }
                        } else if (!lastPreview.isEmpty()) {
                            lastPreview = "";
                            focusPreview.setText("");
                        }
                        if (prof != null) {
                            prof.snapshotMs = round3((tSnapEnd - tSnapStart) / 1e6);
                            prof.groupPillsMs = round3((tPillsEnd - tPillsStart) / 1e6);
                        }
                    };

            final Runnable[] reloadRef = new Runnable[1];
            this.reloadSubsTab =
                    () -> {
                        ensureSubsPaneInitialized(reloadRef);
                        if (a.multiSourceStore == null || a.configStore == null) {
                            subsZeroBanner.setText("暂无已保存的订阅。请点击下方「添加新源」导入。");
                            subsZeroBanner.setVisibility(View.VISIBLE);
                            subsAdapter.submit(java.util.Collections.emptyList(), "");
                            return;
                        }
                        final TvMultiSourceStore store = a.multiSourceStore;
                        final ConfigLibrary lib = new ConfigLibrary(a.configStore.directory);
                        final String activeRaw =
                                a.config != null && a.config.raw != null ? a.config.raw : "";
                        final String activeOrigin = a.configOrigin == null ? "" : a.configOrigin;
                        final String activeSel =
                                a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
                        a.worker.execute(
                                () -> {
                                    try {
                                        final TvMultiSourceStore.State finalSt =
                                                store.ensureMigrated(
                                                        lib, activeRaw, activeOrigin, activeSel);
                                        a.ui.post(
                                                () -> {
                                                    if (a.isFinishing() || !dialog.isShowing())
                                                        return;
                                                    int total = finalSt.subscriptions.size();
                                                    int enabled = finalSt.enabledCount();
                                                    if (currentTab == TAB_SUBSCRIPTIONS) {
                                                        headerSummary.setText(
                                                                "已添加 "
                                                                        + total
                                                                        + " 个订阅 · 已启用 "
                                                                        + enabled
                                                                        + " 个");
                                                    }
                                                    subsZeroBanner.setVisibility(
                                                            total == 0 || enabled == 0
                                                                    ? View.VISIBLE
                                                                    : View.GONE);
                                                    btnEnableAllSubs.setVisibility(
                                                            total > 1 && enabled < total
                                                                    ? View.VISIBLE
                                                                    : View.GONE);
                                                    btnEnableAllSubs.setOnClickListener(
                                                            v ->
                                                                    applySubscriptionMutationAsync(
                                                                            a,
                                                                            store,
                                                                            lib,
                                                                            origin,
                                                                            () -> {
                                                                                for (TvMultiSourceStore
                                                                                                .SubscriptionRecord
                                                                                        r :
                                                                                                finalSt.subscriptions) {
                                                                                    if (!r.enabled) {
                                                                                        store
                                                                                                .setSubscriptionEnabled(
                                                                                                        r.id,
                                                                                                        true);
                                                                                    }
                                                                                }
                                                                            },
                                                                            "已全部启用 " + total
                                                                                    + " 个订阅",
                                                                            () -> {
                                                                                invalidatePickerCache();
                                                                                snap =
                                                                                        obtainSnapshot(
                                                                                                a);
                                                                                if (reloadRef[0]
                                                                                        != null) {
                                                                                    reloadRef[0]
                                                                                            .run();
                                                                                }
                                                                            }));
                                                    subsZeroBanner.setText(
                                                            total == 0
                                                                    ? "尚未添加任何订阅。点击下方「添加新源」即可导入。"
                                                                    : "所有订阅均已停用。选择下方任一卡片即可重新启用，配置、收藏与历史均已保留。");
                                                    subsAdapter.submit(
                                                            finalSt.subscriptions,
                                                            finalSt.currentSubscriptionId);
                                                    if (currentTab == TAB_SUBSCRIPTIONS
                                                            && total > 0) {
                                                        int idx =
                                                                subsAdapter.indexOfId(
                                                                        focusSubIdAfterReload);
                                                        if (idx < 0) {
                                                            idx =
                                                                    subsAdapter.indexOfId(
                                                                            finalSt.currentSubscriptionId);
                                                        }
                                                        if (idx < 0) idx = 0;
                                                        final int focusPos = idx;
                                                        subsLm.scrollToPositionWithOffset(
                                                                focusPos, 0);
                                                        subsRv.post(
                                                                () -> {
                                                                    RecyclerView.ViewHolder h =
                                                                            subsRv
                                                                                    .findViewHolderForAdapterPosition(
                                                                                            focusPos);
                                                                    if (h
                                                                            instanceof
                                                                            SubscriptionViewHolder) {
                                                                        ((SubscriptionViewHolder) h)
                                                                                .card
                                                                                        .requestFocus();
                                                                    }
                                                                });
                                                    }
                                                });
                                    } catch (Throwable err) {
                                        a.ui.post(
                                                () -> {
                                                    if (!a.isFinishing()) {
                                                        a.toast("读取订阅库失败：" + a.message(err));
                                                    }
                                                });
                                    }
                                });
                    };
            reloadRef[0] = reloadSubsTab;

            this.switchTab =
                    () -> {
                        boolean lines = currentTab == TAB_LINES;
                        linesPane.setVisibility(lines ? View.VISIBLE : View.INVISIBLE);
                        linesPane.setDescendantFocusability(
                                lines
                                        ? ViewGroup.FOCUS_AFTER_DESCENDANTS
                                        : ViewGroup.FOCUS_BLOCK_DESCENDANTS);
                        subsPane.setVisibility(lines ? View.INVISIBLE : View.VISIBLE);
                        subsPane.setDescendantFocusability(
                                lines
                                        ? ViewGroup.FOCUS_BLOCK_DESCENDANTS
                                        : ViewGroup.FOCUS_AFTER_DESCENDANTS);
                        refreshTabStyles.run();
                        if (lines) {
                            if (snap == null || snap != cachedPickerSnapshot) {
                                bindLinesTab.run();
                            }
                            int targetIdx =
                                    snap == null ? -1 : siteAdapter.indexOfKey(snap.selectedKey);
                            if (targetIdx < 0) targetIdx = 0;
                            if (siteAdapter.getItemCount() > 0) {
                                final int pos = targetIdx;
                                pendingFocusSitePos = pos;
                                sitesLm.scrollToPositionWithOffset(pos, 0);
                                if (!tryFocusPendingSiteCard()) {
                                    sitesRv.post(this::tryFocusPendingSiteCard);
                                }
                            } else {
                                tabSubs.requestFocus();
                            }
                        } else {
                            reloadSubsTab.run();
                        }
                    };

            tabLines.setOnClickListener(
                    v -> {
                        currentTab = TAB_LINES;
                        lastManageBtnText = "管理订阅源";
                        btnManageSubs.setText(lastManageBtnText);
                        switchTab.run();
                    });
            tabSubs.setOnClickListener(
                    v -> {
                        currentTab = TAB_SUBSCRIPTIONS;
                        lastManageBtnText = "返回选线路";
                        btnManageSubs.setText(lastManageBtnText);
                        switchTab.run();
                    });
            btnManageSubs.setOnClickListener(
                    v -> {
                        currentTab =
                                currentTab == TAB_SUBSCRIPTIONS ? TAB_LINES : TAB_SUBSCRIPTIONS;
                        lastManageBtnText = currentTab == TAB_SUBSCRIPTIONS ? "返回选线路" : "管理订阅源";
                        btnManageSubs.setText(lastManageBtnText);
                        switchTab.run();
                    });

            // Fixed exact pixel height avoids WindowManager.relayoutWindow during DPAD scrolling.
            dialog.setContentView(panel, new ViewGroup.LayoutParams(panelWidth, dialogHeightPx));
            Window window = dialog.getWindow();
            if (window != null) {
                window.setBackgroundDrawableResource(android.R.color.transparent);
                window.setLayout(panelWidth, dialogHeightPx);
                window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
                if (tv) {
                    window.setWindowAnimations(0);
                }
                WindowManager.LayoutParams params = window.getAttributes();
                params.gravity = Gravity.CENTER;
                params.dimAmount = .65f;
                window.setAttributes(params);
            }
            dialog.setOnShowListener(
                    d -> {
                        if (currentTab == TAB_SUBSCRIPTIONS) {
                            reloadSubsTab.run();
                        } else if (siteAdapter.getItemCount() > 0) {
                            if (!tryFocusPendingSiteCard()) {
                                sitesRv.post(this::tryFocusPendingSiteCard);
                            }
                            scheduleDeferredPoolTopUp(6, 500L);
                        } else {
                            tabSubs.requestFocus();
                        }
                    });
        }

        private void ensureSubsPaneInitialized(final Runnable[] reloadRef) {
            if (subsPaneInitialized) return;
            subsPaneInitialized = true;
            final MainActivity a = this.activity;
            final TextView subsNotice =
                    a.text("启用的订阅可参与选线路与跨源搜索。按确定键可停用、启用、管理单条线路或设为当前浏览源。", 12.5f, 0xffc9d6e2);
            subsNotice.setPadding(a.dp(2), a.dp(6), a.dp(2), a.dp(4));
            applyFastTextProps(subsNotice);
            subsPane.addView(subsNotice, new LinearLayout.LayoutParams(-1, -2));

            this.subsZeroBanner = a.text("所有订阅均已停用。选择下方任一卡片即可重新启用，配置、收藏与历史均已保留。", 13f, 0xffe8e4c4);
            subsZeroBanner.setTag("subs-zero-enabled-banner");
            subsZeroBanner.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
            subsZeroBanner.setBackground(a.bg(0x44585643, 10));
            subsZeroBanner.setVisibility(View.GONE);
            applyFastTextProps(subsZeroBanner);
            LinearLayout.LayoutParams zbLp = new LinearLayout.LayoutParams(-1, -2);
            zbLp.bottomMargin = a.dp(6);
            subsPane.addView(subsZeroBanner, zbLp);

            this.btnEnableAllSubs = a.button("全部启用订阅", "source-merge-all-subscriptions", () -> {});
            btnEnableAllSubs.setId(View.generateViewId());
            btnEnableAllSubs.setTextSize(12.5f);
            btnEnableAllSubs.setSingleLine(true);
            btnEnableAllSubs.setPadding(a.dp(12), a.dp(5), a.dp(12), a.dp(5));
            btnEnableAllSubs.setMinHeight(a.dp(32));
            btnEnableAllSubs.setMinimumHeight(a.dp(32));
            btnEnableAllSubs.setVisibility(View.GONE);
            LinearLayout.LayoutParams eaLp = new LinearLayout.LayoutParams(-2, -2);
            eaLp.bottomMargin = a.dp(6);
            subsPane.addView(btnEnableAllSubs, eaLp);

            this.subsRv = new RecyclerView(a);
            subsRv.setTag("source-subs-recyclerview");
            subsRv.setClipToPadding(true);
            subsRv.setClipChildren(true);
            subsRv.setItemAnimator(null);
            subsRv.setHasFixedSize(true);
            subsRv.setItemViewCacheSize(4);
            subsRv.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(4));
            this.subsLm = new GridLayoutManager(a, columns);
            subsLm.setSpanSizeLookup(new UniformSpanSizeLookup());
            subsRv.setLayoutManager(subsLm);
            subsPane.addView(subsRv, new LinearLayout.LayoutParams(-1, 0, 1f));

            this.subsAdapter =
                    new SubscriptionGridAdapter(
                            a,
                            tv,
                            cardGap,
                            new SubscriptionCardListener() {
                                @Override
                                public void onClick(TvMultiSourceStore.SubscriptionRecord rec) {
                                    focusSubIdAfterReload = rec.id;
                                    showSubscriptionActionPanel(
                                            a,
                                            dialog,
                                            origin,
                                            rec,
                                            () -> {
                                                invalidatePickerCache();
                                                if (reloadRef[0] != null) reloadRef[0].run();
                                                bindLinesTab.run();
                                            });
                                }

                                @Override
                                public void onFocus(
                                        TvMultiSourceStore.SubscriptionRecord rec, int position) {
                                    String text =
                                            "订阅："
                                                    + rec.name
                                                    + (rec.origin.isEmpty()
                                                            ? "（本地）"
                                                            : "  ·  " + rec.origin);
                                    if (!text.equals(lastPreview)) {
                                        lastPreview = text;
                                        focusPreview.setText(text);
                                    }
                                }

                                @Override
                                public boolean onKey(
                                        TvMultiSourceStore.SubscriptionRecord rec,
                                        int pos,
                                        int keyCode,
                                        KeyEvent ev) {
                                    if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                                            && ev.getAction() == KeyEvent.ACTION_DOWN) {
                                        int total = subsAdapter.getItemCount();
                                        if (pos >= 0 && pos + columns >= total) {
                                            btnManageSubs.requestFocus();
                                            return true;
                                        }
                                    }
                                    if (keyCode == KeyEvent.KEYCODE_DPAD_UP
                                            && ev.getAction() == KeyEvent.ACTION_DOWN
                                            && pos >= 0
                                            && pos < columns) {
                                        tabSubs.requestFocus();
                                        return true;
                                    }
                                    return false;
                                }
                            });
            subsRv.setAdapter(subsAdapter);
        }

        void cancelPendingPrewarm() {
            Runnable task = pendingPrewarmTask;
            pendingPrewarmTask = null;
            if (task != null && activity.ui != null) {
                activity.ui.removeCallbacks(task);
            }
        }

        void detachFirstDrawListener() {
            ViewTreeObserver.OnDrawListener l = activeFirstDrawListener;
            activeFirstDrawListener = null;
            if (l != null) {
                try {
                    ViewTreeObserver vto = panel.getViewTreeObserver();
                    if (vto != null && vto.isAlive()) {
                        vto.removeOnDrawListener(l);
                    }
                } catch (Throwable ignored) {
                }
            }
        }

        void armFirstDrawAndFocusProbe(final OpenProfile prof) {
            detachFirstDrawListener();
            final ViewTreeObserver vto = panel.getViewTreeObserver();
            if (vto == null || !vto.isAlive()) return;
            vto.addOnPreDrawListener(
                    new ViewTreeObserver.OnPreDrawListener() {
                        @Override
                        public boolean onPreDraw() {
                            try {
                                ViewTreeObserver cur = panel.getViewTreeObserver();
                                if (cur != null && cur.isAlive()) {
                                    cur.removeOnPreDrawListener(this);
                                }
                            } catch (Throwable ignored) {
                            }
                            tryFocusPendingSiteCard();
                            return true;
                        }
                    });
            final ViewTreeObserver.OnDrawListener drawListener =
                    new ViewTreeObserver.OnDrawListener() {
                        @Override
                        public void onDraw() {
                            if (!drawRecorded && prof != null && activeProfile == prof) {
                                drawRecorded = true;
                                prof.firstDrawMs =
                                        round3(
                                                (android.os.SystemClock.elapsedRealtimeNanos()
                                                                - prof.enterNs)
                                                        / 1e6);
                            }
                            final ViewTreeObserver.OnDrawListener self = this;
                            panel.post(
                                    () -> {
                                        if (activeFirstDrawListener == self) {
                                            detachFirstDrawListener();
                                        }
                                    });
                        }
                    };
            activeFirstDrawListener = drawListener;
            vto.addOnDrawListener(drawListener);
        }

        void scheduleDeferredPoolTopUp(final int targetCount, long delayMs) {
            cancelPendingPrewarm();
            if (prewarmedHolders >= targetCount || activity.isFinishing() || activity.ui == null) {
                return;
            }
            final Runnable r =
                    () -> {
                        pendingPrewarmTask = null;
                        if (activity.isFinishing()
                                || !dialog.isShowing()
                                || prewarmedHolders >= targetCount) {
                            return;
                        }
                        schedulePoolPrewarm(targetCount);
                    };
            pendingPrewarmTask = r;
            activity.ui.postDelayed(r, delayMs);
        }

        /**
         * Incrementally pre-populates pooled SiteViewHolders (2 per frame) during idle so rapid
         * DPAD_DOWN x3 hits ready recycled views instead of running synchronous ViewHolder
         * inflation mid-scroll, without ever competing with rapid dialog close/reopen.
         */
        void schedulePoolPrewarm(final int targetCount) {
            if (prewarmedHolders >= targetCount || activity.isFinishing() || activity.ui == null) {
                return;
            }
            cancelPendingPrewarm();
            final Runnable r =
                    () -> {
                        pendingPrewarmTask = null;
                        if (activity.isFinishing() || prewarmedHolders >= targetCount) return;
                        RecyclerView.RecycledViewPool pool = sitesRv.getRecycledViewPool();
                        int batch = Math.min(2, targetCount - prewarmedHolders);
                        for (int i = 0; i < batch; i++) {
                            SiteViewHolder vh = siteAdapter.createViewHolder(sitesRv, 0);
                            pool.putRecycledView(vh);
                            prewarmedHolders++;
                        }
                        if (prewarmedHolders < targetCount) {
                            schedulePoolPrewarm(targetCount);
                        }
                    };
            pendingPrewarmTask = r;
            activity.ui.post(r);
        }

        /**
         * Pre-populates group pills, adapter items, and off-screen measure/layout once Home is idle
         * so the very first "换源" click skips view inflation & layout measurement on the UI thread.
         */
        void prebindForIdle(MainActivity host) {
            if (host == null || host.config == null || dialog.isShowing()) return;
            PickerSnapshot warm = cachedPickerSnapshot;
            if (warm == null) return;
            activeProfile = null;
            activeGroup = "全部";
            currentTab = TAB_LINES;
            bindLinesTab.run();
            if (siteAdapter.getItemCount() > 0) {
                int targetIdx = siteAdapter.indexOfKey(warm.selectedKey);
                if (targetIdx < 0) targetIdx = 0;
                sitesLm.scrollToPositionWithOffset(targetIdx, 0);
            }
            if (panelWidth > 0 && dialogHeightPx > 0) {
                int wSpec = View.MeasureSpec.makeMeasureSpec(panelWidth, View.MeasureSpec.EXACTLY);
                int hSpec =
                        View.MeasureSpec.makeMeasureSpec(dialogHeightPx, View.MeasureSpec.EXACTLY);
                panel.measure(wSpec, hSpec);
                panel.layout(0, 0, panelWidth, dialogHeightPx);
            }
        }

        private void applyGroupPillVisual(Button p, boolean active, boolean focused) {
            int bg = focused ? MainActivity.WHITE : (active ? 0xff2b5a84 : 0x26ffffff);
            if (p.getBackground() instanceof GradientDrawable) {
                ((GradientDrawable) p.getBackground()).setColor(bg);
            } else {
                p.setBackground(makeCardDrawable(activity, bg, 0, 0, 10));
            }
            p.setTextColor(focused ? MainActivity.DARK : MainActivity.WHITE);
        }

        private void applyTabPillVisual(Button b, boolean active, boolean focused) {
            int bg = focused ? MainActivity.WHITE : (active ? 0xff2b5a84 : 0x28ffffff);
            if (b.getBackground() instanceof GradientDrawable) {
                ((GradientDrawable) b.getBackground()).setColor(bg);
            } else {
                b.setBackground(makeCardDrawable(activity, bg, 0, 0, 12));
            }
            b.setTextColor(focused ? MainActivity.DARK : MainActivity.WHITE);
        }

        boolean tryFocusPendingSiteCard() {
            int pos = pendingFocusSitePos;
            if (pos < 0 || currentTab != TAB_LINES) return false;
            RecyclerView.ViewHolder h = sitesRv.findViewHolderForAdapterPosition(pos);
            if (!(h instanceof SiteViewHolder)) return false;
            SiteViewHolder svh = (SiteViewHolder) h;
            boolean ok = svh.card.requestFocus();
            if (ok || svh.card.hasFocus()) {
                pendingFocusSitePos = -1;
                OpenProfile prof = activeProfile;
                if (prof != null && prof.selectedFocusedMs < 0.0) {
                    prof.selectedFocusedMs =
                            round3(
                                    (android.os.SystemClock.elapsedRealtimeNanos() - prof.enterNs)
                                            / 1e6);
                    Object tg = svh.card.getTag();
                    prof.focusedTag = tg == null ? "" : String.valueOf(tg);
                }
                return true;
            }
            return false;
        }

        boolean matches(MainActivity a, int pw, int mh, int cols, float fs, boolean isTv) {
            return activity == a
                    && panelWidth == pw
                    && maxDialogH == mh
                    && columns == cols
                    && Math.abs(fontScale - fs) < 0.01f
                    && tv == isTv;
        }
    }

    private static PickerShell cachedPickerShell;

    static void clearCachedShell(MainActivity a) {
        PickerShell s = cachedPickerShell;
        if (s != null && (a == null || s.activity == a)) {
            try {
                if (s.dialog != null && s.dialog.isShowing()) s.dialog.dismiss();
            } catch (Throwable ignored) {
            }
            cachedPickerShell = null;
        }
    }

    private static double round3(double v) {
        return Math.round(v * 1000.0) / 1000.0;
    }

    private static Button createLightweightPillButton(
            MainActivity a,
            String label,
            String tag,
            float textSp,
            boolean bold,
            int padHDp,
            int padVDp,
            int minHeightDp) {
        Button b = new Button(a);
        b.setText(label);
        b.setTag(tag);
        b.setTextSize(textSp);
        if (bold) b.setTypeface(null, Typeface.BOLD);
        b.setTextColor(MainActivity.WHITE);
        b.setAllCaps(false);
        b.setSingleLine(true);
        b.setGravity(Gravity.CENTER);
        b.setIncludeFontPadding(false);
        b.setStateListAnimator(null);
        b.setOutlineProvider(null);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(a.dp(minHeightDp));
        b.setMinimumHeight(a.dp(minHeightDp));
        b.setPadding(a.dp(padHDp), a.dp(padVDp), a.dp(padHDp), a.dp(padVDp));
        b.setBackground(makeCardDrawable(a, 0x26ffffff, 0, 0, bold ? 12 : 10));
        UiCompat.setDefaultFocusHighlightEnabled(b, false);
        b.setFocusable(true);
        b.setFocusableInTouchMode(a.isTvDevice());
        return b;
    }

    private static PickerShell ensureCachedShellForActivity(MainActivity a) {
        final boolean tv = a.isTvDevice();
        final float density = Math.max(1f, a.getResources().getDisplayMetrics().density);
        final float fontScale = Math.max(1f, a.getResources().getConfiguration().fontScale);
        android.graphics.Rect visRect = new android.graphics.Rect();
        if (a.getWindow() != null && a.getWindow().getDecorView() != null) {
            a.getWindow().getDecorView().getWindowVisibleDisplayFrame(visRect);
        }
        int screenW =
                visRect.width() > 0
                        ? Math.min(a.windowWidth(), visRect.width())
                        : (a.root != null && a.root.getWidth() > 0
                                ? a.root.getWidth()
                                : a.windowWidth());
        int screenH =
                visRect.height() > 0
                        ? Math.min(a.windowHeight(), visRect.height())
                        : (a.root != null && a.root.getHeight() > 0
                                ? a.root.getHeight()
                                : a.windowHeight());
        int marginH = Math.min(a.dp(tv ? 48 : 20), Math.max(0, screenW / 14));
        int panelWidth = Math.min(a.dp(tv ? 800 : 560), Math.max(1, screenW - marginH));
        int maxDialogH = Math.max(a.dp(220), screenH - Math.min(a.dp(40), screenH / 12));
        int padH = Math.min(a.dp(tv ? 22 : 16), Math.max(a.dp(10), panelWidth / 16));
        int padTop = a.dp(tv ? 16 : 14);
        int padBottom = a.dp(tv ? 14 : 12);
        int innerWidth = Math.max(a.dp(180), panelWidth - padH * 2);
        final int columns = computePickerColumns(innerWidth, density, fontScale, tv);
        final int cardGap = a.dp(tv ? 6 : 4);

        PickerShell shell = cachedPickerShell;
        if (shell != null && shell.matches(a, panelWidth, maxDialogH, columns, fontScale, tv)) {
            return shell;
        }
        if (shell != null) clearCachedShell(null);
        shell =
                new PickerShell(
                        a,
                        panelWidth,
                        maxDialogH,
                        columns,
                        fontScale,
                        tv,
                        padH,
                        padTop,
                        padBottom,
                        innerWidth,
                        cardGap);
        cachedPickerShell = shell;
        return shell;
    }

    private static void showUnified(
            final MainActivity a,
            final String requestedGroup,
            final int initialTab,
            final Origin origin) {
        if (a == null || a.isFinishing()) return;
        final long tEnterNs = android.os.SystemClock.elapsedRealtimeNanos();
        final OpenProfile prof = new OpenProfile();
        prof.enterNs = tEnterNs;
        lastOpenProfile = prof;

        if (a.sourceDialog != null && a.sourceDialog.isShowing()) {
            try {
                a.sourceDialog.dismiss();
            } catch (Throwable ignored) {
            }
        }

        final PickerShell prevShell = cachedPickerShell;
        final PickerShell shell = ensureCachedShellForActivity(a);
        boolean reused = (prevShell != null && prevShell == shell);
        prof.shellReused = reused;
        long tViewsBuiltNs = android.os.SystemClock.elapsedRealtimeNanos();
        prof.dialogAndViewsMs = round3((tViewsBuiltNs - tEnterNs) / 1e6);

        shell.cancelPendingPrewarm();
        shell.activeProfile = prof;
        shell.drawRecorded = false;
        shell.handingOff = false;
        shell.origin = origin;
        shell.currentTab = initialTab;
        shell.activeGroup = requestedGroup == null ? "全部" : requestedGroup;
        shell.lastFocusedSiteKey =
                a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
        a.sourceDialog = shell.dialog;
        a.activePickerOrigin = origin;

        long tBindStartNs = android.os.SystemClock.elapsedRealtimeNanos();
        shell.bindLinesTab.run();
        boolean startLines = shell.currentTab == TAB_LINES;
        int wantLinesVis = startLines ? View.VISIBLE : View.INVISIBLE;
        if (shell.linesPane.getVisibility() != wantLinesVis) {
            shell.linesPane.setVisibility(wantLinesVis);
        }
        shell.linesPane.setDescendantFocusability(
                startLines ? ViewGroup.FOCUS_AFTER_DESCENDANTS : ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        int wantSubsVis = startLines ? View.INVISIBLE : View.VISIBLE;
        if (shell.subsPane.getVisibility() != wantSubsVis) {
            shell.subsPane.setVisibility(wantSubsVis);
        }
        shell.subsPane.setDescendantFocusability(
                startLines ? ViewGroup.FOCUS_BLOCK_DESCENDANTS : ViewGroup.FOCUS_AFTER_DESCENDANTS);
        String nextManageText = startLines ? "管理订阅源" : "返回选线路";
        if (!nextManageText.equals(shell.lastManageBtnText)) {
            shell.lastManageBtnText = nextManageText;
            shell.btnManageSubs.setText(nextManageText);
        }
        if (shell.lastStyledTab != shell.currentTab) {
            shell.lastStyledTab = shell.currentTab;
            shell.refreshTabStyles.run();
        }
        long tBindEndNs = android.os.SystemClock.elapsedRealtimeNanos();
        prof.bindLinesMs = round3((tBindEndNs - tBindStartNs) / 1e6);

        // Pre-scroll BEFORE dialog.show() ONLY when the target card is not already laid out in the
        // visible window so hot re-opens on the same site skip redundant RecyclerView relayout.
        long tScrollStartNs = android.os.SystemClock.elapsedRealtimeNanos();
        if (startLines && shell.siteAdapter.getItemCount() > 0) {
            int targetIdx = shell.siteAdapter.indexOfKey(shell.snap.selectedKey);
            if (targetIdx < 0) targetIdx = 0;
            prof.targetPos = targetIdx;
            shell.pendingFocusSitePos = targetIdx;
            boolean alreadyVisible =
                    reused
                            && shell.sitesRv.findViewHolderForAdapterPosition(targetIdx) != null
                            && shell.sitesLm.findFirstCompletelyVisibleItemPosition() >= 0
                            && targetIdx >= shell.sitesLm.findFirstCompletelyVisibleItemPosition()
                            && targetIdx <= shell.sitesLm.findLastCompletelyVisibleItemPosition();
            if (!alreadyVisible) {
                shell.sitesLm.scrollToPositionWithOffset(targetIdx, 0);
            }
        } else {
            prof.targetPos = -1;
            shell.pendingFocusSitePos = -1;
        }
        long tScrollEndNs = android.os.SystemClock.elapsedRealtimeNanos();
        prof.preScrollMs = round3((tScrollEndNs - tScrollStartNs) / 1e6);

        long tShowStartNs = android.os.SystemClock.elapsedRealtimeNanos();
        shell.dialog.show();
        shell.armFirstDrawAndFocusProbe(prof);
        long tShowEndNs = android.os.SystemClock.elapsedRealtimeNanos();
        prof.dialogShowMs = round3((tShowEndNs - tShowStartNs) / 1e6);
    }

    private static void handleSiteCardSelected(
            final MainActivity a,
            final Dialog dialog,
            final Origin origin,
            final boolean[] handingOff,
            final SiteRow row,
            final String activeGroup) {
        final Cms.Site site = row.site;
        if (!row.available) {
            new AppDialog.Builder(a)
                    .setTitle(site.name)
                    .setMessage(SourceController.siteSupportSummary(a, a.config, site))
                    .setNeutralButton("知道了", null)
                    .setPositiveButton(
                            "编辑线路",
                            (d2, w2) -> {
                                handingOff[0] = true;
                                dialog.dismiss();
                                showEditSiteDialog(a, a.config, site, activeGroup);
                            })
                    .setNegativeButton(
                            "删除线路",
                            (d2, w2) -> {
                                handingOff[0] = true;
                                dialog.dismiss();
                                new AppDialog.Builder(a)
                                        .wrapChoices()
                                        .setTitle("删除「" + site.name + "」？")
                                        .setNegativeButton("取消", (c, w3) -> show(a, activeGroup))
                                        .setPositiveButton(
                                                "删除",
                                                (ok, w3) ->
                                                        edit(a, a.config, site, -1, activeGroup))
                                        .show();
                            })
                    .show();
            return;
        }
        String selected = a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
        int action =
                HomeSourceSwitchAnchor.decideSiteSelectionAction(
                        selected,
                        site.key,
                        origin.fromRetainedHome,
                        a.current != null && a.current.home);
        if (action == HomeSourceSwitchAnchor.ACTION_DISMISS_ONLY) {
            dialog.dismiss();
            return;
        }
        invalidatePickerCache();
        if (action == HomeSourceSwitchAnchor.ACTION_SETTINGS_COMMIT_STAY) {
            saveSelectedSiteOnly(a, site.key);
            if (a.activePickerOrigin == origin) a.activePickerOrigin = null;
            dialog.dismiss();
            a.toast("已切换默认片源：" + site.name);
            return;
        }
        final long persistSeq = SITE_PERSIST_SEQ.incrementAndGet();
        if (action == HomeSourceSwitchAnchor.ACTION_IN_PLACE_HOME_SWITCH
                && a.current != null
                && a.current.retainedHome != null) {
            final HomeScreen retained = a.current.retainedHome;
            handingOff[0] = true;
            if (a.activePickerOrigin == origin) a.activePickerOrigin = null;
            dialog.dismiss();
            saveSelectedSiteOnly(a, site.key);
            SITE_PERSIST_EXECUTOR.execute(
                    () -> {
                        if (SITE_PERSIST_SEQ.get() != persistSeq) return;
                        a.ui.post(
                                () -> {
                                    if (SITE_PERSIST_SEQ.get() != persistSeq || a.isFinishing()) {
                                        return;
                                    }
                                    retained.switchSiteInPlace(
                                            site, origin.sourceRelTopPx, origin.scrollY);
                                });
                    });
            return;
        }
        commitSelectedSiteForCrashGuard(a, site.key);
        handingOff[0] = true;
        if (a.activePickerOrigin == origin) a.activePickerOrigin = null;
        dialog.dismiss();
        a.open(new MainActivity.Screen(a::home), false);
    }

    private static void showSubscriptionActionPanel(
            final MainActivity a,
            final Dialog parentDialog,
            final Origin origin,
            final TvMultiSourceStore.SubscriptionRecord rec,
            final Runnable onStateChanged) {
        if (a == null || a.multiSourceStore == null || a.configStore == null || rec == null) return;
        final TvMultiSourceStore store = a.multiSourceStore;
        final ConfigLibrary lib = new ConfigLibrary(a.configStore.directory);
        final java.util.List<String> actionLabels = new java.util.ArrayList<>();
        final java.util.List<String> actionKeys = new java.util.ArrayList<>();
        actionLabels.add(rec.enabled ? "停用此源" : "启用此源");
        actionKeys.add("toggle");
        TvMultiSourceStore.State curState = store.readState();
        boolean isCurrentSub = rec.enabled && rec.id.equals(curState.currentSubscriptionId);
        if (rec.enabled && !isCurrentSub) {
            actionLabels.add("设为当前浏览");
            actionKeys.add("set-current");
        }
        actionLabels.add("管理线路（独立启停单站）");
        actionKeys.add("manage-sites");
        if (curState.subscriptions.size() > 1) {
            int pos = -1;
            for (int i = 0; i < curState.subscriptions.size(); i++) {
                if (curState.subscriptions.get(i).id.equals(rec.id)) {
                    pos = i;
                    break;
                }
            }
            if (pos > 0) {
                actionLabels.add("上移排序");
                actionKeys.add("move-up");
            }
            if (pos >= 0 && pos + 1 < curState.subscriptions.size()) {
                actionLabels.add("下移排序");
                actionKeys.add("move-down");
            }
        }
        if (rec.origin != null && Cms.isHttp(rec.origin)) {
            actionLabels.add("刷新订阅");
            actionKeys.add("refresh");
        }
        actionLabels.add("重命名");
        actionKeys.add("rename");
        actionLabels.add("删除订阅");
        actionKeys.add("delete");

        String statusDesc =
                (rec.enabled ? (isCurrentSub ? "状态：已启用 · 当前浏览" : "状态：已启用") : "状态：已停用")
                        + (rec.lastError != null && !rec.lastError.isEmpty()
                                ? "\n上次刷新：" + rec.lastError
                                : "");

        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle(rec.name)
                .setMessage(statusDesc)
                .setItems(
                        actionLabels.toArray(new String[0]),
                        (d, idx) -> {
                            String act = actionKeys.get(idx);
                            if ("toggle".equals(act)) {
                                final boolean nextEnabled = !rec.enabled;
                                applySubscriptionMutationAsync(
                                        a,
                                        store,
                                        lib,
                                        origin,
                                        () -> store.setSubscriptionEnabled(rec.id, nextEnabled),
                                        nextEnabled
                                                ? ("已启用「" + rec.name + "」")
                                                : ("已停用「" + rec.name + "」"),
                                        onStateChanged);
                            } else if ("set-current".equals(act)) {
                                applySetCurrentSubscriptionAsync(
                                        a, store, lib, origin, rec, onStateChanged);
                            } else if ("manage-sites".equals(act)) {
                                showSubscriptionSitesToggleDialog(
                                        a, store, lib, origin, rec, onStateChanged);
                            } else if ("move-up".equals(act)) {
                                applySubscriptionMutationAsync(
                                        a,
                                        store,
                                        lib,
                                        origin,
                                        () -> store.moveSubscription(rec.id, -1),
                                        "已上移「" + rec.name + "」",
                                        onStateChanged);
                            } else if ("move-down".equals(act)) {
                                applySubscriptionMutationAsync(
                                        a,
                                        store,
                                        lib,
                                        origin,
                                        () -> store.moveSubscription(rec.id, 1),
                                        "已下移「" + rec.name + "」",
                                        onStateChanged);
                            } else if ("refresh".equals(act)) {
                                a.toast("正在刷新「" + rec.name + "」…");
                                a.worker.execute(
                                        () -> {
                                            try {
                                                boolean updated =
                                                        store.refreshSingleSubscription(
                                                                lib,
                                                                rec.id,
                                                                url ->
                                                                        SourceController
                                                                                .fetchImport(
                                                                                        a, url),
                                                                System.currentTimeMillis());
                                                TvMultiSourceStore.EffectiveBuild built =
                                                        store.buildEffectiveConfig(
                                                                lib,
                                                                a.prefs.getString(
                                                                        Prefs.PREFERRED_SITE, ""),
                                                                (cfg, st) ->
                                                                        SourceController.available(
                                                                                a, cfg, st));
                                                TvMultiSourceStore.SubscriptionRecord afterRec =
                                                        store.readState().findById(rec.id);
                                                String msg =
                                                        (afterRec != null
                                                                        && !afterRec.lastError
                                                                                .isEmpty())
                                                                ? ("刷新失败（已保留上次可用配置）："
                                                                        + afterRec.lastError)
                                                                : (updated
                                                                        ? "已刷新「" + rec.name + "」"
                                                                        : "「" + rec.name + "」已是最新");
                                                a.ui.post(
                                                        () -> {
                                                            if (a.isFinishing()) return;
                                                            a.applyMultiSourceEffectiveBuild(
                                                                    built,
                                                                    origin.fromRetainedHome,
                                                                    origin.sourceRelTopPx,
                                                                    origin.scrollY,
                                                                    msg);
                                                            if (onStateChanged != null) {
                                                                onStateChanged.run();
                                                            }
                                                        });
                                            } catch (Throwable err) {
                                                a.ui.post(
                                                        () -> {
                                                            if (!a.isFinishing()) {
                                                                a.toast("刷新失败：" + a.message(err));
                                                                if (onStateChanged != null) {
                                                                    onStateChanged.run();
                                                                }
                                                            }
                                                        });
                                            }
                                        });
                            } else if ("rename".equals(act)) {
                                EditText input = new EditText(a);
                                input.setHint("输入新的订阅名称");
                                input.setText(rec.name);
                                input.setSingleLine(true);
                                input.setTextColor(MainActivity.WHITE);
                                input.setHintTextColor(0xff9299a8);
                                input.setBackgroundColor(0xff232834);
                                input.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
                                input.setSelection(input.getText().length());
                                new AppDialog.Builder(a)
                                        .setTitle("重命名订阅")
                                        .setView(input)
                                        .setNegativeButton("取消", null)
                                        .setPositiveButton(
                                                "保存",
                                                (d2, w2) -> {
                                                    String nextName =
                                                            input.getText().toString().trim();
                                                    if (nextName.isEmpty()) return;
                                                    applySubscriptionMutationAsync(
                                                            a,
                                                            store,
                                                            lib,
                                                            origin,
                                                            () ->
                                                                    store.renameSubscription(
                                                                            lib, rec.id, nextName),
                                                            "已重命名为「" + nextName + "」",
                                                            onStateChanged);
                                                })
                                        .show();
                            } else if ("delete".equals(act)) {
                                new AppDialog.Builder(a)
                                        .setTitle("删除订阅「" + rec.name + "」？")
                                        .setMessage("将永久移除该订阅文件；你的观看历史和收藏记录仍会保留。")
                                        .setNegativeButton("取消", null)
                                        .setPositiveButton(
                                                "确认删除",
                                                (d2, w2) ->
                                                        applySubscriptionMutationAsync(
                                                                a,
                                                                store,
                                                                lib,
                                                                origin,
                                                                () ->
                                                                        store.deleteSubscription(
                                                                                lib, rec.id),
                                                                "已删除订阅「" + rec.name + "」",
                                                                onStateChanged))
                                        .show();
                            }
                        })
                .setNegativeButton("返回", null)
                .show();
    }

    private interface ThrowingTask {
        void run() throws Exception;
    }

    private static void applySubscriptionMutationAsync(
            final MainActivity a,
            final TvMultiSourceStore store,
            final ConfigLibrary lib,
            final Origin origin,
            final ThrowingTask mutation,
            final String baseToast,
            final Runnable onStateChanged) {
        SITE_PERSIST_EXECUTOR.execute(
                () -> {
                    try {
                        String prevSub = store.readState().currentSubscriptionId;
                        mutation.run();
                        final long targetRev = store.currentRevision();
                        final TvMultiSourceStore.EffectiveBuild built =
                                store.buildEffectiveConfig(
                                        lib,
                                        a.prefs.getString(Prefs.PREFERRED_SITE, ""),
                                        (cfg, st) -> SourceController.available(a, cfg, st));
                        String toastMsg = baseToast;
                        if (built.enabledSubscriptionCount == 0) {
                            toastMsg = baseToast + "（当前无已启用片源）";
                        } else if (built.config == null || built.config.sites.isEmpty()) {
                            toastMsg = baseToast + "（已启用订阅下暂无可用点播线路）";
                        } else if (!built.resolvedCurrentSubscriptionId.isEmpty()
                                && !built.resolvedCurrentSubscriptionId.equals(prevSub)) {
                            TvMultiSourceStore.SubscriptionRecord nextSub =
                                    store.readState().findById(built.resolvedCurrentSubscriptionId);
                            if (nextSub != null) {
                                toastMsg = baseToast + " · 当前浏览已切换为「" + nextSub.name + "」";
                            }
                        }
                        final String finalToast = toastMsg;
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()
                                            || built.stale
                                            || store.currentRevision() != targetRev) {
                                        return;
                                    }
                                    a.applyMultiSourceEffectiveBuild(
                                            built,
                                            origin.fromRetainedHome,
                                            origin.sourceRelTopPx,
                                            origin.scrollY,
                                            finalToast);
                                    if (onStateChanged != null) onStateChanged.run();
                                });
                    } catch (Throwable err) {
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing()) {
                                        a.notice("操作保存失败，已保留原状态：" + a.message(err));
                                    }
                                });
                    }
                });
    }

    private static void applySetCurrentSubscriptionAsync(
            final MainActivity a,
            final TvMultiSourceStore store,
            final ConfigLibrary lib,
            final Origin origin,
            final TvMultiSourceStore.SubscriptionRecord rec,
            final Runnable onStateChanged) {
        SITE_PERSIST_EXECUTOR.execute(
                () -> {
                    try {
                        java.util.List<Cms.Site> sites = store.listSitesInSubscription(lib, rec);
                        Cms.Site pick = null;
                        for (Cms.Site s : sites) {
                            if (s != null && !rec.disabledSiteKeys.contains(s.key)) {
                                pick = s;
                                break;
                            }
                        }
                        if (pick == null) {
                            a.ui.post(() -> a.toast("该订阅内暂无可用线路"));
                            return;
                        }
                        String stableKey = TvMultiSourceStore.stableSiteKey(rec.id, pick.key);
                        store.setCurrentSite(stableKey, rec.id, pick.key);
                        final long rev = store.currentRevision();
                        final TvMultiSourceStore.EffectiveBuild built =
                                store.buildEffectiveConfig(
                                        lib,
                                        a.prefs.getString(Prefs.PREFERRED_SITE, ""),
                                        (cfg, st) -> SourceController.available(a, cfg, st));
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()
                                            || built.stale
                                            || store.currentRevision() != rev) return;
                                    a.applyMultiSourceEffectiveBuild(
                                            built,
                                            origin.fromRetainedHome,
                                            origin.sourceRelTopPx,
                                            origin.scrollY,
                                            "当前浏览已切换为「" + rec.name + "」");
                                    if (onStateChanged != null) onStateChanged.run();
                                });
                    } catch (Throwable err) {
                        a.ui.post(() -> a.notice("切换当前浏览失败：" + a.message(err)));
                    }
                });
    }

    private static void showSubscriptionSitesToggleDialog(
            final MainActivity a,
            final TvMultiSourceStore store,
            final ConfigLibrary lib,
            final Origin origin,
            final TvMultiSourceStore.SubscriptionRecord rec,
            final Runnable onStateChanged) {
        a.worker.execute(
                () -> {
                    final java.util.List<Cms.Site> sites = store.listSitesInSubscription(lib, rec);
                    a.ui.post(
                            () -> {
                                if (a.isFinishing()) return;
                                if (sites.isEmpty()) {
                                    a.toast("该订阅内暂无线路");
                                    return;
                                }
                                TvMultiSourceStore.SubscriptionRecord latest =
                                        store.readState().findById(rec.id);
                                final TvMultiSourceStore.SubscriptionRecord activeRec =
                                        latest != null ? latest : rec;
                                String[] labels = new String[sites.size()];
                                for (int i = 0; i < sites.size(); i++) {
                                    Cms.Site s = sites.get(i);
                                    boolean off = activeRec.disabledSiteKeys.contains(s.key);
                                    labels[i] = (off ? "[已停用] " : "[已启用] ") + s.name;
                                }
                                new AppDialog.Builder(a)
                                        .wrapChoices()
                                        .setTitle(activeRec.name + " · 管理线路")
                                        .setMessage("点击单条线路可独立停用或恢复；该开关在停用并重新启用父订阅后仍会保留。")
                                        .setItems(
                                                labels,
                                                (d, idx) -> {
                                                    Cms.Site s = sites.get(idx);
                                                    boolean nextDisabled =
                                                            !activeRec.disabledSiteKeys.contains(
                                                                    s.key);
                                                    applySubscriptionMutationAsync(
                                                            a,
                                                            store,
                                                            lib,
                                                            origin,
                                                            () ->
                                                                    store.setSiteDisabled(
                                                                            activeRec.id,
                                                                            s.key,
                                                                            nextDisabled),
                                                            (nextDisabled ? "已停用线路「" : "已启用线路「")
                                                                    + s.name
                                                                    + "」",
                                                            () -> {
                                                                if (onStateChanged != null) {
                                                                    onStateChanged.run();
                                                                }
                                                                showSubscriptionSitesToggleDialog(
                                                                        a,
                                                                        store,
                                                                        lib,
                                                                        origin,
                                                                        activeRec,
                                                                        onStateChanged);
                                                            });
                                                })
                                        .setNegativeButton("返回", null)
                                        .show();
                            });
                });
    }

    private static void showLegacySavedConfigs(MainActivity a) {
        Cms.Config previous = a.config;
        ConfigLibrary library = new ConfigLibrary(a.configStore.directory);
        String previousOrigin = a.configOrigin;
        String previousSelection = a.prefs.getString(Prefs.SELECTED_SITE, "");
        a.worker.execute(
                () -> {
                    try {
                        if (!TvMultiSourceStore.isEffectiveRuntimeConfig(previous, previousOrigin)
                                && !SubscriptionManager.isMergedOrigin(previousOrigin)) {
                            library.rememberIfAbsent(
                                    previous.raw,
                                    previousOrigin,
                                    SourceController.configName(previous),
                                    previousSelection);
                        }
                        java.util.List<ConfigLibrary.Entry> entries = library.entries();
                        String active = ConfigLibrary.identity(previousOrigin, previous.raw);
                        String[] names = new String[entries.size()];
                        int selected = -1;
                        final java.util.List<ConfigLibrary.Entry> mergeable =
                                new java.util.ArrayList<>();
                        for (int i = 0; i < names.length; i++) {
                            ConfigLibrary.Entry entry = entries.get(i);
                            String stamp = SourceController.formatShortTimestamp(entry.updated);
                            names[i] =
                                    entry.name
                                            + "（订阅 "
                                            + (i + 1)
                                            + (stamp.isEmpty() ? "" : " · 更新 " + stamp)
                                            + "）";
                            if (entry.id.equals(active)) selected = i;
                            if (!SubscriptionManager.isMergedOrigin(entry.origin)) {
                                mergeable.add(entry);
                            }
                        }
                        final int checked = selected;
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing() || a.config != previous) return;
                                    AppDialog.Builder builder =
                                            new AppDialog.Builder(a)
                                                    .wrapChoices()
                                                    .setTitle("已添加源 · " + entries.size() + " 个订阅")
                                                    .setSingleChoiceItems(
                                                            names,
                                                            checked,
                                                            (dialog, index) -> {
                                                                dialog.dismiss();
                                                                ConfigLibrary.Entry entry =
                                                                        entries.get(index);
                                                                if (entry.id.equals(active)) {
                                                                    show(a);
                                                                    return;
                                                                }
                                                                a.worker.execute(
                                                                        () -> {
                                                                            try {
                                                                                Cms.Config saved =
                                                                                        Cms
                                                                                                .parseConfig(
                                                                                                        library
                                                                                                                .raw(
                                                                                                                        entry),
                                                                                                        entry.origin);
                                                                                a.ui.post(
                                                                                        () -> {
                                                                                            if (a
                                                                                                            .isFinishing()
                                                                                                    || a.config
                                                                                                            != previous)
                                                                                                return;
                                                                                            try {
                                                                                                saveSelectedConfig(
                                                                                                        a,
                                                                                                        saved,
                                                                                                        entry.origin);
                                                                                            } catch (
                                                                                                    Exception
                                                                                                            error) {
                                                                                                a
                                                                                                        .notice(
                                                                                                                "订阅切换失败，已保留当前片源");
                                                                                            }
                                                                                        });
                                                                            } catch (
                                                                                    Exception
                                                                                            error) {
                                                                                a.ui.post(
                                                                                        () ->
                                                                                                a
                                                                                                        .notice(
                                                                                                                "无法读取这份订阅，已保留当前片源"));
                                                                            }
                                                                        });
                                                            })
                                                    .setNegativeButton("关闭", null)
                                                    .setPositiveButton(
                                                            "立即刷新订阅",
                                                            (dialog, which) ->
                                                                    SourceController
                                                                            .runDailyAutoUpdateIfNeeded(
                                                                                    a, true));
                                    if (mergeable.size() >= 2) {
                                        builder.setNeutralButton(
                                                "多源合并 / 删除",
                                                (dialog, which) ->
                                                        showSavedConfigsActionsDialog(
                                                                a, library, entries, mergeable,
                                                                active));
                                    } else if (entries.size() > 1) {
                                        builder.setNeutralButton(
                                                "删除订阅",
                                                (dialog, which) ->
                                                        showDeleteSavedConfigDialog(
                                                                a, library, entries, active));
                                    }
                                    builder.show();
                                });
                    } catch (Exception error) {
                        a.ui.post(() -> a.notice("无法读取已添加源，原订阅文件已保留"));
                    }
                });
    }

    private static void showSavedConfigsActionsDialog(
            final MainActivity a,
            final ConfigLibrary library,
            final java.util.List<ConfigLibrary.Entry> entries,
            final java.util.List<ConfigLibrary.Entry> mergeable,
            final String activeId) {
        String[] actions =
                new String[] {
                    "⚡ 合并多个已添加源并自动分组（" + mergeable.size() + " 个可选）", "↻ 立即刷新全部在线订阅源", "删除不再使用的订阅源"
                };
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("订阅源管理")
                .setItems(
                        actions,
                        (d, idx) -> {
                            if (idx == 0) {
                                showMergeSavedConfigsDialog(a, mergeable);
                            } else if (idx == 1) {
                                SourceController.runDailyAutoUpdateIfNeeded(a, true);
                            } else {
                                showDeleteSavedConfigDialog(a, library, entries, activeId);
                            }
                        })
                .setNegativeButton("返回", (d, w) -> showSavedConfigs(a))
                .show();
    }

    private static void showMergeSavedConfigsDialog(
            final MainActivity a, final java.util.List<ConfigLibrary.Entry> mergeable) {
        String[] labels = new String[mergeable.size()];
        final boolean[] checked = new boolean[mergeable.size()];
        for (int i = 0; i < mergeable.size(); i++) {
            labels[i] = mergeable.get(i).name;
            checked[i] = true;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要合并自动分组的订阅源")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton("返回", (d, w) -> showSavedConfigs(a))
                .setPositiveButton(
                        "合并并自动分组",
                        (d, w) -> {
                            java.util.List<ConfigLibrary.Entry> chosen =
                                    new java.util.ArrayList<>();
                            for (int i = 0; i < checked.length; i++) {
                                if (checked[i]) chosen.add(mergeable.get(i));
                            }
                            if (chosen.size() < 2) {
                                a.notice("请至少勾选 2 个订阅源进行合并分组");
                                return;
                            }
                            SourceController.mergeSavedSubscriptions(a, chosen);
                        })
                .show();
    }

    private static void showDeleteSavedConfigDialog(
            final MainActivity a,
            final ConfigLibrary library,
            final java.util.List<ConfigLibrary.Entry> entries,
            final String activeId) {
        final java.util.List<ConfigLibrary.Entry> deletable = new java.util.ArrayList<>();
        for (ConfigLibrary.Entry e : entries) {
            if (!e.id.equals(activeId)) {
                deletable.add(e);
            }
        }
        if (deletable.isEmpty()) {
            a.notice("请先切换到其他订阅源，再删除当前订阅。");
            return;
        }
        String[] labels = new String[deletable.size()];
        for (int i = 0; i < deletable.size(); i++) {
            labels[i] = "删除 · " + deletable.get(i).name;
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("选择要移除的订阅源")
                .setItems(
                        labels,
                        (d, idx) -> {
                            final ConfigLibrary.Entry target = deletable.get(idx);
                            a.worker.execute(
                                    () -> {
                                        try {
                                            library.remove(target.id);
                                            CloudSyncDialog.onSubscriptionDeleted(a, target.id);
                                            a.ui.post(
                                                    () -> {
                                                        a.toast("已移除订阅：" + target.name);
                                                        showSavedConfigs(a);
                                                    });
                                        } catch (Exception err) {
                                            a.ui.post(() -> a.notice("删除订阅失败：" + err.getMessage()));
                                        }
                                    });
                        })
                .setNegativeButton("返回", (d, w) -> showSavedConfigs(a))
                .show();
    }

    private static void saveSelectedConfig(MainActivity a, Cms.Config saved, String origin)
            throws Exception {
        SourceController.saveConfig(a, saved, origin);
        show(a);
    }

    static void showWarehouses(MainActivity a) {
        Cms.Config previous = a.config;
        org.json.JSONArray rows = previous.depots;
        boolean canMergeAll = rows.length() >= 2;
        String[] names = new String[rows.length() + (canMergeAll ? 1 : 0)];
        if (canMergeAll) {
            names[0] = "⚡ 勾选多个子仓库合并并自动分组…";
        }
        for (int i = 0; i < rows.length(); i++) {
            names[i + (canMergeAll ? 1 : 0)] = rows.optJSONObject(i).optString("name");
        }
        new AppDialog.Builder(a)
                .wrapChoices()
                .setTitle("切换子仓库")
                .setItems(
                        names,
                        (dialog, index) -> {
                            if (canMergeAll && index == 0) {
                                showMergeWarehousesDialog(a, rows);
                                return;
                            }
                            int rowIdx = index - (canMergeAll ? 1 : 0);
                            String url = rows.optJSONObject(rowIdx).optString("url");
                            a.toast("正在读取子仓库…");
                            a.worker.execute(
                                    () -> {
                                        try {
                                            Cms.Config selected =
                                                    Cms.parseConfig(
                                                            SourceController.fetchImport(a, url),
                                                            url);
                                            String combined =
                                                    com.pilipala.source.Warehouse.retainDirectory(
                                                            selected.raw,
                                                            selected.origin,
                                                            previous.raw,
                                                            raw ->
                                                                    new org.json.JSONObject(
                                                                            Cms.withoutComments(
                                                                                    raw)));
                                            Cms.Config ready =
                                                    Cms.parseConfig(combined, selected.origin);
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing() || a.config != previous)
                                                            return;
                                                        try {
                                                            SourceController.saveConfig(
                                                                    a, ready, ready.origin);
                                                        } catch (Exception e) {
                                                            a.notice("子仓库保存失败，请重试");
                                                        }
                                                    });
                                        } catch (Exception e) {
                                            a.ui.post(
                                                    () -> {
                                                        if (!a.isFinishing())
                                                            a.notice("子仓库读取失败，已保留原线路");
                                                    });
                                        }
                                    });
                        })
                .show();
    }

    private static void showMergeWarehousesDialog(
            final MainActivity a, final org.json.JSONArray rows) {
        int count = Math.min(SubscriptionManager.MAX_BATCH_SOURCES, rows.length());
        String[] labels = new String[count];
        final boolean[] checked = new boolean[count];
        for (int i = 0; i < count; i++) {
            org.json.JSONObject r = rows.optJSONObject(i);
            labels[i] = r == null ? ("子仓库 " + (i + 1)) : r.optString("name", "子仓库 " + (i + 1));
            checked[i] = i < 4;
        }
        new AppDialog.Builder(a)
                .setTitle("勾选要合并自动分组的子仓库")
                .setView(buildMultiSelectListView(a, labels, checked))
                .setNegativeButton("取消", null)
                .setPositiveButton(
                        "合并并自动分组",
                        (d, w) -> {
                            final java.util.List<SubscriptionManager.ImportSpec> specs =
                                    new java.util.ArrayList<>();
                            for (int i = 0; i < count; i++) {
                                if (!checked[i]) continue;
                                org.json.JSONObject r = rows.optJSONObject(i);
                                if (r == null) continue;
                                String u = r.optString("url", "").trim();
                                String n = r.optString("name", "").trim();
                                if (Cms.isHttp(u)) {
                                    specs.add(new SubscriptionManager.ImportSpec(n, u));
                                }
                            }
                            if (specs.size() < 2) {
                                a.notice("请至少勾选 2 个子仓库");
                                return;
                            }
                            a.toast("正在读取 " + specs.size() + " 个子仓库并自动分组…");
                            a.worker.execute(
                                    () -> {
                                        try {
                                            final SubscriptionManager.MergedResult merged =
                                                    SourceController.fetchAndMergeImportSpecs(
                                                            a, specs, false);
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing()) return;
                                                        try {
                                                            SourceController.saveConfig(
                                                                    a,
                                                                    merged.config,
                                                                    merged.origin);
                                                            a.toast(
                                                                    "已合并 "
                                                                            + merged.sourceCount
                                                                            + " 个子仓库并自动分组");
                                                            show(a);
                                                        } catch (Exception e) {
                                                            a.notice("合并子仓库保存失败：" + a.message(e));
                                                        }
                                                    });
                                        } catch (Exception e) {
                                            a.ui.post(
                                                    () -> {
                                                        if (!a.isFinishing()) {
                                                            a.notice("子仓库合并失败：" + a.message(e));
                                                        }
                                                    });
                                        }
                                    });
                        })
                .show();
    }
}

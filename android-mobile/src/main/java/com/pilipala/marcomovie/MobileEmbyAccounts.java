package com.pilipala.marcomovie;

import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.json.JSONObject;

/** The subscription holds only the account reference. Tokens stay in app-private preferences. */
public final class MobileEmbyAccounts {
    public interface OnConnected {
        void save(JSONObject site) throws Exception;
    }

    public interface OnOpenSite {
        void open(JSONObject site);
    }

    public static List<JSONObject> listSaved(Context context) {
        List<JSONObject> out = new ArrayList<JSONObject>();
        if (context == null) return out;
        SharedPreferences sp = context.getSharedPreferences("emby.accounts", 0);
        java.util.Map<String, ?> all = sp.getAll();
        if (all == null) return out;
        for (java.util.Map.Entry<String, ?> entry : all.entrySet()) {
            String k = entry.getKey();
            if (k == null || !k.startsWith(MobileEmbyLibrary.PREFIX)) continue;
            Object v = entry.getValue();
            if (!(v instanceof String)) continue;
            try {
                JSONObject session = new JSONObject((String) v);
                String keySuffix = k.substring(MobileEmbyLibrary.PREFIX.length());
                String label = session.optString("label", "").trim();
                String displayName =
                        label.length() > 0 ? label : session.optString("name", "").trim();
                if (displayName.length() == 0) {
                    displayName = session.optString("base", "Emby");
                }
                String siteTitle =
                        displayName.startsWith("Emby") ? displayName : ("Emby · " + displayName);
                JSONObject site =
                        new JSONObject()
                                .put("key", "emby_" + keySuffix)
                                .put("name", siteTitle)
                                .put("label", label)
                                .put("type", 1)
                                .put("api", k)
                                .put("base", session.optString("base", ""))
                                .put(
                                        "username",
                                        session.optString(
                                                "username", session.optString("name", "")))
                                .put("user", session.optString("user", ""))
                                .put("allowSync", session.optBoolean("allowSync", true));
                out.add(site);
            } catch (Exception ignored) {
            }
        }
        return out;
    }

    public static void remove(Context context, String api) {
        if (context == null || api == null || !api.startsWith(MobileEmbyLibrary.PREFIX)) return;
        context.getSharedPreferences("emby.accounts", 0).edit().remove(api).commit();
    }

    public static String statusSummary(Context context) {
        List<JSONObject> saved = listSaved(context);
        if (saved.isEmpty()) return "连接自建 Emby / Jellyfin 媒体库，登录时校验读库权限并持久保存";
        if (saved.size() == 1) {
            return "已挂载「" + saved.get(0).optString("name", "Emby") + "」";
        }
        return "已挂载 " + saved.size() + " 个 Emby 媒体库，点击管理或进入";
    }

    public static MobileEmbyLibrary open(Context context, String api) throws Exception {
        if (!api.startsWith(MobileEmbyLibrary.PREFIX)) throw new IOException("Emby 来源无效");
        String raw = context.getSharedPreferences("emby.accounts", 0).getString(api, "");
        if (raw.length() == 0) throw new IOException("请在本机重新登录 Emby");
        return new MobileEmbyLibrary(new JSONObject(raw));
    }

    private static int dp(Activity a, float v) {
        return Math.round(v * a.getResources().getDisplayMetrics().density);
    }

    private static GradientDrawable roundedRect(int fill, float radiusPx, int stroke, int strokeW) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(fill);
        gd.setCornerRadius(radiusPx);
        if (strokeW > 0 && stroke != 0) {
            gd.setStroke(strokeW, stroke);
        }
        return gd;
    }

    public static void connect(final Activity a, final OnConnected callback) {
        openEditor(a, null, callback);
    }

    public static void openEditor(
            final Activity a, final JSONObject existingSite, final OnConnected callback) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p =
                a instanceof MainActivity
                        ? MobileTheme.of((MainActivity) a)
                        : MobileTheme.forState(MobileTheme.isDark(a, MobileTheme.MODE_SYSTEM), 0);
        final SharedPreferences prefs = a.getSharedPreferences("emby.accounts", 0);
        final String existingApi = existingSite == null ? "" : existingSite.optString("api", "");
        JSONObject storedSession = null;
        if (existingApi.length() > 0) {
            String raw = prefs.getString(existingApi, "");
            if (raw.length() > 0) {
                try {
                    storedSession = new JSONObject(raw);
                } catch (Exception ignored) {
                }
            }
        }
        final JSONObject existingSession = storedSession;
        final boolean isEdit = existingSession != null;

        boolean initHttps = false;
        String initHost = "";
        String initPath = "";
        String initPort = "8096";
        String initLabel = "";
        String initUser = "";
        boolean initAllowSync = true;
        if (existingSession != null) {
            initLabel = existingSession.optString("label", "");
            if (initLabel.isEmpty()) {
                String fallbackName = existingSession.optString("name", "");
                if (!fallbackName.equals(existingSession.optString("username", ""))) {
                    initLabel = fallbackName;
                }
            }
            initUser = existingSession.optString("username", existingSession.optString("name", ""));
            initAllowSync = existingSession.optBoolean("allowSync", true);
            if (existingSession.has("rawHost")) {
                initHttps = existingSession.optBoolean("rawHttps", false);
                initHost = existingSession.optString("rawHost", "");
                initPath = existingSession.optString("rawPath", "");
                initPort = existingSession.optString("rawPort", initHttps ? "443" : "8096");
            } else {
                JSONObject split =
                        MobileEmbyLibrary.splitServerUrl(existingSession.optString("base", ""));
                initHttps = split.optBoolean("useHttps", false);
                initHost = split.optString("host", "");
                initPath = split.optString("subpath", "");
                initPort = split.optString("port", initHttps ? "443" : "8096");
                if (initPath.equalsIgnoreCase("/emby")) {
                    initPath = "";
                }
            }
        }

        final LinearLayout form = new LinearLayout(a);
        form.setOrientation(LinearLayout.VERTICAL);

        final EditText nameInput =
                addLabeledField(
                        a,
                        p,
                        form,
                        "名称",
                        initLabel,
                        "例如：4K影视库（选填）",
                        InputType.TYPE_CLASS_TEXT,
                        false);

        final Switch syncSwitch = addSwitchCard(a, p, form, "同步", "是否允许云端同步", initAllowSync);
        final Switch httpsSwitch = addSwitchCard(a, p, form, "协议", "HTTPS", initHttps);

        final EditText hostInput =
                addLabeledField(
                        a,
                        p,
                        form,
                        "服务器地址",
                        initHost,
                        "emby.example 或粘贴完整 URL",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI,
                        false);
        final EditText pathInput =
                addLabeledField(
                        a,
                        p,
                        form,
                        "路径",
                        initPath,
                        "选填 (/path)",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI,
                        false);
        final EditText portInput =
                addLabeledField(
                        a, p, form, "端口号", initPort, "8096", InputType.TYPE_CLASS_NUMBER, false);

        final boolean[] programmaticFieldUpdate = new boolean[] {false};
        httpsSwitch.setOnCheckedChangeListener(
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                        if (programmaticFieldUpdate[0]) return;
                        String curPort = portInput.getText().toString().trim();
                        if (isChecked && (curPort.isEmpty() || "8096".equals(curPort))) {
                            programmaticFieldUpdate[0] = true;
                            portInput.setText("8920");
                            portInput.setSelection(portInput.getText().length());
                            programmaticFieldUpdate[0] = false;
                        } else if (!isChecked
                                && (curPort.isEmpty()
                                        || "8920".equals(curPort)
                                        || "443".equals(curPort))) {
                            programmaticFieldUpdate[0] = true;
                            portInput.setText("8096");
                            portInput.setSelection(portInput.getText().length());
                            programmaticFieldUpdate[0] = false;
                        }
                    }
                });

        hostInput.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {}

                    @Override
                    public void afterTextChanged(Editable s) {
                        if (programmaticFieldUpdate[0] || s == null) return;
                        String raw = s.toString().trim();
                        if (!(raw.regionMatches(true, 0, "http://", 0, 7)
                                || raw.regionMatches(true, 0, "https://", 0, 8))) {
                            return;
                        }
                        JSONObject split = MobileEmbyLibrary.splitServerUrl(raw);
                        String host = split.optString("host", "").trim();
                        if (host.isEmpty()) return;
                        programmaticFieldUpdate[0] = true;
                        try {
                            boolean useTls = split.optBoolean("useHttps", false);
                            httpsSwitch.setChecked(useTls);
                            String sub = split.optString("subpath", "").trim();
                            if (sub.length() > 0
                                    && pathInput.getText().toString().trim().isEmpty()) {
                                pathInput.setText(sub);
                            }
                            String port = split.optString("port", "").trim();
                            if (port.length() > 0) {
                                portInput.setText(port);
                            }
                            s.replace(0, s.length(), host);
                        } finally {
                            programmaticFieldUpdate[0] = false;
                        }
                    }
                });

        final EditText userInput =
                addLabeledField(
                        a, p, form, "用户名", initUser, "用户名", InputType.TYPE_CLASS_TEXT, false);
        final EditText passInput =
                addLabeledField(
                        a,
                        p,
                        form,
                        "密码",
                        "",
                        isEdit ? "密码（留空则仅更新名称与同步设置）" : "密码（可留空）",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD,
                        true);

        final TextView status = new TextView(a);
        status.setTextSize(12.5f);
        status.setTextColor(p.danger);
        status.setVisibility(View.GONE);
        status.setPadding(dp(a, 2), dp(a, 4), dp(a, 2), dp(a, 10));
        form.addView(status);

        final Dialog[] dlgHolder = new Dialog[1];
        final MobileBottomSheet.SheetHandle[] sheetHolder = new MobileBottomSheet.SheetHandle[1];
        final Button submitBtn = actionButton(a, p, isEdit ? "保存" : "连接并保存", true);

        final View.OnClickListener submitAction =
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        final String label = nameInput.getText().toString().trim();
                        final boolean allowSync = syncSwitch.isChecked();
                        final boolean useHttps = httpsSwitch.isChecked();
                        final String rawHost = hostInput.getText().toString().trim();
                        final String rawPath = pathInput.getText().toString().trim();
                        final String rawPort = portInput.getText().toString().trim();
                        final String user = userInput.getText().toString().trim();
                        final String pw = passInput.getText().toString();
                        if (rawHost.isEmpty() || user.isEmpty()) {
                            status.setTextColor(p.danger);
                            status.setText("请填写服务器地址和用户名");
                            status.setVisibility(View.VISIBLE);
                            return;
                        }
                        final String address;
                        try {
                            address =
                                    MobileEmbyLibrary.assembleServerUrl(
                                            useHttps, rawHost, rawPath, rawPort);
                        } catch (Exception addrErr) {
                            status.setTextColor(p.danger);
                            status.setText(addrErr.getMessage());
                            status.setVisibility(View.VISIBLE);
                            return;
                        }

                        if (isEdit && pw.isEmpty()) {
                            try {
                                String oldBase =
                                        existingSession.optString("base", "").replaceAll("/+$", "");
                                String candRoot = address.replaceAll("/+$", "");
                                String oldUser =
                                        existingSession.optString(
                                                "username", existingSession.optString("name", ""));
                                boolean sameServer =
                                        oldBase.equalsIgnoreCase(candRoot)
                                                || oldBase.equalsIgnoreCase(candRoot + "/emby");
                                if (sameServer && user.equals(oldUser)) {
                                    JSONObject updated =
                                            new JSONObject(existingSession.toString())
                                                    .put("label", label)
                                                    .put("name", label.length() > 0 ? label : user)
                                                    .put("username", user)
                                                    .put("allowSync", allowSync)
                                                    .put("rawHttps", useHttps)
                                                    .put("rawHost", rawHost)
                                                    .put("rawPath", rawPath)
                                                    .put("rawPort", rawPort);
                                    prefs.edit()
                                            .putString(existingApi, updated.toString())
                                            .commit();
                                    String keySuffix =
                                            existingApi.substring(
                                                    MobileEmbyLibrary.PREFIX.length());
                                    String display = label.length() > 0 ? label : user;
                                    JSONObject site =
                                            new JSONObject()
                                                    .put("key", "emby_" + keySuffix)
                                                    .put(
                                                            "name",
                                                            display.startsWith("Emby")
                                                                    ? display
                                                                    : ("Emby · " + display))
                                                    .put("type", 1)
                                                    .put("api", existingApi);
                                    if (callback != null) callback.save(site);
                                    dismissDialogOrSheet(dlgHolder[0], sheetHolder[0]);
                                    return;
                                }
                            } catch (Exception ex) {
                                status.setTextColor(p.danger);
                                status.setText(ex.getMessage());
                                status.setVisibility(View.VISIBLE);
                                return;
                            }
                        }

                        submitBtn.setEnabled(false);
                        status.setTextColor(p.accent);
                        status.setText("正在验证并连接…");
                        status.setVisibility(View.VISIBLE);

                        String existingDevice = prefs.getString("device", "");
                        if (existingDevice.length() == 0) {
                            existingDevice = UUID.randomUUID().toString();
                            prefs.edit().putString("device", existingDevice).apply();
                        }
                        final String device = existingDevice;
                        new Thread(
                                        new Runnable() {
                                            @Override
                                            public void run() {
                                                try {
                                                    final JSONObject session =
                                                            MobileEmbyLibrary.login(
                                                                    address, user, pw, device,
                                                                    label);
                                                    session.put("allowSync", allowSync)
                                                            .put("rawHttps", useHttps)
                                                            .put("rawHost", rawHost)
                                                            .put("rawPath", rawPath)
                                                            .put("rawPort", rawPort);
                                                    final String key =
                                                            MobileEmbyLibrary.accountKey(session);
                                                    final String api =
                                                            MobileEmbyLibrary.PREFIX + key;
                                                    final String display =
                                                            label.length() > 0 ? label : user;
                                                    final JSONObject site =
                                                            new JSONObject()
                                                                    .put("key", "emby_" + key)
                                                                    .put(
                                                                            "name",
                                                                            display.startsWith(
                                                                                            "Emby")
                                                                                    ? display
                                                                                    : ("Emby · "
                                                                                            + display))
                                                                    .put("type", 1)
                                                                    .put("api", api);
                                                    a.runOnUiThread(
                                                            new Runnable() {
                                                                @Override
                                                                public void run() {
                                                                    if (a.isFinishing()) return;
                                                                    String prevSession =
                                                                            prefs.getString(
                                                                                    api, null);
                                                                    try {
                                                                        if (!prefs.edit()
                                                                                .putString(
                                                                                        api,
                                                                                        session
                                                                                                .toString())
                                                                                .commit()) {
                                                                            throw new IOException(
                                                                                    "无法保存 Emby 登录状态");
                                                                        }
                                                                        if (isEdit
                                                                                && existingApi
                                                                                                .length()
                                                                                        > 0
                                                                                && !existingApi
                                                                                        .equals(
                                                                                                api)) {
                                                                            prefs.edit()
                                                                                    .remove(
                                                                                            existingApi)
                                                                                    .commit();
                                                                        }
                                                                        if (callback != null) {
                                                                            callback.save(site);
                                                                        }
                                                                        passInput.setText("");
                                                                        dismissDialogOrSheet(
                                                                                dlgHolder[0],
                                                                                sheetHolder[0]);
                                                                    } catch (final Exception ex) {
                                                                        SharedPreferences.Editor
                                                                                rb = prefs.edit();
                                                                        if (prevSession == null) {
                                                                            rb.remove(api);
                                                                        } else {
                                                                            rb.putString(
                                                                                    api,
                                                                                    prevSession);
                                                                        }
                                                                        rb.commit();
                                                                        submitBtn.setEnabled(true);
                                                                        status.setTextColor(
                                                                                p.danger);
                                                                        status.setText(
                                                                                ex.getMessage());
                                                                        status.setVisibility(
                                                                                View.VISIBLE);
                                                                    }
                                                                }
                                                            });
                                                } catch (final Exception ex) {
                                                    a.runOnUiThread(
                                                            new Runnable() {
                                                                @Override
                                                                public void run() {
                                                                    if (!a.isFinishing()) {
                                                                        submitBtn.setEnabled(true);
                                                                        status.setTextColor(
                                                                                p.danger);
                                                                        status.setText(
                                                                                ex.getMessage());
                                                                        status.setVisibility(
                                                                                View.VISIBLE);
                                                                    }
                                                                }
                                                            });
                                                }
                                            }
                                        },
                                        "emby-login")
                                .start();
                    }
                };
        submitBtn.setOnClickListener(submitAction);

        if (a instanceof MainActivity) {
            LinearLayout btnWrap = new LinearLayout(a);
            btnWrap.setOrientation(LinearLayout.HORIZONTAL);
            btnWrap.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(-1, dp(a, 44));
            sLp.topMargin = dp(a, 4);
            form.addView(submitBtn, sLp);
            sheetHolder[0] =
                    MobileBottomSheet.showHandle(
                            (MainActivity) a,
                            isEdit ? "编辑 Emby" : "连接 Emby 媒体库",
                            "支持 HTTP (8096) / HTTPS (8920) 与反代子路径",
                            "取消",
                            null,
                            form,
                            true);
            return;
        }

        final Dialog dlg = new Dialog(a);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dlgHolder[0] = dlg;

        final LinearLayout card = new LinearLayout(a);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(a, 20), dp(a, 18), dp(a, 20), dp(a, 16));
        card.setBackgroundDrawable(roundedRect(p.bgSheet, dp(a, 24), p.hairline, dp(a, 1)));

        TextView title = new TextView(a);
        title.setText(isEdit ? "编辑 Emby" : "连接 Emby 媒体库");
        title.setTextSize(18f);
        title.setTypeface(null, Typeface.BOLD);
        title.setTextColor(p.textPrimary);
        card.addView(title);

        TextView subtitle = new TextView(a);
        subtitle.setText("支持 HTTP (8096) / HTTPS (8920) 与反代子路径");
        subtitle.setTextSize(12.5f);
        subtitle.setTextColor(p.textSecondary);
        subtitle.setPadding(0, dp(a, 4), 0, dp(a, 12));
        card.addView(subtitle);

        ScrollView scroll = new ScrollView(a);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(form, new FrameLayout.LayoutParams(-1, -2));
        card.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1f));

        LinearLayout btnRow = new LinearLayout(a);
        btnRow.setOrientation(LinearLayout.HORIZONTAL);
        btnRow.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        btnRow.setPadding(0, dp(a, 8), 0, 0);

        Button cancel = actionButton(a, p, "取消", false);
        cancel.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        dlg.dismiss();
                    }
                });
        LinearLayout.LayoutParams cancelLp = new LinearLayout.LayoutParams(-2, dp(a, 40));
        cancelLp.rightMargin = dp(a, 10);
        btnRow.addView(cancel, cancelLp);
        btnRow.addView(submitBtn, new LinearLayout.LayoutParams(-2, dp(a, 40)));
        card.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));

        dlg.setContentView(card);
        Window win = dlg.getWindow();
        if (win != null) {
            win.getDecorView().setTag("app-dialog");
            win.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            DisplayMetrics dm = a.getResources().getDisplayMetrics();
            int w = Math.min(dm.widthPixels - dp(a, 32), dp(a, 440));
            win.setLayout(w, WindowManager.LayoutParams.WRAP_CONTENT);
            win.setGravity(Gravity.CENTER);
            win.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams attrs = win.getAttributes();
            attrs.dimAmount = p.isDark ? 0.64f : 0.42f;
            win.setAttributes(attrs);
            win.setSoftInputMode(
                    WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                            | WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN);
        }
        dlg.show();
    }

    private static void dismissDialogOrSheet(
            Dialog dlg, MobileBottomSheet.SheetHandle sheetHandle) {
        if (sheetHandle != null) {
            sheetHandle.dismiss();
        }
        if (dlg != null && dlg.isShowing()) {
            dlg.dismiss();
        }
    }

    private static Switch addSwitchCard(
            Activity a,
            MobileTheme.Palette p,
            LinearLayout parent,
            String sectionLabel,
            String rowLabel,
            boolean checked) {
        TextView lbl = new TextView(a);
        lbl.setText(sectionLabel);
        lbl.setTextSize(12.5f);
        lbl.setTextColor(p.textSecondary);
        lbl.setPadding(dp(a, 2), 0, 0, dp(a, 4));
        parent.addView(lbl);

        LinearLayout row = new LinearLayout(a);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(a, 14), dp(a, 10), dp(a, 12), dp(a, 10));
        row.setBackgroundDrawable(roundedRect(p.bgSubtle, dp(a, 14), p.hairline, dp(a, 1)));

        TextView title = new TextView(a);
        title.setText(rowLabel);
        title.setTextSize(14f);
        title.setTextColor(p.textPrimary);
        row.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        Switch sw = new Switch(a);
        sw.setChecked(checked);
        row.addView(sw, new LinearLayout.LayoutParams(-2, -2));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = dp(a, 10);
        parent.addView(row, lp);
        return sw;
    }

    private static EditText addLabeledField(
            Activity a,
            final MobileTheme.Palette p,
            LinearLayout parent,
            String label,
            String initialValue,
            String hint,
            final int inputType,
            boolean passwordToggle) {
        TextView lbl = new TextView(a);
        lbl.setText(label);
        lbl.setTextSize(12.5f);
        lbl.setTextColor(p.textSecondary);
        lbl.setPadding(dp(a, 2), 0, 0, dp(a, 4));
        parent.addView(lbl);

        LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.HORIZONTAL);
        box.setGravity(Gravity.CENTER_VERTICAL);
        box.setBackgroundDrawable(roundedRect(p.bgSubtle, dp(a, 14), p.hairline, dp(a, 1)));

        final EditText field = new EditText(a);
        field.setSingleLine(true);
        field.setInputType(inputType);
        if (initialValue != null && !initialValue.isEmpty()) {
            field.setText(initialValue);
        }
        field.setHint(hint);
        field.setTextColor(p.textPrimary);
        field.setHintTextColor(p.textTertiary);
        field.setTextSize(14f);
        field.setBackgroundDrawable(null);
        field.setPadding(dp(a, 14), dp(a, 11), dp(a, passwordToggle ? 4 : 14), dp(a, 11));
        box.addView(field, new LinearLayout.LayoutParams(0, -2, 1f));

        if (passwordToggle) {
            final boolean[] visible = new boolean[] {false};
            final TextView eyeBtn = new TextView(a);
            eyeBtn.setText("显示");
            eyeBtn.setTextSize(12.5f);
            eyeBtn.setTypeface(null, Typeface.BOLD);
            eyeBtn.setTextColor(p.accent);
            eyeBtn.setPadding(dp(a, 10), dp(a, 10), dp(a, 14), dp(a, 10));
            eyeBtn.setOnClickListener(
                    new View.OnClickListener() {
                        @Override
                        public void onClick(View v) {
                            int pos = field.getSelectionStart();
                            visible[0] = !visible[0];
                            field.setInputType(
                                    visible[0]
                                            ? (InputType.TYPE_CLASS_TEXT
                                                    | InputType
                                                            .TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
                                            : inputType);
                            eyeBtn.setText(visible[0] ? "隐藏" : "显示");
                            if (pos >= 0 && pos <= field.getText().length()) {
                                field.setSelection(pos);
                            }
                        }
                    });
            box.addView(eyeBtn, new LinearLayout.LayoutParams(-2, -2));
        }

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = dp(a, 10);
        parent.addView(box, lp);
        return field;
    }

    @SuppressWarnings("deprecation")
    private static Button actionButton(
            Activity a, MobileTheme.Palette p, String text, boolean primary) {
        Button b = new Button(a);
        b.setText(text);
        b.setAllCaps(false);
        b.setIncludeFontPadding(false);
        b.setTypeface(null, Typeface.BOLD);
        b.setTextSize(14f);
        b.setTextColor(primary ? p.accentOnFill : p.textPrimary);
        b.setPadding(dp(a, 18), 0, dp(a, 18), 0);
        b.setBackgroundDrawable(
                roundedRect(
                        primary ? p.accent : p.bgSubtle,
                        dp(a, 14),
                        primary ? 0 : p.hairline,
                        primary ? 0 : dp(a, 1)));
        return b;
    }
}

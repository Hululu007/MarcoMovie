package com.pilipala.marcomovie;

import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.text.InputType;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.Window;
import android.view.WindowManager;
import android.widget.*;
import java.io.IOException;
import java.util.UUID;
import org.json.*;

/** The subscription holds only the account reference. Tokens stay in app-private preferences. */
public final class MobileEmbyAccounts {
    public interface OnConnected {
        void save(JSONObject site) throws Exception;
    }

    public interface OnOpenSite {
        void open(JSONObject site);
    }

    public static java.util.List<JSONObject> listSaved(Context context) {
        java.util.List<JSONObject> out = new java.util.ArrayList<JSONObject>();
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
                String displayName = session.optString("name", "").trim();
                if (displayName.length() == 0) {
                    displayName = session.optString("base", "Emby");
                }
                JSONObject site =
                        new JSONObject()
                                .put("key", "emby_" + keySuffix)
                                .put("name", "Emby · " + displayName)
                                .put("type", 1)
                                .put("api", k)
                                .put("base", session.optString("base", ""))
                                .put("user", session.optString("user", ""));
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
        java.util.List<JSONObject> saved = listSaved(context);
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

    public static void connect(final Activity a, final OnConnected callback) {
        final Dialog dlg = new Dialog(a);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);

        final LinearLayout card = new LinearLayout(a);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(a, 20), dp(a, 20), dp(a, 20), dp(a, 16));
        GradientDrawable cardBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xf5192220, 0xf8111716});
        cardBg.setCornerRadius(dp(a, 26));
        cardBg.setStroke(Math.max(1, dp(a, 1)), 0x2cffffff);
        card.setBackgroundDrawable(cardBg);

        TextView title = new TextView(a);
        title.setText("连接 Emby 媒体库");
        title.setTextSize(18f);
        title.setTypeface(null, Typeface.BOLD);
        title.setTextColor(0xfff5f5f7);
        card.addView(title);

        TextView subtitle = new TextView(a);
        subtitle.setText("默认使用 HTTP（8096），也支持直接粘贴完整 HTTPS 地址");
        subtitle.setTextSize(12.5f);
        subtitle.setTextColor(0xa8ebebf5);
        subtitle.setPadding(0, dp(a, 4), 0, dp(a, 12));
        card.addView(subtitle);

        final ScrollView scroller = new ScrollView(a);
        final LinearLayout form = new LinearLayout(a);
        form.setOrientation(LinearLayout.VERTICAL);

        final boolean[] useHttps = new boolean[] {false};
        LinearLayout protoRow = new LinearLayout(a);
        protoRow.setOrientation(LinearLayout.HORIZONTAL);
        protoRow.setGravity(Gravity.CENTER_VERTICAL);
        final Button httpBtn = actionButton(a, "HTTP（默认）", true);
        final Button httpsBtn = actionButton(a, "HTTPS", false);
        LinearLayout.LayoutParams protoLp = new LinearLayout.LayoutParams(0, dp(a, 34), 1f);
        protoLp.rightMargin = dp(a, 8);
        protoRow.addView(httpBtn, protoLp);
        protoRow.addView(httpsBtn, new LinearLayout.LayoutParams(0, dp(a, 34), 1f));
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-1, -2);
        rowLp.bottomMargin = dp(a, 10);
        form.addView(protoRow, rowLp);

        final EditText server =
                field(
                        a,
                        form,
                        "服务器域名或 IP（如 emby.example）",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        final EditText portField =
                field(a, form, "端口号（HTTP 默认 8096，HTTPS 默认 443）", InputType.TYPE_CLASS_NUMBER);
        portField.setText("8096");
        final EditText pathField =
                field(
                        a,
                        form,
                        "路径（选填，如 /path，留空自动识别）",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        final EditText user = field(a, form, "用户名", InputType.TYPE_CLASS_TEXT);
        final EditText pass =
                field(
                        a,
                        form,
                        "密码（可留空）",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);

        httpBtn.setOnClickListener(
                new android.view.View.OnClickListener() {
                    public void onClick(android.view.View v) {
                        useHttps[0] = false;
                        styleToggle(a, httpBtn, true);
                        styleToggle(a, httpsBtn, false);
                        if (portField.getText().toString().trim().length() == 0) {
                            portField.setText("8096");
                        }
                    }
                });
        httpsBtn.setOnClickListener(
                new android.view.View.OnClickListener() {
                    public void onClick(android.view.View v) {
                        useHttps[0] = true;
                        styleToggle(a, httpBtn, false);
                        styleToggle(a, httpsBtn, true);
                        if ("8096".equals(portField.getText().toString().trim())) {
                            portField.setText("");
                        }
                    }
                });

        scroller.addView(form);
        card.addView(scroller, new LinearLayout.LayoutParams(-1, 0, 1f));

        final TextView status = new TextView(a);
        status.setTextSize(12.5f);
        status.setTextColor(0xffff9f0a);
        status.setPadding(dp(a, 2), dp(a, 2), dp(a, 2), dp(a, 10));
        card.addView(status);

        LinearLayout btnRow = new LinearLayout(a);
        btnRow.setOrientation(LinearLayout.HORIZONTAL);
        btnRow.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);

        Button cancel = actionButton(a, "取消", false);
        cancel.setOnClickListener(
                new android.view.View.OnClickListener() {
                    public void onClick(android.view.View v) {
                        dlg.dismiss();
                    }
                });
        LinearLayout.LayoutParams cancelLp = new LinearLayout.LayoutParams(-2, dp(a, 38));
        cancelLp.rightMargin = dp(a, 10);
        btnRow.addView(cancel, cancelLp);

        final Button submit = actionButton(a, "连接并保存", true);
        btnRow.addView(submit, new LinearLayout.LayoutParams(-2, dp(a, 38)));
        card.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));

        dlg.setContentView(card);
        Window win = dlg.getWindow();
        if (win != null) {
            win.getDecorView().setTag("app-dialog");
            win.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            DisplayMetrics dm = a.getResources().getDisplayMetrics();
            int w = Math.min(dm.widthPixels - dp(a, 32), dp(a, 420));
            win.setLayout(w, WindowManager.LayoutParams.WRAP_CONTENT);
            win.setGravity(Gravity.CENTER);
            win.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams attrs = win.getAttributes();
            attrs.dimAmount = 0.64f;
            win.setAttributes(attrs);
            win.setSoftInputMode(
                    WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                            | WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN);
        }
        dlg.show();
        submit.setOnClickListener(
                new android.view.View.OnClickListener() {
                    public void onClick(android.view.View v) {
                        final String rawHost = server.getText().toString().trim(),
                                portText = portField.getText().toString().trim(),
                                pathText = pathField.getText().toString().trim(),
                                name = user.getText().toString().trim(),
                                pw = pass.getText().toString();
                        final boolean httpsMode = useHttps[0];
                        if (rawHost.length() == 0 || name.length() == 0) {
                            status.setText("请填写服务器地址和用户名");
                            return;
                        }
                        submit.setEnabled(false);
                        status.setText("正在连接…");
                        final SharedPreferences prefs = a.getSharedPreferences("emby.accounts", 0);
                        String existing = prefs.getString("device", "");
                        if (existing.length() == 0) {
                            existing = UUID.randomUUID().toString();
                            prefs.edit().putString("device", existing).apply();
                        }
                        final String device = existing;
                        new Thread(
                                        new Runnable() {
                                            public void run() {
                                                try {
                                                    final String address =
                                                            MobileEmbyLibrary.composeServerAddress(
                                                                    httpsMode, rawHost, portText,
                                                                    pathText);
                                                    final JSONObject session =
                                                            MobileEmbyLibrary.login(
                                                                    address, name, pw, device);
                                                    final String key =
                                                            MobileEmbyLibrary.accountKey(session);
                                                    final String api =
                                                            MobileEmbyLibrary.PREFIX + key;
                                                    final JSONObject site =
                                                            new JSONObject()
                                                                    .put("key", "emby_" + key)
                                                                    .put("name", "Emby · " + name)
                                                                    .put("type", 1)
                                                                    .put("api", api);
                                                    a.runOnUiThread(
                                                            new Runnable() {
                                                                public void run() {
                                                                    if (!dlg.isShowing()
                                                                            || a.isFinishing())
                                                                        return;
                                                                    String prevSession =
                                                                            prefs.getString(
                                                                                    api, null);
                                                                    try {
                                                                        if (!prefs.edit()
                                                                                .putString(
                                                                                        api,
                                                                                        session
                                                                                                .toString())
                                                                                .commit())
                                                                            throw new IOException(
                                                                                    "无法保存 Emby 登录状态");
                                                                        callback.save(site);
                                                                        pass.setText("");
                                                                        dlg.dismiss();
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
                                                                        submit.setEnabled(true);
                                                                        status.setText(
                                                                                ex.getMessage());
                                                                    }
                                                                }
                                                            });
                                                } catch (final Exception ex) {
                                                    a.runOnUiThread(
                                                            new Runnable() {
                                                                public void run() {
                                                                    if (dlg.isShowing()) {
                                                                        submit.setEnabled(true);
                                                                        status.setText(
                                                                                ex.getMessage());
                                                                    }
                                                                }
                                                            });
                                                }
                                            }
                                        },
                                        "emby-login")
                                .start();
                    }
                });
    }

    private static void styleToggle(Activity a, Button b, boolean active) {
        b.setTextColor(active ? Color.WHITE : 0xe6f5f5f7);
        GradientDrawable gd = new GradientDrawable();
        gd.setCornerRadius(dp(a, 999));
        gd.setColor(active ? 0xff0a84ff : 0x22ffffff);
        if (!active) gd.setStroke(Math.max(1, dp(a, 1)), 0x2cffffff);
        b.setBackgroundDrawable(gd);
    }

    private static EditText field(Activity a, LinearLayout parent, String hint, int type) {
        EditText field = new EditText(a);
        field.setSingleLine(true);
        field.setInputType(type);
        field.setHint(hint);
        field.setTextColor(Color.WHITE);
        field.setHintTextColor(0x73ebebf5);
        field.setTextSize(14f);
        field.setPadding(dp(a, 14), dp(a, 11), dp(a, 14), dp(a, 11));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(a, 14));
        bg.setColor(0x20ffffff);
        bg.setStroke(Math.max(1, dp(a, 1)), 0x2effffff);
        field.setBackgroundDrawable(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = dp(a, 10);
        parent.addView(field, lp);
        return field;
    }

    @SuppressWarnings("deprecation")
    private static Button actionButton(Activity a, String text, boolean primary) {
        Button b = new Button(a);
        b.setText(text);
        b.setAllCaps(false);
        b.setIncludeFontPadding(false);
        b.setTypeface(null, Typeface.BOLD);
        b.setTextSize(13.5f);
        b.setTextColor(primary ? Color.WHITE : 0xe6f5f5f7);
        b.setPadding(dp(a, 18), 0, dp(a, 18), 0);
        GradientDrawable gd = new GradientDrawable();
        gd.setCornerRadius(dp(a, 999));
        gd.setColor(primary ? 0xff0a84ff : 0x22ffffff);
        if (!primary) gd.setStroke(Math.max(1, dp(a, 1)), 0x2cffffff);
        b.setBackgroundDrawable(gd);
        return b;
    }
}

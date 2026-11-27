package com.pilipala.emby;

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
public final class EmbyAccounts {
    public interface OnConnected {
        void save(JSONObject site) throws Exception;
    }

    public static EmbyLibrary open(Context context, String api) throws Exception {
        if (!api.startsWith(EmbyLibrary.PREFIX)) throw new IOException("Emby 来源无效");
        String raw = context.getSharedPreferences("emby.accounts", 0).getString(api, "");
        if (raw.length() == 0) throw new IOException("请在本机重新登录 Emby");
        return new EmbyLibrary(new JSONObject(raw));
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
        subtitle.setText("输入家庭 NAS 或远程 Emby 服务器地址与账号凭据");
        subtitle.setTextSize(12.5f);
        subtitle.setTextColor(0xa8ebebf5);
        subtitle.setPadding(0, dp(a, 4), 0, dp(a, 14));
        card.addView(subtitle);

        final EditText server =
                field(
                        a,
                        card,
                        "https://emby.example:8920",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        final EditText user = field(a, card, "用户名", InputType.TYPE_CLASS_TEXT);
        final EditText pass =
                field(
                        a,
                        card,
                        "密码（可留空）",
                        InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);

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
                        final String address = server.getText().toString().trim(),
                                name = user.getText().toString().trim(),
                                pw = pass.getText().toString();
                        if (address.length() == 0 || name.length() == 0) {
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
                                                    final JSONObject session =
                                                            EmbyLibrary.login(
                                                                    address, name, pw, device);
                                                    final String key =
                                                            EmbyLibrary.accountKey(session);
                                                    final String api = EmbyLibrary.PREFIX + key;
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
                                                                    } catch (Exception ex) {
                                                                        submit.setEnabled(true);
                                                                        status.setText(
                                                                                ex.getMessage());
                                                                    }
                                                                }
                                                            });
                                                } catch (Exception ex) {
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

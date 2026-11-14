package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.util.Collections;

/** 10-foot TV Wireless Cast screen reachable from the Home Dock ("nav-cast"). */
final class CastScreen {
    final MainActivity a;
    TextView liveStatusView;

    CastScreen(MainActivity activity) {
        a = activity;
    }

    void show() {
        a.renderPage("无线投屏", "WIRELESS CAST");
        a.body.setTag("cast-screen");
        if (a.privateMode) {
            a.paragraph("当前处于隐私空间，所有局域网广播与远程接收已严格隔离关闭。退出隐私空间后即可使用无线投屏。");
            Button backBtn = a.button("返回", "primary", a::onBackPressed);
            a.addButton(a.body, backBtn);
            return;
        }

        boolean enabled = a.prefs.getBoolean(Prefs.CAST_ENABLED, true);
        a.syncCastService();
        CastService svc = a.castService;
        String deviceName = a.prefs.getString(Prefs.CAST_DEVICE_NAME, "Marco Movie 电视端");
        if (deviceName == null || deviceName.trim().isEmpty()) {
            deviceName = "Marco Movie 电视端";
        }

        LinearLayout actions = a.row();
        Button toggleBtn =
                a.button(
                        enabled ? "投屏接收：已开启" : "投屏接收：已关闭",
                        "primary",
                        () -> {
                            boolean next = !a.prefs.getBoolean(Prefs.CAST_ENABLED, true);
                            a.prefs.edit().putBoolean(Prefs.CAST_ENABLED, next).apply();
                            a.syncCastService();
                            a.toast(next ? "已开启无线投屏接收" : "已关闭无线投屏接收");
                            show();
                        });
        a.addButton(actions, toggleBtn);

        final String currentName = deviceName;
        Button renameBtn =
                a.navButton("设备名称：" + currentName, "cast-rename", () -> promptRename(currentName));
        a.addButton(actions, renameBtn);

        Button refreshBtn =
                a.navButton(
                        "重新广播并刷新",
                        "cast-refresh",
                        () -> {
                            a.restartCastService();
                            a.toast("已重新发送局域网投屏广播");
                            show();
                        });
        a.addButton(actions, refreshBtn);

        Button manualBtn = a.navButton("直接输入流地址", "cast-manual-url", this::promptDirectStream);
        a.addButton(actions, manualBtn);
        a.body.addView(actions);
        a.gap(a.body, 14);

        LinearLayout columns = a.row();
        columns.setGravity(Gravity.TOP);

        // Left Card: DLNA / UPnP Video App Cast
        LinearLayout dlnaCard = a.vertical();
        dlnaCard.setPadding(a.dp(22), a.dp(20), a.dp(22), a.dp(20));
        GradientDrawable dlnaBg = a.bg(0xff191b23, 18);
        dlnaBg.setStroke(Math.max(1, a.dp(1)), 0x22ffffff);
        dlnaCard.setBackground(dlnaBg);

        TextView badge =
                a.text(
                        !enabled
                                ? "● 服务已手动关闭"
                                : (svc != null && !svc.closed
                                        ? "● DLNA / UPnP 在线监听中 · 同一局域网可见"
                                        : "● 未检测到局域网连接，请检查 Wi-Fi 或网线"),
                        13,
                        !enabled
                                ? MainActivity.MUTED
                                : (svc != null && !svc.closed ? 0xff66d4cf : 0xffff9f0a));
        badge.setTypeface(null, Typeface.BOLD);
        dlnaCard.addView(badge);
        a.gap(dlnaCard, 10);

        TextView dlnaTitle = a.text("方式一：主流视频 App 一键投屏", 20, MainActivity.WHITE);
        dlnaTitle.setTypeface(null, Typeface.BOLD);
        dlnaCard.addView(dlnaTitle);
        a.gap(dlnaCard, 8);

        TextView nameLabel = a.text("本机投屏名称：" + deviceName, 16, 0xff7cb8ff);
        nameLabel.setTypeface(null, Typeface.BOLD);
        dlnaCard.addView(nameLabel);
        if (svc != null && !svc.lanIp.isEmpty()) {
            TextView ipLabel =
                    a.text(
                            "本机局域网地址：" + svc.lanIp + "  (端口 " + svc.httpPort() + ")",
                            13,
                            MainActivity.MUTED);
            ipLabel.setPadding(0, a.dp(4), 0, 0);
            dlnaCard.addView(ipLabel);
        }
        a.gap(dlnaCard, 14);

        TextView steps =
                a.text(
                        "1. 确保手机、平板或电脑与本电视连接同一个路由器 / Wi-Fi。\n"
                                + "2. 打开哔哩哔哩、腾讯视频、爱奇艺、优酷、夸克网盘、抖音或本地视频播放器，点击播放画面右上角的「TV」投屏图标。\n"
                                + "3. 在搜索到的设备列表中选择「"
                                + deviceName
                                + "」，即可在大屏播放并通过手机控制进度与音量。",
                        14,
                        0xffd4d7e2);
        steps.setLineSpacing(a.dp(5), 1f);
        dlnaCard.addView(steps);
        a.gap(dlnaCard, 14);

        liveStatusView =
                a.text(
                        svc != null
                                ? "当前状态：" + svc.lastClientInfo
                                : (enabled ? "当前状态：等待局域网连接…" : "当前状态：投屏接收已关闭"),
                        13,
                        MainActivity.MUTED);
        liveStatusView.setTag("cast-live-status");
        dlnaCard.addView(liveStatusView);

        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 1.15f);
        leftLp.rightMargin = a.dp(18);
        columns.addView(dlnaCard, leftLp);

        // Right Card: QR Code Browser Direct Cast & Remote Control
        LinearLayout qrCard = a.vertical();
        qrCard.setGravity(Gravity.CENTER_HORIZONTAL);
        qrCard.setPadding(a.dp(22), a.dp(20), a.dp(22), a.dp(20));
        GradientDrawable qrBg = a.bg(0xff191b23, 18);
        qrBg.setStroke(Math.max(1, a.dp(1)), 0x22ffffff);
        qrCard.setBackground(qrBg);

        TextView qrTitle = a.text("方式二：扫码网页直投 & 手机遥控", 19, MainActivity.WHITE);
        qrTitle.setTypeface(null, Typeface.BOLD);
        qrCard.addView(qrTitle);
        a.gap(qrCard, 6);

        TextView qrDesc = a.text("手机相机或浏览器扫码，直接推送 m3u8 / mp4 视频链接并遥控播放", 13, MainActivity.MUTED);
        qrDesc.setGravity(Gravity.CENTER);
        qrCard.addView(qrDesc);
        a.gap(qrCard, 14);

        String webUrl = svc != null && enabled ? svc.webCastUrl() : "";
        if (!webUrl.isEmpty()) {
            try {
                int px = a.dp(158);
                BitMatrix matrix = new QRCodeWriter().encode(webUrl, BarcodeFormat.QR_CODE, px, px);
                int[] pixels = new int[px * px];
                for (int y = 0; y < px; y++) {
                    for (int x = 0; x < px; x++) {
                        pixels[y * px + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
                    }
                }
                ImageView qr = new ImageView(a);
                qr.setTag("cast-qr");
                qr.setContentDescription("扫码无线投屏二维码");
                qr.setImageBitmap(Bitmap.createBitmap(pixels, px, px, Bitmap.Config.ARGB_8888));
                qr.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(8));
                qr.setBackground(a.bg(Color.WHITE, 12));
                qrCard.addView(qr, new LinearLayout.LayoutParams(px + a.dp(16), px + a.dp(16)));
                a.gap(qrCard, 10);
                TextView urlLabel = a.text(webUrl, 11.5f, 0xff7cb8ff);
                urlLabel.setTag("cast-web-url");
                urlLabel.setGravity(Gravity.CENTER);
                qrCard.addView(urlLabel);
            } catch (Exception ignored) {
                qrCard.addView(a.text("二维码生成失败，请点击上方重新广播并刷新", 13, MainActivity.MUTED));
            }
        } else {
            TextView offHint =
                    a.text(
                            enabled ? "连接局域网后将自动生成投屏二维码" : "开启投屏接收后可显示扫码直投二维码",
                            14,
                            MainActivity.MUTED);
            offHint.setGravity(Gravity.CENTER);
            offHint.setPadding(a.dp(12), a.dp(36), a.dp(12), a.dp(36));
            qrCard.addView(offHint);
        }

        LinearLayout.LayoutParams rightLp = new LinearLayout.LayoutParams(0, -2, 0.85f);
        columns.addView(qrCard, rightLp);
        a.body.addView(columns, new LinearLayout.LayoutParams(-1, -2));
    }

    void refreshLiveStatus() {
        if (liveStatusView != null && a.castService != null) {
            liveStatusView.setText("当前状态：" + a.castService.lastClientInfo);
        }
    }

    private void promptRename(String currentName) {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(8), a.dp(6), a.dp(8), a.dp(4));
        final EditText edit = new EditText(a);
        edit.setSingleLine(true);
        edit.setText(currentName);
        edit.setSelection(edit.getText().length());
        edit.setHint("例如：客厅电视 · Marco Movie");
        edit.setTextColor(MainActivity.WHITE);
        edit.setHintTextColor(MainActivity.MUTED);
        edit.setBackground(a.bg(0xff262832, 10));
        edit.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        box.addView(edit, new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("修改投屏设备名称")
                .setView(box)
                .setPositiveButton(
                        "保存",
                        (d, w) -> {
                            String next =
                                    SearchInputServer.sanitizeKeyword(
                                            edit.getText() == null
                                                    ? ""
                                                    : edit.getText().toString());
                            if (next.isEmpty()) next = "Marco Movie 电视端";
                            a.prefs.edit().putString(Prefs.CAST_DEVICE_NAME, next).apply();
                            if (a.castService != null) a.castService.updateFriendlyName(next);
                            a.toast("投屏名称已更新为：" + next);
                            show();
                        })
                .setNegativeButton("取消", null)
                .show();
    }

    private void promptDirectStream() {
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(8), a.dp(6), a.dp(8), a.dp(4));
        final EditText edit = new EditText(a);
        edit.setSingleLine(true);
        edit.setHint("https://media.example/video.m3u8");
        edit.setTextColor(MainActivity.WHITE);
        edit.setHintTextColor(MainActivity.MUTED);
        edit.setBackground(a.bg(0xff262832, 10));
        edit.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        box.addView(edit, new LinearLayout.LayoutParams(-1, -2));
        new AppDialog.Builder(a)
                .setTitle("播放网络流地址")
                .setView(box)
                .setPositiveButton(
                        "立即播放",
                        (d, w) -> {
                            String valid =
                                    CastService.validateCastMediaUrl(
                                            edit.getText() == null
                                                    ? ""
                                                    : edit.getText().toString());
                            if (valid.isEmpty()) {
                                a.toast("请输入有效的 HTTP / HTTPS 视频流地址");
                                return;
                            }
                            if (a.castService != null) {
                                a.castService.bridge.openMedia(
                                        valid, "网络直链播放", Collections.emptyMap(), 0);
                            } else {
                                Cms.Site castSite = new Cms.Site();
                                castSite.key = "cast";
                                castSite.originalKey = "cast";
                                castSite.name = "无线投屏";
                                castSite.type = 1;
                                Cms.Video v = new Cms.Video();
                                v.id = "cast:" + valid;
                                v.title = "网络直链播放";
                                Cms.Episode ep = new Cms.Episode();
                                ep.name = v.title;
                                ep.url = valid;
                                a.activeLine = null;
                                a.activeEpisode = null;
                                a.playingBookmark = null;
                                a.resumeAt = 0;
                                a.openPlayer(castSite, v, ep);
                            }
                        })
                .setNegativeButton("取消", null)
                .show();
    }
}

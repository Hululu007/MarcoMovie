package com.pilipala.marcomovie;

import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Native Android Mobile UI for:
 *
 * <ol>
 *   <li>One-scan QR Login Sheet with same-device netdisk App deep-link jump, lifecycle resume
 *       immediate polling ({@link #onActivityResumed()}), credential writing, and {@link
 *       ConfigCenterBridge#syncAll} push (Item 1: 原 2B/4/5).
 *   <li>Manual Cookie/Token Config Sheet & Local/LAN QR Config Web Server Sheet (Item 1 paths 2–4).
 *   <li>Personal Netdisk File Browser ("我的云盘 → 我的文件") with subfolder navigation, breadcrumb
 *       bar, incremental pagination, page-2 auth-expired preservation of page-1 items with inline
 *       re-auth + retry banner, Favorites, and direct playback with seek & resume (Item 2: 原 12).
 * </ol>
 */
final class PersonalNetdiskBrowser {
    private static volatile Runnable activeQrResumeHook;
    private static volatile CloudMediaProxy.Lease activeCloudLease;
    private static volatile CloudMediaProxy.Lease pendingCloudLease;

    private PersonalNetdiskBrowser() {}

    /** Invoked by {@link MainActivity#onResume()} to resume QR polling immediately on return. */
    static void onActivityResumed() {
        Runnable hook = activeQrResumeHook;
        if (hook != null) {
            try {
                hook.run();
            } catch (Throwable ignored) {
            }
        }
    }

    private static void revokeQuietly(CloudMediaProxy.Lease lease) {
        if (lease == null) return;
        try {
            CloudMediaProxy.shared().releaseLease(lease);
        } catch (Throwable ignored) {
            lease.revoke();
        }
    }

    static synchronized void stagePendingLease(CloudMediaProxy.Lease lease) {
        CloudMediaProxy.Lease oldPending = pendingCloudLease;
        pendingCloudLease = lease;
        if (oldPending != null && oldPending != lease && oldPending != activeCloudLease) {
            revokeQuietly(oldPending);
        }
    }

    static synchronized void releaseActiveLease() {
        releaseActiveLeaseExcept("");
    }

    static synchronized void releaseActiveLeaseExcept(String keepLeaseId) {
        String keep = keepLeaseId == null ? "" : keepLeaseId;
        CloudMediaProxy.Lease cur = activeCloudLease;
        if (cur != null && !keep.equals(cur.id)) {
            activeCloudLease = null;
            revokeQuietly(cur);
        }
        CloudMediaProxy.Lease pend = pendingCloudLease;
        if (pend != null && !keep.equals(pend.id)) {
            pendingCloudLease = null;
            revokeQuietly(pend);
        }
    }

    static synchronized boolean adoptLeaseIfMatching(String leaseId) {
        if (leaseId == null || leaseId.isEmpty()) return false;
        CloudMediaProxy.Lease pend = pendingCloudLease;
        if (pend != null && leaseId.equals(pend.id)) {
            pendingCloudLease = null;
            CloudMediaProxy.Lease old = activeCloudLease;
            activeCloudLease = pend;
            if (old != null && old != pend) revokeQuietly(old);
            return true;
        }
        return activeCloudLease != null && leaseId.equals(activeCloudLease.id);
    }

    static CloudMediaProxy.Lease currentActiveLease() {
        return activeCloudLease;
    }

    static CloudMediaProxy.Lease currentPendingLease() {
        return pendingCloudLease;
    }

    // =========================================================================
    // 1. Native QR Login Sheet (One-Scan Reuse + Resume Polling)
    // =========================================================================

    static void showQrLoginSheet(
            final MainActivity a, final String driveKey, final Runnable onSuccess) {
        if (a == null || a.isFinishing()) return;
        final String provider = NetdiskStore.normalizeDriveKey(driveKey);
        if (provider.isEmpty()) return;

        final MobileTheme.Palette p = MobileTheme.of(a);
        final NetdiskAuthService authService = new NetdiskAuthService();
        final AtomicBoolean closed = new AtomicBoolean(false);
        final AtomicBoolean polling = new AtomicBoolean(false);
        final AtomicBoolean resumedRetry = new AtomicBoolean(false);
        final AtomicInteger attemptSeq = new AtomicInteger(0);
        final AtomicReference<NetdiskAuthService.QrSession> sessionRef = new AtomicReference<>();

        LinearLayout content = a.vertical();
        content.setGravity(Gravity.CENTER_HORIZONTAL);
        content.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(8));

        final TextView statusTv =
                a.text(
                        "正在生成 " + NetdiskStore.displayName(provider) + " 登录二维码…",
                        13.5f,
                        p.textSecondary);
        statusTv.setGravity(Gravity.CENTER);
        content.addView(statusTv, new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        final ImageView qrImg = new ImageView(a);
        int qrSize = a.dp(200);
        qrImg.setPadding(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
        qrImg.setBackground(a.bg(Color.WHITE, 14));
        content.addView(qrImg, new LinearLayout.LayoutParams(qrSize + a.dp(20), qrSize + a.dp(20)));
        a.gap(content, 12);

        TextView tipTv =
                a.text("扫码一次后将自动保存至「我的云盘」并同步给已识别订阅配置中心；切回应用后将自动继续检测登录状态。", 12f, p.textSecondary);
        tipTv.setGravity(Gravity.CENTER);
        tipTv.setLineSpacing(a.dp(2), 1f);
        content.addView(tipTv, new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 14);

        LinearLayout btnRow = a.row();
        btnRow.setGravity(Gravity.CENTER);

        final TextView openAppBtn = buildPillBtn(a, "打开网盘 App", true);
        LinearLayout.LayoutParams openLp = new LinearLayout.LayoutParams(0, a.dp(40), 1f);
        openLp.rightMargin = a.dp(8);
        btnRow.addView(openAppBtn, openLp);

        final TextView checkBtn = buildPillBtn(a, "检查登录状态", false);
        LinearLayout.LayoutParams checkLp = new LinearLayout.LayoutParams(0, a.dp(40), 1f);
        checkLp.rightMargin = a.dp(8);
        btnRow.addView(checkBtn, checkLp);

        final TextView refreshBtn = buildPillBtn(a, "刷新二维码", false);
        btnRow.addView(refreshBtn, new LinearLayout.LayoutParams(0, a.dp(40), 1f));
        content.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));

        final MobileBottomSheet.SheetHandle[] handleBox = new MobileBottomSheet.SheetHandle[1];

        final Runnable[] pollTask = new Runnable[1];
        final Runnable[] startSessionTask = new Runnable[1];

        pollTask[0] =
                new Runnable() {
                    @Override
                    public void run() {
                        if (closed.get() || a.isFinishing()) return;
                        final NetdiskAuthService.QrSession sess = sessionRef.get();
                        final int seq = attemptSeq.get();
                        if (sess == null) return;
                        if (!polling.compareAndSet(false, true)) return;
                        a.worker.execute(
                                () -> {
                                    NetdiskAuthService.PollResult res =
                                            authService.pollQrSession(sess);
                                    polling.set(false);
                                    if (closed.get()
                                            || a.isFinishing()
                                            || seq != attemptSeq.get()) {
                                        return;
                                    }
                                    if (res.isConfirmed()) {
                                        NetdiskStore.setCredential(
                                                a, provider, res.credential, res.ownerId);
                                        ConfigCenterBridge.pushAuthorizedDrives(
                                                a,
                                                a.config,
                                                java.util.Collections.singletonList(provider),
                                                false);
                                        a.ui.post(
                                                () -> {
                                                    if (closed.get()) return;
                                                    closed.set(true);
                                                    activeQrResumeHook = null;
                                                    if (handleBox[0] != null)
                                                        handleBox[0].dismiss();
                                                    a.toast(
                                                            NetdiskStore.displayName(provider)
                                                                    + "登录成功，已同步至我的云盘与配置中心");
                                                    if (onSuccess != null) onSuccess.run();
                                                });
                                        return;
                                    }
                                    a.ui.post(
                                            () -> {
                                                if (closed.get() || seq != attemptSeq.get()) return;
                                                if (NetdiskAuthService.STATE_EXPIRED.equals(
                                                        res.state)) {
                                                    statusTv.setText(res.message);
                                                    return;
                                                }
                                                if (res.message != null && !res.message.isEmpty()) {
                                                    statusTv.setText(res.message);
                                                }
                                                long delayMs =
                                                        resumedRetry.getAndSet(false) ? 80L : 3000L;
                                                a.ui.postDelayed(pollTask[0], delayMs);
                                            });
                                });
                    }
                };

        final Runnable triggerImmediateResumePoll =
                () -> {
                    if (closed.get() || a.isFinishing() || sessionRef.get() == null) return;
                    if (polling.get()) {
                        resumedRetry.set(true);
                        if (NetdiskStore.DRIVE_BAIDU.equals(provider)) {
                            authService.abortBaiduLongPoll();
                        }
                    } else {
                        a.ui.removeCallbacks(pollTask[0]);
                        a.ui.post(pollTask[0]);
                    }
                };

        activeQrResumeHook = triggerImmediateResumePoll;

        startSessionTask[0] =
                () -> {
                    final int seq = attemptSeq.incrementAndGet();
                    sessionRef.set(null);
                    resumedRetry.set(false);
                    statusTv.setText("正在获取最新二维码…");
                    a.worker.execute(
                            () -> {
                                try {
                                    NetdiskAuthService.QrSession sess =
                                            authService.startQrSession(provider);
                                    Bitmap bmp = renderLocalQr(sess.qrUrl, qrSize);
                                    a.ui.post(
                                            () -> {
                                                if (closed.get() || seq != attemptSeq.get()) return;
                                                sessionRef.set(sess);
                                                if (bmp != null) qrImg.setImageBitmap(bmp);
                                                statusTv.setText(
                                                        "请使用"
                                                                + NetdiskStore.displayName(provider)
                                                                + " App 扫码或点击下方按钮跳转授权");
                                                a.ui.removeCallbacks(pollTask[0]);
                                                a.ui.postDelayed(pollTask[0], 1500L);
                                            });
                                } catch (Exception e) {
                                    a.ui.post(
                                            () -> {
                                                if (closed.get() || seq != attemptSeq.get()) return;
                                                statusTv.setText("获取二维码失败：" + a.message(e));
                                            });
                                }
                            });
                };

        openAppBtn.setOnClickListener(
                v -> {
                    NetdiskAuthService.QrSession sess = sessionRef.get();
                    if (sess == null) return;
                    boolean opened = false;
                    for (String deepLink :
                            NetdiskAuthService.buildSameDeviceDeepLinks(provider, sess.qrUrl)) {
                        try {
                            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(deepLink));
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                            a.startActivity(intent);
                            opened = true;
                            break;
                        } catch (Throwable ignored) {
                        }
                    }
                    if (!opened) {
                        try {
                            Intent web = new Intent(Intent.ACTION_VIEW, Uri.parse(sess.qrUrl));
                            web.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                            a.startActivity(web);
                            opened = true;
                        } catch (Throwable ignored) {
                        }
                    }
                    if (!opened) {
                        a.toast("未检测到对应网盘 App，请使用另一台设备扫码");
                    }
                });
        checkBtn.setOnClickListener(v -> triggerImmediateResumePoll.run());
        refreshBtn.setOnClickListener(v -> startSessionTask[0].run());

        handleBox[0] =
                MobileBottomSheet.showCustom(
                        a,
                        NetdiskStore.displayName(provider) + " · 扫码登录",
                        content,
                        () -> {
                            closed.set(true);
                            a.ui.removeCallbacks(pollTask[0]);
                            if (activeQrResumeHook == triggerImmediateResumePoll) {
                                activeQrResumeHook = null;
                            }
                            authService.abortBaiduLongPoll();
                        });
        startSessionTask[0].run();
    }

    // =========================================================================
    // 1b. Dedicated Visual Netdisk Priority Order Sheet ("切换盘序")
    // =========================================================================

    static void showDriveOrderSheet(final MainActivity a, final Runnable onSaved) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final List<String> working = new ArrayList<>(NetdiskStore.getOrder(a));

        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));

        TextView note =
                a.text(
                        "同一片源包含多个网盘线路时，将按以下顺序排列并默认优先拉取播放；已有观看续播记录或该源单独设置过默认线路时仍优先尊重。",
                        12f,
                        p.textSecondary);
        note.setLineSpacing(a.dp(2), 1f);
        box.addView(note);
        a.gap(box, 10);

        final TextView previewTv = a.text(NetdiskStore.formatOrderBanner(working), 13f, p.accent);
        previewTv.setTypeface(null, Typeface.BOLD);
        previewTv.setSingleLine(true);
        previewTv.setEllipsize(TextUtils.TruncateAt.END);
        previewTv.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        previewTv.setBackground(
                MobileTheme.outlinedBg(
                        a,
                        MobileTheme.withAlpha(p.accent, p.isDark ? 0x26 : 0x16),
                        MobileTheme.withAlpha(p.accent, p.isDark ? 0x66 : 0x44),
                        12));
        box.addView(previewTv, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 10);

        final LinearLayout listBox = a.vertical();
        box.addView(listBox, new LinearLayout.LayoutParams(-1, -2));

        final Runnable[] rebuild = new Runnable[1];
        rebuild[0] =
                () -> {
                    previewTv.setText(NetdiskStore.formatOrderBanner(working));
                    listBox.removeAllViews();
                    for (int i = 0; i < working.size(); i++) {
                        final int idx = i;
                        final String driveKey = working.get(i);
                        final boolean isFirst = (i == 0);
                        final boolean logged = AccountPanel.isDriveLoggedIn(a, driveKey);

                        LinearLayout row = a.row();
                        row.setTag("drive-order-row-" + driveKey);
                        row.setGravity(Gravity.CENTER_VERTICAL);
                        row.setPadding(a.dp(12), a.dp(11), a.dp(10), a.dp(11));
                        row.setBackground(
                                MobileTheme.outlinedBg(
                                        a,
                                        p.bgCard,
                                        isFirst
                                                ? MobileTheme.withAlpha(
                                                        p.accent, p.isDark ? 0x80 : 0x60)
                                                : p.hairline,
                                        14));

                        TextView rankBadge =
                                a.text(
                                        String.valueOf(i + 1),
                                        12.5f,
                                        isFirst ? p.accentOnFill : p.textSecondary);
                        rankBadge.setTypeface(null, Typeface.BOLD);
                        rankBadge.setGravity(Gravity.CENTER);
                        rankBadge.setBackground(
                                isFirst ? a.bg(p.accent, 999) : MobileTheme.subtleBg(a, 999));
                        LinearLayout.LayoutParams rbLp =
                                new LinearLayout.LayoutParams(a.dp(26), a.dp(26));
                        rbLp.rightMargin = a.dp(10);
                        row.addView(rankBadge, rbLp);

                        LinearLayout info = a.vertical();
                        LinearLayout titleLine = a.row();
                        titleLine.setGravity(Gravity.CENTER_VERTICAL);
                        TextView nameTv =
                                a.text(NetdiskStore.displayName(driveKey), 14.5f, p.textPrimary);
                        nameTv.setTypeface(null, Typeface.BOLD);
                        nameTv.setSingleLine(true);
                        titleLine.addView(nameTv);

                        TextView statusTv =
                                a.text(
                                        logged ? "已登录" : "未登录",
                                        10.5f,
                                        logged ? p.success : p.textTertiary);
                        statusTv.setTypeface(null, Typeface.BOLD);
                        statusTv.setPadding(a.dp(7), a.dp(2), a.dp(7), a.dp(2));
                        statusTv.setBackground(
                                logged
                                        ? a.bg(
                                                MobileTheme.withAlpha(
                                                        p.success, p.isDark ? 0x2A : 0x1A),
                                                999)
                                        : MobileTheme.subtleBg(a, 999));
                        LinearLayout.LayoutParams stLp = new LinearLayout.LayoutParams(-2, -2);
                        stLp.leftMargin = a.dp(6);
                        titleLine.addView(statusTv, stLp);
                        info.addView(titleLine);

                        TextView aliasTv =
                                a.text(
                                        driveOrderSubtitle(driveKey, isFirst),
                                        11.5f,
                                        isFirst ? p.accent : p.textSecondary);
                        aliasTv.setSingleLine(true);
                        aliasTv.setEllipsize(TextUtils.TruncateAt.END);
                        aliasTv.setPadding(0, a.dp(2), 0, 0);
                        info.addView(aliasTv);
                        row.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

                        LinearLayout actions = a.row();
                        actions.setGravity(Gravity.CENTER_VERTICAL);
                        if (i > 1) {
                            TextView topBtn = buildOrderActionPill(a, "置顶", false);
                            topBtn.setOnClickListener(
                                    v -> {
                                        List<String> next =
                                                NetdiskStore.moveDriveInOrder(working, idx, 0);
                                        working.clear();
                                        working.addAll(next);
                                        rebuild[0].run();
                                    });
                            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                            lp.rightMargin = a.dp(5);
                            actions.addView(topBtn, lp);
                        }
                        if (i > 0) {
                            TextView upBtn = buildOrderActionPill(a, "上移", true);
                            upBtn.setOnClickListener(
                                    v -> {
                                        List<String> next =
                                                NetdiskStore.moveDriveInOrder(
                                                        working, idx, idx - 1);
                                        working.clear();
                                        working.addAll(next);
                                        rebuild[0].run();
                                    });
                            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                            lp.rightMargin = i < working.size() - 1 ? a.dp(5) : 0;
                            actions.addView(upBtn, lp);
                        }
                        if (i < working.size() - 1) {
                            TextView downBtn = buildOrderActionPill(a, "下移", false);
                            downBtn.setOnClickListener(
                                    v -> {
                                        List<String> next =
                                                NetdiskStore.moveDriveInOrder(
                                                        working, idx, idx + 1);
                                        working.clear();
                                        working.addAll(next);
                                        rebuild[0].run();
                                    });
                            actions.addView(downBtn, new LinearLayout.LayoutParams(-2, -2));
                        }
                        LinearLayout.LayoutParams actLp = new LinearLayout.LayoutParams(-2, -2);
                        actLp.leftMargin = a.dp(6);
                        row.addView(actions, actLp);

                        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-1, -2);
                        rowLp.bottomMargin = a.dp(8);
                        listBox.addView(row, rowLp);
                    }
                };
        rebuild[0].run();
        a.gap(box, 6);

        LinearLayout footer = a.row();
        footer.setGravity(Gravity.CENTER_VERTICAL);
        TextView resetBtn = buildPillBtn(a, "恢复默认", false);
        LinearLayout.LayoutParams resetLp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
        resetLp.rightMargin = a.dp(8);
        footer.addView(resetBtn, resetLp);

        TextView saveBtn = buildPillBtn(a, "保存盘序", true);
        LinearLayout.LayoutParams saveLp = new LinearLayout.LayoutParams(0, a.dp(42), 1.4f);
        footer.addView(saveBtn, saveLp);
        box.addView(footer, new LinearLayout.LayoutParams(-1, -2));

        final MobileBottomSheet.SheetHandle handle =
                MobileBottomSheet.showCustom(a, "切换默认盘序", box, null);

        resetBtn.setOnClickListener(
                v -> {
                    working.clear();
                    working.addAll(NetdiskStore.DEFAULT_ORDER);
                    rebuild[0].run();
                });

        saveBtn.setOnClickListener(
                v -> {
                    NetdiskStore.setOrder(a, working);
                    ConfigCenterBridge.pushAuthorizedDrives(
                            a, a.config, Collections.<String>emptyList(), true);
                    handle.dismiss();
                    a.toast("已保存默认" + NetdiskStore.formatOrderBanner(working));
                    if (onSaved != null) onSaved.run();
                });
    }

    private static String driveOrderSubtitle(String driveKey, boolean isFirst) {
        String alias;
        if (NetdiskStore.DRIVE_QUARK.equals(driveKey)) {
            alias = "夸父 / 夸克线路";
        } else if (NetdiskStore.DRIVE_UC.equals(driveKey)) {
            alias = "优汐 / UC 线路";
        } else if (NetdiskStore.DRIVE_BAIDU.equals(driveKey)) {
            alias = "嘟嘟 / 百度线路";
        } else if (NetdiskStore.DRIVE_ALI.equals(driveKey)) {
            alias = "阿狸 / 阿里线路";
        } else {
            alias = driveKey;
        }
        return isFirst ? ("默认优先 · " + alias) : alias;
    }

    private static TextView buildOrderActionPill(MainActivity a, String label, boolean accent) {
        MobileTheme.Palette p = MobileTheme.of(a);
        TextView tv = a.text(label, 12f, accent ? p.accent : p.textSecondary);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setPadding(a.dp(9), a.dp(5), a.dp(9), a.dp(5));
        tv.setBackground(
                accent
                        ? a.bg(MobileTheme.withAlpha(p.accent, p.isDark ? 0x2B : 0x1A), 999)
                        : MobileTheme.subtleBg(a, 999));
        MobileMotion.bindPress(tv, 0.94f);
        return tv;
    }

    // =========================================================================
    // 2. Manual Credential & Drive Order Sheet (Path 2)
    // =========================================================================

    static void showManualCredentialSheet(
            final MainActivity a, final String preselectDrive, final Runnable onSaved) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));

        TextView note = a.text("仅更新已填写的有效项，留空不会覆盖已登录的账号；保存后自动同步至本机配置中心。", 12f, p.textSecondary);
        note.setLineSpacing(a.dp(2), 1f);
        box.addView(note);
        a.gap(box, 10);

        final Map<String, EditText> inputs = new LinkedHashMap<>();
        String[][] fields = {
            {NetdiskStore.DRIVE_QUARK, "夸克网盘 Cookie", "__pus=...; __puus=..."},
            {NetdiskStore.DRIVE_UC, "UC 网盘 Cookie", "__pus=...; __puus=..."},
            {NetdiskStore.DRIVE_BAIDU, "百度网盘 Cookie", "BDUSS=...; STOKEN=..."},
            {NetdiskStore.DRIVE_ALI, "阿里云盘 Refresh Token", "refresh_token 或 ali_token=..."}
        };
        for (String[] f : fields) {
            String key = f[0];
            boolean logged = NetdiskStore.isLoggedIn(a, key);
            TextView lbl = a.text(f[1] + (logged ? "（已登录 · 留空保留）" : "（未登录）"), 12.5f, p.textPrimary);
            lbl.setTypeface(null, Typeface.BOLD);
            box.addView(lbl);
            a.gap(box, 4);

            EditText et = new EditText(a);
            et.setHint(f[2]);
            et.setHintTextColor(p.textTertiary);
            et.setTextColor(p.textPrimary);
            et.setTextSize(13f);
            et.setSingleLine(false);
            et.setMaxLines(3);
            et.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
            et.setBackground(MobileTheme.subtleBg(a, 12));
            box.addView(et, new LinearLayout.LayoutParams(-1, -2));
            a.gap(box, 10);
            inputs.put(key, et);
            if (key.equals(NetdiskStore.normalizeDriveKey(preselectDrive))) {
                et.requestFocus();
            }
        }

        TextView orderLbl = a.text("网盘优先顺序（逗号分隔：quark,uc,baidu,ali）", 12.5f, p.textPrimary);
        orderLbl.setTypeface(null, Typeface.BOLD);
        box.addView(orderLbl);
        a.gap(box, 4);
        final EditText orderEt = new EditText(a);
        orderEt.setTextColor(p.textPrimary);
        orderEt.setTextSize(13f);
        orderEt.setSingleLine(true);
        orderEt.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
        orderEt.setBackground(MobileTheme.subtleBg(a, 12));
        List<String> curOrder = NetdiskStore.getOrder(a);
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < curOrder.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(curOrder.get(i));
        }
        orderEt.setText(sb.toString());
        box.addView(orderEt, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 14);

        final TextView saveBtn = buildPillBtn(a, "保存并同步配置中心", true);
        box.addView(saveBtn, new LinearLayout.LayoutParams(-1, a.dp(42)));

        final MobileBottomSheet.SheetHandle handle =
                MobileBottomSheet.showCustom(a, "手动配置网盘凭据", box, null);

        saveBtn.setOnClickListener(
                v -> {
                    Map<String, String> submitted = new LinkedHashMap<>();
                    for (Map.Entry<String, EditText> e : inputs.entrySet()) {
                        String val = e.getValue().getText().toString().trim();
                        if (val.isEmpty()) continue;
                        if (!NetdiskStore.isCredentialUsable(e.getKey(), val)) {
                            a.toast(NetdiskStore.displayName(e.getKey()) + " 凭据格式无效");
                            return;
                        }
                        submitted.put(e.getKey(), val);
                    }
                    String orderText = orderEt.getText().toString().trim();
                    ConfigCenterBridge.applyUserSubmission(
                            NetdiskStore.storeFor(a),
                            ConfigCenterBridge.collectRuntimeDirs(a.getApplicationContext(), true),
                            a.config,
                            submitted,
                            orderText);
                    handle.dismiss();
                    a.toast("网盘配置已保存并同步");
                    if (onSaved != null) onSaved.run();
                });
    }

    // =========================================================================
    // 3. Local & LAN QR Config Web Page Sheet (Paths 3 & 4)
    // =========================================================================

    static void showConfigWebServerSheet(final MainActivity a, final Runnable onSubmitted) {
        if (a == null || a.isFinishing()) return;
        try {
            final NetdiskStore.KeyValueStore store = NetdiskStore.storeFor(a);
            final NetdiskConfigWebServer[] serverBox = new NetdiskConfigWebServer[1];
            NetdiskConfigWebServer server =
                    new NetdiskConfigWebServer(
                            (drives, order, remoteAddr) -> {
                                ConfigCenterBridge.SyncReport rep =
                                        ConfigCenterBridge.applyUserSubmission(
                                                store,
                                                ConfigCenterBridge.collectRuntimeDirs(
                                                        a.getApplicationContext(), true),
                                                a.config,
                                                drives,
                                                order);
                                a.ui.post(
                                        () -> {
                                            a.toast("已接收网页提交并同步网盘配置");
                                            if (onSubmitted != null) onSubmitted.run();
                                        });
                                return new NetdiskConfigWebServer.SubmissionResult(
                                        true, "配置已写入本机并同步至我的云盘与配置中心", rep.importedDrives);
                            },
                            store);
            serverBox[0] = server;

            String lanIp = NetdiskConfigWebServer.detectLanIpv4();
            final String localUrl = server.localUrl();
            final String lanUrl = lanIp.isEmpty() ? localUrl : server.lanUrl(lanIp);
            final MobileTheme.Palette p = MobileTheme.of(a);

            LinearLayout box = a.vertical();
            box.setGravity(Gravity.CENTER_HORIZONTAL);
            box.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));

            TextView info =
                    a.text(
                            "本机监听："
                                    + server.getBindAddress()
                                    + ":"
                                    + server.getPort()
                                    + "\n页面路径："
                                    + server.getPagePath()
                                    + "\n回调路径："
                                    + server.getSubmitPath(),
                            11.5f,
                            p.textSecondary);
            info.setGravity(Gravity.CENTER);
            box.addView(info, new LinearLayout.LayoutParams(-1, -2));
            a.gap(box, 10);

            int qrSize = a.dp(180);
            Bitmap bmp = renderLocalQr(lanUrl, qrSize);
            if (bmp != null) {
                ImageView qr = new ImageView(a);
                qr.setImageBitmap(bmp);
                qr.setPadding(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
                qr.setBackground(a.bg(Color.WHITE, 14));
                box.addView(
                        qr, new LinearLayout.LayoutParams(qrSize + a.dp(20), qrSize + a.dp(20)));
                a.gap(box, 10);
            }

            TextView urlTv = a.text("同 Wi-Fi 设备扫码地址：\n" + lanUrl, 12f, p.textPrimary);
            urlTv.setGravity(Gravity.CENTER);
            urlTv.setTextIsSelectable(true);
            box.addView(urlTv, new LinearLayout.LayoutParams(-1, -2));
            a.gap(box, 12);

            TextView openLocalBtn = buildPillBtn(a, "在本机浏览器打开配置网页", true);
            openLocalBtn.setOnClickListener(
                    v -> {
                        try {
                            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(localUrl));
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                            a.startActivity(intent);
                        } catch (Throwable t) {
                            a.toast("无法打开本机浏览器，请复制地址访问");
                        }
                    });
            box.addView(openLocalBtn, new LinearLayout.LayoutParams(-1, a.dp(40)));

            MobileBottomSheet.showCustom(
                    a,
                    "网页 / 局域网扫码配置",
                    box,
                    () -> {
                        if (serverBox[0] != null) serverBox[0].close();
                    });
        } catch (Exception e) {
            a.toast("无法启动网盘配置网页服务：" + a.message(e));
        }
    }

    // =========================================================================
    // 4. Personal Netdisk File Browser ("我的云盘 → 我的文件") — Item 2 (原 12)
    // =========================================================================

    static final class FolderBreadcrumb {
        final String folderId;
        final String title;

        FolderBreadcrumb(String folderId, String title) {
            this.folderId = folderId;
            this.title = title;
        }
    }

    /** Pure-JVM testable paging state preserving page-1 items on page-2 auth expiry. */
    static final class BrowserPagingState {
        final List<PersonalNetdiskLibrary.CloudItem> items = new ArrayList<>();
        int page = 0;
        boolean hasMore = false;
        String nextCursor = "";
        boolean loading = false;
        String inlineError = "";
        boolean inlineRequiresReauth = false;

        void reset() {
            items.clear();
            page = 0;
            hasMore = false;
            nextCursor = "";
            loading = false;
            inlineError = "";
            inlineRequiresReauth = false;
        }

        void applyPageSuccess(PersonalNetdiskLibrary.FolderPage result, boolean replace) {
            if (replace) items.clear();
            items.addAll(result.items);
            page = result.page;
            hasMore = result.hasMore;
            nextCursor = result.nextCursor;
            loading = false;
            inlineError = "";
            inlineRequiresReauth = false;
        }

        /**
         * Preserves all already loaded items (e.g. page 1) when loading page 2+ fails with
         * auth-expired or network error, surfacing an inline re-auth / retry banner instead!
         */
        void applyPageFailure(String message, boolean requiresReauth) {
            loading = false;
            inlineError = message == null ? "读取失败" : message;
            inlineRequiresReauth = requiresReauth;
        }

        boolean shouldShowFullScreenError() {
            return items.isEmpty() && !inlineError.isEmpty();
        }

        boolean shouldShowInlineBanner() {
            return !items.isEmpty() && !inlineError.isEmpty();
        }
    }

    static void openDriveFiles(final MainActivity a, final String rawProvider) {
        if (a == null || a.isFinishing()) return;
        final String provider = NetdiskStore.normalizeDriveKey(rawProvider);
        if (provider.isEmpty()) return;
        if (!NetdiskStore.isLoggedIn(a, provider)) {
            showQrLoginSheet(a, provider, () -> openDriveFiles(a, provider));
            return;
        }
        final List<FolderBreadcrumb> stack = new ArrayList<>();
        stack.add(
                new FolderBreadcrumb(
                        PersonalNetdiskLibrary.rootFolderId(provider),
                        NetdiskStore.displayName(provider) + " · 我的文件"));
        MainActivity.Screen screen =
                new MainActivity.Screen(() -> renderFolderScreen(a, provider, stack));
        screen.focus = "personal-netdisk-browser:" + provider;
        a.open(screen, true);
    }

    private static void renderFolderScreen(
            final MainActivity a, final String provider, final List<FolderBreadcrumb> stack) {
        a.applyMobileSystemBars(false);
        final MobileTheme.Palette p = MobileTheme.of(a);
        final PersonalNetdiskLibrary library = new PersonalNetdiskLibrary(a);
        final BrowserPagingState state = new BrowserPagingState();
        final AtomicInteger loadSeq = new AtomicInteger(0);

        FrameLayout root = new MainActivity.GlassFreezeFrameLayout(a, a.glassFreezeController);
        root.setTag("personal-netdisk-files:" + provider);
        root.setBackgroundColor(p.bgCanvas);
        a.root = root;
        a.setContentView(root);

        LinearLayout outer = a.vertical();
        root.addView(outer, new FrameLayout.LayoutParams(-1, -1));

        // Top nav header
        LinearLayout topNav = a.row();
        topNav.setGravity(Gravity.CENTER_VERTICAL);
        int topInset = Math.max(a.dp(16), a.statusBarHeight());
        topNav.setPadding(a.dp(16), topInset + a.dp(8), a.dp(16), a.dp(10));

        FrameLayout backBtn = new FrameLayout(a);
        backBtn.setBackground(MobileTheme.cardBg(a, 999));
        backBtn.addView(
                MobileIcons.create(a, MobileIcons.IC_BACK, 18f, p.textPrimary),
                new FrameLayout.LayoutParams(a.dp(18), a.dp(18), Gravity.CENTER));
        MobileMotion.bindPress(backBtn, 0.92f);
        LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        backLp.rightMargin = a.dp(12);
        topNav.addView(backBtn, backLp);

        LinearLayout titleCol = a.vertical();
        final TextView crumbTv = a.text("我的云盘", 11.5f, p.textSecondary);
        crumbTv.setSingleLine(true);
        crumbTv.setEllipsize(TextUtils.TruncateAt.START);
        titleCol.addView(crumbTv);

        final TextView titleTv = a.text(stack.get(stack.size() - 1).title, 19f, p.textPrimary);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        titleCol.addView(titleTv);
        topNav.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView reauthHeaderBtn = buildPillBtn(a, "账号", false);
        LinearLayout.LayoutParams raLp = new LinearLayout.LayoutParams(-2, a.dp(32));
        raLp.leftMargin = a.dp(8);
        topNav.addView(reauthHeaderBtn, raLp);
        outer.addView(topNav, new LinearLayout.LayoutParams(-1, -2));

        // Inline banner slot (shown above page-1 items when page 2+ fails!)
        final LinearLayout inlineBannerHost = a.vertical();
        inlineBannerHost.setPadding(a.dp(16), 0, a.dp(16), 0);
        outer.addView(inlineBannerHost, new LinearLayout.LayoutParams(-1, -2));

        // Scrollable file list
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);
        a.scroll = sv;
        final LinearLayout listBody = a.vertical();
        listBody.setPadding(a.dp(16), a.dp(4), a.dp(16), a.navigationBarHeight() + a.dp(32));
        sv.addView(listBody, new ScrollView.LayoutParams(-1, -2));
        outer.addView(sv, new LinearLayout.LayoutParams(-1, 0, 1f));

        final Runnable[] renderList = new Runnable[1];
        final Runnable[] loadPageFn = new Runnable[1];

        final Runnable loadNextOrFirst =
                () -> {
                    final FolderBreadcrumb cur = stack.get(stack.size() - 1);
                    final boolean replace = state.page <= 0;
                    final int targetPage = replace ? 1 : state.page + 1;
                    final String cursor = replace ? "" : state.nextCursor;
                    final int seq = loadSeq.incrementAndGet();
                    state.loading = true;
                    renderList[0].run();
                    a.worker.execute(
                            () -> {
                                try {
                                    PersonalNetdiskLibrary.FolderPage pageResult =
                                            library.listFolder(
                                                    provider, cur.folderId, targetPage, cursor);
                                    a.ui.post(
                                            () -> {
                                                if (seq != loadSeq.get()) return;
                                                state.applyPageSuccess(pageResult, replace);
                                                renderList[0].run();
                                            });
                                } catch (PersonalNetdiskLibrary.PersonalCloudException pce) {
                                    a.ui.post(
                                            () -> {
                                                if (seq != loadSeq.get()) return;
                                                state.applyPageFailure(
                                                        pce.getMessage(), pce.requiresReauth);
                                                renderList[0].run();
                                            });
                                } catch (Exception ex) {
                                    a.ui.post(
                                            () -> {
                                                if (seq != loadSeq.get()) return;
                                                state.applyPageFailure(a.message(ex), false);
                                                renderList[0].run();
                                            });
                                }
                            });
                };
        loadPageFn[0] = loadNextOrFirst;

        renderList[0] =
                () -> {
                    FolderBreadcrumb cur = stack.get(stack.size() - 1);
                    titleTv.setText(cur.title);
                    StringBuilder pathSb = new StringBuilder();
                    for (int i = 0; i < stack.size(); i++) {
                        if (i > 0) pathSb.append(" / ");
                        pathSb.append(stack.get(i).title);
                    }
                    crumbTv.setText(pathSb.toString());

                    inlineBannerHost.removeAllViews();
                    if (state.shouldShowInlineBanner()) {
                        LinearLayout banner = a.vertical();
                        banner.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
                        banner.setBackground(
                                MobileTheme.outlinedBg(
                                        a,
                                        MobileTheme.withAlpha(p.danger, p.isDark ? 0x2E : 0x1A),
                                        MobileTheme.withAlpha(p.danger, 0x66),
                                        14));
                        TextView errTv = a.text(state.inlineError, 12.5f, p.textPrimary);
                        banner.addView(errTv);
                        a.gap(banner, 8);
                        LinearLayout actRow = a.row();
                        if (state.inlineRequiresReauth) {
                            TextView reBtn = buildPillBtn(a, "重新授权", true);
                            reBtn.setOnClickListener(
                                    v ->
                                            showQrLoginSheet(
                                                    a,
                                                    provider,
                                                    () -> {
                                                        state.inlineError = "";
                                                        state.inlineRequiresReauth = false;
                                                        loadPageFn[0].run();
                                                    }));
                            LinearLayout.LayoutParams rlp =
                                    new LinearLayout.LayoutParams(-2, a.dp(34));
                            rlp.rightMargin = a.dp(8);
                            actRow.addView(reBtn, rlp);
                        }
                        TextView retryBtn = buildPillBtn(a, "重试下一页", false);
                        retryBtn.setOnClickListener(v -> loadPageFn[0].run());
                        actRow.addView(retryBtn, new LinearLayout.LayoutParams(-2, a.dp(34)));
                        banner.addView(actRow);
                        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(-1, -2);
                        blp.bottomMargin = a.dp(10);
                        inlineBannerHost.addView(banner, blp);
                    }

                    listBody.removeAllViews();
                    if (state.shouldShowFullScreenError()) {
                        LinearLayout errBox = a.vertical();
                        errBox.setGravity(Gravity.CENTER_HORIZONTAL);
                        errBox.setPadding(a.dp(20), a.dp(48), a.dp(20), a.dp(32));
                        TextView eTv = a.text(state.inlineError, 14f, p.textPrimary);
                        eTv.setGravity(Gravity.CENTER);
                        errBox.addView(eTv);
                        a.gap(errBox, 14);
                        if (state.inlineRequiresReauth) {
                            TextView reBtn = buildPillBtn(a, "重新扫码授权", true);
                            reBtn.setOnClickListener(
                                    v ->
                                            showQrLoginSheet(
                                                    a,
                                                    provider,
                                                    () -> {
                                                        state.reset();
                                                        loadPageFn[0].run();
                                                    }));
                            errBox.addView(reBtn, new LinearLayout.LayoutParams(-2, a.dp(40)));
                            a.gap(errBox, 8);
                        }
                        TextView retryBtn = buildPillBtn(a, "重试", false);
                        retryBtn.setOnClickListener(
                                v -> {
                                    state.reset();
                                    loadPageFn[0].run();
                                });
                        errBox.addView(retryBtn, new LinearLayout.LayoutParams(-2, a.dp(38)));
                        listBody.addView(errBox);
                        return;
                    }

                    if (state.items.isEmpty() && state.loading) {
                        TextView loadingTv = a.text("正在加载网盘目录…", 13.5f, p.textSecondary);
                        loadingTv.setGravity(Gravity.CENTER);
                        loadingTv.setPadding(0, a.dp(48), 0, a.dp(48));
                        listBody.addView(loadingTv, new LinearLayout.LayoutParams(-1, -2));
                        return;
                    }

                    if (state.items.isEmpty()) {
                        TextView emptyTv = a.text("此目录暂无子文件夹或视频文件", 13.5f, p.textSecondary);
                        emptyTv.setGravity(Gravity.CENTER);
                        emptyTv.setPadding(0, a.dp(48), 0, a.dp(48));
                        listBody.addView(emptyTv, new LinearLayout.LayoutParams(-1, -2));
                        return;
                    }

                    LinearLayout card = a.vertical();
                    card.setBackground(MobileTheme.cardBg(a, 16));
                    for (int i = 0; i < state.items.size(); i++) {
                        final PersonalNetdiskLibrary.CloudItem item = state.items.get(i);
                        if (i > 0) {
                            View div = new View(a);
                            div.setBackgroundColor(p.hairline);
                            LinearLayout.LayoutParams dlp =
                                    new LinearLayout.LayoutParams(-1, MobileTheme.hairlinePx(a));
                            dlp.leftMargin = a.dp(56);
                            card.addView(div, dlp);
                        }
                        LinearLayout row = a.row();
                        row.setGravity(Gravity.CENTER_VERTICAL);
                        row.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(12));
                        MobileSectionGroup.bindPressHighlight(row, p.bgPressed);

                        FrameLayout badge =
                                MobileIcons.badge(
                                        a,
                                        item.directory
                                                ? MobileIcons.IC_FOLDER
                                                : MobileIcons.IC_PLAY,
                                        item.directory ? p.accent : p.success,
                                        34,
                                        17);
                        LinearLayout.LayoutParams blp =
                                new LinearLayout.LayoutParams(a.dp(34), a.dp(34));
                        blp.rightMargin = a.dp(12);
                        row.addView(badge, blp);

                        LinearLayout infoCol = a.vertical();
                        TextView nameTv = a.text(item.name, 14.5f, p.textPrimary);
                        nameTv.setTypeface(null, Typeface.BOLD);
                        nameTv.setSingleLine(true);
                        nameTv.setEllipsize(TextUtils.TruncateAt.END);
                        infoCol.addView(nameTv);

                        String subText =
                                item.directory
                                        ? "文件夹 · 点击进入"
                                        : (PersonalNetdiskLibrary.formatFileSize(item.sizeBytes)
                                                + " · 点击播放");
                        TextView subTv = a.text(subText, 11.5f, p.textSecondary);
                        subTv.setSingleLine(true);
                        subTv.setPadding(0, a.dp(3), 0, 0);
                        infoCol.addView(subTv);
                        row.addView(infoCol, new LinearLayout.LayoutParams(0, -2, 1f));

                        if (!item.directory) {
                            String siteKey =
                                    PersonalNetdiskLibrary.siteKeyFor(provider, item.accountId);
                            final boolean isFav =
                                    Favorites.contains(
                                            a.prefs.getString(Prefs.FAVORITES, "[]"),
                                            siteKey,
                                            item.canonicalPlayId());
                            FrameLayout favBtn = new FrameLayout(a);
                            favBtn.setBackground(MobileTheme.subtleBg(a, 999));
                            favBtn.addView(
                                    MobileIcons.create(
                                            a,
                                            isFav
                                                    ? MobileIcons.IC_HEART_FILLED
                                                    : MobileIcons.IC_HEART,
                                            15f,
                                            isFav ? p.danger : p.textSecondary),
                                    new FrameLayout.LayoutParams(
                                            a.dp(15), a.dp(15), Gravity.CENTER));
                            MobileMotion.bindPress(favBtn, 0.90f);
                            favBtn.setOnClickListener(
                                    v -> {
                                        String next =
                                                Favorites.toggle(
                                                        a.prefs.getString(Prefs.FAVORITES, "[]"),
                                                        siteKey,
                                                        item.toVideo());
                                        a.prefs.edit().putString(Prefs.FAVORITES, next).apply();
                                        a.toast(isFav ? "已取消收藏" : "已收藏（绑定当前网盘账号）");
                                        renderList[0].run();
                                    });
                            LinearLayout.LayoutParams flp =
                                    new LinearLayout.LayoutParams(a.dp(32), a.dp(32));
                            flp.leftMargin = a.dp(8);
                            row.addView(favBtn, flp);
                        }

                        row.setOnClickListener(
                                v -> {
                                    if (item.directory) {
                                        String nextId =
                                                NetdiskStore.DRIVE_BAIDU.equals(provider)
                                                        ? item.path
                                                        : item.fid;
                                        stack.add(new FolderBreadcrumb(nextId, item.name));
                                        state.reset();
                                        loadPageFn[0].run();
                                    } else {
                                        playCloudItem(a, item);
                                    }
                                });
                        card.addView(row, new LinearLayout.LayoutParams(-1, -2));
                    }
                    listBody.addView(card, new LinearLayout.LayoutParams(-1, -2));

                    if (state.hasMore) {
                        a.gap(listBody, 12);
                        TextView moreBtn =
                                buildPillBtn(
                                        a,
                                        state.loading
                                                ? "正在加载第 " + (state.page + 1) + " 页…"
                                                : "加载下一页（当前第 " + state.page + " 页）",
                                        false);
                        moreBtn.setEnabled(!state.loading);
                        moreBtn.setOnClickListener(v -> loadPageFn[0].run());
                        listBody.addView(moreBtn, new LinearLayout.LayoutParams(-1, a.dp(42)));
                    }
                };

        backBtn.setOnClickListener(
                v -> {
                    if (stack.size() > 1) {
                        stack.remove(stack.size() - 1);
                        state.reset();
                        loadPageFn[0].run();
                    } else {
                        a.onBackPressed();
                    }
                });
        reauthHeaderBtn.setOnClickListener(
                v ->
                        showQrLoginSheet(
                                a,
                                provider,
                                () -> {
                                    state.reset();
                                    loadPageFn[0].run();
                                }));

        loadPageFn[0].run();
    }

    /**
     * Resolves and opens a personal netdisk video directly into the native player, enforcing
     * account identity isolation and restoring watch-history resume position.
     */
    static void playCloudItem(final MainActivity a, final PersonalNetdiskLibrary.CloudItem item) {
        if (a == null || item == null || a.isFinishing()) return;
        a.toast("正在解析 " + NetdiskStore.displayName(item.provider) + " 播放地址…");
        a.worker.execute(
                () -> {
                    try {
                        PersonalNetdiskLibrary lib = new PersonalNetdiskLibrary(a);
                        final PersonalNetdiskLibrary.ResolvedMedia resolved = lib.resolveFile(item);

                        final Cms.Site site =
                                PersonalNetdiskLibrary.buildVirtualSite(
                                        resolved.provider, resolved.accountId);
                        final Cms.Video video = item.toVideo();
                        video.id = item.canonicalPlayId();
                        Cms.Line line = new Cms.Line();
                        line.name = NetdiskStore.displayName(resolved.provider);
                        line.rawName = line.name;
                        final Cms.Episode ep = new Cms.Episode();
                        ep.name = item.name;
                        ep.url = resolved.playUrl;
                        ep.headers.putAll(resolved.headers);

                        // Populate multi-quality variants into ep.media so quality switcher works!
                        try {
                            JSONObject media = new JSONObject();
                            if (resolved.proxyLease != null) {
                                media.put("_cloudLeaseId", resolved.proxyLease.id);
                            }
                            JSONArray qualities = new JSONArray();
                            for (int i = 0; i < resolved.variants.size(); i++) {
                                PersonalNetdiskLibrary.PlayVariant pv = resolved.variants.get(i);
                                JSONObject qObj = new JSONObject();
                                qObj.put("name", pv.name);
                                qObj.put("url", i == 0 ? resolved.playUrl : pv.url);
                                if (i > 0 && !pv.headers.isEmpty()) {
                                    qObj.put("header", new JSONObject(pv.headers));
                                }
                                qualities.put(qObj);
                            }
                            if (qualities.length() > 1) {
                                media.put("qualities", qualities);
                                media.put("_qualityIdx", 0);
                            }
                            ep.media = media;
                        } catch (Exception ignored) {
                        }
                        line.episodes.add(ep);
                        video.lines.add(line);

                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()) {
                                        revokeQuietly(resolved.proxyLease);
                                        return;
                                    }
                                    // Clean up old playback session BEFORE adopting the new lease
                                    // so releasePlayer() inside openPlayer() never revokes the
                                    // freshly resolved stream URL.
                                    stagePendingLease(resolved.proxyLease);
                                    a.activeLine = line;
                                    a.activeEpisode = ep;
                                    a.openPlayer(site, video, ep);
                                });
                    } catch (PersonalNetdiskLibrary.PersonalCloudException pce) {
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()) return;
                                    if (pce.requiresReauth) {
                                        MobileBottomSheet.showConfirm(
                                                a,
                                                "account_mismatch".equals(pce.code)
                                                        ? "网盘账号不一致"
                                                        : "网盘授权已过期",
                                                pce.getMessage(),
                                                "扫码登录 / 切换账号",
                                                false,
                                                () ->
                                                        showQrLoginSheet(
                                                                a,
                                                                item.provider,
                                                                () -> playCloudItem(a, item)));
                                    } else {
                                        a.toast(pce.getMessage());
                                    }
                                });
                    } catch (Exception ex) {
                        a.ui.post(() -> a.toast("播放地址解析失败：" + a.message(ex)));
                    }
                });
    }

    /**
     * Handles opening a Favorited or Watched personal netdisk item cleanly (WITHOUT ever falling
     * back to public third-party search engines!).
     */
    static boolean tryOpenPersonalCloudEntry(MainActivity a, String siteKey, String videoId) {
        if (!PersonalNetdiskLibrary.isPersonalCloudSiteKey(siteKey)
                && !PersonalNetdiskLibrary.isPersonalCloudPlayId(videoId)) {
            return false;
        }
        PersonalNetdiskLibrary.CloudItem parsed =
                PersonalNetdiskLibrary.parseCanonicalPlayId(videoId);
        if (parsed == null) {
            a.toast("该个人网盘记录格式无效或已损坏，无法打开");
            return true;
        }
        playCloudItem(a, parsed);
        return true;
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    static Bitmap renderLocalQr(String content, int sizePx) {
        if (content == null || content.trim().isEmpty()) return null;
        try {
            BitMatrix matrix =
                    new QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx);
            int[] pixels = new int[sizePx * sizePx];
            for (int y = 0; y < sizePx; y++) {
                for (int x = 0; x < sizePx; x++) {
                    pixels[y * sizePx + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
                }
            }
            return Bitmap.createBitmap(pixels, sizePx, sizePx, Bitmap.Config.ARGB_8888);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static TextView buildPillBtn(MainActivity a, String text, boolean primary) {
        MobileTheme.Palette p = MobileTheme.of(a);
        TextView btn = a.text(text, 13f, primary ? p.accentOnFill : p.textPrimary);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setGravity(Gravity.CENTER);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        btn.setBackground(primary ? a.bg(p.accent, 999) : MobileTheme.subtleBg(a, 999));
        MobileMotion.bindPress(btn, 0.95f);
        return btn;
    }
}

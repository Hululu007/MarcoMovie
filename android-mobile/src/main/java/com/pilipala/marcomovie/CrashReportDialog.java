package com.pilipala.marcomovie;

import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * TV & Mobile crash-log review, selective submission, and hybrid GitHub Issue + QR fallback UI.
 *
 * <p>On cold launch (outside Privacy Space), if unsubmitted crash logs exist, shows a concise
 * D-pad friendly review dialog. Submitting attempts automatic HTTPS upload to the GitHub Issue
 * relay first, and seamlessly falls back to a 5-minute LAN QR share page (or direct GitHub Issue
 * QR when offline) on failure.
 */
final class CrashReportDialog {
    private static boolean promptedThisSession;
    private static CrashReportShareServer activeShareServer;
    private static AppDialog activeShareDialog;

    private CrashReportDialog() {}

    static void closeActiveShareSession() {
        CrashReportShareServer srv = activeShareServer;
        activeShareServer = null;
        if (srv != null) srv.close();
        AppDialog dlg = activeShareDialog;
        activeShareDialog = null;
        if (dlg != null && dlg.isShowing()) {
            try {
                dlg.dismiss();
            } catch (Throwable ignored) {
            }
        }
    }

    /**
     * Pure-JVM single-shot action state machine preventing double-tap duplicate uploads and
     * ensuring every dismissal path (submit partial selection, ignore, clear, swipe/scrim/back)
     * transitions deterministically.
     */
    static final class ReviewActionGuard {
        private boolean locked;

        boolean tryConsumeAction() {
            if (locked) return false;
            locked = true;
            return true;
        }

        boolean isLocked() {
            return locked;
        }
    }

    /**
     * Wraps a confirmation action (such as the empty-history "提交当前运行诊断" button) with a
     * single-shot {@link ReviewActionGuard} so double-activation never triggers duplicate uploads.
     */
    static Runnable guardSingleShotConfirmAction(
            final ReviewActionGuard guard, final Runnable action) {
        return () -> {
            if (guard != null && !guard.tryConsumeAction()) return;
            if (action != null) action.run();
        };
    }

    /**
     * Schedules a quiet, non-nagging crash-review prompt once per cold launch outside Privacy
     * Space, selecting strictly by per-report ID state ({@code !prompted && !dismissed &&
     * !submitted}). Re-reads eligibility and persists prompted IDs off the main thread to avoid
     * StrictMode disk I/O stalls on cold launch.
     */
    static void maybePromptOnStartup(final MainActivity a) {
        if (a == null || a.privateMode || promptedThisSession) return;
        a.worker.execute(
                () -> {
                    CrashReportStore.collectHistoricalExitReasons(a);
                    final long now = System.currentTimeMillis();
                    final File filesDir = a.getFilesDir();
                    final List<CrashReportStore.CrashReport> promptable =
                            CrashReportStore.loadPromptableReports(filesDir, now);
                    if (promptable.isEmpty()) {
                        return;
                    }
                    a.ui.postDelayed(
                            () -> {
                                if (a.isFinishing()
                                        || a.isDestroyed()
                                        || a.privateMode
                                        || promptedThisSession) return;
                                if ((a.appDialog != null && a.appDialog.isShowing())
                                        || MobileAuthorNotice.isShowing()) return;
                                if (a.current != null && a.current.player) return;
                                // Re-check eligibility off the UI thread in case manual Settings
                                // review or clear ran during the startup delay.
                                a.worker.execute(
                                        () -> {
                                            final List<CrashReportStore.CrashReport> fresh =
                                                    CrashReportStore.loadPromptableReports(
                                                            filesDir, System.currentTimeMillis());
                                            if (fresh.isEmpty()) return;
                                            a.ui.post(
                                                    () -> {
                                                        if (a.isFinishing()
                                                                || a.isDestroyed()
                                                                || a.privateMode
                                                                || promptedThisSession) return;
                                                        if ((a.appDialog != null
                                                                        && a.appDialog.isShowing())
                                                                || MobileAuthorNotice.isShowing())
                                                            return;
                                                        if (a.current != null && a.current.player)
                                                            return;
                                                        if (renderReviewDialog(a, fresh, false)) {
                                                            promptedThisSession = true;
                                                            final List<CrashReportStore.CrashReport>
                                                                    shown = new ArrayList<>(fresh);
                                                            a.worker.execute(
                                                                    () ->
                                                                            CrashReportStore
                                                                                    .markPrompted(
                                                                                            filesDir,
                                                                                            shown));
                                                        }
                                                    });
                                        });
                            },
                            1800L);
                });
    }

    static void show(final MainActivity a, final boolean manual) {
        if (a == null || a.isFinishing()) return;
        if (a.privateMode) {
            a.toast("隐私空间内不采集也不上报任何崩溃日志");
            return;
        }
        a.worker.execute(
                () -> {
                    CrashReportStore.collectHistoricalExitReasons(a);
                    final List<CrashReportStore.CrashReport> reports =
                            CrashReportStore.loadReports(a.getFilesDir());
                    a.ui.post(
                            () -> {
                                if (a.isFinishing() || a.isDestroyed()) return;
                                renderReviewDialog(a, reports, manual);
                            });
                });
    }

    private static void dismissAutoPromptReports(
            final MainActivity a,
            final List<CrashReportStore.CrashReport> reports,
            final boolean showHintToast) {
        if (a == null || reports == null || reports.isEmpty()) return;
        final List<CrashReportStore.CrashReport> snapshot = new ArrayList<>(reports);
        a.worker.execute(() -> CrashReportStore.markDismissed(a.getFilesDir(), snapshot));
        if (showHintToast) {
            a.toast("已忽略本次提醒，可随时在「设置 → 异常退出报告」查看");
        }
    }

    private static boolean renderReviewDialog(
            final MainActivity a,
            final List<CrashReportStore.CrashReport> reports,
            final boolean manual) {
        final boolean mobileUi = !a.isTvDevice();
        final MobileTheme.Palette pal = mobileUi ? MobileTheme.of(a) : null;
        if (reports.isEmpty()) {
            if (!manual) return false;
            final ReviewActionGuard emptyGuard = new ReviewActionGuard();
            final Runnable submitDiagnostic =
                    guardSingleShotConfirmAction(
                            emptyGuard,
                            () -> {
                                List<CrashReportStore.CrashReport> single = new ArrayList<>();
                                single.add(CrashReportStore.buildManualDiagnostic(a));
                                startHybridSubmit(a, single, false);
                            });
            if (mobileUi) {
                MobileBottomSheet.showConfirm(
                        a,
                        "崩溃日志与问题反馈",
                        "本机暂未记录到未处理的应用闪退。如遇到画面异常、播放卡顿或解析问题，可导出当前脱敏运行日志并自动提交至 GitHub Issue。",
                        "提交当前运行诊断",
                        false,
                        submitDiagnostic);
                return true;
            }
            new AppDialog.Builder(a)
                    .setTitle("崩溃日志与问题反馈")
                    .setMessage(
                            "本机暂未记录到未处理的应用闪退。\n\n如遇到画面异常、播放卡顿或解析问题，可点击下方按钮导出当前脱敏运行日志并自动提交至 GitHub Issue（失败时自动切换手机扫码提交）。")
                    .setPositiveButton("提交当前运行诊断", (d, w) -> submitDiagnostic.run())
                    .setNegativeButton("关闭", null)
                    .show();
            return true;
        }

        final boolean[] selected = new boolean[reports.size()];
        int defaultSelected = 0;
        for (int i = 0; i < reports.size(); i++) {
            CrashReportStore.CrashReport item = reports.get(i);
            boolean pick = (!item.submitted && !item.dismissed) || (manual && i == 0);
            selected[i] = pick;
            if (pick) defaultSelected++;
        }
        if (defaultSelected == 0) {
            selected[0] = true;
        }

        LinearLayout panel = a.vertical();
        TextView hint =
                a.text(
                        manual
                                ? "勾选要提交的脱敏日志（已自动隐藏片源地址、网盘凭证与隐私信息）。优先自动创建 GitHub Issue，失败时自动切换扫码。"
                                : "检测到上次异常退出，已记录脱敏崩溃日志（不含片源链接与账号信息）。同一条记录仅提醒一次，关闭或忽略后不再重复打扰。",
                        12.5f,
                        mobileUi ? pal.textSecondary : 0xbce2e8f0);
        hint.setLineSpacing(a.dp(2.5f), 1f);
        panel.addView(hint, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 10);

        ScrollView scroll = new ScrollView(a);
        scroll.setVerticalScrollBarEnabled(true);
        final int accentColor = mobileUi ? pal.accent : 0xff34d399;
        LinearLayout listBox = a.vertical();
        final List<View> rowViews = new ArrayList<>();
        for (int i = 0; i < reports.size(); i++) {
            final int idx = i;
            final CrashReportStore.CrashReport r = reports.get(i);
            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(12), a.dp(9), a.dp(10), a.dp(9));

            final TextView checkView = a.text(selected[idx] ? "☑" : "☐", 16f, accentColor);
            checkView.setTypeface(null, Typeface.BOLD);
            LinearLayout.LayoutParams checkLp = new LinearLayout.LayoutParams(a.dp(26), -2);
            if (!mobileUi) {
                row.addView(checkView, checkLp);
            }
            final FrameLayout mobileCheckBox = mobileUi ? new FrameLayout(a) : null;
            final MobileIcons.IconView mobileCheckIcon =
                    mobileUi
                            ? MobileIcons.create(a, MobileIcons.IC_CHECK, 13f, pal.accentOnFill)
                            : null;
            if (mobileUi) {
                mobileCheckIcon.setStrokeWidthUnits(2.4f);
                mobileCheckBox.addView(
                        mobileCheckIcon,
                        new FrameLayout.LayoutParams(a.dp(13), a.dp(13), Gravity.CENTER));
                LinearLayout.LayoutParams mclp = new LinearLayout.LayoutParams(a.dp(20), a.dp(20));
                mclp.rightMargin = a.dp(10);
                row.addView(mobileCheckBox, mclp);
            }

            LinearLayout copy = a.vertical();
            String statusTag =
                    r.submitted
                            ? (r.submittedIssueNumber > 0
                                    ? " [已提交 #" + r.submittedIssueNumber + "]"
                                    : " [已提交]")
                            : (r.dismissed ? " [已忽略]" : "");
            TextView titleTv =
                    a.text(
                            r.displayTime() + " · " + r.summary + statusTag,
                            13f,
                            mobileUi ? pal.textPrimary : MainActivity.WHITE);
            titleTv.setTypeface(null, Typeface.BOLD);
            titleTv.setSingleLine(true);
            titleTv.setEllipsize(TextUtils.TruncateAt.END);
            copy.addView(titleTv);

            TextView metaTv =
                    a.text(
                            r.kindLabel()
                                    + " · "
                                    + r.deviceModel
                                    + " · Android "
                                    + r.androidRelease
                                    + " (API "
                                    + r.sdkInt
                                    + ")",
                            11.5f,
                            mobileUi ? pal.textSecondary : MainActivity.MUTED);
            metaTv.setSingleLine(true);
            metaTv.setEllipsize(TextUtils.TruncateAt.END);
            metaTv.setPadding(0, a.dp(2), 0, 0);
            copy.addView(metaTv);

            LinearLayout.LayoutParams copyLp = new LinearLayout.LayoutParams(0, -2, 1f);
            copyLp.rightMargin = a.dp(8);
            row.addView(copy, copyLp);

            final LinearLayout toggleBox = a.row();
            toggleBox.setFocusable(true);
            toggleBox.setClickable(true);
            UiCompat.setDefaultFocusHighlightEnabled(toggleBox, false);
            toggleBox.setGravity(Gravity.CENTER_VERTICAL);
            toggleBox.addView(row, new LinearLayout.LayoutParams(-1, -2));

            final Runnable restyleRow =
                    () -> {
                        boolean focused = toggleBox.hasFocus();
                        boolean checked = selected[idx];
                        if (mobileUi) {
                            if (checked) {
                                mobileCheckBox.setBackground(a.bg(pal.accent, 6));
                                mobileCheckIcon.setVisibility(View.VISIBLE);
                            } else {
                                GradientDrawable box = a.bg(Color.TRANSPARENT, 6);
                                box.setStroke(Math.max(1, a.dp(1.5f)), pal.textTertiary);
                                mobileCheckBox.setBackground(box);
                                mobileCheckIcon.setVisibility(View.INVISIBLE);
                            }
                            toggleBox.setBackground(
                                    a.bg(checked ? pal.pillSelectedFill : pal.bgSubtle, 12));
                        } else {
                            checkView.setText(checked ? "☑" : "☐");
                            checkView.setTextColor(checked ? 0xff34d399 : 0x88cbd5e1);
                            GradientDrawable bg = a.bg(focused ? 0x3834d399 : 0x1a1e293b, 12);
                            bg.setStroke(
                                    Math.max(1, a.dp(focused ? 1.5f : 0.8f)),
                                    focused ? 0xff6ee7b7 : (checked ? 0x5534d399 : 0x26ffffff));
                            toggleBox.setBackground(bg);
                        }
                    };
            restyleRow.run();
            toggleBox.setOnFocusChangeListener((v, f) -> restyleRow.run());
            toggleBox.setOnClickListener(
                    v -> {
                        selected[idx] = !selected[idx];
                        restyleRow.run();
                        if (mobileUi && selected[idx]) MobileMotion.popBounce(mobileCheckBox);
                    });

            final TextView previewBtn =
                    a.text("预览", 12f, mobileUi ? pal.textPrimary : MainActivity.WHITE);
            previewBtn.setFocusable(true);
            previewBtn.setClickable(true);
            UiCompat.setDefaultFocusHighlightEnabled(previewBtn, false);
            previewBtn.setGravity(Gravity.CENTER);
            previewBtn.setPadding(a.dp(10), a.dp(8), a.dp(10), a.dp(8));
            final Runnable restylePreview =
                    () -> {
                        boolean f = previewBtn.hasFocus();
                        if (mobileUi) {
                            previewBtn.setBackground(a.bg(pal.bgSubtle, 10));
                            previewBtn.setTextColor(pal.textPrimary);
                        } else {
                            GradientDrawable bg = a.bg(f ? 0xffffffff : 0x24ffffff, 10);
                            bg.setStroke(Math.max(1, a.dp(0.8f)), f ? 0xffffffff : 0x33ffffff);
                            previewBtn.setBackground(bg);
                            previewBtn.setTextColor(f ? 0xff10141c : MainActivity.WHITE);
                        }
                    };
            restylePreview.run();
            previewBtn.setOnFocusChangeListener((v, f) -> restylePreview.run());
            previewBtn.setOnClickListener(
                    v -> {
                        List<CrashReportStore.CrashReport> one = new ArrayList<>();
                        one.add(r);
                        if (mobileUi) {
                            ScrollView pvScroll = new ScrollView(a);
                            TextView pvText =
                                    a.text(
                                            CrashReportStore.formatIssueMarkdown(one),
                                            12f,
                                            pal.textPrimary);
                            pvText.setTypeface(Typeface.MONOSPACE);
                            pvText.setTextIsSelectable(true);
                            pvText.setLineSpacing(a.dp(2), 1f);
                            pvText.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(12));
                            pvText.setBackground(MobileTheme.subtleBg(a, 14));
                            pvScroll.addView(pvText, new LinearLayout.LayoutParams(-1, -2));
                            MobileBottomSheet.showHandle(
                                    a,
                                    "脱敏日志预览",
                                    r.displayTime() + " · " + r.kindLabel(),
                                    null,
                                    null,
                                    pvScroll,
                                    true);
                        } else {
                            new AppDialog.Builder(a)
                                    .setTitle("脱敏日志预览")
                                    .setMessage(CrashReportStore.formatIssueMarkdown(one))
                                    .setPositiveButton("返回", null)
                                    .show();
                        }
                    });

            LinearLayout outerRow = a.row();
            outerRow.setGravity(Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(0, -2, 1f);
            tLp.rightMargin = a.dp(8);
            outerRow.addView(toggleBox, tLp);
            outerRow.addView(previewBtn, new LinearLayout.LayoutParams(-2, -2));

            LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-1, -2);
            if (i + 1 < reports.size()) rowLp.bottomMargin = a.dp(8);
            listBox.addView(outerRow, rowLp);
            rowViews.add(toggleBox);
        }
        scroll.addView(listBox, new LinearLayout.LayoutParams(-1, -2));
        int maxListH =
                Math.min(a.dp(240), Math.max(a.dp(130), Math.round(a.windowHeight() * 0.36f)));
        panel.addView(
                scroll,
                new LinearLayout.LayoutParams(-1, Math.min(maxListH, a.dp(reports.size() * 64))));

        final ReviewActionGuard actionGuard = new ReviewActionGuard();

        if (mobileUi) {
            a.gap(panel, 14);
            final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];

            final TextView submitBtn = a.text("提交所选日志", 14.5f, pal.accentOnFill);
            submitBtn.setTypeface(null, Typeface.BOLD);
            submitBtn.setGravity(Gravity.CENTER);
            submitBtn.setMinimumHeight(a.dp(46));
            submitBtn.setPadding(a.dp(16), a.dp(12), a.dp(16), a.dp(12));
            submitBtn.setBackground(a.bg(pal.accent, 14));
            MobileMotion.bindPress(submitBtn, 0.96f);

            LinearLayout secondaryRow = a.row();
            final TextView ignoreBtn = a.text(manual ? "关闭" : "不再提醒", 13.5f, pal.textPrimary);
            ignoreBtn.setTypeface(null, Typeface.BOLD);
            ignoreBtn.setGravity(Gravity.CENTER);
            ignoreBtn.setMinimumHeight(a.dp(42));
            ignoreBtn.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
            ignoreBtn.setBackground(MobileTheme.subtleBg(a, 12));
            MobileMotion.bindPress(ignoreBtn, 0.96f);

            final TextView clearBtn = a.text("清空记录", 13.5f, 0xFFEF4444);
            clearBtn.setTypeface(null, Typeface.BOLD);
            clearBtn.setGravity(Gravity.CENTER);
            clearBtn.setMinimumHeight(a.dp(42));
            clearBtn.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
            clearBtn.setBackground(MobileTheme.subtleBg(a, 12));
            MobileMotion.bindPress(clearBtn, 0.96f);

            final Runnable disableButtons =
                    () -> {
                        submitBtn.setEnabled(false);
                        submitBtn.setClickable(false);
                        submitBtn.setAlpha(0.55f);
                        ignoreBtn.setEnabled(false);
                        ignoreBtn.setClickable(false);
                        clearBtn.setEnabled(false);
                        clearBtn.setClickable(false);
                    };

            submitBtn.setOnClickListener(
                    v -> {
                        if (actionGuard.isLocked()) return;
                        List<CrashReportStore.CrashReport> chosen = new ArrayList<>();
                        for (int i = 0; i < reports.size(); i++) {
                            if (selected[i]) chosen.add(reports.get(i));
                        }
                        if (chosen.isEmpty()) {
                            a.toast("请至少勾选一条日志");
                            return;
                        }
                        if (!actionGuard.tryConsumeAction()) return;
                        disableButtons.run();
                        if (!manual) {
                            // Unchecked items in the same startup prompt won't nag again either.
                            List<CrashReportStore.CrashReport> unselected = new ArrayList<>();
                            for (int i = 0; i < reports.size(); i++) {
                                if (!selected[i]) unselected.add(reports.get(i));
                            }
                            if (!unselected.isEmpty()) {
                                dismissAutoPromptReports(a, unselected, false);
                            }
                        }
                        if (handleRef[0] != null) handleRef[0].dismiss();
                        startHybridSubmit(a, chosen, true);
                    });
            panel.addView(submitBtn, new LinearLayout.LayoutParams(-1, -2));
            a.gap(panel, 10);

            ignoreBtn.setOnClickListener(
                    v -> {
                        if (!actionGuard.tryConsumeAction()) return;
                        disableButtons.run();
                        if (!manual) {
                            dismissAutoPromptReports(a, reports, true);
                        }
                        if (handleRef[0] != null) handleRef[0].dismiss();
                    });
            LinearLayout.LayoutParams igLp = new LinearLayout.LayoutParams(0, -2, 1f);
            igLp.rightMargin = a.dp(8);
            secondaryRow.addView(ignoreBtn, igLp);

            clearBtn.setOnClickListener(
                    v -> {
                        if (!actionGuard.tryConsumeAction()) return;
                        disableButtons.run();
                        CrashReportStore.clearAll(a.getFilesDir());
                        a.toast("已清空本地崩溃日志");
                        if (handleRef[0] != null) handleRef[0].dismiss();
                    });
            secondaryRow.addView(clearBtn, new LinearLayout.LayoutParams(0, -2, 1f));
            panel.addView(secondaryRow, new LinearLayout.LayoutParams(-1, -2));

            handleRef[0] =
                    MobileBottomSheet.showHandle(
                            a,
                            manual ? "崩溃日志与问题反馈" : "上次异常退出",
                            manual
                                    ? ("共 " + reports.size() + " 条本地记录")
                                    : ("发现 " + reports.size() + " 条新记录 · 仅本次提醒"),
                            null,
                            null,
                            panel,
                            true);
            boolean showing =
                    handleRef[0] != null
                            && handleRef[0].dialog() != null
                            && handleRef[0].dialog().isShowing();
            if (handleRef[0] != null && handleRef[0].dialog() != null) {
                handleRef[0]
                        .dialog()
                        .setOnDismissListener(
                                d -> {
                                    if (!manual && actionGuard.tryConsumeAction()) {
                                        dismissAutoPromptReports(a, reports, false);
                                    }
                                });
            }
            return showing;
        }

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle(manual ? "崩溃日志与问题反馈" : "上次异常退出 · 提交崩溃日志")
                        .setView(panel)
                        .setPositiveButton(
                                "提交所选日志",
                                (d, w) -> {
                                    if (actionGuard.isLocked()) return;
                                    List<CrashReportStore.CrashReport> chosen = new ArrayList<>();
                                    for (int i = 0; i < reports.size(); i++) {
                                        if (selected[i]) chosen.add(reports.get(i));
                                    }
                                    if (chosen.isEmpty()) {
                                        a.toast("请至少勾选一条日志");
                                        return;
                                    }
                                    if (!actionGuard.tryConsumeAction()) return;
                                    if (!manual) {
                                        List<CrashReportStore.CrashReport> unselected =
                                                new ArrayList<>();
                                        for (int i = 0; i < reports.size(); i++) {
                                            if (!selected[i]) unselected.add(reports.get(i));
                                        }
                                        if (!unselected.isEmpty()) {
                                            dismissAutoPromptReports(a, unselected, false);
                                        }
                                    }
                                    startHybridSubmit(a, chosen, true);
                                })
                        .setNeutralButton(
                                "清空记录",
                                (d, w) -> {
                                    if (!actionGuard.tryConsumeAction()) return;
                                    CrashReportStore.clearAll(a.getFilesDir());
                                    a.toast("已清空本地崩溃日志");
                                })
                        .setNegativeButton(
                                manual ? "关闭" : "不再提醒",
                                (d, w) -> {
                                    if (!actionGuard.tryConsumeAction()) return;
                                    if (!manual) {
                                        dismissAutoPromptReports(a, reports, true);
                                    }
                                })
                        .create();
        dialog.setOnDismissListener(
                d -> {
                    if (!manual && actionGuard.tryConsumeAction()) {
                        dismissAutoPromptReports(a, reports, false);
                    }
                });
        dialog.show();
        if (dialog.getButton(-1) != null) {
            dialog.getButton(-1).requestFocus();
        } else if (!rowViews.isEmpty()) {
            rowViews.get(0).requestFocus();
        }
        return dialog.isShowing();
    }

    private static void startHybridSubmit(
            final MainActivity a,
            final List<CrashReportStore.CrashReport> chosen,
            final boolean persistSubmittedFlag) {
        a.toast("正在自动提交崩溃日志至 GitHub Issue…");
        a.worker.execute(
                () -> {
                    final CrashReportUploader.UploadResult res = CrashReportUploader.submit(chosen);
                    if (res.ok && persistSubmittedFlag) {
                        CrashReportStore.markSubmitted(
                                a.getFilesDir(), chosen, res.issueNumber, res.issueUrl);
                    }
                    a.ui.post(
                            () -> {
                                if (a.isFinishing() || a.isDestroyed()) return;
                                if (res.ok) {
                                    String tag =
                                            res.issueNumber > 0 ? ("#" + res.issueNumber) : "成功";
                                    new AppDialog.Builder(a)
                                            .setTitle("崩溃日志提交成功")
                                            .setMessage(
                                                    "已自动提交脱敏日志至 GitHub Issue "
                                                            + tag
                                                            + "。\n\n感谢你的反馈，我们会尽快跟进修复。"
                                                            + (res.issueUrl.isEmpty()
                                                                    ? ""
                                                                    : ("\n\n地址：" + res.issueUrl)))
                                            .setPositiveButton("知道了", null)
                                            .show();
                                } else {
                                    showQrFallbackDialog(a, chosen, res.errorMessage);
                                }
                            });
                });
    }

    private static void showQrFallbackDialog(
            final MainActivity a,
            final List<CrashReportStore.CrashReport> chosen,
            final String failureReason) {
        closeActiveShareSession();
        String qrTargetUrl;
        boolean lanMode = false;
        CrashReportShareServer server = null;
        try {
            String ip = PhoneConfigDialog.lanAddress();
            server = new CrashReportShareServer(chosen);
            qrTargetUrl = server.address(ip);
            lanMode = true;
            activeShareServer = server;
        } catch (Exception ignored) {
            if (server != null) server.close();
            qrTargetUrl = CrashReportStore.buildGithubNewIssueUrl(chosen);
        }

        LinearLayout panel = a.vertical();
        panel.setGravity(Gravity.CENTER_HORIZONTAL);
        String reason =
                failureReason == null || failureReason.isEmpty() ? "网络或服务不可达" : failureReason;
        TextView note =
                a.text(
                        lanMode
                                ? ("自动提交 GitHub 失败（"
                                        + reason
                                        + "）。\n请用手机连接同一局域网并扫码，打开后可一键跳转 GitHub 提交 Issue、复制或下载完整脱敏日志：")
                                : ("自动提交 GitHub 失败（"
                                        + reason
                                        + "）。\n未检测到局域网地址，请直接用手机扫码打开预填好的 GitHub Issue 提交页："),
                        13f,
                        0xbce2e8f0);
        note.setLineSpacing(a.dp(2.5f), 1f);
        panel.addView(note, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 10);

        int qrSize = Math.min(a.dp(172), Math.max(a.dp(132), Math.round(a.windowHeight() * 0.28f)));
        Bitmap qrBmp = renderQrBitmap(qrTargetUrl, qrSize);
        if (qrBmp != null) {
            ImageView qr = new ImageView(a);
            qr.setTag("crash-fallback-qr");
            qr.setContentDescription("崩溃日志扫码反馈二维码");
            qr.setImageBitmap(qrBmp);
            panel.addView(qr, new LinearLayout.LayoutParams(qrSize, qrSize));
        }

        TextView urlTv =
                a.text(
                        lanMode
                                ? qrTargetUrl
                                : "https://github.com/Pilipala9919/MarcoMovie/issues/new",
                        11.5f,
                        MainActivity.WHITE);
        urlTv.setGravity(Gravity.CENTER);
        urlTv.setSingleLine(true);
        urlTv.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        urlTv.setPadding(0, a.dp(8), 0, 0);
        panel.addView(urlTv, new LinearLayout.LayoutParams(-1, -2));

        TextView expireTv =
                a.text(
                        lanMode ? "局域网扫码页有效 5 分钟 · 关闭弹窗立即停止服务" : "扫码将携带脱敏摘要直达 GitHub Issue",
                        11.5f,
                        MainActivity.MUTED);
        expireTv.setGravity(Gravity.CENTER);
        expireTv.setPadding(0, a.dp(4), 0, 0);
        panel.addView(expireTv, new LinearLayout.LayoutParams(-1, -2));

        final Runnable expiry = CrashReportDialog::closeActiveShareSession;
        final AppDialog dlg =
                new AppDialog.Builder(a)
                        .setTitle("扫码提交崩溃日志")
                        .setView(panel)
                        .setNeutralButton(
                                "重试自动提交",
                                (d, w) -> {
                                    closeActiveShareSession();
                                    startHybridSubmit(a, chosen, true);
                                })
                        .setPositiveButton("完成", null)
                        .create();
        activeShareDialog = dlg;
        dlg.setOnDismissListener(
                d -> {
                    a.ui.removeCallbacks(expiry);
                    if (activeShareDialog == dlg) activeShareDialog = null;
                    CrashReportShareServer s = activeShareServer;
                    activeShareServer = null;
                    if (s != null) s.close();
                });
        dlg.show();
        if (dlg.getButton(-1) != null) dlg.getButton(-1).requestFocus();
        if (lanMode) {
            a.ui.postDelayed(expiry, TimeUnit.MINUTES.toMillis(5));
        }
    }

    static Bitmap renderQrBitmap(String content, int sizePx) {
        if (content == null || content.isEmpty() || sizePx <= 0) return null;
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
        } catch (Exception e) {
            return null;
        }
    }
}

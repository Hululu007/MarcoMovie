package com.pilipala.marcomovie;

import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Android TV post-update / first-launch official channel, anti-scam & voluntary support notice,
 * plus Settings / Update Center author contact, community group, and voluntary donation widgets.
 *
 * <p>Persists per-version display state in the device-local {@link OnboardingScreen#PREFS_FILE}
 * preferences file so {@link Prefs#KEYS} (strictly 46 backup keys) remains untouched.
 */
final class TvOfficialNotice {
    static final String KEY_FIRST_LAUNCH_NOTICE_SEEN_V1 = "tv_official_notice_seen_v1";
    static final String KEY_NOTICE_SEEN_VERSION_CODE = "tv_official_notice_seen_version_code";

    static final String AUTHOR_SOCIAL_NAME = "PILIPALA来信";
    static final String AUTHOR_SOCIAL_PLATFORMS = "小红书 · B站 · 抖音 · 公众号 · 视频号";
    static final String OFFICIAL_SITE_DISPLAY = "marcotv.wlj9919.top";
    static final String OFFICIAL_SITE_URL = "https://marcotv.wlj9919.top";
    static final String OFFICIAL_GROUP_URL = "https://marcotv.wlj9919.top/movie/#group";
    static final String OFFICIAL_DONATE_DISPLAY = "marcotv.wlj9919.top/movie/#donate";
    static final String OFFICIAL_DONATE_URL = "https://marcotv.wlj9919.top/movie/#donate";

    static final String SECURITY_REMINDER =
            "Marco Movie 永久免费开源，从未授权任何第三方收费售卖、代装或会员解锁；若您曾付费购买，请及时向购买平台申请退款。"
                    + "官网 "
                    + OFFICIAL_SITE_DISPLAY
                    + " 为唯一官方发布与更新渠道，下载和升级请认准官网，切勿安装不明修改包。";

    static final String NOTICE_DONATE_TITLE = "如果 Marco 陪你度过了轻松的客厅时光";
    static final String NOTICE_DONATE_BODY =
            "Marco 由独立开发者在业余时间持续打磨，国内镜像加速、服务器与多端适配都需要长期投入。"
                    + "软件全部功能始终免费、无广告无限制；若您觉得好用，欢迎量力而行请作者喝杯咖啡——"
                    + "哪怕一份小小的心意，也是支撑它走得更远的温暖动力。不捐赠同样完整使用，感谢相遇。";

    static final String DONATE_ROW_TAG = "settings-donate-support";
    static final String DONATE_SECTION_TITLE = "支持 Marco 长久同行 · 自愿赞助捐赠";
    static final String DONATE_SECTION_BODY =
            "从深夜逐帧排查大屏播放体验，到自费维护国内镜像加速与多端更新，Marco 始终坚持免费开源、无广告、无任何功能门槛。"
                    + "如果它恰好成了客厅里顺手的小工具，欢迎随心请作者喝杯咖啡，让这份热爱能稳稳走得更久。捐赠全凭自愿，不捐赠一样完整享用。";
    static final String DONATE_SECTION_PROMISE = "完全免费开源 · 捐赠全凭自愿 · 不影响任何功能";

    static final String SETTINGS_ROW_TAG = "settings-contact-author";
    static final String SETTINGS_ROW_TITLE = "联系反馈作者与官方交流群";
    static final String SETTINGS_ROW_DETAIL =
            "各社媒同名：" + AUTHOR_SOCIAL_NAME + "（小红书/B站/抖音/公众号/视频号）· 官网交流群 " + OFFICIAL_SITE_DISPLAY;

    private TvOfficialNotice() {}

    /** Pure-JVM state controller showing the notice once on fresh install and once after every version update. */
    static final class Controller {
        private Controller() {}

        static boolean shouldShowOnLaunch(OnboardingScreen.Store store, int installedVersionCode) {
            if (store == null || installedVersionCode <= 0) return false;
            return store.getInt(KEY_NOTICE_SEEN_VERSION_CODE, 0) != installedVersionCode;
        }

        static void markSeen(OnboardingScreen.Store store, int installedVersionCode) {
            if (store == null) return;
            if (installedVersionCode > 0) {
                store.putInt(KEY_NOTICE_SEEN_VERSION_CODE, installedVersionCode);
            }
            store.putBoolean(KEY_FIRST_LAUNCH_NOTICE_SEEN_V1, true);
        }

        static void resetForTest(OnboardingScreen.Store store) {
            if (store == null) return;
            store.putInt(KEY_NOTICE_SEEN_VERSION_CODE, 0);
            store.putBoolean(KEY_FIRST_LAUNCH_NOTICE_SEEN_V1, false);
        }
    }

    static boolean shouldShowOnLaunch(Context context) {
        if (context == null) return false;
        int code = UpdateManager.installedCode(context);
        if (code == Integer.MAX_VALUE) code = 1;
        return Controller.shouldShowOnLaunch(new OnboardingScreen.SharedPrefsStore(context), code);
    }

    static void markSeen(Context context) {
        if (context == null) return;
        int code = UpdateManager.installedCode(context);
        if (code == Integer.MAX_VALUE) code = 1;
        Controller.markSeen(new OnboardingScreen.SharedPrefsStore(context), code);
    }

    /** Shows the post-install / post-update official notice dialog once per app versionCode. */
    static AppDialog showFirstLaunchDialog(final MainActivity a) {
        if (a == null || a.isFinishing() || a.isDestroyed() || !a.isTvDevice()) return null;
        if (a.activeOnboarding != null) return null;

        final boolean[] showingDonateQr = new boolean[] {false};
        final ImageView[] qrViewRef = new ImageView[1];
        final TextView[] qrTitleRef = new TextView[1];
        final TextView[] qrUrlRef = new TextView[1];
        final int qrSize = resolveQrSizePx(a);

        LinearLayout content =
                buildPostUpdateNoticeBody(a, qrSize, qrViewRef, qrTitleRef, qrUrlRef);
        String ver = UpdateManager.installedVersion(a);
        String dlgTitle =
                (ver != null && !ver.trim().isEmpty())
                        ? "欢迎使用 Marco Movie " + ver.trim()
                        : "Marco Movie 官方提示";

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle(dlgTitle)
                        .setWide(true)
                        .setView(content)
                        .setNeutralButton("切换捐赠二维码", null)
                        .setPositiveButton("我知道了", (d, w) -> markSeen(a))
                        .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                        .create();
        dialog.setOnDismissListener(
                d -> {
                    markSeen(a);
                    if (a.current != null) {
                        a.restore(a.current);
                    }
                });
        dialog.show();

        final Button toggleBtn = dialog.getButton(DialogInterface.BUTTON_NEUTRAL);
        if (toggleBtn != null) {
            toggleBtn.setOnClickListener(
                    v -> {
                        showingDonateQr[0] = !showingDonateQr[0];
                        boolean showDonate = showingDonateQr[0];
                        String nextUrl = showDonate ? OFFICIAL_DONATE_URL : OFFICIAL_SITE_URL;
                        Bitmap nextBmp = CrashReportDialog.renderQrBitmap(nextUrl, qrSize);
                        if (qrViewRef[0] != null && nextBmp != null) {
                            qrViewRef[0].setImageBitmap(nextBmp);
                            qrViewRef[0].setContentDescription(
                                    showDonate ? "官网捐赠区二维码" : "Marco 唯一官网二维码");
                        }
                        if (qrTitleRef[0] != null) {
                            qrTitleRef[0].setText(showDonate ? "手机扫码前往官网捐赠区" : "手机扫码访问唯一官网");
                        }
                        if (qrUrlRef[0] != null) {
                            qrUrlRef[0].setText(nextUrl);
                        }
                        toggleBtn.setText(showDonate ? "切回官网二维码" : "切换捐赠二维码");
                    });
        }
        Button okBtn = dialog.getButton(DialogInterface.BUTTON_POSITIVE);
        if (okBtn != null) okBtn.requestFocus();
        return dialog;
    }

    /** Shows the author social handles, official site, and scannable community group QR dialog. */
    static AppDialog showContactAndGroupDialog(final MainActivity a) {
        if (a == null || a.isFinishing() || a.isDestroyed()) return null;

        final boolean[] showingGroupQr = new boolean[] {true};
        final ImageView[] qrViewRef = new ImageView[1];
        final TextView[] qrTitleRef = new TextView[1];
        final TextView[] qrUrlRef = new TextView[1];
        final int qrSize = resolveQrSizePx(a);

        LinearLayout content =
                buildContactBody(a, qrSize, showingGroupQr[0], qrViewRef, qrTitleRef, qrUrlRef);

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle(SETTINGS_ROW_TITLE)
                        .setWide(true)
                        .setView(content)
                        .setNeutralButton("切换官网二维码", null)
                        .setPositiveButton("关闭", null)
                        .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                        .create();
        dialog.show();

        final Button toggleBtn = dialog.getButton(DialogInterface.BUTTON_NEUTRAL);
        if (toggleBtn != null) {
            toggleBtn.setOnClickListener(
                    v -> {
                        showingGroupQr[0] = !showingGroupQr[0];
                        boolean showGroup = showingGroupQr[0];
                        String nextUrl = showGroup ? OFFICIAL_GROUP_URL : OFFICIAL_SITE_URL;
                        Bitmap nextBmp = CrashReportDialog.renderQrBitmap(nextUrl, qrSize);
                        if (qrViewRef[0] != null && nextBmp != null) {
                            qrViewRef[0].setImageBitmap(nextBmp);
                            qrViewRef[0].setContentDescription(
                                    showGroup ? "官网交流群二维码" : "Marco 官网二维码");
                        }
                        if (qrTitleRef[0] != null) {
                            qrTitleRef[0].setText(showGroup ? "手机扫码进入官网交流群" : "手机扫码访问 Marco 官网");
                        }
                        if (qrUrlRef[0] != null) {
                            qrUrlRef[0].setText(nextUrl);
                        }
                        toggleBtn.setText(showGroup ? "切换官网二维码" : "切换交流群二维码");
                    });
        }
        Button closeBtn = dialog.getButton(DialogInterface.BUTTON_POSITIVE);
        if (closeBtn != null) closeBtn.requestFocus();
        return dialog;
    }

    /** Shows the dedicated warm voluntary donation dialog with enlarged QR code for 3m TV scanning. */
    static AppDialog showDonateDialog(final MainActivity a) {
        if (a == null || a.isFinishing() || a.isDestroyed()) return null;

        final boolean[] showingDonateQr = new boolean[] {true};
        final ImageView[] qrViewRef = new ImageView[1];
        final TextView[] qrTitleRef = new TextView[1];
        final TextView[] qrUrlRef = new TextView[1];
        final int qrSize =
                Math.max(a.dp(136), Math.min(a.dp(176), Math.round(a.windowHeight() * 0.30f)));

        LinearLayout outer = a.vertical();
        outer.setTag("tv-donate-dialog-body");
        LinearLayout split = a.row();
        split.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout left = a.vertical();
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 1f);
        leftLp.rightMargin = a.dp(18);

        LinearLayout heartCard = a.vertical();
        heartCard.setPadding(a.dp(15), a.dp(13), a.dp(15), a.dp(13));
        GradientDrawable heartBg = new GradientDrawable();
        heartBg.setColor(0x22f472b6);
        heartBg.setCornerRadius(a.dp(14));
        heartBg.setStroke(Math.max(1, a.dp(1)), 0x48f9a8d4);
        heartCard.setBackground(heartBg);

        TextView ht = a.text(NOTICE_DONATE_TITLE, 14.5f, 0xfffce7f3);
        ht.setTypeface(null, Typeface.BOLD);
        heartCard.addView(ht);

        TextView hb = a.text(DONATE_SECTION_BODY, 13f, 0xfff1f5f9);
        hb.setLineSpacing(a.dp(3.5f), 1f);
        hb.setPadding(0, a.dp(6), 0, 0);
        heartCard.addView(hb);
        left.addView(heartCard, new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 10);

        left.addView(
                buildInfoCard(
                        a,
                        "官网捐赠区地址（微信 / 支付宝自愿支持）",
                        OFFICIAL_DONATE_URL,
                        DONATE_SECTION_PROMISE,
                        0xfff9a8d4),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 8);

        left.addView(
                buildInfoCard(
                        a,
                        "作者各社媒账号（全平台同名）",
                        AUTHOR_SOCIAL_NAME,
                        AUTHOR_SOCIAL_PLATFORMS + " · 官网 " + OFFICIAL_SITE_DISPLAY,
                        0xff7cc4ff),
                new LinearLayout.LayoutParams(-1, -2));

        split.addView(left, leftLp);
        split.addView(
                buildQrPanel(
                        a,
                        qrSize,
                        OFFICIAL_DONATE_URL,
                        "手机扫码前往官网捐赠区",
                        "tv-donate-qr",
                        qrViewRef,
                        qrTitleRef,
                        qrUrlRef),
                new LinearLayout.LayoutParams(-2, -2));
        outer.addView(split, new LinearLayout.LayoutParams(-1, -2));

        AppDialog dialog =
                new AppDialog.Builder(a)
                        .setTitle(DONATE_SECTION_TITLE)
                        .setWide(true)
                        .setView(outer)
                        .setNeutralButton("切换官网二维码", null)
                        .setPositiveButton("关闭", null)
                        .setDefaultFocusButton(DialogInterface.BUTTON_POSITIVE)
                        .create();
        dialog.show();

        final Button toggleBtn = dialog.getButton(DialogInterface.BUTTON_NEUTRAL);
        if (toggleBtn != null) {
            toggleBtn.setOnClickListener(
                    v -> {
                        showingDonateQr[0] = !showingDonateQr[0];
                        boolean showDonate = showingDonateQr[0];
                        String nextUrl = showDonate ? OFFICIAL_DONATE_URL : OFFICIAL_SITE_URL;
                        Bitmap nextBmp = CrashReportDialog.renderQrBitmap(nextUrl, qrSize);
                        if (qrViewRef[0] != null && nextBmp != null) {
                            qrViewRef[0].setImageBitmap(nextBmp);
                            qrViewRef[0].setContentDescription(
                                    showDonate ? "官网捐赠区二维码" : "Marco 官网二维码");
                        }
                        if (qrTitleRef[0] != null) {
                            qrTitleRef[0].setText(showDonate ? "手机扫码前往官网捐赠区" : "手机扫码访问 Marco 官网");
                        }
                        if (qrUrlRef[0] != null) {
                            qrUrlRef[0].setText(nextUrl);
                        }
                        toggleBtn.setText(showDonate ? "切换官网二维码" : "切回捐赠二维码");
                    });
        }
        Button closeBtn = dialog.getButton(DialogInterface.BUTTON_POSITIVE);
        if (closeBtn != null) closeBtn.requestFocus();
        return dialog;
    }

    /**
     * Builds an inline, focusable Apple-TV-styled voluntary sponsorship & donation card with a
     * scannable official donation QR code and URL for Settings -> Updates and the Update Center.
     */
    static LinearLayout buildInlineDonateCard(final MainActivity a, String cardTag, String qrTag) {
        final LinearLayout card = a.row();
        card.setId(View.generateViewId());
        card.setTag(cardTag);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setPadding(a.dp(20), a.dp(16), a.dp(20), a.dp(16));
        card.setClickable(true);
        card.setFocusable(a.isTvDevice());
        card.setFocusableInTouchMode(a.isTvDevice());
        card.setContentDescription(DONATE_SECTION_TITLE + " " + OFFICIAL_DONATE_URL);

        final GradientDrawable restingBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TL_BR, new int[] {0xd4221a24, 0xdc171b24});
        restingBg.setCornerRadius(a.dp(18));
        restingBg.setStroke(Math.max(1, a.dp(1)), 0x3ef9a8d4);

        final GradientDrawable focusedBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TL_BR, new int[] {0xee2e2130, 0xf21e2534});
        focusedBg.setCornerRadius(a.dp(18));
        focusedBg.setStroke(Math.max(2, a.dp(2.5f)), Color.WHITE);

        card.setBackground(restingBg);
        UiCompat.setDefaultFocusHighlightEnabled(card, false);

        // Left copy column
        LinearLayout copy = a.vertical();
        LinearLayout.LayoutParams copyLp = new LinearLayout.LayoutParams(0, -2, 1f);
        copyLp.rightMargin = a.dp(18);

        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView titleTv = a.text(DONATE_SECTION_TITLE, 15.5f, 0xfffdf2f8);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleRow.addView(titleTv, new LinearLayout.LayoutParams(-2, -2));

        TextView pill = a.text("自愿支持 · 永久免费", 10.5f, 0xfffbcfe8);
        pill.setTypeface(null, Typeface.BOLD);
        pill.setPadding(a.dp(9), a.dp(3), a.dp(9), a.dp(3));
        GradientDrawable pillBg = new GradientDrawable();
        pillBg.setColor(0x28f472b6);
        pillBg.setCornerRadius(a.dp(999));
        pillBg.setStroke(Math.max(1, a.dp(1)), 0x48f9a8d4);
        pill.setBackground(pillBg);
        LinearLayout.LayoutParams pillLp = new LinearLayout.LayoutParams(-2, -2);
        pillLp.leftMargin = a.dp(10);
        titleRow.addView(pill, pillLp);
        copy.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));

        TextView bodyTv = a.text(DONATE_SECTION_BODY, 12.5f, 0xdce2e8f0);
        bodyTv.setLineSpacing(a.dp(3.5f), 1f);
        bodyTv.setPadding(0, a.dp(7), 0, 0);
        copy.addView(bodyTv, new LinearLayout.LayoutParams(-1, -2));

        TextView urlTv = a.text("官网捐赠区：" + OFFICIAL_DONATE_URL, 12f, 0xfff9a8d4);
        urlTv.setTypeface(null, Typeface.BOLD);
        urlTv.setSingleLine(true);
        urlTv.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        urlTv.setPadding(0, a.dp(8), 0, 0);
        copy.addView(urlTv, new LinearLayout.LayoutParams(-1, -2));

        TextView actionHint = a.text("手机扫描右侧二维码即可支持 · 按确认键放大二维码", 11f, 0x99cbd5e1);
        actionHint.setPadding(0, a.dp(3), 0, 0);
        copy.addView(actionHint, new LinearLayout.LayoutParams(-1, -2));

        card.addView(copy, copyLp);

        // Right inline crisp scannable QR code
        int inlineQrPx = a.dp(a.isTvDevice() ? 104 : 96);
        LinearLayout qrBox = a.vertical();
        qrBox.setGravity(Gravity.CENTER_HORIZONTAL);
        qrBox.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(6));
        GradientDrawable qrWrapBg = new GradientDrawable();
        qrWrapBg.setColor(0x22ffffff);
        qrWrapBg.setCornerRadius(a.dp(14));
        qrWrapBg.setStroke(Math.max(1, a.dp(1)), 0x2cffffff);
        qrBox.setBackground(qrWrapBg);

        FrameLayout whiteFrame = new FrameLayout(a);
        whiteFrame.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(6));
        GradientDrawable wfBg = new GradientDrawable();
        wfBg.setColor(Color.WHITE);
        wfBg.setCornerRadius(a.dp(9));
        whiteFrame.setBackground(wfBg);

        ImageView qrImg = new ImageView(a);
        qrImg.setTag(qrTag);
        qrImg.setContentDescription("官网捐赠区二维码 " + OFFICIAL_DONATE_URL);
        Bitmap bmp = CrashReportDialog.renderQrBitmap(OFFICIAL_DONATE_URL, inlineQrPx);
        if (bmp != null) {
            qrImg.setImageBitmap(bmp);
        }
        whiteFrame.addView(qrImg, new FrameLayout.LayoutParams(inlineQrPx, inlineQrPx));
        qrBox.addView(whiteFrame, new LinearLayout.LayoutParams(-2, -2));

        TextView qrCap = a.text("扫码请作者喝杯咖啡", 10.5f, 0xfff8fafc);
        qrCap.setTypeface(null, Typeface.BOLD);
        qrCap.setPadding(0, a.dp(5), 0, 0);
        qrBox.addView(qrCap, new LinearLayout.LayoutParams(-2, -2));

        card.addView(qrBox, new LinearLayout.LayoutParams(-2, -2));

        card.setOnFocusChangeListener(
                (v, focused) -> {
                    card.setBackground(focused ? focusedBg : restingBg);
                    if (a.isTvDevice()) {
                        float s = (focused && !a.reduced) ? 1.015f : 1f;
                        card.setScaleX(s);
                        card.setScaleY(s);
                    }
                });
        card.setOnClickListener(v -> showDonateDialog(a));
        return card;
    }

    private static int resolveQrSizePx(MainActivity a) {
        int winH = a.windowHeight();
        int maxByH = Math.round(winH * 0.27f);
        return Math.max(a.dp(118), Math.min(a.dp(156), maxByH));
    }

    private static LinearLayout buildPostUpdateNoticeBody(
            MainActivity a,
            int qrSize,
            ImageView[] qrViewRef,
            TextView[] qrTitleRef,
            TextView[] qrUrlRef) {
        LinearLayout outer = a.vertical();
        outer.setTag("tv-first-launch-notice-body");

        LinearLayout split = a.row();
        split.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout left = a.vertical();
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 1f);
        leftLp.rightMargin = a.dp(16);

        // 1) Anti-scam & sole official update channel card
        LinearLayout warnBox = a.vertical();
        warnBox.setPadding(a.dp(13), a.dp(9), a.dp(13), a.dp(9));
        GradientDrawable warnBg = new GradientDrawable();
        warnBg.setColor(0x28ffb340);
        warnBg.setCornerRadius(a.dp(12));
        warnBg.setStroke(Math.max(1, a.dp(1)), 0x66ffb340);
        warnBox.setBackground(warnBg);
        TextView warnTitle = a.text("谨防受骗 · 官网为唯一更新渠道", 12.5f, 0xffffd17a);
        warnTitle.setTypeface(null, Typeface.BOLD);
        warnBox.addView(warnTitle);
        TextView warnText = a.text(SECURITY_REMINDER, 12.5f, 0xfff8fafc);
        warnText.setLineSpacing(a.dp(2.5f), 1f);
        warnText.setPadding(0, a.dp(3), 0, 0);
        warnBox.addView(warnText);
        left.addView(warnBox, new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 8);

        // 2) Official website + author social handles (compact single card)
        left.addView(
                buildInfoCard(
                        a,
                        "唯一官网与作者全平台社媒",
                        OFFICIAL_SITE_DISPLAY + "  ·  " + AUTHOR_SOCIAL_NAME,
                        AUTHOR_SOCIAL_PLATFORMS + "（交流群见官网 / 设置页）",
                        0xff6ee7b7),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 8);

        // 3) Sincere, non-pushy voluntary support / donation message
        LinearLayout donateBox = a.vertical();
        donateBox.setPadding(a.dp(13), a.dp(9), a.dp(13), a.dp(9));
        GradientDrawable donateBg = new GradientDrawable();
        donateBg.setColor(0x20f472b6);
        donateBg.setCornerRadius(a.dp(12));
        donateBg.setStroke(Math.max(1, a.dp(1)), 0x44f9a8d4);
        donateBox.setBackground(donateBg);
        TextView dTitle = a.text(NOTICE_DONATE_TITLE, 12.5f, 0xfffbcfe8);
        dTitle.setTypeface(null, Typeface.BOLD);
        donateBox.addView(dTitle);
        TextView dText = a.text(NOTICE_DONATE_BODY, 12f, 0xe8f1f5f9);
        dText.setLineSpacing(a.dp(2.5f), 1f);
        dText.setPadding(0, a.dp(3), 0, 0);
        donateBox.addView(dText);
        TextView dUrl = a.text("官网捐赠区：" + OFFICIAL_DONATE_URL, 11.5f, 0xfff9a8d4);
        dUrl.setTypeface(null, Typeface.BOLD);
        dUrl.setPadding(0, a.dp(4), 0, 0);
        donateBox.addView(dUrl);
        left.addView(donateBox, new LinearLayout.LayoutParams(-1, -2));

        split.addView(left, leftLp);
        split.addView(
                buildQrPanel(
                        a,
                        qrSize,
                        OFFICIAL_SITE_URL,
                        "手机扫码访问唯一官网",
                        "tv-first-launch-qr",
                        qrViewRef,
                        qrTitleRef,
                        qrUrlRef),
                new LinearLayout.LayoutParams(-2, -2));
        outer.addView(split, new LinearLayout.LayoutParams(-1, -2));
        return outer;
    }

    private static LinearLayout buildContactBody(
            MainActivity a,
            int qrSize,
            boolean showGroup,
            ImageView[] qrViewRef,
            TextView[] qrTitleRef,
            TextView[] qrUrlRef) {
        LinearLayout outer = a.vertical();
        outer.setTag("tv-contact-author-body");

        LinearLayout split = a.row();
        split.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout left = a.vertical();
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, -2, 1f);
        leftLp.rightMargin = a.dp(18);

        LinearLayout warnBox = a.vertical();
        warnBox.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
        GradientDrawable warnBg = new GradientDrawable();
        warnBg.setColor(0x28ffb340);
        warnBg.setCornerRadius(a.dp(12));
        warnBg.setStroke(Math.max(1, a.dp(1)), 0x66ffb340);
        warnBox.setBackground(warnBg);
        TextView warnTitle = a.text("安全下载提醒 · 官网为唯一更新渠道", 12.5f, 0xffffd17a);
        warnTitle.setTypeface(null, Typeface.BOLD);
        warnBox.addView(warnTitle);
        TextView warnText = a.text(SECURITY_REMINDER, 12.5f, 0xfff8fafc);
        warnText.setLineSpacing(a.dp(2.5f), 1f);
        warnText.setPadding(0, a.dp(3), 0, 0);
        warnBox.addView(warnText);
        left.addView(warnBox, new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 9);

        left.addView(
                buildInfoCard(
                        a,
                        "作者各社媒账号（全平台同名）",
                        AUTHOR_SOCIAL_NAME,
                        AUTHOR_SOCIAL_PLATFORMS,
                        0xff7cc4ff),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 8);

        left.addView(
                buildInfoCard(
                        a, "Marco 唯一官网", OFFICIAL_SITE_DISPLAY, OFFICIAL_SITE_URL, 0xff6ee7b7),
                new LinearLayout.LayoutParams(-1, -2));
        a.gap(left, 8);

        left.addView(
                buildInfoCard(
                        a, "官网交流群链接", OFFICIAL_GROUP_URL, "打开或扫码进入官网交流群页面，获取最新官方交流群入口", 0xffc4b5fd),
                new LinearLayout.LayoutParams(-1, -2));

        split.addView(left, leftLp);
        split.addView(
                buildQrPanel(
                        a,
                        qrSize,
                        showGroup ? OFFICIAL_GROUP_URL : OFFICIAL_SITE_URL,
                        showGroup ? "手机扫码进入官网交流群" : "手机扫码访问 Marco 官网",
                        "tv-contact-qr",
                        qrViewRef,
                        qrTitleRef,
                        qrUrlRef),
                new LinearLayout.LayoutParams(-2, -2));
        outer.addView(split, new LinearLayout.LayoutParams(-1, -2));
        return outer;
    }

    private static LinearLayout buildQrPanel(
            MainActivity a,
            int qrSize,
            String qrUrl,
            String qrCaption,
            String qrTag,
            ImageView[] qrViewRef,
            TextView[] qrTitleRef,
            TextView[] qrUrlRef) {
        LinearLayout right = a.vertical();
        right.setGravity(Gravity.CENTER_HORIZONTAL);
        right.setPadding(a.dp(12), a.dp(12), a.dp(12), a.dp(10));
        GradientDrawable rightBg = new GradientDrawable();
        rightBg.setColor(0x22ffffff);
        rightBg.setCornerRadius(a.dp(16));
        rightBg.setStroke(Math.max(1, a.dp(1)), 0x2cffffff);
        right.setBackground(rightBg);

        FrameLayout qrFrame = new FrameLayout(a);
        qrFrame.setPadding(a.dp(8), a.dp(8), a.dp(8), a.dp(8));
        GradientDrawable whiteFrame = new GradientDrawable();
        whiteFrame.setColor(Color.WHITE);
        whiteFrame.setCornerRadius(a.dp(10));
        qrFrame.setBackground(whiteFrame);

        ImageView qrImage = new ImageView(a);
        qrImage.setTag(qrTag);
        qrImage.setContentDescription(qrCaption);
        Bitmap qrBmp = CrashReportDialog.renderQrBitmap(qrUrl, qrSize);
        if (qrBmp != null) {
            qrImage.setImageBitmap(qrBmp);
        }
        qrFrame.addView(qrImage, new FrameLayout.LayoutParams(qrSize, qrSize));
        right.addView(qrFrame, new LinearLayout.LayoutParams(-2, -2));

        TextView capTv = a.text(qrCaption, 12.5f, MainActivity.WHITE);
        capTv.setTypeface(null, Typeface.BOLD);
        capTv.setGravity(Gravity.CENTER);
        capTv.setPadding(0, a.dp(8), 0, 0);
        right.addView(capTv, new LinearLayout.LayoutParams(-2, -2));

        TextView urlTv = a.text(qrUrl, 10.5f, 0xb8cbd5e1);
        urlTv.setGravity(Gravity.CENTER);
        urlTv.setSingleLine(true);
        urlTv.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        urlTv.setMaxWidth(qrSize + a.dp(24));
        urlTv.setPadding(0, a.dp(3), 0, 0);
        right.addView(urlTv, new LinearLayout.LayoutParams(-2, -2));

        if (qrViewRef != null) qrViewRef[0] = qrImage;
        if (qrTitleRef != null) qrTitleRef[0] = capTv;
        if (qrUrlRef != null) qrUrlRef[0] = urlTv;
        return right;
    }

    private static LinearLayout buildInfoCard(
            MainActivity a, String label, String primary, String secondary, int accentColor) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(13), a.dp(8), a.dp(13), a.dp(8));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0x1effffff);
        bg.setCornerRadius(a.dp(12));
        bg.setStroke(Math.max(1, a.dp(1)), 0x22ffffff);
        card.setBackground(bg);

        TextView labelTv = a.text(label, 11f, 0xb0cbd5e1);
        card.addView(labelTv);

        TextView primaryTv = a.text(primary, 14.5f, accentColor);
        primaryTv.setTypeface(null, Typeface.BOLD);
        primaryTv.setPadding(0, a.dp(2), 0, 0);
        card.addView(primaryTv);

        if (secondary != null && !secondary.isEmpty()) {
            TextView secTv = a.text(secondary, 11.5f, 0xd8e2e8f0);
            secTv.setLineSpacing(a.dp(2f), 1f);
            secTv.setPadding(0, a.dp(2), 0, 0);
            card.addView(secTv);
        }
        return card;
    }
}

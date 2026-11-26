package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Arrays;
import java.util.List;

/**
 * Per-install &amp; per-update official channel, anti-scam security &amp; voluntary donation notice
 * plus Settings author contact / community channel / donation sheet for Android Mobile / Tablet.
 *
 * <p>Persists its seen app {@code versionCode} in device-local {@link #PREFS_FILE} outside {@link
 * Prefs#KEYS} so backup/sync schema invariants remain strictly unchanged, while automatically
 * reminding the user once after every version upgrade.
 */
final class MobileAuthorNotice {
    static final String PREFS_FILE = "marco_first_launch_notice";
    static final String KEY_SEEN_VERSION = "first_launch_notice_version";
    static final String KEY_SEEN_APP_VERSION_CODE = "notice_seen_app_version_code";
    static final int CURRENT_VERSION = 2;

    static final String AUTHOR_SOCIAL_NAME = "PILIPALA来信";
    static final String[] SOCIAL_PLATFORMS = {"小红书", "B站", "抖音", "公众号", "视频号"};
    static final String AUTHOR_SOCIAL_FULL = "PILIPALA来信（小红书、B站、抖音、公众号、视频号）";
    static final String OFFICIAL_SITE_DISPLAY = "marcotv.wlj9919.top";
    static final String OFFICIAL_SITE_URL = "https://marcotv.wlj9919.top";
    static final String OFFICIAL_DONATE_DISPLAY = "marcotv.wlj9919.top/movie/#donate";
    static final String OFFICIAL_DONATE_URL = "https://marcotv.wlj9919.top/movie/#donate";
    static final String OFFICIAL_CHANNEL_NAME = "Marco交流区";
    static final String OFFICIAL_CHANNEL_URL = "https://pd.qq.com/s/N45e3aaawv?b=9";
    static final String OFFICIAL_DOWNLOAD_WARNING =
            "Marco Movie 是完全免费软件，官网（marcotv.wlj9919.top）为唯一官方更新与下载渠道。请勿轻信任何付费代购、收费群或不明渠道安装包，谨防受骗与恶意篡改病毒风险。";
    static final String DONATE_TITLE = "捐赠支持 · 请作者喝杯咖啡";
    static final String DONATE_SUBTITLE = "永久免费 · 自愿随心 · 不影响任何功能";
    static final String DONATE_MESSAGE =
            "Marco Movie 永久免费、无广告、无会员限制，由作者利用业余时间独立开发与多端维护。如果你觉得它让日常追剧看片顺手了一点，欢迎前往官网捐赠区请作者喝杯咖啡；不捐赠也完全享有全部功能，你的每一次使用和反馈都同样珍贵。";
    static final String DONATE_NOTICE_COMPACT =
            "软件永久免费、无广告无付费墙，由作者业余时间独立维护。如果这次更新让你觉得顺手，欢迎去官网捐赠区请作者喝杯咖啡，支持项目持续迭代；不捐赠也享有全部功能。";

    private static final int TINT_BLUE = 0xFF0A84FF;
    private static final int TINT_TEAL = 0xFF06B6D4;
    private static final int TINT_GREEN = 0xFF34C759;
    private static final int TINT_AMBER = 0xFFF59E0B;
    private static final int TINT_ROSE = 0xFFEC4899;

    private static Dialog activeDialog;

    private MobileAuthorNotice() {}

    /** Device-local store abstraction for pure-JVM testing without Android framework stubs. */
    interface Store {
        int getInt(String key, int defaultValue);

        void putInt(String key, int value);
    }

    /** Android {@link SharedPreferences} adapter backed by {@link #PREFS_FILE}. */
    static final class SharedPrefsStore implements Store {
        private final SharedPreferences prefs;

        SharedPrefsStore(Context context) {
            this.prefs = context.getApplicationContext().getSharedPreferences(PREFS_FILE, 0);
        }

        @Override
        public int getInt(String key, int defaultValue) {
            return prefs.getInt(key, defaultValue);
        }

        @Override
        public void putInt(String key, int value) {
            prefs.edit().putInt(key, value).apply();
        }
    }

    /**
     * Pure-JVM state controller governing first-launch and per-update presentation, Privacy Space
     * suppression, per-version persistence, and single-shot post-dismiss continuation.
     */
    static final class Controller {
        private final Store store;
        private final int targetVersionCode;
        private boolean shownThisSession;

        Controller(Store store) {
            this(store, CURRENT_VERSION);
        }

        Controller(Store store, int currentAppVersionCode) {
            this.store = store;
            this.targetVersionCode = Math.max(CURRENT_VERSION, currentAppVersionCode);
        }

        int targetVersionCode() {
            return targetVersionCode;
        }

        boolean isUpgradeNotice() {
            if (store == null) return false;
            return store.getInt(KEY_SEEN_APP_VERSION_CODE, 0) > 0
                    || store.getInt(KEY_SEEN_VERSION, 0) > 0;
        }

        boolean shouldShow(boolean privateMode, boolean hasBlockingOverlay) {
            if (privateMode || hasBlockingOverlay || shownThisSession) {
                return false;
            }
            if (store == null) {
                return false;
            }
            return store.getInt(KEY_SEEN_APP_VERSION_CODE, 0) < targetVersionCode;
        }

        void markShown() {
            shownThisSession = true;
            if (store != null) {
                if (store.getInt(KEY_SEEN_VERSION, 0) < CURRENT_VERSION) {
                    store.putInt(KEY_SEEN_VERSION, CURRENT_VERSION);
                }
                if (store.getInt(KEY_SEEN_APP_VERSION_CODE, 0) < targetVersionCode) {
                    store.putInt(KEY_SEEN_APP_VERSION_CODE, targetVersionCode);
                }
            }
        }
    }

    /** Wraps a dismissal continuation so Back, scrim, swipe, and button presses run it once. */
    static Runnable singleShot(final Runnable action) {
        final boolean[] done = {false};
        return () -> {
            if (done[0]) return;
            done[0] = true;
            if (action != null) action.run();
        };
    }

    /**
     * Pure-JVM URL whitelist verifying only official Marco HTTPS URLs and the exact Tencent
     * community channel URL are opened.
     */
    static boolean isTrustedOfficialUrl(String url) {
        if (url == null) return false;
        String trimmed = url.trim();
        return trimmed.equals(OFFICIAL_SITE_URL)
                || trimmed.startsWith(OFFICIAL_SITE_URL + "/")
                || trimmed.equals(OFFICIAL_CHANNEL_URL);
    }

    @SuppressWarnings("deprecation")
    static int installedVersionCode(Context context) {
        if (context == null) return CURRENT_VERSION;
        try {
            PackageInfo info =
                    context.getApplicationContext()
                            .getPackageManager()
                            .getPackageInfo(context.getPackageName(), 0);
            if (info != null && info.versionCode > 0) {
                return info.versionCode;
            }
        } catch (Throwable ignored) {
        }
        return CURRENT_VERSION;
    }

    static String installedVersionName(Context context) {
        if (context == null) return "";
        try {
            PackageInfo info =
                    context.getApplicationContext()
                            .getPackageManager()
                            .getPackageInfo(context.getPackageName(), 0);
            if (info != null && info.versionName != null) {
                return info.versionName.trim();
            }
        } catch (Throwable ignored) {
        }
        return "";
    }

    static boolean shouldShowFirstLaunch(Context context) {
        if (context == null) return false;
        return new Controller(new SharedPrefsStore(context), installedVersionCode(context))
                .shouldShow(false, false);
    }

    static boolean isShowing() {
        return activeDialog != null && activeDialog.isShowing();
    }

    static void dismissActive() {
        Dialog dlg = activeDialog;
        activeDialog = null;
        if (dlg != null && dlg.isShowing()) {
            try {
                dlg.dismiss();
            } catch (Throwable ignored) {
            }
        }
    }

    private static boolean isActivityGone(MainActivity a) {
        return a == null || a.isFinishing() || (Build.VERSION.SDK_INT >= 17 && a.isDestroyed());
    }

    /**
     * Shows the official channel, anti-scam &amp; voluntary donation popup once on fresh install and
     * once after every version upgrade. Runs {@code onAfterDismiss} exactly once after the popup
     * closes (or immediately if skipped / unable to display).
     */
    static boolean maybeShowFirstLaunch(final MainActivity a, final Runnable onAfterDismiss) {
        final Runnable continueOnce = singleShot(onAfterDismiss);
        if (isActivityGone(a)) {
            return false;
        }
        boolean blocked =
                (a.appDialog != null && a.appDialog.isShowing())
                        || isShowing()
                        || (a.current != null && a.current.player);
        final Controller controller =
                new Controller(new SharedPrefsStore(a), installedVersionCode(a));
        if (!controller.shouldShow(a.privateMode, blocked)) {
            continueOnce.run();
            return false;
        }
        final boolean isUpgrade = controller.isUpgradeNotice();
        final String verName = installedVersionName(a);
        final String sheetTitle = isUpgrade ? "版本更新与官方渠道提示" : "官方渠道与安全提示";
        final String sheetSubtitle;
        if (isUpgrade) {
            sheetSubtitle =
                    verName.isEmpty()
                            ? "已更新至新版本 · 官网为唯一更新渠道，免费软件谨防受骗"
                            : ("已更新至 v" + verName + " · 官网为唯一更新渠道，谨防受骗");
        } else {
            sheetSubtitle =
                    verName.isEmpty()
                            ? "感谢安装 Marco Movie · 免费软件，请认准官方唯一渠道"
                            : ("欢迎使用 Marco Movie v" + verName + " · 免费软件，请认准官网");
        }

        final MobileTheme.Palette p = MobileTheme.of(a);
        final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];

        LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(2), 0, a.dp(4));

        // 1. Official site + anti-scam warning card (prominent at top after update)
        content.addView(
                buildOfficialSecurityCard(a, p, true), new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        // 2. Author social handles card
        content.addView(buildAuthorSocialCard(a, p), new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        // 3. Natural, low-pressure voluntary donation card
        content.addView(buildDonationCard(a, p, true), new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 16);

        // 4. Primary high-contrast acknowledge button
        TextView confirmBtn = a.text("我知道了，开始使用", 15.5f, Color.WHITE);
        confirmBtn.setTypeface(null, Typeface.BOLD);
        confirmBtn.setGravity(Gravity.CENTER);
        confirmBtn.setMinimumHeight(a.dp(48));
        confirmBtn.setPadding(a.dp(16), a.dp(12), a.dp(16), a.dp(12));
        confirmBtn.setBackground(a.bg(p.accent, 14));
        MobileMotion.bindPress(confirmBtn, 0.97f);
        confirmBtn.setOnClickListener(
                v -> {
                    if (handleRef[0] != null) {
                        handleRef[0].dismiss();
                    }
                });
        content.addView(confirmBtn, new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 10);

        // 5. Secondary quick links row (official website & official Tencent channel)
        LinearLayout quickRow = a.row();
        quickRow.setGravity(Gravity.CENTER);
        TextView siteLink = buildSecondaryPill(a, p, "访问 Marco 官网");
        siteLink.setOnClickListener(v -> openOfficialUrl(a, OFFICIAL_SITE_URL, "Marco 官网"));
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(0, -2, 1f);
        slp.rightMargin = a.dp(8);
        quickRow.addView(siteLink, slp);

        TextView channelLink = buildSecondaryPill(a, p, "加入官方交流频道");
        channelLink.setOnClickListener(v -> openOfficialUrl(a, OFFICIAL_CHANNEL_URL, "官网交流频道"));
        quickRow.addView(channelLink, new LinearLayout.LayoutParams(0, -2, 1f));
        content.addView(quickRow, new LinearLayout.LayoutParams(-1, -2));

        MobileBottomSheet.SheetHandle handle =
                MobileBottomSheet.showHandle(
                        a, sheetTitle, sheetSubtitle, null, null, content, true);
        handleRef[0] = handle;
        final Dialog dlg = handle.dialog();
        if (dlg == null) {
            continueOnce.run();
            return false;
        }

        controller.markShown();
        activeDialog = dlg;
        dlg.setOnDismissListener(
                d -> {
                    if (activeDialog == dlg) {
                        activeDialog = null;
                    }
                    if (!isActivityGone(a)) {
                        a.ui.post(continueOnce);
                    }
                });
        return true;
    }

    /**
     * Opens the Settings "联系与反馈作者" sheet displaying author social handles, official website,
     * Tencent exchange channel, anti-scam reminder, and voluntary donation support card.
     */
    static void showContactSheet(final MainActivity a) {
        if (isActivityGone(a)) return;
        final MobileTheme.Palette p = MobileTheme.of(a);

        LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(2), 0, a.dp(4));

        // 1. Author social handles card with 1-tap copy
        content.addView(buildAuthorSocialCard(a, p), new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        // 2. Official website & Tencent exchange channel actions
        LinearLayout officialGroup =
                MobileSectionGroup.create(
                        a,
                        "官网与交流频道",
                        OFFICIAL_DOWNLOAD_WARNING,
                        Arrays.<View>asList(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_LINK,
                                        TINT_TEAL,
                                        "官网交流频道",
                                        OFFICIAL_CHANNEL_NAME,
                                        () -> openOfficialUrl(a, OFFICIAL_CHANNEL_URL, "官网交流频道")),
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_EXTERNAL,
                                        TINT_GREEN,
                                        "Marco 官网",
                                        OFFICIAL_SITE_DISPLAY,
                                        () -> openOfficialUrl(a, OFFICIAL_SITE_URL, "Marco 官网")),
                                MobileSectionGroup.actionRow(
                                        a,
                                        MobileIcons.IC_CLIPBOARD,
                                        TINT_BLUE,
                                        "复制官网交流频道链接",
                                        "复制",
                                        p.accent,
                                        () ->
                                                copyToClipboard(
                                                        a, "官网交流频道链接", OFFICIAL_CHANNEL_URL))));
        content.addView(officialGroup, new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        // 3. Natural voluntary donation support section
        content.addView(buildDonationCard(a, p, false), new LinearLayout.LayoutParams(-1, -2));

        MobileBottomSheet.showHandle(
                a, "联系与反馈作者", "各平台统一账号名 · 欢迎在社媒或交流频道反馈建议", null, null, content, true);
    }

    private static LinearLayout buildDonationCard(
            final MainActivity a, final MobileTheme.Palette p, boolean compact) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(14), a.dp(14), a.dp(14), a.dp(14));
        GradientDrawable cardBg = new GradientDrawable();
        cardBg.setColor(p.isDark ? 0x1CEC4899 : 0x10EC4899);
        cardBg.setCornerRadius(a.dp(16));
        cardBg.setStroke(MobileTheme.hairlinePx(a), p.isDark ? 0x44EC4899 : 0x33EC4899);
        card.setBackground(cardBg);

        LinearLayout headRow = a.row();
        headRow.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout badge = MobileIcons.badge(a, MobileIcons.IC_HEART_FILLED, TINT_ROSE, 28, 15);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(a.dp(28), a.dp(28));
        blp.rightMargin = a.dp(10);
        headRow.addView(badge, blp);

        LinearLayout titleCol = a.vertical();
        TextView title = a.text(DONATE_TITLE, 14.5f, p.textPrimary);
        title.setTypeface(null, Typeface.BOLD);
        titleCol.addView(title);
        TextView sub = a.text(DONATE_SUBTITLE, 12f, p.textSecondary);
        titleCol.addView(sub);
        headRow.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));
        card.addView(headRow, new LinearLayout.LayoutParams(-1, -2));

        a.gap(card, 10);

        TextView desc =
                a.text(compact ? DONATE_NOTICE_COMPACT : DONATE_MESSAGE, 13f, p.textPrimary);
        desc.setLineSpacing(a.dp(3.5f), 1f);
        card.addView(desc, new LinearLayout.LayoutParams(-1, -2));

        a.gap(card, 12);

        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView donateBtn = a.text("前往官网捐赠区", 13.5f, Color.WHITE);
        donateBtn.setTypeface(null, Typeface.BOLD);
        donateBtn.setGravity(Gravity.CENTER);
        donateBtn.setMinimumHeight(a.dp(40));
        donateBtn.setPadding(a.dp(16), a.dp(9), a.dp(16), a.dp(9));
        donateBtn.setBackground(a.bg(TINT_ROSE, 12));
        MobileMotion.bindPress(donateBtn, 0.96f);
        donateBtn.setOnClickListener(v -> openOfficialUrl(a, OFFICIAL_DONATE_URL, "官网捐赠区"));
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(0, -2, 1f);
        actionRow.addView(donateBtn, dlp);

        if (!compact) {
            TextView copyBtn = a.text("复制链接", 13f, p.textSecondary);
            copyBtn.setTypeface(null, Typeface.BOLD);
            copyBtn.setGravity(Gravity.CENTER);
            copyBtn.setMinimumHeight(a.dp(40));
            copyBtn.setPadding(a.dp(14), a.dp(9), a.dp(14), a.dp(9));
            copyBtn.setBackground(MobileTheme.cardBg(a, 12));
            MobileMotion.bindPress(copyBtn, 0.95f);
            copyBtn.setOnClickListener(v -> copyToClipboard(a, "官网捐赠区链接", OFFICIAL_DONATE_URL));
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, -2);
            clp.leftMargin = a.dp(8);
            actionRow.addView(copyBtn, clp);
        }

        card.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));
        return card;
    }

    private static LinearLayout buildAuthorSocialCard(
            final MainActivity a, final MobileTheme.Palette p) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(14), a.dp(14), a.dp(14), a.dp(14));
        card.setBackground(MobileTheme.subtleBg(a, 16));

        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout badge = MobileIcons.badge(a, MobileIcons.IC_SPARKLE, TINT_BLUE, 28, 16);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(a.dp(28), a.dp(28));
        blp.rightMargin = a.dp(10);
        topRow.addView(badge, blp);

        TextView label = a.text("作者各社媒账号名", 13f, p.textSecondary);
        label.setTypeface(null, Typeface.BOLD);
        topRow.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView copyBtn = a.text("复制账号名", 12.5f, p.accent);
        copyBtn.setTypeface(null, Typeface.BOLD);
        copyBtn.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
        copyBtn.setBackground(a.bg(p.pillSelectedFill, 999));
        MobileMotion.bindPress(copyBtn, 0.94f);
        copyBtn.setOnClickListener(v -> copyToClipboard(a, "作者社媒账号名", AUTHOR_SOCIAL_NAME));
        topRow.addView(copyBtn, new LinearLayout.LayoutParams(-2, -2));
        card.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        a.gap(card, 10);

        TextView handleText = a.text(AUTHOR_SOCIAL_NAME, 20f, p.textPrimary);
        handleText.setTypeface(null, Typeface.BOLD);
        handleText.setSingleLine(true);
        handleText.setEllipsize(TextUtils.TruncateAt.END);
        card.addView(handleText, new LinearLayout.LayoutParams(-1, -2));

        a.gap(card, 10);

        // Platform chips arranged across two clean rows so narrow screens never clip labels
        LinearLayout row1 = buildPlatformChipRow(a, p, Arrays.asList("小红书", "B站", "抖音"));
        card.addView(row1, new LinearLayout.LayoutParams(-1, -2));
        a.gap(card, 6);
        LinearLayout row2 = buildPlatformChipRow(a, p, Arrays.asList("公众号", "视频号"));
        card.addView(row2, new LinearLayout.LayoutParams(-1, -2));

        return card;
    }

    private static LinearLayout buildPlatformChipRow(
            MainActivity a, MobileTheme.Palette p, List<String> names) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        for (int i = 0; i < names.size(); i++) {
            TextView chip = a.text(names.get(i), 12f, p.textPrimary);
            chip.setTypeface(null, Typeface.BOLD);
            chip.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(p.bgCard);
            bg.setCornerRadius(a.dp(999));
            bg.setStroke(MobileTheme.hairlinePx(a), p.hairline);
            chip.setBackground(bg);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = a.dp(8);
            row.addView(chip, lp);
        }
        return row;
    }

    private static LinearLayout buildOfficialSecurityCard(
            final MainActivity a, final MobileTheme.Palette p, boolean includeWarning) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(14), a.dp(14), a.dp(14), a.dp(14));
        card.setBackground(MobileTheme.subtleBg(a, 16));

        LinearLayout siteRow = a.row();
        siteRow.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout badge = MobileIcons.badge(a, MobileIcons.IC_LINK, TINT_GREEN, 28, 16);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(a.dp(28), a.dp(28));
        blp.rightMargin = a.dp(10);
        siteRow.addView(badge, blp);

        LinearLayout siteCol = a.vertical();
        TextView siteLabel = a.text("Marco 官网（唯一官方更新渠道）", 12.5f, p.textSecondary);
        siteCol.addView(siteLabel);
        TextView siteUrl = a.text(OFFICIAL_SITE_DISPLAY, 15.5f, p.accent);
        siteUrl.setTypeface(null, Typeface.BOLD);
        siteUrl.setSingleLine(true);
        siteUrl.setEllipsize(TextUtils.TruncateAt.END);
        siteCol.addView(siteUrl);
        siteRow.addView(siteCol, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView copySite = a.text("复制网址", 12.5f, p.textSecondary);
        copySite.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
        copySite.setBackground(MobileTheme.cardBg(a, 999));
        MobileMotion.bindPress(copySite, 0.94f);
        copySite.setOnClickListener(v -> copyToClipboard(a, "Marco 官网地址", OFFICIAL_SITE_URL));
        siteRow.addView(copySite, new LinearLayout.LayoutParams(-2, -2));

        MobileSectionGroup.bindPressHighlight(siteRow, p.bgPressed);
        siteRow.setOnClickListener(v -> openOfficialUrl(a, OFFICIAL_SITE_URL, "Marco 官网"));
        card.addView(siteRow, new LinearLayout.LayoutParams(-1, -2));

        if (includeWarning) {
            a.gap(card, 12);
            LinearLayout warnBox = a.row();
            warnBox.setGravity(Gravity.TOP);
            warnBox.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
            warnBox.setBackground(a.bg(p.isDark ? 0x26F59E0B : 0x1CF59E0B, 12));

            MobileIcons.IconView warnIcon =
                    MobileIcons.create(a, MobileIcons.IC_WARNING, 16f, TINT_AMBER);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(a.dp(16), a.dp(16));
            ilp.rightMargin = a.dp(8);
            ilp.topMargin = a.dp(2);
            warnBox.addView(warnIcon, ilp);

            TextView warnText = a.text(OFFICIAL_DOWNLOAD_WARNING, 13f, p.textPrimary);
            warnText.setLineSpacing(a.dp(3f), 1f);
            warnBox.addView(warnText, new LinearLayout.LayoutParams(0, -2, 1f));

            card.addView(warnBox, new LinearLayout.LayoutParams(-1, -2));
        }

        return card;
    }

    private static TextView buildSecondaryPill(
            MainActivity a, MobileTheme.Palette p, String label) {
        TextView btn = a.text(label, 13.5f, p.textPrimary);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setGravity(Gravity.CENTER);
        btn.setMinimumHeight(a.dp(42));
        btn.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
        btn.setBackground(MobileTheme.subtleBg(a, 12));
        MobileMotion.bindPress(btn, 0.96f);
        return btn;
    }

    static void openOfficialUrl(MainActivity a, String url, String label) {
        if (isActivityGone(a) || !isTrustedOfficialUrl(url)) return;
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            a.startActivity(intent);
        } catch (Throwable ignored) {
            copyToClipboard(a, label, url);
            a.toast("未检测到浏览器，已复制" + label + "链接");
        }
    }

    static void copyToClipboard(MainActivity a, String label, String text) {
        if (a == null || text == null || text.isEmpty()) return;
        try {
            ClipboardManager cm = (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null) {
                cm.setPrimaryClip(ClipData.newPlainText(label, text));
                a.toast("已复制" + label + "：" + text);
                return;
            }
        } catch (Throwable ignored) {
        }
        a.toast(label + "：" + text);
    }
}

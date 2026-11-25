package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
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
 * First-launch official channel &amp; anti-malware security notice plus Settings author contact /
 * community feedback sheet for Android Mobile / Tablet.
 *
 * <p>Persists its one-time seen version in device-local {@link #PREFS_FILE} outside {@link
 * Prefs#KEYS} so backup/sync schema invariants remain strictly unchanged.
 */
final class MobileAuthorNotice {
    static final String PREFS_FILE = "marco_first_launch_notice";
    static final String KEY_SEEN_VERSION = "first_launch_notice_version";
    static final int CURRENT_VERSION = 1;

    static final String AUTHOR_SOCIAL_NAME = "PILIPALA来信";
    static final String[] SOCIAL_PLATFORMS = {"小红书", "B站", "抖音", "公众号", "视频号"};
    static final String AUTHOR_SOCIAL_FULL = "PILIPALA来信（小红书、B站、抖音、公众号、视频号）";
    static final String OFFICIAL_SITE_DISPLAY = "marcotv.wlj9919.top";
    static final String OFFICIAL_SITE_URL = "https://marcotv.wlj9919.top";
    static final String OFFICIAL_GROUP_DISPLAY = "marcotv.wlj9919.top/movie/#group";
    static final String OFFICIAL_GROUP_URL = "https://marcotv.wlj9919.top/movie/#group";
    static final String OFFICIAL_DOWNLOAD_WARNING = "下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。";

    private static final int TINT_BLUE = 0xFF0A84FF;
    private static final int TINT_TEAL = 0xFF06B6D4;
    private static final int TINT_GREEN = 0xFF34C759;
    private static final int TINT_AMBER = 0xFFF59E0B;

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
     * Pure-JVM state controller governing first-launch presentation, Privacy Space suppression,
     * one-time persistence, and single-shot post-dismiss continuation.
     */
    static final class Controller {
        private final Store store;
        private boolean shownThisSession;

        Controller(Store store) {
            this.store = store;
        }

        boolean shouldShow(boolean privateMode, boolean hasBlockingOverlay) {
            if (privateMode || hasBlockingOverlay || shownThisSession) {
                return false;
            }
            if (store == null) {
                return false;
            }
            return store.getInt(KEY_SEEN_VERSION, 0) < CURRENT_VERSION;
        }

        void markShown() {
            shownThisSession = true;
            if (store != null && store.getInt(KEY_SEEN_VERSION, 0) < CURRENT_VERSION) {
                store.putInt(KEY_SEEN_VERSION, CURRENT_VERSION);
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

    /** Pure-JVM URL whitelist verifying only official Marco HTTPS URLs are opened. */
    static boolean isTrustedOfficialUrl(String url) {
        if (url == null) return false;
        String trimmed = url.trim();
        return trimmed.equals(OFFICIAL_SITE_URL) || trimmed.startsWith(OFFICIAL_SITE_URL + "/");
    }

    static boolean shouldShowFirstLaunch(Context context) {
        if (context == null) return false;
        return new Controller(new SharedPrefsStore(context)).shouldShow(false, false);
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
     * Shows the one-time first-launch official channel &amp; safety popup if unseen on this
     * installation. Runs {@code onAfterDismiss} exactly once after the popup closes (or
     * immediately if skipped / unable to display).
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
        final Controller controller = new Controller(new SharedPrefsStore(a));
        if (!controller.shouldShow(a.privateMode, blocked)) {
            continueOnce.run();
            return false;
        }

        final MobileTheme.Palette p = MobileTheme.of(a);
        final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];

        LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(2), 0, a.dp(4));

        // 1. Author social handles card
        content.addView(buildAuthorSocialCard(a, p), new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        // 2. Official site + anti-malware warning card
        content.addView(
                buildOfficialSecurityCard(a, p, true), new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 16);

        // 3. Primary high-contrast acknowledge button
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

        // 4. Secondary quick links row (official website & community group)
        LinearLayout quickRow = a.row();
        quickRow.setGravity(Gravity.CENTER);
        TextView siteLink = buildSecondaryPill(a, p, "访问 Marco 官网");
        siteLink.setOnClickListener(v -> openOfficialUrl(a, OFFICIAL_SITE_URL, "Marco 官网"));
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(0, -2, 1f);
        slp.rightMargin = a.dp(8);
        quickRow.addView(siteLink, slp);

        TextView groupLink = buildSecondaryPill(a, p, "前往官网交流群");
        groupLink.setOnClickListener(v -> openOfficialUrl(a, OFFICIAL_GROUP_URL, "官网交流群"));
        quickRow.addView(groupLink, new LinearLayout.LayoutParams(0, -2, 1f));
        content.addView(quickRow, new LinearLayout.LayoutParams(-1, -2));

        MobileBottomSheet.SheetHandle handle =
                MobileBottomSheet.showHandle(
                        a, "官方渠道与安全提示", "感谢安装 Marco Movie · 请认准官方发布信息", null, null, content, true);
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
     * Opens the Settings "联系与反馈作者" sheet displaying all author social media handles, official
     * website, community group link, and anti-malware security reminder.
     */
    static void showContactSheet(final MainActivity a) {
        if (isActivityGone(a)) return;
        final MobileTheme.Palette p = MobileTheme.of(a);

        LinearLayout content = a.vertical();
        content.setPadding(0, a.dp(2), 0, a.dp(4));

        // Author social handles card with 1-tap copy
        content.addView(buildAuthorSocialCard(a, p), new LinearLayout.LayoutParams(-1, -2));
        a.gap(content, 12);

        // Official website & community group actions
        LinearLayout officialGroup =
                MobileSectionGroup.create(
                        a,
                        "官网与交流群",
                        OFFICIAL_DOWNLOAD_WARNING,
                        Arrays.<View>asList(
                                MobileSectionGroup.navRow(
                                        a,
                                        MobileIcons.IC_LINK,
                                        TINT_TEAL,
                                        "官网交流群",
                                        "前往加群",
                                        () -> openOfficialUrl(a, OFFICIAL_GROUP_URL, "官网交流群")),
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
                                        "复制官网交流群链接",
                                        "复制",
                                        p.accent,
                                        () -> copyToClipboard(a, "官网交流群链接", OFFICIAL_GROUP_URL))));
        content.addView(officialGroup, new LinearLayout.LayoutParams(-1, -2));

        MobileBottomSheet.showHandle(
                a, "联系与反馈作者", "各平台统一账号名 · 欢迎在社媒或交流群反馈建议", null, null, content, true);
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
        TextView siteLabel = a.text("Marco 官网", 12.5f, p.textSecondary);
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

package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Environment;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.util.Locale;

/**
 * Unified netdisk login & QR credential center.
 *
 * <p>On Android phones/tablets, opens a full-screen iOS secondary page ("我的云盘") aligned 1:1 with
 * {@code flutter/lib/ui/netdisk_sheet.dart} (obsidian-slate palette, priority banner card, and 4
 * two-tier cloud drive cards for 夸父 / 优汐 / 嘟嘟 / 阿狸). Keeps the anchored D-pad menu on Android TV.
 */
final class AccountPanel {
    private static final int ICON_CLOUD = 1;
    private static final int ICON_QR = 2;
    private static final int ICON_ARROWS_UD = 3;
    private static final int ICON_REFRESH = 4;
    private static final int ICON_PENCIL = 5;
    private static final int ICON_SORT = 6;
    private static final int ICON_CATPAW = 7;

    private static final String PREF_LOGIN_PREFIX = "netdisk_obs_login_";
    private static final String PREF_ENABLED_PREFIX = "netdisk_obs_enabled_";

    private static Runnable activePageRefresh;

    private static final class DriveSpec {
        final String key;
        final String tvAlias;
        final String providerName;
        final String lineSubtitle;
        final String panConfigCode;
        final String wexConfigCode;

        DriveSpec(
                String key,
                String tvAlias,
                String providerName,
                String lineSubtitle,
                String panConfigCode,
                String wexConfigCode) {
            this.key = key;
            this.tvAlias = tvAlias;
            this.providerName = providerName;
            this.lineSubtitle = lineSubtitle;
            this.panConfigCode = panConfigCode;
            this.wexConfigCode = wexConfigCode;
        }
    }

    private static final DriveSpec[] DRIVES = {
        new DriveSpec("quark", "我的夸父", "夸克网盘", "对应线路：夸父智1 / 夸克4K", "quark", "quarkcookie"),
        new DriveSpec("uc", "我的优汐", "UC网盘", "对应线路：优汐智1 / UC4K", "uccookie", "ucpancookie"),
        new DriveSpec("baidu", "我的嘟嘟", "百度网盘", "对应线路：嘟嘟无限2 / 百度原画", "baidu", "baidupanlogin"),
        new DriveSpec("ali", "我的阿狸", "阿里云盘", "对应线路：阿狸原画 / 阿里4K", "LoginShow", "aliyuntoken")
    };

    private AccountPanel() {}

    static Cms.Site findConfigCenterSite(MainActivity a) {
        if (a == null || a.config == null) return null;
        for (Cms.Site site : a.config.sites) {
            String api = site.api == null ? "" : site.api.toLowerCase(Locale.ROOT);
            String key = site.key == null ? "" : site.key.toLowerCase(Locale.ROOT);
            String name = site.name == null ? "" : site.name;
            if (api.contains("mydrive")
                    || key.contains("mydrive")
                    || api.contains("configcenter")
                    || api.contains("localconfig")
                    || api.contains("panconfig")
                    || api.contains("wexconfig")
                    || api.contains("wexokconfig")
                    || key.contains("configcenter")
                    || key.contains("panconfig")
                    || key.contains("wexconfig")
                    || name.contains("我的云盘")
                    || name.contains("配置中心")) {
                return site;
            }
        }
        for (Cms.Site site : a.config.sites) {
            String api = site.api == null ? "" : site.api.toLowerCase(Locale.ROOT);
            String name = site.name == null ? "" : site.name;
            if (api.contains("wogg")
                    || api.contains("mogg")
                    || name.contains("玩偶")
                    || name.contains("木偶")) {
                return site;
            }
        }
        return null;
    }

    static boolean isAvailable(MainActivity a) {
        return findConfigCenterSite(a) != null || CatPawSettings.available(a);
    }

    static void recordObservedSpiderRow(MainActivity a, String accountLabel, String statusLabel) {
        if (a == null || a.prefs == null || accountLabel == null) return;
        String key = null;
        if (accountLabel.contains("夸父") || accountLabel.contains("夸克")) {
            key = "quark";
        } else if (accountLabel.contains("优汐")
                || accountLabel.toUpperCase(Locale.ROOT).contains("UC")) {
            key = "uc";
        } else if (accountLabel.contains("嘟嘟") || accountLabel.contains("百度")) {
            key = "baidu";
        } else if (accountLabel.contains("阿狸") || accountLabel.contains("阿里")) {
            key = "ali";
        }
        if (key == null) return;

        boolean loggedIn =
                accountLabel.contains("已登录")
                        || accountLabel.contains("已绑定")
                        || accountLabel.contains("已配置");
        boolean explicitlyLoggedOut = accountLabel.contains("未登录") || accountLabel.contains("未绑定");
        if (!loggedIn && !explicitlyLoggedOut) return;

        boolean enabled =
                statusLabel != null && (statusLabel.contains("启用中") || statusLabel.contains("已启用"));

        int nextLogin = loggedIn ? 1 : 0;
        int nextEnabled = enabled ? 1 : 0;
        int prevLogin = a.prefs.getInt(PREF_LOGIN_PREFIX + key, -1);
        int prevEnabled = a.prefs.getInt(PREF_ENABLED_PREFIX + key, -1);
        if (prevLogin != nextLogin || prevEnabled != nextEnabled) {
            SharedPreferences.Editor ed = a.prefs.edit();
            ed.putInt(PREF_LOGIN_PREFIX + key, nextLogin);
            ed.putInt(PREF_ENABLED_PREFIX + key, nextEnabled);
            ed.apply();
            Runnable refresh = activePageRefresh;
            if (refresh != null) {
                a.ui.post(refresh);
            }
        }
    }

    static boolean isDriveLoggedIn(MainActivity a, String driveKey) {
        if (a == null || driveKey == null) return false;
        if (a.prefs != null) {
            int obs = a.prefs.getInt(PREF_LOGIN_PREFIX + driveKey, -1);
            if (obs >= 0) return obs == 1;
        }
        return hasNonEmptyCookieFile(a, driveKey);
    }

    static boolean isDriveEnabled(MainActivity a, String driveKey) {
        if (a == null || a.prefs == null || driveKey == null) return false;
        return a.prefs.getInt(PREF_ENABLED_PREFIX + driveKey, 0) == 1;
    }

    static int loggedDriveCount(MainActivity a) {
        int count = 0;
        for (DriveSpec d : DRIVES) {
            if (isDriveLoggedIn(a, d.key)) count++;
        }
        return count;
    }

    private static boolean hasNonEmptyCookieFile(MainActivity a, String driveKey) {
        try {
            File[] roots = {
                a.getCacheDir(),
                a.getFilesDir(),
                a.getExternalCacheDir(),
                a.getExternalFilesDir(null),
                new File(Environment.getExternalStorageDirectory(), "TV")
            };
            String[] names;
            switch (driveKey) {
                case "quark":
                    names = new String[] {"quark.txt", ".quark", "quark_cookie.txt"};
                    break;
                case "uc":
                    names = new String[] {"uc.txt", ".uc", "uc_cookie.txt"};
                    break;
                case "baidu":
                    names = new String[] {"baidu.txt", ".baidu", "bd_cookie.txt"};
                    break;
                case "ali":
                    names = new String[] {"ali.txt", ".ali", "aliyundrive.txt"};
                    break;
                default:
                    return false;
            }
            for (File root : roots) {
                if (root == null || !root.isDirectory()) continue;
                for (String name : names) {
                    File f = new File(root, name);
                    if (f.isFile() && f.length() > 8) return true;
                    File tvSub = new File(new File(root, "TV"), name);
                    if (tvSub.isFile() && tvSub.length() > 8) return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    /** Builds the iOS-matched top-bar Liquid Glass netdisk pill for {@link MobileShell}. */
    static View buildHeaderCapsule(final MainActivity a, final Runnable onTap) {
        boolean unconfigured = a.config == null;
        int logged = unconfigured ? 0 : loggedDriveCount(a);
        LinearLayout pill = a.row();
        pill.setTag("home-netdisk-button");
        pill.setGravity(Gravity.CENTER);
        pill.setPadding(a.dp(10), a.dp(6), a.dp(11), a.dp(6));
        if (logged > 0) {
            GradientDrawable tinted = new GradientDrawable();
            tinted.setShape(GradientDrawable.RECTANGLE);
            tinted.setCornerRadius(a.dp(999));
            tinted.setColor(0x38165b33);
            tinted.setStroke(Math.max(1, a.dp(0.8f)), 0x6630d158);
            pill.setBackground(tinted);
        } else {
            a.glass(pill, 999);
        }

        if (!unconfigured) {
            VectorGlyphView icon =
                    new VectorGlyphView(
                            a,
                            logged > 0 ? ICON_CLOUD : ICON_QR,
                            logged > 0 ? 0xff30d158 : 0xff5ac8fa);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
            ilp.rightMargin = a.dp(4);
            pill.addView(icon, ilp);
        }

        TextView label = a.text(unconfigured ? "＋配置" : "网盘", 12.5f, Color.WHITE);
        label.setTypeface(null, Typeface.BOLD);
        label.setSingleLine(true);
        pill.addView(label);

        MobileDetailScreen.bindTouchFeedback(pill);
        pill.setOnClickListener(v -> onTap.run());
        return pill;
    }

    static void show(MainActivity a) {
        show(a, null);
    }

    static void show(MainActivity a, View anchor) {
        if (a == null) return;
        if (a.isTvDevice()) {
            showTvDialog(a, anchor);
            return;
        }
        boolean hasCatPaw = CatPawSettings.available(a);
        Cms.Site configSite = findConfigCenterSite(a);
        if (configSite == null && !hasCatPaw) {
            a.notice(
                    "当前订阅未包含网盘配置中心。\n\n"
                            + "请在「设置 → 订阅与账号」导入带有配置中心或网盘源的订阅包后，即可在此统一扫码登录夸克、UC、百度、阿里等网盘。");
            return;
        }
        String backLabel =
                (a.current != null && a.current.home && MobileShell.activeTab == 4) ? "设置" : "返回";
        if (a.current != null && "mobile-netdisk-page".equals(a.current.focus)) {
            renderMobileCloudDrivePage(a, backLabel);
            return;
        }
        MainActivity.Screen page =
                new MainActivity.Screen(() -> renderMobileCloudDrivePage(a, backLabel));
        page.focus = "mobile-netdisk-page";
        a.open(page, true);
    }

    private static void showTvDialog(final MainActivity a, final View anchor) {
        final Dialog dialog = new Dialog(a);
        a.accountDialog = dialog;
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        if (dialog.getWindow() != null) {
            dialog.getWindow().getDecorView().setTag("app-dialog");
        }
        LinearLayout panel = a.vertical();
        panel.setTag("account-panel");
        panel.setPadding(a.dp(24), a.dp(22), a.dp(24), a.dp(18));
        panel.setBackground(a.bg(0xf5222227, 28));
        panel.addView(a.text("网盘与账号", 24, MainActivity.WHITE));
        a.gap(panel, 8);
        TextView note = a.text("登录与账号状态由你导入的配置提供。", 13, MainActivity.MUTED);
        panel.addView(note);
        a.gap(panel, 16);
        String[] labels = {"网盘登录与启用", "登录凭据配置", "网盘优先顺序", "网盘搜索顺序"};
        String[] actions = {"LoginShow", "pushCkShow", "panSortShow", "panSourceSortShow"};
        for (int i = 0; i < labels.length; i++) {
            final String action = actions[i];
            final android.widget.Button item =
                    a.button(
                            labels[i],
                            "account-action:" + action,
                            () -> {
                                dialog.dismiss();
                                PluginDialogStyler.watch(a);
                                new SettingsScreen(a).accountAction(action);
                            });
            item.setOnFocusChangeListener(
                    (v, f) ->
                            FocusMotion.style(
                                    a,
                                    item,
                                    f,
                                    0x18ffffff,
                                    MainActivity.WHITE,
                                    20,
                                    MainActivity.WHITE,
                                    MainActivity.DARK,
                                    false,
                                    1.015f));
            item.setBackground(a.bg(0x18ffffff, 20));
            item.setMinHeight(a.dp(46));
            item.setTextSize(15);
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, a.dp(48));
            size.bottomMargin = a.dp(6);
            panel.addView(item, size);
        }
        if (CatPawSettings.available(a)) {
            final android.widget.Button catItem =
                    a.button(
                            "CatPaw 本机配置",
                            "account-action:catpaw",
                            () -> {
                                dialog.dismiss();
                                CatPawSettings.choose(a);
                            });
            catItem.setBackground(a.bg(0x18ffffff, 20));
            catItem.setMinHeight(a.dp(46));
            catItem.setTextSize(15);
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(-1, a.dp(48));
            size.bottomMargin = a.dp(6);
            panel.addView(catItem, size);
        }
        a.gap(panel, 6);
        android.widget.Button close = a.navButton("完成", "account-close", dialog::dismiss);
        panel.addView(close, new LinearLayout.LayoutParams(-1, a.dp(42)));
        dialog.setContentView(panel);
        dialog.setOnDismissListener(
                d -> {
                    a.accountDialog = null;
                    if (anchor != null && anchor.isAttachedToWindow()) anchor.requestFocus();
                });
        dialog.show();
        final Window window = dialog.getWindow();
        if (window != null) {
            window.getDecorView().setTag("app-dialog");
            window.setBackgroundDrawableResource(android.R.color.transparent);
            int panelW = Math.min(a.dp(410), a.windowWidth() - a.dp(48));
            window.setLayout(panelW, -2);
            WindowManager.LayoutParams lp = window.getAttributes();
            window.setGravity(Gravity.TOP | Gravity.RIGHT);
            int[] point = {0, 0};
            if (anchor != null) anchor.getLocationInWindow(point);
            lp.x = a.dp(38);
            lp.y = anchor == null ? a.dp(80) : point[1] + anchor.getHeight() + a.dp(8);
            lp.dimAmount = .5f;
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            window.setAttributes(lp);
        }
        panel.post(
                () -> {
                    boolean side =
                            a.homeDock != null && anchor != null && a.homeDock.contains(anchor);
                    boolean top = side && a.homeDock.topMode;
                    int pivotY = 0;
                    if (side && window != null) {
                        int[] point = {0, 0};
                        anchor.getLocationInWindow(point);
                        int height = a.windowHeight();
                        WindowManager.LayoutParams position = window.getAttributes();
                        if (top) {
                            int left =
                                    Math.max(
                                            a.dp(24),
                                            Math.min(
                                                    a.windowWidth() - panel.getWidth() - a.dp(24),
                                                    point[0]
                                                            + anchor.getWidth() / 2
                                                            - panel.getWidth() / 2));
                            position.x = a.windowWidth() - left - panel.getWidth();
                            position.y =
                                    Math.max(
                                            a.dp(24),
                                            Math.min(
                                                    height - panel.getHeight() - a.dp(24),
                                                    point[1] + anchor.getHeight() + a.dp(14)));
                            panel.setPivotX(point[0] + anchor.getWidth() / 2 - left);
                        } else {
                            position.x = a.windowWidth() - point[0] + a.dp(12);
                            position.y =
                                    Math.max(
                                            a.dp(24),
                                            Math.min(
                                                    height - panel.getHeight() - a.dp(24),
                                                    point[1]
                                                            + anchor.getHeight() / 2
                                                            - panel.getHeight() / 2));
                        }
                        window.setAttributes(position);
                        pivotY = top ? 0 : point[1] + anchor.getHeight() / 2 - position.y;
                    }
                    if (!top)
                        panel.setPivotX(side ? panel.getWidth() : panel.getWidth() - a.dp(70));
                    panel.setPivotY(pivotY);
                    if (!a.reduced) {
                        panel.setScaleX(.88f);
                        panel.setScaleY(.7f);
                        panel.setAlpha(0);
                        panel.animate()
                                .scaleX(1)
                                .scaleY(1)
                                .alpha(1)
                                .setDuration(200)
                                .setInterpolator(new DecelerateInterpolator())
                                .start();
                    }
                    View first = panel.findViewWithTag("account-action:LoginShow");
                    if (first != null) first.requestFocus();
                });
    }

    private static void runSafeAccountAction(final MainActivity a, final String action) {
        try {
            CspEngine.syncAllPluginActivities(a);
            PluginDialogStyler.watch(a);
            new SettingsScreen(a).accountAction(action);
        } catch (Throwable t) {
            AppLog.w("AccountPanel", "accountAction failed: " + action, t);
            a.notice(a.message(t));
        }
    }

    private static void dispatchDriveLoginAction(
            final MainActivity a, final Cms.Site configSite, final DriveSpec drive) {
        try {
            CspEngine.syncAllPluginActivities(a);
            PluginDialogStyler.watch(a);
            if (configSite != null) {
                String api = configSite.api == null ? "" : configSite.api.toLowerCase(Locale.ROOT);
                String key = configSite.key == null ? "" : configSite.key.toLowerCase(Locale.ROOT);
                if (api.contains("panconfig") || key.contains("panconfig")) {
                    if (!"LoginShow".equals(drive.panConfigCode)) {
                        a.sourceAction(configSite, drive.panConfigCode);
                        return;
                    }
                } else if (api.contains("wexconfig")
                        || api.contains("wexokconfig")
                        || key.contains("wexconfig")
                        || key.contains("wexokconfig")) {
                    a.sourceAction(configSite, drive.wexConfigCode);
                    return;
                }
            }
            new SettingsScreen(a).accountAction("LoginShow");
        } catch (Throwable t) {
            AppLog.w("AccountPanel", "dispatchDriveLoginAction failed: " + drive.key, t);
            a.notice(a.message(t));
        }
    }

    /**
     * Renders the full-screen iOS secondary page "我的云盘" matching {@code IosSettingsScaffold} +
     * {@code _NetdiskAccountSheet} in {@code flutter/lib/ui/netdisk_sheet.dart}.
     */
    private static void renderMobileCloudDrivePage(final MainActivity a, final String backLabel) {
        a.applyMobileSystemBars(false);

        final Cms.Site configSite = findConfigCenterSite(a);
        final boolean hasCatPaw = CatPawSettings.available(a);
        final LinearLayout drivesHolder = a.vertical();

        FrameLayout pageRoot =
                new FrameLayout(a) {
                    @Override
                    public void onWindowFocusChanged(boolean hasWindowFocus) {
                        super.onWindowFocusChanged(hasWindowFocus);
                        if (hasWindowFocus) {
                            populateDriveCards(a, drivesHolder, configSite);
                        }
                    }

                    @Override
                    protected void onDetachedFromWindow() {
                        super.onDetachedFromWindow();
                        activePageRefresh = null;
                    }
                };
        pageRoot.setTag("netdisk-account-sheet");
        GradientDrawable pageBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xff121217, 0xff050507, 0xff000000});
        pageRoot.setBackground(pageBg);
        a.root = pageRoot;
        a.setContentView(pageRoot);

        activePageRefresh =
                () -> {
                    if (drivesHolder.isAttachedToWindow()) {
                        populateDriveCards(a, drivesHolder, configSite);
                    }
                };

        LinearLayout outerCol = a.vertical();
        pageRoot.addView(outerCol, new FrameLayout.LayoutParams(-1, -1));

        // 1. iOS Secondary Navigation Header (< 返回 / 我的云盘)
        LinearLayout topNav = a.row();
        topNav.setGravity(Gravity.CENTER_VERTICAL);
        int topInset = Math.max(a.dp(28), a.statusBarHeight());
        topNav.setPadding(a.dp(20), topInset + a.dp(10), a.dp(20), a.dp(12));

        TextView backBtn = a.text("‹", 22f, Color.WHITE);
        backBtn.setTag("netdisk-back");
        backBtn.setGravity(Gravity.CENTER);
        backBtn.setPadding(0, 0, a.dp(1), a.dp(2));
        GradientDrawable backCircle = new GradientDrawable();
        backCircle.setShape(GradientDrawable.OVAL);
        backCircle.setColor(0x24ffffff);
        backCircle.setStroke(Math.max(1, a.dp(0.9f)), 0x34ffffff);
        backBtn.setBackground(backCircle);
        bindPressScale(backBtn);
        backBtn.setOnClickListener(v -> a.onBackPressed());
        LinearLayout.LayoutParams backLp = new LinearLayout.LayoutParams(a.dp(38), a.dp(38));
        backLp.rightMargin = a.dp(12);
        topNav.addView(backBtn, backLp);

        LinearLayout titleStack = a.vertical();
        TextView crumb = a.text(backLabel, 11.5f, 0x99ebebf5);
        crumb.setOnClickListener(v -> a.onBackPressed());
        titleStack.addView(crumb);

        TextView pageTitle = a.text("我的云盘", 24f, 0xfff5f5f7);
        pageTitle.setTypeface(null, Typeface.BOLD);
        titleStack.addView(pageTitle);
        topNav.addView(titleStack, new LinearLayout.LayoutParams(0, -2, 1f));
        outerCol.addView(topNav, new LinearLayout.LayoutParams(-1, -2));

        // 2. Scrollable Body matching netdisk_sheet.dart padding(20, 4, 20, 36)
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.setClipToPadding(false);
        a.scroll = sv;

        LinearLayout body = a.vertical();
        body.setPadding(a.dp(20), a.dp(4), a.dp(20), a.dp(40));
        sv.addView(body, new ScrollView.LayoutParams(-1, -2));
        outerCol.addView(sv, new LinearLayout.LayoutParams(-1, 0, 1f));

        // Card A: Priority Order Banner (matches iOS `盘序优先：夸父 > 优汐 > 嘟嘟 > 阿狸`)
        if (configSite != null) {
            body.addView(buildPriorityOrderBanner(a));
            a.gap(body, 14);
        }

        // Card Group B: 4 Stacked Two-Tier iOS Drive Cards (夸父 / 优汐 / 嘟嘟 / 阿狸)
        if (configSite != null) {
            populateDriveCards(a, drivesHolder, configSite);
            body.addView(drivesHolder, new LinearLayout.LayoutParams(-1, -2));
            a.gap(body, 8);
        }

        // Card Group C: Secondary iOS Grouped Settings Card (搜索排序 / 扩展网盘 / CatPaw)
        body.addView(buildSecondarySettingsCard(a, configSite, hasCatPaw));

        if (!a.reduced) {
            outerCol.setTranslationX(a.dp(22));
            outerCol.setAlpha(0.4f);
            outerCol.animate()
                    .translationX(0f)
                    .alpha(1f)
                    .setDuration(175)
                    .setInterpolator(new DecelerateInterpolator())
                    .start();
        }
    }

    private static View buildPriorityOrderBanner(final MainActivity a) {
        LinearLayout banner = a.vertical();
        banner.setPadding(a.dp(15), a.dp(12), a.dp(15), a.dp(12));
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(a.dp(18));
        bg.setColor(0xb826262e);
        bg.setStroke(Math.max(1, a.dp(0.7f)), 0x24ffffff);
        banner.setBackground(bg);

        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);

        FrameLayout iconCircle = new FrameLayout(a);
        GradientDrawable circle = new GradientDrawable();
        circle.setShape(GradientDrawable.OVAL);
        circle.setColor(0xff0a84ff);
        iconCircle.setBackground(circle);
        iconCircle.addView(
                new VectorGlyphView(a, ICON_ARROWS_UD, Color.WHITE),
                new FrameLayout.LayoutParams(a.dp(12), a.dp(12), Gravity.CENTER));
        LinearLayout.LayoutParams icLp = new LinearLayout.LayoutParams(a.dp(20), a.dp(20));
        icLp.rightMargin = a.dp(8);
        row.addView(iconCircle, icLp);

        TextView orderTv = a.text("盘序优先：夸父 > 优汐 > 嘟嘟 > 阿狸", 13.5f, Color.WHITE);
        orderTv.setTypeface(null, Typeface.BOLD);
        orderTv.setSingleLine(true);
        orderTv.setEllipsize(TextUtils.TruncateAt.END);
        row.addView(orderTv, new LinearLayout.LayoutParams(0, -2, 1f));

        View switchBtn =
                buildIosCapsuleButton(
                        a,
                        ICON_REFRESH,
                        "切换盘序",
                        false,
                        true,
                        () -> runSafeAccountAction(a, "panSortShow"));
        LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(-2, a.dp(30));
        sLp.leftMargin = a.dp(8);
        row.addView(switchBtn, sLp);
        banner.addView(row, new LinearLayout.LayoutParams(-1, -2));

        TextView hint =
                a.text("与电视端「🗂我的云盘┃配置」保持一致，支持优汐智1 / 夸父智1 / 嘟嘟无限2 / 阿狸原画", 11.5f, 0x99ebebf5);
        hint.setLineSpacing(a.dp(2), 1f);
        hint.setPadding(0, a.dp(6), 0, 0);
        banner.addView(hint, new LinearLayout.LayoutParams(-1, -2));
        return banner;
    }

    private static void populateDriveCards(
            final MainActivity a, final LinearLayout container, final Cms.Site configSite) {
        container.removeAllViews();
        for (DriveSpec drive : DRIVES) {
            View tile = buildIosDriveTile(a, configSite, drive);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.bottomMargin = a.dp(10);
            container.addView(tile, lp);
        }
    }

    private static View buildIosDriveTile(
            final MainActivity a, final Cms.Site configSite, final DriveSpec drive) {
        final boolean loggedIn = isDriveLoggedIn(a, drive.key);
        final boolean enabled = isDriveEnabled(a, drive.key);

        LinearLayout tile = a.vertical();
        tile.setTag("netdisk-tile-" + drive.key);
        tile.setPadding(a.dp(14), a.dp(13), a.dp(14), a.dp(12));

        GradientDrawable bg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xb82e2e36, 0xb81e1e24});
        bg.setCornerRadius(a.dp(18));
        bg.setStroke(Math.max(1, a.dp(0.8f)), loggedIn ? 0x7a30d158 : 0x24ffffff);
        tile.setBackground(bg);

        // Upper Row: 40x40 rounded-11dp icon + title/provider/lines + status pill
        LinearLayout topRow = a.row();
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        FrameLayout iconBox = new FrameLayout(a);
        GradientDrawable iconBg = new GradientDrawable();
        iconBg.setShape(GradientDrawable.RECTANGLE);
        iconBg.setCornerRadius(a.dp(11));
        iconBg.setColor(loggedIn ? 0x2e30d158 : 0x2e0a84ff);
        iconBox.setBackground(iconBg);
        iconBox.addView(
                new VectorGlyphView(
                        a, loggedIn ? ICON_CLOUD : ICON_QR, loggedIn ? 0xff30d158 : 0xff5ac8fa),
                new FrameLayout.LayoutParams(a.dp(20), a.dp(20), Gravity.CENTER));
        LinearLayout.LayoutParams ibLp = new LinearLayout.LayoutParams(a.dp(40), a.dp(40));
        ibLp.rightMargin = a.dp(12);
        topRow.addView(iconBox, ibLp);

        LinearLayout infoCol = a.vertical();
        LinearLayout nameRow = a.row();
        nameRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView aliasTv = a.text(drive.tvAlias, 15f, Color.WHITE);
        aliasTv.setTypeface(null, Typeface.BOLD);
        aliasTv.setSingleLine(true);
        nameRow.addView(aliasTv);

        TextView providerTv = a.text(drive.providerName, 12f, 0x99ebebf5);
        providerTv.setSingleLine(true);
        providerTv.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams pvLp = new LinearLayout.LayoutParams(-2, -2);
        pvLp.leftMargin = a.dp(6);
        nameRow.addView(providerTv, pvLp);
        infoCol.addView(nameRow);

        TextView lineTv = a.text(drive.lineSubtitle, 12f, 0xb3ebebf5);
        lineTv.setSingleLine(true);
        lineTv.setEllipsize(TextUtils.TruncateAt.END);
        lineTv.setPadding(0, a.dp(3), 0, 0);
        infoCol.addView(lineTv);
        topRow.addView(infoCol, new LinearLayout.LayoutParams(0, -2, 1f));

        String badgeText = loggedIn ? (enabled ? "已登录 · 启用" : "已登录") : "未登录";
        TextView statusPill = a.text(badgeText, 11f, loggedIn ? 0xff30d158 : 0x99ebebf5);
        statusPill.setTypeface(null, Typeface.BOLD);
        statusPill.setSingleLine(true);
        statusPill.setPadding(a.dp(9), a.dp(3.5f), a.dp(9), a.dp(3.5f));
        GradientDrawable pillBg = new GradientDrawable();
        pillBg.setShape(GradientDrawable.RECTANGLE);
        pillBg.setCornerRadius(a.dp(999));
        pillBg.setColor(loggedIn ? 0x3330d158 : 0xa63a3a42);
        pillBg.setStroke(Math.max(1, a.dp(0.6f)), loggedIn ? 0x7330d158 : 0x24ffffff);
        statusPill.setBackground(pillBg);
        LinearLayout.LayoutParams spLp = new LinearLayout.LayoutParams(-2, -2);
        spLp.leftMargin = a.dp(8);
        topRow.addView(statusPill, spLp);

        tile.addView(topRow, new LinearLayout.LayoutParams(-1, -2));

        // 0.5dp Hairline Divider
        View divider = new View(a);
        divider.setBackgroundColor(0x1affffff);
        LinearLayout.LayoutParams divLp = new LinearLayout.LayoutParams(-1, 1);
        divLp.topMargin = a.dp(10);
        divLp.bottomMargin = a.dp(10);
        tile.addView(divider, divLp);

        // Lower Action Row: Primary Scan/Toggle Capsule + Manual Cookie/Token Capsule
        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);

        View scanBtn =
                buildIosCapsuleButton(
                        a,
                        ICON_QR,
                        loggedIn ? "账号与启用开关" : "扫码登录",
                        !loggedIn,
                        false,
                        () -> dispatchDriveLoginAction(a, configSite, drive));
        LinearLayout.LayoutParams leftLp = new LinearLayout.LayoutParams(0, a.dp(34), 1f);
        leftLp.rightMargin = a.dp(8);
        actionRow.addView(scanBtn, leftLp);

        View tokenBtn =
                buildIosCapsuleButton(
                        a,
                        ICON_PENCIL,
                        "配置 Token / Cookie",
                        false,
                        false,
                        () -> runSafeAccountAction(a, "pushCkShow"));
        LinearLayout.LayoutParams rightLp = new LinearLayout.LayoutParams(0, a.dp(34), 1f);
        actionRow.addView(tokenBtn, rightLp);

        tile.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));
        return tile;
    }

    private static View buildIosCapsuleButton(
            MainActivity a,
            int iconKind,
            String label,
            boolean primary,
            boolean compact,
            Runnable onClick) {
        LinearLayout btn = a.row();
        btn.setGravity(Gravity.CENTER);
        btn.setPadding(
                a.dp(compact ? 10 : 12),
                a.dp(compact ? 4 : 6),
                a.dp(compact ? 10 : 12),
                a.dp(compact ? 4 : 6));

        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(999));
        if (primary) {
            gd.setColor(0xfff5f5f7);
        } else {
            gd.setColor(0x8c3a3a42);
            gd.setStroke(Math.max(1, a.dp(0.7f)), 0x26ffffff);
        }
        btn.setBackground(gd);

        int fg = primary ? 0xff111114 : 0xfff5f5f7;
        VectorGlyphView glyph = new VectorGlyphView(a, iconKind, fg);
        LinearLayout.LayoutParams glp =
                new LinearLayout.LayoutParams(a.dp(compact ? 12 : 14), a.dp(compact ? 12 : 14));
        glp.rightMargin = a.dp(5);
        btn.addView(glyph, glp);

        TextView tv = a.text(label, compact ? 11.5f : 12.5f, fg);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setSingleLine(true);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        btn.addView(tv);

        bindPressScale(btn);
        btn.setOnClickListener(v -> onClick.run());
        return btn;
    }

    private static View buildSecondarySettingsCard(
            final MainActivity a, final Cms.Site configSite, final boolean hasCatPaw) {
        LinearLayout section = a.vertical();

        TextView secHeader = a.text("更多网盘与检索设置", 12.5f, 0x99ebebf5);
        secHeader.setTypeface(null, Typeface.BOLD);
        secHeader.setPadding(a.dp(6), a.dp(2), a.dp(6), a.dp(8));
        section.addView(secHeader);

        LinearLayout card = a.vertical();
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(a.dp(18));
        bg.setColor(0xb826262e);
        bg.setStroke(Math.max(1, a.dp(0.7f)), 0x24ffffff);
        card.setBackground(bg);

        boolean addedAny = false;
        if (configSite != null) {
            card.addView(
                    buildGroupedRow(
                            a,
                            ICON_SORT,
                            0xffbf5af2,
                            "网盘搜索结果排序",
                            "自定义多网盘聚合检索时的画质与网盘展示先后",
                            () -> runSafeAccountAction(a, "panSourceSortShow")));
            addedAny = true;

            card.addView(buildGroupedDivider(a));
            card.addView(
                    buildGroupedRow(
                            a,
                            ICON_CLOUD,
                            0xff0a84ff,
                            "全部云盘授权开关面板",
                            "打开扩展原生配置面板（支持 115 / 天翼 / 移动 / 123 等扩展盘）",
                            () -> runSafeAccountAction(a, "LoginShow")));
        }

        if (hasCatPaw) {
            if (addedAny) card.addView(buildGroupedDivider(a));
            card.addView(
                    buildGroupedRow(
                            a,
                            ICON_CATPAW,
                            0xff5ac8fa,
                            "CatPaw 本机服务配置",
                            "打开内嵌 CatPaw 控制台配置代理与云盘账号",
                            () -> CatPawSettings.choose(a)));
        }

        section.addView(card, new LinearLayout.LayoutParams(-1, -2));
        return section;
    }

    private static View buildGroupedDivider(MainActivity a) {
        FrameLayout wrap = new FrameLayout(a);
        wrap.setPadding(a.dp(58), 0, a.dp(14), 0);
        View line = new View(a);
        line.setBackgroundColor(0x1affffff);
        wrap.addView(line, new FrameLayout.LayoutParams(-1, 1));
        return wrap;
    }

    private static View buildGroupedRow(
            MainActivity a,
            int iconKind,
            int accentColor,
            String title,
            String subtitle,
            Runnable onClick) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));

        FrameLayout badge = new FrameLayout(a);
        GradientDrawable badgeBg = new GradientDrawable();
        badgeBg.setShape(GradientDrawable.RECTANGLE);
        badgeBg.setCornerRadius(a.dp(9));
        badgeBg.setColor((accentColor & 0x00ffffff) | 0x2e000000);
        badge.setBackground(badgeBg);
        badge.addView(
                new VectorGlyphView(a, iconKind, accentColor),
                new FrameLayout.LayoutParams(a.dp(17), a.dp(17), Gravity.CENTER));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(a.dp(32), a.dp(32));
        badgeLp.rightMargin = a.dp(12);
        row.addView(badge, badgeLp);

        LinearLayout textCol = a.vertical();
        TextView t = a.text(title, 14.5f, 0xfff5f5f7);
        t.setTypeface(null, Typeface.BOLD);
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        textCol.addView(t);

        TextView s = a.text(subtitle, 11.5f, 0x99ebebf5);
        s.setSingleLine(true);
        s.setEllipsize(TextUtils.TruncateAt.END);
        s.setPadding(0, a.dp(2), 0, 0);
        textCol.addView(s);
        row.addView(textCol, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView chev = a.text("›", 18, 0x66ebebf5);
        chev.setPadding(a.dp(8), 0, 0, a.dp(1));
        row.addView(chev);

        bindPressScale(row);
        row.setOnClickListener(v -> onClick.run());
        return row;
    }

    private static void bindPressScale(View view) {
        if (Build.VERSION.SDK_INT >= 21) {
            view.setStateListAnimator(null);
        }
        view.setOnTouchListener(
                (v, ev) -> {
                    int act = ev.getActionMasked();
                    if (act == MotionEvent.ACTION_DOWN) {
                        v.animate().scaleX(0.97f).scaleY(0.97f).setDuration(90).start();
                    } else if (act == MotionEvent.ACTION_UP || act == MotionEvent.ACTION_CANCEL) {
                        v.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
                    }
                    return false;
                });
    }

    private static final class VectorGlyphView extends View {
        private final int kind;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();
        private final RectF rect = new RectF();

        VectorGlyphView(MainActivity a, int kind, int color) {
            super(a);
            this.kind = kind;
            paint.setColor(color);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1.8f, a.dp(1.6f)));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) return;
            path.reset();
            switch (kind) {
                case ICON_CLOUD:
                    {
                        rect.set(w * 0.14f, h * 0.36f, w * 0.86f, h * 0.78f);
                        c.drawRoundRect(rect, w * 0.22f, w * 0.22f, paint);
                        rect.set(w * 0.28f, h * 0.20f, w * 0.68f, h * 0.58f);
                        c.drawArc(rect, 195f, 160f, false, paint);
                        break;
                    }
                case ICON_QR:
                    {
                        float s = w * 0.28f;
                        rect.set(w * 0.14f, h * 0.14f, w * 0.14f + s, h * 0.14f + s);
                        c.drawRoundRect(rect, w * 0.06f, w * 0.06f, paint);
                        rect.set(w * 0.86f - s, h * 0.14f, w * 0.86f, h * 0.14f + s);
                        c.drawRoundRect(rect, w * 0.06f, w * 0.06f, paint);
                        rect.set(w * 0.14f, h * 0.86f - s, w * 0.14f + s, h * 0.86f);
                        c.drawRoundRect(rect, w * 0.06f, w * 0.06f, paint);
                        c.drawLine(w * 0.58f, h * 0.58f, w * 0.84f, h * 0.58f, paint);
                        c.drawLine(w * 0.58f, h * 0.72f, w * 0.58f, h * 0.86f, paint);
                        c.drawLine(w * 0.74f, h * 0.72f, w * 0.86f, h * 0.86f, paint);
                        break;
                    }
                case ICON_ARROWS_UD:
                    {
                        c.drawLine(w * 0.34f, h * 0.22f, w * 0.34f, h * 0.78f, paint);
                        c.drawLine(w * 0.20f, h * 0.38f, w * 0.34f, h * 0.22f, paint);
                        c.drawLine(w * 0.48f, h * 0.38f, w * 0.34f, h * 0.22f, paint);
                        c.drawLine(w * 0.66f, h * 0.22f, w * 0.66f, h * 0.78f, paint);
                        c.drawLine(w * 0.52f, h * 0.62f, w * 0.66f, h * 0.78f, paint);
                        c.drawLine(w * 0.80f, h * 0.62f, w * 0.66f, h * 0.78f, paint);
                        break;
                    }
                case ICON_REFRESH:
                    {
                        rect.set(w * 0.18f, h * 0.18f, w * 0.82f, h * 0.82f);
                        c.drawArc(rect, -40f, 285f, false, paint);
                        c.drawLine(w * 0.62f, h * 0.16f, w * 0.82f, h * 0.24f, paint);
                        c.drawLine(w * 0.76f, h * 0.42f, w * 0.82f, h * 0.24f, paint);
                        break;
                    }
                case ICON_PENCIL:
                    {
                        path.moveTo(w * 0.20f, h * 0.80f);
                        path.lineTo(w * 0.26f, h * 0.60f);
                        path.lineTo(w * 0.68f, h * 0.18f);
                        path.lineTo(w * 0.82f, h * 0.32f);
                        path.lineTo(w * 0.40f, h * 0.74f);
                        path.close();
                        c.drawPath(path, paint);
                        break;
                    }
                case ICON_SORT:
                    {
                        c.drawLine(w * 0.16f, h * 0.26f, w * 0.84f, h * 0.26f, paint);
                        c.drawLine(w * 0.16f, h * 0.52f, w * 0.64f, h * 0.52f, paint);
                        c.drawLine(w * 0.16f, h * 0.78f, w * 0.44f, h * 0.78f, paint);
                        break;
                    }
                default:
                    {
                        c.drawCircle(w * 0.5f, h * 0.5f, w * 0.34f, paint);
                        c.drawCircle(w * 0.5f, h * 0.5f, w * 0.10f, paint);
                        break;
                    }
            }
        }
    }
}

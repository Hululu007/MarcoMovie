package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.*;

/**
 * Unified netdisk login & QR credential center.
 * Renders a Liquid Glass bottom drawer with capsule rows on phones/tablets, and keeps the anchored
 * D-pad menu on Android TV.
 */
final class AccountPanel {
    private static final int ICON_CLOUD = 1;
    private static final int ICON_QR = 2;
    private static final int ICON_ROUTE = 3;
    private static final int ICON_SORT = 4;
    private static final int ICON_CATPAW = 5;

    static Cms.Site findConfigCenterSite(MainActivity a) {
        if (a.config == null) return null;
        for (Cms.Site site : a.config.sites) {
            String api = site.api == null ? "" : site.api.toLowerCase(Locale.ROOT);
            String key = site.key == null ? "" : site.key.toLowerCase(Locale.ROOT);
            String name = site.name == null ? "" : site.name;
            if (api.contains("configcenter")
                    || api.contains("localconfig")
                    || api.contains("wexconfig")
                    || api.contains("wexokconfig")
                    || key.contains("configcenter")
                    || key.contains("wexconfig")
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

    static void show(MainActivity a) {
        show(a, null);
    }

    static void show(MainActivity a, View anchor) {
        if (a.isTvDevice()) {
            showTvDialog(a, anchor);
            return;
        }
        boolean hasCatPaw = CatPawSettings.available(a);
        Cms.Site configSite = findConfigCenterSite(a);
        if (configSite == null && !hasCatPaw) {
            a.notice(
                    "当前订阅未包含网盘配置中心。\n\n"
                            + "请在「设置 → 订阅与账号」导入带有配置中心或网盘源的订阅包后，即可在此统一扫码登录夸克、UC、百度、阿里、115 等网盘。");
            return;
        }
        showMobileCenteredDialog(a, configSite, hasCatPaw);
    }

    private static void showTvDialog(final MainActivity a, final View anchor) {
        final Dialog dialog = new Dialog(a);
        a.accountDialog = dialog;
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
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
                                .setInterpolator(
                                        new android.view.animation.DecelerateInterpolator())
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

    private static void showMobileCenteredDialog(
            final MainActivity a, final Cms.Site configSite, boolean hasCatPaw) {
        final Dialog sheet = new Dialog(a);
        a.accountDialog = sheet;
        sheet.requestWindowFeature(Window.FEATURE_NO_TITLE);
        sheet.setOnDismissListener(d -> a.accountDialog = null);

        final int dialogWidth = Math.min(a.windowWidth() - a.dp(32), a.dp(410));

        LinearLayout card = a.vertical();
        card.setTag("mobile-drawer");
        card.setPadding(a.dp(20), a.dp(18), a.dp(20), a.dp(14));
        GradientDrawable cardBg =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xf41c2421, 0xf8111715});
        cardBg.setCornerRadius(a.dp(28));
        cardBg.setStroke(Math.max(1, a.dp(1)), 0x36ffffff);
        card.setBackground(cardBg);

        // Header row: Title + circular close button
        LinearLayout header = a.row();
        header.setGravity(Gravity.CENTER_VERTICAL);
        TextView titleTv = a.text("网盘与账号中心", 20, 0xfff5f5f7);
        titleTv.setTypeface(null, Typeface.BOLD);
        header.addView(titleTv, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView closeBtn = a.text("✕", 14, 0xd9f5f5f7);
        closeBtn.setGravity(Gravity.CENTER);
        GradientDrawable closeBg = new GradientDrawable();
        closeBg.setShape(GradientDrawable.OVAL);
        closeBg.setColor(0x22ffffff);
        closeBg.setStroke(Math.max(1, a.dp(1)), 0x28ffffff);
        closeBtn.setBackground(closeBg);
        bindPressScale(closeBtn);
        closeBtn.setOnClickListener(v -> sheet.dismiss());
        header.addView(closeBtn, new LinearLayout.LayoutParams(a.dp(32), a.dp(32)));
        card.addView(header, new LinearLayout.LayoutParams(-1, -2));

        TextView subTv = a.text("统一管理夸克、UC、百度、阿里、115 等云盘登录授权与解析线路优先级", 12.5f, 0xb3ebebf5);
        subTv.setPadding(a.dp(2), a.dp(6), a.dp(2), a.dp(14));
        card.addView(subTv, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout list = a.vertical();

        if (configSite != null || hasCatPaw) {
            list.addView(
                    buildCapsuleItem(
                            a,
                            ICON_CLOUD,
                            0xff30d158,
                            "云盘账号授权与开关",
                            "扫码绑定夸克 / UC / 百度 / 阿里等账号并开启自盘搜索",
                            () -> {
                                sheet.dismiss();
                                a.toast("正在调起云盘授权面板…");
                                runSafeAccountAction(a, "LoginShow");
                            }));

            list.addView(
                    buildCapsuleItem(
                            a,
                            ICON_QR,
                            0xff0a84ff,
                            "局域网推送 Cookie / Token",
                            "通过浏览器或扫码快速填入网盘 Cookie 凭据",
                            () -> {
                                sheet.dismiss();
                                a.toast("正在打开凭据推送面板…");
                                runSafeAccountAction(a, "pushCkShow");
                            }));

            list.addView(
                    buildCapsuleItem(
                            a,
                            ICON_ROUTE,
                            0xffff9f0a,
                            "网盘线路优先顺序",
                            "调整播放详情页默认首选的云盘与原画线路排序",
                            () -> {
                                sheet.dismiss();
                                runSafeAccountAction(a, "panSortShow");
                            }));

            list.addView(
                    buildCapsuleItem(
                            a,
                            ICON_SORT,
                            0xffbf5af2,
                            "网盘搜索结果排序",
                            "自定义多网盘聚合检索时的画质与网盘展示先后",
                            () -> {
                                sheet.dismiss();
                                runSafeAccountAction(a, "panSourceSortShow");
                            }));
        }

        if (hasCatPaw) {
            list.addView(
                    buildCapsuleItem(
                            a,
                            ICON_CATPAW,
                            0xff5ac8fa,
                            "CatPaw 本机服务配置",
                            "打开内嵌 CatPaw 控制台配置代理与云盘帐号",
                            () -> {
                                sheet.dismiss();
                                CatPawSettings.choose(a);
                            }));
        }

        int maxScrollH = Math.max(a.dp(200), Math.round(a.windowHeight() * 0.62f));
        list.measure(
                View.MeasureSpec.makeMeasureSpec(dialogWidth - a.dp(40), View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        ScrollView sv = new ScrollView(a);
        sv.setVerticalScrollBarEnabled(false);
        sv.addView(list, new ScrollView.LayoutParams(-1, -2));
        card.addView(
                sv,
                new LinearLayout.LayoutParams(
                        -1, Math.min(maxScrollH, Math.max(a.dp(60), list.getMeasuredHeight()))));

        sheet.setContentView(card);
        Window win = sheet.getWindow();
        if (win != null) {
            win.getDecorView().setTag("app-dialog");
            win.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            WindowManager.LayoutParams wlp = win.getAttributes();
            wlp.width = dialogWidth;
            wlp.height = WindowManager.LayoutParams.WRAP_CONTENT;
            wlp.gravity = Gravity.CENTER;
            wlp.dimAmount = 0.64f;
            win.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            win.setAttributes(wlp);
        }
        sheet.show();
        if (!a.reduced) {
            card.setScaleX(0.95f);
            card.setScaleY(0.95f);
            card.setAlpha(0f);
            card.animate()
                    .scaleX(1f)
                    .scaleY(1f)
                    .alpha(1f)
                    .setDuration(165)
                    .setInterpolator(new android.view.animation.DecelerateInterpolator())
                    .start();
        }
    }

    private static View buildCapsuleItem(
            MainActivity a,
            int iconKind,
            int accentColor,
            String title,
            String subtitle,
            Runnable onClick) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(16), a.dp(13), a.dp(16), a.dp(13));

        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(a.dp(24));
        bg.setColor(0x18ffffff);
        bg.setStroke(Math.max(1, a.dp(1)), 0x24ffffff);
        row.setBackground(bg);

        FrameLayout badge = new FrameLayout(a);
        GradientDrawable badgeCircle = new GradientDrawable();
        badgeCircle.setShape(GradientDrawable.OVAL);
        badgeCircle.setColor((accentColor & 0x00ffffff) | 0x2e000000);
        badge.setBackground(badgeCircle);
        badge.addView(
                new VectorGlyphView(a, iconKind, accentColor),
                new FrameLayout.LayoutParams(a.dp(20), a.dp(20), Gravity.CENTER));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(a.dp(40), a.dp(40));
        badgeLp.rightMargin = a.dp(13);
        row.addView(badge, badgeLp);

        LinearLayout textCol = a.vertical();
        TextView t = a.text(title, 15.5f, 0xfff5f5f7);
        t.setTypeface(null, Typeface.BOLD);
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        textCol.addView(t);

        TextView s = a.text(subtitle, 12f, 0xa8ebebf5);
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

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = a.dp(10);
        row.setLayoutParams(lp);
        return row;
    }

    private static void bindPressScale(View view) {
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
            paint.setStrokeWidth(Math.max(2f, a.dp(1.8f)));
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
                        rect.set(w * 0.14f, h * 0.34f, w * 0.86f, h * 0.78f);
                        c.drawRoundRect(rect, w * 0.22f, w * 0.22f, paint);
                        rect.set(w * 0.28f, h * 0.18f, w * 0.68f, h * 0.56f);
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
                case ICON_ROUTE:
                    {
                        c.drawLine(w * 0.18f, h * 0.32f, w * 0.82f, h * 0.32f, paint);
                        c.drawLine(w * 0.66f, h * 0.18f, w * 0.82f, h * 0.32f, paint);
                        c.drawLine(w * 0.66f, h * 0.46f, w * 0.82f, h * 0.32f, paint);
                        c.drawLine(w * 0.82f, h * 0.68f, w * 0.18f, h * 0.68f, paint);
                        c.drawLine(w * 0.34f, h * 0.54f, w * 0.18f, h * 0.68f, paint);
                        c.drawLine(w * 0.34f, h * 0.82f, w * 0.18f, h * 0.68f, paint);
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

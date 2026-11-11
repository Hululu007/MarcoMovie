package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckedTextView;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;
import com.pilipala.glass.GlassworkSurface;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.WeakHashMap;

/**
 * Runtime Liquid Glass theme layer for third-party spider / ConfigCenter dialogs (e.g. Pan.java
 * LoginShow, QR scan dialogs, Cookie prompts, and netdisk priority pickers). Styles Android host
 * views without modifying or unwrapping any plugin binary.
 */
final class PluginDialogStyler {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Set<View> STYLED_DECORS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_DRIVE_ROWS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final int[] WATCH_DELAYS_MS = {0, 45, 120, 260, 520, 950, 1600};

    private PluginDialogStyler() {}

    static void watch(final MainActivity a) {
        if (a == null) return;
        for (int delay : WATCH_DELAYS_MS) {
            MAIN.postDelayed(
                    () -> {
                        if (!a.isFinishing() && !a.isDestroyed()) {
                            scanAndStyleWindows(a);
                        }
                    },
                    delay);
        }
    }

    static void scanAndStyleWindows(final MainActivity a) {
        if (a == null || a.isFinishing()) return;
        View activityDecor = a.getWindow() != null ? a.getWindow().getDecorView() : null;
        List<View> views = getGlobalWindowViews();
        for (View root : views) {
            if (root == null || root == activityDecor || !(root instanceof ViewGroup)) continue;
            if (isAppOwnedWindow(root)) continue;
            Context ctx = root.getContext();
            if (!belongsToApp(ctx, a)) continue;
            ViewGroup.LayoutParams rawLp = root.getLayoutParams();
            if (rawLp instanceof WindowManager.LayoutParams) {
                WindowManager.LayoutParams wlp = (WindowManager.LayoutParams) rawLp;
                // Skip Toasts and non-interactive system overlays
                if (wlp.type == WindowManager.LayoutParams.TYPE_TOAST) continue;
                if ((wlp.flags & WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE) != 0) continue;
            }
            // Only style dialog-like hierarchies (AlertDialog content or custom spider dialogs)
            View content = root.findViewById(android.R.id.content);
            if (!(content instanceof ViewGroup) || ((ViewGroup) content).getChildCount() == 0) {
                continue;
            }
            stylePluginDecor(a, (ViewGroup) root, (ViewGroup) content);
        }
    }

    private static boolean belongsToApp(Context ctx, MainActivity a) {
        if (ctx == null || a == null) return false;
        try {
            return a.getPackageName().equals(ctx.getPackageName());
        } catch (Throwable ignored) {
            return true;
        }
    }

    private static boolean isAppOwnedWindow(View decor) {
        Object tag = decor.getTag();
        if ("app-dialog".equals(tag)
                || "source-picker".equals(tag)
                || "player-bubble".equals(tag)) {
            return true;
        }
        return containsAppOwnedTag(decor, 0);
    }

    private static boolean containsAppOwnedTag(View v, int depth) {
        if (v == null || depth > 4) return false;
        Object tag = v.getTag();
        if ("app-dialog".equals(tag)
                || "source-picker".equals(tag)
                || "player-bubble".equals(tag)
                || "mobile-drawer".equals(tag)) {
            return true;
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            int n = Math.min(vg.getChildCount(), 6);
            for (int i = 0; i < n; i++) {
                if (containsAppOwnedTag(vg.getChildAt(i), depth + 1)) return true;
            }
        }
        return false;
    }

    @SuppressWarnings("unchecked")
    private static List<View> getGlobalWindowViews() {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                Method m =
                        Class.forName("android.view.inspector.WindowInspector")
                                .getMethod("getGlobalWindowViews");
                Object res = m.invoke(null);
                if (res instanceof List) {
                    return new ArrayList<>((List<View>) res);
                }
            } catch (Throwable ignored) {
            }
        }
        try {
            Class<?> wmgClass = Class.forName("android.view.WindowManagerGlobal");
            Object wmg = wmgClass.getMethod("getInstance").invoke(null);
            Field viewsField = wmgClass.getDeclaredField("mViews");
            viewsField.setAccessible(true);
            Object raw = viewsField.get(wmg);
            if (raw instanceof List) {
                return new ArrayList<>((List<View>) raw);
            }
        } catch (Throwable ignored) {
        }
        return Collections.emptyList();
    }

    private static void stylePluginDecor(
            final MainActivity a, final ViewGroup decor, final ViewGroup content) {
        final boolean firstPass = STYLED_DECORS.add(decor);
        DisplayMetrics dm = a.getResources().getDisplayMetrics();
        final int maxDialogWidth =
                a.isTvDevice()
                        ? Math.min(dm.widthPixels - a.dp(96), a.dp(540))
                        : Math.min(dm.widthPixels - a.dp(28), a.dp(410));

        if (firstPass) {
            decor.setBackgroundColor(Color.TRANSPARENT);
            adjustWindowLayoutParams(a, decor, maxDialogWidth);

            // Detect secondary dialogs (e.g. QR login or Cookie dialog opened from LoginShow)
            if (Build.VERSION.SDK_INT >= 18) {
                decor.getViewTreeObserver()
                        .addOnWindowFocusChangeListener(
                                hasFocus -> {
                                    if (!hasFocus) watch(a);
                                    else styleHierarchyPass(a, decor, content, maxDialogWidth);
                                });
            }
            decor.getViewTreeObserver()
                    .addOnPreDrawListener(
                            new ViewTreeObserver.OnPreDrawListener() {
                                @Override
                                public boolean onPreDraw() {
                                    if (!decor.isAttachedToWindow()) {
                                        decor.getViewTreeObserver().removeOnPreDrawListener(this);
                                        return true;
                                    }
                                    refreshSpiderButtonStates(a, content);
                                    return true;
                                }
                            });
        }

        styleHierarchyPass(a, decor, content, maxDialogWidth);
    }

    private static void adjustWindowLayoutParams(MainActivity a, ViewGroup decor, int targetWidth) {
        try {
            ViewGroup.LayoutParams raw = decor.getLayoutParams();
            if (!(raw instanceof WindowManager.LayoutParams)) return;
            WindowManager.LayoutParams wlp = (WindowManager.LayoutParams) raw;
            boolean changed = false;
            if (wlp.width != targetWidth) {
                wlp.width = targetWidth;
                changed = true;
            }
            if ((wlp.flags & WindowManager.LayoutParams.FLAG_DIM_BEHIND) == 0
                    || wlp.dimAmount < 0.55f) {
                wlp.flags |= WindowManager.LayoutParams.FLAG_DIM_BEHIND;
                wlp.dimAmount = 0.66f;
                changed = true;
            }
            wlp.gravity = Gravity.CENTER;
            if (changed) {
                WindowManager wm = (WindowManager) a.getSystemService(Context.WINDOW_SERVICE);
                if (wm != null) wm.updateViewLayout(decor, wlp);
            }
        } catch (Throwable ignored) {
        }
    }

    private static void styleHierarchyPass(
            MainActivity a, ViewGroup decor, ViewGroup content, int maxDialogWidth) {
        // Clear intermediate window/frame solid backgrounds so only our outer Liquid Glass card
        // shows
        clearBackgroundUpToDecor(content, decor);

        ViewGroup cardRoot = (ViewGroup) content.getChildAt(0);
        if (cardRoot == null) return;

        if (!Boolean.TRUE.equals(cardRoot.getTag(android.R.id.background))) {
            a.glass(cardRoot, 26);
            cardRoot.setPadding(a.dp(18), a.dp(18), a.dp(18), a.dp(14));
            cardRoot.setTag(android.R.id.background, Boolean.TRUE);
        }

        int maxInnerWidth = Math.max(a.dp(240), maxDialogWidth - a.dp(36));
        styleSubtree(a, cardRoot, cardRoot, maxInnerWidth, 0);
        styleAlertButtonBar(a, cardRoot);
    }

    private static void clearBackgroundUpToDecor(View start, View stop) {
        View cur = start;
        while (cur != null && cur != stop) {
            cur.setBackgroundColor(Color.TRANSPARENT);
            if (!(cur.getParent() instanceof View)) break;
            cur = (View) cur.getParent();
        }
    }

    private static void styleSubtree(
            final MainActivity a,
            final View v,
            final ViewGroup cardRoot,
            final int maxInnerWidth,
            final int depth) {
        if (v == null || depth > 14) return;

        // Clamp oversized hardcoded widths (e.g. Pan.java 500dp QR dialog LinearLayout)
        ViewGroup.LayoutParams lp = v.getLayoutParams();
        if (lp != null && lp.width > maxInnerWidth) {
            lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
            v.setLayoutParams(lp);
        }

        // Hide legacy Holo/Material alert title dividers & empty spacers
        String resName = resourceEntryName(v);
        if ("titleDividerNoCustom".equals(resName)
                || "titleDivider".equals(resName)
                || "scrollIndicatorUp".equals(resName)
                || "scrollIndicatorDown".equals(resName)
                || "textSpacerNoButtons".equals(resName)
                || "textSpacerNoTitle".equals(resName)) {
            v.setVisibility(View.GONE);
            return;
        }
        if ("customPanel".equals(resName)
                || "contentPanel".equals(resName)
                || "topPanel".equals(resName)
                || "buttonPanel".equals(resName)
                || "custom".equals(resName)) {
            v.setMinimumHeight(0);
            v.setBackgroundColor(Color.TRANSPARENT);
        }

        // Detect Pan.java LoginShow row: Horizontal LinearLayout containing 2 Buttons (account +
        // status toggle)
        if (v instanceof LinearLayout && isSpiderDriveRow((LinearLayout) v)) {
            styleSpiderDriveRow(a, (LinearLayout) v);
            return;
        }

        // Strip stark #FFFFFF / #424242 solid ColorDrawables on intermediate containers
        if (v != cardRoot && v instanceof ViewGroup && !(v instanceof ListView)) {
            Drawable bg = v.getBackground();
            if (bg instanceof ColorDrawable) {
                int c = ((ColorDrawable) bg).getColor();
                if (c != Color.TRANSPARENT) {
                    v.setBackgroundColor(Color.TRANSPARENT);
                }
            }
            if (v instanceof ScrollView) {
                ((ScrollView) v).setVerticalScrollBarEnabled(false);
            }
        }

        if (v instanceof ListView) {
            styleListView(a, (ListView) v);
            return;
        }

        if (v instanceof ImageView) {
            styleQrOrIconImageView(a, (ImageView) v, resName);
            return;
        }

        if (v instanceof EditText) {
            styleEditText(a, (EditText) v);
            return;
        }

        if (v instanceof Button) {
            styleGenericPluginButton(a, (Button) v);
            return;
        }

        if (v instanceof TextView) {
            stylePluginTextView(a, (TextView) v, resName);
            return;
        }

        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                styleSubtree(a, vg.getChildAt(i), cardRoot, maxInnerWidth, depth + 1);
            }
        }
    }

    private static boolean isSpiderDriveRow(LinearLayout row) {
        if (row.getOrientation() != LinearLayout.HORIZONTAL) return false;
        if (row.getChildCount() != 2) return false;
        return (row.getChildAt(0) instanceof Button) && (row.getChildAt(1) instanceof Button);
    }

    private static void styleSpiderDriveRow(MainActivity a, LinearLayout row) {
        if (STYLED_DRIVE_ROWS.add(row)) {
            GradientDrawable rowCard = new GradientDrawable();
            rowCard.setShape(GradientDrawable.RECTANGLE);
            rowCard.setCornerRadius(a.dp(16));
            rowCard.setColor(0x16ffffff);
            rowCard.setStroke(Math.max(1, a.dp(1)), 0x22ffffff);
            row.setBackground(rowCard);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(a.dp(8), a.dp(7), a.dp(8), a.dp(7));

            ViewGroup.LayoutParams rawLp = row.getLayoutParams();
            if (rawLp instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) rawLp;
                mlp.leftMargin = 0;
                mlp.rightMargin = 0;
                mlp.topMargin = 0;
                mlp.bottomMargin = a.dp(9);
                row.setLayoutParams(mlp);
            }
        }

        Button accountBtn = (Button) row.getChildAt(0);
        Button statusBtn = (Button) row.getChildAt(1);

        LinearLayout.LayoutParams leftLp =
                accountBtn.getLayoutParams() instanceof LinearLayout.LayoutParams
                        ? (LinearLayout.LayoutParams) accountBtn.getLayoutParams()
                        : new LinearLayout.LayoutParams(0, a.dp(42), 1f);
        leftLp.width = 0;
        leftLp.weight = 1f;
        leftLp.height = a.dp(42);
        leftLp.setMargins(0, 0, a.dp(8), 0);
        accountBtn.setLayoutParams(leftLp);
        accountBtn.setPadding(a.dp(12), 0, a.dp(12), 0);

        LinearLayout.LayoutParams rightLp =
                statusBtn.getLayoutParams() instanceof LinearLayout.LayoutParams
                        ? (LinearLayout.LayoutParams) statusBtn.getLayoutParams()
                        : new LinearLayout.LayoutParams(a.dp(78), a.dp(42));
        rightLp.width = a.dp(78);
        rightLp.weight = 0f;
        rightLp.height = a.dp(42);
        rightLp.setMargins(0, 0, 0, 0);
        statusBtn.setLayoutParams(rightLp);
        statusBtn.setPadding(a.dp(6), 0, a.dp(6), 0);

        applySpiderDriveButtonStyle(a, accountBtn, false);
        applySpiderDriveButtonStyle(a, statusBtn, true);
    }

    private static void refreshSpiderButtonStates(MainActivity a, ViewGroup root) {
        if (root == null) return;
        for (int i = 0; i < root.getChildCount(); i++) {
            View child = root.getChildAt(i);
            if (child instanceof LinearLayout && isSpiderDriveRow((LinearLayout) child)) {
                LinearLayout row = (LinearLayout) child;
                applySpiderDriveButtonStyle(a, (Button) row.getChildAt(0), false);
                applySpiderDriveButtonStyle(a, (Button) row.getChildAt(1), true);
            } else if (child instanceof Button) {
                Button btn = (Button) child;
                int id = btn.getId();
                if (id != android.R.id.button1
                        && id != android.R.id.button2
                        && id != android.R.id.button3) {
                    applySpiderDriveButtonStyle(a, btn, false);
                }
            } else if (child instanceof ViewGroup) {
                refreshSpiderButtonStates(a, (ViewGroup) child);
            }
        }
    }

    private static final class StyledSpiderButtonBg extends GradientDrawable {
        final String appliedLabel;

        StyledSpiderButtonBg(String appliedLabel) {
            this.appliedLabel = appliedLabel;
        }
    }

    private static void applySpiderDriveButtonStyle(
            MainActivity a, Button btn, boolean compactPill) {
        String label = btn.getText() == null ? "" : btn.getText().toString().trim();
        Drawable existing = btn.getBackground();
        if (existing instanceof StyledSpiderButtonBg
                && label.equals(((StyledSpiderButtonBg) existing).appliedLabel)) {
            return;
        }

        boolean positive =
                label.contains("已登录")
                        || label.contains("启用中")
                        || label.contains("已启用")
                        || label.contains("已绑定");
        boolean negativeOrIdle =
                label.contains("未登录")
                        || label.contains("停用中")
                        || label.contains("已停用")
                        || label.contains("未绑定");

        int fillColor;
        int strokeColor;
        int textColor;
        if (positive) {
            fillColor = compactPill ? 0x3630d158 : 0x2e30d158;
            strokeColor = 0x7834d399;
            textColor = 0xff6ee7b7;
        } else if (negativeOrIdle) {
            fillColor = compactPill ? 0x14ffffff : 0x1cffffff;
            strokeColor = compactPill ? 0x22ffffff : 0x28ffffff;
            textColor = compactPill ? 0x99ebebf5 : 0xe0f5f5f7;
        } else {
            fillColor = 0x260a84ff;
            strokeColor = 0x660a84ff;
            textColor = 0xff70b8ff;
        }

        StyledSpiderButtonBg gd = new StyledSpiderButtonBg(label);
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(12));
        gd.setColor(fillColor);
        gd.setStroke(Math.max(1, a.dp(1)), strokeColor);

        btn.setAllCaps(false);
        btn.setIncludeFontPadding(false);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setTextSize(compactPill ? 12.5f : 13.8f);
        btn.setTextColor(textColor);
        if (Build.VERSION.SDK_INT >= 21) {
            btn.setStateListAnimator(null);
            btn.setElevation(0f);
        }
        btn.setBackground(gd);
    }

    private static void styleGenericPluginButton(MainActivity a, Button btn) {
        int id = btn.getId();
        if (id == android.R.id.button1
                || id == android.R.id.button2
                || id == android.R.id.button3) {
            return;
        }
        applySpiderDriveButtonStyle(a, btn, false);
        btn.setMinHeight(a.dp(40));
        btn.setMinimumHeight(a.dp(40));
        btn.setPadding(a.dp(14), a.dp(6), a.dp(14), a.dp(6));
    }

    private static void styleAlertButtonBar(MainActivity a, ViewGroup cardRoot) {
        int[] ids = {android.R.id.button1, android.R.id.button2, android.R.id.button3};
        for (int id : ids) {
            View found = cardRoot.findViewById(id);
            if (!(found instanceof Button) || found.getVisibility() != View.VISIBLE) continue;
            Button b = (Button) found;
            boolean primary = (id == android.R.id.button1);
            GradientDrawable pill = new GradientDrawable();
            pill.setShape(GradientDrawable.RECTANGLE);
            pill.setCornerRadius(a.dp(999));
            pill.setColor(primary ? 0xff0a84ff : 0x22ffffff);
            if (!primary) {
                pill.setStroke(Math.max(1, a.dp(1)), 0x2cffffff);
            }
            b.setAllCaps(false);
            b.setIncludeFontPadding(false);
            b.setTypeface(null, Typeface.BOLD);
            b.setTextSize(13.5f);
            b.setTextColor(primary ? Color.WHITE : 0xe6f5f5f7);
            b.setMinHeight(a.dp(36));
            b.setMinimumHeight(a.dp(36));
            b.setMinWidth(a.dp(72));
            b.setMinimumWidth(a.dp(72));
            b.setPadding(a.dp(18), a.dp(6), a.dp(18), a.dp(6));
            if (Build.VERSION.SDK_INT >= 21) {
                b.setStateListAnimator(null);
                b.setElevation(0f);
            }
            b.setBackground(pill);
            ViewGroup.LayoutParams lp = b.getLayoutParams();
            if (lp instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) lp;
                mlp.leftMargin = a.dp(8);
                mlp.topMargin = a.dp(4);
                mlp.bottomMargin = a.dp(2);
                b.setLayoutParams(mlp);
            }
        }
    }

    private static void stylePluginTextView(MainActivity a, TextView tv, String resName) {
        boolean isAlertTitle = "alertTitle".equals(resName) || tv.getId() == android.R.id.title;
        if (isAlertTitle) {
            tv.setTextSize(15.5f);
            tv.setTypeface(null, Typeface.BOLD);
            tv.setTextColor(0xfff5f5f7);
            tv.setSingleLine(false);
            tv.setMaxLines(2);
            tv.setLineSpacing(a.dp(3), 1f);
            tv.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(10));
            return;
        }
        int curColor = tv.getCurrentTextColor();
        // Ensure readable light text on dark glass if plugin left default dark/black text
        if (Color.alpha(curColor) > 80
                && Color.red(curColor) < 90
                && Color.green(curColor) < 90
                && Color.blue(curColor) < 90) {
            tv.setTextColor(0xe6f5f5f7);
        } else if (tv.getId() == android.R.id.message) {
            tv.setTextColor(0xd9ebebf5);
            tv.setTextSize(14f);
            tv.setLineSpacing(a.dp(4), 1f);
        }
    }

    private static void styleEditText(MainActivity a, EditText input) {
        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(14));
        gd.setColor(0x22ffffff);
        gd.setStroke(Math.max(1, a.dp(1)), 0x38ffffff);
        input.setBackground(gd);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0x73ebebf5);
        input.setTextSize(14f);
        input.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
    }

    private static void styleQrOrIconImageView(MainActivity a, ImageView iv, String resName) {
        if ("icon".equals(resName) || iv.getId() == android.R.id.icon) {
            if (iv.getDrawable() == null) iv.setVisibility(View.GONE);
            return;
        }
        ViewGroup.LayoutParams lp = iv.getLayoutParams();
        int w = lp != null && lp.width > 0 ? lp.width : iv.getMeasuredWidth();
        int h = lp != null && lp.height > 0 ? lp.height : iv.getMeasuredHeight();
        boolean likelyQr =
                (w >= a.dp(110) && h >= a.dp(110))
                        || (iv.getDrawable() != null
                                && iv.getDrawable().getIntrinsicWidth() >= 140
                                && Math.abs(
                                                iv.getDrawable().getIntrinsicWidth()
                                                        - iv.getDrawable().getIntrinsicHeight())
                                        <= 32);
        if (likelyQr) {
            int maxQr = a.dp(220);
            if (lp != null) {
                if (lp.width > maxQr || lp.width <= 0) lp.width = maxQr;
                if (lp.height > maxQr || lp.height <= 0) lp.height = maxQr;
                if (lp instanceof LinearLayout.LayoutParams) {
                    ((LinearLayout.LayoutParams) lp).gravity = Gravity.CENTER_HORIZONTAL;
                    ((LinearLayout.LayoutParams) lp).topMargin = a.dp(8);
                    ((LinearLayout.LayoutParams) lp).bottomMargin = a.dp(8);
                } else if (lp instanceof FrameLayout.LayoutParams) {
                    ((FrameLayout.LayoutParams) lp).gravity = Gravity.CENTER_HORIZONTAL;
                }
                iv.setLayoutParams(lp);
            }
            GradientDrawable qrPad = new GradientDrawable();
            qrPad.setShape(GradientDrawable.RECTANGLE);
            qrPad.setCornerRadius(a.dp(16));
            qrPad.setColor(Color.WHITE);
            iv.setBackground(qrPad);
            iv.setPadding(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
        }
    }

    private static void styleListView(final MainActivity a, ListView lv) {
        lv.setBackgroundColor(Color.TRANSPARENT);
        lv.setCacheColorHint(Color.TRANSPARENT);
        lv.setDivider(new ColorDrawable(0x18ffffff));
        lv.setDividerHeight(1);
        lv.setSelector(new ColorDrawable(0x1cffffff));
        for (int i = 0; i < lv.getChildCount(); i++) {
            styleListItem(a, lv.getChildAt(i));
        }
        lv.setOnHierarchyChangeListener(
                new ViewGroup.OnHierarchyChangeListener() {
                    @Override
                    public void onChildViewAdded(View parent, View child) {
                        styleListItem(a, child);
                    }

                    @Override
                    public void onChildViewRemoved(View parent, View child) {}
                });
    }

    private static void styleListItem(MainActivity a, View child) {
        if (child instanceof TextView) {
            TextView tv = (TextView) child;
            tv.setTextColor(0xfff5f5f7);
            tv.setTextSize(14.5f);
            tv.setMinHeight(a.dp(46));
            tv.setGravity(Gravity.CENTER_VERTICAL);
            tv.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));
            if (tv instanceof CheckedTextView && Build.VERSION.SDK_INT >= 21) {
                tv.setCompoundDrawableTintList(
                        android.content.res.ColorStateList.valueOf(0xff34d399));
            }
        } else if (child instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) child;
            for (int i = 0; i < vg.getChildCount(); i++) {
                styleListItem(a, vg.getChildAt(i));
            }
        }
    }

    private static String resourceEntryName(View v) {
        int id = v.getId();
        if (id == View.NO_ID) return "";
        try {
            return v.getResources().getResourceEntryName(id);
        } catch (Throwable ignored) {
            return "";
        }
    }
}

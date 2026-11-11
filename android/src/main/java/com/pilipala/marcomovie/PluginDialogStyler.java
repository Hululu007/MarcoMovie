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
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.WeakHashMap;

/**
 * Runtime iOS Liquid Glass theme and zero-overflow layout normalizer for third-party spider /
 * ConfigCenter dialogs (e.g. Pan.java LoginShow, QR scan dialogs, Cookie prompts, and netdisk
 * priority pickers). Styles Android host views without modifying or unwrapping any plugin binary,
 * and never mutates view tags.
 */
final class PluginDialogStyler {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Set<View> STYLED_DECORS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_CARD_ROOTS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_DRIVE_ROWS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_BUTTON_ROWS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final Set<View> STYLED_LIST_VIEWS =
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>());
    private static final int[] WATCH_DELAYS_MS = {0, 45, 120, 260, 520, 950, 1600, 2400};

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
        if (a == null || a.isFinishing() || a.isDestroyed()) return;
        try {
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
                    if (wlp.type == WindowManager.LayoutParams.TYPE_TOAST) continue;
                    if ((wlp.flags & WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE) != 0) continue;
                }
                View content = root.findViewById(android.R.id.content);
                if (!(content instanceof ViewGroup) || ((ViewGroup) content).getChildCount() == 0) {
                    continue;
                }
                stylePluginDecor(a, (ViewGroup) root, (ViewGroup) content);
            }
        } catch (Throwable t) {
            AppLog.w("PluginDialogStyler", "scanAndStyleWindows skipped", t);
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
        try {
            final boolean firstPass = STYLED_DECORS.add(decor);
            DisplayMetrics dm = a.getResources().getDisplayMetrics();
            int winW = a.windowWidth() > 0 ? a.windowWidth() : dm.widthPixels;
            int winH = a.windowHeight() > 0 ? a.windowHeight() : dm.heightPixels;
            final int maxDialogWidth =
                    a.isTvDevice()
                            ? Math.min(winW - a.dp(96), a.dp(540))
                            : Math.min(winW - a.dp(24), a.dp(396));

            decor.setBackground(new ColorDrawable(Color.TRANSPARENT));
            decor.setPadding(0, 0, 0, 0);
            adjustWindowLayoutParams(a, decor, maxDialogWidth, winH);

            if (firstPass) {
                if (Build.VERSION.SDK_INT >= 18) {
                    decor.getViewTreeObserver()
                            .addOnWindowFocusChangeListener(
                                    hasFocus -> {
                                        try {
                                            if (!hasFocus) watch(a);
                                            else styleHierarchyPass(a, decor, content, winH);
                                        } catch (Throwable ignored) {
                                        }
                                    });
                }
                decor.getViewTreeObserver()
                        .addOnPreDrawListener(
                                new ViewTreeObserver.OnPreDrawListener() {
                                    @Override
                                    public boolean onPreDraw() {
                                        try {
                                            if (!decor.isAttachedToWindow()) {
                                                decor.getViewTreeObserver()
                                                        .removeOnPreDrawListener(this);
                                                return true;
                                            }
                                            if (decor.getPaddingLeft() != 0
                                                    || decor.getPaddingRight() != 0) {
                                                decor.setPadding(0, 0, 0, 0);
                                            }
                                            refreshSpiderButtonStates(a, content);
                                        } catch (Throwable ignored) {
                                        }
                                        return true;
                                    }
                                });
            }

            styleHierarchyPass(a, decor, content, winH);
        } catch (Throwable t) {
            AppLog.w("PluginDialogStyler", "stylePluginDecor skipped", t);
        }
    }

    private static void adjustWindowLayoutParams(
            MainActivity a, ViewGroup decor, int targetWidth, int screenHeight) {
        try {
            ViewGroup.LayoutParams raw = decor.getLayoutParams();
            if (!(raw instanceof WindowManager.LayoutParams)) return;
            WindowManager.LayoutParams wlp = (WindowManager.LayoutParams) raw;
            boolean changed = false;
            if (wlp.width != targetWidth) {
                wlp.width = targetWidth;
                changed = true;
            }
            int maxHeight = Math.round(screenHeight * 0.84f);
            if (wlp.height > maxHeight) {
                wlp.height = maxHeight;
                changed = true;
            }
            if (wlp.gravity != Gravity.CENTER
                    || wlp.x != 0
                    || wlp.y != 0
                    || wlp.horizontalMargin != 0f) {
                wlp.gravity = Gravity.CENTER;
                wlp.x = 0;
                wlp.y = 0;
                wlp.horizontalMargin = 0f;
                changed = true;
            }
            if ((wlp.flags & WindowManager.LayoutParams.FLAG_DIM_BEHIND) == 0
                    || wlp.dimAmount < 0.58f) {
                wlp.flags |= WindowManager.LayoutParams.FLAG_DIM_BEHIND;
                wlp.dimAmount = 0.68f;
                changed = true;
            }
            if (changed) {
                WindowManager wm = (WindowManager) a.getSystemService(Context.WINDOW_SERVICE);
                if (wm != null) wm.updateViewLayout(decor, wlp);
            }
        } catch (Throwable ignored) {
        }
    }

    private static void styleHierarchyPass(
            MainActivity a, ViewGroup decor, ViewGroup content, int winH) {
        // Strip OEM 9-patch backgrounds, inset paddings, and margins from content up to DecorView
        clearAncestorsUpToDecor(content, decor);

        View firstChild = content.getChildAt(0);
        if (!(firstChild instanceof ViewGroup)) return;
        ViewGroup cardRoot = (ViewGroup) firstChild;

        ViewGroup.LayoutParams cardLp = cardRoot.getLayoutParams();
        if (cardLp != null) {
            boolean lpDirty = false;
            if (cardLp.width != ViewGroup.LayoutParams.MATCH_PARENT) {
                cardLp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                lpDirty = true;
            }
            if (cardLp instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) cardLp;
                if (mlp.leftMargin != 0
                        || mlp.rightMargin != 0
                        || mlp.topMargin != 0
                        || mlp.bottomMargin != 0) {
                    mlp.setMargins(0, 0, 0, 0);
                    zeroRelativeMargins(mlp);
                    lpDirty = true;
                }
            }
            if (lpDirty) cardRoot.setLayoutParams(cardLp);
        }

        if (STYLED_CARD_ROOTS.add(cardRoot)) {
            // Match iOS AppleGlassSurface obsidian-slate palette (#242429 -> #16161B)
            GradientDrawable glassCard =
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {0xf524242a, 0xf816161b});
            glassCard.setCornerRadius(a.dp(26));
            glassCard.setStroke(Math.max(1, a.dp(0.9f)), 0x2effffff);
            cardRoot.setBackground(glassCard);
            cardRoot.setPadding(a.dp(16), a.dp(16), a.dp(16), a.dp(14));
            cardRoot.setClipToPadding(true);
        }

        styleSubtree(a, cardRoot, cardRoot, winH, 0);
        styleAlertButtonBar(a, cardRoot);
    }

    private static void clearAncestorsUpToDecor(View start, View stop) {
        View cur = start;
        while (cur != null) {
            cur.setBackground(new ColorDrawable(Color.TRANSPARENT));
            if (cur.getPaddingLeft() != 0
                    || cur.getPaddingTop() != 0
                    || cur.getPaddingRight() != 0
                    || cur.getPaddingBottom() != 0) {
                cur.setPadding(0, 0, 0, 0);
            }
            ViewGroup.LayoutParams lp = cur.getLayoutParams();
            if (cur != stop && lp != null) {
                boolean changed = false;
                if (lp.width > 0) {
                    lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                    changed = true;
                }
                if (lp instanceof ViewGroup.MarginLayoutParams) {
                    ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) lp;
                    if (mlp.leftMargin != 0
                            || mlp.rightMargin != 0
                            || mlp.topMargin != 0
                            || mlp.bottomMargin != 0) {
                        mlp.setMargins(0, 0, 0, 0);
                        zeroRelativeMargins(mlp);
                        changed = true;
                    }
                }
                if (changed) cur.setLayoutParams(lp);
            }
            if (cur == stop || !(cur.getParent() instanceof View)) break;
            cur = (View) cur.getParent();
        }
    }

    private static void zeroRelativeMargins(ViewGroup.MarginLayoutParams mlp) {
        if (Build.VERSION.SDK_INT >= 17) {
            mlp.setMarginStart(0);
            mlp.setMarginEnd(0);
        }
    }

    private static void styleSubtree(
            final MainActivity a,
            final View v,
            final ViewGroup cardRoot,
            final int winH,
            final int depth) {
        if (v == null || depth > 16) return;

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

        boolean inHScroll = v.getParent() instanceof HorizontalScrollView;

        // Detect Pan.java LoginShow row: Horizontal LinearLayout containing account + status toggle
        if (v instanceof LinearLayout && isSpiderDriveRow((LinearLayout) v)) {
            styleSpiderDriveRow(a, (LinearLayout) v);
            return;
        }

        // Detect generic horizontal button row inside spider custom layouts (e.g. [取消] or QR
        // actions)
        if (v != cardRoot
                && v instanceof LinearLayout
                && !"buttonPanel".equals(resName)
                && isPluginHorizontalButtonBar((LinearLayout) v)) {
            stylePluginHorizontalButtonBar(a, (LinearLayout) v);
            return;
        }

        // Normalize all intermediate ViewGroups so hardcoded widths (e.g. 500dp) or OEM AlertDialog
        // 24dp panel paddings never push child buttons past cardRoot's right edge
        if (v != cardRoot && v instanceof ViewGroup && !inHScroll) {
            ViewGroup.LayoutParams lp = v.getLayoutParams();
            if (lp != null) {
                boolean changed = false;
                boolean shouldFillWidth =
                        lp.width > 0
                                || v instanceof ScrollView
                                || v instanceof FrameLayout
                                || v instanceof ListView
                                || (v instanceof LinearLayout
                                        && ((LinearLayout) v).getOrientation()
                                                == LinearLayout.VERTICAL)
                                || isFrameworkPanelName(resName);
                if (shouldFillWidth && lp.width != ViewGroup.LayoutParams.MATCH_PARENT) {
                    lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                    changed = true;
                }
                if (lp instanceof ViewGroup.MarginLayoutParams) {
                    ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) lp;
                    if (mlp.leftMargin != 0 || mlp.rightMargin != 0) {
                        mlp.leftMargin = 0;
                        mlp.rightMargin = 0;
                        zeroRelativeMargins(mlp);
                        changed = true;
                    }
                }
                if (changed) v.setLayoutParams(lp);
            }
            v.setMinimumWidth(0);
            if (isFrameworkPanelName(resName)) {
                v.setMinimumHeight(0);
            }
            if (!(v instanceof ListView)) {
                if (v.getBackground() != null) {
                    v.setBackgroundColor(Color.TRANSPARENT);
                }
                if (v.getPaddingLeft() != 0 || v.getPaddingRight() != 0) {
                    int topP = Math.min(v.getPaddingTop(), a.dp(4));
                    int botP = Math.min(v.getPaddingBottom(), a.dp(4));
                    v.setPadding(0, topP, 0, botP);
                }
                if (v instanceof ScrollView) {
                    ((ScrollView) v).setVerticalScrollBarEnabled(false);
                }
            }
        }

        if (v instanceof ListView) {
            styleListView(a, (ListView) v);
            return;
        }

        if (v instanceof ImageView) {
            styleQrOrIconImageView(a, (ImageView) v, resName, winH);
            return;
        }

        if (v instanceof EditText) {
            styleEditText(a, (EditText) v, inHScroll);
            return;
        }

        if (v instanceof Button) {
            styleGenericPluginButton(a, (Button) v, inHScroll);
            return;
        }

        if (v instanceof TextView) {
            stylePluginTextView(a, (TextView) v, resName, inHScroll);
            return;
        }

        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                styleSubtree(a, vg.getChildAt(i), cardRoot, winH, depth + 1);
            }
        }
    }

    private static boolean isFrameworkPanelName(String resName) {
        return "parentPanel".equals(resName)
                || "topPanel".equals(resName)
                || "title_template".equals(resName)
                || "contentPanel".equals(resName)
                || "scrollView".equals(resName)
                || "customPanel".equals(resName)
                || "custom".equals(resName)
                || "buttonPanel".equals(resName);
    }

    private static boolean isSpiderDriveRow(LinearLayout row) {
        if (row.getOrientation() != LinearLayout.HORIZONTAL) return false;
        if (row.getChildCount() != 2) return false;
        if (!(row.getChildAt(0) instanceof Button) || !(row.getChildAt(1) instanceof Button)) {
            return false;
        }
        String left = textOf((TextView) row.getChildAt(0));
        String right = textOf((TextView) row.getChildAt(1));
        return left.contains("登录")
                || left.contains("夸")
                || left.contains("优汐")
                || left.contains("UC")
                || left.contains("嘟嘟")
                || left.contains("百度")
                || left.contains("阿狸")
                || left.contains("阿里")
                || left.contains("115")
                || left.contains("天翼")
                || left.contains("移动")
                || left.contains("123")
                || left.contains("迅雷")
                || right.contains("启用")
                || right.contains("停用");
    }

    private static boolean isPluginHorizontalButtonBar(LinearLayout row) {
        if (row.getOrientation() != LinearLayout.HORIZONTAL) return false;
        int n = row.getChildCount();
        if (n == 0 || n > 5) return false;
        int btnCount = 0;
        for (int i = 0; i < n; i++) {
            View c = row.getChildAt(i);
            int id = c.getId();
            if (id == android.R.id.button1
                    || id == android.R.id.button2
                    || id == android.R.id.button3) {
                return false;
            }
            if (c instanceof Button) {
                btnCount++;
            } else if (c.getVisibility() == View.VISIBLE
                    && (c instanceof ViewGroup
                            || c instanceof ImageView
                            || c instanceof EditText)) {
                return false;
            }
        }
        return btnCount >= 1;
    }

    private static void stylePluginHorizontalButtonBar(MainActivity a, LinearLayout row) {
        STYLED_BUTTON_ROWS.add(row);
        row.setBackgroundColor(Color.TRANSPARENT);
        row.setMinimumWidth(0);
        row.setPadding(0, a.dp(6), 0, a.dp(2));
        ViewGroup.LayoutParams rawLp = row.getLayoutParams();
        if (rawLp != null) {
            rawLp.width = ViewGroup.LayoutParams.MATCH_PARENT;
            if (rawLp instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) rawLp;
                mlp.leftMargin = 0;
                mlp.rightMargin = 0;
                zeroRelativeMargins(mlp);
            }
            row.setLayoutParams(rawLp);
        }

        List<Button> buttons = new ArrayList<>();
        for (int i = 0; i < row.getChildCount(); i++) {
            View c = row.getChildAt(i);
            if (c instanceof Button && c.getVisibility() != View.GONE) {
                buttons.add((Button) c);
            } else if (!(c instanceof Button)) {
                // Collapse fixed-width spacers that push trailing [取消] off screen
                ViewGroup.LayoutParams slp = c.getLayoutParams();
                if (slp instanceof LinearLayout.LayoutParams) {
                    LinearLayout.LayoutParams lslp = (LinearLayout.LayoutParams) slp;
                    lslp.width = 0;
                    lslp.weight = 1f;
                    lslp.setMargins(0, 0, 0, 0);
                    zeroRelativeMargins(lslp);
                    c.setLayoutParams(lslp);
                }
            }
        }

        if (buttons.size() == 1) {
            row.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
            Button only = buttons.get(0);
            only.setMinWidth(0);
            only.setMinimumWidth(0);
            only.setMinHeight(a.dp(36));
            only.setMinimumHeight(a.dp(36));
            if (only.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                LinearLayout.LayoutParams blp = (LinearLayout.LayoutParams) only.getLayoutParams();
                blp.width = ViewGroup.LayoutParams.WRAP_CONTENT;
                blp.height = a.dp(36);
                blp.weight = 0f;
                blp.setMargins(0, 0, 0, 0);
                zeroRelativeMargins(blp);
                only.setLayoutParams(blp);
            }
            only.setPadding(a.dp(18), 0, a.dp(18), 0);
            applyIosActionCapsuleStyle(a, only, false);
        } else if (buttons.size() > 1) {
            row.setGravity(Gravity.CENTER_VERTICAL);
            for (int i = 0; i < buttons.size(); i++) {
                Button b = buttons.get(i);
                b.setMinWidth(0);
                b.setMinimumWidth(0);
                b.setMinHeight(a.dp(38));
                b.setMinimumHeight(a.dp(38));
                if (b.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                    LinearLayout.LayoutParams blp = (LinearLayout.LayoutParams) b.getLayoutParams();
                    blp.width = 0;
                    blp.height = a.dp(38);
                    blp.weight = 1f;
                    blp.setMargins(0, 0, i < buttons.size() - 1 ? a.dp(8) : 0, 0);
                    zeroRelativeMargins(blp);
                    b.setLayoutParams(blp);
                }
                b.setPadding(a.dp(8), 0, a.dp(8), 0);
                applyIosActionCapsuleStyle(a, b, i == 0 && !isCancelLabel(textOf(b)));
            }
        }
    }

    private static boolean isCancelLabel(String text) {
        return text.contains("取消") || text.contains("关闭") || text.contains("返回");
    }

    private static void styleSpiderDriveRow(MainActivity a, LinearLayout row) {
        Button accountBtn = (Button) row.getChildAt(0);
        Button statusBtn = (Button) row.getChildAt(1);
        String accountLabel = textOf(accountBtn);
        String statusLabel = textOf(statusBtn);
        AccountPanel.recordObservedSpiderRow(a, accountLabel, statusLabel);

        boolean loggedIn =
                accountLabel.contains("已登录")
                        || accountLabel.contains("已绑定")
                        || accountLabel.contains("已配置");
        boolean enabled = statusLabel.contains("启用中") || statusLabel.contains("已启用");

        STYLED_DRIVE_ROWS.add(row);
        // Match iOS _buildDriveTile obsidian-slate gradient (#2E2E36 -> #1E1E24)
        GradientDrawable rowCard =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM,
                        new int[] {0xc42e2e36, 0xc41e1e24});
        rowCard.setCornerRadius(a.dp(16));
        rowCard.setStroke(
                Math.max(1, a.dp(0.8f)),
                (loggedIn && enabled) ? 0x7a30d158 : (loggedIn ? 0x4830d158 : 0x24ffffff));
        row.setBackground(rowCard);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(10), a.dp(7), a.dp(9), a.dp(7));

        ViewGroup.LayoutParams rawLp = row.getLayoutParams();
        if (rawLp != null) {
            rawLp.width = ViewGroup.LayoutParams.MATCH_PARENT;
            if (rawLp instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams mlp = (ViewGroup.MarginLayoutParams) rawLp;
                mlp.leftMargin = 0;
                mlp.rightMargin = 0;
                mlp.topMargin = 0;
                mlp.bottomMargin = a.dp(9);
                zeroRelativeMargins(mlp);
            }
            row.setLayoutParams(rawLp);
        }

        accountBtn.setMinWidth(0);
        accountBtn.setMinimumWidth(0);
        accountBtn.setMinHeight(0);
        accountBtn.setMinimumHeight(0);
        if (accountBtn.getLayoutParams() instanceof LinearLayout.LayoutParams) {
            LinearLayout.LayoutParams leftLp =
                    (LinearLayout.LayoutParams) accountBtn.getLayoutParams();
            leftLp.width = 0;
            leftLp.weight = 1f;
            leftLp.height = a.dp(38);
            leftLp.setMargins(0, 0, a.dp(8), 0);
            zeroRelativeMargins(leftLp);
            accountBtn.setLayoutParams(leftLp);
        }
        accountBtn.setPadding(a.dp(8), 0, a.dp(6), 0);

        statusBtn.setMinWidth(0);
        statusBtn.setMinimumWidth(0);
        statusBtn.setMinHeight(0);
        statusBtn.setMinimumHeight(0);
        if (statusBtn.getLayoutParams() instanceof LinearLayout.LayoutParams) {
            LinearLayout.LayoutParams rightLp =
                    (LinearLayout.LayoutParams) statusBtn.getLayoutParams();
            rightLp.width = a.dp(68);
            rightLp.weight = 0f;
            rightLp.height = a.dp(32);
            rightLp.setMargins(0, 0, 0, 0);
            zeroRelativeMargins(rightLp);
            statusBtn.setLayoutParams(rightLp);
        }
        statusBtn.setPadding(a.dp(6), 0, a.dp(6), 0);

        applySpiderDriveAccountButton(a, accountBtn);
        applySpiderDriveStatusPill(a, statusBtn);
    }

    private static void refreshSpiderButtonStates(MainActivity a, ViewGroup root) {
        if (root == null) return;
        for (int i = 0; i < root.getChildCount(); i++) {
            View child = root.getChildAt(i);
            if (child instanceof LinearLayout && isSpiderDriveRow((LinearLayout) child)) {
                styleSpiderDriveRow(a, (LinearLayout) child);
            } else if (child instanceof LinearLayout && STYLED_BUTTON_ROWS.contains(child)) {
                stylePluginHorizontalButtonBar(a, (LinearLayout) child);
            } else if (child instanceof ListView) {
                ListView lv = (ListView) child;
                for (int j = 0; j < lv.getChildCount(); j++) {
                    styleListItem(a, lv.getChildAt(j));
                }
            } else if (child instanceof Button) {
                Button btn = (Button) child;
                int id = btn.getId();
                if (id != android.R.id.button1
                        && id != android.R.id.button2
                        && id != android.R.id.button3) {
                    applyIosActionCapsuleStyle(a, btn, false);
                }
            } else if (child instanceof ViewGroup) {
                refreshSpiderButtonStates(a, (ViewGroup) child);
            }
        }
    }

    private static final class StyledSpiderButtonBg extends GradientDrawable {
        final String appliedKey;

        StyledSpiderButtonBg(String appliedKey) {
            this.appliedKey = appliedKey;
        }
    }

    private static void applySpiderDriveAccountButton(MainActivity a, Button btn) {
        String label = textOf(btn);
        String stateKey = "acct:" + label;
        Drawable existing = btn.getBackground();
        if (existing instanceof StyledSpiderButtonBg
                && stateKey.equals(((StyledSpiderButtonBg) existing).appliedKey)) {
            return;
        }
        boolean loggedIn = label.contains("已登录") || label.contains("已绑定") || label.contains("已配置");

        StyledSpiderButtonBg gd = new StyledSpiderButtonBg(stateKey);
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(11));
        gd.setColor(loggedIn ? 0x1c30d158 : 0x10ffffff);
        gd.setStroke(Math.max(1, a.dp(0.6f)), loggedIn ? 0x4230d158 : 0x16ffffff);

        btn.setAllCaps(false);
        btn.setIncludeFontPadding(false);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setTextSize(13.5f);
        btn.setTextColor(loggedIn ? 0xffffffff : 0xe6f5f5f7);
        if (Build.VERSION.SDK_INT >= 21) {
            btn.setStateListAnimator(null);
            btn.setElevation(0f);
        }
        btn.setBackground(gd);
    }

    private static void applySpiderDriveStatusPill(MainActivity a, Button btn) {
        String label = textOf(btn);
        String stateKey = "pill:" + label;
        Drawable existing = btn.getBackground();
        if (existing instanceof StyledSpiderButtonBg
                && stateKey.equals(((StyledSpiderButtonBg) existing).appliedKey)) {
            return;
        }
        boolean enabled = label.contains("启用中") || label.contains("已启用");

        StyledSpiderButtonBg gd = new StyledSpiderButtonBg(stateKey);
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(999));
        gd.setColor(enabled ? 0x3330d158 : 0xa63a3a42);
        gd.setStroke(Math.max(1, a.dp(0.6f)), enabled ? 0x7330d158 : 0x24ffffff);

        btn.setAllCaps(false);
        btn.setIncludeFontPadding(false);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setTextSize(11.8f);
        btn.setTextColor(enabled ? 0xff30d158 : 0x99ebebf5);
        if (Build.VERSION.SDK_INT >= 21) {
            btn.setStateListAnimator(null);
            btn.setElevation(0f);
        }
        btn.setBackground(gd);
    }

    private static void applyIosActionCapsuleStyle(
            MainActivity a, Button btn, boolean highlightPrimary) {
        String label = textOf(btn);
        String stateKey = (highlightPrimary ? "pri:" : "sec:") + label;
        Drawable existing = btn.getBackground();
        if (existing instanceof StyledSpiderButtonBg
                && stateKey.equals(((StyledSpiderButtonBg) existing).appliedKey)) {
            return;
        }

        boolean positive = label.contains("已登录") || label.contains("启用中") || label.contains("已启用");
        boolean cancel = isCancelLabel(label);

        int fill;
        int stroke;
        int textCol;
        if (highlightPrimary && !cancel) {
            fill = 0xfff5f5f7;
            stroke = 0x00000000;
            textCol = 0xff111114;
        } else if (positive) {
            fill = 0x3330d158;
            stroke = 0x7330d158;
            textCol = 0xff30d158;
        } else if (cancel) {
            fill = 0x8c3a3a42;
            stroke = 0x26ffffff;
            textCol = 0xe6f5f5f7;
        } else {
            fill = 0x280a84ff;
            stroke = 0x660a84ff;
            textCol = 0xff64b5ff;
        }

        StyledSpiderButtonBg gd = new StyledSpiderButtonBg(stateKey);
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(999));
        gd.setColor(fill);
        if (stroke != 0) gd.setStroke(Math.max(1, a.dp(0.8f)), stroke);

        btn.setAllCaps(false);
        btn.setIncludeFontPadding(false);
        btn.setSingleLine(true);
        btn.setEllipsize(TextUtils.TruncateAt.END);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setTextSize(13f);
        btn.setTextColor(textCol);
        if (Build.VERSION.SDK_INT >= 21) {
            btn.setStateListAnimator(null);
            btn.setElevation(0f);
        }
        btn.setBackground(gd);
    }

    private static void styleGenericPluginButton(MainActivity a, Button btn, boolean inHScroll) {
        int id = btn.getId();
        if (id == android.R.id.button1
                || id == android.R.id.button2
                || id == android.R.id.button3) {
            return;
        }
        btn.setMinWidth(0);
        btn.setMinimumWidth(0);
        btn.setMinHeight(a.dp(38));
        btn.setMinimumHeight(a.dp(38));
        if (!inHScroll) {
            ViewGroup.LayoutParams lp = btn.getLayoutParams();
            if (lp != null && lp.width > 0) {
                lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                btn.setLayoutParams(lp);
            }
        }
        btn.setPadding(a.dp(14), a.dp(6), a.dp(14), a.dp(6));
        applyIosActionCapsuleStyle(a, btn, false);
    }

    private static void styleAlertButtonBar(MainActivity a, ViewGroup cardRoot) {
        int[] ids = {android.R.id.button1, android.R.id.button2, android.R.id.button3};
        for (int id : ids) {
            View found = cardRoot.findViewById(id);
            if (!(found instanceof Button) || found.getVisibility() != View.VISIBLE) continue;
            Button b = (Button) found;
            View parent = b.getParent() instanceof View ? (View) b.getParent() : null;
            if (parent instanceof ViewGroup) {
                parent.setPadding(0, a.dp(6), 0, 0);
                parent.setBackgroundColor(Color.TRANSPARENT);
                ViewGroup.LayoutParams plp = parent.getLayoutParams();
                if (plp != null && plp.width != ViewGroup.LayoutParams.MATCH_PARENT) {
                    plp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                    parent.setLayoutParams(plp);
                }
                ViewGroup bar = (ViewGroup) parent;
                for (int i = 0; i < bar.getChildCount(); i++) {
                    View sibling = bar.getChildAt(i);
                    if (!(sibling instanceof Button)
                            && sibling.getLayoutParams() instanceof LinearLayout.LayoutParams) {
                        LinearLayout.LayoutParams slp =
                                (LinearLayout.LayoutParams) sibling.getLayoutParams();
                        slp.width = 0;
                        slp.weight = 1f;
                        sibling.setLayoutParams(slp);
                    }
                }
            }
            boolean primary = (id == android.R.id.button1);
            GradientDrawable pill = new GradientDrawable();
            pill.setShape(GradientDrawable.RECTANGLE);
            pill.setCornerRadius(a.dp(999));
            pill.setColor(primary ? 0xff0a84ff : 0x8c3a3a42);
            if (!primary) {
                pill.setStroke(Math.max(1, a.dp(0.8f)), 0x26ffffff);
            }
            b.setAllCaps(false);
            b.setIncludeFontPadding(false);
            b.setSingleLine(true);
            b.setTypeface(null, Typeface.BOLD);
            b.setTextSize(13f);
            b.setTextColor(primary ? Color.WHITE : 0xe6f5f5f7);
            b.setMinHeight(a.dp(36));
            b.setMinimumHeight(a.dp(36));
            b.setMinWidth(0);
            b.setMinimumWidth(0);
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
                mlp.rightMargin = 0;
                mlp.topMargin = a.dp(2);
                mlp.bottomMargin = 0;
                if (Build.VERSION.SDK_INT >= 17) {
                    mlp.setMarginStart(a.dp(8));
                    mlp.setMarginEnd(0);
                }
                b.setLayoutParams(mlp);
            }
        }
    }

    private static void stylePluginTextView(
            MainActivity a, TextView tv, String resName, boolean inHScroll) {
        if (!inHScroll) {
            ViewGroup.LayoutParams lp = tv.getLayoutParams();
            if (lp != null && lp.width > 0) {
                lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                tv.setLayoutParams(lp);
            }
        }
        boolean isAlertTitle = "alertTitle".equals(resName) || tv.getId() == android.R.id.title;
        if (isAlertTitle) {
            tv.setTextSize(15f);
            tv.setTypeface(null, Typeface.BOLD);
            tv.setTextColor(0xfff5f5f7);
            tv.setSingleLine(false);
            tv.setMaxLines(2);
            tv.setEllipsize(TextUtils.TruncateAt.END);
            tv.setLineSpacing(a.dp(2), 1f);
            tv.setPadding(a.dp(2), a.dp(2), a.dp(2), a.dp(10));
            return;
        }
        int curColor = tv.getCurrentTextColor();
        if (Color.alpha(curColor) > 80
                && Color.red(curColor) < 95
                && Color.green(curColor) < 95
                && Color.blue(curColor) < 95) {
            tv.setTextColor(0xe6f5f5f7);
        } else if (tv.getId() == android.R.id.message) {
            tv.setTextColor(0xd9ebebf5);
            tv.setTextSize(13.5f);
            tv.setLineSpacing(a.dp(3), 1f);
        }
    }

    private static void styleEditText(MainActivity a, EditText input, boolean inHScroll) {
        if (!inHScroll) {
            ViewGroup.LayoutParams lp = input.getLayoutParams();
            if (lp != null && lp.width > 0) {
                lp.width = ViewGroup.LayoutParams.MATCH_PARENT;
                input.setLayoutParams(lp);
            }
        }
        GradientDrawable gd = new GradientDrawable();
        gd.setShape(GradientDrawable.RECTANGLE);
        gd.setCornerRadius(a.dp(14));
        gd.setColor(0x992c2c34);
        gd.setStroke(Math.max(1, a.dp(0.8f)), 0x36ffffff);
        input.setBackground(gd);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0x73ebebf5);
        input.setTextSize(14f);
        input.setPadding(a.dp(14), a.dp(11), a.dp(14), a.dp(11));
    }

    private static void styleQrOrIconImageView(
            MainActivity a, ImageView iv, String resName, int winH) {
        if ("icon".equals(resName) || iv.getId() == android.R.id.icon) {
            if (iv.getDrawable() == null) iv.setVisibility(View.GONE);
            return;
        }
        ViewGroup.LayoutParams lp = iv.getLayoutParams();
        int w = lp != null && lp.width > 0 ? lp.width : iv.getMeasuredWidth();
        int h = lp != null && lp.height > 0 ? lp.height : iv.getMeasuredHeight();
        boolean likelyQr =
                (w >= a.dp(105) && h >= a.dp(105))
                        || (iv.getDrawable() != null
                                && iv.getDrawable().getIntrinsicWidth() >= 130
                                && Math.abs(
                                                iv.getDrawable().getIntrinsicWidth()
                                                        - iv.getDrawable().getIntrinsicHeight())
                                        <= 36);
        if (likelyQr) {
            int maxQr = Math.min(a.dp(196), Math.max(a.dp(150), Math.round(winH * 0.30f)));
            if (lp != null) {
                lp.width = maxQr;
                lp.height = maxQr;
                if (lp instanceof LinearLayout.LayoutParams) {
                    ((LinearLayout.LayoutParams) lp).gravity = Gravity.CENTER_HORIZONTAL;
                    ((LinearLayout.LayoutParams) lp).topMargin = a.dp(10);
                    ((LinearLayout.LayoutParams) lp).bottomMargin = a.dp(10);
                } else if (lp instanceof FrameLayout.LayoutParams) {
                    ((FrameLayout.LayoutParams) lp).gravity = Gravity.CENTER_HORIZONTAL;
                }
                iv.setLayoutParams(lp);
            }
            GradientDrawable qrPad = new GradientDrawable();
            qrPad.setShape(GradientDrawable.RECTANGLE);
            qrPad.setCornerRadius(a.dp(18));
            qrPad.setColor(Color.WHITE);
            iv.setBackground(qrPad);
            iv.setPadding(a.dp(10), a.dp(10), a.dp(10), a.dp(10));
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
        }
    }

    private static void styleListView(final MainActivity a, ListView lv) {
        if (STYLED_LIST_VIEWS.add(lv)) {
            lv.setBackgroundColor(Color.TRANSPARENT);
            lv.setCacheColorHint(Color.TRANSPARENT);
            lv.setDivider(new ColorDrawable(0x18ffffff));
            lv.setDividerHeight(1);
            lv.setSelector(new ColorDrawable(0x1cffffff));
        }
        for (int i = 0; i < lv.getChildCount(); i++) {
            styleListItem(a, lv.getChildAt(i));
        }
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
                        android.content.res.ColorStateList.valueOf(0xff0a84ff));
            }
        } else if (child instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) child;
            for (int i = 0; i < vg.getChildCount(); i++) {
                styleListItem(a, vg.getChildAt(i));
            }
        }
    }

    private static String textOf(TextView tv) {
        return tv == null || tv.getText() == null ? "" : tv.getText().toString().trim();
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

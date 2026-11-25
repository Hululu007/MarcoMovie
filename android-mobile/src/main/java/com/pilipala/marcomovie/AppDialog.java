package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.DialogInterface;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Typeface;
import android.os.Build;
import android.view.*;
import android.widget.*;
import java.util.*;

/** Shared app-owned dialog chrome for lists, confirmations, text and forms. */
final class AppDialog extends Dialog {
    final MainActivity a;
    final Map<Integer, Button> actions = new HashMap<>();
    final View anchor;
    final Builder spec;
    private LinearLayout dialogPanel;
    private boolean dismissing;

    AppDialog(Builder b) {
        super(b.a);
        a = b.a;
        spec = b;
        anchor = a.getCurrentFocus();
        requestWindowFeature(Window.FEATURE_NO_TITLE);
    }

    Button getButton(int which) {
        return actions.get(which);
    }

    void style(Button button) {
        if (!a.isTvDevice()) {
            styleMobileButton(button, false, MobileTheme.of(a));
            return;
        }
        button.setBackground(a.bg(0xff33333b, 18));
        button.setOnFocusChangeListener(
                (v, focused) -> {
                    FocusMotion.style(
                            a,
                            button,
                            focused,
                            0xff33333b,
                            MainActivity.WHITE,
                            18,
                            MainActivity.WHITE,
                            MainActivity.DARK,
                            false,
                            1.015f);
                });
    }

    private void styleMobileButton(Button button, boolean primary, MobileTheme.Palette p) {
        button.setOnFocusChangeListener(null);
        button.setFocusable(false);
        button.setFocusableInTouchMode(false);
        if (primary) {
            button.setBackground(a.bg(p.accent, 14));
            button.setTextColor(p.accentOnFill);
            button.setTypeface(null, Typeface.BOLD);
        } else {
            button.setBackground(a.bg(p.bgSubtle, 14));
            button.setTextColor(p.textPrimary);
            button.setTypeface(null, Typeface.NORMAL);
        }
        UiWidgets.bindTouchFeedback(button);
    }

    private static void adaptLightCustomView(MainActivity a, View v, MobileTheme.Palette p) {
        if (v == null) return;
        if (v instanceof EditText) {
            EditText et = (EditText) v;
            int c = et.getCurrentTextColor();
            if (isLightNeutralColor(c, 200)) {
                et.setTextColor(p.textPrimary);
                et.setHintTextColor(p.textTertiary);
                et.setBackground(MobileTheme.subtleBg(a, 12));
            }
            return;
        }
        if (v instanceof CheckBox) {
            CheckBox cb = (CheckBox) v;
            int c = cb.getCurrentTextColor();
            if (isLightNeutralColor(c, 165)) {
                cb.setTextColor(p.textPrimary);
            }
            if (Build.VERSION.SDK_INT >= 21) {
                cb.setButtonTintList(ColorStateList.valueOf(p.accent));
            }
            return;
        }
        if (v instanceof Button) {
            Button btn = (Button) v;
            int c = btn.getCurrentTextColor();
            if (isLightNeutralColor(c, 210) && !isSaturatedButtonFill(btn)) {
                btn.setOnFocusChangeListener(null);
                btn.setFocusable(false);
                btn.setFocusableInTouchMode(false);
                btn.setBackground(MobileTheme.subtleBg(a, 12));
                btn.setTextColor(p.textPrimary);
                UiWidgets.bindTouchFeedback(btn);
            }
            return;
        }
        if (v instanceof TextView) {
            TextView tv = (TextView) v;
            if (!hasOpaqueFillBackground(tv)) {
                int c = tv.getCurrentTextColor();
                if (isLightNeutralColor(c, 210)) {
                    tv.setTextColor(p.textPrimary);
                } else if (isLightNeutralColor(c, 145)) {
                    tv.setTextColor(p.textSecondary);
                }
            }
            return;
        }
        if (v instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                adaptLightCustomView(a, vg.getChildAt(i), p);
            }
        }
    }

    private static boolean isSaturatedButtonFill(Button btn) {
        android.graphics.drawable.Drawable bg = btn.getBackground();
        if (bg == null) return false;
        if (Build.VERSION.SDK_INT >= 24
                && bg instanceof android.graphics.drawable.GradientDrawable) {
            ColorStateList csl = ((android.graphics.drawable.GradientDrawable) bg).getColor();
            if (csl != null) {
                int col = csl.getDefaultColor();
                int r = (col >> 16) & 0xFF;
                int g = (col >> 8) & 0xFF;
                int b = col & 0xFF;
                int max = Math.max(r, Math.max(g, b));
                int min = Math.min(r, Math.min(g, b));
                return (max - min) >= 48;
            }
        }
        return false;
    }

    private static boolean hasOpaqueFillBackground(View v) {
        android.graphics.drawable.Drawable bg = v.getBackground();
        if (bg == null) return false;
        if (bg instanceof android.graphics.drawable.ColorDrawable) {
            return (((android.graphics.drawable.ColorDrawable) bg).getColor() >>> 24) >= 0x40;
        }
        return true;
    }

    private static boolean isLightNeutralColor(int color, int minLuma) {
        int alpha = (color >>> 24) & 0xFF;
        if (alpha < 0x80) return false;
        int r = (color >> 16) & 0xFF;
        int g = (color >> 8) & 0xFF;
        int b = color & 0xFF;
        int max = Math.max(r, Math.max(g, b));
        int min = Math.min(r, Math.min(g, b));
        if (max - min > 48) return false;
        float luma = 0.299f * r + 0.587f * g + 0.114f * b;
        return luma >= minLuma;
    }

    static int computeMaxContentHeight(int winH, int chromeH, int outerMarginY, int minH) {
        int available = Math.max(0, winH - Math.max(0, outerMarginY) - Math.max(0, chromeH));
        return Math.max(minH, available);
    }

    @Override
    public void show() {
        boolean tv = a.isTvDevice();
        MobileTheme.Palette p = tv ? null : MobileTheme.of(a);
        LinearLayout panel = a.vertical();
        panel.setTag("app-dialog");
        panel.setMinimumWidth(0);
        int padH = a.dp(tv ? 22 : 20);
        int padTop = a.dp(20);
        int padBottom = a.dp(16);
        panel.setPadding(padH, padTop, padH, padBottom);
        if (tv) {
            a.glass(panel, 28);
        } else {
            panel.setBackground(a.bg(p.bgSheet, 24));
            UiCompat.setElevation(panel, a.dp(16));
        }
        TextView titleView = null;
        if (spec.title != null) {
            titleView = a.text(spec.title, tv ? 22 : 19, tv ? MainActivity.WHITE : p.textPrimary);
            titleView.setTypeface(null, Typeface.BOLD);
            panel.addView(titleView);
            a.gap(panel, 12);
        }
        LinearLayout content = a.vertical();
        content.setClipChildren(false);
        content.setClipToPadding(false);
        content.setPadding(a.dp(tv ? 6 : 2), a.dp(4), a.dp(tv ? 6 : 2), a.dp(4));
        if (spec.message != null) {
            TextView message =
                    a.text(spec.message, tv ? 15 : 14.5f, tv ? 0xffd0d0d5 : p.textSecondary);
            message.setLineSpacing(a.dp(4), 1);
            message.setFocusable(tv);
            content.addView(message);
            a.gap(content, 10);
        }
        if (spec.view != null) {
            if (!tv && !p.isDark) {
                adaptLightCustomView(a, spec.view, p);
            }
            content.addView(spec.view);
        }
        View selected = null;
        if (spec.labels != null)
            for (int i = 0; i < spec.labels.length; i++) {
                final int index = i;
                boolean checked = i == spec.selected;
                Button item =
                        a.button(
                                (checked ? "✓  " : "") + spec.labels[i],
                                "dialog-option:" + i,
                                () -> {
                                    dismiss();
                                    if (spec.pick != null) spec.pick.onClick(this, index);
                                });
                item.setTextSize(15);
                item.setSingleLine(!spec.wrapChoices);
                item.setEllipsize(spec.wrapChoices ? null : android.text.TextUtils.TruncateAt.END);
                if (spec.wrapChoices) item.setMaxLines(Integer.MAX_VALUE);
                if (!tv) {
                    item.setOnFocusChangeListener(null);
                    item.setFocusable(false);
                    item.setFocusableInTouchMode(false);
                    item.setBackground(a.bg(checked ? p.pillSelectedFill : p.bgSubtle, 12));
                    item.setTextColor(p.textPrimary);
                    item.setTypeface(null, checked ? Typeface.BOLD : Typeface.NORMAL);
                    UiWidgets.bindTouchFeedback(item);
                }
                LinearLayout.LayoutParams lp =
                        new LinearLayout.LayoutParams(-1, spec.wrapChoices ? -2 : a.dp(46));
                lp.bottomMargin = a.dp(6);
                content.addView(item, lp);
                if (checked || selected == null) selected = item;
            }
        int marginH = tv ? a.dp(72) : a.dp(32);
        int width =
                Math.min(
                        a.dp(spec.wide ? 840 : (spec.view == null ? 520 : 660)),
                        a.windowWidth() - marginH);
        int innerWidth = Math.max(a.dp(200), width - padH * 2);

        LinearLayout footer = a.row();
        footer.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
        boolean compactFooter = spec.buttons.size() >= 3 || !tv;
        for (int code : new int[] {-3, -2, -1})
            if (spec.buttons.containsKey(code)) {
                Button button =
                        a.button(
                                spec.buttons.get(code),
                                "dialog-action:" + code,
                                () -> {
                                    dismiss();
                                    DialogInterface.OnClickListener action =
                                            spec.callbacks.get(code);
                                    if (action != null) action.onClick(this, code);
                                });
                button.setSingleLine(true);
                button.setEllipsize(android.text.TextUtils.TruncateAt.END);
                button.setMinWidth(0);
                button.setMinimumWidth(0);
                if (compactFooter) {
                    button.setTextSize(spec.buttons.size() >= 3 ? 13f : 14f);
                    button.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, a.dp(42), 1);
                    lp.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
                    footer.addView(button, lp);
                } else {
                    button.setTextSize(14);
                    a.addButton(footer, button);
                }
                actions.put(code, button);
            }

        int chromeHeight = padTop + padBottom;
        if (titleView != null) {
            titleView.measure(
                    View.MeasureSpec.makeMeasureSpec(innerWidth, View.MeasureSpec.AT_MOST),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
            chromeHeight += titleView.getMeasuredHeight() + a.dp(12);
        }
        if (footer.getChildCount() > 0) {
            footer.measure(
                    View.MeasureSpec.makeMeasureSpec(innerWidth, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
            chromeHeight += footer.getMeasuredHeight() + a.dp(14);
        }
        int outerMarginY = a.dp(tv ? 56 : 96);
        final int maxHeight =
                computeMaxContentHeight(a.windowHeight(), chromeHeight, outerMarginY, a.dp(110));

        content.measure(
                View.MeasureSpec.makeMeasureSpec(innerWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        ScrollView scroller = new TvScrollView(a);
        scroller.setVerticalScrollBarEnabled(false);
        scroller.addView(content, new ScrollView.LayoutParams(-1, -2));
        final FrameLayout clip =
                new FrameLayout(a) {
                    protected void dispatchDraw(Canvas c) {
                        int save = c.save();
                        c.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(c);
                        c.restoreToCount(save);
                    }
                };
        clip.setTag("scroll-viewport-clip");
        clip.setClipChildren(true);
        clip.setClipToPadding(true);
        clip.addView(scroller, new FrameLayout.LayoutParams(-1, -1));
        panel.addView(
                clip,
                new LinearLayout.LayoutParams(
                        -1, Math.min(maxHeight, Math.max(a.dp(24), content.getMeasuredHeight()))));
        content.addOnLayoutChangeListener(
                (v, l, t, r, b, ol, ot, orr, ob) -> {
                    int desired = Math.min(maxHeight, Math.max(a.dp(24), b - t));
                    ViewGroup.LayoutParams clp = clip.getLayoutParams();
                    if (clp != null && clp.height != desired) {
                        clp.height = desired;
                        clip.setLayoutParams(clp);
                    }
                });
        if (footer.getChildCount() > 0) {
            a.gap(panel, 12);
            panel.addView(footer, new LinearLayout.LayoutParams(-1, -2));
        }
        if (tv) {
            for (int i = 0; i < content.getChildCount(); i++)
                if (content.getChildAt(i) instanceof Button) style((Button) content.getChildAt(i));
            for (Button button : actions.values()) style(button);
        } else {
            for (Map.Entry<Integer, Button> entry : actions.entrySet()) {
                styleMobileButton(entry.getValue(), entry.getKey() == -1, p);
            }
        }
        dialogPanel = panel;
        dismissing = false;
        setContentView(panel);
        setOnCancelListener(spec.cancel);
        super.show();
        a.appDialog = this;
        Window w = getWindow();
        w.setBackgroundDrawableResource(android.R.color.transparent);
        w.getDecorView().setTag("app-dialog");
        w.getDecorView().setMinimumWidth(0);
        w.setLayout(width, -2);
        w.setGravity(Gravity.CENTER);
        w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        WindowManager.LayoutParams attrs = w.getAttributes();
        attrs.dimAmount = tv ? .5f : (p.isDark ? .62f : .42f);
        w.setAttributes(attrs);
        if (!tv) {
            MobileTheme.applyWindowBlurIfSupported(w, a.isReducedTransparency(), 24);
        }
        if (tv) {
            w.getDecorView().setSystemUiVisibility(5894);
            w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
            View first = selected;
            if (first == null)
                first = content.getChildCount() > 0 ? content.getChildAt(0) : actions.get(-1);
            if (first != null) first.requestFocus();
        } else {
            w.setSoftInputMode(
                    WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                            | WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN);
        }
        if (MobileMotion.isReduced(a)) {
            if (!tv) {
                panel.setAlpha(0f);
                panel.animate()
                        .alpha(1f)
                        .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                        .setInterpolator(MotionTokens.createLinearInterpolator())
                        .start();
            }
        } else {
            panel.setAlpha(0f);
            panel.setScaleX(.95f);
            panel.setScaleY(.95f);
            panel.animate()
                    .alpha(1f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .setDuration(MotionTokens.DURATION_FAST_MS)
                    .setInterpolator(MotionTokens.createDecelerateInterpolator())
                    .start();
        }
    }

    @Override
    public void dismiss() {
        if (a.isTvDevice()
                || dismissing
                || !isShowing()
                || a.isFinishing()
                || dialogPanel == null
                || !UiCompat.isAttached(dialogPanel)) {
            finishDismissImmediate();
            return;
        }
        dismissing = true;
        dialogPanel.animate().cancel();
        if (MobileMotion.isReduced(a)) {
            dialogPanel
                    .animate()
                    .alpha(0f)
                    .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .withEndAction(this::finishDismissImmediate)
                    .start();
        } else {
            dialogPanel
                    .animate()
                    .alpha(0f)
                    .scaleX(0.96f)
                    .scaleY(0.96f)
                    .setDuration(MotionTokens.DURATION_MICRO_MS)
                    .setInterpolator(MotionTokens.createAccelerateInterpolator())
                    .withEndAction(this::finishDismissImmediate)
                    .start();
        }
    }

    private void finishDismissImmediate() {
        try {
            super.dismiss();
        } catch (Throwable ignored) {
        }
        if (a.appDialog == this) a.appDialog = null;
        if (anchor != null && anchor.isAttachedToWindow()) anchor.requestFocus();
    }

    static final class Builder {
        final MainActivity a;
        boolean wrapChoices;
        boolean wide;
        String title, message;
        String[] labels;
        int selected = -1;
        View view;
        DialogInterface.OnClickListener pick;
        DialogInterface.OnCancelListener cancel;
        final Map<Integer, String> buttons = new HashMap<>();
        final Map<Integer, DialogInterface.OnClickListener> callbacks = new HashMap<>();

        Builder(MainActivity activity) {
            a = activity;
        }

        Builder setTitle(String value) {
            title = value;
            return this;
        }

        Builder setMessage(String value) {
            message = value;
            return this;
        }

        Builder setView(View value) {
            view = value;
            return this;
        }

        Builder wrapChoices() {
            wrapChoices = true;
            return this;
        }

        Builder setWide(boolean value) {
            wide = value;
            return this;
        }

        Builder setItems(String[] values, DialogInterface.OnClickListener action) {
            labels = values;
            pick = action;
            return this;
        }

        Builder setSingleChoiceItems(
                String[] values, int checked, DialogInterface.OnClickListener action) {
            selected = checked;
            return setItems(values, action);
        }

        Builder button(int code, String value, DialogInterface.OnClickListener action) {
            buttons.put(code, value);
            callbacks.put(code, action);
            return this;
        }

        Builder setPositiveButton(String value, DialogInterface.OnClickListener action) {
            return button(-1, value, action);
        }

        Builder setNegativeButton(String value, DialogInterface.OnClickListener action) {
            return button(-2, value, action);
        }

        Builder setNeutralButton(String value, DialogInterface.OnClickListener action) {
            return button(-3, value, action);
        }

        Builder setOnCancelListener(DialogInterface.OnCancelListener action) {
            cancel = action;
            return this;
        }

        AppDialog create() {
            return new AppDialog(this);
        }

        AppDialog show() {
            AppDialog dialog = create();
            dialog.show();
            return dialog;
        }
    }
}

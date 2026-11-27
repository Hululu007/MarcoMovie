package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Custom anchored controls; no platform alert/list chrome. */
final class PlayerBubble {
    private static final Typeface TV_MEDIUM_TYPEFACE =
            Typeface.create("sans-serif-medium", Typeface.NORMAL);
    private static final Typeface TV_REGULAR_TYPEFACE =
            Typeface.create("sans-serif", Typeface.NORMAL);

    interface IntAction {
        void accept(int index);
    }

    static final class Row {
        final String label;
        final boolean header;
        final boolean checked;
        final int actionIndex;

        private Row(String label, boolean header, boolean checked, int actionIndex) {
            this.label = label == null ? "" : label;
            this.header = header;
            this.checked = checked;
            this.actionIndex = actionIndex;
        }

        static Row header(String title) {
            return new Row(title, true, false, -1);
        }

        static Row item(int actionIndex, String label, boolean checked) {
            return new Row(label, false, checked, actionIndex);
        }
    }

    static Dialog show(
            MainActivity a,
            View anchor,
            String title,
            String[] labels,
            int selected,
            IntAction action,
            Runnable closed) {
        return show(a, anchor, title, labels, selected, action, closed, "");
    }

    static Dialog show(
            MainActivity a,
            View anchor,
            String title,
            String[] labels,
            int selected,
            IntAction action,
            Runnable closed,
            String message) {
        return show(a, anchor, title, labels, selected, action, closed, message, null);
    }

    static Dialog show(
            MainActivity a,
            View anchor,
            String title,
            String[] labels,
            int selected,
            IntAction action,
            Runnable closed,
            String message,
            Runnable onCancelBack) {
        java.util.List<Row> rows = new java.util.ArrayList<>(labels.length);
        for (int i = 0; i < labels.length; i++) {
            String raw = labels[i] == null ? "" : labels[i];
            boolean checked = (i == selected) || raw.startsWith("✓");
            rows.add(Row.item(i, raw, checked));
        }
        return showStructured(
                a, anchor, title, "", rows, selected, action, closed, message, false, onCancelBack);
    }

    static Dialog showStructured(
            MainActivity a,
            View anchor,
            String title,
            String statusBanner,
            java.util.List<Row> rows,
            int initialFocusActionIndex,
            IntAction action,
            Runnable closed,
            String message,
            boolean forceShowHeading,
            Runnable onCancelBack) {
        boolean modernTv = a.isTvDevice();
        boolean reducedTrans = a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false);
        String anchorTag =
                anchor != null && anchor.getTag() instanceof String ? (String) anchor.getTag() : "";
        if (modernTv && title != null && title.startsWith("字幕")) {
            anchorTag = "subtitles";
        } else if (modernTv && title != null && title.startsWith("弹幕")) {
            anchorTag = "danmaku";
        } else if (modernTv && title != null && title.startsWith("线路")) {
            anchorTag = "lines";
        }
        final String iconContext = anchorTag;
        String safeBanner = statusBanner == null ? "" : statusBanner.trim();
        String safeMessage = message == null ? "" : message;
        int actionRowCount = 0;
        int headerCount = 0;
        boolean hasLongLabel = !safeBanner.isEmpty();
        for (Row r : rows) {
            if (r.header) {
                headerCount++;
            } else {
                actionRowCount++;
                if (r.label.length() > 14) hasLongLabel = true;
            }
        }

        Dialog dialog = new Dialog(a);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout shell = a.vertical();
        shell.setTag("player-bubble");
        shell.setClipChildren(false);
        shell.setClipToPadding(false);
        float u = modernTv ? PlayerChrome.modernUnit(a) : 1f;
        LinearLayout panel = a.vertical();
        if (modernTv) {
            int pPad = PlayerChrome.vp(a, 8);
            panel.setPadding(pPad, pPad, pPad, pPad);
        } else {
            panel.setPadding(a.dp(16), a.dp(16), a.dp(16), a.dp(12));
        }
        android.graphics.drawable.GradientDrawable glass =
                new android.graphics.drawable.GradientDrawable();
        glass.setColor(modernTv ? (reducedTrans ? 0xff161922 : 0xf6151922) : 0xfa29292e);
        glass.setCornerRadius(modernTv ? u * 18f : a.dp(26));
        glass.setStroke(
                modernTv ? Math.max(1, Math.round(u * .75f)) : a.dp(1),
                modernTv ? 0xff3b4456 : 0x38ffffff);
        panel.setBackground(glass);
        // Avoid expensive GPU ambient/spot shadow pass on Android 9 TV Dialog panels.
        if (!modernTv) {
            UiCompat.setElevation(panel, a.dp(8));
        }
        panel.setClipChildren(false);
        panel.setClipToPadding(false);

        boolean showHeading =
                forceShowHeading
                        || !modernTv
                        || actionRowCount <= 1
                        || !safeMessage.isEmpty()
                        || !safeBanner.isEmpty()
                        || headerCount > 0;
        boolean showHint = a.isTvDevice() && (!modernTv || hasLongLabel);
        if (showHeading && title != null && !title.isEmpty()) {
            TextView heading = a.text(title, modernTv ? 14 : 18, MainActivity.WHITE);
            heading.setTag("player-bubble-title");
            if (modernTv) {
                heading.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 13.5f);
                heading.setPadding(
                        PlayerChrome.vp(a, 10),
                        PlayerChrome.vp(a, 3),
                        PlayerChrome.vp(a, 10),
                        PlayerChrome.vp(a, safeBanner.isEmpty() ? 7 : 4));
            } else {
                heading.setPadding(a.dp(10), 0, a.dp(10), a.dp(safeBanner.isEmpty() ? 10 : 6));
            }
            heading.setTypeface(null, Typeface.BOLD);
            panel.addView(heading);
        }

        if (!safeBanner.isEmpty()) {
            TextView bannerView = a.text(safeBanner, modernTv ? 12 : 13, 0xffe4ecfb);
            bannerView.setTag("player-bubble-status");
            bannerView.setFocusable(false);
            bannerView.setClickable(false);
            bannerView.setMaxLines(2);
            bannerView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            if (modernTv) {
                bannerView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.4f);
                bannerView.setPadding(
                        PlayerChrome.vp(a, 10),
                        PlayerChrome.vp(a, 6),
                        PlayerChrome.vp(a, 10),
                        PlayerChrome.vp(a, 6));
            } else {
                bannerView.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
            }
            android.graphics.drawable.GradientDrawable bannerBg =
                    new android.graphics.drawable.GradientDrawable();
            bannerBg.setColor(0x1effffff);
            bannerBg.setCornerRadius(modernTv ? u * 10f : a.dp(12));
            bannerView.setBackground(bannerBg);
            LinearLayout.LayoutParams bLp = new LinearLayout.LayoutParams(-1, -2);
            int bm = modernTv ? PlayerChrome.vp(a, 4) : a.dp(6);
            bLp.setMargins(bm, 0, bm, modernTv ? PlayerChrome.vp(a, 6) : a.dp(8));
            panel.addView(bannerView, bLp);
        }

        ScrollView scroll = new TvScrollView(a);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        LinearLayout items = a.vertical();
        items.setClipChildren(false);
        items.setClipToPadding(false);
        items.setPadding(
                modernTv ? PlayerChrome.vp(a, 2) : a.dp(6),
                modernTv ? PlayerChrome.vp(a, 1) : a.dp(4),
                modernTv ? PlayerChrome.vp(a, 2) : a.dp(6),
                modernTv ? PlayerChrome.vp(a, 1) : a.dp(4));
        scroll.addView(items);

        int[] origin = new int[2];
        if (anchor != null) {
            anchor.getLocationInWindow(origin);
        } else {
            origin[0] = a.root.getWidth() / 2;
            origin[1] = a.root.getHeight() - a.dp(90);
        }
        int anchorTop = origin[1];
        if (modernTv && a.playerChrome != null && a.playerChrome.dock != null) {
            int[] dockLoc = new int[2];
            a.playerChrome.dock.getLocationInWindow(dockLoc);
            if (dockLoc[1] > PlayerChrome.vp(a, 120)) {
                anchorTop = Math.min(origin[1], dockLoc[1]);
            }
        }
        int maxHeight;
        if (modernTv) {
            int overhead =
                    PlayerChrome.vp(a, 16)
                            + (showHeading ? PlayerChrome.vp(a, 30) : 0)
                            + (!safeBanner.isEmpty() ? PlayerChrome.vp(a, 44) : 0)
                            + (showHint ? PlayerChrome.vp(a, 24) : 0);
            int byAnchor = anchorTop - PlayerChrome.vp(a, 22) - overhead;
            int byScreen = (int) (a.root.getHeight() * .66f) - overhead;
            maxHeight =
                    Math.max(
                            PlayerChrome.vp(a, 76),
                            Math.min(PlayerChrome.vp(a, 344), Math.min(byScreen, byAnchor)));
        } else if (a.isTvDevice()) {
            maxHeight = Math.min(a.dp(256), Math.max(a.dp(100), origin[1] - a.dp(140)));
        } else {
            maxHeight = Math.min(a.dp(260), Math.max(a.dp(120), origin[1] - a.dp(88)));
        }
        FrameLayout viewport =
                new FrameLayout(a) {
                    @Override
                    protected void dispatchDraw(Canvas canvas) {
                        int save = canvas.save();
                        canvas.clipRect(0, 0, getWidth(), getHeight());
                        super.dispatchDraw(canvas);
                        canvas.restoreToCount(save);
                    }
                };
        viewport.setTag("scroll-viewport-clip");
        viewport.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        int rowStride = modernTv ? PlayerChrome.vp(a, 34) : a.dp(44);
        int headerStride = modernTv ? PlayerChrome.vp(a, 24) : a.dp(30);
        int desiredListHeight =
                actionRowCount * rowStride
                        + headerCount * headerStride
                        + (safeMessage.isEmpty() ? 0 : 6 * rowStride)
                        + (modernTv ? PlayerChrome.vp(a, 6) : a.dp(6));
        panel.addView(
                viewport,
                new LinearLayout.LayoutParams(-1, Math.min(desiredListHeight, maxHeight)));
        if (!safeMessage.isEmpty()) {
            TextView description = a.text(safeMessage, 13, 0xffdddddf);
            if (modernTv) {
                description.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.5f);
            }
            description.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(14));
            description.setLineSpacing(a.dp(4), 1);
            description.setFocusable(true);
            items.addView(description);
        }
        final String defaultHint = "上下选择 · 返回关闭";
        TextView hint = a.text(defaultHint, 11, MainActivity.MUTED);
        hint.setSingleLine(false);
        hint.setMaxLines(2);
        hint.setEllipsize(android.text.TextUtils.TruncateAt.END);
        boolean useModernRows = modernTv && actionRowCount > 1;
        int rowH = modernTv ? PlayerChrome.vp(a, 32) : a.dp(40);
        final int modernCornerDp =
                Math.max(
                        12,
                        Math.round((rowH * .5f) / a.getResources().getDisplayMetrics().density));
        final boolean[] pickedOption = {false};
        View firstFocusableView = null;
        View targetInitialFocusView = null;
        for (int i = 0; i < rows.size(); i++) {
            final Row r = rows.get(i);
            if (r.header) {
                TextView sectionHead = a.text(r.label, modernTv ? 11f : 12f, 0x99d6dff0);
                sectionHead.setTag("player-section-header:" + r.label);
                sectionHead.setFocusable(false);
                sectionHead.setClickable(false);
                sectionHead.setSingleLine(true);
                sectionHead.setEllipsize(android.text.TextUtils.TruncateAt.END);
                sectionHead.setTypeface(null, Typeface.BOLD);
                if (modernTv) {
                    sectionHead.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 10.4f);
                    sectionHead.setPadding(
                            PlayerChrome.vp(a, 10),
                            PlayerChrome.vp(a, i == 0 ? 3 : 7),
                            PlayerChrome.vp(a, 10),
                            PlayerChrome.vp(a, 3));
                } else {
                    sectionHead.setPadding(a.dp(12), a.dp(i == 0 ? 4 : 8), a.dp(12), a.dp(4));
                }
                items.addView(sectionHead, new LinearLayout.LayoutParams(-1, -2));
                continue;
            }
            final int index = r.actionIndex;
            String rawLabel = r.label;
            final boolean isChecked = r.checked || (useModernRows && rawLabel.startsWith("✓"));
            final String displayLabel =
                    useModernRows
                            ? rawLabel.replaceFirst("^✓\\s*", "")
                            : ((isChecked && !rawLabel.startsWith("✓") ? "✓  " : "") + rawLabel);
            Button item =
                    a.button(
                            displayLabel,
                            "player-option:" + index,
                            () -> {
                                pickedOption[0] = true;
                                dialog.dismiss();
                                action.accept(index);
                            });
            if (modernTv) {
                item.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 12.0f);
            } else {
                item.setTextSize(14f);
            }
            item.setSingleLine();
            item.setEllipsize(android.text.TextUtils.TruncateAt.END);
            item.setMinHeight(0);
            item.setMinimumHeight(0);
            final RowIconDrawable rowIcon =
                    useModernRows ? new RowIconDrawable(a, iconContext, isChecked) : null;
            final int padL = modernTv ? PlayerChrome.vp(a, 10) : a.dp(12);
            final int padR = modernTv ? PlayerChrome.vp(a, 12) : a.dp(12);
            if (useModernRows) {
                int iconSz = PlayerChrome.vp(a, 15);
                rowIcon.setBounds(0, 0, iconSz, iconSz);
                item.setCompoundDrawables(rowIcon, null, null, null);
                item.setCompoundDrawablePadding(PlayerChrome.vp(a, 8));
                item.setPadding(padL, 0, padR, 0);
                item.setGravity(Gravity.LEFT | Gravity.CENTER_VERTICAL);
                item.setTypeface(isChecked ? TV_MEDIUM_TYPEFACE : TV_REGULAR_TYPEFACE);
            } else {
                item.setPadding(padL, 0, padR, 0);
                item.setGravity(Gravity.CENTER);
            }
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                item.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_SIMPLE);
                item.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);
            }
            final int idleBg = isChecked ? (modernTv ? 0x20ffffff : 0x30ffffff) : 0x00ffffff;
            final int cornerDp = modernTv ? modernCornerDp : 16;
            final android.graphics.drawable.GradientDrawable itemBg = a.bg(idleBg, cornerDp);
            item.setBackground(itemBg);
            item.setOnFocusChangeListener(
                    (v, f) -> {
                        item.setSelected(f);
                        item.setEllipsize(
                                f
                                        ? android.text.TextUtils.TruncateAt.MARQUEE
                                        : android.text.TextUtils.TruncateAt.END);
                        if (showHint) {
                            if (f && displayLabel.length() > 14) {
                                hint.setText(displayLabel);
                                hint.setTextColor(0xffdddddf);
                            } else if (f) {
                                hint.setText(defaultHint);
                                hint.setTextColor(MainActivity.MUTED);
                            }
                        }
                        if (rowIcon != null) {
                            rowIcon.setFocusedState(f);
                        }
                        if (modernTv) {
                            itemBg.setColor(f ? MainActivity.WHITE : idleBg);
                            item.setTextColor(f ? 0xff14161b : MainActivity.WHITE);
                        } else {
                            FocusMotion.style(
                                    a,
                                    item,
                                    f,
                                    idleBg,
                                    MainActivity.WHITE,
                                    cornerDp,
                                    MainActivity.WHITE,
                                    MainActivity.DARK,
                                    false,
                                    1.015f);
                        }
                        if (useModernRows) {
                            item.setPadding(padL, 0, padR, 0);
                        }
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, rowH);
            int mH = modernTv ? PlayerChrome.vp(a, 1.5f) : a.dp(2);
            int mV = modernTv ? PlayerChrome.vp(a, 1f) : a.dp(2);
            lp.setMargins(mH, mV, mH, mV);
            items.addView(item, lp);
            if (firstFocusableView == null) firstFocusableView = item;
            if (index == initialFocusActionIndex) targetInitialFocusView = item;
        }
        if (showHint) {
            hint.setGravity(Gravity.CENTER);
            hint.setPadding(a.dp(8), a.dp(10), a.dp(8), 0);
            panel.addView(hint);
        }
        shell.addView(panel);
        int baseTvWidth = (hasLongLabel || headerCount > 0) ? 318 : 236;
        int maxBubbleW = Math.max(a.dp(200), a.root.getWidth() - a.dp(32));
        int width = Math.min(modernTv ? PlayerChrome.vp(a, baseTvWidth) : a.dp(320), maxBubbleW);
        int anchorWidth = anchor != null ? anchor.getWidth() : 0;
        int x =
                Math.max(
                        a.dp(16),
                        Math.min(
                                a.root.getWidth() - width - a.dp(16),
                                origin[0] + anchorWidth / 2 - width / 2));
        float tip = origin[0] + anchorWidth / 2f - x;
        if (!modernTv) {
            View arrow =
                    new View(a) {
                        final Paint p = new Paint(3);

                        protected void onDraw(Canvas c) {
                            p.setColor(0xfa29292e);
                            Path path = new Path();
                            path.moveTo(tip - a.dp(10), 0);
                            path.lineTo(tip + a.dp(10), 0);
                            path.lineTo(tip, a.dp(9));
                            path.close();
                            c.drawPath(path, p);
                        }
                    };
            shell.addView(arrow, new LinearLayout.LayoutParams(-1, a.dp(9)));
        }
        dialog.setContentView(shell);
        dialog.setOnDismissListener(
                d -> {
                    closed.run();
                    if (!pickedOption[0] && onCancelBack != null) {
                        onCancelBack.run();
                        return;
                    }
                    if (!pickedOption[0]
                            && a.isTvDevice()
                            && anchor != null
                            && UiCompat.isAttached(anchor)) {
                        anchor.requestFocus();
                    } else if (pickedOption[0]
                            && a.isTvDevice()
                            && anchor != null
                            && UiCompat.isAttached(anchor)
                            && (a.playbackControls == null || !a.playbackControls.dialogOpen)) {
                        anchor.requestFocus();
                    }
                });
        Window window = dialog.getWindow();
        if (window != null) {
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            window.setGravity(Gravity.TOP | Gravity.LEFT);
            if (a.isTvDevice()) {
                window.setWindowAnimations(0);
            }
            shell.measure(
                    View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(a.root.getHeight(), View.MeasureSpec.AT_MOST));
            int measuredH = Math.max(1, shell.getMeasuredHeight());
            window.setLayout(width, measuredH);
            WindowManager.LayoutParams attrs = window.getAttributes();
            attrs.x = x;
            attrs.y = Math.max(a.dp(16), anchorTop - measuredH - a.dp(modernTv ? 10 : 8));
            if (a.isTvDevice()) {
                // Use window flags directly instead of setSystemUiVisibility on the Dialog decor
                // view so opening the bubble never triggers a full system-bar insets relayout on
                // the underlying player Activity window.
                attrs.flags |=
                        WindowManager.LayoutParams.FLAG_FULLSCREEN
                                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;
            } else if (!a.isPortrait()) {
                window.getDecorView().setSystemUiVisibility(5894);
            }
            window.setAttributes(attrs);
        }
        final View focusTarget =
                targetInitialFocusView != null ? targetInitialFocusView : firstFocusableView;
        dialog.show();
        if (a.isTvDevice() && focusTarget != null) {
            focusTarget.requestFocus();
        }
        if (!a.reduced && !a.isTvDevice()) {
            shell.post(
                    () -> {
                        shell.setPivotX(tip);
                        shell.setPivotY(shell.getHeight());
                        shell.setScaleX(.85f);
                        shell.setScaleY(.75f);
                        shell.setAlpha(0);
                        shell.animate()
                                .scaleX(1)
                                .scaleY(1)
                                .alpha(1)
                                .setDuration(180)
                                .setInterpolator(
                                        new android.view.animation.DecelerateInterpolator())
                                .start();
                    });
        }
        return dialog;
    }

    private static final class RowIconDrawable extends android.graphics.drawable.Drawable {
        final MainActivity a;
        final String context;
        final boolean checked;
        boolean focused;
        final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        final RectF box = new RectF();
        final Path path = new Path();

        RowIconDrawable(MainActivity a, String context, boolean checked) {
            this.a = a;
            this.context = context == null ? "" : context;
            this.checked = checked;
        }

        void setFocusedState(boolean value) {
            if (focused != value) {
                focused = value;
                invalidateSelf();
            }
        }

        @Override
        public void draw(Canvas c) {
            Rect b = getBounds();
            if (b.isEmpty()) return;
            float cx = b.exactCenterX(), cy = b.exactCenterY();
            float w = b.width(), h = b.height();
            p.reset();
            p.setAntiAlias(true);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeJoin(Paint.Join.ROUND);

            if (checked) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(focused ? 0xff14161b : 0xf0ffffff);
                c.drawCircle(cx, cy, Math.min(w, h) * .46f, p);
                p.setStyle(Paint.Style.STROKE);
                p.setStrokeWidth(Math.max(1.5f, w * .105f));
                p.setColor(focused ? MainActivity.WHITE : 0xff16181f);
                path.reset();
                path.moveTo(cx - w * .19f, cy + h * .01f);
                path.lineTo(cx - w * .04f, cy + h * .16f);
                path.lineTo(cx + w * .21f, cy - h * .13f);
                c.drawPath(path, p);
                return;
            }

            int fg = focused ? 0xff14161b : 0xebeff3f9;
            int cut = focused ? MainActivity.WHITE : 0xff1b1e26;
            p.setColor(fg);
            float sw = Math.max(1.4f, w * .095f);

            switch (context) {
                case "danmaku":
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        box.set(cx - w * .38f, cy - h * .30f, cx + w * .38f, cy + h * .24f);
                        c.drawRoundRect(box, w * .14f, w * .14f, p);
                        c.drawLine(cx - w * .22f, cy - h * .09f, cx + w * .22f, cy - h * .09f, p);
                        c.drawLine(cx - w * .22f, cy + h * .07f, cx + w * .08f, cy + h * .07f, p);
                        break;
                    }
                case "tracks":
                case "subtitles":
                    {
                        float bw = w * .44f, bh = h * .34f;
                        box.set(cx - bw, cy - bh, cx + bw, cy + bh);
                        p.setStyle(Paint.Style.FILL);
                        c.drawRoundRect(box, w * .12f, w * .12f, p);
                        p.setStyle(Paint.Style.STROKE);
                        p.setColor(cut);
                        p.setStrokeWidth(Math.max(1.2f, w * .085f));
                        float y1 = cy + h * .04f, y2 = cy + h * .18f;
                        c.drawLine(cx - w * .28f, y1, cx + w * .28f, y1, p);
                        c.drawLine(cx - w * .28f, y2, cx + w * .08f, y2, p);
                        break;
                    }
                case "audio-tracks":
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        float dx = w * .22f;
                        c.drawLine(cx - dx, cy - h * .16f, cx - dx, cy + h * .16f, p);
                        c.drawLine(cx, cy - h * .32f, cx, cy + h * .32f, p);
                        c.drawLine(cx + dx, cy - h * .20f, cx + dx, cy + h * .20f, p);
                        break;
                    }
                case "lines":
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        float y1 = cy - h * .16f, y2 = cy + h * .16f;
                        c.drawLine(cx - w * .34f, y1, cx + w * .34f, y1, p);
                        c.drawLine(cx - w * .34f, y2, cx + w * .34f, y2, p);
                        p.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx - w * .12f, y1, w * .12f, p);
                        c.drawCircle(cx + w * .14f, y2, w * .12f, p);
                        break;
                    }
                case "speed":
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        float r = w * .36f;
                        box.set(cx - r, cy - r + h * .06f, cx + r, cy + r + h * .06f);
                        c.drawArc(box, 195f, 150f, false, p);
                        c.drawLine(cx, cy + h * .10f, cx + w * .18f, cy - h * .12f, p);
                        break;
                    }
                case "episodes":
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        c.drawLine(cx - w * .30f, cy - h * .20f, cx + w * .30f, cy - h * .20f, p);
                        c.drawLine(cx - w * .30f, cy, cx + w * .30f, cy, p);
                        c.drawLine(cx - w * .30f, cy + h * .20f, cx + w * .12f, cy + h * .20f, p);
                        break;
                    }
                case "skip-intro-tool":
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        path.reset();
                        path.moveTo(cx - w * .13f, cy - h * .28f);
                        path.lineTo(cx - w * .33f, cy - h * .28f);
                        path.lineTo(cx - w * .33f, cy + h * .28f);
                        path.lineTo(cx - w * .13f, cy + h * .28f);
                        c.drawPath(path, p);
                        c.drawLine(cx - w * .10f, cy, cx + w * .33f, cy, p);
                        path.reset();
                        path.moveTo(cx + w * .14f, cy - h * .18f);
                        path.lineTo(cx + w * .33f, cy);
                        path.lineTo(cx + w * .14f, cy + h * .18f);
                        c.drawPath(path, p);
                        break;
                    }
                case "skip-outro-tool":
                    {
                        p.setStyle(Paint.Style.STROKE);
                        p.setStrokeWidth(sw);
                        path.reset();
                        path.moveTo(cx + w * .13f, cy - h * .28f);
                        path.lineTo(cx + w * .33f, cy - h * .28f);
                        path.lineTo(cx + w * .33f, cy + h * .28f);
                        path.lineTo(cx + w * .13f, cy + h * .28f);
                        c.drawPath(path, p);
                        c.drawLine(cx + w * .10f, cy, cx - w * .33f, cy, p);
                        path.reset();
                        path.moveTo(cx - w * .14f, cy - h * .18f);
                        path.lineTo(cx - w * .33f, cy);
                        path.lineTo(cx - w * .14f, cy + h * .18f);
                        c.drawPath(path, p);
                        break;
                    }
                default:
                    {
                        p.setStyle(Paint.Style.FILL);
                        p.setColor(focused ? 0x9914161b : 0x66eef2f8);
                        c.drawCircle(cx, cy, w * .13f, p);
                        break;
                    }
            }
        }

        @Override
        public void setAlpha(int alpha) {}

        @Override
        public void setColorFilter(ColorFilter colorFilter) {}

        @Override
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }
}

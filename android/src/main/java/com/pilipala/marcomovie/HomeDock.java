package com.pilipala.marcomovie;

import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Home-only right/top rail. Content keeps its own scroll and return focus. */
final class HomeDock {
    final MainActivity a;
    final LinearLayout rail;
    final TextView hint;
    final View[] items = new View[6];
    final GlassSelection selection;
    final String[] labels = {"首页", "搜索", "直播", "收藏", "网盘", "设置"};
    final String[] keys = {
        "nav-home", "nav-search", "nav-live", "nav-favorites", "nav-accounts", "nav-settings"
    };

    final boolean bottomMode, topMode, horizontal;
    final float navScale;
    final int crossDp, mainDp, cellDp, hintHeightDp;

    HomeDock(MainActivity host) {
        a = host;
        bottomMode = a.useBottomDock();
        topMode = a.useTopDock();
        horizontal = bottomMode || topMode;
        navScale = Prefs.clampNavScale(a.prefs.getInt(Prefs.NAV_SCALE_PERCENT, 100)) / 100f;
        cellDp = Math.round((a.isTvDevice() ? 42 : 38) * navScale);
        crossDp = Math.round((a.isTvDevice() ? 56 : 50) * navScale);
        mainDp =
                Math.round(
                        (a.isTvDevice() ? (horizontal ? 324 : 320) : (horizontal ? 296 : 292))
                                * navScale);
        hintHeightDp = Math.round(28 * navScale);
        rail =
                new LinearLayout(a) {
                    @Override
                    protected void dispatchDraw(Canvas canvas) {
                        selection.draw(canvas);
                        super.dispatchDraw(canvas);
                    }

                    @Override
                    protected void onLayout(boolean changed, int l, int t, int r, int b) {
                        super.onLayout(changed, l, t, r, b);
                        selection.refresh();
                    }
                };
        rail.setOrientation(horizontal ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        selection = new GlassSelection(a, rail);
        rail.setTag("home-dock");
        rail.setGravity(Gravity.CENTER);
        rail.setClipChildren(false);
        rail.setClipToPadding(false);
        rail.setPadding(
                a.dp(Math.round((horizontal ? 10 : 6) * navScale)),
                a.dp(Math.round((horizontal ? 6 : 8) * navScale)),
                a.dp(Math.round((horizontal ? 10 : 6) * navScale)),
                a.dp(Math.round((horizontal ? 6 : 8) * navScale)));
        a.glass(rail, Math.round(25 * navScale));
        rail.setElevation(a.dp(8));
        FrameLayout.LayoutParams size =
                horizontal
                        ? new FrameLayout.LayoutParams(
                                a.dp(mainDp),
                                a.dp(crossDp),
                                (topMode ? Gravity.TOP : Gravity.BOTTOM)
                                        | Gravity.CENTER_HORIZONTAL)
                        : new FrameLayout.LayoutParams(
                                a.dp(crossDp),
                                a.dp(mainDp),
                                Gravity.RIGHT | Gravity.CENTER_VERTICAL);
        if (bottomMode) size.bottomMargin = a.dp(14);
        else if (topMode) size.topMargin = a.dp(16);
        else size.rightMargin = a.dp(20);
        a.root.addView(rail, size);
        if (topMode) {
            FrameLayout.LayoutParams viewport =
                    (FrameLayout.LayoutParams) a.scroll.getLayoutParams();
            viewport.topMargin = a.dp(crossDp + Math.max(34, hintHeightDp + 6));
            a.scroll.setLayoutParams(viewport);
        }
        hint = a.text("", 12f * navScale, MainActivity.WHITE);
        hint.setTag("home-dock-label");
        hint.setGravity(Gravity.CENTER);
        hint.setIncludeFontPadding(false);
        hint.setPadding(a.dp(Math.round(12 * navScale)), 0, a.dp(Math.round(16 * navScale)), 0);
        hint.setBackground(new LabelBubble());
        hint.setElevation(rail.getElevation() + a.dp(1));
        hint.setVisibility(View.INVISIBLE);
        FrameLayout.LayoutParams tip =
                new FrameLayout.LayoutParams(-2, a.dp(hintHeightDp), Gravity.RIGHT | Gravity.TOP);
        tip.rightMargin = a.dp(crossDp + 28);
        a.root.addView(hint, tip);
        Runnable[] actions = {
            () -> {
                if (a.scroll != null) a.smoothHomeScroll(0);
                View target = a.root.findViewWithTag("home-history:0");
                if (target == null) target = a.root.findViewWithTag("home-tab:0");
                if (target == null) target = a.root.findViewWithTag("primary");
                if (target != null) target.requestFocus();
            },
            a::globalSearchDialog,
            () -> a.open(new MainActivity.Screen(a::liveSources), true),
            () -> a.open(new MainActivity.Screen(() -> new FavoritesScreen(a).show()), true),
            () -> AccountPanel.show(a, items[4]),
            () -> a.open(new MainActivity.Screen(a::settings), true)
        };
        for (int i = 0; i < items.length; i++) {
            final int index = i;
            Icon icon = new Icon(i);
            items[i] = icon;
            icon.setTag(keys[i]);
            icon.setId(View.generateViewId());
            icon.setContentDescription(labels[i]);
            icon.setFocusable(true);
            icon.setFocusableInTouchMode(true);
            icon.setClickable(true);
            icon.setSelected(i == 0);
            a.pressFeedback(icon);
            int cellGap = a.dp(Math.max(3, Math.round(4 * navScale)));
            LinearLayout.LayoutParams cell =
                    new LinearLayout.LayoutParams(a.dp(cellDp), a.dp(cellDp));
            if (horizontal) {
                cell.leftMargin = cellGap;
                cell.rightMargin = cellGap;
            } else {
                cell.topMargin = cellGap;
                cell.bottomMargin = cellGap;
            }
            rail.addView(icon, cell);
            icon.setOnClickListener(v -> actions[index].run());
            icon.setOnFocusChangeListener(
                    (v, focused) -> {
                        icon.invalidate();
                        FocusMotion.style(
                                a,
                                icon,
                                false,
                                Color.TRANSPARENT,
                                Color.TRANSPARENT,
                                // Half of the cell or more: a true circle, not a squircle.
                                Math.max(24, (cellDp + 2) / 2),
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                false,
                                1f);
                        icon.setBackground(null);
                        if (focused) selection.select(icon);
                        if (focused && !bottomMode) showLabel(index);
                        else {
                            hint.animate().cancel();
                            hint.animate()
                                    .alpha(0)
                                    .setDuration(a.reduced ? 0 : 100)
                                    .withEndAction(
                                            () -> {
                                                if (!contains(a.getCurrentFocus()))
                                                    hint.setVisibility(View.INVISIBLE);
                                            })
                                    .start();
                        }
                    });
        }
        for (int i = 0; i < items.length; i++) {
            if (horizontal) {
                items[i].setNextFocusLeftId(items[Math.max(0, i - 1)].getId());
                items[i].setNextFocusRightId(items[Math.min(5, i + 1)].getId());
            } else {
                items[i].setNextFocusUpId(items[Math.max(0, i - 1)].getId());
                items[i].setNextFocusDownId(items[Math.min(5, i + 1)].getId());
                items[i].setNextFocusRightId(items[i].getId());
            }
        }
        a.root.getViewTreeObserver()
                .addOnGlobalFocusChangeListener(
                        (oldFocus, newFocus) -> {
                            if (contains(newFocus)
                                    && oldFocus != null
                                    && !contains(oldFocus)
                                    && oldFocus.getTag() instanceof String
                                    && a.current != null)
                                a.current.homeReturnFocus = (String) oldFocus.getTag();
                            if (newFocus != null
                                    && !contains(newFocus)
                                    && contains(oldFocus)
                                    && newFocus.getRootView() == a.root.getRootView())
                                selection.select(items[0]);
                        });
        selection.select(items[0]);
    }

    boolean contains(View view) {
        for (View item : items) if (item == view) return true;
        return false;
    }

    void showLabel(int index) {
        hint.animate().cancel();
        hint.setText(labels[index]);
        rail.post(
                () -> {
                    if (!items[index].hasFocus()) return;
                    FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) hint.getLayoutParams();
                    if (horizontal) {
                        hint.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
                        p.gravity = Gravity.LEFT | Gravity.TOP;
                        p.rightMargin = 0;
                        int center =
                                rail.getLeft()
                                        + items[index].getLeft()
                                        + items[index].getWidth() / 2;
                        p.leftMargin =
                                Math.max(
                                        a.dp(6),
                                        Math.min(
                                                center - hint.getMeasuredWidth() / 2,
                                                a.root.getWidth()
                                                        - hint.getMeasuredWidth()
                                                        - a.dp(6)));
                        p.topMargin =
                                topMode
                                        ? rail.getBottom() + a.dp(6)
                                        : Math.max(a.dp(4), rail.getTop() - a.dp(36));
                    } else
                        p.topMargin =
                                rail.getTop()
                                        + items[index].getTop()
                                        + (items[index].getHeight() - a.dp(hintHeightDp)) / 2;
                    hint.setLayoutParams(p);
                    hint.setAlpha(1);
                    hint.setTranslationX(0);
                    hint.setVisibility(View.VISIBLE);
                    if (!a.reduced) {
                        hint.setAlpha(0);
                        hint.setTranslationX(a.dp(4));
                        hint.animate().alpha(1).translationX(0).setDuration(140).start();
                    }
                });
    }

    void rightEdge(View view) {
        if (view != null && !horizontal) view.setNextFocusRightId(items[0].getId());
    }

    boolean key(KeyEvent event) {
        View focused = a.getCurrentFocus();
        if (!contains(focused)) return false;
        int key = event.getKeyCode();
        if (horizontal
                && (key == KeyEvent.KEYCODE_DPAD_LEFT || key == KeyEvent.KEYCODE_DPAD_RIGHT)) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                int index = 0;
                while (index < items.length - 1 && items[index] != focused) index++;
                items[
                        Math.max(
                                0,
                                Math.min(
                                        items.length - 1,
                                        index + (key == KeyEvent.KEYCODE_DPAD_LEFT ? -1 : 1)))]
                        .requestFocus();
            }
            return true;
        }
        int exit =
                topMode
                        ? KeyEvent.KEYCODE_DPAD_DOWN
                        : bottomMode ? KeyEvent.KEYCODE_DPAD_UP : KeyEvent.KEYCODE_DPAD_LEFT;
        if (key != exit)
            return horizontal
                    && (key == KeyEvent.KEYCODE_DPAD_UP || key == KeyEvent.KEYCODE_DPAD_DOWN);
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            View target =
                    a.current == null || a.current.homeReturnFocus == null
                            ? null
                            : a.root.findViewWithTag(a.current.homeReturnFocus);
            if (target == null || !target.isShown())
                target = a.root.findViewWithTag("source-switcher");
            if (target == null) target = a.root.findViewWithTag("primary");
            if (target != null) target.requestFocus();
        }
        return true;
    }

    final class LabelBubble extends android.graphics.drawable.Drawable {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

        @Override
        public void draw(Canvas c) {
            Rect b = getBounds();
            if (horizontal) {
                if (topMode) {
                    float edge = b.top + a.dp(4);
                    paint.setColor(0xff303036);
                    paint.setStyle(Paint.Style.FILL);
                    c.drawRoundRect(
                            new RectF(b.left, edge, b.right, b.bottom), a.dp(9), a.dp(9), paint);
                    Path point = new Path();
                    point.moveTo(b.exactCenterX() - a.dp(4), edge + a.dp(1));
                    point.lineTo(b.exactCenterX(), b.top);
                    point.lineTo(b.exactCenterX() + a.dp(4), edge + a.dp(1));
                    point.close();
                    c.drawPath(point, paint);
                    return;
                }
                float edge = b.bottom - a.dp(4);
                paint.setColor(0xff303036);
                paint.setStyle(Paint.Style.FILL);
                c.drawRoundRect(new RectF(b.left, b.top, b.right, edge), a.dp(9), a.dp(9), paint);
                Path point = new Path();
                point.moveTo(b.exactCenterX() - a.dp(4), edge - a.dp(1));
                point.lineTo(b.exactCenterX(), b.bottom);
                point.lineTo(b.exactCenterX() + a.dp(4), edge - a.dp(1));
                point.close();
                c.drawPath(point, paint);
                return;
            }
            float edge = b.right - a.dp(4), middle = b.exactCenterY();
            paint.setColor(0xff303036);
            paint.setStyle(Paint.Style.FILL);
            c.drawRoundRect(new RectF(b.left, b.top, edge, b.bottom), a.dp(9), a.dp(9), paint);
            Path tip = new Path();
            tip.moveTo(edge - a.dp(1), middle - a.dp(4));
            tip.lineTo(b.right, middle);
            tip.lineTo(edge - a.dp(1), middle + a.dp(4));
            tip.close();
            c.drawPath(tip, paint);
        }

        @Override
        public void setAlpha(int alpha) {
            paint.setAlpha(alpha);
        }

        @Override
        public void setColorFilter(ColorFilter filter) {
            paint.setColorFilter(filter);
        }

        @Override
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }

    final class Icon extends View {
        final int kind;
        final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path path = new Path();
        final RectF box = new RectF();

        Icon(int kind) {
            super(a);
            this.kind = kind;
        }

        float snap(float value, int strokePx) {
            return (strokePx & 1) == 0 ? Math.round(value) : (float) Math.floor(value) + 0.5f;
        }

        @Override
        protected void onDraw(Canvas c) {
            super.onDraw(c);
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float size = a.dp((a.isTvDevice() ? 25f : 22f) * navScale);
            float r = size * 0.5f;
            float cx = w * 0.5f + (!horizontal && isSelected() ? a.dp(1f) : 0f);
            float cy = h * 0.5f - (horizontal && isSelected() ? a.dp(1.2f) : 0f);
            int strokePx =
                    Math.max(2, Math.round(a.dp((a.isTvDevice() ? 2.0f : 1.75f) * navScale)));
            int fg = hasFocus() ? MainActivity.WHITE : 0xffedf2f8;
            p.reset();
            p.setAntiAlias(true);
            p.setColor(fg);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(strokePx);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeJoin(Paint.Join.ROUND);

            switch (kind) {
                case 0:
                    {
                        path.reset();
                        float roofY = snap(cy - r * 0.06f, strokePx);
                        float peakY = snap(cy - r * 0.84f, strokePx);
                        path.moveTo(cx - r * 0.88f, roofY);
                        path.lineTo(cx, peakY);
                        path.lineTo(cx + r * 0.88f, roofY);
                        c.drawPath(path, p);

                        path.reset();
                        float leftX = snap(cx - r * 0.58f, strokePx);
                        float rightX = snap(cx + r * 0.58f, strokePx);
                        float wallTop = snap(cy - r * 0.12f, strokePx);
                        float bottomY = snap(cy + r * 0.80f, strokePx);
                        float doorLeft = snap(cx - r * 0.18f, strokePx);
                        float doorRight = snap(cx + r * 0.18f, strokePx);
                        float doorTop = snap(cy + r * 0.26f, strokePx);
                        path.moveTo(leftX, wallTop);
                        path.lineTo(leftX, bottomY);
                        path.lineTo(doorLeft, bottomY);
                        path.lineTo(doorLeft, doorTop);
                        path.lineTo(doorRight, doorTop);
                        path.lineTo(doorRight, bottomY);
                        path.lineTo(rightX, bottomY);
                        path.lineTo(rightX, wallTop);
                        c.drawPath(path, p);
                        break;
                    }
                case 1:
                    {
                        float lx = cx - r * 0.14f;
                        float ly = cy - r * 0.14f;
                        float lensR = r * 0.55f;
                        c.drawCircle(lx, ly, lensR, p);
                        float start = lensR * 0.72f;
                        c.drawLine(lx + start, ly + start, cx + r * 0.80f, cy + r * 0.80f, p);
                        break;
                    }
                case 2:
                    {
                        float left = snap(cx - r * 0.84f, strokePx);
                        float top = snap(cy - r * 0.72f, strokePx);
                        float right = snap(cx + r * 0.84f, strokePx);
                        float bottom = snap(cy + r * 0.42f, strokePx);
                        box.set(left, top, right, bottom);
                        float corner = r * 0.22f;
                        c.drawRoundRect(box, corner, corner, p);
                        float stemX = snap(cx, strokePx);
                        float standY = snap(cy + r * 0.80f, strokePx);
                        c.drawLine(stemX, bottom, stemX, standY, p);
                        c.drawLine(
                                snap(cx - r * 0.42f, strokePx),
                                standY,
                                snap(cx + r * 0.42f, strokePx),
                                standY,
                                p);
                        p.setStyle(Paint.Style.FILL);
                        path.reset();
                        float midY = (top + bottom) * 0.5f;
                        path.moveTo(cx - r * 0.15f, midY - r * 0.25f);
                        path.lineTo(cx + r * 0.25f, midY);
                        path.lineTo(cx - r * 0.15f, midY + r * 0.25f);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 3:
                    {
                        path.reset();
                        float topDipY = cy - r * 0.36f;
                        float bottomTipY = cy + r * 0.78f;
                        float lobePeakY = cy - r * 0.84f;
                        float sideX = r * 0.86f;
                        float sideY = cy - r * 0.16f;
                        path.moveTo(cx, bottomTipY);
                        path.cubicTo(
                                cx - r * 0.38f,
                                cy + r * 0.48f,
                                cx - sideX,
                                cy + r * 0.18f,
                                cx - sideX,
                                sideY);
                        path.cubicTo(cx - sideX, lobePeakY, cx - r * 0.24f, lobePeakY, cx, topDipY);
                        path.cubicTo(
                                cx + r * 0.24f,
                                lobePeakY,
                                cx + sideX,
                                lobePeakY,
                                cx + sideX,
                                sideY);
                        path.cubicTo(
                                cx + sideX,
                                cy + r * 0.18f,
                                cx + r * 0.38f,
                                cy + r * 0.48f,
                                cx,
                                bottomTipY);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 4:
                    {
                        path.reset();
                        float baseY = snap(cy + r * 0.54f, strokePx);
                        float leftTop = snap(cy - r * 0.08f, strokePx);
                        float rightTop = snap(cy - r * 0.02f, strokePx);
                        path.moveTo(cx - r * 0.52f, baseY);
                        path.cubicTo(
                                cx - r * 0.94f,
                                baseY,
                                cx - r * 0.94f,
                                leftTop,
                                cx - r * 0.50f,
                                leftTop);
                        path.cubicTo(
                                cx - r * 0.44f,
                                cy - r * 0.78f,
                                cx + r * 0.36f,
                                cy - r * 0.82f,
                                cx + r * 0.52f,
                                rightTop);
                        path.cubicTo(
                                cx + r * 0.92f,
                                rightTop,
                                cx + r * 0.92f,
                                baseY,
                                cx + r * 0.52f,
                                baseY);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 5:
                    {
                        float xLeft = snap(cx - r * 0.82f, strokePx);
                        float xRight = snap(cx + r * 0.82f, strokePx);
                        float knobR = r * 0.20f;
                        float clearance = knobR + strokePx * 0.65f;
                        float[] rowsY = {
                            snap(cy - r * 0.58f, strokePx),
                            snap(cy, strokePx),
                            snap(cy + r * 0.58f, strokePx)
                        };
                        float[] knobsX = {cx - r * 0.24f, cx + r * 0.26f, cx - r * 0.24f};
                        for (int i = 0; i < 3; i++) {
                            float y = rowsY[i], kx = knobsX[i];
                            if (kx - clearance > xLeft) {
                                c.drawLine(xLeft, y, kx - clearance, y, p);
                            }
                            if (xRight > kx + clearance) {
                                c.drawLine(kx + clearance, y, xRight, y, p);
                            }
                            c.drawCircle(kx, y, knobR, p);
                        }
                        break;
                    }
            }
            if (isSelected()) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(MainActivity.WHITE);
                float dotRadius = Math.max(1.5f, a.dp(1.6f * navScale));
                if (horizontal) {
                    c.drawCircle(w * 0.5f, h - a.dp(3.5f * navScale), dotRadius, p);
                } else {
                    c.drawCircle(a.dp(3.5f * navScale), h * 0.5f, dotRadius, p);
                }
            }
        }

        @Override
        public CharSequence getAccessibilityClassName() {
            return Button.class.getName();
        }
    }
}

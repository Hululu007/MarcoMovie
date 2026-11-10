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
        final Path glyph = new Path();

        Icon(int kind) {
            super(a);
            this.kind = kind;
            switch (kind) {
                case 0:
                    line(2, 10, 12, 2, 22, 10);
                    line(5, 9, 5, 21, 10, 21, 10, 15, 14, 15, 14, 21, 19, 21, 19, 9);
                    break;
                case 1:
                    glyph.addCircle(10, 10, 7, Path.Direction.CW);
                    line(15.5f, 15.5f, 22, 22);
                    break;
                case 2:
                    glyph.addRoundRect(new RectF(2, 4, 22, 18), 3, 3, Path.Direction.CW);
                    line(9, 8, 16, 11, 9, 14, 9, 8);
                    line(12, 18, 12, 22);
                    line(8, 22, 16, 22);
                    break;
                case 3:
                    glyph.moveTo(12, 21);
                    glyph.cubicTo(8, 18, 2, 14, 2, 8);
                    glyph.cubicTo(2, 2, 9, 1, 12, 6);
                    glyph.cubicTo(15, 1, 22, 2, 22, 8);
                    glyph.cubicTo(22, 14, 16, 18, 12, 21);
                    glyph.close();
                    break;
                case 4:
                    glyph.moveTo(6, 19);
                    glyph.cubicTo(0, 19, 0, 11, 6, 11);
                    glyph.cubicTo(6, 3, 17, 2, 19, 11);
                    glyph.cubicTo(24, 11, 24, 19, 19, 19);
                    glyph.close();
                    line(8, 15, 16, 15);
                    break;
                case 5:
                    line(2, 5, 6, 5);
                    line(12, 5, 22, 5);
                    line(2, 12, 12, 12);
                    line(18, 12, 22, 12);
                    line(2, 19, 6, 19);
                    line(12, 19, 22, 19);
                    glyph.addCircle(9, 5, 3, Path.Direction.CW);
                    glyph.addCircle(15, 12, 3, Path.Direction.CW);
                    glyph.addCircle(9, 19, 3, Path.Direction.CW);
                    break;
            }
        }

        void line(float... xy) {
            glyph.moveTo(xy[0], xy[1]);
            for (int i = 2; i < xy.length; i += 2) glyph.lineTo(xy[i], xy[i + 1]);
        }

        @Override
        protected void onDraw(Canvas c) {
            super.onDraw(c);
            c.save();
            float size = a.dp((a.isTvDevice() ? 26f : 22f) * navScale);
            float scale = size / 24f;
            // Draw paths at display resolution with a constant, whole-pixel stroke.
            c.translate(
                    Math.round((getWidth() - size) / 2f), Math.round((getHeight() - size) / 2f));
            c.scale(scale, scale);
            p.setColor(hasFocus() ? MainActivity.WHITE : 0xffe0e6ef);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(Math.max(2, Math.round(size / 12f)) / scale);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeJoin(Paint.Join.ROUND);
            c.drawPath(glyph, p);
            c.restore();
            if (isSelected()) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(MainActivity.WHITE);
                c.drawCircle(a.dp(5), getHeight() / 2f, a.dp(1.5f), p);
            }
        }

        @Override
        public CharSequence getAccessibilityClassName() {
            return Button.class.getName();
        }
    }
}

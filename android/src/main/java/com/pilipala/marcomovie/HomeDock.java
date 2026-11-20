package com.pilipala.marcomovie;

import android.graphics.*;
import android.view.*;
import android.widget.*;

/** Home rail. TV uses a compact left rail; mobile retains its existing placement. */
final class HomeDock {
    final MainActivity a;
    final LinearLayout rail;
    final TextView hint;
    TextView brandText;
    View edgeShade;
    final View[] items;
    final GlassSelection selection;
    final String[] labels;
    final String[] keys;

    final boolean bottomMode, topMode, horizontal, tvLeft;
    final TvV17Navigation navigation = new TvV17Navigation();
    boolean expanded;
    final float navScale, fitScale;
    final int crossDp, mainDp, cellDp, hintHeightDp;

    HomeDock(MainActivity host) {
        a = host;
        tvLeft = a.useLeftDock();
        labels =
                tvLeft
                        ? new String[] {"首页", "搜索", "直播", "我的", "网盘", "投屏", "设置"}
                        : new String[] {"首页", "搜索", "直播", "收藏", "网盘", "投屏", "设置"};
        keys =
                new String[] {
                    "nav-home",
                    "nav-search",
                    "nav-live",
                    "nav-favorites",
                    "nav-accounts",
                    "nav-cast",
                    "nav-settings"
                };
        items = new View[labels.length];
        bottomMode = !tvLeft && a.useBottomDock();
        topMode = !tvLeft && a.useTopDock();
        horizontal = bottomMode || topMode;
        navScale = Prefs.clampNavScale(a.prefs.getInt(Prefs.NAV_SCALE_PERCENT, 100)) / 100f;
        int rawMainBase = a.isTvDevice() ? (horizontal ? 374 : 368) : (horizontal ? 342 : 338);
        float density = Math.max(0.5f, a.getResources().getDisplayMetrics().density);
        int windowMainDp =
                Math.max(
                        260,
                        Math.round((horizontal ? a.windowWidth() : a.windowHeight()) / density)
                                - 32);
        fitScale =
                tvLeft
                        ? TvRailMetrics.fit(
                                navScale,
                                Math.max(1, a.windowHeight() - a.dp(32)),
                                density,
                                items.length)
                        : Math.round(rawMainBase * navScale) > windowMainDp
                                ? Math.min(navScale, windowMainDp / (float) rawMainBase)
                                : navScale;
        cellDp = Math.round((a.isTvDevice() ? 42 : 38) * fitScale);
        crossDp = Math.round((a.isTvDevice() ? 56 : 50) * fitScale);
        mainDp = Math.round(rawMainBase * fitScale);
        hintHeightDp = Math.round(28 * fitScale);
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
        selection = new GlassSelection(a, rail, 10.5f * fitScale, true, tvLeft);
        rail.setTag("home-dock");
        rail.setGravity(Gravity.CENTER);
        rail.setClipChildren(false);
        rail.setClipToPadding(false);
        rail.setPadding(
                a.dp(Math.round((horizontal ? 10 : 6) * fitScale)),
                a.dp(Math.round((horizontal ? 6 : 8) * fitScale)),
                a.dp(Math.round((horizontal ? 10 : 6) * fitScale)),
                a.dp(Math.round((horizontal ? 6 : 8) * fitScale)));
        if (tvLeft) {
            TvV17Theme theme =
                    new TvV17Theme(
                            navScale,
                            1f,
                            a.reduced,
                            a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false));
            edgeShade = new View(a);
            edgeShade.setTag("home-navigation-edge");
            edgeShade.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            edgeShade.setBackground(TvV17Surface.navigationEdge(theme));
            a.root.addView(
                    edgeShade,
                    new FrameLayout.LayoutParams(
                            a.dp(crossDp + 42), -1, Gravity.LEFT | Gravity.TOP));
        } else a.glass(rail, Math.round(25 * fitScale));
        rail.setElevation(tvLeft ? 0 : a.dp(8));
        FrameLayout.LayoutParams size =
                horizontal
                        ? new FrameLayout.LayoutParams(
                                a.dp(mainDp),
                                a.dp(crossDp),
                                (topMode ? Gravity.TOP : Gravity.BOTTOM)
                                        | Gravity.CENTER_HORIZONTAL)
                        : new FrameLayout.LayoutParams(
                                a.dp(crossDp),
                                tvLeft ? a.windowHeight() - a.dp(32) : a.dp(mainDp),
                                tvLeft
                                        ? Gravity.LEFT | Gravity.TOP
                                        : Gravity.RIGHT | Gravity.CENTER_VERTICAL);
        if (bottomMode) size.bottomMargin = a.dp(14);
        else if (topMode) size.topMargin = a.dp(16);
        else if (tvLeft) {
            size.leftMargin = a.dp(12);
            size.topMargin = a.dp(16);
        } else size.rightMargin = a.dp(20);
        a.root.addView(rail, size);
        if (topMode) {
            FrameLayout.LayoutParams viewport =
                    (FrameLayout.LayoutParams) a.scroll.getLayoutParams();
            viewport.topMargin = a.dp(crossDp + Math.max(34, hintHeightDp + 6));
            a.scroll.setLayoutParams(viewport);
        }
        hint = a.text("", 12f * fitScale, MainActivity.WHITE);
        hint.setTag("home-dock-label");
        hint.setGravity(Gravity.CENTER);
        hint.setIncludeFontPadding(false);
        hint.setPadding(a.dp(Math.round(12 * fitScale)), 0, a.dp(Math.round(16 * fitScale)), 0);
        hint.setBackground(new LabelBubble());
        hint.setElevation(rail.getElevation() + a.dp(1));
        hint.setVisibility(View.INVISIBLE);
        FrameLayout.LayoutParams tip =
                new FrameLayout.LayoutParams(-2, a.dp(hintHeightDp), Gravity.RIGHT | Gravity.TOP);
        if (tvLeft) {
            tip.gravity = Gravity.LEFT | Gravity.TOP;
            tip.leftMargin = a.dp(crossDp + 20);
        } else tip.rightMargin = a.dp(crossDp + 28);
        a.root.addView(hint, tip);
        if (tvLeft) {
            addBrand();
            rail.addView(new View(a), new LinearLayout.LayoutParams(1, 0, 1));
        }
        Runnable homeAction =
                () -> {
                    if (a.scroll != null) a.smoothHomeScroll(0);
                    View target = a.root.findViewWithTag("home-history:0");
                    if (target == null) target = a.root.findViewWithTag("home-tab:0");
                    if (target == null) target = a.root.findViewWithTag("source-switcher");
                    if (target == null) target = a.root.findViewWithTag("primary");
                    if (target != null) target.requestFocus();
                };
        Runnable searchAction = a::globalSearchDialog;
        Runnable liveAction = () -> a.open(new MainActivity.Screen(a::liveSources), true);
        Runnable favoriteAction =
                () ->
                        a.open(
                                new MainActivity.Screen(
                                        tvLeft ? a::minePage : () -> new FavoritesScreen(a).show()),
                                true);
        Runnable accountAction = () -> AccountPanel.show(a, items[4]);
        Runnable castAction = () -> a.open(new MainActivity.Screen(a::castScreen), true);
        Runnable settingsAction = () -> a.open(new MainActivity.Screen(a::settings), true);
        Runnable[] actions =
                new Runnable[] {
                    homeAction,
                    searchAction,
                    liveAction,
                    favoriteAction,
                    accountAction,
                    castAction,
                    settingsAction
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
            int cellGap = a.dp(Math.max(3, Math.round(4 * fitScale)));
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
                                focused,
                                Color.TRANSPARENT,
                                Color.TRANSPARENT,
                                Math.max(8, Math.round(10.5f * fitScale)),
                                MainActivity.WHITE,
                                MainActivity.WHITE,
                                false,
                                1.04f);
                        icon.setBackground(null);
                        if (focused) selection.select(icon);
                        if (focused && !bottomMode && !tvLeft) showLabel(index);
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
        if (tvLeft) rail.addView(new View(a), new LinearLayout.LayoutParams(1, 0, 1));
        for (int i = 0; i < items.length; i++) {
            if (horizontal) {
                items[i].setNextFocusLeftId(items[Math.max(0, i - 1)].getId());
                items[i].setNextFocusRightId(items[Math.min(items.length - 1, i + 1)].getId());
            } else {
                items[i].setNextFocusUpId(items[Math.max(0, i - 1)].getId());
                items[i].setNextFocusDownId(items[Math.min(items.length - 1, i + 1)].getId());
                if (tvLeft) items[i].setNextFocusLeftId(items[i].getId());
                else items[i].setNextFocusRightId(items[i].getId());
            }
        }
        a.root.getViewTreeObserver()
                .addOnGlobalFocusChangeListener(
                        (oldFocus, newFocus) -> {
                            if (contains(newFocus)
                                    && oldFocus != null
                                    && !contains(oldFocus)
                                    && oldFocus.getTag() instanceof String
                                    && a.current != null) {
                                a.current.homeReturnFocus = (String) oldFocus.getTag();
                                navigation.remember(oldFocus);
                            }
                            if (tvLeft && contains(oldFocus) != contains(newFocus))
                                setExpanded(contains(newFocus));
                            if (newFocus != null
                                    && !contains(newFocus)
                                    && contains(oldFocus)
                                    && newFocus.getRootView() == a.root.getRootView())
                                selection.select(items[0]);
                        });
        selection.select(items[0]);
    }

    void selectSection(boolean library) {
        if (!tvLeft) return;
        items[0].setSelected(true);
        items[0].invalidate();
        if (!contains(a.getCurrentFocus())) selection.select(items[0]);
    }

    void setExpanded(boolean value) {
        if (!tvLeft || expanded == value) return;
        expanded = value;
        FrameLayout.LayoutParams railSize = (FrameLayout.LayoutParams) rail.getLayoutParams();
        railSize.width = a.dp(value ? Math.round(164 * fitScale) : crossDp);
        rail.setLayoutParams(railSize);
        TvV17Theme theme =
                new TvV17Theme(
                        navScale,
                        1f,
                        a.reduced,
                        a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false));
        // Both states grow from the screen edge. Only the selected row is a rounded lens.
        rail.setBackground(null);
        rail.setElevation(0);
        if (edgeShade != null) {
            FrameLayout.LayoutParams edgeSize =
                    (FrameLayout.LayoutParams) edgeShade.getLayoutParams();
            edgeSize.width = railSize.width + a.dp(value ? 96 : 42);
            edgeShade.setLayoutParams(edgeSize);
            edgeShade.setBackground(TvV17Surface.navigationEdge(theme, value));
        }
        if (brandText != null) brandText.setVisibility(value ? View.VISIBLE : View.INVISIBLE);
        for (View item : items) {
            LinearLayout.LayoutParams cell = (LinearLayout.LayoutParams) item.getLayoutParams();
            // The focus plate spans the available row; only the rail's edge inset remains.
            cell.width = value ? ViewGroup.LayoutParams.MATCH_PARENT : a.dp(cellDp);
            item.setLayoutParams(cell);
            item.invalidate();
        }
        rail.post(() -> selection.refresh());
    }

    private void addBrand() {
        FrameLayout brand = new FrameLayout(a);
        brand.setTag("home-brand");
        brand.setFocusable(false);
        brand.setClickable(false);
        brand.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        brand.setContentDescription("Marco Movie");
        LinearLayout.LayoutParams header =
                new LinearLayout.LayoutParams(-1, a.dp(Math.round(44 * fitScale)));
        header.bottomMargin = a.dp(Math.round(8 * fitScale));
        rail.addView(brand, header);
        ImageView mark = new ImageView(a);
        mark.setTag("home-brand-mark");
        mark.setImageResource(R.drawable.logo_mark);
        mark.setScaleType(ImageView.ScaleType.FIT_CENTER);
        int side = a.dp(32 * fitScale);
        FrameLayout.LayoutParams icon =
                new FrameLayout.LayoutParams(side, side, Gravity.LEFT | Gravity.CENTER_VERTICAL);
        // The header fills the rail. Its left edge/padding never changes when expanded.
        icon.leftMargin = (a.dp(crossDp) - side) / 2 - rail.getPaddingLeft();
        brand.addView(mark, icon);
        brandText = a.text("MARCO MOVIE", 14 * fitScale, MainActivity.WHITE);
        brandText.setTag("home-brand-word");
        brandText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, a.dp(14 * fitScale));
        brandText.setTypeface(null, Typeface.BOLD);
        brandText.setIncludeFontPadding(false);
        brandText.setSingleLine(true);
        brandText.setGravity(Gravity.CENTER_VERTICAL);
        brandText.setVisibility(View.INVISIBLE);
        FrameLayout.LayoutParams label = new FrameLayout.LayoutParams(-1, -1);
        label.leftMargin = a.dp(48 * fitScale) - rail.getPaddingLeft();
        brand.addView(brandText, label);
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
        if (view != null && !horizontal && !tvLeft) view.setNextFocusRightId(items[0].getId());
    }

    void leftEdge(View view, boolean library) {
        if (view != null && tvLeft) view.setNextFocusLeftId(items[0].getId());
    }

    boolean key(KeyEvent event) {
        View focused = a.getCurrentFocus();
        if (!contains(focused)) return false;
        int key = event.getKeyCode();
        if (tvLeft && key == KeyEvent.KEYCODE_BACK) {
            if (event.getAction() == KeyEvent.ACTION_UP && !event.isCanceled()) returnToContent();
            return true;
        }
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
                        : bottomMode
                                ? KeyEvent.KEYCODE_DPAD_UP
                                : tvLeft ? KeyEvent.KEYCODE_DPAD_RIGHT : KeyEvent.KEYCODE_DPAD_LEFT;
        if (key != exit)
            return horizontal
                    && (key == KeyEvent.KEYCODE_DPAD_UP || key == KeyEvent.KEYCODE_DPAD_DOWN);
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            returnToContent();
        }
        return true;
    }

    void returnToContent() {
        View target =
                a.current == null || a.current.homeReturnFocus == null
                        ? null
                        : a.root.findViewWithTag(a.current.homeReturnFocus);
        if (target == null
                || !target.isAttachedToWindow()
                || !target.isShown()
                || !target.isFocusable()
                || !target.isEnabled()) {
            View fallback = a.root.findViewWithTag("home-history:0");
            if (fallback == null || !fallback.isShown())
                fallback = a.root.findViewWithTag("home-tab:0");
            if (fallback == null || !fallback.isShown())
                fallback = a.root.findViewWithTag("source-switcher");
            target = navigation.restore(a.root, fallback);
        }
        if (target == null) target = a.root.findViewWithTag("primary");
        if (target != null && target.isShown() && target.isFocusable()) target.requestFocus();
    }

    final class LabelBubble extends android.graphics.drawable.Drawable {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final RectF box = new RectF();
        final Path tip = new Path();

        @Override
        public void draw(Canvas c) {
            Rect b = getBounds();
            if (horizontal) {
                if (topMode) {
                    float edge = b.top + a.dp(4);
                    box.set(b.left, edge, b.right, b.bottom);
                    float corner = Math.min(box.width(), box.height()) * .5f;
                    paint.setColor(0xe8252830);
                    paint.setStyle(Paint.Style.FILL);
                    c.drawRoundRect(box, corner, corner, paint);
                    tip.reset();
                    tip.moveTo(b.exactCenterX() - a.dp(4), edge + a.dp(1));
                    tip.lineTo(b.exactCenterX(), b.top);
                    tip.lineTo(b.exactCenterX() + a.dp(4), edge + a.dp(1));
                    tip.close();
                    c.drawPath(tip, paint);
                    return;
                }
                float edge = b.bottom - a.dp(4);
                box.set(b.left, b.top, b.right, edge);
                float corner = Math.min(box.width(), box.height()) * .5f;
                paint.setColor(0xe8252830);
                paint.setStyle(Paint.Style.FILL);
                c.drawRoundRect(box, corner, corner, paint);
                tip.reset();
                tip.moveTo(b.exactCenterX() - a.dp(4), edge - a.dp(1));
                tip.lineTo(b.exactCenterX(), b.bottom);
                tip.lineTo(b.exactCenterX() + a.dp(4), edge - a.dp(1));
                tip.close();
                c.drawPath(tip, paint);
                return;
            }
            float edge = b.right - a.dp(4), middle = b.exactCenterY();
            box.set(b.left, b.top, edge, b.bottom);
            float corner = Math.min(box.width(), box.height()) * .5f;
            paint.setColor(0xe8252830);
            paint.setStyle(Paint.Style.FILL);
            c.drawRoundRect(box, corner, corner, paint);
            tip.reset();
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
            float size = a.dp((a.isTvDevice() ? 25f : 22f) * fitScale);
            float r = size * 0.5f;
            float cx =
                    tvLeft && expanded
                            ? a.dp(cellDp / 2f)
                            : w * 0.5f + (!horizontal && isSelected() ? a.dp(1f) : 0f);
            float cy = h * 0.5f - (horizontal && isSelected() ? a.dp(1.2f) : 0f);
            int strokePx =
                    Math.max(2, Math.round(a.dp((a.isTvDevice() ? 2.0f : 1.75f) * fitScale)));
            int fg = hasFocus() ? MainActivity.WHITE : 0xffedf2f8;
            p.reset();
            p.setAntiAlias(true);
            p.setColor(fg);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(strokePx);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeJoin(Paint.Join.ROUND);

            int drawingKind = kind;
            switch (drawingKind) {
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
                        float left = snap(cx - r * 0.84f, strokePx);
                        float top = snap(cy - r * 0.68f, strokePx);
                        float right = snap(cx + r * 0.84f, strokePx);
                        float bottom = snap(cy + r * 0.68f, strokePx);
                        float cr = r * 0.22f;
                        path.reset();
                        path.moveTo(left, cy - r * 0.14f);
                        path.lineTo(left, top + cr);
                        box.set(left, top, left + cr * 2f, top + cr * 2f);
                        path.arcTo(box, 180f, 90f, false);
                        path.lineTo(right - cr, top);
                        box.set(right - cr * 2f, top, right, top + cr * 2f);
                        path.arcTo(box, 270f, 90f, false);
                        path.lineTo(right, bottom - cr);
                        box.set(right - cr * 2f, bottom - cr * 2f, right, bottom);
                        path.arcTo(box, 0f, 90f, false);
                        path.lineTo(cx + r * 0.08f, bottom);
                        c.drawPath(path, p);

                        float r1 = r * 0.42f;
                        box.set(left - r1, bottom - r1, left + r1, bottom + r1);
                        c.drawArc(box, 270f, 90f, false, p);
                        float r2 = r * 0.78f;
                        box.set(left - r2, bottom - r2, left + r2, bottom + r2);
                        c.drawArc(box, 270f, 90f, false, p);

                        p.setStyle(Paint.Style.FILL);
                        c.drawCircle(
                                left + r * 0.05f,
                                bottom - r * 0.05f,
                                Math.max(1.5f, strokePx * 0.75f),
                                p);
                        break;
                    }
                case 7:
                    {
                        box.set(cx - r * .78f, cy - r * .72f, cx + r * .68f, cy + r * .8f);
                        c.drawRoundRect(box, r * .16f, r * .16f, p);
                        path.reset();
                        path.moveTo(cx - r * .18f, cy - r * .35f);
                        path.lineTo(cx + r * .38f, cy);
                        path.lineTo(cx - r * .18f, cy + r * .35f);
                        path.close();
                        c.drawPath(path, p);
                        break;
                    }
                case 6:
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
            if (tvLeft && expanded) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(hasFocus() ? MainActivity.WHITE : 0xffc5ced8);
                p.setTextSize(a.dp(15f * fitScale));
                p.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.NORMAL));
                c.drawText(
                        labels[kind], a.dp(48 * fitScale), cy - (p.ascent() + p.descent()) / 2, p);
            }
            if (isSelected()) {
                p.setStyle(Paint.Style.FILL);
                p.setColor(MainActivity.WHITE);
                float dotRadius = Math.max(1.5f, a.dp(1.6f * fitScale));
                if (horizontal) {
                    c.drawCircle(w * 0.5f, h - a.dp(3.5f * fitScale), dotRadius, p);
                } else {
                    c.drawCircle(a.dp(3.5f * fitScale), h * 0.5f, dotRadius, p);
                }
            }
        }

        @Override
        public CharSequence getAccessibilityClassName() {
            return Button.class.getName();
        }
    }
}

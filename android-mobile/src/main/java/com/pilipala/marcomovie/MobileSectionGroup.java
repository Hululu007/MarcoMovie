package com.pilipala.marcomovie;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.Editable;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Arrays;
import java.util.List;

/**
 * Clean Inset Grouped Section UI kit (iOS / BieCuiLe style) for Android Mobile settings & pages.
 *
 * <p>Uses borderless {@code 16dp} cards ({@link MobileTheme.Palette#bgCard}), {@code 0.5dp}
 * left-inset hairlines ({@link MobileTheme.Palette#hairline}), {@code 28dp} softly tinted rounded
 * icon badges, spring-animated sliding segmented controls, and pure {@link MobileIcons} vector
 * glyphs.
 */
final class MobileSectionGroup {
    private MobileSectionGroup() {}

    static LinearLayout create(
            MainActivity a, String headerTitle, String footerText, View... rows) {
        return create(a, headerTitle, footerText, rows == null ? null : Arrays.asList(rows));
    }

    static LinearLayout create(
            MainActivity a, String headerTitle, String footerText, List<View> rows) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout outer = a.vertical();

        if (headerTitle != null && !headerTitle.trim().isEmpty()) {
            TextView header = a.text(headerTitle.trim(), 12.5f, p.textSecondary);
            header.setTypeface(null, Typeface.BOLD);
            header.setLetterSpacing(0.03f);
            header.setPadding(a.dp(16), 0, a.dp(16), a.dp(8));
            outer.addView(header, new LinearLayout.LayoutParams(-1, -2));
        }

        LinearLayout card = a.vertical();
        card.setBackground(MobileTheme.cardBg(a, 16));
        if (Build.VERSION.SDK_INT >= 21) {
            card.setOutlineProvider(ViewOutlineProvider.BACKGROUND);
            UiCompat.setClipToOutline(card, true);
        }

        if (rows != null) {
            int hairlinePx = MobileTheme.hairlinePx(a);
            int insetPx = a.dp(52);
            boolean addedAny = false;
            for (View row : rows) {
                if (row == null) continue;
                if (addedAny) {
                    View divider = new View(a);
                    divider.setBackgroundColor(p.hairline);
                    LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(-1, hairlinePx);
                    dlp.leftMargin = insetPx;
                    card.addView(divider, dlp);
                }
                if (row.getParent() instanceof ViewGroup) {
                    ((ViewGroup) row.getParent()).removeView(row);
                }
                card.addView(row, new LinearLayout.LayoutParams(-1, -2));
                addedAny = true;
            }
        }

        outer.addView(card, new LinearLayout.LayoutParams(-1, -2));

        if (footerText != null && !footerText.trim().isEmpty()) {
            TextView footer = a.text(footerText.trim(), 12f, p.textSecondary);
            footer.setLineSpacing(a.dp(2.5f), 1f);
            footer.setPadding(a.dp(16), a.dp(8), a.dp(16), 0);
            outer.addView(footer, new LinearLayout.LayoutParams(-1, -2));
        }
        return outer;
    }

    static LinearLayout navRow(
            MainActivity a,
            int icon,
            int badgeTintColor,
            String title,
            String valueText,
            Runnable onClick) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout row = buildBaseRow(a, p, icon, badgeTintColor, title, p.textPrimary);

        if (valueText != null && !valueText.isEmpty()) {
            TextView val = a.text(valueText, 13.5f, p.textSecondary);
            val.setSingleLine(true);
            val.setEllipsize(TextUtils.TruncateAt.END);
            val.setMaxWidth(a.dp(160));
            val.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams vlp = new LinearLayout.LayoutParams(-2, -2);
            vlp.leftMargin = a.dp(10);
            vlp.rightMargin = a.dp(6);
            row.addView(val, vlp);
        }

        MobileIcons.IconView chevron =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 14f, p.textTertiary);
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
        if (valueText == null || valueText.isEmpty()) {
            clp.leftMargin = a.dp(8);
        }
        row.addView(chevron, clp);

        bindPressHighlight(row, p.bgPressed);
        if (onClick != null) {
            row.setOnClickListener(v -> onClick.run());
        }
        return row;
    }

    static LinearLayout toggleRow(
            MainActivity a,
            int icon,
            int badgeTintColor,
            String title,
            boolean checked,
            UiWidgets.BooleanAction onToggle) {
        MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout row = buildBaseRow(a, p, icon, badgeTintColor, title, p.textPrimary);

        final UiWidgets.IosSwitchView sw = new UiWidgets.IosSwitchView(a, checked);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(a.dp(48), a.dp(28));
        slp.leftMargin = a.dp(10);
        row.addView(sw, slp);

        bindPressHighlight(row, p.bgPressed);
        row.setOnClickListener(
                v -> {
                    boolean next = !sw.isChecked();
                    sw.setChecked(next, !MobileMotion.isReduced(a));
                    if (onToggle != null) onToggle.onToggle(next);
                });
        return row;
    }

    static LinearLayout actionRow(
            MainActivity a,
            int icon,
            int badgeTintColor,
            String title,
            String valueText,
            int titleColor,
            Runnable onClick) {
        MobileTheme.Palette p = MobileTheme.of(a);
        int effectiveTitleColor = titleColor != 0 ? titleColor : p.textPrimary;
        LinearLayout row = buildBaseRow(a, p, icon, badgeTintColor, title, effectiveTitleColor);

        if (valueText != null && !valueText.isEmpty()) {
            TextView val = a.text(valueText, 13.5f, p.textSecondary);
            val.setSingleLine(true);
            val.setEllipsize(TextUtils.TruncateAt.END);
            val.setMaxWidth(a.dp(168));
            val.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams vlp = new LinearLayout.LayoutParams(-2, -2);
            vlp.leftMargin = a.dp(10);
            row.addView(val, vlp);
        }

        bindPressHighlight(row, p.bgPressed);
        if (onClick != null) {
            row.setOnClickListener(v -> onClick.run());
        }
        return row;
    }

    /**
     * Spring-animated sliding pill segmented control ({@code bgSubtle} track + continuous sliding
     * {@code bgCard} thumb driven by {@link MotionSpring} with horizontal touch-drag scrubbing).
     */
    static LinearLayout segmentedControl(
            MainActivity a, String[] labels, int selectedIndex, PlayerBubble.IntAction onSelect) {
        return segmentedControl(a, labels, null, selectedIndex, onSelect);
    }

    static LinearLayout segmentedControl(
            MainActivity a,
            String[] labels,
            String[] cellTags,
            int selectedIndex,
            PlayerBubble.IntAction onSelect) {
        LinearLayout wrapper = a.row();
        wrapper.setGravity(Gravity.CENTER_VERTICAL);
        SegmentedTrackView track =
                new SegmentedTrackView(a, labels, cellTags, selectedIndex, onSelect);
        wrapper.addView(track, new LinearLayout.LayoutParams(-1, a.dp(40)));
        return wrapper;
    }

    /** Retrieves the individual segment label view inside a control returned by {@link #segmentedControl}. */
    static View getSegmentCell(View segmented, int index) {
        SegmentedTrackView track = findSegmentedTrack(segmented);
        if (track != null) {
            return track.cellAt(index);
        }
        if (segmented instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) segmented;
            if (index >= 0 && index < vg.getChildCount()) {
                return vg.getChildAt(index);
            }
        }
        return null;
    }

    private static SegmentedTrackView findSegmentedTrack(View root) {
        if (root instanceof SegmentedTrackView) return (SegmentedTrackView) root;
        if (root instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) root;
            for (int i = 0; i < vg.getChildCount(); i++) {
                View child = vg.getChildAt(i);
                if (child instanceof SegmentedTrackView) return (SegmentedTrackView) child;
            }
        }
        return null;
    }

    /** Continuous sliding-thumb segmented track with spring settle and horizontal scrub support. */
    static final class SegmentedTrackView extends FrameLayout {
        private final MainActivity a;
        private final MobileTheme.Palette p;
        private final int count;
        private final TextView[] cells;
        private final PlayerBubble.IntAction onSelect;
        private final Paint thumbPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint shadowPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF thumbRect = new RectF();
        private final float thumbRadiusPx;
        private final int padPx;
        private final int touchSlop;
        private final MotionSpring thumbSpring;
        private MotionLoop.Step springStep;

        private int selectedIndex;
        private float thumbPos;
        private boolean scrubbing;
        private float downX;
        private float downY;

        SegmentedTrackView(
                MainActivity a,
                String[] labels,
                String[] cellTags,
                int initialIndex,
                PlayerBubble.IntAction onSelect) {
            super(a);
            this.a = a;
            this.p = MobileTheme.of(a);
            this.count = labels == null ? 0 : labels.length;
            this.cells = new TextView[this.count];
            this.onSelect = onSelect;
            this.selectedIndex =
                    this.count == 0 ? 0 : Math.max(0, Math.min(this.count - 1, initialIndex));
            this.thumbPos = this.selectedIndex;
            this.padPx = a.dp(3);
            this.thumbRadiusPx = a.dp(9.5f);
            this.touchSlop = ViewConfiguration.get(a).getScaledTouchSlop();
            this.thumbSpring =
                    new MotionSpring(
                            this.thumbPos,
                            MotionTokens.SPRING_HUD_POPUP.motionSpringFrequency,
                            0.004f);

            setWillNotDraw(false);
            setBackground(MobileTheme.subtleBg(a, 12));
            setPadding(padPx, padPx, padPx, padPx);
            setMinimumHeight(a.dp(40));

            thumbPaint.setStyle(Paint.Style.FILL);
            thumbPaint.setColor(p.bgCard);
            shadowPaint.setStyle(Paint.Style.FILL);
            shadowPaint.setColor(p.isDark ? 0x26000000 : 0x16000000);

            LinearLayout row = a.row();
            row.setGravity(Gravity.CENTER_VERTICAL);
            for (int i = 0; i < count; i++) {
                final int idx = i;
                TextView cell = a.text(labels[i], 13.5f, p.textSecondary);
                cell.setGravity(Gravity.CENTER);
                cell.setSingleLine(true);
                cell.setEllipsize(TextUtils.TruncateAt.END);
                cell.setPadding(a.dp(6), a.dp(7), a.dp(6), a.dp(7));
                cell.setClickable(true);
                cell.setFocusable(false);
                if (cellTags != null && i < cellTags.length && cellTags[i] != null) {
                    cell.setTag(cellTags[i]);
                }
                cell.setOnClickListener(v -> selectIndex(idx, true));
                cells[i] = cell;
                row.addView(cell, new LinearLayout.LayoutParams(0, -1, 1f));
            }
            addView(row, new FrameLayout.LayoutParams(-1, -1));
            updateLabelStyles(selectedIndex, false);
        }

        View cellAt(int index) {
            return (index >= 0 && index < count) ? cells[index] : null;
        }

        void selectIndex(int next, boolean notify) {
            if (count <= 0) return;
            int clamped = Math.max(0, Math.min(count - 1, next));
            boolean changed = clamped != selectedIndex;
            selectedIndex = clamped;
            animateThumbTo(clamped);
            updateLabelStyles(clamped, changed && MobileMotion.isReduced(a));
            if (changed && notify && onSelect != null) {
                onSelect.accept(clamped);
            }
        }

        private void animateThumbTo(float targetPos) {
            stopSpring();
            if (MobileMotion.isReduced(a)) {
                thumbPos = targetPos;
                thumbSpring.snap(targetPos);
                invalidate();
                return;
            }
            thumbSpring.value = thumbPos;
            thumbSpring.target(targetPos);
            springStep =
                    dt -> {
                        if (!UiCompat.isAttached(this)) {
                            springStep = null;
                            return false;
                        }
                        boolean moving = thumbSpring.step(dt);
                        thumbPos = thumbSpring.value;
                        invalidate();
                        if (!moving) {
                            thumbPos = targetPos;
                            springStep = null;
                            invalidate();
                        }
                        return moving;
                    };
            MotionLoop.add(springStep);
        }

        private void stopSpring() {
            if (springStep != null) {
                MotionLoop.remove(springStep);
                springStep = null;
            }
        }

        private void updateLabelStyles(int activeIdx, boolean fadeInReduced) {
            for (int i = 0; i < count; i++) {
                boolean active = i == activeIdx;
                TextView cell = cells[i];
                cell.setTextColor(active ? p.textPrimary : p.textSecondary);
                cell.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
                if (fadeInReduced && active) {
                    cell.animate().cancel();
                    cell.setAlpha(0.55f);
                    cell.animate()
                            .alpha(1f)
                            .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                            .setInterpolator(MotionTokens.createLinearInterpolator())
                            .start();
                }
            }
        }

        @Override
        public boolean onInterceptTouchEvent(MotionEvent ev) {
            if (count <= 1) return false;
            int action = ev.getActionMasked();
            if (action == MotionEvent.ACTION_DOWN) {
                downX = ev.getX();
                downY = ev.getY();
                scrubbing = false;
            } else if (action == MotionEvent.ACTION_MOVE) {
                float dx = Math.abs(ev.getX() - downX);
                float dy = Math.abs(ev.getY() - downY);
                if (dx > touchSlop && dx > dy * 1.2f) {
                    scrubbing = true;
                    stopSpring();
                    if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(true);
                    return true;
                }
            } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                scrubbing = false;
            }
            return false;
        }

        @Override
        public boolean onTouchEvent(MotionEvent ev) {
            if (count <= 1) return super.onTouchEvent(ev);
            int action = ev.getActionMasked();
            float innerW = Math.max(1f, getWidth() - padPx * 2f);
            float cellW = innerW / count;
            if (action == MotionEvent.ACTION_MOVE) {
                float rawPos = (ev.getX() - padPx - cellW * 0.5f) / cellW;
                if (rawPos < 0f) {
                    thumbPos = -MobileMotion.rubberBand(-rawPos, 0.25f);
                } else if (rawPos > count - 1) {
                    thumbPos = (count - 1) + MobileMotion.rubberBand(rawPos - (count - 1), 0.25f);
                } else {
                    thumbPos = rawPos;
                }
                int hovered = Math.max(0, Math.min(count - 1, Math.round(thumbPos)));
                updateLabelStyles(hovered, false);
                invalidate();
                return true;
            }
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                scrubbing = false;
                if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(false);
                if (action == MotionEvent.ACTION_CANCEL) {
                    selectIndex(selectedIndex, false);
                } else {
                    int snapped = Math.max(0, Math.min(count - 1, Math.round(thumbPos)));
                    selectIndex(snapped, true);
                }
                return true;
            }
            return super.onTouchEvent(ev);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            if (count <= 0) return;
            float innerW = getWidth() - padPx * 2f;
            float innerH = getHeight() - padPx * 2f;
            if (innerW <= 0f || innerH <= 0f) return;
            float cellW = innerW / count;
            float left = padPx + thumbPos * cellW;
            float top = padPx;
            float right = left + cellW;
            float bottom = top + innerH;

            // Subtle ambient elevation shadow under thumb
            float shadowDy = a.dp(1f);
            thumbRect.set(left, top + shadowDy, right, bottom + shadowDy);
            canvas.drawRoundRect(thumbRect, thumbRadiusPx, thumbRadiusPx, shadowPaint);

            thumbRect.set(left, top, right, bottom);
            canvas.drawRoundRect(thumbRect, thumbRadiusPx, thumbRadiusPx, thumbPaint);
        }

        @Override
        protected void onDetachedFromWindow() {
            stopSpring();
            super.onDetachedFromWindow();
        }
    }

    /** Row of 6 circular accent color swatches with outer ring + pop-bouncing checkmark on selected. */
    static LinearLayout accentSwatchRow(
            MainActivity a, int selectedPreset, PlayerBubble.IntAction onSelect) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(a.dp(10), a.dp(12), a.dp(10), a.dp(12));

        final int count = MobileTheme.ACCENT_COUNT;
        final int[] current = {selectedPreset >= 0 && selectedPreset < count ? selectedPreset : 0};
        final FrameLayout[] rings = new FrameLayout[count];
        final MobileIcons.IconView[] checks = new MobileIcons.IconView[count];

        for (int i = 0; i < count; i++) {
            final int idx = i;
            final int swatchColor = MobileTheme.ACCENT_COLORS[i];

            FrameLayout slot = new FrameLayout(a);
            slot.setClickable(true);
            slot.setFocusable(false);

            FrameLayout ring = new FrameLayout(a);
            int ringSize = a.dp(36);
            FrameLayout dot = new FrameLayout(a);
            dot.setBackground(a.bg(swatchColor, 999));
            int dotSize = a.dp(26);
            MobileIcons.IconView check =
                    MobileIcons.create(
                            a,
                            MobileIcons.IC_CHECK,
                            13f,
                            MobileTheme.computeAccentOnFill(swatchColor));
            check.setStrokeWidthUnits(2.5f);
            dot.addView(check, new FrameLayout.LayoutParams(a.dp(13), a.dp(13), Gravity.CENTER));
            ring.addView(dot, new FrameLayout.LayoutParams(dotSize, dotSize, Gravity.CENTER));
            slot.addView(ring, new FrameLayout.LayoutParams(ringSize, ringSize, Gravity.CENTER));

            rings[i] = ring;
            checks[i] = check;

            MobileMotion.bindPress(slot, 0.90f);
            slot.setOnClickListener(
                    v -> {
                        if (current[0] == idx) return;
                        current[0] = idx;
                        updateSwatchStates(a, rings, checks, current[0], true);
                        if (onSelect != null) onSelect.accept(idx);
                    });

            row.addView(slot, new LinearLayout.LayoutParams(0, a.dp(42), 1f));
        }

        updateSwatchStates(a, rings, checks, current[0], false);
        return row;
    }

    private static void updateSwatchStates(
            MainActivity a,
            FrameLayout[] rings,
            MobileIcons.IconView[] checks,
            int selectedIdx,
            boolean animate) {
        int strokePx = Math.max(2, a.dp(2f));
        for (int i = 0; i < rings.length; i++) {
            boolean active = i == selectedIdx;
            if (active) {
                GradientDrawable ringBg = new GradientDrawable();
                ringBg.setColor(Color.TRANSPARENT);
                ringBg.setCornerRadius(a.dp(999));
                ringBg.setStroke(strokePx, MobileTheme.ACCENT_COLORS[i]);
                rings[i].setBackground(ringBg);
                checks[i].setVisibility(View.VISIBLE);
                if (animate) {
                    MobileMotion.popBounce(rings[i]);
                    MobileMotion.popBounce(checks[i]);
                }
            } else {
                rings[i].setBackgroundColor(Color.TRANSPARENT);
                checks[i].setVisibility(View.INVISIBLE);
            }
        }
    }

    /**
     * Borderless {@code bgSubtle} pill search bar with pure vector {@link MobileIcons#IC_SEARCH}
     * icon, subtle accent focus ring, and animated clear button (zero emoji!).
     */
    static LinearLayout searchBar(
            MainActivity a, EditText outInput, String hint, Runnable onClear) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        final GradientDrawable barBg = MobileTheme.subtleBg(a, 14);
        final LinearLayout bar = a.row();
        bar.setBackground(barBg);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setMinimumHeight(a.dp(42));
        bar.setPadding(a.dp(12), 0, a.dp(8), 0);

        MobileIcons.IconView searchIcon =
                MobileIcons.create(a, MobileIcons.IC_SEARCH, 17f, p.textTertiary);
        LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(a.dp(17), a.dp(17));
        ilp.rightMargin = a.dp(9);
        bar.addView(searchIcon, ilp);

        final EditText input = outInput != null ? outInput : new EditText(a);
        if (input.getParent() instanceof ViewGroup) {
            ((ViewGroup) input.getParent()).removeView(input);
        }
        input.setBackgroundColor(Color.TRANSPARENT);
        input.setHint(hint != null ? hint : "");
        input.setHintTextColor(p.textTertiary);
        input.setTextColor(p.textPrimary);
        input.setTextSize(14.5f);
        input.setSingleLine(true);
        input.setIncludeFontPadding(false);
        input.setPadding(0, a.dp(8), 0, a.dp(8));
        input.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        input.setOnFocusChangeListener(
                (v, hasFocus) -> {
                    if (hasFocus) {
                        barBg.setStroke(
                                Math.max(1, a.dp(1.2f)),
                                MobileTheme.withAlpha(p.accent, p.isDark ? 0x99 : 0x77));
                        searchIcon.setTint(p.accent);
                    } else {
                        barBg.setStroke(0, Color.TRANSPARENT);
                        searchIcon.setTint(p.textTertiary);
                    }
                    bar.invalidate();
                });
        bar.addView(input, new LinearLayout.LayoutParams(0, -2, 1f));

        final FrameLayout clearBtn = new FrameLayout(a);
        clearBtn.setBackground(
                a.bg(MobileTheme.withAlpha(p.textSecondary, p.isDark ? 0x2E : 0x22), 999));
        MobileIcons.IconView closeIcon =
                MobileIcons.create(a, MobileIcons.IC_CLOSE, 11f, p.textSecondary);
        closeIcon.setStrokeWidthUnits(2.3f);
        clearBtn.addView(
                closeIcon, new FrameLayout.LayoutParams(a.dp(11), a.dp(11), Gravity.CENTER));
        MobileMotion.bindPress(clearBtn, 0.90f);
        boolean initialHasText = input.getText() != null && input.getText().length() > 0;
        clearBtn.setVisibility(initialHasText ? View.VISIBLE : View.GONE);
        clearBtn.setOnClickListener(
                v -> {
                    input.setText("");
                    if (onClear != null) onClear.run();
                });
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(a.dp(24), a.dp(24));
        clp.leftMargin = a.dp(6);
        bar.addView(clearBtn, clp);

        input.addTextChangedListener(
                new TextWatcher() {
                    @Override
                    public void beforeTextChanged(
                            CharSequence s, int start, int count, int after) {}

                    @Override
                    public void onTextChanged(CharSequence s, int start, int before, int count) {
                        boolean hasText = s != null && s.length() > 0;
                        MobileMotion.crossfadeVisibility(
                                clearBtn,
                                hasText,
                                0f,
                                0.72f,
                                MotionTokens.DURATION_MICRO_MS,
                                false);
                    }

                    @Override
                    public void afterTextChanged(Editable s) {}
                });

        return bar;
    }

    static View bindPressHighlight(View row, final int pressedColor) {
        if (row == null) return null;
        row.setClickable(true);
        MobileMotion.bindPress(row, 0.988f, Color.TRANSPARENT, pressedColor);
        return row;
    }

    private static LinearLayout buildBaseRow(
            MainActivity a,
            MobileTheme.Palette p,
            int icon,
            int badgeTintColor,
            String title,
            int titleColor) {
        LinearLayout row = a.row();
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(a.dp(52));
        row.setPadding(a.dp(14), a.dp(10), a.dp(14), a.dp(10));

        if (icon != 0) {
            FrameLayout badge = MobileIcons.badge(a, icon, badgeTintColor, 28, 16);
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(a.dp(28), a.dp(28));
            blp.rightMargin = a.dp(10);
            row.addView(badge, blp);
        }

        TextView label = a.text(title != null ? title : "", 15f, titleColor);
        label.setSingleLine(true);
        label.setEllipsize(TextUtils.TruncateAt.END);
        row.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));
        return row;
    }
}

package com.pilipala.marcomovie;

import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Pure-JVM responsive column calculator and unified source card builder matching iOS {@code
 * source_choice_sliver.dart} (Item 6: 原 6/10/15).
 *
 * <p>Guarantees:
 *
 * <ul>
 *   <li>Home quick-switch prefers 2 columns on regular phones/tablets and cleanly falls back to 1
 *       column on narrow screens, split-screen, or large system font scales ({@code fontScale >
 *       1.35f} or effective card width below {@code 152dp}).
 *   <li>Full source picker adapts 1..3 columns using actual available panel width and system font
 *       scale — never forcing 2 columns on cramped screens.
 *   <li>Every card is fully clickable, long-pressable, and keeps its right-side action buttons
 *       ({@code star} + {@code manage}) pinned at fixed width so they are always visible and
 *       clickable without clipping.
 * </ul>
 */
final class SourcePickerLayout {
    static final float QUICK_SWITCH_MIN_CARD_DP = 152f;
    static final float FULL_PICKER_MIN_CARD_DP = 156f;
    static final float DEFAULT_GAP_DP = 10f;
    static final float LARGE_FONT_SINGLE_COL_THRESHOLD = 1.35f;

    private SourcePickerLayout() {}

    /**
     * Pure-JVM column calculation using actual panel width and system font scale.
     *
     * @param availableWidthDp actual inner content width of the picker grid in dp
     * @param fontScale current {@code Configuration.fontScale} (clamped to >= 1.0f)
     * @param maxColumns upper column bound (2 for Home quick-switch, 3 for full picker)
     * @param minCardWidthDp minimum comfortable width of a single card at 1.0x font scale
     * @param gapDp horizontal spacing between columns in dp
     */
    static int resolveColumns(
            float availableWidthDp,
            float fontScale,
            int maxColumns,
            float minCardWidthDp,
            float gapDp) {
        if (availableWidthDp <= 0f || maxColumns <= 1) return 1;
        float safeFont = Math.max(1.0f, Float.isNaN(fontScale) ? 1.0f : fontScale);
        if (safeFont > LARGE_FONT_SINGLE_COL_THRESHOLD) {
            // Very large accessibility font scale: fall back to 1 column unless tablet-wide
            // (>=620dp)
            if (availableWidthDp < 620f) return 1;
        }
        float effectiveMinCard = minCardWidthDp * (1.0f + (safeFont - 1.0f) * 0.65f);
        int cols =
                Math.max(
                        1,
                        (int) Math.floor((availableWidthDp + gapDp) / (effectiveMinCard + gapDp)));
        return Math.max(1, Math.min(maxColumns, cols));
    }

    /** Home quick-switch policy: prefer 2 columns, gracefully degrade to 1 on narrow/large font. */
    static int resolveQuickSwitchColumns(float availableWidthDp, float fontScale) {
        return resolveColumns(
                availableWidthDp, fontScale, 2, QUICK_SWITCH_MIN_CARD_DP, DEFAULT_GAP_DP);
    }

    /** Full source picker policy: 1..3 columns on mobile, 2..3 on TV. */
    static int resolveFullPickerColumns(float availableWidthDp, float fontScale, boolean isTv) {
        if (isTv) {
            return Math.max(
                    2, resolveColumns(availableWidthDp, fontScale, 3, 196f, DEFAULT_GAP_DP));
        }
        return resolveColumns(
                availableWidthDp, fontScale, 3, FULL_PICKER_MIN_CARD_DP, DEFAULT_GAP_DP);
    }

    /**
     * Builds a responsive mobile source card where:
     *
     * <ul>
     *   <li>The entire card responds to click ({@code onSelect}) and long-press ({@code onManage}).
     *   <li>Title occupies {@code weight=1f} and elides cleanly, while right-side favorite and
     *       manage action buttons use fixed width ({@code weight=0}) so they are always visible and
     *       clickable.
     * </ul>
     */
    static LinearLayout buildMobileSourceCard(
            final MainActivity a,
            final Cms.Site site,
            final boolean isCurrent,
            final boolean isPreferred,
            final boolean isAvailable,
            final Runnable onSelect,
            final Runnable onTogglePreferred,
            final Runnable onManage) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout card = a.vertical();
        card.setTag("source-card:" + (site != null ? site.key : ""));
        card.setPadding(a.dp(11), a.dp(10), a.dp(8), a.dp(10));
        GradientDrawable bg =
                a.bg(
                        isCurrent
                                ? MobileTheme.withAlpha(p.accent, p.isDark ? 0x2E : 0x1A)
                                : p.bgSubtle,
                        14);
        if (isCurrent) {
            bg.setStroke(a.dp(1.2f), p.accent);
        } else {
            bg.setStroke(MobileTheme.hairlinePx(a), p.hairline);
        }
        card.setBackground(bg);

        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);

        String titleText =
                (isCurrent ? "✓ " : "") + (site != null && site.name != null ? site.name : "");
        TextView titleTv =
                a.text(
                        titleText,
                        13.5f,
                        isAvailable ? (isCurrent ? p.accent : p.textPrimary) : p.textTertiary);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setMaxLines(2);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0, -2, 1f);
        tlp.rightMargin = a.dp(4);
        headerRow.addView(titleTv, tlp);

        // Right-side pinned buttons (weight=0, guaranteed visible & clickable)
        if (onTogglePreferred != null) {
            FrameLayout starBtn = new FrameLayout(a);
            starBtn.setTag("source-card-star:" + (site != null ? site.key : ""));
            starBtn.setContentDescription(isPreferred ? "取消常用片源" : "设为常用片源");
            MobileIcons.IconView starIcon =
                    MobileIcons.create(
                            a,
                            MobileIcons.IC_STAR,
                            14.5f,
                            isPreferred ? 0xFFF59E0B : p.textTertiary);
            starIcon.setFilled(isPreferred);
            starBtn.addView(
                    starIcon, new FrameLayout.LayoutParams(a.dp(15), a.dp(15), Gravity.CENTER));
            MobileMotion.bindPress(starBtn, 0.88f);
            starBtn.setOnClickListener(v -> onTogglePreferred.run());
            headerRow.addView(starBtn, new LinearLayout.LayoutParams(a.dp(30), a.dp(30)));
        }

        if (onManage != null) {
            FrameLayout moreBtn = new FrameLayout(a);
            moreBtn.setTag("source-card-more:" + (site != null ? site.key : ""));
            moreBtn.setContentDescription("管理该片源");
            MobileIcons.IconView moreIcon =
                    MobileIcons.create(a, MobileIcons.IC_MORE, 14.5f, p.textSecondary);
            moreBtn.addView(
                    moreIcon, new FrameLayout.LayoutParams(a.dp(15), a.dp(15), Gravity.CENTER));
            MobileMotion.bindPress(moreBtn, 0.88f);
            moreBtn.setOnClickListener(v -> onManage.run());
            headerRow.addView(moreBtn, new LinearLayout.LayoutParams(a.dp(30), a.dp(30)));
        }

        card.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        String subText =
                !isAvailable
                        ? (site != null ? site.limitation() : "暂不可用")
                        : SourcePicker.siteGroup(site) + (isCurrent ? " · 当前片源" : "");
        TextView subTv = a.text(subText, 11f, isAvailable ? p.textSecondary : p.danger);
        subTv.setSingleLine(true);
        subTv.setEllipsize(TextUtils.TruncateAt.END);
        subTv.setPadding(0, a.dp(3), 0, 0);
        card.addView(subTv, new LinearLayout.LayoutParams(-1, -2));

        MobileMotion.bindPress(card, 0.97f);
        card.setOnClickListener(
                v -> {
                    if (onSelect != null) onSelect.run();
                });
        card.setOnLongClickListener(
                v -> {
                    if (onManage != null) {
                        onManage.run();
                        return true;
                    }
                    return false;
                });
        return card;
    }
}

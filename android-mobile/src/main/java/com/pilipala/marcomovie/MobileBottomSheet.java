package com.pilipala.marcomovie;

import android.app.Dialog;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.AbsSeekBar;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * Unified mobile bottom sheet (and landscape cinema side-sheet) foundation.
 *
 * <p>Guarantees four invariants:
 * <ol>
 *   <li>Every window, backdrop, and sheet container is tagged with {@link #DRAWER_TAG}
 *       ({@code "mobile-drawer"}) so {@link PluginDialogStyler} NEVER misclassifies or hijacks
 *       app-owned mobile sheets.</li>
 *   <li>Sheets always hug {@code WRAP_CONTENT} height capped cleanly at {@code 76%} of window
 *       height ({@link #computeMaxSheetHeightPx(int)}), eliminating full-screen empty blank space
 *       while letting tall sheets scroll smoothly above the navigation bar inset.</li>
 *   <li>All enter/exit transitions use {@link MotionTokens} curves and honor {@link
 *       MobileMotion#isReduced(Context)} (opacity-only {@code 150ms} when reduced).</li>
 *   <li>Interactive finger-tracking drag-to-dismiss with {@link MobileMotion#rubberBand} overpull
 *       resistance and interruptible {@link MotionSpring} spring-back.</li>
 * </ol>
 */
final class MobileBottomSheet {
    static final String DRAWER_TAG = "mobile-drawer";

    private MobileBottomSheet() {}

    /** Lightweight handle allowing callers to update sheet header state or trigger animated exit. */
    static final class SheetHandle {
        final Dialog dialog;
        private final TextView subtitleView;
        private final TextView actionBtn;
        private final Runnable animatedDismiss;

        SheetHandle(
                Dialog dialog,
                TextView subtitleView,
                TextView actionBtn,
                Runnable animatedDismiss) {
            this.dialog = dialog;
            this.subtitleView = subtitleView;
            this.actionBtn = actionBtn;
            this.animatedDismiss = animatedDismiss;
        }

        Dialog dialog() {
            return dialog;
        }

        void setSubtitle(String subtitle) {
            if (subtitleView == null) return;
            String text = subtitle == null ? "" : subtitle;
            boolean show = !text.isEmpty();
            if (show) {
                if (subtitleView.getVisibility() != View.VISIBLE) {
                    subtitleView.setText(text);
                    MobileMotion.crossfadeVisibility(
                            subtitleView, true, 0f, 1f, MotionTokens.DURATION_MICRO_MS, false);
                } else {
                    MobileMotion.crossfadeText(subtitleView, text);
                }
            } else {
                MobileMotion.crossfadeVisibility(
                        subtitleView, false, 0f, 1f, MotionTokens.DURATION_MICRO_MS, false);
            }
        }

        void setAction(String label, boolean visible) {
            if (actionBtn == null) return;
            if (label != null) {
                actionBtn.setText(label);
            }
            boolean shouldShow =
                    visible && actionBtn.getText() != null && actionBtn.getText().length() > 0;
            MobileMotion.crossfadeVisibility(
                    actionBtn, shouldShow, 0f, 0.85f, MotionTokens.DURATION_MICRO_MS, false);
        }

        void setActionVisible(boolean visible) {
            setAction(null, visible);
        }

        void dismiss() {
            if (animatedDismiss != null) {
                animatedDismiss.run();
            } else if (dialog != null) {
                dialog.dismiss();
            }
        }
    }

    /** Pure-JVM sheet max-height policy (76% of window height). */
    static int computeMaxSheetHeightPx(int windowHeightPx) {
        if (windowHeightPx <= 0) return 0;
        return Math.round(windowHeightPx * 0.76f);
    }

    /** Pure-JVM remaining scroll-body budget after subtracting non-scroll chrome heights. */
    static int computeRemainingScrollHeightPx(
            int maxSheetHeightPx, int chromeHeightPx, int minScrollBodyPx) {
        if (maxSheetHeightPx <= 0) return Math.max(0, minScrollBodyPx);
        return Math.max(minScrollBodyPx, maxSheetHeightPx - Math.max(0, chromeHeightPx));
    }

    private static boolean isActivityGone(MainActivity a) {
        return a == null || a.isFinishing() || (Build.VERSION.SDK_INT >= 17 && a.isDestroyed());
    }

    static Dialog show(MainActivity a, String title, View content) {
        return show(a, title, null, null, null, content, true);
    }

    static SheetHandle showCustom(
            MainActivity a, String title, View content, final Runnable onDismiss) {
        SheetHandle handle = showHandle(a, title, null, null, null, content, true);
        if (handle.dialog != null && onDismiss != null) {
            handle.dialog.setOnDismissListener(d -> onDismiss.run());
        }
        return handle;
    }

    static Dialog show(
            MainActivity a,
            String title,
            String subtitle,
            String actionLabel,
            Runnable onAction,
            View content,
            boolean allowScroll) {
        return showHandle(a, title, subtitle, actionLabel, onAction, content, allowScroll).dialog;
    }

    static SheetHandle showHandle(
            MainActivity a,
            String title,
            String subtitle,
            String actionLabel,
            Runnable onAction,
            View content,
            boolean allowScroll) {
        if (isActivityGone(a)) {
            return new SheetHandle(null, null, null, null);
        }
        final MobileTheme.Palette p = MobileTheme.of(a);
        final SheetDialog dlg = new SheetDialog(a, false);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        configureSheetWindow(a, dlg, false);

        final FrameLayout backdrop = new FrameLayout(a);
        backdrop.setTag(DRAWER_TAG);
        backdrop.setBackgroundColor(p.scrimBackdrop);
        backdrop.setOnClickListener(v -> dlg.dismissAnimated());

        boolean portrait = a.isPortrait();
        int winW = a.windowWidth();
        int winH = a.windowHeight();
        int sheetWidth =
                portrait
                        ? ViewGroup.LayoutParams.MATCH_PARENT
                        : Math.min(Math.max(a.dp(320), winW - a.dp(48)), a.dp(520));
        int maxH = computeMaxSheetHeightPx(winH);
        int navInset = a.navigationBarHeight();

        final MaxHeightLinearLayout sheet = new MaxHeightLinearLayout(a, maxH, a.dp(100));
        sheet.setTag(DRAWER_TAG);
        sheet.setOrientation(LinearLayout.VERTICAL);
        sheet.setClickable(true);
        sheet.setPadding(a.dp(18), a.dp(10), a.dp(18), portrait ? navInset + a.dp(16) : a.dp(16));

        GradientDrawable sheetBg = new GradientDrawable();
        sheetBg.setColor(p.bgSheet);
        float r = a.dp(24);
        if (portrait) {
            sheetBg.setCornerRadii(new float[] {r, r, r, r, 0f, 0f, 0f, 0f});
        } else {
            sheetBg.setCornerRadius(r);
        }
        sheet.setBackground(sheetBg);
        UiCompat.setElevation(sheet, a.dp(16));

        // Centered drag handle
        View handle = new View(a);
        handle.setBackground(a.bg(p.handleColor, 999));
        LinearLayout.LayoutParams handleLp = new LinearLayout.LayoutParams(a.dp(36), a.dp(4));
        handleLp.gravity = Gravity.CENTER_HORIZONTAL;
        handleLp.bottomMargin = a.dp(12);
        sheet.addView(handle, handleLp);

        // Header bar
        boolean hasTitle = title != null && !title.isEmpty();
        boolean hasSub = subtitle != null && !subtitle.isEmpty();
        boolean hasAction = actionLabel != null && !actionLabel.isEmpty();
        TextView subtitleView = null;
        TextView actionBtn = null;
        if (hasTitle || hasSub || hasAction || onAction != null) {
            LinearLayout header = a.row();
            header.setGravity(Gravity.CENTER_VERTICAL);

            LinearLayout titleCol = a.vertical();
            if (hasTitle) {
                TextView titleView = a.text(title, 17f, p.textPrimary);
                titleView.setTypeface(null, Typeface.BOLD);
                titleView.setSingleLine(true);
                titleView.setEllipsize(TextUtils.TruncateAt.END);
                titleCol.addView(titleView);
            }
            subtitleView = a.text(hasSub ? subtitle : "", 12.5f, p.textSecondary);
            subtitleView.setPadding(0, a.dp(3), 0, 0);
            subtitleView.setMaxLines(2);
            subtitleView.setEllipsize(TextUtils.TruncateAt.END);
            subtitleView.setVisibility(hasSub ? View.VISIBLE : View.GONE);
            titleCol.addView(subtitleView);
            header.addView(titleCol, new LinearLayout.LayoutParams(0, -2, 1f));

            if (hasAction || onAction != null) {
                actionBtn = a.text(hasAction ? actionLabel : "", 14f, p.accent);
                actionBtn.setTypeface(null, Typeface.BOLD);
                actionBtn.setGravity(Gravity.CENTER);
                actionBtn.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
                actionBtn.setVisibility(hasAction ? View.VISIBLE : View.GONE);
                MobileMotion.bindPress(actionBtn, 0.92f);
                actionBtn.setOnClickListener(
                        v -> {
                            if (onAction != null) onAction.run();
                        });
                LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(-2, -2);
                alp.rightMargin = a.dp(6);
                header.addView(actionBtn, alp);
            }

            FrameLayout closeBtn =
                    buildCloseButton(a, p.bgSubtle, p.textSecondary, dlg::dismissAnimated);
            header.addView(closeBtn, new LinearLayout.LayoutParams(a.dp(32), a.dp(32)));

            LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(-1, -2);
            hlp.bottomMargin = a.dp(14);
            sheet.addView(header, hlp);
        }

        attachSheetContent(a, sheet, content, allowScroll);
        sheet.bindInteractiveDismiss(a, backdrop, false, dlg::dismissAnimated);
        dlg.attachSheetViews(backdrop, sheet);

        FrameLayout.LayoutParams sheetLp =
                new FrameLayout.LayoutParams(
                        sheetWidth,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        if (!portrait) {
            sheetLp.bottomMargin = navInset + a.dp(12);
        }
        backdrop.addView(sheet, sheetLp);

        dlg.setContentView(
                backdrop,
                new ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        dlg.show();
        finalizeSheetWindow(dlg, false);
        animateSheetIn(a, backdrop, sheet, false);
        return new SheetHandle(dlg, subtitleView, actionBtn, dlg::dismissAnimated);
    }

    /** Clean borderless Inset Grouped picker sheet with accent selection + vector checkmark. */
    static Dialog showPicker(
            MainActivity a,
            String title,
            String subtitle,
            String[] options,
            int selectedIndex,
            PlayerBubble.IntAction onSelect) {
        if (isActivityGone(a)) return null;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final SheetHandle[] holder = new SheetHandle[1];

        LinearLayout list = a.vertical();
        list.setPadding(0, a.dp(2), 0, a.dp(4));

        if (options != null) {
            int hairlinePx = MobileTheme.hairlinePx(a);
            for (int i = 0; i < options.length; i++) {
                final int idx = i;
                final boolean active = idx == selectedIndex;

                LinearLayout optRow = a.row();
                optRow.setGravity(Gravity.CENTER_VERTICAL);
                optRow.setMinimumHeight(a.dp(50));
                optRow.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
                if (active) {
                    optRow.setBackground(a.bg(p.pillSelectedFill, 12));
                    MobileMotion.bindPress(optRow, 0.985f);
                } else {
                    MobileSectionGroup.bindPressHighlight(optRow, p.bgPressed);
                }

                TextView label = a.text(options[i], 15f, p.textPrimary);
                label.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
                label.setSingleLine(false);
                label.setMaxLines(2);
                label.setEllipsize(TextUtils.TruncateAt.END);
                optRow.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

                if (active) {
                    MobileIcons.IconView check =
                            MobileIcons.create(a, MobileIcons.IC_CHECK, 18f, p.accent);
                    check.setStrokeWidthUnits(2.3f);
                    LinearLayout.LayoutParams clp =
                            new LinearLayout.LayoutParams(a.dp(18), a.dp(18));
                    clp.leftMargin = a.dp(12);
                    optRow.addView(check, clp);
                }

                optRow.setOnClickListener(
                        v -> {
                            if (holder[0] != null) holder[0].dismiss();
                            if (onSelect != null) onSelect.accept(idx);
                        });
                list.addView(optRow, new LinearLayout.LayoutParams(-1, -2));

                boolean nextIsActive = (i + 1) == selectedIndex;
                if (i + 1 < options.length && !active && !nextIsActive) {
                    View divider = new View(a);
                    divider.setBackgroundColor(p.hairline);
                    LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(-1, hairlinePx);
                    dlp.leftMargin = a.dp(14);
                    dlp.rightMargin = a.dp(14);
                    list.addView(divider, dlp);
                }
            }
        }

        holder[0] = showHandle(a, title, subtitle, null, null, list, true);
        return holder[0].dialog;
    }

    /**
     * Unified confirmation sheet for destructive or irreversible user actions. Spatially separates
     * the high-contrast primary confirmation button above a neutral full-width cancel button.
     */
    static Dialog showConfirm(
            MainActivity a,
            String title,
            String message,
            String confirmLabel,
            boolean destructive,
            Runnable onConfirm) {
        if (isActivityGone(a)) return null;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final SheetHandle[] holder = new SheetHandle[1];

        LinearLayout box = a.vertical();
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        box.setPadding(a.dp(6), a.dp(6), a.dp(6), a.dp(4));

        int tint = destructive ? p.danger : p.accent;
        FrameLayout badge = new FrameLayout(a);
        badge.setBackground(a.bg(MobileTheme.withAlpha(tint, p.isDark ? 0x2E : 0x1C), 14));
        MobileIcons.IconView glyph =
                MobileIcons.create(
                        a, destructive ? MobileIcons.IC_WARNING : MobileIcons.IC_INFO, 24f, tint);
        glyph.setStrokeWidthUnits(2.0f);
        badge.addView(glyph, new FrameLayout.LayoutParams(a.dp(24), a.dp(24), Gravity.CENTER));
        box.addView(badge, new LinearLayout.LayoutParams(a.dp(48), a.dp(48)));

        if (title != null && !title.trim().isEmpty()) {
            TextView titleView = a.text(title.trim(), 17.5f, p.textPrimary);
            titleView.setTypeface(null, Typeface.BOLD);
            titleView.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(-1, -2);
            tlp.topMargin = a.dp(14);
            box.addView(titleView, tlp);
        }

        if (message != null && !message.trim().isEmpty()) {
            TextView msgView = a.text(message.trim(), 13.5f, p.textSecondary);
            msgView.setGravity(Gravity.CENTER);
            msgView.setLineSpacing(a.dp(3f), 1f);
            LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(-1, -2);
            mlp.topMargin = a.dp(6);
            box.addView(msgView, mlp);
        }

        a.gap(box, 20);

        String primaryText =
                (confirmLabel != null && !confirmLabel.trim().isEmpty())
                        ? confirmLabel.trim()
                        : "确认";
        TextView confirmBtn = a.text(primaryText, 15f, destructive ? 0xFFFFFFFF : p.accentOnFill);
        confirmBtn.setTypeface(null, Typeface.BOLD);
        confirmBtn.setGravity(Gravity.CENTER);
        confirmBtn.setMinimumHeight(a.dp(48));
        confirmBtn.setPadding(a.dp(16), a.dp(13), a.dp(16), a.dp(13));
        confirmBtn.setBackground(a.bg(tint, 14));
        MobileMotion.bindPress(confirmBtn, 0.96f);

        TextView cancelBtn = a.text("取消", 15f, p.textPrimary);
        cancelBtn.setTypeface(null, Typeface.BOLD);
        cancelBtn.setGravity(Gravity.CENTER);
        cancelBtn.setMinimumHeight(a.dp(48));
        cancelBtn.setPadding(a.dp(16), a.dp(13), a.dp(16), a.dp(13));
        cancelBtn.setBackground(MobileTheme.subtleBg(a, 14));
        MobileMotion.bindPress(cancelBtn, 0.96f);

        final boolean[] actionConsumed = {false};
        confirmBtn.setOnClickListener(
                createSingleShotConfirmListener(
                        actionConsumed,
                        confirmBtn,
                        cancelBtn,
                        () -> {
                            if (holder[0] != null) holder[0].dismiss();
                        },
                        onConfirm));
        cancelBtn.setOnClickListener(
                createSingleShotConfirmListener(
                        actionConsumed,
                        cancelBtn,
                        confirmBtn,
                        () -> {
                            if (holder[0] != null) holder[0].dismiss();
                        },
                        null));

        box.addView(confirmBtn, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 10);
        box.addView(cancelBtn, new LinearLayout.LayoutParams(-1, -2));

        holder[0] = showHandle(a, null, null, null, null, box, false);
        return holder[0].dialog;
    }

    /**
     * Single-shot click listener for confirmation sheets: disables both buttons immediately upon
     * first activation so rapid double-taps during dismiss animation never trigger duplicate
     * callbacks (e.g., duplicate empty-history diagnostic uploads).
     */
    static View.OnClickListener createSingleShotConfirmListener(
            final boolean[] consumed,
            final View primaryBtn,
            final View secondaryBtn,
            final Runnable dismissAction,
            final Runnable onAction) {
        return v -> {
            if (consumed != null) {
                if (consumed[0]) return;
                consumed[0] = true;
            }
            if (primaryBtn != null) {
                primaryBtn.setEnabled(false);
                primaryBtn.setClickable(false);
                primaryBtn.setAlpha(0.55f);
            }
            if (secondaryBtn != null) {
                secondaryBtn.setEnabled(false);
                secondaryBtn.setClickable(false);
            }
            if (dismissAction != null) dismissAction.run();
            if (onAction != null) onAction.run();
        };
    }

    /**
     * Dark cinema translucent frosted sheet for full-screen / inline player overlays. Slides from
     * the right ({@code 320dp} side drawer) in landscape when {@code preferSideInLandscape} is
     * true, or from the bottom in portrait.
     */
    static Dialog showPlayerSheet(
            MainActivity a, String title, View content, boolean preferSideInLandscape) {
        return showPlayerHandle(a, title, content, preferSideInLandscape).dialog;
    }

    static SheetHandle showPlayerHandle(
            MainActivity a, String title, View content, boolean preferSideInLandscape) {
        if (isActivityGone(a)) {
            return new SheetHandle(null, null, null, null);
        }
        final boolean sideMode = !a.isPortrait() && preferSideInLandscape;
        final SheetDialog dlg = new SheetDialog(a, sideMode);
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        configureSheetWindow(a, dlg, true);

        final FrameLayout backdrop = new FrameLayout(a);
        backdrop.setTag(DRAWER_TAG);
        backdrop.setBackgroundColor(0x66000000);
        backdrop.setOnClickListener(v -> dlg.dismissAnimated());

        int winW = a.windowWidth();
        int winH = a.windowHeight();
        int navInset = a.navigationBarHeight();
        boolean solid = a.isReducedTransparency();

        final MaxHeightLinearLayout sheet =
                new MaxHeightLinearLayout(
                        a, sideMode ? 0 : computeMaxSheetHeightPx(winH), a.dp(100));
        sheet.setTag(DRAWER_TAG);
        sheet.setOrientation(LinearLayout.VERTICAL);
        sheet.setClickable(true);

        GradientDrawable sheetBg = new GradientDrawable();
        sheetBg.setColor(solid ? 0xF5141720 : 0xE0141720);
        float r = a.dp(22);
        if (sideMode) {
            sheetBg.setCornerRadii(new float[] {r, r, 0f, 0f, 0f, 0f, r, r});
            sheet.setPadding(a.dp(18), a.dp(18), a.dp(18), a.dp(18));
        } else {
            sheetBg.setCornerRadii(new float[] {r, r, r, r, 0f, 0f, 0f, 0f});
            sheet.setPadding(a.dp(18), a.dp(10), a.dp(18), navInset + a.dp(16));
        }
        sheetBg.setStroke(MobileTheme.hairlinePx(a), 0x22FFFFFF);
        sheet.setBackground(sheetBg);
        UiCompat.setElevation(sheet, a.dp(16));

        if (!sideMode) {
            View handle = new View(a);
            handle.setBackground(a.bg(0x3DFFFFFF, 999));
            LinearLayout.LayoutParams handleLp = new LinearLayout.LayoutParams(a.dp(36), a.dp(4));
            handleLp.gravity = Gravity.CENTER_HORIZONTAL;
            handleLp.bottomMargin = a.dp(12);
            sheet.addView(handle, handleLp);
        }

        if (title != null && !title.isEmpty()) {
            LinearLayout header = a.row();
            header.setGravity(Gravity.CENTER_VERTICAL);
            TextView titleView = a.text(title, 16.5f, 0xFFF3F5F9);
            titleView.setTypeface(null, Typeface.BOLD);
            titleView.setSingleLine(true);
            titleView.setEllipsize(TextUtils.TruncateAt.END);
            header.addView(titleView, new LinearLayout.LayoutParams(0, -2, 1f));

            FrameLayout closeBtn =
                    buildCloseButton(a, 0x22FFFFFF, 0xFFD1D5DB, dlg::dismissAnimated);
            header.addView(closeBtn, new LinearLayout.LayoutParams(a.dp(30), a.dp(30)));

            LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(-1, -2);
            hlp.bottomMargin = a.dp(12);
            sheet.addView(header, hlp);
        }

        attachSheetContent(a, sheet, content, true);
        sheet.bindInteractiveDismiss(a, backdrop, sideMode, dlg::dismissAnimated);
        dlg.attachSheetViews(backdrop, sheet);

        FrameLayout.LayoutParams sheetLp;
        if (sideMode) {
            int sideW = Math.min(a.dp(320), Math.max(a.dp(260), Math.round(winW * 0.48f)));
            sheetLp =
                    new FrameLayout.LayoutParams(
                            sideW,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            Gravity.RIGHT | Gravity.FILL_VERTICAL);
        } else {
            sheetLp =
                    new FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                            Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        }
        backdrop.addView(sheet, sheetLp);

        dlg.setContentView(
                backdrop,
                new ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        dlg.show();
        finalizeSheetWindow(dlg, sideMode);
        animateSheetIn(a, backdrop, sheet, sideMode);
        return new SheetHandle(dlg, null, null, dlg::dismissAnimated);
    }

    private static void configureSheetWindow(MainActivity a, Dialog dlg, boolean playerMode) {
        Window w = dlg.getWindow();
        if (w == null) return;
        w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        w.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        w.setLayout(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT);
        w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        if (playerMode) {
            w.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
        }
        MobileTheme.applyWindowBlurIfSupported(w, a.isReducedTransparency(), 24);
        View decor = w.getDecorView();
        if (decor != null) {
            decor.setTag(DRAWER_TAG);
        }
    }

    private static void finalizeSheetWindow(Dialog dlg, boolean sideMode) {
        Window w = dlg.getWindow();
        if (w == null) return;
        w.setLayout(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT);
        w.setGravity(
                sideMode
                        ? (Gravity.RIGHT | Gravity.FILL_VERTICAL)
                        : (Gravity.BOTTOM | Gravity.FILL_HORIZONTAL));
        View decor = w.getDecorView();
        if (decor != null) {
            decor.setTag(DRAWER_TAG);
            decor.setPadding(0, 0, 0, 0);
        }
    }

    private static void attachSheetContent(
            MainActivity a, MaxHeightLinearLayout sheet, View content, boolean allowScroll) {
        if (content == null) return;
        if (content.getParent() instanceof ViewGroup) {
            ((ViewGroup) content.getParent()).removeView(content);
        }
        if (allowScroll) {
            MaxHeightScrollView scroll = new MaxHeightScrollView(a);
            scroll.setVerticalScrollBarEnabled(false);
            scroll.setOverScrollMode(View.OVER_SCROLL_IF_CONTENT_SCROLLS);
            scroll.addView(
                    content,
                    new ScrollView.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT));
            sheet.setScrollBody(scroll);
            sheet.addView(
                    scroll,
                    new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT));
        } else {
            sheet.addView(
                    content,
                    new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT));
        }
    }

    private static FrameLayout buildCloseButton(
            MainActivity a, int circleColor, int iconColor, Runnable onClick) {
        FrameLayout btn = new FrameLayout(a);
        btn.setBackground(a.bg(circleColor, 999));
        MobileIcons.IconView closeIcon =
                MobileIcons.create(a, MobileIcons.IC_CLOSE, 14f, iconColor);
        closeIcon.setStrokeWidthUnits(2.2f);
        btn.addView(closeIcon, new FrameLayout.LayoutParams(a.dp(14), a.dp(14), Gravity.CENTER));
        MobileMotion.bindPress(btn, 0.90f);
        btn.setOnClickListener(
                v -> {
                    if (onClick != null) onClick.run();
                });
        return btn;
    }

    private static void animateSheetIn(
            MainActivity a, View backdrop, View sheet, boolean fromRight) {
        if (MobileMotion.isReduced(a)) {
            backdrop.setAlpha(0f);
            sheet.setAlpha(0f);
            backdrop.animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .start();
            sheet.animate()
                    .alpha(1f)
                    .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                    .setInterpolator(MotionTokens.createLinearInterpolator())
                    .start();
            return;
        }
        backdrop.setAlpha(0f);
        backdrop.animate()
                .alpha(1f)
                .setDuration(MotionTokens.DURATION_STANDARD_MS)
                .setInterpolator(MotionTokens.createDecelerateInterpolator())
                .start();
        sheet.post(
                () -> {
                    if (isActivityGone(a) || !UiCompat.isAttached(sheet)) return;
                    if (fromRight) {
                        float dx = Math.max(a.dp(140), sheet.getWidth());
                        sheet.setTranslationX(dx);
                        sheet.animate()
                                .translationX(0f)
                                .setDuration(MotionTokens.DURATION_MOBILE_SHARED_BOUNDS_MS)
                                .setInterpolator(MotionTokens.createDecelerateInterpolator())
                                .start();
                    } else {
                        float dy =
                                sheet.getHeight() > 0
                                        ? Math.max(a.dp(140), sheet.getHeight())
                                        : a.dp(220);
                        sheet.setTranslationY(dy);
                        sheet.animate()
                                .translationY(0f)
                                .setDuration(MotionTokens.DURATION_MOBILE_SHARED_BOUNDS_MS)
                                .setInterpolator(MotionTokens.createDecelerateInterpolator())
                                .start();
                    }
                });
    }

    /** Custom Dialog with idempotent animated exit across backdrop tap, close, Back, and programmatic dismiss. */
    private static final class SheetDialog extends Dialog {
        private final MainActivity a;
        private final boolean sideMode;
        private View backdrop;
        private MaxHeightLinearLayout sheet;
        private boolean dismissing;

        SheetDialog(MainActivity a, boolean sideMode) {
            super(a);
            this.a = a;
            this.sideMode = sideMode;
        }

        void attachSheetViews(View backdrop, MaxHeightLinearLayout sheet) {
            this.backdrop = backdrop;
            this.sheet = sheet;
        }

        @Override
        public void onBackPressed() {
            cancel();
        }

        @Override
        public void dismiss() {
            if (dismissing) {
                return;
            }
            dismissAnimated();
        }

        void dismissAnimated() {
            if (dismissing) return;
            dismissing = true;
            if (sheet != null) {
                sheet.stopSpringBack();
            }
            if (!isShowing()
                    || isActivityGone(a)
                    || backdrop == null
                    || sheet == null
                    || !UiCompat.isAttached(sheet)) {
                superDismissQuietly();
                return;
            }
            backdrop.animate().cancel();
            sheet.animate().cancel();
            if (MobileMotion.isReduced(a)) {
                backdrop.animate()
                        .alpha(0f)
                        .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                        .setInterpolator(MotionTokens.createLinearInterpolator())
                        .start();
                sheet.animate()
                        .alpha(0f)
                        .setDuration(MotionTokens.REDUCE_MOTION_TRANSITION_DURATION_MS)
                        .setInterpolator(MotionTokens.createLinearInterpolator())
                        .withEndAction(this::superDismissQuietly)
                        .start();
                return;
            }
            int dur = MotionTokens.DURATION_FAST_MS;
            backdrop.animate()
                    .alpha(0f)
                    .setDuration(dur)
                    .setInterpolator(MotionTokens.createAccelerateInterpolator())
                    .start();
            if (sideMode) {
                float targetX = Math.max(a.dp(140), sheet.getWidth());
                sheet.animate()
                        .translationX(targetX)
                        .setDuration(dur)
                        .setInterpolator(MotionTokens.createAccelerateInterpolator())
                        .withEndAction(this::superDismissQuietly)
                        .start();
            } else {
                float targetY = Math.max(a.dp(160), sheet.getHeight());
                sheet.animate()
                        .translationY(targetY)
                        .setDuration(dur)
                        .setInterpolator(MotionTokens.createAccelerateInterpolator())
                        .withEndAction(this::superDismissQuietly)
                        .start();
            }
        }

        private void superDismissQuietly() {
            try {
                if (sheet != null) sheet.stopSpringBack();
                super.dismiss();
            } catch (Throwable ignored) {
            }
        }
    }

    /**
     * Vertical sheet container that caps total height to {@code maxHeightPx}, dynamically bounds
     * any child {@link MaxHeightScrollView}, and provides interruptible finger-tracking drag to
     * dismiss with {@link MobileMotion#rubberBand} overpull and {@link MotionSpring} settle.
     */
    static final class MaxHeightLinearLayout extends LinearLayout {
        private final int maxHeightPx;
        private final int minScrollBodyPx;
        private MaxHeightScrollView scrollBody;

        private MainActivity host;
        private View backdrop;
        private boolean sideMode;
        private Runnable onDismissRequest;
        private int touchSlop;
        private boolean tracking;
        private boolean startedInScrollBody;
        private float downRawX;
        private float downRawY;
        private float startTranslation;
        private VelocityTracker velocityTracker;
        private MotionLoop.Step springBackStep;

        MaxHeightLinearLayout(Context context, int maxHeightPx, int minScrollBodyPx) {
            super(context);
            this.maxHeightPx = maxHeightPx;
            this.minScrollBodyPx = minScrollBodyPx;
            this.touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
        }

        void setScrollBody(MaxHeightScrollView body) {
            this.scrollBody = body;
        }

        void bindInteractiveDismiss(
                MainActivity host, View backdrop, boolean sideMode, Runnable onDismissRequest) {
            this.host = host;
            this.backdrop = backdrop;
            this.sideMode = sideMode;
            this.onDismissRequest = onDismissRequest;
        }

        void stopSpringBack() {
            if (springBackStep != null) {
                MotionLoop.remove(springBackStep);
                springBackStep = null;
            }
        }

        private void recycleVelocity() {
            if (velocityTracker != null) {
                velocityTracker.recycle();
                velocityTracker = null;
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            stopSpringBack();
            recycleVelocity();
            super.onDetachedFromWindow();
        }

        private boolean isTouchInsideScrollBody(MotionEvent ev) {
            if (scrollBody == null || scrollBody.getVisibility() != View.VISIBLE) return false;
            float y = ev.getY();
            return y >= scrollBody.getTop() && y <= scrollBody.getBottom();
        }

        private boolean hasScrollableHorizontalChild(View v, float localX, float localY) {
            if (v == null || v.getVisibility() != View.VISIBLE) return false;
            if (v instanceof MobileSectionGroup.SegmentedTrackView || v instanceof AbsSeekBar) {
                return true;
            }
            if (v instanceof HorizontalScrollView) {
                return v.canScrollHorizontally(-1) || v.canScrollHorizontally(1);
            }
            if (v instanceof ViewGroup) {
                ViewGroup vg = (ViewGroup) v;
                for (int i = 0; i < vg.getChildCount(); i++) {
                    View c = vg.getChildAt(i);
                    float cx = localX - c.getLeft() + vg.getScrollX();
                    float cy = localY - c.getTop() + vg.getScrollY();
                    if (cx >= 0f
                            && cx <= c.getWidth()
                            && cy >= 0f
                            && cy <= c.getHeight()
                            && hasScrollableHorizontalChild(c, cx, cy)) {
                        return true;
                    }
                }
            }
            return false;
        }

        @Override
        public boolean onInterceptTouchEvent(MotionEvent ev) {
            if (host == null || onDismissRequest == null) {
                return super.onInterceptTouchEvent(ev);
            }
            int action = ev.getActionMasked();
            if (action == MotionEvent.ACTION_DOWN) {
                tracking = false;
                downRawX = ev.getRawX();
                downRawY = ev.getRawY();
                startedInScrollBody = isTouchInsideScrollBody(ev);
                startTranslation = sideMode ? getTranslationX() : getTranslationY();
                recycleVelocity();
                velocityTracker = VelocityTracker.obtain();
                velocityTracker.addMovement(ev);
                // Catching sheet mid-spring immediately interrupts the spring!
                if (springBackStep != null && Math.abs(startTranslation) > 1f) {
                    stopSpringBack();
                    tracking = true;
                    return true;
                }
                return false;
            }
            if (action == MotionEvent.ACTION_MOVE) {
                if (velocityTracker != null) velocityTracker.addMovement(ev);
                float dx = ev.getRawX() - downRawX;
                float dy = ev.getRawY() - downRawY;
                if (sideMode) {
                    if (dx > touchSlop
                            && Math.abs(dx) > Math.abs(dy) * 1.25f
                            && !hasScrollableHorizontalChild(this, ev.getX(), ev.getY())) {
                        tracking = true;
                        downRawX = ev.getRawX();
                        startTranslation = getTranslationX();
                        return true;
                    }
                } else {
                    if (Math.abs(dy) > touchSlop && Math.abs(dy) > Math.abs(dx) * 1.25f) {
                        if (!startedInScrollBody) {
                            tracking = true;
                            downRawY = ev.getRawY();
                            startTranslation = getTranslationY();
                            return true;
                        }
                        if (dy > 0f && scrollBody != null && scrollBody.getScrollY() <= 0) {
                            tracking = true;
                            downRawY = ev.getRawY();
                            startTranslation = getTranslationY();
                            return true;
                        }
                    }
                }
            } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                tracking = false;
                recycleVelocity();
            }
            return super.onInterceptTouchEvent(ev);
        }

        @Override
        public boolean onTouchEvent(MotionEvent ev) {
            if (host == null || onDismissRequest == null) {
                return super.onTouchEvent(ev);
            }
            int action = ev.getActionMasked();
            if (velocityTracker != null) {
                velocityTracker.addMovement(ev);
            }
            if (action == MotionEvent.ACTION_DOWN) {
                downRawX = ev.getRawX();
                downRawY = ev.getRawY();
                startTranslation = sideMode ? getTranslationX() : getTranslationY();
                if (springBackStep != null) {
                    stopSpringBack();
                    tracking = true;
                }
                return true;
            }
            if (action == MotionEvent.ACTION_MOVE) {
                float delta = sideMode ? (ev.getRawX() - downRawX) : (ev.getRawY() - downRawY);
                if (!tracking) {
                    float other = sideMode ? (ev.getRawY() - downRawY) : (ev.getRawX() - downRawX);
                    if (Math.abs(delta) > touchSlop && Math.abs(delta) > Math.abs(other) * 1.2f) {
                        tracking = true;
                        downRawX = ev.getRawX();
                        downRawY = ev.getRawY();
                        startTranslation = sideMode ? getTranslationX() : getTranslationY();
                        delta = 0f;
                    } else {
                        return true;
                    }
                }
                float raw = startTranslation + delta;
                float extent = sideMode ? host.dp(36) : host.dp(48);
                float applied = raw >= 0f ? raw : -MobileMotion.rubberBand(-raw, extent);
                if (sideMode) {
                    setTranslationX(applied);
                } else {
                    setTranslationY(applied);
                }
                updateBackdropAlphaForOffset(applied);
                return true;
            }
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                float vel = 0f;
                if (velocityTracker != null) {
                    velocityTracker.computeCurrentVelocity(1000);
                    vel =
                            sideMode
                                    ? velocityTracker.getXVelocity()
                                    : velocityTracker.getYVelocity();
                }
                recycleVelocity();
                boolean wasTracking = tracking;
                tracking = false;
                if (!wasTracking) {
                    return true;
                }
                float currentOffset = sideMode ? getTranslationX() : getTranslationY();
                float size =
                        sideMode
                                ? Math.max(host.dp(180), getWidth())
                                : Math.max(host.dp(140), getHeight());
                float flingThreshold = host.dp(900);
                if (action == MotionEvent.ACTION_UP
                        && MobileMotion.shouldDismissSheetOnRelease(
                                currentOffset, vel, size, 0.30f, flingThreshold)) {
                    onDismissRequest.run();
                } else {
                    springBackToRest(currentOffset, vel);
                }
                return true;
            }
            return super.onTouchEvent(ev);
        }

        private void updateBackdropAlphaForOffset(float offsetPx) {
            if (backdrop == null) return;
            float denom = sideMode ? Math.max(1f, getWidth()) : Math.max(1f, getHeight());
            float progress = Math.max(0f, Math.min(1f, offsetPx / denom));
            backdrop.setAlpha(1f - progress * 0.72f);
        }

        private void springBackToRest(float startOffset, float initialVelocity) {
            stopSpringBack();
            if (MobileMotion.isReduced(host) || Math.abs(startOffset) < 0.5f) {
                if (sideMode) setTranslationX(0f);
                else setTranslationY(0f);
                if (backdrop != null) backdrop.setAlpha(1f);
                return;
            }
            final MotionSpring spring =
                    new MotionSpring(
                            startOffset,
                            MotionTokens.SPRING_PLAYER_TRANSITION.motionSpringFrequency,
                            0.5f);
            spring.velocity = Math.max(-4000f, Math.min(4000f, initialVelocity));
            spring.target(0f);
            springBackStep =
                    dt -> {
                        if (!UiCompat.isAttached(this)) {
                            springBackStep = null;
                            return false;
                        }
                        boolean moving = spring.step(dt);
                        if (sideMode) setTranslationX(spring.value);
                        else setTranslationY(spring.value);
                        updateBackdropAlphaForOffset(spring.value);
                        if (!moving) {
                            if (sideMode) setTranslationX(0f);
                            else setTranslationY(0f);
                            if (backdrop != null) backdrop.setAlpha(1f);
                            springBackStep = null;
                        }
                        return moving;
                    };
            MotionLoop.add(springBackStep);
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            int effectiveMax = maxHeightPx;
            int hMode = MeasureSpec.getMode(heightMeasureSpec);
            int hSize = MeasureSpec.getSize(heightMeasureSpec);
            if (effectiveMax > 0) {
                int bound =
                        hMode == MeasureSpec.UNSPECIFIED
                                ? effectiveMax
                                : Math.min(hSize, effectiveMax);
                heightMeasureSpec = MeasureSpec.makeMeasureSpec(bound, MeasureSpec.AT_MOST);
                effectiveMax = bound;
            } else if (hMode != MeasureSpec.UNSPECIFIED) {
                effectiveMax = hSize;
            }

            if (scrollBody != null && effectiveMax > 0) {
                int chromeH = getPaddingTop() + getPaddingBottom();
                int childHSpec = MeasureSpec.makeMeasureSpec(effectiveMax, MeasureSpec.AT_MOST);
                for (int i = 0; i < getChildCount(); i++) {
                    View child = getChildAt(i);
                    if (child == scrollBody || child.getVisibility() == View.GONE) continue;
                    // Respect child LayoutParams (e.g. 4dp drag handle) instead of passing
                    // AT_MOST(effectiveMax) raw to View.onMeasure which returns effectiveMax!
                    measureChildWithMargins(child, widthMeasureSpec, 0, childHSpec, 0);
                    chromeH += child.getMeasuredHeight();
                    if (child.getLayoutParams() instanceof MarginLayoutParams) {
                        MarginLayoutParams mlp = (MarginLayoutParams) child.getLayoutParams();
                        chromeH += mlp.topMargin + mlp.bottomMargin;
                    }
                }
                int remaining =
                        computeRemainingScrollHeightPx(effectiveMax, chromeH, minScrollBodyPx);
                scrollBody.setMaxHeightPx(remaining);
            }

            super.onMeasure(widthMeasureSpec, heightMeasureSpec);
        }
    }

    static final class MaxHeightScrollView extends ScrollView {
        private int maxHeightPx;

        MaxHeightScrollView(Context context) {
            super(context);
        }

        void setMaxHeightPx(int px) {
            this.maxHeightPx = px;
        }

        @Override
        protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            if (maxHeightPx > 0) {
                int mode = MeasureSpec.getMode(heightMeasureSpec);
                int size = MeasureSpec.getSize(heightMeasureSpec);
                int bound =
                        mode == MeasureSpec.UNSPECIFIED ? maxHeightPx : Math.min(size, maxHeightPx);
                heightMeasureSpec = MeasureSpec.makeMeasureSpec(bound, MeasureSpec.AT_MOST);
            }
            super.onMeasure(widthMeasureSpec, heightMeasureSpec);
        }
    }
}

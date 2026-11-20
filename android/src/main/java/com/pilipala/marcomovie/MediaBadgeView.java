package com.pilipala.marcomovie;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.InputStream;
import java.util.List;

/**
 * Plain-text typography capsule pills for media specification badges on Android TV, phone, and
 * tablet.
 *
 * <p>Uses lightweight {@link GradientDrawable} pills with zero blur/shader effects so Android TV
 * stays >= 50fps and 100/110/120% UI scaling never clips text or focus rings. Zero trademarked
 * graphic logos are ever rendered.
 */
final class MediaBadgeView {
    private static volatile boolean assetAttempted;

    private MediaBadgeView() {}

    static void ensureAssetsLoaded(Context context) {
        if (assetAttempted || context == null) return;
        synchronized (MediaBadgeView.class) {
            if (assetAttempted) return;
            assetAttempted = true;
            InputStream in = null;
            try {
                in = context.getAssets().open("ui-spec/badge-rules.json");
                MediaBadges.loadDefaultFromStream(in);
            } catch (Exception ignored) {
                // Built-in rules in MediaBadges match shared/ui-spec/badge-rules.json 1:1.
            } finally {
                if (in != null) {
                    try {
                        in.close();
                    } catch (Exception ignored) {
                    }
                }
            }
        }
    }

    static List<MediaBadges.Badge> extractForLine(
            Context context, String remarks, Cms.Line line, Cms.Episode episode) {
        ensureAssetsLoaded(context);
        String lineName = line == null ? null : line.name;
        Cms.Episode target = episode;
        if (target == null && line != null && line.episodes != null && !line.episodes.isEmpty()) {
            target = line.episodes.get(0);
        }
        String epName = target == null ? null : target.name;
        String epUrl = target == null ? null : target.url;
        return MediaBadges.extractBadgesFromSources(remarks, lineName, epName, epUrl);
    }

    static LinearLayout createRow(MainActivity a, String tag) {
        LinearLayout row = a.row();
        row.setTag(tag);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setClipChildren(false);
        row.setClipToPadding(false);
        row.setVisibility(View.GONE);
        return row;
    }

    static void populateRow(
            MainActivity a,
            ViewGroup container,
            List<MediaBadges.Badge> badges,
            int maxBadges,
            boolean compact,
            boolean tvStyle) {
        if (container == null) return;
        container.removeAllViews();
        if (badges == null || badges.isEmpty() || maxBadges == 0) {
            container.setVisibility(View.GONE);
            return;
        }
        int limit = maxBadges > 0 ? Math.min(maxBadges, badges.size()) : badges.size();
        for (int i = 0; i < limit; i++) {
            MediaBadges.Badge badge = badges.get(i);
            TextView pill = createPill(a, badge, compact, tvStyle);
            ViewGroup.MarginLayoutParams lp;
            if (container instanceof LinearLayout) {
                LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(-2, -2);
                if (i > 0) llp.leftMargin = a.dp(compact ? 5 : 7);
                lp = llp;
            } else {
                ViewGroup.MarginLayoutParams mlp = new ViewGroup.MarginLayoutParams(-2, -2);
                mlp.rightMargin = a.dp(compact ? 5 : 7);
                mlp.bottomMargin = a.dp(compact ? 4 : 6);
                lp = mlp;
            }
            container.addView(pill, lp);
        }
        container.setVisibility(View.VISIBLE);
    }

    static TextView createPill(
            MainActivity a, MediaBadges.Badge badge, boolean compact, boolean tvStyle) {
        int[] palette = colorsForStyle(badge.style);
        int textColor = palette[0];
        int fillColor = palette[1];
        int strokeColor = palette[2];

        float textSp = compact ? 10.5f : (tvStyle ? 12.0f : 11.5f);
        TextView tv = a.text(badge.label, textSp, textColor);
        tv.setTag("media-badge:" + badge.id);
        tv.setSingleLine(true);
        tv.setEllipsize(TextUtils.TruncateAt.END);
        tv.setIncludeFontPadding(false);
        tv.setTypeface(null, Typeface.BOLD);
        tv.setGravity(Gravity.CENTER);
        tv.setLetterSpacing(0.02f);
        int padH = a.dp(compact ? 7 : (tvStyle ? 10 : 9));
        int padV = a.dp(compact ? 3 : (tvStyle ? 4.5f : 3.5f));
        tv.setPadding(padH, padV, padH, padV);
        tv.setBackground(pillDrawable(a, fillColor, strokeColor, false));
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, textSp);
        return tv;
    }

    static void applyFocusHighlight(
            MainActivity a, TextView pill, MediaBadges.Badge badge, boolean focused) {
        if (pill == null || badge == null) return;
        int[] palette = colorsForStyle(badge.style);
        int fill = focused ? brightenAlpha(palette[1], 0x99) : palette[1];
        int stroke = focused ? 0xffffffff : palette[2];
        pill.setBackground(pillDrawable(a, fill, stroke, focused));
    }

    private static GradientDrawable pillDrawable(
            MainActivity a, int fillColor, int strokeColor, boolean focused) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(fillColor);
        gd.setCornerRadius(a.dp(999));
        gd.setStroke(Math.max(1, a.dp(focused ? 1.5f : 0.9f)), strokeColor);
        return gd;
    }

    private static int brightenAlpha(int argb, int minAlpha) {
        int a = Math.max((argb >>> 24) & 0xff, minAlpha);
        return (a << 24) | (argb & 0x00ffffff);
    }

    /** Returns {textColor, fillColor, strokeColor} for a badge-rules.json style key. */
    static int[] colorsForStyle(String style) {
        if ("uhdGold".equals(style)) {
            return new int[] {0xffffdf7a, 0x38d97706, 0x78f59e0b};
        }
        if ("hdCyan".equals(style)) {
            return new int[] {0xff7dd3fc, 0x340284c7, 0x6e38bdf8};
        }
        if ("sdNeutral".equals(style)) {
            return new int[] {0xffd4d4d8, 0x2e52525b, 0x5ea1a1aa};
        }
        if ("visionPurple".equals(style)) {
            return new int[] {0xffd8b4fe, 0x3a7e22ce, 0x78a855f7};
        }
        if ("hdrBlue".equals(style)) {
            return new int[] {0xff93c5fd, 0x361d4ed8, 0x7260a5fa};
        }
        if ("discEmerald".equals(style)) {
            return new int[] {0xff6ee7b7, 0x34047857, 0x6e34d399};
        }
        if ("streamTeal".equals(style)) {
            return new int[] {0xff5eead4, 0x320f766e, 0x682dd4bf};
        }
        if ("spatialAudio".equals(style)) {
            return new int[] {0xfffdba74, 0x38c2410c, 0x74fb923c};
        }
        if ("standardAudio".equals(style)) {
            return new int[] {0xffbfdbfe, 0x2e334155, 0x6294a3b8};
        }
        if ("codecSlate".equals(style)) {
            return new int[] {0xffe2e8f0, 0x2c334155, 0x5c94a3b8};
        }
        if ("platformTag".equals(style)) {
            return new int[] {0xfff0abfc, 0x2e581c87, 0x62c084fc};
        }
        if ("premiumCombo".equals(style)) {
            return new int[] {0xfffef08a, 0x446d28d9, 0x88facc15};
        }
        return new int[] {0xffe5e7eb, 0x2e374151, 0x5c9ca3af};
    }
}

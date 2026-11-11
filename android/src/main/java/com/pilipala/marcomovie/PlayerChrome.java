package com.pilipala.marcomovie;

import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;

/** Three independent floating regions with one visibility/focus owner. */
final class PlayerChrome {
    final MainActivity a;
    final boolean modernTv;
    final FrameLayout overlay;
    final View topShade, bottomShade;
    final LinearLayout dock, progress, heading;
    final LinearLayout actionHost, badgeRow;
    final LinearLayout loadingPill;
    final LinearLayout centerRow;
    final LinearLayout topActions;
    final Button backBtn;
    final TextView rewindBtn, forwardBtn;
    final TextView loadingText, episodeLabel, titleView, seekHint, wallClock, cardTitleView;
    final Button fsBtn;
    final StateGlyph state;
    final TextView resolution;
    final Cms.Video chromeVideo;
    boolean loading = true;
    boolean progressOnlyMode = false;
    final Rect windowInsets = new Rect();
    boolean layoutPending;
    String lastBadgeSignature = "";
    String lastWallClock = "";

    static float modernUnit(MainActivity a) {
        int w = Math.max(1, a.windowWidth());
        int h = Math.max(1, a.windowHeight());
        return Math.min(Math.max(w, h) / 960f, Math.min(w, h) / 540f);
    }

    static int vp(MainActivity a, float v) {
        return Math.max(1, Math.round(v * modernUnit(a)));
    }

    private GradientDrawable chromeSurface(int color, float radiusDp, int strokeColor) {
        GradientDrawable d = a.bg(color, radiusDp);
        if (strokeColor != 0) {
            d.setStroke(Math.max(1, a.dp(1)), strokeColor);
        }
        return d;
    }

    private GradientDrawable modernSurface(int color, float radiusU, int strokeColor) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(modernUnit(a) * radiusU);
        if (strokeColor != 0) {
            d.setStroke(Math.max(1, Math.round(modernUnit(a) * .75f)), strokeColor);
        }
        return d;
    }

    private String formatWallTime() {
        return String.valueOf(
                android.text.format.DateFormat.format("HH:mm", System.currentTimeMillis()));
    }

    private CharSequence styledWallTime(String raw) {
        if (raw == null) return "";
        int colon = raw.indexOf(':');
        if (colon < 0) return raw;
        android.text.SpannableString sp = new android.text.SpannableString(raw);
        sp.setSpan(
                new android.text.style.ReplacementSpan() {
                    @Override
                    public int getSize(
                            Paint paint,
                            CharSequence text,
                            int start,
                            int end,
                            Paint.FontMetricsInt fm) {
                        return Math.round(paint.measureText(":") * 1.15f);
                    }

                    @Override
                    public void draw(
                            Canvas canvas,
                            CharSequence text,
                            int start,
                            int end,
                            float x,
                            int top,
                            int y,
                            int bottom,
                            Paint paint) {
                        float w = Math.round(paint.measureText(":") * 1.15f);
                        float cx = x + w * .5f;
                        float capH = -paint.ascent() * .74f;
                        float cy = y - capH * .5f;
                        float gap = capH * .24f;
                        float r = Math.max(1.2f, paint.getTextSize() * .058f);
                        Paint.Style prevStyle = paint.getStyle();
                        paint.setStyle(Paint.Style.FILL);
                        canvas.drawCircle(cx, cy - gap, r, paint);
                        canvas.drawCircle(cx, cy + gap, r, paint);
                        paint.setStyle(prevStyle);
                    }
                },
                colon,
                colon + 1,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        return sp;
    }

    private String formatCardTitle(Cms.Video video, Cms.Episode episode) {
        String base = video != null && video.title != null ? video.title.trim() : "";
        String ep = episode != null && episode.name != null ? episode.name.trim() : "";
        boolean multi =
                a.activeLine != null
                        && a.activeLine.episodes != null
                        && a.activeLine.episodes.size() > 1;
        if (!ep.isEmpty() && !ep.equalsIgnoreCase(base)) {
            if (multi
                    || (!"正片".equals(ep)
                            && !"HD".equalsIgnoreCase(ep)
                            && !"4K".equalsIgnoreCase(ep)
                            && !"1080P".equalsIgnoreCase(ep)
                            && !"超清".equals(ep))) {
                return base.isEmpty() ? ep : base + " · " + ep;
            }
        }
        return base.isEmpty() ? ep : base;
    }

    private void renderBadgePills(java.util.List<String> badges) {
        if (badgeRow == null) return;
        float u = modernUnit(a);
        StringBuilder sig = new StringBuilder();
        sig.append(Math.round(u * 100)).append(':');
        for (int i = 0; i < badges.size(); i++) {
            if (i > 0) sig.append('|');
            sig.append(badges.get(i));
        }
        String nextSig = sig.toString();
        if (nextSig.equals(lastBadgeSignature)) return;
        lastBadgeSignature = nextSig;
        badgeRow.removeAllViews();
        for (int i = 0; i < badges.size(); i++) {
            String label = badges.get(i);
            if (label == null || label.isEmpty()) continue;
            TextView pill = a.text(label, 9f, 0xffcfd6e2);
            pill.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 8.8f);
            pill.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                pill.setLetterSpacing(0.03f);
            }
            pill.setSingleLine(true);
            pill.setIncludeFontPadding(false);
            pill.setGravity(Gravity.CENTER);
            pill.setPadding(
                    Math.round(u * 6.5f),
                    Math.round(u * 2.2f),
                    Math.round(u * 6.5f),
                    Math.round(u * 2.2f));
            pill.setBackground(modernSurface(0x1cffffff, 4.2f, 0x1effffff));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = Math.round(u * 5f);
            badgeRow.addView(pill, lp);
        }
    }

    PlayerChrome(MainActivity host, Cms.Video video, Cms.Episode episode, boolean live) {
        a = host;
        chromeVideo = video;
        modernTv = a.isTvDevice() && a.prefs.getInt(Prefs.TV_PLAYER_STYLE, 0) == 0;
        overlay = new FrameLayout(a);
        overlay.setTag("player-chrome");
        overlay.setClipChildren(true);
        overlay.setClipToPadding(true);
        overlay.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    if (l != ol || t != ot || r != or || b != ob) scheduleLayout();
                });
        topShade = new View(a);
        if (a.isTvDevice()) {
            topShade.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {modernTv ? 0x8c000000 : 0xc4000000, 0x00000000}));
        } else {
            topShade.setBackgroundColor(Color.TRANSPARENT);
        }
        float u = modernUnit(a);
        overlay.addView(
                topShade,
                new FrameLayout.LayoutParams(-1, modernTv ? vp(a, 110) : a.dp(160), Gravity.TOP));
        bottomShade = new View(a);
        if (a.isTvDevice()) {
            bottomShade.setBackground(
                    new GradientDrawable(
                            GradientDrawable.Orientation.BOTTOM_TOP,
                            new int[] {modernTv ? 0x84000000 : 0xb8000000, 0x00000000}));
        } else {
            bottomShade.setBackgroundColor(Color.TRANSPARENT);
        }
        overlay.addView(
                bottomShade,
                new FrameLayout.LayoutParams(
                        -1, modernTv ? vp(a, 176) : a.dp(210), Gravity.BOTTOM));
        heading = a.vertical();
        heading.setTag("player-heading");
        if (!a.isTvDevice()) {
            topActions = a.row();
            topActions.setPadding(0, 0, 0, a.dp(8));
            backBtn = a.navButton("‹ 返回", "player-back", a::leavePlayback);
            backBtn.setTextColor(MainActivity.WHITE);
            backBtn.setBackground(chromeSurface(0xcc22222a, 17, 0x33ffffff));
            topActions.addView(backBtn, new LinearLayout.LayoutParams(-2, a.dp(34)));
            View spacer = new View(a);
            topActions.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
            // Orientation toggle lives only on the progress row ("全屏横屏 / 退出全屏").
            heading.addView(topActions, new LinearLayout.LayoutParams(-1, -2));
        } else {
            topActions = null;
            backBtn = null;
        }
        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleView = a.text(video.title, a.isPortrait() ? 20 : 26, MainActivity.WHITE);
        if (modernTv) {
            titleView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 20.5f);
            titleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
            titleView.setIncludeFontPadding(false);
            titleView.setShadowLayer(u * 3f, 0, u * 1.2f, 0xaa000000);
        } else {
            titleView.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
            titleView.getPaint().setFakeBoldText(true);
            titleView.setShadowLayer(a.dp(4), 0, a.dp(2), 0xdd000000);
        }
        titleView.setSingleLine();
        titleView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams titleLp =
                modernTv
                        ? new LinearLayout.LayoutParams(0, -2, 1)
                        : new LinearLayout.LayoutParams(-2, -2);
        titleLp.rightMargin = modernTv ? vp(a, 14) : a.dp(10);
        titleRow.addView(titleView, titleLp);
        resolution = a.text("分辨率读取中", 11, 0xffeeeef2);
        resolution.setTag("player-resolution");
        resolution.setSingleLine();
        resolution.setEllipsize(android.text.TextUtils.TruncateAt.END);
        resolution.setPadding(a.dp(9), a.dp(3), a.dp(9), a.dp(3));
        resolution.setBackground(chromeSurface(0xb824242c, 10, 0x28ffffff));
        if (modernTv) resolution.setVisibility(View.GONE);
        titleRow.addView(resolution, new LinearLayout.LayoutParams(-2, -2));
        if (modernTv) {
            lastWallClock = formatWallTime();
            wallClock = a.text("", 15f, 0xcaf0f4fb);
            wallClock.setTag("player-wall-clock");
            wallClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 15.0f);
            wallClock.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
            wallClock.setFontFeatureSettings("tnum");
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                wallClock.setLetterSpacing(0.055f);
            }
            wallClock.setIncludeFontPadding(false);
            wallClock.setSingleLine();
            wallClock.setShadowLayer(u * 2.2f, 0, u * .8f, 0x66000000);
            wallClock.setText(styledWallTime(lastWallClock));
            titleRow.addView(wallClock, new LinearLayout.LayoutParams(-2, -2));
        } else {
            wallClock = null;
        }
        heading.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));
        String line = a.activeLine == null ? "" : a.activeLine.name;
        episodeLabel =
                a.text(episode.name + (line.isEmpty() ? "" : "  ·  " + line), 14, 0xffdddddf);
        episodeLabel.setTag("player-episode");
        episodeLabel.setSingleLine();
        episodeLabel.setEllipsize(android.text.TextUtils.TruncateAt.END);
        episodeLabel.setPadding(0, a.dp(6), 0, 0);
        if (modernTv) episodeLabel.setVisibility(View.GONE);
        heading.addView(episodeLabel);
        a.playStatus = a.text("正在加载所选剧集…", 12, MainActivity.MUTED);
        if (modernTv) {
            a.playStatus.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11f);
            a.playStatus.setPadding(0, vp(a, 3), 0, 0);
        } else {
            a.playStatus.setPadding(0, a.dp(6), 0, 0);
        }
        heading.addView(a.playStatus);
        FrameLayout.LayoutParams top = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
        int width = a.windowWidth();
        int initialCardW = Math.max(vp(a, 260), Math.min(vp(a, 824), Math.round(width * 0.855f)));
        int sideMargin =
                a.isPortrait()
                        ? a.dp(20)
                        : (modernTv ? Math.max(vp(a, 24), (width - initialCardW) / 2) : a.dp(44));
        top.setMargins(sideMargin, modernTv ? vp(a, 22) : a.dp(24), sideMargin, 0);
        overlay.addView(heading, top);

        boolean mobileLandscape = !a.isTvDevice() && !a.isPortrait();
        if (modernTv) {
            fsBtn = null;
            dock = a.vertical();
            dock.setTag("player-dock");
            dock.setPadding(vp(a, 20), vp(a, 12.5f), vp(a, 20), vp(a, 11.5f));
            dock.setClipChildren(false);
            dock.setClipToPadding(false);
            dock.setClipToOutline(true);
            int cardColor =
                    a.prefs.getBoolean(Prefs.REDUCED_TRANSPARENCY, false) ? 0xf2191b22 : 0xdc181a21;
            dock.setBackground(modernSurface(cardColor, 19f, 0x24ffffff));
            UiCompat.setElevation(dock, vp(a, 10));

            LinearLayout headerRow = a.row();
            headerRow.setGravity(Gravity.CENTER_VERTICAL);
            headerRow.setClipChildren(false);
            headerRow.setClipToPadding(false);
            cardTitleView = a.text(formatCardTitle(video, episode), 14.5f, 0xfff5f7fb);
            cardTitleView.setTag("player-card-title");
            cardTitleView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 14.5f);
            cardTitleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            cardTitleView.setIncludeFontPadding(false);
            cardTitleView.setSingleLine(true);
            cardTitleView.setEllipsize(android.text.TextUtils.TruncateAt.END);
            LinearLayout.LayoutParams ctLp = new LinearLayout.LayoutParams(0, -2, 1);
            ctLp.rightMargin = vp(a, 14);
            headerRow.addView(cardTitleView, ctLp);

            actionHost = a.row();
            actionHost.setTag("player-action-host");
            actionHost.setGravity(Gravity.CENTER_VERTICAL | Gravity.RIGHT);
            actionHost.setClipChildren(false);
            actionHost.setClipToPadding(false);
            headerRow.addView(actionHost, new LinearLayout.LayoutParams(-2, -2));
            dock.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

            progress = a.vertical();
            progress.setTag("player-progress");
            progress.setClipChildren(false);
            progress.setClipToPadding(false);
            progress.setVisibility(live ? View.GONE : View.VISIBLE);
            LinearLayout.LayoutParams progLp = new LinearLayout.LayoutParams(-1, -2);
            progLp.topMargin = vp(a, 6);
            progLp.bottomMargin = vp(a, 5);
            dock.addView(progress, progLp);

            LinearLayout metaRow = a.row();
            metaRow.setGravity(Gravity.CENTER_VERTICAL);
            badgeRow = a.row();
            badgeRow.setTag("player-badges");
            badgeRow.setGravity(Gravity.CENTER_VERTICAL);
            metaRow.addView(badgeRow, new LinearLayout.LayoutParams(0, -2, 1));
            renderBadgePills(java.util.Collections.singletonList(live ? "直播频道" : "准备播放"));

            seekHint = a.text("", 11f, 0xffdce2ec);
            seekHint.setTag("player-seek-hint");
            seekHint.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 10.5f);
            seekHint.setIncludeFontPadding(false);
            seekHint.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            seekHint.setPadding(0, 0, vp(a, 10), 0);
            seekHint.setVisibility(View.GONE);
            metaRow.addView(seekHint, new LinearLayout.LayoutParams(-2, -2));

            a.playClock = a.text(live ? "直播" : "--:-- / --:--", 11f, 0xffe4e9f2);
            a.playClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.0f);
            a.playClock.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            a.playClock.setFontFeatureSettings("tnum");
            a.playClock.setIncludeFontPadding(false);
            a.playClock.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            metaRow.addView(a.playClock, new LinearLayout.LayoutParams(-2, -2));
            LinearLayout.LayoutParams metaLp = new LinearLayout.LayoutParams(-1, -2);
            if (live) metaLp.topMargin = vp(a, 8);
            dock.addView(metaRow, metaLp);

            FrameLayout.LayoutParams dockLp =
                    new FrameLayout.LayoutParams(
                            initialCardW, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            dockLp.bottomMargin = vp(a, 22);
            overlay.addView(dock, dockLp);
        } else {
            actionHost = null;
            badgeRow = null;
            cardTitleView = null;
            progress = a.vertical();
            progress.setTag("player-progress");
            LinearLayout clockRow = a.row();
            a.playClock = a.text("--:-- / --:--", 12, MainActivity.WHITE);
            a.playClock.setGravity(Gravity.LEFT | Gravity.CENTER_VERTICAL);
            a.playClock.setPadding(a.dp(8), 0, a.dp(12), 0);
            clockRow.addView(a.playClock, new LinearLayout.LayoutParams(0, -2, 1));
            seekHint = a.text("", 12, 0xffe5e7eb);
            seekHint.setTag("player-seek-hint");
            seekHint.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            seekHint.setPadding(a.dp(8), 0, a.dp(8), 0);
            seekHint.setVisibility(View.GONE);
            clockRow.addView(seekHint, new LinearLayout.LayoutParams(-2, -2));
            if (!a.isTvDevice()) {
                fsBtn =
                        a.navButton(
                                a.isPortrait() ? "⛶ 全屏横屏" : "⛶ 退出全屏",
                                "player-fullscreen",
                                a::togglePlayerOrientation);
                fsBtn.setTextColor(MainActivity.WHITE);
                fsBtn.setTextSize(12);
                fsBtn.setMinHeight(a.dp(30));
                fsBtn.setMinimumHeight(a.dp(30));
                fsBtn.setPadding(a.dp(12), a.dp(4), a.dp(12), a.dp(4));
                fsBtn.setBackground(chromeSurface(0xcc22222a, 15, 0x33ffffff));
                clockRow.addView(fsBtn, new LinearLayout.LayoutParams(-2, a.dp(30)));
            } else {
                fsBtn = null;
            }
            progress.addView(clockRow, new LinearLayout.LayoutParams(-1, -2));
            FrameLayout.LayoutParams track;
            if (a.isTvDevice()) {
                track =
                        new FrameLayout.LayoutParams(
                                Math.min(a.dp(760), Math.max(a.dp(220), width - a.dp(48))),
                                -2,
                                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                track.bottomMargin = a.dp(94);
            } else {
                int trackSideMargin = a.dp(mobileLandscape ? 20 : 22);
                track =
                        new FrameLayout.LayoutParams(
                                Math.max(a.dp(140), width - trackSideMargin * 2),
                                -2,
                                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                track.leftMargin = trackSideMargin;
                track.rightMargin = trackSideMargin;
                track.bottomMargin = a.dp(mobileLandscape ? 12 : 20);
            }
            // Browsing live channels leaves a live session available for returning.
            // Only the currently playing source decides whether seeking is hidden.
            progress.setVisibility(live ? View.GONE : View.VISIBLE);
            overlay.addView(progress, track);

            dock = a.vertical();
            dock.setTag("player-dock");
            if (a.isTvDevice()) {
                dock.setPadding(a.dp(6), a.dp(5), a.dp(6), a.dp(5));
            } else {
                dock.setPadding(a.dp(3), a.dp(5), a.dp(3), a.dp(5));
            }
            dock.setClipChildren(true);
            dock.setClipToPadding(true);
            dock.setClipToOutline(true);
            dock.setBackground(chromeSurface(0xd81c1c22, a.isTvDevice() ? 26 : 24, 0x2affffff));
            UiCompat.setElevation(dock, a.dp(10));
            FrameLayout.LayoutParams dockLp;
            if (a.isTvDevice()) {
                dockLp =
                        new FrameLayout.LayoutParams(
                                Math.min(a.dp(612), Math.max(a.dp(240), width - a.dp(32))),
                                -2,
                                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
                dockLp.bottomMargin = a.dp(16);
            } else {
                dockLp =
                        new FrameLayout.LayoutParams(
                                a.dp(mobileLandscape ? 48 : 52),
                                a.dp(mobileLandscape ? 276 : 356),
                                Gravity.RIGHT | Gravity.BOTTOM);
                dockLp.rightMargin = a.dp(10);
                dockLp.bottomMargin = a.dp(mobileLandscape ? 66 : 82);
            }
            overlay.addView(dock, dockLp);
        }

        state = new StateGlyph();
        state.setTag("player-state");
        state.setFocusable(false);
        state.setVisibility(View.GONE);
        state.setOnClickListener(
                v -> {
                    a.togglePlayback();
                    a.showControls(true);
                });
        if (!a.isTvDevice()) {
            centerRow = a.row();
            centerRow.setGravity(Gravity.CENTER);
            rewindBtn = buildSeekCircle("↺ 15s", -15000);
            forwardBtn = buildSeekCircle("15s ↻", 15000);
            LinearLayout.LayoutParams sideLp = new LinearLayout.LayoutParams(a.dp(58), a.dp(58));
            LinearLayout.LayoutParams centerLp = new LinearLayout.LayoutParams(a.dp(76), a.dp(76));
            centerLp.leftMargin = a.dp(28);
            centerLp.rightMargin = a.dp(28);
            centerRow.addView(rewindBtn, sideLp);
            centerRow.addView(state, centerLp);
            centerRow.addView(forwardBtn, sideLp);
            overlay.addView(centerRow, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        } else {
            centerRow = null;
            rewindBtn = null;
            forwardBtn = null;
            overlay.addView(
                    state, new FrameLayout.LayoutParams(a.dp(72), a.dp(72), Gravity.CENTER));
        }
        a.playbackLayer.addView(overlay, new FrameLayout.LayoutParams(-1, -1));

        loadingPill = a.row();
        loadingPill.setTag("player-loading");
        loadingPill.setGravity(Gravity.CENTER_VERTICAL);
        loadingPill.setPadding(a.dp(24), a.dp(16), a.dp(24), a.dp(16));
        loadingPill.setBackground(chromeSurface(0xe01c1c22, 24, 0x2affffff));
        UiCompat.setElevation(loadingPill, a.dp(10));
        loadingPill.addView(
                new PlaybackLoading.Ring(a), new LinearLayout.LayoutParams(a.dp(26), a.dp(26)));
        String epTitle =
                episode != null && episode.name != null && !episode.name.isEmpty()
                        ? " " + episode.name
                        : "";
        loadingText = a.text("正在加载" + epTitle + "…", 14, MainActivity.WHITE);
        loadingText.setPadding(a.dp(14), 0, 0, 0);
        loadingPill.addView(loadingText);
        a.playbackLayer.addView(loadingPill, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        a.playerOverlay = overlay;
        a.controlsVisible = true;
        dock.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    if (b - t != ob - ot) scheduleLayout();
                });
        progress.addOnLayoutChangeListener(
                (view, l, t, r, b, ol, ot, or, ob) -> {
                    if (b - t != ob - ot) scheduleLayout();
                });
        scheduleLayout();
    }

    TextView buildSeekCircle(String label, int deltaMs) {
        TextView btn = a.text(label, 12, MainActivity.WHITE);
        btn.setGravity(Gravity.CENTER);
        btn.setTypeface(null, Typeface.BOLD);
        GradientDrawable bg = a.bg(0x99303034, 29);
        bg.setStroke(a.dp(1), 0x33ffffff);
        btn.setBackground(bg);
        btn.setOnClickListener(
                v -> {
                    if (a.player != null && a.prepared) {
                        int dur = Math.max(1, a.player.getDuration());
                        int cur =
                                a.playbackControls != null
                                        ? a.playbackControls.displayPosition(
                                                a.player.getCurrentPosition())
                                        : a.player.getCurrentPosition();
                        int next = Math.max(0, Math.min(dur, cur + deltaMs));
                        if (a.playbackControls != null) a.playbackControls.recordUserSeek(next);
                        a.player.seekTo(next);
                        if (a.playClock != null && dur > 1) {
                            a.playClock.setText(
                                    PlaybackController.formatTime(next)
                                            + " / "
                                            + PlaybackController.formatTime(dur));
                        }
                    }
                    a.showControls(true);
                });
        return btn;
    }

    void scheduleLayout() {
        if (layoutPending) return;
        layoutPending = true;
        overlay.post(
                () -> {
                    layoutPending = false;
                    if (a.playerChrome == this) relayout();
                });
    }

    void safeInsets(int left, int top, int right, int bottom) {
        windowInsets.set(left, top, right, bottom);
        relayout();
    }

    void relayout() {
        // A rotation request is not a measurement. OEM bars, multi-window and
        // embedded playback can all leave this layer smaller than the display.
        int measuredWidth = overlay.getWidth(), measuredHeight = overlay.getHeight();
        if (measuredWidth <= 0 || measuredHeight <= 0) return;
        boolean portrait = measuredWidth < measuredHeight;
        Rect safe = new Rect(0, 0, measuredWidth, measuredHeight);
        Rect visible = new Rect();
        if (overlay.getLocalVisibleRect(visible)) safe.intersect(visible);
        if (!a.isTvDevice()) {
            int[] location = new int[2];
            overlay.getLocationInWindow(location);
            View decor = a.getWindow().getDecorView();
            if (portrait) {
                safe.left = Math.max(safe.left, windowInsets.left - location[0]);
                safe.top =
                        Math.max(
                                safe.top,
                                Math.min(a.dp(48), Math.max(0, windowInsets.top - location[1])));
                safe.right =
                        Math.min(safe.right, decor.getWidth() - windowInsets.right - location[0]);
                safe.bottom =
                        Math.min(
                                safe.bottom,
                                decor.getHeight()
                                        - Math.min(a.dp(48), windowInsets.bottom)
                                        - location[1]);
            } else {
                int leftCutout = Math.min(a.dp(24), Math.max(0, windowInsets.left - location[0]));
                int rightCutout =
                        Math.min(
                                a.dp(24),
                                Math.max(
                                        0,
                                        windowInsets.right
                                                - Math.max(
                                                        0,
                                                        decor.getWidth()
                                                                - location[0]
                                                                - measuredWidth)));
                safe.left = Math.max(safe.left, leftCutout);
                safe.right = Math.min(safe.right, measuredWidth - rightCutout);
            }
        }
        safe.left = Math.max(0, Math.min(measuredWidth, safe.left));
        safe.top = Math.max(0, Math.min(measuredHeight, safe.top));
        safe.right = Math.max(safe.left, Math.min(measuredWidth, safe.right));
        safe.bottom = Math.max(safe.top, Math.min(measuredHeight, safe.bottom));
        overlay.setPadding(
                safe.left, safe.top, measuredWidth - safe.right, measuredHeight - safe.bottom);
        int width = safe.width(), height = safe.height();
        boolean mobileLandscape = !a.isTvDevice() && !portrait;
        boolean compact = !a.isTvDevice() && (mobileLandscape || height < a.dp(440));
        if (topActions != null && backBtn != null) {
            topActions.setPadding(0, 0, 0, a.dp(compact ? 4 : 8));
            ViewGroup.LayoutParams backLp = backBtn.getLayoutParams();
            int backH = a.dp(compact ? 28 : 34);
            if (backLp != null && backLp.height != backH) {
                backLp.height = backH;
                backBtn.setLayoutParams(backLp);
            }
        }
        if (titleView != null) {
            if (modernTv) {
                titleView.setTextSize(
                        android.util.TypedValue.COMPLEX_UNIT_PX, modernUnit(a) * 20.5f);
            } else {
                titleView.setTextSize(compact ? 17 : (portrait ? 20 : 26));
            }
        }
        boolean ultraShort = !a.isTvDevice() && height < a.dp(325);
        episodeLabel.setTextSize(compact ? 12f : 13.5f);
        episodeLabel.setVisibility(modernTv || ultraShort ? View.GONE : View.VISIBLE);
        if (a.playStatus != null) {
            a.playStatus.setVisibility(
                    compact
                            ? View.GONE
                            : (modernTv && a.prepared && a.playing && !loading
                                    ? View.GONE
                                    : View.VISIBLE));
        }
        if (fsBtn != null) {
            fsBtn.setText(portrait ? "⛶ 全屏横屏" : "⛶ 退出全屏");
        }
        if (centerRow != null && rewindBtn != null && forwardBtn != null) {
            int sideSz = a.dp(compact ? 44 : 54);
            int centerSz = a.dp(compact ? 56 : 70);
            int gap = a.dp(compact ? 20 : 26);
            LinearLayout.LayoutParams rLp = (LinearLayout.LayoutParams) rewindBtn.getLayoutParams();
            LinearLayout.LayoutParams fLp =
                    (LinearLayout.LayoutParams) forwardBtn.getLayoutParams();
            LinearLayout.LayoutParams cLp = (LinearLayout.LayoutParams) state.getLayoutParams();
            if (rLp.width != sideSz || cLp.width != centerSz || cLp.leftMargin != gap) {
                rLp.width = rLp.height = sideSz;
                fLp.width = fLp.height = sideSz;
                cLp.width = cLp.height = centerSz;
                cLp.leftMargin = cLp.rightMargin = gap;
                rewindBtn.setLayoutParams(rLp);
                forwardBtn.setLayoutParams(fLp);
                state.setLayoutParams(cLp);
            }
        }
        if (modernTv) {
            float u = modernUnit(a);
            if (wallClock != null) {
                wallClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 15.0f);
            }
            if (cardTitleView != null) {
                cardTitleView.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 14.5f);
            }
            if (a.playClock != null) {
                a.playClock.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 11.0f);
            }
            if (seekHint != null) {
                seekHint.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, u * 10.5f);
            }
            dock.setPadding(vp(a, 20), vp(a, 12.5f), vp(a, 20), vp(a, 11.5f));
            int cardWidth = Math.max(vp(a, 260), Math.min(vp(a, 824), Math.round(width * 0.855f)));
            place(
                    dock,
                    cardWidth,
                    -2,
                    Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL,
                    0,
                    0,
                    0,
                    vp(a, 22));
            int side = Math.max(vp(a, 24), (width - cardWidth) / 2);
            place(heading, -1, -2, Gravity.TOP, side, Math.min(vp(a, 22), height / 8), side, 0);
        } else if (a.isTvDevice()) {
            dock.setPadding(a.dp(6), a.dp(5), a.dp(6), a.dp(5));
            int edge = Math.min(a.dp(16), width / 8);
            int maxDock = a.dp(612);
            int dockWidth = Math.max(0, Math.min(maxDock, width - edge * 2));
            int dockBottom = a.dp(16);
            place(
                    dock,
                    dockWidth,
                    -2,
                    Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL,
                    0,
                    0,
                    0,
                    dockBottom);
            int left = Math.min(a.dp(24), width / 8);
            int right = left;
            int trackWidth = Math.max(0, Math.min(a.dp(760), width - left - right));
            left += Math.max(0, (width - left - right - trackWidth) / 2);
            int progressHeight = Math.max(progress.getMeasuredHeight(), a.dp(62));
            int bottom = Math.max(a.dp(94), dock.getMeasuredHeight() + a.dp(28));
            bottom = Math.max(0, Math.min(bottom, height - progressHeight));
            place(progress, trackWidth, -2, Gravity.BOTTOM | Gravity.LEFT, left, 0, right, bottom);
            int side = Math.min(a.dp(44), width / 8);
            place(heading, -1, -2, Gravity.TOP, side, Math.min(a.dp(24), height / 8), side, 0);
        } else {
            int sideMargin = Math.min(a.dp(compact ? 20 : 22), Math.max(a.dp(12), width / 16));
            int trackWidth = Math.max(a.dp(120), width - sideMargin * 2);
            int progressHeight = Math.max(progress.getMeasuredHeight(), a.dp(compact ? 46 : 56));
            int bottom = Math.min(a.dp(compact ? 10 : 18), Math.max(0, height - progressHeight));
            place(
                    progress,
                    trackWidth,
                    -2,
                    Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL,
                    sideMargin,
                    0,
                    sideMargin,
                    bottom);
            dock.setPadding(a.dp(3), a.dp(compact ? 4 : 6), a.dp(3), a.dp(compact ? 4 : 6));
            int dockWidth = a.dp(compact ? 48 : 52);
            int dockRight = Math.min(a.dp(10), Math.max(a.dp(6), width / 24));
            int dockBottom = bottom + progressHeight + a.dp(8);
            int dockTop = a.dp(compact ? 12 : 52);
            int availDockH = Math.max(a.dp(96), height - dockBottom - dockTop);
            int dockHeight = Math.min(a.dp(compact ? 286 : 368), availDockH);
            place(
                    dock,
                    dockWidth,
                    dockHeight,
                    Gravity.RIGHT | Gravity.BOTTOM,
                    0,
                    0,
                    dockRight,
                    dockBottom);
            int side = sideMargin;
            int headingRight = Math.max(side, dockWidth + dockRight + a.dp(12));
            place(
                    heading,
                    -1,
                    -2,
                    Gravity.TOP,
                    side,
                    Math.min(a.dp(compact ? 8 : 22), height / 8),
                    headingRight,
                    0);
        }
        if (a.playbackControls != null) {
            a.playbackControls.relayout(compact);
        }
    }

    private void place(
            View view,
            int width,
            int height,
            int gravity,
            int left,
            int top,
            int right,
            int bottom) {
        FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) view.getLayoutParams();
        if (p.width == width
                && p.height == height
                && p.gravity == gravity
                && p.leftMargin == left
                && p.topMargin == top
                && p.rightMargin == right
                && p.bottomMargin == bottom) return;
        p.width = width;
        p.height = height;
        p.gravity = gravity;
        p.setMargins(left, top, right, bottom);
        view.setLayoutParams(p);
    }

    void resolution(int width, int height) {
        if (a.player != null && a.prepared) {
            resolution.setText(a.player.videoResolution());
        } else {
            resolution.setText(width > 0 && height > 0 ? width + " × " + height : "分辨率未知");
        }
    }

    void setLoading(boolean value) {
        loading = value;
        update();
    }

    void switchEpisode(Cms.Episode episode, Cms.Line line) {
        String lineName = line == null || line.name == null ? "" : line.name;
        String epName = episode == null || episode.name == null ? "" : episode.name;
        episodeLabel.setText(epName + (lineName.isEmpty() ? "" : "  ·  " + lineName));
        if (cardTitleView != null) {
            cardTitleView.setText(formatCardTitle(chromeVideo, episode));
        }
        resolution.setText("分辨率读取中");
        String statusMsg = "正在加载" + (epName.isEmpty() ? "" : " " + epName) + "…";
        if (a.playStatus != null) a.playStatus.setText(statusMsg);
        loadingText.setText(statusMsg);
        loading = true;
        update();
    }

    void setProgressOnlyMode(boolean progressOnly) {
        if (this.progressOnlyMode == progressOnly) return;
        this.progressOnlyMode = progressOnly;
        int otherVis = progressOnly ? View.INVISIBLE : View.VISIBLE;
        topShade.setVisibility(otherVis);
        heading.setVisibility(otherVis);
        if (modernTv) {
            dock.setVisibility(View.VISIBLE);
            if (actionHost != null) actionHost.setVisibility(otherVis);
        } else {
            dock.setVisibility(otherVis);
        }
        seekHint.setVisibility(progressOnly ? View.VISIBLE : View.GONE);
        update();
        if (a.playbackControls != null) {
            a.playbackControls.visible(a.controlsVisible);
        }
    }

    void update() {
        if (a.prepared) loading = false;
        if (wallClock != null) {
            String now = formatWallTime();
            if (!now.equals(lastWallClock)) {
                lastWallClock = now;
                wallClock.setText(styledWallTime(now));
            }
        }
        if (a.player != null && a.prepared) {
            resolution.setText(a.player.videoResolution());
            if (modernTv) {
                java.util.List<String> badges = a.player.mediaBadges();
                if (badges != null && !badges.isEmpty()) renderBadgePills(badges);
            }
        }
        if (modernTv && a.playStatus != null) {
            a.playStatus.setVisibility(
                    loading || !a.prepared || !a.playing ? View.VISIBLE : View.GONE);
        }
        if (modernTv && cardTitleView != null && a.activeEpisode != null) {
            String expected = formatCardTitle(chromeVideo, a.activeEpisode);
            if (!expected.contentEquals(cardTitleView.getText())) {
                cardTitleView.setText(expected);
            }
        }
        if (a.playbackControls != null) {
            a.playbackControls.refreshPlayPauseGlyph();
        }
        boolean showSpinner = loading && !a.prepared && a.playbackLoading == null && !a.miniMode;
        loadingPill.setVisibility(showSpinner ? View.VISIBLE : View.GONE);
        int stateVis =
                showSpinner
                        ? View.GONE
                        : (progressOnlyMode
                                ? View.INVISIBLE
                                : (modernTv && a.prepared && a.playing ? View.GONE : View.VISIBLE));
        state.setVisibility(stateVis);
        if (centerRow != null) centerRow.setVisibility(stateVis);
        state.setContentDescription(!a.prepared ? "正在准备" : a.playing ? "正在播放，确认暂停" : "已暂停，确认继续");
        state.invalidate();
    }

    final class StateGlyph extends View {
        final Paint paint = new Paint(3);

        StateGlyph() {
            super(a);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float cx = getWidth() / 2f, cy = getHeight() / 2f;
            paint.setColor(0x99303034);
            canvas.drawCircle(cx, cy, getWidth() / 2f, paint);
            paint.setColor(MainActivity.WHITE);
            if (!a.prepared) {
                paint.setStrokeWidth(a.dp(3));
                paint.setStyle(Paint.Style.STROKE);
                canvas.drawCircle(cx, cy, a.dp(12), paint);
                paint.setStyle(Paint.Style.FILL);
                return;
            }
            if (a.playing) {
                canvas.drawRoundRect(
                        new RectF(cx - a.dp(10), cy - a.dp(13), cx - a.dp(3), cy + a.dp(13)),
                        a.dp(2),
                        a.dp(2),
                        paint);
                canvas.drawRoundRect(
                        new RectF(cx + a.dp(3), cy - a.dp(13), cx + a.dp(10), cy + a.dp(13)),
                        a.dp(2),
                        a.dp(2),
                        paint);
            } else {
                Path p = new Path();
                p.moveTo(cx - a.dp(8), cy - a.dp(14));
                p.lineTo(cx + a.dp(15), cy);
                p.lineTo(cx - a.dp(8), cy + a.dp(14));
                p.close();
                paint.setStrokeJoin(Paint.Join.ROUND);
                paint.setStrokeWidth(a.dp(3));
                paint.setStyle(Paint.Style.FILL_AND_STROKE);
                canvas.drawPath(p, paint);
                paint.setStyle(Paint.Style.FILL);
            }
        }
    }
}

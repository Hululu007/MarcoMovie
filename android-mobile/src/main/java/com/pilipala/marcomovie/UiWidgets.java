package com.pilipala.marcomovie;

import android.animation.ValueAnimator;
import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Shared Liquid Glass surfaces, touch feedback helpers, vector setting icons, iOS switches, and
 * adaptive choice sheets used across core controllers without cross-referencing TV or Mobile
 * screen classes.
 */
final class UiWidgets {
    interface BooleanAction {
        void onToggle(boolean checked);
    }

    private UiWidgets() {}

    static GradientDrawable glassBg(
            MainActivity a, int fillColor, int strokeColor, float radiusDp) {
        GradientDrawable gd = new GradientDrawable();
        if (a.isReducedTransparency()) {
            gd.setColor((fillColor & 0x00ffffff) | 0xf2000000);
        } else {
            gd.setColor(fillColor);
        }
        gd.setCornerRadius(a.dp(radiusDp));
        gd.setStroke(Math.max(1, a.dp(0.8f)), strokeColor);
        return gd;
    }

    static GradientDrawable glassBg(
            int topColor, int bottomColor, float radiusPx, float strokePx, int strokeColor) {
        GradientDrawable gd =
                new GradientDrawable(
                        GradientDrawable.Orientation.TOP_BOTTOM, new int[] {topColor, bottomColor});
        gd.setCornerRadius(radiusPx);
        if (strokePx > 0) {
            gd.setStroke(Math.max(1, Math.round(strokePx)), strokeColor);
        }
        return gd;
    }

    static void bindTouchFeedback(View v) {
        if (v == null) return;
        MobileMotion.bindPress(v, 0.94f);
    }

    static void bindCardTouchFeedback(
            MainActivity a, View card, Drawable normalBg, Drawable pressedBg) {
        if (card == null) return;
        MobileMotion.bindPress(card, 0.97f, normalBg, pressedBg);
    }

    static void showDrawerPicker(
            MainActivity a,
            String title,
            String subtitle,
            String[] options,
            int selectedIndex,
            PlayerBubble.IntAction onSelect) {
        if (a.isTvDevice()) {
            new AppDialog.Builder(a)
                    .setTitle(title)
                    .setSingleChoiceItems(
                            options,
                            Math.max(0, selectedIndex),
                            (d, idx) -> {
                                d.dismiss();
                                if (onSelect != null) onSelect.accept(idx);
                            })
                    .setNegativeButton("取消", null)
                    .show();
            return;
        }
        MobileBottomSheet.showPicker(a, title, subtitle, options, selectedIndex, onSelect);
    }

    /** Pure-JVM classifier for clipboard import candidates (URL, JSON, M3U, TXT, ZIP, clan://). */
    static String classifyImportCandidate(String raw) {
        if (raw == null) return null;
        String text = raw.trim();
        if (text.length() < 6 || text.length() > 262144) return null;
        String lower = text.toLowerCase(Locale.ROOT);
        if (lower.startsWith("#extm3u")
                || lower.contains("#genre#")
                || lower.contains(",http://")
                || lower.contains(",https://")) {
            return "直播源";
        }
        if (lower.startsWith("http://") || lower.startsWith("https://")) {
            if (lower.contains(".m3u")) return "直播源链接";
            if (lower.endsWith(".zip") || lower.contains(".zip?")) return "压缩配置包";
            if (lower.endsWith(".js")
                    || lower.contains(".js?")
                    || lower.endsWith(".py")
                    || lower.contains(".py?")) return "脚本源链接";
            return "网址配置";
        }
        if (lower.startsWith("clan://")) {
            return "本地规则";
        }
        if (text.startsWith("{")
                && text.endsWith("}")
                && (text.contains("\"sites\"")
                        || text.contains("\"urls\"")
                        || text.contains("\"lives\"")
                        || text.contains("\"spider\""))) {
            return "JSON 配置";
        }
        return null;
    }

    private static String readClipboardImportCandidate(MainActivity a) {
        try {
            ClipboardManager cm = (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm == null || !cm.hasPrimaryClip()) return null;
            ClipData clip = cm.getPrimaryClip();
            if (clip == null || clip.getItemCount() <= 0 || clip.getItemAt(0).getText() == null) {
                return null;
            }
            String text = clip.getItemAt(0).getText().toString().trim();
            return classifyImportCandidate(text) != null ? text : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    static void showMobileImportDialog(MainActivity a) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        final MobileBottomSheet.SheetHandle[] handleRef = new MobileBottomSheet.SheetHandle[1];
        LinearLayout panel = a.vertical();
        panel.setPadding(0, a.dp(2), 0, a.dp(6));

        final String detectedClip = readClipboardImportCandidate(a);
        if (detectedClip != null) {
            String kind = classifyImportCandidate(detectedClip);
            String preview = detectedClip.replace('\n', ' ').replace('\r', ' ').trim();
            if (preview.length() > 64) {
                preview = preview.substring(0, 64) + "…";
            }
            LinearLayout clipCard = a.row();
            clipCard.setGravity(Gravity.CENTER_VERTICAL);
            clipCard.setPadding(a.dp(14), a.dp(13), a.dp(14), a.dp(13));
            clipCard.setBackground(MobileTheme.accentPillBg(a, 16));
            MobileMotion.bindPress(clipCard, 0.96f);

            FrameLayout clipBadge = new FrameLayout(a);
            clipBadge.setBackground(a.bg(MobileTheme.withAlpha(p.accent, 0x22), 10));
            MobileIcons.IconView clipIcon =
                    MobileIcons.create(a, MobileIcons.IC_CLIPBOARD, 18f, p.accent);
            clipBadge.addView(
                    clipIcon, new FrameLayout.LayoutParams(a.dp(18), a.dp(18), Gravity.CENTER));
            LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(a.dp(34), a.dp(34));
            badgeLp.rightMargin = a.dp(12);
            clipCard.addView(clipBadge, badgeLp);

            LinearLayout clipTextCol = a.vertical();
            TextView clipTitle = a.text("检测到剪贴板影视源，一键导入", 14.5f, p.accent);
            clipTitle.setTypeface(null, Typeface.BOLD);
            clipTitle.setSingleLine(true);
            clipTitle.setEllipsize(TextUtils.TruncateAt.END);
            clipTextCol.addView(clipTitle);

            TextView clipSub = a.text(kind + " · " + preview, 12f, p.textSecondary);
            clipSub.setSingleLine(true);
            clipSub.setEllipsize(TextUtils.TruncateAt.MIDDLE);
            clipSub.setPadding(0, a.dp(2), 0, 0);
            clipTextCol.addView(clipSub);
            clipCard.addView(clipTextCol, new LinearLayout.LayoutParams(0, -2, 1f));

            MobileIcons.IconView arrow =
                    MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 15f, p.accent);
            LinearLayout.LayoutParams arrowLp = new LinearLayout.LayoutParams(a.dp(15), a.dp(15));
            arrowLp.leftMargin = a.dp(8);
            clipCard.addView(arrow, arrowLp);

            clipCard.setOnClickListener(
                    v -> {
                        if (handleRef[0] != null) handleRef[0].dismiss();
                        importTextOrUrl(a, detectedClip);
                    });
            panel.addView(clipCard, new LinearLayout.LayoutParams(-1, -2));
            a.gap(panel, 14);
        }

        final EditText input = new EditText(a);
        input.setHint("输入或粘贴网址 / .json / .m3u / .zip");
        input.setHintTextColor(p.textTertiary);
        input.setTextColor(p.textPrimary);
        input.setTextSize(14.5f);
        input.setSingleLine(true);
        input.setShowSoftInputOnFocus(true);
        input.setLongClickable(true);
        input.setTextIsSelectable(true);
        input.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        input.setBackground(MobileTheme.subtleBg(a, 14));
        String savedOrigin = a.prefs.getString(Prefs.ORIGIN, "");
        if (!savedOrigin.isEmpty()) {
            input.setText(savedOrigin);
            input.setSelection(savedOrigin.length());
        }
        panel.addView(input, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 10);

        TextView submitBtn = a.text("导入输入内容", 14.5f, p.accentOnFill);
        submitBtn.setTypeface(null, Typeface.BOLD);
        submitBtn.setGravity(Gravity.CENTER);
        submitBtn.setMinimumHeight(a.dp(46));
        submitBtn.setPadding(a.dp(16), a.dp(12), a.dp(16), a.dp(12));
        submitBtn.setBackground(a.bg(p.accent, 14));
        MobileMotion.bindPress(submitBtn, 0.96f);
        submitBtn.setOnClickListener(
                v -> {
                    String raw = input.getText().toString().trim();
                    if (raw.isEmpty()) {
                        MobileMotion.shakeInvalid(input);
                        a.toast("请输入配置网址或先复制影视源链接");
                        return;
                    }
                    if (handleRef[0] != null) handleRef[0].dismiss();
                    importTextOrUrl(a, raw);
                });
        panel.addView(submitBtn, new LinearLayout.LayoutParams(-1, -2));
        a.gap(panel, 14);

        java.util.List<View> rows = new java.util.ArrayList<>();
        if (detectedClip == null) {
            rows.add(
                    MobileSectionGroup.navRow(
                            a,
                            MobileIcons.IC_CLIPBOARD,
                            p.accent,
                            "从剪贴板粘贴导入",
                            null,
                            () -> {
                                if (handleRef[0] != null) handleRef[0].dismiss();
                                pasteConfigFromClipboard(a);
                            }));
        }
        rows.add(
                MobileSectionGroup.navRow(
                        a,
                        MobileIcons.IC_FOLDER,
                        0xFF10B981,
                        "选择本地文件或压缩包",
                        ".json / .zip",
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            a.pickConfig();
                        }));
        rows.add(
                MobileSectionGroup.navRow(
                        a,
                        MobileIcons.IC_LIVE,
                        0xFFF59E0B,
                        "导入或管理电视直播源",
                        "M3U / TXT",
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            SourceController.showLiveImportDialog(a);
                        }));
        rows.add(
                MobileSectionGroup.navRow(
                        a,
                        MobileIcons.IC_NETDISK,
                        0xFF8B5CF6,
                        "连接 Emby 媒体库",
                        null,
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            EmbyEngine.connect(a);
                        }));
        rows.add(
                MobileSectionGroup.navRow(
                        a,
                        MobileIcons.IC_FOLDER,
                        0xFF0EA5E9,
                        "挂载 AList / OpenList 网盘",
                        null,
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            AlistAccounts.openManager(a);
                        }));
        LinearLayout actionsGroup = MobileSectionGroup.create(a, "更多导入方式", null, rows);
        panel.addView(actionsGroup, new LinearLayout.LayoutParams(-1, -2));

        handleRef[0] =
                MobileBottomSheet.showHandle(
                        a,
                        "导入影视源",
                        "支持 JSON / JS / PY / TXT / M3U / ZIP 配置",
                        null,
                        null,
                        panel,
                        true);
    }

    static void pasteConfigFromClipboard(MainActivity a) {
        ClipboardManager cm = (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
        String text = "";
        if (cm != null && cm.hasPrimaryClip()) {
            ClipData clip = cm.getPrimaryClip();
            if (clip != null && clip.getItemCount() > 0 && clip.getItemAt(0).getText() != null) {
                text = clip.getItemAt(0).getText().toString().trim();
            }
        }
        if (text.isEmpty()) {
            a.toast("剪贴板为空，请先复制配置网址或源码内容");
            return;
        }
        importTextOrUrl(a, text);
    }

    static byte[] fetchZipBytes(String address) throws Exception {
        if (!Cms.isHttp(address)) {
            throw new IOException("只支持 HTTP(S) 地址");
        }
        URL current = new URL(Cms.normalizeHttp(address));
        Map<String, String> forwardedHeaders = new LinkedHashMap<>();
        forwardedHeaders.put("User-Agent", Cms.USER_AGENT);
        forwardedHeaders.put("Accept", "*/*");
        Map<String, Cms.RedirectCookie> redirectCookies = new LinkedHashMap<>();

        for (int hop = 0; hop < 5; hop++) {
            if (Thread.currentThread().isInterrupted()) {
                throw new java.io.InterruptedIOException();
            }
            HttpURLConnection conn = ProxyAddress.openHttpConnection(current);
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(25000);
            for (Map.Entry<String, String> entry : forwardedHeaders.entrySet()) {
                conn.setRequestProperty(entry.getKey(), entry.getValue());
            }

            try {
                int status = conn.getResponseCode();
                List<String> setCookies = conn.getHeaderFields().get("Set-Cookie");
                if (setCookies == null) {
                    for (Map.Entry<String, List<String>> entry :
                            conn.getHeaderFields().entrySet()) {
                        if ("set-cookie".equalsIgnoreCase(entry.getKey())) {
                            setCookies = entry.getValue();
                            break;
                        }
                    }
                }
                List<Cms.RedirectCookie> newCookies = Cms.parseSetCookies(setCookies, current);
                for (Cms.RedirectCookie cookie : newCookies) {
                    redirectCookies.put(
                            cookie.domain
                                    + "|"
                                    + cookie.hostOnly
                                    + "|"
                                    + cookie.path
                                    + "|"
                                    + cookie.name,
                            cookie);
                }

                if (status == 301
                        || status == 302
                        || status == 303
                        || status == 307
                        || status == 308) {
                    String loc = conn.getHeaderField("Location");
                    if (loc == null || loc.trim().isEmpty()) {
                        throw new IOException("重定向缺少地址");
                    }
                    URL target = new URL(current, loc.trim());
                    if (!Cms.isHttp(target.toString())) {
                        throw new IOException("不支持此重定向协议: " + target.getProtocol());
                    }
                    if (target.getUserInfo() != null) {
                        throw new IOException("来源重定向不能注入登录凭据");
                    }
                    forwardedHeaders =
                            Cms.inheritedHeaders(
                                    current.toString(), target.toString(), forwardedHeaders);
                    Cms.mergeRedirectCookies(forwardedHeaders, redirectCookies.values(), target);
                    current = target;
                    continue;
                }

                if (status < 200 || status >= 300) {
                    throw new IOException("远程服务器返回 HTTP " + status);
                }

                try (InputStream in = conn.getInputStream();
                        ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        if (bos.size() + n > 28 * 1024 * 1024) {
                            throw new IOException("远程包超过 28 MB 限制");
                        }
                        bos.write(buf, 0, n);
                    }
                    return bos.toByteArray();
                }
            } finally {
                conn.disconnect();
            }
        }
        throw new IOException("来源重定向次数过多");
    }

    static void importTextOrUrl(MainActivity a, String rawInput) {
        final String pasted = rawInput == null ? "" : rawInput.trim();
        if (pasted.isEmpty()) {
            a.toast("请输入有效的配置网址或源码内容");
            return;
        }
        final long importSeq = SourceController.beginConfigImport(a);
        final boolean snapshotPrivate = a.privateMode;
        a.toast("正在读取并解析配置…");
        a.worker.execute(
                () -> {
                    try {
                        String origin = "";
                        String rawJson = pasted;
                        if (Cms.isHttp(pasted)) {
                            origin = Cms.normalizeHttp(pasted);
                            String lowerOrigin = origin.toLowerCase(Locale.ROOT);
                            if (lowerOrigin.endsWith(".zip") || lowerOrigin.contains(".zip?")) {
                                byte[] bytes = fetchZipBytes(origin);
                                LocalSourcePackage pkg =
                                        LocalSourcePackage.open(a.getFilesDir(), bytes);
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || a.isDestroyed()
                                                    || a.switchingPrivacy
                                                    || a.privateMode != snapshotPrivate
                                                    || !SourceController.isCurrentConfigImport(
                                                            a, importSeq)) {
                                                return;
                                            }
                                            try {
                                                SourceController.applyLocalPackage(a, pkg);
                                            } catch (Exception ex) {
                                                a.toast("保存配置失败：" + a.message(ex));
                                            }
                                        });
                                return;
                            } else {
                                rawJson = SourceController.fetchImport(a, origin);
                                origin = SourceController.importOrigin(origin);
                            }
                        }
                        // Optional AI static safety check for imported Python scripts
                        if (!a.isTvDevice()
                                && rawJson != null
                                && (origin.toLowerCase(Locale.ROOT).endsWith(".py")
                                        || rawJson.contains("class Spider")
                                        || rawJson.contains("def homeContent"))) {
                            String warn = AiAssistantService.staticSafetyScanPython(rawJson);
                            if (warn != null && !warn.isEmpty()) {
                                a.ui.post(() -> a.toast("Python 脚本安全提醒：" + warn));
                            }
                        }
                        try {
                            Cms.Config parsed = Cms.parseConfig(rawJson, origin);
                            final String savedOrigin = origin;
                            a.ui.post(
                                    () -> {
                                        if (a.isFinishing()
                                                || a.isDestroyed()
                                                || a.switchingPrivacy
                                                || a.privateMode != snapshotPrivate
                                                || !SourceController.isCurrentConfigImport(
                                                        a, importSeq)) {
                                            return;
                                        }
                                        try {
                                            a.saveConfig(parsed, savedOrigin);
                                        } catch (Exception ex) {
                                            a.toast("保存配置失败：" + a.message(ex));
                                        }
                                    });
                        } catch (Exception parseEx) {
                            String trimmed = rawJson == null ? "" : rawJson.trim();
                            if (trimmed.startsWith("#EXTM3U")
                                    || trimmed.contains("#genre#")
                                    || trimmed.contains(",http://")
                                    || trimmed.contains(",https://")
                                    || trimmed.contains(",rtmp://")
                                    || trimmed.contains(",rtsp://")) {
                                SourceController.importLiveTextOrUrl(a, pasted);
                                return;
                            }
                            throw parseEx;
                        }
                    } catch (Throwable e) {
                        a.ui.post(() -> a.toast(SourceController.stageMessage("配置读取失败", e)));
                    }
                });
    }

    /** iOS-style capsule toggle switch (`50dp × 30dp`, accent track + sliding white thumb). */
    static class IosSwitchView extends View {
        private final MainActivity a;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private boolean checked;
        private float progress;
        private ValueAnimator animator;

        IosSwitchView(MainActivity activity, boolean initialChecked) {
            super(activity);
            this.a = activity;
            this.checked = initialChecked;
            this.progress = initialChecked ? 1f : 0f;
            setClickable(false);
            setFocusable(false);
        }

        boolean isChecked() {
            return checked;
        }

        void setChecked(boolean next, boolean animate) {
            this.checked = next;
            float target = next ? 1f : 0f;
            if (animator != null) {
                animator.cancel();
                animator = null;
            }
            if (!animate || MobileMotion.isReduced(a) || Math.abs(progress - target) < 0.01f) {
                progress = target;
                invalidate();
                return;
            }
            animator = ValueAnimator.ofFloat(progress, target);
            animator.setDuration(MotionTokens.DURATION_FAST_MS);
            animator.setInterpolator(MotionTokens.createStandardInterpolator());
            animator.addUpdateListener(
                    anim -> {
                        progress = (Float) anim.getAnimatedValue();
                        invalidate();
                    });
            animator.start();
        }

        private static int blendColor(int c1, int c2, float ratio) {
            float r = Math.max(0f, Math.min(1f, ratio));
            int a1 = (c1 >>> 24) & 0xff,
                    r1 = (c1 >> 16) & 0xff,
                    g1 = (c1 >> 8) & 0xff,
                    b1 = c1 & 0xff;
            int a2 = (c2 >>> 24) & 0xff,
                    r2 = (c2 >> 16) & 0xff,
                    g2 = (c2 >> 8) & 0xff,
                    b2 = c2 & 0xff;
            int oa = Math.round(a1 + (a2 - a1) * r);
            int or = Math.round(r1 + (r2 - r1) * r);
            int og = Math.round(g1 + (g2 - g1) * r);
            int ob = Math.round(b1 + (b2 - b1) * r);
            return (oa << 24) | (or << 16) | (og << 8) | ob;
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float radius = h / 2f;
            boolean tv = a.isTvDevice();
            int onColor;
            int offColor;
            if (tv) {
                onColor = 0xff30d158;
                offColor = 0x58787880;
            } else {
                MobileTheme.Palette p = MobileTheme.of(a);
                onColor = p.accent;
                offColor = p.isDark ? 0xff323644 : 0xffd5dae4;
            }
            int trackColor = blendColor(offColor, onColor, progress);
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(trackColor);
            RectF trackRect = new RectF(0, 0, w, h);
            c.drawRoundRect(trackRect, radius, radius, paint);

            if (tv && progress < 0.95f) {
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f, a.dp(0.8f)));
                paint.setColor(blendColor(0x2effffff, 0x00ffffff, progress));
                float inset = paint.getStrokeWidth() / 2f;
                c.drawRoundRect(
                        new RectF(inset, inset, w - inset, h - inset), radius, radius, paint);
            }

            float pad = a.dp(2f);
            float thumbRadius = (h - pad * 2f) / 2f;
            float minCx = pad + thumbRadius;
            float maxCx = w - pad - thumbRadius;
            float cx = minCx + (maxCx - minCx) * progress;
            float cy = h / 2f;

            paint.setStyle(Paint.Style.FILL);
            paint.setColor(tv ? 0x33000000 : 0x22000000);
            c.drawCircle(cx, cy + a.dp(0.7f), thumbRadius, paint);

            paint.setColor(Color.WHITE);
            c.drawCircle(cx, cy, thumbRadius, paint);
        }
    }

    /** Semantic vector icon badge (`38dp × 38dp` rounded square + vector glyph). */
    static class SettingIconView extends View {
        static final int ICON_SOURCES = 1;
        static final int ICON_NETDISK = 2;
        static final int ICON_PLAYBACK = 3;
        static final int ICON_APPEARANCE = 4;
        static final int ICON_SYSTEM = 5;
        static final int ICON_CLIPBOARD = 11;
        static final int ICON_LINK_CODE = 12;
        static final int ICON_FOLDER_FILE = 13;
        static final int ICON_LIVE_TV = 14;
        static final int ICON_SWITCH_SOURCE = 15;
        static final int ICON_PLUGIN_EXT = 16;
        static final int ICON_ENGINE_CORE = 21;
        static final int ICON_DECODER_CHIP = 22;
        static final int ICON_HDR_TUNNEL = 23;
        static final int ICON_AUTO_NEXT = 24;
        static final int ICON_SKIP_TIMELINE = 25;
        static final int ICON_SUBTITLE = 26;
        static final int ICON_UI_SCALE = 31;
        static final int ICON_NAV_FONT = 32;
        static final int ICON_GLASS_BLUR = 33;
        static final int ICON_MOTION_SPARK = 34;
        static final int ICON_TRASH_CLEAR = 35;
        static final int ICON_UPDATE_CLOUD = 41;
        static final int ICON_DIAGNOSTIC_LOG = 42;
        static final int ICON_BACKUP_SAFE = 43;
        static final int ICON_WALLPAPER = 51;
        static final int ICON_GRID_COLS = 52;
        static final int ICON_AUDIO_WAVE = 53;
        static final int ICON_ASPECT_RATIO = 54;
        static final int ICON_SPEED_GAUGE = 55;
        static final int ICON_REPEAT_LOOP = 56;
        static final int ICON_AI_SPARKLE = 61;
        static final int ICON_TMDB_STAR = 62;
        static final int ICON_GESTURE_TOUCH = 63;

        private final MainActivity a;
        private final int kind;
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

        SettingIconView(MainActivity activity, int kind) {
            super(activity);
            this.a = activity;
            this.kind = kind;
        }

        static int kindForSetting(String key, String title) {
            String k = key == null ? "" : key;
            String t = title == null ? "" : title;
            if (t.contains("AI") || t.contains("净化") || t.contains("大模型")) return ICON_AI_SPARKLE;
            if (t.contains("TMDB") || t.contains("刮削") || t.contains("评分") || t.contains("追剧"))
                return ICON_TMDB_STAR;
            if (t.contains("手势") || t.contains("亮度") || t.contains("双指")) return ICON_GESTURE_TOUCH;
            if (k.contains("settings-appearance")) return ICON_APPEARANCE;
            if (k.contains("settings-playback")) return ICON_PLAYBACK;
            if (k.contains("settings-data")) return ICON_SOURCES;
            if (k.contains("settings-updates")) return ICON_UPDATE_CLOUD;
            if (k.contains("settings-accounts") || t.contains("网盘") || t.contains("WebDAV"))
                return ICON_NETDISK;
            if (k.contains("settings-live-import") || t.contains("直播") || t.contains("电视"))
                return ICON_LIVE_TV;
            if (k.contains("settings-import") || t.contains("配置源")) return ICON_LINK_CODE;
            if (k.contains("settings-depots") || t.contains("线路") || t.contains("切换"))
                return ICON_SWITCH_SOURCE;
            if (k.contains(Prefs.EXPERIMENTAL_CSP) || t.contains("扩展") || t.contains("Python"))
                return ICON_PLUGIN_EXT;
            if (k.contains("settings-backup")
                    || k.contains("settings-restore")
                    || t.contains("备份")
                    || t.contains("还原")) return ICON_BACKUP_SAFE;
            if (k.contains("settings-logs") || t.contains("日志")) return ICON_DIAGNOSTIC_LOG;
            if (k.contains("clear-history") || t.contains("清除") || t.contains("清空"))
                return ICON_TRASH_CLEAR;
            if (k.contains("settings-history")
                    || k.contains("clear-images")
                    || k.contains("settings-reset")
                    || k.contains(Prefs.REPEAT_MODE)
                    || t.contains("循环")
                    || t.contains("历史")
                    || t.contains("恢复")) return ICON_REPEAT_LOOP;
            if (k.contains(Prefs.UI_SCALE_PERCENT) || t.contains("界面大小") || t.contains("缩放"))
                return ICON_UI_SCALE;
            if (k.contains(Prefs.NAV_SCALE_PERCENT) || t.contains("导航栏") || t.contains("底栏"))
                return ICON_NAV_FONT;
            if (k.contains(Prefs.HOME_COLUMNS) || t.contains("每行海报")) return ICON_GRID_COLS;
            if (k.contains("wallpaper")
                    || k.contains(Prefs.HOME_AMBIENT)
                    || t.contains("壁纸")
                    || t.contains("图片")
                    || t.contains("柔光")
                    || t.contains("压暗")) return ICON_WALLPAPER;
            if (k.contains(Prefs.REDUCED_TRANSPARENCY) || t.contains("透明") || t.contains("玻璃"))
                return ICON_GLASS_BLUR;
            if (k.contains(Prefs.REDUCED)
                    || k.contains(Prefs.STARTUP_ANIMATION)
                    || t.contains("动画")
                    || t.contains("动态")) return ICON_MOTION_SPARK;
            if (k.contains(Prefs.VIDEO_OUTPUT)
                    || k.contains(Prefs.TUNNELED_PLAYBACK)
                    || t.contains("HDR")
                    || t.contains("画面输出")) return ICON_HDR_TUNNEL;
            if (k.contains(Prefs.PLAYER_ENGINE) || t.contains("播放器") || t.contains("内核"))
                return ICON_ENGINE_CORE;
            if (k.contains(Prefs.DECODER_MODE) || k.contains("decoders") || t.contains("解码"))
                return ICON_DECODER_CHIP;
            if (k.contains(Prefs.SOFTWARE_AUDIO)
                    || k.contains(Prefs.PREFER_AAC)
                    || k.contains(Prefs.AUDIO_EFFECT)
                    || t.contains("音轨")
                    || t.contains("音效")
                    || t.contains("音频")
                    || t.contains("响度")) return ICON_AUDIO_WAVE;
            if (k.contains(Prefs.ASPECT)
                    || k.contains(Prefs.PICTURE_EFFECT)
                    || t.contains("画面比例")
                    || t.contains("色彩")) return ICON_ASPECT_RATIO;
            if (k.contains(Prefs.PLAY_SPEED)
                    || k.contains(Prefs.BUFFER_SECONDS)
                    || k.contains(Prefs.SEARCH_THREADS)
                    || k.contains(Prefs.SEARCH_TIMEOUT)
                    || t.contains("速度")
                    || t.contains("倍速")
                    || t.contains("缓冲")) return ICON_SPEED_GAUGE;
            if (k.contains(Prefs.AUTO_NEXT) || t.contains("下一集") || t.contains("连播"))
                return ICON_AUTO_NEXT;
            if (k.contains(Prefs.SKIP_INTRO) || k.contains(Prefs.SKIP_OUTRO) || t.contains("跳过片"))
                return ICON_SKIP_TIMELINE;
            if (k.contains(Prefs.SUBTITLE_SIZE)
                    || k.contains(Prefs.SUBTITLE_STYLE)
                    || k.contains(Prefs.DANMAKU_DEFAULT)
                    || t.contains("字幕")
                    || t.contains("弹幕")) return ICON_SUBTITLE;
            return ICON_SOURCES;
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float cx = w / 2f, cy = h / 2f;
            int badgeBg;
            int strokeColor;
            switch (kind) {
                case ICON_SOURCES:
                case ICON_CLIPBOARD:
                case ICON_DECODER_CHIP:
                case ICON_GLASS_BLUR:
                    badgeBg = 0x2606b6d4;
                    strokeColor = 0xff22d3ee;
                    break;
                case ICON_NETDISK:
                case ICON_PLUGIN_EXT:
                case ICON_AUTO_NEXT:
                case ICON_REPEAT_LOOP:
                    badgeBg = 0x2610b981;
                    strokeColor = 0xff34d399;
                    break;
                case ICON_PLAYBACK:
                case ICON_ENGINE_CORE:
                case ICON_SPEED_GAUGE:
                case ICON_TMDB_STAR:
                    badgeBg = 0x26f59e0b;
                    strokeColor = 0xfffbbf24;
                    break;
                case ICON_FOLDER_FILE:
                case ICON_SKIP_TIMELINE:
                case ICON_GESTURE_TOUCH:
                    badgeBg = 0x26f97316;
                    strokeColor = 0xfffb923c;
                    break;
                case ICON_APPEARANCE:
                case ICON_HDR_TUNNEL:
                case ICON_UI_SCALE:
                case ICON_GRID_COLS:
                case ICON_AI_SPARKLE:
                    badgeBg = 0x26a855f7;
                    strokeColor = 0xffc084fc;
                    break;
                case ICON_NAV_FONT:
                    badgeBg = 0x26ec4899;
                    strokeColor = 0xfff472b6;
                    break;
                case ICON_LIVE_TV:
                case ICON_AUDIO_WAVE:
                    badgeBg = 0x26f43f5e;
                    strokeColor = 0xfffb7185;
                    break;
                case ICON_TRASH_CLEAR:
                    badgeBg = 0x26ef4444;
                    strokeColor = 0xfff87171;
                    break;
                case ICON_MOTION_SPARK:
                    badgeBg = 0x26eab308;
                    strokeColor = 0xfffacc15;
                    break;
                case ICON_DIAGNOSTIC_LOG:
                case ICON_WALLPAPER:
                    badgeBg = 0x2614b8a6;
                    strokeColor = 0xff2dd4bf;
                    break;
                case ICON_SWITCH_SOURCE:
                case ICON_BACKUP_SAFE:
                    badgeBg = 0x266366f1;
                    strokeColor = 0xff818cf8;
                    break;
                case ICON_SUBTITLE:
                case ICON_ASPECT_RATIO:
                    badgeBg = 0x260ea5e9;
                    strokeColor = 0xff38bdf8;
                    break;
                case ICON_SYSTEM:
                case ICON_LINK_CODE:
                case ICON_UPDATE_CLOUD:
                default:
                    badgeBg = 0x263b82f6;
                    strokeColor = 0xff60a5fa;
                    break;
            }
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(badgeBg);
            c.drawRoundRect(new RectF(0, 0, w, h), a.dp(10), a.dp(10), paint);

            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(strokeColor);
            paint.setStrokeWidth(a.dp(1.65f));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);

            switch (kind) {
                case ICON_AI_SPARKLE:
                    {
                        Path star = new Path();
                        float rOut = a.dp(8.2f), rIn = a.dp(2.6f);
                        star.moveTo(cx, cy - rOut);
                        star.lineTo(cx + rIn, cy - rIn);
                        star.lineTo(cx + rOut, cy);
                        star.lineTo(cx + rIn, cy + rIn);
                        star.lineTo(cx, cy + rOut);
                        star.lineTo(cx - rIn, cy + rIn);
                        star.lineTo(cx - rOut, cy);
                        star.lineTo(cx - rIn, cy - rIn);
                        star.close();
                        c.drawPath(star, paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx + a.dp(6.2f), cy - a.dp(6.2f), a.dp(1.3f), paint);
                        break;
                    }
                case ICON_TMDB_STAR:
                    {
                        RectF film =
                                new RectF(
                                        cx - a.dp(8.2f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.2f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(film, a.dp(2.2f), a.dp(2.2f), paint);
                        c.drawCircle(cx, cy, a.dp(2.8f), paint);
                        c.drawLine(
                                cx - a.dp(5.2f),
                                cy - a.dp(6.5f),
                                cx - a.dp(5.2f),
                                cy + a.dp(6.5f),
                                paint);
                        c.drawLine(
                                cx + a.dp(5.2f),
                                cy - a.dp(6.5f),
                                cx + a.dp(5.2f),
                                cy + a.dp(6.5f),
                                paint);
                        break;
                    }
                case ICON_GESTURE_TOUCH:
                    {
                        c.drawCircle(cx, cy - a.dp(3.5f), a.dp(4.2f), paint);
                        c.drawLine(cx, cy - a.dp(1.2f), cx, cy + a.dp(7.5f), paint);
                        c.drawLine(
                                cx - a.dp(6.5f),
                                cy + a.dp(2.2f),
                                cx + a.dp(6.5f),
                                cy + a.dp(2.2f),
                                paint);
                        break;
                    }
                case ICON_SOURCES:
                    {
                        Path top = new Path();
                        top.moveTo(cx, cy - a.dp(8f));
                        top.lineTo(cx + a.dp(8f), cy - a.dp(3.2f));
                        top.lineTo(cx, cy + a.dp(1.6f));
                        top.lineTo(cx - a.dp(8f), cy - a.dp(3.2f));
                        top.close();
                        c.drawPath(top, paint);
                        c.drawLine(cx - a.dp(8f), cy + a.dp(0.8f), cx, cy + a.dp(5.2f), paint);
                        c.drawLine(cx + a.dp(8f), cy + a.dp(0.8f), cx, cy + a.dp(5.2f), paint);
                        c.drawLine(cx - a.dp(8f), cy + a.dp(4.4f), cx, cy + a.dp(8.8f), paint);
                        c.drawLine(cx + a.dp(8f), cy + a.dp(4.4f), cx, cy + a.dp(8.8f), paint);
                        break;
                    }
                case ICON_NETDISK:
                    {
                        RectF base =
                                new RectF(
                                        cx - a.dp(8.2f),
                                        cy - a.dp(1.5f),
                                        cx + a.dp(8.2f),
                                        cy + a.dp(6.8f));
                        c.drawRoundRect(base, a.dp(4.2f), a.dp(4.2f), paint);
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(5.2f),
                                        cy - a.dp(7.5f),
                                        cx + a.dp(5.2f),
                                        cy + a.dp(2.5f)),
                                185,
                                170,
                                false,
                                paint);
                        c.drawLine(cx, cy + a.dp(4.2f), cx, cy - a.dp(1.2f), paint);
                        c.drawLine(cx - a.dp(2.3f), cy + a.dp(1f), cx, cy - a.dp(1.4f), paint);
                        c.drawLine(cx + a.dp(2.3f), cy + a.dp(1f), cx, cy - a.dp(1.4f), paint);
                        break;
                    }
                case ICON_PLAYBACK:
                case ICON_ENGINE_CORE:
                    {
                        RectF scr =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(scr, a.dp(2.8f), a.dp(2.8f), paint);
                        paint.setStyle(Paint.Style.FILL);
                        Path tri = new Path();
                        tri.moveTo(cx - a.dp(2.2f), cy - a.dp(3.2f));
                        tri.lineTo(cx + a.dp(3.4f), cy);
                        tri.lineTo(cx - a.dp(2.2f), cy + a.dp(3.2f));
                        tri.close();
                        c.drawPath(tri, paint);
                        break;
                    }
                case ICON_APPEARANCE:
                    {
                        float x1 = cx - a.dp(8f), x2 = cx + a.dp(8f);
                        c.drawLine(x1, cy - a.dp(4.5f), x2, cy - a.dp(4.5f), paint);
                        c.drawLine(x1, cy + a.dp(4.5f), x2, cy + a.dp(4.5f), paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx - a.dp(2.8f), cy - a.dp(4.5f), a.dp(2.4f), paint);
                        c.drawCircle(cx + a.dp(2.8f), cy + a.dp(4.5f), a.dp(2.4f), paint);
                        break;
                    }
                case ICON_CLIPBOARD:
                    {
                        RectF board =
                                new RectF(
                                        cx - a.dp(6.8f),
                                        cy - a.dp(6.2f),
                                        cx + a.dp(6.8f),
                                        cy + a.dp(8.2f));
                        c.drawRoundRect(board, a.dp(2.2f), a.dp(2.2f), paint);
                        RectF clip =
                                new RectF(
                                        cx - a.dp(3.2f),
                                        cy - a.dp(8.4f),
                                        cx + a.dp(3.2f),
                                        cy - a.dp(4.8f));
                        paint.setStyle(Paint.Style.FILL);
                        c.drawRoundRect(clip, a.dp(1.4f), a.dp(1.4f), paint);
                        paint.setStyle(Paint.Style.STROKE);
                        c.drawLine(
                                cx - a.dp(3.6f),
                                cy - a.dp(0.8f),
                                cx + a.dp(3.6f),
                                cy - a.dp(0.8f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.6f),
                                cy + a.dp(3.4f),
                                cx + a.dp(2.2f),
                                cy + a.dp(3.4f),
                                paint);
                        break;
                    }
                case ICON_LINK_CODE:
                    {
                        c.drawLine(cx - a.dp(3.8f), cy - a.dp(4.5f), cx - a.dp(8.2f), cy, paint);
                        c.drawLine(cx - a.dp(8.2f), cy, cx - a.dp(3.8f), cy + a.dp(4.5f), paint);
                        c.drawLine(cx + a.dp(3.8f), cy - a.dp(4.5f), cx + a.dp(8.2f), cy, paint);
                        c.drawLine(cx + a.dp(8.2f), cy, cx + a.dp(3.8f), cy + a.dp(4.5f), paint);
                        c.drawLine(
                                cx + a.dp(1.8f),
                                cy - a.dp(6.2f),
                                cx - a.dp(1.8f),
                                cy + a.dp(6.2f),
                                paint);
                        break;
                    }
                case ICON_FOLDER_FILE:
                    {
                        Path folder = new Path();
                        folder.moveTo(cx - a.dp(8.2f), cy - a.dp(6.8f));
                        folder.lineTo(cx - a.dp(2.2f), cy - a.dp(6.8f));
                        folder.lineTo(cx + a.dp(0.2f), cy - a.dp(4.2f));
                        folder.lineTo(cx + a.dp(8.2f), cy - a.dp(4.2f));
                        folder.lineTo(cx + a.dp(8.2f), cy + a.dp(7.2f));
                        folder.lineTo(cx - a.dp(8.2f), cy + a.dp(7.2f));
                        folder.close();
                        c.drawPath(folder, paint);
                        c.drawLine(
                                cx - a.dp(8f),
                                cy - a.dp(0.8f),
                                cx + a.dp(8f),
                                cy - a.dp(0.8f),
                                paint);
                        break;
                    }
                case ICON_LIVE_TV:
                    {
                        RectF tv =
                                new RectF(
                                        cx - a.dp(8f),
                                        cy - a.dp(3.8f),
                                        cx + a.dp(8f),
                                        cy + a.dp(7.5f));
                        c.drawRoundRect(tv, a.dp(2.4f), a.dp(2.4f), paint);
                        c.drawLine(cx - a.dp(4.5f), cy - a.dp(8.5f), cx, cy - a.dp(3.8f), paint);
                        c.drawLine(cx + a.dp(4.5f), cy - a.dp(8.5f), cx, cy - a.dp(3.8f), paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx, cy + a.dp(1.8f), a.dp(2f), paint);
                        break;
                    }
                case ICON_SWITCH_SOURCE:
                    {
                        float lx = cx - a.dp(7.5f), rx = cx + a.dp(7.5f);
                        float ty = cy - a.dp(3.5f), by = cy + a.dp(3.5f);
                        c.drawLine(lx, ty, rx, ty, paint);
                        c.drawLine(rx - a.dp(3f), ty - a.dp(2.6f), rx, ty, paint);
                        c.drawLine(rx - a.dp(3f), ty + a.dp(2.6f), rx, ty, paint);
                        c.drawLine(rx, by, lx, by, paint);
                        c.drawLine(lx + a.dp(3f), by - a.dp(2.6f), lx, by, paint);
                        c.drawLine(lx + a.dp(3f), by + a.dp(2.6f), lx, by, paint);
                        break;
                    }
                case ICON_PLUGIN_EXT:
                    {
                        float s = a.dp(5.6f), g = a.dp(1.4f);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy - g - s, cx - g, cy - g),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy + g, cx - g, cy + g + s),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx + g, cy + g, cx + g + s, cy + g + s),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawRoundRect(
                                new RectF(
                                        cx + g + a.dp(0.8f),
                                        cy - g - s - a.dp(0.8f),
                                        cx + g + s + a.dp(0.8f),
                                        cy - g - a.dp(0.8f)),
                                a.dp(1.5f),
                                a.dp(1.5f),
                                paint);
                        break;
                    }
                case ICON_DECODER_CHIP:
                    {
                        RectF chip =
                                new RectF(
                                        cx - a.dp(5.5f),
                                        cy - a.dp(5.5f),
                                        cx + a.dp(5.5f),
                                        cy + a.dp(5.5f));
                        c.drawRoundRect(chip, a.dp(1.8f), a.dp(1.8f), paint);
                        float p = a.dp(2.4f), in = a.dp(5.5f), out = a.dp(8.5f);
                        c.drawLine(cx - p, cy - out, cx - p, cy - in, paint);
                        c.drawLine(cx + p, cy - out, cx + p, cy - in, paint);
                        c.drawLine(cx - p, cy + in, cx - p, cy + out, paint);
                        c.drawLine(cx + p, cy + in, cx + p, cy + out, paint);
                        c.drawLine(cx - out, cy - p, cx - in, cy - p, paint);
                        c.drawLine(cx - out, cy + p, cx - in, cy + p, paint);
                        c.drawLine(cx + in, cy - p, cx + out, cy - p, paint);
                        c.drawLine(cx + in, cy + p, cx + out, cy + p, paint);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawRoundRect(
                                new RectF(
                                        cx - a.dp(2.2f),
                                        cy - a.dp(2.2f),
                                        cx + a.dp(2.2f),
                                        cy + a.dp(2.2f)),
                                a.dp(0.8f),
                                a.dp(0.8f),
                                paint);
                        break;
                    }
                case ICON_HDR_TUNNEL:
                    {
                        RectF scr =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(scr, a.dp(2.5f), a.dp(2.5f), paint);
                        c.drawCircle(cx, cy, a.dp(2.4f), paint);
                        c.drawLine(cx, cy - a.dp(4.6f), cx, cy - a.dp(3.8f), paint);
                        c.drawLine(cx, cy + a.dp(3.8f), cx, cy + a.dp(4.6f), paint);
                        c.drawLine(cx - a.dp(4.8f), cy, cx - a.dp(3.8f), cy, paint);
                        c.drawLine(cx + a.dp(3.8f), cy, cx + a.dp(4.8f), cy, paint);
                        break;
                    }
                case ICON_AUTO_NEXT:
                    {
                        paint.setStyle(Paint.Style.FILL);
                        Path t1 = new Path();
                        t1.moveTo(cx - a.dp(7.5f), cy - a.dp(4.5f));
                        t1.lineTo(cx - a.dp(1.2f), cy);
                        t1.lineTo(cx - a.dp(7.5f), cy + a.dp(4.5f));
                        t1.close();
                        c.drawPath(t1, paint);
                        Path t2 = new Path();
                        t2.moveTo(cx - a.dp(1.2f), cy - a.dp(4.5f));
                        t2.lineTo(cx + a.dp(5.2f), cy);
                        t2.lineTo(cx - a.dp(1.2f), cy + a.dp(4.5f));
                        t2.close();
                        c.drawPath(t2, paint);
                        paint.setStyle(Paint.Style.STROKE);
                        c.drawLine(
                                cx + a.dp(6.8f),
                                cy - a.dp(4.5f),
                                cx + a.dp(6.8f),
                                cy + a.dp(4.5f),
                                paint);
                        break;
                    }
                case ICON_SKIP_TIMELINE:
                    {
                        c.drawLine(
                                cx - a.dp(8f), cy + a.dp(5f), cx + a.dp(8f), cy + a.dp(5f), paint);
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(6.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(6.5f),
                                        cy + a.dp(3.5f)),
                                195,
                                150,
                                false,
                                paint);
                        break;
                    }
                case ICON_SUBTITLE:
                    {
                        RectF box =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(box, a.dp(2.5f), a.dp(2.5f), paint);
                        c.drawLine(
                                cx - a.dp(5.2f),
                                cy + a.dp(0.5f),
                                cx + a.dp(5.2f),
                                cy + a.dp(0.5f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.6f),
                                cy + a.dp(3.5f),
                                cx + a.dp(3.6f),
                                cy + a.dp(3.5f),
                                paint);
                        break;
                    }
                case ICON_UI_SCALE:
                    {
                        float d = a.dp(7.5f), s = a.dp(3.4f);
                        c.drawLine(cx - d, cy - d, cx - d + s, cy - d, paint);
                        c.drawLine(cx - d, cy - d, cx - d, cy - d + s, paint);
                        c.drawLine(cx + d, cy - d, cx + d - s, cy - d, paint);
                        c.drawLine(cx + d, cy - d, cx + d, cy - d + s, paint);
                        c.drawLine(cx - d, cy + d, cx - d + s, cy + d, paint);
                        c.drawLine(cx - d, cy + d, cx - d, cy + d - s, paint);
                        c.drawLine(cx + d, cy + d, cx + d - s, cy + d, paint);
                        c.drawLine(cx + d, cy + d, cx + d, cy + d - s, paint);
                        break;
                    }
                case ICON_NAV_FONT:
                    {
                        c.drawLine(
                                cx - a.dp(3.5f),
                                cy - a.dp(6.5f),
                                cx - a.dp(7.2f),
                                cy + a.dp(3f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.5f),
                                cy - a.dp(6.5f),
                                cx + a.dp(0.2f),
                                cy + a.dp(3f),
                                paint);
                        c.drawCircle(cx + a.dp(4.8f), cy + a.dp(0.2f), a.dp(2.6f), paint);
                        c.drawLine(
                                cx - a.dp(7.5f),
                                cy + a.dp(7f),
                                cx + a.dp(7.5f),
                                cy + a.dp(7f),
                                paint);
                        break;
                    }
                case ICON_GLASS_BLUR:
                    {
                        c.drawCircle(cx - a.dp(2.6f), cy - a.dp(2.2f), a.dp(5.4f), paint);
                        paint.setAlpha(110);
                        paint.setStyle(Paint.Style.FILL);
                        c.drawCircle(cx + a.dp(2.8f), cy + a.dp(2.4f), a.dp(5.4f), paint);
                        paint.setAlpha(255);
                        paint.setStyle(Paint.Style.STROKE);
                        c.drawCircle(cx + a.dp(2.8f), cy + a.dp(2.4f), a.dp(5.4f), paint);
                        break;
                    }
                case ICON_MOTION_SPARK:
                    {
                        Path bolt = new Path();
                        bolt.moveTo(cx + a.dp(1.2f), cy - a.dp(8.2f));
                        bolt.lineTo(cx - a.dp(5.2f), cy + a.dp(0.6f));
                        bolt.lineTo(cx + a.dp(0.2f), cy + a.dp(0.6f));
                        bolt.lineTo(cx - a.dp(1.2f), cy + a.dp(8.2f));
                        bolt.lineTo(cx + a.dp(5.2f), cy - a.dp(0.6f));
                        bolt.lineTo(cx - a.dp(0.2f), cy - a.dp(0.6f));
                        bolt.close();
                        c.drawPath(bolt, paint);
                        break;
                    }
                case ICON_TRASH_CLEAR:
                    {
                        c.drawLine(
                                cx - a.dp(7.2f),
                                cy - a.dp(5.2f),
                                cx + a.dp(7.2f),
                                cy - a.dp(5.2f),
                                paint);
                        RectF bin =
                                new RectF(
                                        cx - a.dp(5.2f),
                                        cy - a.dp(5.2f),
                                        cx + a.dp(5.2f),
                                        cy + a.dp(7.8f));
                        c.drawRoundRect(bin, a.dp(1.8f), a.dp(1.8f), paint);
                        break;
                    }
                case ICON_DIAGNOSTIC_LOG:
                    {
                        RectF box =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.8f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.8f));
                        c.drawRoundRect(box, a.dp(2.4f), a.dp(2.4f), paint);
                        Path pulse = new Path();
                        pulse.moveTo(cx - a.dp(5.8f), cy + a.dp(0.5f));
                        pulse.lineTo(cx - a.dp(2.6f), cy + a.dp(0.5f));
                        pulse.lineTo(cx - a.dp(1f), cy - a.dp(3.8f));
                        pulse.lineTo(cx + a.dp(1.2f), cy + a.dp(3.8f));
                        pulse.lineTo(cx + a.dp(2.8f), cy + a.dp(0.5f));
                        pulse.lineTo(cx + a.dp(5.8f), cy + a.dp(0.5f));
                        c.drawPath(pulse, paint);
                        break;
                    }
                case ICON_BACKUP_SAFE:
                    {
                        RectF lid =
                                new RectF(
                                        cx - a.dp(8.2f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.2f),
                                        cy - a.dp(2.2f));
                        c.drawRoundRect(lid, a.dp(1.5f), a.dp(1.5f), paint);
                        RectF body =
                                new RectF(
                                        cx - a.dp(7f),
                                        cy - a.dp(2.2f),
                                        cx + a.dp(7f),
                                        cy + a.dp(7.5f));
                        c.drawRoundRect(body, a.dp(2f), a.dp(2f), paint);
                        break;
                    }
                case ICON_WALLPAPER:
                    {
                        RectF frame =
                                new RectF(
                                        cx - a.dp(8.5f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8.5f),
                                        cy + a.dp(6.5f));
                        c.drawRoundRect(frame, a.dp(2.4f), a.dp(2.4f), paint);
                        Path mtn = new Path();
                        mtn.moveTo(cx - a.dp(6.5f), cy + a.dp(5.2f));
                        mtn.lineTo(cx - a.dp(1.5f), cy + a.dp(0.2f));
                        mtn.lineTo(cx + a.dp(1.8f), cy + a.dp(3.2f));
                        mtn.lineTo(cx + a.dp(6.8f), cy + a.dp(5.2f));
                        c.drawPath(mtn, paint);
                        break;
                    }
                case ICON_GRID_COLS:
                    {
                        float s = a.dp(5.8f), g = a.dp(1.4f);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy - g - s, cx - g, cy - g),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx + g, cy - g - s, cx + g + s, cy - g),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx - g - s, cy + g, cx - g, cy + g + s),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        c.drawRoundRect(
                                new RectF(cx + g, cy + g, cx + g + s, cy + g + s),
                                a.dp(1.4f),
                                a.dp(1.4f),
                                paint);
                        break;
                    }
                case ICON_AUDIO_WAVE:
                    {
                        c.drawLine(
                                cx - a.dp(6.8f),
                                cy - a.dp(3f),
                                cx - a.dp(6.8f),
                                cy + a.dp(3f),
                                paint);
                        c.drawLine(
                                cx - a.dp(3.4f),
                                cy - a.dp(7f),
                                cx - a.dp(3.4f),
                                cy + a.dp(7f),
                                paint);
                        c.drawLine(cx, cy - a.dp(4.5f), cx, cy + a.dp(4.5f), paint);
                        c.drawLine(
                                cx + a.dp(3.4f),
                                cy - a.dp(8f),
                                cx + a.dp(3.4f),
                                cy + a.dp(8f),
                                paint);
                        c.drawLine(
                                cx + a.dp(6.8f),
                                cy - a.dp(3.5f),
                                cx + a.dp(6.8f),
                                cy + a.dp(3.5f),
                                paint);
                        break;
                    }
                case ICON_ASPECT_RATIO:
                    {
                        RectF frame =
                                new RectF(
                                        cx - a.dp(8.8f),
                                        cy - a.dp(6f),
                                        cx + a.dp(8.8f),
                                        cy + a.dp(6f));
                        c.drawRoundRect(frame, a.dp(2.2f), a.dp(2.2f), paint);
                        break;
                    }
                case ICON_SPEED_GAUGE:
                    {
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(8f),
                                        cy - a.dp(6.5f),
                                        cx + a.dp(8f),
                                        cy + a.dp(9.5f)),
                                155,
                                230,
                                false,
                                paint);
                        c.drawLine(cx, cy + a.dp(2f), cx + a.dp(4.2f), cy - a.dp(3.2f), paint);
                        break;
                    }
                case ICON_REPEAT_LOOP:
                    {
                        c.drawArc(
                                new RectF(
                                        cx - a.dp(7.5f),
                                        cy - a.dp(7.5f),
                                        cx + a.dp(7.5f),
                                        cy + a.dp(7.5f)),
                                -45,
                                290,
                                false,
                                paint);
                        c.drawLine(cx, cy - a.dp(3.5f), cx, cy + a.dp(0.5f), paint);
                        c.drawLine(cx, cy + a.dp(0.5f), cx + a.dp(2.8f), cy + a.dp(2.2f), paint);
                        break;
                    }
                case ICON_SYSTEM:
                case ICON_UPDATE_CLOUD:
                default:
                    {
                        c.drawArc(
                                new RectF(a.dp(9.5f), a.dp(9.5f), w - a.dp(9.5f), h - a.dp(9.5f)),
                                -30,
                                300,
                                false,
                                paint);
                        c.drawLine(cx, a.dp(13f), cx, cy + a.dp(3.5f), paint);
                        c.drawLine(cx - a.dp(2.8f), cy + a.dp(0.8f), cx, cy + a.dp(3.6f), paint);
                        c.drawLine(cx + a.dp(2.8f), cy + a.dp(0.8f), cx, cy + a.dp(3.6f), paint);
                        break;
                    }
            }
        }
    }
}

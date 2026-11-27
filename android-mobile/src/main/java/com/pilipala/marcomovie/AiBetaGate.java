package com.pilipala.marcomovie;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Typeface;
import android.net.Uri;
import android.text.InputType;
import android.view.Gravity;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONObject;

/**
 * Unified cross-platform (Android Mobile / iOS / Windows) offline RFC 8032 Ed25519 beta passcode
 * gate for Marco Movie AI Cinema Lab.
 *
 * <p>Canonical format shared with Windows &amp; iOS ({@code flutter/lib/core/ai_lab_passcode.dart}
 * and {@code scripts/sign_manifest.py}): {@code MMAILAB1.<payload_b64url>.<sig_b64url>} where the
 * 64-byte Ed25519 signature covers {@code utf8("marco-ai-lab-v1:") + decoded_payload_bytes}.
 *
 * <p>Only the 32-byte Ed25519 public key is embedded in the APK; the signing seed stays offline on
 * the author's machine / password-locked mobile keygen. Persists active token in device-local
 * {@link #PREFS_FILE} strictly outside {@link Prefs#KEYS}.
 */
final class AiBetaGate {
    static final String TOKEN_PREFIX = "MMAILAB1";
    static final String SIGNING_DOMAIN_PREFIX = "marco-ai-lab-v1:";
    static final String PREFS_FILE = "marco_ai_beta";
    static final String KEY_ACTIVE_CODE = "active_passcode";
    static final String KEY_ACTIVATED_AT = "activated_at_ms";

    static final String PLATFORM_ANDROID = "android";
    static final String PLATFORM_IOS = "ios";
    static final String PLATFORM_WINDOWS = "windows";

    /**
     * Unified 32-byte Ed25519 public key shared across Android Mobile, iOS, and Windows
     * ({@code private/ai-lab-ed25519.pub}).
     */
    static final String DEFAULT_PUBLIC_KEY_HEX =
            "1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929";

    private static final Pattern TOKEN_EXTRACT_RE =
            Pattern.compile("MMAILAB1\\.([A-Za-z0-9_-]+)\\.([A-Za-z0-9_-]+)");

    private AiBetaGate() {}

    /** Device-local store abstraction for pure-JVM testing without Android framework stubs. */
    interface Store {
        String getString(String key, String def);

        void putString(String key, String value);

        long getLong(String key, long def);

        void putLong(String key, long value);

        void remove(String key);
    }

    static final class SharedPrefsStore implements Store {
        private final SharedPreferences prefs;

        SharedPrefsStore(Context ctx) {
            this.prefs = ctx.getApplicationContext().getSharedPreferences(PREFS_FILE, 0);
        }

        @Override
        public String getString(String key, String def) {
            return prefs.getString(key, def);
        }

        @Override
        public void putString(String key, String value) {
            prefs.edit().putString(key, value).apply();
        }

        @Override
        public long getLong(String key, long def) {
            return prefs.getLong(key, def);
        }

        @Override
        public void putLong(String key, long value) {
            prefs.edit().putLong(key, value).apply();
        }

        @Override
        public void remove(String key) {
            prefs.edit().remove(key).apply();
        }
    }

    static final class VerifyResult {
        final boolean ok;
        final boolean signatureValid;
        final String errorReason;
        final int version;
        final String tag;
        final long issuedAtEpochSec;
        final long expiresAtEpochSec;
        final String platformSpec;
        final boolean sharedChannel;
        final boolean experimentalOAuth;
        final int minVersionCode;
        final String canonicalToken;

        private VerifyResult(
                boolean ok,
                boolean signatureValid,
                String errorReason,
                int version,
                String tag,
                long issuedAtEpochSec,
                long expiresAtEpochSec,
                String platformSpec,
                boolean sharedChannel,
                boolean experimentalOAuth,
                int minVersionCode,
                String canonicalToken) {
            this.ok = ok;
            this.signatureValid = signatureValid;
            this.errorReason = errorReason == null ? "" : errorReason;
            this.version = version;
            this.tag = tag == null ? "" : tag;
            this.issuedAtEpochSec = issuedAtEpochSec;
            this.expiresAtEpochSec = expiresAtEpochSec;
            this.platformSpec =
                    platformSpec == null || platformSpec.trim().isEmpty()
                            ? "all"
                            : platformSpec.trim();
            this.sharedChannel = sharedChannel;
            this.experimentalOAuth = experimentalOAuth;
            this.minVersionCode = minVersionCode;
            this.canonicalToken = canonicalToken == null ? "" : canonicalToken;
        }

        static VerifyResult fail(String reason) {
            return new VerifyResult(
                    false, false, reason, 0, "", 0L, 0L, "all", false, false, 0, "");
        }

        static VerifyResult failAfterValidSig(
                String reason,
                int version,
                String tag,
                long iat,
                long exp,
                String plat,
                boolean shared,
                boolean expOAuth,
                int minVc,
                String canonical) {
            return new VerifyResult(
                    false, true, reason, version, tag, iat, exp, plat, shared, expOAuth, minVc,
                    canonical);
        }

        static VerifyResult success(
                int version,
                String tag,
                long iat,
                long exp,
                String plat,
                boolean shared,
                boolean expOAuth,
                int minVc,
                String canonical) {
            return new VerifyResult(
                    true, true, "", version, tag, iat, exp, plat, shared, expOAuth, minVc,
                    canonical);
        }

        boolean coreAiEnabled() {
            return ok;
        }

        boolean experimentalOAuthAllowed() {
            return ok && experimentalOAuth;
        }

        boolean sharedChannel() {
            return ok && sharedChannel;
        }

        String platformScopeLabel() {
            return AiBetaGate.platformScopeLabel(platformSpec);
        }

        String expireDateLabel() {
            if (!ok) return "";
            if (expiresAtEpochSec <= 0L) return "永久有效";
            SimpleDateFormat fmt = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
            fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
            return fmt.format(new Date(expiresAtEpochSec * 1000L));
        }

        String summaryBadge() {
            if (!ok) return "未解锁";
            StringBuilder sb = new StringBuilder();
            sb.append(tag.isEmpty() ? "内测口令" : tag);
            sb.append(" · ").append(platformScopeLabel());
            sb.append(sharedChannel ? " · 频道通用" : " · 专属内测");
            sb.append(" · ");
            sb.append(expiresAtEpochSec <= 0L ? "永久有效" : ("有效至 " + expireDateLabel()));
            return sb.toString();
        }
    }

    private static final int ED25519_SIG_B64URL_LEN = 86;

    /**
     * Extracts {@code MMAILAB1.<payload>.<sig>} even when pasted inside prose or wrapped across
     * newlines inside either the payload or the 86-char Base64URL signature segment.
     */
    static String extractToken(String raw) {
        if (raw == null) return "";
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return "";

        // 1. Fast path: an unwrapped token whose signature already decodes to a complete 64 bytes.
        Matcher direct = TOKEN_EXTRACT_RE.matcher(trimmed);
        while (direct.find()) {
            byte[] sig = base64UrlDecode(direct.group(2));
            if (sig != null && sig.length == 64) {
                return direct.group(0);
            }
        }

        // 2. Wrap-aware scan starting at "MMAILAB1." (tolerates spaces/newlines inside payload or
        //    signature without swallowing trailing ASCII prose after the 86-char Ed25519
        // signature).
        int start = trimmed.indexOf(TOKEN_PREFIX + ".");
        if (start >= 0) {
            String scanned = scanWrappedToken(trimmed, start);
            if (!scanned.isEmpty()) return scanned;
        }

        // 3. Fallback: whitespace-collapsed scan (handles breaks even inside the "MMAILAB1."
        // prefix).
        String collapsed = stripWhitespace(trimmed);
        int cStart = collapsed.indexOf(TOKEN_PREFIX + ".");
        if (cStart >= 0) {
            String scanned = scanWrappedToken(collapsed, cStart);
            if (!scanned.isEmpty()) return scanned;
        }
        Matcher after = TOKEN_EXTRACT_RE.matcher(collapsed);
        if (after.find()) return after.group(0);
        return collapsed;
    }

    private static boolean isBase64UrlChar(char c) {
        return (c >= 'A' && c <= 'Z')
                || (c >= 'a' && c <= 'z')
                || (c >= '0' && c <= '9')
                || c == '-'
                || c == '_';
    }

    private static String scanWrappedToken(String text, int start) {
        int pos = start + TOKEN_PREFIX.length() + 1; // right after "MMAILAB1."
        int len = text.length();
        StringBuilder payload = new StringBuilder();
        while (pos < len) {
            char c = text.charAt(pos);
            if (Character.isWhitespace(c)) {
                pos++;
                continue;
            }
            if (c == '.') {
                pos++;
                break;
            }
            if (isBase64UrlChar(c)) {
                payload.append(c);
                pos++;
                continue;
            }
            return "";
        }
        if (payload.length() == 0) return "";

        StringBuilder sig = new StringBuilder();
        while (pos < len) {
            char c = text.charAt(pos);
            if (Character.isWhitespace(c)) {
                // Once we already have the exact 86-char Base64URL Ed25519 signature, whitespace
                // marks the end of the token so trailing ASCII words are not appended.
                if (sig.length() >= ED25519_SIG_B64URL_LEN) break;
                pos++;
                continue;
            }
            if (isBase64UrlChar(c)) {
                sig.append(c);
                pos++;
                continue;
            }
            break;
        }
        if (sig.length() == 0) return "";
        return TOKEN_PREFIX + "." + payload + "." + sig;
    }

    static boolean matchesPlatform(String platformSpec, String targetPlatform) {
        String p = platformSpec == null ? "" : platformSpec.trim().toLowerCase(Locale.ROOT);
        if (p.isEmpty() || "all".equals(p) || "*".equals(p)) return true;
        String target =
                targetPlatform == null ? "" : targetPlatform.trim().toLowerCase(Locale.ROOT);
        if (target.isEmpty()) return true;
        for (String part : p.split("[,;/\\s]+")) {
            String tok = normalizePlatformToken(part);
            if ("all".equals(tok) || tok.equals(target)) return true;
        }
        return false;
    }

    static String platformScopeLabel(String platformSpec) {
        String p = platformSpec == null ? "" : platformSpec.trim().toLowerCase(Locale.ROOT);
        if (p.isEmpty() || "all".equals(p) || "*".equals(p)) return "三端通用";
        boolean hasAnd = false;
        boolean hasIos = false;
        boolean hasWin = false;
        List<String> extras = new ArrayList<>();
        for (String part : p.split("[,;/\\s]+")) {
            String tok = normalizePlatformToken(part);
            if (tok.isEmpty()) continue;
            if ("all".equals(tok)) return "三端通用";
            if (PLATFORM_ANDROID.equals(tok)) hasAnd = true;
            else if (PLATFORM_IOS.equals(tok)) hasIos = true;
            else if (PLATFORM_WINDOWS.equals(tok)) hasWin = true;
            else if (!extras.contains(tok)) extras.add(tok);
        }
        if (hasAnd && hasIos && hasWin && extras.isEmpty()) return "三端通用";
        List<String> names = new ArrayList<>();
        if (hasAnd) names.add("安卓");
        if (hasIos) names.add("iOS");
        if (hasWin) names.add("Windows");
        names.addAll(extras);
        if (names.isEmpty()) return "三端通用";
        StringBuilder sb = new StringBuilder("仅限 ");
        for (int i = 0; i < names.size(); i++) {
            if (i > 0) sb.append("/");
            sb.append(names.get(i));
        }
        return sb.toString();
    }

    private static String normalizePlatformToken(String raw) {
        String s = raw == null ? "" : raw.trim().toLowerCase(Locale.ROOT);
        if ("android-mobile".equals(s) || "mobile".equals(s)) return PLATFORM_ANDROID;
        if ("win".equals(s) || "pc".equals(s)) return PLATFORM_WINDOWS;
        if ("iphone".equals(s) || "ipad".equals(s)) return PLATFORM_IOS;
        return s;
    }

    static VerifyResult verifyPasscode(
            String rawCode, int currentAppVersionCode, long nowEpochMillis) {
        return verifyPasscode(
                rawCode,
                currentAppVersionCode,
                nowEpochMillis,
                hexToBytes(DEFAULT_PUBLIC_KEY_HEX),
                PLATFORM_ANDROID);
    }

    static VerifyResult verifyPasscode(
            String rawCode, int currentAppVersionCode, long nowEpochMillis, byte[] pubKey32) {
        return verifyPasscode(
                rawCode, currentAppVersionCode, nowEpochMillis, pubKey32, PLATFORM_ANDROID);
    }

    /**
     * Pure-JVM RFC 8032 Ed25519 offline verification of a unified cross-platform AI Lab passcode.
     *
     * <p>Format: {@code MMAILAB1.<payload_b64url>.<sig_b64url>}.
     */
    static VerifyResult verifyPasscode(
            String rawCode,
            int currentAppVersionCode,
            long nowEpochMillis,
            byte[] pubKey32,
            String targetPlatform) {
        String cleaned = extractToken(rawCode);
        if (cleaned.isEmpty()) return VerifyResult.fail("请输入内测口令");
        if (pubKey32 == null || pubKey32.length != 32) {
            return VerifyResult.fail("内置 Ed25519 验签公钥异常");
        }
        Matcher m = TOKEN_EXTRACT_RE.matcher(cleaned);
        if (!m.matches()) {
            return VerifyResult.fail("口令格式不正确（应为 MMAILAB1.<载荷>.<签名>）");
        }
        String payloadB64 = m.group(1);
        String sigB64 = m.group(2);
        byte[] payloadBytes = base64UrlDecode(payloadB64);
        byte[] sigBytes = base64UrlDecode(sigB64);
        if (payloadBytes == null
                || payloadBytes.length == 0
                || sigBytes == null
                || sigBytes.length != 64) {
            return VerifyResult.fail("口令编码损坏，请确认完整复制了整段口令");
        }

        byte[] domain = SIGNING_DOMAIN_PREFIX.getBytes(StandardCharsets.UTF_8);
        byte[] message = new byte[domain.length + payloadBytes.length];
        System.arraycopy(domain, 0, message, 0, domain.length);
        System.arraycopy(payloadBytes, 0, message, domain.length, payloadBytes.length);

        if (!Ed25519.verify(pubKey32, message, sigBytes)) {
            return VerifyResult.fail("口令 Ed25519 离线签名校验未通过，请确认来源为官方渠道");
        }

        JSONObject claims;
        try {
            claims = new JSONObject(new String(payloadBytes, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return VerifyResult.fail("口令载荷无法解析");
        }

        int version = claims.optInt("v", 0);
        if (version != 1) {
            return VerifyResult.fail("不支持的口令版本（v" + version + "），请更新应用");
        }
        String tag = claims.optString("tag", claims.optString("id", "")).trim();
        long iat = Math.max(0L, claims.optLong("iat", 0L));
        long exp = Math.max(0L, claims.optLong("exp", 0L));
        String plat = claims.optString("plat", "all").trim();
        if (plat.isEmpty()) plat = "all";
        boolean shared = claims.optBoolean("shared", false);
        boolean expOAuth = claims.optBoolean("exp_oauth", false);
        int minVc = Math.max(0, claims.optInt("min_vc", 0));

        String canonical = TOKEN_PREFIX + "." + payloadB64 + "." + sigB64;
        if (!matchesPlatform(plat, targetPlatform)) {
            return VerifyResult.failAfterValidSig(
                    "该内测口令适用范围为「" + platformScopeLabel(plat) + "」，不适用于当前设备平台",
                    version,
                    tag,
                    iat,
                    exp,
                    plat,
                    shared,
                    expOAuth,
                    minVc,
                    canonical);
        }
        if (minVc > 0 && currentAppVersionCode > 0 && currentAppVersionCode < minVc) {
            return VerifyResult.failAfterValidSig(
                    "当前版本过低（需版本码 ≥ " + minVc + "），请前往官网更新",
                    version,
                    tag,
                    iat,
                    exp,
                    plat,
                    shared,
                    expOAuth,
                    minVc,
                    canonical);
        }
        long nowSec = nowEpochMillis / 1000L;
        if (exp > 0L && nowSec > exp) {
            return VerifyResult.failAfterValidSig(
                    "该内测口令已过期，请在官方交流频道获取最新口令",
                    version,
                    tag,
                    iat,
                    exp,
                    plat,
                    shared,
                    expOAuth,
                    minVc,
                    canonical);
        }

        return VerifyResult.success(
                version, tag, iat, exp, plat, shared, expOAuth, minVc, canonical);
    }

    static VerifyResult currentStatus(
            Store store, int currentAppVersionCode, long nowEpochMillis, byte[] pubKey32) {
        if (store == null) return VerifyResult.fail("未输入口令");
        String saved = store.getString(KEY_ACTIVE_CODE, "");
        if (saved == null || saved.trim().isEmpty()) {
            return VerifyResult.fail("尚未开启 AI 观影实验室");
        }
        return verifyPasscode(saved, currentAppVersionCode, nowEpochMillis, pubKey32);
    }

    static VerifyResult activate(
            Store store,
            String rawCode,
            int currentAppVersionCode,
            long nowEpochMillis,
            byte[] pubKey32) {
        VerifyResult r = verifyPasscode(rawCode, currentAppVersionCode, nowEpochMillis, pubKey32);
        if (r.ok && store != null) {
            store.putString(KEY_ACTIVE_CODE, r.canonicalToken);
            store.putLong(KEY_ACTIVATED_AT, nowEpochMillis);
        }
        return r;
    }

    static void deactivate(Store store) {
        if (store == null) return;
        store.remove(KEY_ACTIVE_CODE);
        store.remove(KEY_ACTIVATED_AT);
    }

    static VerifyResult currentStatus(Context ctx) {
        if (ctx == null) return VerifyResult.fail("上下文无效");
        return currentStatus(
                new SharedPrefsStore(ctx),
                MobileAuthorNotice.installedVersionCode(ctx),
                System.currentTimeMillis(),
                hexToBytes(DEFAULT_PUBLIC_KEY_HEX));
    }

    static boolean isUnlocked(Context ctx) {
        return currentStatus(ctx).coreAiEnabled();
    }

    static boolean isExperimentalOAuthAllowed(Context ctx) {
        return currentStatus(ctx).experimentalOAuthAllowed();
    }

    static VerifyResult activate(Context ctx, String rawCode) {
        if (ctx == null) return VerifyResult.fail("上下文无效");
        return activate(
                new SharedPrefsStore(ctx),
                rawCode,
                MobileAuthorNotice.installedVersionCode(ctx),
                System.currentTimeMillis(),
                hexToBytes(DEFAULT_PUBLIC_KEY_HEX));
    }

    static void deactivate(Context ctx) {
        if (ctx == null) return;
        deactivate(new SharedPrefsStore(ctx));
    }

    /** Bottom sheet for entering and verifying a unified MMAILAB1 Ed25519 passcode. */
    static void showUnlockSheet(final MainActivity a, final Runnable onUnlocked) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        LinearLayout body = a.vertical();
        body.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        LinearLayout infoCard = a.vertical();
        infoCard.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        infoCard.setBackground(a.bg(p.bgSubtle, 14));
        TextView infoTitle = a.text("Ed25519 离线验签 · 三端统一内测通道", 13.5f, p.textPrimary);
        infoTitle.setTypeface(null, Typeface.BOLD);
        infoCard.addView(infoTitle);
        a.gap(infoCard, 5);
        TextView infoDesc =
                a.text(
                        "「AI 观影实验室」包含全片滑动窗口双语字幕、播放页防剧透剧情/台词问答、AI 找片推荐，以及 API Key / 订阅账号双模式登录。当前为限量测试阶段，请输入作者签发的 MMAILAB1.… 口令（Android 移动端 / iOS / Windows 通用同一套口令体系）。",
                        12.5f,
                        p.textSecondary);
        infoDesc.setLineSpacing(a.dp(3f), 1f);
        infoCard.addView(infoDesc);
        body.addView(infoCard, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 14);

        TextView lbl = a.text("内测口令（MMAILAB1.…）", 12.5f, p.textSecondary);
        lbl.setTypeface(null, Typeface.BOLD);
        body.addView(lbl);
        a.gap(body, 6);

        final EditText codeInput = new EditText(a);
        codeInput.setHint("粘贴完整的 MMAILAB1.… 口令");
        codeInput.setTextColor(p.textPrimary);
        codeInput.setHintTextColor(p.textTertiary);
        codeInput.setTextSize(13.5f);
        codeInput.setSingleLine(false);
        codeInput.setMinLines(2);
        codeInput.setMaxLines(4);
        codeInput.setGravity(Gravity.TOP | Gravity.START);
        codeInput.setInputType(
                InputType.TYPE_CLASS_TEXT
                        | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                        | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        codeInput.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        codeInput.setBackground(MobileTheme.subtleBg(a, 12));
        body.addView(codeInput, new LinearLayout.LayoutParams(-1, -2));

        final TextView errorView = a.text("", 12f, p.danger);
        errorView.setPadding(a.dp(2), a.dp(6), a.dp(2), 0);
        errorView.setVisibility(android.view.View.GONE);
        body.addView(errorView, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 12);

        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];

        LinearLayout actionRow = a.row();
        actionRow.setGravity(Gravity.CENTER_VERTICAL);

        TextView pasteBtn = a.text("粘贴剪贴板", 13.5f, p.textPrimary);
        pasteBtn.setTypeface(null, Typeface.BOLD);
        pasteBtn.setGravity(Gravity.CENTER);
        pasteBtn.setBackground(a.bg(p.bgSubtle, 12));
        MobileMotion.bindPress(pasteBtn, 0.95f);
        pasteBtn.setOnClickListener(
                v -> {
                    try {
                        ClipboardManager cm =
                                (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
                        if (cm != null && cm.hasPrimaryClip()) {
                            ClipData clip = cm.getPrimaryClip();
                            if (clip != null && clip.getItemCount() > 0) {
                                CharSequence cs = clip.getItemAt(0).coerceToText(a);
                                if (cs != null && cs.length() > 0) {
                                    String pasted = extractToken(cs.toString());
                                    codeInput.setText(pasted);
                                    codeInput.setSelection(pasted.length());
                                    errorView.setVisibility(android.view.View.GONE);
                                    return;
                                }
                            }
                        }
                        a.toast("剪贴板暂无口令文本");
                    } catch (Exception ignored) {
                        a.toast("无法读取剪贴板，请手动粘贴");
                    }
                });

        TextView unlockBtn = a.text("验证并开启内测", 13.5f, p.accentOnFill);
        unlockBtn.setTypeface(null, Typeface.BOLD);
        unlockBtn.setGravity(Gravity.CENTER);
        unlockBtn.setBackground(MobileTheme.accentPillBg(a, 12));
        MobileMotion.bindPress(unlockBtn, 0.95f);
        unlockBtn.setOnClickListener(
                v -> {
                    String entered = codeInput.getText().toString();
                    VerifyResult res = activate(a, entered);
                    if (!res.ok) {
                        errorView.setText(res.errorReason);
                        errorView.setVisibility(android.view.View.VISIBLE);
                        MobileMotion.shakeInvalid(codeInput);
                        return;
                    }
                    if (hRef[0] != null) hRef[0].dismiss();
                    a.toast("AI 观影实验室已开启：" + res.summaryBadge());
                    if (onUnlocked != null) onUnlocked.run();
                });

        LinearLayout.LayoutParams pLp = new LinearLayout.LayoutParams(0, a.dp(44), 1f);
        pLp.rightMargin = a.dp(8);
        actionRow.addView(pasteBtn, pLp);
        actionRow.addView(unlockBtn, new LinearLayout.LayoutParams(0, a.dp(44), 1.4f));
        body.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));

        a.gap(body, 10);
        TextView channelBtn = a.text("前往官方交流频道（Marco交流区）获取内测口令", 12.5f, p.accent);
        channelBtn.setGravity(Gravity.CENTER);
        channelBtn.setPadding(a.dp(10), a.dp(8), a.dp(10), a.dp(8));
        MobileMotion.bindPress(channelBtn, 0.96f);
        channelBtn.setOnClickListener(
                v -> {
                    try {
                        a.startActivity(
                                new Intent(
                                        Intent.ACTION_VIEW,
                                        Uri.parse(MobileAuthorNotice.OFFICIAL_CHANNEL_URL)));
                    } catch (Exception e) {
                        a.toast("无法打开链接，请手动访问官网交流频道");
                    }
                });
        body.addView(channelBtn, new LinearLayout.LayoutParams(-1, -2));

        hRef[0] =
                MobileBottomSheet.showHandle(
                        a, "开启 AI 观影实验室", "内测功能需使用作者签发口令离线验证", null, null, body, true);
    }

    // -------------------------------------------------------------------------
    // Pure-Java RFC 8032 Ed25519 Verifier (Zero Dependencies, API 23+ & JDK 17)
    // -------------------------------------------------------------------------

    static final class Ed25519 {
        private static final BigInteger Q =
                BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19));
        private static final BigInteger L =
                BigInteger.ONE
                        .shiftLeft(252)
                        .add(new BigInteger("27742317777372353535851937790883648493"));
        private static final BigInteger D =
                BigInteger.valueOf(-121665)
                        .multiply(BigInteger.valueOf(121666).modInverse(Q))
                        .mod(Q);
        private static final BigInteger TWO_D = D.shiftLeft(1).mod(Q);
        private static final BigInteger I =
                BigInteger.valueOf(2).modPow(Q.subtract(BigInteger.ONE).shiftRight(2), Q);
        private static final BigInteger Q_PLUS_3_DIV_8 = Q.add(BigInteger.valueOf(3)).shiftRight(3);
        private static final ExtPoint BASE;

        static {
            BigInteger by =
                    BigInteger.valueOf(4).multiply(BigInteger.valueOf(5).modInverse(Q)).mod(Q);
            BigInteger bx = recoverX(by, 0);
            BASE = new ExtPoint(bx, by, BigInteger.ONE, bx.multiply(by).mod(Q));
        }

        private static final class ExtPoint {
            final BigInteger x, y, z, t;

            ExtPoint(BigInteger x, BigInteger y, BigInteger z, BigInteger t) {
                this.x = x;
                this.y = y;
                this.z = z;
                this.t = t;
            }
        }

        private static final ExtPoint IDENTITY =
                new ExtPoint(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO);

        private Ed25519() {}

        static boolean verify(byte[] publicKey, byte[] message, byte[] signature) {
            if (publicKey == null
                    || publicKey.length != 32
                    || signature == null
                    || signature.length != 64
                    || message == null) {
                return false;
            }
            try {
                byte[] rBytes = new byte[32];
                byte[] sBytes = new byte[32];
                System.arraycopy(signature, 0, rBytes, 0, 32);
                System.arraycopy(signature, 32, sBytes, 0, 32);
                BigInteger s = decodeLittleEndian(sBytes);
                if (s.signum() < 0 || s.compareTo(L) >= 0) return false;

                ExtPoint rPt = decodePoint(rBytes);
                ExtPoint aPt = decodePoint(publicKey);
                if (rPt == null || aPt == null) return false;

                MessageDigest sha512 = MessageDigest.getInstance("SHA-512");
                sha512.update(rBytes);
                sha512.update(publicKey);
                sha512.update(message);
                BigInteger k = decodeLittleEndian(sha512.digest()).mod(L);

                ExtPoint lhs = scalarMult(BASE, s);
                ExtPoint rhs = add(rPt, scalarMult(aPt, k));
                return pointsEqual(lhs, rhs);
            } catch (Exception e) {
                return false;
            }
        }

        private static BigInteger decodeLittleEndian(byte[] b) {
            byte[] be = new byte[b.length + 1];
            for (int i = 0; i < b.length; i++) {
                be[b.length - i] = b[i];
            }
            return new BigInteger(be);
        }

        private static BigInteger recoverX(BigInteger y, int signBit) {
            if (y.compareTo(Q) >= 0) return null;
            BigInteger y2 = y.multiply(y).mod(Q);
            BigInteger u = y2.subtract(BigInteger.ONE).mod(Q);
            BigInteger v = D.multiply(y2).add(BigInteger.ONE).mod(Q);
            if (v.signum() == 0) return null;
            BigInteger xx = u.multiply(v.modInverse(Q)).mod(Q);
            BigInteger x = xx.modPow(Q_PLUS_3_DIV_8, Q);
            BigInteger x2 = x.multiply(x).mod(Q);
            if (!x2.equals(xx)) {
                x = x.multiply(I).mod(Q);
                x2 = x.multiply(x).mod(Q);
                if (!x2.equals(xx)) return null;
            }
            if (x.signum() == 0 && signBit == 1) return null;
            if ((x.testBit(0) ? 1 : 0) != signBit) {
                x = Q.subtract(x);
            }
            return x;
        }

        private static ExtPoint decodePoint(byte[] enc) {
            if (enc.length != 32) return null;
            int signBit = (enc[31] >> 7) & 1;
            byte[] copy = enc.clone();
            copy[31] &= 0x7F;
            BigInteger y = decodeLittleEndian(copy);
            BigInteger x = recoverX(y, signBit);
            if (x == null) return null;
            return new ExtPoint(x, y, BigInteger.ONE, x.multiply(y).mod(Q));
        }

        private static ExtPoint add(ExtPoint p1, ExtPoint p2) {
            BigInteger a = p1.y.subtract(p1.x).multiply(p2.y.subtract(p2.x)).mod(Q);
            BigInteger b = p1.y.add(p1.x).multiply(p2.y.add(p2.x)).mod(Q);
            BigInteger c = p1.t.multiply(TWO_D).multiply(p2.t).mod(Q);
            BigInteger d = p1.z.shiftLeft(1).multiply(p2.z).mod(Q);
            BigInteger e = b.subtract(a).mod(Q);
            BigInteger f = d.subtract(c).mod(Q);
            BigInteger g = d.add(c).mod(Q);
            BigInteger h = b.add(a).mod(Q);
            BigInteger x3 = e.multiply(f).mod(Q);
            BigInteger y3 = g.multiply(h).mod(Q);
            BigInteger t3 = e.multiply(h).mod(Q);
            BigInteger z3 = f.multiply(g).mod(Q);
            return new ExtPoint(x3, y3, z3, t3);
        }

        private static ExtPoint scalarMult(ExtPoint base, BigInteger scalar) {
            ExtPoint result = IDENTITY;
            ExtPoint addend = base;
            int bits = scalar.bitLength();
            for (int i = 0; i < bits; i++) {
                if (scalar.testBit(i)) {
                    result = add(result, addend);
                }
                addend = add(addend, addend);
            }
            return result;
        }

        private static boolean pointsEqual(ExtPoint p1, ExtPoint p2) {
            return p1.x.multiply(p2.z).mod(Q).equals(p2.x.multiply(p1.z).mod(Q))
                    && p1.y.multiply(p2.z).mod(Q).equals(p2.y.multiply(p1.z).mod(Q));
        }
    }

    static String stripWhitespace(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!Character.isWhitespace(c)) sb.append(c);
        }
        return sb.toString();
    }

    static byte[] hexToBytes(String hex) {
        if (hex == null || (hex.length() & 1) != 0) return new byte[0];
        int len = hex.length() / 2;
        byte[] out = new byte[len];
        for (int i = 0; i < len; i++) {
            int hi = Character.digit(hex.charAt(i * 2), 16);
            int lo = Character.digit(hex.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) return new byte[0];
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    /** Pure-JVM Base64URL decoder (no {@code android.util.Base64} or API 26 dependency). */
    static byte[] base64UrlDecode(String input) {
        if (input == null || input.isEmpty()) return null;
        int len = input.length();
        while (len > 0 && input.charAt(len - 1) == '=') len--;
        if ((len & 3) == 1) return null;
        int outLen = (len * 3) / 4;
        byte[] out = new byte[outLen];
        int outPos = 0;
        int i = 0;
        while (i < len) {
            int c0 = b64Val(input.charAt(i++));
            int c1 = i < len ? b64Val(input.charAt(i++)) : -1;
            int c2 = i < len ? b64Val(input.charAt(i++)) : -2;
            int c3 = i < len ? b64Val(input.charAt(i++)) : -2;
            if (c0 < 0 || c1 < 0 || c2 == -1 || c3 == -1) return null;
            int triple = (c0 << 18) | (c1 << 12) | ((c2 >= 0 ? c2 : 0) << 6) | (c3 >= 0 ? c3 : 0);
            if (outPos < outLen) out[outPos++] = (byte) ((triple >> 16) & 0xFF);
            if (c2 >= 0 && outPos < outLen) out[outPos++] = (byte) ((triple >> 8) & 0xFF);
            if (c3 >= 0 && outPos < outLen) out[outPos++] = (byte) (triple & 0xFF);
        }
        return out;
    }

    private static int b64Val(char c) {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '-' || c == '+') return 62;
        if (c == '_' || c == '/') return 63;
        return -1;
    }
}

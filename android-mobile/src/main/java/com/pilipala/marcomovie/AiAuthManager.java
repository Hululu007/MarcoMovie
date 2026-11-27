package com.pilipala.marcomovie;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Typeface;
import android.net.Uri;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URL;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Dual-mode AI Authentication &amp; Multi-Protocol Transport Manager (strictly clean-room: zero
 * third-party CLI/IDE identity spoofing, strict provider+origin BYOK key scoping, mandatory HTTPS
 * for credentialed endpoints, atomic session-versioned OAuth commits, and full log redaction).
 */
final class AiAuthManager {
    static final String PREFS_FILE = "marco_ai_oauth";
    static final String KEY_AUTH_MODE = "ai_auth_mode";
    static final String KEY_OAUTH_PROVIDER = "ai_oauth_provider";
    static final String KEY_OAUTH_MODEL_PREFIX = "ai_oauth_model_";
    static final String KEY_OAUTH_BUNDLE_PREFIX = "ai_oauth_bundle_";
    static final String KEY_OAUTH_SESSION_VER_PREFIX = "ai_oauth_ver_";
    static final String KEY_OAUTH_CLIENT_ID_PREFIX = "ai_oauth_client_id_";
    static final String KEY_AUTH_SELECTION_EPOCH = "ai_auth_selection_epoch";
    static final String KEY_OPENAI_EXPERIMENTAL_CONSENT = "ai_openai_oauth_consent";

    static final String SCOPED_API_KEY_PREFIX = "ai_api_key_v2:";

    static final String AUTH_MODE_API_KEY = "api_key";
    static final String AUTH_MODE_OAUTH = "oauth";

    static final String WIRE_OPENAI_COMPAT = "openai_compat";
    static final String WIRE_OPENAI_RESPONSES = "openai_responses";
    static final String WIRE_ANTHROPIC = "anthropic";
    static final String WIRE_GEMINI = "gemini";

    // OAuth provider IDs
    static final String OAUTH_OPENROUTER = "openrouter_oauth";
    static final String OAUTH_KIMI_CODE = "kimi_code";
    static final String OAUTH_OPENAI_EXPERIMENTAL = "openai_oauth";

    /** Shipped 0.7.3 OAuth UI provider list (unverified experimental paths withdrawn in 0.7.3). */
    static final String[] SHIPPED_OAUTH_PROVIDER_IDS = {OAUTH_OPENROUTER};

    static final String[] SHIPPED_OAUTH_PROVIDER_LABELS = {"OpenRouter 官方账号登录 (PKCE)"};

    static final String[] OAUTH_PROVIDER_IDS = {
        OAUTH_OPENROUTER, OAUTH_KIMI_CODE, OAUTH_OPENAI_EXPERIMENTAL
    };
    static final String[] OAUTH_PROVIDER_LABELS = {
        "OpenRouter 官方账号登录 (PKCE)", "Kimi Code 设备码登录 (当前版本已撤下)", "OpenAI 订阅账号登录 (当前版本已撤下)"
    };

    static boolean isShippedOAuthProvider(String providerId) {
        return OAUTH_OPENROUTER.equals(providerId);
    }

    static boolean providerRequiresClientId(String providerId) {
        return OAUTH_KIMI_CODE.equals(providerId) || OAUTH_OPENAI_EXPERIMENTAL.equals(providerId);
    }

    // Official OAuth endpoints (all registered in scripts/check_public_content.py ALLOWED_HOSTS)
    static final String OPENROUTER_AUTH_URL = "https://openrouter.ai/auth";
    static final String OPENROUTER_EXCHANGE_URL = "https://openrouter.ai/api/v1/auth/keys";
    static final String OPENROUTER_API_BASE = "https://openrouter.ai/api/v1";

    static final String KIMI_DEVICE_AUTH_URL =
            "https://auth.kimi.com/api/oauth/device_authorization";
    static final String KIMI_TOKEN_URL = "https://auth.kimi.com/api/oauth/token";
    static final String KIMI_CODE_API_BASE = "https://api.kimi.com/coding/v1";

    static final String OPENAI_AUTH_URL = "https://auth.openai.com/oauth/authorize";
    static final String OPENAI_TOKEN_URL = "https://auth.openai.com/oauth/token";
    static final String OPENAI_API_BASE = "https://api.openai.com/v1";

    /**
     * Official OpenAI delegated subscription/plan-usage OAuth scopes required for direct Responses
     * API inference against a user's ChatGPT plan quota.
     */
    static final String OPENAI_PLAN_USAGE_SCOPES =
            "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

    private static final long REFRESH_BUFFER_MS = 5L * 60_000L;
    private static final Object FOREGROUND_LOCK = new Object();
    private static volatile boolean activityForeground = true;

    /** Serializes network token refresh per provider so concurrent calls do not stampede. */
    private static final ConcurrentHashMap<String, Object> REFRESH_LOCKS =
            new ConcurrentHashMap<>();

    /** Fast non-blocking state lock for atomic session version checks and Store commits. */
    private static final ConcurrentHashMap<String, Object> SESSION_STATE_LOCKS =
            new ConcurrentHashMap<>();

    /** Global lock coordinating active auth mode/provider selection epochs and OAuth commits. */
    private static final Object AUTH_SELECTION_LOCK = new Object();

    private AiAuthManager() {}

    /** Device-local string store abstraction for pure-JVM testing. */
    interface Store {
        String getString(String key, String def);

        void putString(String key, String value);

        boolean getBoolean(String key, boolean def);

        void putBoolean(String key, boolean value);

        void remove(String key);
    }

    /** Gate re-check predicate invoked before starting OAuth and right before committing tokens. */
    interface GateCheck {
        boolean isAllowed();
    }

    /** Pluggable HTTP transport for deterministic pure-JVM testing with strict HTTPS checking. */
    interface HttpTransport {
        HttpResult postRaw(String url, String contentType, String body, Map<String, String> headers)
                throws IOException;
    }

    static final HttpTransport DEFAULT_TRANSPORT = AiAuthManager::postRawDirect;

    static final class SharedPrefsStore implements Store {
        private final SharedPreferences prefs;

        SharedPrefsStore(Context ctx) {
            this.prefs = ctx.getApplicationContext().getSharedPreferences(PREFS_FILE, 0);
        }

        SharedPrefsStore(SharedPreferences prefs) {
            this.prefs = prefs;
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
        public boolean getBoolean(String key, boolean def) {
            return prefs.getBoolean(key, def);
        }

        @Override
        public void putBoolean(String key, boolean value) {
            prefs.edit().putBoolean(key, value).apply();
        }

        @Override
        public void remove(String key) {
            prefs.edit().remove(key).apply();
        }
    }

    static final class PkcePair {
        final String verifier;
        final String challenge;
        final String state;

        PkcePair(String verifier, String challenge, String state) {
            this.verifier = verifier;
            this.challenge = challenge;
            this.state = state;
        }
    }

    static final class OAuthBundle {
        String providerId = "";
        String accessToken = "";
        String refreshToken = "";
        String accountLabel = "";
        String accountId = "";
        String planType = "";
        long expiresAtMs = 0L; // 0 = non-expiring (e.g. OpenRouter permanent key)
        boolean needsReauth = false;

        boolean hasCredential() {
            return accessToken != null && !accessToken.trim().isEmpty();
        }

        boolean isExpiringSoon(long nowMs) {
            return expiresAtMs > 0 && nowMs + REFRESH_BUFFER_MS >= expiresAtMs;
        }

        String statusSummary() {
            if (!hasCredential()) return "未登录";
            if (needsReauth) return "授权已失效，请重新登录";
            StringBuilder sb = new StringBuilder("已登录");
            if (accountLabel != null && !accountLabel.isEmpty()) {
                sb.append(" · ").append(accountLabel);
            } else if (planType != null && !planType.isEmpty()) {
                sb.append(" · ").append(planType);
            }
            return sb.toString();
        }

        JSONObject toJson() {
            JSONObject o = new JSONObject();
            try {
                o.put("provider_id", providerId);
                o.put("access_token", accessToken);
                o.put("refresh_token", refreshToken);
                o.put("account_label", accountLabel);
                o.put("account_id", accountId);
                o.put("plan_type", planType);
                o.put("expires_at_ms", expiresAtMs);
                o.put("needs_reauth", needsReauth);
            } catch (Exception ignored) {
            }
            return o;
        }

        static OAuthBundle fromJson(String raw) {
            if (raw == null || raw.trim().isEmpty()) return null;
            try {
                JSONObject o = new JSONObject(raw);
                OAuthBundle b = new OAuthBundle();
                b.providerId = o.optString("provider_id", "");
                b.accessToken = o.optString("access_token", "");
                b.refreshToken = o.optString("refresh_token", "");
                b.accountLabel = o.optString("account_label", "");
                b.accountId = o.optString("account_id", "");
                b.planType = o.optString("plan_type", "");
                b.expiresAtMs = o.optLong("expires_at_ms", 0L);
                b.needsReauth = o.optBoolean("needs_reauth", false);
                return b;
            } catch (Exception e) {
                return null;
            }
        }
    }

    static final class DeviceCodeSession {
        final String deviceCode;
        final String userCode;
        final String verificationUri;
        final String verificationUriComplete;
        final int expiresInSec;
        final int intervalSec;

        DeviceCodeSession(
                String deviceCode,
                String userCode,
                String verificationUri,
                String verificationUriComplete,
                int expiresInSec,
                int intervalSec) {
            this.deviceCode = deviceCode;
            this.userCode = userCode;
            this.verificationUri = verificationUri;
            this.verificationUriComplete = verificationUriComplete;
            this.expiresInSec = expiresInSec;
            this.intervalSec = intervalSec;
        }
    }

    static final class ResolvedRequest {
        final String wireProtocol;
        final String baseUrl;
        final String model;
        final String credential;
        final String oauthProviderId; // empty for API key mode
        final String chatGptAccountId;

        ResolvedRequest(
                String wireProtocol,
                String baseUrl,
                String model,
                String credential,
                String oauthProviderId,
                String chatGptAccountId) {
            this.wireProtocol = wireProtocol;
            this.baseUrl = baseUrl;
            this.model = model;
            this.credential = credential == null ? "" : credential;
            this.oauthProviderId = oauthProviderId == null ? "" : oauthProviderId;
            this.chatGptAccountId = chatGptAccountId == null ? "" : chatGptAccountId;
        }
    }

    // -------------------------------------------------------------------------
    // BYOK Credential Origin-Binding & HTTPS Security Gate (P1-2)
    // -------------------------------------------------------------------------

    /**
     * Extracts canonical origin {@code scheme://host[:non-default-port]} for credential binding.
     * Returns empty string for malformed or non-HTTP(S) URLs.
     */
    static String canonicalOrigin(String urlStr) {
        if (urlStr == null || urlStr.trim().isEmpty()) return "";
        try {
            URI u = URI.create(urlStr.trim());
            String scheme = u.getScheme() == null ? "" : u.getScheme().toLowerCase(Locale.ROOT);
            if (!"http".equals(scheme) && !"https".equals(scheme)) return "";
            String host = u.getHost();
            if (host == null || host.trim().isEmpty()) return "";
            host = host.trim().toLowerCase(Locale.ROOT);
            int port = u.getPort();
            boolean defaultPort =
                    port <= 0
                            || ("http".equals(scheme) && port == 80)
                            || ("https".equals(scheme) && port == 443);
            return defaultPort ? (scheme + "://" + host) : (scheme + "://" + host + ":" + port);
        } catch (Exception e) {
            return "";
        }
    }

    static boolean isHttpsUrl(String urlStr) {
        String origin = canonicalOrigin(urlStr);
        return origin.startsWith("https://");
    }

    /**
     * Enforces HTTPS whenever carrying any API key or OAuth bearer credential. Plaintext HTTP is
     * strictly rejected for credentialed requests and allowed ONLY for keyless local endpoints
     * (such as keyless local Ollama).
     */
    static void validateTransportSecurity(String endpointUrl, String credential)
            throws IOException {
        String origin = canonicalOrigin(endpointUrl);
        if (origin.isEmpty()) {
            throw new IOException("无效的 AI 接口地址，仅支持 HTTP/HTTPS 规范 URL");
        }
        boolean hasCred = credential != null && !credential.trim().isEmpty();
        if (hasCred && !origin.startsWith("https://")) {
            throw new IOException("携带 API Key 或 OAuth 凭据时必须使用 HTTPS 安全地址（已拦截明文 HTTP 请求）");
        }
    }

    static String scopedApiKeyPrefName(String provider, String effectiveBaseUrl) {
        String p = provider == null ? "" : provider.trim().toLowerCase(Locale.ROOT);
        String origin = canonicalOrigin(effectiveBaseUrl);
        if (p.isEmpty() || origin.isEmpty()) return "";
        return SCOPED_API_KEY_PREFIX + p + ":" + origin;
    }

    static void saveScopedApiKey(
            Store secStore, String provider, String effectiveBaseUrl, String apiKey) {
        if (secStore == null) return;
        String prefKey = scopedApiKeyPrefName(provider, effectiveBaseUrl);
        if (prefKey.isEmpty()) return;
        String trimmed = apiKey == null ? "" : apiKey.trim();
        if (trimmed.isEmpty()) {
            secStore.remove(prefKey);
        } else {
            secStore.putString(prefKey, trimmed);
        }
        // Always remove legacy global unbound key so switching providers or restoring another
        // Base URL can never leak an old key to a different host or provider.
        secStore.remove(Prefs.SECRET_AI_API_KEY);
    }

    static String loadScopedApiKey(Store secStore, String provider, String effectiveBaseUrl) {
        if (secStore == null) return "";
        String prefKey = scopedApiKeyPrefName(provider, effectiveBaseUrl);
        if (prefKey.isEmpty()) return "";
        return secStore.getString(prefKey, "").trim();
    }

    static void saveScopedApiKey(
            MainActivity a, String provider, String effectiveBaseUrl, String apiKey) {
        if (a == null) return;
        saveScopedApiKey(
                new SharedPrefsStore(a.secretsPrefs()), provider, effectiveBaseUrl, apiKey);
    }

    static String loadScopedApiKey(MainActivity a, String provider, String effectiveBaseUrl) {
        if (a == null) return "";
        return loadScopedApiKey(new SharedPrefsStore(a.secretsPrefs()), provider, effectiveBaseUrl);
    }

    static boolean hasLegacyUnboundApiKey(Store secStore) {
        if (secStore == null) return false;
        return !secStore.getString(Prefs.SECRET_AI_API_KEY, "").trim().isEmpty();
    }

    static boolean hasLegacyUnboundApiKey(MainActivity a) {
        return a != null && hasLegacyUnboundApiKey(new SharedPrefsStore(a.secretsPrefs()));
    }

    static String legacyUnboundApiKeyNotice() {
        return "检测到升级前的旧版未绑定 API Key。为防止跨服务商或跨网关泄露，请为当前接口重新录入 API Key 并保存（保存后自动清除旧版全局密钥）。";
    }

    /**
     * Pure-JVM BYOK form controller enforcing immediate key reload/clear whenever the selected
     * provider OR effective Base URL origin changes, preventing prefilled keys from leaking onto a
     * newly typed gateway URL on Save or Test.
     */
    static final class ByokFormState {
        String provider;
        String customBaseUrl;
        String boundOrigin;
        String keyText;

        ByokFormState(Store secStore, String initialProvider, String initialCustomBaseUrl) {
            this.provider =
                    initialProvider == null || initialProvider.trim().isEmpty()
                            ? "deepseek"
                            : initialProvider.trim().toLowerCase(Locale.ROOT);
            this.customBaseUrl = initialCustomBaseUrl == null ? "" : initialCustomBaseUrl.trim();
            String effBase = AiAssistantService.resolveBaseUrl(this.provider, this.customBaseUrl);
            this.boundOrigin = canonicalOrigin(effBase);
            this.keyText = loadScopedApiKey(secStore, this.provider, effBase);
        }

        /** Updates provider, clears custom Base URL, and immediately loads that provider's key. */
        boolean onProviderChanged(Store secStore, String nextProvider) {
            String next =
                    nextProvider == null || nextProvider.trim().isEmpty()
                            ? "deepseek"
                            : nextProvider.trim().toLowerCase(Locale.ROOT);
            this.provider = next;
            this.customBaseUrl = "";
            String effBase = AiAssistantService.resolveBaseUrl(this.provider, "");
            this.boundOrigin = canonicalOrigin(effBase);
            this.keyText = loadScopedApiKey(secStore, this.provider, effBase);
            return true;
        }

        /**
         * Updates custom Base URL; whenever the canonical origin changes (including malformed URLs
         * with empty origin), immediately reloads the key bound to the new origin or clears {@link
         * #keyText} to {@code ""} so an old origin's key can NEVER be saved or sent to a new host.
         *
         * @return {@code true} if origin changed and the UI key field must be refreshed.
         */
        boolean onBaseUrlChanged(Store secStore, String rawBaseUrl) {
            this.customBaseUrl = rawBaseUrl == null ? "" : rawBaseUrl.trim();
            String effBase = AiAssistantService.resolveBaseUrl(this.provider, this.customBaseUrl);
            String nextOrigin = canonicalOrigin(effBase);
            if (!nextOrigin.equals(this.boundOrigin)) {
                this.boundOrigin = nextOrigin;
                this.keyText =
                        nextOrigin.isEmpty()
                                ? ""
                                : loadScopedApiKey(secStore, this.provider, effBase);
                return true;
            }
            return false;
        }

        void onKeyEdited(String typedKey) {
            this.keyText = typedKey == null ? "" : typedKey.trim();
        }

        String effectiveBaseUrl() {
            return AiAssistantService.resolveBaseUrl(this.provider, this.customBaseUrl);
        }

        boolean needsLegacyReentryNotice(Store secStore) {
            return !"ollama".equals(this.provider)
                    && (this.keyText == null || this.keyText.trim().isEmpty())
                    && hasLegacyUnboundApiKey(secStore);
        }

        /**
         * Validates and persists current form state into {@code secStore} strictly under the
         * current {@code (provider, canonicalOrigin)} binding.
         */
        String commitToStore(Store secStore, Store authStore) throws IOException {
            String rawBase = this.customBaseUrl == null ? "" : this.customBaseUrl.trim();
            String safeCustomBase =
                    rawBase.isEmpty()
                            ? ""
                            : (Prefs.sanitizeHttpUrl(rawBase) == null ? "" : rawBase);
            if (!rawBase.isEmpty() && safeCustomBase.isEmpty()) {
                throw new IOException("接口地址格式无效，请输入规范的 HTTP/HTTPS URL");
            }
            String effBase = AiAssistantService.resolveBaseUrl(this.provider, safeCustomBase);
            String targetOrigin = canonicalOrigin(effBase);
            // Defensive guard: if origin diverged from boundOrigin without sync, reload instead of
            // ever carrying an old origin's key forward.
            if (!targetOrigin.equals(this.boundOrigin)) {
                this.boundOrigin = targetOrigin;
                this.keyText =
                        targetOrigin.isEmpty()
                                ? ""
                                : loadScopedApiKey(secStore, this.provider, effBase);
            }
            String keyVal = this.keyText == null ? "" : this.keyText.trim();
            validateTransportSecurity(effBase, keyVal);
            if (authStore != null) {
                setAuthMode(authStore, AUTH_MODE_API_KEY);
            }
            saveScopedApiKey(secStore, this.provider, effBase, keyVal);
            if (!keyVal.isEmpty()) {
                AppLog.registerSecretForRedaction(keyVal);
            }
            return safeCustomBase;
        }
    }

    /** Pure-JVM BYOK request resolver enforcing provider+origin key isolation and HTTPS check. */
    static ResolvedRequest resolveByokRequest(
            Store secStore, String provider, String customBaseUrl, String model)
            throws IOException {
        String prov =
                provider == null || provider.trim().isEmpty()
                        ? "deepseek"
                        : provider.trim().toLowerCase(Locale.ROOT);
        String base = AiAssistantService.resolveBaseUrl(prov, customBaseUrl);
        if (base.isEmpty()) throw new IOException("未配置 AI 接口地址");
        String key = loadScopedApiKey(secStore, prov, base);
        if (!"ollama".equals(prov) && key.isEmpty()) {
            if (hasLegacyUnboundApiKey(secStore)) {
                throw new IOException("检测到升级前的旧版未绑定 API Key，请在「AI 认证中心」为当前服务商与接口地址重新录入并保存");
            }
            throw new IOException("请先为当前服务商与接口地址填写 API Key");
        }
        validateTransportSecurity(base, key);
        if (!key.isEmpty()) {
            AppLog.registerSecretForRedaction(key);
        }
        String effModel =
                model == null || model.trim().isEmpty()
                        ? AiAssistantService.defaultModel(prov)
                        : model.trim();
        return new ResolvedRequest(wireProtocolForApiProvider(prov), base, effModel, key, "", "");
    }

    // -------------------------------------------------------------------------
    // OpenMinis Foreground Gate (Android 16 background network safety)
    // -------------------------------------------------------------------------

    static void notifyActivityResumed() {
        synchronized (FOREGROUND_LOCK) {
            activityForeground = true;
            FOREGROUND_LOCK.notifyAll();
        }
    }

    static void notifyActivityBackgrounded() {
        synchronized (FOREGROUND_LOCK) {
            activityForeground = false;
        }
    }

    static boolean awaitForeground(long timeoutMs) {
        long deadline = System.currentTimeMillis() + Math.max(0L, timeoutMs);
        synchronized (FOREGROUND_LOCK) {
            while (!activityForeground) {
                long remain = deadline - System.currentTimeMillis();
                if (remain <= 0L) return false;
                try {
                    FOREGROUND_LOCK.wait(Math.min(remain, 500L));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return activityForeground;
                }
            }
            return true;
        }
    }

    // -------------------------------------------------------------------------
    // Store Accessors & Mode Selection
    // -------------------------------------------------------------------------

    static Store store(Context ctx) {
        return new SharedPrefsStore(ctx);
    }

    static String authMode(Context ctx) {
        if (ctx == null) return AUTH_MODE_API_KEY;
        return authMode(store(ctx));
    }

    static String authMode(Store store) {
        if (store == null) return AUTH_MODE_API_KEY;
        String m = store.getString(KEY_AUTH_MODE, AUTH_MODE_API_KEY);
        return AUTH_MODE_OAUTH.equals(m) ? AUTH_MODE_OAUTH : AUTH_MODE_API_KEY;
    }

    static long getAuthSelectionEpoch(Store store) {
        if (store == null) return 0L;
        synchronized (AUTH_SELECTION_LOCK) {
            return parseLongSafe(store.getString(KEY_AUTH_SELECTION_EPOCH, "0"));
        }
    }

    private static long bumpAuthSelectionEpochLocked(Store store) {
        long next = parseLongSafe(store.getString(KEY_AUTH_SELECTION_EPOCH, "0")) + 1L;
        store.putString(KEY_AUTH_SELECTION_EPOCH, Long.toString(next));
        return next;
    }

    static long setAuthMode(Store store, String mode) {
        if (store == null) return 0L;
        String normalized = AUTH_MODE_OAUTH.equals(mode) ? AUTH_MODE_OAUTH : AUTH_MODE_API_KEY;
        synchronized (AUTH_SELECTION_LOCK) {
            store.putString(KEY_AUTH_MODE, normalized);
            return bumpAuthSelectionEpochLocked(store);
        }
    }

    static void setAuthMode(Context ctx, String mode) {
        if (ctx == null) return;
        setAuthMode(store(ctx), mode);
    }

    static String activeOAuthProvider(Context ctx) {
        if (ctx == null) return OAUTH_OPENROUTER;
        return activeOAuthProvider(store(ctx));
    }

    static String activeOAuthProvider(Store store) {
        if (store == null) return OAUTH_OPENROUTER;
        String p = store.getString(KEY_OAUTH_PROVIDER, OAUTH_OPENROUTER);
        for (String id : OAUTH_PROVIDER_IDS) {
            if (id.equals(p)) return p;
        }
        return OAUTH_OPENROUTER;
    }

    static long setActiveOAuthProvider(Store store, String providerId) {
        if (store == null || providerId == null) return 0L;
        synchronized (AUTH_SELECTION_LOCK) {
            store.putString(KEY_OAUTH_PROVIDER, providerId);
            return bumpAuthSelectionEpochLocked(store);
        }
    }

    static void setActiveOAuthProvider(Context ctx, String providerId) {
        if (ctx == null || providerId == null) return;
        setActiveOAuthProvider(store(ctx), providerId);
    }

    /**
     * Pure-JVM OAuth provider switcher guaranteeing each provider's Client ID is saved strictly
     * under its own key before switching and loading the destination provider's independent Client
     * ID.
     */
    static final class OAuthProviderSwitchState {
        String currentProviderId;
        String clientIdInput;

        OAuthProviderSwitchState(Store store, String initialProviderId) {
            this.currentProviderId =
                    initialProviderId == null || initialProviderId.trim().isEmpty()
                            ? OAUTH_OPENROUTER
                            : initialProviderId.trim();
            this.clientIdInput =
                    providerRequiresClientId(this.currentProviderId)
                            ? oauthClientId(store, this.currentProviderId)
                            : "";
        }

        void onClientIdTyped(String typed) {
            this.clientIdInput = typed == null ? "" : typed.trim();
        }

        /**
         * Persists {@code typedInputForPrevious} ONLY to the previously active provider (when it
         * uses a Client ID), then switches to {@code nextProviderId} and loads {@code
         * nextProviderId}'s own independent Client ID.
         */
        String switchTo(Store store, String nextProviderId, String typedInputForPrevious) {
            if (store != null && providerRequiresClientId(this.currentProviderId)) {
                String toSave =
                        typedInputForPrevious != null
                                ? typedInputForPrevious.trim()
                                : clientIdInput;
                saveOAuthClientId(store, this.currentProviderId, toSave);
            }
            this.currentProviderId =
                    nextProviderId == null || nextProviderId.trim().isEmpty()
                            ? OAUTH_OPENROUTER
                            : nextProviderId.trim();
            if (store != null) {
                setActiveOAuthProvider(store, this.currentProviderId);
            }
            this.clientIdInput =
                    providerRequiresClientId(this.currentProviderId)
                            ? oauthClientId(store, this.currentProviderId)
                            : "";
            return this.clientIdInput;
        }
    }

    /**
     * Immutable handle for an in-flight interactive OAuth sign-in attempt, binding both the
     * per-provider session version and the global auth-selection epoch so closing the login sheet,
     * switching to BYOK, or switching to another OAuth provider atomically invalidates any late
     * success response.
     */
    static final class OAuthAttemptToken {
        final String providerId;
        final long providerSessionVersion;
        final long selectionEpoch;
        final AtomicBoolean cancelled = new AtomicBoolean(false);

        OAuthAttemptToken(String providerId, long providerSessionVersion, long selectionEpoch) {
            this.providerId = providerId;
            this.providerSessionVersion = providerSessionVersion;
            this.selectionEpoch = selectionEpoch;
        }
    }

    static OAuthAttemptToken beginOAuthAttempt(Store store, String providerId) {
        if (store == null || providerId == null) {
            return new OAuthAttemptToken(providerId == null ? "" : providerId, 0L, 0L);
        }
        synchronized (AUTH_SELECTION_LOCK) {
            synchronized (sessionStateLockFor(providerId)) {
                long nextVer =
                        parseLongSafe(
                                        store.getString(
                                                KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"))
                                + 1L;
                store.putString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, Long.toString(nextVer));
                long selEpoch = bumpAuthSelectionEpochLocked(store);
                return new OAuthAttemptToken(providerId, nextVer, selEpoch);
            }
        }
    }

    static void cancelOAuthAttempt(Store store, OAuthAttemptToken attempt) {
        if (attempt == null) return;
        attempt.cancelled.set(true);
        if (store == null || attempt.providerId == null || attempt.providerId.isEmpty()) return;
        synchronized (AUTH_SELECTION_LOCK) {
            synchronized (sessionStateLockFor(attempt.providerId)) {
                long curVer =
                        parseLongSafe(
                                store.getString(
                                        KEY_OAUTH_SESSION_VER_PREFIX + attempt.providerId, "0"));
                if (curVer == attempt.providerSessionVersion) {
                    store.putString(
                            KEY_OAUTH_SESSION_VER_PREFIX + attempt.providerId,
                            Long.toString(curVer + 1L));
                }
                long curEpoch = parseLongSafe(store.getString(KEY_AUTH_SELECTION_EPOCH, "0"));
                if (curEpoch == attempt.selectionEpoch) {
                    bumpAuthSelectionEpochLocked(store);
                }
            }
        }
    }

    /**
     * Atomically commits an interactive OAuth sign-in bundle AND activates OAuth mode/provider ONLY
     * if the attempt was not cancelled, the beta gate is still open, the provider's session epoch
     * is unchanged, AND the user has not switched to BYOK or another provider in the meantime.
     */
    static boolean completeOAuthSignInAtomically(
            Store store, OAuthAttemptToken attempt, OAuthBundle bundle, GateCheck gateCheck) {
        if (store == null || attempt == null || bundle == null) return false;
        synchronized (AUTH_SELECTION_LOCK) {
            synchronized (sessionStateLockFor(attempt.providerId)) {
                if (attempt.cancelled.get()) return false;
                if (gateCheck != null && !gateCheck.isAllowed()) return false;
                long curVer =
                        parseLongSafe(
                                store.getString(
                                        KEY_OAUTH_SESSION_VER_PREFIX + attempt.providerId, "0"));
                if (curVer != attempt.providerSessionVersion) return false;
                long curEpoch = parseLongSafe(store.getString(KEY_AUTH_SELECTION_EPOCH, "0"));
                if (curEpoch != attempt.selectionEpoch) return false;
                bundle.providerId = attempt.providerId;
                store.putString(
                        KEY_OAUTH_BUNDLE_PREFIX + attempt.providerId, bundle.toJson().toString());
                store.putString(KEY_AUTH_MODE, AUTH_MODE_OAUTH);
                store.putString(KEY_OAUTH_PROVIDER, attempt.providerId);
                AppLog.registerSecretForRedaction(bundle.accessToken);
                if (bundle.refreshToken != null && !bundle.refreshToken.isEmpty()) {
                    AppLog.registerSecretForRedaction(bundle.refreshToken);
                }
                return true;
            }
        }
    }

    static String oauthClientId(Store store, String providerId) {
        if (store == null || providerId == null) return "";
        return store.getString(KEY_OAUTH_CLIENT_ID_PREFIX + providerId, "").trim();
    }

    static String oauthClientId(Context ctx, String providerId) {
        if (ctx == null) return "";
        return oauthClientId(store(ctx), providerId);
    }

    static void saveOAuthClientId(Store store, String providerId, String clientId) {
        if (store == null || providerId == null) return;
        String clean = clientId == null ? "" : clientId.trim();
        if (clean.isEmpty()) store.remove(KEY_OAUTH_CLIENT_ID_PREFIX + providerId);
        else store.putString(KEY_OAUTH_CLIENT_ID_PREFIX + providerId, clean);
    }

    static void saveOAuthClientId(Context ctx, String providerId, String clientId) {
        if (ctx == null) return;
        saveOAuthClientId(store(ctx), providerId, clientId);
    }

    static String defaultOAuthModel(String providerId) {
        if (OAUTH_KIMI_CODE.equals(providerId)) return "kimi-for-coding";
        if (OAUTH_OPENAI_EXPERIMENTAL.equals(providerId)) return "gpt-4o-mini";
        return "openai/gpt-4o-mini";
    }

    static String oauthApiBase(String providerId) {
        if (OAUTH_KIMI_CODE.equals(providerId)) return KIMI_CODE_API_BASE;
        if (OAUTH_OPENAI_EXPERIMENTAL.equals(providerId)) return OPENAI_API_BASE;
        return OPENROUTER_API_BASE;
    }

    static String oauthWireProtocol(String providerId) {
        if (OAUTH_OPENAI_EXPERIMENTAL.equals(providerId)) return WIRE_OPENAI_RESPONSES;
        return WIRE_OPENAI_COMPAT;
    }

    static String oauthProviderLabel(String providerId) {
        for (int i = 0; i < OAUTH_PROVIDER_IDS.length; i++) {
            if (OAUTH_PROVIDER_IDS[i].equals(providerId)) return OAUTH_PROVIDER_LABELS[i];
        }
        return OAUTH_PROVIDER_LABELS[0];
    }

    static String resolveOAuthModel(Context ctx, String providerId) {
        if (ctx == null) return defaultOAuthModel(providerId);
        String saved = store(ctx).getString(KEY_OAUTH_MODEL_PREFIX + providerId, "").trim();
        return saved.isEmpty() ? defaultOAuthModel(providerId) : saved;
    }

    static void saveOAuthModel(Context ctx, String providerId, String model) {
        if (ctx == null || providerId == null) return;
        store(ctx)
                .putString(KEY_OAUTH_MODEL_PREFIX + providerId, model == null ? "" : model.trim());
    }

    static OAuthBundle loadBundle(Store store, String providerId) {
        if (store == null || providerId == null) return null;
        return OAuthBundle.fromJson(store.getString(KEY_OAUTH_BUNDLE_PREFIX + providerId, ""));
    }

    static OAuthBundle loadBundle(Context ctx, String providerId) {
        if (ctx == null) return null;
        return loadBundle(store(ctx), providerId);
    }

    static void saveBundle(Store store, OAuthBundle bundle) {
        if (store == null || bundle == null || bundle.providerId == null) return;
        synchronized (sessionStateLockFor(bundle.providerId)) {
            store.putString(
                    KEY_OAUTH_BUNDLE_PREFIX + bundle.providerId, bundle.toJson().toString());
        }
    }

    static void saveBundle(Context ctx, OAuthBundle bundle) {
        if (ctx == null) return;
        saveBundle(store(ctx), bundle);
    }

    // -------------------------------------------------------------------------
    // Atomic OAuth Session Versioning & Passcode Re-Check (P1-3)
    // -------------------------------------------------------------------------

    static Object refreshLockFor(String providerId) {
        String key = providerId == null ? "" : providerId;
        Object existing = REFRESH_LOCKS.get(key);
        if (existing != null) return existing;
        Object created = new Object();
        Object raced = REFRESH_LOCKS.putIfAbsent(key, created);
        return raced != null ? raced : created;
    }

    private static Object sessionStateLockFor(String providerId) {
        String key = providerId == null ? "" : providerId;
        Object existing = SESSION_STATE_LOCKS.get(key);
        if (existing != null) return existing;
        Object created = new Object();
        Object raced = SESSION_STATE_LOCKS.putIfAbsent(key, created);
        return raced != null ? raced : created;
    }

    static long getSessionVersion(Store store, String providerId) {
        if (store == null || providerId == null) return 0L;
        synchronized (sessionStateLockFor(providerId)) {
            return parseLongSafe(store.getString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"));
        }
    }

    private static long parseLongSafe(String raw) {
        if (raw == null || raw.trim().isEmpty()) return 0L;
        try {
            return Long.parseLong(raw.trim());
        } catch (Exception e) {
            return 0L;
        }
    }

    /**
     * Atomically advances the per-provider session epoch when initiating a new sign-in or account
     * switch, invalidating any earlier in-flight sign-in or refresh response.
     */
    static long beginOAuthSession(Store store, String providerId) {
        if (store == null || providerId == null) return 0L;
        synchronized (sessionStateLockFor(providerId)) {
            long next =
                    parseLongSafe(store.getString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"))
                            + 1L;
            store.putString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, Long.toString(next));
            return next;
        }
    }

    /**
     * Atomically removes the stored bundle AND advances the session epoch so any in-flight late
     * refresh or sign-in callback cannot resurrect the logged-out session.
     */
    static long signOutOAuth(Store store, String providerId) {
        if (store == null || providerId == null) return 0L;
        synchronized (sessionStateLockFor(providerId)) {
            long next =
                    parseLongSafe(store.getString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"))
                            + 1L;
            store.putString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, Long.toString(next));
            store.remove(KEY_OAUTH_BUNDLE_PREFIX + providerId);
            return next;
        }
    }

    static void signOutOAuth(Context ctx, String providerId) {
        if (ctx == null || providerId == null) return;
        signOutOAuth(store(ctx), providerId);
    }

    /**
     * Atomically commits a completed OAuth sign-in bundle ONLY if the beta passcode gate is still
     * valid AND the provider's session epoch still matches {@code expectedVersion}.
     */
    static boolean commitOAuthSignInIfCurrent(
            Store store,
            String providerId,
            long expectedVersion,
            OAuthBundle bundle,
            GateCheck gateCheck) {
        if (store == null || providerId == null || bundle == null) return false;
        synchronized (sessionStateLockFor(providerId)) {
            if (gateCheck != null && !gateCheck.isAllowed()) {
                return false;
            }
            long curVer =
                    parseLongSafe(store.getString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"));
            if (curVer != expectedVersion) {
                return false;
            }
            bundle.providerId = providerId;
            store.putString(KEY_OAUTH_BUNDLE_PREFIX + providerId, bundle.toJson().toString());
            return true;
        }
    }

    static boolean hasOpenAiExperimentalConsent(Context ctx) {
        return ctx != null && store(ctx).getBoolean(KEY_OPENAI_EXPERIMENTAL_CONSENT, false);
    }

    static void setOpenAiExperimentalConsent(Context ctx, boolean accepted) {
        if (ctx == null) return;
        store(ctx).putBoolean(KEY_OPENAI_EXPERIMENTAL_CONSENT, accepted);
    }

    static String wireProtocolForApiProvider(String provider) {
        if ("anthropic".equals(provider)) return WIRE_ANTHROPIC;
        if ("gemini".equals(provider)) return WIRE_GEMINI;
        return WIRE_OPENAI_COMPAT;
    }

    static boolean isActiveCredentialReady(MainActivity a) {
        if (a == null || !AiBetaGate.isUnlocked(a)) return false;
        String mode = authMode(a);
        if (AUTH_MODE_OAUTH.equals(mode)) {
            String prov = activeOAuthProvider(a);
            if (!isShippedOAuthProvider(prov)) {
                return false;
            }
            OAuthBundle b = loadBundle(a, prov);
            return b != null && b.hasCredential() && !b.needsReauth;
        }
        String provider = a.mobilePrefs().getString(Prefs.AI_PROVIDER, "deepseek");
        String base = AiAssistantService.resolveBaseUrl(a);
        if (base.isEmpty()) return false;
        String key = loadScopedApiKey(a, provider, base);
        if ("ollama".equals(provider)) {
            return key.isEmpty() ? !canonicalOrigin(base).isEmpty() : isHttpsUrl(base);
        }
        return !key.isEmpty() && isHttpsUrl(base);
    }

    static String activeSummaryLabel(MainActivity a) {
        if (a == null || !AiBetaGate.isUnlocked(a)) return "内测未解锁";
        if (!a.mobilePrefs().getBoolean(Prefs.AI_ENABLED, false)) return "已关闭";
        if (AUTH_MODE_OAUTH.equals(authMode(a))) {
            String prov = activeOAuthProvider(a);
            if (!isShippedOAuthProvider(prov)) return "请重选认证方式";
            OAuthBundle b = loadBundle(a, prov);
            if (b == null || !b.hasCredential()) return "账号未登录";
            if (b.needsReauth) return "授权过期";
            return "OpenRouter 账号";
        }
        if (!isActiveCredentialReady(a)) {
            return hasLegacyUnboundApiKey(a) ? "需重新录入 Key" : "未配置 Key";
        }
        return AiAssistantService.providerLabel(
                a.mobilePrefs().getString(Prefs.AI_PROVIDER, "deepseek"));
    }

    /**
     * OpenMinis Compare-Before-Delete rule: only mark {@code needsReauth = true} if the persisted
     * refresh token has not already been rotated by a concurrent winning refresh thread.
     */
    static boolean shouldMarkReauthAfterRefreshFailure(
            String staleRefreshToken, String currentStoredRefreshToken) {
        if (staleRefreshToken == null || staleRefreshToken.isEmpty()) return true;
        if (currentStoredRefreshToken == null || currentStoredRefreshToken.isEmpty()) return true;
        return staleRefreshToken.equals(currentStoredRefreshToken);
    }

    static OAuthBundle ensureFreshOAuthBundle(
            Store store, String providerId, String tokenEndpoint, String clientId, long nowMs)
            throws IOException {
        return ensureFreshOAuthBundle(
                store, providerId, tokenEndpoint, clientId, nowMs, () -> true, DEFAULT_TRANSPORT);
    }

    static OAuthBundle ensureFreshOAuthBundle(
            Store store,
            String providerId,
            String tokenEndpoint,
            String clientId,
            long nowMs,
            GateCheck gateCheck,
            HttpTransport transport)
            throws IOException {
        if (gateCheck != null && !gateCheck.isAllowed()) {
            throw new IOException("内测口令已失效，已阻止刷新订阅令牌");
        }
        OAuthBundle cur;
        synchronized (sessionStateLockFor(providerId)) {
            cur = loadBundle(store, providerId);
        }
        if (cur == null || !cur.hasCredential()) {
            throw new IOException("请先登录 " + oauthProviderLabel(providerId));
        }
        if (cur.needsReauth) {
            throw new IOException("账号授权已失效，请在 AI 认证中心重新登录");
        }
        if (!cur.isExpiringSoon(nowMs) || cur.refreshToken == null || cur.refreshToken.isEmpty()) {
            return cur;
        }
        synchronized (refreshLockFor(providerId)) {
            final long startVersion;
            final OAuthBundle snapshot;
            synchronized (sessionStateLockFor(providerId)) {
                if (gateCheck != null && !gateCheck.isAllowed()) {
                    throw new IOException("内测口令已失效，已阻止刷新订阅令牌");
                }
                startVersion =
                        parseLongSafe(
                                store.getString(KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"));
                snapshot = loadBundle(store, providerId);
                if (snapshot == null || !snapshot.hasCredential()) {
                    throw new IOException("登录状态已清除，请重新登录");
                }
                if (snapshot.needsReauth) {
                    throw new IOException("账号授权已失效，请在 AI 认证中心重新登录");
                }
                if (!snapshot.isExpiringSoon(nowMs)) {
                    return snapshot;
                }
            }
            String attemptedRefresh = snapshot.refreshToken;
            try {
                // Network refresh executes outside sessionStateLock so logout / account-switch
                // never blocks and can immediately bump sessionVersion.
                OAuthBundle refreshed =
                        refreshOAuthToken(
                                providerId, tokenEndpoint, clientId, snapshot, nowMs, transport);
                synchronized (sessionStateLockFor(providerId)) {
                    if (gateCheck != null && !gateCheck.isAllowed()) {
                        throw new IOException("内测口令已失效，已丢弃过期刷新结果");
                    }
                    long curVer =
                            parseLongSafe(
                                    store.getString(
                                            KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"));
                    OAuthBundle current = loadBundle(store, providerId);
                    if (curVer != startVersion || current == null || !current.hasCredential()) {
                        throw new IOException("账号会话已切换或已退出，已忽略过期的刷新响应");
                    }
                    store.putString(
                            KEY_OAUTH_BUNDLE_PREFIX + providerId, refreshed.toJson().toString());
                    return refreshed;
                }
            } catch (OAuthTerminalError e) {
                synchronized (sessionStateLockFor(providerId)) {
                    long curVer =
                            parseLongSafe(
                                    store.getString(
                                            KEY_OAUTH_SESSION_VER_PREFIX + providerId, "0"));
                    OAuthBundle reread = loadBundle(store, providerId);
                    if (curVer == startVersion && reread != null && reread.hasCredential()) {
                        String storedRefresh = reread.refreshToken;
                        if (shouldMarkReauthAfterRefreshFailure(attemptedRefresh, storedRefresh)) {
                            reread.needsReauth = true;
                            store.putString(
                                    KEY_OAUTH_BUNDLE_PREFIX + providerId,
                                    reread.toJson().toString());
                        }
                    }
                }
                throw new IOException("订阅授权已过期，请重新登录（" + sanitizeLogBody(e.getMessage()) + "）", e);
            }
        }
    }

    static final class OAuthTerminalError extends IOException {
        OAuthTerminalError(String msg) {
            super(msg);
        }
    }

    static OAuthBundle refreshOAuthToken(
            String providerId,
            String tokenEndpoint,
            String clientId,
            OAuthBundle existing,
            long nowMs)
            throws IOException {
        return refreshOAuthToken(
                providerId, tokenEndpoint, clientId, existing, nowMs, DEFAULT_TRANSPORT);
    }

    static OAuthBundle refreshOAuthToken(
            String providerId,
            String tokenEndpoint,
            String clientId,
            OAuthBundle existing,
            long nowMs,
            HttpTransport transport)
            throws IOException {
        validateTransportSecurity(tokenEndpoint, existing.refreshToken);
        HttpTransport tx = transport == null ? DEFAULT_TRANSPORT : transport;
        HttpResult res;
        if (OAUTH_OPENAI_EXPERIMENTAL.equals(providerId)) {
            JSONObject req = new JSONObject();
            try {
                req.put("grant_type", "refresh_token");
                req.put("client_id", clientId);
                req.put("refresh_token", existing.refreshToken);
                req.put("resource", OPENAI_API_BASE);
            } catch (Exception e) {
                throw new IOException(e);
            }
            res = postJson(tokenEndpoint, req.toString(), null, tx);
        } else {
            Map<String, String> form = new HashMap<>();
            form.put("grant_type", "refresh_token");
            form.put("client_id", clientId);
            form.put("refresh_token", existing.refreshToken);
            res = postForm(tokenEndpoint, form, null, tx);
        }
        if (res.code == 400 || res.code == 401 || res.code == 403) {
            String errCode = extractOAuthErrorCode(res.body);
            if ("invalid_grant".equals(errCode)
                    || "invalid_token".equals(errCode)
                    || res.code == 401) {
                throw new OAuthTerminalError(errCode.isEmpty() ? ("HTTP " + res.code) : errCode);
            }
        }
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "刷新令牌失败 HTTP "
                            + res.code
                            + ": "
                            + conciseError(res.body, existing.refreshToken));
        }
        try {
            JSONObject obj = new JSONObject(res.body);
            String nextAccess = obj.optString("access_token", "").trim();
            if (nextAccess.isEmpty()) {
                throw new OAuthTerminalError("empty_access_token");
            }
            OAuthBundle out = new OAuthBundle();
            out.providerId = providerId;
            out.accessToken = nextAccess;
            String nextRefresh = obj.optString("refresh_token", "").trim();
            out.refreshToken = nextRefresh.isEmpty() ? existing.refreshToken : nextRefresh;
            long expiresIn = obj.optLong("expires_in", 3600L);
            out.expiresAtMs = expiresIn > 0 ? nowMs + expiresIn * 1000L : 0L;
            out.accountLabel = existing.accountLabel;
            out.accountId = existing.accountId;
            out.planType = existing.planType;
            out.needsReauth = false;
            applyJwtMetadata(out, obj.optString("id_token", ""), nextAccess);
            return out;
        } catch (OAuthTerminalError e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("解析刷新响应失败：" + sanitizeLogBody(e.getMessage()), e);
        }
    }

    // -------------------------------------------------------------------------
    // PKCE S256 & Loopback OAuth (OpenRouter Official + Experimental OpenAI)
    // -------------------------------------------------------------------------

    static PkcePair generatePkcePair() {
        SecureRandom rng = new SecureRandom();
        byte[] verifierBytes = new byte[48];
        rng.nextBytes(verifierBytes);
        String verifier = base64UrlEncode(verifierBytes);
        byte[] stateBytes = new byte[24];
        rng.nextBytes(stateBytes);
        String state = base64UrlEncode(stateBytes);
        try {
            byte[] digest =
                    MessageDigest.getInstance("SHA-256")
                            .digest(verifier.getBytes(StandardCharsets.US_ASCII));
            return new PkcePair(verifier, base64UrlEncode(digest), state);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    static String buildOpenRouterAuthUrl(String callbackUrl, PkcePair pkce) {
        return OPENROUTER_AUTH_URL
                + "?callback_url="
                + urlEncode(callbackUrl)
                + "&code_challenge="
                + urlEncode(pkce.challenge)
                + "&code_challenge_method=S256";
    }

    /**
     * Builds the official OpenAI "Sign in with ChatGPT" OAuth PKCE URL with delegated plan-usage
     * scopes and API resource indicator required for Responses API inference.
     */
    static String buildOpenAiAuthUrl(String clientId, String redirectUri, PkcePair pkce) {
        return OPENAI_AUTH_URL
                + "?response_type=code"
                + "&client_id="
                + urlEncode(clientId)
                + "&redirect_uri="
                + urlEncode(redirectUri)
                + "&scope="
                + urlEncode(OPENAI_PLAN_USAGE_SCOPES)
                + "&resource="
                + urlEncode(OPENAI_API_BASE)
                + "&code_challenge="
                + urlEncode(pkce.challenge)
                + "&code_challenge_method=S256"
                + "&state="
                + urlEncode(pkce.state);
    }

    static OAuthBundle exchangeOpenRouterCode(String exchangeUrl, String code, String codeVerifier)
            throws IOException {
        return exchangeOpenRouterCode(exchangeUrl, code, codeVerifier, DEFAULT_TRANSPORT);
    }

    static OAuthBundle exchangeOpenRouterCode(
            String exchangeUrl, String code, String codeVerifier, HttpTransport transport)
            throws IOException {
        validateTransportSecurity(exchangeUrl, codeVerifier);
        JSONObject req = new JSONObject();
        try {
            req.put("code", code);
            req.put("code_verifier", codeVerifier);
            req.put("code_challenge_method", "S256");
        } catch (Exception e) {
            throw new IOException(e);
        }
        HttpResult res =
                postJson(
                        exchangeUrl,
                        req.toString(),
                        null,
                        transport == null ? DEFAULT_TRANSPORT : transport);
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "OpenRouter 换取密钥失败 HTTP "
                            + res.code
                            + ": "
                            + conciseError(res.body, codeVerifier));
        }
        try {
            JSONObject obj = new JSONObject(res.body);
            String key = obj.optString("key", "").trim();
            if (key.isEmpty()) throw new IOException("OpenRouter 返回空密钥");
            OAuthBundle b = new OAuthBundle();
            b.providerId = OAUTH_OPENROUTER;
            b.accessToken = key;
            b.accountLabel = obj.optString("user_id", "OpenRouter 已授权");
            b.expiresAtMs = 0L; // Permanent API key
            b.needsReauth = false;
            return b;
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("解析 OpenRouter 响应失败", e);
        }
    }

    static OAuthBundle exchangeOpenAiCode(
            String tokenUrl,
            String clientId,
            String code,
            String codeVerifier,
            String redirectUri,
            long nowMs)
            throws IOException {
        return exchangeOpenAiCode(
                tokenUrl, clientId, code, codeVerifier, redirectUri, nowMs, DEFAULT_TRANSPORT);
    }

    /**
     * Verifies both user identity ({@code sub} / {@code email}) and actual granted OpenAI
     * subscription inference scopes ({@code resource.invoke} and {@code
     * chatgpt.tokens.use.direct}) before accepting an OpenAI OAuth token response.
     */
    static void verifyOpenAiOAuthIdentityAndScopes(
            OAuthBundle bundle, String idToken, String accessToken, String grantedScope)
            throws IOException {
        JSONObject idClaims = extractJwtClaims(idToken);
        JSONObject accessClaims = extractJwtClaims(accessToken);
        String sub =
                idClaims != null && !idClaims.optString("sub", "").trim().isEmpty()
                        ? idClaims.optString("sub", "").trim()
                        : (accessClaims != null ? accessClaims.optString("sub", "").trim() : "");
        String email =
                bundle != null && bundle.accountLabel != null ? bundle.accountLabel.trim() : "";
        if (sub.isEmpty() && email.isEmpty()) {
            throw new IOException("OpenAI OAuth 响应缺少可验证的身份声明（sub/email）");
        }
        String scopeText = grantedScope == null ? "" : grantedScope.trim();
        if (scopeText.isEmpty() && accessClaims != null) {
            scopeText = accessClaims.optString("scope", "").trim();
            if (scopeText.isEmpty()) {
                JSONArray scpArr = accessClaims.optJSONArray("scp");
                if (scpArr != null) {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < scpArr.length(); i++) {
                        if (i > 0) sb.append(' ');
                        sb.append(scpArr.optString(i, ""));
                    }
                    scopeText = sb.toString().trim();
                }
            }
        }
        java.util.Set<String> scopes = new java.util.HashSet<>();
        if (!scopeText.isEmpty()) {
            for (String s : scopeText.split("\\s+")) {
                if (!s.trim().isEmpty()) scopes.add(s.trim());
            }
        }
        if (!scopes.contains("resource.invoke") || !scopes.contains("chatgpt.tokens.use.direct")) {
            throw new IOException(
                    "OpenAI OAuth 实际授权范围缺少订阅推理权限（需同时包含 resource.invoke 与 chatgpt.tokens.use.direct）");
        }
    }

    static OAuthBundle exchangeOpenAiCode(
            String tokenUrl,
            String clientId,
            String code,
            String codeVerifier,
            String redirectUri,
            long nowMs,
            HttpTransport transport)
            throws IOException {
        validateTransportSecurity(tokenUrl, codeVerifier);
        if (clientId == null || clientId.trim().isEmpty()) {
            throw new IOException("请先填写已注册的 OpenAI OAuth Client ID");
        }
        JSONObject req = new JSONObject();
        try {
            req.put("grant_type", "authorization_code");
            req.put("client_id", clientId.trim());
            req.put("code", code);
            req.put("code_verifier", codeVerifier);
            req.put("redirect_uri", redirectUri);
            req.put("resource", OPENAI_API_BASE);
        } catch (Exception e) {
            throw new IOException(e);
        }
        HttpResult res =
                postJson(
                        tokenUrl,
                        req.toString(),
                        null,
                        transport == null ? DEFAULT_TRANSPORT : transport);
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "OpenAI 令牌交换失败 HTTP " + res.code + ": " + conciseError(res.body, codeVerifier));
        }
        try {
            JSONObject obj = new JSONObject(res.body);
            String access = obj.optString("access_token", "").trim();
            if (access.isEmpty()) throw new IOException("OpenAI 返回空 access_token");
            String idToken = obj.optString("id_token", "").trim();
            String grantedScope = obj.optString("scope", "").trim();
            OAuthBundle b = new OAuthBundle();
            b.providerId = OAUTH_OPENAI_EXPERIMENTAL;
            b.accessToken = access;
            b.refreshToken = obj.optString("refresh_token", "").trim();
            long expiresIn = obj.optLong("expires_in", 3600L);
            b.expiresAtMs = expiresIn > 0 ? nowMs + expiresIn * 1000L : 0L;
            b.needsReauth = false;
            applyJwtMetadata(b, idToken, access);
            verifyOpenAiOAuthIdentityAndScopes(b, idToken, access, grantedScope);
            if (b.accountLabel.isEmpty()) b.accountLabel = "ChatGPT 订阅账号";
            return b;
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("解析 OpenAI 令牌失败", e);
        }
    }

    /** Loopback HTTP callback receiver strictly bound to 127.0.0.1. */
    static final class LoopbackCallbackServer implements AutoCloseable {
        final ServerSocket server;
        final int port;
        final String callbackPath;

        private LoopbackCallbackServer(ServerSocket server, String callbackPath) {
            this.server = server;
            this.port = server.getLocalPort();
            this.callbackPath = callbackPath;
        }

        static LoopbackCallbackServer bind(int[] candidatePorts, String callbackPath)
                throws IOException {
            InetAddress loopback = InetAddress.getByName("127.0.0.1");
            IOException last = null;
            for (int port : candidatePorts) {
                try {
                    ServerSocket ss = new ServerSocket(port, 4, loopback);
                    return new LoopbackCallbackServer(ss, callbackPath);
                } catch (IOException e) {
                    last = e;
                }
            }
            throw last != null ? last : new IOException("无法绑定本机回调端口");
        }

        String callbackUrl() {
            return "http://localhost:" + port + callbackPath;
        }

        Map<String, String> awaitCallback(long timeoutMs, AtomicBoolean cancelled)
                throws IOException {
            long deadline = System.currentTimeMillis() + timeoutMs;
            while (System.currentTimeMillis() < deadline) {
                if (cancelled != null && cancelled.get()) {
                    throw new IOException("已取消登录");
                }
                int slice =
                        (int)
                                Math.min(
                                        1000L,
                                        Math.max(100L, deadline - System.currentTimeMillis()));
                server.setSoTimeout(slice);
                try (Socket s = server.accept()) {
                    s.setSoTimeout(3000);
                    BufferedReader br =
                            new BufferedReader(
                                    new InputStreamReader(
                                            s.getInputStream(), StandardCharsets.UTF_8));
                    String reqLine = br.readLine();
                    if (reqLine == null) continue;
                    String[] parts = reqLine.split(" ");
                    String target = parts.length >= 2 ? parts[1] : "/";
                    String pathOnly = target;
                    String query = "";
                    int qIdx = target.indexOf('?');
                    if (qIdx >= 0) {
                        pathOnly = target.substring(0, qIdx);
                        query = target.substring(qIdx + 1);
                    }
                    if (!callbackPath.equals(pathOnly)) {
                        writeHttpHtml(s, 404, "Not Found");
                        continue;
                    }
                    Map<String, String> params = parseQuery(query);
                    boolean hasErr = params.containsKey("error") && !params.get("error").isEmpty();
                    writeHttpHtml(
                            s,
                            200,
                            hasErr
                                    ? "<h3>授权未完成</h3><p>请返回 Marco Movie 查看提示。</p>"
                                    : "<h3>授权已接收</h3><p>请切回 Marco Movie 完成连接，可关闭此标签页。</p>");
                    return params;
                } catch (SocketTimeoutException ignored) {
                }
            }
            throw new IOException("等待浏览器授权回调超时");
        }

        private static void writeHttpHtml(Socket s, int status, String bodyHtml) {
            try {
                String html =
                        "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
                                + "<style>body{font-family:sans-serif;text-align:center;padding:48px 20px;background:#0a0b0e;color:#f3f5f9}</style>"
                                + "</head><body>"
                                + bodyHtml
                                + "</body></html>";
                byte[] bytes = html.getBytes(StandardCharsets.UTF_8);
                String hdr =
                        "HTTP/1.1 "
                                + status
                                + " OK\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Length: "
                                + bytes.length
                                + "\r\nConnection: close\r\n\r\n";
                OutputStream out = s.getOutputStream();
                out.write(hdr.getBytes(StandardCharsets.US_ASCII));
                out.write(bytes);
                out.flush();
            } catch (Exception ignored) {
            }
        }

        @Override
        public void close() {
            try {
                server.close();
            } catch (Exception ignored) {
            }
        }
    }

    // -------------------------------------------------------------------------
    // RFC 8628 Device Flow (Requires User-Supplied Authorized Client ID)
    // -------------------------------------------------------------------------

    static DeviceCodeSession requestDeviceCode(String deviceAuthUrl, String clientId)
            throws IOException {
        return requestDeviceCode(deviceAuthUrl, clientId, DEFAULT_TRANSPORT);
    }

    static DeviceCodeSession requestDeviceCode(
            String deviceAuthUrl, String clientId, HttpTransport transport) throws IOException {
        validateTransportSecurity(deviceAuthUrl, clientId);
        if (clientId == null || clientId.trim().isEmpty()) {
            throw new IOException("请先填写已授权的 OAuth Client ID（本应用不冒用第三方 CLI 身份）");
        }
        Map<String, String> form = new HashMap<>();
        form.put("client_id", clientId.trim());
        HttpResult res =
                postForm(
                        deviceAuthUrl,
                        form,
                        null,
                        transport == null ? DEFAULT_TRANSPORT : transport);
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "获取设备授权码失败 HTTP " + res.code + ": " + conciseError(res.body, clientId));
        }
        try {
            JSONObject o = new JSONObject(res.body);
            String dc = o.optString("device_code", "").trim();
            String uc = o.optString("user_code", "").trim();
            String uri = o.optString("verification_uri", "").trim();
            String uriComplete = o.optString("verification_uri_complete", uri).trim();
            int exp = Math.max(60, o.optInt("expires_in", 600));
            int interval = Math.max(1, o.optInt("interval", 5));
            if (dc.isEmpty() || uc.isEmpty()) {
                throw new IOException("设备授权响应缺少必要字段");
            }
            return new DeviceCodeSession(dc, uc, uri, uriComplete, exp, interval);
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("解析设备授权响应失败", e);
        }
    }

    static final class DevicePollOutcome {
        static final int STATUS_PENDING = 0;
        static final int STATUS_SLOW_DOWN = 1;
        static final int STATUS_SUCCESS = 2;
        static final int STATUS_TERMINAL_ERROR = 3;

        final int status;
        final OAuthBundle bundle;
        final String errorMessage;

        DevicePollOutcome(int status, OAuthBundle bundle, String errorMessage) {
            this.status = status;
            this.bundle = bundle;
            this.errorMessage = errorMessage == null ? "" : errorMessage;
        }
    }

    static DevicePollOutcome pollDeviceTokenOnce(
            String providerId, String tokenUrl, String clientId, String deviceCode, long nowMs)
            throws IOException {
        return pollDeviceTokenOnce(
                providerId, tokenUrl, clientId, deviceCode, nowMs, DEFAULT_TRANSPORT);
    }

    static DevicePollOutcome pollDeviceTokenOnce(
            String providerId,
            String tokenUrl,
            String clientId,
            String deviceCode,
            long nowMs,
            HttpTransport transport)
            throws IOException {
        validateTransportSecurity(tokenUrl, deviceCode);
        Map<String, String> form = new HashMap<>();
        form.put("grant_type", "urn:ietf:params:oauth:grant-type:device_code");
        form.put("device_code", deviceCode);
        form.put("client_id", clientId);
        HttpResult res =
                postForm(tokenUrl, form, null, transport == null ? DEFAULT_TRANSPORT : transport);
        if (res.code >= 200 && res.code < 300) {
            try {
                JSONObject o = new JSONObject(res.body);
                String access = o.optString("access_token", "").trim();
                if (!access.isEmpty()) {
                    OAuthBundle b = new OAuthBundle();
                    b.providerId = providerId;
                    b.accessToken = access;
                    b.refreshToken = o.optString("refresh_token", "").trim();
                    long expIn = o.optLong("expires_in", 3600L);
                    b.expiresAtMs = expIn > 0 ? nowMs + expIn * 1000L : 0L;
                    b.accountLabel = "Kimi Code 订阅";
                    b.needsReauth = false;
                    return new DevicePollOutcome(DevicePollOutcome.STATUS_SUCCESS, b, "");
                }
            } catch (Exception e) {
                throw new IOException("解析设备登录令牌失败", e);
            }
        }
        String err = extractOAuthErrorCode(res.body);
        if ("authorization_pending".equals(err)) {
            return new DevicePollOutcome(DevicePollOutcome.STATUS_PENDING, null, "");
        }
        if ("slow_down".equals(err)) {
            return new DevicePollOutcome(DevicePollOutcome.STATUS_SLOW_DOWN, null, "");
        }
        if ("access_denied".equals(err)) {
            return new DevicePollOutcome(DevicePollOutcome.STATUS_TERMINAL_ERROR, null, "你已拒绝本次授权");
        }
        if ("expired_token".equals(err)) {
            return new DevicePollOutcome(
                    DevicePollOutcome.STATUS_TERMINAL_ERROR, null, "设备授权码已过期，请重新发起");
        }
        return new DevicePollOutcome(
                DevicePollOutcome.STATUS_TERMINAL_ERROR,
                null,
                err.isEmpty() ? ("授权失败 HTTP " + res.code) : ("授权失败：" + err));
    }

    // -------------------------------------------------------------------------
    // Interactive UI Sign-In Flows (Android Mobile)
    // -------------------------------------------------------------------------

    static void startOpenRouterSignIn(
            final MainActivity a, final AiAssistantService.ResultCallback<OAuthBundle> onSuccess) {
        if (a == null || a.isFinishing()) return;
        if (!AiBetaGate.isUnlocked(a)) {
            a.toast("内测口令未激活或已过期，请先解锁 AI 观影实验室");
            return;
        }
        final Store st = store(a);
        final OAuthAttemptToken attempt = beginOAuthAttempt(st, OAUTH_OPENROUTER);
        final LoopbackCallbackServer[] serverRef = new LoopbackCallbackServer[1];

        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(6), a.dp(4), a.dp(6));
        final TextView statusTv =
                a.text("正在准备本机回环回调并拉起 OpenRouter 官方授权页面…", 13.5f, MobileTheme.of(a).textPrimary);
        statusTv.setLineSpacing(a.dp(3f), 1f);
        box.addView(statusTv);

        final MobileBottomSheet.SheetHandle handle =
                MobileBottomSheet.showCustom(
                        a,
                        "OpenRouter 官方 OAuth 登录",
                        box,
                        () -> {
                            cancelOAuthAttempt(st, attempt);
                            if (serverRef[0] != null) serverRef[0].close();
                        });

        a.worker.execute(
                () -> {
                    LoopbackCallbackServer srv = null;
                    try {
                        PkcePair pkce = generatePkcePair();
                        srv =
                                LoopbackCallbackServer.bind(
                                        new int[] {3000, 3001, 3002}, "/callback");
                        serverRef[0] = srv;
                        final String authUrl = buildOpenRouterAuthUrl(srv.callbackUrl(), pkce);
                        a.ui.post(
                                () -> {
                                    if (attempt.cancelled.get()) return;
                                    statusTv.setText(
                                            "已在浏览器打开 OpenRouter 授权页。完成确认后将自动跳回本机并换取专属密钥（无需手动复制 Key）。");
                                    try {
                                        a.startActivity(
                                                new Intent(Intent.ACTION_VIEW, Uri.parse(authUrl)));
                                    } catch (Exception ex) {
                                        statusTv.setText("无法自动打开浏览器：" + a.message(ex));
                                    }
                                });
                        Map<String, String> params = srv.awaitCallback(180_000L, attempt.cancelled);
                        if (attempt.cancelled.get()) return;
                        if (params.containsKey("error") && !params.get("error").isEmpty()) {
                            throw new IOException("授权被取消：" + params.get("error"));
                        }
                        String code = params.get("code");
                        if (code == null || code.trim().isEmpty()) {
                            throw new IOException("回调缺少授权码 code");
                        }
                        a.ui.post(
                                () -> {
                                    if (!attempt.cancelled.get()) {
                                        statusTv.setText("已收到授权回调，等待回到应用前台并换取密钥…");
                                    }
                                });
                        awaitForeground(15_000L);
                        if (attempt.cancelled.get()) return;
                        final OAuthBundle bundle =
                                exchangeOpenRouterCode(
                                        OPENROUTER_EXCHANGE_URL, code.trim(), pkce.verifier);
                        boolean committed =
                                completeOAuthSignInAtomically(
                                        st, attempt, bundle, () -> AiBetaGate.isUnlocked(a));
                        if (!committed) {
                            return;
                        }
                        a.mobilePrefs().edit().putBoolean(Prefs.AI_ENABLED, true).apply();
                        a.ui.post(
                                () -> {
                                    if (handle != null) handle.dismiss();
                                    a.toast("OpenRouter 账号登录成功");
                                    if (onSuccess != null) onSuccess.onResult(bundle);
                                });
                    } catch (Exception e) {
                        if (!attempt.cancelled.get()) {
                            final String msg = sanitizeLogBody(a.message(e));
                            a.ui.post(
                                    () -> {
                                        statusTv.setText("登录未完成：" + msg);
                                        a.toast("OpenRouter 登录失败：" + msg);
                                    });
                        }
                    } finally {
                        if (srv != null) srv.close();
                    }
                });
    }

    static void startKimiCodeDeviceSignIn(
            final MainActivity a, final AiAssistantService.ResultCallback<OAuthBundle> onSuccess) {
        if (a == null || a.isFinishing()) return;
        a.toast("当前版本已撤下未实测的 Kimi Code 订阅直连入口，请使用 Moonshot (Kimi) API Key 或 OpenRouter 官方登录");
    }

    static void startOpenAiExperimentalSignIn(
            final MainActivity a, final AiAssistantService.ResultCallback<OAuthBundle> onSuccess) {
        if (a == null || a.isFinishing()) return;
        a.toast("当前版本已撤下未实测的实验性 OpenAI 订阅直连入口，请使用 OpenAI API Key 或 OpenRouter 官方登录");
    }

    // -------------------------------------------------------------------------
    // Multi-Protocol Chat Completion Wire Transport (OpenAI Compat / Responses / Anthropic /
    // Gemini)
    // -------------------------------------------------------------------------

    static ResolvedRequest resolveActiveRequest(MainActivity a) throws IOException {
        if (a == null) throw new IOException("上下文无效");
        if (!AiBetaGate.isUnlocked(a)) {
            throw new IOException("请先使用内测口令开启 AI 观影实验室");
        }
        String mode = authMode(a);
        if (AUTH_MODE_OAUTH.equals(mode)) {
            String prov = activeOAuthProvider(a);
            if (!isShippedOAuthProvider(prov)) {
                throw new IOException("当前版本已撤下未实测的实验性订阅直连，请改用 OpenRouter 官方登录或 API Key 模式");
            }
            Store st = store(a);
            OAuthBundle bundle = loadBundle(st, prov);
            if (bundle == null || !bundle.hasCredential()) {
                throw new IOException("请先登录 " + oauthProviderLabel(prov));
            }
            String base = oauthApiBase(prov);
            validateTransportSecurity(base, bundle.accessToken);
            AppLog.registerSecretForRedaction(bundle.accessToken);
            return new ResolvedRequest(
                    oauthWireProtocol(prov),
                    base,
                    resolveOAuthModel(a, prov),
                    bundle.accessToken,
                    prov,
                    bundle.accountId);
        }
        String provider = a.mobilePrefs().getString(Prefs.AI_PROVIDER, "deepseek");
        String customBase = a.mobilePrefs().getString(Prefs.AI_BASE_URL, "").trim();
        String model = a.mobilePrefs().getString(Prefs.AI_MODEL, "").trim();
        return resolveByokRequest(
                new SharedPrefsStore(a.secretsPrefs()), provider, customBase, model);
    }

    static String executeChatCompletion(
            ResolvedRequest req,
            String systemPrompt,
            String userPrompt,
            int maxTokens,
            double temperature)
            throws IOException {
        return executeChatCompletion(
                req, systemPrompt, userPrompt, maxTokens, temperature, DEFAULT_TRANSPORT);
    }

    static String executeChatCompletion(
            ResolvedRequest req,
            String systemPrompt,
            String userPrompt,
            int maxTokens,
            double temperature,
            HttpTransport transport)
            throws IOException {
        if (req != null && req.credential != null && !req.credential.isEmpty()) {
            AppLog.registerSecretForRedaction(req.credential);
        }
        HttpTransport tx = transport == null ? DEFAULT_TRANSPORT : transport;
        if (WIRE_ANTHROPIC.equals(req.wireProtocol)) {
            return executeAnthropicMessages(
                    req, systemPrompt, userPrompt, maxTokens, temperature, tx);
        }
        if (WIRE_GEMINI.equals(req.wireProtocol)) {
            return executeGeminiGenerateContent(
                    req, systemPrompt, userPrompt, maxTokens, temperature, tx);
        }
        if (WIRE_OPENAI_RESPONSES.equals(req.wireProtocol)) {
            return executeOpenAiResponses(
                    req, systemPrompt, userPrompt, maxTokens, temperature, tx);
        }
        return executeOpenAiCompatChat(req, systemPrompt, userPrompt, maxTokens, temperature, tx);
    }

    /**
     * Parses OpenAI Responses API Server-Sent Events (SSE) stream, handling {@code
     * response.output_text.delta}, {@code response.completed}, {@code response.failed}, {@code
     * response.incomplete}, and abrupt stream truncation / disconnect without a terminal completion
     * event.
     */
    static String parseOpenAiResponsesSse(String rawSse, String knownSecret) throws IOException {
        if (rawSse == null || rawSse.trim().isEmpty()) {
            throw new IOException("OpenAI Responses SSE 响应为空（连接异常中断）");
        }
        StringBuilder deltaText = new StringBuilder();
        String completedFallback = "";
        boolean sawCompleted = false;

        String normalized = rawSse.replace("\r\n", "\n").replace('\r', '\n');
        String[] lines = normalized.split("\n", -1);
        String curEvent = "";
        StringBuilder dataBuf = new StringBuilder();

        for (int idx = 0; idx <= lines.length; idx++) {
            String line = idx < lines.length ? lines[idx] : "";
            if (line.isEmpty()) {
                if (dataBuf.length() > 0) {
                    String payload = dataBuf.toString().trim();
                    dataBuf.setLength(0);
                    String evName = curEvent;
                    curEvent = "";
                    if ("[DONE]".equals(payload)) {
                        continue;
                    }
                    try {
                        JSONObject obj = new JSONObject(payload);
                        String type = obj.optString("type", evName);
                        if ("response.output_text.delta".equals(type)) {
                            deltaText.append(obj.optString("delta", ""));
                        } else if ("response.completed".equals(type)) {
                            sawCompleted = true;
                            JSONObject resp = obj.optJSONObject("response");
                            if (resp != null) {
                                String status = resp.optString("status", "completed");
                                if ("failed".equals(status)) {
                                    throw new IOException(
                                            "OpenAI Responses 推理失败："
                                                    + extractResponsesError(resp, knownSecret));
                                }
                                if ("incomplete".equals(status)) {
                                    throw new IOException(
                                            "OpenAI Responses 推理未完成："
                                                    + extractResponsesIncompleteReason(resp));
                                }
                                completedFallback = extractResponsesOutputText(resp);
                            }
                        } else if ("response.failed".equals(type)) {
                            JSONObject resp = obj.optJSONObject("response");
                            throw new IOException(
                                    "OpenAI Responses 推理失败："
                                            + extractResponsesError(
                                                    resp != null ? resp : obj, knownSecret));
                        } else if ("response.incomplete".equals(type)) {
                            JSONObject resp = obj.optJSONObject("response");
                            throw new IOException(
                                    "OpenAI Responses 推理未完成："
                                            + extractResponsesIncompleteReason(
                                                    resp != null ? resp : obj));
                        } else if ("error".equals(type)) {
                            throw new IOException(
                                    "OpenAI Responses 错误："
                                            + extractResponsesError(obj, knownSecret));
                        }
                    } catch (IOException ioe) {
                        throw ioe;
                    } catch (Exception parseErr) {
                        throw new IOException(
                                "OpenAI Responses SSE 事件解析失败（流可能已截断）："
                                        + sanitizeErrorText(parseErr.getMessage(), knownSecret),
                                parseErr);
                    }
                } else {
                    curEvent = "";
                }
                continue;
            }
            if (line.startsWith(":")) continue;
            if (line.startsWith("event:")) {
                curEvent = line.substring(6).trim();
            } else if (line.startsWith("data:")) {
                if (dataBuf.length() > 0) dataBuf.append('\n');
                dataBuf.append(line.substring(5).trim());
            }
        }
        if (!sawCompleted) {
            throw new IOException("OpenAI Responses SSE 流异常中断（未收到 response.completed 结束事件）");
        }
        return deltaText.length() > 0 ? deltaText.toString() : completedFallback;
    }

    private static String extractResponsesOutputText(JSONObject root) {
        if (root == null) return "";
        String directText = root.optString("output_text", "");
        if (!directText.isEmpty()) return directText;
        JSONArray output = root.optJSONArray("output");
        if (output == null || output.length() == 0) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < output.length(); i++) {
            JSONObject item = output.optJSONObject(i);
            if (item == null) continue;
            JSONArray content = item.optJSONArray("content");
            if (content == null) continue;
            for (int j = 0; j < content.length(); j++) {
                JSONObject part = content.optJSONObject(j);
                if (part == null) continue;
                String text = part.optString("text", "");
                if (!text.isEmpty()) sb.append(text);
            }
        }
        return sb.toString();
    }

    private static String extractResponsesError(JSONObject obj, String knownSecret) {
        if (obj == null) return "unknown_error";
        JSONObject err = obj.optJSONObject("error");
        if (err != null) {
            String msg = sanitizeErrorText(err.optString("message", "").trim(), knownSecret);
            String code = sanitizeErrorText(err.optString("code", "").trim(), knownSecret);
            if (!msg.isEmpty()) return msg;
            if (!code.isEmpty()) return code;
        }
        String msg = sanitizeErrorText(obj.optString("message", "").trim(), knownSecret);
        return msg.isEmpty() ? "upstream_failed" : msg;
    }

    private static String extractResponsesIncompleteReason(JSONObject obj) {
        if (obj == null) return "incomplete";
        JSONObject details = obj.optJSONObject("incomplete_details");
        if (details != null) {
            String r = details.optString("reason", "").trim();
            if (!r.isEmpty()) return r;
        }
        return "max_output_tokens_or_interrupted";
    }

    private static String executeOpenAiResponses(
            ResolvedRequest req,
            String systemPrompt,
            String userPrompt,
            int maxTokens,
            double temperature,
            HttpTransport transport)
            throws IOException {
        String base = trimTrailingSlash(req.baseUrl);
        String endpoint = base.endsWith("/responses") ? base : (base + "/responses");
        validateTransportSecurity(endpoint, req.credential);
        JSONObject body = new JSONObject();
        try {
            body.put("model", req.model);
            if (systemPrompt != null && !systemPrompt.isEmpty()) {
                body.put("instructions", systemPrompt);
            }
            body.put("input", userPrompt == null ? "" : userPrompt);
            body.put("max_output_tokens", maxTokens);
            body.put("stream", true);
            body.put("store", false);
        } catch (Exception e) {
            throw new IOException(e);
        }
        Map<String, String> headers = new HashMap<>();
        headers.put("Accept", "text/event-stream");
        if (req.credential != null && !req.credential.isEmpty()) {
            headers.put("Authorization", "Bearer " + req.credential);
        }
        if (req.chatGptAccountId != null && !req.chatGptAccountId.isEmpty()) {
            headers.put("ChatGPT-Account-Id", req.chatGptAccountId);
        }
        HttpResult res = postJson(endpoint, body.toString(), headers, transport);
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "OpenAI Responses HTTP "
                            + res.code
                            + ": "
                            + conciseError(res.body, req.credential));
        }
        String trimmed = res.body == null ? "" : res.body.trim();
        if (trimmed.startsWith("event:") || trimmed.startsWith("data:")) {
            return parseOpenAiResponsesSse(res.body, req.credential);
        }
        try {
            JSONObject root = new JSONObject(trimmed);
            String status = root.optString("status", "completed");
            if ("failed".equals(status)) {
                throw new IOException(
                        "OpenAI Responses 推理失败：" + extractResponsesError(root, req.credential));
            }
            if ("incomplete".equals(status)) {
                throw new IOException(
                        "OpenAI Responses 推理未完成：" + extractResponsesIncompleteReason(root));
            }
            return extractResponsesOutputText(root);
        } catch (IOException ioe) {
            throw ioe;
        } catch (Exception e) {
            throw new IOException("解析 OpenAI Responses 响应失败", e);
        }
    }

    private static String executeOpenAiCompatChat(
            ResolvedRequest req,
            String systemPrompt,
            String userPrompt,
            int maxTokens,
            double temperature,
            HttpTransport transport)
            throws IOException {
        String base = trimTrailingSlash(req.baseUrl);
        String endpoint = base.endsWith("/chat/completions") ? base : (base + "/chat/completions");
        validateTransportSecurity(endpoint, req.credential);
        JSONObject body = new JSONObject();
        try {
            body.put("model", req.model);
            body.put("temperature", temperature);
            body.put("max_tokens", maxTokens);
            JSONArray messages = new JSONArray();
            if (systemPrompt != null && !systemPrompt.isEmpty()) {
                messages.put(new JSONObject().put("role", "system").put("content", systemPrompt));
            }
            messages.put(new JSONObject().put("role", "user").put("content", userPrompt));
            body.put("messages", messages);
        } catch (Exception e) {
            throw new IOException(e);
        }
        Map<String, String> headers = new HashMap<>();
        if (req.credential != null && !req.credential.isEmpty()) {
            headers.put("Authorization", "Bearer " + req.credential);
        }
        if (req.chatGptAccountId != null && !req.chatGptAccountId.isEmpty()) {
            headers.put("ChatGPT-Account-Id", req.chatGptAccountId);
        }
        if (OAUTH_OPENROUTER.equals(req.oauthProviderId) || base.contains("openrouter.ai")) {
            headers.put("HTTP-Referer", MobileAuthorNotice.OFFICIAL_SITE_URL);
            headers.put("X-Title", "Marco Movie");
        }
        HttpResult res = postJson(endpoint, body.toString(), headers, transport);
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "HTTP " + res.code + ": " + conciseError(res.body, req.credential));
        }
        try {
            JSONObject root = new JSONObject(res.body);
            JSONArray choices = root.optJSONArray("choices");
            if (choices == null || choices.length() == 0) return "";
            JSONObject msg = choices.getJSONObject(0).optJSONObject("message");
            return msg == null ? "" : msg.optString("content", "");
        } catch (Exception e) {
            throw new IOException("解析模型响应失败", e);
        }
    }

    private static String executeAnthropicMessages(
            ResolvedRequest req,
            String systemPrompt,
            String userPrompt,
            int maxTokens,
            double temperature,
            HttpTransport transport)
            throws IOException {
        String base = trimTrailingSlash(req.baseUrl);
        String endpoint = base.endsWith("/v1/messages") ? base : (base + "/v1/messages");
        validateTransportSecurity(endpoint, req.credential);
        JSONObject body = new JSONObject();
        try {
            body.put("model", req.model);
            body.put("max_tokens", maxTokens);
            // Anthropic Claude 5.5 (e.g. claude-haiku-5-5) & API 2026-10-21 reject sampling
            // parameters (temperature / top_p / top_k) with HTTP 400; intentionally omitted.
            if (systemPrompt != null && !systemPrompt.isEmpty()) {
                body.put("system", systemPrompt);
            }
            JSONArray messages = new JSONArray();
            messages.put(new JSONObject().put("role", "user").put("content", userPrompt));
            body.put("messages", messages);
        } catch (Exception e) {
            throw new IOException(e);
        }
        Map<String, String> headers = new HashMap<>();
        headers.put("x-api-key", req.credential);
        headers.put("anthropic-version", "2023-06-01");
        HttpResult res = postJson(endpoint, body.toString(), headers, transport);
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "Anthropic HTTP " + res.code + ": " + conciseError(res.body, req.credential));
        }
        try {
            JSONObject root = new JSONObject(res.body);
            JSONArray content = root.optJSONArray("content");
            if (content == null || content.length() == 0) return "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < content.length(); i++) {
                JSONObject block = content.optJSONObject(i);
                if (block != null && "text".equals(block.optString("type", "text"))) {
                    sb.append(block.optString("text", ""));
                }
            }
            return sb.toString();
        } catch (Exception e) {
            throw new IOException("解析 Anthropic 响应失败", e);
        }
    }

    private static String executeGeminiGenerateContent(
            ResolvedRequest req,
            String systemPrompt,
            String userPrompt,
            int maxTokens,
            double temperature,
            HttpTransport transport)
            throws IOException {
        String base = trimTrailingSlash(req.baseUrl);
        String endpoint =
                base.contains(":generateContent")
                        ? base
                        : (base + "/v1beta/models/" + urlEncode(req.model) + ":generateContent");
        validateTransportSecurity(endpoint, req.credential);
        JSONObject body = new JSONObject();
        try {
            if (systemPrompt != null && !systemPrompt.isEmpty()) {
                body.put(
                        "systemInstruction",
                        new JSONObject()
                                .put(
                                        "parts",
                                        new JSONArray()
                                                .put(new JSONObject().put("text", systemPrompt))));
            }
            body.put(
                    "contents",
                    new JSONArray()
                            .put(
                                    new JSONObject()
                                            .put("role", "user")
                                            .put(
                                                    "parts",
                                                    new JSONArray()
                                                            .put(
                                                                    new JSONObject()
                                                                            .put(
                                                                                    "text",
                                                                                    userPrompt)))));
            body.put(
                    "generationConfig",
                    new JSONObject()
                            .put("temperature", temperature)
                            .put("maxOutputTokens", maxTokens));
        } catch (Exception e) {
            throw new IOException(e);
        }
        Map<String, String> headers = new HashMap<>();
        headers.put("x-goog-api-key", req.credential);
        HttpResult res = postJson(endpoint, body.toString(), headers, transport);
        if (res.code < 200 || res.code >= 300) {
            throw new IOException(
                    "Gemini HTTP " + res.code + ": " + conciseError(res.body, req.credential));
        }
        try {
            JSONObject root = new JSONObject(res.body);
            JSONArray candidates = root.optJSONArray("candidates");
            if (candidates == null || candidates.length() == 0) return "";
            JSONObject content = candidates.getJSONObject(0).optJSONObject("content");
            JSONArray parts = content == null ? null : content.optJSONArray("parts");
            if (parts == null || parts.length() == 0) return "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < parts.length(); i++) {
                JSONObject part = parts.optJSONObject(i);
                if (part != null) sb.append(part.optString("text", ""));
            }
            return sb.toString();
        } catch (Exception e) {
            throw new IOException("解析 Gemini 响应失败", e);
        }
    }

    // -------------------------------------------------------------------------
    // HTTP, JWT & Security Utilities
    // -------------------------------------------------------------------------

    static final class HttpResult {
        final int code;
        final String body;

        HttpResult(int code, String body) {
            this.code = code;
            this.body = body == null ? "" : body;
        }
    }

    static HttpURLConnection openProxiedConnection(String urlStr) throws IOException {
        URL url = new URL(urlStr);
        Proxy selected = Proxy.NO_PROXY;
        try {
            ProxySelector ps = ProxySelector.getDefault();
            if (ps != null) {
                List<Proxy> proxies = ps.select(URI.create(urlStr));
                if (proxies != null && !proxies.isEmpty() && proxies.get(0) != null) {
                    selected = proxies.get(0);
                }
            }
        } catch (Exception ignored) {
        }
        return (HttpURLConnection)
                (selected == Proxy.NO_PROXY ? url.openConnection() : url.openConnection(selected));
    }

    static HttpResult postJson(
            String url, String jsonBody, Map<String, String> headers, HttpTransport transport)
            throws IOException {
        return transport.postRaw(url, "application/json; charset=UTF-8", jsonBody, headers);
    }

    static HttpResult postForm(
            String url, Map<String, String> form, Map<String, String> headers, HttpTransport tx)
            throws IOException {
        StringBuilder sb = new StringBuilder();
        boolean first = true;
        for (Map.Entry<String, String> e : form.entrySet()) {
            if (!first) sb.append('&');
            first = false;
            sb.append(urlEncode(e.getKey())).append('=').append(urlEncode(e.getValue()));
        }
        return tx.postRaw(
                url, "application/x-www-form-urlencoded; charset=UTF-8", sb.toString(), headers);
    }

    static HttpResult postRawDirect(
            String url, String contentType, String body, Map<String, String> headers)
            throws IOException {
        HttpURLConnection conn = openProxiedConnection(url);
        // Never auto-follow redirects on AI/OAuth endpoints: prevents Android 6 HttpURLConnection
        // from forwarding Authorization / x-api-key / x-goog-api-key across origins.
        conn.setInstanceFollowRedirects(false);
        conn.setRequestMethod("POST");
        conn.setDoOutput(true);
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(35000);
        conn.setRequestProperty("Content-Type", contentType);
        conn.setRequestProperty("Accept", "application/json");
        if (headers != null) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                if (e.getKey() != null && e.getValue() != null) {
                    conn.setRequestProperty(e.getKey(), e.getValue());
                }
            }
        }
        try {
            byte[] payload = (body == null ? "" : body).getBytes(StandardCharsets.UTF_8);
            try (OutputStream out = conn.getOutputStream()) {
                out.write(payload);
            }
            int code = conn.getResponseCode();
            if (code >= 300 && code < 400) {
                throw new IOException("AI 接口返回重定向（HTTP " + code + "），为防止认证凭据跨源泄露已拒绝自动跳转");
            }
            InputStream stream =
                    code >= 200 && code < 300 ? conn.getInputStream() : conn.getErrorStream();
            String resp = "";
            if (stream != null) {
                try (InputStream in = stream;
                        ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
                    byte[] buf = new byte[4096];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        if (bos.size() + n > 1024 * 1024) break;
                        bos.write(buf, 0, n);
                    }
                    resp = new String(bos.toByteArray(), StandardCharsets.UTF_8);
                }
            }
            return new HttpResult(code, resp);
        } finally {
            conn.disconnect();
        }
    }

    static JSONObject extractJwtClaims(String jwt) {
        if (jwt == null) return null;
        String[] parts = jwt.split("\\.");
        if (parts.length < 2) return null;
        byte[] raw = AiBetaGate.base64UrlDecode(parts[1]);
        if (raw == null || raw.length == 0) return null;
        try {
            return new JSONObject(new String(raw, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return null;
        }
    }

    static void applyJwtMetadata(OAuthBundle bundle, String idToken, String accessToken) {
        for (String tok : new String[] {idToken, accessToken}) {
            JSONObject claims = extractJwtClaims(tok);
            if (claims == null) continue;
            if (bundle.accountLabel.isEmpty()) {
                String email = claims.optString("email", "").trim();
                if (!email.isEmpty()) bundle.accountLabel = email;
            }
            JSONObject authObj = claims.optJSONObject("https://api.openai.com/auth");
            if (authObj != null) {
                if (bundle.accountId.isEmpty()) {
                    bundle.accountId = authObj.optString("chatgpt_account_id", "").trim();
                }
                if (bundle.planType.isEmpty()) {
                    bundle.planType = authObj.optString("chatgpt_plan_type", "").trim();
                }
            }
        }
    }

    /** Redacts OAuth tokens, bare API keys, native auth headers, device codes, and passcodes. */
    static String sanitizeLogBody(String raw) {
        return AppLog.sanitize(raw);
    }

    static String sanitizeErrorText(String raw, String knownSecret) {
        String s = AppLog.sanitize(raw);
        return AppLog.redactKnownSecret(s, knownSecret);
    }

    private static String extractOAuthErrorCode(String body) {
        if (body == null || body.isEmpty()) return "";
        try {
            JSONObject o = new JSONObject(body);
            String err = o.optString("error", "").trim();
            if (!err.isEmpty()) return err;
            JSONObject nested = o.optJSONObject("error");
            if (nested != null) return nested.optString("code", "").trim();
        } catch (Exception ignored) {
        }
        return "";
    }

    private static String conciseError(String body, String knownSecret) {
        String safe = sanitizeErrorText(body, knownSecret);
        try {
            JSONObject o = new JSONObject(safe);
            JSONObject err = o.optJSONObject("error");
            if (err != null) {
                String msg = sanitizeErrorText(err.optString("message", "").trim(), knownSecret);
                if (!msg.isEmpty()) return msg.length() > 140 ? msg.substring(0, 140) : msg;
            }
            String msg = sanitizeErrorText(o.optString("message", "").trim(), knownSecret);
            if (!msg.isEmpty()) return msg.length() > 140 ? msg.substring(0, 140) : msg;
        } catch (Exception ignored) {
        }
        String trimmed = safe.replace('\n', ' ').trim();
        return trimmed.length() > 120 ? trimmed.substring(0, 120) : trimmed;
    }

    static Map<String, String> parseQuery(String query) {
        Map<String, String> out = new HashMap<>();
        if (query == null || query.isEmpty()) return out;
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            try {
                if (eq >= 0) {
                    String k = URLDecoder.decode(pair.substring(0, eq), "UTF-8");
                    String v = URLDecoder.decode(pair.substring(eq + 1), "UTF-8");
                    out.put(k, v);
                } else if (!pair.isEmpty()) {
                    out.put(URLDecoder.decode(pair, "UTF-8"), "");
                }
            } catch (Exception ignored) {
            }
        }
        return out;
    }

    static String base64UrlEncode(byte[] data) {
        final char[] alphabet =
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toCharArray();
        StringBuilder sb = new StringBuilder((data.length * 4 + 2) / 3);
        int i = 0;
        while (i < data.length) {
            int b0 = data[i++] & 0xFF;
            int b1 = i < data.length ? (data[i++] & 0xFF) : -1;
            int b2 = i < data.length ? (data[i++] & 0xFF) : -1;
            sb.append(alphabet[b0 >>> 2]);
            sb.append(alphabet[((b0 & 0x03) << 4) | (b1 >= 0 ? (b1 >>> 4) : 0)]);
            if (b1 >= 0) {
                sb.append(alphabet[((b1 & 0x0F) << 2) | (b2 >= 0 ? (b2 >>> 6) : 0)]);
            }
            if (b2 >= 0) {
                sb.append(alphabet[b2 & 0x3F]);
            }
        }
        return sb.toString();
    }

    static boolean constantTimeEquals(String a, String b) {
        if (a == null || b == null || a.length() != b.length()) return false;
        int diff = 0;
        for (int i = 0; i < a.length(); i++) {
            diff |= a.charAt(i) ^ b.charAt(i);
        }
        return diff == 0;
    }

    private static String urlEncode(String s) {
        try {
            return URLEncoder.encode(s == null ? "" : s, "UTF-8").replace("+", "%20");
        } catch (Exception e) {
            return "";
        }
    }

    private static String trimTrailingSlash(String s) {
        if (s == null) return "";
        String out = s.trim();
        while (out.endsWith("/")) out = out.substring(0, out.length() - 1);
        return out;
    }
}

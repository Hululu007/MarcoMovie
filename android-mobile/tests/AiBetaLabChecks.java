package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Pure-JVM + local mock HTTP verification suite for the refactored AI Cinema Lab:
 *  1. Cross-language ECDSA P-256 offline beta passcode verification (Python signer -> Java verifier).
 *  2. Dual-mode AI auth & OpenMinis hardening (OpenRouter PKCE, Kimi Code RFC 8628 Device Flow,
 *     Experimental OpenAI JWT metadata, Refresh Mutex + Compare-Before-Delete, Foreground Gate,
 *     log redaction, and OpenAI/Anthropic/Gemini wire adapters).
 *  3. True full-episode sliding-window AI bilingual subtitle translation (>100 cues, glossary
 *     continuity, lossless tail preservation, and timestamp context extraction).
 *  4. AI Cinema Copilot anti-spoiler recap prompts and Tonight's Watch JSON recommendation parser.
 *  5. Prefs.KEYS == 46 invariant and static beta-gating / zero-emoji hygiene checks.
 */
public final class AiBetaLabChecks {
    private static int passed;

    private static void check(boolean cond, String label) {
        if (!cond) throw new AssertionError("FAILED: " + label);
        passed++;
        System.out.println("PASS " + label);
    }

    private static final class MemoryGateStore implements AiBetaGate.Store {
        private final Map<String, String> strMap = new HashMap<>();
        private final Map<String, Long> longMap = new HashMap<>();

        @Override
        public String getString(String key, String def) {
            return strMap.containsKey(key) ? strMap.get(key) : def;
        }

        @Override
        public void putString(String key, String value) {
            strMap.put(key, value);
        }

        @Override
        public long getLong(String key, long def) {
            return longMap.containsKey(key) ? longMap.get(key) : def;
        }

        @Override
        public void putLong(String key, long value) {
            longMap.put(key, value);
        }

        @Override
        public void remove(String key) {
            strMap.remove(key);
            longMap.remove(key);
        }
    }

    private static final class MemoryOAuthStore implements AiAuthManager.Store {
        private final Map<String, String> strMap = new HashMap<>();
        private final Map<String, Boolean> boolMap = new HashMap<>();

        @Override
        public String getString(String key, String def) {
            return strMap.containsKey(key) ? strMap.get(key) : def;
        }

        @Override
        public void putString(String key, String value) {
            strMap.put(key, value);
        }

        @Override
        public boolean getBoolean(String key, boolean def) {
            return boolMap.containsKey(key) ? boolMap.get(key) : def;
        }

        @Override
        public void putBoolean(String key, boolean value) {
            boolMap.put(key, value);
        }

        @Override
        public void remove(String key) {
            strMap.remove(key);
            boolMap.remove(key);
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 9) {
            throw new IllegalArgumentException(
                    "Usage: AiBetaLabChecks <root> <pubHex> <sharedCode> <expCode> <highMinVcCode> <expiredCode> <jsAllPlatCode> <jsIosOnlyCode> <jsAndWinCode> [realAuthorCode]");
        }
        Path root = Paths.get(args[0]);
        byte[] testPub = AiBetaGate.hexToBytes(args[1]);
        String sharedCode = args[2];
        String expCode = args[3];
        String highMinVcCode = args[4];
        String expiredCode = args[5];
        String jsAllPlatCode = args[6];
        String jsIosOnlyCode = args[7];
        String jsAndWinCode = args[8];
        String realAuthorCode = args.length >= 10 ? args[9] : "";

        test1_EcdsaPasscodeGate(
                testPub,
                sharedCode,
                expCode,
                highMinVcCode,
                expiredCode,
                jsAllPlatCode,
                jsIosOnlyCode,
                jsAndWinCode,
                realAuthorCode);
        test2_DualModeAuthAndOpenMinisHardening();
        test3_FullEpisodeSlidingSubtitleTranslator();
        test4_CinemaCopilotPromptsAndParser();
        test5_StaticHygieneAndInvariants(root);

        System.out.println("ALL AI BETA LAB CHECKS PASSED (" + passed + " checks)");
    }

    private static void test1_EcdsaPasscodeGate(
            byte[] pubKey,
            String sharedCode,
            String expCode,
            String highMinVcCode,
            String expiredCode,
            String jsAllPlatCode,
            String jsIosOnlyCode,
            String jsAndWinCode,
            String realAuthorCode) {
        long nowValid = 1768000000L * 1000L; // 2026-01-10 UTC

        // 1. Default embedded Ed25519 public key sanity
        byte[] embedded = AiBetaGate.hexToBytes(AiBetaGate.DEFAULT_PUBLIC_KEY_HEX);
        check(
                embedded.length == 32
                        && "1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929"
                                .equals(AiBetaGate.DEFAULT_PUBLIC_KEY_HEX),
                "Gate: DEFAULT_PUBLIC_KEY_HEX matches unified 32-byte Ed25519 public key");

        if (realAuthorCode != null && !realAuthorCode.isEmpty()) {
            AiBetaGate.VerifyResult realRes =
                    AiBetaGate.verifyPasscode(realAuthorCode, 103, System.currentTimeMillis());
            check(
                    realRes.ok && realRes.coreAiEnabled(),
                    "Gate: real ai-lab-ed25519.key token verifies against embedded DEFAULT_PUBLIC_KEY_HEX");
        }

        // 2. Shared standard MMAILAB1 code passes & disables experimental OAuth
        AiBetaGate.VerifyResult rShared =
                AiBetaGate.verifyPasscode(sharedCode, 103, nowValid, pubKey);
        check(
                rShared.ok
                        && rShared.coreAiEnabled()
                        && rShared.sharedChannel()
                        && !rShared.experimentalOAuthAllowed()
                        && "channel-101".equals(rShared.tag),
                "Gate: shared MMAILAB1 code verifies with tag=channel-101, shared=true, expOAuth=false");

        // 3. Prose & whitespace/line-break extraction resilience when copied from QQ Channel
        String wrapped =
                "测试口令如下：\n"
                        + sharedCode.substring(0, 24)
                        + "\n  "
                        + sharedCode.substring(24, 60)
                        + " \t "
                        + sharedCode.substring(60);
        AiBetaGate.VerifyResult rWrapped =
                AiBetaGate.verifyPasscode(wrapped, 103, nowValid, pubKey);
        check(
                rWrapped.ok && "channel-101".equals(rWrapped.tag),
                "Gate: prose/whitespace-wrapped MMAILAB1 code extracts and verifies");

        // 4. Permanent experimental-OAuth code
        AiBetaGate.VerifyResult rExp =
                AiBetaGate.verifyPasscode(expCode, 103, nowValid + 3650L * 86400_000L, pubKey);
        check(
                rExp.ok
                        && rExp.coreAiEnabled()
                        && !rExp.sharedChannel()
                        && rExp.experimentalOAuthAllowed()
                        && rExp.expiresAtEpochSec == 0L
                        && "永久有效".equals(rExp.expireDateLabel())
                        && "core-202".equals(rExp.tag),
                "Gate: permanent experimental-OAuth MMAILAB1 code verifies and sets experimentalOAuthAllowed=true");

        // 5. Tampered signature & tampered payload rejected
        char[] chars = sharedCode.toCharArray();
        int idx = chars.length - 4;
        chars[idx] = chars[idx] == 'A' ? 'B' : 'A';
        AiBetaGate.VerifyResult rTamperedSig =
                AiBetaGate.verifyPasscode(new String(chars), 103, nowValid, pubKey);
        check(
                !rTamperedSig.ok && rTamperedSig.errorReason.contains("签名"),
                "Gate: tampered Ed25519 signature rejected");

        char[] chars2 = sharedCode.toCharArray();
        chars2[12] = chars2[12] == 'A' ? 'B' : 'A';
        AiBetaGate.VerifyResult rTamperedPayload =
                AiBetaGate.verifyPasscode(new String(chars2), 103, nowValid, pubKey);
        check(
                !rTamperedPayload.ok && rTamperedPayload.errorReason.contains("签名"),
                "Gate: tampered payload rejected");

        // 6. minVersionCode enforcement
        AiBetaGate.VerifyResult rLowVc =
                AiBetaGate.verifyPasscode(highMinVcCode, 103, nowValid, pubKey);
        AiBetaGate.VerifyResult rOkVc =
                AiBetaGate.verifyPasscode(highMinVcCode, 999, nowValid, pubKey);
        check(
                !rLowVc.ok && rLowVc.errorReason.contains("版本") && rOkVc.ok,
                "Gate: min_vc blocks older app versions and allows >= min_vc");

        // 7. Expiration enforcement + Store auto-lock
        long beforeExp = (1768000000L + 100L) * 1000L;
        long afterExpTime = (1768000000L + 2L * 86400L) * 1000L;
        MemoryGateStore store = new MemoryGateStore();
        check(
                !AiBetaGate.currentStatus(store, 103, beforeExp, pubKey).ok,
                "Gate: store starts locked");
        AiBetaGate.VerifyResult act =
                AiBetaGate.activate(store, expiredCode, 103, beforeExp, pubKey);
        check(
                act.ok && AiBetaGate.currentStatus(store, 103, beforeExp, pubKey).ok,
                "Gate: activate unlocks before expiry");
        AiBetaGate.VerifyResult afterExp =
                AiBetaGate.currentStatus(store, 103, afterExpTime, pubKey);
        check(
                !afterExp.ok && afterExp.errorReason.contains("过期"),
                "Gate: expired code auto-locks cleanly on subsequent checks");
        AiBetaGate.deactivate(store);
        check(
                !AiBetaGate.currentStatus(store, 103, beforeExp, pubKey).ok,
                "Gate: deactivate clears active passcode");

        // 8. 3-way Phone HTML JS Ed25519 signer -> Android Java verifier + 3-platform scoping
        AiBetaGate.VerifyResult jsAllAnd =
                AiBetaGate.verifyPasscode(
                        jsAllPlatCode, 103, nowValid, pubKey, AiBetaGate.PLATFORM_ANDROID);
        AiBetaGate.VerifyResult jsAllIos =
                AiBetaGate.verifyPasscode(
                        jsAllPlatCode, 100, nowValid, pubKey, AiBetaGate.PLATFORM_IOS);
        AiBetaGate.VerifyResult jsAllWin =
                AiBetaGate.verifyPasscode(
                        jsAllPlatCode, 1, nowValid, pubKey, AiBetaGate.PLATFORM_WINDOWS);
        check(
                jsAllAnd.ok
                        && jsAllIos.ok
                        && jsAllWin.ok
                        && "三端通用".equals(jsAllAnd.platformScopeLabel())
                        && "js-all-501".equals(jsAllAnd.tag),
                "Gate: Phone-JS minted 3-platform MMAILAB1 code verifies in Java across Android, iOS, and Windows");

        AiBetaGate.VerifyResult jsIosOnAndroid =
                AiBetaGate.verifyPasscode(
                        jsIosOnlyCode, 103, nowValid, pubKey, AiBetaGate.PLATFORM_ANDROID);
        AiBetaGate.VerifyResult jsIosOnIos =
                AiBetaGate.verifyPasscode(
                        jsIosOnlyCode, 100, nowValid, pubKey, AiBetaGate.PLATFORM_IOS);
        AiBetaGate.VerifyResult jsIosOnWin =
                AiBetaGate.verifyPasscode(
                        jsIosOnlyCode, 1, nowValid, pubKey, AiBetaGate.PLATFORM_WINDOWS);
        check(
                !jsIosOnAndroid.ok
                        && jsIosOnAndroid.errorReason.contains("iOS")
                        && jsIosOnIos.ok
                        && !jsIosOnWin.ok,
                "Gate: Phone-JS minted iOS-only MMAILAB1 code is rejected on Android/Windows and passes on iOS");

        AiBetaGate.VerifyResult jsAwOnAnd =
                AiBetaGate.verifyPasscode(
                        jsAndWinCode, 103, nowValid, pubKey, AiBetaGate.PLATFORM_ANDROID);
        AiBetaGate.VerifyResult jsAwOnWin =
                AiBetaGate.verifyPasscode(
                        jsAndWinCode, 1, nowValid, pubKey, AiBetaGate.PLATFORM_WINDOWS);
        AiBetaGate.VerifyResult jsAwOnIos =
                AiBetaGate.verifyPasscode(
                        jsAndWinCode, 100, nowValid, pubKey, AiBetaGate.PLATFORM_IOS);
        check(
                jsAwOnAnd.ok
                        && jsAwOnWin.ok
                        && !jsAwOnIos.ok
                        && jsAwOnAnd.platformScopeLabel().contains("安卓")
                        && jsAwOnAnd.platformScopeLabel().contains("Windows"),
                "Gate: Phone-JS minted Android+Windows MMAILAB1 code passes on Android/Windows and rejects iOS");
    }

    private static void test2_DualModeAuthAndOpenMinisHardening() throws Exception {
        // A. PKCE + Loopback + Mock OAuth & Multi-Protocol AI Server
        final AtomicInteger devicePollCount = new AtomicInteger(0);
        final AtomicBoolean failRefreshWithInvalidGrant = new AtomicBoolean(false);
        final AtomicReference<String> lastAnthropicKey = new AtomicReference<>("");
        final AtomicReference<String> lastAnthropicVer = new AtomicReference<>("");
        final AtomicReference<String> lastGeminiKey = new AtomicReference<>("");
        final AtomicReference<String> lastGeminiQuery = new AtomicReference<>("");
        final AtomicReference<String> lastOpenAiAccountHdr = new AtomicReference<>("");

        HttpServer server =
                HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        int port = server.getAddress().getPort();
        String base = "http://127.0.0.1:" + port;

        server.createContext(
                "/openrouter/keys",
                ex -> {
                    String body = readBody(ex);
                    boolean ok = body.contains("or-code-123") && body.contains("S256");
                    writeJson(
                            ex,
                            ok ? 200 : 400,
                            ok
                                    ? "{\"key\":\"sk-or-v1-mock-perm-key\",\"user_id\":\"tester@marco\"}"
                                    : "{\"error\":\"bad\"}");
                });
        server.createContext(
                "/kimi/device_authorization",
                ex -> {
                    String body = readBody(ex);
                    boolean noScope = !body.contains("scope=");
                    writeJson(
                            ex,
                            noScope ? 200 : 400,
                            "{\"device_code\":\"dev-code-xyz\",\"user_code\":\"ABCD-1234\",\"verification_uri\":\"https://auth.kimi.com/verify\",\"verification_uri_complete\":\"https://auth.kimi.com/verify?code=ABCD-1234\",\"expires_in\":300,\"interval\":2}");
                });
        server.createContext(
                "/kimi/token",
                ex -> {
                    String body = readBody(ex);
                    if (body.contains("grant_type=refresh_token")) {
                        if (failRefreshWithInvalidGrant.get()) {
                            writeJson(ex, 400, "{\"error\":\"invalid_grant\"}");
                        } else {
                            writeJson(
                                    ex,
                                    200,
                                    "{\"access_token\":\"kimi-at-rotated\",\"refresh_token\":\"kimi-rt-rotated\",\"expires_in\":7200}");
                        }
                        return;
                    }
                    int n = devicePollCount.incrementAndGet();
                    if (n == 1) {
                        writeJson(ex, 400, "{\"error\":\"authorization_pending\"}");
                    } else if (n == 2) {
                        writeJson(ex, 400, "{\"error\":\"slow_down\"}");
                    } else {
                        writeJson(
                                ex,
                                200,
                                "{\"access_token\":\"kimi-at-1\",\"refresh_token\":\"kimi-rt-1\",\"expires_in\":3600}");
                    }
                });
        server.createContext(
                "/openai/token",
                ex -> {
                    String payloadJson =
                            "{\"email\":\"marco@example.test\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_test_88\",\"chatgpt_plan_type\":\"plus\"}}";
                    String fakeJwt =
                            AiAuthManager.base64UrlEncode(
                                            "{\"alg\":\"none\"}".getBytes(StandardCharsets.UTF_8))
                                    + "."
                                    + AiAuthManager.base64UrlEncode(
                                            payloadJson.getBytes(StandardCharsets.UTF_8))
                                    + ".sig";
                    writeJson(
                            ex,
                            200,
                            "{\"access_token\":\"oa-at-1\",\"refresh_token\":\"oa-rt-1\",\"id_token\":\""
                                    + fakeJwt
                                    + "\",\"expires_in\":3600}");
                });
        server.createContext(
                "/v1/chat/completions",
                ex -> {
                    lastOpenAiAccountHdr.set(
                            ex.getRequestHeaders().getFirst("ChatGPT-Account-Id") == null
                                    ? ""
                                    : ex.getRequestHeaders().getFirst("ChatGPT-Account-Id"));
                    writeJson(
                            ex, 200, "{\"choices\":[{\"message\":{\"content\":\"连接正常-OpenAI\"}}]}");
                });
        server.createContext(
                "/v1/messages",
                ex -> {
                    lastAnthropicKey.set(
                            ex.getRequestHeaders().getFirst("x-api-key") == null
                                    ? ""
                                    : ex.getRequestHeaders().getFirst("x-api-key"));
                    lastAnthropicVer.set(
                            ex.getRequestHeaders().getFirst("anthropic-version") == null
                                    ? ""
                                    : ex.getRequestHeaders().getFirst("anthropic-version"));
                    writeJson(
                            ex,
                            200,
                            "{\"content\":[{\"type\":\"text\",\"text\":\"连接正常-Anthropic\"}]}");
                });
        server.createContext(
                "/v1beta/models/gemini-2.5-flash:generateContent",
                ex -> {
                    lastGeminiKey.set(
                            ex.getRequestHeaders().getFirst("x-goog-api-key") == null
                                    ? ""
                                    : ex.getRequestHeaders().getFirst("x-goog-api-key"));
                    lastGeminiQuery.set(
                            ex.getRequestURI().getQuery() == null
                                    ? ""
                                    : ex.getRequestURI().getQuery());
                    writeJson(
                            ex,
                            200,
                            "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"连接正常-Gemini\"}]}}]}");
                });

        server.start();
        try {
            // 1. PKCE + Loopback callback server test
            AiAuthManager.PkcePair pkce = AiAuthManager.generatePkcePair();
            check(
                    pkce.verifier.length() >= 43
                            && pkce.challenge.length() >= 40
                            && pkce.state.length() >= 20,
                    "Auth: PKCE S256 verifier, challenge, and state generated");

            try (AiAuthManager.LoopbackCallbackServer lb =
                    AiAuthManager.LoopbackCallbackServer.bind(new int[] {0}, "/callback")) {
                final String cbUrl = lb.callbackUrl() + "?code=or-code-123&state=" + pkce.state;
                Thread caller =
                        new Thread(
                                () -> {
                                    try {
                                        Thread.sleep(60);
                                        HttpURLConnection c =
                                                (HttpURLConnection) new URL(cbUrl).openConnection();
                                        c.getResponseCode();
                                        c.disconnect();
                                    } catch (Exception ignored) {
                                    }
                                });
                caller.start();
                Map<String, String> params = lb.awaitCallback(5000L, new AtomicBoolean(false));
                caller.join(2000L);
                check(
                        "or-code-123".equals(params.get("code"))
                                && AiAuthManager.constantTimeEquals(
                                        pkce.state, params.get("state")),
                        "Auth: LoopbackCallbackServer captures code & constant-time state matches");
            }

            AiAuthManager.OAuthBundle orBundle =
                    AiAuthManager.exchangeOpenRouterCode(
                            base + "/openrouter/keys", "or-code-123", pkce.verifier);
            check(
                    "sk-or-v1-mock-perm-key".equals(orBundle.accessToken)
                            && orBundle.expiresAtMs == 0L
                            && !orBundle.needsReauth,
                    "Auth: OpenRouter PKCE code exchanges for permanent API key");

            // 2. Kimi Code RFC 8628 Device Flow (pending -> slow_down -> success)
            AiAuthManager.DeviceCodeSession devSess =
                    AiAuthManager.requestDeviceCode(
                            base + "/kimi/device_authorization", AiAuthManager.KIMI_CLIENT_ID);
            check(
                    "ABCD-1234".equals(devSess.userCode)
                            && "dev-code-xyz".equals(devSess.deviceCode),
                    "Auth: Kimi Code RFC 8628 device authorization omits scope & parses user_code");
            AiAuthManager.DevicePollOutcome p1 =
                    AiAuthManager.pollDeviceTokenOnce(
                            AiAuthManager.OAUTH_KIMI_CODE,
                            base + "/kimi/token",
                            AiAuthManager.KIMI_CLIENT_ID,
                            devSess.deviceCode,
                            1000L);
            AiAuthManager.DevicePollOutcome p2 =
                    AiAuthManager.pollDeviceTokenOnce(
                            AiAuthManager.OAUTH_KIMI_CODE,
                            base + "/kimi/token",
                            AiAuthManager.KIMI_CLIENT_ID,
                            devSess.deviceCode,
                            2000L);
            AiAuthManager.DevicePollOutcome p3 =
                    AiAuthManager.pollDeviceTokenOnce(
                            AiAuthManager.OAUTH_KIMI_CODE,
                            base + "/kimi/token",
                            AiAuthManager.KIMI_CLIENT_ID,
                            devSess.deviceCode,
                            3000L);
            check(
                    p1.status == AiAuthManager.DevicePollOutcome.STATUS_PENDING
                            && p2.status == AiAuthManager.DevicePollOutcome.STATUS_SLOW_DOWN
                            && p3.status == AiAuthManager.DevicePollOutcome.STATUS_SUCCESS
                            && "kimi-at-1".equals(p3.bundle.accessToken),
                    "Auth: Kimi Code Device Flow handles authorization_pending -> slow_down -> success");

            // 3. Refresh Mutex + Compare-Before-Delete + non-destructive needsReauth
            MemoryOAuthStore oauthStore = new MemoryOAuthStore();
            AiAuthManager.saveBundle(oauthStore, p3.bundle);
            // Force expiry window -> refresh succeeds & rotates tokens
            AiAuthManager.OAuthBundle rotated =
                    AiAuthManager.ensureFreshOAuthBundle(
                            oauthStore,
                            AiAuthManager.OAUTH_KIMI_CODE,
                            base + "/kimi/token",
                            AiAuthManager.KIMI_CLIENT_ID,
                            p3.bundle.expiresAtMs);
            check(
                    "kimi-at-rotated".equals(rotated.accessToken)
                            && "kimi-rt-rotated".equals(rotated.refreshToken)
                            && !rotated.needsReauth,
                    "Auth: OAuth token auto-refreshes and persists rotated refresh_token");

            check(
                    AiAuthManager.shouldMarkReauthAfterRefreshFailure("rt_same", "rt_same")
                            && !AiAuthManager.shouldMarkReauthAfterRefreshFailure(
                                    "rt_stale", "rt_rotated"),
                    "Auth: OpenMinis Compare-Before-Delete protects newer rotated refresh tokens");

            failRefreshWithInvalidGrant.set(true);
            boolean threw = false;
            try {
                AiAuthManager.ensureFreshOAuthBundle(
                        oauthStore,
                        AiAuthManager.OAUTH_KIMI_CODE,
                        base + "/kimi/token",
                        AiAuthManager.KIMI_CLIENT_ID,
                        rotated.expiresAtMs + 10_000L);
            } catch (IOException expected) {
                threw = true;
            }
            AiAuthManager.OAuthBundle afterInvalid =
                    AiAuthManager.loadBundle(oauthStore, AiAuthManager.OAUTH_KIMI_CODE);
            check(
                    threw
                            && afterInvalid != null
                            && afterInvalid.hasCredential()
                            && afterInvalid.needsReauth,
                    "Auth: invalid_grant sets needsReauth=true WITHOUT silently deleting credentials");

            // 4. OpenAI Experimental JWT claim extraction
            AiAuthManager.OAuthBundle oaBundle =
                    AiAuthManager.exchangeOpenAiCode(
                            base + "/openai/token",
                            "oa-code",
                            pkce.verifier,
                            "http://localhost:1455/auth/callback",
                            5000L);
            check(
                    "marco@example.test".equals(oaBundle.accountLabel)
                            && "acct_test_88".equals(oaBundle.accountId)
                            && "plus".equals(oaBundle.planType),
                    "Auth: OpenAI OAuth JWT claims extract email, chatgpt_account_id, and plan_type");

            // 5. Foreground Gate
            AiAuthManager.notifyActivityBackgrounded();
            final AtomicBoolean gateUnblocked = new AtomicBoolean(false);
            Thread waiter =
                    new Thread(
                            () -> {
                                gateUnblocked.set(AiAuthManager.awaitForeground(3000L));
                            });
            waiter.start();
            Thread.sleep(80);
            check(
                    !gateUnblocked.get(),
                    "Auth: OAuthForegroundGate blocks while activity backgrounded");
            AiAuthManager.notifyActivityResumed();
            waiter.join(2000L);
            check(
                    gateUnblocked.get(),
                    "Auth: OAuthForegroundGate unblocks immediately on onResume()");

            // 6. Log Redaction
            String dirty =
                    "{\"access_token\":\"secA\",\"refresh_token\":\"secR\",\"api_key\":\"sk-999\"} Authorization: Bearer tok123 code_verifier=ver999";
            String clean = AiAuthManager.sanitizeLogBody(dirty);
            check(
                    !clean.contains("secA")
                            && !clean.contains("secR")
                            && !clean.contains("sk-999")
                            && !clean.contains("tok123")
                            && !clean.contains("ver999"),
                    "Auth: sanitizeLogBody redacts all JSON, Bearer, and form secrets");

            // 7. Multi-Protocol Wire Adapters (OpenAI, Anthropic, Gemini)
            String oaReply =
                    AiAuthManager.executeChatCompletion(
                            new AiAuthManager.ResolvedRequest(
                                    AiAuthManager.WIRE_OPENAI_COMPAT,
                                    base + "/v1",
                                    "gpt-4o-mini",
                                    "sk-oa",
                                    AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL,
                                    "acct_test_88"),
                            "sys",
                            "hi",
                            64,
                            0.2);
            check(
                    "连接正常-OpenAI".equals(oaReply)
                            && "acct_test_88".equals(lastOpenAiAccountHdr.get()),
                    "Transport: OpenAI-compatible wire adapter + ChatGPT-Account-Id header");

            String claudeReply =
                    AiAuthManager.executeChatCompletion(
                            new AiAuthManager.ResolvedRequest(
                                    AiAuthManager.WIRE_ANTHROPIC,
                                    base,
                                    "claude-3-5-haiku-latest",
                                    "sk-ant-key",
                                    "",
                                    ""),
                            "sys",
                            "hi",
                            64,
                            0.2);
            check(
                    "连接正常-Anthropic".equals(claudeReply)
                            && "sk-ant-key".equals(lastAnthropicKey.get())
                            && "2023-06-01".equals(lastAnthropicVer.get()),
                    "Transport: Anthropic native /v1/messages sends x-api-key and anthropic-version");

            String geminiReply =
                    AiAuthManager.executeChatCompletion(
                            new AiAuthManager.ResolvedRequest(
                                    AiAuthManager.WIRE_GEMINI,
                                    base,
                                    "gemini-2.5-flash",
                                    "AIza-test-key",
                                    "",
                                    ""),
                            "sys",
                            "hi",
                            64,
                            0.2);
            check(
                    "连接正常-Gemini".equals(geminiReply)
                            && "AIza-test-key".equals(lastGeminiKey.get())
                            && lastGeminiQuery.get().isEmpty(),
                    "Transport: Gemini native generateContent sends x-goog-api-key header (never in URL query)");
        } finally {
            server.stop(0);
        }
    }

    private static void test3_FullEpisodeSlidingSubtitleTranslator() throws Exception {
        // Build a 120-cue SRT (3x larger than the old 40-cue limit!)
        StringBuilder srt = new StringBuilder();
        for (int i = 0; i < 120; i++) {
            long startSec = i * 5L;
            long endSec = startSec + 4L;
            srt.append(i + 1)
                    .append('\n')
                    .append(formatSrtTs(startSec * 1000L))
                    .append(" --> ")
                    .append(formatSrtTs(endSec * 1000L))
                    .append('\n')
                    .append("Line ")
                    .append(i + 1)
                    .append(" spoken by Ye Wenjie")
                    .append("\n\n");
        }
        List<AiSubtitleTranslator.SrtCue> cues = AiSubtitleTranslator.parseSrt(srt.toString());
        check(cues.size() == 120, "Subtitle: parses all 120 cues with zero 40-cue truncation");

        // Seek focus at cue index 70 (350s = 350_000ms)
        int focus = AiSubtitleTranslator.findCueIndexAt(cues, 351_000L);
        check(focus == 70, "Subtitle: findCueIndexAt locates cue #70 at 351s");

        List<int[]> plan = AiSubtitleTranslator.planSlidingChunks(120, focus, 25);
        check(
                plan.size() == 5
                        && plan.get(0)[0] == 50
                        && plan.get(0)[1] == 75
                        && plan.get(1)[0] == 75
                        && plan.get(1)[1] == 100
                        && plan.get(2)[0] == 100
                        && plan.get(2)[1] == 120,
                "Subtitle: sliding-window schedules playback chunk [50..75) first, then forward chunks, then backfill");

        // Verify partial render preserves all 120 cues losslessly
        String[] partial = new String[120];
        partial[70] = "第71句叶文洁台词";
        String partialRendered = AiSubtitleTranslator.renderSrt(cues, partial, true);
        check(
                partialRendered.contains("第71句叶文洁台词\nLine 71 spoken by Ye Wenjie")
                        && partialRendered.contains("Line 120 spoken by Ye Wenjie"),
                "Subtitle: partial render displays translated focus cue AND preserves all untranslated tail cues");

        // Full-episode translation carries glossary across chunks
        final List<Integer> chunkStarts = new ArrayList<>();
        final AtomicBoolean glossaryCarried = new AtomicBoolean(false);
        String fullRendered =
                AiSubtitleTranslator.translateFullEpisodeSync(
                        "三体",
                        srt.toString(),
                        351_000L,
                        25,
                        true,
                        (title, lines, glossary) -> {
                            int firstLineNum = Integer.parseInt(lines.get(0).split(" ")[1]);
                            chunkStarts.add(firstLineNum);
                            if (chunkStarts.size() > 1 && "叶文洁".equals(glossary.get("Ye Wenjie"))) {
                                glossaryCarried.set(true);
                            }
                            List<String> zh = new ArrayList<>(lines.size());
                            for (String l : lines) zh.add("译:" + l);
                            Map<String, String> g =
                                    chunkStarts.size() == 1
                                            ? Collections.singletonMap("Ye Wenjie", "叶文洁")
                                            : Collections.emptyMap();
                            return new AiSubtitleTranslator.ChunkTranslation(zh, g);
                        });
        List<AiSubtitleTranslator.SrtCue> finalCues = AiSubtitleTranslator.parseSrt(fullRendered);
        check(
                finalCues.size() == 120
                        && chunkStarts.get(0) == 51
                        && glossaryCarried.get()
                        && fullRendered.contains("译:Line 120 spoken by Ye Wenjie"),
                "Subtitle: full-episode sync translates all 120 cues starting at focus window with glossary carry-over");

        // Context extraction for Copilot Q&A
        String snippet = AiSubtitleTranslator.extractContextAround(cues, 351_000L, 10_000L);
        check(
                snippet.contains("Line 71")
                        && snippet.contains("Line 69")
                        && !snippet.contains("Line 1 "),
                "Subtitle: extractContextAround isolates nearby dialogue around playback timestamp");
    }

    private static void test4_CinemaCopilotPromptsAndParser() {
        check(
                AiCinemaCopilot.parseEpisodeNumber("第08集") == 8
                        && AiCinemaCopilot.parseEpisodeNumber("S02E12 4K") == 12
                        && AiCinemaCopilot.parseEpisodeNumber("第3话") == 3
                        && AiCinemaCopilot.parseEpisodeNumber("1080P 正片") == 0,
                "Copilot: parseEpisodeNumber extracts episode index and returns 0 for movies");

        String sysPrompt = AiCinemaCopilot.buildSpoilerFreeRecapSystemPrompt("三体", 8, "第08集");
        check(
                sysPrompt.contains("第 1 集至第 7 集") && sysPrompt.contains("严禁提及第 8 集及之后"),
                "Copilot: spoiler-free prompt strictly fences recap to episodes 1..(N-1)");

        String mockReply =
                "```json\n"
                        + "{\"recommendations\":["
                        + "{\"title\":\"降临\",\"year\":\"2016\",\"reason\":\"语言学硬科幻经典，情感与悬念俱佳\",\"tags\":[\"硬科幻\",\"高分\"]},"
                        + "{\"title\":\"星际穿越\",\"year\":\"2014\",\"reason\":\"宏大宇宙尺度与父女情感交织\",\"tags\":[\"太空\",\"必看\"]}"
                        + "]}\n```";
        List<AiCinemaCopilot.Recommendation> recs = AiCinemaCopilot.parseRecommendations(mockReply);
        check(
                recs.size() == 2
                        && "降临".equals(recs.get(0).title)
                        && "2016".equals(recs.get(0).year)
                        && recs.get(0).tags.size() == 2
                        && "星际穿越".equals(recs.get(1).title),
                "Copilot: parseRecommendations cleanly extracts fenced JSON movie cards");
    }

    private static void test5_StaticHygieneAndInvariants(Path root) throws Exception {
        check(Prefs.KEYS.length == 46, "Invariant: Prefs.KEYS remains strictly length 46");
        check(
                "openai".equals(Prefs.sanitizeMobileSetting(Prefs.AI_PROVIDER, "openai"))
                        && "anthropic"
                                .equals(Prefs.sanitizeMobileSetting(Prefs.AI_PROVIDER, "anthropic"))
                        && "gemini".equals(Prefs.sanitizeMobileSetting(Prefs.AI_PROVIDER, "gemini"))
                        && "openrouter"
                                .equals(
                                        Prefs.sanitizeMobileSetting(
                                                Prefs.AI_PROVIDER, "openrouter"))
                        && Prefs.sanitizeMobileSetting(Prefs.AI_PROVIDER, "invalid_xyz") == null,
                "Invariant: Prefs.AI_PROVIDER sanitizer accepts new official providers and rejects bogus values");

        String[] newFiles = {
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiBetaGate.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiAuthManager.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiAssistantService.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiSubtitleTranslator.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiCinemaCopilot.java"
        };
        for (String rel : newFiles) {
            String src = Files.readString(root.resolve(rel), StandardCharsets.UTF_8);
            check(!containsEmoji(src), "Hygiene: zero UI chrome emoji in " + rel);
        }

        String aiSvc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/AiAssistantService.java"),
                        StandardCharsets.UTF_8);
        String settings =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileSettingsScreen.java"),
                        StandardCharsets.UTF_8);
        String controls =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/PlaybackControls.java"),
                        StandardCharsets.UTF_8);
        String search =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileSearchPage.java"),
                        StandardCharsets.UTF_8);
        check(
                aiSvc.contains("if (!AiBetaGate.isUnlocked(a)) return false;")
                        && settings.contains("if (!aiBetaStatus.coreAiEnabled())")
                        && controls.contains("if (AiBetaGate.isUnlocked(a))")
                        && search.contains("if (AiBetaGate.isUnlocked(a))"),
                "Gating: AI service, Settings, Player Copilot, and Search AI Discovery are all gated behind AiBetaGate");
    }

    private static boolean containsEmoji(String text) {
        for (int i = 0; i < text.length(); ) {
            int cp = text.codePointAt(i);
            i += Character.charCount(cp);
            if ((cp >= 0x1F300 && cp <= 0x1FAFF) || (cp >= 0x2600 && cp <= 0x27BF)) {
                return true;
            }
        }
        return false;
    }

    private static String formatSrtTs(long ms) {
        long h = ms / 3600_000L;
        long m = (ms % 3600_000L) / 60_000L;
        long s = (ms % 60_000L) / 1000L;
        long rem = ms % 1000L;
        return String.format(Locale.US, "%02d:%02d:%02d,%03d", h, m, s, rem);
    }

    private static String readBody(HttpExchange ex) throws IOException {
        try (InputStream in = ex.getRequestBody();
                ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static void writeJson(HttpExchange ex, int status, String json) throws IOException {
        byte[] b = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=UTF-8");
        ex.sendResponseHeaders(status, b.length);
        try (OutputStream out = ex.getResponseBody()) {
            out.write(b);
        }
    }
}

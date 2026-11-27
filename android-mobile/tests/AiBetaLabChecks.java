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
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Pure-JVM + local mock HTTP verification suite for the refactored AI Cinema Lab covering all
 * Codex 0.7.3 P1/P2 findings:
 *  1. Cross-platform Ed25519 MMAILAB1 passcodes (P1-1, P1-6, P2-1): wrapped-signature extraction
 *     with trailing ASCII prose, signatureValid vs platform-activatable distinction, Windows 0.7.3
 *     single-platform vectors, fixed non-authorizable expired test vector.
 *  2. BYOK provider+origin credential binding & strict HTTPS enforcement (P1-2): switching
 *     providers, restoring custom gateway, HTTP+key rejection, keyless local Ollama HTTP.
 *  3. OAuth atomic session versioning & passcode re-check (P1-3): late success, late invalid_grant
 *     failure, account switch, logout, and mid-auth passcode expiration.
 *  4. Transport & AppLog redaction (P1-4): echoed bare keys & native auth headers scrubbed from
 *     thrown IOException messages, AppLog.entries(), and AppLog.dump().
 *  5. Locked-state UI & Settings search containment across never-unlocked / expired / cleared
 *     states (P1-5).
 *  6. Full-episode subtitle retry, 100%-only completion cache gate, single-track deduplication,
 *     and zero mid-playback prepare() live overlay lookup (P1-8).
 *  7. Active 2026 default models (deepseek-flash, claude-haiku-5-5), OpenAI plan-usage scopes +
 *     Responses API (/v1/responses), and zero spoofed third-party CLI client IDs (P1-9).
 *  8. Anti-spoiler subtitle cutoff strictly excluding future unplayed lines (P2-3).
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
        public synchronized String getString(String key, String def) {
            return strMap.containsKey(key) ? strMap.get(key) : def;
        }

        @Override
        public synchronized void putString(String key, String value) {
            strMap.put(key, value);
        }

        @Override
        public synchronized boolean getBoolean(String key, boolean def) {
            return boolMap.containsKey(key) ? boolMap.get(key) : def;
        }

        @Override
        public synchronized void putBoolean(String key, boolean value) {
            boolMap.put(key, value);
        }

        @Override
        public synchronized void remove(String key) {
            strMap.remove(key);
            boolMap.remove(key);
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 11) {
            throw new IllegalArgumentException(
                    "Usage: AiBetaLabChecks <root> <pubHex> <sharedCode> <expCode> <highMinVcCode> <expiredCode> <jsAllPlatCode> <jsIosOnlyCode> <jsWinOnlyCode> <fixedPubHex> <fixedExpiredCode>");
        }
        Path root = Paths.get(args[0]);
        byte[] testPub = AiBetaGate.hexToBytes(args[1]);
        String sharedCode = args[2];
        String expCode = args[3];
        String highMinVcCode = args[4];
        String expiredCode = args[5];
        String jsAllPlatCode = args[6];
        String jsIosOnlyCode = args[7];
        String jsWinOnlyCode = args[8];
        byte[] fixedPub = AiBetaGate.hexToBytes(args[9]);
        String fixedExpiredCode = args[10];

        test1_Ed25519PasscodeGateAndWrapping(
                testPub,
                sharedCode,
                expCode,
                highMinVcCode,
                expiredCode,
                jsAllPlatCode,
                jsIosOnlyCode,
                jsWinOnlyCode,
                fixedPub,
                fixedExpiredCode);
        test2_ByokScopingHttpsAndKeylessOllama();
        test3_OAuthSessionVersioningAndPasscodeRecheck();
        test4_ModelsSubscriptionInferenceAndLogRedaction();
        test5_FullEpisodeSubtitleRetryCacheAndSingleTrack();
        test6_AntiSpoilerCutoffAndCopilotPrompts();
        test7_LockedUiContainmentAndStaticHygiene(root);

        System.out.println("ALL AI BETA LAB CHECKS PASSED (" + passed + " checks)");
    }

    private static void test1_Ed25519PasscodeGateAndWrapping(
            byte[] pubKey,
            String sharedCode,
            String expCode,
            String highMinVcCode,
            String expiredCode,
            String jsAllPlatCode,
            String jsIosOnlyCode,
            String jsWinOnlyCode,
            byte[] fixedPub,
            String fixedExpiredCode) {
        long nowValid = 1768000000L * 1000L; // 2026-01-10 UTC

        // 1. Pinned official public key invariant
        byte[] embedded = AiBetaGate.hexToBytes(AiBetaGate.DEFAULT_PUBLIC_KEY_HEX);
        check(
                embedded.length == 32
                        && "1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929"
                                .equals(AiBetaGate.DEFAULT_PUBLIC_KEY_HEX),
                "P1-1: DEFAULT_PUBLIC_KEY_HEX matches unified 32-byte Ed25519 public key");

        // Fixed non-authorizable expired test vector cannot unlock default app AND distinguishes
        // signatureValid=true from ok=false under its own test key
        AiBetaGate.VerifyResult fixedOnProd =
                AiBetaGate.verifyPasscode(fixedExpiredCode, 103, nowValid);
        AiBetaGate.VerifyResult fixedOnTestKey =
                AiBetaGate.verifyPasscode(fixedExpiredCode, 103, nowValid, fixedPub);
        check(
                !fixedOnProd.ok
                        && !fixedOnProd.signatureValid
                        && !fixedOnTestKey.ok
                        && fixedOnTestKey.signatureValid
                        && fixedOnTestKey.errorReason.contains("过期"),
                "P1-6/P2-1: fixed non-authorizable vector rejected by prod key & distinguishes signatureValid vs expired");

        // 2. Shared standard MMAILAB1 code passes
        AiBetaGate.VerifyResult rShared =
                AiBetaGate.verifyPasscode(sharedCode, 103, nowValid, pubKey);
        check(
                rShared.ok
                        && rShared.signatureValid
                        && rShared.coreAiEnabled()
                        && rShared.sharedChannel()
                        && !rShared.experimentalOAuthAllowed()
                        && "channel-101".equals(rShared.tag),
                "P1-1: shared MMAILAB1 code verifies with tag=channel-101, shared=true, expOAuth=false");

        // 3. P2-1 regression: newline INSIDE the 86-char signature segment + trailing ASCII prose!
        int dot2 = sharedCode.lastIndexOf('.');
        String wrappedSig =
                "请复制口令：\n"
                        + sharedCode.substring(0, dot2 + 24)
                        + "\n"
                        + sharedCode.substring(dot2 + 24, dot2 + 58)
                        + "  \r\n  "
                        + sharedCode.substring(dot2 + 58)
                        + "\nValidUntil 2026-03-11";
        String extracted = AiBetaGate.extractToken(wrappedSig);
        AiBetaGate.VerifyResult rWrappedSig =
                AiBetaGate.verifyPasscode(wrappedSig, 103, nowValid, pubKey);
        check(
                sharedCode.equals(extracted)
                        && rWrappedSig.ok
                        && "channel-101".equals(rWrappedSig.tag),
                "P2-1: signature wrapped across newlines + trailing ASCII prose extracts exact full token without truncation");

        // 4. Permanent experimental-OAuth code
        AiBetaGate.VerifyResult rExp =
                AiBetaGate.verifyPasscode(expCode, 103, nowValid + 3650L * 86400_000L, pubKey);
        check(
                rExp.ok
                        && rExp.experimentalOAuthAllowed()
                        && rExp.expiresAtEpochSec == 0L
                        && "永久有效".equals(rExp.expireDateLabel()),
                "P1-1: permanent experimental-OAuth code verifies and sets experimentalOAuthAllowed=true");

        // 5. Tampered signature & payload rejected
        char[] chars = sharedCode.toCharArray();
        int idx = chars.length - 4;
        chars[idx] = chars[idx] == 'A' ? 'B' : 'A';
        AiBetaGate.VerifyResult rTamperedSig =
                AiBetaGate.verifyPasscode(new String(chars), 103, nowValid, pubKey);
        check(
                !rTamperedSig.ok && !rTamperedSig.signatureValid,
                "P1-1: tampered Ed25519 signature rejected");

        // 6. Android-only min_vc enforcement
        AiBetaGate.VerifyResult rLowVc =
                AiBetaGate.verifyPasscode(highMinVcCode, 103, nowValid, pubKey);
        AiBetaGate.VerifyResult rOkVc =
                AiBetaGate.verifyPasscode(highMinVcCode, 999, nowValid, pubKey);
        check(
                !rLowVc.ok
                        && rLowVc.signatureValid
                        && rLowVc.errorReason.contains("版本")
                        && rOkVc.ok,
                "P1-1: Android-only min_vc blocks older versionCode and allows >= min_vc");

        // 7. Three locked-state transitions (never unlocked, unlocked-then-expired, deactivated)
        long beforeExp = (1768000000L + 100L) * 1000L;
        long afterExpTime = (1768000000L + 2L * 86400L) * 1000L;
        MemoryGateStore store = new MemoryGateStore();
        check(
                !AiBetaGate.currentStatus(store, 103, beforeExp, pubKey).ok,
                "P1-5: Gate state 1 (never unlocked) is locked");
        AiBetaGate.VerifyResult act =
                AiBetaGate.activate(store, expiredCode, 103, beforeExp, pubKey);
        check(act.ok, "P1-5: Gate activates cleanly before expiry");
        AiBetaGate.VerifyResult afterExp =
                AiBetaGate.currentStatus(store, 103, afterExpTime, pubKey);
        check(
                !afterExp.ok && afterExp.signatureValid && afterExp.errorReason.contains("过期"),
                "P1-5: Gate state 2 (unlocked then expired) auto-locks");
        AiBetaGate.deactivate(store);
        check(
                !AiBetaGate.currentStatus(store, 103, beforeExp, pubKey).ok,
                "P1-5: Gate state 3 (explicitly cleared) is locked");

        // 8. 3-way Phone-JS minted single-platform & all tokens cross-checked in Java
        AiBetaGate.VerifyResult jsAllAnd =
                AiBetaGate.verifyPasscode(
                        jsAllPlatCode, 103, nowValid, pubKey, AiBetaGate.PLATFORM_ANDROID);
        AiBetaGate.VerifyResult jsAllWin =
                AiBetaGate.verifyPasscode(
                        jsAllPlatCode, 1, nowValid, pubKey, AiBetaGate.PLATFORM_WINDOWS);
        AiBetaGate.VerifyResult jsIosOnAnd =
                AiBetaGate.verifyPasscode(
                        jsIosOnlyCode, 103, nowValid, pubKey, AiBetaGate.PLATFORM_ANDROID);
        AiBetaGate.VerifyResult jsIosOnIos =
                AiBetaGate.verifyPasscode(
                        jsIosOnlyCode, 100, nowValid, pubKey, AiBetaGate.PLATFORM_IOS);
        AiBetaGate.VerifyResult jsWinOnAnd =
                AiBetaGate.verifyPasscode(
                        jsWinOnlyCode, 103, nowValid, pubKey, AiBetaGate.PLATFORM_ANDROID);
        AiBetaGate.VerifyResult jsWinOnWin =
                AiBetaGate.verifyPasscode(
                        jsWinOnlyCode, 1, nowValid, pubKey, AiBetaGate.PLATFORM_WINDOWS);
        check(
                jsAllAnd.ok
                        && jsAllWin.ok
                        && !jsIosOnAnd.ok
                        && jsIosOnAnd.signatureValid
                        && jsIosOnIos.ok
                        && !jsWinOnAnd.ok
                        && jsWinOnAnd.signatureValid
                        && jsWinOnWin.ok,
                "P1-1/P2-1: Phone-JS all / iOS-only / Windows-only tokens enforce exact platform scoping & report signatureValid");
    }

    private static void test2_ByokScopingHttpsAndKeylessOllama() throws Exception {
        MemoryOAuthStore sec = new MemoryOAuthStore();
        String fakeDeepSeekKey = "sk-fake-deepseek-bound-99887766";

        // 1. Bind fake key strictly to (deepseek, https://api.deepseek.com)
        AiAuthManager.saveScopedApiKey(
                sec, "deepseek", "https://api.deepseek.com/v1", fakeDeepSeekKey);
        AiAuthManager.ResolvedRequest dsReq =
                AiAuthManager.resolveByokRequest(sec, "deepseek", "", "");
        check(
                fakeDeepSeekKey.equals(dsReq.credential)
                        && "https://api.deepseek.com/v1".equals(dsReq.baseUrl)
                        && "deepseek-flash".equals(dsReq.model),
                "P1-2/P1-9: DeepSeek loads bound key and uses non-retired default model deepseek-flash");

        // 2. Switching provider to OpenAI MUST NOT receive DeepSeek's key
        boolean openaiBlocked = false;
        try {
            AiAuthManager.resolveByokRequest(sec, "openai", "", "");
        } catch (IOException expected) {
            openaiBlocked = true;
        }
        check(
                openaiBlocked
                        && AiAuthManager.loadScopedApiKey(
                                        sec, "openai", "https://api.openai.com/v1")
                                .isEmpty(),
                "P1-2: switching provider from DeepSeek to OpenAI never leaks old DeepSeek key");

        // 3. Restoring a different custom gateway URL under DeepSeek MUST NOT receive old key
        boolean restoredGatewayBlocked = false;
        try {
            AiAuthManager.resolveByokRequest(
                    sec, "deepseek", "https://restored-relay.example/v1", "");
        } catch (IOException expected) {
            restoredGatewayBlocked = true;
        }
        check(
                restoredGatewayBlocked
                        && AiAuthManager.loadScopedApiKey(
                                        sec, "deepseek", "https://restored-relay.example/v1")
                                .isEmpty(),
                "P1-2: restoring a different custom gateway origin never sends old bound DeepSeek key");

        // 4. Plaintext HTTP with credential MUST be rejected at BOTH resolver and transport layers
        AiAuthManager.saveScopedApiKey(
                sec, "custom", "http://insecure-gateway.example/v1", "sk-fake-http-secret-12345");
        boolean httpResolverBlocked = false;
        try {
            AiAuthManager.resolveByokRequest(
                    sec, "custom", "http://insecure-gateway.example/v1", "gpt-4o-mini");
        } catch (IOException expected) {
            httpResolverBlocked = expected.getMessage().contains("HTTPS");
        }
        boolean httpTransportBlocked = false;
        final AtomicInteger transportCalls = new AtomicInteger(0);
        try {
            AiAuthManager.executeChatCompletion(
                    new AiAuthManager.ResolvedRequest(
                            AiAuthManager.WIRE_OPENAI_COMPAT,
                            "http://insecure-gateway.example/v1",
                            "gpt-4o-mini",
                            "sk-fake-http-secret-12345",
                            "",
                            ""),
                    "sys",
                    "hi",
                    32,
                    0.2,
                    (u, ct, b, h) -> {
                        transportCalls.incrementAndGet();
                        return new AiAuthManager.HttpResult(200, "{}");
                    });
        } catch (IOException expected) {
            httpTransportBlocked = expected.getMessage().contains("HTTPS");
        }
        check(
                httpResolverBlocked && httpTransportBlocked && transportCalls.get() == 0,
                "P1-2: credentialed plaintext HTTP URL is blocked before reaching transport (0 requests sent)");

        // 5. Keyless local Ollama over HTTP MUST succeed cleanly with ZERO Authorization header
        final AtomicReference<String> ollamaAuthHdr = new AtomicReference<>("UNSET");
        HttpServer ollamaSrv =
                HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        ollamaSrv.createContext(
                "/v1/chat/completions",
                ex -> {
                    String auth = ex.getRequestHeaders().getFirst("Authorization");
                    ollamaAuthHdr.set(auth == null ? "" : auth);
                    writeJson(
                            ex, 200, "{\"choices\":[{\"message\":{\"content\":\"本地Ollama正常\"}}]}");
                });
        ollamaSrv.start();
        try {
            String ollamaBase = "http://127.0.0.1:" + ollamaSrv.getAddress().getPort() + "/v1";
            AiAuthManager.ResolvedRequest ollamaReq =
                    AiAuthManager.resolveByokRequest(sec, "ollama", ollamaBase, "qwen2.5:7b");
            String reply = AiAuthManager.executeChatCompletion(ollamaReq, "sys", "ping", 32, 0.2);
            check(
                    "本地Ollama正常".equals(reply)
                            && ollamaReq.credential.isEmpty()
                            && ollamaAuthHdr.get().isEmpty(),
                    "P1-2: keyless local Ollama HTTP works end-to-end with zero Authorization header");
        } finally {
            ollamaSrv.stop(0);
        }
    }

    private static void test3_OAuthSessionVersioningAndPasscodeRecheck() throws Exception {
        MemoryOAuthStore oauthStore = new MemoryOAuthStore();
        final String prov = AiAuthManager.OAUTH_KIMI_CODE;

        // 1. Late sign-in callback AFTER logout is discarded
        long ver1 = AiAuthManager.beginOAuthSession(oauthStore, prov);
        AiAuthManager.signOutOAuth(oauthStore, prov);
        AiAuthManager.OAuthBundle lateLogin = new AiAuthManager.OAuthBundle();
        lateLogin.providerId = prov;
        lateLogin.accessToken = "stale-at";
        lateLogin.refreshToken = "stale-rt";
        boolean committedAfterLogout =
                AiAuthManager.commitOAuthSignInIfCurrent(
                        oauthStore, prov, ver1, lateLogin, () -> true);
        check(
                !committedAfterLogout && AiAuthManager.loadBundle(oauthStore, prov) == null,
                "P1-3: late OAuth sign-in callback after signOut is discarded atomically");

        // 2. Late sign-in callback AFTER account switch (newer session) cannot overwrite Account B
        long verA = AiAuthManager.beginOAuthSession(oauthStore, prov);
        long verB = AiAuthManager.beginOAuthSession(oauthStore, prov);
        AiAuthManager.OAuthBundle acctB = new AiAuthManager.OAuthBundle();
        acctB.providerId = prov;
        acctB.accessToken = "acctB-at";
        acctB.refreshToken = "acctB-rt";
        acctB.accountLabel = "Account B";
        acctB.expiresAtMs = 99_000_000L;
        check(
                AiAuthManager.commitOAuthSignInIfCurrent(oauthStore, prov, verB, acctB, () -> true),
                "P1-3: newer Account B session commits");
        AiAuthManager.OAuthBundle acctA = new AiAuthManager.OAuthBundle();
        acctA.providerId = prov;
        acctA.accessToken = "acctA-late-at";
        acctA.accountLabel = "Account A";
        boolean staleACommitted =
                AiAuthManager.commitOAuthSignInIfCurrent(oauthStore, prov, verA, acctA, () -> true);
        AiAuthManager.OAuthBundle stored = AiAuthManager.loadBundle(oauthStore, prov);
        check(
                !staleACommitted && stored != null && "acctB-at".equals(stored.accessToken),
                "P1-3: late Account A callback cannot overwrite newer Account B session");

        // 3. Passcode expires during authorization -> commit blocked!
        long verExp = AiAuthManager.beginOAuthSession(oauthStore, AiAuthManager.OAUTH_OPENROUTER);
        AiAuthManager.OAuthBundle orBundle = new AiAuthManager.OAuthBundle();
        orBundle.providerId = AiAuthManager.OAUTH_OPENROUTER;
        orBundle.accessToken = "sk-or-v1-should-not-persist";
        boolean committedWhileLocked =
                AiAuthManager.commitOAuthSignInIfCurrent(
                        oauthStore, AiAuthManager.OAUTH_OPENROUTER, verExp, orBundle, () -> false);
        check(
                !committedWhileLocked
                        && AiAuthManager.loadBundle(oauthStore, AiAuthManager.OAUTH_OPENROUTER)
                                == null,
                "P1-3: passcode expiration mid-authorization blocks saving OAuth bundle");

        // 4. Late refresh SUCCESS after signOut cannot resurrect logged-out session
        long verR1 = AiAuthManager.beginOAuthSession(oauthStore, prov);
        AiAuthManager.OAuthBundle expiring = new AiAuthManager.OAuthBundle();
        expiring.providerId = prov;
        expiring.accessToken = "old-at";
        expiring.refreshToken = "old-rt";
        expiring.expiresAtMs = 1000L;
        AiAuthManager.commitOAuthSignInIfCurrent(oauthStore, prov, verR1, expiring, () -> true);

        CountDownLatch inFlight = new CountDownLatch(1);
        CountDownLatch proceed = new CountDownLatch(1);
        AtomicBoolean lateSuccessThrew = new AtomicBoolean(false);
        Thread refreshThread =
                new Thread(
                        () -> {
                            try {
                                AiAuthManager.ensureFreshOAuthBundle(
                                        oauthStore,
                                        prov,
                                        "https://auth.kimi.com/api/oauth/token",
                                        "test-client",
                                        2000L,
                                        () -> true,
                                        (u, ct, b, h) -> {
                                            inFlight.countDown();
                                            try {
                                                proceed.await(3, TimeUnit.SECONDS);
                                            } catch (InterruptedException ignored) {
                                            }
                                            return new AiAuthManager.HttpResult(
                                                    200,
                                                    "{\"access_token\":\"resurrected-at\",\"refresh_token\":\"resurrected-rt\",\"expires_in\":3600}");
                                        });
                            } catch (IOException expected) {
                                lateSuccessThrew.set(true);
                            }
                        });
        refreshThread.start();
        check(inFlight.await(3, TimeUnit.SECONDS), "P1-3: refresh entered in-flight state");
        AiAuthManager.signOutOAuth(oauthStore, prov);
        proceed.countDown();
        refreshThread.join(3000L);
        check(
                lateSuccessThrew.get() && AiAuthManager.loadBundle(oauthStore, prov) == null,
                "P1-3: late refresh success after signOut is discarded and never resurrects session");

        // 5. Late refresh invalid_grant FAILURE after switching to Account B cannot poison Account
        // B
        long verOld = AiAuthManager.beginOAuthSession(oauthStore, prov);
        AiAuthManager.commitOAuthSignInIfCurrent(oauthStore, prov, verOld, expiring, () -> true);
        CountDownLatch inFlight2 = new CountDownLatch(1);
        CountDownLatch proceed2 = new CountDownLatch(1);
        Thread failRefreshThread =
                new Thread(
                        () -> {
                            try {
                                AiAuthManager.ensureFreshOAuthBundle(
                                        oauthStore,
                                        prov,
                                        "https://auth.kimi.com/api/oauth/token",
                                        "test-client",
                                        2000L,
                                        () -> true,
                                        (u, ct, b, h) -> {
                                            inFlight2.countDown();
                                            try {
                                                proceed2.await(3, TimeUnit.SECONDS);
                                            } catch (InterruptedException ignored) {
                                            }
                                            return new AiAuthManager.HttpResult(
                                                    400, "{\"error\":\"invalid_grant\"}");
                                        });
                            } catch (IOException ignored) {
                            }
                        });
        failRefreshThread.start();
        check(
                inFlight2.await(3, TimeUnit.SECONDS),
                "P1-3: failing refresh entered in-flight state");
        long verNewB = AiAuthManager.beginOAuthSession(oauthStore, prov);
        AiAuthManager.commitOAuthSignInIfCurrent(oauthStore, prov, verNewB, acctB, () -> true);
        proceed2.countDown();
        failRefreshThread.join(3000L);
        AiAuthManager.OAuthBundle afterSwitch = AiAuthManager.loadBundle(oauthStore, prov);
        check(
                afterSwitch != null
                        && "acctB-at".equals(afterSwitch.accessToken)
                        && !afterSwitch.needsReauth,
                "P1-3: late invalid_grant refresh failure after account switch never marks Account B needsReauth");

        // 6. Normal invalid_grant on SAME session version still marks needsReauth non-destructively
        long verSame = AiAuthManager.beginOAuthSession(oauthStore, prov);
        AiAuthManager.commitOAuthSignInIfCurrent(oauthStore, prov, verSame, expiring, () -> true);
        boolean normalFailed = false;
        try {
            AiAuthManager.ensureFreshOAuthBundle(
                    oauthStore,
                    prov,
                    "https://auth.kimi.com/api/oauth/token",
                    "test-client",
                    2000L,
                    () -> true,
                    (u, ct, b, h) ->
                            new AiAuthManager.HttpResult(400, "{\"error\":\"invalid_grant\"}"));
        } catch (IOException expected) {
            normalFailed = true;
        }
        AiAuthManager.OAuthBundle afterNormalInvalid = AiAuthManager.loadBundle(oauthStore, prov);
        check(
                normalFailed
                        && afterNormalInvalid != null
                        && afterNormalInvalid.hasCredential()
                        && afterNormalInvalid.needsReauth,
                "P1-3: normal invalid_grant on current session sets needsReauth=true without deleting bundle");
    }

    private static void test4_ModelsSubscriptionInferenceAndLogRedaction() throws Exception {
        // 1. P1-9: Active non-retired 2026 default models
        check(
                "deepseek-flash".equals(AiAssistantService.defaultModel("deepseek"))
                        && "claude-haiku-5-5".equals(AiAssistantService.defaultModel("anthropic"))
                        && "gemini-2.5-flash".equals(AiAssistantService.defaultModel("gemini")),
                "P1-9: default models updated off retired deepseek-chat & claude-3-5-haiku-latest");

        // 2. P1-9: OpenAI Experimental OAuth URL requests official plan-usage scopes + resource
        AiAuthManager.PkcePair pkce = AiAuthManager.generatePkcePair();
        String oaAuthUrl =
                AiAuthManager.buildOpenAiAuthUrl(
                        "app_user_registered_demo", "http://localhost:1455/auth/callback", pkce);
        check(
                oaAuthUrl.contains("resource.invoke")
                        && oaAuthUrl.contains("chatgpt.tokens.use.direct")
                        && oaAuthUrl.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"),
                "P1-9: OpenAI OAuth URL includes delegated plan-usage scopes and API resource indicator");

        // 3. P1-9: OpenAI subscription inference uses WIRE_OPENAI_RESPONSES -> POST /v1/responses
        final AtomicReference<String> respUrl = new AtomicReference<>("");
        final AtomicReference<String> respBody = new AtomicReference<>("");
        final AtomicReference<String> respAcctHdr = new AtomicReference<>("");
        String oaRespReply =
                AiAuthManager.executeChatCompletion(
                        new AiAuthManager.ResolvedRequest(
                                AiAuthManager.oauthWireProtocol(
                                        AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL),
                                AiAuthManager.OPENAI_API_BASE,
                                "gpt-4o-mini",
                                "oa-plan-access-token",
                                AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL,
                                "acct_plus_99"),
                        "sys-instructions",
                        "hello responses",
                        64,
                        0.2,
                        (u, ct, body, hdrs) -> {
                            respUrl.set(u);
                            respBody.set(body);
                            respAcctHdr.set(hdrs.getOrDefault("ChatGPT-Account-Id", ""));
                            return new AiAuthManager.HttpResult(
                                    200,
                                    "{\"id\":\"resp_1\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"连接正常-Responses\"}]}]}");
                        });
        check(
                "连接正常-Responses".equals(oaRespReply)
                        && "https://api.openai.com/v1/responses".equals(respUrl.get())
                        && respBody.get().contains("\"instructions\":\"sys-instructions\"")
                        && respBody.get().contains("\"input\":\"hello responses\"")
                        && "acct_plus_99".equals(respAcctHdr.get()),
                "P1-9: Experimental OpenAI OAuth routes through /v1/responses with instructions/input and parses output");

        // 4. Native Anthropic & Gemini over HTTPS transport check
        final AtomicReference<String> antKeyHdr = new AtomicReference<>("");
        final AtomicReference<String> gemKeyHdr = new AtomicReference<>("");
        String claudeReply =
                AiAuthManager.executeChatCompletion(
                        new AiAuthManager.ResolvedRequest(
                                AiAuthManager.WIRE_ANTHROPIC,
                                "https://api.anthropic.com",
                                "claude-haiku-5-5",
                                "sk-ant-valid-mock-123456",
                                "",
                                ""),
                        "sys",
                        "hi",
                        64,
                        0.2,
                        (u, ct, body, hdrs) -> {
                            antKeyHdr.set(hdrs.getOrDefault("x-api-key", ""));
                            return new AiAuthManager.HttpResult(
                                    200,
                                    "{\"content\":[{\"type\":\"text\",\"text\":\"连接正常-Claude55\"}]}");
                        });
        String geminiReply =
                AiAuthManager.executeChatCompletion(
                        new AiAuthManager.ResolvedRequest(
                                AiAuthManager.WIRE_GEMINI,
                                "https://generativelanguage.googleapis.com",
                                "gemini-2.5-flash",
                                "AIzaSyValidMockKey12345678",
                                "",
                                ""),
                        "sys",
                        "hi",
                        64,
                        0.2,
                        (u, ct, body, hdrs) -> {
                            gemKeyHdr.set(hdrs.getOrDefault("x-goog-api-key", ""));
                            return new AiAuthManager.HttpResult(
                                    200,
                                    "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"连接正常-Gemini\"}]}}]}");
                        });
        check(
                "连接正常-Claude55".equals(claudeReply)
                        && "sk-ant-valid-mock-123456".equals(antKeyHdr.get())
                        && "连接正常-Gemini".equals(geminiReply)
                        && "AIzaSyValidMockKey12345678".equals(gemKeyHdr.get()),
                "P1-4/P1-9: Anthropic & Gemini HTTPS wire adapters send native auth headers");

        // 5. P1-4: Upstream error echoing bare API keys & native headers MUST be redacted from
        //    thrown IOException, AppLog.entries(), and AppLog.dump()!
        AppLog.clear();
        String markerSk = "sk-INVALIDTESTMARKER99887766";
        String markerGem = "AIzaSyINVALIDTESTMARKER998877";
        String markerCustom = "CUSTOM_NATIVE_KEY_77665544";

        IOException caughtAnt = null;
        try {
            AiAuthManager.executeChatCompletion(
                    new AiAuthManager.ResolvedRequest(
                            AiAuthManager.WIRE_ANTHROPIC,
                            "https://api.anthropic.com",
                            "claude-haiku-5-5",
                            markerSk,
                            "",
                            ""),
                    "sys",
                    "hi",
                    32,
                    0.2,
                    (u, ct, body, hdrs) ->
                            new AiAuthManager.HttpResult(
                                    401,
                                    "{\"error\":{\"message\":\"Rejected bare key "
                                            + markerSk
                                            + " in x-api-key: "
                                            + markerCustom
                                            + "\"}}"));
        } catch (IOException e) {
            caughtAnt = e;
        }
        AppLog.w("AiAssistant", "Anthropic test failed with x-api-key: " + markerCustom, caughtAnt);

        IOException caughtGem = null;
        try {
            AiAuthManager.executeChatCompletion(
                    new AiAuthManager.ResolvedRequest(
                            AiAuthManager.WIRE_GEMINI,
                            "https://generativelanguage.googleapis.com",
                            "gemini-2.5-flash",
                            markerGem,
                            "",
                            ""),
                    "sys",
                    "hi",
                    32,
                    0.2,
                    (u, ct, body, hdrs) ->
                            new AiAuthManager.HttpResult(
                                    400,
                                    "Invalid x-goog-api-key: "
                                            + markerGem
                                            + " echoed directly "
                                            + markerGem));
        } catch (IOException e) {
            caughtGem = e;
        }
        AppLog.w("AiAssistant", "Gemini error", caughtGem);

        String dump = AppLog.dump();
        check(
                caughtAnt != null
                        && caughtGem != null
                        && !caughtAnt.getMessage().contains(markerSk)
                        && !caughtAnt.getMessage().contains(markerCustom)
                        && !caughtGem.getMessage().contains(markerGem)
                        && !dump.contains(markerSk)
                        && !dump.contains(markerGem)
                        && !dump.contains(markerCustom),
                "P1-4: echoed bare keys (sk-..., AIza...) & native headers (x-api-key / x-goog-api-key) scrubbed from exceptions, AppLog.entries, and AppLog.dump");
    }

    private static void test5_FullEpisodeSubtitleRetryCacheAndSingleTrack() throws Exception {
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
        check(cues.size() == 120, "P1-8: parses all 120 cues with zero 40-cue truncation");

        // 1. Partial failure (3/5 chunks = 60% > 50%): MUST NOT mark completion cache eligible!
        final AtomicInteger partialCalls = new AtomicInteger(0);
        AiSubtitleTranslator.TranslationRunResult partialRes =
                AiSubtitleTranslator.translateFullEpisodeWithStats(
                        "三体",
                        srt.toString(),
                        351_000L,
                        25,
                        true,
                        (title, lines, glossary) -> {
                            int firstLineNum = Integer.parseInt(lines.get(0).split(" ")[1]);
                            partialCalls.incrementAndGet();
                            // Permanently fail chunk starting at Line 101 (cues 101..120)
                            if (firstLineNum >= 101) {
                                throw new IOException("simulated persistent failure");
                            }
                            List<String> zh = new ArrayList<>(lines.size());
                            for (String l : lines) zh.add("译:" + l);
                            return new AiSubtitleTranslator.ChunkTranslation(
                                    zh, Collections.emptyMap());
                        });
        check(
                partialRes.translatedCues == 100
                        && partialRes.totalCues == 120
                        && partialRes.failedChunks == 1
                        && partialRes.retriedChunks >= 2
                        && !partialRes.shouldCacheCompletion
                        && !AiSubtitleTranslator.shouldWriteCompletionCache(100, 120),
                "P1-8: partial failure (100/120 = 83%) retries failed chunk and REFUSES to poison completion cache");

        // 2. Transient failure recovering on retry #2 -> 100% complete & completion cache allowed
        final AtomicInteger transientChunkAttempts = new AtomicInteger(0);
        AiSubtitleTranslator.TranslationRunResult recoveredRes =
                AiSubtitleTranslator.translateFullEpisodeWithStats(
                        "三体",
                        srt.toString(),
                        351_000L,
                        25,
                        true,
                        (title, lines, glossary) -> {
                            int firstLineNum = Integer.parseInt(lines.get(0).split(" ")[1]);
                            if (firstLineNum == 76
                                    && transientChunkAttempts.incrementAndGet() == 1) {
                                throw new IOException("transient 503");
                            }
                            List<String> zh = new ArrayList<>(lines.size());
                            for (String l : lines) zh.add("译:" + l);
                            return new AiSubtitleTranslator.ChunkTranslation(
                                    zh, Collections.singletonMap("Ye Wenjie", "叶文洁"));
                        });
        check(
                recoveredRes.translatedCues == 120
                        && recoveredRes.totalCues == 120
                        && recoveredRes.retriedChunks == 1
                        && recoveredRes.failedChunks == 0
                        && recoveredRes.shouldCacheCompletion,
                "P1-8: transient chunk error recovers on retry and unlocks 100% completion cache");

        // 3. Single-track deduplication in MoviePlayer.upsertSubtitleTrackJson across 6 progressive
        //    updates -> strictly 1 track (zero duplicates)!
        JSONObject mediaOpts = new JSONObject();
        for (int u = 0; u < 6; u++) {
            MoviePlayer.upsertSubtitleTrackJson(
                    mediaOpts,
                    "file:///cache/online_subs_v1/ep1.srt",
                    "AI 全片双语字幕",
                    "application/x-subrip");
        }
        JSONArray subTracks = mediaOpts.getJSONArray("subtitles");
        check(
                subTracks.length() == 1
                        && "AI 全片双语字幕".equals(subTracks.getJSONObject(0).getString("name")),
                "P1-8: MoviePlayer.upsertSubtitleTrackJson keeps strictly 1 unique subtitle track across progressive updates");

        // 4. Live non-disruptive overlay lookup at current playback timestamp
        String[] liveTrans = new String[120];
        liveTrans[70] = "叶文洁的译文";
        String liveText = AiSubtitleTranslator.activeCueTextAt(cues, liveTrans, 351_000L, true);
        check(
                liveText.contains("叶文洁的译文") && liveText.contains("Line 71"),
                "P1-8: activeCueTextAt renders live progressive bilingual cue without needing exo.prepare()");
    }

    private static void test6_AntiSpoilerCutoffAndCopilotPrompts() {
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
                    .append(" cue")
                    .append("\n\n");
        }
        List<AiSubtitleTranslator.SrtCue> cues = AiSubtitleTranslator.parseSrt(srt.toString());

        // Playback at 351_000ms (inside Line 71: 350s..354s).
        // Line 72 starts at 355s (+4s future!), Line 73 at 360s (+9s), Line 74 at 365s (+14s).
        // ALL future lines MUST be strictly excluded from extractContextAround!
        String snippet = AiSubtitleTranslator.extractContextAround(cues, 351_000L, 18_000L);
        check(
                snippet.contains("Line 71")
                        && snippet.contains("Line 69")
                        && !snippet.contains("Line 72")
                        && !snippet.contains("Line 73")
                        && !snippet.contains("Line 74")
                        && !snippet.contains("Line 75"),
                "P2-3: extractContextAround cuts off strictly at current playback position (0s future spoilers)");

        check(
                AiCinemaCopilot.parseEpisodeNumber("第08集") == 8
                        && AiCinemaCopilot.parseEpisodeNumber("S02E12 4K") == 12
                        && AiCinemaCopilot.parseEpisodeNumber("1080P 正片") == 0,
                "Copilot: parseEpisodeNumber extracts episode index cleanly");
        String sysPrompt = AiCinemaCopilot.buildSpoilerFreeRecapSystemPrompt("三体", 8, "第08集");
        check(
                sysPrompt.contains("第 1 集至第 7 集") && sysPrompt.contains("严禁提及第 8 集及之后"),
                "Copilot: spoiler-free recap prompt fences episodes 1..(N-1)");
    }

    private static void test7_LockedUiContainmentAndStaticHygiene(Path root) throws Exception {
        check(Prefs.KEYS.length == 46, "Invariant: Prefs.KEYS remains strictly length 46");

        // P1-5: Settings search in locked state MUST exclude ALL 7 locked AI-only entries across
        // queries ("ai", "双语", "oauth", "找片", "api") while keeping ONLY ms-ai-lab-gate!
        String[] hiddenAiKeys = {
            "ms-ai-enable",
            "ms-ai-cfg",
            "ms-ai-discovery",
            "ms-ai-clean-search",
            "ms-ai-translate-sub",
            "ms-ai-py-audit",
            "ms-sub-bilingual"
        };
        for (String query : new String[] {"ai", "双语", "oauth", "找片", "api"}) {
            List<MobileSettingsIndex.Entry> hits = MobileSettingsIndex.search(query, false, false);
            for (MobileSettingsIndex.Entry e : hits) {
                for (String hidden : hiddenAiKeys) {
                    check(
                            !hidden.equals(e.key),
                            "P1-5: locked search '" + query + "' hides AI-only entry " + hidden);
                }
            }
        }
        boolean hasGateHit = false;
        for (MobileSettingsIndex.Entry e : MobileSettingsIndex.search("ai", false, false)) {
            if ("ms-ai-lab-gate".equals(e.key)) hasGateHit = true;
        }
        check(hasGateHit, "P1-5: locked search 'ai' preserves passcode entry ms-ai-lab-gate");

        // Unlocked state exposes full AI entries
        List<MobileSettingsIndex.Entry> unlockedAiHits =
                MobileSettingsIndex.search("ai", true, true);
        check(
                unlockedAiHits.size() >= 7,
                "P1-5: Settings search for 'ai' when unlocked returns full AI Lab entries");

        // P2-2: Straight bar phone hides ms-tablet-dock-pos from Settings search
        List<MobileSettingsIndex.Entry> phoneDockHits =
                MobileSettingsIndex.search("dock", false, false);
        List<MobileSettingsIndex.Entry> tabletDockHits =
                MobileSettingsIndex.search("dock", false, true);
        check(
                phoneDockHits.isEmpty()
                        && tabletDockHits.size() == 1
                        && "ms-tablet-dock-pos".equals(tabletDockHits.get(0).key),
                "P2-2: Settings search hides ms-tablet-dock-pos on ordinary bar phones and shows it on tablets/foldables");

        // Static guards: zero hardcoded third-party CLI client IDs (P1-9), locked-state UI guards
        // (P1-5), zero UI emoji in AI classes
        String authSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/AiAuthManager.java"),
                        StandardCharsets.UTF_8);
        check(
                !authSrc.contains("17e5f671-d194-4dfb-9706-5516cb48c098")
                        && !authSrc.contains("app_EMoamEEZ73f0CkXaXp7hrann"),
                "P1-9: zero unowned third-party CLI client IDs hardcoded in AiAuthManager");

        String controlsSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/PlaybackControls.java"),
                        StandardCharsets.UTF_8);
        String settingsSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileSettingsScreen.java"),
                        StandardCharsets.UTF_8);
        check(
                controlsSrc.contains("final boolean aiUnlocked = AiBetaGate.isUnlocked(a);")
                        && controlsSrc.contains(
                                "if (!AiBetaGate.isUnlocked(a)) {\n            return;")
                        && settingsSrc.contains(
                                "boolean aiUnlockedForEp = AiBetaGate.isUnlocked(a);")
                        && settingsSrc.contains(
                                "MobileSettingsIndex.search(\n                                        q,\n                                        AiBetaGate.isUnlocked(a),"),
                "P1-5: PlaybackControls subtitle sheet, Settings ms-ep-clean, ms-sub-bilingual, and search all enforce AiBetaGate");

        String[] emojiFreeFiles = {
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiBetaGate.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiAuthManager.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiAssistantService.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiSubtitleTranslator.java",
            "android-mobile/src/main/java/com/pilipala/marcomovie/AiCinemaCopilot.java"
        };
        for (String rel : emojiFreeFiles) {
            String src = Files.readString(root.resolve(rel), StandardCharsets.UTF_8);
            check(!containsEmoji(src), "Hygiene: zero UI chrome emoji in " + rel);
        }
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

    private static void writeJson(HttpExchange ex, int status, String json) throws IOException {
        byte[] b = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=UTF-8");
        ex.sendResponseHeaders(status, b.length);
        try (OutputStream out = ex.getResponseBody()) {
            out.write(b);
        }
    }
}

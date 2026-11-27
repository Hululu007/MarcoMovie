package com.pilipala.marcomovie;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.File;
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

        // 5. P1-1: Manual Base URL origin change immediately clears/reloads key in ByokFormState
        //    (save/test on new origin NEVER carries prefilled old key; switching back reloads old)
        MemoryOAuthStore authSt = new MemoryOAuthStore();
        AiAuthManager.ByokFormState form = new AiAuthManager.ByokFormState(sec, "deepseek", "");
        check(
                fakeDeepSeekKey.equals(form.keyText)
                        && "https://api.deepseek.com".equals(form.boundOrigin),
                "P1-1: ByokFormState initially loads bound DeepSeek key");
        boolean changedToNewOrigin = form.onBaseUrlChanged(sec, "https://other-gateway.example/v1");
        check(
                changedToNewOrigin
                        && form.keyText.isEmpty()
                        && "https://other-gateway.example".equals(form.boundOrigin),
                "P1-1: editing Base URL to new origin immediately clears prefilled old key");
        form.commitToStore(sec, authSt);
        check(
                AiAuthManager.loadScopedApiKey(sec, "deepseek", "https://other-gateway.example/v1")
                                .isEmpty()
                        && fakeDeepSeekKey.equals(
                                AiAuthManager.loadScopedApiKey(
                                        sec, "deepseek", "https://api.deepseek.com/v1")),
                "P1-1: saving after changing Base URL NEVER writes old key to new origin and preserves original gateway key");
        form.onKeyEdited("sk-fake-new-gateway-5544");
        form.commitToStore(sec, authSt);
        boolean switchedBack = form.onBaseUrlChanged(sec, "");
        check(
                switchedBack && fakeDeepSeekKey.equals(form.keyText),
                "P1-1: switching Base URL back to original gateway immediately reloads original bound key");

        // 6. P2-6: Legacy unbound key upgrade notice & automatic cleanup upon re-entry
        MemoryOAuthStore upgradeSec = new MemoryOAuthStore();
        upgradeSec.putString(Prefs.SECRET_AI_API_KEY, "sk-legacy-unbound-072");
        AiAuthManager.ByokFormState upgradeForm =
                new AiAuthManager.ByokFormState(upgradeSec, "deepseek", "");
        boolean legacyErrClear = false;
        try {
            AiAuthManager.resolveByokRequest(upgradeSec, "deepseek", "", "");
        } catch (IOException expected) {
            legacyErrClear = expected.getMessage().contains("旧版未绑定");
        }
        check(
                AiAuthManager.hasLegacyUnboundApiKey(upgradeSec)
                        && upgradeForm.needsLegacyReentryNotice(upgradeSec)
                        && upgradeForm.keyText.isEmpty()
                        && legacyErrClear,
                "P2-6: legacy unbound key triggers explicit upgrade re-entry prompt and is never auto-sent");
        upgradeForm.onKeyEdited("sk-reentered-scoped-073");
        upgradeForm.commitToStore(upgradeSec, authSt);
        check(
                !AiAuthManager.hasLegacyUnboundApiKey(upgradeSec)
                        && !upgradeForm.needsLegacyReentryNotice(upgradeSec),
                "P2-6: saving scoped key clears legacy unbound key and dismisses upgrade prompt");

        // 7. P1-1: Real HttpURLConnection redirect test — 302/307 MUST NOT follow to another origin
        //    so Android 6 never forwards native auth headers
        // (Authorization/x-api-key/x-goog-api-key)
        final AtomicInteger redirectTargetHits = new AtomicInteger(0);
        HttpServer targetSrv =
                HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        targetSrv.createContext(
                "/capture",
                ex -> {
                    redirectTargetHits.incrementAndGet();
                    writeJson(ex, 200, "{\"leaked\":true}");
                });
        targetSrv.start();
        HttpServer redirectSrv =
                HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        final String targetUrl =
                "http://127.0.0.1:" + targetSrv.getAddress().getPort() + "/capture";
        redirectSrv.createContext(
                "/v1/chat/completions",
                ex -> {
                    ex.getResponseHeaders().set("Location", targetUrl);
                    ex.sendResponseHeaders(302, -1);
                    ex.close();
                });
        redirectSrv.start();
        try {
            String redirUrl =
                    "http://127.0.0.1:"
                            + redirectSrv.getAddress().getPort()
                            + "/v1/chat/completions";
            Map<String, String> fakeAuthHdrs = new HashMap<>();
            fakeAuthHdrs.put("Authorization", "Bearer sk-fake-redirect-guard");
            fakeAuthHdrs.put("x-api-key", "sk-ant-redirect-guard");
            fakeAuthHdrs.put("x-goog-api-key", "AIzaSyRedirectGuard12345");
            boolean redirBlocked = false;
            try {
                AiAuthManager.postRawDirect(
                        redirUrl, "application/json; charset=UTF-8", "{}", fakeAuthHdrs);
            } catch (IOException expected) {
                redirBlocked = expected.getMessage().contains("重定向");
            }
            check(
                    redirBlocked && redirectTargetHits.get() == 0,
                    "P1-1: postRawDirect disables auto-redirects and rejects 302 with 0 hits to redirect target");
        } finally {
            redirectSrv.stop(0);
            targetSrv.stop(0);
        }

        // 8. Keyless local Ollama over HTTP MUST succeed cleanly with ZERO Authorization header
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
                    "P1-1/P1-2: keyless local Ollama HTTP works end-to-end with zero Authorization header");
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

        // 7. P1-2: Closing/cancelling login sheet discards in-flight success and leaves active mode
        //    and prior credentials completely untouched
        MemoryOAuthStore st2 = new MemoryOAuthStore();
        AiAuthManager.setAuthMode(st2, AiAuthManager.AUTH_MODE_API_KEY);
        AiAuthManager.OAuthAttemptToken cancelAttempt =
                AiAuthManager.beginOAuthAttempt(st2, AiAuthManager.OAUTH_OPENROUTER);
        AiAuthManager.cancelOAuthAttempt(st2, cancelAttempt);
        AiAuthManager.OAuthBundle lateSuccess = new AiAuthManager.OAuthBundle();
        lateSuccess.providerId = AiAuthManager.OAUTH_OPENROUTER;
        lateSuccess.accessToken = "sk-or-late-after-cancel";
        boolean committedAfterCancel =
                AiAuthManager.completeOAuthSignInAtomically(
                        st2, cancelAttempt, lateSuccess, () -> true);
        check(
                !committedAfterCancel
                        && AiAuthManager.loadBundle(st2, AiAuthManager.OAUTH_OPENROUTER) == null
                        && AiAuthManager.AUTH_MODE_API_KEY.equals(AiAuthManager.authMode(st2)),
                "P1-2: cancelling OAuth login sheet discards in-flight success without overwriting active mode");

        // 8. P1-2: Switching to BYOK while OAuth is in flight discards late OAuth success
        AiAuthManager.OAuthAttemptToken byokRaceAttempt =
                AiAuthManager.beginOAuthAttempt(st2, AiAuthManager.OAUTH_OPENROUTER);
        AiAuthManager.setAuthMode(st2, AiAuthManager.AUTH_MODE_API_KEY);
        boolean committedAfterByok =
                AiAuthManager.completeOAuthSignInAtomically(
                        st2, byokRaceAttempt, lateSuccess, () -> true);
        check(
                !committedAfterByok
                        && AiAuthManager.loadBundle(st2, AiAuthManager.OAUTH_OPENROUTER) == null
                        && AiAuthManager.AUTH_MODE_API_KEY.equals(AiAuthManager.authMode(st2)),
                "P1-2: switching to BYOK while OAuth is in flight discards late OAuth success and keeps BYOK active");

        // 9. P1-2: Switching to another OAuth provider discards in-flight previous provider success
        AiAuthManager.OAuthAttemptToken provRaceAttempt =
                AiAuthManager.beginOAuthAttempt(st2, AiAuthManager.OAUTH_KIMI_CODE);
        AiAuthManager.setAuthMode(st2, AiAuthManager.AUTH_MODE_OAUTH);
        AiAuthManager.setActiveOAuthProvider(st2, AiAuthManager.OAUTH_OPENROUTER);
        AiAuthManager.OAuthBundle lateKimi = new AiAuthManager.OAuthBundle();
        lateKimi.providerId = AiAuthManager.OAUTH_KIMI_CODE;
        lateKimi.accessToken = "late-kimi-at";
        boolean committedAfterProvSwitch =
                AiAuthManager.completeOAuthSignInAtomically(
                        st2, provRaceAttempt, lateKimi, () -> true);
        check(
                !committedAfterProvSwitch
                        && AiAuthManager.loadBundle(st2, AiAuthManager.OAUTH_KIMI_CODE) == null
                        && AiAuthManager.OAUTH_OPENROUTER.equals(
                                AiAuthManager.activeOAuthProvider(st2)),
                "P1-2: switching OAuth provider while prior sign-in is in flight discards stale response and preserves final choice");

        // 10. P1-2: Per-provider Client ID isolation across Kimi <-> OpenAI <-> OpenRouter switches
        AiAuthManager.OAuthProviderSwitchState switchState =
                new AiAuthManager.OAuthProviderSwitchState(st2, AiAuthManager.OAUTH_KIMI_CODE);
        switchState.onClientIdTyped("kimi-client-id-111");
        String loadedForOpenAi =
                switchState.switchTo(
                        st2, AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL, "kimi-client-id-111");
        check(
                loadedForOpenAi.isEmpty()
                        && "kimi-client-id-111"
                                .equals(
                                        AiAuthManager.oauthClientId(
                                                st2, AiAuthManager.OAUTH_KIMI_CODE))
                        && AiAuthManager.oauthClientId(st2, AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL)
                                .isEmpty(),
                "P1-2: switching from Kimi to OpenAI saves Kimi Client ID strictly to Kimi and never writes it to OpenAI");
        switchState.onClientIdTyped("openai-client-id-222");
        String loadedBackKimi =
                switchState.switchTo(st2, AiAuthManager.OAUTH_KIMI_CODE, "openai-client-id-222");
        String loadedOpenRouter =
                switchState.switchTo(st2, AiAuthManager.OAUTH_OPENROUTER, loadedBackKimi);
        check(
                "kimi-client-id-111".equals(loadedBackKimi)
                        && loadedOpenRouter.isEmpty()
                        && "openai-client-id-222"
                                .equals(
                                        AiAuthManager.oauthClientId(
                                                st2, AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL))
                        && AiAuthManager.oauthClientId(st2, AiAuthManager.OAUTH_OPENROUTER)
                                .isEmpty(),
                "P1-2: Kimi and OpenAI Client IDs remain independently persisted across repeated switches");

        // 11. P1-2: Same-provider concurrent refresh mutex allows only 1 network refresh call
        long verMutex = AiAuthManager.beginOAuthSession(oauthStore, prov);
        AiAuthManager.commitOAuthSignInIfCurrent(oauthStore, prov, verMutex, expiring, () -> true);
        AtomicInteger refreshNetCalls = new AtomicInteger(0);
        CountDownLatch t1Entered = new CountDownLatch(1);
        CountDownLatch allowRefreshFinish = new CountDownLatch(1);
        AiAuthManager.HttpTransport mutexTx =
                (u, ct, b, h) -> {
                    refreshNetCalls.incrementAndGet();
                    t1Entered.countDown();
                    try {
                        allowRefreshFinish.await(3, TimeUnit.SECONDS);
                    } catch (InterruptedException ignored) {
                    }
                    return new AiAuthManager.HttpResult(
                            200,
                            "{\"access_token\":\"mutex-fresh-at\",\"refresh_token\":\"mutex-fresh-rt\",\"expires_in\":7200}");
                };
        AtomicReference<String> res1 = new AtomicReference<>("");
        AtomicReference<String> res2 = new AtomicReference<>("");
        Thread rt1 =
                new Thread(
                        () -> {
                            try {
                                res1.set(
                                        AiAuthManager.ensureFreshOAuthBundle(
                                                        oauthStore,
                                                        prov,
                                                        "https://auth.kimi.com/api/oauth/token",
                                                        "kimi-client-id-111",
                                                        2000L,
                                                        () -> true,
                                                        mutexTx)
                                                .accessToken);
                            } catch (IOException ignored) {
                            }
                        });
        Thread rt2 =
                new Thread(
                        () -> {
                            try {
                                res2.set(
                                        AiAuthManager.ensureFreshOAuthBundle(
                                                        oauthStore,
                                                        prov,
                                                        "https://auth.kimi.com/api/oauth/token",
                                                        "kimi-client-id-111",
                                                        2000L,
                                                        () -> true,
                                                        mutexTx)
                                                .accessToken);
                            } catch (IOException ignored) {
                            }
                        });
        rt1.start();
        check(t1Entered.await(3, TimeUnit.SECONDS), "P1-2: concurrent refresh #1 entered lock");
        rt2.start();
        Thread.sleep(80L);
        allowRefreshFinish.countDown();
        rt1.join(3000L);
        rt2.join(3000L);
        check(
                refreshNetCalls.get() == 1
                        && "mutex-fresh-at".equals(res1.get())
                        && "mutex-fresh-at".equals(res2.get()),
                "P1-2: same-provider refresh mutex deduplicates concurrent token refreshes into 1 network call");

        // 12. Round-4 P1-3: OpenRouter immediate close cancellation ("点击关闭 -> 换码成功 -> 动画结束")
        //     MUST NOT save account or enable AI; programmatic close after normal login success
        //     still persists account & enables AI cleanly!
        MemoryOAuthStore stClose = new MemoryOAuthStore();
        AiAuthManager.setAuthMode(stClose, AiAuthManager.AUTH_MODE_API_KEY);
        AtomicBoolean serverClosed = new AtomicBoolean(false);
        AtomicBoolean aiEnabledFlag = new AtomicBoolean(false);
        AiAuthManager.OAuthAttemptToken openRouterCloseAttempt =
                AiAuthManager.beginOAuthAttempt(stClose, AiAuthManager.OAUTH_OPENROUTER);
        AiAuthManager.OAuthSheetCancellationCoordinator closeCoord =
                new AiAuthManager.OAuthSheetCancellationCoordinator(
                        stClose, openRouterCloseAttempt, () -> serverClosed.set(true));
        // Step 1: User taps Close/backdrop/Back BEFORE exit animation finishes
        closeCoord.onUserCloseInitiated();
        // Step 2: In-flight token exchange succeeds during the exit animation window
        AiAuthManager.OAuthBundle lateOrBundle = new AiAuthManager.OAuthBundle();
        lateOrBundle.providerId = AiAuthManager.OAUTH_OPENROUTER;
        lateOrBundle.accessToken = "sk-or-v1-late-during-close-anim";
        boolean committedDuringCloseAnim =
                closeCoord.commitSuccessAtomically(
                        lateOrBundle, () -> true, () -> aiEnabledFlag.set(true));
        // Step 3: Exit animation ends
        closeCoord.onDialogDismissAnimationFinished();
        check(
                !committedDuringCloseAnim
                        && serverClosed.get()
                        && !aiEnabledFlag.get()
                        && AiAuthManager.loadBundle(stClose, AiAuthManager.OAUTH_OPENROUTER) == null
                        && AiAuthManager.AUTH_MODE_API_KEY.equals(AiAuthManager.authMode(stClose)),
                "R4 P1-3: OpenRouter click-close -> late code exchange -> anim-end writes 0 account and never enables AI");

        // Normal login success -> programmatic dismiss -> animation end keeps account & enables AI
        AtomicBoolean normalServerClosed = new AtomicBoolean(false);
        AtomicBoolean normalAiEnabled = new AtomicBoolean(false);
        AiAuthManager.OAuthAttemptToken normalOrAttempt =
                AiAuthManager.beginOAuthAttempt(stClose, AiAuthManager.OAUTH_OPENROUTER);
        AiAuthManager.OAuthSheetCancellationCoordinator normalCoord =
                new AiAuthManager.OAuthSheetCancellationCoordinator(
                        stClose, normalOrAttempt, () -> normalServerClosed.set(true));
        AiAuthManager.OAuthBundle okOrBundle = new AiAuthManager.OAuthBundle();
        okOrBundle.providerId = AiAuthManager.OAUTH_OPENROUTER;
        okOrBundle.accessToken = "sk-or-v1-normal-ok";
        boolean normalCommitted =
                normalCoord.commitSuccessAtomically(
                        okOrBundle, () -> true, () -> normalAiEnabled.set(true));
        normalCoord.onDialogDismissAnimationFinished();
        AiAuthManager.OAuthBundle savedOkOr =
                AiAuthManager.loadBundle(stClose, AiAuthManager.OAUTH_OPENROUTER);
        check(
                normalCommitted
                        && normalCoord.isProgrammaticSuccess()
                        && normalAiEnabled.get()
                        && normalServerClosed.get()
                        && savedOkOr != null
                        && "sk-or-v1-normal-ok".equals(savedOkOr.accessToken)
                        && AiAuthManager.AUTH_MODE_OAUTH.equals(AiAuthManager.authMode(stClose)),
                "R4 P1-3: OpenRouter normal login -> programmatic dismiss persists account and enables AI");

        // 13. Round-4 P2-3: OpenRouter foreground wait returns false cleanly on cancel / timeout
        //     and matches 15s waiting prompt constant
        AiAuthManager.notifyActivityBackgrounded();
        AtomicBoolean waitCancel = new AtomicBoolean(true);
        boolean fgWhenCancelled = AiAuthManager.awaitForeground(2_000L, waitCancel);
        boolean fgWhenTimeout = AiAuthManager.awaitForeground(40L, new AtomicBoolean(false));
        AiAuthManager.notifyActivityResumed();
        boolean fgWhenActive = AiAuthManager.awaitForeground(50L, new AtomicBoolean(false));
        check(
                AiAuthManager.OPENROUTER_FOREGROUND_WAIT_MS == 15_000L
                        && !fgWhenCancelled
                        && !fgWhenTimeout
                        && fgWhenActive,
                "R4 P2-3: OpenRouter foreground wait honors 15s timeout constant, cancellation, and active foreground");
    }

    private static String makeUnsignedJwt(String payloadJson) {
        String hdr =
                AiAuthManager.base64UrlEncode(
                        "{\"alg\":\"none\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));
        String pay = AiAuthManager.base64UrlEncode(payloadJson.getBytes(StandardCharsets.UTF_8));
        return hdr + "." + pay + ".sig";
    }

    private static void test4_ModelsSubscriptionInferenceAndLogRedaction() throws Exception {
        // 1. P1-3: Active 2026 default models (Gemini updated off deprecated 2.5-flash for new
        //    accounts -> gemini-3.5-flash-lite)
        check(
                "deepseek-flash".equals(AiAssistantService.defaultModel("deepseek"))
                        && "claude-haiku-5-5".equals(AiAssistantService.defaultModel("anthropic"))
                        && "gemini-3.5-flash-lite"
                                .equals(AiAssistantService.defaultModel("gemini")),
                "P1-3: default models use deepseek-flash, claude-haiku-5-5, and new-account-ready gemini-3.5-flash-lite");

        // 2. P1-3: Shipped 0.7.3 OAuth UI withdraws unverified experimental subscription paths
        check(
                AiAuthManager.SHIPPED_OAUTH_PROVIDER_IDS.length == 1
                        && AiAuthManager.OAUTH_OPENROUTER.equals(
                                AiAuthManager.SHIPPED_OAUTH_PROVIDER_IDS[0])
                        && AiAuthManager.isShippedOAuthProvider(AiAuthManager.OAUTH_OPENROUTER)
                        && !AiAuthManager.isShippedOAuthProvider(AiAuthManager.OAUTH_KIMI_CODE)
                        && !AiAuthManager.isShippedOAuthProvider(
                                AiAuthManager.OAUTH_OPENAI_EXPERIMENTAL),
                "P1-3: 0.7.3 shipped OAuth UI keeps only OpenRouter PKCE and withdraws unverified experimental subscription paths");

        // 3. P1-3: OpenAI OAuth identity & actual granted scope verification contract
        String validIdJwt = makeUnsignedJwt("{\"sub\":\"usr_123\",\"email\":\"dev@example.com\"}");
        String validAccessJwt =
                makeUnsignedJwt(
                        "{\"sub\":\"usr_123\",\"scope\":\"openid profile email resource.invoke chatgpt.tokens.use.direct\"}");
        AiAuthManager.OAuthBundle verifiedOa =
                AiAuthManager.exchangeOpenAiCode(
                        AiAuthManager.OPENAI_TOKEN_URL,
                        "app_user_registered_demo",
                        "auth_code_1",
                        "verifier_1234567890",
                        "http://localhost:1455/auth/callback",
                        1_700_000_000_000L,
                        (u, ct, body, hdrs) ->
                                new AiAuthManager.HttpResult(
                                        200,
                                        "{\"access_token\":\""
                                                + validAccessJwt
                                                + "\",\"id_token\":\""
                                                + validIdJwt
                                                + "\",\"scope\":\"openid profile email resource.invoke chatgpt.tokens.use.direct\",\"expires_in\":3600}"));
        boolean missingScopeRejected = false;
        try {
            AiAuthManager.exchangeOpenAiCode(
                    AiAuthManager.OPENAI_TOKEN_URL,
                    "app_user_registered_demo",
                    "auth_code_2",
                    "verifier_1234567890",
                    "http://localhost:1455/auth/callback",
                    1_700_000_000_000L,
                    (u, ct, body, hdrs) ->
                            new AiAuthManager.HttpResult(
                                    200,
                                    "{\"access_token\":\"opaque_no_scope\",\"id_token\":\""
                                            + validIdJwt
                                            + "\",\"scope\":\"openid profile email\",\"expires_in\":3600}"));
        } catch (IOException expected) {
            missingScopeRejected = expected.getMessage().contains("授权范围");
        }
        boolean missingIdentityRejected = false;
        try {
            AiAuthManager.exchangeOpenAiCode(
                    AiAuthManager.OPENAI_TOKEN_URL,
                    "app_user_registered_demo",
                    "auth_code_3",
                    "verifier_1234567890",
                    "http://localhost:1455/auth/callback",
                    1_700_000_000_000L,
                    (u, ct, body, hdrs) ->
                            new AiAuthManager.HttpResult(
                                    200,
                                    "{\"access_token\":\"opaque_no_sub\",\"scope\":\"resource.invoke chatgpt.tokens.use.direct\",\"expires_in\":3600}"));
        } catch (IOException expected) {
            missingIdentityRejected = expected.getMessage().contains("身份");
        }
        check(
                "dev@example.com".equals(verifiedOa.accountLabel)
                        && missingScopeRejected
                        && missingIdentityRejected,
                "P1-3: OpenAI OAuth verifies both user identity and actual granted inference scopes");

        // 4. P1-3: OpenAI Responses API SSE contract (completed, failed, incomplete, mid-stream
        // EOF)
        final AtomicReference<String> respUrl = new AtomicReference<>("");
        final AtomicReference<String> respBody = new AtomicReference<>("");
        final AtomicReference<String> respAccept = new AtomicReference<>("");
        final AtomicReference<String> respAcctHdr = new AtomicReference<>("");
        String sseCompleted =
                "event: response.output_text.delta\n"
                        + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"连接\"}\n\n"
                        + "event: response.output_text.delta\n"
                        + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"正常-SSE\"}\n\n"
                        + "event: response.completed\n"
                        + "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n";
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
                            respAccept.set(hdrs.getOrDefault("Accept", ""));
                            respAcctHdr.set(hdrs.getOrDefault("ChatGPT-Account-Id", ""));
                            return new AiAuthManager.HttpResult(200, sseCompleted);
                        });
        JSONObject oaSent = new JSONObject(respBody.get());
        boolean sseFailedCaught = false;
        try {
            AiAuthManager.parseOpenAiResponsesSse(
                    "event: response.failed\n"
                            + "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"quota exceeded\"}}}\n\n",
                    "oa-plan-access-token");
        } catch (IOException expected) {
            sseFailedCaught = expected.getMessage().contains("失败");
        }
        boolean sseIncompleteCaught = false;
        try {
            AiAuthManager.parseOpenAiResponsesSse(
                    "event: response.output_text.delta\n"
                            + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"半截\"}\n\n"
                            + "event: response.incomplete\n"
                            + "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n",
                    "oa-plan-access-token");
        } catch (IOException expected) {
            sseIncompleteCaught = expected.getMessage().contains("未完成");
        }
        boolean sseTruncatedCaught = false;
        try {
            AiAuthManager.parseOpenAiResponsesSse(
                    "event: response.output_text.delta\n"
                            + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"断流前\"}\n\n",
                    "oa-plan-access-token");
        } catch (IOException expected) {
            sseTruncatedCaught = expected.getMessage().contains("中断");
        }
        check(
                "连接正常-SSE".equals(oaRespReply)
                        && "https://api.openai.com/v1/responses".equals(respUrl.get())
                        && oaSent.optBoolean("stream", false)
                        && "text/event-stream".equals(respAccept.get())
                        && "sys-instructions".equals(oaSent.optString("instructions"))
                        && "acct_plus_99".equals(respAcctHdr.get())
                        && sseFailedCaught
                        && sseIncompleteCaught
                        && sseTruncatedCaught,
                "P1-3: OpenAI Responses SSE handles stream=true, delta+completed, failed, incomplete, and truncated EOF");

        // 5. P1-3: Anthropic Haiku 5.5 omits unsupported sampling params (temperature/top_p/top_k)
        //    AND Gemini uses new-account default model gemini-3.5-flash-lite with x-goog-api-key
        final AtomicReference<String> antKeyHdr = new AtomicReference<>("");
        final AtomicReference<String> antBody = new AtomicReference<>("");
        final AtomicReference<String> gemUrl = new AtomicReference<>("");
        final AtomicReference<String> gemKeyHdr = new AtomicReference<>("");
        String claudeReply =
                AiAuthManager.executeChatCompletion(
                        new AiAuthManager.ResolvedRequest(
                                AiAuthManager.WIRE_ANTHROPIC,
                                "https://api.anthropic.com",
                                AiAssistantService.defaultModel("anthropic"),
                                "sk-ant-valid-mock-123456",
                                "",
                                ""),
                        "sys",
                        "hi",
                        64,
                        0.2,
                        (u, ct, body, hdrs) -> {
                            antKeyHdr.set(hdrs.getOrDefault("x-api-key", ""));
                            antBody.set(body);
                            return new AiAuthManager.HttpResult(
                                    200,
                                    "{\"content\":[{\"type\":\"text\",\"text\":\"连接正常-Claude55\"}]}");
                        });
        JSONObject antSent = new JSONObject(antBody.get());
        String geminiReply =
                AiAuthManager.executeChatCompletion(
                        new AiAuthManager.ResolvedRequest(
                                AiAuthManager.WIRE_GEMINI,
                                "https://generativelanguage.googleapis.com",
                                AiAssistantService.defaultModel("gemini"),
                                "AIzaSyValidMockKey12345678",
                                "",
                                ""),
                        "sys",
                        "hi",
                        64,
                        0.2,
                        (u, ct, body, hdrs) -> {
                            gemUrl.set(u);
                            gemKeyHdr.set(hdrs.getOrDefault("x-goog-api-key", ""));
                            return new AiAuthManager.HttpResult(
                                    200,
                                    "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"连接正常-Gemini35\"}]}}]}");
                        });
        check(
                "连接正常-Claude55".equals(claudeReply)
                        && "claude-haiku-5-5".equals(antSent.optString("model"))
                        && !antSent.has("temperature")
                        && !antSent.has("top_p")
                        && !antSent.has("top_k")
                        && "sk-ant-valid-mock-123456".equals(antKeyHdr.get())
                        && "连接正常-Gemini35".equals(geminiReply)
                        && gemUrl.get().contains("/models/gemini-3.5-flash-lite:generateContent")
                        && "AIzaSyValidMockKey12345678".equals(gemKeyHdr.get()),
                "P1-3: Haiku 5.5 omits temperature/top_p/top_k; Gemini targets gemini-3.5-flash-lite with x-goog-api-key");

        // 6. P1-4 / P2-6: Log, cause chain, short custom key, JSON native auth headers & diagnostic
        //    export redaction
        AppLog.clear();
        AppLog.clearRegisteredSecrets();
        String markerSk = "sk-INVALIDTESTMARKER99887766";
        String markerGem = "AIzaSyINVALIDTESTMARKER998877";
        String markerCustom = "CUSTOM_NATIVE_KEY_77665544";
        String shortCustomKey = "k9x8";
        String jsonAntHeaderVal = "JSON_XAPI_SECRET_5544";
        String jsonGemHeaderVal = "JSON_GOOG_SECRET_6633";

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
                                            + " headers {\\\"x-api-key\\\":\\\""
                                            + jsonAntHeaderVal
                                            + "\\\"}\"}}"));
        } catch (IOException e) {
            caughtAnt = e;
        }
        AppLog.w("AiAssistant", "Anthropic test failed with x-api-key: " + markerCustom, caughtAnt);

        // Short custom key echoed in upstream error + nested exception cause chain + JSON headers
        IOException caughtShort = null;
        try {
            AiAuthManager.executeChatCompletion(
                    new AiAuthManager.ResolvedRequest(
                            AiAuthManager.WIRE_OPENAI_COMPAT,
                            "https://custom-relay.example/v1",
                            "gpt-4o-mini",
                            shortCustomKey,
                            "",
                            ""),
                    "sys",
                    "hi",
                    32,
                    0.2,
                    (u, ct, body, hdrs) ->
                            new AiAuthManager.HttpResult(
                                    401,
                                    "{\"error\":{\"message\":\"Bad custom key "
                                            + shortCustomKey
                                            + " with {\"x-goog-api-key\":\""
                                            + jsonGemHeaderVal
                                            + "\"}\"}}"));
        } catch (IOException e) {
            caughtShort = e;
        }
        Throwable deepRootCause =
                new IllegalStateException(
                        "root echoed "
                                + shortCustomKey
                                + " and {\"x-api-key\":\""
                                + jsonAntHeaderVal
                                + "\",\"x-goog-api-key\":\""
                                + jsonGemHeaderVal
                                + "\"}");
        IOException wrappedCauseEx =
                new IOException(
                        "outer wrapper " + markerGem, new RuntimeException("mid", deepRootCause));
        AppLog.w("AiAssistant", "Nested diagnostic failure", wrappedCauseEx);

        String dump = AppLog.dump();
        String crashStack = CrashReportStore.formatStackTrace(wrappedCauseEx);
        String crashRecentLogs = CrashReportStore.collectSanitizedAppLogs(50);
        String combinedDiag = dump + "\n" + crashStack + "\n" + crashRecentLogs;
        check(
                caughtAnt != null
                        && caughtShort != null
                        && !caughtAnt.getMessage().contains(markerSk)
                        && !caughtAnt.getMessage().contains(jsonAntHeaderVal)
                        && !caughtShort.getMessage().contains(shortCustomKey)
                        && !caughtShort.getMessage().contains(jsonGemHeaderVal)
                        && !combinedDiag.contains(markerSk)
                        && !combinedDiag.contains(markerGem)
                        && !combinedDiag.contains(markerCustom)
                        && !combinedDiag.contains(shortCustomKey)
                        && !combinedDiag.contains(jsonAntHeaderVal)
                        && !combinedDiag.contains(jsonGemHeaderVal),
                "P2-6: short custom key, JSON native auth headers (raw & escaped), nested exception causes, AppLog.dump & CrashReportStore diagnostic export are all 0-leak");

        // 7. Round-4 P2-4: 1-char & 2-char custom API keys (still allowed as custom input) MUST
        //    be redacted in ordinary error bodies AND CrashReportStore diagnostic exports without
        //    corrupting unrelated words!
        AppLog.clear();
        AppLog.clearRegisteredSecrets();
        String key1Char = "q";
        String key2Char = "k9";
        IOException caught1 = null;
        try {
            AiAuthManager.executeChatCompletion(
                    new AiAuthManager.ResolvedRequest(
                            AiAuthManager.WIRE_OPENAI_COMPAT,
                            "https://relay.example/v1",
                            "gpt-4o-mini",
                            key1Char,
                            "",
                            ""),
                    "sys",
                    "hi",
                    32,
                    0.2,
                    (u, ct, body, hdrs) ->
                            new AiAuthManager.HttpResult(
                                    401,
                                    "{\"error\":{\"message\":\"Request quota rejected bare key: q\"}}"));
        } catch (IOException e) {
            caught1 = e;
        }
        IOException caught2 = null;
        try {
            AiAuthManager.executeChatCompletion(
                    new AiAuthManager.ResolvedRequest(
                            AiAuthManager.WIRE_OPENAI_COMPAT,
                            "https://relay.example/v1",
                            "gpt-4o-mini",
                            key2Char,
                            "",
                            ""),
                    "sys",
                    "hi",
                    32,
                    0.2,
                    (u, ct, body, hdrs) ->
                            new AiAuthManager.HttpResult(
                                    500, "upstream failed with token k9 on request"));
        } catch (IOException e) {
            caught2 = e;
        }
        AppLog.w("AiAssistant", "1-char fail", caught1);
        AppLog.w("AiAssistant", "2-char fail", caught2);
        String diag12 =
                AppLog.dump()
                        + "\n"
                        + CrashReportStore.formatStackTrace(caught1)
                        + "\n"
                        + CrashReportStore.formatStackTrace(caught2)
                        + "\n"
                        + CrashReportStore.collectSanitizedAppLogs(50);
        check(
                caught1 != null
                        && caught2 != null
                        && !caught1.getMessage().contains("bare key: q")
                        && caught1.getMessage().contains("quota")
                        && caught1.getMessage().contains("[REDACTED_KEY]")
                        && !caught2.getMessage().contains("token k9 ")
                        && caught2.getMessage().contains("[REDACTED_KEY]")
                        && !diag12.contains("bare key: q")
                        && !diag12.contains("token k9 ")
                        && diag12.contains("[REDACTED_KEY]"),
                "R4 P2-4: 1-char & 2-char custom keys are redacted in ordinary error bodies and CrashReportStore diagnostic exports without mangling words");
        AppLog.clearRegisteredSecrets();
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

        // 5. P2-5: Versioned completion cache rejects legacy 2-cue SRT where only 1 cue was
        //    translated (same cue count == 2!) AND accepts only verified v2 complete caches
        String legacyHalfTranslatedTwoCueSrt =
                "1\n00:00:01,000 --> 00:00:04,000\n第一句译文\nLine 1\n\n"
                        + "2\n00:00:05,000 --> 00:00:08,000\nLine 2\n\n";
        check(
                AiSubtitleTranslator.parseSrt(legacyHalfTranslatedTwoCueSrt).size() == 2
                        && AiSubtitleTranslator.decodeVerifiedCompletionCache(
                                        legacyHalfTranslatedTwoCueSrt, 2, true)
                                == null,
                "P2-5: legacy unmarked 2-cue half-translated SRT cache is rejected (never falsely reported complete)");
        String partialV2Envelope =
                "{\"cache_version\":2,\"complete\":false,\"bilingual\":true,\"total_cues\":2,\"translated_cues\":1,\"srt\":"
                        + JSONObject.quote(legacyHalfTranslatedTwoCueSrt)
                        + "}";
        String completeTwoCueSrt =
                "1\n00:00:01,000 --> 00:00:04,000\n第一句译文\nLine 1\n\n"
                        + "2\n00:00:05,000 --> 00:00:08,000\n第二句译文\nLine 2\n\n";
        String validV2Envelope =
                AiSubtitleTranslator.encodeCompletionCache(completeTwoCueSrt, 2, 2, true);
        String decodedV2 =
                AiSubtitleTranslator.decodeVerifiedCompletionCache(validV2Envelope, 2, true);
        List<AiSubtitleTranslator.SrtCue> cachedTwoCues = AiSubtitleTranslator.parseSrt(decodedV2);
        String cachedOverlayLine =
                AiSubtitleTranslator.activeCueTextAt(cachedTwoCues, null, 2000L, true);
        check(
                AiSubtitleTranslator.decodeVerifiedCompletionCache(partialV2Envelope, 2, true)
                                == null
                        && AiSubtitleTranslator.encodeCompletionCache(completeTwoCueSrt, 1, 2, true)
                                == null
                        && completeTwoCueSrt.equals(decodedV2)
                        && AiSubtitleTranslator.decodeVerifiedCompletionCache(
                                        validV2Envelope, 2, false)
                                == null
                        && "第一句译文\nLine 1".equals(cachedOverlayLine),
                "P2-5: v2 completion cache enforces version+complete+mode+count invariants and preserves bilingual line breaks");

        // 6. P1-4: All three engines (Media3, MPV, SystemPlayer) verified for BOTH first
        //    progressive translation AND cache-hit re-entry (visible, switchable, 0 dupes, 0
        //    progressive prepare())
        // 6a. Media3 engine
        final JSONObject media3Opts = new JSONObject();
        final AtomicBoolean media3OverlayVisible = new AtomicBoolean(false);
        final AtomicInteger media3PrepareCount = new AtomicInteger(0);
        AiSubtitleTranslator.SubtitleMountTarget media3Target =
                new AiSubtitleTranslator.SubtitleMountTarget() {
                    @Override
                    public void setLiveOverlay(
                            List<AiSubtitleTranslator.SrtCue> c, String[] t, boolean bi) {
                        media3OverlayVisible.set(true);
                    }

                    @Override
                    public void clearLiveOverlay() {
                        media3OverlayVisible.set(false);
                    }

                    @Override
                    public boolean upsertExternalSubtitle(
                            String uri,
                            String name,
                            String mime,
                            boolean reload,
                            Runnable onMounted)
                            throws Exception {
                        MoviePlayer.upsertSubtitleTrackJson(media3Opts, uri, name, mime);
                        if (reload) {
                            media3PrepareCount.incrementAndGet();
                            if (onMounted != null) onMounted.run();
                            return true;
                        }
                        return false;
                    }
                };
        // First progressive updates on Media3: 0 prepare, overlay stays visible, 1 track
        AiSubtitleTranslator.applySubtitleMountSafely(
                media3Target,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                new String[] {"第一句译文", null},
                true,
                false);
        AiSubtitleTranslator.applySubtitleMountSafely(
                media3Target,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                new String[] {"第一句译文", "第二句译文"},
                true,
                false);
        boolean media3ProgOk =
                media3OverlayVisible.get()
                        && media3PrepareCount.get() == 0
                        && media3Opts.getJSONArray("subtitles").length() == 1;
        // Cache hit re-entry on Media3: mounts single track, clears overlay ONLY after mount
        AiSubtitleTranslator.applySubtitleMountSafely(
                media3Target,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                null,
                true,
                true);
        check(
                media3ProgOk
                        && !media3OverlayVisible.get()
                        && media3PrepareCount.get() == 1
                        && media3Opts.getJSONArray("subtitles").length() == 1,
                "P1-4: Media3 progressive (0 prepare, overlay visible, 1 track) + cache-hit re-entry verified");

        // 6b. MPV engine (deduplicates via sub-remove + sub-add, 0 prepare on both progressive &
        //     cache hit)
        final List<JSONObject> mpvTrackTable = new ArrayList<>();
        mpvTrackTable.add(
                new JSONObject()
                        .put("id", 1)
                        .put("type", "sub")
                        .put("external", false)
                        .put("title", "English"));
        final AtomicBoolean mpvOverlayVisible = new AtomicBoolean(false);
        final AtomicInteger mpvNextId = new AtomicInteger(2);
        AiSubtitleTranslator.SubtitleMountTarget mpvTarget =
                new AiSubtitleTranslator.SubtitleMountTarget() {
                    @Override
                    public void setLiveOverlay(
                            List<AiSubtitleTranslator.SrtCue> c, String[] t, boolean bi) {
                        mpvOverlayVisible.set(true);
                    }

                    @Override
                    public void clearLiveOverlay() {
                        mpvOverlayVisible.set(false);
                    }

                    @Override
                    public boolean upsertExternalSubtitle(
                            String uri,
                            String name,
                            String mime,
                            boolean reload,
                            Runnable onMounted)
                            throws Exception {
                        List<String[]> cmds =
                                MpvPlayer.planExternalSubtitleUpsertCommands(
                                        mpvTrackTable, uri, name);
                        for (String[] cmd : cmds) {
                            if ("sub-remove".equals(cmd[0])) {
                                int rmId = Integer.parseInt(cmd[1]);
                                mpvTrackTable.removeIf(t -> t.optInt("id", -1) == rmId);
                            } else if ("sub-add".equals(cmd[0])) {
                                mpvTrackTable.add(
                                        new JSONObject()
                                                .put("id", mpvNextId.getAndIncrement())
                                                .put("type", "sub")
                                                .put("external", true)
                                                .put("external-filename", cmd[1])
                                                .put("title", cmd[3]));
                            }
                        }
                        if (onMounted != null) onMounted.run();
                        return true;
                    }
                };
        // First progressive + second update + cache-hit re-entry on MPV -> always 1 AI track + 1
        // embedded English track = 2 total, 0 duplicates!
        AiSubtitleTranslator.applySubtitleMountSafely(
                mpvTarget,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                null,
                true,
                false);
        AiSubtitleTranslator.applySubtitleMountSafely(
                mpvTarget,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                null,
                true,
                true);
        int mpvAiCount = 0;
        for (JSONObject t : mpvTrackTable) {
            if (AiSubtitleTranslator.AI_TRACK_NAME.equals(t.optString("title"))) mpvAiCount++;
        }
        check(
                mpvAiCount == 1 && mpvTrackTable.size() == 2 && !mpvOverlayVisible.get(),
                "P1-4: MPV progressive + cache-hit re-entry keeps strictly 1 AI track with 0 prepare()");

        // 6c. SystemPlayer engine (progressive keeps overlay + 0 addTimedTextSource; cache hit
        //     replaces prior AI track via filterVisibleTrackIndices and keeps overlay visible until
        //     onMounted OR if addTimedTextSource fails!)
        final List<Integer> sysRawTrackIndices = new ArrayList<>();
        sysRawTrackIndices.add(0); // embedded track 0
        final java.util.Set<Integer> sysReplaced = new java.util.HashSet<>();
        final AtomicInteger sysActiveAiIdx = new AtomicInteger(-1);
        final AtomicInteger sysAddCalls = new AtomicInteger(0);
        final AtomicBoolean sysOverlayVisible = new AtomicBoolean(false);
        final AtomicBoolean sysSimulateFailure = new AtomicBoolean(false);
        final AtomicReference<Runnable> sysDeferredMount = new AtomicReference<>(null);
        AiSubtitleTranslator.SubtitleMountTarget sysTarget =
                new AiSubtitleTranslator.SubtitleMountTarget() {
                    @Override
                    public void setLiveOverlay(
                            List<AiSubtitleTranslator.SrtCue> c, String[] t, boolean bi) {
                        sysOverlayVisible.set(true);
                    }

                    @Override
                    public void clearLiveOverlay() {
                        sysOverlayVisible.set(false);
                    }

                    @Override
                    public boolean upsertExternalSubtitle(
                            String uri,
                            String name,
                            String mime,
                            boolean reload,
                            Runnable onMounted)
                            throws Exception {
                        if (!reload) return false;
                        if (sysSimulateFailure.get()) {
                            throw new IllegalStateException(
                                    "simulated ROM addTimedTextSource failure");
                        }
                        if (sysActiveAiIdx.get() >= 0) {
                            sysReplaced.add(sysActiveAiIdx.get());
                        }
                        int nextIdx = sysRawTrackIndices.size();
                        sysRawTrackIndices.add(nextIdx);
                        sysActiveAiIdx.set(nextIdx);
                        sysAddCalls.incrementAndGet();
                        sysDeferredMount.set(onMounted);
                        return false;
                    }
                };
        // Progressive on SystemPlayer -> 0 addTimedTextSource, overlay stays visible
        AiSubtitleTranslator.applySubtitleMountSafely(
                sysTarget,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                null,
                true,
                false);
        boolean sysProgOk = sysAddCalls.get() == 0 && sysOverlayVisible.get();
        // Cache hit #1 on SystemPlayer -> overlay stays visible until async onMounted completes
        AiSubtitleTranslator.applySubtitleMountSafely(
                sysTarget,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                null,
                true,
                true);
        boolean sysVisibleBeforeCallback = sysOverlayVisible.get() && sysAddCalls.get() == 1;
        sysDeferredMount.get().run();
        boolean sysClearedAfterCallback = !sysOverlayVisible.get();
        // Cache hit #2 replaces prior AI track index -> still strictly 2 visible tracks (1 embedded
        // + 1 AI)
        AiSubtitleTranslator.applySubtitleMountSafely(
                sysTarget,
                "file:///sub/ep1.srt",
                "application/x-subrip",
                cachedTwoCues,
                null,
                true,
                true);
        sysDeferredMount.get().run();
        List<Integer> visibleSysTracks =
                SystemPlayer.filterVisibleTrackIndices(sysRawTrackIndices, sysReplaced);
        // Error resilience: if mount throws, overlay MUST stay visible (never cleared!)
        sysSimulateFailure.set(true);
        boolean mountOkOnFail =
                AiSubtitleTranslator.applySubtitleMountSafely(
                        sysTarget,
                        "file:///sub/ep1.srt",
                        "application/x-subrip",
                        cachedTwoCues,
                        null,
                        true,
                        true);
        check(
                sysProgOk
                        && sysVisibleBeforeCallback
                        && sysClearedAfterCallback
                        && visibleSysTracks.size() == 2
                        && !mountOkOnFail
                        && sysOverlayVisible.get(),
                "P1-4: SystemPlayer progressive + cache-hit re-entry + dedupe + error-fallback overlay visibility verified");

        // 7. Round-4 P1-4: User turning off subtitles or switching tracks cancels active
        //    background AI translation so late chunks & deferred mounts NEVER overwrite user
        // choice;
        //    AND Media3 waits for exact target AI track selection even when another pre-existing
        //    external subtitle is already selected!
        long sid = AiSubtitleTranslator.beginActiveTranslationSession();
        AiSubtitleTranslator.ActivityCheck sidActive =
                () -> AiSubtitleTranslator.isTranslationSessionActive(sid);
        final AtomicInteger lateOverlayWrites = new AtomicInteger(0);
        final AtomicInteger lateOverlayClears = new AtomicInteger(0);
        final AtomicInteger lateUpserts = new AtomicInteger(0);
        final AtomicReference<Runnable> inFlightMountCb = new AtomicReference<>(null);
        AiSubtitleTranslator.SubtitleMountTarget cancelProbeTarget =
                new AiSubtitleTranslator.SubtitleMountTarget() {
                    @Override
                    public void setLiveOverlay(
                            List<AiSubtitleTranslator.SrtCue> c, String[] t, boolean bi) {
                        lateOverlayWrites.incrementAndGet();
                    }

                    @Override
                    public void clearLiveOverlay() {
                        lateOverlayClears.incrementAndGet();
                    }

                    @Override
                    public boolean upsertExternalSubtitle(
                            String uri,
                            String name,
                            String mime,
                            boolean reload,
                            Runnable onMounted) {
                        lateUpserts.incrementAndGet();
                        inFlightMountCb.set(onMounted);
                        return false;
                    }
                };
        // Initial chunk mounts while active
        boolean firstMounted =
                AiSubtitleTranslator.applySubtitleMountSafely(
                        cancelProbeTarget,
                        "file:///sub/ep1.srt",
                        "application/x-subrip",
                        cachedTwoCues,
                        new String[] {"第一句译文", null},
                        true,
                        true,
                        sidActive);
        // User turns off subtitles OR switches to embedded English track
        AiSubtitleTranslator.cancelActiveTranslation();
        // Late chunk arrives after cancel -> MUST be completely ignored!
        boolean lateMounted =
                AiSubtitleTranslator.applySubtitleMountSafely(
                        cancelProbeTarget,
                        "file:///sub/ep1.srt",
                        "application/x-subrip",
                        cachedTwoCues,
                        new String[] {"第一句译文", "第二句译文"},
                        true,
                        false,
                        sidActive);
        // Earlier in-flight async mount callback finishes after cancel -> MUST NOT clear overlay!
        if (inFlightMountCb.get() != null) inFlightMountCb.get().run();
        check(
                firstMounted
                        && !lateMounted
                        && lateOverlayWrites.get() == 1
                        && lateUpserts.get() == 1
                        && lateOverlayClears.get() == 0,
                "R4 P1-4: cancelling AI translation on subtitle-off/track-switch blocks late chunks and stale mount callbacks");

        // Media3 state machine with pre-existing external subtitle selected:
        final AtomicBoolean m3OverlayAlive = new AtomicBoolean(true);
        MoviePlayer.PendingSubtitleMount pm =
                new MoviePlayer.PendingSubtitleMount(
                        "marco_ai_sub_2",
                        AiSubtitleTranslator.AI_TRACK_NAME,
                        () -> m3OverlayAlive.set(false));
        // Update 1: pre-existing other external subtitle is selected, target AI track is NOT yet
        // selected -> MUST return SELECT_TARGET and KEEP overlay alive!
        List<MoviePlayer.SubtitleTrackProbe> probesOtherSelected =
                Arrays.asList(
                        new MoviePlayer.SubtitleTrackProbe(
                                0, 0, "marco_ext_sub_1", "外挂英文字幕", true, true),
                        new MoviePlayer.SubtitleTrackProbe(
                                1,
                                0,
                                "marco_ai_sub_2",
                                AiSubtitleTranslator.AI_TRACK_NAME,
                                true,
                                false));
        MoviePlayer.MountReconcileResult rec1 =
                MoviePlayer.reconcilePendingSubtitleMount(pm, probesOtherSelected);
        boolean stayedAliveBeforeTargetSelected =
                rec1.decision == MoviePlayer.MountDecision.SELECT_TARGET
                        && rec1.groupIndex == 1
                        && rec1.trackIndex == 0
                        && !pm.completed
                        && m3OverlayAlive.get();
        // Update 2: Media3 confirms exact target AI track is now selected ->
        // CONFIRMED_CLEAR_OVERLAY
        List<MoviePlayer.SubtitleTrackProbe> probesAiSelected =
                Arrays.asList(
                        new MoviePlayer.SubtitleTrackProbe(
                                0, 0, "marco_ext_sub_1", "外挂英文字幕", true, false),
                        new MoviePlayer.SubtitleTrackProbe(
                                1,
                                0,
                                "marco_ai_sub_2",
                                AiSubtitleTranslator.AI_TRACK_NAME,
                                true,
                                true));
        MoviePlayer.MountReconcileResult rec2 =
                MoviePlayer.reconcilePendingSubtitleMount(pm, probesAiSelected);
        if (rec2.decision == MoviePlayer.MountDecision.CONFIRMED_CLEAR_OVERLAY
                && pm.onMounted != null) {
            pm.onMounted.run();
        }
        // Update 3: Cancelled pending mount never selects or clears
        MoviePlayer.PendingSubtitleMount cancelledPm =
                new MoviePlayer.PendingSubtitleMount(
                        "marco_ai_sub_3", AiSubtitleTranslator.AI_TRACK_NAME, () -> {});
        cancelledPm.cancelled = true;
        MoviePlayer.MountReconcileResult recCancelled =
                MoviePlayer.reconcilePendingSubtitleMount(cancelledPm, probesAiSelected);
        check(
                stayedAliveBeforeTargetSelected
                        && rec2.decision == MoviePlayer.MountDecision.CONFIRMED_CLEAR_OVERLAY
                        && pm.completed
                        && !m3OverlayAlive.get()
                        && recCancelled.decision == MoviePlayer.MountDecision.WAIT,
                "R4 P1-4: Media3 keeps overlay when another external track is selected and clears ONLY once target AI track is confirmed selected");

        // 7b. Round-5 P1-5: Media3 MUST NOT mistake an older same-label track (ID 1) for the new
        //     target track (ID 2)! Old same-label selected -> WAIT; new target appears unselected
        //     -> SELECT_TARGET (overlay stays); new target confirmed selected -> clears STRICTLY
        //     ONCE even across repeated onTracksChanged!
        final AtomicInteger r5ClearCalls = new AtomicInteger(0);
        MoviePlayer.PendingSubtitleMount pmNew2 =
                new MoviePlayer.PendingSubtitleMount(
                        "marco_ai_sub_2",
                        AiSubtitleTranslator.AI_TRACK_NAME,
                        r5ClearCalls::incrementAndGet);
        List<MoviePlayer.SubtitleTrackProbe> onlyOldSameLabelSelected =
                Arrays.asList(
                        new MoviePlayer.SubtitleTrackProbe(
                                0,
                                0,
                                "marco_ai_sub_1",
                                AiSubtitleTranslator.AI_TRACK_NAME,
                                true,
                                true));
        MoviePlayer.MountReconcileResult r5Step1 =
                MoviePlayer.reconcilePendingSubtitleMount(pmNew2, onlyOldSameLabelSelected);
        boolean completedAfterStep1 = pmNew2.completed;
        List<MoviePlayer.SubtitleTrackProbe> bothSameLabelNewUnselected =
                Arrays.asList(
                        new MoviePlayer.SubtitleTrackProbe(
                                0,
                                0,
                                "marco_ai_sub_1",
                                AiSubtitleTranslator.AI_TRACK_NAME,
                                true,
                                true),
                        new MoviePlayer.SubtitleTrackProbe(
                                1,
                                0,
                                "marco_ai_sub_2",
                                AiSubtitleTranslator.AI_TRACK_NAME,
                                true,
                                false));
        MoviePlayer.MountReconcileResult r5Step2 =
                MoviePlayer.reconcilePendingSubtitleMount(pmNew2, bothSameLabelNewUnselected);
        boolean completedAfterStep2 = pmNew2.completed;
        List<MoviePlayer.SubtitleTrackProbe> bothSameLabelNewSelected =
                Arrays.asList(
                        new MoviePlayer.SubtitleTrackProbe(
                                0,
                                0,
                                "marco_ai_sub_1",
                                AiSubtitleTranslator.AI_TRACK_NAME,
                                true,
                                false),
                        new MoviePlayer.SubtitleTrackProbe(
                                1,
                                0,
                                "marco_ai_sub_2",
                                AiSubtitleTranslator.AI_TRACK_NAME,
                                true,
                                true));
        MoviePlayer.MountReconcileResult r5Step3 =
                MoviePlayer.reconcilePendingSubtitleMount(pmNew2, bothSameLabelNewSelected);
        if (r5Step3.decision == MoviePlayer.MountDecision.CONFIRMED_CLEAR_OVERLAY
                && pmNew2.onMounted != null) {
            pmNew2.onMounted.run();
        }
        MoviePlayer.MountReconcileResult r5Step4Repeat =
                MoviePlayer.reconcilePendingSubtitleMount(pmNew2, bothSameLabelNewSelected);
        if (r5Step4Repeat.decision == MoviePlayer.MountDecision.CONFIRMED_CLEAR_OVERLAY
                && pmNew2.onMounted != null) {
            pmNew2.onMounted.run();
        }
        check(
                r5Step1.decision == MoviePlayer.MountDecision.WAIT
                        && !completedAfterStep1
                        && r5Step2.decision == MoviePlayer.MountDecision.SELECT_TARGET
                        && !completedAfterStep2
                        && r5Step2.groupIndex == 1
                        && r5Step2.trackIndex == 0
                        && r5Step3.decision == MoviePlayer.MountDecision.CONFIRMED_CLEAR_OVERLAY
                        && pmNew2.completed
                        && r5Step4Repeat.decision == MoviePlayer.MountDecision.WAIT
                        && r5ClearCalls.get() == 1,
                "R5 P1-5: Media3 ignores stale same-label track (ID 1), waits for ID 2 selection, and clears overlay strictly once");

        // 7c. Round-5 P1-4: Online subtitle selection bound at tap time — delayed download followed
        //     by (1) subtitle-off, (2) track-switch, (3) episode-switch, or (4) player-exit yields
        //     0 model calls, 0 overlay writes, and 0 mounts!
        String[] cancelModes = {"subtitle_off", "track_switch", "episode_switch", "exit_player"};
        for (String mode : cancelModes) {
            final AtomicBoolean exiting = new AtomicBoolean(false);
            final AtomicInteger gen = new AtomicInteger(10);
            final AtomicReference<String> epId = new AtomicReference<>("demo|v1|line1|第1集|u1");
            OnlineSubtitleDanmakuService.PlaybackStateProbe probe =
                    new OnlineSubtitleDanmakuService.PlaybackStateProbe() {
                        @Override
                        public boolean isExiting() {
                            return exiting.get();
                        }

                        @Override
                        public int currentGeneration() {
                            return gen.get();
                        }

                        @Override
                        public String currentEpisodeIdentity() {
                            return epId.get();
                        }
                    };
            OnlineSubtitleDanmakuService.SubtitleSelectionToken tok =
                    OnlineSubtitleDanmakuService.beginSubtitleSelection(gen.get(), epId.get());
            final AtomicInteger modelCalls = new AtomicInteger(0);
            final AtomicInteger overlayWrites = new AtomicInteger(0);
            final AtomicInteger mountCalls = new AtomicInteger(0);
            boolean delivered =
                    OnlineSubtitleDanmakuService.completeSubtitleSelectionAfterDownload(
                            tok,
                            probe,
                            true,
                            () -> {
                                // Simulate user action arriving while network download is in flight
                                if ("subtitle_off".equals(mode)) {
                                    AiSubtitleTranslator.cancelActiveTranslation();
                                } else if ("track_switch".equals(mode)) {
                                    OnlineSubtitleDanmakuService.beginSubtitleSelection(
                                            gen.get(), epId.get());
                                } else if ("episode_switch".equals(mode)) {
                                    gen.incrementAndGet();
                                    epId.set("demo|v1|line1|第2集|u2");
                                } else if ("exit_player".equals(mode)) {
                                    exiting.set(true);
                                }
                                return completeTwoCueSrt;
                            },
                            new OnlineSubtitleDanmakuService.SubtitleDeliverySink() {
                                @Override
                                public void runAiTranslation(
                                        String srt,
                                        OnlineSubtitleDanmakuService.SubtitleSelectionToken t) {
                                    modelCalls.incrementAndGet();
                                    overlayWrites.incrementAndGet();
                                    mountCalls.incrementAndGet();
                                }

                                @Override
                                public void mountPlainSubtitle(
                                        String srt,
                                        OnlineSubtitleDanmakuService.SubtitleSelectionToken t) {
                                    mountCalls.incrementAndGet();
                                }
                            });
            check(
                    !delivered
                            && modelCalls.get() == 0
                            && overlayWrites.get() == 0
                            && mountCalls.get() == 0,
                    "R5 P1-4: delayed online subtitle download aborted cleanly on "
                            + mode
                            + " (0 model/overlay/mount)");
        }

        // 7d. Round-6 P1-3: Selecting a source-provided track named "AI 中文字幕" OR even identically
        //     named "AI 全片双语字幕" MUST be distinguished by mounted engine track identity (never
        //     display label prefix) and MUST cancel in-flight online subtitle download / AI
        //     translation (0 model calls, 0 overlay writes, 0 mounts)!
        String mountedAppAiId = "marco_ai_sub_7";
        check(
                !MoviePlayer.isAppGeneratedAiTrackFormatId("sub-0", mountedAppAiId)
                        && !MoviePlayer.isAppGeneratedAiTrackFormatId(
                                "marco_ext_sub_8", mountedAppAiId)
                        && !MoviePlayer.isAppGeneratedAiTrackFormatId(mountedAppAiId, "")
                        && MoviePlayer.isAppGeneratedAiTrackFormatId(mountedAppAiId, mountedAppAiId)
                        && PlaybackControls.shouldCancelAiTranslationOnTrackSelect(0, false)
                        && PlaybackControls.shouldCancelAiTranslationOnTrackSelect(-2, true)
                        && !PlaybackControls.shouldCancelAiTranslationOnTrackSelect(2, true),
                "R6 P1-3A: Media3 track identity guard rejects source-provided 'AI ...' and external tracks even with identical title, matching ONLY mounted marco_ai_sub ID");

        JSONObject mpvEmbeddedAi =
                new JSONObject().put("id", 1).put("external", false).put("title", "AI 中文字幕");
        JSONObject mpvEmbeddedSameTitle =
                new JSONObject()
                        .put("id", 2)
                        .put("external", false)
                        .put("title", AiSubtitleTranslator.AI_TRACK_NAME);
        JSONObject mpvAppAi =
                new JSONObject()
                        .put("id", 9)
                        .put("external", true)
                        .put("title", AiSubtitleTranslator.AI_TRACK_NAME)
                        .put("external-filename", "file:///cache/ai_ep1.srt");
        List<String[]> mpvPlanWithEmbeddedAi =
                MpvPlayer.planExternalSubtitleUpsertCommands(
                        Arrays.asList(mpvEmbeddedAi, mpvEmbeddedSameTitle, mpvAppAi),
                        "file:///cache/ai_ep1_v2.srt",
                        AiSubtitleTranslator.AI_TRACK_NAME,
                        9,
                        "file:///cache/ai_ep1.srt",
                        true);
        boolean removedEmbedded1 = false;
        boolean removedEmbedded2 = false;
        boolean removedPriorApp9 = false;
        for (String[] c : mpvPlanWithEmbeddedAi) {
            if ("sub-remove".equals(c[0]) && "1".equals(c[1])) removedEmbedded1 = true;
            if ("sub-remove".equals(c[0]) && "2".equals(c[1])) removedEmbedded2 = true;
            if ("sub-remove".equals(c[0]) && "9".equals(c[1])) removedPriorApp9 = true;
        }
        check(
                !MpvPlayer.isAppGeneratedAiMpvTrack(mpvEmbeddedAi, 9, "file:///cache/ai_ep1.srt")
                        && !MpvPlayer.isAppGeneratedAiMpvTrack(
                                mpvEmbeddedSameTitle, 9, "file:///cache/ai_ep1.srt")
                        && MpvPlayer.isAppGeneratedAiMpvTrack(
                                mpvAppAi, 9, "file:///cache/ai_ep1.srt")
                        && !removedEmbedded1
                        && !removedEmbedded2
                        && removedPriorApp9,
                "R6 P1-3B: MPV identifies app AI track strictly by external SID/URI and preserves embedded source 'AI ...' tracks");

        // End-to-end delayed download + user selects source-provided "AI 中文字幕" / "AI 全片双语字幕"
        for (String sourceAiLabel : new String[] {"AI 中文字幕", AiSubtitleTranslator.AI_TRACK_NAME}) {
            final AtomicInteger r6Gen = new AtomicInteger(30);
            final String r6Ep = "demo|v9|line1|第1集|u9";
            OnlineSubtitleDanmakuService.PlaybackStateProbe r6Probe =
                    new OnlineSubtitleDanmakuService.PlaybackStateProbe() {
                        @Override
                        public boolean isExiting() {
                            return false;
                        }

                        @Override
                        public int currentGeneration() {
                            return r6Gen.get();
                        }

                        @Override
                        public String currentEpisodeIdentity() {
                            return r6Ep;
                        }
                    };
            OnlineSubtitleDanmakuService.SubtitleSelectionToken r6Tok =
                    OnlineSubtitleDanmakuService.beginSubtitleSelection(r6Gen.get(), r6Ep);
            final AtomicInteger r6Models = new AtomicInteger(0);
            final AtomicInteger r6Overlays = new AtomicInteger(0);
            final AtomicInteger r6Mounts = new AtomicInteger(0);
            boolean r6Delivered =
                    OnlineSubtitleDanmakuService.completeSubtitleSelectionAfterDownload(
                            r6Tok,
                            r6Probe,
                            true,
                            () -> {
                                // User taps source-embedded track whose label starts with "AI " or
                                // matches AI_TRACK_NAME; engine track identity check returns false!
                                boolean isAppAi =
                                        MoviePlayer.isAppGeneratedAiTrackFormatId(
                                                "source_embedded_0", mountedAppAiId);
                                if (PlaybackControls.shouldCancelAiTranslationOnTrackSelect(
                                        0, isAppAi)) {
                                    AiSubtitleTranslator.cancelActiveTranslation();
                                }
                                return completeTwoCueSrt;
                            },
                            new OnlineSubtitleDanmakuService.SubtitleDeliverySink() {
                                @Override
                                public void runAiTranslation(
                                        String srt,
                                        OnlineSubtitleDanmakuService.SubtitleSelectionToken t) {
                                    r6Models.incrementAndGet();
                                    r6Overlays.incrementAndGet();
                                    r6Mounts.incrementAndGet();
                                }

                                @Override
                                public void mountPlainSubtitle(
                                        String srt,
                                        OnlineSubtitleDanmakuService.SubtitleSelectionToken t) {
                                    r6Mounts.incrementAndGet();
                                }
                            });
            check(
                    !r6Delivered
                            && r6Models.get() == 0
                            && r6Overlays.get() == 0
                            && r6Mounts.get() == 0,
                    "R6 P1-3C: selecting source-provided '"
                            + sourceAiLabel
                            + "' cancels in-flight translation (0 model/overlay/mount)");
        }

        // 7e. Round-7 P2-1: Mounting a new app-generated AI subtitle track MUST preserve same-named
        //     embedded tracks, source-provided external tracks (no explicit id), and manually
        //     imported tracks (marco_ext_sub_*), replacing ONLY confirmed prior app-AI tracks!
        JSONObject r7Media3Opts = new JSONObject();
        org.json.JSONArray r7InitialSubs = new org.json.JSONArray();
        r7InitialSubs.put(
                new JSONObject()
                        .put("url", "https://src.example/sub/source_ai.srt")
                        .put("name", AiSubtitleTranslator.AI_TRACK_NAME)
                        .put("mimeType", "application/x-subrip"));
        r7InitialSubs.put(
                new JSONObject()
                        .put("id", "marco_ext_sub_1")
                        .put("url", "file:///sdcard/manual_ai.srt")
                        .put("name", AiSubtitleTranslator.AI_TRACK_NAME)
                        .put("mimeType", "application/x-subrip"));
        r7InitialSubs.put(
                new JSONObject()
                        .put("id", "marco_ai_sub_2")
                        .put("url", "file:///cache/app_ai_v1.srt")
                        .put("name", AiSubtitleTranslator.AI_TRACK_NAME)
                        .put("mimeType", "application/x-subrip"));
        r7Media3Opts.put("subtitles", r7InitialSubs);
        MoviePlayer.upsertSubtitleTrackJson(
                r7Media3Opts,
                "file:///cache/app_ai_v2.srt",
                AiSubtitleTranslator.AI_TRACK_NAME,
                "application/x-subrip",
                "marco_ai_sub_3");
        org.json.JSONArray r7AfterSubs = r7Media3Opts.getJSONArray("subtitles");
        check(
                r7AfterSubs.length() == 3
                        && "https://src.example/sub/source_ai.srt"
                                .equals(r7AfterSubs.getJSONObject(0).optString("url"))
                        && "marco_ext_sub_1".equals(r7AfterSubs.getJSONObject(1).optString("id"))
                        && "marco_ai_sub_3".equals(r7AfterSubs.getJSONObject(2).optString("id"))
                        && "file:///cache/app_ai_v2.srt"
                                .equals(r7AfterSubs.getJSONObject(2).optString("url")),
                "R7 P2-1A: Media3 upsertSubtitleTrackJson preserves same-named source external (no id) & manual tracks, replacing ONLY marco_ai_sub_*");

        JSONObject mpvSrcExtSameName =
                new JSONObject()
                        .put("id", 3)
                        .put("external", true)
                        .put("title", AiSubtitleTranslator.AI_TRACK_NAME)
                        .put("external-filename", "https://src.example/sub/source_ai.srt");
        JSONObject mpvManualExtSameName =
                new JSONObject()
                        .put("id", 4)
                        .put("external", true)
                        .put("title", AiSubtitleTranslator.AI_TRACK_NAME)
                        .put("external-filename", "file:///sdcard/manual_ai.srt");
        // Case 1: First app-AI mount (no prior app AI yet) -> ZERO sub-remove for
        // embedded/source/manual!
        List<String[]> mpvFirstMountPlan =
                MpvPlayer.planExternalSubtitleUpsertCommands(
                        Arrays.asList(
                                mpvEmbeddedSameTitle, mpvSrcExtSameName, mpvManualExtSameName),
                        "file:///cache/app_ai_v1.srt",
                        AiSubtitleTranslator.AI_TRACK_NAME,
                        -1,
                        "",
                        true);
        // Case 2: Updating prior app-AI track id=9 -> emits sub-remove ONLY for id=9!
        List<String[]> mpvUpdatePlan =
                MpvPlayer.planExternalSubtitleUpsertCommands(
                        Arrays.asList(
                                mpvEmbeddedSameTitle,
                                mpvSrcExtSameName,
                                mpvManualExtSameName,
                                mpvAppAi),
                        "file:///cache/app_ai_v2.srt",
                        AiSubtitleTranslator.AI_TRACK_NAME,
                        9,
                        "file:///cache/ai_ep1.srt",
                        true);
        boolean firstMountRemovedAny = false;
        for (String[] c : mpvFirstMountPlan) {
            if ("sub-remove".equals(c[0])) firstMountRemovedAny = true;
        }
        int updateRemoveCount = 0;
        boolean updateRemoved9 = false;
        for (String[] c : mpvUpdatePlan) {
            if ("sub-remove".equals(c[0])) {
                updateRemoveCount++;
                if ("9".equals(c[1])) updateRemoved9 = true;
            }
        }
        check(
                !firstMountRemovedAny && updateRemoveCount == 1 && updateRemoved9,
                "R7 P2-1B: MPV planExternalSubtitleUpsertCommands preserves embedded, source external & manual same-named tracks and removes ONLY confirmed prior app AI track");

        // 8. Round-4 P1-5: Unified 4 MiB subtitle completion disk cache write/read limit — verify
        //    742,995-byte complete full-episode sample hits disk cache on 2nd open with 0 model
        //    requests, oversize payload is symmetrically rejected, and legacy half-baked rejected!
        StringBuilder largeSrt = new StringBuilder(750_000);
        int largeCueCount = 0;
        while (largeSrt.toString().getBytes(StandardCharsets.UTF_8).length < 742_995) {
            largeCueCount++;
            long st = largeCueCount * 2000L;
            largeSrt.append(largeCueCount)
                    .append('\n')
                    .append(formatSrtTs(st))
                    .append(" --> ")
                    .append(formatSrtTs(st + 1800L))
                    .append('\n')
                    .append("第")
                    .append(largeCueCount)
                    .append("句完整双语译文内容用于验证七十四万字节全片字幕缓存读取一致性测试文本\n")
                    .append("Cue ")
                    .append(largeCueCount)
                    .append(
                            " full episode bilingual verification dialogue payload line for cache parity\n\n");
        }
        String largeSrtStr = largeSrt.toString();
        int largeSrtBytes = largeSrtStr.getBytes(StandardCharsets.UTF_8).length;
        String largeEnvelope =
                AiSubtitleTranslator.encodeCompletionCache(
                        largeSrtStr, largeCueCount, largeCueCount, true);
        int largeEnvelopeBytes =
                largeEnvelope == null ? 0 : largeEnvelope.getBytes(StandardCharsets.UTF_8).length;
        File tmpCacheDir = Files.createTempDirectory("marco-sub-cache-r4-").toFile();
        try {
            String cacheKey = AiSubtitleTranslator.COMPLETION_CACHE_PREFIX + "large_742k";
            boolean wroteLarge =
                    AiAssistantService.writeDiskCacheFile(tmpCacheDir, cacheKey, largeEnvelope);
            // Second open: read from disk cache -> decode -> 0 model calls!
            AtomicInteger secondOpenModelCalls = new AtomicInteger(0);
            String readBack = AiAssistantService.readDiskCacheFile(tmpCacheDir, cacheKey);
            String verifiedLarge =
                    AiSubtitleTranslator.decodeVerifiedCompletionCache(
                            readBack, largeCueCount, true);
            if (verifiedLarge == null) {
                secondOpenModelCalls.incrementAndGet();
            }
            List<AiSubtitleTranslator.SrtCue> parsedLarge =
                    AiSubtitleTranslator.parseSrt(verifiedLarge);
            String visibleFirstCue =
                    AiSubtitleTranslator.activeCueTextAt(parsedLarge, null, 2500L, true);

            // Oversize (> MAX_DISK_CACHE_BYTES = 4 MiB) symmetrically rejected on write & read
            StringBuilder tooBig =
                    new StringBuilder(AiAssistantService.MAX_DISK_CACHE_BYTES + 2048);
            while (tooBig.length() <= AiAssistantService.MAX_DISK_CACHE_BYTES + 128) {
                tooBig.append("0123456789abcdef");
            }
            boolean wroteOversize =
                    AiAssistantService.writeDiskCacheFile(
                            tmpCacheDir, "oversize_entry", tooBig.toString());
            // Also plant an oversized file directly on disk to verify read rejects > 4 MiB
            File plantedOversize = new File(tmpCacheDir, "planted_oversize.json");
            Files.writeString(plantedOversize.toPath(), tooBig.toString(), StandardCharsets.UTF_8);
            String readOversize =
                    AiAssistantService.readDiskCacheFile(tmpCacheDir, "planted_oversize");

            check(
                    largeSrtBytes >= 742_995
                            && largeEnvelopeBytes > 742_995
                            && wroteLarge
                            && verifiedLarge != null
                            && secondOpenModelCalls.get() == 0
                            && parsedLarge.size() == largeCueCount
                            && visibleFirstCue.contains("第1句完整双语译文")
                            && !wroteOversize
                            && !new File(tmpCacheDir, "oversize_entry.json").exists()
                            && readOversize == null,
                    "R4 P1-5: 742,995B+ full-episode cache roundtrips cleanly with 0 model calls on 2nd open; >4MiB rejected symmetrically");

            // 9. Round-5 P2-1: Concurrent atomic same-key AI disk cache replacement (4 writers x
            //    16 commits = 64 writes + concurrent readers + swap-failure old-value rollback!)
            final String raceKey = "r5_concurrent_atomic_key";
            final String seedPayload =
                    new JSONObject()
                            .put("writer", 0)
                            .put("seq", 0)
                            .put("body", "SEED_".repeat(512))
                            .toString();
            check(
                    AiAssistantService.writeDiskCacheFile(tmpCacheDir, raceKey, seedPayload),
                    "R5 P2-1: seeded initial atomic disk cache payload");

            final int numWriters = 4;
            final int commitsPerWriter = 16;
            final AtomicInteger writeSuccesses = new AtomicInteger(0);
            final AtomicInteger writeFailures = new AtomicInteger(0);
            final AtomicInteger corruptReads = new AtomicInteger(0);
            final AtomicInteger totalReads = new AtomicInteger(0);
            final AtomicBoolean stopReaders = new AtomicBoolean(false);
            final CountDownLatch startGate = new CountDownLatch(1);
            List<Thread> workers = new ArrayList<>();
            for (int w = 1; w <= numWriters; w++) {
                final int wid = w;
                Thread wt =
                        new Thread(
                                () -> {
                                    try {
                                        startGate.await(3, TimeUnit.SECONDS);
                                        for (int seq = 1; seq <= commitsPerWriter; seq++) {
                                            String tag = "W" + wid + "_S" + seq + "_";
                                            String payload =
                                                    new JSONObject()
                                                            .put("writer", wid)
                                                            .put("seq", seq)
                                                            .put("body", tag.repeat(600))
                                                            .toString();
                                            if (AiAssistantService.writeDiskCacheFile(
                                                    tmpCacheDir, raceKey, payload)) {
                                                writeSuccesses.incrementAndGet();
                                            } else {
                                                writeFailures.incrementAndGet();
                                            }
                                        }
                                    } catch (Exception e) {
                                        writeFailures.incrementAndGet();
                                    }
                                });
                workers.add(wt);
                wt.start();
            }
            List<Thread> readers = new ArrayList<>();
            for (int r = 0; r < 4; r++) {
                Thread rt =
                        new Thread(
                                () -> {
                                    try {
                                        startGate.await(3, TimeUnit.SECONDS);
                                    } catch (InterruptedException ignored) {
                                    }
                                    while (!stopReaders.get()) {
                                        String got =
                                                AiAssistantService.readDiskCacheFile(
                                                        tmpCacheDir, raceKey);
                                        totalReads.incrementAndGet();
                                        if (got == null || got.isEmpty()) {
                                            corruptReads.incrementAndGet();
                                            continue;
                                        }
                                        try {
                                            JSONObject obj = new JSONObject(got);
                                            int w = obj.getInt("writer");
                                            int seq = obj.getInt("seq");
                                            String body = obj.getString("body");
                                            String expected =
                                                    w == 0
                                                            ? "SEED_".repeat(512)
                                                            : ("W" + w + "_S" + seq + "_")
                                                                    .repeat(600);
                                            if (!expected.equals(body)) {
                                                corruptReads.incrementAndGet();
                                            }
                                        } catch (Exception ex) {
                                            corruptReads.incrementAndGet();
                                        }
                                    }
                                });
                readers.add(rt);
                rt.start();
            }
            startGate.countDown();
            for (Thread wt : workers) wt.join(15_000L);
            stopReaders.set(true);
            for (Thread rt : readers) rt.join(5_000L);

            String beforeFailedSwap = AiAssistantService.readDiskCacheFile(tmpCacheDir, raceKey);
            boolean failedSwapResult =
                    AiAssistantService.writeDiskCacheFile(
                            tmpCacheDir,
                            raceKey,
                            "{\"writer\":99,\"seq\":99,\"body\":\"BROKEN\"}",
                            (tmp, target) -> false);
            String afterFailedSwap = AiAssistantService.readDiskCacheFile(tmpCacheDir, raceKey);
            check(
                    writeSuccesses.get() == numWriters * commitsPerWriter
                            && writeFailures.get() == 0
                            && totalReads.get() > 0
                            && corruptReads.get() == 0
                            && !failedSwapResult
                            && beforeFailedSwap != null
                            && beforeFailedSwap.equals(afterFailedSwap),
                    "R5 P2-1: 4 writers x 16 commits (64/64) + concurrent readers observe 0 failures / 0 partial reads & failed swap preserves old value");
        } finally {
            File[] files = tmpCacheDir.listFiles();
            if (files != null) for (File f : files) f.delete();
            tmpCacheDir.delete();
        }
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

        // P2-1: Locked player button-order dialog hides "ai-sub" while preserving its relative slot
        //       so re-unlocking restores user preference; DetailScreen masks stored mode 2 -> 0
        //       while locked without erasing stored preference.
        List<String> lockedButtons =
                MobileSettingsScreen.visiblePlayerButtonOrderTokens(
                        Prefs.DEFAULT_PLAYER_BUTTON_ORDER, false);
        List<String> unlockedButtons =
                MobileSettingsScreen.visiblePlayerButtonOrderTokens(
                        Prefs.DEFAULT_PLAYER_BUTTON_ORDER, true);
        List<String> reorderedLocked = new ArrayList<>(lockedButtons);
        Collections.swap(reorderedLocked, 0, 1);
        String mergedOrder =
                MobileSettingsScreen.mergePlayerButtonOrderPreservingHidden(
                        Prefs.DEFAULT_PLAYER_BUTTON_ORDER, reorderedLocked, false);
        check(
                !lockedButtons.contains("ai-sub")
                        && unlockedButtons.contains("ai-sub")
                        && MobileSettingsScreen.visiblePlayerButtonOrderTokens(mergedOrder, true)
                                .contains("ai-sub")
                        && !MobileSettingsScreen.visiblePlayerButtonOrderTokens(mergedOrder, false)
                                .contains("ai-sub"),
                "P2-1: locked player button order hides ai-sub and preserves its slot for re-unlock recovery");

        check(
                MobileDetailScreen.effectiveEpisodeCleanMode(2, false) == 0
                        && "净化".equals(MobileDetailScreen.episodeCleanPillLabel(2, false))
                        && MobileDetailScreen.nextEpisodeCleanMode(2, false, false) == 1
                        && MobileDetailScreen.effectiveEpisodeCleanMode(2, true) == 2
                        && "AI净化".equals(MobileDetailScreen.episodeCleanPillLabel(2, true)),
                "P2-1: locked DetailScreen masks stored AI clean mode 2 -> local clean without erasing preference for re-unlock");

        check(
                "字幕 / 弹幕".equals(MobileSettingsScreen.buildSubtitleDanmuSummary(false, true, true))
                        && "字幕 / 关弹幕"
                                .equals(
                                        MobileSettingsScreen.buildSubtitleDanmuSummary(
                                                false, false, false))
                        && "双语 / 弹幕"
                                .equals(
                                        MobileSettingsScreen.buildSubtitleDanmuSummary(
                                                true, true, true))
                        && "单语 / 关弹幕"
                                .equals(
                                        MobileSettingsScreen.buildSubtitleDanmuSummary(
                                                true, false, false)),
                "P2-1: locked Settings root hides bilingual label (字幕 / 弹幕) and restores 双语/单语 once unlocked");

        // Static guards: zero hardcoded third-party CLI client IDs (P1-9), locked-state UI guards
        // (P1-5/P2-1), zero UI emoji in AI classes
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
        String mpvSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MpvPlayer.java"),
                        StandardCharsets.UTF_8);
        String sysPlayerSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/SystemPlayer.java"),
                        StandardCharsets.UTF_8);
        check(
                controlsSrc.contains("final boolean aiUnlocked = AiBetaGate.isUnlocked(a);")
                        && controlsSrc.contains(
                                "if (!AiBetaGate.isUnlocked(a)) {\n            return;")
                        && settingsSrc.contains(
                                "boolean aiUnlockedForEp = AiBetaGate.isUnlocked(a);")
                        && settingsSrc.contains(
                                "visiblePlayerButtonOrderTokens(savedRaw, aiUnlocked)")
                        && settingsSrc.contains(
                                "MobileSettingsIndex.search(\n                                        q,\n                                        AiBetaGate.isUnlocked(a),")
                        && mpvSrc.contains("public boolean upsertExternalSubtitle(")
                        && sysPlayerSrc.contains("public boolean upsertExternalSubtitle("),
                "P1-4/P1-5/P2-1: PlaybackControls, Settings button order, Detail clean, MPV & SystemPlayer overrides all wired");

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

        // Round-4 P1-7: Episode list render snapshots gate status ONCE per render pass (50 vs 200
        // episodes -> constant 1 Ed25519 verification each, never O(N)), while real AI request
        // initiation still re-verifies gate!
        List<Cms.Episode> eps50 = new ArrayList<>();
        for (int i = 1; i <= 50; i++) {
            Cms.Episode ep = new Cms.Episode();
            ep.name = "第" + i + "集.1080P.WEB-DL";
            eps50.add(ep);
        }
        List<Cms.Episode> eps200 = new ArrayList<>();
        for (int i = 1; i <= 200; i++) {
            Cms.Episode ep = new Cms.Episode();
            ep.name = "第" + i + "集.1080P.WEB-DL";
            eps200.add(ep);
        }
        byte[] probePub = new byte[32];
        String probeTok = "MMAILAB1.eyJ2IjoxfQ." + "A".repeat(86);
        long before50 = AiBetaGate.verifyCallCountForTest();
        List<MobileDetailScreen.EpisodeDisplay> disp50 =
                MobileDetailScreen.formatEpisodeDisplaysForRender(
                        eps50,
                        2,
                        () ->
                                AiBetaGate.verifyPasscode(
                                                probeTok,
                                                103,
                                                1_768_000_010_000L,
                                                probePub,
                                                AiBetaGate.PLATFORM_ANDROID)
                                        .ok);
        long calls50 = AiBetaGate.verifyCallCountForTest() - before50;
        long before200 = AiBetaGate.verifyCallCountForTest();
        List<MobileDetailScreen.EpisodeDisplay> disp200 =
                MobileDetailScreen.formatEpisodeDisplaysForRender(
                        eps200,
                        2,
                        () ->
                                AiBetaGate.verifyPasscode(
                                                probeTok,
                                                103,
                                                1_768_000_010_000L,
                                                probePub,
                                                AiBetaGate.PLATFORM_ANDROID)
                                        .ok);
        long calls200 = AiBetaGate.verifyCallCountForTest() - before200;
        // Real AI request still re-verifies gate every time!
        AtomicInteger realReqGateChecks = new AtomicInteger(0);
        MemoryOAuthStore reqStore = new MemoryOAuthStore();
        long reqVer = AiAuthManager.beginOAuthSession(reqStore, AiAuthManager.OAUTH_OPENROUTER);
        AiAuthManager.OAuthBundle reqBundle = new AiAuthManager.OAuthBundle();
        reqBundle.providerId = AiAuthManager.OAUTH_OPENROUTER;
        reqBundle.accessToken = "sk-or-reverify-123";
        AiAuthManager.commitOAuthSignInIfCurrent(
                reqStore,
                AiAuthManager.OAUTH_OPENROUTER,
                reqVer,
                reqBundle,
                () -> {
                    realReqGateChecks.incrementAndGet();
                    return true;
                });
        String detailSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileDetailScreen.java"),
                        StandardCharsets.UTF_8);
        check(
                disp50.size() == 50
                        && disp200.size() == 200
                        && calls50 == 1L
                        && calls200 == 1L
                        && realReqGateChecks.get() == 1
                        && authSrc.contains(
                                "if (!AiBetaGate.isUnlocked(a)) {\n            throw new IOException")
                        && detailSrc.contains(
                                "final boolean presentAiUnlocked = !a.isTvDevice() && AiBetaGate.isUnlocked(a);")
                        && detailSrc.contains(
                                "final boolean renderAiUnlocked = !a.isTvDevice() && AiBetaGate.isUnlocked(a);")
                        && detailSrc.contains(
                                "final boolean gridAiUnlocked = !a.isTvDevice() && AiBetaGate.isUnlocked(a);")
                        && detailSrc.contains("renderAiUnlocked, renderStoredCleanMode")
                        && detailSrc.contains("gridAiUnlocked, gridStoredCleanMode"),
                "R4 P1-7: 50 & 200 episodes each verify gate strictly once per render pass while real AI requests still re-verify");

        // Round-4 P2-3: Zero residual Kimi subscription claims in Auth Center UI & aligned
        // OpenRouter foreground waiting prompt + timeout handling
        String settingsIndexSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileSettingsIndex.java"),
                        StandardCharsets.UTF_8);
        String gateSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/AiBetaGate.java"),
                        StandardCharsets.UTF_8);
        String copilotSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/AiCinemaCopilot.java"),
                        StandardCharsets.UTF_8);
        String sheetSrc =
                Files.readString(
                        root.resolve(
                                "android-mobile/src/main/java/com/pilipala/marcomovie/MobileBottomSheet.java"),
                        StandardCharsets.UTF_8);
        check(
                !settingsSrc.contains("OpenRouter / Kimi Code")
                        && !settingsSrc.contains("Kimi Code 订阅")
                        && !settingsSrc.contains("登录订阅账号")
                        && !settingsIndexSrc.contains("订阅账号")
                        && !gateSrc.contains("订阅账号")
                        && !controlsSrc.contains("登录订阅账号")
                        && !copilotSrc.contains("登录订阅账号")
                        && authSrc.contains("OPENROUTER_FOREGROUND_WAIT_MS / 1000L")
                        && authSrc.contains("秒内返回应用前台以完成密钥换取")
                        && authSrc.contains("等待返回应用前台超时（")
                        && authSrc.contains("setOnUserDismissInitiated")
                        && sheetSrc.contains("dismissByUser()"),
                "R4 P2-3/P1-3 static: zero residual Kimi/subscription claims in Auth Center UI, 15s foreground wait prompt aligned, MobileBottomSheet immediate user-dismiss wired");
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

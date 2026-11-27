package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * App-private netdisk credential, account-identity, and drive-order store.
 *
 * <p>Persists exclusively inside app-private {@link Prefs#SECRETS_FILE} (encrypted via {@link
 * SecureStorage} when AndroidKeyStore is available, falling back cleanly to private
 * SharedPreferences without ever requesting or requiring external storage permissions).
 *
 * <p>Never mutates {@link Prefs#KEYS} so cross-device backup schema invariants stay intact.
 */
final class NetdiskStore {
    static final String DRIVE_QUARK = "quark";
    static final String DRIVE_UC = "uc";
    static final String DRIVE_BAIDU = "baidu";
    static final String DRIVE_ALI = "ali";

    static final List<String> DEFAULT_ORDER =
            Collections.unmodifiableList(
                    Arrays.asList(DRIVE_QUARK, DRIVE_UC, DRIVE_BAIDU, DRIVE_ALI));

    private static final String KEY_CRED_PREFIX = "netdisk_cred_";
    private static final String KEY_CRED_ENC_PREFIX = "netdisk_cred_enc_";
    private static final String KEY_ACCOUNT_ID_PREFIX = "netdisk_account_id_";
    private static final String KEY_OWNER_ID_PREFIX = "netdisk_owner_id_";
    private static final String KEY_VERIFIED_COOKIES_PREFIX = "netdisk_verified_cookies_";
    private static final String KEY_VERIFIED_AT_PREFIX = "netdisk_verified_at_";
    private static final String KEY_ORDER = "netdisk_drive_order";

    private static final AtomicLong REVISION = new AtomicLong(1L);
    private static final CopyOnWriteArrayList<Runnable> LISTENERS = new CopyOnWriteArrayList<>();

    interface KeyValueStore {
        String getString(String key, String defValue);

        void putString(String key, String value);

        void remove(String key);
    }

    static final class MemoryStore implements KeyValueStore {
        private final Map<String, String> map = new HashMap<>();

        @Override
        public synchronized String getString(String key, String defValue) {
            String val = map.get(key);
            return val != null ? val : defValue;
        }

        @Override
        public synchronized void putString(String key, String value) {
            if (value == null) {
                map.remove(key);
            } else {
                map.put(key, value);
            }
        }

        @Override
        public synchronized void remove(String key) {
            map.remove(key);
        }
    }

    private static final class SharedPrefsStore implements KeyValueStore {
        private final SharedPreferences prefs;

        SharedPrefsStore(SharedPreferences prefs) {
            this.prefs = prefs;
        }

        @Override
        public String getString(String key, String defValue) {
            return prefs.getString(key, defValue);
        }

        @Override
        public void putString(String key, String value) {
            prefs.edit().putString(key, value).apply();
        }

        @Override
        public void remove(String key) {
            prefs.edit().remove(key).apply();
        }
    }

    private NetdiskStore() {}

    static long revision() {
        return REVISION.get();
    }

    static void addListener(Runnable listener) {
        if (listener != null) LISTENERS.addIfAbsent(listener);
    }

    static void removeListener(Runnable listener) {
        if (listener != null) LISTENERS.remove(listener);
    }

    private static void notifyChanged() {
        REVISION.incrementAndGet();
        for (Runnable r : LISTENERS) {
            try {
                r.run();
            } catch (Throwable ignored) {
            }
        }
    }

    static KeyValueStore storeFor(Context context) {
        if (context == null) return new MemoryStore();
        SharedPreferences sp =
                context.getApplicationContext()
                        .getSharedPreferences(Prefs.SECRETS_FILE, Context.MODE_PRIVATE);
        return new SharedPrefsStore(sp);
    }

    static String normalizeDriveKey(String raw) {
        if (raw == null) return "";
        String k = raw.trim().toLowerCase(Locale.ROOT);
        if ("quark".equals(k)
                || "quarkcookie".equals(k)
                || "quark_cookie".equals(k)
                || "quarkck".equals(k)
                || "qkcookie".equals(k)
                || "kuake".equals(k)
                || "夸父".equals(k)
                || "夸克".equals(k)) {
            return DRIVE_QUARK;
        }
        if ("uc".equals(k)
                || "uccookie".equals(k)
                || "uc_cookie".equals(k)
                || "ucpancookie".equals(k)
                || "ucck".equals(k)
                || "优汐".equals(k)) {
            return DRIVE_UC;
        }
        if ("baidu".equals(k)
                || "baiducookie".equals(k)
                || "baidu_cookie".equals(k)
                || "baidupan".equals(k)
                || "bdcookie".equals(k)
                || "嘟嘟".equals(k)
                || "百度".equals(k)) {
            return DRIVE_BAIDU;
        }
        if ("ali".equals(k)
                || "alipan".equals(k)
                || "aliyun".equals(k)
                || "alitoken".equals(k)
                || "ali_token".equals(k)
                || "aliyuntoken".equals(k)
                || "aliyun_token".equals(k)
                || "refresh_token".equals(k)
                || "阿狸".equals(k)
                || "阿里".equals(k)) {
            return DRIVE_ALI;
        }
        return "";
    }

    static String displayName(String driveKey) {
        String k = normalizeDriveKey(driveKey);
        if (DRIVE_QUARK.equals(k)) return "夸克网盘";
        if (DRIVE_UC.equals(k)) return "UC网盘";
        if (DRIVE_BAIDU.equals(k)) return "百度网盘";
        if (DRIVE_ALI.equals(k)) return "阿里云盘";
        return driveKey == null ? "" : driveKey;
    }

    static String shortAlias(String driveKey) {
        String k = normalizeDriveKey(driveKey);
        if (DRIVE_QUARK.equals(k)) return "夸父";
        if (DRIVE_UC.equals(k)) return "优汐";
        if (DRIVE_BAIDU.equals(k)) return "嘟嘟";
        if (DRIVE_ALI.equals(k)) return "阿狸";
        return driveKey == null ? "" : driveKey;
    }

    static boolean looksLikeHttpUrl(String value) {
        if (value == null) return false;
        String t = value.trim().toLowerCase(Locale.ROOT);
        return t.startsWith("http://") || t.startsWith("https://");
    }

    /** Parses semicolon-separated Cookie string into a case-preserving map. */
    static Map<String, String> parseCookieMap(String rawCookie) {
        Map<String, String> out = new LinkedHashMap<>();
        if (rawCookie == null || rawCookie.trim().isEmpty()) return out;
        String normalized = rawCookie.replace('\r', ';').replace('\n', ';');
        for (String part : normalized.split(";")) {
            String trimmed = part.trim();
            if (trimmed.isEmpty()) continue;
            int eq = trimmed.indexOf('=');
            if (eq <= 0) continue;
            String key = trimmed.substring(0, eq).trim();
            String val = trimmed.substring(eq + 1).trim();
            if (!key.isEmpty() && !val.isEmpty()) {
                out.put(key, val);
            }
        }
        return out;
    }

    static String cookieValueIgnoreCase(Map<String, String> cookies, String key) {
        if (cookies == null || key == null) return "";
        for (Map.Entry<String, String> entry : cookies.entrySet()) {
            if (key.equalsIgnoreCase(entry.getKey())) {
                return entry.getValue() == null ? "" : entry.getValue().trim();
            }
        }
        return "";
    }

    /** Extracts raw cookie string from a stored Quark credential (either v1 JSON envelope or raw cookie). */
    static String extractQuarkCookie(String raw) {
        if (raw == null) return "";
        String t = raw.trim();
        if (t.isEmpty()) return "";
        if (t.startsWith("{")) {
            try {
                JSONObject obj = new JSONObject(t);
                String c = obj.optString("cookie", "").trim();
                if (!c.isEmpty()) return c;
            } catch (Exception ignored) {
            }
        }
        return t;
    }

    /** Extracts clean Ali refresh token from {@code ali_token=...} or raw token text. */
    static String extractAliRefreshToken(String raw) {
        if (raw == null) return "";
        String t = raw.trim();
        if (t.isEmpty() || looksLikeHttpUrl(t)) return "";
        if (t.startsWith("{")) {
            try {
                JSONObject obj = new JSONObject(t);
                String rt = obj.optString("refresh_token", "").trim();
                if (rt.isEmpty()) rt = obj.optString("refreshToken", "").trim();
                if (rt.isEmpty()) rt = obj.optString("token", "").trim();
                if (!rt.isEmpty()) t = rt;
            } catch (Exception ignored) {
            }
        }
        if (t.toLowerCase(Locale.ROOT).startsWith("ali_token=")) {
            t = t.substring("ali_token=".length()).trim();
            int semi = t.indexOf(';');
            if (semi >= 0) t = t.substring(0, semi).trim();
        } else if (t.contains("=")) {
            Map<String, String> map = parseCookieMap(t);
            String found = cookieValueIgnoreCase(map, "ali_token");
            if (found.isEmpty()) found = cookieValueIgnoreCase(map, "refresh_token");
            if (!found.isEmpty()) t = found;
        }
        if (t.contains(" ") || t.contains("\n") || t.contains("\r")) return "";
        return t;
    }

    /** Validates whether {@code rawValue} is a genuinely usable credential for {@code driveKey}. */
    static boolean isCredentialUsable(String driveKey, String rawValue) {
        String key = normalizeDriveKey(driveKey);
        if (key.isEmpty() || rawValue == null) return false;
        String t = rawValue.trim();
        if (t.isEmpty() || looksLikeHttpUrl(t)) return false;
        if (DRIVE_QUARK.equals(key)) {
            String cookie = extractQuarkCookie(t);
            Map<String, String> map = parseCookieMap(cookie);
            String pus = cookieValueIgnoreCase(map, "__pus");
            String puus = cookieValueIgnoreCase(map, "__puus");
            return !pus.isEmpty() || !puus.isEmpty();
        }
        if (DRIVE_UC.equals(key)) {
            Map<String, String> map = parseCookieMap(t);
            String pus = cookieValueIgnoreCase(map, "__pus");
            String puus = cookieValueIgnoreCase(map, "__puus");
            return !pus.isEmpty() || !puus.isEmpty();
        }
        if (DRIVE_BAIDU.equals(key)) {
            Map<String, String> map = parseCookieMap(t);
            String bduss = cookieValueIgnoreCase(map, "BDUSS");
            return bduss.length() >= 12;
        }
        if (DRIVE_ALI.equals(key)) {
            String rt = extractAliRefreshToken(t);
            return rt.length() >= 16;
        }
        return false;
    }

    /** Normalizes a validated credential into canonical storage format. */
    static String normalizeCredential(String driveKey, String rawValue) {
        String key = normalizeDriveKey(driveKey);
        if (!isCredentialUsable(key, rawValue)) return "";
        String t = rawValue.trim();
        if (DRIVE_QUARK.equals(key)) {
            return extractQuarkCookie(t);
        }
        if (DRIVE_ALI.equals(key)) {
            return "ali_token=" + extractAliRefreshToken(t);
        }
        return t;
    }

    /**
     * Derives a stable, credential-free account identity hash from a drive credential so that
     * Favorites & WatchHistory remain isolated across different accounts while surviving cookie
     * re-logins of the same account.
     */
    static String deriveCookieAccountId(String driveKey, String rawCredential) {
        String key = normalizeDriveKey(driveKey);
        if (!isCredentialUsable(key, rawCredential)) return "";
        if (DRIVE_QUARK.equals(key)) {
            String cookie = extractQuarkCookie(rawCredential);
            Map<String, String> map = parseCookieMap(cookie);
            String pus = cookieValueIgnoreCase(map, "__pus");
            if (!pus.isEmpty()) {
                return "quark:pus:" + sha256Hex("quark|__pus=" + pus).substring(0, 16);
            }
            String puus = cookieValueIgnoreCase(map, "__puus");
            return "quark:puus:" + sha256Hex("quark|__puus=" + puus).substring(0, 16);
        }
        if (DRIVE_UC.equals(key)) {
            Map<String, String> map = parseCookieMap(rawCredential);
            String pus = cookieValueIgnoreCase(map, "__pus");
            String uid = cookieValueIgnoreCase(map, "uid");
            if (!uid.isEmpty()) {
                return "uc:uid:" + uid;
            }
            if (!pus.isEmpty()) {
                return "uc:v2:" + sha256Hex("uc|__pus=" + pus).substring(0, 16);
            }
            String puus = cookieValueIgnoreCase(map, "__puus");
            return "uc:v2:" + sha256Hex("uc|__puus=" + puus).substring(0, 16);
        }
        if (DRIVE_BAIDU.equals(key)) {
            Map<String, String> map = parseCookieMap(rawCredential);
            String bduss = cookieValueIgnoreCase(map, "BDUSS");
            return "baidu:v2:" + sha256Hex("baidu|BDUSS=" + bduss).substring(0, 16);
        }
        if (DRIVE_ALI.equals(key)) {
            String rt = extractAliRefreshToken(rawCredential);
            return "ali:v2:" + sha256Hex("ali|rt=" + rt).substring(0, 16);
        }
        return "";
    }

    static String sha256Hex(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest =
                    md.digest((input == null ? "" : input).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                sb.append(String.format(Locale.ROOT, "%02x", b & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(input == null ? 0 : input.hashCode());
        }
    }

    private static String encryptBestEffort(String plain) {
        if (plain == null || plain.isEmpty()) return "";
        try {
            return SecureStorage.encrypt(plain);
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String decryptBestEffort(String cipherText) {
        if (cipherText == null || cipherText.isEmpty()) return "";
        try {
            return SecureStorage.decrypt(cipherText);
        } catch (Throwable ignored) {
            return "";
        }
    }

    static String getCredential(Context context, String driveKey) {
        return getCredential(storeFor(context), driveKey);
    }

    static String getCredential(KeyValueStore store, String driveKey) {
        String key = normalizeDriveKey(driveKey);
        if (store == null || key.isEmpty()) return "";
        String enc = store.getString(KEY_CRED_ENC_PREFIX + key, "");
        if (enc != null && !enc.isEmpty()) {
            String dec = decryptBestEffort(enc);
            if (!dec.isEmpty() && isCredentialUsable(key, dec)) {
                return dec;
            }
        }
        String plain = store.getString(KEY_CRED_PREFIX + key, "");
        if (plain != null && !plain.isEmpty() && isCredentialUsable(key, plain)) {
            return plain;
        }
        return "";
    }

    static boolean isLoggedIn(Context context, String driveKey) {
        return isLoggedIn(storeFor(context), driveKey);
    }

    static boolean isLoggedIn(KeyValueStore store, String driveKey) {
        return !getCredential(store, driveKey).isEmpty();
    }

    static int loggedInCount(Context context) {
        return loggedInCount(storeFor(context));
    }

    static int loggedInCount(KeyValueStore store) {
        int count = 0;
        for (String drive : DEFAULT_ORDER) {
            if (isLoggedIn(store, drive)) count++;
        }
        return count;
    }

    static boolean setCredential(Context context, String driveKey, String rawValue) {
        return setCredential(storeFor(context), driveKey, rawValue, "");
    }

    static boolean setCredential(
            Context context, String driveKey, String rawValue, String explicitOwnerId) {
        return setCredential(storeFor(context), driveKey, rawValue, explicitOwnerId);
    }

    static boolean setCredential(
            KeyValueStore store, String driveKey, String rawValue, String explicitOwnerId) {
        String key = normalizeDriveKey(driveKey);
        if (store == null || key.isEmpty()) return false;
        if (rawValue == null || rawValue.trim().isEmpty()) {
            clearCredential(store, key);
            return true;
        }
        String normalized = normalizeCredential(key, rawValue);
        if (normalized.isEmpty()) return false;

        String prevCred = getCredential(store, key);
        String prevAccountId = getAccountId(store, key);
        String prevOwnerId = store.getString(KEY_OWNER_ID_PREFIX + key, "");
        String cookieAccountId = deriveCookieAccountId(key, normalized);
        String cleanOwner = explicitOwnerId == null ? "" : explicitOwnerId.trim();

        String enc = encryptBestEffort(normalized);
        if (!enc.isEmpty()) {
            store.putString(KEY_CRED_ENC_PREFIX + key, enc);
            store.remove(KEY_CRED_PREFIX + key);
        } else {
            store.putString(KEY_CRED_PREFIX + key, normalized);
            store.remove(KEY_CRED_ENC_PREFIX + key);
        }

        // Preserve verified owner ID only when the new credential matches the same owner or has
        // an explicit matching owner; clear stale owner ID when switching to a different credential
        // without confirmed ownership so Account A's ID is never mistakenly inherited by Account B!
        String effectiveAccountId;
        if (!cleanOwner.isEmpty()) {
            effectiveAccountId = cleanOwner;
            store.putString(KEY_OWNER_ID_PREFIX + key, cleanOwner);
            if (!cleanOwner.equals(prevOwnerId)) {
                store.remove(KEY_VERIFIED_COOKIES_PREFIX + key);
            }
            addVerifiedCookieAccountId(store, key, cookieAccountId);
        } else if (cookieAccountId.equals(prevAccountId) || normalized.equals(prevCred)) {
            effectiveAccountId = !prevOwnerId.isEmpty() ? prevOwnerId : cookieAccountId;
        } else {
            // Different cookie and no explicit owner ID yet -> bind to new cookieAccountId
            // and drop old owner ID until server API verifies ownership.
            store.remove(KEY_OWNER_ID_PREFIX + key);
            store.remove(KEY_VERIFIED_COOKIES_PREFIX + key);
            effectiveAccountId = cookieAccountId;
        }
        store.putString(KEY_ACCOUNT_ID_PREFIX + key, effectiveAccountId);
        store.putString(KEY_VERIFIED_AT_PREFIX + key, String.valueOf(System.currentTimeMillis()));
        notifyChanged();
        return true;
    }

    static void clearCredential(Context context, String driveKey) {
        clearCredential(storeFor(context), driveKey);
    }

    static void clearCredential(KeyValueStore store, String driveKey) {
        String key = normalizeDriveKey(driveKey);
        if (store == null || key.isEmpty()) return;
        store.remove(KEY_CRED_ENC_PREFIX + key);
        store.remove(KEY_CRED_PREFIX + key);
        store.remove(KEY_ACCOUNT_ID_PREFIX + key);
        store.remove(KEY_OWNER_ID_PREFIX + key);
        store.remove(KEY_VERIFIED_COOKIES_PREFIX + key);
        store.remove(KEY_VERIFIED_AT_PREFIX + key);
        notifyChanged();
    }

    /** Returns the canonical active account ID (server owner ID if verified, else cookie hash). */
    static String getAccountId(Context context, String driveKey) {
        return getAccountId(storeFor(context), driveKey);
    }

    static String getAccountId(KeyValueStore store, String driveKey) {
        String key = normalizeDriveKey(driveKey);
        if (store == null || key.isEmpty()) return "";
        String cred = getCredential(store, key);
        if (cred.isEmpty()) return "";
        String owner = store.getString(KEY_OWNER_ID_PREFIX + key, "");
        if (owner != null && !owner.trim().isEmpty()) return owner.trim();
        String saved = store.getString(KEY_ACCOUNT_ID_PREFIX + key, "");
        if (saved != null && !saved.trim().isEmpty()) return saved.trim();
        return deriveCookieAccountId(key, cred);
    }

    /**
     * Records a server-verified owner ID (e.g. {@code uc:uid:123}, {@code baidu:uk:456}, {@code
     * ali:uid:789}, {@code quark:uid:111}) for the currently logged-in credential.
     */
    static void recordVerifiedOwner(
            KeyValueStore store, String driveKey, String ownerId, String rawCredential) {
        String key = normalizeDriveKey(driveKey);
        if (store == null || key.isEmpty() || ownerId == null || ownerId.trim().isEmpty()) return;
        String cleanOwner = ownerId.trim();
        String prevOwner = store.getString(KEY_OWNER_ID_PREFIX + key, "");
        if (!cleanOwner.equals(prevOwner)) {
            store.remove(KEY_VERIFIED_COOKIES_PREFIX + key);
        }
        store.putString(KEY_OWNER_ID_PREFIX + key, cleanOwner);
        store.putString(KEY_ACCOUNT_ID_PREFIX + key, cleanOwner);
        String cookieId = deriveCookieAccountId(key, rawCredential);
        if (!cookieId.isEmpty()) {
            addVerifiedCookieAccountId(store, key, cookieId);
        }
    }

    static Set<String> getAccountAliases(KeyValueStore store, String driveKey) {
        Set<String> aliases = new LinkedHashSet<>();
        String key = normalizeDriveKey(driveKey);
        if (store == null || key.isEmpty()) return aliases;
        String cred = getCredential(store, key);
        if (cred.isEmpty()) return aliases;
        String owner = store.getString(KEY_OWNER_ID_PREFIX + key, "");
        if (owner != null && !owner.trim().isEmpty()) aliases.add(owner.trim());
        String saved = store.getString(KEY_ACCOUNT_ID_PREFIX + key, "");
        if (saved != null && !saved.trim().isEmpty()) aliases.add(saved.trim());
        String cookieId = deriveCookieAccountId(key, cred);
        if (!cookieId.isEmpty()) aliases.add(cookieId);
        String verifiedRaw = store.getString(KEY_VERIFIED_COOKIES_PREFIX + key, "");
        if (verifiedRaw != null && !verifiedRaw.isEmpty()) {
            try {
                JSONArray arr = new JSONArray(verifiedRaw);
                for (int i = 0; i < arr.length(); i++) {
                    String s = arr.optString(i, "").trim();
                    if (!s.isEmpty()) aliases.add(s);
                }
            } catch (Exception ignored) {
            }
        }
        return aliases;
    }

    private static void addVerifiedCookieAccountId(
            KeyValueStore store, String key, String cookieAccountId) {
        if (cookieAccountId == null || cookieAccountId.isEmpty()) return;
        LinkedHashSet<String> set = new LinkedHashSet<>();
        String raw = store.getString(KEY_VERIFIED_COOKIES_PREFIX + key, "");
        if (raw != null && !raw.isEmpty()) {
            try {
                JSONArray arr = new JSONArray(raw);
                for (int i = 0; i < arr.length(); i++) {
                    String v = arr.optString(i, "").trim();
                    if (!v.isEmpty()) set.add(v);
                }
            } catch (Exception ignored) {
            }
        }
        set.add(cookieAccountId);
        JSONArray out = new JSONArray();
        for (String v : set) out.put(v);
        store.putString(KEY_VERIFIED_COOKIES_PREFIX + key, out.toString());
    }

    static List<String> getOrder(Context context) {
        return getOrder(storeFor(context));
    }

    static List<String> getOrder(KeyValueStore store) {
        if (store == null) return new ArrayList<>(DEFAULT_ORDER);
        return parseOrder(store.getString(KEY_ORDER, ""));
    }

    static List<String> parseOrder(String raw) {
        List<String> out = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        if (raw != null && !raw.trim().isEmpty()) {
            String[] parts = raw.split("[,;\\s>|]+");
            for (String p : parts) {
                String k = normalizeDriveKey(p);
                if (!k.isEmpty() && seen.add(k)) {
                    out.add(k);
                }
            }
        }
        for (String def : DEFAULT_ORDER) {
            if (seen.add(def)) out.add(def);
        }
        return out;
    }

    static boolean isDefaultOrder(KeyValueStore store) {
        return DEFAULT_ORDER.equals(getOrder(store));
    }

    static void setOrder(Context context, List<String> order) {
        setOrder(storeFor(context), order);
    }

    static void setOrder(KeyValueStore store, List<String> order) {
        if (store == null) return;
        StringBuilder sb = new StringBuilder();
        List<String> normalized = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        if (order != null) {
            for (String item : order) {
                String k = normalizeDriveKey(item);
                if (!k.isEmpty() && seen.add(k)) normalized.add(k);
            }
        }
        for (String def : DEFAULT_ORDER) {
            if (seen.add(def)) normalized.add(def);
        }
        for (int i = 0; i < normalized.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(normalized.get(i));
        }
        store.putString(KEY_ORDER, sb.toString());
        notifyChanged();
    }

    static String formatOrderBanner(List<String> order) {
        List<String> list = order == null || order.isEmpty() ? DEFAULT_ORDER : order;
        StringBuilder sb = new StringBuilder("盘序优先：");
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(" > ");
            sb.append(shortAlias(list.get(i)));
        }
        return sb.toString();
    }

    static String joinOrderCsv(List<String> order) {
        List<String> list = order == null || order.isEmpty() ? DEFAULT_ORDER : order;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(list.get(i));
        }
        return sb.toString();
    }

    static List<String> moveDriveInOrder(List<String> currentOrder, int fromIndex, int toIndex) {
        List<String> list =
                new ArrayList<>(
                        currentOrder == null || currentOrder.isEmpty()
                                ? DEFAULT_ORDER
                                : currentOrder);
        if (fromIndex < 0
                || fromIndex >= list.size()
                || toIndex < 0
                || toIndex >= list.size()
                || fromIndex == toIndex) {
            return list;
        }
        String moved = list.remove(fromIndex);
        list.add(toIndex, moved);
        return list;
    }

    /** Recognizes one of the 4 core netdisk keys from a line title (with ASCII boundary guards). */
    static String detectDriveKeyFromLineName(String raw) {
        return WatchHistory.detectDriveKeyFromLineName(raw);
    }

    static String detectDriveKeyFromEpisodeUrl(String rawUrl) {
        return WatchHistory.detectDriveKeyFromUrl(rawUrl);
    }

    private static boolean isNetdiskShareUrl(String rawUrl) {
        String host = WatchHistory.extractLowerHost(rawUrl);
        if (host.isEmpty()) return false;
        return WatchHistory.hostEqualsOrSubdomain(host, "pan.quark.cn")
                || WatchHistory.hostEqualsOrSubdomain(host, "drive.uc.cn")
                || WatchHistory.hostEqualsOrSubdomain(host, "fast.uc.cn")
                || WatchHistory.hostEqualsOrSubdomain(host, "pan.baidu.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "yun.baidu.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "alipan.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "aliyundrive.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "115.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "115cdn.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "anxia.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "cloud.189.cn")
                || WatchHistory.hostEqualsOrSubdomain(host, "yun.139.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "caiyun.139.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123pan.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123684.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123865.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123912.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "pan.xunlei.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "mypikpak.com");
    }

    private static boolean isExtendedNetdiskShareHost(String rawUrl) {
        String host = WatchHistory.extractLowerHost(rawUrl);
        if (host.isEmpty()) return false;
        return WatchHistory.hostEqualsOrSubdomain(host, "115.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "115cdn.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "anxia.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "cloud.189.cn")
                || WatchHistory.hostEqualsOrSubdomain(host, "yun.139.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "caiyun.139.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123pan.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123684.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123865.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "123912.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "pan.xunlei.com")
                || WatchHistory.hostEqualsOrSubdomain(host, "mypikpak.com");
    }

    private static boolean isBare115Name(String label) {
        if (label == null) return false;
        String norm = label.trim().toLowerCase(Locale.ROOT);
        if ("115".equals(norm)) return true;
        int hashIdx = norm.indexOf('#');
        if (hashIdx > 0 && "115".equals(norm.substring(0, hashIdx).trim())) {
            String suffix = norm.substring(hashIdx + 1).trim();
            if (!suffix.isEmpty()) {
                boolean allDigits = true;
                for (int i = 0; i < suffix.length(); i++) {
                    if (!Character.isDigit(suffix.charAt(i))) {
                        allDigits = false;
                        break;
                    }
                }
                if (allDigits) return true;
            }
        }
        return false;
    }

    private static boolean isExplicitDirectStreamUrl(String url) {
        if (url == null || url.isEmpty() || isNetdiskShareUrl(url)) return false;
        String lower = url.toLowerCase(Locale.ROOT);
        if (lower.startsWith("rtsp://")
                || lower.startsWith("rtsps://")
                || lower.startsWith("rtmp://")
                || lower.startsWith("rtmps://")
                || lower.startsWith("rtmpt://")
                || lower.startsWith("rtmpe://")
                || lower.startsWith("rtmfp://")
                || lower.startsWith("udp://")
                || lower.startsWith("rtp://")
                || lower.startsWith("mms://")
                || lower.startsWith("mmsh://")
                || lower.startsWith("mmst://")
                || lower.startsWith("srt://")
                || lower.startsWith("rist://")
                || lower.startsWith("webrtc://")
                || lower.startsWith("file://")
                || lower.startsWith("content://")) {
            return true;
        }
        if (!Cms.isHttp(url)) return false;
        String path = url.split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        return path.endsWith(".m3u8")
                || path.endsWith(".mp4")
                || path.endsWith(".flv")
                || path.endsWith(".mkv")
                || path.endsWith(".ts")
                || path.endsWith(".webm")
                || path.endsWith(".mpd")
                || path.endsWith(".mov")
                || path.endsWith(".avi");
    }

    /**
     * Returns {@code true} ONLY when a line is genuinely a pure direct playable stream line (e.g.
     * {@code .m3u8} / {@code .mp4} / {@code .mkv} / {@code rtsp://} on non-netdisk-share hosts). A
     * line containing any explicit netdisk share episode — or a leading direct trailer followed by
     * non-direct netdisk/redirect main episodes — MUST return {@code false} so drive ordering still
     * applies.
     */
    static boolean hasExplicitDirectMediaUrl(Cms.Line line) {
        if (line == null || line.episodes == null || line.episodes.isEmpty()) return false;
        boolean sawDirect = false;
        boolean sawNonTrailerDirect = false;
        boolean sawNonTrailerNonDirect = false;
        int checked = 0;
        int checkedNonTrailer = 0;
        for (int i = 0; i < line.episodes.size() && (checked < 8 || checkedNonTrailer < 3); i++) {
            Cms.Episode ep = line.episodes.get(i);
            if (ep == null || ep.url == null) continue;
            String url = ep.url.trim();
            if (url.isEmpty()) continue;
            checked++;
            if (isNetdiskShareUrl(url)) {
                return false;
            }
            boolean isTrailer = HistoryResumeMatcher.isTrailerOrExtraName(ep.name);
            boolean direct = isExplicitDirectStreamUrl(url);
            if (direct) {
                sawDirect = true;
                if (!isTrailer) {
                    sawNonTrailerDirect = true;
                    checkedNonTrailer++;
                }
            } else if (!isTrailer) {
                sawNonTrailerNonDirect = true;
                checkedNonTrailer++;
            }
        }
        if (sawNonTrailerDirect) return true;
        return sawDirect && !sawNonTrailerNonDirect;
    }

    /**
     * Classifies a playback {@link Cms.Line} into one of the 4 core netdisk keys ({@code quark},
     * {@code uc}, {@code baidu}, {@code ali}). Explicit netdisk share hostnames on episodes take
     * strict precedence over display aliases (e.g. a real {@code pan.quark.cn} share renamed to
     * "百度的备用线路" stays {@code quark}); only lines without explicit share hosts fall back to
     * {@code rawName}/{@code name}. Pure direct-stream lines return {@code ""}.
     */
    static String detectLineDriveKey(Cms.Line line) {
        if (line == null || hasExplicitDirectMediaUrl(line)) return "";
        if (line.episodes != null) {
            int checked = 0;
            for (int i = 0; i < line.episodes.size() && checked < 8; i++) {
                Cms.Episode ep = line.episodes.get(i);
                if (ep == null || ep.url == null || ep.url.trim().isEmpty()) continue;
                checked++;
                String byUrl = detectDriveKeyFromEpisodeUrl(ep.url);
                if (!byUrl.isEmpty()) return byUrl;
                if (isExtendedNetdiskShareHost(ep.url)) {
                    // Explicit extended share host (e.g. 115.com) must not be hijacked by a core
                    // drive alias in rawName/name.
                    return "";
                }
            }
        }
        String byRaw = detectDriveKeyFromLineName(line.rawName());
        if (!byRaw.isEmpty()) return byRaw;
        return detectDriveKeyFromLineName(line.name);
    }

    static boolean isExtendedNetdiskLine(Cms.Line line) {
        if (line == null || hasExplicitDirectMediaUrl(line)) return false;
        if (line.episodes != null) {
            int checked = 0;
            for (int i = 0; i < line.episodes.size() && checked < 8; i++) {
                Cms.Episode ep = line.episodes.get(i);
                if (ep == null || ep.url == null || ep.url.trim().isEmpty()) continue;
                checked++;
                if (!detectDriveKeyFromEpisodeUrl(ep.url).isEmpty()) {
                    return false;
                }
                if (isExtendedNetdiskShareHost(ep.url)) {
                    return true;
                }
            }
        }
        String rawName = line.rawName() == null ? "" : line.rawName();
        String dispName = line.name == null ? "" : line.name;
        if (isBare115Name(rawName) || isBare115Name(dispName)) {
            return true;
        }
        String combined = (rawName + " " + dispName).toLowerCase(Locale.ROOT);
        return combined.contains("115网盘")
                || combined.contains("115云")
                || combined.contains("115盘")
                || combined.contains("115原画")
                || combined.contains("115超清")
                || combined.contains("pan115")
                || combined.contains("天翼")
                || combined.contains("189云")
                || combined.contains("189网盘")
                || combined.contains("189盘")
                || combined.contains("pan189")
                || combined.contains("移动云")
                || combined.contains("移动网盘")
                || combined.contains("移动原画")
                || combined.contains("139云")
                || combined.contains("139网盘")
                || combined.contains("pan139")
                || combined.contains("123云")
                || combined.contains("123盘")
                || combined.contains("123网盘")
                || combined.contains("pan123")
                || combined.contains("迅雷")
                || combined.contains("thunder")
                || combined.contains("pikpak");
    }

    /**
     * Stably reorders netdisk lines according to {@code driveOrder} while keeping non-netdisk
     * (e.g. direct stream) lines in their original slots. Multiple lines belonging to the same
     * drive retain their upstream relative order, and prioritized core drives are placed ahead of
     * extended netdisk lines (115 / 天翼 / 移动 / 123 / 迅雷).
     */
    static List<Cms.Line> sortLinesByDriveOrder(List<Cms.Line> lines, List<String> driveOrder) {
        if (lines == null || lines.size() <= 1) {
            return lines == null ? new ArrayList<Cms.Line>() : new ArrayList<Cms.Line>(lines);
        }
        final List<String> effectiveOrder =
                (driveOrder == null || driveOrder.isEmpty())
                        ? DEFAULT_ORDER
                        : parseOrder(joinOrderCsv(driveOrder));
        final Map<String, Integer> rankMap = new HashMap<>();
        for (int i = 0; i < effectiveOrder.size(); i++) {
            rankMap.put(effectiveOrder.get(i), i);
        }
        final int extendedRank = effectiveOrder.size();

        List<Integer> netdiskSlots = new ArrayList<>();
        List<Cms.Line> netdiskLines = new ArrayList<>();
        boolean hasCoreDrive = false;
        for (int i = 0; i < lines.size(); i++) {
            Cms.Line l = lines.get(i);
            String dk = detectLineDriveKey(l);
            if (!dk.isEmpty()) {
                hasCoreDrive = true;
                netdiskSlots.add(i);
                netdiskLines.add(l);
            } else if (isExtendedNetdiskLine(l)) {
                netdiskSlots.add(i);
                netdiskLines.add(l);
            }
        }
        if (!hasCoreDrive || netdiskLines.size() <= 1) {
            return new ArrayList<>(lines);
        }

        Collections.sort(
                netdiskLines,
                (a, b) -> {
                    String da = detectLineDriveKey(a);
                    String db = detectLineDriveKey(b);
                    int ra =
                            !da.isEmpty() && rankMap.containsKey(da)
                                    ? rankMap.get(da)
                                    : extendedRank;
                    int rb =
                            !db.isEmpty() && rankMap.containsKey(db)
                                    ? rankMap.get(db)
                                    : extendedRank;
                    return Integer.compare(ra, rb);
                });

        List<Cms.Line> out = new ArrayList<>(lines);
        for (int i = 0; i < netdiskSlots.size(); i++) {
            out.set(netdiskSlots.get(i), netdiskLines.get(i));
        }
        return out;
    }

    static Map<String, String> allCredentials(KeyValueStore store) {
        Map<String, String> out = new LinkedHashMap<>();
        for (String d : DEFAULT_ORDER) {
            String c = getCredential(store, d);
            if (!c.isEmpty()) out.put(d, c);
        }
        return out;
    }
}

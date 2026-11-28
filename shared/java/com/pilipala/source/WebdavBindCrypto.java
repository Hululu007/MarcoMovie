// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.source;

import java.io.UnsupportedEncodingException;
import java.net.URI;
import java.net.URLDecoder;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Locale;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Pure HMAC-SHA256 authenticated encryption ({@code marco-bind-box-v1}) and QR URI codecs for
 * direct LAN WebDAV binding between mobile, TV, and desktop Marco Movie clients.
 *
 * <p>Compatible with Android API 14+, standard JVM unit runners, Dart {@code package:crypto}, and
 * Swift {@code CryptoKit}.
 */
public final class WebdavBindCrypto {
    public static final String BIND_SCHEME_FRAGMENT = "marco-bind=v1";
    public static final String ALG = "marco-bind-box-v1";
    public static final int KEY_BYTES = 32;
    public static final int NONCE_BYTES = 16;
    private static final String ENC_INFO = "marco-bind-v1-enc";
    private static final String MAC_INFO = "marco-bind-v1-mac";
    private static final String MAC_LABEL = "marco-bind-box-v1";
    private static final SecureRandom RNG = new SecureRandom();
    private static final char[] B64URL_ALPHABET =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toCharArray();

    private WebdavBindCrypto() {}

    public static final class ParsedBindTarget {
        public final String baseEndpointUrl;
        public final String bindUrl;
        public final String syncUrl;
        public final byte[] key;

        ParsedBindTarget(String baseEndpointUrl, String bindUrl, String syncUrl, byte[] key) {
            this.baseEndpointUrl = baseEndpointUrl;
            this.bindUrl = bindUrl;
            this.syncUrl = syncUrl;
            this.key = key;
        }
    }

    public static byte[] generateKey() {
        byte[] k = new byte[KEY_BYTES];
        RNG.nextBytes(k);
        return k;
    }

    public static String buildBindQrUrl(String baseEndpointUrl, byte[] key) {
        if (baseEndpointUrl == null || baseEndpointUrl.trim().isEmpty()) {
            throw new IllegalArgumentException("Missing baseEndpointUrl");
        }
        if (key == null || key.length != KEY_BYTES) {
            throw new IllegalArgumentException("Expected 32-byte key");
        }
        String cleanBase = baseEndpointUrl.trim();
        int hashIdx = cleanBase.indexOf('#');
        if (hashIdx >= 0) {
            cleanBase = cleanBase.substring(0, hashIdx);
        }
        return cleanBase + "#" + BIND_SCHEME_FRAGMENT + "&k=" + encodeBase64UrlNoPad(key);
    }

    public static ParsedBindTarget parseBindQrInput(String rawInput) {
        if (rawInput == null) return null;
        String trimmed = rawInput.trim();
        if (trimmed.isEmpty()) return null;

        String endpoint = "";
        String keyB64 = "";

        if (trimmed.toLowerCase(Locale.ROOT).startsWith("marcomovie://bind")) {
            int qIdx = trimmed.indexOf('?');
            if (qIdx < 0) return null;
            String query = trimmed.substring(qIdx + 1);
            int hashIdx = query.indexOf('#');
            if (hashIdx >= 0) query = query.substring(0, hashIdx);
            for (String part : query.split("&")) {
                String[] kv = part.split("=", 2);
                if (kv.length != 2) continue;
                String name = urlDecode(kv[0]);
                String val = urlDecode(kv[1]);
                if ("u".equals(name)) endpoint = val.trim();
                else if ("k".equals(name)) keyB64 = val.trim();
            }
        } else {
            int hashIdx = trimmed.indexOf('#');
            if (hashIdx < 0) return null;
            endpoint = trimmed.substring(0, hashIdx).trim();
            String frag = trimmed.substring(hashIdx + 1).trim();
            for (String part : frag.split("&")) {
                String[] kv = part.split("=", 2);
                if (kv.length == 2 && "k".equals(kv[0])) {
                    keyB64 = urlDecode(kv[1]).trim();
                }
            }
        }

        if (endpoint.isEmpty() || keyB64.isEmpty()) return null;
        byte[] key;
        try {
            key = decodeBase64Url(keyB64);
        } catch (IllegalArgumentException bad) {
            return null;
        }
        if (key.length != KEY_BYTES) return null;

        try {
            URI uri = URI.create(endpoint);
            String scheme = uri.getScheme();
            if (scheme == null
                    || (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme))) {
                return null;
            }
            if (uri.getHost() == null || uri.getHost().trim().isEmpty()) {
                return null;
            }
        } catch (Exception badUri) {
            return null;
        }

        String base = endpoint;
        while (base.endsWith("/")) {
            base = base.substring(0, base.length() - 1);
        }
        if (base.endsWith("/bind")) {
            base = base.substring(0, base.length() - "/bind".length());
        } else if (base.endsWith("/sync")) {
            base = base.substring(0, base.length() - "/sync".length());
        }
        return new ParsedBindTarget(base, base + "/bind", base + "/sync", key);
    }

    public static String sealJson(byte[] key, JSONObject payload)
            throws GeneralSecurityException, JSONException {
        if (payload == null) throw new IllegalArgumentException("Missing payload");
        byte[] nonce = new byte[NONCE_BYTES];
        RNG.nextBytes(nonce);
        return sealPlaintextWithNonce(key, nonce, payload.toString());
    }

    public static String sealPlaintextWithNonce(byte[] key, byte[] nonce, String plaintextJson)
            throws GeneralSecurityException, JSONException {
        if (key == null || key.length != KEY_BYTES) {
            throw new IllegalArgumentException("Expected 32-byte key");
        }
        if (nonce == null || nonce.length != NONCE_BYTES) {
            throw new IllegalArgumentException("Expected 16-byte nonce");
        }
        if (plaintextJson == null) throw new IllegalArgumentException("Missing plaintext");
        byte[] pt = utf8(plaintextJson);
        byte[] encKey = hmacSha256(key, utf8(ENC_INFO));
        byte[] macKey = hmacSha256(key, utf8(MAC_INFO));
        byte[] ct = xorCtr(encKey, nonce, pt);
        byte[] tag = computeTag(macKey, nonce, ct);

        JSONObject env = new JSONObject();
        env.put("v", 1);
        env.put("alg", ALG);
        env.put("n", encodeBase64UrlNoPad(nonce));
        env.put("c", encodeBase64UrlNoPad(ct));
        env.put("t", encodeBase64UrlNoPad(tag));
        return env.toString();
    }

    public static JSONObject openJson(byte[] key, String envelopeJson)
            throws GeneralSecurityException, JSONException {
        String raw = openPlaintext(key, envelopeJson);
        return new JSONObject(raw);
    }

    public static String openPlaintext(byte[] key, String envelopeJson)
            throws GeneralSecurityException, JSONException {
        if (key == null || key.length != KEY_BYTES) {
            throw new GeneralSecurityException("Invalid bind key length");
        }
        if (envelopeJson == null || envelopeJson.trim().isEmpty()) {
            throw new GeneralSecurityException("Empty envelope");
        }
        JSONObject env = new JSONObject(envelopeJson);
        if (env.optInt("v", 0) != 1 || !ALG.equals(env.optString("alg", ""))) {
            throw new GeneralSecurityException("Unsupported bind envelope version or algorithm");
        }
        byte[] nonce = decodeBase64Url(env.optString("n", ""));
        byte[] ct = decodeBase64Url(env.optString("c", ""));
        byte[] tag = decodeBase64Url(env.optString("t", ""));
        if (nonce.length != NONCE_BYTES || tag.length != 32) {
            throw new GeneralSecurityException("Malformed bind envelope sizes");
        }
        byte[] macKey = hmacSha256(key, utf8(MAC_INFO));
        byte[] expectedTag = computeTag(macKey, nonce, ct);
        if (!MessageDigest.isEqual(expectedTag, tag)) {
            throw new GeneralSecurityException("Bind MAC verification failed");
        }
        byte[] encKey = hmacSha256(key, utf8(ENC_INFO));
        byte[] pt = xorCtr(encKey, nonce, ct);
        try {
            return new String(pt, "UTF-8");
        } catch (UnsupportedEncodingException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    private static byte[] computeTag(byte[] macKey, byte[] nonce, byte[] ct)
            throws GeneralSecurityException {
        byte[] label = utf8(MAC_LABEL);
        byte[] input = new byte[label.length + nonce.length + ct.length];
        System.arraycopy(label, 0, input, 0, label.length);
        System.arraycopy(nonce, 0, input, label.length, nonce.length);
        System.arraycopy(ct, 0, input, label.length + nonce.length, ct.length);
        return hmacSha256(macKey, input);
    }

    private static byte[] xorCtr(byte[] encKey, byte[] nonce, byte[] data)
            throws GeneralSecurityException {
        byte[] out = new byte[data.length];
        byte[] blockInput = new byte[nonce.length + 4];
        System.arraycopy(nonce, 0, blockInput, 0, nonce.length);
        int offset = 0;
        int counter = 0;
        while (offset < data.length) {
            blockInput[nonce.length] = (byte) ((counter >>> 24) & 0xff);
            blockInput[nonce.length + 1] = (byte) ((counter >>> 16) & 0xff);
            blockInput[nonce.length + 2] = (byte) ((counter >>> 8) & 0xff);
            blockInput[nonce.length + 3] = (byte) (counter & 0xff);
            byte[] ks = hmacSha256(encKey, blockInput);
            int take = Math.min(ks.length, data.length - offset);
            for (int i = 0; i < take; i++) {
                out[offset + i] = (byte) (data[offset + i] ^ ks[i]);
            }
            offset += take;
            counter++;
        }
        return out;
    }

    public static byte[] hmacSha256(byte[] key, byte[] message) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(message);
    }

    public static byte[] decodeKey(String b64Url) {
        byte[] raw = decodeBase64Url(b64Url);
        if (raw.length != KEY_BYTES) {
            throw new IllegalArgumentException("Expected 32-byte key");
        }
        return raw;
    }

    public static String encodeKey(byte[] key) {
        return encodeBase64UrlNoPad(key);
    }

    public static String encodeBase64UrlNoPad(byte[] data) {
        if (data == null) return "";
        StringBuilder sb = new StringBuilder((data.length * 4 + 2) / 3);
        int i = 0;
        while (i < data.length) {
            int b0 = data[i++] & 0xff;
            int b1 = i < data.length ? (data[i++] & 0xff) : -1;
            int b2 = i < data.length ? (data[i++] & 0xff) : -1;
            sb.append(B64URL_ALPHABET[b0 >>> 2]);
            sb.append(B64URL_ALPHABET[((b0 & 0x03) << 4) | (b1 >= 0 ? (b1 >>> 4) : 0)]);
            if (b1 >= 0) {
                sb.append(B64URL_ALPHABET[((b1 & 0x0f) << 2) | (b2 >= 0 ? (b2 >>> 6) : 0)]);
            }
            if (b2 >= 0) {
                sb.append(B64URL_ALPHABET[b2 & 0x3f]);
            }
        }
        return sb.toString();
    }

    public static byte[] decodeBase64Url(String text) {
        if (text == null) throw new IllegalArgumentException("null base64url");
        String s = text.trim();
        while (s.endsWith("=")) {
            s = s.substring(0, s.length() - 1);
        }
        int len = s.length();
        if (len == 0) return new byte[0];
        if ((len & 3) == 1) throw new IllegalArgumentException("Invalid base64url length");
        int outLen = (len * 3) / 4;
        byte[] out = new byte[outLen];
        int i = 0;
        int j = 0;
        while (i < len) {
            int c0 = b64Val(s.charAt(i++));
            int c1 = b64Val(s.charAt(i++));
            int c2 = i < len ? b64Val(s.charAt(i++)) : -1;
            int c3 = i < len ? b64Val(s.charAt(i++)) : -1;
            out[j++] = (byte) ((c0 << 2) | (c1 >>> 4));
            if (c2 >= 0) {
                out[j++] = (byte) (((c1 & 0x0f) << 4) | (c2 >>> 2));
                if (c3 >= 0) {
                    out[j++] = (byte) (((c2 & 0x03) << 6) | c3);
                }
            }
        }
        return out;
    }

    private static int b64Val(char c) {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '-' || c == '+') return 62;
        if (c == '_' || c == '/') return 63;
        throw new IllegalArgumentException("Invalid base64url char: " + c);
    }

    private static String urlDecode(String s) {
        try {
            return URLDecoder.decode(s, "UTF-8");
        } catch (UnsupportedEncodingException e) {
            return s;
        }
    }

    private static byte[] utf8(String s) {
        try {
            return s.getBytes("UTF-8");
        } catch (UnsupportedEncodingException impossible) {
            throw new IllegalStateException(impossible);
        }
    }
}

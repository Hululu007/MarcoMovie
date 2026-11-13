package com.pilipala.marcomovie.lite;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class SecureStorage {
    private static final String PREF_FILE = "lite_secure_creds";
    private static final String KEY_PASS_ENC = "webdav_pass_enc";
    private static final String KEY_DEVICE_SALT = "device_salt";
    private static final String CIPHER_ALGO = "AES/CBC/PKCS5Padding";
    private static final int IV_LENGTH = 16;
    private static final String CHARSET = "UTF-8";

    private SecureStorage() {}

    private static SecretKeySpec deriveKey(Context ctx) throws Exception {
        SharedPreferences sp = ctx.getSharedPreferences(PREF_FILE, 0);
        String salt = sp.getString(KEY_DEVICE_SALT, "");
        if (salt == null || salt.isEmpty()) {
            byte[] saltBytes = new byte[16];
            new SecureRandom().nextBytes(saltBytes);
            StringBuilder sb = new StringBuilder();
            for (byte b : saltBytes) {
                sb.append(String.format("%02x", b));
            }
            salt = sb.toString();
            sp.edit().putString(KEY_DEVICE_SALT, salt).apply();
        }
        String seed = ctx.getPackageName() + ":lite_secure_v1:" + salt;
        byte[] hash = MessageDigest.getInstance("SHA-256").digest(seed.getBytes(CHARSET));
        byte[] keyBytes = new byte[16];
        System.arraycopy(hash, 0, keyBytes, 0, 16);
        return new SecretKeySpec(keyBytes, "AES");
    }

    public static String encrypt(Context ctx, String plainText) throws Exception {
        if (plainText == null || plainText.isEmpty()) return "";
        SecretKeySpec key = deriveKey(ctx);
        Cipher cipher = Cipher.getInstance(CIPHER_ALGO);
        byte[] iv = new byte[IV_LENGTH];
        new SecureRandom().nextBytes(iv);
        cipher.init(Cipher.ENCRYPT_MODE, key, new IvParameterSpec(iv));
        byte[] cipherText = cipher.doFinal(plainText.getBytes(CHARSET));
        byte[] combined = new byte[iv.length + cipherText.length];
        System.arraycopy(iv, 0, combined, 0, iv.length);
        System.arraycopy(cipherText, 0, combined, iv.length, cipherText.length);
        return Base64.encodeToString(combined, Base64.NO_WRAP);
    }

    public static String decrypt(Context ctx, String base64Payload) throws Exception {
        if (base64Payload == null || base64Payload.isEmpty()) return "";
        byte[] combined = Base64.decode(base64Payload, Base64.NO_WRAP);
        if (combined.length <= IV_LENGTH) return "";
        byte[] iv = new byte[IV_LENGTH];
        System.arraycopy(combined, 0, iv, 0, IV_LENGTH);
        byte[] cipherText = new byte[combined.length - IV_LENGTH];
        System.arraycopy(combined, IV_LENGTH, cipherText, 0, cipherText.length);

        SecretKeySpec key = deriveKey(ctx);
        Cipher cipher = Cipher.getInstance(CIPHER_ALGO);
        cipher.init(Cipher.DECRYPT_MODE, key, new IvParameterSpec(iv));
        byte[] plain = cipher.doFinal(cipherText);
        return new String(plain, CHARSET);
    }

    private static SharedPreferences getLegacyPrefs(Context ctx) {
        if (ctx instanceof Activity) {
            return ((Activity) ctx).getPreferences(0);
        }
        return ctx.getSharedPreferences(ctx.getClass().getSimpleName(), 0);
    }

    public static String getWebdavPass(Context ctx) {
        if (ctx == null) return "";
        SharedPreferences legacy = getLegacyPrefs(ctx);
        if (legacy.contains("webdav_pass")) {
            String legacyPass = legacy.getString("webdav_pass", "");
            if (legacyPass != null && !legacyPass.isEmpty()) {
                setWebdavPass(ctx, legacyPass);
            } else {
                clearWebdavPass(ctx);
            }
            legacy.edit().remove("webdav_pass").apply();
            return legacyPass != null ? legacyPass : "";
        }

        SharedPreferences securePrefs = ctx.getSharedPreferences(PREF_FILE, 0);
        String enc = securePrefs.getString(KEY_PASS_ENC, "");
        if (enc == null || enc.isEmpty()) return "";
        try {
            return decrypt(ctx, enc);
        } catch (Throwable t) {
            return "";
        }
    }

    public static void setWebdavPass(Context ctx, String pass) {
        if (ctx == null) return;
        SharedPreferences legacy = getLegacyPrefs(ctx);
        legacy.edit().remove("webdav_pass").apply();

        SharedPreferences securePrefs = ctx.getSharedPreferences(PREF_FILE, 0);
        if (pass == null || pass.isEmpty()) {
            securePrefs.edit().remove(KEY_PASS_ENC).apply();
            return;
        }
        try {
            String enc = encrypt(ctx, pass);
            securePrefs.edit().putString(KEY_PASS_ENC, enc).apply();
        } catch (Throwable ignored) {
        }
    }

    public static void clearWebdavPass(Context ctx) {
        if (ctx == null) return;
        getLegacyPrefs(ctx).edit().remove("webdav_pass").apply();
        ctx.getSharedPreferences(PREF_FILE, 0).edit().remove(KEY_PASS_ENC).apply();
    }
}

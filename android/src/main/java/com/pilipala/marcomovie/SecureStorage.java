package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class SecureStorage {
    private static final String KEYSTORE_PROVIDER = "AndroidKeyStore";
    private static final String KEY_ALIAS = "movie_webdav_credential_key";
    private static final String PREF_FILE = "movie_secure_credentials";
    private static final String KEY_WEBDAV_PASS_ENC = "webdav_pass_enc";
    private static final String AES_GCM_NO_PADDING = "AES/GCM/NoPadding";
    private static final int GCM_TAG_LENGTH = 128;
    private static final int GCM_IV_LENGTH = 12;

    private SecureStorage() {}

    private static synchronized SecretKey getOrCreateKey() throws Exception {
        try {
            KeyStore ks = KeyStore.getInstance(KEYSTORE_PROVIDER);
            ks.load(null);
            if (ks.containsAlias(KEY_ALIAS)) {
                return (SecretKey) ks.getKey(KEY_ALIAS, null);
            }
            KeyGenerator kg =
                    KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER);
            KeyGenParameterSpec spec =
                    new KeyGenParameterSpec.Builder(
                                    KEY_ALIAS,
                                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setKeySize(256)
                            .build();
            kg.init(spec);
            return kg.generateKey();
        } catch (Throwable t) {
            // Fallback for JVM host test environments without AndroidKeyStore
            byte[] raw =
                    MessageDigest.getInstance("SHA-256")
                            .digest(
                                    "marco_movie_jvm_fallback_key"
                                            .getBytes(StandardCharsets.UTF_8));
            return new SecretKeySpec(raw, "AES");
        }
    }

    public static String encrypt(String plainText) throws Exception {
        if (plainText == null || plainText.isEmpty()) return "";
        SecretKey key = getOrCreateKey();
        Cipher cipher = Cipher.getInstance(AES_GCM_NO_PADDING);
        byte[] iv = new byte[GCM_IV_LENGTH];
        new SecureRandom().nextBytes(iv);
        cipher.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_LENGTH, iv));
        byte[] cipherText = cipher.doFinal(plainText.getBytes(StandardCharsets.UTF_8));
        byte[] combined = new byte[iv.length + cipherText.length];
        System.arraycopy(iv, 0, combined, 0, iv.length);
        System.arraycopy(cipherText, 0, combined, iv.length, cipherText.length);
        return Base64.encodeToString(combined, Base64.NO_WRAP);
    }

    public static String decrypt(String base64Payload) throws Exception {
        if (base64Payload == null || base64Payload.isEmpty()) return "";
        byte[] combined = Base64.decode(base64Payload, Base64.NO_WRAP);
        if (combined.length < GCM_IV_LENGTH + 16) return "";
        byte[] iv = new byte[GCM_IV_LENGTH];
        System.arraycopy(combined, 0, iv, 0, GCM_IV_LENGTH);
        byte[] cipherText = new byte[combined.length - GCM_IV_LENGTH];
        System.arraycopy(combined, GCM_IV_LENGTH, cipherText, 0, cipherText.length);

        SecretKey key = getOrCreateKey();
        Cipher cipher = Cipher.getInstance(AES_GCM_NO_PADDING);
        cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_LENGTH, iv));
        byte[] plain = cipher.doFinal(cipherText);
        return new String(plain, StandardCharsets.UTF_8);
    }

    public static String getWebdavPass(Context context) {
        if (context == null) return "";
        SharedPreferences legacyPrefs =
                context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        if (legacyPrefs.contains(Prefs.WEBDAV_PASS)) {
            String legacyPass = legacyPrefs.getString(Prefs.WEBDAV_PASS, "");
            if (legacyPass != null && !legacyPass.isEmpty()) {
                setWebdavPass(context, legacyPass);
            } else {
                clearWebdavPass(context);
            }
            legacyPrefs.edit().remove(Prefs.WEBDAV_PASS).apply();
            return legacyPass != null ? legacyPass : "";
        }

        SharedPreferences securePrefs =
                context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
        String enc = securePrefs.getString(KEY_WEBDAV_PASS_ENC, "");
        if (enc == null || enc.isEmpty()) return "";
        try {
            return decrypt(enc);
        } catch (Throwable t) {
            return "";
        }
    }

    public static void setWebdavPass(Context context, String pass) {
        if (context == null) return;
        SharedPreferences legacyPrefs =
                context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE);
        legacyPrefs.edit().remove(Prefs.WEBDAV_PASS).apply();

        SharedPreferences securePrefs =
                context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
        if (pass == null || pass.isEmpty()) {
            securePrefs.edit().remove(KEY_WEBDAV_PASS_ENC).apply();
            return;
        }
        try {
            String enc = encrypt(pass);
            securePrefs.edit().putString(KEY_WEBDAV_PASS_ENC, enc).apply();
        } catch (Throwable ignored) {
        }
    }

    public static void clearWebdavPass(Context context) {
        if (context == null) return;
        context.getSharedPreferences(Prefs.FILE, Context.MODE_PRIVATE)
                .edit()
                .remove(Prefs.WEBDAV_PASS)
                .apply();
        context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)
                .edit()
                .remove(KEY_WEBDAV_PASS_ENC)
                .apply();
    }
}

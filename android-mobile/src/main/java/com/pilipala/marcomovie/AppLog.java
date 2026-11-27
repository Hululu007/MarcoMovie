package com.pilipala.marcomovie;

import java.lang.reflect.Method;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * Bounded in-memory diagnostic ring buffer that works both on Android (forwarding to logcat) and in
 * offline JVM tests without requiring the Android framework jar at runtime.
 *
 * <p>All log lines and exception messages are scrubbed via {@link #sanitize(String)} before entering
 * the ring buffer or logcat so upstream error bodies echoing raw API keys or native auth headers
 * never leak into diagnostics.
 */
final class AppLog {
    static final int CAPACITY = 200;
    private static final ArrayDeque<String> ENTRIES = new ArrayDeque<>(CAPACITY);
    private static final int MAX_REGISTERED_SECRETS = 16;
    private static final ArrayDeque<String> REGISTERED_SECRETS =
            new ArrayDeque<>(MAX_REGISTERED_SECRETS);
    private static final Method ANDROID_INFO;
    private static final Method ANDROID_WARN;

    private static final Pattern JSON_SECRET_RE =
            Pattern.compile(
                    "(?i)(\\\\?\"(?:access_token|refresh_token|id_token|api_key|apikey|api-key|x-api-key|x-goog-api-key|x_api_key|x_goog_api_key|key|secret|token|authorization|proxy-authorization|cookie|set-cookie|device_code|user_code|code_verifier|client_secret)\\\\?\"\\s*:\\s*\\\\?\")([^\"\\\\]*)(\\\\?\")");
    private static final Pattern AUTH_HEADER_RE =
            Pattern.compile(
                    "(?i)(['\"]?(?:authorization|proxy-authorization|x-api-key|x-goog-api-key|api-key|cookie|set-cookie)['\"]?\\s*[:=]\\s*['\"]?(?:Bearer\\s+|Basic\\s+)?)([^\\s,;\"'}\\]]+)");
    private static final Pattern BEARER_RE = Pattern.compile("(?i)(Bearer\\s+)[A-Za-z0-9._~+/=-]+");
    private static final Pattern FORM_SECRET_RE =
            Pattern.compile(
                    "(?i)((?:access_token|refresh_token|code_verifier|device_code|client_secret|api_key|key)=)([^&\\s]+)");
    private static final Pattern BARE_SK_KEY_RE = Pattern.compile("\\bsk-[A-Za-z0-9_-]{8,}\\b");
    private static final Pattern BARE_GEMINI_KEY_RE =
            Pattern.compile("\\bAIza[A-Za-z0-9_-]{12,}\\b");
    private static final Pattern PASSCODE_TOKEN_RE =
            Pattern.compile("MMAILAB1\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+");

    static {
        Method info = null, warn = null;
        try {
            Class<?> log = Class.forName("android.util.Log");
            info = log.getMethod("i", String.class, String.class);
            warn = log.getMethod("w", String.class, String.class);
        } catch (Throwable ignored) {
        }
        ANDROID_INFO = info;
        ANDROID_WARN = warn;
    }

    private AppLog() {}

    /**
     * Registers an active session credential in memory (never written to disk) so even short or
     * non-prefixed custom gateway API keys are scrubbed from logs, exception causes, and diagnostic
     * exports.
     */
    static void registerSecretForRedaction(String secret) {
        if (secret == null) return;
        String trimmed = secret.trim();
        if (trimmed.length() < 3) return;
        synchronized (REGISTERED_SECRETS) {
            REGISTERED_SECRETS.remove(trimmed);
            while (REGISTERED_SECRETS.size() >= MAX_REGISTERED_SECRETS) {
                REGISTERED_SECRETS.pollFirst();
            }
            REGISTERED_SECRETS.addLast(trimmed);
        }
    }

    static void clearRegisteredSecrets() {
        synchronized (REGISTERED_SECRETS) {
            REGISTERED_SECRETS.clear();
        }
    }

    static String redactKnownSecret(String raw, String knownSecret) {
        if (raw == null || raw.isEmpty() || knownSecret == null) return raw == null ? "" : raw;
        String trimmed = knownSecret.trim();
        if (trimmed.length() < 3) return raw;
        if (trimmed.length() >= 4) {
            return raw.replace(trimmed, "[REDACTED_KEY]");
        }
        // For 3-char custom secrets, redact token-bounded occurrences so ordinary words stay intact
        return Pattern.compile("(?<![A-Za-z0-9_-])" + Pattern.quote(trimmed) + "(?![A-Za-z0-9_-])")
                .matcher(raw)
                .replaceAll("[REDACTED_KEY]");
    }

    /** Redacts API keys, OAuth tokens, native auth headers, short custom keys, and passcodes. */
    static String sanitize(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String s = JSON_SECRET_RE.matcher(raw).replaceAll("$1[REDACTED]$3");
        s = AUTH_HEADER_RE.matcher(s).replaceAll("$1[REDACTED]");
        s = BEARER_RE.matcher(s).replaceAll("$1[REDACTED]");
        s = FORM_SECRET_RE.matcher(s).replaceAll("$1[REDACTED]");
        s = BARE_SK_KEY_RE.matcher(s).replaceAll("[REDACTED_KEY]");
        s = BARE_GEMINI_KEY_RE.matcher(s).replaceAll("[REDACTED_KEY]");
        s = PASSCODE_TOKEN_RE.matcher(s).replaceAll("MMAILAB1.[REDACTED]");
        List<String> secretsSnap;
        synchronized (REGISTERED_SECRETS) {
            secretsSnap = REGISTERED_SECRETS.isEmpty() ? null : new ArrayList<>(REGISTERED_SECRETS);
        }
        if (secretsSnap != null) {
            for (int i = secretsSnap.size() - 1; i >= 0; i--) {
                s = redactKnownSecret(s, secretsSnap.get(i));
            }
        }
        return s;
    }

    static void i(String tag, String message) {
        String safeMsg = sanitize(message);
        record("I", tag, safeMsg, null);
        if (ANDROID_INFO != null) {
            try {
                ANDROID_INFO.invoke(null, safeTag(tag), safeMsg);
            } catch (Throwable ignored) {
            }
        }
    }

    static void w(String tag, String message) {
        w(tag, message, null);
    }

    static void w(String tag, String message, Throwable error) {
        String safeMsg = sanitize(message);
        String formatted = formatLine(safeMsg, error);
        recordRaw("W", tag, formatted);
        if (ANDROID_WARN != null) {
            try {
                ANDROID_WARN.invoke(null, safeTag(tag), formatted);
            } catch (Throwable ignored) {
            }
        }
    }

    private static String safeTag(String tag) {
        return tag == null || tag.isEmpty() ? "MarcoMovie" : tag;
    }

    private static String formatLine(String safeMsg, Throwable error) {
        StringBuilder sb = new StringBuilder(96);
        sb.append(safeMsg == null ? "" : safeMsg);
        if (error != null) {
            sb.append(" (").append(error.getClass().getSimpleName());
            String detail = sanitize(error.getMessage());
            if (!detail.isEmpty()) sb.append(": ").append(detail);
            Throwable cause = error.getCause();
            Throwable prev = error;
            int depth = 0;
            while (cause != null && cause != prev && depth < 4) {
                String cDetail = sanitize(cause.getMessage());
                if (!cDetail.isEmpty()) {
                    sb.append(" <- ")
                            .append(cause.getClass().getSimpleName())
                            .append(": ")
                            .append(cDetail);
                }
                prev = cause;
                cause = cause.getCause();
                depth++;
            }
            sb.append(')');
        }
        return sb.toString();
    }

    private static void record(String level, String tag, String safeMsg, Throwable error) {
        recordRaw(level, tag, formatLine(safeMsg, error));
    }

    private static void recordRaw(String level, String tag, String body) {
        StringBuilder line = new StringBuilder(96);
        line.append(System.currentTimeMillis())
                .append(' ')
                .append(level)
                .append('/')
                .append(safeTag(tag))
                .append(": ")
                .append(body == null ? "" : body);
        synchronized (ENTRIES) {
            while (ENTRIES.size() >= CAPACITY) ENTRIES.pollFirst();
            ENTRIES.addLast(line.toString());
        }
    }

    static List<String> entries() {
        synchronized (ENTRIES) {
            return new ArrayList<>(ENTRIES);
        }
    }

    static String dump() {
        List<String> snapshot = entries();
        StringBuilder out = new StringBuilder(snapshot.size() * 64);
        for (int i = 0; i < snapshot.size(); i++) {
            if (i > 0) out.append('\n');
            out.append(snapshot.get(i));
        }
        return out.toString();
    }

    static void clear() {
        synchronized (ENTRIES) {
            ENTRIES.clear();
        }
    }
}

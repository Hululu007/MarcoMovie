package com.pilipala.source;

import org.json.JSONObject;

/**
 * Shared JSON access helpers ensuring null fields degrade to fallbacks instead of org.json's literal
 * "null" strings across Android and JVM runtimes.
 */
public final class Json {
    private Json() {}

    public static String str(JSONObject o, String key, String fallback) {
        if (o == null || !o.has(key) || o.isNull(key)) return fallback;
        Object v = o.opt(key);
        if (v == null || JSONObject.NULL.equals(v)) return fallback;
        String s = String.valueOf(v).trim();
        return s.isEmpty() ? fallback : s;
    }

    public static String str(JSONObject o, String key) {
        return str(o, key, "");
    }

    public static int integer(JSONObject o, String key, int fallback) {
        if (o == null || !o.has(key) || o.isNull(key)) return fallback;
        return o.optInt(key, fallback);
    }

    public static boolean bool(JSONObject o, String key, boolean fallback) {
        if (o == null || !o.has(key) || o.isNull(key)) return fallback;
        return o.optBoolean(key, fallback);
    }
}

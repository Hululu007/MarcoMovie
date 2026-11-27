package com.pilipala.marcomovie;

import android.content.SharedPreferences;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Refactored multi-protocol AI Assistant Service for Android Mobile / Tablet.
 *
 * <p>Strictly gated by {@link AiBetaGate#isUnlocked(android.content.Context)} during beta testing.
 * Supports both BYOK API Keys (DeepSeek, Qwen, SiliconFlow, Kimi, Zhipu GLM, OpenAI, native
 * Anthropic Claude, native Google Gemini, OpenRouter, local Ollama, and Custom OpenAI-compatible
 * gateways) and Subscription/OAuth sign-in via {@link AiAuthManager}. Zero built-in keys.
 */
final class AiAssistantService {
    interface ResultCallback<T> {
        void onResult(T value);
    }

    static final String[] PROVIDER_IDS = {
        "deepseek",
        "qwen",
        "siliconflow",
        "kimi",
        "glm",
        "openai",
        "anthropic",
        "gemini",
        "openrouter",
        "ollama",
        "custom"
    };
    static final String[] PROVIDER_LABELS = {
        "DeepSeek 官方",
        "阿里云百炼 (通义千问)",
        "SiliconFlow 硅基流动",
        "Moonshot (Kimi)",
        "智谱清言 (GLM)",
        "OpenAI 官方",
        "Anthropic Claude (原生接口)",
        "Google Gemini (原生接口)",
        "OpenRouter 聚合网关",
        "Ollama 局域网本地",
        "自定义 OpenAI 兼容网关"
    };

    private static final Pattern PY_SUSPICIOUS =
            Pattern.compile(
                    "(?i)\\b(os\\.system|subprocess\\.(?:Popen|call|run|check_output)|pty\\.spawn|shutil\\.rmtree|socket\\.socket)\\b");

    private AiAssistantService() {}

    static String defaultBaseUrl(String provider) {
        if ("qwen".equals(provider)) return "https://dashscope.aliyuncs.com/compatible-mode/v1";
        if ("siliconflow".equals(provider)) return "https://api.siliconflow.cn/v1";
        if ("kimi".equals(provider)) return "https://api.moonshot.cn/v1";
        if ("glm".equals(provider)) return "https://open.bigmodel.cn/api/paas/v4";
        if ("openai".equals(provider)) return "https://api.openai.com/v1";
        if ("anthropic".equals(provider)) return "https://api.anthropic.com";
        if ("gemini".equals(provider)) return "https://generativelanguage.googleapis.com";
        if ("openrouter".equals(provider)) return "https://openrouter.ai/api/v1";
        if ("ollama".equals(provider)) return "http://127.0.0.1:11434/v1";
        if ("custom".equals(provider)) return "";
        return "https://api.deepseek.com/v1";
    }

    static String defaultModel(String provider) {
        if ("qwen".equals(provider)) return "qwen-plus";
        if ("siliconflow".equals(provider)) return "Qwen/Qwen2.5-7B-Instruct";
        if ("kimi".equals(provider)) return "moonshot-v1-8k";
        if ("glm".equals(provider)) return "glm-4-flash";
        if ("openai".equals(provider)) return "gpt-4o-mini";
        if ("anthropic".equals(provider)) return "claude-haiku-5-5";
        if ("gemini".equals(provider)) return "gemini-3.5-flash-lite";
        if ("openrouter".equals(provider)) return "openai/gpt-4o-mini";
        if ("ollama".equals(provider)) return "qwen2.5:7b";
        if ("custom".equals(provider)) return "gpt-4o-mini";
        return "deepseek-flash";
    }

    static String providerLabel(String provider) {
        for (int i = 0; i < PROVIDER_IDS.length; i++) {
            if (PROVIDER_IDS[i].equals(provider)) return PROVIDER_LABELS[i];
        }
        return PROVIDER_LABELS[0];
    }

    static boolean isConfigured(MainActivity a) {
        if (a == null || a.isTvDevice()) return false;
        if (!AiBetaGate.isUnlocked(a)) return false;
        SharedPreferences mp = a.mobilePrefs();
        if (!mp.getBoolean(Prefs.AI_ENABLED, false)) return false;
        return AiAuthManager.isActiveCredentialReady(a);
    }

    static String resolveBaseUrl(MainActivity a) {
        SharedPreferences mp = a.mobilePrefs();
        String provider = mp.getString(Prefs.AI_PROVIDER, "deepseek");
        String custom = mp.getString(Prefs.AI_BASE_URL, "").trim();
        return resolveBaseUrl(provider, custom);
    }

    static String resolveBaseUrl(String provider, String customBaseUrl) {
        String custom = customBaseUrl == null ? "" : customBaseUrl.trim();
        String url = custom.isEmpty() ? defaultBaseUrl(provider) : custom;
        while (url.endsWith("/")) url = url.substring(0, url.length() - 1);
        return url;
    }

    static String resolveModel(MainActivity a) {
        SharedPreferences mp = a.mobilePrefs();
        String provider = mp.getString(Prefs.AI_PROVIDER, "deepseek");
        String m = mp.getString(Prefs.AI_MODEL, "").trim();
        return m.isEmpty() ? defaultModel(provider) : m;
    }

    /** Fast local heuristic security scan before running user-imported Python spiders. */
    static String staticSafetyScanPython(String pySource) {
        if (pySource == null || pySource.isEmpty()) return null;
        java.util.regex.Matcher m = PY_SUSPICIOUS.matcher(pySource);
        if (m.find()) {
            return "检测到高危系统调用 (" + m.group(1) + ")，请确认脚本来源可信";
        }
        return null;
    }

    static void cleanEpisodesAsync(
            final MainActivity a,
            final String seriesTitle,
            final List<Cms.Episode> episodes,
            final ResultCallback<Map<String, String>> callback) {
        if (!isConfigured(a) || episodes == null || episodes.isEmpty() || callback == null) {
            return;
        }
        final int count = Math.min(episodes.size(), 60);
        final List<String> rawNames = new ArrayList<>(count);
        StringBuilder sig = new StringBuilder(seriesTitle == null ? "" : seriesTitle);
        for (int i = 0; i < count; i++) {
            String n = episodes.get(i).name == null ? "" : episodes.get(i).name;
            rawNames.add(n);
            sig.append('|').append(n);
        }
        final String cacheKey = "ep_" + sha256(sig.toString());
        final int ticket = a.generation;
        a.worker.execute(
                () -> {
                    try {
                        String cached = readDiskCache(a, cacheKey);
                        JSONObject parsed;
                        if (cached != null && !cached.isEmpty()) {
                            parsed = new JSONObject(cached);
                        } else {
                            JSONArray arr = new JSONArray();
                            for (String n : rawNames) arr.put(n);
                            String sys =
                                    "你是影视剧集标题净化助手。将输入数组中的杂乱文件名整理为简短规范的中文集名（如“第 1 集”或“第 1 集 副标题”或“1080P 正片”），去除广告、网盘引流词与编码后缀。严格只输出 JSON 对象：{\"items\":[\"净化名1\",...]}，数组长度必须与输入完全一致。";
                            String usr =
                                    "片名："
                                            + (seriesTitle == null ? "" : seriesTitle)
                                            + "\n原始集名数组："
                                            + arr.toString();
                            String reply = chatCompletion(a, sys, usr, 1200);
                            parsed = extractJsonObject(reply);
                            if (parsed != null) writeDiskCache(a, cacheKey, parsed.toString());
                        }
                        if (parsed == null) return;
                        JSONArray outArr = parsed.optJSONArray("items");
                        if (outArr == null || outArr.length() != rawNames.size()) return;
                        final Map<String, String> map = new HashMap<>();
                        for (int i = 0; i < rawNames.size(); i++) {
                            String clean = outArr.optString(i, "").trim();
                            if (!clean.isEmpty()) map.put(rawNames.get(i), clean);
                        }
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing() && ticket == a.generation) {
                                        callback.onResult(map);
                                    }
                                });
                    } catch (Exception e) {
                        AppLog.w("AiAssistant", "cleanEpisodesAsync failed", e);
                    }
                });
    }

    static void translateSubtitleLinesAsync(
            final MainActivity a,
            final List<String> sourceLines,
            final ResultCallback<List<String>> callback) {
        if (!isConfigured(a) || sourceLines == null || sourceLines.isEmpty() || callback == null) {
            return;
        }
        final List<String> batch = new ArrayList<>(sourceLines);
        final String cacheKey = "sub_" + sha256(batch.toString());
        a.worker.execute(
                () -> {
                    try {
                        String cached = readDiskCache(a, cacheKey);
                        JSONObject parsed;
                        if (cached != null) {
                            parsed = new JSONObject(cached);
                        } else {
                            JSONArray arr = new JSONArray(batch);
                            String sys =
                                    "你是影视字幕翻译专家。将输入外语台词数组逐条自然翻译为简体中文。严格只返回 JSON 对象：{\"zh\":[\"译文1\",...]}，条数与输入完全一致。";
                            String reply = chatCompletion(a, sys, arr.toString(), 2200);
                            parsed = extractJsonObject(reply);
                            if (parsed != null) writeDiskCache(a, cacheKey, parsed.toString());
                        }
                        if (parsed == null) return;
                        JSONArray zh = parsed.optJSONArray("zh");
                        if (zh == null || zh.length() != batch.size()) return;
                        final List<String> result = new ArrayList<>(zh.length());
                        for (int i = 0; i < zh.length(); i++) {
                            result.add(zh.optString(i, ""));
                        }
                        a.ui.post(
                                () -> {
                                    if (!a.isFinishing()) callback.onResult(result);
                                });
                    } catch (Exception e) {
                        AppLog.w("AiAssistant", "translateSubtitleLinesAsync failed", e);
                    }
                });
    }

    static void testConnectionAsync(MainActivity a, final ResultCallback<String> callback) {
        a.worker.execute(
                () -> {
                    try {
                        String reply =
                                chatCompletion(
                                        a, "Reply concisely in Chinese.", "请回复“连接正常”四个字。", 64);
                        final String msg = "连接成功：" + (reply == null ? "" : reply.trim());
                        a.ui.post(() -> callback.onResult(msg));
                    } catch (Exception e) {
                        final String err = "连接失败：" + AiAuthManager.sanitizeLogBody(a.message(e));
                        a.ui.post(() -> callback.onResult(err));
                    }
                });
    }

    static String chatCompletion(
            MainActivity a, String systemPrompt, String userPrompt, int maxTokens)
            throws Exception {
        return chatCompletion(a, systemPrompt, userPrompt, maxTokens, 0.25);
    }

    static String chatCompletion(
            MainActivity a,
            String systemPrompt,
            String userPrompt,
            int maxTokens,
            double temperature)
            throws Exception {
        AiAuthManager.ResolvedRequest req = AiAuthManager.resolveActiveRequest(a);
        return AiAuthManager.executeChatCompletion(
                req, systemPrompt, userPrompt, maxTokens, temperature);
    }

    static JSONObject extractJsonObject(String raw) {
        if (raw == null) return null;
        String trimmed = raw.trim();
        if (trimmed.startsWith("```")) {
            int firstNl = trimmed.indexOf('\n');
            if (firstNl > 0) trimmed = trimmed.substring(firstNl + 1);
            int fenceEnd = trimmed.lastIndexOf("```");
            if (fenceEnd > 0) trimmed = trimmed.substring(0, fenceEnd);
        }
        int start = trimmed.indexOf('{');
        int end = trimmed.lastIndexOf('}');
        if (start >= 0 && end > start) {
            try {
                return new JSONObject(trimmed.substring(start, end + 1));
            } catch (Exception ignored) {
            }
        }
        return null;
    }

    static File cacheDir(MainActivity a) {
        File d = new File(a.getCacheDir(), "ai_cache_v1");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    static final int MAX_DISK_CACHE_BYTES = 4 * 1024 * 1024;

    static String readDiskCache(MainActivity a, String key) {
        return readDiskCacheFile(cacheDir(a), key);
    }

    static String readDiskCacheFile(File dir, String key) {
        if (dir == null || key == null || key.isEmpty()) return null;
        File f = new File(dir, key + ".json");
        if (!f.exists() || System.currentTimeMillis() - f.lastModified() > 14L * 86400_000L) {
            return null;
        }
        if (f.length() > MAX_DISK_CACHE_BYTES) {
            return null;
        }
        try (InputStream in = new FileInputStream(f)) {
            return Cms.read(in, MAX_DISK_CACHE_BYTES);
        } catch (Exception ignored) {
            return null;
        }
    }

    static boolean writeDiskCache(MainActivity a, String key, String json) {
        return writeDiskCacheFile(cacheDir(a), key, json);
    }

    static boolean writeDiskCacheFile(File dir, String key, String json) {
        if (dir == null || key == null || key.isEmpty() || json == null) return false;
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_DISK_CACHE_BYTES) {
            AppLog.w(
                    "AiAssistantService",
                    "Disk cache entry exceeds unified limit ("
                            + bytes.length
                            + " > "
                            + MAX_DISK_CACHE_BYTES
                            + ")");
            return false;
        }
        if (!dir.exists() && !dir.mkdirs()) return false;
        File target = new File(dir, key + ".json");
        File tmp = new File(dir, key + ".json.tmp");
        try (OutputStream out = new FileOutputStream(tmp)) {
            out.write(bytes);
            out.flush();
        } catch (Exception ignored) {
            tmp.delete();
            return false;
        }
        if (target.exists() && !target.delete()) {
            // Fallback direct overwrite if rename cannot replace
            try (OutputStream out = new FileOutputStream(target)) {
                out.write(bytes);
                out.flush();
                tmp.delete();
                return true;
            } catch (Exception ignored) {
                tmp.delete();
                return false;
            }
        }
        if (!tmp.renameTo(target)) {
            tmp.delete();
            return false;
        }
        return true;
    }

    static long cacheBytes(MainActivity a) {
        File d = new File(a.getCacheDir(), "ai_cache_v1");
        File[] files = d.listFiles();
        long sum = 0;
        if (files != null) for (File f : files) sum += f.length();
        return sum;
    }

    static void clearCache(MainActivity a) {
        File d = new File(a.getCacheDir(), "ai_cache_v1");
        File[] files = d.listFiles();
        if (files != null) for (File f : files) f.delete();
    }

    static String sha256(String s) {
        try {
            byte[] d =
                    MessageDigest.getInstance("SHA-256")
                            .digest((s == null ? "" : s).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(32);
            for (int i = 0; i < 16; i++) {
                sb.append(String.format(Locale.US, "%02x", d[i] & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(s == null ? 0 : s.hashCode());
        }
    }
}

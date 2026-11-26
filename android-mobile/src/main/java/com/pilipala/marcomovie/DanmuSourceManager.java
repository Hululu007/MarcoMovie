package com.pilipala.marcomovie;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Typeface;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Unified Danmu source store, new-service discovery/probe ("搜索并添加新弹幕源"), and in-player manual
 * episode matcher with multi-service candidate attribution (Item 5: 原 3).
 *
 * <p>Guarantees:
 *
 * <ul>
 *   <li>Settings and auto-playback strictly share ONE canonical ordered danmu source list
 *       (synchronizing {@link Prefs#DANMAKU_SOURCES_JSON} and {@link
 *       DanmuSettingsPanel#KEY_SERVER_URLS} atomically on every read/write).
 *   <li>Service URLs preserve non-default ports (e.g. {@code :8443}, {@code :18080}) and subpaths
 *       (e.g. {@code /dm}, {@code /12345}, {@code /2025/api}), stripping only redundant trailing
 *       {@code /} or {@code /api/v2}.
 *   <li>Clearly separates "搜索并添加新弹幕源" (discover & probe new service endpoints) from
 *       "在已配置弹幕源中手动匹配本集弹幕" (edit title, season, episode, inspect which service each
 *       candidate came from, and load selected episode danmu).
 * </ul>
 */
final class DanmuSourceManager {
    static final class ProbeResult {
        final boolean ok;
        final String normalizedOrigin;
        final String suggestedName;
        final long latencyMs;
        final int sampleCount;
        final String message;

        ProbeResult(
                boolean ok,
                String normalizedOrigin,
                String suggestedName,
                long latencyMs,
                int sampleCount,
                String message) {
            this.ok = ok;
            this.normalizedOrigin = normalizedOrigin == null ? "" : normalizedOrigin;
            this.suggestedName = suggestedName == null ? "" : suggestedName;
            this.latencyMs = latencyMs;
            this.sampleCount = sampleCount;
            this.message = message == null ? "" : message;
        }
    }

    interface CandidateCallback {
        void onSelected(DanmuProvider.Candidate candidate);
    }

    private DanmuSourceManager() {}

    /**
     * Normalizes a danmu service origin while strictly preserving non-default ports and arbitrary
     * subpaths ({@code /dm}, {@code /12345}, etc.), and stripping accidental trailing {@code
     * /api/v2} so users pasting a full API prefix never produce {@code /api/v2/api/v2/...}.
     */
    static String normalizeServiceOrigin(String raw) {
        if (raw == null) return null;
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return null;
        while (trimmed.endsWith("/")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        String lower = trimmed.toLowerCase(Locale.ROOT);
        if (lower.endsWith("/api/v2")) {
            trimmed = trimmed.substring(0, trimmed.length() - 7);
            while (trimmed.endsWith("/")) {
                trimmed = trimmed.substring(0, trimmed.length() - 1);
            }
        }
        return DandanplayProvider.normalizeOriginOrNull(trimmed);
    }

    static String defaultSourceName(String normalizedOrigin) {
        if (normalizedOrigin == null || normalizedOrigin.isEmpty()) return "自定义弹幕源";
        try {
            URI u = URI.create(normalizedOrigin);
            String host = u.getHost() == null ? normalizedOrigin : u.getHost();
            String portPart = u.getPort() > 0 ? (":" + u.getPort()) : "";
            String path = u.getRawPath() == null ? "" : u.getRawPath();
            return host + portPart + path;
        } catch (Exception ignored) {
            return normalizedOrigin;
        }
    }

    /** Formats a concise source badge showing BOTH friendly name and host:port/subpath. */
    static String formatCandidateSourceBadge(
            String sourceOrigin, List<OnlineSubtitleDanmakuService.DanmakuSource> configured) {
        String norm = normalizeServiceOrigin(sourceOrigin);
        String endpoint = defaultSourceName(norm != null ? norm : sourceOrigin);
        if (configured != null && norm != null) {
            for (OnlineSubtitleDanmakuService.DanmakuSource s : configured) {
                if (s == null) continue;
                String sNorm = normalizeServiceOrigin(s.baseUrl);
                if (norm.equals(sNorm) && s.name != null && !s.name.trim().isEmpty()) {
                    if (s.name.trim().equalsIgnoreCase(endpoint)) return s.name.trim();
                    return s.name.trim() + " · " + endpoint;
                }
            }
        }
        return endpoint;
    }

    /** Loads the single unified danmu source list by merging mobile JSON & legacy server URLs. */
    static List<OnlineSubtitleDanmakuService.DanmakuSource> loadUnifiedSources(Context context) {
        if (context == null) return new ArrayList<>();
        SharedPreferences mobilePrefs =
                context.getSharedPreferences(Prefs.MOBILE_FILE, Context.MODE_PRIVATE);
        SharedPreferences mainPrefs =
                context.getSharedPreferences(DanmuSettingsPanel.PREFS_FILE, Context.MODE_PRIVATE);
        return mergeSources(
                mobilePrefs.getString(Prefs.DANMAKU_SOURCES_JSON, "[]"),
                mainPrefs.getString(DanmuSettingsPanel.KEY_SERVER_URLS, ""));
    }

    /** Pure-JVM merger of mobile JSON sources and multiline {@code danmu_server_urls}. */
    static List<OnlineSubtitleDanmakuService.DanmakuSource> mergeSources(
            String mobileJson, String legacyMultilineUrls) {
        List<OnlineSubtitleDanmakuService.DanmakuSource> out = new ArrayList<>();
        Set<String> seen = new LinkedHashSet<>();

        if (mobileJson != null && !mobileJson.trim().isEmpty()) {
            try {
                JSONArray arr = new JSONArray(mobileJson);
                for (int i = 0;
                        i < arr.length() && out.size() < DandanplayProvider.MAX_SERVERS;
                        i++) {
                    JSONObject o = arr.optJSONObject(i);
                    if (o == null) continue;
                    String norm = normalizeServiceOrigin(o.optString("url", ""));
                    if (norm == null || !seen.add(norm)) continue;
                    String name = o.optString("name", "").trim();
                    if (name.isEmpty()) name = defaultSourceName(norm);
                    out.add(
                            new OnlineSubtitleDanmakuService.DanmakuSource(
                                    name,
                                    norm,
                                    o.optBoolean("enabled", true),
                                    o.optLong("latencyMs", -1L)));
                }
            } catch (Exception ignored) {
            }
        }

        if (legacyMultilineUrls != null && !legacyMultilineUrls.trim().isEmpty()) {
            String[] lines = legacyMultilineUrls.split("\\r?\\n");
            for (String line : lines) {
                if (out.size() >= DandanplayProvider.MAX_SERVERS) break;
                String norm = normalizeServiceOrigin(line);
                if (norm == null || !seen.add(norm)) continue;
                out.add(
                        new OnlineSubtitleDanmakuService.DanmakuSource(
                                defaultSourceName(norm), norm, true, -1L));
            }
        }
        return out;
    }

    /** Atomically persists unified sources into BOTH mobile JSON and {@code danmu_server_urls}. */
    static void saveUnifiedSources(
            Context context, List<OnlineSubtitleDanmakuService.DanmakuSource> list) {
        if (context == null) return;
        List<OnlineSubtitleDanmakuService.DanmakuSource> cleaned = new ArrayList<>();
        Set<String> seen = new LinkedHashSet<>();
        StringBuilder enabledLines = new StringBuilder();
        JSONArray arr = new JSONArray();

        if (list != null) {
            for (OnlineSubtitleDanmakuService.DanmakuSource src : list) {
                if (src == null || cleaned.size() >= DandanplayProvider.MAX_SERVERS) continue;
                String norm = normalizeServiceOrigin(src.baseUrl);
                if (norm == null || !seen.add(norm)) continue;
                String name =
                        src.name == null || src.name.trim().isEmpty()
                                ? defaultSourceName(norm)
                                : src.name.trim();
                OnlineSubtitleDanmakuService.DanmakuSource item =
                        new OnlineSubtitleDanmakuService.DanmakuSource(
                                name, norm, src.enabled, src.latencyMs);
                cleaned.add(item);
                try {
                    arr.put(item.toJson());
                } catch (Exception ignored) {
                }
                if (item.enabled) {
                    if (enabledLines.length() > 0) enabledLines.append('\n');
                    enabledLines.append(norm);
                }
            }
        }

        context.getSharedPreferences(Prefs.MOBILE_FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(Prefs.DANMAKU_SOURCES_JSON, arr.toString())
                .apply();
        context.getSharedPreferences(DanmuSettingsPanel.PREFS_FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(DanmuSettingsPanel.KEY_SERVER_URLS, enabledLines.toString())
                .apply();
    }

    /** Syncs multiline {@code danmu_server_urls} edits back into {@code DANMAKU_SOURCES_JSON}. */
    static void syncFromServerUrlsText(Context context, String rawMultilineUrls) {
        if (context == null) return;
        List<OnlineSubtitleDanmakuService.DanmakuSource> existing = loadUnifiedSources(context);
        Map<String, OnlineSubtitleDanmakuService.DanmakuSource> byOrigin = new LinkedHashMap<>();
        for (OnlineSubtitleDanmakuService.DanmakuSource s : existing) {
            byOrigin.put(s.baseUrl, s);
        }
        List<OnlineSubtitleDanmakuService.DanmakuSource> updated = new ArrayList<>();
        Set<String> seen = new LinkedHashSet<>();
        if (rawMultilineUrls != null && !rawMultilineUrls.trim().isEmpty()) {
            for (String line : rawMultilineUrls.split("\\r?\\n")) {
                if (updated.size() >= DandanplayProvider.MAX_SERVERS) break;
                String norm = normalizeServiceOrigin(line);
                if (norm == null || !seen.add(norm)) continue;
                OnlineSubtitleDanmakuService.DanmakuSource prev = byOrigin.get(norm);
                if (prev != null) {
                    updated.add(
                            new OnlineSubtitleDanmakuService.DanmakuSource(
                                    prev.name, norm, true, prev.latencyMs));
                } else {
                    updated.add(
                            new OnlineSubtitleDanmakuService.DanmakuSource(
                                    defaultSourceName(norm), norm, true, -1L));
                }
            }
        }
        saveUnifiedSources(context, updated);
    }

    static String enabledOriginsMultiline(List<OnlineSubtitleDanmakuService.DanmakuSource> list) {
        if (list == null || list.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (OnlineSubtitleDanmakuService.DanmakuSource s : list) {
            if (s == null || !s.enabled) continue;
            String norm = normalizeServiceOrigin(s.baseUrl);
            if (norm == null) continue;
            if (sb.length() > 0) sb.append('\n');
            sb.append(norm);
        }
        return sb.toString();
    }

    static boolean addOrUpdateSource(Context context, String name, String rawUrl, long latencyMs) {
        String norm = normalizeServiceOrigin(rawUrl);
        if (context == null || norm == null) return false;
        List<OnlineSubtitleDanmakuService.DanmakuSource> list = loadUnifiedSources(context);
        String finalName =
                (name == null || name.trim().isEmpty()) ? defaultSourceName(norm) : name.trim();
        for (int i = 0; i < list.size(); i++) {
            if (norm.equals(list.get(i).baseUrl)) {
                list.set(
                        i,
                        new OnlineSubtitleDanmakuService.DanmakuSource(
                                finalName, norm, true, latencyMs));
                saveUnifiedSources(context, list);
                return true;
            }
        }
        if (list.size() >= DandanplayProvider.MAX_SERVERS) return false;
        list.add(new OnlineSubtitleDanmakuService.DanmakuSource(finalName, norm, true, latencyMs));
        saveUnifiedSources(context, list);
        return true;
    }

    // =========================================================================
    // 1. Discover & Probe New Danmu Service ("搜索并添加新弹幕源")
    // =========================================================================

    /**
     * Probes a candidate danmu server address (preserving non-default ports & subpaths like {@code
     * /dm} or {@code /12345}) against Dandanplay-compatible v2 endpoints. If the user entered a
     * bare host:port without subpath and root returns 404, automatically probes {@code /dm}.
     */
    static ProbeResult probeNewDanmuService(String rawAddress, String sampleKeyword) {
        String norm = normalizeServiceOrigin(rawAddress);
        if (norm == null) {
            return new ProbeResult(
                    false, "", "", -1L, 0, "请输入有效的 HTTP/HTTPS 弹幕服务地址（支持非默认端口与 /dm 等子路径）");
        }
        String kw =
                (sampleKeyword == null || sampleKeyword.trim().isEmpty())
                        ? "三体"
                        : sampleKeyword.trim();

        List<String> candidates = new ArrayList<>();
        candidates.add(norm);
        try {
            URI u = URI.create(norm);
            String path = u.getRawPath();
            if (path == null || path.isEmpty() || "/".equals(path)) {
                candidates.add(norm + "/dm");
            }
        } catch (Exception ignored) {
        }

        String lastErr = "服务未响应或非兼容弹幕接口";
        for (String origin : candidates) {
            ProbeResult r = probeSingleOrigin(origin, kw);
            if (r.ok) return r;
            lastErr = r.message;
        }
        return new ProbeResult(false, norm, defaultSourceName(norm), -1L, 0, lastErr);
    }

    private static ProbeResult probeSingleOrigin(String origin, String keyword) {
        long t0 = System.currentTimeMillis();
        HttpURLConnection conn = null;
        try {
            String probeUrl =
                    origin
                            + "/api/v2/search/episodes?anime="
                            + DandanplayProvider.percentEncode(keyword);
            conn = ProxyAddress.openHttpConnection(new URL(probeUrl));
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(6000);
            conn.setReadTimeout(8000);
            conn.setInstanceFollowRedirects(false);
            conn.setRequestProperty("Accept", "application/json");
            conn.setRequestProperty("User-Agent", Cms.USER_AGENT);
            int code = conn.getResponseCode();
            long elapsed = Math.max(1L, System.currentTimeMillis() - t0);
            if (code == 401 || code == 403) {
                return new ProbeResult(
                        false,
                        origin,
                        defaultSourceName(origin),
                        elapsed,
                        0,
                        "服务需要认证（HTTP " + code + "）");
            }
            if (code < 200 || code >= 300) {
                return new ProbeResult(
                        false,
                        origin,
                        defaultSourceName(origin),
                        elapsed,
                        0,
                        "探测失败（HTTP " + code + "）");
            }
            String body = readUtf8(conn.getInputStream(), 1024 * 1024);
            JSONObject json = new JSONObject(body.trim());
            boolean validSchema =
                    json.has("animes")
                            || json.has("matches")
                            || json.has("success")
                            || json.has("errorCode");
            if (!validSchema) {
                return new ProbeResult(
                        false,
                        origin,
                        defaultSourceName(origin),
                        elapsed,
                        0,
                        "返回的 JSON 非弹弹Play v2 兼容格式");
            }
            JSONArray animes = json.optJSONArray("animes");
            int count = animes != null ? animes.length() : 0;
            return new ProbeResult(
                    true,
                    origin,
                    defaultSourceName(origin),
                    elapsed,
                    count,
                    "探测成功（" + elapsed + "ms，返回 " + count + " 条测试结果）");
        } catch (Exception e) {
            return new ProbeResult(
                    false,
                    origin,
                    defaultSourceName(origin),
                    -1L,
                    0,
                    "连接失败："
                            + (e.getMessage() == null
                                    ? e.getClass().getSimpleName()
                                    : e.getMessage()));
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    /** Dedicated UI for discovering/probing and adding a new danmu service endpoint. */
    static void showDiscoverAndAddServiceSheet(final MainActivity a, final Runnable onAdded) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);

        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));

        TextView intro =
                a.text(
                        "输入新的弹幕服务地址（完整保留非默认端口与 /dm、/数字前缀 等子路径），先探测验证兼容性再加入统一弹幕源列表。",
                        12f,
                        p.textSecondary);
        intro.setLineSpacing(a.dp(2), 1f);
        box.addView(intro);
        a.gap(box, 10);

        final EditText nameEt = buildInput(a, "服务名称（可选，如：自建弹幕服务）", "");
        box.addView(nameEt, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 8);

        final EditText urlEt =
                buildInput(
                        a, "http://danmu.example:8080/dm 或 https://danmu.example:8443/12345", "");
        urlEt.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        box.addView(urlEt, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 8);

        final EditText probeKwEt = buildInput(a, "探测测试片名（默认：三体）", "三体");
        box.addView(probeKwEt, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 10);

        final TextView probeStatusTv = a.text("尚未探测新服务", 12.5f, p.textSecondary);
        box.addView(probeStatusTv);
        a.gap(box, 12);

        LinearLayout actionRow = a.row();
        final TextView probeBtn = buildPillBtn(a, "探测并校验服务", true);
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(0, a.dp(40), 1f);
        plp.rightMargin = a.dp(8);
        actionRow.addView(probeBtn, plp);

        final TextView addBtn = buildPillBtn(a, "直接添加", false);
        actionRow.addView(addBtn, new LinearLayout.LayoutParams(0, a.dp(40), 1f));
        box.addView(actionRow, new LinearLayout.LayoutParams(-1, -2));

        final ProbeResult[] lastProbe = new ProbeResult[1];
        final MobileBottomSheet.SheetHandle handle =
                MobileBottomSheet.showCustom(a, "搜索并添加新弹幕源", box, null);

        probeBtn.setOnClickListener(
                v -> {
                    final String rawUrl = urlEt.getText().toString().trim();
                    final String kw = probeKwEt.getText().toString().trim();
                    probeBtn.setEnabled(false);
                    probeStatusTv.setText("正在探测服务接口与延迟…");
                    probeStatusTv.setTextColor(p.accent);
                    a.worker.execute(
                            () -> {
                                ProbeResult res = probeNewDanmuService(rawUrl, kw);
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()) return;
                                            probeBtn.setEnabled(true);
                                            lastProbe[0] = res;
                                            probeStatusTv.setText(
                                                    res.ok
                                                            ? (res.message
                                                                    + "\n规范地址："
                                                                    + res.normalizedOrigin)
                                                            : res.message);
                                            probeStatusTv.setTextColor(
                                                    res.ok ? p.success : p.danger);
                                            if (res.ok) {
                                                addBtn.setText("确认添加此服务");
                                                urlEt.setText(res.normalizedOrigin);
                                            }
                                        });
                            });
                });

        addBtn.setOnClickListener(
                v -> {
                    String rawUrl = urlEt.getText().toString().trim();
                    String norm = normalizeServiceOrigin(rawUrl);
                    if (norm == null) {
                        a.toast("请输入有效的 HTTP/HTTPS 弹幕服务地址（不含查询参数）");
                        return;
                    }
                    String name = nameEt.getText().toString().trim();
                    long latency =
                            (lastProbe[0] != null
                                            && lastProbe[0].ok
                                            && norm.equals(lastProbe[0].normalizedOrigin))
                                    ? lastProbe[0].latencyMs
                                    : -1L;
                    if (addOrUpdateSource(a, name, norm, latency)) {
                        handle.dismiss();
                        a.toast("已添加新弹幕源：" + (name.isEmpty() ? defaultSourceName(norm) : name));
                        if (onAdded != null) onAdded.run();
                    } else {
                        a.toast("弹幕源数量已达上限（最多 " + DandanplayProvider.MAX_SERVERS + " 个）");
                    }
                });
    }

    // =========================================================================
    // 2. In-Player Manual Episode Matching ("在已配置弹幕源里找本集弹幕")
    // =========================================================================

    static void showManualMatchSheet(
            final MainActivity a,
            final String initialTitle,
            final int initialSeason,
            final int initialEpisode,
            final long durationSec,
            final CandidateCallback onSelect) {
        if (a == null || a.isFinishing()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        final List<OnlineSubtitleDanmakuService.DanmakuSource> configured = loadUnifiedSources(a);
        final DanmuSettingsPanel.DanmuConfig cfg = DanmuSettingsPanel.loadConfig(a, a.isTvDevice());
        final String enabledMultiline = enabledOriginsMultiline(configured);

        LinearLayout box = a.vertical();
        box.setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(8));

        TextView desc =
                a.text(
                        "在已配置的 " + configured.size() + " 个弹幕服务中检索本集弹幕，可修改片名、季数与集数，候选将标注来源服务。",
                        12f,
                        p.textSecondary);
        desc.setLineSpacing(a.dp(2), 1f);
        box.addView(desc);
        a.gap(box, 10);

        final EditText titleEt = buildInput(a, "片名 / 剧名", initialTitle == null ? "" : initialTitle);
        box.addView(titleEt, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 8);

        LinearLayout seRow = a.row();
        final EditText seasonEt =
                buildInput(a, "季数（可选）", initialSeason > 0 ? String.valueOf(initialSeason) : "");
        seasonEt.setInputType(InputType.TYPE_CLASS_NUMBER);
        LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(0, -2, 1f);
        sLp.rightMargin = a.dp(8);
        seRow.addView(seasonEt, sLp);

        final EditText epEt =
                buildInput(a, "集数（如 1）", initialEpisode > 0 ? String.valueOf(initialEpisode) : "");
        epEt.setInputType(InputType.TYPE_CLASS_NUMBER);
        seRow.addView(epEt, new LinearLayout.LayoutParams(0, -2, 1f));
        box.addView(seRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 10);

        LinearLayout btnRow = a.row();
        final TextView searchBtn = buildPillBtn(a, "搜索本集弹幕", true);
        LinearLayout.LayoutParams srLp = new LinearLayout.LayoutParams(0, a.dp(40), 1.4f);
        srLp.rightMargin = a.dp(8);
        btnRow.addView(searchBtn, srLp);

        final TextView addSrcBtn = buildPillBtn(a, "添加新源", false);
        btnRow.addView(addSrcBtn, new LinearLayout.LayoutParams(0, a.dp(40), 1f));
        box.addView(btnRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(box, 10);

        final TextView statusTv =
                a.text(
                        enabledMultiline.isEmpty()
                                ? "当前未配置弹幕源，请先点击「添加新源」探测并添加服务。"
                                : "点击「搜索本集弹幕」查看各服务候选",
                        12.5f,
                        p.textSecondary);
        box.addView(statusTv);
        a.gap(box, 8);

        final LinearLayout resultsBox = a.vertical();
        box.addView(resultsBox, new LinearLayout.LayoutParams(-1, -2));

        final AtomicInteger searchSeq = new AtomicInteger(0);
        final MobileBottomSheet.SheetHandle handle =
                MobileBottomSheet.showCustom(a, "手动匹配本集弹幕", box, null);

        addSrcBtn.setOnClickListener(
                v -> {
                    handle.dismiss();
                    showDiscoverAndAddServiceSheet(
                            a,
                            () ->
                                    showManualMatchSheet(
                                            a,
                                            titleEt.getText().toString().trim(),
                                            parsePositiveInt(seasonEt.getText().toString()),
                                            parsePositiveInt(epEt.getText().toString()),
                                            durationSec,
                                            onSelect));
                });

        final Runnable runSearch =
                () -> {
                    final List<OnlineSubtitleDanmakuService.DanmakuSource> latestSources =
                            loadUnifiedSources(a);
                    final String originsText = enabledOriginsMultiline(latestSources);
                    if (originsText.isEmpty()) {
                        statusTv.setText("暂无已启用的弹幕服务源，请先点击「添加新源」。");
                        statusTv.setTextColor(p.danger);
                        return;
                    }
                    final String kw = titleEt.getText().toString().trim();
                    if (kw.isEmpty()) {
                        statusTv.setText("请输入片名后再搜索");
                        statusTv.setTextColor(p.danger);
                        return;
                    }
                    final int season = parsePositiveInt(seasonEt.getText().toString());
                    final int epNum = parsePositiveInt(epEt.getText().toString());
                    final int seq = searchSeq.incrementAndGet();
                    statusTv.setText("正在并发检索 " + latestSources.size() + " 个已配置弹幕服务…");
                    statusTv.setTextColor(p.accent);
                    resultsBox.removeAllViews();

                    a.worker.execute(
                            () -> {
                                try {
                                    DandanplayProvider provider =
                                            new DandanplayProvider(
                                                    originsText, cfg.appId, cfg.appSecret);
                                    DanmuProvider.MatchQuery query =
                                            new DanmuProvider.MatchQuery(
                                                    kw,
                                                    epNum > 0 ? ("第" + epNum + "集") : "",
                                                    season,
                                                    epNum,
                                                    durationSec);
                                    final List<DanmuProvider.Candidate> candidates =
                                            provider.matchOrSearch(
                                                    query, new DanmuProvider.CancellationToken());
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing() || seq != searchSeq.get())
                                                    return;
                                                resultsBox.removeAllViews();
                                                if (candidates == null || candidates.isEmpty()) {
                                                    statusTv.setText("未在已配置服务中找到候选，请调整片名或季集重试");
                                                    statusTv.setTextColor(p.textSecondary);
                                                    return;
                                                }
                                                statusTv.setText(
                                                        "找到 " + candidates.size() + " 条候选，点击即可加载：");
                                                statusTv.setTextColor(p.success);
                                                int cap = Math.min(30, candidates.size());
                                                for (int i = 0; i < cap; i++) {
                                                    final DanmuProvider.Candidate cand =
                                                            candidates.get(i);
                                                    String srcBadge =
                                                            formatCandidateSourceBadge(
                                                                    cand.sourceOrigin,
                                                                    latestSources);
                                                    LinearLayout row = a.vertical();
                                                    row.setPadding(
                                                            a.dp(12), a.dp(10), a.dp(12), a.dp(10));
                                                    row.setBackground(MobileTheme.subtleBg(a, 12));

                                                    TextView topTv =
                                                            a.text(
                                                                    (cand.animeTitle.isEmpty()
                                                                                    ? kw
                                                                                    : cand.animeTitle)
                                                                            + (cand.episodeTitle
                                                                                            .isEmpty()
                                                                                    ? ""
                                                                                    : " · "
                                                                                            + cand.episodeTitle),
                                                                    13.5f,
                                                                    p.textPrimary);
                                                    topTv.setTypeface(null, Typeface.BOLD);
                                                    topTv.setMaxLines(2);
                                                    topTv.setEllipsize(TextUtils.TruncateAt.END);
                                                    row.addView(topTv);

                                                    int pct =
                                                            Math.max(
                                                                    0,
                                                                    Math.min(
                                                                            100,
                                                                            (int)
                                                                                    Math.round(
                                                                                            cand.confidence
                                                                                                    * 100.0)));
                                                    TextView metaTv =
                                                            a.text(
                                                                    "来源服务："
                                                                            + srcBadge
                                                                            + "  ·  匹配度 "
                                                                            + pct
                                                                            + "%",
                                                                    11.5f,
                                                                    p.accent);
                                                    metaTv.setSingleLine(true);
                                                    metaTv.setEllipsize(TextUtils.TruncateAt.END);
                                                    metaTv.setPadding(0, a.dp(3), 0, 0);
                                                    row.addView(metaTv);

                                                    MobileMotion.bindPress(row, 0.97f);
                                                    row.setOnClickListener(
                                                            v -> {
                                                                handle.dismiss();
                                                                if (onSelect != null) {
                                                                    onSelect.onSelected(cand);
                                                                }
                                                            });
                                                    LinearLayout.LayoutParams rlp =
                                                            new LinearLayout.LayoutParams(-1, -2);
                                                    rlp.bottomMargin = a.dp(8);
                                                    resultsBox.addView(row, rlp);
                                                }
                                            });
                                } catch (Exception ex) {
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing() || seq != searchSeq.get())
                                                    return;
                                                statusTv.setText("检索失败：" + a.message(ex));
                                                statusTv.setTextColor(p.danger);
                                            });
                                }
                            });
                };

        searchBtn.setOnClickListener(v -> runSearch.run());
        if (!enabledMultiline.isEmpty() && initialTitle != null && !initialTitle.trim().isEmpty()) {
            runSearch.run();
        }
    }

    private static int parsePositiveInt(String raw) {
        if (raw == null) return 0;
        try {
            int v = Integer.parseInt(raw.trim());
            return Math.max(0, v);
        } catch (Exception ignored) {
            return 0;
        }
    }

    private static EditText buildInput(MainActivity a, String hint, String value) {
        MobileTheme.Palette p = MobileTheme.of(a);
        EditText et = new EditText(a);
        et.setHint(hint);
        et.setText(value);
        et.setHintTextColor(p.textTertiary);
        et.setTextColor(p.textPrimary);
        et.setTextSize(13.5f);
        et.setSingleLine(true);
        et.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
        et.setBackground(MobileTheme.subtleBg(a, 12));
        return et;
    }

    private static TextView buildPillBtn(MainActivity a, String text, boolean primary) {
        MobileTheme.Palette p = MobileTheme.of(a);
        TextView btn = a.text(text, 13f, primary ? p.accentOnFill : p.textPrimary);
        btn.setTypeface(null, Typeface.BOLD);
        btn.setGravity(Gravity.CENTER);
        btn.setSingleLine(true);
        btn.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        btn.setBackground(primary ? a.bg(p.accent, 999) : MobileTheme.subtleBg(a, 999));
        MobileMotion.bindPress(btn, 0.95f);
        return btn;
    }

    private static String readUtf8(InputStream in, int limit) throws IOException {
        if (in == null) return "";
        try (InputStream s = in) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int total = 0;
            int n;
            while ((n = s.read(buf)) != -1) {
                total += n;
                if (total > limit) throw new IOException("响应过大");
                bos.write(buf, 0, n);
            }
            return new String(bos.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}

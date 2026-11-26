package com.pilipala.marcomovie;

import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * High-value AI Cinema Copilot features for Android Mobile / Tablet (beta-gated via {@link
 * AiBetaGate}):
 *
 * <ol>
 *   <li><b>Player Spoiler-Free Recap &amp; Subtitle/Trivia Q&amp;A</b>: summarizes story arcs
 *       strictly before the current episode number and answers questions grounded in surrounding
 *       external subtitle lines at the current playback position.
 *   <li><b>Tonight's Watch AI Discovery</b>: takes natural-language mood/taste prompts plus local
 *       watch-history &amp; favorites titles (on-device titles only) and outputs clickable title
 *       cards that immediately trigger Marco Movie's native multi-source search.
 * </ol>
 */
final class AiCinemaCopilot {
    private static final Pattern EP_CN_RE = Pattern.compile("第\\s*(\\d{1,4})\\s*[集话話回期]");
    private static final Pattern EP_EN_RE = Pattern.compile("(?i)(?:S\\d{1,2})?E(\\d{1,4})\\b");
    private static final Pattern EP_NUM_RE = Pattern.compile("\\b(\\d{1,3})\\b");

    static final class Recommendation {
        final String title;
        final String year;
        final String reason;
        final List<String> tags;

        Recommendation(String title, String year, String reason, List<String> tags) {
            this.title = title;
            this.year = year;
            this.reason = reason;
            this.tags = tags;
        }
    }

    private AiCinemaCopilot() {}

    // -------------------------------------------------------------------------
    // Pure-JVM Prompt & Parser Helpers (Unit-Testable)
    // -------------------------------------------------------------------------

    /** Extracts 1-based episode number from episode label (e.g. "第08集", "S02E05"), or 0 if movie/unknown. */
    static int parseEpisodeNumber(String episodeName) {
        if (episodeName == null || episodeName.trim().isEmpty()) return 0;
        String s = episodeName.trim();
        Matcher m = EP_CN_RE.matcher(s);
        if (m.find()) return safeInt(m.group(1));
        m = EP_EN_RE.matcher(s);
        if (m.find()) return safeInt(m.group(1));
        if (s.matches("\\d{1,3}")) return safeInt(s);
        m = EP_NUM_RE.matcher(s);
        if (m.find()) {
            int n = safeInt(m.group(1));
            if (n >= 1 && n <= 200 && n != 4 && n != 720 && n != 1080) return n;
        }
        return 0;
    }

    private static int safeInt(String s) {
        try {
            return Integer.parseInt(s);
        } catch (Exception e) {
            return 0;
        }
    }

    static String buildSpoilerFreeRecapSystemPrompt(
            String showTitle, int currentEpisode, String epLabel) {
        StringBuilder sb = new StringBuilder();
        sb.append("你是严谨的防剧透影视伴看助手，请用清晰简洁的简体中文回答。");
        if (currentEpisode > 1) {
            sb.append("用户当前正准备观看《")
                    .append(showTitle)
                    .append("》的第 ")
                    .append(currentEpisode)
                    .append(" 集（")
                    .append(epLabel == null ? "" : epLabel)
                    .append("）。");
            sb.append("【绝对禁止剧透规则】只能回顾第 1 集至第 ")
                    .append(currentEpisode - 1)
                    .append(" 集已经发生的主线剧情与核心人物关系；严禁提及第 ")
                    .append(currentEpisode)
                    .append(" 集及之后任何反转、结局、死亡或未揭示身份！");
        } else if (currentEpisode == 1) {
            sb.append("用户刚开始观看《")
                    .append(showTitle)
                    .append("》第 1 集。【绝对禁止剧透规则】仅介绍无剧透的世界观背景、主要角色初始身份与看点，严禁透露第 1 集及后续任何情节发展或反转。");
        } else {
            sb.append("用户正在观看《")
                    .append(showTitle)
                    .append("》。【绝对禁止剧透规则】仅提供无剧透的背景设定与核心人物介绍，严禁透露中后段转折与结局。");
        }
        sb.append("输出控制在 220~350 字，分「主线脉络」与「核心人物」两小节。");
        return sb.toString();
    }

    static String buildSubtitleQaUserPrompt(
            String showTitle,
            String epLabel,
            long positionMs,
            String subtitleContext,
            String userQuestion) {
        StringBuilder sb = new StringBuilder();
        sb.append("影片：《").append(showTitle == null ? "" : showTitle).append("》");
        if (epLabel != null && !epLabel.trim().isEmpty()) {
            sb.append(" / 当前分集：").append(epLabel.trim());
        }
        if (positionMs > 0) {
            sb.append(" / 进度：").append(AiSubtitleTranslator.formatShortClock(positionMs));
        }
        sb.append('\n');
        if (subtitleContext != null && !subtitleContext.trim().isEmpty()) {
            sb.append("当前时间点附近字幕台词：\n").append(subtitleContext.trim()).append("\n\n");
        }
        sb.append("用户提问：").append(userQuestion == null ? "" : userQuestion.trim());
        return sb.toString();
    }

    static List<Recommendation> parseRecommendations(String rawReply) {
        List<Recommendation> out = new ArrayList<>();
        JSONObject root = AiAssistantService.extractJsonObject(rawReply);
        if (root == null) return out;
        JSONArray arr = root.optJSONArray("recommendations");
        if (arr == null) arr = root.optJSONArray("items");
        if (arr == null) return out;
        for (int i = 0; i < arr.length() && out.size() < 8; i++) {
            JSONObject item = arr.optJSONObject(i);
            if (item == null) continue;
            String title = item.optString("title", "").trim();
            if (title.isEmpty()) continue;
            String year = item.optString("year", "").trim();
            String reason = item.optString("reason", "").trim();
            List<String> tags = new ArrayList<>();
            JSONArray tArr = item.optJSONArray("tags");
            if (tArr != null) {
                for (int j = 0; j < tArr.length() && tags.size() < 3; j++) {
                    String tag = tArr.optString(j, "").trim();
                    if (!tag.isEmpty()) tags.add(tag);
                }
            }
            out.add(new Recommendation(title, year, reason, tags));
        }
        return out;
    }

    static String collectLocalTasteSummary(MainActivity a) {
        if (a == null || a.privateMode || a.prefs == null) return "";
        Set<String> titles = new LinkedHashSet<>();
        try {
            List<WatchHistory.Entry> hist =
                    WatchHistory.read(a.prefs.getString(Prefs.WATCH_HISTORY, "[]"));
            for (WatchHistory.Entry e : hist) {
                if (e != null && e.title != null && !e.title.trim().isEmpty()) {
                    titles.add(e.title.trim());
                }
                if (titles.size() >= 10) break;
            }
        } catch (Exception ignored) {
        }
        try {
            List<Favorites.Entry> favs = Favorites.read(a.prefs.getString(Prefs.FAVORITES, "[]"));
            for (Favorites.Entry e : favs) {
                if (e != null && e.title != null && !e.title.trim().isEmpty()) {
                    titles.add(e.title.trim());
                }
                if (titles.size() >= 18) break;
            }
        } catch (Exception ignored) {
        }
        if (titles.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        int idx = 0;
        for (String t : titles) {
            if (idx++ > 0) sb.append("、");
            sb.append(t);
        }
        return sb.toString();
    }

    // -------------------------------------------------------------------------
    // Feature 2 UI: Player Spoiler-Free Recap & Subtitle/Trivia Q&A Sheet
    // -------------------------------------------------------------------------

    static void showPlayerCopilotSheet(
            final MainActivity a,
            final Cms.Video video,
            final Cms.Episode episode,
            final long positionMs,
            final File activeSubtitleFile) {
        if (a == null || a.isFinishing()) return;
        if (!AiBetaGate.isUnlocked(a)) {
            AiBetaGate.showUnlockSheet(a, null);
            return;
        }
        if (!AiAssistantService.isConfigured(a)) {
            a.toast("请先在「设置 → AI 观影实验室」中配置 API Key 或登录订阅账号");
            return;
        }
        final MobileTheme.Palette p = MobileTheme.of(a);
        final String title =
                video != null && video.title != null && !video.title.trim().isEmpty()
                        ? video.title.trim()
                        : "当前影片";
        final String epLabel = episode != null && episode.name != null ? episode.name.trim() : "";
        final int epNum = parseEpisodeNumber(epLabel);
        final String subtitleSnippet =
                AiSubtitleTranslator.extractContextAroundFile(
                        activeSubtitleFile, positionMs, 18000L);

        LinearLayout body = a.vertical();
        body.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        // Context banner
        String ctxText =
                epNum > 1
                        ? ("防剧透保护已锁定：仅回顾第 1~" + (epNum - 1) + " 集，绝不剧透当前及后续分集")
                        : ("当前影片：《" + title + "》" + (epLabel.isEmpty() ? "" : (" · " + epLabel)));
        TextView ctxBanner = a.text(ctxText, 12f, p.accent);
        ctxBanner.setTypeface(null, Typeface.BOLD);
        ctxBanner.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
        ctxBanner.setBackground(a.bg(MobileTheme.withAlpha(p.accent, p.isDark ? 0x26 : 0x16), 12));
        body.addView(ctxBanner, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 10);

        if (!subtitleSnippet.isEmpty()) {
            LinearLayout subBox = a.vertical();
            subBox.setPadding(a.dp(12), a.dp(9), a.dp(12), a.dp(9));
            subBox.setBackground(a.bg(p.bgSubtle, 12));
            TextView subHdr =
                    a.text(
                            "已捕获当前进度（"
                                    + AiSubtitleTranslator.formatShortClock(positionMs)
                                    + "）附近字幕台词：",
                            11.5f,
                            p.textSecondary);
            subHdr.setTypeface(null, Typeface.BOLD);
            subBox.addView(subHdr);
            a.gap(subBox, 4);
            TextView subLines = a.text(subtitleSnippet, 12f, p.textPrimary);
            subLines.setMaxLines(4);
            subLines.setEllipsize(TextUtils.TruncateAt.END);
            subLines.setLineSpacing(a.dp(2f), 1f);
            subBox.addView(subLines);
            body.addView(subBox, new LinearLayout.LayoutParams(-1, -2));
            a.gap(body, 10);
        }

        // Answer card
        final TextView answerTv =
                a.text("点击下方「生成防剧透前情提要」或快捷提问，也可输入你想了解的台词、典故与人物关系。", 13.5f, p.textSecondary);
        answerTv.setLineSpacing(a.dp(4f), 1f);
        answerTv.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
        answerTv.setBackground(a.bg(p.bgSubtle, 14));
        body.addView(answerTv, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 10);

        // Quick action chips
        LinearLayout quickRow = a.row();
        String[] quickLabels = {epNum > 1 ? "防剧透前情提要" : "无剧透背景导览", "解释当前台词/典故", "梳理主要人物关系"};
        final Runnable[] runPrompt = new Runnable[1];
        final String[] pendingQuestion = {""};
        final boolean[] isRecapMode = {false};

        for (int i = 0; i < quickLabels.length; i++) {
            final int idx = i;
            TextView chip = a.text(quickLabels[i], 12f, i == 0 ? p.accentOnFill : p.textPrimary);
            chip.setTypeface(null, Typeface.BOLD);
            chip.setSingleLine(true);
            chip.setGravity(Gravity.CENTER);
            chip.setPadding(a.dp(10), a.dp(8), a.dp(10), a.dp(8));
            chip.setBackground(i == 0 ? MobileTheme.accentPillBg(a, 10) : a.bg(p.bgSubtle, 10));
            MobileMotion.bindPress(chip, 0.94f);
            chip.setOnClickListener(
                    v -> {
                        if (idx == 0) {
                            isRecapMode[0] = true;
                            pendingQuestion[0] = "请生成严格防剧透的前情提要与人物梳理。";
                        } else if (idx == 1) {
                            isRecapMode[0] = false;
                            pendingQuestion[0] =
                                    subtitleSnippet.isEmpty()
                                            ? "请介绍本片常见的专有名词、文化典故或隐喻（不要剧透后续剧情）。"
                                            : "请结合上述台词解释其中的典故、双关语、背景含义或潜台词（不要剧透后续剧情）。";
                        } else {
                            isRecapMode[0] = false;
                            pendingQuestion[0] = "请用简洁列表梳理截至目前的主要人物与他们之间的关系（严禁剧透后续反转）。";
                        }
                        runPrompt[0].run();
                    });
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (i < quickLabels.length - 1) clp.rightMargin = a.dp(6);
            quickRow.addView(chip, clp);
        }
        body.addView(quickRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 10);

        // Custom question row
        LinearLayout askRow = a.row();
        askRow.setGravity(Gravity.CENTER_VERTICAL);
        final EditText qInput = new EditText(a);
        qInput.setHint("输入关于剧情、人物或台词的问题…");
        qInput.setTextColor(p.textPrimary);
        qInput.setHintTextColor(p.textTertiary);
        qInput.setTextSize(13.5f);
        qInput.setSingleLine(true);
        qInput.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        qInput.setBackground(MobileTheme.subtleBg(a, 12));
        askRow.addView(qInput, new LinearLayout.LayoutParams(0, a.dp(42), 1f));

        TextView sendBtn = a.text("提问", 13.5f, p.accentOnFill);
        sendBtn.setTypeface(null, Typeface.BOLD);
        sendBtn.setGravity(Gravity.CENTER);
        sendBtn.setPadding(a.dp(16), 0, a.dp(16), 0);
        sendBtn.setBackground(MobileTheme.accentPillBg(a, 12));
        MobileMotion.bindPress(sendBtn, 0.94f);
        sendBtn.setOnClickListener(
                v -> {
                    String q = qInput.getText().toString().trim();
                    if (q.isEmpty()) {
                        MobileMotion.shakeInvalid(qInput);
                        return;
                    }
                    isRecapMode[0] = false;
                    pendingQuestion[0] = q;
                    runPrompt[0].run();
                });
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-2, a.dp(42));
        slp.leftMargin = a.dp(8);
        askRow.addView(sendBtn, slp);
        body.addView(askRow, new LinearLayout.LayoutParams(-1, -2));

        runPrompt[0] =
                () -> {
                    final String question = pendingQuestion[0];
                    final boolean recap = isRecapMode[0];
                    answerTv.setTextColor(p.textSecondary);
                    answerTv.setText("正在向 AI 思考整理（已开启防剧透约束）…");
                    final String cacheKey =
                            recap
                                    ? ("recap_"
                                            + AiAssistantService.sha256(
                                                    title + "|" + epNum + "|" + epLabel))
                                    : null;
                    a.worker.execute(
                            () -> {
                                try {
                                    if (cacheKey != null) {
                                        String cached =
                                                AiAssistantService.readDiskCache(a, cacheKey);
                                        if (cached != null && !cached.trim().isEmpty()) {
                                            final String out = cached.trim();
                                            a.ui.post(
                                                    () -> {
                                                        answerTv.setTextColor(p.textPrimary);
                                                        answerTv.setText(out);
                                                    });
                                            return;
                                        }
                                    }
                                    String sys =
                                            buildSpoilerFreeRecapSystemPrompt(
                                                    title, epNum, epLabel);
                                    String usr =
                                            buildSubtitleQaUserPrompt(
                                                    title,
                                                    epLabel,
                                                    positionMs,
                                                    recap ? "" : subtitleSnippet,
                                                    question);
                                    String reply =
                                            AiAssistantService.chatCompletion(
                                                    a, sys, usr, 900, 0.35);
                                    final String clean =
                                            reply == null || reply.trim().isEmpty()
                                                    ? "模型未返回有效内容，请稍后重试。"
                                                    : reply.trim();
                                    if (cacheKey != null
                                            && reply != null
                                            && !reply.trim().isEmpty()) {
                                        AiAssistantService.writeDiskCache(a, cacheKey, clean);
                                    }
                                    a.ui.post(
                                            () -> {
                                                answerTv.setTextColor(p.textPrimary);
                                                answerTv.setText(clean);
                                            });
                                } catch (Exception e) {
                                    final String err =
                                            "AI 请求失败："
                                                    + AiAuthManager.sanitizeLogBody(a.message(e));
                                    a.ui.post(
                                            () -> {
                                                answerTv.setTextColor(p.danger);
                                                answerTv.setText(err);
                                            });
                                }
                            });
                };

        MobileBottomSheet.showHandle(
                a, "AI 剧情与台词助手", "防剧透前情提要 · 结合当前字幕实时问答", null, null, body, true);
    }

    // -------------------------------------------------------------------------
    // Feature 3 UI: "今晚看什么 · AI 找片" Local Discovery Sheet
    // -------------------------------------------------------------------------

    static void showDiscoverySheet(
            final MainActivity a, final AiAssistantService.ResultCallback<String> onPickTitle) {
        if (a == null || a.isFinishing()) return;
        if (!AiBetaGate.isUnlocked(a)) {
            AiBetaGate.showUnlockSheet(a, null);
            return;
        }
        if (!AiAssistantService.isConfigured(a)) {
            a.toast("请先在「设置 → AI 观影实验室」中配置 API Key 或登录订阅账号");
            return;
        }
        final MobileTheme.Palette p = MobileTheme.of(a);
        final String tasteTitles = collectLocalTasteSummary(a);
        final MobileBottomSheet.SheetHandle[] hRef = new MobileBottomSheet.SheetHandle[1];

        LinearLayout body = a.vertical();
        body.setPadding(a.dp(2), a.dp(4), a.dp(2), a.dp(4));

        String subBanner =
                tasteTitles.isEmpty()
                        ? "输入你想看的心情、题材或节奏，点击推荐片名即可直接在你已订阅的片源中检索。"
                        : ("已参考你本机最近观看/收藏片单（仅片名，不上传地址与账号），点击结果即可搜源播放。");
        TextView hintTv = a.text(subBanner, 12f, p.textSecondary);
        hintTv.setLineSpacing(a.dp(3f), 1f);
        hintTv.setPadding(a.dp(2), 0, a.dp(2), a.dp(10));
        body.addView(hintTv);

        // Input row
        LinearLayout inputRow = a.row();
        inputRow.setGravity(Gravity.CENTER_VERTICAL);
        final EditText moodInput = new EditText(a);
        moodInput.setHint("例如：90 分钟以内轻松下饭喜剧，或类似《三体》的硬核科幻…");
        moodInput.setTextColor(p.textPrimary);
        moodInput.setHintTextColor(p.textTertiary);
        moodInput.setTextSize(13.5f);
        moodInput.setSingleLine(true);
        moodInput.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
        moodInput.setBackground(MobileTheme.subtleBg(a, 12));
        inputRow.addView(moodInput, new LinearLayout.LayoutParams(0, a.dp(42), 1f));

        TextView goBtn = a.text("推荐", 13.5f, p.accentOnFill);
        goBtn.setTypeface(null, Typeface.BOLD);
        goBtn.setGravity(Gravity.CENTER);
        goBtn.setPadding(a.dp(16), 0, a.dp(16), 0);
        goBtn.setBackground(MobileTheme.accentPillBg(a, 12));
        MobileMotion.bindPress(goBtn, 0.94f);
        LinearLayout.LayoutParams gLp = new LinearLayout.LayoutParams(-2, a.dp(42));
        gLp.leftMargin = a.dp(8);
        inputRow.addView(goBtn, gLp);
        body.addView(inputRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 10);

        // Mood quick chips
        LinearLayout chipRow = a.row();
        String[] presets = {"按我历史品味推荐", "下饭轻松90分钟", "高分烧脑悬疑", "周末连刷好剧"};
        final Runnable[] doSearch = new Runnable[1];
        for (int i = 0; i < presets.length; i++) {
            final String preset = presets[i];
            TextView c = a.text(preset, 11.5f, p.textPrimary);
            c.setSingleLine(true);
            c.setGravity(Gravity.CENTER);
            c.setPadding(a.dp(8), a.dp(7), a.dp(8), a.dp(7));
            c.setBackground(a.bg(p.bgSubtle, 999));
            MobileMotion.bindPress(c, 0.94f);
            c.setOnClickListener(
                    v -> {
                        moodInput.setText(preset);
                        moodInput.setSelection(preset.length());
                        doSearch[0].run();
                    });
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0, -2, 1f);
            if (i < presets.length - 1) clp.rightMargin = a.dp(5);
            chipRow.addView(c, clp);
        }
        body.addView(chipRow, new LinearLayout.LayoutParams(-1, -2));
        a.gap(body, 12);

        final TextView statusTv = a.text("", 12.5f, p.textSecondary);
        statusTv.setVisibility(View.GONE);
        body.addView(statusTv, new LinearLayout.LayoutParams(-1, -2));

        final LinearLayout resultsBox = a.vertical();
        body.addView(resultsBox, new LinearLayout.LayoutParams(-1, -2));

        doSearch[0] =
                () -> {
                    final String prompt = moodInput.getText().toString().trim();
                    if (prompt.isEmpty()) {
                        MobileMotion.shakeInvalid(moodInput);
                        return;
                    }
                    resultsBox.removeAllViews();
                    statusTv.setTextColor(p.textSecondary);
                    statusTv.setText("正在为你挑选 5 部高口碑作品…");
                    statusTv.setVisibility(View.VISIBLE);
                    a.worker.execute(
                            () -> {
                                try {
                                    String sys =
                                            "你是资深私人选片顾问。根据用户心情需求和近期看过的片名，推荐 5 部真实存在、豆瓣/IMDb 口碑优秀的影视作品（不要推荐用户已经看过的片名）。"
                                                    + "严格只输出 JSON 对象：{\"recommendations\":[{\"title\":\"中文常用片名\",\"year\":\"年份\",\"reason\":\"35字内推荐理由（无剧透）\",\"tags\":[\"标签1\",\"标签2\"]}]}。";
                                    StringBuilder usr = new StringBuilder();
                                    usr.append("用户想看：").append(prompt);
                                    if (!tasteTitles.isEmpty()) {
                                        usr.append("\n用户近期观看/收藏片单：").append(tasteTitles);
                                    }
                                    String reply =
                                            AiAssistantService.chatCompletion(
                                                    a, sys, usr.toString(), 1100, 0.65);
                                    final List<Recommendation> recs = parseRecommendations(reply);
                                    a.ui.post(
                                            () -> {
                                                if (a.isFinishing()) return;
                                                if (recs.isEmpty()) {
                                                    statusTv.setTextColor(p.danger);
                                                    statusTv.setText("未能解析出推荐片单，请换个说法重试。");
                                                    return;
                                                }
                                                statusTv.setTextColor(p.textSecondary);
                                                statusTv.setText("点击任意影片卡片即可立即聚合搜索片源：");
                                                resultsBox.removeAllViews();
                                                for (final Recommendation rec : recs) {
                                                    resultsBox.addView(
                                                            buildRecommendationCard(
                                                                    a,
                                                                    p,
                                                                    rec,
                                                                    () -> {
                                                                        if (hRef[0] != null) {
                                                                            hRef[0].dismiss();
                                                                        }
                                                                        if (onPickTitle != null) {
                                                                            onPickTitle.onResult(
                                                                                    rec.title);
                                                                        }
                                                                    }));
                                                }
                                            });
                                } catch (Exception e) {
                                    final String err =
                                            "AI 找片失败："
                                                    + AiAuthManager.sanitizeLogBody(a.message(e));
                                    a.ui.post(
                                            () -> {
                                                statusTv.setTextColor(p.danger);
                                                statusTv.setText(err);
                                            });
                                }
                            });
                };

        goBtn.setOnClickListener(v -> doSearch[0].run());

        hRef[0] =
                MobileBottomSheet.showHandle(
                        a, "今晚看什么 · AI 找片", "自然语言选片 · 一键直达本地多源检索", null, null, body, true);
    }

    private static View buildRecommendationCard(
            MainActivity a, MobileTheme.Palette p, Recommendation rec, Runnable onClick) {
        LinearLayout card = a.vertical();
        card.setPadding(a.dp(13), a.dp(11), a.dp(13), a.dp(11));
        card.setBackground(a.bg(p.bgSubtle, 14));
        MobileMotion.bindPress(card, 0.97f);
        card.setOnClickListener(v -> onClick.run());

        LinearLayout top = a.row();
        top.setGravity(Gravity.CENTER_VERTICAL);
        String heading = rec.year.isEmpty() ? rec.title : (rec.title + " (" + rec.year + ")");
        TextView titleTv = a.text(heading, 14.5f, p.textPrimary);
        titleTv.setTypeface(null, Typeface.BOLD);
        titleTv.setSingleLine(true);
        titleTv.setEllipsize(TextUtils.TruncateAt.END);
        top.addView(titleTv, new LinearLayout.LayoutParams(0, -2, 1f));

        TextView goTag = a.text("去搜源", 12f, p.accent);
        goTag.setTypeface(null, Typeface.BOLD);
        top.addView(goTag);
        card.addView(top, new LinearLayout.LayoutParams(-1, -2));

        if (!rec.reason.isEmpty()) {
            a.gap(card, 4);
            TextView reasonTv = a.text(rec.reason, 12.5f, p.textSecondary);
            reasonTv.setLineSpacing(a.dp(2.5f), 1f);
            card.addView(reasonTv);
        }

        if (!rec.tags.isEmpty()) {
            a.gap(card, 6);
            LinearLayout tagRow = a.row();
            for (int i = 0; i < rec.tags.size(); i++) {
                TextView t = a.text(rec.tags.get(i), 11f, p.accent);
                t.setPadding(a.dp(8), a.dp(3), a.dp(8), a.dp(3));
                t.setBackground(a.bg(MobileTheme.withAlpha(p.accent, p.isDark ? 0x26 : 0x18), 999));
                LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(-2, -2);
                if (i < rec.tags.size() - 1) tlp.rightMargin = a.dp(6);
                tagRow.addView(t, tlp);
            }
            card.addView(tagRow);
        }

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.topMargin = a.dp(8);
        card.setLayoutParams(lp);
        return card;
    }
}

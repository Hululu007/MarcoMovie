// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

/**
 * Clean-room segmented danmu provider contract shared across Android runtime and pure-JVM offline
 * checks. Contains zero Android framework dependencies and zero hardcoded server addresses or keys.
 */
public interface DanmuProvider {

    final class CancellationToken {
        private final AtomicBoolean cancelled = new AtomicBoolean(false);
        private final List<Runnable> hooks = new ArrayList<>();

        public boolean isCancelled() {
            return cancelled.get();
        }

        public void cancel() {
            if (!cancelled.compareAndSet(false, true)) return;
            List<Runnable> snapshot;
            synchronized (hooks) {
                snapshot = new ArrayList<>(hooks);
                hooks.clear();
            }
            for (Runnable hook : snapshot) {
                try {
                    hook.run();
                } catch (Throwable ignored) {
                }
            }
        }

        public void onCancel(Runnable hook) {
            if (hook == null) return;
            boolean runNow = false;
            synchronized (hooks) {
                if (cancelled.get()) {
                    runNow = true;
                } else {
                    hooks.add(hook);
                }
            }
            if (runNow) {
                try {
                    hook.run();
                } catch (Throwable ignored) {
                }
            }
        }

        public void removeCancelHook(Runnable hook) {
            if (hook == null) return;
            synchronized (hooks) {
                hooks.remove(hook);
            }
        }

        public void throwIfCancelled() throws IOException {
            if (cancelled.get()) {
                throw new CancelledException("Danmu request cancelled");
            }
        }
    }

    final class CancelledException extends IOException {
        public CancelledException(String message) {
            super(message);
        }
    }

    final class HttpStatusException extends IOException {
        public final int statusCode;
        public final long retryAfterMs;

        public HttpStatusException(int statusCode, String message) {
            this(statusCode, message, 0L);
        }

        public HttpStatusException(int statusCode, String message, long retryAfterMs) {
            super(message);
            this.statusCode = statusCode;
            this.retryAfterMs = Math.max(0L, retryAfterMs);
        }
    }

    final class MatchQuery {
        public final String title;
        public final String episodeTitle;
        public final int episodeIndex;
        public final long durationSec;

        public MatchQuery(String title, String episodeTitle, int episodeIndex, long durationSec) {
            this.title = title == null ? "" : title;
            this.episodeTitle = episodeTitle == null ? "" : episodeTitle;
            this.episodeIndex = episodeIndex;
            this.durationSec = Math.max(0L, durationSec);
        }
    }

    final class Candidate {
        public final String sourceOrigin;
        public final String animeId;
        public final String animeTitle;
        public final String boundEpisodeId; // mmdanmu://v1?src=...&ep=...
        public final String episodeTitle;
        public final double confidence;

        public Candidate(
                String sourceOrigin,
                String animeId,
                String animeTitle,
                String boundEpisodeId,
                String episodeTitle,
                double confidence) {
            this.sourceOrigin = sourceOrigin == null ? "" : sourceOrigin;
            this.animeId = animeId == null ? "" : animeId;
            this.animeTitle = animeTitle == null ? "" : animeTitle;
            this.boundEpisodeId = boundEpisodeId == null ? "" : boundEpisodeId;
            this.episodeTitle = episodeTitle == null ? "" : episodeTitle;
            this.confidence = confidence;
        }
    }

    final class SegmentDescriptor {
        public final long startMs;
        public final long endMs;
        public final String segmentUrl;

        public SegmentDescriptor(long startMs, long endMs, String segmentUrl) {
            this.startMs = startMs;
            this.endMs = endMs;
            this.segmentUrl = segmentUrl == null ? "" : segmentUrl;
        }
    }

    final class EpisodeSession {
        public final String boundEpisodeId;
        public final boolean segmented;
        public final List<SegmentDescriptor> segments; // empty when FULL_EPISODE
        public final List<DanmuItem> preloadComments; // populated when FULL_EPISODE

        public EpisodeSession(
                String boundEpisodeId,
                boolean segmented,
                List<SegmentDescriptor> segments,
                List<DanmuItem> preloadComments) {
            this.boundEpisodeId = boundEpisodeId == null ? "" : boundEpisodeId;
            this.segmented = segmented;
            this.segments =
                    segments == null
                            ? Collections.<SegmentDescriptor>emptyList()
                            : Collections.unmodifiableList(new ArrayList<>(segments));
            this.preloadComments =
                    preloadComments == null
                            ? Collections.<DanmuItem>emptyList()
                            : Collections.unmodifiableList(new ArrayList<>(preloadComments));
        }
    }

    final class DanmuItem {
        public final String id;
        public final long timeMs;
        public final int mode; // 1=scroll, 4=bottom, 5=top
        public final int rgbColor;
        public final String text;

        public DanmuItem(String id, long timeMs, int mode, int rgbColor, String text) {
            this.id = id == null ? "" : id;
            this.timeMs = timeMs;
            this.mode = mode;
            this.rgbColor = rgbColor & 0xFFFFFF;
            this.text = text == null ? "" : text;
        }
    }

    /**
     * O(N) user block filter with strict single-pass static ReDoS rejection for {@code re:} rules.
     */
    final class BlockFilter {
        public static final int MAX_RULES = 100;
        public static final int MAX_REGEX_LENGTH = 120;
        public static final int MAX_WILDCARDS = 3;
        public static final BlockFilter EMPTY = new BlockFilter(new String[0], new Pattern[0]);

        public static final class ValidationResult {
            public final boolean valid;
            public final String error;

            public ValidationResult(boolean valid, String error) {
                this.valid = valid;
                this.error = error == null ? "" : error;
            }

            public static ValidationResult ok() {
                return new ValidationResult(true, "");
            }

            public static ValidationResult fail(String reason) {
                return new ValidationResult(false, reason);
            }
        }

        private final String[] plainLowerRules;
        private final Pattern[] regexRules;

        private BlockFilter(String[] plainLowerRules, Pattern[] regexRules) {
            this.plainLowerRules = plainLowerRules;
            this.regexRules = regexRules;
        }

        public static ValidationResult validateRule(String rawRule) {
            if (rawRule == null) return ValidationResult.fail("屏蔽规则不能为空");
            String trimmed = rawRule.trim();
            if (trimmed.isEmpty()) return ValidationResult.fail("屏蔽规则不能为空");
            if (!trimmed.startsWith("re:")) {
                return ValidationResult.ok();
            }
            String expr = trimmed.substring(3);
            if (expr.isEmpty()) return ValidationResult.fail("正则表达式不能为空");
            if (expr.length() > MAX_REGEX_LENGTH) {
                return ValidationResult.fail("正则表达式长度超过 120 字符上限");
            }
            boolean inCharClass = false;
            int wildcardCount = 0;
            int len = expr.length();
            for (int i = 0; i < len; i++) {
                char ch = expr.charAt(i);
                if (ch == '\\') {
                    if (i + 1 >= len) {
                        return ValidationResult.fail("正则表达式以未闭合转义符结尾");
                    }
                    char next = expr.charAt(i + 1);
                    if (!inCharClass && next >= '1' && next <= '9') {
                        return ValidationResult.fail("禁止使用正则反向引用");
                    }
                    i++;
                    continue;
                }
                if (inCharClass) {
                    if (ch == ']') {
                        inCharClass = false;
                    }
                    continue;
                }
                if (ch == '[') {
                    inCharClass = true;
                    if (i + 1 < len && expr.charAt(i + 1) == '^') {
                        i++;
                    }
                    if (i + 1 < len && expr.charAt(i + 1) == ']') {
                        i++;
                    }
                    continue;
                }
                if (ch == '(' && i + 1 < len && expr.charAt(i + 1) == '?') {
                    if (i + 2 < len) {
                        char m = expr.charAt(i + 2);
                        if (m == '<') {
                            return ValidationResult.fail("禁止使用正则后行断言");
                        }
                        if (m == '-' || (m >= 'a' && m <= 'z') || (m >= 'A' && m <= 'Z')) {
                            return ValidationResult.fail("禁止使用正则内联修饰符");
                        }
                    }
                }
                if (ch == '.' && i + 1 < len) {
                    char next = expr.charAt(i + 1);
                    if (next == '*' || next == '+') {
                        wildcardCount++;
                        if (wildcardCount > MAX_WILDCARDS) {
                            return ValidationResult.fail("通配符 .* / .+ 超过 3 次上限");
                        }
                    }
                }
                if (ch == ')' && i + 1 < len) {
                    char next = expr.charAt(i + 1);
                    if (next == '*' || next == '+' || next == '?' || next == '{') {
                        return ValidationResult.fail("禁止闭合括号后紧跟量词以防回溯风险");
                    }
                }
            }
            try {
                Pattern.compile(expr, Pattern.CASE_INSENSITIVE);
            } catch (PatternSyntaxException e) {
                return ValidationResult.fail("正则表达式语法错误: " + e.getDescription());
            }
            return ValidationResult.ok();
        }

        public static BlockFilter compile(List<String> rawRules) {
            if (rawRules == null || rawRules.isEmpty()) return EMPTY;
            List<String> plains = new ArrayList<>();
            List<Pattern> regexes = new ArrayList<>();
            int accepted = 0;
            for (String raw : rawRules) {
                if (accepted >= MAX_RULES) break;
                if (raw == null) continue;
                String trimmed = raw.trim();
                if (trimmed.isEmpty()) continue;
                ValidationResult vr = validateRule(trimmed);
                if (!vr.valid) continue;
                if (trimmed.startsWith("re:")) {
                    regexes.add(Pattern.compile(trimmed.substring(3), Pattern.CASE_INSENSITIVE));
                } else {
                    plains.add(trimmed.toLowerCase(Locale.ROOT));
                }
                accepted++;
            }
            if (plains.isEmpty() && regexes.isEmpty()) return EMPTY;
            return new BlockFilter(plains.toArray(new String[0]), regexes.toArray(new Pattern[0]));
        }

        public boolean isEmpty() {
            return plainLowerRules.length == 0 && regexRules.length == 0;
        }

        public int ruleCount() {
            return plainLowerRules.length + regexRules.length;
        }

        public boolean isBlocked(String text) {
            if (text == null || text.isEmpty() || isEmpty()) return false;
            if (plainLowerRules.length > 0) {
                String lower = text.toLowerCase(Locale.ROOT);
                for (int i = 0; i < plainLowerRules.length; i++) {
                    if (lower.contains(plainLowerRules[i])) return true;
                }
            }
            for (int i = 0; i < regexRules.length; i++) {
                if (regexRules[i].matcher(text).find()) return true;
            }
            return false;
        }
    }

    List<Candidate> matchOrSearch(MatchQuery query, CancellationToken token) throws IOException;

    List<Candidate> listEpisodes(String sourceOrigin, String animeId, CancellationToken token)
            throws IOException;

    EpisodeSession openSession(String boundEpisodeId, CancellationToken token) throws IOException;

    List<DanmuItem> fetchWindow(EpisodeSession session, int windowIndex, CancellationToken token)
            throws IOException;
}

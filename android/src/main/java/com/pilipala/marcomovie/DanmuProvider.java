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
     * O(N) user block filter with strict whitelist recursive-descent static ReDoS rejection for
     * {@code re:} rules. Keeps validation semantics 100% identical to Dart {@code DanmuBlockFilter}.
     */
    final class BlockFilter {
        public static final int MAX_RULES = 100;
        public static final int MAX_REGEX_LENGTH = 120;
        public static final int MAX_WILDCARDS = 3;
        public static final int MAX_GROUP_DEPTH = 6;
        public static final int MAX_QUANTIFIER_BOUND = 64;
        public static final int MAX_UNBOUNDED_PER_BRANCH = 1;
        public static final int MAX_VAR_QUANTS_PER_BRANCH = 2;
        public static final int MAX_BOUNDED_BRANCH_CHOICES = 32;
        public static final int MAX_BRANCH_CHOICES = 550;
        public static final int MAX_TOTAL_CHOICES = 600;
        private static final int UNBOUNDED_CHOICE_COST = 181;
        private static final int CHOICE_CAP = MAX_TOTAL_CHOICES + 1;
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

        private static final class BranchStats {
            final int unboundedQuants;
            final int varQuants;
            final int choices;

            BranchStats(int unboundedQuants, int varQuants, int choices) {
                this.unboundedQuants = unboundedQuants;
                this.varQuants = varQuants;
                this.choices = choices;
            }
        }

        private static final class QuantStats {
            static final QuantStats NONE = new QuantStats(0, 0, 1);
            final int unbounded;
            final int varQuant;
            final int choices;

            QuantStats(int unbounded, int varQuant, int choices) {
                this.unbounded = unbounded;
                this.varQuant = varQuant;
                this.choices = choices;
            }
        }

        private static final class SafeRegexValidator {
            private final String expr;
            private final int len;
            private int pos;
            private int wildcardCount;
            private int groupDepth;
            private String error;

            SafeRegexValidator(String expr) {
                this.expr = expr;
                this.len = expr.length();
            }

            ValidationResult validate() {
                BranchStats root = parseAlternation(true);
                if (error != null) {
                    return ValidationResult.fail(error);
                }
                if (pos != len) {
                    return ValidationResult.fail("正则表达式包含多余的闭合括号");
                }
                if (root == null || root.choices > MAX_TOTAL_CHOICES) {
                    return ValidationResult.fail("正则表达式总回溯分支复杂度过高");
                }
                return ValidationResult.ok();
            }

            private void fail(String reason) {
                if (error == null) {
                    error = reason;
                }
            }

            private static int satAdd(int a, int b) {
                long s = (long) a + (long) b;
                return s >= CHOICE_CAP ? CHOICE_CAP : (int) s;
            }

            private static int satMul(int a, int b) {
                long p = (long) a * (long) b;
                return p >= CHOICE_CAP ? CHOICE_CAP : (int) p;
            }

            private static boolean isQuantStart(char ch) {
                return ch == '*' || ch == '+' || ch == '?' || ch == '{';
            }

            private static boolean isHexDigit(char ch) {
                return (ch >= '0' && ch <= '9')
                        || (ch >= 'a' && ch <= 'f')
                        || (ch >= 'A' && ch <= 'F');
            }

            private static boolean isAsciiPunctuation(char ch) {
                if (ch < 0x21 || ch > 0x7E) return false;
                if (ch >= '0' && ch <= '9') return false;
                if (ch >= 'a' && ch <= 'z') return false;
                if (ch >= 'A' && ch <= 'Z') return false;
                return ch != '_';
            }

            private BranchStats parseAlternation(boolean isTopLevel) {
                BranchStats first = parseBranch();
                if (error != null) return null;
                if (isTopLevel && first.choices > MAX_BRANCH_CHOICES) {
                    fail("正则表达式回溯复杂度过高");
                    return null;
                }
                int maxUnbounded = first.unboundedQuants;
                int maxVar = first.varQuants;
                int sumChoices = first.choices;
                while (pos < len && expr.charAt(pos) == '|') {
                    pos++;
                    BranchStats next = parseBranch();
                    if (error != null) return null;
                    if (isTopLevel && next.choices > MAX_BRANCH_CHOICES) {
                        fail("正则表达式回溯复杂度过高");
                        return null;
                    }
                    if (next.unboundedQuants > maxUnbounded) {
                        maxUnbounded = next.unboundedQuants;
                    }
                    if (next.varQuants > maxVar) {
                        maxVar = next.varQuants;
                    }
                    sumChoices = satAdd(sumChoices, next.choices);
                    if (isTopLevel && sumChoices > MAX_TOTAL_CHOICES) {
                        fail("正则表达式总回溯分支复杂度过高");
                        return null;
                    }
                }
                return new BranchStats(maxUnbounded, maxVar, sumChoices);
            }

            private BranchStats parseBranch() {
                int unbounded = 0;
                int varQuants = 0;
                int choices = 1;
                int atomCount = 0;

                while (pos < len) {
                    char ch = expr.charAt(pos);
                    if (ch == '|' || ch == ')') {
                        break;
                    }
                    atomCount++;

                    if (ch == '(') {
                        pos++;
                        if (pos < len && expr.charAt(pos) == '?') {
                            if (pos + 1 < len && expr.charAt(pos + 1) == ':') {
                                pos += 2;
                            } else if (pos + 1 < len) {
                                char m = expr.charAt(pos + 1);
                                if (m == '<') {
                                    fail("禁止使用正则后行断言");
                                } else if (m == '-'
                                        || (m >= 'a' && m <= 'z')
                                        || (m >= 'A' && m <= 'Z')) {
                                    fail("禁止使用正则内联修饰符");
                                } else if (m == '=' || m == '!') {
                                    fail("禁止使用正则环视断言");
                                } else {
                                    fail("禁止使用不受支持的正则扩展分组");
                                }
                                return null;
                            } else {
                                fail("正则表达式语法错误: 未闭合分组");
                                return null;
                            }
                        }
                        groupDepth++;
                        if (groupDepth > MAX_GROUP_DEPTH) {
                            fail("正则分组嵌套层数超过上限");
                            return null;
                        }
                        BranchStats inner = parseAlternation(false);
                        if (error != null) return null;
                        groupDepth--;
                        if (pos >= len || expr.charAt(pos) != ')') {
                            fail("正则表达式语法错误: 未闭合括号");
                            return null;
                        }
                        pos++;
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止闭合括号后紧跟量词以防回溯风险");
                            return null;
                        }
                        unbounded += inner.unboundedQuants;
                        varQuants += inner.varQuants;
                        choices = satMul(choices, inner.choices);
                        if (!checkBranchBudget(unbounded, varQuants, choices)) {
                            return null;
                        }
                        continue;
                    }

                    if (isQuantStart(ch)) {
                        fail("量词缺少前置匹配项");
                        return null;
                    }
                    if (ch == '}' || ch == ']') {
                        fail("正则表达式包含未转义的闭合符号");
                        return null;
                    }
                    if (ch == '^' || ch == '$') {
                        pos++;
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止对零宽断言使用量词");
                            return null;
                        }
                        continue;
                    }

                    boolean isDot = false;
                    if (ch == '[') {
                        parseCharClass();
                        if (error != null) return null;
                    } else if (ch == '\\') {
                        boolean isZeroWidthAnchor = parseOutsideEscape();
                        if (error != null) return null;
                        if (isZeroWidthAnchor) {
                            if (pos < len && isQuantStart(expr.charAt(pos))) {
                                fail("禁止对零宽断言使用量词");
                                return null;
                            }
                            continue;
                        }
                    } else if (ch == '.') {
                        pos++;
                        isDot = true;
                    } else {
                        pos++;
                    }

                    QuantStats q = parseQuantifier(isDot);
                    if (error != null) return null;
                    unbounded += q.unbounded;
                    varQuants += q.varQuant;
                    choices = satMul(choices, q.choices);
                    if (!checkBranchBudget(unbounded, varQuants, choices)) {
                        return null;
                    }
                }

                if (atomCount == 0) {
                    fail("正则表达式禁止空分支或空分组");
                    return null;
                }
                return new BranchStats(unbounded, varQuants, choices);
            }

            private boolean checkBranchBudget(int unbounded, int varQuants, int choices) {
                if (unbounded > MAX_UNBOUNDED_PER_BRANCH) {
                    fail("禁止同分支内组合多个无界量词以防回溯风险");
                    return false;
                }
                if (varQuants > MAX_VAR_QUANTS_PER_BRANCH) {
                    fail("禁止同分支内组合过多可变长量词以防回溯风险");
                    return false;
                }
                int limit = unbounded == 0 ? MAX_BOUNDED_BRANCH_CHOICES : MAX_BRANCH_CHOICES;
                if (choices > limit) {
                    fail("正则表达式回溯复杂度过高");
                    return false;
                }
                return true;
            }

            private QuantStats parseQuantifier(boolean isDot) {
                if (pos >= len) return QuantStats.NONE;
                char q = expr.charAt(pos);
                if (q == '*' || q == '+') {
                    pos++;
                    if (isDot) {
                        wildcardCount++;
                        if (wildcardCount > MAX_WILDCARDS) {
                            fail("通配符 .* / .+ 超过 3 次上限");
                            return null;
                        }
                    }
                    if (pos < len && expr.charAt(pos) == '?') {
                        pos++;
                    }
                    if (pos < len && isQuantStart(expr.charAt(pos))) {
                        fail("禁止堆叠或占有型量词");
                        return null;
                    }
                    return new QuantStats(1, 1, UNBOUNDED_CHOICE_COST);
                }
                if (q == '?') {
                    pos++;
                    if (pos < len && isQuantStart(expr.charAt(pos))) {
                        fail("禁止堆叠或占有型量词");
                        return null;
                    }
                    return new QuantStats(0, 1, 2);
                }
                if (q == '{') {
                    pos++;
                    int minVal = parseBoundedInt();
                    if (error != null) return null;
                    if (pos >= len) {
                        fail("正则表达式量词花括号未闭合");
                        return null;
                    }
                    char sep = expr.charAt(pos);
                    if (sep == '}') {
                        pos++;
                        if (minVal == 0) {
                            fail("禁止使用零次量词");
                            return null;
                        }
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止堆叠或占有型量词");
                            return null;
                        }
                        return QuantStats.NONE;
                    }
                    if (sep == ',') {
                        pos++;
                        if (pos < len && expr.charAt(pos) == '}') {
                            pos++;
                            if (isDot) {
                                wildcardCount++;
                                if (wildcardCount > MAX_WILDCARDS) {
                                    fail("通配符 .* / .+ 超过 3 次上限");
                                    return null;
                                }
                            }
                            if (pos < len && expr.charAt(pos) == '?') {
                                pos++;
                            }
                            if (pos < len && isQuantStart(expr.charAt(pos))) {
                                fail("禁止堆叠或占有型量词");
                                return null;
                            }
                            return new QuantStats(1, 1, UNBOUNDED_CHOICE_COST);
                        }
                        int maxVal = parseBoundedInt();
                        if (error != null) return null;
                        if (pos >= len || expr.charAt(pos) != '}') {
                            fail("正则表达式量词花括号格式无效");
                            return null;
                        }
                        pos++;
                        if (maxVal < minVal) {
                            fail("正则表达式量词上限小于下限");
                            return null;
                        }
                        if (maxVal == 0) {
                            fail("禁止使用零次量词");
                            return null;
                        }
                        if (maxVal == minVal) {
                            if (pos < len && isQuantStart(expr.charAt(pos))) {
                                fail("禁止堆叠或占有型量词");
                                return null;
                            }
                            return QuantStats.NONE;
                        }
                        if (pos < len && expr.charAt(pos) == '?') {
                            pos++;
                        }
                        if (pos < len && isQuantStart(expr.charAt(pos))) {
                            fail("禁止堆叠或占有型量词");
                            return null;
                        }
                        return new QuantStats(0, 1, maxVal - minVal + 1);
                    }
                    fail("正则表达式量词花括号格式无效");
                    return null;
                }
                return QuantStats.NONE;
            }

            private int parseBoundedInt() {
                int start = pos;
                int val = 0;
                while (pos < len) {
                    char d = expr.charAt(pos);
                    if (d < '0' || d > '9') break;
                    val = val * 10 + (d - '0');
                    if (val > MAX_QUANTIFIER_BOUND) {
                        fail("正则表达式量词数值超过 64 上限");
                        return -1;
                    }
                    pos++;
                }
                if (pos == start) {
                    fail("正则表达式量词花括号缺少数字");
                    return -1;
                }
                return val;
            }

            private boolean parseOutsideEscape() {
                pos++; // consume '\'
                if (pos >= len) {
                    fail("正则表达式以未闭合转义符结尾");
                    return false;
                }
                char next = expr.charAt(pos);
                if ((next >= '1' && next <= '9') || next == 'k') {
                    fail("禁止使用正则反向引用");
                    return false;
                }
                if (next == 'b' || next == 'B') {
                    pos++;
                    return true;
                }
                if (next == 'd'
                        || next == 'D'
                        || next == 'w'
                        || next == 'W'
                        || next == 's'
                        || next == 'S'
                        || next == 't'
                        || next == 'n'
                        || next == 'r'
                        || next == 'f') {
                    pos++;
                    return false;
                }
                if (next == 'x') {
                    pos++;
                    parseFixedHexEscape(2);
                    return false;
                }
                if (next == 'u') {
                    pos++;
                    parseFixedHexEscape(4);
                    return false;
                }
                if (isAsciiPunctuation(next)) {
                    pos++;
                    return false;
                }
                fail("禁止使用不受支持的正则转义序列");
                return false;
            }

            private int parseFixedHexEscape(int digits) {
                if (pos + digits > len) {
                    fail("正则十六进制转义位数不足");
                    return -1;
                }
                int value = 0;
                for (int i = 0; i < digits; i++) {
                    char h = expr.charAt(pos + i);
                    if (!isHexDigit(h)) {
                        fail("正则十六进制转义格式无效");
                        return -1;
                    }
                    int nibble =
                            h <= '9' ? (h - '0') : (h <= 'F' ? (h - 'A' + 10) : (h - 'a' + 10));
                    value = (value << 4) | nibble;
                }
                pos += digits;
                return value;
            }

            private void parseCharClass() {
                pos++; // consume '['
                if (pos < len && expr.charAt(pos) == '^') {
                    pos++;
                }
                int itemCount = 0;
                boolean prevWasSingleChar = false;
                int prevCharCode = -1;
                boolean pendingRange = false;

                while (pos < len && expr.charAt(pos) != ']') {
                    char c = expr.charAt(pos);
                    if (c == '[') {
                        fail("禁止在字符类中使用未转义的 [");
                        return;
                    }
                    if (c == '&' && pos + 1 < len && expr.charAt(pos + 1) == '&') {
                        fail("禁止在字符类中使用交集语法");
                        return;
                    }
                    if (c == '-'
                            && !pendingRange
                            && itemCount > 0
                            && pos + 1 < len
                            && expr.charAt(pos + 1) != ']') {
                        if (!prevWasSingleChar) {
                            fail("字符类范围不能以简写字符类作为起点");
                            return;
                        }
                        pos++;
                        pendingRange = true;
                        continue;
                    }

                    boolean isSingleChar;
                    int charCode;
                    if (c == '\\') {
                        pos++;
                        if (pos >= len) {
                            fail("正则表达式以未闭合转义符结尾");
                            return;
                        }
                        char next = expr.charAt(pos);
                        if (next == 'd'
                                || next == 'D'
                                || next == 'w'
                                || next == 'W'
                                || next == 's'
                                || next == 'S') {
                            pos++;
                            isSingleChar = false;
                            charCode = -1;
                        } else if (next == 't') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\t';
                        } else if (next == 'n') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\n';
                        } else if (next == 'r') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\r';
                        } else if (next == 'f') {
                            pos++;
                            isSingleChar = true;
                            charCode = '\f';
                        } else if (next == 'x') {
                            pos++;
                            charCode = parseFixedHexEscape(2);
                            if (error != null) return;
                            isSingleChar = true;
                        } else if (next == 'u') {
                            pos++;
                            charCode = parseFixedHexEscape(4);
                            if (error != null) return;
                            isSingleChar = true;
                        } else if (isAsciiPunctuation(next)) {
                            pos++;
                            isSingleChar = true;
                            charCode = next;
                        } else {
                            fail("禁止在字符类中使用不受支持的转义序列");
                            return;
                        }
                    } else {
                        pos++;
                        isSingleChar = true;
                        charCode = c;
                    }

                    if (pendingRange) {
                        if (!isSingleChar) {
                            fail("字符类范围不能以简写字符类作为终点");
                            return;
                        }
                        if (charCode < prevCharCode) {
                            fail("字符类范围起点大于终点");
                            return;
                        }
                        pendingRange = false;
                        prevWasSingleChar = false;
                    } else {
                        prevWasSingleChar = isSingleChar;
                        prevCharCode = charCode;
                    }
                    itemCount++;
                }

                if (pos >= len || expr.charAt(pos) != ']') {
                    fail("字符类未闭合");
                    return;
                }
                pos++; // consume ']'
                if (itemCount == 0) {
                    fail("字符类不能为空");
                }
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
            ValidationResult staticCheck = new SafeRegexValidator(expr).validate();
            if (!staticCheck.valid) {
                return staticCheck;
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

package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Search ranking and exact-title matching utilities for {@link MobileSearchPage}.
 *
 * <p>Exact mode compares against the original raw video title BEFORE any title cleaning or
 * cross-source aggregation so sequels, subtitles, and edition tags (for example {@code 《我的三体》},
 * {@code 《三体2》}, {@code 《三体：周年纪念版》}) are strictly excluded when searching for {@code 三体}.
 * Fuzzy mode prioritizes exact hits and cross-source consensus matches across providers.
 */
final class SearchRanking {
    private SearchRanking() {}

    /**
     * Trims ONLY leading and trailing whitespace without altering internal spaces, case, or CJK
     * brackets. Exact mode compares titles strictly with this function so {@code IT}/{@code It},
     * differing internal spaces, and {@code 《三体》}/{@code 三体} remain distinct.
     */
    static String normalizeExactTitle(String raw) {
        if (raw == null) return "";
        int start = 0;
        int end = raw.length();
        while (start < end && isTrimWhitespace(raw.charAt(start))) start++;
        while (end > start && isTrimWhitespace(raw.charAt(end - 1))) end--;
        return raw.substring(start, end);
    }

    private static boolean isTrimWhitespace(char c) {
        return Character.isWhitespace(c) || c == '\u3000' || c == '\u00A0';
    }

    /** Normalization used solely for fuzzy-mode consensus grouping & ranking. */
    static String normalizeFuzzyTitle(String raw) {
        if (raw == null) return "";
        String s = raw.replace('\u3000', ' ').trim();
        while (s.length() >= 2 && isWrappedByMatchingBrackets(s)) {
            s = s.substring(1, s.length() - 1).trim();
        }
        StringBuilder sb = new StringBuilder(s.length());
        boolean lastSpace = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (Character.isWhitespace(c)) {
                if (!lastSpace) {
                    sb.append(' ');
                    lastSpace = true;
                }
            } else {
                sb.append(c);
                lastSpace = false;
            }
        }
        return sb.toString().trim().toLowerCase(Locale.ROOT);
    }

    private static boolean isWrappedByMatchingBrackets(String s) {
        char first = s.charAt(0);
        char last = s.charAt(s.length() - 1);
        char expectedClose;
        if (first == '《') expectedClose = '》';
        else if (first == '「') expectedClose = '」';
        else if (first == '『') expectedClose = '』';
        else if (first == '〈') expectedClose = '〉';
        else if (first == '【') expectedClose = '】';
        else return false;
        if (last != expectedClose) return false;
        int depth = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == first) depth++;
            else if (c == expectedClose) {
                depth--;
                if (depth == 0 && i < s.length() - 1) {
                    return false;
                }
            }
        }
        return depth == 0;
    }

    /**
     * Returns {@code true} iff {@code rawTitle} (edge-trimmed only) equals {@code keyword}
     * (edge-trimmed only) on the exact original full title.
     */
    static boolean isExactTitleMatch(String rawTitle, String keyword) {
        String normKey = normalizeExactTitle(keyword);
        if (normKey.isEmpty()) return false;
        String normTitle = normalizeExactTitle(rawTitle);
        return !normTitle.isEmpty() && normTitle.equals(normKey);
    }

    /**
     * Filters (in exact mode) or ranks (in fuzzy mode) search hits.
     *
     * <p>Exact mode retains ALL hits across different sources whose original {@code video.title}
     * matches {@code keyword} via {@link #isExactTitleMatch}. Fuzzy mode puts exact matches first,
     * then prioritizes titles present across more distinct sources, while preserving all hits.
     */
    static List<MobileSearchPage.Hit> rankAndFilter(
            List<MobileSearchPage.Hit> hits, String keyword, boolean exactMode) {
        List<MobileSearchPage.Hit> out = new ArrayList<>();
        if (hits == null || hits.isEmpty()) return out;

        if (exactMode) {
            for (int i = 0; i < hits.size(); i++) {
                MobileSearchPage.Hit h = hits.get(i);
                if (h != null && h.video != null && isExactTitleMatch(h.video.title, keyword)) {
                    out.add(h);
                }
            }
            return out;
        }

        final String normKey = normalizeFuzzyTitle(keyword);
        // Count distinct sources per fuzzy-normalized title for cross-source consensus boost.
        Map<String, Set<String>> sourcesByTitle = new HashMap<>();
        for (int i = 0; i < hits.size(); i++) {
            MobileSearchPage.Hit h = hits.get(i);
            if (h == null || h.video == null) continue;
            String tKey = normalizeFuzzyTitle(h.video.title);
            if (tKey.isEmpty()) continue;
            Set<String> set = sourcesByTitle.get(tKey);
            if (set == null) {
                set = new HashSet<>();
                sourcesByTitle.put(tKey, set);
            }
            String sKey = h.site != null && h.site.key != null ? h.site.key : ("idx-" + i);
            set.add(sKey);
        }

        List<RankedHit> ranked = new ArrayList<>(hits.size());
        for (int i = 0; i < hits.size(); i++) {
            MobileSearchPage.Hit h = hits.get(i);
            if (h == null || h.video == null) continue;
            String rawTitle = h.video.title == null ? "" : h.video.title;
            String normTitle = normalizeFuzzyTitle(rawTitle);
            int tier = computeFuzzyTier(rawTitle, normTitle, normKey);
            Set<String> srcs = sourcesByTitle.get(normTitle);
            int sourceCount = srcs != null ? srcs.size() : 1;
            ranked.add(new RankedHit(h, tier, sourceCount, i));
        }

        Collections.sort(
                ranked,
                new Comparator<RankedHit>() {
                    @Override
                    public int compare(RankedHit a, RankedHit b) {
                        if (a.tier != b.tier) {
                            return a.tier < b.tier ? -1 : 1;
                        }
                        if (a.sourceCount != b.sourceCount) {
                            return a.sourceCount > b.sourceCount ? -1 : 1;
                        }
                        return a.originalIndex < b.originalIndex
                                ? -1
                                : (a.originalIndex > b.originalIndex ? 1 : 0);
                    }
                });

        for (int i = 0; i < ranked.size(); i++) {
            out.add(ranked.get(i).hit);
        }
        return out;
    }

    private static int computeFuzzyTier(String rawTitle, String normTitle, String normKey) {
        if (normKey.isEmpty() || normTitle.isEmpty()) return 4;
        if (normTitle.equals(normKey)) return 0;
        String cleaned = normalizeExactTitle(EpisodeNameCleaner.cleanSearchTitle(rawTitle));
        if (!cleaned.isEmpty() && cleaned.equals(normKey)) return 1;
        if (normTitle.startsWith(normKey)) return 2;
        if (normTitle.contains(normKey)) return 3;
        return 4;
    }

    private static final class RankedHit {
        final MobileSearchPage.Hit hit;
        final int tier;
        final int sourceCount;
        final int originalIndex;

        RankedHit(MobileSearchPage.Hit hit, int tier, int sourceCount, int originalIndex) {
            this.hit = hit;
            this.tier = tier;
            this.sourceCount = sourceCount;
            this.originalIndex = originalIndex;
        }
    }
}

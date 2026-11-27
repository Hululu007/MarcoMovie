package com.pilipala.marcomovie;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Centralized Android TV search match modes, strict NFKC normalization, admission predicates, and
 * tiered ranking shared across initial fetch, variants, pagination, single-source retry, and
 * cross-source wall rendering.
 *
 * <p>Pure JVM (zero Android framework imports) so offline acceptance tests execute the exact same
 * production logic.
 */
final class TvSearchMatcher {
    enum Mode {
        EXACT("exact", "精准搜索"),
        FUZZY("fuzzy", "模糊搜索");

        final String prefValue;
        final String label;

        Mode(String prefValue, String label) {
            this.prefValue = prefValue;
            this.label = label;
        }

        static Mode fromPref(String raw) {
            if (FUZZY.prefValue.equalsIgnoreCase(raw == null ? "" : raw.trim())) {
                return FUZZY;
            }
            return EXACT;
        }
    }

    /** Match tiers (lower is higher priority). TIER_NONE rejects the entry from admission. */
    static final int TIER_EXACT = 0;

    static final int TIER_PREFIX = 1;
    static final int TIER_CONTAINS = 2;
    static final int TIER_PHONETIC = 3;
    static final int TIER_NONE = 99;

    private static final Pattern MULTI_SPACE = Pattern.compile("\\s+");
    private static final Pattern LATIN_OR_DIGIT_QUERY = Pattern.compile("^[a-z0-9' -]+$");
    private static final Pattern ALPHA_ONLY_OR_PINYIN = Pattern.compile("^[a-z' -]+$");

    private TvSearchMatcher() {}

    /**
     * Strict title/query normalization:
     * <ul>
     *   <li>Unicode NFKC (folds full-width Latin/digits/ideographic spaces cleanly)</li>
     *   <li>trim leading/trailing whitespace and collapse repeated whitespace to a single space</li>
     *   <li>{@code Locale.ROOT} lowercase folding</li>
     *   <li>PRESERVES meaningful punctuation (e.g. {@code C++} vs {@code C}), digits, season tags
     *       ({@code 第一季}/{@code 第二季}), sequel numerals, editions, and subtitles</li>
     * </ul>
     */
    static String normalizeStrict(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String nfkc = Normalizer.normalize(raw, Normalizer.Form.NFKC);
        String trimmed = nfkc.trim();
        if (trimmed.isEmpty()) return "";
        return MULTI_SPACE.matcher(trimmed).replaceAll(" ").toLowerCase(Locale.ROOT);
    }

    /** Returns true when {@code raw} contains only ASCII or Unicode whitespace (e.g. U+3000, U+00A0). */
    static boolean isBlankQuery(String raw) {
        return normalizeStrict(raw).isEmpty();
    }

    /**
     * Builds query recall terms sent to remote sources for the given mode.
     *
     * <p>In {@link Mode#EXACT}, never expands pinyin/initials or sequel rewrites — only sends the
     * user's literal query (plus NFKC-folded query if full-width characters differ, so literal CMS
     * APIs can return e.g. {@code Alien} when searching {@code 　ＡＬＩＥＮ　}).
     *
     * <p>In {@link Mode#FUZZY}, preserves pinyin/initials and sequel numeral recall terms while
     * still enforcing strict local relevance admission on every returned item.
     */
    static List<String> buildRecallTerms(Mode mode, String rawQuery, PhoneticSearchIndex phonetic) {
        if (isBlankQuery(rawQuery)) return Collections.emptyList();
        String trimmed = rawQuery.trim();
        Mode effective = mode == null ? Mode.EXACT : mode;
        LinkedHashSet<String> terms = new LinkedHashSet<>();
        String nfkc =
                MULTI_SPACE
                        .matcher(Normalizer.normalize(trimmed, Normalizer.Form.NFKC).trim())
                        .replaceAll(" ");
        if (effective == Mode.EXACT) {
            if (!nfkc.isEmpty()) terms.add(nfkc);
            if (!trimmed.isEmpty()) terms.add(trimmed);
            return new ArrayList<>(terms);
        }
        String queryForRecall = !nfkc.isEmpty() ? nfkc : trimmed;
        List<String> base =
                phonetic == null
                        ? Collections.singletonList(queryForRecall)
                        : phonetic.searchTerms(queryForRecall);
        return SearchVariants.mergeTerms(queryForRecall, base);
    }

    /**
     * Evaluates match tier for a {@link Cms.Video} against {@code rawQuery} under {@code mode}.
     * Returns {@link #TIER_NONE} when the item MUST be excluded.
     */
    static int matchTier(
            Mode mode, String rawQuery, Cms.Video video, PhoneticSearchIndex phonetic) {
        if (video == null) return TIER_NONE;
        return matchTier(mode, rawQuery, video.title, video.aliases, phonetic);
    }

    /**
     * Evaluates match tier for a title and optional explicit alias list against {@code rawQuery}.
     * Only explicit, source-provided aliases are considered — never descriptions, actors, or tags.
     */
    static int matchTier(
            Mode mode,
            String rawQuery,
            String rawTitle,
            List<String> explicitAliases,
            PhoneticSearchIndex phonetic) {
        String normQ = normalizeStrict(rawQuery);
        if (normQ.isEmpty()) return TIER_NONE;
        Mode effective = mode == null ? Mode.EXACT : mode;

        String normTitle = normalizeStrict(rawTitle);
        boolean exactTitle = !normTitle.isEmpty() && normTitle.equals(normQ);
        boolean exactAlias = false;
        if (!exactTitle && explicitAliases != null && !explicitAliases.isEmpty()) {
            for (int i = 0, n = explicitAliases.size(); i < n; i++) {
                String aNorm = normalizeStrict(explicitAliases.get(i));
                if (!aNorm.isEmpty() && aNorm.equals(normQ)) {
                    exactAlias = true;
                    break;
                }
            }
        }
        if (exactTitle || exactAlias) {
            return TIER_EXACT;
        }
        if (effective == Mode.EXACT) {
            return TIER_NONE;
        }

        // FUZZY mode: Tier 1 Prefix -> Tier 2 Contains -> Tier 3 Trusted Pinyin/Initials
        if (!normTitle.isEmpty() && normTitle.startsWith(normQ)) {
            return TIER_PREFIX;
        }
        if (explicitAliases != null && !explicitAliases.isEmpty()) {
            for (int i = 0, n = explicitAliases.size(); i < n; i++) {
                String aNorm = normalizeStrict(explicitAliases.get(i));
                if (!aNorm.isEmpty() && aNorm.startsWith(normQ)) {
                    return TIER_PREFIX;
                }
            }
        }

        // Sequel-numeral equivalence in FUZZY mode only (e.g. "斗罗大陆2" <-> "斗罗大陆II绝世唐门"),
        // guarded so punctuation-sensitive tokens like "C++" never collapse into "C".
        boolean sequelQuery = SearchVariants.sequelVariants(rawQuery).size() > 1;
        String canonQ = sequelQuery ? SearchVariants.canonicalSearchKey(rawQuery) : "";
        if (sequelQuery && !canonQ.isEmpty()) {
            String canonTitle = SearchVariants.canonicalSearchKey(rawTitle);
            if (!canonTitle.isEmpty() && canonTitle.startsWith(canonQ)) {
                return TIER_PREFIX;
            }
            if (explicitAliases != null) {
                for (int i = 0, n = explicitAliases.size(); i < n; i++) {
                    String ca = SearchVariants.canonicalSearchKey(explicitAliases.get(i));
                    if (!ca.isEmpty() && ca.startsWith(canonQ)) {
                        return TIER_PREFIX;
                    }
                }
            }
        }

        if (!normTitle.isEmpty() && normTitle.contains(normQ)) {
            return TIER_CONTAINS;
        }
        if (explicitAliases != null && !explicitAliases.isEmpty()) {
            for (int i = 0, n = explicitAliases.size(); i < n; i++) {
                String aNorm = normalizeStrict(explicitAliases.get(i));
                if (!aNorm.isEmpty() && aNorm.contains(normQ)) {
                    return TIER_CONTAINS;
                }
            }
        }
        if (sequelQuery && !canonQ.isEmpty()) {
            String canonTitle = SearchVariants.canonicalSearchKey(rawTitle);
            if (!canonTitle.isEmpty() && canonTitle.contains(canonQ)) {
                return TIER_CONTAINS;
            }
            if (explicitAliases != null) {
                for (int i = 0, n = explicitAliases.size(); i < n; i++) {
                    String ca = SearchVariants.canonicalSearchKey(explicitAliases.get(i));
                    if (!ca.isEmpty() && ca.contains(canonQ)) {
                        return TIER_CONTAINS;
                    }
                }
            }
        }

        // Trusted local phonetic/initials matching (FUZZY mode only, ASCII latin/pinyin input).
        if (phonetic != null
                && normQ.length() >= 2
                && LATIN_OR_DIGIT_QUERY.matcher(normQ).matches()
                && ALPHA_ONLY_OR_PINYIN.matcher(normQ).find()) {
            if (rawTitle != null && !rawTitle.isEmpty() && phonetic.matches(rawTitle, normQ)) {
                return TIER_PHONETIC;
            }
            if (explicitAliases != null && !explicitAliases.isEmpty()) {
                for (int i = 0, n = explicitAliases.size(); i < n; i++) {
                    String alias = explicitAliases.get(i);
                    if (alias != null && !alias.isEmpty() && phonetic.matches(alias, normQ)) {
                        return TIER_PHONETIC;
                    }
                }
            }
        }
        return TIER_NONE;
    }

    static boolean matches(
            Mode mode, String rawQuery, Cms.Video video, PhoneticSearchIndex phonetic) {
        return matchTier(mode, rawQuery, video, phonetic) != TIER_NONE;
    }

    static boolean matches(
            Mode mode,
            String rawQuery,
            String rawTitle,
            List<String> explicitAliases,
            PhoneticSearchIndex phonetic) {
        return matchTier(mode, rawQuery, rawTitle, explicitAliases, phonetic) != TIER_NONE;
    }

    /** Unified admission predicate + tier ranker passed through SearchVariants and TvSearchPages. */
    static final class VideoMatcher
            implements SearchVariants.VideoMatch, SearchVariants.VideoRanker {
        final Mode mode;
        final String rawQuery;
        final PhoneticSearchIndex phonetic;

        VideoMatcher(Mode mode, String rawQuery, PhoneticSearchIndex phonetic) {
            this.mode = mode == null ? Mode.EXACT : mode;
            this.rawQuery = rawQuery == null ? "" : rawQuery;
            this.phonetic = phonetic;
        }

        @Override
        public boolean test(Cms.Video video) {
            return matches(mode, rawQuery, video, phonetic);
        }

        @Override
        public void rank(List<Cms.Video> videos, String siteName) {
            rankSourceVideos(mode, rawQuery, videos, siteName, phonetic);
        }
    }

    static SearchVariants.VideoMatch videoPredicate(
            final Mode mode, final String rawQuery, final PhoneticSearchIndex phonetic) {
        return new VideoMatcher(mode, rawQuery, phonetic);
    }

    static SearchVariants.Match titlePredicate(
            final Mode mode, final String rawQuery, final PhoneticSearchIndex phonetic) {
        return title -> matches(mode, rawQuery, title, null, phonetic);
    }

    /**
     * Ranks admitted videos within a single source by match tier first, then non-comic preference
     * (in fuzzy mode unless user asked for comic/short-drama), preserving original order on ties.
     */
    static void rankSourceVideos(
            final Mode mode,
            final String rawQuery,
            List<Cms.Video> videos,
            final String siteName,
            final PhoneticSearchIndex phonetic) {
        if (videos == null || videos.size() <= 1) return;
        final boolean allowComic = SearchVariants.wantsComicOrShortDrama(rawQuery);
        final int n = videos.size();
        final List<Cms.Video> copy = new ArrayList<>(videos);
        final int[] tiers = new int[n];
        final boolean[] comics = new boolean[n];
        final Integer[] indices = new Integer[n];
        for (int i = 0; i < n; i++) {
            Cms.Video v = copy.get(i);
            tiers[i] = matchTier(mode, rawQuery, v, phonetic);
            comics[i] =
                    !allowComic
                            && tiers[i] > TIER_EXACT
                            && SearchVariants.isComicOrShortDrama(v, siteName);
            indices[i] = Integer.valueOf(i);
        }
        java.util.Arrays.sort(
                indices,
                new Comparator<Integer>() {
                    @Override
                    public int compare(Integer ia, Integer ib) {
                        int a = ia.intValue();
                        int b = ib.intValue();
                        int c = Integer.compare(tiers[a], tiers[b]);
                        if (c != 0) return c;
                        if (comics[a] != comics[b]) return comics[a] ? 1 : -1;
                        return Integer.compare(a, b);
                    }
                });
        for (int i = 0; i < n; i++) {
            videos.set(i, copy.get(indices[i].intValue()));
        }
    }

    /**
     * Escapes {@code %} and {@code :} so {@link #stableKey(String, String)} is bijective across
     * arbitrary {@code (siteKey, vodId)} pairs while leaving plain keys (without colons or percent
     * signs) unchanged.
     */
    static String encodeKeyPart(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        int len = raw.length();
        boolean needsEscape = false;
        for (int i = 0; i < len; i++) {
            char c = raw.charAt(i);
            if (c == '%' || c == ':') {
                needsEscape = true;
                break;
            }
        }
        if (!needsEscape) return raw;
        StringBuilder sb = new StringBuilder(len + 8);
        for (int i = 0; i < len; i++) {
            char c = raw.charAt(i);
            if (c == '%') sb.append("%25");
            else if (c == ':') sb.append("%3A");
            else sb.append(c);
        }
        return sb.toString();
    }

    /** Exact inverse of {@link #encodeKeyPart(String)}. */
    static String decodeKeyPart(String encoded) {
        if (encoded == null || encoded.isEmpty()) return "";
        if (encoded.indexOf('%') < 0) return encoded;
        int len = encoded.length();
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) {
            char c = encoded.charAt(i);
            if (c == '%' && i + 2 < len) {
                char h1 = encoded.charAt(i + 1);
                char h2 = encoded.charAt(i + 2);
                if (h1 == '3' && (h2 == 'A' || h2 == 'a')) {
                    sb.append(':');
                    i += 2;
                    continue;
                }
                if (h1 == '2' && h2 == '5') {
                    sb.append('%');
                    i += 2;
                    continue;
                }
            }
            sb.append(c);
        }
        return sb.toString();
    }

    /** Bijective canonical string key for a {@code (siteKey, vodId)} pair. */
    static String stableKey(String siteKey, String vodId) {
        return encodeKeyPart(siteKey) + ":" + encodeKeyPart(vodId);
    }

    /** Unambiguous two-field identity for a search hit ({@code siteKey}, {@code vodId}). */
    static final class HitId {
        final String siteKey;
        final String vodId;

        HitId(String siteKey, String vodId) {
            this.siteKey = siteKey == null ? "" : siteKey;
            this.vodId = vodId == null ? "" : vodId;
        }

        String stableKey() {
            return TvSearchMatcher.stableKey(siteKey, vodId);
        }

        /**
         * Decodes a canonical {@link #stableKey()} containing exactly one unescaped {@code ':'}.
         * Returns {@code null} for malformed or legacy unencoded multi-colon strings.
         */
        static HitId parseKey(String rawKey) {
            if (rawKey == null || rawKey.isEmpty()) return null;
            int sep = rawKey.indexOf(':');
            if (sep <= 0 || rawKey.indexOf(':', sep + 1) >= 0) return null;
            String site = decodeKeyPart(rawKey.substring(0, sep));
            String vod = decodeKeyPart(rawKey.substring(sep + 1));
            if (site.isEmpty() || vod.isEmpty()) return null;
            return new HitId(site, vod);
        }

        @Override
        public boolean equals(Object obj) {
            if (this == obj) return true;
            if (!(obj instanceof HitId)) return false;
            HitId other = (HitId) obj;
            return siteKey.equals(other.siteKey) && vodId.equals(other.vodId);
        }

        @Override
        public int hashCode() {
            return 31 * siteKey.hashCode() + vodId.hashCode();
        }

        @Override
        public String toString() {
            return stableKey();
        }
    }

    /** Flat cross-source candidate for global wall sorting and deterministic deduplication. */
    static final class RankedHit {
        final Cms.Site site;
        final Cms.Video video;
        final HitId hitId;
        final int tier;
        final boolean exactTitle;
        final boolean comicPenalty;
        final boolean preferredSite;
        final int siteRank;
        final int itemIndex;

        RankedHit(
                Cms.Site site,
                Cms.Video video,
                int tier,
                boolean exactTitle,
                boolean comicPenalty,
                boolean preferredSite,
                int siteRank,
                int itemIndex) {
            this.site = site;
            this.video = video;
            this.hitId = new HitId(site == null ? "" : site.key, video == null ? "" : video.id);
            this.tier = tier;
            this.exactTitle = exactTitle;
            this.comicPenalty = comicPenalty;
            this.preferredSite = preferredSite;
            this.siteRank = siteRank;
            this.itemIndex = itemIndex;
        }

        HitId hitId() {
            return hitId;
        }

        String stableKey() {
            return hitId.stableKey();
        }
    }

    /**
     * Collects, filters, deduplicates by exact two-field {@link HitId} {@code (siteKey, vodId)}
     * (NEVER collapsing distinct sites or colliding colon-delimited pairs), and sorts hits strictly
     * by:
     * <ol>
     *   <li>Match tier ({@code EXACT -> PREFIX -> CONTAINS -> PHONETIC})</li>
     *   <li>Within the same tier: comic/short-drama deprioritization (fuzzy non-exact only),
     *       source preference, site order, and original index</li>
     * </ol>
     */
    static List<RankedHit> collectAndRank(
            Mode mode,
            String rawQuery,
            List<GlobalSearchScreen.SourceResult> sources,
            String activeFilter,
            String preferredSiteKey,
            PhoneticSearchIndex phonetic) {
        String normQ = normalizeStrict(rawQuery);
        if (normQ.isEmpty() || sources == null || sources.isEmpty()) {
            return Collections.emptyList();
        }
        boolean allowComic = SearchVariants.wantsComicOrShortDrama(rawQuery);
        List<RankedHit> out = new ArrayList<>();
        LinkedHashSet<HitId> seenIds = new LinkedHashSet<>();
        for (int sIdx = 0; sIdx < sources.size(); sIdx++) {
            GlobalSearchScreen.SourceResult sr = sources.get(sIdx);
            if (sr == null || sr.site == null || sr.videos == null) continue;
            if (activeFilter != null
                    && !activeFilter.isEmpty()
                    && !activeFilter.equals(sr.site.key)) {
                continue;
            }
            boolean pref =
                    preferredSiteKey != null
                            && !preferredSiteKey.isEmpty()
                            && preferredSiteKey.equals(sr.site.key);
            for (int i = 0; i < sr.videos.size(); i++) {
                Cms.Video v = sr.videos.get(i);
                if (v == null || v.id == null || v.id.isEmpty() || v.id.startsWith("msearch:")) {
                    continue;
                }
                int tier = matchTier(mode, rawQuery, v, phonetic);
                if (tier == TIER_NONE) continue;
                HitId dedupId = new HitId(sr.site.key, v.id);
                if (!seenIds.add(dedupId)) continue;
                boolean exactTitle = tier == TIER_EXACT && normalizeStrict(v.title).equals(normQ);
                boolean comic =
                        !allowComic
                                && tier > TIER_EXACT
                                && SearchVariants.isComicOrShortDrama(v, sr.site.name);
                out.add(new RankedHit(sr.site, v, tier, exactTitle, comic, pref, sIdx, i));
            }
        }
        Collections.sort(
                out,
                new Comparator<RankedHit>() {
                    @Override
                    public int compare(RankedHit a, RankedHit b) {
                        int c = Integer.compare(a.tier, b.tier);
                        if (c != 0) return c;
                        if (a.comicPenalty != b.comicPenalty) return a.comicPenalty ? 1 : -1;
                        if (a.preferredSite != b.preferredSite) return a.preferredSite ? -1 : 1;
                        if (a.exactTitle != b.exactTitle) return a.exactTitle ? -1 : 1;
                        c = Integer.compare(a.siteRank, b.siteRank);
                        if (c != 0) return c;
                        return Integer.compare(a.itemIndex, b.itemIndex);
                    }
                });
        return out;
    }
}

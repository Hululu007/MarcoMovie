package com.pilipala.marcomovie;

import java.io.IOException;
import java.util.*;

/**
 * Immutable search-page transactions; publish only after the host rechecks its context token.
 *
 * <p>Separates lightweight pagination cursors & delivered-ID sets from retained {@link Cms.Video}
 * objects so memory budgets never hold unshown video objects in a shadow copy and never discard
 * access to truncated items.
 */
final class TvSearchPages {
    static final int MAX_RESULTS = 5000;
    private static final int MAX_CONSECUTIVE_REPEAT_PAGES = 2;

    interface Fetch {
        Cms.Listing get(String term, int page) throws Exception;
    }

    static final class Cursor {
        final String term;
        final int page, pages;
        final boolean pageHasRemainder;
        final int rewindWatermark;
        final Set<String> seen;
        final String lastPageSignature;
        final int consecutiveRepeats;

        Cursor(String term, int page, int pages, Set<String> seen) {
            this(term, page, pages, false, 0, seen, "", 0);
        }

        Cursor(String term, int page, int pages, boolean pageHasRemainder, Set<String> seen) {
            this(term, page, pages, pageHasRemainder, 0, seen, "", 0);
        }

        Cursor(
                String term,
                int page,
                int pages,
                boolean pageHasRemainder,
                int rewindWatermark,
                Set<String> seen) {
            this(term, page, pages, pageHasRemainder, rewindWatermark, seen, "", 0);
        }

        Cursor(
                String term,
                int page,
                int pages,
                boolean pageHasRemainder,
                int rewindWatermark,
                Set<String> seen,
                String lastPageSignature,
                int consecutiveRepeats) {
            this.term = term;
            this.page = page;
            this.pages = pages;
            this.pageHasRemainder = pageHasRemainder;
            this.rewindWatermark = Math.max(0, rewindWatermark);
            this.seen = Collections.unmodifiableSet(new HashSet<>(seen));
            this.lastPageSignature = lastPageSignature == null ? "" : lastPageSignature;
            this.consecutiveRepeats = Math.max(0, consecutiveRepeats);
        }

        boolean more() {
            return pageHasRemainder || (page < pages && page < Integer.MAX_VALUE);
        }
    }

    private static final class TermPageMeta {
        final String term;
        final int pageCount;
        final Set<String> matchedIds;
        final String pageSignature;

        TermPageMeta(String term, int pageCount, Set<String> matchedIds, String pageSignature) {
            this.term = term;
            this.pageCount = pageCount;
            this.matchedIds = matchedIds;
            this.pageSignature = pageSignature == null ? "" : pageSignature;
        }
    }

    private static String pageSignature(List<Cms.Video> videos) {
        if (videos == null || videos.isEmpty()) return "";
        StringBuilder sb = new StringBuilder(videos.size() * 48);
        for (int i = 0; i < videos.size(); i++) {
            Cms.Video v = videos.get(i);
            if (!playable(v)) continue;
            sb.append(v.id).append('\0');
            if (v.title != null) sb.append(v.title.trim());
            sb.append('\0');
            if (v.aliases != null && !v.aliases.isEmpty()) {
                for (int j = 0; j < v.aliases.size(); j++) {
                    String a = v.aliases.get(j);
                    if (a != null) sb.append(a.trim()).append('\u0001');
                }
            }
            sb.append('\n');
        }
        return sb.toString();
    }

    final String query;
    final List<Cms.Video> videos;
    final List<Cursor> cursors;
    final boolean limited;
    final boolean evicted;

    private TvSearchPages(
            String query,
            List<Cms.Video> videos,
            List<Cursor> cursors,
            boolean limited,
            boolean evicted) {
        this.query = query;
        this.videos = Collections.unmodifiableList(new ArrayList<>(videos));
        this.cursors = Collections.unmodifiableList(new ArrayList<>(cursors));
        this.limited = limited;
        this.evicted = evicted;
    }

    boolean hasMore() {
        if (limited) return false;
        for (Cursor c : cursors) if (c.more()) return true;
        return false;
    }

    static TvSearchPages first(
            String query, List<String> variants, SearchVariants.Match match, Fetch fetch)
            throws Exception {
        return first(query, variants, match, fetch, MAX_RESULTS);
    }

    static TvSearchPages first(
            String query,
            List<String> variants,
            SearchVariants.Match match,
            Fetch fetch,
            int maxRetained)
            throws Exception {
        final SearchVariants.Match pred = match;
        return firstVideos(
                query,
                variants,
                v -> v != null && (pred == null || pred.test(v.title)),
                fetch,
                maxRetained,
                3);
    }

    static TvSearchPages firstVideos(
            String query,
            List<String> variants,
            SearchVariants.VideoMatch match,
            Fetch fetch,
            int maxRetained)
            throws Exception {
        return firstVideos(query, variants, match, fetch, maxRetained, 3);
    }

    static TvSearchPages firstVideos(
            String query,
            List<String> variants,
            SearchVariants.VideoMatch match,
            Fetch fetch,
            int maxRetained,
            int autoAdvancePagesOnZeroMatch)
            throws Exception {
        if (isBlankQuery(query) || variants == null || variants.isEmpty()) {
            return new TvSearchPages(
                    query == null ? "" : query,
                    Collections.emptyList(),
                    Collections.emptyList(),
                    false,
                    false);
        }
        int cap = Math.max(0, Math.min(MAX_RESULTS, maxRetained));
        final List<TermPageMeta> metas = new ArrayList<>();
        List<Cms.Video> raw =
                SearchVariants.runVideos(
                        query,
                        variants,
                        match,
                        term -> {
                            Cms.Listing page = fetch.get(term, 1);
                            requirePage(page, 1);
                            Set<String> matchedIds = new LinkedHashSet<>();
                            for (Cms.Video v : page.videos) {
                                if (!playable(v)) continue;
                                if (match == null || match.test(v)) {
                                    matchedIds.add(v.id);
                                }
                            }
                            metas.add(
                                    new TermPageMeta(
                                            term,
                                            page.videos.isEmpty() ? 1 : page.pageCount,
                                            matchedIds,
                                            pageSignature(page.videos)));
                            return page.videos;
                        });

        // Deduplicate & rank ALL admitted candidates by unified mode tier BEFORE applying the
        // per-source retention cap so full exact/alias matches are never truncated behind prefix
        // noise under low-RAM 200-site budgets.
        List<Cms.Video> admitted = new ArrayList<>(raw.size());
        Set<String> admittedIds = new LinkedHashSet<>();
        for (Cms.Video v : raw) {
            if (!playable(v)) continue;
            if (match != null && !match.test(v)) continue;
            if (admittedIds.add(v.id)) {
                admitted.add(v);
            }
        }
        if (admitted.size() > 1 && match instanceof SearchVariants.VideoRanker) {
            ((SearchVariants.VideoRanker) match).rank(admitted, "");
        }
        List<Cms.Video> retained = new ArrayList<>(Math.min(cap, admitted.size()));
        Set<String> deliveredIds = new HashSet<>();
        for (int i = 0; i < admitted.size() && retained.size() < cap; i++) {
            Cms.Video v = admitted.get(i);
            deliveredIds.add(v.id);
            retained.add(v);
        }

        // Cursor `seen` records ONLY delivered IDs (never previously rejected IDs), so later pages
        // that enrich a previously rejected ID with a trusted alias/title are re-evaluated cleanly.
        List<Cursor> cursors = new ArrayList<>(metas.size());
        for (TermPageMeta meta : metas) {
            Set<String> cursorSeen = new HashSet<>();
            int deliveredFromMeta = 0;
            for (String id : meta.matchedIds) {
                if (deliveredIds.contains(id)) {
                    cursorSeen.add(id);
                    deliveredFromMeta++;
                }
            }
            boolean hasRemainder = meta.matchedIds.size() > deliveredFromMeta;
            cursors.add(
                    new Cursor(
                            meta.term,
                            1,
                            meta.pageCount,
                            hasRemainder,
                            0,
                            cursorSeen,
                            meta.pageSignature,
                            0));
        }
        TvSearchPages result = new TvSearchPages(query, retained, cursors, false, false);
        // When page 1 returned only irrelevant items (0 matches) yet the source advertises
        // additional pages, bounded-advance within the existing request budget so later-page
        // valid hits are discovered instead of falsely concluding the source is empty.
        if (result.videos.isEmpty()
                && cap > 0
                && autoAdvancePagesOnZeroMatch > 0
                && result.hasMore()) {
            try {
                // Separate initial per-source display cap (`cap`) from total search retention hard
                // limit (`MAX_RESULTS`) so reaching `cap` on page 2+ preserves remaining items on
                // that page (`pageHasRemainder`) and later page cursors for manual "Load More".
                result =
                        result.nextBounded(
                                match,
                                fetch,
                                cap,
                                MAX_RESULTS,
                                Math.min(8, autoAdvancePagesOnZeroMatch));
            } catch (SearchCoordinator.VerificationRequiredException e) {
                throw e;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw e;
            } catch (Exception ignored) {
                // Keep page-1 cursors intact so the user can retry or manually load more.
            }
        }
        return result;
    }

    TvSearchPages next(SearchVariants.Match match, Fetch fetch) throws Exception {
        return next(match, fetch, MAX_RESULTS, MAX_RESULTS);
    }

    TvSearchPages next(
            SearchVariants.Match match, Fetch fetch, int maxAdditional, int maxTotalRetained)
            throws Exception {
        final SearchVariants.Match pred = match;
        return nextVideos(
                v -> v != null && (pred == null || pred.test(v.title)),
                fetch,
                maxAdditional,
                maxTotalRetained);
    }

    TvSearchPages nextVideos(
            SearchVariants.VideoMatch match, Fetch fetch, int maxAdditional, int maxTotalRetained)
            throws Exception {
        return nextBounded(match, fetch, maxAdditional, maxTotalRetained, 8);
    }

    private TvSearchPages nextBounded(
            SearchVariants.VideoMatch match,
            Fetch fetch,
            int maxAdditional,
            int maxTotalRetained,
            int maxScans)
            throws Exception {
        if (!hasMore()) return this;
        int hardLimit = Math.max(1, Math.min(MAX_RESULTS, maxTotalRetained));
        if (videos.size() >= hardLimit) {
            return new TvSearchPages(query, videos, cursors, true, evicted);
        }
        int stepBudget = Math.max(1, Math.min(maxAdditional, hardLimit - videos.size()));
        int scanCap = Math.max(1, Math.min(8, maxScans));

        List<Cursor> next = new ArrayList<>(cursors);
        List<Cms.Video> merged = new ArrayList<>(videos);
        Set<String> ids = new HashSet<>();
        for (Cms.Video v : videos) ids.add(v.id);

        boolean progressed = false;
        for (int i = 0; i < next.size(); i++) {
            Cursor cursor = next.get(i);
            if (!cursor.more()) continue;
            int scans = 0;
            while (cursor.more() && scans < scanCap) {
                scans++;
                int requested = cursor.pageHasRemainder ? cursor.page : cursor.page + 1;
                Cms.Listing page = fetch.get(cursor.term, requested);
                requirePage(page, requested);

                boolean moreLeftOnPage = false;
                boolean hitHardLimit = false;
                int added = 0;
                Set<String> seen = new HashSet<>(cursor.seen);
                Set<String> currentPageIds = new HashSet<>();
                String currentSig = pageSignature(page.videos);

                // Collect ALL newly-admitted candidates on this page FIRST (ignoring only already-
                // delivered IDs so previously-rejected IDs enriched with aliases/titles on later
                // pages are re-evaluated), then rank before applying step/hard budget caps.
                List<Cms.Video> pageAdmitted = new ArrayList<>();
                Set<String> pageAdmittedIds = new LinkedHashSet<>();
                for (Cms.Video v : page.videos) {
                    if (!playable(v)) continue;
                    currentPageIds.add(v.id);
                    if (ids.contains(v.id) || seen.contains(v.id)) continue;
                    if (match != null && !match.test(v)) continue;
                    if (pageAdmittedIds.add(v.id)) {
                        pageAdmitted.add(v);
                    }
                }
                if (pageAdmitted.size() > 1 && match instanceof SearchVariants.VideoRanker) {
                    ((SearchVariants.VideoRanker) match).rank(pageAdmitted, "");
                }
                for (int k = 0; k < pageAdmitted.size(); k++) {
                    Cms.Video v = pageAdmitted.get(k);
                    if (merged.size() >= hardLimit) {
                        hitHardLimit = true;
                        moreLeftOnPage = true;
                        break;
                    }
                    if (added >= stepBudget) {
                        moreLeftOnPage = true;
                        break;
                    }
                    seen.add(v.id);
                    ids.add(v.id);
                    merged.add(v);
                    added++;
                }

                boolean rewinding = requested <= cursor.rewindWatermark;
                boolean emptyPage = currentPageIds.isEmpty();
                boolean sameSignatureAsPrev =
                        !currentSig.isEmpty() && currentSig.equals(cursor.lastPageSignature);
                boolean allAlreadyDelivered = !emptyPage && ids.containsAll(currentPageIds);
                int nextRepeats;
                if (added > 0) {
                    nextRepeats = 0;
                } else if (emptyPage) {
                    nextRepeats = MAX_CONSECUTIVE_REPEAT_PAGES;
                } else if (sameSignatureAsPrev || (allAlreadyDelivered && !rewinding)) {
                    nextRepeats = cursor.consecutiveRepeats + 1;
                } else {
                    nextRepeats = 0;
                }

                boolean stuckRepeating = emptyPage || nextRepeats >= MAX_CONSECUTIVE_REPEAT_PAGES;
                int nextPages;
                if (cursor.pageHasRemainder || rewinding) {
                    nextPages =
                            (emptyPage
                                            || (sameSignatureAsPrev
                                                    && nextRepeats >= MAX_CONSECUTIVE_REPEAT_PAGES))
                                    ? requested
                                    : Math.max(requested, page.pageCount);
                } else {
                    // Allow skipping a pinned/duplicated intermediate page when the source
                    // advertises further pages, while stopping boundedly on repeated loops.
                    nextPages = stuckRepeating ? requested : Math.max(requested, page.pageCount);
                }
                int nextWatermark =
                        moreLeftOnPage || requested < cursor.rewindWatermark
                                ? cursor.rewindWatermark
                                : 0;
                cursor =
                        new Cursor(
                                cursor.term,
                                requested,
                                nextPages,
                                moreLeftOnPage,
                                nextWatermark,
                                seen,
                                currentSig,
                                nextRepeats);
                next.set(i, cursor);
                progressed = true;
                boolean nowLimited = hitHardLimit || merged.size() >= hardLimit;
                if (added > 0 || nowLimited) {
                    return new TvSearchPages(query, merged, next, nowLimited, false);
                }
                if (!cursor.more() || (!moreLeftOnPage && stuckRepeating && !rewinding)) {
                    break;
                }
            }
            if (progressed && scans >= scanCap) {
                // Persist the advanced cursor when hitting the per-click scan cap so the next click
                // continues forward instead of re-requesting already-scanned pages.
                return new TvSearchPages(query, merged, next, false, false);
            }
        }
        return progressed ? new TvSearchPages(query, merged, next, false, false) : this;
    }

    /**
     * Evicts surplus {@link Cms.Video} references from this transaction while preserving
     * lightweight cursor metadata so all evicted results remain reachable via on-demand pagination.
     */
    TvSearchPages trimTo(int keepCount) {
        int safeKeep = Math.max(0, keepCount);
        if (safeKeep >= videos.size()) return this;
        List<Cms.Video> kept =
                safeKeep == 0
                        ? Collections.emptyList()
                        : new ArrayList<>(videos.subList(0, safeKeep));
        Set<String> keptIds = new HashSet<>();
        for (Cms.Video v : kept) keptIds.add(v.id);

        List<Cursor> trimmedCursors = new ArrayList<>(cursors.size());
        for (Cursor c : cursors) {
            Set<String> retainedSeen = new HashSet<>();
            for (String id : c.seen) {
                if (keptIds.contains(id)) retainedSeen.add(id);
            }
            // Reset cursor to page 1 with pageHasRemainder=true and remember the highest page
            // previously reached so re-fetching skips retained pages (even across multi-page
            // trims) and recovers every evicted item without retaining Cms.Video refs.
            int watermark = Math.max(1, Math.max(c.page, c.rewindWatermark));
            trimmedCursors.add(
                    new Cursor(c.term, 1, Math.max(1, c.pages), true, watermark, retainedSeen));
        }
        return new TvSearchPages(query, kept, trimmedCursors, false, true);
    }

    private static boolean isDirectTerm(String query, String term) {
        return term.equalsIgnoreCase(query) || SearchVariants.sequelVariants(query).contains(term);
    }

    private static void requirePage(Cms.Listing page, int requested) throws IOException {
        if (page == null || page.page != requested)
            throw new IOException("来源返回的搜索页码与请求不符，请重试或更换来源");
        if (page.videos.size() > 500) throw new IOException("单页超过 500 项限制");
    }

    private static boolean isBlankQuery(String raw) {
        if (raw == null || raw.isEmpty()) return true;
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (!Character.isWhitespace(c)
                    && !Character.isSpaceChar(c)
                    && c != '\u00a0'
                    && c != '\u3000'
                    && c != '\ufeff'
                    && c != '\u200b') {
                return false;
            }
        }
        return true;
    }

    private static boolean playable(Cms.Video v) {
        return v != null && v.id != null && !v.id.isEmpty() && !v.id.startsWith("msearch:");
    }
}

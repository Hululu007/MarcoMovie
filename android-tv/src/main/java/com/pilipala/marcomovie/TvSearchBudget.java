package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Pure-JVM unified memory budget for Android TV global search across initial search, single-source
 * retry, and pagination.
 *
 * <p>Keeps single-source unbudgeted {@link TvSearchPages#MAX_RESULTS} intact while ensuring total
 * strongly-referenced {@link Cms.Video} objects across all active {@link TvSearchPages} and {@link
 * GlobalSearchScreen.SourceResult} entries never exceed the TV memory cap.
 */
final class TvSearchBudget {
    static final int LOW_RAM_TV_GLOBAL_CAP = 900;
    static final int STANDARD_TV_GLOBAL_CAP = 2000;
    static final int NON_TV_GLOBAL_CAP = 2400;

    static final int LOW_RAM_TV_PAGE_STEP = 60;
    static final int STANDARD_TV_PAGE_STEP = 120;
    static final int NON_TV_PAGE_STEP = 24;

    private TvSearchBudget() {}

    static int globalCap(boolean tvDevice, boolean lowRamTv) {
        if (!tvDevice) return NON_TV_GLOBAL_CAP;
        return lowRamTv ? LOW_RAM_TV_GLOBAL_CAP : STANDARD_TV_GLOBAL_CAP;
    }

    static int pageStepCap(boolean tvDevice, boolean lowRamTv) {
        if (!tvDevice) return NON_TV_PAGE_STEP;
        return lowRamTv ? LOW_RAM_TV_PAGE_STEP : STANDARD_TV_PAGE_STEP;
    }

    /**
     * Per-source retention cap for initial multi-source search so every source gets a fair slice
     * while guaranteeing {@code sourceCount * initialPerSourceCap <= globalCap} whenever {@code
     * sourceCount <= globalCap}.
     */
    static int initialPerSourceCap(int sourceCount, boolean tvDevice, boolean lowRamTv) {
        int gCap = globalCap(tvDevice, lowRamTv);
        int step = pageStepCap(tvDevice, lowRamTv);
        int safeSources = Math.max(1, sourceCount);
        int fairShare = gCap / safeSources;
        return Math.max(1, Math.min(step, fairShare));
    }

    /**
     * Enforces {@code sum(pages.videos.size()) <= globalCap} across a map of per-source {@link
     * TvSearchPages}, evicting inactive sources back to lightweight cursor-only entries first so
     * evicted hits remain reachable on demand while memory never exceeds {@code globalCap}.
     */
    static boolean enforceGlobalPagesCap(
            Map<String, TvSearchPages> pagesBySite, String protectedSiteKey, int globalCap) {
        if (pagesBySite == null || pagesBySite.isEmpty()) return false;
        int cap = Math.max(0, globalCap);
        int total = 0;
        for (TvSearchPages p : pagesBySite.values()) {
            if (p != null) total += p.videos.size();
        }
        if (total <= cap) return false;
        int excess = total - cap;
        boolean evictedAny = false;

        // First shed videos from non-protected (inactive) sources in reverse insertion order so
        // earlier/focused sources keep their visible cards while staying strictly within globalCap.
        List<String> keys = new ArrayList<>(pagesBySite.keySet());
        Collections.reverse(keys);
        for (String key : keys) {
            if (excess <= 0) break;
            if (key != null && key.equals(protectedSiteKey)) continue;
            TvSearchPages current = pagesBySite.get(key);
            if (current == null || current.videos.isEmpty()) continue;
            int shed = Math.min(current.videos.size(), excess);
            int keep = current.videos.size() - shed;
            pagesBySite.put(key, current.trimTo(keep));
            excess -= shed;
            evictedAny = true;
        }
        if (excess > 0 && protectedSiteKey != null && !protectedSiteKey.isEmpty()) {
            TvSearchPages active = pagesBySite.get(protectedSiteKey);
            if (active != null && !active.videos.isEmpty()) {
                int shed = Math.min(active.videos.size(), excess);
                pagesBySite.put(protectedSiteKey, active.trimTo(active.videos.size() - shed));
                evictedAny = true;
            }
        }
        return evictedAny;
    }

    /**
     * Enforces the global video budget directly on {@link GlobalSearchScreen.SourceResult} entries,
     * keeping {@code SourceResult.videos} identical to {@code SourceResult.pages.videos} (zero
     * unshown shadow references).
     */
    static boolean enforceGlobalResultsCap(
            Map<String, GlobalSearchScreen.SourceResult> results,
            String protectedSiteKey,
            int globalCap) {
        return enforceGlobalResultsCap(
                results, protectedSiteKey, "", Collections.emptyList(), globalCap);
    }

    static final class ProtectedItem {
        final String siteKey;
        final String vodId;

        ProtectedItem(String siteKey, String vodId) {
            this.siteKey = siteKey == null ? "" : siteKey;
            this.vodId = vodId == null ? "" : vodId;
        }
    }

    /**
     * Enforces {@code sum(sr.videos.size()) <= globalCap} while protecting the currently active
     * filter tab ({@code activeFilterKey}) and all currently visible/focused cards ({@code
     * protectedVisibleKeys}, formatted {@code "siteKey:vodId"}).
     *
     * <p>Eviction order:
     * <ol>
     *   <li>Inactive background sources (neither {@code activeFilterKey} nor {@code
     *       incomingSiteKey}) in reverse insertion order, trimming only items above each source's
     *       highest protected visible/focused card index.
     *   <li>Late background {@code incomingSiteKey} (when {@code incomingSiteKey !=
     *       activeFilterKey}) above its protected visible/focused card index, preserving its
     *       resumable {@link TvSearchPages#hasMore()} cursor via {@link TvSearchPages#trimTo(int)}.
     *   <li>Non-visible tail of {@code activeFilterKey} above its protected visible/focused cards.
     *   <li>Absolute hard-cap fallback only if {@code sum(protected floors) > globalCap}.
     * </ol>
     */
    static boolean enforceGlobalResultsCap(
            Map<String, GlobalSearchScreen.SourceResult> results,
            String activeFilterKey,
            String incomingSiteKey,
            Collection<String> protectedVisibleKeys,
            int globalCap) {
        return enforceGlobalResultsCapWithFloors(
                results,
                activeFilterKey,
                incomingSiteKey,
                computeMinKeepBySite(results, protectedVisibleKeys),
                globalCap);
    }

    /**
     * Structured two-field overload matching {@code (siteKey, vodId)} independently without ever
     * splitting concatenated keys on {@code ':'}, so overlapping keys like {@code "film"} and
     * {@code "film:hk"} or video IDs containing {@code ':'} are resolved unambiguously.
     */
    static boolean enforceGlobalResultsCapByItems(
            Map<String, GlobalSearchScreen.SourceResult> results,
            String activeFilterKey,
            String incomingSiteKey,
            Collection<ProtectedItem> protectedItems,
            int globalCap) {
        return enforceGlobalResultsCapWithFloors(
                results,
                activeFilterKey,
                incomingSiteKey,
                computeMinKeepByItems(results, protectedItems),
                globalCap);
    }

    private static boolean enforceGlobalResultsCapWithFloors(
            Map<String, GlobalSearchScreen.SourceResult> results,
            String activeFilterKey,
            String incomingSiteKey,
            Map<String, Integer> minKeepBySite,
            int globalCap) {
        if (results == null || results.isEmpty()) return false;
        int cap = Math.max(0, globalCap);
        int total = 0;
        for (GlobalSearchScreen.SourceResult sr : results.values()) {
            if (sr != null && sr.videos != null) total += sr.videos.size();
        }
        if (total <= cap) return false;
        int excess = total - cap;
        boolean evictedAny = false;

        String active = activeFilterKey == null ? "" : activeFilterKey;
        String incoming = incomingSiteKey == null ? "" : incomingSiteKey;

        List<String> keys = new ArrayList<>(results.keySet());
        Collections.reverse(keys);

        // Pass 1a: Evict completely offscreen background sources (floor == 0, neither active filter
        // nor incoming batch) in reverse insertion order first so sources contributing visible
        // cards on "全部" keep their full cached page whenever idle offscreen sources can absorb
        // the excess.
        for (String key : keys) {
            if (excess <= 0) break;
            if (key == null) continue;
            if (!active.isEmpty() && key.equals(active)) continue;
            if (!incoming.isEmpty() && key.equals(incoming)) continue;
            GlobalSearchScreen.SourceResult sr = results.get(key);
            if (sr == null || sr.videos == null || sr.videos.isEmpty()) continue;
            int floor = Math.min(sr.videos.size(), intValueOrZero(minKeepBySite, key));
            if (floor > 0) continue;
            int shed = Math.min(sr.videos.size(), excess);
            results.put(key, trimSourceResult(sr, sr.videos.size() - shed));
            excess -= shed;
            evictedAny = true;
        }

        // Pass 1b: If excess remains, trim offscreen tails of background sources that own visible
        // cards down to their protected visible floor.
        for (String key : keys) {
            if (excess <= 0) break;
            if (key == null) continue;
            if (!active.isEmpty() && key.equals(active)) continue;
            if (!incoming.isEmpty() && key.equals(incoming)) continue;
            GlobalSearchScreen.SourceResult sr = results.get(key);
            if (sr == null || sr.videos == null || sr.videos.isEmpty()) continue;
            int floor = Math.min(sr.videos.size(), intValueOrZero(minKeepBySite, key));
            int sheddable = sr.videos.size() - floor;
            if (sheddable <= 0) continue;
            int shed = Math.min(sheddable, excess);
            results.put(key, trimSourceResult(sr, sr.videos.size() - shed));
            excess -= shed;
            evictedAny = true;
        }

        // Pass 2: Trim late background incoming source (when user is viewing another filter tab or
        // "全部") above its visible/focused cards, keeping resumable hasMore() cursor intact.
        if (excess > 0 && !incoming.isEmpty() && !incoming.equals(active)) {
            GlobalSearchScreen.SourceResult inc = results.get(incoming);
            if (inc != null && inc.videos != null && !inc.videos.isEmpty()) {
                int floor = Math.min(inc.videos.size(), intValueOrZero(minKeepBySite, incoming));
                int sheddable = inc.videos.size() - floor;
                if (sheddable > 0) {
                    int shed = Math.min(sheddable, excess);
                    results.put(incoming, trimSourceResult(inc, inc.videos.size() - shed));
                    excess -= shed;
                    evictedAny = true;
                }
            }
        }

        // Pass 3: Trim only the offscreen/non-visible tail of the active filter source.
        if (excess > 0 && !active.isEmpty()) {
            GlobalSearchScreen.SourceResult act = results.get(active);
            if (act != null && act.videos != null && !act.videos.isEmpty()) {
                int floor = Math.min(act.videos.size(), intValueOrZero(minKeepBySite, active));
                int sheddable = act.videos.size() - floor;
                if (sheddable > 0) {
                    int shed = Math.min(sheddable, excess);
                    results.put(active, trimSourceResult(act, act.videos.size() - shed));
                    excess -= shed;
                    evictedAny = true;
                }
            }
        }

        // Pass 4: Absolute hard-cap fallback if protected visible floors alone exceed globalCap.
        if (excess > 0) {
            for (String key : keys) {
                if (excess <= 0) break;
                if (key == null) continue;
                if (!active.isEmpty() && key.equals(active)) continue;
                GlobalSearchScreen.SourceResult sr = results.get(key);
                if (sr == null || sr.videos == null || sr.videos.isEmpty()) continue;
                int shed = Math.min(sr.videos.size(), excess);
                results.put(key, trimSourceResult(sr, sr.videos.size() - shed));
                excess -= shed;
                evictedAny = true;
            }
        }
        if (excess > 0 && !active.isEmpty()) {
            GlobalSearchScreen.SourceResult act = results.get(active);
            if (act != null && act.videos != null && !act.videos.isEmpty()) {
                int shed = Math.min(act.videos.size(), excess);
                results.put(active, trimSourceResult(act, act.videos.size() - shed));
                evictedAny = true;
            }
        }
        return evictedAny;
    }

    private static int intValueOrZero(Map<String, Integer> map, String key) {
        Integer v = map.get(key);
        return v == null ? 0 : v.intValue();
    }

    private static Map<String, Integer> computeMinKeepByItems(
            Map<String, GlobalSearchScreen.SourceResult> results,
            Collection<ProtectedItem> protectedItems) {
        if (protectedItems == null || protectedItems.isEmpty()) {
            return Collections.emptyMap();
        }
        Map<String, Set<String>> protectedIdsBySite = new HashMap<>();
        for (ProtectedItem item : protectedItems) {
            if (item == null || item.siteKey.isEmpty() || item.vodId.isEmpty()) continue;
            if (!results.containsKey(item.siteKey)) continue;
            Set<String> bucket = protectedIdsBySite.get(item.siteKey);
            if (bucket == null) {
                bucket = new HashSet<>();
                protectedIdsBySite.put(item.siteKey, bucket);
            }
            bucket.add(item.vodId);
        }
        return buildFloorsFromIds(results, protectedIdsBySite);
    }

    private static Map<String, Integer> computeMinKeepBySite(
            Map<String, GlobalSearchScreen.SourceResult> results,
            Collection<String> protectedVisibleKeys) {
        if (protectedVisibleKeys == null || protectedVisibleKeys.isEmpty()) {
            return Collections.emptyMap();
        }
        // Build per-site video ID index so concatenated "siteKey:vodId" keys are matched against
        // ACTUAL (siteKey, video.id) pairs rather than blindly splitting on the first ':'. This
        // handles overlapping site keys such as "film" + "film:hk" and colons inside video IDs.
        Map<String, Set<String>> existingIdsBySite = new HashMap<>();
        for (Map.Entry<String, GlobalSearchScreen.SourceResult> entry : results.entrySet()) {
            String siteKey = entry.getKey();
            GlobalSearchScreen.SourceResult sr = entry.getValue();
            if (siteKey == null || siteKey.isEmpty() || sr == null || sr.videos == null) continue;
            Set<String> ids = new HashSet<>(sr.videos.size() * 2);
            for (Cms.Video v : sr.videos) {
                if (v != null && v.id != null && !v.id.isEmpty()) {
                    ids.add(v.id);
                }
            }
            existingIdsBySite.put(siteKey, ids);
        }

        Map<String, Set<String>> protectedIdsBySite = new HashMap<>();
        for (String rawKey : protectedVisibleKeys) {
            if (rawKey == null || rawKey.isEmpty()) continue;
            TvSearchMatcher.HitId parsed = TvSearchMatcher.HitId.parseKey(rawKey);
            if (parsed != null) {
                Set<String> existingForSite = existingIdsBySite.get(parsed.siteKey);
                if (existingForSite != null && existingForSite.contains(parsed.vodId)) {
                    Set<String> bucket = protectedIdsBySite.get(parsed.siteKey);
                    if (bucket == null) {
                        bucket = new HashSet<>();
                        protectedIdsBySite.put(parsed.siteKey, bucket);
                    }
                    bucket.add(parsed.vodId);
                    continue;
                }
                if (rawKey.indexOf('%') >= 0 && results.containsKey(parsed.siteKey)) {
                    // Canonical percent-encoded key unambiguously names (siteKey, vodId).
                    continue;
                }
            }
            boolean matchedRealVideo = false;
            for (Map.Entry<String, Set<String>> siteEntry : existingIdsBySite.entrySet()) {
                String k = siteEntry.getKey();
                if (rawKey.length() <= k.length() + 1) continue;
                if (!rawKey.startsWith(k) || rawKey.charAt(k.length()) != ':') continue;
                String candidateVodId = rawKey.substring(k.length() + 1);
                if (siteEntry.getValue().contains(candidateVodId)) {
                    Set<String> bucket = protectedIdsBySite.get(k);
                    if (bucket == null) {
                        bucket = new HashSet<>();
                        protectedIdsBySite.put(k, bucket);
                    }
                    bucket.add(candidateVodId);
                    matchedRealVideo = true;
                }
            }
            if (!matchedRealVideo) {
                String bestSite = null;
                String bestVodId = null;
                for (String k : results.keySet()) {
                    if (k == null || k.isEmpty()) continue;
                    if (rawKey.length() <= k.length() + 1) continue;
                    if (!rawKey.startsWith(k) || rawKey.charAt(k.length()) != ':') continue;
                    if (bestSite == null || k.length() > bestSite.length()) {
                        bestSite = k;
                        bestVodId = rawKey.substring(k.length() + 1);
                    }
                }
                if (bestSite != null && bestVodId != null && !bestVodId.isEmpty()) {
                    Set<String> bucket = protectedIdsBySite.get(bestSite);
                    if (bucket == null) {
                        bucket = new HashSet<>();
                        protectedIdsBySite.put(bestSite, bucket);
                    }
                    bucket.add(bestVodId);
                }
            }
        }
        return buildFloorsFromIds(results, protectedIdsBySite);
    }

    private static Map<String, Integer> buildFloorsFromIds(
            Map<String, GlobalSearchScreen.SourceResult> results,
            Map<String, Set<String>> protectedIdsBySite) {
        if (protectedIdsBySite.isEmpty()) return Collections.emptyMap();
        Map<String, Integer> floors = new HashMap<>();
        for (Map.Entry<String, Set<String>> entry : protectedIdsBySite.entrySet()) {
            GlobalSearchScreen.SourceResult sr = results.get(entry.getKey());
            if (sr == null || sr.videos == null || sr.videos.isEmpty()) continue;
            Set<String> wanted = entry.getValue();
            int maxKeep = 0;
            for (int i = 0; i < sr.videos.size(); i++) {
                Cms.Video v = sr.videos.get(i);
                if (v != null && wanted.contains(v.id)) {
                    maxKeep = i + 1;
                }
            }
            if (maxKeep > 0) floors.put(entry.getKey(), maxKeep);
        }
        return floors;
    }

    private static GlobalSearchScreen.SourceResult trimSourceResult(
            GlobalSearchScreen.SourceResult sr, int keepCount) {
        int safeKeep = Math.max(0, keepCount);
        if (sr.pages != null) {
            TvSearchPages trimmedPages = sr.pages.trimTo(safeKeep);
            return new GlobalSearchScreen.SourceResult(
                    sr.site, trimmedPages.videos, sr.outcome, trimmedPages);
        }
        List<Cms.Video> kept =
                safeKeep == 0
                        ? Collections.emptyList()
                        : Collections.unmodifiableList(
                                new ArrayList<>(sr.videos.subList(0, safeKeep)));
        return new GlobalSearchScreen.SourceResult(sr.site, kept, sr.outcome, null);
    }

    /**
     * Thread-safe one-shot handoff table for initial/retry {@link TvSearchPages} batches.
     *
     * <p>Guarantees every delivered batch is removed on UI handoff (never left behind in the
     * coordinator closure), and late background completions after timeout, failure, or cancellation
     * are dropped immediately rather than leaking {@link Cms.Video} objects beyond the budget.
     */
    static final class BatchHandoff {
        private final Map<String, TvSearchPages> pending = new HashMap<>();
        private final Set<String> settled = new HashSet<>();
        private boolean closed;

        synchronized boolean put(String siteKey, TvSearchPages pages) {
            if (closed || siteKey == null || pages == null || settled.contains(siteKey)) {
                return false;
            }
            pending.put(siteKey, pages);
            return true;
        }

        synchronized TvSearchPages take(String siteKey, boolean accept) {
            if (siteKey == null) return null;
            settled.add(siteKey);
            TvSearchPages pages = pending.remove(siteKey);
            return (closed || !accept) ? null : pages;
        }

        synchronized void close() {
            closed = true;
            pending.clear();
            settled.clear();
        }

        synchronized int pendingCount() {
            return pending.size();
        }

        synchronized Collection<TvSearchPages> pendingValuesSnapshot() {
            return new ArrayList<>(pending.values());
        }
    }
}

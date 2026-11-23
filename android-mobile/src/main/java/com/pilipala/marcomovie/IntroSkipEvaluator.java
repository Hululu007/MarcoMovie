package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Unified intro / credits / outro skip state machine shared by both {@link MobileInlinePlayer} and
 * {@link MobilePlayerOverlay}.
 *
 * <p>Strictly separates timestamp semantics:
 * <ul>
 *   <li>Manual {@link Prefs#SKIP_INTRO}: seconds from start (0 -> target).
 *   <li>Manual {@link Prefs#SKIP_OUTRO}: <b>remaining seconds from end</b> ({@code dur - outro}).
 *   <li>Community TheIntroDB v4 {@code intro[]}: absolute millisecond intervals {@code [startMs,
 *       endMs]} (honoring cold opens when {@code startMs > 0}).
 *   <li>Community TheIntroDB v4 {@code credits[]}: absolute millisecond intervals {@code [startMs,
 *       endMs]} ({@code endMs < 0} means until end-of-file).
 * </ul>
 */
final class IntroSkipEvaluator {
    static final int ACTION_NONE = 0;
    static final int ACTION_SEEK = 1;
    static final int ACTION_NEXT_EPISODE = 2;

    static final class Decision {
        final int action;
        final long targetMs;
        final String toastMessage;

        private Decision(int action, long targetMs, String toastMessage) {
            this.action = action;
            this.targetMs = targetMs;
            this.toastMessage = toastMessage == null ? "" : toastMessage;
        }

        static final Decision NONE = new Decision(ACTION_NONE, -1L, "");

        static Decision seek(long targetMs, String toastMessage) {
            return new Decision(ACTION_SEEK, targetMs, toastMessage);
        }

        static Decision nextEpisode(String toastMessage) {
            return new Decision(ACTION_NEXT_EPISODE, -1L, toastMessage);
        }
    }

    private long episodeToken;
    private int manualIntroSec;
    private int manualOutroRemainingSec;
    private boolean manualIntroApplied;
    private boolean manualOutroApplied;
    private List<TmdbService.TimeRange> communityIntros = Collections.emptyList();
    private List<TmdbService.TimeRange> communityCredits = Collections.emptyList();
    private final Set<Integer> appliedIntroIndices = new HashSet<>();
    private final Set<Integer> appliedCreditIndices = new HashSet<>();

    synchronized void resetForEpisode(long token, int manualIntroSec, int manualOutroRemainingSec) {
        this.episodeToken = token;
        this.manualIntroSec = Math.max(0, manualIntroSec);
        this.manualOutroRemainingSec = Math.max(0, manualOutroRemainingSec);
        this.manualIntroApplied = false;
        this.manualOutroApplied = false;
        this.communityIntros = Collections.emptyList();
        this.communityCredits = Collections.emptyList();
        this.appliedIntroIndices.clear();
        this.appliedCreditIndices.clear();
    }

    synchronized long currentToken() {
        return episodeToken;
    }

    /** Applies async community timestamps only if {@code token} matches the active episode. */
    synchronized boolean applyCommunityTimestamps(long token, TmdbService.IntroTimestamps ts) {
        if (token != episodeToken || ts == null) {
            return false;
        }
        this.communityIntros =
                ts.intros == null
                        ? Collections.<TmdbService.TimeRange>emptyList()
                        : new ArrayList<>(ts.intros);
        this.communityCredits =
                ts.credits == null
                        ? Collections.<TmdbService.TimeRange>emptyList()
                        : new ArrayList<>(ts.credits);
        return true;
    }

    synchronized Decision evaluate(
            long posMs, long durMs, boolean hasNextEpisode, boolean autoNextEnabled) {
        if (durMs <= 0L || posMs < 0L) {
            return Decision.NONE;
        }

        // 1. Intro skip: manual SKIP_INTRO takes precedence over community intro[].
        if (manualIntroSec > 0) {
            long targetMs = manualIntroSec * 1000L;
            if (!manualIntroApplied && targetMs < durMs - 1000L && posMs < targetMs - 500L) {
                manualIntroApplied = true;
                return Decision.seek(targetMs, "已自动跳过片头 (" + manualIntroSec + "s)");
            }
        } else if (!communityIntros.isEmpty()) {
            for (int i = 0; i < communityIntros.size(); i++) {
                if (appliedIntroIndices.contains(i)) continue;
                TmdbService.TimeRange r = communityIntros.get(i);
                if (r == null || r.endMs <= r.startMs || r.endMs >= durMs - 1000L) continue;
                // Only skip once playback has entered [startMs, endMs), preserving cold opens.
                if (posMs >= r.startMs && posMs < r.endMs - 500L) {
                    appliedIntroIndices.add(i);
                    return Decision.seek(
                            r.endMs, "TheIntroDB 自动跳过片头 (" + Math.round(r.endMs / 1000.0) + "s)");
                }
            }
        }

        // 2. Outro / Credits skip: manual SKIP_OUTRO (remaining duration) vs community credits[]
        //    (absolute millisecond timestamps) are kept strictly distinct.
        if (manualOutroRemainingSec > 0) {
            long remainingMs = manualOutroRemainingSec * 1000L;
            if (!manualOutroApplied
                    && durMs > remainingMs + 5000L
                    && posMs >= durMs - remainingMs) {
                manualOutroApplied = true;
                if (hasNextEpisode && autoNextEnabled) {
                    return Decision.nextEpisode("已自动跳过片尾，切换下一集");
                }
                return Decision.NONE;
            }
        } else if (!communityCredits.isEmpty()) {
            for (int i = 0; i < communityCredits.size(); i++) {
                if (appliedCreditIndices.contains(i)) continue;
                TmdbService.TimeRange r = communityCredits.get(i);
                if (r == null || r.startMs <= 0L || r.startMs >= durMs) continue;
                boolean withinRange =
                        r.endMs < 0L
                                ? (posMs >= r.startMs)
                                : (posMs >= r.startMs && posMs < r.endMs);
                if (!withinRange) continue;
                appliedCreditIndices.add(i);
                // Finite mid-episode credits (ending well before EOF) must NEVER skip the rest of
                // the episode into the next episode, regardless of when playback enters the window.
                boolean reachesEnd = r.endMs < 0L || r.endMs >= durMs - 2000L;
                if (!reachesEnd) {
                    if (r.endMs > posMs + 1000L) {
                        return Decision.seek(
                                r.endMs,
                                "TheIntroDB 已跳过片尾字幕 (" + Math.round(r.endMs / 1000.0) + "s)");
                    }
                    return Decision.NONE;
                }
                if (hasNextEpisode && autoNextEnabled) {
                    return Decision.nextEpisode("TheIntroDB 已到片尾，自动切换下一集");
                }
                return Decision.NONE;
            }
        }

        return Decision.NONE;
    }
}

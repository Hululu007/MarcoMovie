package com.pilipala.marcomovie;

/**
 * One-shot return context for catalog source switching on Android TV.
 *
 * <p>Pure Java so offline unit tests can verify A->B->C async race rejection, relative-viewport
 * scroll alignment, short-list clamping, and user-focus non-interruption without Android runtime.
 */
final class HomeSourceSwitchAnchor {
    static final int ACTION_DISMISS_ONLY = 0;
    static final int ACTION_IN_PLACE_HOME_SWITCH = 1;
    static final int ACTION_SETTINGS_COMMIT_STAY = 2;
    static final int ACTION_REBUILD_HOME_TOP = 3;

    final int homeGeneration;
    final long switchToken;
    final String targetSiteKey;
    final String focusTag;
    final int anchorRelTopPx;
    final int fallbackScrollY;
    boolean userMovedFocus;
    boolean consumed;

    HomeSourceSwitchAnchor(
            int homeGeneration,
            long switchToken,
            String targetSiteKey,
            String focusTag,
            int anchorRelTopPx,
            int fallbackScrollY) {
        this.homeGeneration = homeGeneration;
        this.switchToken = switchToken;
        this.targetSiteKey = targetSiteKey == null ? "" : targetSiteKey;
        this.focusTag =
                (focusTag == null || focusTag.trim().isEmpty())
                        ? "source-switcher"
                        : focusTag.trim();
        this.anchorRelTopPx = anchorRelTopPx;
        this.fallbackScrollY = Math.max(0, fallbackScrollY);
    }

    /** Decides how SourcePicker handles clicking an available site. */
    static int decideSiteSelectionAction(
            String previousSelectedKey,
            String clickedSiteKey,
            boolean openedFromRetainedHome,
            boolean currentIsHome) {
        String prev = previousSelectedKey == null ? "" : previousSelectedKey;
        String next = clickedSiteKey == null ? "" : clickedSiteKey;
        if (prev.equals(next)) {
            return ACTION_DISMISS_ONLY;
        }
        if (openedFromRetainedHome && currentIsHome) {
            return ACTION_IN_PLACE_HOME_SWITCH;
        }
        if (!currentIsHome) {
            return ACTION_SETTINGS_COMMIT_STAY;
        }
        return ACTION_REBUILD_HOME_TOP;
    }

    boolean matches(int currentGeneration, long currentSwitchToken, String currentSiteKey) {
        return !consumed
                && homeGeneration == currentGeneration
                && switchToken == currentSwitchToken
                && targetSiteKey.equals(currentSiteKey == null ? "" : currentSiteKey);
    }

    boolean canApplyFocus(
            int currentGeneration,
            long currentSwitchToken,
            String currentSiteKey,
            boolean modalDialogOpen) {
        return !userMovedFocus
                && !modalDialogOpen
                && matches(currentGeneration, currentSwitchToken, currentSiteKey);
    }

    void markUserMovedFocus() {
        userMovedFocus = true;
    }

    void consume() {
        consumed = true;
    }

    /**
     * Computes the scrollY that places {@code anchorTopInContent} at {@code desiredRelTopPx} inside
     * the scroll viewport, clamped strictly to {@code [0, max(0, contentHeight - viewportHeight)]}.
     */
    static int computeAlignedScrollY(
            int anchorTopInContent, int desiredRelTopPx, int contentHeight, int viewportHeight) {
        int maxScroll = Math.max(0, contentHeight - Math.max(0, viewportHeight));
        int desired = anchorTopInContent - desiredRelTopPx;
        if (desired < 0) return 0;
        return Math.min(maxScroll, desired);
    }

    /**
     * Tracks ownership of {@link Prefs#LOADING_SITE} by {@code (siteKey, generation, requestId)} so
     * settings-only selections never arm the crash guard and late callbacks from a superseded site
     * never clear a newer site's active crash guard.
     */
    static final class LoadingGuardTracker {
        private String ownerSiteKey = "";
        private int ownerGeneration = -1;
        private long ownerRequestId = -1L;

        synchronized void claim(String siteKey, int generation, long requestId) {
            this.ownerSiteKey = siteKey == null ? "" : siteKey;
            this.ownerGeneration = generation;
            this.ownerRequestId = requestId;
        }

        synchronized boolean isOwner(String siteKey, int generation, long requestId) {
            String key = siteKey == null ? "" : siteKey;
            return !ownerSiteKey.isEmpty()
                    && ownerSiteKey.equals(key)
                    && ownerGeneration == generation
                    && ownerRequestId == requestId;
        }

        synchronized boolean releaseIfOwner(String siteKey, int generation, long requestId) {
            if (!isOwner(siteKey, generation, requestId)) return false;
            ownerSiteKey = "";
            ownerGeneration = -1;
            ownerRequestId = -1L;
            return true;
        }

        synchronized boolean releaseIfSiteMatches(String siteKey, int generation) {
            String key = siteKey == null ? "" : siteKey;
            if (ownerSiteKey.isEmpty()
                    || !ownerSiteKey.equals(key)
                    || ownerGeneration != generation) {
                return false;
            }
            ownerSiteKey = "";
            ownerGeneration = -1;
            ownerRequestId = -1L;
            return true;
        }

        synchronized void reset() {
            ownerSiteKey = "";
            ownerGeneration = -1;
            ownerRequestId = -1L;
        }

        synchronized String activeOwnerSiteKey() {
            return ownerSiteKey;
        }
    }
}

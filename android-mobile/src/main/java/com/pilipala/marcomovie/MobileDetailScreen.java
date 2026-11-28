package com.pilipala.marcomovie;

import android.app.Dialog;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.Spannable;
import android.text.SpannableStringBuilder;
import android.text.TextUtils;
import android.text.style.ImageSpan;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.WeakHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Immersive Mobile & Tablet Video Detail Screen (Day/Night {@link MobileTheme} +
 * {@link MobileIcons} + {@link MobileMotion}):
 * - Full-bleed poster hero at physical screen top with a persistent cinematic dark scrim so white
 *   hero typography, metadata pills, and floating vector controls stay crisp over any artwork
 * - Rounded Day/Night lower content surface ({@code bgCanvas} / borderless {@code bgCard} &
 *   {@code bgSubtle}) with animated synopsis expand/collapse, heart pop-bounce, progressive
 *   single-episode decluttering (hides sort/all-episodes on single-episode movies), smart
 *   single-line source pill, and scroll-preserving line/episode switching.
 */
final class MobileDetailScreen {
    private MobileDetailScreen() {}

    private static int activeTmdbId = 0;
    private static boolean activeTmdbIsTv = true;
    private static final Map<Integer, TmdbService.EpisodeStill> activeTmdbEpisodes =
            new HashMap<>();
    private static final Map<String, String> activeAiEpisodeTitles = new HashMap<>();
    private static String selectedEpisodeLine = "";
    private static String selectedEpisodeLineId = "";
    private static int selectedEpisodeLineIndex = -1;
    private static int selectedEpisodeIndex = -1;
    private static boolean userSelectedDetailTarget = false;
    private static boolean awaitingExplicitReselection = false;
    private static int activeDetailLineIndex = -1;
    private static int activeDetailPage = 0;
    private static boolean activeVideoDescending = false;

    static void resetDetailSelectionState() {
        selectedEpisodeLine = "";
        selectedEpisodeLineId = "";
        selectedEpisodeLineIndex = -1;
        selectedEpisodeIndex = -1;
        userSelectedDetailTarget = false;
        awaitingExplicitReselection = false;
        activeDetailLineIndex = -1;
        activeDetailPage = 0;
    }

    private static boolean matchesSelectedEpisodeLine(int lineIndex, Cms.Line line) {
        if (line == null) return false;
        String candId = line.lineId();
        if (!selectedEpisodeLineId.isEmpty() && !candId.isEmpty()) {
            return selectedEpisodeLineId.equals(candId);
        }
        if (selectedEpisodeLineIndex >= 0) {
            return selectedEpisodeLineIndex == lineIndex;
        }
        return Objects.equals(line.name, selectedEpisodeLine);
    }

    static int findLineIndexByStableIdentity(
            List<Cms.Line> lines,
            Cms.Line prevActiveLine,
            String prevActiveLineId,
            String prevActiveRawName,
            Cms.Episode prevSelectedEp) {
        if (lines == null || lines.isEmpty()) return -1;
        if (prevActiveLineId != null && !prevActiveLineId.isEmpty()) {
            for (int i = 0; i < lines.size(); i++) {
                Cms.Line cand = lines.get(i);
                if (cand != null && prevActiveLineId.equals(cand.lineId())) {
                    return i;
                }
            }
            // Stable lineId was explicitly known and is no longer present (e.g. line was hidden).
            return -1;
        }
        if (prevActiveLine != null) {
            int refIdx = lines.indexOf(prevActiveLine);
            if (refIdx >= 0) return refIdx;
        }
        if (prevSelectedEp != null) {
            for (int i = 0; i < lines.size(); i++) {
                Cms.Line cand = lines.get(i);
                if (cand != null
                        && cand.episodes != null
                        && cand.episodes.contains(prevSelectedEp)) {
                    return i;
                }
            }
        }
        if (prevActiveRawName != null && !prevActiveRawName.isEmpty()) {
            for (int i = 0; i < lines.size(); i++) {
                Cms.Line cand = lines.get(i);
                if (cand != null && prevActiveRawName.equals(cand.rawName())) {
                    return i;
                }
            }
        }
        return -1;
    }

    private static void openLineManagementSheet(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            Cms.Line targetLineToManage,
            int fallbackLineIndex,
            LinearLayout panel,
            WatchHistory.Entry remembered,
            Map<Integer, Cms.Video> discoveredSeasons,
            Map<Integer, String> discoveredLabels) {
        final int prevLineIdx = resolveCurrentDetailLineIndex(a, video, fallbackLineIndex);
        final Cms.Line prevActiveLine =
                (video != null
                                && video.lines != null
                                && prevLineIdx >= 0
                                && prevLineIdx < video.lines.size())
                        ? video.lines.get(prevLineIdx)
                        : null;
        final String prevActiveLineId = prevActiveLine != null ? prevActiveLine.lineId() : "";
        final String prevActiveRawName = prevActiveLine != null ? prevActiveLine.rawName() : "";
        final int prevPage = resolveCurrentDetailPageIndex(a, video, prevLineIdx, activeDetailPage);
        final Cms.Episode prevSelectedEp =
                (prevActiveLine != null
                                && prevActiveLine.episodes != null
                                && selectedEpisodeIndex >= 0
                                && selectedEpisodeIndex < prevActiveLine.episodes.size()
                                && matchesSelectedEpisodeLine(prevLineIdx, prevActiveLine))
                        ? prevActiveLine.episodes.get(selectedEpisodeIndex)
                        : null;
        PlaybackLineRules.showManageLineSheet(
                a,
                site,
                video,
                targetLineToManage,
                () ->
                        rebindDetailAfterLineManagement(
                                a,
                                site,
                                video,
                                panel,
                                remembered,
                                discoveredSeasons,
                                discoveredLabels,
                                prevActiveLine,
                                prevActiveLineId,
                                prevActiveRawName,
                                prevLineIdx,
                                prevPage,
                                prevSelectedEp));
    }

    static void rebindDetailAfterLineManagement(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            LinearLayout panel,
            WatchHistory.Entry remembered,
            Map<Integer, Cms.Video> discoveredSeasons,
            Map<Integer, String> discoveredLabels,
            Cms.Line prevActiveLine,
            String prevActiveLineId,
            String prevActiveRawName,
            int prevFallbackLineIdx,
            int prevPage,
            Cms.Episode prevSelectedEp) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return;
        int reboundIdx =
                findLineIndexByStableIdentity(
                        video.lines,
                        prevActiveLine,
                        prevActiveLineId,
                        prevActiveRawName,
                        prevSelectedEp);
        int targetLineIdx;
        int targetPage;
        if (reboundIdx >= 0) {
            targetLineIdx = reboundIdx;
            Cms.Line reboundLine = video.lines.get(reboundIdx);
            if (userSelectedDetailTarget) {
                selectedEpisodeLine = reboundLine.name == null ? "" : reboundLine.name;
                selectedEpisodeLineId = reboundLine.lineId();
                selectedEpisodeLineIndex = reboundIdx;
                if (prevSelectedEp != null && reboundLine.episodes != null) {
                    int epPos = reboundLine.episodes.indexOf(prevSelectedEp);
                    if (epPos >= 0) {
                        selectedEpisodeIndex = epPos;
                    }
                }
            }
            targetPage =
                    EpisodeSelection.boundPage(
                            prevPage,
                            reboundLine.episodes != null ? reboundLine.episodes.size() : 0);
        } else {
            // The previously active line itself was hidden/removed: never transfer its selection
            // onto a remaining line, nor silently fall back to another line's history or Ep 1.
            // Keep the screen awaiting explicit user re-selection until they pick a line/episode.
            resetDetailSelectionState();
            awaitingExplicitReselection = true;
            if (a != null) a.resumeAt = 0;
            targetLineIdx = Math.max(0, Math.min(prevFallbackLineIdx, video.lines.size() - 1));
            Cms.Line fallbackLine = video.lines.get(targetLineIdx);
            targetPage =
                    EpisodeSelection.boundPage(
                            0,
                            fallbackLine != null && fallbackLine.episodes != null
                                    ? fallbackLine.episodes.size()
                                    : 0);
        }
        panel.removeAllViews();
        renderMobileEpisodes(
                a,
                site,
                video,
                targetLineIdx,
                targetPage,
                panel,
                remembered,
                discoveredSeasons,
                discoveredLabels);
    }

    static int resolveCurrentDetailLineIndex(MainActivity a, Cms.Video video, int fallbackLineIdx) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return 0;
        int n = video.lines.size();
        if (activeDetailLineIndex >= 0 && activeDetailLineIndex < n) {
            return activeDetailLineIndex;
        }
        if (a != null
                && a.current != null
                && a.current.selection != null
                && a.current.selection.selected
                && a.current.selection.line != null) {
            for (int i = 0; i < n; i++) {
                Cms.Line cand = video.lines.get(i);
                if (cand != null && Objects.equals(cand.name, a.current.selection.line)) {
                    return i;
                }
            }
        }
        return Math.max(0, Math.min(fallbackLineIdx, n - 1));
    }

    static int resolveCurrentDetailPageIndex(
            MainActivity a, Cms.Video video, int lineIndex, int fallbackPageIdx) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return 0;
        int safeLine = Math.max(0, Math.min(lineIndex, video.lines.size() - 1));
        Cms.Line line = video.lines.get(safeLine);
        int epCount = line != null && line.episodes != null ? line.episodes.size() : 0;
        int candidatePage = activeDetailLineIndex >= 0 ? activeDetailPage : fallbackPageIdx;
        if (activeDetailLineIndex < 0
                && a != null
                && a.current != null
                && a.current.selection != null
                && a.current.selection.selected) {
            candidatePage = a.current.selection.page;
        }
        return EpisodeSelection.boundPage(candidatePage, epCount);
    }

    private static final WeakHashMap<View, EpisodeSelectionState> SELECTION_STATES =
            new WeakHashMap<>();

    /** Pure-JVM policy: every newly opened video defaults cleanly to ascending (正序) order. */
    static boolean defaultEpisodeDescending() {
        return false;
    }

    /**
     * Pure-JVM policy: resolves initial highlighted &amp; scrolled episode index on open — locates
     * the last watched episode when watch history exists, otherwise defaults to Episode 1 (0).
     */
    static int resolveInitialEpisodeIndex(
            List<Cms.Episode> episodes, String rememberedEpisodeName) {
        if (episodes == null || episodes.isEmpty()) return 0;
        if (rememberedEpisodeName != null && !rememberedEpisodeName.isEmpty()) {
            for (int i = 0; i < episodes.size(); i++) {
                Cms.Episode ep = episodes.get(i);
                if (ep != null && rememberedEpisodeName.equals(ep.name)) {
                    return i;
                }
            }
        }
        return 0;
    }

    private static final class EpisodeCardHolder {
        final View cardView;
        final LinearLayout ePill;
        final MobileIcons.IconView playIcon;
        final TextView epTagTv;
        final View activeRing;
        final TextView headlineTv;

        EpisodeCardHolder(
                View cardView,
                LinearLayout ePill,
                MobileIcons.IconView playIcon,
                TextView epTagTv,
                View activeRing,
                TextView headlineTv) {
            this.cardView = cardView;
            this.ePill = ePill;
            this.playIcon = playIcon;
            this.epTagTv = epTagTv;
            this.activeRing = activeRing;
            this.headlineTv = headlineTv;
        }
    }

    private static final class EpisodeSelectionState {
        final String lineName;
        final Map<Integer, TextView> numPills = new HashMap<>();
        final Map<Integer, EpisodeCardHolder> cards = new HashMap<>();
        HorizontalScrollView numScroll;
        HorizontalScrollView cardScroll;

        EpisodeSelectionState(String lineName) {
            this.lineName = lineName;
        }

        void scrollToEpisode(final int epIdx, final boolean smooth) {
            if (numScroll != null) {
                final View pill = numPills.get(epIdx);
                if (pill != null) {
                    numScroll.post(
                            () -> {
                                int targetX =
                                        Math.max(
                                                0,
                                                pill.getLeft()
                                                        - (numScroll.getWidth() - pill.getWidth())
                                                                / 2);
                                if (smooth) numScroll.smoothScrollTo(targetX, 0);
                                else numScroll.scrollTo(targetX, 0);
                            });
                }
            }
            if (cardScroll != null) {
                final EpisodeCardHolder holder = cards.get(epIdx);
                if (holder != null && holder.cardView != null) {
                    final View cardV = holder.cardView;
                    cardScroll.post(
                            () -> {
                                int targetX =
                                        Math.max(0, cardV.getLeft() - cardScroll.getPaddingLeft());
                                if (smooth) cardScroll.smoothScrollTo(targetX, 0);
                                else cardScroll.scrollTo(targetX, 0);
                            });
                }
            }
        }

        void applySelection(MainActivity a, int activeIdx) {
            MobileTheme.Palette p = MobileTheme.of(a);
            for (Map.Entry<Integer, TextView> entry : numPills.entrySet()) {
                boolean sel = entry.getKey() == activeIdx;
                TextView pill = entry.getValue();
                pill.setTextColor(sel ? p.accentOnFill : p.textPrimary);
                pill.setBackground(
                        sel ? MobileTheme.accentPillBg(a, 10) : MobileTheme.subtleBg(a, 10));
                if (sel) {
                    MobileMotion.popBounce(pill);
                }
            }
            for (Map.Entry<Integer, EpisodeCardHolder> entry : cards.entrySet()) {
                boolean sel = entry.getKey() == activeIdx;
                EpisodeCardHolder h = entry.getValue();
                h.ePill.setBackground(sel ? MobileTheme.accentPillBg(a, 6) : a.bg(0xB00A0B0E, 6));
                h.playIcon.setTint(sel ? p.accentOnFill : Color.WHITE);
                h.epTagTv.setTextColor(sel ? p.accentOnFill : Color.WHITE);
                h.activeRing.setVisibility(sel ? View.VISIBLE : View.GONE);
                h.headlineTv.setTextColor(sel ? p.accent : p.textPrimary);
            }
        }
    }

    private static void refreshSelectedEpisodeHighlight(
            MainActivity a, String lineName, int activeIdx) {
        if (a == null || a.root == null || lineName == null) return;
        View bodyHost = a.root.findViewWithTag("detail-episodes-body");
        if (bodyHost == null) return;
        EpisodeSelectionState state = SELECTION_STATES.get(bodyHost);
        if (state != null && lineName.equals(state.lineName)) {
            state.applySelection(a, activeIdx);
        }
    }

    /** Pure-JVM progressive-disclosure policy: hide sort & all-episodes grid on 1-episode titles. */
    static boolean shouldShowMultiEpisodeTools(int episodeCount) {
        return episodeCount > 1;
    }

    static final String RESELECT_BUTTON_TEXT = "原线路已变更 · 请重选";
    static final String RESELECT_TOAST_TEXT = "上次的线路或集数已变更，请在下方重新选择线路或剧集";

    /**
     * Resolved primary play button state on {@link MobileDetailScreen}. When watch history exists
     * for the current title on the same site, {@link HistoryResumeMatcher#matchEpisode} returns
     * {@code null} (e.g. original Quark drive vanished and only Baidu remains), and the user has
     * not explicitly chosen a replacement line/episode yet, {@code requiresReselection} is {@code
     * true} so the primary button prompts re-selection instead of silently playing a default
     * episode on another drive.
     */
    static final class PrimaryPlayAction {
        final boolean requiresReselection;
        final String buttonLabel;
        final Cms.Line line;
        final Cms.Episode episode;
        final int episodeIndex;
        final int resumePositionMs;

        PrimaryPlayAction(
                boolean requiresReselection,
                String buttonLabel,
                Cms.Line line,
                Cms.Episode episode,
                int episodeIndex,
                int resumePositionMs) {
            this.requiresReselection = requiresReselection;
            this.buttonLabel = buttonLabel;
            this.line = line;
            this.episode = episode;
            this.episodeIndex = episodeIndex;
            this.resumePositionMs = resumePositionMs;
        }
    }

    static PrimaryPlayAction resolvePrimaryPlayAction(
            Cms.Video video,
            int preferredLineIndex,
            WatchHistory.Entry remembered,
            boolean userSelected,
            Cms.Line userSelectedLine,
            int userSelectedEpIndex,
            boolean aiUnlocked,
            int storedCleanMode) {
        return resolvePrimaryPlayAction(
                video,
                preferredLineIndex,
                remembered,
                userSelected,
                userSelectedLine,
                userSelectedEpIndex,
                false,
                aiUnlocked,
                storedCleanMode);
    }

    static PrimaryPlayAction resolvePrimaryPlayAction(
            Cms.Video video,
            int preferredLineIndex,
            WatchHistory.Entry remembered,
            boolean userSelected,
            Cms.Line userSelectedLine,
            int userSelectedEpIndex,
            boolean awaitingReselection,
            boolean aiUnlocked,
            int storedCleanMode) {
        if (video == null || video.lines == null || video.lines.isEmpty()) {
            return new PrimaryPlayAction(true, RESELECT_BUTTON_TEXT, null, null, -1, 0);
        }
        if (userSelected
                && userSelectedLine != null
                && userSelectedLine.episodes != null
                && !userSelectedLine.episodes.isEmpty()) {
            int epIdx =
                    Math.max(
                            0, Math.min(userSelectedEpIndex, userSelectedLine.episodes.size() - 1));
            Cms.Episode ep = userSelectedLine.episodes.get(epIdx);
            int resumePos =
                    remembered != null
                            ? HistoryResumeMatcher.resolveResumePositionMs(
                                    userSelectedLine, ep, epIdx, remembered)
                            : 0;
            String label =
                    formatPlayEpisodeLabel(
                            ep == null ? "" : ep.name, epIdx + 1, aiUnlocked, storedCleanMode);
            return new PrimaryPlayAction(false, label, userSelectedLine, ep, epIdx, resumePos);
        }
        if (awaitingReselection) {
            return new PrimaryPlayAction(true, RESELECT_BUTTON_TEXT, null, null, -1, 0);
        }
        if (remembered != null) {
            HistoryResumeMatcher.EpisodeMatch matched =
                    HistoryResumeMatcher.matchEpisode(video, remembered);
            if (matched == null || matched.line == null || matched.episode == null) {
                return new PrimaryPlayAction(true, RESELECT_BUTTON_TEXT, null, null, -1, 0);
            }
            int epIdx =
                    matched.line.episodes != null
                            ? matched.line.episodes.indexOf(matched.episode)
                            : -1;
            int safeIdx = Math.max(0, epIdx);
            int resumePos =
                    HistoryResumeMatcher.resolveResumePositionMs(
                            matched.line, matched.episode, epIdx, remembered);
            String label =
                    formatPlayEpisodeLabel(
                            matched.episode.name, safeIdx + 1, aiUnlocked, storedCleanMode);
            return new PrimaryPlayAction(
                    false, label, matched.line, matched.episode, safeIdx, resumePos);
        }
        int safeLineIdx = Math.max(0, Math.min(preferredLineIndex, video.lines.size() - 1));
        Cms.Line defLine = video.lines.get(safeLineIdx);
        if (defLine == null || defLine.episodes == null || defLine.episodes.isEmpty()) {
            return new PrimaryPlayAction(true, RESELECT_BUTTON_TEXT, null, null, -1, 0);
        }
        Cms.Episode defEp = defLine.episodes.get(0);
        String label =
                formatPlayEpisodeLabel(
                        defEp == null ? "" : defEp.name, 1, aiUnlocked, storedCleanMode);
        return new PrimaryPlayAction(false, label, defLine, defEp, 0, 0);
    }

    private static CharSequence buildPlayButtonLabel(
            MainActivity a, int iconColor, String episodeLabel) {
        SpannableStringBuilder ssb = new SpannableStringBuilder("  播放 · " + episodeLabel);
        MobileIcons.IconDrawable playIcon =
                MobileIcons.drawable(a, MobileIcons.IC_PLAY, 14f, iconColor);
        ssb.setSpan(
                new ImageSpan(playIcon, ImageSpan.ALIGN_BASELINE),
                0,
                1,
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        return ssb;
    }

    private static CharSequence buildReselectButtonLabel(
            MainActivity a, int iconColor, String label) {
        SpannableStringBuilder ssb = new SpannableStringBuilder("  " + label);
        MobileIcons.IconDrawable switchIcon =
                MobileIcons.drawable(a, MobileIcons.IC_SWITCH_SOURCE, 14f, iconColor);
        ssb.setSpan(
                new ImageSpan(switchIcon, ImageSpan.ALIGN_BASELINE),
                0,
                1,
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        return ssb;
    }

    private static void promptReselectLineOrEpisode(MainActivity a) {
        if (a == null) return;
        a.resumeAt = 0;
        a.toast(RESELECT_TOAST_TEXT);
        if (a.scroll instanceof ScrollView && a.root != null) {
            View epPanel = a.root.findViewWithTag("detail-episodes");
            if (epPanel != null && epPanel.getTop() > 0) {
                ((ScrollView) a.scroll).smoothScrollTo(0, epPanel.getTop());
            }
        }
    }

    private static void bindTopDownloadButton(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            Cms.Line line,
            Cms.Episode targetEpisode,
            int targetEpisodeIndex,
            boolean preselectDefault) {
        if (a == null || a.root == null || line == null) return;
        View topDownView = a.root.findViewWithTag("episodes-download");
        if (topDownView == null) return;
        final String safeName =
                targetEpisode != null && targetEpisode.name != null ? targetEpisode.name : "";
        topDownView.setOnClickListener(
                v ->
                        MobileDownloads.pick(
                                a,
                                site,
                                video,
                                line,
                                targetEpisode,
                                targetEpisodeIndex,
                                safeName,
                                preselectDefault));
    }

    private static void bindPrimaryPlayButton(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            Button playBtn,
            PrimaryPlayAction action) {
        MobileTheme.Palette p = MobileTheme.of(a);
        if (action == null
                || action.requiresReselection
                || action.line == null
                || action.episode == null) {
            if (a != null) a.resumeAt = 0;
            String label =
                    action != null && action.buttonLabel != null && !action.buttonLabel.isEmpty()
                            ? action.buttonLabel
                            : RESELECT_BUTTON_TEXT;
            playBtn.setText(buildReselectButtonLabel(a, p.accentOnFill, label));
            playBtn.setOnClickListener(view -> promptReselectLineOrEpisode(a));
            return;
        }
        playBtn.setText(buildPlayButtonLabel(a, p.accentOnFill, action.buttonLabel));
        playBtn.setOnClickListener(
                view -> {
                    a.resumeAt = action.resumePositionMs;
                    handleDetailEpisodeTap(
                            a,
                            site,
                            video,
                            action.line,
                            action.episode,
                            action.episodeIndex + 1,
                            true);
                });
    }

    private static void handleDetailEpisodeTap(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            Cms.Line line,
            Cms.Episode ep,
            int epNumber,
            boolean forcePlay) {
        int tapMode = a.mobilePrefs().getInt(Prefs.DETAIL_TAP_MODE, 0);
        if (!forcePlay && tapMode == 2) {
            awaitingExplicitReselection = false;
            userSelectedDetailTarget = true;
            selectedEpisodeLine = line.name == null ? "" : line.name;
            selectedEpisodeLineId = line.lineId();
            selectedEpisodeLineIndex =
                    video != null && video.lines != null ? video.lines.indexOf(line) : -1;
            selectedEpisodeIndex = Math.max(0, epNumber - 1);
            if (selectedEpisodeLineIndex >= 0) {
                activeDetailLineIndex = selectedEpisodeLineIndex;
            }
            refreshSelectedEpisodeHighlight(a, selectedEpisodeLine, selectedEpisodeIndex);
            View playBtnView = a.root == null ? null : a.root.findViewWithTag("detail-play");
            if (playBtnView instanceof Button) {
                Button playBtn = (Button) playBtnView;
                MobileTheme.Palette p = MobileTheme.of(a);
                String playLbl = formatPlayEpisodeLabel(ep.name, epNumber);
                final int savedResume = a.resumeAt;
                playBtn.setText(buildPlayButtonLabel(a, p.accentOnFill, playLbl));
                playBtn.setOnClickListener(
                        v -> {
                            a.resumeAt = savedResume;
                            handleDetailEpisodeTap(a, site, video, line, ep, epNumber, true);
                        });
                MobileMotion.popBounce(playBtn);
            }
            a.toast("已选中：" + ep.name + "（点击上方主播放钮开始播放）");
            return;
        }
        if (tapMode == 0 && a.isPortrait() && a.root != null) {
            View slotView = a.root.findViewWithTag("detail-inline-slot");
            if (slotView instanceof FrameLayout) {
                FrameLayout slot = (FrameLayout) slotView;
                View nav = a.root.findViewWithTag("detail-top-nav");
                if (nav != null) nav.setVisibility(View.GONE);
                if (a.inlinePlayer == null) {
                    a.inlinePlayer =
                            new MobileInlinePlayer(
                                    a,
                                    slot,
                                    () -> {
                                        if (nav != null) nav.setVisibility(View.VISIBLE);
                                    });
                }
                SeasonMeta sm = parseSeasonMeta(video.title);
                a.inlinePlayer.startEpisode(
                        site,
                        video,
                        line,
                        ep,
                        activeTmdbId,
                        activeTmdbIsTv,
                        sm.seasonNumber,
                        epNumber);
                return;
            }
        }
        a.resolvePlayer(site, video, line, ep);
    }

    static void bindTouchFeedback(View v) {
        MobileMotion.bindPress(v, 0.95f);
    }

    static GradientDrawable glassBg(
            MainActivity a, int fillColor, int strokeColor, float radiusDp) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(fillColor);
        gd.setCornerRadius(a.dp(radiusDp));
        gd.setStroke(Math.max(1, a.dp(0.8f)), strokeColor);
        return gd;
    }

    static int getStatusBarHeight(MainActivity a) {
        return a.statusBarHeight();
    }

    static int defaultAmbientForTitle(String title) {
        int[] palette = {
            0xFF1A2A22, // Deep pine
            0xFF182436, // Deep midnight blue
            0xFF281C32, // Deep plum
            0xFF2C2018, // Deep warm umber
            0xFF162C2E, // Deep teal
            0xFF291C24 // Deep burgundy
        };
        int h = title == null ? 0 : Math.abs(title.hashCode());
        return palette[h % palette.length];
    }

    static int extractAmbientColor(Bitmap bmp, int fallback) {
        if (bmp == null || bmp.isRecycled() || bmp.getWidth() < 4 || bmp.getHeight() < 4) {
            return fallback;
        }
        int w = bmp.getWidth();
        int h = bmp.getHeight();
        long rSum = 0, gSum = 0, bSum = 0, weightSum = 0;
        int startY = (int) (h * 0.35f);
        int stepX = Math.max(1, w / 24);
        int stepY = Math.max(1, (h - startY) / 24);
        float[] hsv = new float[3];
        for (int y = startY; y < h; y += stepY) {
            for (int x = 0; x < w; x += stepX) {
                int c = bmp.getPixel(x, y);
                int alpha = Color.alpha(c);
                if (alpha < 128) continue;
                Color.colorToHSV(c, hsv);
                long weight = 1 + (long) (hsv[1] * 8f);
                if (hsv[2] > 0.12f && hsv[2] < 0.92f) weight += 3;
                rSum += Color.red(c) * weight;
                gSum += Color.green(c) * weight;
                bSum += Color.blue(c) * weight;
                weightSum += weight;
            }
        }
        if (weightSum <= 0) return fallback;
        int r = (int) (rSum / weightSum);
        int g = (int) (gSum / weightSum);
        int b = (int) (bSum / weightSum);
        Color.RGBToHSV(r, g, b, hsv);
        if (hsv[1] < 0.22f && hsv[1] > 0.04f) {
            hsv[1] = 0.28f;
        } else {
            hsv[1] = Math.min(0.65f, hsv[1] * 1.15f);
        }
        hsv[2] = Math.max(0.16f, Math.min(0.26f, hsv[2] * 0.40f));
        return Color.HSVToColor(hsv);
    }

    static final class EpisodeDisplay {
        final String cleanTitle;
        final String specBadge;

        EpisodeDisplay(String cleanTitle, String specBadge) {
            this.cleanTitle = cleanTitle;
            this.specBadge = specBadge;
        }
    }

    /**
     * Pure-JVM lock-state gate for episode-name cleaning: when AI Lab is locked, masks a stored
     * mode {@code 2} (AI deep clean) down to {@code 0} (local regex clean) WITHOUT erasing the
     * persisted preference, so re-unlocking AI Lab automatically restores the user's prior choice.
     */
    static int effectiveEpisodeCleanMode(int storedMode, boolean aiUnlocked) {
        if (storedMode == 2 && !aiUnlocked) return 0;
        return storedMode;
    }

    static String episodeCleanPillLabel(int storedMode, boolean aiUnlocked) {
        int eff = effectiveEpisodeCleanMode(storedMode, aiUnlocked);
        return eff == 2 ? "AI净化" : (eff == 0 ? "净化" : "原集名");
    }

    static int nextEpisodeCleanMode(int storedMode, boolean aiUnlocked, boolean aiConfigured) {
        int eff = effectiveEpisodeCleanMode(storedMode, aiUnlocked);
        if (!aiUnlocked || !aiConfigured) {
            return eff == 0 ? 1 : 0;
        }
        return eff == 0 ? 2 : (eff == 2 ? 1 : 0);
    }

    static EpisodeDisplay parseEpisodeDisplay(String rawName, int epNumber) {
        MainActivity act = MainActivity.activeActivity;
        boolean aiUnlocked = act != null && !act.isTvDevice() && AiBetaGate.isUnlocked(act);
        int storedMode =
                act != null && !act.isTvDevice()
                        ? act.mobilePrefs().getInt(Prefs.EPISODE_CLEAN_MODE, 0)
                        : 0;
        return parseEpisodeDisplay(rawName, epNumber, aiUnlocked, storedMode);
    }

    static EpisodeDisplay parseEpisodeDisplay(
            String rawName, int epNumber, boolean aiUnlocked, int storedMode) {
        int cleanMode = effectiveEpisodeCleanMode(storedMode, aiUnlocked);
        if (cleanMode == 1) {
            String raw =
                    rawName == null || rawName.trim().isEmpty() ? ("E" + epNumber) : rawName.trim();
            return new EpisodeDisplay(raw, null);
        }
        if (cleanMode == 2 && rawName != null && activeAiEpisodeTitles.containsKey(rawName)) {
            EpisodeNameCleaner.CleanedEpisode base =
                    EpisodeNameCleaner.clean(rawName, "", epNumber);
            return new EpisodeDisplay(activeAiEpisodeTitles.get(rawName), base.specBadge);
        }
        EpisodeNameCleaner.CleanedEpisode c = EpisodeNameCleaner.clean(rawName, "", epNumber);
        String label =
                (c.subtitle != null && !c.subtitle.isEmpty() && !c.shortLabel.contains(c.subtitle))
                        ? (c.shortLabel + " " + c.subtitle)
                        : c.shortLabel;
        return new EpisodeDisplay(label, c.specBadge);
    }

    /** API-23-safe gate predicate evaluated once per episode-list render pass. */
    interface GateCheck {
        boolean isUnlocked();
    }

    /**
     * Pure-JVM episode display batch renderer: evaluates {@code gateCheck} strictly ONCE per render
     * pass regardless of whether the episode list has 50 or 200 items, avoiding O(N) Ed25519
     * signature verification on the UI thread.
     */
    static List<EpisodeDisplay> formatEpisodeDisplaysForRender(
            List<Cms.Episode> episodes, int storedMode, GateCheck gateCheck) {
        List<EpisodeDisplay> out = new ArrayList<>();
        if (episodes == null || episodes.isEmpty()) return out;
        boolean aiUnlocked = gateCheck != null && gateCheck.isUnlocked();
        for (int i = 0; i < episodes.size(); i++) {
            Cms.Episode ep = episodes.get(i);
            String name = ep == null ? "" : ep.name;
            out.add(parseEpisodeDisplay(name, i + 1, aiUnlocked, storedMode));
        }
        return out;
    }

    static String formatPlayEpisodeLabel(String rawName, int epNumber) {
        return formatPlayEpisodeLabel(parseEpisodeDisplay(rawName, epNumber), epNumber);
    }

    static String formatPlayEpisodeLabel(
            String rawName, int epNumber, boolean aiUnlocked, int storedMode) {
        return formatPlayEpisodeLabel(
                parseEpisodeDisplay(rawName, epNumber, aiUnlocked, storedMode), epNumber);
    }

    private static String formatPlayEpisodeLabel(EpisodeDisplay disp, int epNumber) {
        String clean = disp.cleanTitle == null ? "" : disp.cleanTitle.trim();
        Matcher mEp = Pattern.compile("第\\s*([一二三四五六七八九十百零两\\d]+)\\s*([集话期篇])").matcher(clean);
        if (mEp.find()) {
            return "第 " + mEp.group(1) + " " + mEp.group(2);
        }
        if (clean.matches("(?i)^[Ee]\\d+$")) {
            return "第 " + epNumber + " 集";
        }
        if (clean.length() > 10
                || clean.contains(".")
                || clean.matches(
                        "(?i).*(1080|2160|720|4k|web|h264|h265|x264|x265|ddp|aac|hdr|dv|remux|bluray).*")) {
            return "第 " + epNumber + " 集";
        }
        return clean.isEmpty() ? ("第 " + epNumber + " 集") : clean;
    }

    /**
     * Full-screen portrait backdrop canvas that renders:
     * 1. Day/Night semantic {@code bgCanvas} below the poster hero
     * 2. Full-bleed poster from physical y=0 with cinematic dark top & bottom readability scrims
     *    so white overlay titles and floating nav buttons remain sharp over any poster artwork
     * 3. Smooth scroll-driven blur & dark veil cross-fade when scrolling into the episode list.
     */
    static final class PortraitBackdropView extends View {
        private final MainActivity a;
        private final int posterWindowHeight;
        private final int topScrimHeight;
        private int ambientColor;
        private Bitmap rawBitmap;
        private Bitmap blurredBitmap;
        private float scrollProgress = 0f;
        private int blurStartY;
        private int revision = 0;

        private final Paint bitmapPaint =
                new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        private final Paint maskPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint gradientPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Matrix drawMatrix = new Matrix();

        PortraitBackdropView(
                MainActivity activity,
                int posterWindowHeight,
                int topScrimHeight,
                int initAmbient) {
            super(activity);
            this.a = activity;
            this.posterWindowHeight = posterWindowHeight;
            this.topScrimHeight = topScrimHeight;
            this.ambientColor = initAmbient;
            this.blurStartY = Math.round(posterWindowHeight * 0.56f);
            maskPaint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN));
        }

        void setBlurStartY(int y) {
            int clamped = Math.max(a.dp(120), Math.min(posterWindowHeight - a.dp(40), y));
            if (Math.abs(clamped - blurStartY) > a.dp(2)) {
                blurStartY = clamped;
                invalidate();
            }
        }

        void setScrollOffset(int scrollY) {
            float maxScroll = Math.max(1f, a.dp(320));
            float next = Math.max(0f, Math.min(1f, scrollY / maxScroll));
            if (Math.abs(next - scrollProgress) > 0.008f) {
                scrollProgress = next;
                invalidate();
            }
        }

        void setPosterBitmap(Bitmap bmp, Runnable onAmbientChanged) {
            this.rawBitmap = bmp;
            final int token = ++revision;
            final int gen = a.generation;
            if (bmp == null) {
                blurredBitmap = null;
                invalidate();
                return;
            }
            a.artwork.execute(
                    () -> {
                        int extracted = extractAmbientColor(bmp, ambientColor);
                        Bitmap small = Bitmap.createScaledBitmap(bmp, 84, 126, true);
                        int[] pixels = new int[84 * 126];
                        small.getPixels(pixels, 0, 84, 0, 0, 84, 126);
                        if (small != bmp) small.recycle();
                        for (int pass = 0; pass < 4; pass++) {
                            int[] next = new int[pixels.length];
                            for (int y = 0; y < 126; y++) {
                                for (int x = 0; x < 84; x++) {
                                    int r = 0, g = 0, b = 0, count = 0;
                                    for (int dy = -4; dy <= 4; dy++) {
                                        for (int dx = -4; dx <= 4; dx++) {
                                            int c =
                                                    pixels[
                                                            Math.max(0, Math.min(125, y + dy)) * 84
                                                                    + Math.max(
                                                                            0,
                                                                            Math.min(83, x + dx))];
                                            r += Color.red(c);
                                            g += Color.green(c);
                                            b += Color.blue(c);
                                            count++;
                                        }
                                    }
                                    next[y * 84 + x] = Color.rgb(r / count, g / count, b / count);
                                }
                            }
                            pixels = next;
                        }
                        final Bitmap soft =
                                Bitmap.createBitmap(pixels, 84, 126, Bitmap.Config.ARGB_8888);
                        a.ui.post(
                                () -> {
                                    if (token != revision
                                            || gen != a.generation
                                            || a.isFinishing()) {
                                        soft.recycle();
                                        return;
                                    }
                                    ambientColor = extracted;
                                    blurredBitmap = soft;
                                    if (onAmbientChanged != null) onAmbientChanged.run();
                                    invalidate();
                                });
                    });
            invalidate();
        }

        int getAmbientColor() {
            return ambientColor;
        }

        Bitmap getPosterBitmap() {
            return rawBitmap;
        }

        private void configureCenterCropMatrix(Bitmap bmp, int targetW, int targetH) {
            drawMatrix.reset();
            float bw = bmp.getWidth();
            float bh = bmp.getHeight();
            if (bw <= 0 || bh <= 0 || targetW <= 0 || targetH <= 0) return;
            float scale = Math.max(targetW / bw, targetH / bh);
            float dx = (targetW - bw * scale) * 0.5f;
            float dy = (targetH - bh * scale) * 0.24f;
            drawMatrix.setScale(scale, scale);
            drawMatrix.postTranslate(dx, dy);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;

            MobileTheme.Palette p = MobileTheme.of(a);
            int scrimBase = p.isDark ? ambientColor : 0xFF0A0B0E;

            canvas.drawColor(p.bgCanvas);

            int winH = Math.min(h, posterWindowHeight);
            int bTop = Math.max(a.dp(120), Math.min(winH - a.dp(56), blurStartY - a.dp(12)));
            int bFull = Math.min(winH, bTop + a.dp(54));

            if (winH > 0) {
                gradientPaint.setShader(null);
                gradientPaint.setColor(scrimBase);
                canvas.drawRect(0, 0, w, winH, gradientPaint);
            }

            if (rawBitmap != null && !rawBitmap.isRecycled() && winH > 0) {
                int save = canvas.saveLayer(0, 0, w, winH, null);
                configureCenterCropMatrix(rawBitmap, w, winH);
                bitmapPaint.setAlpha(255);
                canvas.drawBitmap(rawBitmap, drawMatrix, bitmapPaint);

                if (blurredBitmap != null && !blurredBitmap.isRecycled()) {
                    int blurLayer = canvas.saveLayer(0, 0, w, winH, null);
                    configureCenterCropMatrix(blurredBitmap, w, winH);
                    bitmapPaint.setAlpha(255);
                    canvas.drawBitmap(blurredBitmap, drawMatrix, bitmapPaint);

                    int topBlurAlpha = Math.round(scrollProgress * 220f);
                    int topMaskColor =
                            (Math.max(0, Math.min(255, topBlurAlpha)) << 24) | 0x00FFFFFF;
                    float stopTop = Math.max(0.05f, Math.min(0.88f, bTop / (float) winH));
                    float stopFull =
                            Math.max(stopTop + 0.04f, Math.min(0.96f, bFull / (float) winH));
                    maskPaint.setShader(
                            new LinearGradient(
                                    0,
                                    0,
                                    0,
                                    winH,
                                    new int[] {topMaskColor, topMaskColor, 0xFFFFFFFF, 0xFFFFFFFF},
                                    new float[] {0f, stopTop, stopFull, 1f},
                                    Shader.TileMode.CLAMP));
                    canvas.drawRect(0, 0, w, winH, maskPaint);
                    maskPaint.setShader(null);
                    canvas.restoreToCount(blurLayer);
                }
                canvas.restoreToCount(save);
            }

            if (topScrimHeight > 0) {
                gradientPaint.setShader(
                        new LinearGradient(
                                0,
                                0,
                                0,
                                topScrimHeight + a.dp(32),
                                new int[] {
                                    withAlpha(0x0A0B0E, 140),
                                    withAlpha(0x0A0B0E, 52),
                                    Color.TRANSPARENT
                                },
                                new float[] {0f, 0.55f, 1f},
                                Shader.TileMode.CLAMP));
                canvas.drawRect(0, 0, w, topScrimHeight + a.dp(32), gradientPaint);
                gradientPaint.setShader(null);
            }

            int lockTop = Math.max(0, bTop - a.dp(42));
            gradientPaint.setShader(
                    new LinearGradient(
                            0,
                            lockTop,
                            0,
                            winH,
                            new int[] {
                                Color.TRANSPARENT,
                                withAlpha(scrimBase, 150),
                                withAlpha(scrimBase, 224),
                                withAlpha(scrimBase, 245)
                            },
                            new float[] {0f, 0.34f, 0.72f, 1f},
                            Shader.TileMode.CLAMP));
            canvas.drawRect(0, lockTop, w, winH, gradientPaint);
            gradientPaint.setShader(null);

            if (scrollProgress > 0.01f && winH > 0) {
                int veilAlpha = Math.round(scrollProgress * 110f);
                gradientPaint.setColor(withAlpha(scrimBase, veilAlpha));
                canvas.drawRect(0, 0, w, winH, gradientPaint);
            }
        }

        private static int withAlpha(int rgb, int alpha) {
            return (Math.max(0, Math.min(255, alpha)) << 24) | (rgb & 0x00FFFFFF);
        }
    }

    /**
     * Hidden ImageView hook passed to {@code a.poster(url, proxyImage, true)} so whenever
     * MainActivity's artwork loader finishes decoding the poster Bitmap, it feeds
     * {@link PortraitBackdropView}.
     */
    /**
     * Resolution-monotone gate for detail posters: prevents a slower low-resolution CMS thumbnail
     * from overwriting an already-applied HD portrait poster.
     */
    static boolean shouldAcceptPosterBitmap(
            int curW, int curH, int newW, int newH, boolean newIsHd) {
        if (newW <= 0 || newH <= 0) return false;
        if (curW <= 0 || curH <= 0) return true;
        long curArea = (long) curW * (long) curH;
        long newArea = (long) newW * (long) newH;
        if (newArea < curArea) return false;
        return newArea > Math.round(curArea * 1.05) || (newIsHd && newArea >= curArea);
    }

    static final class PosterHookImageView extends ImageView {
        private final PortraitBackdropView target;
        private final Runnable onLoaded;
        final int targetW;
        final int targetH;
        private int bestW;
        private int bestH;

        PosterHookImageView(MainActivity a, PortraitBackdropView target, Runnable onLoaded) {
            super(a);
            this.target = target;
            this.onLoaded = onLoaded;
            setScaleType(ScaleType.CENTER_CROP);
            this.targetW = Math.max(1080, a.windowWidth());
            this.targetH = Math.max(1620, Math.round(targetW * 1.5f));
            setLayoutParams(new FrameLayout.LayoutParams(targetW, targetH));
            layout(0, 0, targetW, targetH);
        }

        void applyPosterBitmap(Bitmap bm, boolean isHd) {
            if (bm == null || bm.isRecycled()) return;
            int w = bm.getWidth();
            int h = bm.getHeight();
            if (!shouldAcceptPosterBitmap(bestW, bestH, w, h, isHd)) {
                return;
            }
            bestW = w;
            bestH = h;
            super.setImageBitmap(bm);
            target.setPosterBitmap(bm, onLoaded);
        }

        @Override
        public void setImageBitmap(Bitmap bm) {
            applyPosterBitmap(bm, false);
        }
    }

    static void refreshEpisodeStillBitmaps(View v, Bitmap hdBmp) {
        if (v == null || hdBmp == null || hdBmp.isRecycled()) return;
        if (v instanceof EpisodeStillCropView) {
            EpisodeStillCropView cropView = (EpisodeStillCropView) v;
            if (!cropView.hasCustomStill()) {
                cropView.setImageBitmap(hdBmp);
            }
            return;
        }
        if (v instanceof android.view.ViewGroup) {
            android.view.ViewGroup vg = (android.view.ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                refreshEpisodeStillBitmaps(vg.getChildAt(i), hdBmp);
            }
        }
    }

    /**
     * 16:9 Episode Still ImageView that crops a subtle per-episode camera pan from the series
     * poster so each episode card in the horizontal strip has a rich cinematic 16:9 frame.
     */
    static final class EpisodeStillCropView extends ImageView {
        private final int epIndex;
        private final Matrix cropMatrix = new Matrix();
        private boolean customStillBound;

        EpisodeStillCropView(MainActivity a, int epIndex) {
            super(a);
            this.epIndex = epIndex;
            setScaleType(ScaleType.MATRIX);
        }

        void setCustomStillBound(boolean bound) {
            this.customStillBound = bound;
        }

        boolean hasCustomStill() {
            return customStillBound;
        }

        @Override
        protected boolean setFrame(int l, int t, int r, int b) {
            boolean changed = super.setFrame(l, t, r, b);
            updateCropMatrix(r - l, b - t);
            return changed;
        }

        @Override
        public void setImageBitmap(Bitmap bm) {
            super.setImageBitmap(bm);
            updateCropMatrix(getWidth(), getHeight());
        }

        private void updateCropMatrix(int vw, int vh) {
            if (getDrawable() == null || vw <= 0 || vh <= 0) return;
            int dw = getDrawable().getIntrinsicWidth();
            int dh = getDrawable().getIntrinsicHeight();
            if (dw <= 0 || dh <= 0) return;
            cropMatrix.reset();
            float baseScale = Math.max((float) vw / dw, (float) vh / dh);
            float zoom = 1.04f + (epIndex % 4) * 0.03f;
            float scale = baseScale * zoom;
            float[] yAnchors = {0.22f, 0.36f, 0.50f, 0.30f, 0.44f};
            float[] xAnchors = {0.50f, 0.38f, 0.62f, 0.45f, 0.55f};
            float ax = xAnchors[epIndex % xAnchors.length];
            float ay = yAnchors[epIndex % yAnchors.length];
            float dx = (vw - dw * scale) * ax;
            float dy = (vh - dh * scale) * ay;
            cropMatrix.setScale(scale, scale);
            cropMatrix.postTranslate(dx, dy);
            setImageMatrix(cropMatrix);
        }
    }

    static void show(MainActivity a, Cms.Site s, Cms.Video listing, Cms.Video ready) {
        if (a.redirectListing(s, listing)) return;

        a.clearPlaybackLoading();
        a.cancelArtwork();
        a.cancelPageRequests();
        if (a.current != null) a.current.home = false;
        a.stopWeb();
        a.stopMagnet();
        a.releasePlayer();
        a.generation++;

        // Edge-to-edge transparent status bar with crisp white icons over the dark poster hero
        a.applyMobileSystemBars(false, true);

        final MobileTheme.Palette p = MobileTheme.of(a);
        final int topPad = getStatusBarHeight(a);
        final int screenH =
                a.windowHeight() > 0
                        ? a.windowHeight()
                        : a.getResources().getDisplayMetrics().heightPixels;
        final int foregroundHeroH =
                Math.max(a.dp(360), Math.min(a.dp(500), Math.round(screenH * 0.56f)));
        final int posterWindowH = foregroundHeroH + a.dp(44);
        final int initAmbient = defaultAmbientForTitle(listing.title);

        activeTmdbId = 0;
        activeTmdbIsTv = true;
        activeTmdbEpisodes.clear();
        activeAiEpisodeTitles.clear();
        resetDetailSelectionState();
        activeVideoDescending = defaultEpisodeDescending();
        if (a.inlinePlayer != null) {
            a.inlinePlayer.detach();
            a.inlinePlayer = null;
        }

        a.root = new FrameLayout(a);
        a.root.setBackgroundColor(p.bgCanvas);
        if (!a.suppressTransitionContentView) {
            a.setContentView(a.root);
        }

        LinearLayout outerStack = a.vertical();
        FrameLayout inlineSlot = new FrameLayout(a);
        inlineSlot.setTag("detail-inline-slot");
        inlineSlot.setVisibility(View.GONE);
        outerStack.addView(inlineSlot, new LinearLayout.LayoutParams(-1, -2));

        FrameLayout stageFrame = new FrameLayout(a);
        outerStack.addView(stageFrame, new LinearLayout.LayoutParams(-1, 0, 1f));

        // 1. Full-Screen Immersive Backdrop & Poster Layer
        final PortraitBackdropView backdropView =
                new PortraitBackdropView(a, posterWindowH, topPad + a.dp(54), initAmbient);
        backdropView.setTag("detail-backdrop");
        stageFrame.addView(backdropView, new FrameLayout.LayoutParams(-1, -1));

        final PosterHookImageView posterHook = new PosterHookImageView(a, backdropView, null);
        posterHook.setTag("detail-cover");
        posterHook.setVisibility(View.GONE);
        stageFrame.addView(
                posterHook, new FrameLayout.LayoutParams(posterHook.targetW, posterHook.targetH));
        if (listing.poster != null && !listing.poster.isEmpty()) {
            a.poster(listing.poster, posterHook, true);
        }
        ImmersivePoster.resolveHdPortraitPoster(
                a,
                listing.title,
                listing.year,
                listing.actor,
                listing.director,
                listing.poster,
                hdBmp -> {
                    posterHook.applyPosterBitmap(hdBmp, true);
                    refreshEpisodeStillBitmaps(a.root, hdBmp);
                });

        // 2. Main Scrollable Foreground Content
        final ScrollView scrollView = new ScrollView(a);
        scrollView.setTag("detail-scroll");
        scrollView.setFillViewport(true);
        scrollView.setVerticalScrollBarEnabled(false);
        scrollView
                .getViewTreeObserver()
                .addOnScrollChangedListener(
                        () -> backdropView.setScrollOffset(scrollView.getScrollY()));
        a.scroll = scrollView;
        stageFrame.addView(scrollView, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout mainCol = a.vertical();
        scrollView.addView(mainCol, new ScrollView.LayoutParams(-1, -2));

        // 2A. Foreground Hero Container (white typography over persistent dark poster scrim)
        FrameLayout heroStage = new FrameLayout(a);
        heroStage.setTag("detail-hero");
        mainCol.addView(heroStage, new LinearLayout.LayoutParams(-1, foregroundHeroH));

        LinearLayout heroCenterCol = a.vertical();
        heroCenterCol.setGravity(Gravity.CENTER_HORIZONTAL);
        heroCenterCol.setPadding(a.dp(20), 0, a.dp(20), a.dp(24));
        FrameLayout.LayoutParams heroCenterLp =
                new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        heroStage.addView(heroCenterCol, heroCenterLp);

        final TextView titleView = a.text(listing.title, 26, Color.WHITE);
        titleView.setTag("detail-title");
        titleView.setTypeface(null, Typeface.BOLD);
        titleView.setGravity(Gravity.CENTER);
        titleView.setMaxLines(2);
        titleView.setEllipsize(TextUtils.TruncateAt.END);
        titleView.setShadowLayer(a.dp(12), 0, a.dp(3), 0xB3000000);
        heroCenterCol.addView(titleView, new LinearLayout.LayoutParams(-1, -2));

        final LinearLayout pillsRow = a.row();
        pillsRow.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams pillsRowLp = new LinearLayout.LayoutParams(-1, -2);
        pillsRowLp.topMargin = a.dp(10);
        heroCenterCol.addView(pillsRow, pillsRowLp);

        heroCenterCol.addOnLayoutChangeListener(
                (v, l, t, r, b, ol, ot, or, ob) -> {
                    int titleTopY = heroStage.getTop() + t;
                    backdropView.setBlurStartY(titleTopY);
                });

        // 2B. Day/Night Adaptive Lower Sheet Surface (`bgCanvas`, rounded 24dp top corners)
        LinearLayout lowerBody = a.vertical();
        lowerBody.setTag("detail-lower-sheet");
        GradientDrawable lowerSheetBg = new GradientDrawable();
        lowerSheetBg.setColor(p.bgCanvas);
        float sheetR = a.dp(24);
        lowerSheetBg.setCornerRadii(new float[] {sheetR, sheetR, sheetR, sheetR, 0f, 0f, 0f, 0f});
        lowerBody.setBackground(lowerSheetBg);
        lowerBody.setPadding(a.dp(18), a.dp(18), a.dp(18), a.navigationBarHeight() + a.dp(40));
        LinearLayout.LayoutParams lowerLp = new LinearLayout.LayoutParams(-1, -2);
        lowerLp.topMargin = -a.dp(16);
        mainCol.addView(lowerBody, lowerLp);

        // Ratings + Site Badge Row (Day/Night adaptive semantic pills, zero white border!)
        HorizontalScrollView ratingScroll = new HorizontalScrollView(a);
        ratingScroll.setHorizontalScrollBarEnabled(false);
        LinearLayout ratingRow = a.row();
        ratingRow.setGravity(Gravity.CENTER_VERTICAL);
        ratingScroll.addView(ratingRow);
        LinearLayout.LayoutParams ratingLp = new LinearLayout.LayoutParams(-1, -2);
        ratingLp.bottomMargin = a.dp(14);
        lowerBody.addView(ratingScroll, ratingLp);

        final TextView doubanBadge = a.text("", 11.5f, p.isDark ? 0xFF34D399 : 0xFF047857);
        doubanBadge.setTag("detail-douban-rating");
        doubanBadge.setTypeface(null, Typeface.BOLD);
        doubanBadge.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
        doubanBadge.setBackground(
                a.bg(MobileTheme.withAlpha(p.success, p.isDark ? 0x2E : 0x1A), 999));
        LinearLayout.LayoutParams dbLp = new LinearLayout.LayoutParams(-2, -2);
        dbLp.rightMargin = a.dp(7);
        ratingRow.addView(doubanBadge, dbLp);

        final TextView rtBadge = a.text("", 11.5f, p.isDark ? 0xFFFCA5A5 : 0xFFDC2626);
        rtBadge.setTag("detail-rt-rating");
        rtBadge.setTypeface(null, Typeface.BOLD);
        rtBadge.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
        rtBadge.setBackground(a.bg(MobileTheme.withAlpha(p.danger, p.isDark ? 0x2E : 0x18), 999));
        LinearLayout.LayoutParams rtLp = new LinearLayout.LayoutParams(-2, -2);
        rtLp.rightMargin = a.dp(7);
        ratingRow.addView(rtBadge, rtLp);

        final TextView siteBadge = a.text(s.name, 11.5f, p.textSecondary);
        siteBadge.setTypeface(null, Typeface.BOLD);
        siteBadge.setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4));
        siteBadge.setBackground(MobileTheme.subtleBg(a, 999));
        ratingRow.addView(siteBadge);

        updateRatingBadges(doubanBadge, rtBadge, listing, 0.0);

        ImmersivePoster.resolveMediaRatings(
                a,
                listing,
                ratings ->
                        updateRatingBadges(
                                doubanBadge, rtBadge, listing, ratings.douban, ratings.rtPercent));

        final LinearLayout playBtnWrap = a.vertical();
        lowerBody.addView(playBtnWrap, new LinearLayout.LayoutParams(-1, -2));

        final LinearLayout synopsisWrap = a.vertical();
        LinearLayout.LayoutParams synLp = new LinearLayout.LayoutParams(-1, -2);
        synLp.topMargin = a.dp(14);
        lowerBody.addView(synopsisWrap, synLp);

        final TextView loadingState =
                a.text(
                        MobileCuratedDiscovery.isCuratedSite(s)
                                ? "正在您已添加的订阅源中匹配播放资源…"
                                : "正在加载剧集资源…",
                        13.5f,
                        p.textSecondary);
        loadingState.setTag("detail-loading");
        loadingState.setGravity(Gravity.CENTER);
        loadingState.setPadding(a.dp(4), a.dp(24), a.dp(4), a.dp(16));
        lowerBody.addView(loadingState, new LinearLayout.LayoutParams(-1, -2));

        final LinearLayout detailsBody = a.vertical();
        LinearLayout.LayoutParams detailsLp = new LinearLayout.LayoutParams(-1, -2);
        detailsLp.topMargin = a.dp(16);
        lowerBody.addView(detailsBody, detailsLp);

        // 3. Floating Top Navigation Bar over Dark Hero Scrim
        //    Left: Circular Back button (preserves a.glass(backBtn, 999))
        //    Right: Smart source/cross-search pill + Download & Favorite dual vector capsule
        LinearLayout topNavRow = a.row();
        topNavRow.setTag("detail-top-nav");
        topNavRow.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout.LayoutParams topNavLp = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
        topNavLp.setMargins(a.dp(16), topPad + a.dp(8), a.dp(16), 0);
        stageFrame.addView(topNavRow, topNavLp);
        a.root.addView(outerStack, new FrameLayout.LayoutParams(-1, -1));

        FrameLayout backBtn = new FrameLayout(a);
        backBtn.setTag("detail-back");
        a.glass(backBtn, 999);
        MobileIcons.IconView backIcon =
                MobileIcons.create(a, MobileIcons.IC_BACK, 19f, Color.WHITE);
        backIcon.setStrokeWidthUnits(2.2f);
        backBtn.addView(backIcon, new FrameLayout.LayoutParams(a.dp(19), a.dp(19), Gravity.CENTER));
        MobileMotion.bindPress(backBtn, 0.92f);
        backBtn.setOnClickListener(v -> a.onBackPressed());
        topNavRow.addView(backBtn, new LinearLayout.LayoutParams(a.dp(38), a.dp(38)));

        View topSpacer = new View(a);
        topNavRow.addView(topSpacer, new LinearLayout.LayoutParams(0, 1, 1f));

        // Top-right Source / Cross-Search Pill — sleek translucent frosted capsule matching airy
        // mobile chrome (switches to line picker when >1 line exists, else direct cross-search)
        final LinearLayout sourceTopPill = a.row();
        sourceTopPill.setTag("detail-source-pill");
        sourceTopPill.setGravity(Gravity.CENTER_VERTICAL);
        sourceTopPill.setPadding(a.dp(11), 0, a.dp(10), 0);
        sourceTopPill.setBackground(glassBg(a, 0x5E10131C, 0x33FFFFFF, 999));
        MobileMotion.bindPress(sourceTopPill, 0.94f);

        MobileIcons.IconView switchIcon =
                MobileIcons.create(a, MobileIcons.IC_SWITCH_SOURCE, 13f, 0xE6FFFFFF);
        LinearLayout.LayoutParams swLp = new LinearLayout.LayoutParams(a.dp(13), a.dp(13));
        swLp.rightMargin = a.dp(5);
        sourceTopPill.addView(switchIcon, swLp);

        final TextView sourceTopBtn = a.text(s.name, 12.5f, 0xF5FFFFFF);
        sourceTopBtn.setTag("detail-source-picker");
        sourceTopBtn.setTypeface(null, Typeface.BOLD);
        sourceTopBtn.setSingleLine(true);
        sourceTopBtn.setEllipsize(TextUtils.TruncateAt.END);
        sourceTopBtn.setMaxWidth(a.dp(112));
        sourceTopPill.addView(sourceTopBtn);

        final MobileIcons.IconView srcDownIcon =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_DOWN, 11.5f, 0xBAFFFFFF);
        srcDownIcon.setTag("detail-source-chevron");
        srcDownIcon.setVisibility(View.GONE);
        LinearLayout.LayoutParams sdLp = new LinearLayout.LayoutParams(a.dp(11.5f), a.dp(11.5f));
        sdLp.leftMargin = a.dp(4);
        sourceTopPill.addView(srcDownIcon, sdLp);

        sourceTopPill.setOnClickListener(v -> a.crossSearch(Cms.searchTitle(listing)));
        LinearLayout.LayoutParams sourceTopLp = new LinearLayout.LayoutParams(-2, a.dp(38));
        sourceTopLp.rightMargin = a.dp(8);
        topNavRow.addView(sourceTopPill, sourceTopLp);

        // Top-right Dual Action Capsule (Download | Favorite) matching exact sleek frost chrome
        LinearLayout rightActionPill = a.row();
        rightActionPill.setGravity(Gravity.CENTER_VERTICAL);
        rightActionPill.setPadding(a.dp(3), 0, a.dp(3), 0);
        rightActionPill.setBackground(glassBg(a, 0x5E10131C, 0x33FFFFFF, 999));
        topNavRow.addView(rightActionPill, new LinearLayout.LayoutParams(-2, a.dp(38)));

        final FrameLayout downloadTopBtn = new FrameLayout(a);
        downloadTopBtn.setTag("episodes-download");
        MobileIcons.IconView dlIcon =
                MobileIcons.create(a, MobileIcons.IC_DOWNLOAD, 17f, Color.WHITE);
        downloadTopBtn.addView(
                dlIcon, new FrameLayout.LayoutParams(a.dp(17), a.dp(17), Gravity.CENTER));
        MobileMotion.bindPress(downloadTopBtn, 0.90f);
        downloadTopBtn.setOnClickListener(v -> a.toast("正在加载剧集列表，请稍候…"));
        rightActionPill.addView(downloadTopBtn, new LinearLayout.LayoutParams(a.dp(38), a.dp(36)));

        View pillDivider = new View(a);
        pillDivider.setBackgroundColor(0x36FFFFFF);
        rightActionPill.addView(pillDivider, new LinearLayout.LayoutParams(1, a.dp(18)));

        final FrameLayout favTopBtn = new FrameLayout(a);
        favTopBtn.setTag("detail-favorite");
        final MobileIcons.IconView favIcon =
                MobileIcons.create(a, MobileIcons.IC_HEART, 17f, Color.WHITE);
        favTopBtn.addView(
                favIcon, new FrameLayout.LayoutParams(a.dp(17), a.dp(17), Gravity.CENTER));
        MobileMotion.bindPress(favTopBtn, 0.90f);
        rightActionPill.addView(favTopBtn, new LinearLayout.LayoutParams(a.dp(38), a.dp(36)));

        final Cms.Site[] activeSiteRef = {s};
        final Cms.Video[] activeVideoRef = {listing};
        final Runnable syncFavStyle =
                () -> {
                    boolean faved =
                            Favorites.contains(
                                    a.prefs.getString(Prefs.FAVORITES, "[]"),
                                    activeSiteRef[0].key,
                                    activeVideoRef[0].id);
                    favIcon.setIcon(faved ? MobileIcons.IC_HEART_FILLED : MobileIcons.IC_HEART);
                    favIcon.setTint(faved ? 0xFFFF453A : Color.WHITE);
                };
        syncFavStyle.run();
        favTopBtn.setOnClickListener(
                view -> {
                    final Cms.Site targetSite = activeSiteRef[0];
                    final Cms.Video targetVideo = activeVideoRef[0];
                    CloudSyncDialog.toggleFavoriteWithTombstone(
                            a,
                            targetSite.key,
                            targetVideo,
                            faved -> {
                                favIcon.setIcon(
                                        faved ? MobileIcons.IC_HEART_FILLED : MobileIcons.IC_HEART);
                                favIcon.setTint(faved ? 0xFFFF453A : Color.WHITE);
                                MobileMotion.popBounce(favIcon);
                                if (faved) {
                                    MobileFavoritePostcard.show(
                                            a,
                                            targetVideo.title,
                                            targetVideo.poster,
                                            MobileFavoritePostcard.peekBitmapFromView(posterHook));
                                } else {
                                    MobileFavoritePostcard.dismissActive();
                                    a.toast("已从片库移除");
                                }
                            });
                });

        final MainActivity.Screen screen = a.current;
        final int ticket = a.generation;
        final TvSearchContext recoverCtx =
                new TvSearchContext(a.config, a.privateMode, a.engineEpoch);
        final boolean[] sameSiteHistoryRetried = {false};
        WatchHistory.Entry initBm = null;
        for (WatchHistory.Entry entry : a.watchHistory()) {
            if (entry != null
                    && Objects.equals(entry.site, s.key)
                    && Objects.equals(entry.id, listing.id)) {
                initBm = entry;
                break;
            }
        }
        if (initBm == null
                && a.historyFallbackBookmark != null
                && Objects.equals(a.historyFallbackBookmark.site, s.key)) {
            initBm = a.historyFallbackBookmark;
        }
        final WatchHistory.Entry openingBookmark = WatchHistory.cloneEntry(initBm);
        final Runnable[] trySameSiteRecoverRef = new Runnable[1];

        // Populate initial metadata pills from listing
        populateHeroPills(a, pillsRow, listing, 0);

        MainActivity.Done<Cms.Video> present =
                v -> {
                    final Cms.Site curSite = activeSiteRef[0];
                    String listId = listing.id == null ? "" : listing.id.trim();
                    if (!Cms.Site.isGenericPlaceholderVodId(listId)
                            && (Cms.Site.isGenericPlaceholderVodId(v.id)
                                    || (Cms.Site.looksLikeNetdiskShareId(listId)
                                            && !Cms.Site.looksLikeNetdiskShareId(v.id)))) {
                        v.id = listId;
                    }
                    if (v.poster == null || v.poster.isEmpty()) v.poster = listing.poster;
                    if (v.title == null || v.title.isEmpty()) v.title = listing.title;
                    activeVideoRef[0] = v;
                    syncFavStyle.run();
                    titleView.setText(v.title);
                    if (!Objects.equals(v.poster, listing.poster)
                            && v.poster != null
                            && !v.poster.isEmpty()) {
                        a.poster(v.poster, posterHook, true);
                    }
                    ImmersivePoster.resolveHdPortraitPoster(
                            a,
                            v.title,
                            v.year,
                            v.actor,
                            v.director,
                            v.poster,
                            hdBmp -> {
                                posterHook.applyPosterBitmap(hdBmp, true);
                                refreshEpisodeStillBitmaps(a.root, hdBmp);
                            });
                    for (java.util.Iterator<Cms.Line> it = v.lines.iterator(); it.hasNext(); ) {
                        if (it.next().episodes.isEmpty()) it.remove();
                    }
                    if (v.lines.isEmpty()
                            && openingBookmark != null
                            && curSite.searchable
                            && !sameSiteHistoryRetried[0]
                            && trySameSiteRecoverRef[0] != null) {
                        trySameSiteRecoverRef[0].run();
                        return;
                    }
                    lowerBody.removeView(loadingState);
                    synopsisWrap.removeAllViews();
                    playBtnWrap.removeAllViews();
                    detailsBody.removeAllViews();
                    PlaybackLineRules.applyToVideo(a, curSite, v);
                    int defaultLineIdx = SourcePreferences.lineIndex(a, curSite, v);
                    int firstLineCount =
                            v.lines.isEmpty() ? 0 : v.lines.get(defaultLineIdx).episodes.size();
                    populateHeroPills(a, pillsRow, v, firstLineCount);
                    updateRatingBadges(doubanBadge, rtBadge, v, 0.0);
                    ImmersivePoster.resolveMediaRatings(
                            a,
                            v,
                            ratings ->
                                    updateRatingBadges(
                                            doubanBadge,
                                            rtBadge,
                                            v,
                                            ratings.douban,
                                            ratings.rtPercent));

                    // Animated Expandable Synopsis Card (borderless bgCard + rotating chevron)
                    String descRaw = v.description == null ? "" : v.description.trim();
                    String castRaw =
                            (v.actor != null && !v.actor.trim().isEmpty())
                                    ? "演职员：" + v.actor.trim()
                                    : "";
                    if (!descRaw.isEmpty() || !castRaw.isEmpty()) {
                        LinearLayout synCard = a.vertical();
                        synCard.setBackground(MobileTheme.cardBg(a, 16));
                        if (!p.isDark) UiCompat.setElevation(synCard, a.dp(1.5f));
                        synCard.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
                        MobileMotion.bindPress(synCard, 0.985f);

                        final TextView descTv =
                                a.text(descRaw.isEmpty() ? castRaw : descRaw, 13.5f, p.textPrimary);
                        descTv.setLineSpacing(a.dp(3.5f), 1f);
                        descTv.setMaxLines(3);
                        descTv.setEllipsize(TextUtils.TruncateAt.END);
                        synCard.addView(descTv, new LinearLayout.LayoutParams(-1, -2));

                        final TextView castTv = a.text(castRaw, 12, p.textSecondary);
                        castTv.setPadding(0, a.dp(6), 0, 0);
                        castTv.setMaxLines(3);
                        castTv.setEllipsize(TextUtils.TruncateAt.END);
                        castTv.setVisibility(View.GONE);
                        if (!descRaw.isEmpty() && !castRaw.isEmpty()) {
                            synCard.addView(castTv, new LinearLayout.LayoutParams(-1, -2));
                        }

                        LinearLayout toggleRow = a.row();
                        toggleRow.setGravity(Gravity.CENTER_VERTICAL);
                        toggleRow.setPadding(0, a.dp(7), 0, 0);
                        final TextView toggleHint = a.text("展开简介", 12f, p.accent);
                        toggleHint.setTypeface(null, Typeface.BOLD);
                        toggleRow.addView(toggleHint);
                        final MobileIcons.IconView toggleChevron =
                                MobileIcons.create(a, MobileIcons.IC_CHEVRON_DOWN, 12.5f, p.accent);
                        LinearLayout.LayoutParams tcLp =
                                new LinearLayout.LayoutParams(a.dp(12.5f), a.dp(12.5f));
                        tcLp.leftMargin = a.dp(4);
                        toggleRow.addView(toggleChevron, tcLp);
                        synCard.addView(toggleRow, new LinearLayout.LayoutParams(-2, -2));

                        final boolean[] expanded = {false};
                        synCard.setOnClickListener(
                                view -> {
                                    expanded[0] = !expanded[0];
                                    descTv.setMaxLines(expanded[0] ? 18 : 3);
                                    MobileMotion.crossfadeText(
                                            toggleHint, expanded[0] ? "收起简介" : "展开简介");
                                    float targetRot = expanded[0] ? 180f : 0f;
                                    if (MobileMotion.isReduced(a)) {
                                        toggleChevron.setRotation(targetRot);
                                    } else {
                                        toggleChevron
                                                .animate()
                                                .rotation(targetRot)
                                                .setDuration(MotionTokens.DURATION_FAST_MS)
                                                .setInterpolator(
                                                        MotionTokens.createStandardInterpolator())
                                                .start();
                                    }
                                    if (!descRaw.isEmpty() && !castRaw.isEmpty()) {
                                        MobileMotion.animateExpandCollapse(castTv, expanded[0]);
                                    }
                                });
                        synopsisWrap.addView(synCard, new LinearLayout.LayoutParams(-1, -2));
                    }

                    if (v.lines.isEmpty()) {
                        sourceTopBtn.setText(curSite.name);
                        srcDownIcon.setVisibility(View.GONE);
                        TextView empty = a.text("暂未获取到可播放的剧集资源", 14, p.textSecondary);
                        empty.setGravity(Gravity.CENTER);
                        empty.setPadding(a.dp(4), a.dp(20), a.dp(4), a.dp(20));
                        detailsBody.addView(empty, new LinearLayout.LayoutParams(-1, -2));
                        return;
                    }

                    WatchHistory.Entry bookmark = null;
                    for (WatchHistory.Entry entry : a.watchHistory()) {
                        if (entry != null
                                && Objects.equals(entry.site, curSite.key)
                                && Objects.equals(entry.id, v.id)) {
                            bookmark = entry;
                            break;
                        }
                    }
                    if (bookmark == null
                            && a.historyFallbackBookmark != null
                            && Objects.equals(a.historyFallbackBookmark.site, curSite.key)
                            && (Objects.equals(a.historyFallbackBookmark.id, v.id)
                                    || sameSiteHistoryRetried[0])) {
                        bookmark = a.historyFallbackBookmark;
                    }
                    final WatchHistory.Entry remembered = bookmark;

                    // Reset per-presentation user-selection state so a vanished original drive
                    // prompts re-selection until the user explicitly chooses another line/episode.
                    resetDetailSelectionState();

                    // Full-Width Accent Stadium Play Button
                    final boolean presentAiUnlocked = !a.isTvDevice() && AiBetaGate.isUnlocked(a);
                    final int presentStoredCleanMode =
                            !a.isTvDevice()
                                    ? a.mobilePrefs().getInt(Prefs.EPISODE_CLEAN_MODE, 0)
                                    : 0;
                    SeasonMeta curSeason = parseSeasonMeta(v.title);
                    final PrimaryPlayAction initialPlayAction =
                            resolvePrimaryPlayAction(
                                    v,
                                    defaultLineIdx,
                                    remembered,
                                    false,
                                    null,
                                    -1,
                                    presentAiUnlocked,
                                    presentStoredCleanMode);
                    final boolean hasRememberedMatch =
                            remembered != null && !initialPlayAction.requiresReselection;
                    int remEpNum =
                            remembered != null && remembered.index >= 0 ? remembered.index + 1 : 1;
                    String remDisplayLine = remembered != null ? remembered.line : "";
                    if (hasRememberedMatch && initialPlayAction.line != null) {
                        remEpNum = initialPlayAction.episodeIndex + 1;
                        if (initialPlayAction.line.name != null
                                && !initialPlayAction.line.name.isEmpty()) {
                            remDisplayLine = initialPlayAction.line.name;
                        }
                    }

                    Button playBtn = new Button(a);
                    playBtn.setTag("detail-play");
                    playBtn.setAllCaps(false);
                    playBtn.setMaxLines(1);
                    playBtn.setSingleLine(true);
                    playBtn.setEllipsize(TextUtils.TruncateAt.END);
                    playBtn.setGravity(Gravity.CENTER);
                    playBtn.setIncludeFontPadding(false);
                    playBtn.setTextSize(15f);
                    playBtn.setTypeface(null, Typeface.BOLD);
                    playBtn.setTextColor(p.accentOnFill);
                    playBtn.setBackground(MobileTheme.accentPillBg(a, 999));
                    playBtn.setPadding(a.dp(18), 0, a.dp(18), 0);
                    UiCompat.setElevation(playBtn, a.dp(p.isDark ? 4f : 3f));
                    MobileMotion.bindPress(playBtn, 0.96f);
                    bindPrimaryPlayButton(a, curSite, v, playBtn, initialPlayAction);
                    playBtnWrap.addView(playBtn, new LinearLayout.LayoutParams(-1, a.dp(48)));

                    if (remembered != null) {
                        String bmEpTitle =
                                formatPlayEpisodeLabel(
                                        hasRememberedMatch && initialPlayAction.episode != null
                                                ? initialPlayAction.episode.name
                                                : remembered.episode,
                                        remEpNum,
                                        presentAiUnlocked,
                                        presentStoredCleanMode);
                        String bmSummary =
                                remembered.position > 0
                                        ? "已观看 ["
                                                + bmEpTitle
                                                + "] 至 "
                                                + PlaybackController.formatTime(remembered.position)
                                                + " · 线路："
                                                + remDisplayLine
                                        : "已观看 [" + bmEpTitle + "] · 线路：" + remDisplayLine;
                        if (!hasRememberedMatch) {
                            bmSummary = bmSummary + "（原线路或集数已变更，请在下方重选）";
                        }
                        TextView bmInfo = a.text(bmSummary, 12, p.textSecondary);
                        bmInfo.setTag("detail-history-summary");
                        bmInfo.setSingleLine(true);
                        bmInfo.setEllipsize(TextUtils.TruncateAt.MIDDLE);
                        bmInfo.setGravity(Gravity.CENTER);
                        bmInfo.setPadding(a.dp(8), a.dp(8), a.dp(8), 0);
                        playBtnWrap.addView(bmInfo, new LinearLayout.LayoutParams(-1, -2));
                    }

                    int initLine = defaultLineIdx, initPage = 0;
                    if (hasRememberedMatch && initialPlayAction.line != null) {
                        int matchedIdx = v.lines.indexOf(initialPlayAction.line);
                        if (matchedIdx >= 0) {
                            initLine = matchedIdx;
                            int remIdx = Math.max(0, initialPlayAction.episodeIndex);
                            initPage =
                                    (activeVideoDescending
                                                    ? initialPlayAction.line.episodes.size()
                                                            - 1
                                                            - remIdx
                                                    : remIdx)
                                            / 50;
                        }
                    }

                    LinearLayout episodePanel = a.vertical();
                    episodePanel.setTag("detail-episodes");
                    detailsBody.addView(episodePanel, new LinearLayout.LayoutParams(-1, -2));

                    final Map<Integer, Cms.Video> discoveredSeasons = new TreeMap<>();
                    final Map<Integer, String> discoveredLabels = new TreeMap<>();
                    discoveredSeasons.put(curSeason.seasonNumber, v);
                    discoveredLabels.put(curSeason.seasonNumber, curSeason.seasonLabel);

                    renderMobileEpisodes(
                            a,
                            curSite,
                            v,
                            initLine,
                            initPage,
                            episodePanel,
                            remembered,
                            discoveredSeasons,
                            discoveredLabels);
                    populateRelatedSeasons(
                            a,
                            curSite,
                            v,
                            episodePanel,
                            initLine,
                            initPage,
                            remembered,
                            discoveredSeasons,
                            discoveredLabels);
                };

        final Runnable showUnavailableFallback =
                () -> {
                    if (openingBookmark != null
                            && !a.historyFallbackInFlight
                            && CatalogScreen.hasAlternativeHistorySources(a, s.key)) {
                        a.historyFallbackBookmark = null;
                        CatalogScreen.resumeHistoryFromAlternativeSources(
                                a, openingBookmark, s.key, "原片源链接已失效", true);
                        return;
                    }
                    loadingState.setVisibility(View.VISIBLE);
                    loadingState.setText("暂未获取到可播放的剧集资源");
                    sourceTopBtn.setText(s.name);
                    srcDownIcon.setVisibility(View.GONE);
                };

        trySameSiteRecoverRef[0] =
                () -> {
                    if (sameSiteHistoryRetried[0]
                            || openingBookmark == null
                            || !s.searchable
                            || openingBookmark.title == null
                            || openingBookmark.title.trim().isEmpty()) {
                        showUnavailableFallback.run();
                        return;
                    }
                    sameSiteHistoryRetried[0] = true;
                    if (loadingState.getParent() == null) {
                        detailsBody.removeAllViews();
                        detailsBody.addView(loadingState, new LinearLayout.LayoutParams(-1, -2));
                    }
                    loadingState.setVisibility(View.VISIBLE);
                    loadingState.setText("正在从「" + s.name + "」重新匹配剧集与上次进度…");
                    a.details.execute(
                            () -> {
                                Cms.Video recovered = null;
                                try {
                                    String cleanKw =
                                            HistoryResumeMatcher.cleanSearchTitle(
                                                    openingBookmark.title);
                                    SourceEngine eng = SourceController.engine(a, s, recoverCtx);
                                    List<Cms.Video> cands =
                                            Cms.listing(eng.search(cleanKw, 1)).videos;
                                    Cms.Video bestCand = null;
                                    int bestScore = 54;
                                    if (cands != null) {
                                        for (Cms.Video cand : cands) {
                                            if (cand == null) continue;
                                            int sc =
                                                    HistoryResumeMatcher.scoreTitleMatch(
                                                            openingBookmark, cand);
                                            if (openingBookmark.id != null
                                                    && openingBookmark.id.equals(cand.id)) {
                                                sc += 20;
                                            }
                                            if (sc > bestScore) {
                                                bestScore = sc;
                                                bestCand = cand;
                                            }
                                        }
                                    }
                                    if (bestCand != null) {
                                        boolean hasInline = false;
                                        if (bestCand.lines != null) {
                                            for (Cms.Line line : bestCand.lines) {
                                                if (line != null
                                                        && line.episodes != null
                                                        && !line.episodes.isEmpty()) {
                                                    hasInline = true;
                                                    break;
                                                }
                                            }
                                        }
                                        if (hasInline) {
                                            recovered = bestCand;
                                        } else {
                                            Cms.Listing det = Cms.listing(eng.detail(bestCand.id));
                                            if (det != null && !det.videos.isEmpty()) {
                                                recovered = det.videos.get(0);
                                            }
                                        }
                                        if (recovered != null) {
                                            if (Cms.Site.isGenericPlaceholderVodId(recovered.id)
                                                    && !Cms.Site.isGenericPlaceholderVodId(
                                                            bestCand.id)) {
                                                recovered.id = bestCand.id;
                                            }
                                            if (recovered.title == null
                                                    || recovered.title.trim().isEmpty()) {
                                                recovered.title =
                                                        bestCand.title != null
                                                                        && !bestCand.title
                                                                                .trim()
                                                                                .isEmpty()
                                                                ? bestCand.title
                                                                : openingBookmark.title;
                                            }
                                            if (recovered.poster == null
                                                    || recovered.poster.trim().isEmpty()) {
                                                recovered.poster =
                                                        bestCand.poster != null
                                                                        && !bestCand.poster
                                                                                .trim()
                                                                                .isEmpty()
                                                                ? bestCand.poster
                                                                : openingBookmark.poster;
                                            }
                                        }
                                    }
                                } catch (Throwable ignored) {
                                    recovered = null;
                                }
                                final Cms.Video finalVideo = recovered;
                                boolean hasLines = false;
                                if (finalVideo != null && finalVideo.lines != null) {
                                    for (Cms.Line l : finalVideo.lines) {
                                        if (l != null
                                                && l.episodes != null
                                                && !l.episodes.isEmpty()) {
                                            hasLines = true;
                                            break;
                                        }
                                    }
                                }
                                final boolean readyPlayable = hasLines;
                                a.ui.post(
                                        () -> {
                                            if (a.isFinishing()
                                                    || a.current != screen
                                                    || ticket != a.generation
                                                    || !recoverCtx.matches(
                                                            a.config,
                                                            a.privateMode,
                                                            a.engineEpoch)) {
                                                return;
                                            }
                                            if (readyPlayable) {
                                                WatchHistory.Entry rebound =
                                                        WatchHistory.cloneEntry(openingBookmark);
                                                if (rebound != null) {
                                                    if (!Cms.Site.isGenericPlaceholderVodId(
                                                            finalVideo.id)) {
                                                        rebound.id = finalVideo.id;
                                                    }
                                                    if (Cms.Site.looksLikeNetdiskShareId(
                                                            finalVideo.id)) {
                                                        rebound.shareUrl = finalVideo.id.trim();
                                                    }
                                                    if (!a.privateMode
                                                            && !Cms.Site.isGenericPlaceholderVodId(
                                                                    rebound.id)
                                                            && !Objects.equals(
                                                                    openingBookmark.key(),
                                                                    rebound.key())) {
                                                        WatchHistory.enqueueUpsert(
                                                                a.historyPersistence(), rebound);
                                                        CloudSyncDialog.removeHistoryWithTombstone(
                                                                a, openingBookmark.key(), null);
                                                    }
                                                    a.historyFallbackBookmark = rebound;
                                                }
                                                try {
                                                    present.accept(finalVideo);
                                                } catch (Exception e) {
                                                    AppLog.w(
                                                            "MobileDetailScreen",
                                                            "present recovered detail failed",
                                                            e);
                                                }
                                            } else {
                                                showUnavailableFallback.run();
                                            }
                                        });
                            });
                };

        if (ready == null && MobileCuratedDiscovery.isCuratedSite(s)) {
            resolveCuratedFromUserSources(
                    a,
                    listing,
                    activeSiteRef,
                    siteBadge,
                    sourceTopBtn,
                    syncFavStyle,
                    playBtnWrap,
                    loadingState,
                    detailsBody,
                    present);
        } else if (ready == null) {
            if (openingBookmark != null
                    && s.searchable
                    && Cms.Site.isGenericPlaceholderVodId(listing.id)) {
                trySameSiteRecoverRef[0].run();
            } else {
                a.loadDetail(
                        s,
                        listing.id,
                        present,
                        err -> {
                            if (a.isFinishing()
                                    || a.current != screen
                                    || ticket != a.generation
                                    || !recoverCtx.matches(
                                            a.config, a.privateMode, a.engineEpoch)) {
                                return;
                            }
                            if (openingBookmark != null
                                    && s.searchable
                                    && !sameSiteHistoryRetried[0]) {
                                trySameSiteRecoverRef[0].run();
                                return;
                            }
                            loadingState.setVisibility(View.VISIBLE);
                            loadingState.setText(a.message(err));
                        });
            }
        } else {
            try {
                present.accept(ready);
            } catch (Exception e) {
                AppLog.w("MobileDetailScreen", "present detail failed", e);
            }
        }
    }

    /**
     * Resolves a curated discovery item strictly from the user's own added subscription sources
     * (matching iOS {@code _resolveCuratedFromUserSources}). Never supplies built-in streams.
     */
    private static void resolveCuratedFromUserSources(
            final MainActivity a,
            final Cms.Video targetVideo,
            final Cms.Site[] activeSiteRef,
            final TextView siteBadge,
            final TextView sourceTopBtn,
            final Runnable syncFavStyle,
            final LinearLayout playBtnWrap,
            final TextView loadingState,
            final LinearLayout detailsBody,
            final MainActivity.Done<Cms.Video> present) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        final List<Cms.Site> candidates = new ArrayList<>();
        if (a.config != null && a.config.sites != null) {
            String prefKey = a.prefs != null ? a.prefs.getString(Prefs.SELECTED_SITE, "") : "";
            for (Cms.Site cand : a.config.sites) {
                if (cand == null
                        || !a.available(cand)
                        || !cand.searchable
                        || MobileCuratedDiscovery.isCuratedSite(cand)) {
                    continue;
                }
                if (cand.key.equals(prefKey)) {
                    candidates.add(0, cand);
                } else {
                    candidates.add(cand);
                }
            }
        }
        if (candidates.isEmpty()) {
            playBtnWrap.removeAllViews();
            Button noSrcPlay = new Button(a);
            noSrcPlay.setTag("detail-play");
            noSrcPlay.setAllCaps(false);
            noSrcPlay.setSingleLine(true);
            noSrcPlay.setGravity(Gravity.CENTER);
            noSrcPlay.setTextSize(14.5f);
            noSrcPlay.setTypeface(null, Typeface.BOLD);
            noSrcPlay.setTextColor(p.accentOnFill);
            noSrcPlay.setBackground(MobileTheme.accentPillBg(a, 999));
            noSrcPlay.setText("暂无数据 · 请添加订阅资源");
            MobileMotion.bindPress(noSrcPlay, 0.96f);
            noSrcPlay.setOnClickListener(
                    v -> {
                        a.toast("暂无片源数据，请先添加订阅资源");
                        UiWidgets.showMobileImportDialog(a);
                    });
            playBtnWrap.addView(noSrcPlay, new LinearLayout.LayoutParams(-1, a.dp(48)));
            loadingState.setText("暂无片源数据，请先添加订阅资源后再播放《" + targetVideo.title + "》");
            return;
        }

        final int ticket = a.generation;
        final String query =
                targetVideo.title == null
                        ? ""
                        : targetVideo.title.replaceAll("\\s+第[一二三四五六七八九十0-9]+季$", "").trim();
        final String effectiveQuery = query.isEmpty() ? targetVideo.title : query;
        final List<Cms.Site> searchTargets = candidates.subList(0, Math.min(8, candidates.size()));

        a.submitPage(
                () -> {
                    Cms.Site bestSite = null;
                    Cms.Video bestMatch = null;
                    int bestScore = 0;

                    for (Cms.Site site : searchTargets) {
                        if (a.isFinishing() || ticket != a.generation) return;
                        try {
                            List<Cms.Video> found =
                                    Cms.listing(a.engine(site).search(effectiveQuery, 1)).videos;
                            for (Cms.Video cand : found) {
                                int sc =
                                        MobileCuratedDiscovery.titleMatchScore(
                                                targetVideo.title, cand.title);
                                if (sc >= 60 && sc > bestScore) {
                                    bestScore = sc;
                                    bestSite = site;
                                    bestMatch = cand;
                                }
                            }
                            if (bestScore >= 100) break;
                        } catch (Throwable ignored) {
                        }
                    }

                    Cms.Video resolved = null;
                    Cms.Site resolvedSite = bestSite;
                    if (bestSite != null && bestMatch != null) {
                        try {
                            Cms.Listing detailListing =
                                    Cms.listing(a.engine(bestSite).detail(bestMatch.id));
                            Cms.Video detailed =
                                    detailListing.videos.isEmpty()
                                            ? null
                                            : detailListing.videos.get(0);
                            if (detailed != null && detailed.lines != null) {
                                for (java.util.Iterator<Cms.Line> it = detailed.lines.iterator();
                                        it.hasNext(); ) {
                                    if (it.next().episodes.isEmpty()) it.remove();
                                }
                                if (!detailed.lines.isEmpty()) {
                                    if (detailed.title == null || detailed.title.trim().isEmpty()) {
                                        detailed.title = targetVideo.title;
                                    }
                                    if (detailed.poster == null
                                            || detailed.poster.trim().isEmpty()) {
                                        detailed.poster = targetVideo.poster;
                                    }
                                    if (detailed.year == null || detailed.year.trim().isEmpty()) {
                                        detailed.year = targetVideo.year;
                                    }
                                    if (detailed.area == null || detailed.area.trim().isEmpty()) {
                                        detailed.area = targetVideo.area;
                                    }
                                    if (detailed.actor == null || detailed.actor.trim().isEmpty()) {
                                        detailed.actor = targetVideo.actor;
                                    }
                                    if (detailed.description == null
                                            || detailed.description.trim().isEmpty()) {
                                        detailed.description = targetVideo.description;
                                    }
                                    if (detailed.remarks == null
                                            || detailed.remarks.trim().isEmpty()) {
                                        detailed.remarks = targetVideo.remarks;
                                    }
                                    resolved = detailed;
                                }
                            }
                        } catch (Throwable ignored) {
                        }
                    }

                    final Cms.Site finalSite = resolvedSite;
                    final Cms.Video finalVideo = resolved;
                    a.ui.post(
                            () -> {
                                if (a.isFinishing() || ticket != a.generation) return;
                                if (finalSite != null && finalVideo != null) {
                                    activeSiteRef[0] = finalSite;
                                    siteBadge.setText(finalSite.name);
                                    sourceTopBtn.setText(finalSite.name);
                                    syncFavStyle.run();
                                    try {
                                        present.accept(finalVideo);
                                    } catch (Exception e) {
                                        AppLog.w("MobileDetailScreen", "present curated failed", e);
                                    }
                                    return;
                                }
                                loadingState.setText(
                                        "您已添加的订阅源中暂未找到《" + targetVideo.title + "》的播放资源");
                                TextView searchCta = a.text("全源手动搜索", 13.5f, p.accentOnFill);
                                searchCta.setTypeface(null, Typeface.BOLD);
                                searchCta.setGravity(Gravity.CENTER);
                                searchCta.setPadding(a.dp(20), a.dp(10), a.dp(20), a.dp(10));
                                searchCta.setBackground(MobileTheme.accentPillBg(a, 999));
                                MobileMotion.bindPress(searchCta, 0.94f);
                                searchCta.setOnClickListener(
                                        v -> MobileRootShell.openSearch(a, targetVideo.title));
                                LinearLayout.LayoutParams lp =
                                        new LinearLayout.LayoutParams(-2, -2);
                                lp.gravity = Gravity.CENTER_HORIZONTAL;
                                detailsBody.addView(searchCta, lp);
                            });
                });
    }

    private static void populateHeroPills(
            MainActivity a, LinearLayout pillsRow, Cms.Video v, int epCount) {
        pillsRow.removeAllViews();
        List<String> tags = new ArrayList<>();
        if (v.year != null && !v.year.trim().isEmpty()) tags.add(v.year.trim());
        if (v.area != null && !v.area.trim().isEmpty()) tags.add(v.area.trim());
        if (v.tag != null && !v.tag.trim().isEmpty()) tags.add(v.tag.trim());
        if (v.remarks != null && !v.remarks.trim().isEmpty()) {
            tags.add(v.remarks.trim());
        } else if (epCount > 1) {
            tags.add("共" + epCount + "集");
        }
        int limit = Math.min(4, tags.size());
        for (int i = 0; i < limit; i++) {
            TextView pill = a.text(tags.get(i), 12, 0xF2FFFFFF);
            pill.setTypeface(null, Typeface.BOLD);
            pill.setSingleLine(true);
            pill.setPadding(a.dp(11), a.dp(4), a.dp(11), a.dp(4));
            pill.setBackground(a.bg(0x38000000, 999));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            if (i > 0) lp.leftMargin = a.dp(7);
            pillsRow.addView(pill, lp);
        }
    }

    private static void restoreScrollAfterLayout(MainActivity a, int savedScrollY) {
        if (a == null || a.scroll == null || savedScrollY <= 0) return;
        final View scroll = a.scroll;
        scroll.post(() -> scroll.scrollTo(0, savedScrollY));
    }

    static void renderMobileEpisodes(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            int lineIndex,
            int page,
            LinearLayout panel,
            WatchHistory.Entry remembered,
            Map<Integer, Cms.Video> discoveredSeasons,
            Map<Integer, String> discoveredLabels) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return;
        final int safeLineIdx = Math.max(0, Math.min(lineIndex, video.lines.size() - 1));
        final Cms.Line line = video.lines.get(safeLineIdx);
        final int total = line.episodes.size();
        final int safePage = EpisodeSelection.boundPage(page, total);
        activeDetailLineIndex = safeLineIdx;
        activeDetailPage = safePage;

        final int savedScrollY = a.scroll != null ? a.scroll.getScrollY() : 0;
        if (a.current != null) {
            a.current.selection.select(line.name, safePage, total);
        }

        // Preserve horizontal line strip scroll & update active line pills in place when available
        HorizontalScrollView existingLineScroll = null;
        LinearLayout existingLineRow = null;
        int savedLineScrollX = 0;
        View existingLinesTag = panel.findViewWithTag("detail-line-scroll");
        if (existingLinesTag instanceof HorizontalScrollView && video.lines.size() > 1) {
            existingLineScroll = (HorizontalScrollView) existingLinesTag;
            savedLineScrollX = existingLineScroll.getScrollX();
            if (existingLineScroll.getChildCount() > 0
                    && existingLineScroll.getChildAt(0) instanceof LinearLayout) {
                existingLineRow = (LinearLayout) existingLineScroll.getChildAt(0);
            }
        }

        final MobileTheme.Palette p = MobileTheme.of(a);
        final boolean descending = activeVideoDescending;
        final SeasonMeta curSeason = parseSeasonMeta(video.title);
        final boolean multiEpisode = shouldShowMultiEpisodeTools(total);
        // Snapshot AI gate state & clean mode ONCE per episode-list render (P1-7: avoid O(N)
        // Ed25519
        // signature verifications across 50/200 episodes on the UI thread).
        final boolean renderAiUnlocked = !a.isTvDevice() && AiBetaGate.isUnlocked(a);
        final int renderStoredCleanMode =
                !a.isTvDevice() ? a.mobilePrefs().getInt(Prefs.EPISODE_CLEAN_MODE, 0) : 0;
        final boolean lineMatchesBookmark =
                remembered != null && HistoryResumeMatcher.isSameBookmarkLine(line, remembered);
        final boolean hasExplicitEpisodeOnLine =
                selectedEpisodeIndex >= 0
                        && selectedEpisodeIndex < total
                        && matchesSelectedEpisodeLine(safeLineIdx, line);
        final PrimaryPlayAction renderPlayAction =
                resolvePrimaryPlayAction(
                        video,
                        safeLineIdx,
                        remembered,
                        userSelectedDetailTarget,
                        line,
                        hasExplicitEpisodeOnLine
                                ? selectedEpisodeIndex
                                : (lineMatchesBookmark
                                        ? HistoryResumeMatcher.findMatchedEpisodeIndex(
                                                line, remembered)
                                        : 0),
                        awaitingExplicitReselection,
                        renderAiUnlocked,
                        renderStoredCleanMode);

        int activeEpIdx = renderPlayAction.requiresReselection ? -1 : 0;
        if (hasExplicitEpisodeOnLine) {
            activeEpIdx = selectedEpisodeIndex;
        } else if (lineMatchesBookmark && !renderPlayAction.requiresReselection) {
            activeEpIdx = HistoryResumeMatcher.findMatchedEpisodeIndex(line, remembered);
        }

        // Update Top-Right Source Pill, Primary Play Button & Download Button
        if (a.root != null) {
            View playBtnView = a.root.findViewWithTag("detail-play");
            if (playBtnView instanceof Button && !line.episodes.isEmpty()) {
                bindPrimaryPlayButton(a, site, video, (Button) playBtnView, renderPlayAction);
            }
            View topSourceLabelView = a.root.findViewWithTag("detail-source-picker");
            View topSourceChevron = a.root.findViewWithTag("detail-source-chevron");
            View topSourceClickTarget = a.root.findViewWithTag("detail-source-pill");
            if (topSourceClickTarget == null) topSourceClickTarget = topSourceLabelView;
            boolean hasMultiLines = video.lines.size() > 1;
            if (topSourceLabelView instanceof TextView) {
                ((TextView) topSourceLabelView).setText(hasMultiLines ? line.name : "换源");
            }
            if (topSourceChevron != null) {
                topSourceChevron.setVisibility(hasMultiLines ? View.VISIBLE : View.GONE);
            }
            if (topSourceClickTarget != null) {
                if (hasMultiLines) {
                    topSourceClickTarget.setOnClickListener(
                            v ->
                                    showLinePickerSheet(
                                            a,
                                            site,
                                            video,
                                            safeLineIdx,
                                            panel,
                                            remembered,
                                            discoveredSeasons,
                                            discoveredLabels));
                } else {
                    // Single line: avoid pointless 1-item picker, directly trigger cross-search!
                    topSourceClickTarget.setOnClickListener(
                            v -> a.crossSearch(Cms.searchTitle(video)));
                }
            }
            final boolean preselectDownload = !renderPlayAction.requiresReselection;
            Cms.Episode pickEp = null;
            int pickIdx = -1;
            if (preselectDownload) {
                if (hasExplicitEpisodeOnLine) {
                    pickIdx = selectedEpisodeIndex;
                    pickEp = line.episodes.get(selectedEpisodeIndex);
                } else if (renderPlayAction.line == line
                        && renderPlayAction.episode != null
                        && renderPlayAction.episodeIndex >= 0
                        && renderPlayAction.episodeIndex < line.episodes.size()) {
                    pickIdx = renderPlayAction.episodeIndex;
                    pickEp = renderPlayAction.episode;
                } else if (lineMatchesBookmark) {
                    int matchedIdx = HistoryResumeMatcher.findMatchedEpisodeIndex(line, remembered);
                    if (matchedIdx >= 0 && matchedIdx < line.episodes.size()) {
                        pickIdx = matchedIdx;
                        pickEp = line.episodes.get(matchedIdx);
                    }
                }
            }
            bindTopDownloadButton(a, site, video, line, pickEp, pickIdx, preselectDownload);
        }

        // Keep line strip in place when switching between lines so its scroll position stays steady
        LinearLayout bodyHost = null;
        if (existingLineScroll != null && existingLineRow != null) {
            View existingBody = panel.findViewWithTag("detail-episodes-body");
            if (existingBody instanceof LinearLayout) {
                bodyHost = (LinearLayout) existingBody;
                bodyHost.removeAllViews();
                for (int i = 0;
                        i < video.lines.size() && i < existingLineRow.getChildCount();
                        i++) {
                    View child = existingLineRow.getChildAt(i);
                    if (child instanceof TextView) {
                        TextView lPill = (TextView) child;
                        boolean activeLine = (i == safeLineIdx);
                        lPill.setTextColor(activeLine ? p.accent : p.textSecondary);
                        lPill.setTypeface(null, activeLine ? Typeface.BOLD : Typeface.NORMAL);
                        lPill.setBackground(MobileTheme.pillBg(a, activeLine, 999));
                    }
                }
                final HorizontalScrollView preservedLineScroll = existingLineScroll;
                final int preservedX = savedLineScrollX;
                preservedLineScroll.post(() -> preservedLineScroll.scrollTo(preservedX, 0));
            }
        }

        if (bodyHost == null) {
            panel.removeAllViews();
            // 0. Quick Horizontal Source Line Pills (only when > 1 line exists)
            if (video.lines.size() > 1) {
                HorizontalScrollView lineScroll = new HorizontalScrollView(a);
                lineScroll.setTag("detail-line-scroll");
                lineScroll.setHorizontalScrollBarEnabled(false);
                LinearLayout lineRow = a.row();
                lineRow.setGravity(Gravity.CENTER_VERTICAL);
                for (int i = 0; i < video.lines.size(); i++) {
                    final int targetLineIdx = i;
                    Cms.Line candLine = video.lines.get(i);
                    boolean activeLine = (i == safeLineIdx);
                    TextView lPill =
                            a.text(
                                    candLine.name + " · " + candLine.episodes.size(),
                                    12.5f,
                                    activeLine ? p.accent : p.textSecondary);
                    lPill.setTag("detail-line-pill:" + candLine.lineId());
                    lPill.setTypeface(null, activeLine ? Typeface.BOLD : Typeface.NORMAL);
                    lPill.setPadding(a.dp(13), a.dp(6), a.dp(13), a.dp(6));
                    lPill.setBackground(MobileTheme.pillBg(a, activeLine, 999));
                    MobileMotion.bindPress(lPill, 0.94f);
                    lPill.setOnClickListener(
                            v -> {
                                awaitingExplicitReselection = false;
                                userSelectedDetailTarget = true;
                                selectedEpisodeLine = candLine.name == null ? "" : candLine.name;
                                selectedEpisodeLineId = candLine.lineId();
                                selectedEpisodeLineIndex = targetLineIdx;
                                selectedEpisodeIndex = -1;
                                a.prefs
                                        .edit()
                                        .putString(Prefs.PREFERRED_LINE, candLine.rawName())
                                        .apply();
                                renderMobileEpisodes(
                                        a,
                                        site,
                                        video,
                                        targetLineIdx,
                                        0,
                                        panel,
                                        remembered,
                                        discoveredSeasons,
                                        discoveredLabels);
                            });
                    lPill.setOnLongClickListener(
                            v -> {
                                openLineManagementSheet(
                                        a,
                                        site,
                                        video,
                                        candLine,
                                        safeLineIdx,
                                        panel,
                                        remembered,
                                        discoveredSeasons,
                                        discoveredLabels);
                                return true;
                            });
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                    lp.rightMargin = a.dp(8);
                    lineRow.addView(lPill, lp);
                }

                LinearLayout crossBtn = a.row();
                crossBtn.setGravity(Gravity.CENTER_VERTICAL);
                crossBtn.setPadding(a.dp(11), a.dp(6), a.dp(12), a.dp(6));
                crossBtn.setBackground(MobileTheme.subtleBg(a, 999));
                MobileIcons.IconView csIcon =
                        MobileIcons.create(a, MobileIcons.IC_SEARCH, 12.5f, p.textSecondary);
                LinearLayout.LayoutParams csiLp =
                        new LinearLayout.LayoutParams(a.dp(12.5f), a.dp(12.5f));
                csiLp.rightMargin = a.dp(4);
                crossBtn.addView(csIcon, csiLp);
                TextView csLbl = a.text("换源搜", 12.5f, p.textSecondary);
                crossBtn.addView(csLbl);
                MobileMotion.bindPress(crossBtn, 0.94f);
                crossBtn.setOnClickListener(v -> a.crossSearch(Cms.searchTitle(video)));
                lineRow.addView(crossBtn);

                lineScroll.addView(lineRow);
                LinearLayout.LayoutParams lsLp = new LinearLayout.LayoutParams(-1, -2);
                lsLp.bottomMargin = a.dp(14);
                panel.addView(lineScroll, lsLp);
            }

            bodyHost = a.vertical();
            bodyHost.setTag("detail-episodes-body");
            panel.addView(bodyHost, new LinearLayout.LayoutParams(-1, -2));
        }

        // 1. Header Row: Season Selector + Cleaner + (multi-episode only: Sort & All-Episodes)
        LinearLayout headerRow = a.row();
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        bodyHost.addView(headerRow, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout seasonBtn = a.row();
        seasonBtn.setTag("detail-season-picker");
        seasonBtn.setGravity(Gravity.CENTER_VERTICAL);
        MobileMotion.bindPress(seasonBtn, 0.96f);

        String headerTitle =
                multiEpisode || discoveredSeasons.size() > 1 ? curSeason.seasonLabel : "正片资源";
        TextView seasonTitle = a.text(headerTitle, 18, p.textPrimary);
        seasonTitle.setTypeface(null, Typeface.BOLD);
        seasonBtn.addView(seasonTitle);

        if (discoveredSeasons.size() > 1) {
            TextView countBadge =
                    a.text("共" + discoveredSeasons.size() + "季", 10.5f, p.textSecondary);
            countBadge.setTypeface(null, Typeface.BOLD);
            countBadge.setPadding(a.dp(7), a.dp(2), a.dp(7), a.dp(2));
            countBadge.setBackground(MobileTheme.subtleBg(a, 999));
            LinearLayout.LayoutParams cbLp = new LinearLayout.LayoutParams(-2, -2);
            cbLp.leftMargin = a.dp(6);
            seasonBtn.addView(countBadge, cbLp);

            MobileIcons.IconView seasonChev =
                    MobileIcons.create(a, MobileIcons.IC_CHEVRON_DOWN, 14f, p.textSecondary);
            LinearLayout.LayoutParams scLp = new LinearLayout.LayoutParams(a.dp(14), a.dp(14));
            scLp.leftMargin = a.dp(4);
            seasonBtn.addView(seasonChev, scLp);

            seasonBtn.setOnClickListener(
                    v ->
                            showSeasonPickerDialog(
                                    a,
                                    site,
                                    video,
                                    curSeason,
                                    discoveredSeasons,
                                    discoveredLabels));
        }
        headerRow.addView(seasonBtn, new LinearLayout.LayoutParams(0, -2, 1f));

        // Episode Name Purifier Pill (Local Regex / AI when unlocked / Raw)
        final boolean aiUnlocked = renderAiUnlocked;
        final int storedCleanMode = renderStoredCleanMode;
        final int curCleanMode = effectiveEpisodeCleanMode(storedCleanMode, aiUnlocked);
        boolean cleanActive = curCleanMode != 1;
        String cleanLabel = episodeCleanPillLabel(storedCleanMode, aiUnlocked);
        LinearLayout cleanBtn = a.row();
        cleanBtn.setTag("episodes-cleaner");
        cleanBtn.setGravity(Gravity.CENTER_VERTICAL);
        cleanBtn.setPadding(a.dp(9), a.dp(5), a.dp(10), a.dp(5));
        cleanBtn.setBackground(MobileTheme.pillBg(a, cleanActive, 999));
        MobileIcons.IconView cleanIcon =
                MobileIcons.create(
                        a, MobileIcons.IC_SPARKLE, 12f, cleanActive ? p.accent : p.textSecondary);
        cleanIcon.setFilled(cleanActive);
        LinearLayout.LayoutParams ciLp = new LinearLayout.LayoutParams(a.dp(12), a.dp(12));
        ciLp.rightMargin = a.dp(4);
        cleanBtn.addView(cleanIcon, ciLp);
        TextView cleanTv = a.text(cleanLabel, 12, cleanActive ? p.accent : p.textSecondary);
        cleanTv.setTypeface(null, Typeface.BOLD);
        cleanBtn.addView(cleanTv);
        MobileMotion.bindPress(cleanBtn, 0.94f);
        cleanBtn.setOnClickListener(
                v -> {
                    boolean nowUnlocked = AiBetaGate.isUnlocked(a);
                    int nextMode =
                            nextEpisodeCleanMode(
                                    storedCleanMode,
                                    nowUnlocked,
                                    AiAssistantService.isConfigured(a));
                    a.mobilePrefs().edit().putInt(Prefs.EPISODE_CLEAN_MODE, nextMode).apply();
                    if (nextMode == 2 && nowUnlocked) {
                        a.toast("正在调用 AI 智能净化集名…");
                        final int cleanTicket = a.generation;
                        AiAssistantService.cleanEpisodesAsync(
                                a,
                                video.title,
                                line.episodes,
                                map -> {
                                    if (a.isFinishing()
                                            || a.isDestroyed()
                                            || cleanTicket != a.generation) {
                                        return;
                                    }
                                    activeAiEpisodeTitles.putAll(map);
                                    int liveLineIdx =
                                            resolveCurrentDetailLineIndex(a, video, safeLineIdx);
                                    int livePageIdx =
                                            resolveCurrentDetailPageIndex(
                                                    a, video, liveLineIdx, safePage);
                                    renderMobileEpisodes(
                                            a,
                                            site,
                                            video,
                                            liveLineIdx,
                                            livePageIdx,
                                            panel,
                                            remembered,
                                            discoveredSeasons,
                                            discoveredLabels);
                                });
                    }
                    renderMobileEpisodes(
                            a,
                            site,
                            video,
                            safeLineIdx,
                            safePage,
                            panel,
                            remembered,
                            discoveredSeasons,
                            discoveredLabels);
                });
        LinearLayout.LayoutParams cleanLp = new LinearLayout.LayoutParams(-2, -2);
        if (multiEpisode) cleanLp.rightMargin = a.dp(6);
        headerRow.addView(cleanBtn, cleanLp);

        // Sort Pill (`正序` / `倒序`) — hidden on single-episode movies
        LinearLayout sortBtn = a.row();
        sortBtn.setTag("episodes-order");
        sortBtn.setGravity(Gravity.CENTER_VERTICAL);
        sortBtn.setPadding(a.dp(9), a.dp(5), a.dp(10), a.dp(5));
        sortBtn.setBackground(MobileTheme.subtleBg(a, 999));
        MobileIcons.IconView sortIcon =
                MobileIcons.create(a, MobileIcons.IC_SORT, 12.5f, p.textSecondary);
        LinearLayout.LayoutParams soiLp = new LinearLayout.LayoutParams(a.dp(12.5f), a.dp(12.5f));
        soiLp.rightMargin = a.dp(4);
        sortBtn.addView(sortIcon, soiLp);
        TextView sortTv = a.text(descending ? "倒序" : "正序", 12, p.textPrimary);
        sortTv.setTypeface(null, Typeface.BOLD);
        sortBtn.addView(sortTv);
        MobileMotion.bindPress(sortBtn, 0.94f);
        sortBtn.setOnClickListener(
                v -> {
                    activeVideoDescending = !descending;
                    int nextPage = 0;
                    if (selectedEpisodeIndex >= 0
                            && selectedEpisodeIndex < total
                            && matchesSelectedEpisodeLine(safeLineIdx, line)) {
                        int visIdx =
                                activeVideoDescending
                                        ? (total - 1 - selectedEpisodeIndex)
                                        : selectedEpisodeIndex;
                        nextPage = visIdx / 50;
                    } else if (lineMatchesBookmark && !renderPlayAction.requiresReselection) {
                        int remIdx = HistoryResumeMatcher.findMatchedEpisodeIndex(line, remembered);
                        int visIdx = activeVideoDescending ? (total - 1 - remIdx) : remIdx;
                        nextPage = visIdx / 50;
                    }
                    renderMobileEpisodes(
                            a,
                            site,
                            video,
                            safeLineIdx,
                            nextPage,
                            panel,
                            remembered,
                            discoveredSeasons,
                            discoveredLabels);
                });
        sortBtn.setVisibility(multiEpisode ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams sortLp = new LinearLayout.LayoutParams(-2, -2);
        sortLp.rightMargin = a.dp(6);
        headerRow.addView(sortBtn, sortLp);

        // All Episodes Pill — hidden on single-episode movies
        LinearLayout allGridBtn = a.row();
        allGridBtn.setTag("episodes-all-grid");
        allGridBtn.setGravity(Gravity.CENTER_VERTICAL);
        allGridBtn.setPadding(a.dp(10), a.dp(5), a.dp(8), a.dp(5));
        allGridBtn.setBackground(MobileTheme.subtleBg(a, 999));
        TextView allTv = a.text("全部(" + total + ")", 12, p.textPrimary);
        allTv.setTypeface(null, Typeface.BOLD);
        allGridBtn.addView(allTv);
        MobileIcons.IconView allChev =
                MobileIcons.create(a, MobileIcons.IC_CHEVRON_RIGHT, 12f, p.textSecondary);
        LinearLayout.LayoutParams achLp = new LinearLayout.LayoutParams(a.dp(12), a.dp(12));
        achLp.leftMargin = a.dp(2);
        allGridBtn.addView(allChev, achLp);
        MobileMotion.bindPress(allGridBtn, 0.94f);
        allGridBtn.setOnClickListener(
                v ->
                        showAllEpisodesDialog(
                                a,
                                site,
                                video,
                                safeLineIdx,
                                line,
                                descending,
                                panel,
                                remembered,
                                discoveredSeasons,
                                discoveredLabels));
        allGridBtn.setVisibility(multiEpisode ? View.VISIBLE : View.GONE);
        headerRow.addView(allGridBtn);

        // 1b. Direct Multi-Season Selector Strip (visible whenever >= 2 seasons exist)
        LinearLayout seasonStripWrap = a.vertical();
        seasonStripWrap.setTag("detail-seasons");
        bodyHost.addView(seasonStripWrap, new LinearLayout.LayoutParams(-1, -2));
        if (discoveredSeasons.size() > 1) {
            renderSeasonStrip(
                    a,
                    site,
                    video,
                    curSeason,
                    seasonStripWrap,
                    discoveredSeasons,
                    discoveredLabels);
        }

        int start = safePage * 50;
        int end = Math.min(start + 50, total);
        final EpisodeSelectionState selectionState = new EpisodeSelectionState(line.name);
        SELECTION_STATES.put(bodyHost, selectionState);

        // 2. Quick Episode Number Tile Strip — pure episode locator (highlights & scrolls episode
        //    preview strip + updates main Play button; never launches playback directly!)
        if (multiEpisode) {
            a.gap(bodyHost, 12);
            HorizontalScrollView numScroll = new HorizontalScrollView(a);
            numScroll.setHorizontalScrollBarEnabled(false);
            selectionState.numScroll = numScroll;
            LinearLayout numRow = a.row();
            numScroll.addView(numRow);
            bodyHost.addView(numScroll, new LinearLayout.LayoutParams(-1, -2));

            for (int i = start; i < end; i++) {
                final int posIdx = descending ? (total - 1 - i) : i;
                final Cms.Episode ep = line.episodes.get(posIdx);
                boolean isCurrent = posIdx == activeEpIdx;

                TextView numPill =
                        a.text(
                                String.valueOf(posIdx + 1),
                                13f,
                                isCurrent ? p.accentOnFill : p.textPrimary);
                numPill.setTag("episode:" + line.name + ":" + posIdx);
                numPill.setTypeface(null, Typeface.BOLD);
                numPill.setGravity(Gravity.CENTER);
                numPill.setMinWidth(a.dp(36));
                numPill.setMinimumWidth(a.dp(36));
                numPill.setPadding(a.dp(10), a.dp(6), a.dp(10), a.dp(6));
                numPill.setBackground(
                        isCurrent ? MobileTheme.accentPillBg(a, 10) : MobileTheme.subtleBg(a, 10));
                MobileMotion.bindPress(numPill, 0.94f);
                numPill.setOnClickListener(
                        v -> {
                            awaitingExplicitReselection = false;
                            userSelectedDetailTarget = true;
                            selectedEpisodeLine = line.name == null ? "" : line.name;
                            selectedEpisodeLineId = line.lineId();
                            selectedEpisodeLineIndex = safeLineIdx;
                            selectedEpisodeIndex = posIdx;
                            activeDetailLineIndex = safeLineIdx;
                            activeDetailPage = safePage;
                            selectionState.applySelection(a, posIdx);
                            selectionState.scrollToEpisode(posIdx, true);
                            View playBtnView =
                                    a.root == null ? null : a.root.findViewWithTag("detail-play");
                            if (playBtnView instanceof Button) {
                                PrimaryPlayAction pickedAction =
                                        resolvePrimaryPlayAction(
                                                video,
                                                safeLineIdx,
                                                remembered,
                                                true,
                                                line,
                                                posIdx,
                                                renderAiUnlocked,
                                                renderStoredCleanMode);
                                bindPrimaryPlayButton(
                                        a, site, video, (Button) playBtnView, pickedAction);
                            }
                            bindTopDownloadButton(a, site, video, line, ep, posIdx, true);
                        });
                selectionState.numPills.put(posIdx, numPill);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(34));
                lp.rightMargin = a.dp(8);
                numRow.addView(numPill, lp);
            }
        }

        // 3. Horizontal 16:9 Landscape Episode Preview Cards
        a.gap(bodyHost, 14);
        HorizontalScrollView cardScroll = new HorizontalScrollView(a);
        cardScroll.setHorizontalScrollBarEnabled(false);
        selectionState.cardScroll = cardScroll;
        LinearLayout cardRow = a.row();
        cardRow.setGravity(Gravity.TOP);
        cardRow.setBaselineAligned(false);
        cardScroll.addView(cardRow);
        bodyHost.addView(cardScroll, new LinearLayout.LayoutParams(-1, -2));

        for (int i = start; i < end; i++) {
            final int posIdx = descending ? (total - 1 - i) : i;
            final Cms.Episode ep = line.episodes.get(posIdx);
            boolean isCurrent = posIdx == activeEpIdx;
            EpisodeDisplay disp =
                    parseEpisodeDisplay(
                            ep.name, posIdx + 1, renderAiUnlocked, renderStoredCleanMode);
            String eBadgeText = "E" + String.format(Locale.US, "%02d", posIdx + 1);

            LinearLayout cardWrap = a.vertical();
            cardWrap.setTag("ep-card:" + line.name + ":" + posIdx);
            MobileMotion.bindPress(cardWrap, 0.97f);
            cardWrap.setOnClickListener(
                    v -> {
                        awaitingExplicitReselection = false;
                        userSelectedDetailTarget = true;
                        selectedEpisodeLine = line.name == null ? "" : line.name;
                        selectedEpisodeLineId = line.lineId();
                        selectedEpisodeLineIndex = safeLineIdx;
                        selectedEpisodeIndex = posIdx;
                        activeDetailLineIndex = safeLineIdx;
                        activeDetailPage = safePage;
                        selectionState.applySelection(a, posIdx);
                        PrimaryPlayAction cardAction =
                                resolvePrimaryPlayAction(
                                        video,
                                        safeLineIdx,
                                        remembered,
                                        true,
                                        line,
                                        posIdx,
                                        renderAiUnlocked,
                                        renderStoredCleanMode);
                        View playBtnView =
                                a.root == null ? null : a.root.findViewWithTag("detail-play");
                        if (playBtnView instanceof Button) {
                            bindPrimaryPlayButton(a, site, video, (Button) playBtnView, cardAction);
                        }
                        bindTopDownloadButton(a, site, video, line, ep, posIdx, true);
                        a.resumeAt = cardAction.resumePositionMs;
                        handleDetailEpisodeTap(a, site, video, line, ep, posIdx + 1, false);
                    });
            cardWrap.setOnLongClickListener(
                    v -> {
                        List<Cms.Episode> one = Collections.singletonList(ep);
                        MobileDownloads.enqueue(a, site, video, line, one);
                        return true;
                    });

            FrameLayout frame = new FrameLayout(a);
            frame.setBackground(MobileTheme.subtleBg(a, 14));
            frame.setClipToOutline(true);

            EpisodeStillCropView stillImg = new EpisodeStillCropView(a, posIdx);
            frame.addView(stillImg, new FrameLayout.LayoutParams(-1, -1));
            View bdView = a.root != null ? a.root.findViewWithTag("detail-backdrop") : null;
            Bitmap currentBackdropBmp =
                    bdView instanceof PortraitBackdropView
                            ? ((PortraitBackdropView) bdView).getPosterBitmap()
                            : null;
            TmdbService.EpisodeStill tmdbEp = activeTmdbEpisodes.get(posIdx + 1);
            if (tmdbEp != null && tmdbEp.stillUrl != null && !tmdbEp.stillUrl.isEmpty()) {
                stillImg.setCustomStillBound(true);
                a.poster(tmdbEp.stillUrl, stillImg, false);
            } else if (currentBackdropBmp != null && !currentBackdropBmp.isRecycled()) {
                stillImg.setImageBitmap(currentBackdropBmp);
            } else if (video.poster != null && !video.poster.isEmpty()) {
                a.poster(video.poster, stillImg, false);
            }

            View cardScrim = new View(a);
            GradientDrawable scrimGd =
                    new GradientDrawable(
                            GradientDrawable.Orientation.TOP_BOTTOM,
                            new int[] {0x00000000, 0x990A0B0E});
            scrimGd.setCornerRadius(a.dp(14));
            cardScrim.setBackground(scrimGd);
            frame.addView(cardScrim, new FrameLayout.LayoutParams(-1, -1));

            if (disp.specBadge != null && !disp.specBadge.isEmpty()) {
                TextView specTv = a.text(disp.specBadge, 10, Color.WHITE);
                specTv.setTypeface(null, Typeface.BOLD);
                specTv.setPadding(a.dp(7), a.dp(2), a.dp(7), a.dp(2));
                specTv.setBackground(a.bg(0xB30A0B0E, 6));
                FrameLayout.LayoutParams specLp =
                        new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
                specLp.setMargins(a.dp(8), a.dp(8), a.dp(8), a.dp(8));
                frame.addView(specTv, specLp);
            }

            LinearLayout bottomBar = a.row();
            bottomBar.setGravity(Gravity.CENTER_VERTICAL);
            FrameLayout.LayoutParams bottomLp =
                    new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM);
            bottomLp.setMargins(a.dp(9), a.dp(8), a.dp(9), a.dp(8));
            frame.addView(bottomBar, bottomLp);

            LinearLayout ePill = a.row();
            ePill.setGravity(Gravity.CENTER_VERTICAL);
            ePill.setPadding(a.dp(7), a.dp(2.5f), a.dp(7), a.dp(2.5f));
            ePill.setBackground(isCurrent ? MobileTheme.accentPillBg(a, 6) : a.bg(0xB00A0B0E, 6));
            MobileIcons.IconView epPlayIc =
                    MobileIcons.create(
                            a, MobileIcons.IC_PLAY, 9.5f, isCurrent ? p.accentOnFill : Color.WHITE);
            LinearLayout.LayoutParams epiLp = new LinearLayout.LayoutParams(a.dp(9.5f), a.dp(9.5f));
            epiLp.rightMargin = a.dp(3);
            ePill.addView(epPlayIc, epiLp);
            TextView epTagTv = a.text(eBadgeText, 10.5f, isCurrent ? p.accentOnFill : Color.WHITE);
            epTagTv.setTypeface(null, Typeface.BOLD);
            ePill.addView(epTagTv);
            bottomBar.addView(ePill);

            TextView lineLabel = a.text(line.name, 10.5f, 0xD9FFFFFF);
            lineLabel.setTypeface(null, Typeface.BOLD);
            lineLabel.setGravity(Gravity.RIGHT);
            lineLabel.setSingleLine(true);
            lineLabel.setEllipsize(TextUtils.TruncateAt.END);
            bottomBar.addView(lineLabel, new LinearLayout.LayoutParams(0, -2, 1f));

            View activeRing = new View(a);
            GradientDrawable ringGd = new GradientDrawable();
            ringGd.setColor(Color.TRANSPARENT);
            ringGd.setCornerRadius(a.dp(14));
            ringGd.setStroke(a.dp(2f), p.accent);
            activeRing.setBackground(ringGd);
            activeRing.setVisibility(isCurrent ? View.VISIBLE : View.GONE);
            frame.addView(activeRing, new FrameLayout.LayoutParams(-1, -1));

            cardWrap.addView(frame, new LinearLayout.LayoutParams(a.dp(220), a.dp(124)));

            String yearPrefix =
                    (video.year != null && !video.year.trim().isEmpty())
                            ? video.year.trim() + " · "
                            : "";
            String subMeta =
                    yearPrefix
                            + (multiEpisode ? ("第" + (posIdx + 1) + "集") : "正片")
                            + (disp.specBadge != null ? " · " + disp.specBadge : "");
            TextView subMetaTv = a.text(subMeta, 11.5f, p.textSecondary);
            subMetaTv.setSingleLine(true);
            subMetaTv.setEllipsize(TextUtils.TruncateAt.END);
            subMetaTv.setPadding(a.dp(2), a.dp(7), a.dp(2), 0);
            cardWrap.addView(subMetaTv);

            String headline =
                    !multiEpisode
                            ? disp.cleanTitle
                            : (disp.cleanTitle.startsWith("第")
                                    ? disp.cleanTitle
                                    : "第 " + (posIdx + 1) + " 集 · " + disp.cleanTitle);
            TextView headlineTv = a.text(headline, 13.5f, isCurrent ? p.accent : p.textPrimary);
            headlineTv.setTypeface(null, Typeface.BOLD);
            headlineTv.setSingleLine(true);
            headlineTv.setEllipsize(TextUtils.TruncateAt.END);
            headlineTv.setPadding(a.dp(2), a.dp(2), a.dp(2), 0);
            cardWrap.addView(headlineTv);
            selectionState.cards.put(
                    posIdx,
                    new EpisodeCardHolder(
                            cardWrap, ePill, epPlayIc, epTagTv, activeRing, headlineTv));

            LinearLayout.LayoutParams cardLp = new LinearLayout.LayoutParams(a.dp(220), -2);
            cardLp.rightMargin = a.dp(12);
            cardRow.addView(cardWrap, cardLp);
        }

        // 4. Range Capsules (`1 · 50`, `51 · 100` ...) when > 50 episodes
        int groupCount = (total + 49) / 50;
        if (groupCount > 1) {
            a.gap(bodyHost, 14);
            HorizontalScrollView groupScroll = new HorizontalScrollView(a);
            groupScroll.setHorizontalScrollBarEnabled(false);
            LinearLayout groupRow = a.row();
            groupScroll.addView(groupRow);
            for (int g = 0; g < groupCount; g++) {
                final int targetGroup = g;
                boolean selectedGroup = g == safePage;
                int gStart = g * 50 + 1;
                int gEnd = Math.min(total, (g + 1) * 50);
                String label =
                        descending
                                ? (total - g * 50) + " · " + Math.max(1, total - gEnd + 1)
                                : gStart + " · " + gEnd;
                TextView tab = a.text(label, 12.5f, selectedGroup ? p.accentOnFill : p.textPrimary);
                tab.setTypeface(null, Typeface.BOLD);
                tab.setPadding(a.dp(15), a.dp(6), a.dp(15), a.dp(6));
                tab.setBackground(
                        selectedGroup
                                ? MobileTheme.accentPillBg(a, 999)
                                : MobileTheme.subtleBg(a, 999));
                MobileMotion.bindPress(tab, 0.94f);
                tab.setOnClickListener(
                        v ->
                                renderMobileEpisodes(
                                        a,
                                        site,
                                        video,
                                        safeLineIdx,
                                        targetGroup,
                                        panel,
                                        remembered,
                                        discoveredSeasons,
                                        discoveredLabels));
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
                lp.rightMargin = a.dp(8);
                groupRow.addView(tab, lp);
            }
            bodyHost.addView(groupScroll, new LinearLayout.LayoutParams(-1, -2));
        }

        if (activeEpIdx >= 0 && (activeEpIdx > 0 || lineMatchesBookmark)) {
            selectionState.scrollToEpisode(activeEpIdx, false);
        }

        restoreScrollAfterLayout(a, savedScrollY);
    }

    private static void showLinePickerSheet(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            int currentLineIndex,
            LinearLayout panel,
            WatchHistory.Entry remembered,
            Map<Integer, Cms.Video> discoveredSeasons,
            Map<Integer, String> discoveredLabels) {
        final MobileTheme.Palette p = MobileTheme.of(a);
        final MobileBottomSheet.SheetHandle[] handleRef = {null};

        LinearLayout list = a.vertical();
        list.setPadding(0, a.dp(2), 0, a.dp(4));
        int hairlinePx = MobileTheme.hairlinePx(a);

        for (int i = 0; i < video.lines.size(); i++) {
            final int idx = i;
            final Cms.Line cand = video.lines.get(i);
            boolean active = idx == currentLineIndex;

            LinearLayout optRow = a.row();
            optRow.setGravity(Gravity.CENTER_VERTICAL);
            optRow.setMinimumHeight(a.dp(50));
            optRow.setPadding(a.dp(14), a.dp(12), a.dp(14), a.dp(12));
            if (active) {
                optRow.setBackground(a.bg(p.pillSelectedFill, 12));
            } else {
                MobileSectionGroup.bindPressHighlight(optRow, p.bgPressed);
            }

            LinearLayout info = a.vertical();
            TextView lName = a.text(cand.name, 15f, active ? p.accent : p.textPrimary);
            lName.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
            lName.setSingleLine(true);
            lName.setEllipsize(TextUtils.TruncateAt.END);
            info.addView(lName);

            TextView lMeta =
                    a.text("共 " + cand.episodes.size() + " 集 · " + site.name, 12f, p.textSecondary);
            lMeta.setPadding(0, a.dp(2), 0, 0);
            info.addView(lMeta);
            optRow.addView(info, new LinearLayout.LayoutParams(0, -2, 1f));

            if (active) {
                MobileIcons.IconView check =
                        MobileIcons.create(a, MobileIcons.IC_CHECK, 18f, p.accent);
                check.setStrokeWidthUnits(2.3f);
                LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(a.dp(18), a.dp(18));
                clp.leftMargin = a.dp(12);
                optRow.addView(check, clp);
            }

            TextView manageLineBtn = a.text("管理", 12f, p.textSecondary);
            manageLineBtn.setTag("line-picker-manage:" + cand.lineId());
            manageLineBtn.setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5));
            manageLineBtn.setBackground(MobileTheme.subtleBg(a, 999));
            MobileMotion.bindPress(manageLineBtn, 0.92f);
            Runnable openLineManage =
                    () -> {
                        if (handleRef[0] != null) handleRef[0].dismiss();
                        openLineManagementSheet(
                                a,
                                site,
                                video,
                                cand,
                                currentLineIndex,
                                panel,
                                remembered,
                                discoveredSeasons,
                                discoveredLabels);
                    };
            manageLineBtn.setOnClickListener(v -> openLineManage.run());
            LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(-2, -2);
            mlp.leftMargin = a.dp(10);
            optRow.addView(manageLineBtn, mlp);

            optRow.setOnClickListener(
                    v -> {
                        if (handleRef[0] != null) handleRef[0].dismiss();
                        awaitingExplicitReselection = false;
                        userSelectedDetailTarget = true;
                        selectedEpisodeLine = cand.name == null ? "" : cand.name;
                        selectedEpisodeLineId = cand.lineId();
                        selectedEpisodeLineIndex = idx;
                        selectedEpisodeIndex = -1;
                        a.prefs.edit().putString(Prefs.PREFERRED_LINE, cand.rawName()).apply();
                        renderMobileEpisodes(
                                a,
                                site,
                                video,
                                idx,
                                0,
                                panel,
                                remembered,
                                discoveredSeasons,
                                discoveredLabels);
                    });
            optRow.setOnLongClickListener(
                    v -> {
                        openLineManage.run();
                        return true;
                    });
            list.addView(optRow, new LinearLayout.LayoutParams(-1, -2));

            boolean nextActive = (i + 1) == currentLineIndex;
            if (i + 1 < video.lines.size() && !active && !nextActive) {
                View divider = new View(a);
                divider.setBackgroundColor(p.hairline);
                LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(-1, hairlinePx);
                dlp.leftMargin = a.dp(14);
                dlp.rightMargin = a.dp(14);
                list.addView(divider, dlp);
            }
        }

        handleRef[0] =
                MobileBottomSheet.showHandle(
                        a,
                        "切换播放源",
                        "当前共 " + video.lines.size() + " 条可用线路",
                        "跨源搜索",
                        () -> {
                            if (handleRef[0] != null) handleRef[0].dismiss();
                            a.crossSearch(Cms.searchTitle(video));
                        },
                        list,
                        true);
    }

    private static void showSeasonPickerDialog(
            MainActivity a,
            Cms.Site site,
            Cms.Video currentVideo,
            SeasonMeta curSeason,
            Map<Integer, Cms.Video> discoveredSeasons,
            Map<Integer, String> discoveredLabels) {
        final List<Integer> seasonNums = new ArrayList<>(discoveredSeasons.keySet());
        String[] items = new String[seasonNums.size()];
        int checkedIdx = 0;
        for (int i = 0; i < seasonNums.size(); i++) {
            int sNum = seasonNums.get(i);
            Cms.Video vid = discoveredSeasons.get(sNum);
            String sLabel = discoveredLabels.get(sNum);
            String rem =
                    (vid != null && vid.remarks != null && !vid.remarks.trim().isEmpty())
                            ? " · " + vid.remarks.trim()
                            : "";
            items[i] = sLabel + "  (" + (vid != null ? vid.title : currentVideo.title) + rem + ")";
            if ((vid != null && Objects.equals(vid.id, currentVideo.id))
                    || sNum == curSeason.seasonNumber) {
                checkedIdx = i;
            }
        }
        String title = seasonNums.size() > 1 ? "选择季数（共 " + seasonNums.size() + " 季）" : "选择季数";
        UiWidgets.showDrawerPicker(
                a,
                title,
                "切换同系列关联季数",
                items,
                checkedIdx,
                which -> {
                    int sNum = seasonNums.get(which);
                    Cms.Video target = discoveredSeasons.get(sNum);
                    if (target != null && !Objects.equals(target.id, currentVideo.id)) {
                        show(a, site, target, null);
                    }
                });
    }

    private static void showAllEpisodesDialog(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            int lineIndex,
            Cms.Line line,
            boolean descending,
            LinearLayout panel,
            WatchHistory.Entry remembered,
            Map<Integer, Cms.Video> discoveredSeasons,
            Map<Integer, String> discoveredLabels) {
        MobileTheme.Palette p = MobileTheme.of(a);
        int total = line.episodes.size();
        LinearLayout grid = a.vertical();
        grid.setPadding(0, a.dp(4), 0, a.dp(8));

        final Dialog[] dlgRef = {null};

        final boolean gridAiUnlocked = !a.isTvDevice() && AiBetaGate.isUnlocked(a);
        final int gridStoredCleanMode =
                !a.isTvDevice() ? a.mobilePrefs().getInt(Prefs.EPISODE_CLEAN_MODE, 0) : 0;
        boolean hasLongTitles = false;
        for (int i = 0; i < Math.min(12, total); i++) {
            EpisodeDisplay sample =
                    parseEpisodeDisplay(
                            line.episodes.get(i).name, i + 1, gridAiUnlocked, gridStoredCleanMode);
            if (sample.cleanTitle != null && sample.cleanTitle.length() > 11) {
                hasLongTitles = true;
                break;
            }
        }
        int cols = hasLongTitles ? 1 : 3;
        final int precomputedGridMatchedIdx;
        if (selectedEpisodeIndex >= 0 && matchesSelectedEpisodeLine(lineIndex, line)) {
            precomputedGridMatchedIdx = selectedEpisodeIndex;
        } else if (!awaitingExplicitReselection
                && remembered != null
                && HistoryResumeMatcher.isSameBookmarkLine(line, remembered)) {
            int candIdx = HistoryResumeMatcher.findMatchedEpisodeIndex(line, remembered);
            precomputedGridMatchedIdx =
                    (candIdx >= 0
                                    && candIdx < total
                                    && HistoryResumeMatcher.matchesBookmarkSelection(
                                            line, line.episodes.get(candIdx), candIdx, remembered))
                            ? candIdx
                            : -1;
        } else {
            precomputedGridMatchedIdx = -1;
        }
        LinearLayout currentRow = null;
        for (int i = 0; i < total; i++) {
            if (i % cols == 0) {
                currentRow = a.row();
                grid.addView(currentRow, new LinearLayout.LayoutParams(-1, -2));
            }
            final int visualIdx = i;
            final int posIdx = descending ? (total - 1 - i) : i;
            final Cms.Episode ep = line.episodes.get(posIdx);
            boolean isCurrent = (posIdx == precomputedGridMatchedIdx);
            EpisodeDisplay disp =
                    parseEpisodeDisplay(ep.name, posIdx + 1, gridAiUnlocked, gridStoredCleanMode);
            TextView cell = a.text(disp.cleanTitle, 13, isCurrent ? p.accentOnFill : p.textPrimary);
            cell.setTypeface(null, isCurrent ? Typeface.BOLD : Typeface.NORMAL);
            cell.setGravity(cols == 1 ? Gravity.CENTER_VERTICAL : Gravity.CENTER);
            cell.setSingleLine(true);
            cell.setEllipsize(TextUtils.TruncateAt.END);
            cell.setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10));
            cell.setBackground(
                    isCurrent ? MobileTheme.accentPillBg(a, 10) : MobileTheme.subtleBg(a, 10));
            MobileMotion.bindPress(cell, 0.94f);
            cell.setOnClickListener(
                    v -> {
                        if (dlgRef[0] != null) dlgRef[0].dismiss();
                        awaitingExplicitReselection = false;
                        userSelectedDetailTarget = true;
                        selectedEpisodeLine = line.name == null ? "" : line.name;
                        selectedEpisodeLineId = line.lineId();
                        selectedEpisodeLineIndex = lineIndex;
                        selectedEpisodeIndex = posIdx;
                        int targetPage = visualIdx / 50;
                        renderMobileEpisodes(
                                a,
                                site,
                                video,
                                lineIndex,
                                targetPage,
                                panel,
                                remembered,
                                discoveredSeasons,
                                discoveredLabels);
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
            lp.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
            currentRow.addView(cell, lp);
        }
        if (currentRow != null && total % cols != 0) {
            for (int pad = total % cols; pad < cols; pad++) {
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, 1, 1f);
                lp.setMargins(a.dp(4), a.dp(4), a.dp(4), a.dp(4));
                currentRow.addView(new View(a), lp);
            }
        }
        dlgRef[0] =
                MobileBottomSheet.show(
                        a,
                        "全部剧集 · " + line.name,
                        "共 " + total + " 集 · 点击定位至对应剧集卡片",
                        null,
                        null,
                        grid,
                        true);
    }

    private static void renderSeasonStrip(
            MainActivity a,
            Cms.Site site,
            Cms.Video currentVideo,
            SeasonMeta curMeta,
            LinearLayout seasonStripWrap,
            Map<Integer, Cms.Video> bySeason,
            Map<Integer, String> labels) {
        MobileTheme.Palette p = MobileTheme.of(a);
        seasonStripWrap.removeAllViews();
        a.gap(seasonStripWrap, 11);
        HorizontalScrollView hsv = new HorizontalScrollView(a);
        hsv.setHorizontalScrollBarEnabled(false);
        LinearLayout row = a.row();
        hsv.addView(row);
        seasonStripWrap.addView(hsv, new LinearLayout.LayoutParams(-1, -2));

        for (final Integer sNum : bySeason.keySet()) {
            final Cms.Video targetVid = bySeason.get(sNum);
            String sLabel = labels.get(sNum);
            boolean active =
                    (targetVid != null && Objects.equals(targetVid.id, currentVideo.id))
                            || sNum == curMeta.seasonNumber;
            TextView pill = a.text(sLabel, 12.5f, active ? p.accentOnFill : p.textPrimary);
            pill.setTag("detail-season:" + sNum);
            pill.setTypeface(null, Typeface.BOLD);
            pill.setPadding(a.dp(14), a.dp(5), a.dp(14), a.dp(5));
            pill.setBackground(
                    active ? MobileTheme.accentPillBg(a, 999) : MobileTheme.subtleBg(a, 999));
            MobileMotion.bindPress(pill, 0.94f);
            pill.setOnClickListener(
                    v -> {
                        if (targetVid != null && !Objects.equals(targetVid.id, currentVideo.id)) {
                            show(a, site, targetVid, null);
                        }
                    });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, a.dp(32));
            lp.rightMargin = a.dp(8);
            row.addView(pill, lp);
        }
    }

    static final class SeasonMeta {
        final String baseTitle;
        final int seasonNumber;
        final String seasonLabel;
        final boolean explicit;

        SeasonMeta(String baseTitle, int seasonNumber, String seasonLabel, boolean explicit) {
            this.baseTitle = baseTitle;
            this.seasonNumber = seasonNumber;
            this.seasonLabel = seasonLabel;
            this.explicit = explicit;
        }
    }

    static int parseChineseNumber(String raw) {
        if (raw == null) return 1;
        String s = raw.trim();
        if (s.isEmpty()) return 1;
        try {
            int d = Integer.parseInt(s);
            if (d > 0) return d;
        } catch (NumberFormatException ignored) {
        }
        String digits = "零一二三四五六七八九";
        if ("十".equals(s) || "拾".equals(s)) return 10;
        if (s.contains("十") || s.contains("拾")) {
            String[] parts = s.split("[十拾]", -1);
            int tens = parts[0].isEmpty() ? 1 : Math.max(1, digits.indexOf(parts[0].charAt(0)));
            int ones =
                    (parts.length > 1 && !parts[1].isEmpty())
                            ? Math.max(0, digits.indexOf(parts[1].charAt(0)))
                            : 0;
            int val = tens * 10 + ones;
            return val > 0 ? val : 1;
        }
        int acc = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            int idx = digits.indexOf(c);
            if (c == '两') idx = 2;
            if (idx >= 0) acc = acc * 10 + idx;
        }
        return acc > 0 ? acc : 1;
    }

    static SeasonMeta parseSeasonMeta(String rawTitle) {
        String t = rawTitle == null ? "" : rawTitle.trim();
        t =
                t.replaceAll(
                                "(?i)\\s*[\\[【(（](?:4K|2160P|1080P|720P|HD|BD|国语|粤语|中字|双语|完结|全集)[^\\]】)）]*[\\]】)）]\\s*$",
                                "")
                        .trim();
        if (t.isEmpty() && rawTitle != null) t = rawTitle.trim();

        Matcher m1 =
                Pattern.compile(
                                "^(.+?)\\s*(?:[（(\\[【·:：\\-—]\\s*)?第\\s*([一二三四五六七八九十百零两\\d]+)\\s*([季部辑篇])(?:\\s*[)）\\]】])?\\s*$")
                        .matcher(t);
        if (m1.matches()) {
            String base = m1.group(1).trim();
            int num = parseChineseNumber(m1.group(2));
            String unit = m1.group(3);
            if (!base.isEmpty()) {
                return new SeasonMeta(base, num, "第 " + num + " " + unit, true);
            }
        }

        Matcher m2 =
                Pattern.compile(
                                "(?i)^(.+?)\\s*(?:[（(\\[【·:：\\-—]\\s*)?(?:Season\\s*0*(\\d{1,2})|S0*(\\d{1,2}))(?:\\s*[)）\\]】])?\\s*$")
                        .matcher(t);
        if (m2.matches()) {
            String base = m2.group(1).trim();
            String numStr = m2.group(2) != null ? m2.group(2) : m2.group(3);
            int num = parseChineseNumber(numStr);
            if (!base.isEmpty()) {
                return new SeasonMeta(base, num, "第 " + num + " 季", true);
            }
        }

        Matcher m3 =
                Pattern.compile(
                                "^([\\u4e00-\\u9fa5A-Za-z][\\u4e00-\\u9fa5A-Za-z0-9·\\s]{1,20}?)\\s*(?:[（(\\[【·\\-]\\s*)?(20[123]\\d)\\s*[季期年]?(?:\\s*[)）\\]】])?\\s*$")
                        .matcher(t);
        if (m3.matches()) {
            String base = m3.group(1).trim();
            int yr = parseChineseNumber(m3.group(2));
            if (!base.isEmpty()) {
                return new SeasonMeta(base, yr, yr + " 季", true);
            }
        }

        Matcher m4 = Pattern.compile("^([\\u4e00-\\u9fa5]{2,16})\\s*([1-9])\\s*$").matcher(t);
        if (m4.matches()) {
            String base = m4.group(1).trim();
            int num = parseChineseNumber(m4.group(2));
            if (!base.isEmpty()) {
                return new SeasonMeta(base, num, "第 " + num + " 季", true);
            }
        }

        return new SeasonMeta(t, 1, "第 1 季", false);
    }

    static void updateRatingBadges(
            TextView doubanBadge, TextView rtBadge, Cms.Video v, double resolvedDouban) {
        updateRatingBadges(doubanBadge, rtBadge, v, resolvedDouban, -1);
    }

    static void updateRatingBadges(
            TextView doubanBadge,
            TextView rtBadge,
            Cms.Video v,
            double resolvedDouban,
            int resolvedRtPercent) {
        ImmersivePoster.Ratings local = ImmersivePoster.extractImmediateRatings(v);
        double dbScore = resolvedDouban >= 2.0 ? resolvedDouban : local.douban;
        int rtPct = resolvedRtPercent > 0 ? resolvedRtPercent : local.rtPercent;
        if (dbScore >= 2.0 && dbScore <= 9.9) {
            doubanBadge.setText(String.format(Locale.US, "豆瓣 %.1f", dbScore));
            doubanBadge.setVisibility(View.VISIBLE);
        } else {
            doubanBadge.setText("");
            doubanBadge.setVisibility(View.GONE);
        }
        if (rtPct >= 1 && rtPct <= 100) {
            rtBadge.setText("烂番茄 " + rtPct + "%");
            rtBadge.setVisibility(View.VISIBLE);
        } else {
            rtBadge.setText("");
            rtBadge.setVisibility(View.GONE);
        }
    }

    static void legacyUnusedUpdateRatingBadges(
            TextView doubanBadge, TextView rtBadge, Cms.Video v, double resolvedDouban) {
        double dbScore = resolvedDouban;
        if (dbScore < 2.0 && v != null) {
            String blob =
                    (v.remarks == null ? "" : v.remarks)
                            + " "
                            + (v.description == null ? "" : v.description);
            Matcher m =
                    Pattern.compile("(?:豆瓣|评分|TMDB|IMDb)?\\s*[:：]?\\s*([4-9]\\.[0-9])\\s*分?")
                            .matcher(blob);
            if (m.find()) {
                try {
                    dbScore = Double.parseDouble(m.group(1));
                } catch (Exception ignored) {
                }
            }
        }
        int titleHash = Math.abs((v == null || v.title == null ? "movie" : v.title).hashCode());
        if (dbScore < 2.0) {
            dbScore = 7.4 + ((titleHash % 16) * 0.1);
        }
        int rtPercent =
                Math.max(
                        68,
                        Math.min(98, (int) Math.round(dbScore * 10.4 + ((titleHash / 7) % 5) - 2)));
        doubanBadge.setText(String.format(Locale.US, "豆瓣 %.1f", dbScore));
        rtBadge.setText("烂番茄 " + rtPercent + "%");
    }

    private static String normalizeBaseKey(String s) {
        if (s == null) return "";
        return s.toLowerCase().replaceAll("[\\s·:：\\-—_（）()【】\\[\\]《》〈〉\"“”'’!！?？,，.。]", "").trim();
    }

    static void populateRelatedSeasons(
            final MainActivity a,
            final Cms.Site site,
            final Cms.Video currentVideo,
            final LinearLayout episodePanel,
            final int currentLineIdx,
            final int currentPageIdx,
            final WatchHistory.Entry remembered,
            final Map<Integer, Cms.Video> bySeason,
            final Map<Integer, String> labels) {
        final SeasonMeta curMeta = parseSeasonMeta(currentVideo.title);
        if (!curMeta.explicit) return;
        final String baseKey = normalizeBaseKey(curMeta.baseTitle);
        if (baseKey.isEmpty()) return;
        final int ticket = a.generation;
        a.submitPage(
                () -> {
                    try {
                        List<Cms.Video> found =
                                Cms.listing(
                                                SourceController.engine(a, site)
                                                        .search(curMeta.baseTitle, 1))
                                        .videos;
                        if (found == null || found.isEmpty()) return;
                        boolean added = false;
                        for (Cms.Video cand : found) {
                            if (cand == null || cand.title == null) continue;
                            SeasonMeta candMeta = parseSeasonMeta(cand.title);
                            if (!baseKey.equals(normalizeBaseKey(candMeta.baseTitle))) continue;
                            if (!curMeta.explicit
                                    && !candMeta.explicit
                                    && !Objects.equals(cand.id, currentVideo.id)) {
                                continue;
                            }
                            if (!bySeason.containsKey(candMeta.seasonNumber)) {
                                bySeason.put(candMeta.seasonNumber, cand);
                                labels.put(candMeta.seasonNumber, candMeta.seasonLabel);
                                added = true;
                            }
                        }
                        if (!added || bySeason.size() < 2) return;
                        a.ui.post(
                                () -> {
                                    if (a.isFinishing()
                                            || a.isDestroyed()
                                            || ticket != a.generation) return;
                                    int liveLineIdx =
                                            resolveCurrentDetailLineIndex(
                                                    a, currentVideo, currentLineIdx);
                                    int livePageIdx =
                                            resolveCurrentDetailPageIndex(
                                                    a, currentVideo, liveLineIdx, currentPageIdx);
                                    renderMobileEpisodes(
                                            a,
                                            site,
                                            currentVideo,
                                            liveLineIdx,
                                            livePageIdx,
                                            episodePanel,
                                            remembered,
                                            bySeason,
                                            labels);
                                });
                    } catch (Exception ignored) {
                    }
                });
    }
}

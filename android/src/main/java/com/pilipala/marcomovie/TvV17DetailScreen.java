package com.pilipala.marcomovie;

import android.graphics.Outline;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.List;

/**
 * Apple TV+ inspired immersive TV detail screen.
 *
 * <p>Spacious, left-aligned cinema hierarchy over a full-bleed backdrop:
 * - Upper ~51% viewport reserved as an unobstructed artwork breathing window
 * - Row 1: Giant bold title + circular Heart favorite button (hollow ♡ / Apple Red ♥)
 * - Row 2: Official year · country/region · total episodes / duration
 * - Row 3: Authentic Douban & Rotten Tomatoes badges
 * - Row 4: Dedicated single action row — Play button + Line/Episodes popup button
 * - Row 5: Small-type single-episode filename from the active line (+ resume caption)
 * - Below: Spacious plot synopsis + display-only circular-avatar cast strip (non-focusable)
 */
final class TvV17DetailScreen {
    interface Actions {
        void back();

        void play();

        void episodes();

        void favorite();

        void synopsis();
    }

    private static final int[] AVATAR_ACCENTS = {
        0xff2b4c6f, 0xff4b3a69, 0xff28544b, 0xff6b4431, 0xff3b4c63, 0xff5a374b
    };

    final FrameLayout view;
    final ImmersivePoster cover;
    final LinearLayout seasonHost;
    final Button play;
    final Button episodesBtn;
    final Button favorite;
    final TextView episodeFileView;
    final TextView historyView;
    final TextView statusView;
    final TvScrollView scroll;
    final LinearLayout content;
    private final MainActivity host;
    private final Cms.Site site;
    private final TextView factsView;
    private final TextView doubanBadge;
    private final TextView rtBadge;
    private final LinearLayout ratingRow;
    private final MediaBadgeView.BadgeFlowLayout specBadgeRow;
    private final TextView synopsisView;
    private final Button synopsisMoreBtn;
    private final LinearLayout castSection;
    private final LinearLayout castRow;
    private final Cms.Video video;
    private double resolvedDouban = 0.0;
    private int resolvedRt = -1;

    TvV17DetailScreen(
            MainActivity a,
            Cms.Site site,
            Cms.Video video,
            String verifiedBackdrop,
            boolean isFavorite,
            boolean playEnabled,
            String playLabel,
            String episodesButtonLabel,
            String episodeFileCaption,
            String historyCaption,
            Actions actions) {
        if (a == null || site == null || video == null || actions == null)
            throw new IllegalArgumentException();
        this.host = a;
        this.site = site;
        this.video = video;

        int initialAmbient = MobileDetailScreen.defaultAmbientForTitle(video.title);
        view = new FrameLayout(a);
        view.setTag("tv-v17-detail");
        view.setBackgroundColor(initialAmbient);

        // Full-bleed cinema backdrop with Apple TV+ left-aligned directional vignette
        cover = new ImmersivePoster(a, "detail-cover");
        cover.immersiveMode = true;
        cover.backdrop.setTag("detail-backdrop");
        cover.backdrop.leftAlignedHero = true;
        cover.backdrop.ambientColor = initialAmbient;
        cover.onAmbientChanged = color -> view.setBackgroundColor(color);
        view.addView(cover.backdrop, new FrameLayout.LayoutParams(-1, -1));
        view.addView(
                cover,
                new FrameLayout.LayoutParams(a.dp(260), a.dp(390), Gravity.TOP | Gravity.START));

        scroll = new TvScrollView(a);
        scroll.setTag("detail-scroll");
        scroll.readingMode = true;
        scroll.setFillViewport(true);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.getViewTreeObserver()
                .addOnScrollChangedListener(
                        () -> cover.backdrop.setScrollOffset(scroll.getScrollY()));
        view.addView(scroll, new FrameLayout.LayoutParams(-1, -1));

        content = a.vertical();
        content.setPadding(a.dp(58), a.dp(28), a.dp(58), a.dp(64));
        content.setClipChildren(false);
        content.setClipToPadding(false);
        scroll.addView(content, new ScrollView.LayoutParams(-1, -2));

        // Top-left floating frosted back button
        Button back = DetailScreen.glassNavButton(a, "‹ 返回", "detail-back", false, actions::back);
        back.setId(View.generateViewId());
        content.addView(back, new LinearLayout.LayoutParams(-2, a.dp(38)));

        // Generous upper breathing window so the title's top edge sits at left middle-lower (~51%)
        float density = Math.max(1f, a.getResources().getDisplayMetrics().density);
        float screenHeightDp = a.windowHeight() / density;
        float screenWidthDp = a.windowWidth() / density;
        int targetTitleTopDp = Math.round(screenHeightDp * 0.51f);
        int breathingDp = Math.max(148, Math.min(340, targetTitleTopDp - 66));
        View breathingRoom = new View(a);
        content.addView(breathingRoom, new LinearLayout.LayoutParams(1, a.dp(breathingDp)));

        int heroWidthPx = a.dp(Math.max(460, Math.min(720, Math.round(screenWidthDp * 0.64f))));
        LinearLayout heroColumn = a.vertical();
        heroColumn.setTag("detail-hero");
        heroColumn.setClipChildren(false);
        heroColumn.setClipToPadding(false);
        content.addView(heroColumn, new LinearLayout.LayoutParams(heroWidthPx, -2));

        // 1. Largest Bold Title + Heart Favorite Icon Button right beside it
        LinearLayout titleRow = a.row();
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleRow.setClipChildren(false);
        titleRow.setClipToPadding(false);

        TextView title = a.text(video.title == null ? "" : video.title, 38, 0xfff5f5f7);
        title.setTag("detail-title");
        title.setTypeface(null, Typeface.BOLD);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setMaxWidth(heroWidthPx - a.dp(54));
        title.setLineSpacing(a.dp(2), 1.05f);
        title.setShadowLayer(a.dp(14), 0, a.dp(3), 0xb8000000);
        titleRow.addView(title, new LinearLayout.LayoutParams(-2, -2));

        favorite = a.button("", "detail-favorite", actions::favorite);
        favorite.setId(View.generateViewId());
        favorite.setMinWidth(0);
        favorite.setMinimumWidth(0);
        favorite.setMinHeight(0);
        favorite.setMinimumHeight(0);
        favorite.setPadding(0, 0, 0, 0);
        favorite.setGravity(Gravity.CENTER);
        favorite.setIncludeFontPadding(false);
        favorite.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16.5f);
        favorite.setOnFocusChangeListener(
                (v, focused) -> styleHeartFavorite(focused, favorite.isSelected()));
        setFavorite(isFavorite);
        LinearLayout.LayoutParams favLp = new LinearLayout.LayoutParams(a.dp(34), a.dp(34));
        favLp.leftMargin = a.dp(12);
        titleRow.addView(favorite, favLp);
        heroColumn.addView(titleRow, new LinearLayout.LayoutParams(-1, -2));

        // 2. Official Metadata Line: Year · Region · Total Episodes / Duration
        factsView = a.text(ImmersivePoster.formatOfficialFactLine(video, null), 14.5f, 0xe2ebebf5);
        factsView.setTag("detail-facts");
        factsView.setMaxLines(2);
        factsView.setEllipsize(TextUtils.TruncateAt.END);
        factsView.setShadowLayer(a.dp(6), 0, a.dp(1), 0x80000000);
        factsView.setVisibility(factsView.getText().length() > 0 ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams factsLp = new LinearLayout.LayoutParams(-1, -2);
        factsLp.topMargin = a.dp(14);
        heroColumn.addView(factsView, factsLp);

        // 3. Authentic Rating Badges: Douban Score · Rotten Tomatoes · Source
        ratingRow = a.row();
        ratingRow.setTag("detail-rating-row");
        ratingRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams ratingLp = new LinearLayout.LayoutParams(-2, -2);
        ratingLp.topMargin = a.dp(12);
        heroColumn.addView(ratingRow, ratingLp);

        doubanBadge = a.text("", 12.5f, 0xff6ee7b7);
        doubanBadge.setTag("detail-douban-rating");
        doubanBadge.setSingleLine(true);
        doubanBadge.setTypeface(null, Typeface.BOLD);
        doubanBadge.setPadding(a.dp(12), a.dp(4.5f), a.dp(12), a.dp(4.5f));
        doubanBadge.setBackground(MobileDetailScreen.glassBg(a, 0x3800b51d, 0x6634d399, 999));
        LinearLayout.LayoutParams dbLp = new LinearLayout.LayoutParams(-2, -2);
        dbLp.rightMargin = a.dp(10);
        ratingRow.addView(doubanBadge, dbLp);

        rtBadge = a.text("", 12.5f, 0xffffb4a2);
        rtBadge.setTag("detail-rt-rating");
        rtBadge.setSingleLine(true);
        rtBadge.setTypeface(null, Typeface.BOLD);
        rtBadge.setPadding(a.dp(12), a.dp(4.5f), a.dp(12), a.dp(4.5f));
        rtBadge.setBackground(MobileDetailScreen.glassBg(a, 0x38fa320a, 0x66ff6b4a, 999));
        LinearLayout.LayoutParams rtLp = new LinearLayout.LayoutParams(-2, -2);
        rtLp.rightMargin = a.dp(10);
        ratingRow.addView(rtBadge, rtLp);

        if (site.name != null && !site.name.trim().isEmpty()) {
            TextView siteLabel = a.text(site.name.trim(), 12, 0xd8ffffff);
            siteLabel.setSingleLine(true);
            siteLabel.setPadding(a.dp(12), a.dp(4.5f), a.dp(12), a.dp(4.5f));
            siteLabel.setBackground(MobileDetailScreen.glassBg(a, 0x24ffffff, 0x36ffffff, 999));
            ratingRow.addView(siteLabel);
        }
        applyRatings(0.0, -1);

        // 3b. Plain-text Media Spec Badges (bypassing URLDecoder so '+' in HDR10+/DD+ stays intact)
        specBadgeRow = MediaBadgeView.createRow(a, "detail-spec-badges", false);
        LinearLayout.LayoutParams specLp = new LinearLayout.LayoutParams(-1, -2);
        specLp.topMargin = a.dp(10);
        heroColumn.addView(specBadgeRow, specLp);
        refreshSpecBadges();

        // 4. Dedicated Action Row directly below ratings: Play + Episodes/Lines Popup Button
        LinearLayout buttons = a.row();
        buttons.setGravity(Gravity.CENTER_VERTICAL);
        buttons.setClipChildren(false);
        buttons.setClipToPadding(false);
        LinearLayout.LayoutParams buttonsLp = new LinearLayout.LayoutParams(-1, -2);
        buttonsLp.topMargin = a.dp(22);
        heroColumn.addView(buttons, buttonsLp);

        play = DetailScreen.heroPlayButton(a, playLabel, "detail-play", actions::play);
        play.setId(View.generateViewId());
        play.setEnabled(playEnabled);
        play.setSingleLine(true);
        play.setEllipsize(TextUtils.TruncateAt.END);
        play.setMinWidth(a.dp(172));
        play.setMinimumWidth(a.dp(172));
        play.setMaxWidth(a.dp(230));
        play.setPadding(a.dp(26), 0, a.dp(26), 0);
        buttons.addView(play, new LinearLayout.LayoutParams(-2, a.dp(48)));

        episodesBtn =
                DetailScreen.glassNavButton(
                        a,
                        episodesButtonLabel,
                        "detail-episodes-trigger",
                        false,
                        actions::episodes);
        episodesBtn.setId(View.generateViewId());
        episodesBtn.setEnabled(playEnabled);
        episodesBtn.setVisibility(playEnabled ? View.VISIBLE : View.GONE);
        episodesBtn.setSingleLine(true);
        episodesBtn.setEllipsize(TextUtils.TruncateAt.END);
        episodesBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f);
        episodesBtn.setPadding(a.dp(22), a.dp(10), a.dp(22), a.dp(10));
        LinearLayout.LayoutParams epBtnLp = new LinearLayout.LayoutParams(-2, a.dp(48));
        epBtnLp.leftMargin = a.dp(14);
        buttons.addView(episodesBtn, epBtnLp);

        // Ensure D-pad UP from Play / Episodes always lands directly on the Heart Favorite button
        play.setNextFocusUpId(favorite.getId());
        episodesBtn.setNextFocusUpId(favorite.getId());
        favorite.setNextFocusUpId(back.getId());
        back.setNextFocusDownId(favorite.getId());
        if (playEnabled) {
            favorite.setNextFocusDownId(play.getId());
        }

        // 5. Small single-episode filename from active line directly below Play button
        episodeFileView =
                a.text(episodeFileCaption == null ? "" : episodeFileCaption, 12.5f, 0xb0ebebf5);
        episodeFileView.setTag("detail-episode-file");
        episodeFileView.setMaxLines(2);
        episodeFileView.setEllipsize(TextUtils.TruncateAt.END);
        episodeFileView.setLineSpacing(a.dp(2), 1.12f);
        episodeFileView.setShadowLayer(a.dp(6), 0, a.dp(1), 0x80000000);
        episodeFileView.setVisibility(
                episodeFileView.getText().length() > 0 ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams fileLp = new LinearLayout.LayoutParams(-1, -2);
        fileLp.topMargin = a.dp(12);
        heroColumn.addView(episodeFileView, fileLp);

        historyView = a.text(historyCaption == null ? "" : historyCaption, 12, 0x98d4dae8);
        historyView.setTag("detail-history");
        historyView.setVisibility(historyView.getText().length() > 0 ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams historyLp = new LinearLayout.LayoutParams(-1, -2);
        historyLp.topMargin = a.dp(5);
        heroColumn.addView(historyView, historyLp);

        statusView = a.text("", 13, MainActivity.MUTED);
        statusView.setTag("detail-loading");
        statusView.setVisibility(View.GONE);
        LinearLayout.LayoutParams statusLp = new LinearLayout.LayoutParams(-1, -2);
        statusLp.topMargin = a.dp(8);
        heroColumn.addView(statusView, statusLp);

        // 6. Plot Synopsis (airy spacing below primary hero actions)
        String initialSynopsis = video.description == null ? "" : video.description.trim();
        synopsisView = a.text(initialSynopsis, 14, 0xd0e6ebf4);
        synopsisView.setTag("detail-synopsis");
        synopsisView.setMaxLines(4);
        synopsisView.setEllipsize(TextUtils.TruncateAt.END);
        synopsisView.setLineSpacing(a.dp(3), 1.18f);
        synopsisView.setShadowLayer(a.dp(6), 0, a.dp(1), 0x80000000);
        synopsisView.setVisibility(initialSynopsis.isEmpty() ? View.GONE : View.VISIBLE);
        LinearLayout.LayoutParams synopsisLp = new LinearLayout.LayoutParams(-1, -2);
        synopsisLp.topMargin = a.dp(24);
        heroColumn.addView(synopsisView, synopsisLp);

        synopsisMoreBtn =
                DetailScreen.glassNavButton(a, "查看完整简介 ›", "synopsis", false, actions::synopsis);
        synopsisMoreBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f);
        synopsisMoreBtn.setMinHeight(a.dp(32));
        synopsisMoreBtn.setMinimumHeight(a.dp(32));
        synopsisMoreBtn.setPadding(a.dp(14), a.dp(5), a.dp(14), a.dp(5));
        synopsisMoreBtn.setVisibility(initialSynopsis.length() > 60 ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams moreLp = new LinearLayout.LayoutParams(-2, a.dp(32));
        moreLp.topMargin = a.dp(10);
        heroColumn.addView(synopsisMoreBtn, moreLp);

        // 7. Related Seasons Shelf (if multi-season)
        seasonHost = a.vertical();
        seasonHost.setTag("detail-seasons");
        seasonHost.setClipChildren(false);
        seasonHost.setClipToPadding(false);
        LinearLayout.LayoutParams seasonLp = new LinearLayout.LayoutParams(-1, -2);
        seasonLp.topMargin = a.dp(26);
        content.addView(seasonHost, seasonLp);

        // 8. Display-Only Cast Strip with Circular Portrait Avatars (non-focusable)
        castSection = a.vertical();
        castSection.setTag("detail-cast-section");
        castSection.setFocusable(false);
        castSection.setFocusableInTouchMode(false);
        castSection.setClickable(false);
        castSection.setClipChildren(false);
        castSection.setClipToPadding(false);
        LinearLayout.LayoutParams castSecLp = new LinearLayout.LayoutParams(-1, -2);
        castSecLp.topMargin = a.dp(30);
        content.addView(castSection, castSecLp);

        TextView castLabel = a.text("演职员", 13.5f, 0xb0ebebf5);
        castLabel.setTypeface(null, Typeface.BOLD);
        castSection.addView(castLabel, new LinearLayout.LayoutParams(-2, -2));

        HorizontalScrollView castScroll = new HorizontalScrollView(a);
        castScroll.setTag("detail-cast-strip");
        castScroll.setHorizontalScrollBarEnabled(false);
        castScroll.setFocusable(false);
        castScroll.setFocusableInTouchMode(false);
        castScroll.setClickable(false);
        castScroll.setClipChildren(false);
        castScroll.setClipToPadding(false);
        castScroll.setPadding(0, a.dp(14), 0, a.dp(8));
        castRow = a.row();
        castRow.setFocusable(false);
        castRow.setFocusableInTouchMode(false);
        castRow.setClipChildren(false);
        castRow.setClipToPadding(false);
        castScroll.addView(castRow, new FrameLayout.LayoutParams(-2, -2));
        castSection.addView(castScroll, new LinearLayout.LayoutParams(-1, -2));

        populateCast(ImmersivePoster.parseCastNamesFallback(video.director, video.actor));

        // Kick off verified artwork, ratings, and official Douban metadata/cast enrichment
        boolean likelyTv = hasMultipleEpisodes(video);
        String artwork =
                verifiedBackdrop != null && !verifiedBackdrop.trim().isEmpty()
                        ? verifiedBackdrop.trim()
                        : video.poster;
        cover.load(artwork, video.title, video.year, video.actor, video.director, true, likelyTv);

        ImmersivePoster.resolveMediaRatings(
                a,
                video,
                ratings -> {
                    if (ratings != null) {
                        applyRatings(ratings.douban, ratings.rtPercent);
                    }
                });

        ImmersivePoster.resolveSubjectDetails(
                a,
                video,
                details -> {
                    if (details == null) return;
                    String updatedFacts = ImmersivePoster.formatOfficialFactLine(video, details);
                    if (!updatedFacts.isEmpty()) {
                        factsView.setText(updatedFacts);
                        factsView.setVisibility(View.VISIBLE);
                    }
                    if (details.doubanScore >= 2.0 || details.rtPercent > 0) {
                        applyRatings(details.doubanScore, details.rtPercent);
                    }
                    if (!details.intro.isEmpty()
                            && (video.description == null
                                    || video.description.trim().length() < 18)) {
                        video.description = details.intro;
                        synopsisView.setText(details.intro);
                        synopsisView.setVisibility(View.VISIBLE);
                        synopsisMoreBtn.setVisibility(
                                details.intro.length() > 60 ? View.VISIBLE : View.GONE);
                    }
                    if (!details.cast.isEmpty()) {
                        populateCast(details.cast);
                    }
                    if (!details.posterUrl.isEmpty()
                            && cover.backdrop.wideBitmap == null
                            && (cover.backdrop.rawBitmap == null
                                    || cover.backdrop.rawBitmap.isRecycled())) {
                        a.poster(details.posterUrl, cover.image, true);
                    }
                });
    }

    static String formatEpisodeFileCaption(Cms.Line line, Cms.Episode episode) {
        if (episode == null) return "";
        String lineName = line == null || line.name == null ? "" : line.name.trim();
        String epName = episode.name == null ? "" : episode.name.trim();
        String urlFile = extractFilenameFromUrl(episode.url);
        String display = epName;
        if (!urlFile.isEmpty()
                && !urlFile.equalsIgnoreCase(epName)
                && (epName.isEmpty()
                        || epName.length() <= 8
                        || "播放".equals(epName)
                        || "正片".equals(epName)
                        || "高清".equals(epName)
                        || "HD".equalsIgnoreCase(epName))) {
            display = epName.isEmpty() ? urlFile : (epName + " · " + urlFile);
        }
        if (display.isEmpty()) return "";
        return lineName.isEmpty() ? display : (lineName + "  ·  " + display);
    }

    static String extractFilenameFromUrl(String rawUrl) {
        if (rawUrl == null || rawUrl.trim().isEmpty()) return "";
        String trimmed = rawUrl.trim();
        if (!trimmed.regionMatches(true, 0, "http://", 0, 7)
                && !trimmed.regionMatches(true, 0, "https://", 0, 8)) {
            return "";
        }
        String path = extractRawHttpPath(trimmed);
        if (path.isEmpty()) return "";
        int slash = path.lastIndexOf('/');
        String base = slash >= 0 ? path.substring(slash + 1) : path;
        if (base.isEmpty()) return "";
        String decoded = MediaBadges.percentDecodeUtf8PreservePlus(base).trim();
        String lower = decoded.toLowerCase(java.util.Locale.ROOT);
        if (lower.equals("index.m3u8")
                || lower.equals("playlist.m3u8")
                || lower.equals("master.m3u8")
                || lower.equals("video.m3u8")
                || lower.equals("play.m3u8")
                || lower.equals("stream.m3u8")
                || lower.equals("stream.ts")
                || lower.endsWith(".php")
                || lower.endsWith(".html")
                || decoded.length() < 5
                || decoded.matches("^[0-9a-fA-F]{16,}\\.[a-z0-9]{2,5}$")) {
            return "";
        }
        if (lower.endsWith(".mp4")
                || lower.endsWith(".mkv")
                || lower.endsWith(".mov")
                || lower.endsWith(".avi")
                || lower.endsWith(".ts")
                || lower.endsWith(".flv")
                || lower.endsWith(".webm")
                || lower.endsWith(".m3u8")) {
            return decoded;
        }
        return "";
    }

    static String extractRawHttpPath(String url) {
        if (url == null) return "";
        int schemeEnd = url.indexOf("://");
        if (schemeEnd < 0) return "";
        int authorityStart = schemeEnd + 3;
        int end = url.length();
        int queryIdx = url.indexOf('?', authorityStart);
        if (queryIdx >= 0 && queryIdx < end) end = queryIdx;
        int hashIdx = url.indexOf('#', authorityStart);
        if (hashIdx >= 0 && hashIdx < end) end = hashIdx;
        int pathStart = url.indexOf('/', authorityStart);
        if (pathStart < 0 || pathStart >= end) return "";
        return url.substring(pathStart, end);
    }

    void updateEpisodeCaption(String caption, String buttonLabel) {
        if (caption != null) {
            episodeFileView.setText(caption);
            episodeFileView.setVisibility(caption.isEmpty() ? View.GONE : View.VISIBLE);
        }
        if (buttonLabel != null && !buttonLabel.isEmpty()) {
            episodesBtn.setText(buttonLabel);
        }
        refreshSpecBadges();
    }

    private void refreshSpecBadges() {
        WatchHistory.Entry bookmark = null;
        for (WatchHistory.Entry entry : host.watchHistory()) {
            if (site.key.equals(entry.site) && video.id != null && video.id.equals(entry.id)) {
                bookmark = entry;
                break;
            }
        }
        Cms.Line activeLine = null;
        Cms.Episode activeEpisode = null;
        if (video.lines != null && !video.lines.isEmpty()) {
            int[] sel =
                    TvDetailHost.initialSelection(
                            video,
                            bookmark,
                            host.prefs.getString(Prefs.PREFERRED_LINE, ""),
                            host.current == null ? null : host.current.selection,
                            host.prefs.getBoolean(Prefs.EPISODES_DESCENDING, false));
            int lineIdx = Math.max(0, Math.min(sel[0], video.lines.size() - 1));
            activeLine = video.lines.get(lineIdx);
            if (activeLine.episodes != null && !activeLine.episodes.isEmpty()) {
                activeEpisode = activeLine.episodes.get(0);
                if (bookmark != null
                        && activeLine.name.equals(bookmark.line)
                        && bookmark.episode != null) {
                    for (Cms.Episode ep : activeLine.episodes) {
                        if (bookmark.episode.equals(ep.name)) {
                            activeEpisode = ep;
                            break;
                        }
                    }
                }
            }
        }
        MediaBadgeView.populateRow(
                host,
                specBadgeRow,
                MediaBadgeView.extractForHero(host, video.remarks, activeLine, activeEpisode),
                MediaBadgeView.HERO_MAX_BADGES,
                false,
                true);
    }

    private static boolean hasMultipleEpisodes(Cms.Video video) {
        if (video == null || video.lines == null) return false;
        for (Cms.Line line : video.lines) {
            if (line != null && line.episodes != null && line.episodes.size() > 1) return true;
        }
        return false;
    }

    private void applyRatings(double dbScore, int rtPercent) {
        if (dbScore >= 2.0 && dbScore <= 9.9) {
            resolvedDouban = dbScore;
        }
        if (rtPercent >= 1 && rtPercent <= 100) {
            resolvedRt = rtPercent;
        }
        MobileDetailScreen.updateRatingBadges(
                doubanBadge, rtBadge, video, resolvedDouban, resolvedRt);
        boolean anyVisible = false;
        for (int i = 0; i < ratingRow.getChildCount(); i++) {
            if (ratingRow.getChildAt(i).getVisibility() == View.VISIBLE) {
                anyVisible = true;
                break;
            }
        }
        ratingRow.setVisibility(anyVisible ? View.VISIBLE : View.GONE);
    }

    private void populateCast(List<ImmersivePoster.CastMember> members) {
        castRow.removeAllViews();
        if (members == null || members.isEmpty()) {
            castSection.setVisibility(View.GONE);
            return;
        }
        castSection.setVisibility(View.VISIBLE);
        int limit = Math.min(12, members.size());
        for (int i = 0; i < limit; i++) {
            LinearLayout card = buildCastCard(members.get(i), i);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(host.dp(88), -2);
            if (i > 0) lp.leftMargin = host.dp(18);
            castRow.addView(card, lp);
        }
    }

    private LinearLayout buildCastCard(final ImmersivePoster.CastMember member, int index) {
        LinearLayout card = host.vertical();
        card.setTag("detail-cast:" + index);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        // Display-only: cast cards must never steal D-pad focus or trigger clicks.
        card.setFocusable(false);
        card.setFocusableInTouchMode(false);
        card.setClickable(false);
        card.setClipChildren(false);
        card.setClipToPadding(false);
        card.setPadding(host.dp(4), host.dp(4), host.dp(4), host.dp(4));

        int avatarPx = host.dp(58);
        final FrameLayout avatarFrame = new FrameLayout(host);
        int accent = AVATAR_ACCENTS[Math.abs(member.name.hashCode()) % AVATAR_ACCENTS.length];
        GradientDrawable monogramBg = new GradientDrawable();
        monogramBg.setShape(GradientDrawable.OVAL);
        monogramBg.setColor(accent);
        avatarFrame.setBackground(monogramBg);
        avatarFrame.setOutlineProvider(
                new ViewOutlineProvider() {
                    @Override
                    public void getOutline(View v, Outline outline) {
                        outline.setOval(0, 0, v.getWidth(), v.getHeight());
                    }
                });
        avatarFrame.setClipToOutline(true);

        String initial =
                member.name.isEmpty()
                        ? "?"
                        : member.name.substring(0, Math.min(1, member.name.length()));
        TextView monogram = host.text(initial, 19, 0xf0ffffff);
        monogram.setTypeface(null, Typeface.BOLD);
        monogram.setGravity(Gravity.CENTER);
        avatarFrame.addView(monogram, new FrameLayout.LayoutParams(-1, -1));

        if (!member.avatarUrl.isEmpty()) {
            ImageView photo = new ImageView(host);
            photo.setScaleType(ImageView.ScaleType.CENTER_CROP);
            avatarFrame.addView(photo, new FrameLayout.LayoutParams(-1, -1));
            host.poster(member.avatarUrl, photo, false);
        }

        FrameLayout ringWrap = new FrameLayout(host);
        int ringPad = host.dp(2);
        ringWrap.setPadding(ringPad, ringPad, ringPad, ringPad);
        GradientDrawable ring = new GradientDrawable();
        ring.setShape(GradientDrawable.OVAL);
        ring.setColor(0x00000000);
        ring.setStroke(Math.max(1, host.dp(1)), 0x36ffffff);
        ringWrap.setBackground(ring);
        ringWrap.addView(avatarFrame, new FrameLayout.LayoutParams(avatarPx, avatarPx));
        card.addView(
                ringWrap,
                new LinearLayout.LayoutParams(avatarPx + ringPad * 2, avatarPx + ringPad * 2));

        TextView nameTv = host.text(member.name, 12.5f, 0xeeffffff);
        nameTv.setSingleLine(true);
        nameTv.setEllipsize(TextUtils.TruncateAt.END);
        nameTv.setGravity(Gravity.CENTER);
        nameTv.setTypeface(null, Typeface.BOLD);
        LinearLayout.LayoutParams nameLp = new LinearLayout.LayoutParams(-1, -2);
        nameLp.topMargin = host.dp(8);
        card.addView(nameTv, nameLp);

        if (!member.role.isEmpty()) {
            TextView roleTv = host.text(member.role, 11, 0x9cd4dae6);
            roleTv.setSingleLine(true);
            roleTv.setEllipsize(TextUtils.TruncateAt.END);
            roleTv.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams roleLp = new LinearLayout.LayoutParams(-1, -2);
            roleLp.topMargin = host.dp(2);
            card.addView(roleTv, roleLp);
        }
        return card;
    }

    private void styleHeartFavorite(boolean focused, boolean selected) {
        FocusMotion.unclipAncestors(favorite);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        if (focused) {
            d.setColor(0xffffffff);
            d.setStroke(Math.max(1, host.dp(1.5f)), 0xffffffff);
            favorite.setTextColor(selected ? 0xffff3b30 : 0xff14161c);
            favorite.setElevation(host.dp(6));
            favorite.animate().scaleX(1.14f).scaleY(1.14f).setDuration(130).start();
        } else if (selected) {
            d.setColor(0x3aff3b30);
            d.setStroke(Math.max(1, host.dp(1)), 0x80ff453a);
            favorite.setTextColor(0xffff3b30);
            favorite.setElevation(0);
            favorite.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
        } else {
            d.setColor(0x58181d28);
            d.setStroke(Math.max(1, host.dp(1)), 0x42ffffff);
            favorite.setTextColor(0xecffffff);
            favorite.setElevation(0);
            favorite.animate().scaleX(1f).scaleY(1f).setDuration(130).start();
        }
        favorite.setBackground(d);
    }

    void setFavorite(boolean selected) {
        favorite.setText(selected ? "♥" : "♡");
        favorite.setSelected(selected);
        favorite.setContentDescription(selected ? "已收藏，点击取消收藏" : "收藏");
        styleHeartFavorite(favorite.hasFocus(), selected);
    }
}

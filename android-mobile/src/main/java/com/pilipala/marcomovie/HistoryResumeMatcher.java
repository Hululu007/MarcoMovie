package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Pure-JVM title, episode, and alternative-source matching logic for Watch History resume and
 * automatic cross-source failover.
 */
final class HistoryResumeMatcher {
    private static final Pattern SEASON_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:s|season\\s*)0*(\\d{1,2})\\s*[._\\-\\s]*e(?:p)?\\.?\\s*0*(\\d{1,4})");
    private static final Pattern EXPLICIT_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,4})\\s*[集话話回期]|(?:^|[^a-z0-9])ep?\\.?\\s*0*(\\d{1,4})(?:$|[^a-z0-9]))");
    private static final Pattern CN_EP_PATTERN =
            Pattern.compile("第\\s*([一二三四五六七八九十百零两兩]{1,5})\\s*[集话話回期]");
    private static final Pattern SEASON_ONLY_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,2})\\s*季|第\\s*([一二三四五六七八九十]{1,3})\\s*季|season\\s*0*(\\d{1,2})|(?:^|[^a-z0-9])s0*(\\d{1,2})(?:$|[^a-z0-9]))");
    private static final Pattern NOISE_NUMBERS_PATTERN =
            Pattern.compile(
                    "(?i)(?:\\b(?:2160|1080|720|480|360)p\\b|\\b(?:4k|8k|2k|10bit|8bit|hdr10|dv|h264|h265|x264|x265|hevc|avc|aac|ac3|eac3|dts|ddp5\\.?1|5\\.1|7\\.1)\\b|\\b(?:19|20)\\d{2}\\b)");
    private static final Pattern LOOSE_NUMBER_PATTERN =
            Pattern.compile("(?:^|[^0-9])0*(\\d{1,4})(?:$|[^0-9])");
    private static final Pattern TITLE_CLEAN_PATTERN =
            Pattern.compile("[\\s\\p{Punct}·•—–：:，,。！？!？【】\\[\\]()（）《》<>「」『』]+");

    static final class EpisodeMatch {
        final Cms.Line line;
        final Cms.Episode episode;
        final int score;

        EpisodeMatch(Cms.Line line, Cms.Episode episode, int score) {
            this.line = line;
            this.episode = episode;
            this.score = score;
        }
    }

    private HistoryResumeMatcher() {}

    static int extractSeasonNumber(String text) {
        if (text == null || text.trim().isEmpty()) return -1;
        Matcher se = SEASON_EP_PATTERN.matcher(text);
        if (se.find()) {
            return parsePositiveInt(se.group(1));
        }
        Matcher m = SEASON_ONLY_PATTERN.matcher(text);
        if (m.find()) {
            if (m.group(1) != null) return parsePositiveInt(m.group(1));
            if (m.group(2) != null) return parseChineseNumeral(m.group(2));
            if (m.group(3) != null) return parsePositiveInt(m.group(3));
            if (m.group(4) != null) return parsePositiveInt(m.group(4));
        }
        return -1;
    }

    static int extractEpisodeNumber(String name) {
        if (name == null) return -1;
        String trimmed = name.trim();
        if (trimmed.isEmpty()) return -1;

        Matcher se = SEASON_EP_PATTERN.matcher(trimmed);
        if (se.find()) {
            return parsePositiveInt(se.group(2));
        }
        Matcher exp = EXPLICIT_EP_PATTERN.matcher(trimmed);
        if (exp.find()) {
            String g = exp.group(1) != null ? exp.group(1) : exp.group(2);
            return parsePositiveInt(g);
        }
        Matcher cn = CN_EP_PATTERN.matcher(trimmed);
        if (cn.find()) {
            return parseChineseNumeral(cn.group(1));
        }

        // Strip common video metadata numbers (1080p, 2026, H265, 5.1) before loose digit fallback.
        String stripped = NOISE_NUMBERS_PATTERN.matcher(trimmed).replaceAll(" ");
        // Also strip file extensions so ".mp4" doesn't match "4".
        stripped = stripped.replaceAll("(?i)\\.(?:mkv|mp4|m4v|ts|flv|avi|mov|m3u8|webm)\\b", " ");
        Matcher loose = LOOSE_NUMBER_PATTERN.matcher(stripped);
        int found = -1;
        while (loose.find()) {
            int val = parsePositiveInt(loose.group(1));
            if (val > 0 && val <= 2000) {
                found = val;
            }
        }
        return found;
    }

    static boolean looksLikeMovieEpisode(String name) {
        if (name == null) return true;
        String lower = name.trim().toLowerCase(Locale.ROOT);
        if (lower.isEmpty()) return true;
        if (extractEpisodeNumber(lower) > 1) return false;
        return lower.contains("正片")
                || lower.contains("高清")
                || lower.contains("超清")
                || lower.contains("蓝光")
                || lower.contains("原画")
                || lower.contains("完整")
                || lower.contains("抢先")
                || lower.contains("中字")
                || lower.contains("国语")
                || lower.contains("粤语")
                || lower.contains("1080")
                || lower.contains("2160")
                || lower.contains("4k")
                || lower.contains("hd")
                || lower.contains("bd")
                || lower.contains("tc")
                || lower.contains("ts")
                || lower.contains("全集");
    }

    private static final Pattern TRAILER_EXTRA_PATTERN =
            Pattern.compile(
                    "(?i)(?:预告|先导|花絮|彩蛋|特辑|宣传片|片花|定档|终极版|\\b(?:pv|mv|trailer|teaser|preview|sp|ova)\\b)");

    /**
     * Returns {@code true} for local proxy leases or resolved temporary netdisk download URLs that
     * must NEVER be persisted or synced.
     */
    static boolean isSensitiveOrEphemeralUrl(String rawUrl) {
        return WatchHistory.isSensitiveOrEphemeralUrl(rawUrl);
    }

    /**
     * Computes a non-sensitive stable episode fingerprint from an upstream episode identifier/URL
     * after stripping query parameters, fragments, and userinfo. Returns {@code ""} for local proxy
     * leases or temporary signed netdisk download URLs so sensitive/ephemeral URLs never enter
     * local bookmarks or CloudSync payloads.
     */
    static String stableEpisodeKey(String rawUrl) {
        return WatchHistory.stableEpisodeKey(rawUrl);
    }

    static String bookmarkDriveKey(WatchHistory.Entry bookmark) {
        return WatchHistory.bookmarkDriveKey(bookmark);
    }

    static String bookmarkEpisodeKey(WatchHistory.Entry bookmark) {
        return WatchHistory.bookmarkEpisodeKey(bookmark);
    }

    static boolean isTrailerOrExtraName(String name) {
        if (name == null || name.trim().isEmpty()) return false;
        return TRAILER_EXTRA_PATTERN.matcher(name.trim()).find();
    }

    static int lineMatchStrength(Cms.Line line, WatchHistory.Entry bookmark) {
        if (line == null || bookmark == null) return 0;
        String bmDrive = bookmarkDriveKey(bookmark);
        String candDrive = NetdiskStore.detectLineDriveKey(line);
        if (!bmDrive.isEmpty() && !candDrive.isEmpty() && !bmDrive.equals(candDrive)) {
            return -1;
        }
        String bmLineId = bookmark.lineId == null ? "" : bookmark.lineId.trim();
        String bmLine = bookmark.line == null ? "" : bookmark.line.trim();
        String candId = line.lineId();
        String candRaw = line.rawName();
        String candName = line.name == null ? "" : line.name.trim();
        boolean sameDrive = !bmDrive.isEmpty() && bmDrive.equals(candDrive);
        boolean sameLineBaseName =
                !bmLine.isEmpty()
                        && (PlaybackLineRules.matchesLine(line, bmLine)
                                || bmLine.equalsIgnoreCase(candRaw)
                                || bmLine.equalsIgnoreCase(candName));
        if (!bmLineId.isEmpty()) {
            if (bmLineId.equals(candId)) {
                return sameDrive ? 4 : 3;
            }
            if (sameDrive && sameLineBaseName) {
                return 3;
            }
            return 0;
        }
        if (sameDrive && sameLineBaseName) return 3;
        if (bmLine.isEmpty()) return sameDrive ? 2 : 0;
        if (!candId.isEmpty() && bmLine.equals(candId)) return 2;
        if (sameLineBaseName) {
            return 1;
        }
        return sameDrive ? 1 : 0;
    }

    static boolean isSameBookmarkLine(Cms.Line line, WatchHistory.Entry bookmark) {
        if (line == null || bookmark == null) return false;
        int strength = lineMatchStrength(line, bookmark);
        if (strength < 0) return false;
        if (strength > 0) return true;
        String bmEpKey = bookmarkEpisodeKey(bookmark);
        if (!bmEpKey.isEmpty() && line.episodes != null) {
            for (Cms.Episode ep : line.episodes) {
                if (ep != null && bmEpKey.equals(stableEpisodeKey(ep.url))) {
                    return true;
                }
            }
        }
        return false;
    }

    private static final Pattern PART_NUMBER_PATTERN =
            Pattern.compile(
                    "(?i)(?:^|[^a-z0-9])(?:part|pt|cd|disc)\\s*[._\\-]?\\s*0*(\\d{1,2})(?:$|[^a-z0-9])");
    private static final Pattern PART_UPPER_PATTERN =
            Pattern.compile(
                    "(?:上部|上集|上篇|上卷|前篇|前集|前半|^[上前]$|[\\s_\\-\\(\\[（【正片影剧清蓝原画全集]+上[\\s_\\-\\)\\]）】]*$)");
    private static final Pattern PART_MIDDLE_PATTERN =
            Pattern.compile(
                    "(?:中部|中集|中篇|中卷|^[中]$|[\\s_\\-\\(\\[（【正片影剧清蓝原画全集]+中[\\s_\\-\\)\\]）】]*$)");
    private static final Pattern PART_LOWER_PATTERN =
            Pattern.compile(
                    "(?:下部|下集|下篇|下卷|后篇|后集|后半|^[下后]$|[\\s_\\-\\(\\[（【正片影剧清蓝原画全集]+下[\\s_\\-\\)\\]）】]*$)");

    /**
     * Distinguishes split-part labels such as {@code 正片上} vs {@code 正片下}, {@code 上篇}/{@code
     * 中篇}/{@code 下篇}, and {@code Part 1}/{@code Part 2}/{@code CD1}/{@code CD2}. Returns {@code
     * 0} when no split-part marker is present.
     */
    static int extractPartMarker(String name) {
        if (name == null || name.trim().isEmpty()) return 0;
        String trimmed = name.trim();
        Matcher pm = PART_NUMBER_PATTERN.matcher(trimmed);
        if (pm.find()) {
            int n = parsePositiveInt(pm.group(1));
            if (n > 0) return 100 + n;
        }
        if (PART_UPPER_PATTERN.matcher(trimmed).find()) return 1;
        if (PART_MIDDLE_PATTERN.matcher(trimmed).find()) return 2;
        if (PART_LOWER_PATTERN.matcher(trimmed).find()) return 3;
        return 0;
    }

    private static boolean hasEpisodeIdentityConflict(
            String bmEp, String candName, int lineEpisodeCount) {
        boolean bmTrailer = isTrailerOrExtraName(bmEp);
        boolean candTrailer = isTrailerOrExtraName(candName);
        if (bmTrailer != candTrailer) return true;
        int bmPart = extractPartMarker(bmEp);
        int candPart = extractPartMarker(candName);
        if (bmPart > 0 && candPart > 0 && bmPart != candPart) return true;
        if (bmPart != candPart && lineEpisodeCount > 1) return true;
        int bmEpNum = extractEpisodeNumber(bmEp);
        int candEpNum = extractEpisodeNumber(candName);
        if (bmEpNum > 0 && candEpNum > 0) {
            if (bmEpNum != candEpNum) return true;
            int bmSeason = extractSeasonNumber(bmEp);
            int candSeason = extractSeasonNumber(candName);
            if (bmSeason > 0 && candSeason > 0 && bmSeason != candSeason) return true;
        }
        return false;
    }

    private static boolean hasDuplicateEpisodeName(Cms.Line line, String candName) {
        if (line == null || line.episodes == null || candName == null || candName.isEmpty()) {
            return false;
        }
        int count = 0;
        for (Cms.Episode ep : line.episodes) {
            if (ep != null && ep.name != null && candName.equalsIgnoreCase(ep.name.trim())) {
                count++;
                if (count > 1) return true;
            }
        }
        return false;
    }

    private static boolean lineHasAnotherEpKeyMatch(
            Cms.Line line, String bmEpKey, Cms.Episode exclude) {
        if (line == null || line.episodes == null || bmEpKey == null || bmEpKey.isEmpty()) {
            return false;
        }
        for (Cms.Episode ep : line.episodes) {
            if (ep == null || ep == exclude) continue;
            if (bmEpKey.equals(stableEpisodeKey(ep.url))) {
                return true;
            }
        }
        return false;
    }

    private static boolean isEpKeyUniqueInLine(Cms.Line line, String epKey) {
        if (line == null || line.episodes == null || epKey == null || epKey.isEmpty()) {
            return false;
        }
        int count = 0;
        for (Cms.Episode ep : line.episodes) {
            if (ep != null && epKey.equals(stableEpisodeKey(ep.url))) {
                count++;
                if (count > 1) return false;
            }
        }
        return count == 1;
    }

    /**
     * Checks whether two non-empty episode titles are compatible enough to trust an episodeKey
     * match without cross-inheriting progress across distinct titled episodes (e.g. "返航" vs
     * "开端") on a multi-episode line if fingerprints ever collide.
     */
    private static boolean areTitlesCompatibleForEpKeyMatch(
            String bmEp, String candName, int lineSize) {
        if (bmEp == null || bmEp.isEmpty() || candName == null || candName.isEmpty()) {
            return true;
        }
        if (bmEp.equalsIgnoreCase(candName)) return true;
        int bmNum = extractEpisodeNumber(bmEp);
        int candNum = extractEpisodeNumber(candName);
        if (bmNum > 0 && candNum > 0) {
            if (bmNum != candNum) return false;
            int bmSeason = extractSeasonNumber(bmEp);
            int candSeason = extractSeasonNumber(candName);
            return bmSeason <= 0 || candSeason <= 0 || bmSeason == candSeason;
        }
        if (lineSize == 1
                && looksLikeMovieEpisode(bmEp)
                && looksLikeMovieEpisode(candName)
                && extractPartMarker(bmEp) == extractPartMarker(candName)) {
            return true;
        }
        String normBm = normalizeTitle(bmEp);
        String normCand = normalizeTitle(candName);
        return !normBm.isEmpty()
                && !normCand.isEmpty()
                && (normBm.equals(normCand)
                        || normCand.contains(normBm)
                        || normBm.contains(normCand));
    }

    private static boolean isConfirmedEpKeyMatch(
            Cms.Line line, Cms.Episode ep, String bmEp, String bmEpKey) {
        if (line == null || ep == null || bmEpKey == null || bmEpKey.isEmpty()) return false;
        String candEpKey = stableEpisodeKey(ep.url);
        if (!bmEpKey.equals(candEpKey)) return false;
        int lineSize = line.episodes != null ? line.episodes.size() : 0;
        String candName = ep.name == null ? "" : ep.name.trim();
        if (hasEpisodeIdentityConflict(bmEp, candName, lineSize)) return false;
        if (!isEpKeyUniqueInLine(line, bmEpKey)) return false;
        return areTitlesCompatibleForEpKeyMatch(bmEp, candName, lineSize);
    }

    /**
     * Checks whether {@code target} is the unique compatible episode-number (and season, when
     * specified) match for {@code bmEp} within {@code line}. Rejects ambiguous duplicate episode
     * numbers such as two seasons both labeled "第2集" on one line or two un-fingerprinted proxy
     * resources sharing "第2集".
     */
    private static boolean isUniqueEpisodeNumberMatch(
            Cms.Line line, Cms.Episode target, String bmEp) {
        if (line == null || line.episodes == null || target == null || bmEp == null) return false;
        int bmEpNum = extractEpisodeNumber(bmEp);
        if (bmEpNum <= 0) return false;
        String targetName = target.name == null ? "" : target.name.trim();
        if (targetName.isEmpty()) return false;
        int lineSize = line.episodes.size();
        if (hasEpisodeIdentityConflict(bmEp, targetName, lineSize)) return false;
        if (extractEpisodeNumber(targetName) != bmEpNum) return false;

        int bmSeason = extractSeasonNumber(bmEp);
        int targetSeason = extractSeasonNumber(targetName);
        int compatibleCount = 0;
        int exactSeasonCount = 0;
        for (Cms.Episode ep : line.episodes) {
            if (ep == null) continue;
            String epName = ep.name == null ? "" : ep.name.trim();
            if (epName.isEmpty()) continue;
            if (hasEpisodeIdentityConflict(bmEp, epName, lineSize)) continue;
            if (extractEpisodeNumber(epName) != bmEpNum) continue;
            compatibleCount++;
            if (bmSeason > 0 && extractSeasonNumber(epName) == bmSeason) {
                exactSeasonCount++;
            }
        }
        if (bmSeason > 0 && exactSeasonCount > 0) {
            return exactSeasonCount == 1 && targetSeason == bmSeason;
        }
        return compatibleCount == 1;
    }

    static boolean matchesBookmarkSelection(
            Cms.Line line, Cms.Episode ep, int epIdx, WatchHistory.Entry bookmark) {
        if (line == null || ep == null || bookmark == null) return false;
        int lineStrength = lineMatchStrength(line, bookmark);
        if (lineStrength < 0) {
            return false;
        }
        int lineSize = line.episodes != null ? line.episodes.size() : 0;
        String bmEp = bookmark.episode == null ? "" : bookmark.episode.trim();
        String candName = ep.name == null ? "" : ep.name.trim();
        if (hasEpisodeIdentityConflict(bmEp, candName, lineSize)) {
            return false;
        }
        String bmEpKey = bookmarkEpisodeKey(bookmark);
        String candEpKey = stableEpisodeKey(ep.url);
        if (isConfirmedEpKeyMatch(line, ep, bmEp, bmEpKey)) {
            return true;
        }
        String bmLineId = bookmark.lineId == null ? "" : bookmark.lineId.trim();
        String bmLine = bookmark.line == null ? "" : bookmark.line.trim();
        String bmDrive = bookmarkDriveKey(bookmark);
        if ((!bmLineId.isEmpty() || !bmLine.isEmpty() || !bmDrive.isEmpty()) && lineStrength <= 0) {
            return false;
        }
        boolean keysPresentAndDiffer =
                !bmEpKey.isEmpty() && !candEpKey.isEmpty() && !bmEpKey.equals(candEpKey);
        if (keysPresentAndDiffer && lineHasAnotherEpKeyMatch(line, bmEpKey, ep)) {
            return false;
        }
        if (!bmEp.isEmpty() && !candName.isEmpty()) {
            // Disambiguation order after unique confirmed episodeKey:
            // 1. Unique exact title match (rejects duplicate generic or duplicate numbered names)
            if (candName.equalsIgnoreCase(bmEp) && !hasDuplicateEpisodeName(line, candName)) {
                return true;
            }
            // 2. Unique compatible episode-number (and season) match within the line
            if (isUniqueEpisodeNumberMatch(line, ep, bmEp)) {
                return true;
            }
            int bmEpNum = extractEpisodeNumber(bmEp);
            int candEpNum = extractEpisodeNumber(candName);
            if (bmEpNum > 0 || candEpNum > 0) {
                return false;
            }
            // 3. Single-item movie title match
            if (lineSize == 1
                    && looksLikeMovieEpisode(bmEp)
                    && looksLikeMovieEpisode(candName)
                    && extractPartMarker(bmEp) == extractPartMarker(candName)) {
                return true;
            }
            return false;
        }
        // Without episode names/numbers, only allow single-item same-line anonymous match when
        // episodeKeys do not contradict each other; otherwise cannot confirm identity -> start at
        // 0.
        if (keysPresentAndDiffer) return false;
        return lineSize == 1 && epIdx == 0 && bookmark.index == 0 && lineStrength > 0;
    }

    /** Unified pure-JVM resume position resolver shared by Detail, History, Fullscreen & Inline. */
    static int resolveResumePositionMs(
            Cms.Line line, Cms.Episode ep, int epIdx, WatchHistory.Entry bookmark) {
        if (bookmark == null || !matchesBookmarkSelection(line, ep, epIdx, bookmark)) {
            return 0;
        }
        return bookmark.resume();
    }

    /**
     * Resolves resume position for cross-source failover: carries progress ONLY when the matched
     * episode on the alternative source has confirmed unique identity with {@code bookmark} (unique
     * episodeKey, unique exact title/part, unique episode number/season, or both single-item
     * movies). Never transfers progress onto a different or ambiguous duplicate episode.
     */
    static int resolveFailoverResumePositionMs(EpisodeMatch match, WatchHistory.Entry bookmark) {
        if (match == null || match.line == null || match.episode == null || bookmark == null) {
            return 0;
        }
        int lineSize = match.line.episodes != null ? match.line.episodes.size() : 0;
        String bmEp = bookmark.episode == null ? "" : bookmark.episode.trim();
        String candName = match.episode.name == null ? "" : match.episode.name.trim();
        if (hasEpisodeIdentityConflict(bmEp, candName, lineSize)) {
            return 0;
        }
        String bmEpKey = bookmarkEpisodeKey(bookmark);
        if (isConfirmedEpKeyMatch(match.line, match.episode, bmEp, bmEpKey)) {
            return bookmark.resume();
        }
        String candEpKey = stableEpisodeKey(match.episode.url);
        boolean keysPresentAndDiffer =
                !bmEpKey.isEmpty() && !candEpKey.isEmpty() && !bmEpKey.equals(candEpKey);
        if (keysPresentAndDiffer && lineHasAnotherEpKeyMatch(match.line, bmEpKey, match.episode)) {
            return 0;
        }
        if (!bmEp.isEmpty() && !candName.isEmpty()) {
            if (candName.equalsIgnoreCase(bmEp) && !hasDuplicateEpisodeName(match.line, candName)) {
                return bookmark.resume();
            }
            if (isUniqueEpisodeNumberMatch(match.line, match.episode, bmEp)) {
                return bookmark.resume();
            }
            int bmEpNum = extractEpisodeNumber(bmEp);
            int candEpNum = extractEpisodeNumber(candName);
            if (bmEpNum > 0 || candEpNum > 0) {
                return 0;
            }
            if (lineSize == 1
                    && looksLikeMovieEpisode(bmEp)
                    && looksLikeMovieEpisode(candName)
                    && extractPartMarker(bmEp) == extractPartMarker(candName)) {
                return bookmark.resume();
            }
            return 0;
        }
        return 0;
    }

    static int findMatchedLineIndex(Cms.Video video, WatchHistory.Entry bookmark) {
        EpisodeMatch m = matchEpisode(video, bookmark);
        if (m == null || video == null || video.lines == null) return -1;
        return video.lines.indexOf(m.line);
    }

    static int findMatchedEpisodeIndex(Cms.Line line, WatchHistory.Entry bookmark) {
        if (line == null || line.episodes == null || line.episodes.isEmpty() || bookmark == null) {
            return 0;
        }
        int lineSize = line.episodes.size();
        String bmEp = bookmark.episode == null ? "" : bookmark.episode.trim();
        String bmEpKey = bookmarkEpisodeKey(bookmark);
        if (!bmEpKey.isEmpty() && isEpKeyUniqueInLine(line, bmEpKey)) {
            for (int i = 0; i < lineSize; i++) {
                Cms.Episode ep = line.episodes.get(i);
                if (isConfirmedEpKeyMatch(line, ep, bmEp, bmEpKey)) {
                    return i;
                }
            }
        }
        if (!bmEp.isEmpty()) {
            if (!hasDuplicateEpisodeName(line, bmEp)) {
                for (int i = 0; i < lineSize; i++) {
                    Cms.Episode ep = line.episodes.get(i);
                    if (ep != null
                            && ep.name != null
                            && bmEp.equalsIgnoreCase(ep.name.trim())
                            && !hasEpisodeIdentityConflict(bmEp, ep.name, lineSize)) {
                        return i;
                    }
                }
            }
            if (extractEpisodeNumber(bmEp) > 0) {
                for (int i = 0; i < lineSize; i++) {
                    Cms.Episode ep = line.episodes.get(i);
                    if (isUniqueEpisodeNumberMatch(line, ep, bmEp)) {
                        return i;
                    }
                }
            }
        }
        if (bookmark.index >= 0 && bookmark.index < lineSize) {
            Cms.Episode atIdx = line.episodes.get(bookmark.index);
            if (atIdx != null
                    && !hasEpisodeIdentityConflict(
                            bmEp, atIdx.name == null ? "" : atIdx.name, lineSize)) {
                return bookmark.index;
            }
        }
        return 0;
    }

    static EpisodeMatch matchEpisode(Cms.Video video, WatchHistory.Entry bookmark) {
        return matchEpisode(video, bookmark, false);
    }

    /**
     * Cross-source failover episode matcher: prefers the same netdisk drive when available on the
     * alternative source, but allows matching an alternative drive (e.g. original site Quark failed
     * -> alternative site only carries Baidu with the confirmed same episode) while still strictly
     * enforcing episode identity.
     */
    static EpisodeMatch matchEpisodeForFailover(Cms.Video video, WatchHistory.Entry bookmark) {
        return matchEpisode(video, bookmark, true);
    }

    static EpisodeMatch matchEpisode(
            Cms.Video video, WatchHistory.Entry bookmark, boolean crossSourceFailover) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return null;
        String bmEp = bookmark == null || bookmark.episode == null ? "" : bookmark.episode.trim();
        String bmEpKey = bookmarkEpisodeKey(bookmark);
        int bmIndex = bookmark == null ? 0 : Math.max(0, bookmark.index);
        int bmEpNum = extractEpisodeNumber(bmEp);
        int bmSeason = extractSeasonNumber(bmEp);
        int bmPart = extractPartMarker(bmEp);
        boolean bmTrailer = isTrailerOrExtraName(bmEp);
        boolean bmMovieLike = looksLikeMovieEpisode(bmEp) && bmPart == 0 && bmIndex == 0;

        EpisodeMatch best = null;
        for (Cms.Line line : video.lines) {
            if (line == null || line.episodes == null || line.episodes.isEmpty()) continue;
            int lineStrength = lineMatchStrength(line, bookmark);
            boolean driveConflict = !crossSourceFailover && lineStrength < 0;
            boolean sameLine = lineStrength > 0;
            int lineCount = line.episodes.size();
            int lineBonus;
            if (driveConflict) {
                lineBonus = -240;
            } else if (crossSourceFailover) {
                // On an alternative site, prefer same drive if available, but never reject a
                // confirmed episode solely because the alternative site hosts another drive.
                String bmDrive = bookmarkDriveKey(bookmark);
                String candDrive = NetdiskStore.detectLineDriveKey(line);
                lineBonus =
                        (!bmDrive.isEmpty() && bmDrive.equals(candDrive))
                                ? 20
                                : (sameLine ? 12 : 0);
            } else if (lineStrength >= 4) {
                lineBonus = 150;
            } else if (lineStrength == 3) {
                lineBonus = 120;
            } else if (lineStrength == 2) {
                lineBonus = 50;
            } else if (lineStrength == 1) {
                lineBonus = 25;
            } else {
                lineBonus = 0;
            }
            if (!sameLine && !driveConflict && lineCount > 1) {
                lineBonus += 4;
            }
            if (!sameLine && !driveConflict && looksLikeNetdiskLineName(line.name)) {
                lineBonus -= 8;
            }

            for (int i = 0; i < lineCount; i++) {
                Cms.Episode ep = line.episodes.get(i);
                if (ep == null) continue;
                String candName = ep.name == null ? "" : ep.name.trim();
                String candEpKey = stableEpisodeKey(ep.url);
                boolean candTrailer = isTrailerOrExtraName(candName);
                int candPart = extractPartMarker(candName);
                int candNum = extractEpisodeNumber(candName);
                boolean identityConflict = hasEpisodeIdentityConflict(bmEp, candName, lineCount);
                int score = -1;

                // 0. Confirmed unique non-sensitive canonical episodeKey match (requires uniqueness
                //    in line and title compatibility so collisions never cross-inherit progress)
                boolean hasOtherEpKeyMatch =
                        !bmEpKey.isEmpty()
                                && !candEpKey.isEmpty()
                                && !bmEpKey.equals(candEpKey)
                                && lineHasAnotherEpKeyMatch(line, bmEpKey, ep);
                if (!driveConflict && isConfirmedEpKeyMatch(line, ep, bmEp, bmEpKey)) {
                    score = 220 + lineBonus + (bmIndex == i ? 10 : 0);
                } else if (!identityConflict
                        && !hasOtherEpKeyMatch
                        && !bmEp.isEmpty()
                        && bmEp.equalsIgnoreCase(candName)
                        && !hasDuplicateEpisodeName(line, candName)) {
                    // 1. Unique exact episode name match
                    score = 140 + lineBonus + (sameLine && bmIndex == i ? 10 : 0);
                } else if (!identityConflict && !hasOtherEpKeyMatch) {
                    // 2. Unique normalized episode number (and season) match within the line
                    //    (e.g. 第05集 <-> EP05 <-> S01E05 <-> 05; rejects duplicate "第2集" across
                    //    multi-season single-line dumps or duplicate proxy items)
                    if (isUniqueEpisodeNumberMatch(line, ep, bmEp) && bmTrailer == candTrailer) {
                        score = 100 + lineBonus;
                        int candSeason = extractSeasonNumber(candName);
                        if (bmSeason > 0 && candSeason > 0) {
                            score += (bmSeason == candSeason) ? 10 : -45;
                        }
                    } else if (lineCount == 1
                            && (bmMovieLike || bmEp.isEmpty())
                            && bmPart == candPart
                            && !candTrailer
                            && bmEpNum <= 0
                            && candNum <= 0) {
                        // 3. Single-stream movie match across sources
                        score = 82 + lineBonus;
                    } else if (sameLine
                            && !crossSourceFailover
                            && lineCount == 1
                            && bmIndex == 0
                            && i == 0
                            && bmEpNum <= 0
                            && candNum <= 0
                            && bmPart == candPart
                            && bmTrailer == candTrailer
                            && (bmEp.isEmpty() || candName.isEmpty())) {
                        // 4. Single-item anonymous stream fallback on the same line only
                        score = 72 + lineBonus;
                    }
                }
                if (bmTrailer != candTrailer && score > 0) {
                    score -= 140;
                }

                if (score >= 40 && (best == null || score > best.score)) {
                    best = new EpisodeMatch(line, ep, score);
                }
            }
        }

        if (best != null) return best;

        // Final safe fallback ONLY for single-item movie entries when bookmark has no explicit
        // episode number or split-part marker (e.g. never map "第2集" or "正片下" onto an unrelated
        // single stream).
        if (bmIndex == 0 && bmEpNum <= 0 && bmPart == 0 && !bmTrailer) {
            for (Cms.Line line : video.lines) {
                if (line != null && line.episodes != null && line.episodes.size() == 1) {
                    Cms.Episode only = line.episodes.get(0);
                    String onlyName = only == null || only.name == null ? "" : only.name.trim();
                    if (!isTrailerOrExtraName(onlyName)
                            && extractPartMarker(onlyName) == 0
                            && extractEpisodeNumber(onlyName) <= 0) {
                        return new EpisodeMatch(line, only, 42);
                    }
                }
            }
        }
        return null;
    }

    static int scoreTitleMatch(WatchHistory.Entry entry, Cms.Video candidate) {
        if (entry == null || candidate == null) return 0;
        String rawTarget = entry.title == null ? "" : entry.title.trim();
        String rawCand = candidate.title == null ? "" : candidate.title.trim();
        if (rawTarget.isEmpty() || rawCand.isEmpty()) return 0;

        Cms.Video ref = new Cms.Video();
        ref.title = rawTarget;
        int base = TvCuratedHome.scoreSourceMatch(ref, candidate);

        String normTarget = normalizeTitle(rawTarget);
        String normCand = normalizeTitle(rawCand);
        if (!normTarget.isEmpty() && normTarget.equals(normCand)) {
            base = Math.max(base, 95);
        } else if (!normTarget.isEmpty()
                && !normCand.isEmpty()
                && (normCand.contains(normTarget) || normTarget.contains(normCand))) {
            int diff = Math.abs(normCand.length() - normTarget.length());
            if (diff <= 4) {
                base = Math.max(base, 78);
            }
        }

        int targetSeason = extractSeasonNumber(rawTarget);
        int candSeason = extractSeasonNumber(rawCand);
        if (targetSeason > 0 && candSeason > 0 && targetSeason != candSeason) {
            base -= 55;
        } else if ((targetSeason > 1 && candSeason <= 0) || (candSeason > 1 && targetSeason <= 0)) {
            base -= 35;
        }
        return Math.max(0, base);
    }

    static String normalizeTitle(String raw) {
        if (raw == null) return "";
        return TITLE_CLEAN_PATTERN.matcher(raw.trim().toLowerCase(Locale.ROOT)).replaceAll("");
    }

    static List<Cms.Site> rankAlternativeSites(
            List<Cms.Site> availableSearchableSites,
            String failedSiteKey,
            String preferredSiteKey,
            int maxCount) {
        List<Cms.Site> out = new ArrayList<>();
        if (availableSearchableSites == null
                || availableSearchableSites.isEmpty()
                || maxCount <= 0) {
            return out;
        }
        List<Cms.Site> preferred = new ArrayList<>();
        List<Cms.Site> light = new ArrayList<>();
        List<Cms.Site> standard = new ArrayList<>();
        List<Cms.Site> heavy = new ArrayList<>();

        for (Cms.Site site : availableSearchableSites) {
            if (site == null || site.key == null) continue;
            if (failedSiteKey != null && failedSiteKey.equals(site.key)) continue;
            if (SearchCoordinator.isSiteWedged(site.key)) continue;
            if (SourceController.isConfigOrNetdiskSite(site)) continue;
            if (preferredSiteKey != null && preferredSiteKey.equals(site.key)) {
                preferred.add(site);
            } else if (isFastSite(site)) {
                light.add(site);
            } else if (isHeavySite(site)) {
                heavy.add(site);
            } else {
                standard.add(site);
            }
        }
        appendUpTo(out, preferred, maxCount);
        appendUpTo(out, light, maxCount);
        appendUpTo(out, standard, maxCount);
        appendUpTo(out, heavy, maxCount);
        return out;
    }

    private static void appendUpTo(List<Cms.Site> dst, List<Cms.Site> src, int maxCount) {
        for (Cms.Site s : src) {
            if (dst.size() >= maxCount) return;
            boolean dup = false;
            for (Cms.Site existing : dst) {
                if (Objects.equals(existing.key, s.key)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) dst.add(s);
        }
    }

    private static boolean isFastSite(Cms.Site site) {
        String api = site.api == null ? "" : site.api;
        return site.supported()
                || HttpT4Engine.eligible(site)
                || api.startsWith(MobileEmbyLibrary.PREFIX)
                || api.startsWith(AlistEngine.PREFIX);
    }

    private static boolean isHeavySite(Cms.Site site) {
        String api = site.api == null ? "" : site.api;
        return api.startsWith("catpaw://")
                || DrpyEngine.eligible(site)
                || GuardEngine.eligible(site)
                || JsEngine.eligible(site);
    }

    private static boolean looksLikeNetdiskLineName(String lineName) {
        if (lineName == null) return false;
        String lower = lineName.toLowerCase(Locale.ROOT);
        return lower.contains("夸克")
                || lower.contains("夸父")
                || lower.contains("阿里")
                || lower.contains("百度")
                || lower.contains("摆渡")
                || lower.contains("天翼")
                || lower.contains("115")
                || lower.contains("uc")
                || lower.contains("网盘");
    }

    private static int parsePositiveInt(String text) {
        if (text == null || text.isEmpty()) return -1;
        try {
            int val = Integer.parseInt(text.trim());
            return val > 0 ? val : -1;
        } catch (Exception ignored) {
            return -1;
        }
    }

    private static int parseChineseNumeral(String cn) {
        if (cn == null || cn.isEmpty()) return -1;
        int total = 0;
        int current = 0;
        for (int i = 0; i < cn.length(); i++) {
            char c = cn.charAt(i);
            int d = chineseDigit(c);
            if (d >= 0) {
                current = d;
            } else if (c == '十') {
                total += (current == 0 ? 1 : current) * 10;
                current = 0;
            } else if (c == '百') {
                total += (current == 0 ? 1 : current) * 100;
                current = 0;
            } else {
                return -1;
            }
        }
        int result = total + current;
        return result > 0 ? result : -1;
    }

    private static int chineseDigit(char c) {
        switch (c) {
            case '零':
                return 0;
            case '一':
                return 1;
            case '二':
            case '两':
            case '兩':
                return 2;
            case '三':
                return 3;
            case '四':
                return 4;
            case '五':
                return 5;
            case '六':
                return 6;
            case '七':
                return 7;
            case '八':
                return 8;
            case '九':
                return 9;
            default:
                return -1;
        }
    }
}

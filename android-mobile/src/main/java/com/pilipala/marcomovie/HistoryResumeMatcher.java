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

    /**
     * Conservative season extractor for line names (e.g. {@code 夸克·第一季}, {@code 百度·第二季},
     * {@code Season 2}). Intentionally excludes bare {@code S1}/{@code S2} tokens so CDN node names
     * such as {@code S1高速} are never misclassified as seasons.
     */
    private static final Pattern EXPLICIT_LINE_SEASON_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,2})\\s*季|第\\s*([一二三四五六七八九十]{1,3})\\s*季|season\\s*0*(\\d{1,2}))");

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
        final int videoSeason;

        EpisodeMatch(Cms.Line line, Cms.Episode episode, int score) {
            this(line, episode, score, -1);
        }

        EpisodeMatch(Cms.Line line, Cms.Episode episode, int score, int videoSeason) {
            this.line = line;
            this.episode = episode;
            this.score = score;
            this.videoSeason = videoSeason;
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

    static int extractExplicitLineSeasonNumber(String lineName) {
        if (lineName == null || lineName.trim().isEmpty()) return -1;
        Matcher m = EXPLICIT_LINE_SEASON_PATTERN.matcher(lineName);
        if (m.find()) {
            if (m.group(1) != null) return parsePositiveInt(m.group(1));
            if (m.group(2) != null) return parseChineseNumeral(m.group(2));
            if (m.group(3) != null) return parsePositiveInt(m.group(3));
        }
        return -1;
    }

    private static int firstPositive(int a, int b) {
        return a > 0 ? a : b;
    }

    private static int firstPositive(int a, int b, int c) {
        if (a > 0) return a;
        if (b > 0) return b;
        return c;
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
        String bmEp = bookmark.episode == null ? "" : bookmark.episode.trim();
        String bmEpKey = bookmarkEpisodeKey(bookmark);
        String bmEpMediaId = WatchHistory.sanitizeEpisodeMediaId(bookmark.episodeMediaId);
        if ((bmEpKey.isEmpty() && bmEpMediaId.isEmpty()) || line.episodes == null) {
            return false;
        }
        int lineSize = line.episodes.size();
        int bmEpNum = extractEpisodeNumber(bmEp);
        int bmSeason = extractSeasonNumber(bmEp);
        int bmPart = extractPartMarker(bmEp);
        boolean bmTrailer = isTrailerOrExtraName(bmEp);
        int lineSeason = extractExplicitLineSeasonNumber(line.name);
        for (Cms.Episode ep : line.episodes) {
            if (ep == null) continue;
            String candName = ep.name == null ? "" : ep.name.trim();
            int candNum = extractEpisodeNumber(candName);
            if (bmEpNum > 0 && candNum > 0 && candNum != bmEpNum) continue;
            int candSeason = firstPositive(extractSeasonNumber(candName), lineSeason);
            if (hasEpisodeIdentityConflictParsed(
                    bmEpNum,
                    bmSeason,
                    bmPart,
                    bmTrailer,
                    candName,
                    candNum,
                    candSeason,
                    lineSize)) {
                continue;
            }
            if (!bmEpKey.isEmpty() && bmEpKey.equals(stableEpisodeKey(ep.url))) {
                return true;
            }
            if (!bmEpMediaId.isEmpty()
                    && bmEpMediaId.equals(WatchHistory.windowsMediaIdentityForUrl(ep.url))) {
                return true;
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

    private static boolean hasEpisodeIdentityConflictParsed(
            int bmEpNum,
            int bmSeason,
            int bmPart,
            boolean bmTrailer,
            String candName,
            int candEpNum,
            int candEffSeason,
            int lineEpisodeCount) {
        if (bmEpNum > 0 && candEpNum > 0) {
            if (bmEpNum != candEpNum) return true;
            if (bmSeason > 0 && candEffSeason > 0 && bmSeason != candEffSeason) return true;
        } else if (bmSeason > 0 && candEffSeason > 0 && bmSeason != candEffSeason) {
            return true;
        }
        boolean candTrailer = isTrailerOrExtraName(candName);
        if (bmTrailer != candTrailer) return true;
        int candPart = extractPartMarker(candName);
        if (bmPart > 0 && candPart > 0 && bmPart != candPart) return true;
        if (bmPart != candPart && lineEpisodeCount > 1) return true;
        return false;
    }

    /**
     * Checks whether two non-empty episode titles are compatible enough to trust a fingerprint
     * match without cross-inheriting progress across distinct titled episodes (e.g. "返航" vs
     * "开端") on a multi-episode line if fingerprints ever collide.
     */
    private static boolean areTitlesCompatibleForEpKeyMatchParsed(
            String bmEp,
            String normBm,
            int bmNum,
            int bmSeason,
            int bmPart,
            boolean bmMovieLikeTitle,
            String candName,
            int candNum,
            int candEffSeason,
            int lineSize) {
        if (bmEp == null || bmEp.isEmpty() || candName == null || candName.isEmpty()) {
            return true;
        }
        if (bmEp.equalsIgnoreCase(candName)) return true;
        if (bmNum > 0 && candNum > 0) {
            if (bmNum != candNum) return false;
            return bmSeason <= 0 || candEffSeason <= 0 || bmSeason == candEffSeason;
        }
        if (lineSize == 1
                && bmMovieLikeTitle
                && looksLikeMovieEpisode(candName)
                && bmPart == extractPartMarker(candName)) {
            return true;
        }
        String normCand = normalizeTitle(candName);
        return !normBm.isEmpty()
                && !normCand.isEmpty()
                && (normBm.equals(normCand)
                        || normCand.contains(normBm)
                        || normBm.contains(normCand));
    }

    /**
     * Single-pass O(N) per-line summary for a bookmark. Eliminates O(N^2) line scans and repeated
     * SHA-256 hashing on long-running series (250/500/800+ episodes), while unifying episodeKey,
     * Windows episodeMediaId, exact title, and season+number disambiguation across Detail, History,
     * Fullscreen, Inline, and cross-source failover.
     */
    private static final class LineScan {
        final int lineSize;
        final int fallbackSeason;
        final int bmEpNum;
        final int bmSeason;
        final int bmPart;
        final boolean bmTrailer;
        final String bmEp;
        final String bmEpKey;
        final String bmEpMediaId;

        int confirmedEpKeyCount;
        int confirmedEpKeyIdx = -1;
        int confirmedEpMediaIdCount;
        int confirmedEpMediaIdIdx = -1;
        int exactNameCount;
        int exactNameNonConflictIdx = -1;
        int exactNameNonConflictCount;
        int compatibleNumCount;
        int compatibleNumIdx = -1;
        int exactSeasonNumCount;
        int exactSeasonNumIdx = -1;

        LineScan(
                Cms.Line line,
                int videoSeason,
                String bmEp,
                String bmEpKey,
                String bmEpMediaId,
                int bmEpNum,
                int bmSeason,
                int bmPart,
                boolean bmTrailer) {
            this.lineSize = line != null && line.episodes != null ? line.episodes.size() : 0;
            int lineSeason = line != null ? extractExplicitLineSeasonNumber(line.name) : -1;
            this.fallbackSeason = firstPositive(lineSeason, videoSeason);
            this.bmEp = bmEp == null ? "" : bmEp;
            this.bmEpKey = bmEpKey == null ? "" : bmEpKey;
            this.bmEpMediaId = bmEpMediaId == null ? "" : bmEpMediaId;
            this.bmEpNum = bmEpNum;
            this.bmSeason = bmSeason;
            this.bmPart = bmPart;
            this.bmTrailer = bmTrailer;
            if (lineSize == 0) return;

            final String normBm = this.bmEp.isEmpty() ? "" : normalizeTitle(this.bmEp);
            final boolean bmMovieTitle = looksLikeMovieEpisode(this.bmEp);
            final boolean checkEpKey = !this.bmEpKey.isEmpty();
            final boolean checkEpMid = !this.bmEpMediaId.isEmpty();
            final boolean checkExact = !this.bmEp.isEmpty();

            for (int i = 0; i < lineSize; i++) {
                Cms.Episode ep = line.episodes.get(i);
                if (ep == null) continue;
                String candName = ep.name == null ? "" : ep.name.trim();
                boolean exactMatch = checkExact && this.bmEp.equalsIgnoreCase(candName);
                if (exactMatch) {
                    exactNameCount++;
                }

                // Fast-path O(1) number rejection for 799/800 non-matching numbered episodes before
                // running trailer/part/season regexes or SHA-256 fingerprint hashing.
                int candNum = extractEpisodeNumber(candName);
                if (bmEpNum > 0 && candNum > 0 && candNum != bmEpNum) {
                    continue;
                }

                int candEpSeason = extractSeasonNumber(candName);
                int candEffSeason = firstPositive(candEpSeason, fallbackSeason);
                if (hasEpisodeIdentityConflictParsed(
                        bmEpNum,
                        bmSeason,
                        bmPart,
                        bmTrailer,
                        candName,
                        candNum,
                        candEffSeason,
                        lineSize)) {
                    continue;
                }

                if (exactMatch) {
                    exactNameNonConflictCount++;
                    exactNameNonConflictIdx = i;
                }

                if (bmEpNum > 0 && candNum == bmEpNum) {
                    compatibleNumCount++;
                    compatibleNumIdx = i;
                    if (bmSeason > 0 && candEffSeason == bmSeason) {
                        exactSeasonNumCount++;
                        exactSeasonNumIdx = i;
                    }
                }

                if ((checkEpKey || checkEpMid)
                        && areTitlesCompatibleForEpKeyMatchParsed(
                                this.bmEp,
                                normBm,
                                bmEpNum,
                                bmSeason,
                                bmPart,
                                bmMovieTitle,
                                candName,
                                candNum,
                                candEffSeason,
                                lineSize)) {
                    if (checkEpKey && this.bmEpKey.equals(stableEpisodeKey(ep.url))) {
                        confirmedEpKeyCount++;
                        confirmedEpKeyIdx = i;
                    }
                    if (checkEpMid
                            && this.bmEpMediaId.equals(
                                    WatchHistory.windowsMediaIdentityForUrl(ep.url))) {
                        confirmedEpMediaIdCount++;
                        confirmedEpMediaIdIdx = i;
                    }
                }
            }
        }

        boolean isUniqueConfirmedFingerprintAt(int idx) {
            return (confirmedEpKeyCount == 1 && confirmedEpKeyIdx == idx)
                    || (confirmedEpMediaIdCount == 1 && confirmedEpMediaIdIdx == idx);
        }

        boolean hasOtherConfirmedFingerprint(int idx) {
            boolean otherEpKey = confirmedEpKeyCount == 1 && confirmedEpKeyIdx != idx;
            boolean otherEpMid = confirmedEpMediaIdCount == 1 && confirmedEpMediaIdIdx != idx;
            return otherEpKey || otherEpMid;
        }

        boolean isUniqueExactNameAt(int idx, String candName) {
            return !bmEp.isEmpty()
                    && exactNameCount == 1
                    && exactNameNonConflictCount == 1
                    && exactNameNonConflictIdx == idx
                    && bmEp.equalsIgnoreCase(candName);
        }

        boolean isUniqueEpisodeNumberAt(int idx, int candNum, int candEffSeason) {
            if (bmEpNum <= 0 || candNum != bmEpNum) return false;
            if (bmSeason > 0 && exactSeasonNumCount > 0) {
                return exactSeasonNumCount == 1
                        && exactSeasonNumIdx == idx
                        && candEffSeason == bmSeason;
            }
            return compatibleNumCount == 1 && compatibleNumIdx == idx;
        }
    }

    private static int resolveTargetIndexInLine(Cms.Line line, Cms.Episode ep, int hintIdx) {
        if (line == null || line.episodes == null || ep == null) return -1;
        int n = line.episodes.size();
        if (hintIdx >= 0 && hintIdx < n && line.episodes.get(hintIdx) == ep) {
            return hintIdx;
        }
        return line.episodes.indexOf(ep);
    }

    static boolean matchesBookmarkSelection(
            Cms.Line line, Cms.Episode ep, int epIdx, WatchHistory.Entry bookmark) {
        if (line == null || ep == null || bookmark == null) return false;
        int lineStrength = lineMatchStrength(line, bookmark);
        if (lineStrength < 0) {
            return false;
        }
        int lineSize = line.episodes != null ? line.episodes.size() : 0;
        if (lineSize == 0) return false;
        int targetIdx = resolveTargetIndexInLine(line, ep, epIdx);
        if (targetIdx < 0) return false;

        String bmEp = bookmark.episode == null ? "" : bookmark.episode.trim();
        String candName = ep.name == null ? "" : ep.name.trim();
        int bmEpNum = extractEpisodeNumber(bmEp);
        int candEpNum = extractEpisodeNumber(candName);
        // Immediate O(1) rejection for mismatched episode numbers (critical for long series).
        if (bmEpNum > 0 && candEpNum > 0 && bmEpNum != candEpNum) {
            return false;
        }
        int bmSeason = extractSeasonNumber(bmEp);
        int lineSeason = extractExplicitLineSeasonNumber(line.name);
        int candEffSeason = firstPositive(extractSeasonNumber(candName), lineSeason);
        int bmPart = extractPartMarker(bmEp);
        boolean bmTrailer = isTrailerOrExtraName(bmEp);
        if (hasEpisodeIdentityConflictParsed(
                bmEpNum,
                bmSeason,
                bmPart,
                bmTrailer,
                candName,
                candEpNum,
                candEffSeason,
                lineSize)) {
            return false;
        }

        String bmEpKey = bookmarkEpisodeKey(bookmark);
        String bmEpMediaId = WatchHistory.sanitizeEpisodeMediaId(bookmark.episodeMediaId);
        LineScan scan =
                new LineScan(
                        line, -1, bmEp, bmEpKey, bmEpMediaId, bmEpNum, bmSeason, bmPart, bmTrailer);

        // 0. Unique confirmed fingerprint (Android episodeKey OR Windows episodeMediaId)
        if (scan.isUniqueConfirmedFingerprintAt(targetIdx)) {
            return true;
        }
        String bmLineId = bookmark.lineId == null ? "" : bookmark.lineId.trim();
        String bmLine = bookmark.line == null ? "" : bookmark.line.trim();
        String bmDrive = bookmarkDriveKey(bookmark);
        if ((!bmLineId.isEmpty() || !bmLine.isEmpty() || !bmDrive.isEmpty()) && lineStrength <= 0) {
            return false;
        }
        // Only block fallback when ANOTHER episode in the line is a VALID, CONFIRMED fingerprint
        // match (so re-indexed trailers where old ?id=2 moved to "第1集" do NOT block "第2集").
        if (scan.hasOtherConfirmedFingerprint(targetIdx)) {
            return false;
        }
        if (!bmEp.isEmpty() && !candName.isEmpty()) {
            // 1. Unique exact episode title match
            if (scan.isUniqueExactNameAt(targetIdx, candName)) {
                return true;
            }
            // 2. Unique compatible episode-number (and season) match
            if (scan.isUniqueEpisodeNumberAt(targetIdx, candEpNum, candEffSeason)) {
                return true;
            }
            if (bmEpNum > 0 || candEpNum > 0) {
                return false;
            }
            // 3. Single-item movie title match
            if (lineSize == 1
                    && looksLikeMovieEpisode(bmEp)
                    && looksLikeMovieEpisode(candName)
                    && bmPart == extractPartMarker(candName)) {
                return true;
            }
            return false;
        }
        // Without episode names/numbers, allow single-item same-line anonymous match only when
        // fingerprints do not contradict each other.
        String candEpKey = stableEpisodeKey(ep.url);
        if (!bmEpKey.isEmpty() && !candEpKey.isEmpty() && !bmEpKey.equals(candEpKey)) {
            return false;
        }
        String candMid = WatchHistory.windowsMediaIdentityForUrl(ep.url);
        if (!bmEpMediaId.isEmpty() && !candMid.isEmpty() && !bmEpMediaId.equals(candMid)) {
            return false;
        }
        return lineSize == 1 && targetIdx == 0 && bookmark.index == 0 && lineStrength > 0;
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
     * episode on the alternative source has confirmed unique identity with {@code bookmark}
     * (including explicit season confirmation whenever {@code bookmark} carries a season). Never
     * transfers progress onto a wrong season, season-unverifiable candidate, or ambiguous duplicate.
     */
    static int resolveFailoverResumePositionMs(EpisodeMatch match, WatchHistory.Entry bookmark) {
        if (match == null || match.line == null || match.episode == null || bookmark == null) {
            return 0;
        }
        int lineSize = match.line.episodes != null ? match.line.episodes.size() : 0;
        if (lineSize == 0) return 0;
        int targetIdx = resolveTargetIndexInLine(match.line, match.episode, -1);
        if (targetIdx < 0) return 0;

        String bmEp = bookmark.episode == null ? "" : bookmark.episode.trim();
        String candName = match.episode.name == null ? "" : match.episode.name.trim();
        int bmEpNum = extractEpisodeNumber(bmEp);
        int candEpNum = extractEpisodeNumber(candName);
        if (bmEpNum > 0 && candEpNum > 0 && bmEpNum != candEpNum) {
            return 0;
        }
        int bmSeason =
                firstPositive(extractSeasonNumber(bmEp), extractSeasonNumber(bookmark.title));
        int lineSeason = extractExplicitLineSeasonNumber(match.line.name);
        int candEffSeason =
                firstPositive(extractSeasonNumber(candName), lineSeason, match.videoSeason);
        int bmPart = extractPartMarker(bmEp);
        boolean bmTrailer = isTrailerOrExtraName(bmEp);
        if (hasEpisodeIdentityConflictParsed(
                bmEpNum,
                bmSeason,
                bmPart,
                bmTrailer,
                candName,
                candEpNum,
                candEffSeason,
                lineSize)) {
            return 0;
        }

        String bmEpKey = bookmarkEpisodeKey(bookmark);
        String bmEpMediaId = WatchHistory.sanitizeEpisodeMediaId(bookmark.episodeMediaId);
        LineScan scan =
                new LineScan(
                        match.line,
                        match.videoSeason,
                        bmEp,
                        bmEpKey,
                        bmEpMediaId,
                        bmEpNum,
                        bmSeason,
                        bmPart,
                        bmTrailer);

        if (scan.isUniqueConfirmedFingerprintAt(targetIdx)) {
            return bookmark.resume();
        }
        if (scan.hasOtherConfirmedFingerprint(targetIdx)) {
            return 0;
        }
        // On cross-source failover, if bookmark explicitly identifies a season (e.g. S02E02) and
        // the alternative candidate cannot confirm that season via episode, line, or video title,
        // NEVER auto-transfer the breakpoint.
        if (bmSeason > 0 && candEffSeason != bmSeason) {
            return 0;
        }
        if (!bmEp.isEmpty() && !candName.isEmpty()) {
            if (scan.isUniqueExactNameAt(targetIdx, candName)) {
                return bookmark.resume();
            }
            if (scan.isUniqueEpisodeNumberAt(targetIdx, candEpNum, candEffSeason)) {
                return bookmark.resume();
            }
            if (bmEpNum > 0 || candEpNum > 0) {
                return 0;
            }
            if (lineSize == 1
                    && looksLikeMovieEpisode(bmEp)
                    && looksLikeMovieEpisode(candName)
                    && bmPart == extractPartMarker(candName)) {
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
        String bmEpMediaId = WatchHistory.sanitizeEpisodeMediaId(bookmark.episodeMediaId);
        int bmEpNum = extractEpisodeNumber(bmEp);
        int bmSeason = extractSeasonNumber(bmEp);
        int bmPart = extractPartMarker(bmEp);
        boolean bmTrailer = isTrailerOrExtraName(bmEp);

        LineScan scan =
                new LineScan(
                        line, -1, bmEp, bmEpKey, bmEpMediaId, bmEpNum, bmSeason, bmPart, bmTrailer);

        if (scan.confirmedEpKeyCount == 1) return scan.confirmedEpKeyIdx;
        if (scan.confirmedEpMediaIdCount == 1) return scan.confirmedEpMediaIdIdx;
        if (!bmEp.isEmpty()) {
            if (scan.exactNameCount == 1 && scan.exactNameNonConflictCount == 1) {
                return scan.exactNameNonConflictIdx;
            }
            if (bmSeason > 0 && scan.exactSeasonNumCount == 1) {
                return scan.exactSeasonNumIdx;
            }
            if (scan.compatibleNumCount == 1) {
                return scan.compatibleNumIdx;
            }
        }
        if (bookmark.index >= 0 && bookmark.index < lineSize) {
            Cms.Episode atIdx = line.episodes.get(bookmark.index);
            if (atIdx != null) {
                String atName = atIdx.name == null ? "" : atIdx.name.trim();
                int atNum = extractEpisodeNumber(atName);
                int atSeason = firstPositive(extractSeasonNumber(atName), scan.fallbackSeason);
                if (!hasEpisodeIdentityConflictParsed(
                        bmEpNum, bmSeason, bmPart, bmTrailer, atName, atNum, atSeason, lineSize)) {
                    return bookmark.index;
                }
            }
        }
        return 0;
    }

    static EpisodeMatch matchEpisode(Cms.Video video, WatchHistory.Entry bookmark) {
        return matchEpisode(video, bookmark, false);
    }

    /**
     * Cross-source failover episode matcher: strictly confirms season + episode identity FIRST, and
     * applies same-drive preference ONLY as a secondary tie-breaker among equally confirmed
     * candidates. Rejects failover when bookmark has an explicit season and no alternative
     * candidate can confirm that season.
     */
    static EpisodeMatch matchEpisodeForFailover(Cms.Video video, WatchHistory.Entry bookmark) {
        return matchEpisode(video, bookmark, true);
    }

    static EpisodeMatch matchEpisode(
            Cms.Video video, WatchHistory.Entry bookmark, boolean crossSourceFailover) {
        if (video == null || video.lines == null || video.lines.isEmpty()) return null;
        String bmEp = bookmark == null || bookmark.episode == null ? "" : bookmark.episode.trim();
        String bmEpKey = bookmarkEpisodeKey(bookmark);
        String bmEpMediaId =
                bookmark == null
                        ? ""
                        : WatchHistory.sanitizeEpisodeMediaId(bookmark.episodeMediaId);
        int bmIndex = bookmark == null ? 0 : Math.max(0, bookmark.index);
        int bmEpNum = extractEpisodeNumber(bmEp);
        int bmSeason =
                crossSourceFailover && bookmark != null
                        ? firstPositive(
                                extractSeasonNumber(bmEp), extractSeasonNumber(bookmark.title))
                        : extractSeasonNumber(bmEp);
        int bmPart = extractPartMarker(bmEp);
        boolean bmTrailer = isTrailerOrExtraName(bmEp);
        boolean bmMovieLike = looksLikeMovieEpisode(bmEp) && bmPart == 0 && bmIndex == 0;
        int videoSeason = extractSeasonNumber(video.title);
        String bmDrive = bookmarkDriveKey(bookmark);

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
                // Secondary preference ONLY: identity tier gaps (>= 60) always outrank same-drive
                // preference (+20) so season+episode confirmation strictly precedes drive matching.
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

            // Single O(N) scan of this line (zero nested scans, zero redundant SHA-256 hashing).
            LineScan scan =
                    new LineScan(
                            line,
                            videoSeason,
                            bmEp,
                            bmEpKey,
                            bmEpMediaId,
                            bmEpNum,
                            bmSeason,
                            bmPart,
                            bmTrailer);

            // Evaluate only the exact candidate indices identified by the single O(N) pass (or
            // single-item movie fallback when lineCount == 1).
            int[] candidateIndices;
            if (lineCount == 1) {
                candidateIndices = new int[] {0};
            } else {
                int[] raw = new int[5];
                int nCand = 0;
                if (scan.confirmedEpKeyCount == 1) raw[nCand++] = scan.confirmedEpKeyIdx;
                if (scan.confirmedEpMediaIdCount == 1) raw[nCand++] = scan.confirmedEpMediaIdIdx;
                if (scan.exactNameCount == 1 && scan.exactNameNonConflictCount == 1) {
                    raw[nCand++] = scan.exactNameNonConflictIdx;
                }
                if (bmSeason > 0 && scan.exactSeasonNumCount == 1) {
                    raw[nCand++] = scan.exactSeasonNumIdx;
                }
                if (scan.compatibleNumCount == 1) {
                    raw[nCand++] = scan.compatibleNumIdx;
                }
                candidateIndices = new int[nCand];
                System.arraycopy(raw, 0, candidateIndices, 0, nCand);
            }

            for (int cPos = 0; cPos < candidateIndices.length; cPos++) {
                int i = candidateIndices[cPos];
                if (i < 0 || i >= lineCount) continue;
                boolean dupIdx = false;
                for (int prev = 0; prev < cPos; prev++) {
                    if (candidateIndices[prev] == i) {
                        dupIdx = true;
                        break;
                    }
                }
                if (dupIdx) continue;

                Cms.Episode ep = line.episodes.get(i);
                if (ep == null) continue;
                String candName = ep.name == null ? "" : ep.name.trim();
                int candNum = extractEpisodeNumber(candName);
                int candEffSeason =
                        firstPositive(extractSeasonNumber(candName), scan.fallbackSeason);
                boolean identityConflict =
                        hasEpisodeIdentityConflictParsed(
                                bmEpNum,
                                bmSeason,
                                bmPart,
                                bmTrailer,
                                candName,
                                candNum,
                                candEffSeason,
                                lineCount);
                if (identityConflict) continue;

                boolean candTrailer = isTrailerOrExtraName(candName);
                int candPart = extractPartMarker(candName);
                boolean hasOtherConfirmed = scan.hasOtherConfirmedFingerprint(i);
                boolean seasonRequiredAndMissing =
                        crossSourceFailover && bmSeason > 0 && candEffSeason != bmSeason;
                int score = -1;

                // Tier 0: Unique confirmed fingerprint (Android episodeKey OR Windows
                // episodeMediaId)
                if (!driveConflict && scan.isUniqueConfirmedFingerprintAt(i)) {
                    score = 400 + lineBonus + (bmIndex == i ? 10 : 0);
                } else if (!hasOtherConfirmed && !seasonRequiredAndMissing) {
                    if (scan.isUniqueExactNameAt(i, candName)) {
                        // Tier 1: Unique exact title match (+ season confirmation bonus)
                        int seasonTierBonus = (bmSeason > 0 && candEffSeason == bmSeason) ? 60 : 0;
                        score =
                                240
                                        + seasonTierBonus
                                        + lineBonus
                                        + (sameLine && bmIndex == i ? 10 : 0);
                    } else if (scan.isUniqueEpisodeNumberAt(i, candNum, candEffSeason)
                            && bmTrailer == candTrailer) {
                        // Tier 2: Unique episode-number (and season) match
                        int seasonTierBonus = (bmSeason > 0 && candEffSeason == bmSeason) ? 60 : 0;
                        score = 200 + seasonTierBonus + lineBonus;
                    } else if (lineCount == 1
                            && (bmMovieLike || bmEp.isEmpty())
                            && bmPart == candPart
                            && !candTrailer
                            && bmEpNum <= 0
                            && candNum <= 0) {
                        // Tier 3: Single-stream movie match across sources
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
                        // Tier 4: Single-item anonymous stream fallback on the same line only
                        score = 72 + lineBonus;
                    }
                }
                if (bmTrailer != candTrailer && score > 0) {
                    score -= 140;
                }

                if (score >= 40 && (best == null || score > best.score)) {
                    best = new EpisodeMatch(line, ep, score, videoSeason);
                }
            }
        }

        if (best != null) return best;

        // Final safe fallback ONLY for single-item movie entries when bookmark has no explicit
        // episode number, season, or split-part marker.
        if (bmIndex == 0 && bmEpNum <= 0 && bmSeason <= 0 && bmPart == 0 && !bmTrailer) {
            for (Cms.Line line : video.lines) {
                if (line != null && line.episodes != null && line.episodes.size() == 1) {
                    Cms.Episode only = line.episodes.get(0);
                    String onlyName = only == null || only.name == null ? "" : only.name.trim();
                    if (!isTrailerOrExtraName(onlyName)
                            && extractPartMarker(onlyName) == 0
                            && extractEpisodeNumber(onlyName) <= 0) {
                        return new EpisodeMatch(line, only, 42, videoSeason);
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

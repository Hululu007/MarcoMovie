// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Unified episode & series scraping engine for ALL Android TV media sources (subscription CMS,
 * CSP/JS/Python plugins, cloud drives, AList, Emby, and local USB hard drives).
 *
 * <p>Solves:
 *
 * <ul>
 *   <li>Misrecognized episode numbers caused by tech tags ({@code H.265}, {@code 1920x1080}, {@code
 *       60fps}, {@code DDP5.1}, {@code [1.8GB]}), trailing netdisk share folder annotations ({@code
 *       【后会油漆（4K）(1)】}), OS/netdisk duplicate copy markers ({@code (1)}), franchise numerals
 *       ({@code 斗罗大陆2}), or leading specials ({@code 第0集}, {@code 先导片}, {@code 预告}, {@code
 *       SP/OVA/PV}).
 *   <li>Variety shows and multi-cut lines ({@code 第X期}, air dates {@code 2026.10.22}, parts {@code
 *       上/中/下}, cuts {@code 沉浸版/加更/抢先版/纯享版/完整版/会员版/衍生/花絮}), preserving readable
 *       distinctions instead of collapsing every cut into identical {@code 第01集} badges.
 *   <li>Scrambled or lexicographically ordered episode lists ({@code 1, 10, 11, 2}) and
 *       multi-season flattened lines ({@code S01E01..S02E12}), while refusing to scramble uncertain
 *       or colliding lines and always disambiguating duplicate labels.
 *   <li>Mismatched Danmaku queries by supplying true scraped {@code (season, episodeNumber)},
 *       cleaned work titles, movie detection, work-form filtering, and user overrides.
 * </ul>
 */
final class TvSeriesScraper {

    enum WorkForm {
        REGULAR,
        MOTION_COMIC,
        AUDIO_BOOK,
        RECAP,
        GAME
    }

    static final class ScrapedEpisode {
        final int sourceIndex;
        final String rawName;
        final int season;
        final int episodeNumber;
        final int endEpisodeNumber;
        final boolean isSpecial;
        final String specialLabel;
        final String cleanDisplayLabel;
        final String episodeTitle;
        final boolean manualOverride;
        final boolean isVarietyPeriod;
        final String partTag;
        final String variantTag;
        final String dateKey;
        final String dateLabel;
        final String cleanedRawLabel;
        final String specSummary;

        ScrapedEpisode(
                int sourceIndex,
                String rawName,
                int season,
                int episodeNumber,
                int endEpisodeNumber,
                boolean isSpecial,
                String specialLabel,
                String cleanDisplayLabel,
                String episodeTitle,
                boolean manualOverride) {
            this(
                    sourceIndex,
                    rawName,
                    season,
                    episodeNumber,
                    endEpisodeNumber,
                    isSpecial,
                    specialLabel,
                    cleanDisplayLabel,
                    episodeTitle,
                    manualOverride,
                    false,
                    "",
                    "",
                    "",
                    "",
                    "");
        }

        ScrapedEpisode(
                int sourceIndex,
                String rawName,
                int season,
                int episodeNumber,
                int endEpisodeNumber,
                boolean isSpecial,
                String specialLabel,
                String cleanDisplayLabel,
                String episodeTitle,
                boolean manualOverride,
                boolean isVarietyPeriod,
                String partTag,
                String variantTag,
                String dateKey,
                String dateLabel,
                String cleanedRawLabel) {
            this(
                    sourceIndex,
                    rawName,
                    season,
                    episodeNumber,
                    endEpisodeNumber,
                    isSpecial,
                    specialLabel,
                    cleanDisplayLabel,
                    episodeTitle,
                    manualOverride,
                    isVarietyPeriod,
                    partTag,
                    variantTag,
                    dateKey,
                    dateLabel,
                    cleanedRawLabel,
                    extractEpisodeSpecSummary(rawName, "", ""));
        }

        ScrapedEpisode(
                int sourceIndex,
                String rawName,
                int season,
                int episodeNumber,
                int endEpisodeNumber,
                boolean isSpecial,
                String specialLabel,
                String cleanDisplayLabel,
                String episodeTitle,
                boolean manualOverride,
                boolean isVarietyPeriod,
                String partTag,
                String variantTag,
                String dateKey,
                String dateLabel,
                String cleanedRawLabel,
                String specSummary) {
            this.sourceIndex = sourceIndex;
            this.rawName = rawName == null ? "" : rawName;
            this.season = season;
            this.episodeNumber = episodeNumber;
            this.endEpisodeNumber = endEpisodeNumber;
            this.isSpecial = isSpecial;
            this.specialLabel = specialLabel == null ? "" : specialLabel;
            this.cleanDisplayLabel = cleanDisplayLabel == null ? "" : cleanDisplayLabel;
            this.episodeTitle = episodeTitle == null ? "" : episodeTitle;
            this.manualOverride = manualOverride;
            this.isVarietyPeriod = isVarietyPeriod;
            this.partTag = partTag == null ? "" : partTag;
            this.variantTag = variantTag == null ? "" : variantTag;
            this.dateKey = dateKey == null ? "" : dateKey;
            this.dateLabel = dateLabel == null ? "" : dateLabel;
            this.cleanedRawLabel = cleanedRawLabel == null ? "" : cleanedRawLabel;
            this.specSummary = specSummary == null ? "" : specSummary;
        }

        ScrapedEpisode withCleanDisplayLabel(String newLabel) {
            return new ScrapedEpisode(
                    sourceIndex,
                    rawName,
                    season,
                    episodeNumber,
                    endEpisodeNumber,
                    isSpecial,
                    specialLabel,
                    newLabel,
                    episodeTitle,
                    manualOverride,
                    isVarietyPeriod,
                    partTag,
                    variantTag,
                    dateKey,
                    dateLabel,
                    cleanedRawLabel,
                    specSummary);
        }

        String displayText() {
            if (!episodeTitle.isEmpty() && episodeNumber > 0 && !isSpecial) {
                return cleanDisplayLabel + " · " + episodeTitle;
            }
            return cleanDisplayLabel.isEmpty() ? rawName : cleanDisplayLabel;
        }
    }

    static final class ScrapedLine {
        final List<ScrapedEpisode> episodes;
        final boolean sourceOrderScrambled;
        final boolean multiSeason;
        final int regularCount;
        final int specialCount;
        final boolean isVarietyLine;
        final boolean preferRawNames;

        ScrapedLine(
                List<ScrapedEpisode> episodes,
                boolean sourceOrderScrambled,
                boolean multiSeason,
                int regularCount,
                int specialCount) {
            this(
                    episodes,
                    sourceOrderScrambled,
                    multiSeason,
                    regularCount,
                    specialCount,
                    false,
                    false);
        }

        ScrapedLine(
                List<ScrapedEpisode> episodes,
                boolean sourceOrderScrambled,
                boolean multiSeason,
                int regularCount,
                int specialCount,
                boolean isVarietyLine,
                boolean preferRawNames) {
            this.episodes = episodes;
            this.sourceOrderScrambled = sourceOrderScrambled;
            this.multiSeason = multiSeason;
            this.regularCount = regularCount;
            this.specialCount = specialCount;
            this.isVarietyLine = isVarietyLine;
            this.preferRawNames = preferRawNames;
        }

        ScrapedEpisode atSourceIndex(int sourceIndex) {
            if (sourceIndex < 0 || sourceIndex >= episodes.size()) return null;
            return episodes.get(sourceIndex);
        }

        /**
         * Returns non-mutating ordered source indices for UI rendering. Keeps raw array order when
         * {@code sortByScraped} is false, or sorts by {@code (isSpecial, season, episodeNumber,
         * variantRank, partRank, dateKey, sourceIndex)} when true.
         */
        List<Integer> orderedIndices(
                boolean sortByScraped, boolean hideSpecials, boolean descending) {
            List<ScrapedEpisode> filtered = new ArrayList<>(episodes.size());
            for (ScrapedEpisode ep : episodes) {
                if (hideSpecials && ep.isSpecial && regularCount > 0) continue;
                filtered.add(ep);
            }
            if (sortByScraped) {
                Collections.sort(
                        filtered,
                        new Comparator<ScrapedEpisode>() {
                            @Override
                            public int compare(ScrapedEpisode a, ScrapedEpisode b) {
                                int cmp = compareScrapedOrder(a, b);
                                if (cmp != 0) return cmp;
                                return Integer.compare(a.sourceIndex, b.sourceIndex);
                            }
                        });
            }
            if (descending) {
                Collections.reverse(filtered);
            }
            List<Integer> indices = new ArrayList<>(filtered.size());
            for (ScrapedEpisode ep : filtered) {
                indices.add(ep.sourceIndex);
            }
            return indices;
        }
    }

    private static final Pattern SEASON_EP_RANGE_PATTERN =
            Pattern.compile(
                    "(?i)(?:s|season\\s*)0*(\\d{1,2})\\s*[._\\-\\s]*e(?:p)?\\.?\\s*0*(\\d{1,4})(?:\\s*[-~～]\\s*e?(?:p)?\\.?\\s*0*(\\d{1,4}))?");
    private static final Pattern CN_ARABIC_EP_PATTERN =
            Pattern.compile("第\\s*0*(\\d{1,4})(?:\\s*[-~～]\\s*0*(\\d{1,4}))?\\s*([集话話回期篇章])");
    private static final Pattern CN_NUMERAL_EP_PATTERN =
            Pattern.compile("第\\s*([一二三四五六七八九十百千零〇两兩]{1,6})\\s*([集话話回期篇章])");
    private static final Pattern EP_ZERO_PATTERN =
            Pattern.compile("(?i)(?:第\\s*0+\\s*[集话話回期]|(?:^|[^a-z0-9])ep?\\.?\\s*0+(?:$|[^0-9]))");
    private static final Pattern SPECIAL_KEYWORD_PATTERN =
            Pattern.compile(
                    "(?i)(?:(?:^|[^a-z0-9])(?:sp|ova|oad|pv|cm|op|ed|ncop|nced|extra|bonus|trailer|teaser|preview|behind|making)(?:\\s*\\d{0,3})(?:$|[^a-z0-9])|预告|先导|花絮|番外|特别篇|特典|总集篇|总集|幕后|彩蛋|片花|精编|定档|终极预告|主题曲|片头曲|片尾曲|小剧场|抢先看)");
    private static final Pattern SPECIAL_CODE_PATTERN =
            Pattern.compile(
                    "(?i)(?:^|[^a-z0-9])(sp|ova|oad|pv|op|ed)\\s*0*(\\d{1,2})?(?:$|[^a-z0-9])");
    private static final Pattern SEASON_ONLY_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*0*(\\d{1,2})\\s*季|第\\s*([一二三四五六七八九十两兩]{1,3})\\s*季|season\\s*0*(\\d{1,2})|(?:^|[^a-z0-9])s0*(\\d{1,2})(?:$|[^a-z0-9]))");
    private static final Pattern EXPLICIT_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:^|[^a-z0-9])ep?\\.?\\s*0*(\\d{1,4})(?:\\s*[-~～]\\s*e?p?\\.?\\s*0*(\\d{1,4}))?(?:$|[^a-z0-9])");
    private static final Pattern ATTACHED_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:[\\u4e00-\\u9fff_\\-.\\s])ep?\\.?\\s*0*(\\d{1,4})(?:$|[^a-z0-9])");
    // Match [01] / 【01】 / (第01集) / (01集) / (01), while NEVER matching single-digit copy suffixes
    // like (1) / （2） used by Quark/Baidu/OS duplicate saves.
    private static final Pattern BRACKET_EP_PATTERN =
            Pattern.compile(
                    "(?:[\\[【]\\s*(?:第)?0*(\\d{1,4})(?:\\s*[集话話期完全])?\\s*[\\]】]|[(（]\\s*(?:第\\s*0*(\\d{1,4})(?:\\s*[集话話期])?|0*(\\d{1,4})\\s*[集话話期]|0(\\d{1,3}))\\s*[)）])");
    private static final Pattern VARIETY_DATE_PATTERN =
            Pattern.compile("(?:19|20)\\d{2}[.\\-/]?\\d{2}[.\\-/]?\\d{2}\\s*期?");
    private static final Pattern VARIETY_DATE_CAPTURE_PATTERN =
            Pattern.compile(
                    "(?<![0-9])((?:19|20)\\d{2})[.\\-/]?(0[1-9]|1[0-2])[.\\-/]?(0[1-9]|[12]\\d|3[01])(?![0-9])");
    private static final Pattern TRAILING_NETDISK_FOLDER_AFTER_EXT =
            Pattern.compile(
                    "(?i)(\\.(?:mkv|mp4|m4v|avi|mov|ts|m2ts|flv|rmvb|wmv|webm|mpg|mpeg|vob|iso|strm|m3u8))\\s*(?:【[^】]*】|\\[[^\\]]*\\])+$");
    private static final Pattern TRAILING_LENTICULAR_BLOCK =
            Pattern.compile("\\s*【[^】]{2,80}】\\s*$");
    private static final Pattern LEADING_SIZE_TAG_PATTERN =
            Pattern.compile(
                    "(?i)^\\s*[\\[【(（]\\s*\\d+(?:\\.\\d+)?\\s*(?:gb|mb|kb|gib|mib|g|m)\\s*[\\]】)）]\\s*");
    private static final Pattern TRAILING_COPY_COUNTER_PATTERN =
            Pattern.compile(
                    "\\s*[(（]\\s*[1-9]\\d?\\s*[)）]\\s*(?=(?:\\.[a-z0-9]{2,4})?$)",
                    Pattern.CASE_INSENSITIVE);
    private static final Pattern FILE_EXT_PATTERN =
            Pattern.compile(
                    "(?i)\\.(?:mkv|mp4|m4v|avi|mov|ts|m2ts|flv|rmvb|wmv|webm|mpg|mpeg|vob|iso|strm|m3u8|srt|ass|vtt)$");
    private static final Pattern PART_AFTER_EP_PATTERN =
            Pattern.compile(
                    "(?i)(?:第\\s*(?:\\d{1,4}|[一二三四五六七八九十百千零〇两兩]{1,6})\\s*[集话話回期篇章]|ep?\\.?\\s*\\d{1,4})\\s*[._\\-·(（\\[]*\\s*(上|中|下)(?:篇|集|期|部)?(?=$|[\\s._\\-·)）\\]]|4k|8k|2k|1080|2160|720|hdr|加更|沉浸|纯享|抢先|完整|会员|花絮|幕后|彩蛋|未播|衍生|\\.)");
    private static final Pattern TECH_NOISE_PATTERN =
            Pattern.compile(
                    "(?i)(?:\\d{3,4}\\s*[xX×]\\s*\\d{3,4}|(?:2160|1440|1080|720|576|480|360)[pi]|(?:2k|4k|8k)|(?:8|10|12)\\s*bit|(?:24|25|30|48|50|60|120)\\s*(?:fps|帧|hz)|hdr10\\+?|hdr|sdr|dovi(?:\\.p[578])?|dolby\\s*vision|hi10p?|bd(?:25|50|66|100)|avs[23]?|atmos|dts(?:-?hd)?|truehd|ddp\\s*5\\.?1|ddp\\s*2\\.?0|dd\\+?\\s*5\\.?1|aac\\s*2\\.?0|ac3|eac3|flac|opus|(?<![a-z0-9])(?:5\\.1|7\\.1|2\\.0)(?![a-z0-9])|h\\.?265|h\\.?264|x\\.?265|x\\.?264|hevc|avc|av1|vp9|web-?dl|webrip|bluray|blu-?ray|bdrip|remux|hq|uhd|fhd|hdrip|\\d+(?:\\.\\d+)?\\s*(?:gb|mb|kb|gib|mib|mbps|kbps)|(?:^|[^0-9])v[234](?:$|[^a-z0-9])|\\.(?:mkv|mp4|m4v|avi|mov|ts|m2ts|flv|rmvb|wmv|webm|mpg|mpeg|vob|iso|strm|m3u8|srt|ass|vtt))");
    private static final Pattern YEAR_PATTERN =
            Pattern.compile("(?<![0-9])(?:19[4-9]\\d|20[0-3]\\d)(?![0-9])");
    private static final Pattern BRACKET_YEAR_PATTERN =
            Pattern.compile("[\\[【(（]\\s*(?:19[4-9]\\d|20[0-3]\\d)\\s*[\\]】)）]");
    private static final Pattern DELIMITED_YEAR_PATTERN =
            Pattern.compile("(?<=[\\s._\\-])(?:19[4-9]\\d|20[0-3]\\d)(?=$|[\\s._\\-])");
    private static final Pattern LOOSE_NUMBER_PATTERN =
            Pattern.compile("(?<![0-9])0*(\\d{1,4})(?![0-9])");
    private static final Pattern TITLE_NOISE_TAGS =
            Pattern.compile(
                    "(?i)(?:[\\[【(（][^\\]】)）]*(?:4k|8k|2k|1080p|2160p|720p|hdr|杜比|高码|蓝光|原盘|国语|粤语|中字|双语|字幕|更新|全\\d+集|\\d+集全|共\\d+集|完结|连载|未删减|修正|高帧|60帧|120帧|hd|bd|tc|ts)[^\\]】)）]*[\\]】)）]|更新至?\\s*第?\\s*\\d+\\s*[集话期]?|连载至?\\s*\\d+|全\\s*\\d+\\s*[集话期]|\\d+\\s*[集话期]全|共\\s*\\d+\\s*[集话期]|第\\s*\\d+\\s*集(?:完)?|国语中字|粤语中字|中英双字|蓝光原盘|4k高码|高清修复版|未删减版|完整版|抢先版|hd中字)");
    private static final Pattern COMPACT_CLEAN_PATTERN =
            Pattern.compile("[\\s\\p{Punct}·•—–：:，,。！？!？【】\\[\\]()（）《》<>「」『』]+");

    private static final String[][] VARIANT_TAG_RULES = {
        {"沉浸版", "沉浸版"},
        {"沉浸", "沉浸版"},
        {"加更版", "加更"},
        {"加更", "加更"},
        {"抢先版", "抢先版"},
        {"抢先看", "抢先版"},
        {"超前营业", "超前营业"},
        {"超前企划", "超前企划"},
        {"超前看", "超前看"},
        {"纯享版", "纯享版"},
        {"纯享", "纯享版"},
        {"会员版", "会员版"},
        {"vip版", "会员版"},
        {"未播版", "未播"},
        {"未播", "未播"},
        {"衍生版", "衍生"},
        {"衍生", "衍生"},
        {"陪看版", "陪看"},
        {"陪看", "陪看"},
        {"直拍", "直拍"},
        {"reaction", "Reaction"},
        {"未删减", "未删减"},
        {"无删减", "无删减"},
        {"加长版", "加长版"},
        {"导演剪辑版", "导剪版"},
        {"导剪版", "导剪版"},
        {"完整版", "完整版"},
        {"精编版", "精编版"},
        {"精编", "精编版"},
        {"先导片", "先导片"},
        {"先导", "先导"},
        {"特别篇", "特别篇"},
        {"番外", "番外"},
        {"花絮", "花絮"},
        {"幕后", "幕后"},
        {"彩蛋", "彩蛋"},
        {"特辑", "特辑"},
        {"预告", "预告"}
    };

    private static final String[][] SPEC_DISAMBIG_RULES = {
        {"4k", "4K"},
        {"2160p", "4K"},
        {"1080p", "1080P"},
        {"720p", "720P"},
        {"杜比", "杜比"},
        {"dovi", "杜比"},
        {"hdr10+", "HDR10+"},
        {"hdr", "HDR"},
        {"60fps", "60帧"},
        {"60帧", "60帧"},
        {"高码", "高码"},
        {"国语", "国语"},
        {"粤语", "粤语"},
        {"原声", "原声"},
        {"双语", "双语"}
    };

    private TvSeriesScraper() {}

    static WorkForm detectWorkForm(String title) {
        if (title == null || title.trim().isEmpty()) return WorkForm.REGULAR;
        String lower = title.toLowerCase(Locale.ROOT);
        if (lower.contains("动态漫画") || lower.contains("动态漫") || lower.contains("有声漫画")) {
            return WorkForm.MOTION_COMIC;
        }
        if (lower.contains("有声书")
                || lower.contains("有声小说")
                || lower.contains("广播剧")
                || lower.contains("评书")) {
            return WorkForm.AUDIO_BOOK;
        }
        if (lower.contains("解说") || lower.contains("速看") || lower.contains("一口气看完")) {
            return WorkForm.RECAP;
        }
        if (lower.contains("游戏实况") || lower.contains("通关攻略") || lower.contains("全剧情流程")) {
            return WorkForm.GAME;
        }
        return WorkForm.REGULAR;
    }

    static String normalizeSequelNumerals(String raw) {
        if (raw == null) return "";
        return raw.replace("Ⅳ", "4").replace("Ⅲ", "3").replace("Ⅱ", "2").replace("Ⅰ", "1");
    }

    static String cleanWorkTitle(String raw) {
        if (raw == null) return "";
        String s = normalizeSequelNumerals(raw).replaceAll("[\\p{Cntrl}]+", " ").trim();
        s = TITLE_NOISE_TAGS.matcher(s).replaceAll(" ");
        s = BRACKET_YEAR_PATTERN.matcher(s).replaceAll(" ");
        String techTrimmed =
                TECH_NOISE_PATTERN
                        .matcher(s)
                        .replaceAll(" ")
                        .replaceAll("[._]+", " ")
                        .replaceAll("\\s+", " ")
                        .trim();
        if (!techTrimmed.isEmpty()) {
            s = techTrimmed;
        }
        // Only strip delimited release years (e.g. "三体 2023" / "三体.2023") while preserving
        // integral year titles such as "请回答1988" or "1923".
        String yearTrimmed =
                DELIMITED_YEAR_PATTERN.matcher(s).replaceAll(" ").replaceAll("\\s+", " ").trim();
        if (!yearTrimmed.isEmpty()) {
            s = yearTrimmed;
        }
        s = s.replaceAll("\\s*[\\[【(（]\\s*[\\]】)）]\\s*", " ");
        s = s.replaceAll("[._]+", " ");
        s = s.replaceAll("\\s+", " ").trim();
        if (s.isEmpty()) {
            return raw.replaceAll("[\\p{Cntrl}]+", " ").replaceAll("\\s+", " ").trim();
        }
        return s;
    }

    static String normalizeCoreKey(String raw) {
        String cleaned = cleanWorkTitle(raw);
        return COMPACT_CLEAN_PATTERN
                .matcher(cleaned)
                .replaceAll("")
                .toLowerCase(Locale.ROOT)
                .trim();
    }

    private static final Pattern EPISODE_FILE_SIZE_PATTERN =
            Pattern.compile(
                    "(?i)(?:^|[^a-z0-9])(\\d+(?:\\.\\d{1,2})?)\\s*(tb|tib|gb|gib|mb|mib)(?=$|[^a-z0-9])");
    private static final Pattern BRACKET_SHORT_SIZE_PATTERN =
            Pattern.compile("(?i)[\\[【(（]\\s*(\\d+(?:\\.\\d{1,2})?)\\s*(t|g|m)\\s*[\\]】)）]");
    private static final Pattern DECIMAL_SHORT_SIZE_PATTERN =
            Pattern.compile(
                    "(?i)(?<![0-9]\\.)(?<![a-z0-9])(\\d{1,4}\\.\\d{1,2})\\s*(t|g|m)(?![a-z0-9])");
    private static final Pattern DELIMITED_SHORT_SIZE_PATTERN =
            Pattern.compile(
                    "(?i)(?:[丨|/_\\-\\s]|^)(\\d{2,4})\\s*(m)(?=$|[^a-z0-9])|(?:[丨|])+\\s*(\\d{1,3})\\s*(g)(?=$|[^a-z0-9])");
    private static final Pattern URL_BYTE_PARAM_PATTERN =
            Pattern.compile(
                    "(?i)(?:[?&;\"'\\s]|^)(?:file_?size|fsize|size|bytes)\\s*[:=]\\s*(\\d{8,12})(?=$|[^0-9])");
    private static final Pattern SPIDER_EXT_SIZE_PATTERN =
            Pattern.compile(
                    "(?i)\\.(?:mkv|mp4|m4v|avi|mov|ts|m2ts|iso|flv|wmv|rmvb)[+|*#$]+(\\d{8,12})(?=$|[+|*#$&?])");
    private static final Pattern URL_SCHEME_HOST_PATTERN = Pattern.compile("(?i)^https?://[^/?#]+");
    private static final Pattern BARE_YEAR_OR_PUNCT_PATTERN =
            Pattern.compile("^(?:(?:19|20)\\d{2}|[0-9\\s._\\-·•&+|/]+)$");
    private static final Pattern SHORT_ASCII_RELEASE_TOKEN_PATTERN =
            Pattern.compile(
                    "(?i)(?:^|[\\s.·•])(?:yk|edr|dv|hfr|hq|bd|hd|uhd|fhd|sdr|hdr|hevc|avc|av1|x265|x264|h265|h264|ddp|dts|web|dl|aac|iso|rip|ver)(?=$|[\\s.·•])");
    private static final Pattern RELEASE_GROUP_SUFFIX_PATTERN =
            Pattern.compile("\\s*-\\s*[\\u4e00-\\u9fffA-Za-z0-9]{1,8}(?=$|\\s)");
    private static final Pattern STANDALONE_DV_PATTERN =
            Pattern.compile("(?i)(?:^|[^a-z0-9])dv(?:$|[^a-z0-9])");
    private static final Pattern STANDALONE_HQ_PATTERN =
            Pattern.compile("(?i)(?:^|[^a-z0-9])hq(?:$|[^a-z0-9])");
    private static final Pattern HIGH_FPS_PATTERN =
            Pattern.compile("(?i)(?:(?:60|120)\\s*(?:fps|帧)|(?:^|[^a-z0-9])hfr(?:$|[^a-z0-9]))");

    static String extractEpisodeSizeTag(String rawName) {
        return extractEpisodeSizeTag(rawName, "");
    }

    static String extractEpisodeSizeTag(String rawName, String epUrl) {
        String tag = extractHumanReadableSizeTag(rawName);
        if (!tag.isEmpty()) return tag;
        String urlSpec = extractUrlSpecText(epUrl);
        if (urlSpec.isEmpty()) return "";
        tag = extractHumanReadableSizeTag(urlSpec);
        if (!tag.isEmpty()) return tag;
        String rawBytes = matchByteSizeString(urlSpec);
        if (rawBytes.isEmpty()) {
            rawBytes = matchByteSizeString(epUrl);
        }
        return rawBytes.isEmpty() ? "" : formatByteSizeTag(rawBytes);
    }

    private static String extractHumanReadableSizeTag(String text) {
        if (text == null || text.trim().isEmpty()) return "";
        String num = "";
        String unit = "";
        Matcher m = EPISODE_FILE_SIZE_PATTERN.matcher(text);
        if (m.find()) {
            num = m.group(1);
            unit = m.group(2);
        } else {
            Matcher bm = BRACKET_SHORT_SIZE_PATTERN.matcher(text);
            if (bm.find()) {
                num = bm.group(1);
                unit = bm.group(2);
            } else {
                Matcher dm = DECIMAL_SHORT_SIZE_PATTERN.matcher(text);
                if (dm.find()) {
                    num = dm.group(1);
                    unit = dm.group(2);
                } else {
                    Matcher sm = DELIMITED_SHORT_SIZE_PATTERN.matcher(text);
                    while (sm.find()) {
                        String gNum = sm.group(1) != null ? sm.group(1) : sm.group(3);
                        String gUnit = sm.group(2) != null ? sm.group(2) : sm.group(4);
                        int val = parsePositiveInt(gNum);
                        if ("m".equalsIgnoreCase(gUnit) && val < 25) continue;
                        if ("g".equalsIgnoreCase(gUnit) && (val <= 0 || val > 500)) continue;
                        num = gNum;
                        unit = gUnit;
                        break;
                    }
                }
            }
        }
        if (num == null || num.isEmpty() || unit == null || unit.isEmpty()) return "";
        if (num.indexOf('.') >= 0) {
            num = num.replaceAll("0+$", "").replaceAll("\\.$", "");
        }
        String u = unit.toUpperCase(Locale.ROOT);
        if ("T".equals(u) || "TIB".equals(u)) u = "TB";
        else if ("G".equals(u) || "GIB".equals(u)) u = "GB";
        else if ("M".equals(u) || "MIB".equals(u)) u = "MB";
        return num + u;
    }

    private static String matchByteSizeString(String input) {
        if (input == null || input.isEmpty()) return "";
        Matcher pm = URL_BYTE_PARAM_PATTERN.matcher(input);
        if (pm.find()) return pm.group(1);
        Matcher em = SPIDER_EXT_SIZE_PATTERN.matcher(input);
        if (em.find()) return em.group(1);
        return "";
    }

    private static String formatByteSizeTag(String digits) {
        if (digits == null || digits.isEmpty()) return "";
        try {
            long bytes = Long.parseLong(digits);
            if (bytes < 20_000_000L || bytes > 250_000_000_000L) return "";
            double gb = bytes / (1024.0 * 1024.0 * 1024.0);
            if (gb >= 1.0) {
                String formatted = String.format(Locale.US, "%.1f", gb);
                formatted = formatted.replaceAll("0+$", "").replaceAll("\\.$", "");
                return formatted + "GB";
            }
            long mb = Math.round(bytes / (1024.0 * 1024.0));
            return mb >= 20 ? (mb + "MB") : "";
        } catch (NumberFormatException ignored) {
            return "";
        }
    }

    private static String extractUrlSpecText(String epUrl) {
        if (epUrl == null) return "";
        String trimmed = epUrl.trim();
        if (trimmed.isEmpty()) return "";
        String withoutHost = URL_SCHEME_HOST_PATTERN.matcher(trimmed).replaceFirst("");
        String decoded = MediaBadges.percentDecodeUtf8PreservePlus(withoutHost);
        return decoded == null ? "" : decoded.trim();
    }

    static String extractEpisodeSpecSummary(String rawName) {
        return extractEpisodeSpecSummary(rawName, "", "");
    }

    static String extractEpisodeSpecSummary(String rawName, String epUrl, String lineName) {
        String safeRaw = rawName == null ? "" : rawName;
        String urlSpec = extractUrlSpecText(epUrl);
        if (safeRaw.trim().isEmpty() && urlSpec.isEmpty()) return "";
        String core = safeRaw.isEmpty() ? "" : stripTrailingNetdiskSuffix(safeRaw, "");
        String probe = core.isEmpty() ? safeRaw : core;
        String combinedProbe = urlSpec.isEmpty() ? probe : (probe + " " + urlSpec);
        String combinedRaw = urlSpec.isEmpty() ? safeRaw : (safeRaw + " " + urlSpec);

        String resolution = detectResolutionTag(combinedProbe);
        if (resolution.isEmpty() && !combinedRaw.equals(combinedProbe)) {
            resolution = detectResolutionTag(combinedRaw);
        }

        List<String> tags = new ArrayList<>();
        String hdrLower = combinedProbe.toLowerCase(Locale.ROOT);
        if (hdrLower.contains("杜比")
                || hdrLower.contains("dovi")
                || hdrLower.contains("dolby")
                || hdrLower.contains("atmos")
                || STANDALONE_DV_PATTERN.matcher(combinedProbe).find()) {
            tags.add("杜比");
        } else if (safeRaw.contains("杜比")) {
            tags.add("杜比");
        }
        if (hdrLower.contains("hdr10+")) {
            tags.add("HDR10+");
        } else if (hdrLower.contains("hdr") || combinedProbe.contains("臻彩")) {
            tags.add("HDR");
        }
        if (hdrLower.contains("remux")
                || hdrLower.contains("bluray")
                || hdrLower.contains("blu-ray")
                || hdrLower.contains("bdrip")
                || hdrLower.contains("原盘")
                || hdrLower.contains("bd25")
                || hdrLower.contains("bd50")
                || hdrLower.contains("bd66")
                || hdrLower.contains("bd100")
                || hdrLower.endsWith(".iso")) {
            tags.add("原盘");
        }
        if (combinedProbe.contains("高码") || STANDALONE_HQ_PATTERN.matcher(combinedProbe).find()) {
            tags.add("高码");
        }
        if (HIGH_FPS_PATTERN.matcher(combinedProbe).find()) {
            tags.add("60帧");
        }
        if (hdrLower.contains("atmos") || combinedProbe.contains("全景声")) {
            tags.add("全景声");
        } else if (hdrLower.contains("truehd")) {
            tags.add("TrueHD");
        } else if (hdrLower.contains("ddp")
                || hdrLower.contains("dd+")
                || hdrLower.contains("eac3")
                || hdrLower.contains("e-ac-3")) {
            tags.add("DD+");
        } else if (hdrLower.contains("dts")) {
            tags.add("DTS");
        }

        String sizeTag = extractEpisodeSizeTag(safeRaw, epUrl);
        if (resolution.isEmpty()
                && lineName != null
                && !lineName.trim().isEmpty()
                && (!sizeTag.isEmpty()
                        || !tags.isEmpty()
                        || looksLikeNoisyResourceLabel(safeRaw)
                        || !urlSpec.isEmpty())) {
            resolution = detectResolutionTag(lineName);
        }

        List<String> summary = new ArrayList<>(5);
        if (!resolution.isEmpty()) summary.add(resolution);
        for (int i = 0; i < tags.size() && summary.size() < 4; i++) {
            String t = tags.get(i);
            if (!summary.contains(t)) {
                summary.add(t);
            }
        }
        if (!sizeTag.isEmpty()) {
            summary.add(sizeTag);
        }
        if (summary.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < summary.size(); i++) {
            if (i > 0) sb.append(" · ");
            sb.append(summary.get(i));
        }
        return sb.toString();
    }

    private static String detectResolutionTag(String text) {
        if (text == null || text.isEmpty()) return "";
        String lower = text.toLowerCase(Locale.ROOT);
        if (lower.contains("8k") || lower.contains("4320p") || lower.contains("7680x")) {
            return "8K";
        }
        if (lower.contains("4k")
                || lower.contains("2160p")
                || lower.contains("uhd")
                || lower.contains("3840x")) {
            return "4K";
        }
        if (lower.contains("2k") || lower.contains("1440p") || lower.contains("2560x")) {
            return "2K";
        }
        if (lower.contains("1080p")
                || lower.contains("1080i")
                || lower.contains("1920x")
                || lower.contains("fhd")) {
            return "1080P";
        }
        if (lower.contains("720p") || lower.contains("1280x")) {
            return "720P";
        }
        return "";
    }

    private static boolean looksLikeNoisyResourceLabel(String rawName) {
        if (rawName == null) return false;
        return rawName.contains("..")
                || rawName.contains("【")
                || TECH_NOISE_PATTERN.matcher(rawName).find();
    }

    private static String extractTrailingBalancedLenticular(String s) {
        if (s == null) return "";
        String trimmed = s.trim();
        if (!trimmed.endsWith("】")) return "";
        int depth = 0;
        int start = -1;
        for (int i = trimmed.length() - 1; i >= 0; i--) {
            char c = trimmed.charAt(i);
            if (c == '】') {
                depth++;
            } else if (c == '【') {
                depth--;
                if (depth == 0) {
                    start = i;
                    break;
                }
            }
        }
        if (start <= 0) return "";
        int len = trimmed.length() - start;
        return (len >= 2 && len <= 140) ? trimmed.substring(start) : "";
    }

    /**
     * Strips trailing cloud-drive share folder tags (such as {@code 【后会油漆（4K）(1)】} appended after
     * {@code .mkv}) and constant line-wide folder suffixes before parsing episode tokens.
     */
    static String stripTrailingNetdiskSuffix(String raw, String commonTrailingBlock) {
        if (raw == null) return "";
        String s = raw.trim();
        if (commonTrailingBlock != null
                && !commonTrailingBlock.isEmpty()
                && s.endsWith(commonTrailingBlock)
                && s.length() > commonTrailingBlock.length()) {
            s = s.substring(0, s.length() - commonTrailingBlock.length()).trim();
        }
        String balanced = extractTrailingBalancedLenticular(s);
        if (!balanced.isEmpty() && (balanced.contains("/") || balanced.indexOf('【', 1) > 0)) {
            String without = s.substring(0, s.length() - balanced.length()).trim();
            if (!without.isEmpty()) s = without;
        }
        s = TRAILING_NETDISK_FOLDER_AFTER_EXT.matcher(s).replaceFirst("$1").trim();
        return s;
    }

    private static String detectCommonTrailingFolderBlock(List<Cms.Episode> episodes) {
        if (episodes == null || episodes.size() < 2) return "";
        Map<String, Integer> counts = new HashMap<>();
        int nonEmpty = 0;
        for (Cms.Episode ep : episodes) {
            if (ep == null || ep.name == null || ep.name.trim().isEmpty()) continue;
            nonEmpty++;
            String nameTrim = ep.name.trim();
            String block = extractTrailingBalancedLenticular(nameTrim);
            if (block.isEmpty()) {
                Matcher m = TRAILING_LENTICULAR_BLOCK.matcher(nameTrim);
                if (m.find()) block = m.group().trim();
            }
            if (!block.isEmpty()) {
                Integer prev = counts.get(block);
                counts.put(block, prev == null ? 1 : prev + 1);
            }
        }
        if (nonEmpty < 2) return "";
        int threshold = (int) Math.ceil(nonEmpty * 0.60);
        String best = "";
        int bestCount = 0;
        for (Map.Entry<String, Integer> entry : counts.entrySet()) {
            if (entry.getValue() >= threshold && entry.getValue() > bestCount) {
                bestCount = entry.getValue();
                best = entry.getKey();
            }
        }
        return best;
    }

    private static String stripCopySuffixIfOtherNumberPresent(String s) {
        if (s == null || s.isEmpty()) return "";
        Matcher m = TRAILING_COPY_COUNTER_PATTERN.matcher(s);
        if (!m.find()) return s;
        String without = m.replaceFirst("").trim();
        if (without.isEmpty()) return s;
        // Only strip trailing "(1)" when there is another episode/date/number token remaining.
        String probe = stripTechNoise(without);
        if (SEASON_EP_RANGE_PATTERN.matcher(without).find()
                || CN_ARABIC_EP_PATTERN.matcher(without).find()
                || CN_NUMERAL_EP_PATTERN.matcher(without).find()
                || EXPLICIT_EP_PATTERN.matcher(probe).find()
                || ATTACHED_EP_PATTERN.matcher(probe).find()
                || VARIETY_DATE_CAPTURE_PATTERN.matcher(without).find()
                || LOOSE_NUMBER_PATTERN
                        .matcher(VARIETY_DATE_PATTERN.matcher(probe).replaceAll(" "))
                        .find()) {
            return without;
        }
        return s;
    }

    /**
     * Produces a clean, human-readable filename label stripped of size prefixes ({@code [4.7GB]}),
     * file extensions ({@code .mkv}), netdisk share folder suffixes ({@code 【...】}), and trailing
     * resolution clutter. Used both for variety/dated fallback and for user raw-name display mode.
     */
    static String cleanReadableEpisodeName(String raw, String commonTrailingBlock) {
        if (raw == null) return "";
        String s = stripTrailingNetdiskSuffix(raw, commonTrailingBlock);
        s = LEADING_SIZE_TAG_PATTERN.matcher(s).replaceFirst("");
        s = FILE_EXT_PATTERN.matcher(s).replaceFirst("");
        s = stripCopySuffixIfOtherNumberPresent(s);
        s = TECH_NOISE_PATTERN.matcher(s).replaceAll(" ");
        s = s.replaceAll("[\\[【(（]\\s*[\\]】)）]", " ");
        s = s.replaceAll("[_]+", " ");
        s = s.replaceAll("(?:\\s*[.·•]+\\s*){2,}", " · ");
        s = s.replaceAll("\\s*\\.\\s*", " ");
        s = s.replaceAll("\\s*&\\s*", " ");
        s = s.replaceAll("\\s*-\\s*(?=-|$)", " ");
        s = s.replaceAll("^\\s*[-·._]+\\s*|\\s*[-·._]+\\s*$", "");
        s = s.replaceAll("\\s+", " ").trim();
        return s.isEmpty() ? raw.trim() : s;
    }

    private static String[] extractDateInfo(String core) {
        if (core == null || core.isEmpty()) return null;
        Matcher m = VARIETY_DATE_CAPTURE_PATTERN.matcher(core);
        if (!m.find()) return null;
        String y = m.group(1);
        String mo = m.group(2);
        String d = m.group(3);
        return new String[] {y + mo + d, y, mo + "." + d};
    }

    private static String extractPartTag(String core) {
        if (core == null || core.isEmpty()) return "";
        Matcher m = PART_AFTER_EP_PATTERN.matcher(core);
        if (m.find()) {
            return m.group(1);
        }
        return "";
    }

    private static String extractVariantTag(String core) {
        if (core == null || core.isEmpty()) return "";
        String lower = core.toLowerCase(Locale.ROOT);
        for (String[] rule : VARIANT_TAG_RULES) {
            if (lower.contains(rule[0])) {
                return rule[1];
            }
        }
        return "";
    }

    private static boolean hasExplicitPeriodToken(String core) {
        if (core == null || core.isEmpty()) return false;
        Matcher a = CN_ARABIC_EP_PATTERN.matcher(core);
        if (a.find() && "期".equals(a.group(3))) return true;
        Matcher n = CN_NUMERAL_EP_PATTERN.matcher(core);
        return n.find() && "期".equals(n.group(2));
    }

    private static int variantSortRank(String variantTag) {
        if (variantTag == null || variantTag.isEmpty()) return 0;
        switch (variantTag) {
            case "完整版":
            case "未删减":
            case "无删减":
            case "加长版":
            case "导剪版":
                return 1;
            case "沉浸版":
            case "纯享版":
                return 2;
            case "加更":
            case "会员版":
                return 3;
            case "抢先版":
            case "超前营业":
            case "超前企划":
            case "超前看":
                return 4;
            case "未播":
            case "衍生":
            case "陪看":
            case "直拍":
            case "Reaction":
            case "精编版":
                return 5;
            case "先导片":
            case "先导":
            case "特别篇":
            case "番外":
            case "特辑":
                return 6;
            case "花絮":
            case "幕后":
            case "彩蛋":
            case "预告":
                return 7;
            default:
                return 8;
        }
    }

    private static int partSortRank(String partTag) {
        if ("上".equals(partTag)) return 1;
        if ("中".equals(partTag)) return 2;
        if ("下".equals(partTag)) return 3;
        return 0;
    }

    private static int compareScrapedOrder(ScrapedEpisode a, ScrapedEpisode b) {
        if (a.isSpecial != b.isSpecial) {
            return a.isSpecial ? 1 : -1;
        }
        int sa = a.season > 0 ? a.season : 1;
        int sb = b.season > 0 ? b.season : 1;
        if (sa != sb) return Integer.compare(sa, sb);
        boolean aHas = a.episodeNumber > 0;
        boolean bHas = b.episodeNumber > 0;
        if (aHas && bHas) {
            if (a.episodeNumber != b.episodeNumber) {
                return Integer.compare(a.episodeNumber, b.episodeNumber);
            }
            int va = variantSortRank(a.variantTag);
            int vb = variantSortRank(b.variantTag);
            if (va != vb) return Integer.compare(va, vb);
            int pa = partSortRank(a.partTag);
            int pb = partSortRank(b.partTag);
            if (pa != pb) return Integer.compare(pa, pb);
            if (!a.dateKey.isEmpty() && !b.dateKey.isEmpty()) {
                int dc = a.dateKey.compareTo(b.dateKey);
                if (dc != 0) return dc;
            }
            return 0;
        }
        if (aHas != bHas) return aHas ? -1 : 1;
        if (!a.dateKey.isEmpty() && !b.dateKey.isEmpty()) {
            int dc = a.dateKey.compareTo(b.dateKey);
            if (dc != 0) return dc;
            int va = variantSortRank(a.variantTag);
            int vb = variantSortRank(b.variantTag);
            if (va != vb) return Integer.compare(va, vb);
        }
        return 0;
    }

    static int extractSeasonNumber(String text) {
        if (text == null || text.trim().isEmpty()) return -1;
        String norm = normalizeSequelNumerals(stripTrailingNetdiskSuffix(text, ""));
        Matcher se = SEASON_EP_RANGE_PATTERN.matcher(norm);
        if (se.find()) {
            return parsePositiveInt(se.group(1));
        }
        Matcher m = SEASON_ONLY_PATTERN.matcher(norm);
        if (m.find()) {
            if (m.group(1) != null) return parsePositiveInt(m.group(1));
            if (m.group(2) != null) return parseChineseNumeral(m.group(2));
            if (m.group(3) != null) return parsePositiveInt(m.group(3));
            if (m.group(4) != null) return parsePositiveInt(m.group(4));
        }
        return -1;
    }

    static boolean isSpecialEpisode(String raw) {
        if (raw == null || raw.trim().isEmpty()) return false;
        String s = stripTrailingNetdiskSuffix(raw, "");
        if (EP_ZERO_PATTERN.matcher(s).find()) return true;
        // Variety entries tied to an explicit 期 (e.g. "抢先版第一期", "第一期花絮") keep their period
        // identity with a variant tag rather than being stripped to anonymous specials.
        if (hasExplicitPeriodToken(s)) {
            return false;
        }
        // If string contains explicit SxxExx with positive episode, treat as regular unless clearly
        // trailer/PV
        if (SEASON_EP_RANGE_PATTERN.matcher(s).find()) {
            Matcher se = SEASON_EP_RANGE_PATTERN.matcher(s);
            if (se.find()) {
                int sNum = parsePositiveInt(se.group(1));
                int eNum = parsePositiveInt(se.group(2));
                if (sNum == 0 || eNum == 0) return true;
            }
        }
        return SPECIAL_KEYWORD_PATTERN.matcher(s).find();
    }

    static String extractSpecialLabel(String raw) {
        if (raw == null) return "特辑";
        String s = stripTrailingNetdiskSuffix(raw, "");
        if (EP_ZERO_PATTERN.matcher(s).find()) return "第0集";
        Matcher code = SPECIAL_CODE_PATTERN.matcher(s);
        if (code.find()) {
            String tag = code.group(1).toUpperCase(Locale.ROOT);
            String num = code.group(2);
            if (num != null && !num.isEmpty()) {
                int v = parsePositiveInt(num);
                return v > 0 ? (tag + (v < 10 ? "0" + v : String.valueOf(v))) : tag;
            }
            return tag;
        }
        if (s.contains("先导")) return "先导片";
        if (s.contains("预告")) return "预告";
        if (s.contains("花絮")) return "花絮";
        if (s.contains("番外")) return "番外";
        if (s.contains("特别篇")) return "特别篇";
        if (s.contains("总集")) return "总集篇";
        if (s.contains("彩蛋")) return "彩蛋";
        return "特辑";
    }

    /**
     * Strips technical metadata, file extensions, resolution dimensions, years, and season tags so
     * loose number matching never mistakes {@code H.265}, {@code 60fps}, {@code 1920x1080}, {@code
     * 5.1}, {@code 2026}, or {@code S02} for an episode number.
     */
    static String stripTechNoise(String raw) {
        if (raw == null) return "";
        String s = TECH_NOISE_PATTERN.matcher(raw).replaceAll(" ");
        s = YEAR_PATTERN.matcher(s).replaceAll(" ");
        s = SEASON_ONLY_PATTERN.matcher(s).replaceAll(" ");
        return s;
    }

    /** Single-name episode number extraction (used by HistoryResumeMatcher & single-item callers). */
    static int extractEpisodeNumber(String rawName) {
        return extractEpisodeNumber(rawName, null);
    }

    static int extractEpisodeNumber(String rawName, Set<Integer> constantNumbers) {
        if (rawName == null) return -1;
        String trimmed = stripTrailingNetdiskSuffix(rawName, "");
        if (trimmed.isEmpty()) return -1;
        trimmed = stripCopySuffixIfOtherNumberPresent(trimmed);
        if (isSpecialEpisode(trimmed)) return -1;

        Matcher se = SEASON_EP_RANGE_PATTERN.matcher(trimmed);
        if (se.find()) {
            int ep = parsePositiveInt(se.group(2));
            if (ep > 0) return ep;
        }

        Matcher cnAr = CN_ARABIC_EP_PATTERN.matcher(trimmed);
        if (cnAr.find()) {
            int ep = parsePositiveInt(cnAr.group(1));
            if (ep > 0) return ep;
        }

        Matcher cnNum = CN_NUMERAL_EP_PATTERN.matcher(trimmed);
        if (cnNum.find()) {
            int ep = parseChineseNumeral(cnNum.group(1));
            if (ep > 0) return ep;
        }

        String stripped = stripTechNoise(trimmed);

        Matcher exp = EXPLICIT_EP_PATTERN.matcher(stripped);
        if (exp.find()) {
            int ep = parsePositiveInt(exp.group(1));
            if (ep > 0) return ep;
        }

        Matcher att = ATTACHED_EP_PATTERN.matcher(stripped);
        if (att.find()) {
            int ep = parsePositiveInt(att.group(1));
            if (ep > 0) return ep;
        }

        Matcher br = BRACKET_EP_PATTERN.matcher(stripped);
        if (br.find()) {
            String digits =
                    br.group(1) != null
                            ? br.group(1)
                            : (br.group(2) != null
                                    ? br.group(2)
                                    : (br.group(3) != null ? br.group(3) : br.group(4)));
            int ep = parsePositiveInt(digits);
            if (ep > 0 && ep <= 2000) {
                return ep;
            }
        }

        // Strip variety date tokens like 20260315 or 2026.10.22 so date digits aren't matched as
        // episodes.
        String noDate = VARIETY_DATE_PATTERN.matcher(stripped).replaceAll(" ");
        Matcher loose = LOOSE_NUMBER_PATTERN.matcher(noDate);
        List<Integer> nums = new ArrayList<>();
        while (loose.find()) {
            int val = parsePositiveInt(loose.group(1));
            if (val > 0 && val <= 2000) {
                nums.add(val);
            }
        }
        if (nums.isEmpty()) return -1;
        if (nums.size() == 1) {
            int only = nums.get(0);
            if (constantNumbers != null && constantNumbers.contains(only)) {
                // Keep bare numeric labels like "02" or "2", suppress title-only strings like
                // "斗罗大陆2".
                boolean hasWordChars =
                        noDate.replaceAll("[0-9\\s\\p{Punct}_\\-]+", "").length() > 0;
                if (hasWordChars) return -1;
            }
            return only;
        }
        // Multiple numbers in the same episode name (e.g. "斗罗大陆2_02" -> [2, 2], "斗罗大陆2_01" -> [2,
        // 1]).
        // Suppress at most ONE (leftmost) occurrence of each franchise/constant number so Episode 2
        // of
        // a sequel show ("斗罗大陆2_02") preserves its second "2" as the real episode number.
        Set<Integer> consumedConstants = new HashSet<>();
        int found = -1;
        for (int val : nums) {
            if (constantNumbers != null
                    && constantNumbers.contains(val)
                    && !consumedConstants.contains(val)) {
                consumedConstants.add(val);
                continue;
            }
            found = val;
        }
        return found;
    }

    /**
     * Scrapes an entire line with cross-episode constant-number suppression (e.g. franchise numeral
     * {@code 2} in {@code 斗罗大陆2_01.mkv} .. {@code 斗罗大陆2_26.mkv}), netdisk folder/copy-marker
     * stripping, variety-show period/part/variant/date preservation, special isolation, season
     * extraction, duplicate-label disambiguation, scrambled-order detection, and user override
     * application.
     */
    static ScrapedLine scrapeLine(
            String seriesTitle,
            List<Cms.Episode> episodes,
            SeriesScrapeStore.OverrideRecord override) {
        return scrapeLine(seriesTitle, "", episodes, override);
    }

    static ScrapedLine scrapeLine(
            String seriesTitle,
            String lineName,
            List<Cms.Episode> episodes,
            SeriesScrapeStore.OverrideRecord override) {
        if (episodes == null || episodes.isEmpty()) {
            return new ScrapedLine(
                    Collections.<ScrapedEpisode>emptyList(), false, false, 0, 0, false, false);
        }

        String commonTrailingBlock = detectCommonTrailingFolderBlock(episodes);
        Set<Integer> constantNumbers =
                computeConstantNumbers(seriesTitle, episodes, commonTrailingBlock);
        int seriesSeason = extractSeasonNumber(seriesTitle);
        int offset = override != null ? override.episodeOffset : 0;
        boolean preferRawNames = override != null && override.preferRawEpisodeNames;

        List<ScrapedEpisode> out = new ArrayList<>(episodes.size());
        Set<Integer> distinctSeasons = new HashSet<>();
        Set<String> distinctDateYears = new HashSet<>();
        int regularCount = 0;
        int specialCount = 0;
        int varietyTokenCount = 0;
        int datedCount = 0;
        int nonEmptyCount = 0;

        for (int i = 0; i < episodes.size(); i++) {
            Cms.Episode ep = episodes.get(i);
            String raw = ep != null && ep.name != null ? ep.name.trim() : "";
            String rawUrl = ep != null && ep.url != null ? ep.url.trim() : "";
            String specSummary = extractEpisodeSpecSummary(raw, rawUrl, lineName);
            if (!raw.isEmpty()) nonEmptyCount++;
            String core =
                    stripCopySuffixIfOtherNumberPresent(
                            stripTrailingNetdiskSuffix(raw, commonTrailingBlock));
            String readableRaw = cleanReadableEpisodeName(raw, commonTrailingBlock);
            String[] dateInfo = extractDateInfo(core);
            String dateKey = dateInfo != null ? dateInfo[0] : "";
            String dateYear = dateInfo != null ? dateInfo[1] : "";
            String dateShort = dateInfo != null ? dateInfo[2] : "";
            if (!dateKey.isEmpty()) {
                datedCount++;
                distinctDateYears.add(dateYear);
            }
            String partTag = extractPartTag(core);
            String variantTag = extractVariantTag(core);

            Integer manualEp =
                    override != null && override.episodeNumberOverrides != null
                            ? override.episodeNumberOverrides.get(i)
                            : null;
            if (manualEp != null && manualEp > 0) {
                int season = extractSeasonNumber(core);
                if (season <= 0) season = seriesSeason;
                if (season > 0) distinctSeasons.add(season);
                boolean periodUnit = hasExplicitPeriodToken(core);
                if (periodUnit) varietyTokenCount++;
                String officialTitle = lookupOfficialEpTitle(override, manualEp);
                regularCount++;
                out.add(
                        new ScrapedEpisode(
                                i,
                                raw,
                                season,
                                manualEp,
                                -1,
                                false,
                                "",
                                formatEpisodeBadge(
                                        season,
                                        manualEp,
                                        -1,
                                        false,
                                        periodUnit,
                                        partTag,
                                        variantTag),
                                officialTitle,
                                true,
                                periodUnit,
                                partTag,
                                variantTag,
                                dateKey,
                                dateShort,
                                readableRaw,
                                specSummary));
                continue;
            }

            boolean special = isSpecialEpisode(core);
            if (special) {
                specialCount++;
                String spLabel = extractSpecialLabel(core);
                out.add(
                        new ScrapedEpisode(
                                i,
                                raw,
                                seriesSeason,
                                -1,
                                -1,
                                true,
                                spLabel,
                                spLabel,
                                "",
                                false,
                                false,
                                "",
                                variantTag,
                                dateKey,
                                dateShort,
                                readableRaw,
                                specSummary));
                continue;
            }

            int season = extractSeasonNumber(core);
            if (season <= 0) season = seriesSeason;
            int epNum = -1;
            int endEp = -1;
            boolean periodUnit = false;

            Matcher se = SEASON_EP_RANGE_PATTERN.matcher(core);
            if (se.find()) {
                int sFound = parsePositiveInt(se.group(1));
                int eFound = parsePositiveInt(se.group(2));
                int eEnd = se.group(3) != null ? parsePositiveInt(se.group(3)) : -1;
                if (sFound > 0) season = sFound;
                if (eFound > 0) epNum = eFound;
                if (eEnd > epNum && eEnd - epNum <= 6) endEp = eEnd;
            }
            if (epNum <= 0) {
                Matcher cnAr = CN_ARABIC_EP_PATTERN.matcher(core);
                if (cnAr.find()) {
                    epNum = parsePositiveInt(cnAr.group(1));
                    int eEnd = cnAr.group(2) != null ? parsePositiveInt(cnAr.group(2)) : -1;
                    if (eEnd > epNum && eEnd - epNum <= 6) endEp = eEnd;
                    periodUnit = "期".equals(cnAr.group(3));
                }
            }
            if (epNum <= 0) {
                Matcher cnNum = CN_NUMERAL_EP_PATTERN.matcher(core);
                if (cnNum.find()) {
                    epNum = parseChineseNumeral(cnNum.group(1));
                    periodUnit = "期".equals(cnNum.group(2));
                }
            }
            if (epNum <= 0) {
                epNum = extractEpisodeNumber(core, constantNumbers);
            }

            if (periodUnit) varietyTokenCount++;
            if (epNum > 0 && offset != 0) {
                epNum = Math.max(1, epNum + offset);
                if (endEp > 0) endEp = Math.max(epNum, endEp + offset);
            }
            if (season > 0 && epNum > 0) {
                distinctSeasons.add(season);
            }
            if (epNum > 0) {
                regularCount++;
            }

            String officialTitle = epNum > 0 ? lookupOfficialEpTitle(override, epNum) : "";
            out.add(
                    new ScrapedEpisode(
                            i,
                            raw,
                            season,
                            epNum,
                            endEp,
                            false,
                            "",
                            raw,
                            officialTitle,
                            false,
                            periodUnit,
                            partTag,
                            variantTag,
                            dateKey,
                            dateShort,
                            readableRaw,
                            specSummary));
        }

        boolean multiSeason = distinctSeasons.size() >= 2;
        boolean multiYearDates = distinctDateYears.size() >= 2;
        boolean isVarietyLine =
                nonEmptyCount > 0
                        && (varietyTokenCount >= 2
                                || (varietyTokenCount >= 1
                                        && varietyTokenCount * 2 >= nonEmptyCount)
                                || (datedCount >= 2 && datedCount * 2 >= nonEmptyCount));

        List<ScrapedEpisode> finalized = new ArrayList<>(out.size());
        for (ScrapedEpisode item : out) {
            boolean usePeriodUnit =
                    item.isVarietyPeriod || (isVarietyLine && item.episodeNumber > 0);
            String fullDateLabel =
                    item.dateKey.length() == 8
                            ? (multiYearDates
                                    ? (item.dateKey.substring(0, 4)
                                            + "."
                                            + item.dateKey.substring(4, 6)
                                            + "."
                                            + item.dateKey.substring(6, 8))
                                    : item.dateLabel)
                            : item.dateLabel;
            String cleanLabel;
            if (preferRawNames && !item.manualOverride) {
                cleanLabel = item.cleanedRawLabel.isEmpty() ? item.rawName : item.cleanedRawLabel;
            } else if (item.isSpecial) {
                if (!fullDateLabel.isEmpty() && !item.specialLabel.isEmpty()) {
                    cleanLabel = fullDateLabel + "·" + item.specialLabel;
                } else {
                    cleanLabel = item.specialLabel;
                }
            } else if (item.episodeNumber > 0) {
                cleanLabel =
                        formatEpisodeBadge(
                                item.season,
                                item.episodeNumber,
                                item.endEpisodeNumber,
                                multiSeason,
                                usePeriodUnit,
                                item.partTag,
                                item.variantTag);
            } else if (!fullDateLabel.isEmpty()) {
                cleanLabel =
                        formatDatedFallbackLabel(
                                fullDateLabel, item.variantTag, item.cleanedRawLabel);
            } else {
                cleanLabel =
                        synthesizeUnnumberedResourceLabel(
                                item.rawName, item.cleanedRawLabel, commonTrailingBlock);
            }
            finalized.add(
                    new ScrapedEpisode(
                            item.sourceIndex,
                            item.rawName,
                            item.season,
                            item.episodeNumber,
                            item.endEpisodeNumber,
                            item.isSpecial,
                            item.specialLabel,
                            cleanLabel,
                            item.episodeTitle,
                            item.manualOverride,
                            usePeriodUnit,
                            item.partTag,
                            item.variantTag,
                            item.dateKey,
                            fullDateLabel,
                            item.cleanedRawLabel,
                            item.specSummary));
        }

        disambiguateDuplicateLabels(finalized, seriesTitle);
        boolean scrambled = detectScrambledOrder(finalized);
        return new ScrapedLine(
                finalized,
                scrambled,
                multiSeason,
                regularCount,
                specialCount,
                isVarietyLine,
                preferRawNames);
    }

    private static String formatDatedFallbackLabel(
            String dateLabel, String variantTag, String cleanedRaw) {
        if (!variantTag.isEmpty()) {
            return dateLabel + "·" + variantTag;
        }
        String rest =
                cleanedRaw == null
                        ? ""
                        : VARIETY_DATE_PATTERN.matcher(cleanedRaw).replaceAll(" ").trim();
        rest = rest.replaceAll("^[-·._\\s]+|[-·._\\s]+$", "").trim();
        if (!rest.isEmpty() && rest.length() <= 10) {
            return dateLabel + "·" + rest;
        }
        return dateLabel + "期";
    }

    private static String synthesizeUnnumberedResourceLabel(
            String rawName, String cleanedRaw, String commonTrailingBlock) {
        String safeRaw = rawName == null ? "" : rawName.trim();
        String candidate = cleanedRaw == null ? "" : cleanedRaw.trim();
        boolean noisy =
                looksLikeNoisyResourceLabel(safeRaw)
                        || SHORT_ASCII_RELEASE_TOKEN_PATTERN.matcher(candidate).find()
                        || RELEASE_GROUP_SUFFIX_PATTERN.matcher(candidate).find();
        if (!noisy
                && !candidate.isEmpty()
                && !BARE_YEAR_OR_PUNCT_PATTERN.matcher(candidate).matches()) {
            return candidate;
        }
        String core = stripTrailingNetdiskSuffix(safeRaw, commonTrailingBlock);
        String qualifierProbe = (core + " " + candidate).toLowerCase(Locale.ROOT);
        List<String> quals = new ArrayList<>(2);
        if (qualifierProbe.contains("imax")) quals.add("IMAX版");
        if (qualifierProbe.contains("未删减") || qualifierProbe.contains("uncut")) {
            quals.add("未删减版");
        } else if (qualifierProbe.contains("无删减") || qualifierProbe.contains("unrated")) {
            quals.add("无删减版");
        } else if (qualifierProbe.contains("导剪") || qualifierProbe.contains("director")) {
            quals.add("导剪版");
        } else if (qualifierProbe.contains("加长") || qualifierProbe.contains("extended")) {
            quals.add("加长版");
        } else if (qualifierProbe.contains("fixed")
                || qualifierProbe.contains("修正")
                || qualifierProbe.contains("修复")) {
            quals.add("修正版");
        } else if (qualifierProbe.contains("重映")) {
            quals.add("重映版");
        }
        if (qualifierProbe.contains("国粤")) quals.add("国粤");
        else if (qualifierProbe.contains("粤语") || qualifierProbe.contains("粤配")) {
            quals.add("粤语");
        } else if (qualifierProbe.contains("国语") || qualifierProbe.contains("国配")) {
            quals.add("国语");
        }
        if (!quals.isEmpty()) {
            StringBuilder sb = new StringBuilder("正片");
            for (int i = 0; i < quals.size() && i < 2; i++) {
                sb.append(" · ").append(quals.get(i));
            }
            return sb.toString();
        }
        String strippedSkeleton =
                DELIMITED_YEAR_PATTERN
                        .matcher(RELEASE_GROUP_SUFFIX_PATTERN.matcher(candidate).replaceAll(" "))
                        .replaceAll(" ");
        String prev;
        do {
            prev = strippedSkeleton;
            strippedSkeleton =
                    SHORT_ASCII_RELEASE_TOKEN_PATTERN.matcher(strippedSkeleton).replaceAll(" ");
        } while (!strippedSkeleton.equals(prev));
        strippedSkeleton =
                strippedSkeleton
                        .replaceAll("(?:\\s*[.·•]+\\s*)+", " ")
                        .replaceAll("^\\s*[-·._&]+\\s*|\\s*[-·._&]+\\s*$", "")
                        .replaceAll("\\s+", " ")
                        .trim();
        if (strippedSkeleton.isEmpty()
                || BARE_YEAR_OR_PUNCT_PATTERN.matcher(strippedSkeleton).matches()) {
            return "正片";
        }
        return strippedSkeleton;
    }

    /**
     * Guarantees no two episodes in the same line render indistinguishable duplicate scraped labels
     * (such as {@code 第01集 | 第01集}). Appends date, distinguishing spec/language token, or falls
     * back to cleaned readable raw name or clean cut indexing whenever collisions remain.
     */
    private static void disambiguateDuplicateLabels(List<ScrapedEpisode> list, String seriesTitle) {
        if (list.size() < 2) return;
        Map<String, List<Integer>> byLabel = new LinkedHashMap<>();
        for (int i = 0; i < list.size(); i++) {
            String lbl = list.get(i).cleanDisplayLabel;
            if (lbl.isEmpty()) continue;
            List<Integer> group = byLabel.get(lbl);
            if (group == null) {
                group = new ArrayList<>();
                byLabel.put(lbl, group);
            }
            group.add(i);
        }

        String cleanSeries = cleanWorkTitle(seriesTitle);
        for (List<Integer> indices : byLabel.values()) {
            if (indices.size() < 2) continue;

            // Step 0: If every item in this duplicate-title group already has a distinct
            // specSummary (e.g. "正片" 4K·18.5GB vs "正片" 4K·60fps·22GB), keep clean titlePart
            // and let card spec line differentiate them cleanly.
            Set<String> cardKeys = new HashSet<>();
            boolean allCardKeysDistinct = true;
            for (int idx : indices) {
                ScrapedEpisode ep = list.get(idx);
                if (ep.specSummary.isEmpty()
                        || !cardKeys.add(ep.cleanDisplayLabel + "|" + ep.specSummary)) {
                    allCardKeysDistinct = false;
                    break;
                }
            }
            if (allCardKeysDistinct) continue;

            // Step 1: Try disambiguating by air date (e.g. "10.22" vs "10.23")
            Set<String> dates = new HashSet<>();
            boolean allHaveDates = true;
            for (int idx : indices) {
                String d = list.get(idx).dateLabel;
                if (d.isEmpty()) {
                    allHaveDates = false;
                } else {
                    dates.add(d);
                }
            }
            if (allHaveDates && dates.size() > 1) {
                for (int idx : indices) {
                    ScrapedEpisode ep = list.get(idx);
                    list.set(
                            idx,
                            ep.withCleanDisplayLabel(
                                    ep.cleanDisplayLabel + " (" + ep.dateLabel + ")"));
                }
                if (allDistinctLabels(list, indices)) continue;
            }

            // Step 2: Try disambiguating by spec/language tag (4K vs 1080P, 国语 vs 粤语, etc.)
            Map<Integer, String> specTags = new HashMap<>();
            Set<String> uniqueSpecs = new HashSet<>();
            for (int idx : indices) {
                String tag = extractSpecDisambigTag(list.get(idx).rawName);
                specTags.put(idx, tag);
                if (!tag.isEmpty()) uniqueSpecs.add(tag);
            }
            if (uniqueSpecs.size() >= 2) {
                for (int idx : indices) {
                    String tag = specTags.get(idx);
                    if (tag != null && !tag.isEmpty()) {
                        ScrapedEpisode ep = list.get(idx);
                        list.set(idx, ep.withCleanDisplayLabel(ep.cleanDisplayLabel + "·" + tag));
                    }
                }
                if (allDistinctLabels(list, indices)) continue;
            }

            // Step 3: Fall back to cleaned readable raw name if non-noisy, else clean indexed cuts
            for (int k = 0; k < indices.size(); k++) {
                int idx = indices.get(k);
                ScrapedEpisode ep = list.get(idx);
                if (ep.manualOverride) continue;
                String readable = ep.cleanedRawLabel.isEmpty() ? ep.rawName : ep.cleanedRawLabel;
                if (!cleanSeries.isEmpty()
                        && readable.length() > cleanSeries.length() + 1
                        && readable.startsWith(cleanSeries)) {
                    String trimmed =
                            readable.substring(cleanSeries.length())
                                    .replaceAll("^[\\s._\\-·:：]+", "")
                                    .trim();
                    if (!trimmed.isEmpty()) readable = trimmed;
                }
                boolean usableReadable =
                        !readable.isEmpty()
                                && !looksLikeNoisyResourceLabel(ep.rawName)
                                && !BARE_YEAR_OR_PUNCT_PATTERN.matcher(readable).matches();
                if (!usableReadable) {
                    String numStr = (k + 1) < 10 ? "0" + (k + 1) : String.valueOf(k + 1);
                    String baseTitle = ep.cleanDisplayLabel.isEmpty() ? "片源" : ep.cleanDisplayLabel;
                    list.set(idx, ep.withCleanDisplayLabel(baseTitle + " " + numStr));
                } else {
                    list.set(idx, ep.withCleanDisplayLabel(readable));
                }
            }
        }
    }

    private static boolean allDistinctLabels(List<ScrapedEpisode> list, List<Integer> indices) {
        Set<String> seen = new HashSet<>();
        for (int idx : indices) {
            if (!seen.add(list.get(idx).cleanDisplayLabel)) return false;
        }
        return true;
    }

    private static String extractSpecDisambigTag(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String lower = raw.toLowerCase(Locale.ROOT);
        for (String[] rule : SPEC_DISAMBIG_RULES) {
            if (lower.contains(rule[0])) {
                return rule[1];
            }
        }
        return "";
    }

    /**
     * True when the raw episode array is confidently out of order (e.g., lexicographic {@code 1,
     * 10, 11, 2}, reversed {@code 40..1}, scrambled variety uploads, or specials intermixed before
     * regular episodes). Returns {@code false} when too many entries collide ambiguously on the
     * same scraped episode identity so uncertain parses never scramble the user's episode list.
     */
    private static boolean detectScrambledOrder(List<ScrapedEpisode> list) {
        if (list.size() < 2) return false;
        Set<String> seenIdentities = new HashSet<>();
        int regularTotal = 0;
        int ambiguousDuplicates = 0;
        for (ScrapedEpisode ep : list) {
            if (ep.isSpecial || ep.episodeNumber <= 0) continue;
            regularTotal++;
            String identity =
                    (ep.season > 0 ? ep.season : 1)
                            + ":"
                            + ep.episodeNumber
                            + ":"
                            + ep.partTag
                            + ":"
                            + ep.variantTag
                            + ":"
                            + ep.dateKey;
            if (!seenIdentities.add(identity)) {
                ambiguousDuplicates++;
            }
        }
        // If >= 40% of numbered entries collide with identical identity, do NOT auto-reorder.
        if (regularTotal >= 2 && ambiguousDuplicates * 5 >= regularTotal * 2) {
            return false;
        }

        ScrapedEpisode prevRegular = null;
        int numbered = 0;
        boolean seenRegular = false;
        boolean leadingSpecial = false;
        for (ScrapedEpisode ep : list) {
            if (ep.isSpecial) {
                if (!seenRegular) leadingSpecial = true;
                continue;
            }
            if (ep.episodeNumber <= 0 && ep.dateKey.isEmpty()) continue;
            seenRegular = true;
            if (ep.episodeNumber > 0) numbered++;
            if (prevRegular != null && compareScrapedOrder(ep, prevRegular) < 0) {
                return true;
            }
            prevRegular = ep;
        }
        return leadingSpecial && numbered >= 2;
    }

    private static Set<Integer> computeConstantNumbers(
            String seriesTitle, List<Cms.Episode> episodes, String commonTrailingBlock) {
        Set<Integer> constants = new HashSet<>();
        if (seriesTitle != null && !seriesTitle.trim().isEmpty()) {
            String titleNoNoise = stripTechNoise(normalizeSequelNumerals(seriesTitle));
            Matcher tm = LOOSE_NUMBER_PATTERN.matcher(titleNoNoise);
            while (tm.find()) {
                int v = parsePositiveInt(tm.group(1));
                if (v > 0 && v <= 99) constants.add(v);
            }
        }
        if (episodes.size() < 3) return constants;
        Map<Integer, Integer> docFreq = new HashMap<>();
        int nonEmpty = 0;
        for (Cms.Episode ep : episodes) {
            if (ep == null || ep.name == null || ep.name.trim().isEmpty()) continue;
            nonEmpty++;
            String core =
                    stripCopySuffixIfOtherNumberPresent(
                            stripTrailingNetdiskSuffix(ep.name, commonTrailingBlock));
            String cleaned =
                    VARIETY_DATE_PATTERN
                            .matcher(TITLE_NOISE_TAGS.matcher(stripTechNoise(core)).replaceAll(" "))
                            .replaceAll(" ");
            Matcher m = LOOSE_NUMBER_PATTERN.matcher(cleaned);
            Set<Integer> seenInEp = new HashSet<>();
            int tokenCount = 0;
            while (m.find()) {
                int v = parsePositiveInt(m.group(1));
                if (v > 0 && v <= 2000) {
                    seenInEp.add(v);
                    tokenCount++;
                }
            }
            // Only mark numbers as constant if an episode actually has >= 2 number tokens
            // (including duplicates like "斗罗大陆2_02" -> [2, 2]).
            if (tokenCount >= 2) {
                for (Integer v : seenInEp) {
                    Integer prev = docFreq.get(v);
                    docFreq.put(v, prev == null ? 1 : prev + 1);
                }
            }
        }
        if (nonEmpty >= 3) {
            int threshold = (int) Math.ceil(nonEmpty * 0.80);
            for (Map.Entry<Integer, Integer> entry : docFreq.entrySet()) {
                if (entry.getValue() >= threshold) {
                    constants.add(entry.getKey());
                }
            }
        }
        return constants;
    }

    private static String lookupOfficialEpTitle(
            SeriesScrapeStore.OverrideRecord override, int epNum) {
        if (override == null || override.officialEpisodeTitles == null || epNum <= 0) return "";
        String t = override.officialEpisodeTitles.get(epNum);
        return t == null ? "" : t.trim();
    }

    static String formatEpisodeBadge(int season, int epNum, int endEp, boolean showSeason) {
        return formatEpisodeBadge(season, epNum, endEp, showSeason, false, "", "");
    }

    static String formatEpisodeBadge(
            int season,
            int epNum,
            int endEp,
            boolean showSeason,
            boolean isVarietyPeriod,
            String partTag,
            String variantTag) {
        if (epNum <= 0) return "";
        String pEp = epNum < 10 ? "0" + epNum : String.valueOf(epNum);
        String unit = isVarietyPeriod ? "期" : "集";
        String base;
        if (showSeason && season > 0) {
            String pS = season < 10 ? "0" + season : String.valueOf(season);
            if (endEp > epNum) {
                String pEnd = endEp < 10 ? "0" + endEp : String.valueOf(endEp);
                base = "S" + pS + "E" + pEp + "-E" + pEnd;
            } else {
                base = "S" + pS + "E" + pEp;
            }
        } else if (endEp > epNum) {
            String pEnd = endEp < 10 ? "0" + endEp : String.valueOf(endEp);
            base = "第" + pEp + "-" + pEnd + unit;
        } else {
            base = "第" + pEp + unit;
        }
        if (partTag != null && !partTag.isEmpty()) {
            base = base + partTag;
        }
        if (variantTag != null && !variantTag.isEmpty()) {
            base = base + "·" + variantTag;
        }
        return base;
    }

    /**
     * Decides whether a raw episode name should be replaced on the TV episode grid with the crisp
     * scraped badge (true for release filenames, scrambled lists, manual overrides, variety lines,
     * or bound official titles; false when the source already provides clean concise labels like
     * {@code 第01集} or custom chapter titles without release clutter).
     */
    static String formatGridEpisodeLabel(
            ScrapedEpisode scraped, boolean isBookmarked, boolean hasOverrideOrScrambled) {
        String[] parts = formatGridEpisodeCardParts(scraped, isBookmarked, hasOverrideOrScrambled);
        if (parts[0].isEmpty()) return "";
        return parts[1].isEmpty() ? parts[0] : (parts[0] + " · " + parts[1]);
    }

    /**
     * Returns {@code {titlePart, specPart}} for two-line TV episode grid cards so resolution,
     * dynamic range, audio, and file size render cleanly on a secondary metadata line without
     * misaligning card titles.
     */
    static String[] formatGridEpisodeCardParts(
            ScrapedEpisode scraped, boolean isBookmarked, boolean hasOverrideOrScrambled) {
        if (scraped == null) return new String[] {"", ""};
        String base = scraped.rawName;
        boolean scrapedFormatted = false;
        if (scraped.manualOverride || !scraped.episodeTitle.isEmpty()) {
            base = scraped.displayText();
            scrapedFormatted = true;
        } else if (scraped.isSpecial) {
            base =
                    scraped.rawName.length() > 14
                            ? (scraped.cleanDisplayLabel.isEmpty()
                                    ? scraped.specialLabel
                                    : scraped.cleanDisplayLabel)
                            : scraped.rawName;
            scrapedFormatted = !base.equals(scraped.rawName);
        } else if (scraped.episodeNumber > 0 || !scraped.dateLabel.isEmpty()) {
            boolean noisyFilename =
                    scraped.rawName.length() > 14
                            || scraped.rawName.contains(".")
                            || scraped.rawName.contains("【")
                            || TECH_NOISE_PATTERN.matcher(scraped.rawName).find();
            if (noisyFilename || hasOverrideOrScrambled) {
                base = scraped.cleanDisplayLabel;
                scrapedFormatted = true;
            }
        } else if (!scraped.cleanDisplayLabel.isEmpty()
                && (scraped.rawName.length() > 18
                        || scraped.rawName.contains("【")
                        || scraped.rawName.contains("..")
                        || TECH_NOISE_PATTERN.matcher(scraped.rawName).find()
                        || !scraped.specSummary.isEmpty())) {
            base = scraped.cleanDisplayLabel;
            scrapedFormatted = true;
        }
        String specPart = "";
        if (scrapedFormatted && !scraped.specSummary.isEmpty()) {
            String lowerBase = base.toLowerCase(Locale.ROOT);
            StringBuilder specSb = new StringBuilder();
            for (String token : scraped.specSummary.split(" · ")) {
                String trimmed = token.trim();
                if (!trimmed.isEmpty() && !lowerBase.contains(trimmed.toLowerCase(Locale.ROOT))) {
                    if (specSb.length() > 0) specSb.append(" · ");
                    specSb.append(trimmed);
                }
            }
            specPart = specSb.toString();
        }
        String titlePart = isBookmarked ? ("● " + base) : base;
        return new String[] {titlePart, specPart};
    }

    /**
     * Computes the exact episode number for Danmaku matching:
     *
     * <ul>
     *   <li>Returns {@code 0} for single-stream movies (preventing bogus {@code "Movie E01"}
     *       queries).
     *   <li>Returns the real scraped episode number (with {@code episodeOffset} and per-episode
     *       overrides applied) rather than the raw 1-based array index.
     *   <li>Falls back to 1-based regular-episode rank (excluding leading trailers/specials) only
     *       when no episode number could be extracted.
     * </ul>
     */
    static int resolveDanmuEpisodeNumber(
            String seriesTitle,
            List<Cms.Episode> episodes,
            int activeIndex,
            SeriesScrapeStore.OverrideRecord override) {
        if (episodes == null || episodes.isEmpty()) return 0;
        int safeIdx = Math.max(0, Math.min(activeIndex, episodes.size() - 1));
        Cms.Episode active = episodes.get(safeIdx);
        String rawName = active != null && active.name != null ? active.name.trim() : "";

        // Single-item movie detection
        if (episodes.size() == 1
                && (override == null
                        || (override.episodeOffset == 0
                                && (override.episodeNumberOverrides == null
                                        || override.episodeNumberOverrides.isEmpty())))
                && HistoryResumeMatcher.looksLikeMovieEpisode(rawName)
                && extractEpisodeNumber(rawName) <= 0) {
            return 0;
        }

        ScrapedLine scraped = scrapeLine(seriesTitle, episodes, override);
        ScrapedEpisode item = scraped.atSourceIndex(safeIdx);
        if (item != null && !item.isSpecial && item.episodeNumber > 0) {
            return item.episodeNumber;
        }
        if (item != null && item.isSpecial) {
            return 0;
        }
        // Fallback: count non-special episodes up to safeIdx
        int regularRank = 0;
        for (int i = 0; i <= safeIdx; i++) {
            ScrapedEpisode cand = scraped.atSourceIndex(i);
            if (cand != null && !cand.isSpecial) regularRank++;
        }
        int offset = override != null ? override.episodeOffset : 0;
        return Math.max(1, Math.max(1, regularRank) + offset);
    }

    static int resolveDanmuSeasonNumber(
            String seriesTitle,
            List<Cms.Episode> episodes,
            int activeIndex,
            SeriesScrapeStore.OverrideRecord override) {
        if (episodes != null && !episodes.isEmpty()) {
            int safeIdx = Math.max(0, Math.min(activeIndex, episodes.size() - 1));
            ScrapedLine scraped = scrapeLine(seriesTitle, episodes, override);
            ScrapedEpisode item = scraped.atSourceIndex(safeIdx);
            if (item != null && item.season > 0) return item.season;
        }
        String effectiveTitle =
                override != null && !override.matchedTitle.isEmpty()
                        ? override.matchedTitle
                        : seriesTitle;
        return extractSeasonNumber(effectiveTitle);
    }

    static boolean isSingleMovieLine(
            String seriesTitle, List<Cms.Episode> episodes, int activeIndex) {
        if (episodes == null || episodes.size() != 1) return false;
        Cms.Episode ep = episodes.get(Math.max(0, Math.min(activeIndex, episodes.size() - 1)));
        String name = ep != null && ep.name != null ? ep.name.trim() : "";
        return HistoryResumeMatcher.looksLikeMovieEpisode(name) && extractEpisodeNumber(name) <= 0;
    }

    /**
     * Scores a Dandanplay search candidate using cleaned title similarity, work-form consistency
     * (rejecting 动态漫画 / 有声书 mismatches), season agreement, and episode number agreement.
     */
    static double scoreDanmuCandidate(
            String rawQueryTitle,
            int querySeason,
            int queryEp,
            String candAnimeTitle,
            String candEpTitle) {
        WorkForm queryForm = detectWorkForm(rawQueryTitle);
        WorkForm candForm = detectWorkForm(candAnimeTitle);
        double score = 0.50;
        if (queryForm != candForm) {
            score -= 0.35;
        }

        String qCore = normalizeCoreKey(rawQueryTitle);
        String cCore = normalizeCoreKey(candAnimeTitle);
        if (!qCore.isEmpty() && !cCore.isEmpty()) {
            if (qCore.equals(cCore)) {
                score += 0.32;
            } else if (cCore.contains(qCore) || qCore.contains(cCore)) {
                int lenDiff = Math.abs(cCore.length() - qCore.length());
                score += Math.max(0.08, 0.24 - lenDiff * 0.02);
            } else {
                score -= 0.12;
            }
        }

        int candSeason = extractSeasonNumber(candAnimeTitle);
        if (querySeason > 0 && candSeason > 0) {
            score += (querySeason == candSeason) ? 0.14 : -0.25;
        } else if (querySeason > 1 && candSeason <= 0) {
            score -= 0.10;
        }

        if (queryEp > 0 && candEpTitle != null && !candEpTitle.trim().isEmpty()) {
            int candEp = extractEpisodeNumber(candEpTitle);
            if (candEp == queryEp) {
                score += 0.14;
            } else if (candEp > 0) {
                score -= 0.20;
            }
        }
        return Math.max(0.05, Math.min(0.99, score));
    }

    /**
     * Matches an episode from {@code fromLine} to {@code targetLine} using scraped {@code (season,
     * episodeNumber, partTag, variantTag)} before falling back to episode number or positional
     * index.
     */
    static Cms.Episode findMatchingEpisodeAcrossLines(
            String seriesTitle,
            Cms.Line targetLine,
            Cms.Line fromLine,
            Cms.Episode fromEpisode,
            SeriesScrapeStore.OverrideRecord override) {
        if (targetLine == null || targetLine.episodes == null || targetLine.episodes.isEmpty()) {
            return null;
        }
        if (fromEpisode != null && fromEpisode.name != null) {
            for (Cms.Episode cand : targetLine.episodes) {
                if (cand != null && fromEpisode.name.equalsIgnoreCase(cand.name)) {
                    return cand;
                }
            }
        }
        int fromIdx =
                fromLine != null && fromLine.episodes != null && fromEpisode != null
                        ? fromLine.episodes.indexOf(fromEpisode)
                        : -1;
        if (fromLine != null && fromIdx >= 0) {
            ScrapedLine fromScraped = scrapeLine(seriesTitle, fromLine.episodes, override);
            ScrapedEpisode src = fromScraped.atSourceIndex(fromIdx);
            if (src != null && !src.isSpecial && src.episodeNumber > 0) {
                ScrapedLine targetScraped = scrapeLine(seriesTitle, targetLine.episodes, override);
                Cms.Episode seasonEpMatch = null;
                Cms.Episode fallbackEpMatch = null;
                for (ScrapedEpisode cand : targetScraped.episodes) {
                    if (cand.isSpecial || cand.episodeNumber != src.episodeNumber) continue;
                    boolean seasonOk =
                            src.season <= 0 || cand.season <= 0 || src.season == cand.season;
                    boolean variantAndPartExact =
                            src.partTag.equals(cand.partTag)
                                    && src.variantTag.equals(cand.variantTag);
                    if (seasonOk && variantAndPartExact) {
                        return targetLine.episodes.get(cand.sourceIndex);
                    }
                    if (seasonOk && seasonEpMatch == null) {
                        seasonEpMatch = targetLine.episodes.get(cand.sourceIndex);
                    }
                    if (fallbackEpMatch == null) {
                        fallbackEpMatch = targetLine.episodes.get(cand.sourceIndex);
                    }
                }
                if (seasonEpMatch != null) return seasonEpMatch;
                if (fallbackEpMatch != null) return fallbackEpMatch;
            }
        }
        if (fromIdx >= 0 && fromIdx < targetLine.episodes.size()) {
            return targetLine.episodes.get(fromIdx);
        }
        return targetLine.episodes.get(0);
    }

    static String formatRangeLabel(
            ScrapedLine scraped, List<Integer> orderedIndices, int start, int end) {
        if (orderedIndices == null || orderedIndices.isEmpty() || start >= end) return "";
        int safeEnd = Math.min(end, orderedIndices.size());
        ScrapedEpisode first =
                scraped != null ? scraped.atSourceIndex(orderedIndices.get(start)) : null;
        ScrapedEpisode last =
                scraped != null ? scraped.atSourceIndex(orderedIndices.get(safeEnd - 1)) : null;
        if (first != null
                && last != null
                && !first.isSpecial
                && !last.isSpecial
                && first.episodeNumber > 0
                && last.episodeNumber > 0) {
            if (scraped.multiSeason && first.season > 0 && last.season > 0) {
                return "S"
                        + first.season
                        + "E"
                        + first.episodeNumber
                        + "–S"
                        + last.season
                        + "E"
                        + last.episodeNumber;
            }
            if (scraped.isVarietyLine) {
                return "第" + first.episodeNumber + "–" + last.episodeNumber + "期";
            }
            return first.episodeNumber + "–" + last.episodeNumber;
        }
        return (start + 1) + "–" + safeEnd;
    }

    static int parsePositiveInt(String digits) {
        if (digits == null || digits.isEmpty()) return -1;
        try {
            int val = Integer.parseInt(digits.trim());
            return val > 0 ? val : -1;
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    static int parseChineseNumeral(String cn) {
        if (cn == null || cn.trim().isEmpty()) return -1;
        String s = cn.trim();
        int total = 0;
        int current = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            int digit = chineseDigit(c);
            if (digit >= 0) {
                current = digit;
            } else if (c == '十') {
                total += (current == 0 ? 1 : current) * 10;
                current = 0;
            } else if (c == '百') {
                total += (current == 0 ? 1 : current) * 100;
                current = 0;
            } else if (c == '千') {
                total += (current == 0 ? 1 : current) * 1000;
                current = 0;
            } else {
                return -1;
            }
        }
        total += current;
        return total > 0 ? total : -1;
    }

    private static int chineseDigit(char c) {
        switch (c) {
            case '零':
            case '〇':
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

    /** Utility used by interactive search to deduplicate candidate queries. */
    static List<String> buildSearchQueries(String rawTitle) {
        Set<String> out = new LinkedHashSet<>();
        String clean = cleanWorkTitle(rawTitle);
        if (!clean.isEmpty()) out.add(clean);
        String noSeason =
                SEASON_ONLY_PATTERN.matcher(clean).replaceAll(" ").replaceAll("\\s+", " ").trim();
        if (!noSeason.isEmpty()) out.add(noSeason);
        if (rawTitle != null && !rawTitle.trim().isEmpty()) out.add(rawTitle.trim());
        return new ArrayList<>(out);
    }

    /**
     * Unified candidate scorer shared by local media scraping, manual Douban/Bangumi search
     * ranking, and score lookups to minimize wrong-season / partial-title mismatches.
     */
    static int scoreMetadataCandidate(
            String rawTitle,
            String targetYear,
            boolean targetIsSeries,
            int targetEpisodeCount,
            String candTitle,
            String candYear,
            String candKind,
            int candEpisodeCount,
            String candPosterUrl,
            double candRating) {
        if (candTitle == null || candTitle.trim().isEmpty()) return -1000;
        String cleanTarget = normalizeCoreKey(rawTitle);
        String cleanCand = normalizeCoreKey(candTitle);
        if (cleanTarget.isEmpty() || cleanCand.isEmpty()) return -1000;
        int score = 0;
        if (cleanTarget.equals(cleanCand)) {
            score += 100;
        } else if (cleanCand.contains(cleanTarget) || cleanTarget.contains(cleanCand)) {
            int minLen = Math.min(cleanCand.length(), cleanTarget.length());
            int maxLen = Math.max(cleanCand.length(), cleanTarget.length());
            if (minLen * 2 >= maxLen) {
                score += 55 - Math.min(25, (maxLen - minLen) * 4);
            } else {
                score -= 20;
            }
        } else {
            score -= 60;
        }
        int tSeason = extractSeasonNumber(rawTitle);
        int cSeason = extractSeasonNumber(candTitle);
        if (tSeason > 0 && cSeason > 0) {
            score += (tSeason == cSeason) ? 30 : -45;
        } else if (tSeason > 1 && cSeason <= 0) {
            score -= 20;
        }
        String ty = targetYear == null ? "" : targetYear.trim();
        String cy = candYear == null ? "" : candYear.trim();
        if (!ty.isEmpty() && !cy.isEmpty()) {
            if (ty.equals(cy)) {
                score += 25;
            } else {
                try {
                    int diff = Math.abs(Integer.parseInt(ty) - Integer.parseInt(cy));
                    score -= (diff <= 1) ? 8 : 25;
                } catch (NumberFormatException ignored) {
                    score -= 15;
                }
            }
        }
        if (candKind != null && !candKind.isEmpty()) {
            if (targetIsSeries && "tv".equals(candKind)) score += 15;
            else if (!targetIsSeries && "movie".equals(candKind)) score += 15;
            else if (targetIsSeries && "movie".equals(candKind)) score -= 18;
        }
        if (targetIsSeries && targetEpisodeCount > 1 && candEpisodeCount > 0) {
            if (candEpisodeCount == targetEpisodeCount) score += 15;
            else if (Math.abs(candEpisodeCount - targetEpisodeCount) <= 2) score += 8;
            else if (candEpisodeCount < Math.max(1, targetEpisodeCount / 3)) score -= 12;
        }
        if (candPosterUrl != null && !candPosterUrl.trim().isEmpty()) score += 5;
        if (candRating > 1.0) score += 3;
        return score;
    }

    /** Strips cloud-drive share noise from title/episode names to build a clean danmaku query. */
    static String cleanNetdiskDanmuQuery(String rawTitle, String episodeName) {
        String candidate = cleanWorkTitle(rawTitle);
        candidate = stripCloudDriveWords(candidate);
        if ((candidate.isEmpty() || candidate.length() <= 1) && episodeName != null) {
            String epBase = stripTrailingNetdiskSuffix(episodeName, "");
            epBase = FILE_EXT_PATTERN.matcher(epBase).replaceAll(" ");
            epBase = epBase.replaceAll("(?i)(?:S\\d{1,2}E\\d{1,4}.*|第\\s*\\d+\\s*[集话期].*)$", " ");
            String cleanedEp = stripCloudDriveWords(cleanWorkTitle(epBase));
            if (!cleanedEp.isEmpty()) candidate = cleanedEp;
        }
        return candidate.replaceAll("\\s+", " ").trim();
    }

    private static String stripCloudDriveWords(String text) {
        if (text == null || text.isEmpty()) return "";
        return text.replaceAll(
                        "(?i)(?:阿里云?盘|夸克网盘|夸克资源|夸克|百度云?网?盘|迅雷云?盘|115网盘|UC网盘|原盘|高码率?|杜比视界|臻彩|蓝光|全集|合集|内封字幕|外挂字幕|中英字幕|特效字幕|国粤双语)",
                        " ")
                .replaceAll("\\s+", " ")
                .trim();
    }
}

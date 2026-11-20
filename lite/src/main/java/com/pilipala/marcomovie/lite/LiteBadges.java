// SPDX-License-Identifier: GPL-3.0-only
package com.pilipala.marcomovie.lite;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Lightweight Android 4.0 (API 14) single-DEX media specification badge parser for Marco Movie
 * Lite.
 *
 * <p>Implements {@code shared/ui-spec/badge-rules.json} (schemaVersion 1) with identical
 * normalization, regex matching, combo rules, and deterministic sorting as {@code MediaBadges} and
 * Flutter {@code media_badges.dart}. Outputs plain-text strings for zero-allocation {@code
 * TextView} concatenation.
 */
public final class LiteBadges {
    public static final int MAX_INPUT_CODE_UNITS = 1024;
    public static final int LRU_CACHE_CAPACITY = 256;

    private static final Charset UTF8 = Charset.forName("UTF-8");

    public static final class Badge {
        public final String id;
        public final String group;
        public final String label;
        public final int priority;
        public final String style;

        Badge(String id, String group, String label, int priority, String style) {
            this.id = id;
            this.group = group;
            this.label = label;
            this.priority = priority;
            this.style = style;
        }
    }

    private static final class Rule {
        final String id;
        final Pattern pattern;
        final Badge badge;

        Rule(String id, String group, String label, String regex, int priority, String style) {
            this.id = id;
            this.pattern = Pattern.compile(regex, Pattern.CASE_INSENSITIVE);
            this.badge = new Badge(id, group, label, priority, style);
        }
    }

    private static final class ComboRule {
        final String[] requires;
        final String[] consumes;
        final Badge badge;

        ComboRule(
                String id,
                String group,
                String label,
                String[] requires,
                String[] consumes,
                int priority,
                String style) {
            this.requires = requires;
            this.consumes = consumes;
            this.badge = new Badge(id, group, label, priority, style);
        }
    }

    private static final Comparator<Badge> BADGE_ORDER =
            new Comparator<Badge>() {
                @Override
                public int compare(Badge a, Badge b) {
                    if (a.priority != b.priority) {
                        return a.priority < b.priority ? -1 : 1;
                    }
                    return a.id.compareTo(b.id);
                }
            };

    private static final List<Rule> RULES;
    private static final Map<String, Rule> RULE_BY_ID;
    private static final List<ComboRule> COMBO_RULES;

    private static final LinkedHashMap<String, List<Badge>> CACHE =
            new LinkedHashMap<String, List<Badge>>(LRU_CACHE_CAPACITY, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(Map.Entry<String, List<Badge>> eldest) {
                    return size() > LRU_CACHE_CAPACITY;
                }
            };

    static {
        List<Rule> r = new ArrayList<Rule>(45);
        r.add(
                new Rule(
                        "res_8k",
                        "resolution",
                        "8K",
                        "^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1440[pi]|2k|qhd|wqhd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|2560|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:4320[pi]|8k|fuhd|7680[ ]*[x×][ ]*4320[pi]?)(?![a-z0-9])",
                        100,
                        "uhdGold"));
        r.add(
                new Rule(
                        "res_4k",
                        "resolution",
                        "4K",
                        "^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|(?:3840|4096)[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])",
                        110,
                        "uhdGold"));
        r.add(
                new Rule(
                        "res_2k",
                        "resolution",
                        "2K",
                        "^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:1440[pi]|2k|qhd|wqhd|2560[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])",
                        120,
                        "hdCyan"));
        r.add(
                new Rule(
                        "res_1080p",
                        "resolution",
                        "1080p",
                        "^(?:(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])|.*(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|.*[^a-z0-9])1080[ ]*(?:高码|蓝光|超清))",
                        130,
                        "hdCyan"));
        r.add(
                new Rule(
                        "res_720p",
                        "resolution",
                        "720p",
                        "^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:^|.*[^a-z0-9])(?:720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])",
                        140,
                        "sdNeutral"));
        r.add(
                new Rule(
                        "res_sd",
                        "resolution",
                        "SD",
                        "^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?|720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:(?:^|.*[^a-z0-9])(?:(?:480|576)[pi]|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9])|.*标清|(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))",
                        150,
                        "sdNeutral"));
        r.add(
                new Rule(
                        "dr_dv",
                        "dynamic_range",
                        "DV",
                        "^(?:(?:^|.*[^a-z0-9])(?:dv|dovi|dolby[ ._-]?vision|(?:dvh[e1]|dav1)(?:\\.[0-9]{2}(?:\\.[0-9]{2})?)?)(?![a-z0-9])|.*杜比视界)",
                        210,
                        "visionPurple"));
        r.add(
                new Rule(
                        "dr_hdr10plus",
                        "dynamic_range",
                        "HDR10+",
                        "^(?:^|.*[^a-z0-9])(?:hdr10\\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9]))",
                        220,
                        "visionPurple"));
        r.add(
                new Rule(
                        "dr_hdr10",
                        "dynamic_range",
                        "HDR10",
                        "^(?!(?:^|.*[^a-z0-9])(?:hdr10\\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9]))",
                        230,
                        "hdrBlue"));
        r.add(
                new Rule(
                        "dr_hlg",
                        "dynamic_range",
                        "HLG",
                        "^(?:^|.*[^a-z0-9])(?:hlg|arib[ ._-]?std[ ._-]?b67)(?![a-z0-9])",
                        240,
                        "hdrBlue"));
        r.add(
                new Rule(
                        "dr_hdr",
                        "dynamic_range",
                        "HDR",
                        "^(?!(?:^|.*[^a-z0-9])(?:hdr10\\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])|hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9])|hlg(?![a-z0-9])|arib[ ._-]?std[ ._-]?b67(?![a-z0-9])|(?:non|no)[ ._-]?hdr(?![a-z0-9])))(?:(?:^|.*[^a-z0-9])(?:hdr(?:[ ._-]?vivid)?(?![a-z0-9])|hdr10[ ._-]?bits?(?![a-z0-9]))|(?=(?:^|.*[^a-z0-9])bt\\.?2020(?![a-z0-9]))(?=(?:^|.*[^a-z0-9])pq(?![a-z0-9])).*|.*臻彩)",
                        250,
                        "hdrBlue"));
        r.add(
                new Rule(
                        "src_remux",
                        "source_quality",
                        "REMUX",
                        "^(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9])",
                        310,
                        "discEmerald"));
        r.add(
                new Rule(
                        "src_bluray",
                        "source_quality",
                        "BluRay",
                        "^(?!(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9]))(?:(?:^|.*[^a-z0-9])(?:(?:blu[ ._-]?ray|bdrip|brrip|bdmv|bdiso|uhdbd|bd(?:25|50|66|100))(?![a-z0-9])|bd(?![a-z0-9])(?!://))|.*(?:蓝光原盘|原盘))",
                        320,
                        "discEmerald"));
        r.add(
                new Rule(
                        "src_webdl",
                        "source_quality",
                        "WEB-DL",
                        "^(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9])",
                        330,
                        "streamTeal"));
        r.add(
                new Rule(
                        "src_webrip",
                        "source_quality",
                        "WEBRip",
                        "^(?!(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9]))(?:^|.*[^a-z0-9])web[ ._-]?rip(?![a-z0-9])",
                        340,
                        "streamTeal"));
        r.add(
                new Rule(
                        "src_hdtv",
                        "source_quality",
                        "HDTV",
                        "^(?:^|.*[^a-z0-9])(?:hdtv(?:rip)?|pdtv|dsr)(?![a-z0-9])",
                        350,
                        "streamTeal"));
        r.add(
                new Rule(
                        "aud_atmos",
                        "audio_codec",
                        "ATMOS",
                        "^(?:(?:^|.*[^a-z0-9])(?:atmos(?![a-z0-9])|e[ ._-]?ac[ ._-]?3[ ._-]?joc(?![a-z0-9])|ec\\+3(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))|.*(?:杜比)?全景声)",
                        410,
                        "spatialAudio"));
        r.add(
                new Rule(
                        "aud_dtsx",
                        "audio_codec",
                        "DTS:X",
                        "^(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        420,
                        "spatialAudio"));
        r.add(
                new Rule(
                        "aud_truehd",
                        "audio_codec",
                        "TrueHD",
                        "^(?:^|.*[^a-z0-9])(?:true[ ._-]?hd|mlp)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        430,
                        "spatialAudio"));
        r.add(
                new Rule(
                        "aud_dtshd_ma",
                        "audio_codec",
                        "DTS-HD MA",
                        "^(?!(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        440,
                        "spatialAudio"));
        r.add(
                new Rule(
                        "aud_dtshd",
                        "audio_codec",
                        "DTS-HD",
                        "^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd(?:[ ._-]?(?:hr|hra))?|dts[ ._-]?(?:hr|hra))(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        450,
                        "standardAudio"));
        r.add(
                new Rule(
                        "aud_dts",
                        "audio_codec",
                        "DTS",
                        "^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd(?:[ ._-]?(?:ma|hr|hra))?|dts[ ._-]?(?:ma|xll|hr|hra))(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))(?:^|.*[^a-z0-9])dts(?:[ ._-]?es)?(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        460,
                        "standardAudio"));
        r.add(
                new Rule(
                        "aud_ddp",
                        "audio_codec",
                        "DD+",
                        "^(?:^|.*[^a-z0-9])(?:dd\\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9]))))",
                        470,
                        "standardAudio"));
        r.add(
                new Rule(
                        "aud_dd",
                        "audio_codec",
                        "DD",
                        "^(?!(?:^|.*[^a-z0-9])(?:dd\\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))))(?:(?:^|.*[^a-z0-9])(?:ac[ ._-]?3|dolby[ ._-]?(?:digital|audio))(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))|(?:^|.*[^a-z0-9])dd[ ._-]?[125678]\\.[01](?![0-9])|(?:^|.*[^a-z0-9/])dd(?![a-z0-9+/]))",
                        480,
                        "standardAudio"));
        r.add(
                new Rule(
                        "aud_lpcm",
                        "audio_codec",
                        "LPCM",
                        "^(?:^|.*[^a-z0-9])(?:lpcm|pcm)(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        485,
                        "standardAudio"));
        r.add(
                new Rule(
                        "aud_flac",
                        "audio_codec",
                        "FLAC",
                        "^(?:^|.*[^a-z0-9])flac(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        490,
                        "standardAudio"));
        r.add(
                new Rule(
                        "aud_opus",
                        "audio_codec",
                        "OPUS",
                        "^(?:^|.*[^a-z0-9])opus(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))",
                        492,
                        "standardAudio"));
        r.add(
                new Rule(
                        "aud_aac",
                        "audio_codec",
                        "AAC",
                        "^(?:^|.*[^a-z0-9])(?:(?:he[ ._-]?)?aac(?:[ ._-]?lc)?(?:(?![a-z0-9])|(?=[125678]\\.[01](?![0-9])))|mp4a(?:\\.40\\.[0-9]+)?(?![a-z0-9]))",
                        495,
                        "standardAudio"));
        r.add(
                new Rule(
                        "ch_7_1",
                        "audio_channels",
                        "7.1",
                        "^(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))",
                        510,
                        "standardAudio"));
        r.add(
                new Rule(
                        "ch_5_1",
                        "audio_channels",
                        "5.1",
                        "^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))5\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])6[ ]*ch(?:annels?)?(?![a-z0-9]))",
                        520,
                        "standardAudio"));
        r.add(
                new Rule(
                        "ch_2_0",
                        "audio_channels",
                        "2.0",
                        "^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))[57]\\.1(?:\\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])[68][ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))2\\.0(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])(?:2[ ]*ch(?:annels?)?|stereo)(?![a-z0-9])|.*(?:立体声|双声道))",
                        530,
                        "standardAudio"));
        r.add(
                new Rule(
                        "vid_av1",
                        "video_codec",
                        "AV1",
                        "^(?:^|.*[^a-z0-9])(?:(?:svt[ ._-]?)?av1|(?:av01|dav1)(?:\\.[0-9a-z.]+)?)(?![a-z0-9])",
                        610,
                        "codecSlate"));
        r.add(
                new Rule(
                        "vid_hevc",
                        "video_codec",
                        "HEVC",
                        "^(?:^|.*[^a-z0-9])(?:hevc|[hx][ ._-]?265|h(?:ev|vc)1(?:\\.[0-9a-z.]+)?)(?![a-z0-9])",
                        620,
                        "codecSlate"));
        r.add(
                new Rule(
                        "vid_vp9",
                        "video_codec",
                        "VP9",
                        "^(?:^|.*[^a-z0-9])(?:vp9|vp09(?:\\.[0-9a-z.]+)?)(?![a-z0-9])",
                        630,
                        "codecSlate"));
        r.add(
                new Rule(
                        "vid_avc",
                        "video_codec",
                        "AVC",
                        "^(?:^|.*[^a-z0-9])(?:avc|[hx][ ._-]?264|avc1(?:\\.[0-9a-z]+)?)(?![a-z0-9])",
                        640,
                        "codecSlate"));
        r.add(
                new Rule(
                        "plt_nf",
                        "release_platform",
                        "NF",
                        "^(?:^|.*[^a-z0-9])(?:netflix|nflx|nf)(?![a-z0-9])",
                        710,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_amzn",
                        "release_platform",
                        "AMZN",
                        "^(?:^|.*[^a-z0-9])(?:amzn|amazon|prime[ ._-]?video)(?![a-z0-9])",
                        715,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_atvp",
                        "release_platform",
                        "ATVP",
                        "^(?:^|.*[^a-z0-9])(?:(?:atvp|aptv)(?![a-z0-9])|apple[ ._-]?tv\\+(?![a-z0-9])|apple[ ._-]?tv(?![a-z0-9+]))",
                        720,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_dsnp",
                        "release_platform",
                        "DSNP",
                        "^(?:^|.*[^a-z0-9])(?:(?:dsnp|dsny)(?![a-z0-9])|disney\\+(?![a-z0-9])|disney[ ._-]?plus(?![a-z0-9]))",
                        725,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_max",
                        "release_platform",
                        "MAX",
                        "^(?:^|.*[^a-z0-9])(?:hmax(?![a-z0-9])|hbo[ ._-]?max(?![a-z0-9])|max(?=[ ._-]+(?:2160[pi]|1080[pi]|720[pi]|4k|web[ ._-]?(?:dl|rip))(?![a-z0-9])))",
                        730,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_hulu",
                        "release_platform",
                        "HULU",
                        "^(?:^|.*[^a-z0-9])hulu(?![a-z0-9])",
                        735,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_pcok",
                        "release_platform",
                        "PCOK",
                        "^(?:^|.*[^a-z0-9])(?:pcok|peacock)(?![a-z0-9])",
                        740,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_pmtp",
                        "release_platform",
                        "PMTP",
                        "^(?:^|.*[^a-z0-9])(?:(?:pmtp|pamp)(?![a-z0-9])|paramount\\+(?![a-z0-9])|paramount[ ._-]?plus(?![a-z0-9]))",
                        745,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_bili",
                        "release_platform",
                        "BILI",
                        "^(?:(?:^|.*[^a-z0-9])(?:bili(?:bili)?|b[ ._-]?global)(?![a-z0-9])|(?:^|.*[^a-z0-9])b站(?!点))",
                        750,
                        "platformTag"));
        r.add(
                new Rule(
                        "plt_cr",
                        "release_platform",
                        "CR",
                        "^(?:(?:^|.*[^a-z0-9])crunchyroll(?![a-z0-9])|.*\\[cr\\]|(?:^|.*[^a-z0-9])cr(?=[ ._-]+(?:1080[pi]|720[pi]|web[ ._-]?(?:dl|rip))(?![a-z0-9])))",
                        755,
                        "platformTag"));
        RULES = Collections.unmodifiableList(r);
        Map<String, Rule> byId = new HashMap<String, Rule>(64);
        for (int i = 0; i < r.size(); i++) {
            Rule rule = r.get(i);
            byId.put(rule.id, rule);
        }
        RULE_BY_ID = Collections.unmodifiableMap(byId);

        List<ComboRule> c = new ArrayList<ComboRule>(3);
        c.add(
                new ComboRule(
                        "combo_dv_atmos",
                        "dynamic_range",
                        "DV · ATMOS",
                        new String[] {"dr_dv", "aud_atmos"},
                        new String[] {"dr_dv", "aud_atmos"},
                        205,
                        "premiumCombo"));
        c.add(
                new ComboRule(
                        "combo_dv_truehd",
                        "dynamic_range",
                        "DV · TrueHD",
                        new String[] {"dr_dv", "aud_truehd"},
                        new String[] {"dr_dv", "aud_truehd"},
                        206,
                        "premiumCombo"));
        c.add(
                new ComboRule(
                        "combo_dv_ddp",
                        "dynamic_range",
                        "DV · DD+",
                        new String[] {"dr_dv", "aud_ddp"},
                        new String[] {"dr_dv", "aud_ddp"},
                        207,
                        "premiumCombo"));
        COMBO_RULES = Collections.unmodifiableList(c);
    }

    private LiteBadges() {}

    public static String normalize(String input) {
        if (input == null || input.isEmpty()) {
            return "";
        }
        String decoded = percentDecodePreservePlus(input);
        int len = decoded.length();
        StringBuilder collapsed = new StringBuilder(Math.min(len, MAX_INPUT_CODE_UNITS + 16));
        boolean pendingSpace = false;
        for (int i = 0; i < len; i++) {
            char ch = decoded.charAt(i);
            if (ch <= 0x0020
                    || (ch >= 0x007F && ch <= 0x00A0)
                    || ch == 0x2028
                    || ch == 0x2029
                    || ch == 0x3000
                    || ch == 0xFEFF) {
                if (collapsed.length() > 0) {
                    pendingSpace = true;
                }
            } else {
                if (pendingSpace) {
                    collapsed.append(' ');
                    pendingSpace = false;
                }
                collapsed.append(ch);
            }
        }
        int start = 0;
        int end = collapsed.length();
        while (start < end && collapsed.charAt(start) == ' ') start++;
        while (end > start && collapsed.charAt(end - 1) == ' ') end--;
        if (start >= end) {
            return "";
        }
        int maxEnd = start + MAX_INPUT_CODE_UNITS;
        if (end > maxEnd) {
            end = maxEnd;
            char last = collapsed.charAt(end - 1);
            if (last >= 0xD800 && last <= 0xDBFF) {
                end--;
            }
            while (end > start && collapsed.charAt(end - 1) == ' ') {
                end--;
            }
        }
        return collapsed.substring(start, end);
    }

    private static String percentDecodePreservePlus(String input) {
        int pct = input.indexOf('%');
        if (pct < 0) {
            return input;
        }
        int len = input.length();
        StringBuilder out = new StringBuilder(len);
        out.append(input, 0, pct);
        ByteArrayOutputStream byteBuf = new ByteArrayOutputStream(32);
        CharsetDecoder decoder = null;
        int i = pct;
        while (i < len) {
            char ch = input.charAt(i);
            if (ch == '%' && i + 2 < len) {
                int hi = hexDigit(input.charAt(i + 1));
                int lo = hexDigit(input.charAt(i + 2));
                if (hi >= 0 && lo >= 0) {
                    byteBuf.reset();
                    while (i + 2 < len && input.charAt(i) == '%') {
                        int h = hexDigit(input.charAt(i + 1));
                        int l = hexDigit(input.charAt(i + 2));
                        if (h < 0 || l < 0) break;
                        byteBuf.write((h << 4) | l);
                        i += 3;
                    }
                    if (decoder == null) {
                        decoder =
                                UTF8.newDecoder()
                                        .onMalformedInput(CodingErrorAction.REPLACE)
                                        .onUnmappableCharacter(CodingErrorAction.REPLACE);
                    } else {
                        decoder.reset();
                    }
                    try {
                        out.append(decoder.decode(ByteBuffer.wrap(byteBuf.toByteArray())));
                    } catch (Exception e) {
                        out.append('\uFFFD');
                    }
                    continue;
                }
            }
            out.append(ch);
            i++;
        }
        return out.toString();
    }

    private static int hexDigit(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    public static List<Badge> extract(String input) {
        if (input == null || input.isEmpty()) {
            return Collections.emptyList();
        }
        String norm = normalize(input);
        if (norm.isEmpty()) {
            return Collections.emptyList();
        }
        synchronized (CACHE) {
            List<Badge> cached = CACHE.get(norm);
            if (cached != null) {
                return cached;
            }
        }
        Set<String> matched = new HashSet<String>();
        for (int i = 0; i < RULES.size(); i++) {
            Rule r = RULES.get(i);
            if (r.pattern.matcher(norm).find()) {
                matched.add(r.id);
            }
        }
        List<Badge> out;
        if (matched.isEmpty()) {
            out = Collections.emptyList();
        } else {
            List<Badge> list = new ArrayList<Badge>(matched.size());
            for (int i = 0; i < COMBO_RULES.size(); i++) {
                ComboRule combo = COMBO_RULES.get(i);
                boolean allPresent = true;
                for (int j = 0; j < combo.requires.length; j++) {
                    if (!matched.contains(combo.requires[j])) {
                        allPresent = false;
                        break;
                    }
                }
                if (allPresent) {
                    for (int j = 0; j < combo.consumes.length; j++) {
                        matched.remove(combo.consumes[j]);
                    }
                    list.add(combo.badge);
                }
            }
            for (String id : matched) {
                Rule r = RULE_BY_ID.get(id);
                if (r != null) {
                    list.add(r.badge);
                }
            }
            Collections.sort(list, BADGE_ORDER);
            out = Collections.unmodifiableList(list);
        }
        synchronized (CACHE) {
            CACHE.put(norm, out);
        }
        return out;
    }

    /** Formats up to {@code maxBadges} badges joined by {@code " · "} for plain TextView display. */
    public static String formatFromSources(int maxBadges, String... inputs) {
        if (inputs == null || inputs.length == 0 || maxBadges == 0) {
            return "";
        }
        StringBuilder joined = new StringBuilder();
        for (int i = 0; i < inputs.length; i++) {
            String s = inputs[i];
            if (s != null && !s.isEmpty()) {
                if (joined.length() > 0) joined.append(' ');
                joined.append(s);
            }
        }
        if (joined.length() == 0) {
            return "";
        }
        List<Badge> badges = extract(joined.toString());
        if (badges.isEmpty()) {
            return "";
        }
        int limit = maxBadges > 0 ? Math.min(maxBadges, badges.size()) : badges.size();
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < limit; i++) {
            if (i > 0) sb.append(" · ");
            sb.append(badges.get(i).label);
        }
        return sb.toString();
    }
}

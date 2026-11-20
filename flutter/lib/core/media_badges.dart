// SPDX-License-Identifier: GPL-3.0-only
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/services.dart';

/// Immutable plain-text media specification badge parsed from metadata or live tracks.
class MediaBadge {
  const MediaBadge({
    required this.id,
    required this.group,
    required this.label,
    required this.priority,
    required this.style,
  });

  final String id;
  final String group;
  final String label;
  final int priority;
  final String style;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaBadge &&
          id == other.id &&
          group == other.group &&
          label == other.label &&
          priority == other.priority &&
          style == other.style;

  @override
  int get hashCode => Object.hash(id, group, label, priority, style);

  @override
  String toString() => '$label($id)';
}

/// Pure-data live track descriptor for player HUD fusion (M2 / Wave 2).
class MediaTrackSpec {
  const MediaTrackSpec({
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.videoCodec,
    this.dynamicRange,
    this.audioCodec,
    this.audioChannels = 0,
    this.audioChannelLayout,
    this.atmos = false,
  });

  final int videoWidth;
  final int videoHeight;
  final String? videoCodec;
  final String? dynamicRange;
  final String? audioCodec;
  final int audioChannels;
  final String? audioChannelLayout;
  final bool atmos;

  String toSyntheticTokens() {
    final parts = <String>[];
    if (videoWidth >= 7000 || videoHeight >= 4000) {
      parts.add('4320p');
    } else if (videoWidth >= 3600 || videoHeight >= 2000) {
      parts.add('2160p');
    } else if (videoWidth >= 2400 || videoHeight >= 1350) {
      parts.add('1440p');
    } else if (videoWidth >= 1800 || videoHeight >= 1000) {
      parts.add('1080p');
    } else if (videoWidth >= 1200 || videoHeight >= 700) {
      parts.add('720p');
    } else if (videoWidth > 0 || videoHeight > 0) {
      parts.add('480p');
    }
    if (dynamicRange != null && dynamicRange!.isNotEmpty) {
      parts.add(dynamicRange!);
    }
    if (videoCodec != null && videoCodec!.isNotEmpty) {
      parts.add(videoCodec!);
    }
    if (audioCodec != null && audioCodec!.isNotEmpty) {
      parts.add(audioCodec!);
    }
    if (atmos) {
      parts.add('Atmos');
    }
    if (audioChannelLayout != null && audioChannelLayout!.isNotEmpty) {
      parts.add(audioChannelLayout!);
    } else if (audioChannels >= 8) {
      parts.add('7.1');
    } else if (audioChannels >= 6) {
      parts.add('5.1');
    } else if (audioChannels == 2) {
      parts.add('2.0');
    }
    return parts.join(' ');
  }
}

class _BadgeRule {
  _BadgeRule({
    required this.id,
    required this.group,
    required this.label,
    required String pattern,
    required this.priority,
    required this.style,
    bool registerStandard = false,
  })  : regExp = RegExp(pattern, caseSensitive: false),
        anyRequiredTokens = registerStandard
            ? (_registerStandardPattern(id, pattern))
            : _requiredTokensForStandardRule(id, pattern),
        badge = MediaBadge(
          id: id,
          group: group,
          label: label,
          priority: priority,
          style: style,
        );

  static List<String>? _registerStandardPattern(String id, String pattern) {
    _standardRulePatterns[id] = pattern;
    return _standardRuleHints[id];
  }

  final String id;
  final String group;
  final String label;
  final RegExp regExp;
  final List<String>? anyRequiredTokens;
  final int priority;
  final String style;
  final MediaBadge badge;

  bool couldMatch(String lower) {
    final tokens = anyRequiredTokens;
    if (tokens == null) return true;
    for (var i = 0; i < tokens.length; i++) {
      if (lower.contains(tokens[i])) return true;
    }
    return false;
  }

  static List<String>? _requiredTokensForStandardRule(String id, String pattern) {
    final expected = _standardRulePatterns[id];
    if (expected == null || expected != pattern) return null;
    return _standardRuleHints[id];
  }

  static const Map<String, List<String>> _standardRuleHints = <String, List<String>>{
    'res_8k': <String>['8k', '4320', 'fuhd'],
    'res_4k': <String>['4k', '2160', 'uhd', '3840', '4096', 'ultra'],
    'res_2k': <String>['2k', '1440', 'qhd', '2560'],
    'res_1080p': <String>['1080', 'fhd', '1920', 'full'],
    'res_720p': <String>['720', '1280'],
    'res_sd': <String>['480', '576', 'sd', '标清'],
    'dr_dv': <String>['dv', 'dovi', 'dolby', 'dav1', '杜比'],
    'dr_hdr10plus': <String>['hdr10'],
    'dr_hdr10': <String>['hdr', '2084'],
    'dr_hlg': <String>['hlg', 'b67'],
    'dr_hdr': <String>['hdr', '2020', '臻彩'],
    'src_remux': <String>['remux'],
    'src_bluray': <String>['blu', 'bd', 'brrip', '原盘'],
    'src_webdl': <String>['web'],
    'src_webrip': <String>['web'],
    'src_hdtv': <String>['hdtv', 'pdtv', 'dsr'],
    'aud_atmos': <String>['atmos', 'joc', 'ec+3', '全景声'],
    'aud_dtsx': <String>['dts'],
    'aud_truehd': <String>['true', 'mlp'],
    'aud_dtshd_ma': <String>['dts'],
    'aud_dtshd': <String>['dts'],
    'aud_dts': <String>['dts'],
    'aud_ddp': <String>['dd+', 'ddp', 'ac', 'ec', 'dolby'],
    'aud_dd': <String>['dd', 'ac', 'dolby'],
    'aud_lpcm': <String>['pcm'],
    'aud_flac': <String>['flac'],
    'aud_opus': <String>['opus'],
    'aud_aac': <String>['aac', 'mp4a'],
    'ch_7_1': <String>['7.1', '8'],
    'ch_5_1': <String>['5.1', '6'],
    'ch_2_0': <String>['2.0', '2', 'stereo', '立体声', '双声道'],
    'vid_av1': <String>['av1', 'av01', 'dav1'],
    'vid_hevc': <String>['hevc', '265', 'hev1', 'hvc1'],
    'vid_vp9': <String>['vp9', 'vp09'],
    'vid_avc': <String>['avc', '264'],
    'plt_nf': <String>['nf', 'netflix', 'nflx'],
    'plt_amzn': <String>['amzn', 'amazon', 'prime'],
    'plt_atvp': <String>['atvp', 'aptv', 'apple'],
    'plt_dsnp': <String>['dsnp', 'dsny', 'disney'],
    'plt_max': <String>['max'],
    'plt_hulu': <String>['hulu'],
    'plt_pcok': <String>['pcok', 'peacock'],
    'plt_pmtp': <String>['pmtp', 'pamp', 'paramount'],
    'plt_bili': <String>['bili', 'global', 'b站'],
    'plt_cr': <String>['cr'],
  };

  static final Map<String, String> _standardRulePatterns = <String, String>{};
}

class _ComboRule {
  _ComboRule({
    required this.id,
    required this.group,
    required this.label,
    required this.requires,
    required this.consumes,
    required this.priority,
    required this.style,
  }) : badge = MediaBadge(
          id: id,
          group: group,
          label: label,
          priority: priority,
          style: style,
        );

  final String id;
  final String group;
  final String label;
  final List<String> requires;
  final List<String> consumes;
  final int priority;
  final String style;
  final MediaBadge badge;
}

/// Cross-platform media specification badge engine implementing
/// `shared/ui-spec/badge-rules.json` (schemaVersion 1).
class MediaBadges {
  MediaBadges._(List<_BadgeRule> rules, List<_ComboRule> comboRules)
      : _rules = List<_BadgeRule>.unmodifiable(rules),
        _ruleById = Map<String, _BadgeRule>.unmodifiable({
          for (final r in rules) r.id: r,
        }),
        _comboRules = List<_ComboRule>.unmodifiable(
          List<_ComboRule>.of(comboRules)
            ..sort((a, b) {
              final c = a.priority.compareTo(b.priority);
              return c != 0 ? c : a.id.compareTo(b.id);
            }),
        );

  static const int maxInputCodeUnits = 1024;
  static const int lruCacheCapacity = 256;
  static const String assetPath = 'assets/ui-spec/badge-rules.json';

  static MediaBadges? _defaultInstance;
  static Future<void>? _assetInitFuture;

  final List<_BadgeRule> _rules;
  final Map<String, _BadgeRule> _ruleById;
  final List<_ComboRule> _comboRules;
  final LinkedHashMap<String, List<MediaBadge>> _cache =
      LinkedHashMap<String, List<MediaBadge>>();

  static MediaBadges get instance => _defaultInstance ??= _buildBuiltinDefault();

  /// Loads `assets/ui-spec/badge-rules.json` from the Flutter asset bundle once.
  static Future<void> ensureInitialized() {
    return _assetInitFuture ??= _loadFromBundle();
  }

  static Future<void> _loadFromBundle() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      _defaultInstance = MediaBadges.fromJson(raw);
    } catch (_) {
      // Built-in default rules match shared/ui-spec/badge-rules.json 1:1.
    }
  }

  factory MediaBadges.fromJson(String jsonSource) {
    // Ensure built-in pattern table is registered so identical standard rules
    // safely reuse pre-filter hints while custom rules run unfiltered.
    if (_BadgeRule._standardRulePatterns.isEmpty) {
      instance;
    }
    final root = jsonDecode(jsonSource) as Map<String, dynamic>;
    final rulesJson = root['rules'] as List<dynamic>;
    final parsedRules = <_BadgeRule>[
      for (final item in rulesJson)
        _BadgeRule(
          id: (item as Map<String, dynamic>)['id'] as String,
          group: item['group'] as String,
          label: item['label'] as String,
          pattern: item['pattern'] as String,
          priority: (item['priority'] as num).toInt(),
          style: item['style'] as String,
        ),
    ];
    final comboJson = (root['comboRules'] as List<dynamic>?) ?? const <dynamic>[];
    final parsedCombos = <_ComboRule>[
      for (final item in comboJson)
        _ComboRule(
          id: (item as Map<String, dynamic>)['id'] as String,
          group: item['group'] as String,
          label: item['label'] as String,
          requires: ((item['requires'] as List<dynamic>).cast<String>()),
          consumes: ((item['consumes'] as List<dynamic>).cast<String>()),
          priority: (item['priority'] as num).toInt(),
          style: item['style'] as String,
        ),
    ];
    return MediaBadges._(parsedRules, parsedCombos);
  }

  /// Normalizes input per `badge-rules.json` `evaluationContract.normalization`.
  static String normalize(String? input) {
    if (input == null || input.isEmpty) {
      return '';
    }
    final decoded = _percentDecodeUtf8PreservePlus(input);
    final len = decoded.length;
    if (len <= maxInputCodeUnits) {
      var clean = true;
      var prevSpace = true;
      for (var i = 0; i < len; i++) {
        final ch = decoded.codeUnitAt(i);
        if (ch == 0x20) {
          if (prevSpace) {
            clean = false;
            break;
          }
          prevSpace = true;
        } else if (_isCollapsibleWhitespace(ch)) {
          clean = false;
          break;
        } else {
          prevSpace = false;
        }
      }
      if (clean && !prevSpace) {
        return decoded;
      }
    }
    final collapsed = StringBuffer();
    var pendingSpace = false;
    for (var i = 0; i < len; i++) {
      final ch = decoded.codeUnitAt(i);
      if (_isCollapsibleWhitespace(ch)) {
        if (collapsed.isNotEmpty) {
          pendingSpace = true;
        }
      } else {
        if (pendingSpace) {
          collapsed.writeCharCode(0x20);
          pendingSpace = false;
        }
        collapsed.writeCharCode(ch);
      }
    }
    var result = collapsed.toString();
    var start = 0;
    var end = result.length;
    while (start < end && result.codeUnitAt(start) == 0x20) {
      start++;
    }
    while (end > start && result.codeUnitAt(end - 1) == 0x20) {
      end--;
    }
    if (start >= end) {
      return '';
    }
    final maxEnd = start + maxInputCodeUnits;
    if (end > maxEnd) {
      end = maxEnd;
      final last = result.codeUnitAt(end - 1);
      if (last >= 0xD800 && last <= 0xDBFF) {
        end--;
      }
      while (end > start && result.codeUnitAt(end - 1) == 0x20) {
        end--;
      }
    }
    return result.substring(start, end);
  }

  static bool _isCollapsibleWhitespace(int ch) {
    return ch <= 0x0020 ||
        (ch >= 0x007F && ch <= 0x00A0) ||
        ch == 0x2028 ||
        ch == 0x2029 ||
        ch == 0x3000 ||
        ch == 0xFEFF;
  }

  static String _percentDecodeUtf8PreservePlus(String input) {
    final firstPct = input.indexOf('%');
    if (firstPct < 0) return input;
    final len = input.length;
    final out = StringBuffer();
    if (firstPct > 0) {
      out.write(input.substring(0, firstPct));
    }
    var i = firstPct;
    while (i < len) {
      final cu = input.codeUnitAt(i);
      if (cu == 0x25 && i + 2 < len) {
        final hi = _hexDigit(input.codeUnitAt(i + 1));
        final lo = _hexDigit(input.codeUnitAt(i + 2));
        if (hi >= 0 && lo >= 0) {
          final bytes = <int>[];
          while (i + 2 < len && input.codeUnitAt(i) == 0x25) {
            final h = _hexDigit(input.codeUnitAt(i + 1));
            final l = _hexDigit(input.codeUnitAt(i + 2));
            if (h < 0 || l < 0) break;
            bytes.add((h << 4) | l);
            i += 3;
          }
          out.write(utf8.decode(bytes, allowMalformed: true));
          continue;
        }
      }
      out.writeCharCode(cu);
      i++;
    }
    return out.toString();
  }

  static int _hexDigit(int cu) {
    if (cu >= 0x30 && cu <= 0x39) return cu - 0x30;
    if (cu >= 0x61 && cu <= 0x66) return cu - 0x61 + 10;
    if (cu >= 0x41 && cu <= 0x46) return cu - 0x41 + 10;
    return -1;
  }

  List<MediaBadge> extract(String? input) {
    if (input == null || input.isEmpty) {
      return const <MediaBadge>[];
    }
    final norm = normalize(input);
    if (norm.isEmpty) {
      return const <MediaBadge>[];
    }
    final cached = _cache.remove(norm);
    if (cached != null) {
      _cache[norm] = cached;
      return cached;
    }
    final matched = _matchBaseRules(norm);
    final result = _finalizeBadges(matched);
    if (_cache.length >= lruCacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
    _cache[norm] = result;
    return result;
  }

  List<MediaBadge> extractFromSources(Iterable<String?> inputs) {
    final buf = StringBuffer();
    for (final s in inputs) {
      if (s != null && s.isNotEmpty) {
        if (buf.isNotEmpty) buf.writeCharCode(0x20);
        buf.write(s);
      }
    }
    return extract(buf.toString());
  }

  /// Pure-data fusion API combining filename/line/URL metadata with live player track specs.
  List<MediaBadge> fuse({
    Iterable<String?> sources = const <String?>[],
    MediaTrackSpec? track,
  }) {
    final buf = StringBuffer();
    for (final s in sources) {
      if (s != null && s.isNotEmpty) {
        if (buf.isNotEmpty) buf.writeCharCode(0x20);
        buf.write(s);
      }
    }
    final normSrc = normalize(buf.toString());
    var matched = normSrc.isEmpty ? <String>{} : _matchBaseRules(normSrc);
    if (track != null) {
      final normTrack = normalize(track.toSyntheticTokens());
      if (normTrack.isNotEmpty) {
        final trackMatched = _matchBaseRules(normTrack);
        if (trackMatched.isNotEmpty) {
          final hasTrackRes = _hasGroup(trackMatched, 'resolution');
          final hasTrackCh = _hasGroup(trackMatched, 'audio_channels');
          final hasTrackVid = _hasGroup(trackMatched, 'video_codec');
          final hasTrackConcreteAud = _hasConcreteAudioCodec(trackMatched);
          final trackAllowsAtmos = trackMatched.contains('aud_atmos') ||
              trackMatched.contains('aud_truehd') ||
              trackMatched.contains('aud_ddp');
          final hasTrackNonDvDr = _hasNonDvDynamicRange(trackMatched);
          if (hasTrackRes ||
              hasTrackCh ||
              hasTrackVid ||
              hasTrackConcreteAud ||
              hasTrackNonDvDr) {
            matched = matched.where((id) {
              final r = _ruleById[id];
              if (r == null) return false;
              if (hasTrackRes && r.group == 'resolution') return false;
              if (hasTrackCh && r.group == 'audio_channels') return false;
              if (hasTrackVid && r.group == 'video_codec') return false;
              if (hasTrackConcreteAud && r.group == 'audio_codec') {
                if (!(id == 'aud_atmos' && trackAllowsAtmos)) return false;
              }
              if (hasTrackNonDvDr &&
                  r.group == 'dynamic_range' &&
                  id != 'dr_dv') {
                return false;
              }
              return true;
            }).toSet();
          }
          matched.addAll(trackMatched);
          _reconcileDynamicRangeHierarchy(matched);
        }
      }
    }
    return _finalizeBadges(matched);
  }

  bool _hasConcreteAudioCodec(Set<String> ids) {
    for (final id in ids) {
      if (id == 'aud_atmos') continue;
      final r = _ruleById[id];
      if (r != null && r.group == 'audio_codec') return true;
    }
    return false;
  }

  bool _hasNonDvDynamicRange(Set<String> ids) {
    for (final id in ids) {
      if (id == 'dr_dv') continue;
      final r = _ruleById[id];
      if (r != null && r.group == 'dynamic_range') return true;
    }
    return false;
  }

  static void _reconcileDynamicRangeHierarchy(Set<String> matched) {
    if (matched.contains('dr_hdr10plus')) {
      matched.remove('dr_hdr10');
      matched.remove('dr_hdr');
    } else if (matched.contains('dr_hdr10') || matched.contains('dr_hlg')) {
      matched.remove('dr_hdr');
    }
  }

  bool _hasGroup(Set<String> ids, String group) {
    for (final id in ids) {
      final r = _ruleById[id];
      if (r != null && r.group == group) return true;
    }
    return false;
  }

  Set<String> _matchBaseRules(String norm) {
    final lower = norm.toLowerCase();
    final matched = <String>{};
    for (var i = 0; i < _rules.length; i++) {
      final r = _rules[i];
      if (r.couldMatch(lower) && r.regExp.hasMatch(norm)) {
        matched.add(r.id);
      }
    }
    return matched;
  }

  List<MediaBadge> _finalizeBadges(Set<String> matched) {
    if (matched.isEmpty) {
      return const <MediaBadge>[];
    }
    final out = <MediaBadge>[];
    for (final combo in _comboRules) {
      var allPresent = true;
      for (final req in combo.requires) {
        if (!matched.contains(req)) {
          allPresent = false;
          break;
        }
      }
      if (allPresent) {
        for (final cons in combo.consumes) {
          matched.remove(cons);
        }
        out.add(combo.badge);
      }
    }
    for (final id in matched) {
      final r = _ruleById[id];
      if (r != null) {
        out.add(r.badge);
      }
    }
    out.sort((a, b) {
      final c = a.priority.compareTo(b.priority);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return List<MediaBadge>.unmodifiable(out);
  }

  int get cacheSize => _cache.length;

  void clearCache() => _cache.clear();

  static List<MediaBadge> extractBadges(String? input) =>
      instance.extract(input);

  static List<MediaBadge> extractBadgesFromSources(Iterable<String?> inputs) =>
      instance.extractFromSources(inputs);

  static List<MediaBadge> fuseBadges({
    Iterable<String?> sources = const <String?>[],
    MediaTrackSpec? track,
  }) =>
      instance.fuse(sources: sources, track: track);

  static String formatDotJoined(List<MediaBadge> badges, {int maxBadges = 4}) {
    if (badges.isEmpty || maxBadges == 0) return '';
    final limit =
        maxBadges > 0 && maxBadges < badges.length ? maxBadges : badges.length;
    return badges.take(limit).map((b) => b.label).join(' · ');
  }

  static MediaBadges _buildBuiltinDefault() {
    _BadgeRule std({
      required String id,
      required String group,
      required String label,
      required String pattern,
      required int priority,
      required String style,
    }) =>
        _BadgeRule(
          id: id,
          group: group,
          label: label,
          pattern: pattern,
          priority: priority,
          style: style,
          registerStandard: true,
        );
    final r = <_BadgeRule>[
      std(
        id: 'res_8k',
        group: 'resolution',
        label: '8K',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1440[pi]|2k|qhd|wqhd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|2560|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:4320[pi]|8k|fuhd|7680[ ]*[x×][ ]*4320[pi]?)(?![a-z0-9])',
        priority: 100,
        style: 'uhdGold',
      ),
      std(
        id: 'res_4k',
        group: 'resolution',
        label: '4K',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|(?:3840|4096)[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])',
        priority: 110,
        style: 'uhdGold',
      ),
      std(
        id: 'res_2k',
        group: 'resolution',
        label: '2K',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:2160[pi]|4k|uhd|ultra[ ._-]?hd|1080[pi]|fhd|full[ ._-]?hd|720[pi]|hd720|(?:480|576)[pi]|(?:3840|4096|1920|1280)[ ]*[x×][ ]*[0-9]{3,4}[pi]?|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)|标清))(?!(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:1440[pi]|2k|qhd|wqhd|2560[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])',
        priority: 120,
        style: 'hdCyan',
      ),
      std(
        id: 'res_1080p',
        group: 'resolution',
        label: '1080p',
        pattern:
            r'^(?:(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])|.*(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|.*[^a-z0-9])1080[ ]*(?:高码|蓝光|超清))',
        priority: 130,
        style: 'hdCyan',
      ),
      std(
        id: 'res_720p',
        group: 'resolution',
        label: '720p',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:^|.*[^a-z0-9])(?:720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9])',
        priority: 140,
        style: 'sdNeutral',
      ),
      std(
        id: 'res_sd',
        group: 'resolution',
        label: 'SD',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:1080[pi]|fhd|full[ ._-]?hd|1920[ ]*[x×][ ]*[0-9]{3,4}[pi]?|720[pi]|hd720|1280[ ]*[x×][ ]*[0-9]{3,4}[pi]?)(?![a-z0-9]))(?!.*(?:(?:蓝光|超清|高清|极速|高码)[ ]*1080(?![a-z0-9])|(?:^|[^a-z0-9])1080[ ]*(?:高码|蓝光|超清)))(?:(?:^|.*[^a-z0-9])(?:(?:480|576)[pi]|(?:720|640)[ ]*[x×][ ]*(?:480|576)[pi]?)(?![a-z0-9])|.*标清|(?:^|.*[^a-z0-9/])sd(?![a-z0-9/])(?![ ._-]?cards?(?![a-z0-9])))',
        priority: 150,
        style: 'sdNeutral',
      ),
      std(
        id: 'dr_dv',
        group: 'dynamic_range',
        label: 'DV',
        pattern:
            r'^(?:(?:^|.*[^a-z0-9])(?:dv|dovi|dolby[ ._-]?vision|(?:dvh[e1]|dav1)(?:\.[0-9]{2}(?:\.[0-9]{2})?)?)(?![a-z0-9])|.*杜比视界)',
        priority: 210,
        style: 'visionPurple',
      ),
      std(
        id: 'dr_hdr10plus',
        group: 'dynamic_range',
        label: 'HDR10+',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:hdr10\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9]))',
        priority: 220,
        style: 'visionPurple',
      ),
      std(
        id: 'dr_hdr10',
        group: 'dynamic_range',
        label: 'HDR10',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:hdr10\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])))(?:^|.*[^a-z0-9])(?:hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9]))',
        priority: 230,
        style: 'hdrBlue',
      ),
      std(
        id: 'dr_hlg',
        group: 'dynamic_range',
        label: 'HLG',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:hlg|arib[ ._-]?std[ ._-]?b67)(?![a-z0-9])',
        priority: 240,
        style: 'hdrBlue',
      ),
      std(
        id: 'dr_hdr',
        group: 'dynamic_range',
        label: 'HDR',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:hdr10\+(?![0-9])|hdr10[ ._-]?plus(?![a-z0-9])|hdr10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|hdr[ ._-]10(?![a-z0-9+])(?![ ._-]?bits?(?![a-z0-9]))|smpte[ ._-]?2084(?![a-z0-9])|hlg(?![a-z0-9])|arib[ ._-]?std[ ._-]?b67(?![a-z0-9])|(?:non|no)[ ._-]?hdr(?![a-z0-9])))(?:(?:^|.*[^a-z0-9])(?:hdr(?:[ ._-]?vivid)?(?![a-z0-9])|hdr10[ ._-]?bits?(?![a-z0-9]))|(?=(?:^|.*[^a-z0-9])bt\.?2020(?![a-z0-9]))(?=(?:^|.*[^a-z0-9])pq(?![a-z0-9])).*|.*臻彩)',
        priority: 250,
        style: 'hdrBlue',
      ),
      std(
        id: 'src_remux',
        group: 'source_quality',
        label: 'REMUX',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9])',
        priority: 310,
        style: 'discEmerald',
      ),
      std(
        id: 'src_bluray',
        group: 'source_quality',
        label: 'BluRay',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:(?:bd|uhd)[ ._-]?)?remux(?![a-z0-9]))(?:(?:^|.*[^a-z0-9])(?:(?:blu[ ._-]?ray|bdrip|brrip|bdmv|bdiso|uhdbd|bd(?:25|50|66|100))(?![a-z0-9])|bd(?![a-z0-9])(?!://))|.*(?:蓝光原盘|原盘))',
        priority: 320,
        style: 'discEmerald',
      ),
      std(
        id: 'src_webdl',
        group: 'source_quality',
        label: 'WEB-DL',
        pattern: r'^(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9])',
        priority: 330,
        style: 'streamTeal',
      ),
      std(
        id: 'src_webrip',
        group: 'source_quality',
        label: 'WEBRip',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])web[ ._-]?dl(?![a-z0-9]))(?:^|.*[^a-z0-9])web[ ._-]?rip(?![a-z0-9])',
        priority: 340,
        style: 'streamTeal',
      ),
      std(
        id: 'src_hdtv',
        group: 'source_quality',
        label: 'HDTV',
        pattern: r'^(?:^|.*[^a-z0-9])(?:hdtv(?:rip)?|pdtv|dsr)(?![a-z0-9])',
        priority: 350,
        style: 'streamTeal',
      ),
      std(
        id: 'aud_atmos',
        group: 'audio_codec',
        label: 'ATMOS',
        pattern:
            r'^(?:(?:^|.*[^a-z0-9])(?:atmos(?![a-z0-9])|e[ ._-]?ac[ ._-]?3[ ._-]?joc(?![a-z0-9])|ec\+3(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))|.*(?:杜比)?全景声)',
        priority: 410,
        style: 'spatialAudio',
      ),
      std(
        id: 'aud_dtsx',
        group: 'audio_codec',
        label: 'DTS:X',
        pattern:
            r'^(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 420,
        style: 'spatialAudio',
      ),
      std(
        id: 'aud_truehd',
        group: 'audio_codec',
        label: 'TrueHD',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:true[ ._-]?hd|mlp)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 430,
        style: 'spatialAudio',
      ),
      std(
        id: 'aud_dtshd_ma',
        group: 'audio_codec',
        label: 'DTS-HD MA',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])dts[ ._:+-]?x(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 440,
        style: 'spatialAudio',
      ),
      std(
        id: 'aud_dtshd',
        group: 'audio_codec',
        label: 'DTS-HD',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma|dts[ ._-]?xll)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))(?:^|.*[^a-z0-9])(?:dts[ ._-]?hd(?:[ ._-]?(?:hr|hra))?|dts[ ._-]?(?:hr|hra))(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 450,
        style: 'standardAudio',
      ),
      std(
        id: 'aud_dts',
        group: 'audio_codec',
        label: 'DTS',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:dts[ ._:+-]?x|dts[ ._-]?hd(?:[ ._-]?(?:ma|hr|hra))?|dts[ ._-]?(?:ma|xll|hr|hra))(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))(?:^|.*[^a-z0-9])dts(?:[ ._-]?es)?(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 460,
        style: 'standardAudio',
      ),
      std(
        id: 'aud_ddp',
        group: 'audio_codec',
        label: 'DD+',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:dd\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9]))))',
        priority: 470,
        style: 'standardAudio',
      ),
      std(
        id: 'aud_dd',
        group: 'audio_codec',
        label: 'DD',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9])(?:dd\+|(?:ddp|e[ ._-]?ac[ ._-]?3|ec[ ._-]?3|ec\+3|dolby[ ._-]?digital[ ._-]?plus)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))))(?:(?:^|.*[^a-z0-9])(?:ac[ ._-]?3|dolby[ ._-]?(?:digital|audio))(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))|(?:^|.*[^a-z0-9])dd[ ._-]?[125678]\.[01](?![0-9])|(?:^|.*[^a-z0-9/])dd(?![a-z0-9+/]))',
        priority: 480,
        style: 'standardAudio',
      ),
      std(
        id: 'aud_lpcm',
        group: 'audio_codec',
        label: 'LPCM',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:lpcm|pcm)(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 485,
        style: 'standardAudio',
      ),
      std(
        id: 'aud_flac',
        group: 'audio_codec',
        label: 'FLAC',
        pattern:
            r'^(?:^|.*[^a-z0-9])flac(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 490,
        style: 'standardAudio',
      ),
      std(
        id: 'aud_opus',
        group: 'audio_codec',
        label: 'OPUS',
        pattern:
            r'^(?:^|.*[^a-z0-9])opus(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))',
        priority: 492,
        style: 'standardAudio',
      ),
      std(
        id: 'aud_aac',
        group: 'audio_codec',
        label: 'AAC',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:(?:he[ ._-]?)?aac(?:[ ._-]?lc)?(?:(?![a-z0-9])|(?=[125678]\.[01](?![0-9])))|mp4a(?:\.40\.[0-9]+)?(?![a-z0-9]))',
        priority: 495,
        style: 'standardAudio',
      ),
      std(
        id: 'ch_7_1',
        group: 'audio_channels',
        label: '7.1',
        pattern:
            r'^(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))',
        priority: 510,
        style: 'standardAudio',
      ),
      std(
        id: 'ch_5_1',
        group: 'audio_channels',
        label: '5.1',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))7\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])8[ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))5\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])6[ ]*ch(?:annels?)?(?![a-z0-9]))',
        priority: 520,
        style: 'standardAudio',
      ),
      std(
        id: 'ch_2_0',
        group: 'audio_channels',
        label: '2.0',
        pattern:
            r'^(?!(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))[57]\.1(?:\.[24])?(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9])))(?!(?:^|.*[^a-z0-9])[68][ ]*ch(?:annels?)?(?![a-z0-9]))(?:(?:^|.*[^a-z0-9.]|.*(?:[a-z]|(?:19|20)[0-9]{2}|e?ac[ ._-]?3|ec[ ._+-]?3|[hx][ ._-]?26[45]|av0?1|vp0?9)\.|.*(?:ddp|dd|aac|dts|truehd|flac|lpcm|pcm|opus))2\.0(?:[ ]?ch(?:annels?)?)?(?![a-z0-9])(?![ ]*(?:gb|mb|kb|tb|gib|mib|fps|hz|khz|mhz)(?![a-z0-9]))|(?:^|.*[^a-z0-9])(?:2[ ]*ch(?:annels?)?|stereo)(?![a-z0-9])|.*(?:立体声|双声道))',
        priority: 530,
        style: 'standardAudio',
      ),
      std(
        id: 'vid_av1',
        group: 'video_codec',
        label: 'AV1',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:(?:svt[ ._-]?)?av1|(?:av01|dav1)(?:\.[0-9a-z.]+)?)(?![a-z0-9])',
        priority: 610,
        style: 'codecSlate',
      ),
      std(
        id: 'vid_hevc',
        group: 'video_codec',
        label: 'HEVC',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:hevc|[hx][ ._-]?265|h(?:ev|vc)1(?:\.[0-9a-z.]+)?)(?![a-z0-9])',
        priority: 620,
        style: 'codecSlate',
      ),
      std(
        id: 'vid_vp9',
        group: 'video_codec',
        label: 'VP9',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:vp9|vp09(?:\.[0-9a-z.]+)?)(?![a-z0-9])',
        priority: 630,
        style: 'codecSlate',
      ),
      std(
        id: 'vid_avc',
        group: 'video_codec',
        label: 'AVC',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:avc|[hx][ ._-]?264|avc1(?:\.[0-9a-z]+)?)(?![a-z0-9])',
        priority: 640,
        style: 'codecSlate',
      ),
      std(
        id: 'plt_nf',
        group: 'release_platform',
        label: 'NF',
        pattern: r'^(?:^|.*[^a-z0-9])(?:netflix|nflx|nf)(?![a-z0-9])',
        priority: 710,
        style: 'platformTag',
      ),
      std(
        id: 'plt_amzn',
        group: 'release_platform',
        label: 'AMZN',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:amzn|amazon|prime[ ._-]?video)(?![a-z0-9])',
        priority: 715,
        style: 'platformTag',
      ),
      std(
        id: 'plt_atvp',
        group: 'release_platform',
        label: 'ATVP',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:(?:atvp|aptv)(?![a-z0-9])|apple[ ._-]?tv\+(?![a-z0-9])|apple[ ._-]?tv(?![a-z0-9+]))',
        priority: 720,
        style: 'platformTag',
      ),
      std(
        id: 'plt_dsnp',
        group: 'release_platform',
        label: 'DSNP',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:(?:dsnp|dsny)(?![a-z0-9])|disney\+(?![a-z0-9])|disney[ ._-]?plus(?![a-z0-9]))',
        priority: 725,
        style: 'platformTag',
      ),
      std(
        id: 'plt_max',
        group: 'release_platform',
        label: 'MAX',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:hmax(?![a-z0-9])|hbo[ ._-]?max(?![a-z0-9])|max(?=[ ._-]+(?:2160[pi]|1080[pi]|720[pi]|4k|web[ ._-]?(?:dl|rip))(?![a-z0-9])))',
        priority: 730,
        style: 'platformTag',
      ),
      std(
        id: 'plt_hulu',
        group: 'release_platform',
        label: 'HULU',
        pattern: r'^(?:^|.*[^a-z0-9])hulu(?![a-z0-9])',
        priority: 735,
        style: 'platformTag',
      ),
      std(
        id: 'plt_pcok',
        group: 'release_platform',
        label: 'PCOK',
        pattern: r'^(?:^|.*[^a-z0-9])(?:pcok|peacock)(?![a-z0-9])',
        priority: 740,
        style: 'platformTag',
      ),
      std(
        id: 'plt_pmtp',
        group: 'release_platform',
        label: 'PMTP',
        pattern:
            r'^(?:^|.*[^a-z0-9])(?:(?:pmtp|pamp)(?![a-z0-9])|paramount\+(?![a-z0-9])|paramount[ ._-]?plus(?![a-z0-9]))',
        priority: 745,
        style: 'platformTag',
      ),
      std(
        id: 'plt_bili',
        group: 'release_platform',
        label: 'BILI',
        pattern:
            r'^(?:(?:^|.*[^a-z0-9])(?:bili(?:bili)?|b[ ._-]?global)(?![a-z0-9])|(?:^|.*[^a-z0-9])b站(?!点))',
        priority: 750,
        style: 'platformTag',
      ),
      std(
        id: 'plt_cr',
        group: 'release_platform',
        label: 'CR',
        pattern:
            r'^(?:(?:^|.*[^a-z0-9])crunchyroll(?![a-z0-9])|.*\[cr\]|(?:^|.*[^a-z0-9])cr(?=[ ._-]+(?:1080[pi]|720[pi]|web[ ._-]?(?:dl|rip))(?![a-z0-9])))',
        priority: 755,
        style: 'platformTag',
      ),
    ];
    final c = <_ComboRule>[
      _ComboRule(
        id: 'combo_dv_atmos',
        group: 'dynamic_range',
        label: 'DV · ATMOS',
        requires: const <String>['dr_dv', 'aud_atmos'],
        consumes: const <String>['dr_dv', 'aud_atmos'],
        priority: 205,
        style: 'premiumCombo',
      ),
      _ComboRule(
        id: 'combo_dv_truehd',
        group: 'dynamic_range',
        label: 'DV · TrueHD',
        requires: const <String>['dr_dv', 'aud_truehd'],
        consumes: const <String>['dr_dv', 'aud_truehd'],
        priority: 206,
        style: 'premiumCombo',
      ),
      _ComboRule(
        id: 'combo_dv_ddp',
        group: 'dynamic_range',
        label: 'DV · DD+',
        requires: const <String>['dr_dv', 'aud_ddp'],
        consumes: const <String>['dr_dv', 'aud_ddp'],
        priority: 207,
        style: 'premiumCombo',
      ),
    ];
    return MediaBadges._(r, c);
  }
}

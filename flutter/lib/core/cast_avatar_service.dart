import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// A single cast or crew member displayed in the avatar carousel on the Detail
/// and Portrait Player screens.
class CastMember {
  final String name;
  final String role;
  final String avatarUrl;

  const CastMember({
    required this.name,
    this.role = '',
    this.avatarUrl = '',
  });
}

/// Resolves real actor/director portraits using public Douban metadata
/// endpoints (strictly within the repository's allowed metadata hosts) with
/// graceful fallback to parsed [actorRaw] names from CMS sources.
class CastAvatarService {
  CastAvatarService._();

  static const String _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const int _maxCache = 220;
  static final LinkedHashMap<String, List<CastMember>> _cache =
      LinkedHashMap<String, List<CastMember>>();
  static final Map<String, Future<List<CastMember>>> _inflight = {};
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 20)
    ..autoUncompress = true;

  /// Parses raw CMS `vod_actor` strings (`"张三, 李四 / 王五"`) into immediate
  /// placeholder [CastMember] items so the UI renders without layout jump
  /// before remote avatars arrive.
  static List<CastMember> parseRawActors(String actorRaw) {
    final cleaned = actorRaw.trim();
    if (cleaned.isEmpty) return const [];
    final tokens = cleaned
        .split(RegExp(r'[,，/、;；|]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != '未知' && s != '内详' && s.length <= 28)
        .toList();
    final seen = <String>{};
    final out = <CastMember>[];
    for (final t in tokens) {
      if (seen.add(t)) {
        out.add(CastMember(name: t, role: '主演'));
      }
      if (out.length >= 16) break;
    }
    return out;
  }

  /// Synchronously returns cached cast members for [title] if already loaded.
  static List<CastMember>? peekCached(String title) {
    final key = _normalizeTitle(title);
    return _cache[key];
  }

  /// Resolves cast members with portrait avatar URLs for [title].
  static Future<List<CastMember>> resolveCast({
    required String title,
    String actorRaw = '',
    String year = '',
    String doubanId = '',
  }) async {
    final fallback = parseRawActors(actorRaw);
    final key = _normalizeTitle(title);
    if (key.isEmpty) return fallback;

    final cached = _cache[key];
    if (cached != null && cached.isNotEmpty) return cached;

    final existing = _inflight[key];
    if (existing != null) return existing;

    final future = _fetchCastForTitle(
      cleanTitle: key,
      year: year.trim(),
      doubanId: doubanId.trim(),
      fallback: fallback,
    );
    _inflight[key] = future;
    try {
      final result = await future;
      if (result.isNotEmpty) {
        _putCache(key, result);
      }
      return result.isNotEmpty ? result : fallback;
    } finally {
      _inflight.remove(key);
    }
  }

  static void _putCache(String key, List<CastMember> list) {
    _cache.remove(key);
    while (_cache.length >= _maxCache) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = list;
  }

  static String _normalizeTitle(String raw) {
    var s = raw.trim();
    s = s.replaceAll(
      RegExp(
        r'[\(\[（【].*?(?:4K|HDR|臻彩|杜比|蓝光|国语|粤语|中字|未删减|完整版|高清|HD|1080P|2160P).*?[\)\]）】]',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static Future<List<CastMember>> _fetchCastForTitle({
    required String cleanTitle,
    required String year,
    required String doubanId,
    required List<CastMember> fallback,
  }) async {
    try {
      String id = doubanId;
      String kind = 'tv';
      if (id.isEmpty) {
        final match = await _lookupDoubanSubject(cleanTitle, year);
        if (match != null) {
          id = match.id;
          kind = match.kind;
        }
      }
      if (id.isNotEmpty) {
        final primary = await _fetchDoubanCredits(id, kind);
        if (primary.isNotEmpty) return primary;
        final altKind = kind == 'tv' ? 'movie' : 'tv';
        final secondary = await _fetchDoubanCredits(id, altKind);
        if (secondary.isNotEmpty) return secondary;
      }
    } catch (e) {
      debugPrint('CastAvatarService lookup warning: $e');
    }
    return fallback;
  }

  static Future<({String id, String kind})?> _lookupDoubanSubject(
    String title,
    String year,
  ) async {
    final uri = Uri.https('movie.douban.com', '/j/subject_suggest', {
      'q': title,
    });
    final jsonText = await _getJsonText(
      uri,
      referer: 'https://movie.douban.com/',
    );
    if (jsonText == null || jsonText.isEmpty) return null;
    final decoded = jsonDecode(jsonText);
    if (decoded is! List || decoded.isEmpty) return null;

    Map<String, dynamic>? best;
    for (final item in decoded.whereType<Map>()) {
      final map = Map<String, dynamic>.from(item);
      final type = (map['type'] ?? '').toString().toLowerCase();
      if (type != 'movie' && type != 'tv') continue;
      final itemTitle = (map['title'] ?? '').toString().trim();
      final itemYear = (map['year'] ?? '').toString().trim();
      if (itemTitle == title && (year.isEmpty || itemYear == year)) {
        best = map;
        break;
      }
      best ??= map;
    }
    if (best == null) return null;
    final id = (best['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    final type = (best['type'] ?? '').toString().toLowerCase();
    final episode = (best['episode'] ?? '').toString().trim();
    final kind = (type == 'tv' || episode.isNotEmpty) ? 'tv' : 'movie';
    return (id: id, kind: kind);
  }

  static Future<List<CastMember>> _fetchDoubanCredits(
    String subjectId,
    String kind,
  ) async {
    final uri = Uri.https(
      'm.douban.com',
      '/rexxar/api/v2/$kind/$subjectId/credits',
    );
    final jsonText = await _getJsonText(
      uri,
      referer: 'https://m.douban.com/movie/subject/$subjectId/',
    );
    if (jsonText == null || jsonText.isEmpty) return const [];
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) return const [];
    final items = decoded['credits'];
    if (items is! List) return const [];

    final members = <CastMember>[];
    final seen = <String>{};
    for (final section in items.whereType<Map>()) {
      final sectionTitle = (section['title'] ?? '').toString().trim();
      final celebList = section['celebrities'];
      if (celebList is! List) continue;
      for (final raw in celebList.whereType<Map>()) {
        final name = (raw['name'] ?? '').toString().trim();
        if (name.isEmpty || !seen.add(name)) continue;
        final character = (raw['character'] ?? '').toString().trim();
        final roles = raw['roles'];
        String role = character;
        if (role.isEmpty && roles is List && roles.isNotEmpty) {
          role = roles.first.toString().trim();
        }
        if (role.isEmpty) {
          role = sectionTitle.isNotEmpty ? sectionTitle : '主演';
        }
        final avatarMap = raw['avatar'];
        String avatarUrl = '';
        if (avatarMap is Map) {
          avatarUrl = (avatarMap['large'] ??
                  avatarMap['normal'] ??
                  avatarMap['small'] ??
                  '')
              .toString()
              .trim();
        } else if (raw['cover_url'] != null) {
          avatarUrl = raw['cover_url'].toString().trim();
        }
        members.add(
          CastMember(
            name: name,
            role: role,
            avatarUrl: avatarUrl,
          ),
        );
        if (members.length >= 16) break;
      }
      if (members.length >= 16) break;
    }
    return members;
  }

  static Future<String?> _getJsonText(
    Uri uri, {
    required String referer,
  }) async {
    try {
      final req = await _client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      req.headers.set(HttpHeaders.refererHeader, referer);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return null;
      return await utf8.decoder.bind(resp).join();
    } catch (_) {
      return null;
    }
  }
}

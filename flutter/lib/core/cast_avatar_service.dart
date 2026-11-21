import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// A single cast or crew member displayed in the avatar carousel on the Detail
/// screen.
class CastMember {
  final String name;
  final String role;
  final String avatarUrl;

  const CastMember({
    required this.name,
    this.role = '',
    this.avatarUrl = '',
  });

  CastMember copyWith({
    String? name,
    String? role,
    String? avatarUrl,
  }) =>
      CastMember(
        name: name ?? this.name,
        role: role ?? this.role,
        avatarUrl: avatarUrl ?? this.avatarUrl,
      );
}

/// Resolves real actor/director portraits using allowed public domestic metadata
/// endpoints (`baike.baidu.com`, `cn.bing.com`, and `m.douban.com` /
/// `movie.douban.com`) with immediate parsed-name fallback and per-actor cache.
class CastAvatarService {
  CastAvatarService._();

  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const String _mobileUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const int _maxCache = 220;
  static const int _maxActorCache = 600;
  static const int _maxConcurrentLookups = 5;

  static final LinkedHashMap<String, List<CastMember>> _cache =
      LinkedHashMap<String, List<CastMember>>();
  static final LinkedHashMap<String, String> _actorPortraitCache =
      LinkedHashMap<String, String>();
  static final Map<String, Future<String>> _actorInflight = {};
  static final Map<String, Future<List<CastMember>>> _inflight = {};
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 20)
    ..autoUncompress = true;

  /// Parses raw CMS `vod_actor` strings (`"张三, 李四 / 王五"`) into immediate
  /// placeholder [CastMember] items (already populated with cached portrait
  /// URLs when available) so the UI renders without layout jump.
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
        final cachedAvatar = _actorPortraitCache[t] ?? '';
        out.add(CastMember(name: t, role: '主演', avatarUrl: cachedAvatar));
      }
      if (out.length >= 16) break;
    }
    return out;
  }

  /// Synchronously returns cached cast members for [title] if already loaded
  /// with at least one resolved portrait URL.
  static List<CastMember>? peekCached(String title) {
    final key = _normalizeTitle(title);
    return _cache[key];
  }

  /// Seeds cached cast members in tests without making live network calls.
  @visibleForTesting
  static void debugSeedCache(String title, List<CastMember> members) {
    final key = _normalizeTitle(title);
    if (key.isEmpty) return;
    _putCache(key, members);
  }

  /// Clears cached cast entries in tests.
  @visibleForTesting
  static void debugClearCache() {
    _cache.clear();
    _actorPortraitCache.clear();
  }

  /// Resolves cast members with portrait avatar URLs for [title].
  ///
  /// Calls [onProgress] as portraits arrive so the UI updates progressively
  /// without waiting for every actor lookup to finish.
  static Future<List<CastMember>> resolveCast({
    required String title,
    String actorRaw = '',
    String year = '',
    String doubanId = '',
    void Function(List<CastMember> members)? onProgress,
  }) async {
    final fallback = parseRawActors(actorRaw);
    final key = _normalizeTitle(title);
    if (key.isEmpty && fallback.isEmpty) return const [];

    final cached = key.isNotEmpty ? _cache[key] : null;
    if (cached != null &&
        cached.isNotEmpty &&
        cached.any((m) => m.avatarUrl.isNotEmpty)) {
      return cached;
    }

    final inflightKey = '$key|${fallback.map((m) => m.name).join(',')}';
    final existing = _inflight[inflightKey];
    if (existing != null) return existing;

    final future = _fetchCastForTitle(
      cleanTitle: key,
      year: year.trim(),
      doubanId: doubanId.trim(),
      fallback: fallback,
      onProgress: onProgress,
    );
    _inflight[inflightKey] = future;
    try {
      final result = await future;
      if (key.isNotEmpty &&
          result.isNotEmpty &&
          result.any((m) => m.avatarUrl.isNotEmpty)) {
        _putCache(key, result);
      }
      return result.isNotEmpty ? result : fallback;
    } finally {
      _inflight.remove(inflightKey);
    }
  }

  static void _putCache(String key, List<CastMember> list) {
    _cache.remove(key);
    while (_cache.length >= _maxCache) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = list;
  }

  static void _putActorPortrait(String name, String url) {
    if (name.isEmpty || url.isEmpty) return;
    _actorPortraitCache.remove(name);
    while (_actorPortraitCache.length >= _maxActorCache) {
      _actorPortraitCache.remove(_actorPortraitCache.keys.first);
    }
    _actorPortraitCache[name] = url;
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
    void Function(List<CastMember> members)? onProgress,
  }) async {
    var baseMembers = List<CastMember>.of(fallback);

    // 1. Try Douban credits when doubanId is known or when CMS gave no actors.
    if (doubanId.isNotEmpty || baseMembers.isEmpty) {
      try {
        String id = doubanId;
        String kind = 'tv';
        if (id.isEmpty && cleanTitle.isNotEmpty) {
          final match = await _lookupDoubanSubject(cleanTitle, year);
          if (match != null) {
            id = match.id;
            kind = match.kind;
          }
        }
        if (id.isNotEmpty) {
          var doubanCast = await _fetchDoubanCredits(id, kind);
          if (doubanCast.isEmpty) {
            final altKind = kind == 'tv' ? 'movie' : 'tv';
            doubanCast = await _fetchDoubanCredits(id, altKind);
          }
          if (doubanCast.isNotEmpty) {
            for (final m in doubanCast) {
              if (m.avatarUrl.isNotEmpty) _putActorPortrait(m.name, m.avatarUrl);
            }
            baseMembers = doubanCast;
            onProgress?.call(List<CastMember>.unmodifiable(baseMembers));
            if (baseMembers.every((m) => m.avatarUrl.isNotEmpty)) {
              return baseMembers;
            }
          }
        }
      } catch (e) {
        debugPrint('CastAvatarService douban lookup warning: $e');
      }
    }

    if (baseMembers.isEmpty) return const [];

    // 2. Fill missing actor portraits via Baidu Baike LemmaCard + Bing face
    //    portrait lookup (strictly within ALLOWED_HOSTS) with bounded
    //    concurrency so avatars stream in rapidly.
    final pendingIndices = <int>[
      for (var i = 0; i < baseMembers.length; i++)
        if (baseMembers[i].avatarUrl.isEmpty) i,
    ];
    if (pendingIndices.isEmpty) return baseMembers;

    var cursor = 0;
    Future<void> worker() async {
      while (cursor < pendingIndices.length) {
        final idx = pendingIndices[cursor++];
        final member = baseMembers[idx];
        final portrait = await resolveActorPortrait(member.name);
        if (portrait.isNotEmpty) {
          baseMembers[idx] = member.copyWith(avatarUrl: portrait);
          onProgress?.call(List<CastMember>.unmodifiable(baseMembers));
        }
      }
    }

    final workerCount = pendingIndices.length < _maxConcurrentLookups
        ? pendingIndices.length
        : _maxConcurrentLookups;
    await Future.wait([for (var w = 0; w < workerCount; w++) worker()]);
    return baseMembers;
  }

  /// Resolves a single actor's portrait URL using Baidu Baike LemmaCard first
  /// and Bing face-portrait thumbnails as fallback.
  static Future<String> resolveActorPortrait(String actorName) async {
    final name = actorName.trim();
    if (name.isEmpty) return '';
    final cached = _actorPortraitCache[name];
    if (cached != null && cached.isNotEmpty) return cached;

    final inflight = _actorInflight[name];
    if (inflight != null) return inflight;

    final future = _fetchActorPortrait(name);
    _actorInflight[name] = future;
    try {
      final url = await future;
      if (url.isNotEmpty) _putActorPortrait(name, url);
      return url;
    } finally {
      _actorInflight.remove(name);
    }
  }

  static Future<String> _fetchActorPortrait(String name) async {
    // 1. Official Baidu Baike celebrity card image (fast, crisp studio portrait)
    final baikeUrl = await _lookupBaiduBaikePortrait(name);
    if (baikeUrl.isNotEmpty) return baikeUrl;

    // 2. Bing face-portrait thumbnail (reliable fallback for Korean/Japanese/new actors)
    final bingUrl = await _lookupBingFacePortrait(name);
    if (bingUrl.isNotEmpty) return bingUrl;

    return '';
  }

  static bool _looksLikeEntertainmentPerson(String desc, String abstractText) {
    final combined = '$desc $abstractText'.toLowerCase();
    if (combined.trim().isEmpty) return true;
    const positive = [
      '演员',
      '艺人',
      '歌手',
      '导演',
      '主持人',
      '模特',
      '编剧',
      '配音',
      '声优',
      '制片',
      '男团',
      '女团',
      '组合',
      '影视',
      '主演',
      '明星',
      '相声',
      '喜剧人',
      'actor',
      'actress',
      'singer',
      'director',
    ];
    for (final kw in positive) {
      if (combined.contains(kw)) return true;
    }
    return false;
  }

  static Future<String> _lookupBaiduBaikePortrait(String name) async {
    try {
      final uri = Uri.https(
        'baike.baidu.com',
        '/api/openapi/BaikeLemmaCardApi',
        {
          'scope': '103',
          'format': 'json',
          'appid': '379020',
          'bk_key': name,
          'bk_length': '160',
        },
      );
      final body = await _getText(
        uri,
        userAgent: _desktopUa,
        referer: 'https://baike.baidu.com/',
        accept: 'application/json',
      );
      if (body == null || body.isEmpty) return '';
      final decoded = jsonDecode(body);
      if (decoded is! Map) return '';
      final rawImage = (decoded['image'] ?? '').toString().trim();
      if (rawImage.isEmpty ||
          (!rawImage.startsWith('https://') && !rawImage.startsWith('http://'))) {
        return '';
      }
      final desc = (decoded['desc'] ?? '').toString();
      final abstractText = (decoded['abstract'] ?? '').toString();
      if (!_looksLikeEntertainmentPerson(desc, abstractText)) {
        return '';
      }
      return rawImage;
    } catch (_) {
      return '';
    }
  }

  static Future<String> _lookupBingFacePortrait(String name) async {
    try {
      final uri = Uri.https('cn.bing.com', '/images/async', {
        'q': '$name 演员',
        'first': '0',
        'count': '4',
        'mmasync': '1',
        'qft': '+filterui:face-portrait',
      });
      final body = await _getText(
        uri,
        userAgent: _desktopUa,
        referer: 'https://cn.bing.com/',
        accept: 'text/html,*/*',
      );
      if (body == null || body.isEmpty) return '';
      final thumbMatch = RegExp(
        r'(tse[1-4]-mm\.cn\.bing\.net)(/th(?:/id)?/[^"\x27&<>\s?]+)(?:\?([^"\x27<>\s]+))?',
      ).firstMatch(body);
      if (thumbMatch != null) {
        final host = thumbMatch.group(1)!;
        final path = thumbMatch.group(2)!;
        final existingQuery = thumbMatch.group(3) ?? '';
        final params = <String, String>{
          if (existingQuery.isNotEmpty) ...Uri.splitQueryString(existingQuery),
          'w': '240',
          'h': '240',
          'c': '7',
          'rs': '1',
          'p': '0',
        };
        return Uri.https(host, path, params).toString();
      }
      final murlMatch = RegExp(
        r'murl&quot;:&quot;(https?://[^&]+?)&quot;',
      ).firstMatch(body);
      if (murlMatch != null) {
        return murlMatch.group(1)!;
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  static Future<({String id, String kind})?> _lookupDoubanSubject(
    String title,
    String year,
  ) async {
    final uri = Uri.https('movie.douban.com', '/j/subject_suggest', {
      'q': title,
    });
    final jsonText = await _getText(
      uri,
      userAgent: _mobileUa,
      referer: 'https://movie.douban.com/',
      accept: 'application/json',
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
    final jsonText = await _getText(
      uri,
      userAgent: _mobileUa,
      referer: 'https://m.douban.com/movie/subject/$subjectId/',
      accept: 'application/json',
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

  static Future<String?> _getText(
    Uri uri, {
    required String userAgent,
    required String referer,
    required String accept,
  }) async {
    try {
      final req = await _client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      req.headers.set(HttpHeaders.refererHeader, referer);
      req.headers.set(HttpHeaders.acceptHeader, accept);
      req.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return null;
      return await utf8.decoder.bind(resp).join();
    } catch (_) {
      return null;
    }
  }
}

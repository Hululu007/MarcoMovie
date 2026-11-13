import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'cms_parser.dart';
import 'csp_bridge.dart';
import 'models.dart';

/// Declarative data-only rule engine for TVBox `csp_XBPQ`, `csp_XYQ`, and
/// `csp_XPath*` subscription sources. Evaluates HTML/JSON extraction templates
/// from `site.ext` without executing any third-party code or bypassing challenges.
class CspRuleEngines {
  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const String _mobileUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  static final Map<String, Map<String, dynamic>> _ruleCache = {};

  static bool isXbpqSite(CmsSite site) {
    final api = site.api.trim().toLowerCase();
    return api == 'csp_xbpq' || api == 'csp_xbpqguard';
  }

  static bool isXyqSite(CmsSite site) {
    final api = site.api.trim().toLowerCase();
    return api == 'csp_xyq' || api == 'csp_xyqguard';
  }

  static bool isXpathSite(CmsSite site) {
    final api = site.api.trim().toLowerCase();
    return api == 'csp_xpath' ||
        api == 'csp_xpathguard' ||
        api == 'csp_xpathfilter' ||
        api == 'csp_xpathfilterguard' ||
        api == 'csp_xpathmac' ||
        api == 'csp_xpathmacfilter';
  }

  static bool supports(CmsSite site) {
    if (site.ext.trim().isEmpty) return false;
    return isXbpqSite(site) || isXyqSite(site) || isXpathSite(site);
  }

  static String _cacheKey(CmsSite site) => jsonEncode([
        site.subscriptionId,
        site.sourceKey,
        site.isEffectivelyPrivate,
        site.api.toLowerCase(),
        site.ext,
      ]);

  /// Strips `//` and `/* ... */` comments and trailing commas outside string
  /// literals, which are commonplace in community `XBPQ` and `XYQ` JSON rules.
  static Map<String, dynamic> parseLenientJsonObject(String raw) {
    final text = raw.replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty) throw const FormatException('规则内容为空');
    try {
      final direct = jsonDecode(text);
      if (direct is Map) {
        return direct.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}

    final sb = StringBuffer();
    var inStr = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inStr) {
        sb.write(ch);
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
        sb.write(ch);
        continue;
      }
      if (ch == '/' && i + 1 < text.length) {
        final next = text[i + 1];
        if (next == '/') {
          i += 2;
          while (i < text.length && text[i] != '\n') {
            i++;
          }
          sb.write('\n');
          continue;
        }
        if (next == '*') {
          i += 2;
          while (i + 1 < text.length && !(text[i] == '*' && text[i + 1] == '/')) {
            i++;
          }
          i++;
          continue;
        }
      }
      sb.write(ch);
    }
    final cleaned = sb
        .toString()
        .replaceAllMapped(RegExp(r',\s*([}\]])'), (m) => m.group(1)!);
    final decoded = jsonDecode(cleaned);
    if (decoded is! Map) throw const FormatException('规则格式不是 JSON 对象');
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  }

  static Future<Map<String, dynamic>> _loadRule(
    CmsSite site,
    CspHttpTextFetcher fetchText,
  ) async {
    final key = _cacheKey(site);
    final cached = _ruleCache[key];
    if (cached != null) return cached;

    var ext = site.ext.trim();
    if (ext.isEmpty) throw const FormatException('缺少规则扩展配置');

    Map<String, dynamic>? rule;
    if (ext.startsWith('{')) {
      final parsed = parseLenientJsonObject(ext);
      final remoteUrl =
          (parsed['url'] ?? parsed['rule'] ?? parsed['json'] ?? '').toString().trim();
      if ((remoteUrl.startsWith('http://') || remoteUrl.startsWith('https://')) &&
          parsed.length <= 3 &&
          !parsed.containsKey('分类url') &&
          !parsed.containsKey('分类链接') &&
          !parsed.containsKey('cateUrl')) {
        final remoteRaw = await fetchText(remoteUrl, headers: site.headers);
        rule = {
          ...parseLenientJsonObject(remoteRaw),
          ...parsed,
        };
      } else {
        rule = parsed;
      }
    } else if (ext.startsWith('http://') || ext.startsWith('https://')) {
      final remoteRaw = await fetchText(ext, headers: site.headers);
      rule = parseLenientJsonObject(remoteRaw);
    } else {
      try {
        var b64 = ext.replaceAll('-', '+').replaceAll('_', '/');
        while (b64.length % 4 != 0) {
          b64 += '=';
        }
        final decoded = utf8.decode(base64Decode(b64), allowMalformed: true).trim();
        if (decoded.startsWith('{')) {
          rule = parseLenientJsonObject(decoded);
        } else if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
          final remoteRaw = await fetchText(decoded, headers: site.headers);
          rule = parseLenientJsonObject(remoteRaw);
        }
      } catch (_) {}
    }

    if (rule == null) throw const FormatException('无法解析规则扩展配置');
    if (_ruleCache.length >= 64) {
      _ruleCache.remove(_ruleCache.keys.first);
    }
    _ruleCache[key] = rule;
    return rule;
  }

  static void _checkChallenge(String html) {
    if (html.isEmpty) return;
    if (RegExp(
          r'(?:SafeLineChallenge|__cdn_pow|sl-challenge-jwt|Checking your browser|challenges\.cloudflare\.com|<title>\s*Just a moment\.\.\.\s*</title>|cf-turnstile|系统安全验证|正在验证您的浏览器|人机验证|verify you are human|请完成滑块验证)',
          caseSensitive: false,
        ).hasMatch(html) ||
        RegExp(r'<input[^>]+(?:name|id)=["\x27]?(?:verify|validate|captcha)',
                caseSensitive: false)
            .hasMatch(html)) {
      throw const FormatException('该站点启用了人机验证，请稍后重试或切换其他片源');
    }
  }

  static Map<String, String> _headersForRule(
    CmsSite site,
    Map<String, dynamic> rule, {
    String? refererOrigin,
  }) {
    final out = <String, String>{
      'User-Agent': _desktopUa,
      ...site.headers,
    };
    final rawUa = (rule['请求头'] ??
            rule['请求头参数'] ??
            rule['ua'] ??
            rule['User-Agent'] ??
            '')
        .toString()
        .trim();
    if (rawUa == '手机' || rawUa.toLowerCase() == 'mobile' || rawUa == 'MOBILE_UA') {
      out['User-Agent'] = _mobileUa;
    } else if (rawUa == '电脑' || rawUa.toLowerCase() == 'pc' || rawUa == 'PC_UA') {
      out['User-Agent'] = _desktopUa;
    } else if (rawUa.contains('#')) {
      for (final part in rawUa.split('#')) {
        final sep = part.indexOf(r'$');
        if (sep > 0) {
          out[part.substring(0, sep).trim()] = part.substring(sep + 1).trim();
        }
      }
    } else if (rawUa.startsWith('Mozilla/') || rawUa.startsWith('okhttp/')) {
      out['User-Agent'] = rawUa;
    }
    if (refererOrigin != null &&
        refererOrigin.startsWith('http') &&
        !out.keys.any((k) => k.toLowerCase() == 'referer')) {
      out['Referer'] = refererOrigin.endsWith('/') ? refererOrigin : '$refererOrigin/';
    }
    return out;
  }

  static String _originOf(Map<String, dynamic> rule) {
    for (final k in const [
      '主页url',
      '首页推荐链接',
      'homeUrl',
      '分类url',
      '分类链接',
      'cateUrl',
      '搜索url',
      '搜索链接',
      'searchUrl',
    ]) {
      final raw = (rule[k] ?? '').toString().trim();
      final m = RegExp(r'^(https?://[^/?#\s\[]+)', caseSensitive: false).firstMatch(raw);
      if (m != null) return m.group(1)!;
    }
    return '';
  }

  static String _resolveHref(String baseOrigin, String raw, {String prefix = '', String suffix = ''}) {
    var v = raw.trim();
    if (v.isEmpty) return '';
    if (prefix.isNotEmpty && !v.startsWith('http://') && !v.startsWith('https://')) {
      v = '$prefix$v';
    }
    if (suffix.isNotEmpty && !v.endsWith(suffix)) {
      v = '$v$suffix';
    }
    if (v.startsWith('//')) return 'https:$v';
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    if (baseOrigin.isEmpty) return v;
    try {
      return Uri.parse(baseOrigin.endsWith('/') ? baseOrigin : '$baseOrigin/')
          .resolve(v)
          .toString();
    } catch (_) {
      return v;
    }
  }

  static String _safePic(String baseOrigin, String raw) {
    final resolved = _resolveHref(baseOrigin, raw);
    if (resolved.isEmpty || CmsParser.isBrokenPosterUrl(resolved)) return '';
    if (resolved.contains('sogoucdn.com') || resolved.contains('imagehub.cc')) {
      return '';
    }
    return resolved.startsWith('http://') || resolved.startsWith('https://')
        ? resolved
        : '';
  }

  static String _stripHtml(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _expandUrlTemplate(
    String template, {
    String cateId = '',
    int page = 1,
    String wd = '',
    String area = '',
    String year = '',
    String clazz = '',
    String by = '',
  }) {
    var raw = template.trim();
    String? firstPageAlt;
    final fpMatch = RegExp(r'\[firstPage=([^\]]+)\]').firstMatch(raw);
    if (fpMatch != null) {
      firstPageAlt = fpMatch.group(1)!;
      raw = raw.replaceRange(fpMatch.start, fpMatch.end, '');
    }
    if (page == 1 && firstPageAlt != null && firstPageAlt.trim().isNotEmpty) {
      raw = firstPageAlt.trim();
    }
    // Handle `;;...` XBPQ suffix flags
    final semiIdx = raw.indexOf(';;');
    if (semiIdx >= 0) raw = raw.substring(0, semiIdx);

    // Handle `[||fallback]` or `{catePg}` page-1 brackets like `[-{catePg}]`
    raw = raw.replaceAllMapped(RegExp(r'\[([^\[\]]*\{catePg\}[^\[\]]*)\]'), (m) {
      if (page <= 1) return '';
      return m.group(1)!.replaceAll('{catePg}', '$page');
    });

    return raw
        .replaceAll('{cateId}', Uri.encodeComponent(cateId))
        .replaceAll('{catePg}', '$page')
        .replaceAll('{pg}', '$page')
        .replaceAll('{wd}', Uri.encodeQueryComponent(wd))
        .replaceAll('{area}', Uri.encodeComponent(area))
        .replaceAll('{year}', Uri.encodeComponent(year))
        .replaceAll('{class}', Uri.encodeComponent(clazz))
        .replaceAll('{by}', Uri.encodeComponent(by));
  }

  // ---------------------------------------------------------------------------
  // Entry points called from CspBridge
  // ---------------------------------------------------------------------------

  static Future<(List<CmsCategory>, CmsListing)> fetchHome(
    CmsSite site,
    CspHttpTextFetcher fetchText,
  ) async {
    final rule = await _loadRule(site, fetchText);
    if (isXbpqSite(site)) return _xbpqHome(site, rule, fetchText);
    if (isXyqSite(site)) return _xyqHome(site, rule, fetchText);
    if (isXpathSite(site)) return _xpathHome(site, rule, fetchText);
    throw const FormatException('不支持的规则类型');
  }

  static Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText, {
    CmsFilter? filter,
  }) async {
    final rule = await _loadRule(site, fetchText);
    if (isXbpqSite(site)) {
      return _xbpqCategory(site, rule, categoryId, page, fetchText, filter: filter);
    }
    if (isXyqSite(site)) {
      return _xyqCategory(site, rule, categoryId, page, fetchText, filter: filter);
    }
    if (isXpathSite(site)) {
      return _xpathCategory(site, rule, categoryId, page, fetchText);
    }
    return const CmsListing();
  }

  static Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const CmsListing();
    final rule = await _loadRule(site, fetchText);
    if (isXbpqSite(site)) return _xbpqSearch(site, rule, kw, page, fetchText);
    if (isXyqSite(site)) return _xyqSearch(site, rule, kw, page, fetchText);
    if (isXpathSite(site)) return _xpathSearch(site, rule, kw, page, fetchText);
    return const CmsListing();
  }

  static Future<CmsVideo> fetchDetail(
    CmsSite site,
    CmsVideo fallback,
    CspHttpTextFetcher fetchText,
  ) async {
    final rule = await _loadRule(site, fetchText);
    if (isXbpqSite(site)) return _xbpqDetail(site, rule, fallback, fetchText);
    if (isXyqSite(site)) return _xyqDetail(site, rule, fallback, fetchText);
    if (isXpathSite(site)) return _xpathDetail(site, rule, fallback, fetchText);
    return fallback;
  }

  static Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode,
    CspHttpTextFetcher fetchText,
  ) async {
    final rawUrl = episode.url.trim();
    if (RegExp(r'^https?://[^?#]+\.(?:m3u8?|mp4|flv|mkv|webm|ts)(?:[?#]|$)',
            caseSensitive: false)
        .hasMatch(rawUrl)) {
      return episode;
    }
    if (!rawUrl.startsWith('http://') && !rawUrl.startsWith('https://')) {
      return episode;
    }
    try {
      final rule = await _loadRule(site, fetchText);
      final origin = _originOf(rule);
      final headers = _headersForRule(site, rule, refererOrigin: origin);
      final html = await fetchText(rawUrl, headers: headers);
      _checkChallenge(html);
      final mediaUrl = _extractPlayerMediaUrl(html, origin);
      if (mediaUrl.isNotEmpty) {
        return CmsEpisode(
          name: episode.name,
          url: mediaUrl,
          headers: {
            ...headers,
            ...episode.headers,
          },
        );
      }
    } catch (_) {}
    return episode;
  }

  static String _extractPlayerMediaUrl(String html, String origin) {
    final m = RegExp(
      r'var\s+player_(?:aaaa|data)\s*=\s*(\{[\s\S]*?\})\s*<',
      caseSensitive: false,
    ).firstMatch(html);
    if (m != null) {
      try {
        final obj = jsonDecode(m.group(1)!);
        if (obj is Map && obj['url'] != null) {
          var u = obj['url'].toString().trim();
          final enc = int.tryParse('${obj['encrypt'] ?? 0}') ?? 0;
          if (enc == 1) {
            u = Uri.decodeFull(u);
          } else if (enc == 2) {
            u = Uri.decodeFull(
              utf8.decode(base64Decode(u), allowMalformed: true),
            );
          }
          if (u.startsWith('http://') || u.startsWith('https://') || u.startsWith('//')) {
            return _resolveHref(origin, u);
          }
        }
      } catch (_) {}
    }
    final direct = RegExp(
      r'''["'](https?:\\/\\/|https?://)([^"'\s<>]+\.(?:m3u8|mp4)[^"'\s<>]*)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (direct != null) {
      return '${direct.group(1)}${direct.group(2)}'.replaceAll(r'\/', '/');
    }
    return '';
  }

  // ===========================================================================
  // 1. XBPQ Engine (`before&&after` substring rules)
  // ===========================================================================

  static String _xbpqBetween(String source, String rule, {bool stripTags = false}) {
    if (source.isEmpty || rule.isEmpty) return '';
    // Support `||` fallback rules in XBPQ
    for (final alt in rule.split('||')) {
      final r = alt.trim();
      if (r.isEmpty) continue;
      final val = _xbpqSingleBetween(source, r);
      if (val.isNotEmpty) {
        return stripTags ? _stripHtml(val) : val.trim();
      }
    }
    return '';
  }

  static String _xbpqSingleBetween(String source, String rule) {
    // Strip `[替换:old>>new]` or `[不包含:...]` modifiers at end
    var core = rule;
    final replacements = <(String, String)>[];
    core = core.replaceAllMapped(RegExp(r'\[替换:([^\]]+)\]'), (m) {
      for (final seg in m.group(1)!.split('#')) {
        final idx = seg.indexOf('>>');
        if (idx >= 0) {
          replacements.add((seg.substring(0, idx), seg.substring(idx + 2)));
        }
      }
      return '';
    });
    core = core.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    final parts = core.split('&&');
    String extracted = '';
    if (parts.length == 1) {
      extracted = source;
    } else if (parts.length == 2) {
      final left = parts[0];
      final right = parts[1];
      if (left.isEmpty) {
        final end = right.isEmpty ? source.length : source.indexOf(right);
        extracted = end < 0 ? '' : source.substring(0, end);
      } else {
        var searchFrom = 0;
        while (searchFrom < source.length) {
          final start = source.indexOf(left, searchFrom);
          if (start < 0) break;
          final afterLeft = start + left.length;
          final end = right.isEmpty
              ? source.length
              : source.indexOf(right, afterLeft);
          if (end < 0) break;
          final candidate = source.substring(afterLeft, end);
          if (candidate.trim().isNotEmpty) {
            extracted = candidate;
            break;
          }
          searchFrom = afterLeft;
        }
      }
    } else {
      var cur = source;
      for (var i = 0; i < parts.length - 1; i++) {
        final left = parts[i];
        final right = parts[i + 1];
        final start = left.isEmpty ? 0 : cur.indexOf(left);
        if (start < 0) {
          extracted = '';
          break;
        }
        final afterLeft = start + left.length;
        if (i == parts.length - 2) {
          final end = right.isEmpty ? cur.length : cur.indexOf(right, afterLeft);
          if (end < 0) {
            extracted = '';
            break;
          }
          extracted = cur.substring(afterLeft, end);
        } else {
          cur = cur.substring(afterLeft);
        }
      }
    }
    for (final rep in replacements) {
      extracted = extracted.replaceAll(rep.$1, rep.$2);
    }
    return extracted;
  }

  static List<String> _xbpqSplitArray(String source, String arrayRule) {
    if (source.isEmpty) return const [];
    if (arrayRule.isEmpty) {
      return _xbpqSplitByPair(source, '<li', '</li>');
    }
    for (final alt in arrayRule.split('||')) {
      final clean = alt.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
      if (clean.isEmpty) continue;
      final parts = clean.split('&&');
      final left = parts[0];
      final right = parts.length > 1 ? parts[1] : '';
      final items = _xbpqSplitByPair(source, left, right);
      if (items.isNotEmpty) return items;
    }
    return const [];
  }

  static List<String> _xbpqSplitByPair(String source, String left, String right) {
    if (left.isEmpty) return [source];
    final out = <String>[];
    var pos = 0;
    while (pos < source.length) {
      final s = source.indexOf(left, pos);
      if (s < 0) break;
      final contentStart = s + left.length;
      if (right.isEmpty) {
        final nextS = source.indexOf(left, contentStart);
        out.add(source.substring(s, nextS < 0 ? source.length : nextS));
        pos = nextS < 0 ? source.length : nextS;
      } else {
        final e = source.indexOf(right, contentStart);
        if (e < 0) break;
        out.add(source.substring(s, e + right.length));
        pos = e + right.length;
      }
      if (out.length >= 200) break;
    }
    return out;
  }

  static List<CmsCategory> _xbpqParseCategories(Map<String, dynamic> rule, String homeHtml) {
    final cats = <CmsCategory>[];
    final manual = (rule['分类'] ?? '').toString().trim();
    if (manual.isNotEmpty) {
      if (manual.contains(r'$')) {
        for (final seg in manual.split('#')) {
          final p = seg.trim().split(r'$');
          if (p.length >= 2 && p[0].trim().isNotEmpty && p[1].trim().isNotEmpty) {
            cats.add(CmsCategory(id: p[1].trim(), name: p[0].trim()));
          }
        }
      } else if (manual.contains('&') && (rule['分类值'] ?? '').toString().trim().isNotEmpty) {
        final names = manual.split('&');
        final vals = rule['分类值'].toString().trim().split('&');
        for (var i = 0; i < names.length && i < vals.length; i++) {
          if (names[i].trim().isNotEmpty && vals[i].trim().isNotEmpty) {
            cats.add(CmsCategory(id: vals[i].trim(), name: names[i].trim()));
          }
        }
      }
    }
    if (cats.isEmpty && homeHtml.isNotEmpty) {
      final arrRule = (rule['分类数组'] ?? '').toString().trim();
      if (arrRule.isNotEmpty) {
        final blocks = _xbpqSplitArray(homeHtml, arrRule);
        final titleR = (rule['分类标题'] ?? '>&&</a').toString();
        final idR = (rule['分类ID'] ?? 'href="&&"').toString();
        for (final b in blocks) {
          final name = _xbpqBetween(b, titleR, stripTags: true);
          final id = _xbpqBetween(b, idR);
          if (name.isNotEmpty && id.isNotEmpty) {
            cats.add(CmsCategory(id: id, name: name));
          }
        }
      }
    }
    if (cats.isEmpty) {
      return const [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '电视剧'),
        CmsCategory(id: '3', name: '综艺'),
        CmsCategory(id: '4', name: '动漫'),
      ];
    }
    return cats;
  }

  static List<CmsVideo> _xbpqParseVideos(
    String html,
    Map<String, dynamic> rule,
    String origin, {
    bool isSearch = false,
  }) {
    var scope = html;
    final secondR = (isSearch ? (rule['搜索二次截取'] ?? '') : (rule['二次截取'] ?? ''))
        .toString()
        .trim();
    if (secondR.isNotEmpty) {
      final sub = _xbpqBetween(scope, secondR);
      if (sub.isNotEmpty) scope = sub;
    }
    final arrR = (isSearch
            ? (rule['搜索数组'] ?? rule['数组'] ?? '<a&&</a>')
            : (rule['数组'] ?? 'class="module-item"&&</div>||<li&&</li>'))
        .toString();
    final titleR = (isSearch
            ? (rule['搜索标题'] ?? rule['标题'] ?? 'title="&&"||alt="&&"')
            : (rule['标题'] ?? 'title="&&"||alt="&&"'))
        .toString();
    final picR = (isSearch
            ? (rule['搜索图片'] ?? rule['图片'] ?? 'data-original="&&"||data-src="&&"||src="&&"')
            : (rule['图片'] ?? 'data-original="&&"||data-src="&&"||src="&&"'))
        .toString();
    final remR = (isSearch
            ? (rule['搜索副标题'] ?? rule['副标题'] ?? '')
            : (rule['副标题'] ?? 'module-item-note">&&<||pic-text">&&<'))
        .toString();
    final linkR = (isSearch
            ? (rule['搜索链接'] ?? rule['链接'] ?? 'href="&&"')
            : (rule['链接'] ?? 'href="&&"'))
        .toString();
    final linkPre = (isSearch
            ? (rule['搜索链接前缀'] ?? rule['链接前缀'] ?? '')
            : (rule['链接前缀'] ?? ''))
        .toString();
    final linkSuf = (isSearch
            ? (rule['搜索链接后缀'] ?? rule['链接后缀'] ?? '')
            : (rule['链接后缀'] ?? ''))
        .toString();

    final blocks = _xbpqSplitArray(scope, arrR);
    final out = <CmsVideo>[];
    final seen = <String>{};
    for (final b in blocks) {
      final title = _xbpqBetween(b, titleR, stripTags: true);
      final rawLink = _xbpqBetween(b, linkR);
      if (title.isEmpty || rawLink.isEmpty) continue;
      final id = _resolveHref(origin, rawLink, prefix: linkPre, suffix: linkSuf);
      if (!seen.add(id)) continue;
      final pic = _safePic(origin, _xbpqBetween(b, picR));
      final rem = remR.isEmpty ? '' : _xbpqBetween(b, remR, stripTags: true);
      out.add(CmsVideo(id: id, title: title, poster: pic, remarks: rem));
    }
    return out;
  }

  static Future<(List<CmsCategory>, CmsListing)> _xbpqHome(
    CmsSite site,
    Map<String, dynamic> rule,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final homeUrl = _resolveHref(origin, (rule['主页url'] ?? origin).toString());
    String homeHtml = '';
    if (homeUrl.startsWith('http')) {
      try {
        homeHtml = await fetchText(homeUrl, headers: headers);
        _checkChallenge(homeHtml);
      } catch (e) {
        if (e is FormatException) rethrow;
      }
    }
    final cats = _xbpqParseCategories(rule, homeHtml);
    var videos = homeHtml.isEmpty ? const <CmsVideo>[] : _xbpqParseVideos(homeHtml, rule, origin);
    if (videos.isEmpty && cats.isNotEmpty) {
      final firstCat = await _xbpqCategory(site, rule, cats.first.id, 1, fetchText);
      videos = firstCat.videos;
    }
    return (cats, CmsListing(page: 1, pageCount: videos.isEmpty ? 1 : 2, videos: videos));
  }

  static Future<CmsListing> _xbpqCategory(
    CmsSite site,
    Map<String, dynamic> rule,
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText, {
    CmsFilter? filter,
  }) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final tpl = (rule['分类url'] ?? '').toString().trim();
    if (tpl.isEmpty) return const CmsListing();
    final url = _resolveHref(
      origin,
      _expandUrlTemplate(
        tpl,
        cateId: categoryId,
        page: page < 1 ? 1 : page,
        area: filter != null && filter.area != '全部' ? filter.area : '',
        year: filter != null && filter.year != '全部' ? filter.year : '',
        clazz: filter != null && filter.genreLabel != '全部' ? filter.genreLabel : '',
      ),
    );
    if (!url.startsWith('http')) return const CmsListing();
    final html = await fetchText(url, headers: headers);
    _checkChallenge(html);
    final videos = _xbpqParseVideos(html, rule, origin);
    return CmsListing(
      page: page < 1 ? 1 : page,
      pageCount: videos.isNotEmpty ? page + 1 : page,
      videos: videos,
      sourceFiltered: filter?.hasSubFilter ?? false,
    );
  }

  static Future<CmsListing> _xbpqSearch(
    CmsSite site,
    Map<String, dynamic> rule,
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    var tpl = (rule['搜索url'] ?? '').toString().trim();
    if (tpl.isEmpty && origin.isNotEmpty) {
      tpl = '$origin/index.php/vod/search.html?wd={wd}';
    }
    if (tpl.isEmpty) return const CmsListing();
    final url = _resolveHref(
      origin,
      _expandUrlTemplate(tpl, wd: keyword, page: page < 1 ? 1 : page),
    );
    if (!url.startsWith('http')) return const CmsListing();
    final raw = await fetchText(url, headers: headers);
    _checkChallenge(raw);
    if ('${rule['搜索模式'] ?? ''}' == '0' || raw.trimLeft().startsWith('{')) {
      try {
        final doc = jsonDecode(raw);
        final list = (doc is Map ? (doc['list'] ?? doc['data']) : null);
        if (list is List) {
          final pre = (rule['搜索链接前缀'] ?? rule['链接前缀'] ?? '$origin/index.php/vod/detail/id/').toString();
          final suf = (rule['搜索链接后缀'] ?? rule['链接后缀'] ?? '.html').toString();
          final videos = <CmsVideo>[];
          for (final it in list.whereType<Map>()) {
            final id = (it['id'] ?? it['vod_id'] ?? '').toString().trim();
            final name = (it['name'] ?? it['vod_name'] ?? '').toString().trim();
            if (id.isEmpty || name.isEmpty) continue;
            videos.add(CmsVideo(
              id: _resolveHref(origin, id, prefix: pre, suffix: suf),
              title: name,
              poster: _safePic(origin, (it['pic'] ?? it['vod_pic'] ?? '').toString()),
            ));
          }
          if (videos.isNotEmpty) return CmsListing(page: 1, pageCount: 1, videos: videos);
        }
      } catch (_) {}
    }
    final videos = _xbpqParseVideos(raw, rule, origin, isSearch: true);
    return CmsListing(page: page, pageCount: 1, videos: videos);
  }

  static Future<CmsVideo> _xbpqDetail(
    CmsSite site,
    Map<String, dynamic> rule,
    CmsVideo fallback,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final detailUrl = _resolveHref(origin, fallback.id);
    if (!detailUrl.startsWith('http')) return fallback;
    final html = await fetchText(detailUrl, headers: headers);
    _checkChallenge(html);

    final tabR = (rule['线路数组'] ?? 'class="module-tab-item&&</div>||data-dropdown-value=&&</div>').toString();
    final tabTitleR = (rule['线路标题'] ?? '<span>&&</span>||>&&<').toString();
    final playArrR = (rule['播放数组'] ?? 'class="module-play-list"&&</div>||class="stui-content__playlist&&</ul>').toString();
    final epItemR = (rule['播放列表'] ?? '<a&&/a>').toString();
    final epTitleR = (rule['播放标题'] ?? '>&&<').toString();
    final epLinkR = (rule['播放链接'] ?? 'href="&&"').toString();
    final epPre = (rule['播放链接前缀'] ?? '').toString();
    final epSuf = (rule['播放链接后缀'] ?? '').toString();

    final tabBlocks = _xbpqSplitArray(html, tabR);
    final tabNames = [
      for (final tb in tabBlocks) _xbpqBetween(tb, tabTitleR, stripTags: true),
    ].where((s) => s.isNotEmpty).toList();

    final playBlocks = _xbpqSplitArray(html, playArrR);
    final lines = <CmsLine>[];
    for (var i = 0; i < playBlocks.length; i++) {
      final epBlocks = _xbpqSplitArray(playBlocks[i], epItemR);
      final episodes = <CmsEpisode>[];
      for (var j = 0; j < epBlocks.length; j++) {
        final rawHref = _xbpqBetween(epBlocks[j], epLinkR);
        if (rawHref.isEmpty ||
            rawHref.startsWith('javascript:') ||
            rawHref.startsWith('magnet:')) {
          continue;
        }
        final epName = _xbpqBetween(epBlocks[j], epTitleR, stripTags: true);
        final epUrl = _resolveHref(origin, rawHref, prefix: epPre, suffix: epSuf);
        episodes.add(CmsEpisode(
          name: epName.isEmpty ? '第${j + 1}集' : epName,
          url: epUrl,
          headers: headers,
        ));
      }
      if (episodes.isNotEmpty) {
        lines.add(CmsLine(
          name: i < tabNames.length ? tabNames[i] : '线路 ${i + 1}',
          episodes: episodes,
        ));
      }
    }

    final descR = (rule['简介'] ?? 'class="video-info-content">&&</div>||name="description" content="&&"').toString();
    final yearR = (rule['影片年代'] ?? '').toString();
    final areaR = (rule['影片地区'] ?? '').toString();
    final actorR = (rule['主演'] ?? '').toString();
    final desc = _xbpqBetween(html, descR, stripTags: true);
    final year = yearR.isEmpty ? '' : _xbpqBetween(html, yearR, stripTags: true);
    final area = areaR.isEmpty ? '' : _xbpqBetween(html, areaR, stripTags: true);
    final actor = actorR.isEmpty ? '' : _xbpqBetween(html, actorR, stripTags: true);

    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      poster: fallback.poster,
      remarks: fallback.remarks,
      year: year.isEmpty ? fallback.year : year,
      area: area.isEmpty ? fallback.area : area,
      actor: actor.isEmpty ? fallback.actor : actor,
      description: desc.isEmpty ? fallback.description : desc,
      tag: fallback.tag,
      lines: lines.isEmpty ? fallback.lines : lines,
    );
  }

  // ===========================================================================
  // 2. XYQ Engine (JSoup CSS + `&&` attribute extraction)
  // ===========================================================================

  static String _jsoupSelectValue(dom.Element root, String expr) {
    if (expr.trim().isEmpty) return '';
    for (final alt in expr.split('||')) {
      final clean = alt.trim();
      if (clean.isEmpty) continue;
      final parts = clean.split('&&');
      dom.Element? target = root;
      for (var i = 0; i < parts.length - 1; i++) {
        final sel = _normalizeCssSelector(parts[i]);
        if (sel.isEmpty) continue;
        try {
          target = target?.querySelector(sel);
        } catch (_) {
          target = null;
        }
        if (target == null) break;
      }
      if (target == null) continue;
      final attr = parts.last.trim();
      String val = '';
      if (attr.isEmpty || attr.toLowerCase() == 'text') {
        val = target.text.trim();
      } else if (attr.toLowerCase() == 'html') {
        val = target.innerHtml.trim();
      } else {
        val = (target.attributes[attr] ?? '').trim();
      }
      if (val.isNotEmpty) return val;
    }
    return '';
  }

  static String _normalizeCssSelector(String sel) {
    return sel
        .trim()
        .replaceAllMapped(RegExp(r':eq\((\d+)\)'), (m) => ':nth-child(${int.parse(m.group(1)!) + 1})');
  }

  static List<dom.Element> _jsoupSelectAll(dom.Element root, String expr) {
    for (final alt in expr.split('||')) {
      final clean = _normalizeCssSelector(alt.replaceFirst(RegExp(r'^body&&'), ''));
      if (clean.isEmpty) continue;
      final parts = clean.split('&&');
      List<dom.Element> current = [root];
      for (final p in parts) {
        final sel = _normalizeCssSelector(p);
        if (sel.isEmpty) continue;
        final next = <dom.Element>[];
        for (final el in current) {
          try {
            next.addAll(el.querySelectorAll(sel));
          } catch (_) {}
        }
        current = next;
        if (current.isEmpty) break;
      }
      if (current.isNotEmpty) return current;
    }
    return const [];
  }

  static List<CmsVideo> _xyqParseVideos(
    String html,
    Map<String, dynamic> rule,
    String origin, {
    bool isSearch = false,
  }) {
    final listSel = (isSearch
            ? (rule['搜索列表数组规则'] ?? rule['列表数组规则'] ?? '')
            : (rule['列表数组规则'] ?? ''))
        .toString()
        .trim();
    if (listSel.isEmpty) return const [];
    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return const [];

    final nodes = _jsoupSelectAll(body, listSel);
    final titleR = (isSearch
            ? (rule['搜索片单标题'] ?? rule['标题规则'] ?? 'a&&title||a&&Text')
            : (rule['标题规则'] ?? 'a&&title||a&&Text'))
        .toString();
    final picR = (isSearch
            ? (rule['搜索片单图片'] ?? rule['图片规则'] ?? 'img&&data-original||img&&data-src||img&&src')
            : (rule['图片规则'] ?? 'img&&data-original||img&&data-src||img&&src'))
        .toString();
    final remR = (isSearch
            ? (rule['搜索片单副标题'] ?? rule['集数规则'] ?? '')
            : (rule['集数规则'] ?? ''))
        .toString();
    final linkR = (isSearch
            ? (rule['搜索片单链接'] ?? rule['链接规则'] ?? 'a&&href')
            : (rule['链接规则'] ?? 'a&&href'))
        .toString();
    final pre = (isSearch
            ? (rule['搜索片单链接加前缀'] ?? rule['链接前缀'] ?? '')
            : (rule['链接前缀'] ?? ''))
        .toString();
    final suf = (isSearch
            ? (rule['搜索片单链接加后缀'] ?? rule['链接后缀'] ?? '')
            : (rule['链接后缀'] ?? ''))
        .toString();

    final out = <CmsVideo>[];
    final seen = <String>{};
    for (final el in nodes) {
      final title = _stripHtml(_jsoupSelectValue(el, titleR));
      final rawHref = _jsoupSelectValue(el, linkR);
      if (title.isEmpty || rawHref.isEmpty) continue;
      final id = _resolveHref(origin, rawHref, prefix: pre, suffix: suf);
      if (!seen.add(id)) continue;
      final pic = _safePic(origin, _jsoupSelectValue(el, picR));
      final rem = remR.isEmpty ? '' : _stripHtml(_jsoupSelectValue(el, remR));
      out.add(CmsVideo(id: id, title: title, poster: pic, remarks: rem));
    }
    return out;
  }

  static Future<(List<CmsCategory>, CmsListing)> _xyqHome(
    CmsSite site,
    Map<String, dynamic> rule,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final cats = <CmsCategory>[];
    final names = (rule['分类名称'] ?? '').toString().trim().split('&');
    final vals = (rule['分类值'] ?? '').toString().trim().split('&');
    for (var i = 0; i < names.length && i < vals.length; i++) {
      if (names[i].trim().isNotEmpty && vals[i].trim().isNotEmpty) {
        cats.add(CmsCategory(id: vals[i].trim(), name: names[i].trim()));
      }
    }
    if (cats.isEmpty) {
      cats.addAll(const [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '电视剧'),
        CmsCategory(id: '3', name: '综艺'),
        CmsCategory(id: '4', name: '动漫'),
      ]);
    }

    var videos = const <CmsVideo>[];
    final homeUrl = _resolveHref(origin, (rule['首页推荐链接'] ?? origin).toString());
    if (homeUrl.startsWith('http')) {
      try {
        final html = await fetchText(homeUrl, headers: headers);
        _checkChallenge(html);
        final homeRule = {
          ...rule,
          if ((rule['首页列表数组规则'] ?? '').toString().trim().isNotEmpty)
            '列表数组规则': rule['首页列表数组规则'],
        };
        videos = _xyqParseVideos(html, homeRule, origin);
      } catch (e) {
        if (e is FormatException) rethrow;
      }
    }
    if (videos.isEmpty && cats.isNotEmpty) {
      videos = (await _xyqCategory(site, rule, cats.first.id, 1, fetchText)).videos;
    }
    return (cats, CmsListing(page: 1, pageCount: videos.isEmpty ? 1 : 2, videos: videos));
  }

  static Future<CmsListing> _xyqCategory(
    CmsSite site,
    Map<String, dynamic> rule,
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText, {
    CmsFilter? filter,
  }) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final tpl = (rule['分类链接'] ?? '').toString().trim();
    if (tpl.isEmpty) return const CmsListing();
    final url = _resolveHref(
      origin,
      _expandUrlTemplate(
        tpl,
        cateId: categoryId,
        page: page < 1 ? 1 : page,
        area: filter != null && filter.area != '全部' ? filter.area : '',
        year: filter != null && filter.year != '全部' ? filter.year : '',
        clazz: filter != null && filter.genreLabel != '全部' ? filter.genreLabel : '',
      ),
    );
    if (!url.startsWith('http')) return const CmsListing();
    final html = await fetchText(url, headers: headers);
    _checkChallenge(html);
    final videos = _xyqParseVideos(html, rule, origin);
    return CmsListing(
      page: page < 1 ? 1 : page,
      pageCount: videos.isNotEmpty ? page + 1 : page,
      videos: videos,
    );
  }

  static Future<CmsListing> _xyqSearch(
    CmsSite site,
    Map<String, dynamic> rule,
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final tpl = (rule['搜索链接'] ?? '').toString().trim();
    if (tpl.isEmpty) return const CmsListing();
    final url = _resolveHref(
      origin,
      _expandUrlTemplate(tpl.split(';').first, wd: keyword, page: page < 1 ? 1 : page),
    );
    if (!url.startsWith('http')) return const CmsListing();
    final html = await fetchText(url, headers: headers);
    _checkChallenge(html);
    final videos = _xyqParseVideos(html, rule, origin, isSearch: true);
    return CmsListing(page: page, pageCount: 1, videos: videos);
  }

  static Future<CmsVideo> _xyqDetail(
    CmsSite site,
    Map<String, dynamic> rule,
    CmsVideo fallback,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final url = _resolveHref(origin, fallback.id);
    if (!url.startsWith('http')) return fallback;
    final html = await fetchText(url, headers: headers);
    _checkChallenge(html);
    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return fallback;

    final tabSel = (rule['线路列表数组规则'] ?? '.module-tab-item').toString();
    final tabTitleR = (rule['线路标题'] ?? 'Text').toString();
    final playSel = (rule['播放列表数组规则'] ?? '.module-play-list').toString();
    final epSel = (rule['选集列表数组规则'] ?? 'a').toString();
    final epTitleR = (rule['选集标题'] ?? 'a&&Text').toString();
    final epLinkR = (rule['选集链接'] ?? 'a&&href').toString();
    final epPre = (rule['选集链接加前缀'] ?? '').toString();
    final epSuf = (rule['选集链接加后缀'] ?? '').toString();

    final tabEls = _jsoupSelectAll(body, tabSel);
    final tabNames = [
      for (final t in tabEls) _stripHtml(_jsoupSelectValue(t, tabTitleR)),
    ].where((s) => s.isNotEmpty).toList();

    final playEls = _jsoupSelectAll(body, playSel);
    final lines = <CmsLine>[];
    for (var i = 0; i < playEls.length; i++) {
      final epEls = _jsoupSelectAll(playEls[i], epSel);
      final episodes = <CmsEpisode>[];
      for (var j = 0; j < epEls.length; j++) {
        final rawHref = _jsoupSelectValue(epEls[j], epLinkR);
        if (rawHref.isEmpty ||
            rawHref.startsWith('javascript:') ||
            rawHref.startsWith('magnet:')) {
          continue;
        }
        final epName = _stripHtml(_jsoupSelectValue(epEls[j], epTitleR));
        episodes.add(CmsEpisode(
          name: epName.isEmpty ? '第${j + 1}集' : epName,
          url: _resolveHref(origin, rawHref, prefix: epPre, suffix: epSuf),
          headers: headers,
        ));
      }
      if (episodes.isNotEmpty) {
        lines.add(CmsLine(
          name: i < tabNames.length ? tabNames[i] : '线路 ${i + 1}',
          episodes: episodes,
        ));
      }
    }

    final descSel = (rule['详情内容'] ?? '.video-info-content&&Text').toString();
    final desc = _stripHtml(_jsoupSelectValue(body, descSel));
    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      poster: fallback.poster,
      remarks: fallback.remarks,
      year: fallback.year,
      area: fallback.area,
      actor: fallback.actor,
      description: desc.isEmpty ? fallback.description : desc,
      tag: fallback.tag,
      lines: lines.isEmpty ? fallback.lines : lines,
    );
  }

  // ===========================================================================
  // 3. XPath Engine (lightweight XPath -> package:html DOM conversion)
  // ===========================================================================

  static (String, String) _xpathToCssAndAttr(String rawXpath) {
    var xp = rawXpath.trim();
    if (xp.isEmpty) return ('', 'text');
    // Unwrap `concat('prefix', //xpath)` if simple
    final concatM = RegExp(r'^concat\((.+)\)$').firstMatch(xp);
    if (concatM != null) {
      for (final piece in concatM.group(1)!.split(',')) {
        final t = piece.trim();
        if (t.startsWith('/') || t.startsWith('.')) {
          xp = t;
          break;
        }
      }
    }
    var attr = 'text';
    if (xp.endsWith('/text()')) {
      xp = xp.substring(0, xp.length - 7);
      attr = 'text';
    } else {
      final attrM = RegExp(r'/@([A-Za-z0-9_:-]+)$').firstMatch(xp);
      if (attrM != null) {
        attr = attrM.group(1)!;
        xp = xp.substring(0, attrM.start);
      }
    }
    xp = xp.replaceFirst(RegExp(r'^\.?//+'), '');
    final steps = xp.split(RegExp(r'/+'));
    final cssParts = <String>[];
    for (var s in steps) {
      if (s.isEmpty || s == '.') continue;
      // Convert `tag[contains(@class, 'foo')]` -> `tag.foo`
      s = s.replaceAllMapped(
        RegExp(r'''\[\s*contains\(\s*@class\s*,\s*['"]([^'"]+)['"]\s*\)\s*\]'''),
        (m) => '.${m.group(1)!.trim().split(RegExp(r'\s+')).join('.')}',
      );
      // Convert `tag[@class='foo bar']` -> `tag.foo.bar`
      s = s.replaceAllMapped(
        RegExp(r'''\[\s*@class\s*=\s*['"]([^'"]+)['"]\s*\]'''),
        (m) => '.${m.group(1)!.trim().split(RegExp(r'\s+')).join('.')}',
      );
      // Convert `tag[@id='foo']` -> `tag#foo`
      s = s.replaceAllMapped(
        RegExp(r'''\[\s*@id\s*=\s*['"]([^'"]+)['"]\s*\]'''),
        (m) => '#${m.group(1)!.trim()}',
      );
      // Convert `tag[1]` -> `tag:nth-of-type(1)`
      s = s.replaceAllMapped(
        RegExp(r'\[(\d+)\]'),
        (m) => ':nth-of-type(${m.group(1)})',
      );
      // Convert remaining `[@attr='val']` -> `[attr="val"]`
      s = s.replaceAllMapped(
        RegExp(r'''\[\s*@([A-Za-z0-9_:-]+)\s*=\s*['"]([^'"]+)['"]\s*\]'''),
        (m) => '[${m.group(1)}="${m.group(2)}"]',
      );
      if (s == '*') s = '';
      if (s.isNotEmpty) cssParts.add(s);
    }
    return (cssParts.join(' '), attr);
  }

  static List<dom.Element> _xpathNodes(dom.Element root, String rawXpath) {
    final (css, _) = _xpathToCssAndAttr(rawXpath);
    if (css.isEmpty) return const [];
    try {
      return root.querySelectorAll(css);
    } catch (_) {
      return const [];
    }
  }

  static String _xpathString(dom.Element root, String rawXpath, {String regexGroup = ''}) {
    if (rawXpath.trim().isEmpty) return '';
    final (css, attr) = _xpathToCssAndAttr(rawXpath);
    dom.Element? el = root;
    if (css.isNotEmpty) {
      try {
        el = root.querySelector(css);
      } catch (_) {
        el = null;
      }
    }
    if (el == null) return '';
    var val = attr == 'text' ? el.text.trim() : (el.attributes[attr] ?? '').trim();
    if (val.isNotEmpty && regexGroup.trim().isNotEmpty) {
      final m = RegExp(regexGroup.trim()).firstMatch(val);
      if (m != null && m.groupCount >= 1) val = m.group(1) ?? val;
    }
    return val;
  }

  static List<CmsVideo> _xpathParseVideos(
    String html,
    Map<String, dynamic> rule,
    String origin, {
    required String prefixKey,
  }) {
    final nodeXp = (rule['${prefixKey}VodNode'] ?? rule['scVodNode'] ?? rule['homeVodNode'] ?? '').toString();
    if (nodeXp.trim().isEmpty) return const [];
    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return const [];

    final nodes = _xpathNodes(body, nodeXp);
    final nameXp = (rule['${prefixKey}VodName'] ?? rule['scVodName'] ?? rule['homeVodName'] ?? '').toString();
    final idXp = (rule['${prefixKey}VodId'] ?? rule['scVodId'] ?? rule['homeVodId'] ?? '').toString();
    final idR = (rule['${prefixKey}VodIdR'] ?? rule['scVodIdR'] ?? rule['homeVodIdR'] ?? '').toString();
    final imgXp = (rule['${prefixKey}VodImg'] ?? rule['scVodImg'] ?? rule['homeVodImg'] ?? '').toString();
    final markXp = (rule['${prefixKey}VodMark'] ?? rule['scVodMark'] ?? rule['homeVodMark'] ?? '').toString();

    final out = <CmsVideo>[];
    for (final el in nodes) {
      final title = _stripHtml(_xpathString(el, nameXp));
      final id = _xpathString(el, idXp, regexGroup: idR);
      if (title.isEmpty || id.isEmpty) continue;
      final pic = _safePic(origin, _xpathString(el, imgXp));
      final rem = _stripHtml(_xpathString(el, markXp));
      out.add(CmsVideo(id: id, title: title, poster: pic, remarks: rem));
    }
    return out;
  }

  static Future<(List<CmsCategory>, CmsListing)> _xpathHome(
    CmsSite site,
    Map<String, dynamic> rule,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final cats = <CmsCategory>[];
    final manual = rule['cateManual'];
    if (manual is Map) {
      manual.forEach((k, v) {
        final n = k.toString().trim();
        final id = v.toString().trim();
        if (n.isNotEmpty && id.isNotEmpty) cats.add(CmsCategory(id: id, name: n));
      });
    }
    var videos = const <CmsVideo>[];
    final homeUrl = _resolveHref(origin, (rule['homeUrl'] ?? origin).toString());
    if (homeUrl.startsWith('http')) {
      try {
        final html = await fetchText(homeUrl, headers: headers);
        _checkChallenge(html);
        videos = _xpathParseVideos(html, rule, origin, prefixKey: 'home');
      } catch (e) {
        if (e is FormatException) rethrow;
      }
    }
    if (videos.isEmpty && cats.isNotEmpty) {
      videos = (await _xpathCategory(site, rule, cats.first.id, 1, fetchText)).videos;
    }
    return (cats, CmsListing(page: 1, pageCount: videos.isEmpty ? 1 : 2, videos: videos));
  }

  static Future<CmsListing> _xpathCategory(
    CmsSite site,
    Map<String, dynamic> rule,
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final tpl = (rule['cateUrl'] ?? '').toString().trim();
    if (tpl.isEmpty) return const CmsListing();
    final url = _resolveHref(
      origin,
      _expandUrlTemplate(tpl, cateId: categoryId, page: page < 1 ? 1 : page),
    );
    if (!url.startsWith('http')) return const CmsListing();
    final html = await fetchText(url, headers: headers);
    _checkChallenge(html);
    final videos = _xpathParseVideos(html, rule, origin, prefixKey: 'cate');
    return CmsListing(
      page: page < 1 ? 1 : page,
      pageCount: videos.isNotEmpty ? page + 1 : page,
      videos: videos,
    );
  }

  static Future<CmsListing> _xpathSearch(
    CmsSite site,
    Map<String, dynamic> rule,
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final tpl = (rule['searchUrl'] ?? '').toString().trim();
    if (tpl.isEmpty) return const CmsListing();
    final url = _resolveHref(
      origin,
      tpl.replaceAll('{wd}', Uri.encodeQueryComponent(keyword)).replaceAll('{pg}', '$page'),
    );
    if (!url.startsWith('http')) return const CmsListing();
    final raw = await fetchText(url, headers: headers);
    _checkChallenge(raw);
    if ('${rule['scVodNode'] ?? ''}'.startsWith('json:') || raw.trimLeft().startsWith('{')) {
      try {
        final doc = jsonDecode(raw);
        final list = doc is Map ? (doc['list'] ?? doc['data']) : null;
        if (list is List) {
          final videos = <CmsVideo>[];
          for (final it in list.whereType<Map>()) {
            final id = (it['id'] ?? it['vod_id'] ?? '').toString().trim();
            final name = (it['name'] ?? it['vod_name'] ?? '').toString().trim();
            if (id.isNotEmpty && name.isNotEmpty) {
              videos.add(CmsVideo(
                id: id,
                title: name,
                poster: _safePic(origin, (it['pic'] ?? it['vod_pic'] ?? '').toString()),
              ));
            }
          }
          if (videos.isNotEmpty) return CmsListing(page: 1, pageCount: 1, videos: videos);
        }
      } catch (_) {}
    }
    final videos = _xpathParseVideos(raw, rule, origin, prefixKey: 'sc');
    return CmsListing(page: page, pageCount: 1, videos: videos);
  }

  static Future<CmsVideo> _xpathDetail(
    CmsSite site,
    Map<String, dynamic> rule,
    CmsVideo fallback,
    CspHttpTextFetcher fetchText,
  ) async {
    final origin = _originOf(rule);
    final headers = _headersForRule(site, rule, refererOrigin: origin);
    final dtTpl = (rule['dtUrl'] ?? '{vid}').toString();
    final detailUrl = _resolveHref(origin, dtTpl.replaceAll('{vid}', fallback.id));
    if (!detailUrl.startsWith('http')) return fallback;
    final html = await fetchText(detailUrl, headers: headers);
    _checkChallenge(html);
    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return fallback;

    final fromNodes = _xpathNodes(body, (rule['dtFromNode'] ?? '').toString());
    final fromNameXp = (rule['dtFromName'] ?? '/text()').toString();
    final tabNames = [
      for (final f in fromNodes) _stripHtml(_xpathString(f, fromNameXp)),
    ].where((s) => s.isNotEmpty).toList();

    final urlNodes = _xpathNodes(body, (rule['dtUrlNode'] ?? '').toString());
    final subXp = (rule['dtUrlSubNode'] ?? '//a').toString();
    final idXp = (rule['dtUrlId'] ?? '/@href').toString();
    final idR = (rule['dtUrlIdR'] ?? '').toString();
    final epNameXp = (rule['dtUrlName'] ?? '/text()').toString();
    final playTpl = (rule['playUrl'] ?? '{playUrl}').toString();

    final lines = <CmsLine>[];
    for (var i = 0; i < urlNodes.length; i++) {
      final epEls = _xpathNodes(urlNodes[i], subXp);
      final episodes = <CmsEpisode>[];
      for (var j = 0; j < epEls.length; j++) {
        final pid = _xpathString(epEls[j], idXp, regexGroup: idR);
        if (pid.isEmpty || pid.startsWith('javascript:')) continue;
        final epName = _stripHtml(_xpathString(epEls[j], epNameXp));
        final epUrl = _resolveHref(origin, playTpl.replaceAll('{playUrl}', pid));
        episodes.add(CmsEpisode(
          name: epName.isEmpty ? '第${j + 1}集' : epName,
          url: epUrl,
          headers: headers,
        ));
      }
      if (episodes.isNotEmpty) {
        lines.add(CmsLine(
          name: i < tabNames.length ? tabNames[i] : '线路 ${i + 1}',
          episodes: episodes,
        ));
      }
    }

    final desc = _stripHtml(_xpathString(body, (rule['dtDesc'] ?? '').toString()));
    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      poster: fallback.poster,
      remarks: fallback.remarks,
      year: fallback.year,
      area: fallback.area,
      actor: fallback.actor,
      description: desc.isEmpty ? fallback.description : desc,
      tag: fallback.tag,
      lines: lines.isEmpty ? fallback.lines : lines,
    );
  }
}
